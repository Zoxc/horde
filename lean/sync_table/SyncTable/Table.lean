import SyncTable.Capacity

/-!
# Sequential model of one `TableInfo` + bucket array

A table is `n` buckets (`bucket_mask + 1`), a control state per bucket, and the
`growth_left` / `tombstones` counters. The control byte and the bucket contents are merged
into one `Slot`:

* `EMPTY`             ↦ `Slot.empty`
* `h2(hash)` (full)   ↦ `Slot.full k v`
* `h2(hash)` (full) where `hash` is not `k`'s hash and `h2(hash) ≠ h2(hash_key(k))`
                      ↦ `Slot.mistagged k v` (written by an insert given a wrong hash)
* `DELETED`           ↦ `Slot.deleted k v` (the bucket still holds the pair: `remove` does
  not drop it, readers may still hold references until the table is freed).

`h2` is a filter in front of `eq`. For a bucket whose tag is `k`'s own `h2`, comparing keys
directly is equivalent. A `mistagged` bucket is matched by no lookup: a lookup of `k` fails
`match_byte`, and a lookup of any other key fails `eq`. It is still a full bucket for probing,
counting and iteration.

Probing is abstract: `Cfg.seq n h` is the list of bucket indices `search` /
`find_insert_slot` visit for hash `h` in a table of `n` buckets (the group-wise triangular
probe flattened into single buckets; see `Probe.lean` and MAPPING.md).
-/

namespace SyncTable

inductive Slot (K V : Type) where
  | empty
  | full (k : K) (v : V)
  /-- a full bucket holding `k` whose control byte is not `h2` of `k`'s hash -/
  | mistagged (k : K) (v : V)
  | deleted (k : K) (v : V)

def Slot.isEmpty {K V} : Slot K V → Bool
  | .empty => true
  | _ => false

def Slot.isDel {K V} : Slot K V → Bool
  | .deleted .. => true
  | _ => false

def Slot.isFull {K V} : Slot K V → Bool
  | .full .. => true
  | .mistagged .. => true
  | _ => false

/-- Hashing and probing parameters. `seq_lt`: probe positions are masked by `bucket_mask`. -/
structure Cfg (K : Type) where
  hash : K → Nat
  seq : Nat → Nat → List Nat
  seq_lt : ∀ n h x, x ∈ seq n h → x < n

/-- The probe sequence visits every bucket (proved for the triangular probe on power-of-two
tables, `triSeq_cover` in `Probe.lean`). Needed for termination of `find_insert_slot`, and
through it a hypothesis (`hcov`) of `reachable_sinv`, `preachable_inv` and the main theorems. -/
def Cfg.Cover {K} (C : Cfg K) : Prop := ∀ n h i, n.isPowerOfTwo → i < n → i ∈ C.seq n h

structure Table (K V : Type) where
  n : Nat
  slot : Nat → Slot K V
  growthLeft : Nat
  tombstones : Nat

variable {K V : Type}

def Table.set (T : Table K V) (i : Nat) (s : Slot K V) : Table K V :=
  { T with slot := fun j => if j = i then s else T.slot j }

/-- `cnt p f n`: number of buckets `< n` satisfying `p`. -/
def cnt (p : Slot K V → Bool) (f : Nat → Slot K V) : Nat → Nat
  | 0 => 0
  | n + 1 => cnt p f n + (if p (f n) then 1 else 0)

def notEmpty (s : Slot K V) : Bool := !s.isEmpty

/-- `TableRef::allocate` (all control bytes `EMPTY`). -/
def emptyTable (m : Nat) : Table K V :=
  { n := m, slot := fun _ => .empty, growthLeft := bmc (m - 1), tombstones := 0 }

/-- The table contains the pair `(k, v)` (as a full bucket). -/
def Has (T : Table K V) (k : K) (v : V) : Prop := ∃ i, T.slot i = .full k v

/-- `Clear T i l`: some occurrence of `i` in `l` is preceded only by non-empty buckets,
i.e. a probe along `l` cannot stop before reaching `i`. -/
def Clear (T : Table K V) (i : Nat) : List Nat → Prop
  | [] => False
  | j :: l => j = i ∨ (T.slot j ≠ .empty ∧ Clear T i l)

variable [DecidableEq K] (C : Cfg K)

/-- The probe sequence for key `k` in `T`. -/
def ps (T : Table K V) (k : K) : List Nat := C.seq T.n (C.hash k)

/-- `TableRef::find` (via `search` with the `match_empty` stop condition). -/
def find (T : Table K V) (k : K) : List Nat → Option (Nat × V)
  | [] => none
  | j :: l => match T.slot j with
    | .empty => none
    | .full k' v => if k' = k then some (j, v) else find T k l
    | .mistagged .. => find T k l
    | .deleted .. => find T k l

