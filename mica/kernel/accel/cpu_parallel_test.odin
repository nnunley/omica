package accel

import "core:sync"
import "core:testing"
import "core:thread"

@(private = "file")
membership_inputs :: proc(n: int) -> (left: []u64, right: []u64) {
	left = make([]u64, n, context.temp_allocator)
	right = make([]u64, n, context.temp_allocator)
	for i in 0 ..< n {
		left[i] = (u64(i) * 2654435761) % u64(3 * n)
		right[i] = u64(i) * 3 + 1
	}
	return
}

// Row partitioning changes no arithmetic, so parallel results must equal the
// serial reference exactly, at sizes straddling the parallel threshold and
// with ragged final chunks.
@(test)
test_cpu_parallel_membership_equals_serial :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	serial := cpu_strategy()
	for workers in ([]int{1, 2, 3, 8}) {
		p := cpu_parallel_strategy(workers)
		for n in ([]int{10, CPU_PARALLEL_MIN_PROBES - 1, CPU_PARALLEL_MIN_PROBES, CPU_PARALLEL_MIN_PROBES * 3 + 17}) {
			left, right := membership_inputs(n)
			for keep in ([]bool{true, false}) {
				want, _ := serial.membership_select(left, right, keep, context.temp_allocator)
				got, ok := p.membership_select(left, right, keep, context.temp_allocator)
				testing.expectf(t, ok, "workers %d n %d: declined", workers, n)
				if ok {
					testing.expectf(t, slice_eq(got, want), "workers %d n %d keep %v: differs", workers, n, keep)
				}
			}
		}
	}
}

@(test)
test_cpu_parallel_cosine_equals_serial :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	serial := cpu_strategy()
	dim := 67
	for workers in ([]int{1, 2, 5}) {
		p := cpu_parallel_strategy(workers)
		for shape in ([][2]int{{1, 7}, {3, 1001}, {2, CPU_PARALLEL_MIN_PAIRS + 13}}) {
			n_queries, n_docs := shape[0], shape[1]
			queries := make([]f32, n_queries * dim, context.temp_allocator)
			docs := make([]f32, n_docs * dim, context.temp_allocator)
			for i in 0 ..< len(queries) {
				queries[i] = f32((i * 37) % 23) / 11.0 - 1.0
			}
			for i in 0 ..< len(docs) {
				docs[i] = f32((i * 53) % 29) / 14.0 - 1.0
			}
			want, _ := serial.cosine_queries(queries, docs, n_queries, n_docs, dim, context.temp_allocator)
			got, ok := p.cosine_queries(queries, docs, n_queries, n_docs, dim, context.temp_allocator)
			testing.expectf(t, ok, "workers %d shape %v: declined", workers, shape)
			if !ok {
				continue
			}
			mismatches := 0
			for i in 0 ..< len(want) {
				if got[i] != want[i] {
					mismatches += 1
				}
			}
			testing.expectf(t, mismatches == 0, "workers %d shape %v: %d mismatches", workers, shape, mismatches)
		}
	}
}

@(test)
test_cpu_parallel_rejects_unsorted_like_serial :: proc(t: ^testing.T) {
	left := make([]u64, CPU_PARALLEL_MIN_PROBES, context.temp_allocator)
	_, ok := cpu_parallel_strategy(4).membership_select(left, []u64{3, 1, 2}, true, context.temp_allocator)
	testing.expect(t, !ok)
	free_all(context.temp_allocator)
}

@(private = "file")
Concurrent_Call :: struct {
	left:  []u64,
	right: []u64,
	want:  []bool,
	bad:   ^int,
	done:  ^sync.Wait_Group,
}

// Several callers at once: one gets the parallel workers, the rest run
// serially on their own threads; every result must still be exact.
@(test)
test_cpu_parallel_concurrent_callers :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	n := CPU_PARALLEL_MIN_PROBES * 2
	left, right := membership_inputs(n)
	want, _ := cpu_strategy().membership_select(left, right, true, context.temp_allocator)
	bad := 0
	wg: sync.Wait_Group
	CALLERS :: 6
	threads: [CALLERS]^thread.Thread
	sync.wait_group_add(&wg, CALLERS)
	for i in 0 ..< CALLERS {
		threads[i] = thread.create_and_start_with_poly_data(
			Concurrent_Call{left = left, right = right, want = want, bad = &bad, done = &wg},
			proc(call: Concurrent_Call) {
				defer sync.wait_group_done(call.done)
				for _ in 0 ..< 5 {
					got, ok := cpu_parallel_strategy(4).membership_select(call.left, call.right, true, context.allocator)
					if !ok || !slice_eq(got, call.want) {
						sync.atomic_add(call.bad, 1)
					}
					delete(got)
				}
			},
		)
	}
	sync.wait_group_wait(&wg)
	for th in threads {
		thread.join(th)
		thread.destroy(th)
	}
	testing.expect_value(t, bad, 0)
}
