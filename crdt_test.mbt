///|
fn test_event(
  replica : String,
  counter : Int,
  deps : @y.StateVector,
  op : @y.Operation,
) -> @y.Event {
  @y.Event::new(@y.EventId::new(replica, counter).unwrap(), deps, op).unwrap()
}

///|
fn test_vector(entries : Array[(String, Int, Int)]) -> @y.StateVector {
  @y.StateVector::from_metadata(entries, None).unwrap()
}

///|
fn reverse_test_events(events : Array[@y.Event]) -> Array[@y.Event] {
  let output : Array[@y.Event] = []
  for index in 0..<events.length() {
    output.push(events[events.length() - index - 1])
  }
  output
}

///|
fn shuffled_test_events(
  events : Array[@y.Event],
  seed : Int,
) -> Array[@y.Event] {
  let output = events.copy()
  let mut state = seed
  for index in 0..<output.length() {
    state = (state * 37 + 11) % 997
    let other = state % output.length()
    let temporary = output[index]
    output[index] = output[other]
    output[other] = temporary
  }
  output
}

///|
fn assert_same_projection(
  left : @y.Document,
  right : @y.Document,
) -> Unit raise {
  assert_eq(
    left.state_vector().metadata_entries(),
    right.state_vector().metadata_entries(),
  )
  assert_eq(left.map_snapshot("shared"), right.map_snapshot("shared"))
  assert_eq(left.list_values("items"), right.list_values("items"))
  assert_eq(left.text("body"), right.text("body"))
}

///|
test "causal LWW winner is independent of cross-batch arrival order" {
  let empty = @y.StateVector::new()
  let a = test_event("z", 1, empty, @y.MapSet("root", "x", @y.String("A")))
  let after_a = test_vector([("z", 1, a.lamport())])
  let b = test_event("a", 1, after_a, @y.MapSet("root", "x", @y.String("B")))
  let c = test_event("m", 1, empty, @y.MapSet("root", "x", @y.String("C")))
  let permutations = [
    [a, b, c],
    [a, c, b],
    [b, a, c],
    [b, c, a],
    [c, a, b],
    [c, b, a],
  ]
  for permutation in permutations {
    let document = @y.Document::new("receiver").unwrap()
    for event in permutation {
      let _ = document.apply_events([event]).unwrap()
      let _ = document.apply_events([event]).unwrap()
    }
    assert_eq(document.map_get("root", "x"), Some(@y.String("B")))
  }
}

///|
test "conditional map undo cannot erase an independent concurrent write" {
  let empty = @y.StateVector::new()
  let original = test_event(
    "z",
    1,
    empty,
    @y.MapSet("root", "x", @y.String("old")),
  )
  let original_frontier = test_vector([("z", 1, original.lamport())])
  let undo = test_event(
    "z",
    2,
    original_frontier,
    @y.MapRestore("root", "x", original.id(), Some(@y.String("restored"))),
  )
  let concurrent = test_event(
    "a",
    1,
    original_frontier,
    @y.MapSet("root", "x", @y.String("concurrent")),
  )
  let document1 = @y.Document::new("one").unwrap()
  let document2 = @y.Document::new("two").unwrap()
  let _ = document1.apply_events([original]).unwrap()
  let _ = document1.apply_events([undo]).unwrap()
  let _ = document1.apply_events([concurrent]).unwrap()
  let _ = document2.apply_events([original]).unwrap()
  let _ = document2.apply_events([concurrent]).unwrap()
  let _ = document2.apply_events([undo]).unwrap()
  assert_eq(document1.map_get("root", "x"), Some(@y.String("concurrent")))
  assert_eq(document2.map_get("root", "x"), Some(@y.String("concurrent")))
}

///|
test "map undo rebinds only the restored predecessor across remote writes" {
  let local_doc = @y.Document::new("undo-local").unwrap()
  let _ = local_doc.map_set("root", "key", @y.Int(1)).unwrap()

  let remote = @y.Document::new("undo-remote").unwrap()
  let _ = remote.apply_events(local_doc.events()).unwrap()
  let _ = remote.map_set("root", "key", @y.Int(2)).unwrap()
  let _ = local_doc.apply_events(remote.events()).unwrap()
  let _ = local_doc.map_set("root", "key", @y.Int(3)).unwrap()

  let _ = local_doc.undo().unwrap()
  assert_eq(local_doc.map_get("root", "key"), Some(@y.Int(2)))
  let _ = local_doc.undo().unwrap()
  assert_eq(local_doc.map_get("root", "key"), Some(@y.Int(2)))
  let _ = local_doc.redo().unwrap()
  assert_eq(local_doc.map_get("root", "key"), Some(@y.Int(2)))
  let _ = local_doc.redo().unwrap()
  assert_eq(local_doc.map_get("root", "key"), Some(@y.Int(3)))

  let local_only = @y.Document::new("undo-cycle").unwrap()
  let _ = local_only.map_set("root", "key", @y.Int(1)).unwrap()
  let _ = local_only.map_set("root", "key", @y.Int(2)).unwrap()
  let _ = local_only.undo().unwrap()
  assert_eq(local_only.map_get("root", "key"), Some(@y.Int(1)))
  let _ = local_only.redo().unwrap()
  assert_eq(local_only.map_get("root", "key"), Some(@y.Int(2)))
  let _ = local_only.undo().unwrap()
  let _ = local_only.undo().unwrap()
  assert_eq(local_only.map_get("root", "key"), None)
  let _ = local_only.redo().unwrap()
  assert_eq(local_only.map_get("root", "key"), Some(@y.Int(1)))
  let _ = local_only.redo().unwrap()
  assert_eq(local_only.map_get("root", "key"), Some(@y.Int(2)))
}

///|
test "a suppressed concurrent restore cannot block undo of the visible winner" {
  let seed = @y.Document::new("restore-seed").unwrap()
  let _ = seed.map_set("root", "x", @y.Int(0)).unwrap()
  let seed_events = seed.events()

  let branch_a = @y.Document::new("restore-a").unwrap()
  let _ = branch_a.apply_events(seed_events).unwrap()
  let _ = branch_a.map_set("root", "x", @y.Int(1)).unwrap()
  let _ = branch_a.undo().unwrap()
  assert_eq(branch_a.map_get("root", "x"), Some(@y.Int(0)))

  let branch_z = @y.Document::new("restore-z").unwrap()
  let _ = branch_z.apply_events(seed_events).unwrap()
  let _ = branch_z.map_set("root", "x", @y.Int(2)).unwrap()
  for event in branch_a.events() {
    let _ = branch_z.apply_events([event]).unwrap()
  }
  assert_eq(branch_z.map_get("root", "x"), Some(@y.Int(2)))
  let _ = branch_z.undo().unwrap()
  assert_eq(branch_z.map_get("root", "x"), Some(@y.Int(0)))
  let _ = branch_z.redo().unwrap()
  assert_eq(branch_z.map_get("root", "x"), Some(@y.Int(2)))

  let all_by_id : Map[@y.EventId, @y.Event] = {}
  for event in branch_a.events() {
    all_by_id[event.id()] = event
  }
  for event in branch_z.events() {
    all_by_id[event.id()] = event
  }
  let all_events = all_by_id.values().to_array()
  let forward = @y.Document::new("restore-forward").unwrap()
  let reverse = @y.Document::new("restore-reverse").unwrap()
  for event in all_events {
    let _ = forward.apply_events([event]).unwrap()
  }
  for event in reverse_test_events(all_events) {
    let _ = reverse.apply_events([event]).unwrap()
    let _ = reverse.apply_events([event]).unwrap()
  }
  assert_eq(forward.map_get("root", "x"), Some(@y.Int(2)))
  assert_eq(reverse.map_get("root", "x"), Some(@y.Int(2)))
  assert_eq(
    forward.state_vector().metadata_entries(),
    reverse.state_vector().metadata_entries(),
  )
}

