///|
/// Create a new replica with an application-chosen stable identifier.
pub fn Document::new(replica : String) -> Result[Document, CrdtError] {
  if !utf16_is_well_formed(replica) {
    return Err(InvalidUnicode)
  }
  match validate_update_string(replica) {
    Err(error) => return Err(error)
    Ok(_) => ()
  }
  if replica.is_empty() || replica.contains("\u{0}") {
    return Err(InvalidReplicaId)
  }
  Ok({
    replica,
    clock: {},
    lamports: {},
    maps: {},
    lists: {},
    texts: {},
    integrated: {},
    pending: {},
    rejected_pending: {},
    history: [],
    checkpoint: None,
    undo: [],
    redo: [],
    peer_acks: {},
    observers: [],
    next_observer_id: 1,
    notifying_observers: false,
    notification_queue: [],
  })
}

///|
/// Return this replica's stable identifier.
pub fn Document::replica(self : Document) -> String {
  self.replica
}

///|
/// Return the current contiguous causal frontier.
pub fn Document::state_vector(self : Document) -> StateVector {
  let vector = {
    clocks: clone_clock_map(self.clock),
    lamports: clone_clock_map(self.lamports),
    checkpoint: None,
  }
  match self.checkpoint {
    Some(checkpoint) => vector_set_checkpoint(vector, Some(checkpoint.id))
    None => vector
  }
}

///|
/// Return the number of integrated and queued events.
pub fn Document::event_counts(self : Document) -> (Int, Int) {
  (self.integrated.length(), self.pending.length())
}

///|
/// Return the visible value for a shared map entry.
pub fn Document::map_get(
  self : Document,
  root : String,
  key : String,
) -> Value? {
  match self.maps.get(root) {
    None => None
    Some(registers) =>
      match registers.get(key) {
        None => None
        Some(register) => register.value.map(value => value.clone())
      }
  }
}

///|
/// Return a recursively copied, visible map snapshot.
pub fn Document::map_snapshot(
  self : Document,
  root : String,
) -> Map[String, Value] {
  let output : Map[String, Value] = {}
  match self.maps.get(root) {
    None => ()
    Some(registers) =>
      for key, register in registers {
        match register.value {
          None => ()
          Some(value) => output[key] = value.clone()
        }
      }
  }
  output
}

///|
/// Return the visible values in a shared list.
pub fn Document::list_values(self : Document, root : String) -> Array[Value] {
  match self.lists.get(root) {
    None => []
    Some(sequence) => sequence_visible_values(sequence)
  }
}

///|
/// Return the visible text as Unicode scalar values joined into a string.
pub fn Document::text(self : Document, root : String) -> String {
  match self.texts.get(root) {
    None => ""
    Some(sequence) => {
      let output = StringBuilder::new()
      for value in sequence_visible_values(sequence) {
        match value {
          String(character) => output.write_string(character)
          _ => ()
        }
      }
      output.to_string()
    }
  }
}

///|
/// Apply a batch of remote events atomically. Events with missing causal
/// predecessors are retained in a bounded pending queue and integrated later.
/// Local transactions do not drain that queue; providers retry pending events
/// with this method or `retry_pending` after receiving their dependencies.
pub fn Document::apply_events(
  self : Document,
  events : Array[Event],
) -> Result[ChangeSet, CrdtError] {
  let before = clone_document(self)
  let staged = clone_document(self)
  let applied = match apply_events_to_staged(staged, events) {
    Err(error) => return Err(error)
    Ok(applied) => applied
  }
  commit_replica_state(self, staged)
  let changes = changes_between(before, self, applied)
  if !changes.is_empty() {
    notify_observers(self, changes)
  }
  Ok(changes)
}

///|
/// Retry queued events after a provider delivers their missing predecessors.
pub fn Document::retry_pending(self : Document) -> Result[ChangeSet, CrdtError] {
  self.apply_events([])
}

///| Discard one rejected or no-longer-useful event from the bounded pending

///|
/// queue. The caller can inspect event identities with `pending_events`.
pub fn Document::discard_pending(self : Document, id : EventId) -> Bool {
  if self.pending.contains(id) {
    self.pending.remove(id)
    true
  } else {
    false
  }
}

///| Return deterministic diagnostics for dependency-ready events rejected

