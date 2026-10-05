# Y.mbt

Y.mbt is a MoonBit-native local-first CRDT for shared maps, lists, and plain
text. Replicas edit independently, exchange causal updates through an
application-owned transport, and converge without relying on delivery order.
Its API, event representation, and versioned binary format belong to this
library; it does not emulate Yjs internals or wire bytes.

The public surface includes causally validated events and state vectors,
atomic user transactions with copied change sets, Unicode-scalar text
positions, semantic undo/redo, full and incremental updates, compaction
checkpoints, and callback-based persistence/provider boundaries. Mutable
values returned to callers are copied, and malformed remote updates fail
without partially changing document state.

## Quick start

The runnable example shows two offline replicas exchanging full and incremental
updates, observing a transaction, syncing undo/redo, and saving/restoring a
document through an in-memory persistence adapter:

```sh
moon run --target native examples
```

Applications own delivery, retry, storage, and peer coordination. A provider
can ask for the bytes missing from a peer and apply bytes received from it:

```moonbit
let update_bytes = alice.sync_update(bob.state_vector()).unwrap()
let _ = bob.apply_sync_update(update_bytes).unwrap()
```

`sync_update` uses Y.mbt's versioned native format. Exchange the peer state
vector through the application's protocol; do not pass these bytes to a Yjs
provider. See [the collaboration example](examples/README.md) for a complete
workflow and [the public API documentation](README.mbt.md).

`full_update` and `persist` save the durable shared projection and causal
frontier (including a checkpoint and retained event tail when present). They
do not save the whole mutable `Document` session: pending and rejected event
diagnostics, peer leases, observers, undo/redo history, and relative-position
handles are transient. Restored documents start with empty pending/diagnostic
and undo state; applications must register observers and peer leases again.

## Semantics and retention

Text indexes count Unicode scalar values. Map conflicts use a deterministic
Lamport/event-identity order that extends causal order. Concurrent sequence
insertions use stable event identities and Lamport metadata; relative
positions retain left/right boundaries and expire when their checkpoint epoch
is replaced.

String inputs with isolated UTF-16 surrogates return `InvalidUnicode` before
conversion or persistence. Valid astral text, U+FFFD, and NUL string values
round-trip without replacement; identifier boundaries separately reject NUL.

Compaction is a coordinated retention boundary. Every tracked active peer must
acknowledge the local frontier before local compaction or installation of a
new remote checkpoint can discard local history. A provider must fence peer
edits while coordinating an epoch transition, or explicitly expire a peer
lease and accept that an old reconnect needs application-level recovery. See
[the retention contract](docs/retention.md). Same-epoch checkpoint replay is
idempotent and preserves edits made above its baseline.
The provider must assign globally unique checkpoint IDs and never reuse one
across replicas or persistence/restore lifetimes; the bounded document keeps
only the active epoch ID.

Events missing causal predecessors wait in a bounded queue. If a previously
queued event becomes ready and fails event-specific validation, Y.mbt removes
it from that queue and exposes the typed reason through
`Document::rejected_events`; use `discard_rejected` after recording or
resolving the error. Capacity failures abort the current batch atomically.
Local transactions do not implicitly retry remote pending events; providers
can call `retry_pending` after delivery.

See [the invariant and limit reference](docs/invariants.md) for causal,
ownership, observer, codec, and resource-limit guarantees.

## Yjs compatibility

The compatibility boundary is **sequential semantic projection only** for
fixture-tested map set/overwrite/delete, indexed array insertion/deletion, and
plain text insertion/deletion. The fixtures are generated from upstream Yjs
13.6.32. Yjs JavaScript API compatibility, concurrent winner equivalence, and
Yjs update/state-vector/snapshot wire compatibility are unsupported. See
[the compatibility matrix and fixture provenance](docs/compatibility.md) and
the current [algorithm decision](docs/algorithm-decision.md).

## Development checks

```sh
moon fmt --check
moon info --target all
moon check --target all
moon test --target all
moon run --target native examples
moon bench --target native bench/measure
npm ci --prefix compat/yjs
moon run --target js scripts/yjs-fixtures.mbtx --check
```

The CI matrix also runs the collaboration example and benchmark correctness
smoke tests on native, JavaScript, and Wasm GC. Benchmark measurements and
their limits are documented in [docs/benchmarks.md](docs/benchmarks.md).
