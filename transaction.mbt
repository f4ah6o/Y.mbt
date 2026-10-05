///|
/// A batch of user-level edits committed as one observer-visible transition.
pub(all) enum Edit {
  MapSet(String, String, Value)
  MapDelete(String, String)
  ListInsert(String, Int, Array[Value])
  ListDelete(String, Int, Int)
  TextInsert(String, Int, String)
  TextDelete(String, Int, Int)
} derive(Eq)

///|
priv enum UndoAction {
  RestoreMap(String, String, EventId, EventId?, Value?)
  DeleteNode(String, SequenceKind, NodeId)
  InsertAfter(String, SequenceKind, NodeId, Array[(NodeId, Value, EventId)])
}

///|
priv struct UndoRecord {
  actions : Array[UndoAction]
}

///|
/// Apply several map, list, and text edits as one atomic transaction.
/// Text indexes count Unicode scalar values.
pub fn Document::transact(
  self : Document,
  edits : Array[Edit],
) -> Result[ChangeSet, CrdtError] {
  for edit in edits {
    match validate_edit(edit) {
      Err(error) => return Err(error)
      Ok(_) => ()
    }
  }
  let before = clone_document(self)
  let staged = clone_document(self)
  let events : Array[EventId] = []
  let inverse_actions : Array[UndoAction] = []
  for edit in edits {
    let actions = match apply_edit(staged, edit, events) {
      Err(error) => return Err(error)
      Ok(actions) => actions
    }
    for action in actions {
      inverse_actions.push(action)
    }
  }
  if !events.is_empty() {
    let normalized = normalize_undo_actions(reversed_actions(inverse_actions))
    if !normalized.is_empty() {
      staged.undo.push({ actions: normalized, })
    }
    staged.redo = []
  }
  commit_replica_state(self, staged)
  let changes = changes_between(before, self, events)
  if !changes.is_empty() {
    notify_observers(self, changes)
  }
  Ok(changes)
}

///|
/// Set a shared map value.
pub fn Document::map_set(
  self : Document,
  root : String,
  key : String,
  value : Value,
) -> Result[ChangeSet, CrdtError] {
  self.transact([MapSet(root, key, value)])
}

///|
/// Delete a shared map key.
pub fn Document::map_delete(
  self : Document,
  root : String,
  key : String,
) -> Result[ChangeSet, CrdtError] {
  self.transact([MapDelete(root, key)])
}

///|
/// Insert copied values at a Unicode-scalar/list index.
pub fn Document::list_insert(
  self : Document,
  root : String,
  index : Int,
  values : Array[Value],
) -> Result[ChangeSet, CrdtError] {
  self.transact([ListInsert(root, index, values)])
}

///|
/// Delete `length` visible list items beginning at `index`.
pub fn Document::list_delete(
  self : Document,
  root : String,
  index : Int,
  length : Int,
) -> Result[ChangeSet, CrdtError] {
  self.transact([ListDelete(root, index, length)])
}

///|
/// Insert text at a Unicode-scalar index.
pub fn Document::text_insert(
  self : Document,
  root : String,
  index : Int,
  text : String,
) -> Result[ChangeSet, CrdtError] {
  self.transact([TextInsert(root, index, text)])
}

///|
/// Delete `length` Unicode scalar values beginning at `index`.
pub fn Document::text_delete(
  self : Document,
  root : String,
  index : Int,
  length : Int,
) -> Result[ChangeSet, CrdtError] {
  self.transact([TextDelete(root, index, length)])
}

