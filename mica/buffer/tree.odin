// The persistent piece-tree index.
//
// A buffer's text is a sequence of pieces over immutable chunks. This file
// indexes that sequence with a persistent balanced binary tree, so an edit
// copies O(log N) nodes and shares every untouched subtree. Reads, offset
// lookup, line lookup, span visit, and the provenance walk all descend cached
// scalar and newline counts.
//
// `tree_provenance` is the bridge to the semantic model in `document.odin`: it
// derives the same base-relative replacement set that `delta_derive` derives
// from the tagged reference document. The two are compared directly by the
// differential tests, which is how the storage index is held to the frozen
// semantics.
package buffer

import "core:mem"
import "core:strings"
import "core:unicode/utf8"

// A store owns the chunk and node pools for a set of buffers.
Store :: struct {
	chunks:    Chunk_Pool,
	nodes:     Node_Pool,
	allocator: mem.Allocator,
}

store_init :: proc(store: ^Store, allocator := context.allocator) {
	store.allocator = allocator
	chunk_pool_init(&store.chunks, allocator)
	node_pool_init(&store.nodes, allocator)
}

store_destroy :: proc(store: ^Store) {
	node_pool_destroy(&store.nodes)
	chunk_pool_destroy(&store.chunks)
}

tree_retain :: proc(root: ^Piece_Node) -> ^Piece_Node {
	return node_retain(root)
}

tree_release :: proc(store: ^Store, root: ^Piece_Node) {
	node_release(&store.nodes, root)
}

tree_scalars :: proc(root: ^Piece_Node) -> u64 {
	return node_scalars(root)
}

// Newline count. The line count is `tree_newlines(root) + 1`.
tree_newlines :: proc(root: ^Piece_Node) -> u64 {
	return node_newlines(root)
}

tree_line_count :: proc(root: ^Piece_Node) -> u64 {
	return tree_newlines(root) + 1
}

// Merges adjacent pieces that are contiguous in both the view and the chunk.
// Merging across chunks would destroy provenance, so it is deliberately not
// done.
@(private)
pieces_coalesce :: proc(pieces: []Piece, allocator: mem.Allocator) -> []Piece {
	out: [dynamic]Piece
	out = make([dynamic]Piece, allocator)
	for piece in pieces {
		if len(out) > 0 {
			last := &out[len(out) - 1]
			if last.chunk == piece.chunk && last.start + last.length == piece.start {
				last.length += piece.length
				continue
			}
		}
		append(&out, piece)
	}
	return out[:]
}

@(private)
tree_build_recursive :: proc(store: ^Store, pieces: []Piece) -> ^Piece_Node {
	if len(pieces) == 0 {
		return nil
	}
	if len(pieces) <= NODE_FANOUT {
		return node_leaf(&store.nodes, pieces)
	}
	mid := len(pieces) / 2
	left := tree_build_recursive(store, pieces[:mid])
	right := tree_build_recursive(store, pieces[mid:])
	return node_internal(&store.nodes, left, right)
}

// Builds a balanced tree from an ordered piece sequence, coalescing first.
tree_from_pieces :: proc(store: ^Store, pieces: []Piece) -> ^Piece_Node {
	coalesced := pieces_coalesce(pieces, store.allocator)
	return tree_build_recursive(store, coalesced)
}

// Builds a tree holding `text` as a single chunk of `kind`.
tree_from_text :: proc(store: ^Store, text: string, kind: Chunk_Kind) -> ^Piece_Node {
	if len(text) == 0 {
		return nil
	}
	chunk := chunk_create(&store.chunks, text, kind, store.allocator)
	piece := Piece {
		chunk  = chunk,
		start  = 0,
		length = chunk.scalars,
	}
	root := node_leaf(&store.nodes, []Piece{piece})
	chunk_release(chunk)
	return root
}

