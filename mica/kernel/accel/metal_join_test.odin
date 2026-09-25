#+build darwin
package accel

import "core:slice"
import "core:sync"
import "core:testing"

// Metal's join equals the CPU reference exactly (same pairs, same order), for
// one and two key columns with duplicates on both sides; zero probes return
// no pairs. Skipped without a Metal device.
@(test)
test_metal_join_agrees_with_cpu :: proc(t: ^testing.T) {
	sync.mutex_lock(&metal_tests_lock)
	defer sync.mutex_unlock(&metal_tests_lock)
	defer free_all(context.temp_allocator)
	m := metal_strategy()
	testing.expect(t, m.join_equality != nil)
	// Not offered by default: no win over the CPU hash join (Stage 3).
	testing.expect_value(t, m.join_min_probes, 0)
	if !m.available() {
		return
	}
	n, rows_n := 20_000, 50_000
	for width in 1 ..= 2 {
		right := make([][]u64, width, context.temp_allocator)
		left := make([][]u64, width, context.temp_allocator)
		for c in 0 ..< width {
			right[c] = make([]u64, rows_n, context.temp_allocator)
			left[c] = make([]u64, n, context.temp_allocator)
		}
		rows := make([]u32, rows_n, context.temp_allocator)
		for j in 0 ..< rows_n {
			// Sorted by construction: (j/6, (j/2)%3) is non-decreasing.
			right[0][j] = u64(j / 6)
			if width == 2 {
				right[1][j] = u64((j / 2) % 3)
			}
			rows[j] = u32(j * 3)
		}
		for i in 0 ..< n {
			left[0][i] = u64((i * 2654435761) % 9000)
			if width == 2 {
				left[1][i] = u64(i % 3)
			}
		}
		want_l, want_r, _ := join_pairs(cpu_strategy(), left, right, rows, context.temp_allocator)
		got_l, got_r, res := join_pairs(m, left, right, rows, context.temp_allocator)
		testing.expectf(t, res == .Completed, "width %d: %v (%v)", width, res, last_decline_reason())
		testing.expectf(t, slice.equal(got_l, want_l) && slice.equal(got_r, want_r), "width %d: Metal join differs (%d vs %d pairs)", width, len(got_l), len(want_l))
	}
	l, r, res := join_pairs(m, [][]u64{{}}, [][]u64{{1, 2}}, []u32{0, 1}, context.temp_allocator)
	testing.expect_value(t, res, Operator_Result.Completed)
	testing.expect(t, len(l) == 0 && len(r) == 0)
}
