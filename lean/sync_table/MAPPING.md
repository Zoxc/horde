# Lean model of `src/sync_table.rs`

Build: `cd lean/sync_table && lake build` (Lean core only, no Mathlib, same toolchain as
`lean/collect`, which is a lake path dependency `../collect`; builds in a few seconds). No
`sorry` here or in `lean/collect`.

Files:
- `SyncTable/Capacity.lean`: `bucket_mask_to_capacity`, `capacity_to_buckets`, `expand_by` arithmetic.
- `SyncTable/Table.lean`: sequential model of one table (buckets + control state + counters), the
  well-formedness invariant `WF`, and correctness of `find`, `find_insert_slot`, insert, remove,
  `from_iter` and iteration.
- `SyncTable/Probe.lean`: the concrete flattened triangular group probe and its coverage claim.
- `SyncTable/Bytes.lean`: the byte level: control-byte array with the mirrored trailing group
  (`Ctrl`, `setCtrl`), `Group::load`, `match_byte` (SSE2 and the generic bit trick),
  `match_empty`, `BitMask` iteration, `ProbeSeq`, and Rust's sequential `search` /
  `find_insert_slot` loops, proved equal to `Table.find` / `Table.firstEmpty` on `triSeq W`.
- `SyncTable/Word.lean`: the generic backend on machine words: little-endian group words,
  `match_byte` / `match_empty` word arithmetic (wrapping, `^`, `&`, `!`, `<<`), the `BitMask` word
  (`trailing_zeros`, `x & (x - 1)`, `BitMaskIter`), `usize` as `Nat` mod `2^u` (`h1`, `set_ctrl`'s
  `wrapping_sub & mask`), and the word-level `search` / `find_insert_slot` equal to the table model.
- `SyncTable/Link.lean`: Rust's per-group decision on loaded (possibly sheared) bytes versus the
  reader steps `scanHit` / `scanEmpty` / `scanNext` of `Model.lean`.
- `SyncTable/Backend.lean`: `BitMask` words of any stride and the `search` / `find_insert_slot`
  loops over an abstract `Group` backend, instantiated for generic little-endian, generic
  big-endian and SSE2 (`movemask`); the `usize` overflow bound of the probe.
- `SyncTable/LinkInv.lean`: invariants on reachable states (loaded buckets are a permutation of
  the group; no `mistagged` bucket on `PReachable` runs) deriving `Link.lean`'s hypotheses, with
  the mirrored-replica ordering (`ReplicaSync`) left as a hypothesis there, discharged per `get` over RC11 graphs in `RC11Table.lean` (`group_replicaSync`); across `get`s it holds up to one lagging replica byte (`RC11Global.chain_replicaSync`), which never changes a result (`RC11Global.reader_lin`).
- `SyncTable/Model.lean`: the concurrent transition system (one writer, many readers, `collect` abstracted
  by the `Step.markFree` premise).
- `SyncTable/Safety.lean`: the two inductive invariants: the safety invariant `SInv` on every run
  (`reachable_sinv`), and the full invariant `Inv` on probe-respecting runs (`preachable_inv`);
  the probe contract lemmas (`step_probeOK`, `probeOK_*`).
- `SyncTable/Properties.lean`: the headline theorems.
- `SyncTable/Ordered.lean`: the FIFO retired list (`OSt.rl`, `OStep`), refinement of `Step`,
  the list invariant `RLInv`, and reclamation liveness.
- `SyncTable/Contract.lean`: the `insert_new`/`replace`/`PotentialSlot` contracts and functional correctness under them.
- `SyncTable/Composed.lean`: **the composed model** `Composed.CStep`/`CReach`: the ordered table model
  run together with the `collect` primary model (`Collect.Ev.EStep`), projections to both, the
  `markFree` premise proved, and the headline theorems restated (namespace `SyncTable.Composed`).
