// Semantics tests for the reference document model: view-relative coordinates,
// provenance normalization, ambiguity regressions, and reversion.
package buffer

import "core:strings"
import "core:testing"

// A deterministic linear congruential generator, so failures reproduce.
@(private)
next_random :: proc(state: ^u64) -> u64 {
	state^ = state^ * 6364136223846793005 + 1442695040888963407
	return state^ >> 33
}

@(private)
runes_to_text :: proc(runes: []rune, allocator := context.allocator) -> string {
	builder: strings.Builder
	strings.builder_init(&builder, allocator)
	for scalar in runes {
		strings.write_rune(&builder, scalar)
	}
	return strings.to_string(builder)
}

// An independent mirror of the edit semantics over a plain rune list. It shares
// no code with the tagged model, so disagreement means a real defect.
@(private)
mirror_apply :: proc(
	mirror: [dynamic]rune,
	edit: Edit,
	allocator := context.allocator,
) -> (
	[dynamic]rune,
	Edit_Error,
) {
	if edit.at < 0 || edit.remove < 0 || edit.at + edit.remove > len(mirror) {
		return mirror, .Out_Of_Range
	}
	next: [dynamic]rune
	next = make([dynamic]rune, allocator)
	append(&next, ..mirror[:edit.at])
	for scalar in edit.text {
		append(&next, scalar)
	}
	append(&next, ..mirror[edit.at + edit.remove:])
	return next, .None
}

// Applies a script of view-relative edits in order.
@(private)
apply_script :: proc(
	base: Document,
	script: []Edit,
	runs: ^Run_Allocator,
	allocator := context.allocator,
) -> (
	Document,
	Edit_Error,
) {
	doc := base
	for edit in script {
		next, err := edit_apply(doc, edit, runs, allocator)
		if err != .None {
			return doc, err
		}
		doc = next
	}
	return doc, .None
}

@(test)
test_base_document_round_trips :: proc(t: ^testing.T) {
	alloc, arena := test_allocator(t)
	defer test_allocator_destroy(arena)

	base := base_document("hello", alloc)
	testing.expect_value(t, len(base.cells), 5)
	testing.expect_value(t, document_text(base, alloc), "hello")
	testing.expect_value(t, base.cells[0].run, u64(0))
	testing.expect_value(t, base.cells[4].base, 4)
}

@(test)
test_edit_apply_is_view_relative :: proc(t: ^testing.T) {
	alloc, arena := test_allocator(t)
	defer test_allocator_destroy(arena)

	base := base_document("abc", alloc)
	runs := run_allocator_init(len(base.cells))

	// Insert at the front, then delete a scalar that the first edit created.
	doc, err := apply_script(base, []Edit{insert(0, "XY"), remove(1, 1)}, &runs, alloc)
	testing.expect_value(t, err, Edit_Error.None)
	testing.expect_value(t, document_text(doc, alloc), "Xabc")
}

@(test)
test_edit_apply_rejects_out_of_range :: proc(t: ^testing.T) {
	alloc, arena := test_allocator(t)
	defer test_allocator_destroy(arena)

	base := base_document("abc", alloc)
	runs := run_allocator_init(len(base.cells))
	_, err := edit_apply(base, remove(2, 5), &runs, alloc)
	testing.expect_value(t, err, Edit_Error.Out_Of_Range)
}

@(test)
test_delta_identity_is_empty :: proc(t: ^testing.T) {
	alloc, arena := test_allocator(t)
	defer test_allocator_destroy(arena)

	base := base_document("hello", alloc)
	delta, err := delta_derive(base, len(base.cells), alloc)
	testing.expect_value(t, err, Delta_Error.None)
	testing.expect_value(t, len(delta.replacements), 0)
}

