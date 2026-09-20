# Buffers

Mica stores text as immutable `string` values. That is the right default: a string is a value, it
compares and hashes like a value, and it can live in a relation tuple. It is the wrong default for
text that changes. An edit produces a whole new string, and a large text kept in a tuple is sorted,
hashed, and copied by the relation store.

A **buffer** is a durable, transactional text object for that case. Buffers exist so that an editor,
a shared document, a log, or any large text artefact can be world state without being a relation.

> **Status.** Buffers are implemented: the piece tree, transactional integration, durability, the
> Mica builtins, conflict handling, reversion, change observation, and the marker/annotation layer
> over stored relations all exist and are tested. Two things are not built: the registry that would
> make computed projections such as `BufferStat` rule-visible, and the interval-indexed marker
> overlap query. Where this chapter describes those, it says so.

## What A Buffer Is Not

It is tempting to call these "buffer relations." They are not relations, and the distinction is
worth keeping sharp.

A relation is an arity-fixed **set of tuples** with a declared heading, set semantics, and
rule-based derivation. A buffer is a **sequence of Unicode scalars**: order is the content,
duplicates are meaningful, and equality is sequence equality.

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

The last row is the whole of the commonality: buffers share the transaction manager and the world
with relations, and nothing else. A buffer is not rule-queryable. Writing `Text(b, ?c) :- ...` over
a buffer's content is not part of the design, and reaching text from a rule requires an explicit
computed projection.

The relational alternative — one fact per line — was available and was rejected. It gives up cheap
splicing, and the tuple store rebuilds a chunk for every change.

## Text Storage

Buffer text lives out of line in a **persistent, balanced piece tree** over immutable,
reference-counted **text chunks**.

A piece is a `(chunk, start, length)` run of scalars. A chunk is a bounded byte run with cached
scalar and newline counts and a sampled scalar-to-byte index. Chunks are immutable once published:
bytes never move, grow, or mutate, so a reader that holds a root can borrow spans from it safely.
Chunk byte storage is size-classed, so a one-scalar insert does not reserve a full-size block.

Every node caches the scalar and newline count of its subtree, which makes both character and line
addressing logarithmic. Balancing is a required invariant, not an optimization: those cached counts
only give logarithmic descent while the tree stays balanced. Nodes are small fixed-capacity slab
objects; only chunks own byte storage.

Editing path-copies from the root to the touched leaf and shares every untouched subtree. Two
snapshots therefore share almost all of their structure, and retaining an old version costs a
reference count rather than a copy. That is what makes reversal, point-in-time reads, and undo
affordable.

## Coordinates

**Builtin offsets address the current transaction view, never the base version.** A command reads
and writes the buffer as it exists after its own earlier edits, which is what editor commands
expect.

Staging keeps a **private root** seeded from the base. Each edit applies to that root immediately,
so:

- reads during a transaction are root reads, with no overlay to scan repeatedly;
- an edit that touches text inserted earlier in the same command is expressible directly;
- an abandoned transaction simply releases its private root and the chunks it created.

## Normalization Is Provenance, Not Content

Conflict detection and persistence both need a **base-relative** description of a change. Deriving
that from text content alone is ambiguous. If the text was `"aaa"` and is now `"aa"`, which `"a"`
was removed? All three answers produce the same text and different edits, and the difference decides
whether another concurrent edit overlaps.

Provenance removes the ambiguity. Because a piece records its chunk and offset, and because an edit
only inserts new chunks or removes base material, walking the private root recovers exactly what
happened:

- runs of pieces that reference base intervals **retain** that base material;
- runs that reference newly created chunks are **insertions**;
- base material that is absent was **deleted**.

Each maximal non-retained region becomes one **replacement**, `(start, end, text)`: remove base
interval `[start, end)` and insert `text` at `start`. Emitting one replacement per region, rather
than separate insertions and deletions, is what makes an adjacent delete-and-insert normalize to a
single replacement rather than to two edits that would compose incorrectly.

A cell is retained material only when the base actually contains that interval. Under ordinary
splicing this is automatic, but it is the rule that makes reversal safe.

## Conflict

When a transaction finds its base superseded, it reconciles using the provenance of three roots: its
base, the winner's root, and its own private root. No change log is needed, so a change feed that has
evicted old records cannot affect correctness.

