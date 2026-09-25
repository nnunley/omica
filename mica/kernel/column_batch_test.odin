package kernel

import "core:slice"
import "core:testing"
import v "../var"

@(test)
test_column_batch_unit_has_one_unbound_row :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	b := column_batch_unit(3, context.temp_allocator)
	testing.expect_value(t, column_batch_live(&b), 1)
	testing.expect_value(t, column_batch_row(&b, 0), 0)
	for s in 0 ..< 3 {
		testing.expect(t, !b.bound[s])
	}
}

@(test)
test_column_batch_select_composes_and_gathers :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	b := column_batch_make(2, context.temp_allocator)
	b.count = 5
	column_batch_set(&b, 0, []v.Value{must_int(10), must_int(11), must_int(12), must_int(13), must_int(14)})
	testing.expect(t, b.bound[0] && b.fixed[0])
	testing.expect(t, !b.bound[1])

	column_batch_select(&b, []u32{1, 3, 4}, context.temp_allocator) // physical 1, 3, 4
	testing.expect_value(t, column_batch_live(&b), 3)
	column_batch_select(&b, []u32{0, 2}, context.temp_allocator) // live 0 and 2: physical 1, 4
	testing.expect(t, slice.equal(b.selection, []u32{1, 4}))
	testing.expect(t, slice.equal(column_batch_live_rows(&b, context.temp_allocator), []u32{1, 4}))
	live := column_batch_live_column(&b, 0, context.temp_allocator)
	testing.expect(t, slice.equal(live, []v.Value{must_int(11), must_int(14)}))
}

@(test)
test_column_all_fixed_rejects_heap_values :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	testing.expect(t, column_all_fixed([]v.Value{must_int(1), must_identity(2)}))
	testing.expect(t, !column_all_fixed([]v.Value{must_int(1), v.value_string(context.temp_allocator, "heap")}))
	testing.expect(t, column_all_fixed(nil))
}

@(test)
test_column_sink_transposes_rows :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	sink := column_sink_make(2, context.temp_allocator)
	column_sink_append_tuple(&sink, tuple_of(must_int(1), must_int(2)))
	testing.expect(t, column_sink_visit(&sink, tuple_of(must_int(3), v.value_string(context.temp_allocator, "x"))))
	b := column_sink_batch(&sink)
	testing.expect_value(t, b.count, 2)
	testing.expect(t, b.bound[0] && b.bound[1])
	testing.expect(t, b.fixed[0] && !b.fixed[1])
	testing.expect(t, slice.equal(b.columns[0], []v.Value{must_int(1), must_int(3)}))

	empty := column_sink_make(0, context.temp_allocator)
	column_sink_append_tuple(&empty, v.tuple_new(context.temp_allocator, nil))
	testing.expect_value(t, column_sink_batch(&empty).count, 1)
}

// Selecting no rows empties the batch; a nil selection must not read as "all
// rows live".
@(test)
test_column_batch_select_none_empties :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	b := column_batch_make(1, context.temp_allocator)
	b.count = 3
	column_batch_set(&b, 0, []v.Value{must_int(1), must_int(2), must_int(3)})
	column_batch_select(&b, nil, context.temp_allocator)
	testing.expect_value(t, column_batch_live(&b), 0)
	column_batch_select(&b, []u32{}, context.temp_allocator)
	testing.expect_value(t, column_batch_live(&b), 0)
}
