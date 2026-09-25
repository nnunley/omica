package var

import "core:testing"

@(test)
test_tuple_hash_columns_matches_tuple_hash :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	alpha := value_string(context.temp_allocator, "alpha")
	alpha_again := value_string(context.temp_allocator, "alpha")
	beta := value_string(context.temp_allocator, "beta")
	one, _ := value_int(1)
	minus, _ := value_int(-7)
	half, _ := value_float(2.5)
	col0 := []Value{one, alpha, half, beta, minus}
	col1 := []Value{alpha_again, minus, one, half, beta}
	col2 := []Value{value_identity(Identity(9)), value_symbol(symbol_intern("s")), alpha, one, minus}
	columns := [][]Value{col0, col1, col2}

	out := make([]u64, 5, context.temp_allocator)
	tuple_hash_columns(columns, nil, out)
	for i in 0 ..< 5 {
		row := tuple_new(context.temp_allocator, []Value{col0[i], col1[i], col2[i]})
		testing.expect_value(t, out[i], tuple_hash(row))
	}

	picked := make([]u64, 2, context.temp_allocator)
	tuple_hash_columns(columns, []u32{4, 1}, picked)
	testing.expect_value(t, picked[0], out[4])
	testing.expect_value(t, picked[1], out[1])

	// Equal strings from distinct allocations hash equally.
	a := make([]u64, 1, context.temp_allocator)
	b := make([]u64, 1, context.temp_allocator)
	tuple_hash_columns([][]Value{[]Value{alpha}}, nil, a)
	tuple_hash_columns([][]Value{[]Value{alpha_again}}, nil, b)
	testing.expect_value(t, a[0], b[0])

	// Zero columns: the hash of the empty tuple.
	empty := make([]u64, 2, context.temp_allocator)
	tuple_hash_columns(nil, nil, empty)
	testing.expect_value(t, empty[0], tuple_hash(tuple_new(context.temp_allocator, nil)))
	testing.expect_value(t, empty[1], empty[0])
}