Two base-relative replacements conflict according to their ranges:

| A \ B | insert at q | delete `[s2,e2)` | replace `[s2,e2)` |
| --- | --- | --- | --- |
| **insert at p** | conflict iff `p == q` | conflict iff `s2 < p < e2` | same |
| **delete `[s1,e1)`** | symmetric | conflict iff `s1 < e2 && s2 < e1` | same |
| **replace `[s1,e1)`** | symmetric | same | conflict iff `s1 < e2 && s2 < e1` |

Interior overlap conflicts. An insertion exactly at a boundary does not conflict and orders
deterministically: at the start of a changed range it stays before, at the end it stays after.
Adjacent ranges do not conflict. Two insertions at the same position conflict, because there is no
defined order and imposing one silently would be worse than reporting the conflict.

For the first implementation this is deliberately conservative. `Reject` mode, the default, makes
any concurrent content change to a buffer conflict. A shared document opts into provenance merging
with `Span`, which merges disjoint changes and refuses overlaps. Last-writer-wins (`Whole`) exists
only as an explicitly destructive policy for scratch buffers.

## Revisions and Epochs

Four notions of identity are kept separate, because conflating them breaks recovery and client
reconciliation:

| Concept | Lifetime | Purpose |
| --- | --- | --- |
| Buffer id | Stable, never reused, persisted | Identifies the buffer forever |
| Entry name | Fixed at creation | Catalogue lookup and authority resolution |
| **Revision** | Monotonic per buffer, persisted | Content version; what clients and the log check |
| **Epoch** | Monotonic per buffer, persisted | Chunk lineage; bumped by compaction |
| Generation | Process-local | Checkpoint page cache only |

**Compaction** re-chunks a buffer's current text into fresh chunks without changing its content. It
preserves the revision and bumps the epoch. That means compaction is invisible to clients, but it is
not invisible to reconciliation: a transaction whose base predates a compaction no longer shares
chunk lineage with the current root.

Because compaction describes *committed* content, it must be the transaction's only change to the
buffer. It is refused on a view that already has staged edits, and it seals the view so a later edit
is refused too; otherwise the edit would either be discarded with the old root or published under
the revision compaction preserves, leaving the revision un-advanced. Compacting a buffer created by
the same transaction is a no-op, because its content already lives in fresh chunks.

The epoch therefore constrains the **published result**, not merely permission to merge:

| Base vs winner revision | Base vs winner epoch | Action |
| --- | --- | --- |
| equal | equal | The buffer was untouched; publish as built |
| equal | differ (compaction only) | Re-apply the delta to the current root, under the new epoch |
| differ | equal | Provenance merge |
| differ | differ | Conflict |

The second row matters: content is identical, so there is nothing to conflict with, but publishing
the old private root would inject pre-compaction provenance into the new epoch. The edits are
re-applied to the current root instead. A reversion publishes fresh chunks too, so it also begins a
new epoch; because it advances the revision as well, a transaction whose base predates it sees both
move and conflicts rather than merging across the fresh lineage.

## Two Kinds Of Limit

Ordinary edit work and reconciliation work are separate limits, and conflating them produces a
failure a client cannot recover from:

| Class | Covers | Failure | Caller action |
| --- | --- | --- | --- |
| **Ordinary limits** | Own normalization, encoded size, store admission | `Buffer_Edit_Too_Large` / `Overloaded` | Split the edit or raise the limit; resynchronizing cannot help |
| **Rebase budget** | Reconciling against concurrent changes | `Rebase_Budget_Exceeded` | Resynchronize and resubmit |

A large paste with no contention is an ordinary edit. It is bounded by admission and by the ordinary
limits, and it must not fail with "resynchronize" merely because producing its own delta is large.
Resynchronization cannot fix an oversized ordinary edit, because the same snapshot and the same edit
fail identically.

## Client Revisions

A stale client offset is not a transaction conflict. A submission computed against revision 41 that
arrives after revision 42 committed starts on the new snapshot, finds nothing to conflict with, and
silently edits the wrong position. The transaction model cannot catch that; the contract must.

Shared editing therefore uses a revision-checked operation rather than the bare builtins:

```mica
// Staging, inside the transaction. No commit yet.
buffer_apply(buffer, expected_revision, edits)

// After publication, delivered to the caller:
//   {:status -> :ok,     :revision -> committed, :applied -> authoritative_edits}
//   {:status -> :resync, :revision -> current}
//   {:status -> :conflict, :revision -> current}
```

