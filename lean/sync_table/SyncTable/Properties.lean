import SyncTable.Safety

/-!
# Headline properties

Safety, on every run (`Reachable`, which includes `Step.insertAny`: `PotentialSlot::insert_new`
with a key other than the one given to `get_potential`):

* `no_use_after_free`: reclamation through `collect` is safe for readers.
* `retired_frozen`: a table is never written after it stops being `current`.
* `static_live`, `static_frozen`: the static empty table is never retired, deferred or freed,
  and never written.
* `potential_of_scanEmpty`, `potential_step`, `potential_insert`: a `PotentialSlot` stays valid
  while its bucket is `EMPTY`, and used with its own key it is `find_insert_slot`'s bucket, so
  that insert respects the probe contract (`potential_insert_probeOK`).
* `insert_enabled`: `find_insert_slot` always finds a slot when `growth_left > 0`.

Probe-based correctness, on runs that respect the probe contract (`PReachable`):

* `get_linearizable_some`: a lock-free `get` hit is linearizable against the single writer
  (the `none` case needs the key contract too: `get_linearizable` in `Contract.lean`).
* `potential_get`: the `PotentialSlot::{get, refresh}` fast paths are correct.
* `retired_eventually_freed`: liveness of reclamation (proved in `Ordered.lean`).
-/

namespace SyncTable

variable {K V : Type} [DecidableEq K] (C : Cfg K)

/-- Table `t` is being probed by, or holds references returned to, reader state `r`. -/
def Uses {K V} : RS K V → Nat → Prop
  | .idle, _ => False
  | .pinned _ h, t => t ∈ h
  | .probing _ h _ t' .., t => t = t' ∨ t ∈ h
  | .scanning _ h _ t' .., t => t = t' ∨ t ∈ h
  | .returned _ h _ t' .., t => t = t' ∨ t ∈ h

/-- **No use-after-free.** In every reachable state, every table a reader is probing or
holds references into (until it unpins) is allocated and not freed. This depends on the
`collect` contract in `Step.markFree`'s premise, which `Composed.lean` proves
(`Composed.composed_no_use_after_free`). -/
theorem no_use_after_free (hcov : C.Cover) {s : St K V} (h : Reachable C s) (u t : Nat)
    (hu : Uses (s.rd u) t) : s.ts t ≠ .freed ∧ s.ts t ≠ .unalloc := by
  have hi := reachable_sinv C hcov h
  have hH : ∀ st, Holds s st t → s.ts t ≠ .freed ∧ s.ts t ≠ .unalloc := by
    intro st ⟨_, h2⟩
    rcases h2 with h2 | ⟨v, d, h2, _⟩ <;> rw [h2] <;> exact ⟨by simp, by simp⟩
  have hr := hi.rd u
  cases hru : s.rd u with
  | idle => rw [hru] at hu; exact hu.elim
  | pinned st hl => rw [hru] at hu hr; exact hH st (hr.2 t hu)
  | probing st hl k t' lv pre rest =>
    rw [hru] at hu hr
    rcases hu with rfl | hu
    · exact hH st hr.2.2.1
    · exact hH st (hr.2.1 t hu)
  | scanning st hl k t' lv pre g todo obs rest =>
    rw [hru] at hu hr
    rcases hu with rfl | hu
    · exact hH st hr.2.2.1
    · exact hH st (hr.2.1 t hu)
  | returned st hl k t' lv r =>
    rw [hru] at hu hr
    rcases hu with rfl | hu
    · exact hH st hr.2.2
    · exact hH st (hr.2.1 t hu)

/-- **Linearizability of a `get` hit, to the multimap.** When a reader's `get`/`get_potential`
for `k` has returned `some w` (having loaded `current` at writer version `lv`), the pair
`(k, w)` is in the abstract multimap at some version `x` with `lv ≤ x ≤ ver`, i.e. within the
operation's interval (the version can only grow). It holds with duplicate keys and with sheared
group loads: the byte that matched was loaded at a moment its pair was in the table.

Only on runs that respect the probe contract (`PReachable`, needed for the current table to
represent `hist ver`). A `none` result is linearizable only under the full key contract
(`get_linearizable` in `Contract.lean`): with duplicate keys a sheared group load can miss
every copy of a key that is present throughout the `get`. -/
theorem get_linearizable_some (hcov : C.Cover) {s : St K V} (h : PReachable C s) (u st : Nat)
    (hl : List Nat) (k : K) (t lv : Nat) (w : V)
    (hu : s.rd u = .returned st hl k t lv (some w)) : Lin s k lv (some w) := by
  have hr := (preachable_inv C hcov h).rd u
  rw [hu] at hr; exact hr.2.2.2 w rfl

