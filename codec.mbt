///|
/// Encode this update in Y.mbt's bounded, versioned binary format.
/// This format is independent of Yjs updates and is not wire-compatible with
/// Yjs.
pub fn Update::encode(self : Update) -> Result[Bytes, CrdtError] {
  match validate_update(self) {
    Err(error) => return Err(error)
    Ok(_) => ()
  }
  let writer = UpdateWriter::{ buffer: @buffer.Buffer(), }
  try write_update(writer, self) catch {
    error => Err(error)
  } noraise {
    _ => Ok(writer.buffer.to_bytes())
  }
}

///|
/// Decode a complete, bounded Y.mbt update.
/// Unknown format versions return `UnsupportedVersion`; malformed or
/// truncated data returns `MalformedUpdate`.
pub fn Update::decode(bytes : Bytes) -> Result[Update, CrdtError] {
  if bytes.length() > MAX_UPDATE_BYTES {
    return Err(UpdateTooLarge)
  }
  let reader = UpdateReader::{
    bytes,
    offset: 0,
    value_budget: MAX_UPDATE_VALUE_NODES,
  }
  try read_update(reader) catch {
    error => Err(error)
  } noraise {
    update => Ok(update)
  }
}

///|
fn validate_update(update : Update) -> Result[Unit, CrdtError] {
  match Update::new(update.checkpoint, update.events) {
    Err(error) => Err(error)
    Ok(_) => Ok(())
  }
}

///|
priv struct UpdateWriter {
  buffer : @buffer.Buffer
}

///|
priv struct UpdateReader {
  bytes : Bytes
  mut offset : Int
  mut value_budget : Int
}

///|
fn write_update(writer : UpdateWriter, update : Update) -> Unit raise CrdtError {
  writer_byte(writer, 0x59)
  writer_byte(writer, 0x4d)
  writer_byte(writer, 0x42)
  writer_byte(writer, 0x54)
  writer_byte(writer, 1)
  match update.checkpoint {
    None => writer_byte(writer, 0)
    Some(checkpoint) => {
      writer_byte(writer, 1)
      write_checkpoint(writer, checkpoint)
    }
  }

  if update.events.length() > MAX_UPDATE_EVENTS {
    raise UpdateTooLarge
  }
  writer_int(writer, update.events.length())
  let events = update.events.copy()
  sort_events(events)
  for event in events {
    writer_event(writer, event)
  }
}

///|
fn writer_reserve(writer : UpdateWriter, amount : Int) -> Unit raise CrdtError {
  if amount < 0 || writer.buffer.length() > MAX_UPDATE_BYTES - amount {
    raise UpdateTooLarge
  }
}

///|
fn writer_byte(writer : UpdateWriter, value : Int) -> Unit raise CrdtError {
  writer_reserve(writer, 1)
  writer.buffer.write_byte(value.to_byte())
}

///|
fn writer_int(writer : UpdateWriter, value : Int) -> Unit raise CrdtError {
  writer_reserve(writer, 4)
  writer.buffer.write_int_be(value)
}

///|
fn writer_string(writer : UpdateWriter, value : String) -> Unit raise CrdtError {
  match validate_update_string(value) {
    Err(error) => raise error
    Ok(_) => ()
  }
  let bytes = @utf8.encode(value)
  writer_reserve(writer, 4 + bytes.length())
  writer.buffer.write_int_be(bytes.length())
  writer.buffer.write_bytes(bytes.exact_view())
}

///|
fn writer_optional_string(
  writer : UpdateWriter,
  value : String?,
) -> Unit raise CrdtError {
  match value {
    None => writer_byte(writer, 0)
    Some(value) => {
      writer_byte(writer, 1)
      writer_string(writer, value)
    }
  }
}

///|
fn writer_event_id(writer : UpdateWriter, id : EventId) -> Unit raise CrdtError {
  writer_string(writer, id.replica())
  writer_int(writer, id.counter())
}

