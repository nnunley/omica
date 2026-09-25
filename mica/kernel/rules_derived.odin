// Derived relations accumulated during one rule evaluation, column-major
// (docs/accel-engine-design.md §6). Each relation keeps one column per
// position, each row's hash (`v.tuple_hash`, computed column-wise) and a flat
// open-addressing index for deduplication. All storage comes from the
// evaluation arena. Snapshots never hold this form: `derived_relations_from`
// transposes to rows.
package kernel

import "core:mem"
import v "../var"

Derived_Columns :: struct {
	relation: Relation_ID,
	arity:    int,
	columns:  [][dynamic]v.Value,
	hashes:   [dynamic]u64,
	// Row index + 1 per slot, 0 when empty. Power-of-two length, at most half
	// full.
	index:    []u32,
	// Rows scans see while the set is frozen (strict semi-naive rounds).
	visible:  int,
}

Rule_Derived :: struct {
	allocator: mem.Allocator,
	relations: [dynamic]^Derived_Columns,
	// While frozen, scans see each relation as it was at the freeze; adds and
	// deduplication still see every row.
	frozen:    bool,
}

// Freezes what scans see: each relation's current rows, and nothing of a
// relation first created while frozen.
rules_derived_freeze :: proc(d: ^Rule_Derived) {
	for entry in d.relations {
		entry.visible = len(entry.hashes)
	}
	d.frozen = true
}

rules_derived_thaw :: proc(d: ^Rule_Derived) {
	d.frozen = false
}

// Rows of `entry` that scans see.
rules_derived_visible :: #force_inline proc(d: ^Rule_Derived, entry: ^Derived_Columns) -> int {
	return d.frozen ? entry.visible : len(entry.hashes)
}

DERIVED_INDEX_MIN :: 16

// At most this many extra rows are reserved per batch: a batch whose candidates
// collapse to few new rows must not size storage that lives for the whole
// evaluation; larger results still grow by doubling past it.
DERIVED_RESERVE_MAX :: 65_536

// Creates an empty derived set whose storage is allocated from `alloc`.
rules_derived_create :: proc(alloc: mem.Allocator) -> Rule_Derived {
	return Rule_Derived{allocator = alloc, relations = make([dynamic]^Derived_Columns, 0, alloc)}
}

rules_derived_find :: proc(d: ^Rule_Derived, relation: Relation_ID) -> ^Derived_Columns {
	if d == nil {
		return nil
	}
	for entry in d.relations {
		if entry.relation == relation {
			return entry
		}
	}
	return nil
}

// Rows scans see (all rows unless frozen).
rules_derived_count :: proc(d: ^Rule_Derived, relation: Relation_ID) -> int {
	entry := rules_derived_find(d, relation)
	return entry == nil ? 0 : rules_derived_visible(d, entry)
}

@(private)
rules_derived_entry :: proc(d: ^Rule_Derived, relation: Relation_ID, arity: int) -> ^Derived_Columns {
	if entry := rules_derived_find(d, relation); entry != nil {
		return entry
	}
	entry := new(Derived_Columns, d.allocator)
	entry^ = Derived_Columns {
		relation = relation,
		arity    = arity,
		columns  = make([][dynamic]v.Value, arity, d.allocator),
		hashes   = make([dynamic]u64, 0, d.allocator),
		index    = make([]u32, DERIVED_INDEX_MIN, d.allocator),
	}
	for c in 0 ..< arity {
		entry.columns[c] = make([dynamic]v.Value, 0, d.allocator)
	}
	append(&d.relations, entry)
	return entry
}

@(private)
derived_row_eq :: #force_inline proc(entry: ^Derived_Columns, row: int, columns: [][]v.Value, r: int) -> bool {
	for c in 0 ..< entry.arity {
		if !v.value_eq(entry.columns[c][row], columns[c][r]) {
			return false
		}
	}
	return true
}

@(private)
derived_index_grow :: proc(entry: ^Derived_Columns, alloc: mem.Allocator) {
	index := make([]u32, 2 * len(entry.index), alloc)
	mask := u64(len(index) - 1)
	for hash, row in entry.hashes {
		slot := hash & mask
		for index[slot] != 0 {
			slot = (slot + 1) & mask
		}
		index[slot] = u32(row + 1)
	}
	entry.index = index
}

// Makes room for `extra` more rows in one step: the index is rebuilt at most
// once (to stay at most half full) and the columns and hashes grow once,
// instead of doubling repeatedly while a large batch is inserted.
@(private)
derived_reserve :: proc(entry: ^Derived_Columns, alloc: mem.Allocator, extra: int) {
	want := len(entry.hashes) + extra
	size := len(entry.index)
	for 2 * want > size {
		size *= 2
	}
	if size != len(entry.index) {
		index := make([]u32, size, alloc)
		mask := u64(size - 1)
		for hash, row in entry.hashes {
			slot := hash & mask
			for index[slot] != 0 {
				slot = (slot + 1) & mask
			}
			index[slot] = u32(row + 1)
		}
		entry.index = index
	}
	// Grow geometrically: reserving exactly `want` reallocates on nearly every
	// batch, and in an arena each outgrown copy stays allocated.
	if want > cap(entry.hashes) {
		want = max(want, 2 * cap(entry.hashes))
		reserve(&entry.hashes, want)
		for c in 0 ..< entry.arity {
			reserve(&entry.columns[c], want)
		}
	}
}