// Collects the tree's pieces in view order.
tree_collect_pieces :: proc(root: ^Piece_Node, out: ^[dynamic]Piece) {
	if root == nil {
		return
	}
	if root.leaf {
		for index in 0 ..< int(root.count) {
			append(out, root.pieces[index])
		}
		return
	}
	tree_collect_pieces(root.children[0], out)
	tree_collect_pieces(root.children[1], out)
}

// Visits borrowed byte spans covering scalar range `[start, end)`. A span is
// valid while the caller holds a reference to the root, which retains its
// chunks. The visitor returns false to stop early.
tree_visit_spans :: proc(
	root: ^Piece_Node,
	start, end: u64,
	visit: proc(user: rawptr, text: string, offset: u64) -> bool,
	user: rawptr,
) -> bool {
	position := u64(0)
	return tree_visit_node(root, start, end, &position, visit, user)
}

@(private)
tree_visit_node :: proc(
	node: ^Piece_Node,
	start, end: u64,
	position: ^u64,
	visit: proc(user: rawptr, text: string, offset: u64) -> bool,
	user: rawptr,
) -> bool {
	if node == nil {
		return true
	}
	// Entirely before the requested range.
	if position^ + node.scalars <= start {
		position^ += node.scalars
		return true
	}
	// Entirely after: nothing later can match, so stop.
	if position^ >= end {
		return false
	}

	if node.leaf {
		for index in 0 ..< int(node.count) {
			piece := node.pieces[index]
			piece_start := position^
			piece_end := piece_start + piece.length
			if piece_end <= start {
				position^ = piece_end
				continue
			}
			if piece_start >= end {
				return false
			}
			low := max(start, piece_start) - piece_start
			high := min(end, piece_end) - piece_start
			byte_low := chunk_byte_offset(piece.chunk, piece.start + low)
			byte_high := chunk_byte_offset(piece.chunk, piece.start + high)
			text := string(piece.chunk.bytes[byte_low:byte_high])
			if !visit(user, text, piece_start + low) {
				return false
			}
			position^ = piece_end
		}
		return true
	}

	if !tree_visit_node(node.children[0], start, end, position, visit, user) {
		return false
	}
	return tree_visit_node(node.children[1], start, end, position, visit, user)
}

@(private)
Append_State :: struct {
	builder: ^[dynamic]u8,
}

@(private)
append_span :: proc(user: rawptr, text: string, offset: u64) -> bool {
	state := cast(^Append_State)user
	append(state.builder, ..transmute([]u8)text)
	return true
}

// Renders the whole tree as text.
tree_text :: proc(root: ^Piece_Node, allocator := context.allocator) -> string {
	builder: [dynamic]u8
	builder = make([dynamic]u8, allocator)
	state := Append_State {
		builder = &builder,
	}
	tree_visit_spans(root, 0, tree_scalars(root), append_span, &state)
	return string(builder[:])
}

// Scalar offset of the `n`-th newline (0-based), or -1 when absent.
tree_newline_scalar :: proc(root: ^Piece_Node, n: u64) -> i64 {
	if root == nil || n >= root.newlines {
		return -1
	}
	if root.leaf {
		remaining := n
		base := u64(0)
		for index in 0 ..< int(root.count) {
			piece := root.pieces[index]
			piece_newline_count := piece_newlines(piece)
			if remaining < piece_newline_count {
				offset := chunk_piece_newline(piece, remaining)
				if offset < 0 {
					return -1
				}
				return i64(base + u64(offset))
			}
			remaining -= piece_newline_count
			base += piece.length
		}
		return -1
	}
	left := root.children[0]
	if n < left.newlines {
		return tree_newline_scalar(left, n)
	}
	return tree_newline_scalar(root.children[1], n - left.newlines)
}

// Scalar offset of the `n`-th newline within a piece, or -1.
@(private)
chunk_piece_newline :: proc(piece: Piece, n: u64) -> i64 {
	return chunk_nth_newline_in_range(piece.chunk, piece.start, piece.start + piece.length, n)
}

