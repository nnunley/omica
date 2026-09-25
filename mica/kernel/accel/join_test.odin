package accel

import "core:mem"
import "core:slice"
import "core:testing"

@(private = "file")
Join_Rng :: struct {
	state: u64,
}

@(private = "file")
join_next :: proc(r: ^Join_Rng) -> u64 {
	r.state = r.state * 6364136223846793005 + 1442695040888963407
	return r.state >> 33
}

@(private = "file")
Sorted_Entry :: struct {
	a, b: u64,
	row:  u32,
}

// Random right side of `m` entries with keys in 0..<domain, sorted by key
// then row: the columns and the row of each sorted entry.
@(private = "file")
sorted_right :: proc(r: ^Join_Rng, width, m: int, domain: u64) -> (columns: [][]u64, rows: []u32) {
	entries := make([]Sorted_Entry, m, context.temp_allocator)
	for i in 0 ..< m {
		entries[i] = {join_next(r) % domain, width == 2 ? join_next(r) % domain : 0, u32(i * 7 + 1)}
	}
	slice.sort_by(entries, proc(x, y: Sorted_Entry) -> bool {
		return x.a < y.a || (x.a == y.a && (x.b < y.b || (x.b == y.b && x.row < y.row)))
	})
	columns = make([][]u64, width, context.temp_allocator)
	for c in 0 ..< width {
		columns[c] = make([]u64, m, context.temp_allocator)
	}
	rows = make([]u32, m, context.temp_allocator)
	for e, j in entries {
		columns[0][j] = e.a
		if width == 2 {
			columns[1][j] = e.b
		}
		rows[j] = e.row
	}
	return
}

@(private = "file")
random_left :: proc(r: ^Join_Rng, width, n: int, domain: u64) -> [][]u64 {
	columns := make([][]u64, width, context.temp_allocator)
	for c in 0 ..< width {
		columns[c] = make([]u64, n, context.temp_allocator)
		for i in 0 ..< n {
			columns[c][i] = join_next(r) % domain
		}
	}
	return columns
}

// Nested loop: pairs ordered by left row, then sorted position.
@(private = "file")
nested_join :: proc(left, right: [][]u64, rows: []u32) -> (l, r: []u32) {
	lo := make([dynamic]u32, context.temp_allocator)
	ro := make([dynamic]u32, context.temp_allocator)
	for i in 0 ..< len(left[0]) {
		for j in 0 ..< len(rows) {
			equal := true
			for c in 0 ..< len(left) {
				equal = equal && left[c][i] == right[c][j]
			}
			if equal {
				append(&lo, u32(i))
				append(&ro, rows[j])
			}
		}
	}
	return lo[:], ro[:]
}

@(test)
test_join_pairs_cpu_matches_nested_loop :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	rng := Join_Rng{state = 0x2545f4914f6cdd1d}
	for round in 0 ..< 30 {
		width := 1 + round % 2
		n := int(join_next(&rng) % 41)
		m := int(join_next(&rng) % 41)
		right, rows := sorted_right(&rng, width, m, 5)
		left := random_left(&rng, width, n, 5)
		want_l, want_r := nested_join(left, right, rows)
		got_l, got_r, res := join_pairs(cpu_strategy(), left, right, rows, context.temp_allocator)
		testing.expect_value(t, res, Operator_Result.Completed)
		testing.expectf(t, slice.equal(got_l, want_l) && slice.equal(got_r, want_r), "round %d width %d: pairs differ", round, width)
	}
}

@(test)
test_join_pairs_rejects_bad_inputs :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	left := [][]u64{{1, 2}}
	_, _, unsorted := join_pairs(cpu_strategy(), left, [][]u64{{3, 1}}, []u32{0, 1}, context.temp_allocator)
	testing.expect_value(t, unsorted, Operator_Result.Declined)
	testing.expect_value(t, last_decline_reason(), Decline.Unsupported)
	wide := [][]u64{{1}, {1}, {1}}
	_, _, too_wide := join_pairs(cpu_strategy(), wide, wide, []u32{0}, context.temp_allocator)
	testing.expect_value(t, too_wide, Operator_Result.Declined)
	_, _, ragged := join_pairs(cpu_strategy(), [][]u64{{1, 2}, {1}}, [][]u64{{1}, {1}}, []u32{0}, context.temp_allocator)
	testing.expect_value(t, ragged, Operator_Result.Declined)
	none := cpu_strategy()
	none.join_equality = nil
	_, _, missing := join_pairs(none, left, [][]u64{{1, 2}}, []u32{0, 1}, context.temp_allocator)
	testing.expect_value(t, missing, Operator_Result.Declined)
}

