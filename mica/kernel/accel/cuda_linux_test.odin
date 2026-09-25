// Linux CUDA agreement tests: same workloads through the CPU reference
// strategy and the CUDA strategy must produce identical results, on every
// visible device. Without a driver the CUDA side declines and only the
// decline behaviour is checked; set MICA_REQUIRE_CUDA=1 to fail instead, so a
// GPU box cannot pass by skipping.
#+build linux
package accel

import "core:log"
import "core:os"
import "core:sync"
import "core:testing"

@(private = "file")
require_cuda :: proc() -> bool {
	value, found := os.lookup_env("MICA_REQUIRE_CUDA", context.temp_allocator)
	return found && value == "1"
}

// CUDA operators decline Busy instead of waiting, and Odin runs tests on
// parallel threads, so tests that need an operator to complete take this
// lock to run one at a time.
@(private = "file")
cuda_tests_lock: sync.Mutex

// Available CUDA or a test failure when MICA_REQUIRE_CUDA=1.
@(private = "file")
cuda_or_skip :: proc(t: ^testing.T) -> bool {
	if cuda_strategy().available() {
		return true
	}
	testing.expect(t, !require_cuda(), "MICA_REQUIRE_CUDA=1 but CUDA is unavailable")
	return false
}

@(test)
test_cuda_probe_no_crash :: proc(t: ^testing.T) {
	_ = cuda_strategy().available()
	_ = cuda_device_count()
}

@(test)
test_cuda_unavailable_declines :: proc(t: ^testing.T) {
	if cuda_strategy().available() {
		return
	}
	testing.expect(t, !require_cuda(), "MICA_REQUIRE_CUDA=1 but CUDA is unavailable")
	c := cuda_strategy()
	left := make([]u64, CUDA_MEMBERSHIP_MIN_ROWS, context.temp_allocator)
	_, ok := c.membership_select(left, []u64{1}, true, context.temp_allocator)
	testing.expect(t, !ok)
}

@(test)
test_membership_small_declines_cuda :: proc(t: ^testing.T) {
	c := cuda_strategy()
	_, ok := c.membership_select([]u64{1, 2, 3}, []u64{2, 3, 4}, true, context.temp_allocator)
	testing.expect(t, !ok)
}

@(test)
test_cosine_small_declines_cuda :: proc(t: ^testing.T) {
	c := cuda_strategy()
	_, ok := c.cosine_query([]f32{1, 0}, []f32{1, 0, 0, 1}, 2, 2, context.temp_allocator)
	testing.expect(t, !ok)
}

@(test)
test_membership_unsorted_right_declines_cuda :: proc(t: ^testing.T) {
	sync.mutex_lock(&cuda_tests_lock)
	defer sync.mutex_unlock(&cuda_tests_lock)
	if !cuda_or_skip(t) {
		return
	}
	left := make([]u64, CUDA_MEMBERSHIP_MIN_ROWS, context.temp_allocator)
	_, ok := cuda_strategy().membership_select(left, []u64{3, 1, 2}, true, context.temp_allocator)
	testing.expect(t, !ok)
}

// Membership through CPU and CUDA on one device: identical flags for both
// keep_matches polarities, with hits, misses, and probes past either end.
@(private = "file")
membership_agrees :: proc(t: ^testing.T, device: int) {
	n := CUDA_MEMBERSHIP_MIN_ROWS * 4 + 7
	left := make([]u64, n, context.temp_allocator)
	for i in 0 ..< n {
		// Spread over [0, 3n) so about a third of probes hit, some beyond the
		// right column's range; include the top bit (identity tag byte).
		left[i] = (u64(i) * 2654435761) % u64(3 * n) | (u64(i & 1) << 63)
	}
	right := make([]u64, n, context.temp_allocator)
	for i in 0 ..< n {
		right[i] = u64(i) * 3 + 1
	}
	c := cpu_strategy()
	g := cuda_strategy()
	for keep in ([]bool{true, false}) {
		want, want_ok := c.membership_select(left, right, keep, context.temp_allocator)
		got, got_ok := g.membership_select(left, right, keep, context.temp_allocator)
		testing.expectf(t, want_ok && got_ok, "device %d keep=%v: cpu %v cuda %v (%v)", device, keep, want_ok, got_ok, last_decline_reason())
		if !want_ok || !got_ok {
			return
		}
		testing.expect_value(t, len(got), len(want))
		mismatches := 0
		for i in 0 ..< min(len(got), len(want)) {
			if got[i] != want[i] {
				mismatches += 1
			}
		}
		testing.expectf(t, mismatches == 0, "device %d keep=%v: %d mismatches", device, keep, mismatches)
	}
}

