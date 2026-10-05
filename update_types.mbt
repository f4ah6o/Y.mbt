///|
/// A checkpointed value retained for one map key.
struct MapSnapshotEntry {
  root : String
  key : String
  value : Value?
  stamp : EventId
  lamport : Int
}

///|
/// Construct a validated map entry for a checkpoint snapshot.
pub fn MapSnapshotEntry::new(
  root : String,
  key : String,
  value : Value?,
  stamp : EventId,
  lamport : Int,
) -> Result[MapSnapshotEntry, CrdtError] {
  if root.is_empty() || lamport <= 0 {
    return Err(MalformedUpdate)
  }
  match validate_update_string(root) {
    Err(error) => return Err(error)
    Ok(_) => ()
  }
  match validate_update_string(key) {
    Err(error) => return Err(error)
    Ok(_) => ()
  }
  match EventId::new(stamp.replica(), stamp.counter()) {
    Err(error) => return Err(error)
    Ok(_) => ()
  }
  match value {
    None => return Err(MalformedUpdate)
    Some(value) =>
      match validate_update_value(value, 0, [MAX_UPDATE_VALUE_NODES]) {
        Err(error) => return Err(error)
        Ok(_) => ()
      }
  }
  Ok({ root, key, value: value.map(value => value.clone()), stamp, lamport, })
}

///|
/// Return the shared map root.
pub fn MapSnapshotEntry::root(self : MapSnapshotEntry) -> String {
  self.root
}

///|
/// Return the map key.
pub fn MapSnapshotEntry::key(self : MapSnapshotEntry) -> String {
  self.key
}

///|
/// Return a recursively copied live value stored in this checkpoint entry.
pub fn MapSnapshotEntry::value(self : MapSnapshotEntry) -> Value? {
  self.value.map(value => value.clone())
}

///|
/// Return the event which last changed this map key.
pub fn MapSnapshotEntry::stamp(self : MapSnapshotEntry) -> EventId {
  self.stamp
}

///|
/// Return the Lamport timestamp of the event which last changed this key.
pub fn MapSnapshotEntry::lamport(self : MapSnapshotEntry) -> Int {
  self.lamport
}

///|
/// A compacted visible list or text sequence.
struct SequenceSnapshot {
  root : String
  kind : SequenceKind
  values : Array[Value]
}

///|
/// Construct a validated sequence snapshot. Text values must each contain one
/// Unicode scalar, matching native text positions and element identity.
pub fn SequenceSnapshot::new(
  root : String,
  kind : SequenceKind,
  values : Array[Value],
) -> Result[SequenceSnapshot, CrdtError] {
  if root.is_empty() {
    return Err(MalformedUpdate)
  }
  if values.length() > MAX_UPDATE_CONTAINER_ITEMS {
    return Err(UpdateTooLarge)
  }
  match validate_update_string(root) {
    Err(error) => return Err(error)
    Ok(_) => ()
  }
  let budget = [MAX_UPDATE_VALUE_NODES]
  for value in values {
    match validate_update_value(value, 0, budget) {
      Err(error) => return Err(error)
      Ok(_) => ()
    }
    match (kind, value) {
      (Text, String(text)) if text.to_array().length() == 1 => ()
      (Text, _) => return Err(MalformedUpdate)
      _ => ()
    }
  }
  Ok({ root, kind, values: values.map(value => value.clone()), })
}

///|
/// Return the shared sequence root.
pub fn SequenceSnapshot::root(self : SequenceSnapshot) -> String {
  self.root
}

///|
/// Return whether this is a list or plain text sequence.
pub fn SequenceSnapshot::kind(self : SequenceSnapshot) -> SequenceKind {
  self.kind
}

///|
/// Return a recursively copied sequence projection.
pub fn SequenceSnapshot::values(self : SequenceSnapshot) -> Array[Value] {
  self.values.map(value => value.clone())
}

///|
/// A validated checkpoint baseline sufficient to rebase retained events.
struct CheckpointSnapshot {
  id : String
  frontier : StateVector
  maps : Array[MapSnapshotEntry]
  sequences : Array[SequenceSnapshot]
}

