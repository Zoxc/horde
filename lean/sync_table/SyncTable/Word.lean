import SyncTable.Bytes

/-!
# Machine words for `Group`, `BitMask`, `h1` and `set_ctrl` (property 17, generic backend)

`Bytes.lean` works on lists: a group is a `List Nat` of bytes, a `BitMask` a `List Bool`, and
the generic `match_byte` a byte-serial borrow chain (`mbGo`). This file models the generic
backend (`src/raw/generic.rs`, `src/raw/bitmask.rs`) on words and proves it agrees with the list
model:

* A group of `L` bytes is the little-endian word `wb bytes < 2^(8L)` (`Group::load` builds it
  with `transmute` of the byte array; on a little-endian target that is `from_le_bytes`, and
  `to_le` is the identity). `pw L = 2^(8L)`; `L = 8` for `u64`, `4` for `u32`.
* `matchByteWord`: `cmp = x ^ repeat(t)`, `cmp.wrapping_sub(repeat(0x01)) & !cmp & repeat(0x80)`
  with `wrapping_sub` as `(a + 2^(8L) - b) % 2^(8L)` and `!cmp` as `2^(8L) - 1 - cmp`.
  `matchByteWord_eq`: it is `toMask (matchByteLE g t)`.
* `matchEmptyWord`: `x & (x << 1) & repeat(0x80)` with `<<` truncated to the word.
  `matchEmptyWord_eq`: it is `toMask (matchEmpty g)`.
* `BitMask` word with `BITMASK_STRIDE = 8` (one bit, bit 7, per byte: `toMask`):
  `lowestSetBit` (`trailing_zeros / 8` on a non-zero word), `removeLowestBit`
  (`x & x.wrapping_sub(1)`), `x != 0` (`any_bit_set`), and `BitMaskIter` (`iterW`).
  `iterW_toMask`, `lowestSetBit_toMask`, `anyBitSet_toMask`: they agree with `bits`, `lsb`,
  `List.any`.
* `searchW` / `findInsertSlotW`: the `search` and `find_insert_slot` loops on these words;
  `searchW_eq`, `findInsertSlotW_eq`: equal to `Bytes.search` / `Bytes.findInsertSlot` with
  `matchByteLE`. `bfindW_eq`, `bfindPotentialW_eq`, `bfindInsertSlotW_eq`: with Rust's `h1`,
  the word-level operations equal `Table.find` / `Table.firstEmpty`.
* `usize` is `Nat` mod `2^u` (`u = 64` or `32`). `h1 hash = hash as usize = hash % 2^u`
  (`h1_mask`: masking it equals masking the full hash when `n ≤ 2^u`). `set_ctrl`'s
  `index.wrapping_sub(W) & bucket_mask` is `(i + n - W) % n` (`idx2Rust_eq`).

Big-endian targets (byte-swap before `to_le`, borrows towards lower addresses) are covered at
the list level by `matchByteBE_ok`, not at the word level here. SSE2 (`sse2.rs`) uses
`_mm_cmpeq_epi8` / `_mm_movemask_epi8`, i.e. `matchByteSSE2` with `BITMASK_STRIDE = 1`; its
word form (`movemask` bit `b` = byte `b`) is not modelled.
-/

namespace SyncTable
namespace Bytes
namespace Word

/-- The little-endian word of a byte list. -/
def wb : List Nat → Nat
  | [] => 0
  | x :: xs => 256 * wb xs + x

def IsBytes (l : List Nat) : Prop := ∀ x ∈ l, x < 256

/-- `2^(8L)`. -/
def pw (L : Nat) : Nat := 2 ^ (8 * L)

theorem pw_succ (L : Nat) : pw (L + 1) = 256 * pw L := by
  unfold pw; rw [Nat.mul_succ, Nat.pow_add, Nat.mul_comm]

theorem pw_pos (L : Nat) : 0 < pw L := Nat.two_pow_pos _

theorem isBytes_cons {x : Nat} {l : List Nat} : IsBytes (x :: l) ↔ x < 256 ∧ IsBytes l := by
  simp [IsBytes]

theorem isBytes_nil : IsBytes [] := by simp [IsBytes]

theorem wb_lt : ∀ l : List Nat, IsBytes l → wb l < pw l.length
  | [], _ => by simp [wb, pw]
  | x :: l, h => by
    rw [isBytes_cons] at h
    have := wb_lt l h.2
    simp only [wb, List.length_cons, pw_succ]; omega

