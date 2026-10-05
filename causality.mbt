///|
/// A contiguous vector clock plus the checkpoint epoch carried by a peer.
struct StateVector {
  clocks : Map[String, Int]
  lamports : Map[String, Int]
  checkpoint : String?
} derive(Eq, Debug)

///|
/// Construct an empty state vector.
pub fn StateVector::new() -> StateVector {
  { clocks: Map([]), lamports: Map([]), checkpoint: None, }
}

///|
/// Return the highest contiguous integrated counter for `replica`.
pub fn StateVector::counter(self : StateVector, replica : String) -> Int {
  self.clocks.get(replica).unwrap_or(0)
}

///|
/// Return the checkpoint identifier associated with this vector, if any.
pub fn StateVector::checkpoint(self : StateVector) -> String? {
  self.checkpoint
}

///|
/// Return a sorted copy of the vector entries.
pub fn StateVector::entries(self : StateVector) -> Array[(String, Int)] {
  let entries = self.clocks.to_array()
  entries.sort_by((left, right) => left.0.compare(right.0))
  entries
}

///|
/// Return true when this vector includes the given event.
pub fn StateVector::includes(self : StateVector, id : EventId) -> Bool {
  self.counter(id.replica()) >= id.counter()
}

///|
/// Return true when every component in `other` is covered by `self`.
pub fn StateVector::dominates(self : StateVector, other : StateVector) -> Bool {
  for replica, counter in other.clocks {
    if self.counter(replica) < counter {
      return false
    }
  }
  true
}

///|
/// A validated immutable causal event.
struct Event {
  id : EventId
  dependencies : StateVector
  lamport : Int
  operation : Operation
} derive(Eq, Debug)

///|
/// Construct an event, rejecting invalid counters and self/cyclic clocks.
pub fn Event::new(
  id : EventId,
  dependencies : StateVector,
  operation : Operation,
) -> Result[Event, CrdtError] {
  if id.replica().is_empty() || id.counter() <= 0 {
    return Err(InvalidEvent)
  }
  if dependencies.counter(id.replica()) != id.counter() - 1 {
    return Err(InvalidDependency)
  }
  if dependencies.clocks.length() > MAX_UPDATE_CLOCKS ||
    dependencies.lamports.length() > MAX_UPDATE_CLOCKS {
    return Err(UpdateTooLarge)
  }
  for replica, counter in dependencies.clocks {
    if replica.is_empty() || counter < 0 {
      return Err(InvalidDependency)
    }
    if counter > 0 && dependencies.lamports.get(replica).unwrap_or(0) < counter {
      return Err(InvalidDependency)
    }
    if counter == 0 && dependencies.lamports.get(replica).unwrap_or(0) != 0 {
      return Err(InvalidDependency)
    }
  }
  for replica, timestamp in dependencies.lamports {
    if timestamp < 0 || dependencies.clocks.get(replica).unwrap_or(0) == 0 {
      return Err(InvalidDependency)
    }
  }
  let previous_lamport = max_lamport(dependencies)
  if previous_lamport == 2147483647 {
    return Err(ClockOverflow)
  }
  let lamport = previous_lamport + 1
  match validate_operation_value(operation) {
    Err(error) => return Err(error)
    Ok(_) => ()
  }
  match validate_operation_dependencies(operation, dependencies) {
    Err(error) => return Err(error)
    Ok(_) => ()
  }
  Ok({
    id,
    dependencies: clone_vector(dependencies),
    lamport,
    operation: clone_operation(operation),
  })
}

///|
/// Return this event's stable identity.
pub fn Event::id(self : Event) -> EventId {
  self.id
}

///|
/// Return an owned copy of the causal dependencies.
pub fn Event::dependencies(self : Event) -> StateVector {
  clone_vector(self.dependencies)
}

///|
/// Return the causality-preserving Lamport timestamp assigned to this event.
pub fn Event::lamport(self : Event) -> Int {
  self.lamport
}

///|
/// Return an owned copy of the semantic operation.
pub fn Event::operation(self : Event) -> Operation {
  clone_operation(self.operation)
}

///|
fn clone_vector(vector : StateVector) -> StateVector {
  let clocks : Map[String, Int] = {}
  let lamports : Map[String, Int] = {}
  for replica, counter in vector.clocks {
    clocks[replica] = counter
  }
  for replica, counter in vector.lamports {
    lamports[replica] = counter
  }
  { clocks, lamports, checkpoint: vector.checkpoint, }
}

///|
fn clone_operation(operation : Operation) -> Operation {
  match operation {
    MapSet(root, key, value) => MapSet(root, key, value.clone())
    MapDelete(root, key) => MapDelete(root, key)
    SequenceInsert(root, kind, after, value) =>
      SequenceInsert(root, kind, after, value.clone())
    SequenceDelete(root, kind, target) => SequenceDelete(root, kind, target)
    MapRestore(root, key, target, value) =>
      MapRestore(root, key, target, value.map(value => value.clone()))
  }
}

///|

///|
fn vector_set_checkpoint(
  vector : StateVector,
  checkpoint : String?,
) -> StateVector {
  {
    clocks: clone_clock_map(vector.clocks),
    lamports: clone_clock_map(vector.lamports),
    checkpoint,
  }
}

///|
fn max_lamport(vector : StateVector) -> Int {
  let mut maximum = 0
  for _, timestamp in vector.lamports {
    if timestamp > maximum {
      maximum = timestamp
    }
  }
  maximum
}

///|
fn clone_clock_map(clocks : Map[String, Int]) -> Map[String, Int] {
  let output : Map[String, Int] = {}
  for replica, counter in clocks {
    output[replica] = counter
  }
  output
}

///| Reject statically invalid causal references before an event can enter a

///|
/// pending queue and poison later local transactions.
fn validate_operation_dependencies(
  operation : Operation,
  dependencies : StateVector,
) -> Result[Unit, CrdtError] {
  match operation {
    SequenceInsert(root, kind, after, _) =>
      validate_static_node_dependency(dependencies, root, kind, after)
    SequenceDelete(root, kind, target) =>
      validate_static_node_dependency(dependencies, root, kind, target)
    MapRestore(_, _, target, _) =>
      if dependencies.includes(target) {
        Ok(())
      } else {
        Err(InvalidDependency)
      }
    _ => Ok(())
  }
}

///|
fn validate_static_node_dependency(
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
    CheckpointNode(epoch, node_root, node_kind, _) =>
      if node_root != root || node_kind != kind {
        Err(AnchorTypeMismatch)
      } else if dependencies.checkpoint != Some(epoch) {
        Err(InvalidDependency)
      } else {
        Ok(())
      }
  }
}
