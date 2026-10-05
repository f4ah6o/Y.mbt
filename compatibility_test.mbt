///|
// Generated from upstream Yjs by scripts/yjs-fixtures.mbtx.
const YJS_FIXTURE_JSONL : String =
  #|{"format":1,"upstream":{"package":"yjs","version":"13.6.32"},"scenario":"map-basic","operations":[{"type":"map-set","key":"status","value":"draft"},{"type":"map-set","key":"status","value":"published"},{"type":"map-set","key":"obsolete","value":true},{"type":"map-delete","key":"obsolete"}],"expected":{"map":{"status":"published"}}}
  #|{"format":1,"upstream":{"package":"yjs","version":"13.6.32"},"scenario":"array-basic","operations":[{"type":"array-insert","index":0,"values":["first","second"]},{"type":"array-insert","index":1,"values":["middle"]},{"type":"array-delete","index":0,"length":1}],"expected":{"array":["middle","second"]}}
  #|{"format":1,"upstream":{"package":"yjs","version":"13.6.32"},"scenario":"text-unicode-boundary","indexUnit":"utf16-code-unit","operations":[{"type":"text-insert","index":0,"text":"A😀B"},{"type":"text-insert","index":1,"text":"🙂"},{"type":"text-delete","index":5,"length":1}],"nativeScalarOperations":[{"type":"text-insert","index":0,"text":"A😀B"},{"type":"text-insert","index":1,"text":"🙂"},{"type":"text-delete","index":3,"length":1}],"nativeIndexUnit":"unicode-scalar","indexProjections":[{"context":"before B in A🙂😀B","yjsUtf16Index":5,"nativeScalarIndex":3}],"expected":{"text":"A🙂😀"}}
// End generated Yjs fixture data.

///|
fn fixture_field(value : Json, name : String) -> Json raise {
  match value {
    Json::Object(fields) =>
      match fields.get(name) {
        Some(field) => field
        None => fail("missing fixture field: \{name}")
      }
    _ => fail("expected fixture object while reading \{name}")
  }
}

///|
fn fixture_string(value : Json) -> String raise {
  match value {
    Json::String(text) => text
    _ => fail("expected fixture string")
  }
}

///|
fn fixture_array(value : Json) -> Array[Json] raise {
  match value {
    Json::Array(values) => values
    _ => fail("expected fixture array")
  }
}

///|
fn fixture_integer(value : Json) -> Int raise {
  @json.from_json(value)
}

///|
fn fixture_value(value : Json) -> @y.Value raise {
  match value {
    Json::Null => @y.Value::Null
    Json::True => @y.Value::Bool(true)
    Json::False => @y.Value::Bool(false)
    Json::Number(number, repr~) => {
      let _ = repr
      let integer = number.to_int()
      if integer.to_double() != number {
        fail("fixture contains a non-integer number unsupported by Value")
      }
      @y.Value::Int(integer)
    }
    Json::String(text) => @y.Value::String(text)
    Json::Array(values) =>
      @y.Value::Array(values.map(value => fixture_value(value)))
    Json::Object(fields) => {
      let output : Map[String, @y.Value] = {}
      for key, value in fields {
        output[key] = fixture_value(value)
      }
      @y.Value::Object(output)
    }
  }
}

///|
fn fixture_values(value : Json) -> Array[@y.Value] raise {
  fixture_array(value).map(value => fixture_value(value))
}

///|
fn[T, E] fixture_expect_success(
  result : Result[T, E],
  scenario : String,
) -> Unit raise {
  match result {
    Ok(_) => ()
    Err(_) => fail("native operation failed while replaying \{scenario}")
  }
}

///|
fn replay_map_fixture(
  document : @y.Document,
  operations : Array[Json],
  scenario : String,
) -> Unit raise {
  for operation in operations {
    let kind = fixture_string(fixture_field(operation, "type"))
    let key = fixture_string(fixture_field(operation, "key"))
    match kind {
      "map-set" =>
        fixture_expect_success(
          document.map_set(
            "root",
            key,
            fixture_value(fixture_field(operation, "value")),
          ),
          scenario,
        )
      "map-delete" =>
        fixture_expect_success(document.map_delete("root", key), scenario)
      _ => fail("unknown map fixture operation: \{kind}")
    }
  }
}