theorem and_split (x y a b : Nat) (ha : a < 256) (hb : b < 256) :
    (256 * x + a) &&& (256 * y + b) = 256 * (x &&& y) + (a &&& b) := by
  have hab : a &&& b < 2 ^ 8 := Nat.and_lt_two_pow a (by simpa using hb)
  apply Nat.eq_of_testBit_eq; intro i
  rw [show (256 : Nat) = 2 ^ 8 from rfl, Nat.testBit_and,
    Nat.testBit_two_pow_mul_add _ (by simpa using ha), Nat.testBit_two_pow_mul_add _ (by simpa using hb),
    Nat.testBit_two_pow_mul_add _ hab]
  split <;> simp [Nat.testBit_and]

theorem xor_split (x y a b : Nat) (ha : a < 256) (hb : b < 256) :
    (256 * x + a) ^^^ (256 * y + b) = 256 * (x ^^^ y) + (a ^^^ b) := by
  have hab : a ^^^ b < 2 ^ 8 := Nat.xor_lt_two_pow (by simpa using ha) (by simpa using hb)
  apply Nat.eq_of_testBit_eq; intro i
  rw [show (256 : Nat) = 2 ^ 8 from rfl, Nat.testBit_xor,
    Nat.testBit_two_pow_mul_add _ (by simpa using ha), Nat.testBit_two_pow_mul_add _ (by simpa using hb),
    Nat.testBit_two_pow_mul_add _ hab]
  split <;> simp [Nat.testBit_xor]

theorem wb_and : ∀ a b : List Nat, a.length = b.length → IsBytes a → IsBytes b →
    wb a &&& wb b = wb (List.zipWith (· &&& ·) a b)
  | [], [], _, _, _ => by simp [wb]
  | x :: a, y :: b, hl, ha, hb => by
    rw [isBytes_cons] at ha hb
    simp only [wb, List.zipWith_cons_cons]
    rw [and_split _ _ _ _ ha.1 hb.1, wb_and a b (by simpa using hl) ha.2 hb.2]
  | [], _ :: _, hl, _, _ => by simp at hl
  | _ :: _, [], hl, _, _ => by simp at hl

theorem wb_xor : ∀ a b : List Nat, a.length = b.length → IsBytes a → IsBytes b →
    wb a ^^^ wb b = wb (List.zipWith (· ^^^ ·) a b)
  | [], [], _, _, _ => by simp [wb]
  | x :: a, y :: b, hl, ha, hb => by
    rw [isBytes_cons] at ha hb
    simp only [wb, List.zipWith_cons_cons]
    rw [xor_split _ _ _ _ ha.1 hb.1, wb_xor a b (by simpa using hl) ha.2 hb.2]
  | [], _ :: _, hl, _, _ => by simp at hl
  | _ :: _, [], hl, _, _ => by simp at hl

theorem zipWith_rep (f : Nat → Nat → Nat) (c : Nat) :
    ∀ l : List Nat, List.zipWith f l (List.replicate l.length c) = l.map (fun x => f x c)
  | [] => rfl
  | x :: l => by simp [List.replicate_succ, zipWith_rep f c l]

theorem isBytes_rep (L c : Nat) (hc : c < 256) : IsBytes (List.replicate L c) := by
  intro x hx; rw [List.eq_of_mem_replicate hx]; exact hc

theorem wb_not : ∀ l : List Nat, IsBytes l → wb (l.map (255 - ·)) = pw l.length - 1 - wb l
  | [], _ => by simp [wb, pw]
  | x :: l, h => by
    rw [isBytes_cons] at h
    have := wb_lt l h.2
    simp only [List.map_cons, wb, List.length_cons, pw_succ, wb_not l h.2]; omega

theorem mod256 (X d M : Nat) (hd : d < 256) : (256 * X + d) % (256 * M) = 256 * (X % M) + d := by
  rw [Nat.mod_mul]
  rw [show (256 * X + d) % 256 = d by omega, show (256 * X + d) / 256 = X by omega]; omega

/-- `wrapping_sub(repeat(0x01))` byte-serially, with borrow `br`. -/
def subGo : List Nat → Nat → List Nat
  | [], _ => []
  | c :: cs, br => ((c + 256 - 1 - br) % 256) :: subGo cs (if c < 1 + br then 1 else 0)

theorem subGo_length : ∀ (cs : List Nat) br, (subGo cs br).length = cs.length
  | [], _ => rfl
  | _ :: cs, _ => by simp [subGo, subGo_length cs]

theorem subGo_bytes : ∀ (cs : List Nat) br, IsBytes (subGo cs br)
  | [], _ => isBytes_nil
  | _ :: cs, _ => isBytes_cons.mpr ⟨Nat.mod_lt _ (by decide), subGo_bytes cs _⟩

