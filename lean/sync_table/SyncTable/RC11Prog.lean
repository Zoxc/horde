import SyncTable.RC11Readers
import SyncTable.RC11Free

/-!
# Property 18: the writer's and the readers' programs as event sequences

`RC11Table`/`RC11Readers`/`RC11Free` take the graph's shape as hypotheses (`henc`, `TableData`,
`hSw`, `hmo`, the reader's `current` load in its pin). This file derives them from a literal
description of the Rust code as event sequences, so that what stays axiomatised is only the
program-to-graph mapping (`WProg`, `RetireProg`, `PinRegion`/`RCall`), each field of which is
one line of Rust.

## The writer (`WProg`)

A table's memory is `TLoc`: the control bytes `ctrl q` (`q < n + W`, primary and mirrored), the
bucket data `dat b`, `growth_left`, `tombstones`, mapped to graph locations by `lay` (injective:
distinct addresses). The writer operations of the table's life `[pub, dF)` store to it exactly
the program `progAt x` (`complete`: no other store of the operation hits the table), as a
`po`-ordered event list `ev x` whose labels realise the stores in order (`Real`):

* `pub` (the operation that publishes the table: `clone_table` / `from_iter` into the new
  table, then `replace_table`): `pubProg`, the data of every full bucket, every control byte,
  both counters, all non-atomic, all `po`-before the `Release` store `S` of `current` (`ev_S`).
  Each location is written with its final value: `TableRef::allocate`'s `EMPTY` memset and the
  counters' initial values, overwritten later in the same operation, are not listed (no reader
  can read them: the overwrite is `po`-before `S`).
* `x ∈ (pub, dF)`: the table effect `ops x` of the model writer step (`TOp`, from `Hist`'s
  `TStep`: `exists_ops`), expanded by `opProg` in Rust's order:
  - `insert_new` / `insert` / `PotentialSlot::insert_new` (`Step.insert*`), `TOp.ins i k v`:
    `bucket.write((k, v))` (`dat i`, non-atomic), `record_item_insert_at`:
    `growth_left.store(_, Release)`, then `set_ctrl_release(i, h2)`: `ctrl i` and
    `ctrl (((i - W) & mask) + W)` (`idx2`; equal to `i` when `i ≥ W`), both `Release`;
  - `remove` (`Step.remove*`), `TOp.rem i k v`: `set_ctrl_release(i, DELETED)` (two stores),
    then `tombstones.store(_, Release)`;
  - every other step (`expand*`, `replace*`, `swapEmpty`, `prune`, ... and every operation
    after the table was replaced), `TOp.none`: no store to the table's memory (the retiring
    operation writes the old table's `next_retired`, which is not a `TLoc`).

From this: `WProg.life` (`RC11Table.Life`), `WProg.henc` (the `henc` hypothesis of `reader_lin`/`load_data`, and the counters
`WProg.hcnt`), `WProg.tableData` (`RC11Readers.TableData`), and `readers_lin_prog`
(`readers_lin` with both derived).

## `replace_table` and `collect` on one graph (`Shared`, `RetireProg`)

`Shared` is one RC11 graph with both the writer structure (`RC11Table.Writer`) and `collect`'s
(`Collect.RC11Pin.CExec`). `RetireProg`: the operation `r > pub` that replaces the table runs
`replace_table`: `current.store(new, Release)` (`Sw`), then (`po`-later) `defer_by_id` (`D`).
`can_free_no_race_shared` is `RC11Free.can_free_no_race` with `hmo` derived from
`Writer.mo_op` and `hSw` from the program.

## Readers (`PinRegion`, `RCall`)

