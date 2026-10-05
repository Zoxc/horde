import SyncTable.Link
import SyncTable.Backend

/-!
# Deriving `ObsOf` and `Loaded` from the reader state

`Link.lean` relates Rust's group decision to the model's `scanHit` / `scanEmpty` / `scanNext`
under two hypotheses, `ObsOf` and `Loaded`. This file derives them on reachable states, with
invariants kept here (self-contained, no change to `Model.lean`):

* `reachable_obsPerm`: on every `Reachable` state, a scanning reader's loaded buckets and
  `todo` are a permutation of its group `g` (`ObsPerm`). Once `todo = []` and `g` has no
  duplicates (the `W`-chunks of `triSeq` have none, `chunk_nodup`), `obs` records each bucket of
  `g` exactly once: `obsOf_of_perm` gives `ObsOf` with `os[b]` the slot recorded for `g[b]`.
* `preachable_noMis`: on `PReachable` runs no table has a `mistagged` bucket, so no recorded
  slot is one (`ObsNoMis`).
* `loaded_canon`: the canonical bytes of the recorded slots (`encSlot`: `EMPTY`, `DELETED`,
  `h2 (hash k)`) satisfy `Loaded`.
* `reader_group_step` / `reader_model_*`: Rust's group decision on the bytes it loaded is a model
  step, and conversely, for every reachable scanning reader with a complete, duplicate-free group.

The one remaining hypothesis is `ReplicaSync`: the bytes Rust's `Group::load` returns are the
canonical bytes of the slots the model's `scanLoad` steps recorded. In the sequentially
consistent model a byte load of a primary control byte returns exactly that (the writer's
`Release` store is the slot change). For a byte in the mirrored trailing group it additionally
needs the replica store of `set_ctrl_release`, which comes after the primary store, to be seen
together with it; that ordering question is weak memory (property 18), answered per `get` in `RC11Table.lean`
(`group_replicaSync`, `group_step_rc11`) and across a reader's `get`s, where one replica byte
may lag, in `RC11Global.lean` (`chain_replicaSync`, `reader_lin`).
-/

namespace SyncTable
namespace Bytes

variable {K V : Type} [DecidableEq K] (C : Cfg K)

/-! ## Loaded buckets form a permutation of the group -/

def ObsPerm : RS K V → Prop
  | .scanning _ _ _ _ _ _ g todo obs _ => (obs.map Prod.fst ++ todo).Perm g
  | _ => True

