///|
fn codec_make_event(
  replica : String,
  counter : Int,
  deps : @y.StateVector,
  operation : @y.Operation,
) -> @y.Event {
  @y.Event::new(@y.EventId::new(replica, counter).unwrap(), deps, operation).unwrap()
}

///|
fn codec_vector(counter : Int) -> @y.StateVector {
  @y.StateVector::from_metadata([("source", counter, counter)], None).unwrap()
}

///|
fn codec_event_fixture() -> Array[@y.Event] {
  let first = codec_make_event(
    "source",
    1,
    @y.StateVector::new(),
    @y.MapSet("profile", "name", @y.String("before")),
  )
  let second = codec_make_event(
    "source",
    2,
    codec_vector(1),
    @y.MapRestore("profile", "name", first.id(), Some(@y.String("after"))),
  )
  let third = codec_make_event(
    "source",
    3,
    codec_vector(2),
    @y.SequenceInsert("items", @y.List, @y.Root, @y.Int(-7)),
  )
  let fourth = codec_make_event(
    "source",
    4,
    codec_vector(3),
    @y.SequenceDelete("items", @y.List, @y.EventNode(third.id())),
  )
  let fifth = codec_make_event(
    "source",
    5,
    codec_vector(4),
    @y.SequenceInsert("body", @y.Text, @y.Root, @y.String("🙂")),
  )
  let sixth = codec_make_event(
    "source",
    6,
    codec_vector(5),
    @y.MapDelete("profile", "removed"),
  )
  [first, second, third, fourth, fifth, sixth]
}

///|
fn expect_decode_error(bytes : Bytes, expected : @y.CrdtError) -> Unit raise {
  match @y.Update::decode(bytes) {
    Err(error) => assert_eq(error, expected)
    Ok(_) => fail("expected malformed update decoding to fail")
  }
}

///|
fn write_raw_string(buffer : @buffer.Buffer, value : String) -> Unit {
  let bytes = @utf8.encode(value)
  buffer.write_int_be(bytes.length())
  buffer.write_bytes(bytes.exact_view())
}

///|
fn raw_nested_value_update(depth : Int) -> Bytes {
  let buffer = @buffer.Buffer()
  buffer.write_byte(b'Y')
  buffer.write_byte(b'M')
  buffer.write_byte(b'B')
  buffer.write_byte(b'T')
  buffer.write_byte(b'\x01')
  buffer.write_byte(b'\x00')
  buffer.write_int_be(1)
  write_raw_string(buffer, "sender")
  buffer.write_int_be(1)
  buffer.write_byte(b'\x00')
  buffer.write_int_be(0)
  buffer.write_byte(b'\x00')
  write_raw_string(buffer, "root")
  write_raw_string(buffer, "deep")
  for _ in 0..<depth {
    buffer.write_byte(b'\x05')
    buffer.write_int_be(1)
  }
  buffer.write_byte(b'\x03')
  buffer.write_int_be(9)
  buffer.to_bytes()
}

///|
fn find_single_byte_string(bytes : Array[Byte], character : Byte) -> Int raise {
  let mut result = -1
  for index in 0..<(bytes.length() - 4) {
    if bytes[index] == b'\x00' &&
      bytes[index + 1] == b'\x00' &&
      bytes[index + 2] == b'\x00' &&
      bytes[index + 3] == b'\x01' &&
      bytes[index + 4] == character {
      if result >= 0 {
        fail("expected one matching single-byte string")
      }
      result = index + 4
    }
  }
  if result < 0 {
    fail("could not find single-byte string in encoded checkpoint")
  }
  result
}

///|
test "versioned codec round trips all event operations and preserves metadata" {
  let update = @y.Update::new(None, codec_event_fixture()).unwrap()
  let encoded = update.encode().unwrap()
  let decoded = @y.Update::decode(encoded).unwrap()
  assert_eq(decoded.events(), update.events())
  assert_eq(decoded.encode().unwrap(), encoded)

  let events = decoded.events()
  ignore(events.pop())
  assert_eq(decoded.events().length(), 6)
}

