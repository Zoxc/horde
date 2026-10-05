import Collect.RC11Live

/-!
# Weak-memory liveness over RC11 execution graphs

`RC11Live.lean` proves fair liveness for the weak model `LStep`, in which the three loads of
`EVENTS` outside the `COLLECTOR` lock read some write `wₖ` with `vw t ≤ k ≤ total` and return
`k % W`. This file derives that load rule from RC11-consistent execution graphs
(`Collect/RC11.lean`): the replay of an enumeration of the graph's events is an `LExec` run
of `LStep` (`lexec`), every out-of-lock load step reads the write the graph's `rf` gives it,
with index and value as in `LStep` (`load_rule`), and `EvVis` on the graph gives `EvVis` on
the run (`evvis_run`). `lfair_stable`/`lfair` are then restated over graphs (`gfair_stable`,
`gfair`).

## Executions: one graph and an enumeration of its events

A (finite or infinite) execution is an RC11-consistent graph `G` over an event type `E` together
with an enumeration `ord : Nat → Option E` of its events (`Enum`): every event occurs exactly
once, `none` entries are padding, and every `porf = (po ∪ rf)⁺` edge points forward. Since
`hb ⊆ porf` (`hb_porf`: `sw` is made of `po` and `rf` edges), the enumeration is also a
linearisation of `hb`. Every prefix `{ord i | i < n}` is `porf`-closed (`prefix_closed`), so the
prefixes form a growing sequence of finite execution graphs, each a prefix of the next, and the
enumeration restricted to each is a linearisation of it: this is the usual presentation of an
infinite execution as the limit of its finite `(po ∪ rf)`-prefixes (it requires every event to
have finitely many `porf`-predecessors). A finite graph (a list `evs` of all its events) always
has one: `porf` is acyclic by RC11's no-thin-air axiom, and `exists_lin_porf` sorts it
topologically; `enum_of_lin` turns the list into an enumeration.

## The interface (`LGraph`), the axiomatised part

