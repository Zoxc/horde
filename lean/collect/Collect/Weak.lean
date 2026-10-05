import Collect.Safety
import Collect.Events

/-!
# Weak memory: the `Pin` contract in happens-before terms

`Safety.lean` interprets `Pin<'a>` in the sequentially consistent ghost time of the model: a
pinned region "starts" at the `pinOuter` step and "ends" at the `unpinOuter` step, and these are
ordered against other threads' `defer`s by the interleaving. In Rust neither `pin` nor the end
of a pinned region does any synchronisation: they only write the thread-local `DATA.state`. So in
a C11 execution there is no happens-before edge between a region's start or end and another
thread's `defer`, and the interleaving position of a `pinOuter`/`unpinOuter` step has no meaning.

The only synchronisation `collect.rs` relies on for safety is the `COLLECTOR` mutex: every
collector operation runs under it, so lock acquisitions are totally ordered (lock order `lo`),
and each unlock synchronises with the next lock. Happens-before thus contains `sb ∪ lo`.

This file proves the stronger property that only uses these edges. A thread's *own lock steps*
are the locked steps the model attributes to it: `pinRegister` (`register`), `collectReg`
(`quiet`), `release` (`unregister`) and `collectUnreg`. (`defer` is not attributed to a thread,
assumption 5 of `MAPPING.md`; ignoring a thread's `defer`s only makes the result weaker.)

`WSt` adds the ghost `pt u`: the value of `now` at `u`'s latest `pinRegister`/`collectReg`.
`now` is monotone along the trace and the trace orders locked steps by `lo`, so for a callback
`c` (deferred by a locked step `D`, `c.time` = `now` at `D`) and a lock step `L` of `u`,
`c.time < pt u` (with `L` the step that set `pt u`) holds iff `D` comes before `L` in `lo`.

**`weak_safety`**: if `c` has been run or marked ready, or is in some thread's to-do list, then
every *registered* thread `u` has `c.time < pt u`. No pin state is mentioned: a registered thread
blocks every callback deferred after its latest own lock step, whether or not it is pinned.

Happens-before reading (the C11 argument, in prose; see `MAPPING.md`, property 11). Let `R` be a
pinned region of `u` with first event `a` and last event `b`, and `c` taken at locked step `T`
(`quiet`/`collect_unregistered`, then run at `F` with `T sb F`, or stored by `mark_ready` inside
`T` with `Release`). Let `L` be the last own lock step of `u` sb-before `a` (`pinRegister`
itself when the region registers) and `L'` the first one sb-after `b` (none can occur inside
`R`: `collect`/`release` panic while pinned). Any C11 execution of the program yields a trace of
the model: lock steps in `lo` order, each thread's steps in `sb` order (thread-local steps can be
placed anywhere between the neighbouring lock steps of their thread). In that trace:
* `T` before `L` in `lo`: `D lo T lo L sb a`, so `D hb a`.
* `T` after `L'`: `b sb L' lo T sb F`, so every event of `R` happens before `F`.
* otherwise `u` is registered at `T` with `pt u` set by `L`, so `weak_safety` gives `D lo L`,
  hence `D hb a`.
With the client's unlink `w sb D`, `D hb a` gives `w hb` every read in `R`, so by coherence no
read in `R` returns the unlinked pointer; `R hb F` makes every access in `R` race-free with the
free. For `defer_by_id` flags, `F` is the client's `Acquire` load reading the `Release` store in
`T` (`mark_ready`), which synchronises with it. Nothing about `EVENTS` is used: its loads only
choose the fast path of `collect`, which affects liveness, not safety.
-/

namespace Collect.Weak
open Collect

/-- The base state plus `pt u`: `now` at thread `u`'s latest `pinRegister`/`collectReg`. -/
structure WSt where
  s : St
  pt : Tid → Nat

