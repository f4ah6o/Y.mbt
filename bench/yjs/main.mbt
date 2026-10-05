///|
#cfg(target="js")
extern "js" fn run_yjs_candidate(
  scenario_json : String,
  native_event_count : Int,
  native_projection : String,
) -> String =
  #|(scenarioJson, nativeEventCount, nativeProjection) => {
  #|  const fs = process.getBuiltinModule("fs")
  #|  const { createRequire } = process.getBuiltinModule("module")
  #|  const requireFromFixturePackage = createRequire(
  #|    process.cwd() + "/compat/yjs/package.json",
  #|  )
  #|  const Y = requireFromFixturePackage("yjs")
  #|  const yjsPackage = JSON.parse(fs.readFileSync(
  #|    process.cwd() + "/compat/yjs/node_modules/yjs/package.json",
  #|    "utf8",
  #|  ))
  #|  if (yjsPackage.version !== "13.6.32") {
  #|    throw new Error(`Expected pinned Yjs 13.6.32, found ${yjsPackage.version}`)
  #|  }
  #|
  #|  const scenario = JSON.parse(scenarioJson)
  #|  const seedClient = 101
  #|  const leftClient = 202
  #|  const rightClient = 303
  #|  const receiverClient = 9900
  #|  const newDoc = (clientID) => {
  #|    const doc = new Y.Doc()
  #|    doc.clientID = clientID
  #|    return doc
  #|  }
  #|  const applyOps = (doc, edits) => {
  #|    for (const edit of edits) {
  #|      switch (edit.kind) {
  #|        case "text-insert":
  #|          doc.getText("body").insert(edit.index, edit.text)
  #|          break
  #|        case "text-delete":
  #|          doc.getText("body").delete(edit.index, edit.length)
  #|          break
  #|        case "list-insert":
  #|          doc.getArray("items").insert(edit.index, edit.values)
  #|          break
  #|        case "map-set":
  #|          doc.getMap("meta").set(edit.key, edit.value)
  #|          break
  #|        case "map-delete":
  #|          doc.getMap("meta").delete(edit.key)
  #|          break
  #|        default:
  #|          throw new Error(`Unknown workload edit: ${edit.kind}`)
  #|      }
  #|    }
  #|  }
  #|  const project = (doc) => ({
  #|    body: doc.getText("body").toString(),
  #|    items: doc.getArray("items").toJSON(),
  #|    title: doc.getMap("meta").get("title") ?? null,
  #|    retired: doc.getMap("meta").get("retired") ?? null,
  #|  })
  #|  const encodeProjection = (projection) => JSON.stringify(projection)
  #|  const seed = newDoc(seedClient)
  #|  applyOps(seed, scenario.seed)
  #|  const seedUpdate = Y.encodeStateAsUpdate(seed)
  #|  const seedVector = Y.encodeStateVector(seed)
  #|  const left = newDoc(leftClient)
  #|  Y.applyUpdate(left, seedUpdate)
  #|  applyOps(left, scenario.left)
  #|  const leftDelta = Y.encodeStateAsUpdate(left, seedVector)
  #|  const right = newDoc(rightClient)
  #|  Y.applyUpdate(right, seedUpdate)
  #|  applyOps(right, scenario.right)
  #|  const rightDelta = Y.encodeStateAsUpdate(right, seedVector)
  #|
  #|  const mergeInOrder = (reverse) => {
  #|    const receiver = newDoc(receiverClient)
  #|    Y.applyUpdate(receiver, seedUpdate)
  #|    if (reverse) {
  #|      Y.applyUpdate(receiver, rightDelta)
  #|      Y.applyUpdate(receiver, leftDelta)
  #|    } else {
  #|      Y.applyUpdate(receiver, leftDelta)
  #|      Y.applyUpdate(receiver, rightDelta)
  #|    }
  #|    return { receiver, projection: project(receiver) }
  #|  }
  #|  const leftFirst = mergeInOrder(false)
  #|  const rightFirst = mergeInOrder(true)
  #|  const converged = encodeProjection(leftFirst.projection) ===
  #|    encodeProjection(rightFirst.projection)
  #|  if (!converged) {
  #|    throw new Error("Yjs branch update order changed its final projection")
  #|  }
  #|
  #|  const operationCount = [scenario.seed, scenario.left, scenario.right]
  #|    .reduce((total, edits) => total + edits.length, 0)
  #|  const bytes = seedUpdate.length + leftDelta.length + rightDelta.length
  #|  const runOne = () => {
  #|    const start = process.hrtime.bigint()
  #|    const receiver = newDoc(receiverClient)
  #|    Y.applyUpdate(receiver, seedUpdate)
  #|    Y.applyUpdate(receiver, leftDelta)
  #|    Y.applyUpdate(receiver, rightDelta)
  #|    const visible = project(receiver)
  #|    const elapsed = Number(process.hrtime.bigint() - start) / 1000
  #|    return { elapsed, visible }
  #|  }
  #|  for (let index = 0; index < 5; index += 1) {
  #|    runOne()
  #|  }
  #|  const samples = []
  #|  for (let index = 0; index < 15; index += 1) {
  #|    samples.push(runOne())
  #|  }
  #|  const timings = samples.map((sample) => sample.elapsed).sort((a, b) => a - b)
  #|  const mean = timings.reduce((sum, value) => sum + value, 0) / timings.length
  #|  const median = timings[7]
  #|  const finalProjection = samples[samples.length - 1].visible
  #|  const finalProjectionJson = encodeProjection(finalProjection)
  #|  const yjsStructCount = Array.from(leftFirst.receiver.store.clients.values())
  #|    .reduce((count, structs) => count + structs.length, 0)
  #|  if (finalProjectionJson.length === 0 || yjsStructCount === 0) {
  #|    throw new Error("Yjs benchmark result was not observably retained")
  #|  }
  #|  return JSON.stringify({
  #|    yjsVersion: yjsPackage.version,
  #|    seedSize: scenario.seedSize,
  #|    editsPerBranch: scenario.editsPerBranch,
  #|    logicalEditCalls: operationCount,
  #|    nativeEventCount,
  #|    matchesNativeProjection: finalProjectionJson === nativeProjection,
  #|    clientIds: { seed: seedClient, left: leftClient, right: rightClient },
  #|    updateBytes: { seed: seedUpdate.length, leftDelta: leftDelta.length, rightDelta: rightDelta.length, total: bytes },
  #|    yjsStructCount,
  #|    updateOrderConverged: converged,
  #|    projection: finalProjectionJson,
  #|    coldMergeAndProjection: {
  #|      warmups: 5,
  #|      trials: timings.length,
  #|      timer: "process.hrtime.bigint, microseconds",
  #|      includes: "new Y.Doc + applyUpdate(seed,leftDelta,rightDelta) + in-memory projection reads",
  #|      excludes: "scenario construction, branch edits, update encoding, JSON serialization",
  #|      medianMicroseconds: median,
  #|      meanMicroseconds: mean,
  #|      rangeMicroseconds: [timings[0], timings[timings.length - 1]],
  #|    },
  #|  })
  #|}

