import SyncTable.Bytes
import SyncTable.Model

/-!
# The concurrent reader's group decision is Rust's group code on the loaded bytes

`Model.lean` lets a reader decide on a loaded group only through its observed slots `obs`
(`Step.scanHit` / `scanEmpty` / `scanNext`). Rust decides on the `W` bytes `Group::load`
returned, which may come from different moments (shearing): the `match_byte` bits in order with
`eq` on each, then `match_empty`. This file shows the two agree, for any `match_byte`
satisfying `MatchOK` (generic or SSE2) and any shearing:

* `groupDecide mb tag k bs os`: Rust's decision on loaded bytes `bs` whose buckets were
  observed as `os` (byte `b` encodes `os[b]`, `Loaded`).
* `groupDecide_found` / `_stop` / `_next`: each Rust outcome holds exactly when the
  corresponding model premise holds on the observed slots.
* `rust_group_step`: Rust's outcome is a `Step` of the model (when `obs` lists the observed
  slots of the group's buckets, `ObsOf`). `model_hit_rust`, `model_empty_rust`,
  `model_next_rust`: whenever a model step is enabled, Rust takes the same kind of step.
* `scan_eq_scanB`: on a static table, the per-group part of `Bytes.search` is `groupDecide`'s
  `scanB` with `os[b] = T.slot ((pos + b) % n)`.

