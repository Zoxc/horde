import Collect.Fair

/-!
# Fair liveness, bound (variant 4)

With registration stable, a queued closure is taken into a to-do list within two *rounds*.
A round `[a, b)` is an interval in which every thread registered in the stable suffix
completes a slow-path `collect` (`Round`). See MAPPING.md, section "Fair liveness".

Main results:
* `round_level`: a round lowers the level (`Lv`) of a queued closure, or takes it.
* `round_prev`: a closure in `previous` or `pending` at the start of a round is taken in it.
* `bound`: a closure queued at `n0` is taken by the end of the second round after `n0`.

The counting is per round, not per thread: "every registered thread completes two slow-path
collects after the defer" is not enough. A thread that is already `Quiet` may do both of its
collects (no-ops) before the epoch that started before the defer completes.
-/

namespace Collect
namespace Fair

/-- `[a, b)` is a round: every thread registered at `N0` completes a slow-path `collect` from
`Registered` at some step in `[a, b)`. -/
def Round (ex : Nat → St) (N0 a b : Nat) : Prop :=
  ∀ t, ((ex N0).threads t).isSome → ∃ m, a ≤ m ∧ m < b ∧ CollectsAt ex t m

/-! ## Helper lemmas -/

theorem stable_step {ex : Nat → St} {N0 : Nat} (hst : StableFrom ex N0) {j : Nat}
    (hj : N0 ≤ j) : ∀ u, ((ex (j + 1)).threads u).isSome = ((ex j).threads u).isSome :=
  fun u => (stable_at hst _ (by omega) u).trans (stable_at hst _ hj u).symm

/-- `Shr` along every step of `[a, b)` gives `Shr` between any two points of `[a, b]`. -/
theorem shr_chain {ex : Nat → St} {a b : Nat}
    (h : ∀ j, a ≤ j → j < b → Shr (ex j).threads (ex (j + 1)).threads) :
    ∀ i j, a ≤ i → i ≤ j → j ≤ b → Shr (ex i).threads (ex j).threads := by
  intro i j hi hij
  refine ge_induction (P := fun j => j ≤ b → Shr (ex i).threads (ex j).threads)
    (fun _ _ h => h) (fun j hj ih hjb => ?_) j hij
  exact fun u hu => ih (by omega) u (h j (by omega) (by omega) u hu)

/-- A round cannot keep the `Busy` set shrinking at every step while each `Busy` thread's
collect makes it non-`Busy`: the thread `Busy` at the end (`reachable_hasBusy`) was `Busy`
throughout, also right after its own collect. -/
theorem round_busy_false {ex : Nat → St} (hex : Exec ex) (hr : Reachable (ex 0)) {N0 : Nat}
    (hst : StableFrom ex N0) (hne : ∃ t, ((ex N0).threads t).isSome) {a b : Nat}
    (ha : N0 ≤ a) (hR : Round ex N0 a b)
    (hshr : ∀ j, a ≤ j → j < b → Shr (ex j).threads (ex (j + 1)).threads)
    (hq : ∀ t m, a ≤ m → m < b → CollectsAt ex t m → (ex m).threads t = some .busy →
      (ex (m + 1)).threads t ≠ some .busy) : False := by
  have ch := shr_chain hshr
  obtain ⟨u0, hu0⟩ := hne
  have hab : a ≤ b := by obtain ⟨m, h1, h2, -⟩ := hR u0 hu0; omega
  obtain ⟨w, hw⟩ := reachable_hasBusy (Exec.reach hex hr b)
    ⟨u0, by
      have := stable_at hst b (by omega) u0; rw [hu0] at this
      intro h; rw [h] at this; simp at this⟩
  have hwN : ((ex N0).threads w).isSome := by rw [← stable_at hst b (by omega) w, hw]; rfl
  obtain ⟨m, hm1, hm2, hcol⟩ := hR w hwN
  exact hq w m hm1 hm2 hcol (ch m b hm1 (by omega) (Nat.le_refl _) w hw)
    (ch (m + 1) b (by omega) (by omega) (Nat.le_refl _) w hw)

