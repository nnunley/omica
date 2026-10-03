// Column batches for rule evaluation (docs/accel-engine-design.md §6).
//
// A batch holds rows column-major. For a rule step, columns are indexed by
// rule slot (variable) and an unbound slot has no column; for a relation scan
// they are indexed by position and all are bound. Evaluation is
// breadth-first, so every row of a batch binds the same slots. Filters narrow
// `selection` instead of copying; columns are gathered only when a step needs
// them dense.
package kernel

import "core:mem"
import v "../var"

Column_Batch :: struct {
	// Physical rows in every bound column.
	count:     int,
	columns:   [][]v.Value,
	bound:     []bool,
	// fixed[s]: every value in column s is fixed-width (immediate).
	fixed:     []bool,
	// Live physical rows in increasing order; nil means 0..count-1.
	selection: []u32,
}

column_batch_make :: proc(width: int, alloc: mem.Allocator) -> Column_Batch {
	return Column_Batch {
		columns = make([][]v.Value, width, alloc),
		bound = make([]bool, width, alloc),
		fixed = make([]bool, width, alloc),
	}
}

// The batch a rule application starts from: one row, nothing bound.
column_batch_unit :: proc(width: int, alloc: mem.Allocator) -> Column_Batch {
	b := column_batch_make(width, alloc)
	b.count = 1
	return b
}

column_batch_live :: proc(b: ^Column_Batch) -> int {
	if b.selection != nil {
		return len(b.selection)
	}
	return b.count
}

// The physical row of live row `i`.
column_batch_row :: #force_inline proc(b: ^Column_Batch, i: int) -> int {
	if b.selection != nil {
		return int(b.selection[i])
	}
	return i
}

column_batch_live_rows :: proc(b: ^Column_Batch, alloc: mem.Allocator) -> []u32 {
	if b.selection != nil {
		return b.selection
	}
	return row_iota(b.count, alloc)
}

// Slot `s`'s values over the live rows, gathered when a selection is set.
column_batch_live_column :: proc(b: ^Column_Batch, s: int, alloc: mem.Allocator) -> []v.Value {
	if b.selection == nil {
		return b.columns[s][:b.count]
	}
	out := make([]v.Value, len(b.selection), alloc)
	column := b.columns[s]
	for r, i in b.selection {
		out[i] = column[r]
	}
	return out
}

// Binds slot `s` to `column` (count values) and records whether it is all
// fixed-width.
column_batch_set :: proc(b: ^Column_Batch, s: int, column: []v.Value) {
	b.columns[s] = column
	b.bound[s] = true
	b.fixed[s] = column_all_fixed(column)
}

// Keeps the live rows listed in `keep_live` (indexes into the live rows, in
// increasing order).
column_batch_select :: proc(b: ^Column_Batch, keep_live: []u32, alloc: mem.Allocator) {
	if len(keep_live) == 0 {
		// An empty slice may be nil, which would read as "every row live".
		b.count = 0
		b.selection = nil
		return
	}
	next := make([]u32, len(keep_live), alloc)
	for live, i in keep_live {
		next[i] = u32(column_batch_row(b, int(live)))
	}
	b.selection = next
}

column_all_fixed :: proc(column: []v.Value) -> bool {
	for value in column {
		if !v.value_is_immediate(value) {
			return false
		}
	}
	return true
}

row_iota :: proc(n: int, alloc: mem.Allocator) -> []u32 {
	out := make([]u32, n, alloc)
	for i in 0 ..< n {
		out[i] = u32(i)
	}
	return out
}

// Accumulates rows column by column: one dynamic column per position.
Column_Sink :: struct {
	columns:   [][dynamic]v.Value,
	count:     int,
	allocator: mem.Allocator,
}

column_sink_make :: proc(width: int, alloc: mem.Allocator) -> Column_Sink {
	sink := Column_Sink {
		columns   = make([][dynamic]v.Value, width, alloc),
		allocator = alloc,
	}
	for c in 0 ..< width {
		sink.columns[c] = make([dynamic]v.Value, 0, alloc)
	}
	return sink
}

column_sink_append_tuple :: proc(sink: ^Column_Sink, row: v.Tuple) {
	for value, c in v.tuple_values(row) {
		append(&sink.columns[c], value)
	}
	sink.count += 1
}

// Relation-visit callback form of `column_sink_append_tuple`; `user` is the sink.
column_sink_visit :: proc(user: rawptr, row: v.Tuple) -> bool {
	column_sink_append_tuple((^Column_Sink)(user), row)
	return true
}

// The accumulated rows as a batch with every column bound.
column_sink_batch :: proc(sink: ^Column_Sink) -> Column_Batch {
	b := column_batch_make(len(sink.columns), sink.allocator)
	b.count = sink.count
	for c in 0 ..< len(sink.columns) {
		column_batch_set(&b, c, sink.columns[c][:])
	}
	return b
}