// Batched cosine through CPU and CUDA on one device, including a zero vector
// (score 0, not NaN) and a dim that is not a multiple of any warp width.
@(private = "file")
cosine_agrees :: proc(t: ^testing.T, device: int) {
	n_queries, n_docs, dim := 3, CUDA_COSINE_MIN_DOCS + 5, 67
	queries := make([]f32, n_queries * dim, context.temp_allocator)
	docs := make([]f32, n_docs * dim, context.temp_allocator)
	for i in 0 ..< len(queries) {
		queries[i] = f32((i * 37) % 23) / 11.0 - 1.0
	}
	for i in dim ..< len(docs) { // doc 0 stays the zero vector
		docs[i] = f32((i * 53) % 29) / 14.0 - 1.0
	}
	want, want_ok := cpu_strategy().cosine_queries(queries, docs, n_queries, n_docs, dim, context.temp_allocator)
	got, got_ok := cuda_strategy().cosine_queries(queries, docs, n_queries, n_docs, dim, context.temp_allocator)
	testing.expectf(t, want_ok && got_ok, "device %d: cpu %v cuda %v (%v)", device, want_ok, got_ok, last_decline_reason())
	if !want_ok || !got_ok {
		return
	}
	testing.expect_value(t, len(got), len(want))
	worst := f32(0)
	for i in 0 ..< min(len(got), len(want)) {
		worst = max(worst, abs(got[i] - want[i]))
	}
	testing.expectf(t, worst < 1e-3, "device %d: worst |cuda - cpu| = %v", device, worst)

	single, single_ok := cuda_strategy().cosine_query(queries[:dim], docs, n_docs, dim, context.temp_allocator)
	testing.expect(t, single_ok)
	if single_ok {
		for i in 0 ..< n_docs {
			testing.expectf(t, abs(single[i] - want[i]) < 1e-3, "device %d single-query doc %d", device, i)
		}
	}
}

@(test)
test_cuda_agrees_with_cpu_on_every_device :: proc(t: ^testing.T) {
	sync.mutex_lock(&cuda_tests_lock)
	defer sync.mutex_unlock(&cuda_tests_lock)
	if !cuda_or_skip(t) {
		return
	}
	count := cuda_device_count()
	testing.expect(t, count >= 1)
	defer cuda_select_device(0)
	// A device another process has filled (a resident model server) cannot
	// take a context; the backend declines it, so skip it here. At least one
	// device must work.
	usable := 0
	for device in 0 ..< count {
		if !cuda_select_device(device) {
			log.warnf("CUDA device %d unusable; skipped", device)
			continue
		}
		usable += 1
		membership_agrees(t, device)
		cosine_agrees(t, device)
	}
	testing.expect(t, usable >= 1, "no usable CUDA device")
	free_all(context.temp_allocator)
}

@(test)
test_cuda_select_device_out_of_range :: proc(t: ^testing.T) {
	testing.expect(t, !cuda_select_device(-1))
	testing.expect(t, !cuda_select_device(1 << 20))
}

