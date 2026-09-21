// Tests for the persistent piece-tree index: build, balancing, span visit,
// offset and line lookup, path-copy edit, iterative release, and — most
// importantly — that its provenance walk agrees with the frozen reference
// semantics in `document.odin`.
package buffer

import "core:mem"
import "core:testing"

// Verifies cached counts, height, occupancy, and the balance invariant.
@(private)
check_tree_invariants :: proc(t: ^testing.T, node: ^Piece_Node, label: string) {
	if node == nil {
		return
	}
	if node.leaf {
		testing.expectf(
			t,
			node.count >= 1 && int(node.count) <= NODE_FANOUT,
			"%s: leaf occupancy %d",
			label,
			node.count,
		)
		testing.expectf(t, node.height == 1, "%s: leaf height %d", label, node.height)
		scalars := u64(0)
		newlines := u64(0)
		for index in 0 ..< int(node.count) {
			testing.expectf(t, node.pieces[index].length > 0, "%s: empty piece", label)
			scalars += node.pieces[index].length
			newlines += piece_newlines(node.pieces[index])
		}
		testing.expectf(t, node.scalars == scalars, "%s: cached scalars", label)
		testing.expectf(t, node.newlines == newlines, "%s: cached newlines", label)
		return
	}

	testing.expectf(t, node.count == 2, "%s: internal child count %d", label, node.count)
	left := node.children[0]
	right := node.children[1]
	check_tree_invariants(t, left, label)
	check_tree_invariants(t, right, label)

	testing.expectf(t, node.scalars == left.scalars + right.scalars, "%s: internal scalars", label)
	testing.expectf(
		t,
		node.newlines == left.newlines + right.newlines,
		"%s: internal newlines",
		label,
	)

	expected_height := 1 + max(node_height(left), node_height(right))
	testing.expectf(
		t,
		int(node.height) == expected_height,
		"%s: internal height %d, expected %d",
		label,
		node.height,
		expected_height,
	)
	imbalance := node_height(left) - node_height(right)
	if imbalance < 0 {
		imbalance = -imbalance
	}
	testing.expectf(t, imbalance <= 1, "%s: imbalance %d", label, imbalance)
}

@(test)
test_tree_from_text_reads_back :: proc(t: ^testing.T) {
	alloc, arena := test_allocator(t)
	defer test_allocator_destroy(arena)

	store: Store
	store_init(&store, alloc)
	defer store_destroy(&store)

	root := tree_from_text(&store, "hello\nworld", .Original)
	defer tree_release(&store, root)

	testing.expect_value(t, tree_scalars(root), u64(11))
	testing.expect_value(t, tree_newlines(root), u64(1))
	testing.expect_value(t, tree_line_count(root), u64(2))
	testing.expect_value(t, tree_text(root, alloc), "hello\nworld")
	check_tree_invariants(t, root, "from_text")
}

@(test)
test_tree_empty_is_nil :: proc(t: ^testing.T) {
	alloc, arena := test_allocator(t)
	defer test_allocator_destroy(arena)

	store: Store
	store_init(&store, alloc)
	defer store_destroy(&store)

	root := tree_from_text(&store, "", .Original)
	testing.expect(t, root == nil)
	testing.expect_value(t, tree_scalars(root), u64(0))
	testing.expect_value(t, tree_line_count(root), u64(1))
}

@(test)
test_tree_offset_and_line_lookup :: proc(t: ^testing.T) {
	alloc, arena := test_allocator(t)
	defer test_allocator_destroy(arena)

	store: Store
	store_init(&store, alloc)
	defer store_destroy(&store)

	root := tree_from_text(&store, "ab\ncd\nef", .Original)
	defer tree_release(&store, root)

	testing.expect_value(t, tree_line_start(root, 0), u64(0))
	testing.expect_value(t, tree_line_start(root, 1), u64(3))
	testing.expect_value(t, tree_line_start(root, 2), u64(6))
	// Past the last line: the end of the text.
	testing.expect_value(t, tree_line_start(root, 3), u64(8))

	testing.expect_value(t, tree_line_of_scalar(root, 0), u64(0))
	testing.expect_value(t, tree_line_of_scalar(root, 2), u64(0))
	testing.expect_value(t, tree_line_of_scalar(root, 3), u64(1))
	testing.expect_value(t, tree_line_of_scalar(root, 7), u64(2))
}

