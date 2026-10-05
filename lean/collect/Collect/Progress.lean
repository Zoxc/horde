import Collect.Safety

/-!
# Cancellation and progress properties
-/

namespace Collect

/-- `cancel_by_ids` is effective: after it, no flag with a cancelled id remains queued, so
(since flags are only marked inside the lock, from the queues) none will be written later
unless it is deferred again. -/
theorem cancel_effective (s : St) (ids : List Nat) (c : Cb) (hid : c.byId = true)
    (hmem : c.id ∈ ids) :
    c ∉ cancelList ids s.pending ∧ c ∉ cancelList ids s.current ∧
    c ∉ cancelList ids s.previous := by
  simp [cancelList, hid, hmem]

/-- `collect` from an unregistered thread when no thread is registered takes every queued
callback (the `free_single_thread` / "exited thread" scenarios). -/
theorem collectUnreg_takes_all (s : St) (h : allNone s.threads) (c : Cb) (hc : c ∈ bufs s) :
    c ∈ (collectUnreg s).2 ∧ bufs (collectUnreg s).1 = [] := by
  simp [collectUnreg, h, bufs] at hc ⊢
  grind

/-- When the last `busy` thread reports quiescence, every callback deferred in the previous
epoch is handed to it (epoch completion makes them eligible). -/
theorem last_quiet_takes_previous (s : St) (hcnt : CInv s) (t : Tid) (hb : s.threads t = some .busy)
    (hlast : ∀ u, u ≠ t → s.threads u ≠ some .busy) (c : Cb) (hc : c ∈ s.previous ∨ c ∈ s.pending) :
    c ∈ (quiet t 2 s).2 := by
  have hnb : noBusy (upd s.threads t (some .quiet)) := by
    intro u; by_cases hu : u = t
    · subst hu; simp
    · simp [hu]; exact hlast u hu
  have h0 : s.busy - 1 = 0 := (busy_last_iff hcnt hb (by simp)).2 hnb
  have hna : ¬ allNone (upd s.threads t (some .quiet)) := fun h => by simpa using h t
  have hmq : (markQuiet t s).pending = s.pending ++ s.previous := by
    simp [markQuiet, h0, completeEpoch, hna]
  simp only [quiet, hb, ne_eq, not_true_eq_false, ite_false]
  have : c ∈ (takePending (markQuiet t s)).2 := by
    simp only [takePending, hmq, List.mem_append]; exact hc.symm
  split <;> simp_all