///|
test "insertions after synchronization honor prepend middle and append indices" {
  let source = @y.Document::new("source").unwrap()
  let _ = source.text_insert("body", 0, "AB").unwrap()
  let received = @y.Document::new("received").unwrap()
  let _ = received.apply_events(source.events()).unwrap()
  let _ = received.text_insert("body", 1, "X").unwrap()
  assert_eq(received.text("body"), "AXB")

  let prefix = @y.Document::new("prefix").unwrap()
  let _ = prefix.apply_events(source.events()).unwrap()
  let _ = prefix.text_insert("body", 0, "P").unwrap()
  assert_eq(prefix.text("body"), "PAB")

  let suffix = @y.Document::new("suffix").unwrap()
  let _ = suffix.apply_events(source.events()).unwrap()
  let _ = suffix.text_insert("body", 2, "S").unwrap()
  assert_eq(suffix.text("body"), "ABS")
}

///|
test "relative positions round trip every text boundary for both affinities" {
  let document = @y.Document::new("cursor").unwrap()
  let _ = document.text_insert("body", 0, "A🙂😀B").unwrap()
  for index in 0..<=4 {
    for affinity in [@y.Before, @y.After] {
      let position = document
        .position_at("body", @y.Text, index, affinity)
        .unwrap()
      assert_eq(document.resolve_position(position).unwrap(), index)
    }
  }
}

///|
test "remote batch with a causal cycle fails without changing state" {
  let document = @y.Document::new("receiver").unwrap()
  let before = document.state_vector().metadata_entries()
  let a_dependencies = test_vector([("b", 1, 1)])
  let b_dependencies = test_vector([("a", 1, 2)])
  let a = test_event(
    "a",
    1,
    a_dependencies,
    @y.MapSet("root", "x", @y.String("A")),
  )
  let b = test_event(
    "b",
    1,
    b_dependencies,
    @y.MapSet("root", "x", @y.String("B")),
  )
  assert_true(document.apply_events([a, b]).is_err())
  assert_eq(document.state_vector().metadata_entries(), before)
  assert_eq(document.event_counts(), (0, 0))
  assert_eq(document.map_get("root", "x"), None)
}

///|
test "invalid remote operation leaves clocks and observers untouched" {
  let seed = @y.Document::new("anchor-source").unwrap()
  let _ = seed.list_insert("items", 0, [@y.Int(1)]).unwrap()
  let document = @y.Document::new("receiver").unwrap()
  let _ = document.apply_events(seed.events()).unwrap()
  let mut notifications = 0
  let _observer = document.observe(_ => notifications += 1)
  let anchor = seed.events()[0].id()
  let invalid = test_event(
    "sender",
    1,
    seed.state_vector(),
    @y.SequenceInsert("items", @y.Text, @y.EventNode(anchor), @y.String("x")),
  )
  let before = document.state_vector().metadata_entries()
  assert_true(document.apply_events([invalid]) is Err(@y.AnchorTypeMismatch))
  assert_eq(document.state_vector().metadata_entries(), before)
  assert_eq(document.event_counts(), (1, 0))
  assert_eq(notifications, 0)
}

///|
test "aggregate replica clocks reject overflow before integrating any event" {
  let events : Array[@y.Event] = []
  for index in 0..<10001 {
    let replica = "clock-peer-\{index}"
    let event = @y.Event::new(
      @y.EventId::new(replica, 1).unwrap(),
      @y.StateVector::new(),
      @y.SequenceInsert("root-\{index}", @y.List, @y.Root, @y.Int(index)),
    ).unwrap()
    events.push(event)
  }

  let receiver = @y.Document::new("clock-overflow-receiver").unwrap()
  let update = @y.Update::new(None, events).unwrap()
  assert_true(receiver.apply_update(update) is Err(@y.UpdateTooLarge))
  assert_eq(receiver.state_vector().metadata_entries(), [])
  assert_eq(receiver.event_counts(), (0, 0))
  assert_eq(receiver.storage_counts(), (0, 0, 0, 0))

  let allowed_events : Array[@y.Event] = []
  for index in 0..<10000 {
    allowed_events.push(events[index])
  }
  let full = @y.Document::new("clock-full-vector").unwrap()
  let _ = full.apply_events(allowed_events).unwrap()
  assert_eq(full.state_vector().metadata_entries().length(), 10000)
  let before = full.state_vector().metadata_entries()
  assert_true(
    full.map_set("local-root", "key", @y.Int(1)) is Err(@y.UpdateTooLarge),
  )
  assert_eq(full.state_vector().metadata_entries(), before)
  assert_eq(full.event_counts(), (10000, 0))
}

///|
test "a deferred invalid operation is quarantined without blocking its dependency" {
  let source = @y.Document::new("pending-source").unwrap()
  let _ = source.list_insert("items", 0, [@y.Int(1)]).unwrap()
  let anchor = source.events()[0].id()
  let receiver = @y.Document::new("pending-receiver").unwrap()
  let malformed = test_event(
    "pending-malformed",
    1,
    source.state_vector(),
    @y.SequenceInsert("items", @y.Text, @y.EventNode(anchor), @y.String("x")),
  )
  let _ = receiver.apply_events([malformed]).unwrap()
  assert_eq(receiver.event_counts(), (0, 1))
  let _ = receiver.map_set("local", "survives", @y.Bool(true)).unwrap()
  assert_eq(receiver.map_get("local", "survives"), Some(@y.Bool(true)))

  let _ = receiver.apply_events(source.events()).unwrap()
  assert_eq(receiver.event_counts(), (2, 0))
  assert_eq(receiver.rejected_events(), [
    (malformed.id(), @y.AnchorTypeMismatch),
  ])
  assert_true(receiver.discard_rejected(malformed.id()))
  assert_true(!receiver.discard_rejected(malformed.id()))
  assert_eq(receiver.list_values("items"), [@y.Int(1)])
  assert_eq(receiver.map_get("local", "survives"), Some(@y.Bool(true)))
}

