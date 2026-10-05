import Collect.Progress

/-!
# Fair (trace) liveness

Infinite executions of the base model and fairness hypotheses. See MAPPING.md, section
"Fair liveness".

Main results:
* `busy_zero_iff_empty`: `busy_count == 0` iff `threads` is empty, so `register` inserts a
  `Busy` thread only into an empty collector.
* `fair_stable`: with registration eventually stable, every non-cancellable queued closure
  eventually runs under per-thread fairness on slow-path collects.
* `fair`: the same with threads free to `release` and re-register at any time, under
  `BusyFairAll` (a `Busy` thread eventually collects or stops being `Busy`), `CollectFair`
  (some thread eventually collects) and the to-do clause. `register` inserts `Quiet`
  threads, so the `Busy` set of an epoch only shrinks.

These are on the base model, where `collect_cold` may run at any time. The primary-model
versions, with fairness on `collect` calls that may take the `EVENTS` fast path, are
`EFair.efair_stable` and `EFair.efair`; they need a no-wrap-around hypothesis.
-/

namespace Collect
namespace Fair

/-- An infinite execution of the base model (stuttering allowed). -/
def Exec (ex : Nat → St) : Prop := ∀ n, Step (ex n) (ex (n + 1)) ∨ ex (n + 1) = ex n

/-- Thread `t` completes a slow-path `collect` from `Registered` at step `m`. -/
def CollectsAt (ex : Nat → St) (t : Tid) (m : Nat) : Prop :=
  (ex m).loc t = .registered ∧ ex (m + 1) = startCollect t true (quiet t 2 (ex m))

/-! ## Stable registration

`fair_stable`: if the registered set is eventually stable (`StableFrom`), per-thread fairness
on slow-path collects suffices. `fair` (below) drops the stability assumption. -/

/-- From step `N0` on, no thread registers or unregisters. -/
def StableFrom (ex : Nat → St) (N0 : Nat) : Prop :=
  ∀ n, N0 ≤ n → ∀ t, ((ex (n + 1)).threads t).isSome = ((ex N0).threads t).isSome

/-- Fairness: every thread registered in the stable suffix completes slow-path collects
infinitely often, and every to-do list is eventually run. -/
def FairFrom (ex : Nat → St) (N0 : Nat) : Prop :=
  (∀ t, ((ex N0).threads t).isSome → ∀ n, ∃ m, n ≤ m ∧ CollectsAt ex t m) ∧
  (∀ n t w l, (ex n).loc t = .collecting w l → ∀ x ∈ l, ∃ m, x ∈ (ex m).ran)

/-! ### Helper lemmas for `fair_stable` -/

/-- `quiet` with fuel `≥ 1` always empties `pending`. -/
theorem quiet_pending_nil (t : Tid) : ∀ fuel (s : St), (quiet t (fuel + 1) s).1.pending = []
  | fuel, s => by
    simp only [quiet]
    split
    · rfl
    · split
      · cases fuel with
        | zero => simp [quiet, takePending]
        | succ f => simp [quiet_pending_nil t f]
      · rfl

/-- `quiet` only moves callbacks forward: `pending` to the result, `previous` to `pending`
or the result. -/
theorem quiet_fwd (t : Tid) (x : Cb) : ∀ fuel (s : St),
    (x ∈ s.pending → x ∈ (quiet t fuel s).1.pending ∨ x ∈ (quiet t fuel s).2) ∧
    (x ∈ s.previous → x ∈ (quiet t fuel s).1.previous ∨ x ∈ (quiet t fuel s).1.pending ∨
      x ∈ (quiet t fuel s).2)
  | 0, s => by simp [quiet]; exact fun h => .inl h
  | fuel + 1, s => by
    have ih := quiet_fwd t x fuel
    simp only [quiet]
    split
    · simp [takePending]; exact fun h => .inl h
    · have hm : (x ∈ s.pending → x ∈ (markQuiet t s).pending) ∧
          (x ∈ s.previous → x ∈ (markQuiet t s).previous ∨ x ∈ (markQuiet t s).pending) := by
        unfold markQuiet; split
        · unfold completeEpoch; split <;> simp <;> grind
        · simp; exact fun h => .inl h
      split
      · have h2 := ih (takePending (markQuiet t s)).1
        simp only [takePending] at h2 ⊢
        constructor
        · intro hx; simp [hm.1 hx]
        · intro hx
          rcases hm.2 hx with h | h
          · rcases h2.2 h with h' | h' | h' <;> simp_all
          · simp [h]
      · simp only [takePending]
        constructor
        · intro hx; simp [hm.1 hx]
        · intro hx; rcases hm.2 hx with h | h <;> simp [h]