@(test)
test_tree_line_lookup_across_joined_edits :: proc(t: ^testing.T) {
	alloc, arena := test_allocator(t)
	defer test_allocator_destroy(arena)

	store: Store
	store_init(&store, alloc)
	defer store_destroy(&store)

	root := tree_from_text(&store, "", .Original)
	next := tree_edit(&store, root, 0, 0, "a", .Added)
	tree_release(&store, root)
	root = next
	next = tree_edit(&store, root, 1, 0, "b", .Added)
	tree_release(&store, root)
	root = next
	next = tree_edit(&store, root, 2, 0, "\n", .Added)
	tree_release(&store, root)
	root = next
	defer tree_release(&store, root)

	// Each edit is a separate tree. The newline is in a right subtree, so its
	// scalar offset must include all text in the subtrees before it.
	testing.expect_value(t, tree_text(root, alloc), "ab\n")
	testing.expect_value(t, tree_line_start(root, 1), u64(3))
	testing.expect_value(t, tree_line_of_scalar(root, 3), u64(1))
}

@(private)
Span_Collector :: struct {
	pieces:  [dynamic]string,
	offsets: [dynamic]u64,
}

@(private)
collect_span :: proc(user: rawptr, text: string, offset: u64) -> bool {
	collector := cast(^Span_Collector)user
	append(&collector.pieces, text)
	append(&collector.offsets, offset)
	return true
}

@(test)
test_tree_span_visit_clips_to_range :: proc(t: ^testing.T) {
	alloc, arena := test_allocator(t)
	defer test_allocator_destroy(arena)

	store: Store
	store_init(&store, alloc)
	defer store_destroy(&store)

	root := tree_from_text(&store, "abcdef", .Original)
	defer tree_release(&store, root)

	collector: Span_Collector
	collector.pieces = make([dynamic]string, alloc)
	collector.offsets = make([dynamic]u64, alloc)

	tree_visit_spans(root, 2, 5, collect_span, &collector)
	testing.expect_value(t, len(collector.pieces), 1)
	testing.expect_value(t, collector.pieces[0], "cde")
	testing.expect_value(t, collector.offsets[0], u64(2))
}

@(test)
test_tree_split_and_join_round_trip :: proc(t: ^testing.T) {
	alloc, arena := test_allocator(t)
	defer test_allocator_destroy(arena)

	store: Store
	store_init(&store, alloc)
	defer store_destroy(&store)

	// Many pieces, so the tree has real depth rather than a single leaf.
	pieces: [dynamic]Piece
	pieces = make([dynamic]Piece, alloc)
	for index in 0 ..< 200 {
		text := index % 10 == 9 ? "X" : "a"
		chunk := chunk_create(&store.chunks, text, .Original, alloc)
		append(&pieces, Piece{chunk = chunk, start = 0, length = chunk.scalars})
		chunk_release(chunk)
	}
	root := tree_from_pieces(&store, pieces[:])
	defer tree_release(&store, root)
	check_tree_invariants(t, root, "bulk")

	want := tree_text(root, alloc)
	total := tree_scalars(root)

	for at in ([]u64{0, 1, 17, 55, 101, 199, total - 1, total}) {
		left, right := tree_split(&store, root, at)
		check_tree_invariants(t, left, "split_left")
		check_tree_invariants(t, right, "split_right")
		testing.expectf(
			t,
			tree_scalars(left) + tree_scalars(right) == total,
			"split at %d lost scalars",
			at,
		)
		joined := tree_join(&store, left, right)
		check_tree_invariants(t, joined, "rejoined")
		testing.expectf(t, tree_text(joined, alloc) == want, "split/join at %d changed text", at)
		node_release(&store.nodes, left)
		node_release(&store.nodes, right)
		tree_release(&store, joined)
	}
}

