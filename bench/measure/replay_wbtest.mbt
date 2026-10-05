///|
/// A deliberately simple event-log replay candidate used to compare cold
/// materialization against the production incremental indexes. It stores
/// sequence nodes in ordinary maps, sorts siblings at materialization time,
/// then walks the graph to produce visible values.
priv struct ReplayNode {
  after : @y.NodeId
  lamport : Int
  value : @y.Value
  mut deleted : Bool
}

///|
priv struct ReplayVersion {
  stamp : @y.EventId
  lamport : Int
  value : @y.Value?
  dependencies : @y.StateVector
  is_restore : Bool
}

///|
priv struct ReplayProjection {
  maps : Map[String, Map[String, @y.Value]]
  lists : Map[String, Array[@y.Value]]
  texts : Map[String, String]
  event_count : Int
  sequence_node_count : Int
  tombstone_count : Int
  map_version_count : Int
  replica_count : Int
}

///|
priv struct ReplayCandidate {
  maps : Map[String, Map[String, Array[ReplayVersion]]]
  lists : Map[String, Map[@y.NodeId, ReplayNode]]
  texts : Map[String, Map[@y.NodeId, ReplayNode]]
  seen : Map[@y.EventId, @y.Event]
  vector : Map[String, Int]
  mut sequence_node_count : Int
  mut tombstone_count : Int
  mut map_version_count : Int
}

///|
/// Rebuild a projection from a complete, checkpoint-free event log. The
/// event ordering is derived from Lamport clocks; no production Document
/// integration or sequence index is used in this candidate.
fn replay_materialize(
  events : Array[@y.Event],
) -> Result[ReplayProjection, @y.CrdtError] {
  let ordered = events.copy()
  ordered.sort_by((left, right) => {
    if left.lamport() == right.lamport() {
      replay_compare_event_ids(left.id(), right.id())
    } else if left.lamport() < right.lamport() {
      -1
    } else {
      1
    }
  })
  let candidate : ReplayCandidate = {
    maps: {},
    lists: {},
    texts: {},
    seen: {},
    vector: {},
    sequence_node_count: 0,
    tombstone_count: 0,
    map_version_count: 0,
  }
  for event in ordered {
    if event.dependencies().checkpoint() is Some(_) {
      return Err(@y.PeerBehindCheckpoint)
    }
    match candidate.seen.get(event.id()) {
      Some(existing) =>
        if existing != event {
          return Err(@y.ConflictingDuplicate)
        }
      None => {
        match replay_operation(candidate, event) {
          Err(error) => return Err(error)
          Ok(_) => ()
        }
        candidate.seen[event.id()] = event
        let replica = event.id().replica()
        let counter = event.id().counter()
        if candidate.vector.get(replica).unwrap_or(0) < counter {
          candidate.vector[replica] = counter
        }
      }
    }
  }
  let maps = replay_visible_maps(candidate.maps)
  let lists = replay_visible_sequences(candidate.lists)
  let texts = replay_visible_texts(candidate.texts)
  Ok({
    maps,
    lists,
    texts,
    event_count: candidate.seen.length(),
    sequence_node_count: candidate.sequence_node_count,
    tombstone_count: candidate.tombstone_count,
    map_version_count: candidate.map_version_count,
    replica_count: candidate.vector.length(),
  })
}

