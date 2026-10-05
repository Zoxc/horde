import SyncTable.Ordered
import Collect

/-!
# `SyncTable` composed with the `collect` primary model

`Model.lean` abstracts `collect`: `Step.markFree` (the `can_free` store) carries the premise
"no reader is pinned with a start time `≤` the defer time". This file removes that assumption by
running the ordered `SyncTable` model (`OStep`, `Ordered.lean`) and the primary `collect` model
(`Collect.Ev.EStep`, `lean/collect`) side by side:

* reader `u` of the table is `collect` thread `u` (`Tid = Nat`);
* `pin`/`unpin` of a reader is a joint step: the table's `Step.pin`/`Step.unpin` together with the
  `collect` step that enters/leaves the outermost pinned region of thread `u`
  (`EStep.pinRegister`/`pinOuter`, `EStep.unpinOuter`);
* `replace_table` (`Step.expand`/`Step.replace`/`Step.replaceEmpty`, `OStep.swap`) of a table
  other than the static empty one is a joint step with `EStep.defer e cur true`:
  `collect::defer_by_id(&table.info().can_free)` with the table id as the flag's pointer
  identity. `replace_table` of the static table (id `0`) returns before the `defer_by_id`, so it
  is a table-only step (`CStep.tbl` with an `OStep.other`);
* each table's `can_free: AtomicBool` is a cell `CSt.cell t`: `false` when the table is
  allocated (every id `≥ nextId` has a `false` cell, `VI.fresh`), set `true` only by `collect`
  steps, through every pointer `mark_ready` stores to (`storeCells`, from
  `Collect.Flags.stores`). The static table's cell stays `false` (`VI.stat`,
  `static_can_free_false`): it is never registered, so `collect` never stores to it;
* `prune_tables`' `can_free.load(Acquire)` is `CStep.markFree`: enabled when the cell holds
  `true`; it records the observation in the table's `canFree` for the following pop
  (`OStep.pruneHead`). The invariant `VI` shows the cell of a retired table is `true` exactly when
  its flag callback `⟨t, time, true⟩` is in `collect`'s ghost `ran` (`VI.val`), so the table's
  `markFree` premise is *proved* from `Collect.Main.safety` (`markFree_premise`, `can_free_safe`);
* every other `collect` step (any thread: `collect`, `release`, a plain `defer` by other code, the
  callback loop, ...) runs alone (`CStep.col`), provided it does not move a thread that is inside
  a table read, does not drop a queued `defer_by_id` flag (only `cancel_by_ids` can, and
  `SyncTable` calls it only from `drop_impl`, `DStep.cancel` of `Drop.lean`), and registers no
  `defer_by_id` flag (`KeepFlags`: the table is the only `defer_by_id` client of the run);
* every other table step (writer `insert`/`insertAny`/`remove`, `replace_table` of the static
  table, `prune_tables`, reader probes) runs alone (`CStep.tbl`).

The two models use different logical clocks (`St.clk` counts only table pins and retirements,
`St.now` counts all `collect` pins and defers). The ghost `f` maps table times to `collect`
times and is strictly monotone (`J.mono`), so comparisons agree.

Main results:
* `creach_ereach`, `creach_oreach`: every composed run projects to a run of the `collect`
  primary model and to a run of the ordered table model (`cstep_e`, `cstep_o`).
* `markFree_premise`: the former `collect` axiom, proved; `can_free_safe`: a retired table's
  cell read `true` ⇒ `collect` stored its flag ⇒ no reader pinned at or before the defer.
* `creach_vi`: the `can_free` cell invariant (`VI`); `only_collect_sets_can_free`: only a
  `collect` store turns a cell `true`.
* `composed_no_use_after_free`, `composed_retired_frozen` (every run, `Step.insertAny`
  included), `composed_get_linearizable` (when the table component is reached by a run that
  respects the key contract, `CReachable`), and `composed_get_linearizable_some` (`get` hits,
  when it respects the probe contract, `PReachable`).
* `static_never_freed`, `static_can_free_false`, `prune_sentinel`: the static empty table is
  never retired or freed, its `can_free` stays `false`, and it ends the retired list for
  `prune_tables`.
* `composed_retired_eventually_freed`: reclamation liveness (for `1 < W`), using `collect`
  liveness on flag-keeping schedules (`collect_live`, from `Collect.Ev.eventually_ran_keep`).
-/

set_option linter.unusedSectionVars false

namespace SyncTable
namespace Composed

open Collect.Ev (ESt EStep EReach)

variable {K V : Type} [DecidableEq K] (W : Nat) (C : Cfg K)

/-- Composed state: ordered table model, primary `collect` model, ghost clock map. -/
structure CSt (K V : Type) where
  o : OSt K V
  e : ESt
  /-- ghost: table time (`St.clk`) to `collect` time (`St.now`) -/
  f : Nat → Nat
  /-- each table's `can_free: AtomicBool` (by table id): `false` from allocation, written `true`
  only by `collect`'s `mark_ready` (`stores`) -/
  cell : Nat → Bool

/-- The `defer_by_id` flag callback for table `t` retired at table time `d`. -/
def flagCb (f : Nat → Nat) (t d : Nat) : Collect.Cb := ⟨t, f d, true⟩

