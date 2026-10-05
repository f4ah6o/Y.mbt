///|
fn[T] must_ok(result : Result[T, @y.CrdtError]) -> T {
  match result {
    Ok(value) => value
    Err(_) => abort("benchmark setup failed")
  }
}

///|
fn[T] must_unit(result : Result[T, @y.CrdtError]) -> Unit {
  match result {
    Ok(_) => ()
    Err(_) => abort("benchmark setup failed")
  }
}

///|
fn new_document(replica : String) -> @y.Document {
  must_ok(@y.Document::new(replica))
}

///|
fn repeat_scalar(scalar : Char, count : Int) -> String {
  let output = StringBuilder()
  for _ in 0..<count {
    output.write_char(scalar)
  }
  output.to_string()
}

///|
fn compare_benchmark_event_ids(left : @y.EventId, right : @y.EventId) -> Int {
  let replica_order = left.replica().compare(right.replica())
  if replica_order != 0 {
    replica_order
  } else if left.counter() < right.counter() {
    -1
  } else if left.counter() > right.counter() {
    1
  } else {
    0
  }
}

///|
/// Produce a deterministic offline workload: two replicas start from the
/// same seed, edit text and lists independently, and race on one map key.
fn seed_events(seed_size : Int) -> Array[@y.Event] {
  let seed = new_document("seed")
  let scenario = @workload.offline_branch_scenario(seed_size, 1)
  apply_workload_edits(seed, scenario.seed)
  seed.events()
}

///|
fn long_offline_branch_events(
  seed_size : Int,
  edits_per_branch : Int,
) -> Array[@y.Event] {
  let scenario = @workload.offline_branch_scenario(seed_size, edits_per_branch)
  let seed = new_document("seed")
  apply_workload_edits(seed, scenario.seed)
  let prefix = seed.events()

  let left = new_document("left")
  must_unit(left.apply_events(prefix))
  apply_workload_edits(left, scenario.left)

  let right = new_document("right")
  must_unit(right.apply_events(prefix))
  apply_workload_edits(right, scenario.right)

  let by_id : Map[@y.EventId, @y.Event] = Map([])
  for event in left.events() {
    by_id[event.id()] = event
  }
  for event in right.events() {
    by_id[event.id()] = event
  }
  let events = by_id.values().to_array()
  events.sort_by((left_event, right_event) => {
    compare_benchmark_event_ids(right_event.id(), left_event.id())
  })
  events
}

///|
fn apply_workload_edits(
  document : @y.Document,
  edits : Array[@workload.Edit],
) -> Unit {
  for edit in edits {
    match edit {
      @workload.TextInsert(index, text) =>
        must_unit(document.text_insert("body", index, text))
      @workload.TextDelete(index, length) =>
        must_unit(document.text_delete("body", index, length))
      @workload.ListInsert(index, values) =>
        must_unit(
          document.list_insert(
            "items",
            index,
            values.map(value => @y.Int(value)),
          ),
        )
      @workload.MapSet(key, value) =>
        match value {
          @workload.Text(text) =>
            must_unit(document.map_set("meta", key, @y.String(text)))
          @workload.Number(number) =>
            must_unit(document.map_set("meta", key, @y.Int(number)))
        }
      @workload.MapDelete(key) => must_unit(document.map_delete("meta", key))
    }
  }
}

///|
test "event-log replay matches indexed materialization for offline branches" {
  let events = long_offline_branch_events(24, 20)
  let indexed = new_document("receiver")
  must_unit(indexed.apply_events(events))
  let replayed = must_ok(replay_materialize(events))
  if !production_matches_replay(indexed, replayed) {
    abort("indexed merge and event replay projections differ")
  }
  assert_eq(replayed.event_count, events.length())
  assert_eq(replayed.replica_count, indexed.state_vector().entries().length())
  assert_true(replayed.sequence_node_count > 0)
  assert_true(replayed.tombstone_count > 0)
  assert_true(replayed.map_version_count >= 6)
  assert_eq(indexed.event_counts().1, 0)
}

///|
test "shared offline workload retains its documented event profiles" {
  assert_eq(long_offline_branch_events(24, 20).length(), 85)
  assert_eq(long_offline_branch_events(64, 48).length(), 193)
  assert_eq(long_offline_branch_events(128, 96).length(), 373)
}

