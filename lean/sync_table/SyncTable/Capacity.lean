/-!
# Capacity arithmetic (`bucket_mask_to_capacity`, `capacity_to_buckets`, `expand_by`)

All arithmetic is on `Nat`: `usize` overflow (which Rust turns into a
"capacity overflow" panic) is not modelled.
-/

namespace SyncTable

/-- `bucket_mask_to_capacity` -/
def bmc (mask : Nat) : Nat := if mask < 8 then mask else ((mask + 1) / 8) * 7

/-- `capacity_to_buckets` (without the overflow check). `W` is `Group::WIDTH`. -/
def c2b (W cap : Nat) : Nat :=
  max (if cap < 8 then (if cap < 4 then 4 else 8) else (cap * 8 / 7).nextPowerOfTwo) W

/-- The usable capacity is always below the number of buckets, so a table that respects
its `growth_left` always has an `EMPTY` bucket (this makes probing terminate). -/
theorem bmc_lt (m : Nat) (h : 0 < m) : bmc (m - 1) < m := by
  unfold bmc; split <;> omega

/-- `bucket_mask_to_capacity` is monotone in the number of buckets. -/
theorem bmc_mono {a b : Nat} (ha : 0 < a) (h : a ≤ b) : bmc (a - 1) ≤ bmc (b - 1) := by
  unfold bmc
  split <;> split <;> omega

private theorem pow2_ge9 {B : Nat} (hp : B.isPowerOfTwo) (h : 9 ≤ B) : ∃ q, B = 8 * q := by
  obtain ⟨k, rfl⟩ := hp
  match k with
  | 0 | 1 | 2 | 3 => simp at h
  | k + 4 => exact ⟨2 ^ (k + 1), by simp only [Nat.pow_succ]; omega⟩

/-- **`capacity_to_buckets` is sound**: the resulting bucket count is a power of two whose
capacity is at least the requested one. -/
theorem c2b_sound (W cap : Nat) (hW : W.isPowerOfTwo) (hc : 0 < cap) :
    (c2b W cap).isPowerOfTwo ∧ cap ≤ bmc (c2b W cap - 1) := by
  have hmax : ∀ r, r.isPowerOfTwo → cap ≤ bmc (r - 1) →
      (max r W).isPowerOfTwo ∧ cap ≤ bmc (max r W - 1) := by
    intro r hr hcap
    refine ⟨?_, Nat.le_trans hcap (bmc_mono (Nat.pos_of_isPowerOfTwo hr) (Nat.le_max_left _ _))⟩
    rcases Nat.le_total r W with h | h
    · rw [Nat.max_eq_right h]; exact hW
    · rw [Nat.max_eq_left h]; exact hr
  unfold c2b
  apply hmax
  · split
    · split
      · exact ⟨2, rfl⟩
      · exact ⟨3, rfl⟩
    · exact Nat.isPowerOfTwo_nextPowerOfTwo _
  · split
    · split <;> (unfold bmc; simp) <;> omega
    · rename_i h8
      have hle := Nat.le_nextPowerOfTwo (cap * 8 / 7)
      obtain ⟨q, hq⟩ := pow2_ge9 (Nat.isPowerOfTwo_nextPowerOfTwo (cap * 8 / 7)) (by omega)
      rw [hq] at hle ⊢
      unfold bmc
      split <;> omega

/-- The capacity `expand_by` asks for. -/
def expandCap (items additional mask : Nat) : Nat :=
  let newItems := items + additional
  let full := bmc mask
  if newItems ≤ full / 2 then newItems * 2 else max newItems (full + 1)

/-- **`expand_by` makes room**: the new table can hold every current item plus
`additional` more. -/
theorem expand_by_room (W items additional mask : Nat) (hW : W.isPowerOfTwo)
    (ha : 0 < additional) :
    (c2b W (expandCap items additional mask)).isPowerOfTwo ∧
    items + additional ≤ bmc (c2b W (expandCap items additional mask) - 1) := by
  have hpos : 0 < expandCap items additional mask := by
    unfold expandCap; simp only; split <;> omega
  obtain ⟨hp, hc⟩ := c2b_sound W _ hW hpos
  refine ⟨hp, Nat.le_trans ?_ hc⟩
  unfold expandCap; simp only; split <;> omega

/-- When the table is more than half full, `expand_by` strictly grows the capacity
(so repeated `insert`s trigger amortised doubling rather than same-size rehashes). -/
theorem expand_by_grows (W items additional mask : Nat) (hW : W.isPowerOfTwo)
    (ha : 0 < additional) (h : bmc mask / 2 < items + additional) :
    bmc mask < bmc (c2b W (expandCap items additional mask) - 1) := by
  have hpos : 0 < expandCap items additional mask := by
    unfold expandCap; simp only; split <;> omega
  have hc := (c2b_sound W _ hW hpos).2
  refine Nat.lt_of_lt_of_le ?_ hc
  unfold expandCap; simp only; split <;> omega

end SyncTable
