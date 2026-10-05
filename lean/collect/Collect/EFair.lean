import Collect.Fair
import Collect.Events

/-!
# Fair (trace) liveness on the primary model

`Fair.lean` works on the base `Step`, where `collect_cold` may run at any time. Here the
executions are of the primary model `Ev.EStep`, where `collect_cold` runs only when
`collect`'s load of `EVENTS` differs from `seen_events` (`src/collect.rs`, `collect`), and
fairness is on `collect` *calls* (`CallsAt`), which may take the fast path. See MAPPING.md,
section "Fair liveness", variants 3 and 3'.

Main results:
* `efair_stable`: with registration eventually stable, fairness on `collect` calls
  (`EFairFrom`) and no wrap-around at a call (`NoWrapAt`), every queued closure runs.
  `efair_bounded`: the same with `total + 1 < W` (fewer than `W - 1` events) instead.
* `wrap_starves` / `efair_needs_nowrap`: `NoWrapAt` cannot be dropped. For every `W ≥ 1`, a
  thread whose calls come exactly `W` events apart always takes the fast path and starves a
  closure, with all other hypotheses of `efair_stable` satisfied.
* `efair`: threads may `release` and re-register at any time. Under `EFairAll` (registered
  threads call `collect` or unregister, `collect` is called infinitely often) and
  `NoWrapAny`, every queued closure runs.

The key invariant is `NewsInv.news`: a `Busy` thread outside a split has `seen_events`
(unwrapped) strictly behind `EVENTS` while a callback is queued. Every step that makes a
thread `Busy` without bumping `EVENTS` leaves nothing queued (`quiet2_news`, `quiet2_self`,
`unregister_news`), and `pin_cold`'s forced store `EVENTS - 1` covers registration with
callbacks queued. So a `Busy` thread's call sees news (`fast_path_detects`), which yields
`Fair.BusyFair` (`busyFair`), and `Fair.fair_stable_busy` finishes. For `efair`, the
invariant `PendInv` adds that while `c` is in `pending` (or nothing is registered) every
caller sees news, which yields `Fair.CollectFair`; `Fair.fair` finishes.
-/

namespace Collect
namespace EFair

open Ev Fair

theorem allNone_upd_false {th : Tid → Option TS} {t : Tid} {v : TS} : ¬ allNone (upd th t (some v)) :=
  fun h => by simpa using h t

/-- After `collect_cold`'s locked `quiet` by `t0`, a `Busy` thread with callbacks still
queued was already `Busy` (and a callback queued) before, or `quiet` bumped `EVENTS`. -/
theorem quiet2_news (t0 : Tid) (s : St) (t : Tid)
    (hb : (quiet t0 2 s).1.threads t = some .busy) (hne : bufs (quiet t0 2 s).1 ≠ []) :
    (t ≠ t0 ∧ s.threads t = some .busy ∧ bufs s ≠ []) ∨ 0 < qBump t0 s := by
  by_cases h0 : s.threads t0 = some .busy
  · by_cases h1 : s.busy - 1 = 0
    · by_cases hc : s.current = []
      · simp [quiet, markQuiet, takePending, completeEpoch, h0, h1, hc, allNone_upd_false, bufs] at hne
      · right; simp [qBump, ceBump, h0, h1, hc, allNone_upd_false]
    · left
      have hq : (quiet t0 2 s).1 = { s with threads := upd s.threads t0 (some .quiet), busy := s.busy - 1, pending := [] } := by
        simp [quiet, markQuiet, takePending, h0, h1]
      rw [hq] at hb hne
      by_cases ht : t = t0
      · subst ht; simp at hb
      · refine ⟨ht, by simpa [ht] using hb, fun e => hne ?_⟩
        simp [bufs] at e ⊢; simp [e]
  · left
    have hq : (quiet t0 2 s).1 = { s with pending := [] } := by simp [quiet, takePending, h0]
    rw [hq] at hb hne
    refine ⟨fun e => h0 (e ▸ hb), hb, fun e => hne ?_⟩
    simp [bufs] at e ⊢; simp [e]

/-- After `quiet` by `t0`, if `t0` itself is `Busy` (an epoch completed in the last level),
nothing is queued. -/
theorem quiet2_self (t0 : Tid) (s : St) (hb : (quiet t0 2 s).1.threads t0 = some .busy) :
    bufs (quiet t0 2 s).1 = [] := by
  by_cases h0 : s.threads t0 = some .busy
  · by_cases h1 : s.busy - 1 = 0
    · by_cases hc : s.current = []
      · simp [quiet, markQuiet, takePending, completeEpoch, h0, h1, hc, allNone_upd_false, bufs]
      · by_cases h2 : s.len - 1 = 0
        · simp [quiet, markQuiet, takePending, completeEpoch, h0, h1, hc, h2, allNone_upd_false, bufs]
        · simp [quiet, markQuiet, takePending, completeEpoch, h0, h1, hc, h2, allNone_upd_false] at hb
    · simp [quiet, markQuiet, takePending, h0, h1] at hb
  · simp [quiet, takePending, h0] at hb