@(test)
test_tree_edit_path_copies_and_shares :: proc(t: ^testing.T) {
	alloc, arena := test_allocator(t)
	defer test_allocator_destroy(arena)

	store: Store
	store_init(&store, alloc)
	defer store_destroy(&store)

	base := tree_from_text(&store, "hello world", .Original)
	defer tree_release(&store, base)
	base_root := base

	edited := tree_edit(&store, base, 0, 0, ">> ", .Added)
	defer tree_release(&store, edited)

	testing.expect_value(t, tree_text(base, alloc), "hello world")
	testing.expect_value(t, tree_text(edited, alloc), ">> hello world")
	// The base is untouched and still shares its subtree with the edit.
	testing.expect(t, base == base_root)
	testing.expect_value(t, tree_scalars(base), u64(11))
	testing.expect_value(t, tree_scalars(edited), u64(14))
	check_tree_invariants(t, edited, "edited")
}

@(test)
test_tree_release_is_iterative_and_recycles :: proc(t: ^testing.T) {
	alloc, arena := test_allocator(t)
	defer test_allocator_destroy(arena)

	store: Store
	store_init(&store, alloc)
	defer store_destroy(&store)

	pieces: [dynamic]Piece
	pieces = make([dynamic]Piece, alloc)
	for index in 0 ..< 4000 {
		chunk := chunk_create(&store.chunks, "a", .Original, alloc)
		append(&pieces, Piece{chunk = chunk, start = 0, length = chunk.scalars})
		chunk_release(chunk)
	}
	root := tree_from_pieces(&store, pieces[:])
	check_tree_invariants(t, root, "deep")
	// Deep enough that a recursive release would be at risk.
	testing.expect(t, node_height(root) > 4)

	tree_release(&store, root)
	// Every node that reached zero is on the free list, and the chunks they
	// held have gone back to the chunk pool.
	testing.expect(t, len(store.nodes.free) > 100)
	testing.expect(t, store.nodes.reuses == 0)
}

// The load-bearing test: the storage index must derive exactly the same
// base-relative delta as the frozen reference semantics.
@(test)
test_tree_provenance_matches_reference_model :: proc(t: ^testing.T) {
	alloc, arena := test_allocator(t)
	defer test_allocator_destroy(arena)

	store: Store
	store_init(&store, alloc)
	defer store_destroy(&store)

	base_text := "the quick brown fox"
	base_tree := tree_from_text(&store, base_text, .Original)
	defer tree_release(&store, base_tree)
	base_doc := base_document(base_text, alloc)
	base_len := len(base_doc.cells)

	for seed in ([]u64{3, 11, 4242, 999_983}) {
		state := seed
		tree := tree_retain(base_tree)
		doc := base_doc
		runs := run_allocator_init(base_len)

		for _ in 0 ..< 120 {
			scalars := tree_scalars(tree)
			at := next_random(&state) % (scalars + 1)
			kind := next_random(&state) % 3
			remaining := scalars - at

			edit: Edit
			switch kind {
			case 0:
				text := insertion_sources[int(next_random(&state) % u64(len(insertion_sources)))]
				edit = insert(int(at), text)
			case 1:
				if remaining == 0 {
					continue
				}
				limit := remaining < 3 ? remaining : 3
				count := 1 + int(next_random(&state) % limit)
				edit = remove(int(at), count)
			case:
				if remaining == 0 {
					edit = insert(int(at), "Z")
				} else {
					limit := remaining < 3 ? remaining : 3
					count := 1 + int(next_random(&state) % limit)
					text :=
						insertion_sources[int(next_random(&state) % u64(len(insertion_sources)))]
					edit = replace(int(at), count, text)
				}
			}

			next_tree := tree_edit(&store, tree, u64(edit.at), u64(edit.remove), edit.text, .Added)
			tree_release(&store, tree)
			tree = next_tree

			next_doc, doc_err := edit_apply(doc, edit, &runs, alloc)
			testing.expectf(t, doc_err == .None, "seed %d: reference edit failed", seed)
			doc = next_doc

			testing.expectf(
				t,
				tree_text(tree, alloc) == document_text(doc, alloc),
				"seed %d: tree text diverged from reference",
				seed,
			)
			check_tree_invariants(t, tree, "random")
		}

		tree_delta, tree_err := tree_provenance(&store, base_tree, tree, alloc)
		testing.expectf(t, tree_err == .None, "seed %d: provenance error %v", seed, tree_err)
		ref_delta, ref_err := delta_derive(doc, base_len, alloc)
		testing.expectf(t, ref_err == .None, "seed %d: reference derive error %v", seed, ref_err)

		testing.expectf(
			t,
			len(tree_delta.replacements) == len(ref_delta.replacements),
			"seed %d: %d replacements, reference has %d",
			seed,
			len(tree_delta.replacements),
			len(ref_delta.replacements),
		)
		for index in 0 ..< min(len(tree_delta.replacements), len(ref_delta.replacements)) {
			testing.expectf(
				t,
				tree_delta.replacements[index] == ref_delta.replacements[index],
				"seed %d: replacement %d differs: tree %v, reference %v",
				seed,
				index,
				tree_delta.replacements[index],
				ref_delta.replacements[index],
			)
		}

		tree_release(&store, tree)
	}
}