///|
fn replay_operation(
  candidate : ReplayCandidate,
  event : @y.Event,
) -> Result[Unit, @y.CrdtError] {
  match event.operation() {
    @y.MapSet(root, key, value) =>
      replay_map_version(candidate, root, key, {
        stamp: event.id(),
        lamport: event.lamport(),
        value: Some(value),
        dependencies: event.dependencies(),
        is_restore: false,
      })
    @y.MapDelete(root, key) =>
      replay_map_version(candidate, root, key, {
        stamp: event.id(),
        lamport: event.lamport(),
        value: None,
        dependencies: event.dependencies(),
        is_restore: false,
      })
    @y.MapRestore(root, key, target, value) =>
      replay_map_restore(candidate, root, key, event, target, value)
    @y.SequenceInsert(root, kind, after, value) => {
      let id = @y.EventNode(event.id())
      let nodes = match kind {
        @y.List => replay_list_for(candidate, root)
        @y.Text => replay_text_for(candidate, root)
      }
      match nodes.get(id) {
        Some(_) => Err(@y.ConflictingDuplicate)
        None => {
          if after is @y.EventNode(anchor) && !candidate.seen.contains(anchor) {
            return Err(@y.MissingAnchor)
          }
          nodes[id] = {
            after,
            lamport: event.lamport(),
            value,
            deleted: false,
          }
          candidate.sequence_node_count += 1
          Ok(())
        }
      }
    }
    @y.SequenceDelete(root, kind, target) => {
      let nodes = match kind {
        @y.List => replay_list_for(candidate, root)
        @y.Text => replay_text_for(candidate, root)
      }
      match nodes.get(target) {
        None => Err(@y.MissingAnchor)
        Some(node) => {
          if !node.deleted {
            node.deleted = true
            candidate.tombstone_count += 1
          }
          Ok(())
        }
      }
    }
  }
}

///|
fn replay_map_restore(
  candidate : ReplayCandidate,
  root : String,
  key : String,
  event : @y.Event,
  target : @y.EventId,
  value : @y.Value?,
) -> Result[Unit, @y.CrdtError] {
  let versions = replay_map_key(candidate, root, key)
  let visible = versions.filter(version => {
    event.dependencies().includes(version.stamp)
  })
  match replay_greatest_version(visible) {
    Some(current) if current.stamp == target =>
      replay_map_version(candidate, root, key, {
        stamp: event.id(),
        lamport: event.lamport(),
        value,
        dependencies: event.dependencies(),
        is_restore: true,
      })
    _ => Ok(())
  }
}

///|
fn replay_map_version(
  candidate : ReplayCandidate,
  root : String,
  key : String,
  version : ReplayVersion,
) -> Result[Unit, @y.CrdtError] {
  let versions = replay_map_key(candidate, root, key)
  versions.push(version)
  candidate.map_version_count += 1
  Ok(())
}

///|
fn replay_map_key(
  candidate : ReplayCandidate,
  root : String,
  key : String,
) -> Array[ReplayVersion] {
  let registers = match candidate.maps.get(root) {
    Some(registers) => registers
    None => {
      let registers : Map[String, Array[ReplayVersion]] = Map([])
      candidate.maps[root] = registers
      registers
    }
  }
  match registers.get(key) {
    Some(versions) => versions
    None => {
      let versions : Array[ReplayVersion] = []
      registers[key] = versions
      versions
    }
  }
}

///|
fn replay_list_for(
  candidate : ReplayCandidate,
  root : String,
) -> Map[@y.NodeId, ReplayNode] {
  match candidate.lists.get(root) {
    Some(nodes) => nodes
    None => {
      let nodes : Map[@y.NodeId, ReplayNode] = Map([])
      candidate.lists[root] = nodes
      nodes
    }
  }
}

///|
fn replay_text_for(
  candidate : ReplayCandidate,
  root : String,
) -> Map[@y.NodeId, ReplayNode] {
  match candidate.texts.get(root) {
    Some(nodes) => nodes
    None => {
      let nodes : Map[@y.NodeId, ReplayNode] = Map([])
      candidate.texts[root] = nodes
      nodes
    }
  }
}

///|
fn replay_greatest_version(versions : Array[ReplayVersion]) -> ReplayVersion? {
  if versions.is_empty() {
    return None
  }
  let mut best = versions[0]
  for version in versions[1:] {
    if replay_version_wins(version, best) {
      best = version
    }
  }
  Some(best)
}

///|
fn replay_version_wins(
  candidate : ReplayVersion,
  current : ReplayVersion,
) -> Bool {
  if candidate.lamport != current.lamport {
    candidate.lamport > current.lamport
  } else {
    replay_compare_event_ids(candidate.stamp, current.stamp) > 0
  }
}

