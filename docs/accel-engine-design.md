# Accelerating omica's rule and query engine

Status: design approved 2026-09-23; Stages 0 and 1 implemented (2026-09-24);
stages reordered after Stage 1 measurements. Work lands on `accel-cuda`, one
branch per stage.

## Why

`mica/kernel/accel` holds working accelerator strategies: a CPU reference, a
multi-core CPU strategy with a SIMD cosine kernel, Metal on Darwin, and a CUDA
prototype on Linux, with resident (prepared) columns and document matrices. The
engine barely uses them. One call site reaches an accelerator
(`try_negated_atom_batch`, `mica/kernel/rules.odin:801`), it rebuilds and
re-sorts its column on every call, and nothing in production selects a strategy
other than the single-core CPU. The benchmarks so far measure operators on
generated data, not omica.

This design wires acceleration into rule and query evaluation so that real Mica
workloads get faster, and so that omica and Rust mica can be compared on the
same workloads with acceleration on and off.

## Scope

In scope, in the engine:

- equality joins between a positive atom's bound positions and a relation
  (Rust mica's operator, generalized beyond two-atom rules);
- negated-atom membership over any fixed-width column of one or two positions
  (Rust mica does not accelerate negation);
- cosine scoring for the `NearestEmbedding` computed relation (Rust mica has no
  cosine operator);
- batched deduplication of derived rows, kept only if measurement shows a win;
- strict semi-naive evaluation, so recursive relations can be packed per round.

Out of scope: GPU sort, consolidate and distinct; string (dictionary) columns;
accelerating guards or ordered comparisons; acceleration inside transactions
that hold uncommitted writes to the relations involved; the build-target
question (portable vs `-microarch:x86-64-v3`), which stays with Ryan.

## What the two engines do today

omica (`mica/kernel`):

- `rules_apply` (`rules.odin:1076`) evaluates a rule body breadth-first. Each
  step receives every current binding as `[dynamic][]v.Binding`, the right
  shape for batching.
- Positive atoms run a nested loop: one `relation_source_visit` per binding. The
  store uses binary search or a secondary index when positions are bound;
  derived rows have no index and are scanned in full for every binding
  (`rules_derived_visit`, `rules.odin:246`), so recursive closures cost
  |bindings| × |derived|.
- Every commit recomputes all derived relations from scratch
  (`kernel_compute_derived`, `kernel.odin:958`).
- A derived relation's rows stop changing when its stratum finishes. During a
  stratum, recursive atoms read the growing result, so evaluation is not strict
  semi-naive.
- `Relation_Block` is immutable and refcounted; unchanged blocks are shared
  across commits. `Secondary_Index` is built lazily under `sync.Once` in the
  block's arena. This is the pattern the packed layer follows.
- For immediate values other than relations, equality on the raw 64-bit word
  matches `value_eq`. Raw-word order is not value order for Int and Float.

Rust mica (`crates/relation-kernel`, `crates/relation-wgpu`):

- `RelationAccelerator` has two operators, `select_membership` and
  `join_equality`, over immutable `Arc<[Value]>` columns. Results come back as
  row indexes or row pairs and are validated before use; any decline falls back
  to an identical CPU path without waiting.
- In production only one shape reaches the GPU: a rule whose body is exactly
  two positive atoms, inside a transaction (packed at ≥256 rows, GPU at
  ≥262,144). Membership is reachable only through the unused `QueryPlan` API;
  negated atoms never reach the accelerator; snapshot materialization runs
  serially; differential joins need an opt-in the driver never sets.
- GPU caches key on `Arc` identity. The snapshot's packed cache resets on every
  commit, so most reuse is lost after a commit.

## Design

### 1. Packed columns (`mica/kernel/packed.odin`)

A packed column is one relation position, or a pair of positions, stored as
raw 64-bit value words. It exists only for fixed-width immediates (Identity,
Int, Float, Symbol, Bool and the other immediate kinds). A column containing any
heap value (String, Bytes, List, Map, Range, Error, Frob, Relation) is not
packable, and its operator runs on the existing row-wise path. Packed columns
serve equality only; guards and ordered comparisons keep using `value_cmp` and
the numeric comparisons.

Each packed column holds:

- for membership: the distinct values, sorted by raw word;
- for joins: the key values sorted by raw word, with the source row index of
  each key.

Packed columns are cached only on data that cannot change:

1. **Stored relations.** On the immutable `Relation_Block`, built on first use
   under a once-guard, allocated in the block's arena and freed with it, like
   `Secondary_Index`. Unchanged relations keep their packed columns across
   commits because blocks are shared copy-on-write. New lazy fields must be
   set in the full struct literal, since frame arenas are not zeroed.
2. **Derived relations.** On a derived relation once its stratum finishes,
   during evaluation and in `snapshot.derived`. A relation still growing in the
   current stratum is packed only per round (see 3).
3. **Transactions with uncommitted writes** to a relation read it row-wise.

A packed column may hold one prepared accelerator handle for the active
strategy (`accel.Prepared`). It is released when the owning block or snapshot
is released (`relation_block_release`, snapshot release), so device memory
follows relation lifetime without a separate eviction scheme.

`accel` sees only `[]u64` slices and prepared handles; no kernel types cross
into it.

### 2. Placement (`mica/kernel/placement.odin`)

One layer between rule evaluation and `accel` decides, per eligible step,
whether to use the accelerator or the CPU:

- **Thresholds per strategy.** A strategy declares its minimum sizes. Initial
  values come from the operator measurements (CUDA membership breaks even near
  8k probes, so it starts at 16k); stage 2 re-tunes them on real workloads.
- **Validation.** Results must have the right length and in-range, ordered row
  indexes. An invalid result is discarded and the step runs on the CPU.
- **No waiting.** A busy accelerator declines. CUDA's operator lock becomes a
  try-lock.
- **Counters.** Every decision is counted by reason (accelerated, below
  threshold, not packable, busy, unsupported, failed, invalid result) and
  readable through a kernel API, so tests and benchmarks can prove what ran.

### 3. Operators in rule evaluation

1. **Negated membership.** Generalizes `try_negated_atom_batch` to any
   fully-bound negated atom of one or two positions over packable values,
   reading its column from the packed layer instead of rescanning. Fixes three
   defects in the current path: the unchecked `source.error` after the scan
   (a negated computed relation lets every binding through), the doubled
   `delete(rows)`, and scratch on scheduler workers' never-reset temp
   allocator.
2. **Batched positive joins.** When a positive atom has bound positions and the
   step's bindings exceed the threshold, the bound positions form one or two
   key columns, probed in one batch against the relation's packed sorted keys.
   The result is (binding, row) pairs; remaining terms unify per pair. Any
   positive step the planner picks qualifies, not only two-atom rules. The CPU
   strategy runs the same batched probe, which replaces the per-binding scan
   for every packed relation.
3. **Strict semi-naive evaluation.** Each round reads the previous round's
   frozen result, so the result can be packed once per round and recursive
   closures use batched joins. Results must be identical to today's; the
   property test against a naive fixpoint guards the change.
4. **Derived-row deduplication.** A batched "which of these new rows already
   exist" check at each rule's head. Kept only if it shows at least a 20% median
   win with no p95 regression on the workloads below.

### 4. Cosine for `NearestEmbedding`

`nearest_embedding_scan` (`mica/runtime/retrieval_computed.odin`) now does two
scans per index member and scores in f64. The accelerated path:

- packs, per vector index, an f32 matrix of member vectors and a subject column.
  The cache key is the index plus the blocks of `VectorIndexContains`,
  `EmbeddingOf` and `EmbeddingVector`; the cache holds references to those
  blocks so the key cannot be reused. A small cache (a few indexes) owns any
  prepared matrix. A transaction with uncommitted writes to those relations
  uses the existing path;
- scores with the strategy's `cosine_queries`, resident when supported;
- preserves current semantics: zero-length and non-numeric vectors are skipped
  (not scored 0), each subject keeps its best score, ties break by subject
  order, scores are returned as f32;
- takes the top `limit + 32` by f32 score, re-scores those in f64 exactly as
  today, then sorts and cuts. Results match today's unless f32 error exceeds
  the gap to candidate `limit + 32`.

### 5. Configuration

- `World_Config.accel`: `cpu` (default, the reference), `cpu-parallel`,
  `metal`, `cuda` or `auto` (a usable GPU, otherwise `cpu-parallel`), plus
  `accel_workers`. Applied in `world_start` before `scheduler_init`. A GPU mode
  whose device is unusable, or absent on the platform, falls through to
  `cpu-parallel` with a logged warning; a world never fails to start over its
  accelerator. The zero value leaves the process-wide strategy unchanged, so
  worlds that do not ask for one never reset another's.
- `--accel` in `tools/filein`, `tools/micabench`, `tools/webhost` and
  `tools/repl`; `micabench --accel-report` prints placement counts after a run.
- `cpu-parallel` moves from per-call thread creation to a persistent worker
  pool created in `world_start`. This removes the intermittent Linux
  thread-creation failure and the per-call start-up cost.
- Diagnostics go through `core:log`.

## Workloads and comparison

1. **OpenCyc taxonomy (bycycle).** `tools/bycycle-export` writes loaded OpenCyc
   facts as a Mica fact file, plus a copy of the ontology that Rust mica's
   parser accepts (no `_` in rule bodies; no relation named `Arity`, which is
   built into Rust mica). Sizes: 20k, 60k and all 242k subjects. The corpus
   exercises the `Subsumes`/`InstanceOf` closure, the three-atom
   `InconsistentWith` join, and a single-argument negation over a large derived
   relation. It measures rederivation after a commit and query time.
2. **Retrieval.** `apps/shared/retrieval.mica` over embeddings of OpenCyc labels
   and comments: from ndn's llama.cpp server if it serves embeddings, otherwise
   deterministic embeddings (a mode Rust mica's runner already has). Only omica
   accelerates cosine, so this compares omica accelerated against Rust mica on
   CPU.
3. **Regression guards.** `kernel_large` (80k-row closure), `visible_items_rule`
   and the `benchmarks/mica` corpora.

Matrix: omica `cpu`, `cpu-parallel`, and `cuda` (ndn) or `metal` (Mac), against
Rust mica `filein` (serial) and `bench` (driver selects wgpu), on both machines.
The RTX 3090 on ndn hosts a llama.cpp server and stays excluded. Every omica
result carries its placement counts; Rust mica's use its metrics. Results update
the published benchmark page.

## Testing

- Unit: packed-column encoding and rejection of heap values; the placement
  layer with a fake strategy that returns invalid results (falls back, counts
  the rejection); each operator against the row-wise path.
- Property: the random-program test against a naive fixpoint gains negation and
  runs under every strategy, requiring identical derived relations. It also
  guards strict semi-naive evaluation.
- Cosine: randomized comparison with the f64 path.
- Integration: every bycycle size under every `--accel` value produces identical
  result digests.
- Concurrency: ThreadSanitizer on the Mac; the full suite on ndn with
  `MICA_REQUIRE_CUDA=1`. ndn lacks the TSan runtime (`libclang-rt-18-dev`).

## Stages

Each stage is its own commit series with its own tests.

| Stage | Contents |
|---|---|
| 0 | Done. `World_Config.accel` and flags, persistent worker pool, placement counters, fixes to the negated-atom path. |
| 1 | Done. Packed keys (cached per evaluation, not per block: see Stage 6); negated membership over one or two positions of fixed-width values. |
| 2 | Derived-row deduplication and binding copies: the two largest measured costs of an evaluation (below). CPU first; accelerated where a strategy measurably wins (≥20% median, no p95 regression). |
| 3 | Batched positive joins (CPU and accelerated); thresholds tuned on real workloads. |
| 4 | Strict semi-naive evaluation with per-round packing. |
| 5 | Cosine for `NearestEmbedding` with f64 re-scoring. |
| 6 | Faster GPU operators: a matrix-multiply cosine kernel (today one thread per query–document pair, no data reuse); packed keys and prepared device copies cached on immutable `Relation_Block`s across commits (deferred from Stage 1); Metal two-key membership and residency; thresholds from measurements; overlapping copies with compute. `accel/scale` and `kernel/rules_accel` track operator and engine speed throughout. |
| 7 | Exporter, corpora, comparison against Rust mica, page update. |

### Why deduplication moved up (Stage 1 measurements)

Whole-evaluation benchmarks (`kernel/rules_accel`, identical derived rows under every strategy):

| Workload | Mac M3: cpu / cpu-parallel / metal | ndn 7800X3D + RTX 4070 Ti: cpu / cpu-parallel / cuda |
|---|---|---|
| `visible_items_rule` (two-position negation) | 7.3 / 7.4 / 8.0 ms (Metal declines two-key) | 12.1 / 12.2 / 12.1 ms |
| 262k-item negation | 79.5 / 76.3 / 74.3 ms | 139.8 / 134.9 / 134.4 ms |

A sample of the single-core 262k evaluation puts the membership probe at about 6% of active time. Derived-row deduplication (`rules_derived_add` and the map inserts and resizes it causes) takes about 43%, `memmove`/`memcpy` of binding vectors and growing arrays about 33%, and arena allocation about 13%. Faster operators cannot move an evaluation much until those costs fall, so Stage 2 takes them first; the GPU operator work stays on the roadmap as Stage 6.

## Relation to other work

- The packed column layer overlaps the columnar projection the code assigns to
  Ryan (`rules.odin:797`, `accel.odin:9`). It is built here, scoped to what
  acceleration needs, and offered to Ryan as a candidate for that projection.
- Rust mica's design notes (`sketches/DIFFERENTIAL_RELATION_MAINTENANCE_DESIGN.md`)
  record a threshold rule worth keeping: no default GPU enablement until the GPU
  shows at least a 20% median win with no p95 regression on real workloads.
