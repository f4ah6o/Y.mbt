# Benchmark harness and current results

These measurements are a reproducible local baseline, not a release
performance guarantee. Results were collected on **2026-10-06** with MoonBit
0.1.20260920 on macOS 26.5.2, Apple M4 (16 GB), arm64. JavaScript runs used
Node.js v26.8.2. The Wasm GC backend was run through the local MoonBit toolchain.
All three targets ran on the same machine; the numbers are not comparisons
between backends on separate hardware.

The final checkpoint-floor applicability fix landed before this refresh. All
three `moon bench` backend runs and all local-edit samples below use that tree.
The timed event-log and local-edit paths do not apply remote checkpoints; the
compaction workloads create local checkpoints but do not test importing an
unknown lower-order map stamp. The benchmark projection equality checks passed
on all three targets, and the runnable examples passed on all three targets.

## Running

From the module root, run:

    moon test --target native
    moon run --target native examples
    moon bench --target native bench/measure
    moon run --target native bench/local_latency

    moon test --target js
    moon run --target js examples
    moon bench --target js bench/measure
    moon run --target js bench/local_latency
    moon run bench/memory-js.mbtx
    npm ci --prefix compat/yjs
    moon run --target js bench/yjs

    moon test --target wasm-gc
    moon run --target wasm-gc examples
    moon bench --target wasm-gc bench/measure
    moon run --target wasm-gc bench/local_latency

The benchmark package contains white-box tests, so moon bench first checks
the indexed and replay projections for equality and then runs the timed cases.
The CI workflow runs those tests, examples, and benchmark smoke cases for
native, JavaScript, and Wasm GC. It also runs setup-excluded local-edit timing
on all three targets, the live-size heap probe on JavaScript, and the pinned
Yjs candidate after installing its dependency. CI does not enforce latency
thresholds because its runners and load vary.
The Yjs fixture drift check can also be exercised locally with
`moon run bench/check-fixture-drift.mbtx`; it first requires a clean fixture
check to pass, then tests each stale copy independently. The JavaScript runner
reports a generic panic when a MoonBit `Failure` escapes, so these negative
checks assert each isolated mutation produces a nonzero exit rather than
claiming to inspect the hidden failure message.

## Workloads and interpretation

The deterministic offline-branch scenario is defined once in
`bench/workload` and consumed by the MoonBit candidates and Yjs. It creates a
seed document with text, a three-item list, and two map keys. Two replicas start
from the same seed, independently insert and delete text, insert list values,
and race on map values. All benchmark text is ASCII, so scalar indexes in the
native core and UTF-16 indexes in Yjs refer to the same offsets. The three
profiles contain 85, 193, and 373 distinct native events from three replicas.
They have 57, 142, and 283 visible text scalars respectively; each has seven
visible list items and two visible map keys.

The timed indexed case creates a new Document and calls apply_events on the
complete event set. The replay case independently sorts and interprets that
same set into ordinary map-backed event and sequence-node collections, then
projects visible values. The indexed API also clones state for atomic staging,
validates causal dependencies and duplicates, drains pending events, commits
the state, and constructs a change set. There are no observers registered in
this benchmark, so observer dispatch has no callbacks to invoke. Replay assumes
a complete valid log and does not do equivalent validation, pending-event, or
mutable-document work. The benchmark is useful for the cold
materialization decision in [algorithm-decision.md](algorithm-decision.md),
but the ratios are workload timings, not isolated algorithm comparisons or
equivalent end-to-end sync throughput.

The pinned Yjs 13.6.32 candidate receives the same high-level operation trace.
It encodes the seed once and encodes the left and right offline branches as
updates relative to the seed state vector. Stable client IDs (101, 202, and
303) make branch identity reproducible. Its convergence check applies the two
branch deltas in both orders to receivers with the common seed and compares
their visible text, list, and map projection. That is a Yjs-internal
permutation check; it does not assert semantic equality with the MoonBit core.
The output prints both candidate projections and an equality flag so map-winner
or sequence-order differences remain visible.