///|
/// Construct a checked checkpoint snapshot, copying all mutable input data.
/// The identifier must be globally unique and never reused across replicas or
/// persisted/restored lifetimes. This constructor validates the identifier's
/// shape but does not retain older identifiers to detect reuse.
pub fn CheckpointSnapshot::new(
  id : String,
  frontier : StateVector,
  maps : Array[MapSnapshotEntry],
  sequences : Array[SequenceSnapshot],
) -> Result[CheckpointSnapshot, CrdtError] {
  if id.is_empty() {
    return Err(MalformedUpdate)
  }
  if maps.length() > MAX_UPDATE_CONTAINER_ITEMS ||
    sequences.length() > MAX_UPDATE_CONTAINER_ITEMS {
    return Err(UpdateTooLarge)
  }
  match validate_update_string(id) {
    Err(error) => return Err(error)
    Ok(_) => ()
  }
  if frontier.checkpoint != Some(id) {
    return Err(MalformedUpdate)
  }
  match validate_update_vector(frontier) {
    Err(error) => return Err(error)
    Ok(_) => ()
  }

  let map_keys : Map[String, Map[String, Unit]] = {}
  let map_stamps : Map[EventId, Unit] = {}
  let budget = [MAX_UPDATE_VALUE_NODES]
  for entry in maps {
    match validate_snapshot_map_entry(entry, frontier, budget) {
      Err(error) => return Err(error)
      Ok(_) => ()
    }
    let keys = match map_keys.get(entry.root) {
      Some(keys) => keys
      None => {
        let keys : Map[String, Unit] = {}
        map_keys[entry.root] = keys
        keys
      }
    }
    if keys.contains(entry.key) {
      return Err(MalformedUpdate)
    }
    if map_stamps.contains(entry.stamp) {
      return Err(MalformedUpdate)
    }
    keys[entry.key] = ()
    map_stamps[entry.stamp] = ()
  }

  let sequence_kinds : Map[String, Map[String, Unit]] = {}
  for sequence in sequences {
    match validate_snapshot_sequence(sequence, budget) {
      Err(error) => return Err(error)
      Ok(_) => ()
    }
    let kinds = match sequence_kinds.get(sequence.root) {
      Some(kinds) => kinds
      None => {
        let kinds : Map[String, Unit] = {}
        sequence_kinds[sequence.root] = kinds
        kinds
      }
    }
    let kind = sequence_kind_name(sequence.kind)
    if kinds.contains(kind) {
      return Err(MalformedUpdate)
    }
    kinds[kind] = ()
  }

  let copied_maps = maps.map(entry => clone_snapshot_map_entry(entry))
  copied_maps.sort_by((left, right) => {
    let by_root = left.root.compare(right.root)
    if by_root != 0 {
      by_root
    } else {
      left.key.compare(right.key)
    }
  })
  let copied_sequences = sequences.map(sequence => {
    clone_snapshot_sequence(sequence)
  })
  copied_sequences.sort_by((left, right) => {
    let by_root = left.root.compare(right.root)
    if by_root != 0 {
      by_root
    } else {
      sequence_kind_name(left.kind).compare(sequence_kind_name(right.kind))
    }
  })
  Ok({
    id,
    frontier: clone_vector(frontier),
    maps: copied_maps,
    sequences: copied_sequences,
  })
}

///|
/// Return the checkpoint epoch identifier.
pub fn CheckpointSnapshot::id(self : CheckpointSnapshot) -> String {
  self.id
}

///|
/// Return a copied causal frontier.
pub fn CheckpointSnapshot::frontier(self : CheckpointSnapshot) -> StateVector {
  clone_vector(self.frontier)
}

///|
/// Return copied map checkpoint entries.
pub fn CheckpointSnapshot::maps(
  self : CheckpointSnapshot,
) -> Array[MapSnapshotEntry] {
  self.maps.map(entry => clone_snapshot_map_entry(entry))
}

///|
/// Return copied sequence checkpoint entries.
pub fn CheckpointSnapshot::sequences(
  self : CheckpointSnapshot,
) -> Array[SequenceSnapshot] {
  self.sequences.map(sequence => clone_snapshot_sequence(sequence))
}

///|
/// A self-contained update, optionally based on a compacted checkpoint.
struct Update {
  checkpoint : CheckpointSnapshot?
  events : Array[Event]
}

///|
/// Construct an update only after validating and copying all of its contents.
pub fn Update::new(
  checkpoint : CheckpointSnapshot?,
  events : Array[Event],
) -> Result[Update, CrdtError] {
  if events.length() > MAX_UPDATE_EVENTS {
    return Err(UpdateTooLarge)
  }
  let budget = [MAX_UPDATE_VALUE_NODES]
  match checkpoint {
    None => ()
    Some(checkpoint) => {
      match validate_checkpoint_snapshot(checkpoint) {
        Err(error) => return Err(error)
        Ok(_) => ()
      }
      match consume_checkpoint_value_budget(checkpoint, budget) {
        Err(error) => return Err(error)
        Ok(_) => ()
      }
    }
  }
  let ids : Map[EventId, Unit] = {}
  for event in events {
    match validate_update_event(event, budget) {
      Err(error) => return Err(error)
      Ok(_) => ()
    }
    if ids.contains(event.id) {
      return Err(MalformedUpdate)
    }
    ids[event.id] = ()
  }
  Ok({
    checkpoint: checkpoint.map(value => clone_checkpoint_snapshot(value)),
    events: events.map(event => clone_update_event(event)),
  })
}

