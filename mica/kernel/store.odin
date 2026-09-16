// Immutable relation storage: a persistent sorted sequence of rows.
//
// A block is an ordered list of immutable, reference-counted chunks. Each
// chunk owns deep copies of up to `CHUNK_CAPACITY` tuples in its own arena.
// Commits build a new block by copy-on-write: chunks outside the changed key
// range are shared, and only the chunks a change touches are rebuilt. This
// replaces the previous model, which deep-copied every row on every commit.
//
// Secondary indexes are positional and are rebuilt per block when the relation
// declares them. Relations without indexes pay no index cost.
package kernel

import "base:runtime"
import "core:mem"
import "core:mem/virtual"
import "core:slice"
import "core:sort"
import "core:sync"
import v "../var"

// Maximum rows per chunk. Small enough that copy-on-write is cheap, large
// enough that the spine stays short.
CHUNK_CAPACITY :: 128

// An immutable, reference-counted run of sorted tuples.
Relation_Chunk :: struct {
	tuples: []v.Tuple,
	refs:   i32,
	arena:  ^Frame_Arena,
	pool:   ^Arena_Pool,
	// Stable identity for the checkpoint cache. The chunk address is recycled
	// with its pooled arena, so it cannot be used as a persistent key.
	generation: u64,
}

// Monotonic source of chunk identities. Never reset; identities only need to
// be unique for the life of the process.
@(private)
chunk_generation_counter: u64

@(private)
next_chunk_generation :: proc() -> u64 {
	return sync.atomic_add(&chunk_generation_counter, 1) + 1
}

// A relation's materialized tuple state.
Relation_Block :: struct {
	metadata:    Relation_Metadata,
	chunks:      []^Relation_Chunk,
	chunk_rows:  []u32,
	count:       int,
	// Flat row view and secondary indexes, built lazily by the first
	// index-backed query. Blocks are immutable, so the cache cannot go stale;
	// deferring the build keeps the commit path O(span) instead of O(n log n).
	flat_rows:    []v.Tuple,
	indexes:      []Secondary_Index,
	indexes_once: sync.Once,
	refs:         i32,
	arena:        ^Frame_Arena,
	pool:         ^Arena_Pool,
	storage:      mem.Allocator,
}

// A sorted row-index array over selected argument positions.
Secondary_Index :: struct {
	positions: []u16,
	rows:      []u32,
}

// --- Chunks ----------------------------------------------------------------

@(private)
new_arena :: proc(pool: ^Arena_Pool) -> ^Frame_Arena {
	if pool != nil {
		return arena_pool_take(pool)
	}
	arena := new(Frame_Arena, runtime.default_allocator())
	frame_arena_init(arena)
	return arena
}

// Deep-copies `rows` into one contiguous cell block plus one tuple pointer
// array. A single allocation for all cells avoids a per-tuple allocation, and
// with it the arena mutex and page-commit work that dominates chunk building.
deep_copy_rows :: proc(alloc: mem.Allocator, rows: []v.Tuple) -> []v.Tuple {
	if len(rows) == 0 {
		return make([]v.Tuple, 0, alloc)
	}
	arity := v.tuple_arity(rows[0])
	for row in rows {
		if v.tuple_arity(row) != arity {
			// Defensive: uniform arity is expected, but do not corrupt data if
			// it is ever violated.
			owned := make([]v.Tuple, len(rows), alloc)
			for fallback, index in rows {
				owned[index] = v.tuple_deep_copy(alloc, fallback)
			}
			return owned
		}
	}

	cells := make([]v.Value, len(rows) * arity, alloc)
	owned := make([]v.Tuple, len(rows), alloc)
	for row, index in rows {
		source := v.tuple_values(row)
		start := index * arity
		for value, cell in source {
			cells[start + cell] = v.value_deep_copy(alloc, value)
		}
		owned[index] = v.Tuple(cells[start:start + arity])
	}
	return owned
}

