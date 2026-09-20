// M2 tests: buffers as transactional catalogue entries.
//
// These exercise the integration rather than the text structure: atomic commit
// with relation writes, snapshot isolation, read-your-own-writes, revision
// accounting, structural sharing across snapshots, and conservative conflict.
package kernel

import "core:testing"
import buf "../buffer"
import v "../var"

@(private)
buffer_test_sym :: proc(name: string) -> v.Symbol {
	return v.symbol_intern(name)
}

@(private)
buffer_test_identity :: proc(raw: u64) -> v.Value {
	value, _ := v.value_identity_raw(raw)
	return value
}

@(private)
buffer_test_tuple :: proc(values: ..v.Value) -> v.Tuple {
	return v.tuple_new(context.temp_allocator, values)
}

@(private)
create_buffer_relation :: proc(
	t: ^testing.T,
	kernel: ^Kernel,
	id: u32,
	name: string,
	conflict: Conflict_Kind = .Reject,
) -> Relation_ID {
	metadata := relation_metadata(Relation_ID(id), buffer_test_sym(name), 0)
	metadata.storage = .Buffer
	metadata.conflict = Conflict_Policy{kind = conflict}
	snapshot, err := kernel_create_relation(kernel, metadata)
	testing.expectf(t, err == .None, "create buffer %s: %v", name, err)
	if snapshot != nil {
		snapshot_release(snapshot)
	}
	return Relation_ID(id)
}

@(private)
create_tuple_relation :: proc(
	t: ^testing.T,
	kernel: ^Kernel,
	id: u32,
	name: string,
	arity: u16,
) -> Relation_ID {
	metadata := relation_metadata(Relation_ID(id), buffer_test_sym(name), arity)
	snapshot, err := kernel_create_relation(kernel, metadata)
	testing.expectf(t, err == .None, "create relation %s: %v", name, err)
	if snapshot != nil {
		snapshot_release(snapshot)
	}
	return Relation_ID(id)
}

@(private)
commit_buffer_tx :: proc(t: ^testing.T, tx: ^Transaction, want: Kernel_Error = .None) {
	snapshot, err := transaction_commit(tx)
	testing.expectf(t, err == want, "commit: expected %v, got %v", want, err)
	if snapshot != nil {
		snapshot_release(snapshot)
	}
	transaction_destroy(tx)
}

@(test)
test_kernel_buffer_commits_and_reads :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	kernel: Kernel
	kernel_init(&kernel)
	defer kernel_destroy(&kernel)

	notes := create_buffer_relation(t, &kernel, 1, "notes")
	testing.expect_value(t, kernel_buffer_revision(&kernel, notes), u64(0))
	testing.expect_value(t, kernel_buffer_text(&kernel, notes, context.temp_allocator), "")

	tx := kernel_begin(&kernel)
	testing.expect_value(t, transaction_buffer_edit(&tx, notes, 0, 0, "hello"), Kernel_Error.None)
	// Read-your-own-writes sees the staged text; nobody else does yet.
	testing.expect_value(t, transaction_buffer_text(&tx, notes, context.temp_allocator), "hello")
	testing.expect_value(t, kernel_buffer_text(&kernel, notes, context.temp_allocator), "")
	commit_buffer_tx(t, &tx)

	testing.expect_value(t, kernel_buffer_text(&kernel, notes, context.temp_allocator), "hello")
	testing.expect_value(t, kernel_buffer_revision(&kernel, notes), u64(1))
}

@(test)
test_kernel_buffer_edits_are_view_relative :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	kernel: Kernel
	kernel_init(&kernel)
	defer kernel_destroy(&kernel)

	notes := create_buffer_relation(t, &kernel, 1, "notes")

	tx := kernel_begin(&kernel)
	testing.expect_value(t, transaction_buffer_edit(&tx, notes, 0, 0, "abc"), Kernel_Error.None)
	// Offset 3 exists only in the view the first edit produced; the base buffer
	// is empty. A base-relative reading would reject this.
	testing.expect_value(t, transaction_buffer_edit(&tx, notes, 3, 0, "X"), Kernel_Error.None)
	testing.expect_value(t, transaction_buffer_text(&tx, notes, context.temp_allocator), "abcX")
	commit_buffer_tx(t, &tx)

	testing.expect_value(t, kernel_buffer_text(&kernel, notes, context.temp_allocator), "abcX")
}

@(test)
test_kernel_buffer_and_relation_write_commit_atomically :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	kernel: Kernel
	kernel_init(&kernel)
	defer kernel_destroy(&kernel)

	notes := create_buffer_relation(t, &kernel, 1, "notes")
	held_by := create_tuple_relation(t, &kernel, 2, "HeldBy", 2)
	alice := buffer_test_identity(1)
	lamp := buffer_test_identity(2)
	fact := buffer_test_tuple(alice, lamp)

	tx := kernel_begin(&kernel)
	testing.expect_value(t, transaction_assert(&tx, held_by, fact), Kernel_Error.None)
	testing.expect_value(t, transaction_buffer_edit(&tx, notes, 0, 0, "draft"), Kernel_Error.None)

	// Neither write is visible before publication.
	testing.expect(t, !kernel_contains(&kernel, held_by, fact))
	testing.expect_value(t, kernel_buffer_text(&kernel, notes, context.temp_allocator), "")
	commit_buffer_tx(t, &tx)

	// Both are visible together after it.
	testing.expect(t, kernel_contains(&kernel, held_by, fact))
	testing.expect_value(t, kernel_buffer_text(&kernel, notes, context.temp_allocator), "draft")
}

@(test)
test_kernel_buffer_isolation_across_snapshots :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	kernel: Kernel
	kernel_init(&kernel)
	defer kernel_destroy(&kernel)

	notes := create_buffer_relation(t, &kernel, 1, "notes")

	tx := kernel_begin(&kernel)
	transaction_buffer_edit(&tx, notes, 0, 0, "hello")
	commit_buffer_tx(t, &tx)

	reader := kernel_snapshot(&kernel)
	defer snapshot_release(reader)

	tx2 := kernel_begin(&kernel)
	transaction_buffer_edit(&tx2, notes, 5, 0, " world")
	commit_buffer_tx(t, &tx2)

	// The retained reader still sees the version it acquired.
	testing.expect_value(t, snapshot_buffer_text(reader, notes, context.temp_allocator), "hello")
	testing.expect_value(t, kernel_buffer_text(&kernel, notes, context.temp_allocator), "hello world")
	testing.expect_value(t, kernel_buffer_revision(&kernel, notes), u64(2))
}

@(test)
test_kernel_untouched_buffer_root_is_shared_across_snapshots :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	kernel: Kernel
	kernel_init(&kernel)
	defer kernel_destroy(&kernel)

	notes := create_buffer_relation(t, &kernel, 1, "notes")
	held_by := create_tuple_relation(t, &kernel, 2, "HeldBy", 2)

	tx := kernel_begin(&kernel)
	transaction_buffer_edit(&tx, notes, 0, 0, "shared")
	commit_buffer_tx(t, &tx)

	before := kernel_snapshot(&kernel)
	defer snapshot_release(before)
	before_block, before_ok := snapshot_buffer(before, notes)
	testing.expect(t, before_ok)

	// A commit that touches only a relation must not copy the buffer's root.
	write_tx := kernel_begin(&kernel)
	transaction_assert(
		&write_tx,
		held_by,
		buffer_test_tuple(buffer_test_identity(1), buffer_test_identity(2)),
	)
	commit_buffer_tx(t, &write_tx)

	after := kernel_snapshot(&kernel)
	defer snapshot_release(after)
	after_block, after_ok := snapshot_buffer(after, notes)
	testing.expect(t, after_ok)
	testing.expectf(
		t,
		before_block.root == after_block.root,
		"untouched buffer root was copied",
	)
	testing.expect_value(t, after_block.revision, before_block.revision)
}

@(test)
test_kernel_buffer_concurrent_edit_conflicts :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	kernel: Kernel
	kernel_init(&kernel)
	defer kernel_destroy(&kernel)

	notes := create_buffer_relation(t, &kernel, 1, "notes")

	tx_a := kernel_begin(&kernel)
	tx_b := kernel_begin(&kernel)
	testing.expect_value(t, transaction_buffer_edit(&tx_a, notes, 0, 0, "A"), Kernel_Error.None)
	testing.expect_value(t, transaction_buffer_edit(&tx_b, notes, 0, 0, "B"), Kernel_Error.None)

	commit_buffer_tx(t, &tx_a)
	// Conservative Reject: the second transaction's base is stale.
	commit_buffer_tx(t, &tx_b, .Conflict)

	testing.expect_value(t, kernel_buffer_text(&kernel, notes, context.temp_allocator), "A")
	testing.expect_value(t, kernel_buffer_revision(&kernel, notes), u64(1))
}