// Scalar offset where `line` starts (0-based). Returns the scalar count when the
// line is past the end.
tree_line_start :: proc(root: ^Piece_Node, line: u64) -> u64 {
	if line == 0 {
		return 0
	}
	offset := tree_newline_scalar(root, line - 1)
	if offset < 0 {
		return tree_scalars(root)
	}
	return u64(offset) + 1
}

// Line index containing scalar `scalar`.
tree_line_of_scalar :: proc(root: ^Piece_Node, scalar: u64) -> u64 {
	// Count newlines strictly before `scalar`.
	count := u64(0)
	position := u64(0)
	tree_count_newlines_before(root, scalar, &count, &position)
	return count
}

@(private)
tree_count_newlines_before :: proc(node: ^Piece_Node, scalar: u64, count: ^u64, position: ^u64) {
	if node == nil || position^ >= scalar {
		return
	}
	if position^ + node.scalars <= scalar {
		count^ += node.newlines
		position^ += node.scalars
		return
	}
	if node.leaf {
		for index in 0 ..< int(node.count) {
			piece := node.pieces[index]
			if position^ >= scalar {
				return
			}
			if position^ + piece.length <= scalar {
				count^ += piece_newlines(piece)
				position^ += piece.length
				continue
			}
			// Partial: count newlines inside the covered prefix.
			limit := scalar - position^
			byte_start := chunk_byte_offset(piece.chunk, piece.start)
			byte_end := chunk_byte_offset(piece.chunk, piece.start + limit)
			for byte := byte_start; byte < byte_end; byte += 1 {
				if piece.chunk.bytes[byte] == '\n' {
					count^ += 1
				}
			}
			position^ += limit
			return
		}
		return
	}
	tree_count_newlines_before(node.children[0], scalar, count, position)
	tree_count_newlines_before(node.children[1], scalar, count, position)
}

// --- Split and join -------------------------------------------------------

// Splits `node` at scalar offset `at` into two owned trees.
tree_split :: proc(store: ^Store, node: ^Piece_Node, at: u64) -> (^Piece_Node, ^Piece_Node) {
	if node == nil {
		return nil, nil
	}
	if node.leaf {
		left: [dynamic]Piece
		left = make([dynamic]Piece, store.allocator)
		right: [dynamic]Piece
		right = make([dynamic]Piece, store.allocator)
		defer delete(left)
		defer delete(right)

		remaining := at
		for index in 0 ..< int(node.count) {
			piece := node.pieces[index]
			switch {
			case remaining >= piece.length:
				append(&left, piece)
				remaining -= piece.length
			case remaining == 0:
				append(&right, piece)
			case:
				append(&left, Piece{chunk = piece.chunk, start = piece.start, length = remaining})
				append(
					&right,
					Piece {
						chunk = piece.chunk,
						start = piece.start + remaining,
						length = piece.length - remaining,
					},
				)
				remaining = 0
			}
		}
		left_node := len(left) > 0 ? node_leaf(&store.nodes, left[:]) : nil
		right_node := len(right) > 0 ? node_leaf(&store.nodes, right[:]) : nil
		return left_node, right_node
	}

	left_child := node.children[0]
	right_child := node.children[1]
	left_scalars := left_child.scalars

	if at < left_scalars {
		a, b := tree_split(store, left_child, at)
		joined := tree_join(store, b, right_child)
		node_release(&store.nodes, b)
		return a, joined
	}
	if at > left_scalars {
		a, b := tree_split(store, right_child, at - left_scalars)
		joined := tree_join(store, left_child, a)
		node_release(&store.nodes, a)
		return joined, b
	}
	return node_retain(left_child), node_retain(right_child)
}

// Joins two trees into an owned result. Both arguments are borrowed.
tree_join :: proc(store: ^Store, left, right: ^Piece_Node) -> ^Piece_Node {
	if left == nil {
		return node_retain(right)
	}
	if right == nil {
		return node_retain(left)
	}

	left_height := node_height(left)
	right_height := node_height(right)

	if left_height > right_height + 1 {
		joined := tree_join(store, left.children[1], right)
		return tree_rebalance(store, node_retain(left.children[0]), joined)
	}
	if right_height > left_height + 1 {
		joined := tree_join(store, left, right.children[0])
		return tree_rebalance(store, joined, node_retain(right.children[1]))
	}
	return tree_rebalance(store, node_retain(left), node_retain(right))
}

