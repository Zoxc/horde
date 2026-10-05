import SyncTable.Flags

/-!
# `drop_impl` and memory reuse

`SyncTable::drop_impl` (`impl Drop for SyncTable`, `&mut self`):

```rust
collect::cancel_by_ids(retired_iter().filter(|t| !t.can_free.load(Acquire)).map(|t| &t.can_free));
self.current().free();
for info in retired_iter() { TableRef::from(info).free(); }
```

The composed model `CStep` (`Composed.lean`) is extended by the phases of `drop_impl` and by
environment steps that use freed memory (`DSt`, `DStep`, `DReach`). Every Rust action is its own
step, and `collect` steps of other threads interleave everywhere. Table ids are addresses: a
freed table's address may be reused by a new table of the same `SyncTable` (`Step.expandAt`,
`Step.replaceAt`, with a fresh `can_free`, `allocCell`) or by anyone else.

* `.run c`: the `SyncTable` is in use. `DStep.run` is any `CStep`. `DStep.envRun` writes any
  value into the `can_free` cell of a table that is **freed** (by `prune_tables`): its memory may
  have been reallocated by anyone, and the new owner may write it arbitrarily. The table never
  touches a freed table again (provenance: only the hash table can reach a table's memory until
  it frees it), except by allocating a new table there.