/-- `step_level` for `c ∈ previous`: in the stable suffix `c` is taken or stays in `previous`
while the `Busy` set only shrinks (an epoch completed inside `quiet` takes `previous`). -/
theorem step_prev {c : Cb} (hid : c.byId = false) {s s' : St} (hr : Reachable s)
    (hs : Step s s') (hst : ∀ u, (s'.threads u).isSome = (s.threads u).isSome)
    (h : c ∈ s.previous) : Taken c s' ∨ (c ∈ s'.previous ∧ Shr s.threads s'.threads) := by
  cases hs with
  | pinRegister t hl =>
    have := hst t; simp [register, (threads_consistent hr t).1 hl] at this
  | release t hl =>
    have := hst t
    rw [unregister_isSome] at this
    simp at this; exact absurd this ((threads_consistent hr t).2 hl)
  | collectReg t _ =>
    rw [quietRust_eq]
    rcases (quiet_epoch t 1 s c).2 with ⟨hs, -, hprev, -⟩ | ⟨h1, -⟩
    · exact .inr ⟨by simp [startCollect, hprev, h], by simpa [startCollect] using hs⟩
    · exact .inl (taken_startCollect hid t true _ (h1 h))
  | collectUnreg t _ =>
    by_cases ha : allNone s.threads
    · exact .inl (collectUnreg_taken hid t s (.inr ⟨ha, by simp [bufs, h]⟩))
    · exact .inr ⟨by simp [collectUnreg, ha, startCollect, h],
        by simp only [collectUnreg, ha, ite_false, startCollect]; exact fun _ h => h⟩
  | defer => exact .inr ⟨by simp [h], fun _ h => h⟩
  | cancel ids => exact .inr ⟨by simpa [cancelList, hid] using h, fun _ h => h⟩
  | pinOuter => exact .inr ⟨h, fun _ h => h⟩
  | pinNest => exact .inr ⟨h, fun _ h => h⟩
  | unpinNest => exact .inr ⟨h, fun _ h => h⟩
  | unpinOuter => exact .inr ⟨h, fun _ h => h⟩
  | runOne => exact .inr ⟨h, fun _ h => h⟩
  | finish => exact .inr ⟨h, fun _ h => h⟩

/-! ## Rounds -/