///|
/// after they were previously queued while missing a predecessor.
pub fn Document::rejected_events(
  self : Document,
) -> Array[(EventId, CrdtError)] {
  let output : Array[(EventId, CrdtError)] = []
  for id, error in self.rejected_pending {
    output.push((id, error))
  }
  output.sort_by((left, right) => EventId::compare(left.0, right.0))
  output
}

///|
/// Discard one retained deferred-event diagnostic.
pub fn Document::discard_rejected(self : Document, id : EventId) -> Bool {
  if self.rejected_pending.contains(id) {
    self.rejected_pending.remove(id)
    true
  } else {
    false
  }
}

///|
fn apply_events_to_staged(
  staged : Document,
  events : Array[Event],
) -> Result[Array[EventId], CrdtError] {
  let input_ids : Map[EventId, Unit] = {}
  for input in events {
    let event = match
      Event::new(input.id, input.dependencies, input.operation) {
      Err(error) => return Err(error)
      Ok(event) => event
    }
    if is_stale_epoch(staged, event) {
      return Err(PeerBehindCheckpoint)
    }
    if staged.rejected_pending.contains(event.id) {
      return Err(staged.rejected_pending[event.id])
    }
    let was_queued = staged.pending.contains(event.id)
    match covered_by_checkpoint(staged, event) {
      true => ()
      false =>
        match staged.integrated.get(event.id) {
          Some(existing) =>
            if existing != event {
              return Err(ConflictingDuplicate)
            }
          None =>
            match staged.pending.get(event.id) {
              Some(existing) =>
                if existing != event {
                  return Err(ConflictingDuplicate)
                }
              None => {
                if staged.pending.length() + staged.rejected_pending.length() >=
                  MAX_PENDING_EVENTS {
                  return Err(PendingLimit)
                }
                staged.pending[event.id] = event
              }
            }
        }
    }
    if !was_queued {
      input_ids[event.id] = ()
    }
  }
  match reject_pending_cycles(staged) {
    Err(error) => return Err(error)
    Ok(_) => ()
  }
  match drain_pending(staged, input_ids) {
    Err(error) => return Err(error)
    Ok(applied) => Ok(applied)
  }
}

///|
/// Return a deterministic copy of all retained integrated events.
pub fn Document::events(self : Document) -> Array[Event] {
  let events = self.integrated.values().to_array()
  sort_events(events)
  events.map(event => {
    Event::new(event.id, event.dependencies, event.operation).unwrap()
  })
}

///|
/// Return a deterministic copy of events waiting for missing predecessors.
pub fn Document::pending_events(self : Document) -> Array[Event] {
  let events = self.pending.values().to_array()
  events.sort_by((left, right) => EventId::compare(left.id, right.id))
  events.map(event => {
    Event::new(event.id, event.dependencies, event.operation).unwrap()
  })
}

///|
fn commit_replica_state(target : Document, source : Document) -> Unit {
  target.clock = clone_clock_map(source.clock)
  target.lamports = clone_clock_map(source.lamports)
  target.maps = clone_maps(source.maps)
  target.lists = clone_sequence_roots(source.lists)
  target.texts = clone_sequence_roots(source.texts)
  target.integrated = clone_event_map(source.integrated)
  target.pending = clone_event_map(source.pending)
  target.rejected_pending = source.rejected_pending.copy()
  target.history = source.history.map(event => {
    Event::new(event.id, event.dependencies, event.operation).unwrap()
  })
  target.checkpoint = source.checkpoint.map(value => {
    id: value.id,
    frontier: clone_vector(value.frontier),
    maps: clone_maps(value.maps),
    lists: clone_sequence_roots(value.lists),
    texts: clone_sequence_roots(value.texts),
  })
  target.undo = clone_undo_records(source.undo)
  target.redo = clone_undo_records(source.redo)
  target.peer_acks = clone_state_vectors(source.peer_acks)
}

///|
fn is_stale_epoch(document : Document, event : Event) -> Bool {
  match document.checkpoint {
    None => event.dependencies.checkpoint is Some(_)
    Some(checkpoint) =>
      if event.dependencies.checkpoint is Some(id) && id == checkpoint.id {
        false
      } else {
        true
      }
  }
}

