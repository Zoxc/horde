import SyncTable.Word

/-!
# All three `Group` backends on machine words, and `usize` overflow of the probe

`Word.lean` modelled the little-endian generic backend with an 8-bit `BitMask` stride. This file
generalizes the `BitMask` word to any `BITMASK_STRIDE` `s` (bit `s*b + s-1` for byte `b`) and
runs `search` / `find_insert_slot` over an abstract backend (`Backend`: group word, `match_byte`
and `match_empty` on it, stride). `searchG_eq` / `findInsertSlotG_eq`: any backend whose word
operations agree with a list-level `match_byte` (`Agrees`) computes the list-level loops; with
`MatchOK` that gives `Table.find` / `Table.firstEmpty` (`bfindG_eq`, `bfindPotentialG_eq`,
`bfindInsertSlotG_eq`). Instances:

* `genericLE`: `generic.rs` on a little-endian target (`agrees_genericLE`).
* `genericBE`: `generic.rs` on a big-endian target: the group word is `from_be_bytes`
  (`wb g.reverse`), the masks are byte-swapped by `to_le` (`swapBytes`) (`agrees_genericBE`).
* `sse2`: `sse2.rs`: `match_byte` is `_mm_movemask_epi8(_mm_cmpeq_epi8(group, set1(byte)))`
  (`movemask`, `cmpeq` on the 16-byte little-endian word, stride 1), `match_empty` is
  `match_byte(EMPTY)` (`agrees_sse2`; it equals the generic `match_empty` on control bytes).

`usize` overflow (`probe_no_overflow`): the probe adds `pos + stride` (and `pos + bit`) in
`usize`. For a group `j` that `move_next` leaves (`j + 1 < n / W`; the loops never leave the
last group, `search_find_eq`), `pos + stride + W < 2 * n`, and `pos + b < n + W`. Both fit in
`usize` once `n + W ≤ isize::MAX = 2^(u-1) - 1`, which `TableRef::layout` enforces: the
control bytes alone are `bucket_count + Group::WIDTH` bytes (`ctrl_size`, `checked_add`) inside
the allocation, and `Layout::from_size_align` rejects sizes above `isize::MAX`, so
`allocate` panics ("capacity overflow") otherwise.
-/

namespace SyncTable
namespace Bytes
namespace Word

/-! ## `BitMask` words with any stride -/

/-- A mask as a `BitMask` word with `BITMASK_STRIDE = s`: byte `b` is bit `s*b + (s-1)`. -/
def toMaskS (s : Nat) : List Bool → Nat
  | [] => 0
  | b :: m => 2 ^ s * toMaskS s m + (if b then 2 ^ (s - 1) else 0)

/-- `lowest_set_bit`: `trailing_zeros / BITMASK_STRIDE`. -/
def lsbS (s x : Nat) : Option Nat := if x = 0 then none else some (tz x / s)

/-- `BitMaskIter` with stride `s` (fuel: one step per byte). -/
def iterS (s : Nat) : Nat → Nat → List Nat
  | 0, _ => []
  | f + 1, x => match lsbS s x with
    | none => []
    | some b => b :: iterS s f (removeLowestBit x)

theorem and_split_pow (s x y a b : Nat) (ha : a < 2 ^ s) (hb : b < 2 ^ s) :
    (2 ^ s * x + a) &&& (2 ^ s * y + b) = 2 ^ s * (x &&& y) + (a &&& b) := by
  have hab : a &&& b < 2 ^ s := Nat.and_lt_two_pow a hb
  apply Nat.eq_of_testBit_eq; intro i
  rw [Nat.testBit_and, Nat.testBit_two_pow_mul_add _ ha, Nat.testBit_two_pow_mul_add _ hb,
    Nat.testBit_two_pow_mul_add _ hab]
  split <;> simp [Nat.testBit_and]