///|
test "a failed multi-action undo cannot rebind live history" {
  let frontier = @y.StateVector::from_metadata(
    [("atomic-owner", 2147483643, 2147483643)],
    Some("atomic-epoch"),
  ).unwrap()
  let checkpoint = @y.CheckpointSnapshot::new("atomic-epoch", frontier, [], []).unwrap()
  let document = @y.Document::new("atomic-owner").unwrap()
  let update = @y.Update::new(Some(checkpoint), []).unwrap()
  let _ = document.apply_update(update).unwrap()
  let _ = document.map_set("root", "second", @y.Int(0)).unwrap()
  let initial_target = document.events()[0].id()
  let _ = document
    .transact([
      @y.MapSet("root", "first", @y.Int(1)),
      @y.MapSet("root", "second", @y.Int(2)),
    ])
    .unwrap()
  let before_vector = document.state_vector().metadata_entries()
  assert_true(document.undo() is Err(@y.ClockOverflow))
  assert_eq(document.state_vector().metadata_entries(), before_vector)
  assert_eq(document.map_get("root", "first"), Some(@y.Int(1)))
  assert_eq(document.map_get("root", "second"), Some(@y.Int(2)))
  assert_eq(document.events()[0].id(), initial_target)
}

///|
test "observer transitions remain in commit order during reentrant edits" {
  let document = @y.Document::new("observer-reentry").unwrap()
  let mut reentered = false
  let _first = document.observe(changes => {
    for change in changes.changes() {
      match change {
        @y.MapChanged("root", "key", _, Some(@y.Int(1))) if !reentered => {
          reentered = true
          let _ = document.map_set("root", "key", @y.Int(2)).unwrap()
        }
        _ => ()
      }
    }
  })
  let mirror : Map[String, @y.Value] = {}
  let after_values : Array[@y.Value?] = []
  let _second = document.observe(changes => {
    for change in changes.changes() {
      match change {
        @y.MapChanged("root", "key", _, after) => {
          match after {
            None => mirror.remove("key")
            Some(value) => mirror["key"] = value
          }
          after_values.push(after)
        }
        _ => ()
      }
    }
  })
  let _ = document.map_set("root", "key", @y.Int(1)).unwrap()
  assert_eq(after_values, [Some(@y.Int(1)), Some(@y.Int(2))])
  assert_eq(mirror.get("key"), Some(@y.Int(2)))
  assert_eq(document.map_get("root", "key"), Some(@y.Int(2)))
}

///|
test "event dependency vectors must include each predecessor causal past" {
  let empty = @y.StateVector::new()
  let root = test_event("z", 1, empty, @y.MapSet("root", "seed", @y.Int(1)))
  let root_vector = test_vector([("z", 1, root.lamport())])
  let dependent = test_event(
    "a",
    1,
    root_vector,
    @y.MapSet("root", "dependent", @y.Int(2)),
  )
  let missing_ancestor_vector = test_vector([("a", 1, dependent.lamport())])
  let omitted_ancestor = test_event(
    "a",
    2,
    missing_ancestor_vector,
    @y.MapSet("root", "invalid", @y.Int(3)),
  )
  let document = @y.Document::new("causal-closure").unwrap()
  let _ = document.apply_events([root]).unwrap()
  let _ = document.apply_events([dependent]).unwrap()
  let before = document.state_vector().metadata_entries()
  assert_true(
    document.apply_events([omitted_ancestor]) is Err(@y.InvalidDependency),
  )
  assert_eq(document.state_vector().metadata_entries(), before)
  assert_eq(document.map_get("root", "invalid"), None)

  let peer = @y.StateVector::from_metadata(
    [("a", 1, dependent.lamport())],
    None,
  ).unwrap()
  assert_true(document.update_since(peer) is Err(@y.InvalidDependency))
  let _ = document.track_peer("peer", peer).unwrap()
  assert_true(
    document.acknowledge_peer("peer", peer) is Err(@y.InvalidAcknowledgement),
  )
}

///|
test "a same-frontier checkpoint cannot omit visible state or inflate causal time" {
  let document = @y.Document::new("checkpoint-exact").unwrap()
  let _ = document.map_set("root", "key", @y.String("visible")).unwrap()
  let _ = document.text_insert("body", 0, "retained").unwrap()
  let current = document.state_vector()
  let forged_frontier = @y.StateVector::from_metadata(
    current.metadata_entries(),
    Some("forged-exact"),
  ).unwrap()
  let omitted = @y.CheckpointSnapshot::new(
    "forged-exact",
    forged_frontier,
    [],
    [],
  ).unwrap()
  let update = @y.Update::new(Some(omitted), []).unwrap()
  assert_true(document.apply_update(update) is Err(@y.CheckpointConflict))
  assert_eq(document.map_get("root", "key"), Some(@y.String("visible")))
  assert_eq(document.text("body"), "retained")

  let known = @y.Document::new("checkpoint-time").unwrap()
  let seed = test_event(
    "seed",
    1,
    @y.StateVector::new(),
    @y.MapSet("root", "x", @y.Int(1)),
  )
  let _ = known.apply_events([seed]).unwrap()
  let observed = test_event(
    "later",
    1,
    test_vector([("seed", 1, seed.lamport())]),
    @y.MapSet("root", "y", @y.Int(2)),
  )
  let _ = known.apply_events([observed]).unwrap()
  let inflated_frontier = @y.StateVector::from_metadata(
    [("later", 100, 100), ("seed", 1, 1)],
    Some("inflated"),
  ).unwrap()
  let inflated = @y.CheckpointSnapshot::new("inflated", inflated_frontier, [], []).unwrap()
  assert_true(
    known.apply_update(@y.Update::new(Some(inflated), []).unwrap())
    is Err(@y.InvalidDependency),
  )
}

///|
test "recursive values reject cycles before an event attempts to copy them" {
  let values : Array[@y.Value] = []
  let recursive = @y.Array(values)
  values.push(recursive)
  let result = @y.Event::new(
    @y.EventId::new("sender", 1).unwrap(),
    @y.StateVector::new(),
    @y.MapSet("root", "cycle", recursive),
  )
  assert_true(result.is_err())
}

///|
test "mutable values and returned changes are copied at every API boundary" {
  let document = @y.Document::new("owner").unwrap()
  let nested : Array[@y.Value] = [@y.String("initial")]
  let _ = document.map_set("root", "value", @y.Array(nested)).unwrap()
  nested[0] = @y.String("caller mutation")
  let snapshot = document.map_snapshot("root")
  match snapshot.get("value") {
    Some(@y.Array(values)) => values[0] = @y.String("snapshot mutation")
    _ => assert_true(false)
  }
  match document.map_get("root", "value") {
    Some(@y.Array(values)) => assert_eq(values[0], @y.String("initial"))
    _ => assert_true(false)
  }
}