///|
test "checkpoint map keys encode canonically and decoder rejects unsorted keys" {
  let frontier = @y.StateVector::from_metadata([("base", 2, 2)], Some("epoch")).unwrap()
  let first_stamp = @y.EventId::new("base", 1).unwrap()
  let second_stamp = @y.EventId::new("base", 2).unwrap()
  let entry_a = @y.MapSnapshotEntry::new(
    "root",
    "a",
    Some(@y.Int(1)),
    first_stamp,
    1,
  ).unwrap()
  let entry_b = @y.MapSnapshotEntry::new(
    "root",
    "b",
    Some(@y.Int(2)),
    second_stamp,
    2,
  ).unwrap()
  let checkpoint_ab = @y.CheckpointSnapshot::new(
    "epoch",
    frontier,
    [entry_b, entry_a],
    [],
  ).unwrap()
  let checkpoint_ba = @y.CheckpointSnapshot::new(
    "epoch",
    frontier,
    [entry_a, entry_b],
    [],
  ).unwrap()
  assert_eq(checkpoint_ab.maps().map(entry => entry.key()), ["a", "b"])
  let bytes_ab = @y.Update::new(Some(checkpoint_ab), [])
    .unwrap()
    .encode()
    .unwrap()
  let bytes_ba = @y.Update::new(Some(checkpoint_ba), [])
    .unwrap()
    .encode()
    .unwrap()
  assert_eq(bytes_ab, bytes_ba)

  let malformed = bytes_ab.to_array()
  let a_index = find_single_byte_string(malformed, b'a')
  let b_index = find_single_byte_string(malformed, b'b')
  assert_true(a_index < b_index)
  malformed[a_index] = b'b'
  malformed[b_index] = b'a'
  expect_decode_error(
    Bytes::from_array(malformed.exact_view()),
    @y.MalformedUpdate,
  )

  let duplicate = bytes_ab.to_array()
  let duplicate_b_index = find_single_byte_string(duplicate, b'b')
  duplicate[duplicate_b_index] = b'a'
  expect_decode_error(
    Bytes::from_array(duplicate.exact_view()),
    @y.MalformedUpdate,
  )
}

///|
test "checkpoint codec round trips map values and compacted scalar sequences" {
  let frontier = @y.StateVector::from_metadata([("base", 3, 7)], Some("epoch")).unwrap()
  let stamp = @y.EventId::new("base", 2).unwrap()
  let map = @y.MapSnapshotEntry::new(
    "profile",
    "name",
    Some(@y.String("Ada")),
    stamp,
    5,
  ).unwrap()
  let items = @y.SequenceSnapshot::new("items", @y.List, [
    @y.Int(-3),
    @y.Object(Map([("name", @y.String("item"))])),
  ]).unwrap()
  let text = @y.SequenceSnapshot::new("body", @y.Text, [
    @y.String("A"),
    @y.String("🙂"),
  ]).unwrap()
  let checkpoint = @y.CheckpointSnapshot::new("epoch", frontier, [map], [
    items, text,
  ]).unwrap()
  let update = @y.Update::new(Some(checkpoint), []).unwrap()
  let bytes = update.encode().unwrap()
  let decoded = @y.Update::decode(bytes).unwrap()
  match decoded.checkpoint() {
    None => fail("checkpoint was lost in update round trip")
    Some(snapshot) => {
      assert_eq(snapshot.id(), "epoch")
      assert_eq(snapshot.frontier().metadata_entries(), [("base", 3, 7)])
      assert_eq(snapshot.maps().length(), 1)
      assert_eq(snapshot.maps()[0].value(), Some(@y.String("Ada")))
      assert_eq(snapshot.sequences().length(), 2)
      assert_eq(snapshot.sequences()[0].values().length(), 2)
    }
  }
}

