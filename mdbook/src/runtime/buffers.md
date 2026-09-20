# Buffers

A buffer stores text that changes over time. Use a buffer for an editor document, a shared note,
or a growing log. Mica can edit a large buffer without copying all its text after each change.

Buffers take part in the same transactions as relations. A task can change text and facts together.
Other tasks see both changes after the transaction commits.

## Start with a buffer

This example creates a durable buffer and edits it:

```mica
make_buffer(:notes, :durable)

buffer_insert(:notes, 0, "hello")
buffer_insert(:notes, 5, " world")

require buffer_text(:notes) == "hello world"
require buffer_len(:notes) == 11
```

The buffer name is a symbol, such as `:notes`. `make_buffer` returns `true` after it creates or
adopts the named buffer. Repeating the same declaration does not erase existing text.

All operations in the example use the task's current transaction. The second insertion sees the
first insertion, even though the transaction has not committed yet.

`buffer_text` returns the complete text. It is useful for tests and small buffers. For a large
document, use slices, line ranges, or search instead.

## Positions and ranges

Buffer positions count Unicode scalars from zero. They do not count bytes. For example, `é` uses
more than one UTF-8 byte, but it occupies one buffer position.

On this page, a scalar means one Unicode code point. A scalar is not a byte or necessarily a
complete visible character.

Ranges include their start and exclude their end. The range `[1, 3)` selects positions 1 and 2.

```mica
make_buffer(:sample, :durable)
buffer_insert(:sample, 0, "héllo→")

require buffer_len(:sample) == 6
require buffer_slice(:sample, 1, 3) == "él"
```

The basic edit operations are:

| Operation | Meaning |
| --- | --- |
| `buffer_insert(buffer, at, text)` | Insert `text` before position `at`. |
| `buffer_delete(buffer, at, count)` | Remove `count` scalars from position `at`. |
| `buffer_replace(buffer, start, end, text)` | Replace the range `[start, end)` with `text`. |
| `buffer_slice(buffer, start, end)` | Return the text in `[start, end)`. |
| `buffer_len(buffer)` | Return the number of scalars. |
| `buffer_line_count(buffer)` | Return the number of lines. An empty buffer has one line. |
| `buffer_revision(buffer)` | Return the committed revision visible to the transaction. |
| `buffer_text(buffer)` | Return the complete text. |

Each later operation uses the text produced by earlier operations in the same transaction:

```mica
make_buffer(:draft, :durable)
buffer_insert(:draft, 0, "the quick fox")
buffer_replace(:draft, 4, 9, "slow")
buffer_delete(:draft, 0, 4)

require buffer_text(:draft) == "slow fox"
```

An invalid range or position raises an error. Use non-negative positions, and do not read or remove
past the end of the buffer.

## Text and facts can commit together

A buffer is part of the world state. Buffer changes and relation changes in one transaction publish
as one unit.

```mica
make_buffer(:report, :durable)
buffer_insert(:report, 0, "Inspection complete")
assert BufferOwner(:report, #alice)
assert BufferState(:report, :ready)
```

No other task can see a partly initialized report. If the transaction aborts, the buffer edits and
the facts are both discarded.

The same rule applies after creation. A task can update a document and its workflow state in one
transaction. See [Tasks and Transactions](tasks-and-transactions.md) for transaction boundaries and
retry behavior.

## Choose durability and conflict behavior

The second argument to `make_buffer` selects how the text survives a restart:

| Mode | After a restart |
| --- | --- |
| `:durable` | Mica restores the text from the world store. |
| `:volatile` | The buffer keeps its name and identity, but its text starts empty. |

When the Mica world owns the document, use `:durable`. When another system owns the durable copy,
use `:volatile`. For example, an editor can use a volatile buffer for a file on disk.

The optional third argument selects the conflict policy:

```mica
make_buffer(:private_notes, :durable)          // same as :reject
make_buffer(:shared_notes, :durable, :span)
make_buffer(:scratch, :volatile, :whole)
```

