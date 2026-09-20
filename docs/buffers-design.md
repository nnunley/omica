# Buffers for Mica

Status: implemented through M7, plus whole-buffer reversion and the change-feed
buffer variant. M0 (semantics), M1 (piece
tree), M2 (transactional integration, atomic creation, conservative conflict),
M3 (persistence), M4 (the client revision contract including completion results
and feed integration), M5 (span merging), and M6 (the Mica surface and lifecycle)
are implemented and tested. Buffer content is durable across a restart through
the log record, the checkpoint page, and compaction; `buffer_revert` splices a
retained earlier revision back in as a whole-buffer replacement over fresh
chunks; observers follow a buffer through the change feed; and
`apps/shared/buffers.mica` provides markers, annotations, and revision-checked
rebasing. The runtime registry provides `BufferStat`, bounded `BufferLine`, and
bounded `BufferMarkers` scans. These computed rows are visible to rules but are
not stored facts. See `mdbook/src/runtime/buffers.md` for the reader-facing
summary.

This document specifies **buffers**: durable, transactional text objects that
share Mica's transactional substrate with relations without being relations.

A buffer is a **catalogue entry with an out-of-line text backend**. Its text is a
persistent, balanced piece tree over immutable, reference-counted text chunks,
shared structurally across snapshots the way a relation's `Relation_Block`
shares chunks. Edits address the **current transaction view** and staging keeps a
private root, so reads are root reads. Commit derives a base-relative delta from
**piece provenance**, not from a content diff. Conflict is a provenance merge
bounded by an explicit work budget. Relations and buffers are written in **one
atomic record per published version**, and creating a buffer with its initial
content and metadata is **one transaction**.

## Motivation

Mica has a durable relational world with snapshot isolation, structural sharing,
and bounded reclamation, but no efficient mutable text: textual values are
immutable `string`s, so an edit is a full copy, and the only durable text
container is a relation tuple, which sorts, hashes, and deep-copies its columns.

That rules out an in-world editor whose buffers are world state, shared document
editing, and any large text artefact kept as versioned, inspectable state. A
workaround using ordinary relations fails on edit cost, render cost, or conflict
granularity. Buffers address all three, at the cost of a second kind of catalogue
entry.

## Goals

- **Transactional.** Edits commit atomically with relation writes, including the
  creation of the buffer itself. Invisible until commit.
- **Isolated.** A reader on a snapshot sees one consistent text version.
- **Structurally shared.** An edit copies O(log N) structure, not O(n) text.
- **Durable or volatile**, per entry.
- **Shared.** Stale clients are rejected by revision, not silently misapplied.
  Concurrent edits merge or conflict by an explicit, testable rule, within a
  bounded work budget.
- **Bounded.** Reclamation follows snapshot lifetime; reconciliation work is
  budgeted and fails loudly rather than running long.
- **Honest.** A buffer presents as a buffer: sequence semantics, builtins, and an
  explicit projection when a relation-shaped view is wanted.

## Non-goals (for the first versions)

- **Not a value type.** Referenced by stable id, never copied into tuples.
- **No unbounded text relation.** Rules can use explicit bounded projections,
  but they cannot range over raw buffer content.
- **No selective undo.** Whole-buffer reversion only, implemented as a splice.
- **No CRDT.** Span merging is provenance-based transform over a common base, not
  convergent replication. Same-position concurrent inserts conflict.
- **No file I/O, no syntax awareness, no rendering or keybindings.**

## What a buffer is not

A relation is an arity-fixed **set of tuples** with a declared heading, set
semantics, and rule derivation. A buffer is a **sequence of Unicode scalars**:
order is the content, duplicates are meaningful, equality is sequence equality.

| | Relation | Buffer |
| --- | --- | --- |
| What it is | Set of tuples over a heading | Sequence of Unicode scalars |
| Order | Meaningless | The content |
| Duplicates | Collapse | Meaningful |
| Domain operations | select, project, join, union | splice, offset, span scan |
| Derivation | Rules over stored facts | None; builtins only |
| Storage | Sorted immutable chunks | Persistent piece tree over text chunks |
| Rule-readable | Yes (stored, derived) | Only through a computed projection |
| Transaction, snapshot, durability, authority, change feed | Shared | Shared |

The last row is the whole of the commonality: same transaction manager, same
world, different concept. A relational representation of text was available (one
fact per line) and was rejected because splice and offset access are not
relational operations and the tuple store rebuilds a chunk per change.