Assumptions (hypotheses, not proved from `Model.lean`): `Loaded` (each loaded byte encodes the
slot the model observed for that bucket, i.e. the `Acquire` load of a byte sees the state that
the `scanLoad` step recorded, including for the mirrored trailing bytes, whose replica store
`set_ctrl_release` makes second; that is weak-memory property 18), no mistagged bucket of `k`
among the observed slots (`ProbeOK` excludes `insertMis`), and `ObsOf` (after the `W`
`scanLoad`s, `obs` holds exactly the group's buckets with their observed slots).
The model allows a hit on any loaded match; Rust takes the lowest bit, one of them.
-/

namespace SyncTable
namespace Bytes

variable {K V : Type} [DecidableEq K]

/-- `eq` on an observed slot (a full bucket keeps its key until freed). -/
def lookSlot (k : K) : Slot K V → Option V
  | .full k' v | .mistagged k' v | .deleted k' v => if k' = k then some v else none
  | .empty => none

/-- `bitmask.next()` / `eq` over byte indices. -/
def scanB (look : Nat → Option V) : List Nat → Option (Nat × V)
  | [] => none
  | b :: bs => match look b with
    | some v => some (b, v)
    | none => scanB look bs

inductive GDec (V : Type) where
  | found (b : Nat) (v : V)
  | stop
  | next

/-- Rust's decision on one loaded group: bytes `bs`, observed slots `os`. -/
def groupDecide (mb : List Nat → Nat → List Bool) (tag : Nat) (k : K) (bs : List Nat)
    (os : List (Slot K V)) : GDec V :=
  match scanB (fun b => lookSlot k (os.getD b .empty)) (bits (mb bs tag)) with
  | some (b, v) => .found b v
  | none => if (matchEmpty bs).any id then .stop else .next

/-- The `W` loaded bytes encode the observed slots. -/
structure Loaded (W : Nat) (hash : K → Nat) (h2 : Nat → Nat) (k : K) (bs : List Nat)
    (os : List (Slot K V)) : Prop where
  lenb : bs.length = W
  leno : os.length = W
  enc : ∀ b < W, CtrlOK hash h2 (os.getD b .empty) (bs.getD b 0)
  nomis : ∀ b < W, ∀ v, os.getD b .empty ≠ .mistagged k v

omit [DecidableEq K] in
theorem scanB_sound {look : Nat → Option V} :
    ∀ {bs : List Nat} {b : Nat} {v : V}, scanB look bs = some (b, v) → b ∈ bs ∧ look b = some v
  | [], _, _, h => by simp [scanB] at h
  | c :: bs, b, v, h => by
    unfold scanB at h
    split at h
    · rename_i w hw; cases h; exact ⟨by simp, hw⟩
    · have := scanB_sound h; exact ⟨by simp [this.1], this.2⟩

omit [DecidableEq K] in
theorem scanB_complete {look : Nat → Option V} {b : Nat} {v : V} :
    ∀ {bs : List Nat}, b ∈ bs → look b = some v → ∃ p, scanB look bs = some p
  | [], h, _ => by simp at h
  | c :: bs, h, hl => by
    unfold scanB
    split
    · exact ⟨_, rfl⟩
    · rename_i hc
      rcases List.mem_cons.mp h with rfl | h
      · rw [hl] at hc; cases hc
      · exact scanB_complete h hl

section
variable {W : Nat} {hash : K → Nat} {h2 : Nat → Nat} {k : K} {bs : List Nat}
  {os : List (Slot K V)} {mb : List Nat → Nat → List Bool}

/-- A matched bit that passes `eq` is a full bucket of `k`. -/
theorem found_full (hl : Loaded W hash h2 k bs os) (hmb : MatchOK mb) (hh2 : ∀ h, h2 h < 0x80)
    {b : Nat} {v : V}
    (hs : scanB (fun b => lookSlot k (os.getD b .empty)) (bits (mb bs (h2 (hash k)))) = some (b, v)) :
    b < W ∧ os.getD b .empty = .full k v := by
  obtain ⟨hb, hk⟩ := scanB_sound hs
  obtain ⟨hlen, hm⟩ := hmb bs (h2 (hash k)) (hh2 _)
  rw [mem_bits, hlen, hl.lenb] at hb
  have hlt := (hm b (by rw [hl.lenb]; exact hb.1)).2 hb.2
  have he := hl.enc b hb.1
  have hn := hl.nomis b hb.1
  refine ⟨hb.1, ?_⟩
  revert hk he hn
  cases os.getD b .empty with
  | empty => intro hk; simp [lookSlot] at hk
  | full k' v' =>
    intro hk _ _; simp only [lookSlot] at hk; split at hk
    · rename_i e; cases hk; rw [e]
    · cases hk
  | mistagged k' v' =>
    intro hk _ hn; simp only [lookSlot] at hk; split at hk
    · rename_i e; subst e; exact (hn v' rfl).elim
    · cases hk
  | deleted k' v' => intro _ he; simp only [CtrlOK, DELETED] at he; rw [he] at hlt; omega

omit [DecidableEq K] in
theorem empty_iff (hl : Loaded W hash h2 k bs os) (hh2 : ∀ h, h2 h < 0x80) :
    (matchEmpty bs).any id = true ↔ ∃ b < W, os.getD b .empty = .empty := by
  have key : ∀ b < W, matchEmptyByte (bs.getD b 0) = (os.getD b .empty).isEmpty := by
    intro b hb
    have he := hl.enc b hb
    revert he
    cases os.getD b .empty with
    | empty => intro he; simp only [CtrlOK] at he; rw [he]; rfl
    | full k' v' => intro he; simp only [CtrlOK] at he; rw [he, matchEmptyByte_lt _ (hh2 _)]; rfl
    | mistagged k' v' => intro he; rw [matchEmptyByte_lt _ he.1]; rfl
    | deleted k' v' => intro he; simp only [CtrlOK] at he; rw [he]; rfl
  simp only [List.any_eq_true, id, matchEmpty, List.mem_map]
  constructor
  · rintro ⟨_, ⟨c, hc, he⟩, rfl⟩
    obtain ⟨b, hb, rfl⟩ := List.mem_iff_getElem.mp hc
    rw [hl.lenb] at hb
    refine ⟨b, hb, ?_⟩
    have := key b hb
    rw [List.getD_eq_getElem?_getD, List.getElem?_eq_getElem (by rw [hl.lenb]; exact hb),
      Option.getD_some, he] at this
    revert this; cases os.getD b .empty <;> simp [Slot.isEmpty]
  · rintro ⟨b, hb, he⟩
    have := key b hb
    rw [he] at this
    refine ⟨true, ⟨bs.getD b 0, ?_, this⟩, rfl⟩
    rw [List.getD_eq_getElem?_getD, List.getElem?_eq_getElem (by rw [hl.lenb]; exact hb)]
    exact List.getElem_mem _

/-- **Rust returns a match exactly when an observed bucket is a full bucket of `k`** (the
`scanHit` premise), and then the bucket it returns is one. -/
theorem groupDecide_found (hl : Loaded W hash h2 k bs os) (hmb : MatchOK mb)
    (hh2 : ∀ h, h2 h < 0x80) :
    (∀ b v, groupDecide mb (h2 (hash k)) k bs os = .found b v → b < W ∧ os.getD b .empty = .full k v) ∧
    ((∃ b v, groupDecide mb (h2 (hash k)) k bs os = .found b v) ↔
      ∃ b < W, ∃ v, os.getD b .empty = .full k v) := by
  have sound : ∀ b v, groupDecide mb (h2 (hash k)) k bs os = .found b v →
      b < W ∧ os.getD b .empty = .full k v := by
    intro b v h
    unfold groupDecide at h
    split at h
    · rename_i b' v' hs; cases h; exact found_full hl hmb hh2 hs
    · split at h <;> cases h
  refine ⟨sound, ⟨fun ⟨b, v, h⟩ => ⟨b, (sound b v h).1, v, (sound b v h).2⟩, ?_⟩⟩
  rintro ⟨b, hb, v, hf⟩
  obtain ⟨hlen, hm⟩ := hmb bs (h2 (hash k)) (hh2 _)
  have hbit := (hm b (by rw [hl.lenb]; exact hb)).1 (by
    have := hl.enc b hb; rw [hf] at this; exact this)
  obtain ⟨p, hp⟩ := scanB_complete (look := fun b => lookSlot k (os.getD b .empty)) (v := v)
    (mem_bits.mpr ⟨by rw [hlen, hl.lenb]; exact hb, hbit⟩)
    (by show lookSlot k (os.getD b .empty) = some v; rw [hf]; simp [lookSlot])
  unfold groupDecide; rw [hp]; exact ⟨p.1, p.2, rfl⟩

theorem groupDecide_not_found (hl : Loaded W hash h2 k bs os) (hmb : MatchOK mb)
    (hh2 : ∀ h, h2 h < 0x80) (hnf : ∀ b < W, ∀ v, os.getD b .empty ≠ .full k v) :
    groupDecide mb (h2 (hash k)) k bs os =
      if (matchEmpty bs).any id then .stop else .next := by
  unfold groupDecide
  split
  · rename_i b v hs
    exact absurd (found_full hl hmb hh2 hs).2 (hnf b (found_full hl hmb hh2 hs).1 v)
  · rfl

/-- **Rust stops (`match_empty`) exactly on the `scanEmpty` premise.** -/
theorem groupDecide_stop (hl : Loaded W hash h2 k bs os) (hmb : MatchOK mb)
    (hh2 : ∀ h, h2 h < 0x80) :
    groupDecide mb (h2 (hash k)) k bs os = .stop ↔
      (∀ b < W, ∀ v, os.getD b .empty ≠ .full k v) ∧ ∃ b < W, os.getD b .empty = .empty := by
  constructor
  · intro h
    have hnf : ∀ b < W, ∀ v, os.getD b .empty ≠ .full k v := by
      intro b hb v hf
      obtain ⟨b', v', h'⟩ := (groupDecide_found hl hmb hh2).2.2 ⟨b, hb, v, hf⟩
      rw [h] at h'; cases h'
    refine ⟨hnf, ?_⟩
    rw [groupDecide_not_found hl hmb hh2 hnf] at h
    split at h
    · rename_i he; exact (empty_iff hl hh2).1 he
    · cases h
  · rintro ⟨hnf, he⟩
    rw [groupDecide_not_found hl hmb hh2 hnf, if_pos ((empty_iff hl hh2).2 he)]

/-- **Rust moves to the next group exactly on the `scanNext` premise.** -/
theorem groupDecide_next (hl : Loaded W hash h2 k bs os) (hmb : MatchOK mb)
    (hh2 : ∀ h, h2 h < 0x80) :
    groupDecide mb (h2 (hash k)) k bs os = .next ↔
      (∀ b < W, ∀ v, os.getD b .empty ≠ .full k v) ∧ ∀ b < W, os.getD b .empty ≠ .empty := by
  constructor
  · intro h
    have hnf : ∀ b < W, ∀ v, os.getD b .empty ≠ .full k v := by
      intro b hb v hf
      obtain ⟨b', v', h'⟩ := (groupDecide_found hl hmb hh2).2.2 ⟨b, hb, v, hf⟩
      rw [h] at h'; cases h'
    refine ⟨hnf, fun b hb he => ?_⟩
    rw [groupDecide_not_found hl hmb hh2 hnf, if_pos ((empty_iff hl hh2).2 ⟨b, hb, he⟩)] at h
    cases h
  · rintro ⟨hnf, hne⟩
    rw [groupDecide_not_found hl hmb hh2 hnf, if_neg]
    intro he; obtain ⟨b, hb, h⟩ := (empty_iff hl hh2).1 he; exact hne b hb h

/-! ## The model's steps -/

/-- `obs` (what the `scanLoad`s recorded) lists bucket `idx b` with observed slot `os[b]`. -/
def ObsOf (W : Nat) (idx : Nat → Nat) (os : List (Slot K V)) (obs : List (Nat × Slot K V)) : Prop :=
  ∀ j s, (j, s) ∈ obs ↔ ∃ b < W, j = idx b ∧ s = os.getD b .empty

omit [DecidableEq K] in
theorem obs_full {idx : Nat → Nat} {obs : List (Nat × Slot K V)} (ho : ObsOf W idx os obs) :
    (∃ j v, (j, Slot.full k v) ∈ obs) ↔ ∃ b < W, ∃ v, os.getD b .empty = .full k v := by
  constructor
  · rintro ⟨j, v, h⟩; obtain ⟨b, hb, _, e⟩ := (ho _ _).1 h; exact ⟨b, hb, v, e.symm⟩
  · rintro ⟨b, hb, v, e⟩; exact ⟨idx b, v, (ho _ _).2 ⟨b, hb, rfl, e.symm⟩⟩

omit [DecidableEq K] in
theorem obs_empty {idx : Nat → Nat} {obs : List (Nat × Slot K V)} (ho : ObsOf W idx os obs) :
    (∃ j, (j, (Slot.empty : Slot K V)) ∈ obs) ↔ ∃ b < W, os.getD b .empty = .empty := by
  constructor
  · rintro ⟨j, h⟩; obtain ⟨b, hb, _, e⟩ := (ho _ _).1 h; exact ⟨b, hb, e.symm⟩
  · rintro ⟨b, hb, e⟩; exact ⟨idx b, (ho _ _).2 ⟨b, hb, rfl, e.symm⟩⟩

variable (C : Cfg K)

/-- **Every decision Rust's group code makes on the loaded bytes is a model step.** -/
theorem rust_group_step (hl : Loaded W hash h2 k bs os) (hmb : MatchOK mb)
    (hh2 : ∀ h, h2 h < 0x80) {idx : Nat → Nat} {obs : List (Nat × Slot K V)}
    (ho : ObsOf W idx os obs) (s : St K V) (u st : Nat) (h : List Nat) (t lv : Nat)
    (pre g rest : List Nat) (hrd : s.rd u = .scanning st h k t lv pre g [] obs rest) :
    match groupDecide mb (h2 (hash k)) k bs os with
    | .found _ v => Step C s (setRd s u (.returned st h k t lv (some v)))
    | .stop => Step C s (setRd s u (.returned st h k t lv none))
    | .next => Step C s (setRd s u (.probing st h k t lv (pre ++ g) rest)) := by
  have hnf_obs : (∀ b < W, ∀ v, os.getD b .empty ≠ .full k v) →
      ∀ i w, (i, Slot.full k w) ∉ obs := fun hnf i w hm =>
    by obtain ⟨b, hb, w', e⟩ := (obs_full ho).1 ⟨i, w, hm⟩; exact hnf b hb w' e
  cases hd : groupDecide mb (h2 (hash k)) k bs os with
  | found b v =>
    obtain ⟨hb, hf⟩ := (groupDecide_found hl hmb hh2).1 b v hd
    exact .scanHit s u st h k t lv pre g obs rest (idx b) v hrd ((ho _ _).2 ⟨b, hb, rfl, hf.symm⟩)
  | stop =>
    obtain ⟨hnf, he⟩ := (groupDecide_stop hl hmb hh2).1 hd
    obtain ⟨j, hj⟩ := (obs_empty ho).2 he
    exact .scanEmpty s u st h k t lv pre g obs rest j hrd (hnf_obs hnf) hj
  | next =>
    obtain ⟨hnf, hne⟩ := (groupDecide_next hl hmb hh2).1 hd
    exact .scanNext s u st h k t lv pre g obs rest hrd (hnf_obs hnf)
      (fun i hi => by obtain ⟨b, hb, e⟩ := (obs_empty ho).1 ⟨i, hi⟩; exact hne b hb e)

/-- **The model's `scanHit` premise forces Rust to return a match** (the bucket Rust returns is
an observed full bucket of `k`, i.e. also a `scanHit`). -/
theorem model_hit_rust (hl : Loaded W hash h2 k bs os) (hmb : MatchOK mb)
    (hh2 : ∀ h, h2 h < 0x80) {idx : Nat → Nat} {obs : List (Nat × Slot K V)}
    (ho : ObsOf W idx os obs) (hm : ∃ j v, (j, Slot.full k v) ∈ obs) :
    ∃ b v, groupDecide mb (h2 (hash k)) k bs os = .found b v ∧ (idx b, Slot.full k v) ∈ obs := by
  obtain ⟨b, v, hd⟩ := (groupDecide_found hl hmb hh2).2.2 ((obs_full ho).1 hm)
  obtain ⟨hb, hf⟩ := (groupDecide_found hl hmb hh2).1 b v hd
  exact ⟨b, v, hd, (ho _ _).2 ⟨b, hb, rfl, hf.symm⟩⟩

/-- The `scanEmpty` premise forces Rust to stop. -/
theorem model_empty_rust (hl : Loaded W hash h2 k bs os) (hmb : MatchOK mb)
    (hh2 : ∀ h, h2 h < 0x80) {idx : Nat → Nat} {obs : List (Nat × Slot K V)}
    (ho : ObsOf W idx os obs) (hnf : ∀ i w, (i, Slot.full k w) ∉ obs)
    (he : ∃ j, (j, (Slot.empty : Slot K V)) ∈ obs) :
    groupDecide mb (h2 (hash k)) k bs os = .stop :=
  (groupDecide_stop hl hmb hh2).2
    ⟨fun b hb v e => hnf (idx b) v ((ho _ _).2 ⟨b, hb, rfl, e.symm⟩), (obs_empty ho).1 he⟩

/-- The `scanNext` premise forces Rust to move on. -/
theorem model_next_rust (hl : Loaded W hash h2 k bs os) (hmb : MatchOK mb)
    (hh2 : ∀ h, h2 h < 0x80) {idx : Nat → Nat} {obs : List (Nat × Slot K V)}
    (ho : ObsOf W idx os obs) (hnf : ∀ i w, (i, Slot.full k w) ∉ obs)
    (hne : ∀ i, (i, (Slot.empty : Slot K V)) ∉ obs) :
    groupDecide mb (h2 (hash k)) k bs os = .next :=
  (groupDecide_next hl hmb hh2).2
    ⟨fun b hb v e => hnf (idx b) v ((ho _ _).2 ⟨b, hb, rfl, e.symm⟩),
     fun b hb e => hne (idx b) ((ho _ _).2 ⟨b, hb, rfl, e.symm⟩)⟩

end

/-! ## The static `search` uses the same group step -/

omit [DecidableEq K] in
theorem lookK_eq [DecidableEq K] (T : Table K V) (k : K) (i : Nat) :
    lookK T k i = lookSlot k (T.slot i) := by
  unfold lookK lookSlot; cases T.slot i <;> rfl

theorem scan_eq_scanB {T : Table K V} (hn : T.n.isPowerOfTwo) (k : K) (pos : Nat) :
    ∀ bs : List Nat, scan T.n (lookK T k) pos bs =
      (scanB (fun b => lookSlot k (T.slot ((pos + b) % T.n))) bs).map
        (fun p => ((pos + p.1) % T.n, p.2))
  | [] => rfl
  | b :: bs => by
    unfold scan scanB
    rw [mask_eq hn, lookK_eq]
    cases lookSlot k (T.slot ((pos + b) % T.n)) with
    | some v => rfl
    | none => exact scan_eq_scanB hn k pos bs

end Bytes
end SyncTable
