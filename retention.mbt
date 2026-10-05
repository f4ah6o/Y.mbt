///|
/// Register a peer's last confirmed state. An old checkpoint epoch may be
/// registered so it can block compaction until the peer receives a snapshot.
pub fn Document::track_peer(
  self : Document,
  peer : String,
  acknowledged : StateVector,
) -> Result[Unit, CrdtError] {
  if !utf16_is_well_formed(peer) {
    return Err(InvalidUnicode)
  }
  match validate_update_string(peer) {
    Err(error) => return Err(error)
    Ok(_) => ()
  }
  if peer.is_empty() || peer.contains("\u{0}") {
    return Err(InvalidReplicaId)
  }
  self.peer_acks[peer] = clone_vector(acknowledged)
  Ok(())
}

///|
/// Record a peer acknowledgement after verifying its exact event stamps.
pub fn Document::acknowledge_peer(
  self : Document,
  peer : String,
  acknowledged : StateVector,
) -> Result[Unit, CrdtError] {
  let previous = match self.peer_acks.get(peer) {
    None => return Err(InvalidAcknowledgement)
    Some(previous) => previous
  }
  if !state_vector_is_known(self, acknowledged) {
    return Err(InvalidAcknowledgement)
  }
  match previous.checkpoint {
    Some(id) if acknowledged.checkpoint != Some(id) => ()
    None if acknowledged.checkpoint is Some(_) => ()
    _ =>
      if !acknowledged.dominates(previous) {
        return Err(InvalidAcknowledgement)
      }
  }
  self.peer_acks[peer] = clone_vector(acknowledged)
  Ok(())
}

///|
/// Explicitly expire a peer lease so it no longer blocks compaction.
pub fn Document::expire_peer(self : Document, peer : String) -> Bool {
  if self.peer_acks.contains(peer) {
    self.peer_acks.remove(peer)
    true
  } else {
    false
  }
}

///|
/// Build and install a compacted checkpoint after all active peers have
/// acknowledged the current frontier. The supplied identifier starts a new
/// retention epoch; old relative positions expire at this boundary. Callers
/// must supply an identifier that is globally unique and never reused across
/// replicas or persisted/restored lifetimes. The document retains only the
/// active epoch identifier, so it cannot detect reuse of an older identifier.
pub fn Document::compact(
  self : Document,
  checkpoint_id : String,
) -> Result[CheckpointSnapshot, CrdtError] {
  if checkpoint_id.is_empty() || checkpoint_id.contains("\u{0}") {
    return Err(MalformedUpdate)
  }
  if self.pending.length() > 0 {
    return Err(CannotCompactPending)
  }
  match self.checkpoint {
    Some(checkpoint) if checkpoint.id == checkpoint_id =>
      return Err(CheckpointConflict)
    _ => ()
  }
  let frontier = self.state_vector()
  if !active_peers_acknowledge(self, frontier) {
    return Err(InvalidAcknowledgement)
  }
  let snapshot = match snapshot_from_document(self, checkpoint_id) {
    Err(error) => return Err(error)
    Ok(snapshot) => snapshot
  }
  let staged = clone_document(self)
  match install_checkpoint_snapshot(staged, snapshot) {
    Err(error) => return Err(error)
    Ok(_) => ()
  }
  commit_replica_state(self, staged)
  Ok(clone_checkpoint_snapshot(snapshot))
}

///|
/// Return a self-contained native update for a fresh replica.
pub fn Document::full_update(self : Document) -> Result[Update, CrdtError] {
  let checkpoint = match self.checkpoint {
    None => None
    Some(_) =>
      match current_checkpoint_snapshot(self) {
        Err(error) => return Err(error)
        Ok(snapshot) => Some(snapshot)
      }
  }
  Update::new(checkpoint, self.events())
}