theorem wb_sub : ∀ (cs : List Nat) (br : Nat), IsBytes cs → br ≤ 1 →
    (wb cs + pw cs.length - wb (List.replicate cs.length 1) - br) % pw cs.length = wb (subGo cs br)
  | [], br, _, hbr => by simp [wb, pw, subGo, Nat.mod_one]
  | c :: cs, br, h, hbr => by
    rw [isBytes_cons] at h
    have hC := wb_lt cs h.2
    have hO := wb_lt _ (isBytes_rep cs.length 1 (by decide))
    rw [List.length_replicate] at hO
    have ih := wb_sub cs (if c < 1 + br then 1 else 0) h.2 (by split <;> omega)
    simp only [List.length_cons, List.replicate_succ, wb, subGo, pw_succ]
    rw [← ih, ← mod256 _ _ _ (Nat.mod_lt _ (by decide))]
    congr 1
    split <;> omega

/-- `x << 1` truncated, byte-serially, with carry `cin` into bit 0. -/
def shlGo : List Nat → Nat → List Nat
  | [], _ => []
  | x :: xs, cin => ((2 * x + cin) % 256) :: shlGo xs (x / 128)

theorem shlGo_length : ∀ (g : List Nat) c, (shlGo g c).length = g.length
  | [], _ => rfl
  | _ :: g, _ => by simp [shlGo, shlGo_length g]

theorem shlGo_bytes : ∀ (g : List Nat) c, IsBytes (shlGo g c)
  | [], _ => isBytes_nil
  | _ :: g, _ => isBytes_cons.mpr ⟨Nat.mod_lt _ (by decide), shlGo_bytes g _⟩

theorem wb_shl : ∀ (g : List Nat) (cin : Nat), IsBytes g → cin ≤ 1 →
    (wb g * 2 + cin) % pw g.length = wb (shlGo g cin)
  | [], _, _, _ => by simp [wb, pw, shlGo, Nat.mod_one]
  | x :: g, cin, h, hc => by
    rw [isBytes_cons] at h
    have ih := wb_shl g (x / 128) h.2 (by omega)
    simp only [List.length_cons, wb, shlGo, pw_succ]
    rw [← ih, ← mod256 _ _ _ (Nat.mod_lt _ (by decide))]
    congr 1; omega

/-! ## Group words -/

/-- `repeat(byte)`. -/
def rep (L c : Nat) : Nat := wb (List.replicate L c)

/-- Generic `Group::match_byte` on an `L`-byte word. -/
def matchByteWord (L x t : Nat) : Nat :=
  ((((x ^^^ rep L t) + pw L - rep L 1) % pw L) &&& (pw L - 1 - (x ^^^ rep L t))) &&& rep L 0x80

/-- Generic `Group::match_empty` on an `L`-byte word. -/
def matchEmptyWord (L x : Nat) : Nat := (x &&& ((x <<< 1) % pw L)) &&& rep L 0x80

/-- A `List Bool` mask as a `BitMask` word with `BITMASK_STRIDE = 8` (bit 7 of each byte). -/
def toMask (m : List Bool) : Nat := wb (m.map (fun b => if b then 0x80 else 0))

theorem toMask_cons (b : Bool) (m : List Bool) :
    toMask (b :: m) = 256 * toMask m + (if b then 0x80 else 0) := rfl

theorem and80 : ∀ y < 256, (y &&& 128) = (if (y &&& 128 != 0) = true then 128 else 0) := by
  decide +kernel

theorem mbByte_eq : ∀ x < 256, ∀ c < 2,
    (x &&& ((2 * x + c) % 256) &&& 128) =
      (if matchEmptyByte x = true then 128 else 0) := by
  unfold matchEmptyByte; decide +kernel

theorem mb_final (t : Nat) (ht : t < 0x80) : ∀ (g : List Nat) (br : Nat), IsBytes g →
    (List.zipWith (· &&& ·) (subGo (g.map (· ^^^ t)) br) ((g.map (· ^^^ t)).map (255 - ·))).map
      (· &&& 0x80) = (mbGo t g br).map (fun b => if b then 0x80 else 0)
  | [], _, _ => rfl
  | x :: g, br, h => by
    rw [isBytes_cons] at h
    simp only [List.map_cons, subGo, List.zipWith_cons_cons, mbGo]
    rw [mb_final t ht g _ h.2]
    congr 1
    have hy : ((x ^^^ t) + 256 - 1 - br) % 256 &&& (255 - (x ^^^ t)) < 256 :=
      Nat.lt_of_le_of_lt Nat.and_le_left (Nat.mod_lt _ (by decide))
    exact and80 _ hy