// A prepared column and document matrix, reused across calls with different
// probes and queries, give the CPU reference's results on every usable device.
@(test)
test_cuda_prepared_agrees_with_cpu_on_every_device :: proc(t: ^testing.T) {
	sync.mutex_lock(&cuda_tests_lock)
	defer sync.mutex_unlock(&cuda_tests_lock)
	if !cuda_or_skip(t) {
		return
	}
	defer cuda_select_device(0)
	c := cpu_strategy()
	n := CUDA_MEMBERSHIP_MIN_ROWS * 2
	column := make([]u64, n, context.temp_allocator)
	for i in 0 ..< n {
		column[i] = u64(i) * 3 + 1
	}
	n_docs, dim := CUDA_COSINE_MIN_DOCS + 3, 33
	docs := make([]f32, n_docs * dim, context.temp_allocator)
	for i in 0 ..< len(docs) {
		docs[i] = f32((i * 53) % 29) / 14.0 - 1.0
	}
	for device in 0 ..< cuda_device_count() {
		if !cuda_select_device(device) {
			continue
		}
		g := cuda_strategy()
		prepared_column, column_ok := prepare_column(g, column)
		testing.expectf(t, column_ok, "device %d: prepare_column", device)
		prepared_docs, docs_ok := prepare_docs(g, docs, n_docs, dim)
		testing.expectf(t, docs_ok, "device %d: prepare_docs", device)
		for round in 0 ..< 3 {
			left := make([]u64, n + round * 1000, context.temp_allocator)
			for i in 0 ..< len(left) {
				left[i] = (u64(i + round) * 2654435761) % u64(3 * n)
			}
			for keep in ([]bool{true, false}) {
				want, _ := c.membership_select(left, column, keep, context.temp_allocator)
				got, got_ok := membership_select_prepared(g, left, prepared_column, keep, context.temp_allocator)
				testing.expectf(t, got_ok, "device %d round %d: prepared membership declined", device, round)
				if got_ok {
					testing.expectf(t, slice_eq(got, want), "device %d round %d keep=%v: flags differ", device, round, keep)
				}
			}
			n_queries := round + 1
			queries := make([]f32, n_queries * dim, context.temp_allocator)
			for i in 0 ..< len(queries) {
				queries[i] = f32((i * 37 + round) % 23) / 11.0 - 1.0
			}
			want, _ := c.cosine_queries(queries, docs, n_queries, n_docs, dim, context.temp_allocator)
			got, got_ok := cosine_queries_prepared(g, queries, n_queries, prepared_docs, context.temp_allocator)
			testing.expectf(t, got_ok, "device %d round %d: prepared cosine declined", device, round)
			if got_ok {
				worst := f32(0)
				for i in 0 ..< len(want) {
					worst = max(worst, abs(got[i] - want[i]))
				}
				testing.expectf(t, worst < 1e-3, "device %d round %d: worst |cuda - cpu| = %v", device, round, worst)
			}
		}
		release_prepared(g, &prepared_column)
		release_prepared(g, &prepared_docs)
		testing.expect(t, prepared_column.handle == nil && prepared_docs.handle == nil)
	}
	free_all(context.temp_allocator)
}

// Device memory belongs to one GPU: a handle prepared on one device declines
// while another is selected. Needs two usable devices.
@(test)
test_cuda_prepared_declines_on_other_device :: proc(t: ^testing.T) {
	sync.mutex_lock(&cuda_tests_lock)
	defer sync.mutex_unlock(&cuda_tests_lock)
	if !cuda_or_skip(t) {
		return
	}
	usable: [dynamic]int
	defer delete(usable)
	for device in 0 ..< cuda_device_count() {
		if cuda_select_device(device) {
			append(&usable, device)
		}
	}
	if len(usable) < 2 {
		log.warnf("only %d usable CUDA device(s); cross-device check skipped", len(usable))
		cuda_select_device(0)
		return
	}
	defer cuda_select_device(0)
	cuda_select_device(usable[0])
	g := cuda_strategy()
	column := make([]u64, CUDA_MEMBERSHIP_MIN_ROWS, context.temp_allocator)
	for i in 0 ..< len(column) {
		column[i] = u64(i)
	}
	prepared, ok := prepare_column(g, column)
	testing.expect(t, ok)
	cuda_select_device(usable[1])
	_, cross_ok := membership_select_prepared(g, column, prepared, true, context.temp_allocator)
	testing.expect(t, !cross_ok)
	cuda_select_device(usable[0])
	release_prepared(g, &prepared)
	free_all(context.temp_allocator)
}

