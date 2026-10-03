#+build darwin
package accel

import "core:slice"
import "core:sync"
import "core:testing"

// Metal offers two-key membership, resident key columns and resident document
// matrices, each agreeing with the CPU reference. Skipped without a device.
@(test)
test_metal_membership2_and_residency :: proc(t: ^testing.T) {
	sync.mutex_lock(&metal_tests_lock)
	defer sync.mutex_unlock(&metal_tests_lock)
	defer free_all(context.temp_allocator)
	m := metal_strategy()
	testing.expect(t, m.membership_select2 != nil)
	testing.expect(t, m.prepare_column != nil && m.membership_select_prepared != nil)
	testing.expect(t, m.prepare_docs != nil && m.cosine_queries_prepared != nil && m.release != nil)
	testing.expect(t, m.resident_min_probes > 0)
	if !m.available() {
		return
	}
	n := MEMBERSHIP2_MIN_ROWS + 7
	right := [][]u64{make([]u64, n, context.temp_allocator), make([]u64, n, context.temp_allocator)}
	left := [][]u64{make([]u64, n, context.temp_allocator), make([]u64, n, context.temp_allocator)}
	for i in 0 ..< n {
		right[0][i], right[1][i] = u64(i / 4), u64(i % 4) << 62
		left[0][i], left[1][i] = u64((i * 2654435761) % n) / 4, u64(i % 6) << 62
	}
	for keep in ([]bool{true, false}) {
		want, _ := membership_selection(cpu_strategy(), left, right, keep, context.temp_allocator)
		got, res := membership_selection(m, left, right, keep, context.temp_allocator)
		testing.expectf(t, res == .Completed && slice.equal(got, want), "two-key keep=%v: %v", keep, res)
	}

	testing.expect(t, MEMBERSHIP2_MIN_ROWS > MEMBERSHIP_MIN_ROWS)
	column := make([]u64, n, context.temp_allocator)
	for i in 0 ..< n {
		column[i] = u64(i * 3)
	}
	prepared, prepared_ok := prepare_column(m, column)
	testing.expect(t, prepared_ok)
	defer release_prepared(m, &prepared)
	probes := make([]u64, n, context.temp_allocator)
	for i in 0 ..< n {
		probes[i] = u64((i * 7919) % (3 * n))
	}
	want, _ := membership_selection(cpu_strategy(), [][]u64{probes}, [][]u64{column}, false, context.temp_allocator)
	got, res := membership_selection_prepared(m, probes, prepared, false, context.temp_allocator)
	testing.expectf(t, res == .Completed && slice.equal(got, want), "prepared column: %v", res)

	dim, n_docs, n_queries := 16, COSINE_MIN_DOCS + 5, 9
	docs := make([]f32, n_docs * dim, context.temp_allocator)
	queries := make([]f32, n_queries * dim, context.temp_allocator)
	for i in 0 ..< len(docs) {
		docs[i] = f32((i * 37) % 101) / 50 - 1
	}
	for i in 0 ..< len(queries) {
		queries[i] = f32((i * 53) % 97) / 48 - 1
	}
	direct, direct_ok := m.cosine_queries(queries, docs, n_queries, n_docs, dim, context.temp_allocator)
	testing.expect(t, direct_ok)
	docs_prepared, docs_ok := prepare_docs(m, docs, n_docs, dim)
	testing.expect(t, docs_ok)
	defer release_prepared(m, &docs_prepared)
	resident, resident_ok := cosine_queries_prepared(m, queries, n_queries, docs_prepared, context.temp_allocator)
	testing.expect(t, resident_ok)
	testing.expect(t, slice.equal(resident, direct))
}

// The tiled cosine kernel matches the CPU reference on shapes that are not
// multiples of its 16x16 tile, resident or not.
@(test)
test_metal_tiled_cosine_agrees :: proc(t: ^testing.T) {
	sync.mutex_lock(&metal_tests_lock)
	defer sync.mutex_unlock(&metal_tests_lock)
	defer free_all(context.temp_allocator)
	testing.expect(t, METAL_TILED_COSINE_MIN_QUERIES > 1)
	m := metal_strategy()
	if !m.available() {
		return
	}
	for shape in ([][3]int{{METAL_TILED_COSINE_MIN_QUERIES, COSINE_MIN_DOCS + 3, 37}, {33, COSINE_MIN_DOCS + 17, 16}, {70, 2 * COSINE_MIN_DOCS + 1, 131}}) {
		n_queries, n_docs, dim := shape[0], shape[1], shape[2]
		queries := make([]f32, n_queries * dim, context.temp_allocator)
		docs := make([]f32, n_docs * dim, context.temp_allocator)
		for i in 0 ..< len(queries) {
			queries[i] = f32((i * 53) % 97) / 48 - 1
		}
		for i in 0 ..< len(docs) {
			docs[i] = f32((i * 37) % 101) / 50 - 1
		}
		want, _ := cpu_strategy().cosine_queries(queries, docs, n_queries, n_docs, dim, context.temp_allocator)
		got, ok := m.cosine_queries(queries, docs, n_queries, n_docs, dim, context.temp_allocator)
		testing.expectf(t, ok, "shape %v declined (%v)", shape, last_decline_reason())
		worst := f32(0)
		for i in 0 ..< min(len(got), len(want)) {
			worst = max(worst, abs(got[i] - want[i]))
		}
		testing.expectf(t, len(got) == len(want) && worst < 1e-4, "shape %v: worst difference %v", shape, worst)
		testing.expectf(t, metal_last_cosine_tiled(), "shape %v: tiled kernel not used", shape)
	}
}