def Shr (th th' : Tid → Option TS) : Prop := ∀ u, th' u = some .busy → th u = some .busy

/-- Epoch dichotomy for `quiet`: either no epoch completed (busy set shrinks, `t` ends up
not busy, `current`/`previous` untouched), or one did (`previous` was taken, `current` moved
at least to `previous`). -/
theorem quiet_epoch (t : Tid) (fuel : Nat) (s : St) (x : Cb) :
    (x ∈ s.pending → x ∈ (quiet t (fuel + 1) s).2) ∧
    ((Shr s.threads (quiet t (fuel + 1) s).1.threads ∧
      (quiet t (fuel + 1) s).1.current = s.current ∧
      (quiet t (fuel + 1) s).1.previous = s.previous ∧
      (quiet t (fuel + 1) s).1.threads t ≠ some .busy) ∨
     ((x ∈ s.previous → x ∈ (quiet t (fuel + 1) s).2) ∧
      (x ∈ s.current → x ∈ (quiet t (fuel + 1) s).1.previous ∨
        x ∈ (quiet t (fuel + 1) s).1.pending ∨ x ∈ (quiet t (fuel + 1) s).2))) := by
  simp only [quiet]
  split
  · rename_i hb
    refine ⟨by simp [takePending], .inl ⟨fun u h => h, rfl, rfl, by simpa [takePending] using hb⟩⟩
  · rename_i hb
    have hb : s.threads t = some .busy := by simpa using hb
    by_cases h0 : s.busy - 1 = 0
    · have hna : ¬ allNone (upd s.threads t (some .quiet)) := fun h => by simpa using h t
      have hp : (markQuiet t s).pending = s.pending ++ s.previous := by
        simp [markQuiet, h0, completeEpoch, hna]
      have hv : (markQuiet t s).previous = s.current := by
        simp [markQuiet, h0, completeEpoch, hna]
      have hc0 : s.busy - 1 = 0 ∧ (takePending (markQuiet t s)).1.previous ≠ [] ↔ s.current ≠ [] := by
        simp [takePending, hv, h0]
      simp only [hc0]
      generalize markQuiet t s = m at hp hv
      split
      · have h2 := (quiet_fwd t x fuel (takePending m).1).2
        simp only [takePending, hp, hv] at h2 ⊢
        refine ⟨by simp_all, .inr ⟨by simp_all, fun hx => ?_⟩⟩
        rcases h2 hx with h | h | h <;> simp [h]
      · rename_i hc
        simp only [takePending, hp, hv]
        refine ⟨by simp_all, .inr ⟨by simp_all, fun hx => ?_⟩⟩
        exact absurd (fun e => by simp [e] at hx) hc
    · have hmq : markQuiet t s = { s with threads := upd s.threads t (some .quiet), busy := s.busy - 1 } := by
        simp [markQuiet, h0]
      rw [hmq]
      simp only [takePending, h0, false_and, ite_false]
      refine ⟨by simp, .inl ⟨fun u h => ?_, by simp, by simp, by simp⟩⟩
      by_cases hu : u = t
      · subst hu; simp at h
      · simpa [hu] using h


/-- Some thread is `Busy` whenever some thread is registered. -/
def HasBusy (th : Tid → Option TS) : Prop := (∃ u, th u ≠ none) → ∃ u, th u = some .busy

theorem hasBusy_completeEpoch (s : St) : HasBusy (completeEpoch s).threads := by
  unfold completeEpoch; split
  · rename_i ha; intro ⟨u, hu⟩; exact absurd (ha u) hu
  · rename_i hna; intro _
    obtain ⟨u, hu⟩ : ∃ u, s.threads u ≠ none := by
      apply Classical.byContradiction; intro hn; exact hna fun u => by
        apply Classical.byContradiction; intro h'; exact hn ⟨u, h'⟩
    exact ⟨u, by cases hh : s.threads u <;> simp_all⟩

theorem not_noBusy {th : Tid → Option TS} (h : ¬ noBusy th) : ∃ u, th u = some .busy :=
  Classical.byContradiction fun hn => h fun u hu => hn ⟨u, hu⟩

theorem hasBusy_markQuiet {s : St} {t} (hc : CInv s) (hb : s.threads t = some .busy) :
    HasBusy (markQuiet t s).threads := by
  intro _
  by_cases h0 : s.busy - 1 = 0
  · have hna : ¬ allNone (upd s.threads t (some .quiet)) := fun h => by simpa using h t
    exact ⟨t, by simp [markQuiet, h0, completeEpoch, hna]⟩
  · have := not_noBusy (mt (busy_last_iff hc hb (v := some .quiet) (by simp)).2 h0)
    simpa [markQuiet, h0] using this

theorem hasBusy_quiet (t : Tid) : ∀ fuel (s : St), CInv s → HasBusy s.threads →
    s.threads t ≠ none → HasBusy (quiet t fuel s).1.threads
  | 0, _, _, h, _ => h
  | fuel + 1, s, hc, h, ht => by
    simp only [quiet]
    split
    · exact h
    · rename_i hb; have hb : s.threads t = some .busy := by simpa using hb
      have h1 := takePending_cinv (markQuiet_cinv hc hb)
      split
      · exact hasBusy_quiet t fuel _ h1 (hasBusy_markQuiet hc hb) (markQuiet_threads_ne ht)
      · exact hasBusy_markQuiet hc hb

theorem hasBusy_unregister {s : St} {t} (hc : CInv s) (h : HasBusy s.threads)
    (ht : s.threads t ≠ none) : HasBusy (unregister s t).threads := by
  dsimp only [unregister]
  split
  · rename_i hb
    split
    · exact hasBusy_completeEpoch _
    · rename_i h0
      intro _
      have := not_noBusy (mt (busy_last_iff hc hb (v := none) (by simp)).2 h0)
      simpa using this
  · rename_i hb
    split
    · exact hasBusy_completeEpoch _
    · intro _
      obtain ⟨u, hu⟩ := h ⟨t, ht⟩
      have hut : u ≠ t := by rintro rfl; exact hb hu
      exact ⟨u, by simp [hut, hu]⟩

theorem reachable_hasBusy {s : St} (h : Reachable s) : HasBusy s.threads := by
  induction h with
  | init => intro ⟨u, hu⟩; simp [init] at hu
  | @step s s' hr hs ih =>
    have hc := reachable_cinv hr
    cases hs with
    | pinRegister t hl =>
      intro _
      by_cases h0 : s.busy = 0
      · exact ⟨t, by simp [register, h0]⟩
      · obtain ⟨u, hu⟩ := not_noBusy (mt (busy_zero_iff hc).2 h0)
        have hut : u ≠ t := by rintro rfl; rw [(threads_consistent hr u).1 hl] at hu; cases hu
        exact ⟨u, by simp [register, hut, hu]⟩
    | release t hl =>
      exact hasBusy_unregister hc ih ((threads_consistent hr t).2 hl)
    | collectReg t hl =>
      rw [quietRust_eq]
      exact hasBusy_quiet t 2 _ hc ih ((threads_consistent hr t).2 hl)
    | collectUnreg t _ =>
      simp only [startCollect]; unfold collectUnreg; split <;> exact ih
    | _ => exact ih


/-- `c` is in some thread's to-do list. -/
def Taken (c : Cb) (s : St) : Prop := ∃ t w l, s.loc t = .collecting w l ∧ c ∈ l

/-- Level of `c`: 0 = `pending`, 1 = `previous` (or better), 2 = anywhere in the buffers. -/
def Lv (c : Cb) (k : Nat) (s : St) : Prop :=
  c ∈ s.pending ∨ (1 ≤ k ∧ c ∈ s.previous) ∨ (2 ≤ k ∧ c ∈ s.current)

theorem taken_startCollect {c : Cb} (hid : c.byId = false) (t : Tid) (w : Bool)
    (r : St × List Cb) (h : c ∈ r.2) : Taken c (startCollect t w r) :=
  ⟨t, w, r.2.filter (fun c => !c.byId), by simp [startCollect], List.mem_filter.2 ⟨h, by simp [hid]⟩⟩

theorem collect_level {c : Cb} (hid : c.byId = false) (k : Nat) (s : St) (t : Tid)
    (hL : Lv c k s) :
    Taken c (startCollect t true (quiet t 2 s)) ∨
    (k ≠ 0 ∧ Lv c (k - 1) (startCollect t true (quiet t 2 s))) ∨
    (k ≠ 0 ∧ Lv c k (startCollect t true (quiet t 2 s)) ∧
      Shr s.threads (startCollect t true (quiet t 2 s)).threads ∧
      (startCollect t true (quiet t 2 s)).threads t ≠ some .busy) := by
  obtain ⟨hp, he⟩ := quiet_epoch t 1 s c
  have hpn := quiet_pending_nil t 1 s
  generalize quiet t 2 s = q at hp he hpn
  have tk := taken_startCollect hid t true q
  simp only [startCollect]
  rcases hL with h | ⟨hk, h⟩ | ⟨hk, h⟩
  · exact .inl (tk (hp h))
  · rcases he with ⟨hs, hcur, hprev, hnb⟩ | ⟨h1, -⟩
    · refine .inr (.inr ⟨by omega, .inr (.inl ⟨hk, by simpa [hprev] using h⟩), hs, hnb⟩)
    · exact .inl (tk (h1 h))
  · rcases he with ⟨hs, hcur, hprev, hnb⟩ | ⟨-, h2⟩
    · refine .inr (.inr ⟨by omega, .inr (.inr ⟨hk, by simpa [hcur] using h⟩), hs, hnb⟩)
    · rcases h2 h with h | h | h
      · exact .inr (.inl ⟨by omega, .inr (.inl ⟨by omega, h⟩)⟩)
      · simp [hpn] at h
      · exact .inl (tk h)

/-- One step in the stable suffix: `c` is taken, drops a level, or stays at its level while
the busy set shrinks. -/
theorem step_level {c : Cb} (hid : c.byId = false) (k : Nat) {s s' : St} (hr : Reachable s)
    (hs : Step s s') (hst : ∀ u, (s'.threads u).isSome = (s.threads u).isSome)
    (hL : Lv c k s) :
    Taken c s' ∨ (k ≠ 0 ∧ Lv c (k - 1) s') ∨ (Lv c k s' ∧ Shr s.threads s'.threads) := by
  have same : ∀ s' : St, s'.pending = s.pending → s'.previous = s.previous →
      s'.current = s.current → s'.threads = s.threads →
      Taken c s' ∨ (k ≠ 0 ∧ Lv c (k - 1) s') ∨ (Lv c k s' ∧ Shr s.threads s'.threads) :=
    fun s' a b d e => .inr (.inr ⟨by simp only [Lv, a, b, d]; exact hL, by rw [e]; exact fun _ h => h⟩)
  cases hs with
  | pinRegister t hl =>
    have := hst t; simp [register, (threads_consistent hr t).1 hl] at this
  | release t hl =>
    have := hst t
    rw [unregister_isSome] at this
    simp at this; exact absurd this ((threads_consistent hr t).2 hl)
  | pinOuter => exact same _ rfl rfl rfl rfl
  | pinNest => exact same _ rfl rfl rfl rfl
  | unpinNest => exact same _ rfl rfl rfl rfl
  | unpinOuter => exact same _ rfl rfl rfl rfl
  | runOne => exact same _ rfl rfl rfl rfl
  | finish => exact same _ rfl rfl rfl rfl
  | defer =>
    refine .inr (.inr ⟨?_, fun _ h => h⟩)
    simp only [Lv, List.mem_append] at hL ⊢
    rcases hL with h | h | ⟨a, b⟩
    · exact .inl h
    · exact .inr (.inl h)
    · exact .inr (.inr ⟨a, .inl b⟩)
  | cancel ids =>
    refine .inr (.inr ⟨?_, fun _ h => h⟩)
    simpa [Lv, cancelList, hid] using hL
  | collectReg t _ =>
    rw [quietRust_eq]
    rcases collect_level hid k s t hL with h | h | ⟨-, a, b, -⟩
    · exact .inl h
    · exact .inr (.inl h)
    · exact .inr (.inr ⟨a, b⟩)
  | collectUnreg t _ =>
    unfold collectUnreg
    split
    · refine .inl (taken_startCollect hid t false _ ?_)
      rcases hL with h | ⟨-, h⟩ | ⟨-, h⟩ <;> simp [*]
    · rcases hL with h | h
      · exact .inl (taken_startCollect hid t false _ (by simp [*]))
      · exact .inr (.inr ⟨by simp only [Lv, startCollect]; exact .inr h, fun _ h => h⟩)