// Builds an internal node from two owned children, rotating to restore the
// height invariant when they differ by more than one.
@(private)
tree_rebalance :: proc(store: ^Store, left, right: ^Piece_Node) -> ^Piece_Node {
	left_height := node_height(left)
	right_height := node_height(right)

	if left_height > right_height + 1 {
		// `left` is internal; its children exist.
		left_left := left.children[0]
		left_right := left.children[1]
		if node_height(left_left) >= node_height(left_right) {
			// Single right rotation: (ll, (lr, r)).
			inner := node_internal(&store.nodes, node_retain(left_right), right)
			result := node_internal(&store.nodes, node_retain(left_left), inner)
			node_release(&store.nodes, left)
			return result
		}
		// Double rotation: ((ll, lrl), (lrr, r)).
		lrl := left_right.children[0]
		lrr := left_right.children[1]
		new_left := node_internal(&store.nodes, node_retain(left_left), node_retain(lrl))
		new_right := node_internal(&store.nodes, node_retain(lrr), right)
		result := node_internal(&store.nodes, new_left, new_right)
		node_release(&store.nodes, left)
		return result
	}

	if right_height > left_height + 1 {
		right_left := right.children[0]
		right_right := right.children[1]
		if node_height(right_right) >= node_height(right_left) {
			// Single left rotation: ((l, rl), rr).
			inner := node_internal(&store.nodes, left, node_retain(right_left))
			result := node_internal(&store.nodes, inner, node_retain(right_right))
			node_release(&store.nodes, right)
			return result
		}
		// Double rotation: ((l, rll), (rlr, rr)).
		rll := right_left.children[0]
		rlr := right_left.children[1]
		new_left := node_internal(&store.nodes, left, node_retain(rll))
		new_right := node_internal(&store.nodes, node_retain(rlr), node_retain(right_right))
		result := node_internal(&store.nodes, new_left, new_right)
		node_release(&store.nodes, right)
		return result
	}

	return node_internal(&store.nodes, left, right)
}

// Splices `text` (as a new chunk of `kind`) into the range `[at, at+remove)`.
// `root` is borrowed; the result is owned.
tree_edit :: proc(
	store: ^Store,
	root: ^Piece_Node,
	at: u64,
	remove: u64,
	text: string,
	kind: Chunk_Kind,
) -> ^Piece_Node {
	left, rest := tree_split(store, root, at)
	mid, right := tree_split(store, rest, remove)
	node_release(&store.nodes, rest)
	node_release(&store.nodes, mid)

	inserted: ^Piece_Node = nil
	if len(text) > 0 {
		chunk := chunk_create(&store.chunks, text, kind, store.allocator)
		piece := Piece {
			chunk  = chunk,
			start  = 0,
			length = chunk.scalars,
		}
		inserted = node_leaf(&store.nodes, []Piece{piece})
		chunk_release(chunk)
	}

	joined := tree_join(store, left, inserted)
	node_release(&store.nodes, left)
	node_release(&store.nodes, inserted)

	result := tree_join(store, joined, right)
	node_release(&store.nodes, joined)
	node_release(&store.nodes, right)
	return result
}

// --- Provenance -----------------------------------------------------------

@(private)
Base_Entry :: struct {
	chunk_id: u64,
	start:    u64,
	length:   u64,
	base_pos: u64,
}

@(private)
collect_base_entries :: proc(root: ^Piece_Node, out: ^[dynamic]Base_Entry, position: ^u64) {
	if root == nil {
		return
	}
	if root.leaf {
		for index in 0 ..< int(root.count) {
			piece := root.pieces[index]
			append(
				out,
				Base_Entry {
					chunk_id = piece.chunk.id,
					start = piece.start,
					length = piece.length,
					base_pos = position^,
				},
			)
			position^ += piece.length
		}
		return
	}
	collect_base_entries(root.children[0], out, position)
	collect_base_entries(root.children[1], out, position)
}

