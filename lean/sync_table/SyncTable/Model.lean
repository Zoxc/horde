import SyncTable.Table

/-!
# Concurrent model of `SyncTable`

An interleaving (sequentially consistent) transition system:

* **one writer** (the `lock` mutex, `&mut self`, or the `unsafe_write` contract give mutual
  exclusion between writers). Each writer operation is one atomic step. Readers only
  observe control bytes, with `Acquire`, and read a bucket only after seeing it full, while
  the writer writes the bucket before the `Release` store of the control byte, so the
  bucket write is invisible until the control byte flips. A single writer operation changes
  at most one bucket's state (plus counters readers don't use for lookups).
* **readers** run `pin` → load `current` → probe group by group → return → (more lookups) →
  unpin. A group load (`Group::load`) is not a snapshot: it is `W` separate `Acquire` byte loads
  that can shear (`sse2.rs` `load`, `generic.rs` `load`). The model reads a group as one bucket
  per step, in any order and interleaved with other threads (`scanLoad`), and decides only once
  the whole group is loaded: first the `h2` matches (`scanHit`), then `match_empty`
  (`scanEmpty`), else on to the next group (`scanNext`), as `search` does.
* **`collect` is abstracted** here: `markFree` (the writer reading the `can_free` flag that
  `collect` stored) is enabled only when no pinned region that started at or before the `defer` is still
  active. This premise is not an assumption of the results: `Composed.lean` runs this model
  together with the `collect` primary model from `lean/collect` and proves it
  (`Composed.markFree_premise`, from `Collect.Main.safety`).

Tables are identified by their address (`TableInfoRef` pointer). A new table gets a fresh
address (`nextId`) or the address of a freed table (`Step.expandAt`, `Step.replaceAt`: the
allocator may reuse memory `prune_tables` freed); pinned readers never hold a freed table
(`no_use_after_free`), so a reused address is never confused with the old table. Id `0`
is the static empty table (`TableInfoRef::empty()`, `EMPTY_TABLE`): one bucket, `growth_left = 0`,
`can_free = false`. It is `current` initially (`SyncTable::new()`) and again after every
`replace` that installs it (`Step.replaceEmpty`). It is never allocated, retired, deferred or
freed: `replace_table` returns before the retire/defer when the old table is the static one
(`publish`, `retire`), and it is never written (`growth_left = 0`, no full bucket).
Ghost state: `ver`/`hist` give the abstract map at each writer version, and `clk` is the
`collect` logical time used for pins and defers.
-/

namespace SyncTable

def upd {α : Type} (f : Nat → α) (t : Nat) (v : α) : Nat → α :=
  fun u => if u = t then v else f u

@[simp] theorem upd_same {α} (f : Nat → α) t v : upd f t v t = v := by simp [upd]
theorem upd_other {α} (f : Nat → α) t v u (h : u ≠ t) : upd f t v u = f u := by
  simp [upd, h]

/-- Status of a `TableInfo` allocation. -/
inductive TS where
  | unalloc
  /-- allocated and not retired: the table in `SyncTable::current`, or the static empty table
  (id `0`), which is never retired -/
  | live
  /-- in the retired list: replaced at writer version `ver`, `defer_by_id` called at
  `collect` time `d`; `canFree`: the writer has read `can_free` as `true` (in
  `Composed.lean` the atomic itself is the cell `CSt.cell`) -/
  | retired (ver d : Nat) (canFree : Bool)
  /-- deallocated by `prune_tables` -/
  | freed
  deriving DecidableEq