Yjs cold-merge timing prepares all edits and encoded updates before the timer.
Each sample times creation of an empty `Y.Doc`, application of the seed update
and both branch deltas, and reads of the resulting in-memory projection. It
excludes branch construction, update encoding, and JSON serialization. Yjs
therefore includes update decoding and integration through `applyUpdate`, while
the indexed MoonBit benchmark receives decoded Event values and does causal
validation, atomic staging, pending-event drain, and change-set construction.
This is a candidate-scope comparison on the same logical edits, not an
equivalent protocol-throughput or API-contract result.

The existing “construct + insert/delete” case seeds a new replica with 64 text scalars,
performs one mutation, and reads the result inside each sample. Its timing
includes construction and seed insertion; it does not isolate one operation.
The separate `bench/local_latency` runner prepares a fresh 64-scalar document
before each timed sample, then times exactly one public text insert or delete
using `moonbitlang/core/bench` monotonic-clock timestamps. It uses 10 warmups
and 50 trials per operation and reports the median, mean, and full sample
range. The operation result and visible text length are checked after the
timer. No construction timing is subtracted. These timings describe one
mutation on a 64-event seed, not transaction, observer, or multi-scalar edit
behavior.
“Incremental diff + encode” measures update_since plus native update encoding.
“Full update encode” measures full_update plus encoding. “Construct + merge +
compact” builds an empty receiver, applies the event set, then installs a
checkpoint.

The profile reports logical storage counts from Document.storage_counts():
retained history events, pending events, sequence nodes, and map registers.
“Tombstones” counts deleted sequence nodes in the independent replay
projection. Compaction removes the retained history in these checkpoint-free
scenarios and leaves only visible sequence nodes; it leaves two visible map
registers. The update byte counts are measured encoded payload sizes. They are
not estimates of heap memory.

No per-document RSS or allocator-byte measurements are reported. The current
counter API exposes useful logical metadata counts, but the JavaScript
`heapUsed` probes below are process-level retained-heap samples. They include
the Node/V8 runtime, generated code, benchmark harness, and document arrays;
the reported per-document and per-element deltas are workload approximations,
not exact object sizes. They are sampled after explicit full GC, with documents
kept observable and validated after the post-compaction sample.

The fixed-live history workload holds a 32-scalar text, a four-item list, and
two map keys constant while adding 0, 128, 512, or 2,048 same-value map edits in
one transaction. The edits still produce retained causal events. This varies
history independently of the visible document. The benchmark includes both
construction and compaction in each timed sample, so its timings are
setup-inclusive rather than isolated compaction latency.

The JavaScript heap probe builds eight documents per sample and performs three
trials per history size. It forces a full V8 GC before the baseline, after
building the retained histories, and after compaction. It reads visible values
and storage counters after the post-compaction heap sample so the documents
remain live across that GC. The values below are medians and trial ranges for
`heapUsed` delta divided by eight documents; this division does not isolate
document objects from process, runtime, generated code, or harness memory.

| Same-value edits | History events per document | Retained heap delta per document | Post-compaction heap delta per document |
| ---: | ---: | ---: | ---: |
| 0 | 38 | 76,766 B (76,733–83,574) | 16,830 B (16,484–40,721) |
| 128 | 166 | 293,923 B (287,219–295,089) | 30,722 B (24,335–31,978) |
| 512 | 550 | 897,287 B (891,259–899,674) | 31,630 B (30,318–32,464) |
| 2,048 | 2,086 | 3,296,825 B (3,294,766–3,297,332) | 36,986 B (35,123–37,546) |

The live shape is unchanged across rows (32 text scalars, four list items, two
map keys). After compaction each document has zero retained history events, 36
sequence nodes, two map registers, and a 413-byte encoded checkpoint update.
The heap values are process measurements rather than exact bytes per event or
element; the similar post-compaction medians are evidence that the retained
process heap tracks history in this workload, not a general memory guarantee.

The variable-live-size probe uses equally sized text and list roots (64, 256,
1,024, and 2,048 values per root). For each of three trials, it retains eight
empty documents as a baseline, samples process heap, then adds eight populated
documents and samples again before and after compaction. The baseline-subtracted
delta is the complete added document cohort, including each document's fixed
object overhead as well as its sequence data; the per-element normalization
does not isolate payload bytes. Before compaction each populated document has
one retained sequence event per visible element; after compaction, retained
history is zero while visible sequence nodes remain. The runner warms each
shape once before three measured trials and validates both cohorts after the
post-compaction GC sample.