///|
fn covered_by_checkpoint(document : Document, event : Event) -> Bool {
  match document.checkpoint {
    None => false
    Some(checkpoint) =>
      checkpoint.frontier.counter(event.id.replica()) >= event.id.counter()
  }
}

///|
fn event_ready(document : Document, event : Event) -> Bool {
  let counter = document.clock.get(event.id.replica()).unwrap_or(0)
  if counter == 2147483647 || event.id.counter() != counter + 1 {
    return false
  }
  for replica, required in event.dependencies.clocks {
    if document.clock.get(replica).unwrap_or(0) < required {
      return false
    }
  }
  true
}

///|
fn drain_pending(
  document : Document,
  input_ids : Map[EventId, Unit],
) -> Result[Array[EventId], CrdtError] {
  let applied : Array[EventId] = []
  let mut progressed = true
  while progressed {
    progressed = false
    let candidates = document.pending.values().to_array()
    candidates.sort_by((left, right) => {
      if left.lamport == right.lamport {
        EventId::compare(left.id, right.id)
      } else {
        left.lamport - right.lamport
      }
    })
    for event in candidates {
      if event_ready(document, event) {
        match validate_event_dependencies(document, event) {
          Err(error) => {
            if input_ids.contains(event.id) {
              return Err(error)
            }
            if !is_quarantinable_deferred_error(error) {
              return Err(error)
            }
            document.pending.remove(event.id)
            document.rejected_pending[event.id] = error
            progressed = true
          }
          Ok(_) => ()
        }
        if document.pending.contains(event.id) {
          match integrate_event(document, event) {
            Err(error) => {
              if input_ids.contains(event.id) {
                return Err(error)
              }
              if !is_quarantinable_deferred_error(error) {
                return Err(error)
              }
              document.pending.remove(event.id)
              document.rejected_pending[event.id] = error
              progressed = true
            }
            Ok(_) => {
              document.pending.remove(event.id)
              applied.push(event.id)
              progressed = true
            }
          }
        }
      }
    }
  }
  Ok(applied)
}

///| Only event-specific validation failures are quarantined. Resource and

///| capacity failures abort the current batch so no partially integrated

///|
/// event can become visible.
fn is_quarantinable_deferred_error(error : CrdtError) -> Bool {
  match error {
    InvalidEvent
    | InvalidDependency
    | MissingAnchor
    | AnchorTypeMismatch
    | PeerBehindCheckpoint => true
    _ => false
  }
}

///| Reject only cycles whose missing causal edges are all represented in the

///|
/// current pending queue. A genuinely absent predecessor remains queueable.
fn reject_pending_cycles(document : Document) -> Result[Unit, CrdtError] {
  let indegree : Map[EventId, Int] = {}
  let outgoing : Map[EventId, Array[EventId]] = {}
  for id, _ in document.pending {
    indegree[id] = 0
    outgoing[id] = []
  }
  for id, event in document.pending {
    for replica, counter in event.dependencies.clocks {
      if counter > 0 {
        let dependency = EventId::new(replica, counter).unwrap()
        if document.pending.contains(dependency) {
          let targets = outgoing[dependency]
          targets.push(id)
          indegree[id] = indegree[id] + 1
        }
      }
    }
  }
  let ready : Array[EventId] = []
  for id, degree in indegree {
    if degree == 0 {
      ready.push(id)
    }
  }
  let mut visited = 0
  while !ready.is_empty() {
    let id = ready.pop().unwrap()
    visited += 1
    for target in outgoing[id] {
      indegree[target] = indegree[target] - 1
      if indegree[target] == 0 {
        ready.push(target)
      }
    }
  }
  if visited == document.pending.length() {
    Ok(())
  } else {
    Err(InvalidDependency)
  }
}

///| Verify each advertised causal stamp against the retained event log or

