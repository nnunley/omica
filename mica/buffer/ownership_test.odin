// Tests for the reference ownership model: insertion runs are retained by the
// documents that reference them, and abandoning a candidate releases exactly
// its own runs.
package buffer

import "core:testing"

@(test)
test_origin_retain_and_release :: proc(t: ^testing.T) {
	alloc, arena := test_allocator(t)
	defer test_allocator_destroy(arena)

	table: Origin_Table
	origin_table_init(&table, alloc)
	defer origin_table_destroy(&table)

	// Base material carries no run and is never freed.
	testing.expect(t, !origin_release(&table, 0))
	testing.expect_value(t, origin_refs(&table, 0), 0)

	origin_retain(&table, 3)
	origin_retain(&table, 3)
	testing.expect_value(t, origin_refs(&table, 3), 2)
	testing.expect(t, !origin_release(&table, 3))
	testing.expect_value(t, origin_refs(&table, 3), 1)
	testing.expect(t, origin_release(&table, 3))
	testing.expect_value(t, origin_refs(&table, 3), 0)

	// Releasing an unreferenced run is not a free.
	testing.expect(t, !origin_release(&table, 3))
}

@(test)
test_shared_run_survives_one_document_release :: proc(t: ^testing.T) {
	alloc, arena := test_allocator(t)
	defer test_allocator_destroy(arena)

	table: Origin_Table
	origin_table_init(&table, alloc)
	defer origin_table_destroy(&table)

	base := base_document("abc", alloc)
	runs := run_allocator_init(len(base.cells))
	doc, err := edit_apply(base, insert(3, "Z"), &runs, alloc)
	testing.expect_value(t, err, Edit_Error.None)
	run := doc.cells[3].run
	testing.expect(t, run != 0)

	// Two holders of the same run, for example a snapshot and a live reader.
	document_retain(&table, doc)
	document_retain(&table, doc)
	testing.expect_value(t, origin_refs(&table, run), 2)

	freed: [dynamic]u64
	freed = make([dynamic]u64, alloc)

	document_release(&table, doc, &freed)
	testing.expect_value(t, origin_refs(&table, run), 1)
	testing.expect_value(t, len(freed), 0)

	document_release(&table, doc, &freed)
	testing.expect_value(t, origin_refs(&table, run), 0)
	testing.expect_value(t, len(freed), 1)
	testing.expect_value(t, freed[0], run)
}

@(test)
test_abandoned_candidate_releases_only_its_own_runs :: proc(t: ^testing.T) {
	alloc, arena := test_allocator(t)
	defer test_allocator_destroy(arena)

	table: Origin_Table
	origin_table_init(&table, alloc)
	defer origin_table_destroy(&table)

	base := base_document("abc", alloc)
	runs := run_allocator_init(len(base.cells))

	// A committed version already holds one run.
	committed, committed_err := edit_apply(base, insert(0, "K"), &runs, alloc)
	testing.expect_value(t, committed_err, Edit_Error.None)
	document_retain(&table, committed)
	committed_run := committed.cells[0].run

	// A candidate stages another run on top.
	candidate, candidate_err := edit_apply(committed, insert(0, "W"), &runs, alloc)
	testing.expect_value(t, candidate_err, Edit_Error.None)
	document_retain(&table, candidate)
	candidate_run := candidate.cells[0].run
	testing.expect(t, candidate_run != committed_run)

	// Abandoning the candidate releases its run and leaves the committed run
	// untouched, including the one its chunks share with the base.
	document_release(&table, candidate, nil)
	testing.expect_value(t, origin_refs(&table, candidate_run), 0)
	testing.expect_value(t, origin_refs(&table, committed_run), 1)
}