| Text values per document | List values per document | Combined live elements | History events before compact | Retained delta per live element, including document overhead | Compacted delta per live element, including document overhead |
| ---: | ---: | ---: | ---: | ---: | ---: |
| 64 | 64 | 128 | 128 | 2,043.7 B (2,022.3–2,047.1) | 528.4 B (514.2–533.1) |
| 256 | 256 | 512 | 512 | 1,969.0 B (1,968.8–1,984.4) | 450.5 B (447.0–450.9) |
| 1,024 | 1,024 | 2,048 | 2,048 | 1,957.0 B (1,956.8–1,957.4) | 433.2 B (432.9–434.2) |
| 2,048 | 2,048 | 4,096 | 4,096 | 1,950.8 B (1,950.3–1,950.8) | 429.0 B (428.4–429.4) |

Values are medians and ranges across the three process-heap trials. The delta
is per added populated document cohort relative to eight live empty documents;
the normalized values therefore include each new Document's fixed overhead.
The decreasing per-element estimate as size grows reflects that fixed overhead
is spread over more elements, not a claim about exact sequence-element size.
Compaction clears history but preserves visible sequence nodes in every row.

The same history sizes were also timed on all three backends. Both columns
include document construction; the second also compacts the document. These
samples characterize setup-inclusive scaling under a fixed visible document,
not standalone edit or compaction latency.

| Same-value edits | Native: build / build + compact | JavaScript: build / build + compact | Wasm GC: build / build + compact |
| ---: | ---: | ---: | ---: |
| 0 | 576.84 ± 11.69 µs / 757.66 ± 144.59 µs | 966.62 ± 6.15 µs / 1.17 ± 0.02 ms | 402.26 ± 10.47 µs / 507.20 ± 3.01 µs |
| 128 | 1.36 ± 0.00 ms / 1.60 ± 0.01 ms | 1.87 ± 0.02 ms / 2.24 ± 0.01 ms | 948.70 ± 4.45 µs / 1.14 ± 0.01 ms |
| 512 | 6.92 ± 0.07 ms / 7.54 ± 0.07 ms | 7.21 ± 0.12 ms / 8.12 ± 0.04 ms | 5.05 ± 0.04 ms / 5.46 ± 0.04 ms |
| 2,048 | 88.67 ± 1.25 ms / 91.94 ± 0.96 ms | 77.59 ± 1.48 ms / 86.23 ± 15.68 ms | 58.15 ± 0.54 ms / 59.49 ± 0.30 ms |

For each 2,048-edit case, calibration ran only two operations on all three
targets. Those rows have limited sampling; the other history sizes also show
some noisy compact timings. Treat these as setup-inclusive smoke measurements,
not isolated compaction latency or a general cross-backend performance claim.

## Results

The event-merge and local-mutation timings use five calibrated samples; the
state-vector metadata scan uses ten. Values below are mean ± sample standard
deviation. At each size, the first time is indexed cold merge and the second is
independent replay cold projection.

| Events | Visible text | Native (µs) | JavaScript (µs) | Wasm GC (µs) |
| ---: | ---: | ---: | ---: | ---: |
| 85 | 57 | 270.18 ± 0.72 / 41.44 ± 0.83 | 448.95 ± 3.52 / 50.42 ± 2.08 | 195.74 ± 0.94 / 29.86 ± 0.08 |
| 193 | 142 | 693.86 ± 8.07 / 103.97 ± 1.16 | 1,170 ± 119.99 / 125.36 ± 8.12 | 483.74 ± 8.54 / 76.23 ± 0.80 |
| 373 | 283 | 1,350 ± 15.05 / 210.78 ± 3.67 | 2,130 ± 62.86 / 236.07 ± 3.47 | 1,060 ± 18.65 / 158.26 ± 1.44 |

