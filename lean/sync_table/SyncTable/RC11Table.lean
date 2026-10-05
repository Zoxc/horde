import Collect.RC11
import SyncTable.LinkInv

/-!
# Property 18: the table over RC11 execution graphs

Built on the generic RC11 layer `lean/collect/Collect/RC11.lean` (as `Collect/RC11Pin.lean` is for
property 11) and on `RC11Publish.lean`.

## The interface (axiomatised part)

**`Writer`: the writer mutex and the writer operations.** An RC11-consistent finite graph `G`.
The table's writer mutex (`SyncTable::lock`, or `&mut self` / `unsafe_write`, which give the same
order) is a lock location `lk` (`RC11.LockLoc`). Unlike `RC11Pin`, a writer operation is *not*
collapsed into one event, since readers read its individual stores: writer operation number `i`
(`insert`, `remove`, `replace_table` with the initialisation of the new table, ...) is the set of
events `e` with `op e = some i`, all `po`-between its lock acquisition `acq i` and its release
`rel i`, both RMWs on `lk`. The numbering is the lock order: `i < j → mo (rel i) (acq j)`
(`order`). Events of no writer operation (readers, `collect`, other owners of the memory) have
`op e = none`. `op_hb` (from `RC11.lock_mo_hb`): every event of operation `i` happens before
every event of a later operation `j`.

**`Track`: locations with a version history.** For the tracked locations (`tr`: the control
bytes, primary and mirrored, `growth_left`, `tombstones`, `current`), `vof x ℓ` is the value of
`ℓ` after writer operation `x` in the sequentially consistent model. Assumed: a writer store
writes `vof i ℓ` (`wval`; an operation may store a location more than once with that value:
`set_ctrl_release(i, c)` with `i ≥ W` stores the primary byte `i` twice, since its replica index
`((i - W) & mask) + W` is `i` itself), and an operation that does not store to `ℓ` leaves `vof`
unchanged (`frame`). This is where the graph is tied to `SyncTable.Model`:
`vof x (ctrl p) = encSlot (slot of bucket p % n in the table after model writer step x)`
(hypothesis `henc` of `group_replicaSync`), i.e. the writer's critical sections replayed in lock
order are the model's writer steps. `RC11Prog.lean` derives `henc` from the writer's program
(`WProg.henc`).

**`TableLocs`: one table.** Published by writer operation `pub`, whose `Release` store `S` of
`current` comes after all its writes to the table (`init_po`: `TableRef::allocate` /
`clone_table` / `from_iter` initialise the control bytes and counters, non-atomically, before
`replace_table`'s `current.store(.., Release)`). Each table location `ℓ` has such an
initialisation write `ini ℓ`. **`Life`: the table's life `[pub, dF)`** (`dF`: the operation
after the one that frees it; later operations may reuse the memory). Every store to the table
by an operation in `(pub, dF)` is a `Release` atomic store (`rel`: `set_ctrl_release`'s two
stores, `growth_left.store(.., Release)`, `tombstones.store(.., Release)`); such an operation
stores the control bytes of at most one bucket (`one_bucket`: `insert` and `remove` touch one
bucket; a resize writes a *new* table), and never both counters (`counters_sep`: `insert`
writes `growth_left`, `remove` writes `tombstones`). `RC11Prog.WProg.life` derives `Life` from
the writer's program. The results using it take `hfree` (the loads happen before operation
`dF`), so every store a load reads is of an operation before `dF` (`Writer.op_lt_of_hb`).

Reader-side hypotheses are stated per theorem: the reader's `Acquire` load `A` of `current`
reads `S`; its control-byte loads (`Group::load`'s per-byte `Acquire` loads, `ctrl_acquire`)
and counter loads (`Acquire`) are `po`-after `A`; and stores to the table's memory by others
(`op = none`: earlier owners of a reused allocation, later ones after `prune_tables` freed it)
happen before the initialisation or after the read (`hnf`). The latter is property 11's
`pin_contract` (the reader is pinned; the free happens after its unpin), not re-derived here.

## Results

* `view` (generic): a `po`-chain of `Acquire` loads of tracked locations, each reading a writer
  store, all writer operations up to `lo` visible: there are versions `x 0 ≤ x 1 ≤ ...`, all
  `≥ lo`, such that load `i` returns `vof (x i) ℓᵢ` — i.e. the loads can be placed, in program
  order, after writer steps of the SC model and read exactly the model's values there. They
  are also below every writer operation the loads happen before (the hb window). Needs: an
  operation (after `lo`) whose store one load reads does not store a location loaded later
  except `po`-before that store (`hsame`).
* `table_view`: the instance for a reader of one table (`lo = pub`, through `current`).
* `group_view`: **one `get`'s control-byte loads** (loads of pairwise different buckets: a
  group has `W ≤ n` different buckets, and one `search` visits each bucket at most once) are
  explained by monotone versions; `group_replicaSync`: hence `LinkInv.ReplicaSync` holds for
  the slots the model's `scanLoad` steps record when scheduled at those versions, also for
  mirrored bytes; `group_step_rc11`: Rust's group decision on the bytes it loaded is then a
  model step (`reader_group_step`), which discharges property 17's remaining hypothesis.
