///|
#cfg(target="js")
extern "js" fn force_full_gc() -> Unit =
  #|() => {
  #|  if (typeof global.gc !== "function") {
  #|    throw new Error("run this probe with node --expose-gc")
  #|  }
  #|  global.gc()
  #|}

///|
#cfg(target="js")
extern "js" fn js_heap_used_bytes() -> Double =
  #|() => process.memoryUsage().heapUsed

///|
#cfg(target="js")
fn[T] memory_must_ok(result : Result[T, @y.CrdtError]) -> T {
  match result {
    Ok(value) => value
    Err(_) => abort("heap probe document operation failed")
  }
}

///|
#cfg(target="js")
fn[T] memory_must_unit(result : Result[T, @y.CrdtError]) -> Unit {
  match result {
    Ok(_) => ()
    Err(_) => abort("heap probe document operation failed")
  }
}

///|
#cfg(target="js")
fn memory_repeat(scalar : Char, count : Int) -> String {
  let output = StringBuilder()
  for _ in 0..<count {
    output.write_char(scalar)
  }
  output.to_string()
}

///|
#cfg(target="js")
fn memory_build_documents(
  document_count : Int,
  repeated_same_value_edits : Int,
) -> Array[@y.Document] {
  let documents : Array[@y.Document] = []
  let edits : Array[@y.Edit] = []
  for _ in 0..<repeated_same_value_edits {
    edits.push(@y.MapSet("meta", "revision", @y.Int(1)))
  }
  for index in 0..<document_count {
    let replica = "heap-\{index}"
    let document = memory_must_ok(@y.Document::new(replica))
    memory_must_unit(document.text_insert("body", 0, memory_repeat('x', 32)))
    memory_must_unit(
      document.list_insert("items", 0, [
        @y.Int(1),
        @y.Int(2),
        @y.Int(3),
        @y.Int(4),
      ]),
    )
    memory_must_unit(document.map_set("meta", "stable", @y.String("unchanged")))
    memory_must_unit(document.map_set("meta", "revision", @y.Int(1)))
    if !edits.is_empty() {
      memory_must_unit(document.transact(edits))
    }
    documents.push(document)
  }
  documents
}

///|
#cfg(target="js")
fn memory_empty_documents(document_count : Int) -> Array[@y.Document] {
  let documents : Array[@y.Document] = []
  for index in 0..<document_count {
    documents.push(memory_must_ok(@y.Document::new("empty-heap-\{index}")))
  }
  documents
}

///|
#cfg(target="js")
fn memory_build_live_size_documents(
  document_count : Int,
  sequence_size : Int,
) -> Array[@y.Document] {
  let documents : Array[@y.Document] = []
  let text = memory_repeat('x', sequence_size)
  let values : Array[@y.Value] = []
  for index in 0..<sequence_size {
    values.push(@y.Int(index))
  }
  for index in 0..<document_count {
    let document = memory_must_ok(
      @y.Document::new("live-heap-\{sequence_size}-\{index}"),
    )
    memory_must_unit(document.text_insert("body", 0, text))
    memory_must_unit(document.list_insert("items", 0, values))
    documents.push(document)
  }
  documents
}

///|
#cfg(target="js")
fn memory_validate_live_size(
  documents : Array[@y.Document],
  sequence_size : Int,
  compacted : Bool,
) -> Int {
  let mut checked = 0
  for document in documents {
    let counts = document.storage_counts()
    let expected_events = if compacted { 0 } else { 2 * sequence_size }
    if document.text("body").char_length() != sequence_size ||
      document.list_values("items").length() != sequence_size ||
      counts.0 != expected_events ||
      counts.1 != 0 ||
      counts.2 != 2 * sequence_size ||
      counts.3 != 0 {
      abort("variable-live heap probe changed visible or retained state")
    }
    checked += 1
  }
  checked
}