///|
test "undo and redo coalesce repeated writes in one transaction" {
  let document = @y.Document::new("undo-map").unwrap()
  let _ = document.map_set("root", "x", @y.String("zero")).unwrap()
  let _ = document
    .transact([
      @y.MapSet("root", "x", @y.String("one")),
      @y.MapSet("root", "x", @y.String("two")),
      @y.MapDelete("root", "x"),
      @y.MapSet("root", "x", @y.String("final")),
    ])
    .unwrap()
  assert_eq(document.map_get("root", "x"), Some(@y.String("final")))
  let _ = document.undo().unwrap()
  assert_eq(document.map_get("root", "x"), Some(@y.String("zero")))
  let _ = document.redo().unwrap()
  assert_eq(document.map_get("root", "x"), Some(@y.String("final")))
}

///|
test "undo cancels insert-delete pairs and replays delete-insert transactions" {
  let empty_text = @y.Document::new("empty-text").unwrap()
  let _ = empty_text
    .transact([@y.TextInsert("body", 0, "X"), @y.TextDelete("body", 0, 1)])
    .unwrap()
  assert_eq(empty_text.text("body"), "")
  assert_true(empty_text.undo() is Err(@y.UndoUnavailable))

  let empty_list = @y.Document::new("empty-list").unwrap()
  let _ = empty_list
    .transact([
      @y.ListInsert("items", 0, [@y.Int(1)]),
      @y.ListDelete("items", 0, 1),
    ])
    .unwrap()
  assert_eq(empty_list.list_values("items"), [])
  assert_true(empty_list.undo() is Err(@y.UndoUnavailable))

  let document = @y.Document::new("replace").unwrap()
  let _ = document.text_insert("body", 0, "A").unwrap()
  let _ = document
    .transact([@y.TextDelete("body", 0, 1), @y.TextInsert("body", 0, "A")])
    .unwrap()
  assert_eq(document.text("body"), "A")
  let _ = document.undo().unwrap()
  assert_eq(document.text("body"), "A")
  let _ = document.redo().unwrap()
  assert_eq(document.text("body"), "A")
}

///|
test "undoing a sequence delete preserves a concurrent delete" {
  let seed = @y.Document::new("seed").unwrap()
  let _ = seed.text_insert("body", 0, "A").unwrap()
  let branch = @y.Document::new("branch").unwrap()
  let _ = branch.apply_events(seed.events()).unwrap()
  let _ = branch.text_delete("body", 0, 1).unwrap()
  let concurrent = @y.Document::new("concurrent").unwrap()
  let _ = concurrent.apply_events(seed.events()).unwrap()
  let _ = concurrent.text_delete("body", 0, 1).unwrap()
  let concurrent_deletes = concurrent
    .events()
    .filter(event => event.id().replica() == "concurrent")
  let _ = branch.apply_events(concurrent_deletes).unwrap()
  let _ = branch.undo().unwrap()
  assert_eq(branch.text("body"), "")
}

///|
test "checkpoint sync is atomic, rebases visible state, and expires old positions" {
  let source = @y.Document::new("source-cp").unwrap()
  let _ = source.map_set("root", "live", @y.String("kept")).unwrap()
  let _ = source.map_set("root", "gone", @y.String("removed")).unwrap()
  let _ = source.map_delete("root", "gone").unwrap()
  let _ = source.text_insert("body", 0, "AB").unwrap()
  let _ = source.text_delete("body", 0, 1).unwrap()
  let old_position = source.position_at("body", @y.Text, 0, @y.Before).unwrap()
  let stale_frontier = @y.StateVector::new()
  let _snapshot = source.compact("epoch-1").unwrap()
  assert_true(source.resolve_position(old_position) is Err(@y.StalePosition))
  assert_eq(source.map_get("root", "live"), Some(@y.String("kept")))
  assert_eq(source.map_get("root", "gone"), None)
  assert_eq(source.text("body"), "B")
  let counts = source.storage_counts()
  assert_eq(counts.0, 0)
  assert_eq(counts.2, 1)
  assert_eq(counts.3, 1)

  let full = source.full_update().unwrap()
  let encoded = full.encode().unwrap()
  let decoded = @y.Update::decode(encoded).unwrap()
  let stale_peer = @y.Document::new("stale-peer").unwrap()
  let _ = stale_peer.apply_update(decoded).unwrap()
  assert_eq(stale_peer.text("body"), "B")
  assert_eq(stale_peer.map_get("root", "gone"), None)

  let snapshot_update = source.update_since(stale_frontier).unwrap()
  assert_true(snapshot_update.checkpoint() is Some(_))
  let dirty = @y.Document::new("dirty-peer").unwrap()
  let _ = dirty.text_insert("local", 0, "dirty").unwrap()
  let dirty_before = dirty.state_vector().metadata_entries()
  assert_true(dirty.apply_update(snapshot_update) is Err(@y.CheckpointConflict))
  assert_eq(dirty.text("local"), "dirty")
  assert_eq(dirty.state_vector().metadata_entries(), dirty_before)
}

///|
test "remote checkpoint install obeys active peer retention leases" {
  let seed = @y.Document::new("lease-seed").unwrap()
  let _ = seed.map_set("root", "value", @y.String("retained")).unwrap()

  let receiver = @y.Document::new("lease-receiver").unwrap()
  let _ = receiver.apply_events(seed.events()).unwrap()
  let _ = receiver.track_peer("offline-peer", @y.StateVector::new()).unwrap()

  let compacted_source = @y.Document::new("remote-checkpointer").unwrap()
  let _ = compacted_source.apply_events(seed.events()).unwrap()
  let _ = compacted_source.compact("remote-epoch").unwrap()
  let incoming = compacted_source.full_update().unwrap()
  let before = receiver.state_vector().metadata_entries()
  assert_true(receiver.apply_update(incoming) is Err(@y.InvalidAcknowledgement))
  assert_eq(receiver.state_vector().metadata_entries(), before)
  assert_eq(receiver.storage_counts().0, 1)
  assert_eq(receiver.map_get("root", "value"), Some(@y.String("retained")))

  assert_true(receiver.expire_peer("offline-peer"))
  let _ = receiver.apply_update(incoming).unwrap()
  assert_eq(receiver.state_vector().checkpoint(), Some("remote-epoch"))
  assert_eq(receiver.storage_counts().0, 0)
}

///|
test "acknowledged compaction discards old delete metadata and bounds repeated epochs" {
  let document = @y.Document::new("compact").unwrap()
  let initial = document.state_vector()
  let _ = document.track_peer("peer", initial).unwrap()
  for index in 0..<40 {
    let key = "deleted-\{index}"
    let _ = document.map_set("root", key, @y.Int(index)).unwrap()
    let _ = document.map_delete("root", key).unwrap()
    let _ = document
      .text_insert("body", document.text("body").char_length(), "x")
      .unwrap()
    let _ = document
      .text_delete("body", document.text("body").char_length() - 1, 1)
      .unwrap()
  }
  assert_true(document.compact("unacked").is_err())
  let _ = document.acknowledge_peer("peer", document.state_vector()).unwrap()
  let _ = document.compact("epoch-a").unwrap()
  assert_eq(document.storage_counts(), (0, 0, 0, 0))
  assert_true(document.compact("epoch-b").is_err())
  let _ = document.acknowledge_peer("peer", document.state_vector()).unwrap()
  let _ = document.compact("epoch-b").unwrap()
  assert_eq(document.storage_counts(), (0, 0, 0, 0))
}