// Derives the base-relative delta of `edited` against `base`, using the same
// region logic as `delta_derive`: a cell is retained only when the base
// actually contains that `(chunk, interval)`, and each maximal non-retained
// region becomes one replacement.
//
// The prototype scans base entries monotonically from a cursor, which is
// correct because splices preserve the order of base material and never
// duplicate a chunk interval. The kernel build replaces the cursor with a
// chunk-keyed index when the base spans many chunks.
tree_provenance :: proc(
	store: ^Store,
	base, edited: ^Piece_Node,
	allocator := context.allocator,
) -> (
	Delta,
	Delta_Error,
) {
	return tree_provenance_counted(store, base, edited, nil, allocator)
}

// As `tree_provenance`, reporting comparison steps through `steps` when given.
// The budget bounds work performed, not the size of the result, so the counter
// is what it checks.
tree_provenance_counted :: proc(
	store: ^Store,
	base, edited: ^Piece_Node,
	steps: ^u64,
	allocator := context.allocator,
	max_steps: u64 = 0,
) -> (
	Delta,
	Delta_Error,
) {
	base_entries: [dynamic]Base_Entry
	base_entries = make([dynamic]Base_Entry, allocator)
	defer delete(base_entries)
	base_position := u64(0)
	collect_base_entries(base, &base_entries, &base_position)
	base_scalars := base_position
	// Odin's map storage requires cache-line alignment. Transaction frame
	// arenas deliberately provide smaller alignment, so this transient lookup
	// index uses the worker-local temporary allocator and is released here.
	index_allocator := context.temp_allocator
	base_by_chunk := make(map[u64][dynamic]Base_Entry, index_allocator)
	for entry in base_entries {
		bucket, found := base_by_chunk[entry.chunk_id]
		if !found {
			bucket = make([dynamic]Base_Entry, 0, index_allocator)
		}
		append(&bucket, entry)
		base_by_chunk[entry.chunk_id] = bucket
	}
	defer {
		for _, bucket in base_by_chunk {
			delete(bucket)
		}
		delete(base_by_chunk)
	}

	reps: [dynamic]Replacement
	reps = make([dynamic]Replacement, allocator)

	pending_bytes: [dynamic]u8
	pending_bytes = make([dynamic]u8, allocator)

	have_pending := false
	region_start := u64(0)
	next_base := u64(0)

	pieces: [dynamic]Piece
	pieces = make([dynamic]Piece, allocator)
	defer delete(pieces)
	tree_collect_pieces(edited, &pieces)

	// Flush the current non-retained region. A region that is only a deletion
	// starts at the base cursor, not at the previous region's origin.
	flush := proc(
		reps: ^[dynamic]Replacement,
		pending_bytes: ^[dynamic]u8,
		start, end: u64,
		allocator: mem.Allocator,
	) {
		text := strings.clone(string(pending_bytes^[:]), allocator)
		append(reps, Replacement{start = int(start), end = int(end), text = text})
		clear(pending_bytes)
	}

	for piece in pieces {
		if steps != nil {
			steps^ += 1
			if max_steps > 0 && steps^ > max_steps {
				return Delta{}, .Budget_Exceeded
			}
		}
		// A piece is retained base material only when the base actually
		// contains that (chunk, interval). The scan is linear in the base's
		// piece count, which is correct regardless of how insertions and
		// deletions interleave; the kernel build replaces it with a
		// chunk-keyed index.
		retained_base: i64 = -1
		if candidates, found := base_by_chunk[piece.chunk.id]; found {
			for entry in candidates {
				if steps != nil {
					steps^ += 1
					if max_steps > 0 && steps^ > max_steps {
						return Delta{}, .Budget_Exceeded
					}
				}
				if piece.start >= entry.start &&
				   piece.start + piece.length <= entry.start + entry.length {
					retained_base = i64(entry.base_pos + (piece.start - entry.start))
					break
				}
			}
		}

		if retained_base >= 0 {
			base_pos := u64(retained_base)
			if base_pos < next_base {
				// Foreign or reordered base provenance: the base cannot
				// account for it.
				return Delta{}, .Foreign_Base_Cell
			}
			if have_pending || base_pos > next_base {
				if !have_pending {
					region_start = next_base
				}
				flush(&reps, &pending_bytes, region_start, base_pos, allocator)
				have_pending = false
			}
			next_base = base_pos + piece.length
		} else {
			if !have_pending {
				region_start = next_base
				have_pending = true
			}
			byte_start := chunk_byte_offset(piece.chunk, piece.start)
			byte_end := chunk_byte_offset(piece.chunk, piece.start + piece.length)
			append(&pending_bytes, ..piece.chunk.bytes[byte_start:byte_end])
		}
	}

	if have_pending || next_base < base_scalars {
		if !have_pending {
			region_start = next_base
		}
		flush(&reps, &pending_bytes, region_start, base_scalars, allocator)
	}

	// `pending_bytes` holds the concatenated text of the current non-retained
	// region; it is cloned into the replacement on flush.

	return Delta{replacements = reps[:]}, .None
}