///| Count snapshot values against the same aggregate budget used for the

///| remaining events in an Update. CheckpointSnapshot has its own constructor

///|
/// budget; this second pass enforces the update-wide wire limit.
fn consume_checkpoint_value_budget(
  checkpoint : CheckpointSnapshot,
  budget : Array[Int],
) -> Result[Unit, CrdtError] {
  for entry in checkpoint.maps {
    match entry.value {
      None => return Err(MalformedUpdate)
      Some(value) =>
        match validate_update_value(value, 0, budget) {
          Err(error) => return Err(error)
          Ok(_) => ()
        }
    }
  }
  for sequence in checkpoint.sequences {
    for value in sequence.values {
      match validate_update_value(value, 0, budget) {
        Err(error) => return Err(error)
        Ok(_) => ()
      }
    }
  }
  Ok(())
}

///|
/// Return a copied checkpoint, if this update carries one.
pub fn Update::checkpoint(self : Update) -> CheckpointSnapshot? {
  self.checkpoint.map(checkpoint => clone_checkpoint_snapshot(checkpoint))
}

///|
/// Return copied events in update order.
pub fn Update::events(self : Update) -> Array[Event] {
  self.events.map(event => clone_update_event(event))
}

///|
/// Return sorted clock entries paired with each replica's Lamport timestamp.
pub fn StateVector::metadata_entries(
  self : StateVector,
) -> Array[(String, Int, Int)] {
  let entries : Array[(String, Int, Int)] = []
  for replica, counter in self.clocks {
    entries.push((replica, counter, self.lamports.get(replica).unwrap_or(0)))
  }
  entries.sort_by((left, right) => left.0.compare(right.0))
  entries
}

///|
/// Return the greatest integrated Lamport timestamp for a replica.
pub fn StateVector::lamport(self : StateVector, replica : String) -> Int {
  self.lamports.get(replica).unwrap_or(0)
}

///|
/// Construct a vector with validated contiguous clocks and Lamport metadata.
/// Each tuple is `(replica, contiguous_counter, greatest_lamport)`.
pub fn StateVector::from_metadata(
  entries : Array[(String, Int, Int)],
  checkpoint : String?,
) -> Result[StateVector, CrdtError] {
  if entries.length() > MAX_UPDATE_CLOCKS {
    return Err(UpdateTooLarge)
  }
  let clocks : Map[String, Int] = {}
  let lamports : Map[String, Int] = {}
  for (replica, counter, timestamp) in entries {
    if replica.is_empty() ||
      replica.contains("\u{0}") ||
      counter <= 0 ||
      timestamp < counter {
      return Err(InvalidDependency)
    }
    match validate_update_string(replica) {
      Err(error) => return Err(error)
      Ok(_) => ()
    }
    if clocks.contains(replica) {
      return Err(InvalidDependency)
    }
    clocks[replica] = counter
    lamports[replica] = timestamp
  }
  match checkpoint {
    None => ()
    Some(id) => {
      if id.is_empty() {
        return Err(InvalidDependency)
      }
      match validate_update_string(id) {
        Err(error) => return Err(error)
        Ok(_) => ()
      }
    }
  }
  Ok({ clocks, lamports, checkpoint, })
}

///|
/// Check raw UTF-16 code units before scalar iteration or UTF-8 encoding.
/// JavaScript strings may contain unpaired surrogates even though Unicode
/// scalar strings on other backends cannot represent them faithfully.
fn utf16_is_well_formed(value : String) -> Bool {
  let length = value.length()
  let mut offset = 0
  while offset < length {
    let unit = value.code_unit_at(offset)
    if unit >= 0xD800 && unit <= 0xDBFF {
      if offset + 1 >= length {
        return false
      }
      let trail = value.code_unit_at(offset + 1)
      if trail < 0xDC00 || trail > 0xDFFF {
        return false
      }
      offset += 2
    } else if unit >= 0xDC00 && unit <= 0xDFFF {
      return false
    } else {
      offset += 1
    }
  }
  true
}