// Creates a chunk owning deep copies of `rows`. With a pool, the chunk arena
// is pooled and recycled; without one it is owned and destroyed on release.
relation_chunk_create :: proc(pool: ^Arena_Pool, rows: []v.Tuple) -> ^Relation_Chunk {
	arena := new_arena(pool)
	alloc := frame_arena_allocator(arena)

	owned := deep_copy_rows(alloc, rows)

	chunk := new(Relation_Chunk, alloc)
	chunk.tuples = owned
	chunk.refs = 1
	chunk.arena = arena
	chunk.pool = pool
	chunk.generation = next_chunk_generation()
	return chunk
}

@(private)
relation_chunk_retain :: proc(chunk: ^Relation_Chunk) {
	if chunk == nil {
		return
	}
	sync.atomic_add_explicit(&chunk.refs, 1, .Relaxed)
}

relation_chunk_release :: proc(chunk: ^Relation_Chunk) {
	if chunk == nil {
		return
	}
	if sync.atomic_sub_explicit(&chunk.refs, 1, .Acq_Rel) != 1 {
		return
	}
	if chunk.pool != nil {
		// The chunk struct lives in the arena; nothing may touch it after the
		// pooled arena is reset.
		arena_pool_return(chunk.pool, chunk.arena)
		return
	}
	// The chunk struct lives inside its own arena, so the arena pointer must
	// be read before the arena is destroyed: a second `chunk.arena` read here
	// would read freed memory (ThreadSanitizer flags it).
	arena := chunk.arena
	frame_arena_destroy(arena)
	free(arena, runtime.default_allocator())
}

@(private)
relation_chunk_first :: proc(chunk: ^Relation_Chunk) -> v.Tuple {
	return chunk.tuples[0]
}

@(private)
relation_chunk_last :: proc(chunk: ^Relation_Chunk) -> v.Tuple {
	return chunk.tuples[len(chunk.tuples) - 1]
}

// --- Block construction ----------------------------------------------------

// Increments a block's reference count. Thread-safe.
relation_block_retain :: proc(block: ^Relation_Block) {
	if block == nil {
		return
	}
	sync.atomic_add_explicit(&block.refs, 1, .Relaxed)
}

// Decrements a block's reference count, releasing its chunks and returning its
// arena to the pool (or freeing it) when the last reference is released.
relation_block_release :: proc(block: ^Relation_Block) {
	if block == nil {
		return
	}
	if sync.atomic_sub_explicit(&block.refs, 1, .Acq_Rel) != 1 {
		return
	}

	for chunk in block.chunks {
		relation_chunk_release(chunk)
	}
	block.chunks = nil

	if block.pool != nil {
		// The block struct lives in the pooled arena.
		arena_pool_return(block.pool, block.arena)
		return
	}
	free(block, block.storage)
}

// Builds a standalone block from `tuples`, sorting and deduplicating. Used by
// tests and benchmarks; the commit path uses `relation_block_apply`.
relation_block_build :: proc(
	alloc: mem.Allocator,
	metadata: Relation_Metadata,
	tuples: []v.Tuple,
) -> ^Relation_Block {
	rows := make([]v.Tuple, len(tuples), alloc)
	copy(rows, tuples)
	rows = sorted_unique_rows(rows, alloc)

	block := new(Relation_Block, alloc)
	block.metadata = metadata
	block.storage = alloc
	block.refs = 1
	block.count = len(rows)
	block.chunks = chunks_from_rows(nil, rows, alloc)
	block.chunk_rows = make([]u32, len(block.chunks), alloc)
	fill_chunk_rows(block)
	return block
}

