import SyncTable.Composed
import Collect.Flags

/-!
# Discharging `defer_by_id`'s obligation in the composed model

`replace_table` calls `collect::defer_by_id(&table.info().can_free)`; the flag pointer is the
table id (`CStep.swap` = `deferE e cur`). `Collect.Flags` states the caller's obligation as the
premises of `FStep.deferId` (the flag is live and not registered) and `FStep.free` (a freed flag
is not registered). Here the table's flag memory is the table allocation itself:
`heapOf s t = cellOf (s.ts t)` (`unalloc`, `live`/`retired` = live, `freed`), and the flag values
are the composed model's `can_free` cells (`CSt.cell`).

The table is the only `defer_by_id` client in the composed run: the `collect` steps run alongside
(`CStep.pin`/`unpin`/`col`) register no flag (`KeepFlags`), so the only new registration is the
table's own in `CStep.swap` (`onlyTable`), for an old `current` that is not the static empty
table. (Other clients, such as `SyncPushVec`, register
pointers into their own allocations, which are distinct from the table's; they are not part of
the composed run.)

Results (all for every `CReach` state):
* `creach_fi`: every queued flag is the flag of a retired table whose `can_free` is not yet
  observed, with that table's defer time (`FI.queued`); every table whose `can_free` was observed
  has had its flag stored by `collect` (`FI.stored`).
