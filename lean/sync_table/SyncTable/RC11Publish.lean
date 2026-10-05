import Collect.RC11

/-!
# Groundwork for property 18: publication through `Release`/`Acquire` (RC11)

Uses the generic RC11 layer of `lean/collect` (`Collect/RC11.lean`). The table publishes data in
two places, both "write the data, then a `Release` store; readers `Acquire`-load, then read the
data":

* `replace_table` initialises the new table (control bytes, buckets, `TableInfo`) and then
  stores `current` with `Release` (`sync_table.rs`, `current.store(.., Release)`); readers load
  `current` with `Acquire` (`current.load(Acquire)`).
* `insert` writes the bucket and then stores the control byte and its mirror with `Release`
  (`set_ctrl`, two `Release` stores); readers load control bytes with `Acquire` (`ctrl`, and
  the SSE2 group load, which loads each byte with `Acquire`).

`publish_read`: a reader whose `Acquire` load reads the `Release` store, and which then reads a
location written before that store, reads that write or a `mo`-later one (never older data,
e.g. uninitialised memory). `publish_read_hb` is the version for data that merely happens
before the store (e.g. written by an earlier writer). `mirror_read` is the instance for the
two mirrored control-byte stores: whichever of the two the reader's load reads, the bucket
write is visible.

The execution-graph model of the table's operations and the per-`get` placement of reader
loads at model versions (property 18) are in `RC11Table.lean`.
-/

namespace SyncTable.RC11Publish
open RC11 RC11.Graph

variable {E L V : Type} {G : Graph E L V}

/-- Data written `hb`-before a `Release` store `S`, read by a reader at or after (`po`) its
`Acquire` load `A` that reads `S`: the reader sees that write or a later one. -/
theorem publish_read_hb (hc : G.Consistent) {w S A r w' : E} (hw : G.hb w S ∨ w = S)
    (hrf : G.rf S A) (hS : G.isRel S) (hA : G.isAcq A) (aS : G.atomic S) (aA : G.atomic A)
    (hr : A = r ∨ G.po A r) (hrd : G.rf w' r) (hww : G.isW w) (hl : G.loc w = G.loc r) :
    w' = w ∨ G.mo w w' := by
  have hsr : G.hb S r := mp_hb hc (.inl rfl) hrf hS hA aS aA hr
  have hwr : G.hb w r := by
    rcases hw with h | rfl
    · exact hb_trans h hsr
    · exact hsr
  exact hb_read_coh hc hwr hrd hww hl

/-- Data written `po`-before a `Release` store (`replace_table`'s initialisation before storing
`current`; `insert`'s bucket write before `set_ctrl`). -/
theorem publish_read (hc : G.Consistent) {w S A r w' : E} (hw : G.po w S)
    (hrf : G.rf S A) (hS : G.isRel S) (hA : G.isAcq A) (aS : G.atomic S) (aA : G.atomic A)
    (hr : A = r ∨ G.po A r) (hrd : G.rf w' r) (hww : G.isW w) (hl : G.loc w = G.loc r) :
    w' = w ∨ G.mo w w' :=
  publish_read_hb hc (.inl (po_hb hw)) hrf hS hA aS aA hr hrd hww hl

/-- The mirrored control-byte stores: the bucket write `w` precedes both `Release` stores `S1`
(the byte) and `S2` (its mirror); an `Acquire` load reading either one publishes `w`. -/
theorem mirror_read (hc : G.Consistent) {w S1 S2 S A r w' : E} (h1 : G.po w S1)
    (h12 : G.po S1 S2) (hS : S = S1 ∨ S = S2) (hrf : G.rf S A) (hR : G.isRel S)
    (hA : G.isAcq A) (aS : G.atomic S) (aA : G.atomic A)
    (hr : A = r ∨ G.po A r) (hrd : G.rf w' r) (hww : G.isW w) (hl : G.loc w = G.loc r) :
    w' = w ∨ G.mo w w' := by
  have hwS : G.po w S := by
    rcases hS with rfl | rfl
    · exact h1
    · exact hc.po_trans _ _ _ h1 h12
  exact publish_read hc hwS hrf hR hA aS aA hr hrd hww hl

end SyncTable.RC11Publish