///|
test "checkpoint snapshots omit empty sequence roots after unique-root churn" {
  let document = @y.Document::new("empty-root-churn").unwrap()
  let _ = document.track_peer("peer", document.state_vector()).unwrap()
  let mut first_size = -1
  for index in 0..<40 {
    let text_root = "text-root-\{index}"
    let list_root = "list-root-\{index}"
    let _ = document.text_insert(text_root, 0, "x").unwrap()
    let _ = document.text_delete(text_root, 0, 1).unwrap()
    let _ = document.list_insert(list_root, 0, [@y.Int(index)]).unwrap()
    let _ = document.list_delete(list_root, 0, 1).unwrap()
    let _ = document.acknowledge_peer("peer", document.state_vector()).unwrap()
    let snapshot = document.compact("root-epoch-\{100 + index}").unwrap()
    assert_eq(snapshot.sequences().length(), 0)
    let update = document.full_update().unwrap()
    let encoded = update.encode().unwrap()
    if index == 0 {
      first_size = encoded.length()
    }
    assert_true(encoded.length() <= first_size + 4)
    assert_eq(update.checkpoint().unwrap().sequences().length(), 0)
    assert_eq(document.storage_counts(), (0, 0, 0, 0))
  }

  let update = document.full_update().unwrap()
  let receiver = @y.Document::new("empty-root-receiver").unwrap()
  let _ = receiver.apply_update(update).unwrap()
  let _ = receiver.apply_update(update).unwrap()
  assert_eq(
    receiver.full_update().unwrap().checkpoint().unwrap().sequences().length(),
    0,
  )
  assert_eq(receiver.text("text-root-39"), "")
  assert_eq(receiver.list_values("list-root-39"), [])
}

///|
test "sequence anchors must be causally named before looking them up" {
  let seed = @y.Document::new("anchor-seed").unwrap()
  let _ = seed.list_insert("items", 0, [@y.Int(1)]).unwrap()
  let anchor = seed.events()[0].id()
  let invalid_insert = @y.Event::new(
    @y.EventId::new("anchor-insert", 1).unwrap(),
    @y.StateVector::new(),
    @y.SequenceInsert("items", @y.List, @y.EventNode(anchor), @y.Int(2)),
  )
  let invalid_delete = @y.Event::new(
    @y.EventId::new("anchor-delete", 1).unwrap(),
    @y.StateVector::new(),
    @y.SequenceDelete("items", @y.List, @y.EventNode(anchor)),
  )
  assert_true(invalid_insert is Err(@y.InvalidDependency))
  assert_true(invalid_delete is Err(@y.InvalidDependency))

  let receiver = @y.Document::new("anchor-receiver").unwrap()
  let pending_insert = test_event(
    "anchor-insert",
    1,
    seed.state_vector(),
    @y.SequenceInsert("items", @y.List, @y.EventNode(anchor), @y.Int(2)),
  )
  let pending_delete = test_event(
    "anchor-delete",
    1,
    seed.state_vector(),
    @y.SequenceDelete("items", @y.List, @y.EventNode(anchor)),
  )
  let _ = receiver.apply_events([pending_insert]).unwrap()
  assert_eq(receiver.event_counts(), (0, 1))
  let _ = receiver.apply_events(seed.events()).unwrap()
  assert_eq(receiver.list_values("items"), [@y.Int(1), @y.Int(2)])
  let _ = receiver.apply_events([pending_delete]).unwrap()
  assert_eq(receiver.list_values("items"), [@y.Int(2)])
  assert_eq(receiver.event_counts(), (3, 0))
}

///|
test "checkpoint node identities include their sequence root and kind" {
  let document = @y.Document::new("scoped-checkpoint").unwrap()
  let _ = document.text_insert("first", 0, "a").unwrap()
  let _ = document.text_insert("second", 0, "b").unwrap()
  let _ = document.compact("scoped-epoch").unwrap()
  let _ = document.text_delete("first", 0, 1).unwrap()
  let _ = document.text_delete("second", 0, 1).unwrap()
  let _ = document.undo().unwrap()
  assert_eq(document.text("first"), "")
  assert_eq(document.text("second"), "b")
  let _ = document.undo().unwrap()
  assert_eq(document.text("first"), "a")
  assert_eq(document.text("second"), "b")
}

///|
test "checkpoint installation rejects a forged known Lamport stamp atomically" {
  let document = @y.Document::new("review-peer").unwrap()
  let _ = document.map_set("root", "key", @y.String("known")).unwrap()
  let stamp = document.events()[0].id()
  let forged_frontier = @y.StateVector::from_metadata(
    [("review-peer", 1, 99)],
    Some("forged-epoch"),
  ).unwrap()
  let entry = @y.MapSnapshotEntry::new(
    "root",
    "key",
    Some(@y.String("known")),
    stamp,
    1,
  ).unwrap()
  let checkpoint = @y.CheckpointSnapshot::new(
    "forged-epoch",
    forged_frontier,
    [entry],
    [],
  )
  let before = document.state_vector().metadata_entries()
  assert_true(checkpoint is Err(@y.MalformedUpdate))
  assert_eq(document.state_vector().metadata_entries(), before)
  assert_eq(document.map_get("root", "key"), Some(@y.String("known")))
}