theorem lsbS_shift {s : Nat} (hs : 0 < s) (Y : Nat) :
    lsbS s (2 ^ s * Y) = (lsbS s Y).map (· + 1) := by
  unfold lsbS
  by_cases hY : Y = 0
  · simp [hY]
  · rw [if_neg (Nat.mul_ne_zero (Nat.pos_iff_ne_zero.mp (Nat.two_pow_pos s)) hY), if_neg hY,
      tz_pow_mul hY]
    simp only [Option.map_some]; congr 1
    rw [Nat.add_div_right _ hs]

theorem pow_split {s : Nat} (hs : 0 < s) : 2 ^ s = 2 * 2 ^ (s - 1) := by
  obtain ⟨r, rfl⟩ : ∃ r, s = r + 1 := ⟨s - 1, by omega⟩
  rw [Nat.pow_succ, Nat.mul_comm]; rfl

theorem lsbS_low {s : Nat} (hs : 0 < s) (Y : Nat) : lsbS s (2 ^ s * Y + 2 ^ (s - 1)) = some 0 := by
  unfold lsbS
  have hq := Nat.two_pow_pos (s - 1)
  rw [if_neg (by omega)]
  have e : 2 ^ s * Y + 2 ^ (s - 1) = 2 ^ (s - 1) * (2 * Y + 1) := by
    rw [pow_split hs, Nat.mul_add, Nat.mul_one, ← Nat.mul_assoc, Nat.mul_comm 2 (2 ^ (s - 1))]
  rw [e, tz_pow_mul (by omega), tz_odd]
  congr 1; simp only [Nat.zero_add]; exact Nat.div_eq_of_lt (by omega)

theorem rlb_shift {s : Nat} (Y : Nat) : removeLowestBit (2 ^ s * Y) = 2 ^ s * removeLowestBit Y := by
  unfold removeLowestBit
  by_cases hY : Y = 0
  · simp [hY]
  · have hP := Nat.two_pow_pos s
    have hle : 2 ^ s ≤ 2 ^ s * Y := Nat.le_mul_of_pos_right _ (by omega)
    have e : 2 ^ s * Y - 1 = 2 ^ s * (Y - 1) + (2 ^ s - 1) := by
      rw [Nat.mul_sub_one]; omega
    rw [e, show 2 ^ s * Y = 2 ^ s * Y + 0 by rfl, and_split_pow _ _ _ _ _ hP (by omega)]
    simp

theorem rlb_low {s : Nat} (hs : 0 < s) (Y : Nat) :
    removeLowestBit (2 ^ s * Y + 2 ^ (s - 1)) = 2 ^ s * Y := by
  unfold removeLowestBit
  have hq := Nat.two_pow_pos (s - 1)
  have hps := pow_split hs
  rw [show 2 ^ s * Y + 2 ^ (s - 1) - 1 = 2 ^ s * Y + (2 ^ (s - 1) - 1) by omega,
    and_split_pow _ _ _ _ _ (by omega) (by omega), Nat.and_self,
    Nat.and_two_pow_sub_one_eq_mod, Nat.mod_self, Nat.add_zero]

theorem iterS_shift {s : Nat} (hs : 0 < s) : ∀ f Y, iterS s f (2 ^ s * Y) = (iterS s f Y).map (· + 1)
  | 0, _ => rfl
  | f + 1, Y => by
    simp only [iterS, lsbS_shift hs]
    cases lsbS s Y with
    | none => rfl
    | some b => simp [rlb_shift, iterS_shift hs f]

/-- **`BitMaskIter` on a stride-`s` word yields `bits`.** -/
theorem iterS_toMaskS {s : Nat} (hs : 0 < s) :
    ∀ (m : List Bool) (f : Nat), m.length ≤ f → iterS s f (toMaskS s m) = bits m
  | [], f, _ => by cases f <;> rfl
  | b :: m, f, hf => by
    rw [toMaskS, bits_cons]
    cases b with
    | true =>
      obtain ⟨f, rfl⟩ : ∃ f', f = f' + 1 := ⟨f - 1, by simp at hf; omega⟩
      simp only [iterS, if_true, lsbS_low hs, rlb_low hs, iterS_shift hs,
        iterS_toMaskS hs m f (by simp at hf; omega)]
      rfl
    | false =>
      simp only [Bool.false_eq_true, if_false, Nat.add_zero, iterS_shift hs,
        iterS_toMaskS hs m f (by simp at hf; omega), List.nil_append]

