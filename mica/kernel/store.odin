// Immutable relation storage: a sorted tuple set with secondary indexes.
//
// A `Relation_Block` is materialized once and then read-only. The primary
// store is sorted by canonical tuple order, which serves full-tuple lookups and
// leading-position prefix scans. Secondary indexes are sorted row-index arrays
// over selected argument positions.
package kernel

import "core:mem"
import "core:slice"
import "core:sort"
import v "../var"

// A relation's materialized tuple state.
Relation_Block :: struct {
	metadata: Relation_Metadata,
	tuples:   []v.Tuple,
	indexes:  []Secondary_Index,
}

// A sorted row-index array over selected argument positions.
Secondary_Index :: struct {
	positions: []u16,
	rows:      []u32,
}

// Creates an empty block for `metadata`.
relation_block_empty :: proc(alloc: mem.Allocator, metadata: Relation_Metadata) -> ^Relation_Block {
	block := new(Relation_Block, alloc)
	block.metadata = metadata
	block.tuples = make([]v.Tuple, 0, alloc)

	index_count := 0
	for spec in metadata.indexes {
		if !index_is_natural_full_tuple(spec, metadata.arity) {
			index_count += 1
		}
	}
	block.indexes = make([]Secondary_Index, index_count, alloc)
	write := 0
	for spec in metadata.indexes {
		if index_is_natural_full_tuple(spec, metadata.arity) {
			continue
		}
		block.indexes[write] = Secondary_Index {
			positions = spec.positions,
			rows      = make([]u32, 0, alloc),
		}
		write += 1
	}
	return block
}

// Builds a block from `tuples`, sorting and deduplicating the rows and
// rebuilding all secondary indexes. The tuple values themselves are not
// copied.
relation_block_build :: proc(
	alloc: mem.Allocator,
	metadata: Relation_Metadata,
	tuples: []v.Tuple,
) -> ^Relation_Block {
	block := relation_block_empty(alloc, metadata)

	rows := make([]v.Tuple, len(tuples), alloc)
	copy(rows, tuples)
	slice.sort_by(rows, proc(a, b: v.Tuple) -> bool {
		return v.tuple_cmp(a, b) == .Less
	})
	write := 0
	for row in rows {
		if write > 0 && v.tuple_cmp(rows[write - 1], row) == .Equal {
			continue
		}
		rows[write] = row
		write += 1
	}
	block.tuples = rows[:write]

	for _, i in block.indexes {
		index := &block.indexes[i]
		index.rows = make([]u32, len(block.tuples), alloc)
		for row_index in 0 ..< len(block.tuples) {
			index.rows[row_index] = u32(row_index)
		}
		sort_secondary_index(block, index)
	}
	return block
}

// Returns the number of tuples in a block.
relation_block_len :: proc(block: ^Relation_Block) -> int {
	return len(block.tuples)
}

@(private)
Index_Sort_Context :: struct {
	tuples:    []v.Tuple,
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
		ctx.tuples,
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
		tuples    = block.tuples,
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
	tuples: []v.Tuple,
	positions: []u16,
	left: u32,
	right: u32,
) -> v.Ordering {
	left_values := v.tuple_values(tuples[left])
	right_values := v.tuple_values(tuples[right])
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
	tuples: []v.Tuple,
	positions: []u16,
	row: u32,
	bindings: []v.Binding,
	count: int,
) -> v.Ordering {
	values := v.tuple_values(tuples[row])
	for i in 0 ..< count {
		position := int(positions[i])
		order := v.value_cmp(values[position], bindings[position].value)
		if order != .Equal {
			return order
		}
	}
	return .Equal
}

// Reports whether a block contains an exact tuple.
relation_block_contains :: proc(block: ^Relation_Block, tuple: v.Tuple) -> bool {
	lo, hi := 0, len(block.tuples)
	for lo < hi {
		mid := (lo + hi) / 2
		switch v.tuple_cmp(block.tuples[mid], tuple) {
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
	if len(bindings) != int(block.metadata.arity) {
		return
	}

	bound_count := v.binding_leading_bound_count(bindings)
	if bound_count == len(bindings) {
		if row, found := relation_block_tuple_for_full(block, bindings); found {
			visit(user, row)
		}
		return
	}

	best_index := -1
	best_count := 0
	for index, i in block.indexes {
		count := index_leading_bound_count(Index_Spec{positions = index.positions}, bindings)
		if count > best_count {
			best_index = i
			best_count = count
		}
	}

	if best_count > 0 {
		index := &block.indexes[best_index]
		lo := index_lower_bound(block, index, bindings, best_count)
		hi := index_upper_bound(block, index, bindings, best_count)
		for row_index in lo ..< hi {
			row := block.tuples[index.rows[row_index]]
			if v.tuple_matches_bindings(row, bindings) {
				if !visit(user, row) {
					return
				}
			}
		}
		return
	}

	for row in block.tuples {
		if v.tuple_matches_bindings(row, bindings) {
			if !visit(user, row) {
				return
			}
		}
	}
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
	values := binding_values(bindings)
	lo, hi := 0, len(block.tuples)
	for lo < hi {
		mid := (lo + hi) / 2
		order := compare_tuple_values(block.tuples[mid], values)
		switch order {
		case .Equal:
			return block.tuples[mid], true
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
		order := compare_index_prefix(block.tuples, index.positions, index.rows[mid], bindings, count)
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
		order := compare_index_prefix(block.tuples, index.positions, index.rows[mid], bindings, count)
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
