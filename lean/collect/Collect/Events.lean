import Collect.Progress

/-!
# `EVENTS` / `seen_events` and the fast path of `collect`

**This is the primary model** (the headline theorems in `Collect.Main` are stated on
`EReach`). It refines the base model (`Collect.Model`, which leaves `collect_cold`
nondeterministic) and adds the global wrapping counter `EVENTS`
(width `W`, i.e. `usize`: `W = 2^64` on 64-bit targets) and every thread's `seen_events`.

* `total` is a ghost, unbounded count of `EVENTS.fetch_add(1)` calls. The real counter is
  `events e = total % W` (a `wrapping_add`).
* `seen t` is the real `seen_events` value (always in `[0, W)`).
* `gseen t` is a ghost: the unwrapped `total` that `seen t` represents. When `seen` is set
  to `EVENTS` it is `total`. When it is set to the forced value `EVENTS.wrapping_sub(1)`
  (in `pin_cold`) it is `total - 1`. Initially it is `0`.
* `chk t`: `collect`'s `Acquire` load saw a difference; `collect_cold`'s second (`Relaxed`)
  load has not happened yet. `mid t`: that load was stored into `seen_events`, the
  `COLLECTOR` lock is not yet taken. Both loads are separate steps, so other threads may
  bump `EVENTS` in between.
* `fpend t`: `pin_cold`'s `register` returned `true` under the lock; the forced store
  `seen_events = EVENTS.load(Relaxed).wrapping_sub(1)` happens after the lock is released
  (`pinForce`), so bumps in between are covered.

Main results:
* `ereach_base`: every behaviour of this model projects to a behaviour of the base model,
  so `esafety` follows from `safety`.
* `fast_path_detects`: if fewer than `W` events happened since the thread's `seen_events`
  was taken (and at least one did), `collect` takes the slow path.
* `fast_path_misses_iff` and `defer_W_misses`: an event is missed exactly when the number
  of events since then is a positive multiple of `W`. Doing `W` defers in a row exhibits it.
-/

namespace Collect
namespace Ev

/-- Extended state. -/
structure ESt where
  base : St
  /-- ghost: total number of `EVENTS.fetch_add(1)` -/
  total : Nat
  /-- `seen_events` of every thread -/
  seen : Tid → Int
  /-- ghost: the unwrapped event count that `seen` stands for -/
  gseen : Tid → Int
  /-- thread is between `collect_cold`'s `seen_events` update and taking the lock -/
  mid : Tid → Bool
  /-- `collect`'s `Acquire` load saw `EVENTS != seen_events`; `collect_cold` has not yet
  reloaded `EVENTS` (`Relaxed`) into `seen_events`. -/
  chk : Tid → Bool
  /-- `pin_cold` has registered the thread (with callbacks queued) but has not yet done the
  forced store `seen_events = EVENTS.wrapping_sub(1)`, which happens after the lock is
  released. -/
  fpend : Tid → Bool

variable (W : Nat)

/-- `EVENTS.load()` -/
def events (e : ESt) : Int := (e.total : Int) % W

/-- `Collector::register`'s return value: the collector has callbacks. -/
def hasCbs (s : St) : Bool := !(s.pending.isEmpty && s.previous.isEmpty && s.current.isEmpty)

open Classical in
/-- Number of `EVENTS` bumps done by `complete_epoch(signal)` on state `s`. -/
noncomputable def ceBump (signal : Bool) (s : St) : Nat :=
  if allNone s.threads then
    (if s.pending ++ s.previous ++ s.current ≠ [] then 1 else 0)
  else if (signal ∧ s.pending ++ s.previous ≠ []) ∨ s.current ≠ [] then 1 else 0

open Classical in
/-- Number of bumps done by `Collector::unregister` (it calls `complete_epoch(true)`). -/
noncomputable def unregBump (s : St) (t : Tid) : Nat :=
  let s' := { s with threads := upd s.threads t none, len := s.len - 1 }
  if s.threads t = some .busy then
    let s'' := { s' with busy := s.busy - 1 }
    (if s''.busy = 0 then ceBump true s'' else 0)
  else if allNone s'.threads then ceBump true s' else 0

open Classical in
/-- Bumps done by one (non-recursive part of) `quiet` (it calls `complete_epoch(false)` on
the state with `t` marked quiet; `threads` is non-empty there, so only `current` matters). -/
noncomputable def qBump (t : Tid) (s : St) : Nat :=
  if s.threads t = some .busy ∧ s.busy - 1 = 0 then
    ceBump false { s with threads := upd s.threads t (some .quiet), busy := s.busy - 1 }
  else 0

/-- Whether `quiet` recurses (and so stores `EVENTS` into `seen_events` inside the lock). -/
def qRecurses (t : Tid) (s : St) : Prop :=
  s.threads t = some .busy ∧ s.busy - 1 = 0 ∧
    (takePending (markQuiet t s)).1.previous ≠ []

/-- `qBump` is the bump count of Rust's `complete_epoch(false)`, which runs after `pending`
was taken (the model's order differs, but `threads` is non-empty there, so only `current`
matters). -/
theorem qBump_rust (t : Tid) (s : St) : qBump t s =
    if s.threads t = some .busy ∧ s.busy - 1 = 0 then
      ceBump false (setQuiet t (takePending s).1) else 0 := by
  have hna : ¬ allNone (upd s.threads t (some TS.quiet)) := fun h => by simpa using h t
  simp [qBump, ceBump, setQuiet, takePending, hna]

/-- The state the recursive call of Rust's `quiet` sees (after the second `take` of
`pending`) is the model's `r1` in `EStep.collectReg`, and `qRecurses` is exactly Rust's
recursion condition (`busy_count == 0 && !previous_deferred.is_empty()`). -/
theorem qInner_rust (t : Tid) (s : St) (hb : s.threads t = some .busy) (h0 : s.busy - 1 = 0) :
    (takePending (completeEpoch (setQuiet t (takePending s).1))).1 =
      (takePending (markQuiet t s)).1 := by
  simp only [markQuiet, h0, ite_true, setQuiet, takePending]
  by_cases ha : allNone (upd s.threads t (some TS.quiet)) <;> simp [completeEpoch, ha]

theorem qRecurses_rust (t : Tid) (s : St) : qRecurses t s ↔
    (s.threads t = some .busy ∧ (setQuiet t (takePending s).1).busy = 0 ∧
      (takePending (completeEpoch (setQuiet t (takePending s).1))).1.previous ≠ []) := by
  constructor
  · rintro ⟨hb, h0, hp⟩; exact ⟨hb, h0, by rwa [qInner_rust t s hb h0]⟩
  · rintro ⟨hb, h0, hp⟩; exact ⟨hb, h0, by rwa [← qInner_rust t s hb h0]⟩

/-- The recursive call finds `current_deferred` empty, so it does not recurse again
(`quietRust_cur_nil`). -/
theorem qInner_current (t : Tid) (s : St) (h : qRecurses t s) :
    (takePending (markQuiet t s)).1.current = [] := by
  obtain ⟨-, h0, -⟩ := h
  simp only [markQuiet, h0, ite_true, takePending]
  by_cases ha : allNone (upd s.threads t (some TS.quiet)) <;> simp [completeEpoch, ha]