@(test)
test_join_pairs_invalid_result :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	left := [][]u64{{1, 2}}
	right := [][]u64{{1, 2}}
	rows := []u32{0, 1}
	out_of_range := cpu_strategy()
	out_of_range.join_equality = proc(left, right: [][]u64, right_rows: []u32, allocator: mem.Allocator) -> ([]u32, []u32, bool) {
		l := make([]u32, 1, allocator)
		r := make([]u32, 1, allocator)
		l[0] = 5
		return l, r, true
	}
	_, _, bad := join_pairs(out_of_range, left, right, rows, context.temp_allocator)
	testing.expect_value(t, bad, Operator_Result.Invalid)
	unordered := cpu_strategy()
	unordered.join_equality = proc(left, right: [][]u64, right_rows: []u32, allocator: mem.Allocator) -> ([]u32, []u32, bool) {
		l := make([]u32, 2, allocator)
		r := make([]u32, 2, allocator)
		l[0], l[1] = 1, 0
		return l, r, true
	}
	_, _, worse := join_pairs(unordered, left, right, rows, context.temp_allocator)
	testing.expect_value(t, worse, Operator_Result.Invalid)
}

@(test)
test_join_pairs_empty_sides :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	l, r, res := join_pairs(cpu_strategy(), [][]u64{{}}, [][]u64{{1, 2}}, []u32{0, 1}, context.temp_allocator)
	testing.expect_value(t, res, Operator_Result.Completed)
	testing.expect(t, len(l) == 0 && len(r) == 0)
	l2, r2, res2 := join_pairs(cpu_strategy(), [][]u64{{1, 2}}, [][]u64{{}}, nil, context.temp_allocator)
	testing.expect_value(t, res2, Operator_Result.Completed)
	testing.expect(t, len(l2) == 0 && len(r2) == 0)
}

// Large enough for the parallel strategy's pool: equal to the reference, for
// one and two key columns.
@(test)
test_join_pairs_parallel_equals_reference :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	parallel := cpu_parallel_strategy(4)
	// Its own operator and threshold, not the inherited serial reference.
	testing.expect(t, parallel.join_equality != cpu_strategy().join_equality)
	// Measured slower than the kernel's CPU hash join on both machines
	// (Stage 3): not offered by default.
	testing.expect_value(t, parallel.join_min_probes, 0)
	n := CPU_PARALLEL_MIN_PROBES + 101
	m := 20_000
	for width in 1 ..= 2 {
		right := make([][]u64, width, context.temp_allocator)
		left := make([][]u64, width, context.temp_allocator)
		for c in 0 ..< width {
			right[c] = make([]u64, m, context.temp_allocator)
			left[c] = make([]u64, n, context.temp_allocator)
		}
		rows := make([]u32, m, context.temp_allocator)
		for j in 0 ..< m {
			right[0][j] = u64(j / 4)
			if width == 2 {
				right[1][j] = u64(j % 3)
			}
			rows[j] = u32(j)
		}
		if width == 2 {
			// (j/4, j%3) is not sorted within a group of four: sort it.
			Pair :: struct {
				a, b: u64,
				row:  u32,
			}
			pairs := make([]Pair, m, context.temp_allocator)
			for j in 0 ..< m {
				pairs[j] = {right[0][j], right[1][j], rows[j]}
			}
			slice.sort_by(pairs, proc(x, y: Pair) -> bool {return x.a < y.a || (x.a == y.a && (x.b < y.b || (x.b == y.b && x.row < y.row)))})
			for p, j in pairs {
				right[0][j], right[1][j], rows[j] = p.a, p.b, p.row
			}
		}
		for i in 0 ..< n {
			left[0][i] = u64((i * 2654435761) % 5000)
			if width == 2 {
				left[1][i] = u64(i % 3)
			}
		}
		want_l, want_r, _ := join_pairs(cpu_strategy(), left, right, rows, context.temp_allocator)
		got_l, got_r, res := join_pairs(cpu_parallel_strategy(4), left, right, rows, context.temp_allocator)
		testing.expect_value(t, res, Operator_Result.Completed)
		testing.expectf(t, slice.equal(got_l, want_l) && slice.equal(got_r, want_r), "width %d: parallel join differs (%d vs %d pairs)", width, len(got_l), len(want_l))
	}
}

// A right index that is not one of right_rows' values would make the kernel's
// gather read out of bounds: rejected as Invalid, like a bad left index.
@(test)
test_join_pairs_rejects_out_of_range_right_rows :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	bad := cpu_strategy()
	bad.join_equality = proc(left, right: [][]u64, right_rows: []u32, allocator: mem.Allocator) -> ([]u32, []u32, bool) {
		l := make([]u32, 1, allocator)
		r := make([]u32, 1, allocator)
		r[0] = 1_000_000
		return l, r, true
	}
	_, _, res := join_pairs(bad, [][]u64{{1, 2}}, [][]u64{{1, 2}}, []u32{0, 1}, context.temp_allocator)
	testing.expect_value(t, res, Operator_Result.Invalid)
}