///|
/// exact checkpoint frontier before using it to order map writes.
fn validate_event_dependencies(
  document : Document,
  event : Event,
) -> Result[Unit, CrdtError] {
  match document.checkpoint {
    None =>
      if event.dependencies.checkpoint is Some(_) {
        return Err(PeerBehindCheckpoint)
      }
    Some(checkpoint) =>
      if event.dependencies.checkpoint != Some(checkpoint.id) ||
        !event.dependencies.dominates(checkpoint.frontier) {
        return Err(PeerBehindCheckpoint)
      }
  }
  for replica, counter in event.dependencies.clocks {
    if counter == 0 {
      continue
    }
    let advertised = event.dependencies.lamports.get(replica).unwrap_or(0)
    let actual = match known_lamport(document, replica, counter) {
      None => return Err(PeerBehindCheckpoint)
      Some(timestamp) => timestamp
    }
    if actual != advertised {
      return Err(InvalidDependency)
    }
  }
  if !causal_vector_is_closed(document, event.dependencies) {
    return Err(InvalidDependency)
  }
  Ok(())
}

///| Each advertised terminal event must bring its complete retained causal

///|
/// past. A compacted epoch contributes its entire checkpoint floor.
fn causal_vector_is_closed(document : Document, vector : StateVector) -> Bool {
  match document.checkpoint {
    None => if vector.checkpoint is Some(_) { return false }
    Some(checkpoint) =>
      if vector.checkpoint != Some(checkpoint.id) ||
        !vector.dominates(checkpoint.frontier) {
        return false
      }
  }
  for (replica, counter, _) in vector.metadata_entries() {
    if counter == 0 {
      continue
    }
    match document.checkpoint {
      Some(checkpoint) if counter == checkpoint.frontier.counter(replica) => ()
      Some(checkpoint) if counter < checkpoint.frontier.counter(replica) =>
        return false
      _ => {
        let id = match EventId::new(replica, counter) {
          Err(_) => return false
          Ok(id) => id
        }
        let event = match document.integrated.get(id) {
          None => return false
          Some(event) => event
        }
        if event.dependencies.checkpoint != vector.checkpoint ||
          !vector.dominates(event.dependencies) {
          return false
        }
      }
    }
  }
  true
}

///|
/// Look up the exact Lamport timestamp for one contiguous replica counter.
fn known_lamport(document : Document, replica : String, counter : Int) -> Int? {
  if counter == 0 {
    return Some(0)
  }
  match document.checkpoint {
    Some(checkpoint) if checkpoint.frontier.counter(replica) == counter =>
      Some(checkpoint.frontier.lamport(replica))
    _ =>
      match EventId::new(replica, counter) {
        Err(_) => None
        Ok(id) => document.integrated.get(id).map(event => event.lamport)
      }
  }
}

///|
fn vector_sum(vector : StateVector) -> Int {
  let mut sum = 0
  for _, counter in vector.clocks {
    sum += counter
  }
  sum
}

///|
fn integrate_event(
  document : Document,
  event : Event,
) -> Result[Unit, CrdtError] {
  if document.history.length() >= MAX_RETAINED_EVENTS {
    return Err(EventLimit)
  }
  if !document.clock.contains(event.id.replica()) &&
    document.clock.length() >= MAX_UPDATE_CLOCKS {
    return Err(UpdateTooLarge)
  }
  match validate_operation(document, event) {
    Err(error) => return Err(error)
    Ok(_) => ()
  }
  match event.operation {
    MapSet(_, _, _) | MapDelete(_, _) | MapRestore(_, _, _, _) => ()
    SequenceInsert(root, kind, after, value) => {
      let sequence = ensure_sequence(document, root, kind)
      sequence.nodes[EventNode(event.id)] = {
        id: EventNode(event.id),
        after,
        lamport: event.lamport,
        value: value.clone(),
        deleted: false,
      }
    }
    SequenceDelete(root, kind, target) => {
      let sequence = ensure_sequence(document, root, kind)
      let node = sequence.nodes[target]
      sequence.nodes[target] = {
        id: node.id,
        after: node.after,
        lamport: node.lamport,
        value: node.value,
        deleted: true,
      }
    }
  }
  document.clock[event.id.replica()] = event.id.counter()
  document.lamports[event.id.replica()] = event.lamport
  document.integrated[event.id] = event
  document.history.push(event)
  match event.operation {
    MapSet(root, key, _) | MapDelete(root, key) | MapRestore(root, key, _, _) =>
      recompute_map_register(document, root, key)
    _ => ()
  }
  Ok(())
}

///|