`pin(|p| ...)`: the region from the outermost pin event `a` to its `unpinOuter` `z`. A `Read`
call in it (`get`, `get_potential`, `iter`, `len`, ...) loads `current` (`Lc`, `Acquire`),
then accesses the table through the returned `TableRef`; the references it returns have the
pin's lifetime `'a`, so every access is `po`-before `z` (`RCall`). `RCall.inRegion`: the call's
load and accesses lie in the pinned region (`CExec.InRegion`); `reader_before_free`: every
access of a call whose `current` load read the table's publication `S` happens before the
`free` of `prune_tables` that read `can_free = true`.

## All readers from their programs (`FreeProg`, `RProg`, `readers_lin_shared`)

`FreeProg`: the collect-side facts of the prune that frees the table, the free `F` in writer
operation `f`; the table's life is `[pub, f + 1)`. `FreeProg.before`: a call's accesses happen
before `F` and before operation `f + 1`. `RProg`: a reader thread as its pinned `Read` calls
reading `S` and the control-byte loads of its `get`s (each an access of a call);
`RProg.toRThread` derives `RThread` (its `current` load, `hfree`, and `hnf` from `Owned`).
`readers_lin_shared`: `readers_lin` for all reader threads from `Shared` + `WProg` +
`FreeProg` + `RProg`, with the data reads' side conditions discharged.
-/

namespace SyncTable.RC11Prog
open RC11 RC11.Graph SyncTable.RC11Table SyncTable.RC11Global SyncTable.RC11Readers

/-! ## Programs -/

/-- A location of one table's memory. -/
inductive TLoc where
  | ctrl (q : Nat)
  | dat (b : Nat)
  | growth
  | tomb
  deriving DecidableEq

/-- Locations that exist: control positions `< n + W`. (Data locations of every index are
allowed; only `b < n` are ever written.) -/
def TLoc.Valid (W n : Nat) : TLoc → Prop
  | .ctrl q => q < n + W
  | _ => True

/-- One store of a program: location, value, `Release` atomic (`rel`) or non-atomic. -/
structure PSt where
  loc : TLoc
  val : Nat
  rel : Bool

/-- The effect of one writer operation on one table. -/
inductive TOp (K V : Type) where
  | none
  | ins (i : Nat) (k : K) (v : V)
  | rem (i : Nat) (k : K) (v : V)

section Prog
variable {K V : Type}

def TOp.apply : TOp K V → Table K V → Table K V
  | .none, T => T
  | .ins i k v, T => insertAt T i k v
  | .rem i k v, T => removeAt T i k v

/-- The bucket an operation's control stores hit. -/
def TOp.bucket : TOp K V → Nat
  | .none => 0
  | .ins i _ _ => i
  | .rem i _ _ => i

def TOp.Ok : TOp K V → Table K V → Prop
  | .none, _ => True
  | .ins i _ _, T => T.slot i = .empty ∧ i < T.n
  | .rem i k v, T => T.slot i = .full k v ∧ i < T.n

/-- `set_ctrl_release`'s second index `((i - W) & bucket_mask) + W` (`Word.idx2Rust_eq`). -/
def idx2 (W n i : Nat) : Nat := (i + n - W) % n + W

/-- The stores of a writer operation to the table, in program order (see the module docs). -/
def opProg (enc : Slot K V → Nat) (dval : K → V → Nat) (W n : Nat) :
    TOp K V → Table K V → List PSt
  | .none, _ => []
  | .ins i k v, T' => [⟨.dat i, dval k v, false⟩, ⟨.growth, T'.growthLeft, true⟩,
      ⟨.ctrl i, enc (T'.slot i), true⟩, ⟨.ctrl (idx2 W n i), enc (T'.slot i), true⟩]
  | .rem i _ _, T' => [⟨.ctrl i, enc (T'.slot i), true⟩,
      ⟨.ctrl (idx2 W n i), enc (T'.slot i), true⟩, ⟨.tomb, T'.tombstones, true⟩]

/-- The data write of bucket `b` of a new table (`bucket.write` in `clone_table` /
`from_iter`). -/
def datW (dval : K → V → Nat) (T : Table K V) (b : Nat) : List PSt :=
  match T.slot b with
  | .full k v => [⟨.dat b, dval k v, false⟩]
  | _ => []

/-- The initialisation of a new table by the publishing operation (final values). -/
def pubProg (enc : Slot K V → Nat) (dval : K → V → Nat) (W n : Nat) (T : Table K V) :
    List PSt :=
  (List.range n).flatMap (datW dval T) ++
    (List.range (n + W)).map (fun q => (⟨.ctrl q, enc (T.slot (q % n)), false⟩ : PSt)) ++
    [⟨.growth, T.growthLeft, false⟩, ⟨.tomb, T.tombstones, false⟩]

/-- The program of writer operation `x` on the table published by `pub`. -/
def progAt (enc : Slot K V → Nat) (dval : K → V → Nat) (W n pub : Nat) (tab : Nat → Table K V)
    (ops : Nat → TOp K V) (x : Nat) : List PSt :=
  if x = pub then pubProg enc dval W n (tab x) else opProg enc dval W n (ops x) (tab x)

theorem idx2_eq {W n i : Nat} (hWn : W ≤ n) (hi : i < n) :
    idx2 W n i = if i < W then n + i else i := by
  unfold idx2
  split
  · rw [Nat.mod_eq_of_lt (by omega)]; omega
  · have : i + n - W = (i - W) + n := by omega
    rw [this, Nat.add_mod_right, Nat.mod_eq_of_lt (by omega)]; omega

theorem idx2_mod {W n i : Nat} (hWn : W ≤ n) (hi : i < n) : idx2 W n i % n = i := by
  rw [idx2_eq hWn hi]
  split
  · rw [Nat.add_mod_left, Nat.mod_eq_of_lt hi]
  · exact Nat.mod_eq_of_lt hi

theorem idx2_lt {W n i : Nat} (hWn : W ≤ n) (hi : i < n) : idx2 W n i < n + W := by
  rw [idx2_eq hWn hi]; split <;> omega

/-- The control positions of bucket `i` are `i` and `idx2 i`. -/
theorem pos_of_mod {W n i q : Nat} (hWn : W ≤ n) (hi : i < n) (hq : q < n + W)
    (h : q % n = i) : q = i ∨ q = idx2 W n i := by
  by_cases hqn : q < n
  · left; rw [Nat.mod_eq_of_lt hqn] at h; exact h
  · right
    rw [Nat.mod_eq_sub_mod (by omega), Nat.mod_eq_of_lt (by omega)] at h
    rw [idx2_eq hWn hi]; split <;> omega

theorem datW_mem {dval : K → V → Nat} {T : Table K V} {b : Nat} {s : PSt}
    (h : s ∈ datW dval T b) : s.loc = .dat b ∧ ∃ k v, T.slot b = .full k v ∧ s.val = dval k v := by
  unfold datW at h
  split at h
  · next k v hs =>
    simp only [List.mem_singleton] at h; subst h; exact ⟨rfl, k, v, hs, rfl⟩
  · simp at h

theorem pubProg_dat {enc : Slot K V → Nat} {dval : K → V → Nat} {W n b : Nat} {T : Table K V}
    {s : PSt} (h : s ∈ pubProg enc dval W n T) (hl : s.loc = .dat b) :
    ∃ k v, T.slot b = .full k v := by
  simp only [pubProg, List.mem_append, List.mem_flatMap, List.mem_map, List.mem_cons,
    List.not_mem_nil] at h
  rcases h with (⟨a, -, ha⟩ | ⟨q, -, rfl⟩) | (rfl | rfl | h)
  · obtain ⟨h1, k, v, h2, -⟩ := datW_mem ha
    rw [hl] at h1; cases h1; exact ⟨k, v, h2⟩
  · cases hl
  · cases hl
  · cases hl
  · exact h.elim

/-- No two stores of a program write the same data location. -/
def DatOnce (l : List PSt) : Prop :=
  l.Pairwise (fun s s' => ∀ b, s.loc = .dat b → s'.loc ≠ .dat b)

theorem pubProg_datOnce (enc : Slot K V → Nat) (dval : K → V → Nat) (W n : Nat) (T : Table K V) :
    DatOnce (pubProg enc dval W n T) := by
  unfold DatOnce pubProg
  refine List.pairwise_append.2 ⟨List.pairwise_append.2 ⟨?_, ?_, ?_⟩, ?_, ?_⟩
  · refine List.pairwise_flatMap.2 ⟨fun a _ => ?_, ?_⟩
    · unfold datW; split
      · exact List.pairwise_singleton _ _
      · exact List.Pairwise.nil
    · refine List.pairwise_lt_range.imp (fun {a1 a2} hlt => ?_)
      intro x hx y hy b hb
      rw [(datW_mem hx).1] at hb; cases hb
      rw [(datW_mem hy).1]; intro e; cases e; omega
  · refine List.pairwise_map.2 (List.Pairwise.imp (fun _ => ?_) List.pairwise_lt_range)
    intro b hb; cases hb
  · intro x hx y hy b hb
    obtain ⟨q, -, rfl⟩ := List.mem_map.1 hy
    intro e; cases e
  · simp
  · intro x hx y hy b hb
    simp only [List.mem_cons, List.not_mem_nil, or_false] at hy
    rcases hy with rfl | rfl <;> intro e <;> cases e

theorem opProg_datOnce (enc : Slot K V → Nat) (dval : K → V → Nat) (W n : Nat) (o : TOp K V)
    (T : Table K V) : DatOnce (opProg enc dval W n o T) := by
  unfold DatOnce
  cases o <;> simp [opProg]

end Prog

/-! ## The writer's program over a graph -/

section Writer
set_option linter.unusedSectionVars false
variable {E L K VV : Type} [DecidableEq K] {X : Writer E L Nat} {T : Track X}

/-- Event `e` is the store `s` (through the layout `lay`). -/
def Real (X : Writer E L Nat) (lay : TLoc → L) (e : E) (s : PSt) : Prop :=
  X.G.isW e ∧ X.G.loc e = lay s.loc ∧ (X.G.lab e).wval = s.val ∧
    (s.rel = true → X.G.isRel e ∧ X.G.atomic e)

/-- **The writer's program on one table, over a graph** (the axiomatised mapping; see the
module docs). `tab` is the table after each writer operation of its life `[pub, dF)`. -/
structure WProg (Tb : TableLocs X T) (C : Cfg K) (h2 : Nat → Nat) (tab : Nat → Table K VV)
    (dF : Nat) where
  /-- `Group::WIDTH` and the bucket count -/
  W : Nat
  n : Nat
  hWn : W ≤ n
  hn : (tab Tb.pub).n = n
  /-- the table's memory layout: distinct locations are distinct addresses -/
  lay : TLoc → L
  lay_inj : ∀ a b, a.Valid W n → b.Valid W n → lay a = lay b → a = b
  hctrl : ∀ q, q < n + W → Tb.ctrl q = lay (.ctrl q)
  /-- positions past the control array are not accessed; `TableLocs.ctrl` names them as their
  bucket's primary byte -/
  hwrap : ∀ q, n + W ≤ q → Tb.ctrl q = Tb.ctrl (q % n)
  hbkt : ∀ q, Tb.bkt q = q % n
  hgrowth : Tb.growth = lay .growth
  htomb : Tb.tomb = lay .tomb
  /-- `TableLocs.tl` is the control array and the counters -/
  tl_lay : ∀ ℓ, Tb.tl ℓ → (∃ q, q < n + W ∧ ℓ = lay (.ctrl q)) ∨ ℓ = lay .growth ∨ ℓ = lay .tomb
  /-- the bucket data encoding -/
  dval : K → VV → Nat
  /-- the table effect of each writer operation (model writer step) -/
  ops : Nat → TOp K VV
  hops : ∀ x, Tb.pub < x → x < dF → (ops x).Ok (tab (x - 1)) ∧ tab x = (ops x).apply (tab (x - 1))
  /-- the events realising each operation's program, in program order -/
  ev : Nat → List E
  ev_len : ∀ x, Tb.pub ≤ x → x < dF →
    (ev x).length = (progAt (Bytes.encSlot C.hash h2) dval W n Tb.pub tab ops x).length
  ev_real : ∀ x, Tb.pub ≤ x → x < dF → ∀ i (hi1 : i < (ev x).length)
    (hi2 : i < (progAt (Bytes.encSlot C.hash h2) dval W n Tb.pub tab ops x).length),
    Real X lay (ev x)[i] (progAt (Bytes.encSlot C.hash h2) dval W n Tb.pub tab ops x)[i]
  ev_op : ∀ x, Tb.pub ≤ x → x < dF → ∀ e ∈ ev x, X.op e = some x
  ev_po : ∀ x, Tb.pub ≤ x → x < dF → (ev x).Pairwise X.G.po
  /-- the initialisation is `po`-before the publishing `current` store -/
  ev_S : ∀ e ∈ ev Tb.pub, X.G.po e Tb.S
  /-- the operations of the table's life store to its memory only by their program -/
  complete : ∀ w x a, X.G.isW w → X.op w = some x → Tb.pub ≤ x → x < dF → a.Valid W n →
    X.G.loc w = lay a → w ∈ ev x

namespace WProg
variable {Tb : TableLocs X T} {C : Cfg K} {h2 : Nat → Nat} {tab : Nat → Table K VV} {dF : Nat}
  (P : WProg Tb C h2 tab dF)

/-- The program of operation `x`. -/
abbrev prog (x : Nat) : List PSt :=
  progAt (Bytes.encSlot C.hash h2) P.dval P.W P.n Tb.pub tab P.ops x

theorem prog_pub : P.prog Tb.pub =
    pubProg (Bytes.encSlot C.hash h2) P.dval P.W P.n (tab Tb.pub) := by
  simp [prog, progAt]

theorem prog_op {x : Nat} (h : x ≠ Tb.pub) : P.prog x =
    opProg (Bytes.encSlot C.hash h2) P.dval P.W P.n (P.ops x) (tab x) := by
  simp [prog, progAt, h]

theorem n_pos (hH : Hist C tab Tb.pub dF) (hF : Tb.pub < dF) : 0 < P.n := by
  rw [← P.hn]; exact Nat.pos_of_isPowerOfTwo (hH.wf _ (Nat.le_refl _) hF).pow2

theorem n_eq (hH : Hist C tab Tb.pub dF) {x : Nat} (h1 : Tb.pub ≤ x) (h2 : x < dF) :
    (tab x).n = P.n := by
  rw [hH.n_eq h1 h2, P.hn]

/-- Each store of the program is an event of the operation. -/
theorem stored {x : Nat} (h1 : Tb.pub ≤ x) (h2 : x < dF) {s : PSt} (hs : s ∈ P.prog x) :
    ∃ e ∈ P.ev x, Real X P.lay e s := by
  obtain ⟨i, hi, rfl⟩ := List.mem_iff_getElem.1 hs
  have hi' : i < (P.ev x).length := by rw [P.ev_len x h1 h2]; exact hi
  exact ⟨_, List.getElem_mem hi', P.ev_real x h1 h2 i hi' hi⟩

/-- Each event of the operation is a store of the program. -/
theorem real_of_mem {x : Nat} (h1 : Tb.pub ≤ x) (h2 : x < dF) {e : E} (he : e ∈ P.ev x) :
    ∃ s ∈ P.prog x, Real X P.lay e s := by
  obtain ⟨i, hi, rfl⟩ := List.mem_iff_getElem.1 he
  have hi' : i < (P.prog x).length := by rw [← P.ev_len x h1 h2]; exact hi
  exact ⟨_, List.getElem_mem hi', P.ev_real x h1 h2 i hi hi'⟩

/-- The program's locations exist. -/
theorem prog_valid (hH : Hist C tab Tb.pub dF) {x : Nat} (h1 : Tb.pub ≤ x) (h2 : x < dF)
    {s : PSt} (hs : s ∈ P.prog x) : s.loc.Valid P.W P.n := by
  by_cases e : x = Tb.pub
  · subst e
    rw [prog_pub] at hs
    simp only [pubProg, List.mem_append, List.mem_flatMap, List.mem_map, List.mem_cons,
      List.not_mem_nil] at hs
    rcases hs with (⟨a, -, ha⟩ | ⟨q, hq, rfl⟩) | (rfl | rfl | h)
    · rw [(datW_mem ha).1]; trivial
    · exact List.mem_range.1 hq
    · trivial
    · trivial
    · exact h.elim
  · rw [prog_op P e] at hs
    have hlt : Tb.pub < x := by omega
    have hok := (P.hops x hlt h2).1
    have hn' : (tab (x - 1)).n = P.n := P.n_eq hH (by omega) (by omega)
    cases ho : P.ops x with
    | none => rw [ho] at hs; simp [opProg] at hs
    | ins i k v =>
      rw [ho] at hs hok
      have hi : i < P.n := hn' ▸ hok.2
      simp only [opProg, List.mem_cons, List.not_mem_nil, or_false] at hs
      rcases hs with rfl | rfl | rfl | rfl
      · trivial
      · trivial
      · show i < P.n + P.W; omega
      · exact idx2_lt P.hWn hi
    | rem i k v =>
      rw [ho] at hs hok
      have hi : i < P.n := hn' ▸ hok.2
      simp only [opProg, List.mem_cons, List.not_mem_nil, or_false] at hs
      rcases hs with rfl | rfl | rfl
      · show i < P.n + P.W; omega
      · exact idx2_lt P.hWn hi
      · trivial

/-- The store of the program to a location is the store of the operation `w` there. -/
theorem loc_of_mem (hH : Hist C tab Tb.pub dF) {x : Nat} (h1 : Tb.pub ≤ x) (h2 : x < dF)
    {w : E} {a : TLoc} (ha : a.Valid P.W P.n) (hw : X.G.isW w) (hop : X.op w = some x)
    (hl : X.G.loc w = P.lay a) : ∃ s ∈ P.prog x, s.loc = a ∧ Real X P.lay w s := by
  obtain ⟨s, hs, hR⟩ := P.real_of_mem h1 h2 (P.complete w x a hw hop h1 h2 ha hl)
  exact ⟨s, hs, P.lay_inj _ _ (P.prog_valid hH h1 h2 hs) ha (hR.2.1.symm.trans hl), hR⟩

/-! ### Versions of the tracked locations -/

/-- A store of the program sets the version's value. -/
theorem vof_stored (htr : ∀ a, a.Valid P.W P.n → T.tr (P.lay a)) (hH : Hist C tab Tb.pub dF)
    {x : Nat} (h1 : Tb.pub ≤ x) (h2 : x < dF) {s : PSt} (hs : s ∈ P.prog x) :
    T.vof x (P.lay s.loc) = s.val := by
  obtain ⟨e, he, hR⟩ := P.stored h1 h2 hs
  have := T.wval e x hR.1 (by rw [hR.2.1]; exact htr _ (P.prog_valid hH h1 h2 hs))
    (P.ev_op x h1 h2 e he)
  rw [← hR.2.1, ← this, hR.2.2.1]

/-- A location the program does not store keeps its value. -/
theorem vof_unstored (htr : ∀ a, a.Valid P.W P.n → T.tr (P.lay a)) (hH : Hist C tab Tb.pub dF)
    {y : Nat} (h1 : Tb.pub ≤ y + 1) (h2 : y + 1 < dF) {a : TLoc} (ha : a.Valid P.W P.n)
    (hno : ∀ s ∈ P.prog (y + 1), s.loc ≠ a) : T.vof (y + 1) (P.lay a) = T.vof y (P.lay a) := by
  apply T.frame _ y (htr a ha)
  intro w hw hl hop
  obtain ⟨s, hs, hsl, -⟩ := P.loc_of_mem hH h1 h2 ha hw hop hl
  exact hno s hs hsl

/-- **The tracked values are the model's** (`henc` and the counters, for positions in the
control array). -/
theorem vof_eq (htr : ∀ a, a.Valid P.W P.n → T.tr (P.lay a)) (hH : Hist C tab Tb.pub dF) :
    ∀ x, Tb.pub ≤ x → x < dF →
      (∀ q, q < P.n + P.W →
        T.vof x (P.lay (.ctrl q)) = Bytes.encSlot C.hash h2 ((tab x).slot (q % P.n))) ∧
      T.vof x (P.lay .growth) = (tab x).growthLeft ∧
      T.vof x (P.lay .tomb) = (tab x).tombstones := by
  have base : ∀ x, x = Tb.pub → x < dF →
      (∀ q, q < P.n + P.W →
        T.vof x (P.lay (.ctrl q)) = Bytes.encSlot C.hash h2 ((tab x).slot (q % P.n))) ∧
      T.vof x (P.lay .growth) = (tab x).growthLeft ∧
      T.vof x (P.lay .tomb) = (tab x).tombstones := by
    intro x e hF
    subst e
    have hm : ∀ s, s ∈ pubProg (Bytes.encSlot C.hash h2) P.dval P.W P.n (tab Tb.pub) →
        T.vof Tb.pub (P.lay s.loc) = s.val := fun s hs =>
      P.vof_stored htr hH (Nat.le_refl _) hF (by rw [prog_pub]; exact hs)
    refine ⟨fun q hq => ?_, ?_, ?_⟩
    · exact hm ⟨.ctrl q, _, false⟩ (List.mem_append_left _ (List.mem_append_right _
        (List.mem_map.2 ⟨q, List.mem_range.2 hq, rfl⟩)))
    · exact hm ⟨.growth, _, false⟩ (List.mem_append_right _ (by simp))
    · exact hm ⟨.tomb, _, false⟩ (List.mem_append_right _ (by simp))
  intro x
  induction x with
  | zero => intro h1 h2; exact base 0 (by omega) h2
  | succ y ih =>
    intro h1 h2
    by_cases e : y + 1 = Tb.pub
    · exact base _ e h2
    have hpy : Tb.pub ≤ y := by omega
    obtain ⟨ihc, ihg, iht⟩ := ih hpy (by omega)
    have hlt : Tb.pub < y + 1 := by omega
    obtain ⟨hok, happ⟩ := P.hops (y + 1) hlt h2
    simp only [Nat.add_sub_cancel] at hok happ
    have hprog := prog_op P e
    have hst : ∀ s, s ∈ P.prog (y + 1) → T.vof (y + 1) (P.lay s.loc) = s.val :=
      fun s hs => P.vof_stored htr hH h1 h2 hs
    have hun : ∀ a, a.Valid P.W P.n → (∀ s ∈ P.prog (y + 1), s.loc ≠ a) →
        T.vof (y + 1) (P.lay a) = T.vof y (P.lay a) :=
      fun a ha hno => P.vof_unstored htr hH h1 h2 ha hno
    have hn' : (tab y).n = P.n := P.n_eq hH hpy (by omega)
    cases ho : P.ops (y + 1) with
    | none =>
      rw [ho] at hprog happ
      have hno : ∀ a, ∀ s ∈ P.prog (y + 1), s.loc ≠ a := by
        intro a s hs; rw [hprog] at hs; simp [opProg] at hs
      simp only [TOp.apply] at happ
      rw [happ]
      refine ⟨fun q hq => ?_, ?_, ?_⟩
      · rw [hun (.ctrl q) hq (hno _), ihc q hq]
      · rw [hun .growth trivial (hno _), ihg]
      · rw [hun .tomb trivial (hno _), iht]
    | ins i k v =>
      rw [ho] at hprog happ hok
      have hi : i < P.n := hn' ▸ hok.2
      simp only [TOp.apply] at happ
      refine ⟨fun q hq => ?_, ?_, ?_⟩
      · by_cases hqi : q % P.n = i
        · rw [hqi]
          rcases pos_of_mod P.hWn hi hq hqi with rfl | rfl
          · exact hst ⟨.ctrl q, _, true⟩ (by rw [hprog]; exact List.mem_cons_of_mem _ (List.mem_cons_of_mem _ List.mem_cons_self))
          · exact hst ⟨.ctrl (idx2 P.W P.n i), _, true⟩ (by rw [hprog]; exact List.mem_cons_of_mem _ (List.mem_cons_of_mem _ (List.mem_cons_of_mem _ List.mem_cons_self)))
        · have hno : ∀ s ∈ P.prog (y + 1), s.loc ≠ .ctrl q := by
            intro s hs; rw [hprog] at hs
            simp only [opProg, List.mem_cons, List.not_mem_nil, or_false] at hs
            rcases hs with rfl | rfl | rfl | rfl
            · intro e; cases e
            · intro e; cases e
            · intro e; cases e; exact hqi (Nat.mod_eq_of_lt hi)
            · intro e; cases e; exact hqi (idx2_mod P.hWn hi)
          rw [hun (.ctrl q) hq hno, ihc q hq, happ]
          simp [insertAt, Table.set, hqi]
      · exact hst ⟨.growth, _, true⟩ (by rw [hprog]; exact List.mem_cons_of_mem _ List.mem_cons_self)
      · have hno : ∀ s ∈ P.prog (y + 1), s.loc ≠ .tomb := by
          intro s hs; rw [hprog] at hs
          simp only [opProg, List.mem_cons, List.not_mem_nil, or_false] at hs
          rcases hs with rfl | rfl | rfl | rfl <;> intro e <;> cases e
        rw [hun .tomb trivial hno, iht, happ]; rfl
    | rem i k v =>
      rw [ho] at hprog happ hok
      have hi : i < P.n := hn' ▸ hok.2
      simp only [TOp.apply] at happ
      refine ⟨fun q hq => ?_, ?_, ?_⟩
      · by_cases hqi : q % P.n = i
        · rw [hqi]
          rcases pos_of_mod P.hWn hi hq hqi with rfl | rfl
          · exact hst ⟨.ctrl q, _, true⟩ (by rw [hprog]; exact List.mem_cons_self)
          · exact hst ⟨.ctrl (idx2 P.W P.n i), _, true⟩ (by rw [hprog]; exact List.mem_cons_of_mem _ List.mem_cons_self)
        · have hno : ∀ s ∈ P.prog (y + 1), s.loc ≠ .ctrl q := by
            intro s hs; rw [hprog] at hs
            simp only [opProg, List.mem_cons, List.not_mem_nil, or_false] at hs
            rcases hs with rfl | rfl | rfl
            · intro e; cases e; exact hqi (Nat.mod_eq_of_lt hi)
            · intro e; cases e; exact hqi (idx2_mod P.hWn hi)
            · intro e; cases e
          rw [hun (.ctrl q) hq hno, ihc q hq, happ]
          simp [removeAt, Table.set, hqi]
      · have hno : ∀ s ∈ P.prog (y + 1), s.loc ≠ .growth := by
          intro s hs; rw [hprog] at hs
          simp only [opProg, List.mem_cons, List.not_mem_nil, or_false] at hs
          rcases hs with rfl | rfl | rfl <;> intro e <;> cases e
        rw [hun .growth trivial hno, ihg, happ]; rfl
      · exact hst ⟨.tomb, _, true⟩ (by rw [hprog]; exact List.mem_cons_of_mem _ (List.mem_cons_of_mem _ List.mem_cons_self))

/-- **`henc` from the program**: the control byte at any position after writer operation `x`
is the encoding of its bucket's slot in the model's table after `x`. -/
theorem henc (hH : Hist C tab Tb.pub dF) (htr : ∀ a, a.Valid P.W P.n → T.tr (P.lay a)) :
    ∀ x q, Tb.pub ≤ x → x < dF →
      T.vof x (Tb.ctrl q) = Bytes.encSlot C.hash h2 ((tab x).slot (Tb.bkt q)) := by
  intro x q h1 h2
  have hn0 := P.n_pos hH (by omega)
  rw [P.hbkt]
  by_cases hq : q < P.n + P.W
  · rw [P.hctrl q hq]; exact (P.vof_eq htr hH x h1 h2).1 q hq
  · rw [P.hwrap q (by omega), P.hctrl _ (by have := Nat.mod_lt q hn0; omega),
      (P.vof_eq htr hH x h1 h2).1 _ (by have := Nat.mod_lt q hn0; omega), Nat.mod_mod]

/-- The counters from the program: `growth_left` and `tombstones` after writer operation `x`
are the model table's. -/
theorem hcnt (hH : Hist C tab Tb.pub dF) (htr : ∀ a, a.Valid P.W P.n → T.tr (P.lay a)) :
    ∀ x, Tb.pub ≤ x → x < dF →
      T.vof x Tb.growth = (tab x).growthLeft ∧ T.vof x Tb.tomb = (tab x).tombstones := by
  intro x h1 h2
  rw [P.hgrowth, P.htomb]
  exact (P.vof_eq htr hH x h1 h2).2

/-! ### The bucket data -/

theorem first_po {x : Nat} (h1 : Tb.pub ≤ x) (h2 : x < dF) {s0 : PSt} {rest : List PSt}
    (hp : P.prog x = s0 :: rest) :
    ∃ d ∈ P.ev x, Real X P.lay d s0 ∧ ∀ e ∈ P.ev x, e ≠ d → X.G.po d e := by
  have hlen := P.ev_len x h1 h2
  have hpo := P.ev_po x h1 h2
  cases hev : P.ev x with
  | nil => rw [hev] at hlen; simp [prog] at hp; rw [hp] at hlen; simp at hlen
  | cons d es =>
    have h0 : 0 < (P.ev x).length := by rw [hev]; simp
    have h0' : 0 < (P.prog x).length := by rw [hp]; simp
    have hR := P.ev_real x h1 h2 0 h0 h0'
    have hs0 : (P.prog x)[0]'h0' = s0 := by simp [hp]
    have hd : (P.ev x)[0]'h0 = d := by simp [hev]
    rw [hs0, hd] at hR
    rw [hev] at hpo
    refine ⟨d, List.mem_cons_self, hR, fun e he hne => ?_⟩
    rcases List.mem_cons.1 he with h | h
    · exact (hne h).elim
    · exact List.rel_of_pairwise_cons hpo h

/-- **`TableData` from the program.** -/
def tableData (hH : Hist C tab Tb.pub dF) : TableData Tb tab dF where
  dat b := P.lay (.dat b)
  dval := P.dval
  write := by
    intro b y k v hy0 hyF hys hyi
    have hbn : b < P.n := by
      apply Nat.lt_of_not_le; intro hle
      have := (hH.wf y hy0 hyF).bound b (by rw [P.n_eq hH hy0 hyF]; exact hle)
      rw [hys] at this; cases this
    by_cases e : y = Tb.pub
    · subst e
      have hmem : (⟨.dat b, P.dval k v, false⟩ : PSt) ∈ P.prog Tb.pub := by
        rw [prog_pub]
        apply List.mem_append_left; apply List.mem_append_left
        exact List.mem_flatMap.2 ⟨b, List.mem_range.2 hbn, by simp [datW, hys]⟩
      obtain ⟨d, hd, hR⟩ := P.stored hy0 hyF hmem
      exact ⟨d, hR.1, hR.2.1, P.ev_op _ hy0 hyF d hd, hR.2.2.1, fun _ => P.ev_S d hd,
        fun h => absurd h (Nat.lt_irrefl _)⟩
    · have hpy : Tb.pub < y := by omega
      have hprev : (tab (y - 1)).slot b = .empty := hyi.resolve_left e
      obtain ⟨hok, happ⟩ := P.hops y hpy hyF
      have hprog := prog_op P e
      cases ho : P.ops y with
      | none =>
        rw [ho] at happ; simp only [TOp.apply] at happ
        rw [happ, hprev] at hys; cases hys
      | rem i k' v' =>
        rw [ho] at happ; simp only [TOp.apply] at happ
        rw [happ] at hys; simp only [removeAt, Table.set] at hys
        split at hys
        · cases hys
        · rw [hprev] at hys; cases hys
      | ins i k' v' =>
        rw [ho] at happ hprog; simp only [TOp.apply] at happ
        rw [happ] at hys; simp only [insertAt, Table.set] at hys
        split at hys
        · next hbi =>
          cases hys; subst hbi
          obtain ⟨d, hd, hR, hpo⟩ := P.first_po hy0 hyF (by rw [hprog]; rfl)
          refine ⟨d, hR.1, hR.2.1, P.ev_op _ hy0 hyF d hd, hR.2.2.1, fun h => (e h).elim, ?_⟩
          intro _ wc q hwc hl _ hop
          have hn0 := P.n_pos hH (by omega)
          have hq' : ∃ q', q' < P.n + P.W ∧ Tb.ctrl q = P.lay (.ctrl q') := by
            by_cases hq : q < P.n + P.W
            · exact ⟨q, hq, P.hctrl q hq⟩
            · have := Nat.mod_lt q hn0
              exact ⟨q % P.n, by omega, by rw [P.hwrap q (by omega), P.hctrl _ (by omega)]⟩
          obtain ⟨q', hq'1, hq'2⟩ := hq'
          have hmem := P.complete wc y (.ctrl q') hwc hop hy0 hyF hq'1 (hl.trans hq'2)
          refine hpo wc hmem (fun hwd => ?_)
          have := P.lay_inj (.dat b) (.ctrl q') trivial hq'1
            (hR.2.1.symm.trans ((congrArg X.G.loc hwd).symm.trans (hl.trans hq'2)))
          cases this
        · rw [hprev] at hys; cases hys
  only := by
    intro w j b hw hl hop hj0 hjF
    obtain ⟨s, hs, hsl, -⟩ := P.loc_of_mem hH hj0 hjF (a := .dat b) trivial hw hop hl
    by_cases e : j = Tb.pub
    · subst e
      rw [prog_pub] at hs
      obtain ⟨k, v, hkv⟩ := pubProg_dat hs hsl
      exact ⟨by rw [hkv]; nofun, Or.inl rfl⟩
    · rw [prog_op P e] at hs
      have hpj : Tb.pub < j := by omega
      obtain ⟨hok, happ⟩ := P.hops j hpj hjF
      cases ho : P.ops j with
      | none => rw [ho] at hs; simp [opProg] at hs
      | rem i k v =>
        rw [ho] at hs
        simp only [opProg, List.mem_cons, List.not_mem_nil, or_false] at hs
        rcases hs with rfl | rfl | rfl <;> cases hsl
      | ins i k v =>
        rw [ho] at hs hok happ
        simp only [opProg, List.mem_cons, List.not_mem_nil, or_false] at hs
        rcases hs with rfl | rfl | rfl | rfl <;> cases hsl
        simp only [TOp.apply] at happ
        refine ⟨by rw [happ]; simp [insertAt, Table.set], .inr hok.1⟩
  uniq := by
    intro w w' j b hw hw' hl hl' hop hop' hj0 hjF
    obtain ⟨i1, h1, rfl⟩ := List.mem_iff_getElem.1
      (P.complete w j (.dat b) hw hop hj0 hjF trivial hl)
    obtain ⟨i2, h2', rfl⟩ := List.mem_iff_getElem.1
      (P.complete w' j (.dat b) hw' hop' hj0 hjF trivial hl')
    have hlen := P.ev_len j hj0 hjF
    have hloc : ∀ i (hi : i < (P.ev j).length), X.G.loc (P.ev j)[i] = P.lay (.dat b) →
        ((P.prog j)[i]'(hlen ▸ hi)).loc = .dat b := by
      intro i hi hli
      have hR := P.ev_real j hj0 hjF i hi (hlen ▸ hi)
      exact P.lay_inj _ _ (P.prog_valid hH hj0 hjF (List.getElem_mem _)) trivial
        (hR.2.1.symm.trans hli)
    have hd1 := hloc i1 h1 hl
    have hd2 := hloc i2 h2' hl'
    have hdo : DatOnce (P.prog j) := by
      by_cases e : j = Tb.pub
      · subst e; rw [prog_pub]; exact pubProg_datOnce _ _ _ _ _
      · rw [prog_op P e]; exact opProg_datOnce _ _ _ _ _ _
    have hpw := List.pairwise_iff_getElem.1 hdo
    rcases Nat.lt_trichotomy i1 i2 with h | h | h
    · exact (hpw i1 i2 (hlen ▸ h1) (hlen ▸ h2') h b hd1 hd2).elim
    · subst h; rfl
    · exact (hpw i2 i1 (hlen ▸ h2') (hlen ▸ h1) h b hd2 hd1).elim

/-! ### The table's life -/

omit [DecidableEq K] in
theorem opProg_rel {enc : Slot K VV → Nat} {dval : K → VV → Nat} {W n : Nat} {o : TOp K VV}
    {T' : Table K VV} {s : PSt} (hs : s ∈ opProg enc dval W n o T') (hd : ∀ b, s.loc ≠ .dat b) :
    s.rel = true := by
  cases o with
  | none => simp [opProg] at hs
  | ins i k v =>
    simp only [opProg, List.mem_cons, List.not_mem_nil, or_false] at hs
    rcases hs with rfl | rfl | rfl | rfl
    · exact (hd i rfl).elim
    all_goals rfl
  | rem i k v =>
    simp only [opProg, List.mem_cons, List.not_mem_nil, or_false] at hs
    rcases hs with rfl | rfl | rfl <;> rfl

omit [DecidableEq K] in
theorem opProg_ctrl {enc : Slot K VV → Nat} {dval : K → VV → Nat} {W n : Nat} (hWn : W ≤ n)
    {o : TOp K VV} {T0 T' : Table K VV} (hok : o.Ok T0) (hn : T0.n = n) {s : PSt} {q : Nat}
    (hs : s ∈ opProg enc dval W n o T') (hl : s.loc = .ctrl q) : q % n = o.bucket := by
  cases o with
  | none => simp [opProg] at hs
  | ins i k v =>
    have hi : i < n := hn ▸ hok.2
    simp only [opProg, List.mem_cons, List.not_mem_nil, or_false] at hs
    rcases hs with rfl | rfl | rfl | rfl <;> cases hl
    · exact Nat.mod_eq_of_lt hi
    · exact idx2_mod hWn hi
  | rem i k v =>
    have hi : i < n := hn ▸ hok.2
    simp only [opProg, List.mem_cons, List.not_mem_nil, or_false] at hs
    rcases hs with rfl | rfl | rfl <;> cases hl
    · exact Nat.mod_eq_of_lt hi
    · exact idx2_mod hWn hi

omit [DecidableEq K] in
theorem opProg_counters {enc : Slot K VV → Nat} {dval : K → VV → Nat} {W n : Nat}
    {o : TOp K VV} {T' : Table K VV} {s s' : PSt} (hs : s ∈ opProg enc dval W n o T')
    (hs' : s' ∈ opProg enc dval W n o T') (hl : s.loc = .tomb) (hl' : s'.loc = .growth) :
    False := by
  cases o with
  | none => simp [opProg] at hs
  | ins i k v =>
    simp only [opProg, List.mem_cons, List.not_mem_nil, or_false] at hs
    rcases hs with rfl | rfl | rfl | rfl <;> cases hl
  | rem i k v =>
    simp only [opProg, List.mem_cons, List.not_mem_nil, or_false] at hs'
    rcases hs' with rfl | rfl | rfl <;> cases hl'

/-- A control position as a location of the layout, with its bucket. -/
theorem ctrl_lay (hH : Hist C tab Tb.pub dF) (hF : Tb.pub < dF) (q : Nat) :
    ∃ q', q' < P.n + P.W ∧ Tb.ctrl q = P.lay (.ctrl q') ∧ q' % P.n = Tb.bkt q := by
  have hn0 := P.n_pos hH hF
  rw [P.hbkt]
  by_cases hq : q < P.n + P.W
  · exact ⟨q, hq, P.hctrl q hq, rfl⟩
  · have := Nat.mod_lt q hn0
    exact ⟨q % P.n, by omega, by rw [P.hwrap q (by omega), P.hctrl _ (by omega)], Nat.mod_mod _ _⟩

include P in
/-- **`Life` from the program**: during the table's life `[pub, dF)` its stores after the
publication are `Release` atomic, hit one bucket's control bytes, and never both counters. -/
theorem life (hH : Hist C tab Tb.pub dF) : Life Tb dF where
  rel := by
    intro w i hw htl hop hpi hiF
    have hne : i ≠ Tb.pub := by omega
    have hdat : ∀ a, (∃ q, q < P.n + P.W ∧ a = TLoc.ctrl q) ∨ a = .growth ∨ a = .tomb →
        ∀ b, a ≠ .dat b := by
      rintro a (⟨q, -, rfl⟩ | rfl | rfl) b e <;> cases e
    have hex : ∃ a, a.Valid P.W P.n ∧ X.G.loc w = P.lay a ∧ ∀ b, a ≠ .dat b := by
      rcases P.tl_lay _ htl with ⟨q, hq, e⟩ | e | e
      · exact ⟨.ctrl q, hq, e, hdat _ (.inl ⟨q, hq, rfl⟩)⟩
      · exact ⟨.growth, trivial, e, hdat _ (.inr (.inl rfl))⟩
      · exact ⟨.tomb, trivial, e, hdat _ (.inr (.inr rfl))⟩
    obtain ⟨a, ha, hl, hd⟩ := hex
    obtain ⟨s, hs, hsl, hR⟩ := P.loc_of_mem hH (by omega) hiF ha hw hop hl
    rw [prog_op P hne] at hs
    exact hR.2.2.2 (opProg_rel hs (hsl ▸ hd))
  one_bucket := by
    intro p q w w' i hpi hiF hw hw' hl hl' hop hop'
    have hne : i ≠ Tb.pub := by omega
    have hF : Tb.pub < dF := by omega
    obtain ⟨p', hp', ep, bp⟩ := P.ctrl_lay hH hF p
    obtain ⟨q', hq', eq, bq⟩ := P.ctrl_lay hH hF q
    obtain ⟨s, hs, hsl, -⟩ := P.loc_of_mem hH (by omega) hiF (a := .ctrl p') hp' hw hop (hl.trans ep)
    obtain ⟨s', hs', hsl', -⟩ :=
      P.loc_of_mem hH (by omega) hiF (a := .ctrl q') hq' hw' hop' (hl'.trans eq)
    rw [prog_op P hne] at hs hs'
    have hok := (P.hops i hpi hiF).1
    have hn' : (tab (i - 1)).n = P.n := P.n_eq hH (by omega) (by omega)
    rw [← bp, ← bq, opProg_ctrl P.hWn hok hn' hs hsl, opProg_ctrl P.hWn hok hn' hs' hsl']
  counters_sep := by
    intro w w' i hpi hiF hw hw' hl hl' hop hop'
    have hne : i ≠ Tb.pub := by omega
    obtain ⟨s, hs, hsl, -⟩ :=
      P.loc_of_mem hH (by omega) hiF (a := .tomb) trivial hw hop (hl.trans P.htomb)
    obtain ⟨s', hs', hsl', -⟩ :=
      P.loc_of_mem hH (by omega) hiF (a := .growth) trivial hw' hop' (hl'.trans P.hgrowth)
    rw [prog_op P hne] at hs hs'
    exact opProg_counters hs hs' hsl hsl'

end WProg

/-- The table effects of a `Hist`: every `TStep` is an `insertAt`, a `removeAt`, or nothing
(the `ops` of a `WProg`). -/
theorem exists_ops {C : Cfg K} {tab : Nat → Table K VV} {lo hi : Nat} (hH : Hist C tab lo hi) :
    ∃ ops : Nat → TOp K VV, ∀ x, lo < x → x < hi →
      (ops x).Ok (tab (x - 1)) ∧ tab x = (ops x).apply (tab (x - 1)) := by
  have h : ∀ x, ∃ o : TOp K VV, lo < x → x < hi →
      o.Ok (tab (x - 1)) ∧ tab x = o.apply (tab (x - 1)) := by
    intro x
    by_cases hx : lo < x ∧ x < hi
    · have hs := hH.step (x - 1) (by omega) (by omega)
      have hx1 : x - 1 + 1 = x := by omega
      rw [hx1] at hs
      have hwf := hH.wf x (by omega) hx.2
      rcases hs with h | ⟨i, k, v, hfe, -, h⟩ | ⟨i, k, v, hsl, h⟩
      · exact ⟨.none, fun _ _ => ⟨trivial, h⟩⟩
      · refine ⟨.ins i k v, fun _ _ => ⟨⟨(firstEmpty_spec hfe).1, ?_⟩, h⟩⟩
        apply Nat.lt_of_not_le; intro hle
        have := hwf.bound i (by rw [h]; exact hle)
        rw [h] at this; simp [insertAt, Table.set] at this
      · refine ⟨.rem i k v, fun _ _ => ⟨⟨hsl, ?_⟩, h⟩⟩
        apply Nat.lt_of_not_le; intro hle
        have := hwf.bound i (by rw [h]; exact hle)
        rw [h] at this; simp [removeAt, Table.set] at this
    · exact ⟨.none, fun h1 h2 => (hx ⟨h1, h2⟩).elim⟩
  exact ⟨fun x => Classical.choose (h x), fun x => Classical.choose_spec (h x)⟩

/-- **Property 18 for all reader threads, with the writer's program**: `readers_lin` with
`henc` and `TableData` derived from `WProg` (`WProg.henc`, `WProg.tableData`). -/
theorem readers_lin_prog {Tb : TableLocs X T} {C : Cfg K} {h2 : Nat → Nat} {tab : Nat → Table K VV}
    {dF : Nat} (P : WProg Tb C h2 tab dF) (hH : Hist C tab Tb.pub dF)
    (htr : ∀ a, a.Valid P.W P.n → T.tr (P.lay a))
    (hW : P.W.isPowerOfTwo) (hn : P.n.isPowerOfTwo) (hh2 : ∀ h, h2 h < 0x80)
    {mb : List Nat → Nat → List Bool} (hmb : Bytes.MatchOK mb)
    (us : List Nat) (hus : us.Nodup) (R : Nat → RThread Tb C P.W P.n dF) :
    ∃ (e : Nat → Nat → Nat) (σ : Nat → Nat → Slot K VV) (ℓ : Nat → K × List (List Nat) → Nat)
      (lin : List (Nat × (K × List (List Nat)))),
      (∀ u ∈ us, ThreadLin (R u) (h2 := h2) mb tab (P.tableData hH) (e u) (σ u) (ℓ u)) ∧
      lin.Pairwise (fun a b => ℓ a.1 a.2 ≤ ℓ b.1 b.2) ∧
      lin.Perm (us.flatMap (fun u => (R u).gets.map (fun G => (u, G)))) ∧
      ∀ u ∈ us, lin.filter (fun a => a.1 == u) = (R u).gets.map (fun G => (u, G)) :=
  readers_lin hW hn P.hWn hh2 hmb (P.life hH) hH (P.henc hH htr) (P.tableData hH) us hus R

end Writer

/-! ## `replace_table` and `collect` on one graph -/

section Shared
open Collect Collect.RC11Pin

/-- **One RC11 graph for the table and `collect`**: the writer structure (`Writer`: writer
mutex, operations in lock order) and `collect`'s (`CExec`: `COLLECTOR` mutex, pin events,
`defer`, `mark_ready`) on the same graph. -/
structure Shared (E L V : Type) where
  X : Writer E L V
  CX : CExec E L V
  hG : X.G = CX.G

/-- **`replace_table` in writer operation `r`** (the program, axiomatised mapping):
`self.table.current.store(new, Release)` (`Sw`), then the old table's `next_retired` and the
retired list (`mid`, not table locations a reader reads), then `collect::defer_by_id` (`D`),
in program order. -/
structure RetireProg {E L V : Type} (Sh : Shared E L V) (cur : L) (r : Nat) where
  Sw : E
  D : E
  mid : List E
  evs : List E
  evs_eq : evs = Sw :: (mid ++ [D])
  evs_po : evs.Pairwise Sh.X.G.po
  evs_op : ∀ e ∈ evs, Sh.X.op e = some r
  Sw_w : Sh.X.G.isW Sw
  Sw_loc : Sh.X.G.loc Sw = cur
  Sw_rel : Sh.X.G.isRel Sw ∧ Sh.X.G.atomic Sw

variable {E L V : Type} {Sh : Shared E L V}

/-- The replacing store is `po`-before the `defer`. -/
theorem RetireProg.Sw_D {cur : L} {r : Nat} (R : RetireProg Sh cur r) :
    R.Sw = R.D ∨ Sh.CX.G.po R.Sw R.D := by
  right
  have h := R.evs_po
  rw [R.evs_eq] at h
  rw [← Sh.hG]
  exact List.rel_of_pairwise_cons h (List.mem_append_right _ List.mem_cons_self)

/-- The publishing store `S` (operation `pub`) is `mo`-before the replacing store `Sw` of a
later operation: `Writer.mo_op` on the shared graph. -/
theorem RetireProg.mo_S {cur : L} {r pub : Nat} (R : RetireProg Sh cur r) {S : E}
    (hS : Sh.X.G.isW S) (hSl : Sh.X.G.loc S = cur) (hSop : Sh.X.op S = some pub)
    (hpr : pub < r) : Sh.CX.G.mo S R.Sw := by
  have hSw : Sh.X.op R.Sw = some r := R.evs_op _ (by rw [R.evs_eq]; exact List.mem_cons_self)
  have := Sh.X.mo_op hS R.Sw_w (hSl.trans R.Sw_loc.symm) hSop hSw hpr
  rw [Sh.hG] at this; exact this

/-- **`can_free_no_race` on one shared graph**: `hmo` and `hSw` of `RC11Free.can_free_no_race`
derived from the writer (`Writer.mo_op`) and `replace_table`'s program (`RetireProg`). `S` is
the store of `current` that published the table (operation `pub`), `r > pub` the operation
that replaced it, whose `defer_by_id` is the `defer` event `R.D`. -/
theorem can_free_no_race_shared {cur : L} {pub r : Nat} {S : E} (R : RetireProg Sh cur r)
    (hS : Sh.X.G.isW S) (hSl : Sh.X.G.loc S = cur) (hSop : Sh.X.op S = some pub)
    (hpr : pub < r)
    {lin : List E} (hlin : IsLin Sh.CX.G.hb lin) (hv : Sh.CX.Valid lin)
    {T a M A F Lc : E} {u : Tid} {c : Cb} {iT iD ia : Nat}
    (hT : lin[iT]? = some T) (hTl : (Sh.CX.act T).locked = true)
    (hc : c ∈ (Sh.CX.replay lin (iT + 1)).s.ran)
    (hD : lin[iD]? = some R.D) (hDa : Sh.CX.act R.D = .defer c.id c.byId)
    (hDt : (Sh.CX.replay lin iD).s.now = c.time)
    (ha : lin[ia]? = some a) (haa : Sh.CX.act a = .pinRegister u ∨ Sh.CX.act a = .pinOuter u)
    (hM : T = M ∨ Sh.CX.G.po T M) (hrf : Sh.CX.G.rf M A) (hMr : Sh.CX.G.isRel M)
    (hAa : Sh.CX.G.isAcq A) (hMat : Sh.CX.G.atomic M) (hAat : Sh.CX.G.atomic A)
    (hAF : Sh.CX.G.po A F)
    (hLc : Sh.CX.InRegion u a Lc) (hrfL : Sh.CX.G.rf S Lc) :
    ∀ x, Sh.CX.InRegion u a x → Sh.CX.G.hb x F :=
  RC11Free.can_free_no_race hlin hv hT hTl hc hD hDa hDt ha haa hM hrf hMr hAa hMat hAat hAF
    R.Sw_D (R.mo_S hS hSl hSop hpr) hLc hrfL

/-! ## Readers: pinned regions and `Read` calls -/

/-- **A pinned region** (`collect::pin(|pin| ...)`): the outermost pin event `a` of thread `u`
and its `unpinOuter` `z` (the end of the closure), with no `unpinOuter` of `u` in between. -/
structure PinRegion (CX : CExec E L V) (u : Tid) where
  a : E
  z : E
  a_act : CX.act a = .pinRegister u ∨ CX.act a = .pinOuter u
  a_tid : CX.G.tid a = u
  z_act : CX.act z = .unpinOuter u
  az : CX.G.po a z
  first : ∀ y, (y = a ∨ CX.G.po a y) → CX.G.po y z → CX.act y ≠ .unpinOuter u

/-- **One `Read` call in a pinned region** (`table.read(pin)` then `get` / `get_potential` /
`iter` / `len` / `capacity` / `clone`): `self.table.current()`, an `Acquire` load `Lc` of
`current`, then the accesses `acc` to the table memory through the returned `TableRef` (control
byte loads, bucket reads, counter loads, and later uses of the returned `&'a K`, `&'a V`).
`Read<'a>` and the returned references borrow the `Pin<'a>` of the closure, so every access is
`po`-before the region's end `z`. -/
structure RCall {CX : CExec E L V} {u : Tid} (P : PinRegion CX u) (cur : L) where
  Lc : E
  acc : List E
  Lc_loc : CX.G.loc Lc = cur
  Lc_acq : CX.G.isAcq Lc ∧ CX.G.atomic Lc
  aLc : CX.G.po P.a Lc
  Lcz : CX.G.po Lc P.z
  Lc_acc : ∀ x ∈ acc, CX.G.po Lc x
  acc_z : ∀ x ∈ acc, CX.G.po x P.z

theorem PinRegion.inRegion {CX : CExec E L V} {u : Tid} (P : PinRegion CX u) {x : E}
    (hax : CX.G.po P.a x) (hxz : CX.G.po x P.z) : CX.InRegion u P.a x :=
  ⟨(CX.cons.po_tid _ _ hax).symm.trans P.a_tid, .inr hax,
    fun y hy hyx => P.first y hy (CX.cons.po_trans _ _ _ hyx hxz)⟩

/-- The call's `current` load and all its accesses lie in the pinned region. -/
theorem RCall.inRegion {CX : CExec E L V} {u : Tid} {P : PinRegion CX u} {cur : L}
    (Cl : RCall P cur) : CX.InRegion u P.a Cl.Lc ∧ ∀ x ∈ Cl.acc, CX.InRegion u P.a x :=
  ⟨P.inRegion Cl.aLc Cl.Lcz,
    fun x hx => P.inRegion (CX.cons.po_trans _ _ _ Cl.aLc (Cl.Lc_acc x hx)) (Cl.acc_z x hx)⟩

/-- **A reader's accesses to a table happen before its free.** A `Read` call in a pinned region
whose `current` load read the table's publication `S`: every access of the call (and every
event of the region) happens before the free `F` of `prune_tables` that read `can_free = true`
(`mark_ready`'s store `M`, after the callback deferred by the replacing operation's
`defer_by_id`). All of `can_free_no_race`'s table-side hypotheses are derived: the reader's
`current` load in the pin (`RCall`), `hSw` and `hmo` (`can_free_no_race_shared`). -/
theorem reader_before_free {cur : L} {pub r : Nat} {S : E} (R : RetireProg Sh cur r)
    (hS : Sh.X.G.isW S) (hSl : Sh.X.G.loc S = cur) (hSop : Sh.X.op S = some pub)
    (hpr : pub < r)
    {lin : List E} (hlin : IsLin Sh.CX.G.hb lin) (hv : Sh.CX.Valid lin)
    {T M A F : E} {u : Tid} {c : Cb} {iT iD ia : Nat}
    (hT : lin[iT]? = some T) (hTl : (Sh.CX.act T).locked = true)
    (hc : c ∈ (Sh.CX.replay lin (iT + 1)).s.ran)
    (hD : lin[iD]? = some R.D) (hDa : Sh.CX.act R.D = .defer c.id c.byId)
    (hDt : (Sh.CX.replay lin iD).s.now = c.time)
    (hM : T = M ∨ Sh.CX.G.po T M) (hrf : Sh.CX.G.rf M A) (hMr : Sh.CX.G.isRel M)
    (hAa : Sh.CX.G.isAcq A) (hMat : Sh.CX.G.atomic M) (hAat : Sh.CX.G.atomic A)
    (hAF : Sh.CX.G.po A F)
    (P : PinRegion Sh.CX u) (ha : lin[ia]? = some P.a) (Cl : RCall P cur)
    (hrfL : Sh.CX.G.rf S Cl.Lc) :
    Sh.CX.G.hb Cl.Lc F ∧ (∀ x ∈ Cl.acc, Sh.CX.G.hb x F) ∧
      ∀ x, Sh.CX.InRegion u P.a x → Sh.CX.G.hb x F := by
  have h := can_free_no_race_shared R hS hSl hSop hpr hlin hv hT hTl hc hD hDa hDt ha P.a_act
    hM hrf hMr hAa hMat hAat hAF Cl.inRegion.1 hrfL
  exact ⟨h _ Cl.inRegion.1, fun x hx => h x (Cl.inRegion.2 x hx), h⟩


/-! ## The free and the readers' programs: all reader threads from their `Read` calls -/

/-- **`prune_tables` freeing the table** (the collect-side facts, `CExec`, property 11): the
operation `r > pub` replaced the table (`RetireProg`: `Sw`, then `defer_by_id` `D` of callback
`c`); `collect` ran `c` in the critical section `T`, `mark_ready` stored `can_free = true`
(`Release` `M`, `po`-after `T`); the pruner's `Acquire` load `A` read `M` and the free `F` is
`po`-after it, in writer operation `f` (`prune_tables` runs under the writer lock). `lin` is a
linearization of the graph valid for `collect`'s model. -/
structure FreeProg (Sh : Shared E L V) (cur : L) (S : E) (pub : Nat) where
  r : Nat
  R : RetireProg Sh cur r
  hpr : pub < r
  lin : List E
  hlin : IsLin Sh.CX.G.hb lin
  hv : Sh.CX.Valid lin
  T : E
  M : E
  A : E
  F : E
  c : Cb
  iT : Nat
  iD : Nat
  hT : lin[iT]? = some T
  hTl : (Sh.CX.act T).locked = true
  hc : c ∈ (Sh.CX.replay lin (iT + 1)).s.ran
  hD : lin[iD]? = some R.D
  hDa : Sh.CX.act R.D = .defer c.id c.byId
  hDt : (Sh.CX.replay lin iD).s.now = c.time
  hM : T = M ∨ Sh.CX.G.po T M
  hrf : Sh.CX.G.rf M A
  hMr : Sh.CX.G.isRel M
  hAa : Sh.CX.G.isAcq A
  hMat : Sh.CX.G.atomic M
  hAat : Sh.CX.G.atomic A
  hAF : Sh.CX.G.po A F
  f : Nat
  F_op : Sh.X.op F = some f

/-- **The free ends the table's life for its readers**: every access of a `Read` call whose
`current` load read the publication `S` happens before the free `F`, hence before writer
operation `f + 1` (the end of the table's life `[pub, f + 1)`). -/
theorem FreeProg.before {cur : L} {S : E} {pub : Nat} (Fp : FreeProg Sh cur S pub)
    (hS : Sh.X.G.isW S) (hSl : Sh.X.G.loc S = cur) (hSop : Sh.X.op S = some pub)
    {u : Tid} (P : PinRegion Sh.CX u) (Cl : RCall P cur) (hrfL : Sh.CX.G.rf S Cl.Lc) :
    (∀ x ∈ Cl.acc, Sh.X.G.hb x Fp.F) ∧ ∀ x ∈ Cl.acc, Sh.X.G.hb x (Sh.X.acq (Fp.f + 1)) := by
  obtain ⟨ia, hia⟩ := List.mem_iff_getElem?.1 (Fp.hlin.1 P.a)
  have h := (reader_before_free Fp.R hS hSl hSop Fp.hpr Fp.hlin Fp.hv Fp.hT Fp.hTl Fp.hc Fp.hD
    Fp.hDa Fp.hDt Fp.hM Fp.hrf Fp.hMr Fp.hAa Fp.hMat Fp.hAat Fp.hAF P hia Cl hrfL).2.1
  have hF : Sh.X.G.hb Fp.F (Sh.X.acq (Fp.f + 1)) :=
    Sh.X.op_hb Fp.F_op (Sh.X.acq_op _) (Nat.lt_succ_self _)
  have h' : ∀ x ∈ Cl.acc, Sh.X.G.hb x Fp.F := fun x hx => by rw [Sh.hG]; exact h x hx
  exact ⟨h', fun x hx => hb_trans (h' x hx) hF⟩

section Readers
variable {K : Type} {Sh : Shared E L Nat} {T : Track Sh.X}

/-- **A reader thread's program on one table**: thread `u`'s `Read` calls `call c` (`c < nc`),
each in a pinned region `reg c` (`RCall`: the `Acquire` load `Lc` of `current`, then the
accesses, all `po`-between the pin and the region's end), whose `current` loads read the
table's publication `S`, in program order; the control-byte loads `r i` of its `get`s, each
an access of one of the calls (`cl i`), in program order (`hpo`). The remaining fields are
`RThread`'s facts about the loads themselves: what they read (`hrf`, `hloc`, `hacq`), Rust's
probe positions (`hbkt`, `hpos`), the `get`s they form (`gets`, ...), and lower bounds `lo`
(operations completed before a load; `lo i = pub` always works). -/
structure RProg (Tb : TableLocs Sh.X T) (C : Cfg K) (W n : Nat) (cur : L) where
  u : Tid
  nc : Nat
  hnc : 0 < nc
  reg : Nat → PinRegion Sh.CX u
  call : (c : Nat) → RCall (reg c) cur
  callS : ∀ c, c < nc → Sh.CX.G.rf Tb.S (call c).Lc
  callpo : ∀ c c', c < c' → c' < nc → Sh.CX.G.po (call c).Lc (call c').Lc
  M : Nat
  r : Nat → E
  w : Nat → E
  p : Nat → Nat
  lo : Nat → Nat
  key : Nat → K
  gets : List (K × List (List Nat))
  cl : Nat → Nat
  hcl : ∀ i, i < M → cl i < nc ∧ r i ∈ (call (cl i)).acc
  hrf : ∀ i, i < M → Sh.X.G.rf (w i) (r i)
  hloc : ∀ i, i < M → Sh.X.G.loc (r i) = Tb.ctrl (p i)
  hacq : ∀ i, i < M → Sh.X.G.isAcq (r i) ∧ Sh.X.G.atomic (r i)
  hpo : ∀ k i, k < i → i < M → Sh.X.G.po (r k) (r i)
  hlo0 : ∀ i, i < M → Tb.pub ≤ lo i
  hlom : ∀ k i, k ≤ i → i < M → lo k ≤ lo i
  hloR : ∀ i, i < M → lo i = Tb.pub ∨ Sh.X.G.hb (Sh.X.rel (lo i)) (r i)
  hbkt : ∀ i, i < M → Tb.bkt (p i) = p i % n
  hpos : ∀ i, i < M → ∃ j b, b < W ∧ p i = (Bytes.probeAt W n (C.hash (key i)) j).1 + b
  hgk : ∀ G ∈ gets, ∀ g ∈ G.2, ∀ i ∈ g, i < M ∧ key i = G.1
  hgne : ∀ G ∈ gets, G.2 ≠ [] ∧ ∀ g ∈ G.2, g ≠ []
  hgo : gets.Pairwise (fun G G' => ∀ g ∈ G.2, ∀ i ∈ g, ∀ g' ∈ G'.2, ∀ j ∈ g', i < j)

/-- The memory belongs to the table from its initialisation to its free (property 11/20):
stores to its control bytes and counters by others (`op = none`: earlier owners of the
allocation, later owners after the free) happen before the initialisation or after the free. -/
def Owned {cur : L} (Tb : TableLocs Sh.X T) (Fp : FreeProg Sh cur Tb.S Tb.pub) : Prop :=
  ∀ w', Sh.X.G.isW w' → Tb.tl (Sh.X.G.loc w') → Sh.X.op w' = none →
    Sh.X.G.hb w' (Tb.ini (Sh.X.G.loc w')) ∨ Sh.X.G.hb Fp.F w'

/-- **`RThread` from the reader's program**: the `current` load `A` is the first call's `Lc`,
`hAr` from the calls' order, `hfree` from the free (`FreeProg.before`), `hnf` from `Owned`. -/
def RProg.toRThread {Tb : TableLocs Sh.X T} {C : Cfg K} {W n : Nat} {cur : L}
    (Rp : RProg Tb C W n cur) (Fp : FreeProg Sh cur Tb.S Tb.pub)
    (hS : Sh.X.G.isW Tb.S) (hSl : Sh.X.G.loc Tb.S = cur) (hown : Owned Tb Fp) :
    RThread Tb C W n (Fp.f + 1) where
  A := (Rp.call 0).Lc
  M := Rp.M
  r := Rp.r
  w := Rp.w
  p := Rp.p
  lo := Rp.lo
  key := Rp.key
  gets := Rp.gets
  hA := by rw [Sh.hG]; exact Rp.callS 0 Rp.hnc
  hAa := by rw [Sh.hG]; exact (Rp.call 0).Lc_acq
  hAr := fun i hi => by
    rw [Sh.hG]
    obtain ⟨h1, h2⟩ := Rp.hcl i hi
    have hx := (Rp.call (Rp.cl i)).Lc_acc _ h2
    rcases Nat.eq_zero_or_pos (Rp.cl i) with e | e
    · rw [e] at hx; exact hx
    · exact Sh.CX.cons.po_trans _ _ _ (Rp.callpo 0 _ e h1) hx
  hrf := Rp.hrf
  hloc := Rp.hloc
  hacq := Rp.hacq
  hpo := Rp.hpo
  hnf := fun i hi w' hw' hl hop => by
    rcases hown w' hw' (by rw [hl, Rp.hloc i hi]; exact Tb.ctrl_tl _) hop with h | h
    · left; rw [← hl]; exact h
    · right
      obtain ⟨h1, h2⟩ := Rp.hcl i hi
      exact hb_trans ((Fp.before hS hSl Tb.S_op _ _ (Rp.callS _ h1)).1 _ h2) h
  hfree := fun i hi =>
    (Fp.before hS hSl Tb.S_op _ _ (Rp.callS _ (Rp.hcl i hi).1)).2 _ (Rp.hcl i hi).2
  hlo0 := Rp.hlo0
  hlom := Rp.hlom
  hloR := Rp.hloR
  hbkt := Rp.hbkt
  hpos := Rp.hpos
  hgk := Rp.hgk
  hgne := Rp.hgne
  hgo := Rp.hgo

variable [DecidableEq K] {VV : Type}

/-- **Property 18 for all reader threads, from the programs.** One graph `Sh` carrying the
writer and `collect`; the writer's program on the table during its life `[pub, f + 1)`
(`WProg`, `Hist`), ending with the operation `f` that frees it (`FreeProg`: `replace_table`,
`collect`'s callback and `mark_ready`, the pruner's `can_free` load and the free); the memory
owned by the table between initialisation and free (`Owned`, and `hownD` for the bucket data);
reader threads `Rp u` given by their pinned `Read` calls (`RProg`). Then: `readers_lin`'s
conclusion for the threads `toRThread`, and the data clause without side conditions for every
data read that is an access of a call: it returns the pair of the slot its control byte
showed, race free. -/
theorem readers_lin_shared {Tb : TableLocs Sh.X T} {C : Cfg K} {h2 : Nat → Nat}
    {tab : Nat → Table K VV} {cur : L} (Fp : FreeProg Sh cur Tb.S Tb.pub)
    (hS : Sh.X.G.isW Tb.S) (hSl : Sh.X.G.loc Tb.S = cur)
    (P : WProg Tb C h2 tab (Fp.f + 1)) (hH : Hist C tab Tb.pub (Fp.f + 1))
    (htr : ∀ a, a.Valid P.W P.n → T.tr (P.lay a))
    (hown : Owned Tb Fp)
    (hownD : ∀ b w'', Sh.X.G.isW w'' → Sh.X.G.loc w'' = P.lay (.dat b) → Sh.X.op w'' = none →
      Sh.X.G.hb w'' (Sh.X.acq Tb.pub) ∨ Sh.X.G.hb Fp.F w'')
    (hW : P.W.isPowerOfTwo) (hn : P.n.isPowerOfTwo) (hh2 : ∀ h, h2 h < 0x80)
    {mb : List Nat → Nat → List Bool} (hmb : Bytes.MatchOK mb)
    (us : List Nat) (hus : us.Nodup) (Rp : Nat → RProg Tb C P.W P.n cur) :
    ∃ (e : Nat → Nat → Nat) (σ : Nat → Nat → Slot K VV) (ℓ : Nat → K × List (List Nat) → Nat)
      (lin : List (Nat × (K × List (List Nat)))),
      (∀ u ∈ us, ThreadLin ((Rp u).toRThread Fp hS hSl hown) (h2 := h2) mb tab
        (P.tableData hH) (e u) (σ u) (ℓ u)) ∧
      (∀ u ∈ us, ∀ i, i < (Rp u).M → ∀ k v, σ u i = .full k v → ∀ c, c < (Rp u).nc →
        ∀ r' ∈ ((Rp u).call c).acc, Sh.X.G.po ((Rp u).r i) r' → Sh.X.G.isR r' →
        Sh.X.G.loc r' = P.lay (.dat (Tb.bkt ((Rp u).p i))) →
        ∃ d, Sh.X.G.rf d r' ∧ (Sh.X.G.lab r').rval = P.dval k v ∧ Sh.X.G.hb d r' ∧
          ∀ w'', Sh.X.G.isW w'' → Sh.X.G.loc w'' = P.lay (.dat (Tb.bkt ((Rp u).p i))) →
            Sh.X.G.hb w'' r' ∨ Sh.X.G.hb r' w'') ∧
      lin.Pairwise (fun a b => ℓ a.1 a.2 ≤ ℓ b.1 b.2) ∧
      lin.Perm (us.flatMap (fun u => (Rp u).gets.map (fun G => (u, G)))) ∧
      ∀ u ∈ us, lin.filter (fun a => a.1 == u) = (Rp u).gets.map (fun G => (u, G)) := by
  obtain ⟨e, σ, ℓ, lin, h1, h2', h3, h4⟩ := readers_lin_prog P hH htr hW hn hh2 hmb us hus
    (fun u => (Rp u).toRThread Fp hS hSl hown)
  refine ⟨e, σ, ℓ, lin, h1, fun u hu i hi k v hσ c hc r' hr' hrr hR hl => ?_, h2', h3, h4⟩
  obtain ⟨hF, hFd⟩ := Fp.before hS hSl Tb.S_op _ _ ((Rp u).callS c hc)
  exact ((h1 u hu).2.1 i hi).2.2.2.2.2 k v hσ r' hrr hR hl (hFd r' hr')
    (fun w'' hw'' hl'' hop => by
      rcases hownD _ w'' hw'' hl'' hop with h | h
      · exact .inl h
      · exact .inr (hb_trans (hF r' hr') h))

end Readers

end Shared

end SyncTable.RC11Prog

#print axioms SyncTable.RC11Prog.WProg.henc
#print axioms SyncTable.RC11Prog.WProg.hcnt
#print axioms SyncTable.RC11Prog.WProg.tableData
#print axioms SyncTable.RC11Prog.WProg.life
#print axioms SyncTable.RC11Prog.exists_ops
#print axioms SyncTable.RC11Prog.readers_lin_prog
#print axioms SyncTable.RC11Prog.can_free_no_race_shared
#print axioms SyncTable.RC11Prog.RCall.inRegion
#print axioms SyncTable.RC11Prog.reader_before_free
#print axioms SyncTable.RC11Prog.FreeProg.before
#print axioms SyncTable.RC11Prog.readers_lin_shared
