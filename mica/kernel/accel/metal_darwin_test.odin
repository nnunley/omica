// Darwin-only Metal agreement tests: same workloads through the CPU
// reference strategy and the Metal strategy must produce identical results.
// Ryan's Vulkan/CUDA backends will add sibling test files against the same
// `Strategy` shape.
#+build darwin
package accel

import "core:mem"
import "core:testing"
import v "../../var"

@(test)
test_metal_probe_no_crash :: proc(t: ^testing.T) {
	// Availability depends on hardware; only require the probe not to crash.
	_ = metal_strategy().available()
}

@(test)
test_membership_small_declines_metal :: proc(t: ^testing.T) {
	// Below MEMBERSHIP_MIN_ROWS the Metal operator must decline.
	m := metal_strategy()
	_, ok := m.membership_select([]u64{1, 2, 3}, []u64{2, 3, 4}, true, context.temp_allocator)
	testing.expect(t, !ok)
}

@(test)
test_cosine_small_declines_metal :: proc(t: ^testing.T) {
	m := metal_strategy()
	_, ok := m.cosine_query([]f32{1, 0}, []f32{1, 0, 0, 1}, 2, 2, context.temp_allocator)
	testing.expect(t, !ok)
}

// Runs the same workload through both strategies and requires identical
// results. Skipped when Metal is unavailable; the CPU side still runs.
strategy_agreement :: proc(
	t: ^testing.T,
	left: []u64,
	right: []u64,
	query: []f32,
	docs: []f32,
	n_docs: int,
	dim: int,
) {
	c := cpu_strategy()
	m := metal_strategy()
	if !m.available() {
		return
	}
	cpu_sel, cpu_ok := c.membership_select(left, right, true, context.temp_allocator)
	testing.expect(t, cpu_ok)
	if !cpu_ok {
		return
	}
	defer delete(cpu_sel, context.temp_allocator)
	gpu_sel, gpu_ok := m.membership_select(left, right, true, context.temp_allocator)
	testing.expect(t, gpu_ok)
	if !gpu_ok {
		return
	}
	defer delete(gpu_sel, context.temp_allocator)
	testing.expect(t, len(cpu_sel) == len(gpu_sel))
	for i in 0 ..< min(len(cpu_sel), len(gpu_sel)) {
		testing.expect_value(t, gpu_sel[i], cpu_sel[i])
	}

	cpu_scores, cpu_scores_ok := c.cosine_query(query, docs, n_docs, dim, context.temp_allocator)
	testing.expect(t, cpu_scores_ok)
	if !cpu_scores_ok {
		return
	}
	defer delete(cpu_scores, context.temp_allocator)
	gpu_scores, gpu_scores_ok := m.cosine_query(query, docs, n_docs, dim, context.temp_allocator)
	testing.expect(t, gpu_scores_ok)
	if !gpu_scores_ok {
		return
	}
	defer delete(gpu_scores, context.temp_allocator)
	testing.expect(t, len(cpu_scores) == len(gpu_scores))
	for i in 0 ..< min(len(cpu_scores), len(gpu_scores)) {
		diff := abs(cpu_scores[i] - gpu_scores[i])
		testing.expectf(t, diff < 1e-3, "score %d: cpu %v metal %v", i, cpu_scores[i], gpu_scores[i])
	}
}

@(test)
test_strategies_agree_large :: proc(t: ^testing.T) {
	n := 8192
	left := make([]u64, n, context.temp_allocator)
	right := make([]u64, n / 2, context.temp_allocator)
	for i in 0 ..< n {
		left[i] = u64(i)
	}
	for i in 0 ..< n / 2 {
		right[i] = u64(i * 2)
	}
	dim := 64
	docs_n := 2048
	query := make([]f32, dim, context.temp_allocator)
	docs := make([]f32, docs_n * dim, context.temp_allocator)
	for i in 0 ..< dim {
		query[i] = f32(i + 1) / f32(dim)
	}
	for i in 0 ..< docs_n * dim {
		docs[i] = f32((i % 37) + 1) / 37.0
	}
	strategy_agreement(t, left, right, query, docs, docs_n, dim)
}

