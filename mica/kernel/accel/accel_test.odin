package accel

import "core:testing"
import v "../../var"

@(test)
test_cpu_strategy_available :: proc(t: ^testing.T) {
	testing.expect(t, cpu_strategy().available())
}

@(test)
test_is_sorted_unique :: proc(t: ^testing.T) {
	testing.expect(t, is_sorted_unique(nil))
	testing.expect(t, is_sorted_unique([]u64{1}))
	testing.expect(t, is_sorted_unique([]u64{1, 2, 3}))
	testing.expect(t, !is_sorted_unique([]u64{1, 1, 2}))
	testing.expect(t, !is_sorted_unique([]u64{3, 2, 1}))
}

@(test)
test_cpu_strategy_handles_small :: proc(t: ^testing.T) {
	c := cpu_strategy()
	selected, ok := c.membership_select([]u64{1, 2, 3}, []u64{2, 3, 4}, true, context.temp_allocator)
	testing.expect(t, ok)
	if ok {
		defer delete(selected, context.temp_allocator)
		testing.expect(t, slice_eq(selected, []bool{false, true, true}))
	}
	comp, comp_ok := c.membership_select([]u64{1, 2, 3}, []u64{2, 3, 4}, false, context.temp_allocator)
	testing.expect(t, comp_ok)
	if comp_ok {
		defer delete(comp, context.temp_allocator)
		testing.expect(t, slice_eq(comp, []bool{true, false, false}))
	}
	scores, scores_ok := c.cosine_query([]f32{1, 0}, []f32{1, 0, 0, 1}, 2, 2, context.temp_allocator)
	testing.expect(t, scores_ok)
	if scores_ok {
		defer delete(scores, context.temp_allocator)
		testing.expect(t, len(scores) == 2)
	}
}

@(test)
test_probe_helper_declines_non_identities :: proc(t: ^testing.T) {
	one, _ := v.value_int(1)
	_, ok := membership_probe_identities(
		[]v.Value{one},
		[]u64{1, 2, 3},
		true,
		context.temp_allocator,
		cpu_strategy(),
	)
	testing.expect(t, !ok)
}

@(test)
test_batch_cosine_matches_single_queries :: proc(t: ^testing.T) {
	c := cpu_strategy()
	dim := 8
	n_queries := 4
	n_docs := 16
	queries := make([]f32, n_queries * dim, context.temp_allocator)
	docs := make([]f32, n_docs * dim, context.temp_allocator)
	for i in 0 ..< len(queries) {
		queries[i] = f32((i % 13) + 1) / 13.0
	}
	for i in 0 ..< len(docs) {
		docs[i] = f32((i % 17) + 1) / 17.0
	}
	batched, batched_ok := c.cosine_queries(
		queries,
		docs,
		n_queries,
		n_docs,
		dim,
		context.temp_allocator,
	)
	testing.expect(t, batched_ok)
	if !batched_ok {
		return
	}
	defer delete(batched, context.temp_allocator)
	testing.expect(t, len(batched) == n_queries * n_docs)
	for q in 0 ..< n_queries {
		single, single_ok := c.cosine_query(
			queries[q * dim:(q + 1) * dim],
			docs,
			n_docs,
			dim,
			context.temp_allocator,
		)
		testing.expect(t, single_ok)
		if !single_ok {
			continue
		}
		defer delete(single, context.temp_allocator)
		for i in 0 ..< n_docs {
			diff := abs(batched[q * n_docs + i] - single[i])
			testing.expectf(
				t,
				diff < 1e-5,
				"q %d doc %d: batch %v single %v",
				q,
				i,
				batched[q * n_docs + i],
				single[i],
			)
		}
	}
}

// Element-wise equality; []bool is not directly comparable in Odin.
slice_eq :: proc(a, b: []bool) -> bool {
	if len(a) != len(b) {
		return false
	}
	for x, i in a {
		if x != b[i] {
			return false
		}
	}
	return true
}