| Policy | Concurrent changes |
| --- | --- |
| `:reject` | Reject any concurrent content change. This policy is the default. |
| `:span` | Merge changes to separate ranges. Reject overlapping changes. |
| `:whole` | Let the last writer replace the complete buffer view. |

Use `:reject` for the safest default. Use `:span` for shared documents that need independent edits.
When last-writer-wins behavior is acceptable, use `:whole`.

## Authority

Buffer reads require read authority for the named buffer. Buffer changes require write authority.
Calling a buffer builtin also requires authority to invoke that builtin.

Authority applies to a complete buffer. The runtime does not provide separate authority for a text
range. An application can store richer access policy in relations and check it before a buffer call.

## Safe edits from an editor client

Normal buffer functions use the transaction's current view. This behavior is useful for trusted
server code, but it cannot detect every stale editor position.

Suppose a client reads revision 41 and prepares an edit at position 20. Another client then commits
revision 42. A new transaction starts at revision 42, so position 20 can now refer to different text.

Use `buffer_apply` for edits that arrive from a client:

```mica
let status = buffer_apply(
  :notes,
  expected_revision,
  [{:at -> 20, :remove -> 3, :text -> "new"}]
)
```

Each edit map removes `remove` scalars at `at`, then inserts `text`. Mica applies the maps in list
order. Each map uses the view produced by the preceding map.

When the expected revision matches, `buffer_apply` returns `:staged`. When it does not match, the
function returns `:stale` and changes nothing.

A transaction can call `buffer_apply` only once for each buffer. It must be the first change to that
buffer in the transaction. These rules keep every client position tied to the revision it describes.

### Learn the result after commit

`:staged` does not mean that the transaction committed. Later work can still abort, and concurrent
work can still cause a conflict.

When the client needs the final result, pass a client token:

```mica
buffer_apply(
  :notes,
  expected_revision,
  [{:at -> 20, :remove -> 3, :text -> "new"}],
  4242
)
```

After the transaction finishes, a later task can read the result:

```mica
let result = buffer_apply_result(4242)
```

The result is `:pending` until Mica records an outcome. A completed result is a map with a status and
a revision.

| Status | Meaning |
| --- | --- |
| `:ok` | The edit committed. `:applied` contains the authoritative delta. |
| `:resync` | The server applied nothing. Read the buffer again before resubmitting. |
| `:conflict` | A concurrent edit overlapped this edit. Read the buffer again. |
| `:aborted` | Another error prevented the transaction from publishing. |

The `:applied` delta is relative to the client's expected revision. It can include concurrent
changes that Mica merged during publication.

## Read a bounded part of a buffer

Large documents need bounded reads. These operations avoid loading the complete buffer.

### Search

`buffer_find(buffer, pattern, from, limit)` finds the first match at or after `from`. When the search
finds no match, it returns `none`.

The `limit` value controls how many scalars the search reads. A value of `0` searches to the end.

```mica
let position = buffer_find(:notes, "TODO", 0, 10000)
```

The search can find text that crosses an internal storage boundary.

### Lines

`buffer_lines(buffer, first, count)` returns a relation value for a range of lines:

```mica
for line in buffer_lines(:notes, 0, 40)
  render(line[:text])
end
```

The result heading is `[:buffer, :line, :start, :stop, :text]`. Line numbers and scalar positions
start at zero. For a line with a trailing newline, `stop` is the scalar position of that newline.
The `text` value does not include the newline. The final line stops at the end of the buffer.

The required `first` and `count` arguments prevent an accidental read of every line. A request past
the last line returns an empty relation value.

## Buffers and relations have different jobs

A buffer is not a special type of relation. The two values have different structures:

| | Relation | Buffer |
| --- | --- | --- |
| Main purpose | Store facts | Store changing text |
| Structure | A set of tuples | An ordered sequence of Unicode scalars |
| Order | Does not affect meaning | Defines the content |
| Duplicates | Duplicate tuples collapse | Repeated characters remain |
| Main operations | Select, project, join, union | Insert, delete, replace, slice |

Do not store one relation fact for each character or line. An edit near the start requires many fact
changes. Keep the text in a buffer, and keep facts about the document in relations.

For example, ownership, status, and display settings fit ordinary relations:

```mica
BufferOwner(:notes, #alice)
BufferState(:notes, :draft)
```

Rules can join these facts without reading the buffer text.

## Read buffer data from rules

Computed relations provide read-only, bounded views of buffer data. They look like relations in
Mica source, but runtime code produces their rows.

`BufferStat` returns basic counts and the current revision:

```mica
BufferStat(:notes, ?length, ?lines, ?revision)
```

`BufferLine` returns a requested line range:

```mica
BufferLine(:notes, 0, 40, ?line, ?start, ?stop, ?text)
```

The buffer, first line, and count must be bound. Missing inputs produce `E_DB`. This rule prevents
an unbounded scan of every buffer.

Computed rows are not stored facts. Code cannot assert or retract them. A caller needs read
authority for both the computed relation and its underlying buffer.

See [Computed Relations](../language/computed-relations.md) for the general query rules.

## Revisions and reversion

Each committed content change increases the buffer revision. Edits that are only staged do not
change the revision yet.

Mica keeps a bounded, process-local history for recent revisions. The current implementation keeps
up to 32 published versions for each eligible buffer. A global limit bounds the number of eligible
buffers.

Use `buffer_revert` to restore the text of a retained revision:

```mica
let status = buffer_revert(:notes, target_revision, expected_revision)
```

The result has one of these values:

| Result | Meaning |
| --- | --- |
| `:staged` | Mica staged the reversion. |
| `:stale` | The current revision does not match `expected_revision`. |
| `:unknown` | The history no longer contains `target_revision`. |

Reversion replaces the complete buffer. It discards every later edit, including edits from other
writers. For that reason, it uses a separate builtin and can have separate authority.

This operation is not selective undo. Selective undo reverses one writer's edit while it preserves
later edits. Mica does not provide that operation.

A checkpoint keeps only the newest content. After a restart, replay rebuilds history only from log
records that remain after the checkpoint.

## Observe changes

The commit feed carries buffer changes with relation changes. A service or user interface can follow
a document without polling its complete text.

In Mica, the `:buffer` subject watches one named buffer:

```mica
let sub = subscribe_changes(sender, :buffer, some(:notes), [], :changes)
```

A change message contains the old revision, new revision, epoch, and committed edits. The edits are
relative to the old revision. An observer applies them to its local copy.

Mica retains a bounded change window. A subscriber outside that window receives the complete current
text and resynchronizes.

## Mark positions in changing text

Applications often attach comments, selections, diagnostics, or breakpoints to text. A raw scalar
position becomes stale after earlier text changes.

A marker gives a position a stable identity. The shared buffer library provides helpers that store
the required marker and annotation facts:

```mica
buffers/marker_create(#start, :notes, 412, 7, :stick_after)
buffers/marker_create(#stop, :notes, 430, 7, :stick_before)
buffers/annotation_create(#comment1, :notes, #start, #stop, :comment, "Check this text")
```

Use `buffers/marker_rebase` to update a stored marker after a committed change. Use the delta from
`buffer_apply_result` or the change feed:

```mica
buffers/marker_rebase(#start, base_revision, new_revision, edits)
```

The lower-level `buffer_marker_rebase(edits, position, insertion_type)` builtin returns one updated
position. It does not change stored marker facts.

The insertion type resolves an insertion at the marker position. `:stick_after` moves the marker
after the inserted text. `:stick_before` keeps it before the inserted text. A deletion moves an
enclosed marker to the deletion position.

Each marker records the buffer revision that its position describes. This revision prevents an
application from applying one delta twice or skipping a delta.