///|
/// Return the events missing from a peer, including a safe snapshot when the
/// peer has not entered the current checkpoint epoch.
pub fn Document::update_since(
  self : Document,
  peer : StateVector,
) -> Result[Update, CrdtError] {
  let current_frontier = self.state_vector()
  if peer.checkpoint == current_frontier.checkpoint {
    if !state_vector_is_known(self, peer) {
      match self.checkpoint {
        Some(checkpoint) if !peer.dominates(checkpoint.frontier) =>
          return Err(PeerBehindCheckpoint)
        _ => return Err(InvalidDependency)
      }
    }
  } else {
    match self.checkpoint {
      None => return Err(PeerBehindCheckpoint)
      Some(_) if !current_frontier.dominates(peer) =>
        return Err(CheckpointConflict)
      Some(_) => ()
    }
  }
  let snapshot = match self.checkpoint {
    None => {
      if peer.checkpoint is Some(_) {
        return Err(PeerBehindCheckpoint)
      }
      None
    }
    Some(checkpoint) =>
      if peer.checkpoint == Some(checkpoint.id) {
        if !state_vector_is_known(self, peer) ||
          !peer.dominates(checkpoint.frontier) {
          return Err(PeerBehindCheckpoint)
        }
        None
      } else {
        match current_checkpoint_snapshot(self) {
          Err(error) => return Err(error)
          Ok(snapshot) => Some(snapshot)
        }
      }
  }
  let events = self.integrated
    .values()
    .to_array()
    .filter(event => {
      match snapshot {
        Some(checkpoint) =>
          event.id.counter() > checkpoint.frontier.counter(event.id.replica())
        None => event.id.counter() > peer.counter(event.id.replica())
      }
    })
  sort_events(events)
  Update::new(snapshot, events)
}