/-- `find_insert_slot` (and the `Err` slot of `find_potential`): the first `EMPTY` bucket
on the probe sequence. Tombstones are never reused. -/
def firstEmpty (T : Table K V) (l : List Nat) : Option Nat := l.find? (fun i => (T.slot i).isEmpty)

/-- `record_item_insert_at` after writing the bucket. -/
def insertAt (T : Table K V) (i : Nat) (k : K) (v : V) : Table K V :=
  { T.set i (.full k v) with growthLeft := T.growthLeft - 1 }

/-- `record_item_insert_at` for an insert given a hash whose `h2` is not `k`'s. -/
def insertMis (T : Table K V) (i : Nat) (k : K) (v : V) : Table K V :=
  { T.set i (.mistagged k v) with growthLeft := T.growthLeft - 1 }

/-- The body of `Write::remove` once `find` returned bucket `i`. -/
def removeAt (T : Table K V) (i : Nat) (k : K) (v : V) : Table K V :=
  { T.set i (.deleted k v) with tombstones := T.tombstones + 1 }

/-- `Write::insert_new` without expansion / `prepare_insert_slot` in `from_iter`. -/
def insertNew (T : Table K V) (k : K) (v : V) : Table K V :=
  match firstEmpty T (ps C T k) with
  | some i => insertAt T i k v
  | none => T

/-- `TableRef::from_iter`: insert the items one by one into a fresh table of `m` buckets. -/
def build (m : Nat) (l : List (K × V)) : Table K V :=
  l.foldl (fun T p => insertNew C T p.1 p.2) (emptyTable m)

/-- The full buckets in index order (what `RawIterRange` yields). -/
def items (T : Table K V) : List (K × V) :=
  (List.range T.n).filterMap (fun i => match T.slot i with
    | .full k v => some (k, v)
    | .mistagged k v => some (k, v)
    | _ => none)

/-- Well-formedness of a table. -/
structure WF (T : Table K V) : Prop where
  pow2 : T.n.isPowerOfTwo
  bound : ∀ i, T.n ≤ i → T.slot i = .empty
  /-- the probe invariant: every full bucket is reachable from its key's probe start
  without crossing an `EMPTY` bucket -/
  noHole : ∀ i k v, T.slot i = .full k v → Clear T i (ps C T k)
  /-- `growth_left` accounting: occupied buckets + `growth_left` = capacity -/
  count : cnt notEmpty T.slot T.n + T.growthLeft = bmc (T.n - 1)
  tomb : cnt Slot.isDel T.slot T.n = T.tombstones
  /-- every full bucket carries its key's own tag (only an insert given a wrong hash breaks
  this, `Step.insertMis`) -/
  noMis : ∀ i k v, T.slot i ≠ .mistagged k v

/-- The memory-layout part of `WF`, without the probe invariant `noHole`. It holds for every
reachable table even when an insert puts a key off its probe sequence
(`Step.insertAny`, see `Safety.lean`): bucket bounds and the `growth_left`/`tombstones`
accounting do not depend on where a key sits. -/
structure SWF (T : Table K V) : Prop where
  pow2 : T.n.isPowerOfTwo
  bound : ∀ i, T.n ≤ i → T.slot i = .empty
  count : cnt notEmpty T.slot T.n + T.growthLeft = bmc (T.n - 1)
  tomb : cnt Slot.isDel T.slot T.n = T.tombstones

theorem WF.swf {C : Cfg K} {T : Table K V} (h : WF C T) : SWF T :=
  ⟨h.pow2, h.bound, h.count, h.tomb⟩

/-- Key uniqueness. This is what the `insert_new` / `replace` contract maintains. It is
deliberately not part of `WF`: violating the contract creates duplicate keys (a logic error),
and the memory-layout invariant `WF` and memory safety do not depend on it. -/
def Uniq (T : Table K V) : Prop :=
  ∀ i j k v w, T.slot i = .full k v → T.slot j = .full k w → i = j

theorem WF.pos {C : Cfg K} {T : Table K V} (h : WF C T) : 0 < T.n := Nat.pos_of_isPowerOfTwo h.pow2

/-! ## Counting lemmas -/

theorem cnt_le (p : Slot K V → Bool) (f) (n : Nat) : cnt p f n ≤ n := by
  induction n with
  | zero => simp [cnt]
  | succ n ih => simp only [cnt]; split <;> omega

theorem cnt_all (p : Slot K V → Bool) (f) (n : Nat) (h : ∀ i, i < n → p (f i) = true) :
    cnt p f n = n := by
  induction n with
  | zero => rfl
  | succ n ih =>
    simp only [cnt, h n (Nat.lt_succ_self n), ite_true]
    rw [ih (fun i hi => h i (by omega))]