@(test)
test_kernel_buffer_span_policy_is_conservatively_rejecting :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	kernel: Kernel
	kernel_init(&kernel)
	defer kernel_destroy(&kernel)

	// Span merging is not implemented yet. A `Span` buffer must behave
	// conservatively rather than silently diverging.
	shared := create_buffer_relation(t, &kernel, 1, "shared", .Span)

	tx_a := kernel_begin(&kernel)
	tx_b := kernel_begin(&kernel)
	transaction_buffer_edit(&tx_a, shared, 0, 0, "A")
	transaction_buffer_edit(&tx_b, shared, 0, 0, "B")
	commit_buffer_tx(t, &tx_a)
	commit_buffer_tx(t, &tx_b, .Conflict)
}

@(test)
test_kernel_buffer_whole_policy_never_conflicts :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	kernel: Kernel
	kernel_init(&kernel)
	defer kernel_destroy(&kernel)

	scratch := create_buffer_relation(t, &kernel, 1, "scratch", .Whole)

	tx_a := kernel_begin(&kernel)
	tx_b := kernel_begin(&kernel)
	transaction_buffer_edit(&tx_a, scratch, 0, 0, "first")
	transaction_buffer_edit(&tx_b, scratch, 0, 0, "second")

	commit_buffer_tx(t, &tx_a)
	// Last-writer-wins: the second transaction replaces the content.
	commit_buffer_tx(t, &tx_b)
	testing.expect_value(t, kernel_buffer_text(&kernel, scratch, context.temp_allocator), "second")
	testing.expect_value(t, kernel_buffer_revision(&kernel, scratch), u64(2))
}

@(test)
test_kernel_buffer_revisions_are_monotonic :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	kernel: Kernel
	kernel_init(&kernel)
	defer kernel_destroy(&kernel)

	notes := create_buffer_relation(t, &kernel, 1, "notes")

	for step in 1 ..= 3 {
		tx := kernel_begin(&kernel)
		testing.expect_value(
			t,
			transaction_buffer_edit(&tx, notes, u64(step - 1), 0, "x"),
			Kernel_Error.None,
		)
		commit_buffer_tx(t, &tx)
		testing.expect_value(t, kernel_buffer_revision(&kernel, notes), u64(step))
	}
	testing.expect_value(t, kernel_buffer_text(&kernel, notes, context.temp_allocator), "xxx")
	// No edits means no publish, so the revision stays put.
	testing.expect_value(t, kernel_buffer_epoch(&kernel, notes), u64(0))
}

@(test)
test_kernel_buffer_relation_metadata_is_validated :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	kernel: Kernel
	kernel_init(&kernel)
	defer kernel_destroy(&kernel)

	// A buffer has no columns.
	bad_arity := relation_metadata(Relation_ID(90), buffer_test_sym("bad_arity"), 2)
	bad_arity.storage = .Buffer
	bad_arity.conflict = Conflict_Policy{kind = .Reject}
	_, arity_error := kernel_create_relation(&kernel, bad_arity)
	testing.expect_value(t, arity_error, Kernel_Error.Invalid_Metadata)

	// A buffer cannot carry a tuple conflict policy.
	bad_conflict := relation_metadata(Relation_ID(91), buffer_test_sym("bad_conflict"), 0)
	bad_conflict.storage = .Buffer
	bad_conflict.conflict = Conflict_Policy{kind = .Set}
	_, conflict_error := kernel_create_relation(&kernel, bad_conflict)
	testing.expect_value(t, conflict_error, Kernel_Error.Invalid_Metadata)

	// A tuple relation cannot carry a buffer conflict policy.
	bad_tuple := relation_metadata(Relation_ID(92), buffer_test_sym("bad_tuple"), 1)
	bad_tuple.conflict = Conflict_Policy{kind = .Reject}
	_, tuple_error := kernel_create_relation(&kernel, bad_tuple)
	testing.expect_value(t, tuple_error, Kernel_Error.Invalid_Metadata)
}

@(test)
test_kernel_buffer_edit_on_tuple_relation_is_unknown :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	kernel: Kernel
	kernel_init(&kernel)
	defer kernel_destroy(&kernel)

	held_by := create_tuple_relation(t, &kernel, 1, "HeldBy", 2)
	tx := kernel_begin(&kernel)
	testing.expect_value(
		t,
		transaction_buffer_edit(&tx, held_by, 0, 0, "nope"),
		Kernel_Error.Unknown_Relation,
	)
	transaction_destroy(&tx)
}

// --- Staged catalogue creation --------------------------------------------

@(private)
staged_metadata :: proc(name: string, storage: Storage_Kind) -> Relation_Metadata {
	metadata := relation_metadata(0, buffer_test_sym(name), 0)
	metadata.storage = storage
	metadata.conflict = Conflict_Policy{kind = .Reject}
	return metadata
}

@(test)
test_kernel_buffer_creation_with_content_is_atomic :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	kernel: Kernel
	kernel_init(&kernel)
	defer kernel_destroy(&kernel)

	tx := kernel_begin(&kernel)
	notes, create_error := transaction_create_relation(
		&tx,
		staged_metadata("notes", .Buffer),
	)
	testing.expect_value(t, create_error, Kernel_Error.None)
	testing.expect(t, notes != 0)

	// The creating transaction resolves and uses its own entry immediately.
	testing.expect_value(t, transaction_buffer_edit(&tx, notes, 0, 0, "hello"), Kernel_Error.None)
	testing.expect_value(t, transaction_buffer_text(&tx, notes, context.temp_allocator), "hello")

	// Nothing is visible to anyone else yet: not the entry, not the content.
	testing.expect_value(t, kernel_buffer_text(&kernel, notes, context.temp_allocator), "")
	{
		snapshot := kernel_snapshot(&kernel)
		_, found := snapshot_relation_metadata_named(snapshot, buffer_test_sym("notes"))
		snapshot_release(snapshot)
		testing.expect(t, !found)
	}

	commit_buffer_tx(t, &tx)

	// Entry, content, and metadata appear together.
	testing.expect_value(t, kernel_buffer_text(&kernel, notes, context.temp_allocator), "hello")
	testing.expect_value(t, kernel_buffer_revision(&kernel, notes), u64(1))
	snapshot := kernel_snapshot(&kernel)
	defer snapshot_release(snapshot)
	created, found := snapshot_relation_metadata_named(snapshot, buffer_test_sym("notes"))
	testing.expect(t, found)
	if found {
		testing.expect_value(t, created.storage, Storage_Kind.Buffer)
		testing.expect_value(t, created.conflict.kind, Conflict_Kind.Reject)
		testing.expect_value(t, created.durability, Relation_Durability.Durable)
	}
}

@(test)
test_kernel_staged_relation_accepts_facts_immediately :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	kernel: Kernel
	kernel_init(&kernel)
	defer kernel_destroy(&kernel)

	number, _ := v.value_int(42)
	fact := buffer_test_tuple(number)

	tx := kernel_begin(&kernel)
	metadata := relation_metadata(0, buffer_test_sym("Counts"), 1)
	counter, create_error := transaction_create_relation(&tx, metadata)
	testing.expect_value(t, create_error, Kernel_Error.None)
	testing.expect_value(t, transaction_assert(&tx, counter, fact), Kernel_Error.None)

	testing.expect(t, !kernel_contains(&kernel, counter, fact))
	commit_buffer_tx(t, &tx)
	testing.expect(t, kernel_contains(&kernel, counter, fact))
}

@(test)
test_kernel_staged_creation_abort_publishes_nothing :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	kernel: Kernel
	kernel_init(&kernel)
	defer kernel_destroy(&kernel)

	tx := kernel_begin(&kernel)
	notes, _ := transaction_create_relation(&tx, staged_metadata("abandoned", .Buffer))
	transaction_buffer_edit(&tx, notes, 0, 0, "gone")
	// Abort: no commit, just teardown.
	transaction_destroy(&tx)

	snapshot := kernel_snapshot(&kernel)
	defer snapshot_release(snapshot)
	_, found := snapshot_relation_metadata_named(snapshot, buffer_test_sym("abandoned"))
	testing.expect(t, !found)
}

