import Collect.Count

/-!
# Reclamation safety

Main theorem `safety`: in every reachable state, every callback that has been run (closure)
or marked ready (`defer_by_id`) is not `blocked`, i.e. no thread is still inside a pinned
region that started at or before the callback was deferred. This is the guarantee that
`Pin<'a>` documents: "no callback deferred at or after the start of `'a` will run during `'a`".
-/

namespace Collect

/-- The callbacks held by the collector. -/
def bufs (s : St) : List Cb := s.pending ++ s.current ++ s.previous

/-- Invariant on the collector buffers (relative to the thread-local states `s.loc`). -/
structure BufInv (s : St) : Prop where
  cur : ∀ c ∈ s.current, ∀ u, blocked s.loc c u → s.threads u ≠ none
  prev : ∀ c ∈ s.previous, ∀ u, blocked s.loc c u → s.threads u = some .busy
  pend : ∀ c ∈ s.pending, ∀ u, ¬ blocked s.loc c u

/-- The full inductive invariant. -/
structure Inv (s : St) : Prop where
  /-- `DATA.state` agrees with membership in `Collector::threads`. -/
  reg : ∀ t, (s.loc t).isReg = (s.threads t).isSome
  pinStart : ∀ t st d, s.loc t = .pinned st d → st < s.now
  timeBuf : ∀ c ∈ bufs s, c.time < s.now
  timeTodo : ∀ t w l, s.loc t = .collecting w l → ∀ c ∈ l, c.time < s.now
  timeRan : ∀ c ∈ s.ran, c.time < s.now
  buf : BufInv s
  todo : ∀ t w l, s.loc t = .collecting w l → ∀ c ∈ l, ∀ u, ¬ blocked s.loc c u
  ran : ∀ c ∈ s.ran, ∀ u, ¬ blocked s.loc c u

/-! ## `complete_epoch` -/

section complete
variable (s : St)

@[simp] theorem completeEpoch_loc : (completeEpoch s).loc = s.loc := by
  unfold completeEpoch; split <;> rfl
@[simp] theorem completeEpoch_now : (completeEpoch s).now = s.now := by
  unfold completeEpoch; split <;> rfl
@[simp] theorem completeEpoch_ran : (completeEpoch s).ran = s.ran := by
  unfold completeEpoch; split <;> rfl
theorem completeEpoch_isSome u :
    ((completeEpoch s).threads u).isSome = (s.threads u).isSome := by
  unfold completeEpoch; split
  · rfl
  · simp

theorem completeEpoch_mem c : c ∈ bufs (completeEpoch s) → c ∈ bufs s := by
  unfold completeEpoch bufs; split <;> simp <;> grind

theorem completeEpoch_inv (h : BufInv s) (hnb : noBusy s.threads) :
    BufInv (completeEpoch s) := by
  -- callbacks in `previous` have no blockers, since a blocker would be `busy`
  have hp : ∀ c ∈ s.previous, ∀ u, ¬ blocked s.loc c u :=
    fun c hc u hb => hnb u (h.prev c hc u hb)
  unfold completeEpoch
  split
  · rename_i hall
    have hcur : ∀ c ∈ s.current, ∀ u, ¬ blocked s.loc c u :=
      fun c hc u hb => h.cur c hc u hb (hall u)
    constructor <;> simp
    intro c hc
    rcases hc with hc | hc | hc
    · exact h.pend c hc
    · exact hp c hc
    · exact hcur c hc
  · constructor <;> simp
    · intro c hc u hb
      have := h.cur c hc u hb
      cases hh : s.threads u <;> simp_all
    · intro c hc
      rcases hc with hc | hc
      · exact h.pend c hc
      · exact hp c hc
end complete


theorem allNone_noBusy {th : Tid → Option TS} (h : allNone th) : noBusy th := by
  intro u; simp [h u]

/-! ## `unregister` -/

section unregister
variable (s : St) (t : Tid)

@[simp] theorem unregister_loc : (unregister s t).loc = s.loc := by
  dsimp only [unregister]
  split <;> (try split) <;> simp
@[simp] theorem unregister_now : (unregister s t).now = s.now := by
  dsimp only [unregister]
  split <;> (try split) <;> simp
@[simp] theorem unregister_ran : (unregister s t).ran = s.ran := by
  dsimp only [unregister]
  split <;> (try split) <;> simp

