// Hash indexes and hash joins over value columns for columnar rule
// evaluation. Keys hash with `v.tuple_hash_columns` and compare with
// `value_eq`, so heap values match by content.
package kernel

import "core:mem"
import v "../var"

// A chained hash index over `rows` of `columns`. Entry j is physical row
// rows[j]; heads[h] and next[j] hold entry index + 1, 0 ending a chain.
Hash_Index :: struct {
	columns: [][]v.Value,
	rows:    []u32,
	hashes:  []u64,
	heads:   []u32,
	next:    []u32,
	mask:    u64,
}

hash_index_build :: proc(columns: [][]v.Value, rows: []u32, alloc: mem.Allocator) -> Hash_Index {
	n := len(rows)
	size := 16
	for size < 2 * n {
		size <<= 1
	}
	index := Hash_Index {
		columns = columns,
		rows    = rows,
		hashes  = make([]u64, n, alloc),
		heads   = make([]u32, size, alloc),
		next    = make([]u32, n, alloc),
		mask    = u64(size - 1),
	}
	v.tuple_hash_columns(columns, rows, index.hashes)
	for j in 0 ..< n {
		h := index.hashes[j] & index.mask
		index.next[j] = index.heads[h]
		index.heads[h] = u32(j + 1)
	}
	return index
}

key_rows_eq :: #force_inline proc(a: [][]v.Value, ra: int, b: [][]v.Value, rb: int) -> bool {
	for c in 0 ..< len(a) {
		if !v.value_eq(a[c][ra], b[c][rb]) {
			return false
		}
	}
	return true
}

// present[i]: probe row i (rows 0..count-1 of `probe`) equals some indexed row.
hash_index_contains_rows :: proc(index: ^Hash_Index, probe: [][]v.Value, count: int, alloc: mem.Allocator) -> []bool {
	hashes := make([]u64, count, alloc)
	v.tuple_hash_columns(probe, nil, hashes)
	present := make([]bool, count, alloc)
	for i in 0 ..< count {
		for e := index.heads[hashes[i] & index.mask]; e != 0; e = index.next[e - 1] {
			j := int(e - 1)
			if index.hashes[j] == hashes[i] && key_rows_eq(index.columns, int(index.rows[j]), probe, i) {
				present[i] = true
				break
			}
		}
	}
	return present
}

// Equi-join on all key columns: every (build row, probe row) pair from
// `build_rows` × `probe_rows` whose keys are equal, as parallel arrays of
// physical rows, in probe order.
hash_join_pairs :: proc(
	build: [][]v.Value,
	build_rows: []u32,
	probe: [][]v.Value,
	probe_rows: []u32,
	alloc: mem.Allocator,
) -> (
	build_out, probe_out: []u32,
) {
	index := hash_index_build(build, build_rows, alloc)
	hashes := make([]u64, len(probe_rows), alloc)
	v.tuple_hash_columns(probe, probe_rows, hashes)
	b := make([dynamic]u32, 0, len(probe_rows), alloc)
	p := make([dynamic]u32, 0, len(probe_rows), alloc)
	for i in 0 ..< len(probe_rows) {
		for e := index.heads[hashes[i] & index.mask]; e != 0; e = index.next[e - 1] {
			j := int(e - 1)
			if index.hashes[j] == hashes[i] && key_rows_eq(build, int(build_rows[j]), probe, int(probe_rows[i])) {
				append(&b, build_rows[j])
				append(&p, probe_rows[i])
			}
		}
	}
	return b[:], p[:]
}