@(test)
test_kernel_staged_creation_rejects_duplicate_names :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	kernel: Kernel
	kernel_init(&kernel)
	defer kernel_destroy(&kernel)

	create_buffer_relation(t, &kernel, 1, "existing")

	// Against the base catalogue.
	tx := kernel_begin(&kernel)
	_, base_error := transaction_create_relation(&tx, staged_metadata("existing", .Buffer))
	testing.expect_value(t, base_error, Kernel_Error.Duplicate_Relation_Name)

	// Against another staged entry in the same transaction.
	_, first_error := transaction_create_relation(&tx, staged_metadata("fresh", .Buffer))
	testing.expect_value(t, first_error, Kernel_Error.None)
	_, second_error := transaction_create_relation(&tx, staged_metadata("fresh", .Buffer))
	testing.expect_value(t, second_error, Kernel_Error.Duplicate_Relation_Name)
	transaction_destroy(&tx)
}

@(test)
test_kernel_staged_creation_rejects_explicit_id_collision :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	kernel: Kernel
	kernel_init(&kernel)
	defer kernel_destroy(&kernel)

	create_buffer_relation(t, &kernel, 4, "taken")

	tx := kernel_begin(&kernel)
	metadata := staged_metadata("clashing", .Buffer)
	metadata.id = Relation_ID(4)
	_, create_error := transaction_create_relation(&tx, metadata)
	testing.expect_value(t, create_error, Kernel_Error.Invalid_Metadata)
	transaction_destroy(&tx)
}

@(test)
test_kernel_concurrent_creation_of_one_name_conflicts :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	kernel: Kernel
	kernel_init(&kernel)
	defer kernel_destroy(&kernel)

	tx_a := kernel_begin(&kernel)
	tx_b := kernel_begin(&kernel)

	first, a_error := transaction_create_relation(&tx_a, staged_metadata("shared", .Buffer))
	testing.expect_value(t, a_error, Kernel_Error.None)
	second, b_error := transaction_create_relation(&tx_b, staged_metadata("shared", .Buffer))
	testing.expect_value(t, b_error, Kernel_Error.None)
	// Reservations are distinct, so this is a name collision, not an id one.
	testing.expect(t, first != second)

	testing.expect_value(t, transaction_buffer_edit(&tx_a, first, 0, 0, "A"), Kernel_Error.None)
	testing.expect_value(t, transaction_buffer_edit(&tx_b, second, 0, 0, "B"), Kernel_Error.None)

	commit_buffer_tx(t, &tx_a)
	// The second creator loses: its staged name now exists.
	commit_buffer_tx(t, &tx_b, .Conflict)

	testing.expect_value(t, kernel_buffer_text(&kernel, first, context.temp_allocator), "A")

	snapshot := kernel_snapshot(&kernel)
	defer snapshot_release(snapshot)
	_, found := snapshot_relation_metadata_named(snapshot, buffer_test_sym("shared"))
	testing.expect(t, found)
	// Exactly one entry by that name.
	count := 0
	for metadata in snapshot.catalog {
		if metadata.name == buffer_test_sym("shared") {
			count += 1
		}
	}
	testing.expect_value(t, count, 1)
}

@(test)
test_kernel_reserved_ids_are_not_reused :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	kernel: Kernel
	kernel_init(&kernel)
	defer kernel_destroy(&kernel)

	tx := kernel_begin(&kernel)
	first, _ := transaction_create_relation(&tx, staged_metadata("one", .Buffer))
	transaction_destroy(&tx)

	// The abort left a gap rather than recycling the id.
	tx2 := kernel_begin(&kernel)
	second, _ := transaction_create_relation(&tx2, staged_metadata("two", .Buffer))
	transaction_destroy(&tx2)
	testing.expect(t, second > first)
}

// --- Compaction -------------------------------------------------------------

@(test)
test_kernel_compaction_preserves_revision_and_bumps_epoch :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	kernel: Kernel
	kernel_init(&kernel)
	defer kernel_destroy(&kernel)

	notes := create_buffer_relation(t, &kernel, 1, "notes")

	tx := kernel_begin(&kernel)
	transaction_buffer_edit(&tx, notes, 0, 0, "hello world")
	commit_buffer_tx(t, &tx)
	testing.expect_value(t, kernel_buffer_revision(&kernel, notes), u64(1))
	testing.expect_value(t, kernel_buffer_epoch(&kernel, notes), u64(0))

	compact := kernel_begin(&kernel)
	testing.expect_value(
		t,
		transaction_buffer_compact(&compact, notes),
		Kernel_Error.None,
	)
	commit_buffer_tx(t, &compact)

	// Content and revision are unchanged; only the chunk lineage moved.
	testing.expect_value(t, kernel_buffer_text(&kernel, notes, context.temp_allocator), "hello world")
	testing.expect_value(t, kernel_buffer_revision(&kernel, notes), u64(1))
	testing.expect_value(t, kernel_buffer_epoch(&kernel, notes), u64(1))

	// Editing still works after compaction.
	edit := kernel_begin(&kernel)
	transaction_buffer_edit(&edit, notes, 11, 0, "!")
	commit_buffer_tx(t, &edit)
	testing.expect_value(
		t,
		kernel_buffer_text(&kernel, notes, context.temp_allocator),
		"hello world!",
	)
	testing.expect_value(t, kernel_buffer_revision(&kernel, notes), u64(2))
	testing.expect_value(t, kernel_buffer_epoch(&kernel, notes), u64(1))
}

// A transaction whose base predates a compaction, and whose content revision is
// otherwise unchanged, re-applies its edits to the current root rather than
// publishing pre-compaction chunks under the new epoch.
@(test)
test_kernel_reapplies_edits_across_a_compaction :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	kernel: Kernel
	kernel_init(&kernel)
	defer kernel_destroy(&kernel)

	notes := create_buffer_relation(t, &kernel, 1, "notes")

	// The transaction reads at epoch 0, revision 0.
	stale := kernel_begin(&kernel)

	compact := kernel_begin(&kernel)
	transaction_buffer_compact(&compact, notes)
	commit_buffer_tx(t, &compact)
	testing.expect_value(t, kernel_buffer_epoch(&kernel, notes), u64(1))
	testing.expect_value(t, kernel_buffer_revision(&kernel, notes), u64(0))

	// Its edit is re-applied under the new epoch.
	testing.expect_value(t, transaction_buffer_edit(&stale, notes, 0, 0, "kept"), Kernel_Error.None)
	commit_buffer_tx(t, &stale)
	testing.expect_value(t, kernel_buffer_text(&kernel, notes, context.temp_allocator), "kept")
	testing.expect_value(t, kernel_buffer_revision(&kernel, notes), u64(1))
	testing.expect_value(t, kernel_buffer_epoch(&kernel, notes), u64(1))
}

// Provenance cannot be compared across a compaction boundary, so a transaction
// that also missed a content change conflicts rather than guessing.
@(test)
test_kernel_rebase_across_a_compaction_conflicts :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	kernel: Kernel
	kernel_init(&kernel)
	defer kernel_destroy(&kernel)

	notes := create_buffer_relation(t, &kernel, 1, "notes")

	stale := kernel_begin(&kernel)

	edit := kernel_begin(&kernel)
	transaction_buffer_edit(&edit, notes, 0, 0, "theirs")
	commit_buffer_tx(t, &edit)

	compact := kernel_begin(&kernel)
	transaction_buffer_compact(&compact, notes)
	commit_buffer_tx(t, &compact)

	// Both the revision and the epoch moved.
	testing.expect_value(t, transaction_buffer_edit(&stale, notes, 0, 0, "mine"), Kernel_Error.None)
	commit_buffer_tx(t, &stale, .Conflict)
	testing.expect_value(t, kernel_buffer_text(&kernel, notes, context.temp_allocator), "theirs")
}

// --- Revision-checked apply -------------------------------------------------