theorem unregister_isSome u :
    ((unregister s t).threads u).isSome = (upd s.threads t none u).isSome := by
  dsimp only [unregister]
  split <;> (try split) <;> simp [completeEpoch_isSome]

theorem unregister_mem c : c ∈ bufs (unregister s t) → c ∈ bufs s := by
  dsimp only [unregister]
  split <;> (try split) <;> intro h <;>
    first | (have := completeEpoch_mem _ c h; simpa [bufs] using this) | simpa [bufs] using h

theorem unregister_inv (h : BufInv s) (hc : CInv s) (ht : ∀ c, ¬ blocked s.loc c t) :
    BufInv (unregister s t) := by
  have h' : ∀ l b : Nat, BufInv { s with threads := upd s.threads t none, len := l, busy := b } := by
    intro l b; constructor
    · intro c hc u hb
      have hne : u ≠ t := by rintro rfl; exact ht c hb
      simpa [hne] using h.cur c hc u hb
    · intro c hc u hb
      have hne : u ≠ t := by rintro rfl; exact ht c hb
      simpa [hne] using h.prev c hc u hb
    · exact h.pend
  dsimp only [unregister]
  split
  · rename_i hb
    split
    · exact completeEpoch_inv _ (h' _ _) ((busy_last_iff hc hb (by simp)).1 ‹_›)
    · exact h' _ _
  · split
    · exact completeEpoch_inv _ (h' _ _) (allNone_noBusy ‹_›)
    · exact h' _ _
end unregister

/-! ## `quiet` -/

/-- `r` is a sound result of a locked collector operation started in `s`. -/
def Good (s : St) (r : St × List Cb) : Prop :=
  r.1.loc = s.loc ∧ r.1.now = s.now ∧ r.1.ran = s.ran ∧
  (∀ u, (r.1.threads u).isSome = (s.threads u).isSome) ∧
  BufInv r.1 ∧ (∀ c ∈ r.2, ∀ u, ¬ blocked s.loc c u) ∧
  (∀ c, c ∈ bufs r.1 ∨ c ∈ r.2 → c ∈ bufs s)

theorem Good.seq {s s1 s2 : St} {l1 l2} (h1 : Good s (s1, l1)) (h2 : Good s1 (s2, l2)) :
    Good s (s2, l1 ++ l2) := by
  obtain ⟨a1, b1, c1, d1, e1, f1, g1⟩ := h1
  obtain ⟨a2, b2, c2, d2, e2, f2, g2⟩ := h2
  simp only at *
  refine ⟨a2.trans a1, b2.trans b1, c2.trans c1, fun u => (d2 u).trans (d1 u), e2, ?_, ?_⟩
  · intro c hc u
    rcases List.mem_append.1 hc with hc | hc
    · exact f1 c hc u
    · exact a1 ▸ f2 c hc u
  · intro c hc
    rcases hc with hc | hc
    · exact g1 c (Or.inl (g2 c (Or.inl hc)))
    · rcases List.mem_append.1 hc with hc | hc
      · exact g1 c (Or.inr hc)
      · exact g1 c (Or.inl (g2 c (Or.inr hc)))

theorem takePending_good (s : St) (h : BufInv s) : Good s (takePending s) := by
  refine ⟨rfl, rfl, rfl, fun _ => rfl, ⟨h.cur, h.prev, by simp [takePending]⟩, h.pend, ?_⟩
  intro c hc; simp [bufs, takePending] at hc ⊢; grind

theorem markQuiet_good (t : Tid) (s : St) (h : BufInv s) (hc : CInv s)
    (ht : ∀ c, ¬ blocked s.loc c t)
    (hb : s.threads t = some .busy) : Good s (markQuiet t s, []) := by
  have h2 : BufInv { s with threads := upd s.threads t (some .quiet), busy := s.busy - 1 } := by
    constructor
    · intro c hc u hbl
      have hne : u ≠ t := by rintro rfl; exact ht c hbl
      simpa [hne] using h.cur c hc u hbl
    · intro c hc u hbl
      have hne : u ≠ t := by rintro rfl; exact ht c hbl
      simpa [hne] using h.prev c hc u hbl
    · exact h.pend
  have hsome : ∀ u, (upd s.threads t (some TS.quiet) u).isSome = (s.threads u).isSome := by
    intro u; by_cases hu : u = t
    · subst hu; simp [hb]
    · simp [hu]
  unfold markQuiet
  split
  · refine ⟨by simp, by simp, by simp, ?_,
      completeEpoch_inv _ h2 ((busy_last_iff hc hb (by simp)).1 ‹_›), by simp, ?_⟩
    · intro u; simp [completeEpoch_isSome, hsome]
    · intro c hc
      simp at hc
      have := completeEpoch_mem _ c hc
      simpa [bufs] using this
  · refine ⟨rfl, rfl, rfl, hsome, h2, by simp, ?_⟩
    intro c hc; simpa [bufs] using hc

theorem quiet_good (t : Tid) : ∀ (fuel : Nat) (s : St), BufInv s → CInv s →
    (∀ c, ¬ blocked s.loc c t) → Good s (quiet t fuel s)
  | 0, s, h, _, _ => by
    refine ⟨rfl, rfl, rfl, fun _ => rfl, h, by simp [quiet], ?_⟩
    intro c hc; simpa [quiet] using hc
  | fuel + 1, s, h, hc, ht => by
    simp only [quiet]
    split
    · exact takePending_good s h
    · rename_i hb
      have hb : s.threads t = some .busy := by simpa using hb
      have g1 := markQuiet_good t s h hc ht hb
      have g2 := takePending_good _ g1.2.2.2.2.1
      have g12 : Good s (takePending (markQuiet t s)) := by
        have := g1.seq g2; simpa [takePending] using this
      split
      · have hl : (takePending (markQuiet t s)).1.loc = s.loc := g12.1
        have g3 := quiet_good t fuel (takePending (markQuiet t s)).1 g12.2.2.2.2.1
          (takePending_cinv (markQuiet_cinv hc hb)) (by rw [hl]; exact ht)
        exact g12.seq g3
      · exact g12

theorem quiet_spec (t : Tid) (fuel : Nat) (s : St) (h : BufInv s) (hc : CInv s)
    (ht : ∀ c, ¬ blocked s.loc c t) : Good s (quiet t fuel s) := quiet_good t fuel s h hc ht

/-! ## `collect_unregistered` -/

theorem collectUnreg_spec (s : St) (h : BufInv s) :
    let r := collectUnreg s
    r.1.loc = s.loc ∧ r.1.now = s.now ∧ r.1.ran = s.ran ∧ r.1.threads = s.threads ∧
    BufInv r.1 ∧ (∀ c ∈ r.2, ∀ u, ¬ blocked s.loc c u) ∧
    (∀ c, c ∈ bufs r.1 ∨ c ∈ r.2 → c ∈ bufs s) := by
  unfold collectUnreg
  split
  · rename_i hall
    refine ⟨rfl, rfl, rfl, rfl, ⟨by simp, by simp, by simp⟩, ?_, ?_⟩
    · intro c hc u hb
      simp at hc
      rcases hc with hc | hc | hc
      · exact h.pend c hc u hb
      · have := h.prev c hc u hb; simp [hall u] at this
      · exact h.cur c hc u hb (hall u)
    · intro c hc; simp [bufs] at hc ⊢; grind
  · refine ⟨rfl, rfl, rfl, rfl, ⟨h.cur, h.prev, by simp⟩, h.pend, ?_⟩
    intro c hc; simp [bufs] at hc ⊢; grind

theorem collectUnreg_good (s : St) (h : BufInv s) : Good s (collectUnreg s) := by
  obtain ⟨a, b, c, d, e, f, g⟩ := collectUnreg_spec s h
  exact ⟨a, b, c, fun u => by rw [d], e, f, g⟩

/-! ## Effect of thread-local state changes on `blocked` -/

def NotPinned (v : LS) : Prop := ∀ st d, v ≠ .pinned st d

theorem blocked_upd_np {loc : Tid → LS} {t v} (hv : NotPinned v) (ho : NotPinned (loc t)) c u :
    blocked (upd loc t v) c u ↔ blocked loc c u := by
  by_cases hu : u = t
  · subst hu
    constructor
    · rintro ⟨st, d, h, _⟩; simp at h; exact absurd h (hv st d)
    · rintro ⟨st, d, h, _⟩; exact absurd h (ho st d)
  · simp [blocked, hu]

theorem notPinned_of_blocked {loc : Tid → LS} {t} (ho : NotPinned (loc t)) c :
    ¬ blocked loc c t := by
  rintro ⟨st, d, h, _⟩; exact ho st d h

/-- If `blocked` can only shrink, and the collector buffers and `threads` are unchanged,
the buffer invariant is preserved. -/
theorem BufInv.mono {s s' : St} (h : BufInv s) (hb : ∀ c u, blocked s'.loc c u → blocked s.loc c u)
    (hth : s'.threads = s.threads) (hp : s'.pending = s.pending) (hc : s'.current = s.current)
    (hpr : s'.previous = s.previous) : BufInv s' := by
  constructor
  · intro c hcm u hbl; rw [hth]; rw [hc] at hcm; exact h.cur c hcm u (hb c u hbl)
  · intro c hcm u hbl; rw [hth]; rw [hpr] at hcm; exact h.prev c hcm u (hb c u hbl)
  · intro c hcm u hbl; rw [hp] at hcm; exact h.pend c hcm u (hb c u hbl)

/-! ## Initial state and preservation -/

theorem inv_init : Inv init := by
  refine ⟨?_, ?_, ?_, ?_, ?_, ⟨?_, ?_, ?_⟩, ?_, ?_⟩ <;> simp [init, bufs, LS.isReg]

/-- Collection steps: the shared part of `collectReg` and `collectUnreg`. -/
theorem inv_startCollect {s : St} {t : Tid} {w : Bool} {r : St × List Cb} (h : Inv s)
    (hg : Good s r) (hloc : s.loc t = (if w then .registered else .unregistered)) :
    Inv (startCollect t w r) := by
  obtain ⟨ga, gb, gc, gd, ge, gf, gg⟩ := hg
  have hnp : NotPinned (s.loc t) := by cases w <;> simp [hloc, NotPinned]
  have hnp' : NotPinned (r.1.loc t) := ga ▸ hnp
  have hbl : ∀ c u, blocked (startCollect t w r).loc c u ↔ blocked s.loc c u := by
    intro c u
    simp only [startCollect]
    rw [blocked_upd_np (by simp [NotPinned]) hnp', ga]
  constructor
  · intro u
    simp only [startCollect]
    by_cases hu : u = t
    · subst hu; simp only [upd_same, LS.isReg]; rw [gd, ← h.reg, hloc]; cases w <;> rfl
    · simp only [upd_other _ _ _ _ hu]; rw [ga, gd]; exact h.reg u
  · intro u st d hu
    simp only [startCollect] at hu ⊢
    by_cases hut : u = t
    · subst hut; simp at hu
    · simp only [upd_other _ _ _ _ hut] at hu; rw [ga] at hu; rw [gb]; exact h.pinStart _ _ _ hu
  · intro c hc; simp only [startCollect]; rw [gb]
    exact h.timeBuf c (gg c (Or.inl (by simpa [bufs, startCollect] using hc)))
  · intro u w' l hu c hc
    simp only [startCollect] at hu ⊢; rw [gb]
    by_cases hut : u = t
    · subst hut; simp at hu; obtain ⟨-, rfl⟩ := hu
      simp at hc; exact h.timeBuf c (gg c (Or.inr hc.1))
    · simp only [upd_other _ _ _ _ hut] at hu; rw [ga] at hu; exact h.timeTodo _ _ _ hu c hc
  · intro c hc; simp only [startCollect] at hc ⊢; rw [gb]
    rcases List.mem_append.1 hc with hc | hc
    · rw [gc] at hc; exact h.timeRan c hc
    · simp at hc; exact h.timeBuf c (gg c (Or.inr hc.1))
  · have := BufInv.mono (s := r.1) (s' := startCollect t w r) ge
      (fun c u hb => by rw [ga]; exact (hbl c u).1 hb) rfl rfl rfl rfl
    exact this
  · intro u w' l hu c hc v hb
    rw [hbl] at hb
    simp only [startCollect] at hu
    by_cases hut : u = t
    · subst hut; simp at hu; obtain ⟨-, rfl⟩ := hu
      simp at hc; exact gf c hc.1 v hb
    · simp only [upd_other _ _ _ _ hut] at hu; rw [ga] at hu; exact h.todo _ _ _ hu c hc v hb
  · intro c hc v hb
    rw [hbl] at hb
    simp only [startCollect] at hc
    rcases List.mem_append.1 hc with hc | hc
    · rw [gc] at hc; exact h.ran c hc v hb
    · simp at hc; exact gf c hc.1 v hb

/-- Entering an outermost pinned region at time `s.now` blocks nothing already deferred. -/
theorem blocked_newPin {s : St} {t : Tid} (_h : Inv s) (ho : NotPinned (s.loc t)) {c : Cb}
    (hc : c.time < s.now) u :
    blocked (upd s.loc t (.pinned s.now 0)) c u → blocked s.loc c u := by
  rintro ⟨st, d, hl, hle⟩
  by_cases hu : u = t
  · subst hu; simp at hl; omega
  · exact ⟨st, d, by simpa [hu] using hl, hle⟩

theorem inv_pin {s : St} {t : Tid} (h : Inv s) (ho : NotPinned (s.loc t))
    (th : Tid → Option TS) (hth : ∀ u, u ≠ t → th u = s.threads u)
    (hreg : (th t).isSome = true) :
    Inv { s with now := s.now + 1, loc := upd s.loc t (.pinned s.now 0), threads := th } := by
  have hbt : ∀ c, c.time < s.now → ∀ u, blocked (upd s.loc t (.pinned s.now 0)) c u →
      blocked s.loc c u ∧ u ≠ t := by
    intro c hc u hb
    refine ⟨blocked_newPin h ho hc u hb, ?_⟩
    rintro rfl; exact notPinned_of_blocked ho c (blocked_newPin h ho hc _ hb)
  constructor
  · intro u; by_cases hu : u = t
    · subst hu; simp [LS.isReg, hreg]
    · simp [hu, hth u hu]; exact h.reg u
  · intro u st d hu; by_cases hut : u = t
    · subst hut; simp at hu; dsimp only; omega
    · simp [hut] at hu; have := h.pinStart _ _ _ hu; dsimp only; omega
  · intro c hc; have := h.timeBuf c hc; dsimp only; omega
  · intro u w l hu c hc; by_cases hut : u = t
    · subst hut; simp at hu
    · simp [hut] at hu; have := h.timeTodo _ _ _ hu c hc; dsimp only; omega
  · intro c hc; have := h.timeRan c hc; dsimp only; omega
  · constructor
    · intro c hc u hb
      have := hbt c (h.timeBuf c (by simp [bufs, hc])) u hb
      simp only; rw [hth u this.2]; exact h.buf.cur c hc u this.1
    · intro c hc u hb
      have := hbt c (h.timeBuf c (by simp [bufs, hc])) u hb
      simp only; rw [hth u this.2]; exact h.buf.prev c hc u this.1
    · intro c hc u hb
      exact h.buf.pend c hc u (hbt c (h.timeBuf c (by simp [bufs, hc])) u hb).1
  · intro u w l hu c hc v hb
    have hut : u ≠ t := by rintro rfl; simp at hu
    simp [hut] at hu
    exact h.todo _ _ _ hu c hc v (hbt c (h.timeTodo _ _ _ hu c hc) v hb).1
  · intro c hc v hb
    exact h.ran c hc v (hbt c (h.timeRan c hc) v hb).1

/-- Local-state-only steps where `blocked` can only shrink and no thread's to-do list grows. -/
theorem inv_local {s : St} {t : Tid} {v : LS} (h : Inv s)
    (hreg : v.isReg = (s.loc t).isReg)
    (hps : ∀ st d, v = .pinned st d → ∃ d', s.loc t = .pinned st d')
    (hcol : ∀ w l, v = .collecting w l → ∃ w' l', s.loc t = .collecting w' l' ∧ l ⊆ l') :
    Inv { s with loc := upd s.loc t v } := by
  have hb : ∀ c u, blocked (upd s.loc t v) c u → blocked s.loc c u := by
    rintro c u ⟨st, d, hl, hle⟩
    by_cases hu : u = t
    · subst hu; simp at hl; obtain ⟨d', hd'⟩ := hps st d hl; exact ⟨st, d', hd', hle⟩
    · exact ⟨st, d, by simpa [hu] using hl, hle⟩
  constructor
  · intro u; by_cases hu : u = t
    · subst hu; simp [hreg]; exact h.reg u
    · simp [hu]; exact h.reg u
  · intro u st d hu; by_cases hut : u = t
    · subst hut; simp at hu; obtain ⟨d', hd'⟩ := hps st d hu; exact h.pinStart _ _ _ hd'
    · simp [hut] at hu; exact h.pinStart _ _ _ hu
  · exact h.timeBuf
  · intro u w l hu c hc; by_cases hut : u = t
    · subst hut; simp at hu; obtain ⟨w', l', hl', hsub⟩ := hcol w l hu
      exact h.timeTodo _ _ _ hl' c (hsub hc)
    · simp [hut] at hu; exact h.timeTodo _ _ _ hu c hc
  · exact h.timeRan
  · exact BufInv.mono h.buf hb rfl rfl rfl rfl
  · intro u w l hu c hc x hx; by_cases hut : u = t
    · subst hut; simp at hu; obtain ⟨w', l', hl', hsub⟩ := hcol w l hu
      exact h.todo _ _ _ hl' c (hsub hc) x (hb c x hx)
    · simp [hut] at hu; exact h.todo _ _ _ hu c hc x (hb c x hx)
  · intro c hc x hx; exact h.ran c hc x (hb c x hx)

theorem cancelList_sub (ids : List Nat) (l : List Cb) : cancelList ids l ⊆ l :=
  fun _ hc => (List.mem_filter.1 hc).1

theorem inv_step {s s' : St} (h : Inv s) (hcnt : CInv s) (hs : Step s s') : Inv s' := by
  cases hs with
  | pinRegister t hl =>
    have h0 : Inv { s with len := s.len + 1, busy := if s.busy = 0 then 1 else s.busy } :=
      ⟨h.1, h.2, h.3, h.4, h.5, ⟨h.buf.1, h.buf.2, h.buf.3⟩, h.7, h.8⟩
    exact inv_pin h0 (t := t) (by simp [hl, NotPinned]) _ (fun u hu => by simp [hu]) (by simp)
  | pinOuter t hl =>
    have := inv_pin h (t := t) (by simp [hl, NotPinned]) s.threads (fun _ _ => rfl)
      (by have := h.reg t; rw [hl] at this; simpa [LS.isReg] using this.symm)
    exact this
  | pinNest t st d hl =>
    refine inv_local h (by simp [hl, LS.isReg]) ?_ (by simp)
    intro st' d' he; cases he; exact ⟨d, hl⟩
  | unpinNest t st d hl =>
    refine inv_local h (by simp [hl, LS.isReg]) ?_ (by simp)
    intro st' d' he; cases he; exact ⟨d + 1, hl⟩
  | unpinOuter t st hl =>
    exact inv_local h (by simp [hl, LS.isReg]) (by simp) (by simp)
  | release t hl =>
    have hnp : NotPinned (s.loc t) := by simp [hl, NotPinned]
    have hbl : ∀ c u, blocked (upd s.loc t .unregistered) c u ↔ blocked s.loc c u :=
      blocked_upd_np (by simp [NotPinned]) hnp
    have hb1 : BufInv { s with loc := upd s.loc t .unregistered } :=
      BufInv.mono h.buf (fun c u hb => (hbl c u).1 hb) rfl rfl rfl rfl
    have hnp1 : NotPinned (upd s.loc t LS.unregistered t) := by simp [NotPinned]
    have hbu := unregister_inv _ t hb1 (cinv_of hcnt rfl rfl rfl) (notPinned_of_blocked hnp1)
    constructor
    · intro u; simp only [unregister_loc]; rw [unregister_isSome]
      by_cases hu : u = t
      · subst hu; simp [LS.isReg]
      · simp [hu]; exact h.reg u
    · intro u st d hu; simp only [unregister_loc, unregister_now] at hu ⊢
      by_cases hut : u = t
      · subst hut; simp at hu
      · simp [hut] at hu; exact h.pinStart u st d hu
    · intro c hc; simp only [unregister_now]; exact h.timeBuf c (by simpa [bufs] using unregister_mem _ _ c hc)
    · intro u w l hu; simp only [unregister_loc, unregister_now] at hu ⊢
      by_cases hut : u = t
      · subst hut; simp at hu
      · simp [hut] at hu; exact h.timeTodo u w l hu
    · intro c hc; simp only [unregister_ran, unregister_now] at hc ⊢; exact h.timeRan c hc
    · exact hbu
    · intro u w l hu c hc x hx; simp only [unregister_loc] at hu hx ⊢
      rw [hbl] at hx
      by_cases hut : u = t
      · subst hut; simp at hu
      · simp [hut] at hu; exact h.todo u w l hu c hc x hx
    · intro c hc x hx; simp only [unregister_loc, unregister_ran] at hc hx ⊢
      rw [hbl] at hx; exact h.ran c hc x hx
  | defer id byId =>
    constructor
    · exact h.reg
    · intro u st d hu; have := h.pinStart u st d hu; simp; omega
    · intro c hc; simp only [bufs, List.mem_append, List.mem_singleton] at hc ⊢
      rcases hc with (hm | (hm | hm)) | hm
      · have := h.timeBuf c (by simp [bufs, hm]); omega
      · have := h.timeBuf c (by simp [bufs, hm]); omega
      · subst hm; dsimp only; omega
      · have := h.timeBuf c (by simp [bufs, hm]); omega
    · intro u w l hu c hc; have := h.timeTodo u w l hu c hc; simp; omega
    · intro c hc; have := h.timeRan c hc; simp; omega
    · constructor
      · intro c hc u hb; simp at hc
        rcases hc with hc | rfl
        · exact h.buf.cur c hc u hb
        · obtain ⟨st, d, hl, -⟩ := hb
          have := h.reg u; rw [hl] at this; simp [LS.isReg] at this
          simpa [Option.isSome_iff_ne_none] using this.symm
      · exact h.buf.prev
      · exact h.buf.pend
    · exact h.todo
    · exact h.ran
  | cancel ids =>
    constructor
    · exact h.reg
    · exact h.pinStart
    · intro c hc
      apply h.timeBuf c
      simp only [bufs, List.mem_append] at hc ⊢
      rcases hc with (hm | hm) | hm
      · exact Or.inl (Or.inl (cancelList_sub _ _ hm))
      · exact Or.inl (Or.inr (cancelList_sub _ _ hm))
      · exact Or.inr (cancelList_sub _ _ hm)
    · exact h.timeTodo
    · exact h.timeRan
    · exact ⟨fun c hc => h.buf.cur c (cancelList_sub _ _ hc),
             fun c hc => h.buf.prev c (cancelList_sub _ _ hc),
             fun c hc => h.buf.pend c (cancelList_sub _ _ hc)⟩
    · exact h.todo
    · exact h.ran
  | collectReg t hl =>
    rw [quietRust_eq]
    exact inv_startCollect h
      (quiet_spec t 2 s h.buf hcnt (notPinned_of_blocked (by simp [hl, NotPinned]))) (by simp [hl])
  | collectUnreg t hl =>
    exact inv_startCollect h (collectUnreg_good s h.buf) (by simp [hl])
  | runOne t w c cs hl =>
    have h1 := inv_local (t := t) (v := .collecting w cs) h (by simp [hl, LS.isReg]) (by simp)
      (by intro w' l he; cases he; exact ⟨w, c :: cs, hl, by simp⟩)
    have hbl : ∀ x u, blocked (upd s.loc t (.collecting w cs)) x u ↔ blocked s.loc x u :=
      blocked_upd_np (by simp [NotPinned]) (by simp [hl, NotPinned])
    constructor
    · exact h1.reg
    · exact h1.pinStart
    · exact h1.timeBuf
    · exact h1.timeTodo
    · intro x hx; simp at hx
      rcases hx with hx | rfl
      · exact h.timeRan x hx
      · exact h.timeTodo t w _ hl x (by simp)
    · exact ⟨h1.buf.cur, h1.buf.prev, h1.buf.pend⟩
    · exact h1.todo
    · intro x hx u hb; simp at hx; rw [hbl] at hb
      rcases hx with hx | rfl
      · exact h.ran x hx u hb
      · exact h.todo t w _ hl x (by simp) u hb
  | finish t w hl =>
    refine inv_local h ?_ ?_ ?_
    · cases w <;> simp [hl, LS.isReg]
    · intro st d he; cases w <;> simp at he
    · intro w' l he; cases w <;> simp at he

/-- `busy_count` (and `threads.len()`) stay exact across every step. -/
theorem cinv_step {s s' : St} (h : Inv s) (hc : CInv s) (hs : Step s s') : CInv s' := by
  have hreg : ∀ t, s.loc t = .registered → s.threads t ≠ none := fun t hl => by
    have := h.reg t; rw [hl] at this; simp [LS.isReg] at this
    simpa [Option.isSome_iff_ne_none] using this.symm
  cases hs with
  | pinRegister t hl =>
    have := h.reg t; rw [hl] at this; simp [LS.isReg] at this
    exact register_cinv hc (by cases hh : s.threads t <;> simp_all)
  | release t hl =>
    exact unregister_cinv (cinv_of hc rfl rfl rfl) (by simpa using hreg t hl)
  | collectReg t hl => rw [quietRust_eq]; exact startCollect_cinv (quiet_cinv t 2 s hc (hreg t hl))
  | collectUnreg t hl => exact startCollect_cinv (collectUnreg_cinv hc)
  | _ => exact cinv_of hc rfl rfl rfl

theorem reachable_inv_cinv {s : St} (h : Reachable s) : Inv s ∧ CInv s := by
  induction h with
  | init => exact ⟨inv_init, cinv_init⟩
  | step _ hs ih => exact ⟨inv_step ih.1 ih.2 hs, cinv_step ih.1 ih.2 hs⟩

theorem reachable_inv {s : St} (h : Reachable s) : Inv s := (reachable_inv_cinv h).1

/-- **`busy_count` is exact.** In every reachable state the keys of `threads` are a finite
duplicate-free list `L`, `threads.len() = L.length`, and `busy_count` is the number of
`Busy` entries. -/
theorem reachable_cinv {s : St} (h : Reachable s) : CInv s := (reachable_inv_cinv h).2

/-! ## Main results -/

/-- **Reclamation safety.** Every callback that has been run (or `AtomicBool` marked ready) was
deferred strictly before the start of every pinned region that is still active. -/
theorem safety {s : St} (h : Reachable s) (c : Cb) (hc : c ∈ s.ran) (u : Tid) :
    ¬ blocked s.loc c u :=
  (reachable_inv h).ran c hc u

/-- Same property at the moment a closure is run (`runOne`) or a flag is marked ready. -/
theorem safety_step {s s' : St} (h : Reachable s) (hs : Step s s') (c : Cb)
    (hnew : c ∈ s'.ran) (u : Tid) : ¬ blocked s'.loc c u :=
  safety (.step h hs) c hnew u

/-- **No panics from the `Collector` asserts/unwraps.** `register`'s `assert!(insert().is_none())`,
`unregister`'s and `quiet`'s `unwrap()`, and `collect_unregistered`'s debug assertion. -/
theorem threads_consistent {s : St} (h : Reachable s) (t : Tid) :
    (s.loc t = .unregistered → s.threads t = none) ∧
    (s.loc t = .registered → s.threads t ≠ none) := by
  have := (reachable_inv h).reg t
  constructor
  · intro hl; rw [hl] at this; simp [LS.isReg] at this; cases hh : s.threads t <;> simp_all
  · intro hl; rw [hl] at this; simp [LS.isReg] at this
    simpa [Option.isSome_iff_ne_none] using this.symm

/-! ## `busy_count` never underflows or overflows -/

/-- `unregister` (`release`) never underflows `busy_count` (nor `threads.len()`). -/
theorem unregister_no_underflow {s : St} (h : Reachable s) {t : Tid}
    (hl : s.loc t = .registered) :
    (s.threads t = some .busy → 0 < s.busy) ∧ 0 < s.len :=
  ⟨busy_pos (reachable_cinv h), len_pos (reachable_cinv h) ((threads_consistent h t).2 hl)⟩

/-- `quiet` (`collect` from `Registered`) never underflows `busy_count`. -/
theorem quiet_no_underflow {s : St} (h : Reachable s) (t : Tid) (fuel : Nat) :
    QuietOk t fuel s :=
  quietOk t fuel s (reachable_cinv h)

/-- `busy_count ≤ threads.len()`, so `register`'s `busy_count += 1` overflows only if
`usize::MAX` threads are registered at once. -/
theorem busy_le_threads {s : St} (h : Reachable s) : s.busy ≤ s.len :=
  busy_le_len (reachable_cinv h)

end Collect
