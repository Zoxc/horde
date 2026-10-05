import SyncTable.Properties

/-!
# The `insert_new` / `replace` / `PotentialSlot` contracts

`Write::insert_new` requires that the key is absent, and `Write::replace` requires distinct
keys. Rust checks neither (there is no `debug_assert` for it). `PotentialSlot::insert_new`
(a safe `pub fn`) also requires that `key` is the key `get_potential` was called with, and every
`hash: Option<u64>` argument must be the key's hash; Rust checks neither outside a
`debug_assert_eq!`. On a violation of the first two:

* `insert_new` writes the pair into the first `EMPTY` bucket of the probe sequence
  (`find_insert_slot`), so the table holds two buckets for the key (`insertAt_dup`).
* `replace` / `from_iter` give every pair its own bucket (no deduplication).
* `get` returns a matching bucket of the first group that has a match or an `EMPTY` byte
  (`scanHit`; any loaded match, Rust takes the lowest bit), `remove` deletes only the bucket its
  `find` returned and the other pairs
  stay, and `expand_by` (`clone_table`) copies all duplicates. Their order on the new probe
  sequences can differ, so after an expansion `get` may return a different one of the values.

A violation of the third (the **probe contract**) writes the key into the slot's `EMPTY` bucket
(or `find_insert_slot`'s bucket for the wrong hash), which may be off the key's probe sequence or
after an `EMPTY` bucket on it (`Step.insertAny`). Then `WF.noHole` fails, and a later `get` for
the key can stop at that `EMPTY` bucket and return `none` while the key is in the map.
A wrong hash whose `h2` is not the key's also writes a tag that no lookup of the key matches
(`Step.insertMis`, a `mistagged` bucket, breaking `WF.noMis`), so `get` misses the key even when
the bucket is on its probe sequence.

The model in `Model.lean` allows all of this (`Step.insert` and `Step.replace` have no
uniqueness precondition, and `Step.insertAny` writes any key into any `EMPTY` bucket of the
current table when `growth_left > 0`). The results split into two tiers:

* **Safety, on every run (`Reachable`)**, independent of all three contracts:
  `no_use_after_free`, `retired_frozen`, `probe_in_bounds`, `reachable_sinv` (every allocated
  table is `SWF`: power of two, bounds, `growth_left`/`tombstones` accounting), the
  `PotentialSlot` validity lemmas (`potential_of_scanEmpty`, `potential_step`,
  `potential_insert`), and in `Ordered.lean` / `Composed.lean` / `Flags.lean` the reclamation
  and `can_free` flag obligations.
* **Probe-based correctness, under the probe contract (`PReachable`, `ProbeOK`)**:
  `preachable_inv` (every table is `WF`, including `noHole`), `potential_get`, and
  `get_linearizable_some` (and its `ordered_` / `composed_` versions): a `get` that returned
  `some w` saw `(k, w)` in the **multimap** at some version in its interval (`St.hist x` is a
  relation `K → V → Prop`, the set of pairs in the table at version `x`). It does not need the
  uniqueness contracts.
* **`none` results, under all three contracts (`CReachable`)**: `get_linearizable` (and its
  `ordered_` / `composed_` versions) also covers `none`: no pair for `k` was in the abstract
  state at some version in the interval. It needs unique keys because group loads are not
  snapshots: with a duplicate key, a reader can load an `EMPTY` byte, then a duplicate
  `insert_new` fills that bucket, `remove` deletes the older copy, and the reader loads the
  older copy's byte as `DELETED` and returns `none` with `k` present throughout (`NWit`). So
  multimap linearizability of `none` is **not** claimed under contract violations.

This file proves the results **under all three contracts**: on runs whose steps all respect
them (`CReachable`, with `ContractOK`), every table has unique keys and every version of the
abstract state is a map (`hist_functional`), the `none` witness `NRInv` is invariant
(`creachable_nrinv`), so `get` is linearizable (`get_linearizable`), and to a map
(`get_linearizable_map`).
-/

namespace SyncTable

variable {K V : Type} [DecidableEq K] (C : Cfg K)

/-- Step `s → s'` respects the API contract: if it is an insert of `k` into an `EMPTY` bucket
of the current table, `k` was absent, if it is a `replace` with list `l`, the keys of `l`
are distinct, and it respects the probe contract (`ProbeOK`: an insert uses `k`'s
`find_insert_slot` bucket). Only genuine `insert`/`insertAny`/`replace` steps are constrained
(`contractOK_of_ver`, `contractOK_remove`, `contractOK_swapEmpty`). -/
def ContractOK (s s' : St K V) : Prop :=
  (∀ i k v, (s.tables s.cur).slot i = .empty →
      s' = commit s (insertAt (s.tables s.cur) i k v) → ∀ w, ¬ Has (s.tables s.cur) k w) ∧
  ((∀ m l, s' = swap s (build C m l) true → l.Pairwise (fun a b => a.1 ≠ b.1)) ∧
    ∀ m l a, s.ts a = .freed → a ≠ 0 → s' = swapAt s a (build C m l) true →
      l.Pairwise (fun a b => a.1 ≠ b.1)) ∧
  ProbeOK C s s'

/-- Steps that do not change the writer version (readers, `collect`, `prune`, `expand`) never
violate the contract. -/
theorem contractOK_of_ver {s s' : St K V} (hv : s'.ver = s.ver) : ContractOK C s s' := by
  refine ⟨fun i k v _ e => ?_, ⟨fun m l e => ?_, fun m l a _ _ e => ?_⟩, probeOK_of_ver C hv⟩
  · have := congrArg St.ver e; simp [commit] at this; omega
  · have := congrArg St.ver e; simp [swap, publish] at this; omega
  · have := congrArg St.ver e; simp [swapAt, publish] at this; omega

/-- `remove` never violates the contract. -/
theorem contractOK_remove (s : St K V) (k : K) (v : V) (i : Nat) :
    ContractOK C s (commit s (removeAt (s.tables s.cur) i k v)) := by
  refine ⟨fun j k' v' he e => ?_, ⟨fun m l e => ?_, fun m l a ha _ e => ?_⟩,
    probeOK_remove C s k v i⟩
  · have e1 := congrArg (fun s : St K V => (s.tables s.cur).slot j) e
    simp only [commit, upd_same] at e1
    show ∀ w, ¬ _
    exfalso
    revert e1
    show ((if j = i then Slot.deleted k v else _) = (if j = j then Slot.full k' v' else _)) → False
    split
    · simp
    · rw [he]; simp
  · have := congrArg St.nextId e; simp [commit, swap, publish] at this
  · have := congrFun (congrArg St.ts e) a; simp [commit, swapAt, publish, upd, ha] at this

/-- `replace` of an empty iterator with `capacity = 0` (`Step.replaceEmpty`) never violates the
contract. -/
theorem contractOK_swapEmpty (s : St K V) : ContractOK C s (swapEmpty s) := by
  refine ⟨fun i k v he e => ?_, ⟨fun m l e => ?_, fun m l a ha h0 e => ?_⟩,
    probeOK_publish C s true (swapEmpty_pub s)⟩
  · exfalso
    have hc : (0 : Nat) = s.cur := congrArg St.cur e
    have e1 := congrArg (fun s' : St K V => (s'.tables s'.cur).slot i) e
    simp only [swapEmpty, commit, publish, upd_same] at e1
    rw [← hc] at he
    rw [he] at e1
    simp [insertAt, Table.set] at e1
  · have := congrArg St.nextId e; simp [swapEmpty, swap, publish] at this
  · exfalso
    have := congrFun (congrArg St.ts e) a
    simp only [swapEmpty, swapAt, publish, upd, h0, if_true, if_false, retire] at this
    split at this
    · cases this
    · rw [ha] at this; cases this

/-- Runs in which every step respects the contract. -/
inductive CReachable : St K V → Prop
  | init : CReachable init
  | step {s s'} : CReachable s → Step C s s' → ContractOK C s s' → CReachable s'

theorem CReachable.preachable {s : St K V} (h : CReachable C s) : PReachable C s := by
  induction h with
  | init => exact .init
  | step _ hs hc ih => exact .step ih hs hc.2.2

theorem CReachable.reachable {s : St K V} (h : CReachable C s) : Reachable C s :=
  (h.preachable C).reachable

/-- The functional invariant: every allocated table has unique keys and every version of the
abstract state is a map. -/
structure UInv (s : St K V) : Prop where
  uniq : ∀ t, t < s.nextId → Uniq (s.tables t)
  func : ∀ x k w w', s.hist x k w → s.hist x k w' → w = w'

theorem has_func {T : Table K V} (hu : Uniq T) {k : K} {w w' : V} (h1 : Has T k w)
    (h2 : Has T k w') : w = w' := by
  obtain ⟨i, hi⟩ := h1; obtain ⟨j, hj⟩ := h2
  have := hu _ _ _ _ _ hi hj; subst this; rw [hi] at hj; cases hj; rfl

theorem uinv_commit {s : St K V} (h : Inv C s) (hu : UInv s) (T' : Table K V) (hT : Uniq T') :
    UInv (commit s T') := by
  refine ⟨fun t ht => ?_, fun x k w w' h1 h2 => ?_⟩
  · show Uniq (upd s.tables s.cur T' t)
    by_cases e : t = s.cur
    · subst e; rw [upd_same]; exact hT
    · rw [upd_other _ _ _ _ e]; exact hu.uniq t ht
  · simp only [commit] at h1 h2
    by_cases e : x = s.ver + 1
    · simp only [e, ite_true] at h1 h2; exact has_func hT h1 h2
    · simp only [e, ite_false] at h1 h2; exact hu.func x k w w' h1 h2

theorem uinv_publish {s : St K V} (hu : UInv s) {t : Nat} {T' : Table K V} {nx : Nat} (ch : Bool)
    (hp : PubOK s t T' nx) (hT : Uniq T') : UInv (publish s t T' nx ch) := by
  refine ⟨fun u hu' => ?_, fun x k w w' h1 h2 => ?_⟩
  · by_cases e : u = t
    · subst e; show Uniq (upd s.tables u T' u); rw [upd_same]; exact hT
    · have : u < s.nextId := by
        rcases hp with ⟨rfl, rfl⟩ | ⟨rfl, rfl, rfl⟩ | ⟨_, rfl⟩
        · have : u < s.nextId + 1 := hu'; omega
        · exact hu'
        · exact hu'
      show Uniq (upd s.tables t T' u); rw [upd_other _ _ _ _ e]; exact hu.uniq u this
  · cases ch with
    | false => exact hu.func x k w w' h1 h2
    | true =>
      simp only [publish, ite_true] at h1 h2
      by_cases e : x = s.ver + 1
      · simp only [e] at h1 h2; exact has_func hT h1 h2
      · simp only [e, ite_false] at h1 h2; exact hu.func x k w w' h1 h2

theorem uinv_swap {s : St K V} (hu : UInv s) (T' : Table K V) (ch : Bool) (hT : Uniq T') :
    UInv (swap s T' ch) := uinv_publish hu ch (swap_pub _ _) hT

/-- `UInv` is preserved by every contract-respecting step. -/
theorem uinv_step (hcov : C.Cover) {s s' : St K V} (h : Inv C s) (hu : UInv s)
    (hs : Step C s s') (hc : ContractOK C s s') : UInv s' := by
  cases hs with
  | insert k v i hg hfe =>
    have he := (firstEmpty_spec hfe).1
    exact uinv_commit C h hu _ (insertAt_uniq (hu.uniq _ h.curLt) (hc.1 i k v he rfl))
  | insertAny k v i hg he _ =>
    exact uinv_commit C h hu _ (insertAt_uniq (hu.uniq _ h.curLt) (hc.1 i k v he rfl))
  | insertMis k v i _ he _ => exact absurd rfl (hc.2.2.2 i k v he)
  | removeMis k v i hi => exact absurd hi ((h.wf _ h.curLt).noMis _ _ _)
  | remove k v i hi => exact uinv_commit C h hu _ (removeAt_uniq (hu.uniq _ h.curLt) i k v)
  | expand m hm hlen =>
    exact uinv_swap hu _ _ (build_uniq C hcov m hm _
      (items_pairwise (hu.uniq _ h.curLt) (h.wf _ h.curLt).noMis) hlen)
  | replace m l hm hlen => exact uinv_swap hu _ _ (build_uniq C hcov m hm l (hc.2.1.1 m l rfl) hlen)
  | expandAt m a ha hm hlen =>
    exact uinv_publish hu _ (swapAt_pub _ ha) (build_uniq C hcov m hm _
      (items_pairwise (hu.uniq _ h.curLt) (h.wf _ h.curLt).noMis) hlen)
  | replaceAt m a l ha hm hlen =>
    have h0 : a ≠ 0 := fun e => by rw [e, h.stat] at ha; cases ha
    exact uinv_publish hu _ (swapAt_pub _ ha)
      (build_uniq C hcov m hm l (hc.2.1.2 m l a ha h0 rfl) hlen)
  | replaceEmpty =>
    exact uinv_publish hu true (swapEmpty_pub s) (hu.uniq 0 (by have := h.curLt; omega))
  | _ => exact ⟨hu.uniq, hu.func⟩

theorem creachable_inv (hcov : C.Cover) {s : St K V} (h : CReachable C s) : Inv C s ∧ UInv s := by
  induction h with
  | init =>
    refine ⟨inv_init C, fun _ _ => emptyTable_uniq 1, fun _ _ _ _ h => h.elim⟩
  | step _ hs hc ih => exact ⟨inv_step C hcov ih.1 hs hc.2.2, uinv_step C hcov ih.1 ih.2 hs hc⟩

/-- Under the contract every version of the abstract state is a map. -/
theorem hist_functional (hcov : C.Cover) {s : St K V} (h : CReachable C s) (x : Nat) (k : K)
    (w w' : V) : s.hist x k w → s.hist x k w' → w = w' :=
  (creachable_inv C hcov h).2.func x k w w'

/-! ## `none` results with sheared group loads

A `get` that returns `none` loaded every byte of its last group at its own moment
(`Step.scanLoad`), found no match and some `EMPTY` byte. `NWit` tracks, from the first `EMPTY`
byte on, a witness that the key was absent at some version since `current` was loaded: either
that is already known (`Lin … none`), or the key sits in a bucket of the group whose byte is
still to load, which then either shows the match or (only after a `remove`, which with unique
keys leaves the key absent) shows a tombstone.

Without unique keys this fails: in group `[b, e]` with `k` in `b`, a reader loads `e` as
`EMPTY`, a duplicate `insert_new(k, _)` fills `e`, `remove(k)` deletes the copy in `b`, and the
reader loads `b` as `DELETED` and returns `none`, while `k` was in the map throughout. -/

/-- The `none` witness of a group load in progress. -/
def NWit (s : St K V) (k : K) (t lv : Nat) (todo : List Nat) (obs : List (Nat × Slot K V)) :
    Prop :=
  (∃ j, (j, .empty) ∈ obs) → (∀ i w, (i, .full k w) ∉ obs) →
    Lin s k lv none ∨ ∃ q w, q ∈ todo ∧ (s.tables t).slot q = .full k w

/-- The `none` half of the reader invariant, proved under the contract (`creachable_nrinv`). -/
def NRInv (s : St K V) : RS K V → Prop
  | .scanning _ _ k t lv _ _ todo obs _ => NWit s k t lv todo obs
  | .returned _ _ k _ lv none => Lin s k lv none
  | _ => True

theorem nrinv_frame {s s' : St K V} (hv : s.ver ≤ s'.ver)
    (hh : ∀ x, x ≤ s.ver → s'.hist x = s.hist x)
    (htab : ∀ t, t < s.nextId → s.ts t ≠ .freed → ∀ q k w, (s.tables t).slot q = .full k w →
      (s'.tables t).slot q = .full k w)
    {r : RS K V} (hr : RInv C s r) (h : NRInv s r) : NRInv s' r := by
  cases r with
  | scanning st hl k t lv pre g todo obs rest =>
    intro hE hM
    rcases h hE hM with l | ⟨q, w, hq, hf⟩
    · exact Or.inl (lin_mono hv hh l)
    · exact Or.inr ⟨q, w, hq, htab t hr.2.2.1.1 hr.2.2.1.nf q k w hf⟩
  | returned st hl k t lv r =>
    cases r with
    | none => exact lin_mono hv hh (show Lin s k lv none from h)
    | some => trivial
  | _ => trivial

theorem nrinv_setRd {s : St K V} (hn : ∀ u, NRInv s (s.rd u)) (u : Nat) (r : RS K V)
    (hr : NRInv s r) : ∀ u', NRInv (setRd s u r) ((setRd s u r).rd u') := by
  intro u'
  show NRInv (setRd s u r) (upd s.rd u r u')
  by_cases e : u' = u
  · subst e; rw [upd_same]; exact hr
  · rw [upd_other _ _ _ _ e]; exact hn u'

/-- A key in a group bucket before an `EMPTY` one: `noHole` puts every copy of the key before
the first `EMPTY` bucket of its probe sequence. -/
theorem clear_group {T : Table K V} {i j : Nat} {rest : List Nat} :
    ∀ {g : List Nat}, Clear T i (g ++ rest) → j ∈ g → T.slot j = .empty → i ∈ g
  | [], _, hj, _ => by cases hj
  | a :: g, hc, hj, he => by
    rcases hc with e | ⟨hne, hc⟩
    · subst e; exact List.mem_cons_self
    · rcases List.mem_cons.1 hj with e | hj
      · subst e; exact absurd he hne
      · exact List.mem_cons_of_mem _ (clear_group hc hj he)

/-- `NRInv` is preserved by every contract-respecting step. -/
theorem nrinv_step (hcov : C.Cover) {s s' : St K V} (h : Inv C s) (hu : UInv s)
    (hn : ∀ u, NRInv s (s.rd u)) (hs : Step C s s') (hc : ContractOK C s s') :
    ∀ u, NRInv s' (s'.rd u) := by
  have h' : Inv C s' := inv_step C hcov h hs hc.2.2
  have hcommit : ∀ T', (∀ q k w, (s.tables s.cur).slot q = .full k w → T'.slot q = .full k w) →
      ∀ u, NRInv (commit s T') ((commit s T').rd u) := by
    intro T' hT u
    refine nrinv_frame C (Nat.le_succ _) (fun x hx => ?_) (fun t _ _ q k w hf => ?_) (h.rd u) (hn u)
    · show (if x = s.ver + 1 then _ else _) = _; rw [if_neg (by omega)]
    · by_cases e : t = s.cur
      · subst e; show (upd s.tables s.cur T' s.cur).slot q = _; rw [upd_same]; exact hT q k w hf
      · show (upd s.tables s.cur T' t).slot q = _; rw [upd_other _ _ _ _ e]; exact hf
  have hswap : ∀ t T' nx ch, PubOK s t T' nx →
      ∀ u, NRInv (publish s t T' nx ch) ((publish s t T' nx ch).rd u) := by
    intro t T' nx ch hp u
    have hver : s.ver ≤ (publish s t T' nx ch).ver := by cases ch <;> simp [publish]
    refine nrinv_frame C hver (fun x hx => ?_) (fun t ht hnf q k w hf => ?_) (h.rd u) (hn u)
    · cases ch <;> simp [publish]; intro; omega
    · rw [publish_tables_lt ch hp ht hnf]; exact hf
  have hsame : ∀ s'' : St K V, s''.tables = s.tables → s''.ver = s.ver → s''.hist = s.hist →
      s''.rd = s.rd → ∀ u, NRInv s'' (s''.rd u) := by
    intro s'' e1 e2 e3 e4 u
    rw [e4]
    exact nrinv_frame C (by rw [e2]; exact Nat.le_refl _) (fun x _ => by rw [e3])
      (fun t _ _ q k w hf => by rw [e1]; exact hf) (h.rd u) (hn u)
  have hrd : ∀ u r, NRInv s r → ∀ u', NRInv (setRd s u r) ((setRd s u r).rd u') :=
    fun u r hr => nrinv_setRd hn u r hr
  cases hs with
  | insert k v i hg hfe =>
    have he := (firstEmpty_spec hfe).1
    refine hcommit _ (fun q k' w hf => ?_)
    show (if q = i then _ else _) = _
    rw [if_neg (by rintro rfl; rw [he] at hf; cases hf)]; exact hf
  | insertAny k v i hg he _ =>
    refine hcommit _ (fun q k' w hf => ?_)
    show (if q = i then _ else _) = _
    rw [if_neg (by rintro rfl; rw [he] at hf; cases hf)]; exact hf
  | insertMis k v i _ he _ => exact absurd rfl (hc.2.2.2 i k v he)
  | removeMis k v i hi => exact absurd hi ((h.wf _ h.curLt).noMis _ _ _)
  | remove k0 v0 i hi =>
    intro u
    have huq := hu.uniq _ h.curLt
    have hr := h.rd u
    have hr' := h'.rd u
    have hv : s.ver ≤ s.ver + 1 := Nat.le_succ _
    have hh : ∀ x, x ≤ s.ver → (commit s (removeAt (s.tables s.cur) i k0 v0)).hist x = s.hist x :=
      fun x hx => by show (if x = s.ver + 1 then _ else _) = _; rw [if_neg (by omega)]
    have hsl : ∀ t q, ((commit s (removeAt (s.tables s.cur) i k0 v0)).tables t).slot q =
        if t = s.cur ∧ q = i then .deleted k0 v0 else (s.tables t).slot q := by
      intro t q
      by_cases e : t = s.cur
      · subst e; show (upd s.tables s.cur _ s.cur).slot q = _; rw [upd_same]
        show (if q = i then _ else _) = _; simp
      · show (upd s.tables s.cur _ t).slot q = _; rw [upd_other _ _ _ _ e]; simp [e]
    show NRInv _ (s.rd u)
    have hn' := hn u
    revert hr hr' hn'
    show RInv C s (s.rd u) → RInv C _ (s.rd u) → NRInv s (s.rd u) → NRInv _ (s.rd u)
    cases s.rd u with
    | scanning st hl k t lv pre g todo obs rest =>
      intro hr hr' hn' hE hM
      rcases hn' hE hM with l | ⟨q, w, hq, hf⟩
      · exact Or.inl (lin_mono hv hh l)
      · by_cases e : t = s.cur ∧ q = i
        · obtain ⟨rfl, rfl⟩ := e
          rw [hi] at hf; cases hf
          left
          refine lin_of_absent C h' hr'.2.2.2.1 (fun w' hw => ?_)
          simp only [commit, upd_same] at hw
          exact ((removeAt_has huq hi _ w').1 hw).2 rfl
        · right; exact ⟨q, w, hq, by rw [hsl, if_neg e]; exact hf⟩
    | returned st hl k t lv r =>
      intro _ _ hn'
      cases r with
      | none => exact lin_mono hv hh (show Lin s k lv none from hn')
      | some => trivial
    | _ => intros; trivial
  | expand m _ _ => exact hswap _ _ _ _ (swap_pub _ _)
  | replace m l _ _ => exact hswap _ _ _ _ (swap_pub _ _)
  | expandAt m a ha => exact hswap _ _ _ _ (swapAt_pub _ ha)
  | replaceAt m a l ha => exact hswap _ _ _ _ (swapAt_pub _ ha)
  | replaceEmpty => exact hswap _ _ _ _ (swapEmpty_pub _)
  | prune t v d _ => exact hsame _ rfl rfl rfl rfl
  | markFree t v d _ _ => exact hsame _ rfl rfl rfl rfl
  | pin u _ =>
    intro u'
    show NRInv _ (upd s.rd u _ u')
    by_cases e : u' = u
    · subst e; rw [upd_same]; trivial
    · rw [upd_other _ _ _ _ e]
      exact nrinv_frame C (s := s) (Nat.le_refl _) (fun _ _ => rfl) (fun _ _ _ _ _ _ hf => hf) (h.rd u') (hn u')
  | unpin u st hl _ => exact hrd u _ trivial
  | load u st hl k _ => exact hrd u _ trivial
  | probeGroup u st hl k t lv pre g rest _ _ =>
    exact hrd u _ (fun ⟨_, hj⟩ => by cases hj)
  | scanLoad u st hl k t lv pre g todo obs rest j hus hj =>
    apply hrd u
    have hr := h.rd u; rw [hus] at hr
    obtain ⟨_, _, h3, h4, h5, h6, h7, _⟩ := hr
    have hn' := hn u; rw [hus] at hn'
    intro ⟨e, hE⟩ hM
    have hM0 : ∀ i w, (i, Slot.full k w) ∉ obs := fun i w hi => hM i w (by simp [hi])
    have hload : ∀ q w, q ∈ todo → (s.tables t).slot q = .full k w → q ∈ todo.erase j := by
      intro q w hq hf
      refine (List.mem_erase_of_ne (fun e => ?_)).2 hq
      subst e; exact hM q w (by simp [hf])
    by_cases hold : ∃ e', (e', Slot.empty) ∈ obs
    · rcases hn' hold hM0 with l | ⟨q, w, hq, hf⟩
      · exact Or.inl l
      · exact Or.inr ⟨q, w, hload q w hq hf, hf⟩
    · -- the first `EMPTY` byte of the group: this load
      have hje : (s.tables t).slot j = .empty ∧ e = j := by
        simp only [List.mem_append, List.mem_singleton, Prod.mk.injEq] at hE
        rcases hE with hE | ⟨rfl, hE⟩
        · exact absurd ⟨e, hE⟩ hold
        · exact ⟨hE.symm, rfl⟩
      by_cases hk : ∃ w, Has (s.tables t) k w
      · obtain ⟨w, i, hi⟩ := hk
        right; refine ⟨i, w, ?_, hi⟩
        have hc := (h.wf t h3.1).noHole _ _ _ hi
        rw [h5] at hc
        rcases Clear.append hc with hp | hc
        · exact absurd hi ((h6 i hp).2 w)
        · have hig := clear_group hc (h7.1 j hj) hje.1
          rcases h7.2.1 i hig with hit | ⟨o, ho⟩
          · exact hload i w hit hi
          · have hne : o ≠ .empty := fun e' => hold ⟨i, e' ▸ ho⟩
            exact absurd (((h7.2.2 i o ho).2 hne).2 w hi ▸ ho) (hM0 i w)
      · exact Or.inl (lin_of_absent C h h4 (fun w hw => hk ⟨w, hw⟩))
  | scanHit u st hl k t lv pre g obs rest j v _ _ => exact hrd u _ trivial
  | scanEmpty u st hl k t lv pre g obs rest j hus hM hj =>
    apply hrd u
    have hn' := hn u; rw [hus] at hn'
    rcases hn' ⟨j, hj⟩ hM with l | ⟨q, w, hq, _⟩
    · exact l
    · cases hq
  | scanNext u st hl k t lv pre g obs rest _ _ _ => exact hrd u _ trivial
  | probeEnd u st hl k t lv pre hus =>
    apply hrd u
    have hr := h.rd u; rw [hus] at hr
    obtain ⟨_, _, h3, h4, h5, h6⟩ := hr
    exact lin_of_absent C h h4 (absent_of_seen C (h.wf t h3.1) h5 h6 (Or.inl rfl))
  | finish u st hl k t lv r _ => exact hrd u _ trivial

theorem creachable_nrinv (hcov : C.Cover) {s : St K V} (h : CReachable C s) :
    ∀ u, NRInv s (s.rd u) := by
  induction h with
  | init => intro u; trivial
  | step hr hs hc ih =>
    have hi := creachable_inv C hcov hr
    exact nrinv_step C hcov hi.1 hi.2 ih hs hc

/-- **Linearizability of `get`, under the contract.** When a reader's `get`/`get_potential` for
`k` has returned `r` (having loaded `current` at writer version `lv`), the abstract state at
some version `x` with `lv ≤ x ≤ ver` agrees with `r`: `some w` means `(k, w)` was in it, `none`
that no pair for `k` was. Group loads are modelled byte by byte at independent moments
(`Step.scanLoad`). The `some` case holds on all `PReachable` runs (`get_linearizable_some`); the
`none` case needs unique keys (see `NWit` for the counterexample with duplicates). -/
theorem get_linearizable (hcov : C.Cover) {s : St K V} (h : CReachable C s) (u st : Nat)
    (hl : List Nat) (k : K) (t lv : Nat) (r : Option V)
    (hu : s.rd u = .returned st hl k t lv r) : Lin s k lv r := by
  cases r with
  | some w => exact get_linearizable_some C hcov (h.preachable C) u st hl k t lv w hu
  | none =>
    have := creachable_nrinv C hcov h u
    rw [hu] at this; exact this

/-- **Linearizability of `get` to a map, under the contract.** A `get` that returned `some w`
saw the map `k ↦ w` (and no other value for `k`) at some version in its interval, and one that
returned `none` saw `k` unmapped. -/
theorem get_linearizable_map (hcov : C.Cover) {s : St K V} (h : CReachable C s) (u st : Nat)
    (hl : List Nat) (k : K) (t lv : Nat) (r : Option V)
    (hu : s.rd u = .returned st hl k t lv r) :
    ∃ x, lv ≤ x ∧ x ≤ s.ver ∧ ∀ w, s.hist x k w ↔ r = some w := by
  have hlin := get_linearizable C hcov h u st hl k t lv r hu
  cases r with
  | none =>
    obtain ⟨x, h1, h2, h3⟩ := hlin
    exact ⟨x, h1, h2, fun w => ⟨fun hw => (h3 w hw).elim, fun e => by cases e⟩⟩
  | some w0 =>
    obtain ⟨x, h1, h2, h3⟩ := hlin
    refine ⟨x, h1, h2, fun w => ⟨fun hw => ?_, fun e => by cases e; exact h3⟩⟩
    rw [hist_functional C hcov h x k w0 w h3 hw]

end SyncTable