@(test)
test_kernel_buffer_apply_checks_revision :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	kernel: Kernel
	kernel_init(&kernel)
	defer kernel_destroy(&kernel)

	notes := create_buffer_relation(t, &kernel, 1, "notes")
	seed := kernel_begin(&kernel)
	transaction_buffer_edit(&seed, notes, 0, 0, "hi")
	commit_buffer_tx(t, &seed)
	testing.expect_value(t, kernel_buffer_revision(&kernel, notes), u64(1))

	// A stale revision is refused, and nothing is staged.
	stale := kernel_begin(&kernel)
	stale_edits := []buf.Edit{{at = 0, remove = 2, text = "no"}}
	testing.expect_value(
		t,
		transaction_buffer_apply(&stale, notes, 99, stale_edits),
		Apply_Status.Stale,
	)
	testing.expect_value(t, transaction_buffer_text(&stale, notes, context.temp_allocator), "hi")
	commit_buffer_tx(t, &stale)
	testing.expect_value(t, kernel_buffer_text(&kernel, notes, context.temp_allocator), "hi")

	// The matching revision stages.
	apply := kernel_begin(&kernel)
	edits := []buf.Edit{{at = 0, remove = 2, text = "yo"}}
	testing.expect_value(
		t,
		transaction_buffer_apply(&apply, notes, 1, edits),
		Apply_Status.Applied,
	)
	testing.expect_value(t, transaction_buffer_text(&apply, notes, context.temp_allocator), "yo")

	// A second apply, and a bare mutation after one, are refused: client
	// offsets are only safe on a pristine view.
	testing.expect_value(
		t,
		transaction_buffer_apply(&apply, notes, 1, edits),
		Apply_Status.Already_Applied,
	)
	testing.expect_value(
		t,
		transaction_buffer_edit(&apply, notes, 0, 0, "bare"),
		Kernel_Error.Already_Applied,
	)
	commit_buffer_tx(t, &apply)
	testing.expect_value(t, kernel_buffer_text(&kernel, notes, context.temp_allocator), "yo")
	testing.expect_value(t, kernel_buffer_revision(&kernel, notes), u64(2))
}

@(test)
test_kernel_buffer_apply_batches_edits_in_order :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	kernel: Kernel
	kernel_init(&kernel)
	defer kernel_destroy(&kernel)

	notes := create_buffer_relation(t, &kernel, 1, "notes")

	apply := kernel_begin(&kernel)
	// Two edits in one batch, the second addressing the view the first made.
	edits := []buf.Edit {
		{at = 0, remove = 0, text = "abc"},
		{at = 3, remove = 0, text = "def"},
	}
	testing.expect_value(
		t,
		transaction_buffer_apply(&apply, notes, 0, edits),
		Apply_Status.Applied,
	)
	testing.expect_value(t, transaction_buffer_text(&apply, notes, context.temp_allocator), "abcdef")
	commit_buffer_tx(t, &apply)
	testing.expect_value(t, kernel_buffer_text(&kernel, notes, context.temp_allocator), "abcdef")
}

// --- Span merging -----------------------------------------------------------

@(test)
test_kernel_span_merges_disjoint_concurrent_edits :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	kernel: Kernel
	kernel_init(&kernel)
	defer kernel_destroy(&kernel)

	shared := create_buffer_relation(t, &kernel, 1, "shared", .Span)
	seed := kernel_begin(&kernel)
	transaction_buffer_edit(&seed, shared, 0, 0, "hello world")
	commit_buffer_tx(t, &seed)
	testing.expect_value(t, kernel_buffer_revision(&kernel, shared), u64(1))

	// Two transactions read the same base and touch different regions.
	replace_head := kernel_begin(&kernel)
	append_tail := kernel_begin(&kernel)
	testing.expect_value(
		t,
		transaction_buffer_edit(&replace_head, shared, 0, 5, "HELLO"),
		Kernel_Error.None,
	)
	testing.expect_value(
		t,
		transaction_buffer_edit(&append_tail, shared, 11, 0, "!"),
		Kernel_Error.None,
	)

	commit_buffer_tx(t, &replace_head)
	testing.expect_value(t, kernel_buffer_text(&kernel, shared, context.temp_allocator), "HELLO world")

	// The second commit is rebased and merged rather than refused.
	commit_buffer_tx(t, &append_tail)
	testing.expect_value(
		t,
		kernel_buffer_text(&kernel, shared, context.temp_allocator),
		"HELLO world!",
	)
	testing.expect_value(t, kernel_buffer_revision(&kernel, shared), u64(3))
}

@(test)
test_kernel_span_refuses_overlapping_concurrent_edits :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	kernel: Kernel
	kernel_init(&kernel)
	defer kernel_destroy(&kernel)

	shared := create_buffer_relation(t, &kernel, 1, "shared", .Span)
	seed := kernel_begin(&kernel)
	transaction_buffer_edit(&seed, shared, 0, 0, "hello world")
	commit_buffer_tx(t, &seed)

	first := kernel_begin(&kernel)
	second := kernel_begin(&kernel)
	transaction_buffer_edit(&first, shared, 0, 5, "HELLO")
	transaction_buffer_edit(&second, shared, 3, 8, "XXX")

	commit_buffer_tx(t, &first)
	commit_buffer_tx(t, &second, .Conflict)
	testing.expect_value(t, kernel_buffer_text(&kernel, shared, context.temp_allocator), "HELLO world")
}

// Merging needs comparable provenance, so a compaction boundary refuses even
// under the merging policy.
@(test)
test_kernel_span_refuses_across_a_compaction :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	kernel: Kernel
	kernel_init(&kernel)
	defer kernel_destroy(&kernel)

	shared := create_buffer_relation(t, &kernel, 1, "shared", .Span)
	seed := kernel_begin(&kernel)
	transaction_buffer_edit(&seed, shared, 0, 0, "hello")
	commit_buffer_tx(t, &seed)

	stale := kernel_begin(&kernel)

	edit := kernel_begin(&kernel)
	transaction_buffer_edit(&edit, shared, 5, 0, " there")
	commit_buffer_tx(t, &edit)

	compact := kernel_begin(&kernel)
	transaction_buffer_compact(&compact, shared)
	commit_buffer_tx(t, &compact)

	transaction_buffer_edit(&stale, shared, 0, 0, ">")
	commit_buffer_tx(t, &stale, .Conflict)
}

// --- Lifecycle --------------------------------------------------------------

@(test)
test_kernel_kill_buffer_tombstones_and_releases :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	kernel: Kernel
	kernel_init(&kernel)
	defer kernel_destroy(&kernel)

	notes := create_buffer_relation(t, &kernel, 1, "notes")
	tx := kernel_begin(&kernel)
	transaction_buffer_edit(&tx, notes, 0, 0, "hello")
	commit_buffer_tx(t, &tx)
	testing.expect_value(t, kernel_buffer_text(&kernel, notes, context.temp_allocator), "hello")

	kill := kernel_begin(&kernel)
	testing.expect_value(t, transaction_kill_relation(&kill, notes), Kernel_Error.None)
	commit_buffer_tx(t, &kill)

	// The entry survives as a tombstone; its content is gone.
	snapshot := kernel_snapshot(&kernel)
	metadata, found := snapshot_relation_metadata(snapshot, notes)
	testing.expect(t, found)
	testing.expect(t, metadata.tombstoned)
	testing.expect_value(t, snapshot_buffer_text(snapshot, notes, context.temp_allocator), "")
	snapshot_release(snapshot)

	// Killing again is a no-op rather than an error.
	again := kernel_begin(&kernel)
	testing.expect_value(t, transaction_kill_relation(&again, notes), Kernel_Error.None)
	commit_buffer_tx(t, &again)

	// Ids are never reused, so a fresh entry cannot alias the killed one.
	revived := create_buffer_relation(t, &kernel, 0, "notes_two")
	testing.expect(t, revived != notes)
}

@(test)
test_kernel_kill_of_a_staged_creation_is_a_tombstone :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	kernel: Kernel
	kernel_init(&kernel)
	defer kernel_destroy(&kernel)

	tx := kernel_begin(&kernel)
	notes, create_error := transaction_create_relation(
		&tx,
		staged_metadata("ephemeral", .Buffer),
	)
	testing.expect_value(t, create_error, Kernel_Error.None)
	transaction_buffer_edit(&tx, notes, 0, 0, "gone")
	testing.expect_value(t, transaction_kill_relation(&tx, notes), Kernel_Error.None)

	// The kill is visible to this transaction immediately.
	metadata, known := transaction_relation_metadata(&tx, notes)
	testing.expect(t, known)
	testing.expect(t, metadata.tombstoned)
	commit_buffer_tx(t, &tx)

	snapshot := kernel_snapshot(&kernel)
	defer snapshot_release(snapshot)
	committed, found := snapshot_relation_metadata(snapshot, notes)
	testing.expect(t, found)
	testing.expect(t, committed.tombstoned)
	testing.expect_value(t, snapshot_buffer_text(snapshot, notes, context.temp_allocator), "")
}

// --- Completion results -----------------------------------------------------