@(test)
test_delta_pure_insert_positions :: proc(t: ^testing.T) {
	alloc, arena := test_allocator(t)
	defer test_allocator_destroy(arena)

	Case :: struct {
		at:   int,
		want: Replacement,
	}
	cases := []Case {
		{at = 0, want = Replacement{start = 0, end = 0, text = "Z"}},
		{at = 2, want = Replacement{start = 2, end = 2, text = "Z"}},
		{at = 3, want = Replacement{start = 3, end = 3, text = "Z"}},
	}
	for entry in cases {
		base := base_document("abc", alloc)
		runs := run_allocator_init(len(base.cells))
		doc, edit_err := edit_apply(base, insert(entry.at, "Z"), &runs, alloc)
		testing.expect_value(t, edit_err, Edit_Error.None)

		delta, err := delta_derive(doc, len(base.cells), alloc)
		testing.expect_value(t, err, Delta_Error.None)
		testing.expect_value(t, len(delta.replacements), 1)
		testing.expect_value(t, delta.replacements[0], entry.want)
	}
}

@(test)
test_delta_pure_delete_positions :: proc(t: ^testing.T) {
	alloc, arena := test_allocator(t)
	defer test_allocator_destroy(arena)

	Case :: struct {
		at:    int,
		count: int,
		want:  Replacement,
	}
	cases := []Case {
		{at = 0, count = 1, want = Replacement{start = 0, end = 1, text = ""}},
		{at = 1, count = 1, want = Replacement{start = 1, end = 2, text = ""}},
		{at = 1, count = 2, want = Replacement{start = 1, end = 3, text = ""}},
		{at = 0, count = 3, want = Replacement{start = 0, end = 3, text = ""}},
	}
	for entry in cases {
		base := base_document("abc", alloc)
		runs := run_allocator_init(len(base.cells))
		doc, edit_err := edit_apply(base, remove(entry.at, entry.count), &runs, alloc)
		testing.expect_value(t, edit_err, Edit_Error.None)

		delta, err := delta_derive(doc, len(base.cells), alloc)
		testing.expect_value(t, err, Delta_Error.None)
		testing.expect_value(t, len(delta.replacements), 1)
		testing.expect_value(t, delta.replacements[0], entry.want)
	}
}

@(test)
test_delta_adjacent_delete_and_insert_normalize_to_one_replacement :: proc(t: ^testing.T) {
	alloc, arena := test_allocator(t)
	defer test_allocator_destroy(arena)

	// Replacing base [0,1) with "A" must normalize to a single replacement, not
	// a delete at 0 plus an insert at 1: those would compose to the wrong text.
	base := base_document("abc", alloc)
	runs := run_allocator_init(len(base.cells))
	doc, edit_err := edit_apply(base, replace(0, 1, "A"), &runs, alloc)
	testing.expect_value(t, edit_err, Edit_Error.None)

	delta, err := delta_derive(doc, len(base.cells), alloc)
	testing.expect_value(t, err, Delta_Error.None)
	testing.expect_value(t, len(delta.replacements), 1)
	testing.expect_value(t, delta.replacements[0], Replacement{start = 0, end = 1, text = "A"})
}

// Worked history 1 from the design: an edit to text inserted earlier in the
// same transaction must collapse to its net effect.
@(test)
test_worked_history_1_edit_to_newly_inserted_text :: proc(t: ^testing.T) {
	alloc, arena := test_allocator(t)
	defer test_allocator_destroy(arena)

	base := base_document("abc", alloc)
	runs := run_allocator_init(len(base.cells))
	doc, edit_err := apply_script(base, []Edit{insert(0, "XY"), remove(1, 1)}, &runs, alloc)
	testing.expect_value(t, edit_err, Edit_Error.None)
	testing.expect_value(t, document_text(doc, alloc), "Xabc")

	delta, err := delta_derive(doc, len(base.cells), alloc)
	testing.expect_value(t, err, Delta_Error.None)
	testing.expect_value(t, len(delta.replacements), 1)
	testing.expect_value(t, delta.replacements[0], Replacement{start = 0, end = 0, text = "X"})
}

// Worked history 2: an append plus a base replacement normalize to two
// disjoint replacements.
@(test)
test_worked_history_2_append_plus_replacement :: proc(t: ^testing.T) {
	alloc, arena := test_allocator(t)
	defer test_allocator_destroy(arena)

	base := base_document("abc", alloc)
	runs := run_allocator_init(len(base.cells))
	doc, edit_err := apply_script(base, []Edit{insert(3, "Z"), replace(0, 1, "A")}, &runs, alloc)
	testing.expect_value(t, edit_err, Edit_Error.None)
	testing.expect_value(t, document_text(doc, alloc), "AbcZ")

	delta, err := delta_derive(doc, len(base.cells), alloc)
	testing.expect_value(t, err, Delta_Error.None)
	testing.expect_value(t, len(delta.replacements), 2)
	testing.expect_value(t, delta.replacements[0], Replacement{start = 0, end = 1, text = "A"})
	testing.expect_value(t, delta.replacements[1], Replacement{start = 3, end = 3, text = "Z"})
}