// Builds a pooled block from `tuples`, sorting and deduplicating. Chunks and
// the block arena come from the kernel pool, so releasing the block recycles
// them. Benchmarks use this for repeated builds.
relation_block_build_pooled :: proc(
	kernel: ^Kernel,
	metadata: Relation_Metadata,
	tuples: []v.Tuple,
) -> ^Relation_Block {
	rows := make([]v.Tuple, len(tuples), context.temp_allocator)
	copy(rows, tuples)
	rows = sorted_unique_rows(rows, context.temp_allocator)

	block_arena := arena_pool_take(kernel.arena_pool)
	block_alloc := frame_arena_allocator(block_arena)

	block := new(Relation_Block, block_alloc)
	block.metadata = metadata
	block.refs = 1
	block.count = len(rows)
	block.chunks = chunks_from_rows(kernel.arena_pool, rows, block_alloc)
	block.chunk_rows = make([]u32, len(block.chunks), block_alloc)
	block.arena = block_arena
	block.pool = kernel.arena_pool
	fill_chunk_rows(block)
	return block
}

// Builds a new block that shares unaffected chunks with `base` and rebuilds
// only the chunks touched by `entries`. Chunks and the block arena come from
// the kernel pool so superseded blocks recycle.
relation_block_apply :: proc(
	kernel: ^Kernel,
	base: ^Relation_Block,
	metadata: Relation_Metadata,
	entries: []Pending_Write,
) -> ^Relation_Block {
	chunks := base != nil ? base.chunks : []^Relation_Chunk{}
	count := base != nil ? base.count : 0

	// Locate the span of chunks the entries can affect. When the entries fall
	// in the gap before a chunk or beyond the last key, the neighbouring chunk
	// is merged as well: that both keeps chunk fill near capacity on appends
	// and avoids leaving a trail of single-row chunks and an O(n) spine.
	lo := 0
	hi := len(chunks) - 1
	if len(entries) > 0 {
		first := entries[0].tuple
		for lo < len(chunks) && v.tuple_cmp(relation_chunk_last(chunks[lo]), first) == .Less {
			lo += 1
		}
		last := entries[len(entries) - 1].tuple
		for hi >= 0 && v.tuple_cmp(relation_chunk_first(chunks[hi]), last) == .Greater {
			hi -= 1
		}
		if hi < lo {
			// The entries fall before a chunk or past the last one. Merge the
			// neighbouring chunk only when it has room: filling the tail keeps
			// chunk counts linear, while a full tail starts a fresh chunk
			// without copying it.
			if hi >= 0 && len(chunks[hi].tuples) < CHUNK_CAPACITY {
				lo = hi
			}
		}
	}
	suffix_start := max(hi + 1, lo)

	block_arena := arena_pool_take(kernel.arena_pool)
	block_alloc := frame_arena_allocator(block_arena)

	merged := make([]v.Tuple, chunk_span_rows(chunks, lo, hi) + len(entries), block_alloc)
	written := 0
	added, removed := merge_chunks(merged, &written, chunks, lo, hi, entries)
	count = count + added - removed

	new_chunks := chunks_from_rows(kernel.arena_pool, merged[:written], block_alloc)

	total := lo + len(new_chunks) + (len(chunks) - suffix_start)
	spine := make([]^Relation_Chunk, total, block_alloc)
	write := 0
	for index in 0 ..< lo {
		relation_chunk_retain(chunks[index])
		spine[write] = chunks[index]
		write += 1
	}
	for chunk in new_chunks {
		spine[write] = chunk
		write += 1
	}
	for index in suffix_start ..< len(chunks) {
		relation_chunk_retain(chunks[index])
		spine[write] = chunks[index]
		write += 1
	}

	block := new(Relation_Block, block_alloc)
	block.metadata = metadata
	block.chunks = spine
	block.count = count
	block.refs = 1
	block.arena = block_arena
	block.pool = kernel.arena_pool
	block.chunk_rows = make([]u32, len(spine), block_alloc)
	fill_chunk_rows(block)
	return block
}

@(private)
sorted_unique_rows :: proc(rows: []v.Tuple, alloc: mem.Allocator) -> []v.Tuple {
	return v.canonicalize_tuples(rows, alloc)
}