// Inserts row `r` of `columns` unless an equal row exists. `hash` is its
// `tuple_hash`.
@(private)
derived_insert :: proc(entry: ^Derived_Columns, alloc: mem.Allocator, hash: u64, columns: [][]v.Value, r: int) -> bool {
	if 2 * (len(entry.hashes) + 1) > len(entry.index) {
		derived_index_grow(entry, alloc)
	}
	mask := u64(len(entry.index) - 1)
	slot := hash & mask
	for entry.index[slot] != 0 {
		row := int(entry.index[slot] - 1)
		if entry.hashes[row] == hash && derived_row_eq(entry, row, columns, r) {
			return false
		}
		slot = (slot + 1) & mask
	}
	entry.index[slot] = u32(len(entry.hashes) + 1)
	append(&entry.hashes, hash)
	for c in 0 ..< entry.arity {
		append(&entry.columns[c], columns[c][r])
	}
	return true
}

// Adds rows 0..count-1 of `columns` (one column per position) to `relation`,
// skipping rows already present, including repeats within the batch. Each new
// row is also added to `delta` when non-nil. Returns the number of new rows.
// `scratch` holds only the batch's hashes.
rules_derived_add_columns :: proc(
	d: ^Rule_Derived,
	delta: ^Rule_Derived,
	relation: Relation_ID,
	columns: [][]v.Value,
	count: int,
	scratch: mem.Allocator,
) -> int {
	if count == 0 {
		return 0
	}
	entry := rules_derived_entry(d, relation, len(columns))
	delta_entry: ^Derived_Columns
	if delta != nil {
		delta_entry = rules_derived_entry(delta, relation, len(columns))
	}
	hashes := make([]u64, count, scratch)
	v.tuple_hash_columns(columns, nil, hashes)
	derived_reserve(entry, d.allocator, min(count, DERIVED_RESERVE_MAX))
	added := 0
	for r in 0 ..< count {
		if derived_insert(entry, d.allocator, hashes[r], columns, r) {
			added += 1
			if delta_entry != nil {
				derived_insert(delta_entry, delta.allocator, hashes[r], columns, r)
			}
		}
	}
	return added
}

// Adds one tuple, returning true when it was new.
rules_derived_add :: proc(d: ^Rule_Derived, relation: Relation_ID, tuple: v.Tuple) -> bool {
	values := v.tuple_values(tuple)
	entry := rules_derived_entry(d, relation, len(values))
	columns := make([][]v.Value, len(values), d.allocator)
	for c in 0 ..< len(values) {
		columns[c] = values[c:c + 1]
	}
	return derived_insert(entry, d.allocator, v.tuple_hash(tuple), columns, 0)
}

@(private)
derived_row_tuple :: proc(entry: ^Derived_Columns, row: int, alloc: mem.Allocator) -> v.Tuple {
	values := make([]v.Value, entry.arity, alloc)
	for c in 0 ..< entry.arity {
		values[c] = entry.columns[c][row]
	}
	return v.Tuple(values)
}

// Visits rows matching a partial binding, each materialized as a tuple in the
// evaluation arena (row consumers such as computed scanners may keep it).
// Returns true when the visitor stopped the scan.
rules_derived_visit :: proc(
	d: ^Rule_Derived,
	relation: Relation_ID,
	bindings: []v.Binding,
	visit: proc(user: rawptr, row: v.Tuple) -> bool,
	user: rawptr,
) -> bool {
	entry := rules_derived_find(d, relation)
	if entry == nil || len(bindings) != entry.arity {
		return false
	}
	for row in 0 ..< rules_derived_visible(d, entry) {
		matches := true
		for binding, c in bindings {
			if binding.bound && !v.value_eq(entry.columns[c][row], binding.value) {
				matches = false
				break
			}
		}
		if matches && !visit(user, derived_row_tuple(entry, row, d.allocator)) {
			return true
		}
	}
	return false
}

rules_derived_tuples :: proc(d: ^Rule_Derived, relation: Relation_ID, alloc: mem.Allocator) -> []v.Tuple {
	entry := rules_derived_find(d, relation)
	if entry == nil {
		return nil
	}
	rows := make([]v.Tuple, len(entry.hashes), alloc)
	for row in 0 ..< len(rows) {
		rows[row] = derived_row_tuple(entry, row, alloc)
	}
	return rows
}

// Each row's hash, equal to `v.tuple_hash` of the row.
rules_derived_hashes :: proc(d: ^Rule_Derived, relation: Relation_ID) -> []u64 {
	entry := rules_derived_find(d, relation)
	return entry == nil ? nil : entry.hashes[:]
}