As in `RC11Pin.CExec`, every event carries a model action `act e : LAct`: one per step of the
primary model `Ev.EStep` that is not an `EVENTS` load (`pinRegister`, ..., `collectReg`,
`collectUnreg`; a critical section is collapsed into one event), the three loads outside the
lock (`check t`: `collect`'s `Acquire` load, `store t`: `collect_cold`'s `Relaxed` load,
`force t`: `pin_cold`'s `Relaxed` load), `bump` (an `EVENTS.fetch_add(1)`), or `other`.

* `EVENTS` is a location `ev`. Its writes are an initialisation write `ini` (value `0`,
  `mo`-first) and the `bump` events, which are RMWs writing `rval + 1` (mod `W`).
* **The bumps are lock-ordered** (`ev_hb`): any two writes to `ev` are `hb`-ordered. This is
  where the `COLLECTOR` lock enters: every `fetch_add` is inside a critical section, critical
  sections are totally ordered by the lock order, and the lock order is in `hb`
  (`RC11.lock_mo_hb`); the initialisation write is `hb`-before everything.
* Out-of-lock loads are reads of `ev` by their thread (`load`, `load_tid`).
* **The program** (`Valid`): along the enumeration, each event's action is enabled in the
  replayed state (as `RC11Pin.CExec.Valid`), where a load is always enabled in the states where
  `LStep` allows it and a `bump` is enabled when the replayed critical sections have charged
  more bumps than were performed (`placed < total`: the model counts a section's bumps at the
  section event, the graph's `fetch_add` events come after it). For infinite executions
  `BumpsDone` says the converse: every bump the model charges is eventually performed (a
  critical section's `fetch_add`s are executed before its unlock).

The in-lock load (`quiet` storing `EVENTS` before recursing) stays an exact step of
`EStep.collectReg`; `inlock_exact` shows why: a load that every write to its location is
`hb`-ordered with (a load inside a critical section) reads the `mo`-latest write among those
`hb`-before it.

## Results

* `idx w`: the index of a write to `ev` in `mo` (the number of bumps `mo`-before or equal to
  it), `idx_lt`: strictly monotone in `mo`, `idx_bump`: a bump's index is that of the write it
  reads plus one (atomicity), `wval_idx`: the value of write `w` is `idx w % W`.
* `load_rule`: an out-of-lock load of `t` at position `n` reads (`rf`) the write `rdW x` with
  index `k = rk x`, returns `k % W`, and `vw t ≤ k ≤ total` in the replayed state. The upper
  bound: `rf` points forward, so the write read is among the bumps performed so far, which
  are at most the bumps charged (`total`). The lower bound: `vw t` is the index of some
  earlier load of `t`, which is `po`-before (`ord_po`), so read-read coherence (`corr`) gives
  `vw t ≤ k`.
* `lexec`: the replay `run`, labelled by `lab`, is an `LExec` from `linit`; `replay_lreach`.
* `evvis_run`: `GEvVis` (for every write to `ev`, only finitely many out-of-lock loads read a
  write `mo`-before it) and `BumpsDone` give `RC11Live.EvVis` of the run.
* `gfair_stable`, `gfair`: `lfair_stable`, `lfair` for executions of `LGraph`s.
-/

namespace RC11
namespace Graph
variable {E L V : Type} {G : Graph E L V}

/-- `(po ∪ rf)⁺`. -/
def porf (G : Graph E L V) : E → E → Prop := TC (fun a b => G.po a b ∨ G.rf a b)

theorem porf_trans {a b c : E} (h1 : G.porf a b) (h2 : G.porf b c) : G.porf a c := TC.trans h1 h2

theorem porf_irrefl (hc : G.Consistent) (a : E) : ¬ G.porf a a := hc.nta a

theorem po_porf {a b : E} (h : G.po a b) : G.porf a b := .base (.inl h)
theorem rf_porf {a b : E} (h : G.rf a b) : G.porf a b := .base (.inr h)

theorem rs_porf {w x : E} (h : G.rs w x) : w = x ∨ G.porf w x := by
  induction h with
  | refl _ => exact .inl rfl
  | step _ hr _ ih =>
    rcases ih with rfl | ih
    · exact .inr (rf_porf hr)
    · exact .inr (porf_trans ih (rf_porf hr))

/-- `sw` is made of `po` and `rf` edges. -/
theorem sw_porf {a b : E} (h : G.sw a b) : G.porf a b := by
  obtain ⟨-, -, w, x, r, ha, -, hrs, hrf, -, hb⟩ := h
  have h1 : G.porf w r := by
    rcases rs_porf hrs with rfl | h
    · exact rf_porf hrf
    · exact porf_trans h (rf_porf hrf)
  have h2 : G.porf a r := by
    rcases ha with rfl | ⟨-, hp⟩
    · exact h1
    · exact porf_trans (po_porf hp) h1
  rcases hb with rfl | ⟨-, hp⟩
  · exact h2
  · exact porf_trans h2 (po_porf hp)

theorem hb_porf {a b : E} (h : G.hb a b) : G.porf a b := by
  induction h with
  | base h => rcases h with h | h
              · exact po_porf h
              · exact sw_porf h
  | trans _ _ ih1 ih2 => exact porf_trans ih1 ih2

/-- A finite consistent graph has a linearisation of `porf`. -/
theorem exists_lin_porf (hc : G.Consistent) (evs : List E) (hall : ∀ e, e ∈ evs) :
    ∃ lin, IsLin G.porf lin :=
  exists_lin G.porf (fun _ _ _ => porf_trans) (porf_irrefl hc) evs hall

/-- **In-lock loads are exact.** A read `r` such that every write to its location is
`hb`-ordered with it (a load inside a critical section, all writes being in critical sections)
reads a write `w0` that happens before it and is `mo`-latest among the writes that do. -/
theorem inlock_exact (hc : G.Consistent) {r w0 : E} (hrf : G.rf w0 r)
    (hord : ∀ w, G.isW w → G.loc w = G.loc r → G.hb w r ∨ G.hb r w) :
    G.hb w0 r ∧ ∀ w, G.isW w → G.loc w = G.loc r → G.hb w r → w = w0 ∨ G.mo w w0 := by
  obtain ⟨hw0, -, hl0, -⟩ := hc.rf_wr w0 r hrf
  have h0 : G.hb w0 r := by
    rcases hord w0 hw0 hl0 with h | h
    · exact h
    · exact ((hc.coh r w0 h).2 (.base (.inl hrf))).elim
  refine ⟨h0, fun w hw hl hh => ?_⟩
  rcases hb_read_coh hc hh hrf hw hl with h | h
  · exact .inl h.symm
  · exact .inr h

end Graph
end RC11

namespace Collect.RC11LiveGraph
open Collect Collect.Ev Collect.Fair Collect.EFair Collect.RC11Live RC11 RC11.Graph

/-! ## Enumerations -/

section Enum
open Classical
variable {E : Type}

/-- An enumeration of all events (each exactly once, `none` is padding) along which every
`R` edge points forward. -/
structure Enum (R : E → E → Prop) (ord : Nat → Option E) : Prop where
  cover : ∀ e, ∃ i, ord i = some e
  inj : ∀ i j e, ord i = some e → ord j = some e → i = j
  fwd : ∀ i j x y, ord i = some x → ord j = some y → R x y → i < j

theorem enum_of_lin {R : E → E → Prop} {lin : List E} (h : IsLin R lin) :
    Enum R (fun i => lin[i]?) :=
  ⟨fun e => List.mem_iff_getElem?.1 (h.1 e),
   fun i j e hi hj => (List.Nodup.getElem?_inj (List.getElem?_eq_some_iff.1 hi).1 h.2.1).1
     (hi.trans hj.symm),
   h.2.2⟩

/-- Prefixes of the enumeration are `R`-closed. -/
theorem prefix_closed {R : E → E → Prop} {ord : Nat → Option E} (h : Enum R ord) {a b : E}
    {i j n : Nat} (hr : R a b) (ha : ord i = some a) (hb : ord j = some b) (hj : j < n) : i < n := by
  have := h.fwd i j a b ha hb hr; omega

open Classical in
/-- Number of positions `i < n` holding an event satisfying `p`. -/
noncomputable def cntTo (ord : Nat → Option E) (p : E → Prop) : Nat → Nat
  | 0 => 0
  | n + 1 => cntTo ord p n + (match ord n with
    | some x => if p x then 1 else 0
    | none => 0)

variable {ord : Nat → Option E}

theorem cntTo_succ_some {p : E → Prop} {n : Nat} {x : E} (h : ord n = some x) :
    cntTo ord p (n + 1) = cntTo ord p n + (if p x then 1 else 0) := by
  simp [cntTo, h]

theorem cntTo_succ_none {p : E → Prop} {n : Nat} (h : ord n = none) :
    cntTo ord p (n + 1) = cntTo ord p n := by
  simp [cntTo, h]

theorem cntTo_succ_le (p : E → Prop) (n : Nat) : cntTo ord p (n + 1) ≤ cntTo ord p n + 1 := by
  cases h : ord n with
  | none => rw [cntTo_succ_none h]; omega
  | some x => rw [cntTo_succ_some h]; split <;> omega

theorem cntTo_mono (p : E → Prop) {m n : Nat} (h : m ≤ n) : cntTo ord p m ≤ cntTo ord p n := by
  induction n with
  | zero => have : m = 0 := by omega
            subst this; exact Nat.le_refl _
  | succ n ih =>
    rcases Nat.eq_or_lt_of_le h with h | h
    · subst h; exact Nat.le_refl _
    have := ih (by omega)
    cases hx : ord n with
    | none => rw [cntTo_succ_none hx]; exact this
    | some x => rw [cntTo_succ_some hx]; omega

theorem cntTo_le {p q : E → Prop} {n : Nat} (h : ∀ i x, i < n → ord i = some x → p x → q x) :
    cntTo ord p n ≤ cntTo ord q n := by
  induction n with
  | zero => exact Nat.le_refl _
  | succ n ih =>
    have := ih (fun i x hi => h i x (by omega))
    cases hx : ord n with
    | none => rw [cntTo_succ_none hx, cntTo_succ_none hx]; exact this
    | some x =>
      rw [cntTo_succ_some hx, cntTo_succ_some hx]
      by_cases hp : p x
      · simp [hp, h n x (by omega) hx hp]; omega
      · by_cases hq : q x <;> simp [hp, hq] <;> omega

theorem cntTo_lt {p q : E → Prop} {n : Nat} (h : ∀ i x, i < n → ord i = some x → p x → q x)
    {j : Nat} {z : E} (hj : j < n) (hz : ord j = some z) (hq : q z) (hp : ¬ p z) :
    cntTo ord p n < cntTo ord q n := by
  induction n with
  | zero => omega
  | succ n ih =>
    have hle := cntTo_le (ord := ord) (fun i x hi => h i x (by omega) : ∀ i x, i < n → _)
    cases hx : ord n with
    | none =>
      rw [cntTo_succ_none hx, cntTo_succ_none hx]
      rcases Nat.eq_or_lt_of_le (Nat.le_of_lt_succ hj) with e | e
      · subst e; rw [hz] at hx; cases hx
      · exact ih (fun i x hi => h i x (by omega)) e
    | some x =>
      rw [cntTo_succ_some hx, cntTo_succ_some hx]
      rcases Nat.eq_or_lt_of_le (Nat.le_of_lt_succ hj) with e | e
      · subst e; rw [hz] at hx; cases hx; simp [hp, hq]; omega
      · have := ih (fun i x hi => h i x (by omega)) e
        by_cases hpx : p x
        · simp [hpx, h n x (by omega) hx hpx]; omega
        · by_cases hqx : q x <;> simp [hpx, hqx] <;> omega

theorem cntTo_stable {p : E → Prop} {n m : Nat} (hnm : n ≤ m)
    (h : ∀ i x, n ≤ i → i < m → ord i = some x → ¬ p x) : cntTo ord p m = cntTo ord p n := by
  induction m with
  | zero => have : n = 0 := by omega
            subst this; rfl
  | succ m ih =>
    rcases Nat.eq_or_lt_of_le hnm with e | e
    · subst e; rfl
    have := ih (by omega) (fun i x h1 h2 => h i x h1 (by omega))
    cases hx : ord m with
    | none => rw [cntTo_succ_none hx]; exact this
    | some x => rw [cntTo_succ_some hx]; simp [h m x (by omega) (by omega) hx, this]

/-- Adding one element `b` (at position `j`) to a predicate adds one to the count. -/
theorem cntTo_add_one (inj : ∀ i k e, ord i = some e → ord k = some e → i = k)
    {p q : E → Prop} {b : E} {j : Nat} (hb : ord j = some b) (hqb : ¬ q b)
    (hpq : ∀ x, p x ↔ q x ∨ x = b) : ∀ n, cntTo ord p n = cntTo ord q n + (if j < n then 1 else 0) := by
  intro n
  induction n with
  | zero => simp [cntTo]
  | succ n ih =>
    cases hx : ord n with
    | none =>
      rw [cntTo_succ_none hx, cntTo_succ_none hx, ih]
      have : j ≠ n := fun e => by subst e; rw [hb] at hx; cases hx
      by_cases h1 : j < n
      · simp [h1, show j < n + 1 by omega]
      · simp [h1, show ¬ j < n + 1 by omega]
    | some x =>
      rw [cntTo_succ_some hx, cntTo_succ_some hx, ih]
      by_cases hxb : x = b
      · subst hxb
        have := inj _ _ _ hx hb; subst this
        simp [(hpq x).2 (.inr rfl), hqb]
      · have hj : j ≠ n := fun e => by subst e; rw [hb] at hx; exact hxb (Option.some.inj hx).symm
        have hpx : p x ↔ q x := by rw [hpq x]; simp [hxb]
        by_cases h1 : j < n
        · by_cases hq : q x <;> simp [h1, show j < n + 1 by omega, hpx, hq] <;> omega
        · by_cases hq : q x <;> simp [h1, show ¬ j < n + 1 by omega, hpx, hq]

end Enum


/-! ## Actions and their replay -/

/-- Model actions of events (see the module docs). -/
inductive LAct where
  | pinRegister (t : Tid)
  | pinOuter (t : Tid)
  | pinNest (t : Tid)
  | unpinNest (t : Tid)
  | unpinOuter (t : Tid)
  | release (t : Tid)
  | defer (id : Nat) (byId : Bool)
  | cancel (ids : List Nat)
  | collectReg (t : Tid)
  | collectUnreg (t : Tid)
  | runOne (t : Tid)
  | finish (t : Tid)
  /-- `collect`'s `Acquire` load of `EVENTS` -/
  | check (t : Tid)
  /-- `collect_cold`'s `Relaxed` load of `EVENTS` (stored into `seen_events`) -/
  | store (t : Tid)
  /-- `pin_cold`'s `Relaxed` load of `EVENTS` (forced store `seen_events = v - 1`) -/
  | force (t : Tid)
  /-- `EVENTS.fetch_add(1)` (inside a critical section) -/
  | bump
  | other

/-- The thread of an out-of-lock load. -/
def LAct.load : LAct → Option Tid
  | .check t | .store t | .force t => some t
  | _ => none

/-- The `LStep` label of an action whose load (if any) reads `wₖ`. -/
def LAct.label : LAct → Nat → Lbl
  | .check t, k => .call t k
  | .store t, k => .store t k
  | .force t, k => .force t k
  | _, _ => .other

variable (W : Nat)

/-- The `EStep` of a non-load action (as the constructors of `Ev.EStep`). -/
noncomputable def eapply : LAct → ESt → ESt
  | .pinRegister t, e => { e with base := register e.base t, fpend := upd e.fpend t (hasCbs e.base) }
  | .pinOuter t, e => { e with base := { e.base with
                                now := e.base.now + 1
                                loc := upd e.base.loc t (.pinned e.base.now 0) } }
  | .pinNest t, e => match e.base.loc t with
    | .pinned st d => { e with base := { e.base with loc := upd e.base.loc t (.pinned st (d + 1)) } }
    | _ => e
  | .unpinNest t, e => match e.base.loc t with
    | .pinned st (d + 1) => { e with base := { e.base with loc := upd e.base.loc t (.pinned st d) } }
    | _ => e
  | .unpinOuter t, e => match e.base.loc t with
    | .pinned _ 0 => { e with base := { e.base with loc := upd e.base.loc t .registered } }
    | _ => e
  | .release t, e => { e with
                  base := unregister { e.base with loc := upd e.base.loc t .unregistered } t
                  total := e.total + unregBump { e.base with loc := upd e.base.loc t .unregistered } t }
  | .defer id byId, e => { e with
                  base := { e.base with
                              now := e.base.now + 1
                              current := e.base.current ++ [⟨id, e.base.now, byId⟩] }
                  total := e.total + 1 }
  | .cancel ids, e => { e with base := { e.base with
                                pending := cancelList ids e.base.pending
                                current := cancelList ids e.base.current
                                previous := cancelList ids e.base.previous } }
  | .collectReg t, e => (open Classical in
        let b1 := qBump t e.base
        let r1 := (takePending (markQuiet t e.base)).1
        let e1 : ESt := { e with base := startCollect t true (quietRust t e.base),
                                 mid := upd e.mid t false }
        if qRecurses t e.base then
          { setSeen e1 t (((e.total + b1 : Nat) : Int) % W) (e.total + b1) with
              total := e.total + b1 + qBump t r1 }
        else { e1 with total := e.total + b1 })
  | .collectUnreg t, e =>
    { e with base := startCollect t false (collectUnreg e.base), mid := upd e.mid t false }
  | .runOne t, e => match e.base.loc t with
    | .collecting w (c :: cs) => { e with base := { e.base with
                                loc := upd e.base.loc t (.collecting w cs)
                                ran := e.base.ran ++ [c] } }
    | _ => e
  | .finish t, e => match e.base.loc t with
    | .collecting w [] => { e with base := { e.base with
                                loc := upd e.base.loc t (if w then .registered else .unregistered) } }
    | _ => e
  | _, e => e

/-- Replay state: the weak-model state and the number of bumps performed so far. -/
structure RSt where
  s : LSt
  placed : Nat

/-- The effect of an action whose load (if any) reads `wₖ`. -/
noncomputable def lapply (a : LAct) (k : Nat) (r : RSt) : RSt :=
  match a with
  | .check t => ⟨⟨lcheck W r.s.e t k, upd r.s.vw t k⟩, r.placed⟩
  | .store t => ⟨⟨{ setSeen r.s.e t ((k : Int) % W) k with
                      mid := upd r.s.e.mid t true, chk := upd r.s.e.chk t false }, upd r.s.vw t k⟩,
                  r.placed⟩
  | .force t => ⟨⟨{ setSeen r.s.e t (((k : Int) % W - 1) % W) ((k : Int) - 1) with
                      fpend := upd r.s.e.fpend t false }, upd r.s.vw t k⟩, r.placed⟩
  | .bump => ⟨r.s, r.placed + 1⟩
  | a => ⟨⟨eapply W a r.s.e, r.s.vw⟩, r.placed⟩

/-- When an action is allowed (the program assumption, as `RC11Pin.enabled`). -/
def enabled : LAct → RSt → Prop
  | .pinRegister t, r => r.s.e.base.loc t = .unregistered ∧ r.s.e.mid t = false ∧ r.s.e.chk t = false
  | .pinOuter t, r => r.s.e.base.loc t = .registered ∧ r.s.e.mid t = false ∧ r.s.e.chk t = false
  | .pinNest t, r => (∃ st d, r.s.e.base.loc t = .pinned st d) ∧ r.s.e.fpend t = false
  | .unpinNest t, r => (∃ st d, r.s.e.base.loc t = .pinned st (d + 1)) ∧ r.s.e.fpend t = false
  | .unpinOuter t, r => (∃ st, r.s.e.base.loc t = .pinned st 0) ∧ r.s.e.fpend t = false
  | .release t, r => r.s.e.base.loc t = .registered ∧ r.s.e.mid t = false ∧ r.s.e.chk t = false
  | .collectReg t, r => r.s.e.base.loc t = .registered ∧ r.s.e.mid t = true
  | .collectUnreg t, r => r.s.e.base.loc t = .unregistered ∧ r.s.e.mid t = true
  | .runOne t, r => ∃ w c cs, r.s.e.base.loc t = .collecting w (c :: cs)
  | .finish t, r => ∃ w, r.s.e.base.loc t = .collecting w []
  | .check t, r => (r.s.e.base.loc t = .registered ∨ r.s.e.base.loc t = .unregistered) ∧
      r.s.e.mid t = false ∧ r.s.e.chk t = false
  | .store t, r => r.s.e.chk t = true
  | .force t, r => r.s.e.fpend t = true
  | .bump, r => r.placed < r.s.e.total
  | _, _ => True

/-- An enabled action is an `LStep` (given the load bounds). -/
theorem lapply_step {a : LAct} {k : Nat} {r : RSt} (hen : enabled a r) (hi : LInv W r.s)
    (hk : ∀ t, a.load = some t → r.s.vw t ≤ k ∧ k ≤ r.s.e.total) :
    LStep W (a.label k) r.s (lapply W a k r).s := by
  obtain ⟨⟨e, vw⟩, pl⟩ := r
  cases a with
  | check t => exact ⟨hen, (hk t rfl).1, (hk t rfl).2, rfl⟩
  | store t => exact ⟨hen, (hk t rfl).1, (hk t rfl).2, rfl⟩
  | force t => exact ⟨hen, (hk t rfl).1, (hk t rfl).2, rfl⟩
  | bump => exact ⟨.inr rfl, rfl⟩
  | other => exact ⟨.inr rfl, rfl⟩
  | pinRegister t =>
    obtain ⟨hl, hm, hc⟩ := hen
    refine ⟨.inl ⟨EStep.pinRegister e t hl hm hc, fun u => ⟨rfl, fun h => ?_⟩⟩, rfl⟩
    by_cases hu : u = t
    · subst hu; rw [fp_notReg hi.news (.inr (.inl hl))] at h; cases h
    · show upd e.fpend t _ u = true; rw [upd_other _ _ _ _ hu]; exact h
  | pinOuter t =>
    obtain ⟨hl, hm, hc⟩ := hen
    exact ⟨.inl ⟨EStep.pinOuter e t hl hm hc, noLoad_of rfl rfl⟩, rfl⟩
  | pinNest t =>
    obtain ⟨⟨st, d, hl⟩, hf⟩ := hen
    have h : (lapply W (.pinNest t) k ⟨⟨e, vw⟩, pl⟩).s.e =
        { e with base := { e.base with loc := upd e.base.loc t (.pinned st (d + 1)) } } := by
      dsimp only at hl; simp only [lapply, eapply, hl]
    refine ⟨.inl ?_, rfl⟩
    rw [h]; exact ⟨EStep.pinNest e t st d hl hf, noLoad_of rfl rfl⟩
  | unpinNest t =>
    obtain ⟨⟨st, d, hl⟩, hf⟩ := hen
    have h : (lapply W (.unpinNest t) k ⟨⟨e, vw⟩, pl⟩).s.e =
        { e with base := { e.base with loc := upd e.base.loc t (.pinned st d) } } := by
      dsimp only at hl; simp only [lapply, eapply, hl]
    refine ⟨.inl ?_, rfl⟩
    rw [h]; exact ⟨EStep.unpinNest e t st d hl hf, noLoad_of rfl rfl⟩
  | unpinOuter t =>
    obtain ⟨⟨st, hl⟩, hf⟩ := hen
    have h : (lapply W (.unpinOuter t) k ⟨⟨e, vw⟩, pl⟩).s.e =
        { e with base := { e.base with loc := upd e.base.loc t .registered } } := by
      dsimp only at hl; simp only [lapply, eapply, hl]
    refine ⟨.inl ?_, rfl⟩
    rw [h]; exact ⟨EStep.unpinOuter e t st hl hf, noLoad_of rfl rfl⟩
  | release t =>
    obtain ⟨hl, hm, hc⟩ := hen
    exact ⟨.inl ⟨EStep.release e t hl hm hc, noLoad_of rfl rfl⟩, rfl⟩
  | defer id byId => exact ⟨.inl ⟨EStep.defer e id byId, noLoad_of rfl rfl⟩, rfl⟩
  | cancel ids => exact ⟨.inl ⟨EStep.cancel e ids, noLoad_of rfl rfl⟩, rfl⟩
  | collectReg t =>
    obtain ⟨hl, hm⟩ := hen
    refine ⟨.inl ⟨EStep.collectReg e t hl hm, fun u => ?_⟩, rfl⟩
    show (eapply W _ e).chk u = _ ∧ (_ → (eapply W _ e).fpend u = true)
    constructor <;> (simp only [eapply]; split <;> simp [setSeen])
  | collectUnreg t =>
    obtain ⟨hl, hm⟩ := hen
    exact ⟨.inl ⟨EStep.collectUnreg e t hl hm, noLoad_of rfl rfl⟩, rfl⟩
  | runOne t =>
    obtain ⟨w, c, cs, hl⟩ := hen
    have h : (lapply W (.runOne t) k ⟨⟨e, vw⟩, pl⟩).s.e = { e with base := { e.base with
        loc := upd e.base.loc t (.collecting w cs), ran := e.base.ran ++ [c] } } := by
      dsimp only at hl; simp only [lapply, eapply, hl]
    refine ⟨.inl ?_, rfl⟩
    rw [h]; exact ⟨EStep.runOne e t w c cs hl, noLoad_of rfl rfl⟩
  | finish t =>
    obtain ⟨w, hl⟩ := hen
    have h : (lapply W (.finish t) k ⟨⟨e, vw⟩, pl⟩).s.e = { e with base := { e.base with
        loc := upd e.base.loc t (if w then .registered else .unregistered) } } := by
      dsimp only at hl; simp only [lapply, eapply, hl]
    refine ⟨.inl ?_, rfl⟩
    rw [h]; exact ⟨EStep.finish e t w hl, noLoad_of rfl rfl⟩

theorem lapply_placed (a : LAct) (k : Nat) (r : RSt) :
    (lapply W a k r).placed = r.placed + (match a with | .bump => 1 | _ => 0) := by
  cases a <;> rfl

theorem lapply_vw (a : LAct) (k : Nat) (r : RSt) (u : Tid) :
    (lapply W a k r).s.vw u = if a.load = some u then k else r.s.vw u := by
  cases a with
  | check t | store t | force t =>
    by_cases h : u = t
    · subst h; simp [lapply, LAct.load]
    · simp [lapply, LAct.load, upd_other _ _ _ _ h, Ne.symm h]
  | _ => simp [lapply, LAct.load]

theorem lapply_bump_s (k : Nat) (r : RSt) : (lapply W .bump k r).s = r.s := rfl

/-! ## The interface -/

/-- An RC11-consistent execution graph of a program using `collect`, for the liveness argument
(module docs). Values are integers. -/
structure LGraph (E L : Type) where
  G : Graph E L Int
  cons : G.Consistent
  act : E → LAct
  /-- the location `EVENTS` and its initialisation write -/
  ev : L
  ini : E
  ini_w : G.isW ini ∧ G.loc ini = ev ∧ (G.lab ini).wval = 0 ∧ act ini ≠ .bump
  ini_first : ∀ e, e ≠ ini → G.isW e → G.loc e = ev → G.mo ini e
  /-- the writes to `EVENTS` are the initialisation write and the bumps -/
  ev_w : ∀ e, G.isW e → G.loc e = ev → e = ini ∨ act e = .bump
  /-- a bump is a `fetch_add(1)` (wrapping at `W`) -/
  bump_w : ∀ e, act e = .bump →
    G.isRMW e ∧ G.loc e = ev ∧ (G.lab e).wval = ((G.lab e).rval + 1) % (W : Int)
  /-- the writes to `EVENTS` are lock-ordered, hence `hb`-ordered -/
  ev_hb : ∀ a b, G.isW a → G.isW b → G.loc a = ev → G.loc b = ev → a ≠ b → G.hb a b ∨ G.hb b a
  /-- an out-of-lock load of `t` is a read of `EVENTS` by `t` -/
  load : ∀ e t, (act e).load = some t → G.isR e ∧ G.loc e = ev ∧ G.tid e = t

namespace LGraph
variable {W} {E L : Type} (X : LGraph W E L) (ord : Nat → Option E)

/-- A write to `EVENTS`. -/
def evW (w : E) : Prop := X.G.isW w ∧ X.G.loc w = X.ev

open Classical in
/-- Position of an event in the enumeration. -/
noncomputable def pos (w : E) : Nat := if h : ∃ i, ord i = some w then Classical.choose h else 0

/-- Bumps `mo`-before or equal to `w`. -/
def P (w z : E) : Prop := X.act z = .bump ∧ (z = w ∨ X.G.mo z w)

/-- **The index of a write to `EVENTS` in `mo`**: the number of bumps `mo`-before or equal to
it (`0` for the initialisation write). -/
noncomputable def idx (w : E) : Nat := cntTo ord (X.P w) (pos ord w + 1)

open Classical in
/-- The write a read reads from. -/
noncomputable def rdW (x : E) : E := if h : ∃ w, X.G.rf w x then Classical.choose h else x

/-- The index of the write a load reads. -/
noncomputable def rk (x : E) : Nat := X.idx ord (X.rdW x)

/-- The replay of the first `n` events. -/
noncomputable def replay : Nat → RSt
  | 0 => ⟨linit, 0⟩
  | n + 1 => match ord n with
    | none => replay n
    | some x => lapply W (X.act x) (X.rk ord x) (replay n)

/-- The program assumption along the enumeration. -/
def Valid : Prop := ∀ i x, ord i = some x → enabled (X.act x) (X.replay ord i)

/-- The replayed run and its labels. -/
noncomputable def run (n : Nat) : LSt := (X.replay ord n).s

noncomputable def lab (n : Nat) : Lbl := match ord n with
  | none => .other
  | some x => (X.act x).label (X.rk ord x)

theorem replay_none {n : Nat} (h : ord n = none) : X.replay ord (n + 1) = X.replay ord n := by
  simp [replay, h]

theorem replay_some {n : Nat} {x : E} (h : ord n = some x) :
    X.replay ord (n + 1) = lapply W (X.act x) (X.rk ord x) (X.replay ord n) := by
  simp [replay, h]

theorem rdW_rf {x : E} (h : X.G.isR x) : X.G.rf (X.rdW x) x := by
  have hx : ∃ w, X.G.rf w x := X.cons.rf_total x h
  simp only [rdW, hx, dite_true]; exact Classical.choose_spec hx

variable {X ord}

/-! ## Positions -/

theorem pos_spec (hE : Enum X.G.porf ord) (w : E) : ord (pos ord w) = some w := by
  have hx : ∃ i, ord i = some w := hE.cover w
  simp only [pos, hx, dite_true]; exact Classical.choose_spec hx

theorem pos_eq (hE : Enum X.G.porf ord) {i : Nat} {w : E} (h : ord i = some w) : pos ord w = i :=
  hE.inj _ _ _ (pos_spec hE w) h

theorem porf_pos (hE : Enum X.G.porf ord) {a b : E} (h : X.G.porf a b) : pos ord a < pos ord b :=
  hE.fwd _ _ _ _ (pos_spec hE a) (pos_spec hE b) h

/-- Same-thread events are in `po` order along the enumeration. -/
theorem ord_po (hE : Enum X.G.porf ord) {i j : Nat} {x y : E} (hx : ord i = some x)
    (hy : ord j = some y) (hij : i < j) (ht : X.G.tid x = X.G.tid y) : X.G.po x y := by
  have hne : x ≠ y := by
    rintro rfl; have := hE.inj _ _ _ hx hy; omega
  rcases X.cons.po_total x y ht hne with h | h
  · exact h
  · have := hE.fwd _ _ _ _ hy hx (po_porf h); omega

/-! ## `mo` on `EVENTS` and the index -/

theorem evW_of_mo {a b : E} (hb : X.evW b) (h : X.G.mo a b) : X.evW a := by
  obtain ⟨ha, -, hl⟩ := X.cons.mo_w a b h; exact ⟨ha, hl.trans hb.2⟩

theorem evW_bump {b : E} (h : X.act b = .bump) : X.evW b := by
  obtain ⟨hr, hl, -⟩ := X.bump_w b h
  exact ⟨by simp [Graph.isW, Graph.isRMW] at hr ⊢; simp [hr, Kind.isW], hl⟩

theorem evW_rd {x : E} {t : Tid} (h : (X.act x).load = some t) :
    X.G.rf (X.rdW x) x ∧ X.evW (X.rdW x) := by
  obtain ⟨hr, hl, -⟩ := X.load x t h
  have hrf := X.rdW_rf hr
  obtain ⟨hw, -, hl', -⟩ := X.cons.rf_wr _ _ hrf
  exact ⟨hrf, hw, hl'.trans hl⟩

/-- On `EVENTS`, `mo` is in `hb` (the bumps are lock-ordered). -/
theorem mo_hb {a b : E} (ha : X.evW a) (hb : X.evW b) (h : X.G.mo a b) : X.G.hb a b := by
  rcases X.ev_hb a b ha.1 hb.1 ha.2 hb.2 (fun e => by subst e; exact X.cons.mo_irrefl a h) with h' | h'
  · exact h'
  · exact ((X.cons.coh b a h').2 (.base (.inr (.inl h)))).elim

theorem mo_pos (hE : Enum X.G.porf ord) {a b : E} (hb : X.evW b) (h : X.G.mo a b) :
    pos ord a < pos ord b :=
  porf_pos hE (hb_porf (mo_hb (evW_of_mo hb h) hb h))

theorem mo_total_ev {a b : E} (ha : X.evW a) (hb : X.evW b) (hne : a ≠ b) :
    X.G.mo a b ∨ X.G.mo b a :=
  X.cons.mo_total a b ha.1 hb.1 (ha.2.trans hb.2.symm) hne

theorem not_mo_ini {a : E} (ha : X.evW a) : ¬ X.G.mo a X.ini := by
  intro h
  have hne : a ≠ X.ini := fun e => by subst e; exact X.cons.mo_irrefl _ h
  exact X.cons.mo_irrefl _ (X.cons.mo_trans _ _ _ h (X.ini_first a hne ha.1 ha.2))

/-- The index can be counted up to any bound past the write's position. -/
theorem idx_eq (hE : Enum X.G.porf ord) {w : E} (hw : X.evW w) {N : Nat} (hN : pos ord w < N) :
    X.idx ord w = cntTo ord (X.P w) N := by
  unfold idx
  refine (cntTo_stable hN fun i z hi _ hz hp => ?_).symm
  have hzi := pos_eq hE hz
  rcases hp.2 with rfl | hm
  · omega
  · have := mo_pos hE hw hm; omega

theorem idx_le_bumps (w : E) : X.idx ord w ≤ cntTo ord (fun z => X.act z = .bump) (pos ord w + 1) :=
  cntTo_le fun _ _ _ _ hp => hp.1

/-- The index is strictly monotone in `mo`. -/
theorem idx_lt (hE : Enum X.G.porf ord) {a b : E} (hb : X.evW b) (h : X.G.mo a b) :
    X.idx ord a < X.idx ord b := by
  have ha := evW_of_mo hb h
  have hp := mo_pos hE hb h
  rw [idx_eq hE ha (show pos ord a < pos ord b + 1 by omega), idx_eq hE hb (Nat.lt_succ_self _)]
  have hbb : X.act b = .bump := by
    rcases X.ev_w b hb.1 hb.2 with e | e
    · subst e; exact (not_mo_ini ha h).elim
    · exact e
  refine cntTo_lt (fun i z _ _ hz => ⟨hz.1, ?_⟩) (Nat.lt_succ_self _) (pos_spec hE b) ⟨hbb, .inl rfl⟩ ?_
  · rcases hz.2 with rfl | hz
    · exact .inr h
    · exact .inr (X.cons.mo_trans _ _ _ hz h)
  · rintro ⟨-, e | e⟩
    · subst e; exact X.cons.mo_irrefl _ h
    · exact X.cons.mo_irrefl _ (X.cons.mo_trans _ _ _ h e)

theorem idx_le (hE : Enum X.G.porf ord) {a b : E} (ha : X.evW a) (hb : X.evW b)
    (h : ¬ X.G.mo b a) : X.idx ord a ≤ X.idx ord b := by
  by_cases e : a = b
  · subst e; exact Nat.le_refl _
  · rcases mo_total_ev ha hb e with h' | h'
    · exact Nat.le_of_lt (idx_lt hE hb h')
    · exact (h h').elim

theorem idx_ini (hE : Enum X.G.porf ord) : X.idx ord X.ini = 0 := by
  unfold idx
  refine cntTo_stable (Nat.zero_le _) fun i z _ _ hz hp => ?_
  rcases hp.2 with rfl | hm
  · exact X.ini_w.2.2.2 hp.1
  · exact not_mo_ini (evW_bump hp.1) hm

/-- **Atomicity**: a bump's index is that of the write it reads plus one. -/
theorem idx_bump (hE : Enum X.G.porf ord) {b w : E} (hb : X.act b = .bump) (hrf : X.G.rf w b) :
    X.idx ord b = X.idx ord w + 1 ∧ X.G.mo w b := by
  have heb := evW_bump hb
  obtain ⟨hww, -, hl, -⟩ := X.cons.rf_wr w b hrf
  have hew : X.evW w := ⟨hww, hl.trans heb.2⟩
  have hne : w ≠ b := rf_ne X.cons hrf
  have hmo : X.G.mo w b := by
    rcases mo_total_ev hew heb hne with h | h
    · exact h
    · exact ((X.cons.coh b w (mo_hb heb hew h)).2 (.base (.inl hrf))).elim
  have hatom := X.cons.atom w b (X.bump_w b hb).1 hrf
  refine ⟨?_, hmo⟩
  have hp := mo_pos hE heb hmo
  rw [idx_eq hE heb (Nat.lt_succ_self _), idx_eq hE hew (show pos ord w < pos ord b + 1 by omega)]
  have key : ∀ z, X.P b z ↔ X.P w z ∨ z = b := by
    intro z; constructor
    · rintro ⟨hz, e | hm⟩
      · exact .inr e
      · by_cases hzw : z = w
        · exact .inl ⟨hz, .inl hzw⟩
        · rcases mo_total_ev (evW_bump hz) hew hzw with h | h
          · exact .inl ⟨hz, .inr h⟩
          · exact (hatom ⟨z, h, hm⟩).elim
    · rintro (⟨hz, e | hm⟩ | e)
      · subst e; exact ⟨hz, .inr hmo⟩
      · exact ⟨hz, .inr (X.cons.mo_trans _ _ _ hm hmo)⟩
      · subst e; exact ⟨hb, .inl rfl⟩
  have hnot : ¬ X.P w b := by
    rintro ⟨-, e | e⟩
    · exact hne e.symm
    · exact X.cons.mo_irrefl _ (X.cons.mo_trans _ _ _ e hmo)
  rw [cntTo_add_one hE.inj (pos_spec hE b) hnot key]
  simp

/-- **Values**: the write with index `k` writes `k % W`. -/
theorem wval_idx (hE : Enum X.G.porf ord) {w : E} (hw : X.evW w) :
    (X.G.lab w).wval = (X.idx ord w : Int) % W := by
  suffices ∀ n w, pos ord w < n → X.evW w → (X.G.lab w).wval = (X.idx ord w : Int) % W from
    this _ w (Nat.lt_succ_self _) hw
  intro n
  induction n with
  | zero => intro w h; omega
  | succ n ih =>
    intro w hn hw
    rcases X.ev_w w hw.1 hw.2 with rfl | hb
    · rw [idx_ini hE, X.ini_w.2.2.1]; simp
    · obtain ⟨hr, -, hv⟩ := X.bump_w w hb
      have hR : X.G.isR w := by simp [Graph.isR, Graph.isRMW] at hr ⊢; simp [hr, Kind.isR]
      have hrf := X.rdW_rf hR
      obtain ⟨hi, hmo⟩ := idx_bump hE hb hrf
      have hlt := mo_pos hE hw hmo
      have := ih _ (by omega) (evW_of_mo hw hmo)
      obtain ⟨-, -, -, hval⟩ := X.cons.rf_wr _ _ hrf
      rw [hv, ← hval, this, hi]; push_cast; simp

/-! ## The replay is a run of `LStep` -/

/-- Invariant of the replay. -/
structure RInv (n : Nat) : Prop where
  reach : LReach W (X.replay ord n).s
  placed : (X.replay ord n).placed = cntTo ord (fun z => X.act z = .bump) n
  le : (X.replay ord n).placed ≤ (X.replay ord n).s.e.total
  /-- `vw t` is the index read by some earlier load of `t` -/
  view : ∀ t, (X.replay ord n).s.vw t = 0 ∨ ∃ j y, j < n ∧ ord j = some y ∧
    (X.act y).load = some t ∧ (X.replay ord n).s.vw t = X.rk ord y

theorem rinv_zero : RInv (X := X) (ord := ord) 0 :=
  ⟨.init, rfl, Nat.zero_le _, fun _ => .inl rfl⟩

/-- **The load rule.** An out-of-lock load `x` of `t` at position `n` reads (`rf`) the write
`rdW x`, whose index `k = rk x` satisfies `vw t ≤ k ≤ total` in the replayed state, and returns
`k % W`. -/
theorem load_bounds (hE : Enum X.G.porf ord) {n : Nat} (hI : RInv (X := X) (ord := ord) n)
    {x : E} {t : Tid} (hx : ord n = some x) (hl : (X.act x).load = some t) :
    X.G.rf (X.rdW x) x ∧ (X.G.lab x).rval = (X.rk ord x : Int) % W ∧
      (X.replay ord n).s.vw t ≤ X.rk ord x ∧ X.rk ord x ≤ (X.replay ord n).s.e.total := by
  obtain ⟨hrf, hew⟩ := evW_rd hl
  have hpn := pos_eq hE hx
  refine ⟨hrf, ?_, ?_, ?_⟩
  · obtain ⟨-, -, -, hval⟩ := X.cons.rf_wr _ _ hrf
    rw [← hval]; exact wval_idx hE hew
  · rcases hI.view t with h | ⟨j, y, hj, hy, hly, h⟩
    · rw [h]; exact Nat.zero_le _
    · rw [h]
      obtain ⟨hrf', hew'⟩ := evW_rd hly
      have hpo := ord_po hE hy hx hj ((X.load y t hly).2.2.trans (X.load x t hl).2.2.symm)
      exact idx_le hE hew' hew (corr X.cons hpo hrf' hrf)
  · have h1 := porf_pos hE (rf_porf hrf)
    rw [hpn] at h1
    have h2 := idx_le_bumps (X := X) (ord := ord) (X.rdW x)
    have h3 := cntTo_mono (ord := ord) (fun z => X.act z = .bump) (show pos ord (X.rdW x) + 1 ≤ n by omega)
    have := hI.le; rw [hI.placed] at this
    unfold rk; omega

theorem replay_step (hE : Enum X.G.porf ord) (hv : X.Valid ord) {n : Nat}
    (hI : RInv (X := X) (ord := ord) n) :
    LStep W (X.lab ord n) (X.run ord n) (X.run ord (n + 1)) ∧ RInv (X := X) (ord := ord) (n + 1) := by
  cases hx : ord n with
  | none =>
    have hr := X.replay_none ord hx
    have hs : LStep W (X.lab ord n) (X.run ord n) (X.run ord (n + 1)) := by
      simp only [lab, run, hx, hr]; exact ⟨.inr rfl, rfl⟩
    refine ⟨hs, ?_, ?_, ?_, fun t => ?_⟩
    · rw [hr]; exact hI.reach
    · rw [hr, cntTo_succ_none hx]; exact hI.placed
    · rw [hr]; exact hI.le
    · rw [hr]; rcases hI.view t with h | ⟨j, y, hj, h⟩
      · exact .inl h
      · exact .inr ⟨j, y, by omega, h⟩
  | some x =>
    have hr := X.replay_some ord hx
    have hk : ∀ t, (X.act x).load = some t →
        (X.replay ord n).s.vw t ≤ X.rk ord x ∧ X.rk ord x ≤ (X.replay ord n).s.e.total :=
      fun t hl => (load_bounds hE hI hx hl).2.2
    have hs0 := lapply_step W (hv n x hx) (lreach_inv W hI.reach) hk
    have hs : LStep W (X.lab ord n) (X.run ord n) (X.run ord (n + 1)) := by
      simp only [lab, run, hx, hr]; exact hs0
    refine ⟨hs, ⟨?_, ?_, ?_, fun t => ?_⟩⟩
    · rw [hr]; exact .step _ hI.reach hs0
    · rw [hr, lapply_placed, cntTo_succ_some hx, hI.placed]
      generalize X.act x = a
      cases a <;> simp
    · rw [hr]
      have ht := lstep_total W hs0
      have hle := hI.le
      have hp := lapply_placed W (X.act x) (X.rk ord x) (X.replay ord n)
      have hen := hv n x hx
      generalize X.act x = a at hp ht hen
      by_cases hb : a = .bump
      · subst hb; show (X.replay ord n).placed + 1 ≤ (X.replay ord n).s.e.total
        simp only [enabled] at hen; omega
      · have : (match a with | .bump => 1 | _ => 0) = 0 := by cases a <;> simp_all
        rw [hp, this]; omega
    · rw [hr, lapply_vw]
      by_cases hl : (X.act x).load = some t
      · simp only [hl, ↓reduceIte]; exact .inr ⟨n, x, by omega, hx, hl, rfl⟩
      · simp only [hl, ↓reduceIte]
        rcases hI.view t with h | ⟨j, y, hj, h⟩
        · exact .inl h
        · exact .inr ⟨j, y, by omega, h⟩

theorem replay_inv (hE : Enum X.G.porf ord) (hv : X.Valid ord) :
    ∀ n, RInv (X := X) (ord := ord) n
  | 0 => rinv_zero
  | n + 1 => (replay_step hE hv (replay_inv hE hv n)).2

/-- **The replay is a run of the weak model**, from its initial state. -/
theorem lexec (hE : Enum X.G.porf ord) (hv : X.Valid ord) : LExec W (X.run ord) (X.lab ord) :=
  fun n => (replay_step hE hv (replay_inv hE hv n)).1

theorem run_zero : X.run ord 0 = linit := rfl

theorem replay_lreach (hE : Enum X.G.porf ord) (hv : X.Valid ord) (n : Nat) :
    LReach W (X.run ord n) :=
  (replay_inv hE hv n).reach

/-- **The load rule along the replay**: an out-of-lock load `x` of `t` at position `n` reads
the write `rdW x` (`rf`), which has index `k = rk x` with `vw t ≤ k ≤ total`, returns `k % W`,
and is the run's step `n`, labelled by `k`. -/
theorem load_rule (hE : Enum X.G.porf ord) (hv : X.Valid ord) {n : Nat} {x : E} {t : Tid}
    (hx : ord n = some x) (hl : (X.act x).load = some t) :
    X.G.rf (X.rdW x) x ∧ (X.G.lab x).rval = (X.rk ord x : Int) % W ∧
      (X.run ord n).vw t ≤ X.rk ord x ∧ X.rk ord x ≤ (X.run ord n).e.total ∧
      X.lab ord n = (X.act x).label (X.rk ord x) :=
  ⟨(load_bounds hE (replay_inv hE hv n) hx hl).1, (load_bounds hE (replay_inv hE hv n) hx hl).2.1,
   (load_bounds hE (replay_inv hE hv n) hx hl).2.2.1, (load_bounds hE (replay_inv hE hv n) hx hl).2.2.2,
   by simp [lab, hx]⟩

/-! ## Eventual visibility -/

variable (X ord) in
/-- **Eventual visibility on the graph**: for every write `w` to `EVENTS`, only finitely many
out-of-lock loads (those at positions below some `N`) read a write `mo`-before it. -/
def GEvVis : Prop :=
  ∀ w, X.evW w → ∃ N, ∀ i x t, N ≤ i → ord i = some x → (X.act x).load = some t →
    ¬ X.G.mo (X.rdW x) w

variable (X ord) in
/-- Every bump the model charges (at a critical-section event) is eventually performed. -/
def BumpsDone : Prop := ∀ n, ∃ m, (X.run ord n).e.total ≤ (X.replay ord m).placed

theorem lab_load {m : Nat} {t : Tid} {k : Nat} (h : LoadAt (X.lab ord) m t k) :
    ∃ x, ord m = some x ∧ (X.act x).load = some t ∧ k = X.rk ord x := by
  unfold lab at h
  cases hx : ord m with
  | none => simp [hx, LoadAt] at h
  | some x =>
    simp only [hx, LoadAt] at h
    refine ⟨x, rfl, ?_⟩
    cases ha : X.act x <;> simp [ha, LAct.label, LAct.load] at h ⊢ <;> exact ⟨h.1, h.2.symm⟩

theorem last_bump (hE : Enum X.G.porf ord) : ∀ m,
    cntTo ord (fun z => X.act z = .bump) m = 0 ∨
      ∃ b, X.act b = .bump ∧ cntTo ord (fun z => X.act z = .bump) m ≤ X.idx ord b
  | 0 => .inl rfl
  | m + 1 => by
    cases hx : ord m with
    | none => rw [cntTo_succ_none hx]; exact last_bump hE m
    | some x =>
      by_cases hb : X.act x = .bump
      · refine .inr ⟨x, hb, ?_⟩
        have hpx := pos_eq hE hx
        rw [idx_eq hE (evW_bump hb) (show pos ord x < m + 1 by omega)]
        refine cntTo_le fun i z hi hz hzb => ⟨hzb, ?_⟩
        by_cases e : z = x
        · exact .inl e
        · rcases mo_total_ev (evW_bump hzb) (evW_bump hb) e with h | h
          · exact .inr h
          · have := mo_pos hE (evW_bump hzb) h; rw [pos_eq hE hz] at this; omega
      · rw [cntTo_succ_some hx]; simp only [hb, ↓reduceIte, Nat.add_zero]; exact last_bump hE m

/-- **`EvVis` on the graph gives `EvVis` on the run.** -/
theorem evvis_run (hE : Enum X.G.porf ord) (hv : X.Valid ord) (hbd : X.BumpsDone ord)
    (hvis : X.GEvVis ord) : EvVis (X.run ord) (X.lab ord) := by
  intro j ⟨n, hn⟩
  obtain ⟨m, hm⟩ := hbd n
  rw [(replay_inv hE hv m).placed] at hm
  rcases last_bump hE m with h | ⟨b, hb, hle⟩
  · exact ⟨0, fun _ _ _ _ _ => by omega⟩
  · obtain ⟨N, hN⟩ := hvis b (evW_bump hb)
    refine ⟨N, fun i t k hi hl => ?_⟩
    obtain ⟨x, hx, hlx, rfl⟩ := lab_load hl
    have := idx_le hE (evW_bump hb) (evW_rd hlx).2 (hN i x t hi hx hlx)
    unfold rk; omega

/-! ## Fair liveness over graphs -/

/-- **Fair liveness under weak memory over RC11 graphs, stable registration.** For an execution
(an `LGraph` with an enumeration `ord`) valid for the program, whose charged bumps are all
performed, with eventual visibility on the graph (`GEvVis`), and with the fairness and no-wrap
hypotheses of `lfair_stable` on its replay: a closure queued after `N0` eventually runs. -/
theorem gfair_stable (hE : Enum X.G.porf ord) (hv : X.Valid ord) (hbd : X.BumpsDone ord)
    (hvis : X.GEvVis ord) (N0 : Nat) (hst : StableFrom (proj (X.run ord)) N0)
    (hne : ∃ t, ((X.run ord N0).e.base.threads t).isSome) (hf : LFairFrom (X.run ord) (X.lab ord) N0)
    (hnw : NoWrapL W (X.run ord) (X.lab ord))
    (c : Cb) (hid : c.byId = false) (n0 : Nat) (hn0 : N0 ≤ n0) (hc : c ∈ bufs (X.run ord n0).e.base) :
    ∃ m, c ∈ (X.run ord m).e.base.ran :=
  lfair_stable W _ _ (lexec hE hv) .init N0 hst hne hf (evvis_run hE hv hbd hvis) hnw c hid n0 hn0 hc

/-- **Fair liveness under weak memory over RC11 graphs, threads may release and
re-register** (`lfair` for the replay of an execution). -/
theorem gfair (hE : Enum X.G.porf ord) (hv : X.Valid ord) (hbd : X.BumpsDone ord)
    (hvis : X.GEvVis ord) (hf : LFairAll (X.run ord) (X.lab ord)) (hnw : NoWrapL W (X.run ord) (X.lab ord))
    (c : Cb) (hid : c.byId = false) (n0 : Nat) (hc : c ∈ bufs (X.run ord n0).e.base) :
    ∃ m, c ∈ (X.run ord m).e.base.ran :=
  lfair W _ _ (lexec hE hv) .init hf (evvis_run hE hv hbd hvis) hnw c hid n0 hc

/-! ## Finite graphs -/

/-- A finite execution graph (all events in `evs`) has an enumeration; under the
enumeration-independent program assumption, a valid one (whose replay is then an `LStep` run
satisfying the load rule: `lexec`, `load_rule`). -/
theorem finite_valid (evs : List E) (hall : ∀ e, e ∈ evs)
    (hprog : ∀ lin, IsLin X.G.porf lin → X.Valid (fun i => lin[i]?)) :
    ∃ lin : List E, Enum X.G.porf (fun i => lin[i]?) ∧ X.Valid (fun i => lin[i]?) := by
  obtain ⟨lin, hl⟩ := exists_lin_porf X.cons evs hall
  exact ⟨lin, enum_of_lin hl, hprog lin hl⟩

end LGraph

end Collect.RC11LiveGraph
