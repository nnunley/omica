package accel

import "core:testing"

// The pool starts once: repeated parallel calls reuse the same threads.
@(test)
test_cpu_pool_is_reused :: proc(t: ^testing.T) {
	cpu_pool_start()
	first := cpu_pool_threads()
	testing.expect(t, first >= 0)
	left := make([]u64, CPU_PARALLEL_MIN_PROBES * 2, context.temp_allocator)
	right := []u64{1, 2, 3}
	p := cpu_parallel_strategy(4)
	for _ in 0 ..< 5 {
		_, ok := p.membership_select(left, right, true, context.temp_allocator)
		testing.expect(t, ok)
	}
	testing.expect_value(t, cpu_pool_threads(), first)
	free_all(context.temp_allocator)
}

// Every chunk runs exactly once, whatever the pool size.
@(test)
test_cpu_pool_covers_every_row_once :: proc(t: ^testing.T) {
	Job :: struct {
		hits: []int,
	}
	hits := make([]int, 100_003, context.temp_allocator)
	job := Job{hits = hits}
	// Eight workers so the pool, not the single-thread shortcut, runs it.
	_ = cpu_parallel_strategy(8)
	// A false return means another test held the pool and nothing ran:
	// retrying is safe.
	for !cpu_parallel_for(len(hits), &job, proc(j: rawptr, first, last: int) {
		h := (^Job)(j).hits
		for i in first ..< last {
			h[i] += 1
		}
	}) {
	}
	for h, i in hits {
		if h != 1 {
			testing.expectf(t, false, "row %d ran %d times", i, h)
			break
		}
	}
	free_all(context.temp_allocator)
}