///|
fn replay_compare_event_ids(left : @y.EventId, right : @y.EventId) -> Int {
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
fn replay_visible_maps(
  histories : Map[String, Map[String, Array[ReplayVersion]]],
) -> Map[String, Map[String, @y.Value]] {
  let output : Map[String, Map[String, @y.Value]] = Map([])
  for root, keys in histories {
    let visible : Map[String, @y.Value] = Map([])
    for key, versions in keys {
      let applicable = versions.filter(version => {
        if !version.is_restore {
          true
        } else {
          !versions.any(other => {
            if other.stamp == version.stamp {
              false
            } else {
              !version.dependencies.includes(other.stamp) &&
              !other.dependencies.includes(version.stamp)
            }
          })
        }
      })
      match replay_greatest_version(applicable) {
        None => ()
        Some(version) =>
          match version.value {
            None => ()
            Some(value) => visible[key] = value
          }
      }
    }
    if !visible.is_empty() {
      output[root] = visible
    }
  }
  output
}

///|
fn replay_visible_sequences(
  roots : Map[String, Map[@y.NodeId, ReplayNode]],
) -> Map[String, Array[@y.Value]] {
  let output : Map[String, Array[@y.Value]] = Map([])
  for root, nodes in roots {
    output[root] = replay_ordered_values(nodes)
  }
  output
}

///|
fn replay_visible_texts(
  roots : Map[String, Map[@y.NodeId, ReplayNode]],
) -> Map[String, String] {
  let output : Map[String, String] = Map([])
  for root, nodes in roots {
    let text = StringBuilder()
    for value in replay_ordered_values(nodes) {
      match value {
        @y.String(character) => text.write_string(character)
        _ => ()
      }
    }
    output[root] = text.to_string()
  }
  output
}

///|
fn replay_ordered_values(nodes : Map[@y.NodeId, ReplayNode]) -> Array[@y.Value] {
  let children : Map[@y.NodeId, Array[@y.NodeId]] = Map([])
  for id, node in nodes {
    let siblings = match children.get(node.after) {
      Some(siblings) => siblings
      None => {
        let siblings : Array[@y.NodeId] = []
        children[node.after] = siblings
        siblings
      }
    }
    siblings.push(id)
  }
  for _, siblings in children {
    siblings.sort_by((left, right) => {
      let left_node = nodes[left]
      let right_node = nodes[right]
      if left_node.lamport == right_node.lamport {
        @y.NodeId::compare(right, left)
      } else if left_node.lamport > right_node.lamport {
        -1
      } else {
        1
      }
    })
  }
  let stack : Array[@y.NodeId] = []
  replay_push_reversed(stack, children.get(@y.Root).unwrap_or([]))
  let output : Array[@y.Value] = []
  while !stack.is_empty() {
    match stack.pop() {
      None => ()
      Some(id) =>
        match nodes.get(id) {
          None => ()
          Some(node) => {
            if !node.deleted {
              output.push(node.value)
            }
            replay_push_reversed(stack, children.get(id).unwrap_or([]))
          }
        }
    }
  }
  output
}

///|
fn replay_push_reversed(
  stack : Array[@y.NodeId],
  nodes : Array[@y.NodeId],
) -> Unit {
  for index in 0..<nodes.length() {
    stack.push(nodes[nodes.length() - index - 1])
  }
}

///|
fn production_matches_replay(
  document : @y.Document,
  projection : ReplayProjection,
) -> Bool {
  let map_roots : Map[String, Unit] = Map([])
  let list_roots : Map[String, Unit] = Map([])
  let text_roots : Map[String, Unit] = Map([])
  for event in document.events() {
    match event.operation() {
      @y.MapSet(root, _, _)
      | @y.MapDelete(root, _)
      | @y.MapRestore(root, _, _, _) => map_roots[root] = ()
      @y.SequenceInsert(root, @y.List, _, _)
      | @y.SequenceDelete(root, @y.List, _) => list_roots[root] = ()
      @y.SequenceInsert(root, @y.Text, _, _)
      | @y.SequenceDelete(root, @y.Text, _) => text_roots[root] = ()
    }
  }
  for root in map_roots.keys() {
    if document.map_snapshot(root) !=
      projection.maps.get(root).unwrap_or(Map([])) {
      return false
    }
  }
  for root in list_roots.keys() {
    if document.list_values(root) != projection.lists.get(root).unwrap_or([]) {
      return false
    }
  }
  for root in text_roots.keys() {
    if document.text(root) != projection.texts.get(root).unwrap_or("") {
      return false
    }
  }
  true
}
