# Roadmap: MoonBit-native CRDT architecture and staged Yjs interoperability

## Goal

Design Y.mbt as an idiomatic MoonBit local-first collaboration library inspired by Yjs, without requiring algorithm-level fidelity to Yjs.

Compatibility must be explicit rather than accidental: preserve Yjs interoperability only where it creates concrete value, while allowing the CRDT core, internal representation, APIs, error model, and module boundaries to be MoonBit-native.

**Implementation completed 2026-10-06.** Phases 0–7 are complete, with the
Phase 2 candidate evaluation and measurement requirements backed by the
bounded, reproducible results described below and in `docs/benchmarks.md`.
The selected Yjs compatibility tier is sequential semantic projection; there
is no Yjs API or wire compatibility claim.

## Design principles

- **Correctness before API breadth.** Convergence, determinism, idempotence, causal consistency, and round-trip encoding are release gates.
- **MoonBit-native core.** Prefer explicit `enum`/`struct` domain types, pattern matching, narrow package APIs, typed errors, and testable transformations over JavaScript-shaped internals.
- **Compatibility is layered.** Semantic, API, and wire compatibility are separate decisions. The CRDT core must not depend on the Yjs wire format.
- **Algorithm freedom.** Evaluate Yjs-style struct stores alongside modern event-graph / Eg-walker-inspired approaches; choose from correctness evidence and benchmarks rather than port fidelity.
- **Local-first by construction.** Offline edits, deterministic replay, incremental sync, and compact persistence are first-class requirements.
- **Observable invariants.** Every phase adds property/model tests before expanding the public API.

## Proposed architecture

```text
src/
  core/          # IDs, clocks, causal metadata, operations/events, invariants
  store/         # document/event storage and indexing
  sequence/      # text/list integration algorithm
  types/         # Map, Array/List, Text and shared-value model
  transaction/   # mutation boundary, change sets, observer events
  sync/          # state vectors/frontiers, diff calculation, update application
  codec/         # MoonBit-native binary format
  compat/yjs/    # optional Yjs wire/API compatibility
  gc/            # compaction/tombstone policy
```

The implemented MoonBit module keeps the core in its cohesive root package and
places `compat/yjs`, `bench`, `examples`, and `cmd` in separate packages. The
core exposes semantic operations and state transitions; codecs, persistence,
awareness, and transports remain replaceable boundaries.

## Phase 0 — Specification and invariants

- [x] Write the compatibility matrix: semantic, API, and wire compatibility are separate decisions.
- [x] Define logical/event IDs, causal frontier/state vector, operation/event types, and document value types; represent `ReplicaId` as an immutable validated `String` rather than a wrapper type.
- [x] Document invariants: unique IDs, dependency closure, deterministic integration, idempotent apply, and convergence.
- [x] Add deterministic two-/three-replica model and delivery-schedule tests.
- [x] Establish formatting, generated-interface, `moon check`, `moon test`, fixture, example, and benchmark CI checks.

**Exit:** randomized delivery orders converge to the same canonical document state.

## Phase 1 — Minimal CRDT kernel

- [x] Implement immutable causal events plus indexed storage.
- [x] Implement local transaction event creation and atomic remote event application.
- [x] Implement causal dependency closure, duplicate suppression, and conflicting-duplicate rejection.
- [x] Implement deterministic merge/materialization.
- [x] Add deterministic model/regression tests for permutation, individual and batch delivery, duplicates, and offline reconnection.

**Exit:** replicas converge under reordered and duplicated delivery without relying on network ordering.

## Phase 2 — Sequence/Text (complete with bounded benchmark evidence)

- [x] Build an RGA-style sequence CRDT for text/list editing.
- [x] Evaluate a pinned Yjs 13.6.32 struct-store candidate on the shared logical operation trace alongside the indexed production candidate and independent complete-log replay projector.
- [x] Define cursor/relative-position semantics independently from storage layout.
- [x] Cover concurrent insert/delete, long offline branches, Unicode, and large documents.
- [x] Measure isolated local edit latency, comparable logical-workload merge/cold materialization, memory per visible element over varying live sizes, fixed-live history growth, and checkpoint size with setup and measurement limits documented.

**Exit evidence:** `docs/benchmarks.md` records indexed and independent replay
projections over shared offline branch workloads, plus the pinned Yjs
13.6.32 struct-store candidate on the same logical edit trace. It records
setup-excluded insert/delete timing on a prepared 64-scalar document,
variable-live-size process-heap estimates per visible element, fixed-live
history-growth measurements, and encoded checkpoint sizes. The candidates do
different work: Yjs decodes and integrates encoded updates, native integration
receives decoded events and performs validation and atomic staging, and replay
assumes a complete valid log. This is bounded candidate evidence, not an
equivalent-throughput or universal performance claim; the heap estimate
includes fixed Document/runtime overhead, not exact allocator bytes.

## Phase 3 — Shared data model and transactions

- [x] Add shared Map and Array/List; Text specializes the shared sequence behavior.
- [x] Define bounded recursive `Value` data and copy mutable containers at API boundaries.
- [x] Add atomic transaction boundaries and deterministic copied change sets.
- [x] Add observer APIs without exposing mutable storage representation; queue reentrant notifications in commit order.
- [x] Define nested shared values as separately named roots and document ownership.

**Exit:** common collaborative document structures can be mutated atomically and observed deterministically.

## Phase 4 — Incremental synchronization

- [x] Implement causal frontier/state-vector exchange with Lamport metadata and checkpoint epochs.
- [x] Compute retained event tails or checkpoint-plus-tail updates.
- [x] Make update application idempotent and independent of valid delivery order.
- [x] Add a bounded, versioned native binary format with typed malformed-input errors.
- [x] Test full and incremental sync, round trips, duplicate delivery, and multi-hop propagation.