@(test)
test_kernel_buffer_apply_reports_completion :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	kernel: Kernel
	kernel_init(&kernel)
	defer kernel_destroy(&kernel)

	notes := create_buffer_relation(t, &kernel, 1, "notes")
	seed := kernel_begin(&kernel)
	transaction_buffer_edit(&seed, notes, 0, 0, "hello")
	commit_buffer_tx(t, &seed)

	apply := kernel_begin(&kernel)
	edits := []buf.Edit{{at = 5, remove = 0, text = "!"}}
	testing.expect_value(
		t,
		transaction_buffer_apply(&apply, notes, 1, edits, 777),
		Apply_Status.Applied,
	)
	// Nothing is knowable before publication.
	_, early := kernel_buffer_result(&kernel, 777)
	testing.expect(t, !early)
	commit_buffer_tx(t, &apply)

	result, found := kernel_buffer_result(&kernel, 777)
	testing.expect(t, found)
	testing.expect_value(t, result.outcome, Buffer_Apply_Outcome.Ok)
	testing.expect_value(t, result.revision, u64(2))
	testing.expect_value(t, len(result.delta.replacements), 1)
	testing.expect_value(
		t,
		result.delta.replacements[0],
		buf.Replacement{start = 5, end = 5, text = "!"},
	)
}

@(test)
test_kernel_buffer_apply_reports_abandonment :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	kernel: Kernel
	kernel_init(&kernel)
	defer kernel_destroy(&kernel)

	notes := create_buffer_relation(t, &kernel, 1, "notes")
	seed := kernel_begin(&kernel)
	transaction_buffer_edit(&seed, notes, 0, 0, "hello")
	commit_buffer_tx(t, &seed)

	apply := kernel_begin(&kernel)
	edits := []buf.Edit{{at = 5, remove = 0, text = "!"}}
	transaction_buffer_apply(&apply, notes, 1, edits, 888)
	// Abandoned: the client must learn that it never published rather than
	// waiting forever.
	transaction_destroy(&apply)

	result, found := kernel_buffer_result(&kernel, 888)
	testing.expect(t, found)
	testing.expect_value(t, result.outcome, Buffer_Apply_Outcome.Aborted)
}

// A rebase publishes onto a version the client never saw, but the authoritative
// delta is composed against the client's own baseline, so the client can still
// reconcile. It is not reported as `:resync` for a committed edit.
@(test)
test_kernel_buffer_apply_composes_across_a_rebase :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	kernel: Kernel
	kernel_init(&kernel)
	defer kernel_destroy(&kernel)

	shared := create_buffer_relation(t, &kernel, 1, "shared", .Span)
	seed := kernel_begin(&kernel)
	transaction_buffer_edit(&seed, shared, 0, 0, "hello world")
	commit_buffer_tx(t, &seed)

	// The client read revision 1 and appends at its end.
	ours := kernel_begin(&kernel)
	edits := []buf.Edit{{at = 11, remove = 0, text = "!"}}
	transaction_buffer_apply(&ours, shared, 1, edits, 999)

	// A concurrent edit lands first, so our commit rebases onto revision 2.
	theirs := kernel_begin(&kernel)
	transaction_buffer_edit(&theirs, shared, 0, 5, "HELLO")
	commit_buffer_tx(t, &theirs)

	commit_buffer_tx(t, &ours)
	testing.expect_value(
		t,
		kernel_buffer_text(&kernel, shared, context.temp_allocator),
		"HELLO world!",
	)

	result, found := kernel_buffer_result(&kernel, 999)
	testing.expect(t, found)
	testing.expect_value(t, result.outcome, Buffer_Apply_Outcome.Ok)
	testing.expect_value(t, result.revision, u64(3))
	// Relative to revision 1: the winner's replacement and our insertion, in
	// ascending order.
	testing.expect_value(t, len(result.delta.replacements), 2)
	if len(result.delta.replacements) == 2 {
		testing.expect_value(
			t,
			result.delta.replacements[0],
			buf.Replacement{start = 0, end = 5, text = "HELLO"},
		)
		testing.expect_value(
			t,
			result.delta.replacements[1],
			buf.Replacement{start = 11, end = 11, text = "!"},
		)
	}
}

// An overlapping concurrent change publishes nothing and tells the client to
// re-read and resubmit, rather than reporting a bare abort.
@(test)
test_kernel_buffer_apply_reports_conflict_on_overlap :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	kernel: Kernel
	kernel_init(&kernel)
	defer kernel_destroy(&kernel)

	shared := create_buffer_relation(t, &kernel, 1, "shared", .Span)
	seed := kernel_begin(&kernel)
	transaction_buffer_edit(&seed, shared, 0, 0, "hello world")
	commit_buffer_tx(t, &seed)

	ours := kernel_begin(&kernel)
	edits := []buf.Edit{{at = 0, remove = 5, text = "HI"}}
	testing.expect_value(
		t,
		transaction_buffer_apply(&ours, shared, 1, edits, 555),
		Apply_Status.Applied,
	)

	theirs := kernel_begin(&kernel)
	transaction_buffer_edit(&theirs, shared, 0, 5, "HELLO")
	commit_buffer_tx(t, &theirs)

	commit_buffer_tx(t, &ours, .Conflict)
	testing.expect_value(
		t,
		kernel_buffer_text(&kernel, shared, context.temp_allocator),
		"HELLO world",
	)

	result, found := kernel_buffer_result(&kernel, 555)
	testing.expect(t, found)
	testing.expect_value(t, result.outcome, Buffer_Apply_Outcome.Conflict)
}

// When a concurrent content change also crossed a compaction boundary, the
// server cannot compose a delta the client could apply: it resyncs and publishes
// nothing, so the completion is never `:ok` against the wrong baseline.
@(test)
test_kernel_buffer_apply_reports_resync_across_an_epoch :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	kernel: Kernel
	kernel_init(&kernel)
	defer kernel_destroy(&kernel)

	shared := create_buffer_relation(t, &kernel, 1, "shared", .Span)
	seed := kernel_begin(&kernel)
	transaction_buffer_edit(&seed, shared, 0, 0, "hello")
	commit_buffer_tx(t, &seed)

	ours := kernel_begin(&kernel)
	edits := []buf.Edit{{at = 0, remove = 0, text = ">"}}
	testing.expect_value(
		t,
		transaction_buffer_apply(&ours, shared, 1, edits, 666),
		Apply_Status.Applied,
	)

	theirs := kernel_begin(&kernel)
	transaction_buffer_edit(&theirs, shared, 5, 0, " there")
	commit_buffer_tx(t, &theirs)

	compact := kernel_begin(&kernel)
	transaction_buffer_compact(&compact, shared)
	commit_buffer_tx(t, &compact)

	commit_buffer_tx(t, &ours, .Conflict)
	testing.expect_value(
		t,
		kernel_buffer_text(&kernel, shared, context.temp_allocator),
		"hello there",
	)

	result, found := kernel_buffer_result(&kernel, 666)
	testing.expect(t, found)
	testing.expect_value(t, result.outcome, Buffer_Apply_Outcome.Resync)
}

// A conservative buffer refuses a moved revision before materialization; the
// tagged client learns it is a conflict rather than a bare abort.
@(test)
test_kernel_buffer_apply_reports_conflict_on_reject :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	kernel: Kernel
	kernel_init(&kernel)
	defer kernel_destroy(&kernel)

	notes := create_buffer_relation(t, &kernel, 1, "notes")
	seed := kernel_begin(&kernel)
	transaction_buffer_edit(&seed, notes, 0, 0, "one")
	commit_buffer_tx(t, &seed)

	ours := kernel_begin(&kernel)
	edits := []buf.Edit{{at = 3, remove = 0, text = "!"}}
	testing.expect_value(
		t,
		transaction_buffer_apply(&ours, notes, 1, edits, 777),
		Apply_Status.Applied,
	)

	theirs := kernel_begin(&kernel)
	transaction_buffer_edit(&theirs, notes, 0, 0, "x")
	commit_buffer_tx(t, &theirs)

	commit_buffer_tx(t, &ours, .Conflict)

	result, found := kernel_buffer_result(&kernel, 777)
	testing.expect(t, found)
	testing.expect_value(t, result.outcome, Buffer_Apply_Outcome.Conflict)
}

// --- Reversion --------------------------------------------------------------

// Chunk identities reachable from a root, in view order.
@(private)
buffer_test_chunk_ids :: proc(root: ^buf.Piece_Node) -> [dynamic]u64 {
	pieces: [dynamic]buf.Piece
	pieces = make([dynamic]buf.Piece, context.temp_allocator)
	buf.tree_collect_pieces(root, &pieces)
	ids: [dynamic]u64
	ids = make([dynamic]u64, context.temp_allocator)
	for piece in pieces {
		append(&ids, piece.chunk.id)
	}
	return ids
}