///|
#cfg(target="js")
fn[T] yjs_must_ok(result : Result[T, @y.CrdtError]) -> T {
  match result {
    Ok(value) => value
    Err(_) => abort("native cross-candidate workload setup failed")
  }
}

///|
#cfg(not(target="js"))
fn run_yjs_candidate(
  _scenario_json : String,
  _native_event_count : Int,
  _native_projection : String,
) -> String {
  "Yjs candidate requires JavaScript"
}

///|
#cfg(target="js")
fn[T] yjs_must_unit(result : Result[T, @y.CrdtError]) -> Unit {
  match result {
    Ok(_) => ()
    Err(_) => abort("native cross-candidate workload failed")
  }
}

///|
#cfg(target="js")
fn apply_scenario_edits(
  document : @y.Document,
  edits : Array[@workload.Edit],
) -> Unit {
  for edit in edits {
    match edit {
      @workload.TextInsert(index, text) =>
        yjs_must_unit(document.text_insert("body", index, text))
      @workload.TextDelete(index, length) =>
        yjs_must_unit(document.text_delete("body", index, length))
      @workload.ListInsert(index, values) =>
        yjs_must_unit(
          document.list_insert(
            "items",
            index,
            values.map(value => @y.Int(value)),
          ),
        )
      @workload.MapSet(key, value) =>
        match value {
          @workload.Text(text) =>
            yjs_must_unit(document.map_set("meta", key, @y.String(text)))
          @workload.Number(number) =>
            yjs_must_unit(document.map_set("meta", key, @y.Int(number)))
        }
      @workload.MapDelete(key) =>
        yjs_must_unit(document.map_delete("meta", key))
    }
  }
}

