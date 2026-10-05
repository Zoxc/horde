import SyncTable.Model

/-!
# Safety of the concurrent model

Main results (all under `C.Cover`, i.e. the probe sequence visits every bucket). The invariants
are split in two:

* `reachable_sinv`: the **safety invariant** `SInv` holds on every run (`Reachable`), including
  runs where `PotentialSlot::insert_new` writes a key off its probe sequence
  (`Step.insertAny`): table status bookkeeping (the static empty table, id `0`, stays `live`
  and unwritten: `SInv.stat`, `SInv.tab0`), `SWF` (bounds, `growth_left` / `tombstones`
  accounting) for every allocated table, `collect` pins, and the tables each reader may
  dereference (`Holds`). `probe_in_bounds` follows from it.
* `preachable_inv`: the **full invariant** `Inv` (adding `WF.noHole`, the abstract map
  `curHist` / `ret`, and the reader linearizability state) holds on runs whose steps all
  respect the probe contract (`PReachable`, `ProbeOK`). `step_probeOK`: only `Step.insertAny`
  with a mismatched key can break it.

`Properties.lean` states the headline results on top of these (`no_use_after_free` on all runs,
`get_linearizable_some` on `PReachable` runs; the `none` case is in `Contract.lean`).
-/

namespace SyncTable

variable {K V : Type} [DecidableEq K] (C : Cfg K)

/-- Reader with pin start `st` may dereference table `t`. -/
def Holds (s : St K V) (st t : Nat) : Prop :=
  t < s.nextId ∧ (s.ts t = .live ∨ ∃ v d, s.ts t = .retired v d false ∧ st ≤ d)

/-- Table `t`, loaded at writer version `lv`, still shows the abstract map of a version
`≥ lv`: it is current, or it was retired at a version `≥ lv` (and is frozen since), or it is the
static empty table (id `0`, never retired, always empty) and the map was empty at some version
in `[lv, ver]` (when it stopped being current). -/
def View (s : St K V) (t lv : Nat) : Prop :=
  lv ≤ s.ver ∧ (t = s.cur ∨ (∃ v d cf, s.ts t = .retired v d cf ∧ lv ≤ v) ∨
    (t = 0 ∧ ∃ x, lv ≤ x ∧ x ≤ s.ver ∧ ∀ k w, ¬ s.hist x k w))

/-- `View` survives a step that only extends the history and keeps the first two cases. -/
theorem view_frame {s s' : St K V} {t lv : Nat} (hv : s.ver ≤ s'.ver)
    (hh : ∀ x, x ≤ s.ver → s'.hist x = s.hist x)
    (hcr : t = s.cur ∨ (∃ v d cf, s.ts t = .retired v d cf ∧ lv ≤ v) →
      t = s'.cur ∨ (∃ v d cf, s'.ts t = .retired v d cf ∧ lv ≤ v))
    (h : View s t lv) : View s' t lv := by
  refine ⟨Nat.le_trans h.1 hv, ?_⟩
  rcases h.2 with e | e | ⟨h0, x, h1, h2, h3⟩
  · exact (hcr (.inl e)).elim .inl (fun e' => .inr (.inl e'))
  · exact (hcr (.inr e)).elim .inl (fun e' => .inr (.inl e'))
  · exact .inr (.inr ⟨h0, x, h1, Nat.le_trans h2 hv, by rw [hh x h2]; exact h3⟩)

/-- The probed buckets are non-empty and do not hold `k`. -/
def Seen (T : Table K V) (k : K) (pre : List Nat) : Prop :=
  ∀ j ∈ pre, T.slot j ≠ .empty ∧ ∀ w, T.slot j ≠ .full k w

/-- Linearizability of a `get` result: some version in `[lv, ver]` agrees with it. -/
def Lin (s : St K V) (k : K) (lv : Nat) : Option V → Prop
  | none => ∃ x, lv ≤ x ∧ x ≤ s.ver ∧ ∀ w, ¬ s.hist x k w
  | some w => ∃ x, lv ≤ x ∧ x ≤ s.ver ∧ s.hist x k w

/-- A byte `o` loaded from bucket `j` still describes it: a non-`EMPTY` byte stays non-`EMPTY`,
and if `j` now holds `k` the load saw that same pair (buckets only go `EMPTY` → full →
`DELETED`, and a full bucket keeps its pair). -/
def Stable (T : Table K V) (k : K) (j : Nat) (o : Slot K V) : Prop :=
  o ≠ .empty → T.slot j ≠ .empty ∧ ∀ w, T.slot j = .full k w → o = .full k w

/-- The state of a group load: `todo ⊆ g`, every bucket of `g` is still to load or loaded, and
every loaded byte is from `g` and `Stable`. -/
def ScanOK (T : Table K V) (k : K) (g todo : List Nat) (obs : List (Nat × Slot K V)) : Prop :=
  (∀ i ∈ todo, i ∈ g) ∧ (∀ i ∈ g, i ∈ todo ∨ ∃ o, (i, o) ∈ obs) ∧
    ∀ i o, (i, o) ∈ obs → i ∈ g ∧ Stable T k i o

/-- The `some` half of `Lin`. The `none` half is not an invariant of `PReachable` runs once
group loads can shear and keys can be duplicated (see `Contract.lean`, `NInv`). -/
def LinSome (s : St K V) (k : K) (lv : Nat) (r : Option V) : Prop :=
  ∀ w, r = some w → Lin s k lv (some w)

def RInv (s : St K V) : RS K V → Prop
  | .idle => True
  | .pinned st h => st < s.clk ∧ ∀ t ∈ h, Holds s st t
  | .probing st h k t lv pre rest => st < s.clk ∧ (∀ t' ∈ h, Holds s st t') ∧ Holds s st t ∧
      View s t lv ∧ ps C (s.tables t) k = pre ++ rest ∧ Seen (s.tables t) k pre
  | .scanning st h k t lv pre g todo obs rest => st < s.clk ∧ (∀ t' ∈ h, Holds s st t') ∧
      Holds s st t ∧ View s t lv ∧ ps C (s.tables t) k = pre ++ (g ++ rest) ∧
      Seen (s.tables t) k pre ∧ ScanOK (s.tables t) k g todo obs ∧
      ∀ i w, (i, .full k w) ∈ obs → Lin s k lv (some w)
  | .returned st h k t lv r => st < s.clk ∧ (∀ t' ∈ h, Holds s st t') ∧ Holds s st t ∧
      LinSome s k lv r

structure Inv (s : St K V) : Prop where
  curLt : s.cur < s.nextId
  curLive : s.ts s.cur = .live
  liveCur : ∀ t, s.ts t = .live → t = s.cur ∨ t = 0
  fresh : ∀ t, s.nextId ≤ t → s.ts t = .unalloc
  wf : ∀ t, t < s.nextId → WF C (s.tables t)
  curHist : ∀ k w, Has (s.tables s.cur) k w ↔ s.hist s.ver k w
  ret : ∀ t v d cf, s.ts t = .retired v d cf →
    v ≤ s.ver ∧ d < s.clk ∧ ∀ k w, Has (s.tables t) k w ↔ s.hist v k w
  rd : ∀ u, RInv C s (s.rd u)
  /-- the static empty table is never retired or freed -/
  stat : s.ts 0 = .live
  /-- the static empty table is never written -/
  tab0 : s.tables 0 = emptyTable 1

