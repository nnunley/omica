// Reference CPU strategy: same operator shapes as the Metal backend, always
// available, no size thresholds. Benchmarks and tests run this side by side
// with the Metal strategy over identical inputs.
package accel

import "base:runtime"
import "core:mem"

@(private)
cpu_available :: proc() -> bool {
	return true
}

// Binary search of each probe in the sorted-unique right column. The Metal
// membership shader implements this same algorithm per thread.
@(private)
cpu_membership_select :: proc(
	left: []u64,
	right_sorted_unique: []u64,
	keep_matches: bool,
	allocator: mem.Allocator,
) -> (
	selected: []bool,
	ok: bool,
) {
	last_decline = .None
	if len(right_sorted_unique) == 0 {
		out := make([]bool, len(left), allocator)
		for i in 0 ..< len(left) {
			out[i] = !keep_matches
		}
		return out, true
	}
	if !is_sorted_unique(right_sorted_unique) {
		last_decline = .Unsupported
		return nil, false
	}
	out := make([]bool, len(left), allocator)
	for probe, i in left {
		hit := cpu_sorted_contains(right_sorted_unique, probe)
		out[i] = (hit == keep_matches)
	}
	return out, true
}

@(private)
cpu_pair_less :: proc(a0, a1, b0, b1: u64) -> bool {
	return a0 < b0 || (a0 == b0 && a1 < b1)
}

@(private)
cpu_sorted_contains_pair :: proc(right_a, right_b: []u64, p0, p1: u64) -> bool {
	lo, hi := 0, len(right_a)
	for lo < hi {
		mid := lo + ((hi - lo) >> 1)
		if cpu_pair_less(right_a[mid], right_b[mid], p0, p1) {
			lo = mid + 1
		} else {
			hi = mid
		}
	}
	return lo < len(right_a) && right_a[lo] == p0 && right_b[lo] == p1
}

// Two-key membership over two columns per side; membership_selection has
// checked the shape and sort order.
@(private)
cpu_membership_select2 :: proc(
	left_a, left_b, right_a, right_b: []u64,
	keep_matches: bool,
	allocator: mem.Allocator,
) -> (
	selected: []bool,
	ok: bool,
) {
	last_decline = .None
	out := make([]bool, len(left_a), allocator)
	for i in 0 ..< len(out) {
		out[i] = cpu_sorted_contains_pair(right_a, right_b, left_a[i], left_b[i]) == keep_matches
	}
	return out, true
}

@(private)
cpu_sorted_contains :: proc(sorted_unique: []u64, probe: u64) -> bool {
	lo, hi := 0, len(sorted_unique)
	for lo < hi {
		mid := lo + ((hi - lo) >> 1)
		if sorted_unique[mid] < probe {
			lo = mid + 1
		} else {
			hi = mid
		}
	}
	return lo < len(sorted_unique) && sorted_unique[lo] == probe
}

// Single-query cosine: the batched operator with n_queries = 1.
@(private)
cpu_cosine_query :: proc(
	query: []f32,
	docs: []f32,
	n_docs: int,
	dim: int,
	allocator: mem.Allocator,
) -> (
	scores: []f32,
	ok: bool,
) {
	return cpu_cosine_queries(query, docs, 1, n_docs, dim, allocator)
}

// Cosine of rows [first_doc, last_doc) of docs against one query, into out.
@(private)
cpu_cosine_rows :: proc(query: []f32, docs: []f32, dim: int, first_doc, last_doc: int, out: []f32) {
	for i in first_doc ..< last_doc {
		d2, qn, dn := cpu_dot_norms(query, docs[i * dim:(i + 1) * dim])
		out[i] = d2 / (cpu_sqrt(qn) * cpu_sqrt(dn) + 1e-9)
	}
}