///|
/// Apply a checkpoint and its events as one all-or-nothing state transition.
pub fn Document::apply_update(
  self : Document,
  update : Update,
) -> Result[ChangeSet, CrdtError] {
  let before = clone_document(self)
  let staged = clone_document(self)
  match update.checkpoint {
    None => ()
    Some(snapshot) =>
      match install_checkpoint_snapshot(staged, snapshot) {
        Err(error) => return Err(error)
        Ok(_) => ()
      }
  }
  let applied = match apply_events_to_staged(staged, update.events) {
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
/// Report retained event, pending event, sequence-node, and map-register
/// counts for diagnostics and reproducible memory-growth benchmarks.
pub fn Document::storage_counts(self : Document) -> (Int, Int, Int, Int) {
  let mut sequence_nodes = 0
  for _, sequence in self.lists {
    sequence_nodes += sequence.nodes.length()
  }
  for _, sequence in self.texts {
    sequence_nodes += sequence.nodes.length()
  }
  let mut map_registers = 0
  for _, registers in self.maps {
    map_registers += registers.length()
  }
  (self.history.length(), self.pending.length(), sequence_nodes, map_registers)
}

///|
fn snapshot_from_document(
  document : Document,
  checkpoint_id : String,
) -> Result[CheckpointSnapshot, CrdtError] {
  let maps : Array[MapSnapshotEntry] = []
  let roots = document.maps.keys().to_array()
  roots.sort_by((left, right) => left.compare(right))
  for root in roots {
    let registers = document.maps[root]
    let keys = registers.keys().to_array()
    keys.sort_by((left, right) => left.compare(right))
    for key in keys {
      let register = registers[key]
      match register.value {
        None => ()
        Some(_) =>
          match
            MapSnapshotEntry::new(
              root,
              key,
              register.value,
              register.stamp,
              register.lamport,
            ) {
            Err(error) => return Err(error)
            Ok(entry) => maps.push(entry)
          }
      }
    }
  }
  let sequences : Array[SequenceSnapshot] = []
  let list_roots = document.lists.keys().to_array()
  list_roots.sort_by((left, right) => left.compare(right))
  for root in list_roots {
    let values = sequence_visible_values(document.lists[root])
    if !values.is_empty() {
      match SequenceSnapshot::new(root, List, values) {
        Err(error) => return Err(error)
        Ok(sequence) => sequences.push(sequence)
      }
    }
  }
  let text_roots = document.texts.keys().to_array()
  text_roots.sort_by((left, right) => left.compare(right))
  for root in text_roots {
    let values = sequence_visible_values(document.texts[root])
    if !values.is_empty() {
      match SequenceSnapshot::new(root, Text, values) {
        Err(error) => return Err(error)
        Ok(sequence) => sequences.push(sequence)
      }
    }
  }
  let frontier = vector_set_checkpoint(
    document.state_vector(),
    Some(checkpoint_id),
  )
  CheckpointSnapshot::new(checkpoint_id, frontier, maps, sequences)
}

///|
fn current_checkpoint_snapshot(
  document : Document,
) -> Result[CheckpointSnapshot, CrdtError] {
  match document.checkpoint {
    None => Err(CheckpointConflict)
    Some(checkpoint) => snapshot_from_checkpoint(checkpoint)
  }
}

///|
fn snapshot_from_checkpoint(
  checkpoint : Checkpoint,
) -> Result[CheckpointSnapshot, CrdtError] {
  let maps : Array[MapSnapshotEntry] = []
  let roots = checkpoint.maps.keys().to_array()
  roots.sort_by((left, right) => left.compare(right))
  for root in roots {
    let registers = checkpoint.maps[root]
    let keys = registers.keys().to_array()
    keys.sort_by((left, right) => left.compare(right))
    for key in keys {
      let register = registers[key]
      match register.value {
        None => ()
        Some(_) =>
          match
            MapSnapshotEntry::new(
              root,
              key,
              register.value,
              register.stamp,
              register.lamport,
            ) {
            Err(error) => return Err(error)
            Ok(entry) => maps.push(entry)
          }
      }
    }
  }
  let sequences : Array[SequenceSnapshot] = []
  let list_roots = checkpoint.lists.keys().to_array()
  list_roots.sort_by((left, right) => left.compare(right))
  for root in list_roots {
    let values = sequence_visible_values(checkpoint.lists[root])
    if !values.is_empty() {
      match SequenceSnapshot::new(root, List, values) {
        Err(error) => return Err(error)
        Ok(sequence) => sequences.push(sequence)
      }
    }
  }
  let text_roots = checkpoint.texts.keys().to_array()
  text_roots.sort_by((left, right) => left.compare(right))
  for root in text_roots {
    let values = sequence_visible_values(checkpoint.texts[root])
    if !values.is_empty() {
      match SequenceSnapshot::new(root, Text, values) {
        Err(error) => return Err(error)
        Ok(sequence) => sequences.push(sequence)
      }
    }
  }
  CheckpointSnapshot::new(checkpoint.id, checkpoint.frontier, maps, sequences)
}

///|
fn state_vector_is_known(document : Document, vector : StateVector) -> Bool {
  let local = document.state_vector()
  if vector.checkpoint != local.checkpoint ||
    !local.dominates(vector) ||
    !causal_vector_is_closed(document, vector) {
    return false
  }
  for (replica, counter, timestamp) in vector.metadata_entries() {
    if known_lamport(document, replica, counter) != Some(timestamp) {
      return false
    }
  }
  true
}

///|
fn install_checkpoint_snapshot(
  document : Document,
  snapshot : CheckpointSnapshot,
) -> Result[Unit, CrdtError] {
  if snapshot.frontier.checkpoint != Some(snapshot.id) {
    return Err(MalformedUpdate)
  }
  match
    CheckpointSnapshot::new(
      snapshot.id,
      snapshot.frontier,
      snapshot.maps,
      snapshot.sequences,
    ) {
    Err(error) => return Err(error)
    Ok(_) => ()
  }
  match document.checkpoint {
    Some(current) if current.id == snapshot.id =>
      if checkpoint_matches_snapshot(current, snapshot) {
        return Ok(())
      } else {
        return Err(CheckpointConflict)
      }
    _ => ()
  }
  if !active_peers_acknowledge(document, document.state_vector()) {
    return Err(InvalidAcknowledgement)
  }
  match validate_checkpoint_frontier_extension(document, snapshot) {
    Err(error) => return Err(error)
    Ok(_) => ()
  }
  if document.pending.length() > 0 ||
    !snapshot.frontier.dominates(document.state_vector()) {
    return Err(CheckpointConflict)
  }
  let checkpoint = checkpoint_from_snapshot(snapshot)
  document.clock = clone_clock_map(snapshot.frontier.clocks)
  document.lamports = clone_clock_map(snapshot.frontier.lamports)
  document.maps = clone_maps(checkpoint.maps)
  document.lists = clone_sequence_roots(checkpoint.lists)
  document.texts = clone_sequence_roots(checkpoint.texts)
  document.integrated = {}
  document.pending = {}
  document.rejected_pending = {}
  document.history = []
  document.undo = []
  document.redo = []
  document.checkpoint = Some(checkpoint)
  Ok(())
}

///| A new checkpoint may discard the locally retained event history only

///| after every active peer has acknowledged the local frontier. The check is

///|
/// intentionally skipped for replay of an already-installed checkpoint.
fn active_peers_acknowledge(
  document : Document,
  frontier : StateVector,
) -> Bool {
  for _, acknowledgement in document.peer_acks {
    if !state_vector_is_known(document, acknowledgement) ||
      acknowledgement.checkpoint != frontier.checkpoint ||
      !acknowledgement.dominates(frontier) {
      return false
    }
  }
  true
}

///| A snapshot may advance a local frontier, but it cannot rewrite a known

///|
/// contiguous event's Lamport identity or a retained map event's payload.
fn validate_checkpoint_frontier_extension(
  document : Document,
  snapshot : CheckpointSnapshot,
) -> Result[Unit, CrdtError] {
  let known_frontier = document.state_vector()
  if !snapshot.frontier.dominates(known_frontier) {
    return Err(CheckpointConflict)
  }
  for (replica, counter, timestamp) in known_frontier.metadata_entries() {
    let incoming_counter = snapshot.frontier.counter(replica)
    let incoming_timestamp = snapshot.frontier.lamport(replica)
    if incoming_counter == counter && incoming_timestamp != timestamp {
      return Err(InvalidDependency)
    }
    if incoming_counter > counter {
      if incoming_timestamp < timestamp ||
        incoming_timestamp - timestamp < incoming_counter - counter {
        return Err(InvalidDependency)
      }
    }
  }
  if snapshot.frontier.metadata_entries() == known_frontier.metadata_entries() {
    match validate_exact_checkpoint_projection(document, snapshot) {
      Err(error) => return Err(error)
      Ok(_) => ()
    }
  }
  for entry in snapshot.maps {
    match validate_checkpoint_map_entry(document, known_frontier, entry) {
      Err(error) => return Err(error)
      Ok(_) => ()
    }
  }
  Ok(())
}

///| Verify payload identity for a map version already known to this replica.

///| Unknown versions beyond the local frontier are supplied by the incoming

///|
/// checkpoint; retained versions and the compacted baseline remain immutable.
fn validate_checkpoint_map_entry(
  document : Document,
  known_frontier : StateVector,
  entry : MapSnapshotEntry,
) -> Result[Unit, CrdtError] {
  match document.integrated.get(entry.stamp) {
    Some(event) => {
      if event.lamport != entry.lamport {
        return Err(InvalidDependency)
      }
      match event.operation {
        MapSet(root, key, value) if root == entry.root && key == entry.key =>
          if entry.value != Some(value) {
            return Err(InvalidDependency)
          }
        MapRestore(root, key, _, value) if root == entry.root &&
          key == entry.key =>
          if entry.value != value ||
            !map_version_is_applicable(
              document,
              entry.root,
              entry.key,
              entry.stamp,
            ) {
            return Err(InvalidDependency)
          }
        _ => return Err(InvalidDependency)
      }
    }
    None =>
      match document.checkpoint {
        Some(checkpoint) if entry.stamp.counter() <=
          checkpoint.frontier.counter(entry.stamp.replica()) =>
          match checkpoint.maps.get(entry.root) {
            Some(registers) =>
              match registers.get(entry.key) {
                Some(register) if register.stamp == entry.stamp =>
                  if register.lamport != entry.lamport ||
                    register.value != entry.value {
                    return Err(InvalidDependency)
                  }
                _ => return Err(CheckpointConflict)
              }
            None => return Err(CheckpointConflict)
          }
        _ =>
          if entry.stamp.counter() <=
            known_frontier.counter(entry.stamp.replica()) {
            return Err(InvalidDependency)
          }
      }
  }

  // A live map value in the installed checkpoint is an unconditional floor
  // version. A new checkpoint cannot claim an older live stamp for that key.
  match document.checkpoint {
    Some(checkpoint) =>
      match checkpoint.maps.get(entry.root) {
        Some(registers) =>
          match registers.get(entry.key) {
            Some(register) if register.lamport > entry.lamport ||
              (
                register.lamport == entry.lamport &&
                EventId::compare(register.stamp, entry.stamp) > 0
              ) => return Err(CheckpointConflict)
            _ => ()
          }
        None => ()
      }
    None => ()
  }

  // An unconditional write is never suppressed by another version. Once a
  // known later write sorts after this stamp, the checkpoint cannot claim the
  // older event as the visible register value.
  for event in document.integrated.values() {
    match event.operation {
      MapSet(root, key, _) | MapDelete(root, key) if root == entry.root &&
        key == entry.key =>
        if event.lamport > entry.lamport ||
          (
            event.lamport == entry.lamport &&
            EventId::compare(event.id, entry.stamp) > 0
          ) {
          return Err(CheckpointConflict)
        }
      _ => ()
    }
  }

  // For a snapshot that extends this replica's frontier, the value must also
  // be compatible with any retained register that is already the known
  // winner. A later remote event may change the projection, but it cannot
  // rewrite a retained event's own value.
  match document.maps.get(entry.root) {
    Some(registers) =>
      match registers.get(entry.key) {
        Some(register) if register.stamp == entry.stamp =>
          if register.lamport != entry.lamport || register.value != entry.value {
            return Err(InvalidDependency)
          }
        _ => ()
      }
    None => ()
  }
  Ok(())
}

///| A snapshot at an already-known causal frontier must preserve its visible

///|
/// state exactly; this permits tombstone/empty-root collection only.
fn validate_exact_checkpoint_projection(
  document : Document,
  snapshot : CheckpointSnapshot,
) -> Result[Unit, CrdtError] {
  for root, registers in document.maps {
    for key, register in registers {
      match register.value {
        None => ()
        Some(value) => {
          let mut found = false
          for entry in snapshot.maps {
            if entry.root == root && entry.key == key {
              if entry.stamp != register.stamp ||
                entry.lamport != register.lamport ||
                entry.value != Some(value) {
                return Err(CheckpointConflict)
              }
              found = true
            }
          }
          if !found {
            return Err(CheckpointConflict)
          }
        }
      }
    }
  }
  for entry in snapshot.maps {
    match document.maps.get(entry.root) {
      None => return Err(CheckpointConflict)
      Some(registers) =>
        match registers.get(entry.key) {
          None => return Err(CheckpointConflict)
          Some(register) =>
            if register.value != entry.value ||
              register.stamp != entry.stamp ||
              register.lamport != entry.lamport {
              return Err(CheckpointConflict)
            }
        }
    }
  }
  for sequence in snapshot.sequences {
    let local_values = match sequence.kind {
      List =>
        document.lists
        .get(sequence.root)
        .map(sequence_visible_values)
        .unwrap_or([])
      Text =>
        document.texts
        .get(sequence.root)
        .map(sequence_visible_values)
        .unwrap_or([])
    }
    if local_values != sequence.values {
      return Err(CheckpointConflict)
    }
  }
  for (kind, roots) in [(List, document.lists), (Text, document.texts)] {
    for root, sequence in roots {
      let local_values = sequence_visible_values(sequence)
      if !local_values.is_empty() {
        let mut found = false
        for entry in snapshot.sequences {
          if entry.root == root &&
            entry.kind == kind &&
            entry.values == local_values {
            found = true
          }
        }
        if !found {
          return Err(CheckpointConflict)
        }
      }
    }
  }
  Ok(())
}

///|
fn checkpoint_from_snapshot(snapshot : CheckpointSnapshot) -> Checkpoint {
  let maps : Map[String, Map[String, MapRegister]] = {}
  for entry in snapshot.maps {
    let registers = match maps.get(entry.root) {
      Some(registers) => registers
      None => {
        let registers : Map[String, MapRegister] = {}
        maps[entry.root] = registers
        registers
      }
    }
    registers[entry.key] = {
      stamp: entry.stamp,
      lamport: entry.lamport,
      value: entry.value.map(value => value.clone()),
    }
  }
  let lists : Map[String, SequenceState] = {}
  let texts : Map[String, SequenceState] = {}
  for sequence_snapshot in snapshot.sequences {
    if !sequence_snapshot.values.is_empty() {
      let sequence = empty_sequence()
      let mut previous = Root
      for index, value in sequence_snapshot.values {
        let id = CheckpointNode(
          snapshot.id,
          sequence_snapshot.root,
          sequence_snapshot.kind,
          index,
        )
        sequence.nodes[id] = {
          id,
          after: previous,
          lamport: 0,
          value: value.clone(),
          deleted: false,
        }
        previous = id
      }
      match sequence_snapshot.kind {
        List => lists[sequence_snapshot.root] = sequence
        Text => texts[sequence_snapshot.root] = sequence
      }
    }
  }
  {
    id: snapshot.id,
    frontier: clone_vector(snapshot.frontier),
    maps,
    lists,
    texts,
  }
}

///|
fn checkpoint_matches_snapshot(
  checkpoint : Checkpoint,
  snapshot : CheckpointSnapshot,
) -> Bool {
  let incoming_sequences = snapshot.sequences.filter(sequence => {
    !sequence.values.is_empty()
  })
  match snapshot_from_checkpoint(checkpoint) {
    Err(_) => false
    Ok(expected) =>
      if expected.id != snapshot.id ||
        expected.frontier.metadata_entries() !=
        snapshot.frontier.metadata_entries() ||
        expected.maps.length() != snapshot.maps.length() ||
        expected.sequences.length() != incoming_sequences.length() {
        false
      } else {
        let mut maps_match = true
        for index in 0..<expected.maps.length() {
          let left = expected.maps[index]
          let right = snapshot.maps[index]
          if left.root != right.root ||
            left.key != right.key ||
            left.value != right.value ||
            left.stamp != right.stamp ||
            left.lamport != right.lamport {
            maps_match = false
          }
        }
        let mut sequences_match = true
        for index in 0..<expected.sequences.length() {
          let left = expected.sequences[index]
          let right = incoming_sequences[index]
          if left.root != right.root ||
            left.kind != right.kind ||
            left.values != right.values {
            sequences_match = false
          }
        }
        maps_match && sequences_match
      }
  }
}