- A revision mismatch is `:stale`, and nothing is staged.
- At most one `buffer_apply` per buffer per transaction, and it must be the first mutation of that
  buffer. A matching revision does not make client offsets safe once the view has moved.
- `:ok` carries a delta expressed relative to the client's `expected_revision`, so the client can
  reconcile against the baseline it knew. When the commit rebased onto a version the client never
  saw, the server composes the concurrent change and its own into one delta against that baseline
  *before* publishing; a committed apply is never reported as an uncommitted `:resync`.
- `:resync` means nothing was applied and the server could not express the change against the
  client's baseline — a crossed structure epoch, an exhausted reconciliation budget, or a
  composition that failed. The client re-reads and reconciles its unsaved edits locally.
- `:conflict` means nothing was applied because a concurrent edit overlapped; the client re-reads and
  resubmits. `:aborted` covers every other reason the transaction did not publish.
- The completion is recorded when the outcome is known — at publication, or at teardown for a
  transaction that never published — and read back on a later turn with `buffer_apply_result`.
  Nothing is knowable while the edits are only staged.

## Undo and Reversion

Retained roots make an earlier revision's text readable, which is what reversion needs. Reverting is
**destructive** in a shared buffer: it discards every edit committed since, including other writers'.
It is therefore its own builtin, so a world can grant it separately from ordinary writes.

`buffer_revert(buffer, revision, expected_revision)` checks `expected_revision` against the revision
the transaction read and stages a whole-buffer replacement with the target revision's text. It is
refused with `:stale` when the expectation does not match and with `:unknown` when the target is
outside the retained window; otherwise it returns `:staged`. Nothing is staged unless it returns
`:staged`.

**Reversion is a splice, not the adoption of a historical root.** Adopting the old root would
resurrect chunk intervals absent from the transaction's base — violating the rule that makes
provenance well defined — and would mix an older epoch's lineage into the current one. Reading the
text and rebuilding it into fresh chunks keeps the operation inside the ordinary splice model, so
the result is an ordinary conflict-checkable delta and the published root simply begins a new epoch.

The text comes from a **bounded per-buffer history**: the kernel retains recent published versions
by reference count (32 per buffer, with a global cap on how many buffers retain any). A version that
falls out of the window is released. The window is process-local and is rebuilt from the records
replay applies, so after a restart it reaches back only as far as the log still holds; a checkpoint
flattens content to its latest version and preserves no prior ones. Reversion is only meaningful
before anything else has been staged for the buffer in the transaction, and it locks the view for
the rest of the transaction exactly as `buffer_apply` does.

**Selective undo** — inverting one writer's edit while preserving later ones — is explicitly out of
scope.

## Observing Changes

The commit feed carries buffer changes alongside fact changes, so a window, an indexer, or another
service can follow a document without polling. A record holds the buffer, the revisions it spans,
the epoch, and the committed base-relative delta — the same change the log records — so an observer
applies it to its own copy rather than re-reading the whole text. A compaction is reported too, with
an empty delta and the new epoch, because a lineage move is observable even though the characters
are not.

In Mica a buffer is watched with the `:buffer` subject against one buffer name:

```mica
let sub = subscribe_changes(sender, :buffer, some(:notes), [], :changes)
```

A change message carries `:changes -> [{:base_revision, :new_revision, :epoch, :edits -> [...]}]`.
When a subscriber falls outside the retained window its resynchronization is the whole text at its
current revision, since a character sequence cannot be diffed from a window the way a row set can.

## Persistence

Relations and buffers written by one transaction recover atomically. One log record per published
version carries all relation writes, buffer writes, and staged catalogue changes, and replay applies
it as a unit. A torn tail discards the whole record, so a torn write cannot leave half a buffer
transaction durable.

Checkpoints store flattened text: the current root's text is re-chunked into fresh original chunks
and written as pages. Structural sharing is an in-memory property, so only the current content needs
to survive a restart, which keeps the checkpoint format simple and boot linear in text size.

Creating a buffer together with its initial content and metadata is a single transaction. A
document's content, ownership, and application metadata are one invariant, and publishing an empty
entry first would create partially initialized objects and awkward recovery. Display names, modes,
and similar attributes are ordinary facts, so renaming in an editor is a fact write rather than a
catalogue change.

