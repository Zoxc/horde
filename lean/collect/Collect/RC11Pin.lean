import Collect.Weak
import Collect.RC11

/-!
# Property 11 over RC11 execution graphs

This file closes the "C11 step" of `Weak.lean`'s module docs: from an RC11-consistent execution
graph (`Collect/RC11.lean`) of a program using `collect`, it derives a model trace (a `WReach`
run of `Weak.WStep`) whose lock steps are in lock order and whose steps of each thread are in
program order, and from it the happens-before form of the `Pin` contract (`pin_contract`).

## The interface: what "an execution graph of a `collect` program" means (`CExec`)

This is the axiomatised part; it is kept small.

* The graph `G` is finite (`evs` lists all events) and RC11-consistent (`cons`).
* Every event carries a model action `act e : Act`: one per base-model step kind
  (`pinRegister`, `pinOuter`, ..., `runOne`, `finish`, `defer`, `cancel`), or `other` for
  events with no effect on the collector model (`EVENTS` accesses, `mark_ready`'s `Release`
  store, the client's own accesses, initialisation writes). Thread actions are performed by
  their thread (`thr`).
* **Critical sections.** The `COLLECTOR` mutex is a lock location `coll` (`RC11.LockLoc`: an
  initialisation write, then only `AcqRel` RMWs) and every *locked* action (`register`,
  `unregister`, `defer*`, `cancel_by_ids`, `quiet`, `collect_unregistered`, i.e. `pinRegister`,
  `release`, `defer`, `cancel`, `collectReg`, `collectUnreg`) is one such RMW (`locked_coll`).
  A whole critical section (lock, body, unlock) is collapsed into that one RMW event: the
  collector's data is only accessed under the mutex, so (for a race-free program) its effect
  is that of the sections run one after another in lock order. This is the standard
  "mutex as `AcqRel` RMW" encoding; the lock order is `mo` on `coll`.
* **The program** (`Valid`): along a linearisation `lin` of `hb`, every event's action is
  enabled in the model state reached by replaying the events before it (`replay`), i.e. each
  thread only performs operations the model allows in its current thread-local state
  (assumption 3 of `MAPPING.md`: misuse panics are not modelled). The values that events read
  and write are not used: the replay computes the collector state, and the only memory-model
  facts used are `po` and the lock order. `exists_valid_lin` packages the hypothesis as
  "every linearisation of `hb` is valid", which is lin-independent; it holds for a program
  whose thread-local control flow only depends on its own steps and on its critical sections.

`EVENTS` is not part of the interface: its accesses are `other` events. Its loads only decide
whether `collect` takes the fast path (whether a `collectReg`/`collectUnreg` event exists at
all), which does not matter for safety; the base model allows `collect_cold` at any time.

## Results

* `lock_hb`: in any linearisation of `hb`, locked events are in `hb` order (from
  `RC11.lock_mo_hb`: lock order `⊆ hb`), and `lin_po`: same-thread events are in `po` order.
* `replay_wreach`: the replay of a valid linearisation is a run of the model (`WReach`), so
  every theorem about `WReach`/`Reachable` applies to it.
* `pin_contract`: for a pinned region `R` of thread `u` (from its outermost `pin` event `a`,
  `InRegion`), a callback `c` deferred by `D` and present (run, marked ready, or in a to-do
  list) just after a locked event `T`: `D hb a`, or every event of `R` happens before `T`.
* `pin_contract_run` / `pin_contract_flag`: the same with `T` replaced by the run of the
  callback (an event `po`-after `T`), or by the client's `Acquire` load reading the flag's
  `Release` store `mark_ready` (`po`-after `T`).
-/

namespace Collect.RC11Pin
open Collect Collect.Weak RC11 RC11.Graph

/-- Model actions of events. -/
inductive Act where
  | pinRegister (t : Tid)
  | pinOuter (t : Tid)
  | pinNest (t : Tid)
  | unpinNest (t : Tid)
  | unpinOuter (t : Tid)
  | release (t : Tid)
  | defer (id : Nat) (byId : Bool)
  | cancel (ids : List Nat)
  | collectReg (t : Tid)
  | collectUnreg (t : Tid)
  | runOne (t : Tid)
  | finish (t : Tid)
  | other
  deriving DecidableEq

/-- The thread whose local state the action uses. -/
def Act.thr : Act → Option Tid
  | .pinRegister t | .pinOuter t | .pinNest t | .unpinNest t | .unpinOuter t | .release t
  | .collectReg t | .collectUnreg t | .runOne t | .finish t => some t
  | .defer .. | .cancel _ | .other => none

/-- Actions that run under the `COLLECTOR` mutex. -/
def Act.locked : Act → Bool
  | .pinRegister _ | .release _ | .defer .. | .cancel _ | .collectReg _ | .collectUnreg _ => true
  | _ => false

/-- When the action is a model step from `s` (otherwise the program would panic). -/
def enabled : Act → St → Prop
  | .pinRegister t, s => s.loc t = .unregistered
  | .pinOuter t, s => s.loc t = .registered
  | .pinNest t, s => ∃ st d, s.loc t = .pinned st d
  | .unpinNest t, s => ∃ st d, s.loc t = .pinned st (d + 1)
  | .unpinOuter t, s => ∃ st, s.loc t = .pinned st 0
  | .release t, s => s.loc t = .registered
  | .collectReg t, s => s.loc t = .registered
  | .collectUnreg t, s => s.loc t = .unregistered
  | .runOne t, s => ∃ w c cs, s.loc t = .collecting w (c :: cs)
  | .finish t, s => ∃ w, s.loc t = .collecting w []
  | _, _ => True

/-- The model step of an action (with `Weak`'s ghost `pt`). -/
noncomputable def apply : Act → WSt → WSt
  | .pinRegister t, e => ⟨register e.s t, upd e.pt t e.s.now⟩
  | .pinOuter t, e => ⟨{ e.s with now := e.s.now + 1, loc := upd e.s.loc t (.pinned e.s.now 0) }, e.pt⟩
  | .pinNest t, e => match e.s.loc t with
    | .pinned st d => ⟨{ e.s with loc := upd e.s.loc t (.pinned st (d + 1)) }, e.pt⟩
    | _ => e
  | .unpinNest t, e => match e.s.loc t with
    | .pinned st (d + 1) => ⟨{ e.s with loc := upd e.s.loc t (.pinned st d) }, e.pt⟩
    | _ => e
  | .unpinOuter t, e => match e.s.loc t with
    | .pinned _ 0 => ⟨{ e.s with loc := upd e.s.loc t .registered }, e.pt⟩
    | _ => e
  | .release t, e => ⟨unregister { e.s with loc := upd e.s.loc t .unregistered } t, e.pt⟩
  | .defer id byId, e =>
    ⟨{ e.s with now := e.s.now + 1, current := e.s.current ++ [⟨id, e.s.now, byId⟩] }, e.pt⟩
  | .cancel ids, e =>
    ⟨{ e.s with pending := cancelList ids e.s.pending, current := cancelList ids e.s.current,
                previous := cancelList ids e.s.previous }, e.pt⟩
  | .collectReg t, e => ⟨startCollect t true (quietRust t e.s), upd e.pt t e.s.now⟩
  | .collectUnreg t, e => ⟨startCollect t false (collectUnreg e.s), e.pt⟩
  | .runOne t, e => match e.s.loc t with
    | .collecting w (c :: cs) => ⟨{ e.s with loc := upd e.s.loc t (.collecting w cs), ran := e.s.ran ++ [c] }, e.pt⟩
    | _ => e
  | .finish t, e => match e.s.loc t with
    | .collecting w [] => ⟨{ e.s with loc := upd e.s.loc t (if w then .registered else .unregistered) }, e.pt⟩
    | _ => e
  | .other, e => e

/-! ## The action semantics is the model's -/

theorem quietRust_loc (t : Tid) (s : St) : (quietRust t s).1.loc = s.loc := by
  rw [quietRust_eq]; exact quiet_loc t 2 s

/-- An enabled action is a `WStep` or a stutter. -/
theorem apply_step {a : Act} {e : WSt} (hen : enabled a e.s) : apply a e = e ∨ WStep e (apply a e) := by
  obtain ⟨s, pt⟩ := e
  cases a <;> simp only [enabled] at hen
  case pinRegister t => exact .inr (.pinRegister s pt t hen)
  case collectReg t => exact .inr (.collectReg s pt t hen)
  case other => exact .inl rfl
  case pinOuter t =>
    refine .inr (.other _ _ pt (.pinOuter s t hen) ?_ ?_)
    · intro u hu; by_cases h : u = t <;> simp_all [LS.isReg]
    · intro u hu l; by_cases h : u = t <;> simp_all
  case pinNest t =>
    obtain ⟨st, d, hl⟩ := hen
    simp only [apply]; rw [hl]
    refine .inr (.other _ _ pt (.pinNest s t st d hl) ?_ ?_)
    · intro u hu; by_cases h : u = t <;> simp_all [LS.isReg]
    · intro u hu l; by_cases h : u = t <;> simp_all
  case unpinNest t =>
    obtain ⟨st, d, hl⟩ := hen
    simp only [apply]; rw [hl]
    refine .inr (.other _ _ pt (.unpinNest s t st d hl) ?_ ?_)
    · intro u hu; by_cases h : u = t <;> simp_all [LS.isReg]
    · intro u hu l; by_cases h : u = t <;> simp_all
  case unpinOuter t =>
    obtain ⟨st, hl⟩ := hen
    simp only [apply]; rw [hl]
    refine .inr (.other _ _ pt (.unpinOuter s t st hl) ?_ ?_)
    · intro u hu; by_cases h : u = t <;> simp_all [LS.isReg]
    · intro u hu l; by_cases h : u = t <;> simp_all
  case release t =>
    refine .inr (.other _ _ pt (.release s t hen) ?_ ?_)
    · intro u hu; by_cases h : u = t <;> simp_all [LS.isReg]
    · intro u hu l; by_cases h : u = t <;> simp_all
  case defer id byId =>
    refine .inr (.other _ _ pt (.defer s id byId) ?_ ?_)
    · intro u hu; simp_all [LS.isReg]
    · intro u hu l; simp_all
  case cancel ids =>
    refine .inr (.other _ _ pt (.cancel s ids) ?_ ?_)
    · intro u hu; simp_all [LS.isReg]
    · intro u hu l; simp_all
  case collectUnreg t =>
    refine .inr (.other _ _ pt (.collectUnreg s t hen) ?_ ?_)
    · intro u hu; by_cases h : u = t
      · subst h; simp [startCollect, LS.isReg]
      · simp only [startCollect, upd_other _ _ _ _ h, collectUnreg_loc]; simp [hu, LS.isReg]
    · intro u hu l; by_cases h : u = t
      · subst h; simp_all
      · simp only [startCollect, upd_other _ _ _ _ h]
        unfold collectUnreg; split <;> simp_all
  case runOne t =>
    obtain ⟨w, c, cs, hl⟩ := hen
    simp only [apply]; rw [hl]
    refine .inr (.other _ _ pt (.runOne s t w c cs hl) ?_ ?_)
    · intro u hu; by_cases h : u = t <;> simp_all [LS.isReg]
    · intro u hu l; by_cases h : u = t <;> simp_all
  case finish t =>
    obtain ⟨w, hl⟩ := hen
    simp only [apply]; rw [hl]
    refine .inr (.other _ _ pt (.finish s t w hl) ?_ ?_)
    · intro u hu; by_cases h : u = t <;> simp_all [LS.isReg]
    · intro u hu l; by_cases h : u = t <;> simp_all

/-- Actions of other threads (and `defer`/`cancel`/`other`) leave `u`'s local state and `pt u`
alone. -/
theorem apply_other {a : Act} {u : Tid} (h : a.thr ≠ some u) (e : WSt) :
    (apply a e).s.loc u = e.s.loc u ∧ (apply a e).pt u = e.pt u := by
  obtain ⟨s, pt⟩ := e
  cases a with
  | pinRegister t | pinOuter t | release t | collectReg t | collectUnreg t =>
    have hu : u ≠ t := fun hu => h (by simp [Act.thr, hu])
    simp [apply, register, startCollect, quietRust_loc, collectUnreg_loc, hu]
  | pinNest t | unpinNest t | unpinOuter t | runOne t | finish t =>
    have hu : u ≠ t := fun hu => h (by simp [Act.thr, hu])
    simp only [apply]; split <;> simp [hu]
  | defer _ _ | cancel _ | other => simp [apply]

theorem apply_pt {a : Act} {u : Tid} (h1 : a ≠ .pinRegister u) (h2 : a ≠ .collectReg u)
    (e : WSt) : (apply a e).pt u = e.pt u := by
  by_cases ht : a.thr = some u
  · obtain ⟨s, pt⟩ := e
    cases a <;> simp [Act.thr] at ht <;> subst ht <;> simp_all [apply] <;> split <;> rfl
  · exact (apply_other ht e).2

theorem apply_pt_set {a : Act} {u : Tid} (h : a = .pinRegister u ∨ a = .collectReg u)
    (e : WSt) : (apply a e).pt u = e.s.now := by
  rcases h with rfl | rfl <;> simp [apply]

def isPin : LS → Prop
  | .pinned .. => True
  | _ => False

theorem isPin_isReg {l : LS} (h : isPin l) : l.isReg = true := by
  cases l <;> simp_all [isPin, LS.isReg]

/-- Only `pinRegister` makes a thread registered. -/
theorem isReg_up {a : Act} {e : WSt} {u : Tid} (hen : enabled a e.s)
    (h0 : (e.s.loc u).isReg = false) (h1 : ((apply a e).s.loc u).isReg = true) :
    a = .pinRegister u := by
  by_cases ht : a.thr = some u
  · obtain ⟨s, pt⟩ := e
    cases a <;> simp only [Act.thr, Option.some.injEq, reduceCtorEq] at ht <;> subst ht <;>
      simp only [enabled] at hen <;> dsimp only at h0
    case pinRegister => rfl
    case pinOuter => simp [hen, LS.isReg] at h0
    case pinNest => obtain ⟨st, d, hl⟩ := hen; simp [hl, LS.isReg] at h0
    case unpinNest => obtain ⟨st, d, hl⟩ := hen; simp [hl, LS.isReg] at h0
    case unpinOuter => obtain ⟨st, hl⟩ := hen; simp [hl, LS.isReg] at h0
    case release => simp [hen, LS.isReg] at h0
    case collectReg => simp [hen, LS.isReg] at h0
    case collectUnreg => simp [apply, startCollect, LS.isReg] at h1
    case runOne =>
      obtain ⟨w, c, cs, hl⟩ := hen; simp only [apply] at h1; rw [hl] at h1
      simp [hl, LS.isReg] at h0 h1; simp_all
    case finish =>
      obtain ⟨w, hl⟩ := hen; simp only [apply] at h1; rw [hl] at h1
      cases w <;> simp [hl, LS.isReg] at h0 h1
  · rw [(apply_other ht e).1] at h1; simp_all

/-- Only `release` makes a thread unregistered. -/
theorem isReg_down {a : Act} {e : WSt} {u : Tid} (hen : enabled a e.s)
    (h0 : (e.s.loc u).isReg = true) (h1 : ((apply a e).s.loc u).isReg = false) :
    a = .release u := by
  by_cases ht : a.thr = some u
  · obtain ⟨s, pt⟩ := e
    cases a <;> simp only [Act.thr, Option.some.injEq, reduceCtorEq] at ht <;> subst ht <;>
      simp only [enabled] at hen <;> dsimp only at h0
    case pinRegister => simp [hen, LS.isReg] at h0
    case pinOuter => simp [apply, LS.isReg] at h1
    case pinNest => obtain ⟨st, d, hl⟩ := hen; simp only [apply] at h1; rw [hl] at h1; simp [LS.isReg] at h1
    case unpinNest => obtain ⟨st, d, hl⟩ := hen; simp only [apply] at h1; rw [hl] at h1; simp [LS.isReg] at h1
    case unpinOuter => obtain ⟨st, hl⟩ := hen; simp only [apply] at h1; rw [hl] at h1; simp [LS.isReg] at h1
    case release => rfl
    case collectReg => simp [apply, startCollect, LS.isReg] at h1
    case collectUnreg => simp [hen, LS.isReg] at h0
    case runOne =>
      obtain ⟨w, c, cs, hl⟩ := hen; simp only [apply] at h1; rw [hl] at h1
      simp [hl, LS.isReg] at h0 h1; simp_all
    case finish =>
      obtain ⟨w, hl⟩ := hen; simp only [apply] at h1; rw [hl] at h1
      cases w <;> simp [hl, LS.isReg] at h0 h1
  · rw [(apply_other ht e).1] at h1; simp_all

/-- Inside a pinned region only `unpinOuter` leaves it. -/
theorem pin_keep {a : Act} {e : WSt} {u : Tid} (hen : enabled a e.s) (h0 : isPin (e.s.loc u))
    (hne : a ≠ .unpinOuter u) : isPin ((apply a e).s.loc u) := by
  by_cases ht : a.thr = some u
  · obtain ⟨s, pt⟩ := e
    cases a <;> simp only [Act.thr, Option.some.injEq, reduceCtorEq] at ht <;> subst ht <;>
      simp only [enabled] at hen <;> dsimp only at h0
    case pinRegister => rw [hen] at h0; simp [isPin] at h0
    case pinOuter => simp [apply, isPin]
    case pinNest => obtain ⟨st, d, hl⟩ := hen; simp only [apply]; rw [hl]; simp [isPin]
    case unpinNest => obtain ⟨st, d, hl⟩ := hen; simp only [apply]; rw [hl]; simp [isPin]
    case unpinOuter => exact (hne rfl).elim
    case release => rw [hen] at h0; simp [isPin] at h0
    case collectReg => rw [hen] at h0; simp [isPin] at h0
    case collectUnreg => rw [hen] at h0; simp [isPin] at h0
    case runOne => obtain ⟨w, c, cs, hl⟩ := hen; rw [hl] at h0; simp [isPin] at h0
    case finish => obtain ⟨w, hl⟩ := hen; rw [hl] at h0; simp [isPin] at h0
  · rw [(apply_other ht e).1]; exact h0

theorem pin_after {a : Act} {e : WSt} {u : Tid} (ha : a = .pinRegister u ∨ a = .pinOuter u) :
    isPin ((apply a e).s.loc u) := by
  rcases ha with rfl | rfl <;> simp [apply, register, isPin]

/-- The pre-state of a locked own step that is not `defer`/`cancel` is not pinned. -/
theorem not_pin_of {a : Act} {s : St} {u : Tid} (hen : enabled a s)
    (ha : a = .pinRegister u ∨ a = .collectReg u ∨ a = .release u) : ¬ isPin (s.loc u) := by
  rcases ha with rfl | rfl | rfl <;> simp only [enabled] at hen <;> simp [hen, isPin]

/-! ## Execution graphs of `collect` programs -/

/-- An RC11-consistent execution graph of a program using `collect` (module docs). -/
structure CExec (E L V : Type) where
  G : Graph E L V
  evs : List E
  all : ∀ e, e ∈ evs
  cons : G.Consistent
  act : E → Act
  /-- the `COLLECTOR` mutex and its initialisation write -/
  coll : L
  init : E
  lock : LockLoc G coll init
  /-- every locked action is a critical section: an `AcqRel` RMW on `coll` -/
  locked_coll : ∀ e, (act e).locked = true → G.isW e ∧ G.loc e = coll
  /-- thread actions are performed by their thread -/
  thr : ∀ e t, (act e).thr = some t → G.tid e = t

namespace CExec
variable {E L V : Type} (X : CExec E L V)

/-- The model state after replaying the first `i` events of `lin`. -/
noncomputable def replay (lin : List E) (i : Nat) : WSt :=
  ((lin.take i).map X.act).foldl (fun e a => apply a e) winit

/-- The program assumption along `lin`: each event's action is enabled when it is replayed. -/
def Valid (lin : List E) : Prop :=
  ∀ i x, lin[i]? = some x → enabled (X.act x) (X.replay lin i).s

/-- A pinned region of `u` starting at its outermost `pin` event `a`: `u`'s events from `a` on,
up to (excluding) the next `unpinOuter`. -/
def InRegion (u : Tid) (a x : E) : Prop :=
  X.G.tid x = u ∧ (x = a ∨ X.G.po a x) ∧
    ∀ z, (z = a ∨ X.G.po a z) → X.G.po z x → X.act z ≠ .unpinOuter u

variable {X}

theorem replay_succ {lin : List E} {i : Nat} {x : E} (h : lin[i]? = some x) :
    X.replay lin (i + 1) = apply (X.act x) (X.replay lin i) := by
  simp [replay, List.take_add_one, h, List.foldl_append]

theorem replay_none {lin : List E} {i : Nat} (h : lin[i]? = none) :
    X.replay lin (i + 1) = X.replay lin i := by
  simp [replay, List.take_add_one, h]

/-- **The replay is a run of the model.** -/
theorem replay_wreach {lin : List E} (hv : X.Valid lin) : ∀ i, WReach (X.replay lin i)
  | 0 => by simp [replay]; exact .init
  | i + 1 => by
    have ih := replay_wreach hv i
    cases h : lin[i]? with
    | none => rw [replay_none h]; exact ih
    | some x =>
      rw [replay_succ h]
      rcases apply_step (hv i x h) with he | he
      · rw [he]; exact ih
      · exact .step ih he

theorem replay_now_mono {lin : List E} (hv : X.Valid lin) {i k : Nat} (hik : i ≤ k) :
    (X.replay lin i).s.now ≤ (X.replay lin k).s.now := by
  induction k with
  | zero => have : i = 0 := by omega
            subst this; exact Nat.le_refl _
  | succ k ih =>
    rcases Nat.eq_or_lt_of_le hik with h | h
    · subst h; exact Nat.le_refl _
    have ih := ih (by omega)
    cases hx : lin[k]? with
    | none => rw [replay_none hx]; exact ih
    | some x =>
      rw [replay_succ hx]
      rcases apply_step (hv k x hx) with he | he
      · rw [he]; exact ih
      · exact Nat.le_trans ih (step_now_le (wreach_reach (replay_wreach hv k)) (wstep_step he))

theorem idx_eq {lin : List E} (hl : lin.Nodup) {i j : Nat} {x y : E} (hx : lin[i]? = some x)
    (hy : lin[j]? = some y) (hxy : x = y) : i = j :=
  (List.Nodup.getElem?_inj (List.getElem?_eq_some_iff.1 hx).1 hl).1 (by rw [hx, hy, hxy])

theorem lin_idx {lin : List E} (hlin : IsLin X.G.hb lin) (x : E) : ∃ i : Nat, lin[i]? = some x :=
  List.mem_iff_getElem?.1 (hlin.1 x)

/-- Locked events are in `hb` order in a linearisation of `hb` (lock order `⊆ hb`). -/
theorem lock_hb {lin : List E} (hlin : IsLin X.G.hb lin) {i j : Nat} {x y : E}
    (hx : lin[i]? = some x) (hy : lin[j]? = some y) (hij : i < j)
    (lx : (X.act x).locked = true) (ly : (X.act y).locked = true) : X.G.hb x y := by
  obtain ⟨wx, cx⟩ := X.locked_coll x lx
  obtain ⟨wy, cy⟩ := X.locked_coll y ly
  exact lin_lock_hb X.cons X.lock X.evs X.all hlin hx hy hij wx wy cx cy

theorem lock_hb_le {lin : List E} (hlin : IsLin X.G.hb lin) {i j : Nat} {x y : E}
    (hx : lin[i]? = some x) (hy : lin[j]? = some y) (hij : i ≤ j)
    (lx : (X.act x).locked = true) (ly : (X.act y).locked = true) : x = y ∨ X.G.hb x y := by
  rcases Nat.eq_or_lt_of_le hij with h | h
  · subst h; rw [hx] at hy; exact .inl (Option.some.inj hy)
  · exact .inr (lock_hb hlin hx hy h lx ly)

/-! ## Thread-local facts along the replay -/

/-- A registered thread's `pt` was set by its latest `pinRegister`/`collectReg`. -/
theorem replay_pt {lin : List E} (hv : X.Valid lin) (u : Tid) : ∀ i,
    ((X.replay lin i).s.loc u).isReg = true →
    ∃ j < i, ∃ y, lin[j]? = some y ∧ (X.act y = .pinRegister u ∨ X.act y = .collectReg u) ∧
      (X.replay lin i).pt u = (X.replay lin j).s.now
  | 0, h => by simp [replay, winit, Collect.init, LS.isReg] at h
  | i + 1, h => by
    cases hx : lin[i]? with
    | none =>
      rw [replay_none hx] at h ⊢
      obtain ⟨j, hj, y, hy⟩ := replay_pt hv u i h
      exact ⟨j, by omega, y, hy⟩
    | some x =>
      rw [replay_succ hx] at h ⊢
      by_cases hs : X.act x = .pinRegister u ∨ X.act x = .collectReg u
      · exact ⟨i, by omega, x, hx, hs, apply_pt_set hs _⟩
      · rw [apply_pt (fun h => hs (.inl h)) (fun h => hs (.inr h))]
        by_cases h0 : ((X.replay lin i).s.loc u).isReg = true
        · obtain ⟨j, hj, y, hy⟩ := replay_pt hv u i h0
          exact ⟨j, by omega, y, hy⟩
        · exact (hs (.inl (isReg_up (hv i x hx) (by simpa using h0) h))).elim

theorem replay_down {lin : List E} (hv : X.Valid lin) (u : Tid) (i : Nat) : ∀ k, i ≤ k →
    ((X.replay lin i).s.loc u).isReg = true → ((X.replay lin k).s.loc u).isReg = false →
    ∃ j, i ≤ j ∧ j < k ∧ ∃ y, lin[j]? = some y ∧ X.act y = .release u
  | 0, hik, h1, h2 => by
    have : i = 0 := by omega
    subst this; simp_all
  | k + 1, hik, h1, h2 => by
    rcases Nat.eq_or_lt_of_le hik with h | h
    · subst h; simp_all
    by_cases hk : ((X.replay lin k).s.loc u).isReg = true
    · cases hx : lin[k]? with
      | none => rw [replay_none hx] at h2; simp_all
      | some x =>
        rw [replay_succ hx] at h2
        exact ⟨k, by omega, by omega, x, hx, isReg_down (hv k x hx) hk h2⟩
    · obtain ⟨j, hj⟩ := replay_down hv u i k (by omega) h1 (by simpa using hk)
      exact ⟨j, hj.1, by omega, hj.2.2⟩

theorem replay_up {lin : List E} (hv : X.Valid lin) (u : Tid) (i : Nat) : ∀ k, i ≤ k →
    ((X.replay lin i).s.loc u).isReg = false → ((X.replay lin k).s.loc u).isReg = true →
    ∃ j, i ≤ j ∧ j < k ∧ ∃ y, lin[j]? = some y ∧ X.act y = .pinRegister u
  | 0, hik, h1, h2 => by
    have : i = 0 := by omega
    subst this; simp_all
  | k + 1, hik, h1, h2 => by
    rcases Nat.eq_or_lt_of_le hik with h | h
    · subst h; simp_all
    by_cases hk : ((X.replay lin k).s.loc u).isReg = false
    · cases hx : lin[k]? with
      | none => rw [replay_none hx] at h2; simp_all
      | some x =>
        rw [replay_succ hx] at h2
        exact ⟨k, by omega, by omega, x, hx, isReg_up (hv k x hx) hk h2⟩
    · obtain ⟨j, hj⟩ := replay_up hv u i k (by omega) h1 (by simpa using hk)
      exact ⟨j, hj.1, by omega, hj.2.2⟩

/-- Between an outermost `pin` and the next `unpinOuter` of `u`, `u` is pinned. -/
theorem replay_region {lin : List E} (hv : X.Valid lin) {u : Tid} {ia : Nat} {a : E}
    (ha : lin[ia]? = some a) (haa : X.act a = .pinRegister u ∨ X.act a = .pinOuter u) :
    ∀ k, ia < k → (∀ j z, ia ≤ j → j < k → lin[j]? = some z → X.act z ≠ .unpinOuter u) →
      isPin ((X.replay lin k).s.loc u)
  | 0, h, _ => by omega
  | k + 1, h, hz => by
    by_cases hk : k = ia
    · subst hk; rw [replay_succ ha]; exact pin_after haa
    have ih := replay_region hv ha haa k (by omega) (fun j z h1 h2 => hz j z h1 (by omega))
    cases hx : lin[k]? with
    | none => rw [replay_none hx]; exact ih
    | some x =>
      rw [replay_succ hx]
      exact pin_keep (hv k x hx) ih (hz k x (by omega) (by omega) hx)

/-- An own event `y` of `u` after the region's start whose pre-state is not pinned comes after
every event of the region. -/
theorem region_before {lin : List E} (hlin : IsLin X.G.hb lin) (hv : X.Valid lin) {u : Tid}
    {ia iy ix : Nat} {a y x : E} (ha : lin[ia]? = some a)
    (haa : X.act a = .pinRegister u ∨ X.act a = .pinOuter u)
    (_hy : lin[iy]? = some y) (hay : ia < iy) (hnp : ¬ isPin ((X.replay lin iy).s.loc u))
    (hx : lin[ix]? = some x) (hR : X.InRegion u a x) : ix < iy := by
  apply Nat.lt_of_not_le
  intro hle
  apply hnp
  refine replay_region hv ha haa iy hay ?_
  intro j z hj1 hj2 hz hzu
  have htz : X.G.tid z = u := X.thr z u (by simp [hzu, Act.thr])
  have hta : X.G.tid a = u := X.thr a u (by rcases haa with h | h <;> simp [h, Act.thr])
  have hza : z = a ∨ X.G.po a z := by
    rcases Nat.eq_or_lt_of_le hj1 with h | h
    · subst h; rw [ha] at hz; exact .inl (Option.some.inj hz).symm
    · exact .inr (lin_po X.cons.toWF hlin ha hz h (hta.trans htz.symm))
  exact hR.2.2 z hza (lin_po X.cons.toWF hlin hz hx (by omega) (htz.trans hR.1.symm)) hzu

/-! ## The `Pin` contract in happens-before terms -/

/-- **Property 11 over RC11 graphs.** Let `lin` be a linearisation of `hb` along which the
program is valid. Let `a` be the outermost `pin` of a pinned region of `u`, `D` the `defer` of
callback `c` (in the replay, `c.time` is the clock at `D`), and `T` a locked event (a
critical section, e.g. the `quiet`/`collect_unregistered` that takes `c`) just after which `c`
has been run or marked ready, or is in a to-do list. Then `D hb a`, or every event of the
region happens before `T`. -/
theorem pin_contract {lin : List E} (hlin : IsLin X.G.hb lin) (hv : X.Valid lin)
    {T D a : E} {u : Tid} {c : Cb} {iT iD ia : Nat}
    (hT : lin[iT]? = some T) (hTl : (X.act T).locked = true)
    (hc : c ∈ (X.replay lin (iT + 1)).s.ran ∨
      ∃ v w l, (X.replay lin (iT + 1)).s.loc v = .collecting w l ∧ c ∈ l)
    (hD : lin[iD]? = some D) (hDa : X.act D = .defer c.id c.byId)
    (hDt : (X.replay lin iD).s.now = c.time)
    (ha : lin[ia]? = some a) (haa : X.act a = .pinRegister u ∨ X.act a = .pinOuter u) :
    X.G.hb D a ∨ ∀ x, X.InRegion u a x → X.G.hb x T := by
  have hw := X.cons.toWF
  have hrch := replay_wreach hv (iT + 1)
  have hinv := reachable_inv (wreach_reach hrch)
  have hDl : (X.act D).locked = true := by simp [hDa, Act.locked]
  have hta : X.G.tid a = u := X.thr a u (by rcases haa with h | h <;> simp [h, Act.thr])
  -- `D` is before `T`.
  have hctime : c.time < (X.replay lin (iT + 1)).s.now := by
    rcases hc with hc | ⟨v, w, l, hv', hc⟩
    · exact hinv.timeRan c hc
    · exact hinv.timeTodo v w l hv' c hc
  have hDT : iD < iT + 1 := by
    apply Nat.lt_of_not_le; intro hle
    have := replay_now_mono hv hle; omega
  -- `y` (an own step of `u`, index `j`) after `D` and at or before `a` gives `D hb a`.
  have left : ∀ j y, lin[j]? = some y → iD < j → j ≤ ia → (X.act y).locked = true →
      X.G.tid y = u → X.G.hb D a := by
    intro j y hy hDj hja hyl hty
    have h1 := lock_hb hlin hD hy hDj hDl hyl
    rcases Nat.eq_or_lt_of_le hja with h | h
    · subst h; rw [hy] at ha; cases Option.some.inj ha; exact h1
    · exact hb_trans h1 (po_hb (lin_po hw hlin hy ha h (hty.trans hta.symm)))
  -- `y` (an own lock step of `u` with non-pinned pre-state) after `a` and at or before `T`
  -- gives `R hb T`.
  have right : ∀ j y, lin[j]? = some y → ia < j → j ≤ iT → (X.act y).locked = true →
      X.G.tid y = u → ¬ isPin ((X.replay lin j).s.loc u) → ∀ x, X.InRegion u a x → X.G.hb x T := by
    intro j y hy haj hjT hyl hty hnp x hR
    obtain ⟨ix, hx⟩ := lin_idx hlin x
    have hxj := region_before hlin hv ha haa hy haj hnp hx hR
    have hxy : X.G.hb x y := po_hb (lin_po hw hlin hx hy hxj (hR.1.trans hty.symm))
    rcases lock_hb_le hlin hy hT hjT hyl hTl with h | h
    · subst h; exact hxy
    · exact hb_trans hxy h
  by_cases hreg : ((X.replay lin (iT + 1)).s.loc u).isReg = true
  · obtain ⟨j, hj, y, hy, hya, hpt⟩ := replay_pt hv u (iT + 1) hreg
    have hws := weak_safety hrch c hc u hreg
    rw [hpt] at hws
    have hDj : iD < j := by
      apply Nat.lt_of_not_le; intro hle
      have := replay_now_mono hv hle; omega
    have hyl : (X.act y).locked = true := by rcases hya with h | h <;> simp [h, Act.locked]
    have hty : X.G.tid y = u := X.thr y u (by rcases hya with h | h <;> simp [h, Act.thr])
    by_cases hja : j ≤ ia
    · exact .inl (left j y hy hDj hja hyl hty)
    · refine .inr (right j y hy (by omega) (by omega) hyl hty ?_)
      exact not_pin_of (hv j y hy) (by rcases hya with h | h <;> simp [h])
  · have hpa : ((X.replay lin (ia + 1)).s.loc u).isReg = true := by
      rw [replay_succ ha]; exact isPin_isReg (pin_after haa)
    by_cases hTa : ia ≤ iT
    · obtain ⟨j, hj1, hj2, y, hy, hya⟩ :=
        replay_down hv u (ia + 1) (iT + 1) (by omega) hpa (by simpa using hreg)
      refine .inr (right j y hy (by omega) (by omega) (by simp [hya, Act.locked])
        (X.thr y u (by simp [hya, Act.thr])) ?_)
      exact not_pin_of (hv j y hy) (by simp [hya])
    · obtain ⟨j, hj1, hj2, y, hy, hya⟩ :=
        replay_up hv u (iT + 1) (ia + 1) (by omega) (by simpa using hreg) hpa
      exact .inl (left j y hy (by omega) (by omega) (by simp [hya, Act.locked])
        (X.thr y u (by simp [hya, Act.thr])))

/-- `pin_contract` with `T` replaced by any event `T` happens before, e.g. the run of the
callback (`runOne`, `po`-after the `quiet`/`collect_unregistered` that took it). -/
theorem pin_contract_run {lin : List E} (hlin : IsLin X.G.hb lin) (hv : X.Valid lin)
    {T D a F : E} {u : Tid} {c : Cb} {iT iD ia : Nat}
    (hT : lin[iT]? = some T) (hTl : (X.act T).locked = true)
    (hc : c ∈ (X.replay lin (iT + 1)).s.ran ∨
      ∃ v w l, (X.replay lin (iT + 1)).s.loc v = .collecting w l ∧ c ∈ l)
    (hD : lin[iD]? = some D) (hDa : X.act D = .defer c.id c.byId)
    (hDt : (X.replay lin iD).s.now = c.time)
    (ha : lin[ia]? = some a) (haa : X.act a = .pinRegister u ∨ X.act a = .pinOuter u)
    (hF : X.G.hb T F) :
    X.G.hb D a ∨ ∀ x, X.InRegion u a x → X.G.hb x F := by
  rcases pin_contract hlin hv hT hTl hc hD hDa hDt ha haa with h | h
  · exact .inl h
  · exact .inr fun x hx => hb_trans (h x hx) hF

/-- `defer_by_id` flags: `mark_ready`'s `Release` store `M` (`po`-after the critical section
`T` that took the flag, or `T` itself) read by the client's `Acquire` load `A`. -/
theorem pin_contract_flag {lin : List E} (hlin : IsLin X.G.hb lin) (hv : X.Valid lin)
    {T D a M A : E} {u : Tid} {c : Cb} {iT iD ia : Nat}
    (hT : lin[iT]? = some T) (hTl : (X.act T).locked = true)
    (hc : c ∈ (X.replay lin (iT + 1)).s.ran)
    (hD : lin[iD]? = some D) (hDa : X.act D = .defer c.id c.byId)
    (hDt : (X.replay lin iD).s.now = c.time)
    (ha : lin[ia]? = some a) (haa : X.act a = .pinRegister u ∨ X.act a = .pinOuter u)
    (hM : T = M ∨ X.G.po T M) (hrf : X.G.rf M A) (hMr : X.G.isRel M) (hAa : X.G.isAcq A)
    (hMat : X.G.atomic M) (hAat : X.G.atomic A) :
    X.G.hb D a ∨ ∀ x, X.InRegion u a x → X.G.hb x A :=
  pin_contract_run hlin hv hT hTl (.inl hc) hD hDa hDt ha haa
    (mp_hb X.cons hM hrf hMr hAa hMat hAat (.inl rfl))

/-- Linearisations exist; under the lin-independent program assumption, a valid one. -/
theorem exists_valid_lin (hprog : ∀ lin, IsLin X.G.hb lin → X.Valid lin) :
    ∃ lin, IsLin X.G.hb lin ∧ X.Valid lin := by
  obtain ⟨lin, hl⟩ := exists_hb_lin X.cons X.evs X.all
  exact ⟨lin, hl, hprog lin hl⟩

end CExec
end Collect.RC11Pin