/-- `T'` only fills empty buckets or turns full buckets into tombstones. -/
def Grows (T T' : Table K V) : Prop :=
  T'.n = T.n ∧ ∀ j, T.slot j ≠ .empty →
    T'.slot j ≠ .empty ∧ ∀ k w, T'.slot j = .full k w → T.slot j = .full k w

theorem grows_insertAt (T : Table K V) (i : Nat) (k : K) (v : V) (he : T.slot i = .empty) :
    Grows T (insertAt T i k v) := by
  refine ⟨rfl, fun j hj => ?_⟩
  have : (insertAt T i k v).slot j = T.slot j := by
    show (if j = i then _ else _) = _
    rw [if_neg]; rintro rfl; exact hj he
  rw [this]; exact ⟨hj, fun _ _ h => h⟩

theorem grows_insertMis (T : Table K V) (i : Nat) (k : K) (v : V) (he : T.slot i = .empty) :
    Grows T (insertMis T i k v) := by
  refine ⟨rfl, fun j hj => ?_⟩
  have : (insertMis T i k v).slot j = T.slot j := by
    show (if j = i then _ else _) = _
    rw [if_neg]; rintro rfl; exact hj he
  rw [this]; exact ⟨hj, fun _ _ h => h⟩

theorem grows_removeAt (T : Table K V) (i : Nat) (k : K) (v : V) :
    Grows T (removeAt T i k v) := by
  refine ⟨rfl, fun j hj => ?_⟩
  show (if j = i then _ else _) ≠ _ ∧ ∀ k w, (if j = i then _ else _) = _ → _
  split
  · exact ⟨by simp, fun _ _ h => by cases h⟩
  · exact ⟨hj, fun _ _ h => h⟩

theorem seen_grows {T T' : Table K V} (hg : Grows T T') {k : K} {pre : List Nat}
    (h : Seen T k pre) : Seen T' k pre := fun j hj =>
  ⟨(hg.2 j (h j hj).1).1, fun w e => (h j hj).2 w ((hg.2 j (h j hj).1).2 _ _ e)⟩

theorem stable_grows {T T' : Table K V} (hg : Grows T T') {k : K} {j : Nat} {o : Slot K V}
    (h : Stable T k j o) : Stable T' k j o := fun ho =>
  ⟨(hg.2 j (h ho).1).1, fun w e => (h ho).2 w ((hg.2 j (h ho).1).2 _ _ e)⟩

theorem scanOK_grows {T T' : Table K V} (hg : Grows T T') {k : K} {g todo : List Nat}
    {obs : List (Nat × Slot K V)} (h : ScanOK T k g todo obs) : ScanOK T' k g todo obs :=
  ⟨h.1, h.2.1, fun i o hi => ⟨(h.2.2 i o hi).1, stable_grows hg (h.2.2 i o hi).2⟩⟩

theorem scanOK_start (T : Table K V) (k : K) (g : List Nat) : ScanOK T k g g [] :=
  ⟨fun _ h => h, fun _ h => Or.inl h, fun _ _ h => by cases h⟩

/-- Loading bucket `j` of the group. -/
theorem scanOK_load {T : Table K V} {k : K} {g todo : List Nat} {obs : List (Nat × Slot K V)}
    {j : Nat} (h : ScanOK T k g todo obs) (hj : j ∈ todo) :
    ScanOK T k g (todo.erase j) (obs ++ [(j, T.slot j)]) := by
  refine ⟨fun i hi => h.1 i (List.mem_of_mem_erase hi), fun i hi => ?_, fun i o hi => ?_⟩
  · by_cases e : i = j
    · subst e; exact Or.inr ⟨T.slot i, by simp⟩
    · rcases h.2.1 i hi with h1 | ⟨o, h1⟩
      · exact Or.inl ((List.mem_erase_of_ne e).2 h1)
      · exact Or.inr ⟨o, by simp [h1]⟩
  · simp only [List.mem_append, List.mem_singleton] at hi
    rcases hi with hi | hi
    · exact h.2.2 i o hi
    · cases hi; exact ⟨h.1 _ hj, fun ho => ⟨ho, fun w e => e⟩⟩

/-- A fully loaded group with no match and no `EMPTY` byte is `Seen`. -/
theorem scanOK_seen {T : Table K V} {k : K} {g : List Nat} {obs : List (Nat × Slot K V)}
    (h : ScanOK T k g [] obs) (hm : ∀ i w, (i, .full k w) ∉ obs) (he : ∀ i, (i, .empty) ∉ obs) :
    Seen T k g := by
  intro i hi
  rcases h.2.1 i hi with h1 | ⟨o, h1⟩
  · cases h1
  · have hne : o ≠ .empty := fun e => he i (e ▸ h1)
    obtain ⟨h2, h3⟩ := (h.2.2 i o h1).2 hne
    exact ⟨h2, fun w e => hm i w (h3 w e ▸ h1)⟩

/-- `Lin` survives steps that only extend the history. -/
theorem lin_mono {s s' : St K V} (hv : s.ver ≤ s'.ver) (hh : ∀ x, x ≤ s.ver → s'.hist x = s.hist x)
    {k : K} {lv : Nat} {r : Option V} (h : Lin s k lv r) : Lin s' k lv r := by
  cases r with
  | none =>
    obtain ⟨x, h1, h2, h3⟩ := h
    exact ⟨x, h1, Nat.le_trans h2 hv, by rw [hh x h2]; exact h3⟩
  | some w =>
    obtain ⟨x, h1, h2, h3⟩ := h
    exact ⟨x, h1, Nat.le_trans h2 hv, by rw [hh x h2]; exact h3⟩

theorem linSome_mono {s s' : St K V} (hv : s.ver ≤ s'.ver)
    (hh : ∀ x, x ≤ s.ver → s'.hist x = s.hist x) {k : K} {lv : Nat} {r : Option V}
    (h : LinSome s k lv r) : LinSome s' k lv r := fun w e => lin_mono hv hh (h w e)

theorem ps_grows {T T' : Table K V} (hg : Grows T T') (k : K) : ps C T' k = ps C T k := by
  simp [ps, hg.1]

/-- A probe that has seen only non-`k` buckets and then hits `EMPTY` (or runs out) proves
`k` absent. -/
theorem absent_of_seen {T : Table K V} (hw : WF C T) {k : K} {pre rest : List Nat}
    (hps : ps C T k = pre ++ rest) (hs : Seen T k pre)
    (hr : rest = [] ∨ ∃ j r, rest = j :: r ∧ T.slot j = .empty) : ∀ w, ¬ Has T k w := by
  intro w ⟨i, hi⟩
  have hc := hw.noHole _ _ _ hi
  rw [hps] at hc
  rcases Clear.append hc with hp | hc
  · exact (hs i hp).2 w hi
  · rcases hr with rfl | ⟨j, r, rfl, he⟩
    · exact hc
    · rcases hc with rfl | ⟨hne, _⟩
      · rw [hi] at he; cases he
      · exact hne he

theorem lin_of_full {s : St K V} (h : Inv C s) {t lv j : Nat} {k : K} {w : V}
    (hv : View s t lv) (hf : (s.tables t).slot j = .full k w) : Lin s k lv (some w) := by
  rcases hv.2 with e | ⟨v', d, cf, hr, hlv⟩ | ⟨rfl, _⟩
  · subst e; exact ⟨s.ver, hv.1, Nat.le_refl _, (h.curHist k w).1 ⟨j, hf⟩⟩
  · have := h.ret t v' d cf hr
    exact ⟨v', hlv, this.1, (this.2.2 k w).1 ⟨j, hf⟩⟩
  · rw [h.tab0] at hf; cases hf

theorem lin_of_absent {s : St K V} (h : Inv C s) {t lv : Nat} {k : K}
    (hv : View s t lv) (hab : ∀ w, ¬ Has (s.tables t) k w) : Lin s k lv none := by
  rcases hv.2 with e | ⟨v, d, cf, hr, hlv⟩ | ⟨_, x, h1, h2, h3⟩
  · subst e; exact ⟨s.ver, hv.1, Nat.le_refl _, fun w hw => hab w ((h.curHist k w).2 hw)⟩
  · have := h.ret t v d cf hr
    exact ⟨v, hlv, this.1, fun w hw => hab w ((this.2.2 k w).2 hw)⟩
  · exact ⟨x, h1, h2, h3 k⟩

/-- The static empty table has no full bucket. -/
theorem static_not_has {s : St K V} (h : s.tables 0 = emptyTable 1) (k : K) (w : V) :
    ¬ Has (s.tables 0) k w := fun ⟨_, hi⟩ => by rw [h] at hi; cases hi

/-- Writer steps that change a bucket (`insert`, `remove`) never run on the static table:
it has `growth_left = 0` and no full bucket. -/
theorem cur_ne0_growth {s : St K V} (h : s.tables 0 = emptyTable 1)
    (hg : 0 < (s.tables s.cur).growthLeft) : s.cur ≠ 0 := by
  intro e; rw [e, h] at hg; simp [emptyTable, bmc] at hg

theorem cur_ne0_full {s : St K V} (h : s.tables 0 = emptyTable 1) {i : Nat} {k : K} {v : V}
    (hi : (s.tables s.cur).slot i = .full k v) : s.cur ≠ 0 := by
  intro e; rw [e, h] at hi; cases hi

theorem cur_ne0_mis {s : St K V} (h : s.tables 0 = emptyTable 1) {i : Nat} {k : K} {v : V}
    (hi : (s.tables s.cur).slot i = .mistagged k v) : s.cur ≠ 0 := by
  intro e; rw [e, h] at hi; cases hi

/-! ## Initial state -/

theorem inv_init : Inv C (init : St K V) := by
  refine ⟨by simp [init], by simp [init], ?_, ?_, ?_, ?_, ?_, ?_, by simp [init], rfl⟩
  · intro t h; simp [init] at h ⊢; exact h
  · intro t h; simp [init] at h ⊢; omega
  · intro t _; exact emptyTable_wf C 1 ⟨0, rfl⟩
  · intro k w; simp [init, Has, emptyTable]
  · intro t v d cf h; simp [init] at h; split at h <;> cases h
  · intro u; simp [init, RInv]

/-! ## Reader-only steps -/

theorem rinv_congr {s s' : St K V} (htab : s'.tables = s.tables) (hts : s'.ts = s.ts)
    (hcur : s'.cur = s.cur) (hn : s'.nextId = s.nextId) (hv : s'.ver = s.ver)
    (hh : s'.hist = s.hist) (hc : s.clk ≤ s'.clk) (r : RS K V) (h : RInv C s r) :
    RInv C s' r := by
  have hH : ∀ st t, Holds s st t → Holds s' st t := by
    intro st t h; unfold Holds; rw [hn, hts]; exact h
  cases r with
  | idle => trivial
  | pinned st hl => exact ⟨by have := h.1; omega, fun t ht => hH _ _ (h.2 t ht)⟩
  | probing st hl k t lv pre rest =>
    obtain ⟨h1, h2, h3, h4, h5, h6⟩ := h
    refine ⟨by omega, fun t ht => hH _ _ (h2 t ht), hH _ _ h3, ?_, by rw [htab]; exact h5,
      by rw [htab]; exact h6⟩
    unfold View; rw [hv, hcur, hts, hh]; exact h4
  | scanning st hl k t lv pre g todo obs rest =>
    obtain ⟨h1, h2, h3, h4, h5, h6, h7, h8⟩ := h
    refine ⟨by omega, fun t ht => hH _ _ (h2 t ht), hH _ _ h3, ?_, by rw [htab]; exact h5,
      by rw [htab]; exact h6, by rw [htab]; exact h7, fun i w hi => ?_⟩
    · unfold View; rw [hv, hcur, hts, hh]; exact h4
    · exact lin_mono (by rw [hv]; exact Nat.le_refl _) (fun x _ => by rw [hh]) (h8 i w hi)
  | returned st hl k t lv r =>
    obtain ⟨h1, h2, h3, h4⟩ := h
    exact ⟨by omega, fun t ht => hH _ _ (h2 t ht), hH _ _ h3,
      linSome_mono (by rw [hv]; exact Nat.le_refl _) (fun x _ => by rw [hh]) h4⟩

theorem inv_setRd {s : St K V} (h : Inv C s) (u : Nat) (r : RS K V) (hr : RInv C s r) :
    Inv C (setRd s u r) := by
  refine ⟨h.curLt, h.curLive, h.liveCur, h.fresh, h.wf, h.curHist, h.ret, ?_, h.stat, h.tab0⟩
  intro u'
  show RInv C (setRd s u r) (upd s.rd u r u')
  by_cases hu : u' = u
  · subst hu; rw [upd_same]
    exact rinv_congr C rfl rfl rfl rfl rfl rfl (Nat.le_refl _) _ hr
  · rw [upd_other _ _ _ _ hu]
    exact rinv_congr C rfl rfl rfl rfl rfl rfl (Nat.le_refl _) _ (h.rd u')

/-! ## Writer steps -/

theorem inv_commit {s : St K V} (h : Inv C s) (T' : Table K V) (hw : WF C T')
    (hg : Grows (s.tables s.cur) T') (h0 : s.cur ≠ 0) : Inv C (commit s T') := by
  have htab : ∀ t, t ≠ s.cur → (commit s T').tables t = s.tables t := fun t ht =>
    upd_other _ _ _ _ ht
  have hcur : (commit s T').tables s.cur = T' := upd_same _ _ _
  have hhist : ∀ x, x ≤ s.ver → (commit s T').hist x = s.hist x := fun x hx => by
    show (if x = s.ver + 1 then _ else _) = _; rw [if_neg (by omega)]
  have hH : ∀ st t, Holds s st t → Holds (commit s T') st t := fun _ _ h => h
  have hnotcur : ∀ t v d cf, s.ts t = .retired v d cf → t ≠ s.cur := by
    intro t v d cf ht e; subst e; rw [h.curLive] at ht; cases ht
  refine ⟨h.curLt, h.curLive, h.liveCur, h.fresh, ?_, ?_, ?_, ?_, h.stat,
    by rw [htab 0 (Ne.symm h0)]; exact h.tab0⟩
  · intro t ht; by_cases e : t = s.cur
    · subst e; rw [hcur]; exact hw
    · rw [htab t e]; exact h.wf t ht
  · intro k w
    have : (commit s T').hist (s.ver + 1) = Has T' := by simp [commit]
    show Has ((commit s T').tables s.cur) k w ↔ (commit s T').hist (s.ver + 1) k w
    rw [hcur, this]
  · intro t v d cf ht
    obtain ⟨h1, h2, h3⟩ := h.ret t v d cf ht
    refine ⟨Nat.le_succ_of_le h1, h2, fun k w => ?_⟩
    rw [htab t (hnotcur _ _ _ _ ht), hhist v h1]; exact h3 k w
  · intro u
    have hr := h.rd u
    show RInv C (commit s T') (s.rd u)
    cases hru : s.rd u with
    | idle => trivial
    | pinned st hl => rw [hru] at hr; exact hr
    | probing st hl k t lv pre rest =>
      rw [hru] at hr
      obtain ⟨h1, h2, h3, h4, h5, h6⟩ := hr
      refine ⟨h1, h2, h3, view_frame (Nat.le_succ _) hhist id h4, ?_, ?_⟩
      · by_cases e : t = s.cur
        · subst e; rw [hcur, ps_grows C hg]; exact h5
        · rw [htab t e]; exact h5
      · by_cases e : t = s.cur
        · subst e; rw [hcur]; exact seen_grows hg h6
        · rw [htab t e]; exact h6
    | scanning st hl k t lv pre g todo obs rest =>
      rw [hru] at hr
      obtain ⟨h1, h2, h3, h4, h5, h6, h7, h8⟩ := hr
      refine ⟨h1, h2, h3, view_frame (Nat.le_succ _) hhist id h4, ?_, ?_, ?_,
        fun i w hi => lin_mono (Nat.le_succ _) hhist (h8 i w hi)⟩
      · by_cases e : t = s.cur
        · subst e; rw [hcur, ps_grows C hg]; exact h5
        · rw [htab t e]; exact h5
      · by_cases e : t = s.cur
        · subst e; rw [hcur]; exact seen_grows hg h6
        · rw [htab t e]; exact h6
      · by_cases e : t = s.cur
        · subst e; rw [hcur]; exact scanOK_grows hg h7
        · rw [htab t e]; exact h7
    | returned st hl k t lv r =>
      rw [hru] at hr
      obtain ⟨h1, h2, h3, h4⟩ := hr
      exact ⟨h1, h2, h3, linSome_mono (Nat.le_succ _) hhist h4⟩

/-! ## The safety invariant (all runs)

`SInv` drops from `Inv` everything that depends on keys sitting on their probe sequences
(`WF.noHole`) or on the abstract map (`curHist`, `ret`'s map, `View`, `Lin`). It is preserved
by every step, including `Step.insertAny` with any key (`reachable_sinv`). -/

/-- The probe-independent part of `RInv`: pins, and the tables a reader may dereference. A
probing reader's remaining buckets are the rest of `k`'s probe sequence in `t`, so it reads
only buckets `< n` (`probe_in_bounds`). -/
def SRInv (s : St K V) : RS K V → Prop
  | .idle => True
  | .pinned st h => st < s.clk ∧ ∀ t ∈ h, Holds s st t
  | .probing st h k t _ pre rest => st < s.clk ∧ (∀ t' ∈ h, Holds s st t') ∧ Holds s st t ∧
      ps C (s.tables t) k = pre ++ rest ∧ Seen (s.tables t) k pre
  | .scanning st h k t _ pre g todo obs rest => st < s.clk ∧ (∀ t' ∈ h, Holds s st t') ∧
      Holds s st t ∧ ps C (s.tables t) k = pre ++ (g ++ rest) ∧ Seen (s.tables t) k pre ∧
      ScanOK (s.tables t) k g todo obs
  | .returned st h _ t .. => st < s.clk ∧ (∀ t' ∈ h, Holds s st t') ∧ Holds s st t

structure SInv (s : St K V) : Prop where
  curLt : s.cur < s.nextId
  curLive : s.ts s.cur = .live
  liveCur : ∀ t, s.ts t = .live → t = s.cur ∨ t = 0
  fresh : ∀ t, s.nextId ≤ t → s.ts t = .unalloc
  swf : ∀ t, t < s.nextId → SWF (s.tables t)
  ret : ∀ t v d cf, s.ts t = .retired v d cf → d < s.clk
  rd : ∀ u, SRInv C s (s.rd u)
  /-- the static empty table is never retired or freed -/
  stat : s.ts 0 = .live
  /-- the static empty table is never written -/
  tab0 : s.tables 0 = emptyTable 1

theorem RInv.srinv {s : St K V} {r : RS K V} (h : RInv C s r) : SRInv C s r := by
  cases r with
  | idle => trivial
  | pinned => exact h
  | probing => exact ⟨h.1, h.2.1, h.2.2.1, h.2.2.2.2.1, h.2.2.2.2.2⟩
  | scanning => exact ⟨h.1, h.2.1, h.2.2.1, h.2.2.2.2.1, h.2.2.2.2.2.1, h.2.2.2.2.2.2.1⟩
  | returned => exact ⟨h.1, h.2.1, h.2.2.1⟩

theorem Inv.sinv {s : St K V} (h : Inv C s) : SInv C s :=
  ⟨h.curLt, h.curLive, h.liveCur, h.fresh, fun t ht => (h.wf t ht).swf,
    fun t v d cf ht => (h.ret t v d cf ht).2.1, fun u => (h.rd u).srinv, h.stat, h.tab0⟩

theorem sinv_init : SInv C (init : St K V) := (inv_init C).sinv

theorem srinv_congr {s s' : St K V} (htab : s'.tables = s.tables) (hts : s'.ts = s.ts)
    (hn : s'.nextId = s.nextId) (hc : s.clk ≤ s'.clk) (r : RS K V) (h : SRInv C s r) :
    SRInv C s' r := by
  have hH : ∀ st t, Holds s st t → Holds s' st t := by
    intro st t h; unfold Holds; rw [hn, hts]; exact h
  cases r with
  | idle => trivial
  | pinned st hl => exact ⟨by have := h.1; omega, fun t ht => hH _ _ (h.2 t ht)⟩
  | probing st hl k t lv pre rest =>
    obtain ⟨h1, h2, h3, h5, h6⟩ := h
    exact ⟨by omega, fun t ht => hH _ _ (h2 t ht), hH _ _ h3, by rw [htab]; exact h5,
      by rw [htab]; exact h6⟩
  | scanning st hl k t lv pre g todo obs rest =>
    obtain ⟨h1, h2, h3, h5, h6, h7⟩ := h
    exact ⟨by omega, fun t ht => hH _ _ (h2 t ht), hH _ _ h3, by rw [htab]; exact h5,
      by rw [htab]; exact h6, by rw [htab]; exact h7⟩
  | returned st hl k t lv r =>
    obtain ⟨h1, h2, h3⟩ := h
    exact ⟨by omega, fun t ht => hH _ _ (h2 t ht), hH _ _ h3⟩

theorem sinv_setRd {s : St K V} (h : SInv C s) (u : Nat) (r : RS K V) (hr : SRInv C s r) :
    SInv C (setRd s u r) := by
  refine ⟨h.curLt, h.curLive, h.liveCur, h.fresh, h.swf, h.ret, ?_, h.stat, h.tab0⟩
  intro u'
  show SRInv C (setRd s u r) (upd s.rd u r u')
  by_cases hu : u' = u
  · subst hu; rw [upd_same]; exact srinv_congr C rfl rfl rfl (Nat.le_refl _) _ hr
  · rw [upd_other _ _ _ _ hu]; exact srinv_congr C rfl rfl rfl (Nat.le_refl _) _ (h.rd u')

theorem sinv_commit {s : St K V} (h : SInv C s) (T' : Table K V) (hw : SWF T')
    (hg : Grows (s.tables s.cur) T') (h0 : s.cur ≠ 0) : SInv C (commit s T') := by
  have htab : ∀ t, t ≠ s.cur → (commit s T').tables t = s.tables t := fun t ht =>
    upd_other _ _ _ _ ht
  have hcur : (commit s T').tables s.cur = T' := upd_same _ _ _
  refine ⟨h.curLt, h.curLive, h.liveCur, h.fresh, ?_, h.ret, ?_, h.stat,
    by rw [htab 0 (Ne.symm h0)]; exact h.tab0⟩
  · intro t ht; by_cases e : t = s.cur
    · subst e; rw [hcur]; exact hw
    · rw [htab t e]; exact h.swf t ht
  · intro u
    have hr := h.rd u
    show SRInv C (commit s T') (s.rd u)
    cases hru : s.rd u with
    | idle => trivial
    | pinned st hl => rw [hru] at hr; exact hr
    | probing st hl k t lv pre rest =>
      rw [hru] at hr
      obtain ⟨h1, h2, h3, h5, h6⟩ := hr
      refine ⟨h1, h2, h3, ?_, ?_⟩
      · by_cases e : t = s.cur
        · subst e; rw [hcur, ps_grows C hg]; exact h5
        · rw [htab t e]; exact h5
      · by_cases e : t = s.cur
        · subst e; rw [hcur]; exact seen_grows hg h6
        · rw [htab t e]; exact h6
    | scanning st hl k t lv pre g todo obs rest =>
      rw [hru] at hr
      obtain ⟨h1, h2, h3, h5, h6, h7⟩ := hr
      refine ⟨h1, h2, h3, ?_, ?_, ?_⟩
      · by_cases e : t = s.cur
        · subst e; rw [hcur, ps_grows C hg]; exact h5
        · rw [htab t e]; exact h5
      · by_cases e : t = s.cur
        · subst e; rw [hcur]; exact seen_grows hg h6
        · rw [htab t e]; exact h6
      · by_cases e : t = s.cur
        · subst e; rw [hcur]; exact scanOK_grows hg h7
        · rw [htab t e]; exact h7
    | returned st hl k t lv r => rw [hru] at hr; exact hr

/-- A table a reader may dereference is not freed. -/
theorem Holds.nf {s : St K V} {st t : Nat} (h : Holds s st t) : s.ts t ≠ .freed := by
  intro h'; rcases h.2 with e | ⟨v, d, e, _⟩ <;> rw [e] at h' <;> cases h'

/-- A pinned reader keeps every table it may dereference across `replace_table`: the old
`current` is retired after the reader's pin started (or stays live if it is the static table). -/
theorem holds_publish {s : St K V} {t : Nat} {T' : Table K V} {nx : Nat} {ch : Bool}
    (hp : PubOK s t T' nx) {st u : Nat} (hst : st < s.clk) (h : Holds s st u) :
    Holds (publish s t T' nx ch) st u := by
  obtain ⟨h1, h2⟩ := h
  refine ⟨Nat.lt_of_lt_of_le h1 hp.nx_ge, ?_⟩
  rw [publish_ts]; split
  · exact .inl rfl
  · unfold retire; split
    · exact .inr ⟨_, _, rfl, Nat.le_of_lt hst⟩
    · exact h2

theorem sinv_publish {s : St K V} (h : SInv C s) {t : Nat} {T' : Table K V} {nx : Nat} (ch : Bool)
    (hp : PubOK s t T' nx) (hw : SWF T') : SInv C (publish s t T' nx ch) := by
  have htab : ∀ u, u < s.nextId → s.ts u ≠ .freed → (publish s t T' nx ch).tables u = s.tables u :=
    fun u hu hf => publish_tables_lt ch hp hu hf
  have hnx := hp.nx_ge
  have htnx : t < nx := by
    rcases hp with ⟨rfl, rfl⟩ | ⟨rfl, rfl, _⟩ | ⟨ht, rfl⟩
    · omega
    · have := h.curLt; omega
    · exact Nat.lt_of_not_le fun hle => by rw [h.fresh _ hle] at ht; cases ht
  have hc := clk_le_tick s
  have hH : ∀ st u, st < s.clk → Holds s st u → Holds (publish s t T' nx ch) st u :=
    fun st u hst hh => holds_publish hp hst hh
  refine ⟨htnx, by show (publish s t T' nx ch).ts t = _; rw [publish_ts, if_pos rfl], ?_, ?_, ?_,
    ?_, ?_, ?_, ?_⟩
  · intro u hu; rw [publish_ts] at hu
    split at hu
    · exact .inl (by assumption)
    · unfold retire at hu; split at hu
      · cases hu
      · rename_i hne
        rcases h.liveCur u hu with e | e
        · exact .inr (Classical.byContradiction fun h0 => hne ⟨e, by rw [← e]; exact h0⟩)
        · exact .inr e
  · intro u hu
    have := h.curLt
    have hu' : nx ≤ u := hu
    rw [publish_ts, if_neg (by omega), retire_of_ne (by omega)]
    exact h.fresh u (by omega)
  · intro u hu
    by_cases e : u = t
    · subst e; show SWF (upd s.tables u T' u); rw [upd_same]; exact hw
    · have : u < s.nextId := by
        rcases hp with ⟨rfl, rfl⟩ | ⟨rfl, rfl, rfl⟩ | ⟨_, rfl⟩
        · have : u < s.nextId + 1 := hu; omega
        · exact hu
        · exact hu
      show SWF (upd s.tables t T' u); rw [upd_other _ _ _ _ e]; exact h.swf u this
  · intro u v d cf hu
    show d < tick s
    rw [publish_ts] at hu
    split at hu
    · cases hu
    · unfold retire at hu; split at hu
      · rename_i e; cases hu; rw [tick_ne0 e.2]; omega
      · have := h.ret u v d cf hu; omega
  · intro u
    have hr := h.rd u
    show SRInv C (publish s t T' nx ch) (s.rd u)
    cases hru : s.rd u with
    | idle => trivial
    | pinned st hl =>
      rw [hru] at hr
      exact ⟨Nat.lt_of_lt_of_le hr.1 hc, fun t ht => hH _ _ hr.1 (hr.2 t ht)⟩
    | probing st hl k t lv pre rest =>
      rw [hru] at hr
      obtain ⟨h1, h2, h3, h5, h6⟩ := hr
      exact ⟨Nat.lt_of_lt_of_le h1 hc, fun t ht => hH _ _ h1 (h2 t ht), hH _ _ h1 h3,
        by rw [htab t h3.1 h3.nf]; exact h5, by rw [htab t h3.1 h3.nf]; exact h6⟩
    | scanning st hl k t lv pre g todo obs rest =>
      rw [hru] at hr
      obtain ⟨h1, h2, h3, h5, h6, h7⟩ := hr
      exact ⟨Nat.lt_of_lt_of_le h1 hc, fun t ht => hH _ _ h1 (h2 t ht), hH _ _ h1 h3,
        by rw [htab t h3.1 h3.nf]; exact h5, by rw [htab t h3.1 h3.nf]; exact h6,
        by rw [htab t h3.1 h3.nf]; exact h7⟩
    | returned st hl k t lv r =>
      rw [hru] at hr
      obtain ⟨h1, h2, h3⟩ := hr
      exact ⟨Nat.lt_of_lt_of_le h1 hc, fun t ht => hH _ _ h1 (h2 t ht), hH _ _ h1 h3⟩
  · rw [publish_ts]; split
    · rfl
    · rw [retire_of_ne (fun ⟨e, h0⟩ => h0 e.symm)]; exact h.stat
  · rcases hp with ⟨rfl, rfl⟩ | ⟨rfl, rfl, rfl⟩ | ⟨ht, rfl⟩
    · show upd s.tables s.nextId T' 0 = _
      rw [upd_other _ _ _ _ (by have := h.curLt; omega)]; exact h.tab0
    · show upd s.tables 0 (s.tables 0) 0 = _; rw [upd_same]; exact h.tab0
    · show upd s.tables t T' 0 = _
      rw [upd_other _ _ _ _ (fun e => by rw [← e, h.stat] at ht; cases ht)]; exact h.tab0

/-- `SInv` is preserved by every step, `Step.insertAny` with any key included. -/
theorem sinv_step (hcov : C.Cover) {s s' : St K V} (h : SInv C s) (hs : Step C s s') :
    SInv C s' := by
  cases hs with
  | insert k v i hg hfe =>
    obtain ⟨he, pre, rest, hl, _⟩ := firstEmpty_spec hfe
    have hin : i < (s.tables s.cur).n := C.seq_lt _ _ _ (by unfold ps at hl; rw [hl]; simp)
    exact sinv_commit C h _ (insertAt_swf (h.swf _ h.curLt) hg he hin)
      (grows_insertAt _ _ _ _ he) (cur_ne0_growth h.tab0 hg)
  | insertAny k v i hg he hin =>
    exact sinv_commit C h _ (insertAt_swf (h.swf _ h.curLt) hg he hin)
      (grows_insertAt _ _ _ _ he) (cur_ne0_growth h.tab0 hg)
  | remove k v i hi =>
    exact sinv_commit C h _ (removeAt_swf (h.swf _ h.curLt) hi) (grows_removeAt _ _ _ _)
      (cur_ne0_full h.tab0 hi)
  | insertMis k v i hg he hin =>
    exact sinv_commit C h _ (insertMis_swf (h.swf _ h.curLt) hg he hin)
      (grows_insertMis _ _ _ _ he) (cur_ne0_growth h.tab0 hg)
  | removeMis k v i hi =>
    exact sinv_commit C h _ (removeAt_swf_mis (h.swf _ h.curLt) hi) (grows_removeAt _ _ _ _)
      (cur_ne0_mis h.tab0 hi)
  | expand m hm hlen =>
    exact sinv_publish C h false (swap_pub _ _) (build_wf C hcov m hm _ hlen).1.swf
  | replace m l hm hlen =>
    exact sinv_publish C h true (swap_pub _ _) (build_wf C hcov m hm l hlen).1.swf
  | expandAt m a ha hm hlen =>
    exact sinv_publish C h false (swapAt_pub _ ha) (build_wf C hcov m hm _ hlen).1.swf
  | replaceAt m a l ha hm hlen =>
    exact sinv_publish C h true (swapAt_pub _ ha) (build_wf C hcov m hm l hlen).1.swf
  | replaceEmpty => exact sinv_publish C h true (swapEmpty_pub s) (h.swf 0 (by have := h.curLt; omega))
  | prune t v d ht =>
    have hne : t ≠ s.cur := by intro e; subst e; rw [h.curLive] at ht; cases ht
    have hts : ∀ t', ({ s with ts := upd s.ts t .freed } : St K V).ts t' =
        if t' = t then .freed else s.ts t' := fun _ => rfl
    have hH : ∀ st t', Holds s st t' → Holds { s with ts := upd s.ts t .freed } st t' := by
      intro st t' ⟨h1, h2⟩; refine ⟨h1, ?_⟩; rw [hts]
      split
      · rename_i e; subst e
        rcases h2 with h2 | ⟨_, _, h2, _⟩ <;> rw [ht] at h2 <;> cases h2
      · exact h2
    have h0 : t ≠ 0 := by rintro rfl; rw [h.stat] at ht; cases ht
    refine ⟨h.curLt, by rw [hts, if_neg (Ne.symm hne)]; exact h.curLive, ?_, ?_, h.swf, ?_, ?_,
      by rw [hts, if_neg (Ne.symm h0)]; exact h.stat, h.tab0⟩
    · intro t' h'; rw [hts] at h'; split at h'
      · cases h'
      · exact h.liveCur t' h'
    · intro t' h'; rw [hts]; split
      · rename_i e; subst e; have := h.fresh t' h'; rw [ht] at this; cases this
      · exact h.fresh t' h'
    · intro t' v' d' cf h'; rw [hts] at h'; split at h'
      · cases h'
      · exact h.ret t' v' d' cf h'
    · intro u
      have hr := h.rd u
      show SRInv C _ (s.rd u)
      cases hru : s.rd u with
      | idle => trivial
      | pinned st hl => rw [hru] at hr; exact ⟨hr.1, fun t ht => hH _ _ (hr.2 t ht)⟩
      | probing st hl k t' lv pre rest =>
        rw [hru] at hr
        obtain ⟨h1, h2, h3, h5, h6⟩ := hr
        exact ⟨h1, fun t ht => hH _ _ (h2 t ht), hH _ _ h3, h5, h6⟩
      | scanning st hl k t' lv pre g todo obs rest =>
        rw [hru] at hr
        obtain ⟨h1, h2, h3, h5, h6, h7⟩ := hr
        exact ⟨h1, fun t ht => hH _ _ (h2 t ht), hH _ _ h3, h5, h6, h7⟩
      | returned st hl k t' lv r =>
        rw [hru] at hr
        exact ⟨hr.1, fun t ht => hH _ _ (hr.2.1 t ht), hH _ _ hr.2.2⟩
  | markFree t v d ht hno =>
    have hne : t ≠ s.cur := by intro e; subst e; rw [h.curLive] at ht; cases ht
    have hts : ∀ t', ({ s with ts := upd s.ts t (.retired v d true) } : St K V).ts t' =
        if t' = t then .retired v d true else s.ts t' := fun _ => rfl
    have hH : ∀ u st t', (s.rd u).start = some st → Holds s st t' →
        Holds { s with ts := upd s.ts t (.retired v d true) } st t' := by
      intro u st t' hst ⟨h1, h2⟩; refine ⟨h1, ?_⟩; rw [hts]
      split
      · rename_i e; subst e
        rcases h2 with h2 | ⟨v', d', h2, h3⟩
        · rw [ht] at h2; cases h2
        · rw [ht] at h2; cases h2; have := hno u st hst; omega
      · exact h2
    have h0 : t ≠ 0 := by rintro rfl; rw [h.stat] at ht; cases ht
    refine ⟨h.curLt, by rw [hts, if_neg (Ne.symm hne)]; exact h.curLive, ?_, ?_, h.swf, ?_, ?_,
      by rw [hts, if_neg (Ne.symm h0)]; exact h.stat, h.tab0⟩
    · intro t' h'; rw [hts] at h'; split at h'
      · cases h'
      · exact h.liveCur t' h'
    · intro t' h'; rw [hts]; split
      · rename_i e; subst e; have := h.fresh t' h'; rw [ht] at this; cases this
      · exact h.fresh t' h'
    · intro t' v' d' cf h'; rw [hts] at h'; split at h'
      · rename_i e; subst e; cases h'; exact h.ret _ _ _ _ ht
      · exact h.ret t' v' d' cf h'
    · intro u
      have hr := h.rd u
      show SRInv C _ (s.rd u)
      cases hru : s.rd u with
      | idle => trivial
      | pinned st hl =>
        rw [hru] at hr
        exact ⟨hr.1, fun t ht => hH u _ _ (by rw [hru]; rfl) (hr.2 t ht)⟩
      | probing st hl k t' lv pre rest =>
        rw [hru] at hr
        have hst : (s.rd u).start = some st := by rw [hru]; rfl
        obtain ⟨h1, h2, h3, h5, h6⟩ := hr
        exact ⟨h1, fun t ht => hH u _ _ hst (h2 t ht), hH u _ _ hst h3, h5, h6⟩
      | scanning st hl k t' lv pre g todo obs rest =>
        rw [hru] at hr
        have hst : (s.rd u).start = some st := by rw [hru]; rfl
        obtain ⟨h1, h2, h3, h5, h6, h7⟩ := hr
        exact ⟨h1, fun t ht => hH u _ _ hst (h2 t ht), hH u _ _ hst h3, h5, h6, h7⟩
      | returned st hl k t' lv r =>
        rw [hru] at hr
        have hst : (s.rd u).start = some st := by rw [hru]; rfl
        exact ⟨hr.1, fun t ht => hH u _ _ hst (hr.2.1 t ht), hH u _ _ hst hr.2.2⟩
  | pin u hu =>
    refine ⟨h.curLt, h.curLive, h.liveCur, h.fresh, h.swf, ?_, ?_, h.stat, h.tab0⟩
    · intro t v d cf ht; have := h.ret t v d cf ht; show d < s.clk + 1; omega
    · intro u'
      show SRInv C _ (upd s.rd u _ u')
      by_cases e : u' = u
      · subst e; rw [upd_same]; exact ⟨Nat.lt_succ_self _, fun _ h => by cases h⟩
      · rw [upd_other _ _ _ _ e]
        exact srinv_congr C (s := s) (s' := { setRd s u (.pinned s.clk []) with clk := s.clk + 1 })
          rfl rfl rfl (Nat.le_succ _) _ (h.rd u')
  | unpin u st hl hu => exact sinv_setRd C h u _ trivial
  | load u st hl k hu =>
    apply sinv_setRd C h
    have hr := h.rd u; rw [hu] at hr
    exact ⟨hr.1, hr.2, ⟨h.curLt, Or.inl h.curLive⟩, by simp, fun _ h => by cases h⟩
  | probeGroup u st hl k t lv pre g rest hu _ =>
    apply sinv_setRd C h
    have hr := h.rd u; rw [hu] at hr
    obtain ⟨h1, h2, h3, h5, h6⟩ := hr
    exact ⟨h1, h2, h3, h5, h6, scanOK_start _ _ _⟩
  | scanLoad u st hl k t lv pre g todo obs rest j hu hj =>
    apply sinv_setRd C h
    have hr := h.rd u; rw [hu] at hr
    obtain ⟨h1, h2, h3, h5, h6, h7⟩ := hr
    exact ⟨h1, h2, h3, h5, h6, scanOK_load h7 hj⟩
  | scanHit u st hl k t lv pre g obs rest j v hu _ =>
    apply sinv_setRd C h
    have hr := h.rd u; rw [hu] at hr
    exact ⟨hr.1, hr.2.1, hr.2.2.1⟩
  | scanEmpty u st hl k t lv pre g obs rest j hu _ _ =>
    apply sinv_setRd C h
    have hr := h.rd u; rw [hu] at hr
    exact ⟨hr.1, hr.2.1, hr.2.2.1⟩
  | scanNext u st hl k t lv pre g obs rest hu hm he =>
    apply sinv_setRd C h
    have hr := h.rd u; rw [hu] at hr
    obtain ⟨h1, h2, h3, h5, h6, h7⟩ := hr
    refine ⟨h1, h2, h3, by rw [h5]; simp, fun i hi => ?_⟩
    simp only [List.mem_append] at hi
    rcases hi with hi | hi
    · exact h6 i hi
    · exact scanOK_seen h7 hm he i hi
  | probeEnd u st hl k t lv pre hu =>
    apply sinv_setRd C h
    have hr := h.rd u; rw [hu] at hr
    exact ⟨hr.1, hr.2.1, hr.2.2.1⟩
  | finish u st hl k t lv r hu =>
    apply sinv_setRd C h
    have hr := h.rd u; rw [hu] at hr
    refine ⟨hr.1, fun t' ht => ?_⟩
    simp at ht; rcases ht with rfl | ht
    · exact hr.2.2
    · exact hr.2.1 t' ht

/-- **The safety invariant holds on every run**, including runs in which `PotentialSlot::insert_new`
is called with a key other than the one `get_potential` was called with (`Step.insertAny`). -/
theorem reachable_sinv (hcov : C.Cover) {s : St K V} (h : Reachable C s) : SInv C s := by
  induction h with
  | init => exact sinv_init C
  | step _ hs ih => exact sinv_step C hcov ih hs

/-- **Memory safety of probing**: every bucket a reader can load next (`Step.scanLoad`, also
the bucket `eq` then reads on a match) is in bounds. -/
theorem probe_in_bounds (hcov : C.Cover) {s : St K V} (h : Reachable C s) {u st : Nat}
    {hl : List Nat} {k : K} {t lv : Nat} {pre g todo rest : List Nat}
    {obs : List (Nat × Slot K V)} {j : Nat}
    (hu : s.rd u = .scanning st hl k t lv pre g todo obs rest) (hj : j ∈ todo) :
    j < (s.tables t).n := by
  have hr := (reachable_sinv C hcov h).rd u; rw [hu] at hr
  have hg := hr.2.2.2.2.2.1 j hj
  exact C.seq_lt _ _ _ (by have := hr.2.2.2.1; unfold ps at this; rw [this]; simp [hg])

/-! ## The full invariant -/

/-- `View` across `replace_table`: the old `current` is retired at version `ver` (or, if it is the
static table and stays unchanged in place, still shows the empty map at `ver`). -/
theorem view_publish {s : St K V} (h : Inv C s) {t : Nat} {T' : Table K V} {nx : Nat} {ch : Bool}
    (hp : PubOK s t T' nx) {u lv : Nat} (hlt : u < s.nextId) (hnf : s.ts u ≠ .freed)
    (hv : View s u lv) : View (publish s t T' nx ch) u lv := by
  have hver : s.ver ≤ (publish s t T' nx ch).ver := by cases ch <;> simp [publish]
  have hhist : ∀ x, x ≤ s.ver → (publish s t T' nx ch).hist x = s.hist x := fun x hx => by
    cases ch <;> simp [publish]; intro; omega
  have hne : ∀ u, u < s.nextId → s.ts u ≠ .freed → u ≠ 0 → u ≠ t := by
    intro u hu hf h0 e; subst e; rcases hp with ⟨e, _⟩ | ⟨e, _⟩ | ⟨e, _⟩
    · omega
    · exact h0 e
    · exact hf e
  refine ⟨Nat.le_trans hv.1 hver, ?_⟩
  rcases hv.2 with e | ⟨v, d, cf, hr, hlv⟩ | ⟨h0, x, h1, h2, h3⟩
  · subst e
    by_cases hc0 : s.cur = 0
    · by_cases et : s.cur = t
      · exact .inl et
      · refine .inr (.inr ⟨hc0, s.ver, hv.1, hver, fun k w hw => ?_⟩)
        rw [hhist _ (Nat.le_refl _)] at hw
        rw [← h.curHist, hc0] at hw; exact static_not_has h.tab0 k w hw
    · refine .inr (.inl ⟨s.ver, s.clk, false, ?_, hv.1⟩)
      rw [publish_ts, if_neg (hne _ h.curLt (by rw [h.curLive]; simp) hc0)]; exact if_pos ⟨rfl, hc0⟩
  · have h0 : u ≠ 0 := by rintro rfl; rw [h.stat] at hr; cases hr
    have hc : u ≠ s.cur := by rintro rfl; rw [h.curLive] at hr; cases hr
    refine .inr (.inl ⟨v, d, cf, ?_, hlv⟩)
    rw [publish_ts, if_neg (hne _ hlt hnf h0), retire_of_ne (fun ⟨e, _⟩ => hc e)]; exact hr
  · exact .inr (.inr ⟨h0, x, h1, Nat.le_trans h2 hver, by rw [hhist x h2]; exact h3⟩)

theorem inv_publish {s : St K V} (h : Inv C s) {t : Nat} {T' : Table K V} {nx : Nat} (ch : Bool)
    (hp : PubOK s t T' nx) (hw : WF C T')
    (hsame : ch = false → ∀ k w, Has T' k w ↔ Has (s.tables s.cur) k w) :
    Inv C (publish s t T' nx ch) := by
  have hS := sinv_publish C h.sinv ch hp hw.swf
  have htab : ∀ u, u < s.nextId → s.ts u ≠ .freed → (publish s t T' nx ch).tables u = s.tables u :=
    fun u hu hf => publish_tables_lt ch hp hu hf
  have hver : s.ver ≤ (publish s t T' nx ch).ver := by cases ch <;> simp [publish]
  have hhist : ∀ x, x ≤ s.ver → (publish s t T' nx ch).hist x = s.hist x := fun x hx => by
    cases ch <;> simp [publish]; intro; omega
  have hlt : ∀ u, s.ts u ≠ .unalloc → u < s.nextId := fun u hu =>
    Nat.lt_of_not_le (fun hle => hu (h.fresh u hle))
  have hH : ∀ st u, st < s.clk → Holds s st u → Holds (publish s t T' nx ch) st u :=
    fun st u hst hh => holds_publish hp hst hh
  refine ⟨hS.curLt, hS.curLive, hS.liveCur, hS.fresh, ?_, ?_, ?_, ?_, hS.stat, hS.tab0⟩
  · intro u hu
    by_cases e : u = t
    · subst e; show WF C (upd s.tables u T' u); rw [upd_same]; exact hw
    · have : u < s.nextId := by
        rcases hp with ⟨rfl, rfl⟩ | ⟨rfl, rfl, rfl⟩ | ⟨_, rfl⟩
        · have : u < s.nextId + 1 := hu; omega
        · exact hu
        · exact hu
      show WF C (upd s.tables t T' u); rw [upd_other _ _ _ _ e]; exact h.wf u this
  · intro k w
    show Has (upd s.tables t T' t) k w ↔ (publish s t T' nx ch).hist (publish s t T' nx ch).ver k w
    rw [upd_same]
    cases ch with
    | true => simp [publish]
    | false => show _ ↔ s.hist s.ver k w; rw [hsame rfl]; exact h.curHist k w
  · intro u v d cf hu
    rw [publish_ts] at hu
    split at hu
    · cases hu
    · unfold retire at hu
      split at hu
      · rename_i e; obtain ⟨rfl, hc0⟩ := e; cases hu
        refine ⟨hver, by show s.clk < tick s; rw [tick_ne0 hc0]; omega, fun k w => ?_⟩
        rw [htab _ h.curLt (by rw [h.curLive]; simp), hhist _ (Nat.le_refl _)]; exact h.curHist k w
      · obtain ⟨h1, h2, h3⟩ := h.ret u v d cf hu
        refine ⟨Nat.le_trans h1 hver, Nat.lt_of_lt_of_le h2 (clk_le_tick s), fun k w => ?_⟩
        rw [htab u (hlt u (by rw [hu]; simp)) (by rw [hu]; simp), hhist v h1]; exact h3 k w
  · intro u
    have hr := h.rd u
    have hc := clk_le_tick s
    show RInv C (publish s t T' nx ch) (s.rd u)
    cases hru : s.rd u with
    | idle => trivial
    | pinned st hl =>
      rw [hru] at hr
      exact ⟨Nat.lt_of_lt_of_le hr.1 hc, fun t ht => hH _ _ hr.1 (hr.2 t ht)⟩
    | probing st hl k t lv pre rest =>
      rw [hru] at hr
      obtain ⟨h1, h2, h3, h4, h5, h6⟩ := hr
      exact ⟨Nat.lt_of_lt_of_le h1 hc, fun t ht => hH _ _ h1 (h2 t ht), hH _ _ h1 h3,
        view_publish C h hp h3.1 h3.nf h4, by rw [htab t h3.1 h3.nf]; exact h5,
        by rw [htab t h3.1 h3.nf]; exact h6⟩
    | scanning st hl k t lv pre g todo obs rest =>
      rw [hru] at hr
      obtain ⟨h1, h2, h3, h4, h5, h6, h7, h8⟩ := hr
      exact ⟨Nat.lt_of_lt_of_le h1 hc, fun t ht => hH _ _ h1 (h2 t ht), hH _ _ h1 h3,
        view_publish C h hp h3.1 h3.nf h4, by rw [htab t h3.1 h3.nf]; exact h5,
        by rw [htab t h3.1 h3.nf]; exact h6, by rw [htab t h3.1 h3.nf]; exact h7, fun i w hi => lin_mono hver hhist (h8 i w hi)⟩
    | returned st hl k t lv r =>
      rw [hru] at hr
      obtain ⟨h1, h2, h3, h4⟩ := hr
      exact ⟨Nat.lt_of_lt_of_le h1 hc, fun t ht => hH _ _ h1 (h2 t ht), hH _ _ h1 h3,
        linSome_mono hver hhist h4⟩

/-! ## The invariant is inductive -/

/-- `Inv` is preserved by every step that respects the probe contract. The premise `hp` is used
only for `Step.insertAny`, where it says the bucket is the one `find_insert_slot` picks. -/
theorem inv_step (hcov : C.Cover) {s s' : St K V} (h : Inv C s) (hs : Step C s s')
    (hp : ProbeOK C s s') : Inv C s' := by
  cases hs with
  | insert k v i hg hfe =>
    have hw := h.wf _ h.curLt
    exact inv_commit C h _ (insertAt_wf C hw hg hfe).1
      (grows_insertAt _ _ _ _ (firstEmpty_spec hfe).1) (cur_ne0_growth h.tab0 hg)
  | insertMis k v i _ he _ => exact absurd rfl (hp.2 i k v he)
  | removeMis k v i hi => exact absurd hi ((h.wf _ h.curLt).noMis _ _ _)
  | insertAny k v i hg he _ =>
    have hfe := hp.1 i k v he rfl
    have hw := h.wf _ h.curLt
    exact inv_commit C h _ (insertAt_wf C hw hg hfe).1 (grows_insertAt _ _ _ _ he)
      (cur_ne0_growth h.tab0 hg)
  | remove k v i hi =>
    have hw := h.wf _ h.curLt
    exact inv_commit C h _ (removeAt_wf C hw hi).1 (grows_removeAt _ _ _ _)
      (cur_ne0_full h.tab0 hi)
  | expand m hm hlen =>
    have hw := h.wf _ h.curLt
    have hb := build_wf C hcov m hm _ hlen
    exact inv_publish C h false (swap_pub _ _) hb.1 (fun _ k w => by rw [hb.2, mem_items C hw])
  | replace m l hm hlen =>
    exact inv_publish C h true (swap_pub _ _) (build_wf C hcov m hm l hlen).1 (fun e => by cases e)
  | expandAt m a ha hm hlen =>
    have hw := h.wf _ h.curLt
    have hb := build_wf C hcov m hm _ hlen
    exact inv_publish C h false (swapAt_pub _ ha) hb.1 (fun _ k w => by rw [hb.2, mem_items C hw])
  | replaceAt m a l ha hm hlen =>
    exact inv_publish C h true (swapAt_pub _ ha) (build_wf C hcov m hm l hlen).1 (fun e => by cases e)
  | replaceEmpty =>
    exact inv_publish C h true (swapEmpty_pub s) (h.wf 0 (by have := h.curLt; omega))
      (fun e => by cases e)
  | prune t v d ht =>
    have hne : t ≠ s.cur := by intro e; subst e; rw [h.curLive] at ht; cases ht
    have hts : ∀ t', ({ s with ts := upd s.ts t .freed } : St K V).ts t' =
        if t' = t then .freed else s.ts t' := fun _ => rfl
    have hH : ∀ st t', Holds s st t' → Holds { s with ts := upd s.ts t .freed } st t' := by
      intro st t' ⟨h1, h2⟩; refine ⟨h1, ?_⟩; rw [hts]
      split
      · rename_i e; subst e
        rcases h2 with h2 | ⟨_, _, h2, _⟩ <;> rw [ht] at h2 <;> cases h2
      · exact h2
    have h0 : t ≠ 0 := by rintro rfl; rw [h.stat] at ht; cases ht
    refine ⟨h.curLt, by rw [hts, if_neg (Ne.symm hne)]; exact h.curLive, ?_, ?_, h.wf,
      h.curHist, ?_, ?_, by rw [hts, if_neg (Ne.symm h0)]; exact h.stat, h.tab0⟩
    · intro t' h'; rw [hts] at h'; split at h'
      · cases h'
      · exact h.liveCur t' h'
    · intro t' h'; rw [hts]; split
      · rename_i e; subst e; have := h.fresh t' h'; rw [ht] at this; cases this
      · exact h.fresh t' h'
    · intro t' v' d' cf h'; rw [hts] at h'; split at h'
      · cases h'
      · exact h.ret t' v' d' cf h'
    · intro u
      have hr := h.rd u
      show RInv C _ (s.rd u)
      cases hru : s.rd u with
      | idle => trivial
      | pinned st hl => rw [hru] at hr; exact ⟨hr.1, fun t ht => hH _ _ (hr.2 t ht)⟩
      | probing st hl k t' lv pre rest =>
        rw [hru] at hr
        obtain ⟨h1, h2, h3, h4, h5, h6⟩ := hr
        refine ⟨h1, fun t ht => hH _ _ (h2 t ht), hH _ _ h3,
          view_frame (s := s) (Nat.le_refl _) (fun _ _ => rfl) (fun hc => ?_) h4, h5, h6⟩
        rcases hc with e | ⟨v', d', cf, hv, hlv⟩
        · exact Or.inl e
        · right; refine ⟨v', d', cf, ?_, hlv⟩; rw [hts, if_neg]; exact hv
          rintro rfl
          rcases h3.2 with h3 | ⟨_, _, h3, _⟩ <;> rw [ht] at h3 <;> cases h3
      | scanning st hl k t' lv pre g todo obs rest =>
        rw [hru] at hr
        obtain ⟨h1, h2, h3, h4, h5, h6, h7, h8⟩ := hr
        refine ⟨h1, fun t ht => hH _ _ (h2 t ht), hH _ _ h3,
          view_frame (s := s) (Nat.le_refl _) (fun _ _ => rfl) (fun hc => ?_) h4, h5, h6, h7, h8⟩
        rcases hc with e | ⟨v', d', cf, hv, hlv⟩
        · exact Or.inl e
        · right; refine ⟨v', d', cf, ?_, hlv⟩; rw [hts, if_neg]; exact hv
          rintro rfl
          rcases h3.2 with h3 | ⟨_, _, h3, _⟩ <;> rw [ht] at h3 <;> cases h3
      | returned st hl k t' lv r =>
        rw [hru] at hr
        exact ⟨hr.1, fun t ht => hH _ _ (hr.2.1 t ht), hH _ _ hr.2.2.1, hr.2.2.2⟩
  | markFree t v d ht hno =>
    have hne : t ≠ s.cur := by intro e; subst e; rw [h.curLive] at ht; cases ht
    have hts : ∀ t', ({ s with ts := upd s.ts t (.retired v d true) } : St K V).ts t' =
        if t' = t then .retired v d true else s.ts t' := fun _ => rfl
    have hH : ∀ u st t', (s.rd u).start = some st → Holds s st t' →
        Holds { s with ts := upd s.ts t (.retired v d true) } st t' := by
      intro u st t' hst ⟨h1, h2⟩; refine ⟨h1, ?_⟩; rw [hts]
      split
      · rename_i e; subst e
        rcases h2 with h2 | ⟨v', d', h2, h3⟩
        · rw [ht] at h2; cases h2
        · rw [ht] at h2; cases h2; have := hno u st hst; omega
      · exact h2
    have h0 : t ≠ 0 := by rintro rfl; rw [h.stat] at ht; cases ht
    refine ⟨h.curLt, by rw [hts, if_neg (Ne.symm hne)]; exact h.curLive, ?_, ?_, h.wf,
      h.curHist, ?_, ?_, by rw [hts, if_neg (Ne.symm h0)]; exact h.stat, h.tab0⟩
    · intro t' h'; rw [hts] at h'; split at h'
      · cases h'
      · exact h.liveCur t' h'
    · intro t' h'; rw [hts]; split
      · rename_i e; subst e; have := h.fresh t' h'; rw [ht] at this; cases this
      · exact h.fresh t' h'
    · intro t' v' d' cf h'; rw [hts] at h'; split at h'
      · rename_i e; subst e; cases h'; exact h.ret _ _ _ _ ht
      · exact h.ret t' v' d' cf h'
    · intro u
      have hr := h.rd u
      show RInv C _ (s.rd u)
      cases hru : s.rd u with
      | idle => trivial
      | pinned st hl =>
        rw [hru] at hr
        exact ⟨hr.1, fun t ht => hH u _ _ (by rw [hru]; rfl) (hr.2 t ht)⟩
      | probing st hl k t' lv pre rest =>
        rw [hru] at hr
        have hst : (s.rd u).start = some st := by rw [hru]; rfl
        obtain ⟨h1, h2, h3, h4, h5, h6⟩ := hr
        refine ⟨h1, fun t ht => hH u _ _ hst (h2 t ht), hH u _ _ hst h3,
          view_frame (s := s) (Nat.le_refl _) (fun _ _ => rfl) (fun hc => ?_) h4, h5, h6⟩
        rcases hc with e | ⟨v', d', cf, hv, hlv⟩
        · exact Or.inl e
        · right; rw [hts]; split
          · rename_i e; subst e; rw [ht] at hv; cases hv; exact ⟨_, _, true, rfl, hlv⟩
          · exact ⟨v', d', cf, hv, hlv⟩
      | scanning st hl k t' lv pre g todo obs rest =>
        rw [hru] at hr
        have hst : (s.rd u).start = some st := by rw [hru]; rfl
        obtain ⟨h1, h2, h3, h4, h5, h6, h7, h8⟩ := hr
        refine ⟨h1, fun t ht => hH u _ _ hst (h2 t ht), hH u _ _ hst h3,
          view_frame (s := s) (Nat.le_refl _) (fun _ _ => rfl) (fun hc => ?_) h4, h5, h6, h7, h8⟩
        rcases hc with e | ⟨v', d', cf, hv, hlv⟩
        · exact Or.inl e
        · right; rw [hts]; split
          · rename_i e; subst e; rw [ht] at hv; cases hv; exact ⟨_, _, true, rfl, hlv⟩
          · exact ⟨v', d', cf, hv, hlv⟩
      | returned st hl k t' lv r =>
        rw [hru] at hr
        have hst : (s.rd u).start = some st := by rw [hru]; rfl
        exact ⟨hr.1, fun t ht => hH u _ _ hst (hr.2.1 t ht), hH u _ _ hst hr.2.2.1, hr.2.2.2⟩
  | pin u hu =>
    refine ⟨h.curLt, h.curLive, h.liveCur, h.fresh, h.wf, h.curHist, ?_, ?_, h.stat, h.tab0⟩
    · intro t v d cf ht; have := h.ret t v d cf ht; exact ⟨this.1, by simp; omega, this.2.2⟩
    · intro u'
      show RInv C _ (upd s.rd u _ u')
      by_cases e : u' = u
      · subst e; rw [upd_same]; exact ⟨Nat.lt_succ_self _, fun _ h => by cases h⟩
      · rw [upd_other _ _ _ _ e]
        exact rinv_congr C (s := s) (s' := { setRd s u (.pinned s.clk []) with clk := s.clk + 1 })
          rfl rfl rfl rfl rfl rfl (Nat.le_succ _) _ (h.rd u')
  | unpin u st hl hu => exact inv_setRd C h u _ trivial
  | load u st hl k hu =>
    apply inv_setRd C h
    have hr := h.rd u; rw [hu] at hr
    exact ⟨hr.1, hr.2, ⟨h.curLt, Or.inl h.curLive⟩, ⟨Nat.le_refl _, Or.inl rfl⟩, by simp,
      fun _ h => by cases h⟩
  | probeGroup u st hl k t lv pre g rest hu _ =>
    apply inv_setRd C h
    have hr := h.rd u; rw [hu] at hr
    obtain ⟨h1, h2, h3, h4, h5, h6⟩ := hr
    exact ⟨h1, h2, h3, h4, h5, h6, scanOK_start _ _ _, fun _ _ h => by cases h⟩
  | scanLoad u st hl k t lv pre g todo obs rest j hu hj =>
    apply inv_setRd C h
    have hr := h.rd u; rw [hu] at hr
    obtain ⟨h1, h2, h3, h4, h5, h6, h7, h8⟩ := hr
    refine ⟨h1, h2, h3, h4, h5, h6, scanOK_load h7 hj, fun i w hi => ?_⟩
    simp only [List.mem_append, List.mem_singleton] at hi
    rcases hi with hi | hi
    · exact h8 i w hi
    · simp only [Prod.mk.injEq] at hi; obtain ⟨rfl, e⟩ := hi; exact lin_of_full C h h4 e.symm
  | scanHit u st hl k t lv pre g obs rest j v hu hj =>
    apply inv_setRd C h
    have hr := h.rd u; rw [hu] at hr
    obtain ⟨h1, h2, h3, h4, h5, h6, h7, h8⟩ := hr
    exact ⟨h1, h2, h3, fun w e => by cases e; exact h8 j v hj⟩
  | scanEmpty u st hl k t lv pre g obs rest j hu _ _ =>
    apply inv_setRd C h
    have hr := h.rd u; rw [hu] at hr
    exact ⟨hr.1, hr.2.1, hr.2.2.1, fun w e => by cases e⟩
  | scanNext u st hl k t lv pre g obs rest hu hm he =>
    apply inv_setRd C h
    have hr := h.rd u; rw [hu] at hr
    obtain ⟨h1, h2, h3, h4, h5, h6, h7, h8⟩ := hr
    refine ⟨h1, h2, h3, h4, by rw [h5]; simp, fun i hi => ?_⟩
    simp only [List.mem_append] at hi
    rcases hi with hi | hi
    · exact h6 i hi
    · exact scanOK_seen h7 hm he i hi
  | probeEnd u st hl k t lv pre hu =>
    apply inv_setRd C h
    have hr := h.rd u; rw [hu] at hr
    exact ⟨hr.1, hr.2.1, hr.2.2.1, fun w e => by cases e⟩
  | finish u st hl k t lv r hu =>
    apply inv_setRd C h
    have hr := h.rd u; rw [hu] at hr
    refine ⟨hr.1, fun t' ht => ?_⟩
    simp at ht; rcases ht with rfl | ht
    · exact hr.2.2.1
    · exact hr.2.1 t' ht

/-- **The full invariant on probe-respecting runs.** `Inv` (with `WF.noHole`, `curHist` and the
reader linearizability state) holds when every step respects the probe contract (`PReachable`).
It does not hold on all of `Reachable`: `Step.insertAny` can put a key behind an `EMPTY` bucket
of its probe sequence, breaking `noHole`. -/
theorem preachable_inv (hcov : C.Cover) {s : St K V} (h : PReachable C s) : Inv C s := by
  induction h with
  | init => exact inv_init C
  | step _ hs hp ih => exact inv_step C hcov ih hs hp

/-! ## The probe contract -/

theorem commit_insertAt_inj {s : St K V} {i i' : Nat} {k k' : K} {v v' : V}
    (he : (s.tables s.cur).slot i = .empty)
    (e : commit s (insertAt (s.tables s.cur) i k v) = commit s (insertAt (s.tables s.cur) i' k' v')) :
    i = i' ∧ k = k' := by
  have e1 := congrArg (fun s' : St K V => (s'.tables s.cur).slot i) e
  simp only [commit, upd_same] at e1
  revert e1
  show ((if i = i then Slot.full k v else _) = (if i = i' then Slot.full k' v' else _)) → _
  rw [if_pos rfl]; split
  · rename_i h; intro e2; cases e2; exact ⟨h, rfl⟩
  · rw [he]; intro e2; cases e2

/-- A step whose current table has no new `mistagged` bucket writes none. -/
theorem noMis_of_slot {s s' : St K V}
    (h : ∀ i k v, (s.tables s.cur).slot i = .empty → (s'.tables s.cur).slot i ≠ .mistagged k v) :
    ∀ i k v, (s.tables s.cur).slot i = .empty → s' ≠ commit s (insertMis (s.tables s.cur) i k v) := by
  intro i k v he e; apply h i k v he; rw [e]; simp [commit, insertMis, Table.set]

/-- Steps that do not change the writer version (readers, `collect`, `prune`, `expand`) respect
the probe contract. -/
theorem probeOK_of_ver {s s' : St K V} (hv : s'.ver = s.ver) : ProbeOK C s s' := by
  refine ⟨fun i k v _ e => ?_, fun i k v _ e => ?_⟩ <;>
    (have := congrArg St.ver e; simp [commit] at this; omega)

/-- `Step.insert` respects the probe contract. -/
theorem probeOK_insert {s : St K V} {k : K} {v : V} {i : Nat}
    (hfe : firstEmpty (s.tables s.cur) (ps C (s.tables s.cur) k) = some i) :
    ProbeOK C s (commit s (insertAt (s.tables s.cur) i k v)) := by
  refine ⟨fun i' k' v' he e => ?_, noMis_of_slot fun j k' v' he => ?_⟩
  · obtain ⟨rfl, rfl⟩ := commit_insertAt_inj he e.symm; exact hfe
  · simp only [commit, upd_same, insertAt, Table.set]; split <;> simp_all

/-- `Step.insertAny` respects the probe contract exactly when its bucket is the one
`find_insert_slot` picks for its key. -/
theorem probeOK_insertAny_iff {s : St K V} {k : K} {v : V} {i : Nat}
    (he : (s.tables s.cur).slot i = .empty) :
    ProbeOK C s (commit s (insertAt (s.tables s.cur) i k v)) ↔
      firstEmpty (s.tables s.cur) (ps C (s.tables s.cur) k) = some i :=
  ⟨fun h => h.1 i k v he rfl, fun h => probeOK_insert C h⟩

/-- `remove` respects the probe contract. -/
theorem probeOK_remove (s : St K V) (k : K) (v : V) (i : Nat) :
    ProbeOK C s (commit s (removeAt (s.tables s.cur) i k v)) := by
  refine ⟨fun j k' v' he e => ?_, noMis_of_slot fun j k' v' he => ?_⟩
  · have e1 := congrArg (fun s : St K V => (s.tables s.cur).slot j) e
    simp only [commit, upd_same] at e1
    exfalso
    revert e1
    show ((if j = i then Slot.deleted k v else _) = (if j = j then Slot.full k' v' else _)) → False
    split
    · simp
    · rw [he]; simp
  · simp only [commit, upd_same, removeAt, Table.set]; split <;> simp_all

/-- `replace_table` (`expand`, `replace`, `replaceEmpty`) respects the probe contract. -/
theorem probeOK_publish (s : St K V) {t : Nat} {T' : Table K V} {nx : Nat} (ch : Bool)
    (hp : PubOK s t T' nx) : ProbeOK C s (publish s t T' nx ch) := by
  refine ⟨fun i k v he e => ?_, fun i k v he e => ?_⟩ <;>
  rcases hp with ⟨rfl, rfl⟩ | ⟨rfl, rfl, rfl⟩ | ⟨ht, rfl⟩
  all_goals first
    | (exfalso
       have := congrFun (congrArg St.ts e) t
       simp [commit, publish, upd, ht] at this; done)
    | (have := congrArg St.nextId e; simp [commit, publish] at this; done)
    | (exfalso
       have hc : (0 : Nat) = s.cur := congrArg St.cur e
       have e1 := congrArg (fun s' : St K V => (s'.tables s'.cur).slot i) e
       simp only [commit, publish, upd_same] at e1
       rw [← hc] at he
       rw [he] at e1
       simp [insertAt, insertMis, Table.set] at e1)

theorem probeOK_swap (s : St K V) (T' : Table K V) (ch : Bool) : ProbeOK C s (swap s T' ch) :=
  probeOK_publish C s ch (swap_pub _ _)

/-- **Only `Step.insertAny` and `Step.insertMis` can break the probe contract**: every step
respects it, or it writes some key `k` into an `EMPTY` bucket `i` that is not `k`'s
`find_insert_slot` bucket, or it writes a `mistagged` bucket. -/
theorem step_probeOK {s s' : St K V} (hs : Step C s s') :
    ProbeOK C s s' ∨ (∃ k v i, (s.tables s.cur).slot i = .empty ∧
      s' = commit s (insertAt (s.tables s.cur) i k v) ∧
      firstEmpty (s.tables s.cur) (ps C (s.tables s.cur) k) ≠ some i) ∨
    ∃ k v i, (s.tables s.cur).slot i = .empty ∧ s' = commit s (insertMis (s.tables s.cur) i k v) := by
  cases hs with
  | insert k v i _ hfe => exact Or.inl (probeOK_insert C hfe)
  | insertAny k v i _ he _ =>
    by_cases hf : firstEmpty (s.tables s.cur) (ps C (s.tables s.cur) k) = some i
    · exact Or.inl (probeOK_insert C hf)
    · exact Or.inr (Or.inl ⟨k, v, i, he, rfl, hf⟩)
  | insertMis k v i _ he _ => exact Or.inr (Or.inr ⟨k, v, i, he, rfl⟩)
  | remove k v i _ => exact Or.inl (probeOK_remove C s k v i)
  | removeMis k v i _ => exact Or.inl (probeOK_remove C s k v i)
  | expand => exact Or.inl (probeOK_swap C _ _ _)
  | replace => exact Or.inl (probeOK_swap C _ _ _)
  | expandAt m a ha => exact Or.inl (probeOK_publish C _ _ (swapAt_pub _ ha))
  | replaceAt m a l ha => exact Or.inl (probeOK_publish C _ _ (swapAt_pub _ ha))
  | replaceEmpty => exact Or.inl (probeOK_publish C _ true (swapEmpty_pub _))
  | _ => exact Or.inl (probeOK_of_ver C rfl)

end SyncTable