* `DStep.start`: `drop` begins. **Exclusivity**: `Drop::drop` takes `&mut self`, so no `Read`
  handle, `Write` guard or `PotentialSlot` exists (they borrow the `SyncTable`, and references
  returned by `get` live for the pin's lifetime, which that borrow bounds). This is the premise
  `hidle` (every reader `idle`). The drop phases have no table step at all: the table component
  stays frozen until the cancel, and after it no table component exists. Other threads may still
  be pinned in `collect`, and the retired tables' `defer_by_id` flags may still be queued.
* `.loading c rest ids`: the `filter(|t| !t.can_free.load(Acquire))` loop over the retired list
  in list order (`OSt.rl`, head first). `DStep.load` is one `can_free` load of the next retired
  table (`ids` grows by it iff the cell reads `false`). `DStep.loadCol` is a flag-keeping
  `collect` step (`CStep.col`, `KeepFlags`: before the cancel, only `drop_impl` cancels the
  table's flags), which may store `true` to cells. `DStep.loadEnv` is an environment write to a
  freed table's cell.
* `DStep.cancel`: `cancel_by_ids(ids)` (`EStep.cancel`, `Collect.Main.cancelE`) after the loop.
  The table memory becomes `heapOf` of the frozen table state. The free list is `cur :: rl`
  without the static table (Rust's order: `current().free()`, a no-op for the static empty
  table since `free` deallocates only when `bucket_mask > 0`, then the retired list head first).
* `.freeing e heap cell todo log`: `DStep.free` frees the head of `todo` (`heap t := freed`) and
  appends it to the ghost `log` of `drop_impl`'s frees. `DStep.col` is any `collect` step
  registering no flag (`NoNewFlag`). `DStep.alloc` reallocates non-live memory to a new
  `defer_by_id` client (`can_free`-like flag, initialised `false`), and `DStep.envWrite` lets
  anyone write memory that is not a live flag (`Collect.Flags.FStep.envWrite`).

Results (`hcov : C.Cover` is needed for the retired-list invariant `rlInv`):
* `run_store_live`, `loading_store_live`: before the cancel, every pointer `collect` stores
  `true` through is a retired, allocated table whose `can_free` is not yet observed: never a
  freed table's cell, reallocated or not.
* `cancel_unregisters_all`: right after the `cancel_by_ids`, **no** `defer_by_id` flag is
  registered (every registered flag belongs to a retired table whose cell is still `false`, so
  the cell read `false` and the flag was cancelled).
* `freeing_no_store`, `freeing_cell_frozen`: from the cancel on, `collect` stores to no cell at
  all: **no write-after-free into a freed table's `can_free`**, before or after reallocation.
* `run_freach`, `loading_freach`, `freeing_freach`: the run, with every `prune_tables` free,
  every `drop_impl` free, every reallocation and every write by a new owner, is a
  `Collect.Flags.FReach` run **over the real cells**. Every free satisfies `FStep.free`'s
  obligation (live and not registered: `free_obligation`). So
  `Collect.Flags.no_write_after_free` applies at every point (`freeing_no_write_after_free`).
* `drop_frees_all`: once `todo` is empty, the ghost log holds every table that was current
  (unless static) or retired at the cancel, each exactly once, and nothing else.
  `freeing_static_live`: the static empty table is never freed.
* `run_no_assert`, `freeing_no_assert`: `collect`'s `debug_assert!`s never fire. Before the drop
  every `defer_by_id` is of an unregistered table. After the cancel no id is registered, so a
  `defer_by_id` by a new owner of reused memory passes them too.
-/

set_option linter.unusedSectionVars false

namespace SyncTable
namespace Composed

open Collect.Ev (ESt EStep EReach)
open Collect.Flags (fl regIds stores Cell FSt FStep FReach)

variable {K V : Type} [DecidableEq K] (W : Nat) (C : Cfg K)

/-- Composed state extended with the phases of `drop_impl`. -/
inductive DSt (K V : Type) where
  | run (c : CSt K V)
  /-- the `can_free` load loop: `rest` still to load, `ids` the pointers collected so far -/
  | loading (c : CSt K V) (rest ids : List Nat)
  /-- after `cancel_by_ids`: `collect`, the memory, the cells, the tables still to free, and the
  ghost log of the tables `drop_impl` has freed -/
  | freeing (e : ESt) (heap : Nat → Cell) (cell : Nat → Bool) (todo log : List Nat)

/-- An environment write to a cell. -/
def setCell (c : CSt K V) (t : Nat) (b : Bool) : CSt K V := { c with cell := Collect.upd c.cell t b }

inductive DStep : DSt K V → DSt K V → Prop
  | run {c c' : CSt K V} : CStep W C c c' → DStep (.run c) (.run c')
  /-- a new owner of a freed table's memory writes its `can_free` cell -/
  | envRun (c : CSt K V) (t : Nat) (b : Bool) (ht : c.o.s.ts t = .freed) :
      DStep (.run c) (.run (setCell c t b))
  /-- `drop` starts: `&mut self`, so no reader is inside a table operation -/
  | start (c : CSt K V) (hidle : ∀ u, c.o.s.rd u = .idle) : DStep (.run c) (.loading c c.o.rl [])
  /-- `can_free.load(Acquire)` of the next retired table -/
  | load (c : CSt K V) (t : Nat) (rest ids : List Nat) :
      DStep (.loading c (t :: rest) ids)
        (.loading c rest (if c.cell t then ids else ids ++ [t]))
  /-- another thread's `collect` step during the loads -/
  | loadCol (o : OSt K V) (f : Nat → Nat) (cell : Nat → Bool) {e e' : ESt} (rest ids : List Nat)
      (he : EStep W e e') (hk : KeepFlags e e') :
      DStep (.loading ⟨o, e, f, cell⟩ rest ids) (.loading ⟨o, e', f, storeCells cell e e'⟩ rest ids)
  /-- a new owner of a freed table's memory writes it during the loads -/
  | loadEnv (c : CSt K V) (t : Nat) (b : Bool) (rest ids : List Nat) (ht : c.o.s.ts t = .freed) :
      DStep (.loading c rest ids) (.loading (setCell c t b) rest ids)
  /-- `cancel_by_ids(ids)` -/
  | cancel (c : CSt K V) (ids : List Nat) :
      DStep (.loading c [] ids)
        (.freeing (Collect.Main.cancelE c.e ids) (heapOf c.o.s) c.cell
          ((c.o.s.cur :: c.o.rl).filter (· != 0)) [])
  /-- `free` of the next table (`current`, then the retired list in order), logged -/
  | free (e : ESt) (heap : Nat → Cell) (cell : Nat → Bool) (t : Nat) (todo log : List Nat) :
      DStep (.freeing e heap cell (t :: todo) log)
        (.freeing e (Collect.upd heap t .freed) cell todo (log ++ [t]))
  /-- `collect` steps after the cancel -/
  | col {e e' : ESt} (heap : Nat → Cell) (cell : Nat → Bool) (todo log : List Nat)
      (he : EStep W e e') (hn : Collect.Ev.NoNewFlag e e') :
      DStep (.freeing e heap cell todo log) (.freeing e' heap (storeCells cell e e') todo log)
  /-- a new `defer_by_id` client allocates non-live memory (its flag starts `false`) -/
  | alloc (e : ESt) (heap : Nat → Cell) (cell : Nat → Bool) (todo log : List Nat) (i : Nat)
      (hi : heap i ≠ .live) :
      DStep (.freeing e heap cell todo log)
        (.freeing e (Collect.upd heap i .live) (Collect.upd cell i false) todo log)
  /-- anyone writes memory that is not a live flag (freed, never allocated, or owned by someone
  who does not use it as a `defer_by_id` flag) -/
  | envWrite (e : ESt) (heap : Nat → Cell) (cell : Nat → Bool) (todo log : List Nat) (i : Nat)
      (b : Bool) (hl : heap i ≠ .live) :
      DStep (.freeing e heap cell todo log) (.freeing e heap (Collect.upd cell i b) todo log)

inductive DReach : DSt K V → Prop
  | init : DReach (.run cinit)
  | step {d d'} : DReach d → DStep W C d d' → DReach d'

/-! ## Freed tables, and their reuse -/

/-- A table step un-frees a table only by allocating a new `current` at its address. -/
theorem step_unfreed {s s' : St K V} (hi : TsI s) (hs : Step C s s') {t : Nat}
    (h : s.ts t = .freed) (h' : s'.ts t ≠ .freed) : s'.cur = t := by
  have h2 : t ≠ s.cur := fun e => by rw [e, hi.curLive] at h; cases h
  have pub : ∀ t' T' nx ch, (publish s t' T' nx ch).ts t ≠ .freed →
      (publish s t' T' nx ch).cur = t := by
    intro t' T' nx ch hne
    show t' = t
    by_cases e : t = t'
    · exact e.symm
    · exfalso; apply hne
      rw [publish_ts, if_neg e, retire_of_ne (fun ⟨e, _⟩ => h2 e)]; exact h
  cases hs with
  | expand => exact pub _ _ _ _ h'
  | replace => exact pub _ _ _ _ h'
  | expandAt => exact pub _ _ _ _ h'
  | replaceAt => exact pub _ _ _ _ h'
  | replaceEmpty => exact pub _ _ _ _ h'
  | prune t' v d h0 =>
    exfalso; apply h'
    show upd s.ts t' .freed t = .freed
    by_cases e : t = t'
    · subst e; simp
    · rw [upd_other _ _ _ _ e]; exact h
  | markFree t' v d h0 _ =>
    exfalso; apply h'
    have e : t ≠ t' := fun e => by subst e; rw [h] at h0; cases h0
    show upd s.ts t' _ t = .freed
    rw [upd_other _ _ _ _ e]; exact h
  | _ => exact absurd h h'

/-! ## The run with environment writes: simulation of a `CReach` run -/

/-- `c` is a reachable composed state `⟨c.o, c.e, c.f, cell0⟩` up to the cells of freed tables
(written by their memory's new owners). -/
def Sim (c : CSt K V) : Prop :=
  ∃ cell0, CReach W C ⟨c.o, c.e, c.f, cell0⟩ ∧ ∀ t, c.o.s.ts t ≠ .freed → c.cell t = cell0 t

theorem storeCells_agree {cell cell0 : Nat → Bool} {e e' : ESt} {t : Nat}
    (h : cell t = cell0 t) : storeCells cell e e' t = storeCells cell0 e e' t := by
  simp only [storeCells, Collect.Flags.storeAll, h]

theorem sim_init : Sim W C (cinit : CSt K V) := ⟨_, .init, fun _ _ => rfl⟩

theorem sim_env {c : CSt K V} (h : Sim W C c) {t : Nat} (b : Bool) (ht : c.o.s.ts t = .freed) :
    Sim W C (setCell c t b) := by
  obtain ⟨cell0, hr, ha⟩ := h
  refine ⟨cell0, hr, fun x hx => ?_⟩
  have : x ≠ t := fun e => hx (e ▸ ht)
  simp only [setCell, Collect.upd_other _ _ _ _ this]; exact ha x hx

/-- Cells agreeing off freed tables still agree after a table step's allocation. -/
theorem allocCell_agree {s s' : St K V} (hi : TsI s) (hs : Step C s s') {cell cell0 : Nat → Bool}
    (ha : ∀ t, s.ts t ≠ .freed → cell t = cell0 t) :
    ∀ t, s'.ts t ≠ .freed → allocCell cell s.cur s'.cur t = allocCell cell0 s.cur s'.cur t := by
  intro t ht
  by_cases e : t = s'.cur ∧ s'.cur ≠ s.cur
  · obtain ⟨rfl, e2⟩ := e; rw [allocCell_new e2, allocCell_new e2]
  · have hnf : s.ts t ≠ .freed := by
      intro h0
      have e1 := step_unfreed C hi hs h0 ht
      exact e ⟨e1.symm, fun e2 => by rw [e2] at e1; rw [← e1, hi.curLive] at h0; cases h0⟩
    unfold allocCell; split
    · exact ha t hnf
    · rename_i e2
      have : t ≠ s'.cur := fun e3 => e ⟨e3, e2⟩
      rw [upd_other _ _ _ _ this, upd_other _ _ _ _ this]; exact ha t hnf

theorem sim_step {c c' : CSt K V} (h : Sim W C c) (hs : CStep W C c c') : Sim W C c' := by
  obtain ⟨cell0, hr, ha⟩ := h
  have hi := (creach_vi W C hr).ts
  cases hs with
  | tbl e f cell cell' ho hl hcl =>
    subst hcl
    exact ⟨_, .step hr (CStep.tbl e f cell0 _ ho hl rfl),
      allocCell_agree C hi (ostep_step C ho) ha⟩
  | pin rl f cell u hidle he hk hloc hnow =>
    exact ⟨_, .step hr (CStep.pin rl f cell0 u hidle he hk hloc hnow),
      fun t ht => storeCells_agree (ha t ht)⟩
  | unpin rl f cell u st hl hrd he hk hloc =>
    exact ⟨_, .step hr (CStep.unpin rl f cell0 u st hl hrd he hk hloc),
      fun t ht => storeCells_agree (ha t ht)⟩
  | swap e f cell ho hc hc0 =>
    exact ⟨_, .step hr (CStep.swap e f cell0 ho hc hc0),
      allocCell_agree C hi (ostep_step C ho) ha⟩
  | markFree s rl e f cell t v d ht hc =>
    have hc0 : cell0 t = true := by rw [← ha t (by simp only; rw [ht]; simp)]; exact hc
    refine ⟨cell0, .step hr (CStep.markFree s rl e f cell0 t v d ht hc0), fun x hx => ha x ?_⟩
    intro h0; apply hx; simp only [upd]; split
    · rename_i e; subst e; simp only at h0; rw [ht] at h0; cases h0
    · exact h0
  | col o f cell he hk hfix =>
    exact ⟨_, .step hr (CStep.col o f cell0 he hk hfix), fun t ht => storeCells_agree (ha t ht)⟩

/-- **The flag memory over the real cells**: the reachable run `cell0` plus one environment
write (`FStep.envWrite`) of the freed tables' cells. -/
theorem sim_freach {c : CSt K V} (h : Sim W C c) :
    ∃ born, FReach ⟨c.e.base, heapOf c.o.s, c.cell, born⟩ := by
  obtain ⟨cell0, hr, ha⟩ := h
  obtain ⟨born, hf⟩ := creach_freach W C hr
  refine ⟨born, .step hf (FStep.envWrite _ _ _ _ _ fun i hi => ha i ?_)⟩
  intro h0; simp only [heapOf, h0, cellOf] at hi; cases hi

/-! ## `cancel_by_ids` -/

/-- A registered flag's table has its `can_free` cell `false`. -/
theorem registered_cell_false {c : CSt K V} (h : CReach W C c) {t : Nat}
    (ht : t ∈ regIds c.e.base) : ∃ v d, c.o.s.ts t = .retired v d false ∧ c.cell t = false := by
  obtain ⟨x, hx, rfl⟩ := mem_regIds.1 ht
  have hv := creach_vi W C h
  obtain ⟨v, d, h1, h2⟩ := hv.queued x hx
  refine ⟨v, d, h1, ?_⟩
  cases e : c.cell x.id
  · rfl
  · have hran := (hv.val _ _ _ _ h1).1 e
    rw [← h2] at hran
    exact absurd (List.mem_filter.2 ⟨hran, (mem_fl.1 hx).2⟩)
      (Collect.Flags.fl_not_ran (Collect.Ev.ereach_base W (creach_ereach W C h)) hx)

theorem cancelE_bufs (e : ESt) (ids : List Nat) {x : Collect.Cb}
    (h : x ∈ Collect.bufs (Collect.Main.cancelE e ids).base) : x ∈ Collect.bufs e.base := by
  simp only [Collect.Main.cancelE, Collect.bufs, List.mem_append] at h ⊢
  rcases h with (h1 | h1) | h1
  · exact .inl (.inl (Collect.cancelList_sub _ _ h1))
  · exact .inl (.inr (Collect.cancelList_sub _ _ h1))
  · exact .inr (Collect.cancelList_sub _ _ h1)

theorem regIds_cancel_sub (e : ESt) (ids : List Nat) {t : Nat}
    (ht : t ∈ regIds (Collect.Main.cancelE e ids).base) : t ∈ regIds e.base := by
  obtain ⟨x, hx, rfl⟩ := mem_regIds.1 ht
  exact mem_regIds.2 ⟨x, mem_fl.2 ⟨cancelE_bufs e ids (mem_fl.1 hx).1, (mem_fl.1 hx).2⟩, rfl⟩

/-- After a `cancel_by_ids` covering every retired table whose `can_free` is `false`, no
`defer_by_id` flag is registered (`Collect.Flags.cancel_unregisters`). -/
theorem drop_unregisters {c : CSt K V} (h : CReach W C c) (ids : List Nat)
    (hids : ∀ t v d cf, c.o.s.ts t = .retired v d cf → c.cell t = false → t ∈ ids) :
    regIds (Collect.Main.cancelE c.e ids).base = [] := by
  apply List.eq_nil_iff_forall_not_mem.2
  intro t ht
  obtain ⟨v, d, h1, h2⟩ := registered_cell_false W C h (regIds_cancel_sub c.e ids ht)
  exact Collect.Flags.cancel_unregisters c.e.base ids (hids t v d false h1 h2) ht

/-- The `cancel_by_ids` step stores nothing and registers nothing. -/
theorem freach_cancel {e : ESt} {heap : Nat → Cell} {val : Nat → Bool} {born : Nat → Nat}
    (ids : List Nat) (h : FReach ⟨e.base, heap, val, born⟩) :
    FReach ⟨(Collect.Main.cancelE e ids).base, heap, val, born⟩ := by
  have hst := FStep.col heap val born (Collect.Step.cancel e.base ids) (fun x hx =>
    mem_fl.2 ⟨cancelE_bufs e ids (mem_fl.1 hx).1, (mem_fl.1 hx).2⟩)
  have : Collect.Flags.storeAll val (stores e.base (Collect.Main.cancelE e ids).base) = val := by
    simp only [stores, Collect.Flags.newRan, Collect.Main.cancelE]; simp [storeAll_nil]
  rw [show (Collect.Main.cancelE e ids).base = { e.base with
      pending := Collect.cancelList ids e.base.pending, current := Collect.cancelList ids e.base.current,
      previous := Collect.cancelList ids e.base.previous } from rfl] at this ⊢
  rw [this] at hst
  exact .step h hst


/-! ## Invariants of the phases -/

theorem storeCells_false {cell : Nat → Bool} {e e' : ESt} {t : Nat}
    (h : storeCells cell e e' t = false) : cell t = false := by
  simp only [storeCells, Collect.Flags.storeAll, Bool.or_eq_false_iff] at h; exact h.1

/-- Invariant of the load loop. -/
structure LI (c : CSt K V) (rest ids : List Nat) : Prop where
  sim : Sim W C c
  idle : ∀ u, c.o.s.rd u = .idle
  /-- every retired table already loaded whose cell is (still) `false` is in `ids` -/
  done : ∃ done, c.o.rl = done ++ rest ∧ ∀ t ∈ done, c.cell t = false → t ∈ ids

/-- The free list of `drop_impl` for the table state `c`. -/
def freeList (c : CSt K V) : List Nat := (c.o.s.cur :: c.o.rl).filter (· != 0)

/-- Invariant of the freeing phase. -/
structure DI (e : ESt) (heap : Nat → Cell) (cell : Nat → Bool) (todo log : List Nat) : Prop where
  ereach : EReach W e
  noReg : regIds e.base = []
  /-- the flag memory, over the real cells -/
  freach : ∃ born, FReach ⟨e.base, heap, cell, born⟩
  stat : heap 0 = .live
  nodup : todo.Nodup
  live : ∀ t ∈ todo, heap t = .live ∧ t ≠ 0
  /-- the log and the rest of the free list make up the free list at the cancel -/
  plan : ∃ c : CSt K V, Sim W C c ∧ log ++ todo = freeList c ∧ (freeList c).Nodup ∧
    ∀ t, t ≠ 0 → (t = c.o.s.cur ∨ ∃ v d cf, c.o.s.ts t = .retired v d cf) → t ∈ freeList c

def Good : DSt K V → Prop
  | .run c => Sim W C c
  | .loading c rest ids => LI W C c rest ids
  | .freeing e heap cell todo log => DI (K := K) (V := V) W C e heap cell todo log

/-- The `cancel_by_ids` set covers every retired table whose cell is `false`. -/
theorem cancel_ids_cover (hcov : C.Cover) {c : CSt K V} {ids : List Nat} (h : LI W C c [] ids) :
    ∃ cell0, CReach W C ⟨c.o, c.e, c.f, cell0⟩ ∧
      ∀ t v d cf, c.o.s.ts t = .retired v d cf → cell0 t = false → t ∈ ids := by
  obtain ⟨cell0, hr, ha⟩ := h.sim
  refine ⟨cell0, hr, fun t v d cf ht hc => ?_⟩
  obtain ⟨done, hrl, hd⟩ := h.done
  have hm : t ∈ c.o.rl := ((rlInv C hcov (creach_oreach W C hr)).mem t).2 ⟨v, d, cf, ht⟩
  rw [hrl, List.append_nil] at hm
  exact hd t hm (by rw [ha t (by rw [ht]; simp)]; exact hc)

theorem freeing_freach_step {e : ESt} {heap : Nat → Cell} {cell cell' : Nat → Bool}
    (born : Nat → Nat) (hf : FReach ⟨e.base, heap, cell, born⟩)
    (hw : ∀ i, heap i = .live → cell' i = cell i) : FReach ⟨e.base, heap, cell', born⟩ :=
  .step hf (FStep.envWrite _ _ _ _ _ hw)

theorem good_step (hcov : C.Cover) {d d' : DSt K V} (h : Good W C d) (hs : DStep W C d d') :
    Good W C d' := by
  cases hs with
  | run hc => exact sim_step W C h hc
  | envRun c t b ht => exact sim_env W C h b ht
  | start c hidle => exact ⟨h, hidle, [], by simp, by simp⟩
  | load c t rest ids =>
    obtain ⟨hr, hidle, done, hrl, hd⟩ := h
    refine ⟨hr, hidle, done ++ [t], by rw [hrl]; simp, fun x hx hc => ?_⟩
    rcases List.mem_append.1 hx with hx | hx
    · have := hd x hx hc; split <;> simp [this]
    · simp at hx; subst hx; simp [hc]
  | loadCol o f cell rest ids he hk =>
    obtain ⟨⟨cell0, hr, ha⟩, hidle, done, hrl, hd⟩ := h
    exact ⟨⟨_, .step hr (CStep.col o f cell0 he hk (fun u hu => absurd (hidle u) hu)),
      fun t ht => storeCells_agree (ha t ht)⟩, hidle, done, hrl,
      fun x hx hc => hd x hx (storeCells_false hc)⟩
  | loadEnv c t b rest ids ht =>
    obtain ⟨hs, hidle, done, hrl, hd⟩ := h
    refine ⟨sim_env W C hs b ht, hidle, done, hrl, fun x hx hc => hd x hx ?_⟩
    have hne : x ≠ t := by
      intro e; subst e
      obtain ⟨cell0, hr, _⟩ := hs
      have hm : x ∈ c.o.rl := by rw [hrl]; exact List.mem_append_left _ hx
      obtain ⟨v, d, cf, e⟩ := ((rlInv C hcov (creach_oreach W C hr)).mem x).1 hm
      simp only at e; rw [e] at ht; cases ht
    simp only [setCell, Collect.upd_other _ _ _ _ hne] at hc; exact hc
  | cancel c ids =>
    obtain ⟨cell0, hr, hids⟩ := cancel_ids_cover W C hcov h
    have hv := creach_vi W C hr
    have hI := rlInv C hcov (creach_oreach W C hr)
    obtain ⟨born, hf⟩ := sim_freach W C h.sim
    have hcl : c.o.s.ts c.o.s.cur = .live := hv.ts.curLive
    have hs0 : c.o.s.ts 0 = .live := hv.ts.stat
    have hmem : ∀ t, t ∈ c.o.rl ↔ ∃ v d cf, c.o.s.ts t = .retired v d cf := hI.mem
    have hrlnd : c.o.rl.Nodup := hI.sorted.imp (fun h e => by subst e; omega)
    have hcur : c.o.s.cur ∉ c.o.rl := fun hm => by
      obtain ⟨v, d, cf, e⟩ := (hmem _).1 hm; rw [hcl] at e; cases e
    have hnd : (freeList c).Nodup := (List.nodup_cons.2 ⟨hcur, hrlnd⟩).filter _
    refine ⟨.step (creach_ereach W C hr) (EStep.cancel c.e ids),
      drop_unregisters W C hr ids hids, ⟨born, freach_cancel ids hf⟩,
      by simp [heapOf, hs0, cellOf], hnd, ?_, ⟨c, h.sim, rfl, hnd, ?_⟩⟩
    · intro t ht
      obtain ⟨hm, h0⟩ := List.mem_filter.1 ht
      refine ⟨?_, by simpa using h0⟩
      rcases List.mem_cons.1 hm with e | e
      · rw [e]; simp [heapOf, hcl, cellOf]
      · obtain ⟨v, d, cf, e⟩ := (hmem _).1 e; simp [heapOf, e, cellOf]
    · intro t h0 ht
      refine List.mem_filter.2 ⟨?_, by simpa using h0⟩
      rcases ht with e | ⟨v, d, cf, e⟩
      · rw [e]; exact List.mem_cons_self
      · exact List.mem_cons_of_mem _ ((hmem t).2 ⟨v, d, cf, e⟩)
  | free e heap cell t todo log =>
    obtain ⟨her, hreg, ⟨born, hf⟩, hst, hnd, hl, c, hsim, hplan, hnd', hall⟩ := h
    have hnt : t ∉ todo := (List.nodup_cons.1 hnd).1
    obtain ⟨hlt, h0⟩ := hl t List.mem_cons_self
    have hfr := FStep.free e.base heap cell born t hlt (by rw [hreg]; simp)
    refine ⟨her, hreg, ⟨born, .step hf hfr⟩,
      by rw [Collect.upd_other _ _ _ _ (Ne.symm h0)]; exact hst, (List.nodup_cons.1 hnd).2,
      fun x hx => ?_, ⟨c, hsim, by rw [← hplan]; simp, hnd', hall⟩⟩
    have hne : x ≠ t := fun e => hnt (e ▸ hx)
    rw [Collect.upd_other _ _ _ _ hne]; exact hl x (List.mem_cons_of_mem _ hx)
  | col heap cell todo log he hn =>
    rename_i e0 e1
    obtain ⟨her, hreg, ⟨born, hf⟩, hst, hnd, hl, hp⟩ := h
    have hno : ∀ x ∈ fl e1.base, x ∈ fl e0.base := fun x hx =>
      mem_fl.2 ⟨hn x (mem_fl.1 hx).2 (mem_fl.1 hx).1, (mem_fl.1 hx).2⟩
    have hreg' : regIds e1.base = [] := by
      apply List.eq_nil_iff_forall_not_mem.2
      intro t ht
      obtain ⟨x, hx, rfl⟩ := mem_regIds.1 ht
      have : x.id ∈ regIds e0.base := mem_regIds.2 ⟨x, hno x hx, rfl⟩
      rw [hreg] at this; cases this
    refine ⟨.step her he, hreg', ?_, hst, hnd, hl, hp⟩
    rcases Collect.Ev.estep_base W he with hb | hb
    · refine ⟨born, ?_⟩
      have : storeCells cell e0 e1 = cell := by
        simp only [storeCells, stores, Collect.Flags.newRan, hb]; simp [storeAll_nil]
      rw [this, hb]; exact hf
    · exact ⟨born, .step hf (FStep.col _ _ _ hb hno)⟩
  | alloc e heap cell todo log i hi =>
    obtain ⟨her, hreg, ⟨born, hf⟩, hst, hnd, hl, hp⟩ := h
    have hne : ∀ x, heap x = .live → x ≠ i := fun x hx e => hi (e ▸ hx)
    refine ⟨her, hreg, ⟨_, .step hf (FStep.alloc e.base heap cell born i hi)⟩,
      by rw [Collect.upd_other _ _ _ _ (hne 0 hst)]; exact hst, hnd, fun x hx => ?_, hp⟩
    obtain ⟨h1, h2⟩ := hl x hx
    exact ⟨by rw [Collect.upd_other _ _ _ _ (hne x h1)]; exact h1, h2⟩
  | envWrite e heap cell todo log i b hl' =>
    obtain ⟨her, hreg, ⟨born, hf⟩, hst, hnd, hl, hp⟩ := h
    refine ⟨her, hreg, ⟨born, freeing_freach_step born hf fun x hx => ?_⟩, hst, hnd, hl, hp⟩
    have : x ≠ i := fun e => hl' (e ▸ hx)
    exact Collect.upd_other _ _ _ _ this

theorem dreach_good (hcov : C.Cover) {d : DSt K V} (h : DReach W C d) : Good W C d := by
  induction h with
  | init => exact sim_init W C
  | step _ hs ih => exact good_step W C hcov ih hs

/-! ## Results -/

/-- **Before the drop, `collect` stores only into retired, allocated tables** whose `can_free`
is not yet observed: never into a freed table's cell, reallocated or not. -/
theorem run_store_live (hcov : C.Cover) {c : CSt K V} (h : DReach W C (.run c))
    {b' : Collect.St} (hs : Collect.Step c.e.base b') :
    ∀ i ∈ stores c.e.base b', heapOf c.o.s i = .live ∧ ∃ v d, c.o.s.ts i = .retired v d false := by
  obtain ⟨cell0, hr, _⟩ := (dreach_good W C hcov h : Sim W C c)
  exact (collect_store_live W C hr hs).2

/-- The same during `drop_impl`'s `can_free` loads. -/
theorem loading_store_live (hcov : C.Cover) {c : CSt K V} {rest ids : List Nat}
    (h : DReach W C (.loading c rest ids)) {b' : Collect.St} (hs : Collect.Step c.e.base b') :
    ∀ i ∈ stores c.e.base b', heapOf c.o.s i = .live ∧ ∃ v d, c.o.s.ts i = .retired v d false := by
  obtain ⟨cell0, hr, _⟩ := (dreach_good W C hcov h : LI W C c rest ids).sim
  exact (collect_store_live W C hr hs).2

/-- **Exclusivity during `drop_impl`'s loads**: no reader probes or holds references into any
table. -/
theorem loading_idle (hcov : C.Cover) {c : CSt K V} {rest ids : List Nat}
    (h : DReach W C (.loading c rest ids)) : ∀ u t, ¬ Uses (c.o.s.rd u) t := by
  intro u t hu; rw [(dreach_good W C hcov h : LI W C c rest ids).idle u] at hu; exact hu

/-- No table step during the loads: every step keeps the table component (`o`). -/
theorem loading_frozen {c : CSt K V} {rest ids : List Nat} {d' : DSt K V}
    (hs : DStep W C (.loading c rest ids) d') :
    (∃ c' rest' ids', d' = .loading c' rest' ids' ∧ c'.o = c.o) ∨
      ∃ e h cl td lg, d' = .freeing e h cl td lg := by
  cases hs with
  | load => exact .inl ⟨_, _, _, rfl, rfl⟩
  | loadCol => exact .inl ⟨_, _, _, rfl, rfl⟩
  | loadEnv => exact .inl ⟨_, _, _, rfl, rfl⟩
  | cancel => exact .inr ⟨_, _, _, _, _, rfl⟩

/-- **After `drop_impl`'s `cancel_by_ids`, no `defer_by_id` flag is registered.** -/
theorem cancel_unregisters_all (hcov : C.Cover) {e : ESt} {heap : Nat → Cell}
    {cell : Nat → Bool} {todo log : List Nat}
    (h : DReach W C (.freeing e heap cell todo log : DSt K V)) : regIds e.base = [] :=
  (dreach_good W C hcov h : DI (K := K) (V := V) W C e heap cell todo log).noReg

/-- **After the cancel, `collect` stores to no cell.** -/
theorem freeing_no_store (hcov : C.Cover) {e : ESt} {heap : Nat → Cell} {cell : Nat → Bool}
    {todo log : List Nat} (h : DReach W C (.freeing e heap cell todo log : DSt K V))
    {b' : Collect.St} (hs : Collect.Step e.base b') : stores e.base b' = [] := by
  have hd : DI (K := K) (V := V) W C e heap cell todo log := dreach_good W C hcov h
  apply List.eq_nil_iff_forall_not_mem.2
  intro i hi
  have := Collect.Flags.store_registered (Collect.Ev.ereach_base W hd.ereach) hs hi
  rw [hd.noReg] at this; cases this

/-- **No `collect` write into any cell after the cancel** (so none into a freed table's, before
or after its reuse): a `collect` step (`DStep.col`) keeps the cells. -/
theorem freeing_cell_frozen (hcov : C.Cover) {e e' : ESt} {heap : Nat → Cell}
    {cell : Nat → Bool} {todo log : List Nat}
    (h : DReach W C (.freeing e heap cell todo log : DSt K V)) (he : EStep W e e') :
    storeCells cell e e' = cell := by
  rcases Collect.Ev.estep_base W he with hb | hb
  · simp only [storeCells, stores, Collect.Flags.newRan, hb]; simp [storeAll_nil]
  · rw [storeCells, freeing_no_store W C hcov h hb, storeAll_nil]

/-- **The flag memory is a `Collect.Flags.FReach` run over the real cells**, with every free,
every reallocation and every write by a new owner: before the drop, during the loads, and
after the cancel. -/
theorem run_freach (hcov : C.Cover) {c : CSt K V} (h : DReach W C (.run c)) :
    ∃ born, FReach ⟨c.e.base, heapOf c.o.s, c.cell, born⟩ :=
  sim_freach W C (dreach_good W C hcov h : Sim W C c)

theorem loading_freach (hcov : C.Cover) {c : CSt K V} {rest ids : List Nat}
    (h : DReach W C (.loading c rest ids)) :
    ∃ born, FReach ⟨c.e.base, heapOf c.o.s, c.cell, born⟩ :=
  sim_freach W C (dreach_good W C hcov h : LI W C c rest ids).sim

theorem freeing_freach (hcov : C.Cover) {e : ESt} {heap : Nat → Cell} {cell : Nat → Bool}
    {todo log : List Nat} (h : DReach W C (.freeing e heap cell todo log : DSt K V)) :
    ∃ born, FReach ⟨e.base, heap, cell, born⟩ :=
  (dreach_good W C hcov h : DI (K := K) (V := V) W C e heap cell todo log).freach

/-- `Collect.Flags.no_write_after_free` after the cancel: every store hits a live, registered
flag (and there are none). -/
theorem freeing_no_write_after_free (hcov : C.Cover) {e : ESt} {heap : Nat → Cell}
    {cell : Nat → Bool} {todo log : List Nat}
    (h : DReach W C (.freeing e heap cell todo log : DSt K V))
    {b' : Collect.St} (hs : Collect.Step e.base b') :
    ∀ i ∈ stores e.base b', heap i = .live ∧ i ∈ regIds e.base := by
  obtain ⟨_, hf⟩ := freeing_freach W C hcov h
  exact fun i hi => ⟨((Collect.Flags.no_write_after_free hf hs).2 i hi).1,
    ((Collect.Flags.no_write_after_free hf hs).2 i hi).2.1⟩

/-- **`free` obligation**: each table `drop_impl` frees is allocated, not the static one, and
not registered with `collect` (`FStep.free`'s premise). -/
theorem free_obligation (hcov : C.Cover) {e : ESt} {heap : Nat → Cell} {cell : Nat → Bool}
    {t : Nat} {todo log : List Nat}
    (h : DReach W C (.freeing e heap cell (t :: todo) log : DSt K V)) :
    heap t = .live ∧ t ≠ 0 ∧ t ∉ regIds e.base := by
  have hd : DI (K := K) (V := V) W C e heap cell (t :: todo) log := dreach_good W C hcov h
  obtain ⟨h1, h2⟩ := hd.live t List.mem_cons_self
  exact ⟨h1, h2, by rw [hd.noReg]; simp⟩

/-- **Every table is freed by `drop_impl` exactly once.** When the free list is done, the ghost
log of `drop_impl`'s `free` steps is duplicate-free and contains every table that was `current`
(unless static) or retired at the drop, and nothing else. -/
theorem drop_frees_all (hcov : C.Cover) {e : ESt} {heap : Nat → Cell} {cell : Nat → Bool}
    {log : List Nat} (h : DReach W C (.freeing e heap cell [] log : DSt K V)) :
    ∃ c : CSt K V, Sim W C c ∧ log.Nodup ∧ ∀ t, t ∈ log ↔ t ≠ 0 ∧
      (t = c.o.s.cur ∨ ∃ v d cf, c.o.s.ts t = .retired v d cf) := by
  obtain ⟨c, hsim, hplan, hnd, hall⟩ := (dreach_good W C hcov h : DI (K := K) (V := V) W C e heap cell [] log).plan
  rw [List.append_nil] at hplan
  subst hplan
  obtain ⟨cell0, hr, _⟩ := hsim
  have hI := rlInv C hcov (creach_oreach W C hr)
  refine ⟨c, ⟨cell0, hr, by assumption⟩, hnd, fun t => ⟨fun ht => ?_, fun ⟨h0, ht⟩ => hall t h0 ht⟩⟩
  obtain ⟨hm, h0⟩ := List.mem_filter.1 ht
  refine ⟨by simpa using h0, ?_⟩
  rcases List.mem_cons.1 hm with e | e
  · exact .inl e
  · exact .inr ((hI.mem t).1 e)

/-- **The static empty table is never freed**, also during and after the drop. -/
theorem freeing_static_live (hcov : C.Cover) {e : ESt} {heap : Nat → Cell} {cell : Nat → Bool}
    {todo log : List Nat} (h : DReach W C (.freeing e heap cell todo log : DSt K V)) :
    heap 0 = .live :=
  (dreach_good W C hcov h : DI (K := K) (V := V) W C e heap cell todo log).stat

theorem run_static_live (hcov : C.Cover) {c : CSt K V} (h : DReach W C (.run c)) :
    c.o.s.ts 0 = .live := by
  obtain ⟨cell0, hr, _⟩ := (dreach_good W C hcov h : Sim W C c)
  exact static_never_freed (c := ⟨c.o, c.e, c.f, cell0⟩) W C hr

/-- **No `debug_assert!` of `collect` fires after the cancel**: no id is registered, so a
`defer_by_id` of any address (e.g. reused table memory) passes the asserts. -/
theorem freeing_no_assert (hcov : C.Cover) {e : ESt} {heap : Nat → Cell} {cell : Nat → Bool}
    {todo log : List Nat} (h : DReach W C (.freeing e heap cell todo log : DSt K V)) (i : Nat) :
    Collect.Flags.assertFires e.base i = false :=
  Collect.Flags.assert_never_fires (by rw [cancel_unregisters_all W C hcov h]; simp)

/-- Before the drop, every `defer_by_id` (`replace_table`) passes the asserts. -/
theorem run_no_assert (hcov : C.Cover) {c : CSt K V} (h : DReach W C (.run c)) :
    Collect.Flags.assertFires c.e.base c.o.s.cur = false := by
  obtain ⟨cell0, hr, _⟩ := (dreach_good W C hcov h : Sim W C c)
  exact swap_no_assert (c := ⟨c.o, c.e, c.f, cell0⟩) W C hr

end Composed
end SyncTable