/-- One step: a base `Step`, with `pt t := now` at `t`'s own lock steps that keep or make it
registered (`register` in `pinRegister`, `quiet` in `collectReg`). -/
inductive WStep : WSt → WSt → Prop
  | pinRegister (s : St) (pt : Tid → Nat) (t : Tid) (hl : s.loc t = .unregistered) :
      WStep ⟨s, pt⟩ ⟨register s t, upd pt t s.now⟩
  | collectReg (s : St) (pt : Tid → Nat) (t : Tid) (hl : s.loc t = .registered) :
      WStep ⟨s, pt⟩ ⟨startCollect t true (quietRust t s), upd pt t s.now⟩
  /-- Every other step leaves `pt` alone. -/
  | other (s s' : St) (pt : Tid → Nat) (hs : Step s s')
      (hr : ∀ t, s.loc t = .unregistered → (s'.loc t).isReg = false)
      (hc : ∀ t, s.loc t = .registered → ∀ l, s'.loc t ≠ .collecting true l) :
      WStep ⟨s, pt⟩ ⟨s', pt⟩

def winit : WSt := ⟨init, fun _ => 0⟩

inductive WReach : WSt → Prop
  | init : WReach winit
  | step {e e'} : WReach e → WStep e e' → WReach e'

theorem wstep_step {e e' : WSt} (h : WStep e e') : Step e.s e'.s := by
  cases h with
  | pinRegister s pt t hl => exact .pinRegister s t hl
  | collectReg s pt t hl => exact .collectReg s t hl
  | other s s' pt hs => exact hs

theorem wreach_reach {e : WSt} (h : WReach e) : Reachable e.s := by
  induction h with
  | init => exact .init
  | step _ hs ih => exact .step ih (wstep_step hs)

theorem collectUnreg_loc (s : St) : (collectUnreg s).1.loc = s.loc := by
  unfold collectUnreg; split <;> rfl

/-- The ghost `pt` restricts no behaviour: every base step is a `WStep`. -/
theorem step_wstep {s s' : St} (h : Step s s') (pt : Tid → Nat) : ∃ pt', WStep ⟨s, pt⟩ ⟨s', pt'⟩ := by
  cases h with
  | pinRegister t hl => exact ⟨_, .pinRegister s pt t hl⟩
  | collectReg t hl => exact ⟨_, .collectReg s pt t hl⟩
  | pinOuter t hl =>
    refine ⟨pt, .other _ _ pt (.pinOuter s t hl) ?_ ?_⟩
    · intro u hu; by_cases h : u = t <;> simp_all [LS.isReg]
    · intro u hu l; by_cases h : u = t <;> simp_all
  | pinNest t st d hl =>
    refine ⟨pt, .other _ _ pt (.pinNest s t st d hl) ?_ ?_⟩
    · intro u hu; by_cases h : u = t <;> simp_all [LS.isReg]
    · intro u hu l; by_cases h : u = t <;> simp_all
  | unpinNest t st d hl =>
    refine ⟨pt, .other _ _ pt (.unpinNest s t st d hl) ?_ ?_⟩
    · intro u hu; by_cases h : u = t <;> simp_all [LS.isReg]
    · intro u hu l; by_cases h : u = t <;> simp_all
  | unpinOuter t st hl =>
    refine ⟨pt, .other _ _ pt (.unpinOuter s t st hl) ?_ ?_⟩
    · intro u hu; by_cases h : u = t <;> simp_all [LS.isReg]
    · intro u hu l; by_cases h : u = t <;> simp_all
  | release t hl =>
    refine ⟨pt, .other _ _ pt (.release s t hl) ?_ ?_⟩
    · intro u hu; by_cases h : u = t <;> simp_all [LS.isReg]
    · intro u hu l; by_cases h : u = t <;> simp_all
  | defer id byId =>
    refine ⟨pt, .other _ _ pt (.defer s id byId) ?_ ?_⟩
    · intro u hu; simp_all [LS.isReg]
    · intro u hu l; simp_all
  | cancel ids =>
    refine ⟨pt, .other _ _ pt (.cancel s ids) ?_ ?_⟩
    · intro u hu; simp_all [LS.isReg]
    · intro u hu l; simp_all
  | collectUnreg t hl =>
    refine ⟨pt, .other _ _ pt (.collectUnreg s t hl) ?_ ?_⟩
    · intro u hu; by_cases h : u = t
      · subst h; simp [startCollect, LS.isReg]
      · simp only [startCollect, upd_other _ _ _ _ h, collectUnreg_loc]; simp [hu, LS.isReg]
    · intro u hu l; by_cases h : u = t
      · subst h; simp_all
      · simp only [startCollect, upd_other _ _ _ _ h]
        unfold collectUnreg; split <;> simp_all
  | runOne t w c cs hl =>
    refine ⟨pt, .other _ _ pt (.runOne s t w c cs hl) ?_ ?_⟩
    · intro u hu; by_cases h : u = t <;> simp_all [LS.isReg]
    · intro u hu l; by_cases h : u = t <;> simp_all
  | finish t w hl =>
    refine ⟨pt, .other _ _ pt (.finish s t w hl) ?_ ?_⟩
    · intro u hu; by_cases h : u = t <;> simp_all [LS.isReg]
    · intro u hu l; by_cases h : u = t <;> simp_all

/-! ## The ghost view -/

/-- Every registered thread viewed as pinned since `pt u`. -/
def wloc (e : WSt) : Tid → LS :=
  fun u => if (e.s.loc u).isReg then .pinned (e.pt u) 0 else .unregistered

theorem blocked_wloc (e : WSt) (c : Cb) (u : Tid) :
    blocked (wloc e) c u ↔ (e.s.loc u).isReg = true ∧ e.pt u ≤ c.time := by
  unfold blocked wloc
  by_cases h : (e.s.loc u).isReg <;> simp [h]

/-- The invariant (relative to the base invariant `Inv`). -/
structure WInv (e : WSt) : Prop where
  prev : ∀ c ∈ e.s.previous, ∀ u, blocked (wloc e) c u → e.s.threads u = some .busy
  pend : ∀ c ∈ e.s.pending, ∀ u, ¬ blocked (wloc e) c u
  todo : ∀ v w l, e.s.loc v = .collecting w l → ∀ c ∈ l, ∀ u, ¬ blocked (wloc e) c u
  ran : ∀ c ∈ e.s.ran, ∀ u, ¬ blocked (wloc e) c u

theorem bufInv_of {e : WSt} (h : Inv e.s) (hw : WInv e) : BufInv { e.s with loc := wloc e } := by
  refine ⟨?_, hw.prev, hw.pend⟩
  intro c _ u hb
  have := h.reg u
  rw [(blocked_wloc e c u).1 hb |>.1] at this
  simpa [Option.isSome_iff_ne_none] using this.symm

/-! ## The collector functions do not read `loc` -/

theorem completeEpoch_wl (s : St) (L : Tid → LS) :
    completeEpoch { s with loc := L } = { completeEpoch s with loc := L } := by
  unfold completeEpoch; split <;> rfl
theorem unregister_wl (s : St) (t : Tid) (L : Tid → LS) :
    unregister { s with loc := L } t = { unregister s t with loc := L } := by
  unfold unregister completeEpoch; dsimp only
  split <;> (try split) <;> (try split) <;> simp_all
theorem markQuiet_wl (t : Tid) (s : St) (L : Tid → LS) :
    markQuiet t { s with loc := L } = { markQuiet t s with loc := L } := by
  unfold markQuiet completeEpoch; dsimp only
  split <;> (try split) <;> simp_all
theorem quiet_wl (t : Tid) (fuel : Nat) : ∀ (s : St) (L : Tid → LS),
    quiet t fuel { s with loc := L } = ({ (quiet t fuel s).1 with loc := L }, (quiet t fuel s).2) := by
  induction fuel with
  | zero => intro s L; rfl
  | succ n ih =>
    intro s L
    simp only [quiet, takePending, markQuiet_wl]
    by_cases hb : s.threads t ≠ some .busy
    · simp [hb]
    · simp only [hb, ite_false]
      by_cases hc : s.busy - 1 = 0 ∧ (markQuiet t s).previous ≠ []
      · have := ih { markQuiet t s with pending := [] } L
        simp [this, hc.2, hc.1]
      · simp [hc]

theorem collectUnreg_wl (s : St) (L : Tid → LS) :
    collectUnreg { s with loc := L } = ({ (collectUnreg s).1 with loc := L }, (collectUnreg s).2) := by
  unfold collectUnreg; split <;> rfl

theorem quiet_loc (t : Tid) (fuel : Nat) (s : St) : (quiet t fuel s).1.loc = s.loc := by
  exact congrArg (fun r => r.1.loc) (quiet_wl t fuel s s.loc)

/-! ## Preservation -/

theorem wloc_eq {e e' : WSt} (hp : e'.pt = e.pt) (hr : ∀ u, (e'.s.loc u).isReg = (e.s.loc u).isReg) :
    wloc e' = wloc e := by
  funext u; simp [wloc, hp, hr u]

/-- A step that changes neither the buffers, `threads`, `ran`, nor any thread's `isReg`, and
only shrinks to-do lists. -/
theorem winv_local {e e' : WSt} (hw : WInv e) (hp : e'.pt = e.pt)
    (hr : ∀ u, (e'.s.loc u).isReg = (e.s.loc u).isReg) (hth : e'.s.threads = e.s.threads)
    (hpe : e'.s.pending = e.s.pending) (hpr : e'.s.previous = e.s.previous)
    (hran : e'.s.ran = e.s.ran)
    (hcol : ∀ v w l, e'.s.loc v = .collecting w l → ∃ w' l', e.s.loc v = .collecting w' l' ∧ l ⊆ l') :
    WInv e' := by
  have hl := wloc_eq hp hr
  refine ⟨?_, ?_, ?_, ?_⟩
  · rw [hl, hpr, hth]; exact hw.prev
  · rw [hl, hpe]; exact hw.pend
  · intro v w l hv c hc u
    obtain ⟨w', l', hv', hs⟩ := hcol v w l hv
    rw [hl]; exact hw.todo v w' l' hv' c (hs hc) u
  · rw [hl, hran]; exact hw.ran

theorem blocked_upd_pin {L : Tid → LS} {t : Tid} {n : Nat} {c : Cb} {u : Tid}
    (hb : blocked (upd L t (.pinned n 0)) c u) (hc : c.time < n) : u ≠ t ∧ blocked L c u := by
  obtain ⟨st, d, h, hle⟩ := hb
  by_cases hu : u = t
  · subst hu; simp at h; omega
  · exact ⟨hu, st, d, by simpa [hu] using h, hle⟩

theorem blocked_upd_np' {L : Tid → LS} {t : Tid} {v : LS} (hv : NotPinned v) {c : Cb} {u : Tid}
    (hb : blocked (upd L t v) c u) : u ≠ t ∧ blocked L c u := by
  obtain ⟨st, d, h, hle⟩ := hb
  by_cases hu : u = t
  · subst hu; simp at h; exact absurd h (hv st d)
  · exact ⟨hu, st, d, by simpa [hu] using h, hle⟩

theorem winv_step {e e' : WSt} (h : Inv e.s) (hcnt : CInv e.s) (hw : WInv e) (hs : WStep e e') :
    WInv e' := by
  cases hs with
  | pinRegister s pt t hl =>
    -- `pt t := now`: `t` blocks only callbacks deferred from now on, and none exists yet.
    have hwl : wloc ⟨register s t, upd pt t s.now⟩ = upd (wloc ⟨s, pt⟩) t (.pinned s.now 0) := by
      funext u; by_cases hu : u = t
      · subst hu; simp [wloc, register, LS.isReg]
      · simp [wloc, register, hu]
    refine ⟨?_, ?_, ?_, ?_⟩
    · intro c hc u hb; rw [hwl] at hb
      change c ∈ s.previous at hc
      have := blocked_upd_pin hb (h.timeBuf c (by simp [bufs, hc]))
      show (register s t).threads u = some .busy
      simp only [register, upd_other _ _ _ _ this.1]; exact hw.prev c hc u this.2
    · intro c hc u hb; rw [hwl] at hb
      change c ∈ s.pending at hc
      exact hw.pend c hc u (blocked_upd_pin hb (h.timeBuf c (by simp [bufs, hc]))).2
    · intro v w l hv c hc u hb; rw [hwl] at hb
      have hvt : v ≠ t := by rintro rfl; simp [register] at hv
      simp only [register, upd_other _ _ _ _ hvt] at hv
      exact hw.todo v w l hv c hc u (blocked_upd_pin hb (h.timeTodo v w l hv c hc)).2
    · intro c hc u hb; rw [hwl] at hb
      change c ∈ s.ran at hc
      exact hw.ran c hc u (blocked_upd_pin hb (h.timeRan c hc)).2
  | collectReg s pt t hl =>
    -- `quiet` on the view with `t` not pinned, then `t` is viewed as pinned since `now`.
    rw [quietRust_eq]
    let e : WSt := ⟨s, pt⟩
    let Lp := upd (wloc e) t .registered
    have hbp : ∀ c u, blocked Lp c u → blocked (wloc e) c u :=
      fun c u hb => (blocked_upd_np' (by simp [NotPinned]) hb).2
    have hP : BufInv { s with loc := Lp } :=
      BufInv.mono (s := { s with loc := wloc e }) (bufInv_of h hw) hbp rfl rfl rfl rfl
    have g := quiet_spec t 2 { s with loc := Lp } hP (cinv_of hcnt rfl rfl rfl)
      (fun c hb => (blocked_upd_np' (L := wloc e) (by simp [NotPinned]) hb).1 rfl)
    rw [quiet_wl] at g
    obtain ⟨-, -, -, -, gb, gl, gm⟩ := g
    let r := quiet t 2 s
    have hrl : r.1.loc = s.loc := quiet_loc t 2 s
    have hmem : ∀ c, c ∈ bufs r.1 ∨ c ∈ r.2 → c.time < s.now := fun c hc =>
      h.timeBuf c (by simpa [bufs] using gm c (by simpa [bufs] using hc))
    have hwl : wloc ⟨startCollect t true r, upd pt t s.now⟩ = upd Lp t (.pinned s.now 0) := by
      funext u; by_cases hu : u = t
      · subst hu; simp [wloc, startCollect, LS.isReg]
      · simp [Lp, wloc, startCollect, hu, hrl, e]
    have hb' : ∀ c u, c.time < s.now →
        blocked (wloc ⟨startCollect t true r, upd pt t s.now⟩) c u → blocked Lp c u := by
      intro c u hc hb; rw [hwl] at hb
      exact (blocked_upd_pin hb hc).2
    refine ⟨?_, ?_, ?_, ?_⟩
    · intro c hc u hb
      exact gb.prev c hc u (hb' c u (hmem c (Or.inl (show c ∈ bufs r.1 by
        simp only [bufs, List.mem_append]; exact Or.inr hc))) hb)
    · intro c hc u hb
      exact gb.pend c hc u (hb' c u (hmem c (Or.inl (show c ∈ bufs r.1 by
        simp only [bufs, List.mem_append]; exact Or.inl (Or.inl hc)))) hb)
    · intro v w l hv c hc u hb
      by_cases hvt : v = t
      · subst hvt; simp [startCollect] at hv; obtain ⟨-, rfl⟩ := hv
        simp at hc
        exact gl c hc.1 u (hb' c u (hmem c (Or.inr hc.1)) hb)
      · simp only [startCollect, upd_other _ _ _ _ hvt] at hv; rw [hrl] at hv
        exact hw.todo v w l hv c hc u (hbp c u (hb' c u (h.timeTodo v w l hv c hc) hb))
    · intro c hc u hb
      simp only [startCollect] at hc
      rcases List.mem_append.1 hc with hc | hc
      · have hc' : c ∈ s.ran := by
          have hran : r.1.ran = s.ran := by
            obtain ⟨-, -, hr, -⟩ := quiet_spec t 2 s h.buf hcnt
              (notPinned_of_blocked (by simp [hl, NotPinned]))
            exact hr
          rwa [hran] at hc
        exact hw.ran c hc' u (hbp c u (hb' c u (h.timeRan c hc') hb))
      · simp at hc
        exact gl c hc.1 u (hb' c u (hmem c (Or.inr hc.1)) hb)
  | other s s' pt hs hr hc =>
    cases hs with
    | pinRegister t hl => exact absurd (hr t hl) (by simp [register, LS.isReg])
    | collectReg t hl => exact (hc t hl ((quietRust t s).2.filter (fun c => !c.byId)) (by simp [startCollect])).elim
    | pinOuter t hl =>
      refine winv_local hw rfl ?_ rfl rfl rfl rfl ?_
      · intro u; by_cases hu : u = t
        · subst hu; simp [hl, LS.isReg]
        · simp [hu]
      · intro v w l hv; by_cases hvt : v = t
        · subst hvt; simp at hv
        · exact ⟨w, l, by simpa [hvt] using hv, fun _ h => h⟩
    | pinNest t st d hl =>
      refine winv_local hw rfl ?_ rfl rfl rfl rfl ?_
      · intro u; by_cases hu : u = t
        · subst hu; simp [hl, LS.isReg]
        · simp [hu]
      · intro v w l hv; by_cases hvt : v = t
        · subst hvt; simp at hv
        · exact ⟨w, l, by simpa [hvt] using hv, fun _ h => h⟩
    | unpinNest t st d hl =>
      refine winv_local hw rfl ?_ rfl rfl rfl rfl ?_
      · intro u; by_cases hu : u = t
        · subst hu; simp [hl, LS.isReg]
        · simp [hu]
      · intro v w l hv; by_cases hvt : v = t
        · subst hvt; simp at hv
        · exact ⟨w, l, by simpa [hvt] using hv, fun _ h => h⟩
    | unpinOuter t st hl =>
      refine winv_local hw rfl ?_ rfl rfl rfl rfl ?_
      · intro u; by_cases hu : u = t
        · subst hu; simp [hl, LS.isReg]
        · simp [hu]
      · intro v w l hv; by_cases hvt : v = t
        · subst hvt; simp at hv
        · exact ⟨w, l, by simpa [hvt] using hv, fun _ h => h⟩
    | finish t w hl =>
      refine winv_local hw rfl ?_ rfl rfl rfl rfl ?_
      · intro u; by_cases hu : u = t
        · subst hu; cases w <;> simp [hl, LS.isReg]
        · simp [hu]
      · intro v w' l hv; by_cases hvt : v = t
        · subst hvt; cases w <;> simp at hv
        · exact ⟨w', l, by simpa [hvt] using hv, fun _ h => h⟩
    | runOne t w c cs hl =>
      have hwl : wloc ⟨{ s with loc := upd s.loc t (.collecting w cs), ran := s.ran ++ [c] }, pt⟩ =
          wloc ⟨s, pt⟩ := by
        refine wloc_eq rfl ?_; intro u; by_cases hu : u = t
        · subst hu; simp [hl, LS.isReg]
        · simp [hu]
      refine ⟨?_, ?_, ?_, ?_⟩
      · rw [hwl]; exact hw.prev
      · rw [hwl]; exact hw.pend
      · intro v w' l hv x hx u; rw [hwl]
        by_cases hvt : v = t
        · subst hvt; simp at hv; obtain ⟨rfl, rfl⟩ := hv
          exact hw.todo _ _ _ hl x (by simp [hx]) u
        · simp [hvt] at hv; exact hw.todo v w' l hv x hx u
      · intro x hx u; rw [hwl]; simp at hx
        rcases hx with hx | rfl
        · exact hw.ran x hx u
        · exact hw.todo t w _ hl x (by simp) u
    | defer id byId =>
      refine ⟨?_, ?_, ?_, ?_⟩
      · exact hw.prev
      · exact hw.pend
      · exact hw.todo
      · exact hw.ran
    | cancel ids =>
      exact ⟨fun c hc => hw.prev c (cancelList_sub _ _ hc),
             fun c hc => hw.pend c (cancelList_sub _ _ hc), hw.todo, hw.ran⟩
    | release t hl =>
      let e : WSt := ⟨s, pt⟩
      let Lr := upd (wloc e) t .unregistered
      have hbr : ∀ c u, blocked Lr c u → blocked (wloc e) c u :=
        fun c u hb => (blocked_upd_np' (by simp [NotPinned]) hb).2
      let s1 : St := { s with loc := upd s.loc t .unregistered }
      have hb1 : BufInv { s1 with loc := Lr } :=
        BufInv.mono (s := { s with loc := wloc e }) (bufInv_of h hw) hbr rfl rfl rfl rfl
      have hu := unregister_inv _ t hb1 (cinv_of hcnt rfl rfl rfl)
        (fun c hb => (blocked_upd_np' (L := wloc e) (by simp [NotPinned]) hb).1 rfl)
      rw [unregister_wl] at hu
      have hwl : wloc ⟨unregister s1 t, pt⟩ = Lr := by
        funext u; by_cases hut : u = t
        · subst hut; simp [Lr, wloc, s1, LS.isReg]
        · simp [Lr, wloc, s1, hut, e]
      refine ⟨?_, ?_, ?_, ?_⟩
      · rw [hwl]; exact hu.prev
      · rw [hwl]; exact hu.pend
      · intro v w l hv c hc u hb; rw [hwl] at hb
        simp only [unregister_loc] at hv
        have hvt : v ≠ t := by rintro rfl; simp at hv
        simp only [upd_other _ _ _ _ hvt] at hv
        exact hw.todo v w l hv c hc u (hbr c u hb)
      · intro c hc u hb; rw [hwl] at hb
        simp only [unregister_ran] at hc
        exact hw.ran c hc u (hbr c u hb)
    | collectUnreg t hl =>
      let e : WSt := ⟨s, pt⟩
      have g := collectUnreg_good _ (bufInv_of h hw)
      rw [collectUnreg_wl] at g
      obtain ⟨-, -, -, -, gb, gl, -⟩ := g
      let r := collectUnreg s
      have hrl : r.1.loc = s.loc := collectUnreg_loc s
      have hran : r.1.ran = s.ran := by unfold r collectUnreg; split <;> rfl
      have hwl : wloc ⟨startCollect t false r, pt⟩ = wloc e := by
        refine wloc_eq rfl ?_; intro u; by_cases hu : u = t
        · subst hu; simp [startCollect, hl, LS.isReg, e]
        · simp [startCollect, hu, hrl, e]
      refine ⟨?_, ?_, ?_, ?_⟩
      · rw [hwl]; exact gb.prev
      · rw [hwl]; exact gb.pend
      · intro v w l hv c hc u; rw [hwl]
        by_cases hvt : v = t
        · subst hvt; simp [startCollect] at hv; obtain ⟨-, rfl⟩ := hv
          simp at hc; exact gl c hc.1 u
        · simp only [startCollect, upd_other _ _ _ _ hvt] at hv; rw [hrl] at hv
          exact hw.todo v w l hv c hc u
      · intro c hc u; rw [hwl]
        simp only [startCollect] at hc
        rcases List.mem_append.1 hc with hc | hc
        · rw [hran] at hc; exact hw.ran c hc u
        · simp at hc; exact gl c hc.1 u

theorem winv_init : WInv winit := by
  refine ⟨?_, ?_, ?_, ?_⟩ <;> simp [winit, init]

theorem wreach_winv {e : WSt} (h : WReach e) : WInv e := by
  induction h with
  | init => exact winv_init
  | step hr hs ih =>
    have hb := wreach_reach hr
    exact winv_step (reachable_inv hb) (reachable_cinv hb) ih hs

/-! ## Main result -/

/-- **Weak-memory safety.** A callback that has been run or marked ready (`ran`), or that is in a
thread's to-do list, was deferred strictly before the latest own lock step (`register`/`quiet`)
of every registered thread, pinned or not. In lock-order terms: its `defer` precedes that lock
step, so it happens before every pinned region that thread starts later (module docs). -/
theorem weak_safety {e : WSt} (h : WReach e) (c : Cb)
    (hc : c ∈ e.s.ran ∨ ∃ v w l, e.s.loc v = .collecting w l ∧ c ∈ l)
    (u : Tid) (hu : (e.s.loc u).isReg = true) : c.time < e.pt u := by
  have hw := wreach_winv h
  have hnb : ¬ blocked (wloc e) c u := by
    rcases hc with hc | ⟨v, w, l, hv, hc⟩
    · exact hw.ran c hc u
    · exact hw.todo v w l hv c hc u
  rw [blocked_wloc] at hnb
  exact Nat.lt_of_not_le (fun hle => hnb ⟨hu, hle⟩)

theorem step_now_le {s s' : St} (h : Reachable s) (hs : Step s s') : s.now ≤ s'.now := by
  cases hs with
  | collectReg t hl =>
    rw [quietRust_eq]
    have := quiet_spec t 2 s (reachable_inv h).buf (reachable_cinv h)
      (notPinned_of_blocked (by simp [hl, NotPinned]))
    simp [startCollect, this.2.1]
  | collectUnreg t hl => simp only [startCollect]; unfold collectUnreg; split <;> simp
  | release t hl => simp
  | _ => simp [register]

/-- `pt u` is the time of `u`'s own lock step: `now` is never smaller. -/
theorem pt_le_now {e : WSt} (h : WReach e) (u : Tid) : e.pt u ≤ e.s.now := by
  induction h with
  | init => simp [winit]
  | step hr hs ih =>
    have hle := step_now_le (wreach_reach hr) (wstep_step hs)
    cases hs with
    | pinRegister s pt t hl =>
      by_cases hu : u = t
      · subst hu; simp [register]
      · simp [hu, register]; simp at ih; omega
    | collectReg s pt t hl =>
      by_cases hu : u = t
      · subst hu; simpa using hle
      · simp [hu]; simp at ih hle; omega
    | other s s' pt hs =>
      simp at ih hle ⊢; omega

/-! ## On the primary model -/

section Events
open Ev
variable (W : Nat)

/-- Primary-model executions with the ghost `pt`: each `EStep` that projects to a base step
updates `pt` as `WStep` does, a stutter keeps it. -/
inductive EWReach : ESt → (Tid → Nat) → Prop
  | init : EWReach einit (fun _ => 0)
  | step {e e' : ESt} {pt pt' : Tid → Nat} : EWReach e pt → EStep W e e' →
      (e'.base = e.base ∧ pt' = pt ∨ WStep ⟨e.base, pt⟩ ⟨e'.base, pt'⟩) → EWReach e' pt'

theorem ewreach_wreach {e : ESt} {pt : Tid → Nat} (h : EWReach W e pt) : WReach ⟨e.base, pt⟩ := by
  induction h with
  | init => exact .init
  | step _ _ hw ih =>
    rcases hw with ⟨hb, rfl⟩ | hw
    · rw [hb]; exact ih
    · exact .step ih hw

/-- Every primary-model execution carries the ghost `pt`. -/
theorem ereach_ewreach {e : ESt} (h : EReach W e) : ∃ pt, EWReach W e pt := by
  induction h with
  | init => exact ⟨_, .init⟩
  | step _ hs ih =>
    obtain ⟨pt, hpt⟩ := ih
    rcases estep_base W hs with hb | hb
    · exact ⟨pt, .step hpt hs (.inl ⟨hb, rfl⟩)⟩
    · obtain ⟨pt', hw⟩ := step_wstep hb pt
      exact ⟨pt', .step hpt hs (.inr hw)⟩

/-- `weak_safety` on the primary model. -/
theorem weak_safety_events {e : ESt} {pt : Tid → Nat} (h : EWReach W e pt) (c : Cb)
    (hc : c ∈ e.base.ran ∨ ∃ v w l, e.base.loc v = .collecting w l ∧ c ∈ l)
    (u : Tid) (hu : (e.base.loc u).isReg = true) : c.time < pt u :=
  weak_safety (ewreach_wreach W h) c hc u hu

end Events

end Collect.Weak