///|
test "codec rejects truncated unsupported trailing and oversized input" {
  let encoded = @y.Update::new(None, []).unwrap().encode().unwrap()
  let truncated = Bytes::from_array(
    encoded.to_array().exact_view(end=encoded.length() - 1),
  )
  expect_decode_error(truncated, @y.MalformedUpdate)

  let unsupported = encoded.to_array()
  unsupported[4] = b'\x02'
  expect_decode_error(
    Bytes::from_array(unsupported.exact_view()),
    @y.UnsupportedVersion,
  )

  expect_decode_error(
    encoded + Bytes::from_array([b'\x00']),
    @y.MalformedUpdate,
  )
  expect_decode_error(Bytes::make(16777217, b'\x00'), @y.UpdateTooLarge)
}

///|
test "codec enforces string count UTF-8 and value nesting limits" {
  let encoded = @y.Update::new(None, []).unwrap().encode().unwrap()
  let too_many_events = encoded.to_array()
  too_many_events[6] = b'\x00'
  too_many_events[7] = b'\x01'
  too_many_events[8] = b'\x86'
  too_many_events[9] = b'\xA1'
  expect_decode_error(
    Bytes::from_array(too_many_events.exact_view()),
    @y.UpdateTooLarge,
  )

  let checkpoint_frontier = @y.StateVector::from_metadata(
    [("base", 1, 1)],
    Some("epoch"),
  ).unwrap()
  let checkpoint = @y.CheckpointSnapshot::new(
    "epoch",
    checkpoint_frontier,
    [],
    [],
  ).unwrap()
  let with_checkpoint = @y.Update::new(Some(checkpoint), [])
    .unwrap()
    .encode()
    .unwrap()
  let oversized_string = with_checkpoint.to_array()
  oversized_string[6] = b'\x00'
  oversized_string[7] = b'\x10'
  oversized_string[8] = b'\x00'
  oversized_string[9] = b'\x01'
  expect_decode_error(
    Bytes::from_array(oversized_string.exact_view()),
    @y.UpdateTooLarge,
  )

  let invalid_utf8 = with_checkpoint.to_array()
  invalid_utf8[10] = b'\xFF'
  expect_decode_error(
    Bytes::from_array(invalid_utf8.exact_view()),
    @y.MalformedUpdate,
  )
  expect_decode_error(raw_nested_value_update(129), @y.InvalidValueDepth)
}

///|
test "checked constructors reject duplicate or inconsistent metadata and recursive values" {
  assert_true(
    @y.StateVector::from_metadata([("replica", 1, 1), ("replica", 2, 2)], None).is_err(),
  )
  assert_true(
    @y.StateVector::from_metadata([("replica", -1, 1)], None).is_err(),
  )

  let frontier = @y.StateVector::from_metadata([("base", 1, 1)], Some("epoch")).unwrap()
  let stamp = @y.EventId::new("base", 1).unwrap()
  let map = @y.MapSnapshotEntry::new(
    "root",
    "key",
    Some(@y.String("value")),
    stamp,
    1,
  ).unwrap()
  assert_true(
    @y.CheckpointSnapshot::new("epoch", frontier, [map, map], []).is_err(),
  )
  assert_true(
    @y.MapSnapshotEntry::new("root", "deleted", None, stamp, 1).is_err(),
  )
  assert_true(
    @y.CheckpointSnapshot::new("different-epoch", frontier, [], []).is_err(),
  )

  let events = codec_event_fixture()
  assert_true(@y.Update::new(None, [events[0], events[0]]).is_err())

  let recursive : Array[@y.Value] = []
  let recursive_value = @y.Array(recursive)
  recursive.push(recursive_value)
  assert_true(
    @y.SequenceSnapshot::new("items", @y.List, [recursive_value]).is_err(),
  )
}

