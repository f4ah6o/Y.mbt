///|
fn[T] latency_must_ok(result : Result[T, @y.CrdtError]) -> T {
  match result {
    Ok(value) => value
    Err(_) => abort("local latency benchmark setup failed")
  }
}

///|
fn[T] latency_must_unit(result : Result[T, @y.CrdtError]) -> Unit {
  match result {
    Ok(_) => ()
    Err(_) => abort("local latency benchmark mutation failed")
  }
}

///|
fn latency_seed_document(replica : String) -> @y.Document {
  let document = latency_must_ok(@y.Document::new(replica))
  let seed = StringBuilder()
  for _ in 0..<64 {
    seed.write_char('x')
  }
  latency_must_unit(document.text_insert("body", 0, seed.to_string()))
  document
}

///|
fn latency_sample(operation : String, sample_id : Int) -> Double {
  let replica = "latency-\{operation}-\{sample_id}"
  let document = latency_seed_document(replica)
  let started = @bench.monotonic_clock_start()
  let result = match operation {
    "insert" => document.text_insert("body", 32, "a")
    "delete" => document.text_delete("body", 32, 1)
    _ => abort("unknown local latency operation")
  }
  let elapsed_microseconds = @bench.monotonic_clock_end(started)
  latency_must_unit(result)
  let expected_length = if operation == "insert" { 65 } else { 63 }
  if document.text("body").char_length() != expected_length {
    abort("single-operation latency sample was not observable")
  }
  elapsed_microseconds
}

///|
fn run_operation(operation : String) -> Unit {
  let warmups = 10
  let trials = 50
  for index in 0..<warmups {
    ignore(latency_sample(operation, -index - 1))
  }
  let samples : Array[Double] = []
  for index in 0..<trials {
    samples.push(latency_sample(operation, index))
  }
  let sorted = samples.copy()
  sorted.sort_by((left, right) => left.compare(right))
  let mut sum = 0.0
  for sample in samples {
    sum += sample
  }
  let median = (sorted[24] + sorted[25]) / 2.0
  println(
    "single_edit_latency: operation=text-\{operation}, seed_text_scalars=64, seed_history_events=64, warmups=\{warmups}, trials=\{trials}, timed_calls_per_trial=1, setup_in_timer=false, statistic=median, median_microseconds=\{median}, mean_microseconds=\{sum / trials.to_double()}, range_microseconds=\{sorted[0]}..\{sorted[trials - 1]}",
  )
}

///|
fn main {
  run_operation("insert")
  run_operation("delete")
}
