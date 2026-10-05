///|
test "failed undo leaves older private compensation targets unchanged" {
  let frontier = StateVector::from_metadata(
    [("atomic-owner", 2147483643, 2147483643)],
    Some("atomic-epoch"),
  ).unwrap()
  let checkpoint = CheckpointSnapshot::new("atomic-epoch", frontier, [], []).unwrap()
  let document = Document::new("atomic-owner").unwrap()
  let _ = document
    .apply_update(Update::new(Some(checkpoint), []).unwrap())
    .unwrap()
  let _ = document.map_set("root", "second", Int(0)).unwrap()
  let initial_target = document.history[0].id
  let _ = document
    .transact([
      MapSet("root", "first", Int(1)),
      MapSet("root", "second", Int(2)),
    ])
    .unwrap()

  assert_true(document.undo() is Err(ClockOverflow))
  match document.undo[0].actions[0] {
    RestoreMap(_, _, target, _, _) => assert_eq(target, initial_target)
    _ => assert_true(false)
  }
}