theorem isBytes_map_xor (t : Nat) (ht : t < 256) : ∀ g : List Nat, IsBytes g →
    IsBytes (g.map (· ^^^ t)) := by
  intro g h x hx
  simp only [List.mem_map] at hx
  obtain ⟨y, hy, rfl⟩ := hx
  exact Nat.xor_lt_two_pow (n := 8) (h y hy) ht

theorem isBytes_map_not : ∀ g : List Nat, IsBytes (g.map (255 - ·)) := by
  intro g x hx
  simp only [List.mem_map] at hx
  obtain ⟨y, _, rfl⟩ := hx; omega

/-- **Generic `match_byte` on the word is the borrow-chain model** (little-endian). -/
theorem matchByteWord_eq (g : List Nat) (hg : IsBytes g) (t : Nat) (ht : t < 0x80) :
    matchByteWord g.length (wb g) t = toMask (matchByteLE g t) := by
  have hcs := isBytes_map_xor t (by omega) g hg
  have hx : wb g ^^^ rep g.length t = wb (g.map (· ^^^ t)) := by
    unfold rep
    rw [wb_xor _ _ (by simp) hg (isBytes_rep _ _ (by omega)), zipWith_rep]
  have hsub := wb_sub (g.map (· ^^^ t)) 0 hcs (by omega)
  simp only [List.length_map, Nat.sub_zero] at hsub
  have hnot := wb_not (g.map (· ^^^ t)) hcs
  simp only [List.length_map] at hnot
  unfold matchByteWord
  rw [hx]
  unfold rep
  rw [hsub, ← hnot, wb_and _ _ (by simp [subGo_length]) (subGo_bytes _ _) (isBytes_map_not _)]
  rw [wb_and _ _ (by simp [subGo_length]) ?_ (isBytes_rep _ _ (by decide))]
  · have := zipWith_rep (· &&& ·) 0x80
      (List.zipWith (· &&& ·) (subGo (g.map (· ^^^ t)) 0) ((g.map (· ^^^ t)).map (255 - ·)))
    simp only [List.length_zipWith, subGo_length, List.length_map, Nat.min_self] at this
    rw [this, mb_final t ht g 0 hg]; rfl
  · intro y hy
    rw [List.mem_iff_getElem] at hy
    obtain ⟨i, hi, rfl⟩ := hy
    simp only [List.getElem_zipWith]
    exact Nat.lt_of_le_of_lt Nat.and_le_left (subGo_bytes _ _ _ (List.getElem_mem _))

theorem me_final : ∀ (g : List Nat) (cin : Nat), IsBytes g → cin ≤ 1 →
    (List.zipWith (· &&& ·) g (shlGo g cin)).map (· &&& 0x80) =
      (matchEmpty g).map (fun b => if b then 0x80 else 0)
  | [], _, _, _ => rfl
  | x :: g, cin, h, hc => by
    rw [isBytes_cons] at h
    simp only [shlGo, List.zipWith_cons_cons, List.map_cons, matchEmpty]
    have := me_final g (x / 128) h.2 (by omega)
    simp only [matchEmpty] at this
    rw [this, mbByte_eq x h.1 cin (by omega)]

/-- **Generic `match_empty` on the word is the per-byte model.** -/
theorem matchEmptyWord_eq (g : List Nat) (hg : IsBytes g) :
    matchEmptyWord g.length (wb g) = toMask (matchEmpty g) := by
  unfold matchEmptyWord rep
  have hs := wb_shl g 0 hg (by omega)
  rw [Nat.add_zero] at hs
  rw [Nat.shiftLeft_eq, Nat.pow_one, hs, wb_and _ _ (by simp [shlGo_length]) hg (shlGo_bytes _ _)]
  rw [wb_and _ _ (by simp [shlGo_length]) ?_ (isBytes_rep _ _ (by decide))]
  · have := zipWith_rep (· &&& ·) 0x80 (List.zipWith (· &&& ·) g (shlGo g 0))
    simp only [List.length_zipWith, shlGo_length, Nat.min_self] at this
    rw [this, me_final g 0 hg (by omega)]; rfl
  · intro y hy
    rw [List.mem_iff_getElem] at hy
    obtain ⟨i, hi, rfl⟩ := hy
    simp only [List.getElem_zipWith]
    exact Nat.lt_of_le_of_lt Nat.and_le_left (hg _ (List.getElem_mem _))

/-! ## `BitMask` words -/

