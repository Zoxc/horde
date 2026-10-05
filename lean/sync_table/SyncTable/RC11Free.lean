import Collect.RC11Pin

/-!
# The `can_free` `Release`/`Acquire` pair over RC11 graphs

`replace_table` retires table `t`: its `Release` store `Sw` of `current` replaces the store `S`
that published `t`, and then (`po`-later, in the same critical section of `collect`'s mutex or
after it) `defer_by_id(&t.can_free)` is the `defer` event `D` of a callback `c`. `collect` runs
the callback in a critical section `T` and `mark_ready` stores `can_free = true` with `Release`
(`M`, `po`-after `T`). `prune_tables` loads `can_free` with `Acquire` (`A`) and, reading `true`,
i.e. reading `M`, frees the table (`F`, `po`-after `A`).

`can_free_no_race`: every event of a reader's pinned region that loaded `current` and read `S`
(i.e. that can access `t`) happens before the free. So the free does not race with any reader
access to `t`. This is `Collect.RC11Pin.CExec.pin_contract_flag` plus the table's interface:

* `hSw`: the replacing store is `D` or `po`-before it (`replace_table` swaps `current` before
  `defer_by_id`);
* `hmo`: `S` is `mo`-before `Sw` on `current` (both are writer stores in lock order;
  `RC11Table.Writer.mo_op` proves this for stores of a `Writer` on the graph);
* `hLc`, `hrfL`: the reader's access is in a pinned region that contains a load `Lc` of
  `current` reading `S` (a reader reaches a table only through such a load in the same pin,
  property 11's contract on the table side).

If the reader's region started after the defer (`D hb a`), then `Sw hb Lc` and `Lc` cannot read
the `mo`-older `S` (coherence); otherwise `pin_contract_flag` puts the whole region before `A`,
hence before `F`.
-/

namespace SyncTable.RC11Free
open Collect Collect.RC11Pin RC11 RC11.Graph

variable {E L V : Type} {X : CExec E L V}

/-- **The free after reading `can_free = true` does not race with readers of the table.** -/
theorem can_free_no_race {lin : List E} (hlin : IsLin X.G.hb lin) (hv : X.Valid lin)
    {T D a M A F S Sw Lc : E} {u : Tid} {c : Cb} {iT iD ia : Nat}
    (hT : lin[iT]? = some T) (hTl : (X.act T).locked = true)
    (hc : c ∈ (X.replay lin (iT + 1)).s.ran)
    (hD : lin[iD]? = some D) (hDa : X.act D = .defer c.id c.byId)
    (hDt : (X.replay lin iD).s.now = c.time)
    (ha : lin[ia]? = some a) (haa : X.act a = .pinRegister u ∨ X.act a = .pinOuter u)
    (hM : T = M ∨ X.G.po T M) (hrf : X.G.rf M A) (hMr : X.G.isRel M) (hAa : X.G.isAcq A)
    (hMat : X.G.atomic M) (hAat : X.G.atomic A) (hAF : X.G.po A F)
    (hSw : Sw = D ∨ X.G.po Sw D) (hmo : X.G.mo S Sw)
    (hLc : X.InRegion u a Lc) (hrfL : X.G.rf S Lc) :
    ∀ x, X.InRegion u a x → X.G.hb x F := by
  rcases X.pin_contract_flag hlin hv hT hTl hc hD hDa hDt ha haa hM hrf hMr hAa hMat hAat
    with h | h
  · exfalso
    have hSa : X.G.hb Sw a := by
      rcases hSw with e | e
      · rw [e]; exact h
      · exact hb_trans (po_hb e) h
    have hSL : X.G.hb Sw Lc := by
      rcases hLc.2.1 with e | e
      · rw [e]; exact hSa
      · exact hb_trans hSa (po_hb e)
    exact hb_not_read_older X.cons hSL hrfL hmo
  · exact fun x hx => hb_trans (h x hx) (po_hb hAF)

/-- The same as a race-freedom statement: an access `x` of the reader's region and the free
`F` are `hb`-ordered (`x` first), so neither `F hb x` nor unordered. -/
theorem can_free_not_after {lin : List E} (hlin : IsLin X.G.hb lin) (hv : X.Valid lin)
    {T D a M A F S Sw Lc : E} {u : Tid} {c : Cb} {iT iD ia : Nat}
    (hT : lin[iT]? = some T) (hTl : (X.act T).locked = true)
    (hc : c ∈ (X.replay lin (iT + 1)).s.ran)
    (hD : lin[iD]? = some D) (hDa : X.act D = .defer c.id c.byId)
    (hDt : (X.replay lin iD).s.now = c.time)
    (ha : lin[ia]? = some a) (haa : X.act a = .pinRegister u ∨ X.act a = .pinOuter u)
    (hM : T = M ∨ X.G.po T M) (hrf : X.G.rf M A) (hMr : X.G.isRel M) (hAa : X.G.isAcq A)
    (hMat : X.G.atomic M) (hAat : X.G.atomic A) (hAF : X.G.po A F)
    (hSw : Sw = D ∨ X.G.po Sw D) (hmo : X.G.mo S Sw)
    (hLc : X.InRegion u a Lc) (hrfL : X.G.rf S Lc) {x : E} (hx : X.InRegion u a x) :
    X.G.hb x F ∧ ¬ X.G.hb F x := by
  have h := can_free_no_race hlin hv hT hTl hc hD hDa hDt ha haa hM hrf hMr hAa hMat hAat hAF
    hSw hmo hLc hrfL x hx
  exact ⟨h, fun h' => hb_irrefl X.cons _ (hb_trans h h')⟩

end SyncTable.RC11Free

#print axioms SyncTable.RC11Free.can_free_no_race
#print axioms SyncTable.RC11Free.can_free_not_after