///|
fn writer_vector(
  writer : UpdateWriter,
  vector : StateVector,
) -> Unit raise CrdtError {
  writer_optional_string(writer, vector.checkpoint)
  let entries = vector.metadata_entries()
  if entries.length() > MAX_UPDATE_CLOCKS {
    raise UpdateTooLarge
  }
  writer_int(writer, entries.length())
  for (replica, counter, timestamp) in entries {
    writer_string(writer, replica)
    writer_int(writer, counter)
    writer_int(writer, timestamp)
  }
}

///|
fn writer_node_id(writer : UpdateWriter, id : NodeId) -> Unit raise CrdtError {
  match id {
    Root => writer_byte(writer, 0)
    CheckpointNode(checkpoint, root, kind, index) => {
      writer_byte(writer, 1)
      writer_string(writer, checkpoint)
      writer_string(writer, root)
      writer_kind(writer, kind)
      writer_int(writer, index)
    }
    EventNode(event) => {
      writer_byte(writer, 2)
      writer_event_id(writer, event)
    }
  }
}

///|
fn writer_kind(
  writer : UpdateWriter,
  kind : SequenceKind,
) -> Unit raise CrdtError {
  match kind {
    List => writer_byte(writer, 0)
    Text => writer_byte(writer, 1)
  }
}

///|
fn writer_value(
  writer : UpdateWriter,
  value : Value,
  depth : Int,
) -> Unit raise CrdtError {
  if depth > MAX_VALUE_DEPTH {
    raise InvalidValueDepth
  }
  match value {
    Null => writer_byte(writer, 0)
    Bool(false) => writer_byte(writer, 1)
    Bool(true) => writer_byte(writer, 2)
    Int(value) => {
      writer_byte(writer, 3)
      writer_int(writer, value)
    }
    String(value) => {
      writer_byte(writer, 4)
      writer_string(writer, value)
    }
    Array(values) => {
      if values.length() > MAX_UPDATE_CONTAINER_ITEMS {
        raise UpdateTooLarge
      }
      writer_byte(writer, 5)
      writer_int(writer, values.length())
      for value in values {
        writer_value(writer, value, depth + 1)
      }
    }
    Object(values) => {
      if values.length() > MAX_UPDATE_CONTAINER_ITEMS {
        raise UpdateTooLarge
      }
      writer_byte(writer, 6)
      let keys = values.keys().to_array()
      keys.sort_by((left, right) => left.compare(right))
      writer_int(writer, keys.length())
      for key in keys {
        writer_string(writer, key)
        writer_value(writer, values[key], depth + 1)
      }
    }
  }
}

///|
fn writer_operation(
  writer : UpdateWriter,
  operation : Operation,
) -> Unit raise CrdtError {
  match operation {
    MapSet(root, key, value) => {
      writer_byte(writer, 0)
      writer_string(writer, root)
      writer_string(writer, key)
      writer_value(writer, value, 0)
    }
    MapDelete(root, key) => {
      writer_byte(writer, 1)
      writer_string(writer, root)
      writer_string(writer, key)
    }
    SequenceInsert(root, kind, after, value) => {
      writer_byte(writer, 2)
      writer_string(writer, root)
      writer_kind(writer, kind)
      writer_node_id(writer, after)
      writer_value(writer, value, 0)
    }
    SequenceDelete(root, kind, target) => {
      writer_byte(writer, 3)
      writer_string(writer, root)
      writer_kind(writer, kind)
      writer_node_id(writer, target)
    }
    MapRestore(root, key, target, value) => {
      writer_byte(writer, 4)
      writer_string(writer, root)
      writer_string(writer, key)
      writer_event_id(writer, target)
      match value {
        None => writer_byte(writer, 0)
        Some(value) => {
          writer_byte(writer, 1)
          writer_value(writer, value, 0)
        }
      }
    }
  }
}

///|
fn writer_event(writer : UpdateWriter, event : Event) -> Unit raise CrdtError {
  writer_event_id(writer, event.id)
  writer_vector(writer, event.dependencies)
  writer_operation(writer, event.operation)
}