/-- Reader thread state. `held`: tables the thread still holds references into (via
`Read<'a>` results), `start`: `collect` time at which its `pin` began. -/
inductive RS (K V : Type) where
  | idle
  | pinned (start : Nat) (held : List Nat)
  /-- inside `search` on table `t` for key `k`, `lv` = writer version when `current` was
  loaded, `pre` = ghost list of buckets already probed, `rest` = buckets still to probe -/
  | probing (start : Nat) (held : List Nat) (k : K) (t lv : Nat) (pre rest : List Nat)
  /-- inside `search`, loading group `g` (the next buckets of the probe sequence, `pre ++ g ++
  rest`): `todo` = buckets of `g` not loaded yet, `obs` = the bytes loaded so far with the bucket
  state each load saw (in load order) -/
  | scanning (start : Nat) (held : List Nat) (k : K) (t lv : Nat) (pre g todo : List Nat)
      (obs : List (Nat × Slot K V)) (rest : List Nat)
  /-- `get` has returned `res` -/
  | returned (start : Nat) (held : List Nat) (k : K) (t lv : Nat) (res : Option V)

def RS.start {K V} : RS K V → Option Nat
  | .idle => none
  | .pinned s _ => some s
  | .probing s .. => some s
  | .scanning s .. => some s
  | .returned s .. => some s

structure St (K V : Type) where
  tables : Nat → Table K V
  ts : Nat → TS
  /-- `SyncTable::current` -/
  cur : Nat
  /-- next fresh table id (allocator) -/
  nextId : Nat
  /-- ghost: writer version (number of map-changing writes) -/
  ver : Nat
  /-- ghost: abstract map at each version -/
  hist : Nat → K → V → Prop
  /-- ghost: `collect` logical clock -/
  clk : Nat
  rd : Nat → RS K V

variable {K V : Type} [DecidableEq K] (C : Cfg K)