/-- **Retired tables are frozen**: an allocated table that is not `current` is never modified
(a freed one's address may be reused by a new table, `Step.expandAt`/`replaceAt`). -/
theorem retired_frozen {s s' : St K V} (h : SInv C s) (hs : Step C s s') (t : Nat)
    (ht : s.ts t ≠ .live) (hf : s.ts t ≠ .freed) (hlt : t < s.nextId) :
    s'.tables t = s.tables t := by
  have hne : t ≠ s.cur := by intro e; subst e; exact ht h.curLive
  cases hs with
  | insert => exact upd_other _ _ _ _ hne
  | insertAny => exact upd_other _ _ _ _ hne
  | insertMis => exact upd_other _ _ _ _ hne
  | remove => exact upd_other _ _ _ _ hne
  | removeMis => exact upd_other _ _ _ _ hne
  | expand => exact upd_other _ _ _ _ (Nat.ne_of_lt hlt)
  | replace => exact upd_other _ _ _ _ (Nat.ne_of_lt hlt)
  | expandAt m a ha => exact upd_other _ _ _ _ (fun e => hf (e ▸ ha))
  | replaceAt m a l ha => exact upd_other _ _ _ _ (fun e => hf (e ▸ ha))
  | replaceEmpty => exact publish_tables_lt true (swapEmpty_pub s) hlt hf
  | _ => rfl

/-- **The static empty table is never retired, deferred or freed** (every run): its status stays
`live`, so `replace_table` never appends it to the retired list and `prune_tables` never frees
it. -/
theorem static_live (hcov : C.Cover) {s : St K V} (h : Reachable C s) : s.ts 0 = .live :=
  (reachable_sinv C hcov h).stat

/-- **The static empty table is never written** (every run): it stays the 1-bucket empty table
with `growth_left = 0`. -/
theorem static_frozen (hcov : C.Cover) {s : St K V} (h : Reachable C s) :
    s.tables 0 = emptyTable 1 :=
  (reachable_sinv C hcov h).tab0

/-- A `PotentialSlot` for key `k` at bucket `idx` of table `t`: `idx` is still `EMPTY`
and every bucket before it on `k`'s probe sequence is non-empty and does not hold `k`. -/
def PotP (s : St K V) (t : Nat) (k : K) (idx : Nat) : Prop :=
  t < s.nextId ∧ s.ts t ≠ .freed ∧ (s.tables t).slot idx = .empty ∧
    ∃ pre rest, ps C (s.tables t) k = pre ++ idx :: rest ∧ Seen (s.tables t) k pre

/-- `get_potential` returning `Err(slot)` creates a valid `PotP` while the slot is still
`EMPTY`. `find_potential`'s stop takes the lowest `EMPTY` bit `j` of the loaded group `g`
(`g = g1 ++ j :: g2`, every byte loaded for `g1` non-`EMPTY`) after no byte matched `k`
(`Step.scanEmpty`'s premise). The byte for `j` may have been loaded before other bytes of the
group, so `j` can have been filled since; then `PotentialSlot::is_empty` fails later. -/
theorem potential_of_scanEmpty {s : St K V} (h : SInv C s) {u st : Nat} {hl : List Nat} {k : K}
    {t lv : Nat} {pre g g1 g2 rest : List Nat} {obs : List (Nat × Slot K V)} {j : Nat}
    (hu : s.rd u = .scanning st hl k t lv pre g [] obs rest) (hm : ∀ i w, (i, .full k w) ∉ obs)
    (hg : g = g1 ++ j :: g2) (hne : ∀ i ∈ g1, ∀ o, (i, o) ∈ obs → o ≠ .empty)
    (he : (s.tables t).slot j = .empty) : PotP C s t k j := by
  have hr := h.rd u; rw [hu] at hr
  obtain ⟨_, _, h3, h5, h6, h7⟩ := hr
  refine ⟨h3.1, h3.nf, he, pre ++ g1, g2 ++ rest, by rw [h5, hg]; simp, fun i hi => ?_⟩
  simp only [List.mem_append] at hi
  rcases hi with hi | hi
  · exact h6 i hi
  · rcases h7.2.1 i (by rw [hg]; simp [hi]) with h1 | ⟨o, h1⟩
    · cases h1
    · obtain ⟨h2, h3⟩ := (h7.2.2 i o h1).2 (hne i hi o h1)
      exact ⟨h2, fun w e => hm i w (h3 w e ▸ h1)⟩

/-- A `PotP` stays valid across any interleaving of steps as long as its bucket stays
`EMPTY` (which is what `PotentialSlot::is_empty` re-checks) and its table is not freed (the
slot's lifetime `'a` is the pin's, which keeps the table allocated, `no_use_after_free`). -/
theorem potential_step {s s' : St K V} (_h : SInv C s) (hs : Step C s s') {t : Nat} {k : K}
    {idx : Nat} (hp : PotP C s t k idx) (he : (s'.tables t).slot idx = .empty)
    (hnf : s'.ts t ≠ .freed) : PotP C s' t k idx := by
  obtain ⟨hlt, hf, _, pre, rest, hps, hseen⟩ := hp
  have hcommit : ∀ T', Grows (s.tables s.cur) T' →
      ((commit s T').tables t).slot idx = .empty → PotP C (commit s T') t k idx := by
    intro T' hg he
    refine ⟨hlt, hf, he, pre, rest, ?_⟩
    by_cases e : t = s.cur
    · have : (commit s T').tables t = T' := by rw [e]; exact upd_same _ _ _
      rw [this, ps_grows C hg]; rw [e] at hps hseen; exact ⟨hps, seen_grows hg hseen⟩
    · have : (commit s T').tables t = s.tables t := upd_other _ _ _ _ e
      rw [this]; exact ⟨hps, hseen⟩
  have hswap : ∀ t' T' nx ch, PubOK s t' T' nx → ((publish s t' T' nx ch).tables t).slot idx = .empty →
      PotP C (publish s t' T' nx ch) t k idx := by
    intro t' T' nx ch hpub he
    have : (publish s t' T' nx ch).tables t = s.tables t := publish_tables_lt ch hpub hlt hf
    refine ⟨Nat.lt_of_lt_of_le hlt hpub.nx_ge, fun h' => hf (publish_freed h'), he, pre, rest, ?_⟩
    rw [this]; exact ⟨hps, hseen⟩
  cases hs with
  | insert k' v i _ hfe => exact hcommit _ (grows_insertAt _ _ _ _ (firstEmpty_spec hfe).1) he
  | insertAny k' v i _ he' _ => exact hcommit _ (grows_insertAt _ _ _ _ he') he
  | insertMis k' v i _ he' _ => exact hcommit _ (grows_insertMis _ _ _ _ he') he
  | remove => exact hcommit _ (grows_removeAt _ _ _ _) he
  | removeMis => exact hcommit _ (grows_removeAt _ _ _ _) he
  | expand => exact hswap _ _ _ _ (swap_pub _ _) he
  | replace => exact hswap _ _ _ _ (swap_pub _ _) he
  | expandAt m a ha => exact hswap _ _ _ _ (swapAt_pub _ ha) he
  | replaceAt m a l ha => exact hswap _ _ _ _ (swapAt_pub _ ha) he
  | replaceEmpty => exact hswap _ _ _ _ (swapEmpty_pub _) he
  | _ => exact ⟨hlt, hnf, he, pre, rest, hps, hseen⟩

/-- **`PotentialSlot::get` / `refresh` fast path**: if the slot is in the current table and
still `EMPTY`, the key is absent from the abstract map right now. Needs the full `Inv`
(`WF.noHole`), so it holds on `PReachable` runs (`preachable_inv`). -/
theorem potential_get {s : St K V} (h : Inv C s) {k : K} {idx : Nat} (hp : PotP C s s.cur k idx) :
    ∀ w, ¬ s.hist s.ver k w := by
  obtain ⟨hlt, _, he, pre, rest, hps, hseen⟩ := hp
  intro w hw
  exact absent_of_seen C (h.wf _ hlt) hps hseen (Or.inr ⟨idx, rest, rfl, he⟩) w
    ((h.curHist k w).2 hw)

/-- **`PotentialSlot::insert_new` fast path**: the slot is exactly what
`find_insert_slot` would pick (the `debug_assert_eq!` in `insert_new`). -/
theorem potential_insert {s : St K V} {t : Nat} {k : K} {idx : Nat} (hp : PotP C s t k idx) :
    firstEmpty (s.tables t) (ps C (s.tables t) k) = some idx := by
  obtain ⟨_, _, he, pre, rest, hps, hseen⟩ := hp
  unfold firstEmpty; rw [hps, List.find?_append]
  have : pre.find? (fun i => ((s.tables t).slot i).isEmpty) = none := by
    rw [List.find?_eq_none]; intro x hx
    cases e : (s.tables t).slot x with
    | empty => exact absurd e (hseen x hx).1
    | _ => simp [Slot.isEmpty]
  rw [this]; simp [he, Slot.isEmpty]

/-- `find_insert_slot` terminates whenever the writer may insert. -/
theorem insert_enabled (hcov : C.Cover) {s : St K V} (h : SInv C s) (k : K) :
    ∃ i, firstEmpty (s.tables s.cur) (ps C (s.tables s.cur) k) = some i :=
  firstEmpty_isSome C (h.swf _ h.curLt) hcov k

/-- **The `PotentialSlot` key contract implies the probe contract**: `insert_new` on a valid
`PotentialSlot` for the current table, with the key it was created for, is a `ProbeOK` step. So a
run in which every `PotentialSlot::insert_new` uses its slot's key (and every `hash` argument is
the key's hash) is `PReachable`. -/
theorem potential_insert_probeOK {s : St K V} {k : K} {idx : Nat} (v : V)
    (hp : PotP C s s.cur k idx) :
    ProbeOK C s (commit s (insertAt (s.tables s.cur) idx k v)) :=
  probeOK_insert C (potential_insert C hp)

/-- Reflexive-transitive closure of `Step`. -/
inductive Steps : St K V → St K V → Prop
  | refl (s) : Steps s s
  | tail {s s' s''} : Steps s s' → Step C s' s'' → Steps s s''

/- Reclamation liveness (`retired_eventually_freed`) is proved in `Ordered.lean`, together
with its FIFO-ordered variant. -/

end SyncTable