@(test)
test_cuda_decline_reasons :: proc(t: ^testing.T) {
	sync.mutex_lock(&cuda_tests_lock)
	defer sync.mutex_unlock(&cuda_tests_lock)
	g := cuda_strategy()
	_, small_ok := g.membership_select([]u64{1, 2, 3}, []u64{2}, true, context.temp_allocator)
	testing.expect(t, !small_ok)
	testing.expect_value(t, last_decline_reason(), Decline.Below_Threshold)
	if !cuda_or_skip(t) {
		return
	}
	// A held backend lock makes the operator decline Busy instead of waiting.
	left := make([]u64, CUDA_MEMBERSHIP_MIN_ROWS, context.temp_allocator)
	sync.mutex_lock(&cuda_backend.mutex)
	_, busy_ok := g.membership_select(left, []u64{1}, true, context.temp_allocator)
	sync.mutex_unlock(&cuda_backend.mutex)
	testing.expect(t, !busy_ok)
	testing.expect_value(t, last_decline_reason(), Decline.Busy)
	free_all(context.temp_allocator)
}

@(test)
test_cuda_membership2_agrees_with_cpu :: proc(t: ^testing.T) {
	sync.mutex_lock(&cuda_tests_lock)
	defer sync.mutex_unlock(&cuda_tests_lock)
	if !cuda_or_skip(t) {
		return
	}
	n := CUDA_MEMBERSHIP_MIN_ROWS * 2 + 3
	right := make([]u64, 2 * n, context.temp_allocator)
	for i in 0 ..< n {
		// (i/4, (i%4) << 62): sorted lexicographically, top bit exercised.
		right[2 * i], right[2 * i + 1] = u64(i / 4), u64(i % 4) << 62
	}
	left := make([]u64, 2 * n, context.temp_allocator)
	for i in 0 ..< n {
		left[2 * i], left[2 * i + 1] = u64((i * 2654435761) % n) / 4, u64(i % 6) << 62
	}
	for keep in ([]bool{true, false}) {
		want, _ := membership_select_keys(cpu_strategy(), left, right, 2, keep, context.temp_allocator)
		got, ok := membership_select_keys(cuda_strategy(), left, right, 2, keep, context.temp_allocator)
		testing.expectf(t, ok, "keep=%v declined (%v)", keep, last_decline_reason())
		if ok {
			testing.expectf(t, slice_eq(got, want), "keep=%v differs", keep)
		}
	}
	free_all(context.temp_allocator)
}

// Uploads are reached from rule evaluation: a held backend lock makes a
// prepare decline Busy instead of waiting.
@(test)
test_cuda_prepare_declines_busy_instead_of_waiting :: proc(t: ^testing.T) {
	sync.mutex_lock(&cuda_tests_lock)
	defer sync.mutex_unlock(&cuda_tests_lock)
	if !cuda_or_skip(t) {
		return
	}
	column := make([]u64, CUDA_MEMBERSHIP_MIN_ROWS, context.temp_allocator)
	for i in 0 ..< len(column) {
		column[i] = u64(i)
	}
	sync.mutex_lock(&cuda_backend.mutex)
	_, ok := prepare_column(cuda_strategy(), column)
	sync.mutex_unlock(&cuda_backend.mutex)
	testing.expect(t, !ok)
	testing.expect_value(t, last_decline_reason(), Decline.Busy)
	free_all(context.temp_allocator)
}