// Applies a base-relative delta to a tree, producing an owned tree.
//
// This is how a transaction commits into a root whose chunk lineage moved under
// it (a compaction between its base and the current root): the transaction's
// edits are re-applied as normalized replacements rather than by publishing its
// own pre-compaction private root.
tree_apply_delta :: proc(
	store: ^Store,
	root: ^Piece_Node,
	delta: Delta,
) -> (
	^Piece_Node,
	Edit_Error,
) {
	current := tree_retain(root)
	for index := len(delta.replacements) - 1; index >= 0; index -= 1 {
		rep := delta.replacements[index]
		if rep.start < 0 || rep.end < rep.start || u64(rep.end) > tree_scalars(current) {
			tree_release(store, current)
			return nil, .Out_Of_Range
		}
		next := tree_edit(
			store,
			current,
			u64(rep.start),
			u64(rep.end - rep.start),
			rep.text,
			.Added,
		)
		tree_release(store, current)
		current = next
	}
	return current, .None
}

// Copies scalar range `[start, end)` of a tree into a string.
tree_slice :: proc(
	root: ^Piece_Node,
	start, end: u64,
	allocator := context.allocator,
) -> (
	string,
	Edit_Error,
) {
	total := tree_scalars(root)
	if start > end || end > total {
		return "", .Out_Of_Range
	}
	builder: [dynamic]u8
	builder = make([dynamic]u8, allocator)
	state := Append_State {
		builder = &builder,
	}
	tree_visit_spans(root, start, end, append_span, &state)
	return string(builder[:]), .None
}

// Finds `needle` in the scalar window starting at `from`, returning the scalar
// offset of the first occurrence.
//
// `limit` bounds the window in scalars; zero means "to the end". The window is
// materialized so a match may cross a chunk boundary, which is why the search
// is O(window) in both time and scratch space: a byte-level scan of separate
// chunk buffers could not see a match that straddles two of them.
tree_find :: proc(
	root: ^Piece_Node,
	needle: string,
	from, limit: u64,
	allocator := context.allocator,
) -> (
	u64,
	bool,
) {
	if len(needle) == 0 {
		return 0, false
	}
	total := tree_scalars(root)
	if from >= total {
		return 0, false
	}
	end := total
	if limit > 0 && limit < total - from {
		end = from + limit
	}
	window, slice_error := tree_slice(root, from, end, allocator)
	if slice_error != .None {
		return 0, false
	}
	index := strings.index(window, needle)
	if index < 0 {
		return 0, false
	}
	return from + u64(utf8.rune_count_in_string(window[:index])), true
}