///|
test "oversized updates fail before the encoder can return a partial buffer" {
  let large_text = String::make(262144, '🙂')
  let values : Array[@y.Value] = []
  for _ in 0..<17 {
    values.push(@y.String(large_text))
  }
  let event = codec_make_event(
    "source",
    1,
    @y.StateVector::new(),
    @y.MapSet("root", "large", @y.Array(values)),
  )
  let update = @y.Update::new(None, [event]).unwrap()
  match update.encode() {
    Err(error) => assert_eq(error, @y.UpdateTooLarge)
    Ok(_) => fail("oversized update unexpectedly encoded")
  }
}

///|
test "checkpoint and event values share one exact update-wide budget" {
  let frontier = @y.StateVector::from_metadata(
    [("base", 1, 1)],
    Some("budget-epoch"),
  ).unwrap()
  let sequences : Array[@y.SequenceSnapshot] = []
  for sequence_index in 0..<5 {
    let values : Array[@y.Value] = []
    for _ in 0..<100000 {
      values.push(@y.Null)
    }
    sequences.push(
      @y.SequenceSnapshot::new("snapshot-\{sequence_index}", @y.List, values).unwrap(),
    )
  }
  let checkpoint = @y.CheckpointSnapshot::new(
    "budget-epoch",
    frontier,
    [],
    sequences,
  ).unwrap()

  let nested : Array[@y.Value] = []
  for _ in 0..<4 {
    let values : Array[@y.Value] = []
    for _ in 0..<100000 {
      values.push(@y.Null)
    }
    nested.push(@y.Array(values))
  }
  let events : Array[@y.Event] = [
    codec_make_event(
      "tail-large",
      1,
      frontier,
      @y.MapSet("root", "large", @y.Array(nested)),
    ),
  ]
  let almost_full : Array[@y.Value] = []
  for _ in 0..<99980 {
    almost_full.push(@y.Null)
  }
  events.push(
    codec_make_event(
      "tail-almost-full",
      1,
      frontier,
      @y.MapSet("root", "almost-full", @y.Array(almost_full)),
    ),
  )
  for index in 0..<14 {
    events.push(
      codec_make_event(
        "tail-small-\{index}",
        1,
        frontier,
        @y.MapSet("root", "small-\{index}", @y.Null),
      ),
    )
  }
  let accepted = @y.Update::new(Some(checkpoint), events).unwrap()
  let bytes = accepted.encode().unwrap()
  assert_true(@y.Update::decode(bytes).is_ok())
  events.push(
    codec_make_event(
      "tail-over-budget",
      1,
      frontier,
      @y.MapSet("root", "overflow", @y.Null),
    ),
  )
  assert_true(
    @y.Update::new(Some(checkpoint), events) is Err(@y.UpdateTooLarge),
  )
}

///|
test "invalid later event cannot partially affect a document when applying an update" {
  let first = codec_make_event(
    "sender",
    1,
    @y.StateVector::new(),
    @y.MapSet("root", "value", @y.String("must roll back")),
  )
  let second = codec_make_event(
    "sender",
    2,
    @y.StateVector::from_metadata([("sender", 1, first.lamport())], None).unwrap(),
    @y.SequenceDelete("missing-list", @y.List, @y.EventNode(first.id())),
  )
  let update = @y.Update::decode(
    @y.Update::new(None, [first, second]).unwrap().encode().unwrap(),
  ).unwrap()
  let receiver = @y.Document::new("receiver").unwrap()
  let before = receiver.state_vector().metadata_entries()
  assert_true(receiver.apply_update(update).is_err())
  assert_eq(receiver.state_vector().metadata_entries(), before)
  assert_eq(receiver.event_counts(), (0, 0))
  assert_eq(receiver.map_get("root", "value"), None)
}

