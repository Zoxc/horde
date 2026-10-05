import Collect.Model

/-!
# `busy_count` and `threads.len()`

`CInv s`: the keys of `threads` form a finite duplicate-free list `L`, `len` is its length and
`busy` (`Collector::busy_count`) is the number of keys mapped to `Busy`. Preservation by the
collector operations is proved here, and by every step in `Safety.lean` (field `Inv.cnt`).
-/

namespace Collect

/-- Number of `busy` entries of `th` among the keys `L`. -/
def countBusy (th : Tid → Option TS) (L : List Tid) : Nat :=
  (L.filter (fun u => th u = some .busy)).length

/-- Counter invariant. -/
def CInv (s : St) : Prop :=
  ∃ L : List Tid, L.Nodup ∧ (∀ u, u ∈ L ↔ s.threads u ≠ none) ∧ s.len = L.length ∧
    s.busy = countBusy s.threads L

theorem countBusy_ext {th th' : Tid → Option TS} {L : List Tid}
    (h : ∀ u ∈ L, (th u = some .busy ↔ th' u = some .busy)) :
    countBusy th L = countBusy th' L := by
  unfold countBusy; congr 1
  apply List.filter_congr; intro u hu; simp [h u hu]

theorem countBusy_upd_notMem {th : Tid → Option TS} {L : List Tid} {t v} (ht : t ∉ L) :
    countBusy (upd th t v) L = countBusy th L :=
  countBusy_ext fun u hu => by
    have : u ≠ t := fun h => ht (h ▸ hu)
    simp [this]

/-- Changing the value at a key `t ∈ L`. -/
theorem countBusy_upd {th : Tid → Option TS} {L : List Tid} {t v} (hn : L.Nodup) (ht : t ∈ L) :
    countBusy (upd th t v) L + (if th t = some .busy then 1 else 0) =
      countBusy th L + (if v = some .busy then 1 else 0) := by
  induction L with
  | nil => simp at ht
  | cons a L ih =>
    have ⟨ha, hn'⟩ := List.nodup_cons.1 hn
    rcases List.mem_cons.1 ht with rfl | ht'
    · have e := countBusy_upd_notMem (th := th) (v := v) ha
      unfold countBusy at e ⊢
      simp only [List.filter_cons, upd_same]
      by_cases h1 : th t = some .busy <;> by_cases h2 : v = some .busy <;> simp_all
    · have hat : a ≠ t := fun h => ha (h ▸ ht')
      have := ih hn' ht'
      unfold countBusy at this ⊢
      simp only [List.filter_cons, upd_other _ _ _ _ hat]
      split <;> simp_all <;> omega

theorem countBusy_le (th : Tid → Option TS) (L : List Tid) : countBusy th L ≤ L.length :=
  List.length_filter_le _ _

theorem countBusy_pos {th : Tid → Option TS} {L : List Tid} {t} (ht : t ∈ L)
    (hb : th t = some .busy) : 0 < countBusy th L := by
  unfold countBusy
  exact List.length_pos_of_mem (List.mem_filter.2 ⟨ht, by simp [hb]⟩)

theorem countBusy_zero {th : Tid → Option TS} {L : List Tid} (h : countBusy th L = 0) :
    ∀ u ∈ L, th u ≠ some .busy := fun u hu hb => by
  have := countBusy_pos hu hb; omega

theorem countBusy_all {th : Tid → Option TS} {L : List Tid} (h : ∀ u ∈ L, th u = some .busy) :
    countBusy th L = L.length := by
  unfold countBusy; rw [List.filter_eq_self.2]; intro u hu; simp [h u hu]

theorem length_filter_ne {L : List Tid} {t} (hn : L.Nodup) (ht : t ∈ L) :
    (L.filter (fun u => u ≠ t)).length = L.length - 1 := by
  induction L with
  | nil => simp at ht
  | cons a L ih =>
    have ⟨ha, hn'⟩ := List.nodup_cons.1 hn
    rcases List.mem_cons.1 ht with rfl | ht'
    · simp only [List.filter_cons, ne_eq, not_true_eq_false, decide_false, List.length_cons]
      rw [List.filter_eq_self.2]
      · simp
      · intro u hu; simp; rintro rfl; exact ha hu
    · have hat : a ≠ t := fun h => ha (h ▸ ht')
      have := ih hn' ht'
      have hp := List.length_pos_of_mem ht'
      simp [hat] at this ⊢; omega

/-! ## Basic consequences -/

section
variable {s : St} (h : CInv s)
include h

/-- **`busy_count == 0` iff there is no `Busy` entry.** -/
theorem busy_zero_iff : s.busy = 0 ↔ noBusy s.threads := by
  obtain ⟨L, -, hm, -, hb⟩ := h
  constructor
  · intro h0 u hu
    have hL : u ∈ L := (hm u).2 (by simp [hu])
    exact countBusy_zero (hb ▸ h0) u hL hu
  · intro hnb; rw [hb]; unfold countBusy
    rw [List.length_eq_zero_iff, List.filter_eq_nil_iff]; intro u _; simp [hnb u]

/-- `busy_count ≤ threads.len()`. -/
theorem busy_le_len : s.busy ≤ s.len := by
  obtain ⟨L, -, -, hl, hb⟩ := h; rw [hb, hl]; exact countBusy_le _ _

theorem busy_pos {t} (hb : s.threads t = some .busy) : 0 < s.busy := by
  obtain ⟨L, -, hm, -, hc⟩ := h; rw [hc]; exact countBusy_pos ((hm t).2 (by simp [hb])) hb

theorem len_pos {t} (hb : s.threads t ≠ none) : 0 < s.len := by
  obtain ⟨L, -, hm, hl, -⟩ := h; rw [hl]; exact List.length_pos_of_mem ((hm t).2 hb)

/-- `threads.len() == 0` iff `threads.is_empty()`. -/
theorem len_zero_iff : s.len = 0 ↔ allNone s.threads := by
  obtain ⟨L, -, hm, hl, -⟩ := h
  rw [hl, List.length_eq_zero_iff]
  constructor
  · rintro rfl u; have := hm u; simpa using this
  · intro ha; rw [List.eq_nil_iff_forall_not_mem]; intro u hu; exact (hm u).1 hu (ha u)

end

/-- Decrementing `busy_count` for the `Busy` entry `t` (which becomes `v`, not `Busy`) gives 0
iff `t` was the last `Busy` entry. -/
theorem busy_last_iff {s : St} {t v} (h : CInv s) (hb : s.threads t = some .busy)
    (hv : v ≠ some .busy) : s.busy - 1 = 0 ↔ noBusy (upd s.threads t v) := by
  obtain ⟨L, a, b, -, d⟩ := h
  have htL : t ∈ L := (b t).2 (by simp [hb])
  have hup := countBusy_upd (v := v) (th := s.threads) a htL
  simp [hb, hv] at hup
  constructor
  · intro h0 u hu
    by_cases huL : u ∈ L
    · exact countBusy_zero (by omega) u huL hu
    · have hut : u ≠ t := fun e => huL (e ▸ htL)
      have : s.threads u = none := Classical.byContradiction fun hn => huL ((b u).2 hn)
      simp [hut, this] at hu
  · intro hnb
    have : countBusy (upd s.threads t v) L = 0 := by
      unfold countBusy; rw [List.length_eq_zero_iff, List.filter_eq_nil_iff]
      intro u _; simp [hnb u]
    omega

/-! ## Preservation by the collector operations -/

theorem cinv_of {s s' : St} (h : CInv s) (ht : s'.threads = s.threads) (hl : s'.len = s.len)
    (hb : s'.busy = s.busy) : CInv s' := by
  obtain ⟨L, a, b, c, d⟩ := h; exact ⟨L, a, by rw [ht]; exact b, by rw [hl]; exact c,
    by rw [hb, ht]; exact d⟩

theorem completeEpoch_cinv {s : St} (h : CInv s) : CInv (completeEpoch s) := by
  unfold completeEpoch; split
  · exact cinv_of h rfl rfl rfl
  · obtain ⟨L, a, b, c, d⟩ := h
    refine ⟨L, a, ?_, c, ?_⟩
    · intro u; rw [b u]; cases hh : s.threads u <;> simp [hh]
    · simp only; rw [c, countBusy_all]; intro u hu
      have := (b u).1 hu; cases hh : s.threads u <;> simp_all

/-- `markQuiet` on a `Busy` entry. -/
theorem markQuiet_cinv {s : St} {t} (h : CInv s) (hb : s.threads t = some .busy) :
    CInv (markQuiet t s) := by
  have h1 : CInv { s with threads := upd s.threads t (some .quiet), busy := s.busy - 1 } := by
    obtain ⟨L, a, b, c, d⟩ := h
    have htL : t ∈ L := (b t).2 (by simp [hb])
    refine ⟨L, a, ?_, c, ?_⟩
    · intro u; by_cases hu : u = t
      · subst hu; simp [htL]
      · simp [hu, b u]
    · have := countBusy_upd (v := some .quiet) (th := s.threads) a htL
      simp [hb] at this; simp only; omega
  unfold markQuiet; split
  · exact completeEpoch_cinv h1
  · exact h1

theorem takePending_cinv {s : St} (h : CInv s) : CInv (takePending s).1 := cinv_of h rfl rfl rfl

theorem markQuiet_threads_ne {s : St} {t u} (hb : s.threads u ≠ none) :
    (markQuiet t s).threads u ≠ none := by
  unfold markQuiet; split
  · unfold completeEpoch; split
    · simp only; by_cases hu : u = t <;> simp [hu, hb]
    · simp only; by_cases hu : u = t <;> simp [hu, hb]
  · simp only; by_cases hu : u = t <;> simp [hu, hb]

theorem quiet_cinv (t : Tid) : ∀ (fuel : Nat) (s : St), CInv s → s.threads t ≠ none →
    CInv (quiet t fuel s).1
  | 0, _, h, _ => h
  | fuel + 1, s, h, ht => by
    simp only [quiet]
    split
    · exact takePending_cinv h
    · rename_i hb; have hb : s.threads t = some .busy := by simpa using hb
      have h1 := takePending_cinv (markQuiet_cinv h hb)
      split
      · exact quiet_cinv t fuel _ h1 (markQuiet_threads_ne ht)
      · exact h1

theorem collectUnreg_cinv {s : St} (h : CInv s) : CInv (collectUnreg s).1 := by
  unfold collectUnreg; split <;> exact cinv_of h rfl rfl rfl

theorem startCollect_cinv {t w} {r : St × List Cb} (h : CInv r.1) : CInv (startCollect t w r) :=
  cinv_of h rfl rfl rfl

/-- `unregister` of a key that is present. -/
theorem unregister_cinv {s : St} {t} (h : CInv s) (ht : s.threads t ≠ none) :
    CInv (unregister s t) := by
  obtain ⟨L, a, b, c, d⟩ := h
  have htL : t ∈ L := (b t).2 ht
  have hlen := length_filter_ne a htL
  have hmem : ∀ u, u ∈ L.filter (fun u => u ≠ t) ↔ upd s.threads t none u ≠ none := by
    intro u; by_cases hu : u = t
    · subst hu; simp
    · simp [hu, b u]
  have hcnt : countBusy (upd s.threads t none) (L.filter (fun u => u ≠ t)) =
      countBusy (upd s.threads t none) L := by
    unfold countBusy; rw [List.filter_filter]; congr 1; apply List.filter_congr
    intro u _; by_cases hu : u = t
    · subst hu; simp
    · simp [hu]
  have hup := countBusy_upd (v := none) (th := s.threads) a htL
  have hnd : (L.filter (fun u => u ≠ t)).Nodup := a.filter _
  dsimp only [unregister]
  split
  · rename_i hb
    have h1 : CInv { s with threads := upd s.threads t none, len := s.len - 1,
                            busy := s.busy - 1 } := by
      refine ⟨_, hnd, hmem, by simp only; omega, ?_⟩
      simp only; rw [hcnt]; simp [hb] at hup; omega
    split
    · exact completeEpoch_cinv h1
    · exact h1
  · rename_i hb
    have h1 : CInv { s with threads := upd s.threads t none, len := s.len - 1 } := by
      refine ⟨_, hnd, hmem, by simp only; omega, ?_⟩
      simp only; rw [hcnt]; simp [hb] at hup; omega
    split
    · exact completeEpoch_cinv h1
    · exact h1

/-- `register` (`Step.pinRegister`) of a key that is absent. -/
theorem register_cinv {s : St} {t} (h : CInv s) (ht : s.threads t = none) :
    CInv (register s t) := by
  obtain ⟨L, a, b, c, d⟩ := h
  have htL : t ∉ L := fun hm => (b t).1 hm ht
  refine ⟨t :: L, List.nodup_cons.2 ⟨htL, a⟩, ?_, by simp [register, c], ?_⟩
  · intro u; by_cases hu : u = t
    · subst hu; simp [register]
    · simp [register, hu, b u]
  · simp only [register, countBusy, List.filter_cons, upd_same]
    simp only [countBusy] at d
    have := countBusy_upd_notMem (th := s.threads) (v := some (if s.busy = 0 then .busy else .quiet)) htL
    simp only [countBusy] at this
    by_cases h0 : s.busy = 0
    · simp only [h0, ite_true] at this ⊢; simp [this, ← d, h0]
    · simp only [h0, ite_false] at this ⊢; simp [this, ← d]

/-- Every `busy_count -= 1` executed by `quiet` (including its recursive call) starts from a
positive counter. Checked for every possible nested call, whether it is taken or not. -/
def QuietOk (t : Tid) : Nat → St → Prop
  | 0, _ => True
  | fuel + 1, s => s.threads t = some .busy →
      0 < s.busy ∧ QuietOk t fuel (takePending (markQuiet t s)).1

theorem quietOk (t : Tid) : ∀ (fuel : Nat) (s : St), CInv s → QuietOk t fuel s
  | 0, _, _ => trivial
  | fuel + 1, _s, h => fun hb =>
    ⟨busy_pos h hb, quietOk t fuel _ (takePending_cinv (markQuiet_cinv h hb))⟩

theorem cinv_init : CInv init := ⟨[], List.nodup_nil, by simp [init], rfl, rfl⟩

end Collect