///|
fn validate_update_string(value : String) -> Result[Unit, CrdtError] {
  if !utf16_is_well_formed(value) {
    return Err(InvalidUnicode)
  }
  // Check the scalar count first to keep UTF-8 encoding allocation bounded.
  if value.char_length() > MAX_UPDATE_STRING_BYTES {
    return Err(UpdateTooLarge)
  }
  if @utf8.encode(value).length() > MAX_UPDATE_STRING_BYTES {
    return Err(UpdateTooLarge)
  }
  Ok(())
}

///|
fn validate_update_vector(vector : StateVector) -> Result[Unit, CrdtError] {
  if vector.clocks.length() > MAX_UPDATE_CLOCKS ||
    vector.lamports.length() > MAX_UPDATE_CLOCKS {
    return Err(UpdateTooLarge)
  }
  for replica, counter in vector.clocks {
    if replica.is_empty() || replica.contains("\u{0}") || counter <= 0 {
      return Err(InvalidDependency)
    }
    match validate_update_string(replica) {
      Err(error) => return Err(error)
      Ok(_) => ()
    }
    let timestamp = vector.lamports.get(replica).unwrap_or(0)
    if timestamp < counter {
      return Err(InvalidDependency)
    }
  }
  for replica, timestamp in vector.lamports {
    if !vector.clocks.contains(replica) ||
      timestamp < vector.clocks.get(replica).unwrap_or(0) {
      return Err(InvalidDependency)
    }
  }
  match vector.checkpoint {
    None => ()
    Some(id) => {
      if id.is_empty() {
        return Err(InvalidDependency)
      }
      match validate_update_string(id) {
        Err(error) => return Err(error)
        Ok(_) => ()
      }
    }
  }
  Ok(())
}

///|
fn validate_update_value(
  value : Value,
  depth : Int,
  budget : Array[Int],
) -> Result[Unit, CrdtError] {
  if depth > MAX_VALUE_DEPTH {
    return Err(InvalidValueDepth)
  }
  budget[0] -= 1
  if budget[0] < 0 {
    return Err(UpdateTooLarge)
  }
  match value {
    String(text) => validate_update_string(text)
    Array(values) => {
      if values.length() > MAX_UPDATE_CONTAINER_ITEMS {
        return Err(UpdateTooLarge)
      }
      for value in values {
        match validate_update_value(value, depth + 1, budget) {
          Err(error) => return Err(error)
          Ok(_) => ()
        }
      }
      Ok(())
    }
    Object(values) => {
      if values.length() > MAX_UPDATE_CONTAINER_ITEMS {
        return Err(UpdateTooLarge)
      }
      for key, value in values {
        match validate_update_string(key) {
          Err(error) => return Err(error)
          Ok(_) => ()
        }
        match validate_update_value(value, depth + 1, budget) {
          Err(error) => return Err(error)
          Ok(_) => ()
        }
      }
      Ok(())
    }
    _ => Ok(())
  }
}

///|
fn validate_snapshot_map_entry(
  entry : MapSnapshotEntry,
  frontier : StateVector,
  budget : Array[Int],
) -> Result[Unit, CrdtError] {
  let frontier_counter = frontier.counter(entry.stamp.replica())
  let frontier_lamport = frontier.lamport(entry.stamp.replica())
  if entry.root.is_empty() ||
    entry.lamport < entry.stamp.counter() ||
    !frontier.includes(entry.stamp) ||
    frontier_lamport < entry.lamport {
    return Err(MalformedUpdate)
  }
  if frontier_counter == entry.stamp.counter() &&
    frontier_lamport != entry.lamport {
    return Err(MalformedUpdate)
  }
  if frontier_counter > entry.stamp.counter() &&
    frontier_lamport - entry.lamport < frontier_counter - entry.stamp.counter() {
    return Err(MalformedUpdate)
  }
  match validate_update_string(entry.root) {
    Err(error) => return Err(error)
    Ok(_) => ()
  }
  match validate_update_string(entry.key) {
    Err(error) => return Err(error)
    Ok(_) => ()
  }
  match entry.value {
    None => Err(MalformedUpdate)
    Some(value) => validate_update_value(value, 0, budget)
  }
}

///|
fn validate_snapshot_sequence(
  sequence : SequenceSnapshot,
  budget : Array[Int],
) -> Result[Unit, CrdtError] {
  if sequence.root.is_empty() ||
    sequence.values.length() > MAX_UPDATE_CONTAINER_ITEMS {
    return Err(
      if sequence.root.is_empty() {
        MalformedUpdate
      } else {
        UpdateTooLarge
      },
    )
  }
  match validate_update_string(sequence.root) {
    Err(error) => return Err(error)
    Ok(_) => ()
  }
  for value in sequence.values {
    match validate_update_value(value, 0, budget) {
      Err(error) => return Err(error)
      Ok(_) => ()
    }
    match (sequence.kind, value) {
      (Text, String(text)) if text.to_array().length() == 1 => ()
      (Text, _) => return Err(MalformedUpdate)
      _ => ()
    }
  }
  Ok(())
}