theorem lsbS_toMaskS {s : Nat} (hs : 0 < s) : ∀ m : List Bool, lsbS s (toMaskS s m) = lsb m
  | [] => rfl
  | b :: m => by
    rw [toMaskS, lsb_cons]
    cases b with
    | true => simp [lsbS_low hs]
    | false => simp [lsbS_shift hs, lsbS_toMaskS hs m]

theorem anyS_toMaskS (s : Nat) : ∀ m : List Bool, (toMaskS s m != 0) = m.any id
  | [] => rfl
  | b :: m => by
    rw [toMaskS]
    have := anyS_toMaskS s m
    have hq := Nat.two_pow_pos (s - 1)
    cases b
    · simp only [Bool.false_eq_true, if_false, Nat.add_zero, List.any_cons, id, Bool.false_or]
      rw [← this]
      by_cases hY : toMaskS s m = 0
      · rw [hY]; simp
      · have h' : 2 ^ s * toMaskS s m ≠ 0 :=
          Nat.mul_ne_zero (Nat.pos_iff_ne_zero.mp (Nat.two_pow_pos s)) hY
        rw [show (2 ^ s * toMaskS s m != 0) = true from bne_iff_ne.mpr h',
          show (toMaskS s m != 0) = true from bne_iff_ne.mpr hY]
    · simp only [if_true, List.any_cons, id, Bool.true_or]
      exact bne_iff_ne.mpr (by omega)

theorem toMaskS_eight : ∀ m : List Bool, toMaskS 8 m = toMask m
  | [] => rfl
  | b :: m => by rw [toMaskS, toMask_cons, toMaskS_eight m]

/-! ## Words to bytes -/

/-- The `L` little-endian bytes of a word. -/
def bytesOf : Nat → Nat → List Nat
  | 0, _ => []
  | L + 1, x => x % 256 :: bytesOf L (x / 256)

theorem bytesOf_wb : ∀ l : List Nat, IsBytes l → bytesOf l.length (wb l) = l
  | [], _ => rfl
  | x :: l, h => by
    rw [isBytes_cons] at h
    simp only [List.length_cons, bytesOf, wb]
    rw [show (256 * wb l + x) % 256 = x by omega, show (256 * wb l + x) / 256 = wb l by omega,
      bytesOf_wb l h.2]

/-- `to_le` on a big-endian target: reverse the bytes of an `L`-byte word. -/
def swapBytes (L x : Nat) : Nat := wb (bytesOf L x).reverse

/-- `_mm_movemask_epi8`: the top bit of each of the `L` bytes, bit `b` for byte `b`. -/
def movemask (L x : Nat) : Nat := toMaskS 1 ((bytesOf L x).map (fun c => decide (128 ≤ c)))

/-- `_mm_cmpeq_epi8(x, _mm_set1_epi8(t))`: `0xFF` where the byte equals `t`, else `0`. -/
def cmpeq (L x t : Nat) : Nat := wb ((bytesOf L x).map (fun c => if c = t then 255 else 0))

theorem isBytes_mask (m : List Bool) : IsBytes (m.map (fun b => if b then 0x80 else 0)) := by
  intro x hx; simp only [List.mem_map] at hx; obtain ⟨b, _, rfl⟩ := hx; split <;> decide

/-! ## Backends -/

/-- A `Group` implementation on words: `Group::load` as a word, `match_byte` / `match_empty` on
it, `BITMASK_STRIDE`. -/
structure Backend where
  word : List Nat → Nat
  mbyte : Nat → Nat → Nat
  mempty : Nat → Nat
  stride : Nat

/-- `generic.rs`, little-endian. -/
def genericLE (W : Nat) : Backend := ⟨wb, matchByteWord W, matchEmptyWord W, 8⟩

/-- `generic.rs`, big-endian: `from_be_bytes`, then `to_le` on the masks. -/
def genericBE (W : Nat) : Backend :=
  ⟨fun g => wb g.reverse, fun x t => swapBytes W (matchByteWord W x t),
   fun x => swapBytes W (matchEmptyWord W x), 8⟩