/-- Reflexive-transitive closure of `Step`. -/
inductive Steps : St → St → Prop
  | refl (s) : Steps s s
  | tail {s s' s''} : Steps s s' → Step s' s'' → Steps s s''


theorem Steps.trans {a b c : St} (h1 : Steps a b) (h2 : Steps b c) : Steps a c := by
  induction h2 with
  | refl => exact h1
  | tail _ h ih => exact .tail ih h

theorem Steps.single {a b : St} (h : Step a b) : Steps a b := .tail (.refl _) h

theorem Steps.reach {a b : St} (h : Steps a b) (ha : Reachable a) : Reachable b := by
  induction h with
  | refl => exact ha
  | tail _ h ih => exact .step ih h

@[simp] theorem takePending_loc (s : St) : (takePending s).1.loc = s.loc := rfl

@[simp] theorem markQuiet_loc (t : Tid) (s : St) : (markQuiet t s).loc = s.loc := by
  unfold markQuiet; split <;> simp

theorem quiet_loc (t : Tid) : ∀ fuel (s : St), (quiet t fuel s).1.loc = s.loc
  | 0, s => rfl
  | fuel + 1, s => by
    simp only [quiet]
    split
    · rfl
    · split
      · simp [quiet_loc t fuel]
      · simp

@[simp] theorem collectUnreg_loc (s : St) : (collectUnreg s).1.loc = s.loc := by
  unfold collectUnreg; split <;> rfl

/-- Only finitely many threads have ever left `Unregistered`. -/
def FinLoc (s : St) : Prop := ∃ N, ∀ t, N ≤ t → s.loc t = .unregistered

theorem finLoc_upd {s : St} {loc : Tid → LS} (h : FinLoc s) (t : Tid) (v : LS)
    (hl : loc = upd s.loc t v) : ∃ N, ∀ u, N ≤ u → loc u = .unregistered := by
  obtain ⟨N, hN⟩ := h
  refine ⟨max N (t + 1), fun u hu => ?_⟩
  have h1 : N ≤ u := Nat.le_trans (Nat.le_max_left _ _) hu
  have h2 : t + 1 ≤ u := Nat.le_trans (Nat.le_max_right _ _) hu
  have hne : u ≠ t := fun e => by subst e; exact Nat.lt_irrefl _ h2
  rw [hl, upd_other _ _ _ _ hne]; exact hN u h1

theorem finLoc_step {s s' : St} (h : FinLoc s) (hs : Step s s') : FinLoc s' := by
  cases hs with
  | pinRegister t _ => exact finLoc_upd h t _ rfl
  | pinOuter t _ => exact finLoc_upd h t _ rfl
  | pinNest t _ _ _ => exact finLoc_upd h t _ rfl
  | unpinNest t _ _ _ => exact finLoc_upd h t _ rfl
  | unpinOuter t _ _ => exact finLoc_upd h t _ rfl
  | release t _ => exact finLoc_upd h t .unregistered (by simp)
  | defer => exact h
  | cancel => exact h
  | collectReg t _ => exact finLoc_upd h t _ (by simp [startCollect, quietRust_eq, quiet_loc]; rfl)
  | collectUnreg t _ => exact finLoc_upd h t _ (by simp [startCollect]; rfl)
  | runOne t _ _ _ _ => exact finLoc_upd h t _ rfl
  | finish t _ _ => exact finLoc_upd h t _ rfl

theorem reachable_finLoc {s : St} (h : Reachable s) : FinLoc s := by
  induction h with
  | init => exact ⟨0, fun _ _ => rfl⟩
  | step _ hs ih => exact finLoc_step ih hs


theorem completeEpoch_mem_fwd (s : St) (c : Cb) (h : c ∈ bufs s) : c ∈ bufs (completeEpoch s) := by
  unfold completeEpoch; split <;> simp [bufs] at h ⊢ <;> grind

theorem unregister_mem_fwd (s : St) (t : Tid) (c : Cb) (h : c ∈ bufs s) :
    c ∈ bufs (unregister s t) := by
  unfold unregister
  dsimp only
  split
  · split
    · exact completeEpoch_mem_fwd _ c (by simpa [bufs] using h)
    · simpa [bufs] using h
  · split
    · exact completeEpoch_mem_fwd _ c (by simpa [bufs] using h)
    · simpa [bufs] using h

/-- `s'` differs from `s` only in thread `t`'s local state, keeps every queued callback queued
and every run callback run. -/
def Pres (t : Tid) (s s' : St) : Prop :=
  (∀ u, u ≠ t → s'.loc u = s.loc u) ∧ (∀ c ∈ bufs s, c ∈ bufs s') ∧ (∀ c ∈ s.ran, c ∈ s'.ran)

theorem Pres.refl (t : Tid) (s : St) : Pres t s s := ⟨fun _ _ => rfl, fun _ h => h, fun _ h => h⟩

theorem Pres.trans {t} {a b c : St} (h1 : Pres t a b) (h2 : Pres t b c) : Pres t a c :=
  ⟨fun u hu => (h2.1 u hu).trans (h1.1 u hu), fun x hx => h2.2.1 x (h1.2.1 x hx),
   fun x hx => h2.2.2 x (h1.2.2 x hx)⟩

theorem release_drive (s : St) (t : Tid) (hl : s.loc t = .registered) :
    ∃ s', Steps s s' ∧ s'.loc t = .unregistered ∧ Pres t s s' := by
  refine ⟨_, .single (.release s t hl), by simp, fun u hu => by simp [hu], ?_, by simp⟩
  intro c hc; exact unregister_mem_fwd _ t c (by simpa [bufs] using hc)

theorem unpin_drive (t : Tid) (st : Nat) : ∀ (d : Nat) (s : St), s.loc t = .pinned st d →
    ∃ s', Steps s s' ∧ s'.loc t = .registered ∧ Pres t s s'
  | 0, s, hl => ⟨_, .single (.unpinOuter s t st hl), by simp, fun u hu => by simp [hu],
      fun _ h => h, fun _ h => h⟩
  | d + 1, s, hl => by
    obtain ⟨s', h1, h2, h3⟩ := unpin_drive t st d { s with loc := upd s.loc t (.pinned st d) } (by simp)
    exact ⟨s', .trans (.single (.unpinNest s t st d hl)) h1, h2,
      Pres.trans (b := { s with loc := upd s.loc t (.pinned st d) })
        ⟨fun u hu => by simp [hu], fun _ h => h, fun _ h => h⟩ h3⟩

theorem run_drive (t : Tid) (w : Bool) : ∀ (l : List Cb) (s : St), s.loc t = .collecting w l →
    ∃ s', Steps s s' ∧ s'.loc t = (if w then .registered else .unregistered) ∧ Pres t s s' ∧
      ∀ c ∈ l, c ∈ s'.ran
  | [], s, hl => ⟨_, .single (.finish s t w hl), by simp, ⟨fun u hu => by simp [hu],
      fun _ h => h, fun _ h => h⟩, by simp⟩
  | c :: cs, s, hl => by
    obtain ⟨s', h1, h2, h3, h4⟩ :=
      run_drive t w cs { s with loc := upd s.loc t (.collecting w cs), ran := s.ran ++ [c] }
        (by simp)
    refine ⟨s', .trans (.single (.runOne s t w c cs hl)) h1, h2,
      Pres.trans (b := { s with loc := upd s.loc t (.collecting w cs), ran := s.ran ++ [c] })
        ⟨fun u hu => by simp [hu], fun _ h => h, fun _ h => by simp [h]⟩ h3, ?_⟩
    intro x hx
    rcases List.mem_cons.1 hx with rfl | hx
    · exact h3.2.2 _ (by simp)
    · exact h4 x hx

/-- Drive one thread back to `Unregistered`. -/
theorem drain_thread (s : St) (t : Tid) :
    ∃ s', Steps s s' ∧ s'.loc t = .unregistered ∧ Pres t s s' := by
  cases hl : s.loc t with
  | unregistered => exact ⟨s, .refl _, hl, .refl t s⟩
  | registered => exact release_drive s t hl
  | pinned st d =>
    obtain ⟨s1, a1, b1, c1⟩ := unpin_drive t st d s hl
    obtain ⟨s2, a2, b2, c2⟩ := release_drive s1 t b1
    exact ⟨s2, a1.trans a2, b2, c1.trans c2⟩
  | collecting w l =>
    obtain ⟨s1, a1, b1, c1, -⟩ := run_drive t w l s hl
    cases w
    · exact ⟨s1, a1, by simpa using b1, c1⟩
    · obtain ⟨s2, a2, b2, c2⟩ := release_drive s1 t (by simpa using b1)
      exact ⟨s2, a1.trans a2, b2, c1.trans c2⟩

/-- Drive threads `0 .. n-1` back to `Unregistered`. -/
theorem drain_upto (s : St) : ∀ n : Nat, ∃ s', Steps s s' ∧
    (∀ t, t < n → s'.loc t = .unregistered) ∧ (∀ t, n ≤ t → s'.loc t = s.loc t) ∧
    (∀ c ∈ bufs s, c ∈ bufs s')
  | 0 => ⟨s, .refl _, fun _ h => absurd h (Nat.not_lt_zero _), fun _ _ => rfl, fun _ h => h⟩
  | n + 1 => by
    obtain ⟨s1, a1, b1, c1, d1⟩ := drain_upto s n
    obtain ⟨s2, a2, b2, c2⟩ := drain_thread s1 n
    refine ⟨s2, a1.trans a2, ?_, ?_, fun c h => c2.2.1 c (d1 c h)⟩
    · intro t ht
      by_cases e : t = n
      · subst e; exact b2
      · rw [c2.1 t e]; exact b1 t (by omega)
    · intro t ht
      have hle : n ≤ t := Nat.le_of_succ_le ht
      have hne : t ≠ n := fun e => by subst e; exact Nat.not_succ_le_self _ ht
      rw [c2.1 t hne]; exact c1 t hle

/-- Proof of `eventually_ran`: release every thread (finitely many, `FinLoc`), then
`collect` from thread 0 with no thread registered and run its to-do list. -/
theorem eventually_ran_aux (s : St) (h : Reachable s) (c : Cb) (hc : c ∈ bufs s) :
    ∃ s', Steps s s' ∧ c ∈ s'.ran := by
  obtain ⟨N, hN⟩ := reachable_finLoc h
  obtain ⟨s1, a1, b1, c1, d1⟩ := drain_upto s N
  have hall : ∀ t, s1.loc t = .unregistered := fun t => by
    by_cases ht : t < N
    · exact b1 t ht
    · have hle : N ≤ t := Nat.le_of_not_lt ht
      rw [c1 t hle]; exact hN t hle
  have hr1 : Reachable s1 := a1.reach h
  have hnone : allNone s1.threads := fun t => (threads_consistent hr1 t).1 (hall t)
  have hcu := (collectUnreg_takes_all s1 hnone c (d1 c hc)).1
  have st1 := Step.collectUnreg s1 0 (hall 0)
  by_cases hb : c.byId = true
  · exact ⟨_, a1.tail st1, by simp [startCollect, hcu, hb]⟩
  · obtain ⟨s3, a3, -, -, d3⟩ := run_drive 0 false
      ((collectUnreg s1).2.filter (fun c => !c.byId)) (startCollect 0 false (collectUnreg s1)) (by simp only [startCollect]; simp [upd])
    exact ⟨s3, (a1.tail st1).trans a3, d3 c (List.mem_filter.2 ⟨hcu, by cases e : c.byId <;> simp_all⟩)⟩


/-- **Eventual reclamation (weak liveness).** From any reachable state, a queued callback can
be driven to completion by some schedule (unpin, then every registered thread calls
`collect` twice, then run the to-do lists).

Proved via `eventually_ran_aux`: the schedule drains every thread back to `Unregistered`
(finitely many have left it, `reachable_finLoc`), then thread 0 runs `collect_unregistered`,
which takes every queued callback since no thread is registered. A *fair-trace* version (every registered thread eventually
calls `collect` outside a pin, with the `EVENTS` fast path modelled) is ~1-2 weeks more. -/
theorem eventually_ran (s : St) (h : Reachable s) (c : Cb) (hc : c ∈ bufs s) :
    ∃ s', Steps s s' ∧ c ∈ s'.ran :=
  eventually_ran_aux s h c hc

end Collect