/-- A `collect` step that does not drop a queued (or already stored) `defer_by_id` flag (every
step except `cancel_by_ids`) and registers no new one (every step except `defer_by_id`: the
table's own registration is `CStep.swap`; other `defer_by_id` clients are not part of the
composed run). -/
def KeepFlags (e e' : ESt) : Prop :=
  (∀ c : Collect.Cb, c.byId = true → c ∈ Collect.bufs e.base ∨ c ∈ e.base.ran →
    c ∈ Collect.bufs e'.base ∨ c ∈ e'.base.ran) ∧ Collect.Ev.NoNewFlag e e'

/-- The `can_free` cells after a `collect` step: `mark_ready` stores `true` through every
pointer in `stores`. -/
def storeCells (cell : Nat → Bool) (e e' : ESt) : Nat → Bool :=
  Collect.Flags.storeAll cell (Collect.Flags.stores e.base e'.base)

/-- Clock map after a new joint event at table time `clk` and `collect` time `now`. -/
def extend (f : Nat → Nat) (clk now : Nat) : Nat → Nat :=
  fun a => if a < clk then f a else now + (a - clk)

/-- `collect::defer_by_id(&can_free)` for table `id` (`EStep.defer e id true`). -/
def deferE (e : ESt) (id : Nat) : ESt :=
  { e with base := { e.base with now := e.base.now + 1
                                 current := e.base.current ++ [⟨id, e.base.now, true⟩] }
           total := e.total + 1 }

/-- A table step that involves no `collect` interaction: same clock, same pin starts, and no
retired entry changes (no `can_free` is set, nothing is retired). Tables may be freed. -/
def Local (s s' : St K V) : Prop :=
  s'.clk = s.clk ∧ (∀ u, (s'.rd u).start = (s.rd u).start) ∧
  ∀ t v d cf, s'.ts t = .retired v d cf → s.ts t = .retired v d cf

/-- The `can_free` cells after `replace_table` from `current = c` to `c'`: a newly allocated table
(at a fresh or at a reused address) gets `can_free = false` (`AtomicBool::new(false)` in
`TableRef::allocate`); nothing changes when `current` stays. -/
def allocCell (cell : Nat → Bool) (c c' : Nat) : Nat → Bool :=
  if c' = c then cell else upd cell c' false

theorem allocCell_eq {cell : Nat → Bool} {c c' : Nat} (h : c' = c) : allocCell cell c c' = cell := by
  simp [allocCell, h]

theorem allocCell_other {cell : Nat → Bool} {c c' t : Nat} (h : t ≠ c') :
    allocCell cell c c' t = cell t := by
  unfold allocCell; split
  · rfl
  · exact upd_other _ _ _ _ h

theorem allocCell_new {cell : Nat → Bool} {c c' : Nat} (h : c' ≠ c) :
    allocCell cell c c' c' = false := by
  simp [allocCell, h]

theorem allocCell_true {cell : Nat → Bool} {c c' t : Nat} (h : allocCell cell c c' t = true) :
    cell t = true := by
  by_cases e : t = c'
  · subst e; by_cases e2 : t = c
    · rw [allocCell_eq e2] at h; exact h
    · rw [allocCell_new e2] at h; cases h
  · rw [allocCell_other e] at h; exact h

inductive CStep : CSt K V → CSt K V → Prop
  /-- table-only step (writer `insert`/`remove`, `replace_table` of the static empty table (into
  a fresh table or one at a reused address, whose `can_free` is initialised `false`), a
  `prune_tables` iteration, reader probes) -/
  | tbl {o o' : OSt K V} (e : ESt) (f : Nat → Nat) (cell cell' : Nat → Bool) : OStep C o o' →
      Local o.s o'.s → cell' = allocCell cell o.s.cur o'.s.cur →
      CStep ⟨o, e, f, cell⟩ ⟨o', e, f, cell'⟩
  /-- `collect::pin` entering the outermost region of reader thread `u` -/
  | pin {s : St K V} (rl : List Nat) {e e' : ESt} (f : Nat → Nat) (cell : Nat → Bool) (u : Nat)
      (hidle : s.rd u = .idle) (he : EStep W e e') (hk : KeepFlags e e')
      (hloc : e'.base.loc = Collect.upd e.base.loc u (.pinned e.base.now 0))
      (hnow : e'.base.now = e.base.now + 1) :
      CStep ⟨⟨s, rl⟩, e, f, cell⟩
        ⟨⟨{ setRd s u (.pinned s.clk []) with clk := s.clk + 1 }, rl⟩, e',
          extend f s.clk e.base.now, storeCells cell e e'⟩
  /-- leaving the outermost `pin` of reader thread `u` -/
  | unpin {s : St K V} (rl : List Nat) {e e' : ESt} (f : Nat → Nat) (cell : Nat → Bool)
      (u st : Nat) (hl : List Nat)
      (hrd : s.rd u = .pinned st hl) (he : EStep W e e') (hk : KeepFlags e e')
      (hloc : e'.base.loc = Collect.upd e.base.loc u .registered) :
      CStep ⟨⟨s, rl⟩, e, f, cell⟩ ⟨⟨setRd s u .idle, rl⟩, e', f, storeCells cell e e'⟩
  /-- `replace_table` + `defer_by_id(&can_free)` of an old `current` that is not the static
  empty table. A newly allocated table (at `nextId` or at a reused address) gets
  `can_free = false` (`AtomicBool::new(false)`, `allocCell`); the static one keeps its `false`
  (`VI.stat`). -/
  | swap {o o' : OSt K V} (e : ESt) (f : Nat → Nat) (cell : Nat → Bool) : OStep C o o' →
      o'.s.cur ≠ o.s.cur → o.s.cur ≠ 0 →
      CStep ⟨o, e, f, cell⟩ ⟨o', deferE e o.s.cur, extend f o.s.clk e.base.now,
        allocCell cell o.s.cur o'.s.cur⟩
  /-- `prune_tables`' `can_free.load(Acquire)` of retired table `t` returns `true` (the cell
  holds `true`); `canFree` records the observation for the following pop -/
  | markFree (s : St K V) (rl : List Nat) (e : ESt) (f : Nat → Nat) (cell : Nat → Bool)
      (t v d : Nat) (ht : s.ts t = .retired v d false) (hc : cell t = true) :
      CStep ⟨⟨s, rl⟩, e, f, cell⟩
        ⟨⟨{ s with ts := upd s.ts t (.retired v d true) }, rl⟩, e, f, cell⟩
  /-- any other `collect` step, not moving a thread that is inside a table read -/
  | col (o : OSt K V) (f : Nat → Nat) (cell : Nat → Bool) {e e' : ESt} (he : EStep W e e')
      (hk : KeepFlags e e') (hfix : ∀ u, o.s.rd u ≠ .idle → e'.base.loc u = e.base.loc u) :
      CStep ⟨o, e, f, cell⟩ ⟨o, e', f, storeCells cell e e'⟩

def cinit : CSt K V := ⟨oinit, Collect.Ev.einit, id, fun _ => false⟩

inductive CReach : CSt K V → Prop
  | init : CReach cinit
  | step {c c'} : CReach c → CStep W C c c' → CReach c'

inductive CSteps : CSt K V → CSt K V → Prop
  | refl (c) : CSteps c c
  | tail {a b c} : CSteps a b → CStep W C b c → CSteps a c

theorem csteps_trans {a b c : CSt K V} (h1 : CSteps W C a b) (h2 : CSteps W C b c) :
    CSteps W C a c := by
  induction h2 with
  | refl => exact h1
  | tail _ hs ih => exact .tail ih hs

theorem csteps_reach {a b : CSt K V} (ha : CReach W C a) (h : CSteps W C a b) :
    CReach W C b := by
  induction h with
  | refl => exact ha
  | tail _ hs ih => exact .step ih hs

/-! ## `collect` facts used here -/

theorem markQuiet_now (t : Collect.Tid) (s : Collect.St) : (Collect.markQuiet t s).now = s.now := by
  unfold Collect.markQuiet; split <;> simp

theorem quiet_now (t : Collect.Tid) : ∀ fuel (s : Collect.St), (Collect.quiet t fuel s).1.now = s.now
  | 0, _ => rfl
  | fuel + 1, s => by
    simp only [Collect.quiet]
    split
    · rfl
    · split
      · rw [quiet_now t fuel]; simp [Collect.takePending, markQuiet_now]
      · simp [Collect.takePending, markQuiet_now]

theorem collectUnreg_now (s : Collect.St) : (Collect.collectUnreg s).1.now = s.now := by
  unfold Collect.collectUnreg; split <;> rfl

/-- `collect`'s logical clock never goes back. -/
theorem estep_now {e e' : ESt} (hs : EStep W e e') : e.base.now ≤ e'.base.now := by
  cases hs with
  | collectReg t _ _ =>
    dsimp only; split <;> simp [Collect.startCollect, Collect.quietRust_eq, quiet_now, Collect.Ev.setSeen]
  | collectUnreg => simp [Collect.startCollect, collectUnreg_now]
  | release => simp
  | pinForce => simp [Collect.Ev.setSeen]
  | collectStore => simp [Collect.Ev.setSeen]
  | pinRegister => simp [Collect.register]
  | _ => simp

theorem deferE_step (e : ESt) (id : Nat) : EStep W e (deferE e id) := EStep.defer e id true

/-! ## The link invariant -/

theorem extend_lt {f : Nat → Nat} {clk now a : Nat} (h : a < clk) : extend f clk now a = f a := by
  simp [extend, h]

theorem extend_self (f : Nat → Nat) (clk now : Nat) : extend f clk now clk = now := by
  simp [extend]

/-- The link between the two components. -/
structure J (c : CSt K V) : Prop where
  mono : ∀ a b, a < b → c.f a < c.f b
  below : ∀ a, a < c.o.s.clk → c.f a < c.e.base.now
  startLt : ∀ u st, (c.o.s.rd u).start = some st → st < c.o.s.clk
  /-- a reader inside a table read is pinned in `collect`, from the corresponding time -/
  pinned : ∀ u st, (c.o.s.rd u).start = some st → c.e.base.loc u = .pinned (c.f st) 0
  retLt : ∀ t v d cf, c.o.s.ts t = .retired v d cf → d < c.o.s.clk
  /-- the flag of a retired, not yet freeable table is queued in `collect` or stored -/
  flag : ∀ t v d, c.o.s.ts t = .retired v d false →
    flagCb c.f t d ∈ Collect.bufs c.e.base ∨ flagCb c.f t d ∈ c.e.base.ran

theorem extend_mono {f : Nat → Nat} {clk now : Nat} (hm : ∀ a b, a < b → f a < f b)
    (hb : ∀ a, a < clk → f a < now) : ∀ a b, a < b → extend f clk now a < extend f clk now b := by
  intro a b hab
  simp only [extend]
  by_cases ha : a < clk
  · by_cases hb' : b < clk
    · simp [ha, hb', hm a b hab]
    · simp only [ha, hb', ↓reduceIte]; have := hb a ha; omega
  · have : ¬ b < clk := by omega
    simp only [ha, this, ↓reduceIte]; omega

theorem j_init : J (cinit : CSt K V) := by
  refine ⟨fun a b h => h, fun a h => by simp [cinit, oinit, init] at h, ?_, ?_, ?_, ?_⟩
  · intro u st h; simp [cinit, oinit, init, RS.start] at h
  · intro u st h; simp [cinit, oinit, init, RS.start] at h
  · intro t v d cf h; simp [cinit, oinit, init] at h; split at h <;> cases h
  · intro t v d h; simp [cinit, oinit, init] at h; split at h <;> cases h

/-- `replace_table` steps (the only steps that change `current`) have this shape. -/
theorem swap_shape {o o' : OSt K V} (h : OStep C o o') (hc : o'.s.cur ≠ o.s.cur) :
    ∃ t T' nx ch, PubOK o.s t T' nx ∧ o'.s = publish o.s t T' nx ch := by
  have key : ∀ {s s' : St K V}, Step C s s' → s'.cur ≠ s.cur →
      ∃ t T' nx ch, PubOK s t T' nx ∧ s' = publish s t T' nx ch := by
    intro s s' hs hc
    cases hs with
    | expand => exact ⟨_, _, _, _, swap_pub _ _, rfl⟩
    | replace => exact ⟨_, _, _, _, swap_pub _ _, rfl⟩
    | expandAt m a ha => exact ⟨_, _, _, _, swapAt_pub _ ha, rfl⟩
    | replaceAt m a l ha => exact ⟨_, _, _, _, swapAt_pub _ ha, rfl⟩
    | replaceEmpty => exact ⟨_, _, _, _, swapEmpty_pub _, rfl⟩
    | _ => exact absurd rfl hc
  cases h with
  | other _ hs => exact key hs hc
  | swap _ hs => exact key hs hc
  | pruneHead => exact absurd rfl hc

/-- `replace_table` of a non-static table: the new `current` is live, the old one retired. -/
theorem swap_ts {o o' : OSt K V} (ho : OStep C o o') (hc : o'.s.cur ≠ o.s.cur) (hc0 : o.s.cur ≠ 0)
    (x : Nat) : o'.s.ts x = if x = o'.s.cur then .live else
      if x = o.s.cur then .retired o.s.ver o.s.clk false else o.s.ts x := by
  obtain ⟨t, T', nx, ch, _, hs'⟩ := swap_shape C ho hc
  rw [hs', publish_ts]; unfold retire; simp only [hc0, ne_eq, not_false_eq_true, and_true]; rfl

theorem swap_clk {o o' : OSt K V} (ho : OStep C o o') (hc : o'.s.cur ≠ o.s.cur)
    (hc0 : o.s.cur ≠ 0) : o'.s.clk = o.s.clk + 1 := by
  obtain ⟨t, T', nx, ch, _, hs'⟩ := swap_shape C ho hc
  rw [hs']; exact tick_ne0 hc0

theorem bufs_deferE (e : ESt) (id : Nat) (c : Collect.Cb) (h : c ∈ Collect.bufs e.base) :
    c ∈ Collect.bufs (deferE e id).base := by
  simp only [Collect.bufs, deferE, List.mem_append] at h ⊢; grind

theorem j_step {c c' : CSt K V} (hj : J c) (hs : CStep W C c c') : J c' := by
  cases hs with
  | tbl e f cell cell' ho hl _ =>
    obtain ⟨hclk, hst, hret⟩ := hl
    refine ⟨hj.mono, ?_, ?_, ?_, ?_, ?_⟩
    · intro a ha; exact hj.below a (by simp only [hclk] at ha ⊢; exact ha)
    · intro u st h; rw [hclk]; exact hj.startLt u st (by rw [← hst]; exact h)
    · intro u st h; exact hj.pinned u st (by rw [← hst]; exact h)
    · intro t v d cf h; rw [hclk]; exact hj.retLt t v d cf (hret _ _ _ _ h)
    · intro t v d h; exact hj.flag t v d (hret _ _ _ _ h)
  | pin rl f cell u hidle he hk hloc hnow =>
    rename_i s e e'
    refine ⟨extend_mono hj.mono hj.below, ?_, ?_, ?_, ?_, ?_⟩
    · intro a ha
      simp only at ha ⊢
      rw [hnow]; simp only [extend]
      split
      · have := hj.below a (by assumption); simp only at this; omega
      · omega
    · intro u' st h
      simp only [setRd] at h ⊢
      by_cases e1 : u' = u
      · subst e1; simp [RS.start] at h; omega
      · rw [upd_other _ _ _ _ e1] at h; have := hj.startLt u' st h; simp only at this; omega
    · intro u' st h
      simp only [setRd] at h ⊢
      rw [hloc]
      by_cases e1 : u' = u
      · subst e1; simp [RS.start] at h; subst h; simp [extend_self]
      · rw [upd_other _ _ _ _ e1] at h
        rw [Collect.upd_other _ _ _ _ e1, hj.pinned u' st h, extend_lt (hj.startLt u' st h)]
    · intro t v d cf h; have := hj.retLt t v d cf h; simp only at this ⊢; omega
    · intro t v d h
      have hd := hj.retLt t v d false h
      simp only [flagCb, extend_lt hd]
      exact hk.1 _ rfl (hj.flag t v d h)
  | unpin rl f cell u st hl hrd he hk hloc =>
    rename_i s e e'
    have hn := estep_now W he
    refine ⟨hj.mono, ?_, ?_, ?_, hj.retLt, ?_⟩
    · intro a ha; have := hj.below a ha; simp only at this ⊢; omega
    · intro u' st' h
      simp only [setRd] at h ⊢
      by_cases e1 : u' = u
      · subst e1; simp [RS.start] at h
      · rw [upd_other _ _ _ _ e1] at h; exact hj.startLt u' st' h
    · intro u' st' h
      simp only [setRd] at h ⊢
      by_cases e1 : u' = u
      · subst e1; simp [RS.start] at h
      · rw [upd_other _ _ _ _ e1] at h
        rw [hloc, Collect.upd_other _ _ _ _ e1]; exact hj.pinned u' st' h
    · intro t v d h; exact hk.1 _ rfl (hj.flag t v d h)
  | swap e f cell ho hc hc0 =>
    rename_i o o'
    have hts := swap_ts C ho hc hc0
    have hclk : o'.s.clk = o.s.clk + 1 := swap_clk C ho hc hc0
    have hrd : o'.s.rd = o.s.rd := by
      obtain ⟨_, _, _, _, _, hs'⟩ := swap_shape C ho hc; rw [hs']; rfl
    refine ⟨extend_mono hj.mono hj.below, ?_, ?_, ?_, ?_, ?_⟩
    · intro a ha
      simp only [hclk, deferE] at ha ⊢
      simp only [extend]
      split
      · have := hj.below a (by assumption); simp only at this; omega
      · omega
    · intro u st h; simp only [hrd, hclk] at h ⊢; have := hj.startLt u st h; simp only at this; omega
    · intro u st h; simp only [hrd, deferE] at h ⊢
      rw [hj.pinned u st h, extend_lt (hj.startLt u st h)]
    · intro t v d cf h; simp only [hts, hclk] at h ⊢
      split at h
      · cases h
      · split at h
        · cases h; omega
        · have := hj.retLt t v d cf h; simp only at this; omega
    · intro t v d h; simp only [hts] at h
      split at h
      · cases h
      · split at h
        · rename_i e1
          cases h; subst e1
          left; simp [Collect.bufs, deferE, flagCb, extend_self]
        · have hd := hj.retLt t v d false h
          simp only [flagCb, extend_lt hd]
          rcases hj.flag t v d h with h1 | h1
          · exact .inl (bufs_deferE e _ _ h1)
          · exact .inr h1
  | markFree s rl e f cell t v d ht hc =>
    refine ⟨hj.mono, hj.below, hj.startLt, hj.pinned, ?_, ?_⟩
    · intro x v' d' cf h; simp only [upd] at h
      split at h
      · cases h; exact hj.retLt t v d false ht
      · exact hj.retLt x v' d' cf h
    · intro x v' d' h; simp only [upd] at h
      split at h
      · cases h
      · exact hj.flag x v' d' h
  | col o f cell he hk hfix =>
    rename_i e e'
    have hn := estep_now W he
    refine ⟨hj.mono, ?_, hj.startLt, ?_, hj.retLt, ?_⟩
    · intro a ha; have := hj.below a ha; simp only at this ⊢; omega
    · intro u st h
      have hne : o.s.rd u ≠ .idle := by intro e0; rw [e0] at h; simp [RS.start] at h
      simp only at h ⊢; rw [hfix u hne]; exact hj.pinned u st h
    · intro t v d h; exact hk.1 _ rfl (hj.flag t v d h)

/-! ## Projections -/

/-- Every composed step is a `collect` primary step or a stutter. -/
theorem cstep_e {c c' : CSt K V} (hs : CStep W C c c') : c'.e = c.e ∨ EStep W c.e c'.e := by
  cases hs with
  | tbl => exact .inl rfl
  | pin _ _ _ _ _ he => exact .inr he
  | unpin _ _ _ _ _ _ _ he => exact .inr he
  | swap e => exact .inr (deferE_step W e _)
  | markFree => exact .inl rfl
  | col _ _ _ he => exact .inr he

theorem creach_ereach {c : CSt K V} (h : CReach W C c) : EReach W c.e := by
  induction h with
  | init => exact .init
  | step _ hs ih =>
    rcases cstep_e W C hs with e | e
    · rw [e]; exact ih
    · exact .step ih e

theorem creach_j {c : CSt K V} (h : CReach W C c) : J c := by
  induction h with
  | init => exact j_init
  | step _ hs ih => exact j_step W C ih hs

/-! ## The `can_free` cells -/

/-- Allocation facts about the table states (no `Cfg.Cover` needed). -/
structure TsI (s : St K V) : Prop where
  curLt : s.cur < s.nextId
  curLive : s.ts s.cur = .live
  fresh : ∀ t, s.nextId ≤ t → s.ts t = .unalloc
  /-- the static empty table is never retired or freed -/
  stat : s.ts 0 = .live

theorem tsI_init : TsI (init : St K V) :=
  ⟨by simp [init], by simp [init], fun t h => by
    simp only [init] at h ⊢; split
    · omega
    · rfl, by simp [init]⟩

/-- A retired table is neither `current`, nor fresh, nor the static one. -/
theorem TsI.ret_ne {s : St K V} (h : TsI s) {t v d : Nat} {cf : Bool}
    (ht : s.ts t = .retired v d cf) : t ≠ s.cur ∧ t < s.nextId ∧ t ≠ 0 := by
  refine ⟨fun e => ?_, Nat.lt_of_not_le fun hle => ?_, fun e => ?_⟩
  · rw [e, h.curLive] at ht; cases ht
  · rw [h.fresh t hle] at ht; cases ht
  · rw [e, h.stat] at ht; cases ht

theorem tsI_publish {s : St K V} (h : TsI s) {t : Nat} {T' : Table K V} {nx : Nat} (ch : Bool)
    (hp : PubOK s t T' nx) : TsI (publish s t T' nx ch) := by
  have hnx := hp.nx_ge
  have hc := h.curLt
  have htn : t < nx := by
    rcases hp with ⟨rfl, rfl⟩ | ⟨rfl, rfl, _⟩ | ⟨ht, rfl⟩
    · omega
    · omega
    · exact Nat.lt_of_not_le fun hle => by rw [h.fresh _ hle] at ht; cases ht
  refine ⟨?_, by show (publish s t T' nx ch).ts t = _; rw [publish_ts, if_pos rfl], ?_, ?_⟩
  · exact htn
  · intro u hu
    have hu' : nx ≤ u := hu
    have : u ≠ t := by omega
    rw [publish_ts, if_neg this, retire_of_ne (by omega)]; exact h.fresh u (by omega)
  · rw [publish_ts]; split
    · rfl
    · rw [retire_of_ne (fun ⟨e, h0⟩ => h0 e.symm)]; exact h.stat

theorem tsI_upd {s : St K V} (h : TsI s) {t v d : Nat} {cf : Bool}
    (ht : s.ts t = .retired v d cf) (x : TS) : TsI { s with ts := upd s.ts t x } := by
  have h1 : s.cur ≠ t := fun e => by rw [← e, h.curLive] at ht; cases ht
  have h2 : ∀ u, s.nextId ≤ u → u ≠ t := fun u hu e => by rw [← e, h.fresh u hu] at ht; cases ht
  exact ⟨h.curLt, by show upd s.ts t x s.cur = _; rw [upd_other _ _ _ _ h1]; exact h.curLive,
    fun u hu => by show upd s.ts t x u = _; rw [upd_other _ _ _ _ (h2 u hu)]; exact h.fresh u hu,
    by show upd s.ts t x 0 = _; rw [upd_other _ _ _ _ (Ne.symm (h.ret_ne ht).2.2)]; exact h.stat⟩

theorem tsI_step {s s' : St K V} (h : TsI s) (hs : Step C s s') : TsI s' := by
  cases hs with
  | expand => exact tsI_publish h _ (swap_pub _ _)
  | replace => exact tsI_publish h _ (swap_pub _ _)
  | expandAt m a ha => exact tsI_publish h _ (swapAt_pub _ ha)
  | replaceAt m a l ha => exact tsI_publish h _ (swapAt_pub _ ha)
  | replaceEmpty => exact tsI_publish h _ (swapEmpty_pub _)
  | prune t v d ht => exact tsI_upd h ht _
  | markFree t v d ht _ => exact tsI_upd h ht _
  | _ => exact ⟨h.curLt, h.curLive, h.fresh, h.stat⟩

/-- `nextId` never decreases. -/
theorem step_nextId {s s' : St K V} (hs : Step C s s') : s.nextId ≤ s'.nextId := by
  cases hs with
  | expand => show _ ≤ _ + 1; omega
  | replace => show _ ≤ _ + 1; omega
  | replaceEmpty => exact Nat.le_refl _
  | _ => exact Nat.le_refl _

/-- A table step keeps a retired table retired, possibly setting `canFree`. -/
theorem step_retired {s s' : St K V} (hi : TsI s) (hs : Step C s s') {t v d : Nat}
    (h : s.ts t = .retired v d false) :
    s'.ts t = .retired v d false ∨ s'.ts t = .retired v d true := by
  obtain ⟨h2, h1, h0⟩ := hi.ret_ne h
  have pub : ∀ t' T' nx ch, PubOK s t' T' nx → (publish s t' T' nx ch).ts t = .retired v d false := by
    intro t' T' nx ch hp
    have : t ≠ t' := by
      rcases hp with ⟨rfl, _⟩ | ⟨rfl, _, _⟩ | ⟨ht', _⟩
      · omega
      · omega
      · intro e; subst e; rw [h] at ht'; cases ht'
    rw [publish_ts, if_neg this, retire_of_ne (fun ⟨e, _⟩ => h2 e)]; exact h
  cases hs with
  | expandAt m a ha => exact .inl (pub _ _ _ _ (swapAt_pub _ ha))
  | replaceAt m a l ha => exact .inl (pub _ _ _ _ (swapAt_pub _ ha))
  | expand => exact .inl (pub _ _ _ _ (swap_pub _ _))
  | replace => exact .inl (pub _ _ _ _ (swap_pub _ _))
  | replaceEmpty => exact .inl (pub _ _ _ _ (swapEmpty_pub _))
  | prune t' v' d' h' =>
    left
    have : t ≠ t' := fun e => by subst e; rw [h] at h'; cases h'
    simp [upd_other _ _ _ _ this, h]
  | markFree t' v' d' h' _ =>
    by_cases e : t = t'
    · subst e; rw [h] at h'; cases h'; right; simp
    · left; simp [upd_other _ _ _ _ e, h]
  | _ => left; exact h

/-- A table-only step (`CStep.tbl`) keeps `current`, or is `replace_table` of the static empty
table (nothing is retired). -/
theorem tbl_cur {o o' : OSt K V} (hi : TsI o.s) (ho : OStep C o o') (hl : Local o.s o'.s) :
    o'.s.cur = o.s.cur ∨ o.s.cur = 0 := by
  by_cases hc : o'.s.cur = o.s.cur
  · exact .inl hc
  · right
    by_cases hc0 : o.s.cur = 0
    · exact hc0
    · exfalso
      have hcur := swap_ts C ho hc hc0 o.s.cur
      rw [if_neg (Ne.symm hc), if_pos rfl] at hcur
      have := hl.2.2 _ _ _ _ hcur
      rw [hi.curLive] at this; cases this

theorem mem_fl {s : Collect.St} {x : Collect.Cb} :
    x ∈ Collect.Flags.fl s ↔ x ∈ Collect.bufs s ∧ x.byId = true := by
  rw [Collect.Flags.fl, List.mem_filter, ← Collect.Ev.mem_bufs_flat]

/-- A `collect` step of the composed run: `ran` grows, no flag is registered, and every flag it
stores was registered. -/
theorem estep_newRan {e e' : ESt} (h : EReach W e) (he : EStep W e e')
    (hn : Collect.Ev.NoNewFlag e e') :
    (∃ w, e'.base.ran = e.base.ran ++ w) ∧
    (∀ x ∈ Collect.Flags.fl e'.base, x ∈ Collect.Flags.fl e.base) ∧
    ∀ x ∈ Collect.Flags.newRan e.base e'.base, x ∈ Collect.Flags.fl e.base := by
  have hno : ∀ x ∈ Collect.Flags.fl e'.base, x ∈ Collect.Flags.fl e.base := fun x hx => by
    rw [mem_fl] at hx ⊢; exact ⟨hn x hx.2 hx.1, hx.2⟩
  rcases Collect.Ev.estep_base W he with hb | hb
  · refine ⟨⟨[], by rw [hb]; simp⟩, hno, fun x hx => ?_⟩
    simp [Collect.Flags.newRan, hb] at hx
  · obtain ⟨hw, hs⟩ := Collect.Flags.col_newRan (Collect.Ev.ereach_base W h) hb hno
    exact ⟨hw, hno, hs⟩

/-- The `can_free` invariant. -/
structure VI (c : CSt K V) : Prop where
  ts : TsI c.o.s
  /-- every queued flag is the flag of a retired table whose `can_free` is not yet observed -/
  queued : ∀ x ∈ Collect.Flags.fl c.e.base,
    ∃ v d, c.o.s.ts x.id = .retired v d false ∧ x = flagCb c.f x.id d
  /-- **a retired table's `can_free` cell is `true` exactly when `collect` stored its flag** -/
  val : ∀ t v d cf, c.o.s.ts t = .retired v d cf → (c.cell t = true ↔ flagCb c.f t d ∈ c.e.base.ran)
  /-- the current table's cell is `false` (as allocated) -/
  cur : c.cell c.o.s.cur = false
  /-- an observed `can_free` is (still) `true` -/
  obs : ∀ t v d, c.o.s.ts t = .retired v d true → c.cell t = true
  /-- **the static empty table's `can_free` is `false`** (`AtomicBool::new(false)` in
  `EMPTY_TABLE`, never stored to) -/
  stat : c.cell 0 = false
  /-- a not yet allocated table's `can_free` is `false` (what allocation stores) -/
  fresh : ∀ t, c.o.s.nextId ≤ t → c.cell t = false

theorem vi_init : VI (cinit : CSt K V) := by
  refine ⟨tsI_init, ?_, ?_, rfl, ?_, rfl, fun _ _ => rfl⟩
  · intro x hx; simp [Collect.Flags.fl, Collect.Flags.flat, cinit, Collect.Ev.einit,
      Collect.init] at hx
  · intro t v d cf h; simp [cinit, oinit, init] at h; split at h <;> cases h
  · intro t v d h; simp [cinit, oinit, init] at h; split at h <;> cases h

/-- A composed step whose table part keeps the table states and whose `collect` part is a
(flag-keeping) `collect` step. -/
theorem vi_collect {c c' : CSt K V} (hj : J c) (hv : VI c) (her : EReach W c.e)
    (he : EStep W c.e c'.e) (hn : Collect.Ev.NoNewFlag c.e c'.e)
    (hts : c'.o.s.ts = c.o.s.ts) (hcur : c'.o.s.cur = c.o.s.cur)
    (hnx : c'.o.s.nextId = c.o.s.nextId) (hf : ∀ a, a < c.o.s.clk → c'.f a = c.f a)
    (hval : c'.cell = storeCells c.cell c.e c'.e) : VI c' := by
  obtain ⟨⟨w, hw⟩, hno, hsub⟩ := estep_newRan W her he hn
  have hnr := Collect.Flags.newRan_of hw
  have stored : ∀ t, t ∈ Collect.Flags.stores c.e.base c'.e.base →
      ∃ v d, c.o.s.ts t = .retired v d false ∧ flagCb c.f t d ∈ w := by
    intro t ht
    obtain ⟨x, hx, rfl⟩ := Collect.Flags.mem_stores.1 ht
    obtain ⟨v, d, h1, h2⟩ := hv.queued x (hsub x hx)
    refine ⟨v, d, h1, ?_⟩
    rw [← h2]; rw [hnr] at hx; exact (List.mem_filter.1 hx).1
  have fd : ∀ t v d cf, c.o.s.ts t = .retired v d cf → c'.f d = c.f d := fun t v d cf h =>
    hf d (hj.retLt t v d cf h)
  have nostore : ∀ t, c.cell t = false → (c.o.s.ts t = .live ∨ c.o.s.ts t = .unalloc) →
      c'.cell t = false := by
    intro t h0 hl
    rw [hval, storeCells]
    cases e : Collect.Flags.storeAll c.cell (Collect.Flags.stores c.e.base c'.e.base) t
    · rfl
    · rcases Collect.Flags.storeAll_true.1 e with h1 | h1
      · rw [h0] at h1; cases h1
      · obtain ⟨v, d, h2, _⟩ := stored _ h1
        rcases hl with hl | hl <;> rw [hl] at h2 <;> cases h2
  refine ⟨⟨?_, ?_, ?_, ?_⟩, ?_, ?_, ?_, ?_, ?_, ?_⟩
  · rw [hcur, hnx]; exact hv.ts.curLt
  · rw [hts, hcur]; exact hv.ts.curLive
  · intro t ht; rw [hts]; rw [hnx] at ht; exact hv.ts.fresh t ht
  · rw [hts]; exact hv.ts.stat
  · intro x hx
    obtain ⟨v, d, h1, h2⟩ := hv.queued x (hno x hx)
    refine ⟨v, d, by rw [hts]; exact h1, ?_⟩
    simp only [flagCb, fd _ _ _ _ h1] at h2 ⊢; exact h2
  · intro t v d cf h
    rw [hts] at h
    simp only [flagCb, fd _ _ _ _ h] at ⊢
    rw [hval, storeCells, Collect.Flags.storeAll_true, hv.val t v d cf h, hw]
    simp only [flagCb, List.mem_append]
    constructor
    · rintro (h1 | h1)
      · exact .inl h1
      · obtain ⟨v', d', h2, h3⟩ := stored t h1
        rw [h] at h2; cases h2; exact .inr h3
    · rintro (h1 | h1)
      · exact .inl h1
      · refine .inr (Collect.Flags.mem_stores.2 ⟨flagCb c.f t d, ?_, rfl⟩)
        rw [hnr]; exact List.mem_filter.2 ⟨h1, rfl⟩
  · rw [hcur]; exact nostore _ hv.cur (.inl hv.ts.curLive)
  · intro t v d h
    rw [hts] at h
    rw [hval, storeCells, Collect.Flags.storeAll_true]; exact .inl (hv.obs t v d h)
  · exact nostore _ hv.stat (.inl hv.ts.stat)
  · intro t ht; rw [hnx] at ht; exact nostore _ (hv.fresh t ht) (.inr (hv.ts.fresh t ht))

theorem vi_step {c c' : CSt K V} (h : CReach W C c) (hv : VI c) (hs : CStep W C c c') :
    VI c' := by
  have hj := creach_j W C h
  have her := creach_ereach W C h
  cases hs with
  | tbl e f cell cell' ho hl hcl =>
    rename_i o o'
    subst hcl
    have hnx := step_nextId C (ostep_step C ho)
    have hi' := tsI_step C hv.ts (ostep_step C ho)
    have hv0 : VI (⟨o, e, f, cell⟩ : CSt K V) := hv
    -- a retired table of `o'` is not the new `current`, so its cell is unchanged
    have hret : ∀ t v d cf, o'.s.ts t = .retired v d cf →
        allocCell cell o.s.cur o'.s.cur t = cell t := by
      intro t v d cf ht; exact allocCell_other (hi'.ret_ne ht).1
    have hle : ∀ t, allocCell cell o.s.cur o'.s.cur t = true → cell t = true :=
      fun t h => allocCell_true h
    have hcur : cell o.s.cur = false := hv0.cur
    have hstat : cell 0 = false := hv0.stat
    have hfresh : ∀ t, o.s.nextId ≤ t → cell t = false := hv0.fresh
    refine ⟨hi', fun x hx => ?_, fun t v d cf ht => ?_, ?_, fun t v d ht => ?_, ?_,
      fun t ht => ?_⟩
    · obtain ⟨v, d, h1, h2⟩ := hv.queued x hx
      refine ⟨v, d, ?_, h2⟩
      rcases step_retired C hv.ts (ostep_step C ho) h1 with h3 | h3
      · exact h3
      · have := hl.2.2 _ _ _ _ h3; rw [h1] at this; cases this
    · show allocCell cell o.s.cur o'.s.cur t = true ↔ _
      rw [hret t v d cf ht]; exact hv.val t v d cf (hl.2.2 _ _ _ _ ht)
    · show allocCell cell o.s.cur o'.s.cur o'.s.cur = false
      by_cases e1 : o'.s.cur = o.s.cur
      · rw [allocCell_eq e1, e1]; exact hcur
      · exact allocCell_new e1
    · show allocCell cell o.s.cur o'.s.cur t = true
      rw [hret t v d true ht]; exact hv.obs t v d (hl.2.2 _ _ _ _ ht)
    · show allocCell cell o.s.cur o'.s.cur 0 = false
      cases e : allocCell cell o.s.cur o'.s.cur 0
      · rfl
      · have := hle 0 e; rw [hstat] at this; cases this
    · show allocCell cell o.s.cur o'.s.cur t = false
      cases e : allocCell cell o.s.cur o'.s.cur t
      · rfl
      · have := hle t e; rw [hfresh t (Nat.le_trans hnx ht)] at this; cases this
  | pin rl f cell u hidle he hk hloc hnow =>
    exact vi_collect W hj hv her he hk.2 rfl rfl rfl (fun a ha => extend_lt ha) rfl
  | unpin rl f cell u st hl hrd he hk hloc =>
    exact vi_collect W hj hv her he hk.2 rfl rfl rfl (fun _ _ => rfl) rfl
  | col o f cell he hk hfix =>
    exact vi_collect W hj hv her he hk.2 rfl rfl rfl (fun _ _ => rfl) rfl
  | swap e f cell ho hc hc0 =>
    rename_i o o'
    obtain ⟨t', T', nx, ch, hp, hs'⟩ := swap_shape C ho hc
    have hts := swap_ts C ho hc hc0
    have hi := hv.ts
    have hi' := tsI_step C hi (ostep_step C ho)
    have hnx := step_nextId C (ostep_step C ho)
    -- the new `current` was not retired (fresh, static, or at a freed address)
    have hnr : ∀ x v d cf, o.s.ts x = .retired v d cf → x ≠ o'.s.cur := by
      intro x v d cf hx e1
      have hx' : x ≠ o.s.cur ∧ x < o.s.nextId ∧ x ≠ 0 := hi.ret_ne hx
      rw [hs'] at e1; simp only [publish] at e1; subst e1
      rcases hp with ⟨rfl, _⟩ | ⟨rfl, _, _⟩ | ⟨ht', _⟩
      · omega
      · exact hx'.2.2 rfl
      · rw [hx] at ht'; cases ht'
    have hcell : ∀ x, x ≠ o'.s.cur → allocCell cell o.s.cur o'.s.cur x = cell x :=
      fun x hx => allocCell_other hx
    have hnotran : (⟨o.s.cur, e.base.now, true⟩ : Collect.Cb) ∉ e.base.ran := fun hm => by
      have := (Collect.Flags.reachable_cbInv (Collect.Ev.ereach_base W her)).2.2 _
        (List.mem_append_right _ (List.mem_filter.2 ⟨hm, rfl⟩))
      simp at this
    refine ⟨hi', ?_, ?_, allocCell_new hc, ?_, ?_, fun t ht => ?_⟩
    · intro x hx
      have hx' : x ∈ Collect.Flags.fl e.base ∨ x = ⟨o.s.cur, e.base.now, true⟩ := by
        have : Collect.Flags.fl (deferE e o.s.cur).base =
            Collect.Flags.fl e.base ++ [⟨o.s.cur, e.base.now, true⟩] := by
          simp [Collect.Flags.fl, Collect.Flags.flat, deferE, List.filter_append]
        rw [this] at hx; simpa using hx
      rcases hx' with h1 | rfl
      · obtain ⟨v, d, h2, h3⟩ := hv.queued x h1
        obtain ⟨e2, e3, e0⟩ := hi.ret_ne h2
        have e1 : x.id ≠ o'.s.cur := hnr _ _ _ _ h2
        refine ⟨v, d, by rw [hts]; simp only [e1, e2, ite_false]; exact h2, ?_⟩
        have hd := hj.retLt _ v d false h2
        simp only [flagCb, extend_lt hd] at h3 ⊢; exact h3
      · refine ⟨o.s.ver, o.s.clk, by rw [hts]; simp [Ne.symm hc], ?_⟩
        simp [flagCb, extend_self]
    · intro t v d cf ht
      rw [hts] at ht
      split at ht
      · cases ht
      · rename_i en
        dsimp only
        rw [hcell t en]
        split at ht
        · rename_i e2
          subst e2; cases ht
          rw [show cell o.s.cur = false from hv.cur]
          simp only [flagCb, extend_self, deferE, Bool.false_eq_true, false_iff]
          exact hnotran
        · have hd := hj.retLt t v d cf ht
          simp only [flagCb, extend_lt hd, deferE]
          exact hv.val t v d cf ht
    · intro t v d ht
      rw [hts] at ht
      split at ht
      · cases ht
      · rename_i en
        dsimp only; rw [hcell t en]
        split at ht
        · cases ht
        · exact hv.obs t v d ht
    · dsimp only
      by_cases e0 : (0 : Nat) = o'.s.cur
      · rw [← e0] at hc ⊢
        unfold allocCell; rw [if_neg hc]; simp
      · rw [hcell 0 e0]; exact hv.stat
    · dsimp only
      have : t ≠ o'.s.cur := by have h1 : o'.s.cur < o'.s.nextId := hi'.curLt; have h2 : o'.s.nextId ≤ t := ht; omega
      rw [hcell t this]; exact hv.fresh t (Nat.le_trans hnx ht)
  | markFree s rl e f cell t v d ht hc =>
    have hran := (hv.val t v d false ht).1 hc
    refine ⟨tsI_upd hv.ts ht _, ?_, ?_, hv.cur, ?_, hv.stat, hv.fresh⟩
    · intro x hx
      obtain ⟨v', d', h1, h2⟩ := hv.queued x hx
      by_cases ex : x.id = t
      · exfalso
        rw [ex, ht] at h1; cases h1
        rw [ex] at h2; subst h2
        exact Collect.Flags.fl_not_ran (Collect.Ev.ereach_base W her) hx
          (List.mem_filter.2 ⟨hran, rfl⟩)
      · exact ⟨v', d', by simp only [upd_other _ _ _ _ ex]; exact h1, h2⟩
    · intro x v' d' cf h'
      simp only [upd] at h'
      split at h'
      · rename_i ex; subst ex; cases h'; exact hv.val x v d false ht
      · exact hv.val x v' d' cf h'
    · intro x v' d' h'
      simp only [upd] at h'
      split at h'
      · rename_i ex; subst ex; exact hc
      · exact hv.obs x v' d' h'

theorem creach_vi {c : CSt K V} (h : CReach W C c) : VI c := by
  induction h with
  | init => exact vi_init
  | step hr hs ih => exact vi_step W C hr ih hs

/-- **The former `collect` axiom, proved.** If `collect` has stored table `t`'s flag, then no
reader is pinned from a time at or before `t`'s retirement. This is `Step.markFree`'s premise;
it follows from `Collect.Main.safety` through the link invariant `J`. -/
theorem markFree_premise {c : CSt K V} (h : CReach W C c) (t d : Nat)
    (hran : flagCb c.f t d ∈ c.e.base.ran) :
    ∀ u st, (c.o.s.rd u).start = some st → d < st := by
  intro u st hu
  have hj := creach_j W C h
  have hsafe := Collect.Main.safety (creach_ereach W C h) _ hran u
  have hp := hj.pinned u st hu
  have hlt : c.f d < c.f st := by
    refine Nat.lt_of_not_le fun hle => hsafe ⟨c.f st, 0, hp, hle⟩
  refine Nat.lt_of_not_le fun hle => ?_
  rcases Nat.lt_or_eq_of_le hle with h1 | h1
  · have := hj.mono _ _ h1; omega
  · subst h1; omega

/-- **`can_free` read `true` ⇒ `collect` stored it ⇒ no reader pinned at/before the defer.**
If retired table `t`'s cell holds `true` (what `prune_tables`' `Acquire` load observes), then
`collect`'s `mark_ready` stored its `defer_by_id` flag (the flag callback is in `ran`), and by
`Collect.Main.safety` no reader is pinned from a time at or before `t`'s retirement. -/
theorem can_free_safe {c : CSt K V} (h : CReach W C c) {t v d : Nat} {cf : Bool}
    (ht : c.o.s.ts t = .retired v d cf) (hc : c.cell t = true) :
    flagCb c.f t d ∈ c.e.base.ran ∧ ∀ u st, (c.o.s.rd u).start = some st → d < st := by
  have hran := ((creach_vi W C h).val t v d cf ht).1 hc
  exact ⟨hran, markFree_premise W C h t d hran⟩

/-- **Only `collect` writes `true` to a `can_free` cell**: a composed step that turns a cell from
`false` to `true` is a `collect` step storing through that table's pointer. -/
theorem only_collect_sets_can_free {c c' : CSt K V} (hs : CStep W C c c') {t : Nat}
    (h0 : c.cell t = false) (h1 : c'.cell t = true) :
    EStep W c.e c'.e ∧ t ∈ Collect.Flags.stores c.e.base c'.e.base := by
  cases hs with
  | tbl e f cell cell' ho hl hcl =>
    simp only at h0 h1; subst hcl; rw [allocCell_true h1] at h0; cases h0
  | markFree => simp only at h0 h1; rw [h0] at h1; cases h1
  | swap => simp only at h0 h1; rw [allocCell_true h1] at h0; cases h0
  | pin rl f cell u hidle he =>
    simp only [storeCells] at h0 h1 ⊢
    rcases Collect.Flags.storeAll_true.1 h1 with h | h
    · rw [h0] at h; cases h
    · exact ⟨he, h⟩
  | unpin rl f cell u st hl hrd he =>
    simp only [storeCells] at h0 h1 ⊢
    rcases Collect.Flags.storeAll_true.1 h1 with h | h
    · rw [h0] at h; cases h
    · exact ⟨he, h⟩
  | col o f cell he =>
    simp only [storeCells] at h0 h1 ⊢
    rcases Collect.Flags.storeAll_true.1 h1 with h | h
    · rw [h0] at h; cases h
    · exact ⟨he, h⟩

/-- Every composed step is an ordered table step or a stutter. -/
theorem cstep_o {c c' : CSt K V} (h : CReach W C c) (hs : CStep W C c c') :
    c'.o = c.o ∨ OStep C c.o c'.o := by
  cases hs with
  | tbl _ _ _ _ ho => exact .inr ho
  | pin rl f _ u hidle => exact .inr (OStep.other rl (Step.pin _ u hidle) (.inl rfl) (fun _ h => h))
  | unpin rl f _ u st hl hrd =>
    exact .inr (OStep.other rl (Step.unpin _ u st hl hrd) (.inl rfl) (fun _ h => h))
  | swap _ _ _ ho => exact .inr ho
  | markFree s rl e f cell t v d ht hc =>
    have hran := ((creach_vi W C h).val t v d false ht).1 hc
    refine .inr (OStep.other rl (Step.markFree s t v d ht (markFree_premise W C h t d hran))
      (.inl rfl) ?_)
    intro x hx; simp only [upd] at hx; split at hx
    · cases hx
    · exact hx
  | col => exact .inl rfl

theorem creach_oreach {c : CSt K V} (h : CReach W C c) : OReachable C c.o := by
  induction h with
  | init => exact .init
  | step hr hs ih =>
    rcases cstep_o W C hr hs with e | e
    · rw [e]; exact ih
    · exact .step ih e

/-! ## Headline theorems on the composed model -/

/-- **No use-after-free**, with `collect` modelled instead of assumed. -/
theorem composed_no_use_after_free (hcov : C.Cover) {c : CSt K V} (h : CReach W C c)
    (u t : Nat) (hu : Uses (c.o.s.rd u) t) : c.o.s.ts t ≠ .freed ∧ c.o.s.ts t ≠ .unalloc :=
  ordered_no_use_after_free C hcov (creach_oreach W C h) u t hu

/-- **Linearizable `get`** on the composed model, when the table component is reached by a run
that respects the key contract (`CReachable`; `creach_oreach` gives only `Reachable`, which
also allows duplicate keys and `Step.insertAny` with a mismatched key). -/
theorem composed_get_linearizable (hcov : C.Cover) {c : CSt K V} (hp : CReachable C c.o.s)
    (u st : Nat) (hl : List Nat) (k : K) (t lv : Nat) (r : Option V)
    (hu : c.o.s.rd u = .returned st hl k t lv r) : Lin c.o.s k lv r :=
  ordered_get_linearizable C hcov hp u st hl k t lv r hu

/-- A `get` hit on the composed model is linearizable to the multimap on probe-respecting runs
(`PReachable`), duplicate keys allowed. -/
theorem composed_get_linearizable_some (hcov : C.Cover) {c : CSt K V} (hp : PReachable C c.o.s)
    (u st : Nat) (hl : List Nat) (k : K) (t lv : Nat) (w : V)
    (hu : c.o.s.rd u = .returned st hl k t lv (some w)) : Lin c.o.s k lv (some w) :=
  ordered_get_linearizable_some C hcov hp u st hl k t lv w hu

/-- Retired tables are frozen on the composed model. -/
theorem composed_retired_frozen (hcov : C.Cover) {c c' : CSt K V} (h : CReach W C c)
    (hs : CStep W C c c') (t : Nat) (ht : c.o.s.ts t ≠ .live) (hf : c.o.s.ts t ≠ .freed)
    (hlt : t < c.o.s.nextId) : c'.o.s.tables t = c.o.s.tables t := by
  rcases cstep_o W C h hs with e | e
  · rw [e]
  · exact ordered_retired_frozen C hcov (creach_oreach W C h) e t ht hf hlt

/-- **The static empty table is never retired or freed** on the composed model. -/
theorem static_never_freed {c : CSt K V} (h : CReach W C c) : c.o.s.ts 0 = .live :=
  (creach_vi W C h).ts.stat

/-- **The static empty table's `can_free` is always `false`**: nothing ever stores `true` to it
(it is never registered with `defer_by_id`, see `Flags.static_never_deferred`). -/
theorem static_can_free_false {c : CSt K V} (h : CReach W C c) : c.cell 0 = false :=
  (creach_vi W C h).stat

/-- **The static empty table is the retired list's sentinel.** Rust's `retired_head` is
`TableInfoRef::empty()` (id `0`) when the list is empty, and `try_prune_tables`/`prune_tables`
read its `can_free`; it is `false`, so the loop only ever pops a real retired table, never the
sentinel. -/
theorem prune_sentinel (hcov : C.Cover) {c : CSt K V} (h : CReach W C c)
    (hc : c.cell (c.o.rl.headD 0) = true) :
    ∃ t rest, c.o.rl = t :: rest ∧ t ≠ 0 ∧ ∃ v d cf, c.o.s.ts t = .retired v d cf := by
  have hstat := static_can_free_false W C h
  cases hrl : c.o.rl with
  | nil => rw [hrl] at hc; simp only [List.headD] at hc; rw [hstat] at hc; cases hc
  | cons t rest =>
    have hm : t ∈ c.o.rl := by rw [hrl]; exact List.mem_cons_self
    refine ⟨t, rest, rfl, fun e => static_not_mem C hcov (creach_oreach W C h) (e ▸ hm), ?_⟩
    exact ((rlInv C hcov (creach_oreach W C h)).mem t).1 hm

/-- `collect`'s own safety theorem holds on the composed model's `collect` component. -/
theorem composed_collect_safety {c : CSt K V} (h : CReach W C c) (cb : Collect.Cb)
    (hc : cb ∈ c.e.base.ran) (u : Collect.Tid) : ¬ Collect.blocked c.e.base.loc cb u :=
  Collect.Main.safety (creach_ereach W C h) cb hc u

/-! ## Reclamation liveness -/

/-- A `collect` step that keeps every queued flag. -/
def KStep (e e' : ESt) : Prop := EStep W e e' ∧ KeepFlags e e'

inductive KSteps : ESt → ESt → Prop
  | refl (e) : KSteps e e
  | tail {a b c} : KSteps a b → KStep W b c → KSteps a c

/-- **`collect` liveness**, restricted to flag-keeping schedules: from any reachable state of
the primary `collect` model, some schedule that does not drop queued `defer_by_id` flags (i.e. no
`cancel_by_ids` of them) runs a queued callback. Proved for `1 < W` (`collect_live`, from
`Collect.Ev.eventually_ran_keep`). -/
def CollectLive : Prop :=
  ∀ e, EReach W e → ∀ cb ∈ Collect.bufs e.base, ∃ e', KSteps W e e' ∧ cb ∈ e'.base.ran

theorem ksteps_of_collect {e e' : ESt} (h : Collect.Ev.KSteps W e e') : KSteps W e e' := by
  induction h with
  | refl => exact .refl _
  | tail _ s k ih => exact .tail ih ⟨s, k.1, k.2⟩

/-- `collect` liveness holds: `Collect.Ev.eventually_ran_keep` (the drain schedule of
`eventually_ran_events`, which never cancels a flag). -/
theorem collect_live (hW : 1 < W) : CollectLive W := fun _ he cb hcb =>
  (Collect.Ev.eventually_ran_keep W he hW cb hcb).imp fun _ h => ⟨ksteps_of_collect W h.1, h.2⟩

/-- With every reader idle, `collect` runs lift to composed runs. -/
theorem lift_ksteps (o : OSt K V) (f : Nat → Nat) (cell : Nat → Bool)
    (hidle : ∀ u, o.s.rd u = .idle) {e e' : ESt}
    (h : KSteps W e e') : ∃ cell', CSteps W C ⟨o, e, f, cell⟩ ⟨o, e', f, cell'⟩ := by
  induction h with
  | refl => exact ⟨cell, .refl _⟩
  | tail _ hs ih =>
    obtain ⟨c1, h1⟩ := ih
    exact ⟨_, .tail h1 (CStep.col o f c1 hs.1 hs.2 (fun u hu => absurd (hidle u) hu))⟩

/-- A reader-only table step is a composed step. -/
theorem reader_cstep {s : St K V} (rl : List Nat) (e : ESt) (f : Nat → Nat) (cell : Nat → Bool)
    (u : Nat) (r : RS K V)
    (hs : Step C s (setRd s u r)) (hst : r.start = (s.rd u).start) :
    CStep W C ⟨⟨s, rl⟩, e, f, cell⟩ ⟨⟨setRd s u r, rl⟩, e, f, cell⟩ := by
  refine CStep.tbl e f cell cell (OStep.other rl hs (.inl rfl) (fun _ h => h))
    ⟨rfl, ?_, fun _ _ _ _ h => h⟩ (allocCell_eq rfl).symm
  intro x; simp only [setRd]; by_cases e1 : x = u
  · subst e1; rw [upd_same, hst]
  · rw [upd_other _ _ _ _ e1]

theorem unpin_from {s : St K V} (rl : List Nat) (e : ESt) (f : Nat → Nat) (cell : Nat → Bool)
    (u st : Nat)
    (hl : List Nat) (hrd : s.rd u = .pinned st hl) (hp : e.base.loc u = .pinned (f st) 0)
    (hf : e.fpend u = false) :
    ∃ e' cell', CStep W C ⟨⟨s, rl⟩, e, f, cell⟩ ⟨⟨setRd s u .idle, rl⟩, e', f, cell'⟩ :=
  ⟨_, _, CStep.unpin rl f cell u st hl hrd (EStep.unpinOuter e u (f st) hp hf)
    ⟨fun _ _ h => by simpa [Collect.bufs] using h, fun _ _ h => by simpa [Collect.bufs] using h⟩
    rfl⟩

/-- A pinned reader can unpin (after `pin_cold`'s pending forced store, if any). -/
theorem unpin_ok {c : CSt K V} (h : CReach W C c) (u st : Nat) (hl : List Nat)
    (hrd : c.o.s.rd u = .pinned st hl) :
    ∃ c', CSteps W C c c' ∧ c'.o.s = setRd c.o.s u .idle ∧ c'.o.rl = c.o.rl := by
  obtain ⟨⟨s, rl⟩, e, f, cell⟩ := c
  have hp := (creach_j W C h).pinned u st (by simp only at hrd ⊢; rw [hrd]; rfl)
  simp only at hrd hp
  cases hfp : e.fpend u with
  | false =>
    obtain ⟨e', _, hs⟩ := unpin_from W C rl e f cell u st hl hrd hp hfp
    exact ⟨_, .tail (.refl _) hs, rfl, rfl⟩
  | true =>
    have h1 := CStep.col (W := W) (C := C) ⟨s, rl⟩ f cell (EStep.pinForce e u hfp)
      ⟨fun _ _ h => h, fun _ _ h => h⟩ (fun _ _ => rfl)
    obtain ⟨e', _, hs⟩ := unpin_from W C rl
      { Collect.Ev.setSeen e u ((Collect.Ev.events W e - 1) % W) (e.total - 1) with
          fpend := Collect.upd e.fpend u false } f _ u st hl hrd hp (by simp)
    exact ⟨_, .tail (.tail (.refl _) h1) hs, rfl, rfl⟩

/-- A reader can finish its operation and unpin, without touching tables or other readers. -/
theorem drain_reader (u : Nat) : ∀ n (c : CSt K V), CReach W C c → rsm (c.o.s.rd u) ≤ n →
    ∃ c', CSteps W C c c' ∧ c'.o.s.rd u = .idle ∧ (∀ x, x ≠ u → c'.o.s.rd x = c.o.s.rd x) ∧
      c'.o.s.ts = c.o.s.ts ∧ c'.o.rl = c.o.rl := by
  intro n
  induction n with
  | zero =>
    intro c _ hm
    refine ⟨c, .refl _, ?_, fun _ _ => rfl, rfl, rfl⟩
    cases e : c.o.s.rd u <;> rw [e] at hm <;> simp [rsm] at hm ⊢
  | succ n ih =>
    intro c hc hm
    obtain ⟨⟨s, rl⟩, e, f, cell⟩ := c
    simp only at hm ⊢
    have go : ∀ r : RS K V, Step C s (setRd s u r) → r.start = (s.rd u).start → rsm r ≤ n →
        ∃ c', CSteps W C ⟨⟨s, rl⟩, e, f, cell⟩ c' ∧ c'.o.s.rd u = .idle ∧
          (∀ x, x ≠ u → c'.o.s.rd x = s.rd x) ∧ c'.o.s.ts = s.ts ∧ c'.o.rl = rl := by
      intro r hs hst hr
      have h1 := reader_cstep W C rl e f cell u r hs hst
      obtain ⟨c', h2, h3, h4, h5, h6⟩ := ih _ (.step hc h1) (by simp [setRd, hr])
      refine ⟨c', csteps_trans W C (.tail (.refl _) h1) h2, h3, fun x hx => ?_, h5, h6⟩
      rw [h4 x hx]; exact upd_other _ _ _ _ hx
    cases es : s.rd u with
    | idle => exact ⟨_, .refl _, es, fun _ _ => rfl, rfl, rfl⟩
    | pinned st hl =>
      obtain ⟨c', h1, h2, h3⟩ := unpin_ok W C hc u st hl es
      simp only at h2 h3
      refine ⟨c', h1, by rw [h2]; simp [setRd], fun x hx => by rw [h2]; exact upd_other _ _ _ _ hx,
        by rw [h2]; rfl, h3⟩
    | returned st hl k t lv r =>
      rw [es] at hm
      exact go _ (Step.finish s u st hl k t lv r es) (by simp [es, RS.start]) (by simp [rsm] at hm ⊢; omega)
    | probing st hl k t lv pre rest =>
      rw [es] at hm; simp only [rsm] at hm
      cases rest with
      | nil => exact go _ (Step.probeEnd s u st hl k t lv pre es) (by simp [es, RS.start]) (by simp [rsm] at hm ⊢; omega)
      | cons j rest =>
        exact go _ (Step.probeGroup s u st hl k t lv pre [j] rest es (by simp)) (by simp [es, RS.start])
          (by simp [rsm] at hm ⊢; omega)
    | scanning st hl k t lv pre g todo obs rest =>
      rw [es] at hm; simp only [rsm] at hm
      cases todo with
      | cons j todo =>
        exact go _ (Step.scanLoad s u st hl k t lv pre g (j :: todo) obs rest j es (by simp)) (by simp [es, RS.start])
          (by simp [rsm] at hm ⊢; omega)
      | nil =>
        by_cases hm' : ∃ i w, (i, Slot.full k w) ∈ obs
        · obtain ⟨i, w, hi⟩ := hm'
          exact go _ (Step.scanHit s u st hl k t lv pre g obs rest i w es hi) (by simp [es, RS.start])
            (by simp [rsm] at hm ⊢; omega)
        · have hm'' : ∀ i w, (i, Slot.full k w) ∉ obs := fun i w hi => hm' ⟨i, w, hi⟩
          by_cases he : ∃ i, (i, Slot.empty) ∈ obs
          · obtain ⟨i, hi⟩ := he
            exact go _ (Step.scanEmpty s u st hl k t lv pre g obs rest i es hm'' hi) (by simp [es, RS.start])
              (by simp [rsm] at hm ⊢; omega)
          · exact go _ (Step.scanNext s u st hl k t lv pre g obs rest es hm''
              (fun i hi => he ⟨i, hi⟩)) (by simp [es, RS.start]) (by simp [rsm] at hm ⊢; omega)

/-- Every reader can be driven back to `idle`. -/
theorem quiesce : ∀ N (c : CSt K V), CReach W C c → (∀ u, N ≤ u → c.o.s.rd u = .idle) →
    ∃ c', CSteps W C c c' ∧ (∀ u, c'.o.s.rd u = .idle) ∧ c'.o.s.ts = c.o.s.ts ∧ c'.o.rl = c.o.rl := by
  intro N
  induction N with
  | zero => intro c _ h; exact ⟨c, .refl _, fun u => h u (Nat.zero_le _), rfl, rfl⟩
  | succ N ih =>
    intro c hc h
    obtain ⟨c1, h1, h2, h3, h4, h5⟩ := drain_reader W C N _ c hc (Nat.le_refl _)
    obtain ⟨c2, h6, h7, h8, h9⟩ := ih c1 (csteps_reach W C hc h1) (by
      intro u hu
      by_cases e : u = N
      · subst e; exact h2
      · rw [h3 u e]; exact h u (by omega))
    exact ⟨c2, csteps_trans W C h1 h6, h7, by rw [h8, h4], by rw [h9, h5]⟩

/-- With all readers idle, `collect` and `prune_tables` drain the retired list up to `t`. -/
theorem drain_prefix (hcov : C.Cover) (hlive : CollectLive W) (t : Nat) :
    ∀ n (c : CSt K V), CReach W C c → (∀ u, c.o.s.rd u = .idle) → c.o.rl.length ≤ n →
      t ∈ c.o.rl → ∃ c', CSteps W C c c' ∧ c'.o.s.ts t = .freed := by
  intro n
  induction n with
  | zero => intro c _ _ hl ht; cases hrl : c.o.rl with
    | nil => rw [hrl] at ht; cases ht
    | cons => rw [hrl] at hl; simp at hl
  | succ n ih =>
    intro c hc hidle hl ht
    obtain ⟨⟨s, rl⟩, e, f, cell⟩ := c
    have hI := rlInv C hcov (creach_oreach W C hc)
    simp only at hidle hl ht hI
    cases rl with
    | nil => cases ht
    | cons hd rest =>
      obtain ⟨vh, dh, cf, ehd⟩ := (hI.mem hd).1 (List.mem_cons_self ..)
      -- `collect` stores the head's flag, then `prune_tables` reads the cell as `true`
      obtain ⟨s1, e1, cell1, hst1, hr1, h1hd, h1o, h1rd⟩ : ∃ (s1 : St K V) (e1 : ESt) (cell1 : Nat → Bool),
          CSteps W C ⟨⟨s, hd :: rest⟩, e, f, cell⟩ ⟨⟨s1, hd :: rest⟩, e1, f, cell1⟩ ∧
          CReach W C ⟨⟨s1, hd :: rest⟩, e1, f, cell1⟩ ∧ s1.ts hd = .retired vh dh true ∧
          (∀ x, x ≠ hd → s1.ts x = s.ts x) ∧ s1.rd = s.rd := by
        cases cf with
        | true => exact ⟨s, e, cell, .refl _, hc, ehd, fun _ _ => rfl, rfl⟩
        | false =>
          obtain ⟨e1, cell1, hs1, hran⟩ : ∃ e1 cell1, CSteps W C ⟨⟨s, hd :: rest⟩, e, f, cell⟩
              ⟨⟨s, hd :: rest⟩, e1, f, cell1⟩ ∧ flagCb f hd dh ∈ e1.base.ran := by
            rcases (creach_j W C hc).flag hd vh dh ehd with hb | hb
            · obtain ⟨e1, hk, hr⟩ := hlive e (creach_ereach W C hc) _ hb
              obtain ⟨cell1, hl⟩ := lift_ksteps W C ⟨s, hd :: rest⟩ f cell hidle hk
              exact ⟨e1, cell1, hl, hr⟩
            · exact ⟨e, cell, .refl _, hb⟩
          have hcell : cell1 hd = true :=
            ((creach_vi W C (csteps_reach W C hc hs1)).val hd vh dh false ehd).2 hran
          have hm := CStep.markFree (W := W) (C := C) s (hd :: rest) e1 f cell1 hd vh dh ehd hcell
          have hs2 := CSteps.tail hs1 hm
          exact ⟨_, e1, cell1, hs2, csteps_reach W C hc hs2, upd_same _ _ _,
            fun x e => upd_other _ _ _ _ e, rfl⟩
      have hpop : CStep W C ⟨⟨s1, hd :: rest⟩, e1, f, cell1⟩
          ⟨⟨{ s1 with ts := upd s1.ts hd .freed }, rest⟩, e1, f, cell1⟩ := by
        refine CStep.tbl e1 f cell1 cell1 (OStep.pruneHead s1 hd vh dh rest h1hd)
          ⟨rfl, fun _ => rfl, ?_⟩ (allocCell_eq rfl).symm
        intro x v d cf hx; simp only [upd] at hx; split at hx
        · cases hx
        · exact hx
      have hst2 := CSteps.tail hst1 hpop
      by_cases et : t = hd
      · subst et; exact ⟨_, hst2, upd_same _ _ _⟩
      · have htr : t ∈ rest := by
          rcases List.mem_cons.1 ht with e' | e'
          · exact absurd e' et
          · exact e'
        obtain ⟨c', h3, h4⟩ := ih _ (.step hr1 hpop)
          (by intro u; show s1.rd u = _; rw [h1rd]; exact hidle u)
          (by simp at hl; simpa using hl) htr
        exact ⟨c', csteps_trans W C hst2 h3, h4⟩

/-- **Reclamation liveness on the composed model**: every
retired table is freed by some schedule that respects the FIFO pruning order. Drain every
reader (each unpin is a joint `collect` step), let `collect` store the flags of `t` and every
older table, and pop the list up to `t`. -/
theorem composed_retired_eventually_freed (hcov : C.Cover) (hW : 1 < W)
    {c : CSt K V} (h : CReach W C c) (t v d : Nat) (cf : Bool)
    (ht : c.o.s.ts t = .retired v d cf) : ∃ c', CSteps W C c c' ∧ c'.o.s.ts t = .freed := by
  obtain ⟨N, hN⟩ := rd_finite C (oreachable_reachable C (creach_oreach W C h))
  obtain ⟨c1, h1, h2, h3, _⟩ := quiesce W C N c h hN
  have hr1 := csteps_reach W C h h1
  have htm : t ∈ c1.o.rl :=
    (rlInv C hcov (creach_oreach W C hr1)).mem t |>.2 ⟨v, d, cf, by rw [h3]; exact ht⟩
  obtain ⟨c2, h5, h6⟩ := drain_prefix W C hcov (collect_live W hW) t _ c1 hr1 h2 (Nat.le_refl _) htm
  exact ⟨c2, csteps_trans W C h1 h5, h6⟩

end Composed
end SyncTable