@(test)
test_tree_provenance_reports_deletion_and_replacement :: proc(t: ^testing.T) {
	alloc, arena := test_allocator(t)
	defer test_allocator_destroy(arena)

	store: Store
	store_init(&store, alloc)
	defer store_destroy(&store)

	base := tree_from_text(&store, "abc", .Original)
	defer tree_release(&store, base)

	// Replace base [0,1) with "A": one replacement, not a delete plus insert.
	replaced := tree_edit(&store, base, 0, 1, "A", .Added)
	defer tree_release(&store, replaced)
	delta, err := tree_provenance(&store, base, replaced, alloc)
	testing.expect_value(t, err, Delta_Error.None)
	testing.expect_value(t, len(delta.replacements), 1)
	testing.expect_value(t, delta.replacements[0], Replacement{start = 0, end = 1, text = "A"})

	// Pure deletion.
	deleted := tree_edit(&store, base, 1, 1, "", .Added)
	defer tree_release(&store, deleted)
	deleted_delta, deleted_err := tree_provenance(&store, base, deleted, alloc)
	testing.expect_value(t, deleted_err, Delta_Error.None)
	testing.expect_value(t, len(deleted_delta.replacements), 1)
	testing.expect_value(
		t,
		deleted_delta.replacements[0],
		Replacement{start = 1, end = 2, text = ""},
	)
}

// Complexity guard. A point edit must copy structure proportional to the tree's
// depth, not to the document. Without this, a regression that made piece
// splitting scan chunk bytes (or rebuild a subtree) would still pass every
// correctness test while turning editing into O(document).
@(test)
test_tree_middle_edit_copies_logarithmic_nodes :: proc(t: ^testing.T) {
	alloc, arena := test_allocator(t)
	defer test_allocator_destroy(arena)

	store: Store
	store_init(&store, alloc)
	defer store_destroy(&store)

	pieces: [dynamic]Piece
	pieces = make([dynamic]Piece, alloc)
	line := "line: the quick brown fox\n"
	for index in 0 ..< 2048 {
		chunk := chunk_create(&store.chunks, line, .Original, alloc)
		append(&pieces, Piece{chunk = chunk, start = 0, length = chunk.scalars})
	}
	root := tree_from_pieces(&store, pieces[:])
	// The tree retains each chunk; drop the creator references.
	for piece in pieces {
		chunk_release(piece.chunk)
	}
	defer tree_release(&store, root)

	depth := node_height(root)
	testing.expectf(t, depth >= 7, "expected real depth, got %d", depth)

	before := store.nodes.alloc_calls
	edited := tree_edit(&store, root, tree_scalars(root) / 2, 4, "XYZ", .Added)
	copied := store.nodes.alloc_calls - before

	// Path copy plus splits, joins, and rotations: bounded by a small multiple
	// of the depth, and independent of the 2048-document-piece count.
	testing.expectf(
		t,
		copied < u64(depth) * 8,
		"middle edit touched %d nodes for depth %d",
		copied,
		depth,
	)
	tree_release(&store, edited)
}