// The ambiguity regression: a content diff cannot tell which "a" was deleted,
// and the two answers must produce different deltas.
@(test)
test_ambiguity_repeated_scalars :: proc(t: ^testing.T) {
	alloc, arena := test_allocator(t)
	defer test_allocator_destroy(arena)

	base := base_document("aaa", alloc)
	base_len := len(base.cells)

	first_runs := run_allocator_init(base_len)
	first, first_err := edit_apply(base, remove(0, 1), &first_runs, alloc)
	testing.expect_value(t, first_err, Edit_Error.None)
	first_delta, first_derr := delta_derive(first, base_len, alloc)
	testing.expect_value(t, first_derr, Delta_Error.None)

	last_runs := run_allocator_init(base_len)
	last, last_err := edit_apply(base, remove(2, 1), &last_runs, alloc)
	testing.expect_value(t, last_err, Edit_Error.None)
	last_delta, last_derr := delta_derive(last, base_len, alloc)
	testing.expect_value(t, last_derr, Delta_Error.None)

	// Same resulting text...
	testing.expect_value(t, document_text(first, alloc), "aa")
	testing.expect_value(t, document_text(last, alloc), "aa")
	// ...but different provenance, and therefore different deltas.
	testing.expect_value(t, first_delta.replacements[0], Replacement{start = 0, end = 1, text = ""})
	testing.expect_value(t, last_delta.replacements[0], Replacement{start = 2, end = 3, text = ""})
}

@(test)
test_delta_derive_rejects_foreign_base_provenance :: proc(t: ^testing.T) {
	alloc, arena := test_allocator(t)
	defer test_allocator_destroy(arena)

	// Out of order: base index 3 then base index 1.
	out_of_order := make([]Cell, 2, alloc)
	out_of_order[0] = Cell {
		run    = 0,
		base   = 3,
		scalar = 'd',
	}
	out_of_order[1] = Cell {
		run    = 0,
		base   = 1,
		scalar = 'b',
	}
	_, err := delta_derive(Document{cells = out_of_order}, 4, alloc)
	testing.expect_value(t, err, Delta_Error.Foreign_Base_Cell)

	// Out of range: a base index the base cannot account for.
	out_of_range := make([]Cell, 1, alloc)
	out_of_range[0] = Cell {
		run    = 0,
		base   = 7,
		scalar = 'h',
	}
	_, err2 := delta_derive(Document{cells = out_of_range}, 4, alloc)
	testing.expect_value(t, err2, Delta_Error.Foreign_Base_Cell)
}

@(test)
test_delta_apply_round_trips :: proc(t: ^testing.T) {
	alloc, arena := test_allocator(t)
	defer test_allocator_destroy(arena)

	base := base_document("hello world", alloc)
	base_len := len(base.cells)
	script := []Edit {
		insert(0, ">> "),
		replace(6, 5, "there"),
		remove(3, 2),
		insert(4, "!"),
	}

	runs := run_allocator_init(base_len)
	doc, edit_err := apply_script(base, script, &runs, alloc)
	testing.expect_value(t, edit_err, Edit_Error.None)
	want := document_text(doc, alloc)

	delta, err := delta_derive(doc, base_len, alloc)
	testing.expect_value(t, err, Delta_Error.None)

	replayed, apply_err := delta_apply(base, delta, &runs, alloc)
	testing.expect_value(t, apply_err, Edit_Error.None)
	testing.expect_value(t, document_text(replayed, alloc), want)
}

