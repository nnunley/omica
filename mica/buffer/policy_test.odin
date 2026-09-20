// Tests for the conflict matrix, epoch decisions, and budget classes.
package buffer

import "core:testing"

@(test)
test_conflict_matrix :: proc(t: ^testing.T) {
	Case :: struct {
		name:     string,
		a:        Replacement,
		b:        Replacement,
		conflict: bool,
	}
	cases := []Case {
		{
			name = "insert/insert same point conflicts",
			a = {5, 5, "x"},
			b = {5, 5, "y"},
			conflict = true,
		},
		{
			name = "insert/insert different points merge",
			a = {3, 3, "x"},
			b = {5, 5, "y"},
			conflict = false,
		},
		{
			name = "insert strictly inside a removed range conflicts",
			a = {5, 5, "x"},
			b = {4, 7, ""},
			conflict = true,
		},
		{
			name = "insert at the start boundary stays before",
			a = {4, 4, "x"},
			b = {4, 7, ""},
			conflict = false,
		},
		{
			name = "insert at the end boundary stays after",
			a = {7, 7, "x"},
			b = {4, 7, ""},
			conflict = false,
		},
		{
			name = "insert strictly inside a replacement conflicts",
			a = {3, 3, "x"},
			b = {2, 5, "y"},
			conflict = true,
		},
		{
			name = "delete/delete overlap conflicts",
			a = {2, 5, ""},
			b = {4, 8, ""},
			conflict = true,
		},
		{
			name = "adjacent deletes merge",
			a = {1, 3, ""},
			b = {3, 5, ""},
			conflict = false,
		},
		{
			name = "identical replacements conflict",
			a = {2, 5, "x"},
			b = {2, 5, "y"},
			conflict = true,
		},
		{
			name = "disjoint replacements merge",
			a = {0, 2, "x"},
			b = {3, 5, "y"},
			conflict = false,
		},
	}

	for entry in cases {
		forward := replacements_conflict(entry.a, entry.b)
		backward := replacements_conflict(entry.b, entry.a)
		testing.expectf(
			t,
			forward == entry.conflict,
			"%s: expected %v, got %v",
			entry.name,
			entry.conflict,
			forward,
		)
		testing.expectf(
			t,
			backward == entry.conflict,
			"%s: not symmetric (expected %v, got %v)",
			entry.name,
			entry.conflict,
			backward,
		)
	}
}

@(test)
test_deltas_conflict_over_multiple_replacements :: proc(t: ^testing.T) {
	left := Delta {
		replacements = []Replacement{{start = 0, end = 1, text = "A"}, {start = 3, end = 3, text = "Z"}},
	}
	// Disjoint from both.
	disjoint := Delta {
		replacements = []Replacement{{start = 8, end = 9, text = "Q"}},
	}
	testing.expect(t, !deltas_conflict(left, disjoint))

	// Overlaps only the second replacement.
	touching := Delta {
		replacements = []Replacement{{start = 3, end = 3, text = "W"}},
	}
	testing.expect(t, deltas_conflict(left, touching))
}

@(test)
test_rebase_action_covers_all_four_cases :: proc(t: ^testing.T) {
	testing.expect_value(t, rebase_action(7, 1, 7, 1), Rebase_Action.Publish_As_Built)
	testing.expect_value(t, rebase_action(7, 1, 8, 1), Rebase_Action.Merge)
	// Compaction only: content identical, lineage moved. The candidate must be
	// re-applied to the current root rather than published as built.
	testing.expect_value(t, rebase_action(7, 1, 7, 2), Rebase_Action.Reapply_Delta)
	testing.expect_value(t, rebase_action(7, 1, 8, 2), Rebase_Action.Conflict)
}

@(test)
test_only_rebase_failures_are_resyncable :: proc(t: ^testing.T) {
	testing.expect(t, failure_is_resyncable(.Rebase_Budget_Exceeded))
	// An oversized ordinary edit fails identically on the same snapshot, so
	// resynchronizing cannot help.
	testing.expect(t, !failure_is_resyncable(.Buffer_Edit_Too_Large))
	testing.expect(t, !failure_is_resyncable(.Overloaded))
	testing.expect(t, !failure_is_resyncable(.None))
}

@(test)
test_budget_exceeded_per_dimension :: proc(t: ^testing.T) {
	budget := DEFAULT_REBASE_BUDGET

	testing.expect(t, !budget_exceeded(budget, Budget_Usage{}))
	testing.expect(
		t,
		!budget_exceeded(
			budget,
			Budget_Usage {
				comparison_steps = budget.comparison_steps,
				text_bytes = budget.text_bytes,
				hunks = budget.hunks,
				alloc_bytes = budget.alloc_bytes,
			},
		),
	)
	testing.expect(
		t,
		budget_exceeded(budget, Budget_Usage{comparison_steps = budget.comparison_steps + 1}),
	)
	testing.expect(t, budget_exceeded(budget, Budget_Usage{text_bytes = budget.text_bytes + 1}))
	testing.expect(t, budget_exceeded(budget, Budget_Usage{hunks = budget.hunks + 1}))
	testing.expect(t, budget_exceeded(budget, Budget_Usage{alloc_bytes = budget.alloc_bytes + 1}))

	// Work performed is bounded independently of the result size: an expensive
	// comparison that yields no hunks still trips the work budget.
	testing.expect(
		t,
		budget_exceeded(budget, Budget_Usage{comparison_steps = 100_000, hunks = 0}),
	)
}