In the kernel this is `transaction_create_relation`: a transaction stages a new entry, resolves and
uses it immediately (staging facts and buffer content against it), and everything becomes visible
together at publication. Duplicate names are checked when staging and again at commit, where a name
a concurrent transaction claimed first is reported as a conflict rather than creating a duplicate
entry. An aborted transaction leaves nothing behind; a reserved id is simply unused, because ids are
never recycled.

## Durability

Durability is chosen per buffer, and it decides only whether the buffer's **text** is written to the
world's log. Everything else is unaffected: a volatile buffer still gets transactions, snapshot
isolation, conflict detection, revisions and epochs, authority, and every builtin. Volatility is not
a lesser kind of buffer; it is the same buffer with its content kept out of the log.

That matters for the common editor case of a buffer backed by a file. The file is the durable
artifact; the buffer is a working copy, and an editor may not want a second copy of a large document
in the world's log. Such a buffer is created volatile:

```mica
make_buffer(:notes_txt, :volatile, :span)
```

What survives a restart is the catalogue entry, not the text: the buffer comes back with the same
name and identity but empty, because the content was never written. Whether that is the right
trade-off depends on who owns the document. A buffer that *is* the document — a world-owned document,
a shared wiki page — should be durable. A buffer that mirrors a file usually should not: unsaved
changes are then the editor's to recover, in the file's own terms, rather than the world's.

## Search and the Line Projection

`buffer_find(buffer, pattern, from, limit)` returns the scalar offset of the first occurrence of
`pattern` at or after `from`, searching at most `limit` scalars (`0` means to the end), or `none`.
The window is materialized so a match may cross a chunk boundary: a byte scan of separate chunk
buffers could not see a match that straddles two of them.

`buffer_lines(buffer, first, count)` returns a relation value of consecutive line spans, with heading
`[:buffer, :line, :start, :stop, :text]`. A span excludes the line's trailing newline while `stop`
counts up to it, and the final line ends at the buffer end. Both `first` and `count` are required, so
there is no way to ask for every line of a buffer: that is a full document scan dressed as a query.

```mica
for line in buffer_lines(:notes, 0, 40)
  render(line[:text])
end
```

A relation value is a value: code can iterate it and combine it with other values, and `len`,
integer indexing (which yields a map keyed by column name), and symbol-keyed column access all work.
What it is *not* is a named relation, so a rule cannot scan it. `buffer_lines` is therefore the shape
text takes today; making projections rule-visible is a separate step, described under Relational
Access.

## Relational Access

Buffer **metadata** is ordinary stored facts keyed by the buffer's identity, so rules can join over
it cheaply:

```mica
Modified(b) :- BufferModified(b, true)
Editable(actor, b) :- CanWrite(actor, BufferId(b))
```

Buffer **content** is meant to be reachable through a computed projection — a read-only,
relation-shaped surface whose rows are produced when scanned, and which a rule can name. Such a
projection as `BufferLine(buffer, ?index, ?text)` must require a specific buffer and a bounded line
range; otherwise a rule asking for every line of every buffer is a full document scan dressed as a
query. A cheap projection such as `BufferStat(buffer, ?length, ?lines, ?revision)` is safe in rules.
A rule cannot name either of those yet: the registry that would produce computed rows during a scan
is not built, so today the relation-valued `buffer_lines` above is what stands in for them.

You cannot write a rule head over buffer text, join two buffers, or pass a buffer where a relation is
expected. Those limits are about **content**. The facts that surround a document are a different
story.

## Regions, Annotations, and Markers

It is worth being precise about where the "not a relation" line falls, because much of what a
document needs beyond its characters *is* relation-shaped.

Three regimes, with different behaviour:

| Regime | Examples | Where it lives |
| --- | --- | --- |
| **Function of the text** | line number, column, indent depth | Computed on demand. Never stored. |
| **Derived presentation** | faces, font-lock, folding, syntax spans | A computed relation over a bounded window. Not stored. |
| **Independent durable state** | markers, comments, breakpoints, selections, diagnostics | Ordinary stored relations. |

Only the third is state. Storing the second would repeat the mistake that ruled out one-fact-per-line:
per-keystroke relation churn for data that can be recomputed.

