package accel

import "core:mem"
import "core:slice"
import "core:testing"

@(private = "file")
cols :: proc(values: ..[2]u64) -> [][]u64 {
	a := make([]u64, len(values), context.temp_allocator)
	b := make([]u64, len(values), context.temp_allocator)
	for p, i in values {
		a[i], b[i] = p[0], p[1]
	}
	out := make([][]u64, 2, context.temp_allocator)
	out[0], out[1] = a, b
	return out
}

@(test)
test_membership_selection_indexes_and_invalid :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	left := [][]u64{{5, 1, 3, 1}}
	right := [][]u64{{1, 3}}
	present, res := membership_selection(cpu_strategy(), left, right, true, context.temp_allocator)
	testing.expect_value(t, res, Membership_Result.Completed)
	testing.expect(t, slice.equal(present, []u32{1, 2, 3}))
	absent, _ := membership_selection(cpu_strategy(), left, right, false, context.temp_allocator)
	testing.expect(t, slice.equal(absent, []u32{0}))

	bad := cpu_strategy()
	bad.membership_select = proc(left, right: []u64, keep: bool, allocator: mem.Allocator) -> ([]bool, bool) {
		return make([]bool, 1, allocator), true
	}
	_, bad_res := membership_selection(bad, left, right, true, context.temp_allocator)
	testing.expect_value(t, bad_res, Membership_Result.Invalid)
}

@(test)
test_membership2_cpu_matches_pair_semantics :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	right := cols({1, 1}, {1, 3}, {2, 1}, {5, 9})
	left := cols({1, 1}, {1, 2}, {2, 1}, {3, 3}, {5, 9}, {9, 5}, {0, 0})
	for s in ([]Strategy{cpu_strategy(), cpu_parallel_strategy(4)}) {
		got, res := membership_selection(s, left, right, true, context.temp_allocator)
		testing.expect_value(t, res, Membership_Result.Completed)
		testing.expect(t, slice.equal(got, []u32{0, 2, 4}))
		kept, kept_res := membership_selection(s, left, right, false, context.temp_allocator)
		testing.expect_value(t, kept_res, Membership_Result.Completed)
		testing.expect(t, slice.equal(kept, []u32{1, 3, 5, 6}))
	}
}

@(test)
test_membership2_rejects_unsorted_pairs :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	_, res := membership_selection(cpu_strategy(), cols({1, 1}), cols({2, 1}, {1, 9}), true, context.temp_allocator)
	testing.expect_value(t, res, Membership_Result.Declined)
	testing.expect_value(t, last_decline_reason(), Decline.Unsupported)
	sorted := cols({1, 1}, {1, 2}, {2, 0})
	testing.expect(t, is_sorted_unique_pairs(sorted[0], sorted[1]))
	dup := cols({1, 2}, {1, 2})
	testing.expect(t, !is_sorted_unique_pairs(dup[0], dup[1]))
}

// Large enough for the parallel strategy's pool: equal to the reference.
@(test)
test_membership2_parallel_equals_reference :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	n := CPU_PARALLEL_MIN_PROBES + 101
	right := [][]u64{make([]u64, n, context.temp_allocator), make([]u64, n, context.temp_allocator)}
	left := [][]u64{make([]u64, n, context.temp_allocator), make([]u64, n, context.temp_allocator)}
	for i in 0 ..< n {
		right[0][i], right[1][i] = u64(i / 3), u64(i % 3) * 7
		left[0][i], left[1][i] = u64((i * 2654435761) % n) / 3, u64(i % 5) * 7
	}
	want, _ := membership_selection(cpu_strategy(), left, right, true, context.temp_allocator)
	got, res := membership_selection(cpu_parallel_strategy(4), left, right, true, context.temp_allocator)
	testing.expect_value(t, res, Membership_Result.Completed)
	testing.expect(t, slice.equal(got, want))
}

@(test)
test_prepare_declines_record_reason :: proc(t: ^testing.T) {
	_, ok := prepare_column(cpu_strategy(), []u64{3, 1})
	testing.expect(t, !ok)
	testing.expect_value(t, last_decline_reason(), Decline.Unsupported)
	s := cpu_strategy()
	s.prepare_column = nil
	_, none_ok := prepare_column(s, []u64{1, 2})
	testing.expect(t, !none_ok)
	testing.expect_value(t, last_decline_reason(), Decline.Unsupported)
}
