import Collect.Flags
import Collect.Events

/-!
# `defer_by_id` flag memory on the primary model (property 13)

`EFSt` is the primary-model state `Ev.ESt` plus the flag heap, values and allocation-time ghost
of `Flags.FSt`. `EFStep` pairs every `Ev.EStep` with the flag-memory effect and client
obligation of `Flags.FStep`: a `collect`-side step (`col`, any `EStep` that registers no flag;
stutter steps store nothing and leave the flags alone), `defer_by_id` (`deferId`, an `EStep`
whose base effect is `deferIdSt`, under the obligation), and the client steps `alloc`/`free`.
`efreach_freach` projects every run onto `Flags.FReach` (via `Ev.estep_base`), and every
property-13 result is restated here.
-/

namespace Collect
namespace EFlags

open Ev Flags

variable {W : Nat}

/-- Primary-model state plus the flag memory. -/
structure EFSt where
  e : ESt
  heap : Nat → Cell
  val : Nat → Bool
  born : Nat → Nat

/-- The projection onto the base-model flag state. -/
def EFSt.proj (f : EFSt) : FSt := ⟨f.e.base, f.heap, f.val, f.born⟩

variable (W) in
/-- `Flags.FStep` over `Ev.EStep`. The client obligation is the premises of `deferId`/`free`. -/
inductive EFStep : EFSt → EFSt → Prop
  /-- any primary step that registers no flag (including stutters) -/
  | col {e e' : ESt} (heap : Nat → Cell) (val : Nat → Bool) (born : Nat → Nat) : EStep W e e' →
      (∀ x ∈ fl e'.base, x ∈ fl e.base) →
      EFStep ⟨e, heap, val, born⟩ ⟨e', heap, storeAll val (stores e.base e'.base), born⟩
  /-- `defer_by_id(i)` under the obligation -/
  | deferId {e e' : ESt} (heap : Nat → Cell) (val : Nat → Bool) (born : Nat → Nat) (i : Nat) :
      EStep W e e' → e'.base = deferIdSt e.base i → heap i = .live → i ∉ regIds e.base →
      EFStep ⟨e, heap, val, born⟩ ⟨e', heap, val, born⟩
  | alloc (e : ESt) (heap : Nat → Cell) (val : Nat → Bool) (born : Nat → Nat) (i : Nat) :
      heap i ≠ .live →
      EFStep ⟨e, heap, val, born⟩ ⟨e, upd heap i .live, upd val i false, upd born i e.base.now⟩
  /-- deallocating a flag, under the obligation -/
  | free (e : ESt) (heap : Nat → Cell) (val : Nat → Bool) (born : Nat → Nat) (i : Nat) :
      heap i = .live → i ∉ regIds e.base →
      EFStep ⟨e, heap, val, born⟩ ⟨e, upd heap i .freed, val, born⟩
  /-- writes by other owners to memory that is not a live flag (`FStep.envWrite`) -/
  | envWrite (e : ESt) (heap : Nat → Cell) (val val' : Nat → Bool) (born : Nat → Nat) :
      (∀ i, heap i = .live → val' i = val i) →
      EFStep ⟨e, heap, val, born⟩ ⟨e, heap, val', born⟩

variable (W) in
inductive EFReach : EFSt → Prop
  | init (heap : Nat → Cell) : EFReach ⟨einit, heap, fun _ => false, fun _ => 0⟩
  | step {f f'} : EFReach f → EFStep W f f' → EFReach f'

/-- Every flag-memory run is a run of the primary model. -/
theorem efreach_ereach {f : EFSt} (h : EFReach W f) : EReach W f.e := by
  induction h with
  | init => exact .init
  | step _ hs ih =>
    cases hs with
    | col _ _ _ hs _ => exact .step ih hs
    | deferId _ _ _ _ hs => exact .step ih hs
    | alloc => exact ih
    | free => exact ih
    | envWrite => exact ih

theorem stores_self (c : St) : stores c c = [] := by simp [stores, newRan]

/-- **Projection:** every primary-model flag run is a base-model flag run. -/
theorem efreach_freach {f : EFSt} (h : EFReach W f) : FReach f.proj := by
  induction h with
  | init => exact .init _
  | step _ hs ih =>
    cases hs with
    | @col e e' heap val born hs hno =>
      rcases estep_base W hs with hb | hb
      · have : storeAll val (stores e.base e'.base) = val := by
          rw [hb, stores_self]; funext i; simp [storeAll]
        show FReach ⟨e'.base, heap, storeAll val (stores e.base e'.base), born⟩
        rw [this, hb]; exact ih
      · exact .step ih (.col heap val born hb hno)
    | @deferId e e' heap val born i _ hb hl hn =>
      simp only [EFSt.proj, hb] at ih ⊢; exact .step ih (.deferId _ heap val born i hl hn)
    | alloc _ _ _ _ _ hi => exact .step ih (.alloc _ _ _ _ _ hi)
    | free _ _ _ _ _ hi hn => exact .step ih (.free _ _ _ _ _ hi hn)
    | envWrite _ _ _ _ _ hw => exact .step ih (.envWrite _ _ _ _ _ hw)

/-! ## Property 13 on the primary model -/

/-- (a) `collect` writes only inside the window (unconditional). -/
theorem stores_window {e e' : ESt} (h : EReach W e) (hs : EStep W e e') :
    (∃ i, e'.base = deferIdSt e.base i ∧ stores e.base e'.base = [] ∧
        regIds e'.base = regIds e.base ++ [i]) ∨
    ∃ l, (stores e.base e'.base ++ regIds e'.base).Perm l ∧ l.Sublist (regIds e.base) := by
  rcases estep_base W hs with hb | hb
  · exact .inr ⟨regIds e.base, by simp [hb, stores_self], .refl _⟩
  · exact Flags.stores_window (ereach_base W h) hb

theorem store_registered {e e' : ESt} (h : EReach W e) (hs : EStep W e e') {i : Nat}
    (hi : i ∈ stores e.base e'.base) : i ∈ regIds e.base := by
  rcases estep_base W hs with hb | hb
  · simp [hb, stores_self] at hi
  · exact Flags.store_registered (ereach_base W h) hb hi

/-- `cancel_by_ids` on the primary model unregisters the cancelled ids. -/
theorem cancel_unregisters (e : ESt) (ids' : List Nat) {i : Nat} (hi : i ∈ ids') :
    ∃ e', EStep W e e' ∧ i ∉ regIds e'.base :=
  ⟨_, .cancel e ids', Flags.cancel_unregisters e.base ids' hi⟩

theorem step_cover {e e' : ESt} (h : EReach W e) (hs : EStep W e e') :
    (∃ i, e'.base = deferIdSt e.base i) ∨ ∀ x ∈ fl e'.base, x ∈ fl e.base := by
  rcases estep_base W hs with hb | hb
  · exact .inr fun x hx => hb ▸ hx
  · exact Flags.step_cover (ereach_base W h) hb

/-- (b) The `debug_assert!`s fire exactly when the pointer is registered. -/
theorem assertFires_iff (e : ESt) (i : Nat) : assertFires e.base i = true ↔ i ∈ regIds e.base :=
  Flags.assertFires_iff e.base i

/-- (c) Under the obligation: registrations are distinct and live. -/
theorem efreach_inv {f : EFSt} (h : EFReach W f) : FInv f.proj := freach_inv (efreach_freach h)

theorem no_write_after_free {f : EFSt} (h : EFReach W f) {e' : ESt} (hs : EStep W f.e e') :
    (stores f.e.base e'.base).Nodup ∧
    ∀ i ∈ stores f.e.base e'.base, f.heap i = .live ∧ i ∈ regIds f.e.base ∧ i ∉ regIds e'.base := by
  rcases estep_base W hs with hb | hb
  · simp [hb, stores_self]
  · exact Flags.no_write_after_free (efreach_freach h) (f := f.proj) hb

/-- The `debug_assert!`s never fire at a `defer_by_id(i)` step of a flag-memory run. -/
theorem assert_never_fires {f f' : EFSt} (h : EFReach W f) (hs : EFStep W f f') {i : Nat}
    (hd : f'.e.base = deferIdSt f.e.base i) : assertFires f.e.base i = false := by
  cases hs with
  | @col e e' _ _ _ _ hno =>
    exfalso
    simp only at hd
    have hm := hno ⟨i, e.base.now, true⟩ (by rw [hd]; simp [fl, flat, deferIdSt])
    have := (reachable_cbInv (ereach_base W (efreach_ereach h))).2.2 _ (List.mem_append_left _ hm)
    simp at this
  | deferId _ _ _ j _ hb _ hni =>
    simp only at hd hb ⊢
    have : i = j := by
      rw [hb] at hd; simp [deferIdSt] at hd; exact hd.symm
    subst this; exact Flags.assert_never_fires hni
  | alloc => simp only at hd; have := congrArg St.now hd; simp [deferIdSt] at this
  | free => simp only at hd; have := congrArg St.now hd; simp [deferIdSt] at this
  | envWrite => simp only at hd; have := congrArg St.now hd; simp [deferIdSt] at this

theorem efreach_no_dup {f : EFSt} (h : EFReach W f) : (regIds f.e.base).Nodup :=
  freach_no_dup (efreach_freach h)

/-- (d) Flag values. -/
theorem efreach_vinv {f : EFSt} (h : EFReach W f) : VInv f.proj := freach_vinv (efreach_freach h)

theorem flag_true_iff {f : EFSt} (h : EFReach W f) {i : Nat} (hi : f.heap i = .live) :
    f.val i = true ↔ ∃ x ∈ ranB f.e.base, x.id = i ∧ f.born i ≤ x.time :=
  Flags.flag_true_iff (efreach_freach h) (f := f.proj) hi

theorem only_collect_writes_true {f f' : EFSt} (hs : EFStep W f f') {i : Nat}
    (hl : f.heap i = .live) (h0 : f.val i = false) (h1 : f'.val i = true) :
    EStep W f.e f'.e ∧ Step f.e.base f'.e.base ∧ i ∈ stores f.e.base f'.e.base := by
  cases hs with
  | col heap val born hst _ =>
    simp only at h0 h1 ⊢
    rcases storeAll_true.1 h1 with h | h
    · rw [h0] at h; cases h
    · refine ⟨hst, ?_, h⟩
      rcases estep_base W hst with hb | hb
      · simp [hb, stores_self] at h
      · exact hb
  | deferId => simp only at h0 h1; rw [h0] at h1; cases h1
  | alloc e heap val born j _ =>
    simp only at h0 h1
    by_cases e : i = j
    · subst e; simp at h1
    · rw [upd_other _ _ _ _ e, h0] at h1; cases h1
  | free => simp only at h0 h1; rw [h0] at h1; cases h1
  | envWrite e heap val val' born hw =>
    simp only at h0 h1 hl; rw [hw i hl, h0] at h1; cases h1

theorem registered_once_false {f : EFSt} (h : EFReach W f) {x : Cb} (hx : x ∈ fl f.e.base)
    (honly : ∀ y ∈ ranB f.e.base, y.id = x.id → y.time < f.born x.id) : f.val x.id = false :=
  Flags.registered_once_false (efreach_freach h) (f := f.proj) hx honly

end EFlags
end Collect
