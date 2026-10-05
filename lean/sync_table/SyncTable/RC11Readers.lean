import SyncTable.RC11Global

/-!
# Property 18: probe positions, bucket data, and all reader threads together

`RC11Global.reader_lin` linearizes the `get`s of **one** reader thread, given `hkey` (one key
reaches one bucket at one position of the control array) and without the bucket data. This
file closes those gaps:

* `probe_pos_inj`, `hkey_of_probe`: `hkey` from the probe model. A load of group `j` of a
  lookup of `k` at byte `b < W` reads control position `(probeAt W n (hash k) j).1 + b`
  (`Bytes.probeAt_eq`: Rust's `ProbeSeq`), and that position's bucket is `% n`
  (`Bytes.ctrl_mirror`). Group positions of one hash are congruent mod `W`, `W ∣ n`, so equal
  buckets force equal bytes `b` and equal group positions: the position is a function of the
  key's hash and the bucket.
* `TableData`, `load_data`: the bucket data. Every insertion of `(k, v)` into bucket `b` (the
  version at which the bucket stops being `EMPTY`, or the publication for buckets copied by a
  resize) writes the data location `dat b` with `dval k v`, `po`-before the operation's `Release`
  control stores of `b` (or the publication's `current` store); no other writer operation of the
  table's life writes `dat b`. Then a data read `po`-after a control-byte load that returned the
  byte of `full k v` reads exactly `dval k v`, from a write that happens before it, and every
  write to the location is `hb`-ordered with it (no data race). This is `full_read_data` for
  the loads of `reader_lin`, including a lagging or leading replica byte and resized tables.
* `RThread`, `RThread.lin`: `reader_lin` with `hkey` derived and the data conjunct: the slot
  `σ i` each load returned is the one whose pair any later data read of the bucket returns, so
  Rust's result (the key compared and the value returned are those of the data read) is
  `rustGet` on the slots, `Valid` at the version `ℓ G`.
* `merge_threads`, `readers_lin`: **all reader threads together**. Readers do not write, so the
  per-thread placements merge: one list `lin` of all `get`s of all threads, sorted by version
  `ℓ`, containing each thread's `get`s in its program order, each `get` valid at its version.
  With the writer operations in lock order and each `get` inserted after operation `ℓ G` (ties
  in `lin` order), this is one sequential history explaining every `get` and every writer
  operation.
-/

namespace SyncTable.RC11Readers
open RC11 RC11.Graph SyncTable.RC11Table SyncTable.RC11Global

/-! ## The position of a bucket in a key's probe -/

theorem pow2_dvd {W n : Nat} (hW : W.isPowerOfTwo) (hn : n.isPowerOfTwo) (h : W ≤ n) :
    W ∣ n := by
  obtain ⟨a, rfl⟩ := hW; obtain ⟨c, rfl⟩ := hn
  exact Nat.pow_dvd_pow 2 ((Nat.pow_le_pow_iff_right (by decide)).1 h)

theorem mod_cancel_small {W x y c : Nat} (hx : x < W) (hy : y < W) (hc : c < W)
    (h : (c + x) % W = (c + y) % W) : x = y := by
  have h1 := Nat.mod_add_div (c + x) W
  have h2 := Nat.mod_add_div (c + y) W
  have q1 : (c + x) / W < 2 := Nat.div_lt_iff_lt_mul (by omega) |>.2 (by omega)
  have q2 : (c + y) / W < 2 := Nat.div_lt_iff_lt_mul (by omega) |>.2 (by omega)
  generalize (c + x) / W = a at h1 q1
  generalize (c + y) / W = b at h2 q2
  rcases (show a = 0 ∨ a = 1 by omega) with rfl | rfl <;>
  rcases (show b = 0 ∨ b = 1 by omega) with rfl | rfl <;> simp at h1 h2 <;> omega

/-- **One bucket, one position.** Two bytes `b1`, `b2 < W` of groups `j1`, `j2` of the probe of
one hash `h` (Rust's `ProbeSeq` positions, `Bytes.probeAt`) that are the same bucket
(`% n`, `Bytes.ctrl_mirror`) are the same control-array position. -/
theorem probe_pos_inj {W n : Nat} (hW : W.isPowerOfTwo) (hn : n.isPowerOfTwo) (hWn : W ≤ n)
    (h : Nat) {j1 j2 b1 b2 : Nat} (hb1 : b1 < W) (hb2 : b2 < W)
    (heq : ((Bytes.probeAt W n h j1).1 + b1) % n = ((Bytes.probeAt W n h j2).1 + b2) % n) :
    (Bytes.probeAt W n h j1).1 + b1 = (Bytes.probeAt W n h j2).1 + b2 := by
  have hd := pow2_dvd hW hn hWn
  have hn0 : 0 < n := Nat.pos_of_isPowerOfTwo hn
  have hW0 : 0 < W := Nat.pos_of_isPowerOfTwo hW
  simp only [Bytes.probeAt_eq W n h hn] at heq ⊢
  generalize ht1 : W * (j1 * (j1 + 1) / 2) = t1 at heq ⊢
  generalize ht2 : W * (j2 * (j2 + 1) / 2) = t2 at heq ⊢
  have hm : ∀ t, W ∣ t → (h + t) % n % W = h % W := by
    intro t ht
    rw [Nat.mod_mod_of_dvd _ hd]; obtain ⟨q, rfl⟩ := ht; exact Nat.add_mul_mod_self_left h W q
  have hW1 := hm t1 (by rw [← ht1]; exact Nat.dvd_mul_right _ _)
  have hW2 := hm t2 (by rw [← ht2]; exact Nat.dvd_mul_right _ _)
  have hw := congrArg (· % W) heq
  simp only [Nat.mod_mod_of_dvd _ hd] at hw
  rw [Nat.add_mod, hW1, Nat.add_mod ((h + t2) % n), hW2, Nat.mod_eq_of_lt hb1,
    Nat.mod_eq_of_lt hb2] at hw
  have hbb := mod_cancel_small hb1 hb2 (Nat.mod_lt h hW0) hw
  subst hbb
  have hp := mod_cancel_small (W := n) (c := b1) (Nat.mod_lt (h + t1) hn0)
    (Nat.mod_lt (h + t2) hn0) (by omega)
    (by rw [Nat.add_comm b1, Nat.add_comm b1]; exact heq)
  rw [hp]

section Key
variable {E L K : Type} {X : Writer E L Nat} {T : Track X}

/-- **`hkey` from the probe model.** If load `i` (of a lookup of `key i`) reads byte `b < W` of
group `j` of the probe of `key i`'s hash (`hpos`), and a position's bucket is the position
`% n` (`hbkt`), then one key reaches one bucket at one position. -/
theorem hkey_of_probe (Tb : TableLocs X T) (hash : K → Nat) {W n M : Nat}
    (hW : W.isPowerOfTwo) (hn : n.isPowerOfTwo) (hWn : W ≤ n) {p : Nat → Nat} {key : Nat → K}
    (hbkt : ∀ i, i < M → Tb.bkt (p i) = p i % n)
    (hpos : ∀ i, i < M → ∃ j b, b < W ∧ p i = (Bytes.probeAt W n (hash (key i)) j).1 + b) :
    ∀ i j, i < M → j < M → key i = key j → Tb.bkt (p i) = Tb.bkt (p j) → p i = p j := by
  intro i j hi hj hk hb
  obtain ⟨j1, b1, hb1, e1⟩ := hpos i hi
  obtain ⟨j2, b2, hb2, e2⟩ := hpos j hj
  rw [hbkt i hi, hbkt j hj, e1, e2, hk] at hb
  rw [e1, e2, hk]
  exact probe_pos_inj hW hn hWn _ hb1 hb2 hb

end Key

/-! ## Bucket data -/

section Data
variable {E L K VV : Type} [DecidableEq K] {X : Writer E L Nat} {T : Track X}

/-- **The bucket data locations of one table** (the part of the interface for the data a
reader reads after a matching control byte). `tab` is the table after each writer operation of
its life `[pub, dF)`. An insertion of `(k, v)` into bucket `b` at version `y` (the slot is
non-`EMPTY` at `y` and `EMPTY` before, or `y` is the publication, which copies the entries of a
resized table) writes `dat b` with `dval k v` (`write`): `po`-before the publication's `current`
store, or `po`-before every control-byte store of `b` of the operation (`insert`'s
`bucket.write` before `record_item_insert_at`'s `set_ctrl_release`). No other writer operation of
the table's life writes `dat b` (`only`: a bucket is written once, inserts go into `EMPTY`
buckets only), and an operation of the table's life writes a data location once (`uniq`). -/
structure TableData (Tb : TableLocs X T) (tab : Nat → Table K VV) (dF : Nat) where
  dat : Nat → L
  dval : K → VV → Nat
  write : ∀ b y k v, Tb.pub ≤ y → y < dF → (tab y).slot b = .full k v →
    (y = Tb.pub ∨ (tab (y - 1)).slot b = .empty) →
    ∃ d, X.G.isW d ∧ X.G.loc d = dat b ∧ X.op d = some y ∧ (X.G.lab d).wval = dval k v ∧
      (y = Tb.pub → X.G.po d Tb.S) ∧
      (Tb.pub < y → ∀ wc q, X.G.isW wc → X.G.loc wc = Tb.ctrl q → Tb.bkt q = b →
        X.op wc = some y → X.G.po d wc)
  only : ∀ w j b, X.G.isW w → X.G.loc w = dat b → X.op w = some j → Tb.pub ≤ j → j < dF →
    (tab j).slot b ≠ .empty ∧ (j = Tb.pub ∨ (tab (j - 1)).slot b = .empty)
  uniq : ∀ w w' j b, X.G.isW w → X.G.isW w' → X.G.loc w = dat b → X.G.loc w' = dat b →
    X.op w = some j → X.op w' = some j → Tb.pub ≤ j → j < dF → w = w'

omit [DecidableEq K] in
theorem exists_first (P : Nat → Prop) : ∀ a, P a → ∃ y, y ≤ a ∧ P y ∧ ∀ y', y' < y → ¬ P y'
  | a, h => by
    by_cases hx : ∃ y', y' < a ∧ P y'
    · obtain ⟨y', hy', hp⟩ := hx
      obtain ⟨y, h1, h2, h3⟩ := exists_first P y' hp
      exact ⟨y, by omega, h2, h3⟩
    · exact ⟨a, Nat.le_refl _, h, fun y' hy' hp => hx ⟨y', hy', hp⟩⟩

/-- `hb` from an event to a writer operation's events: before the operation, or in it. -/
theorem hb_acq_le {e : E} {j y : Nat} (hj : X.op e = some j) (hjy : y ≤ j) :
    X.acq y = e ∨ X.G.hb (X.acq y) e := by
  rcases Nat.lt_or_eq_of_le hjy with h | h
  · exact .inr (X.op_hb (X.acq_op y) hj h)
  · subst h; rcases (X.in_op e y hj).1 with h | h
    · exact .inl h
    · exact .inr (po_hb h)

/-- **The data read after a control byte, over RC11 graphs.** A reader's `Acquire` load `r` of
control position `q` (after its `current` load `A` read the publication, before the free
`dF`) returned the byte of `full k v`, and the bucket holds `(k, v)` at some version `z` of the
table's life (as `reader_lin`'s `σ`). A data read `r'` of the bucket, `po`-after `r` (and before
the free), reads exactly the insertion's write of `dval k v`, which happens before it; every
write to the location is `hb`-ordered with `r'`: no data race. Writes not by the writer
(`hnfD`: a previous owner of the memory, before the publishing operation; a later owner, after
the read: property 11) are ordered by assumption. -/
theorem load_data (Tb : TableLocs X T) (C : Cfg K) {h2 : Nat → Nat} (hh2 : ∀ h, h2 h < 0x80)
    {tab : Nat → Table K VV} {dF : Nat} (Lf : Life Tb dF) (hH : Hist C tab Tb.pub dF)
    (henc : ∀ x q, Tb.pub ≤ x → x < dF →
      T.vof x (Tb.ctrl q) = Bytes.encSlot C.hash h2 ((tab x).slot (Tb.bkt q)))
    (D : TableData Tb tab dF)
    {A r w r' : E} {q z : Nat} {k : K} {v : VV}
    (hA : X.G.rf Tb.S A) (hAa : X.G.isAcq A ∧ X.G.atomic A) (hAr : X.G.po A r)
    (hrf : X.G.rf w r) (hloc : X.G.loc r = Tb.ctrl q) (hacq : X.G.isAcq r ∧ X.G.atomic r)
    (hnf : ∀ w', X.G.isW w' → X.G.loc w' = X.G.loc r → X.op w' = none →
      X.G.hb w' (Tb.ini (X.G.loc r)) ∨ X.G.hb r w')
    (hfree : X.G.hb r (X.acq dF))
    (hz1 : Tb.pub ≤ z) (hz2 : z < dF) (hzs : (tab z).slot (Tb.bkt q) = .full k v)
    (hrv : (X.G.lab r).rval = Bytes.encSlot C.hash h2 (.full k v))
    (hrr : X.G.po r r') (hR : X.G.isR r') (hl : X.G.loc r' = D.dat (Tb.bkt q))
    (hnfD : ∀ w'', X.G.isW w'' → X.G.loc w'' = D.dat (Tb.bkt q) → X.op w'' = none →
      X.G.hb w'' (X.acq Tb.pub) ∨ X.G.hb r' w'')
    (hfreeD : X.G.hb r' (X.acq dF)) :
    ∃ d, X.G.rf d r' ∧ (X.G.lab r').rval = D.dval k v ∧ X.G.hb d r' ∧
      ∀ w'', X.G.isW w'' → X.G.loc w'' = D.dat (Tb.bkt q) → X.G.hb w'' r' ∨ X.G.hb r' w'' := by
  have hc := X.cons
  have htl : Tb.tl (X.G.loc r) := by rw [hloc]; exact Tb.ctrl_tl _
  obtain ⟨a, ha⟩ := src_tracked Tb hA hAa hAr hrf htl hnf
  obtain ⟨hwW, -, hlw, hwv⟩ := hc.rf_wr _ _ hrf
  -- the store read is of an operation of the table's life
  have hapub : Tb.pub ≤ a := by
    obtain ⟨hiw, hil, hio⟩ := Tb.ini_w _ htl
    have hir : X.G.hb (Tb.ini (X.G.loc r)) r :=
      mp_hb hc (.inr (Tb.init_po _ hiw (by rw [hil]; exact htl) hio)) hA Tb.S_rel.1
        hAa.1 Tb.S_rel.2 hAa.2 (.inr hAr)
    exact X.seen hir hrf hiw hil hio ha
  have haF : a < dF := by
    apply Nat.lt_of_not_le; intro hd
    have h2 : X.G.hb r w := by
      rcases hb_acq_le ha hd with e | e
      · rw [← e]; exact hfree
      · exact hb_trans hfree e
    exact (hc.coh _ _ h2).2 (.base (Or.inl hrf))
  -- the slot at the store's version is `(k, v)`
  have hva : Bytes.encSlot C.hash h2 ((tab a).slot (Tb.bkt q)) = h2 (C.hash k) := by
    rw [← henc a q hapub haF, ← hloc, ← hlw, ← T.wval w a hwW (by rw [hlw]; exact Tb.tl_tr _ htl) ha,
      hwv, hrv]; rfl
  have hne : (tab a).slot (Tb.bkt q) ≠ .empty := by
    intro e; rw [e] at hva; have := hh2 (C.hash k)
    simp only [Bytes.encSlot, Bytes.EMPTY] at hva; omega
  have hsa : (tab a).slot (Tb.bkt q) = .full k v := by
    rcases Nat.lt_or_ge z a with hza | haz
    · have hg := (hH.grows hz1 a (Nat.le_of_lt hza) haF).2 (Tb.bkt q) (by rw [hzs]; intro e; cases e)
      cases hs : (tab a).slot (Tb.bkt q) with
      | empty => exact (hne hs).elim
      | full k' v' => rw [← hzs]; exact (hg.2 k' v' hs).symm
      | mistagged k' v' => exact ((hH.wf a hapub haF).noMis _ _ _ hs).elim
      | deleted k' v' =>
        rw [hs] at hva; have := hh2 (C.hash k)
        simp only [Bytes.encSlot, Bytes.DELETED] at hva; omega
    · exact ((hH.grows hapub z haz hz2).2 _ hne).2 k v hzs
  -- the insertion: the first version at which the bucket is not `EMPTY`
  obtain ⟨y, hya, ⟨hy0, hyne⟩, hymin⟩ := exists_first
    (fun y => Tb.pub ≤ y ∧ (tab y).slot (Tb.bkt q) ≠ .empty) a ⟨hapub, hne⟩
  have hyF : y < dF := by omega
  have hys : (tab y).slot (Tb.bkt q) = .full k v :=
    ((hH.grows hy0 a hya haF).2 _ hyne).2 k v hsa
  have hyi : y = Tb.pub ∨ (tab (y - 1)).slot (Tb.bkt q) = .empty := by
    rcases Nat.lt_or_eq_of_le hy0 with h | h
    · right; apply Classical.byContradiction; intro hn
      exact hymin (y - 1) (by omega) ⟨by omega, hn⟩
    · left; exact h.symm
  obtain ⟨d, hdW, hdl, hdop, hdval, hdS, hdc⟩ := D.write _ y k v hy0 hyF hys hyi
  -- the data write happens before the data read
  have hdr : X.G.hb d r' := by
    have hAr' : X.G.po A r' := hc.po_trans _ _ _ hAr hrr
    rcases Nat.lt_or_eq_of_le hy0 with hpy | hpy
    · have hwrel := Lf.rel w a hwW (by rw [hlw]; exact htl) ha (by omega) haF
      rcases Nat.lt_or_eq_of_le hya with hlt | heq
      · exact hb_trans (X.op_hb hdop ha hlt)
          (mp_hb hc (.inl rfl) hrf hwrel.1 hacq.1 hwrel.2 hacq.2 (.inr hrr))
      · subst heq
        exact mp_hb hc (.inr (hdc hpy w q hwW (hlw.trans hloc) rfl ha)) hrf hwrel.1 hacq.1
          hwrel.2 hacq.2 (.inr hrr)
    · exact mp_hb hc (.inr (hdS hpy.symm)) hA Tb.S_rel.1 hAa.1 Tb.S_rel.2 hAa.2 (.inr hAr')
  -- every write to the bucket's data is `d`, before `d`, or after the read
  have hother : ∀ w'', X.G.isW w'' → X.G.loc w'' = D.dat (Tb.bkt q) →
      w'' = d ∨ X.G.hb w'' d ∨ X.G.hb r' w'' := by
    intro w'' hw'' hl''
    cases hj : X.op w'' with
    | none =>
      rcases hnfD w'' hw'' hl'' hj with h | h
      · right; left
        rcases hb_acq_le hdop hy0 with e | e
        · rw [← e]; exact h
        · exact hb_trans h e
      · exact .inr (.inr h)
    | some j =>
      by_cases hjp : j < Tb.pub
      · exact .inr (.inl (X.op_hb hj hdop (by omega)))
      by_cases hjF : dF ≤ j
      · right; right
        rcases hb_acq_le hj hjF with e | e
        · rw [← e]; exact hfreeD
        · exact hb_trans hfreeD e
      obtain ⟨hjne, hji⟩ := D.only w'' j _ hw'' hl'' hj (by omega) (by omega)
      have hjy : j = y := by
        rcases Nat.lt_trichotomy j y with h | h | h
        · exact (hymin j h ⟨by omega, hjne⟩).elim
        · exact h
        · rcases hji with e | e
          · omega
          · exact absurd e ((hH.grows hy0 (j - 1) (by omega) (by omega)).2 _ hyne).1
      subst hjy
      exact .inl (D.uniq w'' d _ _ hw'' hdW hl'' hdl hj hdop (by omega) (by omega))
  have hrfd : X.G.rf d r' := by
    obtain ⟨w0, h0⟩ := hc.rf_total r' hR
    obtain ⟨hw0, -, hl0, -⟩ := hc.rf_wr _ _ h0
    rcases hother w0 hw0 (hl0.trans hl) with e | e | e
    · rw [← e]; exact h0
    · rcases hb_read_coh hc hdr h0 hdW (hdl.trans hl.symm) with e' | e'
      · rw [e'] at e; exact (hb_irrefl hc _ e).elim
      · exact ((hc.coh _ _ e).2 (.base (Or.inr (Or.inl e')))).elim
    · exact ((hc.coh _ _ e).2 (.base (Or.inl h0))).elim
  refine ⟨d, hrfd, ?_, hdr, fun w'' hw'' hl'' => ?_⟩
  · rw [← (hc.rf_wr _ _ hrfd).2.2.2, hdval]
  · rcases hother w'' hw'' hl'' with e | e | e
    · rw [e]; exact .inl hdr
    · exact .inl (hb_trans e hdr)
    · exact .inr e

end Data

/-! ## One reader thread: `reader_lin` with positions and data -/

section Thread
variable {E L K VV : Type} [DecidableEq K] {X : Writer E L Nat} {T : Track X}

/-- **A reader thread of one table**: `reader_lin`'s hypotheses, with `hkey` replaced by Rust's
probe positions (`hpos`, `hbkt`; see `hkey_of_probe`). `W` is `Group::WIDTH`, `n` the table's
bucket count. -/
structure RThread (Tb : TableLocs X T) (C : Cfg K) (W n dF : Nat) where
  A : E
  M : Nat
  r : Nat → E
  w : Nat → E
  p : Nat → Nat
  lo : Nat → Nat
  key : Nat → K
  gets : List (K × List (List Nat))
  hA : X.G.rf Tb.S A
  hAa : X.G.isAcq A ∧ X.G.atomic A
  hAr : ∀ i, i < M → X.G.po A (r i)
  hrf : ∀ i, i < M → X.G.rf (w i) (r i)
  hloc : ∀ i, i < M → X.G.loc (r i) = Tb.ctrl (p i)
  hacq : ∀ i, i < M → X.G.isAcq (r i) ∧ X.G.atomic (r i)
  hpo : ∀ k i, k < i → i < M → X.G.po (r k) (r i)
  hnf : ∀ i, i < M → ∀ w', X.G.isW w' → X.G.loc w' = X.G.loc (r i) → X.op w' = none →
    X.G.hb w' (Tb.ini (X.G.loc (r i))) ∨ X.G.hb (r i) w'
  hfree : ∀ i, i < M → X.G.hb (r i) (X.acq dF)
  hlo0 : ∀ i, i < M → Tb.pub ≤ lo i
  hlom : ∀ k i, k ≤ i → i < M → lo k ≤ lo i
  hloR : ∀ i, i < M → lo i = Tb.pub ∨ X.G.hb (X.rel (lo i)) (r i)
  hbkt : ∀ i, i < M → Tb.bkt (p i) = p i % n
  hpos : ∀ i, i < M → ∃ j b, b < W ∧ p i = (Bytes.probeAt W n (C.hash (key i)) j).1 + b
  hgk : ∀ G ∈ gets, ∀ g ∈ G.2, ∀ i ∈ g, i < M ∧ key i = G.1
  hgne : ∀ G ∈ gets, G.2 ≠ [] ∧ ∀ g ∈ G.2, g ≠ []
  hgo : gets.Pairwise (fun G G' => ∀ g ∈ G.2, ∀ i ∈ g, ∀ g' ∈ G'.2, ∀ j ∈ g', i < j)

/-- What `RThread.lin` proves for one thread with placements `e`, slots `σ`, versions `ℓ`
(module docs of `RC11Global` and `RThread.lin`). -/
def ThreadLin {Tb : TableLocs X T} {C : Cfg K} {W n dF : Nat} (R : RThread Tb C W n dF)
    {h2 : Nat → Nat} (mb : List Nat → Nat → List Bool) (tab : Nat → Table K VV)
    (D : TableData Tb tab dF)
    (e : Nat → Nat) (σ : Nat → Slot K VV) (ℓ : K × List (List Nat) → Nat) : Prop :=
  (∀ i j, i ≤ j → j < R.M → e i ≤ e j) ∧
  (∀ i, i < R.M → R.lo i ≤ e i ∧ e i < dF ∧
    (∀ d, R.lo i < d → X.G.hb (R.r i) (X.acq d) → e i < d) ∧
    (X.G.lab (R.r i)).rval = Bytes.encSlot C.hash h2 (σ i) ∧
    (σ i = (tab (e i)).slot (Tb.bkt (R.p i)) ∨ σ i = (tab (e i + 1)).slot (Tb.bkt (R.p i)) ∨
      σ i = (tab (e i - 1)).slot (Tb.bkt (R.p i))) ∧
    -- the bucket data read after the byte is the slot's pair, race free
    ∀ k v, σ i = .full k v → ∀ r', X.G.po (R.r i) r' → X.G.isR r' →
      X.G.loc r' = D.dat (Tb.bkt (R.p i)) → X.G.hb r' (X.acq dF) →
      (∀ w'', X.G.isW w'' → X.G.loc w'' = D.dat (Tb.bkt (R.p i)) → X.op w'' = none →
        X.G.hb w'' (X.acq Tb.pub) ∨ X.G.hb r' w'') →
      ∃ d, X.G.rf d r' ∧ (X.G.lab r').rval = D.dval k v ∧ X.G.hb d r' ∧
        ∀ w'', X.G.isW w'' → X.G.loc w'' = D.dat (Tb.bkt (R.p i)) →
          X.G.hb w'' r' ∨ X.G.hb r' w'') ∧
  (∀ G ∈ R.gets, (∃ g ∈ G.2, ∃ i ∈ g, e i ≤ ℓ G) ∧ (∃ g ∈ G.2, ∃ i ∈ g, ℓ G ≤ e i) ∧
    (Complete C mb h2 (tab Tb.pub) (fun i => Tb.bkt (R.p i)) (fun i => (X.G.lab (R.r i)).rval)
        σ G →
      Valid (tab (ℓ G)) G.1 (rustGet mb (h2 (C.hash G.1)) G.1
        (G.2.map (fun g => (g.map (fun i => (X.G.lab (R.r i)).rval), g.map σ)))))) ∧
  R.gets.Pairwise (fun G G' => ℓ G ≤ ℓ G')

/-- **Property 18 for one reader thread, closed**: `reader_lin` with `hkey` derived from the
probe positions (`hkey_of_probe`) and the bucket data combined (`load_data`): for every load
whose byte was a `FULL` byte of slot `σ i = full k v`, a later data read of the bucket returns
`dval k v`, race free. So Rust's `get` (which compares the key read from the data and returns
the value read) computes `rustGet` on the slots `σ`, and that result is `Valid` at `ℓ G`. -/
theorem RThread.lin {Tb : TableLocs X T} {C : Cfg K} {W n dF : Nat} (R : RThread Tb C W n dF)
    (hW : W.isPowerOfTwo) (hn : n.isPowerOfTwo) (hWn : W ≤ n)
    {h2 : Nat → Nat} (hh2 : ∀ h, h2 h < 0x80)
    {mb : List Nat → Nat → List Bool} (hmb : Bytes.MatchOK mb)
    {tab : Nat → Table K VV} (Lf : Life Tb dF) (hH : Hist C tab Tb.pub dF)
    (henc : ∀ x q, Tb.pub ≤ x → x < dF →
      T.vof x (Tb.ctrl q) = Bytes.encSlot C.hash h2 ((tab x).slot (Tb.bkt q)))
    (D : TableData Tb tab dF) :
    ∃ e σ ℓ, ThreadLin R (h2 := h2) mb tab D e σ ℓ := by
  obtain ⟨e, σ, ℓ, h1, h2', h3, h4⟩ := reader_lin Tb C hh2 hmb Lf hH henc R.hA R.hAa R.hAr R.hrf
    R.hloc R.hacq R.hpo R.hnf R.hfree R.hlo0 R.hlom R.hloR
    (hkey_of_probe Tb C.hash hW hn hWn R.hbkt R.hpos) R.gets R.hgk R.hgne R.hgo
  refine ⟨e, σ, ℓ, h1, fun i hi => ?_, h3, h4⟩
  obtain ⟨a1, a2, a3, a4, a5, z, hz1, hz2, hz⟩ := h2' i hi
  refine ⟨a1, a2, a3, a4, a5, fun k v hσ r' hrr hR hl hfreeD hnfD => ?_⟩
  exact load_data Tb C hh2 Lf hH henc D R.hA R.hAa (R.hAr i hi) (R.hrf i hi) (R.hloc i hi)
    (R.hacq i hi) (R.hnf i hi) (R.hfree i hi) hz1 hz2 (hz ▸ hσ)
    (by rw [a4, hσ]) hrr hR hl hnfD hfreeD

end Thread

/-! ## All reader threads -/

section Merge
variable {α : Type}

theorem filter_tag_other (gs : Nat → List α) (u : Nat) :
    ∀ us : List Nat, u ∉ us →
      (us.flatMap (fun u' => (gs u').map (fun G => (u', G)))).filter (fun a => a.1 == u) = []
  | [], _ => rfl
  | u' :: us, h => by
    have hne : u' ≠ u := fun e => h (e ▸ List.mem_cons_self)
    rw [List.flatMap_cons, List.filter_append,
      filter_tag_other gs u us (fun hm => h (List.mem_cons_of_mem _ hm)), List.append_nil,
      List.filter_eq_nil_iff]
    intro a ha
    obtain ⟨G, -, rfl⟩ := List.mem_map.1 ha
    simpa using hne

theorem filter_tag (gs : Nat → List α) (u : Nat) :
    ∀ us : List Nat, us.Nodup → u ∈ us →
      (us.flatMap (fun u' => (gs u').map (fun G => (u', G)))).filter (fun a => a.1 == u) =
        (gs u).map (fun G => (u, G))
  | [], _, h => by cases h
  | u' :: us, hnd, hu => by
    rw [List.flatMap_cons, List.filter_append]
    obtain ⟨hn1, hn2⟩ := List.nodup_cons.1 hnd
    by_cases e : u' = u
    · subst e
      rw [filter_tag_other gs u' us hn1, List.append_nil, List.filter_eq_self]
      intro a ha
      obtain ⟨G, -, rfl⟩ := List.mem_map.1 ha
      simp
    · have hu' : u ∈ us := by
        rcases List.mem_cons.1 hu with h | h
        · exact (e h.symm).elim
        · exact h
      rw [filter_tag gs u us hn2 hu', List.filter_eq_nil_iff.2 (fun a ha => by
        obtain ⟨G, -, rfl⟩ := List.mem_map.1 ha
        simpa using e), List.nil_append]

/-- **Merging threads by version.** Per-thread lists `gs u`, each monotone in its version
`ℓ u`, merge into one list sorted by version that contains exactly the tagged `get`s of all
threads and, restricted to any thread, is that thread's list in its order. -/
theorem merge_threads (us : List Nat) (hus : us.Nodup) (gs : Nat → List α)
    (ℓ : Nat → α → Nat) (hmono : ∀ u ∈ us, (gs u).Pairwise (fun a b => ℓ u a ≤ ℓ u b)) :
    ∃ lin : List (Nat × α), lin.Pairwise (fun a b => ℓ a.1 a.2 ≤ ℓ b.1 b.2) ∧
      lin.Perm (us.flatMap (fun u => (gs u).map (fun G => (u, G)))) ∧
      ∀ u ∈ us, lin.filter (fun a => a.1 == u) = (gs u).map (fun G => (u, G)) := by
  let all := us.flatMap (fun u => (gs u).map (fun G => (u, G)))
  let le : Nat × α → Nat × α → Bool := fun a b => decide (ℓ a.1 a.2 ≤ ℓ b.1 b.2)
  have htr : ∀ a b c, le a b → le b c → le a c := by
    intro a b c h1 h2; simp only [le, decide_eq_true_eq] at *; omega
  have htot : ∀ a b, (le a b || le b a) := by
    intro a b; simp only [le, Bool.or_eq_true, decide_eq_true_eq]; omega
  refine ⟨all.mergeSort le, ?_, List.mergeSort_perm all le, fun u hu => ?_⟩
  · exact (List.pairwise_mergeSort htr htot all).imp (fun h => by simpa [le] using h)
  · let c := (gs u).map (fun G => (u, G))
    have hc : c.Pairwise (fun a b => le a b) := by
      refine List.pairwise_map.2 ((hmono u hu).imp (fun h => ?_))
      simpa [le] using h
    have hsub : List.Sublist c all := by
      have : c ∈ us.map (fun u => (gs u).map (fun G => (u, G))) := List.mem_map.2 ⟨u, hu, rfl⟩
      have h := List.sublist_flatten_of_mem this
      rwa [← List.flatMap_def] at h
    have h1 := (List.sublist_mergeSort htr htot hc hsub).filter (fun a => a.1 == u)
    have hcf : c.filter (fun a => a.1 == u) = c := by
      rw [List.filter_eq_self]; intro a ha
      obtain ⟨G, -, rfl⟩ := List.mem_map.1 ha; simp
    rw [hcf] at h1
    have h2 := ((List.mergeSort_perm all le).filter (fun a => a.1 == u)).length_eq
    rw [filter_tag gs u us hus hu] at h2
    exact (h1.eq_of_length h2.symm).symm

end Merge

section Readers
variable {E L K VV : Type} [DecidableEq K] {X : Writer E L Nat} {T : Track X}

/-- **Property 18 for all reader threads together.** Reader threads `R u` (`u ∈ us`, distinct)
of one table, each an `RThread`. There are, per thread, placements `e u`, slots `σ u` and
versions `ℓ u` with everything `RThread.lin` proves (`ThreadLin`: placements in each load's
`hb` window, the bytes and data read are those of the slots, each completed `get` `Valid` at its
version, versions monotone in the thread's program order), and one list `lin` of all `get`s of
all threads (tagged with their thread), sorted by version, that restricted to each thread is
that thread's `get`s in program order. Readers do not write, so this is one sequential history:
the writer's operations in lock order, and after operation `x` the `get`s of `lin` with version
`x`, each returning a result valid for the table after `x`. -/
theorem readers_lin {Tb : TableLocs X T} {C : Cfg K} {W n dF : Nat}
    (hW : W.isPowerOfTwo) (hn : n.isPowerOfTwo) (hWn : W ≤ n)
    {h2 : Nat → Nat} (hh2 : ∀ h, h2 h < 0x80)
    {mb : List Nat → Nat → List Bool} (hmb : Bytes.MatchOK mb)
    {tab : Nat → Table K VV} (Lf : Life Tb dF) (hH : Hist C tab Tb.pub dF)
    (henc : ∀ x q, Tb.pub ≤ x → x < dF →
      T.vof x (Tb.ctrl q) = Bytes.encSlot C.hash h2 ((tab x).slot (Tb.bkt q)))
    (D : TableData Tb tab dF)
    (us : List Nat) (hus : us.Nodup) (R : Nat → RThread Tb C W n dF) :
    ∃ (e : Nat → Nat → Nat) (σ : Nat → Nat → Slot K VV) (ℓ : Nat → K × List (List Nat) → Nat)
      (lin : List (Nat × (K × List (List Nat)))),
      (∀ u ∈ us, ThreadLin (R u) (h2 := h2) mb tab D (e u) (σ u) (ℓ u)) ∧
      lin.Pairwise (fun a b => ℓ a.1 a.2 ≤ ℓ b.1 b.2) ∧
      lin.Perm (us.flatMap (fun u => (R u).gets.map (fun G => (u, G)))) ∧
      ∀ u ∈ us, lin.filter (fun a => a.1 == u) = (R u).gets.map (fun G => (u, G)) := by
  have hex := fun u => (R u).lin hW hn hWn hh2 hmb Lf hH henc D
  let e := fun u => Classical.choose (hex u)
  let σ := fun u => Classical.choose (Classical.choose_spec (hex u))
  let ℓ := fun u => Classical.choose (Classical.choose_spec (Classical.choose_spec (hex u)))
  have hl : ∀ u, ThreadLin (R u) (h2 := h2) mb tab D (e u) (σ u) (ℓ u) := fun u =>
    Classical.choose_spec (Classical.choose_spec (Classical.choose_spec (hex u)))
  obtain ⟨lin, h1, h2', h3⟩ := merge_threads us hus (fun u => (R u).gets) ℓ
    (fun u _ => (hl u).2.2.2)
  exact ⟨e, σ, ℓ, lin, fun u _ => hl u, h1, h2', h3⟩

end Readers

end SyncTable.RC11Readers

#print axioms SyncTable.RC11Readers.probe_pos_inj
#print axioms SyncTable.RC11Readers.hkey_of_probe
#print axioms SyncTable.RC11Readers.load_data
#print axioms SyncTable.RC11Readers.RThread.lin
#print axioms SyncTable.RC11Readers.merge_threads
#print axioms SyncTable.RC11Readers.readers_lin