/-- A writer step that changes the current table in place and changes the abstract map. -/
def commit (s : St K V) (T' : Table K V) : St K V :=
  { s with tables := upd s.tables s.cur T', ver := s.ver + 1,
           hist := fun x => if x = s.ver + 1 then Has T' else s.hist x }

/-- `replace_table`'s retirement of the old `current`: appended to the retired list at
version `ver` and `defer_by_id` at time `clk`, unless it is the static empty table (id `0`), for
which `replace_table` returns early (`if table.info == TableInfoRef::empty() { return; }`). -/
def retire (s : St K V) : Nat → TS :=
  fun u => if u = s.cur ∧ s.cur ≠ 0 then .retired s.ver s.clk false else s.ts u

/-- The table clock after `replace_table`: the `defer_by_id` is one `collect` event, skipped for
the static table. -/
def tick (s : St K V) : Nat := if s.cur = 0 then s.clk else s.clk + 1

/-- `replace_table(new)`: store table `t` (contents `T'`) into `current` and retire the old one
(`retire`, `tick`). `nx` is the next fresh id afterwards; `changes` is true for `replace` (new
abstract map `Has T'`). -/
def publish (s : St K V) (t : Nat) (T' : Table K V) (nx : Nat) (changes : Bool) : St K V :=
  { s with tables := upd s.tables t T', ts := upd (retire s) t .live, cur := t, nextId := nx,
           clk := tick s, ver := if changes then s.ver + 1 else s.ver,
           hist := if changes then (fun x => if x = s.ver + 1 then Has T' else s.hist x)
                   else s.hist }

/-- `replace_table` of a freshly allocated table (`TableRef::allocate`, `from_iter`,
`clone_table`): `T'` gets the fresh id `nextId`. -/
def swap (s : St K V) (T' : Table K V) (changes : Bool) : St K V :=
  publish s s.nextId T' (s.nextId + 1) changes

/-- `replace_table(TableRef::empty())`: the static empty table (id `0`, unchanged) becomes
`current` again; nothing is allocated. -/
def swapEmpty (s : St K V) : St K V := publish s 0 (s.tables 0) s.nextId true

/-- `replace_table` of a table allocated at the address `a` of a freed table (`TableRef::allocate`
returning memory that `prune_tables` freed earlier, as Rust's allocator may): the table id is
the address, so the new table reuses id `a` (with a fresh `can_free`, in `Composed.lean`). -/
def swapAt (s : St K V) (a : Nat) (T' : Table K V) (changes : Bool) : St K V :=
  publish s a T' s.nextId changes

/-- The shapes of `publish` the model uses: a fresh table (`swap`), the static one
(`swapEmpty`), or a table at a reused address (`swapAt`). -/
def PubOK (s : St K V) (t : Nat) (T' : Table K V) (nx : Nat) : Prop :=
  (t = s.nextId ∧ nx = s.nextId + 1) ∨ (t = 0 ∧ nx = s.nextId ∧ T' = s.tables 0) ∨
    (s.ts t = .freed ∧ nx = s.nextId)

omit [DecidableEq K] in
theorem swap_pub (s : St K V) (T' : Table K V) : PubOK s s.nextId T' (s.nextId + 1) :=
  .inl ⟨rfl, rfl⟩

omit [DecidableEq K] in
theorem swapEmpty_pub (s : St K V) : PubOK s 0 (s.tables 0) s.nextId := .inr (.inl ⟨rfl, rfl, rfl⟩)

omit [DecidableEq K] in
theorem swapAt_pub {s : St K V} {a : Nat} (T' : Table K V) (h : s.ts a = .freed) :
    PubOK s a T' s.nextId := .inr (.inr ⟨h, rfl⟩)

def setRd (s : St K V) (u : Nat) (r : RS K V) : St K V := { s with rd := upd s.rd u r }

inductive Step : St K V → St K V → Prop
  -- writer
  /-- `insert_new` / `insert` (after its `find_potential` found nothing) /
  `PotentialSlot::insert_new` with the key its slot was created for, once `growth_left > 0`:
  the key goes into `find_insert_slot`'s bucket. The key may already be present:
  `insert_new` does not check (a contract violation, see `Contract.lean`), and then the table
  gets a second bucket for the key. -/
  | insert (s : St K V) (k : K) (v : V) (i : Nat) :
      0 < (s.tables s.cur).growthLeft →
      firstEmpty (s.tables s.cur) (ps C (s.tables s.cur) k) = some i →
      Step s (commit s (insertAt (s.tables s.cur) i k v))
  /-- `PotentialSlot::insert_new` fast path, without the key contract. It checks only that the
  slot's table is `current` (`is_empty`'s pointer compare), that bucket `i` is still `EMPTY`, and
  that `growth_left > 0`, and then writes `key` at `i`. Nothing checks that `key` is the key
  `get_potential` was called with (only `debug_assert_eq!` against `find_insert_slot`), so any
  key can land in any `EMPTY` bucket: off its probe sequence, or after an `EMPTY` bucket on it.
  The same holds for `insert_new` / `insert` given a `hash` that is not the hash of `key`.
  The counter effects are those of `insert` (`record_item_insert_at`). `i < n` holds because a
  `PotentialSlot` is only built by `get_potential` / `refresh` from a bucket on a probe sequence
  of the table whose `TableInfo` pointer it records (`Cfg.seq_lt`), and `is_empty` checks that
  pointer against `current`. `Step.insert` is the special case `i = firstEmpty` of `k`'s probe
  sequence (`ProbeOK`). -/
  | insertAny (s : St K V) (k : K) (v : V) (i : Nat) :
      0 < (s.tables s.cur).growthLeft →
      (s.tables s.cur).slot i = .empty → i < (s.tables s.cur).n →
      Step s (commit s (insertAt (s.tables s.cur) i k v))
  /-- An insert (`insert_new`, `insert`, or `PotentialSlot::insert_new`) given a hash whose
  `h2` is not `h2` of `k`'s hash: `record_item_insert_at` writes that tag, so the bucket is full
  but no lookup matches it. It can land in any `EMPTY` bucket, like `insertAny`, with the same
  counter effects. -/
  | insertMis (s : St K V) (k : K) (v : V) (i : Nat) :
      0 < (s.tables s.cur).growthLeft →
      (s.tables s.cur).slot i = .empty → i < (s.tables s.cur).n →
      Step s (commit s (insertMis (s.tables s.cur) i k v))
  /-- `remove` (after `find` returned bucket `i`) -/
  | remove (s : St K V) (k : K) (v : V) (i : Nat) :
      (s.tables s.cur).slot i = .full k v →
      Step s (commit s (removeAt (s.tables s.cur) i k v))
  /-- `remove` given a wrong hash whose `h2` and probe sequence reach a `mistagged` bucket
  holding `k` -/
  | removeMis (s : St K V) (k : K) (v : V) (i : Nat) :
      (s.tables s.cur).slot i = .mistagged k v →
      Step s (commit s (removeAt (s.tables s.cur) i k v))
  /-- `expand_by` / `reserve_one`: clone into a table of `m` buckets (`clone_table`) and
  `replace_table` -/
  | expand (s : St K V) (m : Nat) :
      m.isPowerOfTwo → (items (s.tables s.cur)).length ≤ bmc (m - 1) →
      Step s (swap s (build C m (items (s.tables s.cur))) false)
  /-- `replace` (`from_maybe_empty_iter` + `replace_table`) into a freshly allocated table. The
  keys need not be distinct: `from_iter` does not deduplicate (a contract violation, see
  `Contract.lean`). `l = []` is `replace` of an empty iterator with `capacity > 0`. -/
  | replace (s : St K V) (m : Nat) (l : List (K × V)) :
      m.isPowerOfTwo → l.length ≤ bmc (m - 1) →
      Step s (swap s (build C m l) true)
  /-- `expand` into a table allocated at a freed table's address `a` (address reuse) -/
  | expandAt (s : St K V) (m a : Nat) : s.ts a = .freed →
      m.isPowerOfTwo → (items (s.tables s.cur)).length ≤ bmc (m - 1) →
      Step s (swapAt s a (build C m (items (s.tables s.cur))) false)
  /-- `replace` into a table allocated at a freed table's address `a` (address reuse) -/
  | replaceAt (s : St K V) (m a : Nat) (l : List (K × V)) : s.ts a = .freed →
      m.isPowerOfTwo → l.length ≤ bmc (m - 1) →
      Step s (swapAt s a (build C m l) true)
  /-- `replace` of an empty iterator with `capacity = 0`: `from_maybe_empty_iter` returns
  `TableRef::empty()` and `replace_table` installs the static empty table (also when it is
  already `current`). -/
  | replaceEmpty (s : St K V) : Step s (swapEmpty s)
  /-- `prune_tables`: free a retired table whose `can_free` is set -/
  | prune (s : St K V) (t v d : Nat) : s.ts t = .retired v d true →
      Step s { s with ts := upd s.ts t .freed }
  -- `collect` (abstracted; the premise is proved in `Composed.lean`)
  /-- `prune_tables` reads `can_free` as `true` (`collect` stored it); allowed only when no pinned
  region that began at or before the `defer` is active (`Composed.markFree_premise`,
  `Composed.can_free_safe`, from `Collect.Main.safety`). -/
  | markFree (s : St K V) (t v d : Nat) : s.ts t = .retired v d false →
      (∀ u st, (s.rd u).start = some st → d < st) →
      Step s { s with ts := upd s.ts t (.retired v d true) }
  -- readers
  | pin (s : St K V) (u : Nat) : s.rd u = .idle →
      Step s { setRd s u (.pinned s.clk []) with clk := s.clk + 1 }
  | unpin (s : St K V) (u st : Nat) (h : List Nat) : s.rd u = .pinned st h →
      Step s (setRd s u .idle)
  /-- `self.table.current()` (Acquire load) at the start of `get`/`get_potential` -/
  | load (s : St K V) (u st : Nat) (h : List Nat) (k : K) : s.rd u = .pinned st h →
      Step s (setRd s u (.probing st h k s.cur s.ver [] (ps C (s.tables s.cur) k)))
  /-- `search` starts on the next group: `Group::load` at `probe_seq.pos`. The group is any
  non-empty prefix `g` of the remaining probe sequence. For `triSeq W` the real groups are the
  consecutive `W`-chunks, so this allows more runs than Rust has. -/
  | probeGroup (s : St K V) (u st : Nat) (h : List Nat) (k : K) (t lv : Nat) (pre g rest : List Nat) :
      s.rd u = .probing st h k t lv pre (g ++ rest) → g ≠ [] →
      Step s (setRd s u (.scanning st h k t lv pre g g [] rest))
  /-- one byte of `Group::load`: an `Acquire` load of the control byte of some not yet loaded
  bucket `j` of the group, in any order (the loads can shear) -/
  | scanLoad (s : St K V) (u st : Nat) (h : List Nat) (k : K) (t lv : Nat)
      (pre g todo : List Nat) (obs : List (Nat × Slot K V)) (rest : List Nat) (j : Nat) :
      s.rd u = .scanning st h k t lv pre g todo obs rest → j ∈ todo →
      Step s (setRd s u (.scanning st h k t lv pre g (todo.erase j)
        (obs ++ [(j, (s.tables t).slot j)]) rest))
  /-- the group is loaded and one of its loaded bytes is a full bucket of `k` (`match_byte`, then
  `eq` on the bucket, which a full bucket keeps until it is freed). Rust takes the lowest such
  bit; the model allows any. -/
  | scanHit (s : St K V) (u st : Nat) (h : List Nat) (k : K) (t lv : Nat)
      (pre g : List Nat) (obs : List (Nat × Slot K V)) (rest : List Nat) (j : Nat) (v : V) :
      s.rd u = .scanning st h k t lv pre g [] obs rest → (j, .full k v) ∈ obs →
      Step s (setRd s u (.returned st h k t lv (some v)))
  /-- no match in the loaded group, and some loaded byte is `EMPTY` (`match_empty` stop) -/
  | scanEmpty (s : St K V) (u st : Nat) (h : List Nat) (k : K) (t lv : Nat)
      (pre g : List Nat) (obs : List (Nat × Slot K V)) (rest : List Nat) (j : Nat) :
      s.rd u = .scanning st h k t lv pre g [] obs rest → (∀ i w, (i, .full k w) ∉ obs) →
      (j, .empty) ∈ obs →
      Step s (setRd s u (.returned st h k t lv none))
  /-- no match and no `EMPTY` byte in the loaded group: `probe_seq.move_next` -/
  | scanNext (s : St K V) (u st : Nat) (h : List Nat) (k : K) (t lv : Nat)
      (pre g : List Nat) (obs : List (Nat × Slot K V)) (rest : List Nat) :
      s.rd u = .scanning st h k t lv pre g [] obs rest → (∀ i w, (i, .full k w) ∉ obs) →
      (∀ i, (i, .empty) ∉ obs) →
      Step s (setRd s u (.probing st h k t lv (pre ++ g) rest))
  | probeEnd (s : St K V) (u st : Nat) (h : List Nat) (k : K) (t lv : Nat) (pre : List Nat) :
      s.rd u = .probing st h k t lv pre [] →
      Step s (setRd s u (.returned st h k t lv none))
  /-- the reader keeps the returned references until its pin ends -/
  | finish (s : St K V) (u st : Nat) (h : List Nat) (k : K) (t lv : Nat) (r : Option V) :
      s.rd u = .returned st h k t lv r →
      Step s (setRd s u (.pinned st (t :: h)))

/-- Initial state: `SyncTable::new()`: `current` is the static empty table (id `0`, 1 bucket,
capacity 0). Every table id is initially the 1-bucket empty table; only id `0` is allocated. -/
def init : St K V :=
  { tables := fun _ => emptyTable 1, ts := fun t => if t = 0 then .live else .unalloc,
    cur := 0, nextId := 1, ver := 0, hist := fun _ _ _ => False, clk := 0,
    rd := fun _ => .idle }

inductive Reachable : St K V → Prop
  | init : Reachable init
  | step {s s'} : Reachable s → Step C s s' → Reachable s'

/-- Step `s → s'` respects the probe (key) contract: if it writes a key `k` into an `EMPTY`
bucket `i` of the current table, `i` is the first `EMPTY` bucket of `k`'s probe sequence
(what `find_insert_slot` picks), and it does not write a `mistagged` bucket (the hash given
to an insert has `k`'s `h2`). Only `Step.insertAny` with a mismatched key or hash, and
`Step.insertMis`, can violate it (`probeOK_insertAny_iff`; every other step satisfies it, see `Safety.lean`). -/
def ProbeOK (s s' : St K V) : Prop :=
  (∀ i k v, (s.tables s.cur).slot i = .empty →
    s' = commit s (insertAt (s.tables s.cur) i k v) →
    firstEmpty (s.tables s.cur) (ps C (s.tables s.cur) k) = some i) ∧
  ∀ i k v, (s.tables s.cur).slot i = .empty → s' ≠ commit s (insertMis (s.tables s.cur) i k v)

/-- Runs in which every step respects the probe contract (`ProbeOK`). The probe-based
correctness results (`preachable_inv`, `get_linearizable_some`, `potential_get`) hold on these runs;
the safety results hold on all of `Reachable`. -/
inductive PReachable : St K V → Prop
  | init : PReachable init
  | step {s s'} : PReachable s → Step C s s' → ProbeOK C s s' → PReachable s'

/-! ## `publish` facts -/

section
set_option linter.unusedSectionVars false
set_option linter.deprecated false

theorem publish_ts (s : St K V) (t : Nat) (T' : Table K V) (nx : Nat) (ch : Bool) (u : Nat) :
    (publish s t T' nx ch).ts u = if u = t then .live else retire s u := rfl

theorem retire_of_ne {s : St K V} {u : Nat} (h : ¬ (u = s.cur ∧ s.cur ≠ 0)) :
    retire s u = s.ts u := if_neg h

theorem retire_cur0 {s : St K V} (h : s.cur = 0) : retire s = s.ts :=
  funext fun _ => retire_of_ne (fun ⟨_, e⟩ => e h)

theorem tick_cur0 {s : St K V} (h : s.cur = 0) : tick s = s.clk := if_pos h

theorem tick_ne0 {s : St K V} (h : s.cur ≠ 0) : tick s = s.clk + 1 := if_neg h

theorem clk_le_tick (s : St K V) : s.clk ≤ tick s := by
  unfold tick; split <;> omega

theorem PubOK.nx_ge {s : St K V} {t : Nat} {T' : Table K V} {nx : Nat} (hp : PubOK s t T' nx) :
    s.nextId ≤ nx := by
  rcases hp with ⟨_, rfl⟩ | ⟨_, rfl, _⟩ | ⟨_, rfl⟩ <;> omega

/-- Every table below `nextId` that is not freed keeps its contents (the static one is
re-published unchanged; a reused address was freed). -/
theorem publish_tables_lt {s : St K V} {t : Nat} {T' : Table K V} {nx : Nat} (ch : Bool)
    (hp : PubOK s t T' nx) {u : Nat} (hu : u < s.nextId) (hf : s.ts u ≠ .freed) :
    (publish s t T' nx ch).tables u = s.tables u := by
  show upd s.tables t T' u = _
  rcases hp with ⟨rfl, _⟩ | ⟨rfl, _, rfl⟩ | ⟨ht, _⟩
  · exact upd_other _ _ _ _ (Nat.ne_of_lt hu)
  · unfold upd; split
    · rename_i e; rw [e]
    · rfl
  · exact upd_other _ _ _ _ (fun e => hf (e ▸ ht))

/-- `publish` frees nothing. -/
theorem publish_freed {s : St K V} {t : Nat} {T' : Table K V} {nx : Nat} {ch : Bool} {u : Nat}
    (h : (publish s t T' nx ch).ts u = .freed) : s.ts u = .freed := by
  rw [publish_ts] at h; split at h
  · cases h
  · unfold retire at h; split at h
    · cases h
    · exact h

end

theorem PReachable.reachable {s : St K V} (h : PReachable C s) : Reachable C s := by
  induction h with
  | init => exact .init
  | step _ hs _ ih => exact .step ih hs

end SyncTable
