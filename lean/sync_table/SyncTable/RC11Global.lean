import SyncTable.RC11Table
import SyncTable.Contract

/-!
# Property 18, global form: all `get`s of a reader thread over RC11 graphs

`RC11Table.lean` places the loads of **one** `get` at monotone writer versions. Across `get`s
of one thread that fails for exactly one byte: `set_ctrl_release` stores the primary control
byte and then its replica, so a reader that saw the primary byte of operation `a` may later
load the replica with its value from before `a`. This file proves that this never changes a
result, and that all `get`s of a reader thread are linearizable, in program order, against the
writer's operations.

* `chain_view` (generic graphs): a reader's whole `po`-chain of `Acquire` loads (any locations)
  has monotone versions `x i` (at least an operation completed before the load, at most an
  operation the load happens before) such that only operation `x i` itself may have stored the
  loaded location after the store read; two loads of one location read in operation order.
* `chain_replicaSync` (the true form of `ReplicaSync` for a chain of control-byte loads): load `i`
  returns the canonical byte of its bucket's slot after operation `x i`, or after `x i - 1`
  (the lagging replica of the bucket operation `x i` changed, `lo i < x i`), and a lagging load
  never follows a load of the same position that saw the new byte.
* `Hist`: the table after each writer operation, consecutive versions related by `TStep`
  (nothing, an insert of an absent key into `find_insert_slot`'s bucket, or a remove: the
  contract-respecting model writer steps, `tstep_of_step`, `hist_of_run`), with `WF` and unique
  keys.
* `ObsOK`: a load good for a lookup of `k`; `obsOK_exact` (the slot at the placement),
  `obsOK_fwd` / `obsOK_lag`: a load of the bucket an operation changes, placed on the other side
  of the operation, is good for every key the operation does not insert or remove (`EMPTY →
  FULL(κ)` and `FULL(κ) → DELETED(κ)` are irrelevant to other keys: a lagging `EMPTY` is a valid
  stop because every other key present after the insert was inserted while that bucket was
  `EMPTY`, so it lies before it on its probe sequence; tombstones are never reused and `EMPTY`
  is never written after initialisation).
* `get_valid`: a lookup over good loads is `Valid` (`some w`: the pair is in the table,
  `none`: the key is not) at a version between its smallest and largest placement (the
  sequentially consistent `get_linearizable` argument on per-load placements).
* `reader_lin`: **the global refinement for a reader's `get`s**. The placements are shifted
  down by one, for the loads of one version up to the last lagging load of a `get` of the key
  the operation involves; every other mismatch is with a key the operation does not involve
  (same key and bucket means same position, `hkey`, and coherence excludes a lagging load after
  a fresh one at one position). Every `get` gets a version `ℓ G` within its loads' placements,
  monotone in program order, in its `hb` window, at which its Rust result (`rustGet`, the
  group decisions of `Link.lean` on the loaded bytes) is `Valid`. `valid_hist` turns `Valid`
  into agreement with the model's abstract map (current or retired table).
-/

namespace SyncTable.RC11Global
open RC11 RC11.Graph SyncTable.RC11Table

/-! ## A reader's whole chain of loads: placement with one lagging byte -/

section Chain
variable {E L V : Type}

/-- The greedy placement with a per-load lower bound `lo`. -/
def xl (lo a : Nat → Nat) : Nat → Nat
  | 0 => max (lo 0) (a 0)
  | i + 1 => max (max (xl lo a i) (lo (i + 1))) (a (i + 1))

theorem xl_mono (lo a : Nat → Nat) {k : Nat} : ∀ i, k ≤ i → xl lo a k ≤ xl lo a i
  | 0, h => by rw [Nat.le_zero.1 h]; exact Nat.le_refl _
  | i + 1, h => by
    rcases Nat.lt_or_eq_of_le h with h | h
    · exact Nat.le_trans (xl_mono lo a i (by omega))
        (Nat.le_trans (Nat.le_max_left _ _) (Nat.le_max_left _ _))
    · rw [h]; exact Nat.le_refl _

theorem xl_ge_lo (lo a : Nat → Nat) : ∀ i, lo i ≤ xl lo a i
  | 0 => Nat.le_max_left _ _
  | _ + 1 => Nat.le_trans (Nat.le_max_right _ _) (Nat.le_max_left _ _)

theorem xl_ge_a (lo a : Nat → Nat) : ∀ i, a i ≤ xl lo a i
  | 0 => Nat.le_max_right _ _
  | _ + 1 => Nat.le_max_right _ _

theorem xl_le (lo a : Nat → Nat) {j : Nat} :
    ∀ i, (∀ k, k ≤ i → lo k ≤ j ∧ a k ≤ j) → xl lo a i ≤ j
  | 0, h => Nat.max_le.2 ⟨(h 0 (Nat.le_refl _)).1, (h 0 (Nat.le_refl _)).2⟩
  | i + 1, h => Nat.max_le.2 ⟨Nat.max_le.2 ⟨xl_le lo a i (fun k hk => h k (by omega)),
      (h _ (Nat.le_refl _)).1⟩, (h _ (Nat.le_refl _)).2⟩

theorem xl_gt (lo a : Nat → Nat) {j i : Nat} (h : j < xl lo a i) :
    ∃ k, k ≤ i ∧ (j < lo k ∨ j < a k) := by
  apply Classical.byContradiction; intro hn
  exact Nat.lt_irrefl _ (Nat.lt_of_lt_of_le h (xl_le lo a i (fun k hk => by
    refine ⟨Nat.le_of_not_lt (fun h1 => hn ⟨k, hk, .inl h1⟩),
      Nat.le_of_not_lt (fun h1 => hn ⟨k, hk, .inr h1⟩)⟩)))