theorem cnt_congr (p : Slot K V → Bool) (f g) (n : Nat) (h : ∀ i, i < n → p (f i) = p (g i)) :
    cnt p f n = cnt p g n := by
  induction n with
  | zero => rfl
  | succ n ih => simp only [cnt, h n (by omega), ih (fun i hi => h i (by omega))]

theorem cnt_set (p : Slot K V → Bool) (f : Nat → Slot K V) (i : Nat) (s : Slot K V) (n : Nat)
    (hi : i < n) :
    cnt p (fun j => if j = i then s else f j) n + (if p (f i) then 1 else 0) =
      cnt p f n + (if p s then 1 else 0) := by
  induction n with
  | zero => omega
  | succ n ih =>
    simp only [cnt]
    by_cases h : i = n
    · subst h
      have : cnt p (fun j => if j = i then s else f j) i = cnt p f i :=
        cnt_congr _ _ _ _ (fun j hj => by simp [Nat.ne_of_lt hj])
      simp only [ite_true, this]; omega
    · have := ih (by omega)
      simp only [show n ≠ i from fun e => h e.symm, ite_false]; omega

theorem cnt_split (f : Nat → Slot K V) (n : Nat) :
    cnt notEmpty f n = cnt Slot.isFull f n + cnt Slot.isDel f n := by
  induction n with
  | zero => rfl
  | succ n ih =>
    simp only [cnt, ih]
    cases f n <;> simp [notEmpty, Slot.isEmpty, Slot.isFull, Slot.isDel] <;> omega

/-! ## `Clear` and probing -/

