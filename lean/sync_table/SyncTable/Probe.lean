import SyncTable.Table

/-!
# The concrete probe sequence (`ProbeSeq`, `Group`)

`search` / `find_insert_slot` load a group of `W = Group::WIDTH` control bytes at `pos`,
examine its bytes in order (`match_byte`, `match_empty`, `lowest_set_bit`), and then move
to `pos + stride` with `stride` growing by `W` each step (triangular numbers), masked by
`bucket_mask`. Flattened to single buckets, group `j` covers buckets
`(h + W * (j*(j+1)/2) + b) mod n` for `b < W`.

"First `EMPTY` in the first group that has one, lowest bit first" is the first `EMPTY` of
the flattened list, so `Table.firstEmpty` matches `find_insert_slot`. The concurrent reader
(`Model.lean`) does not use `Table.find`: it loads each group byte by byte at independent
moments (`Group::load` can shear), checks every match of the group before `match_empty`, and
allows any chunking of the probe sequence into groups, which covers the `W`-chunks of `triSeq`
(`Bytes.triSeq_chunks`). That `Table.find` equals Rust's sequential `search` on a static table,
and `firstEmpty` its `find_insert_slot`, is proved at the byte level in `Bytes.lean`
(`search_find_eq`, `findInsertSlot_eq`).

Tables smaller than a group exist only as the static empty table (`n = 1`), for which the
model uses `[0, n)`.
-/

namespace SyncTable

/-- Flattened triangular group probe. -/
def triSeq (W n h : Nat) : List Nat :=
  if n < W then List.range n else
  (List.range (n / W)).flatMap
    (fun j => (List.range W).map (fun b => (h + W * (j * (j + 1) / 2) + b) % n))

theorem triSeq_lt (W n h x : Nat) (hx : x ∈ triSeq W n h) : x < n := by
  unfold triSeq at hx
  split at hx
  · simpa using hx
  · simp only [List.mem_flatMap, List.mem_range, List.mem_map] at hx
    obtain ⟨j, hj, b, _, rfl⟩ := hx
    apply Nat.mod_lt
    rename_i hnw
    omega

/-- The hashing configuration of the real table for a given `Group::WIDTH`. -/
def realCfg {K : Type} (W : Nat) (hash : K → Nat) : Cfg K :=
  { hash := hash, seq := triSeq W, seq_lt := triSeq_lt W }

/-- Reflection `j ↦ 2P-1-j` shifts the triangular number by `P * odd`. -/
theorem tri_refl (P j : Nat) (hj : j < P) :
    (2*P-1-j) * (2*P-1-j+1) / 2 = j*(j+1)/2 + P*(2*(P-1-j)+1) := by
  obtain ⟨c, rfl⟩ : ∃ c, P = c + j + 1 := ⟨P - j - 1, by omega⟩
  have e1 : 2*(c+j+1)-1-j = 2*c+j+1 := by omega
  have e2 : c+j+1-1-j = c := by omega
  rw [e1, e2]
  have : (2*c+j+1)*(2*c+j+1+1) = j*(j+1) + 2*((c+j+1)*(2*c+1)) := by grind
  rw [this]; generalize j*(j+1) = x; generalize (c+j+1)*(2*c+1) = y; omega

/-- Triangular numbers `j(j+1)/2` for `j < 2^k` hit every residue mod `2^k`. -/
theorem tri_surj (k : Nat) : ∀ q < 2^k, ∃ j < 2^k, j*(j+1)/2 % 2^k = q := by
  induction k with
  | zero => intro q hq; exact ⟨0, by simp, by simp at hq ⊢; omega⟩
  | succ k ih =>
    intro q hq
    have hP : 0 < 2^k := Nat.two_pow_pos k
    have hM : 2^(k+1) = 2*2^k := by rw [Nat.pow_succ]; omega
    obtain ⟨j, hj, hjq⟩ := ih (q % 2^k) (Nat.mod_lt _ hP)
    -- T j mod 2^(k+1) is either q or q ± 2^k
    have hmod : j*(j+1)/2 % 2^(k+1) % 2^k = q % 2^k := by
      rw [hM, Nat.mod_mul_left_mod]; exact hjq
    rw [hM] at hq ⊢
    by_cases h : j*(j+1)/2 % (2*2^k) = q
    · exact ⟨j, by omega, h⟩
    · refine ⟨2*2^k-1-j, by omega, ?_⟩
      rw [tri_refl _ _ hj]
      rw [hM] at hmod
      generalize j*(j+1)/2 = t at h hmod ⊢
      generalize hc : 2^k-1-j = c
      rw [Nat.mul_add, Nat.mul_one, Nat.mul_left_comm, ← Nat.mul_assoc, ← Nat.add_assoc,
        Nat.add_right_comm, Nat.add_mul_mod_self_left]
      generalize 2^k = P at *
      have := Nat.mod_lt t (show 0 < 2*P by omega)
      have hmP : ∀ x, x < 2*P → x % P = if x < P then x else x - P := by
        intro x hx; split
        · exact Nat.mod_eq_of_lt (by omega)
        · rw [Nat.mod_eq_sub_mod (by omega), Nat.mod_eq_of_lt (by omega)]
      have hsum : (t + P) % (2*P) = if t % (2*P) < P then t % (2*P) + P else t % (2*P) - P := by
        rw [Nat.add_mod, Nat.mod_eq_of_lt (show P < 2*P by omega)]
        split
        · exact Nat.mod_eq_of_lt (by omega)
        · rw [Nat.mod_eq_sub_mod (by omega), Nat.mod_eq_of_lt (by omega)]; omega
      rw [hmP _ this, hmP _ hq] at hmod
      rw [hsum]
      split at hmod <;> split at hmod <;> split <;> omega