theorem unregister_news (s : St) (t0 t : Tid)
    (hb : (unregister s t0).threads t = some .busy) (hne : bufs (unregister s t0) ≠ []) :
    (s.threads t = some .busy ∧ bufs s ≠ []) ∨ 0 < unregBump s t0 := by
  have hcomp : ∀ s' : St, ¬ allNone s'.threads → bufs (completeEpoch s') ≠ [] →
      0 < ceBump true s' := fun s' hna h => by
    simp only [completeEpoch, hna, ite_false, bufs] at h
    simp only [ceBump, hna, ite_false]
    split
    · omega
    · rename_i hn; exfalso; apply h; simp_all
  have hnone : ∀ s' : St, allNone s'.threads → (completeEpoch s').threads t ≠ some .busy :=
    fun s' ha => by simp [completeEpoch, ha, ha t]
  dsimp only [unregister] at hb hne
  by_cases h0 : s.threads t0 = some .busy
  · by_cases h1 : s.busy - 1 = 0
    · simp only [h0, h1, ite_true] at hb hne
      by_cases ha : allNone (upd s.threads t0 none)
      · exact absurd hb (hnone _ ha)
      · right; simp only [unregBump, h0, h1, ite_true]; exact hcomp _ ha hne
    · simp only [h0, h1, ite_true, ite_false] at hb hne
      have ht : t ≠ t0 := by rintro rfl; simp at hb
      exact .inl ⟨by simpa [ht] using hb, by simpa [bufs] using hne⟩
  · simp only [h0, ite_false] at hb hne
    by_cases ha : allNone (upd s.threads t0 none)
    · simp only [ha, ite_true] at hb; exact absurd hb (hnone _ ha)
    · simp only [ha, ite_false] at hb hne
      have ht : t ≠ t0 := by rintro rfl; simp at hb
      exact .inl ⟨by simpa [ht] using hb, by simpa [bufs] using hne⟩

theorem unregister_loc (s : St) (t : Tid) : (unregister s t).loc = s.loc := by
  dsimp only [unregister]; split <;> (try split) <;> simp [completeEpoch] <;> split <;> rfl

theorem hasCbs_bufs {s : St} (h : hasCbs s = false) : bufs s = [] := by
  simp [hasCbs, bufs] at h ⊢; simp [h]

variable (W : Nat)

/-- Invariant behind the fast-path argument: a `Busy` thread that is not inside a split
(`pin_cold`'s forced store pending, or between `collect_cold`'s store and the lock) has
`seen_events` strictly behind `EVENTS` (unwrapped) whenever a callback is queued. So its next
`collect` check sees news, unless the gap is a multiple of `W` (`fast_path_detects`). Also
`fpend` threads are pinned and `gseen ≥ -1`. -/
structure NewsInv (e : ESt) : Prop where
  fp : ∀ t, e.fpend t = true → ∃ st d, e.base.loc t = .pinned st d
  lo : ∀ t, -1 ≤ e.gseen t
  news : ∀ t, e.base.threads t = some .busy → e.fpend t = false → e.mid t = false →
    bufs e.base ≠ [] → e.gseen t < e.total

theorem newsInv_init : NewsInv einit :=
  ⟨fun _ h => by simp [einit] at h, fun _ => by simp [einit], fun _ h => by simp [einit, init] at h⟩

theorem fp_notReg {e : ESt} (h : NewsInv e) {t : Tid} (hl : e.base.loc t = .registered ∨
    e.base.loc t = .unregistered ∨ ∃ w l, e.base.loc t = .collecting w l) : e.fpend t = false := by
  cases hf : e.fpend t
  · rfl
  · obtain ⟨st, d, hp⟩ := h.fp t hf
    rcases hl with hl | hl | ⟨w, l, hl⟩ <;> rw [hl] at hp <;> cases hp

/-- `newsInv_step` from the facts it uses about `e` (counter invariant and a reachable
projection), so that it also applies to other runs of `EStep` (`RC11Live`). -/
theorem newsInv_step' {e e' : ESt} (hsi : SeenInv W e) (hrb : Reachable e.base) (h : NewsInv e)
    (hs : EStep W e e') : NewsInv e' := by
  obtain ⟨hfp, hlo, hnw⟩ := h
  -- steps that change at most `t0`'s local state
  have locOnly : ∀ (t0 : Tid) (l : LS), (e.fpend t0 = true → ∃ st d, l = .pinned st d) →
      NewsInv { e with base := { e.base with loc := upd e.base.loc t0 l } } := by
    intro t0 l hl
    refine ⟨fun u hu => ?_, hlo, fun u a b d f => hnw u a b d f⟩
    by_cases hu' : u = t0
    · subst hu'; obtain ⟨st, d, h⟩ := hl hu; exact ⟨st, d, by simp [h]⟩
    · simpa [hu'] using hfp u hu
  cases hs with
  | pinRegister t0 hl hm hc =>
    simp only [register]
    refine ⟨fun u hu => ?_, hlo, fun u a b d f => ?_⟩
    · by_cases hu' : u = t0
      · subst hu'; exact ⟨e.base.now, 0, by simp⟩
      · simpa [hu'] using hfp u (by simpa [hu'] using hu)
    · by_cases hu' : u = t0
      · subst hu'
        simp only [upd_same] at b
        exact absurd (hasCbs_bufs b) (by simpa [bufs] using f)
      · simp only [upd_other _ _ _ _ hu'] at a b
        exact hnw u a b d (by simpa [bufs] using f)
  | pinForce t0 hf =>
    refine ⟨fun u hu => ?_, fun u => ?_, fun u a b d f => ?_⟩
    · by_cases hu' : u = t0
      · subst hu'; simp at hu
      · simpa [setSeen, hu'] using hfp u (by simpa [setSeen, hu'] using hu)
    · by_cases hu' : u = t0
      · subst hu'; simp [setSeen]; omega
      · simpa [setSeen, hu'] using hlo u
    · by_cases hu' : u = t0
      · subst hu'; simp [setSeen]; omega
      · simp only [setSeen, upd_other _ _ _ _ hu'] at a b d f ⊢
        exact hnw u a b d f
  | pinOuter t0 hl hm hc =>
    refine ⟨fun u hu => ?_, hlo, fun u a b d f => hnw u a b d f⟩
    by_cases hu' : u = t0
    · subst hu'; exact ⟨e.base.now, 0, by simp⟩
    · simpa [hu'] using hfp u hu
  | pinNest t0 st d hl hf => exact locOnly t0 _ fun _ => ⟨_, _, rfl⟩
  | unpinNest t0 st d hl hf => exact locOnly t0 _ fun _ => ⟨_, _, rfl⟩
  | unpinOuter t0 st hl hf => exact locOnly t0 _ fun h => by rw [hf] at h; cases h
  | runOne t0 w c cs hl =>
    refine ⟨fun u hu => ?_, hlo, fun u a b d f => hnw u a b d f⟩
    by_cases hu' : u = t0
    · subst hu'; rw [fp_notReg ⟨hfp, hlo, hnw⟩ (.inr (.inr ⟨_, _, hl⟩))] at hu; cases hu
    · simpa [hu'] using hfp u hu
  | finish t0 w hl =>
    refine ⟨fun u hu => ?_, hlo, fun u a b d f => hnw u a b d f⟩
    by_cases hu' : u = t0
    · subst hu'; rw [fp_notReg ⟨hfp, hlo, hnw⟩ (.inr (.inr ⟨_, _, hl⟩))] at hu; cases hu
    · simpa [hu'] using hfp u hu
  | cancel ids =>
    refine ⟨hfp, hlo, fun u a b d f => hnw u a b d fun e => f ?_⟩
    simp [bufs, cancelList] at e ⊢
    obtain ⟨e1, e2, e3⟩ := e; simp [e1, e2, e3]
  | defer id byId =>
    refine ⟨hfp, hlo, fun u a b d _ => ?_⟩
    have := (hsi u).2; simp only at this ⊢; omega
  | collectFast => exact ⟨hfp, hlo, hnw⟩
  | collectCheck t0 => exact ⟨hfp, hlo, hnw⟩
  | collectStore t0 hc =>
    refine ⟨fun u hu => ?_, fun u => ?_, fun u a b d f => ?_⟩
    · simpa [setSeen] using hfp u (by simpa [setSeen] using hu)
    · by_cases hu' : u = t0
      · subst hu'; simp [setSeen]
      · simpa [setSeen, hu'] using hlo u
    · by_cases hu' : u = t0
      · subst hu'; simp at d
      · simp only [setSeen, upd_other _ _ _ _ hu'] at a b d f ⊢
        exact hnw u a b d f
  | release t0 hl hm hc =>
    have hf0 := fp_notReg ⟨hfp, hlo, hnw⟩ (.inl hl)
    refine ⟨fun u hu => ?_, hlo, fun u a b d f => ?_⟩
    · by_cases hu' : u = t0
      · subst hu'; rw [hf0] at hu; cases hu
      · obtain ⟨st, d, h⟩ := hfp u hu; exact ⟨st, d, by rw [unregister_loc]; simpa [hu'] using h⟩
    · simp only at a b d f ⊢
      have := (hsi u).2
      rcases unregister_news _ t0 u a f with ⟨a', f'⟩ | hpos
      · have := hnw u a' b d (by simpa [bufs] using f'); omega
      · omega
  | collectReg t0 hl hm =>
    have hf0 := fp_notReg ⟨hfp, hlo, hnw⟩ (.inl hl)
    have hfp' : ∀ u, e.fpend u = true → ∃ st d, (startCollect t0 true (quietRust t0 e.base)).loc u = .pinned st d := by
      intro u hu
      by_cases hu' : u = t0
      · subst hu'; rw [hf0] at hu; cases hu
      · obtain ⟨st, d, h⟩ := hfp u hu
        exact ⟨st, d, by simp [startCollect, quietRust_eq, quiet_loc, hu', h]⟩
    have hnw' : ∀ u, u ≠ t0 → (startCollect t0 true (quietRust t0 e.base)).threads u = some .busy →
        e.fpend u = false → e.mid u = false → bufs (startCollect t0 true (quietRust t0 e.base)) ≠ [] →
        e.gseen u < e.total ∨ e.gseen u < e.total + qBump t0 e.base := by
      intro u hu a b d f
      simp only [startCollect, quietRust_eq] at a f
      rcases quiet2_news t0 e.base u a (by simpa [bufs] using f) with ⟨-, a', f'⟩ | hpos
      · exact .inl (hnw u a' b d f')
      · have := (hsi u).2; right; omega
    have hself : (startCollect t0 true (quietRust t0 e.base)).threads t0 = some .busy →
        bufs (startCollect t0 true (quietRust t0 e.base)) ≠ [] → False := by
      intro a f
      simp only [startCollect, quietRust_eq] at a f
      exact f (by simpa [bufs] using quiet2_self t0 e.base a)
    dsimp only
    split
    · refine ⟨fun u hu => hfp' u (by simpa [setSeen] using hu), fun u => ?_, fun u a b d f => ?_⟩
      · by_cases hu' : u = t0
        · subst hu'; simp [setSeen]; omega
        · simpa [setSeen, hu'] using hlo u
      · by_cases hu' : u = t0
        · subst hu'; exact (hself a f).elim
        · simp only [setSeen, upd_other _ _ _ _ hu'] at a b d f ⊢
          have := hnw' u hu' a b d f; omega
    · refine ⟨hfp', hlo, fun u a b d f => ?_⟩
      by_cases hu' : u = t0
      · subst hu'; exact (hself a f).elim
      · simp only [upd_other _ _ _ _ hu'] at a b d f ⊢
        have := hnw' u hu' a b d f; omega
  | collectUnreg t0 hl hm =>
    have hf0 := fp_notReg ⟨hfp, hlo, hnw⟩ (.inr (.inl hl))
    have hn0 := (Collect.threads_consistent hrb t0).1 hl
    have hth : (Collect.collectUnreg e.base).1.threads = e.base.threads := by
      unfold Collect.collectUnreg; split <;> rfl
    refine ⟨fun u hu => ?_, hlo, fun u a b d f => ?_⟩
    · by_cases hu' : u = t0
      · subst hu'; rw [hf0] at hu; cases hu
      · obtain ⟨st, d, h⟩ := hfp u hu
        refine ⟨st, d, ?_⟩
        simp only [startCollect, upd_other _ _ _ _ hu']
        unfold Collect.collectUnreg; split <;> exact h
    · simp only [startCollect, hth] at a
      have hu' : u ≠ t0 := by rintro rfl; rw [hn0] at a; cases a
      simp only [upd_other _ _ _ _ hu'] at d
      refine hnw u a b d fun e0 => f ?_
      simp only [startCollect, bufs]
      unfold Collect.collectUnreg; split <;> simp_all [bufs]

theorem newsInv_step {e e' : ESt} (hr : EReach W e) (h : NewsInv e) (hs : EStep W e e') :
    NewsInv e' :=
  newsInv_step' W (ereach_seenInv W hr) (ereach_base W hr) h hs

theorem ereach_newsInv {e : ESt} (h : EReach W e) : NewsInv e := by
  induction h with
  | init => exact newsInv_init
  | step hr hs ih => exact newsInv_step W hr ih hs

/-! ## Fair executions of the primary model -/

/-- An infinite execution of the primary model (stuttering allowed). -/
def EExec (ex : Nat → ESt) : Prop := ∀ n, EStep W (ex n) (ex (n + 1)) ∨ ex (n + 1) = ex n

/-- The base-model projection of an execution. -/
def proj (ex : Nat → ESt) : Nat → St := fun n => (ex n).base

/-- Thread `t` calls `collect` from `Registered` at step `m`: step `m` is `collect`'s
`Acquire` load of `EVENTS`, which takes the fast path (`EStep.collectFast`, a stutter) iff it
equals `seen_events`, and otherwise enters `collect_cold` (`EStep.collectCheck`). -/
def CallsAt (ex : Nat → ESt) (t : Tid) (m : Nat) : Prop :=
  (ex m).base.loc t = .registered ∧ (ex m).mid t = false ∧ (ex m).chk t = false ∧
    ex (m + 1) = if events W (ex m) = (ex m).seen t then ex m
                 else { ex m with chk := upd (ex m).chk t true }

/-- Fairness on the primary model, from step `N0`:
* every thread registered at `N0` *calls* `collect` from `Registered` infinitely often (each
  call may take the fast path; nothing forces `collect_cold`);
* a `collect_cold` entered from `Registered` completes its locked part (`collectStore` and
  then the locked `quiet`, which is `Fair.CollectsAt` on the projection);
* every to-do list is eventually run. -/
def EFairFrom (ex : Nat → ESt) (N0 : Nat) : Prop :=
  (∀ t, ((ex N0).base.threads t).isSome → ∀ n, ∃ m, n ≤ m ∧ CallsAt W ex t m) ∧
  (∀ n t, (ex n).chk t = true → (ex n).base.loc t = .registered →
    ∃ m, n ≤ m ∧ CollectsAt (proj ex) t m) ∧
  (∀ n t w l, (ex n).base.loc t = .collecting w l → ∀ x ∈ l, ∃ m, x ∈ (ex m).base.ran)

/-- No wrap-around at `collect` calls: when a thread calls `collect`, fewer than `W` events
happened (unwrapped) since its `seen_events` was taken. -/
def NoWrapAt (ex : Nat → ESt) : Prop :=
  ∀ m t, CallsAt W ex t m → ((ex m).total : Int) - (ex m).gseen t < W

theorem EExec.exec {ex : Nat → ESt} (hex : EExec W ex) : Exec (proj ex) := fun n => by
  rcases hex n with h | h
  · rcases estep_base W h with h' | h'
    · exact .inr h'
    · exact .inl h'
  · exact .inr (by simp [proj, h])

theorem EExec.reach {ex : Nat → ESt} (hex : EExec W ex) (hr : EReach W (ex 0)) :
    ∀ n, EReach W (ex n)
  | 0 => hr
  | n + 1 => by
    rcases hex n with h | h
    · exact .step (EExec.reach hex hr n) h
    · rw [h]; exact EExec.reach hex hr n

/-- **The fast path does not starve a `Busy` thread** (without wrap-around): fairness on
`collect` calls gives `Fair.BusyFair`. A `Busy` thread's call while a callback is queued sees
news (`NewsInv`, `fast_path_detects`), so it enters `collect_cold`, which completes. -/
theorem busyFair {ex : Nat → ESt} (hex : EExec W ex) (hr : EReach W (ex 0)) {N0 : Nat}
    (hst : StableFrom (proj ex) N0) (hf : EFairFrom W ex N0) (hnw : NoWrapAt W ex) (c : Cb) :
    BusyFair (proj ex) N0 c := by
  intro w m hm hw hq
  have hwN : ((ex N0).base.threads w).isSome := by
    rw [show (ex N0).base = proj ex N0 from rfl, ← stable_at hst m hm w]; simp [hw]
  obtain ⟨m1, hm1, hl, hmid, hchk, hnext⟩ := hf.1 w hwN m
  by_cases hb : (ex m1).base.threads w = some .busy
  · have hri := EExec.reach W hex hr m1
    have hinv := ereach_newsInv W hri
    have hfp := fp_notReg hinv (.inl hl)
    have hlt := hinv.news w hb hfp hmid (fun h => by
      have := hq m1 hm1; simp only [proj] at this; rw [h] at this; cases this)
    have hne := fast_path_detects W hri w hlt (hnw m1 w ⟨hl, hmid, hchk, hnext⟩)
    simp only [hne, ite_false] at hnext
    obtain ⟨m2, hm2, hcol⟩ := hf.2.1 (m1 + 1) w (by rw [hnext]; simp) (by rw [hnext]; exact hl)
    exact ⟨m2, by omega, .inl hcol⟩
  · exact ⟨m1, hm1, .inr hb⟩

/-- **Fair liveness on the primary model, stable registration, no wrap-around.** In an
infinite execution of `Ev.EStep` from a reachable state, where registration is stable from
`N0` on (at least one thread registered), every registered thread calls `collect` infinitely
often (fast path allowed), every started `collect_cold` completes, every to-do list runs, and
no `collect` call happens `W` or more events after the caller's `seen_events` was taken, a
closure (`byId = false`) queued after `N0` eventually runs.

Proof: `busyFair` turns fairness on calls into `Fair.BusyFair` on the projection, and
`Fair.fair_stable_busy` does the rest. Without `NoWrapAt` this is false in spirit: exactly `W`
defers between a `Busy` thread's calls make every call take the fast path
(`Ev.defer_W_misses`, `Ev.fast_path_misses_iff`), so it never quiets. -/
theorem efair_stable (ex : Nat → ESt) (hex : EExec W ex) (hr : EReach W (ex 0)) (N0 : Nat)
    (hst : StableFrom (proj ex) N0) (hne : ∃ t, ((ex N0).base.threads t).isSome)
    (hf : EFairFrom W ex N0) (hnw : NoWrapAt W ex)
    (c : Cb) (hid : c.byId = false) (n0 : Nat) (hn0 : N0 ≤ n0) (hc : c ∈ bufs (ex n0).base) :
    ∃ m, c ∈ (ex m).base.ran :=
  fair_stable_busy (proj ex) (hex.exec W) (ereach_base W hr) N0 hst hne c
    (busyFair W hex hr hst hf hnw c) hf.2.2 hid n0 hn0 hc

/-- `efair_stable` with a bound on the number of events instead of `NoWrapAt`: if the
execution does fewer than `W - 1` `EVENTS` bumps in total (`total + 1 < W` throughout; on
64-bit, `W = 2^64`), no `collect` call can miss an event, since `gseen ≥ -1`
(`NewsInv.lo`). -/
theorem efair_bounded (ex : Nat → ESt) (hex : EExec W ex) (hr : EReach W (ex 0)) (N0 : Nat)
    (hst : StableFrom (proj ex) N0) (hne : ∃ t, ((ex N0).base.threads t).isSome)
    (hf : EFairFrom W ex N0) (hbd : ∀ n, (ex n).total + 1 < W)
    (c : Cb) (hid : c.byId = false) (n0 : Nat) (hn0 : N0 ≤ n0) (hc : c ∈ bufs (ex n0).base) :
    ∃ m, c ∈ (ex m).base.ran :=
  efair_stable W ex hex hr N0 hst hne hf (fun m t _ => by
    have := (ereach_newsInv W (EExec.reach W hex hr m)).lo t
    have := hbd m; omega) c hid n0 hn0 hc

/-! ## Unstable registration -/

/-- `c` sits in `pending`, or nothing is registered while something is queued. Then no
`Busy` thread may be left to take it, so every caller of `collect` must see news. -/
def Stuck (s : St) : Prop := s.pending ≠ [] ∨ (allNone s.threads ∧ bufs s ≠ [])

/-- Invariant: while `Stuck`, every thread outside a split (`mid`, `fpend`) has `seen_events`
(unwrapped) strictly behind `EVENTS`. Whatever makes the state `Stuck` bumps `EVENTS`
(`complete_epoch(true)` in `unregister`, `defer`), and a `collect_cold` that stores `EVENTS`
leaves it not `Stuck`. -/
def PendInv (e : ESt) : Prop :=
  Stuck e.base → ∀ t, e.mid t = false → e.fpend t = false → e.gseen t < e.total

theorem completeEpoch_stuck {x : St} (h : ceBump true x = 0) : ¬ Stuck (completeEpoch x) := by
  unfold ceBump at h; unfold completeEpoch Stuck bufs
  by_cases ha : allNone x.threads
  · simp only [ha, ite_true] at h ⊢
    split at h
    · cases h
    · rename_i hn; simp at hn; simp [hn]
  · simp only [ha, ite_false] at h ⊢
    split at h
    · cases h
    · rename_i hn
      simp only [not_or, Decidable.not_not, true_and] at hn
      obtain ⟨h1, h2⟩ := hn
      simp only [List.append_eq_nil_iff] at h1
      intro hs; rcases hs with hs | ⟨hs, -⟩
      · simp [h1.1, h1.2] at hs
      · apply ha; intro u; have := hs u; cases hh : x.threads u <;> simp_all

/-- Without a bump, `unregister` makes the state `Stuck` only if it already was, with the
same `pending`. -/
theorem unregister_stuck {s : St} {t : Tid} (hc : CInv s) (h0 : unregBump s t = 0)
    (hs : Stuck (unregister s t)) : s.pending ≠ [] := by
  by_cases hb : s.threads t = some .busy
  · by_cases h1 : s.busy - 1 = 0
    · simp only [unregBump, hb, h1, ite_true] at h0
      simp only [unregister, hb, h1, ite_true] at hs
      exact absurd hs (completeEpoch_stuck h0)
    · simp only [unregister, hb, h1, ite_true, ite_false] at hs
      rcases hs with hs | ⟨ha, -⟩
      · exact hs
      · obtain ⟨u, hu⟩ := not_noBusy (mt (busy_last_iff hc hb (v := none) (by simp)).2 h1)
        have := ha u; simp_all
  · by_cases ha : allNone (upd s.threads t none)
    · simp only [unregBump, hb, ha, ite_true, ite_false] at h0
      simp only [unregister, hb, ha, ite_true, ite_false] at hs
      exact absurd hs (completeEpoch_stuck h0)
    · simp only [unregister, hb, ha, ite_false] at hs
      rcases hs with hs | ⟨ha', -⟩
      · exact hs
      · exact absurd ha' ha

theorem pendInv_init : PendInv einit := fun h => by
  simp [Stuck, einit, init, bufs] at h

/-- `pendInv_step` from the counter invariant and a reachable projection. -/
theorem pendInv_step' {e e' : ESt} (hsi : SeenInv W e) (hb : Reachable e.base) (h : PendInv e)
    (hs : EStep W e e') : PendInv e' := by
  cases hs with
  | pinRegister t0 hl hm hc =>
    intro hp u a f
    have hp' : e.base.pending ≠ [] := by
      rcases hp with hp | ⟨ha, -⟩
      · simpa [register] using hp
      · simpa [register] using ha t0
    by_cases hu : u = t0
    · subst hu; simp [hasCbs] at f; exact (hp' f.1.1).elim
    · exact h (.inl hp') u a (by simpa [hu] using f)
  | pinForce t0 hf =>
    intro hp u a f
    by_cases hu : u = t0
    · subst hu; simp [setSeen]; omega
    · simp only [setSeen, upd_other _ _ _ _ hu] at a f ⊢; exact h hp u a f
  | pinOuter | pinNest | unpinNest | unpinOuter | runOne | finish => exact h
  | collectFast | collectCheck => exact h
  | cancel ids =>
    intro hp; apply h
    simp only [Stuck, bufs] at hp ⊢
    rcases hp with hp | ⟨ha, hb'⟩
    · exact .inl fun e0 => hp (by simp [e0, cancelList])
    · refine .inr ⟨ha, fun e0 => hb' ?_⟩
      simp only [List.append_eq_nil_iff] at e0 ⊢; simp [e0, cancelList]
  | defer => intro _ u _ _; have := (hsi u).2; simp only at this ⊢; omega
  | collectStore t0 hc =>
    intro hp u a f
    by_cases hu : u = t0
    · subst hu; simp at a
    · simp only [setSeen, upd_other _ _ _ _ hu] at a f ⊢; exact h hp u a f
  | release t0 hl hm hc =>
    intro hp u a f
    have := (hsi u).2
    show e.gseen u < ((e.total + unregBump { e.base with loc := upd e.base.loc t0 .unregistered } t0 : Nat) : Int)
    simp only at hp
    by_cases h0 : unregBump { e.base with loc := upd e.base.loc t0 .unregistered } t0 = 0
    · have := unregister_stuck (cinv_of (s' := { e.base with loc := upd e.base.loc t0 .unregistered })
        (reachable_cinv hb) rfl rfl rfl) h0 hp
      have := h (.inl this) u a f; omega
    · omega
  | collectReg t0 hl hm =>
    have hk := (threads_consistent hb t0).2 hl
    have hns : ¬ Stuck (startCollect t0 true (quietRust t0 e.base)) := by
      rw [quietRust_eq]; intro hs
      rcases hs with hs | ⟨ha, -⟩
      · exact hs (by simpa [startCollect] using quiet_pending_nil t0 1 e.base)
      · exact quiet_keys t0 2 e.base t0 hk (by simpa [startCollect] using ha t0)
    dsimp only; split
    · intro hp; exact absurd hp hns
    · intro hp; exact absurd hp hns
  | collectUnreg t0 hl hm =>
    intro hp; exfalso
    simp only [Stuck, startCollect, bufs] at hp
    unfold Collect.collectUnreg at hp
    split at hp
    · simp at hp
    · rename_i hna; rcases hp with hp | ⟨ha, -⟩
      · exact hp rfl
      · exact hna ha

theorem pendInv_step {e e' : ESt} (hr : EReach W e) (h : PendInv e) (hs : EStep W e e') :
    PendInv e' :=
  pendInv_step' W (ereach_seenInv W hr) (ereach_base W hr) h hs

theorem ereach_pendInv {e : ESt} (h : EReach W e) : PendInv e := by
  induction h with
  | init => exact pendInv_init
  | step hr hs ih => exact pendInv_step W hr ih hs

/-- Thread `t` calls `collect` (from `Registered` or `Unregistered`) at step `m`. -/
def CallsAnyAt (ex : Nat → ESt) (t : Tid) (m : Nat) : Prop :=
  ((ex m).base.loc t = .registered ∨ (ex m).base.loc t = .unregistered) ∧
    (ex m).mid t = false ∧ (ex m).chk t = false ∧
    ex (m + 1) = if events W (ex m) = (ex m).seen t then ex m
                 else { ex m with chk := upd (ex m).chk t true }

/-- Thread `t` completes the locked part of `collect_cold` from `Unregistered` at step `m`. -/
def CollectsUnregAt (ex : Nat → St) (t : Tid) (m : Nat) : Prop :=
  (ex m).loc t = .unregistered ∧ ex (m + 1) = startCollect t false (collectUnreg (ex m))

/-- Fairness on the primary model with threads free to `release` and re-register:
* a registered thread eventually calls `collect` from `Registered` or unregisters;
* `collect` is called infinitely often (by some thread, registered or not);
* a started `collect_cold` completes its locked part;
* every to-do list is eventually run. -/
def EFairAll (ex : Nat → ESt) : Prop :=
  (∀ t n, (ex n).base.threads t ≠ none →
    ∃ m, n ≤ m ∧ (CallsAt W ex t m ∨ (ex m).base.threads t = none)) ∧
  (∀ n, ∃ m t, n ≤ m ∧ CallsAnyAt W ex t m) ∧
  (∀ n t, (ex n).chk t = true → (ex n).base.loc t = .registered →
    ∃ m, n ≤ m ∧ CollectsAt (proj ex) t m) ∧
  (∀ n t, (ex n).chk t = true → (ex n).base.loc t = .unregistered →
    ∃ m, n ≤ m ∧ CollectsUnregAt (proj ex) t m) ∧
  (∀ n t w l, (ex n).base.loc t = .collecting w l → ∀ x ∈ l, ∃ m, x ∈ (ex m).base.ran)

/-- No wrap-around at any `collect` call. -/
def NoWrapAny (ex : Nat → ESt) : Prop :=
  ∀ m t, CallsAnyAt W ex t m → ((ex m).total : Int) - (ex m).gseen t < W

theorem busyFairAll {ex : Nat → ESt} (hex : EExec W ex) (hr : EReach W (ex 0))
    (hf : EFairAll W ex) (hnw : NoWrapAny W ex) (c : Cb) : BusyFairAll (proj ex) c := by
  intro w m hw hq
  obtain ⟨m1, hm1, hcall | hnone⟩ := hf.1 w m (by simp [proj] at hw; simp [hw])
  · obtain ⟨hl, hmid, hchk, hnext⟩ := hcall
    by_cases hb : (ex m1).base.threads w = some .busy
    · have hri := EExec.reach W hex hr m1
      have hinv := ereach_newsInv W hri
      have hlt := hinv.news w hb (fp_notReg hinv (.inl hl)) hmid (fun h => by
        have := hq m1 hm1; simp only [proj] at this; rw [h] at this; cases this)
      have hne := fast_path_detects W hri w hlt (hnw m1 w ⟨.inl hl, hmid, hchk, hnext⟩)
      simp only [hne, ite_false] at hnext
      obtain ⟨m2, hm2, hcol⟩ := hf.2.2.1 (m1 + 1) w (by rw [hnext]; simp) (by rw [hnext]; exact hl)
      exact ⟨m2, by omega, .inl hcol⟩
    · exact ⟨m1, hm1, .inr hb⟩
  · exact ⟨m1, hm1, .inr (by simp [proj, hnone])⟩

theorem collectFair {ex : Nat → ESt} (hex : EExec W ex) (hr : EReach W (ex 0))
    (hf : EFairAll W ex) (hnw : NoWrapAny W ex) (c : Cb) : CollectFair (proj ex) c := by
  intro m hq
  obtain ⟨m1, t, hm1, hcall⟩ := hf.2.1 m
  obtain ⟨hl, hmid, hchk, hnext⟩ := hcall
  have hri := EExec.reach W hex hr m1
  have hinv := ereach_newsInv W hri
  have hst : Stuck (ex m1).base := by
    obtain ⟨hb, hp | ha⟩ := hq m1 hm1
    · exact .inl fun e => by simp [proj, e] at hp
    · exact .inr ⟨ha, fun e => by simp [proj, e] at hb⟩
  have hlt := ereach_pendInv W hri hst t hmid
    (fp_notReg hinv (by rcases hl with h | h; exact .inl h; exact .inr (.inl h)))
  have hne := fast_path_detects W hri t hlt (hnw m1 t ⟨hl, hmid, hchk, hnext⟩)
  simp only [hne, ite_false] at hnext
  rcases hl with hl | hl
  · obtain ⟨m2, hm2, hc1, hc2⟩ := hf.2.2.1 (m1 + 1) t (by rw [hnext]; simp) (by rw [hnext]; exact hl)
    exact ⟨m2, by omega, t, .inl ⟨hc1, hc2⟩⟩
  · obtain ⟨m2, hm2, hc1, hc2⟩ := hf.2.2.2.1 (m1 + 1) t (by rw [hnext]; simp) (by rw [hnext]; exact hl)
    exact ⟨m2, by omega, t, .inr ⟨hc1, hc2⟩⟩

/-- **Fair liveness on the primary model, no wrap-around.** In an infinite execution of
`Ev.EStep` from a reachable state, with threads free to `release` and re-register at any
time, a closure (`byId = false`) queued at some point eventually runs, provided `EFairAll`
(registered threads call `collect` or unregister, `collect` is called infinitely often,
started `collect_cold`s complete, to-do lists run) and no `collect` call happens `W` or more
events after the caller's `seen_events` was taken.

Proof: `busyFairAll` (`NewsInv`: a `Busy` caller sees news) and `collectFair` (`PendInv`: while
`c` is in `pending` or nothing is registered, every caller sees news) give the base-model
hypotheses of `Fair.fair`. -/
theorem efair (ex : Nat → ESt) (hex : EExec W ex) (hr : EReach W (ex 0)) (hf : EFairAll W ex)
    (hnw : NoWrapAny W ex) (c : Cb) (hid : c.byId = false) (n0 : Nat)
    (hc : c ∈ bufs (ex n0).base) : ∃ m, c ∈ (ex m).base.ran :=
  fair (proj ex) (hex.exec W) (ereach_base W hr) c hid (busyFairAll W hex hr hf hnw c)
    (collectFair W hex hr hf hnw c) hf.2.2.2.2 n0 hc

/-! ## Wrap-around refutes the statement without `NoWrapAt` -/

/-- The `EStep.defer` successor (closure `⟨0, now, false⟩`). -/
def deferE (e : ESt) : ESt :=
  { e with base := { e.base with now := e.base.now + 1,
                                 current := e.base.current ++ [⟨0, e.base.now, false⟩] }
           total := e.total + 1 }

/-- Start: thread 0 registered and `Busy` with `seen_events = 0`, closure `⟨0, 1, false⟩`
deferred (one event). -/
def wstart : ESt :=
  { base := { now := 2, loc := upd (fun _ => .unregistered) 0 .registered,
              threads := upd (fun _ => none) 0 (some .busy), len := 1, busy := 1,
              pending := [], current := [⟨0, 1, false⟩], previous := [], ran := [] }
    total := 1, seen := fun _ => 0, gseen := fun _ => 0, mid := fun _ => false,
    chk := fun _ => false, fpend := fun _ => false }

theorem wstart_reach : EReach W wstart := by
  have r1 := EReach.step (W := W) .init (EStep.pinRegister einit 0 rfl rfl rfl)
  have r2 := EReach.step r1 (EStep.unpinOuter _ 0 0 (by simp [register, einit, init]) (by simp [hasCbs, einit, init]))
  have r3 := EReach.step r2 (EStep.defer _ 0 false)
  refine (fun e (h : EReach W e) (he : e = wstart) => he ▸ h) _ r3 ?_
  simp only [wstart, einit, init, hasCbs, register]
  have h1 : upd (upd (fun _ => LS.unregistered) 0 (LS.pinned 0 0)) 0 LS.registered =
      upd (fun _ => LS.unregistered) 0 LS.registered := by
    funext u; by_cases hu : u = 0 <;> simp [upd, hu]
  have h2 : upd (fun _ => false) 0 (!(([] : List Cb).isEmpty && ([] : List Cb).isEmpty &&
      ([] : List Cb).isEmpty)) = fun _ => false := by
    funext u; by_cases hu : u = 0 <;> simp [upd, hu]
  rw [h1, h2]; rfl

/-- The schedule, with the number of defers left before thread 0's next `collect` call:
`W - 1` defers, then the call, then `W` defers and a call, forever. -/
def wseq : Nat → ESt × Nat
  | 0 => (wstart, W - 1)
  | n + 1 => match wseq n with
    | (e, 0) => (e, W)
    | (e, k + 1) => (deferE e, k)

theorem wseq_inv (hW : 0 < W) : ∀ n, (wseq W n).1.base.loc = wstart.base.loc ∧
    (wseq W n).1.base.threads = wstart.base.threads ∧ (wseq W n).1.mid = wstart.mid ∧
    (wseq W n).1.chk = wstart.chk ∧ (wseq W n).1.seen = wstart.seen ∧
    (wseq W n).1.base.ran = [] ∧ ⟨0, 1, false⟩ ∈ (wseq W n).1.base.current ∧
    ∃ j, (wseq W n).1.total + (wseq W n).2 = W * j
  | 0 => ⟨rfl, rfl, rfl, rfl, rfl, rfl, by simp [wseq, wstart], 1, by simp [wseq, wstart]; omega⟩
  | n + 1 => by
    obtain ⟨a, b, d, f, g, i, k, j, hj⟩ := wseq_inv hW n
    simp only [wseq]
    split
    · rename_i e h; rw [h] at a b d f g i k hj
      exact ⟨a, b, d, f, g, i, k, j + 1, by simp at hj ⊢; rw [Nat.mul_succ]; omega⟩
    · rename_i e k' h; rw [h] at a b d f g i k hj
      exact ⟨a, b, d, f, g, i, by simp [deferE, k], j, by simp [deferE] at hj ⊢; omega⟩

/-- **Wrap-around starvation on the primary model.** For every width `W ≥ 1` there is an
infinite execution of `Ev.EStep` from a reachable state in which registration never changes
(only thread 0 is registered, and it stays `Busy`), thread 0 calls `collect` infinitely often,
no `collect_cold` is ever entered (so the other `EFairFrom` clauses hold vacuously), yet a
closure stays queued and never runs. Thread 0's calls come exactly `W` events apart, so every
one takes the fast path. Hence `NoWrapAt` (or a bound such as `efair_bounded`'s) cannot be
dropped from `efair_stable`. -/
theorem wrap_starves (hW : 0 < W) : ∃ (ex : Nat → ESt) (c : Cb), EReach W (ex 0) ∧ EExec W ex ∧
    StableFrom (proj ex) 0 ∧ ((ex 0).base.threads 0).isSome ∧ EFairFrom W ex 0 ∧
    c.byId = false ∧ (∀ n, c ∈ (ex n).base.current ∧ c ∉ (ex n).base.ran) := by
  have hi := wseq_inv W hW
  -- every state has a later call
  have calls : ∀ k n, (wseq W n).2 = k → ∃ m, n ≤ m ∧ (wseq W m).2 = 0 := by
    intro k
    induction k with
    | zero => exact fun n h => ⟨n, Nat.le_refl _, h⟩
    | succ k ih =>
      intro n h
      have : (wseq W (n + 1)).2 = k := by
        simp only [wseq]; split <;> simp_all
      obtain ⟨m, hm, h'⟩ := ih (n + 1) this
      exact ⟨m, by omega, h'⟩
  have callAt : ∀ m, (wseq W m).2 = 0 → CallsAt W (fun n => (wseq W n).1) 0 m := by
    intro m h
    obtain ⟨a, -, d, f, g, -, -, j, hj⟩ := hi m
    have hev : events W (wseq W m).1 = (wseq W m).1.seen 0 := by
      rw [g, h] at *; simp only [Nat.add_zero] at hj
      simp [events, hj, wstart]
    refine ⟨by rw [a]; simp [wstart], by rw [d]; simp [wstart],
      by rw [f]; simp [wstart], ?_⟩
    simp only [hev, ite_true]
    simp only [wseq]; split <;> simp_all
  refine ⟨fun n => (wseq W n).1, ⟨0, 1, false⟩, wstart_reach W, fun n => ?_, fun n _ u => ?_,
    by simp [wseq, wstart], ⟨fun t ht n => ?_, fun n t h => ?_, fun n t w l h => ?_⟩,
    rfl, fun n => ⟨(hi n).2.2.2.2.2.2.1, by rw [(hi n).2.2.2.2.2.1]; simp⟩⟩
  · simp only [wseq]; split
    · rename_i e h; rw [h]; exact .inr rfl
    · rename_i e k h; rw [h]; exact .inl (EStep.defer e 0 false)
  · simp only [proj, (hi (n + 1)).2.1, (hi 0).2.1]
  · obtain ⟨m, hm, h⟩ := calls _ n rfl
    have ht0 : t = 0 := by
      rw [(hi 0).2.1] at ht; by_cases h0 : t = 0
      · exact h0
      · simp [wstart, upd, h0] at ht
    exact ⟨m, hm, ht0 ▸ callAt m h⟩
  · rw [(hi n).2.2.2.1] at h; simp [wstart] at h
  · rw [(hi n).1] at h
    by_cases ht : t = 0 <;> simp [wstart, upd, ht] at h

/-- `wrap_starves` as the negation of `efair_stable` without `NoWrapAt`. -/
theorem efair_needs_nowrap (hW : 0 < W) : ¬ ∀ (ex : Nat → ESt) (N0 : Nat), EExec W ex →
    EReach W (ex 0) → StableFrom (proj ex) N0 → (∃ t, ((ex N0).base.threads t).isSome) →
    EFairFrom W ex N0 → ∀ c : Cb, c.byId = false → ∀ n0, N0 ≤ n0 → c ∈ bufs (ex n0).base →
    ∃ m, c ∈ (ex m).base.ran := by
  intro H
  obtain ⟨ex, c, hr, hex, hst, h0, hf, hid, hnot⟩ := wrap_starves W hW
  obtain ⟨m, hm⟩ := H ex 0 hex hr hst ⟨0, h0⟩ hf c hid 0 (Nat.le_refl _)
    (by simp [bufs, (hnot 0).1])
  exact (hnot m).2 hm

end EFair
end Collect