///|
#cfg(target="js")
fn compare_yjs_event_ids(left : @y.EventId, right : @y.EventId) -> Int {
  let replica_order = left.replica().compare(right.replica())
  if replica_order != 0 {
    replica_order
  } else {
    left.counter().compare(right.counter())
  }
}

///|
#cfg(target="js")
fn native_scenario_projection(scenario : @workload.Scenario) -> (Int, String) {
  let seed = yjs_must_ok(@y.Document::new("seed"))
  apply_scenario_edits(seed, scenario.seed)
  let seed_events = seed.events()
  let left = yjs_must_ok(@y.Document::new("left"))
  yjs_must_unit(left.apply_events(seed_events))
  apply_scenario_edits(left, scenario.left)
  let right = yjs_must_ok(@y.Document::new("right"))
  yjs_must_unit(right.apply_events(seed_events))
  apply_scenario_edits(right, scenario.right)
  let by_id : Map[@y.EventId, @y.Event] = Map([])
  for event in left.events() {
    by_id[event.id()] = event
  }
  for event in right.events() {
    by_id[event.id()] = event
  }
  let events = by_id.values().to_array()
  events.sort_by((left_event, right_event) => {
    compare_yjs_event_ids(left_event.id(), right_event.id())
  })
  let receiver = yjs_must_ok(@y.Document::new("projection"))
  yjs_must_unit(receiver.apply_events(events))
  let projection = StringBuilder()
  projection.write_string("{\"body\":")
  write_projection_string(projection, receiver.text("body"))
  projection.write_string(",\"items\":[")
  let items = receiver.list_values("items")
  for index in 0..<items.length() {
    if index > 0 {
      projection.write_char(',')
    }
    match items[index] {
      @y.Int(value) => projection.write_string(value.to_string())
      _ => abort("unexpected non-integer workload list value")
    }
  }
  projection.write_string("],\"title\":")
  write_projection_value(projection, receiver.map_get("meta", "title"))
  projection.write_string(",\"retired\":")
  write_projection_value(projection, receiver.map_get("meta", "retired"))
  projection.write_char('}')
  (events.length(), projection.to_string())
}

///|
#cfg(target="js")
fn write_projection_string(output : StringBuilder, value : String) -> Unit {
  output.write_char('"')
  for character in value.to_array() {
    match character {
      '"' => output.write_string("\\\"")
      '\\' => output.write_string("\\\\")
      _ => output.write_char(character)
    }
  }
  output.write_char('"')
}

///|
#cfg(target="js")
fn write_projection_value(output : StringBuilder, value : @y.Value?) -> Unit {
  match value {
    None => output.write_string("null")
    Some(@y.String(text)) => write_projection_string(output, text)
    Some(@y.Int(number)) => output.write_string(number.to_string())
    _ => abort("unexpected map value in workload projection")
  }
}

///|
#cfg(target="js")
fn run_case(seed_size : Int, edits_per_branch : Int) -> Unit {
  let scenario = @workload.offline_branch_scenario(seed_size, edits_per_branch)
  let (native_event_count, native_projection) = native_scenario_projection(
    scenario,
  )
  let yjs_result = run_yjs_candidate(
    scenario.to_json(),
    native_event_count,
    native_projection,
  )
  println(
    "cross_candidate_projection: seed_size=\{seed_size}, edits_per_branch=\{edits_per_branch}, native_projection=\{native_projection}, yjs_result=\{yjs_result}",
  )
}

///|
#cfg(target="js")
fn main {
  run_case(24, 20)
  run_case(64, 48)
  run_case(128, 96)
}

///|
#cfg(not(target="js"))
fn main {
  println("The upstream Yjs struct-store benchmark is available on JavaScript")
}