theorem cover_aux (W m h i : Nat) (hW : 0 < W) (hm : ∃ k, m = 2^k) (hi : i < W*m) :
    ∃ j < m, ∃ b < W, (h + W * (j*(j+1)/2) + b) % (W*m) = i := by
  obtain ⟨k, rfl⟩ := hm
  generalize hn : W * 2^k = n at *
  have hn0 : 0 < n := by omega
  have hhn := Nat.mod_lt h hn0
  let d := (i + n - h % n) % n
  have hd : d < n := Nat.mod_lt _ hn0
  have hq : d / W < 2^k := by
    rw [Nat.div_lt_iff_lt_mul hW, Nat.mul_comm]; omega
  obtain ⟨j, hj, hjq⟩ := tri_surj k _ hq
  refine ⟨j, hj, d % W, Nat.mod_lt _ hW, ?_⟩
  have e1 : W * (j*(j+1)/2) % n = W * (d / W) := by
    rw [← hn, Nat.mul_mod_mul_left, hjq]
  have e2 : W * (d / W) + d % W = d := Nat.div_add_mod d W
  rw [Nat.add_assoc, Nat.add_mod, Nat.add_mod (W * _), e1,
    Nat.mod_eq_of_lt (show d % W < n from Nat.lt_of_le_of_lt (Nat.mod_le _ _) hd),
    e2, Nat.mod_eq_of_lt hd]
  show (h % n + (i + n - h % n) % n) % n = i
  rw [Nat.add_mod_mod, show h % n + (i + n - h % n) = i + n by omega, Nat.add_mod_right,
    Nat.mod_eq_of_lt hi]

/-- **Triangular probing visits every bucket** (for power-of-two `W ≤ n`), i.e. the claim in
the `ProbeSeq` doc comment (fgiesen's proof). With `n < W` the sequence is `[0, n)`.

Proof: `tri_surj` (surjectivity of `j(j+1)/2` mod `2^k`, by induction on `k` using
`tri_refl`), then `cover_aux` picks the group and offset. -/
theorem triSeq_cover {K : Type} (W : Nat) (hash : K → Nat) (hW : W.isPowerOfTwo) :
    (realCfg W hash).Cover := by
  intro n h i hn hi
  show i ∈ triSeq W n h
  unfold triSeq
  split
  · simpa using hi
  · rename_i hnw
    obtain ⟨a, rfl⟩ := hn
    obtain ⟨b, rfl⟩ := hW
    have hba : b ≤ a := by
      false_or_by_contra
      have : 2^a < 2^b := Nat.pow_lt_pow_right (by decide) (by omega)
      omega
    have hsplit : 2^a = 2^b * 2^(a-b) := by rw [← Nat.pow_add]; congr 1; omega
    have hdiv : 2^a / 2^b = 2^(a-b) := by
      rw [hsplit, Nat.mul_div_cancel_left _ (Nat.two_pow_pos b)]
    rw [hsplit] at hi
    obtain ⟨j, hj, c, hc, he⟩ := cover_aux (2^b) (2^(a-b)) h i (Nat.two_pow_pos b) ⟨_, rfl⟩ hi
    simp only [List.mem_flatMap, List.mem_range, List.mem_map]
    exact ⟨j, by rw [hdiv]; exact hj, c, hc, by rw [hsplit]; exact he⟩

end SyncTable