///|
test "full and incremental updates carry checkpoints and are same epoch idempotent" {
  let source = @y.Document::new("source").unwrap()
  let _ = source.map_set("profile", "name", @y.String("before")).unwrap()
  let _ = source.map_set("profile", "gone", @y.String("temporary")).unwrap()
  let _ = source.map_delete("profile", "gone").unwrap()
  let _ = source
    .list_insert("items", 0, [@y.String("first"), @y.String("second")])
    .unwrap()
  let _ = source.text_insert("body", 0, "A🙂B").unwrap()

  let receiver = @y.Document::new("receiver").unwrap()
  let initial = source.full_update().unwrap()
  let initial_bytes = initial.encode().unwrap()
  let _ = receiver
    .apply_update(@y.Update::decode(initial_bytes).unwrap())
    .unwrap()
  assert_eq(receiver.map_get("profile", "name"), Some(@y.String("before")))
  assert_eq(receiver.map_get("profile", "gone"), None)
  assert_eq(receiver.list_values("items"), [
    @y.String("first"),
    @y.String("second"),
  ])
  assert_eq(receiver.text("body"), "A🙂B")

  let _ = source.map_set("profile", "name", @y.String("after")).unwrap()
  let delta = source.update_since(receiver.state_vector()).unwrap()
  assert_eq(delta.events().length(), 1)
  let delta_bytes = delta.encode().unwrap()
  let _ = receiver
    .apply_update(@y.Update::decode(delta_bytes).unwrap())
    .unwrap()
  assert_eq(receiver.map_get("profile", "name"), Some(@y.String("after")))

  let _ = source.compact("epoch-1").unwrap()
  let compacted = source.full_update().unwrap()
  let checkpoint_bytes = compacted.encode().unwrap()
  let _ = receiver
    .apply_update(@y.Update::decode(checkpoint_bytes).unwrap())
    .unwrap()
  assert_eq(receiver.state_vector().checkpoint(), Some("epoch-1"))
  assert_eq(receiver.map_get("profile", "gone"), None)
  assert_eq(receiver.storage_counts().3, 1)

  let after_first_checkpoint_apply = receiver.state_vector().metadata_entries()
  let repeated = @y.Update::decode(
    source.full_update().unwrap().encode().unwrap(),
  ).unwrap()
  let _ = receiver.apply_update(repeated).unwrap()
  assert_eq(
    receiver.state_vector().metadata_entries(),
    after_first_checkpoint_apply,
  )
  assert_eq(receiver.storage_counts().3, 1)

  let _ = source.text_insert("body", 3, "!").unwrap()
  let post_checkpoint_full = source.full_update().unwrap()
  let post_checkpoint_bytes = post_checkpoint_full.encode().unwrap()
  let fresh_full_receiver = @y.Document::new("fresh-full").unwrap()
  let _ = fresh_full_receiver
    .apply_update(@y.Update::decode(post_checkpoint_bytes).unwrap())
    .unwrap()
  let _ = fresh_full_receiver
    .apply_update(@y.Update::decode(post_checkpoint_bytes).unwrap())
    .unwrap()
  assert_eq(fresh_full_receiver.text("body"), "A🙂B!")

  let dirty_receiver = @y.Document::new("dirty-same-epoch").unwrap()
  let _ = dirty_receiver
    .apply_update(@y.Update::decode(checkpoint_bytes).unwrap())
    .unwrap()
  let _ = dirty_receiver.text_insert("body", 3, "?").unwrap()
  let _ = dirty_receiver
    .apply_update(@y.Update::decode(post_checkpoint_bytes).unwrap())
    .unwrap()
  assert_eq(dirty_receiver.text("body").char_length(), 5)
  assert_true(dirty_receiver.text("body").contains("!"))
  assert_true(dirty_receiver.text("body").contains("?"))

  let incremental = source.update_since(receiver.state_vector()).unwrap()
  match incremental.checkpoint() {
    None => ()
    Some(_) =>
      fail("same epoch incremental update unexpectedly carried a checkpoint")
  }
  assert_eq(incremental.events().length(), 1)
  let _ = receiver
    .apply_update(@y.Update::decode(incremental.encode().unwrap()).unwrap())
    .unwrap()
  assert_eq(receiver.text("body"), "A🙂B!")
}