@(test)
test_tree_find_locates_occurrences :: proc(t: ^testing.T) {
	alloc, arena := test_allocator(t)
	defer test_allocator_destroy(arena)

	store: Store
	store_init(&store, alloc)
	defer store_destroy(&store)

	root := tree_from_text(&store, "the quick brown fox", .Original)
	defer tree_release(&store, root)

	offset, found := tree_find(root, "quick", 0, 0, alloc)
	testing.expect(t, found)
	testing.expect_value(t, offset, u64(4))

	// `from` skips earlier occurrences.
	offset, found = tree_find(root, "the", 1, 0, alloc)
	testing.expect(t, !found)
	offset, found = tree_find(root, "o", 12, 0, alloc)
	testing.expect(t, found)
	testing.expect_value(t, offset, u64(12))

	// A `limit` bounds the window, so a match that does not fit inside it is not
	// found.
	_, found = tree_find(root, "fox", 0, 18, alloc)
	testing.expect(t, !found)
	offset, found = tree_find(root, "fox", 0, 19, alloc)
	testing.expect(t, found)
	testing.expect_value(t, offset, u64(16))

	// An empty needle has no meaningful position.
	_, found = tree_find(root, "", 0, 0, alloc)
	testing.expect(t, !found)

	// Searching from or past the end finds nothing.
	_, found = tree_find(root, "the", tree_scalars(root), 0, alloc)
	testing.expect(t, !found)
}

@(test)
test_tree_find_crosses_chunk_boundaries :: proc(t: ^testing.T) {
	alloc, arena := test_allocator(t)
	defer test_allocator_destroy(arena)

	store: Store
	store_init(&store, alloc)
	defer store_destroy(&store)

	// Two chunks that meet in the middle of "needle": a byte-level scan of each
	// chunk buffer cannot see the match, so the search must bridge them.
	pieces := []Piece{piece_of(&store, "haystac", alloc), piece_of(&store, "kneedle", alloc)}
	root := tree_from_pieces(&store, pieces)
	// The tree retains each chunk; drop the creator references.
	for piece in pieces {
		chunk_release(piece.chunk)
	}
	defer tree_release(&store, root)

	offset, found := tree_find(root, "stackneedle", 0, 0, alloc)
	testing.expect(t, found)
	testing.expect_value(t, offset, u64(3))
	offset, found = tree_find(root, "knee", 0, 0, alloc)
	testing.expect(t, found)
	testing.expect_value(t, offset, u64(7))
}

@(test)
test_tree_find_counts_scalars_not_bytes :: proc(t: ^testing.T) {
	alloc, arena := test_allocator(t)
	defer test_allocator_destroy(arena)

	store: Store
	store_init(&store, alloc)
	defer store_destroy(&store)

	// Four multi-byte scalars before the match, so the byte index overstates
	// the scalar offset.
	root := tree_from_text(&store, "→→→→needle", .Original)
	defer tree_release(&store, root)

	offset, found := tree_find(root, "needle", 0, 0, alloc)
	testing.expect(t, found)
	testing.expect_value(t, offset, u64(4))
}

// Builds a one-chunk piece. The caller owns the chunk reference and must
// release it after the pieces have been built into a tree, which retains them.
@(private)
piece_of :: proc(store: ^Store, text: string, alloc: mem.Allocator) -> Piece {
	chunk := chunk_create(&store.chunks, text, .Original, alloc)
	return Piece{chunk = chunk, start = 0, length = chunk.scalars}
}
