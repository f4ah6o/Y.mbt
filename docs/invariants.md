# Core invariants and resource limits

This page describes the guarantees of the current MoonBit-native document
model. The wire format and public API are Y.mbt's own versioned interface;
these guarantees do not imply Yjs binary or JavaScript API compatibility.

## Causal identity and delivery

`ReplicaId` is represented as an immutable `String`, not a wrapper type. The
`Document::new` and `EventId::new` boundaries reject empty IDs and embedded
NUL characters; the update codec also enforces its byte limit. The `String`
representation keeps the public API small while preserving validation at
identity-creation boundaries.

Every accepted string must also contain well-formed UTF-16: each high
surrogate must be followed by a low surrogate, and isolated surrogates are
rejected with `InvalidUnicode` before scalar iteration or UTF-8 encoding.
Valid astral characters and U+FFFD are preserved; NUL remains allowed in
ordinary values even though identifier boundaries reject it.

Checkpoint epoch IDs are caller-supplied strings and must be globally unique
and never reused across replicas or persisted/restored lifetimes. A document
retains only its active epoch ID so compaction remains bounded; callers own
the uniqueness guarantee.

Each event has an immutable `(replica, counter)` identity. A replica's
integrated counters are contiguous, and its state vector reports the greatest
contiguous counter plus the corresponding greatest Lamport timestamp. A local
event at counter `n` must depend on exactly counter `n - 1` from its own
replica. Its Lamport timestamp is one greater than the largest timestamp in
its causal dependencies, so the `(Lamport timestamp, event identity)` order
extends happens-before and deterministically orders concurrent map writes.
An integrated document has a combined limit of 10,000 distinct replica
clocks, including its own replica when that ID is not already present. Adding
another distinct replica past this limit fails atomically with `UpdateTooLarge`;
a replica already represented in the frontier can continue advancing.

Dependencies are validated as a causally closed vector: each advertised event
must include the causal past of the event it names. Operations may only refer
to sequence anchors in their causal past, and checkpoint anchors must match
the active checkpoint, root, and sequence kind. A state vector supplied by a
peer is only a synchronization claim; the receiver checks that its counters,
timestamps, and causal past are known before using it as a diff or retention
frontier.

Applying an identical event twice is idempotent. Reusing an event identity
with a different event is a typed conflict. A batch is validated and applied
on staged state, so failure leaves the document, clock, pending queue,
diagnostics, and observers unchanged. Events whose causal predecessors have
not arrived wait in a bounded queue. If a queued event becomes ready and then
fails operation-specific validation, it is removed from pending and exposed
by `rejected_events`; resource and clock failures abort the current batch
instead of being quarantined. See [retention.md](retention.md) for provider
retry and diagnostic handling.

## Materialized maps, lists, and text

Each map key retains causal versions while its event history is retained. The
visible ordinary write is selected by Lamport timestamp, then event identity.
Semantic undo uses conditional restore operations. A restore applies only
when its target is still the applicable version in the restore's causal past;
concurrent changes are preserved. Restore candidates that are themselves
invalidated by a concurrent version are ignored consistently during
materialization and undo precondition checks.

Lists and text use an RGA-style sequence graph. Inserts name a left anchor;
siblings are ordered by descending Lamport timestamp and stable node identity.
Deleted nodes remain as hidden anchors until checkpoint compaction, which
preserves relative order for later insertions. Text is stored as one Unicode
scalar per node; all text indexes and relative-position indexes count Unicode
scalars, not UTF-8 bytes or UTF-16 code units. A relative position records
left and right boundaries, affinity, root, kind, and checkpoint epoch. Its
index can be resolved while those anchors remain in the active epoch; a
checkpoint rebases visible values and explicitly expires positions from the
previous epoch. Callers must never reuse a checkpoint ID, including after
persistence/restore or on another replica; the bounded document remembers
only its active ID and cannot detect reuse of an older one.

