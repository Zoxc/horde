import SyncTable.Probe

/-!
# Byte-level control bytes, `Group`, `BitMask` and the sequential `search`

This file closes the byte-level part of property 17 (MAPPING.md) for a quiescent table: Rust's
sequential `search` (`find`, `find_potential`) and `find_insert_slot`, written over the
concrete control-byte array, compute `Table.find` and `Table.firstEmpty` on `triSeq W`.

Model:

* **Control bytes** (`Ctrl`): a function `ctrl : Nat → Nat` read at `[0, n + W)`. Byte `i < n`
  encodes `T.slot i` (`CtrlOK`): `EMPTY = 0xFF`, `DELETED = 0x80`, a full bucket of `k` holds
  `h2 (hash k)`, a mistagged one some other tag `< 0x80`. The trailing `W` bytes mirror the
  first `W` (`mirror`, kept by `setCtrl`, `set_ctrl`). The only table with `n < W` is the
  static empty one: `n = 1`, every byte `EMPTY` (`small`).
* **`h2`** is a parameter with `h2 h < 0x80` (`h2_64` is Rust's 64-bit `h2`).
* **`Group::load`** at `pos` is the list of the `W` bytes `ctrl (pos + b)` (`load`).
* **`BitMask`** is a `List Bool` of width `W`, bit `b` for byte `b` (Rust's masks are
  little-endian after `to_le`, low bit = low address). `lowest_set_bit` is `lsb`, the
  `BitMaskIter` order (lowest bit, then `remove_lowest_bit`) is `bits` (increasing).
* **`match_empty`** is the generic per-byte bit trick `c & (c << 1) & 0x80` (`matchEmptyByte`,
  the neighbour bit shifted in at bit 0 is masked away). SSE2's `match_empty` is
  `cmpeq EMPTY`, which agrees on every control byte (`matchEmptyByte_iff`).
* **`match_byte`** is any function satisfying `MatchOK`: every byte equal to the tag is set,
  and only bytes `< 0x80` (full) are set. SSE2 is exact (`matchByteSSE2_ok`). The generic
  `(cmp - 0x01..) & !cmp & 0x80..` (`cmp = group ^ repeat(tag)`) has false positives; it is
  modelled with an explicit byte-serial borrow chain in either direction (`matchByteLE`,
  `matchByteBE`, little- and big-endian targets) and satisfies `MatchOK` for any borrows
  (`matchByteLE_ok`, `matchByteBE_ok`). That the borrow chain is word subtraction is by
  inspection, not proved.
* **`ProbeSeq`**: `pos = h1(hash) & bucket_mask`, `stride = 0`; `move_next` does
  `stride += W; pos = (pos + stride) & bucket_mask`. `h1` is the identity, and `wrapping_sub`
  in `set_ctrl` is `(i + n - W) % n` after masking (`n` divides `2^usize`).
* **`search`** is Rust's loop with a fuel bound (`n / W` groups): iterate the `match_byte`
  bits of the current group, `eq` on each (`scan`), then the `stop` closure, then `move_next`.
  Running out of fuel (`SRes.exhausted`) is shown not to happen on `WF` tables.

Results: `findInsertSlot_eq`, `search_find_eq`, `search_potential_eq`, `setCtrl_ctrl`.
-/

namespace SyncTable
namespace Bytes

def EMPTY : Nat := 0xFF
def DELETED : Nat := 0x80

/-- Rust's `h2` on a 64-bit target: the top 7 bits of the hash. -/
def h2_64 (h : Nat) : Nat := (h >>> 57) &&& 0x7f

theorem h2_64_lt (h : Nat) : h2_64 h < 0x80 := Nat.lt_of_le_of_lt Nat.and_le_right (by decide)

variable {K V : Type}

/-- The control byte `c` encodes the slot `s`. -/
def CtrlOK (hash : K → Nat) (h2 : Nat → Nat) : Slot K V → Nat → Prop
  | .empty, c => c = EMPTY
  | .deleted .., c => c = DELETED
  | .full k _, c => c = h2 (hash k)
  | .mistagged k _, c => c < 0x80 ∧ c ≠ h2 (hash k)

/-- The control-byte array `ctrl` (`n + W` bytes) represents the table `T`. -/
structure Ctrl (W : Nat) (hash : K → Nat) (h2 : Nat → Nat) (T : Table K V) (ctrl : Nat → Nat) :
    Prop where
  slot : ∀ i < T.n, CtrlOK hash h2 (T.slot i) (ctrl i)
  /-- `set_ctrl` replicates the first `W` bytes after the last bucket -/
  mirror : W ≤ T.n → ∀ b < W, ctrl (T.n + b) = ctrl b
  /-- the static empty table: one bucket, `[Group::EMPTY; 2]` -/
  small : T.n < W → T.n = 1 ∧ ∀ i < T.n + W, ctrl i = EMPTY

/-! ## `Group` and `BitMask` -/

/-- `Group::load(ctrl(pos))`: `W` consecutive control bytes. -/
def load (W : Nat) (ctrl : Nat → Nat) (pos : Nat) : List Nat :=
  (List.range W).map (fun b => ctrl (pos + b))

/-- One byte of the generic `match_empty`: `x & (x << 1) & repeat(0x80)`. -/
def matchEmptyByte (c : Nat) : Bool := (c &&& (c <<< 1) &&& 0x80) != 0

def matchEmpty (g : List Nat) : List Bool := g.map matchEmptyByte

/-- SSE2 `match_byte`: `_mm_cmpeq_epi8` + `movemask`. -/
def matchByteSSE2 (g : List Nat) (t : Nat) : List Bool := g.map (· == t)

/-- The generic `match_byte` bit trick, byte-serially: `cmp = x ^ t`, `cmp - 0x01` with the
borrow `br` from the previous byte, `& !cmp & 0x80`. -/
def mbGo (t : Nat) : List Nat → Nat → List Bool
  | [], _ => []
  | x :: xs, br =>
    (((((x ^^^ t) + 256 - 1 - br) % 256) &&& (255 - (x ^^^ t)) &&& 0x80) != 0) ::
      mbGo t xs (if x ^^^ t < 1 + br then 1 else 0)

/-- Generic `match_byte` on a little-endian target (borrows run to higher addresses). -/
def matchByteLE (g : List Nat) (t : Nat) : List Bool := mbGo t g 0

/-- Generic `match_byte` on a big-endian target (borrows run to lower addresses; `to_le`
puts the bits back in address order). -/
def matchByteBE (g : List Nat) (t : Nat) : List Bool := (mbGo t g.reverse 0).reverse

/-- What `search` needs from `match_byte`: exact on matches, false positives only on full
(`< 0x80`) bytes. -/
def MatchOK (mb : List Nat → Nat → List Bool) : Prop :=
  ∀ g t, t < 0x80 → (mb g t).length = g.length ∧
    ∀ b < g.length, (g.getD b 0 = t → (mb g t).getD b false = true) ∧
      ((mb g t).getD b false = true → g.getD b 0 < 0x80)

/-- `BitMask::lowest_set_bit`. -/
def lsb (m : List Bool) : Option Nat := (List.range m.length).find? (fun b => m.getD b false)

/-- The bits `BitMaskIter` yields, in order. -/
def bits (m : List Bool) : List Nat := (List.range m.length).filter (fun b => m.getD b false)

theorem matchEmptyByte_lt : ∀ c < 0x80, matchEmptyByte c = false := by decide

theorem matchEmptyByte_iff (c : Nat) (hc : c < 0x80 ∨ c = DELETED ∨ c = EMPTY) :
    matchEmptyByte c = (c == EMPTY) := by
  rcases hc with h | rfl | rfl
  · rw [matchEmptyByte_lt c h]; simp [EMPTY]; omega
  · decide
  · decide

theorem matchByteSSE2_ok : MatchOK matchByteSSE2 := by
  intro g t ht
  refine ⟨by simp [matchByteSSE2], fun b hb => ⟨fun h => ?_, fun h => ?_⟩⟩
  · simp [matchByteSSE2, List.getD_eq_getElem?_getD, hb] at h ⊢; exact h
  · simp [matchByteSSE2, List.getD_eq_getElem?_getD, hb] at h ⊢; omega

theorem and80_lt : ∀ a < 128, a &&& 0x80 = 0 := by decide

/-- One byte of the generic bit trick: a match is always reported, and a reported byte is full. -/
theorem mb_byte (x t br : Nat) (ht : t < 0x80) (hbr : br ≤ 1) :
    (x = t → (((((x ^^^ t) + 256 - 1 - br) % 256) &&& (255 - (x ^^^ t)) &&& 0x80) != 0) = true) ∧
    ((((((x ^^^ t) + 256 - 1 - br) % 256) &&& (255 - (x ^^^ t)) &&& 0x80) != 0) = true →
      x < 0x80) := by
  constructor
  · rintro rfl; rw [Nat.xor_self]
    rcases (show br = 0 ∨ br = 1 by omega) with rfl | rfl <;> decide
  · intro h
    have hc : x ^^^ t < 128 := by
      false_or_by_contra
      have h1 : (((x ^^^ t) + 256 - 1 - br) % 256) &&& (255 - (x ^^^ t)) < 128 :=
        Nat.lt_of_le_of_lt Nat.and_le_right (by omega)
      rw [and80_lt _ h1] at h; simp at h
    have : x = (x ^^^ t) ^^^ t := by rw [Nat.xor_assoc, Nat.xor_self, Nat.xor_zero]
    rw [this]
    exact Nat.xor_lt_two_pow (n := 7) hc ht

theorem mbGo_ok (t : Nat) (ht : t < 0x80) : ∀ (g : List Nat) (br : Nat), br ≤ 1 →
    (mbGo t g br).length = g.length ∧
    ∀ b < g.length, (g.getD b 0 = t → (mbGo t g br).getD b false = true) ∧
      ((mbGo t g br).getD b false = true → g.getD b 0 < 0x80)
  | [], _, _ => ⟨rfl, fun b hb => by simp at hb⟩
  | x :: xs, br, hbr => by
    have ih := mbGo_ok t ht xs (if x ^^^ t < 1 + br then 1 else 0) (by split <;> omega)
    refine ⟨by simp [mbGo, ih.1], fun b hb => ?_⟩
    cases b with
    | zero => simpa [mbGo] using mb_byte x t br ht hbr
    | succ b =>
      simp only [List.length_cons] at hb
      simpa [mbGo] using ih.2 b (by omega)

theorem matchByteLE_ok : MatchOK matchByteLE := by
  intro g t ht; exact mbGo_ok t ht g 0 (by omega)

theorem matchByteBE_ok : MatchOK matchByteBE := by
  intro g t ht
  have h := mbGo_ok t ht g.reverse 0 (by omega)
  simp only [List.length_reverse] at h
  refine ⟨by simp [matchByteBE, h.1], fun b hb => ?_⟩
  have hb' : g.length - 1 - b < g.length := by omega
  have e1 : g.getD b 0 = g.reverse.getD (g.length - 1 - b) 0 := by
    simp only [List.getD_eq_getElem?_getD, List.getElem?_reverse hb']
    congr 2; omega
  have e2 : (matchByteBE g t).getD b false = (mbGo t g.reverse 0).getD (g.length - 1 - b) false := by
    simp only [matchByteBE, List.getD_eq_getElem?_getD]
    rw [List.getElem?_reverse (by rw [h.1]; omega), h.1]
    all_goals (try (congr 2; omega))
  rw [e1, e2]; exact h.2 _ hb'

/-! ## The sequential `search` loop -/

inductive SRes (V R : Type) where
  | found (i : Nat) (v : V)
  | stop (r : R)
  /-- ran past the `n / W` groups (Rust would loop on; shown not to happen) -/
  | exhausted

section Loop
variable (W n : Nat) (ctrl : Nat → Nat)

/-- The `while let Some(bit) = bitmask.next()` part of `search`: `eq` on each matched bucket
`(pos + bit) & bucket_mask` in bit order. -/
def scan (look : Nat → Option V) (pos : Nat) : List Nat → Option (Nat × V)
  | [] => none
  | b :: bs => match look ((pos + b) &&& (n - 1)) with
    | some v => some ((pos + b) &&& (n - 1), v)
    | none => scan look pos bs

/-- `TableRef::search`: per group, the `match_byte` bits (`scan`), then `stop(&group, &probe_seq)`,
then `probe_seq.move_next` and the next `Group::load`. -/
def search {R : Type} (mb : List Nat → Nat → List Bool) (t : Nat) (look : Nat → Option V)
    (stop : List Nat → Nat → Option R) : (fuel pos stride : Nat) → SRes V R
  | fuel, pos, stride =>
    match scan n look pos (bits (mb (load W ctrl pos) t)) with
    | some (i, v) => .found i v
    | none => match stop (load W ctrl pos) pos with
      | some r => .stop r
      | none => match fuel with
        | 0 => .exhausted
        | f + 1 => search mb t look stop f ((pos + (stride + W)) &&& (n - 1)) (stride + W)

/-- `find`'s stop closure: `group.match_empty().any_bit_set()`. -/
def stopFind (g : List Nat) (_pos : Nat) : Option Unit :=
  if (matchEmpty g).any id then some () else none

/-- `find_potential`'s stop closure: the lowest `EMPTY` bit's bucket. -/
def stopPotential (g : List Nat) (pos : Nat) : Option Nat :=
  (lsb (matchEmpty g)).map (fun bit => (pos + bit) &&& (n - 1))

/-- `TableInfoRef::find_insert_slot`. -/
def findInsertSlot : (fuel pos stride : Nat) → Option Nat
  | fuel, pos, stride =>
    match lsb (matchEmpty (load W ctrl pos)) with
    | some bit => some ((pos + bit) &&& (n - 1))
    | none => match fuel with
      | 0 => none
      | f + 1 => findInsertSlot f ((pos + (stride + W)) &&& (n - 1)) (stride + W)

/-- The stop closures alone along the probe (what `search` does when no `eq` succeeds). -/
def stopLoop {R : Type} (stop : List Nat → Nat → Option R) : (fuel pos stride : Nat) → Option R
  | fuel, pos, stride =>
    match stop (load W ctrl pos) pos with
    | some r => some r
    | none => match fuel with
      | 0 => none
      | f + 1 => stopLoop stop f ((pos + (stride + W)) &&& (n - 1)) (stride + W)

end Loop

/-- `eq` on the bucket at `i` (Rust reads the bucket's key whatever its control byte). -/
def lookK [DecidableEq K] (T : Table K V) (k : K) (i : Nat) : Option V :=
  match T.slot i with
  | .full k' v | .mistagged k' v | .deleted k' v => if k' = k then some v else none
  | .empty => none

/-- `TableRef::find(hash, eq)` for key `k` with `hash = hash k`. -/
def bfind [DecidableEq K] (W : Nat) (mb : List Nat → Nat → List Bool) (hash : K → Nat)
    (h2 : Nat → Nat) (T : Table K V) (ctrl : Nat → Nat) (k : K) : SRes V Unit :=
  search W T.n ctrl mb (h2 (hash k)) (lookK T k) stopFind (T.n / W - 1) (hash k &&& (T.n - 1)) 0

/-- `TableRef::find_potential(hash, eq)`. -/
def bfindPotential [DecidableEq K] (W : Nat) (mb : List Nat → Nat → List Bool) (hash : K → Nat)
    (h2 : Nat → Nat) (T : Table K V) (ctrl : Nat → Nat) (k : K) : SRes V Nat :=
  search W T.n ctrl mb (h2 (hash k)) (lookK T k) (stopPotential T.n) (T.n / W - 1)
    (hash k &&& (T.n - 1)) 0

/-- `find_insert_slot(hash)` on `T`. -/
def bfindInsertSlot (W : Nat) (T : Table K V) (ctrl : Nat → Nat) (h : Nat) : Option Nat :=
  findInsertSlot W T.n ctrl (T.n / W - 1) (h &&& (T.n - 1)) 0

/-- `set_ctrl(index, c)`: the byte and its replica at `((index - W) & mask) + W`. -/
def setCtrl (W n : Nat) (ctrl : Nat → Nat) (i c : Nat) : Nat → Nat :=
  fun x => if x = i ∨ x = (i + n - W) % n + W then c else ctrl x

/-! ## Bytes, mirroring and groups -/

section Proofs
variable {W : Nat} {hash : K → Nat} {h2 : Nat → Nat} {T : Table K V} {ctrl : Nat → Nat}

theorem mask_eq {n : Nat} (hn : n.isPowerOfTwo) (x : Nat) : x &&& (n - 1) = x % n := by
  obtain ⟨a, rfl⟩ := hn; exact Nat.and_two_pow_sub_one_eq_mod x a

/-- **Mirroring**: byte `pos + b` of a group loaded at an in-bounds `pos` is the control byte
of bucket `(pos + b) % n`. -/
theorem ctrl_mirror (hc : Ctrl W hash h2 T ctrl) (hn0 : 0 < T.n) {pos b : Nat} (hpos : pos < T.n)
    (hb : b < W) : ctrl (pos + b) = ctrl ((pos + b) % T.n) := by
  by_cases hs : T.n < W
  · obtain ⟨_, he⟩ := hc.small hs
    rw [he _ (by omega), he _ (by have := Nat.mod_lt (pos + b) hn0; omega)]
  · by_cases hlt : pos + b < T.n
    · rw [Nat.mod_eq_of_lt hlt]
    · have e : (pos + b) % T.n = pos + b - T.n := by
        rw [Nat.mod_eq_sub_mod (by omega), Nat.mod_eq_of_lt (by omega)]
      have hm := hc.mirror (by omega) (pos + b - T.n) (by omega)
      rw [show T.n + (pos + b - T.n) = pos + b by omega] at hm
      rw [e, hm]

theorem ctrl_valid (hc : Ctrl W hash h2 T ctrl) (hh2 : ∀ h, h2 h < 0x80) {i : Nat} (hi : i < T.n) :
    ctrl i < 0x80 ∨ ctrl i = DELETED ∨ ctrl i = EMPTY := by
  have := hc.slot i hi
  generalize T.slot i = s at this
  cases s with
  | empty => exact Or.inr (Or.inr this)
  | full k v => exact Or.inl (by rw [this]; exact hh2 _)
  | mistagged k v => exact Or.inl this.1
  | deleted k v => exact Or.inr (Or.inl this)

/-- `match_empty` on the control byte of bucket `i` is "bucket `i` is `EMPTY`". -/
theorem meb_slot (hc : Ctrl W hash h2 T ctrl) (hh2 : ∀ h, h2 h < 0x80) {i : Nat} (hi : i < T.n) :
    matchEmptyByte (ctrl i) = (T.slot i).isEmpty := by
  rw [matchEmptyByte_iff _ (ctrl_valid hc hh2 hi)]
  have := hc.slot i hi
  generalize T.slot i = s at this
  cases s with
  | empty => simp [CtrlOK] at this; simp [this, Slot.isEmpty]
  | full k v =>
    simp [CtrlOK] at this; have := hh2 (hash k); simp [Slot.isEmpty, EMPTY]; omega
  | mistagged k v => simp [CtrlOK] at this; simp [Slot.isEmpty, EMPTY]; omega
  | deleted k v => simp [CtrlOK] at this; simp [this, Slot.isEmpty, DELETED, EMPTY]

/-- A byte `< 0x80` is a full bucket (given no mistagged buckets). -/
theorem full_of_lt (hc : Ctrl W hash h2 T ctrl) {i : Nat} (hi : i < T.n) (hl : ctrl i < 0x80)
    (hnm : ∀ k v, T.slot i ≠ .mistagged k v) : ∃ k v, T.slot i = .full k v := by
  have := hc.slot i hi
  revert hnm
  generalize T.slot i = s at this
  cases s with
  | empty => simp [CtrlOK, EMPTY] at this; omega
  | full k v => intro _; exact ⟨k, v, rfl⟩
  | mistagged k v => intro h; exact (h k v rfl).elim
  | deleted k v => simp [CtrlOK, DELETED] at this; omega

theorem load_length (pos : Nat) : (load W ctrl pos).length = W := by simp [load]

theorem load_getD {pos b : Nat} (hb : b < W) : (load W ctrl pos).getD b 0 = ctrl (pos + b) := by
  simp [load, List.getD_eq_getElem?_getD, hb]

theorem find?_congr' {α : Type} {p q : α → Bool} :
    ∀ {l : List α}, (∀ x ∈ l, p x = q x) → l.find? p = l.find? q
  | [], _ => rfl
  | x :: l, h => by
    simp only [List.find?_cons, h x (by simp)]
    rw [find?_congr' (fun y hy => h y (by simp [hy]))]

theorem lsb_load (hc : Ctrl W hash h2 T ctrl) (hh2 : ∀ h, h2 h < 0x80) (hn0 : 0 < T.n)
    {pos : Nat} (hpos : pos < T.n) :
    lsb (matchEmpty (load W ctrl pos)) =
      (List.range W).find? (fun b => (T.slot ((pos + b) % T.n)).isEmpty) := by
  unfold lsb
  rw [show (matchEmpty (load W ctrl pos)).length = W by simp [matchEmpty, load]]
  apply find?_congr'
  intro b hb; simp only [List.mem_range] at hb
  simp only [matchEmpty, List.getD_eq_getElem?_getD, List.getElem?_map]
  rw [show (load W ctrl pos)[b]? = some (ctrl (pos + b)) by simp [load, hb]]
  simp only [Option.map_some, Option.getD_some]
  rw [ctrl_mirror hc hn0 hpos hb, meb_slot hc hh2 (Nat.mod_lt _ hn0)]

theorem stopPotential_load (hc : Ctrl W hash h2 T ctrl) (hh2 : ∀ h, h2 h < 0x80)
    (hn : T.n.isPowerOfTwo) {pos : Nat} (hpos : pos < T.n) :
    stopPotential T.n (load W ctrl pos) pos =
      ((List.range W).map (fun b => (pos + b) % T.n)).find? (fun x => (T.slot x).isEmpty) := by
  unfold stopPotential
  rw [lsb_load hc hh2 (Nat.pos_of_isPowerOfTwo hn) hpos, List.find?_map]
  simp only [mask_eq hn]; rfl

theorem any_eq_lsb (m : List Bool) : m.any id = (lsb m).isSome := by
  apply Bool.eq_iff_iff.mpr
  simp only [List.any_eq_true, id, lsb, List.find?_isSome, List.mem_range,
    List.getD_eq_getElem?_getD]
  constructor
  · rintro ⟨x, hx, rfl⟩
    obtain ⟨b, hb, he⟩ := List.mem_iff_getElem.mp hx
    exact ⟨b, hb, by simp [hb, he]⟩
  · rintro ⟨b, hb, h⟩
    refine ⟨m[b], List.getElem_mem hb, ?_⟩
    simpa [hb] using h

theorem stopFind_eq (n : Nat) (g : List Nat) (pos : Nat) :
    stopFind g pos = (stopPotential n g pos).map (fun _ => ()) := by
  unfold stopFind stopPotential
  rw [any_eq_lsb]; cases lsb (matchEmpty g) <;> rfl

theorem stopLoop_find (n : Nat) : ∀ f pos s,
    stopLoop W n ctrl stopFind f pos s =
      (stopLoop W n ctrl (stopPotential n) f pos s).map (fun _ => ())
  | f, pos, s => by
    unfold stopLoop
    rw [stopFind_eq n]
    cases stopPotential n (load W ctrl pos) pos with
    | some r => rfl
    | none =>
      cases f with
      | zero => rfl
      | succ f => exact stopLoop_find n f _ _

theorem findInsertSlot_stopLoop (n : Nat) : ∀ f pos s,
    findInsertSlot W n ctrl f pos s = stopLoop W n ctrl (stopPotential n) f pos s
  | f, pos, s => by
    unfold findInsertSlot stopLoop stopPotential
    cases lsb (matchEmpty (load W ctrl pos)) with
    | some r => rfl
    | none =>
      cases f with
      | zero => rfl
      | succ f => exact findInsertSlot_stopLoop n f _ _

/-! ## `ProbeSeq` positions and `triSeq` groups -/

theorem tri_succ (j : Nat) : (j + 1) * (j + 1 + 1) / 2 = j * (j + 1) / 2 + (j + 1) := by
  have : (j + 1) * (j + 1 + 1) = j * (j + 1) + (j + 1) * 2 := by
    rw [Nat.mul_comm j, ← Nat.mul_add]
  rw [this, Nat.add_mul_div_right _ _ (by decide)]

/-- `move_next` from the position of group `j` gives the position of group `j + 1`. -/
theorem pos_next (n W h j : Nat) (hn : n.isPowerOfTwo) :
    ((h + W * (j * (j + 1) / 2)) % n + (W * j + W)) &&& (n - 1) =
      (h + W * ((j + 1) * (j + 1 + 1) / 2)) % n := by
  rw [mask_eq hn, Nat.mod_add_mod, tri_succ]
  congr 1
  rw [Nat.mul_add W (j * (j + 1) / 2) (j + 1), Nat.mul_succ W j]
  generalize W * (j * (j + 1) / 2) = A; generalize W * j = B; omega

/-- The `ProbeSeq` state `(pos, stride)` after `j` calls of `move_next`. -/
def probeAt (W n h : Nat) : Nat → Nat × Nat
  | 0 => (h &&& (n - 1), 0)
  | j + 1 => ((probeAt W n h j).1 + ((probeAt W n h j).2 + W) &&& (n - 1), (probeAt W n h j).2 + W)

/-- **`ProbeSeq`**: group `j` is loaded at `pos = (h + W * j(j+1)/2) % n`, `stride = W * j`. -/
theorem probeAt_eq (W n h : Nat) (hn : n.isPowerOfTwo) :
    ∀ j, probeAt W n h j = ((h + W * (j * (j + 1) / 2)) % n, W * j)
  | 0 => by simp [probeAt, mask_eq hn]
  | j + 1 => by
    rw [probeAt, probeAt_eq W n h hn j]; dsimp only
    rw [pos_next n W h j hn, ← Nat.mul_succ]

/-- **The `W`-chunks of `triSeq` are the groups `search` loads.** Chunk `j` lists, for each
byte `b` of the group loaded at the `j`-th `ProbeSeq` position, the bucket Rust computes for
bit `b` (`(pos + b) & bucket_mask`); by `load_chunk` byte `b` is that bucket's control byte. -/
theorem triSeq_chunks (W n h : Nat) (hn : n.isPowerOfTwo) (hW : W ≤ n) :
    triSeq W n h = (List.range (n / W)).flatMap
      (fun j => (List.range W).map (fun b => ((probeAt W n h j).1 + b) &&& (n - 1))) := by
  unfold triSeq; rw [if_neg (by omega)]
  congr 1; funext j; congr 1; funext b
  rw [probeAt_eq W n h hn, mask_eq hn, Nat.mod_add_mod]

theorem load_chunk (hc : Ctrl W hash h2 T ctrl) (hn : T.n.isPowerOfTwo) {pos : Nat}
    (hpos : pos < T.n) :
    load W ctrl pos = (List.range W).map (fun b => ctrl ((pos + b) &&& (T.n - 1))) := by
  unfold load
  apply List.map_congr_left; intro b hb; simp only [List.mem_range] at hb
  rw [mask_eq hn, ctrl_mirror hc (Nat.pos_of_isPowerOfTwo hn) hpos hb]

/-- The `j`-th group of bucket indices in `triSeq`. -/
def grp (W n h j : Nat) : List Nat :=
  (List.range W).map (fun b => (h + W * (j * (j + 1) / 2) + b) % n)

theorem triSeq_grp (W n h : Nat) (hW : ¬ n < W) :
    triSeq W n h = (List.range' 0 (n / W)).flatMap (grp W n h) := by
  unfold triSeq; rw [if_neg hW, List.range_eq_range' (n := n / W)]; rfl

theorem stopPotential_grp (hc : Ctrl W hash h2 T ctrl) (hh2 : ∀ h, h2 h < 0x80)
    (hn : T.n.isPowerOfTwo) (h j : Nat) :
    stopPotential T.n (load W ctrl ((h + W * (j * (j + 1) / 2)) % T.n))
        ((h + W * (j * (j + 1) / 2)) % T.n) =
      (grp W T.n h j).find? (fun x => (T.slot x).isEmpty) := by
  rw [stopPotential_load hc hh2 hn (Nat.mod_lt _ (Nat.pos_of_isPowerOfTwo hn))]
  unfold grp; simp only [Nat.mod_add_mod]

/-! ## `find_insert_slot` -/

theorem fis_groups (hc : Ctrl W hash h2 T ctrl) (hh2 : ∀ h, h2 h < 0x80)
    (hn : T.n.isPowerOfTwo) (h : Nat) : ∀ f j,
    stopLoop W T.n ctrl (stopPotential T.n) f ((h + W * (j * (j + 1) / 2)) % T.n) (W * j) =
      ((List.range' j (f + 1)).flatMap (grp W T.n h)).find? (fun x => (T.slot x).isEmpty)
  | f, j => by
    unfold stopLoop
    rw [stopPotential_grp hc hh2 hn, List.range'_succ, List.flatMap_cons, List.find?_append]
    cases (grp W T.n h j).find? (fun x => (T.slot x).isEmpty) with
    | some r => rfl
    | none =>
      cases f with
      | zero => simp
      | succ f =>
        simp only [Option.none_or]
        rw [pos_next _ _ _ _ hn, show W * j + W = W * (j + 1) by rw [Nat.mul_succ]]
        exact fis_groups hc hh2 hn h f (j + 1)

/-- **`find_insert_slot` is `Table.firstEmpty` on `triSeq W`.** -/
theorem findInsertSlot_eq (hc : Ctrl W hash h2 T ctrl) (hh2 : ∀ h, h2 h < 0x80)
    (hn : T.n.isPowerOfTwo) (hW : 0 < W) (h : Nat) :
    bfindInsertSlot W T ctrl h = firstEmpty T (triSeq W T.n h) := by
  unfold bfindInsertSlot firstEmpty
  rw [findInsertSlot_stopLoop]
  by_cases hs : T.n < W
  · obtain ⟨h1, he⟩ := hc.small hs
    have h0 : T.slot 0 = .empty := by
      have := hc.slot 0 (by omega); rw [he 0 (by omega)] at this
      revert this; cases T.slot 0 with
      | empty => intro; rfl
      | full k v => intro e; have := hh2 (hash k); simp [CtrlOK, EMPTY] at e; omega
      | mistagged k v => intro e; simp [CtrlOK, EMPTY] at e
      | deleted k v => intro e; simp [CtrlOK, EMPTY, DELETED] at e
    have hp : h &&& (T.n - 1) = 0 := by rw [h1]; simp
    unfold triSeq; rw [if_pos hs, hp, Nat.div_eq_of_lt hs]
    unfold stopLoop
    rw [stopPotential_load hc hh2 hn (by omega), h1]
    obtain ⟨w, rfl⟩ : ∃ w, W = w + 1 := ⟨W - 1, by omega⟩
    simp [List.range_succ_eq_map, h0, Slot.isEmpty]
  · have hN : 0 < T.n / W := Nat.div_pos (by omega) hW
    have := fis_groups hc hh2 hn h (T.n / W - 1) 0
    simp only [Nat.zero_add, Nat.mul_zero, Nat.add_zero, Nat.zero_mul, Nat.zero_div] at this
    rw [mask_eq hn, this, triSeq_grp W T.n h hs, Nat.sub_add_cancel hN]

/-! ## `search` -/

theorem mem_bits {m : List Bool} {b : Nat} : b ∈ bits m ↔ b < m.length ∧ m.getD b false = true := by
  simp [bits]

theorem scan_sound {n : Nat} {look : Nat → Option V} {pos : Nat} :
    ∀ {bs : List Nat} {i : Nat} {v : V}, scan n look pos bs = some (i, v) →
      ∃ b ∈ bs, i = (pos + b) &&& (n - 1) ∧ look i = some v
  | [], _, _, h => by simp [scan] at h
  | b :: bs, i, v, h => by
    unfold scan at h
    split at h
    · rename_i w hw; cases h; exact ⟨b, by simp, rfl, hw⟩
    · obtain ⟨c, hc, h1, h2⟩ := scan_sound h; exact ⟨c, by simp [hc], h1, h2⟩

theorem scan_complete {n : Nat} {look : Nat → Option V} {pos : Nat} {b : Nat} {v : V} :
    ∀ {bs : List Nat}, b ∈ bs → look ((pos + b) &&& (n - 1)) = some v →
      ∃ p, scan n look pos bs = some p
  | [], h, _ => by simp at h
  | c :: bs, h, hl => by
    unfold scan
    split
    · exact ⟨_, rfl⟩
    · rename_i hc
      rcases List.mem_cons.mp h with rfl | h
      · rw [hl] at hc; cases hc
      · exact scan_complete h hl

variable [DecidableEq K]

/-- A successful `eq` on a `match_byte` bit is a full bucket of `k` (false positives of the
generic `match_byte` are full buckets of other keys in a table without mistagged buckets). -/
theorem scan_full (hc : Ctrl W hash h2 T ctrl) (hn : T.n.isPowerOfTwo)
    {mb : List Nat → Nat → List Bool} (hmb : MatchOK mb) (hh2 : ∀ h, h2 h < 0x80)
    (hnm : ∀ i k v, T.slot i ≠ .mistagged k v) {k : K} {pos i : Nat} {v : V} (hpos : pos < T.n)
    (h : scan T.n (lookK T k) pos (bits (mb (load W ctrl pos) (h2 (hash k)))) = some (i, v)) :
    T.slot i = .full k v := by
  have hn0 := Nat.pos_of_isPowerOfTwo hn
  obtain ⟨b, hb, rfl, hl⟩ := scan_sound h
  obtain ⟨hlen, hm⟩ := hmb (load W ctrl pos) (h2 (hash k)) (hh2 _)
  rw [mem_bits, hlen, load_length] at hb
  have hlt := (hm b (by rw [load_length]; exact hb.1)).2 hb.2
  rw [load_getD hb.1, ctrl_mirror hc hn0 hpos hb.1] at hlt
  rw [mask_eq hn] at hl ⊢
  obtain ⟨k', v', hs⟩ := full_of_lt hc (Nat.mod_lt _ hn0) hlt (hnm _)
  simp only [lookK, hs] at hl
  split at hl
  · rename_i e; cases hl; rw [hs, e]
  · cases hl

/-- `search` only returns full buckets of `k`. -/
theorem search_sound (hc : Ctrl W hash h2 T ctrl) (hn : T.n.isPowerOfTwo)
    {mb : List Nat → Nat → List Bool} (hmb : MatchOK mb) (hh2 : ∀ h, h2 h < 0x80)
    (hnm : ∀ i k v, T.slot i ≠ .mistagged k v) {R : Type} (stop : List Nat → Nat → Option R)
    (k : K) {i : Nat} {v : V} : ∀ f pos s, pos < T.n →
    search W T.n ctrl mb (h2 (hash k)) (lookK T k) stop f pos s = .found i v → T.slot i = .full k v
  | f, pos, s, hpos, h => by
    unfold search at h
    split at h
    · rename_i i' v' hs; cases h; exact scan_full hc hn hmb hh2 hnm hpos hs
    · split at h
      · cases h
      · split at h
        · cases h
        · exact search_sound hc hn hmb hh2 hnm stop k _ _ _
            (by rw [mask_eq hn]; exact Nat.mod_lt _ (Nat.pos_of_isPowerOfTwo hn)) h

/-- With `k` absent, `search` is its stop closure run along the probe. -/
theorem search_absent (hc : Ctrl W hash h2 T ctrl) (hn : T.n.isPowerOfTwo)
    {mb : List Nat → Nat → List Bool} (hmb : MatchOK mb) (hh2 : ∀ h, h2 h < 0x80)
    (hnm : ∀ i k v, T.slot i ≠ .mistagged k v) {R : Type} (stop : List Nat → Nat → Option R)
    (k : K) (habs : ∀ i v, T.slot i ≠ .full k v) : ∀ f pos s, pos < T.n →
    search W T.n ctrl mb (h2 (hash k)) (lookK T k) stop f pos s =
      match stopLoop W T.n ctrl stop f pos s with
      | some r => .stop r
      | none => .exhausted
  | f, pos, s, hpos => by
    unfold search stopLoop
    cases hs : scan T.n (lookK T k) pos (bits (mb (load W ctrl pos) (h2 (hash k)))) with
    | some p => exact (habs _ _ (scan_full hc hn hmb hh2 hnm hpos hs)).elim
    | none =>
      dsimp only
      cases stop (load W ctrl pos) pos with
      | some r => rfl
      | none =>
        cases f with
        | zero => rfl
        | succ f =>
          exact search_absent hc hn hmb hh2 hnm stop k habs f _ _
            (by rw [mask_eq hn]; exact Nat.mod_lt _ (Nat.pos_of_isPowerOfTwo hn))

/-- `search` reaches the group `jp` that holds bucket `i` of `k` when no earlier group has an
`EMPTY` byte, and then succeeds. -/
theorem search_reach (hc : Ctrl W hash h2 T ctrl) (hn : T.n.isPowerOfTwo)
    {mb : List Nat → Nat → List Bool} (hmb : MatchOK mb) (hh2 : ∀ h, h2 h < 0x80)
    {R : Type} (stop : List Nat → Nat → Option R)
    (hstop : ∀ pos < T.n, (∀ b < W, (T.slot ((pos + b) % T.n)).isEmpty = false) →
      stop (load W ctrl pos) pos = none)
    {k : K} {i : Nat} {v : V} (hi : T.slot i = .full k v) (jp : Nat) (hjp : i ∈ grp W T.n (hash k) jp) :
    ∀ f j, j ≤ jp → jp ≤ j + f →
      (∀ j', j ≤ j' → j' < jp → ∀ x ∈ grp W T.n (hash k) j', T.slot x ≠ .empty) →
      ∃ x w, search W T.n ctrl mb (h2 (hash k)) (lookK T k) stop f
        ((hash k + W * (j * (j + 1) / 2)) % T.n) (W * j) = .found x w
  | f, j, h1, h2', hall => by
    have hn0 := Nat.pos_of_isPowerOfTwo hn
    have hpos := Nat.mod_lt (hash k + W * (j * (j + 1) / 2)) hn0
    unfold search
    cases hs : scan T.n (lookK T k) ((hash k + W * (j * (j + 1) / 2)) % T.n)
        (bits (mb (load W ctrl ((hash k + W * (j * (j + 1) / 2)) % T.n)) (h2 (hash k)))) with
    | some p => exact ⟨p.1, p.2, rfl⟩
    | none =>
      dsimp only
      by_cases hj : j = jp
      · subst hj
        exfalso
        simp only [grp, List.mem_map, List.mem_range] at hjp
        obtain ⟨b, hb, hbi⟩ := hjp
        have hin : i < T.n := by rw [← hbi]; exact Nat.mod_lt _ hn0
        have hidx : ((hash k + W * (j * (j + 1) / 2)) % T.n + b) &&& (T.n - 1) = i := by
          rw [mask_eq hn, Nat.mod_add_mod, hbi]
        obtain ⟨hlen, hm⟩ := hmb (load W ctrl ((hash k + W * (j * (j + 1) / 2)) % T.n))
          (h2 (hash k)) (hh2 _)
        have hbit := (hm b (by rw [load_length]; exact hb)).1 (by
          rw [load_getD hb, ctrl_mirror hc hn0 hpos hb, Nat.mod_add_mod, hbi]
          have := hc.slot i hin; rw [hi] at this; exact this)
        obtain ⟨p, hp⟩ := scan_complete (look := lookK T k) (v := v)
          (mem_bits.mpr ⟨by rw [hlen, load_length]; exact hb, hbit⟩)
          (by rw [hidx]; simp [lookK, hi])
        rw [hs] at hp; cases hp
      · rw [hstop _ hpos (fun b hb => ?_)]
        · cases f with
          | zero => omega
          | succ f =>
            dsimp only
            rw [pos_next _ _ _ _ hn, show W * j + W = W * (j + 1) by rw [Nat.mul_succ]]
            exact search_reach hc hn hmb hh2 stop hstop hi jp hjp f (j + 1) (by omega) (by omega)
              (fun j' a c => hall j' (by omega) c)
        · have := hall j (Nat.le_refl _) (by omega) ((hash k + W * (j * (j + 1) / 2) + b) % T.n)
            (by simp only [grp, List.mem_map, List.mem_range]; exact ⟨b, hb, rfl⟩)
          rw [Nat.mod_add_mod]
          revert this; cases T.slot ((hash k + W * (j * (j + 1) / 2) + b) % T.n) <;>
            simp [Slot.isEmpty]

omit [DecidableEq K] in
theorem Clear.append' {T : Table K V} {i : Nat} :
    ∀ {pre l : List Nat}, Clear T i (pre ++ l) →
      i ∈ pre ∨ ((∀ x ∈ pre, T.slot x ≠ .empty) ∧ Clear T i l)
  | [], _, h => Or.inr ⟨by simp, h⟩
  | j :: pre, l, h => by
    rcases h with h | ⟨hne, h⟩
    · left; simp [h]
    · rcases Clear.append' h with h | ⟨h1, h2⟩
      · left; simp [h]
      · right; refine ⟨?_, h2⟩
        intro x hx; rcases List.mem_cons.mp hx with rfl | hx
        · exact hne
        · exact h1 x hx

omit [DecidableEq K] in
/-- `Clear` along the groups: bucket `i` is in some group `jp`, and every earlier group is free of
`EMPTY` buckets. -/
theorem clear_groups {T : Table K V} {i : Nat} (G : Nat → List Nat) :
    ∀ c j, Clear T i ((List.range' j c).flatMap G) → ∃ jp, j ≤ jp ∧ jp < j + c ∧ i ∈ G jp ∧
      ∀ j', j ≤ j' → j' < jp → ∀ x ∈ G j', T.slot x ≠ .empty
  | 0, _, h => by simp [Clear] at h
  | c + 1, j, h => by
    rw [List.range'_succ, List.flatMap_cons] at h
    rcases Clear.append' h with h | ⟨h1, h2⟩
    · exact ⟨j, Nat.le_refl _, by omega, h, fun j' a b => by omega⟩
    · obtain ⟨jp, a, b, hm, hall⟩ := clear_groups G c (j + 1) h2
      refine ⟨jp, by omega, by omega, hm, fun j' c1 c2 => ?_⟩
      by_cases e : j' = j
      · subst e; exact h1
      · exact hall j' (by omega) c2

/-- On a `WF` table with unique keys, `search` returns the bucket of a present key. -/
theorem search_found (hc : Ctrl W hash h2 T ctrl) (hh2 : ∀ h, h2 h < 0x80)
    {mb : List Nat → Nat → List Bool} (hmb : MatchOK mb)
    (hw : WF (realCfg W hash) T) (hu : Uniq T)
    {R : Type} (stop : List Nat → Nat → Option R)
    (hstop : ∀ pos < T.n, (∀ b < W, (T.slot ((pos + b) % T.n)).isEmpty = false) →
      stop (load W ctrl pos) pos = none)
    {k : K} {i : Nat} {v : V} (hi : T.slot i = .full k v) :
    search W T.n ctrl mb (h2 (hash k)) (lookK T k) stop (T.n / W - 1)
      (hash k &&& (T.n - 1)) 0 = .found i v := by
  have hn := hw.pow2
  have hin : i < T.n := Nat.lt_of_not_le (fun h => by rw [hw.bound i h] at hi; cases hi)
  by_cases hs : T.n < W
  · exfalso
    obtain ⟨_, he⟩ := hc.small hs
    have := hc.slot i hin; rw [hi, he i (by omega)] at this
    have := hh2 (hash k); simp [CtrlOK, EMPTY] at *; omega
  · have hcl := hw.noHole i k v hi
    change Clear T i (triSeq W T.n (hash k)) at hcl
    rw [triSeq_grp W T.n _ hs] at hcl
    obtain ⟨jp, -, hjp, hm, hall⟩ := clear_groups _ _ 0 hcl
    obtain ⟨x, w, h⟩ := search_reach hc hn hmb hh2 stop hstop hi jp hm (T.n / W - 1) 0
      (Nat.zero_le _) (by omega) (fun j' _ c x hx => hall j' (Nat.zero_le _) c x hx)
    simp only [Nat.zero_add, Nat.mul_zero, Nat.add_zero, Nat.zero_mul, Nat.zero_div] at h
    rw [← mask_eq hn] at h
    have hx := search_sound hc hn hmb hh2 hw.noMis stop k _ _ _
      (by rw [mask_eq hn]; exact Nat.mod_lt _ (Nat.pos_of_isPowerOfTwo hn)) h
    have := hu _ _ _ _ _ hx hi; subst this
    rw [hi] at hx; cases hx; exact h

omit [DecidableEq K] in
theorem stopPotential_none (hc : Ctrl W hash h2 T ctrl) (hh2 : ∀ h, h2 h < 0x80)
    (hn : T.n.isPowerOfTwo) : ∀ pos < T.n,
    (∀ b < W, (T.slot ((pos + b) % T.n)).isEmpty = false) →
      stopPotential T.n (load W ctrl pos) pos = none := by
  intro pos hpos h
  rw [stopPotential_load hc hh2 hn hpos, List.find?_eq_none]
  intro x hx; simp only [List.mem_map, List.mem_range] at hx
  obtain ⟨b, hb, rfl⟩ := hx; simp [h b hb]

omit [DecidableEq K] in
theorem stopFind_none (hc : Ctrl W hash h2 T ctrl) (hh2 : ∀ h, h2 h < 0x80)
    (hn : T.n.isPowerOfTwo) : ∀ pos < T.n,
    (∀ b < W, (T.slot ((pos + b) % T.n)).isEmpty = false) →
      stopFind (load W ctrl pos) pos = none := by
  intro pos hpos h
  rw [stopFind_eq T.n, stopPotential_none hc hh2 hn pos hpos h]; rfl

/-- **Sequential `find` is `Table.find`.** On a well-formed table with unique keys, whose
control bytes are `ctrl`, Rust's `search` with `find`'s `match_empty` stop returns the bucket
`Table.find` returns, or stops (`None`) exactly when `Table.find` is `none`. It never runs past
the `n / W` groups of the probe. -/
theorem search_find_eq (hW : W.isPowerOfTwo) (hc : Ctrl W hash h2 T ctrl)
    (hh2 : ∀ h, h2 h < 0x80) {mb : List Nat → Nat → List Bool} (hmb : MatchOK mb)
    (hw : WF (realCfg W hash) T) (hu : Uniq T) (k : K) :
    bfind W mb hash h2 T ctrl k =
      match find T k (ps (realCfg W hash) T k) with
      | some (i, v) => .found i v
      | none => .stop () := by
  have hn := hw.pow2
  have hW0 := Nat.pos_of_isPowerOfTwo hW
  have hpos : hash k &&& (T.n - 1) < T.n := by
    rw [mask_eq hn]; exact Nat.mod_lt _ (Nat.pos_of_isPowerOfTwo hn)
  unfold bfind
  cases hf : find T k (ps (realCfg W hash) T k) with
  | some p =>
    obtain ⟨i, v⟩ := p
    exact search_found hc hh2 hmb hw hu _ (stopFind_none hc hh2 hn)
      (find_sound T k _ i v hf)
  | none =>
    have habs : ∀ i v, T.slot i ≠ .full k v := fun i v h =>
      ((find_spec (realCfg W hash) hw hu k).2.1 hf v) ⟨i, h⟩
    rw [search_absent hc hn hmb hh2 hw.noMis _ k habs _ _ _ hpos, stopLoop_find,
      ← findInsertSlot_stopLoop]
    have := findInsertSlot_eq hc hh2 hn hW0 (hash k)
    unfold bfindInsertSlot at this
    rw [this]
    obtain ⟨e, he⟩ := firstEmpty_isSome (realCfg W hash) hw.swf (triSeq_cover W hash hW) k
    change firstEmpty T (triSeq W T.n (hash k)) = some e at he
    rw [he]; rfl

/-- **Sequential `find_potential`**: the bucket of a present key, else the first `EMPTY` bucket
of the probe (`Table.firstEmpty`, the slot `find_insert_slot` picks). -/
theorem search_potential_eq (hW : W.isPowerOfTwo) (hc : Ctrl W hash h2 T ctrl)
    (hh2 : ∀ h, h2 h < 0x80) {mb : List Nat → Nat → List Bool} (hmb : MatchOK mb)
    (hw : WF (realCfg W hash) T) (hu : Uniq T) (k : K) :
    bfindPotential W mb hash h2 T ctrl k =
      match find T k (ps (realCfg W hash) T k) with
      | some (i, v) => .found i v
      | none => match firstEmpty T (ps (realCfg W hash) T k) with
        | some e => .stop e
        | none => .exhausted := by
  have hn := hw.pow2
  have hW0 := Nat.pos_of_isPowerOfTwo hW
  have hpos : hash k &&& (T.n - 1) < T.n := by
    rw [mask_eq hn]; exact Nat.mod_lt _ (Nat.pos_of_isPowerOfTwo hn)
  unfold bfindPotential
  cases hf : find T k (ps (realCfg W hash) T k) with
  | some p =>
    obtain ⟨i, v⟩ := p
    exact search_found hc hh2 hmb hw hu _ (stopPotential_none hc hh2 hn)
      (find_sound T k _ i v hf)
  | none =>
    have habs : ∀ i v, T.slot i ≠ .full k v := fun i v h =>
      ((find_spec (realCfg W hash) hw hu k).2.1 hf v) ⟨i, h⟩
    rw [search_absent hc hn hmb hh2 hw.noMis _ k habs _ _ _ hpos, ← findInsertSlot_stopLoop]
    have := findInsertSlot_eq hc hh2 hn hW0 (hash k)
    unfold bfindInsertSlot at this
    rw [this]
    show _ = match firstEmpty T (triSeq W T.n (hash k)) with
      | some e => SRes.stop e
      | none => .exhausted
    cases firstEmpty T (triSeq W T.n (hash k)) <;> rfl

/-! ## `set_ctrl` keeps the mirror -/

theorem idx2_eq {i n W : Nat} (hW : W ≤ n) (hi : i < n) :
    (i + n - W) % n + W = if W ≤ i then i else n + i := by
  split
  · rw [Nat.mod_eq_sub_mod (by omega), Nat.mod_eq_of_lt (by omega)]; omega
  · rw [Nat.mod_eq_of_lt (by omega)]; omega

omit [DecidableEq K] in
/-- **`set_ctrl`** (byte and replica) of a byte encoding `s` represents `T.set i s`. -/
theorem setCtrl_ctrl (hc : Ctrl W hash h2 T ctrl) (hW : W ≤ T.n) {i c : Nat} {s : Slot K V}
    (hi : i < T.n) (hs : CtrlOK hash h2 s c) :
    Ctrl W hash h2 (T.set i s) (setCtrl W T.n ctrl i c) := by
  have e2 := idx2_eq hW hi
  refine ⟨fun x hx => ?_, fun _ b hb => ?_, fun h => absurd h (by simp [Table.set]; omega)⟩
  · simp only [Table.set] at hx ⊢
    simp only [setCtrl, e2]
    by_cases hxi : x = i
    · subst hxi; simp [hs]
    · rw [if_neg hxi, if_neg]; exact hc.slot x hx
      intro h; rcases h with h | h
      · exact hxi h
      · split at h <;> omega
  · simp only [Table.set, setCtrl, e2]
    by_cases hbi : b = i
    · subst hbi; rw [if_pos (Or.inl rfl), if_pos (Or.inr (by rw [if_neg (by omega)]))]
    · rw [if_neg, if_neg, hc.mirror hW b hb]
      · intro h; rcases h with h | h
        · exact hbi h
        · split at h <;> omega
      · intro h; rcases h with h | h
        · omega
        · split at h <;> omega

omit [DecidableEq K] in
/-- A freshly allocated table (`TableRef::allocate`: every byte `EMPTY`). -/
theorem emptyTable_ctrl (m : Nat) (hW : W ≤ m) :
    Ctrl W hash h2 (emptyTable (K := K) (V := V) m) (fun _ => EMPTY) :=
  ⟨fun _ _ => rfl, fun _ _ _ => rfl, fun h => absurd h (by simp [emptyTable]; omega)⟩

end Proofs

end Bytes
end SyncTable