/-- `trailing_zeros` (of a non-zero word). -/
def tz (x : Nat) : Nat :=
  if h : x = 0 then 0 else if x % 2 = 1 then 0 else tz (x / 2) + 1
termination_by x
decreasing_by omega

/-- `BitMask::lowest_set_bit` with `BITMASK_STRIDE = 8`. -/
def lowestSetBit (x : Nat) : Option Nat := if x = 0 then none else some (tz x / 8)

/-- `BitMask::remove_lowest_bit`: `x & x.wrapping_sub(1)` (for `x = 0` both give `0`). -/
def removeLowestBit (x : Nat) : Nat := x &&& (x - 1)

/-- `BitMaskIter`: `lowest_set_bit`, then `remove_lowest_bit`, until empty (fuel: at most one
step per byte). -/
def iterW : Nat → Nat → List Nat
  | 0, _ => []
  | f + 1, x => match lowestSetBit x with
    | none => []
    | some b => b :: iterW f (removeLowestBit x)

theorem tz_two_mul {y : Nat} (hy : y ≠ 0) : tz (2 * y) = tz y + 1 := by
  rw [tz]; rw [dif_neg (by omega), if_neg (by omega)]; congr 2; omega

theorem tz_odd (y : Nat) : tz (2 * y + 1) = 0 := by
  rw [tz]; rw [dif_neg (by omega), if_pos (by omega)]

theorem tz_pow_mul {y : Nat} (hy : y ≠ 0) : ∀ k, tz (2 ^ k * y) = tz y + k
  | 0 => by simp
  | k + 1 => by
    rw [Nat.pow_succ, Nat.mul_comm (2 ^ k) 2, Nat.mul_assoc, tz_two_mul, tz_pow_mul hy k]
    · omega
    · exact Nat.mul_ne_zero (Nat.pos_iff_ne_zero.mp (Nat.two_pow_pos k)) hy

theorem lowestSetBit_shift (Y : Nat) : lowestSetBit (256 * Y) = (lowestSetBit Y).map (· + 1) := by
  unfold lowestSetBit
  by_cases hY : Y = 0
  · simp [hY]
  · rw [if_neg (by omega), if_neg hY]
    have := tz_pow_mul hY 8
    simp only [show (2 : Nat) ^ 8 = 256 from rfl] at this
    simp only [Option.map_some, this]; congr 1; omega

theorem lowestSetBit_low (Y : Nat) : lowestSetBit (256 * Y + 128) = some 0 := by
  unfold lowestSetBit
  rw [if_neg (by omega)]
  have := tz_pow_mul (y := 2 * Y + 1) (by omega) 7
  rw [tz_odd] at this
  rw [show 256 * Y + 128 = 2 ^ 7 * (2 * Y + 1) by
    rw [show (2 : Nat) ^ 7 = 128 from rfl]; omega, this]

theorem removeLowestBit_shift (Y : Nat) : removeLowestBit (256 * Y) = 256 * removeLowestBit Y := by
  unfold removeLowestBit
  by_cases hY : Y = 0
  · simp [hY]
  · have e : 256 * Y - 1 = 256 * (Y - 1) + 255 := by omega
    rw [e, show 256 * Y = 256 * Y + 0 by rfl, and_split _ _ _ _ (by decide) (by decide)]
    simp

theorem removeLowestBit_low (Y : Nat) : removeLowestBit (256 * Y + 128) = 256 * Y := by
  unfold removeLowestBit
  rw [show 256 * Y + 128 - 1 = 256 * Y + 127 by omega, and_split _ _ _ _ (by decide) (by decide)]
  simp

theorem iterW_shift : ∀ f Y, iterW f (256 * Y) = (iterW f Y).map (· + 1)
  | 0, _ => rfl
  | f + 1, Y => by
    simp only [iterW, lowestSetBit_shift]
    cases lowestSetBit Y with
    | none => rfl
    | some b => simp [removeLowestBit_shift, iterW_shift f]

theorem bits_cons (b : Bool) (m : List Bool) :
    bits (b :: m) = (if b then [0] else []) ++ (bits m).map (· + 1) := by
  unfold bits
  rw [List.length_cons, List.range_succ_eq_map, List.filter_cons, List.filter_map]
  cases b <;> simp [Function.comp_def, List.getD_eq_getElem?_getD]

theorem lsb_cons (b : Bool) (m : List Bool) :
    lsb (b :: m) = if b then some 0 else (lsb m).map (· + 1) := by
  unfold lsb
  rw [List.length_cons, List.range_succ_eq_map, List.find?_cons]
  cases b <;> simp [List.find?_map, Function.comp_def, List.getD_eq_getElem?_getD]

