# Y.mbt implementation roadmap

**Status: Phases 0–7 complete (2026-10-06).** Phase 2's original candidate-
evaluation and measurement requirements have reproducible, scoped evidence in
the benchmark documents. This roadmap is not a claim of Yjs wire/API parity or
of an exhaustive proof over every possible event schedule.

## Architecture and decisions

Y.mbt is a MoonBit-native local-first CRDT for shared maps, lists, and plain
text. Its root package is organized as small cohesive implementation files;
`compat/yjs`, `bench`, `examples`, and `cmd` are separate packages. The core
uses causal events with indexed map and sequence materialization. A separate
complete-log replay projector provides an independent cold-projection
candidate and correctness comparison. The measured projector does not
implement the full `Document` contract, so the results are bounded workload
evidence rather than an equivalent-work throughput comparison. Details and
the measurements are in [docs/algorithm-decision.md](docs/algorithm-decision.md)
and [docs/benchmarks.md](docs/benchmarks.md).

The selected compatibility tier is **sequential Yjs semantic projection** for
the fixture-tested map, indexed array, and plain-text operations. There is no
Yjs JavaScript API or Yjs update/state-vector wire compatibility. Yjs wire
codec work is therefore not required by the selected tier. See
[docs/compatibility.md](docs/compatibility.md).

The library exposes provider-neutral sync and byte-persistence hooks, but
leaves networking, authentication, awareness, durable storage choice, and
write fencing to applications. Checkpoint epochs bound retained event,
tombstone, deleted-node, and undo history under the documented active-peer
retention policy in [docs/retention.md](docs/retention.md).

## Phase 0 — Specification and invariants: complete

- [x] Separate semantic, JavaScript API, and wire compatibility claims in the compatibility matrix.
- [x] Define event identities, causal vectors, operations, values, document state, and typed errors; represent `ReplicaId` as an immutable validated `String` rather than a wrapper type.
- [x] Document dependency closure, ownership, deterministic integration, idempotence, transactions, observers, retention, and codec budgets in [docs/invariants.md](docs/invariants.md).
- [x] Add deterministic two- and three-replica delivery/model tests.
- [x] Add formatting, generated-interface, type-check, test, fixture-drift, example, and benchmark checks to CI.

**Evidence:** `crdt_test.mbt`, `codec_test.mbt`, `compatibility_test.mbt`,
`docs/compatibility.md`, `docs/invariants.md`, and `.github/workflows/ci.yml`.
The CI model schedules are deterministic and seeded; they are not fuzzing or
an exhaustive schedule proof.

## Phase 1 — Minimal CRDT kernel: complete

- [x] Create immutable validated causal events with contiguous per-replica counters and Lamport metadata.
- [x] Apply local and remote events with dependency closure checks and duplicate/conflict handling.
- [x] Materialize deterministic map registers and RGA-style sequence nodes.
- [x] Test reordering, duplicate and individual delivery, batches, offline branches, and multi-hop updates.

**Exit evidence:** the checked-in model and regression suite passes on native,
JavaScript, Wasm, and Wasm GC. Cross-batch causal map ordering, invalid causal
cycles, poisoned pending records, and three-replica offline delivery have
dedicated regressions.

## Phase 2 — Sequence and text: complete with bounded benchmark evidence

- [x] Implement list and Unicode-scalar text sequences with stable event and checkpoint anchors.
- [x] Define relative positions using left/right boundaries, affinity, root, kind, and checkpoint epoch.
- [x] Evaluate a pinned Yjs 13.6.32 struct-store candidate on the shared logical operation trace alongside the indexed production candidate and independent complete-log replay projector.
- [x] Cover concurrent insertion/deletion, cross-replica prepend/middle/append, long offline branches, Unicode, and large documents.
- [x] Measure isolated local edit latency, comparable logical-workload merge/cold materialization, memory per visible element over varying live sizes, fixed-live history growth, and checkpoint size with disclosed setup and measurement limits.

**Exit evidence:** `docs/benchmarks.md` records the indexed and independent
replay projections over shared offline branch workloads, plus a pinned Yjs
13.6.32 struct-store candidate consuming the same logical trace. It includes
setup-excluded insert/delete timing on prepared 64-scalar documents,
variable-live-size process-heap estimates per visible element, fixed-live
history-growth measurements, and encoded checkpoint sizes. The comparison
documents different work scopes: Yjs decodes and integrates encoded updates;
the native candidate receives decoded events and validates/stages a full
Document transition; replay assumes a complete valid log. Results support a
bounded candidate decision, not equivalent-throughput or universal performance
claims. The process heap estimate includes fixed Document and runtime overhead,
and no exact allocator bytes per element are asserted.

## Phase 3 — Shared data model and transactions: complete