@(private)
buffer_test_has_chunk :: proc(ids: [dynamic]u64, id: u64) -> bool {
	for candidate in ids {
		if candidate == id {
			return true
		}
	}
	return false
}

// Reverting restores an earlier revision's text by rebuilding it into fresh
// chunks, and advances the content revision like any other edit.
@(test)
test_kernel_buffer_revert_restores_an_earlier_revision :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	kernel: Kernel
	kernel_init(&kernel)
	defer kernel_destroy(&kernel)

	notes := create_buffer_relation(t, &kernel, 1, "notes")

	seed := kernel_begin(&kernel)
	transaction_buffer_edit(&seed, notes, 0, 0, "one")
	commit_buffer_tx(t, &seed)

	second := kernel_begin(&kernel)
	transaction_buffer_edit(&second, notes, 0, 3, "two")
	commit_buffer_tx(t, &second)

	third := kernel_begin(&kernel)
	transaction_buffer_edit(&third, notes, 0, 3, "three")
	commit_buffer_tx(t, &third)
	testing.expect_value(t, kernel_buffer_revision(&kernel, notes), u64(3))
	testing.expect_value(t, kernel_buffer_text(&kernel, notes, context.temp_allocator), "three")

	// The transaction reads revision 3 and reverts to revision 1.
	revert := kernel_begin(&kernel)
	testing.expect_value(t, transaction_buffer_revision(&revert, notes), u64(3))
	testing.expect_value(
		t,
		transaction_buffer_revert(&revert, notes, 1, 3),
		Revert_Status.Reverted,
	)
	// Read-your-own-writes sees the restored text before the commit.
	testing.expect_value(t, transaction_buffer_text(&revert, notes, context.temp_allocator), "one")
	commit_buffer_tx(t, &revert)

	testing.expect_value(t, kernel_buffer_text(&kernel, notes, context.temp_allocator), "one")
	// Content advanced by one; structure started a new epoch because the
	// reverted text lives in fresh chunks.
	testing.expect_value(t, kernel_buffer_revision(&kernel, notes), u64(4))
	testing.expect_value(t, kernel_buffer_epoch(&kernel, notes), u64(1))
}

// A reversion is a splice, not the adoption of a historical root: the published
// tree shares no chunk with the version it replaced.
@(test)
test_kernel_buffer_revert_never_adopts_a_historical_root :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	kernel: Kernel
	kernel_init(&kernel)
	defer kernel_destroy(&kernel)

	notes := create_buffer_relation(t, &kernel, 1, "notes")
	seed := kernel_begin(&kernel)
	transaction_buffer_edit(&seed, notes, 0, 0, "original text")
	commit_buffer_tx(t, &seed)
	edit := kernel_begin(&kernel)
	transaction_buffer_edit(&edit, notes, 0, 8, "changed")
	commit_buffer_tx(t, &edit)

	before := kernel_snapshot(&kernel)
	defer snapshot_release(before)
	before_block, before_found := snapshot_buffer(before, notes)
	testing.expect(t, before_found)

	revert := kernel_begin(&kernel)
	testing.expect_value(
		t,
		transaction_buffer_revert(&revert, notes, 1, 2),
		Revert_Status.Reverted,
	)
	commit_buffer_tx(t, &revert)

	after := kernel_snapshot(&kernel)
	defer snapshot_release(after)
	after_block, after_found := snapshot_buffer(after, notes)
	testing.expect(t, after_found)

	testing.expect_value(t, snapshot_buffer_text(after, notes, context.temp_allocator), "original text")
	before_ids := buffer_test_chunk_ids(before_block.root)
	after_ids := buffer_test_chunk_ids(after_block.root)
	testing.expect(t, len(before_ids) > 0)
	for id in after_ids {
		testing.expectf(
			t,
			!buffer_test_has_chunk(before_ids, id),
			"reverted root reused chunk %d from the superseded version",
			id,
		)
	}
}

// The revision check is a precondition, exactly as it is for a revision-checked
// apply, and a refused reversion stages nothing.
@(test)
test_kernel_buffer_revert_checks_revision :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	kernel: Kernel
	kernel_init(&kernel)
	defer kernel_destroy(&kernel)

	notes := create_buffer_relation(t, &kernel, 1, "notes")
	seed := kernel_begin(&kernel)
	transaction_buffer_edit(&seed, notes, 0, 0, "one")
	commit_buffer_tx(t, &seed)
	second := kernel_begin(&kernel)
	transaction_buffer_edit(&second, notes, 0, 3, "two")
	commit_buffer_tx(t, &second)

	stale := kernel_begin(&kernel)
	testing.expect_value(
		t,
		transaction_buffer_revert(&stale, notes, 1, 1),
		Revert_Status.Stale,
	)
	// Nothing was staged: the view is untouched, and committing publishes no
	// new version.
	testing.expect_value(t, transaction_buffer_text(&stale, notes, context.temp_allocator), "two")
	commit_buffer_tx(t, &stale)
	testing.expect_value(t, kernel_buffer_revision(&kernel, notes), u64(2))
	testing.expect_value(t, kernel_buffer_text(&kernel, notes, context.temp_allocator), "two")
}

// A revision that is not retained -- or is newer than the one in hand -- is
// refused rather than guessed at.
@(test)
test_kernel_buffer_revert_refuses_unretained_revisions :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	kernel: Kernel
	kernel_init(&kernel)
	defer kernel_destroy(&kernel)

	notes := create_buffer_relation(t, &kernel, 1, "notes")
	seed := kernel_begin(&kernel)
	transaction_buffer_edit(&seed, notes, 0, 0, "one")
	commit_buffer_tx(t, &seed)
	second := kernel_begin(&kernel)
	transaction_buffer_edit(&second, notes, 0, 3, "two")
	commit_buffer_tx(t, &second)

	tx := kernel_begin(&kernel)
	// A revision that was never published.
	testing.expect_value(
		t,
		transaction_buffer_revert(&tx, notes, 77, 2),
		Revert_Status.Unknown_Revision,
	)
	// A revision in the future cannot be a reversion target.
	testing.expect_value(
		t,
		transaction_buffer_revert(&tx, notes, 3, 2),
		Revert_Status.Unknown_Revision,
	)
	testing.expect_value(t, transaction_buffer_text(&tx, notes, context.temp_allocator), "two")
	commit_buffer_tx(t, &tx)

	// Reverting to the version in hand is a no-op rather than a new version.
	noop := kernel_begin(&kernel)
	testing.expect_value(
		t,
		transaction_buffer_revert(&noop, notes, 2, 2),
		Revert_Status.Reverted,
	)
	commit_buffer_tx(t, &noop)
	testing.expect_value(t, kernel_buffer_revision(&kernel, notes), u64(2))
}

// Reversion replaces the view wholesale, so it is only meaningful before
// anything else has been staged for the buffer, and it locks the view
// afterwards just as a revision-checked apply does.
@(test)
test_kernel_buffer_revert_requires_a_pristine_view :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	kernel: Kernel
	kernel_init(&kernel)
	defer kernel_destroy(&kernel)

	notes := create_buffer_relation(t, &kernel, 1, "notes")
	seed := kernel_begin(&kernel)
	transaction_buffer_edit(&seed, notes, 0, 0, "one")
	commit_buffer_tx(t, &seed)
	second := kernel_begin(&kernel)
	transaction_buffer_edit(&second, notes, 0, 3, "two")
	commit_buffer_tx(t, &second)

	// A bare edit already staged in this transaction would be silently
	// discarded, so the reversion is refused.
	dirty := kernel_begin(&kernel)
	transaction_buffer_edit(&dirty, notes, 0, 0, "prefix ")
	testing.expect_value(
		t,
		transaction_buffer_revert(&dirty, notes, 1, 2),
		Revert_Status.Dirty,
	)
	transaction_destroy(&dirty)

	// After a reversion the view is locked, exactly like a revision-checked
	// apply.
	locked := kernel_begin(&kernel)
	testing.expect_value(
		t,
		transaction_buffer_revert(&locked, notes, 1, 2),
		Revert_Status.Reverted,
	)
	testing.expect_value(
		t,
		transaction_buffer_edit(&locked, notes, 0, 0, "bare"),
		Kernel_Error.Already_Applied,
	)
	testing.expect_value(
		t,
		transaction_buffer_revert(&locked, notes, 1, 2),
		Revert_Status.Dirty,
	)
	commit_buffer_tx(t, &locked)
	testing.expect_value(t, kernel_buffer_text(&kernel, notes, context.temp_allocator), "one")
}