///|
test "checkpoint entries preserve known map event payloads and winners" {
  let document = @y.Document::new("review-payload").unwrap()
  let _ = document.map_set("root", "key", @y.Int(1)).unwrap()
  let first_stamp = document.events()[0].id()
  let _ = document.map_set("root", "key", @y.Int(2)).unwrap()
  let incoming_frontier = @y.StateVector::from_metadata(
    [("review-payload", 2, 2), ("new-peer", 1, 3)],
    Some("forged-payload"),
  ).unwrap()
  let forged_old = @y.MapSnapshotEntry::new(
    "root",
    "key",
    Some(@y.Int(999)),
    first_stamp,
    1,
  ).unwrap()
  let forged_snapshot = @y.CheckpointSnapshot::new(
    "forged-payload",
    incoming_frontier,
    [forged_old],
    [],
  ).unwrap()
  let before = document.state_vector().metadata_entries()
  assert_true(
    document.apply_update(@y.Update::new(Some(forged_snapshot), []).unwrap())
    is Err(@y.InvalidDependency),
  )
  assert_eq(document.state_vector().metadata_entries(), before)
  assert_eq(document.map_get("root", "key"), Some(@y.Int(2)))
  assert_eq(document.events().length(), 2)

  let rewound = @y.MapSnapshotEntry::new(
    "root",
    "key",
    Some(@y.Int(1)),
    first_stamp,
    1,
  ).unwrap()
  let rewind_snapshot = @y.CheckpointSnapshot::new(
    "rewind-payload",
    @y.StateVector::from_metadata(
      [("review-payload", 2, 2), ("new-peer", 1, 3)],
      Some("rewind-payload"),
    ).unwrap(),
    [rewound],
    [],
  ).unwrap()
  assert_true(
    document.apply_update(@y.Update::new(Some(rewind_snapshot), []).unwrap())
    is Err(@y.CheckpointConflict),
  )

  let sequence_document = @y.Document::new("known-sequence-stamp").unwrap()
  let _ = sequence_document.list_insert("items", 0, [@y.Int(10)]).unwrap()
  let sequence_stamp = sequence_document.events()[0].id()
  let sequence_entry = @y.MapSnapshotEntry::new(
    "items",
    "forged",
    Some(@y.Int(10)),
    sequence_stamp,
    1,
  ).unwrap()
  let sequence_snapshot = @y.CheckpointSnapshot::new(
    "sequence-as-map",
    @y.StateVector::from_metadata(
      [("known-sequence-stamp", 1, 1), ("new-peer", 1, 2)],
      Some("sequence-as-map"),
    ).unwrap(),
    [sequence_entry],
    [],
  ).unwrap()
  assert_true(
    sequence_document.apply_update(
      @y.Update::new(Some(sequence_snapshot), []).unwrap(),
    )
    is Err(@y.InvalidDependency),
  )

  let deletion_document = @y.Document::new("known-delete-stamp").unwrap()
  let _ = deletion_document.map_set("root", "key", @y.Int(10)).unwrap()
  let _ = deletion_document.map_delete("root", "key").unwrap()
  let deletion_stamp = deletion_document.events()[1].id()
  let deletion_entry = @y.MapSnapshotEntry::new(
    "root",
    "key",
    Some(@y.Int(10)),
    deletion_stamp,
    2,
  ).unwrap()
  let deletion_snapshot = @y.CheckpointSnapshot::new(
    "delete-as-map",
    @y.StateVector::from_metadata(
      [("known-delete-stamp", 2, 2), ("new-peer", 1, 3)],
      Some("delete-as-map"),
    ).unwrap(),
    [deletion_entry],
    [],
  ).unwrap()
  assert_true(
    deletion_document.apply_update(
      @y.Update::new(Some(deletion_snapshot), []).unwrap(),
    )
    is Err(@y.InvalidDependency),
  )

  let restore_seed = @y.Document::new("restore-seed").unwrap()
  let _ = restore_seed.map_set("root", "key", @y.Int(0)).unwrap()
  let restoring = @y.Document::new("restore-local").unwrap()
  let _ = restoring.apply_events(restore_seed.events()).unwrap()
  let _ = restoring.map_set("root", "key", @y.Int(1)).unwrap()
  let remote_writer = @y.Document::new("restore-remote").unwrap()
  let _ = remote_writer.apply_events(restoring.events()).unwrap()
  let _ = remote_writer.map_set("root", "key", @y.Int(2)).unwrap()
  let _ = restoring.apply_events(remote_writer.events()).unwrap()
  let _ = restoring.undo().unwrap()
  assert_eq(restoring.map_get("root", "key"), Some(@y.Int(2)))
  let ignored_restore = restoring.events()[3]
  let restore_entry = @y.MapSnapshotEntry::new(
    "root",
    "key",
    Some(@y.Int(0)),
    ignored_restore.id(),
    ignored_restore.lamport(),
  ).unwrap()
  let advanced = restoring.state_vector().metadata_entries()
  advanced.push(("future-peer", 1, 5))
  let ignored_restore_snapshot = @y.CheckpointSnapshot::new(
    "ignored-restore",
    @y.StateVector::from_metadata(advanced, Some("ignored-restore")).unwrap(),
    [restore_entry],
    [],
  ).unwrap()
  assert_true(
    restoring.apply_update(
      @y.Update::new(Some(ignored_restore_snapshot), []).unwrap(),
    )
    is Err(@y.InvalidDependency),
  )

  let restore_branch_seed = @y.Document::new("older-restore-seed").unwrap()
  let _ = restore_branch_seed.map_set("root", "key", @y.Int(0)).unwrap()
  let restore_branch = @y.Document::new("older-restore-local").unwrap()
  let _ = restore_branch.apply_events(restore_branch_seed.events()).unwrap()
  let _ = restore_branch.map_set("root", "key", @y.Int(1)).unwrap()
  let _ = restore_branch.undo().unwrap()
  let first_restore = restore_branch.events()[2]
  let branch_event = @y.Event::new(
    @y.EventId::new("older-restore-branch", 1).unwrap(),
    restore_branch.state_vector(),
    @y.MapRestore("root", "key", first_restore.id(), Some(@y.Int(7))),
  ).unwrap()
  let receiver = @y.Document::new("older-restore-receiver").unwrap()
  let _ = receiver.apply_events(restore_branch.events()).unwrap()
  let _ = restore_branch.redo().unwrap()
  let latest_local = restore_branch.events()[3]
  let _ = receiver.apply_events([latest_local]).unwrap()
  let sender = @y.Document::new("older-restore-sender").unwrap()
  let _ = sender.apply_events(restore_branch.events()).unwrap()
  let _ = sender.apply_events([branch_event]).unwrap()
  assert_eq(sender.map_get("root", "key"), Some(@y.Int(0)))
  let _ = sender.compact("older-restore-epoch").unwrap()
  let _ = receiver.apply_update(sender.full_update().unwrap()).unwrap()
  assert_eq(receiver.map_get("root", "key"), Some(@y.Int(0)))

  let one_stamp = @y.EventId::new("single-map-event", 1).unwrap()
  let first_entry = @y.MapSnapshotEntry::new(
    "root",
    "first",
    Some(@y.Int(1)),
    one_stamp,
    1,
  ).unwrap()
  let second_entry = @y.MapSnapshotEntry::new(
    "root",
    "second",
    Some(@y.Int(2)),
    one_stamp,
    1,
  ).unwrap()
  let repeated_stamp = @y.CheckpointSnapshot::new(
    "repeated-map-stamp",
    @y.StateVector::from_metadata(
      [("single-map-event", 1, 1)],
      Some("repeated-map-stamp"),
    ).unwrap(),
    [first_entry, second_entry],
    [],
  )
  assert_true(repeated_stamp is Err(@y.MalformedUpdate))

  let baseline = @y.Document::new("known-baseline").unwrap()
  let _ = baseline.map_set("root", "stable", @y.String("kept")).unwrap()
  let authority = @y.Document::new("checkpoint-authority").unwrap()
  let _ = authority.apply_events(baseline.events()).unwrap()
  let _ = authority.map_set("other", "key", @y.Int(3)).unwrap()
  let _ = authority.compact("legitimate-advance").unwrap()
  let _ = baseline.apply_update(authority.full_update().unwrap()).unwrap()
  assert_eq(baseline.map_get("root", "stable"), Some(@y.String("kept")))
  assert_eq(baseline.map_get("other", "key"), Some(@y.Int(3)))

  let compacted = @y.Document::new("below-floor-stamp").unwrap()
  let _ = compacted.map_set("root", "key", @y.Int(1)).unwrap()
  let below_floor_stamp = compacted.events()[0].id()
  let _ = compacted.map_set("root", "key", @y.Int(2)).unwrap()
  let _ = compacted.compact("live-baseline").unwrap()
  let below_floor_entry = @y.MapSnapshotEntry::new(
    "root",
    "key",
    Some(@y.Int(1)),
    below_floor_stamp,
    1,
  ).unwrap()
  let below_floor_frontier = compacted.state_vector().metadata_entries()
  below_floor_frontier.push(("below-floor-peer", 1, 3))
  let below_floor_snapshot = @y.CheckpointSnapshot::new(
    "below-floor-advance",
    @y.StateVector::from_metadata(
      below_floor_frontier,
      Some("below-floor-advance"),
    ).unwrap(),
    [below_floor_entry],
    [],
  ).unwrap()
  assert_true(
    compacted.apply_update(
      @y.Update::new(Some(below_floor_snapshot), []).unwrap(),
    )
    is Err(@y.CheckpointConflict),
  )
  assert_eq(compacted.map_get("root", "key"), Some(@y.Int(2)))

  let floor_writer = @y.Document::new("z-writer").unwrap()
  let _ = floor_writer.map_set("root", "key", @y.Int(1)).unwrap()
  let _ = floor_writer.compact("known-map-floor").unwrap()
  let lower_unknown = @y.MapSnapshotEntry::new(
    "root",
    "key",
    Some(@y.Int(999)),
    @y.EventId::new("a-writer", 1).unwrap(),
    1,
  ).unwrap()
  let advanced_floor = floor_writer.state_vector().metadata_entries()
  advanced_floor.push(("a-writer", 1, 1))
  let advanced_floor_snapshot = @y.CheckpointSnapshot::new(
    "advanced-map-floor",
    @y.StateVector::from_metadata(advanced_floor, Some("advanced-map-floor")).unwrap(),
    [lower_unknown],
    [],
  ).unwrap()
  assert_true(
    floor_writer.apply_update(
      @y.Update::new(Some(advanced_floor_snapshot), []).unwrap(),
    )
    is Err(@y.CheckpointConflict),
  )
  assert_eq(floor_writer.map_get("root", "key"), Some(@y.Int(1)))
}