def setSeen (e : ESt) (t : Tid) (v g : Int) : ESt :=
  { e with seen := upd e.seen t v, gseen := upd e.gseen t g }

/-- The extended transition relation. Steps that do not touch `EVENTS`/`seen_events` lift the
base step unchanged. A thread in `mid` can only take the lock. -/
inductive EStep : ESt → ESt → Prop
  /-- `pin` from `Unregistered`: the locked `register` call. If it returns `true`, the forced
  store of `seen_events` is still to come (`fpend`), outside the lock (`pinForce`).
  The thread's local state is set to `Pinned` already here: its later local writes are
  invisible to other threads, and treating it as pinned from the moment it is `Busy` only
  strengthens `safety`. -/
  | pinRegister (e : ESt) (t : Tid) (h : e.base.loc t = .unregistered) (hm : e.mid t = false)
      (hc : e.chk t = false) :
      EStep e { e with base := register e.base t, fpend := upd e.fpend t (hasCbs e.base) }
  /-- `pin_cold` after the lock is released: `seen_events = EVENTS.load(Relaxed).wrapping_sub(1)`,
  so the next `collect` is slow (unless `W - 1` more events happen first). Other threads may
  bump `EVENTS` between `register` and this load. -/
  | pinForce (e : ESt) (t : Tid) (hf : e.fpend t = true) :
      EStep e { setSeen e t ((events W e - 1) % W) (e.total - 1) with fpend := upd e.fpend t false }
  /-- `pin` from `Registered` -/
  | pinOuter (e : ESt) (t : Tid) (h : e.base.loc t = .registered) (hm : e.mid t = false)
      (hc : e.chk t = false) :
      EStep e { e with base := { e.base with
                                now := e.base.now + 1
                                loc := upd e.base.loc t (.pinned e.base.now 0) } }
  | pinNest (e : ESt) (t : Tid) (st d : Nat) (h : e.base.loc t = .pinned st d) (hf : e.fpend t = false) :
      EStep e { e with base := { e.base with loc := upd e.base.loc t (.pinned st (d + 1)) } }
  | unpinNest (e : ESt) (t : Tid) (st d : Nat) (h : e.base.loc t = .pinned st (d + 1))
      (hf : e.fpend t = false) :
      EStep e { e with base := { e.base with loc := upd e.base.loc t (.pinned st d) } }
  | unpinOuter (e : ESt) (t : Tid) (st : Nat) (h : e.base.loc t = .pinned st 0)
      (hf : e.fpend t = false) :
      EStep e { e with base := { e.base with loc := upd e.base.loc t .registered } }
  | cancel (e : ESt) (ids : List Nat) :
      EStep e { e with base := { e.base with
                                pending := cancelList ids e.base.pending
                                current := cancelList ids e.base.current
                                previous := cancelList ids e.base.previous } }
  | runOne (e : ESt) (t : Tid) (w : Bool) (c : Cb) (cs : List Cb)
      (h : e.base.loc t = .collecting w (c :: cs)) :
      EStep e { e with base := { e.base with
                                loc := upd e.base.loc t (.collecting w cs)
                                ran := e.base.ran ++ [c] } }
  | finish (e : ESt) (t : Tid) (w : Bool) (h : e.base.loc t = .collecting w []) :
      EStep e { e with base := { e.base with
                                loc := upd e.base.loc t (if w then .registered else .unregistered) } }
  /-- `release` (`unregister` may complete an epoch and bump `EVENTS`). -/
  | release (e : ESt) (t : Tid) (h : e.base.loc t = .registered) (hm : e.mid t = false)
      (hc : e.chk t = false) :
      EStep e { e with
                  base := unregister { e.base with loc := upd e.base.loc t .unregistered } t
                  total := e.total + unregBump { e.base with loc := upd e.base.loc t .unregistered } t }
  /-- `defer*`: one bump. -/
  | defer (e : ESt) (id : Nat) (byId : Bool) :
      EStep e { e with
                  base := { e.base with
                              now := e.base.now + 1
                              current := e.base.current ++ [⟨id, e.base.now, byId⟩] }
                  total := e.total + 1 }
  /-- `collect` fast path: `EVENTS == seen_events`, nothing happens. -/
  | collectFast (e : ESt) (t : Tid) (h : e.base.loc t = .registered ∨ e.base.loc t = .unregistered)
      (hm : e.mid t = false) (hc : e.chk t = false) (heq : events W e = e.seen t) : EStep e e
  /-- `collect`'s check: the `Acquire` load of `EVENTS` differs from `seen_events`, so
  `collect_cold` is entered. -/
  | collectCheck (e : ESt) (t : Tid) (h : e.base.loc t = .registered ∨ e.base.loc t = .unregistered)
      (hm : e.mid t = false) (hc : e.chk t = false) (hne : events W e ≠ e.seen t) :
      EStep e { e with chk := upd e.chk t true }
  /-- `collect_cold`: `seen_events = EVENTS.load(Relaxed)`, a second load (outside the lock), so
  bumps since `collectCheck` are included. -/
  | collectStore (e : ESt) (t : Tid) (hc : e.chk t = true) :
      EStep e { setSeen e t (events W e) e.total with
                  mid := upd e.mid t true, chk := upd e.chk t false }
  /-- `collect_cold`'s locked part from `Registered`: `quiet`, which may bump `EVENTS` and, when
  it recurses, stores `EVENTS` into `seen_events` between the two calls. -/
  | collectReg (e : ESt) (t : Tid) (h : e.base.loc t = .registered) (hm : e.mid t = true) :
      EStep e (open Classical in
        let b1 := qBump t e.base
        let r1 := (takePending (markQuiet t e.base)).1
        let e1 : ESt := { e with base := startCollect t true (quietRust t e.base),
                                 mid := upd e.mid t false }
        if qRecurses t e.base then
          { setSeen e1 t (((e.total + b1 : Nat) : Int) % W) (e.total + b1) with
              total := e.total + b1 + qBump t r1 }
        else { e1 with total := e.total + b1 })
  /-- `collect_cold`'s locked part from `Unregistered` (no bumps). -/
  | collectUnreg (e : ESt) (t : Tid) (h : e.base.loc t = .unregistered) (hm : e.mid t = true) :
      EStep e { e with base := startCollect t false (collectUnreg e.base), mid := upd e.mid t false }

def einit : ESt := { base := init, total := 0, seen := fun _ => 0, gseen := fun _ => 0,
                     mid := fun _ => false, chk := fun _ => false, fpend := fun _ => false }