// A non-conflicting pair of deltas must commute: applying either first and
// transforming the other through it yields the same text. This is the property
// that makes the merge meaningful.
@(test)
test_delta_transform_commutes_for_disjoint_edits :: proc(t: ^testing.T) {
	alloc, arena := test_allocator(t)
	defer test_allocator_destroy(arena)

	base_text := "the quick brown fox jumps"
	sources := []string{"X", "YY", "", "zzz", " "}

	state := u64(20240920)
	for _ in 0 ..< 300 {
		base := base_document(base_text, alloc)
		base_len := len(base.cells)

		first := base_relative_edit(&state, base_len, sources)
		second := base_relative_edit(&state, base_len, sources)
		if deltas_conflict(first, second) {
			continue
		}

		// Apply left then right.
		left_applied, left_error := delta_apply(base, first, &Run_Allocator{next = u64(base_len) + 1}, alloc)
		testing.expect_value(t, left_error, Edit_Error.None)
		right_transformed := delta_transform(first, second, alloc)
		left_then_right, ltr_error := delta_apply(
			left_applied,
			right_transformed,
			&Run_Allocator{next = u64(base_len) + 1},
			alloc,
		)
		testing.expect_value(t, ltr_error, Edit_Error.None)

		// Apply right then left.
		right_applied, right_error := delta_apply(base, second, &Run_Allocator{next = u64(base_len) + 1}, alloc)
		testing.expect_value(t, right_error, Edit_Error.None)
		left_transformed := delta_transform(second, first, alloc)
		right_then_left, rtl_error := delta_apply(
			right_applied,
			left_transformed,
			&Run_Allocator{next = u64(base_len) + 1},
			alloc,
		)
		testing.expect_value(t, rtl_error, Edit_Error.None)

		testing.expectf(
			t,
			document_text(left_then_right, alloc) == document_text(right_then_left, alloc),
			"disjoint deltas did not commute: %v then %v",
			first.replacements,
			second.replacements,
		)
	}
}

// A base-relative edit over a document of `base_len` scalars.
@(private)
base_relative_edit :: proc(state: ^u64, base_len: int, sources: []string) -> Delta {
	start := int(next_random(state) % u64(base_len + 1))
	remaining := base_len - start
	count := 0
	if remaining > 0 {
		limit := remaining < 4 ? remaining : 4
		count = int(next_random(state) % u64(limit + 1))
	}
	text := sources[int(next_random(state) % u64(len(sources)))]
	replacements := make([]Replacement, 1, context.temp_allocator)
	replacements[0] = Replacement{start = start, end = start + count, text = text}
	return Delta{replacements = replacements}
}

// A marker moves with an edit: insertions and deletions before it shift it,
// deletions covering it collapse it to the deletion point, and the insertion
// type decides only the tie at its own position.
@(test)
test_marker_rebase :: proc(t: ^testing.T) {
	Case :: struct {
		name:      string,
		delta:     Delta,
		position:  int,
		kind:      Marker_Insertion_Type,
		expected:  int,
	}
	// Base text for the cases below: "abcdef" (six scalars).
	insert_at_one := Delta {
		replacements = []Replacement{{1, 1, "XY"}},
	}
	delete_prefix := Delta {
		replacements = []Replacement{{0, 2, ""}},
	}
	replace_middle := Delta {
		replacements = []Replacement{{1, 2, "XYZ"}},
	}
	delete_covering := Delta {
		replacements = []Replacement{{2, 5, ""}},
	}
	replace_covering := Delta {
		replacements = []Replacement{{2, 5, "Q"}},
	}
	insert_at_marker := Delta {
		replacements = []Replacement{{3, 3, "!!"}},
	}
	multi := Delta {
		replacements = []Replacement{{1, 1, "X"}, {4, 5, ""}},
	}

	cases := []Case {
		{"insertion before the marker shifts it", insert_at_one, 5, .Before, 7},
		{"insertion before the marker shifts it after too", insert_at_one, 5, .After, 7},
		{"deletion before the marker shifts it left", delete_prefix, 4, .Before, 2},
		{"replacement before the marker shifts by the difference", replace_middle, 5, .Before, 7},
		{"marker inside a deleted range collapses to the deletion point", delete_covering, 3, .Before, 2},
		{"marker inside a replaced range collapses to the replacement start", replace_covering, 4, .After, 2},
		{"marker at the end of a deleted range", delete_covering, 5, .Before, 2},
		{"marker before a deleted range is unmoved", delete_covering, 1, .Before, 1},
		{"insertion at the marker with :after moves past it", insert_at_marker, 3, .After, 5},
		{"insertion at the marker with :before stays put", insert_at_marker, 3, .Before, 3},
		{"several changes compose, collapsing inside the deletion", multi, 4, .Before, 5},
		{"several changes compose for a later marker", multi, 6, .Before, 6},
		{"an empty delta leaves the marker alone", Delta{}, 4, .After, 4},
	}

	for entry in cases {
		actual := marker_rebase(entry.delta, entry.position, entry.kind)
		testing.expectf(
			t,
			actual == entry.expected,
			"%s: got %d, expected %d",
			entry.name,
			actual,
			entry.expected,
		)
	}
}