///|
test "an advanced checkpoint cannot undercut a compacted map winner" {
  let document = @y.Document::new("z-writer").unwrap()
  let _ = document.map_set("root", "key", @y.Int(1)).unwrap()
  let _ = document.compact("known-floor").unwrap()

  // Both writers are concurrent at the incoming frontier. The retained
  // checkpoint value is a non-suppressible floor version, and the native LWW
  // order puts z-writer's stamp above a-writer's stamp at equal Lamport time.
  let frontier = @y.StateVector::from_metadata(
    [("z-writer", 1, 1), ("a-writer", 1, 1)],
    Some("incoming-floor"),
  ).unwrap()
  let forged_entry = @y.MapSnapshotEntry::new(
    "root",
    "key",
    Some(@y.Int(999)),
    @y.EventId::new("a-writer", 1).unwrap(),
    1,
  ).unwrap()
  let incoming = @y.CheckpointSnapshot::new(
    "incoming-floor",
    frontier,
    [forged_entry],
    [],
  ).unwrap()

  assert_true(
    document.apply_update(@y.Update::new(Some(incoming), []).unwrap()).is_err(),
  )
  assert_eq(document.map_get("root", "key"), Some(@y.Int(1)))
  assert_eq(document.state_vector().counter("z-writer"), 1)
}

///|
test "unverified peer clocks cannot authorize compaction" {
  let matching_counter = @y.Document::new("same-clock").unwrap()
  let _ = matching_counter.map_set("root", "key", @y.Int(1)).unwrap()
  let forged_lamport = @y.StateVector::from_metadata(
    [("same-clock", 1, 99)],
    None,
  ).unwrap()
  let _ = matching_counter.track_peer("peer", forged_lamport).unwrap()
  assert_true(
    matching_counter.compact("bad-lamport") is Err(@y.InvalidAcknowledgement),
  )
  assert_eq(matching_counter.storage_counts().0, 1)

  let future_counter = @y.Document::new("future-clock").unwrap()
  let impossible = @y.StateVector::from_metadata(
    [("future-clock", 100, 100)],
    None,
  ).unwrap()
  let _ = future_counter.track_peer("peer", impossible).unwrap()
  assert_true(
    future_counter.compact("future") is Err(@y.InvalidAcknowledgement),
  )
  assert_eq(future_counter.storage_counts().0, 0)
}

///|
test "map and sequence undo redo compose across multiple transactions" {
  let maps = @y.Document::new("multi-map-undo").unwrap()
  let _ = maps.map_set("root", "key", @y.String("zero")).unwrap()
  let _ = maps.map_set("root", "key", @y.String("one")).unwrap()
  let _ = maps.map_set("root", "key", @y.String("two")).unwrap()
  let _ = maps.map_delete("root", "key").unwrap()
  assert_eq(maps.map_get("root", "key"), None)
  for _ in 0..<4 {
    let _ = maps.undo().unwrap()
  }
  assert_eq(maps.map_get("root", "key"), None)
  for
    expected in [
      Some(@y.String("zero")),
      Some(@y.String("one")),
      Some(@y.String("two")),
      None,
    ] {
    let _ = maps.redo().unwrap()
    assert_eq(maps.map_get("root", "key"), expected)
  }

  let text = @y.Document::new("multi-text-undo").unwrap()
  let _ = text.text_insert("body", 0, "A").unwrap()
  let _ = text.text_delete("body", 0, 1).unwrap()
  let _ = text.undo().unwrap()
  assert_eq(text.text("body"), "A")
  let _ = text.undo().unwrap()
  assert_eq(text.text("body"), "")
  let _ = text.redo().unwrap()
  assert_eq(text.text("body"), "A")
  let _ = text.redo().unwrap()
  assert_eq(text.text("body"), "")

  let list = @y.Document::new("multi-list-undo").unwrap()
  let _ = list
    .list_insert("items", 0, [@y.Int(1), @y.Int(2), @y.Int(3)])
    .unwrap()
  let _ = list.list_delete("items", 0, 3).unwrap()
  let _ = list.undo().unwrap()
  assert_eq(list.list_values("items"), [@y.Int(1), @y.Int(2), @y.Int(3)])
  let _ = list.undo().unwrap()
  assert_eq(list.list_values("items"), [])
  let _ = list.redo().unwrap()
  assert_eq(list.list_values("items"), [@y.Int(1), @y.Int(2), @y.Int(3)])
  let _ = list.redo().unwrap()
  assert_eq(list.list_values("items"), [])
}