// Compaction must preserve the text of a buffer whose pieces span more than one
// chunk. Rendering the text into an arena-backed builder used to truncate, so
// compaction silently lost the tail of any buffer edited across transactions.
@(test)
test_kernel_compaction_preserves_multi_chunk_text :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	kernel: Kernel
	kernel_init(&kernel)
	defer kernel_destroy(&kernel)

	notes := create_buffer_relation(t, &kernel, 1, "notes")
	seed := kernel_begin(&kernel)
	transaction_buffer_edit(&seed, notes, 0, 0, "hello")
	commit_buffer_tx(t, &seed)

	// The append lands in a second chunk, so the root has two pieces.
	append_tx := kernel_begin(&kernel)
	transaction_buffer_edit(&append_tx, notes, 5, 0, " there")
	commit_buffer_tx(t, &append_tx)
	testing.expect_value(
		t,
		kernel_buffer_text(&kernel, notes, context.temp_allocator),
		"hello there",
	)

	compact := kernel_begin(&kernel)
	testing.expect_value(
		t,
		transaction_buffer_compact(&compact, notes),
		Kernel_Error.None,
	)
	// The rebuilt root is readable before the commit.
	testing.expect_value(
		t,
		transaction_buffer_text(&compact, notes, context.temp_allocator),
		"hello there",
	)
	commit_buffer_tx(t, &compact)

	testing.expect_value(
		t,
		kernel_buffer_text(&kernel, notes, context.temp_allocator),
		"hello there",
	)
	testing.expect_value(t, kernel_buffer_revision(&kernel, notes), u64(2))
	testing.expect_value(t, kernel_buffer_epoch(&kernel, notes), u64(1))

	// Editing continues against the rebuilt root.
	after := kernel_begin(&kernel)
	transaction_buffer_edit(&after, notes, 11, 0, "!")
	commit_buffer_tx(t, &after)
	testing.expect_value(
		t,
		kernel_buffer_text(&kernel, notes, context.temp_allocator),
		"hello there!",
	)
}

// A transaction that read the pre-reversion version conflicts rather than
// silently reapplying its edits to text it never saw.
@(test)
test_kernel_buffer_revert_conflicts_with_a_concurrent_editor :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	kernel: Kernel
	kernel_init(&kernel)
	defer kernel_destroy(&kernel)

	notes := create_buffer_relation(t, &kernel, 1, "notes")
	seed := kernel_begin(&kernel)
	transaction_buffer_edit(&seed, notes, 0, 0, "one")
	commit_buffer_tx(t, &seed)
	second := kernel_begin(&kernel)
	transaction_buffer_edit(&second, notes, 0, 3, "two")
	commit_buffer_tx(t, &second)

	editor := kernel_begin(&kernel)
	transaction_buffer_edit(&editor, notes, 3, 0, "!")

	revert := kernel_begin(&kernel)
	testing.expect_value(
		t,
		transaction_buffer_revert(&revert, notes, 1, 2),
		Revert_Status.Reverted,
	)
	commit_buffer_tx(t, &revert)
	testing.expect_value(t, kernel_buffer_text(&kernel, notes, context.temp_allocator), "one")

	// The editor's base moved under it, and reversion is a whole-buffer
	// replacement, so the conservative policy refuses it.
	commit_buffer_tx(t, &editor, .Conflict)
	testing.expect_value(t, kernel_buffer_text(&kernel, notes, context.temp_allocator), "one")
}

// The history is bounded, so an old revision eventually falls out rather than
// pinning a document forever.
@(test)
test_kernel_buffer_history_is_bounded :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	kernel: Kernel
	kernel_init(&kernel)
	defer kernel_destroy(&kernel)

	notes := create_buffer_relation(t, &kernel, 1, "notes")

	// Publish more versions than the history retains.
	versions := BUFFER_HISTORY_DEPTH + 4
	seed := kernel_begin(&kernel)
	transaction_buffer_edit(&seed, notes, 0, 0, "x")
	commit_buffer_tx(t, &seed)
	// Revision `r` holds `r` scalars, so revision 1 is the seed and the window
	// ends at `versions`.
	for version in 1 ..< versions {
		tx := kernel_begin(&kernel)
		transaction_buffer_edit(&tx, notes, u64(version), 0, "y")
		commit_buffer_tx(t, &tx)
	}
	testing.expect_value(t, kernel_buffer_revision(&kernel, notes), u64(versions))

	// The genesis version has fallen out of the window; revisions inside it are
	// still readable.
	testing.expect(t, buffer_history_lookup(&kernel.buffer_history, notes, 1) == nil)
	retained := buffer_history_lookup(&kernel.buffer_history, notes, 5)
	testing.expect(t, retained != nil)
	if retained != nil {
		buffer_block_release(retained)
	}

	// A revision inside the window still reverts.
	revert := kernel_begin(&kernel)
	testing.expect_value(
		t,
		transaction_buffer_revert(&revert, notes, 5, u64(versions)),
		Revert_Status.Reverted,
	)
	commit_buffer_tx(t, &revert)
	testing.expect_value(t, kernel_buffer_text(&kernel, notes, context.temp_allocator), "xyyyy")
}

// Killing an entry drops its history, so a retired buffer's content is not
// pinned by versions nothing can revert to.
@(test)
test_kernel_kill_buffer_drops_its_history :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	kernel: Kernel
	kernel_init(&kernel)
	defer kernel_destroy(&kernel)

	notes := create_buffer_relation(t, &kernel, 1, "notes")
	seed := kernel_begin(&kernel)
	transaction_buffer_edit(&seed, notes, 0, 0, "keep")
	commit_buffer_tx(t, &seed)
	testing.expect(t, buffer_history_find(&kernel.buffer_history, notes) != nil)

	kill := kernel_begin(&kernel)
	testing.expect_value(t, transaction_kill_relation(&kill, notes), Kernel_Error.None)
	commit_buffer_tx(t, &kill)
	testing.expect(t, buffer_history_find(&kernel.buffer_history, notes) == nil)
}

// --- Change feed ------------------------------------------------------------

@(private)
Buffer_Feed_Probe :: struct {
	records:       int,
	buffer_records: int,
	version:       u64,
	relation:      Relation_ID,
	base_revision: u64,
	new_revision:  u64,
	epoch:         u64,
	hunks:         int,
	first:         buf.Replacement,
}

@(private)
buffer_feed_probe :: proc(user: rawptr, record: ^Change_Record) -> bool {
	probe := (^Buffer_Feed_Probe)(user)
	probe.records += 1
	if len(record.buffers) == 0 {
		return true
	}
	probe.buffer_records += 1
	probe.version = record.version
	change := record.buffers[0]
	probe.relation = change.relation
	probe.base_revision = change.base_revision
	probe.new_revision = change.new_revision
	probe.epoch = change.epoch
	probe.hunks = len(change.delta.replacements)
	if probe.hunks > 0 {
		probe.first = change.delta.replacements[0]
	}
	return true
}

// A committed buffer edit is published to the change feed with the same
// base-relative delta the log records, and a compaction publishes an empty delta
// with the new epoch. The assertions run inside the visit, while the feed's
// copies are still owned.
@(test)
test_kernel_change_feed_records_buffer_edits :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	kernel: Kernel
	kernel_init(&kernel)
	defer kernel_destroy(&kernel)

	notes := create_buffer_relation(t, &kernel, 1, "notes")
	seed := kernel_begin(&kernel)
	transaction_buffer_edit(&seed, notes, 0, 0, "hello")
	commit_buffer_tx(t, &seed)

	seed_probe: Buffer_Feed_Probe
	_, seed_ok := changes_visit(&kernel.changes, 0, &seed_probe, buffer_feed_probe)
	testing.expect(t, seed_ok)
	testing.expect_value(t, seed_probe.buffer_records, 1)
	testing.expect_value(t, seed_probe.version, u64(2))
	testing.expect_value(t, seed_probe.relation, notes)
	testing.expect_value(t, seed_probe.base_revision, u64(0))
	testing.expect_value(t, seed_probe.new_revision, u64(1))
	testing.expect_value(t, seed_probe.hunks, 1)
	testing.expect_value(
		t,
		seed_probe.first,
		buf.Replacement{start = 0, end = 0, text = "hello"},
	)

	edit := kernel_begin(&kernel)
	transaction_buffer_edit(&edit, notes, 5, 0, " world")
	commit_buffer_tx(t, &edit)

	edit_probe: Buffer_Feed_Probe
	_, edit_ok := changes_visit(&kernel.changes, 2, &edit_probe, buffer_feed_probe)
	testing.expect(t, edit_ok)
	testing.expect_value(t, edit_probe.buffer_records, 1)
	testing.expect_value(t, edit_probe.version, u64(3))
	testing.expect_value(t, edit_probe.base_revision, u64(1))
	testing.expect_value(t, edit_probe.new_revision, u64(2))
	testing.expect_value(t, edit_probe.hunks, 1)
	testing.expect_value(
		t,
		edit_probe.first,
		buf.Replacement{start = 5, end = 5, text = " world"},
	)

	compact := kernel_begin(&kernel)
	transaction_buffer_compact(&compact, notes)
	commit_buffer_tx(t, &compact)

	// A compaction is observable even though it changes no content: the epoch
	// moved, and the delta is empty.
	compact_probe: Buffer_Feed_Probe
	_, compact_ok := changes_visit(&kernel.changes, 3, &compact_probe, buffer_feed_probe)
	testing.expect(t, compact_ok)
	testing.expect_value(t, compact_probe.version, u64(4))
	testing.expect_value(t, compact_probe.base_revision, u64(2))
	testing.expect_value(t, compact_probe.new_revision, u64(2))
	testing.expect_value(t, compact_probe.epoch, u64(1))
	testing.expect_value(t, compact_probe.hunks, 0)
}