* `creach_freach`: **the obligation is discharged**: the composed run, with the table memory as
  flag heap and the `can_free` cells as flag values, is a run of `Collect.Flags.FReach` (every
  `defer_by_id` is on a live, unregistered table; every table free is of an unregistered table;
  a new table is allocated at a non-live address (`nextId`, `unalloc`, or a freed table's, `swapAt`) with `can_free = false` (`allocCell`, `FStep.alloc`);
  `replace_table` of the static table into itself allocates nothing and defers nothing).
  So `Collect.Flags.flag_true_iff` applies to the cells (`can_free_iff_stored`).
* `swap_obligation`: at `replace_table` the old `current` is live and not registered, so the
  `debug_assert!`s do not fire (`swap_no_assert`). The defer happens only for an old `current`
  other than the static empty table (`CStep.swap`, `onlyTable`).
* `static_not_registered`, `static_never_deferred`: the static empty table is never registered
  or deferred (with `Composed.static_can_free_false`: its `can_free` stays `false`).
* `freed_after_stored`: a table is freed only after `collect` stored its flag (and
  `prune_tables` read the cell as `true`), and it is then not registered.
* `flags_no_dup`: no table is registered twice.
* `collect_store_live`: every `true` store `collect` performs hits a retired, still allocated
  table whose `can_free` is not yet observed set.
-/

set_option linter.unusedSectionVars false

namespace SyncTable
namespace Composed

open Collect.Ev (ESt EStep EReach)
open Collect.Flags (fl regIds stores deferIdSt Cell FSt FStep FReach)

variable {K V : Type} [DecidableEq K] (W : Nat) (C : Cfg K)

/-- A table's allocation state as flag memory. -/
def cellOf : TS → Cell
  | .unalloc => .unalloc
  | .live => .live
  | .retired .. => .live
  | .freed => .freed

def heapOf (s : St K V) : Nat → Cell := fun t => cellOf (s.ts t)

/-- The only new `defer_by_id` registration of a composed step is the table's own, in
`replace_table` (`deferE e cur`) of a `current` that is not the static empty table. -/
def OnlyTable (c c' : CSt K V) : Prop :=
  ∀ x ∈ fl c'.e.base, x ∈ fl c.e.base ∨
    (x = ⟨c.o.s.cur, c.e.base.now, true⟩ ∧ c'.o.s.cur ≠ c.o.s.cur ∧ c.o.s.cur ≠ 0)

theorem keep_noNew {e e' : ESt} (hk : KeepFlags e e') : ∀ x ∈ fl e'.base, x ∈ fl e.base :=
  fun x hx => by rw [mem_fl] at hx ⊢; exact ⟨hk.2 x hx.2 hx.1, hx.2⟩

/-- **The table is the only `defer_by_id` client** of the composed run. -/
theorem onlyTable {c c' : CSt K V} (hs : CStep W C c c') : OnlyTable c c' := by
  cases hs with
  | tbl => exact fun x hx => .inl hx
  | pin _ _ _ _ _ _ hk => exact fun x hx => .inl (keep_noNew hk x hx)
  | unpin _ _ _ _ _ _ _ _ hk => exact fun x hx => .inl (keep_noNew hk x hx)
  | col _ _ _ _ hk => exact fun x hx => .inl (keep_noNew hk x hx)
  | markFree => exact fun x hx => .inl hx
  | swap e f cell ho hc hc0 =>
    rename_i o o'
    intro x hx
    have : fl (deferE e o.s.cur).base = fl e.base ++ [⟨o.s.cur, e.base.now, true⟩] := by
      simp [Collect.Flags.fl, Collect.Flags.flat, deferE, List.filter_append]
    rw [this] at hx
    rcases List.mem_append.1 hx with h | h
    · exact .inl h
    · simp at h; exact .inr ⟨h, hc, hc0⟩

/-- The table flag invariant. -/
structure FI (c : CSt K V) : Prop where
  /-- every queued flag is the flag of a retired table whose `can_free` is not yet observed -/
  queued : ∀ x ∈ fl c.e.base, ∃ v d, c.o.s.ts x.id = .retired v d false ∧ x = flagCb c.f x.id d
  /-- `can_free` observed implies `collect` stored the flag -/
  stored : ∀ t v d, c.o.s.ts t = .retired v d true → flagCb c.f t d ∈ c.e.base.ran

theorem creach_fi {c : CSt K V} (h : CReach W C c) : FI c := by
  have hv := creach_vi W C h
  exact ⟨hv.queued, fun t v d ht => (hv.val t v d true ht).1 (hv.obs t v d ht)⟩

theorem mem_regIds {s : Collect.St} {i : Nat} : i ∈ regIds s ↔ ∃ x ∈ fl s, x.id = i := by
  rw [Collect.Flags.regIds_eq]; simp

/-- A table-only step (`CStep.tbl`) keeps the flag memory, frees a table whose `can_free` was
observed (a `prune_tables` iteration), or allocates a new `current` at an address `a` that is not
live (`nextId`, or a freed table's address: `replace_table` of the static empty table, which
retires and defers nothing). -/
theorem tbl_heap {o o' : OSt K V} (hi : TsI o.s) (ho : OStep C o o') (hl : Local o.s o'.s) :
    (heapOf o'.s = heapOf o.s ∧ o'.s.cur = o.s.cur) ∨
      (∃ t v d, o.s.ts t = .retired v d true ∧ o'.s.ts = upd o.s.ts t .freed ∧
        o'.s.cur = o.s.cur) ∨
      (∃ a, heapOf o.s a ≠ .live ∧ o'.s.cur = a ∧ a ≠ o.s.cur ∧
        heapOf o'.s = Collect.upd (heapOf o.s) a .live) := by
  cases ho with
  | other rl hs hcur hfr =>
    rename_i s s'
    -- `replace_table` of the static table
    have pub : ∀ t T' nx ch, PubOK s t T' nx → s'.cur = t → s' = publish s t T' nx ch →
        (heapOf s' = heapOf s ∧ s'.cur = s.cur) ∨ (∃ a, heapOf s a ≠ .live ∧ s'.cur = a ∧
          a ≠ s.cur ∧ heapOf s' = Collect.upd (heapOf s) a .live) := by
      intro t T' nx ch hp hct hs'
      have hc0 : s.cur = 0 := by
        rcases hcur with e | e
        · rcases hp with ⟨rfl, _⟩ | ⟨rfl, _, _⟩ | ⟨ht, _⟩
          · exact absurd (hct ▸ e) (Nat.ne_of_gt hi.curLt)
          · exact (hct ▸ e).symm
          · rw [← hct, e, hi.curLive] at ht; cases ht
        · exact e
      have hts : ∀ x, s'.ts x = if x = t then .live else s.ts x := by
        intro x; rw [hs', publish_ts, retire_cur0 hc0]
      have halloc : s.ts t = .unalloc ∨ s.ts t = .freed →
          ∃ a, heapOf s a ≠ .live ∧ s'.cur = a ∧ a ≠ s.cur ∧
            heapOf s' = Collect.upd (heapOf s) a .live := by
        intro ht
        refine ⟨t, by rcases ht with ht | ht <;> simp [heapOf, ht, cellOf], hct, fun e => ?_,
          funext fun x => ?_⟩
        · rw [e, hi.curLive] at ht; rcases ht with ht | ht <;> cases ht
        · simp only [heapOf, hts, Collect.upd]; split <;> rfl
      rcases hp with ⟨rfl, _⟩ | ⟨rfl, _, _⟩ | ⟨ht, _⟩
      · exact .inr (halloc (.inl (hi.fresh _ (Nat.le_refl _))))
      · refine .inl ⟨funext fun x => ?_, by rw [hct, hc0]⟩
        simp only [heapOf, hts]; split
        · rename_i e; rw [e, hi.stat]
        · rfl
      · exact .inr (halloc (.inr ht))
    have lift : ∀ {t T' nx ch}, PubOK s t T' nx → s'.cur = t → s' = publish s t T' nx ch →
        ((heapOf s' = heapOf s ∧ s'.cur = s.cur) ∨
        (∃ t v d, s.ts t = .retired v d true ∧ s'.ts = upd s.ts t .freed ∧ s'.cur = s.cur) ∨
        (∃ a, heapOf s a ≠ .live ∧ s'.cur = a ∧ a ≠ s.cur ∧
          heapOf s' = Collect.upd (heapOf s) a .live)) := by
      intro t T' nx ch hp hct hs'
      rcases pub t T' nx ch hp hct hs' with e | e
      · exact .inl e
      · exact .inr (.inr e)
    cases hs with
    | expand => exact lift (swap_pub _ _) rfl rfl
    | replace => exact lift (swap_pub _ _) rfl rfl
    | expandAt m a ha => exact lift (swapAt_pub _ ha) rfl rfl
    | replaceAt m a l ha => exact lift (swapAt_pub _ ha) rfl rfl
    | replaceEmpty => exact lift (swapEmpty_pub _) rfl rfl
    | prune t v d h' =>
      have := hfr t (by simp)
      rw [h'] at this; cases this
    | markFree t v d h' _ =>
      left; refine ⟨?_, rfl⟩; funext x; simp only [heapOf, upd]
      split
      · subst x; rw [h']; rfl
      · rfl
    | _ => exact .inl ⟨rfl, rfl⟩
  | swap rl hs hc hc0 =>
    rename_i s s'
    exfalso
    have hcur := swap_ts C (OStep.swap rl hs hc hc0) hc hc0 s.cur
    rw [if_neg (Ne.symm hc), if_pos rfl] at hcur
    have := hl.2.2 _ _ _ _ hcur
    rw [hi.curLive] at this; cases this
  | pruneHead s t v d rest h => exact .inr (.inl ⟨t, v, d, h, rfl, rfl⟩)

theorem upd_eq_collect {α : Type} (f : Nat → α) (t : Nat) (v : α) : upd f t v = Collect.upd f t v := by
  funext x; simp [upd, Collect.upd]

/-- A queued table is retired with `can_free` not yet observed. -/
theorem registered_retired {c : CSt K V} (h : CReach W C c) {t : Nat}
    (ht : t ∈ regIds c.e.base) : ∃ v d, c.o.s.ts t = .retired v d false := by
  obtain ⟨x, hx, rfl⟩ := mem_regIds.1 ht
  obtain ⟨v, d, h1, _⟩ := (creach_fi W C h).queued x hx
  exact ⟨v, d, h1⟩

/-- **The obligation at `replace_table`:** the flag of the old `current` is live (its table is
allocated) and not registered. It is used at `CStep.swap`, i.e. only when the old `current` is
not the static empty table (`replace_table` returns before `defer_by_id` for it). -/
theorem swap_obligation {c : CSt K V} (h : CReach W C c) :
    heapOf c.o.s c.o.s.cur = .live ∧ c.o.s.cur ∉ regIds c.e.base := by
  have hi := (creach_vi W C h).ts
  refine ⟨by simp [heapOf, hi.curLive, cellOf], fun hm => ?_⟩
  obtain ⟨v, d, h1⟩ := registered_retired W C h hm
  rw [hi.curLive] at h1; cases h1

/-- **The static empty table is never registered** with `collect`. -/
theorem static_not_registered {c : CSt K V} (h : CReach W C c) : 0 ∉ regIds c.e.base := by
  intro hm
  obtain ⟨v, d, h1⟩ := registered_retired W C h hm
  rw [static_never_freed W C h] at h1; cases h1

/-- **The static empty table is never deferred**: no composed step registers a
`defer_by_id` flag for it (`replace_table` returns early when the old `current` is the static
table). -/
theorem static_never_deferred {c c' : CSt K V} (hs : CStep W C c c') :
    ∀ x ∈ fl c'.e.base, x ∉ fl c.e.base → x.id ≠ 0 := by
  intro x hx hn
  rcases onlyTable W C hs x hx with h1 | ⟨rfl, _, h0⟩
  · exact absurd h1 hn
  · exact h0

/-- `replace_table`'s `defer_by_id` never trips the `debug_assert!`s. -/
theorem swap_no_assert {c : CSt K V} (h : CReach W C c) :
    Collect.Flags.assertFires c.e.base c.o.s.cur = false :=
  Collect.Flags.assert_never_fires (swap_obligation W C h).2

theorem storeAll_nil (val : Nat → Bool) : Collect.Flags.storeAll val [] = val := by
  funext i; simp [Collect.Flags.storeAll]

/-- **The obligation discharged:** every composed run is, on `collect`'s state, the table memory
as flag heap and the `can_free` cells as flag values, a run of `Collect.Flags.FReach`, the
system whose client steps carry `defer_by_id`'s obligation (`born` is its allocation-time
ghost). -/
theorem creach_freach {c : CSt K V} (h : CReach W C c) :
    ∃ born, FReach ⟨c.e.base, heapOf c.o.s, c.cell, born⟩ := by
  induction h with
  | init => exact ⟨_, .init _⟩
  | @step c c' hr hs ih =>
    obtain ⟨born, ih⟩ := ih
    have hv := creach_vi W C hr
    have hi := hv.ts
    have her := creach_ereach W C hr
    have notReg : ∀ t v d, c.o.s.ts t = .retired v d true → t ∉ regIds c.e.base := by
      intro t v d ht hm
      obtain ⟨v', d', h1⟩ := registered_retired W C hr hm
      rw [ht] at h1; cases h1
    -- `collect` steps that register nothing
    have colStep : ∀ {e' : ESt}, EStep W c.e e' → KeepFlags c.e e' →
        ∃ born', FReach ⟨e'.base, heapOf c.o.s, storeCells c.cell c.e e', born'⟩ := by
      intro e' he hk
      rcases Collect.Ev.estep_base W he with hb | hb
      · refine ⟨born, ?_⟩
        have : storeCells c.cell c.e e' = c.cell := by
          simp only [storeCells, Collect.Flags.stores, Collect.Flags.newRan, hb]
          simp [storeAll_nil]
        rw [this, hb]; exact ih
      · exact ⟨born, .step ih (FStep.col _ _ _ hb (keep_noNew hk))⟩
    cases hs with
    | tbl e f cell cell' ho' hl hcl =>
      rename_i o o'
      rcases tbl_heap C hi ho' hl with ⟨e1, ec⟩ | ⟨t, v, d, ht, e1, ec⟩ | ⟨a, ha, ec, hne, e1⟩
      · simp only at e1 ⊢; rw [e1, hcl, allocCell_eq ec]; exact ⟨born, ih⟩
      · have ht' : o.s.ts t = .retired v d true := ht
        have hst := FStep.free e.base (heapOf o.s) cell born t (by simp only [heapOf, ht']; rfl)
          (notReg t v d ht)
        have : Collect.upd (heapOf o.s) t .freed = heapOf o'.s := by
          funext x; simp only [heapOf, e1, upd, Collect.upd]; split <;> rfl
        simp only; rw [← this, hcl, allocCell_eq ec]; exact ⟨born, .step ih hst⟩
      · -- allocation at `a` (`nextId` or a freed address) by `replace_table` of the static table
        have h1 := FStep.alloc e.base (heapOf o.s) cell born a ha
        have hc : Collect.upd cell a false = cell' := by
          rw [hcl, ← ec]; unfold allocCell; rw [if_neg (by rw [ec]; exact hne), upd_eq_collect]
        simp only at e1 ⊢; rw [e1, ← hc]; exact ⟨_, .step ih h1⟩
    | pin rl f cell u hidle he hk hloc hnow => exact colStep he hk
    | unpin rl f cell u st hl hrd he hk hloc => exact colStep he hk
    | col o f cell he hk hfix => exact colStep he hk
    | swap e f cell ho' hc hc0 =>
      rename_i o o'
      have hts := swap_ts C ho' hc hc0
      have hcl : o.s.ts o.s.cur = .live := hi.curLive
      by_cases h0 : o'.s.cur = 0
      · -- the static table: only the old table's `defer_by_id`
        have h2 := FStep.deferId e.base (heapOf o.s) cell born o.s.cur
          (by simp only [heapOf, hcl]; rfl) (swap_obligation W C hr).2
        have : heapOf o.s = heapOf o'.s := by
          funext x; simp only [heapOf, hts, h0]
          split
          · rename_i ex; rw [ex, hi.stat]
          · split
            · rename_i _ e2; rw [e2, hcl]; rfl
            · rfl
        have hcell : allocCell cell o.s.cur o'.s.cur = cell := by
          funext x; by_cases ex : x = o'.s.cur
          · rw [ex, allocCell_new hc, h0]; exact hv.stat.symm
          · exact allocCell_other ex
        simp only; rw [← this, hcell]; exact ⟨_, .step ih h2⟩
      · -- a new table at `nextId` or at a freed address: allocation, then the old table's
        -- `defer_by_id`
        have ha : heapOf o.s o'.s.cur ≠ .live := by
          obtain ⟨t', T', nx, ch, hp, hs'⟩ := swap_shape C ho' hc
          have ec : o'.s.cur = t' := by rw [hs']; rfl
          rw [ec]
          rcases hp with ⟨rfl, _⟩ | ⟨rfl, _, _⟩ | ⟨ht, _⟩
          · have hfr : o.s.ts o.s.nextId = .unalloc := hi.fresh _ (Nat.le_refl _)
            simp [heapOf, hfr, cellOf]
          · exact absurd ec h0
          · simp [heapOf, ht, cellOf]
        have hne : o.s.cur ≠ o'.s.cur := Ne.symm hc
        have h1 := FStep.alloc e.base (heapOf o.s) cell born o'.s.cur ha
        have h2 := FStep.deferId e.base (Collect.upd (heapOf o.s) o'.s.cur .live)
          (Collect.upd cell o'.s.cur false) (Collect.upd born o'.s.cur e.base.now) o.s.cur
          (by simp only [Collect.upd, hne, ite_false, heapOf, hcl]; rfl)
          (swap_obligation W C hr).2
        have : Collect.upd (heapOf o.s) o'.s.cur .live = heapOf o'.s := by
          funext x; simp only [heapOf, hts, Collect.upd]
          split
          · rfl
          · split
            · rename_i e1 e2; subst e2; rw [hcl]; rfl
            · rfl
        have hc' : Collect.upd cell o'.s.cur false = allocCell cell o.s.cur o'.s.cur := by
          unfold allocCell; rw [if_neg hc, upd_eq_collect]
        simp only; rw [← this, ← hc']; exact ⟨_, .step (.step ih h1) h2⟩
    | markFree s rl e f cell t v d ht hc =>
      have : heapOf { s with ts := upd s.ts t (.retired v d true) } = heapOf s := by
        funext x; simp only [heapOf, upd]; split
        · rename_i ex; subst ex; rw [ht]; rfl
        · rfl
      simp only; rw [this]; exact ⟨born, ih⟩

/-- **`can_free` is `true` exactly when `collect` stored it** (`Collect.Flags.flag_true_iff` on
the table's allocation): for an allocated table, the cell holds `true` iff some `defer_by_id`
registration of it since its allocation is in `collect`'s `ran`. -/
theorem can_free_iff_stored {c : CSt K V} (h : CReach W C c) :
    ∃ born : Nat → Nat, ∀ t, heapOf c.o.s t = .live →
      (c.cell t = true ↔ ∃ x ∈ Collect.Flags.ranB c.e.base, x.id = t ∧ born t ≤ x.time) := by
  obtain ⟨born, hf⟩ := creach_freach W C h
  exact ⟨born, fun t ht => Collect.Flags.flag_true_iff hf ht⟩

/-- No table is registered twice. -/
theorem flags_no_dup {c : CSt K V} (h : CReach W C c) : (regIds c.e.base).Nodup := by
  obtain ⟨_, hf⟩ := creach_freach W C h
  exact Collect.Flags.freach_no_dup hf

/-- **A table is freed only after `collect` stored its flag** (and `prune_tables` read the
cell as `true`), and it is then no longer registered. -/
theorem freed_after_stored {c c' : CSt K V} (h : CReach W C c)
    (hs : CStep W C c c') {t : Nat} (h1 : c.o.s.ts t ≠ .freed) (h2 : c'.o.s.ts t = .freed) :
    ∃ v d, c.o.s.ts t = .retired v d true ∧ c.cell t = true ∧ flagCb c.f t d ∈ c.e.base.ran ∧
      t ∉ regIds c.e.base := by
  have hv := creach_vi W C h
  have hi := hv.ts
  have hf := creach_fi W C h
  have key : ∃ v d, c.o.s.ts t = .retired v d true := by
    cases hs with
    | tbl e f cell cell' ho hl hcl =>
      rename_i o o'
      rcases tbl_heap C hi ho hl with ⟨e1, _⟩ | ⟨t', v, d, ht, e1, _⟩ | ⟨_, _, _, _, e1⟩
      · have h2' : o'.s.ts t = .freed := h2
        have h1' : o.s.ts t ≠ .freed := h1
        have : cellOf (o'.s.ts t) = cellOf (o.s.ts t) := congrFun e1 t
        rw [h2'] at this
        cases hx : o.s.ts t <;> rw [hx] at this h1' <;> simp [cellOf] at this h1'
      · simp only at e1 h1 h2 ⊢
        rw [e1] at h2
        by_cases ex : t = t'
        · subst ex; exact ⟨v, d, ht⟩
        · rw [upd_other _ _ _ _ ex] at h2; exact absurd h2 h1
      · exfalso
        have h2' : o'.s.ts t = .freed := h2
        have h1' : o.s.ts t ≠ .freed := h1
        have := congrFun e1 t
        simp only [heapOf, Collect.upd, h2'] at this
        split at this
        · cases this
        · cases hx : o.s.ts t <;> rw [hx] at this h1' <;> simp [cellOf] at this h1'
    | pin => exact absurd h2 h1
    | unpin => exact absurd h2 h1
    | col => exact absurd h2 h1
    | swap e f cell ho hc hc0 =>
      rw [swap_ts C ho hc hc0] at h2
      split at h2
      · cases h2
      · split at h2
        · cases h2
        · exact absurd h2 h1
    | markFree s rl e f cell t' v d ht hc =>
      simp only [upd] at h1 h2; split at h2
      · cases h2
      · exact absurd h2 h1
  obtain ⟨v, d, ht⟩ := key
  refine ⟨v, d, ht, hv.obs t v d ht, hf.stored t v d ht, fun hm => ?_⟩
  obtain ⟨v', d', h3⟩ := registered_retired W C h hm
  rw [ht] at h3; cases h3

/-- **`collect` never writes a freed (or unallocated) table's `can_free`.** Every pointer a
`collect` step stores `true` through is a retired, allocated table whose `can_free` has not been
observed yet, and each is stored at most once. -/
theorem collect_store_live {c : CSt K V} (h : CReach W C c)
    {b' : Collect.St} (hs : Collect.Step c.e.base b') :
    (stores c.e.base b').Nodup ∧ ∀ i ∈ stores c.e.base b',
      heapOf c.o.s i = .live ∧ ∃ v d, c.o.s.ts i = .retired v d false := by
  obtain ⟨_, hf⟩ := creach_freach W C h
  obtain ⟨hn, hw⟩ := Collect.Flags.no_write_after_free hf hs
  refine ⟨hn, fun i hi => ⟨(hw i hi).1, registered_retired W C h (hw i hi).2.1⟩⟩

end Composed
end SyncTable