inductive EReach : ESt → Prop
  | init : EReach einit
  | step {e e'} : EReach e → EStep W e e' → EReach e'

/-! ## Refinement and safety -/

theorem estep_base {e e' : ESt} (hs : EStep W e e') : e'.base = e.base ∨ Step e.base e'.base := by
  cases hs with
  | pinRegister t h _ => exact .inr (Step.pinRegister _ t h)
  | pinForce => exact .inl rfl
  | pinOuter t h _ => exact .inr (Step.pinOuter _ t h)
  | pinNest t st d h _ => exact .inr (Step.pinNest _ t st d h)
  | unpinNest t st d h _ => exact .inr (Step.unpinNest _ t st d h)
  | unpinOuter t st h _ => exact .inr (Step.unpinOuter _ t st h)
  | cancel ids => exact .inr (Step.cancel _ ids)
  | runOne t w c cs h => exact .inr (Step.runOne _ t w c cs h)
  | finish t w h => exact .inr (Step.finish _ t w h)
  | release t h _ => exact .inr (Step.release _ t h)
  | defer id byId => exact .inr (Step.defer _ id byId)
  | collectFast => exact .inl rfl
  | collectCheck => exact .inl rfl
  | collectStore => exact .inl rfl
  | collectReg t h _ =>
    right; dsimp only; split
    · exact Step.collectReg _ t h
    · exact Step.collectReg _ t h
  | collectUnreg t h _ => exact .inr (Step.collectUnreg _ t h)

/-- Every reachable extended state projects to a reachable base state. -/
theorem ereach_base {e : ESt} (h : EReach W e) : Reachable e.base := by
  induction h with
  | init => exact .init
  | step _ hs ih =>
    rcases estep_base W hs with he | he
    · rw [he]; exact ih
    · exact .step ih he

/-- **Reclamation safety** for the refined model. -/
theorem esafety {e : ESt} (h : EReach W e) (c : Cb) (hc : c ∈ e.base.ran) (u : Tid) :
    ¬ blocked e.base.loc c u :=
  safety (ereach_base W h) c hc u

/-! ## Counter invariant -/

/-- `seen_events` is the wrapped value of its ghost, and the ghost is not ahead of `EVENTS`. -/
def SeenInv (e : ESt) : Prop := ∀ t, e.seen t = e.gseen t % W ∧ e.gseen t ≤ e.total

theorem seenInv_init : SeenInv W einit := by
  intro t; simp [einit]

theorem seenInv_setSeen {e : ESt} (h : SeenInv W e) (t : Tid) (g : Int) (hg : g ≤ e.total) :
    SeenInv W (setSeen e t (g % W) g) := by
  intro u; by_cases hu : u = t
  · subst hu; simp [setSeen, hg]
  · simp [setSeen, hu, h u]

theorem seenInv_mono {e : ESt} (h : SeenInv W e) (n : Nat) :
    SeenInv W { e with total := e.total + n } := by
  intro u; have := h u; simp only at *; omega

theorem wsub_emod (x : Int) : (x % W - 1) % W = (x - 1) % W := by
  rw [Int.sub_emod x, Int.sub_emod (x % W), Int.emod_emod]

theorem seenInv_step {e e' : ESt} (h : SeenInv W e) (hs : EStep W e e') : SeenInv W e' := by
  cases hs with
  | pinRegister => exact h
  | pinForce t =>
    intro u; have := h u; by_cases hu : u = t
    · subst hu; simp [setSeen, events]; omega
    · simp [setSeen, hu, this]
  | pinOuter | pinNest | unpinNest | unpinOuter | cancel | runOne | finish => exact h
  | release t => intro u; have := h u; simp only at *; omega
  | defer => intro u; have := h u; simp only at *; omega
  | collectFast => exact h
  | collectCheck => exact h
  | collectStore t =>
    intro u; have := h u; by_cases hu : u = t
    · subst hu; simp [setSeen, events]
    · simp [setSeen, hu, this]
  | collectReg t _ _ =>
    dsimp only; split
    · intro u; have := h u; by_cases hu : u = t
      · subst hu; simp [setSeen]; omega
      · simp [setSeen, hu]; omega
    · intro u; have := h u; simp only at *; omega
  | collectUnreg => exact h

theorem ereach_seenInv {e : ESt} (h : EReach W e) : SeenInv W e := by
  induction h with
  | init => exact seenInv_init W
  | step _ hs ih => exact seenInv_step W ih hs

/-! ## The fast-path check -/

theorem emod_eq_iff_sub (a b : Int) :
    a % W = b % W ↔ (b - a) % W = 0 := by
  constructor
  · intro h
    have ha := Int.emod_add_mul_ediv a W
    have hb := Int.emod_add_mul_ediv b W
    have : b - a = W * (b / W - a / W) := by rw [Int.mul_sub]; omega
    rw [this, Int.mul_emod_right]
  · intro h
    obtain ⟨k, hk⟩ := Int.dvd_of_emod_eq_zero h
    have : b = a + W * k := by omega
    rw [this, Int.add_mul_emod_self_left]

/-- `collect` takes the fast path (misses the events since `seen_events` was taken) exactly
when the number of events since then is a multiple of `W`. -/
theorem fast_path_misses_iff {e : ESt} (h : EReach W e) (t : Tid) :
    events W e = e.seen t ↔ ((e.total : Int) - e.gseen t) % W = 0 := by
  rw [(ereach_seenInv W h t).1, events, eq_comm, emod_eq_iff_sub W]

/-- **No missed events without wrap-around.** If at least one and fewer than `W` events
happened since `seen_events` was taken, `collect`'s check sees a difference and takes the
slow path. -/
theorem fast_path_detects {e : ESt} (h : EReach W e) (t : Tid)
    (hnew : e.gseen t < e.total) (hnowrap : (e.total : Int) - e.gseen t < W) :
    events W e ≠ e.seen t := by
  intro h0; rw [fast_path_misses_iff W h] at h0
  have := Int.emod_eq_of_lt (a := (e.total : Int) - e.gseen t) (b := W) (by omega) hnowrap
  omega

/-- Corollary for the forced value: right after `pin` registers a thread while callbacks are
queued (`gseen = total - 1`), `collect` is slow unless the counter moved by `W - 1` events. -/
theorem forced_detects {e : ESt} (h : EReach W e) (hW : 1 < W) (t : Tid)
    (hforced : e.gseen t = (e.total : Int) - 1) : events W e ≠ e.seen t :=
  fast_path_detects W h t (by omega) (by omega)

/-! ## Wrap-around: an event can be missed -/

/-- Reflexive-transitive closure of `EStep`. -/
inductive ESteps : ESt → ESt → Prop
  | refl (e) : ESteps e e
  | tail {e e' e''} : ESteps e e' → EStep W e' e'' → ESteps e e''

theorem ereach_steps {e e'} (h : EReach W e) (hs : ESteps W e e') : EReach W e' := by
  induction hs with
  | refl => exact h
  | tail _ s ih => exact .step ih s

/-- `n` defers (by any thread) keep `seen`/`gseen` and add `n` to `total` and `n` callbacks. -/
theorem defer_n (e : ESt) (n : Nat) : ∃ e', ESteps W e e' ∧ e'.total = e.total + n ∧
    e'.seen = e.seen ∧ e'.gseen = e.gseen ∧ e'.mid = e.mid ∧ e'.base.loc = e.base.loc ∧
    e'.base.current.length = e.base.current.length + n := by
  induction n with
  | zero => exact ⟨e, .refl e, by simp⟩
  | succ n ih =>
    obtain ⟨e', hs, h1, h2, h3, h4, h5, h6⟩ := ih
    refine ⟨_, .tail hs (EStep.defer e' 0 false), ?_⟩
    simp [h1, h2, h3, h4, h5, h6]; omega

/-- **A missed event.** From any reachable state where thread `t` is up to date
(`EVENTS == seen_events`, e.g. just after its `collect`), exactly `W` defers by other code
bring `EVENTS` back to the same value: `t`'s `collect` then takes the fast path although
`W` callbacks were deferred since (and, as `gseen < total`, the slow path would be needed
to make progress on them). -/
theorem defer_W_misses {e : ESt} (h : EReach W e) (hW : 0 < W) (t : Tid)
    (hup : events W e = e.seen t) :
    ∃ e', ESteps W e e' ∧ EReach W e' ∧ e'.gseen t < e'.total ∧
      e'.base.current.length = e.base.current.length + W ∧ events W e' = e'.seen t := by
  obtain ⟨e', hs, h1, h2, h3, -, -, h6⟩ := defer_n W e W
  have hr := ereach_steps W h hs
  have hi := (ereach_seenInv W h t).2
  refine ⟨e', hs, hr, by rw [h3, h1]; push_cast; omega, h6, ?_⟩
  rw [h2, ← hup, events, events, h1]; push_cast; simp

/-! ## Liveness under no overflow -/

/-! ### Decomposition of `eventually_ran_events`

`Clean e`: no thread is in the middle of a split (`pin_cold`'s forced store, `collect`'s
check/reload, or about to take the lock). The proof is: (A) drive `e` to a clean state
(`eclean`), then (B) run the drain schedule of `eventually_ran` on the `Events` model
(`eventually_ran_clean`), with one escaping `defer` before the final `collect` if its
check would miss. -/

def Clean (e : ESt) : Prop := ∀ t, e.fpend t = false ∧ e.chk t = false ∧ e.mid t = false

theorem esteps_trans {a b c : ESt} (h1 : ESteps W a b) (h2 : ESteps W b c) : ESteps W a c := by
  induction h2 with
  | refl => exact h1
  | tail _ s ih => exact .tail ih s

theorem esteps_single {a b : ESt} (h : EStep W a b) : ESteps W a b := .tail (.refl a) h

/-- **Escaping a missed event** (needs `1 < W`): if thread `t`'s check would take the fast
path, one `defer` makes it take the slow path. -/
theorem defer_escapes {e : ESt} (hW : 1 < W) (t : Tid)
    (hup : events W e = e.seen t) : (((e.total + 1 : Nat) : Int) % W) ≠ e.seen t := by
  rw [← hup]; simp only [events]; push_cast
  intro h0
  have := (emod_eq_iff_sub W ((e.total : Int)) ((e.total : Int) + 1)).1 h0.symm
  have h1 : (1 : Int) % W = 1 := Int.emod_eq_of_lt (by omega) (by omega)
  have h2 : ((e.total : Int) + 1 - e.total) = 1 := by omega
  rw [h2, h1] at this; exact absurd this (by decide)

/-! ### (A) Finishing split steps -/

theorem markQuiet_ran (t : Tid) (s : St) : (markQuiet t s).ran = s.ran := by
  unfold markQuiet completeEpoch; split <;> (try split) <;> rfl

theorem quiet_ran (t : Tid) : ∀ fuel (s : St), (quiet t fuel s).1.ran = s.ran
  | 0, s => rfl
  | fuel + 1, s => by
    simp only [quiet]
    split
    · rfl
    · split
      · simp [quiet_ran t fuel, takePending, markQuiet_ran]
      · simp [takePending, markQuiet_ran]

theorem markQuiet_bufs (t : Tid) (s : St) (c : Cb) (h : c ∈ bufs s) : c ∈ bufs (markQuiet t s) := by
  unfold markQuiet; split
  · exact completeEpoch_mem_fwd _ c (by simpa [bufs] using h)
  · simpa [bufs] using h

theorem quiet_bufs (t : Tid) : ∀ fuel (s : St) (c : Cb), c ∈ bufs s →
    c ∈ bufs (quiet t fuel s).1 ∨ c ∈ (quiet t fuel s).2
  | 0, s, c, h => .inl h
  | fuel + 1, s, c, h => by
    simp only [quiet]
    split
    · simp [takePending, bufs] at h ⊢; grind
    · have h1 := markQuiet_bufs t s c h
      have h2 : c ∈ bufs (takePending (markQuiet t s)).1 ∨ c ∈ (takePending (markQuiet t s)).2 := by
        simp [takePending, bufs] at h1 ⊢; grind
      split
      · rcases h2 with h2 | h2
        · rcases quiet_bufs t fuel _ c h2 with h3 | h3
          · exact .inl h3
          · exact .inr (by simp [h3])
        · exact .inr (by simp [h2])
      · exact h2

theorem collectUnreg_bufs (s : St) (c : Cb) (h : c ∈ bufs s) :
    c ∈ bufs (collectUnreg s).1 ∨ c ∈ (collectUnreg s).2 := by
  unfold collectUnreg; split <;> simp [bufs] at h ⊢ <;> grind

/-- After `startCollect`, a queued callback is still queued, already ran (a flag) or is in
the thread's to-do list. -/
theorem startCollect_bufs (t : Tid) (w : Bool) (r : St × List Cb) (c : Cb)
    (h : c ∈ bufs r.1 ∨ c ∈ r.2) :
    c ∈ bufs (startCollect t w r) ∨ c ∈ (startCollect t w r).ran ∨
      c ∈ r.2.filter (fun c => !c.byId) := by
  rcases h with h | h
  · exact .inl h
  · cases hb : c.byId
    · exact .inr (.inr (by simp [h, hb]))
    · exact .inr (.inl (by simp [startCollect, h, hb]))

/-- Invariant for `eclean`. -/
structure SplitInv (e : ESt) : Prop where
  loc : ∀ t, (e.chk t = true ∨ e.mid t = true) →
    e.base.loc t = .registered ∨ e.base.loc t = .unregistered
  excl : ∀ t, ¬ (e.chk t = true ∧ e.mid t = true)
  fin : ∃ N, ∀ t, N ≤ t → e.fpend t = false ∧ e.chk t = false ∧ e.mid t = false

theorem fin_upd {e : ESt} (h : ∃ N, ∀ t, N ≤ t → e.fpend t = false ∧ e.chk t = false ∧ e.mid t = false)
    (t : Tid) (f c m : Tid → Bool) (hf : ∀ u, u ≠ t → f u = e.fpend u)
    (hc : ∀ u, u ≠ t → c u = e.chk u) (hm : ∀ u, u ≠ t → m u = e.mid u) :
    ∃ N, ∀ u, N ≤ u → f u = false ∧ c u = false ∧ m u = false := by
  obtain ⟨N, hN⟩ := h
  refine ⟨max N (t + 1), fun u hu => ?_⟩
  have h1 : N ≤ u := Nat.le_trans (Nat.le_max_left _ _) hu
  have h2 : t + 1 ≤ u := Nat.le_trans (Nat.le_max_right _ _) hu
  have hne : u ≠ t := fun e => by subst e; exact Nat.lt_irrefl _ h2
  rw [hf u hne, hc u hne, hm u hne]; exact hN u h1

theorem splitInv_init : SplitInv einit :=
  ⟨fun _ h => by simp [einit] at h, fun _ h => by simp [einit] at h,
   ⟨0, fun _ _ => by simp [einit]⟩⟩

theorem splitInv_step {e e' : ESt} (h : SplitInv e) (hs : EStep W e e') : SplitInv e' := by
  obtain ⟨hl, hx, hfin⟩ := h
  cases hs with
  | pinRegister t h0 hm hc =>
    refine ⟨fun u hu => ?_, fun u => by simpa using hx u, fin_upd hfin t _ _ _ (by simp_all) (by simp) (by simp)⟩
    by_cases e : u = t
    · subst e; simp_all
    · simpa [register, e] using hl u hu
  | pinForce t _ =>
    exact ⟨fun u hu => by simpa [setSeen] using hl u (by simpa [setSeen] using hu),
      fun u => by simpa [setSeen] using hx u, fin_upd hfin t _ _ _ (by simp_all) (by simp [setSeen]) (by simp [setSeen])⟩
  | pinOuter t h0 hm hc =>
    refine ⟨fun u hu => ?_, hx, fin_upd hfin t _ _ _ (by simp) (by simp) (by simp)⟩
    by_cases e : u = t
    · subst e; simp_all
    · simpa [e] using hl u hu
  | pinNest t st d h0 _ =>
    refine ⟨fun u hu => ?_, hx, fin_upd hfin t _ _ _ (by simp) (by simp) (by simp)⟩
    by_cases e : u = t
    · subst e; have := hl u hu; simp_all
    · simpa [e] using hl u hu
  | unpinNest t st d h0 _ =>
    refine ⟨fun u hu => ?_, hx, fin_upd hfin t _ _ _ (by simp) (by simp) (by simp)⟩
    by_cases e : u = t
    · subst e; have := hl u hu; simp_all
    · simpa [e] using hl u hu
  | unpinOuter t st h0 _ =>
    refine ⟨fun u hu => ?_, hx, fin_upd hfin t _ _ _ (by simp) (by simp) (by simp)⟩
    by_cases e : u = t
    · subst e; simp_all
    · simpa [e] using hl u hu
  | cancel ids => exact ⟨hl, hx, hfin⟩
  | runOne t w c cs h0 =>
    refine ⟨fun u hu => ?_, hx, fin_upd hfin t _ _ _ (by simp) (by simp) (by simp)⟩
    by_cases e : u = t
    · subst e; have := hl u hu; simp_all
    · simpa [e] using hl u hu
  | finish t w h0 =>
    refine ⟨fun u hu => ?_, hx, fin_upd hfin t _ _ _ (by simp) (by simp) (by simp)⟩
    by_cases e : u = t
    · subst e; cases w <;> simp
    · simpa [e] using hl u hu
  | release t h0 hm hc =>
    refine ⟨fun u hu => ?_, hx, fin_upd hfin t _ _ _ (by simp) (by simp) (by simp)⟩
    by_cases e : u = t
    · subst e; simp
    · simpa [e] using hl u hu
  | defer => exact ⟨hl, hx, hfin⟩
  | collectFast => exact ⟨hl, hx, hfin⟩
  | collectCheck t h0 hm hc _ =>
    refine ⟨fun u hu => ?_, fun u => ?_, fin_upd hfin t _ _ _ (by simp) (fun u hu => by simp [hu]) (by simp)⟩
    · by_cases e : u = t
      · subst e; exact h0
      · exact hl u (by simpa [e] using hu)
    · by_cases e : u = t
      · subst e; simp [hm]
      · simpa [e] using hx u
  | collectStore t hc =>
    refine ⟨fun u hu => ?_, fun u => ?_, fin_upd hfin t _ _ _ (by simp [setSeen])
      (fun u hu => by simp [setSeen, hu]) (fun u hu => by simp [setSeen, hu])⟩
    · by_cases e : u = t
      · subst e; simpa [setSeen] using hl u (.inl hc)
      · exact hl u (by simpa [setSeen, e] using hu)
    · by_cases e : u = t
      · subst e; simp [setSeen]
      · simpa [setSeen, e] using hx u
  | collectReg t h0 hm =>
    have hc : e.chk t = false := by have := hx t; simp_all
    split
    · refine ⟨fun u hu => ?_, fun u => ?_, fin_upd hfin t _ _ _ (by simp [setSeen])
        (by simp [setSeen]) (fun u hu => by simp [setSeen, hu])⟩
      · by_cases e : u = t
        · subst e; simp_all [setSeen]
        · simpa [setSeen, e, startCollect, quietRust_eq, quiet_loc] using hl u (by simpa [setSeen, e] using hu)
      · by_cases e : u = t
        · subst e; simp [setSeen]
        · simpa [setSeen, e] using hx u
    · refine ⟨fun u hu => ?_, fun u => ?_, fin_upd hfin t _ _ _ (by simp)
        (by simp) (fun u hu => by simp [hu])⟩
      · by_cases e : u = t
        · subst e; simp_all
        · simpa [e, startCollect, quietRust_eq, quiet_loc] using hl u (by simpa [e] using hu)
      · by_cases e : u = t
        · subst e; simp
        · simpa [e] using hx u
  | collectUnreg t h0 hm =>
    have hc : e.chk t = false := by have := hx t; simp_all
    refine ⟨fun u hu => ?_, fun u => ?_, fin_upd hfin t _ _ _ (by simp)
        (by simp) (fun u hu => by simp [hu])⟩
    · by_cases e : u = t
      · subst e; simp_all
      · simpa [e, startCollect] using hl u (by simpa [e] using hu)
    · by_cases e : u = t
      · subst e; simp
      · simpa [e] using hx u

theorem ereach_splitInv {e : ESt} (h : EReach W e) : SplitInv e := by
  induction h with
  | init => exact splitInv_init
  | step _ hs ih => exact splitInv_step W ih hs

/-- What the schedule of `eventually_ran_events` needs from its start state: `SplitInv` and a
reachable base state. Both are preserved by every `EStep`, so they also hold on states reached
through other step relations that project to `EStep`s (`RC11Live.LReach`). -/
def Drainable (e : ESt) : Prop := SplitInv e ∧ Reachable e.base

theorem drainable_step {e e' : ESt} (h : Drainable e) (hs : EStep W e e') : Drainable e' :=
  ⟨splitInv_step W h.1 hs, by
    rcases estep_base W hs with he | he
    · rw [he]; exact h.2
    · exact .step h.2 he⟩

theorem drainable_steps {e e' : ESt} (h : Drainable e) (hs : ESteps W e e') : Drainable e' := by
  induction hs with
  | refl => exact h
  | tail _ s ih => exact drainable_step W ih s

theorem ereach_drainable {e : ESt} (h : EReach W e) : Drainable e := ⟨ereach_splitInv W h, ereach_base W h⟩

/-- `c` is queued or has run. -/
def Has (c : Cb) (e : ESt) : Prop := c ∈ bufs e.base ∨ c ∈ e.base.ran

/-- Run the whole to-do list of a collecting thread (no `finish`). -/
theorem erun (t : Tid) (w : Bool) : ∀ (l : List Cb) (e : ESt), e.base.loc t = .collecting w l →
    ∃ e', ESteps W e e' ∧ e'.fpend = e.fpend ∧ e'.chk = e.chk ∧ e'.mid = e.mid ∧
      bufs e'.base = bufs e.base ∧ (∀ x ∈ e.base.ran, x ∈ e'.base.ran) ∧ ∀ x ∈ l, x ∈ e'.base.ran
  | [], e, _ => ⟨e, .refl e, rfl, rfl, rfl, rfl, fun _ h => h, by simp⟩
  | c :: cs, e, hl => by
    obtain ⟨e', h1, h2, h3, h4, h5, h6, h7⟩ := erun t w cs _ (by simp : ({ e with base := { e.base with
        loc := upd e.base.loc t (.collecting w cs), ran := e.base.ran ++ [c] } } : ESt).base.loc t
          = .collecting w cs)
    refine ⟨e', esteps_trans W (esteps_single W (EStep.runOne e t w c cs hl)) h1, h2, h3, h4,
      by rw [h5]; rfl, fun x hx => h6 x (by simp [hx]), ?_⟩
    intro x hx
    rcases List.mem_cons.1 hx with rfl | hx
    · exact h6 _ (by simp)
    · exact h7 x hx