@(private)
chunks_from_rows :: proc(
	pool: ^Arena_Pool,
	rows: []v.Tuple,
	alloc: mem.Allocator,
) -> []^Relation_Chunk {
	count := (len(rows) + CHUNK_CAPACITY - 1) / CHUNK_CAPACITY
	chunks := make([]^Relation_Chunk, count, alloc)
	for index in 0 ..< count {
		start := index * CHUNK_CAPACITY
		end := min(start + CHUNK_CAPACITY, len(rows))
		chunks[index] = relation_chunk_create(pool, rows[start:end])
	}
	return chunks
}

@(private)
chunk_span_rows :: proc(chunks: []^Relation_Chunk, lo, hi: int) -> int {
	total := 0
	for index in lo ..= hi {
		total += len(chunks[index].tuples)
	}
	return total
}

// Merges the rows of chunks `[lo, hi]` with the sorted `entries` directly,
// without materialising the base rows in a scratch array.
@(private)
merge_chunks :: proc(
	merged: []v.Tuple,
	written: ^int,
	chunks: []^Relation_Chunk,
	lo, hi: int,
	entries: []Pending_Write,
) -> (
	added: int,
	removed: int,
) {
	put :: proc(merged: []v.Tuple, written: ^int, row: v.Tuple) {
		merged[written^] = row
		written^ += 1
	}
	entry_index := 0
	for index in lo ..= hi {
		for row in chunks[index].tuples {
			for entry_index < len(entries) &&
			    v.tuple_cmp(entries[entry_index].tuple, row) == .Less {
				if entries[entry_index].kind == .Assert {
					put(merged, written, entries[entry_index].tuple)
					added += 1
				}
				entry_index += 1
			}
			if entry_index < len(entries) &&
			   v.tuple_cmp(entries[entry_index].tuple, row) == .Equal {
				if entries[entry_index].kind == .Assert {
					put(merged, written, row)
				} else {
					removed += 1
				}
				entry_index += 1
			} else {
				put(merged, written, row)
			}
		}
	}
	for entry_index < len(entries) {
		if entries[entry_index].kind == .Assert {
			put(merged, written, entries[entry_index].tuple)
			added += 1
		}
		entry_index += 1
	}
	return added, removed
}

@(private)
fill_chunk_rows :: proc(block: ^Relation_Block) {
	row := u32(0)
	for chunk, index in block.chunks {
		block.chunk_rows[index] = row
		row += u32(len(chunk.tuples))
	}
}

// --- Block queries ---------------------------------------------------------

// Returns the number of tuples in a block.
relation_block_len :: proc(block: ^Relation_Block) -> int {
	return block.count
}

// Returns the tuple at a logical row position.
relation_block_row :: proc(block: ^Relation_Block, row_index: int) -> v.Tuple {
	if row_index < 0 || row_index >= block.count {
		return nil
	}
	// Find the last chunk whose start is at or before the row.
	lo, hi := 0, len(block.chunk_rows)
	for lo < hi {
		mid := (lo + hi) / 2
		if int(block.chunk_rows[mid]) <= row_index {
			lo = mid + 1
		} else {
			hi = mid
		}
	}
	if lo == 0 {
		return nil
	}
	chunk := block.chunks[lo - 1]
	offset := row_index - int(block.chunk_rows[lo - 1])
	if offset < 0 || offset >= len(chunk.tuples) {
		return nil
	}
	return chunk.tuples[offset]
}

// Reports whether a block contains an exact tuple.
relation_block_contains :: proc(block: ^Relation_Block, tuple: v.Tuple) -> bool {
	if block == nil {
		return false
	}
	chunk := chunk_for_tuple(block, tuple)
	if chunk == nil {
		return false
	}
	lo, hi := 0, len(chunk.tuples)
	for lo < hi {
		mid := (lo + hi) / 2
		switch v.tuple_cmp(chunk.tuples[mid], tuple) {
		case .Equal:
			return true
		case .Less:
			lo = mid + 1
		case .Greater:
			hi = mid
		}
	}
	return false
}

