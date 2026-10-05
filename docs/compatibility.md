# Yjs compatibility

Y.mbt targets **semantic compatibility for a small sequential subset** of Yjs. The MoonBit API and the Yjs wire format are not compatibility targets. The native document model remains authoritative and may use different event identities, storage, and conflict resolution.

| Layer | Status | Evidence and boundary |
| --- | --- | --- |
| Semantic values | Partial | Checked-in upstream fixtures compare the final values for sequential map set, overwrite, and delete; array insert and delete; and text insert and delete. The fixtures cover primitive values and text containing emoji. |
| API | Unsupported | MoonBit callers use Y.mbt types and functions. There is no promise to reproduce JavaScript constructors, method signatures, event names, callback ordering, transaction origins, or observer payloads from Yjs. |
| Wire | Unsupported | Yjs document updates, state vectors, snapshots, delete sets, and provider or awareness protocols are not accepted or emitted. Any Y.mbt encoding belongs to its own format and version. |

The semantic fixtures describe single-replica, ordered edits and compare only the resulting logical projection. They do not check concurrent conflict winners, Yjs item identities, event clocks, history, or binary round trips. In particular, passing these fixtures does not imply that concurrent edits converge to the same value as Yjs.

## Supported projection

The fixtures in [`compat/yjs/fixtures.jsonl`](../compat/yjs/fixtures.jsonl) contain an operation sequence and an expected projection captured from upstream Yjs 13.6.32:

- A `Y.Map` is projected with `toJSON()` after setting, overwriting, and deleting keys.
- A `Y.Array` is projected with `toJSON()` after indexed insertion and deletion.
- A `Y.Text` is projected with `toString()` after inserting and deleting plain text. The scenario includes emoji and performs edits at valid character boundaries.

Yjs text positions count UTF-16 code units. Y.mbt text positions count Unicode scalar values, so the fixture records Yjs operations in UTF-16 units and includes `nativeScalarOperations` as the matching native projection. For example, the start of `B` in `A🙂😀B` is UTF-16 index 5 and scalar index 3. The fixture does not test an index inside a surrogate pair.

Map and sequence fixtures use one replica and no concurrent edits. They establish only the listed final values. They do not promise equivalence for nested shared types, text formatting or embeds, XML types, relative positions, event/observer behavior, transaction grouping, undo/redo, garbage collection, or concurrent map and sequence conflict resolution.

## Regenerating fixtures

The fixture generator calls the upstream Yjs API through the JavaScript backend. The exact package version is pinned by [`compat/yjs/package.json`](../compat/yjs/package.json) and [`compat/yjs/package-lock.json`](../compat/yjs/package-lock.json). From the module root, run:

```sh
npm ci --prefix compat/yjs
moon run --target js scripts/yjs-fixtures.mbtx > compat/yjs/fixtures.jsonl
moon run --target js scripts/yjs-fixtures.mbtx --moonbit
moon run --target js scripts/yjs-fixtures.mbtx --check
```

The generated file is JSON Lines: each line is one self-contained scenario with its input operations, source version, and expected projection. The MoonBit black-box tests embed the same JSONL string for target-independent execution. The `--moonbit` mode prints the generated constant block for `compatibility_test.mbt`; replace the block beginning at `const YJS_FIXTURE_JSONL` with that output. The `--check` mode regenerates the fixture and fails if either the checked-in JSONL or the embedded test data differs, so it can run in CI after `npm ci`.
