// Piece-tree nodes: fixed-capacity slab objects, retained by reference count.
//
// The index over a piece sequence is a persistent balanced binary tree. Leaves
// hold up to `NODE_FANOUT` pieces; internal nodes have exactly two children.
// Every node caches its subtree's scalar and newline counts, so offset and line
// addressing are logarithmic, and its height, so the balance invariant can be
// maintained by local rotations.
//
// The source model is still a piece table -- an immutable original plus
// appended chunks -- and the tree is only the index over its pieces. The
// design proposed a fan-out-B-tree index; a binary balanced index is used here
// because it reaches the same O(log N) contracts with a rebalancing strategy
// that is easier to keep correct. The buffer API hides the choice.
//
// Ownership convention:
//   - `node_leaf` and `node_internal` return an owned node;
//   - `node_internal` consumes its two child references;
//   - `node_leaf` retains the chunks of the pieces it is given.
package buffer

import "core:mem"

NODE_FANOUT :: 16

// A run of scalars inside one chunk. `start` and `length` are scalar offsets
// within the chunk, so provenance is exactly `(chunk, start, length)`.
Piece :: struct {
	chunk:  ^Text_Chunk,
	start:  u64,
	length: u64,
}

Piece_Node :: struct {
	refs:     i64,
	leaf:     bool,
	count:    u16,
	height:   u16,
	scalars:  u64,
	newlines: u64,
	pieces:   [NODE_FANOUT]Piece,
	children: [2]^Piece_Node,
}

// Slab pool for nodes. Freed nodes are recycled, so a steady edit loop does no
// node allocation at all.
Node_Pool :: struct {
	allocator:   mem.Allocator,
	free:        [dynamic]^Piece_Node,
	allocations: u64,
	reuses:      u64,
	// Every node_alloc call, whether it allocated or recycled. Tests use this
	// to assert that an edit copies structure proportional to the tree's depth
	// rather than to the document.
	alloc_calls: u64,
}

node_pool_init :: proc(pool: ^Node_Pool, allocator := context.allocator) {
	pool.allocator = allocator
	pool.free = make([dynamic]^Piece_Node, allocator)
}

node_pool_destroy :: proc(pool: ^Node_Pool) {
	for node in pool.free {
		free(node, pool.allocator)
	}
	delete(pool.free)
}

@(private)
node_alloc :: proc(pool: ^Node_Pool) -> ^Piece_Node {
	pool.alloc_calls += 1
	if len(pool.free) > 0 {
		node := pop(&pool.free)
		pool.reuses += 1
		node^ = Piece_Node{}
		return node
	}
	pool.allocations += 1
	return new(Piece_Node, pool.allocator)
}

@(private)
node_free :: proc(pool: ^Node_Pool, node: ^Piece_Node) {
	append(&pool.free, node)
}

node_retain :: proc(node: ^Piece_Node) -> ^Piece_Node {
	if node != nil {
		node.refs += 1
	}
	return node
}

// Releases one reference. When a node's last reference goes, the subtree is
// freed iteratively with an explicit worklist: a deep tree must not overflow
// the stack, and release is O(j) in the number of nodes that actually reach
// zero, not O(1).
node_release :: proc(pool: ^Node_Pool, node: ^Piece_Node) {
	if node == nil {
		return
	}
	node.refs -= 1
	if node.refs > 0 {
		return
	}

	worklist: [dynamic]^Piece_Node
	worklist = make([dynamic]^Piece_Node, pool.allocator)
	append(&worklist, node)
	for len(worklist) > 0 {
		current := pop(&worklist)
		current.refs -= 1
		if current.refs > 0 {
			continue
		}
		if current.leaf {
			for index in 0 ..< int(current.count) {
				chunk_release(current.pieces[index].chunk)
			}
		} else {
			append(&worklist, current.children[0])
			append(&worklist, current.children[1])
		}
		node_free(pool, current)
	}
	delete(worklist)
}

node_height :: proc(node: ^Piece_Node) -> int {
	return node == nil ? 0 : int(node.height)
}

node_scalars :: proc(node: ^Piece_Node) -> u64 {
	return node == nil ? 0 : node.scalars
}

node_newlines :: proc(node: ^Piece_Node) -> u64 {
	return node == nil ? 0 : node.newlines
}

// Builds a leaf from `pieces`, retaining each chunk. `pieces` is copied.
node_leaf :: proc(pool: ^Node_Pool, pieces: []Piece) -> ^Piece_Node {
	node := node_alloc(pool)
	node.refs = 1
	node.leaf = true
	node.count = u16(len(pieces))
	node.height = 1
	for piece, index in pieces {
		node.pieces[index] = piece
		chunk_retain(piece.chunk)
		node.scalars += piece.length
		node.newlines += piece_newlines(piece)
	}
	return node
}

// Builds an internal node, consuming `left` and `right`.
node_internal :: proc(pool: ^Node_Pool, left, right: ^Piece_Node) -> ^Piece_Node {
	node := node_alloc(pool)
	node.refs = 1
	node.leaf = false
	node.count = 2
	node.children[0] = left
	node.children[1] = right
	node.scalars = left.scalars + right.scalars
	node.newlines = left.newlines + right.newlines
	node.height = u16(1 + max(node_height(left), node_height(right)))
	return node
}

// Newlines contributed by a piece. The chunk's newline index makes this
// logarithmic in the chunk's newline count; scanning bytes here would make
// every piece split O(chunk), and therefore every middle edit O(document).
@(private)
piece_newlines :: proc(piece: Piece) -> u64 {
	return chunk_newlines_in_range(
		piece.chunk,
		piece.start,
		piece.start + piece.length,
	)
}