/-- `sse2.rs` (`W = 16`). -/
def sse2 (W : Nat) : Backend :=
  ⟨wb, fun x t => movemask W (cmpeq W x t), fun x => movemask W (cmpeq W x EMPTY), 1⟩

/-- The backend agrees with the list-level `match_byte` `mb` and `matchEmpty` on every group
the probe loads (`pos < n`). -/
structure Agrees (B : Backend) (W n : Nat) (ctrl : Nat → Nat) (mb : List Nat → Nat → List Bool) :
    Prop where
  stride : 0 < B.stride
  mbyte : ∀ pos < n, ∀ t < 0x80,
    B.mbyte (B.word (load W ctrl pos)) t = toMaskS B.stride (mb (load W ctrl pos) t)
  mempty : ∀ pos < n, B.mempty (B.word (load W ctrl pos)) = toMaskS B.stride (matchEmpty (load W ctrl pos))

section Loop
variable {V : Type} (B : Backend) (W n : Nat) (ctrl : Nat → Nat)

def stopFindG (x : Nat) (_pos : Nat) : Option Unit := if B.mempty x != 0 then some () else none

def stopPotentialG (x pos : Nat) : Option Nat :=
  (lsbS B.stride (B.mempty x)).map (fun bit => (pos + bit) &&& (n - 1))

/-- `search` over backend `B`. -/
def searchG {R : Type} (t : Nat) (look : Nat → Option V) (stop : Nat → Nat → Option R) :
    (fuel pos stride : Nat) → SRes V R
  | fuel, pos, stride =>
    match scan n look pos (iterS B.stride W (B.mbyte (B.word (load W ctrl pos)) t)) with
    | some (i, v) => .found i v
    | none => match stop (B.word (load W ctrl pos)) pos with
      | some r => .stop r
      | none => match fuel with
        | 0 => .exhausted
        | f + 1 => searchG t look stop f ((pos + (stride + W)) &&& (n - 1)) (stride + W)

/-- `find_insert_slot` over backend `B`. -/
def findInsertSlotG : (fuel pos stride : Nat) → Option Nat
  | fuel, pos, stride =>
    match lsbS B.stride (B.mempty (B.word (load W ctrl pos))) with
    | some bit => some ((pos + bit) &&& (n - 1))
    | none => match fuel with
      | 0 => none
      | f + 1 => findInsertSlotG f ((pos + (stride + W)) &&& (n - 1)) (stride + W)

end Loop

section
variable {B : Backend} {W n : Nat} {ctrl : Nat → Nat} {mb : List Nat → Nat → List Bool}

theorem stopFindG_eq (hA : Agrees B W n ctrl mb) {pos : Nat} (hpos : pos < n) :
    stopFindG B (B.word (load W ctrl pos)) pos = stopFind (load W ctrl pos) pos := by
  unfold stopFindG stopFind; rw [hA.mempty pos hpos, anyS_toMaskS]

theorem stopPotentialG_eq (hA : Agrees B W n ctrl mb) {pos : Nat} (hpos : pos < n) :
    stopPotentialG B n (B.word (load W ctrl pos)) pos = stopPotential n (load W ctrl pos) pos := by
  unfold stopPotentialG stopPotential; rw [hA.mempty pos hpos, lsbS_toMaskS hA.stride]

theorem mask_lt {n : Nat} (hn : n.isPowerOfTwo) (x : Nat) : x &&& (n - 1) < n := by
  rw [mask_eq hn]; exact Nat.mod_lt _ (Nat.pos_of_isPowerOfTwo hn)