Annotations pass the tests that the text fails. They form a set of tuples, their order is not
meaningful, duplicates collapse, and rules can select, project, and join them. So spans are relations
for the same reason the characters are not.

**Coordinates are anchored to a revision.** A `(start, end)` pair means nothing without the revision
it was written against. The transform that carries a coordinate set from one revision to another is
the same provenance delta the transaction layer already computes, applied to intervals instead of
text.

**Markers are the long-term shape.** A marker is a stable identity with a position that moves with
edits, and durable annotations reference markers rather than raw offsets:

```mica
MarkerPosition(#m1, 412)
MarkerInsertionType(#m1, :stick_after)
AnnotationSpan(#a1, #m1, #m2)
AnnotationKind(#a1, :comment)
```

An edit then moves the (small) marker table and leaves the annotation set untouched, which is the
whole reason to prefer this over rewriting every annotation after the edit point. An insertion type
decides whether text inserted exactly at a marker lands before or after it, and a marker inside a
deleted range collapses to the deletion point. (`:stick_after`/`:stick_before` rather than
`:after`/`:before`, because `after` is a reserved word in Mica source.)

The buffer stays pure: it does not know annotations exist. A buffer write already produces the
normalized base-relative delta, and that delta is exactly what marker rebasing needs, so rebasing is
an explicit step over the delta rather than behaviour hidden inside `buffer_insert`.
`apps/shared/buffers.mica` is that step: it declares the marker and annotation relations and the
verbs over them, and rebasing calls the pure builtin
`buffer_marker_rebase(edits, position, insertion_type)` on the delta a caller already holds — from
`buffer_apply_result` for its own edit, or from the change feed as an observer. A span that collapses
is dropped by a separate call, so keeping a point annotation stays a choice.

One genuine gap remains. Mica's relation indexes are equality- and prefix-based, while the natural
annotation query is **overlap** — "everything intersecting this window". The intended fix is to keep
interval indexing inside the buffer layer and expose it as a bounded computed relation
(`BufferMarkers(buffer, window_start, window_end, ?marker, ?start, ?end)`), so rules see tuples while
the interval structure stays an implementation detail.

## What Is Built

The piece tree, the transactional integration, durability, the Mica surface, conflict handling,
reversion, change observation, and the marker/annotation layer are all implemented and tested.
Concretely, a buffer can be created, edited, read in slices and lines, searched, compacted, applied
to under a revision check, reverted to a retained revision, observed through the commit feed, and
killed; markers can be anchored, rebased through a committed delta, and joined to annotations; and
all of it commits atomically with ordinary relation writes and survives a restart.

What is missing is the layer that would let rules see into a buffer directly:

- **Computed relations.** A rule cannot name `BufferStat` or `BufferLine` yet. The
  computed-relation registry that would make them rule-visible is not built, so today
  `buffer_lines` returns a relation *value* that code can iterate but a rule cannot scan.
- **Interval-indexed marker queries.** A rule can join marker and annotation relations by equality,
  but cannot ask the buffer layer for "markers overlapping this window"; that bounded computed
  relation is the remaining piece.

Rules over the *stored* marker and annotation relations work today; it is only the computed
projections and interval overlap that are missing.

The implementation is exercised by

```sh
odin test mica/buffer      # semantics and the piece tree
odin test mica/kernel      # transactional integration
odin test mica/store       # durability
odin test mica/runtime     # runs the in-Mica scenarios in apps/buffers/tests
odin run tools/appconformance
odin run benchmarks -o:speed -- -suite=buffer -quick
```

Two of those are the load-bearing ones. The buffer package's differential test applies the same
generated view-relative edit scripts to the storage tree and to the reference semantics, and asserts
that the tree's provenance walk derives exactly the same base-relative delta. The runtime and
app-conformance suites run the Mica-facing scenarios: `apps/buffers/tests/buffer-scenarios.mica` for
the builtins, and `apps/shared/buffers.mica` plus `apps/buffers/tests/marker-scenarios.mica` for the
marker and annotation layer. Both are accepted by Mica source, and the Odin-compiled and
Mica-emitted programs are compared on them.

The full contract, including the pieces summarised here, is in
[`docs/buffers-design.md`](https://github.com/rdaum/omica/blob/main/docs/buffers-design.md).
