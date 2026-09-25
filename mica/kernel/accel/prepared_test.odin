package accel

import "core:testing"

@(private = "file")
sorted_column :: proc(n: int) -> []u64 {
	column := make([]u64, n, context.temp_allocator)
	for i in 0 ..< n {
		column[i] = u64(i) * 3 + 1
	}
	return column
}

@(private = "file")
probe_rows :: proc(n: int) -> []u64 {
	left := make([]u64, n, context.temp_allocator)
	for i in 0 ..< n {
		left[i] = (u64(i) * 2654435761) % u64(3 * n)
	}
	return left
}

@(test)
test_cpu_prepared_membership_matches_unprepared :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	c := cpu_strategy()
	column := sorted_column(500)
	left := probe_rows(700)
	prepared, ok := prepare_column(c, column)
	testing.expect(t, ok)
	if !ok {
		return
	}
	defer release_prepared(c, &prepared)
	for keep in ([]bool{true, false}) {
		want, _ := c.membership_select(left, column, keep, context.temp_allocator)
		got, got_ok := membership_select_prepared(c, left, prepared, keep, context.temp_allocator)
		testing.expect(t, got_ok)
		if got_ok {
			testing.expect(t, slice_eq(got, want))
		}
	}
}

@(test)
test_prepare_column_rejects_unsorted :: proc(t: ^testing.T) {
	_, ok := prepare_column(cpu_strategy(), []u64{3, 1, 2})
	testing.expect(t, !ok)
}

@(test)
test_prepared_column_survives_caller_buffer :: proc(t: ^testing.T) {
	// A prepared column owns its data: reusing the caller's buffer afterwards
	// must not change results.
	c := cpu_strategy()
	column := []u64{2, 4, 6}
	buffer := make([]u64, len(column))
	copy(buffer, column)
	prepared, ok := prepare_column(c, buffer)
	testing.expect(t, ok)
	if !ok {
		delete(buffer)
		return
	}
	defer release_prepared(c, &prepared)
	for &value in buffer {
		value = 99
	}
	delete(buffer)
	got, got_ok := membership_select_prepared(c, []u64{4, 99}, prepared, true, context.temp_allocator)
	testing.expect(t, got_ok)
	if got_ok {
		testing.expect(t, slice_eq(got, []bool{true, false}))
	}
	free_all(context.temp_allocator)
}

@(test)
test_cpu_prepared_cosine_matches_unprepared :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	c := cpu_strategy()
	n_queries, n_docs, dim := 3, 40, 9
	queries := make([]f32, n_queries * dim, context.temp_allocator)
	docs := make([]f32, n_docs * dim, context.temp_allocator)
	for i in 0 ..< len(queries) {
		queries[i] = f32((i * 7) % 11) / 5.0 - 1.0
	}
	for i in 0 ..< len(docs) {
		docs[i] = f32((i * 5) % 13) / 6.0 - 1.0
	}
	prepared, ok := prepare_docs(c, docs, n_docs, dim)
	testing.expect(t, ok)
	if !ok {
		return
	}
	defer release_prepared(c, &prepared)
	want, _ := c.cosine_queries(queries, docs, n_queries, n_docs, dim, context.temp_allocator)
	got, got_ok := cosine_queries_prepared(c, queries, n_queries, prepared, context.temp_allocator)
	testing.expect(t, got_ok)
	if got_ok {
		testing.expect_value(t, len(got), len(want))
		for i in 0 ..< min(len(got), len(want)) {
			testing.expect_value(t, got[i], want[i])
		}
	}
}

@(test)
test_prepared_kind_and_owner_must_match :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	c := cpu_strategy()
	column, column_ok := prepare_column(c, []u64{1, 2, 3})
	docs, docs_ok := prepare_docs(c, []f32{1, 0, 0, 1}, 2, 2)
	testing.expect(t, column_ok && docs_ok)
	defer release_prepared(c, &column)
	defer release_prepared(c, &docs)
	// A column used as documents, and documents used as a column, decline.
	_, as_docs := cosine_queries_prepared(c, []f32{1, 0}, 1, column, context.temp_allocator)
	testing.expect(t, !as_docs)
	_, as_column := membership_select_prepared(c, []u64{1}, docs, true, context.temp_allocator)
	testing.expect(t, !as_column)
	// A handle from one strategy declines under another.
	other := c
	other.name = "other"
	_, cross := membership_select_prepared(other, []u64{1}, column, true, context.temp_allocator)
	testing.expect(t, !cross)
}

@(test)
test_strategy_without_residency_declines :: proc(t: ^testing.T) {
	s := cpu_strategy()
	s.prepare_column = nil
	s.prepare_docs = nil
	_, column_ok := prepare_column(s, []u64{1, 2, 3})
	testing.expect(t, !column_ok)
	_, docs_ok := prepare_docs(s, []f32{1, 0}, 1, 2)
	testing.expect(t, !docs_ok)
}

@(test)
test_release_prepared_zero_value_is_noop :: proc(t: ^testing.T) {
	empty: Prepared
	release_prepared(cpu_strategy(), &empty)
	testing.expect(t, empty.handle == nil)
}
