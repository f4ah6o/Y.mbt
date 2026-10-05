///|
fn[T] checked(result : Result[T, @y.CrdtError]) -> T {
  match result {
    Ok(value) => value
    Err(_) => abort("example operation failed")
  }
}

///|
fn[T] checked_unit(result : Result[T, @y.CrdtError]) -> Unit {
  match result {
    Ok(_) => ()
    Err(_) => abort("example operation failed")
  }
}

///|
fn[T] checked_adapter(result : Result[T, @y.AdapterError]) -> T {
  match result {
    Ok(value) => value
    Err(_) => abort("persistence adapter operation failed")
  }
}

///|
fn main {
  let alice = checked(@y.Document::new("alice"))
  let bob = checked(@y.Document::new("bob"))

  let observer_id = alice.observe(changes => {
    let event_count = changes.event_ids().length()
    let change_count = changes.changes().length()
    println(
      "Alice committed \{event_count} events across \{change_count} visible changes",
    )
  })

  checked_unit(
    alice.transact([
      @y.MapSet("project", "title", @y.String("Offline notes")),
      @y.TextInsert("body", 0, "Drafted while offline."),
    ]),
  )

  // A full update lets a new replica catch up without sharing an event log.
  let full = checked(alice.full_update())
  let full_bytes = checked(full.encode())
  checked_unit(bob.apply_update(checked(@y.Update::decode(full_bytes))))
  println("Bob received \{full_bytes.length()} full-update bytes")

  // Bob can edit independently, then send only events Alice does not know.
  checked_unit(
    bob.text_insert("body", bob.text("body").char_length(), " Bob's note."),
  )
  let bob_delta_bytes = checked(bob.sync_update(alice.state_vector()))
  checked_unit(alice.apply_sync_update(bob_delta_bytes))
  println("Alice received \{bob_delta_bytes.length()} incremental-update bytes")

  // A local transaction is observed once even though it contains two edits.
  checked_unit(
    alice.transact([
      @y.MapSet("project", "status", @y.String("shared")),
      @y.TextInsert("body", alice.text("body").char_length(), " Synced."),
    ]),
  )
  let alice_delta_bytes = checked(alice.sync_update(bob.state_vector()))
  checked_unit(bob.apply_sync_update(alice_delta_bytes))

  // Undo and redo are semantic edits and travel through ordinary sync updates.
  checked_unit(alice.transact([@y.TextInsert("scratch", 0, "temporary")]))
  checked_unit(alice.undo())
  let undo_delta = checked(alice.sync_update(bob.state_vector()))
  checked_unit(bob.apply_sync_update(undo_delta))
  println(
    "Undo synchronized; scratch is empty: \{bob.text("scratch").is_empty()}",
  )
  checked_unit(alice.redo())
  let redo_delta = checked(alice.sync_update(bob.state_vector()))
  checked_unit(bob.apply_sync_update(redo_delta))

  // The library accepts application-owned load/save functions; this demo uses
  // a map in memory in place of a filesystem or database.
  let memory_store : Map[String, Bytes] = Map([])
  let persistence = @y.PersistenceAdapter::new(
    () => Ok(memory_store.get("notes")),
    bytes => {
      memory_store["notes"] = bytes
      Ok(())
    },
  )
  checked_adapter(alice.persist(persistence))
  let restored = checked_adapter(@y.Document::restore("restored", persistence))
  println("Restored document: \{restored.text("body")}")
  ignore(alice.unobserve(observer_id))

  let alice_text = alice.text("body")
  let bob_text = bob.text("body")
  println("Alice: \{alice_text}")
  println("Bob:   \{bob_text}")
  println(
    "Converged: \{alice_text == bob_text && alice.text("scratch") == bob.text("scratch")}",
  )
}
