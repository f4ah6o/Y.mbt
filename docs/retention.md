# Checkpoint and peer-retention contract

Y.mbt compacts by starting a new checkpoint epoch. A checkpoint stores the
current live map projection and list/text values, plus the causal state vector
needed to continue event identity and conflict ordering. It drops retained
events, map deletion tombstones, deleted sequence nodes, semantic undo history,
empty sequence roots, and positions tied to the old epoch. A later event or
peer update from an old epoch is rejected; the library does not silently
rebase unknown old writes.

The provider must supply a checkpoint ID that is globally unique and never
reused across replicas or persistence/restore lifetimes. Reuse can make an old
relative-position handle appear to belong to a later epoch. The bounded
document stores only the active ID and cannot detect reuse of an older one.

## Active peer acknowledgements

`track_peer(peer, vector)` registers an active peer and its last confirmed
frontier. Registration accepts a stale frontier intentionally: it is a
retention blocker until the peer catches up or its lease is explicitly
expired. `acknowledge_peer` accepts only a known, causally closed vector that
advances the peer's previous acknowledgement. Both local `compact` and
installation of a **new remote checkpoint epoch** require every tracked peer
to acknowledge the receiver's current local frontier. Replaying the exact
already-installed checkpoint baseline is idempotent and does not discard
above-floor local edits or require another compaction acknowledgement.

An acknowledgement is a statement about the frontier the peer has received;
it does not prevent that peer from making another offline edit afterward. A
provider must coordinate an epoch transition: fence new peer edits, collect
all edits that must be retained, synchronize active peers to the final old
frontier, obtain their acknowledgements, install or create the new checkpoint,
and then resume editing in the new epoch. Y.mbt does not implement this network
coordination or a distributed write fence.

If a peer cannot participate, `expire_peer(peer)` explicitly removes its
retention lease so compaction can proceed. This accepts the possibility that
the peer has unreported offline edits. When it reconnects, its old-epoch
updates are rejected with a stale-checkpoint error. The application must keep
the old replica data for export/manual merge, or restore the new checkpoint
and have the user reapply those edits. Do not treat `expire_peer` as a way to
merge a dirty offline replica automatically.

To recover an accidentally expired peer, preserve its old local document,
create a fresh replica from the current checkpoint with `full_update`, and
reapply or import the old peer's user-level edits as new transactions. If a
peer is only missing the checkpoint and has no unreported writes, applying a
current full update is sufficient. A dirty peer whose local frontier is not
dominated by an incoming checkpoint is rejected rather than overwritten.

## Pending and rejected remote events

An event with absent causal predecessors can wait in the bounded pending
queue. A provider should retry after delivering the missing events, either by
redelivering that event with its predecessors or by calling `retry_pending`.
If a previously queued event becomes dependency-ready but its operation is
invalid in the now-known document (for example, a text insertion anchored to
a list node), that deferred event is removed from pending and recorded in
`rejected_events()` with its typed error. Valid dependencies in the same
delivery can then commit without a poison event blocking progress. Record or
report that diagnostic before calling `discard_rejected`; the rejected event
is not integrated. Capacity, clock, and other resource failures abort the
entire current batch and are never converted into a semantic rejection.

If an invalid event is submitted for the first time together with its
predecessors, that input batch fails atomically. No clocks, visible data,
observers, or pending queue changes are committed. Correct the producer or
drop the bad input and retry the valid events as a new batch.
