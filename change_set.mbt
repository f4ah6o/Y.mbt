///|
/// A semantic change visible after one committed transaction or remote batch.
pub(all) enum Change {
  MapChanged(String, String, Value?, Value?)
  SequenceChanged(String, SequenceKind, Array[Value], Array[Value])
} derive(Eq, Debug)

///|
/// Deterministic summary of one atomic state transition.
struct ChangeSet {
  changes : Array[Change]
  events : Array[EventId]
}

///|
/// Return a copied array of semantic changes.
pub fn ChangeSet::changes(self : ChangeSet) -> Array[Change] {
  self.changes.map(clone_change)
}

///|
/// Return a copied array of event identities integrated by this transition.
pub fn ChangeSet::event_ids(self : ChangeSet) -> Array[EventId] {
  self.events.copy()
}

///|
/// Return true when this transition did not change integrated document state.
pub fn ChangeSet::is_empty(self : ChangeSet) -> Bool {
  self.changes.is_empty()
}

///|
fn clone_change(change : Change) -> Change {
  match change {
    MapChanged(root, key, before, after) =>
      MapChanged(
        root,
        key,
        before.map(value => value.clone()),
        after.map(value => value.clone()),
      )
    SequenceChanged(root, kind, before, after) =>
      SequenceChanged(
        root,
        kind,
        before.map(value => value.clone()),
        after.map(value => value.clone()),
      )
  }
}

///|
/// Copy both change payloads and event identities before observer dispatch.
fn clone_change_set(changes : ChangeSet) -> ChangeSet {
  { changes: changes.changes.map(clone_change), events: changes.events.copy(), }
}

///|
fn changes_between(
  before : Document,
  after : Document,
  ids : Array[EventId],
) -> ChangeSet {
  let changes : Array[Change] = []
  let map_roots = union_sorted_keys(before.maps, after.maps)
  for root in map_roots {
    let left = before.maps.get(root).unwrap_or({})
    let right = after.maps.get(root).unwrap_or({})
    let keys = union_sorted_keys(left, right)
    for key in keys {
      let old_value = match left.get(key) {
        None => None
        Some(register) => register.value
      }
      let new_value = match right.get(key) {
        None => None
        Some(register) => register.value
      }
      if old_value != new_value {
        changes.push(
          MapChanged(
            root,
            key,
            old_value.map(value => value.clone()),
            new_value.map(value => value.clone()),
          ),
        )
      }
    }
  }
  let list_roots = union_sorted_keys(before.lists, after.lists)
  for root in list_roots {
    let old_values = before.list_values(root)
    let new_values = after.list_values(root)
    if old_values != new_values {
      changes.push(SequenceChanged(root, List, old_values, new_values))
    }
  }
  let text_roots = union_sorted_keys(before.texts, after.texts)
  for root in text_roots {
    let old_values = before.texts
      .get(root)
      .map(sequence_visible_values)
      .unwrap_or([])
    let new_values = after.texts
      .get(root)
      .map(sequence_visible_values)
      .unwrap_or([])
    if old_values != new_values {
      changes.push(SequenceChanged(root, Text, old_values, new_values))
    }
  }
  let events = ids
    .filter(id => after.integrated.contains(id))
    .map(id => after.integrated[id])
  sort_events(events)
  let ordered_ids = events.map(event => event.id)
  { changes, events: ordered_ids, }
}

///|
fn[A, B] union_sorted_keys(
  left : Map[String, A],
  right : Map[String, B],
) -> Array[String] {
  let seen : Map[String, Unit] = {}
  for key, _ in left {
    seen[key] = ()
  }
  for key, _ in right {
    seen[key] = ()
  }
  let keys = seen.keys().to_array()
  keys.sort_by((left, right) => left.compare(right))
  keys
}

///|
fn notify_observers(document : Document, changes : ChangeSet) -> Unit {
  document.notification_queue.push(clone_change_set(changes))
  if document.notifying_observers {
    return
  }
  document.notifying_observers = true
  while !document.notification_queue.is_empty() {
    let next = document.notification_queue[0]
    let _ = document.notification_queue.remove(0)
    // Each transition sees the observer set that exists when its FIFO turn
    // begins. Reentrant transitions queue behind the current dispatch.
    let observers = document.observers.copy()
    for observer in observers {
      (observer.callback)(clone_change_set(next))
    }
  }
  document.notifying_observers = false
}

///|
/// Register an observer called once for each committed state transition.
pub fn Document::observe(
  self : Document,
  callback : (ChangeSet) -> Unit,
) -> Int {
  let id = self.next_observer_id
  if id >= 2147483647 {
    return -1
  }
  self.next_observer_id += 1
  self.observers.push({ id, callback, })
  id
}

///|
/// Remove an observer by its registration identifier.
pub fn Document::unobserve(self : Document, id : Int) -> Bool {
  let mut index = 0
  while index < self.observers.length() {
    if self.observers[index].id == id {
      let _ = self.observers.remove(index)
      return true
    }
    index += 1
  }
  false
}
