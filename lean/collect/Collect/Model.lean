/-!
# Abstract model of `src/collect.rs`

A state-transition system over interleaved, atomic thread steps.

* Every `Collector` method runs under `COLLECTOR`'s mutex, so each is modelled as one atomic
  step (sequential consistency is sound for these, as they are serialised by the lock).
* Thread-local `DATA.state` is the `loc` field.
* This is the *abstract* model. `EVENTS` / `seen_events` only gate the fast path of
  `collect` (whether `collect_cold` runs at all), so here `collect_cold` may run at any time.
  The primary model `Collect.Ev.EStep` (`Events.lean`) adds them faithfully and refines this
  one; the headline theorems are stated on it in `Collect.Main`.
* Callbacks are abstract records; ghost field `time` is the logical time of the `defer`.
* Panics are ignored: `collect_cold` catches panics of individual callbacks and keeps
  running the rest, and the scope guards restore `state`, so the panic-free trace covers
  the normal effect on collector state.
-/

namespace Collect

/-- Thread identifiers (`ThreadId`). Unbounded. -/
abbrev Tid := Nat

/-- `ThreadState` -/
inductive TS where
  | quiet
  | busy
  deriving DecidableEq, Repr

/-- A deferred callback: a `Box<dyn FnOnce>` (`byId = false`) or a `defer_by_id`
pointer (`byId = true`, `id` is the pointer). `time` is a ghost timestamp. -/
structure Cb where
  id : Nat
  time : Nat
  byId : Bool
  deriving DecidableEq, Repr

/-- Thread-local `State`, enriched with ghost data:
* `pinned start depth`: `start` is the logical time the outermost `pin` began, `depth` is
  the number of additional nested `pin` calls.
* `collecting wasReg todo`: `wasReg` is the `old_state` saved by the guard in
  `collect_cold` (`true` = `Registered`), `todo` the callbacks still to run. -/
inductive LS where
  | unregistered
  | registered
  | pinned (start depth : Nat)
  | collecting (wasReg : Bool) (todo : List Cb)

/-- Thread-local states in which the thread must be a key of `Collector::threads`. -/
def LS.isReg : LS → Bool
  | .unregistered => false
  | .registered => true
  | .pinned .. => true
  | .collecting w _ => w

/-- Global state: the `Collector` plus all thread-locals and ghost state. -/
structure St where
  /-- ghost logical clock -/
  now : Nat
  /-- `DATA.state` of every thread -/
  loc : Tid → LS
  /-- `Collector::threads` -/
  threads : Tid → Option TS
  /-- `threads.len()` (the length `HashMap` stores; updated by `insert`/`remove`) -/
  len : Nat
  /-- `Collector::busy_count`. That it equals the number of `busy` entries is proved
  (`CInv`, `Collect/Count.lean`), not assumed. -/
  busy : Nat
  pending : List Cb
  current : List Cb
  previous : List Cb
  /-- ghost: closures that have been run, and `AtomicBool`s that were stored `true` -/
  ran : List Cb

def upd {α : Type} (f : Tid → α) (t : Tid) (v : α) : Tid → α :=
  fun u => if u = t then v else f u

@[simp] theorem upd_same {α} (f : Tid → α) t v : upd f t v t = v := by simp [upd]
@[simp] theorem upd_other {α} (f : Tid → α) t v u (h : u ≠ t) : upd f t v u = f u := by
  simp [upd, h]

/-- No `busy` entry (equivalent to `busy_count == 0` in reachable states, `busy_zero_iff`). -/
def noBusy (th : Tid → Option TS) : Prop := ∀ u, th u ≠ some .busy
/-- `threads.is_empty()` -/
def allNone (th : Tid → Option TS) : Prop := ∀ u, th u = none

open Classical in
/-- `Collector::complete_epoch` (the `EVENTS` signal is omitted). -/
noncomputable def completeEpoch (s : St) : St :=
  if allNone s.threads then
    { s with pending := s.pending ++ s.previous ++ s.current, previous := [], current := [] }
  else
    { s with pending := s.pending ++ s.previous,
             busy := s.len,
             threads := fun u => (s.threads u).map (fun _ => TS.busy),
             previous := s.current, current := [] }

