import SyncTable.Contract

/-!
# Ordered retired list (faithful pruning order)

`Step.prune` in `Model.lean` frees *any* retired table whose `can_free` is set. Rust keeps the
retired tables in a FIFO linked list (`retired_head`/`retired_tail`/`next_retired`):
`replace_table` appends the old `current` at the tail, and `prune_tables` pops the head only
while the head's `can_free` is set:

```rust
while head.get().info().can_free.load(Ordering::Acquire) {
    let table = head.get();
    head.set(table.info().next_retired.get());
    ...
    TableRef::<(K, V)>::from(table).free();
}
```

This file refines the model with the list `OSt.rl`:

* `OStep.swap`: `replace_table` (`Step.expand`/`Step.replace`/`Step.replaceEmpty`) appends the
  old `current`, unless it is the static empty table (id `0`): then `replace_table` returns early
  and the step is an `OStep.other`. The static table is never in the list (`static_not_mem`);
  it is the list's end sentinel in Rust (`retired_head` is `TableInfoRef::empty()` when the list
  is empty, and its `can_free` stays `false`, see `Composed.prune_sentinel`).
* `OStep.pruneHead`: one iteration of the `prune_tables` loop frees the head, and only if its
  `can_free` is set. The whole loop is a run of these steps (the writer holds the lock, and a
  concurrent `collect` setting another flag mid-loop is an interleaved `markFree`).
* `OStep.other`: every other `Step` that frees nothing and keeps `current`.

`ostep_step` shows every `OStep` is a `Step` (the ordered model refines the old one), so all
safety and linearizability theorems carry over (`ordered_*` below; the safety ones on every
run, `ordered_get_linearizable` on runs whose table run respects the key contract, `ordered_get_linearizable_some` on probe-respecting runs). `rlInv` shows that the
list holds exactly the retired tables, in strictly increasing `defer` time.

Liveness: `ordered_retired_eventually_freed` (and the unordered `retired_eventually_freed`) are
proved for the weak "some schedule" form. Head-of-line blocking exists (a table is freed only
after every older one) but adds no extra waiting on readers: defer times increase along the
list, so any pinned reader that blocks an older table (start `≤` its `d`) also blocks every
younger one. The only extra dependence is that `collect` must also set the older tables' flags
(`drain_prefix` does exactly that with `markFree` before popping).
-/

set_option linter.unusedSectionVars false
set_option linter.deprecated false

namespace SyncTable

variable {K V : Type} [DecidableEq K] (C : Cfg K)

/-- Concurrent state plus the retired list, head first. -/
structure OSt (K V : Type) where
  s : St K V
  rl : List Nat

