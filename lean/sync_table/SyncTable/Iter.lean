import SyncTable.Contract

/-!
# Concurrent `Read::iter`, `len`, `capacity` and `Clone` (property 19)

An extension of the concurrent model (`Step`) with **unlocked whole-table readers**. The extended
state `ISt` is the `St` of `Model.lean` plus one state `IR` per iterator / call slot `i`. An
`IStep` is a `Step` of the base model (`IStep.base`), the start of one of the calls
(`IStep.start`), or one step of a running call (`IStep.local`, `IRStep`). The existing model and
its proofs are unchanged; every `IStep` maps to `Step`s of the base model
(`istep_steps`, `ireach_reachable`, given a key to run a `get` with), so all earlier theorems hold
for the base component of extended runs.

What the Rust code does (`sync_table.rs`):

* `Read::iter` loads `current` once (`self.table.current()`) and returns an `Iter<'a>` over
  `TableRef::iter`, a `RawIterRange` over buckets `0 .. buckets()` of **that table**. It never
  reloads `current`, so after a resize it keeps reading the old (retired) table. `RawIterRange`
  loads the control bytes group by group (`Group::load_aligned`, the `W`-aligned chunks in index
  order), takes `match_full` (every byte that is neither `EMPTY` nor `DELETED`, so `mistagged`
  buckets too) and yields those buckets lowest index first. It never stops at an `EMPTY` byte.
  The lifetime `'a` of `Iter` is the pin's (`Read<'a>`), so the table cannot be freed while the
  iterator or its references live.
* `Read::len` loads `current`, then `tombstones` (`Acquire`), then `growth_left` (`Acquire`) and
  returns `bucket_mask_to_capacity - tombstones - growth_left` (`TableInfo::items`).
* `Read::capacity` loads `current`, then `tombstones`, and returns
  `bucket_mask_to_capacity - tombstones` (`bucket_mask` never changes).
* `Clone for SyncTable` pins, loads `current` and calls `clone_table_dedup`: it loads
  `tombstones`; if `capacity - tombstones = 0` it returns the static empty table; otherwise it
  allocates a table whose capacity is at least `capacity - tombstones` (`max(items * 2,
  remaining_capacity)` through `capacity_to_buckets`), iterates the old table with
  `TableRef::iter` and inserts each yielded pair unless its key is already there
  (`find_potential` with key equality: the first yielded pair of a key wins).

Model (`IR`):

* An iterator is `IR.iter u t rest g todo obs out cl`: thread `u`, table `t`, buckets `rest`
  not reached, current group `g` (`[]` between groups) with unloaded buckets `todo` and loaded
  bytes `obs` (bucket and the state each load saw), and the yielded `(bucket, pair)`s `out`.
  A group is any non-empty prefix of the remaining buckets (`IRStep.iterGroup`; Rust's are the
  `W`-chunks), its bytes are loaded one per step in any order (`iterLoad`; group loads can shear),
  and once the group is loaded its full bytes are yielded in index order (`iterYield`, `fulls`).
  Yielding the whole group in one step is exact: between two `next()` calls the iterator touches
  no shared memory, and a full bucket keeps its pair (assumption 1). The padding bytes of the
  static one-bucket table are `EMPTY` and yield nothing, so the model iterates `0 .. n`.
* Starting a call (`Starts`) loads `current` under the reader's pin and adds the table to the
  reader's `held` list (`IStep.start`): the references live for `'a`, until `unpin`. While a call
  of thread `u` is running, `u` cannot unpin (the guard of `IStep.base`: Rust's lifetimes).
* `len`: `lenT` → `lenG` (tombstones loaded) → `lenR` (result). `capacity`: `capT` → `capR`.
* `Clone`: `cloneT` → (`cloneZero`: the static empty table) or (`cloneTomb`: `cloneG`, the
  loaded tombstone count `tb` and, as ghost, the table `T0` at that moment) → `cloneGrowth`
  (`growth_left.load` = `gl`): an iterator with `cl = some (tb, gl, T0)` → `cloneDone`:
  `build C m (dedupK pairs)` for any power-of-two `m` whose capacity is at least
  `max((remaining - gl) * 2, remaining)` with `remaining = capacity - tb` (Rust's
  `capacity_to_buckets` returns such an `m`: `clone_size_rust`). `dedupK` keeps the first pair of
  each key; inserting a key-absent pair with `find_potential` is `insertNew`.
* `Iter::clone` (`IStep.copy`, also used by `Debug for Iter`): a new iterator slot gets an exact
  copy of a running `Read::iter` iterator's state. Its `out` keeps the original's yielded prefix
  (ghost), so the results below are about what the original yielded before the copy plus what
  the copy yields after it (`iter_copy_sound`, `iter_copy_complete`).

Not modelled: panics in `clone`/`hash` (assumption 8).
-/

namespace SyncTable

set_option linter.unusedSectionVars false
set_option linter.deprecated false

variable {K V : Type}

/-- The tables a reader state holds references into (`RS.pinned`'s `h`). -/
def RS.held : RS K V → List Nat
  | .idle => []
  | .pinned _ h => h
  | .probing _ h .. => h
  | .scanning _ h .. => h
  | .returned _ h .. => h

/-- The pair `match_full` yields for a bucket state (any tag that is not `EMPTY`/`DELETED`). -/
def Slot.pair : Slot K V → Option (K × V)
  | .full k v => some (k, v)
  | .mistagged k v => some (k, v)
  | _ => none

/-- The byte loaded for bucket `j` (first entry). -/
def look : List (Nat × Slot K V) → Nat → Option (Slot K V)
  | [], _ => none
  | (i, o) :: l, j => if i = j then some o else look l j

/-- The buckets of a loaded group that `match_full` yields, lowest index first. -/
def fulls (g : List Nat) (obs : List (Nat × Slot K V)) : List (Nat × K × V) :=
  g.filterMap fun j => (look obs j).bind fun o => o.pair.map fun p => (j, p)

/-- Iterator / call state. -/
inductive IR (K V : Type) where
  | idle
  /-- `Read::iter` (or the iteration inside `clone_table_dedup` when `cl = some (tomb, T0)`) by
  thread `u` over table `t` -/
  | iter (u t : Nat) (rest g todo : List Nat) (obs : List (Nat × Slot K V))
      (out : List (Nat × K × V)) (cl : Option (Nat × Nat × Table K V))
  /-- `Read::len` after loading `current = t` -/
  | lenT (u t : Nat)
  /-- `Read::len` after loading `tombstones = tb` -/
  | lenG (u t tb : Nat)
  /-- `Read::len` returned `r` -/
  | lenR (u t r : Nat)
  /-- `Read::capacity` after loading `current = t` -/
  | capT (u t : Nat)
  /-- `Read::capacity` returned `r` -/
  | capR (u t r : Nat)
  /-- `SyncTable::clone` after loading `current = t` -/
  | cloneT (u t : Nat)
  /-- `SyncTable::clone` after loading `tombstones = tb`; ghost `T0`: the table at that load -/
  | cloneG (u t tb : Nat) (T0 : Table K V)
  /-- `SyncTable::clone` built the table `T` (the new `SyncTable`'s `current`) -/
  | cloneR (u : Nat) (T : Table K V)

/-- The thread and table a running call protects with its pin. -/
def IR.tab : IR K V → Option (Nat × Nat)
  | .iter u t .. => some (u, t)
  | .lenT u t | .lenG u t _ | .lenR u t _ | .capT u t | .capR u t _ | .cloneT u t => some (u, t)
  | .cloneG u t _ _ => some (u, t)
  | _ => none

structure ISt (K V : Type) where
  base : St K V
  it : Nat → IR K V

variable [DecidableEq K] (C : Cfg K)

/-- `clone_table_dedup`'s copy loop: keep the first pair of every key. -/
def dedupK : List (K × V) → List (K × V)
  | [] => []
  | p :: l => p :: (dedupK l).filter (fun q => decide (q.1 ≠ p.1))

/-- The calls a pinned thread `u` can start on table `t` (contents `T`) just loaded from
`current`. -/
inductive Starts (u t : Nat) (T : Table K V) : IR K V → Prop
  | iter : Starts u t T (.iter u t (List.range T.n) [] [] [] [] none)
  | len : Starts u t T (.lenT u t)
  | cap : Starts u t T (.capT u t)
  | clone : Starts u t T (.cloneT u t)

/-- One step of a running call; `b` is the base state the loads read. -/
inductive IRStep (b : St K V) : IR K V → IR K V → Prop
  /-- `Group::load_aligned` of the next group starts -/
  | iterGroup (u t : Nat) (g rest : List Nat) out cl : g ≠ [] →
      IRStep b (.iter u t (g ++ rest) [] [] [] out cl) (.iter u t rest g g [] out cl)
  /-- one byte of the group (any order; the loads can shear) -/
  | iterLoad (u t : Nat) (rest g todo : List Nat) obs out cl (j : Nat) : j ∈ todo →
      IRStep b (.iter u t rest g todo obs out cl)
        (.iter u t rest g (todo.erase j) (obs ++ [(j, (b.tables t).slot j)]) out cl)
  /-- `match_full` of the loaded group; its full buckets are yielded in index order -/
  | iterYield (u t : Nat) (rest g : List Nat) obs out cl : g ≠ [] →
      IRStep b (.iter u t rest g [] obs out cl) (.iter u t rest [] [] [] (out ++ fulls g obs) cl)
  /-- `len`: `tombstones.load` -/
  | lenTomb (u t : Nat) : IRStep b (.lenT u t) (.lenG u t (b.tables t).tombstones)
  /-- `len`: `growth_left.load` and the subtraction -/
  | lenGrowth (u t tb : Nat) : IRStep b (.lenG u t tb)
      (.lenR u t (bmc ((b.tables t).n - 1) - tb - (b.tables t).growthLeft))
  /-- `capacity`: `tombstones.load` and the subtraction -/
  | capTomb (u t : Nat) : IRStep b (.capT u t)
      (.capR u t (bmc ((b.tables t).n - 1) - (b.tables t).tombstones))
  /-- `clone_table_dedup`: `tombstones.load`, room left -/
  | cloneTomb (u t : Nat) : 0 < bmc ((b.tables t).n - 1) - (b.tables t).tombstones →
      IRStep b (.cloneT u t) (.cloneG u t (b.tables t).tombstones (b.tables t))
  /-- `clone_table_dedup`: `growth_left.load` (sizes the new table), then the copy iteration -/
  | cloneGrowth (u t tb : Nat) (T0 : Table K V) :
      IRStep b (.cloneG u t tb T0) (.iter u t (List.range (b.tables t).n) [] [] [] []
        (some (tb, (b.tables t).growthLeft, T0)))
  /-- `clone_table_dedup`: no room left: `TableRef::empty()` -/
  | cloneZero (u t : Nat) : bmc ((b.tables t).n - 1) - (b.tables t).tombstones = 0 →
      IRStep b (.cloneT u t) (.cloneR u (emptyTable 1))
  /-- `clone_table_dedup`: the copy loop is done; the new table has `m` buckets. Rust asks
  `capacity_to_buckets` for `max(items * 2, remaining_capacity)` (`items = remaining_capacity -
  growth_left`) and, if that overflows `usize`, for `remaining_capacity` (`cloneBuckets`); either
  way the capacity is at least `remaining_capacity` (`cloneBuckets_ok`), which is all the premise
  keeps -/
  | cloneDone (u t : Nat) obs out (tb gl : Nat) (T0 : Table K V) (m : Nat) :
      m.isPowerOfTwo →
      bmc ((b.tables t).n - 1) - tb ≤ bmc (m - 1) →
      IRStep b (.iter u t [] [] [] obs out (some (tb, gl, T0)))
        (.cloneR u (build C m (dedupK (out.map (·.2)))))
  /-- the iterator is dropped / the result consumed -/
  | drop (r : IR K V) : r ≠ .idle → IRStep b r .idle

inductive IStep : ISt K V → ISt K V → Prop
  /-- a step of the base model; a thread with a running call does not unpin -/
  | base (s : ISt K V) (b' : St K V) : Step C s.base b' →
      (∀ i u t, (s.it i).tab = some (u, t) → b'.rd u ≠ .idle) → IStep s ⟨b', s.it⟩
  /-- a pinned thread loads `current` and starts a call on it; the table joins its `held`
  list (the call's references live as long as the pin) -/
  | start (s : ISt K V) (i u st : Nat) (h : List Nat) (r : IR K V) : s.it i = .idle →
      s.base.rd u = .pinned st h → Starts u s.base.cur (s.base.tables s.base.cur) r →
      IStep s ⟨setRd s.base u (.pinned st (s.base.cur :: h)), upd s.it i r⟩
  | step (s : ISt K V) (i : Nat) (r' : IR K V) : IRStep C s.base (s.it i) r' →
      IStep s ⟨s.base, upd s.it i r'⟩
  /-- `Iter::clone`: slot `i'` gets a copy of the running `Read::iter` iterator in slot `i` -/
  | copy (s : ISt K V) (i i' u t : Nat) (rest g todo : List Nat) obs out :
      s.it i' = .idle → s.it i = .iter u t rest g todo obs out none →
      IStep s ⟨s.base, upd s.it i' (.iter u t rest g todo obs out none)⟩

def iinit : ISt K V := ⟨init, fun _ => .idle⟩

inductive IReach : ISt K V → Prop
  | init : IReach iinit
  | step {s s'} : IReach s → IStep C s s' → IReach s'

/-- A finite run segment from `s` to `s'`; `l` lists every state of it (both ends included). -/
inductive IPath : ISt K V → ISt K V → List (ISt K V) → Prop
  | refl (s) : IPath s s [s]
  | step {s m m' l} : IPath s m l → IStep C m m' → IPath s m' (m' :: l)

/-! ## Evolution of one table -/

/-- How a table can change: same size, counters monotone (`tombstones` up, `growth_left` down),
and a bucket is unchanged, or was `EMPTY`, or was full and is now `DELETED` with the same pair. -/
def Evo (T T' : Table K V) : Prop :=
  T'.n = T.n ∧ T.tombstones ≤ T'.tombstones ∧ T'.growthLeft ≤ T.growthLeft ∧
    ∀ j, T'.slot j = T.slot j ∨ T.slot j = .empty ∨
      ∃ k v, (T.slot j).pair = some (k, v) ∧ T'.slot j = .deleted k v

theorem evo_refl (T : Table K V) : Evo T T :=
  ⟨rfl, Nat.le_refl _, Nat.le_refl _, fun _ => .inl rfl⟩

theorem evo_trans {T1 T2 T3 : Table K V} (h1 : Evo T1 T2) (h2 : Evo T2 T3) : Evo T1 T3 := by
  refine ⟨h2.1.trans h1.1, Nat.le_trans h1.2.1 h2.2.1, Nat.le_trans h2.2.2.1 h1.2.2.1,
    fun j => ?_⟩
  rcases h1.2.2.2 j with e1 | e1 | ⟨k, v, p1, d1⟩
  · rcases h2.2.2.2 j with e2 | e2 | ⟨k', v', p2, d2⟩
    · exact .inl (e2.trans e1)
    · exact .inr (.inl (e1 ▸ e2))
    · exact .inr (.inr ⟨k', v', e1 ▸ p2, d2⟩)
  · exact .inr (.inl e1)
  · rcases h2.2.2.2 j with e2 | e2 | ⟨k', v', p2, d2⟩
    · exact .inr (.inr ⟨k, v, p1, e2.trans d1⟩)
    · rw [d1] at e2; cases e2
    · rw [d1] at p2; cases p2

/-- A bucket that is not `EMPTY` stays not `EMPTY`. -/
theorem Evo.ne_empty {T T' : Table K V} (h : Evo T T') {j : Nat} (hj : T.slot j ≠ .empty) :
    T'.slot j ≠ .empty := by
  rcases h.2.2.2 j with e | e | ⟨k, v, _, d⟩
  · rw [e]; exact hj
  · exact absurd e hj
  · rw [d]; simp

/-- A `DELETED` bucket stays `DELETED`. -/
theorem Evo.del {T T' : Table K V} (h : Evo T T') {j : Nat} (hj : (T.slot j).isDel = true) :
    T'.slot j = T.slot j := by
  rcases h.2.2.2 j with e | e | ⟨k, v, p, _⟩
  · exact e
  · rw [e] at hj; cases hj
  · revert hj p; cases T.slot j <;> simp [Slot.isDel, Slot.pair]

/-- A full bucket of `(k, v)` stays full of `(k, v)` or becomes a tombstone of it. -/
theorem Evo.full {T T' : Table K V} (h : Evo T T') {j : Nat} {k : K} {v : V}
    (hj : T.slot j = .full k v) : T'.slot j = .full k v ∨ T'.slot j = .deleted k v := by
  rcases h.2.2.2 j with e | e | ⟨k', v', p, d⟩
  · exact .inl (e.trans hj)
  · rw [hj] at e; cases e
  · rw [hj] at p; cases p; exact .inr d

theorem evo_set {T : Table K V} {i : Nat} {o : Slot K V}
    (hi : T.slot i = .empty ∨ ∃ k v, (T.slot i).pair = some (k, v) ∧ o = .deleted k v) :
    ∀ j, (T.set i o).slot j = T.slot j ∨ T.slot j = .empty ∨
      ∃ k v, (T.slot j).pair = some (k, v) ∧ (T.set i o).slot j = .deleted k v := by
  intro j
  show (if j = i then o else T.slot j) = _ ∨ _ ∨ ∃ k v, _ ∧ (if j = i then o else T.slot j) = _
  by_cases e : j = i
  · subst e; simp only [ite_true]
    rcases hi with hi | ⟨k, v, p, rfl⟩
    · exact .inr (.inl hi)
    · exact .inr (.inr ⟨k, v, p, rfl⟩)
  · exact .inl (if_neg e)

section
set_option linter.unusedSectionVars false

theorem evo_insertAt {T : Table K V} {i : Nat} {k : K} {v : V} (he : T.slot i = .empty) :
    Evo T (insertAt T i k v) :=
  ⟨rfl, Nat.le_refl _, Nat.sub_le _ _, evo_set (.inl he)⟩

theorem evo_insertMis {T : Table K V} {i : Nat} {k : K} {v : V} (he : T.slot i = .empty) :
    Evo T (insertMis T i k v) :=
  ⟨rfl, Nat.le_refl _, Nat.sub_le _ _, evo_set (.inl he)⟩

theorem evo_removeAt {T : Table K V} {i : Nat} {k : K} {v : V} (hp : (T.slot i).pair = some (k, v)) :
    Evo T (removeAt T i k v) :=
  ⟨rfl, Nat.le_succ _, Nat.le_refl _, evo_set (.inr ⟨k, v, hp, rfl⟩)⟩

theorem evo_commit {s : St K V} {T' : Table K V} (h : Evo (s.tables s.cur) T') (t : Nat) :
    Evo (s.tables t) ((commit s T').tables t) := by
  show Evo _ (upd s.tables s.cur T' t)
  by_cases e : t = s.cur
  · subst e; rw [upd_same]; exact h
  · rw [upd_other _ _ _ _ e]; exact evo_refl _

/-- Every base step changes an allocated table only as `Evo` allows. -/
theorem step_evo {s s' : St K V} (hs : Step C s s') {t : Nat} (ht : t < s.nextId)
    (hf : s.ts t ≠ .freed) :
    Evo (s.tables t) (s'.tables t) := by
  cases hs with
  | insert k v i _ hfe => exact evo_commit (evo_insertAt (firstEmpty_spec hfe).1) t
  | insertAny k v i _ he _ => exact evo_commit (evo_insertAt he) t
  | insertMis k v i _ he _ => exact evo_commit (evo_insertMis he) t
  | remove k v i hi => exact evo_commit (evo_removeAt (by rw [hi]; rfl)) t
  | removeMis k v i hi => exact evo_commit (evo_removeAt (by rw [hi]; rfl)) t
  | expand m _ _ => rw [show (swap s _ false).tables t = s.tables t from
      publish_tables_lt false (swap_pub _ _) ht hf]; exact evo_refl _
  | replace m l _ _ => rw [show (swap s _ true).tables t = s.tables t from
      publish_tables_lt true (swap_pub _ _) ht hf]; exact evo_refl _
  | replaceEmpty => rw [show (swapEmpty s).tables t = s.tables t from
      publish_tables_lt true (swapEmpty_pub s) ht hf]; exact evo_refl _
  | expandAt m a ha _ _ => rw [show (swapAt s a _ false).tables t = s.tables t from
      publish_tables_lt false (swapAt_pub _ ha) ht hf]; exact evo_refl _
  | replaceAt m a l ha _ _ => rw [show (swapAt s a _ true).tables t = s.tables t from
      publish_tables_lt true (swapAt_pub _ ha) ht hf]; exact evo_refl _
  | _ => exact evo_refl _

/-- `nextId` never decreases. -/
theorem step_nextId {s s' : St K V} (hs : Step C s s') : s.nextId ≤ s'.nextId := by
  cases hs with
  | expand => exact Nat.le_succ _
  | replace => exact Nat.le_succ _
  | replaceEmpty => exact Nat.le_refl _
  | _ => exact Nat.le_refl _

/-! ## Held tables -/

theorem held_setRd (s : St K V) (u u' : Nat) (r : RS K V) :
    ((setRd s u r).rd u').held = if u' = u then r.held else (s.rd u').held := by
  show (upd s.rd u r u').held = _
  by_cases e : u' = u
  · subst e; simp
  · rw [upd_other _ _ _ _ e, if_neg e]

/-- A base step keeps every held table of a thread that does not unpin. -/
theorem step_held {s s' : St K V} (hs : Step C s s') {u t : Nat} (ht : t ∈ (s.rd u).held)
    (hne : s'.rd u ≠ .idle) : t ∈ (s'.rd u).held := by
  cases hs with
  | pin u' hu =>
    show t ∈ (upd s.rd u' _ u).held
    by_cases e : u = u'
    · subst e; rw [hu] at ht; cases ht
    · rw [upd_other _ _ _ _ e]; exact ht
  | unpin u' st h hu =>
    show t ∈ (upd s.rd u' _ u).held
    by_cases e : u = u'
    · subst e; exact absurd (upd_same _ _ _) hne
    · rw [upd_other _ _ _ _ e]; exact ht
  | load u' st h k hu =>
    rw [held_setRd]; split
    · rename_i e; subst e; rw [hu] at ht; exact ht
    · exact ht
  | probeGroup u' st h k t' lv pre g rest hu _ =>
    rw [held_setRd]; split
    · rename_i e; subst e; rw [hu] at ht; exact ht
    · exact ht
  | scanLoad u' st h k t' lv pre g todo obs rest j hu _ =>
    rw [held_setRd]; split
    · rename_i e; subst e; rw [hu] at ht; exact ht
    · exact ht
  | scanHit u' st h k t' lv pre g obs rest j v hu _ =>
    rw [held_setRd]; split
    · rename_i e; subst e; rw [hu] at ht; exact ht
    · exact ht
  | scanEmpty u' st h k t' lv pre g obs rest j hu _ _ =>
    rw [held_setRd]; split
    · rename_i e; subst e; rw [hu] at ht; exact ht
    · exact ht
  | scanNext u' st h k t' lv pre g obs rest hu _ _ =>
    rw [held_setRd]; split
    · rename_i e; subst e; rw [hu] at ht; exact ht
    · exact ht
  | probeEnd u' st h k t' lv pre hu =>
    rw [held_setRd]; split
    · rename_i e; subst e; rw [hu] at ht; exact ht
    · exact ht
  | finish u' st h k t' lv r hu =>
    rw [held_setRd]; split
    · rename_i e; subst e; rw [hu] at ht; exact List.mem_cons_of_mem _ ht
    · exact ht
  | _ => exact ht

/-- A held table is one the reader may dereference. -/
theorem srinv_held {s : St K V} {r : RS K V} (h : SRInv C s r) {t : Nat} (ht : t ∈ r.held) :
    ∃ st, Holds s st t := by
  cases r with
  | idle => cases ht
  | pinned st hl => exact ⟨st, h.2 t ht⟩
  | probing st hl k t' lv pre rest => exact ⟨st, h.2.1 t ht⟩
  | scanning st hl k t' lv pre g todo obs rest => exact ⟨st, h.2.1 t ht⟩
  | returned st hl k t' lv r => exact ⟨st, h.2.1 t ht⟩

theorem held_lt {s : St K V} (h : SInv C s) {u t : Nat} (ht : t ∈ (s.rd u).held) :
    t < s.nextId := by
  obtain ⟨_, h1, _⟩ := srinv_held C (h.rd u) ht; exact h1

theorem held_nf {s : St K V} (h : SInv C s) {u t : Nat} (ht : t ∈ (s.rd u).held) :
    s.ts t ≠ .freed := by
  obtain ⟨_, h1⟩ := srinv_held C (h.rd u) ht; exact h1.nf

end

/-! ## Lists -/

section
set_option linter.unusedSectionVars false

theorem look_mem {obs : List (Nat × Slot K V)} {j : Nat} {o : Slot K V} (h : look obs j = some o) :
    (j, o) ∈ obs := by
  induction obs with
  | nil => cases h
  | cons p l ih =>
    obtain ⟨i, o'⟩ := p
    simp only [look] at h; split at h
    · rename_i e; subst e; cases h; exact List.mem_cons_self
    · exact List.mem_cons_of_mem _ (ih h)

theorem look_some {obs : List (Nat × Slot K V)} {j : Nat} {o : Slot K V} (h : (j, o) ∈ obs) :
    ∃ o', look obs j = some o' := by
  induction obs with
  | nil => cases h
  | cons p l ih =>
    obtain ⟨i, o'⟩ := p
    simp only [look]; split
    · exact ⟨_, rfl⟩
    · rename_i e; rcases List.mem_cons.1 h with h | h
      · cases h; exact absurd rfl e
      · exact ih h

theorem mem_fulls {g : List Nat} {obs : List (Nat × Slot K V)} {p : Nat × K × V}
    (h : p ∈ fulls g obs) : p.1 ∈ g ∧ ∃ o, (p.1, o) ∈ obs ∧ o.pair = some p.2 := by
  unfold fulls at h
  obtain ⟨j, hj, e⟩ := List.mem_filterMap.1 h
  cases hl : look obs j with
  | none => rw [hl] at e; cases e
  | some o =>
    rw [hl] at e
    cases hp : o.pair with
    | none => simp [hp] at e
    | some q =>
      simp [hp] at e; subst e
      exact ⟨hj, o, look_mem hl, hp⟩

theorem fulls_sub (g : List Nat) (obs : List (Nat × Slot K V)) :
    ((fulls g obs).map (·.1)).Sublist g := by
  unfold fulls
  induction g with
  | nil => exact List.Sublist.slnil
  | cons j g ih =>
    have key : ∀ (a : Option (Slot K V)) q,
        (a.bind fun o => o.pair.map fun p => (j, p)) = some q → q.1 = j := by
      intro a q h; cases a with
      | none => cases h
      | some o =>
        cases hp : o.pair with
        | none => simp [hp] at h
        | some r => simp [hp] at h; subst h; rfl
    simp only [List.filterMap_cons]
    split
    · exact ih.cons _
    · rename_i q hq
      rw [List.map_cons, key _ _ hq]; exact ih.cons₂ _

theorem len_le_of_nodup : ∀ (L M : List Nat), L.Nodup → (∀ x ∈ L, x ∈ M) → L.length ≤ M.length
  | [], _, _, _ => Nat.zero_le _
  | a :: L, M, hn, hs => by
    have ha : a ∈ M := hs a List.mem_cons_self
    have hn' := List.nodup_cons.1 hn
    have := len_le_of_nodup L (M.erase a) hn'.2 (fun x hx =>
      (List.mem_erase_of_ne (fun (e : x = a) => hn'.1 (e ▸ hx))).2 (hs x (List.mem_cons_of_mem _ hx)))
    rw [List.length_erase_of_mem ha] at this
    have : 0 < M.length := List.length_pos_of_mem ha
    simp only [List.length_cons]; omega

theorem cnt_eq_filter (p : Slot K V → Bool) (f : Nat → Slot K V) (n : Nat) :
    cnt p f n = ((List.range n).filter (fun j => p (f j))).length := by
  induction n with
  | zero => rfl
  | succ n ih =>
    rw [List.range_succ, List.filter_append, List.length_append, ← ih]
    simp only [cnt, List.filter_cons, List.filter_nil]
    split <;> simp_all

end

/-! ## The invariant -/

/-- Clone bookkeeping: `T0` is the table at the moment `tombstones = tb` was loaded; every byte
loaded full and every yielded bucket was not a tombstone then, and is not `EMPTY` now. -/
def CloneInv (T : Table K V) (obs : List (Nat × Slot K V)) (out : List (Nat × K × V)) :
    Option (Nat × Nat × Table K V) → Prop
  | none => True
  | some (tb, gl, T0) => T0.tombstones = tb ∧ SWF T0 ∧ Evo T0 T ∧
      0 < bmc (T0.n - 1) - tb ∧ tb + gl ≤ bmc (T0.n - 1) ∧
      (∀ j o, (j, o) ∈ obs → o.pair ≠ none → (T0.slot j).isDel = false ∧ T.slot j ≠ .empty) ∧
      (∀ p ∈ out, (T0.slot p.1).isDel = false ∧ T.slot p.1 ≠ .empty)

def IRInv (b : St K V) : IR K V → Prop
  | .idle => True
  | .iter u t rest g todo obs out cl => t ∈ (b.rd u).held ∧
      (out.map (·.1) ++ g ++ rest).Sublist (List.range (b.tables t).n) ∧
      (∀ j ∈ todo, j ∈ g) ∧ (∀ j ∈ g, j ∈ todo ∨ ∃ o, (j, o) ∈ obs) ∧
      (∀ j o, (j, o) ∈ obs → j ∈ g) ∧ CloneInv (b.tables t) obs out cl
  | .lenT u t | .lenG u t _ | .lenR u t _ | .capT u t | .capR u t _ | .cloneT u t =>
      t ∈ (b.rd u).held
  | .cloneG u t tb T0 => t ∈ (b.rd u).held ∧ T0.tombstones = tb ∧ SWF T0 ∧
      Evo T0 (b.tables t) ∧ 0 < bmc (T0.n - 1) - tb
  | .cloneR _ T => WF C T

structure IInv (s : ISt K V) : Prop where
  sinv : SInv C s.base
  it : ∀ i, IRInv C s.base (s.it i)

theorem irinv_held {b : St K V} {r : IR K V} (h : IRInv C b r) {u t : Nat}
    (ht : r.tab = some (u, t)) : t ∈ (b.rd u).held := by
  cases r <;> simp only [IR.tab, Option.some.injEq, Prod.mk.injEq, reduceCtorEq] at ht <;>
    obtain ⟨rfl, rfl⟩ := ht <;> first | exact h.1 | exact h

theorem cloneInv_frame {T T' : Table K V} {obs : List (Nat × Slot K V)} {out : List (Nat × K × V)}
    {cl : Option (Nat × Nat × Table K V)} (h : CloneInv T obs out cl) (he : Evo T T') :
    CloneInv T' obs out cl := by
  cases cl with
  | none => trivial
  | some p =>
    obtain ⟨tb, gl, T0⟩ := p
    obtain ⟨c1, c2, c3, c6, c7, c4, c5⟩ := h
    exact ⟨c1, c2, evo_trans c3 he, c6, c7,
      fun j o hj hp => ⟨(c4 j o hj hp).1, he.ne_empty (c4 j o hj hp).2⟩,
      fun p hp => ⟨(c5 p hp).1, he.ne_empty (c5 p hp).2⟩⟩

theorem irinv_frame {b b' : St K V} {r : IR K V} (h : IRInv C b r)
    (hk : ∀ u t, r.tab = some (u, t) → t ∈ (b'.rd u).held ∧ Evo (b.tables t) (b'.tables t)) :
    IRInv C b' r := by
  cases r with
  | idle => trivial
  | iter u t rest g todo obs out cl =>
    obtain ⟨hh, he⟩ := hk u t rfl
    obtain ⟨_, hs, h2, h3, h4, hc⟩ := h
    exact ⟨hh, by rw [he.1]; exact hs, h2, h3, h4, cloneInv_frame hc he⟩
  | lenT u t => exact (hk u t rfl).1
  | lenG u t _ => exact (hk u t rfl).1
  | lenR u t _ => exact (hk u t rfl).1
  | capT u t => exact (hk u t rfl).1
  | capR u t _ => exact (hk u t rfl).1
  | cloneT u t => exact (hk u t rfl).1
  | cloneG u t tb T0 =>
    obtain ⟨hh, he⟩ := hk u t rfl
    exact ⟨hh, h.2.1, h.2.2.1, evo_trans h.2.2.2.1 he, h.2.2.2.2⟩
  | cloneR => exact h

/-- **`clone_table_dedup` never overfills its new table**: the copy loop yields at most
`capacity - tombstones` pairs (with `tombstones` the value it loaded), since every yielded bucket
was not a tombstone at that load and the tombstones then stay tombstones. -/
theorem clone_bound {T T0 : Table K V} {obs : List (Nat × Slot K V)} {out : List (Nat × K × V)}
    {g rest : List Nat} {tb gl : Nat}
    (hs : (out.map (·.1) ++ g ++ rest).Sublist (List.range T.n))
    (hc : CloneInv T obs out (some (tb, gl, T0))) (hw : SWF T) :
    out.length ≤ bmc (T.n - 1) - tb := by
  obtain ⟨c1, c2, c3, _, _, _, c5⟩ := hc
  have hnd : (out.map (·.1)).Nodup :=
    ((List.sublist_append_left _ _).trans ((List.sublist_append_left _ _).trans hs)).nodup
      List.nodup_range
  have hsub : ∀ j ∈ out.map (·.1), j < T.n := fun j hj =>
    List.mem_range.1 (hs.subset (List.mem_append_left _ (List.mem_append_left _ hj)))
  have hnd2 : (out.map (·.1) ++ (List.range T.n).filter (fun j => (T0.slot j).isDel)).Nodup := by
    refine List.nodup_append.2 ⟨hnd, List.nodup_range.filter _, ?_⟩
    intro a ha b hb e; subst e
    obtain ⟨p, hp, rfl⟩ := List.mem_map.1 ha
    have := (List.mem_filter.1 hb).2
    rw [(c5 p hp).1] at this; cases this
  have hle := len_le_of_nodup _ ((List.range T.n).filter (fun j => notEmpty (T.slot j))) hnd2
    (by
      intro x hx
      rcases List.mem_append.1 hx with hx | hx
      · obtain ⟨p, hp, rfl⟩ := List.mem_map.1 hx
        refine List.mem_filter.2 ⟨List.mem_range.2 (hsub _ (List.mem_map_of_mem hp)), ?_⟩
        have := (c5 p hp).2
        revert this; cases T.slot p.1 <;> simp [notEmpty, Slot.isEmpty]
      · have hx' := List.mem_filter.1 hx
        refine List.mem_filter.2 ⟨hx'.1, ?_⟩
        rw [c3.del hx'.2]
        have := hx'.2; revert this; cases T0.slot x <;> simp [notEmpty, Slot.isEmpty, Slot.isDel])
  have hcD : ((List.range T.n).filter (fun j => (T0.slot j).isDel)).length = tb := by
    rw [← c1, ← c2.tomb, cnt_eq_filter, c3.1]
  have hcM := cnt_eq_filter notEmpty T.slot T.n
  have := hw.count
  simp only [List.length_append, List.length_map] at hle
  omega

theorem swf_items {T : Table K V} (hw : SWF T) :
    (items T).length + T.tombstones + T.growthLeft = bmc (T.n - 1) := by
  rw [items_length]; have := cnt_split T.slot T.n; have := hw.count; have := hw.tomb; omega

theorem dedupK_length : ∀ l : List (K × V), (dedupK l).length ≤ l.length
  | [] => Nat.le_refl _
  | p :: l => by
    simp only [dedupK, List.length_cons]
    exact Nat.succ_le_succ (Nat.le_trans (List.length_filter_le _ _) (dedupK_length l))

theorem fresh_irinv {b : St K V} {u t : Nat} {r : IR K V} (hh : t ∈ (b.rd u).held)
    (hs : Starts u t (b.tables t) r) : IRInv C b r := by
  cases hs with
  | iter => exact ⟨hh, by simp, (fun _ h => nomatch h),
      (fun _ h => nomatch h), (fun _ _ h => nomatch h), trivial⟩
  | len => exact hh
  | cap => exact hh
  | clone => exact hh

theorem irstep_irinv (hcov : C.Cover) {b : St K V} {r r' : IR K V} (hs : SInv C b)
    (h : IRInv C b r) (hr : IRStep C b r r') : IRInv C b r' := by
  cases hr with
  | iterGroup u t g rest out cl hg =>
    obtain ⟨hh, hsub, _, _, _, hc⟩ := h
    exact ⟨hh, by simpa using hsub, fun j hj => hj, fun j hj => .inl hj,
      (fun _ _ h => nomatch h), hc⟩
  | iterLoad u t rest g todo obs out cl j hj =>
    obtain ⟨hh, hsub, h2, h3, h4, hc⟩ := h
    refine ⟨hh, hsub, fun x hx => h2 x (List.mem_of_mem_erase hx), fun x hx => ?_,
      fun x o hx => ?_, ?_⟩
    · by_cases e : x = j
      · subst e; exact .inr ⟨_, List.mem_append_right _ List.mem_cons_self⟩
      · rcases h3 x hx with h | ⟨o, ho⟩
        · exact .inl ((List.mem_erase_of_ne e).2 h)
        · exact .inr ⟨o, List.mem_append_left _ ho⟩
    · rcases List.mem_append.1 hx with hx | hx
      · exact h4 x o hx
      · simp at hx; rw [hx.1]; exact h2 j hj
    · cases cl with
      | none => trivial
      | some p =>
        obtain ⟨tb, gl, T0⟩ := p
        obtain ⟨c1, c2, c3, c6, c7, c4, c5⟩ := hc
        refine ⟨c1, c2, c3, c6, c7, fun x o hx hp => ?_, c5⟩
        rcases List.mem_append.1 hx with hx | hx
        · exact c4 x o hx hp
        · simp at hx; obtain ⟨rfl, rfl⟩ := hx
          refine ⟨?_, fun e => by rw [e] at hp; exact hp rfl⟩
          rcases c3.2.2.2 x with e | e | ⟨k, v, _, d⟩
          · rw [← e]; revert hp; cases (b.tables t).slot x <;> simp [Slot.pair, Slot.isDel]
          · rw [e]; rfl
          · rw [d] at hp; exact absurd rfl hp
  | iterYield u t rest g obs out cl hg =>
    obtain ⟨hh, hsub, _, h3, h4, hc⟩ := h
    refine ⟨hh, ?_, (fun _ h => nomatch h), (fun _ h => nomatch h), (fun _ _ h => nomatch h), ?_⟩
    · refine List.Sublist.trans ?_ hsub
      simp only [List.map_append, List.append_nil, List.append_assoc]
      exact (List.Sublist.refl _).append ((fulls_sub g obs).append (List.Sublist.refl _))
    · cases cl with
      | none => trivial
      | some p =>
        obtain ⟨tb, gl, T0⟩ := p
        obtain ⟨c1, c2, c3, c6, c7, c4, c5⟩ := hc
        refine ⟨c1, c2, c3, c6, c7, (fun _ _ h => nomatch h), fun p hp => ?_⟩
        rcases List.mem_append.1 hp with hp | hp
        · exact c5 p hp
        · obtain ⟨_, o, ho, hpo⟩ := mem_fulls hp
          exact c4 _ o ho (by rw [hpo]; simp)
  | lenTomb => exact h
  | lenGrowth => exact h
  | capTomb => exact h
  | cloneTomb u t hpos =>
    exact ⟨h, rfl, hs.swf t (held_lt C hs h), evo_refl _, hpos⟩
  | cloneGrowth u t tb T0 =>
    obtain ⟨hh, c1, c2, c3, c4⟩ := h
    have a := swf_items (hs.swf t (held_lt C hs hh))
    have hn := c3.1; have hto := c3.2.1
    exact ⟨hh, by simp, (fun _ h => nomatch h), (fun _ h => nomatch h),
      (fun _ _ h => nomatch h), c1, c2, c3, c4, by rw [← hn]; omega,
      (fun _ _ h => nomatch h), (fun _ h => nomatch h)⟩
  | cloneZero => exact emptyTable_wf C 1 ⟨0, rfl⟩
  | cloneDone u t obs out tb gl T0 m hm hcap =>
    obtain ⟨hh, hsub, _, _, _, hc⟩ := h
    have hb := clone_bound hsub hc (hs.swf t (held_lt C hs hh))
    refine (build_wf C hcov m hm _ ?_).1
    exact Nat.le_trans (dedupK_length _) (by simp; omega)
  | drop => trivial

theorem istep_iinv (hcov : C.Cover) {s s' : ISt K V} (h : IInv C s) (hs : IStep C s s') :
    IInv C s' := by
  cases hs with
  | base b' hb hg =>
    refine ⟨sinv_step C hcov h.sinv hb, fun i => irinv_frame C (h.it i) fun u t ht => ?_⟩
    have hh := irinv_held C (h.it i) ht
    exact ⟨step_held C hb hh (hg i u t ht), step_evo C hb (held_lt C h.sinv hh) (held_nf C h.sinv hh)⟩
  | start i u st hl r hi hu hst =>
    have hr := h.sinv.rd u; rw [hu] at hr
    have hcur : ∀ t ∈ s.base.cur :: hl, Holds s.base st t := by
      intro t ht; rcases List.mem_cons.1 ht with rfl | ht
      · exact ⟨h.sinv.curLt, .inl h.sinv.curLive⟩
      · exact hr.2 t ht
    refine ⟨sinv_setRd C h.sinv u _ ⟨hr.1, hcur⟩, fun i' => ?_⟩
    show IRInv C _ (upd s.it i r i')
    by_cases e : i' = i
    · subst e; rw [upd_same]
      exact fresh_irinv C (by rw [held_setRd, if_pos rfl]; exact List.mem_cons_self) hst
    · rw [upd_other _ _ _ _ e]
      refine irinv_frame C (h.it i') fun u' t ht => ⟨?_, evo_refl _⟩
      have hh := irinv_held C (h.it i') ht
      rw [held_setRd]; split
      · rename_i e'; subst e'; rw [hu] at hh; exact List.mem_cons_of_mem _ hh
      · exact hh
  | step i r' hr' =>
    refine ⟨h.sinv, fun i' => ?_⟩
    show IRInv C _ (upd s.it i r' i')
    by_cases e : i' = i
    · subst e; rw [upd_same]; exact irstep_irinv C hcov h.sinv (h.it i') hr'
    · rw [upd_other _ _ _ _ e]; exact h.it i'
  | copy i i' u t rest g todo obs out _ hi =>
    refine ⟨h.sinv, fun x => ?_⟩
    show IRInv C _ (upd s.it i' _ x)
    by_cases e : x = i'
    · subst e; rw [upd_same]; have := h.it i; rw [hi] at this; exact this
    · rw [upd_other _ _ _ _ e]; exact h.it x

theorem ireach_iinv (hcov : C.Cover) {s : ISt K V} (h : IReach C s) : IInv C s := by
  induction h with
  | init => exact ⟨sinv_init C, fun _ => trivial⟩
  | step _ hs ih => exact istep_iinv C hcov ih hs

/-! ## Memory safety -/

/-- **No use-after-free for iterators, `len`, `capacity` and `Clone`.** While a call is running
(and an iterator is alive), the table it loaded from `current` is allocated and not freed, even
after writers replaced it, and the reader's pin protects it (`Holds`). An iterator only loads
control bytes of buckets `< n` of that table. -/
theorem iter_no_use_after_free (hcov : C.Cover) {s : ISt K V} (h : IReach C s) (i u t : Nat)
    (ht : (s.it i).tab = some (u, t)) :
    s.base.ts t ≠ .freed ∧ s.base.ts t ≠ .unalloc ∧ ∃ st, Holds s.base st t := by
  have hi := ireach_iinv C hcov h
  obtain ⟨st, h1, h2⟩ := srinv_held C (hi.sinv.rd u) (irinv_held C (hi.it i) ht)
  refine ⟨?_, ?_, st, h1, h2⟩ <;> rcases h2 with h2 | ⟨v, d, h2, _⟩ <;> rw [h2] <;> simp

theorem iter_in_bounds (hcov : C.Cover) {s : ISt K V} (h : IReach C s) {i u t : Nat}
    {rest g todo : List Nat} {obs : List (Nat × Slot K V)} {out : List (Nat × K × V)}
    {cl : Option (Nat × Nat × Table K V)} (hit : s.it i = .iter u t rest g todo obs out cl) :
    ∀ j ∈ todo, j < (s.base.tables t).n := by
  have hi := (ireach_iinv C hcov h).it i; rw [hit] at hi
  intro j hj
  exact List.mem_range.1 (hi.2.1.subset
    (List.mem_append_left _ (List.mem_append_right _ (hi.2.2.1 j hj))))

/-- **No bucket is yielded twice** by one iterator, and buckets come in increasing index order
(`RawIterRange` walks the control bytes once, front to back). Keys can repeat: see `MAPPING.md`
(a key removed after it was yielded and re-inserted into a later bucket is yielded again). -/
theorem iter_buckets_increasing (hcov : C.Cover) {s : ISt K V} (h : IReach C s) {i u t : Nat}
    {rest g todo : List Nat} {obs : List (Nat × Slot K V)} {out : List (Nat × K × V)}
    {cl : Option (Nat × Nat × Table K V)} (hit : s.it i = .iter u t rest g todo obs out cl) :
    (out.map (·.1)).Pairwise (· < ·) := by
  have hi := (ireach_iinv C hcov h).it i; rw [hit] at hi
  exact List.pairwise_lt_range.sublist
    ((List.sublist_append_left _ _).trans ((List.sublist_append_left _ _).trans hi.2.1))

/-! ## Run segments -/

theorem ipath_last {s s1 : ISt K V} {l : List (ISt K V)} (hp : IPath C s s1 l) : s1 ∈ l := by
  cases hp with
  | refl => exact List.mem_singleton_self _
  | step => exact List.mem_cons_self

theorem ipath_reach {s s1 : ISt K V} {l : List (ISt K V)} (h : IReach C s) (hp : IPath C s s1 l) :
    ∀ m ∈ l, IReach C m := by
  induction hp with
  | refl => intro m hm; rw [List.mem_singleton.1 hm]; exact h
  | step hp hs ih =>
    intro m hm
    rcases List.mem_cons.1 hm with rfl | hm
    · exact .step (ih _ (ipath_last C hp)) hs
    · exact ih m hm

theorem istep_evo {s s' : ISt K V} (hs : IStep C s s') {t : Nat} (ht : t < s.base.nextId)
    (hf : s.base.ts t ≠ .freed) :
    Evo (s.base.tables t) (s'.base.tables t) ∧ s.base.nextId ≤ s'.base.nextId := by
  cases hs with
  | base b' hb _ => exact ⟨step_evo C hb ht hf, step_nextId C hb⟩
  | start => exact ⟨evo_refl _, Nat.le_refl _⟩
  | step => exact ⟨evo_refl _, Nat.le_refl _⟩
  | copy => exact ⟨evo_refl _, Nat.le_refl _⟩

/-- Along a run segment, every state's table `t` evolves (`Evo`) from the first state's and into
the last state's. -/
theorem ipath_evo {s s1 : ISt K V} {l : List (ISt K V)} (hp : IPath C s s1 l) {t : Nat}
    (ht : t < s.base.nextId) (hnf : ∀ m ∈ l, m.base.ts t ≠ .freed) :
    ∀ m ∈ l, t < m.base.nextId ∧ Evo (s.base.tables t) (m.base.tables t) ∧
      Evo (m.base.tables t) (s1.base.tables t) := by
  revert hnf
  induction hp with
  | refl => intro _ m hm; rw [List.mem_singleton.1 hm]; exact ⟨ht, evo_refl _, evo_refl _⟩
  | step hp hs ih =>
    rename_i m0 m1 _
    intro hnf
    have ih := ih fun x hx => hnf x (List.mem_cons_of_mem _ hx)
    have ⟨hl1, hl2, _⟩ := ih m0 (ipath_last C hp)
    have ⟨he, hn⟩ := istep_evo C hs hl1 (hnf m0 (List.mem_cons_of_mem _ (ipath_last C hp)))
    intro m hm
    rcases List.mem_cons.1 hm with rfl | hm
    · exact ⟨Nat.lt_of_lt_of_le hl1 hn, evo_trans hl2 he, evo_refl _⟩
    · have ⟨h1, h2, h3⟩ := ih m hm
      exact ⟨h1, h2, evo_trans h3 he⟩

/-! ## Weak consistency of the iterator -/

/-- How one `IStep` changes call `i`: not at all, by one `IRStep` reading the pre-state, or by a
start from `idle`. -/
theorem istep_it {s s' : ISt K V} (hs : IStep C s s') (i : Nat) :
    s'.it i = s.it i ∨ (∃ r', IRStep C s.base (s.it i) r' ∧ s'.it i = r') ∨ s.it i = .idle := by
  cases hs with
  | base => exact .inl rfl
  | start i' u st h r hi _ _ =>
    by_cases e : i = i'
    · subst e; exact .inr (.inr hi)
    · exact .inl (upd_other _ _ _ _ e)
  | step i' r' hr =>
    by_cases e : i = i'
    · subst e; exact .inr (.inl ⟨r', hr, upd_same _ _ _⟩)
    · exact .inl (upd_other _ _ _ _ e)
  | copy i0 i' u t rest g todo obs out hi' _ =>
    by_cases e : i = i'
    · subst e; exact .inr (.inr hi')
    · exact .inl (upd_other _ _ _ _ e)

/-- Soundness bookkeeping along a segment, from any iterator state whose loaded bytes and yielded
pairs are already witnessed by earlier states `L0` (for a fresh iterator `L0 = []`). -/
theorem iter_path_sound {s0 s1 : ISt K V} {l : List (ISt K V)} (hp : IPath C s0 s1 l)
    {i u t : Nat} {cl : Option (Nat × Nat × Table K V)} {L0 : List (ISt K V)}
    {rest0 g0 todo0 : List Nat} {obs0 : List (Nat × Slot K V)} {out0 : List (Nat × K × V)}
    (hstart : s0.it i = .iter u t rest0 g0 todo0 obs0 out0 cl)
    (H0 : (∀ p ∈ out0, ∃ m ∈ L0, ((m.base.tables t).slot p.1).pair = some p.2) ∧
      (∀ j o, (j, o) ∈ obs0 → ∃ m ∈ L0, (m.base.tables t).slot j = o)) :
    (∀ m ∈ l, ∃ rest g todo obs out, m.it i = .iter u t rest g todo obs out cl) →
    ∀ rest g todo obs out, s1.it i = .iter u t rest g todo obs out cl →
      (∀ p ∈ out, ∃ m ∈ L0 ++ l, ((m.base.tables t).slot p.1).pair = some p.2) ∧
      (∀ j o, (j, o) ∈ obs → ∃ m ∈ L0 ++ l, (m.base.tables t).slot j = o) := by
  induction hp with
  | refl =>
    intro _ rest g todo obs out he
    rw [hstart] at he; cases he
    exact ⟨fun p hp => let ⟨x, hx, h⟩ := H0.1 p hp; ⟨x, List.mem_append_left _ hx, h⟩,
      fun j o hj => let ⟨x, hx, h⟩ := H0.2 j o hj; ⟨x, List.mem_append_left _ hx, h⟩⟩
  | step hp hs ih =>
    rename_i m m' l
    intro hrun rest g todo obs out he
    have lift : ∀ {P : ISt K V → Prop}, (∃ x ∈ L0 ++ l, P x) → ∃ x ∈ L0 ++ m' :: l, P x := by
      intro P ⟨x, hx, hP⟩
      refine ⟨x, ?_, hP⟩
      rcases List.mem_append.1 hx with h | h
      · exact List.mem_append_left _ h
      · exact List.mem_append_right _ (List.mem_cons_of_mem _ h)
    have hmem : m ∈ m' :: l := List.mem_cons_of_mem _ (ipath_last C hp)
    obtain ⟨r0, g0, td0, ob0, out0, hm⟩ := hrun m hmem
    have IH := ih (fun x hx => hrun x (List.mem_cons_of_mem _ hx)) _ _ _ _ _ hm
    rcases istep_it C hs i with e | ⟨r', hr, e⟩ | e
    · rw [e, hm] at he; cases he
      exact ⟨fun p hp => lift (IH.1 p hp), fun j o h => lift (IH.2 j o h)⟩
    · rw [e] at he; subst he; rw [hm] at hr
      cases hr with
      | iterGroup =>
        exact ⟨fun p hp => lift (IH.1 p hp), (fun _ _ h => nomatch h)⟩
      | iterLoad _ _ _ _ _ _ _ _ j hj =>
        refine ⟨fun p hp => lift (IH.1 p hp), fun x o hx => ?_⟩
        rcases List.mem_append.1 hx with hx | hx
        · exact lift (IH.2 x o hx)
        · simp at hx; obtain ⟨rfl, rfl⟩ := hx
          exact ⟨m, List.mem_append_right _ hmem, rfl⟩
      | iterYield =>
        refine ⟨fun p hp => ?_, (fun _ _ h => nomatch h)⟩
        rcases List.mem_append.1 hp with hp | hp
        · exact lift (IH.1 p hp)
        · obtain ⟨_, o, ho, hpo⟩ := mem_fulls hp
          obtain ⟨x, hx, hs⟩ := lift (IH.2 _ o ho)
          exact ⟨x, hx, by rw [hs]; exact hpo⟩
    · rw [hm] at e; cases e

theorem ipath_first {s s1 : ISt K V} {l : List (ISt K V)} (hp : IPath C s s1 l) : s ∈ l := by
  induction hp with
  | refl => exact List.mem_singleton_self _
  | step _ _ ih => exact List.mem_cons_of_mem _ ih

theorem iter_path_complete {s0 s1 : ISt K V} {l : List (ISt K V)} (hp : IPath C s0 s1 l)
    {i u t : Nat} {cl : Option (Nat × Nat × Table K V)}
    {rest0 g0 todo0 : List Nat} {obs0 : List (Nat × Slot K V)} {out0 : List (Nat × K × V)}
    (hstart : s0.it i = .iter u t rest0 g0 todo0 obs0 out0 cl)
    {j : Nat} {k : K} {v : V}
    (H0 : j ∈ rest0 ∨ (j ∈ g0 ∧ (j ∈ todo0 ∨ ∃ o, (j, o) ∈ obs0) ∧
        ∀ o, (j, o) ∈ obs0 → o.pair = some (k, v)) ∨ (j, k, v) ∈ out0) :
    (∀ m ∈ l, ∃ rest g todo obs out, m.it i = .iter u t rest g todo obs out cl) →
    (∀ m ∈ l, ((m.base.tables t).slot j).pair = some (k, v)) →
    ∀ rest g todo obs out, s1.it i = .iter u t rest g todo obs out cl →
      j ∈ rest ∨ (j ∈ g ∧ (j ∈ todo ∨ ∃ o, (j, o) ∈ obs) ∧
        ∀ o, (j, o) ∈ obs → o.pair = some (k, v)) ∨ (j, k, v) ∈ out := by
  induction hp with
  | refl =>
    intro _ _ rest g todo obs out he
    rw [hstart] at he; cases he; exact H0
  | step hp hs ih =>
    rename_i m m' l
    intro hrun hpres rest g todo obs out he
    have hmem : m ∈ m' :: l := List.mem_cons_of_mem _ (ipath_last C hp)
    obtain ⟨r0, g0, td0, ob0, out0, hm⟩ := hrun m hmem
    have IH := ih (fun x hx => hrun x (List.mem_cons_of_mem _ hx))
      (fun x hx => hpres x (List.mem_cons_of_mem _ hx)) _ _ _ _ _ hm
    rcases istep_it C hs i with e | ⟨r', hr, e⟩ | e
    · rw [e, hm] at he; cases he; exact IH
    · rw [e] at he; subst he; rw [hm] at hr
      cases hr with
      | iterGroup _ _ g' rest' _ _ hg =>
        rcases IH with h | ⟨h, -⟩ | h
        · rcases List.mem_append.1 h with h | h
          · exact .inr (.inl ⟨h, .inl h, (fun _ h => nomatch h)⟩)
          · exact .inl h
        · nomatch h
        · exact .inr (.inr h)
      | iterLoad _ _ _ _ _ _ _ _ j' hj' =>
        rcases IH with h | ⟨hg, hc, ho⟩ | h
        · exact .inl h
        · refine .inr (.inl ⟨hg, ?_, ?_⟩)
          · by_cases e : j = j'
            · subst e; exact .inr ⟨_, List.mem_append_right _ List.mem_cons_self⟩
            · rcases hc with hc | ⟨o, ho'⟩
              · exact .inl ((List.mem_erase_of_ne e).2 hc)
              · exact .inr ⟨o, List.mem_append_left _ ho'⟩
          · intro o hx; rcases List.mem_append.1 hx with hx | hx
            · exact ho o hx
            · simp at hx; obtain ⟨rfl, rfl⟩ := hx; exact hpres m hmem
        · exact .inr (.inr h)
      | iterYield _ _ _ g' obs' _ _ hg =>
        rcases IH with h | ⟨hg, hc, ho⟩ | h
        · exact .inl h
        · refine .inr (.inr (List.mem_append_right _ ?_))
          rcases hc with hc | ⟨o, ho'⟩
          · nomatch hc
          · obtain ⟨o', hl⟩ := look_some ho'
            have := ho o' (look_mem hl)
            unfold fulls; exact List.mem_filterMap.2 ⟨j, hg, by rw [hl]; simp [this]⟩
        · exact .inr (.inr (List.mem_append_left _ h))
    · rw [hm] at e; cases e

/-- **Iterator soundness.** Every pair an iterator over table `t` yielded from bucket `j` was in
bucket `j` of `t` (full, any tag) at some moment of the iteration: at the moment its control byte
was loaded. `l` is the run segment from the call's start (`s0`, just after `current` was loaded)
to now (`s1`); the iterator stays alive throughout. Holds on every run, with any keys. -/
theorem iter_sound {s0 s1 : ISt K V} {l : List (ISt K V)} (hp : IPath C s0 s1 l)
    {i u t : Nat} {cl : Option (Nat × Nat × Table K V)}
    (hstart : s0.it i = .iter u t (List.range (s0.base.tables t).n) [] [] [] [] cl)
    (hrun : ∀ m ∈ l, ∃ rest g todo obs out, m.it i = .iter u t rest g todo obs out cl)
    {rest g todo : List Nat} {obs : List (Nat × Slot K V)} {out : List (Nat × K × V)}
    (hend : s1.it i = .iter u t rest g todo obs out cl) :
    ∀ p ∈ out, ∃ m ∈ l, ((m.base.tables t).slot p.1).pair = some p.2 :=
  (iter_path_sound C hp hstart (L0 := []) ⟨(fun _ h => nomatch h), (fun _ _ h => nomatch h)⟩
    hrun _ _ _ _ _ hend).1

/-- **Iterator completeness (per bucket).** When an iterator over table `t` has finished (`rest`
and the current group empty), it has yielded every pair that sat in one bucket of `t`
throughout the iteration. Holds on every run. Writes after a resize go to the new table and are
not seen; a key that moves between buckets of `t` is not covered (see `MAPPING.md`). -/
theorem iter_complete (hcov : C.Cover) {s0 s1 : ISt K V} {l : List (ISt K V)} (h0 : IReach C s0)
    (hp : IPath C s0 s1 l) {i u t : Nat} {cl : Option (Nat × Nat × Table K V)}
    (hstart : s0.it i = .iter u t (List.range (s0.base.tables t).n) [] [] [] [] cl)
    (hrun : ∀ m ∈ l, ∃ rest g todo obs out, m.it i = .iter u t rest g todo obs out cl)
    {todo : List Nat} {obs : List (Nat × Slot K V)} {out : List (Nat × K × V)}
    (hend : s1.it i = .iter u t [] [] todo obs out cl) {j : Nat} {k : K} {v : V}
    (hpres : ∀ m ∈ l, ((m.base.tables t).slot j).pair = some (k, v)) : (j, k, v) ∈ out := by
  have hi := (ireach_iinv C hcov h0).it i; rw [hstart] at hi
  have hw := (ireach_iinv C hcov h0).sinv.swf t (held_lt C (ireach_iinv C hcov h0).sinv hi.1)
  have hj : j < (s0.base.tables t).n := by
    refine Nat.lt_of_not_le fun hn => ?_
    have := hpres s0 (ipath_first C hp); rw [hw.bound j hn] at this; cases this
  rcases iter_path_complete C hp hstart (.inl (List.mem_range.2 hj)) hrun hpres _ _ _ _ _ hend with h | ⟨h, _⟩ | h
  · nomatch h
  · nomatch h
  · exact h

/-- The table an iteration runs over is held, hence not freed, at every state of the run. -/
theorem iter_run_nf (hcov : C.Cover) {s0 s1 : ISt K V} {l : List (ISt K V)} (h0 : IReach C s0)
    (hp : IPath C s0 s1 l) {i u t : Nat} {cl : Option (Nat × Nat × Table K V)}
    (hrun : ∀ m ∈ l, ∃ rest g todo obs out, m.it i = .iter u t rest g todo obs out cl) :
    ∀ m ∈ l, m.base.ts t ≠ .freed := by
  intro m hm
  obtain ⟨_, _, _, _, _, e⟩ := hrun m hm
  have hI := ireach_iinv C hcov (ipath_reach C h0 hp m hm)
  have hi := hI.it i; rw [e] at hi
  exact held_nf C hI.sinv hi.1

/-- Completeness with the hypothesis only at the two ends: a pair `(k, v)` in bucket `j` of `t`
(with `k`'s own tag) when the iteration starts and when it finishes was there all along (a
bucket never returns to full once it is a tombstone), so it is yielded. -/
theorem iter_complete_ends (hcov : C.Cover) {s0 s1 : ISt K V} {l : List (ISt K V)}
    (h0 : IReach C s0) (hp : IPath C s0 s1 l) {i u t : Nat} {cl : Option (Nat × Nat × Table K V)}
    (hstart : s0.it i = .iter u t (List.range (s0.base.tables t).n) [] [] [] [] cl)
    (hrun : ∀ m ∈ l, ∃ rest g todo obs out, m.it i = .iter u t rest g todo obs out cl)
    {todo : List Nat} {obs : List (Nat × Slot K V)} {out : List (Nat × K × V)}
    (hend : s1.it i = .iter u t [] [] todo obs out cl) {j : Nat} {k : K} {v : V}
    (hs0 : (s0.base.tables t).slot j = .full k v) (hs1 : (s1.base.tables t).slot j = .full k v) :
    (j, k, v) ∈ out := by
  have hi0 := ireach_iinv C hcov h0
  have hi := hi0.it i; rw [hstart] at hi
  have hev := ipath_evo C hp (held_lt C hi0.sinv hi.1) (iter_run_nf C hcov h0 hp hrun)
  refine iter_complete C hcov h0 hp hstart hrun hend fun m hm => ?_
  obtain ⟨_, e1, e2⟩ := hev m hm
  rcases e1.full hs0 with e | e
  · rw [e]; rfl
  · have := e2.del (j := j) (by rw [e]; rfl); rw [hs1, e] at this; cases this

/-! ## `len` and `capacity` -/

/-- The states of a running `len` call of thread `u` on table `t`. -/
def LenRun (u t : Nat) (r : IR K V) : Prop :=
  r = .lenT u t ∨ (∃ tb, r = .lenG u t tb) ∨ ∃ x, r = .lenR u t x

theorem len_path (hcov : C.Cover) {s0 s1 : ISt K V} {l : List (ISt K V)} (h0 : IReach C s0)
    (hp : IPath C s0 s1 l) {i u t : Nat} (hstart : s0.it i = .lenT u t) :
    (∀ m ∈ l, LenRun u t (m.it i)) →
    (∀ tb, s1.it i = .lenG u t tb → ∃ m1 ∈ l, (m1.base.tables t).tombstones = tb ∧
      Evo (m1.base.tables t) (s1.base.tables t) ∧ SWF (m1.base.tables t)) ∧
    (∀ r, s1.it i = .lenR u t r → ∃ m1 ∈ l, ∃ m2 ∈ l,
      r = bmc ((m1.base.tables t).n - 1) - (m1.base.tables t).tombstones -
        (m2.base.tables t).growthLeft ∧
      (m1.base.tables t).tombstones + (m2.base.tables t).growthLeft ≤
        bmc ((m1.base.tables t).n - 1) ∧
      (items (m1.base.tables t)).length ≤ r ∧ (items (m2.base.tables t)).length ≤ r) := by
  have hreach := ipath_reach C h0 hp
  induction hp with
  | refl =>
    intro _; rw [hstart]
    exact ⟨(fun _ h => by cases h), (fun _ h => by cases h)⟩
  | step hp hs ih =>
    rename_i m m' l
    intro hrun
    have hmem : m ∈ m' :: l := List.mem_cons_of_mem _ (ipath_last C hp)
    have IH := ih (fun x hx => hreach x (List.mem_cons_of_mem _ hx))
      (fun x hx => hrun x (List.mem_cons_of_mem _ hx))
    have hI := ireach_iinv C hcov (hreach m hmem)
    have ht : t < m.base.nextId := by
      have hr := hI.it i
      rcases hrun m hmem with e | ⟨_, e⟩ | ⟨_, e⟩ <;> rw [e] at hr <;> exact held_lt C hI.sinv hr
    have hf : m.base.ts t ≠ .freed := by
      have hr := hI.it i
      rcases hrun m hmem with e | ⟨_, e⟩ | ⟨_, e⟩ <;> rw [e] at hr <;> exact held_nf C hI.sinv hr
    have hev := (istep_evo C hs ht hf).1
    have lift : ∀ {P : ISt K V → Prop}, (∃ x ∈ l, P x) → ∃ x ∈ m' :: l, P x :=
      fun ⟨x, hx, hP⟩ => ⟨x, List.mem_cons_of_mem _ hx, hP⟩
    rcases istep_it C hs i with e | ⟨r', hr, e⟩ | e
    · rw [e]
      refine ⟨fun tb he => ?_, fun r he => ?_⟩
      · obtain ⟨m1, h1, h2, h3, h4⟩ := IH.1 tb he
        exact ⟨m1, List.mem_cons_of_mem _ h1, h2, evo_trans h3 hev, h4⟩
      · obtain ⟨m1, h1, m2, h2, h3⟩ := IH.2 r he
        exact ⟨m1, List.mem_cons_of_mem _ h1, m2, List.mem_cons_of_mem _ h2, h3⟩
    · rw [e]
      rcases hrun m hmem with hm | ⟨tb, hm⟩ | ⟨x, hm⟩ <;> rw [hm] at hr IH
      · cases hr with
        | lenTomb =>
          refine ⟨fun tb he => ?_, fun r he => by cases he⟩
          cases he
          exact ⟨m, hmem, rfl, hev, hI.sinv.swf t ht⟩
        | drop => exact ⟨(fun _ he => by cases he), (fun _ he => by cases he)⟩
      · cases hr with
        | lenGrowth =>
          refine ⟨(fun _ he => by cases he), fun r he => ?_⟩
          cases he
          obtain ⟨m1, h1, h2, h3, h4⟩ := IH.1 tb rfl
          have a1 := swf_items h4
          have a2 := swf_items (hI.sinv.swf t ht)
          have hn := h3.1; have hto := h3.2.1; have hgl := h3.2.2.1
          subst h2; rw [hn] at a2
          refine ⟨m1, List.mem_cons_of_mem _ h1, m, hmem, by rw [hn], ?_, ?_, ?_⟩ <;>
            (try rw [hn]) <;> omega
        | drop => exact ⟨(fun _ he => by cases he), (fun _ he => by cases he)⟩
      · cases hr with
        | drop => exact ⟨(fun _ he => by cases he), (fun _ he => by cases he)⟩
    · rcases hrun m hmem with hm | ⟨_, hm⟩ | ⟨_, hm⟩ <;> rw [hm] at e <;> cases e

/-- **`len` is weakly consistent.** A `len` call on table `t` (the `current` it loaded) returns
`capacity - tombstones₁ - growth_left₂`, with `tombstones₁` the counter of `t` at one moment of
the call and `growth_left₂` at another (two separate loads). The subtraction never underflows,
and the result is at least the true number of full buckets of `t` at both moments. It can exceed
the number of entries at every moment of the call (a removal before an insert, both between the
loads), and it says nothing about a newer `current` after a resize. -/
theorem len_spec (hcov : C.Cover) {s0 s1 : ISt K V} {l : List (ISt K V)} (h0 : IReach C s0)
    (hp : IPath C s0 s1 l) {i u t r : Nat} (hstart : s0.it i = .lenT u t)
    (hrun : ∀ m ∈ l, LenRun u t (m.it i)) (hend : s1.it i = .lenR u t r) :
    ∃ m1 ∈ l, ∃ m2 ∈ l,
      r = bmc ((m1.base.tables t).n - 1) - (m1.base.tables t).tombstones -
        (m2.base.tables t).growthLeft ∧
      (m1.base.tables t).tombstones + (m2.base.tables t).growthLeft ≤
        bmc ((m1.base.tables t).n - 1) ∧
      (items (m1.base.tables t)).length ≤ r ∧ (items (m2.base.tables t)).length ≤ r :=
  (len_path C hcov h0 hp hstart hrun).2 r hend

/-- **`capacity` is linearizable to table `t`.** It returns `capacity - tombstones` of `t` at the
moment of its single counter load, without underflow; that is exactly the number of full
buckets plus `growth_left` then. (`t` may already have been replaced by a resize.) -/
theorem capacity_spec (hcov : C.Cover) {s0 s1 : ISt K V} {l : List (ISt K V)} (h0 : IReach C s0)
    (hp : IPath C s0 s1 l) {i u t r : Nat} (hstart : s0.it i = .capT u t)
    (hrun : ∀ m ∈ l, m.it i = .capT u t ∨ ∃ x, m.it i = .capR u t x)
    (hend : s1.it i = .capR u t r) :
    ∃ m ∈ l, r = bmc ((m.base.tables t).n - 1) - (m.base.tables t).tombstones ∧
      (m.base.tables t).tombstones ≤ bmc ((m.base.tables t).n - 1) ∧
      r = (items (m.base.tables t)).length + (m.base.tables t).growthLeft := by
  have hreach := ipath_reach C h0 hp
  induction hp generalizing r with
  | refl => rw [hstart] at hend; cases hend
  | step hp hs ih =>
    rename_i m m' l
    have hmem : m ∈ m' :: l := List.mem_cons_of_mem _ (ipath_last C hp)
    have hI := ireach_iinv C hcov (hreach m hmem)
    rcases istep_it C hs i with e | ⟨r', hr, e⟩ | e
    · rw [e] at hend
      obtain ⟨x, hx, hh⟩ := ih (fun x hx => hrun x (List.mem_cons_of_mem _ hx))
        hend (fun x hx => hreach x (List.mem_cons_of_mem _ hx))
      exact ⟨x, List.mem_cons_of_mem _ hx, hh⟩
    · rw [e] at hend; subst hend
      rcases hrun m hmem with hm | ⟨x, hm⟩ <;> rw [hm] at hr
      · cases hr with
        | capTomb =>
          have hr := hI.it i; rw [hm] at hr
          have a := swf_items (hI.sinv.swf t (held_lt C hI.sinv hr))
          exact ⟨m, hmem, rfl, by omega, by omega⟩
      · cases hr
    · rcases hrun m hmem with hm | ⟨_, hm⟩ <;> rw [hm] at e <;> cases e

/-! ## `Clone` -/

theorem mem_dedupK {x : K × V} : ∀ {l : List (K × V)}, x ∈ dedupK l → x ∈ l
  | [], h => h
  | p :: l, h => by
    rcases List.mem_cons.1 h with h | h
    · exact h ▸ List.mem_cons_self
    · exact List.mem_cons_of_mem _ (mem_dedupK (List.mem_filter.1 h).1)

theorem dedupK_key {k : K} {v : V} : ∀ {l : List (K × V)}, (k, v) ∈ l → ∃ w, (k, w) ∈ dedupK l
  | [], h => nomatch h
  | p :: l, h => by
    by_cases e : k = p.1
    · exact ⟨p.2, by rw [e]; exact List.mem_cons_self⟩
    · rcases List.mem_cons.1 h with h | h
      · exact absurd (by rw [← h]) e
      · obtain ⟨w, hw⟩ := dedupK_key h
        exact ⟨w, List.mem_cons_of_mem _ (List.mem_filter.2 ⟨hw, by simp [e]⟩)⟩

theorem dedupK_pairwise : ∀ l : List (K × V), (dedupK l).Pairwise (fun a b => a.1 ≠ b.1)
  | [] => .nil
  | p :: l => by
    refine List.pairwise_cons.2 ⟨fun b hb => ?_, (dedupK_pairwise l).filter _⟩
    have := (List.mem_filter.1 hb).2; simp at this; exact Ne.symm this

/-- **The table built by `Clone`.** When the copy loop of `clone_table_dedup` (an iterator with
`cl = some (tb, gl, T0)`) has finished, the new table of any size `m` that Rust may pick is
well-formed (the yielded pairs fit: `clone_bound`), has unique keys, and contains exactly the
first yielded pair of every yielded key. -/
theorem clone_result (hcov : C.Cover) {s : ISt K V} (h : IReach C s) {i u t : Nat}
    {todo : List Nat} {obs : List (Nat × Slot K V)} {out : List (Nat × K × V)} {tb gl : Nat}
    {T0 : Table K V} (hit : s.it i = .iter u t [] [] todo obs out (some (tb, gl, T0)))
    (m : Nat) (hm : m.isPowerOfTwo) (hcap : bmc ((s.base.tables t).n - 1) - tb ≤ bmc (m - 1)) :
    WF C (build C m (dedupK (out.map (·.2)))) ∧ Uniq (build C m (dedupK (out.map (·.2)))) ∧
    (∀ k v, Has (build C m (dedupK (out.map (·.2)))) k v ↔ (k, v) ∈ dedupK (out.map (·.2))) ∧
    out.length ≤ bmc (m - 1) := by
  have hI := ireach_iinv C hcov h
  have hi := hI.it i; rw [hit] at hi
  have hb := clone_bound hi.2.1 hi.2.2.2.2.2 (hI.sinv.swf t (held_lt C hI.sinv hi.1))
  have hlen : (dedupK (out.map (·.2))).length ≤ bmc (m - 1) :=
    Nat.le_trans (dedupK_length _) (by simp; omega)
  have hw := build_wf C hcov m hm _ hlen
  exact ⟨hw.1, build_uniq C hcov m hm _ (dedupK_pairwise _) hlen, hw.2, by omega⟩

/-- **`Clone` is a weakly consistent snapshot of the table it loaded.** Over the copy loop's
run segment `l` (from the `tombstones` load to the end of the iteration): every pair in the clone
was in some bucket of `t` at some moment of `l`, and every pair that sat in one bucket of `t`
throughout `l` has its key in the clone (with that value or with an earlier yielded value of the
same key, since `clone_table_dedup` keeps the first). -/
theorem clone_weakly_consistent (hcov : C.Cover) {s0 s1 : ISt K V} {l : List (ISt K V)}
    (h0 : IReach C s0) (hp : IPath C s0 s1 l) {i u t tb gl : Nat} {T0 : Table K V}
    (hstart : s0.it i = .iter u t (List.range (s0.base.tables t).n) [] [] [] [] (some (tb, gl, T0)))
    (hrun : ∀ m ∈ l, ∃ rest g todo obs out, m.it i = .iter u t rest g todo obs out (some (tb, gl, T0)))
    {todo : List Nat} {obs : List (Nat × Slot K V)} {out : List (Nat × K × V)}
    (hend : s1.it i = .iter u t [] [] todo obs out (some (tb, gl, T0)))
    (m : Nat) (hm : m.isPowerOfTwo) (hcap : bmc ((s1.base.tables t).n - 1) - tb ≤ bmc (m - 1)) :
    WF C (build C m (dedupK (out.map (·.2)))) ∧ Uniq (build C m (dedupK (out.map (·.2)))) ∧
    (∀ k v, Has (build C m (dedupK (out.map (·.2)))) k v →
      ∃ x ∈ l, ∃ j, ((x.base.tables t).slot j).pair = some (k, v)) ∧
    (∀ j k v, (∀ x ∈ l, ((x.base.tables t).slot j).pair = some (k, v)) →
      ∃ w, Has (build C m (dedupK (out.map (·.2)))) k w) := by
  have h1 : IReach C s1 := ipath_reach C h0 hp s1 (ipath_last C hp)
  obtain ⟨hw, hu, hhas, _⟩ := clone_result C hcov h1 hend m hm hcap
  refine ⟨hw, hu, fun k v hkv => ?_, fun j k v hpres => ?_⟩
  · obtain ⟨p, hp', e⟩ := List.mem_map.1 (mem_dedupK ((hhas k v).1 hkv))
    obtain ⟨x, hx, hs⟩ := iter_sound C hp hstart hrun hend p hp'
    exact ⟨x, hx, p.1, by rw [hs, e]⟩
  · have := iter_complete C hcov h0 hp hstart hrun hend hpres
    obtain ⟨w, hw'⟩ := dedupK_key (List.mem_map.2 ⟨_, this, rfl⟩ : (k, v) ∈ out.map (·.2))
    exact ⟨w, (hhas k w).2 hw'⟩

/-- `clone_table_dedup`'s early return is exact: when `capacity - tombstones = 0` at the
`tombstones` load, table `t` had no full bucket at that moment, so the static empty table is a
snapshot of it. -/
theorem clone_zero (hcov : C.Cover) {s : ISt K V} (h : IReach C s) {i u t : Nat}
    (hit : s.it i = .cloneT u t)
    (h0 : bmc ((s.base.tables t).n - 1) - (s.base.tables t).tombstones = 0) :
    items (s.base.tables t) = [] := by
  have hI := ireach_iinv C hcov h
  have hi := hI.it i; rw [hit] at hi
  have := swf_items (hI.sinv.swf t (held_lt C hI.sinv hi))
  exact List.eq_nil_of_length_eq_zero (by omega)

/-- `clone_table_dedup`'s estimate `items = remaining_capacity - growth_left` never underflows:
the `growth_left` it loaded is at most `capacity - tombstones` for the `tombstones` it loaded
before (Rust's comment: "must be less than or equal `remaining_capacity`"). -/
theorem clone_no_underflow (hcov : C.Cover) {s : ISt K V} (h : IReach C s) {i u t : Nat}
    {rest g todo : List Nat} {obs : List (Nat × Slot K V)} {out : List (Nat × K × V)}
    {tb gl : Nat} {T0 : Table K V}
    (hit : s.it i = .iter u t rest g todo obs out (some (tb, gl, T0))) :
    0 < bmc ((s.base.tables t).n - 1) - tb ∧ gl ≤ bmc ((s.base.tables t).n - 1) - tb := by
  have hi := (ireach_iinv C hcov h).it i; rw [hit] at hi
  obtain ⟨_, _, _, _, _, ⟨_, _, c3, c6, c7, _, _⟩⟩ := hi
  rw [c3.1]; omega

/-- The size Rust picks when `capacity_to_buckets(max(items * 2, remaining_capacity))` does not
overflow has capacity at least the requested one. -/
theorem clone_size_rust (W : Nat) (hW : W.isPowerOfTwo) (rem gl : Nat) (h : 0 < rem) :
    (c2b W (max ((rem - gl) * 2) rem)).isPowerOfTwo ∧
      max ((rem - gl) * 2) rem ≤ bmc (c2b W (max ((rem - gl) * 2) rem) - 1) :=
  c2b_sound W _ hW (Nat.lt_of_lt_of_le h (Nat.le_max_right _ _))

/-- `capacity_to_buckets` with `usize` arithmetic: `None` when `cap * 8` overflows (`checked_mul`),
`U = usize::MAX + 1`. Otherwise it is `c2b`. -/
def c2bU (U W cap : Nat) : Option Nat :=
  if cap < 8 then some (c2b W cap) else if U ≤ cap * 8 then none else some (c2b W cap)

/-- `clone_table_dedup`'s bucket count: `capacity_to_buckets(max(items * 2, remaining))`, falling
back to `capacity_to_buckets(remaining)` on overflow (`.expect` panics if both overflow, a panic
not modelled, assumption 8). `items * 2` itself cannot overflow: `items ≤ remaining < buckets`, and
the control bytes alone take `buckets` bytes of a `Layout` bounded by `isize::MAX`. -/
def cloneBuckets (U W items rem : Nat) : Option Nat :=
  match c2bU U W (max (items * 2) rem) with
  | some m => some m
  | none => c2bU U W rem

theorem c2bU_sound {U W cap m : Nat} (hW : W.isPowerOfTwo) (hc : 0 < cap)
    (h : c2bU U W cap = some m) : m.isPowerOfTwo ∧ cap ≤ bmc (m - 1) := by
  unfold c2bU at h
  split at h
  · cases h; exact c2b_sound W cap hW hc
  · split at h
    · cases h
    · cases h; exact c2b_sound W cap hW hc

/-- **Rust's choice for the clone's size, overflow fallback included, satisfies
`IRStep.cloneDone`'s premise**: whichever `capacity_to_buckets` call succeeds, the result is a
power of two with capacity at least `remaining_capacity` (so `clone_bound` makes the copy fit). -/
theorem cloneBuckets_ok {U W items rem m : Nat} (hW : W.isPowerOfTwo) (hrem : 0 < rem)
    (h : cloneBuckets U W items rem = some m) : m.isPowerOfTwo ∧ rem ≤ bmc (m - 1) := by
  unfold cloneBuckets at h
  split at h
  · rename_i e; cases h
    have := c2bU_sound hW (Nat.lt_of_lt_of_le hrem (Nat.le_max_right _ _)) e
    exact ⟨this.1, Nat.le_trans (Nat.le_max_right _ _) this.2⟩
  · exact c2bU_sound hW hrem h

/-! ## Per-key completeness under unique keys -/

/-- At most one bucket changes. -/
def Changes1 (T T' : Table K V) : Prop := ∃ x, ∀ j, j ≠ x → T'.slot j = T.slot j

theorem changes1_refl (T : Table K V) : Changes1 T T := ⟨0, fun _ _ => rfl⟩

theorem changes1_commit {s : St K V} {T' : Table K V} (h : Changes1 (s.tables s.cur) T')
    (t : Nat) : Changes1 (s.tables t) ((commit s T').tables t) := by
  show Changes1 _ (upd s.tables s.cur T' t)
  by_cases e : t = s.cur
  · subst e; rw [upd_same]; exact h
  · rw [upd_other _ _ _ _ e]; exact changes1_refl _

theorem step_changes1 {s s' : St K V} (hs : Step C s s') {t : Nat} (ht : t < s.nextId)
    (hf : s.ts t ≠ .freed) :
    Changes1 (s.tables t) (s'.tables t) := by
  cases hs with
  | insert k v i _ _ => exact changes1_commit ⟨i, fun j hj => if_neg hj⟩ t
  | insertAny k v i _ _ _ => exact changes1_commit ⟨i, fun j hj => if_neg hj⟩ t
  | insertMis k v i _ _ _ => exact changes1_commit ⟨i, fun j hj => if_neg hj⟩ t
  | remove k v i _ => exact changes1_commit ⟨i, fun j hj => if_neg hj⟩ t
  | removeMis k v i _ => exact changes1_commit ⟨i, fun j hj => if_neg hj⟩ t
  | expand m _ _ => rw [show (swap s _ false).tables t = s.tables t from
      publish_tables_lt false (swap_pub _ _) ht hf]; exact changes1_refl _
  | replace m l _ _ => rw [show (swap s _ true).tables t = s.tables t from
      publish_tables_lt true (swap_pub _ _) ht hf]; exact changes1_refl _
  | replaceEmpty => rw [show (swapEmpty s).tables t = s.tables t from
      publish_tables_lt true (swapEmpty_pub s) ht hf]; exact changes1_refl _
  | expandAt m a ha _ _ => rw [show (swapAt s a _ false).tables t = s.tables t from
      publish_tables_lt false (swapAt_pub _ ha) ht hf]; exact changes1_refl _
  | replaceAt m a l ha _ _ => rw [show (swapAt s a _ true).tables t = s.tables t from
      publish_tables_lt true (swapAt_pub _ ha) ht hf]; exact changes1_refl _
  | _ => exact changes1_refl _

theorem istep_changes1 {s s' : ISt K V} (hs : IStep C s s') {t : Nat} (ht : t < s.base.nextId)
    (hf : s.base.ts t ≠ .freed) :
    Changes1 (s.base.tables t) (s'.base.tables t) := by
  cases hs with
  | base b' hb _ => exact step_changes1 C hb ht hf
  | _ => exact changes1_refl _

/-- With unique keys at every moment, a key present in table `t` at every moment stays in the
bucket where it was at the start (every step changes at most one bucket, so a move would need a
moment with two copies or none). -/
theorem key_stays {s0 s1 : ISt K V} {l : List (ISt K V)} (hp : IPath C s0 s1 l) {t : Nat}
    (ht : t < s0.base.nextId) {j : Nat} {k : K} {w : V}
    (hj : (s0.base.tables t).slot j = .full k w) (hnf : ∀ m ∈ l, m.base.ts t ≠ .freed) :
    (∀ m ∈ l, Uniq (m.base.tables t) ∧ ∃ w', Has (m.base.tables t) k w') →
    ∀ m ∈ l, (m.base.tables t).slot j = .full k w := by
  revert hnf
  induction hp with
  | refl => intro _ _ m hm; rw [List.mem_singleton.1 hm]; exact hj
  | step hp hs ih =>
    rename_i m m' l
    intro hnf hk x hx
    have hnf' := fun y hy => hnf y (List.mem_cons_of_mem _ hy)
    have hmem : m ∈ l := ipath_last C hp
    have IH := ih hnf' (fun y hy => hk y (List.mem_cons_of_mem _ hy))
    rcases List.mem_cons.1 hx with rfl | hx
    · have hm := IH m hmem
      have hlt := (ipath_evo C hp ht hnf' m hmem).1
      rcases (istep_evo C hs hlt (hnf' m hmem)).1.full hm with e | e
      · exact e
      · exfalso
        obtain ⟨_, w', j', hj'⟩ := (hk _ List.mem_cons_self)
        obtain ⟨y, hy⟩ := istep_changes1 C hs hlt (hnf' m hmem)
        have hjy : j = y := Classical.byContradiction fun h => by
          have := hy j h; rw [e, hm] at this; cases this
        have hne : j' ≠ j := fun h => by rw [h, e] at hj'; cases hj'
        have hold := hy j' (hjy ▸ hne)
        rw [hj'] at hold
        exact hne ((hk m (List.mem_cons_of_mem _ hmem)).1 _ _ _ _ _ hold.symm hm)
    · exact IH x hx

/-- **Iterator completeness per key, under unique keys.** If every state of the iteration has
unique keys in table `t` (what the `insert_new`/`replace` key contract maintains, `Uniq`) and
`k` is present in `t` (with some value, in some bucket) at every moment, the finished iterator
yielded `k`. This is the strongest per-key form: without unique keys it is false (insert a
duplicate of `k` into an `EMPTY` bucket the iterator has passed, then remove the original before
the iterator reaches it: `k` was always present and is never yielded). -/
theorem iter_complete_key (hcov : C.Cover) {s0 s1 : ISt K V} {l : List (ISt K V)}
    (h0 : IReach C s0) (hp : IPath C s0 s1 l) {i u t : Nat} {cl : Option (Nat × Nat × Table K V)}
    (hstart : s0.it i = .iter u t (List.range (s0.base.tables t).n) [] [] [] [] cl)
    (hrun : ∀ m ∈ l, ∃ rest g todo obs out, m.it i = .iter u t rest g todo obs out cl)
    {todo : List Nat} {obs : List (Nat × Slot K V)} {out : List (Nat × K × V)}
    (hend : s1.it i = .iter u t [] [] todo obs out cl) {k : K}
    (hk : ∀ m ∈ l, Uniq (m.base.tables t) ∧ ∃ w, Has (m.base.tables t) k w) :
    ∃ j w, (j, k, w) ∈ out := by
  have hi0 := ireach_iinv C hcov h0
  have hi := hi0.it i; rw [hstart] at hi
  have ht := held_lt C hi0.sinv hi.1
  obtain ⟨_, w, j, hj⟩ := hk s0 (ipath_first C hp)
  have hst := key_stays C hp ht hj (iter_run_nf C hcov h0 hp hrun) hk
  exact ⟨j, w, iter_complete C hcov h0 hp hstart hrun hend fun m hm => by rw [hst m hm]; rfl⟩

/-! ## Under the key contract -/

/-- Extended runs whose every step respects the `insert_new`/`replace` key contract
(`ContractOK` of `Contract.lean`, which includes the probe contract) on the base state. -/
inductive ICReach : ISt K V → Prop
  | init : ICReach iinit
  | step {s s'} : ICReach s → IStep C s s' → ContractOK C s.base s'.base → ICReach s'

/-- Run segments of contract-respecting steps. -/
inductive ICPath : ISt K V → ISt K V → List (ISt K V) → Prop
  | refl (s) : ICPath s s [s]
  | step {s m m' l} : ICPath s m l → IStep C m m' → ContractOK C m.base m'.base →
      ICPath s m' (m' :: l)

theorem ICReach.ireach {s : ISt K V} (h : ICReach C s) : IReach C s := by
  induction h with
  | init => exact .init
  | step _ hs _ ih => exact .step ih hs

theorem ICPath.ipath {s s1 : ISt K V} {l : List (ISt K V)} (h : ICPath C s s1 l) :
    IPath C s s1 l := by
  induction h with
  | refl => exact .refl _
  | step _ hs _ ih => exact .step ih hs

theorem icpath_reach {s s1 : ISt K V} {l : List (ISt K V)} (h0 : ICReach C s)
    (hp : ICPath C s s1 l) : ∀ m ∈ l, ICReach C m := by
  induction hp with
  | refl => intro m hm; rw [List.mem_singleton.1 hm]; exact h0
  | step hp hs hc ih =>
    intro m hm
    rcases List.mem_cons.1 hm with rfl | hm
    · exact .step (ih _ (ipath_last C hp.ipath)) hs hc
    · exact ih m hm

/-- The base invariants of `Contract.lean` (`Inv`, and `UInv`: every allocated table has unique
keys) hold on contract-respecting extended runs. -/
theorem icreach_inv (hcov : C.Cover) {s : ISt K V} (h : ICReach C s) :
    Inv C s.base ∧ UInv s.base := by
  induction h with
  | init => exact creachable_inv C hcov .init
  | step _ hs hc ih =>
    cases hs with
    | base b' hb _ => exact ⟨inv_step C hcov ih.1 hb hc.2.2, uinv_step C hcov ih.1 ih.2 hb hc⟩
    | start i u st hl r _ hu _ =>
      rename_i s0
      have hr := ih.1.rd u; rw [hu] at hr
      refine ⟨inv_setRd C ih.1 u _ ⟨hr.1, fun t ht => ?_⟩, ⟨ih.2.uniq, ih.2.func⟩⟩
      rcases List.mem_cons.1 ht with rfl | ht
      · exact ⟨ih.1.curLt, .inl ih.1.curLive⟩
      · exact hr.2 t ht
    | step => exact ih
    | copy => exact ih

/-- **Iterator completeness per key under the key contract.** On a contract-respecting run (every
`insert_new` key absent, every `replace` with distinct keys, every insert on its probe
sequence), a finished iterator over table `t` yielded every key that was in `t` (with some value,
in some bucket) at every moment of the iteration. -/
theorem iter_complete_key_contract (hcov : C.Cover) {s0 s1 : ISt K V} {l : List (ISt K V)}
    (h0 : ICReach C s0) (hp : ICPath C s0 s1 l) {i u t : Nat}
    {cl : Option (Nat × Nat × Table K V)}
    (hstart : s0.it i = .iter u t (List.range (s0.base.tables t).n) [] [] [] [] cl)
    (hrun : ∀ m ∈ l, ∃ rest g todo obs out, m.it i = .iter u t rest g todo obs out cl)
    {todo : List Nat} {obs : List (Nat × Slot K V)} {out : List (Nat × K × V)}
    (hend : s1.it i = .iter u t [] [] todo obs out cl) {k : K}
    (hk : ∀ m ∈ l, ∃ w, Has (m.base.tables t) k w) :
    ∃ j w, (j, k, w) ∈ out := by
  refine iter_complete_key C hcov h0.ireach hp.ipath hstart hrun hend fun m hm => ⟨?_, hk m hm⟩
  have hR := icpath_reach C h0 hp m hm
  have hI := ireach_iinv C hcov hR.ireach
  obtain ⟨u', t', hit⟩ : ∃ u' t', (m.it i).tab = some (u', t') ∧ t' = t := by
    obtain ⟨_, _, _, _, _, e⟩ := hrun m hm; rw [e]; exact ⟨u, t, rfl, rfl⟩
  have hh := irinv_held C (hI.it i) hit.1
  rw [hit.2] at hh
  exact (icreach_inv C hcov hR).2.uniq t (held_lt C hI.sinv hh)

/-! ## `Iter::clone` -/

/-- **A copy of an iterator is sound.** Slot `i` runs a `Read::iter` iterator from `s0` to `sc`
(segment `l1`); at `sc` slot `i'` holds the same state (as after `IStep.copy`), and runs to `s1`
(segment `l2`). Every pair in the copy's `out` (the original's yield before the copy, then the
copy's own) was in its bucket of `t` at some moment of `l1 ++ l2`. -/
theorem iter_copy_sound {s0 sc s1 : ISt K V} {l1 l2 : List (ISt K V)}
    (hp1 : IPath C s0 sc l1) (hp2 : IPath C sc s1 l2) {i i' u t : Nat}
    (hstart : s0.it i = .iter u t (List.range (s0.base.tables t).n) [] [] [] [] none)
    (hrun1 : ∀ m ∈ l1, ∃ rest g todo obs out, m.it i = .iter u t rest g todo obs out none)
    (hcp : sc.it i' = sc.it i)
    (hrun2 : ∀ m ∈ l2, ∃ rest g todo obs out, m.it i' = .iter u t rest g todo obs out none)
    {rest g todo : List Nat} {obs : List (Nat × Slot K V)} {out : List (Nat × K × V)}
    (hend : s1.it i' = .iter u t rest g todo obs out none) :
    ∀ p ∈ out, ∃ m ∈ l1 ++ l2, ((m.base.tables t).slot p.1).pair = some p.2 := by
  obtain ⟨r, g', td, ob, ou, hc⟩ := hrun1 sc (ipath_last C hp1)
  have H0 := iter_path_sound C hp1 hstart (L0 := []) ⟨(fun _ h => nomatch h),
    (fun _ _ h => nomatch h)⟩ hrun1 _ _ _ _ _ hc
  exact (iter_path_sound C hp2 (hcp.trans hc) H0 hrun2 _ _ _ _ _ hend).1

/-- **A copy of an iterator is complete per bucket.** When the copy has finished, it (with the
original's yield before the copy) contains every pair that sat in one bucket of `t` throughout
`l1 ++ l2`. -/
theorem iter_copy_complete (hcov : C.Cover) {s0 sc s1 : ISt K V} {l1 l2 : List (ISt K V)}
    (h0 : IReach C s0) (hp1 : IPath C s0 sc l1) (hp2 : IPath C sc s1 l2) {i i' u t : Nat}
    (hstart : s0.it i = .iter u t (List.range (s0.base.tables t).n) [] [] [] [] none)
    (hrun1 : ∀ m ∈ l1, ∃ rest g todo obs out, m.it i = .iter u t rest g todo obs out none)
    (hcp : sc.it i' = sc.it i)
    (hrun2 : ∀ m ∈ l2, ∃ rest g todo obs out, m.it i' = .iter u t rest g todo obs out none)
    {todo : List Nat} {obs : List (Nat × Slot K V)} {out : List (Nat × K × V)}
    (hend : s1.it i' = .iter u t [] [] todo obs out none) {j : Nat} {k : K} {v : V}
    (hpres : ∀ m ∈ l1 ++ l2, ((m.base.tables t).slot j).pair = some (k, v)) :
    (j, k, v) ∈ out := by
  have hi0 := ireach_iinv C hcov h0
  have hi := hi0.it i; rw [hstart] at hi
  have hw := hi0.sinv.swf t (held_lt C hi0.sinv hi.1)
  have hj : j < (s0.base.tables t).n := by
    refine Nat.lt_of_not_le fun hn => ?_
    have := hpres s0 (List.mem_append_left _ (ipath_first C hp1)); rw [hw.bound j hn] at this
    cases this
  obtain ⟨r, g', td, ob, ou, hc⟩ := hrun1 sc (ipath_last C hp1)
  have H0 := iter_path_complete C hp1 hstart (.inl (List.mem_range.2 hj)) hrun1
    (fun m hm => hpres m (List.mem_append_left _ hm)) _ _ _ _ _ hc
  rcases iter_path_complete C hp2 (hcp.trans hc) H0 hrun2
    (fun m hm => hpres m (List.mem_append_right _ hm)) _ _ _ _ _ hend with h | ⟨h, _⟩ | h
  · nomatch h
  · nomatch h
  · exact h

/-! ## Projection to the base model

The only base-state change an `IStep` makes beyond a `Step` is `IStep.start` adding `current` to
the reader's `held` list. The base model reaches the same state by running a `get` for any key
`k` on `current` to completion (`load`, a group per bucket, `finish`), which also adds `current`
to `held`. So with a key at hand, every extended run projects to a base run, and every theorem
about `Reachable` (`no_use_after_free`, `get_linearizable_some`, ...) holds for `s.base`. -/

theorem steps_trans {a b c : St K V} (h1 : Steps C a b) (h2 : Steps C b c) : Steps C a c := by
  induction h2 with
  | refl => exact h1
  | tail _ hs ih => exact .tail ih hs

theorem reachable_steps {a b : St K V} (ha : Reachable C a) (h : Steps C a b) : Reachable C b := by
  induction h with
  | refl => exact ha
  | tail _ hs ih => exact .step ih hs

theorem setRd_setRd (s : St K V) (u : Nat) (r r' : RS K V) :
    setRd (setRd s u r) u r' = setRd s u r' := by
  unfold setRd; congr 1; funext x; unfold upd; by_cases e : x = u <;> simp [e]

theorem setRd_rd (s : St K V) (u : Nat) (r : RS K V) : (setRd s u r).rd u = r := upd_same _ _ _

/-- A `get` that has loaded table `t` runs to `returned`, one bucket per group. -/
theorem probing_returns (s : St K V) (u st : Nat) (h : List Nat) (k : K) (t lv : Nat) :
    ∀ (rest pre : List Nat), ∃ r, Steps C (setRd s u (.probing st h k t lv pre rest))
      (setRd s u (.returned st h k t lv r)) := by
  intro rest
  induction rest with
  | nil =>
    intro pre
    exact ⟨none, .tail (.refl _) (by
      have := Step.probeEnd (C := C) (setRd s u (.probing st h k t lv pre [])) u st h k t lv pre
        (setRd_rd _ _ _)
      rwa [setRd_setRd] at this)⟩
  | cons x rest ih =>
    intro pre
    have s1 := Step.probeGroup (C := C) (setRd s u (.probing st h k t lv pre (x :: rest))) u st h
      k t lv pre [x] rest (setRd_rd _ _ _) (by simp)
    rw [setRd_setRd] at s1
    have s2 := Step.scanLoad (C := C) (setRd s u (.scanning st h k t lv pre [x] [x] [] rest)) u st h
      k t lv pre [x] [x] [] rest x (setRd_rd _ _ _) List.mem_cons_self
    rw [setRd_setRd] at s2
    simp only [List.erase_cons_head, List.nil_append] at s2
    have base := Steps.tail (Steps.tail (.refl _) s1) s2
    have hx : (setRd s u (.scanning st h k t lv pre [x] [x] [] rest)).tables t = s.tables t := rfl
    rw [hx] at base
    generalize ho : (s.tables t).slot x = o at base
    let sx := setRd s u (.scanning st h k t lv pre [x] [] [(x, o)] rest)
    by_cases hf : ∃ w, o = .full k w
    · obtain ⟨w, rfl⟩ := hf
      have s3 := Step.scanHit (C := C) sx u st h k t lv pre [x] [(x, .full k w)] rest x w
        (setRd_rd _ _ _) List.mem_cons_self
      rw [setRd_setRd] at s3
      exact ⟨some w, .tail base s3⟩
    · have hnf : ∀ i w, (i, Slot.full k w) ∉ [(x, o)] := by
        intro i w hm; simp at hm; exact hf ⟨w, hm.2.symm⟩
      by_cases he : o = .empty
      · subst he
        have s3 := Step.scanEmpty (C := C) sx u st h k t lv pre [x] [(x, .empty)] rest x
          (setRd_rd _ _ _) hnf List.mem_cons_self
        rw [setRd_setRd] at s3
        exact ⟨none, .tail base s3⟩
      · have s3 := Step.scanNext (C := C) sx u st h k t lv pre [x] [(x, o)] rest
          (setRd_rd _ _ _) hnf (by intro i hm; simp at hm; exact he hm.2.symm)
        rw [setRd_setRd] at s3
        obtain ⟨r, hr⟩ := ih (pre ++ [x])
        exact ⟨r, steps_trans C (.tail base s3) hr⟩

/-- `IStep.start`'s base change is a whole `get` of the base model. -/
theorem hold_steps (k : K) {s : St K V} {u st : Nat} {h : List Nat}
    (hu : s.rd u = .pinned st h) : Steps C s (setRd s u (.pinned st (s.cur :: h))) := by
  have s1 := Step.load (C := C) s u st h k hu
  obtain ⟨r, hr⟩ := probing_returns C s u st h k s.cur s.ver (ps C (s.tables s.cur) k) []
  have s3 := Step.finish (C := C) (setRd s u (.returned st h k s.cur s.ver r)) u st h k s.cur s.ver r
    (setRd_rd _ _ _)
  rw [setRd_setRd] at s3
  exact .tail (steps_trans C (.tail (.refl _) s1) hr) s3

theorem istep_steps (k : K) {s s' : ISt K V} (hs : IStep C s s') : Steps C s.base s'.base := by
  cases hs with
  | base b' hb _ => exact .tail (.refl _) hb
  | start i u st h r _ hu _ => exact hold_steps C k hu
  | step => exact .refl _
  | copy => exact .refl _

/-- **The extended model refines the base model** (given any key `k`): the base component of
every extended run is a `Reachable` state, so all base theorems apply to it. -/
theorem ireach_reachable (k : K) {s : ISt K V} (h : IReach C s) : Reachable C s.base := by
  induction h with
  | init => exact .init
  | step _ hs ih => exact reachable_steps C ih (istep_steps C k hs)

end SyncTable
