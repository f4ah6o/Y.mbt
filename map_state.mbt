///|
fn recompute_map_register(
  document : Document,
  root : String,
  key : String,
) -> Unit {
  let versions = map_versions_through(document, root, key, None)
  let applicable = applicable_map_versions(versions)
  match greatest_version(applicable) {
    None =>
      match document.maps.get(root) {
        Some(registers) => {
          registers.remove(key)
          if registers.is_empty() {
            document.maps.remove(root)
          }
        }
        None => ()
      }
    Some(version) => {
      let registers = match document.maps.get(root) {
        Some(registers) => registers
        None => {
          let registers : Map[String, MapRegister] = {}
          document.maps[root] = registers
          registers
        }
      }
      registers[key] = {
        stamp: version.stamp,
        lamport: version.lamport,
        value: version.value.map(value => value.clone()),
      }
    }
  }
}

///| Materialize versions visible through an optional causal frontier. This is

///| shared by the document projection and checkpoint provenance validation so

///|
/// restore validity is judged by the same deterministic rule in both places.
fn map_versions_through(
  document : Document,
  root : String,
  key : String,
  frontier : StateVector?,
) -> Array[MapVersion] {
  let versions : Array[MapVersion] = []
  match document.checkpoint {
    Some(checkpoint) =>
      if frontier
        .map(value => value.dominates(checkpoint.frontier))
        .unwrap_or(true) {
        match checkpoint.maps.get(root) {
          Some(registers) =>
            match registers.get(key) {
              Some(register) =>
                versions.push({
                  stamp: register.stamp,
                  lamport: register.lamport,
                  value: register.value.map(value => value.clone()),
                  dependencies: Some(checkpoint.frontier),
                  is_restore: false,
                })
              None => ()
            }
          None => ()
        }
      }
    None => ()
  }

  let candidates = document.history.filter(event => {
    map_event_matches(event, root, key) &&
    frontier.map(value => value.includes(event.id)).unwrap_or(true)
  })
  candidates.sort_by((left, right) => {
    if left.lamport == right.lamport {
      EventId::compare(left.id, right.id)
    } else {
      left.lamport - right.lamport
    }
  })
  for event in candidates {
    match event.operation {
      MapSet(_, _, value) =>
        versions.push({
          stamp: event.id,
          lamport: event.lamport,
          value: Some(value.clone()),
          dependencies: Some(event.dependencies),
          is_restore: false,
        })
      MapDelete(_, _) =>
        versions.push({
          stamp: event.id,
          lamport: event.lamport,
          value: None,
          dependencies: Some(event.dependencies),
          is_restore: false,
        })
      MapRestore(_, _, target, value) =>
        if restore_target_is_visible(versions, event.dependencies, target) {
          versions.push({
            stamp: event.id,
            lamport: event.lamport,
            value: value.map(value => value.clone()),
            dependencies: Some(event.dependencies),
            is_restore: true,
          })
        }
      _ => ()
    }
  }
  versions
}

///| Return whether a known map event remains an applicable version. For a

///| restore, `map_versions_through` includes it only if its causal guard

///| passed; this filter also rejects restores permanently suppressed by known

///| concurrent versions while allowing an older applicable restore that may

///|
/// resurface if a newer causal restore is later suppressed.
fn map_version_is_applicable(
  document : Document,
  root : String,
  key : String,
  stamp : EventId,
) -> Bool {
  let versions = map_versions_through(document, root, key, None)
  for version in applicable_map_versions(versions) {
    if version.stamp == stamp {
      return true
    }
  }
  false
}

///|
fn restore_target_is_visible(
  versions : Array[MapVersion],
  dependencies : StateVector,
  target : EventId,
) -> Bool {
  let causal_before = versions.filter(version => {
    dependencies.includes(version.stamp)
  })
  match greatest_version(applicable_map_versions(causal_before)) {
    Some(current) => current.stamp == target
    None => false
  }
}

///| A conditional restoration is suppressed when any concurrent version

///|
/// invalidates its target in the causal context being considered.
fn applicable_map_versions(versions : Array[MapVersion]) -> Array[MapVersion] {
  versions.filter(version => {
    if !version.is_restore {
      true
    } else {
      !versions.any(other => {
        if other.stamp == version.stamp {
          false
        } else {
          match (version.dependencies, other.dependencies) {
            (Some(version_dependencies), Some(other_dependencies)) =>
              !version_dependencies.includes(other.stamp) &&
              !other_dependencies.includes(version.stamp)
            _ => false
          }
        }
      })
    }
  })
}

///|
fn map_event_matches(event : Event, root : String, key : String) -> Bool {
  match event.operation {
    MapSet(event_root, event_key, _)
    | MapDelete(event_root, event_key)
    | MapRestore(event_root, event_key, _, _) =>
      event_root == root && event_key == key
    _ => false
  }
}

///|
/// Return the current map version's event identity, including tombstones.
fn current_map_stamp(
  document : Document,
  root : String,
  key : String,
) -> EventId? {
  match document.maps.get(root) {
    None => None
    Some(registers) => registers.get(key).map(register => register.stamp)
  }
}

///|
fn greatest_version(versions : Array[MapVersion]) -> MapVersion? {
  if versions.is_empty() {
    return None
  }
  let mut best = versions[0]
  for version in versions[1:] {
    if version_wins(version, best) {
      best = version
    }
  }
  Some(best)
}

///|
fn version_wins(candidate : MapVersion, current : MapVersion) -> Bool {
  if candidate.lamport != current.lamport {
    candidate.lamport > current.lamport
  } else {
    EventId::compare(candidate.stamp, current.stamp) > 0
  }
}