**The claim is about the text, not about everything a document needs.** Facts
*about regions* of a buffer — spans, annotations, markers — are relation-shaped
and belong in relations; see [Regions, Annotations, and
Markers](#regions-annotations-and-markers). Read this section as "a buffer's
*content* is not a stored or freely enumerable relation", not as
"nothing associated with a buffer may be relational". The sharpest form of the
claim: **the buffer holds exactly the part of a document that cannot be
relational, and that is why it is a buffer.**

## What already exists

| Component | Location | What it gives a buffer backend |
| --- | --- | --- |
| Immutable refcounted nodes | `mica/kernel/store.odin` (`Relation_Chunk`) | The node lifetime pattern: `refs`, monotonic generation, retain/release, pooled storage. |
| COW structural sharing | `mica/kernel/store.odin` (`Relation_Block`) | Share everything outside the changed range. |
| Snapshot fork/retain/release | `mica/kernel/snapshot.odin` | One parallel array plus the same three calls. |
| Hazard / RCU reclamation | `mica/kernel/kernel.odin` (`reader_slot_*`, `kernel_retire`, `kernel_reclaim`) | Retired roots free only when no reader window pins them. |
| Transaction staging, rebase, retry | `mica/kernel/transaction.odin` (`Relation_Writes`, `transaction_rebase_in_place`, `transaction_build_candidate`) | The conflict-and-retry loop buffers plug into. |
| Validate-fork-publish | `mica/kernel/kernel.odin` (`kernel_try_publish`, `kernel_publish_group`) | One snapshot per batch — and the aggregation point buffers must join. |
| Conflict policy, durability | `mica/kernel/relation.odin` (`Conflict_Kind`, `Relation_Durability`) | New buffer kinds slot in beside `Set`/`Functional`/`Event_Append`. |
| Persistence hooks and WAL | `mica/kernel/persist.odin` (`Store_Hooks`), `mica/store/wal.odin` (`Wal_Record`, which already carries a `catalog` section) | A record field; staged catalogue changes ride the existing section. |
| Checkpoint | `mica/store/checkpoint.odin` (`store_checkpoint_internal`, `store_page_append`, `Manifest_Data`) | A page kind and a manifest section. |
| Change feed | `mica/kernel/changes.odin` (`Change_Record`, `changes_visit`) | Deltas broadcast through the same bounded window. |
| Sampled scalar offset index | `mica/var/heap.odin` (`Heap_String.index`, `String_Index`) | Reusable per-chunk scalar→byte index. |
| Scalar-indexed strings | `mica/runtime/builtins.odin` (`builtin_string_len`, `builtin_string_slice`) | Positions are Unicode scalars; buffers must match. |
| Authority | `mica/kernel/authority.odin` (`authority_relation_by_name`, `authority_can_invoke_builtin`) | Grants name an entry, resolved to its id at mint time. |
| Catalogue facts | `mica/runtime/runtime.odin` (`Relation`, `RelationName`, `RelationDurability`) | The registry buffers join. |

**Computed-relation prerequisite: complete.** The kernel registry stores a
scanner and its required bindings for each computed relation. Scans use the
current snapshot or transaction view. Computed relations are read-only, and
missing required bindings raise `E_DB`. Rule planning delays a computed atom
until earlier atoms bind its required inputs. The runtime now registers the
buffer projections and the exact `NearestEmbedding` implementation.

## Data model

### Catalogue entries

```odin
// mica/kernel/relation.odin (proposed; see Naming for the rename sweep)
Catalog_ID :: distinct u32

Durability :: enum { Durable, Volatile }

Tuple_Schema :: struct {
    arity:          u16,
    argument_names: []v.Symbol,
    indexes:        []Index_Spec,
}

// Empty in v0. Reserved for per-buffer settings that must not be relation
// fields (line-ending policy, chunk target size).
Buffer_Schema :: struct {}

Storage :: union {
    Tuple:  Tuple_Schema,
    Buffer: Buffer_Schema,
}

Conflict_Kind :: enum {
    // Relations
    Set,
    Functional,
    Event_Append,
    // Buffers
    Reject,  // any concurrent content change conflicts (M2 default)
    Span,    // provenance merge; disjoint base ranges merge (M5)
    Whole,   // last-writer-wins. Destructive; opt-in only.
}

Conflict_Policy :: struct {
    kind:          Conflict_Kind,
    key_positions: []u16,   // relations only
}

Catalog_Entry :: struct {
    id:         Catalog_ID,
    name:       v.Symbol,       // immutable creation-time identity
    durability: Durability,
    conflict:   Conflict_Policy,
    storage:    Storage,
}
```

The discriminated union means "arity" does not exist for a buffer rather than
existing and being ignored. `validate_catalog_entry` rejects mismatches.

### Identity, revision, epoch, and generation are four different things

| Concept | Lifetime | Purpose |
| --- | --- | --- |
| `Catalog_ID` | Stable, never reused, persisted | Identifies the buffer forever. References, authority, WAL all use it. |
| Entry `name` | Fixed at creation, persisted | Catalogue lookup and authority resolution. Immutable; the *display* name is a fact. |
| `Buffer_Revision` | Monotonic per buffer, persisted | **Content** revision. Client `expected_revision` and WAL base checks use it. Bumped once per accepted content-changing transaction; **not** by compaction. |
| `Structure_Epoch` | Monotonic per buffer, persisted | Bumped by compaction, and by a reversion because it too publishes fresh chunks. Labels the chunk lineage of the current root; provenance does not compare across it. |
| `Node/Chunk_Generation` | Process-local, may reset | Checkpoint page-cache identity only. Never exposed to clients, never a revision. |

### Text ownership: chunks and the ownership graph

Text is owned by **immutable, reference-counted, bounded text chunks**; pieces
reference chunks directly. Staging creates chunks as it edits; there is no
separate pending-bytes representation.

```odin
// mica/kernel/buffer.odin (proposed)
CHUNK_TARGET_BYTES :: 64 * 1024   // compaction/batching target, not a minimum
NODE_FANOUT        :: 16

Chunk_Kind :: enum { Original, Added }

// Immutable once published: bytes never move, grow, or mutate.
Text_Chunk :: struct {
    refs:       i32,
    id:         u64,               // stable identity; provenance compares this
    kind:       Chunk_Kind,
    bytes:      []u8,
    scalars:    u64,               // cached scalar count
    lines:      u64,               // cached newline count
    index:      ^v.String_Index,   // sampled scalar->byte offsets
    generation: u64,               // checkpoint page identity (process-local)
}

// A run of scalars inside one chunk. Provenance is (chunk, start, length).
Piece :: struct {
    chunk:  ^Text_Chunk,
    start:  u64,
    length: u64,
}
```

```
Snapshot
 └── buffers[]                     (retains)
      └── Buffer_Block              (retains)
           └── root: ^Piece_Node    (retains children; leaves retain chunks)
                ├── internal ^Piece_Node
                └── leaf ^Piece_Node
                     └── Piece ──► ^Text_Chunk   (immutable bytes)
```

Lifetime rules:

- **Published chunks never move, grow, or mutate.** A span visit borrows bytes,
  valid while the caller holds a retained root, which retains the chunk.
- **Staging creates chunks immediately.** Applying an edit to the private root
  creates an `Added` chunk for the inserted text and splices a piece referencing
  it. Abort releases the private root, which releases those chunks; successful
  publication retains them. The private tree always references real, immutable
  chunks: one piece representation, one lifetime contract.
- **Chunk byte storage is size-classed.** `CHUNK_TARGET_BYTES` is a target for
  compaction and batching, never a minimum allocation. A one-scalar insert gets a
  one-scalar chunk from a small size class (for example 16/32/64/…/64 KiB), so
  per-insert allocation is cheap and memory is not wasted. Character-at-a-time
  editing therefore creates many small chunks, which compaction folds; a
  transaction-local batching chunk is a later optimization, not a prerequisite.
- **Old roots keep their own chunks.** Compaction creates new `Original` chunks;
  old roots retain the old ones by refcount, so old text stays readable.
- **Readers need no protection from writers.** Writers only append new chunks.
- **Piece nodes are not arena-per-node.** A per-node `Frame_Arena` would start at
  `FRAME_DEFAULT_BLOCK_SIZE` (64 KiB, `mica/kernel/frame.odin`). Nodes are
  fixed-size slab objects from a per-kernel free list; only chunks own byte
  storage, from the size-class pool above.

### The piece tree

A **persistent, balanced B-tree of fixed-capacity nodes**. Balancing is a
required invariant: `scalars` and `lines` give O(log N) descent only while the
tree stays balanced.

```odin
Piece_Node :: struct {
    refs:     i32,
    leaf:     bool,
    count:    u16,
    scalars:  u64,                          // cached subtree scalar count
    lines:    u64,                          // cached subtree newline count
    pieces:   [NODE_FANOUT]Piece,           // when leaf
    children: [NODE_FANOUT]^Piece_Node,     // when internal
}
```

- Immutable after publication; an edit path-copies root to leaf and retains
  untouched subtrees. Overflow splits; underflow merges. Occupancy is bounded
  below, so depth is O(log N).
- **Retain is O(1). Release is O(j)** where j nodes reach zero refcount, and it
  is **iterative with an explicit stack**, not recursive.
- **Coalescing rule:** adjacent pieces merge only when contiguous in *both* view
  and base order within the *same* chunk. Merging across chunks would destroy
  provenance.
- **Byte localization inside a chunk** uses the chunk's sampled `String_Index`
  (the structure `mica/var/heap.odin` already builds for long non-ASCII
  strings). Newline location inside a chunk uses a bounded ≤64 KiB scan, or an
  analogous sampled index if profiling asks for it.

```odin
// Yields a borrowed string per run, valid while the root is retained.
buffer_visit_spans :: proc(
    root: ^Piece_Node,
    start, end: u64,
    visit: proc(user: rawptr, text: string, offset: u64) -> bool,
    user: rawptr,
)
```

### Coordinates

**Builtin offsets address the current transaction view**, never the base version.

```odin
Buffer_Edit :: struct {
    at:     u64,     // scalar offset in the CURRENT VIEW
    remove: u64,     // scalars removed at `at` in the current view
    text:   string,  // scalars inserted at `at`
}

Buffer_Writes :: struct {
    entry: Catalog_ID,
    edits: [dynamic]Buffer_Edit,   // application order; view-relative
}
```

Staging maintains a **private persistent root** seeded from the base root; each
edit applies by path copy, creating chunks as needed. Therefore reads during
staging are root reads (no overlay, no quadratic edit/read loop); an edit
touching text inserted earlier in the same transaction is expressible directly;
and an abandoned transaction releases the private root and its chunks.

### The base-relative delta is provenance, not content

Conflict and persistence need a **base-relative** description. Deriving it from
text content is ambiguous: `"aaa" → "aa"` could mean deleting any of three
positions, and the choice determines whether another edit overlaps.

Provenance removes the ambiguity. Every piece records `(chunk, start, length)`,
and a chunk created during this transaction is distinguishable from one inherited
from the base. Splices only insert and remove — they never reorder base material
— so pieces referencing base chunks appear in increasing base order, and a single
walk of the private root yields a deterministic, normalized delta:

- a run of pieces referencing **retained base material** → base interval retained;
- a run of pieces referencing transaction chunks → an **insertion** at the base
  position between the surrounding retained runs;
- base material present in `R0` and absent from the private root → a **deletion**.

**Retained material is defined by base interval, not by chunk identity alone.** A
piece is retained base material only if the base actually contains that
`(chunk, start, length)` interval. Referencing a chunk the base also used, but at
an interval the base did not contain, is not retention. Under pure splices this
holds automatically, because an edit can only shrink a base interval or introduce
a new chunk; the rule matters for reversion, below.

Coalescing (above) preserves provenance, so the walk is exact. `"aaa" → "aa"`
illustrates why this matters: deleting view `[0,1)` leaves a piece `(C,1,2)`, and
comparing against the base's `(C,0,3)` gives *deletion of base `[0,1)`*; deleting
view `[2,3)` leaves `(C,0,2)` and gives *deletion of base `[2,3)`*. A content
diff cannot distinguish these; provenance can, and the difference changes which
concurrent edits conflict.

**Identity pruning is an optimization, not the semantics.** When two subtrees are
the same node pointer, the walk skips them wholesale. That makes the common case
cheap; it does not define the answer, and it does not bound the worst case.

#### Worked history 1 — edit to newly inserted text

Base `"abc"`, one chunk `C` with piece `(C,0,3)`.

1. `buffer_insert(b, 0, "XY")` — view `"XYabc"`; a new chunk `D` holds `"XY"`.
2. `buffer_delete(b, 1, 1)` — removes the `"Y"`; the piece for `D` becomes
   `(D,0,1)`.

The walk yields one base-relative replacement: **insert `"X"` at base 0**. The
transient `"Y"` never appears, and conflict sees one edit.

#### Worked history 2 — appended text plus a base replacement

Base `"abc"`.

1. `buffer_insert(b, 3, "Z")` — view `"abcZ"`.
2. `buffer_replace(b, 0, 1, "A")` — view `"AbcZ"`.

Normalized: **replace base `[0,1)` with `"A"`** and **insert `"Z"` at base 3** —
disjoint in base coordinates, merging independently.

## Conflict follows provenance

At rebase a transaction holds `R0` (its base root, alive because it retains its
base snapshot), `R1` (the winner's root), and `Rp` (its private root). Footprints
come from the provenance walk: `Dp` walks `Rp` against `R0`; `D1` walks `R1`
against `R0`, where pieces referencing intervals present in `R0` are retained
material and everything else is a change. No retained edit log is required, so
change-feed eviction cannot affect correctness.

### Epochs and the resulting root

Compaction creates new `Original` chunks without changing content, which
destroys provenance: after it, `R1`'s pieces no longer reference `R0`'s chunks.
`Structure_Epoch` makes this explicit. Crucially, the epoch constrains the
**published result**, not merely permission to merge — a root published under an
epoch must carry that epoch's chunk lineage.

| `R0.revision` vs `R1.revision` | `R0.epoch` vs `R1.epoch` | Action |
| --- | --- | --- |
| equal | equal | The winner did not touch this buffer. `Rp` is publishable as built. |
| equal | differ (compaction only) | Content is identical, so `Dp` is transform-free, but **re-apply `Dp` onto `R1`** and publish under `R1`'s epoch. **Do not publish `Rp` directly**, which would inject pre-compaction provenance into the new epoch. |
| differ | equal | Provenance merge: walk, conflict-check, transform, apply. Rebase-budgeted. |
| differ | differ | Provenance cannot compare across the compaction boundary. **Conflict.** |

In the second row, base coordinates map one-to-one onto `R1` coordinates because
the content is identical, so re-applying `Dp` is a direct scalar-offset splice.

**Compaction validates before publishing.** Compaction is a normal transaction
following validate-fork-publish: it builds a re-chunked candidate from its base
root and publishes only if that base is still current, rebuilding from the new
root otherwise. It never force-publishes. It preserves the logical revision
precisely because it verified the base revision at publication time; if a
concurrent edit landed, it retries and re-chunks the newer content.

**Compaction is the transaction's only change to the buffer.** It describes
committed content, so combining it with a staged edit would either discard that
edit with the old root or publish a content change under the revision compaction
preserves, leaving the revision un-advanced for a real change. It is therefore
refused with `E_STATE` on a view that already has staged changes, and it seals
the view so a later `buffer_insert`/`buffer_apply`/`buffer_revert` on the same
buffer in the same transaction is refused too. `buffer_compact` on a buffer
created by the same transaction is a no-op that leaves the view open, because
such a buffer's content already lives in fresh chunks.

Merging across an epoch boundary would need a content diff with defined canonical
semantics. That is explicitly not provided: the boundary conflicts.

### Boundary and overlap rules

Base-relative edits `A = (s1,e1,t1)`, `B = (s2,e2,t2)`; `A` is a pure insert when
`s1 == e1`.

| A \ B | insert at q | delete `[s2,e2)` | replace `[s2,e2)→t2` |
| --- | --- | --- | --- |
| **insert at p** | conflict iff `p == q`; else both apply, ordered by position | conflict iff `s2 < p < e2`. `p == s2` stays before; `p == e2` stays after | same as delete |
| **delete `[s1,e1)`** | symmetric | conflict iff `s1 < e2 && s2 < e1` | same as delete |
| **replace `[s1,e1)`** | symmetric | same as delete | conflict iff `s1 < e2 && s2 < e1` |

- **Interior overlap conflicts**, in either direction.
- **Boundary insertions do not conflict** and order deterministically: at the
  start of a changed range, before it; at the end, after it.
- **Adjacent ranges do not conflict:** `(1,3)` and `(3,5)` both apply.
- **Same-position inserts conflict.** No hidden tie-break.
- **Identical ranges conflict.**

### Two distinct budget classes

Ordinary edit work and concurrent-reconciliation work are different limits, and
conflating them produces a failure mode that retrying cannot fix.

| Class | Covers | Failure | Caller action |
| --- | --- | --- | --- |
| **Ordinary limits** | Deriving `Dp` against a stationary base, encoded record size, persistence admission | `Buffer_Edit_Too_Large` / `Overloaded` | Split the edit, or raise the configured limit. **Resynchronizing cannot help**: the same snapshot and the same edit fail identically. |
| **Rebase budget** | `D1` walk, transform, and composing the client's authoritative delta against a moving base | `Rebase_Budget_Exceeded` | Resynchronize and resubmit. After resync there is no concurrency left to reconcile, so the retry is genuinely different work. |

A large uncontended paste is an ordinary edit: it is bounded by the ordinary
limits and by persistence admission, and it must never fail with "resynchronize"
merely because producing its own delta is large.

Rebase budgets are checked incrementally and shared across all reconciliation
work a transaction performs. Provisional starting limits, to be benchmarked
before being treated as defaults:

| Rebase budget | Starting limit |
| --- | --- |
| Node/piece comparison steps | 4,096 |
| Text bytes examined | 1 MiB |
| Output delta hunks | 1,024 |
| Output delta allocation | byte cap (measured, not hunk count) |

The budget limits **work performed**, not the size of the result: comparing two
large, equal but independently chunked roots can do substantial work and produce
zero hunks.

`Reject` mode needs no **rebase** budget — it compares logical revisions, with no
`D1` walk and no transform — but it still derives `Dp` and is still subject to
the ordinary limits and to persistence admission.

### Conflict policies

- **`Reject`** (M2 default) — any concurrent content change since `R0` conflicts.
  Conservative, correct, trivially testable, no rebase budget.
- **`Span`** (M5) — the provenance merge above, for entries that opt in.
- **`Whole`** — last-writer-wins over the whole buffer. **Explicitly
  destructive**; opt-in for volatile scratch buffers, never the default.

## Client revision contract

A stale client offset is **not** a transaction conflict. A browser submitting an
offset from revision 41 after revision 42 committed begins a transaction on the
new snapshot, finds nothing to conflict with, and silently edits the wrong
position. The transaction model cannot catch this; the contract must.

The operation is split, because a staging builtin cannot return a committed
result — the commit has not happened, and later code in the same transaction may
edit further or abort.

**Staging operation** (transaction scope):

```
buffer_apply(buffer, expected_revision, edits)
  -> {:status -> :staged}                 // staged; no commit yet
   | {:status -> :stale, :revision -> current_revision}
```

- `expected_revision` is compared against the entry revision visible to the
  transaction's snapshot. A mismatch returns `:stale` and stages nothing.
- **At most one `buffer_apply` per buffer per transaction, and it must be the
  first mutation of that buffer in the transaction.** A matching snapshot
  revision does not make client offsets safe if an earlier builtin already
  changed the transaction view. This is enforced: a second `buffer_apply`, or a
  bare `buffer_insert`/`buffer_delete`/`buffer_replace` on a buffer already
  `buffer_apply`-ed in the same transaction, is rejected with `E_STATE`.
  Server-side handlers that want several edits use the bare builtins only.

**Completion result** (delivered after publication):

```
  -> {:status -> :ok, :revision -> committed_revision, :applied -> authoritative_edits}
   | {:status -> :resync,   :revision -> current_revision}
   | {:status -> :conflict, :revision -> current_revision}
   | {:status -> :aborted}
```

### Preparation happens before publication

Composing the response can fail (epoch crossing, budget exhaustion), and such a
failure must not occur after the edits are durable. The ordering is therefore:

1. `buffer_apply` checks `expected_revision` against the transaction snapshot.
2. Stage edits; build the candidate root; derive `Dp` (ordinary limits).
3. If a winner exists, reconcile (rebase budget; see the epoch table).
4. **Compose and budget-check the authoritative delta relative to
   `expected_revision`, fully materialized.** If this fails, abort: return
   `:resync` and publish nothing.
5. Publish.
6. Deliver the precomposed `:ok` result.

Once publication succeeds, response generation cannot turn the operation into an
uncommitted `:resync`.

### Result semantics

- **`:applied` is expressed relative to the client's `expected_revision`.** With
  span merging, the committed revision's immediate predecessor can differ from
  the client's baseline; a delta against the wrong baseline would corrupt the
  client's state. The server composes concurrent changes and its own transformed
  edits into one delta against the baseline the client knew.
- **`:resync`** means the server could not compose that delta: an epoch boundary
  was crossed, the rebase budget was exhausted, or the client's revision is no
  longer derivable. No edits were applied; the client re-reads the buffer and
  reconciles its unsaved edits locally. Resynchronization must preserve those
  unsaved edits for reconciliation, never silently discard them.
- **`:conflict`** means another transaction changed an overlapping range on the
  same baseline; the client re-reads and resubmits.
- **`:aborted`** means the transaction did not publish for some other reason.

Server-side in-transaction callers (`buffer_insert` and friends) skip the
revision check: their transaction is the writer.

## Transactions, commit, and cost

Staging, per buffer written:

1. Seed a private root from the base `Buffer_Block`.
2. Apply each view-relative edit by path copy, creating `Added` chunks.
3. At commit, coalesce pieces and derive `Dp` by the provenance walk.
4. Build a `Buffer_Block` and `snapshot_set_buffer(candidate, block)`.

`transaction_build_candidate` dispatches on `Storage`. Publication requires the
group-publisher aggregation described under [Persistence](#persistence).

Total commit cost is not just tree construction:

| Component | Cost |
| --- | --- |
| Tree edits | O(m log N) node copies + O(inserted scalars) bytes |
| Ordinary normalization (`Dp`) | Structure-proportional; bounded by ordinary limits |
| Reconciliation (`D1`, transform, result composition) | Rebase-budgeted |
| Snapshot arrays | O(entries) |
| Derived relations | Existing `snapshot_compute_derived` work, often dominant |
| Persistence | Encoded record size |

## Staged catalogue changes and atomic creation

Creating a buffer, its initial content, and its metadata is **one transaction**. A
document's content, ownership, and application metadata are one invariant, and
publishing an empty entry first would introduce partially initialized objects,
orphan cleanup, and awkward crash recovery.

**Transactions can stage catalogue changes**, not just fact and buffer writes.

- A transaction may stage new buffer entries (and, generally, new relation
  entries) together with their text and ordinary relation facts.
- The **creating transaction resolves and uses its new entry immediately**.
- Other transactions see the entry, its content, and its metadata **together at
  publication**.
- **Duplicate names are checked at commit** against the published catalogue,
  under `catalog_lock`. A concurrent creator of the same name is a conflict.
- **Abort publishes nothing.** An allocated `Catalog_ID` that never publishes is
  acceptable: ids are monotonic and never reused.
- Catalogue creation participates in commit locking and in **the same recovery
  unit** — the WAL record's existing `catalog` section carries the staged
  changes alongside `writes` and `buffers`.

`kernel_create_relation` today publishes a catalogue change in its own snapshot,
separately from transaction writes; this generalizes that into a staged
mechanism. The narrow case (create a buffer with content and metadata) lands in
M2, and the mechanism is designed so other schema operations can use it later.

**Deletion** is separate. No catalogue-delete path exists. `kill_buffer` must
retract metadata facts, tombstone the entry so outstanding references fail
cleanly, release storage through normal reclamation, and never reuse the id. That
lands with the Mica surface (M6).

## Persistence

### Durability is per buffer, and it decides only the text

Durability is a per-entry choice, and for a buffer it decides exactly one thing:
whether its **text** is written to the log and checkpoint. Everything else is
unaffected — transactions, snapshot isolation, conflict detection, revisions and
epochs, authority, the change feed, and every builtin behave identically. A
volatile buffer is not a lesser buffer; it is the same buffer with its content
kept out of the log.

The catalogue entry is still persisted for a volatile buffer, so its name, id,
and schema survive a restart while its content does not: the buffer comes back
empty, at revision 0, and the id is still not reusable. This is deliberate — the
entry is world structure, the text is not — and it means "non-persistent buffer"
means non-persistent *content*, never an unnamed or non-existent one.

This is the natural fit for a buffer that mirrors a file. The file is the durable
artifact, so writing the text to the world's log as well creates a second copy
and a second source of truth for a large document. An editor's file-backed
working buffers should therefore be volatile, while a buffer that *is* the
document (a world-owned page, a shared document) should be durable. The
distinction is the application's to draw, because only it knows who owns the
document.

### One atomic record per published version

Relations and buffers written by one transaction recover atomically. The
**existing** `Wal_Record` gains a buffer field, so one record carries everything
and replay applies it as a unit:

```odin
Wal_Record :: struct {
    version:  u64,
    writes:   []Relation_Writes,
    buffers:  []Buffer_Writes,   // new; same record, same atomicity
    catalog:  []Catalog_Change,  // now also carries staged creation
}
```

A `Buffer_Writes` entry encodes `{entry, base_revision, new_revision, edits}`
where `edits` is the normalized base-relative delta, so replay appends the
inserted bytes and applies the splices without re-deriving them. A record whose
`base_revision` does not match the replayed revision is a gap: recovery refuses
rather than guessing.

### Group-publisher aggregation is required

In the batch path, `kernel_publish_group` (`mica/kernel/kernel.odin:587`) forks
one merged snapshot and then calls `kernel_store_persist` **once per constituent
transaction**, passing the same `merged.version` each time. One atomic record per
published version therefore requires:

1. **Aggregating** relation writes (the change feed already does this into
   `merged_writes`) and buffer writes across the batch.
2. Calling `kernel_store_persist` **once** per merged version with the aggregate.
3. **Settling persistence tickets.** Tickets are per-transaction admissions
   (`kernel_admit_persist`); the publisher must release each against the single
   aggregate publish, or convert them into one aggregate ticket for that version,
   without double-counting budget.

This is implementation scope, listed in M3, not a field addition.

### Checkpoint: one representation

**Flattened text**, not preserved structure:

- Walk each durable buffer's current root and re-chunk the text into bounded
  `Original` chunks (target 64 KiB).
- Write chunks as pages (`store_page_append`); record per chunk the page id, byte
  length, scalar count, and newline count.
- Write a `Manifest_Data` buffer section and a `Checkpoint_Entry` buffer shape.
- On boot, read pages into chunks and build a canonical root: one piece run per
  chunk.

Structural sharing is an in-memory property; only the current root's content must
survive. Boot is linear in text size.

**Compaction** is the same operation on the live tree, run as a normal
validate-fork-publish transaction (see [Epochs](#epochs-and-the-resulting-root)):
re-chunk into fresh `Original` chunks, coalesce pieces, publish a new root,
**preserve the logical revision**, and **bump the structure epoch**.

### Admission

Admission counts the **encoded record size**: inserted bytes plus edit overhead
(offsets, lengths, framing) plus relation writes. A deletion-only transaction
still generates durable work (a record, a new root, reclamation) and is admitted
accordingly. Ordinary edit limits and admission are the class that
resynchronization cannot fix; see [budget classes](#two-distinct-budget-classes).

Because admission runs before the base-relative delta exists, a buffer write is
sized from the **material staged for it** — the inserted text of every staged
edit, accumulated as the edit is staged — plus a fixed framing charge per
record. Sizing from the private root instead would charge a whole document for
one keystroke, and sizing from the delta is impossible this early. Editing text
that is later deleted makes the estimate an over-count, which is the safe
direction for a budget. Volatile entries are excluded entirely.

## Change feed, sharing, and rendering

A `Change_Record` carries a buffer variant: `{entry, base_revision,
new_revision, epoch, delta}`. The delta is the committed base-relative change,
deep-copied into the feed like a fact tuple, so an observer can apply it to its
own copy of the text. A compaction is recorded too, with an empty delta and the
new epoch: the content is unchanged, but the lineage move is observable.
Subscribers drain the feed through `changes_visit` and resynchronize from a
snapshot when their cursor leaves the bounded window; for a buffer the
resynchronization is the whole text at its current revision, because a character
sequence cannot be diffed from a window the way a row set can. Clients that
submitted `buffer_apply` receive their result through the completion result; the
feed is for observers.

In the Mica surface a buffer is watched with the `:buffer` subscription subject
against one buffer name:

```mica
let sub = subscribe_changes(sender, :buffer, some(:notes), [], :changes)

// changes:
//   {:kind -> :changes, :subject -> :buffer, :cursor -> V,
//    :changes -> [{:base_revision -> 1, :new_revision -> 2, :epoch -> 0,
//                  :edits -> [{:at -> 5, :remove -> 0, :text -> " world"}]}]}
// resynchronization:
//   {:kind -> :snapshot, :subject -> :buffer, :revision -> R, :text -> "..."}
```

**Rendering locality is not storage locality.** Inserting a newline shifts every
subsequent line index, so many keyed lines change even though the storage change
was small. The storage guarantee is a **bounded window read**: rendering L lines
costs O(log N + bytes in the window), independent of document size. Patch size
depends on rendering structure and stable keys, and is an application concern.

## Authority

Grants name a catalogue entry, resolved to an id when authority is minted
(`authority_relation_by_name`). A buffer occupies a catalogue id, so
`grant role #player write: :notes` resolves and mints exactly as for a relation.

- **Buffer builtins** perform the read and write checks the VM performs for
  relation access. They are the only new read/write authority call sites.
- **Builtin invocation** is gated by name through `authority_can_invoke_builtin`.
- Because entry names are **immutable**, minted authority cannot be invalidated
  by a display-name change.

Per-buffer granularity is the v0 target; per-span authority is out of scope.

## Language surface

```
// Creation, content, and metadata commit as one task/transaction.
verb create_notes()
  let b = make_buffer(:notes, :durable)
  buffer_insert(b, 0, "hello")
  assert BufferOwner(b, #alice)   // application metadata
  return b
end

buffer_replace(:notes, 0, 5, "goodbye")

match buffer_apply(:notes, expected_revision, [{:at -> 88, :remove -> 0, :text -> "!"}])
  case {:status -> :staged}   // then commit
  case {:status -> :stale}    // re-read and retry
end

for line in buffer_lines(:notes, 0, 40)
  render(line)
end
```

| Builtin | Contract |
| --- | --- |
| `make_buffer(name, durability[, conflict])` | Stage a new buffer entry (usable immediately); the optional third argument selects `:reject` (default), `:span`, or `:whole`. |
| `kill_buffer(buffer)` | Tombstone and release; the id and name are never reused. |
| `buffer_len`, `buffer_line_count` | O(1) counts. |
| `buffer_slice(buffer, start, end)` | String; O(log N + k). |
| `buffer_insert/delete/replace` | Stage a view-relative edit. |
| `buffer_apply(buffer, expected_revision, edits[, token])` | Revision-checked staging; with a token, records a completion readable by `buffer_apply_result`. |
| `buffer_apply_result(token)` | `:pending`, or a map with the committed revision and authoritative delta, or `:resync`/`:aborted`. |
| `buffer_revision(buffer)` | Current logical revision. |
| `buffer_text(buffer)` | The whole content, for tests and small buffers. |
| `buffer_compact(buffer)` | Re-chunk into fresh chunks; preserve revision, bump epoch. Must be the transaction's only change to the buffer. |
| `buffer_revert(buffer, revision, expected_revision)` | Whole-buffer splice from retained history; `:staged`, `:stale`, or `:unknown`. |
| `buffer_marker_rebase(edits, position, insertion_type)` | Pure helper: a position moved through a committed delta; `:stick_after`/`:stick_before` decides the insertion tie. |
| `buffer_find(buffer, pattern, from, limit)` | Scalar offset of the next occurrence within the window, or `none`. |
| `buffer_lines(buffer, first, count)` | Relation value `[:buffer, :line, :start, :stop, :text]` of line spans; the range is required, so there is no whole-buffer line scan. |
| `buffer_visit_spans(buffer, start, end, fn)` | Host-facing run iterator (`tree_visit_spans`). |

## Undo and reversion

Retained roots make the text of an earlier revision readable, which is what
reversion needs. In a shared buffer, reverting is **destructive**: it discards
every edit committed since, including other users'. It is therefore a distinct,
separately authorized operation, never the same as "undo my last change."

**Reversion is a whole-buffer splice, not adoption of a historical root.**
`buffer_revert(buffer, revision, expected_revision)` reads the text at
`revision`, checks `expected_revision` against the current revision, and stages a
single replacement of the entire buffer with **fresh chunks**. Reasons:

- Adopting an old root would resurrect chunk intervals absent from the
  transaction's base, violating the retained-material rule and producing a
  meaningless delta.
- Adoption would also inject an older epoch's lineage into the current epoch.
- A whole-buffer splice with fresh chunks stays inside the splice model, needs no
  lineage or epoch contract, and produces an ordinary, conflict-checkable delta.

Direct historical-root adoption would require a separate lineage contract and is
explicitly not provided.

**The target text comes from a bounded retained history.** The kernel keeps a
per-buffer ring of recent published versions, newest last, retaining them by
refcount (`BUFFER_HISTORY_DEPTH`, 32 versions per buffer, with a global cap on how
many buffers retain any). Retaining a version is O(1), and a version that falls
out of the window is released to the ordinary chunk and node pools. A reversion
looks the target up by revision, reads its text, and rebuilds it; a revision
outside the window — or newer than the one in hand — is refused rather than
approximated, and reverting to the revision in hand is a no-op that burns no new
revision. Compaction republishes a revision under a new epoch, so the ring keeps
at most one block per revision and resolves it to the freshest lineage.

The window is **process-local** and is rebuilt from the records replay applies,
so after a restart it reaches back only as far as the log still holds: a
checkpoint flattens content to its latest version and does not preserve prior
ones. Persisting the window, and whether it should instead be an
application-driven history, remains open.

Because reversion replaces the view wholesale it is only meaningful before
anything else has been staged for that buffer in the transaction — a bare edit
first is refused with `E_STATE` — and, like `buffer_apply`, it locks the view for
the rest of the transaction. Reverting is its own builtin, so a world can grant
it separately from ordinary writes (`CanInvoke`/`RoleCanInvoke`); it also needs
write authority on the buffer.

**Selective undo** — inverting one user's edit while preserving later edits —
requires inverse-edit transformation and is **explicitly out of scope**.

## Architecture

```
   Mica source (verbs, rules, authority, metadata facts)
                 │ builtins                    │ buffer_apply (revision-checked)
                 ▼                             ▼
   transaction ── private root (chunks created as it edits)
                 │                             │
                 │        Dp vs R0 (ordinary limits)
                 │        D1 vs R0 (rebase budget, same epoch only)
                 ▼                             ▼
   reconcile ── same epoch → transform;  equal revision + new epoch → reapply Dp
                 │                        different epoch → conflict
                 ▼
   candidate Buffer_Block ──► kernel_publish_group
                                   │  aggregate writes+buffers, ONE persist call
                                   ▼
        Snapshot{blocks, buffers} ──► readers (lock-free, hazard)
                                   │
                                   ▼
        Store_Hooks: one Wal_Record{version, writes, buffers, catalog}
```

New modules: `mica/kernel/buffer.odin` (chunks, nodes, tree ops, span visit),
`mica/kernel/buffer_provenance.odin` (walks, matrix, transform, budgets),
`mica/kernel/catalog_stage.odin` (staged catalogue changes),
`mica/store/buffer_page.odin`, `mica/runtime/buffer_builtins.odin`.

## Naming and the shared registry

| Current | Proposed | Why |
| --- | --- | --- |
| `Relation_ID` | `Catalog_ID` | Identifies a catalogue slot; relation or buffer. |
| `Relation_Metadata` | `Catalog_Entry` | Shared entry record; `storage` discriminates. |
| `Relation_Durability` | `Durability` | Buffers have durability too. |
| `validate_relation_metadata` | `validate_catalog_entry` | Validates either storage shape. |
| `snapshot_relation_metadata[_named]` | `snapshot_catalog_entry[_named]` | Same. |
| — | `Buffer_Writes`, `snapshot_set_buffer`, `snapshot_buffer` | New. |

Mechanical sweep across `mica/kernel`, `mica/store`, `mica/runtime`; can land as
its own commit. `Relation` keeps its meaning: a stored or derived tuple set, read
by `RelationRead`, usable as a rule head.

## Performance

Definitions: **n** scalars in the buffer; **N** tree nodes ≈ O(n / leaf
capacity); **m** edits in a transaction; **k** scalars in a slice; **c** changed
pieces.

| Operation | Cost | Notes |
| --- | --- | --- |
| Stage one edit | O(log N) node copies + O(inserted) bytes | Path copy; balancing may split/merge. |
| Read committed root at offset | O(log N) + O(1) intra-chunk | Chunk sampled `String_Index`. |
| Slice of k scalars | O(log N + k) | Span walk. |
| Retain a version | O(1) | Refcount. |
| **Release a version** | **O(j)** | Not O(1); iterative. |
| Ordinary normalization (`Dp`) | Structure-proportional | Bounded by ordinary limits. |
| Reconciliation (`D1`, transform) | **Budgeted** | Common case cheap via identity pruning; worst case fails the commit. |
| Snapshot fork | O(entries) | One retain per buffer block. |
| Window read of L lines | O(log N + bytes in window) | The rendering guarantee. |
| Whole commit | tree + normalization + snapshot arrays + derived rules + persistence | Derived rules often dominate. |

Residual costs: many small chunks under character-at-a-time editing (compaction
folds them; batching is a follow-up), root churn and reclamation, very long lines
(rendering, not storage), and pathological random-edit patterns (benchmark before
optimizing; a wider fan-out is a local change).

## Testing

**Reference model first.** M0 delivers the semantics tested against a reference
model before kernel integration.

- **Reference model is a tagged scalar list.** The model is a list of
  `(origin, scalar)` pairs, where each inserted run carries a unique origin and
  base scalars carry base origins. Generate **view-relative** edit scripts,
  apply them to the model, then derive expected retained base intervals and
  inserted runs by scanning it. Compare against the piece tree's provenance walk.
  This independently exercises editing inserted text, fragmented chunks, and
  deletion boundaries; starting from base-relative replacements would bypass
  exactly the hardest normalization cases.
- **Ambiguity regressions.** The `"aaa" → "aa"` cases: deleting at view 0 versus
  view 2 must yield different deltas.
- **Conflict matrix.** Exhaustive insert/insert, insert/delete, replace/replace
  at interior, both boundaries, adjacent, identical, and same-point; assert
  exactly the specified outcome.
- **Epochs.** Equal revision and equal epoch publishes as built; equal revision
  with a new epoch re-applies `Dp` onto `R1` and publishes under the new epoch
  rather than adopting `Rp`; a crossed epoch with a content change conflicts and
  never attempts a content diff; compaction retries rather than force-publishing
  over a concurrent edit.
- **Budgets.** A large uncontended paste succeeds within ordinary limits and
  never reports resynchronize; reconciliation past a rebase limit fails with
  `Rebase_Budget_Exceeded` and publishes nothing; the budget is shared across a
  transaction's rebases; the expensive-but-zero-hunk case still trips the work
  budget.
- **Admission.** A durable buffer write is charged for its staged inserted bytes
  and a per-record framing charge; a pure deletion is still charged its framing;
  a staged buffer's initial content is charged with it; a volatile buffer is
  charged nothing; and a write past the store's budget fails with `Overloaded`
  without advancing the published version.
- **Client contract.** `:stale` stages nothing; one `buffer_apply` per buffer per
  transaction, and a later mutation of an applied buffer is rejected with
  `E_STATE`; `:ok` returns a fully materialized delta relative to
  `expected_revision`, composed before publication even when the commit rebased
  onto a version the client never saw; `:resync` is returned only before
  publication, so a resync is never reported for a committed edit; and a
  non-published tagged apply reports `:resync` for an epoch crossing, exhausted
  budget, or failed composition, `:conflict` for an overlapping concurrent
  change, and `:aborted` otherwise.
- **Change feed.** A committed buffer edit appears as a record carrying the same
  base-relative delta the log records, with the revisions it spans; a compaction
  appears with an empty delta and the new epoch; a `:buffer` subscriber receives
  the edits as message values and a resynchronization as the whole text.
- **Markers and annotations.** A position moves with insertions and deletions
  before it; an insertion exactly at it is decided by the insertion type; a
  position inside deleted material collapses to the deletion point; a marker
  inside a replaced range collapses to the replacement start; the marker table
  rebases from the same delta a token-tagged apply records; and a collapsed
  annotation is dropped only by an explicit call.
- **Reversion.** `buffer_revert` stages a whole-buffer replacement with fresh
  chunks, respects the revision check, and never adopts a historical root;
  reverting cannot resurrect chunk intervals absent from the base; a revision
  outside the retained window is refused; a reversion on a view that already has
  staged changes is refused; the retained window is bounded and a killed entry
  drops it; and a reversion replays from the recorded whole-buffer delta with its
  revision and epoch intact.
- **Ownership.** Abort releases staged chunks; borrowed spans stay valid during a
  visit; chunks free only at last release; compaction preserves content and keeps
  old roots readable; small chunks come from size classes without 64 KiB waste.
- **Tree invariants.** Occupancy bounds under adversarial edits; O(log N) depth;
  iterative, leak-free release of a deep tree.
- **Isolation.** A reader on an old snapshot sees old text while a writer commits.
- **Atomic creation.** Create + insert + metadata commits as one version; a
  concurrent duplicate name conflicts; abort leaves no entry and no content;
  readers never observe a partially initialized buffer.
- **Recovery.** One record per version replays relations, buffers, and staged
  creation atomically; torn tail drops the whole record; revision continuity
  across restart; compaction preserves revision and bumps the epoch; a
  `base_revision` gap is refused.
- **Reclamation.** Node and chunk counts return to baseline after snapshots
  retire.
- **Search and projection.** `buffer_find` returns the scalar offset of the first
  match inside the requested window, crossing chunk boundaries, and `none`
  otherwise; `buffer_lines` returns exactly the requested line range with spans
  excluding the newline, and an empty relation past the end.
- **Integration.** Extend `tools/appconformance` with buffer scenarios, including
  the multi-transaction ones (reversion, compaction) the single-call form cannot
  express.

## Milestones

- **M0 — Semantics fixed and tested.** Exit criteria, all in the reference model
  with tests and no kernel changes: coordinates; provenance normalization
  including retained-interval-by-base rules; the conflict matrix; epoch behaviour
  including resulting-root lineage; the two budget classes; the client revision
  contract including preparation-before-publication; reversion as a splice;
  ownership and lifetime rules.
- **M1 — Piece tree.** Chunks with size-classed storage, slab nodes, balancing,
  path copy, span visit, provenance walk, iterative release, reclamation;
  benchmarks.
- **M2 — Transactional integration, conservative conflict, atomic creation.**
  Catalogue storage kinds, staged catalogue changes, snapshot buffer array,
  private-root staging, normalization, mutation, isolation, atomic mixed commit,
  revision and epoch, `Reject` conflict.
- **M3 — Persistence.** One atomic WAL record, group-publisher aggregation and
  ticket settlement, checkpoint flattening, boot, admission, revision continuity,
  compaction.
- **M4 — Client revision contract.** Staging operation plus precomposed
  completion result, `:stale`/`:resync`/`:conflict`, feed integration.
- **M5 — Span merging.** Provenance merge, transform, matrix and epoch tests,
  opted in per entry via `Span`.
- **M6 — Mica surface and lifecycle.** Builtins (including `buffer_find` and the
  bounded `buffer_lines` line projection), authority, `kill_buffer` and
  tombstones, `buffer_revert` over a bounded retained history, management facts.
- **M7 — Relational projection, annotations, and editor tooling.** Done. The
  runtime provides the computed-relation registry, `BufferStat`, bounded
  `BufferLine`, and indexed `BufferMarkers` window scans. The region layer in
  `apps/shared/buffers.mica` provides revision-anchored markers, insertion
  types, explicit rebasing, and annotations over markers. Line and presentation
  data stay computed and are never stored.

`Whole` lands only as an explicitly destructive opt-in.

## Relational access

**Metadata is ordinary stored facts** keyed by buffer id; rules join cheaply:

```mica
Modified(b) :- BufferModified(b, true)
Editable(actor, b) :- CanWrite(actor, BufferId(b))
```

**Content needs a computed projection.** Computed relations are read-only,
relation-shaped surfaces whose rows runtime code produces when scanned; required
bindings are an access pattern, an unsatisfied binding raises `E_DB`, and
computed rows are visible to rules without becoming facts. Natural projections
are `BufferStat(buffer, ?length, ?lines, ?revision)` and
`BufferLine(buffer, first, count, ?line, ?start, ?stop, ?text)`. `BufferLine`
requires the buffer, first line, and count. This rule prevents an accidental
scan of every line in every buffer. `buffer_lines` remains the direct builtin
for code that needs a relation value instead of a named query. A caller needs
read authority for both the computed relation and its underlying buffer.

You cannot: write a rule head over buffer text, join two buffers, `assert`/
`retract` content as relations, or pass a buffer where a relation is expected.
Those limits are about **content**. The next section is about the facts that
surround it, which are ordinary relations.

## Regions, Annotations, and Markers

A buffer's *content* is not relation-shaped. Nearly everything else a document
needs — spans, annotations, markers, positions — is. This section draws that line
and fixes the coordinate model, because it is the one place where "buffer
content" and "the relational world" meet.

### Three regimes, not one

Lumping these together is what makes the boundary look ambiguous. They have
different derivation, storage, and invalidation behaviour, and each belongs
somewhere different:

| Regime | Examples | Where it lives | Invalidated by an edit? |
| --- | --- | --- | --- |
| **Function of the text** | line number, column, indentation depth | Computed on demand from the tree's cached counts. Never stored. | Recomputed; nothing to invalidate. |
| **Derived presentation** | faces, font-lock, folding, syntax spans | A **computed relation** over a bounded window, with required bindings. Not stored. | Re-derived for the edited window. |
| **Independent durable state** | markers, comments, breakpoints, selections, diagnostics, blame | **Ordinary stored relations.** | Must be *moved* — see below. |

Only the third regime is state, and only it raises the questions this section
answers. Storing the second would repeat the mistake that killed one-tuple-per-
line: per-keystroke relation churn for data that can be recomputed.

### Why annotations are relation-shaped

Applying the tests that disqualified the text:

| | Buffer content | Region annotations |
| --- | --- | --- |
| Set of tuples? | No, a sequence | Yes: `Annotation(buffer, id, start, end, kind, payload)` |
| Order intrinsic? | Yes, it *is* the content | No; the set is unordered |
| Duplicates meaningful? | Yes (`"aaa"`) | No; they collapse |
| Algebra | None over text | select, project, join |
| Derivable by rules? | No | Yes |

So spans are relations for the same reason the text is not: they lack exactly the
properties that made the text a sequence.

### Coordinates are anchored to a revision

A `(start, end)` pair is meaningless without the revision and epoch it was
written against. This is the real difficulty, and the design already contains its
solution: **the provenance delta is the transform.** Carrying a coordinate set
from one revision to another is `tree_provenance` followed by applying the
result — the same operation that reconciles a rebased transaction, applied to
intervals instead of text. Nothing new is required to move an annotation; the
work is deciding what it means when the text under it moves.

### Markers are the long-term shape

**A marker is a stable identity with a position that moves with edits.** The
long-term model is that durable annotations reference markers, not raw offsets:

```mica
Marker(#m1)
MarkerBuffer(#m1, #notes)
MarkerPosition(#m1, 412)
MarkerInsertionType(#m1, :stick_after)

Annotation(#a1)
AnnotationBuffer(#a1, #notes)
AnnotationSpan(#a1, #m1, #m2)
AnnotationKind(#a1, :comment)
AnnotationText(#a1, "check this")
```

(The insertion-type symbols are `:stick_after` and `:stick_before`; `after` is a
reserved word in Mica source, as `end` is.)

Properties of this shape:

- **An edit moves markers, not annotations.** An edit is O(markers) in the marker
  table, and the annotation set is untouched. That is the whole reason to prefer
  it over raw offsets, which would require rewriting every annotation that
  follows the edit point.
- **Insertion type decides ties.** Inserting exactly at a marker's position places
  the text before or after it according to `MarkerInsertionType`, matching the
  behaviour editors expect from a "sticky" marker. Emacs's insertion types are
  the precedent.
- **A marker inside a deleted range collapses** to the deletion point rather than
  vanishing; annotations whose span collapses to zero length are then either
  dropped or kept as point annotations according to their kind.
- **Markers are cheap to share.** Point, mark, and search state are markers too,
  so a search result set does not need its own anchoring mechanism.
- **Rendering joins through the marker table**: find markers whose positions
  intersect the window, then the annotations that reference them (an equality
  join Mica already does well).

**Implemented shape.** `apps/shared/buffers.mica` declares the relations above,
including `MarkerRevision`. It also declares `marker_create`, `marker_position`,
`marker_revision`, `marker_rebase`,
`markers_rebase`, `annotation_create`, `annotation_rebase`, `annotation_view`,
and `annotation_drop_collapsed`. The rebase step is the builtin
`buffer_marker_rebase(edits, position, insertion_type)`, a pure function over a
base-relative delta — the same `[{:at, :remove, :text}]` shape
`buffer_apply_result` returns and the `:buffer` change feed delivers. A caller
therefore moves markers from the delta it already has. The revision pair makes
delivery idempotent and rejects a missed delta. A separate call drops a
collapsed span.

The kernel never sees a marker. Had the marker table been stored as raw offsets
on the annotation, the same observations would hold with more churn; the marker
shape is preferred because an edit then touches only the small marker table.

### Who moves markers

The buffer stays pure: it does not know annotations exist. A buffer write already
produces a **normalized base-relative delta** (for provenance and for the client
completion result), and that delta is exactly the input marker rebasing needs.
So the rule is:

1. An edit stages buffer content; the committed delta then describes everything
   that moved.
2. Rebasing is explicit, not kernel behaviour hidden behind `buffer_insert`.
   Local code can stage an edit and its known marker transform in one
   transaction. A remote client uses the authoritative completion result or
   change feed. Until it applies that result, stale marker revisions are not
   projected against newer text.
3. If that proves too manual, a declared "anchored to this buffer" property on a
   relation could make the kernel rebase automatically. That couples annotation
   tables into every buffer edit, so it is earned later, not assumed now.

### Bounded marker windows

Mica's relation indexes are equality- and prefix-based. The natural annotation
query is **overlap** ("every marker or annotation intersecting this window"),
which is a generalized join, not an equality join. `BufferMarkers` keeps a
sorted position index inside the runtime. The required buffer and half-open
window bindings keep every scan bounded:

`BufferMarkers(buffer, window_start, window_end, ?marker, ?start, ?end)`

Markers are points, so `start` and `end` are equal. The runtime omits a marker
when its stored revision differs from the projected buffer revision. Rules see
relation-shaped rows while the access path stays an implementation detail.

### What you can and cannot do

- **Can:** write rules over annotations, markers, and their metadata; grant
  authority on annotation relations; receive change-feed notifications for them;
  derive views (`Comment(b) :- AnnotationKind(a, :comment), AnnotationBuffer(a, b)`).
- **Cannot:** write a rule over the *characters*; join two buffers; treat an
  annotation's span as stable across revisions without rebasing it.

## Alternatives considered

- **Buffer as a Mica value.** Forces content-defined `value_eq`/`value_hash`/
  canonical ordering, a retaining `value_deep_copy`, a codec, and a
  canonical-order slot; invites multi-megabyte text in a tuple column. Deferred,
  initially *storable but not persistable*.
- **Handle in a relation tuple.** Couples reclamation to tuple lifetimes through
  a new value type while leaving conflict tuple-granular.
- **One tuple per line.** Gives full relational access to content; rejected on
  cost (chunk rebuild per change, suffix renumbering, per-keystroke churn,
  tuple-granular conflict).
- **Rope instead of piece tree.** More general; the append-only chunk model is
  monotonic across versions and pairs with append-only WAL records, which a
  rope's split/merge nodes lose for no gain at editor scale.
- **Canonical content diff for conflict.** Ambiguous for repeated text, and the
  ambiguity changes which edits conflict. Epochs handle compaction instead.
- **Retained edit log for conflict.** Couples retention to live transaction
  bases and interacts with change-feed eviction; unnecessary once conflict is
  provenance-based over retained roots.
- **Historical-root adoption for revert.** Resurrects intervals absent from the
  base and mixes epochs; a whole-buffer splice is used instead.
- **Interval tree for text.** Correct for markers and text properties (M7), not
  for a character sequence.

## Open questions

1. **Authorizing creation and deletion.** Catalogue changes are root-gated today.
   Should `make_buffer`/`kill_buffer` be root-only, and is buffer-per-document a
   hot path?
2. **Undo ring ownership and durability.** A runtime-managed per-buffer ring is
   the interim (32 versions, process-local, rebuilt from replay); should it become
   an application-driven history API, and should the window be persisted so a
   restart does not shorten it?
3. **`Reject` default scope.** Keep `Reject` after M5, or move durable buffers to
   `Span` once proven?
4. **Same-point insert tie-break.** Stay with conflict, or adopt deterministic
   actor-id ordering?
5. **Rebase budget values.** Benchmark the provisional limits; on exhaustion, is
   `:resync` always right, or may a caller request `:conflict`?
6. **Small-insert batching.** Freeze threshold, and whether a partially filled
   batching chunk can survive in the tree.
7. **Compaction trigger.** Checkpoint-time, threshold, explicit, or all three;
   and does compaction re-admit durable budget?
8. **Line-ending and encoding policy.** UTF-8 with `\n` only, or CRLF
   normalized? Belongs in `Buffer_Schema`.
9. **Per-span authority.** Deferred. Must storage leave room for span-keyed
   policy facts?
10. **Cross-kernel transfer.** Does export/import force a serialisation format
    earlier than M3?

## Appendix A: proposed symbols

| Symbol | File | Kind |
| --- | --- | --- |
| `Catalog_ID`, `Catalog_Entry`, `Storage`, `Tuple_Schema`, `Buffer_Schema`, `Durability` | `mica/kernel/relation.odin` | types |
| `Conflict_Kind.Reject/Span/Whole`, `Structure_Epoch` | `mica/kernel/relation.odin` | enum members, field |
| `validate_catalog_entry` | `mica/kernel/relation.odin` | proc |
| `Text_Chunk`, `Chunk_Kind`, `Piece`, `Piece_Node` | `mica/kernel/buffer.odin` | types |
| `chunk_create/retain/release`, `node_alloc/free` | `mica/kernel/buffer.odin` | procs |
| `buffer_edit_apply`, `buffer_visit_spans`, `buffer_offset`, `buffer_line_start` | `mica/kernel/buffer.odin` | procs |
| `buffer_provenance_walk`, `buffer_conflict_matrix`, `buffer_transform` | `mica/kernel/buffer_provenance.odin` | procs |
| `Rebase_Budget`, `Rebase_Budget_Exceeded`, `Buffer_Edit_Too_Large` | `mica/kernel/buffer_provenance.odin`, `mica/kernel/error.odin` | type, errors |
| `Buffer_Edit`, `Buffer_Writes` | `mica/kernel/transaction.odin` | types |
| `Buffer_Block`, `Buffer_History`, `Apply_Status`, `Revert_Status` | `mica/kernel/buffer.odin` | types |
| `transaction_buffer_revert`, `buffer_history_record/lookup/forget` | `mica/kernel/buffer.odin` | procs |
| `Staged_Catalog_Change` | `mica/kernel/catalog_stage.odin` | type |
| `transaction_buffer_seed/apply/normalize/materialize` | `mica/kernel/transaction.odin` | procs |
| `Snapshot.buffers`, `snapshot_set_buffer`, `snapshot_buffer` | `mica/kernel/snapshot.odin` | field, procs |
| `Buffer_Page` encode/decode | `mica/store/buffer_page.odin` | procs |
| `Wal_Record.buffers` | `mica/store/wal.odin` | field |
| `Manifest_Data.buffers` | `mica/store/checkpoint.odin` | field |
| `buffer_apply`, `buffer_apply_result`, `buffer_revision`, `buffer_revert`, `make_buffer`, `kill_buffer` | `mica/runtime/buffer_builtins.odin` | builtins |
| `buffer_marker_rebase` | `mica/runtime/buffer_builtins.odin` | builtin/helper |
| `Marker`, `MarkerBuffer`, `MarkerPosition`, `MarkerInsertionType`, `MarkerRevision` | `apps/shared/buffers.mica` | world relations |
| `Annotation`, `AnnotationBuffer`, `AnnotationSpan`, `AnnotationKind`, `AnnotationText` | `apps/shared/buffers.mica` | world relations |
| `Computed_Registry`, `kernel_register_computed_relation` | `mica/kernel/computed.odin` | registry |
| `BufferStat`, `BufferLine`, `BufferMarkers` | `mica/runtime/buffer_computed.odin` | computed projections |

## Appendix B: recovery invariants

1. **Atomicity.** One `Wal_Record` carries all relation writes, buffer writes,
   and staged catalogue changes of one published version. Replay applies it as a
   unit.
2. **Torn tail.** A partial trailing record is discarded whole; no half
   transaction is applied, including half a buffer creation.
3. **Revision continuity.** Replayed buffer revisions are strictly increasing per
   entry and continue across restart. A record whose `base_revision` does not
   match the replayed revision is a gap and recovery refuses.
4. **Epoch continuity.** `Structure_Epoch` is persisted and monotonic, so a
   transaction can tell whether provenance reaches its base, and a published root
   always carries the epoch it is labelled with.
5. **Compaction invisibility.** Compaction preserves the logical revision and
   bumps only the epoch, so it is indistinguishable from a read by clients; it
   publishes only against an unchanged base.
6. **Generation separation.** Process-local node/chunk generations never appear
   in the WAL, client replies, or authority.
7. **Budget failure is all-or-nothing.** A `Rebase_Budget_Exceeded` commit
   publishes none of that transaction's changes: no facts, no buffers, no staged
   catalogue entries.
8. **Deletion.** A tombstoned entry never has its id reused, so a stale reference
   fails cleanly rather than aliasing.

## Appendix C: glossary

| Term | Meaning |
| --- | --- |
| **buffer** | A catalogue entry whose storage backend is a persistent piece tree. |
| **catalogue entry** | A named slot; relations and buffers are the two storage kinds. |
| **text chunk** | An immutable, refcounted, bounded byte run with a stable id, cached counts, and a sampled scalar→byte index. |
| **piece** | A `(chunk, start, length)` run of scalars; the unit of provenance. |
| **provenance** | The `(chunk, interval)` identity of a piece, distinguishing base material from transaction-inserted material and making normalization exact. |
| **retained base material** | A piece whose `(chunk, interval)` is present in the transaction's base. |
| **private root** | The transaction's working root, path-copied during staging. |
| **base-relative delta** | The normalized replacement set derived from provenance. |
| **revision** | Persisted, monotonic content version used by clients and the WAL. |
| **epoch** | Persisted marker bumped by compaction and carried by the published root; provenance does not compare across it. |
| **generation** | Process-local allocation id, used only by the checkpoint cache. |
| **ordinary limits** | Bounds on a single edit's normalization and encoded size; failure requires splitting or reconfiguring, not resynchronizing. |
| **rebase budget** | A bound on work spent reconciling concurrent changes; failure is `Rebase_Budget_Exceeded` and is resynchronizable. |
| **compaction** | Re-chunking current text into fresh original chunks and publishing a new root, preserving revision and bumping epoch. |
| **marker** | A stable identity with a buffer position that moves with edits; the long-term anchor for annotations. |
| **insertion type** | Whether text inserted exactly at a marker's position lands before or after it. |
| **annotation** | A stored relation over a buffer region, referencing markers rather than raw offsets. |
| **regime** | Which of the three region layers something belongs to: a function of the text, a derived presentation, or independent durable state. |
| **interval join** | An overlap query over regions; the one relational operation Mica's indexes do not provide directly. |