///|
fn validate_operation(
  document : Document,
  event : Event,
) -> Result[Unit, CrdtError] {
  match event.operation {
    MapSet(root, _, value) => {
      if root.is_empty() {
        return Err(InvalidEvent)
      }
      match validate_value(value, 0) {
        Err(error) => return Err(error)
        Ok(_) => ()
      }
    }
    MapDelete(root, _) => if root.is_empty() { return Err(InvalidEvent) }
    SequenceInsert(root, kind, after, value) => {
      if root.is_empty() {
        return Err(InvalidEvent)
      }
      match validate_value(value, 0) {
        Err(error) => return Err(error)
        Ok(_) => ()
      }
      match
        validate_node_dependency(
          document,
          event.dependencies,
          root,
          kind,
          after,
        ) {
        Err(error) => return Err(error)
        Ok(_) => ()
      }
      match after {
        Root => ()
        _ =>
          match sequence_get(document, root, kind) {
            None =>
              return Err(
                if sequence_node_exists_elsewhere(document, root, kind, after) {
                  AnchorTypeMismatch
                } else {
                  MissingAnchor
                },
              )
            Some(sequence) =>
              match sequence.nodes.get(after) {
                None => return Err(MissingAnchor)
                Some(_) => ()
              }
          }
      }
      match value {
        String(text) if kind is Text =>
          if !utf16_is_well_formed(text) {
            return Err(InvalidUnicode)
          } else if text.char_length() != 1 {
            return Err(InvalidEvent)
          }
        String(_) if kind is List => ()
        _ if kind is Text => return Err(InvalidEvent)
        _ => ()
      }
    }
    SequenceDelete(root, kind, target) => {
      if root.is_empty() {
        return Err(InvalidEvent)
      }
      match
        validate_node_dependency(
          document,
          event.dependencies,
          root,
          kind,
          target,
        ) {
        Err(error) => return Err(error)
        Ok(_) => ()
      }
      match sequence_get(document, root, kind) {
        None =>
          return Err(
            if sequence_node_exists_elsewhere(document, root, kind, target) {
              AnchorTypeMismatch
            } else {
              MissingAnchor
            },
          )
        Some(sequence) =>
          match sequence.nodes.get(target) {
            None =>
              return Err(
                if sequence_node_exists_elsewhere(document, root, kind, target) {
                  AnchorTypeMismatch
                } else {
                  MissingAnchor
                },
              )
            Some(_) => ()
          }
      }
    }
    MapRestore(root, key, target, value) => {
      if root.is_empty() {
        return Err(InvalidEvent)
      }
      if !event.dependencies.includes(target) {
        return Err(InvalidDependency)
      }
      match validate_value_option(value, 0) {
        Err(error) => return Err(error)
        Ok(_) => ()
      }
      let _ = key
    }
  }
  Ok(())
}

///|
fn validate_value(value : Value, depth : Int) -> Result[Unit, CrdtError] {
  if depth > MAX_VALUE_DEPTH {
    return Err(InvalidValueDepth)
  }
  match value {
    Array(values) =>
      for value in values {
        match validate_value(value, depth + 1) {
          Err(error) => return Err(error)
          Ok(_) => ()
        }
      }
    Object(values) =>
      for _, value in values {
        match validate_value(value, depth + 1) {
          Err(error) => return Err(error)
          Ok(_) => ()
        }
      }
    _ => ()
  }
  Ok(())
}

///|
fn validate_value_option(
  value : Value?,
  depth : Int,
) -> Result[Unit, CrdtError] {
  match value {
    None => Ok(())
    Some(value) => validate_value(value, depth)
  }
}

///| A sequence operation may only name an anchor in its causal past. The

///|
/// checkpoint epoch stands for every anchor materialized by that snapshot.
fn validate_node_dependency(
  document : Document,
  dependencies : StateVector,
  root : String,
  kind : SequenceKind,
  node : NodeId,
) -> Result[Unit, CrdtError] {
  match node {
    Root => Ok(())
    EventNode(id) =>
      if dependencies.includes(id) {
        Ok(())
      } else {
        Err(InvalidDependency)
      }
    CheckpointNode(id, node_root, node_kind, _) if node_root == root &&
      node_kind == kind =>
      match document.checkpoint {
        Some(checkpoint) if checkpoint.id == id &&
          dependencies.checkpoint == Some(id) => Ok(())
        _ => Err(InvalidDependency)
      }
    CheckpointNode(_, _, _, _) => Err(AnchorTypeMismatch)
  }
}

