/-!
# An RC11-style weak-memory layer (generic)

A small, self-contained (Lean core only) version of the repaired C11 model RC11 of Lahav,
Vafeiadis, Kang, Hur and Dreyer ("Repairing sequential consistency in C/C++11", PLDI 2017),
with the C++20 release sequence. Nothing here is specific to `collect`; `Collect/RC11Pin.lean`
instantiates it for property 11 and `sync_table` can reuse it.

**Events and graphs.** An execution graph over an arbitrary event type `E` gives every event a
label `Lab` (thread, kind, location, access mode, read and written value) and three relations:
`po` (program order, `sb`), `rf` (reads-from, `rf w r`) and `mo` (modification order, a strict
total order on the writes to each location). RMWs are single events of kind `rmw` (they read
and write). Initialisation writes are ordinary write events (by convention on a thread that
runs nothing else). Thread-local computation that touches no shared memory is kind `skip`.

**Derived relations.** `fr` (from-reads, `rf⁻¹; mo` minus identity), `eco` (`(rf ∪ mo ∪ fr)⁺`),
`rs` (release sequence, C++20: `[W]; (rf; rmw)*`), `sw` (synchronises-with, with fences:
`[⊒rel]; ([F]; po)?; rs; rf; [R]; (po; [F])?; [⊒acq]`, both ends atomic) and
`hb = (po ∪ sw)⁺`.

**Consistency** (`Consistent`): well-formedness (`WF`) plus RC11's axioms
* Coherence: `hb; eco?` irreflexive (`coh`);
* Atomicity: an RMW reads its immediate `mo`-predecessor (`rmw ∩ (fr; mo) = ∅`, `atom`);
* No-thin-air: `po ∪ rf` acyclic (`nta`).
RC11's SC axiom (`psc` acyclic) is omitted: no `SeqCst` access or fence occurs outside tests in
this crate (`src/collect.rs`, `src/sync_table.rs`, `src/raw`). Data races on non-atomic
accesses (undefined behaviour in RC11) are not a consistency axiom; results here are about
consistent graphs, i.e. they assume the program is race-free where they need it.

**Mutexes.** A mutex is modelled in the standard way as a location whose writes are an
initialisation write (`Release`) followed only by `AcqRel` RMWs (`LockLoc`; a critical section
is collapsed into one RMW event, see `Collect/RC11Pin.lean`). `lock_mo_hb` proves that the
lock order (`mo` on that location) is contained in `hb`.

**Linearisations.** `exists_lin`: a finite graph's `hb` has a linearisation (a list of all
events with every `hb` edge pointing forward), by a topological sort written here.
-/

namespace RC11

/-- Access modes (`Ordering`). -/
inductive Mode where
  | na | rlx | acq | rel | acqrel | sc
  deriving DecidableEq, Repr

def Mode.isAcq : Mode → Bool
  | .acq | .acqrel | .sc => true
  | _ => false
def Mode.isRel : Mode → Bool
  | .rel | .acqrel | .sc => true
  | _ => false
def Mode.atomic : Mode → Bool
  | .na => false
  | _ => true

/-- Event kinds. `skip`: no shared-memory effect (thread-local computation). -/
inductive Kind where
  | rd | wr | rmw | fence | skip
  deriving DecidableEq, Repr

def Kind.isW : Kind → Bool
  | .wr | .rmw => true
  | _ => false
def Kind.isR : Kind → Bool
  | .rd | .rmw => true
  | _ => false

structure Lab (L V : Type) where
  tid : Nat
  kind : Kind
  loc : L
  mode : Mode
  rval : V
  wval : V

/-- An execution graph. -/
structure Graph (E L V : Type) where
  lab : E → Lab L V
  po : E → E → Prop
  rf : E → E → Prop
  mo : E → E → Prop

/-- Transitive closure. -/
inductive TC {α : Type} (r : α → α → Prop) : α → α → Prop
  | base {a b} : r a b → TC r a b
  | trans {a b c} : TC r a b → TC r b c → TC r a c

