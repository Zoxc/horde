import Collect.EFair

/-!
# Headline theorems, stated on the primary model

The primary model is `Collect.Ev.EStep` / `Collect.Ev.EReach` (`Events.lean`): the base
transition system plus the wrapping `EVENTS` counter of width `W`, every thread's
`seen_events`, both of `collect`'s loads, `pin_cold`'s forced store outside the lock and
`quiet`'s store before its recursive call. No assumption about `EVENTS` is left.

The base model (`Model.lean`, `Safety.lean`, `Progress.lean`) is only used as an abstraction:
every primary step projects to a base step or a stutter (`Ev.estep_base`), so invariants of
the base model transfer.
-/

namespace Collect
namespace Main

open Ev

variable {W : Nat}

/-- The inductive invariant holds in every reachable state of the primary model. -/
theorem inv {e : ESt} (h : EReach W e) : Inv e.base :=
  reachable_inv (ereach_base W h)

/-- **Reclamation safety.** Every callback that has been run, or flag marked ready, was
deferred strictly before the start of every pinned region that is still active. -/
theorem safety {e : ESt} (h : EReach W e) (c : Cb) (hc : c ∈ e.base.ran) (u : Tid) :
    ¬ blocked e.base.loc c u :=
  esafety W h c hc u

/-- Safety at the moment a closure is run or a flag is marked ready. -/
theorem safety_step {e e' : ESt} (h : EReach W e) (hs : EStep W e e') (c : Cb)
    (hc : c ∈ e'.base.ran) (u : Tid) : ¬ blocked e'.base.loc c u :=
  safety (.step h hs) c hc u

/-- **No panics from the `Collector` asserts and unwraps.** -/
theorem threads_consistent {e : ESt} (h : EReach W e) (t : Tid) :
    (e.base.loc t = .unregistered → e.base.threads t = none) ∧
    (e.base.loc t = .registered → e.base.threads t ≠ none) :=
  Collect.threads_consistent (ereach_base W h) t

/-- **`busy_count` is exact.** The keys of `threads` are a finite duplicate-free list `L`,
`threads.len() = L.length` and `busy_count` is the number of `Busy` entries. In particular
`busy_count == 0` iff no entry is `Busy`. -/
theorem busy_count {e : ESt} (h : EReach W e) :
    CInv e.base ∧ (e.base.busy = 0 ↔ noBusy e.base.threads) ∧ e.base.busy ≤ e.base.len :=
  have hc := reachable_cinv (ereach_base W h)
  ⟨hc, busy_zero_iff hc, busy_le_len hc⟩

/-- **`busy_count -= 1` never underflows**, neither in `unregister` (`release`) nor in `quiet`
(any nesting depth). -/
theorem busy_count_no_underflow {e : ESt} (h : EReach W e) (t : Tid) :
    (e.base.loc t = .registered → e.base.threads t = some .busy → 0 < e.base.busy) ∧
    ∀ fuel, QuietOk t fuel e.base :=
  ⟨fun hl => (unregister_no_underflow (ereach_base W h) hl).1,
   quiet_no_underflow (ereach_base W h) t⟩

/-- The state after `cancel_by_ids ids` (the `EStep.cancel` successor). -/
def cancelE (e : ESt) (ids : List Nat) : ESt :=
  { e with base := { e.base with
                      pending := cancelList ids e.base.pending
                      current := cancelList ids e.base.current
                      previous := cancelList ids e.base.previous } }

/-- **`cancel_by_ids` is effective.** The step is always enabled, and afterwards no flag with a
cancelled id is queued. Flags are only marked inside the lock, from the queues, so a cancelled
flag is not written later unless it is deferred again. -/
theorem cancel_effective (e : ESt) (ids : List Nat) (c : Cb) (hid : c.byId = true)
    (hmem : c.id ∈ ids) : EStep W e (cancelE e ids) ∧ c ∉ bufs (cancelE e ids).base := by
  refine ⟨EStep.cancel e ids, ?_⟩
  have := Collect.cancel_effective e.base ids c hid hmem
  simp only [cancelE, bufs, List.mem_append, not_or]; exact ⟨⟨this.1, this.2.1⟩, this.2.2⟩

/-- A callback handed to `collect_cold`'s locked part ends up marked ready (flag) or in the
thread's to-do list (closure). -/
theorem startCollect_mem (t : Tid) (w : Bool) (r : St × List Cb) (c : Cb) (hc : c ∈ r.2) :
    c ∈ (startCollect t w r).ran ∨
      ∃ l, (startCollect t w r).loc t = .collecting w l ∧ c ∈ l := by
  cases hb : c.byId
  · right; exact ⟨r.2.filter (fun c => !c.byId), by simp [startCollect], by simp [hc, hb]⟩
  · left; simp [startCollect, hc, hb]

/-- **Unregistered `collect` with no registered threads takes everything.** A thread that is
past `collect`'s `EVENTS` check and the store into `seen_events` (`mid`) takes the lock and
receives every queued callback. -/
theorem collectUnreg_takes_all {e : ESt} (t : Tid) (hl : e.base.loc t = .unregistered)
    (hm : e.mid t = true) (hn : allNone e.base.threads) (c : Cb) (hc : c ∈ bufs e.base) :
    ∃ e', EStep W e e' ∧ bufs e'.base = [] ∧
      (c ∈ e'.base.ran ∨ ∃ l, e'.base.loc t = .collecting false l ∧ c ∈ l) := by
  have ⟨h1, h2⟩ := Collect.collectUnreg_takes_all e.base hn c hc
  refine ⟨_, EStep.collectUnreg e t hl hm, ?_, startCollect_mem t false _ c h1⟩
  simpa [startCollect, bufs] using h2

/-- **The last busy thread to quiesce takes `previous` and `pending`.** -/
theorem last_quiet_takes_previous {e : ESt} (h : EReach W e) (t : Tid) (hl : e.base.loc t = .registered)
    (hm : e.mid t = true) (hb : e.base.threads t = some .busy)
    (hlast : ∀ u, u ≠ t → e.base.threads u ≠ some .busy) (c : Cb)
    (hc : c ∈ e.base.previous ∨ c ∈ e.base.pending) :
    ∃ e', EStep W e e' ∧
      (c ∈ e'.base.ran ∨ ∃ l, e'.base.loc t = .collecting true l ∧ c ∈ l) := by
  refine ⟨_, EStep.collectReg e t hl hm, ?_⟩
  have := startCollect_mem t true _ c (Collect.last_quiet_takes_previous e.base
    (reachable_cinv (ereach_base W h)) t hb hlast c hc)
  rw [quietRust_eq] at *; dsimp only; split <;> exact this

/-- **`collect` reaches the lock when there is news.** From a reachable state where `t` may call
`collect` and at least one but fewer than `W` events happened since its `seen_events` was
taken, `collect`'s check fails and `collect_cold` stores the new value and reaches the lock. -/
theorem collect_slow_path {e : ESt} (h : EReach W e) (t : Tid)
    (hl : e.base.loc t = .registered ∨ e.base.loc t = .unregistered)
    (hm : e.mid t = false) (hc : e.chk t = false)
    (hnew : e.gseen t < e.total) (hnowrap : (e.total : Int) - e.gseen t < W) :
    ∃ e', ESteps W e e' ∧ e'.mid t = true ∧ e'.base = e.base ∧ e'.seen t = events W e := by
  have hne := fast_path_detects W h t hnew hnowrap
  refine ⟨_, .tail (.tail (.refl e) (EStep.collectCheck e t hl hm hc hne))
    (EStep.collectStore _ t (by simp)), by simp, rfl, by simp [setSeen, events]⟩

/-- **Reclamation is always possible (an existential, not a liveness property).** From any
reachable state of the primary model, *some* finite continuation runs the queued callback
`c`. It says nothing about every execution: the witness schedule chooses the interleaving,
makes every thread `release` and may add one environment `defer` (MAPPING.md, assumption 5).
Proved in `Ev.eventually_ran_events`. For "every fair execution runs `c`" see
`fair_liveness`. -/
theorem reclaim_possible {e : ESt} (h : EReach W e) (hW : 1 < W) (c : Cb)
    (hc : c ∈ bufs e.base) : ∃ e', ESteps W e e' ∧ c ∈ e'.base.ran :=
  eventually_ran_events W h hW c hc

/-- **Fair liveness, primary model.** In every infinite execution of `Ev.EStep` from a
reachable state where registration is stable from `N0` on (some thread registered), every
registered thread calls `collect` infinitely often (fast path allowed), every started
`collect_cold` completes, every to-do list runs, and no `collect` call comes `W` or more
events after the caller's `seen_events` was taken (`EFair.NoWrapAt`), every closure queued
after `N0` eventually runs. `EFair.efair_stable`; see also `EFair.efair_bounded`. -/
theorem fair_liveness (ex : Nat → ESt) (hex : EFair.EExec W ex) (hr : EReach W (ex 0))
    (N0 : Nat) (hst : Fair.StableFrom (EFair.proj ex) N0)
    (hne : ∃ t, ((ex N0).base.threads t).isSome) (hf : EFair.EFairFrom W ex N0)
    (hnw : EFair.NoWrapAt W ex) (c : Cb) (hid : c.byId = false) (n0 : Nat) (hn0 : N0 ≤ n0)
    (hc : c ∈ bufs (ex n0).base) : ∃ m, c ∈ (ex m).base.ran :=
  EFair.efair_stable W ex hex hr N0 hst hne hf hnw c hid n0 hn0 hc

/-- **Fair liveness, primary model, registration unstable.** Threads may `release` and
re-register at any time. In every infinite execution of `Ev.EStep` from a reachable state
where every registered thread eventually calls `collect` or unregisters, `collect` is called
infinitely often (by some thread, fast path allowed), every started `collect_cold` completes,
every to-do list runs, and no `collect` call comes `W` or more events after the caller's
`seen_events` was taken (`EFair.NoWrapAny`), every queued closure eventually runs.
`EFair.efair`. -/
theorem fair_liveness_unstable (ex : Nat → ESt) (hex : EFair.EExec W ex) (hr : EReach W (ex 0))
    (hf : EFair.EFairAll W ex) (hnw : EFair.NoWrapAny W ex) (c : Cb) (hid : c.byId = false)
    (n0 : Nat) (hc : c ∈ bufs (ex n0).base) : ∃ m, c ∈ (ex m).base.ran :=
  EFair.efair W ex hex hr hf hnw c hid n0 hc

/-- **`fair_liveness` needs `NoWrapAt`** (for every width `W ≥ 1`): `EFair.wrap_starves`. -/
theorem fair_liveness_needs_nowrap (hW : 0 < W) : ¬ ∀ (ex : Nat → ESt) (N0 : Nat),
    EFair.EExec W ex → EReach W (ex 0) → Fair.StableFrom (EFair.proj ex) N0 →
    (∃ t, ((ex N0).base.threads t).isSome) → EFair.EFairFrom W ex N0 →
    ∀ c : Cb, c.byId = false → ∀ n0, N0 ≤ n0 → c ∈ bufs (ex n0).base →
    ∃ m, c ∈ (ex m).base.ran :=
  EFair.efair_needs_nowrap W hW

end Main
end Collect