// --- View sealing -----------------------------------------------------------

// Compaction describes committed content, so it cannot share a transaction with
// a content change. Applying it to a moved view would either discard the staged
// change or publish it under the revision compaction preserves, which would then
// not advance for a real content change.
@(test)
test_kernel_compaction_refuses_a_moved_view :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	kernel: Kernel
	kernel_init(&kernel)
	defer kernel_destroy(&kernel)

	notes := create_buffer_relation(t, &kernel, 1, "notes")
	seed := kernel_begin(&kernel)
	transaction_buffer_edit(&seed, notes, 0, 0, "abc")
	commit_buffer_tx(t, &seed)
	testing.expect_value(t, kernel_buffer_revision(&kernel, notes), u64(1))

	// Edited first, then compacted.
	edited := kernel_begin(&kernel)
	transaction_buffer_edit(&edited, notes, 3, 0, "d")
	testing.expect_value(
		t,
		transaction_buffer_compact(&edited, notes),
		Kernel_Error.Already_Applied,
	)
	commit_buffer_tx(t, &edited)
	// The edit is a real content change, so it advances the revision and leaves
	// the epoch alone.
	testing.expect_value(t, kernel_buffer_revision(&kernel, notes), u64(2))
	testing.expect_value(t, kernel_buffer_epoch(&kernel, notes), u64(0))
	testing.expect_value(t, kernel_buffer_text(&kernel, notes, context.temp_allocator), "abcd")

	// Compacted first: the view is sealed, so a later edit is refused rather
	// than published at the preserved revision.
	compacted := kernel_begin(&kernel)
	testing.expect_value(
		t,
		transaction_buffer_compact(&compacted, notes),
		Kernel_Error.None,
	)
	testing.expect_value(
		t,
		transaction_buffer_edit(&compacted, notes, 4, 0, "!"),
		Kernel_Error.Already_Applied,
	)
	// A second compaction is likewise refused.
	testing.expect_value(
		t,
		transaction_buffer_compact(&compacted, notes),
		Kernel_Error.Already_Applied,
	)
	commit_buffer_tx(t, &compacted)
	testing.expect_value(t, kernel_buffer_revision(&kernel, notes), u64(2))
	testing.expect_value(t, kernel_buffer_epoch(&kernel, notes), u64(1))
	testing.expect_value(t, kernel_buffer_text(&kernel, notes, context.temp_allocator), "abcd")
}

// A revision-checked apply must be the first mutation of the buffer: once a bare
// edit has moved the view, the client's offsets no longer address what it meant.
@(test)
test_kernel_apply_refuses_a_moved_view :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	kernel: Kernel
	kernel_init(&kernel)
	defer kernel_destroy(&kernel)

	notes := create_buffer_relation(t, &kernel, 1, "notes")
	seed := kernel_begin(&kernel)
	transaction_buffer_edit(&seed, notes, 0, 0, "abc")
	commit_buffer_tx(t, &seed)

	moved := kernel_begin(&kernel)
	transaction_buffer_edit(&moved, notes, 3, 0, "d")
	edits := []buf.Edit{{at = 0, remove = 0, text = "X"}}
	testing.expect_value(
		t,
		transaction_buffer_apply(&moved, notes, 1, edits),
		Apply_Status.Already_Applied,
	)
	testing.expect_value(t, transaction_buffer_text(&moved, notes, context.temp_allocator), "abcd")
	commit_buffer_tx(t, &moved)
	testing.expect_value(t, kernel_buffer_text(&kernel, notes, context.temp_allocator), "abcd")
	testing.expect_value(t, kernel_buffer_revision(&kernel, notes), u64(2))
}

// --- Admission --------------------------------------------------------------

// Admission sizes a transaction's durable payload before the candidate exists,
// so a buffer write is charged for the material it staged rather than for the
// whole document. Volatile buffers are scratch and are charged nothing.
@(test)
test_kernel_persist_bytes_counts_buffer_writes :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	kernel: Kernel
	kernel_init(&kernel)
	defer kernel_destroy(&kernel)

	notes := create_buffer_relation(t, &kernel, 1, "notes")
	seed := kernel_begin(&kernel)
	transaction_buffer_edit(&seed, notes, 0, 0, "base")
	commit_buffer_tx(t, &seed)

	// An edit is charged for its inserted text plus record framing.
	insert := kernel_begin(&kernel)
	transaction_buffer_edit(&insert, notes, 4, 0, " appended")
	bytes := kernel_persist_bytes(&insert)
	testing.expectf(
		t,
		bytes >= i64(len(" appended")) + BUFFER_RECORD_OVERHEAD,
		"edit payload not admitted: %d",
		bytes,
	)
	transaction_destroy(&insert)

	// A pure deletion inserts nothing, but it still produces a record, so its
	// framing is still admitted.
	deletion := kernel_begin(&kernel)
	transaction_buffer_edit(&deletion, notes, 0, 4, "")
	bytes = kernel_persist_bytes(&deletion)
	testing.expect_value(t, bytes, i64(BUFFER_RECORD_OVERHEAD))
	transaction_destroy(&deletion)

	// A batch apply is charged for every edit it staged.
	apply := kernel_begin(&kernel)
	edits := []buf.Edit {
		{at = 4, remove = 0, text = " one"},
		{at = 8, remove = 0, text = " two"},
	}
	testing.expect_value(t, transaction_buffer_apply(&apply, notes, 1, edits), Apply_Status.Applied)
	bytes = kernel_persist_bytes(&apply)
	testing.expectf(
		t,
		bytes >= i64(len(" one") + len(" two")) + BUFFER_RECORD_OVERHEAD,
		"apply payload not admitted: %d",
		bytes,
	)
	transaction_destroy(&apply)

	// A buffer staged by this transaction is not in the base snapshot, but its
	// content is durable work all the same.
	staged := kernel_begin(&kernel)
	metadata := relation_metadata(Relation_ID(2), buffer_test_sym("drafted"), 0)
	metadata.storage = .Buffer
	metadata.conflict = Conflict_Policy{kind = .Reject}
	drafted, create_error := transaction_create_relation(&staged, metadata)
	testing.expect_value(t, create_error, Kernel_Error.None)
	transaction_buffer_edit(&staged, drafted, 0, 0, "draft content")
	bytes = kernel_persist_bytes(&staged)
	testing.expectf(
		t,
		bytes >= i64(len("draft content")) + BUFFER_RECORD_OVERHEAD,
		"staged content not admitted: %d",
		bytes,
	)
	transaction_destroy(&staged)

	// A volatile buffer never consumes durable budget.
	volatile := kernel_begin(&kernel)
	metadata_v := relation_metadata(Relation_ID(3), buffer_test_sym("scratch"), 0)
	metadata_v.storage = .Buffer
	metadata_v.conflict = Conflict_Policy{kind = .Reject}
	metadata_v.durability = .Volatile
	scratch, create_error_v := transaction_create_relation(&volatile, metadata_v)
	testing.expect_value(t, create_error_v, Kernel_Error.None)
	transaction_buffer_edit(&volatile, scratch, 0, 0, "scratch text")
	testing.expect_value(t, kernel_persist_bytes(&volatile), i64(0))
	transaction_destroy(&volatile)
}