///|
fn replay_array_fixture(
  document : @y.Document,
  operations : Array[Json],
  scenario : String,
) -> Unit raise {
  for operation in operations {
    let kind = fixture_string(fixture_field(operation, "type"))
    let index = fixture_integer(fixture_field(operation, "index"))
    match kind {
      "array-insert" =>
        fixture_expect_success(
          document.list_insert(
            "root",
            index,
            fixture_values(fixture_field(operation, "values")),
          ),
          scenario,
        )
      "array-delete" =>
        fixture_expect_success(
          document.list_delete(
            "root",
            index,
            fixture_integer(fixture_field(operation, "length")),
          ),
          scenario,
        )
      _ => fail("unknown array fixture operation: \{kind}")
    }
  }
}

///|
fn replay_text_fixture(
  document : @y.Document,
  operations : Array[Json],
  scenario : String,
) -> Unit raise {
  for operation in operations {
    let kind = fixture_string(fixture_field(operation, "type"))
    let index = fixture_integer(fixture_field(operation, "index"))
    match kind {
      "text-insert" =>
        fixture_expect_success(
          document.text_insert(
            "root",
            index,
            fixture_string(fixture_field(operation, "text")),
          ),
          scenario,
        )
      "text-delete" =>
        fixture_expect_success(
          document.text_delete(
            "root",
            index,
            fixture_integer(fixture_field(operation, "length")),
          ),
          scenario,
        )
      _ => fail("unknown text fixture operation: \{kind}")
    }
  }
}

///|
fn assert_map_projection(
  actual : Map[String, @y.Value],
  expected : Json,
  scenario : String,
) -> Unit raise {
  match expected {
    Json::Object(expected_fields) => {
      if actual.length() != expected_fields.length() {
        fail("map projection has the wrong number of keys in \{scenario}")
      }
      for key, expected_value in expected_fields {
        match actual.get(key) {
          Some(actual_value) =>
            if actual_value != fixture_value(expected_value) {
              fail("map projection differs at key \{key} in \{scenario}")
            }
          None => fail("map projection is missing key \{key} in \{scenario}")
        }
      }
    }
    _ => fail("expected object projection for \{scenario}")
  }
}

///|
fn assert_array_projection(
  actual : Array[@y.Value],
  expected : Json,
  scenario : String,
) -> Unit raise {
  let expected_values = fixture_array(expected)
  if actual.length() != expected_values.length() {
    fail("array projection has the wrong length in \{scenario}")
  }
  for index in 0..<expected_values.length() {
    if actual[index] != fixture_value(expected_values[index]) {
      fail("array projection differs at index \{index} in \{scenario}")
    }
  }
}

///|
fn replay_yjs_fixture(fixture : Json) -> Unit raise {
  assert_eq(fixture_integer(fixture_field(fixture, "format")), 1)
  let upstream = fixture_field(fixture, "upstream")
  assert_eq(fixture_string(fixture_field(upstream, "package")), "yjs")
  assert_eq(fixture_string(fixture_field(upstream, "version")), "13.6.32")

  let scenario = fixture_string(fixture_field(fixture, "scenario"))
  let document = match @y.Document::new("yjs-fixture-\{scenario}") {
    Ok(document) => document
    Err(_) => fail("could not create replica for \{scenario}")
  }
  let expected = fixture_field(fixture, "expected")
  match scenario {
    "map-basic" => {
      replay_map_fixture(
        document,
        fixture_array(fixture_field(fixture, "operations")),
        scenario,
      )
      assert_map_projection(
        document.map_snapshot("root"),
        fixture_field(expected, "map"),
        scenario,
      )
    }
    "array-basic" => {
      replay_array_fixture(
        document,
        fixture_array(fixture_field(fixture, "operations")),
        scenario,
      )
      assert_array_projection(
        document.list_values("root"),
        fixture_field(expected, "array"),
        scenario,
      )
    }
    "text-unicode-boundary" => {
      assert_eq(
        fixture_string(fixture_field(fixture, "nativeIndexUnit")),
        "unicode-scalar",
      )
      replay_text_fixture(
        document,
        fixture_array(fixture_field(fixture, "nativeScalarOperations")),
        scenario,
      )
      assert_eq(
        document.text("root"),
        fixture_string(fixture_field(expected, "text")),
      )
    }
    _ => fail("unknown upstream Yjs fixture: \{scenario}")
  }
}

///|
test "replay upstream Yjs semantic fixtures" {
  let mut count = 0
  for line in YJS_FIXTURE_JSONL.split("\n") {
    if !line.is_empty() {
      replay_yjs_fixture(@json.parse(line))
      count += 1
    }
  }
  assert_eq(count, 3)
}