`BufferMarkers(buffer, window_start, window_end, ?marker, ?start, ?end)` provides a bounded marker
view for rules. The first three arguments must be bound. Markers are points, so `start` and `end`
have the same value.

The shared definitions are in `apps/shared/buffers.mica`.

## Retire a buffer

`kill_buffer(buffer)` retires a buffer and releases its content. The name and internal identity are
never reused. Later reads and writes fail with `E_KILLED` instead of referring to a different object.

Retirement commits with other changes in the transaction. It also removes the retained reversion
history for that buffer.

## How the runtime stores text

The remaining sections explain implementation details. Application code does not need these details
for basic editing.

### Piece tree

Mica stores text in a persistent, balanced piece tree. A piece refers to a range inside an immutable
text chunk. Tree nodes cache text length and newline counts.

An edit copies the path from the root to the changed leaf. It shares the other branches with the
previous version. Old snapshots therefore keep their text without a complete copy.

The balanced tree gives logarithmic access to positions and lines. Immutable chunks also let a
reader safely use text spans while it holds a snapshot.

### Provenance and concurrent edits

Each piece records where its text came from. This origin information is called provenance. It lets
Mica describe an edit relative to the transaction's original buffer version.

Mica reduces the final transaction view to replacements of this form:

```text
(start, end, text)
```

The replacement removes `[start, end)` and inserts `text` at `start`. Mica uses these replacements
for conflict checks, persistence, client results, and change messages.

Under the `:span` policy, separate ranges can merge. Overlapping ranges conflict. Insertions at
opposite boundaries do not conflict. Two insertions at the same position conflict because Mica does
not define their order.

Mica derives replacements from the text tree, not from a retained change log. Change-feed eviction
therefore does not affect transaction correctness.

### Revisions, epochs, and compaction

A revision identifies visible content. An epoch identifies the lineage of the internal chunks.
Normal content changes increase the revision. Compaction keeps the content and revision, but starts
a new epoch.

`buffer_compact(buffer)` rebuilds the current text into fresh chunks. It must be the only change to
that buffer in its transaction. Compaction is a maintenance operation, not an editor command.

Only permitted revision and epoch states let an older transaction merge. A changed epoch prevents
Mica from treating unrelated chunk origins as shared history.

### Work limits

Mica uses separate limits for ordinary edits and concurrent reconciliation:

| Limit | Typical failure | Caller action |
| --- | --- | --- |
| Edit size or store capacity | `Buffer_Edit_Too_Large` or `Overloaded` | Split the edit or raise the configured limit. |
| Rebase work | `Rebase_Budget_Exceeded` | Read the current buffer and submit the edit again. |

The distinction matters for a large paste. Resynchronization does not make the paste smaller, so an
edit-size failure must not look like a stale-client failure.

### Persistence

One world-log record contains durable buffer writes, relation writes, and catalogue changes from a
transaction. Replay applies the complete record. A torn record does not leave a partial transaction.

A checkpoint stores the latest buffer text in new chunks. It does not store in-memory tree sharing
or old history. This format keeps recovery work proportional to the stored text.

## Implementation and tests

The implementation includes the piece tree, transactions, durability, conflict handling, reversion,
change observation, computed relations, and markers.

These commands run the main buffer checks:

```sh
odin test mica/buffer      # semantics and the piece tree
odin test mica/kernel      # transactions and conflicts
odin test mica/store       # persistence
odin test mica/runtime     # Mica buffer scenarios
odin run tools/appconformance
odin run benchmarks -o:speed -- -suite=buffer -quick
```

The differential test applies generated edits to the piece tree and a reference model. It compares
their final text and normalized changes. The runtime scenarios exercise the public Mica builtins.
The conformance suite compares the Odin-compiled and Mica-emitted programs.

The full internal contract is in
[`docs/buffers-design.md`](https://github.com/rdaum/omica/blob/main/docs/buffers-design.md).
