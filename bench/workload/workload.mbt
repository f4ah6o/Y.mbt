///|
/// A logical edit in the deterministic offline-branch benchmark workload.
pub(all) enum Edit {
  TextInsert(Int, String)
  TextDelete(Int, Int)
  ListInsert(Int, Array[Int])
  MapSet(String, JsonValue)
  MapDelete(String)
}

///|
/// JSON-safe map values used by the benchmark workload.
pub(all) enum JsonValue {
  Text(String)
  Number(Int)
}

///|
/// The common seed and two independent offline branches.
pub(all) struct Scenario {
  seed : Array[Edit]
  left : Array[Edit]
  right : Array[Edit]
  seed_size : Int
  edits_per_branch : Int
}

///|
/// Construct the shared logical trace consumed by the MoonBit and Yjs
/// benchmark candidates. Sequence strings in this workload are ASCII so their
/// indexes have the same meaning in the scalar-indexed core and Yjs UTF-16.
pub fn offline_branch_scenario(
  seed_size : Int,
  edits_per_branch : Int,
) -> Scenario {
  if seed_size <= 0 || edits_per_branch <= 0 {
    abort("offline benchmark sizes must be positive")
  }
  let seed : Array[Edit] = [
    TextInsert(0, repeat_scalar('s', seed_size)),
    ListInsert(0, [0, 1, 2]),
    MapSet("title", Text("seed")),
    MapSet("retired", Number(1)),
  ]
  let left : Array[Edit] = []
  let mut left_length = seed_size
  for index in 0..<edits_per_branch {
    let at = index % (left_length + 1)
    left.push(TextInsert(at, "a"))
    left_length += 1
    if index % 5 == 0 {
      left.push(TextDelete(left_length / 2, 1))
      left_length -= 1
    }
  }
  left.push(ListInsert(1, [10, 11]))
  left.push(MapSet("title", Text("left")))
  left.push(MapDelete("retired"))

  let right : Array[Edit] = []
  let mut right_length = seed_size
  for index in 0..<edits_per_branch {
    let at = right_length / 2
    right.push(TextInsert(at, "b"))
    right_length += 1
    if index % 5 == 0 {
      right.push(TextDelete(right_length / 3, 1))
      right_length -= 1
    }
  }
  right.push(ListInsert(2, [20, 21]))
  right.push(MapSet("title", Text("right")))
  right.push(MapSet("retired", Number(9)))

  { seed, left, right, seed_size, edits_per_branch, }
}

///|
/// Serialize the logical trace for the JavaScript-only Yjs candidate.
pub fn Scenario::to_json(self : Scenario) -> String {
  let output = StringBuilder()
  output.write_string("{\"seedSize\":")
  output.write_string(self.seed_size.to_string())
  output.write_string(",\"editsPerBranch\":")
  output.write_string(self.edits_per_branch.to_string())
  output.write_string(",\"seed\":")
  write_edits(output, self.seed)
  output.write_string(",\"left\":")
  write_edits(output, self.left)
  output.write_string(",\"right\":")
  write_edits(output, self.right)
  output.write_char('}')
  output.to_string()
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
fn write_edits(output : StringBuilder, edits : Array[Edit]) -> Unit {
  output.write_char('[')
  let mut first = true
  for edit in edits {
    if !first {
      output.write_char(',')
    }
    first = false
    match edit {
      TextInsert(index, text) => {
        output.write_string("{\"kind\":\"text-insert\",\"index\":")
        output.write_string(index.to_string())
        output.write_string(",\"text\":")
        write_json_string(output, text)
        output.write_char('}')
      }
      TextDelete(index, length) => {
        output.write_string("{\"kind\":\"text-delete\",\"index\":")
        output.write_string(index.to_string())
        output.write_string(",\"length\":")
        output.write_string(length.to_string())
        output.write_char('}')
      }
      ListInsert(index, values) => {
        output.write_string("{\"kind\":\"list-insert\",\"index\":")
        output.write_string(index.to_string())
        output.write_string(",\"values\":[")
        for i in 0..<values.length() {
          if i > 0 {
            output.write_char(',')
          }
          output.write_string(values[i].to_string())
        }
        output.write_string("]}")
      }
      MapSet(key, value) => {
        output.write_string("{\"kind\":\"map-set\",\"key\":")
        write_json_string(output, key)
        output.write_string(",\"value\":")
        match value {
          Text(text) => write_json_string(output, text)
          Number(number) => output.write_string(number.to_string())
        }
        output.write_char('}')
      }
      MapDelete(key) => {
        output.write_string("{\"kind\":\"map-delete\",\"key\":")
        write_json_string(output, key)
        output.write_char('}')
      }
    }
  }
  output.write_char(']')
}

///|
fn write_json_string(output : StringBuilder, value : String) -> Unit {
  output.write_char('"')
  for character in value.to_array() {
    match character {
      '"' => output.write_string("\\\"")
      '\\' => output.write_string("\\\\")
      '\n' => output.write_string("\\n")
      '\r' => output.write_string("\\r")
      '\t' => output.write_string("\\t")
      _ => output.write_char(character)
    }
  }
  output.write_char('"')
}