/-- **A reader's whole `po`-chain of `Acquire` loads** (any number of `get`s, any locations),
load `i` reading the store `w i` of writer operation `a i`. `lo i` (monotone) is a writer
operation whose stores to the loaded location all happen before load `i` (`hlo`; e.g. one whose
lock release happens before it). There are monotone versions `x i ≥ lo i, a i` such that:
no operation strictly between `a i` and `x i` stores the loaded location (so load `i` returns
`vof (x i)` or, if operation `x i` itself stores the location, `vof (x i - 1)`, and then
`lo i < x i`); `x i` is below every operation load `i` happens before; and two loads of one
location read stores in operation order (coherence). Unlike `view`, nothing is assumed about
which locations one operation stores: the one-lagging-byte case is part of the result. -/
theorem chain_view (X : Writer E L V) {m : Nat} {lo : Nat → Nat} {r w : Nat → E} {a : Nat → Nat}
    (hrf : ∀ i, i < m → X.G.rf (w i) (r i))
    (hop : ∀ i, i < m → X.op (w i) = some (a i))
    (hacq : ∀ i, i < m → X.G.isAcq (r i) ∧ X.G.atomic (r i))
    (hpo : ∀ k i, k < i → i < m → X.G.po (r k) (r i))
    (hlom : ∀ k i, k ≤ i → i < m → lo k ≤ lo i)
    (hlo : ∀ i, i < m → ∀ w' j, X.G.isW w' → X.G.loc w' = X.G.loc (r i) → X.op w' = some j →
      j ≤ lo i → X.G.hb w' (r i))
    (hrel : ∀ k, k < m → lo k < a k → X.G.isRel (w k) ∧ X.G.atomic (w k)) :
    ∃ x : Nat → Nat,
      (∀ k i, k ≤ i → i < m → x k ≤ x i) ∧
      (∀ i, i < m → lo i ≤ x i ∧ a i ≤ x i) ∧
      (∀ i, i < m → ∀ w' j, X.G.isW w' → X.G.loc w' = X.G.loc (r i) → X.op w' = some j →
        a i < j → j < x i → False) ∧
      (∀ i, i < m → ∀ w', X.G.isW w' → X.G.loc w' = X.G.loc (r i) → X.op w' = some (x i) →
        a i < x i → lo i < x i) ∧
      (∀ i d, i < m → lo i < d → X.G.hb (r i) (X.acq d) → x i < d) ∧
      (∀ k i, k < i → i < m → X.G.loc (r k) = X.G.loc (r i) → lo k < a k → a k ≤ a i) := by
  have hbk : ∀ k i, k < i → i < m → lo k < a k → X.G.hb (w k) (r i) := fun k i hk hi hl =>
    mp_hb X.cons (.inl rfl) (hrf k (by omega)) (hrel k (by omega) hl).1 (hacq k (by omega)).1
      (hrel k (by omega) hl).2 (hacq k (by omega)).2 (.inr (hpo k i hk hi))
  have key : ∀ i, i < m → ∀ w' j, X.G.isW w' → X.G.loc w' = X.G.loc (r i) →
      X.op w' = some j → ∀ k, k ≤ i → (j ≤ lo k ∨ (k < i ∧ j < a k)) → j ≤ a i := by
    intro i hi w' j hw' hl hj k hk hc
    have hh : X.G.hb w' (r i) := by
      rcases hc with hc | ⟨hki, hc⟩
      · exact hlo i hi w' j hw' hl hj (Nat.le_trans hc (hlom k i hk hi))
      · by_cases hla : lo k < a k
        · exact hb_trans (X.op_hb hj (hop k (by omega)) hc) (hbk k i hki hi hla)
        · exact hlo i hi w' j hw' hl hj
            (Nat.le_trans (Nat.le_of_lt (Nat.lt_of_lt_of_le hc (Nat.le_of_not_lt hla)))
              (hlom k i hk hi))
    obtain ⟨hwW, -, hlw, -⟩ := X.cons.rf_wr _ _ (hrf i hi)
    exact X.seen hh (hrf i hi) hw' hl hj (hop i hi)
  refine ⟨xl lo a, fun k i hk _ => xl_mono lo a i hk,
    fun i _ => ⟨xl_ge_lo lo a i, xl_ge_a lo a i⟩, ?_, ?_, ?_, ?_⟩
  · intro i hi w' j hw' hl hj haj hjx
    obtain ⟨k, hk, hc⟩ := xl_gt lo a hjx
    rcases hc with hc | hc
    · have := key i hi w' j hw' hl hj k hk (.inl (Nat.le_of_lt hc)); omega
    · rcases Nat.lt_or_eq_of_le hk with hk' | hk'
      · have := key i hi w' j hw' hl hj k hk (.inr ⟨hk', hc⟩); omega
      · subst hk'; omega
  · intro i hi w' hw' hl hj hax
    apply Nat.lt_of_not_le; intro hle
    have := key i hi w' _ hw' hl hj i (Nat.le_refl _) (.inl hle); omega
  · intro i d hi hld hd
    have : xl lo a i ≤ d - 1 := xl_le lo a i (fun k hk => by
      refine ⟨by have := hlom k i hk hi; omega, ?_⟩
      apply Nat.le_of_lt_succ
      have hdk : a k < d := by
        apply Nat.lt_of_not_le; intro hdk
        have hkm : k < m := by omega
        have h1 : X.G.hb (X.acq d) (w k) ∨ X.acq d = w k := by
          rcases Nat.lt_or_eq_of_le hdk with hlt | heq
          · exact .inl (X.op_hb (X.acq_op d) (hop k hkm) hlt)
          · rcases (X.in_op (w k) (a k) (hop k hkm)).1 with e | e
            · rw [heq]; exact .inr e
            · rw [heq]; exact .inl (po_hb e)
        have hrk : X.G.hb (r k) (X.acq d) := by
          rcases Nat.lt_or_eq_of_le hk with hk' | hk'
          · exact hb_trans (po_hb (hpo k i hk' hi)) hd
          · rw [hk']; exact hd
        have h2 : X.G.hb (r k) (w k) := by
          rcases h1 with h1 | h1
          · exact hb_trans hrk h1
          · rw [← h1]; exact hrk
        exact (X.cons.coh _ _ h2).2 (.base (Or.inl (hrf k hkm)))
      omega)
    omega
  · intro k i hk hi hl hla
    obtain ⟨hwW, -, hlw, -⟩ := X.cons.rf_wr _ _ (hrf k (by omega))
    exact X.seen (hbk k i hk hi hla) (hrf i hi) hwW (hlw.trans hl) (hop k (by omega)) (hop i hi)

end Chain

/-! ## The table's history and lookups on lagging bytes -/

section Hist
variable {K V : Type} [DecidableEq K] (C : Cfg K)

/-- One writer operation's effect on one table, under the contracts (`ContractOK`): nothing, an
insert of an absent key into `find_insert_slot`'s bucket, or a remove. -/
def TStep (T T' : Table K V) : Prop :=
  T' = T ∨
  (∃ i k v, firstEmpty T (ps C T k) = some i ∧ (∀ w, ¬ Has T k w) ∧ T' = insertAt T i k v) ∨
  (∃ i k v, T.slot i = .full k v ∧ T' = removeAt T i k v)

/-- The operation `T → T'` inserts or removes key `k`. -/
def Involved (T T' : Table K V) (k : K) : Prop :=
  (∃ i v, T.slot i = .empty ∧ T' = insertAt T i k v) ∨
  (∃ i v, T.slot i = .full k v ∧ T' = removeAt T i k v)

/-- The table after each writer operation `x ∈ [lo, hi)`: well formed, unique keys, and
consecutive versions related by `TStep`. -/
structure Hist (tab : Nat → Table K V) (lo hi : Nat) : Prop where
  wf : ∀ x, lo ≤ x → x < hi → WF C (tab x)
  uniq : ∀ x, lo ≤ x → x < hi → Uniq (tab x)
  step : ∀ x, lo ≤ x → x + 1 < hi → TStep C (tab x) (tab (x + 1))

/-- The result of a lookup agrees with a table. -/
def Valid (T : Table K V) (k : K) : Option V → Prop
  | none => ∀ w, ¬ Has T k w
  | some w => Has T k w

omit [DecidableEq K] in
theorem grows_refl (T : Table K V) : Grows T T := ⟨rfl, fun _ hj => ⟨hj, fun _ _ h => h⟩⟩

omit [DecidableEq K] in
theorem grows_trans {T1 T2 T3 : Table K V} (h1 : Grows T1 T2) (h2 : Grows T2 T3) : Grows T1 T3 :=
  ⟨h2.1.trans h1.1, fun j hj => ⟨(h2.2 j (h1.2 j hj).1).1,
    fun k w e => (h1.2 j hj).2 k w ((h2.2 j (h1.2 j hj).1).2 k w e)⟩⟩

theorem tstep_grows {T T' : Table K V} (h : TStep C T T') : Grows T T' := by
  rcases h with rfl | ⟨i, k, v, hfe, -, rfl⟩ | ⟨i, k, v, -, rfl⟩
  · exact grows_refl _
  · exact grows_insertAt _ _ _ _ (firstEmpty_spec hfe).1
  · exact grows_removeAt _ _ _ _

variable {C} {tab : Nat → Table K V} {lo hi : Nat}

theorem Hist.grows (hH : Hist C tab lo hi) {x : Nat} (hx : lo ≤ x) :
    ∀ v, x ≤ v → v < hi → Grows (tab x) (tab v)
  | 0, h, _ => by rw [Nat.le_zero.1 h]; exact grows_refl _
  | v + 1, h, hv => by
    rcases Nat.lt_or_eq_of_le h with h | h
    · exact grows_trans (hH.grows hx v (by omega) (by omega))
        (tstep_grows C (hH.step v (by omega) hv))
    · rw [h]; exact grows_refl _

theorem Hist.n_eq (hH : Hist C tab lo hi) {x : Nat} (hx : lo ≤ x) (hxh : x < hi) :
    (tab x).n = (tab lo).n := (hH.grows (Nat.le_refl _) x hx hxh).1

theorem Hist.ps_eq (hH : Hist C tab lo hi) {x : Nat} (hx : lo ≤ x) (hxh : x < hi) (k : K) :
    ps C (tab x) k = ps C (tab lo) k := by simp [ps, hH.n_eq hx hxh]

/-- A bucket that stops holding `(k, w)` was removed: then (unique keys) `k` is absent. -/
theorem Hist.gone (hH : Hist C tab lo hi) {x q : Nat} {k : K} {w : V} (hx : lo ≤ x)
    (h1 : (tab x).slot q = .full k w) :
    ∀ v, x ≤ v → v < hi → (tab v).slot q ≠ .full k w →
      ∃ d, x < d ∧ d ≤ v ∧ ∀ w', ¬ Has (tab d) k w'
  | 0, h, _, h2 => by rw [Nat.le_zero.1 h] at h1; exact (h2 h1).elim
  | v + 1, h, hv, h2 => by
    rcases Nat.lt_or_eq_of_le h with h | h
    · by_cases hs : (tab v).slot q = .full k w
      · refine ⟨v + 1, h, Nat.le_refl _, ?_⟩
        rcases hH.step v (by omega) hv with e | ⟨i, k', v', hfe, -, e⟩ | ⟨i, k', v', hi', e⟩
        · rw [e] at h2; exact (h2 hs).elim
        · exfalso; rw [e] at h2; apply h2
          show (if q = i then _ else _) = _
          rw [if_neg]; exact hs
          rintro rfl; rw [(firstEmpty_spec hfe).1] at hs; cases hs
        · by_cases hqi : q = i
          · subst hqi; rw [hs] at hi'; cases hi'
            intro w' hw'; rw [e] at hw'
            exact ((removeAt_has (hH.uniq v (by omega) (by omega)) hs k w').1 hw').2 rfl
          · exfalso; rw [e] at h2; apply h2
            show (if q = i then _ else _) = _
            rw [if_neg hqi]; exact hs
      · obtain ⟨d, h3, h4, h5⟩ := hH.gone hx h1 v (by omega) (by omega) hs
        exact ⟨d, h3, by omega, h5⟩
    · rw [← h] at h2; exact (h2 h1).elim

variable (C) in
/-- **A load good for a lookup of `k`**: bucket `b`, placed at version `e`, returned slot `σ`.
(A) `σ` is a match exactly when the bucket holds `k` at `e`; (B) an `EMPTY` `σ` proves that
every copy of `k` at `e` lies before `b` on the probe sequence; (C) a non-`EMPTY` non-match
stays a non-match. An exact load (`σ` = the slot at `e`) is good (`obsOK_exact`); so is a
load of the bucket an operation not involving `k` changes, at either side of the operation
(`obsOK_fwd`, `obsOK_lag`). -/
def ObsOK (tab : Nat → Table K V) (hi : Nat) (k : K) (b e : Nat) (σ : Slot K V) : Prop :=
  (∀ w, σ = .full k w ↔ (tab e).slot b = .full k w) ∧
  (σ = .empty → ∀ q w, (tab e).slot q = .full k w → ∀ P rest, ps C (tab e) k = P ++ rest →
    b ∈ P → q ∈ P) ∧
  (σ ≠ .empty → (∀ w, σ ≠ .full k w) → ∀ v, e ≤ v → v < hi → ∀ w, (tab v).slot b ≠ .full k w)

theorem obsOK_exact (hH : Hist C tab lo hi) {e : Nat} (he : lo ≤ e) (he' : e < hi) (k : K)
    (b : Nat) : ObsOK C tab hi k b e ((tab e).slot b) := by
  refine ⟨fun _ => Iff.rfl, fun hσ q w hq P rest hps hb => ?_, fun hne hnf v hv hvh w hw => ?_⟩
  · have hc := (hH.wf e he he').noHole _ _ _ hq
    rw [hps] at hc; exact clear_group hc hb hσ
  · exact hnf w ((hH.grows he v hv hvh).2 b hne |>.2 k w hw)

/-- The operation `y → y + 1` changes bucket `c` and does not involve `k`: the bucket's two
slots, and they are an `EMPTY → full κ` or `full κ → DELETED κ` change with `κ ≠ k`. -/
theorem change_cases (hH : Hist C tab lo hi) {y c : Nat} {k : K} (hy : lo ≤ y) (hy' : y + 1 < hi)
    (hc : (tab y).slot c ≠ (tab (y + 1)).slot c) (hni : ¬ Involved (tab y) (tab (y + 1)) k) :
    ∃ κ v, κ ≠ k ∧
      (((tab y).slot c = .empty ∧ (tab (y + 1)).slot c = .full κ v ∧
          ∀ q, q ≠ c → (tab (y + 1)).slot q = (tab y).slot q) ∨
        ((tab y).slot c = .full κ v ∧ (tab (y + 1)).slot c = .deleted κ v)) := by
  rcases hH.step y hy hy' with e | ⟨i, κ, v, hfe, -, e⟩ | ⟨i, κ, v, hi', e⟩
  · rw [e] at hc; exact (hc rfl).elim
  · have hie := (firstEmpty_spec hfe).1
    have hsl : ∀ q, (tab (y + 1)).slot q = if q = i then .full κ v else (tab y).slot q := by
      intro q; rw [e]; rfl
    have hci : c = i := by
      apply Classical.byContradiction; intro hne; apply hc; rw [hsl, if_neg hne]
    subst hci
    refine ⟨κ, v, ?_, .inl ⟨hie, by rw [hsl, if_pos rfl], fun q hq => by rw [hsl, if_neg hq]⟩⟩
    rintro rfl; exact hni (.inl ⟨c, v, hie, e⟩)
  · have hsl : ∀ q, (tab (y + 1)).slot q = if q = i then .deleted κ v else (tab y).slot q := by
      intro q; rw [e]; rfl
    have hci : c = i := by
      apply Classical.byContradiction; intro hne; apply hc; rw [hsl, if_neg hne]
    subst hci
    refine ⟨κ, v, ?_, .inr ⟨hi', by rw [hsl, if_pos rfl]⟩⟩
    rintro rfl; exact hni (.inr ⟨c, v, hi', e⟩)

/-- A load of the changed bucket placed **before** the operation that returned the slot **after**
it (a fresh byte seen by a reader placed one version earlier) is good for every key the
operation does not involve. -/
theorem obsOK_fwd (hH : Hist C tab lo hi) {y c : Nat} {k : K} (hy : lo ≤ y) (hy' : y + 1 < hi)
    (hc : (tab y).slot c ≠ (tab (y + 1)).slot c) (hni : ¬ Involved (tab y) (tab (y + 1)) k) :
    ObsOK C tab hi k c y ((tab (y + 1)).slot c) := by
  obtain ⟨κ, v, hκ, h⟩ := change_cases hH hy hy' hc hni
  rcases h with ⟨h0, h1, -⟩ | ⟨h0, h1⟩
  · rw [h1]
    refine ⟨fun w => ⟨fun e => ?_, fun e => ?_⟩, fun e => ?_, fun _ _ v' hv hvh w hw => ?_⟩
    · cases e; exact (hκ rfl).elim
    · rw [h0] at e; cases e
    · cases e
    · rcases Nat.lt_or_eq_of_le hv with hv | hv
      · have := ((hH.grows (x := y + 1) (by omega) v' (by omega) hvh).2 c
          (by rw [h1]; intro e; cases e)).2 k w hw
        rw [h1] at this; cases this; exact hκ rfl
      · subst hv; rw [h0] at hw; cases hw
  · rw [h1]
    refine ⟨fun w => ⟨fun e => ?_, fun e => ?_⟩, fun e => ?_, fun _ _ v' hv hvh w hw => ?_⟩
    · cases e
    · rw [h0] at e; cases e; exact (hκ rfl).elim
    · cases e
    · have := ((hH.grows hy v' hv hvh).2 c (by rw [h0]; intro e; cases e)).2 k w hw
      rw [h0] at this; cases this; exact hκ rfl

/-- A load of the changed bucket placed **after** the operation that returned the slot
**before** it (the lagging replica byte) is good for every key the operation does not
involve: a lagging `EMPTY` is a valid stop because every other key present after the insert
was inserted while the bucket was `EMPTY`, so it lies before it on its probe sequence. -/
theorem obsOK_lag (hH : Hist C tab lo hi) {y c : Nat} {k : K} (hy : lo ≤ y) (hy' : y + 1 < hi)
    (hc : (tab y).slot c ≠ (tab (y + 1)).slot c) (hni : ¬ Involved (tab y) (tab (y + 1)) k) :
    ObsOK C tab hi k c (y + 1) ((tab y).slot c) := by
  obtain ⟨κ, v, hκ, h⟩ := change_cases hH hy hy' hc hni
  rcases h with ⟨h0, h1, hrest⟩ | ⟨h0, h1⟩
  · rw [h0]
    refine ⟨fun w => ⟨fun e => ?_, fun e => ?_⟩, fun _ q w hq P rest hps hcP => ?_,
      fun e => (e rfl).elim⟩
    · cases e
    · rw [h1] at e; cases e; exact (hκ rfl).elim
    · have hqc : q ≠ c := by rintro rfl; rw [h1] at hq; cases hq; exact hκ rfl
      rw [hrest q hqc] at hq
      have hcl := (hH.wf y hy (by omega)).noHole _ _ _ hq
      rw [hH.ps_eq hy (by omega), ← hH.ps_eq (x := y + 1) (by omega) hy', hps] at hcl
      exact clear_group hcl hcP h0
  · rw [h0]
    refine ⟨fun w => ⟨fun e => ?_, fun e => ?_⟩, fun e => ?_, fun _ _ v' hv hvh w hw => ?_⟩
    · cases e; exact (hκ rfl).elim
    · rw [h1] at e; cases e
    · cases e
    · have := ((hH.grows (x := y + 1) (by omega) v' hv hvh).2 c
        (by rw [h1]; intro e; cases e)).2 k w hw
      rw [h1] at this; cases this

/-! ### One lookup over good loads -/

omit [DecidableEq K] in
theorem exists_min_in {α : Type} (f : α → Nat) (p : α → Prop) :
    ∀ l : List α, (∃ a ∈ l, p a) → ∃ a ∈ l, p a ∧ ∀ b ∈ l, p b → f a ≤ f b
  | [], ⟨_, h, _⟩ => by cases h
  | a :: l, h => by
    by_cases hl : ∃ b ∈ l, p b
    · obtain ⟨m, hm, hpm, hmin⟩ := exists_min_in f p l hl
      by_cases hpa : p a ∧ f a ≤ f m
      · refine ⟨a, List.mem_cons_self, hpa.1, fun b hb hpb => ?_⟩
        rcases List.mem_cons.1 hb with rfl | hb
        · exact Nat.le_refl _
        · exact Nat.le_trans hpa.2 (hmin b hb hpb)
      · refine ⟨m, List.mem_cons_of_mem _ hm, hpm, fun b hb hpb => ?_⟩
        rcases List.mem_cons.1 hb with rfl | hb
        · exact Nat.le_of_not_lt (fun h => hpa ⟨hpb, Nat.le_of_lt h⟩)
        · exact hmin b hb hpb
    · obtain ⟨a', ha', hpa'⟩ := h
      rcases List.mem_cons.1 ha' with rfl | ha'
      · refine ⟨a', List.mem_cons_self, hpa', fun b hb hpb => ?_⟩
        rcases List.mem_cons.1 hb with rfl | hb
        · exact Nat.le_refl _
        · exact (hl ⟨b, hb, hpb⟩).elim
      · exact (hl ⟨a', ha', hpa'⟩).elim

omit [DecidableEq K] in
theorem exists_max_in {α : Type} (f : α → Nat) :
    ∀ l : List α, l ≠ [] → ∃ a ∈ l, ∀ b ∈ l, f b ≤ f a
  | [], h => (h rfl).elim
  | a :: l, _ => by
    by_cases hl : l = []
    · subst hl; exact ⟨a, List.mem_cons_self, fun b hb => by
        rw [List.mem_singleton.1 hb]; exact Nat.le_refl _⟩
    · obtain ⟨m, hm, hmax⟩ := exists_max_in f l hl
      by_cases ha : f m ≤ f a
      · refine ⟨a, List.mem_cons_self, fun b hb => ?_⟩
        rcases List.mem_cons.1 hb with rfl | hb
        · exact Nat.le_refl _
        · exact Nat.le_trans (hmax b hb) ha
      · refine ⟨m, List.mem_cons_of_mem _ hm, fun b hb => ?_⟩
        rcases List.mem_cons.1 hb with rfl | hb
        · exact Nat.le_of_lt (Nat.lt_of_not_le ha)
        · exact hmax b hb

/-- A load record: bucket, placement (version), returned slot. -/
abbrev Ld (K V : Type) := Nat × Nat × Slot K V

/-- A group whose loads show no match and no `EMPTY` byte: the lookup moves on. -/
def NextG (k : K) (g : List (Ld K V)) : Prop := ∀ ld ∈ g, ld.2.2 ≠ .empty ∧ ∀ w, ld.2.2 ≠ .full k w

/-- **One lookup over good loads is valid at a version among its placements.** A lookup of
`k` loads groups `init ++ [last]` covering the probe prefix `P` (`ps = P ++ rest`), each load
good (`ObsOK`) at its placement. The groups of `init` show no match and no `EMPTY`; the last
group decides: a match (`some w`), no match and an `EMPTY` (`none`), or, with the probe sequence
exhausted, nothing (`none`). Then the result is `Valid` at some version between the smallest and
the largest placement. This is the sequentially consistent `get_linearizable` argument (the
`NWit` witness of `Contract.lean`) on per-load placements. -/
theorem get_valid (hH : Hist C tab lo hi) {k : K} {init : List (List (Ld K V))}
    {last : List (Ld K V)} {P rest : List Nat} {r : Option V}
    (hobs : ∀ g ∈ init ++ [last], ∀ ld ∈ g,
      lo ≤ ld.2.1 ∧ ld.2.1 < hi ∧ ObsOK C tab hi k ld.1 ld.2.1 ld.2.2)
    (hP : ps C (tab lo) k = P ++ rest)
    (hPm : ∀ q, q ∈ P ↔ ∃ g ∈ init ++ [last], ∃ ld ∈ g, ld.1 = q)
    (hinit : ∀ g ∈ init, NextG k g) (hne : last ≠ [])
    (hr : (∃ w, r = some w ∧ ∃ ld ∈ last, ld.2.2 = .full k w) ∨
      (r = none ∧ (∀ ld ∈ last, ∀ w, ld.2.2 ≠ .full k w) ∧ ∃ ld ∈ last, ld.2.2 = .empty) ∨
      (r = none ∧ NextG k last ∧ rest = [])) :
    ∃ x, (∃ g ∈ init ++ [last], ∃ ld ∈ g, ld.2.1 ≤ x) ∧
      (∃ g ∈ init ++ [last], ∃ ld ∈ g, x ≤ ld.2.1) ∧ Valid (tab x) k r := by
  have hlast : last ∈ init ++ [last] := by simp
  -- a load of the lookup that holds `k` at a later version shows a non-match
  have hnm : ∀ g ∈ init ++ [last], ∀ ld ∈ g, (∀ w, r = none → ld.2.2 ≠ .full k w) ∨ r ≠ none := by
    intro g hg ld hld
    by_cases hrn : r = none
    · left; intro w _ e
      rcases List.mem_append.1 hg with hg | hg
      · exact (hinit g hg ld hld).2 w e
      · rw [List.mem_singleton.1 hg] at hld
        rcases hr with ⟨w', e', -⟩ | ⟨-, h, -⟩ | ⟨-, h, -⟩
        · rw [hrn] at e'; cases e'
        · exact h ld hld w e
        · exact (h ld hld).2 w e
    · exact .inr hrn
  rcases hr with ⟨w, rfl, ld, hld, hf⟩ | ⟨rfl, hnf, hE⟩ | ⟨rfl, hnx, rfl⟩
  · -- a match
    obtain ⟨h1, h2, hA, -⟩ := hobs last hlast ld hld
    exact ⟨ld.2.1, ⟨last, hlast, ld, hld, Nat.le_refl _⟩, ⟨last, hlast, ld, hld, Nat.le_refl _⟩,
      ⟨ld.1, (hA w).1 hf⟩⟩
  · -- stop at an `EMPTY` byte: the one placed first
    obtain ⟨j, hj, hjE, hjmin⟩ := exists_min_in (fun ld : Ld K V => ld.2.1)
      (fun ld => ld.2.2 = .empty) last hE
    obtain ⟨hj1, hj2, -, hB, -⟩ := hobs last hlast j hj
    by_cases hk : ∃ w, Has (tab j.2.1) k w
    · obtain ⟨w, q, hq⟩ := hk
      have hqP : q ∈ P := hB hjE q w hq P rest
        (by rw [hH.ps_eq hj1 hj2]; exact hP) ((hPm _).2 ⟨last, hlast, j, hj, rfl⟩)
      obtain ⟨g, hg, ld, hld, rfl⟩ := (hPm q).1 hqP
      obtain ⟨hl1, hl2, hA, -, hC⟩ := hobs g hg ld hld
      have hnfq : ∀ w, ld.2.2 ≠ .full k w := by
        intro w' e
        rcases hnm g hg ld hld with h | h
        · exact h w' rfl e
        · exact h rfl
      by_cases hle : ld.2.1 ≤ j.2.1
      · exfalso
        by_cases hσ : ld.2.2 = .empty
        · have hg' : g = last := by
            rcases List.mem_append.1 hg with hg | hg
            · exact ((hinit g hg ld hld).1 hσ).elim
            · exact List.mem_singleton.1 hg
          subst hg'
          have := hjmin ld hld hσ
          have he : ld.2.1 = j.2.1 := Nat.le_antisymm hle this
          rw [← he] at hq
          exact hnfq w ((hA w).2 hq)
        · exact hC hσ hnfq j.2.1 hle hj2 w hq
      · have hlt : j.2.1 < ld.2.1 := Nat.lt_of_not_le hle
        obtain ⟨d, hd1, hd2, hd3⟩ := hH.gone hj1 hq ld.2.1 (Nat.le_of_lt hlt) hl2
          (fun e => hnfq w ((hA w).2 e))
        exact ⟨d, ⟨last, hlast, j, hj, Nat.le_of_lt hd1⟩, ⟨g, hg, ld, hld, hd2⟩, hd3⟩
    · exact ⟨j.2.1, ⟨last, hlast, j, hj, Nat.le_refl _⟩, ⟨last, hlast, j, hj, Nat.le_refl _⟩,
        fun w hw => hk ⟨w, hw⟩⟩
  · -- the probe sequence is exhausted: the last placement
    have hall : (init ++ [last]).flatten ≠ [] := by
      intro e; rw [List.flatten_eq_nil_iff] at e; exact hne (e last hlast)
    obtain ⟨m, hm, hmax⟩ := exists_max_in (fun ld : Ld K V => ld.2.1) _ hall
    obtain ⟨gm, hgm, hmg⟩ := List.mem_flatten.1 hm
    obtain ⟨hm1, hm2, -⟩ := hobs gm hgm m hmg
    refine ⟨m.2.1, ⟨gm, hgm, m, hmg, Nat.le_refl _⟩, ⟨gm, hgm, m, hmg, Nat.le_refl _⟩, ?_⟩
    intro w ⟨q, hq⟩
    have hc := (hH.wf _ hm1 hm2).noHole _ _ _ hq
    rw [hH.ps_eq hm1 hm2, hP, List.append_nil] at hc
    obtain ⟨g, hg, ld, hld, rfl⟩ := (hPm _).1 (Clear.mem hc)
    obtain ⟨hl1, hl2, -, -, hC⟩ := hobs g hg ld hld
    have hN : NextG k g := by
      rcases List.mem_append.1 hg with hg | hg
      · exact hinit g hg
      · rw [List.mem_singleton.1 hg]; exact hnx
    exact hC (hN ld hld).1 (hN ld hld).2 m.2.1 (hmax ld (List.mem_flatten.2 ⟨g, hg, hld⟩)) hm2 w hq

end Hist

/-! ## The relaxed `ReplicaSync` over a reader's whole chain of loads -/

section Replica
variable {E L K V : Type} [DecidableEq K] {X : Writer E L Nat} {T : Track X}

omit [DecidableEq K] in
/-- **What a reader's control-byte loads return, across all its `get`s** (the true form of
`ReplicaSync`). A `po`-chain of `Acquire` loads of control bytes of one table (positions `p i`,
primary or mirrored, any buckets, any number of `get`s), after the reader's `current` load read
the publication, before the table is freed; `lo i` is a writer operation completed before load `i`
(`hloR`: its lock release happens before the load, or it is the publication). Then there are
monotone versions `x i` in `[lo i, dF)`, below every operation the load happens before, such that
load `i` returns the canonical byte of the slot of its bucket after operation `x i`, **except
possibly** the byte of the bucket operation `x i` itself changed, which may hold its value from
before (`x i - 1`); then `lo i < x i` (the operation is not completed before the load). And a
lagging load never follows a load of the same position that already saw that operation's new byte
(read-read coherence). The lagging case is real: it is `set_ctrl_release`'s replica store, which
is `po`-after the primary store another load may have read. -/
theorem chain_replicaSync (Tb : TableLocs X T) (C : Cfg K) (h2 : Nat → Nat)
    {tab : Nat → Table K V} {dF : Nat} (Lf : Life Tb dF)
    (henc : ∀ x q, Tb.pub ≤ x → x < dF →
      T.vof x (Tb.ctrl q) = Bytes.encSlot C.hash h2 ((tab x).slot (Tb.bkt q)))
    {A : E} {M : Nat} {r w : Nat → E} {p lo : Nat → Nat}
    (hA : X.G.rf Tb.S A) (hAa : X.G.isAcq A ∧ X.G.atomic A) (hAr : ∀ i, i < M → X.G.po A (r i))
    (hrf : ∀ i, i < M → X.G.rf (w i) (r i)) (hloc : ∀ i, i < M → X.G.loc (r i) = Tb.ctrl (p i))
    (hacq : ∀ i, i < M → X.G.isAcq (r i) ∧ X.G.atomic (r i))
    (hpo : ∀ k i, k < i → i < M → X.G.po (r k) (r i))
    (hnf : ∀ i, i < M → ∀ w', X.G.isW w' → X.G.loc w' = X.G.loc (r i) → X.op w' = none →
      X.G.hb w' (Tb.ini (X.G.loc (r i))) ∨ X.G.hb (r i) w')
    (hfree : ∀ i, i < M → X.G.hb (r i) (X.acq dF))
    (hlo0 : ∀ i, i < M → Tb.pub ≤ lo i) (hlom : ∀ k i, k ≤ i → i < M → lo k ≤ lo i)
    (hloR : ∀ i, i < M → lo i = Tb.pub ∨ X.G.hb (X.rel (lo i)) (r i)) :
    ∃ x : Nat → Nat, (∀ k i, k ≤ i → i < M → x k ≤ x i) ∧
      (∀ i, i < M → lo i ≤ x i ∧ x i < dF ∧ ∀ d, lo i < d → X.G.hb (r i) (X.acq d) → x i < d) ∧
      (∀ i, i < M →
        (X.G.lab (r i)).rval = Bytes.encSlot C.hash h2 ((tab (x i)).slot (Tb.bkt (p i))) ∨
        (lo i < x i ∧
          (X.G.lab (r i)).rval = Bytes.encSlot C.hash h2 ((tab (x i - 1)).slot (Tb.bkt (p i))))) ∧
      (∀ j i, j < i → i < M → p j = p i → x j = x i →
        (X.G.lab (r j)).rval = Bytes.encSlot C.hash h2 ((tab (x j)).slot (Tb.bkt (p j))) →
        (X.G.lab (r j)).rval ≠ Bytes.encSlot C.hash h2 ((tab (x j - 1)).slot (Tb.bkt (p j))) →
        (X.G.lab (r i)).rval = Bytes.encSlot C.hash h2 ((tab (x i)).slot (Tb.bkt (p i)))) := by
  have htl : ∀ i, i < M → Tb.tl (X.G.loc (r i)) := fun i hi => by rw [hloc i hi]; exact Tb.ctrl_tl _
  have hsrc : ∀ i, i < M → ∃ a, X.op (w i) = some a := fun i hi =>
    src_tracked Tb hA hAa (hAr i hi) (hrf i hi) (htl i hi) (hnf i hi)
  let a : Nat → Nat := fun i => (X.op (w i)).getD 0
  have hop : ∀ i, i < M → X.op (w i) = some (a i) := by
    intro i hi; obtain ⟨b, hb⟩ := hsrc i hi; simp [a, hb]
  have hSr : ∀ i, i < M → X.G.hb Tb.S (r i) := fun i hi =>
    mp_hb X.cons (.inl rfl) hA Tb.S_rel.1 hAa.1 Tb.S_rel.2 hAa.2 (.inr (hAr i hi))
  have hacqrel : ∀ d, X.acq d = X.rel d ∨ X.G.po (X.acq d) (X.rel d) := fun d =>
    (X.in_op _ d (X.acq_op d)).2
  have hlo : ∀ i, i < M → ∀ w' j, X.G.isW w' → X.G.loc w' = X.G.loc (r i) → X.op w' = some j →
      j ≤ lo i → X.G.hb w' (r i) := by
    intro i hi w' j hw' hl hj hjl
    rcases hloR i hi with he | hh
    · rcases Nat.lt_or_eq_of_le (he ▸ hjl : j ≤ Tb.pub) with hlt | heq
      · exact hb_trans (X.op_hb hj Tb.S_op hlt) (hSr i hi)
      · exact hb_trans (po_hb (Tb.init_po w' hw' (by rw [hl]; exact htl i hi) (heq ▸ hj)))
          (hSr i hi)
    · have hwr : w' = X.rel (lo i) ∨ X.G.hb w' (X.rel (lo i)) := by
        rcases Nat.lt_or_eq_of_le hjl with hlt | heq
        · have h1 := X.op_hb hj (X.acq_op (lo i)) hlt
          rcases hacqrel (lo i) with e | e
          · rw [← e]; exact .inr h1
          · exact .inr (hb_trans h1 (po_hb e))
        · rcases (X.in_op w' j hj).2 with e | e
          · rw [e, heq]; exact .inl rfl
          · rw [← heq]; exact .inr (po_hb e)
      rcases hwr with e | e
      · rw [e]; exact hh
      · exact hb_trans e hh
  have hrel : ∀ k, k < M → lo k < a k → X.G.isRel (w k) ∧ X.G.atomic (w k) := by
    intro k hk hlt
    obtain ⟨hw, -, hl, -⟩ := X.cons.rf_wr _ _ (hrf k hk)
    exact Lf.rel _ _ hw (by rw [hl]; exact htl k hk) (hop k hk)
      (Nat.lt_of_le_of_lt (hlo0 k hk) hlt) (X.op_lt_of_hb (hrf k hk) (hop k hk) (hfree k hk))
  obtain ⟨x, hmono, hb1, hO3, hO4, hO5, hO6⟩ := chain_view X hrf hop hacq hpo hlom hlo hrel
  have htr : ∀ i, i < M → T.tr (X.G.loc (r i)) := fun i hi => Tb.tl_tr _ (htl i hi)
  have hapub : ∀ i, i < M → Tb.pub ≤ a i := by
    intro i hi
    obtain ⟨hiw, hil, hio⟩ := Tb.ini_w _ (htl i hi)
    exact X.seen (hlo i hi _ _ hiw hil hio (hlo0 i hi)) (hrf i hi) hiw hil hio (hop i hi)
  have hrv : ∀ i, i < M → (X.G.lab (r i)).rval = T.vof (a i) (X.G.loc (r i)) := by
    intro i hi
    obtain ⟨hwW, -, hlw, hv⟩ := X.cons.rf_wr _ _ (hrf i hi)
    rw [← hv, T.wval (w i) (a i) hwW (by rw [hlw]; exact htr i hi) (hop i hi), hlw]
  have hfr : ∀ i, i < M → ∀ y, a i ≤ y → y < x i →
      T.vof y (X.G.loc (r i)) = T.vof (a i) (X.G.loc (r i)) := fun i hi y h1 h2 =>
    frame_iter T (htr i hi) y h1 (fun y' w' e1 e2 hw hl hy =>
      hO3 i hi w' y' hw hl hy e1 (by omega))
  have hxF : ∀ i, i < M → x i < dF := by
    intro i hi
    have hlF : lo i < dF := by
      rcases hloR i hi with he | hh
      · -- the publication is not at or after the free: its `current` store happens before
        -- the load, which happens before the free
        rw [he]; apply Nat.lt_of_not_le; intro hd
        have hSF : X.G.hb Tb.S (X.acq dF) := hb_trans (hSr i hi) (hfree i hi)
        rcases Nat.lt_or_eq_of_le hd with hlt | heq
        · exact hb_irrefl X.cons _ (hb_trans (X.op_hb (X.acq_op dF) Tb.S_op hlt) hSF)
        · rcases (X.in_op _ _ Tb.S_op).1 with e | e
          · rw [heq, e] at hSF; exact hb_irrefl X.cons _ hSF
          · rw [heq] at hSF; exact hb_irrefl X.cons _ (hb_trans (po_hb e) hSF)
      · apply Nat.lt_of_not_le; intro hd
        have h1 : X.G.hb (X.acq dF) (X.rel (lo i)) ∨ X.acq dF = X.rel (lo i) := by
          rcases Nat.lt_or_eq_of_le hd with hlt | heq
          · have h0 := X.op_hb (X.acq_op dF) (X.acq_op (lo i)) hlt
            rcases hacqrel (lo i) with e | e
            · rw [← e]; exact .inl h0
            · exact .inl (hb_trans h0 (po_hb e))
          · rw [heq]; rcases hacqrel (lo i) with e | e
            · exact .inr e
            · exact .inl (po_hb e)
        have h2 : X.G.hb (X.rel (lo i)) (X.acq dF) := hb_trans hh (hfree i hi)
        rcases h1 with h1 | h1
        · exact hb_irrefl X.cons _ (hb_trans h1 h2)
        · rw [h1] at h2; exact hb_irrefl X.cons _ h2
    exact hO5 i dF hi hlF (hfree i hi)
  have hR3 : ∀ i, i < M →
      (X.G.lab (r i)).rval = Bytes.encSlot C.hash h2 ((tab (x i)).slot (Tb.bkt (p i))) ∨
      (lo i < x i ∧
        (X.G.lab (r i)).rval = Bytes.encSlot C.hash h2 ((tab (x i - 1)).slot (Tb.bkt (p i)))) := by
    intro i hi
    have hxl := (hb1 i hi).1
    have hxa := (hb1 i hi).2
    rcases Nat.lt_or_eq_of_le hxa with hax | hax
    · by_cases hst : ∃ w', X.G.isW w' ∧ X.G.loc w' = X.G.loc (r i) ∧ X.op w' = some (x i)
      · obtain ⟨w', hw', hl', hj'⟩ := hst
        have hlx := hO4 i hi w' hw' hl' hj' hax
        right; refine ⟨hlx, ?_⟩
        rw [hrv i hi, ← hfr i hi (x i - 1) (by omega) (by omega), hloc i hi,
          henc _ _ (by have := hlo0 i hi; omega) (by have := hxF i hi; omega)]
      · left
        rw [hrv i hi, ← frame_iter T (htr i hi) (x i) (Nat.le_of_lt hax)
          (fun y' w' e1 e2 hw hl hy => by
            rcases Nat.lt_or_eq_of_le e2 with e2 | e2
            · exact hO3 i hi w' y' hw hl hy e1 e2
            · exact hst ⟨w', hw, hl, e2 ▸ hy⟩),
          hloc i hi, henc _ _ (Nat.le_trans (hlo0 i hi) hxl) (hxF i hi)]
    · left; rw [hrv i hi, hax, hloc i hi, henc _ _ (Nat.le_trans (hlo0 i hi) hxl) (hxF i hi)]
  refine ⟨x, hmono, fun i hi => ⟨(hb1 i hi).1, hxF i hi, fun d hd hh => hO5 i d hi hd hh⟩,
    hR3, ?_⟩
  intro j i hji hi hp hx hj1 hj2
  have hjM : j < M := by omega
  have haj : a j = x j := by
    apply Nat.le_antisymm (hb1 j hjM).2
    apply Nat.le_of_not_lt; intro hlt
    apply hj2
    rw [hrv j hjM, ← hfr j hjM (x j - 1) (by omega) (by omega), hloc j hjM,
      henc _ _ (by have := hapub j hjM; omega) (by have := hxF j hjM; omega)]
  have hl : X.G.loc (r j) = X.G.loc (r i) := by rw [hloc j hjM, hloc i hi, hp]
  by_cases hla : lo j < a j
  · have h1 := hO6 j i hji hi hl hla
    have hai : a i = x i := Nat.le_antisymm (hb1 i hi).2 (by omega)
    rw [hrv i hi, hai, hloc i hi, henc _ _ (Nat.le_trans (hlo0 i hi) (hb1 i hi).1) (hxF i hi)]
  · have h1 := hlom j i (Nat.le_of_lt hji) hi
    have h2 := (hb1 i hi).1
    have h3 := (hb1 j hjM).1
    rcases hR3 i hi with h | ⟨h, -⟩
    · exact h
    · omega

end Replica

/-! ## Helpers: one changed bucket, Rust's group decision on slots -/

section Helpers
variable {K V : Type} [DecidableEq K] {C : Cfg K}

/-- A change made by one operation: one bucket, `EMPTY → full κ` or `full κ → DELETED κ`, and
`κ` is the only key the operation involves. -/
theorem tstep_change {T T' : Table K V} (h : TStep C T T') {c : Nat}
    (hc : T.slot c ≠ T'.slot c) :
    ∃ κ v, ((T.slot c = .empty ∧ T'.slot c = .full κ v) ∨
        (T.slot c = .full κ v ∧ T'.slot c = .deleted κ v)) ∧
      (∀ q, T.slot q ≠ T'.slot q → q = c) ∧ (∀ k, Involved T T' k → k = κ) := by
  rcases h with e | ⟨i, κ, v, hfe, -, e⟩ | ⟨i, κ, v, hi', e⟩
  · rw [e] at hc; exact (hc rfl).elim
  · have hie := (firstEmpty_spec hfe).1
    have hsl : ∀ q, T'.slot q = if q = i then .full κ v else T.slot q := by
      intro q; rw [e]; rfl
    have hq : ∀ q, T.slot q ≠ T'.slot q → q = i := fun q hq =>
      Classical.byContradiction fun hne => hq (by rw [hsl, if_neg hne])
    have hci := hq c hc; subst hci
    refine ⟨κ, v, .inl ⟨hie, by rw [hsl, if_pos rfl]⟩, hq, fun k hk => ?_⟩
    rcases hk with ⟨j, v', hj, e'⟩ | ⟨j, v', hj, e'⟩
    · have := congrArg (fun T => T.slot j) (e.symm.trans e')
      simp only [insertAt, Table.set] at this
      split at this
      · cases this; rfl
      · rw [hj] at this; simp at this
    · exfalso
      have h1 : T'.slot j = .deleted k v' := by rw [e']; simp [removeAt, Table.set]
      rw [hsl] at h1; split at h1
      · cases h1
      · rw [hj] at h1; cases h1
  · have hsl : ∀ q, T'.slot q = if q = i then .deleted κ v else T.slot q := by
      intro q; rw [e]; rfl
    have hq : ∀ q, T.slot q ≠ T'.slot q → q = i := fun q hq =>
      Classical.byContradiction fun hne => hq (by rw [hsl, if_neg hne])
    have hci := hq c hc; subst hci
    refine ⟨κ, v, .inr ⟨hi', by rw [hsl, if_pos rfl]⟩, hq, fun k hk => ?_⟩
    rcases hk with ⟨j, v', hj, e'⟩ | ⟨j, v', hj, e'⟩
    · exfalso
      have h1 : T'.slot j = .full k v' := by rw [e']; simp [insertAt, Table.set]
      rw [hsl] at h1; split at h1
      · cases h1
      · rw [hj] at h1; cases h1
    · have := congrArg (fun T => T.slot j) (e.symm.trans e')
      simp only [removeAt, Table.set] at this
      split at this
      · rename_i hjc; subst hjc; rw [hi'] at hj; cases hj; rfl
      · rw [hj] at this; simp at this

/-- The two slots of a changed bucket have different control bytes. -/
theorem tstep_enc_ne {T T' : Table K V} (h : TStep C T T') {c : Nat} (hc : T.slot c ≠ T'.slot c)
    {hash : K → Nat} {h2 : Nat → Nat} (hh2 : ∀ h, h2 h < 0x80) :
    Bytes.encSlot hash h2 (T.slot c) ≠ Bytes.encSlot hash h2 (T'.slot c) := by
  obtain ⟨κ, v, h', -, -⟩ := tstep_change h hc
  rcases h' with ⟨h0, h1⟩ | ⟨h0, h1⟩
  · rw [h0, h1]; simp only [Bytes.encSlot, Bytes.EMPTY]; have := hh2 (hash κ); omega
  · rw [h0, h1]; simp only [Bytes.encSlot, Bytes.DELETED]; have := hh2 (hash κ); omega

omit [DecidableEq K] in
theorem getD_mem {os : List (Slot K V)} {b : Nat} (hb : b < os.length) :
    os.getD b .empty = os[b] := by simp [List.getD_eq_getElem?_getD, hb]

/-- Rust's group decision on the canonical bytes of slots `os`, as facts on `os`. -/
theorem dec_facts {hash : K → Nat} {h2 : Nat → Nat} (hh2 : ∀ h, h2 h < 0x80)
    {mb : List Nat → Nat → List Bool} (hmb : Bytes.MatchOK mb) {k : K} {os : List (Slot K V)}
    (hnm : ∀ s ∈ os, ∀ k v, s ≠ .mistagged k v) :
    (∀ b v, Bytes.groupDecide mb (h2 (hash k)) k (os.map (Bytes.encSlot hash h2)) os =
      .found b v → Slot.full k v ∈ os) ∧
    (Bytes.groupDecide mb (h2 (hash k)) k (os.map (Bytes.encSlot hash h2)) os = .stop →
      (∀ v, Slot.full k v ∉ os) ∧ Slot.empty ∈ os) ∧
    (Bytes.groupDecide mb (h2 (hash k)) k (os.map (Bytes.encSlot hash h2)) os = .next →
      (∀ v, Slot.full k v ∉ os) ∧ Slot.empty ∉ os) := by
  have hl := Bytes.loaded_canon (W := os.length) (hash := hash) (h2 := h2) (k := k) rfl hnm
  have hnf : ∀ v, (∀ b < os.length, ∀ v, os.getD b .empty ≠ .full k v) → Slot.full k v ∉ os := by
    intro v h hm
    obtain ⟨b, hb, e⟩ := List.mem_iff_getElem.1 hm
    exact h b hb v (by rw [getD_mem hb]; exact e)
  refine ⟨fun b v hd => ?_, fun hd => ?_, fun hd => ?_⟩
  · obtain ⟨hb, hf⟩ := (Bytes.groupDecide_found hl hmb hh2).1 b v hd
    rw [getD_mem hb] at hf; rw [← hf]; exact List.getElem_mem hb
  · obtain ⟨h1, b, hb, he⟩ := (Bytes.groupDecide_stop hl hmb hh2).1 hd
    rw [getD_mem hb] at he
    exact ⟨fun v => hnf v h1, by rw [← he]; exact List.getElem_mem hb⟩
  · obtain ⟨h1, h2'⟩ := (Bytes.groupDecide_next hl hmb hh2).1 hd
    refine ⟨fun v => hnf v h1, fun hm => ?_⟩
    obtain ⟨b, hb, e⟩ := List.mem_iff_getElem.1 hm
    exact h2' b hb (by rw [getD_mem hb]; exact e)

/-- Rust's `search` over the loaded groups (bytes and the slots they encode): the first group
with a match returns it, the first group with an `EMPTY` byte stops, else the next group. -/
def rustGet (mb : List Nat → Nat → List Bool) (tag : Nat) (k : K) :
    List (List Nat × List (Slot K V)) → Option V
  | [] => none
  | (bs, os) :: gs => match Bytes.groupDecide mb tag k bs os with
    | .found _ v => some v
    | .stop => none
    | .next => rustGet mb tag k gs

theorem rustGet_last {mb : List Nat → Nat → List Bool} {tag : Nat} {k : K}
    {last : List Nat × List (Slot K V)} :
    ∀ {init : List (List Nat × List (Slot K V))},
      (∀ g ∈ init, Bytes.groupDecide mb tag k g.1 g.2 = .next) →
      rustGet mb tag k (init ++ [last]) = rustGet mb tag k [last]
  | [], _ => rfl
  | g :: init, h => by
    show (match Bytes.groupDecide mb tag k g.1 g.2 with
      | .found _ v => some v | .stop => none | .next => rustGet mb tag k (init ++ [last])) = _
    rw [h g List.mem_cons_self]
    exact rustGet_last (fun g' hg' => h g' (List.mem_cons_of_mem _ hg'))

end Helpers

/-! ## The table history from a run of the model -/

section Bridge
variable {K V : Type} [DecidableEq K] (C : Cfg K)

/-- **A contract-respecting model writer step is a `TStep` of every allocated, unfreed table.**
The current table gets the insert or remove, every other one is unchanged (a new table is
published at a fresh or freed address). -/
theorem tstep_of_step {s s' : St K V} (h : Inv C s) (hs : Step C s s') (hc : ContractOK C s s')
    {t : Nat} (ht : t < s.nextId) (hf : s.ts t ≠ .freed) :
    TStep C (s.tables t) (s'.tables t) := by
  have hcommit : ∀ T', (t = s.cur → TStep C (s.tables s.cur) T') →
      TStep C (s.tables t) ((commit s T').tables t) := by
    intro T' hT
    by_cases e : t = s.cur
    · rw [e]; show TStep C _ (upd s.tables s.cur T' s.cur); rw [upd_same]; exact hT e
    · left; exact upd_other _ _ _ _ e
  cases hs with
  | insert k v i hg hfe =>
    exact hcommit _ (fun _ => .inr (.inl ⟨i, k, v, hfe,
      hc.1 i k v (firstEmpty_spec hfe).1 rfl, rfl⟩))
  | insertAny k v i hg he _ =>
    exact hcommit _ (fun _ => .inr (.inl ⟨i, k, v, hc.2.2.1 i k v he rfl,
      hc.1 i k v he rfl, rfl⟩))
  | insertMis k v i _ he _ => exact absurd rfl (hc.2.2.2 i k v he)
  | remove k v i hi => exact hcommit _ (fun _ => .inr (.inr ⟨i, k, v, hi, rfl⟩))
  | removeMis k v i hi => exact absurd hi ((h.wf _ h.curLt).noMis _ _ _)
  | expand m _ _ => exact .inl (publish_tables_lt false (swap_pub _ _) ht hf)
  | replace m l _ _ => exact .inl (publish_tables_lt true (swap_pub _ _) ht hf)
  | expandAt m a ha _ _ => exact .inl (publish_tables_lt false (swapAt_pub _ ha) ht hf)
  | replaceAt m a l ha _ _ => exact .inl (publish_tables_lt true (swapAt_pub _ ha) ht hf)
  | replaceEmpty => exact .inl (publish_tables_lt true (swapEmpty_pub _) ht hf)
  | _ => exact .inl rfl

/-- **The history of one table along a contract-respecting run is a `Hist`.** States `s x`
for the writer operations `x ∈ [lo, hi)` of a `CReachable` run, consecutive ones related by a
contract-respecting step, and a table `t` allocated and not freed throughout: its contents
`(s x).tables t` are a `Hist`. This is how `reader_lin` applies to the model: the writer's
critical sections replayed in lock order are these steps (`henc`). -/
theorem hist_of_run (hcov : C.Cover) {s : Nat → St K V} {lo hi t : Nat}
    (hr : ∀ x, lo ≤ x → x < hi → CReachable C (s x))
    (hs : ∀ x, lo ≤ x → x + 1 < hi → Step C (s x) (s (x + 1)) ∧ ContractOK C (s x) (s (x + 1)))
    (ht : ∀ x, lo ≤ x → x < hi → t < (s x).nextId ∧ (s x).ts t ≠ .freed) :
    Hist C (fun x => (s x).tables t) lo hi :=
  ⟨fun x h1 h2 => (creachable_inv C hcov (hr x h1 h2)).1.wf t (ht x h1 h2).1,
   fun x h1 h2 => (creachable_inv C hcov (hr x h1 h2)).2.uniq t (ht x h1 h2).1,
   fun x h1 h2 => tstep_of_step C (creachable_inv C hcov (hr x h1 (by omega))).1 (hs x h1 h2).1
     (hs x h1 h2).2 (ht x h1 (by omega)).1 (ht x h1 (by omega)).2⟩

/-- The abstract map agrees with a `get` result at a version. -/
def HistAt (s : St K V) (x : Nat) (k : K) : Option V → Prop
  | none => ∀ w, ¬ s.hist x k w
  | some w => s.hist x k w

/-- **From the table to the abstract map.** On a `CReachable` state, a result `Valid` for the
current table agrees with the map at the current version, and one `Valid` for a retired table
agrees with the map at the version it was retired at (`get_linearizable`'s `Lin` witnesses). -/
theorem valid_hist (hcov : C.Cover) {s : St K V} (h : CReachable C s) {t : Nat} {k : K}
    {r : Option V} :
    (t = s.cur → (Valid (s.tables t) k r ↔ HistAt s s.ver k r)) ∧
    (∀ v d cf, s.ts t = .retired v d cf → (Valid (s.tables t) k r ↔ HistAt s v k r)) := by
  have hi := (creachable_inv C hcov h).1
  refine ⟨fun e => ?_, fun v d cf hrt => ?_⟩
  · subst e
    cases r with
    | none => exact ⟨fun h w hw => h w ((hi.curHist k w).2 hw),
        fun h w hw => h w ((hi.curHist k w).1 hw)⟩
    | some w => exact hi.curHist k w
  · have := (hi.ret t v d cf hrt).2.2
    cases r with
    | none => exact ⟨fun h w hw => h w ((this k w).2 hw), fun h w hw => h w ((this k w).1 hw)⟩
    | some w => exact this k w

end Bridge

/-! ## The global refinement of a reader's `get`s -/

section Global
variable {E L K V : Type} [DecidableEq K] {X : Writer E L Nat} {T : Track X}

/-- Rust's control flow for one `get` of key `G.1` over its loaded groups `G.2` (lists of load
indices, bytes in bucket order): every group but the last moved on, the groups are the probe
prefix of `k`, and the last group decided (match or `EMPTY`), or the probe sequence ended. `bk`,
`rv`, `σ`: bucket, loaded byte and slot of a load. -/
def Complete (C : Cfg K) (mb : List Nat → Nat → List Bool) (h2 : Nat → Nat) (T0 : Table K V)
    (bk rv : Nat → Nat) (σ : Nat → Slot K V) (G : K × List (List Nat)) : Prop :=
  ∃ gi gl, G.2 = gi ++ [gl] ∧
    (∀ g ∈ gi, Bytes.groupDecide mb (h2 (C.hash G.1)) G.1 (g.map rv) (g.map σ) = .next) ∧
    ∃ rest, ps C T0 G.1 = (G.2.map (fun g => g.map bk)).flatten ++ rest ∧
      (rest = [] ∨ Bytes.groupDecide mb (h2 (C.hash G.1)) G.1 (gl.map rv) (gl.map σ) ≠ .next)

/-- **Property 18, global form: a reader thread's `get`s are linearizable as one sequence.**

A reader of one table (its `current` load reads the publication `S`; `Acquire` control-byte
loads `r 0, r 1, …` in program order across any number of `get`s, positions `p i`, primary or
mirrored; the table is not freed before them), against the table's history `tab` after each
writer operation (`Hist`: the writer's critical sections replayed in lock order are contract
respecting model writer steps, `henc` ties the bytes to the slots). Load `i` belongs to a `get`
of key `key i`; one key reaches one bucket at one position (`hkey`: the probe sequence depends
on the key only). Each `get` `G` lists its groups (load indices). Then there are

* monotone placements `e i` of the loads, in each load's `hb` window: `lo i ≤ e i` (every
  operation completed before the load) and `e i < d` for every operation `d` the load happens
  before;
* the slot `σ i` each load returned (`rval = encSlot (σ i)`): the bucket's slot at `e i` or at a
  neighbouring version (the one lagging or leading byte);
* for each `get` a version `ℓ G` between the placements of its loads, **monotone along the
  reader's program order** (`hgo`: the `get`s are listed in program order),

such that every `get` whose Rust control flow completed on these bytes returns a result that is
`Valid` for the table at version `ℓ G` (`some w`: `(k, w)` is in it; `none`: `k` is not).
So all `get`s of the thread are explained by one sequence: writer operations in lock order with
the reader's `get`s inserted, in program order, after operation `ℓ G`. The lagging replica byte
of `set_ctrl_release` does not break this: a load placed at `x` that sees the byte from before
operation `x` is placed at `x - 1` together with the earlier loads of the same version when the
operation involves its key; otherwise the byte is irrelevant to its lookup (`obsOK_lag`,
`obsOK_fwd`). -/
theorem reader_lin (Tb : TableLocs X T) (C : Cfg K) {h2 : Nat → Nat} (hh2 : ∀ h, h2 h < 0x80)
    {mb : List Nat → Nat → List Bool} (hmb : Bytes.MatchOK mb)
    {tab : Nat → Table K V} {dF : Nat} (Lf : Life Tb dF) (hH : Hist C tab Tb.pub dF)
    (henc : ∀ x q, Tb.pub ≤ x → x < dF →
      T.vof x (Tb.ctrl q) = Bytes.encSlot C.hash h2 ((tab x).slot (Tb.bkt q)))
    {A : E} {M : Nat} {r w : Nat → E} {p lo : Nat → Nat} {key : Nat → K}
    (hA : X.G.rf Tb.S A) (hAa : X.G.isAcq A ∧ X.G.atomic A) (hAr : ∀ i, i < M → X.G.po A (r i))
    (hrf : ∀ i, i < M → X.G.rf (w i) (r i)) (hloc : ∀ i, i < M → X.G.loc (r i) = Tb.ctrl (p i))
    (hacq : ∀ i, i < M → X.G.isAcq (r i) ∧ X.G.atomic (r i))
    (hpo : ∀ k i, k < i → i < M → X.G.po (r k) (r i))
    (hnf : ∀ i, i < M → ∀ w', X.G.isW w' → X.G.loc w' = X.G.loc (r i) → X.op w' = none →
      X.G.hb w' (Tb.ini (X.G.loc (r i))) ∨ X.G.hb (r i) w')
    (hfree : ∀ i, i < M → X.G.hb (r i) (X.acq dF))
    (hlo0 : ∀ i, i < M → Tb.pub ≤ lo i) (hlom : ∀ k i, k ≤ i → i < M → lo k ≤ lo i)
    (hloR : ∀ i, i < M → lo i = Tb.pub ∨ X.G.hb (X.rel (lo i)) (r i))
    (hkey : ∀ i j, i < M → j < M → key i = key j → Tb.bkt (p i) = Tb.bkt (p j) → p i = p j)
    (gets : List (K × List (List Nat)))
    (hgk : ∀ G ∈ gets, ∀ g ∈ G.2, ∀ i ∈ g, i < M ∧ key i = G.1)
    (hgne : ∀ G ∈ gets, G.2 ≠ [] ∧ ∀ g ∈ G.2, g ≠ [])
    (hgo : gets.Pairwise (fun G G' => ∀ g ∈ G.2, ∀ i ∈ g, ∀ g' ∈ G'.2, ∀ j ∈ g', i < j)) :
    ∃ (e : Nat → Nat) (σ : Nat → Slot K V) (ℓ : K × List (List Nat) → Nat),
      (∀ i j, i ≤ j → j < M → e i ≤ e j) ∧
      (∀ i, i < M → lo i ≤ e i ∧ e i < dF ∧
        (∀ d, lo i < d → X.G.hb (r i) (X.acq d) → e i < d) ∧
        (X.G.lab (r i)).rval = Bytes.encSlot C.hash h2 (σ i) ∧
        (σ i = (tab (e i)).slot (Tb.bkt (p i)) ∨ σ i = (tab (e i + 1)).slot (Tb.bkt (p i)) ∨
          σ i = (tab (e i - 1)).slot (Tb.bkt (p i))) ∧
        ∃ z, Tb.pub ≤ z ∧ z < dF ∧ σ i = (tab z).slot (Tb.bkt (p i))) ∧
      (∀ G ∈ gets, (∃ g ∈ G.2, ∃ i ∈ g, e i ≤ ℓ G) ∧ (∃ g ∈ G.2, ∃ i ∈ g, ℓ G ≤ e i) ∧
        (Complete C mb h2 (tab Tb.pub) (fun i => Tb.bkt (p i)) (fun i => (X.G.lab (r i)).rval) σ G →
          Valid (tab (ℓ G)) G.1 (rustGet mb (h2 (C.hash G.1)) G.1
            (G.2.map (fun g => (g.map (fun i => (X.G.lab (r i)).rval), g.map σ)))))) ∧
      gets.Pairwise (fun G G' => ℓ G ≤ ℓ G') := by
  classical
  obtain ⟨x, hmono, hxb, hR3, hR4⟩ := chain_replicaSync Tb C h2 Lf henc hA hAa hAr hrf hloc hacq hpo
    hnf hfree hlo0 hlom hloR
  -- the slot each load returned, and the loads that lag behind an operation on their key
  let lag : Nat → Prop := fun i =>
    (X.G.lab (r i)).rval ≠ Bytes.encSlot C.hash h2 ((tab (x i)).slot (Tb.bkt (p i)))
  let σ : Nat → Slot K V := fun i =>
    if lag i then (tab (x i - 1)).slot (Tb.bkt (p i)) else (tab (x i)).slot (Tb.bkt (p i))
  let Bad : Nat → Prop := fun j =>
    j < M ∧ lag j ∧ Involved (tab (x j - 1)) (tab (x j)) (key j)
  let low : Nat → Prop := fun i => ∃ j, i ≤ j ∧ x j = x i ∧ Bad j
  let e : Nat → Nat := fun i => if low i then x i - 1 else x i
  have hσ1 : ∀ i, lag i → σ i = (tab (x i - 1)).slot (Tb.bkt (p i)) := fun i h => if_pos h
  have hσ2 : ∀ i, ¬ lag i → σ i = (tab (x i)).slot (Tb.bkt (p i)) := fun i h => if_neg h
  have he1 : ∀ i, low i → e i = x i - 1 := fun i h => if_pos h
  have he2 : ∀ i, ¬ low i → e i = x i := fun i h => if_neg h
  have hlagF : ∀ i, i < M → lag i → lo i < x i ∧
      (X.G.lab (r i)).rval = Bytes.encSlot C.hash h2 ((tab (x i - 1)).slot (Tb.bkt (p i))) := by
    intro i hi hl
    rcases hR3 i hi with h | h
    · exact (hl h).elim
    · exact h
  have hnlag : ∀ i, ¬ lag i →
      (X.G.lab (r i)).rval = Bytes.encSlot C.hash h2 ((tab (x i)).slot (Tb.bkt (p i))) :=
    fun i h => Classical.byContradiction h
  have hσenc : ∀ i, i < M → (X.G.lab (r i)).rval = Bytes.encSlot C.hash h2 (σ i) := by
    intro i hi
    by_cases hl : lag i
    · rw [hσ1 i hl]; exact (hlagF i hi hl).2
    · rw [hσ2 i hl]; exact hnlag i hl
  have hlagch : ∀ i, i < M → lag i →
      (tab (x i - 1)).slot (Tb.bkt (p i)) ≠ (tab (x i)).slot (Tb.bkt (p i)) := by
    intro i hi hl hs; apply hl; rw [(hlagF i hi hl).2, hs]
  have hlowF : ∀ i, i < M → low i → lo i < x i := by
    rintro i hi ⟨j, hij, hxj, hjM, hlj, -⟩
    have := (hlagF j hjM hlj).1; have := hlom i j hij hjM; omega
  have hxF : ∀ i, i < M → x i < dF := fun i hi => (hxb i hi).2.1
  -- the placements are monotone and in the window
  have hemono : ∀ i j, i ≤ j → j < M → e i ≤ e j := by
    intro i j hij hj
    have hx := hmono i j hij hj
    by_cases hli : low i <;> by_cases hlj : low j
    · rw [he1 i hli, he1 j hlj]; omega
    · rw [he1 i hli, he2 j hlj]; omega
    · rw [he2 i hli, he1 j hlj]
      rcases Nat.lt_or_eq_of_le hx with hx | hx
      · omega
      · obtain ⟨j', hj', hxj', hb⟩ := hlj
        exact (hli ⟨j', Nat.le_trans hij hj', hxj'.trans hx.symm, hb⟩).elim
    · rw [he2 i hli, he2 j hlj]; exact hx
  have heb : ∀ i, i < M → lo i ≤ e i ∧ e i ≤ x i := by
    intro i hi
    by_cases hl : low i
    · rw [he1 i hl]; have := hlowF i hi hl; omega
    · rw [he2 i hl]; exact ⟨(hxb i hi).1, Nat.le_refl _⟩
  -- every load is good for its key at its placement
  have hobs : ∀ i, i < M → Tb.pub ≤ e i ∧ e i < dF ∧
      ObsOK C tab dF (key i) (Tb.bkt (p i)) (e i) (σ i) := by
    intro i hi
    have hpe : Tb.pub ≤ e i := Nat.le_trans (hlo0 i hi) (heb i hi).1
    have hef : e i < dF := Nat.lt_of_le_of_lt (heb i hi).2 (hxF i hi)
    refine ⟨hpe, hef, ?_⟩
    by_cases hl : low i
    · have hlx := hlowF i hi hl
      have hy : x i - 1 + 1 = x i := by omega
      have hpy : Tb.pub ≤ x i - 1 := by have := hlo0 i hi; omega
      rw [he1 i hl]
      by_cases hli : lag i
      · rw [hσ1 i hli]; exact obsOK_exact hH hpy (by have := hxF i hi; omega) _ _
      · rw [hσ2 i hli]
        by_cases hch : (tab (x i - 1)).slot (Tb.bkt (p i)) = (tab (x i)).slot (Tb.bkt (p i))
        · rw [← hch]; exact obsOK_exact hH hpy (by have := hxF i hi; omega) _ _
        · have hst : TStep C (tab (x i - 1)) (tab (x i - 1 + 1)) :=
            hH.step _ hpy (by rw [hy]; exact hxF i hi)
          rw [hy] at hst
          have hni : ¬ Involved (tab (x i - 1)) (tab (x i)) (key i) := by
            intro hinv
            obtain ⟨j, hij, hxj, hjM, hlj, hinvj⟩ := hl
            obtain ⟨κ, v, -, hone, hkey1⟩ := tstep_change hst hch
            have hkk : key i = key j := (hkey1 _ hinv).trans (hkey1 _ (by rw [← hxj]; exact hinvj)).symm
            have hbj : Tb.bkt (p j) = Tb.bkt (p i) :=
              hone _ (by have := hlagch j hjM hlj; rw [hxj] at this; exact this)
            have hpp := hkey i j hi hjM hkk hbj.symm
            have hij' : i < j := by
              rcases Nat.lt_or_eq_of_le hij with h | h
              · exact h
              · subst h; exact (hli hlj).elim
            apply hlj
            apply hR4 i j hij' hjM hpp hxj.symm (hnlag i hli)
            rw [hnlag i hli]
            exact (tstep_enc_ne hst hch hh2).symm
          have := obsOK_fwd hH (y := x i - 1) (k := key i) hpy (by rw [hy]; exact hxF i hi)
            (by rw [hy]; exact hch) (by rw [hy]; exact hni)
          rw [hy] at this; exact this
    · rw [he2 i hl]
      by_cases hli : lag i
      · rw [hσ1 i hli]
        have hlx := (hlagF i hi hli).1
        have hy : x i - 1 + 1 = x i := by omega
        have hpy : Tb.pub ≤ x i - 1 := by have := hlo0 i hi; omega
        have hni : ¬ Involved (tab (x i - 1)) (tab (x i)) (key i) := fun hinv =>
          hl ⟨i, Nat.le_refl _, rfl, hi, hli, hinv⟩
        have := obsOK_lag hH (y := x i - 1) (k := key i) hpy (by rw [hy]; exact hxF i hi)
          (by rw [hy]; exact hlagch i hi hli) (by rw [hy]; exact hni)
        rw [hy] at this; exact this
      · rw [hσ2 i hli]; exact obsOK_exact hH (Nat.le_trans (hlo0 i hi) (hxb i hi).1) (hxF i hi) _ _
  have hσcase : ∀ i, i < M → (σ i = (tab (e i)).slot (Tb.bkt (p i)) ∨
      σ i = (tab (e i + 1)).slot (Tb.bkt (p i)) ∨ σ i = (tab (e i - 1)).slot (Tb.bkt (p i))) := by
    intro i hi
    by_cases hl : low i <;> by_cases hli : lag i
    · left; rw [hσ1 i hli, he1 i hl]
    · right; left; rw [hσ2 i hli, he1 i hl]; have := hlowF i hi hl
      rw [show x i - 1 + 1 = x i by omega]
    · right; right; rw [hσ1 i hli, he2 i hl]
    · left; rw [hσ2 i hli, he2 i hl]
  have hσz : ∀ i, i < M → ∃ z, Tb.pub ≤ z ∧ z < dF ∧ σ i = (tab z).slot (Tb.bkt (p i)) := by
    intro i hi
    by_cases hli : lag i
    · have := (hlagF i hi hli).1; have := hlo0 i hi; have := hxF i hi
      exact ⟨x i - 1, by omega, by omega, hσ1 i hli⟩
    · exact ⟨x i, Nat.le_trans (hlo0 i hi) (hxb i hi).1, hxF i hi, hσ2 i hli⟩
  have hnm : ∀ i, i < M → ∀ k v, σ i ≠ .mistagged k v := by
    intro i hi k v
    by_cases hli : lag i
    · rw [hσ1 i hli]; have := (hlagF i hi hli).1; have := hlo0 i hi
      exact (hH.wf _ (by omega) (by have := hxF i hi; omega)).noMis _ _ _
    · rw [hσ2 i hli]
      exact (hH.wf _ (Nat.le_trans (hlo0 i hi) (hxb i hi).1) (hxF i hi)).noMis _ _ _
  -- one `get`
  have hget : ∀ G ∈ gets, ∃ ℓ, (∃ g ∈ G.2, ∃ i ∈ g, e i ≤ ℓ) ∧ (∃ g ∈ G.2, ∃ i ∈ g, ℓ ≤ e i) ∧
      (Complete C mb h2 (tab Tb.pub) (fun i => Tb.bkt (p i)) (fun i => (X.G.lab (r i)).rval) σ G →
        Valid (tab ℓ) G.1 (rustGet mb (h2 (C.hash G.1)) G.1
          (G.2.map (fun g => (g.map (fun i => (X.G.lab (r i)).rval), g.map σ))))) := by
    intro G hG
    obtain ⟨k, gs⟩ := G
    have hgk' := hgk _ hG
    obtain ⟨hgs0, hgs1⟩ := hgne _ hG
    simp only at hgk' hgs0 hgs1 ⊢
    -- the bytes of a group are the canonical bytes of its slots
    have hbs : ∀ g ∈ gs, g.map (fun i => (X.G.lab (r i)).rval) =
        (g.map σ).map (Bytes.encSlot C.hash h2) := by
      intro g hg; rw [List.map_map]
      exact List.map_congr_left (fun i hi => hσenc i (hgk' g hg i hi).1)
    have hgnm : ∀ g ∈ gs, ∀ s ∈ g.map σ, ∀ k v, s ≠ .mistagged k v := by
      intro g hg s hs k v
      obtain ⟨i, hi, rfl⟩ := List.mem_map.1 hs
      exact hnm i (hgk' g hg i hi).1 k v
    by_cases hc : Complete C mb h2 (tab Tb.pub) (fun i => Tb.bkt (p i))
        (fun i => (X.G.lab (r i)).rval) σ (k, gs)
    · obtain ⟨gi, gl, hgs, hnext, rest, hps, hdone⟩ := hc
      simp only at hgs hnext hps hdone
      let ld : Nat → Ld K V := fun i => (Tb.bkt (p i), e i, σ i)
      have hglm : gl ∈ gs := by rw [hgs]; simp
      have hgim : ∀ g ∈ gi, g ∈ gs := fun g hg => by rw [hgs]; simp [hg]
      have hall : gi.map (fun g => g.map ld) ++ [gl.map ld] = gs.map (fun g => g.map ld) := by
        rw [hgs]; simp
      have hdec := fun g (hg : g ∈ gs) =>
        dec_facts (hash := C.hash) hh2 hmb (k := k) (hgnm g hg)
      have hres : rustGet mb (h2 (C.hash k)) k
          (gs.map (fun g => (g.map (fun i => (X.G.lab (r i)).rval), g.map σ))) =
          rustGet mb (h2 (C.hash k)) k [(gl.map (fun i => (X.G.lab (r i)).rval), gl.map σ)] := by
        rw [hgs, List.map_append, List.map_singleton]
        apply rustGet_last
        intro g hg
        obtain ⟨g', hg', rfl⟩ := List.mem_map.1 hg
        exact hnext g' hg'
      obtain ⟨xv, ⟨g1, hg1, l1, hl1, hle1⟩, ⟨g2, hg2, l2, hl2, hle2⟩, hv⟩ :=
        get_valid (C := C) (tab := tab) (lo := Tb.pub) (hi := dF) hH (k := k)
          (init := gi.map (fun g => g.map ld)) (last := gl.map ld)
          (P := (gs.map (fun g => g.map (fun i => Tb.bkt (p i)))).flatten) (rest := rest)
          (r := rustGet mb (h2 (C.hash k)) k
            (gs.map (fun g => (g.map (fun i => (X.G.lab (r i)).rval), g.map σ))))
          (by
            rw [hall]; intro g hg l hl
            obtain ⟨g', hg', rfl⟩ := List.mem_map.1 hg
            obtain ⟨i, hi, rfl⟩ := List.mem_map.1 hl
            obtain ⟨hiM, hki⟩ := hgk' g' hg' i hi
            have := hobs i hiM; rw [hki] at this; exact this)
          hps
          (by
            rw [hall]; intro q
            constructor
            · intro h
              obtain ⟨l, hl, hq⟩ := List.mem_flatten.1 h
              obtain ⟨g, hg, rfl⟩ := List.mem_map.1 hl
              obtain ⟨i, hi, rfl⟩ := List.mem_map.1 hq
              exact ⟨g.map ld, List.mem_map.2 ⟨g, hg, rfl⟩, ld i, List.mem_map.2 ⟨i, hi, rfl⟩, rfl⟩
            · rintro ⟨g', hg', l, hl, rfl⟩
              obtain ⟨g, hg, rfl⟩ := List.mem_map.1 hg'
              obtain ⟨i, hi, rfl⟩ := List.mem_map.1 hl
              exact List.mem_flatten.2 ⟨g.map (fun i => Tb.bkt (p i)), List.mem_map.2 ⟨g, hg, rfl⟩,
                List.mem_map.2 ⟨i, hi, rfl⟩⟩)
          (by
            intro g hg l hl
            obtain ⟨g', hg', rfl⟩ := List.mem_map.1 hg
            obtain ⟨i, hi, rfl⟩ := List.mem_map.1 hl
            have hn := (hdec g' (hgim g' hg')).2.2 (by rw [← hbs g' (hgim g' hg')]; exact hnext g' hg')
            exact ⟨fun e' => hn.2 (List.mem_map.2 ⟨i, hi, e'⟩),
              fun w e' => hn.1 w (List.mem_map.2 ⟨i, hi, e'⟩)⟩)
          (by intro e'; exact hgs1 gl hglm (List.map_eq_nil_iff.1 e'))
          (by
            rw [hres]
            have hd := hdec gl hglm
            rw [← hbs gl hglm] at hd
            show (∃ w, (match Bytes.groupDecide mb (h2 (C.hash k)) k
                (gl.map (fun i => (X.G.lab (r i)).rval)) (gl.map σ) with
                | .found _ v => some v | .stop => none | .next => rustGet mb (h2 (C.hash k)) k []) =
                  some w ∧ _) ∨ _
            cases hdg : Bytes.groupDecide mb (h2 (C.hash k)) k
                (gl.map (fun i => (X.G.lab (r i)).rval)) (gl.map σ) with
            | found b v =>
              left
              obtain ⟨i, hi, he'⟩ := List.mem_map.1 (hd.1 b v hdg)
              exact ⟨v, rfl, ld i, List.mem_map.2 ⟨i, hi, rfl⟩, he'⟩
            | stop =>
              right; left
              obtain ⟨h1, h2'⟩ := hd.2.1 hdg
              obtain ⟨i, hi, he'⟩ := List.mem_map.1 h2'
              refine ⟨by simp only [rustGet, hdg], fun l hl w e' => ?_, ld i,
                List.mem_map.2 ⟨i, hi, rfl⟩, he'⟩
              obtain ⟨j, hj, rfl⟩ := List.mem_map.1 hl
              exact h1 w (List.mem_map.2 ⟨j, hj, e'⟩)
            | next =>
              right; right
              obtain ⟨h1, h2'⟩ := hd.2.2 hdg
              refine ⟨by simp only [rustGet, hdg], fun l hl => ?_, ?_⟩
              · obtain ⟨j, hj, rfl⟩ := List.mem_map.1 hl
                exact ⟨fun e' => h2' (List.mem_map.2 ⟨j, hj, e'⟩),
                  fun w e' => h1 w (List.mem_map.2 ⟨j, hj, e'⟩)⟩
              · rcases hdone with h | h
                · exact h
                · exact (h hdg).elim)
      have hmem : ∀ g ∈ gi.map (fun g => g.map ld) ++ [gl.map ld], ∀ l ∈ g,
          ∃ g' ∈ gs, ∃ i ∈ g', l = ld i := by
        rw [hall]; intro g hg l hl
        obtain ⟨g', hg', rfl⟩ := List.mem_map.1 hg
        obtain ⟨i, hi, rfl⟩ := List.mem_map.1 hl
        exact ⟨g', hg', i, hi, rfl⟩
      obtain ⟨g1', hg1', i1, hi1, rfl⟩ := hmem g1 hg1 l1 hl1
      obtain ⟨g2', hg2', i2, hi2, rfl⟩ := hmem g2 hg2 l2 hl2
      exact ⟨xv, ⟨g1', hg1', i1, hi1, hle1⟩, ⟨g2', hg2', i2, hi2, hle2⟩, fun _ => hv⟩
    · obtain ⟨g0, hg0⟩ := List.exists_mem_of_ne_nil gs hgs0
      obtain ⟨i0, hi0⟩ := List.exists_mem_of_ne_nil g0 (hgs1 g0 hg0)
      exact ⟨e i0, ⟨g0, hg0, i0, hi0, Nat.le_refl _⟩, ⟨g0, hg0, i0, hi0, Nat.le_refl _⟩,
        fun h => (hc h).elim⟩
  have hex : ∀ G, ∃ ℓ, G ∈ gets → (∃ g ∈ G.2, ∃ i ∈ g, e i ≤ ℓ) ∧
      (∃ g ∈ G.2, ∃ i ∈ g, ℓ ≤ e i) ∧
      (Complete C mb h2 (tab Tb.pub) (fun i => Tb.bkt (p i)) (fun i => (X.G.lab (r i)).rval) σ G →
        Valid (tab ℓ) G.1 (rustGet mb (h2 (C.hash G.1)) G.1
          (G.2.map (fun g => (g.map (fun i => (X.G.lab (r i)).rval), g.map σ))))) := by
    intro G
    by_cases hG : G ∈ gets
    · obtain ⟨ℓ, h⟩ := hget G hG; exact ⟨ℓ, fun _ => h⟩
    · exact ⟨0, fun h => (hG h).elim⟩
  let ℓ : K × List (List Nat) → Nat := fun G => Classical.choose (hex G)
  have hℓ := fun G => Classical.choose_spec (hex G)
  refine ⟨e, σ, ℓ, hemono, fun i hi => ⟨(heb i hi).1, Nat.lt_of_le_of_lt (heb i hi).2 (hxF i hi),
    fun d hd hh => Nat.lt_of_le_of_lt (heb i hi).2 ((hxb i hi).2.2 d hd hh), hσenc i hi, hσcase i hi,
    hσz i hi⟩,
    fun G hG => hℓ G hG, ?_⟩
  refine hgo.imp_of_mem (fun {G G'} hG hG' hlt => ?_)
  obtain ⟨-, ⟨g, hg, i, hi, h1⟩, -⟩ := hℓ G hG
  obtain ⟨⟨g', hg', j, hj, h2'⟩, -, -⟩ := hℓ G' hG'
  have hij := hlt g hg i hi g' hg' j hj
  have hjM := (hgk G' hG' g' hg' j hj).1
  exact Nat.le_trans h1 (Nat.le_trans (hemono i j (Nat.le_of_lt hij) hjM) h2')

end Global


end SyncTable.RC11Global

#print axioms SyncTable.RC11Global.chain_view
#print axioms SyncTable.RC11Global.chain_replicaSync
#print axioms SyncTable.RC11Global.get_valid
#print axioms SyncTable.RC11Global.obsOK_lag
#print axioms SyncTable.RC11Global.obsOK_fwd
#print axioms SyncTable.RC11Global.reader_lin
#print axioms SyncTable.RC11Global.hist_of_run
#print axioms SyncTable.RC11Global.valid_hist