///|
#cfg(target="js")
fn memory_measure_live_size(sequence_size : Int, trial : Int) -> Unit {
  let document_count = 8
  let live_elements_per_document = 2 * sequence_size
  let empty_documents = memory_empty_documents(document_count)
  force_full_gc()
  let empty_heap = js_heap_used_bytes()
  let documents = memory_build_live_size_documents(
    document_count, sequence_size,
  )
  let retained_events_per_document = documents[0].storage_counts().0
  let retained_nodes_per_document = documents[0].storage_counts().2
  let visible_documents = memory_validate_live_size(
    documents, sequence_size, false,
  )
  force_full_gc()
  let populated_heap = js_heap_used_bytes()
  for document in documents {
    ignore(memory_must_ok(document.compact("live-size-checkpoint")))
  }
  let compacted_counts = documents[0].storage_counts()
  force_full_gc()
  let compacted_heap = js_heap_used_bytes()
  let compacted_documents = memory_validate_live_size(
    documents, sequence_size, true,
  )
  let empty_documents_checked = memory_validate_live_size(
    empty_documents, 0, false,
  )
  if visible_documents != document_count ||
    compacted_documents != document_count ||
    empty_documents_checked != document_count {
    abort("variable-live heap probe lost a document during GC")
  }
  let retained_delta = (populated_heap - empty_heap).to_int()
  let compacted_delta = (compacted_heap - empty_heap).to_int()
  let docs = document_count.to_double()
  let elements = live_elements_per_document.to_double()
  println(
    "js_live_size_heap_sample: trial=\{trial}, sequence_size_each=\{sequence_size}, live_text_scalars_per_document=\{sequence_size}, live_list_items_per_document=\{sequence_size}, live_sequence_elements_per_document=\{live_elements_per_document}, documents=\{document_count}, empty_baseline_documents=\{document_count}, empty_documents_checked_after_sample=\{empty_documents_checked}, populated_documents_checked_before_sample=\{visible_documents}, compacted_documents_checked_after_sample=\{compacted_documents}, retained_history_events_per_document=\{retained_events_per_document}, retained_sequence_nodes_per_document=\{retained_nodes_per_document}, empty_baseline_heap_bytes=\{empty_heap.to_int()}, populated_heap_bytes=\{populated_heap.to_int()}, compacted_heap_bytes=\{compacted_heap.to_int()}, retained_delta_bytes_per_added_document=\{(retained_delta.to_double() / docs).to_int()}, retained_delta_bytes_per_live_element_including_document_overhead=\{retained_delta.to_double() / docs / elements}, compacted_history_events_per_document=\{compacted_counts.0}, compacted_sequence_nodes_per_document=\{compacted_counts.2}, compacted_delta_bytes_per_added_document=\{(compacted_delta.to_double() / docs).to_int()}, compacted_delta_bytes_per_live_element_including_document_overhead=\{compacted_delta.to_double() / docs / elements}",
  )
}

///|
#cfg(target="js")
fn memory_warm_live_size(sequence_size : Int) -> Unit {
  let documents = memory_build_live_size_documents(2, sequence_size)
  for document in documents {
    ignore(memory_must_ok(document.compact("live-size-warmup")))
  }
  ignore(memory_validate_live_size(documents, sequence_size, true))
}

///|
#cfg(target="js")
fn memory_measure_history(
  repeated_same_value_edits : Int,
  document_count : Int,
  trial : Int,
) -> Unit {
  force_full_gc()
  let before_heap = js_heap_used_bytes()
  let documents = memory_build_documents(
    document_count, repeated_same_value_edits,
  )
  let before_counts = documents[0].storage_counts()
  for document in documents {
    if document.text("body") != memory_repeat('x', 32) ||
      document.list_values("items").length() != 4 ||
      document.map_get("meta", "revision") != Some(@y.Int(1)) {
      abort("fixed-live heap probe changed visible document state")
    }
  }
  force_full_gc()
  let history_heap = js_heap_used_bytes()
  for document in documents {
    ignore(memory_must_ok(document.compact("heap-checkpoint")))
  }
  let compacted_counts = documents[0].storage_counts()
  let checkpoint_bytes = memory_must_ok(
    memory_must_ok(documents[0].full_update()).encode(),
  ).length()
  force_full_gc()
  let compacted_heap = js_heap_used_bytes()
  let mut documents_checked_after_sample = 0
  for document in documents {
    let retained = document.storage_counts()
    if retained.0 != 0 || document.text("body") != memory_repeat('x', 32) {
      abort("compacted document changed after heap sample")
    }
    documents_checked_after_sample += 1
  }
  if documents_checked_after_sample != document_count {
    abort("heap sample lost a compacted document before validation")
  }
  let history_delta = (history_heap - before_heap).to_int()
  let compacted_delta = (compacted_heap - before_heap).to_int()
  let docs_as_double = document_count.to_double()
  println(
    "js_heap_sample: trial=\{trial}, repeated_same_value_edits=\{repeated_same_value_edits}, documents=\{document_count}, documents_checked_after_sample=\{documents_checked_after_sample}, live_text_scalars=32, live_list_items=4, live_map_keys=2, history_events_per_document=\{before_counts.0}, sequence_nodes_per_document=\{before_counts.2}, map_registers_per_document=\{before_counts.3}, retained_heap_delta_bytes=\{history_delta}, retained_heap_delta_bytes_per_document=\{(history_delta.to_double() / docs_as_double).to_int()}, compacted_history_events_per_document=\{compacted_counts.0}, compacted_sequence_nodes_per_document=\{compacted_counts.2}, compacted_map_registers_per_document=\{compacted_counts.3}, heap_delta_after_compaction_bytes=\{compacted_delta}, heap_delta_after_compaction_bytes_per_document=\{(compacted_delta.to_double() / docs_as_double).to_int()}, checkpoint_update_bytes=\{checkpoint_bytes}",
  )
}

///|
#cfg(target="js")
fn main {
  let warmup = memory_build_documents(2, 16)
  ignore(warmup.length())
  memory_warm_live_size(64)
  memory_warm_live_size(256)
  memory_warm_live_size(1024)
  memory_warm_live_size(2048)
  force_full_gc()
  for trial in 1..<=3 {
    memory_measure_history(0, 8, trial)
    memory_measure_history(128, 8, trial)
    memory_measure_history(512, 8, trial)
    memory_measure_history(2048, 8, trial)
    memory_measure_live_size(64, trial)
    memory_measure_live_size(256, trial)
    memory_measure_live_size(1024, trial)
    memory_measure_live_size(2048, trial)
  }
}

///|
#cfg(not(target="js"))
fn main {
  println("The retained heap probe is available on the JavaScript target")
}