/-- Finish thread `t`'s split steps, touching no other thread's split flags. -/
theorem clean_thread {e : ESt} (h : Drainable e) (t : Tid) (c : Cb) (hc : Has c e) :
    ∃ e', ESteps W e e' ∧ e'.fpend t = false ∧ e'.chk t = false ∧ e'.mid t = false ∧
      (∀ u, u ≠ t → e'.fpend u = e.fpend u ∧ e'.chk u = e.chk u ∧ e'.mid u = e.mid u) ∧
      Has c e' := by
  -- 1. `pinForce`
  obtain ⟨e1, s1, f1, k1, b1⟩ : ∃ e1, ESteps W e e1 ∧ e1.fpend t = false ∧
      (∀ u, u ≠ t → e1.fpend u = e.fpend u) ∧ e1.chk = e.chk ∧ e1.mid = e.mid ∧ e1.base = e.base := by
    cases hf : e.fpend t
    · exact ⟨e, .refl e, hf, fun _ _ => rfl, rfl, rfl, rfl⟩
    · exact ⟨_, esteps_single W (EStep.pinForce e t hf), by simp, fun u hu => by simp [hu],
        rfl, rfl, rfl⟩
  obtain ⟨b1c, b1m, b1b⟩ := b1
  -- 2. `collectStore`
  obtain ⟨e2, s2, f2, c2, k2, m2, b2⟩ : ∃ e2, ESteps W e1 e2 ∧ e2.fpend = e1.fpend ∧
      e2.chk t = false ∧ (∀ u, u ≠ t → e2.chk u = e1.chk u ∧ e2.mid u = e1.mid u) ∧
      (e1.mid t = true → e2.mid t = true) ∧ e2.base = e1.base := by
    cases hk : e1.chk t
    · exact ⟨e1, .refl e1, rfl, hk, fun _ _ => ⟨rfl, rfl⟩, id, rfl⟩
    · refine ⟨_, esteps_single W (EStep.collectStore e1 t hk), by simp [setSeen], by simp [setSeen],
        fun u hu => by simp [setSeen, hu], fun _ => by simp [setSeen], by simp [setSeen]⟩
  have hr2 : Drainable e2 := drainable_steps W h (esteps_trans W s1 s2)
  have hc2 : Has c e2 := by unfold Has; rw [b2, b1b]; exact hc
  -- 3. the locked part and the to-do list
  cases hm : e2.mid t
  · refine ⟨e2, esteps_trans W s1 s2, by rw [f2]; exact f1, c2, hm, fun u hu => ?_, hc2⟩
    have := k2 u hu; rw [f2, k1 u hu, this.1, this.2, b1c, b1m]; exact ⟨rfl, rfl, rfl⟩
  · have hinv := hr2.1
    have hcf : e2.chk t = false := c2
    rcases hinv.loc t (.inr hm) with hl | hl
    · -- registered
      obtain ⟨e3, s3, f3, c3, m3, b3⟩ : ∃ e3, EStep W e2 e3 ∧ e3.fpend = e2.fpend ∧
          e3.chk = e2.chk ∧ e3.mid = upd e2.mid t false ∧
          e3.base = startCollect t true (quiet t 2 e2.base) := by
        refine ⟨_, EStep.collectReg e2 t hl hm, ?_⟩
        split <;> simp [setSeen, quietRust_eq]
      have hcol : e3.base.loc t = .collecting true ((quiet t 2 e2.base).2.filter (fun c => !c.byId)) := by
        rw [b3]; simp [startCollect]
      obtain ⟨e4, s4, f4, c4, m4, b4, r4, l4⟩ := erun W t true _ e3 hcol
      refine ⟨e4, esteps_trans W (esteps_trans W s1 s2) (esteps_trans W (esteps_single W s3) s4),
        by rw [f4, f3, f2]; exact f1, by rw [c4, c3]; exact hcf, by rw [m4, m3]; simp,
        fun u hu => ?_, ?_⟩
      · have := k2 u hu
        rw [f4, f3, f2, k1 u hu, c4, c3, this.1, m4, m3, upd_other _ _ _ _ hu, this.2, b1c, b1m]
        exact ⟨rfl, rfl, rfl⟩
      · unfold Has
        rcases hc2 with hb | hb
        · rcases startCollect_bufs t true _ c (quiet_bufs t 2 _ c hb) with h' | h' | h'
          · exact .inl (by rw [b4, b3]; exact h')
          · exact .inr (r4 _ (by rw [b3]; exact h'))
          · exact .inr (l4 _ h')
        · exact .inr (r4 _ (by rw [b3]; simp [startCollect, quiet_ran, hb]))
    · -- unregistered
      obtain ⟨e3, s3, f3, c3, m3, b3⟩ : ∃ e3, EStep W e2 e3 ∧ e3.fpend = e2.fpend ∧
          e3.chk = e2.chk ∧ e3.mid = upd e2.mid t false ∧
          e3.base = startCollect t false (Collect.collectUnreg e2.base) :=
        ⟨_, EStep.collectUnreg e2 t hl hm, rfl, rfl, rfl, rfl⟩
      have hcol : e3.base.loc t =
          .collecting false ((Collect.collectUnreg e2.base).2.filter (fun c => !c.byId)) := by
        rw [b3]; simp [startCollect]
      obtain ⟨e4, s4, f4, c4, m4, b4, r4, l4⟩ := erun W t false _ e3 hcol
      refine ⟨e4, esteps_trans W (esteps_trans W s1 s2) (esteps_trans W (esteps_single W s3) s4),
        by rw [f4, f3, f2]; exact f1, by rw [c4, c3]; exact hcf, by rw [m4, m3]; simp,
        fun u hu => ?_, ?_⟩
      · have := k2 u hu
        rw [f4, f3, f2, k1 u hu, c4, c3, this.1, m4, m3, upd_other _ _ _ _ hu, this.2, b1c, b1m]
        exact ⟨rfl, rfl, rfl⟩
      · unfold Has
        rcases hc2 with hb | hb
        · rcases startCollect_bufs t false _ c (collectUnreg_bufs _ c hb) with h' | h' | h'
          · exact .inl (by rw [b4, b3]; exact h')
          · exact .inr (r4 _ (by rw [b3]; exact h'))
          · exact .inr (l4 _ h')
        · refine .inr (r4 _ ?_)
          rw [b3]
          simp only [startCollect, List.mem_append]
          left; unfold collectUnreg; split <;> exact hb

theorem clean_upto {e : ESt} (h : Drainable e) (c : Cb) (hc : Has c e) : ∀ n : Nat,
    ∃ e', ESteps W e e' ∧
      (∀ t, t < n → e'.fpend t = false ∧ e'.chk t = false ∧ e'.mid t = false) ∧
      (∀ t, n ≤ t → e'.fpend t = e.fpend t ∧ e'.chk t = e.chk t ∧ e'.mid t = e.mid t) ∧
      Has c e'
  | 0 => ⟨e, .refl e, fun _ h => absurd h (Nat.not_lt_zero _), fun _ _ => ⟨rfl, rfl, rfl⟩, hc⟩
  | n + 1 => by
    obtain ⟨e1, a1, b1, c1, d1⟩ := clean_upto h c hc n
    obtain ⟨e2, a2, f2, k2, m2, o2, d2⟩ := clean_thread W (drainable_steps W h a1) n c d1
    refine ⟨e2, esteps_trans W a1 a2, fun t ht => ?_, fun t ht => ?_, d2⟩
    · by_cases ht' : t = n
      · subst ht'; exact ⟨f2, k2, m2⟩
      · have := o2 t ht'; rw [this.1, this.2.1, this.2.2]; exact b1 t (by omega)
    · have hne : t ≠ n := by omega
      have := o2 t hne; rw [this.1, this.2.1, this.2.2]; exact c1 t (by omega)

/-- (A) Finish every in-flight split step. A thread in `chk`/`mid` finishes its `collect`
(which may move `c` into its own to-do list; it is then run by `runOne`), `fpend` threads do
`pinForce`. Uses `SplitInv` (finitely many threads in a split, `mid`/`chk` threads are
`Registered`/`Unregistered`) and `clean_thread`/`clean_upto`. -/
theorem eclean {e : ESt} (h : Drainable e) (c : Cb) (hc : c ∈ bufs e.base) :
    ∃ e', ESteps W e e' ∧ (c ∈ e'.base.ran ∨ (Clean e' ∧ c ∈ bufs e'.base)) := by
  obtain ⟨N, hN⟩ := h.1.fin
  obtain ⟨e', a, b, d, hh⟩ := clean_upto W h c (.inl hc) N
  refine ⟨e', a, ?_⟩
  rcases hh with hb | hr
  · refine .inr ⟨fun t => ?_, hb⟩
    by_cases ht : t < N
    · exact b t ht
    · have hle := Nat.le_of_not_lt ht
      have := d t hle; rw [this.1, this.2.1, this.2.2]; exact hN t hle
  · exact .inl hr

/-! (B) The drain schedule of `Collect.eventually_ran_aux`, replayed on the `Events` model
from a clean state (instead of lifting an arbitrary base schedule). -/


theorem e_release_drive (e : ESt) (t : Tid) (hcl : Clean e) (hl : e.base.loc t = .registered) :
    ∃ e', ESteps W e e' ∧ e'.base.loc t = .unregistered ∧ Pres t e.base e'.base ∧ Clean e' := by
  refine ⟨_, esteps_single W (EStep.release e t hl (hcl t).2.2 (hcl t).2.1), ?_, ?_, hcl⟩
  · simp
  · refine ⟨fun u hu => by simp [hu], ?_, by simp⟩
    intro c hc; exact unregister_mem_fwd _ t c (by simpa [bufs] using hc)

theorem e_unpin_drive (t : Tid) (st : Nat) : ∀ (d : Nat) (e : ESt), Clean e → e.base.loc t = .pinned st d →
    ∃ e', ESteps W e e' ∧ e'.base.loc t = .registered ∧ Pres t e.base e'.base ∧ Clean e'
  | 0, e, hcl, hl => ⟨_, esteps_single W (EStep.unpinOuter e t st hl (hcl t).1), by simp,
      ⟨fun u hu => by simp [hu], fun _ h => h, fun _ h => h⟩, hcl⟩
  | d + 1, e, hcl, hl => by
    obtain ⟨e', h1, h2, h3, h4⟩ := e_unpin_drive t st d
      { e with base := { e.base with loc := upd e.base.loc t (.pinned st d) } } hcl (by simp)
    exact ⟨e', esteps_trans W (esteps_single W (EStep.unpinNest e t st d hl (hcl t).1)) h1, h2,
      Pres.trans (b := { e.base with loc := upd e.base.loc t (.pinned st d) })
        ⟨fun u hu => by simp [hu], fun _ h => h, fun _ h => h⟩ h3, h4⟩

theorem e_run_drive (t : Tid) (w : Bool) : ∀ (l : List Cb) (e : ESt), Clean e →
    e.base.loc t = .collecting w l →
    ∃ e', ESteps W e e' ∧ e'.base.loc t = (if w then .registered else .unregistered) ∧
      Pres t e.base e'.base ∧ Clean e' ∧ ∀ c ∈ l, c ∈ e'.base.ran
  | [], e, hcl, hl => ⟨_, esteps_single W (EStep.finish e t w hl), by simp,
      ⟨fun u hu => by simp [hu], fun _ h => h, fun _ h => h⟩, hcl, by simp⟩
  | c :: cs, e, hcl, hl => by
    obtain ⟨e', h1, h2, h3, h4, h5⟩ := e_run_drive t w cs
      { e with base := { e.base with loc := upd e.base.loc t (.collecting w cs),
                                      ran := e.base.ran ++ [c] } } hcl (by simp)
    refine ⟨e', esteps_trans W (esteps_single W (EStep.runOne e t w c cs hl)) h1, h2,
      Pres.trans (b := { e.base with loc := upd e.base.loc t (.collecting w cs), ran := e.base.ran ++ [c] })
        ⟨fun u hu => by simp [hu], fun _ h => h, fun _ h => by simp [h]⟩ h3, h4, ?_⟩
    intro x hx
    rcases List.mem_cons.1 hx with rfl | hx
    · exact h3.2.2 _ (by simp)
    · exact h5 x hx

theorem e_drain_thread (e : ESt) (t : Tid) (hcl : Clean e) :
    ∃ e', ESteps W e e' ∧ e'.base.loc t = .unregistered ∧ Pres t e.base e'.base ∧ Clean e' := by
  cases hl : e.base.loc t with
  | unregistered => exact ⟨e, .refl _, hl, .refl t _, hcl⟩
  | registered => exact e_release_drive W e t hcl hl
  | pinned st d =>
    obtain ⟨e1, a1, b1, c1, d1⟩ := e_unpin_drive W t st d e hcl hl
    obtain ⟨e2, a2, b2, c2, d2⟩ := e_release_drive W e1 t d1 b1
    exact ⟨e2, esteps_trans W a1 a2, b2, c1.trans c2, d2⟩
  | collecting w l =>
    obtain ⟨e1, a1, b1, c1, d1, -⟩ := e_run_drive W t w l e hcl hl
    cases w
    · exact ⟨e1, a1, by simpa using b1, c1, d1⟩
    · obtain ⟨e2, a2, b2, c2, d2⟩ := e_release_drive W e1 t d1 (by simpa using b1)
      exact ⟨e2, esteps_trans W a1 a2, b2, c1.trans c2, d2⟩

theorem e_drain_upto (e : ESt) (hcl : Clean e) : ∀ n : Nat, ∃ e', ESteps W e e' ∧
    (∀ t, t < n → e'.base.loc t = .unregistered) ∧ (∀ t, n ≤ t → e'.base.loc t = e.base.loc t) ∧
    (∀ c ∈ bufs e.base, c ∈ bufs e'.base) ∧ Clean e'
  | 0 => ⟨e, .refl _, fun _ h => absurd h (Nat.not_lt_zero _), fun _ _ => rfl, fun _ h => h, hcl⟩
  | n + 1 => by
    obtain ⟨e1, a1, b1, c1, d1, f1⟩ := e_drain_upto e hcl n
    obtain ⟨e2, a2, b2, c2, f2⟩ := e_drain_thread W e1 n f1
    refine ⟨e2, esteps_trans W a1 a2, ?_, ?_, fun c h => c2.2.1 c (d1 c h), f2⟩
    · intro t ht
      by_cases h' : t = n
      · subst h'; exact b2
      · rw [c2.1 t h']; exact b1 t (by omega)
    · intro t ht
      have hne : t ≠ n := by omega
      rw [c2.1 t hne]; exact c1 t (by omega)

/-- From a clean state, the drain schedule of `eventually_ran_aux` runs on the `Events`
model; the final `collect` from thread 0 passes the `EVENTS` check, after one escaping
`defer` if it would miss (`defer_escapes`). -/
theorem eventually_ran_clean {e : ESt} (h : Drainable e) (hW : 1 < W) (hcl : Clean e) (c : Cb)
    (hc : c ∈ bufs e.base) : ∃ e', ESteps W e e' ∧ c ∈ e'.base.ran := by
  obtain ⟨N, hN⟩ := reachable_finLoc h.2
  obtain ⟨e1, a1, b1, c1, d1, f1⟩ := e_drain_upto W e hcl N
  have hall : ∀ t, e1.base.loc t = .unregistered := fun t => by
    by_cases ht : t < N
    · exact b1 t ht
    · have hle : N ≤ t := Nat.le_of_not_lt ht
      rw [c1 t hle]; exact hN t hle
  -- reach a state `e2` (same base up to a queued defer) where thread 0's check is slow
  have key : ∃ e2, ESteps W e1 e2 ∧ (∀ t, e2.base.loc t = .unregistered) ∧ Clean e2 ∧
      c ∈ bufs e2.base ∧ events W e2 ≠ e2.seen 0 := by
    by_cases hev : events W e1 = e1.seen 0
    · refine ⟨_, esteps_single W (EStep.defer e1 0 false), hall, f1, ?_, ?_⟩
      · have := d1 c hc; simp [bufs] at this ⊢; grind
      · exact defer_escapes W hW 0 hev
    · exact ⟨e1, .refl _, hall, f1, d1 c hc, hev⟩
  obtain ⟨e2, a2, hall2, f2, hc2, hne⟩ := key
  have hr2 : Drainable e2 := drainable_steps W h (esteps_trans W a1 a2)
  have hnone : allNone e2.base.threads := fun t =>
    (Collect.threads_consistent hr2.2 t).1 (hall2 t)
  have hcu := (collectUnreg_takes_all e2.base hnone c hc2).1
  let e3 : ESt := { e2 with chk := upd e2.chk 0 true }
  let e4 : ESt := { setSeen e3 0 (events W e3) e3.total with
                      mid := upd e3.mid 0 true, chk := upd e3.chk 0 false }
  have s3 : EStep W e2 e3 := EStep.collectCheck e2 0 (.inr (hall2 0)) (f2 0).2.2 (f2 0).2.1 hne
  have s4 : EStep W e3 e4 := EStep.collectStore e3 0 (by simp [e3])
  have s5 := EStep.collectUnreg (W := W) e4 0 (by simpa [e4, e3, setSeen] using hall2 0) (by simp [e4])
  have a5 := esteps_trans W (esteps_trans W a1 a2) (.tail (.tail (.tail (.refl _) s3) s4) s5)
  have hb4 : e4.base = e2.base := rfl
  by_cases hb : c.byId = true
  · exact ⟨_, a5, by simp [startCollect, hb4, hcu, hb]⟩
  · obtain ⟨e6, a6, -, -, -, d6⟩ := e_run_drive W 0 false
      ((collectUnreg e4.base).2.filter (fun c => !c.byId))
      { e4 with base := startCollect 0 false (collectUnreg e4.base), mid := upd e4.mid 0 false }
      (by intro t; by_cases ht : t = 0 <;> simp [e4, e3, setSeen, ht, f2 t, f2 0])
      (by simp only [startCollect]; simp [upd])
    exact ⟨e6, esteps_trans W a5 a6, d6 c (List.mem_filter.2 ⟨by rw [hb4]; exact hcu, by cases e : c.byId <;> simp_all⟩)⟩

/-- **Reclamation is possible in the refined model** (an existential over schedules, not
liveness of every execution; for that see `EFair.efair_stable`). From any reachable
state, some schedule runs a queued callback `c`, where every `collect` now has to pass the
`EVENTS` check.

Wrap-around is handled by the schedule: it can always escape a missed event by doing one
more `defer` (it bumps `EVENTS`, so `gseen < total` with a gap that is not a multiple of `W`
when `1 < W`, and `fast_path_detects` applies; `defer_escapes`).

Proof: `eclean` finishes in-flight split steps to reach a `Clean` state (or runs `c`), then
`eventually_ran_clean` replays the base-model drain schedule and lets thread 0 collect. -/
theorem eventually_ran_drainable {e : ESt} (h : Drainable e) (hW : 1 < W) (c : Cb)
    (hc : c ∈ bufs e.base) :
    ∃ e', ESteps W e e' ∧ c ∈ e'.base.ran := by
  obtain ⟨e1, hs1, hr | ⟨hcl, hb⟩⟩ := eclean W h c hc
  · exact ⟨e1, hs1, hr⟩
  · exact eventually_ran_clean W (drainable_steps W h hs1) hW hcl c hb |>.imp
      fun e2 ⟨hs2, hr2⟩ => ⟨esteps_trans W hs1 hs2, hr2⟩

/-- `eventually_ran_drainable` from a reachable state. -/
theorem eventually_ran_events {e : ESt} (h : EReach W e) (hW : 1 < W) (c : Cb)
    (hc : c ∈ bufs e.base) :
    ∃ e', ESteps W e e' ∧ c ∈ e'.base.ran :=
  eventually_ran_drainable W (ereach_drainable W h) hW c hc

end Ev
end Collect
