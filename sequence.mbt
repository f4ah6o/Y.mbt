///|
fn sequence_all_nodes(sequence : SequenceState) -> Array[SequenceNode] {
  let children : Map[NodeId, Array[NodeId]] = {}
  for id, node in sequence.nodes {
    let siblings = match children.get(node.after) {
      Some(siblings) => siblings
      None => {
        let siblings : Array[NodeId] = []
        children[node.after] = siblings
        siblings
      }
    }
    siblings.push(id)
  }
  for _, siblings in children {
    siblings.sort_by((left, right) => {
      let left_lamport = sequence.nodes[left].lamport
      let right_lamport = sequence.nodes[right].lamport
      if left_lamport == right_lamport {
        NodeId::compare(right, left)
      } else {
        right_lamport - left_lamport
      }
    })
  }
  let stack : Array[NodeId] = []
  push_children_reversed(stack, children.get(Root).unwrap_or([]))
  let output : Array[SequenceNode] = []
  while !stack.is_empty() {
    match stack.pop() {
      None => ()
      Some(id) =>
        match sequence.nodes.get(id) {
          None => ()
          Some(node) => {
            output.push(node)
            push_children_reversed(stack, children.get(id).unwrap_or([]))
          }
        }
    }
  }
  output
}

///|
fn push_children_reversed(
  stack : Array[NodeId],
  children : Array[NodeId],
) -> Unit {
  for index in 0..<children.length() {
    stack.push(children[children.length() - index - 1])
  }
}

///|
fn sequence_visible_nodes(sequence : SequenceState) -> Array[SequenceNode] {
  sequence_all_nodes(sequence).filter(node => !node.deleted)
}

///|
fn sequence_visible_ids(sequence : SequenceState) -> Array[NodeId] {
  sequence_visible_nodes(sequence).map(node => node.id)
}

///|
fn sequence_visible_values(sequence : SequenceState) -> Array[Value] {
  sequence_visible_nodes(sequence).map(node => node.value.clone())
}

///|
fn sequence_anchor_at(sequence : SequenceState, index : Int) -> NodeId? {
  let ids = sequence_visible_ids(sequence)
  if index < 0 || index > ids.length() {
    None
  } else if index == 0 {
    Some(Root)
  } else {
    Some(ids[index - 1])
  }
}

///|
fn sequence_is_descendant(
  sequence : SequenceState,
  node : NodeId,
  ancestor : NodeId,
) -> Bool {
  let mut current = node
  let mut remaining = sequence.nodes.length() + 1
  while remaining > 0 {
    if current == ancestor {
      return true
    }
    match sequence.nodes.get(current) {
      None => return false
      Some(value) => current = value.after
    }
    if current is Root {
      return false
    }
    remaining -= 1
  }
  false
}

///|
fn sequence_position_index(
  sequence : SequenceState,
  position : RelativePosition,
) -> Int? {
  let ordered = sequence_all_nodes(sequence)
  let before = fn(boundary : Int) -> Int {
    let mut visible = 0
    for index in 0..<boundary {
      if !ordered[index].deleted {
        visible += 1
      }
    }
    visible
  }
  let through = fn(boundary : Int) -> Int {
    let mut visible = 0
    for index in 0..<=boundary {
      if !ordered[index].deleted {
        visible += 1
      }
    }
    visible
  }
  let index_of = fn(id : NodeId) -> Int? {
    for index, node in ordered {
      if node.id == id {
        return Some(index)
      }
    }
    None
  }
  let left_index = match position.left {
    Root => Some(-1)
    left => index_of(left)
  }
  let right_index = match position.right {
    None => None
    Some(right) => index_of(right)
  }
  match position.affinity {
    After =>
      match left_index {
        Some(-1) => Some(0)
        Some(index) => Some(through(index))
        None =>
          match right_index {
            Some(index) => Some(before(index))
            None => None
          }
      }
    Before =>
      match right_index {
        Some(index) => Some(before(index))
        None =>
          match left_index {
            Some(-1) => Some(0)
            Some(index) => Some(through(index))
            None => None
          }
      }
  }
}

///|
/// Create a stable position at a Unicode-scalar/list index.
pub fn Document::position_at(
  self : Document,
  root : String,
  kind : SequenceKind,
  index : Int,
  affinity : Affinity,
) -> Result[RelativePosition, CrdtError] {
  let sequence = match sequence_get(self, root, kind) {
    Some(sequence) => sequence
    None => empty_sequence()
  }
  let visible = sequence_visible_ids(sequence)
  if index < 0 || index > visible.length() {
    return Err(InvalidIndex)
  }
  let left = if index == 0 { Root } else { visible[index - 1] }
  let right = if index == visible.length() {
    None
  } else {
    Some(visible[index])
  }
  let checkpoint = self.checkpoint.map(checkpoint => checkpoint.id)
  Ok({ root, kind, left, right, affinity, checkpoint, })
}

///|
/// Resolve a stable position to its current Unicode-scalar/list index.
pub fn Document::resolve_position(
  self : Document,
  position : RelativePosition,
) -> Result[Int, CrdtError] {
  let current_checkpoint = self.checkpoint.map(checkpoint => checkpoint.id)
  if position.checkpoint != current_checkpoint {
    return Err(StalePosition)
  }
  let sequence = match sequence_get(self, position.root, position.kind) {
    Some(sequence) => sequence
    None => empty_sequence()
  }
  match sequence_position_index(sequence, position) {
    None => Err(StalePosition)
    Some(index) => Ok(index)
  }
}