@(private)
chunk_for_tuple :: proc(block: ^Relation_Block, tuple: v.Tuple) -> ^Relation_Chunk {
	lo, hi := 0, len(block.chunks)
	for lo < hi {
		mid := (lo + hi) / 2
		chunk := block.chunks[mid]
		if v.tuple_cmp(relation_chunk_last(chunk), tuple) == .Less {
			lo = mid + 1
			continue
		}
		if v.tuple_cmp(relation_chunk_first(chunk), tuple) == .Greater {
			hi = mid
			continue
		}
		return chunk
	}
	return nil
}

// Returns the tuple matching an exact projected key over `positions`.
relation_block_tuple_for_key :: proc(
	block: ^Relation_Block,
	positions: []u16,
	key_values: []v.Value,
) -> (v.Tuple, bool) {
	if len(key_values) != len(positions) {
		return nil, false
	}
	bindings := make([]v.Binding, block.metadata.arity, context.temp_allocator)
	for position, i in positions {
		bindings[int(position)] = v.binding_of(key_values[i])
	}
	found: v.Tuple
	relation_block_visit(
		block,
		bindings,
		proc(user: rawptr, row: v.Tuple) -> bool {
			(^v.Tuple)(user)^ = row
			return false
		},
		&found,
	)
	return found, found != nil
}

// Visits tuples matching a partial binding. The visitor returns false to
// stop.
relation_block_visit :: proc(
	block: ^Relation_Block,
	bindings: []v.Binding,
	visit: proc(user: rawptr, row: v.Tuple) -> bool,
	user: rawptr,
) {
	if block == nil || len(bindings) != int(block.metadata.arity) {
		return
	}

	bound_count := v.binding_leading_bound_count(bindings)
	if bound_count == len(bindings) {
		if row, found := relation_block_tuple_for_full(block, bindings); found {
			visit(user, row)
		}
		return
	}

	primary_count := bound_count
	best_index := -1
	best_count := 0
	packed := 0
	for spec in block.metadata.indexes {
		if index_is_natural_full_tuple(spec, block.metadata.arity) {
			continue
		}
		count := index_leading_bound_count(spec, bindings)
		if count > best_count {
			best_index = packed
			best_count = count
		}
		packed += 1
	}

	// A secondary index wins ties, matching the Rust kernel. Otherwise the
	// primary store's sorted order serves the leading prefix.
	use_index := best_count > 0 && best_count >= primary_count
	if use_index {
		relation_block_ensure_indexes(block)
		index := &block.indexes[best_index]
		lo := index_lower_bound(block, index, bindings, best_count)
		hi := index_upper_bound(block, index, bindings, best_count)
		for row_index in lo ..< hi {
			row := block.flat_rows[index.rows[row_index]]
			if v.tuple_matches_bindings(row, bindings) {
				if !visit(user, row) {
					return
				}
			}
		}
		return
	}

	if primary_count > 0 {
		start := 0
		for start < len(block.chunks) {
			order := compare_primary_prefix(
				relation_chunk_last(block.chunks[start]),
				bindings,
				primary_count,
			)
			if order != .Less {
				break
			}
			start += 1
		}
		for index in start ..< len(block.chunks) {
			chunk := block.chunks[index]
			if compare_primary_prefix(
				relation_chunk_first(chunk),
				bindings,
				primary_count,
			) == .Greater {
				break
			}
			// Rows are stored in primary (full-tuple) order, so the leading
			// prefix is sorted within the chunk too. Binary-search the first
			// row whose prefix is not less than the binding, then visit only
			// the rows sharing that prefix. Without this, a single-row probe
			// walked the whole chunk, making a nested-loop join O(rows^2 / 128).
			lo := 0
			hi := len(chunk.tuples)
			for lo < hi {
				mid := lo + (hi - lo) / 2
				if compare_primary_prefix(chunk.tuples[mid], bindings, primary_count) == .Less {
					lo = mid + 1
				} else {
					hi = mid
				}
			}
			for row_index in lo ..< len(chunk.tuples) {
				row := chunk.tuples[row_index]
				if compare_primary_prefix(row, bindings, primary_count) == .Greater {
					break
				}
				if v.tuple_matches_bindings(row, bindings) {
					if !visit(user, row) {
						return
					}
				}
			}
		}
		return
	}

	for chunk in block.chunks {
		for row in chunk.tuples {
			if v.tuple_matches_bindings(row, bindings) {
				if !visit(user, row) {
					return
				}
			}
		}
	}
}