/-- **`search` over an agreeing backend is the list-level `search`.** -/
theorem searchG_eq {V R : Type} (hA : Agrees B W n ctrl mb) (hmb : MatchOK mb) (hn : n.isPowerOfTwo)
    {t : Nat} (ht : t < 0x80) (look : Nat → Option V) (stopW : Nat → Nat → Option R)
    (stop : List Nat → Nat → Option R)
    (hs : ∀ pos < n, stopW (B.word (load W ctrl pos)) pos = stop (load W ctrl pos) pos) :
    ∀ f pos s, pos < n → searchG B W n ctrl t look stopW f pos s = search W n ctrl mb t look stop f pos s
  | f, pos, s, hpos => by
    unfold searchG search
    rw [hA.mbyte pos hpos t ht, iterS_toMaskS hA.stride _ _ (by
      rw [(hmb _ _ ht).1, load_length]; exact Nat.le_refl _), hs pos hpos]
    cases scan n look pos (bits (mb (load W ctrl pos) t)) with
    | some p => rfl
    | none =>
      dsimp only
      cases stop (load W ctrl pos) pos with
      | some r => rfl
      | none =>
        cases f with
        | zero => rfl
        | succ f => exact searchG_eq hA hmb hn ht look stopW stop hs f _ _ (mask_lt hn _)

theorem findInsertSlotG_eq (hA : Agrees B W n ctrl mb) (hn : n.isPowerOfTwo) :
    ∀ f pos s, pos < n → findInsertSlotG B W n ctrl f pos s = findInsertSlot W n ctrl f pos s
  | f, pos, s, hpos => by
    unfold findInsertSlotG findInsertSlot
    rw [hA.mempty pos hpos, lsbS_toMaskS hA.stride]
    cases lsb (matchEmpty (load W ctrl pos)) with
    | some b => rfl
    | none =>
      cases f with
      | zero => rfl
      | succ f => exact findInsertSlotG_eq hA hn f _ _ (mask_lt hn _)

end

/-! ## The three backends agree -/

variable {W : Nat} {ctrl : Nat → Nat}

theorem agrees_genericLE (n : Nat) (hb : ∀ i, ctrl i < 256) :
    Agrees (genericLE W) W n ctrl matchByteLE := by
  refine ⟨show 0 < 8 by decide, fun pos _ t ht => ?_, fun pos _ => ?_⟩
  · show matchByteWord W (wb (load W ctrl pos)) t = _
    have := matchByteWord_eq _ (load_bytes (W := W) hb pos) t ht
    rw [load_length] at this; rw [this]; exact (toMaskS_eight _).symm
  · show matchEmptyWord W (wb (load W ctrl pos)) = _
    rw [mew_load hb]; exact (toMaskS_eight _).symm

theorem toMask_reverse (m : List Bool) (L : Nat) (hL : m.length = L) :
    wb (bytesOf L (toMask m)).reverse = toMask m.reverse := by
  unfold toMask
  have := bytesOf_wb _ (isBytes_mask m)
  simp only [List.length_map, hL] at this
  rw [this, List.map_reverse]

theorem agrees_genericBE (n : Nat) (hb : ∀ i, ctrl i < 256) :
    Agrees (genericBE W) W n ctrl matchByteBE := by
  have hbr : ∀ pos, IsBytes (load W ctrl pos).reverse := fun pos x hx =>
    load_bytes (W := W) hb pos x (List.mem_reverse.mp hx)
  refine ⟨show 0 < 8 by decide, fun pos _ t ht => ?_, fun pos _ => ?_⟩
  · show swapBytes W (matchByteWord W (wb (load W ctrl pos).reverse) t) = _
    have := matchByteWord_eq _ (hbr pos) t ht
    rw [List.length_reverse, load_length] at this
    rw [this, swapBytes, toMask_reverse _ W (by
      simp [matchByteLE, (mbGo_ok t ht _ 0 (by omega)).1, load_length])]
    exact (toMaskS_eight _).symm
  · show swapBytes W (matchEmptyWord W (wb (load W ctrl pos).reverse)) = _
    have := matchEmptyWord_eq _ (hbr pos)
    rw [List.length_reverse, load_length] at this
    rw [this, swapBytes, toMask_reverse _ W (by simp [matchEmpty, load_length]),
      show (matchEmpty (load W ctrl pos).reverse).reverse = matchEmpty (load W ctrl pos) by
        simp [matchEmpty, List.map_reverse]]
    exact (toMaskS_eight _).symm

