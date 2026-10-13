///|
/// A vector describes four independent replica-local event prefixes. Zero
/// means absent metadata; positive counters have matching valid Lamport times.
/// No event delivery, checkpoint compatibility, or convergence is assumed here.
fn bounded_vector(counts : Array[Int]) -> @y.StateVector {
  let entries = []
  for replica in 0..<counts.length() {
    if counts[replica] > 0 {
      entries.push(("replica-\{replica}", counts[replica], counts[replica]))
    }
  }
  @y.StateVector::from_metadata(entries, None).unwrap()
}

///|
/// Independent model: enumerate actual (replica, event number) identities,
/// then ask whether every required event appears in the available set. This
/// does not call the library's counter/includes/dominates comparison helpers.
fn represented_events(counts : Array[Int]) -> Array[(Int, Int)] {
  let events = []
  for replica in 0..<counts.length() {
    for counter in 1..<(counts[replica] + 1) {
      events.push((replica, counter))
    }
  }
  events
}

///|
fn bounded_counts(bytes : Array[Byte]) -> Array[Int] {
  Array::makei(4, replica => {
    if replica < bytes.length() {
      bytes[replica].to_int() % 9
    } else {
      0
    }
  })
}

///|
test "state-vector dominance agrees with finite event-set inclusion" {
  @quickcheck.check(
    fn(input : (Array[Byte], Array[Byte])) {
      let left = bounded_counts(input.0)
      let right = bounded_counts(input.1)
      let available = represented_events(left)
      let expected = represented_events(right).all(event => {
        available.contains(event)
      })
      bounded_vector(left).dominates(bounded_vector(right)) == expected
    },
    count=2000,
    max_size=8,
    max_shrinks=1000,
    seed=20261012,
  )
}

///|
test "state-vector dominance empty equality and mixed-replica boundaries" {
  for
    (left, right, expected) in [
      ([0, 0], [0, 0], true),
      ([1, 0], [0, 0], true),
      ([0, 0], [1, 0], false),
      ([1, 0], [1, 0], true),
      ([1, 0], [2, 0], false),
      ([2, 0], [1, 0], true),
      ([2, 0], [1, 1], false),
      ([1, 2], [2, 1], false),
      ([8, 8], [8, 8], true),
      ([8, 8], [7, 8], true),
      ([7, 8], [8, 8], false),
    ] {
    assert_eq(bounded_vector(left).dominates(bounded_vector(right)), expected)
  }
  // Pin the model's representation separately from production metadata.
  assert_eq(represented_events([0, 2]), [(1, 1), (1, 2)])
}