## Transactions, copies, and observers

`Document` and state-owning types have opaque fields. Constructors validate
inputs before copying mutable `Value` arrays and objects. Returned values,
events, vectors, snapshots, pending/rejected diagnostics, and change sets are
owned copies; mutating them cannot alter document state. Recursive values are
bounded before they are cloned or accepted, including caller-created cycles.

`transact` applies the full edit list atomically and emits one semantic
`ChangeSet` for the committed visible transition. A failed transaction emits
no change. Observer payloads are copied. Reentrant edits from an observer are
allowed; their notifications are queued FIFO behind the transition currently
being dispatched. Each queued transition uses the observer set present when
its dispatch begins. `unobserve` affects later dispatch turns and cannot
interrupt callbacks already in the current turn.

Undo and redo create fresh semantic events and never rewind clocks. They
compensate the local transaction when its effects are still applicable and
preserve concurrent winners. The undo/redo stacks are session state: they are
cleared by checkpoint installation and are not included in persistence.

## Checkpoints, synchronization, and persistence

A checkpoint contains the visible map and sequence projection, the causal
frontier, and the metadata needed to continue event identity and map conflict
ordering. It discards retained event history, map tombstones, deleted sequence
anchors, undo/redo records, and old relative positions. Unknown old-epoch
updates are rejected rather than silently rebased. Checkpoint validation
prevents rewriting known event timestamps, retained map event payloads, known
unconditional winners, or visible projection. A below-floor map stamp is
accepted only when it matches the live entry in the installed baseline. An
identical already-installed baseline may be replayed without overwriting local
events above it.

Tracked peer acknowledgements protect locally retained history both during
local compaction and when installing a new remote checkpoint epoch. A peer's
acknowledgement does not fence future offline edits; the provider must fence
writes through the epoch transition or explicitly expire the lease. See
[retention.md](retention.md) for the coordination and recovery contract.

`full_update` and `persist` contain durable shared state and causal metadata,
not a complete `Document` session. Pending and rejected remote events, peer
leases, observers, undo/redo stacks, and relative-position handles are not
serialized. Re-register observers and tracked peers after restore. Persistence
is an application-provided byte load/save callback; provider/network
coordination and awareness are outside the library.

## Native codec limits

The versioned decoder rejects unsupported versions, malformed ordering,
duplicate identities, truncation, trailing bytes, invalid UTF-8, and
over-budget values before applying an update. Current limits are:

| Resource | Limit |
| --- | ---: |
| Encoded update | 16 MiB |
| Events in one update | 100,000 |
| Replica clocks in a vector | 10,000 |
| String or encoded key | 1 MiB UTF-8 |
| Items in one array, object, list, text, or snapshot collection | 100,000 |
| Recursive value depth | 128 |
| Value nodes across one update, including checkpoint and event tail | 1,000,000 |
| Pending plus quarantined deferred events | 100,000 |
| Retained event history | 1,000,000 |

The decoder and constructors enforce the same combined checkpoint-plus-tail
value-node budget, so a successful encode remains decodable under this limit.
These limits bound individual inputs and retained queues; they are not an
authentication, authorization, or transport security layer. Applications
must authenticate peers and decide which replica identifiers and bytes to
accept.

## Verification scope

The checked-in tests exercise deterministic two- and three-replica operation
permutations, duplicate and individual delivery, offline branches, checkpoint
retention, malformed updates, Unicode indexes, and transaction semantics. CI
runs the checked-in suite on native, JavaScript, and Wasm GC targets, along
with runnable examples and benchmark equality/smoke tests. The independent
benchmark comparisons are bounded workloads and are not proofs of convergence
or general performance guarantees; see [algorithm-decision.md](algorithm-decision.md)
and [benchmarks.md](benchmarks.md). Yjs compatibility is limited to the
upstream-fixture-tested sequential semantic cases listed in
[compatibility.md](compatibility.md).