**Exit:** a fresh or stale replica synchronizes without replaying unrelated history.

## Phase 5 — Yjs interoperability boundary

- [x] Decide the exact compatibility tier from the Phase 0 matrix: fixture-tested sequential semantic projection only.
- [x] Record that Yjs wire codecs are not required by this tier and remain unsupported.
- [x] Add differential fixtures generated by upstream Yjs 13.6.32.
- [x] Keep Yjs fixture tooling and its dependency separate from the native core.
- [x] Document unsupported Yjs API, concurrency, relative-position, and wire behavior explicitly.

**Exit:** supported compatibility claims are fixture-tested against upstream Yjs.

## Phase 6 — Compaction / GC

- [x] Define retention requirements for deletes, history, relative positions, and late replicas.
- [x] Implement checkpoints that discard retained history and deleted anchors under an active-peer acknowledgement/fencing contract.
- [x] Separate retained logical history from checkpoint materialization.
- [x] Test reconnect-after-compaction, stale dirty replicas, remote checkpoint lease barriers, and adversarial offline/churn cases.
- [x] Benchmark fixed-live document metadata growth over increasing histories.

**Exit:** storage growth can be bounded under a documented synchronization/retention policy.

## Phase 7 — Production surface

- [x] Implement undo/redo as semantic compensating transactions, preserving concurrent winners.
- [x] Add an application-provided byte persistence adapter.
- [x] Add provider-neutral sync byte hooks; awareness/presence stays outside durable CRDT state.
- [x] Run deterministic model/property/regression tests in CI; these are not a fuzzer.
- [x] Add benchmark correctness/smoke tests for native, JavaScript, and Wasm GC.
- [x] Add API docs and runnable collaboration examples.

**Exit:** stable native API with explicit compatibility guarantees and reproducible performance/correctness tests.

## Algorithm decision gate

Do **not** commit Y.mbt to Yjs internals before Phase 2. Compare:

1. **Yjs-compatible internals** — shortest path to wire compatibility, but imports Yjs/JavaScript representation constraints.
2. **MoonBit-native event graph / Eg-walker-inspired core** — cleaner separation of history and materialized state and a stronger fit for typed domain modeling, but requires compatibility adapters.
3. **Hybrid** — MoonBit-native semantic/event core plus optional Yjs codec/index structures at the boundary.

Recorded direction: a MoonBit-native causal/event core with indexed
materialization and a separate fixture-tested sequential semantic boundary.
The independent replay projector is a bounded cold-materialization candidate,
not a second full `Document` implementation. A pinned upstream Yjs 13.6.32
JavaScript struct store was performance-measured on the shared logical edit
trace; it was not ported as the native implementation. Its encoded-update
integration path and the native decoded-event path perform different work, so
the comparison is bounded candidate evidence, not equivalent-throughput
evidence. See `docs/algorithm-decision.md` and `docs/benchmarks.md` for the
workloads and limitations.

## Required correctness tests

- Same operations under every tested valid delivery permutation => same canonical state.
- Duplicate update application => no semantic change.
- Batched vs individual application => same state.
- Offline branch merge => convergence.
- Encode/decode => semantic round trip.
- Native incremental sync => same state as full sync.
- Selected Yjs semantic projection: compare outputs with fixtures generated by upstream Yjs; Yjs wire round trips are not applicable because no wire compatibility is claimed.
- Malformed/truncated/untrusted binary input => typed failure, no partial corruption.

## Benchmark dimensions

Track visible document size and history size independently. Measure setup-inclusive local insert/delete, indexed remote merge, replay projection, long edit histories, state-vector/frontier calculation, diff encoding, checkpoint payload size, process-level heap change, and compaction. The available heap probe is not exact allocator bytes per element.

## Initial non-goals

- Provider/network implementation.
- Awareness/presence in durable CRDT state.
- Exact JavaScript API emulation.
- Yjs algorithm fidelity for its own sake.
- Premature optimization before invariant/property tests exist.

## Current verification

- `moon fmt --check`, `moon fmt --check scripts/yjs-fixtures.mbtx`, and
  `moon fmt --check bench` pass.
- `moon info --target all` and `moon check --target all` pass with the generated
  public-interface snapshots.
- `moon test --target all` passes 49 total tests per target: 47 core tests and
  two benchmark projection tests on native, JavaScript, Wasm, and Wasm GC.
- `npm ci --prefix compat/yjs` followed by
  `moon run --target js scripts/yjs-fixtures.mbtx --check` confirms that
  upstream-generated fixture data and embedded test data match.
- CI also runs examples and benchmark equality/smoke cases across native,
  JavaScript, and Wasm GC. The model schedules are deterministic; the benchmark
  documents disclose their setup and limits.
- See [docs/invariants.md](../../docs/invariants.md),
  [docs/compatibility.md](../../docs/compatibility.md),
  [docs/retention.md](../../docs/retention.md),
  [docs/algorithm-decision.md](../../docs/algorithm-decision.md), and
  [docs/benchmarks.md](../../docs/benchmarks.md).

## Changelog impact

The repository did not contain `CHANGES.md`. This initial public implementation
records its API, compatibility boundary, persistence scope, and retention and
recovery contract in `README.md`, `README.mbt.md`, and the linked reference
documents. No separate changelog file was introduced.

## Change history

- 2026-10-06: implemented the native CRDT core and recorded compatibility,
  retention, persistence, and benchmark evidence; all roadmap phases complete.
