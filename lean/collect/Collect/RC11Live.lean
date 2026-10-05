import Collect.EFair
import Collect.RC11

/-!
# Fair liveness under weak memory (stale `EVENTS` loads)

`EFair.lean` proves fair liveness (property 10) for the primary model `Ev.EStep`, in which every
load of `EVENTS` returns the current value. Under RC11 the three loads of `EVENTS` outside the
`COLLECTOR` lock may return an older value:

* `collect`'s `Acquire` check `EVENTS.load(Acquire) != seen_events`;
* `collect_cold`'s `seen_events = EVENTS.load(Relaxed)` (before the lock);
* `pin_cold`'s forced `seen_events = EVENTS.load(Relaxed).wrapping_sub(1)` (after the lock).

## Which value a stale load returns

Every write to `EVENTS` is a `fetch_add(1, Release)` inside a `COLLECTOR` critical section
(`defer*`, `complete_epoch`). Critical sections are totally ordered by the lock order, which is
contained in `hb` (`RC11.lock_mo_hb`), so the modification order of `EVENTS` is the lock order of
these bumps, and each `fetch_add` reads its `mo`-predecessor (atomicity). Numbering the writes
`w₀` (the initialisation, value `0`), `w₁`, `w₂`, ... in `mo` order, `wₖ` writes `k % W`, and
`total` (the ghost bump count of `Ev.ESt`) is the index of the `mo`-latest write so far. A load
outside the lock reads some write `wₖ`, `k ≤ total`, and returns `k % W`. RC11 coherence
(read-read coherence, `corr` below) gives `k ≥` the index of the thread's previous `EVENTS`
read; the model keeps that bound as a per-thread view `vw` and drops all other lower bounds
(those from `hb`, e.g. the thread's own critical sections), which only adds behaviours. The
load inside the lock (`quiet`'s store before recursing) reads the latest write, since every
write is `hb`-ordered with the critical section; it stays exact (`EStep.collectReg`).
`Collect/RC11LiveGraph.lean` derives this rule from RC11-consistent execution graphs: the replay
of an execution is an `LExec` run whose load steps read the write given by `rf`, and `EvVis` on
the graph gives `EvVis` on the run.

The ghost `gseen t` of `Ev.ESt` is then the index of the write whose value `seen_events` holds
(`k` after `collect_cold`'s store, `k - 1` after `pin_cold`'s forced store), and `seen t =
gseen t % W` (`Ev.SeenInv`) still holds.

## The model

`LSt` is `Ev.ESt` plus the views `vw`. `LStep` has a label per step (`Lbl`): `call t k`
(collect's check reads `wₖ`), `store t k` (`collect_cold`'s store), `force t k` (`pin_cold`'s
forced store), each with `vw t ≤ k ≤ total`, and `other` for every other `Ev.EStep` (the locked
steps and thread-local steps, `NoLoad` excludes the exact load steps `collectCheck`,
`collectStore`, `pinForce`) or a stutter. `LReach`: reachable states. Every `Ev.EStep` run is an
`LStep` run (`estep_lstep`, `ereach_lreach`, loads reading the latest write).

## The visibility axiom and fairness

RC11 alone has no progress guarantee: a load may read `w₀` forever. We assume the standard
eventual-visibility property (C++ [intro.progress] p18 / [atomics.order] p11: "implementations
should make atomic stores visible to atomic loads within a reasonable amount of time"):
`EvVis`: for every write `wⱼ` that exists at some point, only finitely many loads read a write
`mo`-before it (index `< j`). Fairness is that of `EFair` (`LFairFrom`, `LFairAll`) with
`collect` calls labelled by the write they read, and no-wrap-around is stated on the value read
(`NoWrapL`: `k - gseen t < W` at a call reading `wₖ`).

## Results

* `lfair_stable`: stable registration, `LFairFrom`, `EvVis`, `NoWrapL`: every queued closure
  runs (the analogue of `EFair.efair_stable`).
* `lfair`: threads may release and re-register, `LFairAll`, `EvVis`, `NoWrapL` (the analogue of
  `EFair.efair`).
* `lfair_needs_vis`: `EvVis` cannot be dropped: a thread that keeps reading `w₀` takes the fast
  path forever, with every other hypothesis of `lfair_stable` satisfied.
* `lreclaim_possible`: weak liveness (8b): from every `LReach` state (also states reached only
  through stale loads), some `LStep` schedule runs the closure: the schedule of
  `Ev.eventually_ran_drainable`, every load reading the latest write.
* `corr`: RC11 read-read coherence, which justifies the view `vw`.

Proof idea: the invariants `Ev.SeenInv`, `EFair.NewsInv`, `EFair.PendInv` hold on `LReach`
(stale loads only lower `gseen`, and the forced store still sets `gseen = k - 1 < total`). For
a `Busy` thread `w` whose calls take the fast path forever, `gseen w` is frozen at a value
`g < total` (`NewsInv`) once it calls; by `EvVis` its later calls read `wₖ` with `k > g`, so
(no wrap) one of them sees news: `Fair.BusyFair`. For `CollectFair` (unstable registration),
while `c` is stuck no thread can reach the lock, so every thread outside a split has
`gseen < total(m)` (`PendInv` at the start) or `gseen < vw` (it did a forced store since), and
a call reading a visible write sees news.
-/

namespace Collect
namespace RC11Live

open Ev Fair EFair

variable (W : Nat)

/-! ## The model with stale loads -/

/-- `Ev.ESt` plus each thread's view of `EVENTS`: the index of the last write it read. -/
structure LSt where
  e : ESt
  vw : Tid → Nat

/-- Step labels: the three loads outside the lock, with the index `k` of the write read. -/
inductive Lbl where
  | call (t : Tid) (k : Nat)
  | store (t : Tid) (k : Nat)
  | force (t : Tid) (k : Nat)
  | other

/-- Not one of the exact load steps (`collectCheck`, `collectStore`, `pinForce`). -/
def NoLoad (e e' : ESt) : Prop := ∀ t, e'.chk t = e.chk t ∧ (e.fpend t = true → e'.fpend t = true)

/-- `collect`'s check reading `wₖ` (value `k % W`): fast path (no change) or `collect_cold`. -/
def lcheck (e : ESt) (t : Tid) (k : Nat) : ESt :=
  if ((k : Int) % W) = e.seen t then e else { e with chk := upd e.chk t true }

/-- Steps of the weak model. -/
def LStep : Lbl → LSt → LSt → Prop
  | .call t k, s, s' =>
    ((s.e.base.loc t = .registered ∨ s.e.base.loc t = .unregistered) ∧ s.e.mid t = false ∧
      s.e.chk t = false) ∧ s.vw t ≤ k ∧ k ≤ s.e.total ∧ s' = ⟨lcheck W s.e t k, upd s.vw t k⟩
  | .store t k, s, s' =>
    s.e.chk t = true ∧ s.vw t ≤ k ∧ k ≤ s.e.total ∧
      s' = ⟨{ setSeen s.e t ((k : Int) % W) k with
                mid := upd s.e.mid t true, chk := upd s.e.chk t false }, upd s.vw t k⟩
  | .force t k, s, s' =>
    s.e.fpend t = true ∧ s.vw t ≤ k ∧ k ≤ s.e.total ∧
      s' = ⟨{ setSeen s.e t (((k : Int) % W - 1) % W) ((k : Int) - 1) with
                fpend := upd s.e.fpend t false }, upd s.vw t k⟩
  | .other, s, s' => ((EStep W s.e s'.e ∧ NoLoad s.e s'.e) ∨ s'.e = s.e) ∧ s'.vw = s.vw

def linit : LSt := ⟨einit, fun _ => 0⟩

inductive LReach : LSt → Prop
  | init : LReach linit
  | step {s s'} (l : Lbl) : LReach s → LStep W l s s' → LReach s'

theorem lcheck_eq (e : ESt) (t : Tid) (k : Nat) : ∃ ch, lcheck W e t k = { e with chk := ch } := by
  unfold lcheck; split
  · exact ⟨e.chk, rfl⟩
  · exact ⟨_, rfl⟩

/-! ## Invariants -/

/-- The invariants of `Events`/`EFair` used by the liveness proofs. -/
structure LInv (s : LSt) : Prop where
  reach : Reachable s.e.base
  seen : SeenInv W s.e
  news : NewsInv s.e
  pend : PendInv s.e

theorem linv_init : LInv W linit :=
  ⟨.init, seenInv_init W, newsInv_init, pendInv_init⟩

/-- The base projection of a step is a base step or a stutter. -/
theorem lstep_base {l : Lbl} {s s' : LSt} (hs : LStep W l s s') :
    s'.e.base = s.e.base ∨ Step s.e.base s'.e.base := by
  cases l with
  | call t k =>
    obtain ⟨-, -, -, rfl⟩ := hs; obtain ⟨ch, h⟩ := lcheck_eq W s.e t k; left; simp [h]
  | store t k => obtain ⟨-, -, -, rfl⟩ := hs; exact .inl rfl
  | force t k => obtain ⟨-, -, -, rfl⟩ := hs; exact .inl rfl
  | other =>
    obtain ⟨⟨h, -⟩ | h, -⟩ := hs
    · exact estep_base W h
    · exact .inl (by rw [h])

theorem linv_step {l : Lbl} {s s' : LSt} (h : LInv W s) (hs : LStep W l s s') : LInv W s' := by
  have hreach : Reachable s'.e.base := by
    rcases lstep_base W hs with e | e
    · rw [e]; exact h.reach
    · exact .step h.reach e
  obtain ⟨hr, hsi, hn, hp⟩ := h
  cases l with
  | call t k =>
    obtain ⟨-, -, -, rfl⟩ := hs
    obtain ⟨ch, he⟩ := lcheck_eq W s.e t k
    refine ⟨hreach, ?_, ?_, ?_⟩ <;> simp only [he]
    · exact hsi
    · exact ⟨hn.fp, hn.lo, hn.news⟩
    · exact hp
  | store t k =>
    obtain ⟨hc, -, hk, rfl⟩ := hs
    refine ⟨hreach, seenInv_setSeen W hsi t k (by omega), ⟨fun u hu => ?_, fun u => ?_, fun u a b d f => ?_⟩, ?_⟩
    · simpa [setSeen] using hn.fp u (by simpa [setSeen] using hu)
    · by_cases hu' : u = t
      · subst hu'; simp [setSeen]
      · simpa [setSeen, hu'] using hn.lo u
    · by_cases hu' : u = t
      · subst hu'; simp at d
      · simp only [setSeen, upd_other _ _ _ _ hu'] at a b d f ⊢
        exact hn.news u a b d f
    · intro hst u a f
      by_cases hu : u = t
      · subst hu; simp at a
      · simp only [setSeen, upd_other _ _ _ _ hu] at a f ⊢; exact hp hst u a f
  | force t k =>
    obtain ⟨hf, -, hk, rfl⟩ := hs
    refine ⟨hreach, fun u => ?_, ⟨fun u hu => ?_, fun u => ?_, fun u a b d f => ?_⟩, ?_⟩
    · have := hsi u; by_cases hu : u = t
      · subst hu; simp only [setSeen, upd_same]; exact ⟨wsub_emod W _, by omega⟩
      · simp [setSeen, hu, this]
    · by_cases hu' : u = t
      · subst hu'; simp at hu
      · simpa [setSeen, hu'] using hn.fp u (by simpa [setSeen, hu'] using hu)
    · by_cases hu' : u = t
      · subst hu'; simp [setSeen]; omega
      · simpa [setSeen, hu'] using hn.lo u
    · by_cases hu' : u = t
      · subst hu'; simp [setSeen]; omega
      · simp only [setSeen, upd_other _ _ _ _ hu'] at a b d f ⊢
        exact hn.news u a b d f
    · intro hst u a f
      by_cases hu : u = t
      · subst hu; simp [setSeen]; omega
      · simp only [setSeen, upd_other _ _ _ _ hu] at a f ⊢; exact hp hst u a f
  | other =>
    obtain ⟨⟨he, -⟩ | he, -⟩ := hs
    · exact ⟨hreach, seenInv_step W hsi he, newsInv_step' W hsi hr hn he, pendInv_step' W hsi hr hp he⟩
    · exact ⟨hreach, by rw [he]; exact hsi, by rw [he]; exact hn, by rw [he]; exact hp⟩

theorem lreach_inv {s : LSt} (h : LReach W s) : LInv W s := by
  induction h with
  | init => exact linv_init W
  | step l _ hs ih => exact linv_step W ih hs

/-! ## Frame lemmas for `other` steps -/

/-- A non-load `EStep` leaves the `seen_events` data and split flags of a thread outside
`mid` alone, except that `register` (from `Unregistered`) may set `fpend`. -/
theorem other_frame {e e' : ESt} (hs : EStep W e e') (hn : NoLoad e e') (t : Tid)
    (hm : e.mid t = false) :
    e'.gseen t = e.gseen t ∧ e'.seen t = e.seen t ∧ e'.mid t = false ∧ e'.chk t = e.chk t ∧
      (e'.fpend t = e.fpend t ∨ e.base.loc t = .unregistered) := by
  cases hs with
  | pinRegister t0 hl _ _ =>
    refine ⟨rfl, rfl, hm, rfl, ?_⟩
    by_cases h : t = t0
    · subst h; exact .inr hl
    · exact .inl (by simp [h])
  | pinForce t0 hf => have := (hn t0).2 hf; simp at this
  | collectCheck t0 _ _ hc _ => have := (hn t0).1; simp [hc] at this
  | collectStore t0 hc => have := (hn t0).1; simp [hc] at this
  | collectReg t0 _ hm0 =>
    have h : t ≠ t0 := fun h => by subst h; rw [hm] at hm0; cases hm0
    dsimp only; split
    · simp [setSeen, h, hm]
    · simp [h, hm]
  | collectUnreg t0 _ hm0 =>
    have h : t ≠ t0 := fun h => by subst h; rw [hm] at hm0; cases hm0
    simp [h, hm]
  | _ => exact ⟨rfl, rfl, hm, rfl, .inl rfl⟩

/-- A thread in `mid` stays in `mid` until it takes the lock (`collect_cold`'s locked part). -/
theorem other_mid {e e' : ESt} (hs : EStep W e e') (t : Tid) (hm : e.mid t = true) :
    e'.mid t = true ∨ (e.base.loc t = .registered ∧ e'.base = startCollect t true (quiet t 2 e.base)) ∨
      (e.base.loc t = .unregistered ∧ e'.base = startCollect t false (collectUnreg e.base)) := by
  cases hs with
  | collectStore t0 _ =>
    left; by_cases h : t = t0
    · subst h; simp
    · simp [h, hm]
  | collectReg t0 hl _ =>
    by_cases h : t = t0
    · subst h; right; left; refine ⟨hl, ?_⟩
      dsimp only; split <;> simp [setSeen, quietRust_eq]
    · left; dsimp only; split <;> simp [setSeen, h, hm]
  | collectUnreg t0 hl _ =>
    by_cases h : t = t0
    · subst h; right; right; exact ⟨hl, rfl⟩
    · left; simp [h, hm]
  | pinForce t0 _ => left; simpa [setSeen] using hm
  | _ => exact .inl hm

/-! ## Executions, visibility and fairness -/

/-- An infinite labelled execution of the weak model. -/
def LExec (ex : Nat → LSt) (lab : Nat → Lbl) : Prop := ∀ n, LStep W (lab n) (ex n) (ex (n + 1))

/-- The base-model projection. -/
def proj (ex : Nat → LSt) : Nat → St := fun n => (ex n).e.base

/-- Step `m` is a load of `EVENTS` (outside the lock) by `t` reading `wₖ`. -/
def LoadAt (lab : Nat → Lbl) (m : Nat) (t : Tid) (k : Nat) : Prop :=
  lab m = .call t k ∨ lab m = .store t k ∨ lab m = .force t k

/-- **Eventual visibility** (the weak-memory progress axiom): for every write `wⱼ` to `EVENTS`
that is ever performed, only finitely many loads read a write `mo`-before it. -/
def EvVis (ex : Nat → LSt) (lab : Nat → Lbl) : Prop :=
  ∀ j : Nat, (∃ n, j ≤ (ex n).e.total) → ∃ N, ∀ m t k, N ≤ m → LoadAt lab m t k → j ≤ k

/-- No wrap-around at a `collect` check: the write read is fewer than `W` writes after the one
`seen_events` holds. -/
def NoWrapL (ex : Nat → LSt) (lab : Nat → Lbl) : Prop :=
  ∀ m t k, lab m = .call t k → (k : Int) - (ex m).e.gseen t < W

/-- Fairness with stable registration from `N0` (as `EFair.EFairFrom`):
* every thread registered at `N0` calls `collect` infinitely often (fast path allowed);
* a thread whose check entered `collect_cold` (`chk`) completes its locked part;
* every to-do list is eventually run. -/
def LFairFrom (ex : Nat → LSt) (lab : Nat → Lbl) (N0 : Nat) : Prop :=
  (∀ t, ((ex N0).e.base.threads t).isSome → ∀ n, ∃ m k, n ≤ m ∧ lab m = .call t k) ∧
  (∀ n t, (ex n).e.chk t = true →
    ∃ m, n ≤ m ∧ (CollectsAt (proj ex) t m ∨ CollectsUnregAt (proj ex) t m)) ∧
  (∀ n t w l, (ex n).e.base.loc t = .collecting w l → ∀ x ∈ l, ∃ m, x ∈ (ex m).e.base.ran)

/-- Fairness with threads free to release and re-register (as `EFair.EFairAll`). -/
def LFairAll (ex : Nat → LSt) (lab : Nat → Lbl) : Prop :=
  (∀ t n, (ex n).e.base.threads t ≠ none →
    ∃ m, n ≤ m ∧ ((∃ k, lab m = .call t k) ∨ (ex m).e.base.threads t = none)) ∧
  (∀ n, ∃ m t k, n ≤ m ∧ lab m = .call t k) ∧
  (∀ n t, (ex n).e.chk t = true →
    ∃ m, n ≤ m ∧ (CollectsAt (proj ex) t m ∨ CollectsUnregAt (proj ex) t m)) ∧
  (∀ n t w l, (ex n).e.base.loc t = .collecting w l → ∀ x ∈ l, ∃ m, x ∈ (ex m).e.base.ran)

theorem LExec.reach {ex : Nat → LSt} {lab : Nat → Lbl} (hex : LExec W ex lab)
    (hr : LReach W (ex 0)) : ∀ n, LReach W (ex n)
  | 0 => hr
  | n + 1 => .step (lab n) (LExec.reach hex hr n) (hex n)

theorem LExec.exec {ex : Nat → LSt} {lab : Nat → Lbl} (hex : LExec W ex lab) : Exec (proj ex) :=
  fun n => (lstep_base W (hex n)).symm.imp_right id |>.elim .inl (fun h => .inr h)

/-- A check reading a write strictly after `seen_events`' write, without wrap-around, sees
news. -/
theorem check_news {e : ESt} (hsi : SeenInv W e) (t : Tid) (k : Nat) (hlt : e.gseen t < k)
    (hnw : (k : Int) - e.gseen t < W) : (lcheck W e t k).chk t = true := by
  unfold lcheck
  have : ¬ ((k : Int) % W = e.seen t) := by
    rw [(hsi t).1, eq_comm, emod_eq_iff_sub W]
    have := Int.emod_eq_of_lt (a := (k : Int) - e.gseen t) (b := W) (by omega) hnw
    omega
  simp [this]

/-! ## Stable registration -/

/-- Core of the `Busy` argument: a `Busy` thread that calls `collect` infinitely often, never
completes a slow-path `collect` and stays `Busy`, while a callback stays queued, contradicts
eventual visibility. -/
theorem busy_core {ex : Nat → LSt} {lab : Nat → Lbl} (hex : LExec W ex lab) (hr : LReach W (ex 0))
    (hchkf : ∀ n t, (ex n).e.chk t = true →
      ∃ m, n ≤ m ∧ (CollectsAt (proj ex) t m ∨ CollectsUnregAt (proj ex) t m))
    (hv : EvVis ex lab) (hnw : NoWrapL W ex lab) (w : Tid) (m : Nat)
    (hq : ∀ j, m ≤ j → bufs (ex j).e.base ≠ [])
    (H : ∀ i, m ≤ i → ¬ CollectsAt (proj ex) w i ∧ (ex i).e.base.threads w = some .busy)
    (hcalls : ∀ n, ∃ m2 k, n ≤ m2 ∧ lab m2 = .call w k) : False := by
  have inv := fun i => lreach_inv W (LExec.reach W hex hr i)
  have chk_false : ∀ i, m ≤ i → (ex i).e.chk w = false := by
    intro i hi
    cases hc : (ex i).e.chk w
    · rfl
    · exfalso
      obtain ⟨m', hm', hcol | ⟨hu, -⟩⟩ := hchkf i w hc
      · exact (H m' (by omega)).1 hcol
      · have := (threads_consistent (inv m').reach w).1 hu
        rw [(H m' (by omega)).2] at this; cases this
  obtain ⟨m1, k1, hm1, hl1⟩ := hcalls m
  have hs1 := hex m1; rw [hl1] at hs1
  obtain ⟨⟨hloc, hmid, -⟩, -, -, -⟩ := hs1
  have hfp := fp_notReg (inv m1).news (hloc.elim .inl (fun h => .inr (.inl h)))
  have hg := (inv m1).news.news w (H m1 hm1).2 hfp hmid (hq m1 hm1)
  have hlo := (inv m1).news.lo w
  -- `w`'s `mid`, `fpend` and `gseen` are frozen from `m1` on
  have Q : ∀ i, m1 ≤ i → (ex i).e.mid w = false ∧ (ex i).e.fpend w = false ∧
      (ex i).e.gseen w = (ex m1).e.gseen w := by
    refine ge_induction ⟨hmid, hfp, rfl⟩ fun i hi ⟨a, b, d⟩ => ?_
    have hci := chk_false i (by omega)
    have hs := hex i
    cases hli : lab i with
    | call t k =>
      rw [hli] at hs; obtain ⟨-, -, -, he⟩ := hs
      obtain ⟨ch, hh⟩ := lcheck_eq W (ex i).e t k
      rw [he]; simp only [hh]; exact ⟨a, b, d⟩
    | store t k =>
      rw [hli] at hs; obtain ⟨hc, -, -, he⟩ := hs
      have ht : w ≠ t := fun h => by subst h; rw [hci] at hc; cases hc
      rw [he]; simp [setSeen, ht, a, b, d]
    | force t k =>
      rw [hli] at hs; obtain ⟨hf, -, -, he⟩ := hs
      have ht : w ≠ t := fun h => by subst h; rw [b] at hf; cases hf
      rw [he]; simp [setSeen, ht, a, b, d]
    | other =>
      rw [hli] at hs; obtain ⟨⟨he, hnl⟩ | he, -⟩ := hs
      · obtain ⟨g1, -, m', -, f⟩ := other_frame W he hnl w a
        refine ⟨m', ?_, by rw [g1, d]⟩
        rcases f with f | f
        · rw [f, b]
        · have := (threads_consistent (inv i).reach w).1 f
          rw [(H i (by omega)).2] at this; cases this
      · rw [he]; exact ⟨a, b, d⟩
  obtain ⟨N, hN⟩ := hv (((ex m1).e.gseen w) + 1).toNat ⟨m1, by omega⟩
  obtain ⟨m2, k2, hm2, hl2⟩ := hcalls (max m1 N)
  have hk2 := hN m2 w k2 (by omega) (.inl hl2)
  have hs2 := hex m2; rw [hl2] at hs2
  obtain ⟨-, -, -, he2⟩ := hs2
  obtain ⟨-, -, hg2⟩ := Q m2 (by omega)
  have hc := check_news W (inv m2).seen w k2 (by omega) (hnw m2 w k2 hl2)
  have := chk_false (m2 + 1) (by omega)
  rw [he2] at this; rw [hc] at this; cases this

/-- Fairness on calls plus eventual visibility gives `Fair.BusyFair`. -/
theorem lbusyFair {ex : Nat → LSt} {lab : Nat → Lbl} (hex : LExec W ex lab) (hr : LReach W (ex 0))
    {N0 : Nat} (hst : StableFrom (proj ex) N0) (hf : LFairFrom ex lab N0)
    (hv : EvVis ex lab) (hnw : NoWrapL W ex lab) (c : Cb) : BusyFair (proj ex) N0 c := by
  intro w m hm hw hq
  apply Classical.byContradiction; intro hno
  have H : ∀ i, m ≤ i → ¬ CollectsAt (proj ex) w i ∧ (ex i).e.base.threads w = some .busy :=
    fun i hi => ⟨fun h => hno ⟨i, hi, .inl h⟩,
      Classical.byContradiction fun h => hno ⟨i, hi, .inr h⟩⟩
  have hwN : ((ex N0).e.base.threads w).isSome := by
    rw [show (ex N0).e.base = proj ex N0 from rfl, ← stable_at hst m hm w]; simp [proj] at hw ⊢; simp [hw]
  exact busy_core W hex hr hf.2.1 hv hnw w m (fun j hj e => by
      have := hq j hj; simp only [proj] at this; rw [e] at this; cases this) H
    (fun n => hf.1 w hwN n)

/-- **Fair liveness under weak memory, stable registration.** In an infinite execution of the
weak model (stale `EVENTS` loads, `LStep`) from a reachable state, with registration stable from
`N0` (at least one thread registered), fair `collect` calls (`LFairFrom`), eventual visibility
of `EVENTS` writes (`EvVis`) and no wrap-around at a check (`NoWrapL`), a closure
(`byId = false`) queued after `N0` eventually runs. -/
theorem lfair_stable (ex : Nat → LSt) (lab : Nat → Lbl) (hex : LExec W ex lab)
    (hr : LReach W (ex 0)) (N0 : Nat) (hst : StableFrom (proj ex) N0)
    (hne : ∃ t, ((ex N0).e.base.threads t).isSome) (hf : LFairFrom ex lab N0)
    (hv : EvVis ex lab) (hnw : NoWrapL W ex lab)
    (c : Cb) (hid : c.byId = false) (n0 : Nat) (hn0 : N0 ≤ n0) (hc : c ∈ bufs (ex n0).e.base) :
    ∃ m, c ∈ (ex m).e.base.ran :=
  fair_stable_busy (proj ex) (LExec.exec W hex) (lreach_inv W hr).reach N0 hst hne c
    (lbusyFair W hex hr hst hf hv hnw c) hf.2.2 hid n0 hn0 hc

/-! ## Unstable registration -/

theorem lbusyFairAll {ex : Nat → LSt} {lab : Nat → Lbl} (hex : LExec W ex lab)
    (hr : LReach W (ex 0)) (hf : LFairAll ex lab) (hv : EvVis ex lab) (hnw : NoWrapL W ex lab)
    (c : Cb) : BusyFairAll (proj ex) c := by
  intro w m hw hq
  apply Classical.byContradiction; intro hno
  have H : ∀ i, m ≤ i → ¬ CollectsAt (proj ex) w i ∧ (ex i).e.base.threads w = some .busy :=
    fun i hi => ⟨fun h => hno ⟨i, hi, .inl h⟩,
      Classical.byContradiction fun h => hno ⟨i, hi, .inr h⟩⟩
  refine busy_core W hex hr hf.2.2.1 hv hnw w m (fun j hj e => by
      have := hq j hj; simp only [proj] at this; rw [e] at this; cases this) H fun n => ?_
  obtain ⟨m2, hm2, ⟨k, hk⟩ | hn⟩ := hf.1 w (max m n) (by rw [(H _ (by omega)).2]; simp)
  · exact ⟨m2, k, by omega, hk⟩
  · rw [(H m2 (by omega)).2] at hn; cases hn

/-- A thread is in a split, behind `T` (`total` at the start), or behind its own view. -/
def GoodAt (T : Int) (s : LSt) (t : Tid) : Prop :=
  s.e.mid t = true ∨ s.e.fpend t = true ∨ s.e.gseen t < T ∨ s.e.gseen t < s.vw t

theorem lcollectFair {ex : Nat → LSt} {lab : Nat → Lbl} (hex : LExec W ex lab)
    (hr : LReach W (ex 0)) (hf : LFairAll ex lab) (hv : EvVis ex lab) (hnw : NoWrapL W ex lab)
    (c : Cb) : CollectFair (proj ex) c := by
  intro m hq
  apply Classical.byContradiction; intro hno
  have H : ∀ i, m ≤ i → ¬ CollAt (proj ex) i := fun i hi h => hno ⟨i, hi, h⟩
  have inv := fun i => lreach_inv W (LExec.reach W hex hr i)
  have chk_false : ∀ i, m ≤ i → ∀ t, (ex i).e.chk t = false := by
    intro i hi t
    cases hc : (ex i).e.chk t
    · rfl
    · exfalso
      obtain ⟨m', hm', h⟩ := hf.2.2.1 i t hc
      exact H m' (by omega) ⟨t, h⟩
  have hstk : Stuck (ex m).e.base := by
    obtain ⟨hb, hp | ha⟩ := hq m (Nat.le_refl _)
    · exact .inl fun e => by simp [proj, e] at hp
    · exact .inr ⟨ha, fun e => by simp [proj, e] at hb⟩
  -- every thread is in a split, behind `total` at `m`, or behind its own view
  obtain ⟨T, hT⟩ : ∃ T : Int, T = (ex m).e.total := ⟨_, rfl⟩
  have G : ∀ i, m ≤ i → ∀ t, GoodAt T (ex i) t := by
    refine ge_induction (fun t => ?_) fun i hi ih t => ?_
    · cases hm : (ex m).e.mid t
      · cases hfp : (ex m).e.fpend t
        · exact .inr (.inr (.inl (hT ▸ (inv m).pend hstk t hm hfp)))
        · exact .inr (.inl hfp)
      · exact .inl hm
    · have hs := hex i
      cases hli : lab i with
      | call t0 k =>
        rw [hli] at hs; obtain ⟨-, hvk, -, he⟩ := hs
        obtain ⟨ch, hh⟩ := lcheck_eq W (ex i).e t0 k
        have hv' : (ex i).vw t ≤ (ex (i + 1)).vw t := by
          rw [he]; by_cases h : t = t0
          · subst h; simpa using hvk
          · simp [h]
        rcases ih t with a | a | a | a
        · exact .inl (by rw [he]; simpa [hh] using a)
        · exact .inr (.inl (by rw [he]; simpa [hh] using a))
        · exact .inr (.inr (.inl (by rw [he]; simpa [hh] using a)))
        · refine .inr (.inr (.inr ?_))
          have : (ex (i + 1)).e.gseen t = (ex i).e.gseen t := by rw [he]; simp [hh]
          omega
      | store t0 k =>
        rw [hli] at hs; obtain ⟨hc, -, -, -⟩ := hs
        rw [chk_false i hi t0] at hc; cases hc
      | force t0 k =>
        rw [hli] at hs; obtain ⟨-, -, -, he⟩ := hs
        by_cases h : t = t0
        · subst h; refine .inr (.inr (.inr ?_)); rw [he]; simp [setSeen]; try omega
        · have := ih t
          rw [he]; unfold GoodAt at this ⊢; simpa [setSeen, h] using this
      | other =>
        rw [hli] at hs; obtain ⟨⟨he, hnl⟩ | he, hvw⟩ := hs
        · cases hm : (ex i).e.mid t
          · obtain ⟨g1, -, m', -, f⟩ := other_frame W he hnl t hm
            have hfp0 : (ex i).e.fpend t = (ex (i + 1)).e.fpend t ∨ (ex i).e.fpend t = false := by
              rcases f with f | f
              · exact .inl f.symm
              · exact .inr (fp_notReg (inv i).news (.inr (.inl f)))
            rcases ih t with a | a | a | a
            · rw [hm] at a; cases a
            · rcases hfp0 with f0 | f0
              · exact .inr (.inl (f0 ▸ a))
              · rw [f0] at a; cases a
            · exact .inr (.inr (.inl (by rw [g1]; exact a)))
            · exact .inr (.inr (.inr (by rw [g1, hvw]; exact a)))
          · rcases other_mid W he t hm with a | a | a
            · exact .inl a
            · exact (H i hi ⟨t, .inl a⟩).elim
            · exact (H i hi ⟨t, .inr a⟩).elim
        · have := ih t; unfold GoodAt at this ⊢; rw [he, hvw]; exact this
  obtain ⟨N, hN⟩ := hv T.toNat ⟨m, by omega⟩
  obtain ⟨m2, t, k, hm2, hl2⟩ := hf.2.1 (max m N)
  have hk := hN m2 t k (by omega) (.inl hl2)
  have hs2 := hex m2; rw [hl2] at hs2
  obtain ⟨⟨hloc, hmid, -⟩, hvk, -, he2⟩ := hs2
  have hfp := fp_notReg (inv m2).news (hloc.elim .inl (fun h => .inr (.inl h)))
  have hlt : (ex m2).e.gseen t < k := by
    rcases G m2 (by omega) t with a | a | a | a
    · rw [hmid] at a; cases a
    · rw [hfp] at a; cases a
    · omega
    · omega
  have hc := check_news W (inv m2).seen t k hlt (hnw m2 t k hl2)
  have := chk_false (m2 + 1) (by omega) t
  rw [he2] at this; rw [hc] at this; cases this

/-- **Fair liveness under weak memory, threads may release and re-register.** In an infinite
execution of the weak model from a reachable state, under `LFairAll`, eventual visibility
(`EvVis`) and no wrap-around at a check (`NoWrapL`), a closure (`byId = false`) queued at some
point eventually runs. -/
theorem lfair (ex : Nat → LSt) (lab : Nat → Lbl) (hex : LExec W ex lab) (hr : LReach W (ex 0))
    (hf : LFairAll ex lab) (hv : EvVis ex lab) (hnw : NoWrapL W ex lab)
    (c : Cb) (hid : c.byId = false) (n0 : Nat) (hc : c ∈ bufs (ex n0).e.base) :
    ∃ m, c ∈ (ex m).e.base.ran :=
  fair (proj ex) (LExec.exec W hex) (lreach_inv W hr).reach c hid
    (lbusyFairAll W hex hr hf hv hnw c) (lcollectFair W hex hr hf hv hnw c) hf.2.2.2 n0 hc

/-! ## Eventual visibility is needed -/

theorem noLoad_of {e e' : ESt} (hc : e'.chk = e.chk) (hf : e'.fpend = e.fpend) : NoLoad e e' :=
  fun t => ⟨by rw [hc], fun h => by rw [hf]; exact h⟩

theorem wstart_lreach : LReach W ⟨wstart, fun _ => 0⟩ := by
  have s1 := EStep.pinRegister (W := W) einit 0 rfl rfl rfl
  have h1 : LReach W ⟨_, fun _ => 0⟩ := .step .other .init
    ⟨.inl ⟨s1, fun t => ⟨rfl, fun h => (Bool.false_ne_true h).elim⟩⟩, rfl⟩
  have h2 : LReach W ⟨_, fun _ => 0⟩ := .step .other h1 ⟨.inl ⟨EStep.unpinOuter _ 0 0
    (by simp [register, einit, init]) (by simp [hasCbs, einit, init]), noLoad_of rfl rfl⟩, rfl⟩
  have h3 : LReach W ⟨_, fun _ => 0⟩ := .step .other h2
    ⟨.inl ⟨EStep.defer _ 0 false, noLoad_of rfl rfl⟩, rfl⟩
  refine (fun e (h : LReach W ⟨e, fun _ => 0⟩) (he : e = wstart) => he ▸ h) _ h3 ?_
  simp only [wstart, einit, init, hasCbs, register]
  have h1 : upd (upd (fun _ => LS.unregistered) 0 (LS.pinned 0 0)) 0 LS.registered =
      upd (fun _ => LS.unregistered) 0 LS.registered := by
    funext u; by_cases hu : u = 0 <;> simp [upd, hu]
  have h2 : upd (fun _ => false) 0 (!(([] : List Cb).isEmpty && ([] : List Cb).isEmpty &&
      ([] : List Cb).isEmpty)) = fun _ => false := by
    funext u; by_cases hu : u = 0 <;> simp [upd, hu]
  rw [h1, h2]; rfl

/-- **Without eventual visibility, liveness fails.** For every `W ≥ 1` there is an infinite
execution of the weak model from a reachable state where only thread 0 is registered (and
`Busy`), it calls `collect` at every step, every other hypothesis of `lfair_stable` holds, but
every call reads the initial write `w₀` although `w₁` exists, so it takes the fast path and the
queued closure never runs. -/
theorem lfair_needs_vis (hW : 0 < W) : ∃ (ex : Nat → LSt) (lab : Nat → Lbl) (c : Cb),
    LReach W (ex 0) ∧ LExec W ex lab ∧ StableFrom (proj ex) 0 ∧
    ((ex 0).e.base.threads 0).isSome ∧ LFairFrom ex lab 0 ∧ NoWrapL W ex lab ∧
    ¬ EvVis ex lab ∧ c.byId = false ∧ (∀ n, c ∈ bufs (ex n).e.base ∧ c ∉ (ex n).e.base.ran) := by
  have hcheck : lcheck W wstart 0 0 = wstart := by simp [lcheck, wstart]
  have hupd : upd (fun _ => (0 : Nat)) 0 0 = fun _ => 0 := by
    funext u; by_cases hu : u = 0 <;> simp [upd, hu]
  refine ⟨fun _ => ⟨wstart, fun _ => 0⟩, fun _ => .call 0 0, ⟨0, 1, false⟩, wstart_lreach W,
    fun n => ⟨⟨.inl (by simp [wstart]), rfl, rfl⟩, Nat.le_refl _, by simp [wstart],
      by rw [hcheck, hupd]⟩,
    fun _ _ _ => rfl, by simp [wstart],
    ⟨fun t ht n => ⟨n, 0, Nat.le_refl _, ?_⟩, fun n t h => by simp [wstart] at h,
      fun n t w l h => ?_⟩,
    fun m t k h => ?_, fun hv => ?_, rfl, fun n => ⟨by simp [bufs, wstart], by simp [wstart]⟩⟩
  · by_cases h0 : t = 0
    · subst h0; rfl
    · simp [wstart, upd, h0] at ht
  · by_cases ht : t = 0 <;> simp [wstart, upd, ht] at h
  · simp at h; obtain ⟨rfl, rfl⟩ := h; simp [wstart]; omega
  · obtain ⟨N, hN⟩ := hv 1 ⟨0, by simp [wstart]⟩
    have := hN N 0 0 (Nat.le_refl _) (.inl rfl); omega

/-! ## Every primary-model run is a weak-model run; weak liveness (8b) -/

theorem estep_total {e e' : ESt} (hs : EStep W e e') : e.total ≤ e'.total := by
  cases hs with
  | collectReg t _ _ => dsimp only; split <;> simp <;> omega
  | release => simp
  | defer => simp
  | _ => simp [setSeen]

/-- An `EStep` is an `LStep` (loads read the latest write), keeping views at most `total`. -/
theorem estep_lstep {e e' : ESt} (hs : EStep W e e') (hni : NewsInv e) (vw : Tid → Nat)
    (hvw : ∀ t, vw t ≤ e.total) :
    ∃ l vw', LStep W l ⟨e, vw⟩ ⟨e', vw'⟩ ∧ ∀ t, vw' t ≤ e'.total := by
  have ht := estep_total W hs
  have keep : NoLoad e e' → ∃ l vw', LStep W l ⟨e, vw⟩ ⟨e', vw'⟩ ∧ ∀ t, vw' t ≤ e'.total :=
    fun hn => ⟨.other, vw, ⟨.inl ⟨hs, hn⟩, rfl⟩, fun t => by have := hvw t; omega⟩
  have vupd : ∀ t, ∀ u, upd vw t e.total u ≤ e.total := fun t u => by
    by_cases h : u = t
    · subst h; simp
    · simp [h, hvw u]
  cases hs with
  | pinForce t hf =>
    exact ⟨.force t e.total, upd vw t e.total, ⟨hf, hvw t, Nat.le_refl _, rfl⟩, vupd t⟩
  | collectCheck t hl hm hc hne =>
    refine ⟨.call t e.total, upd vw t e.total, ⟨⟨hl, hm, hc⟩, hvw t, Nat.le_refl _, ?_⟩, vupd t⟩
    simp [lcheck, show ¬ ((e.total : Int) % W = e.seen t) from hne]
  | collectStore t hc =>
    exact ⟨.store t e.total, upd vw t e.total, ⟨hc, hvw t, Nat.le_refl _, rfl⟩, vupd t⟩
  | collectFast => exact ⟨.other, vw, ⟨.inr rfl, rfl⟩, hvw⟩
  | pinRegister t hl hm hc =>
    exact keep fun u => ⟨rfl, fun h => by
      by_cases hu : u = t
      · subst hu; rw [fp_notReg hni (.inr (.inl hl))] at h; cases h
      · simp [hu, h]⟩
  | collectReg t hl hm =>
    exact keep fun u => by constructor <;> (dsimp only; split <;> simp [setSeen])
  | _ => exact keep (noLoad_of rfl rfl)

/-- Reflexive-transitive closure of `LStep` (any labels). -/
inductive LSteps : LSt → LSt → Prop
  | refl (s) : LSteps s s
  | tail {s s' s''} (l : Lbl) : LSteps s s' → LStep W l s' s'' → LSteps s s''

/-- A run of the primary model, from a reachable state, is a run of the weak model. -/
theorem esteps_lsteps {e e' : ESt} (hs : ESteps W e e') (hr : EReach W e) (vw : Tid → Nat)
    (hvw : ∀ t, vw t ≤ e.total) :
    ∃ vw', LSteps W ⟨e, vw⟩ ⟨e', vw'⟩ ∧ ∀ t, vw' t ≤ e'.total := by
  induction hs with
  | refl => exact ⟨vw, .refl _, hvw⟩
  | tail h1 s ih =>
    obtain ⟨vw1, hl1, hb1⟩ := ih
    obtain ⟨l, vw2, hl2, hb2⟩ := estep_lstep W s (ereach_newsInv W (ereach_steps W hr h1)) vw1 hb1
    exact ⟨vw2, .tail l hl1 hl2, hb2⟩

theorem ereach_lreach {e : ESt} (h : EReach W e) :
    ∃ vw, LReach W ⟨e, vw⟩ ∧ ∀ t, vw t ≤ e.total := by
  induction h with
  | init => exact ⟨fun _ => 0, .init, fun _ => Nat.zero_le _⟩
  | @step e e' hr s ih =>
    obtain ⟨vw, hl, hb⟩ := ih
    obtain ⟨l, vw', hs, hb'⟩ := estep_lstep W s (ereach_newsInv W hr) vw hb
    exact ⟨vw', .step l hl hs, hb'⟩

/-! ### Weak liveness from every weak-model state

States reached through stale loads are not primary-model states (`gseen` may be behind, a
`chk` may have been set by a stale check), but the schedule of `Ev.eventually_ran_events` only
needs `Ev.Drainable` (`SplitInv` and a reachable base), which every `LReach` state has
(`lreach_drainable`), and its steps lift to `LStep`s reading the latest write (`estep_lstep`, using
`NewsInv` from `LInv` and `vw ≤ total`, `lreach_vw`). A stale `seen_events` in flight is
handled by that schedule itself: a thread with `chk`/`mid`/`fpend` finishes its split
(`Ev.eclean`, its locked part reads exactly), and the final check of thread 0 either sees news
or takes one escaping `defer` (`Ev.defer_escapes`). -/

theorem lstep_total {l : Lbl} {s s' : LSt} (hs : LStep W l s s') : s.e.total ≤ s'.e.total := by
  cases l with
  | call t k => obtain ⟨-, -, -, rfl⟩ := hs; obtain ⟨ch, h⟩ := lcheck_eq W s.e t k; simp [h]
  | store t k => obtain ⟨-, -, -, rfl⟩ := hs; simp [setSeen]
  | force t k => obtain ⟨-, -, -, rfl⟩ := hs; simp [setSeen]
  | other =>
    obtain ⟨⟨h, -⟩ | h, -⟩ := hs
    · exact estep_total W h
    · rw [h]; exact Nat.le_refl _

/-- Views are not ahead of `EVENTS`. -/
theorem lreach_vw {s : LSt} (h : LReach W s) : ∀ t, s.vw t ≤ s.e.total := by
  induction h with
  | init => intro t; simp [linit, einit]
  | @step s s' l _ hs ih =>
    intro t
    have ht := lstep_total W hs
    cases l with
    | call t0 k | store t0 k | force t0 k =>
      obtain ⟨-, -, hk, rfl⟩ := hs
      by_cases h : t = t0
      · subst h; simp only [upd_same]; dsimp only at ht ⊢; omega
      · simp only [upd_other _ _ _ _ h]; have := ih t; dsimp only at ht ⊢; omega
    | other => obtain ⟨-, hv⟩ := hs; rw [hv]; have := ih t; omega

theorem lstep_split {l : Lbl} {s s' : LSt} (h : SplitInv s.e) (hs : LStep W l s s') :
    SplitInv s'.e := by
  obtain ⟨hl, hx, hfin⟩ := h
  cases l with
  | call t k =>
    obtain ⟨⟨h0, hm, hc⟩, -, -, rfl⟩ := hs
    unfold lcheck; split
    · exact ⟨hl, hx, hfin⟩
    · refine ⟨fun u hu => ?_, fun u => ?_, fin_upd hfin t _ _ _ (by simp)
        (fun u hu => by simp [hu]) (by simp)⟩
      · by_cases e : u = t
        · subst e; exact h0
        · exact hl u (by simpa [e] using hu)
      · by_cases e : u = t
        · subst e; simp [hm]
        · simpa [e] using hx u
  | store t k =>
    obtain ⟨hc, -, -, rfl⟩ := hs
    refine ⟨fun u hu => ?_, fun u => ?_, fin_upd hfin t _ _ _ (by simp [setSeen])
      (fun u hu => by simp [setSeen, hu]) (fun u hu => by simp [setSeen, hu])⟩
    · by_cases e : u = t
      · subst e; simpa [setSeen] using hl u (.inl hc)
      · exact hl u (by simpa [setSeen, e] using hu)
    · by_cases e : u = t
      · subst e; simp [setSeen]
      · simpa [setSeen, e] using hx u
  | force t k =>
    obtain ⟨-, -, -, rfl⟩ := hs
    exact ⟨fun u hu => by simpa [setSeen] using hl u (by simpa [setSeen] using hu),
      fun u => by simpa [setSeen] using hx u,
      fin_upd hfin t _ _ _ (fun u hu => by simp [setSeen, hu]) (by simp [setSeen]) (by simp [setSeen])⟩
  | other =>
    obtain ⟨⟨he, -⟩ | he, -⟩ := hs
    · exact splitInv_step W ⟨hl, hx, hfin⟩ he
    · rw [he]; exact ⟨hl, hx, hfin⟩

theorem lreach_drainable {s : LSt} (h : LReach W s) : Drainable s.e := by
  refine ⟨?_, (lreach_inv W h).reach⟩
  induction h with
  | init => exact splitInv_init
  | step _ _ hs ih => exact lstep_split W ih hs

/-- A primary-model schedule from a weak-model state (with its invariants) is a weak-model
schedule, every load reading the latest write. -/
theorem esteps_lsteps_inv {e e' : ESt} (hs : ESteps W e e') (vw : Tid → Nat) (hi : LInv W ⟨e, vw⟩)
    (hvw : ∀ t, vw t ≤ e.total) :
    ∃ vw', LSteps W ⟨e, vw⟩ ⟨e', vw'⟩ := by
  suffices ∃ vw', LSteps W ⟨e, vw⟩ ⟨e', vw'⟩ ∧ LInv W ⟨e', vw'⟩ ∧ ∀ t, vw' t ≤ e'.total from
    this.imp fun _ h => h.1
  induction hs with
  | refl => exact ⟨vw, .refl _, hi, hvw⟩
  | tail _ s ih =>
    obtain ⟨vw1, hl1, hi1, hb1⟩ := ih
    obtain ⟨l, vw2, hl2, hb2⟩ := estep_lstep W s hi1.news vw1 hb1
    exact ⟨vw2, .tail l hl1 hl2, linv_step W hi1 hl2, hb2⟩

/-- **Weak liveness (8b) in the weak model, from every weak-model state.** From every state
reachable in the weak model (including states reached only through stale loads), some
schedule of the weak model runs a queued closure: the schedule of `Ev.eventually_ran_drainable`
(finish in-flight splits, drain every thread, thread 0 collects, with one escaping `defer` if
its check would miss), in which every load reads the latest write. -/
theorem lreclaim_possible {s : LSt} (h : LReach W s) (hW : 1 < W) (c : Cb)
    (hc : c ∈ bufs s.e.base) :
    ∃ s', LSteps W s s' ∧ c ∈ s'.e.base.ran := by
  obtain ⟨e', hs, hran⟩ := eventually_ran_drainable W (lreach_drainable W h) hW c hc
  obtain ⟨vw', hl⟩ := esteps_lsteps_inv W hs s.vw (lreach_inv W h) (lreach_vw W h)
  exact ⟨_, hl, hran⟩

/-! ## RC11: read-read coherence (justifies the views `vw`) -/

section
open RC11 RC11.Graph
variable {E L V : Type} {G : Graph E L V}

/-- **Read-read coherence.** If `r₁` is `po`-before `r₂` and they read `w₁` and `w₂`, then `w₂`
is not `mo`-before `w₁`. So a thread's successive loads of `EVENTS` read non-decreasing write
indices: the bound `vw t ≤ k` of `LStep`. -/
theorem corr (hc : G.Consistent) {r₁ r₂ w₁ w₂ : E} (hpo : G.po r₁ r₂) (h₁ : G.rf w₁ r₁)
    (h₂ : G.rf w₂ r₂) : ¬ G.mo w₂ w₁ := by
  intro hmo
  have hne : r₂ ≠ w₁ := by
    rintro rfl
    exact hc.nta r₁ (.trans (.base (Or.inl hpo)) (.base (Or.inr h₁)))
  have hfr : G.fr r₂ w₁ := ⟨⟨w₂, h₂, hmo⟩, hne⟩
  have heco : G.eco r₂ r₁ := .trans (.base (Or.inr (Or.inr hfr))) (.base (Or.inl h₁))
  exact (hc.coh r₁ r₂ (po_hb hpo)).2 heco

end

end RC11Live
end Collect