inductive OStep : OSt K V → OSt K V → Prop
  /-- any step that frees nothing and keeps `current` (writer `insert`/`remove`, `markFree`,
  reader steps) or replaces the static empty table (`replace_table`'s early return: nothing is
  retired) -/
  | other {s s' : St K V} (rl : List Nat) : Step C s s' → (s'.cur = s.cur ∨ s.cur = 0) →
      (∀ t, s'.ts t = .freed → s.ts t = .freed) → OStep ⟨s, rl⟩ ⟨s', rl⟩
  /-- `replace_table` of a table other than the static one: the old `current` goes to the tail
  of the retired list -/
  | swap {s s' : St K V} (rl : List Nat) : Step C s s' → s'.cur ≠ s.cur → s.cur ≠ 0 →
      OStep ⟨s, rl⟩ ⟨s', rl ++ [s.cur]⟩
  /-- one iteration of the `prune_tables` loop: pop and free the head if `can_free` is set -/
  | pruneHead (s : St K V) (t v d : Nat) (rest : List Nat) : s.ts t = .retired v d true →
      OStep ⟨s, t :: rest⟩ ⟨{ s with ts := upd s.ts t .freed }, rest⟩

def oinit : OSt K V := ⟨init, []⟩

inductive OReachable : OSt K V → Prop
  | init : OReachable oinit
  | step {o o'} : OReachable o → OStep C o o' → OReachable o'

inductive OSteps : OSt K V → OSt K V → Prop
  | refl (o) : OSteps o o
  | tail {a b c} : OSteps a b → OStep C b c → OSteps a c

theorem osteps_trans {a b c : OSt K V} (h1 : OSteps C a b) (h2 : OSteps C b c) :
    OSteps C a c := by
  induction h2 with
  | refl => exact h1
  | tail _ hs ih => exact OSteps.tail ih hs

theorem osteps_single {a b : OSt K V} (h : OStep C a b) : OSteps C a b :=
  OSteps.tail (OSteps.refl a) h

theorem osteps_reach {a b : OSt K V} (ha : OReachable C a) (h : OSteps C a b) :
    OReachable C b := by
  induction h with
  | refl => exact ha
  | tail _ hs ih => exact OReachable.step ih hs

/-! ## Refinement -/

/-- Every ordered step is a step of the original model. -/
theorem ostep_step {o o' : OSt K V} (h : OStep C o o') : Step C o.s o'.s := by
  cases h with
  | other _ hs => exact hs
  | swap _ hs => exact hs
  | pruneHead s t v d rest ht => exact Step.prune s t v d ht

theorem osteps_steps {o o' : OSt K V} (h : OSteps C o o') : Steps C o.s o'.s := by
  induction h with
  | refl => exact Steps.refl _
  | tail _ hs ih => exact Steps.tail ih (ostep_step C hs)

theorem oreachable_reachable {o : OSt K V} (h : OReachable C o) : Reachable C o.s := by
  induction h with
  | init => exact Reachable.init
  | step _ hs ih => exact Reachable.step ih (ostep_step C hs)

/-! ## Carried-over safety and linearizability -/

theorem ordered_sinv (hcov : C.Cover) {o : OSt K V} (h : OReachable C o) : SInv C o.s :=
  reachable_sinv C hcov (oreachable_reachable C h)

theorem ordered_no_use_after_free (hcov : C.Cover) {o : OSt K V} (h : OReachable C o)
    (u t : Nat) (hu : Uses (o.s.rd u) t) : o.s.ts t ≠ .freed ∧ o.s.ts t ≠ .unalloc :=
  no_use_after_free C hcov (oreachable_reachable C h) u t hu

/-- `get_linearizable` for a state whose table component is reached by a run that respects the
key contract (`CReachable`: unique keys, and every `PotentialSlot::insert_new` used with its own
key). -/
theorem ordered_get_linearizable (hcov : C.Cover) {o : OSt K V} (hp : CReachable C o.s)
    (u st : Nat) (hl : List Nat) (k : K) (t lv : Nat) (r : Option V)
    (hu : o.s.rd u = .returned st hl k t lv r) : Lin o.s k lv r :=
  get_linearizable C hcov hp u st hl k t lv r hu

/-- `get_linearizable_some` (a hit, multimap) on a probe-respecting run (`PReachable`). -/
theorem ordered_get_linearizable_some (hcov : C.Cover) {o : OSt K V} (hp : PReachable C o.s)
    (u st : Nat) (hl : List Nat) (k : K) (t lv : Nat) (w : V)
    (hu : o.s.rd u = .returned st hl k t lv (some w)) : Lin o.s k lv (some w) :=
  get_linearizable_some C hcov hp u st hl k t lv w hu

theorem ordered_retired_frozen (hcov : C.Cover) {o o' : OSt K V} (h : OReachable C o)
    (hs : OStep C o o') (t : Nat) (ht : o.s.ts t ≠ .live) (hf : o.s.ts t ≠ .freed)
    (hlt : t < o.s.nextId) : o'.s.tables t = o.s.tables t :=
  retired_frozen C (ordered_sinv C hcov h) (ostep_step C hs) t ht hf hlt

theorem ordered_potential_step (hcov : C.Cover) {o o' : OSt K V} (h : OReachable C o)
    (hs : OStep C o o') {t : Nat} {k : K} {idx : Nat} (hp : PotP C o.s t k idx)
    (he : (o'.s.tables t).slot idx = .empty) (hnf : o'.s.ts t ≠ .freed) : PotP C o'.s t k idx :=
  potential_step C (ordered_sinv C hcov h) (ostep_step C hs) hp he hnf

/-! ## The retired list invariant -/

/-- `some d` for a retired table deferred at `d`. -/
def rkey : TS → Option Nat
  | .retired _ d _ => some d
  | _ => none

def dOf (x : TS) : Nat := (rkey x).getD 0

theorem rkey_isSome {x : TS} : (rkey x).isSome ↔ ∃ v d cf, x = .retired v d cf := by
  cases x <;> simp [rkey]

/-- The list is exactly the set of retired tables, ordered by strictly increasing `defer`
time (hence without duplicates). -/
structure RLInv (o : OSt K V) : Prop where
  mem : ∀ t, t ∈ o.rl ↔ ∃ v d cf, o.s.ts t = .retired v d cf
  sorted : o.rl.Pairwise (fun a b => dOf (o.s.ts a) < dOf (o.s.ts b))

theorem rlInv_congr {s s' : St K V} {rl : List Nat} (hk : ∀ t, rkey (s'.ts t) = rkey (s.ts t))
    (h : RLInv (⟨s, rl⟩ : OSt K V)) : RLInv (⟨s', rl⟩ : OSt K V) := by
  refine ⟨fun t => ?_, ?_⟩
  · rw [← rkey_isSome, hk, rkey_isSome]; exact h.mem t
  · have := h.sorted; simp only [dOf, hk] at this ⊢; exact this

/-- The table `replace_table` publishes was not retired: it is fresh, the static one, or at a
freed address. -/
theorem pub_not_retired {s : St K V} (h : SInv C s) {t : Nat} {T' : Table K V} {nx : Nat}
    (hp : PubOK s t T' nx) : rkey (s.ts t) = none := by
  rcases hp with ⟨rfl, _⟩ | ⟨rfl, _, _⟩ | ⟨ht, _⟩
  · rw [h.fresh _ (Nat.le_refl _)]; rfl
  · rw [h.stat]; rfl
  · rw [ht]; rfl

/-- The table `replace_table` publishes is not the old `current` unless it is the static one. -/
theorem pub_ne_cur {s : St K V} (h : SInv C s) {t : Nat} {T' : Table K V} {nx : Nat}
    (hp : PubOK s t T' nx) (hc : t = s.cur) : s.cur = 0 := by
  rcases hp with ⟨rfl, _⟩ | ⟨rfl, _, _⟩ | ⟨ht, _⟩
  · exact absurd hc (Nat.ne_of_gt h.curLt)
  · exact hc.symm
  · rw [hc, h.curLive] at ht; cases ht

theorem rlInv_init : RLInv (oinit : OSt K V) := by
  refine ⟨fun t => ?_, List.Pairwise.nil⟩
  simp [oinit, init]; intro v d; split <;> simp

theorem rlInv_step (hcov : C.Cover) {o o' : OSt K V} (hr : OReachable C o) (h : RLInv o)
    (hs : OStep C o o') : RLInv o' := by
  have hi := ordered_sinv C hcov hr
  cases hs with
  | other rl hs hcur hfr =>
    rename_i s s'
    apply rlInv_congr _ h
    -- `replace_table` of the static table: nothing is retired
    have pub : ∀ t T' nx ch, PubOK s t T' nx → (t = s.cur ∨ s.cur = 0) →
        ∀ x, rkey ((publish s t T' nx ch).ts x) = rkey (s.ts x) := by
      intro t T' nx ch hp hc x
      have hc0 : s.cur = 0 := by
        rcases hc with e | e
        · exact pub_ne_cur C hi hp e
        · exact e
      rw [publish_ts, retire_cur0 hc0]; split
      · rename_i e; subst e; rw [pub_not_retired C hi hp]; rfl
      · rfl
    cases hs with
    | expand => exact pub _ _ _ _ (swap_pub _ _) hcur
    | replace => exact pub _ _ _ _ (swap_pub _ _) hcur
    | expandAt m a ha => exact pub _ _ _ _ (swapAt_pub _ ha) hcur
    | replaceAt m a l ha => exact pub _ _ _ _ (swapAt_pub _ ha) hcur
    | replaceEmpty => exact pub _ _ _ _ (swapEmpty_pub _) hcur
    | prune t v d ht =>
      have := hfr t (upd_same _ _ _); rw [ht] at this; cases this
    | markFree t v d ht =>
      intro x; show rkey (upd _ t _ x) = _
      by_cases e : x = t
      · subst e; rw [upd_same, ht]; rfl
      · rw [upd_other _ _ _ _ e]
    | _ => intro; rfl
  | swap rl hs hcur hc0 =>
    rename_i s s'
    have key : ∀ t T' nx ch, PubOK s t T' nx →
        RLInv (⟨publish s t T' nx ch, rl ++ [s.cur]⟩ : OSt K V) := by
      intro t T' nx ch hp
      have hne : s.cur ≠ t := fun e => hc0 (pub_ne_cur C hi hp e.symm)
      have hnr : ∀ x ∈ rl, x ≠ s.cur ∧ x ≠ t := by
        intro x hx
        obtain ⟨v, d, cf, e⟩ := (h.mem x).1 hx
        refine ⟨fun h' => ?_, fun h' => ?_⟩
        · subst h'; rw [hi.curLive] at e; cases e
        · subst h'; have := pub_not_retired C hi hp; rw [e] at this; cases this
      have hts : ∀ x, (publish s t T' nx ch).ts x =
          if x = t then .live else if x = s.cur then .retired s.ver s.clk false
          else s.ts x := by
        intro x; rw [publish_ts]; unfold retire; simp only [hc0, ne_eq, not_false_eq_true, and_true]
      refine ⟨fun x => ?_, ?_⟩
      · simp only [hts, List.mem_append, List.mem_singleton]
        by_cases e1 : x = t
        · subst e1; simp only [if_pos]
          constructor
          · rintro (hx | hx)
            · exact absurd rfl (hnr _ hx).2
            · exact absurd hx.symm hne
          · rintro ⟨_, _, _, e⟩; cases e
        · rw [if_neg e1]
          by_cases e2 : x = s.cur
          · subst e2; simp
          · rw [if_neg e2]; simp only [e2, or_false]; exact h.mem x
      · show List.Pairwise _ (rl ++ [s.cur])
        rw [List.pairwise_append]
        refine ⟨?_, List.pairwise_singleton _ _, ?_⟩
        · refine List.Pairwise.imp_of_mem ?_ h.sorted
          intro a b ha hb hab
          rw [hts, hts, if_neg (hnr a ha).2, if_neg (hnr a ha).1, if_neg (hnr b hb).2,
            if_neg (hnr b hb).1]; exact hab
        · intro a ha b hb
          rw [List.mem_singleton] at hb; subst hb
          rw [hts, hts, if_neg (hnr a ha).2, if_neg (hnr a ha).1, if_neg hne, if_pos rfl]
          obtain ⟨v, d, cf, e⟩ := (h.mem a).1 ha
          rw [e]; exact hi.ret _ _ _ _ e
    cases hs with
    | expand => exact key _ _ _ _ (swap_pub _ _)
    | replace => exact key _ _ _ _ (swap_pub _ _)
    | expandAt m a ha => exact key _ _ _ _ (swapAt_pub _ ha)
    | replaceAt m a l ha => exact key _ _ _ _ (swapAt_pub _ ha)
    | replaceEmpty => exact key _ _ _ _ (swapEmpty_pub _)
    | _ => exact absurd rfl hcur
  | pruneHead s t v d rest ht =>
    have hsorted := h.sorted
    rw [List.pairwise_cons] at hsorted
    have htn : t ∉ rest := fun hm => Nat.lt_irrefl _ (hsorted.1 t hm)
    have hne : ∀ x ∈ rest, x ≠ t := fun x hx e => htn (e ▸ hx)
    refine ⟨fun x => ?_, ?_⟩
    · show x ∈ rest ↔ ∃ v d cf, upd s.ts t .freed x = .retired v d cf
      by_cases e : x = t
      · subst e; rw [upd_same]; simp only [htn, false_iff]; rintro ⟨_, _, _, e⟩; cases e
      · rw [upd_other _ _ _ _ e, ← h.mem x]; simp [e]
    · show rest.Pairwise (fun a b => dOf (upd s.ts t .freed a) < dOf (upd s.ts t .freed b))
      refine List.Pairwise.imp_of_mem ?_ hsorted.2
      intro a b ha hb hab
      rw [upd_other _ _ _ _ (hne a ha), upd_other _ _ _ _ (hne b hb)]; exact hab

theorem rlInv (hcov : C.Cover) {o : OSt K V} (h : OReachable C o) : RLInv o := by
  induction h with
  | init => exact rlInv_init
  | step hr hs ih => exact rlInv_step C hcov hr ih hs

/-- **The static empty table is never in the retired list** (so `prune_tables` never frees it). -/
theorem static_not_mem (hcov : C.Cover) {o : OSt K V} (h : OReachable C o) : 0 ∉ o.rl := by
  intro hm
  obtain ⟨v, d, cf, e⟩ := ((rlInv C hcov h).mem 0).1 hm
  rw [(ordered_sinv C hcov h).stat] at e; cases e

/-- Faithfulness: the only way an ordered step frees a table is popping the list head. -/
theorem ordered_frees_head {o o' : OSt K V} (hs : OStep C o o') (t : Nat)
    (h1 : o.s.ts t ≠ .freed) (h2 : o'.s.ts t = .freed) : o.rl = t :: o'.rl := by
  cases hs with
  | other _ _ _ hfr => exact absurd (hfr t h2) h1
  | swap rl hs hc =>
    exfalso; apply h1
    cases hs with
    | expand | replace | replaceEmpty | expandAt | replaceAt => exact publish_freed h2
    | _ => exact absurd rfl hc
  | pruneHead s t' v d rest ht =>
    by_cases e : t = t'
    · subst e; rfl
    · exact absurd (by simpa [upd, e] using h2) h1

/-! ## Liveness -/

/-- Pruning drains the list up to and including `t` once no pinned reader started at or
before `t`'s defer time: `collect` marks every older table (their defer times are smaller, so
`markFree` is enabled) and `prune_tables` pops them in order. -/
theorem drain_prefix (hcov : C.Cover) (t : Nat) :
    ∀ n (o : OSt K V), o.rl.length ≤ n → OReachable C o → t ∈ o.rl →
      (∀ u st, (o.s.rd u).start = some st → dOf (o.s.ts t) < st) →
      ∃ o', OSteps C o o' ∧ o'.s.ts t = .freed := by
  intro n
  induction n with
  | zero => intro o hl _ ht _; cases hrl : o.rl with
    | nil => rw [hrl] at ht; cases ht
    | cons => rw [hrl] at hl; simp at hl
  | succ n ih =>
    intro o hl hr ht hrd
    obtain ⟨s, rl⟩ := o
    have hI := rlInv C hcov hr
    cases rl with
    | nil => cases ht
    | cons hd rest =>
      obtain ⟨vh, dh, cf, ehd⟩ := (hI.mem hd).1 (List.mem_cons_self ..)
      dsimp only at hl ht hrd ehd
      have hdh : dOf (s.ts hd) = dh := by simp [dOf, rkey, ehd]
      have hdle : dh ≤ dOf (s.ts t) := by
        have hs := hI.sorted
        dsimp only at hs
        rw [List.pairwise_cons] at hs
        rcases List.mem_cons.1 ht with e | e
        · subst e; omega
        · have := hs.1 t e; omega
      -- first make sure the head's `can_free` is set
      obtain ⟨s1, hst1, hr1, h1hd, h1o, h1rd⟩ : ∃ s1 : St K V,
          OSteps C ⟨s, hd :: rest⟩ ⟨s1, hd :: rest⟩ ∧ OReachable C ⟨s1, hd :: rest⟩ ∧
          s1.ts hd = .retired vh dh true ∧ (∀ x, x ≠ hd → s1.ts x = s.ts x) ∧ s1.rd = s.rd := by
        cases cf with
        | true => exact ⟨s, OSteps.refl _, hr, ehd, fun _ _ => rfl, rfl⟩
        | false =>
          have hstep : OStep C ⟨s, hd :: rest⟩
              ⟨{ s with ts := upd s.ts hd (.retired vh dh true) }, hd :: rest⟩ := by
            refine OStep.other _ (Step.markFree s hd vh dh ehd ?_) (.inl rfl) ?_
            · intro u st hu; have := hrd u st hu; omega
            · intro x hx
              by_cases e : x = hd
              · subst e; simp at hx
              · simpa [upd, e] using hx
          exact ⟨_, osteps_single C hstep, OReachable.step hr hstep, upd_same _ _ _,
            fun x e => upd_other _ _ _ _ e, rfl⟩
      have hpop := OStep.pruneHead (C := C) s1 hd vh dh rest h1hd
      have hst2 := OSteps.tail hst1 hpop
      by_cases e : t = hd
      · subst e; exact ⟨_, hst2, upd_same _ _ _⟩
      · have htr : t ∈ rest := by rcases List.mem_cons.1 ht with e' | e'; exact absurd e' e; exact e'
        obtain ⟨o', h3, h4⟩ := ih ⟨{ s1 with ts := upd s1.ts hd .freed }, rest⟩
          (by simp at hl; simpa using hl) (OReachable.step hr1 hpop) htr (by
            intro u st hu
            show dOf (upd s1.ts hd .freed t) < st
            rw [upd_other _ _ _ _ e, h1o t e]; exact hrd u st (by rw [← h1rd]; exact hu))
        exact ⟨o', osteps_trans C hst2 h3, h4⟩

/-- Every `Step` changes at most one reader. -/
theorem step_rd {s s' : St K V} (h : Step C s s') : s'.rd = s.rd ∨ ∃ u r, s'.rd = upd s.rd u r := by
  cases h <;> first | exact Or.inl rfl | exact Or.inr ⟨_, _, rfl⟩

/-- Only finitely many readers are ever non-idle. -/
theorem rd_finite {s : St K V} (h : Reachable C s) : ∃ N, ∀ u, N ≤ u → s.rd u = .idle := by
  induction h with
  | init => exact ⟨0, fun _ _ => rfl⟩
  | step _ hs ih =>
    obtain ⟨N, hN⟩ := ih
    rcases step_rd C hs with e | ⟨u, r, e⟩
    · exact ⟨N, fun x hx => by rw [e]; exact hN x hx⟩
    · refine ⟨max N (u + 1), fun x hx => ?_⟩
      rw [e, upd_other _ _ _ _ (by omega)]; exact hN x (by omega)

def rsm {K V} : RS K V → Nat
  | .idle => 0
  | .pinned .. => 1
  | .returned .. => 2
  | .probing _ _ _ _ _ _ rest => 4 * rest.length + 3
  | .scanning _ _ _ _ _ _ _ todo _ rest => 4 * rest.length + 4 + todo.length

/-- A reader can always finish its current operation and unpin, using reader steps only. -/
theorem drain_reader (u : Nat) : ∀ n (o : OSt K V), rsm (o.s.rd u) ≤ n →
    ∃ o', OSteps C o o' ∧ o'.s.rd u = .idle ∧ (∀ x, x ≠ u → o'.s.rd x = o.s.rd x) ∧
      o'.s.ts = o.s.ts ∧ o'.rl = o.rl := by
  intro n
  induction n with
  | zero =>
    intro o hm
    refine ⟨o, OSteps.refl _, ?_, fun _ _ => rfl, rfl, rfl⟩
    cases e : o.s.rd u <;> rw [e] at hm <;> simp [rsm] at hm ⊢
  | succ n ih =>
    intro o hm
    obtain ⟨s, rl⟩ := o
    -- one reader step to `setRd s u r` with a smaller measure, then recurse
    have go : ∀ r, Step C s (setRd s u r) → rsm r ≤ n →
        ∃ o', OSteps C ⟨s, rl⟩ o' ∧ o'.s.rd u = .idle ∧
          (∀ x, x ≠ u → o'.s.rd x = s.rd x) ∧ o'.s.ts = s.ts ∧ o'.rl = rl := by
      intro r hs hr
      have h1 : OStep C ⟨s, rl⟩ ⟨setRd s u r, rl⟩ := OStep.other rl hs (.inl rfl) (fun _ h => h)
      obtain ⟨o', h2, h3, h4, h5, h6⟩ := ih ⟨setRd s u r, rl⟩ (by simp [setRd, hr])
      refine ⟨o', osteps_trans C (osteps_single C h1) h2, h3, fun x hx => ?_, h5, h6⟩
      rw [h4 x hx]; exact upd_other _ _ _ _ hx
    cases e : s.rd u with
    | idle => exact ⟨⟨s, rl⟩, OSteps.refl _, e, fun _ _ => rfl, rfl, rfl⟩
    | pinned st hl => exact go _ (Step.unpin s u st hl e) (by simp [rsm])
    | returned st hl k t lv r =>
      exact go _ (Step.finish s u st hl k t lv r e) (by (try simp only [e, rsm] at hm); simp [rsm] at hm ⊢; omega)
    | probing st hl k t lv pre rest =>
      simp only [e, rsm] at hm
      cases rest with
      | nil => exact go _ (Step.probeEnd s u st hl k t lv pre e) (by (try simp only [e, rsm] at hm); simp [rsm] at hm ⊢; omega)
      | cons j rest =>
        exact go _ (Step.probeGroup s u st hl k t lv pre [j] rest e (by simp))
          (by (try simp only [e, rsm] at hm); simp [rsm] at hm ⊢; omega)
    | scanning st hl k t lv pre g todo obs rest =>
      simp only [e, rsm] at hm
      cases todo with
      | cons j todo =>
        exact go _ (Step.scanLoad s u st hl k t lv pre g (j :: todo) obs rest j e (by simp))
          (by (try simp only [e, rsm] at hm); simp [rsm] at hm ⊢; omega)
      | nil =>
        by_cases hm' : ∃ i w, (i, Slot.full k w) ∈ obs
        · obtain ⟨i, w, hi⟩ := hm'
          exact go _ (Step.scanHit s u st hl k t lv pre g obs rest i w e hi)
            (by (try simp only [e, rsm] at hm); simp [rsm] at hm ⊢; omega)
        · have hm'' : ∀ i w, (i, Slot.full k w) ∉ obs := fun i w hi => hm' ⟨i, w, hi⟩
          by_cases he : ∃ i, (i, Slot.empty) ∈ obs
          · obtain ⟨i, hi⟩ := he
            exact go _ (Step.scanEmpty s u st hl k t lv pre g obs rest i e hm'' hi)
              (by (try simp only [e, rsm] at hm); simp [rsm] at hm ⊢; omega)
          · exact go _ (Step.scanNext s u st hl k t lv pre g obs rest e hm''
              (fun i hi => he ⟨i, hi⟩)) (by (try simp only [e, rsm] at hm); simp [rsm] at hm ⊢; omega)

/-- Every reader can be driven back to `idle` without touching tables or the retired list. -/
theorem quiesce : ∀ N (o : OSt K V), (∀ u, N ≤ u → o.s.rd u = .idle) →
    ∃ o', OSteps C o o' ∧ (∀ u, o'.s.rd u = .idle) ∧ o'.s.ts = o.s.ts ∧ o'.rl = o.rl := by
  intro N
  induction N with
  | zero => intro o h; exact ⟨o, OSteps.refl _, fun u => h u (Nat.zero_le _), rfl, rfl⟩
  | succ N ih =>
    intro o h
    obtain ⟨o1, h1, h2, h3, h4, h5⟩ := drain_reader C N _ o (Nat.le_refl _)
    obtain ⟨o2, h6, h7, h8, h9⟩ := ih o1 (by
      intro u hu
      by_cases e : u = N
      · subst e; exact h2
      · rw [h3 u e]; exact h u (by omega))
    exact ⟨o2, osteps_trans C h1 h6, h7, by rw [h8, h4], by rw [h9, h5]⟩

/-- **Reclamation liveness, ordered pruning.** Every retired table can be freed by some
schedule that respects the FIFO pruning order: drain every reader, let `collect` mark the
table and every older one, and pop the list up to it. -/
theorem ordered_retired_eventually_freed (hcov : C.Cover) {o : OSt K V} (h : OReachable C o)
    (t v d : Nat) (cf : Bool) (ht : o.s.ts t = .retired v d cf) :
    ∃ o', OSteps C o o' ∧ o'.s.ts t = .freed := by
  obtain ⟨N, hN⟩ := rd_finite C (oreachable_reachable C h)
  obtain ⟨o1, h1, h2, h3, h4⟩ := quiesce C N o hN
  have hr1 := osteps_reach C h h1
  have htm : t ∈ o1.rl := (rlInv C hcov hr1).mem t |>.2 ⟨v, d, cf, by rw [h3]; exact ht⟩
  obtain ⟨o2, h5, h6⟩ := drain_prefix C hcov t _ o1 (Nat.le_refl _) hr1 htm
    (by intro u st hu; rw [h2 u] at hu; cases hu)
  exact ⟨o2, osteps_trans C h1 h5, h6⟩

/-- **Reclamation liveness (original model).** Proved by the same reader-draining argument;
no ordering is needed here since `Step.prune` may free any marked table. -/
theorem retired_eventually_freed (_hcov : C.Cover) {s : St K V} (h : Reachable C s) (t v d : Nat)
    (cf : Bool) (ht : s.ts t = .retired v d cf) :
    ∃ s', Steps C s s' ∧ s'.ts t = .freed := by
  obtain ⟨N, hN⟩ := rd_finite C h
  obtain ⟨o1, h1, h2, h3, _⟩ := quiesce C N (⟨s, []⟩ : OSt K V) hN
  have hs1 := osteps_steps C h1
  have ht1 : o1.s.ts t = .retired v d cf := by rw [h3]; exact ht
  cases cf with
  | true => exact ⟨_, Steps.tail hs1 (Step.prune _ t v d ht1), upd_same _ _ _⟩
  | false =>
    have hm := Step.markFree (C := C) o1.s t v d ht1 (by intro u st hu; rw [h2 u] at hu; cases hu)
    exact ⟨_, Steps.tail (Steps.tail hs1 hm) (Step.prune _ t v d (upd_same _ _ _)),
      upd_same _ _ _⟩

end SyncTable