theorem Clear.mono {T T' : Table K V} {i : Nat} {l : List Nat}
    (hm : ∀ j, T.slot j ≠ .empty → T'.slot j ≠ .empty) : Clear T i l → Clear T' i l := by
  induction l with
  | nil => intro h; exact h
  | cons j l ih =>
    intro h; rcases h with h | ⟨h1, h2⟩
    · exact Or.inl h
    · exact Or.inr ⟨hm j h1, ih h2⟩

theorem Clear.mem {T : Table K V} {i : Nat} {l : List Nat} : Clear T i l → i ∈ l := by
  induction l with
  | nil => intro h; exact h.elim
  | cons j l ih =>
    intro h; rcases h with h | ⟨_, h2⟩
    · simp [h]
    · exact List.mem_cons_of_mem _ (ih h2)

/-- `Clear` through a prefix: either `i` is in the prefix, or it is `Clear` in the rest. -/
theorem Clear.append {T : Table K V} {i : Nat} {pre l : List Nat} :
    Clear T i (pre ++ l) → i ∈ pre ∨ Clear T i l := by
  induction pre with
  | nil => intro h; exact Or.inr h
  | cons j pre ih =>
    intro h; rcases h with h | ⟨_, h2⟩
    · left; simp [h]
    · rcases ih h2 with h | h
      · left; exact List.mem_cons_of_mem _ h
      · right; exact h

theorem find_sound (T : Table K V) (k : K) (l : List Nat) (i : Nat) (v : V) :
    find T k l = some (i, v) → T.slot i = .full k v := by
  induction l with
  | nil => simp [find]
  | cons j l ih =>
    simp only [find]
    split
    · simp
    · rename_i k' v' h; split
      · rename_i e; intro hh; cases hh; rw [h, e]
      · exact ih
    · exact ih
    · exact ih

/-- A key whose bucket is `Clear` along `l` is found by `find`. -/
theorem find_complete (T : Table K V) (k : K) (i : Nat) (v : V) (hu : ∀ j w, T.slot j = .full k w → j = i)
    (hi : T.slot i = .full k v) (l : List Nat) (hc : Clear T i l) : find T k l = some (i, v) := by
  induction l with
  | nil => exact hc.elim
  | cons j l ih =>
    simp only [find]
    rcases hc with e | ⟨hne, hc⟩
    · subst e; simp [hi]
    · split
      · contradiction
      · rename_i k' v' h; split
        · rename_i e; subst e; have := hu j v' h; subst this; rw [hi] at h; cases h; rfl
        · exact ih hc
      · exact ih hc
      · exact ih hc

/-- **`find` is correct** on a well-formed table. -/
theorem find_spec {T : Table K V} (hw : WF C T) (hu : Uniq T) (k : K) :
    (∀ i v, find T k (ps C T k) = some (i, v) ↔ T.slot i = .full k v) ∧
    (find T k (ps C T k) = none ↔ ∀ v, ¬ Has T k v) := by
  have hc : ∀ i v, T.slot i = .full k v → find T k (ps C T k) = some (i, v) := fun i v h =>
    find_complete T k i v (fun j w hj => hu _ _ _ _ _ hj h) h _ (hw.noHole _ _ _ h)
  refine ⟨fun i v => ⟨find_sound T k _ i v, hc i v⟩, ⟨?_, ?_⟩⟩
  · intro hn v ⟨i, hi⟩; rw [hc i v hi] at hn; cases hn
  · intro h; cases hf : find T k (ps C T k) with
    | none => rfl
    | some p => exact (h p.2 ⟨p.1, find_sound T k _ p.1 p.2 hf⟩).elim

theorem firstEmpty_spec {T : Table K V} {l : List Nat} {i : Nat} (h : firstEmpty T l = some i) :
    T.slot i = .empty ∧ ∃ pre rest, l = pre ++ i :: rest ∧ ∀ j ∈ pre, T.slot j ≠ .empty := by
  unfold firstEmpty at h
  induction l with
  | nil => simp at h
  | cons j l ih =>
    simp only [List.find?_cons] at h
    split at h
    · rename_i he; cases h
      refine ⟨by cases hs : T.slot i <;> simp_all [Slot.isEmpty], [], l, rfl, by simp⟩
    · rename_i he
      obtain ⟨h1, pre, rest, hl, hp⟩ := ih h
      refine ⟨h1, j :: pre, rest, by simp [hl], ?_⟩
      intro x hx; simp at hx; rcases hx with rfl | hx
      · intro e; simp [e, Slot.isEmpty] at he
      · exact hp x hx

theorem clear_of_split {T : Table K V} {i : Nat} (pre rest : List Nat)
    (hp : ∀ j ∈ pre, T.slot j ≠ .empty) : Clear T i (pre ++ i :: rest) := by
  induction pre with
  | nil => exact Or.inl rfl
  | cons j pre ih => exact Or.inr ⟨hp j (by simp), ih (fun x hx => hp x (by simp [hx]))⟩

/-- `find_insert_slot` terminates: a table satisfying `SWF` always has an `EMPTY` bucket on any
probe sequence (needs `Cover`). -/
theorem firstEmpty_isSome {T : Table K V} (hw : SWF T) (hcov : C.Cover) (k : K) :
    ∃ i, firstEmpty T (ps C T k) = some i := by
  cases h : firstEmpty T (ps C T k) with
  | some i => exact ⟨i, rfl⟩
  | none =>
    exfalso
    unfold firstEmpty at h
    rw [List.find?_eq_none] at h
    have hall : cnt notEmpty T.slot T.n = T.n :=
      cnt_all _ _ _ (fun i hi => by
        have := h i (hcov _ _ _ hw.pow2 hi); simpa [notEmpty] using this)
    have := hw.count; have := bmc_lt T.n (Nat.pos_of_isPowerOfTwo hw.pow2); omega

/-! ## Operations preserve `WF` and have the expected abstract effect -/

theorem set_slot (T : Table K V) (i j : Nat) (s : Slot K V) :
    (T.set i s).slot j = if j = i then s else T.slot j := rfl

theorem insertAt_wf {T : Table K V} (hw : WF C T) {k : K} {v : V} {i : Nat}
    (hg : 0 < T.growthLeft)
    (hfe : firstEmpty T (ps C T k) = some i) :
    WF C (insertAt T i k v) ∧ (∀ k' v', Has (insertAt T i k v) k' v' ↔ Has T k' v' ∨ (k' = k ∧ v' = v)) := by
  obtain ⟨he, pre, rest, hl, hp⟩ := firstEmpty_spec hfe
  have hin : i < T.n := C.seq_lt _ _ _ (by unfold ps at hl; rw [hl]; simp)
  have hm : ∀ j, T.slot j ≠ .empty → (insertAt T i k v).slot j ≠ .empty := by
    intro j hj; simp only [insertAt, set_slot]; split
    · simp
    · exact hj
  have hsl : ∀ j, (insertAt T i k v).slot j = if j = i then .full k v else T.slot j := fun _ => rfl
  refine ⟨⟨hw.pow2, ?_, ?_, ?_, ?_, ?nm⟩, ?_⟩
  case nm =>
    intro j k1 v1 hj; rw [hsl] at hj; split at hj
    · cases hj
    · exact hw.noMis _ _ _ hj
  · intro j hj; rw [hsl]; rw [if_neg (by simp only [insertAt, Table.set] at hj; omega)]
    exact hw.bound j hj
  · intro j k1 v1 hj; rw [hsl] at hj
    show Clear _ j (C.seq T.n _)
    split at hj
    · rename_i e; cases hj; subst e
      apply Clear.mono hm
      have := clear_of_split (T := T) (i := j) pre rest hp
      unfold ps at hl; rw [← hl] at this; exact this
    · exact Clear.mono hm (hw.noHole _ _ _ hj)
  · have := cnt_set notEmpty T.slot i (.full k v) T.n hin
    simp only [he, notEmpty, Slot.isEmpty] at this
    have hc := hw.count
    simp only [insertAt, Table.set]; simp at this; omega
  · have := cnt_set Slot.isDel T.slot i (.full k v) T.n hin
    simp only [he, Slot.isDel] at this
    have := hw.tomb
    simp only [insertAt, Table.set]; simp at *; omega
  · intro k' v'; constructor
    · intro ⟨j, hj⟩; rw [hsl] at hj; split at hj
      · cases hj; exact Or.inr ⟨rfl, rfl⟩
      · exact Or.inl ⟨j, hj⟩
    · intro h; rcases h with ⟨j, hj⟩ | ⟨rfl, rfl⟩
      · refine ⟨j, ?_⟩; rw [hsl, if_neg]; exact hj
        intro e; subst e; rw [he] at hj; cases hj
      · exact ⟨i, by rw [hsl]; simp⟩

/-- Inserting a key that is absent (the `insert_new` contract) keeps keys unique. -/
theorem insertAt_uniq {T : Table K V} (hu : Uniq T) {k : K} {v : V} {i : Nat}
    (habs : ∀ w, ¬ Has T k w) : Uniq (insertAt T i k v) := by
  have hsl : ∀ j, (insertAt T i k v).slot j = if j = i then .full k v else T.slot j := fun _ => rfl
  intro a b k1 v1 w1 ha hb; rw [hsl] at ha hb
  split at ha <;> split at hb
  · omega
  · cases ha; exact (habs w1 ⟨b, hb⟩).elim
  · cases hb; exact (habs v1 ⟨a, ha⟩).elim
  · exact hu _ _ _ _ _ ha hb

/-- Inserting a key that is already present (an `insert_new` contract violation) keeps both
pairs: the table then holds duplicate keys. -/
theorem insertAt_dup {T : Table K V} {k : K} {v w : V} {i j : Nat} (hj : T.slot j = .full k w)
    (hi : T.slot i = .empty) : (insertAt T i k v).slot j = .full k w ∧
      (insertAt T i k v).slot i = .full k v ∧ i ≠ j := by
  have hij : i ≠ j := by rintro rfl; rw [hi] at hj; cases hj
  refine ⟨?_, ?_, hij⟩
  · show (if j = i then _ else _) = _; rw [if_neg (Ne.symm hij)]; exact hj
  · show (if i = i then _ else _) = _; simp

theorem removeAt_wf {T : Table K V} (hw : WF C T) {k : K} {v : V} {i : Nat}
    (hi : T.slot i = .full k v) :
    WF C (removeAt T i k v) ∧
      (∀ k' v', Has (removeAt T i k v) k' v' ↔ ∃ j, j ≠ i ∧ T.slot j = .full k' v') := by
  have hin : i < T.n := Nat.lt_of_not_le (fun h => by rw [hw.bound i h] at hi; cases hi)
  have hsl : ∀ j, (removeAt T i k v).slot j = if j = i then .deleted k v else T.slot j :=
    fun _ => rfl
  have hm : ∀ j, T.slot j ≠ .empty → (removeAt T i k v).slot j ≠ .empty := by
    intro j hj; rw [hsl]; split
    · simp
    · exact hj
  refine ⟨⟨hw.pow2, ?_, ?_, ?_, ?_, ?nm⟩, ?_⟩
  case nm =>
    intro j k1 v1 hj; rw [hsl] at hj; split at hj
    · cases hj
    · exact hw.noMis _ _ _ hj
  · intro j hj; rw [hsl, if_neg (by simp only [removeAt, Table.set] at hj; omega)]
    exact hw.bound j hj
  · intro j k1 v1 hj; rw [hsl] at hj
    split at hj
    · cases hj
    · exact Clear.mono hm (hw.noHole _ _ _ hj)
  · have := cnt_set notEmpty T.slot i (.deleted k v) T.n hin
    simp only [hi, notEmpty, Slot.isEmpty] at this
    have := hw.count
    simp only [removeAt, Table.set]; simp at *; omega
  · have := cnt_set Slot.isDel T.slot i (.deleted k v) T.n hin
    simp only [hi, Slot.isDel] at this
    have := hw.tomb
    simp only [removeAt, Table.set]; simp at *; omega
  · intro k' v'; constructor
    · intro ⟨j, hj⟩; rw [hsl] at hj; split at hj
      · cases hj
      · rename_i hne; exact ⟨j, hne, hj⟩
    · intro ⟨j, hne, hj⟩; exact ⟨j, by rw [hsl, if_neg hne]; exact hj⟩

/-- Writing any key into any in-bounds `EMPTY` bucket (`Step.insertAny`) keeps `SWF`,
wherever the bucket is relative to the key's probe sequence. -/
theorem insertAt_swf {T : Table K V} (hw : SWF T) {k : K} {v : V} {i : Nat}
    (hg : 0 < T.growthLeft) (he : T.slot i = .empty) (hin : i < T.n) :
    SWF (insertAt T i k v) := by
  have hsl : ∀ j, (insertAt T i k v).slot j = if j = i then .full k v else T.slot j := fun _ => rfl
  refine ⟨hw.pow2, ?_, ?_, ?_⟩
  · intro j hj; rw [hsl]; rw [if_neg (by simp only [insertAt, Table.set] at hj; omega)]
    exact hw.bound j hj
  · have := cnt_set notEmpty T.slot i (.full k v) T.n hin
    simp only [he, notEmpty, Slot.isEmpty] at this
    have hc := hw.count
    simp only [insertAt, Table.set]; simp at this; omega
  · have := cnt_set Slot.isDel T.slot i (.full k v) T.n hin
    simp only [he, Slot.isDel] at this
    have := hw.tomb
    simp only [insertAt, Table.set]; simp at *; omega

theorem removeAt_swf {T : Table K V} (hw : SWF T) {k : K} {v : V} {i : Nat}
    (hi : T.slot i = .full k v) : SWF (removeAt T i k v) := by
  have hin : i < T.n := Nat.lt_of_not_le (fun h => by rw [hw.bound i h] at hi; cases hi)
  have hsl : ∀ j, (removeAt T i k v).slot j = if j = i then .deleted k v else T.slot j :=
    fun _ => rfl
  refine ⟨hw.pow2, ?_, ?_, ?_⟩
  · intro j hj; rw [hsl, if_neg (by simp only [removeAt, Table.set] at hj; omega)]
    exact hw.bound j hj
  · have := cnt_set notEmpty T.slot i (.deleted k v) T.n hin
    simp only [hi, notEmpty, Slot.isEmpty] at this
    have := hw.count
    simp only [removeAt, Table.set]; simp at *; omega
  · have := cnt_set Slot.isDel T.slot i (.deleted k v) T.n hin
    simp only [hi, Slot.isDel] at this
    have := hw.tomb
    simp only [removeAt, Table.set]; simp at *; omega

theorem insertMis_swf {T : Table K V} (hw : SWF T) {k : K} {v : V} {i : Nat}
    (hg : 0 < T.growthLeft) (he : T.slot i = .empty) (hin : i < T.n) :
    SWF (insertMis T i k v) := by
  have hsl : ∀ j, (insertMis T i k v).slot j = if j = i then .mistagged k v else T.slot j := fun _ => rfl
  refine ⟨hw.pow2, ?_, ?_, ?_⟩
  · intro j hj; rw [hsl]; rw [if_neg (by simp only [insertMis, Table.set] at hj; omega)]
    exact hw.bound j hj
  · have := cnt_set notEmpty T.slot i (.mistagged k v) T.n hin
    simp only [he, notEmpty, Slot.isEmpty] at this
    have hc := hw.count
    simp only [insertMis, Table.set]; simp at this; omega
  · have := cnt_set Slot.isDel T.slot i (.mistagged k v) T.n hin
    simp only [he, Slot.isDel] at this
    have := hw.tomb
    simp only [insertMis, Table.set]; simp at *; omega

theorem removeAt_swf_mis {T : Table K V} (hw : SWF T) {k : K} {v : V} {i : Nat}
    (hi : T.slot i = .mistagged k v) : SWF (removeAt T i k v) := by
  have hin : i < T.n := Nat.lt_of_not_le (fun h => by rw [hw.bound i h] at hi; cases hi)
  have hsl : ∀ j, (removeAt T i k v).slot j = if j = i then .deleted k v else T.slot j :=
    fun _ => rfl
  refine ⟨hw.pow2, ?_, ?_, ?_⟩
  · intro j hj; rw [hsl, if_neg (by simp only [removeAt, Table.set] at hj; omega)]
    exact hw.bound j hj
  · have := cnt_set notEmpty T.slot i (.deleted k v) T.n hin
    simp only [hi, notEmpty, Slot.isEmpty] at this
    have := hw.count
    simp only [removeAt, Table.set]; simp at *; omega
  · have := cnt_set Slot.isDel T.slot i (.deleted k v) T.n hin
    simp only [hi, Slot.isDel] at this
    have := hw.tomb
    simp only [removeAt, Table.set]; simp at *; omega

/-- With unique keys (the contract), `remove` deletes the key. With duplicates only the
bucket `find` returned is deleted, and other pairs for the key stay (`removeAt_wf`). -/
theorem removeAt_has {T : Table K V} (hu : Uniq T) {k : K} {v : V} {i : Nat}
    (hi : T.slot i = .full k v) (k' : K) (v' : V) :
    Has (removeAt T i k v) k' v' ↔ Has T k' v' ∧ k' ≠ k := by
  have hsl : ∀ j, (removeAt T i k v).slot j = if j = i then .deleted k v else T.slot j :=
    fun _ => rfl
  constructor
  · intro ⟨j, hj⟩; rw [hsl] at hj; split at hj
    · cases hj
    · rename_i hne
      refine ⟨⟨j, hj⟩, ?_⟩; rintro rfl; exact hne (hu _ _ _ _ _ hj hi)
  · intro ⟨⟨j, hj⟩, hne⟩; refine ⟨j, ?_⟩; rw [hsl, if_neg]; exact hj
    intro e; subst e; rw [hi] at hj; cases hj; exact hne rfl

theorem removeAt_uniq {T : Table K V} (hu : Uniq T) (i : Nat) (k : K) (v : V) :
    Uniq (removeAt T i k v) := by
  have hsl : ∀ j, (removeAt T i k v).slot j = if j = i then .deleted k v else T.slot j :=
    fun _ => rfl
  intro a b k1 v1 w1 ha hb; rw [hsl] at ha hb
  split at ha
  · cases ha
  · split at hb
    · cases hb
    · exact hu _ _ _ _ _ ha hb

theorem emptyTable_wf (m : Nat) (hm : m.isPowerOfTwo) : WF C (emptyTable (K := K) (V := V) m) := by
  have h0 : ∀ p : Slot K V → Bool, ∀ n, cnt p (fun _ => .empty) n = cnt p (fun _ => .empty) n := fun _ _ => rfl
  have hz : ∀ n, cnt notEmpty (fun _ => (Slot.empty : Slot K V)) n = 0 := by
    intro n; induction n with
    | zero => rfl
    | succ n ih => simp [cnt, ih, notEmpty, Slot.isEmpty]
  have hd : ∀ n, cnt Slot.isDel (fun _ => (Slot.empty : Slot K V)) n = 0 := by
    intro n; induction n with
    | zero => rfl
    | succ n ih => simp [cnt, ih, Slot.isDel]
  refine ⟨hm, fun _ _ => rfl, ?_, ?_, ?_, fun _ _ _ h => nomatch h⟩
  · intro i _ _ h; cases h
  · simp [emptyTable, hz]
  · simp [emptyTable, hd]

theorem emptyTable_uniq (m : Nat) : Uniq (emptyTable (K := K) (V := V) m) := by
  intro i _ _ _ _ h; cases h

theorem insertNew_eq {T : Table K V} {k : K} {v : V} {i : Nat}
    (h : firstEmpty T (ps C T k) = some i) : insertNew C T k v = insertAt T i k v := by
  simp [insertNew, h]

theorem insertNew_n (T : Table K V) (k : K) (v : V) : (insertNew C T k v).n = T.n := by
  unfold insertNew; split <;> rfl

theorem insertNew_growth (T : Table K V) (k : K) (v : V) (hw : WF C T) (hcov : C.Cover) :
    (insertNew C T k v).growthLeft = T.growthLeft - 1 := by
  obtain ⟨i, hi⟩ := firstEmpty_isSome C hw.swf hcov k
  rw [insertNew_eq C hi]; rfl

/-- **`from_iter` is memory-safe and keeps every pair**: inserting the items one by one gives a
well-formed table containing exactly the old contents plus the list. This holds for any list
(with duplicate keys too: `replace` and `from_iter` do not deduplicate, every pair gets its own
bucket); only `length ≤ growth_left` is needed (`CHECK_LEN` / the `clone_table` capacity). -/
theorem foldl_insert_wf (hcov : C.Cover) : ∀ (l : List (K × V)) (T : Table K V), WF C T →
    l.length ≤ T.growthLeft →
    WF C (l.foldl (fun T p => insertNew C T p.1 p.2) T) ∧
    (∀ k v, Has (l.foldl (fun T p => insertNew C T p.1 p.2) T) k v ↔ Has T k v ∨ (k, v) ∈ l)
  | [], T, hw, _ => ⟨hw, fun k v => by simp⟩
  | (k, v) :: l, T, hw, hlen => by
    simp only [List.foldl_cons]
    obtain ⟨i, hi⟩ := firstEmpty_isSome C hw.swf hcov k
    rw [insertNew_eq C hi]
    simp only [List.length_cons] at hlen
    obtain ⟨hw', hh⟩ := insertAt_wf C hw (v := v) (by omega) hi
    have ih := foldl_insert_wf hcov l (insertAt T i k v) hw' (by simp only [insertAt]; omega)
    refine ⟨ih.1, fun k' v' => ?_⟩
    rw [ih.2, hh]; simp only [List.mem_cons, Prod.mk.injEq, or_assoc]

/-- With distinct new keys (the `replace` contract, and always for `clone_table` of a unique
table), `from_iter` keeps keys unique. -/
theorem foldl_insert_uniq (hcov : C.Cover) : ∀ (l : List (K × V)) (T : Table K V), WF C T →
    Uniq T → l.Pairwise (fun a b => a.1 ≠ b.1) → (∀ p ∈ l, ∀ w, ¬ Has T p.1 w) →
    l.length ≤ T.growthLeft → Uniq (l.foldl (fun T p => insertNew C T p.1 p.2) T)
  | [], _, _, hu, _, _, _ => hu
  | (k, v) :: l, T, hw, hu, hpw, habs, hlen => by
    simp only [List.foldl_cons]
    obtain ⟨i, hi⟩ := firstEmpty_isSome C hw.swf hcov k
    rw [insertNew_eq C hi]
    simp only [List.length_cons] at hlen
    obtain ⟨hw', hh⟩ := insertAt_wf C hw (v := v) (by omega) hi
    rw [List.pairwise_cons] at hpw
    exact foldl_insert_uniq hcov l _ hw' (insertAt_uniq hu (habs (k, v) (by simp))) hpw.2
      (by
        intro p hp w h; rw [hh] at h; rcases h with h | ⟨e, _⟩
        · exact habs p (by simp [hp]) w h
        · exact hpw.1 p hp e.symm)
      (by simp only [insertAt]; omega)

theorem build_wf (hcov : C.Cover) (m : Nat) (hm : m.isPowerOfTwo) (l : List (K × V))
    (hlen : l.length ≤ bmc (m - 1)) :
    WF C (build C m l) ∧ (∀ k v, Has (build C m l) k v ↔ (k, v) ∈ l) := by
  have := foldl_insert_wf C hcov l (emptyTable m) (emptyTable_wf C m hm) hlen
  refine ⟨this.1, fun k v => ?_⟩
  unfold build; rw [this.2]; constructor
  · intro h; rcases h with ⟨_, h⟩ | h
    · cases h
    · exact h
  · exact Or.inr

theorem build_uniq (hcov : C.Cover) (m : Nat) (hm : m.isPowerOfTwo) (l : List (K × V))
    (hpw : l.Pairwise (fun a b => a.1 ≠ b.1)) (hlen : l.length ≤ bmc (m - 1)) :
    Uniq (build C m l) :=
  foldl_insert_uniq C hcov l _ (emptyTable_wf C m hm) (emptyTable_uniq m) hpw
    (fun _ _ _ ⟨_, h⟩ => by cases h) hlen

theorem build_n (m : Nat) (l : List (K × V)) : (build C m l).n = m := by
  unfold build
  suffices ∀ (l : List (K × V)) (T : Table K V), (l.foldl (fun T p => insertNew C T p.1 p.2) T).n = T.n by
    rw [this]; rfl
  intro l; induction l with
  | nil => intro T; rfl
  | cons p l ih => intro T; simp only [List.foldl_cons]; rw [ih, insertNew_n]

/-! ## `items` (iteration over full buckets) -/

theorem mem_items {T : Table K V} (hw : WF C T) (k : K) (v : V) : (k, v) ∈ items T ↔ Has T k v := by
  unfold items; simp only [List.mem_filterMap, List.mem_range]
  constructor
  · intro ⟨i, _, h⟩; refine ⟨i, ?_⟩; split at h
    · rename_i hs; cases h; exact hs
    · rename_i hs; exact absurd hs (hw.noMis _ _ _)
    · cases h
  · intro ⟨i, hi⟩
    refine ⟨i, Nat.lt_of_not_le (fun h => by rw [hw.bound i h] at hi; cases hi), by rw [hi]⟩

theorem items_pairwise {T : Table K V} (hu : Uniq T) (hm : ∀ i k v, T.slot i ≠ .mistagged k v) :
    (items T).Pairwise (fun a b => a.1 ≠ b.1) := by
  unfold items
  apply List.Pairwise.filterMap _ _ (List.nodup_range)
  intro a b hab x hx y hy e
  split at hx <;> split at hy <;> simp at hx hy
  · rename_i k1 v1 h1 _ k2 v2 h2
    subst hx hy; simp at e; subst e
    exact hab (hu _ _ _ _ _ h1 h2)
  all_goals first
    | (rename_i h _ _ _ _; exact absurd h (hm _ _ _))
    | (rename_i h; exact absurd h (hm _ _ _))

theorem items_length (T : Table K V) : (items T).length = cnt Slot.isFull T.slot T.n := by
  unfold items
  generalize T.n = n
  induction n with
  | zero => rfl
  | succ n ih =>
    rw [List.range_succ, List.filterMap_append, List.length_append, ih]
    simp only [cnt, List.filterMap_cons, List.filterMap_nil]
    cases T.slot n <;> rfl

/-- `TableInfo::items` (`capacity - tombstones - growth_left`) is the number of full buckets
(on a quiescent table). -/
theorem items_formula {T : Table K V} (hw : WF C T) :
    (items T).length = bmc (T.n - 1) - T.tombstones - T.growthLeft := by
  rw [items_length]
  have := cnt_split T.slot T.n; have := hw.count; have := hw.tomb; omega

end SyncTable