@(private)
compare_primary_prefix :: proc(
	tuple: v.Tuple,
	bindings: []v.Binding,
	count: int,
) -> v.Ordering {
	values := v.tuple_values(tuple)
	for i in 0 ..< count {
		order := v.value_cmp(values[i], bindings[i].value)
		if order != .Equal {
			return order
		}
	}
	return .Equal
}

@(private)
binding_values :: proc(bindings: []v.Binding) -> []v.Value {
	values := make([]v.Value, len(bindings), context.temp_allocator)
	for binding, i in bindings {
		values[i] = binding.value
	}
	return values
}

@(private)
relation_block_tuple_for_full :: proc(
	block: ^Relation_Block,
	bindings: []v.Binding,
) -> (v.Tuple, bool) {
	if block == nil || len(bindings) == 0 {
		return nil, false
	}
	values := binding_values(bindings)
	tuple := v.tuple_new(context.temp_allocator, values)
	chunk := chunk_for_tuple(block, tuple)
	if chunk == nil {
		return nil, false
	}
	lo, hi := 0, len(chunk.tuples)
	for lo < hi {
		mid := (lo + hi) / 2
		order := compare_tuple_values(chunk.tuples[mid], values)
		switch order {
		case .Equal:
			return chunk.tuples[mid], true
		case .Less:
			lo = mid + 1
		case .Greater:
			hi = mid
		}
	}
	return nil, false
}

@(private)
compare_tuple_values :: proc(row: v.Tuple, key: []v.Value) -> v.Ordering {
	row_values := v.tuple_values(row)
	n := min(len(row_values), len(key))
	for i in 0 ..< n {
		order := v.value_cmp(row_values[i], key[i])
		if order != .Equal {
			return order
		}
	}
	switch {
	case len(row_values) < len(key):
		return .Less
	case len(row_values) > len(key):
		return .Greater
	}
	return .Equal
}

// --- Secondary indexes -----------------------------------------------------

// Returns the allocator that owns the block's structures. Pooled blocks use
// their frame arena, whose allocator is mutex-protected, so the lazy index
// build is safe from any reader thread.
@(private)
relation_block_allocator :: proc(block: ^Relation_Block) -> mem.Allocator {
	if block.pool != nil {
		return frame_arena_allocator(block.arena)
	}
	if block.storage.procedure != nil {
		return block.storage
	}
	return context.allocator
}

// Materializes `flat_rows` and the secondary indexes from the block's chunks.
// Idempotent; runs through `relation_block_ensure_indexes`.
@(private)
build_block_indexes :: proc(block: ^Relation_Block) {
	alloc := relation_block_allocator(block)
	index_count := 0
	for spec in block.metadata.indexes {
		if !index_is_natural_full_tuple(spec, block.metadata.arity) {
			index_count += 1
		}
	}
	if index_count == 0 {
		block.indexes = nil
		return
	}
	block.indexes = make([]Secondary_Index, index_count, alloc)

	// Indexed relations keep a flat row view so index comparisons are O(1)
	// instead of walking the chunk spine.
	block.flat_rows = make([]v.Tuple, block.count, alloc)
	row_index := 0
	for chunk in block.chunks {
		for row in chunk.tuples {
			block.flat_rows[row_index] = row
			row_index += 1
		}
	}

	write := 0
	for spec in block.metadata.indexes {
		if index_is_natural_full_tuple(spec, block.metadata.arity) {
			continue
		}
		rows := make([]u32, block.count, alloc)
		for row in 0 ..< block.count {
			rows[row] = u32(row)
		}
		index := Secondary_Index {
			positions = spec.positions,
			rows      = rows,
		}
		sort_secondary_index(block, &index)
		block.indexes[write] = index
		write += 1
	}
}