theorem agrees_sse2 {K V : Type} {hash : K → Nat} {h2 : Nat → Nat} {T : Table K V}
    (hc : Ctrl W hash h2 T ctrl) (hh2 : ∀ h, h2 h < 0x80) (hn : T.n.isPowerOfTwo)
    (hb : ∀ i, ctrl i < 256) : Agrees (sse2 W) W T.n ctrl matchByteSSE2 := by
  have hbytes : ∀ pos, bytesOf W (wb (load W ctrl pos)) = load W ctrl pos := fun pos => by
    have := bytesOf_wb _ (load_bytes (W := W) hb pos); rwa [load_length] at this
  have hcm : ∀ pos t, bytesOf W (cmpeq W (wb (load W ctrl pos)) t) =
      (load W ctrl pos).map (fun c => if c = t then 255 else 0) := fun pos t => by
    unfold cmpeq; rw [hbytes]
    have := bytesOf_wb ((load W ctrl pos).map (fun c => if c = t then 255 else 0)) (by
      intro x hx; simp only [List.mem_map] at hx; obtain ⟨_, _, rfl⟩ := hx; split <;> decide)
    rwa [List.length_map, load_length] at this
  have hmm : ∀ pos t, movemask W (cmpeq W (wb (load W ctrl pos)) t) =
      toMaskS 1 ((load W ctrl pos).map (· == t)) := fun pos t => by
    unfold movemask; rw [hcm, List.map_map]
    congr 1; apply List.map_congr_left; intro c _
    simp only [Function.comp_apply]; split <;> simp_all
  refine ⟨show 0 < 1 by decide, fun pos _ t _ => hmm pos t, fun pos hpos => ?_⟩
  show movemask W (cmpeq W (wb (load W ctrl pos)) EMPTY) = _
  rw [hmm]; congr 1
  unfold matchEmpty load; simp only [List.map_map]
  apply List.map_congr_left; intro b hb'
  simp only [List.mem_range] at hb'
  simp only [Function.comp_apply]
  rw [ctrl_mirror hc (Nat.pos_of_isPowerOfTwo hn) hpos hb',
    matchEmptyByte_iff _ (ctrl_valid hc hh2 (Nat.mod_lt _ (Nat.pos_of_isPowerOfTwo hn)))]

/-! ## End to end over any agreeing backend -/

variable {K V : Type} [DecidableEq K] {hash : K → Nat} {h2 : Nat → Nat} {T : Table K V}

def bfindG (B : Backend) (u W : Nat) (hash : K → Nat) (h2 : Nat → Nat) (T : Table K V)
    (ctrl : Nat → Nat) (k : K) : SRes V Unit :=
  searchG B W T.n ctrl (h2 (hash k)) (lookK T k) (stopFindG B) (T.n / W - 1)
    (h1 u (hash k) &&& (T.n - 1)) 0

def bfindPotentialG (B : Backend) (u W : Nat) (hash : K → Nat) (h2 : Nat → Nat) (T : Table K V)
    (ctrl : Nat → Nat) (k : K) : SRes V Nat :=
  searchG B W T.n ctrl (h2 (hash k)) (lookK T k) (stopPotentialG B T.n) (T.n / W - 1)
    (h1 u (hash k) &&& (T.n - 1)) 0

def bfindInsertSlotG (B : Backend) (u W : Nat) (T : Table K V) (ctrl : Nat → Nat) (hash : Nat) :
    Option Nat :=
  findInsertSlotG B W T.n ctrl (T.n / W - 1) (h1 u hash &&& (T.n - 1)) 0

/-- **`find` over any agreeing backend (generic LE/BE, SSE2) is `Table.find`.** -/
theorem bfindG_eq {B : Backend} {mb : List Nat → Nat → List Bool} {u : Nat}
    (hA : Agrees B W T.n ctrl mb) (hmb : MatchOK mb) (hW : W.isPowerOfTwo)
    (hc : Ctrl W hash h2 T ctrl) (hh2 : ∀ h, h2 h < 0x80) (hw : WF (realCfg W hash) T)
    (hu : Uniq T) (hnu : T.n ≤ 2 ^ u) (k : K) :
    bfindG B u W hash h2 T ctrl k =
      match find T k (ps (realCfg W hash) T k) with
      | some (i, v) => .found i v
      | none => .stop () := by
  unfold bfindG
  rw [h1_mask hw.pow2 hnu, searchG_eq hA hmb hw.pow2 (hh2 _) _ _ _
    (fun pos hp => stopFindG_eq hA hp) _ _ _ (mask_lt hw.pow2 _)]
  exact search_find_eq hW hc hh2 hmb hw hu k