* `full_read_data`: a reader whose `Acquire` load reads a `FULL` byte (a `Release` store
  `po`-after the bucket's data write) and then reads the bucket (`eq`, `as_pair_ref`) reads
  exactly that data write, and every write to the bucket is `hb`-ordered with the read (no data
  race).
* `len_view`: `len` (`items`: `tombstones` then `growth_left`, both `Acquire`) reads the
  counters at two versions `x0 ≤ x1`, as `Iter.len_spec`'s two moments.
* `current_view`: a reader of `current` reads the store of a writer operation at or after
  every operation that happens before it (`hb_read_coh`).

## What Rust guarantees for the replica byte

`set_ctrl_release(i, c)` stores the primary byte `i` and then the replica `n + i` (`i < W`),
both `Release`. An `Acquire` load of the replica reads the replica store of some operation `a`
or an earlier one; it never sees a byte older than what an operation that happens before the
load wrote. **Within one `get`** this is as good as a snapshot: `group_view` places all its
loads at monotone versions, so `ReplicaSync` holds and the model's `scanLoad` explains them.
**Across `get`s of one thread the bytes are not one snapshot**: a reader that loaded the
*primary* byte `i` written by operation `a` may, in a later `get`, load the *replica* `n + i`
with its value from before `a` (only the events `po`-before the primary store are published
by it; the replica store is `po`-after). `RC11Global.lean` states what does hold for a whole
chain of loads (`chain_replicaSync`: every byte is the model's at a monotone version `x`,
except possibly the byte of the bucket operation `x` changed, which may lag one version) and
proves that this lag never changes a `get`'s result, so that all `get`s of a reader thread are
linearizable in program order against the writer's operations (`reader_lin`).
-/

namespace SyncTable.RC11Table
open RC11 RC11.Graph

variable {E L V : Type}

/-! ## Interface -/

/-- The writer mutex and the writer operations (see the module docs). -/
structure Writer (E L V : Type) where
  G : Graph E L V
  evs : List E
  all : ∀ e, e ∈ evs
  cons : G.Consistent
  /-- the writer mutex and its initialisation write -/
  lk : L
  lkInit : E
  lock : LockLoc G lk lkInit
  /-- the writer operation an event belongs to -/
  op : E → Option Nat
  /-- lock acquisition and release of operation `i` -/
  acq : Nat → E
  rel : Nat → E
  acq_op : ∀ i, op (acq i) = some i
  in_op : ∀ e i, op e = some i → (acq i = e ∨ G.po (acq i) e) ∧ (e = rel i ∨ G.po e (rel i))
  acq_lk : ∀ i, G.isW (acq i) ∧ G.loc (acq i) = lk
  /-- operations are numbered in lock order -/
  order : ∀ i j, i < j → G.mo (rel i) (acq j)

/-- Tracked locations with their value after each writer operation. -/
structure Track (X : Writer E L V) where
  tr : L → Prop
  vof : Nat → L → V
  wval : ∀ w i, X.G.isW w → tr (X.G.loc w) → X.op w = some i →
    (X.G.lab w).wval = vof i (X.G.loc w)
  frame : ∀ ℓ x, tr ℓ → (∀ w, X.G.isW w → X.G.loc w = ℓ → X.op w ≠ some (x + 1)) →
    vof (x + 1) ℓ = vof x ℓ

/-- One table (see the module docs). -/
structure TableLocs (X : Writer E L V) (T : Track X) where
  /-- the writer operation that published the table and its `Release` store of `current` -/
  pub : Nat
  S : E
  S_op : X.op S = some pub
  S_rel : X.G.isRel S ∧ X.G.atomic S
  /-- the table's locations: control bytes, `growth_left`, `tombstones` -/
  tl : L → Prop
  tl_tr : ∀ ℓ, tl ℓ → T.tr ℓ
  init_po : ∀ w, X.G.isW w → tl (X.G.loc w) → X.op w = some pub → X.G.po w S
  ini : L → E
  ini_w : ∀ ℓ, tl ℓ → X.G.isW (ini ℓ) ∧ X.G.loc (ini ℓ) = ℓ ∧ X.op (ini ℓ) = some pub
  /-- control byte at position `p` (`0 ≤ p < n + W`) and its bucket (`p % n`) -/
  ctrl : Nat → L
  bkt : Nat → Nat
  ctrl_tl : ∀ p, tl (ctrl p)
  tomb : L
  growth : L
  tomb_tl : tl tomb
  growth_tl : tl growth

/-- **The table's life `[pub, dF)`**: what the writer operations after the publication and
before `dF` (the end of the table's life: the operation after the one that frees it) store to
the table. Later operations may store anything there (the memory is freed and reused).
`RC11Prog.WProg.life` derives it from the writer's program. -/
structure Life {X : Writer E L V} {T : Track X} (Tb : TableLocs X T) (dF : Nat) : Prop where
  /-- stores to the table are `Release` atomic stores (`set_ctrl_release`, the counters) -/
  rel : ∀ w i, X.G.isW w → Tb.tl (X.G.loc w) → X.op w = some i → Tb.pub < i → i < dF →
    X.G.isRel w ∧ X.G.atomic w
  /-- an operation stores the control bytes of at most one bucket -/
  one_bucket : ∀ p q w w' i, Tb.pub < i → i < dF → X.G.isW w → X.G.isW w' →
    X.G.loc w = Tb.ctrl p → X.G.loc w' = Tb.ctrl q → X.op w = some i → X.op w' = some i →
    Tb.bkt p = Tb.bkt q
  /-- an operation never stores both counters -/
  counters_sep : ∀ w w' i, Tb.pub < i → i < dF → X.G.isW w → X.G.isW w' →
    X.G.loc w = Tb.tomb → X.G.loc w' = Tb.growth → X.op w = some i → X.op w' = some i → False

/-! ## Writer operations are ordered by `hb` -/

namespace Writer
variable (X : Writer E L V)

/-- Every event of operation `i` happens before every event of a later operation `j`. -/
theorem op_hb {e e' : E} {i j : Nat} (he : X.op e = some i) (he' : X.op e' = some j)
    (hij : i < j) : X.G.hb e e' := by
  have h1 : X.G.hb (X.rel i) (X.acq j) :=
    lock_mo_hb X.cons X.lock (moRank X.G X.evs) (fun a b h _ => moRank_lt X.cons.toWF X.all h)
      _ _ (X.order i j hij) (X.acq_lk j).2
  have h2 : X.G.hb e (X.acq j) := by
    rcases (X.in_op e i he).2 with h | h
    · rw [h]; exact h1
    · exact hb_trans (po_hb h) h1
  rcases (X.in_op e' j he').1 with h | h
  · rw [← h]; exact h2
  · exact hb_trans h2 (po_hb h)

/-- A read that a store of operation `j` happens before reads a store of an operation `≥ j`. -/
theorem seen {w' w0 r : E} {j a : Nat} (hh : X.G.hb w' r) (hrf : X.G.rf w0 r)
    (hw' : X.G.isW w') (hl : X.G.loc w' = X.G.loc r) (hj : X.op w' = some j)
    (ha : X.op w0 = some a) : j ≤ a := by
  rcases hb_read_coh X.cons hh hrf hw' hl with h | h
  · rw [h, hj] at ha; exact Nat.le_of_eq (Option.some.inj ha)
  · apply Nat.not_lt.1; intro hlt
    exact (X.cons.coh _ _ (X.op_hb ha hj hlt)).2 (.base (Or.inr (Or.inl h)))

/-- Stores to one location by writer operations are in `mo` in operation order. -/
theorem mo_op {w w' : E} {i j : Nat} (hw : X.G.isW w) (hw' : X.G.isW w')
    (hl : X.G.loc w = X.G.loc w') (hi : X.op w = some i) (hj : X.op w' = some j) (hij : i < j) :
    X.G.mo w w' := by
  have hhb := X.op_hb hi hj hij
  have hne : w ≠ w' := fun h => hb_irrefl X.cons _ (h ▸ hhb)
  rcases X.cons.mo_total w w' hw hw' hl hne with h | h
  · exact h
  · exact ((X.cons.coh _ _ hhb).2 (.base (Or.inr (Or.inl h)))).elim

/-- A read that happens before operation `d` starts reads a store of an operation before `d`. -/
theorem op_lt_of_hb {w r : E} {a d : Nat} (hrf : X.G.rf w r) (ha : X.op w = some a)
    (h : X.G.hb r (X.acq d)) : a < d := by
  apply Nat.lt_of_not_le; intro hd
  have h2 : X.G.hb r w := by
    rcases Nat.lt_or_eq_of_le hd with hlt | heq
    · exact hb_trans h (X.op_hb (X.acq_op d) ha hlt)
    · subst heq
      rcases (X.in_op w _ ha).1 with e | e
      · rw [← e]; exact h
      · exact hb_trans h (po_hb e)
  exact (X.cons.coh _ _ h2).2 (.base (Or.inl hrf))

end Writer

/-! ## Placing loads at versions -/

/-- The greedy placement: the maximum of `lo` and the versions read so far. -/
def xs (lo : Nat) (a : Nat → Nat) : Nat → Nat
  | 0 => max lo (a 0)
  | i + 1 => max (xs lo a i) (a (i + 1))

theorem xs_ge_lo (lo : Nat) (a : Nat → Nat) : ∀ i, lo ≤ xs lo a i
  | 0 => Nat.le_max_left _ _
  | i + 1 => Nat.le_trans (xs_ge_lo lo a i) (Nat.le_max_left _ _)

theorem xs_mono (lo : Nat) (a : Nat → Nat) {k : Nat} : ∀ i, k ≤ i → xs lo a k ≤ xs lo a i
  | 0, h => by rw [Nat.le_zero.1 h]; exact Nat.le_refl _
  | i + 1, h => by
    rcases Nat.lt_or_eq_of_le h with h | h
    · exact Nat.le_trans (xs_mono lo a i (by omega)) (Nat.le_max_left _ _)
    · rw [h]; exact Nat.le_refl _

theorem xs_ge (lo : Nat) (a : Nat → Nat) : ∀ i, a i ≤ xs lo a i
  | 0 => Nat.le_max_right _ _
  | _ + 1 => Nat.le_max_right _ _

theorem xs_lt (lo : Nat) (a : Nat → Nat) {j : Nat} (hlo : lo < j) :
    ∀ i, (∀ k, k ≤ i → a k < j) → xs lo a i < j
  | 0, h => Nat.max_lt.2 ⟨hlo, h 0 (Nat.le_refl _)⟩
  | i + 1, h => Nat.max_lt.2 ⟨xs_lt lo a hlo i (fun k hk => h k (by omega)), h _ (Nat.le_refl _)⟩

theorem frame_iter {X : Writer E L V} (T : Track X) {ℓ : L} (hℓ : T.tr ℓ) {a : Nat} :
    ∀ x, a ≤ x → (∀ y w, a < y → y ≤ x → X.G.isW w → X.G.loc w = ℓ → X.op w ≠ some y) →
      T.vof x ℓ = T.vof a ℓ
  | 0, h, _ => by rw [Nat.le_zero.1 h]
  | x + 1, h, hn => by
    rcases Nat.lt_or_eq_of_le h with h | h
    · rw [T.frame ℓ x hℓ (fun w hw hl => hn _ w h (Nat.le_refl _) hw hl)]
      exact frame_iter T hℓ x (by omega) (fun y w h1 h2 => hn y w h1 (by omega))
    · rw [h]

/-- **Loads explained by monotone versions.** A `po`-chain of `Acquire` loads `r 0, r 1, ...`
of tracked locations, load `i` reading the store `w i` of writer operation `a i`, where every
store of an operation `≤ lo` to the loaded location happens before the load (`hlo`), stores of
operations after `lo` that are read are `Release` (`hrel`), and an operation after `lo` whose
store some load reads stores a later-loaded location only `po`-before that store (`hsame`):
then there are versions `x 0 ≤ x 1 ≤ ...`, all `≥ lo`, with load `i` returning
`vof (x i) (loc (r i))`, `x i` below every later store to that location, and below every
operation `d > lo` all loads happen before. -/
theorem view (X : Writer E L V) (T : Track X) {m lo : Nat} {r w : Nat → E} {a : Nat → Nat}
    (hrf : ∀ i, i < m → X.G.rf (w i) (r i))
    (hop : ∀ i, i < m → X.op (w i) = some (a i))
    (htr : ∀ i, i < m → T.tr (X.G.loc (r i)))
    (hacq : ∀ i, i < m → X.G.isAcq (r i) ∧ X.G.atomic (r i))
    (hpo : ∀ k i, k < i → i < m → X.G.po (r k) (r i))
    (hlo : ∀ i, i < m → ∀ w' j, X.G.isW w' → X.G.loc w' = X.G.loc (r i) → X.op w' = some j →
      j ≤ lo → X.G.hb w' (r i))
    (hrel : ∀ k, k < m → lo < a k → X.G.isRel (w k) ∧ X.G.atomic (w k))
    (hsame : ∀ k i, k < i → i < m → lo < a k → ∀ w', X.G.isW w' →
      X.G.loc w' = X.G.loc (r i) → X.op w' = some (a k) → w' = w k ∨ X.G.po w' (w k)) :
    ∃ x : Nat → Nat,
      (∀ i, i < m → lo ≤ x i ∧ a i ≤ x i ∧
        (X.G.lab (r i)).rval = T.vof (x i) (X.G.loc (r i))) ∧
      (∀ k i, k ≤ i → i < m → x k ≤ x i) ∧
      (∀ i, i < m → ∀ w' j, X.G.isW w' → X.G.loc w' = X.G.loc (r i) → X.op w' = some j →
        a i < j → x i < j) ∧
      (∀ d, lo < d → (∀ i, i < m → X.G.hb (r i) (X.acq d)) → ∀ i, i < m → x i < d) := by
  have hlo' : ∀ i, i < m → ∀ w' j, X.G.isW w' → X.G.loc w' = X.G.loc (r i) →
      X.op w' = some j → a i < j → lo < j := by
    intro i hi w' j hw' hl hj haj
    apply Nat.not_le.1; intro hjl
    have := X.seen (hlo i hi w' j hw' hl hj hjl) (hrf i hi) hw' hl hj (hop i hi); omega
  have key : ∀ i, i < m → ∀ w' j, X.G.isW w' → X.G.loc w' = X.G.loc (r i) →
      X.op w' = some j → a i < j → xs lo a i < j := by
    intro i hi w' j hw' hl hj haj
    have hlj := hlo' i hi w' j hw' hl hj haj
    refine xs_lt lo a hlj i (fun k hk => ?_)
    rcases Nat.lt_or_eq_of_le hk with hk | hk
    · apply Nat.not_le.1; intro hjk
      have hkm : k < m := by omega
      have hlk : lo < a k := by omega
      obtain ⟨hR, hA⟩ := hrel k hkm hlk
      have hsw : X.G.hb (w k) (r i) :=
        mp_hb X.cons (.inl rfl) (hrf k hkm) hR (hacq k hkm).1 hA (hacq k hkm).2
          (.inr (hpo k i hk hi))
      have hh : X.G.hb w' (r i) := by
        rcases Nat.lt_or_eq_of_le hjk with hlt | heq
        · exact hb_trans (X.op_hb hj (hop k hkm) hlt) hsw
        · rcases hsame k i hk hi hlk w' hw' hl (heq ▸ hj) with e | e
          · rw [e]; exact hsw
          · exact hb_trans (po_hb e) hsw
      have := X.seen hh (hrf i hi) hw' hl hj (hop i hi); omega
    · rw [hk]; exact haj
  refine ⟨xs lo a, fun i hi => ⟨xs_ge_lo lo a i, xs_ge lo a i, ?_⟩,
    fun k i hk _ => xs_mono lo a i hk, key, ?_⟩
  · obtain ⟨hwW, -, hlw, hv⟩ := X.cons.rf_wr _ _ (hrf i hi)
    rw [← hv, T.wval (w i) (a i) hwW (by rw [hlw]; exact htr i hi) (hop i hi), hlw]
    exact (frame_iter T (htr i hi) _ (xs_ge lo a i) (fun y w' h1 h2 hw' hl hy =>
      Nat.lt_irrefl _ (Nat.lt_of_le_of_lt h2 (key i hi w' y hw' hl hy h1)))).symm
  · intro d hld hd i hi
    refine xs_lt lo a hld i (fun k hk => ?_)
    have hkm : k < m := by omega
    apply Nat.not_le.1; intro hdk
    have h1 : X.G.hb (X.acq d) (w k) ∨ X.acq d = w k := by
      rcases Nat.lt_or_eq_of_le hdk with hlt | heq
      · exact .inl (X.op_hb (X.acq_op d) (hop k hkm) hlt)
      · rcases (X.in_op (w k) (a k) (hop k hkm)).1 with e | e
        · rw [heq]; exact .inr e
        · rw [heq]; exact .inl (po_hb e)
    have h2 : X.G.hb (r k) (w k) := by
      rcases h1 with h1 | h1
      · exact hb_trans (hd k hkm) h1
      · rw [← h1]; exact hd k hkm
    exact (X.cons.coh _ _ h2).2 (.base (Or.inl (hrf k hkm)))

/-! ## Readers of one table -/

section Table
variable {X : Writer E L V} {T : Track X}

/-- The store a reader of the table reads is a writer store (not another owner's). -/
theorem src_tracked (Tb : TableLocs X T) {A r w0 : E} (hA : X.G.rf Tb.S A)
    (hAa : X.G.isAcq A ∧ X.G.atomic A) (hAr : X.G.po A r) (hrf : X.G.rf w0 r)
    (htl : Tb.tl (X.G.loc r))
    (hnf : ∀ w', X.G.isW w' → X.G.loc w' = X.G.loc r → X.op w' = none →
      X.G.hb w' (Tb.ini (X.G.loc r)) ∨ X.G.hb r w') :
    ∃ a, X.op w0 = some a := by
  obtain ⟨hw0, -, hl0, -⟩ := X.cons.rf_wr _ _ hrf
  cases h : X.op w0 with
  | some a => exact ⟨a, rfl⟩
  | none =>
    obtain ⟨hiw, hil, hio⟩ := Tb.ini_w _ htl
    rcases hnf w0 hw0 hl0 h with hh | hh
    · have hir : X.G.hb (Tb.ini (X.G.loc r)) r :=
        mp_hb X.cons (.inr (Tb.init_po _ hiw (by rw [hil]; exact htl) hio)) hA Tb.S_rel.1
          hAa.1 Tb.S_rel.2 hAa.2 (.inr hAr)
      rcases hb_read_coh X.cons hir hrf hiw hil with e | e
      · rw [e] at hh; exact (hb_irrefl X.cons _ hh).elim
      · exact ((X.cons.coh _ _ hh).2 (.base (Or.inr (Or.inl e)))).elim
    · exact ((X.cons.coh _ _ hh).2 (.base (Or.inl hrf))).elim

/-- **A reader of one table** (`Acquire` load `A` of `current` reading the publication `S`,
then a `po`-chain of `Acquire` loads of the table's locations): its loads are explained by
monotone versions `≥ pub` (see `view`). `hsame` is the per-operation condition of `view`. -/
theorem table_view (Tb : TableLocs X T) {dF : Nat} (Lf : Life Tb dF) {A : E} {m : Nat}
    {r w : Nat → E}
    (hA : X.G.rf Tb.S A) (hAa : X.G.isAcq A ∧ X.G.atomic A) (hAr : ∀ i, i < m → X.G.po A (r i))
    (hrf : ∀ i, i < m → X.G.rf (w i) (r i)) (htl : ∀ i, i < m → Tb.tl (X.G.loc (r i)))
    (hacq : ∀ i, i < m → X.G.isAcq (r i) ∧ X.G.atomic (r i))
    (hpo : ∀ k i, k < i → i < m → X.G.po (r k) (r i))
    (hnf : ∀ i, i < m → ∀ w', X.G.isW w' → X.G.loc w' = X.G.loc (r i) → X.op w' = none →
      X.G.hb w' (Tb.ini (X.G.loc (r i))) ∨ X.G.hb (r i) w')
    (hfree : ∀ i, i < m → X.G.hb (r i) (X.acq dF))
    (hsame : ∀ k i, k < i → i < m → ∀ w' j, X.G.isW w' → X.G.loc w' = X.G.loc (r i) →
      X.op w' = some j → X.op (w k) = some j → Tb.pub < j → j < dF →
      w' = w k ∨ X.G.po w' (w k)) :
    ∃ x : Nat → Nat,
      (∀ i, i < m → Tb.pub ≤ x i ∧ (X.G.lab (r i)).rval = T.vof (x i) (X.G.loc (r i))) ∧
      (∀ k i, k ≤ i → i < m → x k ≤ x i) ∧
      (∀ d, Tb.pub < d → (∀ i, i < m → X.G.hb (r i) (X.acq d)) → ∀ i, i < m → x i < d) := by
  have hsrc : ∀ i, i < m → ∃ a, X.op (w i) = some a := fun i hi =>
    src_tracked Tb hA hAa (hAr i hi) (hrf i hi) (htl i hi) (hnf i hi)
  let a : Nat → Nat := fun i => (X.op (w i)).getD 0
  have hop : ∀ i, i < m → X.op (w i) = some (a i) := by
    intro i hi; obtain ⟨b, hb⟩ := hsrc i hi; simp [a, hb]
  have hSr : ∀ i, i < m → X.G.hb Tb.S (r i) := fun i hi =>
    mp_hb X.cons (.inl rfl) hA Tb.S_rel.1 hAa.1 Tb.S_rel.2 hAa.2 (.inr (hAr i hi))
  obtain ⟨x, h1, h2, -, h4⟩ := view X T (lo := Tb.pub) (a := a) hrf hop
    (fun i hi => Tb.tl_tr _ (htl i hi)) hacq hpo
    (fun i hi w' j hw' hl hj hjl => by
      rcases Nat.lt_or_eq_of_le hjl with hlt | heq
      · exact hb_trans (X.op_hb hj Tb.S_op hlt) (hSr i hi)
      · exact hb_trans (po_hb (Tb.init_po w' hw' (by rw [hl]; exact htl i hi) (heq ▸ hj)))
          (hSr i hi))
    (fun k hk hlt => by
      obtain ⟨hw, -, hl, -⟩ := X.cons.rf_wr _ _ (hrf k hk)
      exact Lf.rel _ _ hw (by rw [hl]; exact htl k hk) (hop k hk) hlt
        (X.op_lt_of_hb (hrf k hk) (hop k hk) (hfree k hk)))
    (fun k i hk hi hlt w' hw' hl hj => hsame k i hk hi w' (a k) hw' hl hj (hop k (by omega)) hlt
      (X.op_lt_of_hb (hrf k (by omega)) (hop k (by omega)) (hfree k (by omega))))
  exact ⟨x, fun i hi => ⟨(h1 i hi).1, (h1 i hi).2.2⟩, h2, h4⟩

/-- **One `get`'s control-byte loads**: `Acquire` loads of control bytes at positions `p i`
of pairwise different buckets (a `Group::load` of `W ≤ n` consecutive positions, and the
groups of one probe sequence), `po`-after the `current` load. They return the model's bytes
at monotone versions `≥ pub`, below every operation they all happen before. -/
theorem group_view (Tb : TableLocs X T) {dF : Nat} (Lf : Life Tb dF) {A : E} {m : Nat} {r w : Nat → E} {p : Nat → Nat}
    (hA : X.G.rf Tb.S A) (hAa : X.G.isAcq A ∧ X.G.atomic A) (hAr : ∀ i, i < m → X.G.po A (r i))
    (hrf : ∀ i, i < m → X.G.rf (w i) (r i)) (hloc : ∀ i, i < m → X.G.loc (r i) = Tb.ctrl (p i))
    (hacq : ∀ i, i < m → X.G.isAcq (r i) ∧ X.G.atomic (r i))
    (hpo : ∀ k i, k < i → i < m → X.G.po (r k) (r i))
    (hdist : ∀ k i, k < i → i < m → Tb.bkt (p k) ≠ Tb.bkt (p i))
    (hnf : ∀ i, i < m → ∀ w', X.G.isW w' → X.G.loc w' = X.G.loc (r i) → X.op w' = none →
      X.G.hb w' (Tb.ini (X.G.loc (r i))) ∨ X.G.hb (r i) w')
    (hfree : ∀ i, i < m → X.G.hb (r i) (X.acq dF)) :
    ∃ x : Nat → Nat,
      (∀ i, i < m → Tb.pub ≤ x i ∧ (X.G.lab (r i)).rval = T.vof (x i) (Tb.ctrl (p i))) ∧
      (∀ k i, k ≤ i → i < m → x k ≤ x i) ∧
      (∀ d, Tb.pub < d → (∀ i, i < m → X.G.hb (r i) (X.acq d)) → ∀ i, i < m → x i < d) := by
  obtain ⟨x, h1, h2, h3⟩ := table_view Tb Lf hA hAa hAr hrf
    (fun i hi => by rw [hloc i hi]; exact Tb.ctrl_tl _) hacq hpo hnf hfree
    (fun k i hk hi w' j hw' hl hj hjk hlt hjF => by
      obtain ⟨hwk, -, hlk, -⟩ := X.cons.rf_wr _ _ (hrf k (by omega))
      exact (hdist k i hk hi (Lf.one_bucket (p k) (p i) (w k) w' j hlt hjF hwk hw'
        (hlk.trans (hloc k (by omega))) (hl.trans (hloc i hi)) hjk hj)).elim)
  exact ⟨x, fun i hi => by rw [← hloc i hi]; exact h1 i hi, h2, h3⟩

/-- **`len`'s two counter loads** (`items`: `tombstones`, then `growth_left`, both `Acquire`)
read the counters at versions `x0 ≤ x1` of the model, as `Iter.len_spec`'s two moments. The
same holds for `capacity` (one load) and `clone_table`'s two loads. -/
theorem len_view (Tb : TableLocs X T) {dF : Nat} (Lf : Life Tb dF) {A r0 r1 w0 w1 : E}
    (hA : X.G.rf Tb.S A) (hAa : X.G.isAcq A ∧ X.G.atomic A) (hA0 : X.G.po A r0)
    (h01 : X.G.po r0 r1) (hrf0 : X.G.rf w0 r0) (hrf1 : X.G.rf w1 r1)
    (hl0 : X.G.loc r0 = Tb.tomb) (hl1 : X.G.loc r1 = Tb.growth)
    (ha0 : X.G.isAcq r0 ∧ X.G.atomic r0) (ha1 : X.G.isAcq r1 ∧ X.G.atomic r1)
    (hnf0 : ∀ w', X.G.isW w' → X.G.loc w' = Tb.tomb → X.op w' = none →
      X.G.hb w' (Tb.ini Tb.tomb) ∨ X.G.hb r0 w')
    (hnf1 : ∀ w', X.G.isW w' → X.G.loc w' = Tb.growth → X.op w' = none →
      X.G.hb w' (Tb.ini Tb.growth) ∨ X.G.hb r1 w')
    (hfree : X.G.hb r1 (X.acq dF)) :
    ∃ x0 x1, Tb.pub ≤ x0 ∧ x0 ≤ x1 ∧ (X.G.lab r0).rval = T.vof x0 Tb.tomb ∧
      (X.G.lab r1).rval = T.vof x1 Tb.growth := by
  let r : Nat → E := fun i => if i = 0 then r0 else r1
  let w : Nat → E := fun i => if i = 0 then w0 else w1
  have hr0 : r 0 = r0 := rfl
  have hr1 : r 1 = r1 := rfl
  have hw0 : w 0 = w0 := rfl
  have hcase : ∀ i, i < 2 → i = 0 ∨ i = 1 := by intro i hi; omega
  obtain ⟨x, h1, h2, -⟩ := table_view (m := 2) (r := r) (w := w) Tb Lf hA hAa
    (fun i hi => by rcases hcase i hi with rfl | rfl
                    · exact hA0
                    · exact X.cons.po_trans _ _ _ hA0 h01)
    (fun i hi => by rcases hcase i hi with rfl | rfl
                    · exact hrf0
                    · exact hrf1)
    (fun i hi => by rcases hcase i hi with rfl | rfl
                    · show Tb.tl (X.G.loc r0); rw [hl0]; exact Tb.tomb_tl
                    · show Tb.tl (X.G.loc r1); rw [hl1]; exact Tb.growth_tl)
    (fun i hi => by rcases hcase i hi with rfl | rfl
                    · exact ha0
                    · exact ha1)
    (fun k i hk hi => by
      have : k = 0 ∧ i = 1 := by omega
      obtain ⟨rfl, rfl⟩ := this; exact h01)
    (fun i hi => by rcases hcase i hi with rfl | rfl
                    · intro w' e1 e2 e3
                      show X.G.hb w' (Tb.ini (X.G.loc r0)) ∨ X.G.hb r0 w'
                      rw [hl0]; exact hnf0 w' e1 (e2.trans hl0) e3
                    · intro w' e1 e2 e3
                      show X.G.hb w' (Tb.ini (X.G.loc r1)) ∨ X.G.hb r1 w'
                      rw [hl1]; exact hnf1 w' e1 (e2.trans hl1) e3)
    (fun i hi => by rcases hcase i hi with rfl | rfl
                    · exact hb_trans (po_hb h01) hfree
                    · exact hfree)
    (fun k i hk hi w' j hw' hl hj hjk hlt hjF => by
      have : k = 0 ∧ i = 1 := by omega
      obtain ⟨rfl, rfl⟩ := this
      rw [hw0] at hjk
      obtain ⟨hwk, -, hlk, -⟩ := X.cons.rf_wr _ _ hrf0
      exact (Lf.counters_sep w0 w' j hlt hjF hwk hw' (hlk.trans hl0) (hl.trans hl1) hjk hj).elim)
  refine ⟨x 0, x 1, (h1 0 (by omega)).1, h2 0 1 (by omega) (by omega), ?_, ?_⟩
  · have := (h1 0 (by omega)).2; rw [hr0, hl0] at this; exact this
  · have := (h1 1 (by omega)).2; rw [hr1, hl1] at this; exact this

end Table

/-! ## `current` -/

/-- A reader's load of `current` (a tracked location, written by writer operations with
`Release`) reads the store of an operation at or after every operation whose `current` store
happens before the load (it never sees an older table). -/
theorem current_view (X : Writer E L V) {S' A S : E} {j a : Nat} (hh : X.G.hb S' A)
    (hrf : X.G.rf S A) (hw : X.G.isW S') (hl : X.G.loc S' = X.G.loc A) (hj : X.op S' = some j)
    (ha : X.op S = some a) : j ≤ a :=
  X.seen hh hrf hw hl hj ha

/-! ## Bucket data -/

/-- **Reading a bucket after seeing it `FULL`.** The reader's `Acquire` load `r` reads a
`Release` control-byte store `w` (`set_ctrl_release` of `record_item_insert_at`, or its mirror),
which is `po`-after the bucket's data write `d` (`insert`: `bucket.write` before
`record_item_insert_at`). A `po`-later read `r'` of the bucket (`eq`, `as_pair_ref`) reads
exactly `d`, if every other write to the bucket happens before `d` (a previous owner of the
memory) or after `r'` (a later owner, after the free; property 11): a bucket is written once
in a table's life (inserts go only into `EMPTY` buckets, which never come back). And every
write to it is `hb`-ordered with `r'`: no data race. -/
theorem full_read_data {G : Graph E L V} (hc : G.Consistent) {w r d r' : E} (hrf : G.rf w r)
    (hw : G.isRel w ∧ G.atomic w) (hr : G.isAcq r ∧ G.atomic r) (hd : G.po d w)
    (hdw : G.isW d) (hrr : G.po r r') (hl : G.loc d = G.loc r') (hR : G.isR r')
    (hother : ∀ w'', G.isW w'' → G.loc w'' = G.loc d → w'' = d ∨ G.hb w'' d ∨ G.hb r' w'') :
    G.rf d r' ∧ G.hb d r' ∧
      ∀ w'', G.isW w'' → G.loc w'' = G.loc d → G.hb w'' r' ∨ G.hb r' w'' := by
  have hdr : G.hb d r' := mp_hb hc (.inr hd) hrf hw.1 hr.1 hw.2 hr.2 (.inr hrr)
  refine ⟨?_, hdr, fun w'' hw'' hl'' => ?_⟩
  · obtain ⟨w0, h0⟩ := hc.rf_total r' hR
    obtain ⟨hw0, -, hl0, -⟩ := hc.rf_wr _ _ h0
    rcases hother w0 hw0 (hl0.trans hl.symm) with e | e | e
    · rw [← e]; exact h0
    · rcases hb_read_coh hc hdr h0 hdw hl with e' | e'
      · rw [e'] at e; exact (hb_irrefl hc _ e).elim
      · exact ((hc.coh _ _ e).2 (.base (Or.inr (Or.inl e')))).elim
    · exact ((hc.coh _ _ e).2 (.base (Or.inl h0))).elim
  · rcases hother w'' hw'' hl'' with e | e | e
    · rw [e]; exact .inl hdr
    · exact .inl (hb_trans e hdr)
    · exact .inr e

/-! ## `ReplicaSync` and property 17's group decision -/

section Replica
variable {K VV : Type} {X : Writer E L Nat} {T : Track X}

/-- **`ReplicaSync` from the RC11 graph.** For one `get`'s control-byte loads (as in
`group_view`; positions may be primary or mirrored bytes) of a table whose control bytes, up to
the operation `dF` that frees it (which the loads happen before: property 11), are the
canonical bytes of the model's slots `hist x b` (`henc`), there are monotone versions `x i` in
`[pub, dF)` such that the loaded bytes are `ReplicaSync` with the slots `hist (x i) (bkt (p i))`:
exactly what the model's `scanLoad` steps record when scheduled after writer step `x i`. -/
theorem group_replicaSync (Tb : TableLocs X T) {dF : Nat} (Lf : Life Tb dF) (hash : K → Nat) (h2 : Nat → Nat)
    (hist : Nat → Nat → Slot K VV) (hdF : Tb.pub < dF)
    (henc : ∀ x q, Tb.pub ≤ x → x < dF → T.vof x (Tb.ctrl q) = Bytes.encSlot hash h2 (hist x (Tb.bkt q)))
    {A : E} {m : Nat} {r w : Nat → E} {p : Nat → Nat}
    (hA : X.G.rf Tb.S A) (hAa : X.G.isAcq A ∧ X.G.atomic A) (hAr : ∀ i, i < m → X.G.po A (r i))
    (hrf : ∀ i, i < m → X.G.rf (w i) (r i)) (hloc : ∀ i, i < m → X.G.loc (r i) = Tb.ctrl (p i))
    (hacq : ∀ i, i < m → X.G.isAcq (r i) ∧ X.G.atomic (r i))
    (hpo : ∀ k i, k < i → i < m → X.G.po (r k) (r i))
    (hdist : ∀ k i, k < i → i < m → Tb.bkt (p k) ≠ Tb.bkt (p i))
    (hnf : ∀ i, i < m → ∀ w', X.G.isW w' → X.G.loc w' = X.G.loc (r i) → X.op w' = none →
      X.G.hb w' (Tb.ini (X.G.loc (r i))) ∨ X.G.hb (r i) w')
    (hfree : ∀ i, i < m → X.G.hb (r i) (X.acq dF)) :
    ∃ x : Nat → Nat, (∀ k i, k ≤ i → i < m → x k ≤ x i) ∧
      (∀ i, i < m → Tb.pub ≤ x i ∧ x i < dF) ∧
      Bytes.ReplicaSync hash h2 ((List.range m).map (fun i => (X.G.lab (r i)).rval))
        ((List.range m).map (fun i => hist (x i) (Tb.bkt (p i)))) := by
  obtain ⟨x, h1, h2', h3⟩ := group_view Tb Lf hA hAa hAr hrf hloc hacq hpo hdist hnf hfree
  have hlt := h3 dF hdF hfree
  refine ⟨x, h2', fun i hi => ⟨(h1 i hi).1, hlt i hi⟩, ?_⟩
  unfold Bytes.ReplicaSync
  rw [List.map_map]
  apply List.map_congr_left
  intro i hi
  have hi' := List.mem_range.1 hi
  simp only [Function.comp]
  rw [(h1 i hi').2, henc _ _ (h1 i hi').1 (hlt i hi')]

/-- **Property 17's group decision on a sheared load is a model step.** If the model run
schedules reader `u`'s `scanLoad` steps of group `g` at the versions `group_replicaSync`
provides (`hsched`: the recorded slots are `hist (x i) (g[i])`), then Rust's decision on the
bytes it actually loaded is the model's `scanHit` / `scanEmpty` / `scanNext`
(`Bytes.reader_group_step`). -/
theorem group_step_rc11 [DecidableEq K] (C : Cfg K) {hash : K → Nat} {h2 : Nat → Nat}
    (hh2 : ∀ h, h2 h < 0x80) {mb : List Nat → Nat → List Bool} (hmb : Bytes.MatchOK mb)
    {s : St K VV} (hr : PReachable C s) {u st t lv : Nat} {hl : List Nat} {k : K}
    {pre g rest : List Nat} {obs : List (Nat × Slot K VV)}
    (hrd : s.rd u = .scanning st hl k t lv pre g [] obs rest) (hnd : g.Nodup)
    {bs : List Nat} {os : List (Slot K VV)} (hsync : Bytes.ReplicaSync hash h2 bs os)
    (hsched : g.map (Bytes.obsSlot obs) = os) :
    match Bytes.groupDecide mb (h2 (hash k)) k bs (g.map (Bytes.obsSlot obs)) with
    | .found _ v => Step C s (setRd s u (.returned st hl k t lv (some v)))
    | .stop => Step C s (setRd s u (.returned st hl k t lv none))
    | .next => Step C s (setRd s u (.probing st hl k t lv (pre ++ g) rest)) := by
  subst hsched
  exact Bytes.reader_group_step C hh2 hmb hr hrd hnd hsync

end Replica

end SyncTable.RC11Table

#print axioms SyncTable.RC11Table.view
#print axioms SyncTable.RC11Table.group_view
#print axioms SyncTable.RC11Table.group_replicaSync
#print axioms SyncTable.RC11Table.group_step_rc11
#print axioms SyncTable.RC11Table.full_read_data
#print axioms SyncTable.RC11Table.len_view
