///|
priv struct MapRegister {
  stamp : EventId
  lamport : Int
  value : Value?
}

///|
priv struct SequenceNode {
  id : NodeId
  after : NodeId
  lamport : Int
  value : Value
  deleted : Bool
}

///|
priv struct SequenceState {
  nodes : Map[NodeId, SequenceNode]
}

///|
priv struct Checkpoint {
  id : String
  frontier : StateVector
  maps : Map[String, Map[String, MapRegister]]
  lists : Map[String, SequenceState]
  texts : Map[String, SequenceState]
}

///|
priv struct MapVersion {
  stamp : EventId
  lamport : Int
  value : Value?
  dependencies : StateVector?
  is_restore : Bool
}

///|
priv struct Observer {
  id : Int
  callback : (ChangeSet) -> Unit
}

///|
/// Mutable local replica state. Public callers interact through validated
/// methods; all returned mutable values are recursively copied.
struct Document {
  replica : String
  mut clock : Map[String, Int]
  mut lamports : Map[String, Int]
  mut maps : Map[String, Map[String, MapRegister]]
  mut lists : Map[String, SequenceState]
  mut texts : Map[String, SequenceState]
  mut integrated : Map[EventId, Event]
  mut pending : Map[EventId, Event]
  mut rejected_pending : Map[EventId, CrdtError]
  mut history : Array[Event]
  mut checkpoint : Checkpoint?
  mut undo : Array[UndoRecord]
  mut redo : Array[UndoRecord]
  mut peer_acks : Map[String, StateVector]
  observers : Array[Observer]
  mut next_observer_id : Int
  mut notifying_observers : Bool
  notification_queue : Array[ChangeSet]
}

///|
fn empty_sequence() -> SequenceState {
  { nodes: {}, }
}

///|
fn clone_sequence(source : SequenceState) -> SequenceState {
  let nodes : Map[NodeId, SequenceNode] = {}
  for id, node in source.nodes {
    nodes[id] = {
      id: node.id,
      after: node.after,
      lamport: node.lamport,
      value: node.value.clone(),
      deleted: node.deleted,
    }
  }
  { nodes, }
}

///|
fn clone_maps(
  source : Map[String, Map[String, MapRegister]],
) -> Map[String, Map[String, MapRegister]] {
  let output : Map[String, Map[String, MapRegister]] = {}
  for root, registers in source {
    let root_output : Map[String, MapRegister] = {}
    for key, register in registers {
      root_output[key] = {
        stamp: register.stamp,
        lamport: register.lamport,
        value: register.value.map(value => value.clone()),
      }
    }
    output[root] = root_output
  }
  output
}

///|
fn clone_sequence_roots(
  source : Map[String, SequenceState],
) -> Map[String, SequenceState] {
  let output : Map[String, SequenceState] = {}
  for root, sequence in source {
    output[root] = clone_sequence(sequence)
  }
  output
}

///|
fn clone_event_map(source : Map[EventId, Event]) -> Map[EventId, Event] {
  let output : Map[EventId, Event] = {}
  for id, event in source {
    output[id] = Event::new(event.id, event.dependencies, event.operation).unwrap()
  }
  output
}

///|
fn clone_document(source : Document) -> Document {
  let integrated = clone_event_map(source.integrated)
  let pending = clone_event_map(source.pending)
  let history = source.history.map(event => {
    Event::new(event.id, event.dependencies, event.operation).unwrap()
  })
  let checkpoint = source.checkpoint.map(value => {
    id: value.id,
    frontier: clone_vector(value.frontier),
    maps: clone_maps(value.maps),
    lists: clone_sequence_roots(value.lists),
    texts: clone_sequence_roots(value.texts),
  })
  {
    replica: source.replica,
    clock: clone_clock_map(source.clock),
    lamports: clone_clock_map(source.lamports),
    maps: clone_maps(source.maps),
    lists: clone_sequence_roots(source.lists),
    texts: clone_sequence_roots(source.texts),
    integrated,
    pending,
    rejected_pending: source.rejected_pending.copy(),
    history,
    checkpoint,
    undo: clone_undo_records(source.undo),
    redo: clone_undo_records(source.redo),
    peer_acks: clone_state_vectors(source.peer_acks),
    observers: [],
    next_observer_id: source.next_observer_id,
    notifying_observers: false,
    notification_queue: [],
  }
}

///|
fn clone_state_vectors(
  source : Map[String, StateVector],
) -> Map[String, StateVector] {
  let output : Map[String, StateVector] = {}
  for peer, vector in source {
    output[peer] = clone_vector(vector)
  }
  output
}

///| Copy undo records deeply because staged compensation can rebind action

///|
/// targets after restoring maps and sequence nodes.
fn clone_undo_records(source : Array[UndoRecord]) -> Array[UndoRecord] {
  source.map(record => {
    actions: record.actions.map(action => {
      match action {
        RestoreMap(root, key, target, predecessor, value) =>
          RestoreMap(
            root,
            key,
            target,
            predecessor,
            value.map(value => value.clone()),
          )
        DeleteNode(root, kind, target) => DeleteNode(root, kind, target)
        InsertAfter(root, kind, anchor, targets) =>
          InsertAfter(
            root,
            kind,
            anchor,
            targets.map(target => {
              match target {
                (id, value, deleted_by) => (id, value.clone(), deleted_by)
              }
            }),
          )
      }
    }),
  })
}