theorem bfindPotentialG_eq {B : Backend} {mb : List Nat → Nat → List Bool} {u : Nat}
    (hA : Agrees B W T.n ctrl mb) (hmb : MatchOK mb) (hW : W.isPowerOfTwo)
    (hc : Ctrl W hash h2 T ctrl) (hh2 : ∀ h, h2 h < 0x80) (hw : WF (realCfg W hash) T)
    (hu : Uniq T) (hnu : T.n ≤ 2 ^ u) (k : K) :
    bfindPotentialG B u W hash h2 T ctrl k =
      match find T k (ps (realCfg W hash) T k) with
      | some (i, v) => .found i v
      | none => match firstEmpty T (ps (realCfg W hash) T k) with
        | some e => .stop e
        | none => .exhausted := by
  unfold bfindPotentialG
  rw [h1_mask hw.pow2 hnu, searchG_eq hA hmb hw.pow2 (hh2 _) _ _ _
    (fun pos hp => stopPotentialG_eq hA hp) _ _ _ (mask_lt hw.pow2 _)]
  exact search_potential_eq hW hc hh2 hmb hw hu k

omit [DecidableEq K] in
theorem bfindInsertSlotG_eq {B : Backend} {mb : List Nat → Nat → List Bool} {u : Nat}
    (hA : Agrees B W T.n ctrl mb) (hc : Ctrl W hash h2 T ctrl) (hh2 : ∀ h, h2 h < 0x80)
    (hn : T.n.isPowerOfTwo) (hW : 0 < W) (hnu : T.n ≤ 2 ^ u) (h : Nat) :
    bfindInsertSlotG B u W T ctrl h = firstEmpty T (triSeq W T.n h) := by
  unfold bfindInsertSlotG
  rw [h1_mask hn hnu, findInsertSlotG_eq hA hn _ _ _ (mask_lt hn _)]
  exact findInsertSlot_eq hc hh2 hn hW h

/-! ## `usize` overflow -/

/-- **The probe arithmetic does not overflow `usize`.** For every group `j` that `move_next`
leaves, `pos + (stride + W)` (Rust adds `stride += W; pos += stride`) is `< 2^u`, and so is
every `pos + bit`, given `n + W ≤ isize::MAX` (`layout`'s `ctrl_size` must fit). Also
`stride ≤ bucket_mask` (`move_next`'s `debug_assert`). -/
theorem probe_no_overflow {n u : Nat} (hn : n.isPowerOfTwo) (hW : 0 < W) (hWn : W ≤ n)
    (hlim : n + W ≤ 2 ^ (u - 1) - 1) (hu : 1 ≤ u) (h j : Nat) (hj : j + 1 < n / W) :
    (probeAt W n h j).1 + ((probeAt W n h j).2 + W) < 2 ^ u ∧
    (∀ b < W, (probeAt W n h j).1 + b < 2 ^ u) ∧ (probeAt W n h j).2 ≤ n - 1 := by
  have hpu : 2 ^ u = 2 * 2 ^ (u - 1) := pow_split (by omega)
  rw [probeAt_eq W n h hn]
  have hp := Nat.mod_lt (h + W * (j * (j + 1) / 2)) (Nat.pos_of_isPowerOfTwo hn)
  have hs : W * (j + 1) ≤ n := by
    have := Nat.mul_div_le n W
    have : W * (j + 1) ≤ W * (n / W) := Nat.mul_le_mul_left _ (by omega)
    omega
  rw [Nat.mul_succ] at hs
  refine ⟨by omega, fun b hb => by omega, by dsimp only; omega⟩

end Word
end Bytes
end SyncTable