The pinned Yjs 13.6.32 candidate ran on the same Node.js v26.8.2 runtime as the
MoonBit JavaScript target. It uses the same shared operation trace and stable
client IDs (seed 101, left 202, right 303). Each row's Yjs cold timing is the
median and range of 15 samples after five warmups; it includes a new `Y.Doc`,
three `Y.applyUpdate` calls (seed, left delta, right delta), and in-memory
projection reads. Scenario construction and update encoding are outside the
timer. Update sizes include the seed and the two branch deltas. Every sample
scenario converged under both branch-update orders, and all three final Yjs
projections matched the native projections; no map-winner or sequence-order
difference appeared in these workloads.

| Seed text scalars | Edits per branch | Logical edit calls | Native events | Yjs stored structs | Seed + left + right update bytes | Yjs cold merge + projection median (range) |
| ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 24 | 20 | 58 | 85 | 38 | 90 + 62 + 207 = 359 | 125.250 µs (101.458–401.333) |
| 64 | 48 | 126 | 193 | 74 | 130 + 102 + 436 = 668 | 112.833 µs (102.125–126.291) |
| 128 | 96 | 242 | 373 | 136 | 195 + 174 + 839 = 1,208 | 145.000 µs (140.584–157.625) |

The logical edit-call and native-event columns count different units: Yjs can
group multiple text scalars into one stored struct, while the native core
retains scalar sequence events. The measured cold paths also do different work:
Yjs decodes encoded updates, while native `apply_events` receives decoded
events and performs dependency validation, atomic staging, pending-event drain,
and change-set construction. These workload timings are useful candidate
evidence, not an equivalent throughput comparison or a semantic-compatibility
claim.

For the 64-scalar local-mutation case:

| Target | Construct + insert | Construct + delete |
| --- | ---: | ---: |
| Native | 455.96 ± 4.20 µs | 447.60 ± 3.25 µs |
| JavaScript | 828.35 ± 19.87 µs | 799.40 ± 3.84 µs |
| Wasm GC | 333.28 ± 2.32 µs | 329.10 ± 2.83 µs |

These setup-inclusive measurements include document construction and the
64-scalar seed. They are not isolated edit latency; the setup-excluded samples
below time one public mutation on an already prepared document.

The setup-excluded single-edit runner used 10 warmups and 50 timed trials per
operation. Each trial built a fresh 64-scalar (64-event) text document before
the timer, timed exactly one insert or delete with a monotonic clock, then
checked the result and visible text length after the timer. Values are median
and full sample range in microseconds; no construction time was subtracted.

| Target | Text insert | Text delete |
| --- | ---: | ---: |
| Native | 609.000 (592.292–757.834) | 607.854 (591.166–653.833) |
| JavaScript | 583.750 (543.125–1,166.834) | 558.771 (530.000–1,113.458) |
| Wasm GC | 347.417 (269.375–640.208) | 269.229 (252.625–425.042) |

For the 373-event branch merge, the payload sizes and larger end-to-end
measurements were:

| Measurement | Native | JavaScript | Wasm GC |
| --- | ---: | ---: | ---: |
| State-vector metadata scan | 342.02 ± 8.69 ns | 329.95 ± 31.52 ns | 185.27 ± 3.58 ns |
| Incremental diff + encode | 627.50 ± 9.91 µs | 1.70 ± 0.01 ms | 407.53 ± 8.09 µs |
| Full update encode | 2.17 ± 0.77 ms | 2.88 ± 0.06 ms | 741.94 ± 23.06 µs |
| Construct + merge + compact | 2.17 ± 0.01 ms | 3.72 ± 0.54 ms | 1.53 ± 0.04 ms |

| Size | Full update bytes | Incremental update bytes from seed | Checkpoint update bytes | History events before → after compact | Sequence nodes before → after compact | Sequence tombstones before compact |
| ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 85 events | 6,099 | 4,347 | 605 | 85 → 0 | 71 → 64 | 7 |
| 193 events | 13,910 | 9,678 | 1,115 | 193 → 0 | 167 → 149 | 18 |
| 373 events | 26,976 | 18,776 | 1,961 | 373 → 0 | 327 → 290 | 37 |

The encoded update sizes are identical across these three backends because
they use the same native update format. The compaction rows describe this
particular data shape and do not imply that all retained metadata or every
checkpoint has the same size.