/-- **A round lowers the level.** In the stable suffix with a registered thread, if `c` is at
level `k ≥ 1` at the start of a round `[a, b)`, then at some point of `[a, b]` it is taken or
at level `k - 1`. Otherwise every step keeps the level and shrinks the `Busy` set
(`step_level`), and each `Busy` thread's collect makes it `Quiet` (`collect_level`), so the
`Busy` set at `b` would be empty (`round_busy_false`); that is, the round contains an epoch
completion. -/
theorem round_level {ex : Nat → St} (hex : Exec ex) (hr : Reachable (ex 0)) {N0 : Nat}
    (hst : StableFrom ex N0) (hne : ∃ t, ((ex N0).threads t).isSome) {c : Cb}
    (hid : c.byId = false) {k : Nat} {a b : Nat} (ha : N0 ≤ a) (hR : Round ex N0 a b)
    (hL : Lv c k (ex a)) :
    ∃ j, a ≤ j ∧ j ≤ b ∧ (Taken c (ex j) ∨ (k ≠ 0 ∧ Lv c (k - 1) (ex j))) := by
  apply Classical.byContradiction; intro H
  have H' : ∀ j, a ≤ j → j ≤ b → ¬ Taken c (ex j) ∧ ¬ (k ≠ 0 ∧ Lv c (k - 1) (ex j)) :=
    fun j h1 h2 => ⟨fun h => H ⟨j, h1, h2, .inl h⟩, fun h => H ⟨j, h1, h2, .inr h⟩⟩
  have pers : ∀ j, a ≤ j → j ≤ b → Lv c k (ex j) := by
    refine ge_induction (P := fun j => j ≤ b → Lv c k (ex j)) (fun _ => hL)
      (fun j hj ih hjb => ?_)
    have ih := ih (by omega)
    rcases hex j with hs | hs
    · rcases step_level hid k (Exec.reach hex hr _) hs (stable_step hst (by omega)) ih with
        h | h | ⟨h, -⟩
      · exact absurd h (H' _ (by omega) hjb).1
      · exact absurd h (H' _ (by omega) hjb).2
      · exact h
    · rw [hs]; exact ih
  refine round_busy_false hex hr hst hne ha hR (fun j hj hjb => ?_)
    (fun t m hm hmb hcol _ => ?_)
  · rcases hex j with hs | hs
    · rcases step_level hid k (Exec.reach hex hr _) hs (stable_step hst (by omega))
        (pers j hj (by omega)) with h | h | ⟨-, h⟩
      · exact absurd h (H' _ (by omega) (by omega)).1
      · exact absurd h (H' _ (by omega) (by omega)).2
      · exact h
    · rw [hs]; exact fun _ h => h
  · have := collect_level hid k (ex m) t (pers m hm (by omega))
    rw [← hcol.2] at this
    rcases this with h | h | ⟨-, -, -, h⟩
    · exact absurd h (H' _ (by omega) (by omega)).1
    · exact absurd h (H' _ (by omega) (by omega)).2
    · exact h

/-- **A round takes `previous` and `pending`.** In the stable suffix with a registered thread,
a closure in `previous` or `pending` at the start of a round `[a, b)` is taken at some point
of `[a, b]`. From `pending`, the first collect of the round takes it. From `previous`, it stays
there while the `Busy` set shrinks (`step_prev`); by `round_busy_false` some collect of the
round completes an epoch inside `quiet`, which takes the old `previous` (`quiet_epoch`). -/
theorem round_prev {ex : Nat → St} (hex : Exec ex) (hr : Reachable (ex 0)) {N0 : Nat}
    (hst : StableFrom ex N0) (hne : ∃ t, ((ex N0).threads t).isSome) {c : Cb}
    (hid : c.byId = false) {a b : Nat} (ha : N0 ≤ a) (hR : Round ex N0 a b)
    (hc : c ∈ (ex a).pending ∨ c ∈ (ex a).previous) :
    ∃ j, a ≤ j ∧ j ≤ b ∧ Taken c (ex j) := by
  apply Classical.byContradiction; intro H
  have H' : ∀ j, a ≤ j → j ≤ b → ¬ Taken c (ex j) := fun j h1 h2 h => H ⟨j, h1, h2, h⟩
  rcases hc with hp | hp
  · obtain ⟨u0, hu0⟩ := hne
    obtain ⟨m, hm1, hm2, hcol⟩ := hR u0 hu0
    have pers : ∀ j, a ≤ j → j ≤ b → c ∈ (ex j).pending := by
      refine ge_induction (P := fun j => j ≤ b → c ∈ (ex j).pending) (fun _ => hp)
        (fun j hj ih hjb => ?_)
      have ih := ih (by omega)
      rcases hex j with hs | hs
      · rcases step_pending hid hs ih with h | h
        · exact absurd h (H' _ (by omega) hjb)
        · exact h
      · rw [hs]; exact ih
    exact H' (m + 1) (by omega) (by omega)
      (hcol.2 ▸ collect_taken hid u0 _ (pers m hm1 (by omega)))
  · have pers : ∀ j, a ≤ j → j ≤ b → c ∈ (ex j).previous := by
      refine ge_induction (P := fun j => j ≤ b → c ∈ (ex j).previous) (fun _ => hp)
        (fun j hj ih hjb => ?_)
      have ih := ih (by omega)
      rcases hex j with hs | hs
      · rcases step_prev hid (Exec.reach hex hr _) hs (stable_step hst (by omega)) ih with
          h | ⟨h, -⟩
        · exact absurd h (H' _ (by omega) hjb)
        · exact h
      · rw [hs]; exact ih
    refine round_busy_false hex hr hst hne ha hR (fun j hj hjb => ?_)
      (fun t m hm hmb hcol _ => ?_)
    · rcases hex j with hs | hs
      · rcases step_prev hid (Exec.reach hex hr _) hs (stable_step hst (by omega))
          (pers j hj (by omega)) with h | ⟨-, h⟩
        · exact absurd h (H' _ (by omega) (by omega))
        · exact h
      · rw [hs]; exact fun _ h => h
    · rw [hcol.2]
      rcases (quiet_epoch t 1 (ex m) c).2 with ⟨-, -, -, h⟩ | ⟨h1, -⟩
      · simpa [startCollect] using h
      · exact absurd (hcol.2 ▸ taken_startCollect hid t true _ (h1 (pers m hm (by omega))))
          (H' _ (by omega) (by omega))

/-- **Fair liveness, bound (variant 4).** With registration stable from `N0` and at least one
registered thread, a closure `c` (`byId = false`, so never cancelled) queued at `n0 ≥ N0` is
in some thread's to-do list at some step of `[n0, r2]` whenever `[n0, r1)` and `[r1, r2)` are
rounds (every thread registered in the stable suffix completes a slow-path `collect` in each).

Proof: the first round brings `c` from the buffers to `previous`/`pending` or takes it
(`round_level` at level 2: an epoch completion moves `current` to `previous`). It stays there
until taken (`step_prev`, `step_pending`), and the second round takes it (`round_prev`: the
last `Busy` thread's `quiet` completes the epoch and takes the old `previous`). -/
theorem bound (ex : Nat → St) (hex : Exec ex) (hr : Reachable (ex 0)) (N0 : Nat)
    (hst : StableFrom ex N0) (hne : ∃ t, ((ex N0).threads t).isSome) (c : Cb)
    (hid : c.byId = false) (n0 r1 r2 : Nat) (hn0 : N0 ≤ n0) (hc : c ∈ bufs (ex n0))
    (h1 : Round ex N0 n0 r1) (h2 : Round ex N0 r1 r2) :
    ∃ m, n0 ≤ m ∧ m ≤ r2 ∧ Taken c (ex m) := by
  apply Classical.byContradiction; intro H
  have H' : ∀ j, n0 ≤ j → j ≤ r2 → ¬ Taken c (ex j) := fun j a b h => H ⟨j, a, b, h⟩
  obtain ⟨u0, hu0⟩ := hne
  have hr12 : r1 < r2 := by obtain ⟨m, a, b, -⟩ := h2 u0 hu0; omega
  have hL2 : Lv c 2 (ex n0) := by
    simp only [bufs, List.mem_append] at hc
    rcases hc with (h | h) | h
    · exact .inl h
    · exact .inr (.inr ⟨by omega, h⟩)
    · exact .inr (.inl ⟨by omega, h⟩)
  obtain ⟨j, hj1, hj2, h | ⟨-, hj⟩⟩ := round_level hex hr hst ⟨u0, hu0⟩ hid hn0 h1 hL2
  · exact H' j hj1 (by omega) h
  have hj : c ∈ (ex j).pending ∨ c ∈ (ex j).previous := by
    rcases hj with h | ⟨-, h⟩ | ⟨h, -⟩
    · exact .inl h
    · exact .inr h
    · omega
  -- `c` stays in `pending`/`previous` from `j` to `r1`
  have pers : ∀ i, j ≤ i → i ≤ r1 → c ∈ (ex i).pending ∨ c ∈ (ex i).previous := by
    refine ge_induction (P := fun i => i ≤ r1 → c ∈ (ex i).pending ∨ c ∈ (ex i).previous)
      (fun _ => hj) (fun i hi ih hir => ?_)
    have ih := ih (by omega)
    rcases hex i with hs | hs
    · rcases ih with h | h
      · rcases step_pending hid hs h with h | h
        · exact absurd h (H' _ (by omega) (by omega))
        · exact .inl h
      · rcases step_prev hid (Exec.reach hex hr _) hs (stable_step hst (by omega)) h with
          h | ⟨h, -⟩
        · exact absurd h (H' _ (by omega) (by omega))
        · exact .inr h
    · rw [hs]; exact ih
  obtain ⟨m, hm1, hm2, hm⟩ := round_prev hex hr hst ⟨u0, hu0⟩ hid (by omega) h2
    (pers r1 hj2 (Nat.le_refl _))
  exact H' m (by omega) hm2 hm

end Fair
end Collect