- [x] Add shared maps, lists, and plain text over recursive `Value` data.
- [x] Bound and validate recursive values before cloning; represent nested shared objects as explicitly named roots rather than aliased containers.
- [x] Add atomic transactions, deterministic copied change sets, and observers with FIFO reentrant dispatch.
- [x] Keep mutable document and storage fields opaque and return owned copies from public accessors.
- [x] Define semantic undo/redo for coalesced map edits and sequence insert/delete combinations.

**Evidence:** transaction, aliasing, recursive-value, observer-order, and
multi-step undo/redo regressions in `crdt_test.mbt` and
`undo_atomicity_wbtest.mbt`.

## Phase 4 — Incremental synchronization: complete

- [x] Exchange validated causal state vectors including per-replica Lamport metadata and checkpoint epoch.
- [x] Produce minimal retained event tails or a checkpoint plus tail for stale peers.
- [x] Apply full/incremental updates atomically and idempotently; verify multi-hop propagation.
- [x] Add a bounded versioned native binary codec with canonical ordering and typed malformed-input errors.
- [x] Test event and checkpoint round trips, truncation, unsupported versions, duplicate/unsorted metadata, and combined value budgets.

**Evidence:** `codec.mbt`, `codec_test.mbt`, document synchronization tests,
and the generated public interface snapshot `pkg.generated.mbti`.

## Phase 5 — Yjs boundary: semantic subset complete; wire/API unsupported

- [x] Choose and publish the sequential semantic compatibility tier.
- [x] Generate and check in differential fixtures from upstream Yjs 13.6.32 for map, array, and plain-text operations.
- [x] Keep the Yjs fixture generator and pinned dependency under `compat/yjs`; keep the native core independent of Yjs internals.
- [x] State unsupported API, concurrent winner, relative-position, and wire-format behavior explicitly.
- [x] Run the checked-in fixture drift check in CI.

Yjs update/state-vector codecs and Yjs-to-Y.mbt-to-Yjs wire round trips are
**not implemented and not part of the chosen compatibility tier**. The
fixture-backed sequential semantic cases are the only compatibility claims.

## Phase 6 — Compaction and garbage collection: complete under a coordination contract

- [x] Specify retention of event history, map deletes, sequence deletes, relative positions, and offline replicas.
- [x] Compact to a checkpoint that retains live projections and causal metadata while discarding obsolete history and anchors.
- [x] Require known, causally closed active-peer acknowledgements for local compaction and new remote checkpoint epochs.
- [x] Reject dirty stale replicas; provide explicit peer-lease expiry and document the application recovery path.
- [x] Test repeated epochs, unique-key/delete churn, long offline branches, stale positions, forged clocks, and remote checkpoint lease bypass.
- [x] Measure fixed-live growth across increasing history sizes.

**Exit evidence:** under a fenced epoch transition and current active-peer
leases, history and deleted-anchor growth is discarded at compaction. An ACK
alone does not stop a peer from editing later; providers must fence writes
through the epoch change or explicitly expire the peer lease. This is a
coordination contract, not a distributed lease or network implementation.

## Phase 7 — Production surface: complete

- [x] Add semantic undo/redo using fresh compensating events while preserving concurrent winners.
- [x] Add a callback-based persistence adapter and provider-neutral sync byte hooks.
- [x] Keep awareness and network delivery outside durable state.
- [x] Run deterministic property/model and regression tests in CI on native, JavaScript, and Wasm GC; run the Wasm target test suite locally as well.
- [x] Add cross-target benchmark/equality smoke tests and a runnable offline-collaboration example.
- [x] Publish public API, compatibility, invariant, retention, algorithm, and benchmark documentation.

`full_update` and `persist` save durable shared state and causal metadata, not
the whole mutable `Document` session. Pending/rejected diagnostics, peer
leases, observers, undo/redo history, and relative-position handles must be
re-established or recreated after restore.

## Verification and remaining scope

The completed-phase verification runs `moon fmt --check`, `moon fmt --check
scripts/yjs-fixtures.mbtx`, `moon fmt --check bench`, `moon info --target all`,
`moon check --target all`, `moon test --target all`, and the upstream Yjs
fixture drift check. The final checked-in test run passed 49 total tests per
target: 47 core tests and two benchmark projection tests on native, JavaScript,
Wasm, and Wasm GC. The CI workflow runs native, JavaScript, and Wasm GC checks,
tests, examples, and benchmark correctness/smoke tests. It does not run a
fuzzer or enforce latency thresholds. Benchmarks are reproducible local
baseline measurements, not product performance guarantees.

Phase 2 is complete with the bounded candidate and measurement evidence above.
There is no provider/network implementation, Yjs API shim, Yjs wire codec, or
awareness/presence store in durable state. Those remain explicit non-goals of
the selected native scope.
