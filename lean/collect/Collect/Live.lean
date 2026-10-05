import Collect.Events
import Collect.Flags

/-!
# `eventually_ran_events` without `cancel_by_ids`

`Ev.eventually_ran_events` builds its schedule from `pinForce`, `collectStore`, `collectCheck`,
`collectReg`/`collectUnreg`, `runOne`, `finish`, `unpinNest`/`unpinOuter`, `release` and one
`defer`; it never uses `cancel`. That fact is not visible in its statement (`ESteps`), so this
file replays the same schedule with a stronger closure `KSteps`: every step also keeps every
queued or stored `defer_by_id` flag and registers no new one (`KeepFlags`; the schedule's only
`defer` is a plain `defer`, not `defer_by_id`). Clients that compose `collect` with code that
relies on its flags (`lean/sync_table`, `Composed.lean`) need this form.

Main result: `eventually_ran_keep`.
-/

namespace Collect
namespace Ev

variable (W : Nat)

/-- A step that registers no new `defer_by_id` flag (every step except `defer_by_id`). -/
def NoNewFlag (e e' : ESt) : Prop :=
  ∀ c : Cb, c.byId = true → c ∈ bufs e'.base → c ∈ bufs e.base

/-- A step that does not drop a queued (or already stored) `defer_by_id` flag (every step
except `cancel`) and registers no new one (every step except `defer_by_id`). -/
def KeepFlags (e e' : ESt) : Prop :=
  (∀ c : Cb, c.byId = true → c ∈ bufs e.base ∨ c ∈ e.base.ran →
    c ∈ bufs e'.base ∨ c ∈ e'.base.ran) ∧ NoNewFlag e e'

theorem mem_bufs_flat {s : St} {c : Cb} : c ∈ bufs s ↔ c ∈ Flags.flat s := by
  simp only [bufs, Flags.flat, List.mem_append]; grind

theorem hands_bufs {s : St} {r : St × List Cb} (h : Flags.Hands s r) :
    ∀ c ∈ bufs r.1, c ∈ bufs s := fun _ hc =>
  mem_bufs_flat.2 (h.1.subset (List.mem_append_right _ (mem_bufs_flat.1 hc)))

/-- Runs of flag-keeping steps. -/
inductive KSteps : ESt → ESt → Prop
  | refl (e) : KSteps e e
  | tail {a b c} : KSteps a b → EStep W b c → KeepFlags b c → KSteps a c

theorem KSteps.esteps {a b : ESt} (h : KSteps W a b) : ESteps W a b := by
  induction h with
  | refl => exact .refl _
  | tail _ s _ ih => exact .tail ih s

theorem ksteps_trans {a b c : ESt} (h1 : KSteps W a b) (h2 : KSteps W b c) : KSteps W a c := by
  induction h2 with
  | refl => exact h1
  | tail _ s k ih => exact .tail ih s k

theorem ksingle {a b : ESt} (h : EStep W a b) (k : KeepFlags a b) : KSteps W a b :=
  .tail (.refl a) h k

theorem keep_sub {e e' : ESt} (hb : ∀ c ∈ bufs e.base, c ∈ bufs e'.base)
    (hr : ∀ c ∈ e.base.ran, c ∈ e'.base.ran) (hn : NoNewFlag e e') : KeepFlags e e' := by
  refine ⟨?_, hn⟩
  intro c _ h; rcases h with h | h
  · exact .inl (hb c h)
  · exact .inr (hr c h)

theorem keep_base {e e' : ESt} (h : e'.base = e.base) : KeepFlags e e' :=
  keep_sub (fun c hc => by rw [h]; exact hc) (fun c hc => by rw [h]; exact hc)
    (fun c _ hc => by rw [h] at hc; exact hc)

theorem keep_pres {e e' : ESt} {t} (h : Pres t e.base e'.base) (hn : NoNewFlag e e') :
    KeepFlags e e' :=
  keep_sub h.2.1 h.2.2 hn

/-- `collect_cold`'s locked part keeps flags: queued ones stay queued or are stored. -/
theorem keep_start {e e' : ESt} (t : Tid) (w : Bool) (r : St × List Cb)
    (hb : ∀ c ∈ bufs e.base, c ∈ bufs r.1 ∨ c ∈ r.2) (hr : r.1.ran = e.base.ran)
    (hb' : ∀ c ∈ bufs r.1, c ∈ bufs e.base)
    (he : e'.base = startCollect t w r) : KeepFlags e e' := by
  refine ⟨?_, fun c _ h => hb' c (by rw [he] at h; simpa [startCollect, bufs] using h)⟩
  intro c hid h
  rw [he]
  rcases h with h | h
  · rcases startCollect_bufs t w r c (hb c h) with h' | h' | h'
    · exact .inl h'
    · exact .inr h'
    · simp [hid] at h'
  · exact .inr (by simp [startCollect, hr, h])

theorem collectUnreg_ran (s : St) : (collectUnreg s).1.ran = s.ran := by
  unfold collectUnreg; split <;> rfl

/-! ## (A) Finishing split steps, flag-keeping -/

theorem krun (t : Tid) (w : Bool) : ∀ (l : List Cb) (e : ESt), e.base.loc t = .collecting w l →
    ∃ e', KSteps W e e' ∧ e'.fpend = e.fpend ∧ e'.chk = e.chk ∧ e'.mid = e.mid ∧
      bufs e'.base = bufs e.base ∧ (∀ x ∈ e.base.ran, x ∈ e'.base.ran) ∧ ∀ x ∈ l, x ∈ e'.base.ran
  | [], e, _ => ⟨e, .refl e, rfl, rfl, rfl, rfl, fun _ h => h, by simp⟩
  | c :: cs, e, hl => by
    obtain ⟨e', h1, h2, h3, h4, h5, h6, h7⟩ := krun t w cs _ (by simp : ({ e with base := { e.base with
        loc := upd e.base.loc t (.collecting w cs), ran := e.base.ran ++ [c] } } : ESt).base.loc t
          = .collecting w cs)
    refine ⟨e', ksteps_trans W (ksingle W (EStep.runOne e t w c cs hl)
        (keep_sub (fun _ h => h) (fun _ h => by simp [h]) (fun _ _ h => h))) h1, h2, h3, h4,
      by rw [h5]; rfl, fun x hx => h6 x (by simp [hx]), ?_⟩
    intro x hx
    rcases List.mem_cons.1 hx with rfl | hx
    · exact h6 _ (by simp)
    · exact h7 x hx