theorem TC.mono {α} {r s : α → α → Prop} (h : ∀ a b, r a b → s a b) {a b} (t : TC r a b) :
    TC s a b := by
  induction t with
  | base h1 => exact .base (h _ _ h1)
  | trans _ _ ih1 ih2 => exact .trans ih1 ih2

namespace Graph
variable {E L V : Type} (G : Graph E L V)

def isW (e : E) : Prop := (G.lab e).kind.isW = true
def isR (e : E) : Prop := (G.lab e).kind.isR = true
def isRMW (e : E) : Prop := (G.lab e).kind = .rmw
def isF (e : E) : Prop := (G.lab e).kind = .fence
def isRel (e : E) : Prop := (G.lab e).mode.isRel = true
def isAcq (e : E) : Prop := (G.lab e).mode.isAcq = true
def atomic (e : E) : Prop := (G.lab e).mode.atomic = true
def tid (e : E) : Nat := (G.lab e).tid
def loc (e : E) : L := (G.lab e).loc

/-- From-reads: `r` reads a write `mo`-before `w` (`rf⁻¹; mo`, minus identity). -/
def fr (r w : E) : Prop := (∃ w', G.rf w' r ∧ G.mo w' w) ∧ r ≠ w

/-- Extended coherence order. -/
def eco : E → E → Prop := TC (fun a b => G.rf a b ∨ G.mo a b ∨ G.fr a b)

/-- Release sequence (C++20): a write followed by a chain of RMWs each reading the previous. -/
inductive rs : E → E → Prop
  | refl {w} : G.isW w → rs w w
  | step {w x y} : rs w x → G.rf x y → G.isRMW y → rs w y

/-- Synchronises-with, with fences. -/
def sw (a b : E) : Prop :=
  G.isRel a ∧ G.isAcq b ∧ ∃ w x r, (a = w ∨ (G.isF a ∧ G.po a w)) ∧ G.atomic w ∧ G.rs w x ∧
    G.rf x r ∧ G.atomic r ∧ (b = r ∨ (G.isF b ∧ G.po r b))

/-- Happens-before. -/
def hb : E → E → Prop := TC (fun a b => G.po a b ∨ G.sw a b)

/-- Well-formedness. -/
structure WF : Prop where
  po_tid : ∀ a b, G.po a b → G.tid a = G.tid b
  po_trans : ∀ a b c, G.po a b → G.po b c → G.po a c
  po_irrefl : ∀ a, ¬ G.po a a
  po_total : ∀ a b, G.tid a = G.tid b → a ≠ b → G.po a b ∨ G.po b a
  rf_wr : ∀ w r, G.rf w r →
    G.isW w ∧ G.isR r ∧ G.loc w = G.loc r ∧ (G.lab w).wval = (G.lab r).rval
  rf_uniq : ∀ w w' r, G.rf w r → G.rf w' r → w = w'
  rf_total : ∀ r, G.isR r → ∃ w, G.rf w r
  mo_w : ∀ a b, G.mo a b → G.isW a ∧ G.isW b ∧ G.loc a = G.loc b
  mo_trans : ∀ a b c, G.mo a b → G.mo b c → G.mo a c
  mo_irrefl : ∀ a, ¬ G.mo a a
  mo_total : ∀ a b, G.isW a → G.isW b → G.loc a = G.loc b → a ≠ b → G.mo a b ∨ G.mo b a

/-- RC11 consistency (without the SC axiom, see the module docs). -/
structure Consistent (G : Graph E L V) : Prop extends WF G where
  /-- Coherence: `hb; eco?` is irreflexive. -/
  coh : ∀ a b, G.hb a b → a ≠ b ∧ ¬ G.eco b a
  /-- Atomicity: no write between an RMW and the write it reads. -/
  atom : ∀ w e, G.isRMW e → G.rf w e → ¬ ∃ x, G.mo w x ∧ G.mo x e
  /-- No-thin-air: `po ∪ rf` is acyclic. -/
  nta : ∀ a, ¬ TC (fun a b => G.po a b ∨ G.rf a b) a a

variable {G}

/-! ## Basic facts -/

theorem hb_trans {a b c : E} (h1 : G.hb a b) (h2 : G.hb b c) : G.hb a c := TC.trans h1 h2
theorem po_hb {a b : E} (h : G.po a b) : G.hb a b := TC.base (Or.inl h)
theorem sw_hb {a b : E} (h : G.sw a b) : G.hb a b := TC.base (Or.inr h)

theorem hb_irrefl (hc : G.Consistent) (a : E) : ¬ G.hb a a := fun h => (hc.coh a a h).1 rfl

theorem rf_ne (hc : G.Consistent) {w r : E} (h : G.rf w r) : w ≠ r := by
  rintro rfl; exact hc.nta w (.base (Or.inr h))

/-- A `Release` (or stronger) atomic write read by an `Acquire` (or stronger) atomic read
synchronises with it. -/
theorem rf_sw (hc : G.Consistent) {w r : E} (h : G.rf w r) (hw : G.isRel w) (hr : G.isAcq r)
    (aw : G.atomic w) (ar : G.atomic r) : G.sw w r :=
  ⟨hw, hr, w, w, r, Or.inl rfl, aw, .refl (hc.rf_wr w r h).1, h, ar, Or.inl rfl⟩

/-- Message passing through `po`: `a po w`, `w` a `Release` write, `r` an `Acquire` read of it,
`r po b`: then `a hb b` (`a` and `b` may equal `w` and `r`). -/
theorem mp_hb (hc : G.Consistent) {a w r b : E} (ha : a = w ∨ G.po a w) (h : G.rf w r)
    (hw : G.isRel w) (hr : G.isAcq r) (aw : G.atomic w) (ar : G.atomic r)
    (hb : r = b ∨ G.po r b) : G.hb a b := by
  have hs : G.hb w r := sw_hb (rf_sw hc h hw hr aw ar)
  have h1 : G.hb a r := by
    rcases ha with rfl | ha
    · exact hs
    · exact hb_trans (po_hb ha) hs
  rcases hb with rfl | hb
  · exact h1
  · exact hb_trans h1 (po_hb hb)

/-- Coherence for reads: a read that `w0` happens before does not read a write `mo`-before
`w0`. -/
theorem hb_not_read_older (hc : G.Consistent) {w0 r w' : E} (hh : G.hb w0 r) (hrf : G.rf w' r)
    (hmo : G.mo w' w0) : False := by
  have hne : r ≠ w0 := fun h => by subst h; exact hb_irrefl hc r hh
  exact (hc.coh w0 r hh).2 (.base (Or.inr (Or.inr ⟨⟨w', hrf, hmo⟩, hne⟩)))

/-- A read that a write `w0` to its location happens before reads `w0` or a later write. -/
theorem hb_read_coh (hc : G.Consistent) {w0 r w' : E} (hh : G.hb w0 r) (hrf : G.rf w' r)
    (hw0 : G.isW w0) (hl : G.loc w0 = G.loc r) : w' = w0 ∨ G.mo w0 w' := by
  obtain ⟨hw', -, hl', -⟩ := hc.rf_wr w' r hrf
  by_cases he : w' = w0
  · exact Or.inl he
  · rcases hc.mo_total w' w0 hw' hw0 (hl'.trans hl.symm) he with h | h
    · exact (hb_not_read_older hc hh hrf h).elim
    · exact Or.inr h

/-! ## Lock locations: lock order is in `hb` -/

/-- `ℓ` behaves as a mutex (or a location only accessed by `AcqRel` RMWs): its writes are an
initialisation write `init` (`Release`, atomic, `mo`-first) and `AcqRel` RMWs. -/
structure LockLoc (G : Graph E L V) (ℓ : L) (i0 : E) : Prop where
  init_w : G.isW i0 ∧ G.loc i0 = ℓ ∧ G.isRel i0 ∧ G.atomic i0
  init_first : ∀ e, e ≠ i0 → G.isW e → G.loc e = ℓ → G.mo i0 e
  rmw : ∀ e, e ≠ i0 → G.isW e → G.loc e = ℓ →
    G.isRMW e ∧ G.isR e ∧ G.isRel e ∧ G.isAcq e ∧ G.atomic e

/-- **Lock order is contained in happens-before**: on a lock location, `mo ⊆ hb`. Each RMW
reads its immediate `mo`-predecessor (atomicity), which synchronises with it. The rank `rk`
(e.g. `moRank` on a finite graph) makes `mo` well-founded. -/
theorem lock_mo_hb (hc : G.Consistent) {ℓ : L} {init : E} (hl : LockLoc G ℓ init)
    (rk : E → Nat) (hrk : ∀ a b, G.mo a b → G.loc b = ℓ → rk a < rk b) :
    ∀ x y, G.mo x y → G.loc y = ℓ → G.hb x y := by
  suffices ∀ n x y, rk y < n → G.mo x y → G.loc y = ℓ → G.hb x y from
    fun x y h hy => this _ x y (Nat.lt_succ_self _) h hy
  intro n
  induction n with
  | zero => intro x y h; omega
  | succ n ih =>
    intro x y hn hxy hy
    obtain ⟨hwx, hwy, hlxy⟩ := hc.mo_w x y hxy
    have hyi : y ≠ init := by
      intro hy0
      have hxi : x ≠ init := fun h => by rw [h, hy0] at hxy; exact hc.mo_irrefl _ hxy
      have := hl.init_first x hxi hwx (hlxy.trans hy)
      rw [← hy0] at this
      exact hc.mo_irrefl _ (hc.mo_trans _ _ _ hxy this)
    obtain ⟨hrmw, hr, -, hacq, hat⟩ := hl.rmw y hyi hwy hy
    obtain ⟨w, hwr⟩ := hc.rf_total y hr
    obtain ⟨hww, -, hlw, -⟩ := hc.rf_wr w y hwr
    have hlw' : G.loc w = ℓ := hlw.trans hy
    have hsw : G.sw w y := by
      by_cases hwi : w = init
      · subst hwi; exact rf_sw hc hwr hl.init_w.2.2.1 hacq hl.init_w.2.2.2 hat
      · obtain ⟨-, -, hrel, -, hatw⟩ := hl.rmw w hwi hww hlw'
        exact rf_sw hc hwr hrel hacq hatw hat
    have hwy : G.mo w y := by
      rcases hc.mo_total w y hww hwy hlw (rf_ne hc hwr) with h | h
      · exact h
      · exact ((hc.coh w y (sw_hb hsw)).2 (.base (Or.inr (Or.inl h)))).elim
    by_cases hxw : x = w
    · subst hxw; exact sw_hb hsw
    · rcases hc.mo_total x w hwx hww (hlxy.trans hlw.symm) hxw with h | h
      · exact hb_trans (ih x w (by have := hrk w y hwy hy; omega) h hlw') (sw_hb hsw)
      · exact (hc.atom w y hrmw hwr ⟨x, h, hxy⟩).elim

/-! ## Finite graphs: ranks and linearisations -/

open Classical in
/-- Number of elements of `l` satisfying `p`. -/
noncomputable def cnt {α : Type} (p : α → Prop) : List α → Nat
  | [] => 0
  | x :: l => (if p x then 1 else 0) + cnt p l

theorem cnt_le {α : Type} {p q : α → Prop} (h : ∀ z, p z → q z) : ∀ l : List α, cnt p l ≤ cnt q l
  | [] => by simp [cnt]
  | x :: l => by
    have := cnt_le h l
    by_cases hp : p x
    · simp [cnt, hp, h x hp]; omega
    · by_cases hq : q x <;> simp [cnt, hp, hq] <;> omega

theorem cnt_lt {α : Type} {p q : α → Prop} (h : ∀ z, p z → q z) {z0 : α} (hq : q z0)
    (hp : ¬ p z0) : ∀ l : List α, z0 ∈ l → cnt p l < cnt q l
  | [] => by simp
  | x :: l => by
    intro hm
    rcases List.mem_cons.1 hm with rfl | hm
    · have := cnt_le h l; simp [cnt, hp, hq]; omega
    · have := cnt_lt h hq hp l hm
      by_cases hpx : p x
      · simp [cnt, hpx, h x hpx]; omega
      · by_cases hqx : q x <;> simp [cnt, hpx, hqx] <;> omega

/-- The rank of `y` in `mo`: the number of its `mo`-predecessors in the list of all events. -/
noncomputable def moRank (G : Graph E L V) (evs : List E) (y : E) : Nat := cnt (fun z => G.mo z y) evs

theorem moRank_lt (hw : G.WF) {evs : List E} (hall : ∀ e, e ∈ evs) {a b : E} (h : G.mo a b) :
    moRank G evs a < moRank G evs b :=
  cnt_lt (fun z hz => hw.mo_trans z a b hz h) h (hw.mo_irrefl a) evs (hall a)

/-- A list `lin` of all events, without duplicates, in which every `R` edge points forward. -/
def IsLin {α : Type} (R : α → α → Prop) (lin : List α) : Prop :=
  (∀ e, e ∈ lin) ∧ lin.Nodup ∧
    ∀ (i j : Nat) (x y : α), lin[i]? = some x → lin[j]? = some y → R x y → i < j

theorem exists_min {α : Type} (R : α → α → Prop) (htr : ∀ a b c, R a b → R b c → R a c)
    (hir : ∀ a, ¬ R a a) : ∀ l : List α, l ≠ [] → ∃ m ∈ l, ∀ x ∈ l, ¬ R x m
  | [] => by simp
  | a :: l => by
    intro _
    by_cases hl : l = []
    · subst hl; refine ⟨a, by simp, ?_⟩; intro x hx; simp at hx; subst hx; exact hir x
    · obtain ⟨m, hm, hmin⟩ := exists_min R htr hir l hl
      by_cases ham : R a m
      · refine ⟨a, by simp, ?_⟩
        intro x hx
        rcases List.mem_cons.1 hx with rfl | hx
        · exact hir x
        · intro hxa; exact hmin x hx (htr _ _ _ hxa ham)
      · refine ⟨m, by simp [hm], ?_⟩
        intro x hx
        rcases List.mem_cons.1 hx with rfl | hx
        · exact ham
        · exact hmin x hx

open Classical in
theorem topo_sort {α : Type} (R : α → α → Prop) (htr : ∀ a b c, R a b → R b c → R a c)
    (hir : ∀ a, ¬ R a a) : ∀ n (l : List α), l.length ≤ n →
    ∃ l' : List α, (∀ x, x ∈ l' ↔ x ∈ l) ∧ l'.Pairwise (fun a b => a ≠ b ∧ ¬ R b a) := by
  intro n
  induction n with
  | zero => intro l hl; refine ⟨[], ?_, .nil⟩; intro x; simp [List.eq_nil_of_length_eq_zero (Nat.le_zero.1 hl)]
  | succ n ih =>
    intro l hl
    by_cases h0 : l = []
    · subst h0; exact ⟨[], by simp, .nil⟩
    obtain ⟨m, hm, hmin⟩ := exists_min R htr hir l h0
    let rest := l.filter (fun x => !decide (x = m))
    have hlen : rest.length < l.length := by
      have key : ∀ l : List α, m ∈ l → (l.filter (fun x => !decide (x = m))).length < l.length := by
        intro l
        induction l with
        | nil => simp
        | cons y l ih2 =>
          intro hm
          by_cases hy : y = m
          · subst hy; have := List.length_filter_le (fun x => !decide (x = y)) l; simp; omega
          · have hm' : m ∈ l := by
              rcases List.mem_cons.1 hm with h | h
              · exact absurd h.symm hy
              · exact h
            have := ih2 hm'; simp [hy]; omega
      exact key l hm
    obtain ⟨l', hmem, hp⟩ := ih rest (by omega)
    refine ⟨m :: l', ?_, ?_⟩
    · intro x
      simp only [List.mem_cons, hmem, rest, List.mem_filter]
      by_cases hx : x = m
      · subst hx; simp [hm]
      · simp [hx]
    · refine List.Pairwise.cons ?_ hp
      intro b hb
      have := (hmem b).1 hb
      simp [rest] at this
      exact ⟨fun h => this.2 h.symm, hmin b this.1⟩

/-- Every strict partial order on a finite type has a linearisation. -/
theorem exists_lin {α : Type} (R : α → α → Prop) (htr : ∀ a b c, R a b → R b c → R a c)
    (hir : ∀ a, ¬ R a a) (evs : List α) (hall : ∀ e, e ∈ evs) : ∃ lin, IsLin R lin := by
  obtain ⟨l, hmem, hp⟩ := topo_sort R htr hir evs.length evs (Nat.le_refl _)
  refine ⟨l, fun e => (hmem e).2 (hall e), hp.imp (fun h => h.1), ?_⟩
  intro i j x y hx hy hr
  obtain ⟨hi, rfl⟩ := List.getElem?_eq_some_iff.1 hx
  obtain ⟨hj, rfl⟩ := List.getElem?_eq_some_iff.1 hy
  have hpi := List.pairwise_iff_getElem.1 hp
  rcases Nat.lt_trichotomy i j with h | h | h
  · exact h
  · subst h; exact (hir _ hr).elim
  · exact ((hpi j i hj hi h).2 hr).elim

/-- `hb` of a consistent finite graph has a linearisation. -/
theorem exists_hb_lin (hc : G.Consistent) (evs : List E) (hall : ∀ e, e ∈ evs) :
    ∃ lin, IsLin G.hb lin :=
  exists_lin G.hb (fun _ _ _ => hb_trans) (hb_irrefl hc) evs hall

/-- In a linearisation of `hb`, two events of the same thread are in `po` order. -/
theorem lin_po (hw : G.WF) {lin : List E} (hl : IsLin G.hb lin) {i j : Nat} {x y : E}
    (hx : lin[i]? = some x) (hy : lin[j]? = some y) (hij : i < j) (ht : G.tid x = G.tid y) :
    G.po x y := by
  have hne : x ≠ y := by
    rintro rfl
    have : i = j := (List.Nodup.getElem?_inj (List.getElem?_eq_some_iff.1 hx).1 hl.2.1).1 (hx.trans hy.symm)
    omega
  rcases hw.po_total x y ht hne with h | h
  · exact h
  · have := hl.2.2 j i y x hy hx (po_hb h); omega

/-- In a linearisation of `hb`, two writes to a lock location are in `hb` order. -/
theorem lin_lock_hb (hc : G.Consistent) {ℓ : L} {init : E} (hll : LockLoc G ℓ init)
    (evs : List E) (hall : ∀ e, e ∈ evs) {lin : List E} (hl : IsLin G.hb lin) {i j : Nat} {x y : E}
    (hx : lin[i]? = some x) (hy : lin[j]? = some y) (hij : i < j) (hwx : G.isW x) (hwy : G.isW y)
    (hlx : G.loc x = ℓ) (hly : G.loc y = ℓ) : G.hb x y := by
  have hmo := lock_mo_hb hc hll (moRank G evs) (fun a b h _ => moRank_lt hc.toWF hall h)
  have hne : x ≠ y := by
    rintro rfl
    have : i = j := (List.Nodup.getElem?_inj (List.getElem?_eq_some_iff.1 hx).1 hl.2.1).1 (hx.trans hy.symm)
    omega
  rcases hc.mo_total x y hwx hwy (hlx.trans hly.symm) hne with h | h
  · exact hmo x y h hly
  · have := hl.2.2 j i y x hy hx (hmo y x h hlx); omega

end Graph
end RC11