///|
fn validate_checkpoint_snapshot(
  checkpoint : CheckpointSnapshot,
) -> Result[Unit, CrdtError] {
  match
    CheckpointSnapshot::new(
      checkpoint.id,
      checkpoint.frontier,
      checkpoint.maps,
      checkpoint.sequences,
    ) {
    Err(error) => Err(error)
    Ok(_) => Ok(())
  }
}

///|
fn validate_update_event(
  event : Event,
  budget : Array[Int],
) -> Result[Unit, CrdtError] {
  if event.id.replica().is_empty() ||
    event.id.replica().contains("\u{0}") ||
    event.id.counter() <= 0 {
    return Err(InvalidEvent)
  }
  match validate_update_string(event.id.replica()) {
    Err(error) => return Err(error)
    Ok(_) => ()
  }
  match validate_update_vector(event.dependencies) {
    Err(error) => return Err(error)
    Ok(_) => ()
  }
  if event.dependencies.counter(event.id.replica()) != event.id.counter() - 1 {
    return Err(InvalidDependency)
  }
  let mut max_lamport = 0
  for _, lamport in event.dependencies.lamports {
    if lamport > max_lamport {
      max_lamport = lamport
    }
  }
  if max_lamport == 2147483647 || event.lamport != max_lamport + 1 {
    return Err(InvalidEvent)
  }
  match event.operation {
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
      validate_update_value(value, 0, budget)
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
      match validate_update_value(value, 0, budget) {
        Err(error) => return Err(error)
        Ok(_) => ()
      }
      match (kind, value) {
        (Text, String(text)) if text.to_array().length() == 1 => ()
        (Text, _) => return Err(InvalidEvent)
        _ => ()
      }
      match validate_node_id(after) {
        Err(error) => return Err(error)
        Ok(_) => ()
      }
      Ok(())
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
      if root.is_empty() || !event.dependencies.includes(target) {
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
        Some(value) => validate_update_value(value, 0, budget)
      }
    }
  }
}

///|
fn validate_node_id(id : NodeId) -> Result[Unit, CrdtError] {
  match id {
    Root => Ok(())
    CheckpointNode(checkpoint, root, _, index) => {
      if checkpoint.is_empty() || root.is_empty() || index < 0 {
        return Err(InvalidEvent)
      }
      match validate_update_string(checkpoint) {
        Err(error) => return Err(error)
        Ok(_) => validate_update_string(root)
      }
    }
    EventNode(event) => {
      match EventId::new(event.replica(), event.counter()) {
        Err(error) => return Err(error)
        Ok(_) => ()
      }
      validate_update_string(event.replica())
    }
  }
}

///|
fn sequence_kind_name(kind : SequenceKind) -> String {
  match kind {
    List => "list"
    Text => "text"
  }
}

///|
fn clone_snapshot_map_entry(entry : MapSnapshotEntry) -> MapSnapshotEntry {
  {
    root: entry.root,
    key: entry.key,
    value: entry.value.map(value => value.clone()),
    stamp: entry.stamp,
    lamport: entry.lamport,
  }
}

///|
fn clone_snapshot_sequence(sequence : SequenceSnapshot) -> SequenceSnapshot {
  {
    root: sequence.root,
    kind: sequence.kind,
    values: sequence.values.map(value => value.clone()),
  }
}

///|
fn clone_checkpoint_snapshot(
  checkpoint : CheckpointSnapshot,
) -> CheckpointSnapshot {
  {
    id: checkpoint.id,
    frontier: clone_vector(checkpoint.frontier),
    maps: checkpoint.maps.map(entry => clone_snapshot_map_entry(entry)),
    sequences: checkpoint.sequences.map(sequence => {
      clone_snapshot_sequence(sequence)
    }),
  }
}

///|
fn clone_update_event(event : Event) -> Event {
  Event::new(event.id, event.dependencies, event.operation).unwrap()
}

///|
const MAX_UPDATE_CLOCKS : Int = 10000

///|
const MAX_UPDATE_EVENTS : Int = 100000

///|
const MAX_UPDATE_CONTAINER_ITEMS : Int = 100000

///|
const MAX_UPDATE_STRING_BYTES : Int = 1048576

///|
const MAX_UPDATE_VALUE_NODES : Int = 1000000

///|
const MAX_UPDATE_BYTES : Int = 16777216
