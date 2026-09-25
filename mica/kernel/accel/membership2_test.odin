package accel

import "core:testing"

@(private = "file")
pairs :: proc(values: ..[2]u64) -> []u64 {
	out := make([]u64, 2 * len(values), context.temp_allocator)
	for p, i in values {
		out[2 * i], out[2 * i + 1] = p[0], p[1]
	}
	return out
}

@(test)
test_membership2_cpu_matches_pair_semantics :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	right := pairs({1, 1}, {1, 3}, {2, 1}, {5, 9})
	left := pairs({1, 1}, {1, 2}, {2, 1}, {3, 3}, {5, 9}, {9, 5}, {0, 0})
	for s in ([]Strategy{cpu_strategy(), cpu_parallel_strategy(4)}) {
		got, ok := membership_select_keys(s, left, right, 2, true, context.temp_allocator)
		testing.expect(t, ok)
		if ok {
			testing.expect(t, slice_eq(got, []bool{true, false, true, false, true, false, false}))
		}
		kept, kept_ok := membership_select_keys(s, left, right, 2, false, context.temp_allocator)
		testing.expect(t, kept_ok)
		if kept_ok {
			testing.expect(t, slice_eq(kept, []bool{false, true, false, true, false, true, true}))
		}
	}
}

@(test)
test_membership2_rejects_unsorted_pairs :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	_, ok := membership_select_keys(cpu_strategy(), pairs({1, 1}), pairs({2, 1}, {1, 9}), 2, true, context.temp_allocator)
	testing.expect(t, !ok)
	testing.expect_value(t, last_decline_reason(), Decline.Unsupported)
	testing.expect(t, is_sorted_unique_pairs(pairs({1, 1}, {1, 2}, {2, 0})))
	testing.expect(t, !is_sorted_unique_pairs(pairs({1, 2}, {1, 2})))
}

// Large enough for the parallel strategy's pool: equal to the reference.
@(test)
test_membership2_parallel_equals_reference :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	n := CPU_PARALLEL_MIN_PROBES + 101
	right := make([]u64, 2 * n, context.temp_allocator)
	for i in 0 ..< n {
		right[2 * i], right[2 * i + 1] = u64(i / 3), u64(i % 3) * 7
	}
	left := make([]u64, 2 * n, context.temp_allocator)
	for i in 0 ..< n {
		left[2 * i], left[2 * i + 1] = u64((i * 2654435761) % n) / 3, u64(i % 5) * 7
	}
	want, _ := membership_select_keys(cpu_strategy(), left, right, 2, true, context.temp_allocator)
	got, ok := membership_select_keys(cpu_parallel_strategy(4), left, right, 2, true, context.temp_allocator)
	testing.expect(t, ok)
	if ok {
		testing.expect(t, slice_eq(got, want))
	}
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