///|
fn validate_operation_value(operation : Operation) -> Result[Unit, CrdtError] {
  match operation {
    MapSet(root, key, value) => {
      if root.is_empty() {
        return Err(InvalidEvent)
      }
      match validate_update_string(root) {
        Err(error) => return Err(error)
        Ok(_) => ()
      }
      match validate_update_string(key) {
        Err(error) => return Err(error)
        Ok(_) => ()
      }
      validate_update_value(value, 0, [MAX_UPDATE_VALUE_NODES])
    }
    MapDelete(root, key) => {
      if root.is_empty() {
        return Err(InvalidEvent)
      }
      match validate_update_string(root) {
        Err(error) => return Err(error)
        Ok(_) => ()
      }
      validate_update_string(key)
    }
    SequenceInsert(root, kind, after, value) => {
      if root.is_empty() {
        return Err(InvalidEvent)
      }
      match validate_update_string(root) {
        Err(error) => return Err(error)
        Ok(_) => ()
      }
      match validate_node_id(after) {
        Err(error) => return Err(error)
        Ok(_) => ()
      }
      match (kind, value) {
        (Text, String(text)) => {
          match validate_update_string(text) {
            Err(error) => return Err(error)
            Ok(_) => ()
          }
          if text.char_length() != 1 {
            return Err(InvalidEvent)
          }
        }
        (Text, _) => return Err(InvalidEvent)
        _ => ()
      }
      validate_update_value(value, 0, [MAX_UPDATE_VALUE_NODES])
    }
    SequenceDelete(root, _, target) => {
      if root.is_empty() {
        return Err(InvalidEvent)
      }
      match validate_update_string(root) {
        Err(error) => return Err(error)
        Ok(_) => ()
      }
      validate_node_id(target)
    }
    MapRestore(root, key, target, value) => {
      if root.is_empty() {
        return Err(InvalidEvent)
      }
      match validate_update_string(root) {
        Err(error) => return Err(error)
        Ok(_) => ()
      }
      match validate_update_string(key) {
        Err(error) => return Err(error)
        Ok(_) => ()
      }
      match EventId::new(target.replica(), target.counter()) {
        Err(error) => return Err(error)
        Ok(_) => ()
      }
      match value {
        None => Ok(())
        Some(value) => validate_update_value(value, 0, [MAX_UPDATE_VALUE_NODES])
      }
    }
  }
}

///|
fn ensure_sequence(
  document : Document,
  root : String,
  kind : SequenceKind,
) -> SequenceState {
  match kind {
    List =>
      match document.lists.get(root) {
        Some(sequence) => sequence
        None => {
          let sequence = empty_sequence()
          document.lists[root] = sequence
          sequence
        }
      }
    Text =>
      match document.texts.get(root) {
        Some(sequence) => sequence
        None => {
          let sequence = empty_sequence()
          document.texts[root] = sequence
          sequence
        }
      }
  }
}

///|
fn sequence_get(
  document : Document,
  root : String,
  kind : SequenceKind,
) -> SequenceState? {
  match kind {
    List => document.lists.get(root)
    Text => document.texts.get(root)
  }
}

///| A reference to a node in another root or sequence kind is a type

///|
/// mismatch; a node absent from every retained sequence is a missing anchor.
fn sequence_node_exists_elsewhere(
  document : Document,
  root : String,
  kind : SequenceKind,
  node : NodeId,
) -> Bool {
  for other_root, sequence in document.lists {
    if (other_root != root || kind != List) && sequence.nodes.contains(node) {
      return true
    }
  }
  for other_root, sequence in document.texts {
    if (other_root != root || kind != Text) && sequence.nodes.contains(node) {
      return true
    }
  }
  false
}

///|
fn sort_events(events : Array[Event]) -> Unit {
  events.sort_by((left, right) => {
    let depth_order = left.lamport - right.lamport
    if depth_order != 0 {
      depth_order
    } else {
      EventId::compare(left.id, right.id)
    }
  })
}

///|
const MAX_PENDING_EVENTS : Int = 100000

///|
const MAX_RETAINED_EVENTS : Int = 1000000

///|
const MAX_VALUE_DEPTH : Int = 128