omit [DecidableEq K] in
theorem setRd_rd (s : St K V) (u : Nat) (r : RS K V) (u' : Nat) :
    (setRd s u r).rd u' = if u' = u then r else s.rd u' := rfl

omit [DecidableEq K] in
theorem reachable_obsPerm {s : St K V} (h : Reachable C s) : ∀ u, ObsPerm (s.rd u) := by
  induction h with
  | init => intro u; exact trivial
  | step _ hs ih =>
    intro u'
    cases hs with
    | probeGroup u st hl k t lv pre g rest _ _ =>
      rw [setRd_rd]; split
      · exact List.Perm.refl _
      · exact ih u'
    | scanLoad u st hl k t lv pre g todo obs rest j hrd hj =>
      rw [setRd_rd]; split
      · have := ih u; rw [hrd] at this
        show ((obs ++ [(j, _)]).map Prod.fst ++ todo.erase j).Perm g
        simp only [List.map_append, List.map_cons, List.map_nil, List.append_assoc,
          List.singleton_append]
        exact ((List.perm_cons_erase hj).symm.append_left _).trans this
      · exact ih u'
    | pin | unpin | load | scanHit | scanEmpty | scanNext | probeEnd | finish =>
      rw [setRd_rd]; split
      · exact trivial
      · exact ih u'
    | _ => exact ih u'

/-! ## No mistagged buckets on probe-respecting runs -/

def NoMisT (T : Table K V) : Prop := ∀ i k v, T.slot i ≠ .mistagged k v

def ObsNoMis : RS K V → Prop
  | .scanning _ _ _ _ _ _ _ _ obs _ => ∀ p ∈ obs, ∀ k v, p.2 ≠ .mistagged k v
  | _ => True

omit [DecidableEq K] in
theorem noMis_insertAt {T : Table K V} (h : NoMisT T) (i : Nat) (k : K) (v : V) :
    NoMisT (insertAt T i k v) := by
  intro j k' v' e; change (if j = i then _ else _) = _ at e
  split at e
  · cases e
  · exact h _ _ _ e

omit [DecidableEq K] in
theorem noMis_removeAt {T : Table K V} (h : NoMisT T) (i : Nat) (k : K) (v : V) :
    NoMisT (removeAt T i k v) := by
  intro j k' v' e; change (if j = i then _ else _) = _ at e
  split at e
  · cases e
  · exact h _ _ _ e

omit [DecidableEq K] in
theorem noMis_build (m : Nat) (l : List (K × V)) : NoMisT (build C m l) := by
  unfold build
  suffices ∀ (l : List (K × V)) (T : Table K V), NoMisT T →
      NoMisT (l.foldl (fun T p => insertNew C T p.1 p.2) T) from
    this l _ (fun _ _ _ e => nomatch e)
  intro l; induction l with
  | nil => intro T h; exact h
  | cons p l ih =>
    intro T h; simp only [List.foldl_cons]; apply ih
    unfold insertNew; split
    · exact noMis_insertAt h _ _ _
    · exact h

omit [DecidableEq K] in
/-- **No table and no recorded slot is `mistagged` on probe-respecting runs.** -/
theorem preachable_noMis {s : St K V} (h : PReachable C s) :
    (∀ t, NoMisT (s.tables t)) ∧ ∀ u, ObsNoMis (s.rd u) := by
  induction h with
  | init => exact ⟨(fun _ _ _ _ e => nomatch e), fun _ => trivial⟩
  | step _ hs hp ih =>
    obtain ⟨ht, hr⟩ := ih
    have hcommit : ∀ s0 : St K V, (∀ t, NoMisT (s0.tables t)) → ∀ T', NoMisT T' →
        ∀ t, NoMisT ((commit s0 T').tables t) := fun s0 h0 T' hT t => by
      show NoMisT (upd s0.tables s0.cur T' t)
      unfold upd; split
      · exact hT
      · exact h0 t
    have hpub : ∀ s0 : St K V, (∀ t, NoMisT (s0.tables t)) → ∀ t0 T' nx ch, NoMisT T' →
        ∀ t, NoMisT ((publish s0 t0 T' nx ch).tables t) := fun s0 h0 t0 T' nx ch hT t => by
      show NoMisT (upd s0.tables t0 T' t)
      unfold upd; split
      · exact hT
      · exact h0 t
    cases hs with
    | insert k v i _ _ => exact ⟨hcommit _ ht _ (noMis_insertAt (ht _) _ _ _), hr⟩
    | insertAny k v i _ _ _ => exact ⟨hcommit _ ht _ (noMis_insertAt (ht _) _ _ _), hr⟩
    | insertMis k v i _ he _ => exact (hp.2 i k v he rfl).elim
    | remove k v i _ => exact ⟨hcommit _ ht _ (noMis_removeAt (ht _) _ _ _), hr⟩
    | removeMis k v i _ => exact ⟨hcommit _ ht _ (noMis_removeAt (ht _) _ _ _), hr⟩
    | expand m _ _ => exact ⟨hpub _ ht _ _ _ _ (noMis_build C _ _), hr⟩
    | replace m l _ _ => exact ⟨hpub _ ht _ _ _ _ (noMis_build C _ _), hr⟩
    | expandAt m a _ _ _ => exact ⟨hpub _ ht _ _ _ _ (noMis_build C _ _), hr⟩
    | replaceAt m a l _ _ _ => exact ⟨hpub _ ht _ _ _ _ (noMis_build C _ _), hr⟩
    | replaceEmpty => exact ⟨hpub _ ht _ _ _ _ (ht 0), hr⟩
    | prune => exact ⟨ht, hr⟩
    | markFree => exact ⟨ht, hr⟩
    | scanLoad u st hl k t lv pre g todo obs rest j hrd hj =>
      refine ⟨ht, fun u' => ?_⟩
      rw [setRd_rd]; split
      · have := hr u; rw [hrd] at this
        intro p hp k' v' e
        rcases List.mem_append.mp hp with hp | hp
        · exact this p hp k' v' e
        · simp only [List.mem_singleton] at hp; subst hp; exact ht t j k' v' e
      · exact hr u'
    | probeGroup =>
      refine ⟨ht, fun u' => ?_⟩; rw [setRd_rd]; split
      · intro p hp; simp at hp
      · exact hr u'
    | pin | unpin | load | scanHit | scanEmpty | scanNext | probeEnd | finish =>
      refine ⟨ht, fun u' => ?_⟩; rw [setRd_rd]; split
      · exact trivial
      · exact hr u'

/-! ## `ObsOf` from the permutation -/

/-- The slot recorded for bucket `j`. -/
def obsSlot (obs : List (Nat × Slot K V)) (j : Nat) : Slot K V :=
  ((obs.find? (fun p => p.1 == j)).map Prod.snd).getD .empty

omit [DecidableEq K] in
theorem mem_obs_iff : ∀ {obs : List (Nat × Slot K V)}, (obs.map Prod.fst).Nodup →
    ∀ j s, (j, s) ∈ obs ↔ j ∈ obs.map Prod.fst ∧ s = obsSlot obs j
  | [], _, j, s => by simp
  | (a, x) :: obs, hnd, j, s => by
    rw [List.map_cons, List.nodup_cons] at hnd
    have ih := mem_obs_iff hnd.2 j s
    by_cases hj : j = a
    · subst hj
      have e : obsSlot ((j, x) :: obs) j = x := by simp [obsSlot]
      rw [e]
      constructor
      · intro h
        rcases List.mem_cons.mp h with h | h
        · cases h; exact ⟨by simp, rfl⟩
        · exact absurd (List.mem_map_of_mem (f := Prod.fst) h) hnd.1
      · rintro ⟨-, rfl⟩; exact List.mem_cons_self
    · have e : obsSlot ((a, x) :: obs) j = obsSlot obs j := by
        simp [obsSlot, Ne.symm hj]
      rw [e, List.mem_cons, List.map_cons, List.mem_cons, ih]
      simp [hj]

omit [DecidableEq K] in
/-- `ObsOf` for a fully loaded duplicate-free group: `os[b]` is the slot recorded for `g[b]`. -/
theorem obsOf_of_perm {g : List Nat} {obs : List (Nat × Slot K V)} (hp : (obs.map Prod.fst).Perm g)
    (hnd : g.Nodup) :
    ObsOf g.length (fun b => g.getD b 0) (g.map (obsSlot obs)) obs := by
  have hnd' : (obs.map Prod.fst).Nodup := hp.nodup_iff.mpr hnd
  intro j s
  rw [mem_obs_iff hnd' j s, hp.mem_iff, List.mem_iff_getElem]
  constructor
  · rintro ⟨⟨b, hb, rfl⟩, rfl⟩
    exact ⟨b, hb, by simp [List.getD_eq_getElem?_getD, hb], by simp [List.getD_eq_getElem?_getD, hb]⟩
  · rintro ⟨b, hb, rfl, rfl⟩
    refine ⟨⟨b, hb, by simp [List.getD_eq_getElem?_getD, hb]⟩, ?_⟩
    simp [List.getD_eq_getElem?_getD, hb]

/-! ## Canonical bytes -/

/-- The control byte `set_ctrl` stores for a slot (`mistagged` buckets do not occur here). -/
def encSlot (hash : K → Nat) (h2 : Nat → Nat) : Slot K V → Nat
  | .empty => EMPTY
  | .deleted .. => DELETED
  | .full k _ => h2 (hash k)
  | .mistagged .. => 0

/-- **The hypothesis left to weak memory**: the bytes Rust's `Group::load` returned are the
bytes of the slots the model recorded (for mirrored bytes: the replica store is seen with the
primary one). -/
def ReplicaSync (hash : K → Nat) (h2 : Nat → Nat) (bs : List Nat) (os : List (Slot K V)) : Prop :=
  bs = os.map (encSlot hash h2)

omit [DecidableEq K] in
theorem loaded_canon {W : Nat} {hash : K → Nat} {h2 : Nat → Nat} {k : K} {os : List (Slot K V)}
    (hlen : os.length = W) (hnm : ∀ s ∈ os, ∀ k v, s ≠ .mistagged k v) :
    Loaded W hash h2 k (os.map (encSlot hash h2)) os := by
  refine ⟨by simp [hlen], hlen, fun b hb => ?_, fun b hb v e => ?_⟩
  · have hb' : b < os.length := by omega
    have hg : os.getD b .empty = os[b] := by simp [List.getD_eq_getElem?_getD, hb']
    have hg2 : (os.map (encSlot hash h2)).getD b 0 = encSlot hash h2 os[b] := by
      simp [List.getD_eq_getElem?_getD, hb']
    rw [hg, hg2]
    have hmem := List.getElem_mem hb'
    generalize os[b] = x at hmem ⊢
    cases x with
    | empty => rfl
    | deleted _ _ => rfl
    | full _ _ => rfl
    | mistagged k' v' => exact absurd rfl (hnm _ hmem k' v')
  · have hb' : b < os.length := by omega
    have hg : os.getD b .empty = os[b] := by simp [List.getD_eq_getElem?_getD, hb']
    rw [hg] at e
    exact hnm _ (List.getElem_mem hb') k v e

/-- The `W`-chunks of `triSeq` have no duplicates. -/
theorem chunk_nodup {W n pos : Nat} (hWn : W ≤ n) (hpos : pos < n) :
    ((List.range W).map (fun b => (pos + b) % n)).Nodup := by
  unfold List.Nodup; rw [List.pairwise_map]
  refine List.nodup_range.imp_of_mem (fun {a b} ha hb hne e => hne ?_)
  simp only [List.mem_range] at ha hb
  have h1 : ∀ x, x < 2 * n → x % n = if x < n then x else x - n := by
    intro x hx; split
    · exact Nat.mod_eq_of_lt (by omega)
    · rw [Nat.mod_eq_sub_mod (by omega), Nat.mod_eq_of_lt (by omega)]
  rw [h1 _ (by omega), h1 _ (by omega)] at e
  split at e <;> split at e <;> omega

/-! ## The reader's group decision on reachable states -/

/-- **Rust's group code on a reachable reader's loaded group is a model step.** For a
`PReachable` state where reader `u` has loaded all of a duplicate-free group `g`, if the bytes
Rust loaded are those of the recorded slots (`ReplicaSync`), Rust's decision on them is the
model's `scanHit` / `scanEmpty` / `scanNext`. -/
theorem reader_group_step {hash : K → Nat} {h2 : Nat → Nat} (hh2 : ∀ h, h2 h < 0x80)
    {mb : List Nat → Nat → List Bool} (hmb : MatchOK mb) {s : St K V} (hr : PReachable C s)
    {u st t lv : Nat} {hl : List Nat} {k : K} {pre g rest : List Nat} {obs : List (Nat × Slot K V)}
    (hrd : s.rd u = .scanning st hl k t lv pre g [] obs rest) (hnd : g.Nodup)
    {bs : List Nat} (hsync : ReplicaSync hash h2 bs (g.map (obsSlot obs))) :
    match groupDecide mb (h2 (hash k)) k bs (g.map (obsSlot obs)) with
    | .found _ v => Step C s (setRd s u (.returned st hl k t lv (some v)))
    | .stop => Step C s (setRd s u (.returned st hl k t lv none))
    | .next => Step C s (setRd s u (.probing st hl k t lv (pre ++ g) rest)) := by
  have hp := reachable_obsPerm C hr.reachable u
  rw [hrd] at hp; simp only [ObsPerm, List.append_nil] at hp
  have ho := obsOf_of_perm hp hnd
  have hnm : ∀ x ∈ g.map (obsSlot obs), ∀ k v, x ≠ .mistagged k v := by
    have := (preachable_noMis C hr).2 u; rw [hrd] at this
    intro x hx k' v' e
    obtain ⟨j, hj, rfl⟩ := List.mem_map.mp hx
    have hjo : (j, obsSlot obs j) ∈ obs :=
      (mem_obs_iff (hp.nodup_iff.mpr hnd) j _).2 ⟨hp.mem_iff.mpr hj, rfl⟩
    exact this _ hjo k' v' e
  have hl' := loaded_canon (W := g.length) (hash := hash) (h2 := h2) (k := k) (by simp) hnm
  rw [← hsync] at hl'
  exact rust_group_step C hl' hmb hh2 ho s u st hl t lv pre g rest hrd

/-- Conversely, every model decision enabled on such a group is the decision Rust makes. -/
theorem reader_model_rust {hash : K → Nat} {h2 : Nat → Nat} (hh2 : ∀ h, h2 h < 0x80)
    {mb : List Nat → Nat → List Bool} (hmb : MatchOK mb) {s : St K V} (hr : PReachable C s)
    {u st t lv : Nat} {hl : List Nat} {k : K} {pre g rest : List Nat} {obs : List (Nat × Slot K V)}
    (hrd : s.rd u = .scanning st hl k t lv pre g [] obs rest) (hnd : g.Nodup)
    {bs : List Nat} (hsync : ReplicaSync hash h2 bs (g.map (obsSlot obs))) :
    ((∃ j v, (j, Slot.full k v) ∈ obs) →
      ∃ b v, groupDecide mb (h2 (hash k)) k bs (g.map (obsSlot obs)) = .found b v ∧
        (g.getD b 0, Slot.full k v) ∈ obs) ∧
    ((∀ i w, (i, Slot.full k w) ∉ obs) → (∃ j, (j, (Slot.empty : Slot K V)) ∈ obs) →
      groupDecide mb (h2 (hash k)) k bs (g.map (obsSlot obs)) = .stop) ∧
    ((∀ i w, (i, Slot.full k w) ∉ obs) → (∀ i, (i, (Slot.empty : Slot K V)) ∉ obs) →
      groupDecide mb (h2 (hash k)) k bs (g.map (obsSlot obs)) = .next) := by
  have hp := reachable_obsPerm C hr.reachable u
  rw [hrd] at hp; simp only [ObsPerm, List.append_nil] at hp
  have ho := obsOf_of_perm hp hnd
  have hnm : ∀ x ∈ g.map (obsSlot obs), ∀ k v, x ≠ .mistagged k v := by
    have := (preachable_noMis C hr).2 u; rw [hrd] at this
    intro x hx k' v' e
    obtain ⟨j, hj, rfl⟩ := List.mem_map.mp hx
    have hjo : (j, obsSlot obs j) ∈ obs :=
      (mem_obs_iff (hp.nodup_iff.mpr hnd) j _).2 ⟨hp.mem_iff.mpr hj, rfl⟩
    exact this _ hjo k' v' e
  have hl' := loaded_canon (W := g.length) (hash := hash) (h2 := h2) (k := k) (by simp) hnm
  rw [← hsync] at hl'
  exact ⟨model_hit_rust hl' hmb hh2 ho, model_empty_rust hl' hmb hh2 ho,
    model_next_rust hl' hmb hh2 ho⟩

end Bytes
end SyncTable