///|
test "bench local insert and delete on a 64-scalar text" (it : @bench.T) {
  let initial = repeat_scalar('x', 64)
  it.bench(
    fn() {
      let document = new_document("local-insert")
      must_unit(document.text_insert("body", 0, initial))
      must_unit(document.text_insert("body", 32, "🙂"))
      it.keep(document.text("body").char_length())
    },
    name="construct + insert into 64-scalar text",
    count=5,
  )
  it.bench(
    fn() {
      let document = new_document("local-delete")
      must_unit(document.text_insert("body", 0, initial))
      must_unit(document.text_delete("body", 32, 1))
      it.keep(document.text("body").char_length())
    },
    name="construct + delete from 64-scalar text",
    count=5,
  )
}

///|
test "bench indexed merge against independent event-log replay" (it : @bench.T) {
  benchmark_offline_case(it, 24, 20)
  benchmark_offline_case(it, 64, 48)
  benchmark_offline_case(it, 128, 96)
}

///|
test "bench fixed live document with growing map history" (it : @bench.T) {
  benchmark_fixed_history_case(it, 0)
  benchmark_fixed_history_case(it, 128)
  benchmark_fixed_history_case(it, 512)
  benchmark_fixed_history_case(it, 2048)
}

///|
fn benchmark_fixed_history_case(
  it : @bench.T,
  repeated_same_value_edits : Int,
) -> Unit {
  let profiled = fixed_live_history_document(
    "history-profile", repeated_same_value_edits,
  )
  let before = profiled.storage_counts()
  let full_update_bytes = must_ok(must_ok(profiled.full_update()).encode()).length()
  let compacted = fixed_live_history_document(
    "compact-profile", repeated_same_value_edits,
  )
  let checkpoint = must_ok(compacted.compact("fixed-live-profile"))
  let checkpoint_id_length = checkpoint.id().length()
  let after = compacted.storage_counts()
  let checkpoint_update_bytes = must_ok(
    must_ok(compacted.full_update()).encode(),
  ).length()
  let profile = "same-value-edits=\{repeated_same_value_edits}, live-text-scalars=\{profiled.text("body").char_length()}, live-list-items=\{profiled.list_values("items").length()}, live-map-keys=\{profiled.map_snapshot("meta").length()}, history-events=\{before.0}, pending=\{before.1}, sequence-nodes=\{before.2}, map-registers=\{before.3}, full-update-bytes=\{full_update_bytes}, compacted-events=\{after.0}, compacted-sequence-nodes=\{after.2}, compacted-map-registers=\{after.3}, checkpoint-id-length=\{checkpoint_id_length}, checkpoint-update-bytes=\{checkpoint_update_bytes}"

  it.bench(
    fn() {
      let document = fixed_live_history_document(
        "history-build", repeated_same_value_edits,
      )
      it.keep(document.text("body").char_length())
      it.keep(document.list_values("items").length())
      it.keep(document.map_snapshot("meta").length())
      it.keep(document.storage_counts().0)
    },
    name="construct fixed live document + same-value map edits, " + profile,
    count=5,
  )
  it.bench(
    fn() {
      let document = fixed_live_history_document(
        "history-compact", repeated_same_value_edits,
      )
      let current = must_ok(document.compact("fixed-live-benchmark"))
      it.keep(current.id().length() + document.storage_counts().0)
    },
    name="construct fixed live history + compact, " + profile,
    count=5,
  )
}

///|
fn fixed_live_history_document(
  replica : String,
  repeated_same_value_edits : Int,
) -> @y.Document {
  let document = new_document(replica)
  must_unit(document.text_insert("body", 0, repeat_scalar('x', 32)))
  must_unit(
    document.list_insert("items", 0, [
      @y.Int(1),
      @y.Int(2),
      @y.Int(3),
      @y.Int(4),
    ]),
  )
  must_unit(document.map_set("meta", "stable", @y.String("unchanged")))
  must_unit(document.map_set("meta", "revision", @y.Int(1)))
  let edits : Array[@y.Edit] = []
  for _ in 0..<repeated_same_value_edits {
    edits.push(@y.MapSet("meta", "revision", @y.Int(1)))
  }
  if !edits.is_empty() {
    must_unit(document.transact(edits))
  }
  document
}