@(test)
test_revert_is_a_whole_buffer_splice_with_fresh_cells :: proc(t: ^testing.T) {
	alloc, arena := test_allocator(t)
	defer test_allocator_destroy(arena)

	base := base_document("abcd", alloc)
	base_len := len(base.cells)
	runs := run_allocator_init(base_len)

	reverted, delta, err := revert_as_splice(base, "xy", &runs, alloc)
	testing.expect_value(t, err, Edit_Error.None)
	testing.expect_value(t, document_text(reverted, alloc), "xy")
	testing.expect_value(t, len(delta.replacements), 1)
	testing.expect_value(t, delta.replacements[0], Replacement{start = 0, end = base_len, text = "xy"})

	// No base cell survives, so no interval absent from the base is resurrected.
	for cell in reverted.cells {
		testing.expect(t, cell.run != 0)
		testing.expect_value(t, cell.base, -1)
	}

	// Normalizing the reverted document recovers the same single replacement.
	derived, derr := delta_derive(reverted, base_len, alloc)
	testing.expect_value(t, derr, Delta_Error.None)
	testing.expect_value(t, len(derived.replacements), 1)
	testing.expect_value(t, derived.replacements[0], Replacement{start = 0, end = base_len, text = "xy"})

	// And applying it to the base produces exactly the old text.
	applied, apply_err := delta_apply(base, derived, &runs, alloc)
	testing.expect_value(t, apply_err, Edit_Error.None)
	testing.expect_value(t, document_text(applied, alloc), "xy")
}

// Randomized property test: generated view-relative scripts must agree with an
// independent rune-list mirror, and the derived provenance delta must rebuild
// the same text when replayed against the base.
@(test)
test_random_scripts_round_trip :: proc(t: ^testing.T) {
	alloc, arena := test_allocator(t)
	defer test_allocator_destroy(arena)

	base_text := "the quick brown fox"
	insertions := []string{"x", "YZ", "!", "qq", " "}
	steps := 240

	for seed in ([]u64{1, 7, 12345, 999_983}) {
		state := seed
		base := base_document(base_text, alloc)
		base_len := len(base.cells)
		runs := run_allocator_init(base_len)

		mirror: [dynamic]rune
		mirror = make([dynamic]rune, alloc)
		for scalar in base_text {
			append(&mirror, scalar)
		}

		doc := base
		for _ in 0 ..< steps {
			// Choose an edit whose coordinates are valid in the current view.
			span := len(mirror) + 1
			at := int(next_random(&state) % u64(span))
			kind := next_random(&state) % 3
			remaining := len(mirror) - at

			edit: Edit
			switch kind {
			case 0:
				text := insertions[int(next_random(&state) % u64(len(insertions)))]
				edit = insert(at, text)
			case 1:
				if remaining == 0 {
					continue
				}
				count := 1 + int(next_random(&state) % u64(min(remaining, 3)))
				edit = remove(at, count)
			case:
				if remaining == 0 {
					edit = insert(at, "Z")
				} else {
					count := 1 + int(next_random(&state) % u64(min(remaining, 3)))
					text := insertions[int(next_random(&state) % u64(len(insertions)))]
					edit = replace(at, count, text)
				}
			}

			next_doc, doc_err := edit_apply(doc, edit, &runs, alloc)
			testing.expectf(t, doc_err == .None, "seed %d: edit error %v", seed, doc_err)
			doc = next_doc

			next_mirror, mirror_err := mirror_apply(mirror, edit, alloc)
			testing.expectf(
				t,
				mirror_err == .None,
				"seed %d: mirror error %v",
				seed,
				mirror_err,
			)
			mirror = next_mirror

			testing.expectf(
				t,
				document_text(doc, alloc) == runes_to_text(mirror[:], alloc),
				"seed %d: tagged model diverged from mirror",
				seed,
			)
		}

		// Normalize, then replay the delta against the base: provenance must
		// reconstruct exactly the text the edits produced.
		delta, delta_err := delta_derive(doc, base_len, alloc)
		testing.expectf(t, delta_err == .None, "seed %d: derive error %v", seed, delta_err)

		replayed, apply_err := delta_apply(base, delta, &runs, alloc)
		testing.expectf(t, apply_err == .None, "seed %d: apply error %v", seed, apply_err)
		testing.expectf(
			t,
			document_text(replayed, alloc) == document_text(doc, alloc),
			"seed %d: replayed delta produced different text",
			seed,
		)
	}
}