@(test)
test_batch_cosine_agrees_across_strategies :: proc(t: ^testing.T) {
	m := metal_strategy()
	if !m.available() {
		return
	}
	dim := 32
	n_queries := 8
	n_docs := 2048
	queries := make([]f32, n_queries * dim, context.temp_allocator)
	docs := make([]f32, n_docs * dim, context.temp_allocator)
	for i in 0 ..< len(queries) {
		queries[i] = f32((i % 13) + 1) / 13.0
	}
	for i in 0 ..< len(docs) {
		docs[i] = f32((i % 37) + 1) / 37.0
	}
	c := cpu_strategy()
	gpu, gpu_ok := m.cosine_queries(
		queries,
		docs,
		n_queries,
		n_docs,
		dim,
		context.temp_allocator,
	)
	testing.expect(t, gpu_ok)
	if !gpu_ok {
		return
	}
	defer delete(gpu, context.temp_allocator)
	cpu, cpu_ok := c.cosine_queries(
		queries,
		docs,
		n_queries,
		n_docs,
		dim,
		context.temp_allocator,
	)
	testing.expect(t, cpu_ok)
	if !cpu_ok {
		return
	}
	defer delete(cpu, context.temp_allocator)
	testing.expect(t, len(gpu) == len(cpu))
	for i in 0 ..< min(len(gpu), len(cpu)) {
		diff := abs(gpu[i] - cpu[i])
		testing.expectf(t, diff < 1e-3, "score %d: metal %v cpu %v", i, gpu[i], cpu[i])
	}
}

@(test)
test_top_k_agrees_across_strategies :: proc(t: ^testing.T) {
	m := metal_strategy()
	if !m.available() {
		return
	}
	dim := 32
	n_docs := 2048
	query := make([]f32, dim, context.temp_allocator)
	cands := make([]Cosine_Candidate, n_docs, context.temp_allocator)
	for i in 0 ..< dim {
		query[i] = f32(i + 1) / f32(dim)
	}
	for i in 0 ..< n_docs {
		vec := make([]f32, dim, context.temp_allocator)
		for d in 0 ..< dim {
			vec[d] = f32(((i * dim + d) % 37) + 1) / 37.0
		}
		id, _ := v.identity_new(u64(1000 + i))
		cands[i] = Cosine_Candidate {
			subject = v.value_identity(id),
			vector  = vec,
		}
	}
	gpu_hits, gpu_ok := cosine_top_k(query, cands, 8, context.allocator, m)
	testing.expect(t, gpu_ok)
	if !gpu_ok {
		return
	}
	defer delete(gpu_hits, context.allocator)
	cpu_hits, cpu_ok := cosine_top_k(query, cands, 8, context.allocator, cpu_strategy())
	testing.expect(t, cpu_ok)
	if !cpu_ok {
		return
	}
	defer delete(cpu_hits, context.allocator)
	testing.expect(t, len(gpu_hits) == len(cpu_hits))
	for i in 0 ..< min(len(gpu_hits), len(cpu_hits)) {
		testing.expect_value(t, gpu_hits[i].subject, cpu_hits[i].subject)
		diff := abs(gpu_hits[i].score - cpu_hits[i].score)
		testing.expectf(
			t,
			diff < 1e-3,
			"hit %d: metal %v cpu %v",
			i,
			gpu_hits[i].score,
			cpu_hits[i].score,
		)
	}
}

// Metal operators run on scheduler workers, whose temp allocator is never
// reset: an operator must leave nothing behind in it.
@(test)
test_metal_membership_leaves_temp_allocator_clean :: proc(t: ^testing.T) {
	m := metal_strategy()
	if !m.available() { // also initializes the backend before tracking
		return
	}
	left := make([]u64, MEMBERSHIP_MIN_ROWS)
	defer delete(left)
	for i in 0 ..< len(left) {
		left[i] = u64(i)
	}
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer mem.tracking_allocator_destroy(&track)
	selected: []bool
	ok: bool
	{
		context.temp_allocator = mem.tracking_allocator(&track)
		selected, ok = m.membership_select(left, []u64{1, 2, 3}, true, context.allocator)
	}
	testing.expect(t, ok)
	delete(selected)
	testing.expectf(t, len(track.allocation_map) == 0, "%d temp allocation(s) left behind", len(track.allocation_map))
}