///|
test "mixed three replica offline branches converge under seeded delivery schedules" {
  let seed = @y.Document::new("mixed-seed").unwrap()
  let _ = seed.map_set("shared", "status", @y.String("base")).unwrap()
  let _ = seed
    .list_insert("items", 0, [@y.Int(1), @y.Int(2), @y.Int(3)])
    .unwrap()
  let _ = seed.text_insert("body", 0, "A😀B").unwrap()

  let branch_a = @y.Document::new("offline-a").unwrap()
  let branch_b = @y.Document::new("offline-b").unwrap()
  let branch_c = @y.Document::new("offline-c").unwrap()
  let base_events = seed.events()
  let _ = branch_a.apply_events(base_events).unwrap()
  let _ = branch_b.apply_events(base_events).unwrap()
  let _ = branch_c.apply_events(base_events).unwrap()
  let _ = branch_a
    .transact([
      @y.MapSet("shared", "status", @y.String("a")),
      @y.ListInsert("items", 1, [@y.Int(10)]),
      @y.TextInsert("body", 1, "🙂"),
    ])
    .unwrap()
  let _ = branch_b
    .transact([
      @y.MapSet("shared", "status", @y.String("b")),
      @y.ListDelete("items", 2, 1),
      @y.TextDelete("body", 2, 1),
    ])
    .unwrap()
  let _ = branch_c
    .transact([
      @y.MapSet("shared", "extra", @y.String("c")),
      @y.ListInsert("items", 0, [@y.Int(0)]),
      @y.TextInsert("body", 3, "!"),
    ])
    .unwrap()

  let a_events = branch_a
    .events()
    .filter(event => event.id().replica() == "offline-a")
  let b_events = branch_b
    .events()
    .filter(event => event.id().replica() == "offline-b")
  let c_events = branch_c
    .events()
    .filter(event => event.id().replica() == "offline-c")
  let all_events : Array[@y.Event] = []
  for event in base_events {
    all_events.push(event)
  }
  for event in a_events {
    all_events.push(event)
  }
  for event in b_events {
    all_events.push(event)
  }
  for event in c_events {
    all_events.push(event)
  }

  let reference = @y.Document::new("mixed-reference").unwrap()
  let _ = reference.apply_events(all_events).unwrap()
  let branches = [a_events, b_events, c_events]
  let mut scenario = 0
  for
    order in [[0, 1, 2], [0, 2, 1], [1, 0, 2], [1, 2, 0], [2, 0, 1], [2, 1, 0]] {
    let receiver = @y.Document::new("mixed-receiver-\{scenario}").unwrap()
    let _ = receiver.apply_events(base_events).unwrap()
    for branch_index in order {
      let reversed = reverse_test_events(branches[branch_index])
      let _ = receiver.apply_events(reversed).unwrap()
      let _ = receiver.apply_events(reversed).unwrap()
    }
    assert_eq(receiver.event_counts().1, 0)
    assert_same_projection(receiver, reference)
    scenario += 1
  }

  let relay = @y.Document::new("mixed-relay").unwrap()
  let _ = relay.apply_events(base_events).unwrap()
  for batch in [c_events, a_events, b_events] {
    let _ = relay.apply_events(reverse_test_events(batch)).unwrap()
  }
  let sink = @y.Document::new("mixed-sink").unwrap()
  let _ = sink.apply_events(base_events).unwrap()
  let payload = relay.sync_update(sink.state_vector()).unwrap()
  let _ = sink.apply_sync_update(payload).unwrap()
  assert_same_projection(sink, reference)

  for random_seed in 0..<24 {
    let receiver = @y.Document::new("mixed-random-\{random_seed}").unwrap()
    let shuffled = shuffled_test_events(all_events, random_seed)
    for event in shuffled {
      let _ = receiver.apply_events([event]).unwrap()
      if (event.id().counter() + random_seed) % 3 == 0 {
        let _ = receiver.apply_events([event]).unwrap()
      }
    }
    assert_eq(receiver.event_counts().1, 0)
    assert_same_projection(receiver, reference)
  }
}

///|
test "large unicode sequences and long offline churn compact by history not live size" {
  let builder = StringBuilder::new()
  for _ in 0..<1800 {
    builder.write_string("🙂")
  }
  let long_text = builder.to_string()
  let document = @y.Document::new("large-history").unwrap()
  let _ = document.text_insert("body", 0, long_text).unwrap()
  assert_eq(document.text("body").char_length(), 1800)
  let _ = document.track_peer("offline-peer", document.state_vector()).unwrap()
  for index in 0..<150 {
    let at = document.text("churn").char_length()
    let _ = document.text_insert("churn", at, "é🙂").unwrap()
    let _ = document.text_delete("churn", at, 2).unwrap()
    let key = "deleted-\{index}"
    let _ = document.map_set("keys", key, @y.Int(index)).unwrap()
    let _ = document.map_delete("keys", key).unwrap()
  }
  let before_compaction = document.storage_counts()
  assert_true(before_compaction.0 >= 2400)
  assert_true(
    document.compact("long-history") is Err(@y.InvalidAcknowledgement),
  )
  let _ = document
    .acknowledge_peer("offline-peer", document.state_vector())
    .unwrap()
  let snapshot = document.compact("long-history").unwrap()
  assert_eq(document.text("body").char_length(), 1800)
  assert_eq(document.text("churn"), "")
  assert_eq(snapshot.sequences().length(), 1)
  assert_eq(snapshot.sequences()[0].root(), "body")
  assert_eq(document.storage_counts(), (0, 0, 1800, 0))
  let restored = @y.Document::new("large-restored").unwrap()
  let _ = restored.apply_update(document.full_update().unwrap()).unwrap()
  assert_eq(restored.text("body"), long_text)
  assert_eq(restored.storage_counts(), (0, 0, 1800, 0))
}

///|
test "persistence and provider-neutral sync hooks round trip native updates" {
  let mut saved : Bytes? = None
  let adapter = @y.PersistenceAdapter::new(() => Ok(saved), bytes => {
    saved = Some(bytes)
    Ok(())
  })
  let empty = @y.Document::restore("empty-store", adapter).unwrap()
  assert_eq(empty.text("body"), "")

  let source = @y.Document::new("persist-source").unwrap()
  let _ = source
    .transact([
      @y.MapSet("shared", "count", @y.Int(3)),
      @y.TextInsert("body", 0, "durable"),
    ])
    .unwrap()
  let _ = source.persist(adapter).unwrap()
  let restored = @y.Document::restore("persist-restored", adapter).unwrap()
  assert_eq(restored.map_get("shared", "count"), Some(@y.Int(3)))
  assert_eq(restored.text("body"), "durable")

  let receiver = @y.Document::new("provider-receiver").unwrap()
  let _ = receiver.apply_events(source.events()).unwrap()
  let _ = source.map_set("shared", "count", @y.Int(4)).unwrap()
  let encoded = source.sync_update(receiver.state_vector()).unwrap()
  let _ = receiver.apply_sync_update(encoded).unwrap()
  assert_same_projection(receiver, source)
}
