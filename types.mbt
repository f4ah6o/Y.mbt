///|
/// Values stored in shared maps and lists. Container values are copied when
/// they cross the document boundary; nested shared objects are intentionally
/// represented by named roots rather than aliased `Value` containers.
pub(all) enum Value {
  Null
  Bool(Bool)
  Int(Int)
  String(String)
  Array(Array[Value])
  Object(Map[String, Value])
} derive(Eq, Debug)

///|
/// Return an owned copy, recursively copying mutable containers.
fn Value::clone(value : Value) -> Value {
  match value {
    Null => Null
    Bool(value) => Bool(value)
    Int(value) => Int(value)
    String(value) => String(value)
    Array(values) => Array(values.map(value => value.clone()))
    Object(values) => {
      let output : Map[String, Value] = {}
      for key, value in values {
        output[key] = value.clone()
      }
      Object(output)
    }
  }
}

///|
/// A globally unique event identity. Counters are contiguous per replica.
struct EventId {
  replica : String
  counter : Int
} derive(Eq, Hash, Compare, Debug)

///|
/// Construct an event identity after validating its replica and counter.
pub fn EventId::new(
  replica : String,
  counter : Int,
) -> Result[EventId, CrdtError] {
  if !utf16_is_well_formed(replica) {
    Err(InvalidUnicode)
  } else {
    match validate_update_string(replica) {
      Err(error) => Err(error)
      Ok(_) =>
        if replica.is_empty() || replica.contains("\u{0}") {
          Err(InvalidReplicaId)
        } else if counter <= 0 {
          Err(InvalidEventCounter)
        } else {
          Ok({ replica, counter, })
        }
    }
  }
}

///|
/// Return the replica component of an event identity.
pub fn EventId::replica(self : EventId) -> String {
  self.replica
}

///|
/// Return the contiguous counter component of an event identity.
pub fn EventId::counter(self : EventId) -> Int {
  self.counter
}

///|
/// A node identity used by relative positions and RGA sequence links.
pub(all) enum NodeId {
  Root
  CheckpointNode(String, String, SequenceKind, Int)
  EventNode(EventId)
} derive(Eq, Hash, Compare, Debug)

///|
/// Sequence and text operations use the same replicated sequence semantics.
pub(all) enum SequenceKind {
  List
  Text
} derive(Eq, Hash, Compare, Debug)

///|
/// Semantic operation carried by a causal event.
pub(all) enum Operation {
  MapSet(String, String, Value)
  MapDelete(String, String)
  SequenceInsert(String, SequenceKind, NodeId, Value)
  SequenceDelete(String, SequenceKind, NodeId)
  MapRestore(String, String, EventId, Value?)
} derive(Eq, Debug)

///|
/// A relative cursor anchored before or after a stable sequence element.
pub(all) enum Affinity {
  Before
  After
} derive(Eq, Debug)

///|
/// A stable sequence position. Positions into an older checkpoint expire when
/// the document compacts and rebases its visible sequence.
struct RelativePosition {
  root : String
  kind : SequenceKind
  left : NodeId
  right : NodeId?
  affinity : Affinity
  checkpoint : String?
} derive(Eq, Debug)

///|
/// Typed failures from validation, synchronization, or retention boundaries.
pub(all) suberror CrdtError {
  InvalidReplicaId
  InvalidEventCounter
  ClockOverflow
  InvalidEvent
  InvalidDependency
  ConflictingDuplicate
  MissingAnchor
  AnchorTypeMismatch
  PendingLimit
  EventLimit
  InvalidIndex
  InvalidRange
  InvalidValueDepth
  InvalidUnicode
  UnsupportedVersion
  MalformedUpdate
  UpdateTooLarge
  PeerBehindCheckpoint
  CheckpointConflict
  CannotCompactPending
  InvalidAcknowledgement
  StalePosition
  ObserverNotFound
  UndoUnavailable
} derive(Eq, Debug)