theorem countBusy_mono {th th' : Tid → Option TS} (h : Shr th th') :
    ∀ L : List Tid, countBusy th' L ≤ countBusy th L
  | [] => by simp [countBusy]
  | u :: L => by
    have ih := countBusy_mono h L
    simp only [countBusy, List.filter_cons] at ih ⊢
    have := h u
    split <;> split <;> simp_all <;> omega

theorem countBusy_lt {th th' : Tid → Option TS} (h : Shr th th') {w : Tid}
    (hw : th w = some .busy) (hw' : th' w ≠ some .busy) :
    ∀ L : List Tid, w ∈ L → countBusy th' L < countBusy th L
  | [], hm => by simp at hm
  | u :: L, hm => by
    have hle := countBusy_mono h L
    simp only [countBusy, List.filter_cons] at hle ⊢
    by_cases hu : u = w
    · subst hu; simp [hw, hw']; omega
    · have ih := countBusy_lt h hw hw' L (by simpa [Ne.symm hu] using hm)
      simp only [countBusy] at ih
      have := h u
      split <;> split <;> simp_all <;> omega

theorem Exec.reach {ex : Nat → St} (hex : Exec ex) (hr : Reachable (ex 0)) :
    ∀ n, Reachable (ex n)
  | 0 => hr
  | n + 1 => by
    rcases hex n with h | h
    · exact .step (Exec.reach hex hr n) h
    · rw [h]; exact Exec.reach hex hr n

theorem stable_at {ex : Nat → St} {N0 : Nat} (hst : StableFrom ex N0) :
    ∀ n, N0 ≤ n → ∀ u, ((ex n).threads u).isSome = ((ex N0).threads u).isSome
  | n, hn, u => by
    rcases Nat.eq_or_lt_of_le hn with rfl | hlt
    · rfl
    · obtain ⟨m, rfl⟩ : ∃ m, n = m + 1 := ⟨n - 1, by omega⟩
      exact hst m (by omega) u

theorem lv_bufs {c : Cb} {k : Nat} {s : St} (h : Lv c k s) : c ∈ bufs s := by
  simp only [Lv, bufs, List.mem_append] at h ⊢
  rcases h with h | ⟨-, h⟩ | ⟨-, h⟩ <;> simp [h]

/-- The part of fairness that `level_progress` uses: a thread that is `Busy` in the stable
suffix while `c` stays queued eventually completes a slow-path `collect` or stops being
`Busy`. Implied by `FairFrom` (`FairFrom.busyFair`); on the primary model it is derived from
fairness on `collect` calls, fast path included (`EFair.busyFair`). -/
def BusyFair (ex : Nat → St) (N0 : Nat) (c : Cb) : Prop :=
  ∀ w m, N0 ≤ m → (ex m).threads w = some .busy → (∀ j, m ≤ j → c ∈ bufs (ex j)) →
    ∃ m2, m ≤ m2 ∧ (CollectsAt ex w m2 ∨ (ex m2).threads w ≠ some .busy)

/-- At level `k`, `c` eventually is taken or drops a level. Strong induction on the number of
`Busy` threads (among the keys `L` of the stable suffix). -/
theorem level_progress {ex : Nat → St} (hex : Exec ex) (hr : Reachable (ex 0)) {N0 : Nat}
    (hst : StableFrom ex N0) (hne : ∃ t, ((ex N0).threads t).isSome) {c : Cb}
    (hb : BusyFair ex N0 c) (hid : c.byId = false) (k : Nat) (L : List Tid)
    (hL : ∀ u, u ∈ L ↔ (ex N0).threads u ≠ none) :
    ∀ v m, N0 ≤ m → Lv c k (ex m) → countBusy (ex m).threads L = v →
      ∃ m', m ≤ m' ∧ (Taken c (ex m') ∨ (k ≠ 0 ∧ Lv c (k - 1) (ex m'))) := by
  intro v
  induction v using Nat.strongRecOn with
  | _ v IH =>
  intro m hm hlv hv
  apply Classical.byContradiction
  intro H
  have H' : ∀ m', m ≤ m' → ¬ Taken c (ex m') ∧ ¬ (k ≠ 0 ∧ Lv c (k - 1) (ex m')) :=
    fun m' h => ⟨fun h1 => H ⟨m', h, .inl h1⟩, fun h1 => H ⟨m', h, .inr h1⟩⟩
  have pers : ∀ j, Lv c k (ex (m + j)) ∧ Shr (ex m).threads (ex (m + j)).threads := by
    intro j
    induction j with
    | zero => exact ⟨hlv, fun _ h => h⟩
    | succ j ih =>
      rcases hex (m + j) with hs | hs
      · have hstab : ∀ u, ((ex (m + j + 1)).threads u).isSome = ((ex (m + j)).threads u).isSome :=
          fun u => (stable_at hst _ (by omega) u).trans (stable_at hst _ (by omega) u).symm
        rcases step_level hid k (Exec.reach hex hr _) hs hstab ih.1 with h | h | ⟨a, b⟩
        · exact absurd h (H' _ (by omega)).1
        · exact absurd h (H' _ (by omega)).2
        · exact ⟨a, fun u hu => ih.2 u (b u hu)⟩
      · rw [show m + (j + 1) = m + j + 1 by omega, hs]; exact ih
  -- some thread is `Busy` at `m`
  obtain ⟨u0, hu0⟩ := hne
  obtain ⟨w, hw⟩ := reachable_hasBusy (Exec.reach hex hr m)
    ⟨u0, by
      have := stable_at hst m hm u0; rw [hu0] at this
      intro h; rw [h] at this; simp at this⟩
  have hwN : ((ex N0).threads w).isSome := by rw [← stable_at hst m hm w, hw]; rfl
  have hwL : w ∈ L := (hL w).2 (by intro h; rw [h] at hwN; simp at hwN)
  obtain ⟨m2, hm2, hcm⟩ := hb w m hm hw fun j hj => by
    have := (pers (j - m)).1; rw [show m + (j - m) = j by omega] at this; exact lv_bufs this
  -- a later point `p` where `w` is no longer `Busy`
  obtain ⟨p, hp, hpw⟩ : ∃ p, m ≤ p ∧ (ex p).threads w ≠ some .busy := by
    obtain hnb | hcol := hcm.symm
    · exact ⟨m2, hm2, hnb⟩
    by_cases hb : (ex m2).threads w = some .busy
    · have hl2 := (pers (m2 - m)).1
      rw [show m + (m2 - m) = m2 by omega] at hl2
      have := collect_level hid k (ex m2) w hl2
      rw [← hcol.2] at this
      rcases this with h | h | ⟨-, -, -, h⟩
      · exact absurd h (H' _ (by omega)).1
      · exact absurd h (H' _ (by omega)).2
      · exact ⟨m2 + 1, by omega, h⟩
    · exact ⟨m2, hm2, hb⟩
  have hpp := pers (p - m)
  rw [show m + (p - m) = p by omega] at hpp
  have hlt : countBusy (ex p).threads L < v := hv ▸ countBusy_lt hpp.2 hw hpw L hwL
  obtain ⟨m', hm', h⟩ := IH _ hlt p (by omega) hpp.1 rfl
  exact H ⟨m', by omega, h⟩


/-- `fair_stable` with only the parts of fairness its proof uses: `BusyFair` for `c` and the
to-do clause of `FairFrom`. This is the form the primary-model result `EFair.efair_stable`
reduces to. -/
theorem fair_stable_busy (ex : Nat → St) (hex : Exec ex) (hr : Reachable (ex 0)) (N0 : Nat)
    (hst : StableFrom ex N0) (hne : ∃ t, ((ex N0).threads t).isSome) (c : Cb)
    (hb : BusyFair ex N0 c)
    (htodo : ∀ n t w l, (ex n).loc t = .collecting w l → ∀ x ∈ l, ∃ m, x ∈ (ex m).ran)
    (hid : c.byId = false) (n0 : Nat) (hn0 : N0 ≤ n0) (hc : c ∈ bufs (ex n0)) :
    ∃ m, c ∈ (ex m).ran := by
  obtain ⟨L, -, hL, -, -⟩ := reachable_cinv (Exec.reach hex hr N0)
  have lp := level_progress hex hr hst hne hb hid
  have fin : ∀ m, Taken c (ex m) → ∃ m, c ∈ (ex m).ran := fun m ⟨t, w, l, hl, hx⟩ =>
    htodo m t w l hl c hx
  have h2 : Lv c 2 (ex n0) := by
    simp only [bufs, List.mem_append] at hc
    rcases hc with (h | h) | h
    · exact .inl h
    · exact .inr (.inr ⟨by omega, h⟩)
    · exact .inr (.inl ⟨by omega, h⟩)
  obtain ⟨m1, hm1, h | ⟨-, h1⟩⟩ := lp 2 L hL _ n0 hn0 h2 rfl
  · exact fin _ h
  obtain ⟨m2, hm2, h | ⟨-, h0⟩⟩ := lp 1 L hL _ m1 (by omega) h1 rfl
  · exact fin _ h
  obtain ⟨m3, -, h | ⟨h, -⟩⟩ := lp 0 L hL _ m2 (by omega) h0 rfl
  · exact fin _ h
  · exact absurd rfl h

theorem FairFrom.busyFair {ex : Nat → St} {N0 : Nat} (hst : StableFrom ex N0)
    (hf : FairFrom ex N0) (c : Cb) : BusyFair ex N0 c := by
  intro w m hm hw _
  have hwN : ((ex N0).threads w).isSome := by rw [← stable_at hst m hm w, hw]; rfl
  obtain ⟨m2, hm2, h⟩ := hf.1 w hwN m
  exact ⟨m2, hm2, .inl h⟩

/-- **Fair liveness, stable registration.** A closure (`byId = false`, so never cancelled)
queued in the stable suffix eventually runs, provided at least one thread stays registered
(with none registered, `collect_unregistered` takes everything; that case needs a fairness
assumption on unregistered `collect`s instead). Statement unchanged from the original plan.

Proof: `c` has a level (`Lv`: 2 = in the buffers, 1 = in `previous`/`pending`, 0 = in
`pending`). Per step in the stable suffix (`step_level`), `c` is taken into a to-do list
(`Taken`), drops a level, or keeps its level while the `Busy` set only shrinks. No duplicate
freedom is needed: the lemmas track "some copy of `c`" via these disjunctions. Some thread is
always `Busy` while one is registered (`reachable_hasBusy`). Strong induction on the number
of `Busy` keys (`level_progress`): a `Busy` thread's next fair slow-path `collect` either
drops the level / takes `c`, or makes it `Quiet` (`collect_level`, from `quiet_epoch`).
Three applications (levels 2, 1, 0) give `Taken`, and `FairFrom`'s to-do clause gives `ran`. -/
theorem fair_stable (ex : Nat → St) (hex : Exec ex) (hr : Reachable (ex 0)) (N0 : Nat)
    (hst : StableFrom ex N0) (hne : ∃ t, ((ex N0).threads t).isSome) (hf : FairFrom ex N0)
    (c : Cb) (hid : c.byId = false) (n0 : Nat) (hn0 : N0 ≤ n0) (hc : c ∈ bufs (ex n0)) :
    ∃ m, c ∈ (ex m).ran :=
  fair_stable_busy ex hex hr N0 hst hne c (hf.busyFair hst c) hf.2 hid n0 hn0 hc

/-! ## `busy_count == 0` iff `threads` is empty -/

/-- **`busy_count == 0` iff `threads.is_empty()`**, so `register`'s test `busy_count == 0` is
the same as `threads.is_empty()`. -/
theorem busy_zero_iff_empty {s : St} (h : Reachable s) : s.busy = 0 ↔ allNone s.threads := by
  rw [busy_zero_iff (reachable_cinv h)]
  constructor
  · intro hnb u
    apply Classical.byContradiction; intro hu
    obtain ⟨w, hw⟩ := reachable_hasBusy h ⟨u, hu⟩
    exact hnb w hw
  · intro ha u hu; simp [ha u] at hu

/-! ## Fairness -/

/-- Some thread completes a slow-path `collect` (from `Registered` or `Unregistered`) at step
`m`. -/
def CollAt (ex : Nat → St) (m : Nat) : Prop :=
  ∃ t, ((ex m).loc t = .registered ∧ ex (m + 1) = startCollect t true (quiet t 2 (ex m))) ∨
    ((ex m).loc t = .unregistered ∧ ex (m + 1) = startCollect t false (collectUnreg (ex m)))

/-- A thread that is `Busy` while `c` stays queued eventually completes a slow-path `collect`
or stops being `Busy` (for example by `release`). `BusyFair` without the stable suffix. -/
def BusyFairAll (ex : Nat → St) (c : Cb) : Prop :=
  ∀ w m, (ex m).threads w = some .busy → (∀ j, m ≤ j → c ∈ bufs (ex j)) →
    ∃ m2, m ≤ m2 ∧ (CollectsAt ex w m2 ∨ (ex m2).threads w ≠ some .busy)

/-- While `c` stays queued and is in `pending` or no thread is registered, some thread
eventually completes a slow-path `collect`. Needed for `c` in `pending` (a `Busy` thread may
`release` instead of collecting) and while no thread is registered. -/
def CollectFair (ex : Nat → St) (c : Cb) : Prop :=
  ∀ m, (∀ j, m ≤ j → c ∈ bufs (ex j) ∧ (c ∈ (ex j).pending ∨ allNone (ex j).threads)) →
    ∃ m2, m ≤ m2 ∧ CollAt ex m2

/-! ## Per-step lemmas -/

theorem quiet_keys (t : Tid) : ∀ fuel (s : St) u, s.threads u ≠ none →
    (quiet t fuel s).1.threads u ≠ none
  | 0, _, _, h => h
  | fuel + 1, s, u, h => by
    simp only [quiet]
    split
    · simpa [takePending] using h
    · split
      · exact quiet_keys t fuel _ u (by simpa [takePending] using markQuiet_threads_ne h)
      · simpa [takePending] using markQuiet_threads_ne h

theorem collect_taken {c : Cb} (hid : c.byId = false) (t : Tid) (s : St) (h : c ∈ s.pending) :
    Taken c (startCollect t true (quiet t 2 s)) :=
  taken_startCollect hid t true _ ((quiet_epoch t 1 s c).1 h)

theorem collectUnreg_taken {c : Cb} (hid : c.byId = false) (t : Tid) (s : St)
    (h : c ∈ s.pending ∨ (allNone s.threads ∧ c ∈ bufs s)) :
    Taken c (startCollect t false (collectUnreg s)) := by
  apply taken_startCollect hid
  unfold collectUnreg
  rcases h with h | ⟨ha, h⟩
  · split <;> simp [h]
  · simp only [ha, ite_true]; simp only [bufs, List.mem_append] at h ⊢; grind

theorem unregister_pending {c : Cb} {s : St} (t : Tid) (h : c ∈ s.pending) :
    c ∈ (unregister s t).pending := by
  unfold unregister completeEpoch; dsimp only
  split <;> (try split) <;> (try split) <;> simp [h]

/-- A queued `c` stays queued unless it is taken into a to-do list. -/
theorem step_fwd {c : Cb} (hid : c.byId = false) {s s' : St} (hs : Step s s')
    (h : c ∈ bufs s) : Taken c s' ∨ c ∈ bufs s' := by
  cases hs with
    | pinRegister t _ => right; simpa [register, bufs] using h
    | release t _ => exact .inr (unregister_mem_fwd _ t c (by simpa [bufs] using h))
    | collectReg t _ =>
      rw [quietRust_eq]
      obtain ⟨hp, he⟩ := quiet_epoch t 1 s c
      simp only [bufs, List.mem_append] at h
      rcases h with (h | h) | h
      · exact .inl (taken_startCollect hid t true _ (hp h))
      · rcases he with ⟨-, hcur, -, -⟩ | ⟨-, h2⟩
        · right; simp [startCollect, bufs, hcur, h]
        · rcases h2 h with h | h | h
          · right; simp [startCollect, bufs, h]
          · right; simp [startCollect, bufs, h]
          · exact .inl (taken_startCollect hid t true _ h)
      · rcases he with ⟨-, -, hprev, -⟩ | ⟨h1, -⟩
        · right; simp [startCollect, bufs, hprev, h]
        · exact .inl (taken_startCollect hid t true _ (h1 h))
    | collectUnreg t _ =>
      by_cases ha : allNone s.threads
      · exact .inl (collectUnreg_taken hid t s (.inr ⟨ha, h⟩))
      · simp only [bufs, List.mem_append] at h
        rcases h with (h | h) | h
        · exact .inl (collectUnreg_taken hid t s (.inl h))
        · right; simp [collectUnreg, ha, startCollect, bufs, h]
        · right; simp [collectUnreg, ha, startCollect, bufs, h]
    | defer => right; simp only [bufs, List.mem_append] at h ⊢; grind
    | cancel ids => right; simpa [bufs, cancelList, hid] using h
    | _ => right; simpa [bufs] using h

/-- `c` in `pending` stays there until a slow-path `collect` takes it. -/
theorem step_pending {c : Cb} (hid : c.byId = false) {s s' : St} (hs : Step s s')
    (h : c ∈ s.pending) : Taken c s' ∨ c ∈ s'.pending := by
  cases hs with
    | pinRegister t _ => right; simpa [register] using h
    | release t _ => exact .inr (unregister_pending t h)
    | collectReg t _ => rw [quietRust_eq]; exact .inl (collect_taken hid t s h)
    | collectUnreg t _ => exact .inl (collectUnreg_taken hid t s (.inl h))
    | cancel ids => right; simpa [cancelList, hid] using h
    | _ => right; simpa using h

/-- Good at level `k`: `c` is in `pending`, or at level `k` with some thread registered. -/
def Good (c : Cb) (k : Nat) (s : St) : Prop := c ∈ s.pending ∨ (Lv c k s ∧ ¬ allNone s.threads)

theorem unregister_level {c : Cb} {k : Nat} {s : St} {t : Tid} (hc : CInv s)
    (_hk : k ≠ 0) (hL : Lv c k s) :
    Good c (k - 1) (unregister s t) ∨
      (Lv c k (unregister s t) ∧ ¬ allNone (unregister s t).threads ∧
        Shr s.threads (unregister s t).threads) := by
  have shr : Shr s.threads (upd s.threads t none) := fun u hu => by
    by_cases h : u = t
    · subst h; simp at hu
    · simpa [h] using hu
  have ep : ∀ s0 : St, s0.pending = s.pending → s0.previous = s.previous →
      s0.current = s.current → Good c (k - 1) (completeEpoch s0) := by
    intro s0 a b d
    unfold completeEpoch; split
    · left; simp only [Lv] at hL; simp only [a, b, d, List.mem_append]
      rcases hL with h | ⟨_, h⟩ | ⟨_, h⟩ <;> simp [h]
    · rename_i hna; right; refine ⟨?_, ?_⟩
      · simp only [Lv] at hL ⊢; simp only [a, b, d, List.mem_append]
        rcases hL with h | ⟨_, h⟩ | ⟨_, h⟩
        · exact .inl (.inl h)
        · exact .inl (.inr h)
        · exact .inr (.inl ⟨by omega, h⟩)
      · intro hall; apply hna; intro u; have := hall u
        cases h : s0.threads u <;> simp_all
  dsimp only [unregister]
  split
  · rename_i hb; split
    · exact .inl (ep _ rfl rfl rfl)
    · rename_i h0; right
      refine ⟨hL, ?_, shr⟩
      obtain ⟨u, hu⟩ := not_noBusy (mt (busy_last_iff hc hb (v := none) (by simp)).2 h0)
      intro hall; have := hall u; simp_all
  · split
    · exact .inl (ep _ rfl rfl rfl)
    · rename_i hna; exact .inr ⟨hL, hna, shr⟩

/-- One step at level `k ≥ 1` with some thread registered: `c` is taken, becomes good at
level `k - 1`, or keeps its level, some thread stays registered and the `Busy` set only
shrinks. Unlike `step_level` no stability is needed: `register` adds a `Quiet` thread, and
`threads` can only become empty through an epoch completion. -/
theorem step_level' {c : Cb} (hid : c.byId = false) {k : Nat} (hk : k ≠ 0) {s s' : St}
    (hr : Reachable s) (hs : Step s s') (hne : ¬ allNone s.threads) (hL : Lv c k s) :
    Taken c s' ∨ Good c (k - 1) s' ∨
      (Lv c k s' ∧ ¬ allNone s'.threads ∧ Shr s.threads s'.threads) := by
  obtain ⟨hi, hc⟩ := reachable_inv_cinv hr
  have reg : ∀ t, s.loc t = .registered → s.threads t ≠ none := fun t hl => by
    have := hi.reg t; rw [hl] at this; simpa [LS.isReg, Option.isSome_iff_ne_none] using this
  have same : ∀ s' : St, s'.pending = s.pending → s'.previous = s.previous →
      s'.current = s.current → s'.threads = s.threads →
      Taken c s' ∨ Good c (k - 1) s' ∨
        (Lv c k s' ∧ ¬ allNone s'.threads ∧ Shr s.threads s'.threads) :=
    fun s' a b d e => .inr (.inr ⟨by simp only [Lv, a, b, d]; exact hL, by rw [e]; exact hne,
      by rw [e]; exact fun _ h => h⟩)
  cases hs with
    | pinRegister t hl =>
      have h0 : s.busy ≠ 0 := fun h0 => hne ((busy_zero_iff_empty hr).1 h0)
      refine .inr (.inr ⟨by simpa [Lv, register] using hL,
        fun hall => by simpa [register] using hall t, fun u hu => ?_⟩)
      by_cases h : u = t
      · subst h; simp [register, h0] at hu
      · simpa [register, h] using hu
    | release t hl =>
      rcases unregister_level (t := t) (cinv_of (s' := { s with loc := upd s.loc t .unregistered })
        hc rfl rfl rfl) hk hL with h | h
      · exact .inr (.inl h)
      · exact .inr (.inr h)
    | collectReg t hl =>
      rw [quietRust_eq]
      have hne' : ¬ allNone (startCollect t true (quiet t 2 s)).threads := fun hall =>
        quiet_keys t 2 s t (reg t hl) (by simpa [startCollect] using hall t)
      rcases collect_level hid k s t hL with h | ⟨-, h⟩ | ⟨-, a, b, -⟩
      · exact .inl h
      · exact .inr (.inl (.inr ⟨h, hne'⟩))
      · exact .inr (.inr ⟨a, hne', b⟩)
    | collectUnreg t _ =>
      rcases hL with h | h
      · exact .inl (collectUnreg_taken hid t s (.inl h))
      · refine .inr (.inr ⟨?_, ?_, ?_⟩) <;> simp only [collectUnreg, hne, ite_false, startCollect]
        · exact .inr h
        · exact not_false
        · exact fun _ h => h
    | defer =>
      refine .inr (.inr ⟨?_, hne, fun _ h => h⟩)
      simp only [Lv, List.mem_append] at hL ⊢
      rcases hL with h | h | ⟨a, b⟩
      · exact .inl h
      · exact .inr (.inl h)
      · exact .inr (.inr ⟨a, .inl b⟩)
    | cancel ids =>
      refine .inr (.inr ⟨?_, hne, fun _ h => h⟩)
      simpa [Lv, cancelList, hid] using hL
    | pinOuter => exact same _ rfl rfl rfl rfl
    | pinNest => exact same _ rfl rfl rfl rfl
    | unpinNest => exact same _ rfl rfl rfl rfl
    | unpinOuter => exact same _ rfl rfl rfl rfl
    | runOne => exact same _ rfl rfl rfl rfl
    | finish => exact same _ rfl rfl rfl rfl

/-- `busy_count` counts the `Busy` entries over any duplicate-free list containing them. -/
theorem busy_eq_of {s : St} (hc : CInv s) (L : List Tid) (hn : L.Nodup)
    (hL : ∀ u, s.threads u = some .busy → u ∈ L) : s.busy = countBusy s.threads L := by
  obtain ⟨L0, hn0, hm0, -, hb0⟩ := hc
  rw [hb0]; unfold countBusy
  apply List.Perm.length_eq
  apply (List.perm_ext_iff_of_nodup (hn0.filter _) (hn.filter _)).2
  intro u; simp only [List.mem_filter, decide_eq_true_eq]
  constructor
  · rintro ⟨-, h⟩; exact ⟨hL u h, h⟩
  · rintro ⟨-, h⟩; exact ⟨(hm0 u).2 (by simp [h]), h⟩

/-- A shrinking `Busy` set that loses `w` lowers `busy_count`, even if keys were added. -/
theorem busy_lt {s s' : St} (hc : CInv s) (hc' : CInv s') (h : Shr s.threads s'.threads) {w}
    (hw : s.threads w = some .busy) (hw' : s'.threads w ≠ some .busy) : s'.busy < s.busy := by
  have e := busy_eq_of hc'
  obtain ⟨L, hn, hm, -, hb⟩ := hc
  rw [e L hn (fun u hu => (hm u).2 (by simp [h u hu])), hb]
  exact countBusy_lt h hw hw' L ((hm w).2 (by simp [hw]))

/-! ## Fair liveness -/

theorem ge_induction {P : Nat → Prop} {m : Nat} (h0 : P m) (hs : ∀ j, m ≤ j → P j → P (j + 1)) :
    ∀ j, m ≤ j → P j := by
  have : ∀ d, P (m + d) := by
    intro d
    induction d with
    | zero => exact h0
    | succ d ih => exact hs _ (Nat.le_add_right m d) ih
  intro j hj
  have := this (j - m); rwa [show m + (j - m) = j by omega] at this

/-- **Fair liveness.** A closure (`byId = false`, so never cancelled) queued at some point
eventually runs in every fair execution, with threads free to `release` and re-register at
any time. Fairness is `BusyFairAll`, `CollectFair` and the to-do clause.

Proof: as `fair_stable`, but the measure is `busy_count` instead of the number of `Busy`
keys of a fixed key set. Every step at level `k ≥ 1` with some thread registered takes `c`,
drops its level or only shrinks the `Busy` set (`step_level'`); `register` cannot grow it there
(`busy_zero_iff_empty`). Some thread is then `Busy` (`reachable_hasBusy`), and `BusyFairAll` makes it
`Quiet` or drop the level, lowering `busy_count` (`busy_lt`). In `pending` (level 0) and while
no thread is registered, `CollectFair` gives a `collect` that takes `c`. -/
theorem fair (ex : Nat → St) (hex : Exec ex) (hr : Reachable (ex 0)) (c : Cb)
    (hid : c.byId = false) (hb : BusyFairAll ex c) (hcol : CollectFair ex c)
    (htodo : ∀ n t w l, (ex n).loc t = .collecting w l → ∀ x ∈ l, ∃ m, x ∈ (ex m).ran)
    (n0 : Nat) (hc : c ∈ bufs (ex n0)) : ∃ m, c ∈ (ex m).ran := by
  apply Classical.byContradiction; intro hnr
  have nt : ∀ m, ¬ Taken c (ex m) := fun m ⟨t, w, l, hl, hx⟩ => hnr (htodo m t w l hl c hx)
  have reach := Exec.reach hex hr
  have hbufs : ∀ j, n0 ≤ j → c ∈ bufs (ex j) := by
    refine ge_induction hc fun j _ ih => ?_
    rcases hex j with h | h
    · rcases step_fwd hid h ih with h | h
      · exact absurd h (nt _)
      · exact h
    · rw [h]; exact ih
  have hbufs' : ∀ m, n0 ≤ m → ∀ j, m ≤ j → c ∈ bufs (ex j) :=
    fun m hm j hj => hbufs j (by omega)
  -- Level 0: the next slow-path `collect` takes `c`.
  have L0 : ∀ m, n0 ≤ m → c ∈ (ex m).pending → False := by
    intro m hm hp
    have pers : ∀ j, m ≤ j → c ∈ (ex j).pending := by
      refine ge_induction hp fun j _ ih => ?_
      rcases hex j with h | h
      · rcases step_pending hid h ih with h | h
        · exact absurd h (nt _)
        · exact h
      · rw [h]; exact ih
    obtain ⟨m2, hm2, t, h⟩ := hcol m fun j hj => ⟨hbufs j (by omega), .inl (pers j hj)⟩
    rcases h with ⟨-, he⟩ | ⟨-, he⟩
    · exact nt (m2 + 1) (he ▸ collect_taken hid t _ (pers m2 hm2))
    · exact nt (m2 + 1) (he ▸ collectUnreg_taken hid t _ (.inl (pers m2 hm2)))
  -- Levels `k ≥ 1`: strong induction on `busy_count`.
  have LP : ∀ k, k ≠ 0 → ∀ v m, n0 ≤ m → Good c k (ex m) → (ex m).busy = v →
      ∃ m', m ≤ m' ∧ Good c (k - 1) (ex m') := by
    intro k hk v
    induction v using Nat.strongRecOn with
    | _ v IH =>
    intro m hm hG hv
    rcases hG with hp | ⟨hlv, hne⟩
    · exact ⟨m, Nat.le_refl _, .inl hp⟩
    apply Classical.byContradiction
    intro H
    have H' : ∀ m', m ≤ m' → ¬ Good c (k - 1) (ex m') := fun m' h h1 => H ⟨m', h, h1⟩
    have pers : ∀ j, Lv c k (ex (m + j)) ∧ ¬ allNone (ex (m + j)).threads ∧
        Shr (ex m).threads (ex (m + j)).threads := by
      intro j
      induction j with
      | zero => exact ⟨hlv, hne, fun _ h => h⟩
      | succ j ih =>
        rcases hex (m + j) with hs | hs
        · rcases step_level' hid hk (reach _) hs ih.2.1 ih.1 with h | h | ⟨a, b, d⟩
          · exact absurd h (nt _)
          · exact absurd h (H' _ (by omega))
          · exact ⟨a, b, fun u hu => ih.2.2 u (d u hu)⟩
        · rw [show m + (j + 1) = m + j + 1 by omega, hs]; exact ih
    have persAt : ∀ p, m ≤ p → Lv c k (ex p) ∧ ¬ allNone (ex p).threads ∧
        Shr (ex m).threads (ex p).threads := fun p hp => by
      have := pers (p - m); rwa [show m + (p - m) = p by omega] at this
    -- some thread is `Busy` at `m`
    obtain ⟨u0, hu0⟩ : ∃ u, (ex m).threads u ≠ none :=
      Classical.byContradiction fun h => hne fun u =>
        Classical.byContradiction fun h' => h ⟨u, h'⟩
    obtain ⟨w, hw⟩ := reachable_hasBusy (reach m) ⟨u0, hu0⟩
    obtain ⟨m2, hm2, hcm⟩ := hb w m hw (hbufs' m hm)
    -- a later point `p` where `w` is no longer `Busy`
    obtain ⟨p, hp, hpw⟩ : ∃ p, m ≤ p ∧ (ex p).threads w ≠ some .busy := by
      obtain hcol | hnb := hcm
      · by_cases hb2 : (ex m2).threads w = some .busy
        · have := collect_level hid k (ex m2) w (persAt m2 hm2).1
          rw [← hcol.2] at this
          rcases this with h | ⟨-, h⟩ | ⟨-, -, -, h⟩
          · exact absurd h (nt _)
          · exact absurd (.inr ⟨h, (persAt (m2 + 1) (by omega)).2.1⟩) (H' _ (by omega))
          · exact ⟨m2 + 1, by omega, h⟩
        · exact ⟨m2, hm2, hb2⟩
      · exact ⟨m2, hm2, hnb⟩
    have hpp := persAt p hp
    have hlt : (ex p).busy < v :=
      hv ▸ busy_lt (reachable_cinv (reach m)) (reachable_cinv (reach p)) hpp.2.2 hw hpw
    obtain ⟨m', hm', h⟩ := IH _ hlt p (by omega) (.inr ⟨hpp.1, hpp.2.1⟩) rfl
    exact H ⟨m', by omega, h⟩
  -- While no thread is registered, the next slow-path `collect` takes `c`.
  obtain ⟨m, hm, hne⟩ : ∃ m, n0 ≤ m ∧ ¬ allNone (ex m).threads := by
    apply Classical.byContradiction; intro H
    have hall : ∀ j, n0 ≤ j → allNone (ex j).threads := fun j hj =>
      Classical.byContradiction fun h => H ⟨j, hj, h⟩
    obtain ⟨m2, hm2, t, h⟩ := hcol n0 fun j hj => ⟨hbufs j hj, .inr (hall j hj)⟩
    rcases h with ⟨hl, -⟩ | ⟨-, he⟩
    · have := (reachable_inv_cinv (reach m2)).1.reg t
      rw [hl, hall m2 hm2 t] at this; simp [LS.isReg] at this
    · exact nt (m2 + 1)
        (he ▸ collectUnreg_taken hid t _ (.inr ⟨hall m2 hm2, hbufs m2 hm2⟩))
  have h2 : Good c 2 (ex m) := by
    have := hbufs m hm
    simp only [bufs, List.mem_append] at this
    refine .inr ⟨?_, hne⟩
    rcases this with (h | h) | h
    · exact .inl h
    · exact .inr (.inr ⟨by omega, h⟩)
    · exact .inr (.inl ⟨by omega, h⟩)
  obtain ⟨m1, hm1, g1⟩ := LP 2 (by omega) _ m hm h2 rfl
  obtain ⟨m2, hm2, g0⟩ := LP 1 (by omega) _ m1 (by omega) g1 rfl
  rcases g0 with h | ⟨h, -⟩
  · exact L0 m2 (by omega) h
  · rcases h with h | ⟨h, -⟩ | ⟨h, -⟩
    · exact L0 m2 (by omega) h
    · omega
    · omega

end Fair
end Collect