///|
fn write_checkpoint(
  writer : UpdateWriter,
  checkpoint : CheckpointSnapshot,
) -> Unit raise CrdtError {
  writer_string(writer, checkpoint.id)
  writer_vector(writer, checkpoint.frontier)

  let maps = checkpoint.maps.copy()
  if maps.length() > MAX_UPDATE_CONTAINER_ITEMS {
    raise UpdateTooLarge
  }
  maps.sort_by((left, right) => {
    let by_root = left.root.compare(right.root)
    if by_root != 0 {
      by_root
    } else {
      left.key.compare(right.key)
    }
  })
  writer_int(writer, maps.length())
  for entry in maps {
    writer_string(writer, entry.root)
    writer_string(writer, entry.key)
    writer_event_id(writer, entry.stamp)
    writer_int(writer, entry.lamport)
    match entry.value {
      None => writer_byte(writer, 0)
      Some(value) => {
        writer_byte(writer, 1)
        writer_value(writer, value, 0)
      }
    }
  }

  let sequences = checkpoint.sequences.copy()
  if sequences.length() > MAX_UPDATE_CONTAINER_ITEMS {
    raise UpdateTooLarge
  }
  sequences.sort_by((left, right) => {
    let by_root = left.root.compare(right.root)
    if by_root != 0 {
      by_root
    } else {
      sequence_kind_name(left.kind).compare(sequence_kind_name(right.kind))
    }
  })
  writer_int(writer, sequences.length())
  for sequence in sequences {
    writer_string(writer, sequence.root)
    writer_kind(writer, sequence.kind)
    if sequence.values.length() > MAX_UPDATE_CONTAINER_ITEMS {
      raise UpdateTooLarge
    }
    writer_int(writer, sequence.values.length())
    for value in sequence.values {
      writer_value(writer, value, 0)
    }
  }
}

///|
fn reader_need(reader : UpdateReader, length : Int) -> Unit raise CrdtError {
  if length < 0 || reader.offset > reader.bytes.length() - length {
    raise MalformedUpdate
  }
}

///|
fn reader_byte(reader : UpdateReader) -> Int raise CrdtError {
  reader_need(reader, 1)
  let value = match reader.bytes.get(reader.offset) {
    Some(byte) => byte.to_int()
    None => raise MalformedUpdate
  }
  reader.offset += 1
  value
}

///|
fn reader_int(reader : UpdateReader) -> Int raise CrdtError {
  reader_need(reader, 4)
  let b0 = reader_byte(reader)
  let b1 = reader_byte(reader)
  let b2 = reader_byte(reader)
  let b3 = reader_byte(reader)
  (b0 << 24) | (b1 << 16) | (b2 << 8) | b3
}

///|
fn reader_count(reader : UpdateReader, maximum : Int) -> Int raise CrdtError {
  let count = reader_int(reader)
  if count < 0 || count > maximum {
    raise if count < 0 { MalformedUpdate } else { UpdateTooLarge }
  }
  count
}

///|
fn reader_string(reader : UpdateReader) -> String raise CrdtError {
  let length = reader_count(reader, MAX_UPDATE_STRING_BYTES)
  reader_need(reader, length)
  let view = match
    reader.bytes.get_view(start=reader.offset, end=reader.offset + length) {
    Some(view) => view
    None => raise MalformedUpdate
  }
  reader.offset += length
  @utf8.decode(view) catch {
    _ => raise MalformedUpdate
  }
}

///|
fn reader_optional_string(reader : UpdateReader) -> String? raise CrdtError {
  match reader_byte(reader) {
    0 => None
    1 => Some(reader_string(reader))
    _ => raise MalformedUpdate
  }
}

///|
fn reader_event_id(reader : UpdateReader) -> EventId raise CrdtError {
  let replica = reader_string(reader)
  let counter = reader_int(reader)
  match EventId::new(replica, counter) {
    Err(error) => raise error
    Ok(id) => id
  }
}