// Batched cosine: n_queries x dim scored against n_docs x dim in one call.
// This is the measured fast path on Metal (one thread per query/doc pair);
// the CPU reference scores each pair with cpu_dot_norms.
@(private)
cpu_cosine_queries :: proc(
	queries: []f32,
	docs: []f32,
	n_queries: int,
	n_docs: int,
	dim: int,
	allocator: mem.Allocator,
) -> (
	scores: []f32,
	ok: bool,
) {
	last_decline = .None
	if n_queries < 1 || n_docs < 1 || dim < 1 || len(queries) < n_queries * dim || len(docs) < n_docs * dim {
		last_decline = .Unsupported
		return nil, false
	}
	out := make([]f32, n_queries * n_docs, allocator)
	for q in 0 ..< n_queries {
		cpu_cosine_rows(queries[q * dim:(q + 1) * dim], docs, dim, 0, n_docs, out[q * n_docs:(q + 1) * n_docs])
	}
	return out, true
}

@(private)
cpu_sqrt :: proc(x: f32) -> f32 {
	return x * cpu_inv_sqrt(x)
}

@(private)
cpu_inv_sqrt :: proc(x: f32) -> f32 {
	// Two Newton refinements of the bit-level approximation; matches the
	// Metal sqrt to the test tolerance (1e-3 on squared scores).
	i := transmute(u32)x
	i = 0x5f3759df - (i >> 1)
	y := transmute(f32)i
	y = y * (1.5 - 0.5 * x * y * y)
	y = y * (1.5 - 0.5 * x * y * y)
	return y
}

// CPU residency: the prepared input is a heap copy the caller no longer has
// to keep alive (or re-sort).
@(private)
Cpu_Prepared :: struct {
	column:    []u64,
	docs:      []f32,
	// A prepared copy lives from prepare to release, which may run under
	// different context allocators (an evaluation arena, a worker's temp):
	// it is owned by this allocator, fixed at prepare time.
	allocator: mem.Allocator,
}

@(private)
cpu_prepare_column :: proc(sorted_unique: []u64) -> (handle: rawptr, ok: bool) {
	owner := runtime.heap_allocator()
	p := new(Cpu_Prepared, owner)
	p.allocator = owner
	p.column = make([]u64, len(sorted_unique), owner)
	copy(p.column, sorted_unique)
	return p, true
}

@(private)
cpu_membership_select_prepared :: proc(
	left: []u64,
	column: rawptr,
	rows: int,
	keep_matches: bool,
	allocator: mem.Allocator,
) -> (
	selected: []bool,
	ok: bool,
) {
	return cpu_membership_select(left, (^Cpu_Prepared)(column).column, keep_matches, allocator)
}

@(private)
cpu_prepare_docs :: proc(docs: []f32, n_docs: int, dim: int) -> (handle: rawptr, ok: bool) {
	owner := runtime.heap_allocator()
	p := new(Cpu_Prepared, owner)
	p.allocator = owner
	p.docs = make([]f32, len(docs), owner)
	copy(p.docs, docs)
	return p, true
}

@(private)
cpu_cosine_queries_prepared :: proc(
	queries: []f32,
	n_queries: int,
	docs: rawptr,
	n_docs: int,
	dim: int,
	allocator: mem.Allocator,
) -> (
	scores: []f32,
	ok: bool,
) {
	return cpu_cosine_queries(queries, (^Cpu_Prepared)(docs).docs, n_queries, n_docs, dim, allocator)
}

@(private)
cpu_release :: proc(handle: rawptr, kind: Prepared_Kind) {
	p := (^Cpu_Prepared)(handle)
	owner := p.allocator
	delete(p.column, owner)
	delete(p.docs, owner)
	free(p, owner)
}

// Equality join by binary search of each probe in the sorted right keys;
// join_pairs has checked the shape and sort order.
@(private)
cpu_join_equality :: proc(
	left, right: [][]u64,
	right_rows: []u32,
	allocator: mem.Allocator,
) -> (
	left_out, right_out: []u32,
	ok: bool,
) {
	last_decline = .None
	n := len(left[0])
	l := make([dynamic]u32, 0, n, allocator)
	r := make([dynamic]u32, 0, n, allocator)
	for i in 0 ..< n {
		for j := join_lower_bound(left, i, right); j < len(right_rows) && join_key_cmp(left, i, right, j) == 0; j += 1 {
			append(&l, u32(i))
			append(&r, right_rows[j])
		}
	}
	return l[:], r[:], true
}