/-- **`BitMaskIter` on the word yields `bits`** (increasing bit order). -/
theorem iterW_toMask : ∀ (m : List Bool) (f : Nat), m.length ≤ f → iterW f (toMask m) = bits m
  | [], f, _ => by cases f <;> rfl
  | b :: m, f, hf => by
    rw [toMask_cons, bits_cons]
    cases b with
    | true =>
      obtain ⟨f, rfl⟩ : ∃ f', f = f' + 1 := ⟨f - 1, by simp at hf; omega⟩
      simp only [iterW, if_true, lowestSetBit_low, removeLowestBit_low, iterW_shift,
        iterW_toMask m f (by simp at hf; omega)]
      rfl
    | false =>
      simp only [Bool.false_eq_true, if_false, Nat.add_zero, iterW_shift,
        iterW_toMask m f (by simp at hf; omega), List.nil_append]

theorem lowestSetBit_toMask : ∀ m : List Bool, lowestSetBit (toMask m) = lsb m
  | [] => rfl
  | b :: m => by
    rw [toMask_cons, lsb_cons]
    cases b with
    | true => simp [lowestSetBit_low]
    | false => simp [lowestSetBit_shift, lowestSetBit_toMask m]

theorem anyBitSet_toMask : ∀ m : List Bool, (toMask m != 0) = m.any id
  | [] => rfl
  | b :: m => by
    rw [toMask_cons]
    have := anyBitSet_toMask m
    cases b
    · simp only [Bool.false_eq_true, if_false, Nat.add_zero, List.any_cons, id, Bool.false_or]
      rw [← this]
      by_cases hY : toMask m = 0
      · rw [hY]
      · have h' : 256 * toMask m ≠ 0 := by omega
        rw [show (256 * toMask m != 0) = true from bne_iff_ne.mpr h', show (toMask m != 0) = true from bne_iff_ne.mpr hY]
    · simp

/-! ## The loops on words -/

section Loop
variable {V : Type} (W n : Nat) (ctrl : Nat → Nat)

def stopFindW (x : Nat) (_pos : Nat) : Option Unit :=
  if matchEmptyWord W x != 0 then some () else none

def stopPotentialW (x pos : Nat) : Option Nat :=
  (lowestSetBit (matchEmptyWord W x)).map (fun bit => (pos + bit) &&& (n - 1))

/-- `search` on group words (generic backend). -/
def searchW {R : Type} (t : Nat) (look : Nat → Option V) (stop : Nat → Nat → Option R) :
    (fuel pos stride : Nat) → SRes V R
  | fuel, pos, stride =>
    match scan n look pos (iterW W (matchByteWord W (wb (load W ctrl pos)) t)) with
    | some (i, v) => .found i v
    | none => match stop (wb (load W ctrl pos)) pos with
      | some r => .stop r
      | none => match fuel with
        | 0 => .exhausted
        | f + 1 => searchW t look stop f ((pos + (stride + W)) &&& (n - 1)) (stride + W)

/-- `find_insert_slot` on group words. -/
def findInsertSlotW : (fuel pos stride : Nat) → Option Nat
  | fuel, pos, stride =>
    match lowestSetBit (matchEmptyWord W (wb (load W ctrl pos))) with
    | some bit => some ((pos + bit) &&& (n - 1))
    | none => match fuel with
      | 0 => none
      | f + 1 => findInsertSlotW f ((pos + (stride + W)) &&& (n - 1)) (stride + W)

end Loop

variable {W : Nat} {ctrl : Nat → Nat}

theorem load_bytes (hb : ∀ i, ctrl i < 256) (pos : Nat) : IsBytes (load W ctrl pos) := by
  intro x hx; simp only [load, List.mem_map] at hx; obtain ⟨_, _, rfl⟩ := hx; exact hb _

theorem mbw_load (hb : ∀ i, ctrl i < 256) {t : Nat} (ht : t < 0x80) (pos : Nat) :
    iterW W (matchByteWord W (wb (load W ctrl pos)) t) = bits (matchByteLE (load W ctrl pos) t) := by
  have := matchByteWord_eq _ (load_bytes (W := W) hb pos) t ht
  rw [load_length] at this
  rw [this, iterW_toMask]
  rw [(matchByteLE_ok _ _ ht).1, load_length]; exact Nat.le_refl _

theorem mew_load (hb : ∀ i, ctrl i < 256) (pos : Nat) :
    matchEmptyWord W (wb (load W ctrl pos)) = toMask (matchEmpty (load W ctrl pos)) := by
  have := matchEmptyWord_eq _ (load_bytes (W := W) hb pos)
  rwa [load_length] at this

theorem stopFindW_eq (hb : ∀ i, ctrl i < 256) (pos : Nat) :
    stopFindW W (wb (load W ctrl pos)) pos = stopFind (load W ctrl pos) pos := by
  unfold stopFindW stopFind; rw [mew_load hb, anyBitSet_toMask]

theorem stopPotentialW_eq (n : Nat) (hb : ∀ i, ctrl i < 256) (pos : Nat) :
    stopPotentialW W n (wb (load W ctrl pos)) pos = stopPotential n (load W ctrl pos) pos := by
  unfold stopPotentialW stopPotential; rw [mew_load hb, lowestSetBit_toMask]

/-- **The word-level `search` is the list-level `search` with `matchByteLE`.** -/
theorem searchW_eq {V R : Type} (n : Nat) (hb : ∀ i, ctrl i < 256) {t : Nat} (ht : t < 0x80)
    (look : Nat → Option V) (stopW : Nat → Nat → Option R) (stop : List Nat → Nat → Option R)
    (hs : ∀ pos, stopW (wb (load W ctrl pos)) pos = stop (load W ctrl pos) pos) :
    ∀ f pos s, searchW W n ctrl t look stopW f pos s = search W n ctrl matchByteLE t look stop f pos s
  | f, pos, s => by
    unfold searchW search
    rw [mbw_load hb ht, hs]
    cases scan n look pos (bits (matchByteLE (load W ctrl pos) t)) with
    | some p => rfl
    | none =>
      dsimp only
      cases stop (load W ctrl pos) pos with
      | some r => rfl
      | none =>
        cases f with
        | zero => rfl
        | succ f => exact searchW_eq n hb ht look stopW stop hs f _ _

theorem findInsertSlotW_eq (n : Nat) (hb : ∀ i, ctrl i < 256) :
    ∀ f pos s, findInsertSlotW W n ctrl f pos s = findInsertSlot W n ctrl f pos s
  | f, pos, s => by
    unfold findInsertSlotW findInsertSlot
    rw [mew_load hb, lowestSetBit_toMask]
    cases lsb (matchEmpty (load W ctrl pos)) with
    | some b => rfl
    | none =>
      cases f with
      | zero => rfl
      | succ f => exact findInsertSlotW_eq n hb f _ _

/-! ## `usize`: `h1` and `set_ctrl`'s replica index -/

/-- `h1(hash) = hash as usize` on a `u`-bit target. -/
def h1 (u hash : Nat) : Nat := hash % 2 ^ u

theorem pow2_dvd {n u : Nat} (hn : n.isPowerOfTwo) (hu : n ≤ 2 ^ u) : n ∣ 2 ^ u := by
  obtain ⟨a, rfl⟩ := hn
  apply Nat.pow_dvd_pow
  false_or_by_contra
  have : 2 ^ u < 2 ^ a := Nat.pow_lt_pow_right (by decide) (by omega)
  omega

theorem h1_mask {n u : Nat} (hn : n.isPowerOfTwo) (hu : n ≤ 2 ^ u) (hash : Nat) :
    h1 u hash &&& (n - 1) = hash &&& (n - 1) := by
  rw [mask_eq hn, mask_eq hn, h1, Nat.mod_mod_of_dvd _ (pow2_dvd hn hu)]

/-- The probe sequence only depends on `hash % n`, so `triSeq` of `h1 hash` is `triSeq` of `hash`. -/
theorem triSeq_h1 {n u : Nat} (hn : n.isPowerOfTwo) (hu : n ≤ 2 ^ u) (W hash : Nat) :
    triSeq W n (h1 u hash) = triSeq W n hash := by
  unfold triSeq; split
  · rfl
  · congr 1; funext j; congr 1; funext b
    rw [Nat.add_assoc, Nat.add_assoc, Nat.add_mod, h1, Nat.mod_mod_of_dvd _ (pow2_dvd hn hu),
      ← Nat.add_mod]

/-- `set_ctrl`'s `((index.wrapping_sub(W)) & bucket_mask) + W` on a `u`-bit `usize`. -/
def idx2Rust (u W n i : Nat) : Nat := (((i + 2 ^ u - W) % 2 ^ u) &&& (n - 1)) + W

theorem idx2Rust_eq {u W n i : Nat} (hn : n.isPowerOfTwo) (hu : n ≤ 2 ^ u)
    (hW : W ≤ n) : idx2Rust u W n i = (i + n - W) % n + W := by
  unfold idx2Rust
  rw [mask_eq hn, Nat.mod_mod_of_dvd _ (pow2_dvd hn hu)]
  obtain ⟨q, hq⟩ := pow2_dvd hn hu
  have hq1 : 1 ≤ q := by
    rcases q with _ | q
    · simp at hq
    · omega
  congr 1
  rw [hq, show i + n * q - W = (i + n - W) + n * (q - 1) by
    obtain ⟨r, rfl⟩ : ∃ r, q = r + 1 := ⟨q - 1, by omega⟩
    rw [Nat.mul_succ]; simp only [Nat.add_sub_cancel]
    generalize n * r = A; omega,
    Nat.add_mul_mod_self_left]

/-! ## End to end: Rust's generic code on a `u`-bit target -/

variable {K V : Type} [DecidableEq K] {hash : K → Nat} {h2 : Nat → Nat} {T : Table K V}

/-- Rust's `find` with the generic backend: word-level group code, `h1` as `hash as usize`. -/
def bfindW (u W : Nat) (hash : K → Nat) (h2 : Nat → Nat) (T : Table K V) (ctrl : Nat → Nat)
    (k : K) : SRes V Unit :=
  searchW W T.n ctrl (h2 (hash k)) (lookK T k) (stopFindW W) (T.n / W - 1)
    (h1 u (hash k) &&& (T.n - 1)) 0

def bfindPotentialW (u W : Nat) (hash : K → Nat) (h2 : Nat → Nat) (T : Table K V)
    (ctrl : Nat → Nat) (k : K) : SRes V Nat :=
  searchW W T.n ctrl (h2 (hash k)) (lookK T k) (stopPotentialW W T.n) (T.n / W - 1)
    (h1 u (hash k) &&& (T.n - 1)) 0

def bfindInsertSlotW (u W : Nat) (T : Table K V) (ctrl : Nat → Nat) (hash : Nat) : Option Nat :=
  findInsertSlotW W T.n ctrl (T.n / W - 1) (h1 u hash &&& (T.n - 1)) 0

/-- **Generic-backend `find` on machine words is `Table.find`.** -/
theorem bfindW_eq {u : Nat} (hW : W.isPowerOfTwo) (hc : Ctrl W hash h2 T ctrl)
    (hb : ∀ i, ctrl i < 256) (hh2 : ∀ h, h2 h < 0x80) (hw : WF (realCfg W hash) T)
    (hu : Uniq T) (hnu : T.n ≤ 2 ^ u) (k : K) :
    bfindW u W hash h2 T ctrl k =
      match find T k (ps (realCfg W hash) T k) with
      | some (i, v) => .found i v
      | none => .stop () := by
  unfold bfindW
  rw [h1_mask hw.pow2 hnu, searchW_eq _ hb (hh2 _) _ _ _ (stopFindW_eq hb)]
  exact search_find_eq hW hc hh2 matchByteLE_ok hw hu k

theorem bfindPotentialW_eq {u : Nat} (hW : W.isPowerOfTwo) (hc : Ctrl W hash h2 T ctrl)
    (hb : ∀ i, ctrl i < 256) (hh2 : ∀ h, h2 h < 0x80) (hw : WF (realCfg W hash) T)
    (hu : Uniq T) (hnu : T.n ≤ 2 ^ u) (k : K) :
    bfindPotentialW u W hash h2 T ctrl k =
      match find T k (ps (realCfg W hash) T k) with
      | some (i, v) => .found i v
      | none => match firstEmpty T (ps (realCfg W hash) T k) with
        | some e => .stop e
        | none => .exhausted := by
  unfold bfindPotentialW
  rw [h1_mask hw.pow2 hnu, searchW_eq _ hb (hh2 _) _ _ _ (stopPotentialW_eq _ hb)]
  exact search_potential_eq hW hc hh2 matchByteLE_ok hw hu k

omit [DecidableEq K] in
theorem bfindInsertSlotW_eq {u : Nat} (hc : Ctrl W hash h2 T ctrl) (hb : ∀ i, ctrl i < 256)
    (hh2 : ∀ h, h2 h < 0x80) (hn : T.n.isPowerOfTwo) (hW : 0 < W) (hnu : T.n ≤ 2 ^ u)
    (h : Nat) : bfindInsertSlotW u W T ctrl h = firstEmpty T (triSeq W T.n h) := by
  unfold bfindInsertSlotW
  rw [h1_mask hn hnu, findInsertSlotW_eq _ hb]
  exact findInsertSlot_eq hc hh2 hn hW h

end Word
end Bytes
end SyncTable