///|
fn reader_vector(reader : UpdateReader) -> StateVector raise CrdtError {
  let checkpoint = reader_optional_string(reader)
  let count = reader_count(reader, MAX_UPDATE_CLOCKS)
  let entries : Array[(String, Int, Int)] = []
  let mut previous : String? = None
  for _ in 0..<count {
    let replica = reader_string(reader)
    match previous {
      Some(previous) if previous.compare(replica) >= 0 => raise MalformedUpdate
      _ => ()
    }
    previous = Some(replica)
    let counter = reader_int(reader)
    let timestamp = reader_int(reader)
    entries.push((replica, counter, timestamp))
  }
  match StateVector::from_metadata(entries, checkpoint) {
    Err(error) => raise error
    Ok(vector) => vector
  }
}

///|
fn reader_node_id(reader : UpdateReader) -> NodeId raise CrdtError {
  match reader_byte(reader) {
    0 => Root
    1 => {
      let checkpoint = reader_string(reader)
      let root = reader_string(reader)
      let kind = reader_kind(reader)
      let index = reader_int(reader)
      if checkpoint.is_empty() || root.is_empty() || index < 0 {
        raise MalformedUpdate
      }
      CheckpointNode(checkpoint, root, kind, index)
    }
    2 => EventNode(reader_event_id(reader))
    _ => raise MalformedUpdate
  }
}

///|
fn reader_kind(reader : UpdateReader) -> SequenceKind raise CrdtError {
  match reader_byte(reader) {
    0 => List
    1 => Text
    _ => raise MalformedUpdate
  }
}

///|
fn reader_value(reader : UpdateReader, depth : Int) -> Value raise CrdtError {
  if depth > MAX_VALUE_DEPTH {
    raise InvalidValueDepth
  }
  reader.value_budget -= 1
  if reader.value_budget < 0 {
    raise UpdateTooLarge
  }
  match reader_byte(reader) {
    0 => Null
    1 => Bool(false)
    2 => Bool(true)
    3 => Int(reader_int(reader))
    4 => String(reader_string(reader))
    5 => {
      let count = reader_count(reader, MAX_UPDATE_CONTAINER_ITEMS)
      let values : Array[Value] = []
      for _ in 0..<count {
        values.push(reader_value(reader, depth + 1))
      }
      Array(values)
    }
    6 => {
      let count = reader_count(reader, MAX_UPDATE_CONTAINER_ITEMS)
      let values : Map[String, Value] = {}
      let mut previous : String? = None
      for _ in 0..<count {
        let key = reader_string(reader)
        match previous {
          Some(previous) if previous.compare(key) >= 0 => raise MalformedUpdate
          _ => ()
        }
        previous = Some(key)
        values[key] = reader_value(reader, depth + 1)
      }
      Object(values)
    }
    _ => raise MalformedUpdate
  }
}

///|
fn reader_operation(reader : UpdateReader) -> Operation raise CrdtError {
  match reader_byte(reader) {
    0 =>
      MapSet(
        reader_string(reader),
        reader_string(reader),
        reader_value(reader, 0),
      )
    1 => MapDelete(reader_string(reader), reader_string(reader))
    2 =>
      SequenceInsert(
        reader_string(reader),
        reader_kind(reader),
        reader_node_id(reader),
        reader_value(reader, 0),
      )
    3 =>
      SequenceDelete(
        reader_string(reader),
        reader_kind(reader),
        reader_node_id(reader),
      )
    4 => {
      let root = reader_string(reader)
      let key = reader_string(reader)
      let target = reader_event_id(reader)
      let value = match reader_byte(reader) {
        0 => None
        1 => Some(reader_value(reader, 0))
        _ => raise MalformedUpdate
      }
      MapRestore(root, key, target, value)
    }
    _ => raise MalformedUpdate
  }
}

///|
fn reader_event(reader : UpdateReader) -> Event raise CrdtError {
  let id = reader_event_id(reader)
  let dependencies = reader_vector(reader)
  let operation = reader_operation(reader)
  match Event::new(id, dependencies, operation) {
    Err(error) => raise error
    Ok(event) => event
  }
}

