# f4ah6o/y

Y.mbt provides an application-owned collaboration core for MoonBit. Use
`Document::new` for a local replica, `Document::transact` to group shared-map,
list, and text edits, and `Document::observe` to receive one copied `ChangeSet`
per committed visible transition. Text indexes count Unicode scalar values.
Strings with unpaired UTF-16 surrogates fail with `InvalidUnicode` before
scalar conversion or persistence.

Exchange `StateVector` metadata through the host application's protocol.
`Document::update_since` builds the minimal retained event tail or a checkpoint
plus tail; `Update::encode` and `Update::decode` use the versioned Y.mbt binary
format. `Document::apply_update` is atomic and idempotent. Provider adapters
are not bundled: `sync_update` and `apply_sync_update` accept bytes, while
`PersistenceAdapter` accepts host-supplied load and save callbacks.

`Document::undo` and `redo` emit ordinary semantic transactions. They do not
rewind event clocks or erase concurrent winners. `Document::compact` starts a
new checkpoint epoch after active peers acknowledge the local frontier;
retention and recovery requirements are described in
[docs/retention.md](docs/retention.md).

`full_update` and `persist` preserve durable shared content and causal
metadata, not the complete mutable `Document` session. Pending and rejected
event diagnostics, active peer leases, observer registrations, undo/redo
history, and relative-position handles are transient. After restore, register
observers and peer leases again; undo/redo begins empty. See
[docs/invariants.md](docs/invariants.md) for limits and behavioral guarantees.

The runnable [offline collaboration example](examples/README.md) demonstrates
two replicas, incremental updates, observers, semantic undo/redo, and a simple
in-memory persistence adapter. The Yjs boundary is limited to fixture-tested
sequential semantic projection; see [docs/compatibility.md](docs/compatibility.md).