// Builds the block's secondary indexes on first use. Blocks are immutable, so
// one build is enough for the block's lifetime, and a commit pays nothing for
// an index no query has asked for. `indexes_once` serializes concurrent
// first readers.
@(private)
relation_block_ensure_indexes :: proc(block: ^Relation_Block) {
	sync.once_do(&block.indexes_once, proc(data: rawptr) {
		build_block_indexes((^Relation_Block)(data))
	}, block)
}

@(private)
Index_Sort_Context :: struct {
	block:     ^Relation_Block,
	positions: []u16,
	rows:      []u32,
}

@(private)
index_sort_len :: proc(it: sort.Interface) -> int {
	return len((^Index_Sort_Context)(it.collection).rows)
}

@(private)
index_sort_less :: proc(it: sort.Interface, i, j: int) -> bool {
	ctx := (^Index_Sort_Context)(it.collection)
	return compare_index_rows(
		ctx.block,
		ctx.positions,
		ctx.rows[i],
		ctx.rows[j],
	) == .Less
}

@(private)
index_sort_swap :: proc(it: sort.Interface, i, j: int) {
	ctx := (^Index_Sort_Context)(it.collection)
	ctx.rows[i], ctx.rows[j] = ctx.rows[j], ctx.rows[i]
}

@(private)
sort_secondary_index :: proc(block: ^Relation_Block, index: ^Secondary_Index) {
	ctx := Index_Sort_Context {
		block     = block,
		positions = index.positions,
		rows      = index.rows,
	}
	sort.sort(sort.Interface {
		collection = &ctx,
		len = index_sort_len,
		less = index_sort_less,
		swap = index_sort_swap,
	})
}

@(private)
compare_index_rows :: proc(
	block: ^Relation_Block,
	positions: []u16,
	left: u32,
	right: u32,
) -> v.Ordering {
	left_values := v.tuple_values(block.flat_rows[left])
	right_values := v.tuple_values(block.flat_rows[right])
	for position in positions {
		order := v.value_cmp(left_values[int(position)], right_values[int(position)])
		if order != .Equal {
			return order
		}
	}
	switch {
	case left < right:
		return .Less
	case left > right:
		return .Greater
	}
	return .Equal
}

@(private)
compare_index_prefix :: proc(
	block: ^Relation_Block,
	positions: []u16,
	row: u32,
	bindings: []v.Binding,
	count: int,
) -> v.Ordering {
	values := v.tuple_values(block.flat_rows[row])
	for i in 0 ..< count {
		position := int(positions[i])
		order := v.value_cmp(values[position], bindings[position].value)
		if order != .Equal {
			return order
		}
	}
	return .Equal
}

@(private)
index_lower_bound :: proc(
	block: ^Relation_Block,
	index: ^Secondary_Index,
	bindings: []v.Binding,
	count: int,
) -> int {
	lo, hi := 0, len(index.rows)
	for lo < hi {
		mid := (lo + hi) / 2
		order := compare_index_prefix(block, index.positions, index.rows[mid], bindings, count)
		if order == .Less {
			lo = mid + 1
		} else {
			hi = mid
		}
	}
	return lo
}

@(private)
index_upper_bound :: proc(
	block: ^Relation_Block,
	index: ^Secondary_Index,
	bindings: []v.Binding,
	count: int,
) -> int {
	lo, hi := 0, len(index.rows)
	for lo < hi {
		mid := (lo + hi) / 2
		order := compare_index_prefix(block, index.positions, index.rows[mid], bindings, count)
		if order != .Greater {
			lo = mid + 1
		} else {
			hi = mid
		}
	}
	return lo
}

// Appends every tuple matching a partial binding to `out`.
relation_block_scan_into :: proc(
	block: ^Relation_Block,
	bindings: []v.Binding,
	out: ^[dynamic]v.Tuple,
) {
	relation_block_visit(
		block,
		bindings,
		proc(user: rawptr, row: v.Tuple) -> bool {
			append((^[dynamic]v.Tuple)(user), row)
			return true
		},
		out,
	)
}
