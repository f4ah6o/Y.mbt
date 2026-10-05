///|
fn malformed_utf16_samples() -> Array[String] {
  let astral = "😀"
  let high = astral.unsafe_substring(start=0, end=1)
  let low = astral.unsafe_substring(start=1, end=2)
  [high, low, high + "x", low + high]
}

///|
test "unpaired UTF-16 surrogates fail at every string admission boundary" {
  for invalid in malformed_utf16_samples() {
    assert_true(@y.Document::new(invalid) is Err(@y.InvalidUnicode))
    assert_true(@y.EventId::new(invalid, 1) is Err(@y.InvalidUnicode))
    assert_true(
      @y.StateVector::from_metadata([(invalid, 1, 1)], None)
      is Err(@y.InvalidUnicode),
    )

    let document = @y.Document::new("valid-replica").unwrap()
    assert_true(
      document.track_peer(invalid, @y.StateVector::new())
      is Err(@y.InvalidUnicode),
    )
    assert_true(
      document.map_set(invalid, "key", @y.Int(1)) is Err(@y.InvalidUnicode),
    )
    assert_true(
      document.map_set("root", invalid, @y.Int(1)) is Err(@y.InvalidUnicode),
    )
    assert_true(
      document.map_set("root", "key", @y.String(invalid))
      is Err(@y.InvalidUnicode),
    )
    assert_true(
      document.list_insert("items", 0, [@y.Object(Map([(invalid, @y.Int(1))]))])
      is Err(@y.InvalidUnicode),
    )
    assert_true(
      document.text_insert("body", 0, invalid) is Err(@y.InvalidUnicode),
    )
    assert_true(
      @y.Event::new(
        @y.EventId::new("remote", 1).unwrap(),
        @y.StateVector::new(),
        @y.SequenceInsert("body", @y.Text, @y.Root, @y.String(invalid)),
      )
      is Err(@y.InvalidUnicode),
    )
    assert_true(
      @y.SequenceSnapshot::new("body", @y.Text, [@y.String(invalid)])
      is Err(@y.InvalidUnicode),
    )
    assert_true(
      @y.MapSnapshotEntry::new(
        "root",
        invalid,
        Some(@y.Int(1)),
        @y.EventId::new("remote", 1).unwrap(),
        1,
      )
      is Err(@y.InvalidUnicode),
    )
    assert_true(
      @y.Event::new(
        @y.EventId::new("remote", 1).unwrap(),
        @y.StateVector::new(),
        @y.SequenceInsert(
          "body",
          @y.Text,
          @y.CheckpointNode(invalid, "body", @y.Text, 0),
          @y.String("x"),
        ),
      )
      is Err(@y.InvalidUnicode),
    )
  }

  let checkpoint_frontier = @y.StateVector::from_metadata([], Some("epoch")).unwrap()
  let malformed_checkpoint = @y.CheckpointSnapshot::new(
    malformed_utf16_samples()[0],
    checkpoint_frontier,
    [],
    [],
  )
  assert_true(malformed_checkpoint is Err(@y.InvalidUnicode))

  let atomic = @y.Document::new("atomic-unicode").unwrap()
  let before = atomic.state_vector().metadata_entries()
  let bad_text = malformed_utf16_samples()[1]
  assert_true(
    atomic.transact([
      @y.MapSet("root", "first", @y.Int(1)),
      @y.TextInsert("body", 0, bad_text),
    ])
    is Err(@y.InvalidUnicode),
  )
  assert_eq(atomic.state_vector().metadata_entries(), before)
  assert_eq(atomic.map_get("root", "first"), None)
}

///|
test "valid astral scalars replacement character and NUL survive persistence" {
  let source = @y.Document::new("replica😀").unwrap()
  let value = "🙂�\u{0}"
  let _ = source
    .map_set("プロフィール", "name", @y.String(value))
    .unwrap()
  let _ = source.text_insert("本文", 0, value).unwrap()
  let _ = source.compact("unicode-epoch").unwrap()
  let bytes = source.full_update().unwrap().encode().unwrap()

  let receiver = @y.Document::new("receiver").unwrap()
  let update = @y.Update::decode(bytes).unwrap()
  let _ = receiver.apply_update(update).unwrap()
  assert_eq(
    receiver.map_get("プロフィール", "name"),
    Some(@y.String(value)),
  )
  assert_eq(receiver.text("本文"), value)
}
