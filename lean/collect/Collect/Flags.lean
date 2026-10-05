import Collect.Model

/-!
# `defer_by_id` flag memory

`defer_by_id(ready: *const AtomicBool)` registers a raw pointer; `mark_ready` (inside the
collector lock in `collect_cold`) later stores `true` through it, unless `cancel_by_ids` removed
it first. Rust's safety contract on the caller:

> The caller must ensure `ready` remains valid until it is set to `true` by the collector or the
> store is cancelled using `cancel_by_ids`.

and `Collector::defer_by_id`/`Callbacks::push_id` `debug_assert!` that the pointer is not already
in `pending`, `previous_deferred` or `current_deferred`.

This file models the flag memory and that contract.

* A `defer_by_id` registration is a `Cb` with `byId = true` in `pending ++ previous ++ current`
  (`fl`); its id is the pointer (`regIds`). The *window* of a registration is the time it is in
  `regIds`.
* The `true` stores a step performs (`mark_ready`) are the `byId` callbacks it appends to the
  ghost `ran` (`stores`, from `startCollect`); `FStep.col` writes them to the flag values.
* `stores_window` (unconditional, every reachable state): every store consumes a registration:
  the stored ids together with the ids still registered afterwards are a sub-multiset of the ids
  registered before. So `collect` writes only to registered pointers (`store_registered`), and
  `cancel_by_ids` closes the window (`cancel_unregisters`).
* `assertFires_iff`: the three `debug_assert!`s at `defer_by_id(i)` fire exactly when `i` is
  already registered.
* The flag heap `FSt.heap : Nat → Cell` (`unalloc`/`live`/`freed`) and the client steps
  `FStep.alloc`/`free`/`deferId`. The client obligation is stated as the premises of those
  steps (`FStep.deferId`: the flag is live and not registered; `FStep.free`: the flag is not
  registered, i.e. it was already stored or cancelled). Every `collect` step is available as
  `FStep.col` (`step_cover`).