open Classical in
/-- `Collector::unregister`. `remove` decrements `len`; a `Busy` entry decrements
`busy_count` (`- 1` truncates in `Nat`, but never underflows: `unregister_no_underflow`). -/
noncomputable def unregister (s : St) (t : Tid) : St :=
  let s' := { s with threads := upd s.threads t none, len := s.len - 1 }
  if s.threads t = some .busy then
    let s'' := { s' with busy := s.busy - 1 }
    (if s''.busy = 0 then completeEpoch s'' else s'')
  else if allNone s'.threads then completeEpoch s' else s'

/-- `mem::take(&mut self.pending)` -/
def takePending (s : St) : St × List Cb := ({ s with pending := [] }, s.pending)

open Classical in
/-- The middle of `quiet` for a `Busy` thread: decrement `busy_count`, mark it `Quiet` and
complete the epoch if the counter reached 0 (no underflow: `quiet_no_underflow`). -/
noncomputable def markQuiet (t : Tid) (s : St) : St :=
  if s.busy - 1 = 0 then
    completeEpoch { s with threads := upd s.threads t (some .quiet), busy := s.busy - 1 }
  else { s with threads := upd s.threads t (some .quiet), busy := s.busy - 1 }

open Classical in
/-- `Collector::quiet`, including its self-recursive call. `fuel` bounds the recursion
for proofs. It marks quiet first and takes `pending` once. The transition relation uses the
literal `quietRust` instead, and `quietRust_eq` proves `quietRust t s = quiet t 2 s` for all
`s` (same state and list), including that fuel 2 is never exhausted. -/
noncomputable def quiet (t : Tid) : Nat → St → St × List Cb
  | 0, s => (s, [])
  | fuel + 1, s =>
    if s.threads t ≠ some .busy then takePending s else
    let r := takePending (markQuiet t s)
    if s.busy - 1 = 0 ∧ r.1.previous ≠ [] then
      ((quiet t fuel r.1).1, r.2 ++ (quiet t fuel r.1).2)
    else r

/-- `self.busy_count -= 1; *state = ThreadState::Quiet` -/
def setQuiet (t : Tid) (s : St) : St :=
  { s with threads := upd s.threads t (some .quiet), busy := s.busy - 1 }

open Classical in
/-- `Collector::quiet`, literally as in Rust: take `pending`; return if not `Busy`; else
`busy_count -= 1`, mark `Quiet`, and if the count hit 0, `complete_epoch(false)`, take
`pending` again, and recurse if `previous_deferred` is non-empty. The recursion is genuine
(well-founded): the measure `2·|current| + [previous ≠ []]` drops because the recursive call
sees `current = []` (`complete_epoch` moved it to `previous`). This is the function the
transition relation uses; `quietRust_eq` shows it equals the fuel-based `quiet t 2` on which
the proofs are done. -/
noncomputable def quietRust (t : Tid) (s : St) : St × List Cb :=
  let r0 := takePending s
  if s.threads t ≠ some .busy then r0 else
  let s1 := setQuiet t r0.1
  if s1.busy = 0 then
    let r2 := takePending (completeEpoch s1)
    if _h : r2.1.previous ≠ [] then
      let q := quietRust t r2.1
      (q.1, r0.2 ++ r2.2 ++ q.2)
    else (r2.1, r0.2 ++ r2.2)
  else (s1, r0.2)
termination_by 2 * s.current.length + (if s.previous = [] then 0 else 1)
decreasing_by
  simp only [r2, s1, r0, takePending, setQuiet, completeEpoch] at _h ⊢
  by_cases ha : allNone (upd s.threads t (some TS.quiet))
  · simp [ha] at _h
  · simp only [ha, ite_false] at _h ⊢
    have : s.current.length ≠ 0 := by simpa using _h
    simp [_h]; omega

/-- With `current_deferred` empty (as in the inner call) `quiet` does not recurse. -/
theorem quietRust_cur_nil (t : Tid) (s : St) (hc : s.current = []) :
    quietRust t s = quiet t 1 s := by
  rw [quietRust.eq_1]
  simp only [quiet, markQuiet, setQuiet, takePending]
  by_cases hb : s.threads t = some .busy
  · simp only [hb, ne_eq, not_true_eq_false, ite_false]
    by_cases h0 : s.busy - 1 = 0
    · by_cases ha : allNone (upd s.threads t (some TS.quiet)) <;> simp [h0, ha, completeEpoch, hc]
    · simp [h0]
  · simp [hb]

/-- The Rust function returns exactly what the model `quiet t 2` returns (same state, same
callback list in the same order), for every state: the recursion is at most one level deep. -/
theorem quietRust_eq (t : Tid) (s : St) : quietRust t s = quiet t 2 s := by
  show quietRust t s = quiet t (1 + 1) s
  rw [quietRust.eq_1, quiet.eq_2]
  simp only [markQuiet, setQuiet, takePending]
  by_cases hb : s.threads t = some .busy
  · simp only [hb, ne_eq, not_true_eq_false, ite_false]
    by_cases h0 : s.busy - 1 = 0
    · by_cases ha : allNone (upd s.threads t (some TS.quiet))
      · simp [h0, ha, completeEpoch]
      · by_cases hp : s.current = []
        · simp [h0, ha, completeEpoch, hp]
        · simp only [h0, ha, completeEpoch, ite_true, ite_false, hp]
          rw [quietRust_cur_nil t _ rfl]
          simp
    · simp [h0]
  · simp [hb]
open Classical in
/-- `Collector::collect_unregistered` -/
noncomputable def collectUnreg (s : St) : St × List Cb :=
  if allNone s.threads then
    ({ s with pending := [], previous := [], current := [] },
      s.pending ++ s.previous ++ s.current)
  else ({ s with pending := [] }, s.pending)

/-- The locked part of `collect_cold`: after `quiet`/`collect_unregistered`, the
`defer_by_id` flags are marked ready *inside the lock* (`mark_ready`), the closures become
the thread's to-do list and the thread enters `Collecting`. -/
def startCollect (t : Tid) (wasReg : Bool) (r : St × List Cb) : St :=
  { r.1 with loc := upd r.1.loc t (.collecting wasReg (r.2.filter (fun c => !c.byId))),
             ran := r.1.ran ++ r.2.filter (fun c => c.byId) }

/-- `Callbacks::cancel_by_ids` -/
def cancelList (ids : List Nat) (l : List Cb) : List Cb :=
  l.filter (fun c => !(c.byId && ids.contains c.id))

/-- `pin` from `Unregistered`: `pin_cold` → `Collector::register`, then enter the region.
The thread is inserted as `Quiet`, unless no thread is `Busy` (`busy_count == 0`, which in
reachable states means `threads` is empty, `Fair.busy_zero_iff_empty`); then it is inserted as
`Busy` and `busy_count = 1`. -/
def register (s : St) (t : Tid) : St :=
  { s with now := s.now + 1, loc := upd s.loc t (.pinned s.now 0),
           threads := upd s.threads t (some (if s.busy = 0 then .busy else .quiet)),
           len := s.len + 1, busy := if s.busy = 0 then 1 else s.busy }

/-- One atomic step of some thread. -/
inductive Step : St → St → Prop
  /-- `pin` from `Unregistered`: `pin_cold` → `register`, then enter the region. -/
  | pinRegister (s : St) (t : Tid) : s.loc t = .unregistered → Step s (register s t)
  /-- `pin` from `Registered`. -/
  | pinOuter (s : St) (t : Tid) : s.loc t = .registered →
      Step s { s with now := s.now + 1, loc := upd s.loc t (.pinned s.now 0) }
  /-- nested `pin` -/
  | pinNest (s : St) (t : Tid) (st d : Nat) : s.loc t = .pinned st d →
      Step s { s with loc := upd s.loc t (.pinned st (d + 1)) }
  /-- leaving a nested `pin` (guard restores `Pinned`) -/
  | unpinNest (s : St) (t : Tid) (st d : Nat) : s.loc t = .pinned st (d + 1) →
      Step s { s with loc := upd s.loc t (.pinned st d) }
  /-- leaving the outermost `pin` (guard restores `Registered`) -/
  | unpinOuter (s : St) (t : Tid) (st : Nat) : s.loc t = .pinned st 0 →
      Step s { s with loc := upd s.loc t .registered }
  /-- `release`, also `ExitGuard::drop` -/
  | release (s : St) (t : Tid) : s.loc t = .registered →
      Step s (unregister { s with loc := upd s.loc t .unregistered } t)
  /-- `defer`, `defer_unchecked` (`byId = false`) and `defer_by_id` (`byId = true`).
  Callable from any thread state, including inside callbacks. -/
  | defer (s : St) (id : Nat) (byId : Bool) :
      Step s { s with now := s.now + 1, current := s.current ++ [⟨id, s.now, byId⟩] }
  /-- `cancel_by_ids` -/
  | cancel (s : St) (ids : List Nat) :
      Step s { s with pending := cancelList ids s.pending, current := cancelList ids s.current,
                      previous := cancelList ids s.previous }
  /-- `collect_cold` from `Registered` (locked part). -/
  | collectReg (s : St) (t : Tid) : s.loc t = .registered →
      Step s (startCollect t true (quietRust t s))
  /-- `collect_cold` from `Unregistered` (locked part). -/
  | collectUnreg (s : St) (t : Tid) : s.loc t = .unregistered →
      Step s (startCollect t false (collectUnreg s))
  /-- run one deferred closure, outside the lock -/
  | runOne (s : St) (t : Tid) (w : Bool) (c : Cb) (cs : List Cb) :
      s.loc t = .collecting w (c :: cs) →
      Step s { s with loc := upd s.loc t (.collecting w cs), ran := s.ran ++ [c] }
  /-- end of `collect_cold`: guard restores `old_state` -/
  | finish (s : St) (t : Tid) (w : Bool) : s.loc t = .collecting w [] →
      Step s { s with loc := upd s.loc t (if w then .registered else .unregistered) }

def init : St :=
  { now := 0, loc := fun _ => .unregistered, threads := fun _ => none, len := 0, busy := 0,
    pending := [], current := [], previous := [], ran := [] }

inductive Reachable : St → Prop
  | init : Reachable init
  | step {s s'} : Reachable s → Step s s' → Reachable s'

/-- Ghost: thread `u` is in a pinned region that began no later than `c` was deferred.
`Pin<'a>`'s contract says `c` must not run while this holds. -/
def blocked (loc : Tid → LS) (c : Cb) (u : Tid) : Prop :=
  ∃ st d, loc u = .pinned st d ∧ st ≤ c.time

end Collect