///|
fn reader_checkpoint(
  reader : UpdateReader,
) -> CheckpointSnapshot raise CrdtError {
  let id = reader_string(reader)
  let frontier = reader_vector(reader)
  let map_count = reader_count(reader, MAX_UPDATE_CONTAINER_ITEMS)
  let maps : Array[MapSnapshotEntry] = []
  let mut previous_root : String? = None
  let mut previous_key : String? = None
  for _ in 0..<map_count {
    let root = reader_string(reader)
    let key = reader_string(reader)
    match (previous_root, previous_key) {
      (Some(prev_root), Some(_)) if prev_root.compare(root) > 0 =>
        raise MalformedUpdate
      (Some(prev_root), Some(prev_key)) if prev_root == root &&
        prev_key.compare(key) >= 0 => raise MalformedUpdate
      _ => ()
    }
    previous_root = Some(root)
    previous_key = Some(key)
    let stamp = reader_event_id(reader)
    let lamport = reader_int(reader)
    let value = match reader_byte(reader) {
      0 => None
      1 => Some(reader_value(reader, 0))
      _ => raise MalformedUpdate
    }
    match MapSnapshotEntry::new(root, key, value, stamp, lamport) {
      Err(error) => raise error
      Ok(entry) => maps.push(entry)
    }
  }

  let sequence_count = reader_count(reader, MAX_UPDATE_CONTAINER_ITEMS)
  let sequences : Array[SequenceSnapshot] = []
  let mut previous_root : String? = None
  let mut previous_kind : SequenceKind? = None
  for _ in 0..<sequence_count {
    let root = reader_string(reader)
    let kind = reader_kind(reader)
    match (previous_root, previous_kind) {
      (Some(previous_root), Some(previous_kind)) =>
        if previous_root.compare(root) > 0 ||
          (
            previous_root == root &&
            sequence_kind_name(previous_kind).compare(sequence_kind_name(kind)) >=
            0
          ) {
          raise MalformedUpdate
        }
      _ => ()
    }
    previous_root = Some(root)
    previous_kind = Some(kind)
    let value_count = reader_count(reader, MAX_UPDATE_CONTAINER_ITEMS)
    let values : Array[Value] = []
    for _ in 0..<value_count {
      values.push(reader_value(reader, 0))
    }
    match SequenceSnapshot::new(root, kind, values) {
      Err(error) => raise error
      Ok(sequence) => sequences.push(sequence)
    }
  }
  match CheckpointSnapshot::new(id, frontier, maps, sequences) {
    Err(error) => raise error
    Ok(checkpoint) => checkpoint
  }
}

///|
fn read_update(reader : UpdateReader) -> Update raise CrdtError {
  if reader_byte(reader) != 0x59 ||
    reader_byte(reader) != 0x4d ||
    reader_byte(reader) != 0x42 ||
    reader_byte(reader) != 0x54 {
    raise MalformedUpdate
  }
  if reader_byte(reader) != 1 {
    raise UnsupportedVersion
  }
  let checkpoint = match reader_byte(reader) {
    0 => None
    1 => Some(reader_checkpoint(reader))
    _ => raise MalformedUpdate
  }
  let event_count = reader_count(reader, MAX_UPDATE_EVENTS)
  let events : Array[Event] = []
  let mut previous : Event? = None
  for _ in 0..<event_count {
    let event = reader_event(reader)
    match previous {
      Some(previous) if previous.lamport > event.lamport ||
        (
          previous.lamport == event.lamport &&
          EventId::compare(previous.id, event.id) >= 0
        ) => raise MalformedUpdate
      _ => ()
    }
    previous = Some(event)
    events.push(event)
  }
  if reader.offset != reader.bytes.length() {
    raise MalformedUpdate
  }
  match Update::new(checkpoint, events) {
    Err(error) => raise error
    Ok(update) => update
  }
}