theorem kclean_thread {e : ESt} (h : EReach W e) (t : Tid) (c : Cb) (hc : Has c e) :
    ∃ e', KSteps W e e' ∧ e'.fpend t = false ∧ e'.chk t = false ∧ e'.mid t = false ∧
      (∀ u, u ≠ t → e'.fpend u = e.fpend u ∧ e'.chk u = e.chk u ∧ e'.mid u = e.mid u) ∧
      Has c e' := by
  obtain ⟨e1, s1, f1, k1, b1⟩ : ∃ e1, KSteps W e e1 ∧ e1.fpend t = false ∧
      (∀ u, u ≠ t → e1.fpend u = e.fpend u) ∧ e1.chk = e.chk ∧ e1.mid = e.mid ∧ e1.base = e.base := by
    cases hf : e.fpend t
    · exact ⟨e, .refl e, hf, fun _ _ => rfl, rfl, rfl, rfl⟩
    · exact ⟨_, ksingle W (EStep.pinForce e t hf) (keep_base rfl), by simp, fun u hu => by simp [hu],
        rfl, rfl, rfl⟩
  obtain ⟨b1c, b1m, b1b⟩ := b1
  obtain ⟨e2, s2, f2, c2, k2, m2, b2⟩ : ∃ e2, KSteps W e1 e2 ∧ e2.fpend = e1.fpend ∧
      e2.chk t = false ∧ (∀ u, u ≠ t → e2.chk u = e1.chk u ∧ e2.mid u = e1.mid u) ∧
      (e1.mid t = true → e2.mid t = true) ∧ e2.base = e1.base := by
    cases hk : e1.chk t
    · exact ⟨e1, .refl e1, rfl, hk, fun _ _ => ⟨rfl, rfl⟩, id, rfl⟩
    · refine ⟨_, ksingle W (EStep.collectStore e1 t hk) (keep_base rfl), by simp [setSeen],
        by simp, fun u hu => by simp [hu], fun _ => by simp,
        by simp [setSeen]⟩
  have hr2 : EReach W e2 := ereach_steps W h (esteps_trans W s1.esteps s2.esteps)
  have hc2 : Has c e2 := by unfold Has; rw [b2, b1b]; exact hc
  cases hm : e2.mid t
  · refine ⟨e2, ksteps_trans W s1 s2, by rw [f2]; exact f1, c2, hm, fun u hu => ?_, hc2⟩
    have := k2 u hu; rw [f2, k1 u hu, this.1, this.2, b1c, b1m]; exact ⟨rfl, rfl, rfl⟩
  · have hinv := ereach_splitInv W hr2
    have hcf : e2.chk t = false := c2
    rcases hinv.loc t (.inr hm) with hl | hl
    · obtain ⟨e3, s3, f3, c3, m3, b3⟩ : ∃ e3, EStep W e2 e3 ∧ e3.fpend = e2.fpend ∧
          e3.chk = e2.chk ∧ e3.mid = upd e2.mid t false ∧
          e3.base = startCollect t true (quiet t 2 e2.base) := by
        refine ⟨_, EStep.collectReg e2 t hl hm, ?_⟩
        split <;> simp [setSeen, quietRust_eq]
      have k3 : KeepFlags e2 e3 := keep_start t true _
        (fun c h => quiet_bufs t 2 _ c h) (quiet_ran t 2 _)
        (hands_bufs (Flags.quiet_hands t 2 _)) b3
      have hcol : e3.base.loc t = .collecting true ((quiet t 2 e2.base).2.filter (fun c => !c.byId)) := by
        rw [b3]; simp [startCollect]
      obtain ⟨e4, s4, f4, c4, m4, b4, r4, l4⟩ := krun W t true _ e3 hcol
      refine ⟨e4, ksteps_trans W (ksteps_trans W s1 s2) (ksteps_trans W (ksingle W s3 k3) s4),
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
    · obtain ⟨e3, s3, f3, c3, m3, b3⟩ : ∃ e3, EStep W e2 e3 ∧ e3.fpend = e2.fpend ∧
          e3.chk = e2.chk ∧ e3.mid = upd e2.mid t false ∧
          e3.base = startCollect t false (Collect.collectUnreg e2.base) :=
        ⟨_, EStep.collectUnreg e2 t hl hm, rfl, rfl, rfl, rfl⟩
      have k3 : KeepFlags e2 e3 := keep_start t false _
        (fun c h => collectUnreg_bufs _ c h) (collectUnreg_ran _)
        (hands_bufs (Flags.collectUnreg_hands _)) b3
      have hcol : e3.base.loc t =
          .collecting false ((Collect.collectUnreg e2.base).2.filter (fun c => !c.byId)) := by
        rw [b3]; simp [startCollect]
      obtain ⟨e4, s4, f4, c4, m4, b4, r4, l4⟩ := krun W t false _ e3 hcol
      refine ⟨e4, ksteps_trans W (ksteps_trans W s1 s2) (ksteps_trans W (ksingle W s3 k3) s4),
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
          left; rw [collectUnreg_ran]; exact hb

theorem kclean_upto {e : ESt} (h : EReach W e) (c : Cb) (hc : Has c e) : ∀ n : Nat,
    ∃ e', KSteps W e e' ∧
      (∀ t, t < n → e'.fpend t = false ∧ e'.chk t = false ∧ e'.mid t = false) ∧
      (∀ t, n ≤ t → e'.fpend t = e.fpend t ∧ e'.chk t = e.chk t ∧ e'.mid t = e.mid t) ∧
      Has c e'
  | 0 => ⟨e, .refl e, fun _ h => absurd h (Nat.not_lt_zero _), fun _ _ => ⟨rfl, rfl, rfl⟩, hc⟩
  | n + 1 => by
    obtain ⟨e1, a1, b1, c1, d1⟩ := kclean_upto h c hc n
    obtain ⟨e2, a2, f2, k2, m2, o2, d2⟩ := kclean_thread W (ereach_steps W h a1.esteps) n c d1
    refine ⟨e2, ksteps_trans W a1 a2, fun t ht => ?_, fun t ht => ?_, d2⟩
    · by_cases ht' : t = n
      · subst ht'; exact ⟨f2, k2, m2⟩
      · have := o2 t ht'; rw [this.1, this.2.1, this.2.2]; exact b1 t (by omega)
    · have hne : t ≠ n := by omega
      have := o2 t hne; rw [this.1, this.2.1, this.2.2]; exact c1 t (by omega)

theorem kclean {e : ESt} (h : EReach W e) (c : Cb) (hc : c ∈ bufs e.base) :
    ∃ e', KSteps W e e' ∧ (c ∈ e'.base.ran ∨ (Clean e' ∧ c ∈ bufs e'.base)) := by
  obtain ⟨N, hN⟩ := (ereach_splitInv W h).fin
  obtain ⟨e', a, b, d, hh⟩ := kclean_upto W h c (.inl hc) N
  refine ⟨e', a, ?_⟩
  rcases hh with hb | hr
  · refine .inr ⟨fun t => ?_, hb⟩
    by_cases ht : t < N
    · exact b t ht
    · have hle := Nat.le_of_not_lt ht
      have := d t hle; rw [this.1, this.2.1, this.2.2]; exact hN t hle
  · exact .inl hr

/-! ## (B) The drain schedule, flag-keeping -/

theorem k_release_drive (e : ESt) (t : Tid) (hcl : Clean e) (hl : e.base.loc t = .registered) :
    ∃ e', KSteps W e e' ∧ e'.base.loc t = .unregistered ∧ Pres t e.base e'.base ∧ Clean e' := by
  have hp : Pres t e.base (unregister { e.base with loc := upd e.base.loc t .unregistered } t) := by
    refine ⟨fun u hu => by simp [hu], ?_, by simp⟩
    intro c hc; exact unregister_mem_fwd _ t c (by simpa [bufs] using hc)
  refine ⟨_, ksingle W (EStep.release e t hl (hcl t).2.2 (hcl t).2.1) (keep_pres hp ?_), ?_, hp, hcl⟩
  · intro c _ hc
    have := (Flags.unregister_keeps { e.base with loc := upd e.base.loc t .unregistered } t).1
    exact mem_bufs_flat.2 (by simpa [Flags.flat] using this.subset (mem_bufs_flat.1 hc))
  simp

theorem k_unpin_drive (t : Tid) (st : Nat) : ∀ (d : Nat) (e : ESt), Clean e → e.base.loc t = .pinned st d →
    ∃ e', KSteps W e e' ∧ e'.base.loc t = .registered ∧ Pres t e.base e'.base ∧ Clean e'
  | 0, e, hcl, hl => ⟨_, ksingle W (EStep.unpinOuter e t st hl (hcl t).1) (keep_sub (fun _ h => h) (fun _ h => h) (fun _ _ h => h)), by simp,
      ⟨fun u hu => by simp [hu], fun _ h => h, fun _ h => h⟩, hcl⟩
  | d + 1, e, hcl, hl => by
    obtain ⟨e', h1, h2, h3, h4⟩ := k_unpin_drive t st d
      { e with base := { e.base with loc := upd e.base.loc t (.pinned st d) } } hcl (by simp)
    exact ⟨e', ksteps_trans W (ksingle W (EStep.unpinNest e t st d hl (hcl t).1) (keep_sub (fun _ h => h) (fun _ h => h) (fun _ _ h => h))) h1,
      h2, Pres.trans (b := { e.base with loc := upd e.base.loc t (.pinned st d) })
        ⟨fun u hu => by simp [hu], fun _ h => h, fun _ h => h⟩ h3, h4⟩

theorem k_run_drive (t : Tid) (w : Bool) : ∀ (l : List Cb) (e : ESt), Clean e →
    e.base.loc t = .collecting w l →
    ∃ e', KSteps W e e' ∧ e'.base.loc t = (if w then .registered else .unregistered) ∧
      Pres t e.base e'.base ∧ Clean e' ∧ ∀ c ∈ l, c ∈ e'.base.ran
  | [], e, hcl, hl => ⟨_, ksingle W (EStep.finish e t w hl) (keep_sub (fun _ h => h) (fun _ h => h) (fun _ _ h => h)), by simp,
      ⟨fun u hu => by simp [hu], fun _ h => h, fun _ h => h⟩, hcl, by simp⟩
  | c :: cs, e, hcl, hl => by
    obtain ⟨e', h1, h2, h3, h4, h5⟩ := k_run_drive t w cs
      { e with base := { e.base with loc := upd e.base.loc t (.collecting w cs),
                                      ran := e.base.ran ++ [c] } } hcl (by simp)
    refine ⟨e', ksteps_trans W (ksingle W (EStep.runOne e t w c cs hl)
        (keep_sub (fun _ h => h) (fun _ h => by simp [h]) (fun _ _ h => h))) h1, h2,
      Pres.trans (b := { e.base with loc := upd e.base.loc t (.collecting w cs), ran := e.base.ran ++ [c] })
        ⟨fun u hu => by simp [hu], fun _ h => h, fun _ h => by simp [h]⟩ h3, h4, ?_⟩
    intro x hx
    rcases List.mem_cons.1 hx with rfl | hx
    · exact h3.2.2 _ (by simp)
    · exact h5 x hx

theorem k_drain_thread (e : ESt) (t : Tid) (hcl : Clean e) :
    ∃ e', KSteps W e e' ∧ e'.base.loc t = .unregistered ∧ Pres t e.base e'.base ∧ Clean e' := by
  cases hl : e.base.loc t with
  | unregistered => exact ⟨e, .refl _, hl, .refl t _, hcl⟩
  | registered => exact k_release_drive W e t hcl hl
  | pinned st d =>
    obtain ⟨e1, a1, b1, c1, d1⟩ := k_unpin_drive W t st d e hcl hl
    obtain ⟨e2, a2, b2, c2, d2⟩ := k_release_drive W e1 t d1 b1
    exact ⟨e2, ksteps_trans W a1 a2, b2, c1.trans c2, d2⟩
  | collecting w l =>
    obtain ⟨e1, a1, b1, c1, d1, -⟩ := k_run_drive W t w l e hcl hl
    cases w
    · exact ⟨e1, a1, by simpa using b1, c1, d1⟩
    · obtain ⟨e2, a2, b2, c2, d2⟩ := k_release_drive W e1 t d1 (by simpa using b1)
      exact ⟨e2, ksteps_trans W a1 a2, b2, c1.trans c2, d2⟩

theorem k_drain_upto (e : ESt) (hcl : Clean e) : ∀ n : Nat, ∃ e', KSteps W e e' ∧
    (∀ t, t < n → e'.base.loc t = .unregistered) ∧ (∀ t, n ≤ t → e'.base.loc t = e.base.loc t) ∧
    (∀ c ∈ bufs e.base, c ∈ bufs e'.base) ∧ Clean e'
  | 0 => ⟨e, .refl _, fun _ h => absurd h (Nat.not_lt_zero _), fun _ _ => rfl, fun _ h => h, hcl⟩
  | n + 1 => by
    obtain ⟨e1, a1, b1, c1, d1, f1⟩ := k_drain_upto e hcl n
    obtain ⟨e2, a2, b2, c2, f2⟩ := k_drain_thread W e1 n f1
    refine ⟨e2, ksteps_trans W a1 a2, ?_, ?_, fun c h => c2.2.1 c (d1 c h), f2⟩
    · intro t ht
      by_cases h' : t = n
      · subst h'; exact b2
      · rw [c2.1 t h']; exact b1 t (by omega)
    · intro t ht
      have hne : t ≠ n := by omega
      rw [c2.1 t hne]; exact c1 t (by omega)

theorem keventually_ran_clean {e : ESt} (h : EReach W e) (hW : 1 < W) (hcl : Clean e) (c : Cb)
    (hc : c ∈ bufs e.base) : ∃ e', KSteps W e e' ∧ c ∈ e'.base.ran := by
  obtain ⟨N, hN⟩ := reachable_finLoc (ereach_base W h)
  obtain ⟨e1, a1, b1, c1, d1, f1⟩ := k_drain_upto W e hcl N
  have hall : ∀ t, e1.base.loc t = .unregistered := fun t => by
    by_cases ht : t < N
    · exact b1 t ht
    · have hle : N ≤ t := Nat.le_of_not_lt ht
      rw [c1 t hle]; exact hN t hle
  have key : ∃ e2, KSteps W e1 e2 ∧ (∀ t, e2.base.loc t = .unregistered) ∧ Clean e2 ∧
      c ∈ bufs e2.base ∧ events W e2 ≠ e2.seen 0 := by
    by_cases hev : events W e1 = e1.seen 0
    · refine ⟨_, ksingle W (EStep.defer e1 0 false)
          (keep_sub (fun x hx => by simp [bufs] at hx ⊢; grind) (fun _ h => h)
            (fun x hx h => by simp [bufs] at h ⊢; grind)), hall, f1, ?_, ?_⟩
      · have := d1 c hc; simp [bufs] at this ⊢; grind
      · exact defer_escapes W hW 0 hev
    · exact ⟨e1, .refl _, hall, f1, d1 c hc, hev⟩
  obtain ⟨e2, a2, hall2, f2, hc2, hne⟩ := key
  have hr2 : EReach W e2 := ereach_steps W h (esteps_trans W a1.esteps a2.esteps)
  have hnone : allNone e2.base.threads := fun t =>
    (Collect.threads_consistent (ereach_base W hr2) t).1 (hall2 t)
  have hcu := (collectUnreg_takes_all e2.base hnone c hc2).1
  let e3 : ESt := { e2 with chk := upd e2.chk 0 true }
  let e4 : ESt := { setSeen e3 0 (events W e3) e3.total with
                      mid := upd e3.mid 0 true, chk := upd e3.chk 0 false }
  have s3 : EStep W e2 e3 := EStep.collectCheck e2 0 (.inr (hall2 0)) (f2 0).2.2 (f2 0).2.1 hne
  have s4 : EStep W e3 e4 := EStep.collectStore e3 0 (by simp [e3])
  have s5 := EStep.collectUnreg (W := W) e4 0 (by simpa [e4, e3, setSeen] using hall2 0) (by simp [e4])
  have k5 : KeepFlags e4 ({ e4 with base := startCollect 0 false (collectUnreg e4.base), mid := upd e4.mid 0 false } : ESt) :=
    keep_start 0 false _ (fun c h => collectUnreg_bufs _ c h) (collectUnreg_ran _)
      (hands_bufs (Flags.collectUnreg_hands _)) rfl
  have a5 := ksteps_trans W (ksteps_trans W a1 a2)
    (.tail (.tail (.tail (.refl _) s3 (keep_base rfl)) s4 (keep_base rfl)) s5 k5)
  have hb4 : e4.base = e2.base := rfl
  by_cases hb : c.byId = true
  · exact ⟨_, a5, by simp [startCollect, hb4, hcu, hb]⟩
  · obtain ⟨e6, a6, -, -, -, d6⟩ := k_run_drive W 0 false
      ((collectUnreg e4.base).2.filter (fun c => !c.byId))
      { e4 with base := startCollect 0 false (collectUnreg e4.base), mid := upd e4.mid 0 false }
      (by intro t; by_cases ht : t = 0 <;> simp [e4, e3, setSeen, ht, f2 t, f2 0])
      (by simp only [startCollect]; simp [upd])
    exact ⟨e6, ksteps_trans W a5 a6, d6 c (List.mem_filter.2 ⟨by rw [hb4]; exact hcu, by cases e : c.byId <;> simp_all⟩)⟩

/-- **Eventual reclamation without `cancel_by_ids`.** `eventually_ran_events`, with a schedule
in which every step keeps every queued or stored `defer_by_id` flag (so no `cancel` drops one).
The schedule is the same: finish split steps, drain every thread (run to-do lists, unpin,
release), at most one escaping `defer`, then thread 0 collects. -/
theorem eventually_ran_keep {e : ESt} (h : EReach W e) (hW : 1 < W) (c : Cb)
    (hc : c ∈ bufs e.base) : ∃ e', KSteps W e e' ∧ c ∈ e'.base.ran := by
  obtain ⟨e1, hs1, hr | ⟨hcl, hb⟩⟩ := kclean W h c hc
  · exact ⟨e1, hs1, hr⟩
  · obtain ⟨e2, hs2, hr2⟩ := keventually_ran_clean W (ereach_steps W h hs1.esteps) hW hcl c hb
    exact ⟨e2, ksteps_trans W hs1 hs2, hr2⟩

end Ev
end Collect