///|
fn validate_edit(edit : Edit) -> Result[Unit, CrdtError] {
  match edit {
    MapSet(root, _, value) => {
      if root.is_empty() {
        return Err(InvalidEvent)
      }
      match validate_update_string(root) {
        Err(error) => return Err(error)
        Ok(_) => ()
      }
      validate_update_value(value, 0, [MAX_UPDATE_VALUE_NODES])
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
    ListInsert(root, index, values) => {
      if root.is_empty() || index < 0 {
        return Err(InvalidIndex)
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
      }
      Ok(())
    }
    ListDelete(root, index, length) | TextDelete(root, index, length) =>
      if root.is_empty() || index < 0 || length < 0 {
        Err(InvalidRange)
      } else {
        validate_update_string(root)
      }
    TextInsert(root, index, text) =>
      if root.is_empty() || index < 0 {
        Err(InvalidIndex)
      } else {
        match validate_update_string(root) {
          Err(error) => return Err(error)
          Ok(_) => ()
        }
        validate_update_string(text)
      }
  }
}

///|
fn apply_edit(
  document : Document,
  edit : Edit,
  events : Array[EventId],
) -> Result[Array[UndoAction], CrdtError] {
  let inverse : Array[UndoAction] = []
  match edit {
    MapSet(root, key, value) => {
      let old_value = current_map_value(document, root, key)
      let predecessor = current_map_stamp(document, root, key)
      match append_local_event(document, MapSet(root, key, value), events) {
        Err(error) => return Err(error)
        Ok(event) =>
          inverse.push(RestoreMap(root, key, event.id, predecessor, old_value))
      }
    }
    MapDelete(root, key) => {
      let old_value = current_map_value(document, root, key)
      let predecessor = current_map_stamp(document, root, key)
      match append_local_event(document, MapDelete(root, key), events) {
        Err(error) => return Err(error)
        Ok(event) =>
          inverse.push(RestoreMap(root, key, event.id, predecessor, old_value))
      }
    }
    ListInsert(root, index, values) => {
      let sequence = document.lists.get(root).unwrap_or(empty_sequence())
      let mut anchor = match sequence_anchor_at(sequence, index) {
        None => return Err(InvalidIndex)
        Some(anchor) => anchor
      }
      for value in values {
        let event = match
          append_local_event(
            document,
            SequenceInsert(root, List, anchor, value),
            events,
          ) {
          Err(error) => return Err(error)
          Ok(event) => event
        }
        inverse.push(DeleteNode(root, List, EventNode(event.id)))
        anchor = EventNode(event.id)
      }
    }
    ListDelete(root, index, length) => {
      let sequence = document.lists.get(root).unwrap_or(empty_sequence())
      let ids = sequence_visible_ids(sequence)
      if index > ids.length() || length > ids.length() - index {
        return Err(InvalidRange)
      }
      let anchor = if index == 0 { Root } else { ids[index - 1] }
      let deleted : Array[(NodeId, Value, EventId)] = []
      for offset in 0..<length {
        let target = ids[index + offset]
        let value = sequence.nodes[target].value.clone()
        let delete_event = match
          append_local_event(
            document,
            SequenceDelete(root, List, target),
            events,
          ) {
          Err(error) => return Err(error)
          Ok(event) => event
        }
        deleted.push((target, value, delete_event.id))
      }
      if length > 0 {
        inverse.push(InsertAfter(root, List, anchor, deleted))
      }
    }
    TextInsert(root, index, text) => {
      let sequence = document.texts.get(root).unwrap_or(empty_sequence())
      let mut anchor = match sequence_anchor_at(sequence, index) {
        None => return Err(InvalidIndex)
        Some(anchor) => anchor
      }
      for character in text.to_array() {
        let event = match
          append_local_event(
            document,
            SequenceInsert(
              root,
              Text,
              anchor,
              String(char_to_string(character)),
            ),
            events,
          ) {
          Err(error) => return Err(error)
          Ok(event) => event
        }
        inverse.push(DeleteNode(root, Text, EventNode(event.id)))
        anchor = EventNode(event.id)
      }
    }
    TextDelete(root, index, length) => {
      let sequence = document.texts.get(root).unwrap_or(empty_sequence())
      let ids = sequence_visible_ids(sequence)
      if index > ids.length() || length > ids.length() - index {
        return Err(InvalidRange)
      }
      let anchor = if index == 0 { Root } else { ids[index - 1] }
      let deleted : Array[(NodeId, Value, EventId)] = []
      for offset in 0..<length {
        let target = ids[index + offset]
        let delete_event = match
          append_local_event(
            document,
            SequenceDelete(root, Text, target),
            events,
          ) {
          Err(error) => return Err(error)
          Ok(event) => event
        }
        deleted.push(
          (target, sequence.nodes[target].value.clone(), delete_event.id),
        )
      }
      if length > 0 {
        inverse.push(InsertAfter(root, Text, anchor, deleted))
      }
    }
  }
  Ok(inverse)
}

///|
fn append_local_event(
  document : Document,
  operation : Operation,
  events : Array[EventId],
) -> Result[Event, CrdtError] {
  let current = document.clock.get(document.replica).unwrap_or(0)
  if current == 2147483647 {
    return Err(ClockOverflow)
  }
  let id = match EventId::new(document.replica, current + 1) {
    Err(error) => return Err(error)
    Ok(id) => id
  }
  let event = match Event::new(id, document.state_vector(), operation) {
    Err(error) => return Err(error)
    Ok(event) => event
  }
  match document.pending.get(id) {
    Some(existing) =>
      if existing != event {
        return Err(ConflictingDuplicate)
      } else {
        return Err(ConflictingDuplicate)
      }
    None => ()
  }
  match integrate_event(document, event) {
    Err(error) => return Err(error)
    Ok(_) => ()
  }
  events.push(id)
  Ok(event)
}

///|
fn current_map_value(
  document : Document,
  root : String,
  key : String,
) -> Value? {
  match document.maps.get(root) {
    None => None
    Some(registers) =>
      match registers.get(key) {
        None => None
        Some(register) => register.value.map(value => value.clone())
      }
  }
}

///|
fn char_to_string(character : Char) -> String {
  let output = StringBuilder::new()
  output.write_char(character)
  output.to_string()
}

///|
fn reversed_actions(actions : Array[UndoAction]) -> Array[UndoAction] {
  let output : Array[UndoAction] = []
  for index in 0..<actions.length() {
    output.push(actions[actions.length() - index - 1])
  }
  output
}

///| Coalesce multiple writes to one key and cancel sequence edits which had

///|
/// no net effect inside the transaction.
fn normalize_undo_actions(actions : Array[UndoAction]) -> Array[UndoAction] {
  let inserted : Map[NodeId, Unit] = {}
  let deleted : Map[NodeId, Unit] = {}
  for action in actions {
    match action {
      DeleteNode(_, _, id) => inserted[id] = ()
      InsertAfter(_, _, _, targets) =>
        for (id, _, _) in targets {
          deleted[id] = ()
        }
      _ => ()
    }
  }
  let normalized : Array[UndoAction] = []
  for action in actions {
    match action {
      RestoreMap(root, key, target, predecessor, value) => {
        let mut found = -1
        for index, prior in normalized {
          match prior {
            RestoreMap(prior_root, prior_key, _, _, _) if prior_root == root &&
              prior_key == key => found = index
            _ => ()
          }
        }
        if found < 0 {
          normalized.push(
            RestoreMap(
              root,
              key,
              target,
              predecessor,
              value.map(value => value.clone()),
            ),
          )
        } else {
          match normalized[found] {
            RestoreMap(prior_root, prior_key, prior_target, _, _) =>
              normalized[found] = RestoreMap(
                prior_root,
                prior_key,
                prior_target,
                predecessor,
                value.map(value => value.clone()),
              )
            _ => ()
          }
        }
      }
      DeleteNode(root, kind, id) =>
        if !deleted.contains(id) {
          normalized.push(DeleteNode(root, kind, id))
        }
      InsertAfter(root, kind, anchor, targets) => {
        let retained = targets.filter(pair => {
          match pair {
            (id, _, _) => !inserted.contains(id)
          }
        })
        if !retained.is_empty() {
          normalized.push(
            InsertAfter(
              root,
              kind,
              anchor,
              retained.map(pair => {
                match pair {
                  (id, value, deleted_by) => (id, value.clone(), deleted_by)
                }
              }),
            ),
          )
        }
      }
    }
  }
  normalized
}

///|
/// Compensate the last local semantic transaction. Sequence deletions are
/// restored as new nodes, and map restoration remains conditional on its
/// original winner still being applicable.
pub fn Document::undo(self : Document) -> Result[ChangeSet, CrdtError] {
  if self.undo.is_empty() {
    return Err(UndoUnavailable)
  }
  let before = clone_document(self)
  let staged = clone_document(self)
  let record = staged.undo.pop().unwrap()
  let events : Array[EventId] = []
  let inverse_actions : Array[UndoAction] = []
  for action in record.actions {
    let inverse = match compensate_action(staged, action, events) {
      Err(error) => return Err(error)
      Ok(inverse) => inverse
    }
    for item in inverse {
      inverse_actions.push(item)
    }
  }
  staged.redo.push({ actions: reversed_actions(inverse_actions), })
  commit_replica_state(self, staged)
  let changes = changes_between(before, self, events)
  if !changes.is_empty() {
    notify_observers(self, changes)
  }
  Ok(changes)
}

///|
/// Re-apply the semantic effect of the last undone transaction with fresh
/// event identities.
pub fn Document::redo(self : Document) -> Result[ChangeSet, CrdtError] {
  if self.redo.is_empty() {
    return Err(UndoUnavailable)
  }
  let before = clone_document(self)
  let staged = clone_document(self)
  let record = staged.redo.pop().unwrap()
  let events : Array[EventId] = []
  let inverse_actions : Array[UndoAction] = []
  for action in record.actions {
    let inverse = match compensate_action(staged, action, events) {
      Err(error) => return Err(error)
      Ok(inverse) => inverse
    }
    for item in inverse {
      inverse_actions.push(item)
    }
  }
  staged.undo.push({ actions: reversed_actions(inverse_actions), })
  commit_replica_state(self, staged)
  let changes = changes_between(before, self, events)
  if !changes.is_empty() {
    notify_observers(self, changes)
  }
  Ok(changes)
}

///|
fn compensate_action(
  document : Document,
  action : UndoAction,
  events : Array[EventId],
) -> Result[Array[UndoAction], CrdtError] {
  let inverse : Array[UndoAction] = []
  match action {
    RestoreMap(root, key, target, predecessor, value) => {
      let prior = current_map_value(document, root, key)
      let prior_stamp = current_map_stamp(document, root, key)
      match
        append_local_event(
          document,
          MapRestore(root, key, target, value),
          events,
        ) {
        Err(error) => return Err(error)
        Ok(event) => {
          inverse.push(RestoreMap(root, key, event.id, prior_stamp, prior))
          if current_map_stamp(document, root, key) == Some(event.id) {
            rebase_map_targets(document.undo, root, key, predecessor, event.id)
            rebase_map_targets(document.redo, root, key, predecessor, event.id)
          }
        }
      }
    }
    DeleteNode(root, kind, target) => {
      let sequence = match sequence_get(document, root, kind) {
        None => return Err(MissingAnchor)
        Some(sequence) => sequence
      }
      let node = match sequence.nodes.get(target) {
        None => return Err(MissingAnchor)
        Some(node) => node
      }
      if !node.deleted {
        let delete_event = match
          append_local_event(
            document,
            SequenceDelete(root, kind, target),
            events,
          ) {
          Err(error) => return Err(error)
          Ok(event) => event
        }
        inverse.push(
          InsertAfter(root, kind, node.after, [
            (target, node.value.clone(), delete_event.id),
          ]),
        )
      }
    }
    InsertAfter(root, kind, anchor, deleted) => {
      let mut current_anchor = anchor
      for (original_id, value, deleted_by) in deleted {
        if !can_restore_deleted_node(
            document, root, kind, original_id, deleted_by,
          ) {
          continue
        }
        let event = match
          append_local_event(
            document,
            SequenceInsert(root, kind, current_anchor, value),
            events,
          ) {
          Err(error) => return Err(error)
          Ok(event) => event
        }
        inverse.push(DeleteNode(root, kind, EventNode(event.id)))
        rebase_sequence_targets(
          document.undo,
          root,
          kind,
          original_id,
          EventNode(event.id),
        )
        rebase_sequence_targets(
          document.redo,
          root,
          kind,
          original_id,
          EventNode(event.id),
        )
        current_anchor = EventNode(event.id)
      }
    }
  }
  Ok(inverse)
}

///|
/// Rebind only records whose target is the predecessor actually restored.
fn rebase_map_targets(
  records : Array[UndoRecord],
  root : String,
  key : String,
  previous : EventId?,
  target : EventId,
) -> Unit {
  let previous = match previous {
    None => return
    Some(previous) => previous
  }
  for record in records {
    for index, action in record.actions {
      match action {
        RestoreMap(action_root, action_key, action_target, predecessor, value) if action_root ==
          root &&
          action_key == key &&
          action_target == previous =>
          record.actions[index] = RestoreMap(
            action_root, action_key, target, predecessor, value,
          )
        _ => ()
      }
    }
  }
}

///| Rebind earlier sequence actions when a deleted item is restored with a

///|
/// fresh event identity.
fn rebase_sequence_targets(
  records : Array[UndoRecord],
  root : String,
  kind : SequenceKind,
  previous : NodeId,
  replacement : NodeId,
) -> Unit {
  for record in records {
    for index, action in record.actions {
      match action {
        DeleteNode(action_root, action_kind, id) if action_root == root &&
          action_kind == kind &&
          id == previous =>
          record.actions[index] = DeleteNode(
            action_root, action_kind, replacement,
          )
        InsertAfter(action_root, action_kind, anchor, deleted) if action_root ==
          root &&
          action_kind == kind &&
          anchor == previous =>
          record.actions[index] = InsertAfter(
            action_root, action_kind, replacement, deleted,
          )
        _ => ()
      }
    }
  }
}

///|
/// A concurrent or later delete must win over undoing an earlier deletion.
fn can_restore_deleted_node(
  document : Document,
  root : String,
  kind : SequenceKind,
  target : NodeId,
  delete_id : EventId,
) -> Bool {
  let mut found_target_delete = false
  for event in document.history {
    match event.operation {
      SequenceDelete(event_root, event_kind, deleted_target) if event_root ==
        root &&
        event_kind == kind &&
        deleted_target == target =>
        if event.id == delete_id {
          found_target_delete = true
        } else {
          return false
        }
      _ => ()
    }
  }
  found_target_delete
}