- `SyncTable/Iter.lean`: unlocked whole-table readers (`Read::iter`, `len`, `capacity`, `Clone`) as an extension `ISt`/`IStep` of the base model (per-call states `IR`, `IRStep`), its invariant `IInv`, the weak-consistency theorems over run segments `IPath`, and the projection to the base model (`ireach_reachable`).
- `SyncTable/RC11Publish.lean`: groundwork for property 18: `Release`/`Acquire` publication lemmas on the RC11 layer of `lean/collect` (`Collect/RC11.lean`).
- `SyncTable/RC11Table.lean`: property 18: execution graphs of the table (writer operations under the writer mutex, tracked locations with version histories, one table's publication), per-`get` placement of a reader's loads at monotone model versions (`view`, `group_view`), `ReplicaSync` derived (`group_replicaSync`, `group_step_rc11`), bucket data reads (`full_read_data`), the counters (`len_view`).
- `SyncTable/RC11Global.lean`: property 18 across all `get`s of a reader thread: placement of a whole chain of loads with the one lagging replica byte (`chain_view`, `chain_replicaSync`), the table history `Hist` from model runs (`tstep_of_step`, `hist_of_run`), lookups over loads that may see one changed bucket from the other side of the operation (`ObsOK`, `obsOK_lag`, `obsOK_fwd`, `get_valid`), and the global linearizability of a reader's `get`s (`reader_lin`, `valid_hist`).
- `SyncTable/RC11Readers.lean`: property 18 closed for readers: `hkey` derived from Rust's probe positions (`probe_pos_inj`, `hkey_of_probe`), the bucket data interface `TableData` and the race-free data read after a control byte (`load_data`), one thread with both (`RThread`, `RThread.lin`, `ThreadLin`), and all reader threads merged into one history (`merge_threads`, `readers_lin`).
- `SyncTable/RC11Free.lean`: the `can_free` `Release`/`Acquire` pair over RC11 graphs (`can_free_no_race`, `can_free_not_after`), from `Collect.RC11Pin.CExec.pin_contract_flag`.
- `SyncTable/RC11Prog.lean`: property 18's graph hypotheses from the Rust code as event sequences: the writer's program per table (`WProg`: `opProg` for `insert*`/`remove`, `pubProg` for the publishing operation) gives `henc` (`WProg.henc`), the counters (`WProg.hcnt`) and `TableData` (`WProg.tableData`), hence `readers_lin_prog`; one graph for the writer and `collect` (`Shared`) with `replace_table`'s program (`RetireProg`) gives `RC11Free`'s `hmo` and `hSw` (`can_free_no_race_shared`); readers as pinned regions with `Read` calls (`PinRegion`, `RCall`) give the reader-side hypothesis (`RCall.inRegion`, `reader_before_free`).
- `SyncTable/Drop.lean`: `drop_impl` and memory reuse (property 20): the composed model extended (`DSt`, `DStep`, `DReach`) by environment writes to freed tables' cells, then `drop_impl` step by step (`start`, one `load` per retired table's `can_free`, `cancel`, one logged `free` per table in Rust's order) with `collect` steps interleaved throughout, and reallocation (`alloc`) and writes (`envWrite`) of non-live memory after the cancel.
- `SyncTable/Flags.lean`: `collect`'s `defer_by_id` obligation (`Collect.Flags`) discharged for table flags: `swap_obligation`/`swap_no_assert`, `flags_no_dup`, `freed_after_stored`, `collect_store_live`, and that the static empty table is never registered or deferred (`static_not_registered`, `static_never_deferred`). Statement form: `creach_freach` (the composed run, with the table memory `heapOf` as flag heap and the `can_free` cells `CSt.cell` as flag values, is a `Collect.Flags.FReach` run), `can_free_iff_stored`. No extra assumption: the table being the only `defer_by_id` client is now part of `CStep` (`KeepFlags`, `onlyTable`).

## Rust to Lean mapping

| Rust | Lean |
|---|---|
| `TableInfo` + bucket array (`TableRef<(K,V)>`) | `Table K V` (`n` = `buckets()`, `slot`, `growthLeft`, `tombstones`) |
| `bucket_mask` | `T.n - 1` (`WF.pow2`: `n` is a power of two) |
| control byte `EMPTY` / `h2(hash)` / `DELETED` plus bucket contents | `Slot.empty` / `Slot.full k v` (tag is `h2` of `k`'s hash) or `Slot.mistagged k v` (any other tag) / `Slot.deleted k v` (a deleted bucket keeps its pair, like Rust) |
| `h1`, `h2`, `make_insert_hash`, `BuildHasher` | `Cfg.hash : K → Nat`. `h2` is modelled only as whether a bucket's tag is its key's own `h2` (`full`) or not (`mistagged`): a lookup of `k` matches exactly the `full k _` buckets, since `match_byte` filters on `h2(hash_key(k))` and `eq` rejects every other key |
| `ProbeSeq`, `Group::load`, `match_byte`, `match_empty`, `BitMask` | `Cfg.seq n h : List Nat` (abstract), with the concrete `triSeq W` in `Probe.lean`; byte level in `Bytes.lean`: `probeAt`, `load`, `matchByteLE`/`matchByteBE`/`matchByteSSE2` (spec `MatchOK`), `matchEmpty`, `lsb`, `bits` |
| control bytes, `set_ctrl` mirroring, `h2`, sequential `search` / `find` / `find_potential` / `find_insert_slot` | `Bytes.Ctrl`, `Bytes.setCtrl`, `Bytes.h2_64`, `Bytes.search`, `bfind`, `bfindPotential`, `bfindInsertSlot` |
| `TableRef::find` / `search` with the `match_empty` stop | `find` |
| `find_insert_slot`, `prepare_insert_slot`, the `Err` slot of `find_potential` | `firstEmpty` |
| `record_item_insert_at` after `Bucket::write` | `insertAt` |
| the body of `Write::remove` | `removeAt` |
| `TableRef::allocate` | `emptyTable`; its address: `nextId` (`swap`) or a freed table's (`swapAt`, `PubOK`'s third case) |
| the static empty table `TableRef::empty()` / `EMPTY_TABLE` (`bucket_mask = 0`, `growth_left = 0`, `can_free = false`, shared by every `SyncTable`) | table id `0`: `current` in `init`, re-installed by `Step.replaceEmpty` (`swapEmpty`); always `live` and equal to `emptyTable 1` (`SInv.stat`, `SInv.tab0`, `static_live`, `static_frozen`); composed: its cell stays `false` (`VI.stat`, `static_can_free_false`). See assumption 6 |
| `TableRef::from_iter`, `clone_table` | `build` (fold of `insertNew`) |
| `RawIterRange` / `TableRef::iter` (full buckets in index order) | `items` |
| `TableInfo::items` | `(items T).length`, `items_formula`; racing: `swf_items`, `len_spec` |
| `Read::iter` / `Iter` / concurrent `RawIterRange` (one `current` load, `Group::load_aligned` + `match_full` per group, never stops at `EMPTY`) | `IR.iter` (`Starts.iter`, `IRStep.iterGroup` / `iterLoad` / `iterYield`, `fulls`, `Slot.pair`) in `Iter.lean` |
| `Iter<'a>` tied to the pin | `IStep.start` adds the table to the reader's `held`; `IStep.base`'s guard: no `unpin` while a call of the thread runs |
| `Read::len` (`current`, `tombstones.load`, `growth_left.load`) | `IR.lenT` → `lenG` → `lenR` (`IRStep.lenTomb`, `lenGrowth`) |
| `Read::capacity` (`current`, `tombstones.load`) | `IR.capT` → `capR` (`IRStep.capTomb`) |
| `Clone for SyncTable` / `clone_table_dedup` | `IR.cloneT`, `IRStep.cloneZero` (`TableRef::empty()`), `cloneTomb` (`tombstones.load`, state `cloneG` with ghost `T0`), `cloneGrowth` (`growth_left.load`, then the copy iteration with `cl = some (tb, gl, T0)`), `cloneDone` (`build C m (dedupK ..)`, any power-of-two `m` with capacity at least `remaining_capacity`; Rust's choice `capacity_to_buckets(max(items * 2, remaining))` with the `usize` overflow fallback to `capacity_to_buckets(remaining)` is `cloneBuckets`/`c2bU`, and `cloneBuckets_ok` shows it meets that premise) |
| `Iter::clone` (also used by `Debug for Iter`) | `IStep.copy` (a new slot gets the running iterator's state, its yielded prefix kept as ghost) |
| `bucket_mask_to_capacity`, `capacity_to_buckets` | `bmc`, `c2b W` (`W` = `Group::WIDTH`) |
| the `new_capacity` computation in `expand_by` | `expandCap` |
| `SyncTable::current` (`AtomicPtr`) | `St.cur` (a table id) |
| `TableInfoRef` pointer identity (the table's address) | table ids `Nat`: a new table gets the fresh `St.nextId` or, as the allocator may reuse memory, the id of a `freed` table (`Step.expandAt`/`replaceAt`, `swapAt`); id `0` is `TableInfoRef::empty()` |
| allocation state, the retired list, `can_free` | `St.ts : Nat → TS` (`unalloc`/`live`/`retired ver d canFree`/`freed`) |
| `retired_head`/`retired_tail`/`next_retired` (FIFO linked list) | `OSt.rl` (head first) in `Ordered.lean`; `RLInv`: exactly the retired ids, strictly increasing defer time |
| `lock`, `LockedWrite`, `write(&mut)`, `unsafe_write` contract | a single writer whose operations are atomic steps |
| `Write::insert_new`, `insert` (absent case), `PotentialSlot::insert_new` with its own key | `Step.insert` (key may be present) |
| `PotentialSlot::insert_new` fast path with any `key` (`sync_table.rs` `insert_new`: checks only same table, bucket `EMPTY`, `growth_left > 0`); `insert_new`/`insert` with a `hash` that is not `key`'s but has the same `h2` | `Step.insertAny`: any key into any in-bounds `EMPTY` bucket of `current` when `growth_left > 0`, same counter effects (`insertAt`) |
| `insert_new`/`insert`/`PotentialSlot::insert_new` with a `hash` whose `h2` is not `key`'s (`record_item_insert_at` stores the caller's `h2`) | `Step.insertMis`: a `mistagged` bucket in any in-bounds `EMPTY` bucket of `current`, same counter effects (`insertMis`) |
| `remove` with a wrong `hash` that reaches a `mistagged` bucket of the key | `Step.removeMis` |
| the `PotentialSlot` key contract (`key` is the key given to `get_potential`; `hash` is `key`'s hash) | the probe contract `ProbeOK` (an insert uses `k`'s `find_insert_slot` bucket), runs `PReachable`; `potential_insert_probeOK` |
| the `insert_new` (key absent) / `replace` (distinct keys) contract | `ContractOK` (which also includes `ProbeOK`), `CReachable`; key uniqueness `Uniq` |
| `Write::remove` | `Step.remove` |
| `replace_table(new)`: store `current`, then (unless the old table is `TableInfoRef::empty()`: early return) append the old table to the retired list and `defer_by_id` | `publish` (`retire`, `tick` skip the static table, id `0`); `swap` (fresh table `nextId`), `swapEmpty` (the static table) |
| `expand_by`/`expand_by_one`/`reserve_one` + `replace_table` + `defer_by_id` | `Step.expand` (via `swap`) |
| `Write::replace` + `replace_table` + `defer_by_id` | `Step.replace` (via `swap`; an empty iterator with `capacity > 0` allocates) |
| `Write::replace` of an empty iterator with `capacity = 0` (`from_maybe_empty_iter` returns `TableRef::empty()`) | `Step.replaceEmpty` (via `swapEmpty`) |
| `prune_tables`/`try_prune_tables` | `OStep.pruneHead` (one loop iteration: pop the head iff its `can_free` is set); `Step.prune` in the unordered model |
| `replace_table` appending the old table at `retired_tail` | `OStep.swap` (old `current` not the static table); `replace_table` from the static table is an `OStep.other` (nothing appended) |
| `retired_head = TableInfoRef::empty()` as the list's end sentinel, `can_free == false` stopping `prune_tables` | `OSt.rl` never contains `0` (`static_not_mem`); `Composed.prune_sentinel` (`rl.headD 0` has cell `true` only for a real retired head) |
| `can_free: AtomicBool::new(false)` at table allocation | composed: `CSt.cell : Nat → Bool`; `replace_table` into a new table resets its cell (`allocCell`, in `CStep.tbl`/`CStep.swap`), also at a reused address; every id `≥ nextId` has cell `false` (`VI.fresh`) |
| `mark_ready`'s `can_free.store(true, Release)` (in `collect`) | composed: every `collect` step sets `cell t := true` for each `t ∈ Collect.Flags.stores` (`storeCells`); `only_collect_sets_can_free` |
| `prune_tables`' `can_free.load(Acquire)` returning `true` | `Step.markFree` in the table-only model (premise proved in `Composed.lean`); composed: `CStep.markFree`, enabled when `cell t = true`; the observation is recorded in `canFree` for the pop (`OStep.pruneHead`) |
| `drop_impl` (`Drop::drop`, `&mut self`) | `Composed.DStep.start` (premise `hidle`: every reader `idle`, as `&mut self` excludes every `Read`/`Write`/`PotentialSlot` borrow and every returned reference; no table step exists in the drop phases), then `DStep.load` (one `can_free.load(Acquire)` per retired table, list order; `ids` grows iff it reads `false`), `DStep.cancel` (`EStep.cancel ids`), `DStep.free` (one per table: `current`, skipped if static, then the retired list head first); `collect` steps in between: `DStep.loadCol` (`KeepFlags`), `DStep.col` (`NoNewFlag`) |
| reuse of freed memory by any allocator, and the new owner's writes (provenance: the table never touches memory it freed, except to allocate a new table there) | a new table of this `SyncTable` at the address: `Step.expandAt`/`replaceAt`; anyone else: `DStep.envRun`/`loadEnv` (any write to the `can_free` cell of a `freed` table), after the cancel `DStep.alloc` (a new `defer_by_id` client's flag, `FStep.alloc`) and `DStep.envWrite` (any write to memory that is not a live flag, `Collect.Flags.FStep.envWrite`) |
| `collect::pin` entry/exit | `Step.pin` / `Step.unpin` (`RS.pinned start held`); composed: `CStep.pin`/`CStep.unpin` = table step + `EStep.pinRegister`/`pinOuter`/`unpinOuter` of `collect` thread `u` |
| `collect::defer_by_id(&table.info().can_free)` in `replace_table` | composed: `CStep.swap` = `OStep.swap` + `EStep.defer e cur true` (`deferE`; the flag pointer is the table id), only for an old `current ≠ 0`; `replace_table` from the static table is a `CStep.tbl` |
| reader thread `u` | `collect` thread `u` (`Tid = Nat`) |
| all other `collect` activity (other threads, `collect`, `release`, callbacks, ...) | composed: `CStep.col` |
| `collect`'s `St.now` vs. the table's `St.clk` | ghost strictly monotone map `CSt.f` (`J.mono`) |
| `Read::get`/`get_potential`/`get_with_eq`/`get_from_hash`: `current()` load | `Step.load` |
| `search`: one `Group::load` (`W` per-byte `Acquire` loads that can shear, `sse2.rs` / `generic.rs` `load`), the `match_byte` + `eq` loop, then the `stop` closure's `match_empty`, then `move_next` | `Step.probeGroup` (start a group), `Step.scanLoad` (one byte, any order, interleaved), `Step.scanHit` / `scanEmpty` / `scanNext` (after the whole group is loaded: matches first, then `EMPTY`), `Step.probeEnd`; reader state `RS.scanning` |
| references returned from `Read` (lifetime `'a` of the pin) | `RS.returned`, then `held` in `RS.pinned` until `unpin` |
| `PotentialSlot { table_info, index }` | `PotP s t k idx` (a ghost validity predicate) |
| `PotentialSlot::is_empty` | the hypotheses `t = s.cur` and `slot idx = .empty` |
| abstract map | ghost `St.ver` (writer version) and `St.hist : Nat → K → V → Prop` |
| `collect`'s logical time | ghost `St.clk`, pin start times, defer times `d` |

## Simplifying assumptions

1. **Sequential consistency, atomic writer operations.** There is only one writer at a time:
   `lock`, `&mut self`, and the `unsafe_write` contract give mutual exclusion. Readers only read
   control bytes (`Acquire`) and read a bucket only after seeing it full. The writer writes the
   bucket before the `Release` store of its control byte. Each writer operation changes the state
   of at most one bucket. `set_ctrl_release` stores the byte twice (the primary byte and its mirror
   copy for wrap-around group loads). A reader that sees the lagging copy observes the bucket as it
   was before the operation. All other buckets are the same then, so that read can be ordered
   before the writer's step. So each writer operation is one atomic step, and every control-byte load is
   one reader step (`Step.scanLoad`; a group load is `W` of them, assumption 4). The weak-memory
   justification is property 18 (`RC11Table.lean`, `RC11Global.lean`): over RC11 graphs the loads
   of **one `get`** are placed at monotone writer versions (so that `get` is a run of this model's
   reader). Across **different** `get`s of one reader thread the bytes are the model's at monotone
   versions `x` except one: after loading a primary byte written by operation `a`, a later `get`
   may load the replica byte's value from before `a` (`chain_replicaSync`). That byte never changes
   a result: all `get`s of the thread are linearizable in program order against the writer's
   operations, each within its `hb` window (`reader_lin`). What is proved is this order of each
   reader's `get` results (the reader-visible outputs), not a replay of the readers' individual
   `scanLoad` steps into one `Model` run: a `get` that saw the leading primary byte is placed
   before the operation, with that byte read as the operation's new value. The `get`s of all
   reader threads merge into one such sequence (`RC11Readers.readers_lin`), and the bucket data
   a `get` reads after a matching byte is the pair of the slot that byte encodes, race free
   (`RC11Readers.load_data`). The `can_free` `Release` store / `Acquire` load pair is proved over
   graphs (`RC11Free.can_free_no_race`): a free after reading `true` happens after every access
   of every reader that reached the table. The graph hypotheses of these results (`henc`,
   `TableData`, the `current` stores' `mo` order, `replace_table`'s order, the reader's `current`
   load in its pin) are derived from the Rust code as event sequences in `RC11Prog.lean`; the
   program-to-graph mapping itself (`WProg`, `RetireProg`, `PinRegion`, `RCall`) is the
   axiomatised part.
2. **Composition with `collect` (`Composed.lean`).** The residual simplifications of the composed
   model:
   - Reading `can_free` and freeing are separate steps (`CStep.markFree`, then
     `OStep.pruneHead`), as the load and the free are in Rust; `canFree` in `TS.retired` is the
     writer's record of having read `true`, not the atomic itself.
   - A reader thread inside a table read (from `pin` to `unpin`) takes no other `collect` step that
     changes its `collect` state (`CStep.col`'s `hfix`): no nested `pin` inside the read, as in
     the table model, which has no nesting. It may still `defer`. Other threads, and reader threads
     outside table reads, are unrestricted.
   - `collect` steps must not drop a queued `defer_by_id` flag (`KeepFlags`). Only `cancel_by_ids`
     can, and `SyncTable` calls it only from `drop_impl`, which is the separate final step
     `DStep.cancel` (`Drop.lean`); other code does not know the table's flag pointers.
   - `DStep.start` starts `drop_impl` only with every reader `idle` (the `&mut self` exclusivity).
     The drop phases' `collect` steps register no flag (`NoNewFlag`); other clients' flags are
     modelled by `DStep.alloc`/`envWrite` only as memory owners.
   - The composed `collect` steps register no `defer_by_id` flag of their own (`KeepFlags`, via
     `Collect.Ev.NoNewFlag`); the table's `replace_table` is the only registration (`onlyTable`).
     Other clients (`SyncPushVec`) register pointers into their own, distinct allocations; they are
     left out of the composed run rather than given a disjoint address space. Plain `defer` by other
     code is still allowed. The liveness schedule (`Collect.Ev.eventually_ran_keep`) satisfies this.
   - `CStep.swap` merges the table's `replace_table` (the `current` store plus appending to the
     retired list) and `collect`'s `defer_by_id` into one step. In Rust the `current` store comes
     first and `defer_by_id` later. This is sound because a reader `pin` (or other `collect` step)
     between the two commutes past the fused step: such a reader can only load the new `current`,
     never the old table, and after commuting it is pinned after the defer, so it gives the old
     table's flag no protection it needed. Writer-side steps cannot intervene (single writer).
   - The two logical clocks are different (`collect`'s counts all pins and defers), related by the
     ghost strictly monotone `f`.
3. **Hashing and user trait impls.** `hash : K → Nat` is arbitrary (an adversarial hasher is
   allowed), but `Hash`, `Eq` and `Clone` are assumed well-behaved: deterministic, `Eq` an
   equivalence consistent with `Hash`, no side effects. `h2` filtering is dropped. Callers are
   assumed to pass the right hash (`hash == hash_key(key)`) to lookups (`get`, `get_potential`,
   `refresh`): Rust checks this only with `debug_assert_eq!`, so a wrong caller hash for a lookup
   in release builds is excluded. A wrong hash for an insert (`insert_new`, `insert`,
   `PotentialSlot::insert_new`) is modelled. It puts the key into the first `EMPTY` bucket of the
   wrong probe sequence, tagged with the wrong hash's `h2`. With the key's own `h2` that is a
   `Step.insertAny`; with another `h2` it is a `Step.insertMis`, a `mistagged` bucket that no
   lookup matches, even if it lies on the key's probe sequence. Safety holds for both;
   probe-based correctness is only claimed under `ProbeOK`, which excludes `insertMis`. A wrong
   hash for `remove` deletes a full or mistagged bucket of the key or nothing (`Step.remove`,
   `Step.removeMis`). `clone_table` rehashes every key, so `expand` turns `mistagged` buckets
   back into `full` ones (`items` yields both). `get_with_eq` /
   `get_from_hash` with user predicates are not modelled (only `get` by `K`'s `Eq`).
4. **Probing.** A reader loads a group (`Step.probeGroup`) as one step per byte
   (`Step.scanLoad`), in any order and interleaved with other threads, since `Group::load` is
   `W` separate `Acquire` byte loads that can shear. Only after the whole group is loaded does it
   decide, as `search` does: a loaded full bucket of `k` (`match_byte`, then `eq`, which reads the
   bucket data; a full bucket keeps its pair until freed) returns it (`scanHit`); otherwise an
   `EMPTY` byte stops (`scanEmpty`, `find`'s and `find_potential`'s `match_empty`); otherwise the
   next group (`scanNext`). Over-approximations: a group is any non-empty prefix of the remaining
   `Cfg.seq` (for `triSeq W` Rust's groups are the `W`-chunks), the hit may be any loaded match
   (Rust takes the lowest bit; non-`k` `h2` matches fail `eq` and are not modelled), and
   `potential_of_scanEmpty` takes the slot Rust picks (lowest `EMPTY` bit). The reader never
   uses `Table.find`; `Table.find` is proved equal to Rust's sequential `search` (`Bytes.search_find_eq`).
   The writer side still uses the flattened list: "first `EMPTY` in the first group with one,
   lowest bit first" is the first `EMPTY` of the flattened `triSeq`, so `firstEmpty` is exactly
   `find_insert_slot` (the writer sees a stable table). Safety and linearizability need
   `Cfg.seq_lt` (positions are masked) and `Cover` (every bucket is visited, for
   `find_insert_slot` termination inside `reachable_sinv` / `preachable_inv`). `Cover` is a
   hypothesis (`hcov`) of the main theorems; for the concrete probe it is discharged by
   `triSeq_cover`.
5. **Table addresses may be reused.** A table id is its address: a new table may get the address
   of a freed table (`Step.expandAt`/`replaceAt`), with a fresh `can_free` (`allocCell`).
   Everything that compares or dereferences table pointers only does so for tables that are not
   freed: readers (`no_use_after_free`), `PotentialSlot` (`PotP` requires its table not freed;
   its `'a` lifetime ties it to the pin, so `potential_step` assumes the table is still not
   freed), the retired list (only retired tables, `RLInv`), and `collect`'s flags (a table is
   freed only after its flag was stored, `freed_after_stored`, and the new table's
   `defer_by_id` is a new registration with a later time). `retired_frozen` is stated for tables
   that are not freed. The static empty table (`TableInfoRef::empty`, id `0`) is never freed
   (`static_live`), so its address is never reused; see 6. `Step.insertAny` assumes its bucket is in
   bounds (`i < n`): a `PotentialSlot` is only built (private fields) by `get_potential` /
   `refresh` from a bucket of a probe sequence of the table it records (`Cfg.seq_lt`), and
   `is_empty` checks that this table is `current`.
6. **Static empty table.** Rust's `TableInfoRef::empty()` is one static `EMPTY_TABLE`
   (`sync_table.rs` `TableRef::empty`, `bucket_mask = 0`, `growth_left = 0`, `tombstones = 0`,
   `can_free = false`, all control bytes `EMPTY`). The model gives it the reserved id `0`
   (`emptyTable 1`):
   - It is `current` after `SyncTable::new()` (`init`) and again after every `replace` that
     installs it (`from_maybe_empty_iter` with an empty iterator and `capacity = 0`:
     `Step.replaceEmpty`, `swapEmpty`), also when it is already `current`. `clone_table` (used by
     `expand_by`) never returns it; `clone_table_dedup` (`Clone`) can, as the new
     `SyncTable`'s table (`IRStep.cloneZero`, `clone_zero`).
   - `replace_table` returns before the retire and the `defer_by_id` when the old `current` is
     the static table (`sync_table.rs` `replace_table`, `if table.info == TableInfoRef::empty()
     { return; }`). The model does the same: `publish` retires the old `current` and advances the
     `collect` clock (`retire`, `tick`) only when it is not `0`; in `Ordered.lean` such a step is an
     `OStep.other` (nothing appended), and in `Composed.lean` a `CStep.tbl` (no `EStep.defer`).
     `CStep.swap` (the joint step with `defer_by_id`) requires `cur ≠ 0`.
   - Readers pin, load and probe it like any table (`Holds`: it is `live`); a reader that loaded
     it keeps a valid view after it stops being `current` (`View`'s third case: the map was
     empty at some version in the reader's interval).
   - Proved: it stays `live` (never retired, deferred or freed) and is never written
     (`SInv.stat`, `SInv.tab0`, `static_live`, `static_frozen`; insert needs `growth_left > 0`,
     remove a full bucket, `cur_ne0_growth`, `cur_ne0_full`); it is never in the retired list
     (`static_not_mem`), never registered or deferred with `collect` (`static_not_registered`,
     `static_never_deferred`), and its `can_free` cell is always `false` (`VI.stat`,
     `static_can_free_false`), so as the retired list's sentinel it stops `prune_tables`
     (`prune_sentinel`).
   - **Sharing across instances is not modelled; one instance suffices.** Every `SyncTable` (of
     every `K`, `V`) points at the same `EMPTY_TABLE`. No instance writes it: the only writes to a
     `TableInfo` are `record_item_insert_at` (needs `growth_left > 0`; the static table has `0`, so
     `reserve_one` replaces it first), `remove`'s `DELETED` store and `tombstones` increment (need a
     full bucket; it has none), `next_retired.set` (only on a retired table, and `replace_table`
     returns early for the static one), and `can_free.store` by `collect` (only through a pointer
     registered with `defer_by_id`, which no instance does for it). `static_frozen`,
     `static_never_deferred` and `static_can_free_false` prove each of these for one instance; a
     second instance runs the same code against the same table, so it also only reads it. Freeing
     is impossible too: `prune_tables` stops at it (sentinel) and `drop_impl`'s
     `self.current().free()` is a no-op for it (`free` deallocates only when `bucket_mask > 0`;
     and `drop_impl` skips id `0`: `freeing_static_live`). An immutable, never-freed object read by several
     instances cannot couple their behaviour, so the composition of instances is the product of
     single-instance runs as far as the static table is concerned.
7. **Initial state.** Every run starts from `init` (the static empty table, id `0`, is `current`;
   no readers; as after `new()`). Tables built by `with_capacity`, `from_iter` / `FromIterator`, `Clone`, or a
   `SyncTable` obtained otherwise are not initial states.
8. **Arithmetic is on `Nat`.** `usize` overflow ("capacity overflow" panics), allocation failure
   and `Layout` are not modelled. Panics during `clone`/`hash` (scope guards freeing the half-built
   table) are not modelled either.
9. **Not modelled:** `get_mut` (in-place
   mutation of a value through `&mut self`), the unpinned `Read` handles returned by
   `Write::read`/`LockedWrite::read` (the writer reading its own table without a pin),
   `K`/`V` destructors run when `prune_tables` frees a table, `shard_index_by_hash`,
   `lock_from_guard`'s assert, `sync_table/code.rs` (codegen probes only).

Because of 3, 6, 7 and 9, the memory-safety results hold for the modelled behaviours, not
unconditionally for every use of the safe API.

### Modelled exactly

- `collect` linked formally: the table-only model's `Step.markFree` premise is proved on the
  composed model (`markFree_premise`, `can_free_safe`, from `Collect.Main.safety`); composed runs
  project to `collect` and table runs (`creach_ereach`, `creach_oreach`).
- `can_free` value: tracked as `CSt.cell`, `true` exactly when the flag callback ran (`VI.val`);
  only `collect` sets it (`only_collect_sets_can_free`).
- Contract violations: `insert_new`/`replace` have no contract precondition; safety and multimap
  linearizability of `get` hits hold regardless (`insertAt_dup`, `get_linearizable_some`). A
  `get` returning `none` is linearizable only under the contract (`get_linearizable`), and to a
  map (`get_linearizable_map`, 2b/2c).
- Sheared group loads: the reader loads each byte of a group separately (`Step.scanLoad`) and
  checks matches before `EMPTY` (assumption 4).
- `PotentialSlot::insert_new` with a key other than its slot's (and inserts with a wrong hash):
  modelled as `Step.insertAny`, or `Step.insertMis` when the wrong hash has another `h2`. The invariants are split: the safety invariant `SInv` (with `SWF`,
  i.e. `WF` without `noHole`) holds on every run, so memory safety, `count`/`growth_left`/
  `tombstones` accounting and the reclamation and flag obligations hold regardless. `WF.noHole`
  and `WF.noMis` (no `mistagged` bucket), and everything built on them (`Inv`,
  `get_linearizable_some`, `potential_get`), are proved only on runs that respect the probe
  contract (`PReachable`). An off-probe or mistagged insert can hide a key from `get` (a logic
  error, not memory unsafety).
- Static empty table: modelled as the distinguished id `0` that `replace_table` never retires or
  defers (assumption 6); its never-freed,
  never-deferred and `can_free = false` properties are proved (property 22).
- Pruning order: the FIFO retired list is modelled (`Ordered.lean`, `ordered_frees_head`,
  `oreachable_reachable`).
- `can_free` read one step before the free: modelled as separate steps (`CStep.markFree`, then
  `OStep.pruneHead`).

## Properties

| # | Property | Lean | Status |
|---|---|---|---|
| 1 | **No use-after-free of tables.** A reader never probes, or holds references into, a table that is freed or unallocated, from `load` until `unpin`. Holds on every run, including `Step.insertAny` with any key. Every bucket a reader can load next in a group (`scanLoad`) is in bounds | `no_use_after_free`, `probe_in_bounds`; on the composed model `Composed.composed_no_use_after_free` | **Proved** (given `Cover`; on the composed model with `collect` modelled, no assumption about it beyond the composition simplifications, assumption 2) |
| 1b | **Safety invariant on every run.** Table status bookkeeping, every allocated table `SWF` (power of two, bounds, `growth_left`/`tombstones` accounting), pins and the tables each reader may dereference, also when `PotentialSlot::insert_new` writes a key off its probe sequence | `SInv`, `SRInv`, `SWF`, `sinv_step`, `reachable_sinv`, `insertAt_swf`, `removeAt_swf` | **Proved** |
| 1c | **Only `Step.insertAny` and `Step.insertMis` break the probe contract**: `insertAny` exactly when its bucket is not `find_insert_slot`'s for its key, `insertMis` always | `ProbeOK`, `PReachable`, `step_probeOK`, `probeOK_insertAny_iff`, `probeOK_insert`, `probeOK_remove`, `probeOK_swap`, `probeOK_publish`, `probeOK_of_ver` | **Proved** |
| 2 | **Linearizable `get`.** The result of a lock-free `get` for `k`, with group loads modelled byte by byte (assumption 4), agrees with the abstract state at some writer version between the reader's `current` load and its return (also when the table was retired mid-probe). (a) Under the full key contract (`CReachable`: unique keys, `ProbeOK`), for both `some` and `none`. (b) Under the probe contract alone (`PReachable`, duplicate keys from `insert_new`/`replace` allowed), only for `some w`: `(k, w)` was in the multimap. A `none` result is **not** linearizable with duplicate keys: in group `[b, e]` with `k` in `b`, the reader loads `e` as `EMPTY`, a duplicate `insert_new(k, _)` fills `e`, `remove(k)` deletes `b`, the reader loads `b` as `DELETED` and returns `none` while `k` was present throughout. Not claimed for runs with an off-probe `Step.insertAny` or a `Step.insertMis`, where `get` can miss a present key. (Within the modelled behaviours, assumptions 3, 6, 7, 9) | (a) `get_linearizable` (hypothesis `CReachable`; via `NWit`, `NRInv`, `nrinv_step`, `creachable_nrinv`), `ordered_get_linearizable`, `Composed.composed_get_linearizable`; (b) `get_linearizable_some` (hypothesis `PReachable`; plus `Lin`, `LinSome`, `View`, `Seen`, `ScanOK`), `ordered_get_linearizable_some`, `Composed.composed_get_linearizable_some` | **Proved** |
| 2b | **`get` is linearizable to a map under the contract.** On runs where every `insert_new` key is absent, every `replace` has distinct keys, and every insert respects the probe contract, every table has unique keys, every version of the abstract state is a map, and `get` returns exactly the map's value | `get_linearizable_map`, `hist_functional`, `uinv_step`, `creachable_inv`, `creachable_nrinv` | **Proved** |
| 2c | The contract only constrains real `insert`/`insertAny`/`replace` steps | `contractOK_of_ver`, `contractOK_remove`, `contractOK_swapEmpty`, `CReachable.preachable` | **Proved** |
| 3 | Full inductive invariant, under the probe contract: every allocated table is `WF` (including `noHole` and `noMis`), the current table represents `hist ver`, every retired table represents `hist` at its retirement version and is pinned by its readers, plus the reader invariants. `inv_step` needs `ProbeOK` only for `Step.insertAny` and `Step.insertMis` | `Inv`, `inv_step`, `preachable_inv` (hypothesis `PReachable`); `Inv.sinv` | **Proved** |
| 4 | Retired tables are never written again while allocated (every run; a freed table's address may be reused) | `retired_frozen` (hypothesis `SInv`), `ordered_retired_frozen`, `composed_retired_frozen` | **Proved** |
| 5 | `PotentialSlot` validity survives arbitrary interleavings (every run, `Step.insertAny` and address reuse included) while its bucket stays `EMPTY` and its table is not freed | `potential_of_scanEmpty` (the lowest `EMPTY` byte of a sheared group load, while that bucket is still `EMPTY`), `potential_step` (hypothesis `SInv`) | **Proved** |
| 6 | `PotentialSlot::get`/`refresh` fast path: same table and still `EMPTY` imply the key is absent now (under the probe contract) | `potential_get` (hypothesis `Inv`, from `preachable_inv`) | **Proved** |
| 7 | `PotentialSlot::insert_new` fast path with the slot's own key picks the slot `find_insert_slot` would (the `debug_assert_eq!`), so it is a `ProbeOK` step | `potential_insert`, `potential_insert_probeOK` | **Proved** |
| 8 | Probe invariant (`noHole`) and `growth_left`/`tombstones` accounting are preserved by insert/remove, also with duplicate keys. Key uniqueness is preserved by contract-respecting insert and by remove | `WF`, `insertAt_wf`, `removeAt_wf`, `insertAt_uniq`, `removeAt_uniq`, `removeAt_has` | **Proved** |
| 9 | `find` is correct on a `WF` table with unique keys (sound and complete) | `find_spec` | **Proved** |
| 10 | `find_insert_slot` terminates: an `SWF` table always has an `EMPTY` bucket on any probe sequence (every run) | `firstEmpty_isSome`, `insert_enabled` (hypothesis `SInv`), `bmc_lt` | **Proved** (given `Cover`) |
| 11 | `from_iter`/`clone_table` (resize/rehash) preserve the contents (as a set of pairs) and produce a `WF` table for any input, with unique keys if the input keys are distinct | `build_wf`, `foldl_insert_wf`, `build_uniq`, `mem_items`, `items_pairwise` | **Proved** |
| 12 | `TableInfo::items()` (= `capacity - tombstones - growth_left`) is the number of full buckets | `items_formula` | **Proved** |
| 13 | `capacity_to_buckets` returns a power of two with enough capacity, and `expand_by(n)` makes room for `items + n` | `c2b_sound`, `expand_by_room` | **Proved** (on `Nat`) |
| 14 | `expand_by` strictly grows capacity once the table is more than half full (amortised growth) | `expand_by_grows`, `bmc_mono` | **Proved** |
| 15 | The triangular group probe visits every bucket (power-of-two `n`, `W`) | `triSeq_cover` (via `tri_surj`, `tri_refl`, `cover_aux`) | **Proved** |
| 16 | Reclamation liveness: some schedule frees any retired table (unordered, and respecting FIFO pruning) | `retired_eventually_freed`, `ordered_retired_eventually_freed` (via `rd_finite`, `quiesce`, `drain_prefix`) | **Proved** (weak "some schedule" form). Head-of-line blocking: a table is freed only after all older ones, but since defer times increase along the list, any reader blocking an older table also blocks the younger one, so ordering adds no extra wait on readers, only on `collect` marking the older flags. The collect side is discharged in the composed model (16c, `collect_live`, needs `1 < W`); fair-trace liveness is not stated here |
| 16c | Reclamation liveness on the composed model: every retired table is freed by some schedule (FIFO pruning, every unpin a joint `collect` step, `collect` itself storing the flags) | `Composed.composed_retired_eventually_freed` | **Proved** for `1 < W` (`EVENTS` width; `2^64` in Rust). `Composed.collect_live` discharges `Composed.CollectLive` from `Collect.Ev.eventually_ran_keep` (the drain schedule never cancels a flag; it runs as `CStep.col` steps after `quiesce` makes every reader idle) |
| 21 | Composition with `lean/collect`: projections of every composed run, the `markFree` premise, the link invariant, the `can_free` cells (read `true` ⇒ `collect` stored the flag ⇒ no reader pinned at or before the defer; only `collect` writes `true`) | `Composed.cstep_e`, `cstep_o`, `creach_ereach`, `creach_oreach`, `markFree_premise`, `J`, `creach_j`, `VI`, `creach_vi`, `can_free_safe`, `only_collect_sets_can_free`; also `composed_retired_frozen`, `composed_collect_safety` | **Proved** |
| 22 | **Static empty table** (assumption 6): never retired, deferred or freed, never written, never in the retired list, never registered with `collect`, `can_free` always `false`, and the retired list's sentinel for `prune_tables` | `static_live`, `static_frozen` (every `Reachable` run), `SInv.stat`, `SInv.tab0`, `static_not_mem`, `Composed.static_never_freed`, `Composed.static_can_free_false`, `Composed.prune_sentinel`, `Composed.static_not_registered`, `Composed.static_never_deferred`, `VI.stat` | **Proved** (one instance; sharing argued, assumption 6) |
| 16b | Ordered model refines the unordered one; the list is exactly the retired set sorted by defer time; pruning frees only the head | `ostep_step`, `rlInv`, `ordered_frees_head` | **Proved** |
| 17 | Rust's group-wise `search` read by a concurrent reader: per-byte loads of a group that can shear, all `h2` matches of the group checked before `match_empty` | `Step.probeGroup`, `scanLoad`, `scanHit`, `scanEmpty`, `scanNext` (assumption 4); `get_linearizable`, `get_linearizable_some`, `potential_of_scanEmpty`, `probe_in_bounds` are stated on this reader | **Modelled and proved** (any group chunking, any match). **Byte level proved** for a quiescent table (`Bytes.lean`): `search_find_eq` (sequential `find` = `Table.find` on `WF` + `Uniq`, never runs past `n / W` groups), `search_potential_eq` (`find_potential`), `findInsertSlot_eq` (`find_insert_slot` = `Table.firstEmpty`), `setCtrl_ctrl` / `emptyTable_ctrl` (mirroring kept), `ctrl_mirror` (byte `pos + b` is bucket `(pos + b) % n`), `matchByteLE_ok` / `matchByteBE_ok` / `matchByteSSE2_ok`, `matchEmptyByte_iff`. Chunking: `probeAt_eq`, `triSeq_chunks`, `load_chunk` show the `W`-chunks of `triSeq` are exactly the buckets of the groups Rust loads, so they are one admissible chunking for `probeGroup`. Generic backend on words (`Word.lean`): `matchByteWord_eq` (the `u64`/`u32` bit trick equals the borrow-chain model), `matchEmptyWord_eq`, `iterW_toMask` / `lowestSetBit_toMask` / `anyBitSet_toMask` (`BitMask` word with `trailing_zeros`, `x & (x - 1)`, stride 8), `searchW_eq`, `findInsertSlotW_eq`, end to end `bfindW_eq` / `bfindPotentialW_eq` / `bfindInsertSlotW_eq` with `h1 = hash as usize = hash % 2^u` (`h1_mask`, `triSeq_h1`), and `idx2Rust_eq` (`set_ctrl`'s `wrapping_sub & mask` is `(i + n - W) % n` for `n ≤ 2^u`). Concurrent reader (`Link.lean`): `groupDecide_found` / `_stop` / `_next`, `rust_group_step` (every Rust decision on the loaded bytes is a `Step.scanHit` / `scanEmpty` / `scanNext`), `model_hit_rust` / `model_empty_rust` / `model_next_rust` (every enabled model step is the same kind of decision for Rust), for any `MatchOK` `match_byte` and any shearing. All backends (`Backend.lean`): `agrees_genericLE`, `agrees_genericBE` (`from_be_bytes` group word, `to_le` byte swap of the masks), `agrees_sse2` (`_mm_movemask_epi8(_mm_cmpeq_epi8(..))` on the 16-byte word, stride 1, `match_empty = match_byte(EMPTY)`), with `bfindG_eq` / `bfindPotentialG_eq` / `bfindInsertSlotG_eq` for any agreeing backend; `probe_no_overflow`: `pos + stride + W < 2^u`, `pos + bit < 2^u` and `stride ≤ bucket_mask` for every group the loop leaves, given `n + W ≤ isize::MAX = 2^(u-1) - 1`, which `TableRef::layout` enforces (`ctrl_size = bucket_count + Group::WIDTH` lies inside the allocation and `Layout::from_size_align` rejects sizes above `isize::MAX`; `allocate` panics otherwise). Reader hypotheses derived (`LinkInv.lean`): `reachable_obsPerm` (on every `Reachable` state a scanning reader's loaded buckets plus `todo` are a permutation of its group), `obsOf_of_perm` + `chunk_nodup` (`ObsOf` for a fully loaded `W`-chunk), `preachable_noMis` (no `mistagged` bucket in any table or recorded slot on `PReachable` runs), `loaded_canon` (`Loaded` for the canonical bytes of the recorded slots); `reader_group_step` / `reader_model_rust` state the correspondence on reachable states. `ReplicaSync` (the bytes `Group::load` returns are the canonical bytes of the slots the `scanLoad` steps recorded) is **discharged over RC11 graphs** in `RC11Table.lean`: `group_replicaSync` gives, for one `get`'s per-byte `Acquire` loads (primary or mirrored positions, pairwise different buckets), monotone versions `x i` in `[pub, free)` with the loaded bytes `ReplicaSync` with the slots at those versions, and `group_step_rc11` turns Rust's decision into a model step when the `scanLoad`s are scheduled there. What Rust guarantees for the replica byte: its `Acquire` load returns the replica store of some operation that is not older than any operation happening before the load; within one `get` that is a consistent placement; across `get`s of a thread one replica byte may lag one operation, which never changes a result (`RC11Global.reader_lin`, property 18). Over-approximation kept: the model's `scanHit` allows any matching bucket, Rust takes the lowest bit (one of them) |
| 18 | Weak-memory correctness (the Acquire/Release on control bytes and `current`, the mirrored stores, the counters) over RC11-consistent graphs (`lean/collect/Collect/RC11.lean`) | Interface (`RC11Table.lean`): `Writer` (finite consistent graph; writer mutex as `LockLoc`; writer operation `i` = events `po`-between its lock RMWs `acq i`/`rel i`, numbered in lock order), `Track` (locations with values `vof x ℓ` after writer operation `x`: a store writes `vof`, one store per operation and location, `frame`), `TableLocs` (publication by operation `pub` with the `Release` `current` store after the initialisation), `Life` (during the table's life `[pub, dF)`: later table stores are `Release`, an operation writes the control bytes of at most one bucket and not both counters; the results that use it take `hfree`, so a store a load reads is of an operation before `dF`, `Writer.op_lt_of_hb`). Results: `Writer.op_hb`, `seen`, `mo_op`; `view` (a `po`-chain of `Acquire` loads is placed at monotone versions `≥ lo` returning `vof`, below every later store and every operation the loads happen before); `table_view`, `group_view` (one `get`'s control-byte loads), `group_replicaSync`, `group_step_rc11` (`ReplicaSync` and property 17's group decision); `full_read_data` (after an `Acquire` load of a `FULL` byte, the bucket read reads exactly the inserted data, no data race); `len_view` (counter loads at versions `x0 ≤ x1`: `len_spec`'s moments); `current_view`; plus `RC11Publish.lean` (`publish_read`, `publish_read_hb`, `mirror_read`) | **Proved, per `get`, across a reader thread's `get`s, and for all reader threads together** (no `sorry`; axioms `propext`, `Classical.choice`, `Quot.sound`). Per `get` (`RC11Table.lean`): `view`, `group_view`, `group_replicaSync`, `group_step_rc11` as above. Across `get`s (`RC11Global.lean`): `chain_view` (a reader's whole `po`-chain of `Acquire` loads at monotone versions `x i` in its `hb` window, `x i` at least an operation `lo i` completed before the load; only operation `x i` itself may have stored the location after the store read; two loads of one location read in operation order); `chain_replicaSync` (the true `ReplicaSync`: load `i` returns the canonical byte of its bucket's slot after operation `x i`, or, for the bucket operation `x i` changed, after `x i - 1`, and then `lo i < x i`; a lagging load never follows a fresh load of the same position); `obsOK_lag` / `obsOK_fwd` (a load of the bucket an operation changes, `EMPTY → FULL(κ)` or `FULL(κ) → DELETED(κ)`, placed on the other side of the operation is as good as the exact one for every key other than `κ`); `get_valid` (a lookup over such loads returns a result valid at a version between its smallest and largest placement); `reader_lin` (**global form**: for a reader's `get`s listed in program order there are monotone load placements `e i` with `lo i ≤ e i` and `e i < d` for every operation `d` the load happens before, the slot `σ i` each load returned (at `e i` or a neighbouring version), and versions `ℓ G` between each `get`'s placements, monotone in program order, such that each `get` whose Rust control flow completed (`Complete`) returns `rustGet` (`Link.lean`'s `groupDecide` on the loaded bytes) `Valid` for the table after operation `ℓ G`); `tstep_of_step`, `hist_of_run` (the table history `Hist` of a `CReachable` model run, i.e. under the three contracts), `valid_hist` (`Valid` for the current or a retired table is agreement with the abstract map at the current or retirement version). Assumed: the interface above (`Track.wval`: an operation's stores to a tracked location all write its value after the operation, which allows `set_ctrl_release`'s double store of the primary byte when `i ≥ W`, where `((i - W) & mask) + W = i`); `henc` (the control bytes after writer operation `x` are `encSlot` of the table's slots after model writer step `x`) is **derived** from the writer's program (`RC11Prog.WProg.henc`, below); with `hist_of_run` the steps are `CReachable` steps; other owners' stores before the initialisation or after the loads (`hnf`, `hfree`: property 11's pin contract; derived in `readers_lin_shared`, below); `reader_lin` takes `hkey` (a key reaches a bucket at one position of the control array), which `RC11Readers.hkey_of_probe` derives (`probe_pos_inj`: for `W`, `n` powers of two, `W ≤ n`, two bytes of groups of one hash's `ProbeSeq` (`Bytes.probeAt`) with the same bucket `% n` are the same position) from `hpos` (load `i` reads byte `b < W` of a group at `probeAt W n (hash (key i)) j`) and `hbkt` (`bkt q = q % n`); `RThread` is `reader_lin`'s hypotheses with these instead of `hkey`. Bucket data (`RC11Readers.TableData`): each insertion of `(k, v)` into bucket `b` (the version at which `b` stops being `EMPTY`, or the publication for entries copied by a resize) writes `dat b` with `dval k v`, `po`-before the operation's control-byte stores of `b` (or the publication's `current` store); no other operation of the table's life writes `dat b`; one write per operation of the table's life and data location; **derived** from the writer's program (`RC11Prog.WProg.tableData`). Assumed: writes by others (`op = none`) to `dat b` happen before the publishing operation or after the data read (`hnfD`, property 11/20: the memory belongs to the table from allocation to free). `load_data` (proved): a data read `po`-after a control-byte load that returned the byte of `full k v` reads `dval k v` from the insertion's write, which happens before it (through the control byte's `Release`/`Acquire`, a later operation's lock order, or the publication), and every write to the location is `hb`-ordered with it, also when the byte was the lagging/leading replica. `RThread.lin` (`ThreadLin`): `reader_lin`'s conclusion plus, for every load whose slot `σ i` is `full k v`, every later data read of the bucket returns `dval k v`, race free: Rust's key comparison and returned value are those of `σ`, so its result is `rustGet` on `σ`, `Valid` at `ℓ G`. **All reader threads** (`readers_lin`): for distinct threads `R u`, each with `ThreadLin`, one list `lin` of all their `get`s sorted by version `ℓ`, a permutation of all `get`s, that restricted to each thread is its `get`s in program order (`merge_threads`: stable merge sort); with the writer's operations in lock order this is one sequential history for all `get`s and writer operations. The `can_free` pair (`RC11Free.lean`, over a `Collect.RC11Pin.CExec` graph): `can_free_no_race`: a pruner's `Acquire` load `A` reading `mark_ready`'s `Release` store `M` (`po`-after the critical section `T` that ran the table's callback `c`, deferred by `D`), followed by the free `F` (`po`-after `A`): every event of a reader's pinned region that contains a load of `current` reading the table's publication store `S` happens before `F`. On one graph carrying both structures (`RC11Prog.Shared`: a `Writer` and a `CExec` with the same `G`), `can_free_no_race_shared` derives its hypotheses `hmo` (`S` `mo`-before `Sw`, from `Writer.mo_op`: both are `current` stores of writer operations `pub < r`) and `hSw` (`Sw` `po`-before `D`, from `replace_table`'s program `RetireProg`: `current.store(.., Release)`, the retired-list writes, `defer_by_id`, in program order); `reader_before_free` derives the reader side: a `Read` call (`RCall`: its `Acquire` load `Lc` of `current` and its table accesses, all `po`-between the pin event `a` and the region's `unpinOuter` `z` of a `PinRegion`, as the `'a` lifetime of `Read<'a>` and the returned references forces) lies in the pinned region (`RCall.inRegion`), so if `Lc` read `S`, `Lc`, every access of the call and every event of the region happen before `F`. Assumed: reading `true` means reading `M` (only `mark_ready` stores `true`; `Composed.only_collect_sets_can_free` in the model), and the `collect`-side facts about `T`, `D`, `M`, `A` (`CExec`, property 11). **The writer's program** (`RC11Prog.WProg`, the axiomatised mapping, one field per Rust line): the table's memory `TLoc` (`ctrl q` for `q < n + W`, `dat b`, `growth`, `tomb`) at distinct locations (`lay`, `lay_inj`); each writer operation `x` of the table's life `[pub, dF)` stores to it exactly `progAt x`, realised by a `po`-ordered event list `ev x` (`Real`: location, value, `Release` where Rust uses `Release`), and no other store of the operation hits the table (`complete`); `pub`'s program `pubProg` writes the data of each full bucket, every control byte and both counters, non-atomic, all `po`-before the publishing `current` store (`ev_S`), each location with its final value (`allocate`'s `EMPTY` memset and the counters' initial values, overwritten in the same operation before `S`, are not listed); a later operation's program is `opProg (ops x)` with `ops x` the table effect of its model writer step (`exists_ops` from `Hist`): `insert*` (`TOp.ins i k v`): `bucket.write` (`dat i`), `growth_left.store(_, Release)`, `set_ctrl_release(i, h2)` (`ctrl i`, then `ctrl (idx2 i)` with `idx2 i = ((i - W) & mask) + W`, equal to `i` when `i ≥ W`); `remove*` (`TOp.rem i k v`): `set_ctrl_release(i, DELETED)`, `tombstones.store(_, Release)`; every other step (`expand*`, `replace*`, `swapEmpty`, `prune`, and all operations after the table was replaced): no store to the table (the retiring operation's `next_retired` write is not a `TLoc`). Counter values are the model's (`growth_left - 1` and `tombstones + 1` of the writer's own `Relaxed` loads, which read the previous operation's store by lock order). Proved from it: `WProg.life` (`Life` for `[pub, dF)`, with `tl_lay`: `TableLocs.tl` is the control array and the counters), `WProg.henc` (`henc` for every position; positions past `n + W` are named as their bucket's primary byte, `hwrap`), `WProg.hcnt` (`vof` of `growth_left`/`tombstones` is the model table's), `WProg.tableData`, and `readers_lin_prog` (`readers_lin` with `Life`, `henc` and `TableData` derived). **Readers and the free from the programs** (`readers_lin_shared`): on one `Shared` graph, `FreeProg` (the collect-side facts of `can_free_no_race` for the prune that frees the table: `RetireProg` of the replacing operation `r > pub`, the callback's critical section, `mark_ready`'s `M`, the pruner's `A` and free `F`, with `F` in writer operation `f`); the table's life is `[pub, f + 1)` (`WProg`, `Hist` up to `f + 1`; the freeing operation is the model's `prune` step, which stores nothing to the table); `FreeProg.before`: every access of a `Read` call whose `current` load read `S` happens before `F` and before operation `f + 1` (`reader_before_free`, the pin event's index in `lin` from `IsLin`); a reader thread is an `RProg`: its `Read` calls `call c`, each an `RCall` in a `PinRegion`, `current` loads reading `S`, in program order, and the control-byte loads of its `get`s, each an access of a call, with the `RThread` facts about the loads themselves (what they read, probe positions, the `get`s); `RProg.toRThread` builds the `RThread` (`A` is the first call's `Lc`; `hAr` from the calls' order; `hfree` from `FreeProg.before`; `hnf` from `Owned`: others' stores to the control bytes and counters happen before the initialisation or after `F`). `readers_lin_shared` concludes `readers_lin`'s statement for these threads and the data clause for every data read that is an access of a call, with its side conditions discharged (`hownD`: others' stores to the bucket data happen before operation `pub` or after `F`). Assumed there: `Owned`/`hownD` (the allocator hands the memory to the table from allocation to free), `FreeProg` (`CExec`, property 11, and reading `true` means reading `M`), the program mappings (`WProg`, `RetireProg`, `RProg`). Counters: `growth_left`/`tombstones` are `Release` stores and `Acquire` loads by readers (`Relaxed` only for the writer's own loads under the lock, which see the latest value by lock order); `len_view` makes `Iter.len_spec`'s two moments two monotone versions in the reader's `hb` window, so its no-underflow arithmetic applies. `W ≤ n` (in `hkey_of_probe` and `WProg`) holds for every allocated table: `capacity_to_buckets` (`Capacity.c2b`) floors the bucket count at `Group::WIDTH`, and the only smaller table is the static empty one, which is never written. Not formalised: a replay of the readers' individual `scanLoad` steps into one `Model` run (the result order is proved, not a step-level refinement: a `get` that saw a leading primary byte is ordered before that operation), `scanLoad`'s relation to `Group::load`'s byte order beyond `group_step_rc11`'s scheduling premise (`hsched`), a concrete graph witnessing the cross-`get` replica behaviour |
| 19 | **Weakly consistent `Read::iter`/`len`/`capacity`/`Clone` under concurrent writers** (`Iter.lean`, extension `ISt`/`IStep` of the base model; statements over run segments `IPath` from the call's `current` load). The calls read only the table `t` they loaded: after a resize they keep reading the retired `t`, and writes to the new table are not seen. (a) Memory safety: `t` stays allocated and pinned while the call/iterator lives, loads are in bounds. (b) Iterator soundness: every yielded pair was in its bucket of `t` at some moment of the iteration. (c) Completeness per bucket: a finished iterator yielded every pair that sat in one bucket of `t` throughout (so also every pair in one bucket, with `k`'s own tag, at the start and at the end). (c') Completeness per key under the key contract: on contract-respecting extended runs (`ICReach`, `ICPath`: every step `ContractOK`) every table has unique keys (`icreach_inv`), and if `k` is in `t` (any bucket, any value) at every moment, `k` is yielded; with unique keys a present key cannot move (each step changes one bucket). (d) No bucket twice, buckets in increasing order. **Keys can repeat**: `k` yielded from bucket 5, then `remove(k)` and `insert(k, v')` into an `EMPTY` bucket 9 gives `k` twice, even under the key contract; and a key can be missed although the map always had it (multimap: insert a duplicate into an `EMPTY` bucket the iterator has passed, then remove the original before the iterator reaches it). (e) `len` returns `capacity - tombstones₁ - growth_left₂` (counters of `t` at two moments), never underflows, and is at least the number of full buckets at both moments. It can exceed the entry count at every moment (removal then insert between the loads: counts 1, 0, 1, result 2). (f) `capacity` is `capacity - tombstones` of `t` at its one load (= full buckets + `growth_left` then). (g) `Clone`: `items = remaining - growth_left` never underflows (`clone_no_underflow`), the copy loop never overfills the new table (`clone_bound`: at most `capacity - tombstones` pairs), the result is `WF` with unique keys, each of its pairs was in `t` during the copy, each key that sat in one bucket throughout is in it (first yielded value wins); the empty-table early return is exact (`clone_zero`). (i) `Iter::clone`: the copy (with the original's yield before it) is sound and complete per bucket over both segments; no-UAF/in-bounds/increasing hold for every slot. (h) The extension refines the base model (`ireach_reachable`, given any key), so all other theorems hold for its base state | (a) `iter_no_use_after_free`, `iter_in_bounds` (via `IInv`, `ireach_iinv`); (b) `iter_sound`; (c) `iter_complete`, `iter_complete_ends`; (c') `iter_complete_key_contract` (via `icreach_inv`, `iter_complete_key`, `key_stays`, `Changes1`); (d) `iter_buckets_increasing`; (e) `len_spec`; (f) `capacity_spec`; (g) `clone_no_underflow`, `cloneBuckets_ok`, `clone_size_rust`, `clone_bound`, `clone_result`, `clone_weakly_consistent`, `clone_zero`; (i) `iter_copy_sound`, `iter_copy_complete`; (h) `istep_steps`, `ireach_reachable` | **Proved** on every run (no probe or key contract needed). Modelled loosely: a group is any non-empty prefix of the remaining buckets (Rust: `W`-chunks), a whole group's full buckets are yielded in one step, `len`/`capacity` also put `t` in `held` (ghost; the pin protects it anyway). The panic when both `capacity_to_buckets` calls overflow (`.expect`) is not modelled (assumption 8) |
| 20 | **`drop_impl` safety and memory reuse.** Freed memory (by `prune_tables` or `drop_impl`) may be reallocated, by a new table of this `SyncTable` at the same address or by anyone else, and rewritten, also after the drop. `drop_impl` is modelled step by step: per-table `can_free` loads, `cancel_by_ids`, one free per table in Rust's order, with `collect` steps interleaved and no table step from its start (`&mut self`, premise `hidle`). Proved: no reader uses a table during the drop; `collect` stores only into retired, allocated tables before the cancel and into no cell at all after it, so never into a freed table's cell, reused or not; right after the cancel no `defer_by_id` flag is registered; the whole run (every free, every reallocation, every new owner's write) is a `Collect.Flags.FReach` run over the real cells, each free meeting `FStep.free`'s obligation; when the free list is done, the ghost log of `drop_impl`'s frees is exactly the current table (unless static) and every retired table at the drop, each once; the static table is never freed; no `collect` `debug_assert!` fires, also for `defer_by_id` of reused memory | `Composed.DStep`, `DReach`, `Sim`, `sim_step`, `sim_freach`, `step_unfreed`, `allocCell_agree`, `LI`, `DI`, `dreach_good`, `run_store_live`, `loading_store_live`, `loading_idle`, `loading_frozen`, `cancel_ids_cover`, `drop_unregisters`, `cancel_unregisters_all`, `freeing_no_store`, `freeing_cell_frozen`, `run_freach`, `loading_freach`, `freeing_freach`, `freeing_no_write_after_free`, `free_obligation`, `drop_frees_all`, `freeing_static_live`, `run_static_live`, `run_no_assert`, `freeing_no_assert` (`Drop.lean`); `Step.expandAt`/`replaceAt`, `allocCell` | **Proved** (given `Cover`, for the retired-list invariant) |

Done: the safety core (1-14, with 1b/1c), 2b, 2c, the static empty table (22), the probe coverage (15), reclamation liveness (16, 16b,
16c), the composition with `lean/collect` (21), weakly consistent iteration, `len`, `capacity` and `Clone` (19) and `drop_impl` with memory reuse (20). The byte level of 17 is proved (`Bytes.lean`, `Word.lean`, `Link.lean`, `Backend.lean`, `LinkInv.lean`; remaining assumptions listed in its row). Property 18 is proved over RC11 graphs per `get` (`RC11Table.lean`, `RC11Publish.lean`) for all `get`s of a reader thread in program order, with the lagging replica byte (`RC11Global.lean`, `reader_lin`), with `hkey` derived from the probe positions and the bucket data read combined, and for all reader threads merged into one history (`RC11Readers.lean`, `RThread.lin`, `readers_lin`); the `can_free` pair over graphs (`RC11Free.lean`, `can_free_no_race`); the graph hypotheses (`Life`, `henc`, `TableData`, `hmo`, `hSw`, the reader's `current` load in its pin) derived from the Rust code as event sequences, and all reader threads from their pinned `Read` calls with the free-side hypotheses from the prune (`RC11Prog.lean`, `readers_lin_shared`); open: a step-level replay of the readers' `scanLoad`s into one `Model` run (row 18).