///|
fn benchmark_offline_case(
  it : @bench.T,
  seed_size : Int,
  edits_per_branch : Int,
) -> Unit {
  let events = long_offline_branch_events(seed_size, edits_per_branch)
  let indexed = new_document("correctness")
  must_unit(indexed.apply_events(events))
  let replayed = must_ok(replay_materialize(events))
  if !production_matches_replay(indexed, replayed) {
    abort("indexed merge and event replay projections differ")
  }

  let peer = new_document("stale-peer")
  must_unit(peer.apply_events(seed_events(seed_size)))
  let counts = indexed.storage_counts()
  let history_events = counts.0
  let sequence_nodes = counts.2
  let map_registers = counts.3
  let visible_text = indexed.text("body").char_length()
  let visible_list = indexed.list_values("items").length()
  let visible_map_keys = indexed.map_snapshot("meta").length()
  let tombstones = replayed.tombstone_count
  let replica_count = indexed.state_vector().entries().length()
  let full_update_bytes = must_ok(must_ok(indexed.full_update()).encode()).length()
  let incremental_update_bytes = must_ok(
    must_ok(indexed.update_since(peer.state_vector())).encode(),
  ).length()
  let compacted = new_document("compact-profile")
  must_unit(compacted.apply_events(events))
  let checkpoint = must_ok(compacted.compact("benchmark-profile"))
  let checkpoint_id_length = checkpoint.id().length()
  let post_compaction = compacted.storage_counts()
  let checkpoint_update_bytes = must_ok(
    must_ok(compacted.full_update()).encode(),
  ).length()
  let profile = "visible-text=\{visible_text}, visible-list=\{visible_list}, visible-map-keys=\{visible_map_keys}, events=\{history_events}, sequence-nodes=\{sequence_nodes}, tombstones=\{tombstones}, map-registers=\{map_registers}, replicas=\{replica_count}, full-update-bytes=\{full_update_bytes}, incremental-update-bytes=\{incremental_update_bytes}, compacted-events=\{post_compaction.0}, compacted-pending=\{post_compaction.1}, compacted-sequence-nodes=\{post_compaction.2}, compacted-map-registers=\{post_compaction.3}, checkpoint-id-length=\{checkpoint_id_length}, checkpoint-update-bytes=\{checkpoint_update_bytes}"

  it.bench(
    fn() {
      let receiver = new_document("cold-indexed")
      must_unit(receiver.apply_events(events))
      it.keep(receiver.text("body").char_length())
      it.keep(receiver.list_values("items").length())
      it.keep(receiver.map_snapshot("meta").length())
    },
    name="cold indexed merge, " + profile,
    count=5,
  )
  it.bench(
    fn() {
      let projection = must_ok(replay_materialize(events))
      it.keep(projection.texts.get("body").unwrap_or("").char_length())
      it.keep(projection.lists.get("items").unwrap_or([]).length())
      it.keep(projection.maps.get("meta").map_or(0, values => values.length()))
    },
    name="cold replay materialization, " + profile,
    count=5,
  )
  it.bench(
    fn() { it.keep(indexed.state_vector().metadata_entries().length()) },
    name="state-vector metadata scan, " + profile,
    count=10,
  )
  it.bench(
    fn() {
      let update = must_ok(indexed.update_since(peer.state_vector()))
      it.keep(must_ok(update.encode()).length())
    },
    name="incremental diff + encode, " + profile,
    count=5,
  )
  it.bench(
    fn() {
      let update = must_ok(indexed.full_update())
      it.keep(must_ok(update.encode()).length())
    },
    name="full update encode, " + profile,
    count=5,
  )
  it.bench(
    fn() {
      let receiver = new_document("compact")
      must_unit(receiver.apply_events(events))
      let compacted_checkpoint = must_ok(
        receiver.compact("benchmark-checkpoint"),
      )
      let counts = receiver.storage_counts()
      it.keep(
        compacted_checkpoint.id().length() + counts.0 + counts.2 + counts.3,
      )
    },
    name="construct + merge + compact, " + profile,
    count=5,
  )
}