* Under the obligation (`FReach`): registrations are never duplicated and always live
  (`freach_inv`), so `collect` never writes a flag that is not live, writes each at most once,
  and the write closes the window (`no_write_after_free`); the `debug_assert!`s never fire
  (`assert_never_fires`).* Flag values `FSt.val`: `false` at allocation (`FStep.alloc`; Rust initialises the
  `AtomicBool` when the client allocates it, before `defer_by_id`), `true` through every pointer
  in `stores` (`FStep.col`, `mark_ready`'s `store(true, Release)`). `flag_true_iff`: a live flag is
  `true` iff some registration of it since its allocation (`born`) is in `ran`;
  `only_collect_writes_true`: only a `collect` store turns a live flag `true`.
* Other owners' writes: `FStep.envWrite` writes any values into memory that is not a live flag
  (never allocated, freed, or reallocated by someone who does not use it as a `defer_by_id`
  flag), so `FReach` runs over the real memory contents, including new owners' writes to reused
  memory. The value invariant (`VInv`, `flag_true_iff`) is about live flags only.
-/

namespace Collect
namespace Flags

/-- All queued callbacks: `pending`, `previous_deferred`, `current_deferred`. -/
def flat (s : St) : List Cb := s.pending ++ s.previous ++ s.current
/-- The queued `defer_by_id` registrations. -/
def fl (s : St) : List Cb := (flat s).filter (fun c => c.byId)
/-- The pointers of the `defer_by_id` entries of a `Callbacks::defer_by_id` vector. -/
def ids (l : List Cb) : List Nat := (l.filter (fun c => c.byId)).map (fun c => c.id)
/-- The registered pointers (a multiset). -/
def regIds (s : St) : List Nat := ids (flat s)
/-- The `byId` callbacks a step appends to `ran`, i.e. stored `true` by `mark_ready`. -/
def newRan (s s' : St) : List Cb := (s'.ran.drop s.ran.length).filter (fun c => c.byId)
/-- The pointers a step stores `true` through. -/
def stores (s s' : St) : List Nat := (newRan s s').map (fun c => c.id)
/-- `Collector::defer_by_id(i)` (`Step.defer s i true`). -/
def deferIdSt (s : St) (i : Nat) : St :=
  { s with now := s.now + 1, current := s.current ++ [⟨i, s.now, true⟩] }

/-- The `debug_assert!`s of a `defer_by_id(i)` call: `!pending.defer_by_id.contains(&i)` and
`!previous_deferred.defer_by_id.contains(&i)` in `Collector::defer_by_id`, and
`!self.defer_by_id.contains(&i)` in `current_deferred.push_id`. `true` = one of them fires. -/
def assertFires (s : St) (i : Nat) : Bool :=
  (ids s.pending).contains i || (ids s.previous).contains i || (ids s.current).contains i

theorem regIds_eq (s : St) : regIds s = (fl s).map (fun c => c.id) := rfl

/-- **The `debug_assert!`s fire exactly when the pointer is already registered.** -/
theorem assertFires_iff (s : St) (i : Nat) : assertFires s i = true ↔ i ∈ regIds s := by
  simp [assertFires, regIds, ids, flat, List.filter_append, or_assoc]

/-! ## Collector steps and registrations -/

/-- No callback still to run in a `Collecting` thread is a `defer_by_id` flag (`collect_cold`
stores those inside the lock and only runs the closures). -/
def TodoOk (loc : Tid → LS) : Prop := ∀ t w l, loc t = .collecting w l → ∀ c ∈ l, c.byId = false

theorem todoOk_upd {loc : Tid → LS} (ht : TodoOk loc) (t : Tid) {v : LS}
    (hv : ∀ w l, v = .collecting w l → ∀ c ∈ l, c.byId = false) : TodoOk (upd loc t v) := by
  intro u w l h
  by_cases e : u = t
  · subst e; simp only [upd_same] at h; exact hv w l h
  · simp only [upd_other _ _ _ _ e] at h; exact ht u w l h

/-- Effect of a locked `Collector` call that hands callbacks `r.2` out of the queues. -/
def Hands (s : St) (r : St × List Cb) : Prop :=
  (r.2 ++ flat r.1).Perm (flat s) ∧ r.1.ran = s.ran ∧ r.1.loc = s.loc ∧ r.1.now = s.now

/-- Effect of a locked call that keeps all callbacks queued. -/
def Keeps (s s' : St) : Prop :=
  (flat s').Perm (flat s) ∧ s'.ran = s.ran ∧ s'.loc = s.loc ∧ s'.now = s.now

theorem completeEpoch_keeps (s : St) : Keeps s (completeEpoch s) := by
  unfold completeEpoch; split <;> simp [Keeps, flat]

theorem markQuiet_keeps (t : Tid) (s : St) : Keeps s (markQuiet t s) := by
  unfold markQuiet; split
  · exact completeEpoch_keeps _
  · exact ⟨List.Perm.refl _, rfl, rfl, rfl⟩

theorem takePending_hands (s : St) : Hands s (takePending s) := by
  simp [Hands, takePending, flat]

theorem quiet_hands (t : Tid) : ∀ fuel (s : St), Hands s (quiet t fuel s)
  | 0, s => by simp [Hands, quiet]
  | fuel + 1, s => by
    obtain ⟨m1, m2, m3, m4⟩ := markQuiet_keeps t s
    obtain ⟨p1, p2, p3, p4⟩ := takePending_hands (markQuiet t s)
    obtain ⟨q1, q2, q3, q4⟩ := quiet_hands t fuel (takePending (markQuiet t s)).1
    simp only [quiet]
    split
    · exact takePending_hands s
    · split
      · refine ⟨?_, by rw [q2, p2, m2], by rw [q3, p3, m3], by rw [q4, p4, m4]⟩
        rw [List.append_assoc]
        exact ((q1.append_left _).trans p1).trans m1
      · exact ⟨p1.trans m1, p2.trans m2, p3.trans m3, p4.trans m4⟩

theorem collectUnreg_hands (s : St) : Hands s (collectUnreg s) := by
  unfold collectUnreg; split <;> simp [Hands, flat]

theorem unregister_keeps (s : St) (t : Tid) : Keeps s (unregister s t) := by
  unfold unregister; dsimp only
  split
  · split
    · exact completeEpoch_keeps _
    · exact ⟨List.Perm.refl _, rfl, rfl, rfl⟩
  · split
    · exact completeEpoch_keeps _
    · exact ⟨List.Perm.refl _, rfl, rfl, rfl⟩

/-- `A` is a sub-multiset of `B`. -/
def SubP (A B : List Cb) : Prop := ∃ l, A.Perm l ∧ l.Sublist B

theorem newRan_of {s s' : St} {w : List Cb} (h : s'.ran = s.ran ++ w) :
    newRan s s' = w.filter (fun c => c.byId) := by
  simp [newRan, h]

theorem subP_keeps {s s' : St} (hf : (flat s').Perm (flat s)) (hr : s'.ran = s.ran) :
    SubP (newRan s s' ++ fl s') (fl s) := by
  refine ⟨fl s, ?_, List.Sublist.refl _⟩
  rw [newRan_of (w := []) (by simp [hr])]
  simpa [fl] using hf.filter _

/-- One collector step: its effect on the registrations and on `ran`. A step either is a
`defer_by_id`, or it only removes registrations, each stored one being removed. -/
theorem step_flags {s s' : St} (hs : Step s s') (ht : TodoOk s.loc) :
    TodoOk s'.loc ∧ (∃ w, s'.ran = s.ran ++ w) ∧ s.now ≤ s'.now ∧
    ((∃ i, s' = deferIdSt s i) ∨ SubP (newRan s s' ++ fl s') (fl s)) := by
  have hloc : ∀ {v : LS} t, (∀ st d, v ≠ .collecting st d) → TodoOk (upd s.loc t v) :=
    fun t hv => todoOk_upd ht t (fun w l h => absurd h (hv w l))
  have kp : ∀ {s'' : St}, flat s'' = flat s → s''.ran = s.ran → SubP (newRan s s'' ++ fl s'') (fl s) :=
    fun hf hr => subP_keeps (by rw [hf]) hr
  have sc : ∀ t w (r : St × List Cb), Hands s r →
      TodoOk (startCollect t w r).loc ∧ (∃ w', (startCollect t w r).ran = s.ran ++ w') ∧
      s.now ≤ (startCollect t w r).now ∧
      SubP (newRan s (startCollect t w r) ++ fl (startCollect t w r)) (fl s) := by
    intro t w r ⟨h1, h2, h3, h4⟩
    refine ⟨?_, ⟨r.2.filter (fun c => c.byId), by simp [startCollect, h2]⟩, by simp [startCollect, h4], fl s, ?_, .refl _⟩
    · simp only [startCollect, h3]
      refine todoOk_upd ht t ?_
      intro w' l h c hc; cases h; simpa using (List.mem_filter.1 hc).2
    · rw [newRan_of (w := r.2.filter (fun c => c.byId)) (by simp [startCollect, h2])]
      have := h1.filter (fun c => c.byId)
      rw [show fl (startCollect t w r) = (flat r.1).filter (fun c => c.byId) from rfl,
        show fl s = (flat s).filter (fun c => c.byId) from rfl]
      simpa [List.filter_append, List.filter_filter] using this
  cases hs with
  | pinRegister t h =>
    simp only [register]
    exact ⟨hloc t (by intros; simp), ⟨[], by simp⟩, by simp, .inr (kp rfl rfl)⟩
  | pinOuter t h => exact ⟨hloc t (by intros; simp), ⟨[], by simp⟩, by simp, .inr (kp rfl rfl)⟩
  | pinNest t st d h => exact ⟨hloc t (by intros; simp), ⟨[], by simp⟩, Nat.le_refl _, .inr (kp rfl rfl)⟩
  | unpinNest t st d h => exact ⟨hloc t (by intros; simp), ⟨[], by simp⟩, Nat.le_refl _, .inr (kp rfl rfl)⟩
  | unpinOuter t st h => exact ⟨hloc t (by intros; simp), ⟨[], by simp⟩, Nat.le_refl _, .inr (kp rfl rfl)⟩
  | release t h =>
    obtain ⟨k1, k2, k3, k4⟩ := unregister_keeps { s with loc := upd s.loc t .unregistered } t
    refine ⟨?_, ⟨[], by simp [k2]⟩, by simp [k4], .inr (subP_keeps k1 k2)⟩
    rw [k3]; exact hloc t (by intros; simp)
  | defer id b =>
    cases b with
    | true => exact ⟨ht, ⟨[], by simp⟩, by simp, .inl ⟨id, rfl⟩⟩
    | false =>
      refine ⟨ht, ⟨[], by simp⟩, by simp, .inr ⟨fl s, ?_, .refl _⟩⟩
      rw [newRan_of (w := []) (by simp)]
      simp [fl, flat, List.filter_append]
  | cancel ids =>
    refine ⟨ht, ⟨[], by simp⟩, Nat.le_refl _, .inr ⟨_, List.Perm.refl _, ?_⟩⟩
    rw [newRan_of (w := []) (by simp)]
    have : flat { s with pending := cancelList ids s.pending, current := cancelList ids s.current,
                         previous := cancelList ids s.previous } =
        (flat s).filter (fun c => !(c.byId && ids.contains c.id)) := by
      simp [flat, cancelList, List.filter_append]
    simp only [fl, this]
    exact (List.filter_sublist).filter _
  | collectReg t h =>
    obtain ⟨a, b, c, d⟩ := sc t true _ (quietRust_eq t s ▸ quiet_hands t 2 s); exact ⟨a, b, c, .inr d⟩
  | collectUnreg t h =>
    obtain ⟨a, b, c, d⟩ := sc t false _ (collectUnreg_hands s); exact ⟨a, b, c, .inr d⟩
  | runOne t w c cs h =>
    have hc : c.byId = false := ht t w _ h c (by simp)
    refine ⟨todoOk_upd ht t ?_, ⟨[c], rfl⟩, Nat.le_refl _, .inr ⟨fl s, ?_, .refl _⟩⟩
    · intro w' l e x hx; cases e; exact ht t w _ h x (by simp [hx])
    · rw [newRan_of (w := [c]) rfl]; simp [hc, fl, flat]
  | finish t w h =>
    exact ⟨hloc t (by intros; split <;> simp), ⟨[], by simp⟩, Nat.le_refl _, .inr (kp rfl rfl)⟩

/-! ## Reachable states: registrations and stores are never duplicated as callbacks -/

/-- `ran`'s stored flags. -/
def ranB (s : St) : List Cb := s.ran.filter (fun c => c.byId)

/-- Every `defer_by_id` callback (queued or stored) is unique and older than `now`. -/
def CbInv (s : St) : Prop :=
  TodoOk s.loc ∧ (fl s ++ ranB s).Nodup ∧ ∀ c ∈ fl s ++ ranB s, c.time < s.now

theorem cbInv_init : CbInv init := by
  refine ⟨?_, by simp [fl, ranB, flat, init], by simp [fl, ranB, flat, init]⟩
  intro t w l h; simp [init] at h

theorem cbInv_step {s s' : St} (h : CbInv s) (hs : Step s s') : CbInv s' := by
  obtain ⟨ht, hn, htime⟩ := h
  obtain ⟨t', ⟨w, hw⟩, hnow, hc⟩ := step_flags hs ht
  refine ⟨t', ?_⟩
  rcases hc with ⟨i, rfl⟩ | ⟨l, hp, hsub⟩
  · have hx : (⟨i, s.now, true⟩ : Cb) ∉ fl s ++ ranB s := fun hm => by
      have := htime _ hm; simp at this
    have hp : (fl (deferIdSt s i) ++ ranB (deferIdSt s i)).Perm (⟨i, s.now, true⟩ :: (fl s ++ ranB s)) := by
      simp only [fl, ranB, flat, deferIdSt, List.filter_append, List.append_assoc]
      simp only [List.filter_cons, ↓reduceIte, List.filter_nil, List.nil_append, List.cons_append]
      have key : ∀ (A B C R : List Cb) x,
          (A ++ (B ++ (C ++ x :: R))).Perm (x :: (A ++ (B ++ (C ++ R)))) := by
        intros A B C R x
        simpa [List.append_assoc] using (List.perm_middle (l₁ := A ++ B ++ C) (l₂ := R) (a := x))
      exact key _ _ _ _ _
    refine ⟨hp.nodup_iff.2 (List.nodup_cons.2 ⟨hx, hn⟩), fun c hc => ?_⟩
    rcases List.mem_cons.1 (hp.mem_iff.1 hc) with e | e
    · subst e; simp [deferIdSt]
    · have := htime c e; simp [deferIdSt]; omega
  · have hr : ranB s' = ranB s ++ newRan s s' := by
      simp [ranB, newRan_of hw, hw, List.filter_append]
    have hp' : (fl s' ++ ranB s').Perm (l ++ ranB s) := by
      rw [hr, ← List.append_assoc]
      have := (List.perm_append_comm (l₁ := fl s' ++ ranB s) (l₂ := newRan s s'))
      rw [← List.append_assoc] at this
      exact this.trans (hp.append_right _)
    have hsub' : (l ++ ranB s).Sublist (fl s ++ ranB s) := hsub.append (.refl _)
    refine ⟨hp'.nodup_iff.2 (hsub'.nodup hn), fun c hc => ?_⟩
    have := htime c (hsub'.subset (hp'.mem_iff.1 hc)); omega

theorem reachable_cbInv {s : St} (h : Reachable s) : CbInv s := by
  induction h with
  | init => exact cbInv_init
  | step _ hs ih => exact cbInv_step ih hs

/-- A queued flag callback has not been stored yet. -/
theorem fl_not_ran {s : St} (h : Reachable s) {c : Cb} (hc : c ∈ fl s) : c ∉ ranB s := by
  have hn := (reachable_cbInv h).2.1
  exact fun hr => (List.nodup_append.1 hn).2.2 c hc c hr rfl

/-- The queued flag callbacks are distinct. -/
theorem fl_nodup {s : St} (h : Reachable s) : (fl s).Nodup :=
  (List.nodup_append.1 (reachable_cbInv h).2.1).1

/-- **Collect writes only inside the window.** Unconditionally (whatever the clients do), a step
is either `defer_by_id(i)` (adding one registration, storing nothing) or every pointer it stores
`true` through consumes one registration: `stores ++ regIds s'` is a sub-multiset of `regIds s`.
-/
theorem stores_window {s s' : St} (h : Reachable s) (hs : Step s s') :
    (∃ i, s' = deferIdSt s i ∧ stores s s' = [] ∧ regIds s' = regIds s ++ [i]) ∨
    ∃ l, (stores s s' ++ regIds s').Perm l ∧ l.Sublist (regIds s) := by
  obtain ⟨_, _, _, hc⟩ := step_flags hs (reachable_cbInv h).1
  rcases hc with ⟨i, rfl⟩ | ⟨l, hp, hsub⟩
  · refine .inl ⟨i, rfl, ?_, ?_⟩
    · simp [stores, newRan, deferIdSt]
    · simp [regIds, ids, flat, deferIdSt, List.filter_append]
  · refine .inr ⟨l.map (fun c => c.id), ?_, hsub.map _⟩
    have := hp.map (fun c => c.id)
    simpa [stores, regIds_eq] using this

theorem store_registered {s s' : St} (h : Reachable s) (hs : Step s s') {i : Nat}
    (hi : i ∈ stores s s') : i ∈ regIds s := by
  rcases stores_window h hs with ⟨_, _, e, _⟩ | ⟨l, hp, hsub⟩
  · simp [e] at hi
  · exact hsub.subset (hp.mem_iff.1 (List.mem_append_left _ hi))

/-- After `cancel_by_ids(ids)` no id of `ids` is registered, so `collect` never stores to it
again (until it is registered anew). -/
theorem cancel_unregisters (s : St) (ids' : List Nat) {i : Nat} (hi : i ∈ ids') :
    i ∉ regIds { s with pending := cancelList ids' s.pending, current := cancelList ids' s.current,
                        previous := cancelList ids' s.previous } := by
  simp [regIds, ids, flat, cancelList, List.filter_append]
  refine ⟨?_, ?_, ?_⟩ <;> intro c _ hb he e <;> subst e <;> simp_all

/-- Every collector step is a `defer_by_id` or adds no registration. -/
theorem step_cover {s s' : St} (h : Reachable s) (hs : Step s s') :
    (∃ i, s' = deferIdSt s i) ∨ ∀ x ∈ fl s', x ∈ fl s := by
  obtain ⟨_, _, _, hc⟩ := step_flags hs (reachable_cbInv h).1
  rcases hc with e | ⟨l, hp, hsub⟩
  · exact .inl e
  · exact .inr fun x hx => hsub.subset (hp.mem_iff.1 (List.mem_append_right _ hx))

/-! ## The flag heap and the client obligation -/

/-- A flag's memory: never allocated, valid, or deallocated. -/
inductive Cell where
  | unalloc
  | live
  | freed
  deriving DecidableEq, Repr

/-- The flag values after the `true` stores to the pointers `l`. -/
def storeAll (val : Nat → Bool) (l : List Nat) : Nat → Bool := fun i => val i || l.contains i

/-- `collect` state plus the flag memory. -/
structure FSt where
  c : St
  heap : Nat → Cell
  /-- the flags' values (the `AtomicBool`s) -/
  val : Nat → Bool
  /-- ghost: `collect` time (`St.now`) at the flag's latest allocation -/
  born : Nat → Nat

/-- Steps of `collect` together with its `defer_by_id` clients. **The client obligation is the
premises of `deferId` and `free`:**
* `defer_by_id(i)` only on a live flag that is not registered (not registered twice
  concurrently);
* a registered flag is not freed: freeing requires the flag not to be registered, i.e. the
  collector has stored it (`stores` removes it) or `cancel_by_ids` removed it.

Allocation hands out any non-live cell (addresses may be reused after `freed`) and initialises
the flag to `false` (`AtomicBool::new(false)`; `SyncTable`/`SyncPushVec` do this when the table
is allocated, before `defer_by_id`). The only step that writes `true` is a `collect` step
(`col`), through each pointer in `stores` (`mark_ready`'s `store(true, Release)`). -/
inductive FStep : FSt → FSt → Prop
  /-- any `collect` step other than `defer_by_id` (it registers nothing) -/
  | col {c c' : St} (heap : Nat → Cell) (val : Nat → Bool) (born : Nat → Nat) : Step c c' →
      (∀ x ∈ fl c', x ∈ fl c) →
      FStep ⟨c, heap, val, born⟩ ⟨c', heap, storeAll val (stores c c'), born⟩
  /-- `defer_by_id(i)` under the obligation -/
  | deferId (c : St) (heap : Nat → Cell) (val : Nat → Bool) (born : Nat → Nat) (i : Nat) :
      heap i = .live → i ∉ regIds c →
      FStep ⟨c, heap, val, born⟩ ⟨deferIdSt c i, heap, val, born⟩
  | alloc (c : St) (heap : Nat → Cell) (val : Nat → Bool) (born : Nat → Nat) (i : Nat) :
      heap i ≠ .live →
      FStep ⟨c, heap, val, born⟩ ⟨c, upd heap i .live, upd val i false, upd born i c.now⟩
  /-- deallocating a flag, under the obligation -/
  | free (c : St) (heap : Nat → Cell) (val : Nat → Bool) (born : Nat → Nat) (i : Nat) :
      heap i = .live → i ∉ regIds c →
      FStep ⟨c, heap, val, born⟩ ⟨c, upd heap i .freed, val, born⟩
  /-- writes by other owners: any memory that is not a live flag (never allocated, freed, or
  reallocated by someone else, who does not use it as a `defer_by_id` flag) may be written with
  any value, any number of cells at once -/
  | envWrite (c : St) (heap : Nat → Cell) (val val' : Nat → Bool) (born : Nat → Nat) :
      (∀ i, heap i = .live → val' i = val i) →
      FStep ⟨c, heap, val, born⟩ ⟨c, heap, val', born⟩

inductive FReach : FSt → Prop
  | init (heap : Nat → Cell) : FReach ⟨init, heap, fun _ => false, fun _ => 0⟩
  | step {f f'} : FReach f → FStep f f' → FReach f'

theorem freach_reachable {f : FSt} (h : FReach f) : Reachable f.c := by
  induction h with
  | init => exact .init
  | step _ hs ih =>
    cases hs with
    | col _ _ _ h _ => exact .step ih h
    | deferId c heap _ _ i => exact .step ih (Step.defer c i true)
    | alloc => exact ih
    | free => exact ih
    | envWrite => exact ih

/-- Under the obligation: registrations are distinct pointers, and every registered flag is
live. -/
def FInv (f : FSt) : Prop := (regIds f.c).Nodup ∧ ∀ i ∈ regIds f.c, f.heap i = .live

theorem freach_inv {f : FSt} (h : FReach f) : FInv f := by
  induction h with
  | init => exact ⟨by simp [regIds, ids, flat, init], by simp [regIds, ids, flat, init]⟩
  | @step f f' hr hs ih =>
    obtain ⟨hn, hl⟩ := ih
    have hreach := freach_reachable hr
    cases hs with
    | @col c c' heap _ _ hst hno =>
      rcases stores_window hreach hst with ⟨i, rfl, _, _⟩ | ⟨l, hp, hsub⟩
      · exfalso
        have hm := hno ⟨i, c.now, true⟩ (by simp [fl, flat, deferIdSt])
        have := (reachable_cbInv hreach).2.2 _ (List.mem_append_left _ hm)
        simp at this
      · have hn' := hp.nodup_iff.2 (hsub.nodup hn)
        refine ⟨(List.nodup_append.1 hn').2.1, fun i hi => hl i ?_⟩
        exact hsub.subset (hp.mem_iff.1 (List.mem_append_right _ hi))
    | deferId c heap _ _ i hli hni =>
      have e : regIds (deferIdSt c i) = regIds c ++ [i] := by
        simp [regIds, ids, flat, deferIdSt, List.filter_append]
      refine ⟨?_, fun j hj => ?_⟩
      · rw [e]; exact List.nodup_append.2 ⟨hn, by simp, by simp; intro a ha e; subst e; exact hni ha⟩
      · rw [e] at hj; rcases List.mem_append.1 hj with hj | hj
        · exact hl j hj
        · simp at hj; subst hj; exact hli
    | alloc c heap _ _ i hi =>
      refine ⟨hn, fun j hj => ?_⟩
      by_cases e : j = i
      · subst e; simp
      · simp only [upd_other _ _ _ _ e]; exact hl j hj
    | free c heap _ _ i hi hni =>
      refine ⟨hn, fun j hj => ?_⟩
      have e : j ≠ i := fun e => hni (e ▸ hj)
      simp only [upd_other _ _ _ _ e]; exact hl j hj
    | envWrite => exact ⟨hn, hl⟩

/-- **No write-after-free from `collect`.** Under the obligation, every pointer a `collect` step
stores `true` through is a live flag inside its window, each is stored at most once, and the
store ends the window (it is no longer registered afterwards). -/
theorem no_write_after_free {f : FSt} (h : FReach f) {c' : St} (hs : Step f.c c') :
    (stores f.c c').Nodup ∧
    ∀ i ∈ stores f.c c', f.heap i = .live ∧ i ∈ regIds f.c ∧ i ∉ regIds c' := by
  obtain ⟨hn, hl⟩ := freach_inv h
  rcases stores_window (freach_reachable h) hs with ⟨_, _, e, _⟩ | ⟨l, hp, hsub⟩
  · simp [e]
  · have hn' := hp.nodup_iff.2 (hsub.nodup hn)
    have hmem : ∀ i ∈ stores f.c c', i ∈ regIds f.c := fun i hi =>
      hsub.subset (hp.mem_iff.1 (List.mem_append_left _ hi))
    refine ⟨(List.nodup_append.1 hn').1, fun i hi => ⟨hl i (hmem i hi), hmem i hi, fun hi' => ?_⟩⟩
    exact (List.nodup_append.1 hn').2.2 i hi i hi' rfl

/-- **The `debug_assert!`s never fire under the obligation** (`FStep.deferId`'s premise is
exactly the negation of `assertFires`, `assertFires_iff`). -/
theorem assert_never_fires {c : St} {i : Nat} (hni : i ∉ regIds c) : assertFires c i = false := by
  cases e : assertFires c i
  · rfl
  · exact absurd ((assertFires_iff c i).1 e) hni

/-- Under the obligation the `Callbacks::defer_by_id` vectors never hold a duplicate. -/
theorem freach_no_dup {f : FSt} (h : FReach f) : (regIds f.c).Nodup := (freach_inv h).1

/-! ## The flag values -/

/-- A `collect` step that registers nothing: every flag it stores was registered before, and
`ran` only grows. -/
theorem col_newRan {c c' : St} (h : Reachable c) (hs : Step c c') (hno : ∀ x ∈ fl c', x ∈ fl c) :
    (∃ w, c'.ran = c.ran ++ w) ∧ ∀ x ∈ newRan c c', x ∈ fl c := by
  obtain ⟨_, hw, _, hc⟩ := step_flags hs (reachable_cbInv h).1
  refine ⟨hw, ?_⟩
  rcases hc with ⟨i, rfl⟩ | ⟨l, hp, hsub⟩
  · intro x hx; simp [newRan, deferIdSt] at hx
  · exact fun x hx => hsub.subset (hp.mem_iff.1 (List.mem_append_left _ hx))

theorem mem_stores {c c' : St} {i : Nat} : i ∈ stores c c' ↔ ∃ x ∈ newRan c c', x.id = i := by
  simp [stores]

theorem storeAll_true {val : Nat → Bool} {l : List Nat} {i : Nat} :
    storeAll val l i = true ↔ val i = true ∨ i ∈ l := by
  simp [storeAll]

/-- The flag value invariant: a live flag is `true` exactly when `collect` has stored a
`defer_by_id` registration of it made since its allocation (`born`). -/
structure VInv (f : FSt) : Prop where
  val : ∀ i, f.heap i = .live →
    (f.val i = true ↔ ∃ x ∈ ranB f.c, x.id = i ∧ f.born i ≤ x.time)
  reg : ∀ x ∈ fl f.c, f.born x.id ≤ x.time
  born : ∀ i, f.born i ≤ f.c.now

theorem freach_vinv {f : FSt} (h : FReach f) : VInv f := by
  induction h with
  | init =>
    refine ⟨fun i _ => ?_, by simp [fl, flat, init], fun _ => Nat.zero_le _⟩
    simp [ranB, init]
  | @step f f' hr hs ih =>
    obtain ⟨hv, hreg, hb⟩ := ih
    have hreach := freach_reachable hr
    have hcb := reachable_cbInv hreach
    have hl := (freach_inv hr).2
    cases hs with
    | @col c c' heap val born hst hno =>
      obtain ⟨⟨w, hw⟩, hsub⟩ := col_newRan hreach hst hno
      obtain ⟨_, _, hnow, _⟩ := step_flags hst hcb.1
      have hr' : ranB c' = ranB c ++ newRan c c' := by
        simp [ranB, newRan_of hw, hw, List.filter_append]
      refine ⟨fun i hi => ?_, fun x hx => hreg x (hno x hx), fun i => Nat.le_trans (hb i) hnow⟩
      simp only at hi ⊢
      rw [storeAll_true, hv i hi, mem_stores, hr']
      constructor
      · rintro (⟨x, hx, h1, h2⟩ | ⟨x, hx, rfl⟩)
        · exact ⟨x, List.mem_append_left _ hx, h1, h2⟩
        · exact ⟨x, List.mem_append_right _ hx, rfl, hreg x (hsub x hx)⟩
      · rintro ⟨x, hx, h1, h2⟩
        rcases List.mem_append.1 hx with hx | hx
        · exact .inl ⟨x, hx, h1, h2⟩
        · exact .inr ⟨x, hx, h1⟩
    | deferId c heap val born i hli hni =>
      refine ⟨fun j hj => ?_, fun x hx => ?_, fun j => ?_⟩
      · have : ranB (deferIdSt c i) = ranB c := rfl
        simp only at hj ⊢; rw [this]; exact hv j hj
      · have : fl (deferIdSt c i) = fl c ++ [⟨i, c.now, true⟩] := by
          simp [fl, flat, deferIdSt, List.filter_append]
        simp only at hx ⊢; rw [this] at hx
        rcases List.mem_append.1 hx with hx | hx
        · exact hreg x hx
        · simp at hx; subst hx; exact hb i
      · have := hb j; simp only [deferIdSt] at this ⊢; omega
    | alloc c heap val born i hi =>
      refine ⟨fun j hj => ?_, fun x hx => ?_, fun j => ?_⟩
      · simp only at hj ⊢
        by_cases e : j = i
        · subst e
          simp only [upd_same, Bool.false_eq_true, false_iff]
          rintro ⟨x, hx, _, h2⟩
          have := hcb.2.2 x (List.mem_append_right _ hx); simp only [upd_same] at h2 this; omega
        · rw [upd_other _ _ _ _ e] at hj
          rw [upd_other _ _ _ _ e, upd_other _ _ _ _ e]; exact hv j hj
      · simp only at hx ⊢
        have e : x.id ≠ i := fun e => hi (e ▸ hl x.id (by rw [regIds_eq]; exact List.mem_map_of_mem hx))
        rw [upd_other _ _ _ _ e]; exact hreg x hx
      · simp only; by_cases e : j = i
        · subst e; simp
        · rw [upd_other _ _ _ _ e]; exact hb j
    | free c heap val born i hi hni =>
      refine ⟨fun j hj => ?_, hreg, hb⟩
      simp only at hj ⊢
      by_cases e : j = i
      · subst e; simp at hj
      · rw [upd_other _ _ _ _ e] at hj; exact hv j hj
    | envWrite c heap val val' born hw =>
      refine ⟨fun j hj => ?_, hreg, hb⟩
      simp only at hj ⊢; rw [hw j hj]; exact hv j hj

/-- **A live flag holds `true` exactly when `collect` has stored it**: some `defer_by_id`
registration of it made since its allocation is in `ran` (`mark_ready` ran for it). Before any
store (in particular from allocation up to and including `defer_by_id`) it is `false`. -/
theorem flag_true_iff {f : FSt} (h : FReach f) {i : Nat} (hi : f.heap i = .live) :
    f.val i = true ↔ ∃ x ∈ ranB f.c, x.id = i ∧ f.born i ≤ x.time :=
  (freach_vinv h).val i hi

/-- **Only `collect` writes `true` to a live flag.** A step that turns a live flag from `false`
to `true` is a `collect` step (`FStep.col`, i.e. `mark_ready`) that stores through that pointer.
(Other owners may write memory that is not a live flag, `FStep.envWrite`.) -/
theorem only_collect_writes_true {f f' : FSt} (hs : FStep f f') {i : Nat} (hl : f.heap i = .live)
    (h0 : f.val i = false) (h1 : f'.val i = true) : Step f.c f'.c ∧ i ∈ stores f.c f'.c := by
  cases hs with
  | col heap val born hst _ =>
    simp only at h0 h1 ⊢
    rcases storeAll_true.1 h1 with h | h
    · rw [h0] at h; cases h
    · exact ⟨hst, h⟩
  | deferId => simp only at h0 h1; rw [h0] at h1; cases h1
  | alloc c heap val born j _ =>
    simp only at h0 h1
    by_cases e : i = j
    · subst e; simp at h1
    · rw [upd_other _ _ _ _ e, h0] at h1; cases h1
  | free => simp only at h0 h1; rw [h0] at h1; cases h1
  | envWrite c heap val val' born hw =>
    simp only at h0 h1 hl; rw [hw i hl, h0] at h1; cases h1

/-- A registered flag none of whose registrations since its allocation has been stored yet is
`false` (e.g. `SyncTable`'s `can_free`, registered once per allocation, until `mark_ready`). -/
theorem registered_once_false {f : FSt} (h : FReach f) {x : Cb} (hx : x ∈ fl f.c)
    (honly : ∀ y ∈ ranB f.c, y.id = x.id → y.time < f.born x.id) : f.val x.id = false := by
  have hl := (freach_inv h).2 x.id (by rw [regIds_eq]; exact List.mem_map_of_mem hx)
  cases e : f.val x.id
  · rfl
  · obtain ⟨y, hy, h1, h2⟩ := (flag_true_iff h hl).1 e
    have := honly y hy h1; omega

end Flags
end Collect
