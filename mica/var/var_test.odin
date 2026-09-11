package var

import "core:testing"

@(private)
sym :: proc(name: string) -> Value {
	return value_symbol(symbol_intern(name))
}

@(private)
must_int :: proc(n: i64) -> Value {
	value, ok := value_int(n)
	assert(ok)
	return value
}

@(private)
must_float :: proc(f: f32) -> Value {
	value, ok := value_float(f)
	assert(ok)
	return value
}

@(test)
test_int_range_and_sign_roundtrip :: proc(t: ^testing.T) {
	max_value, ok := value_int(INT_MAX)
	testing.expect(t, ok)
	got, got_ok := value_as_int(max_value)
	testing.expect(t, got_ok)
	testing.expect_value(t, got, INT_MAX)

	min_value, min_ok := value_int(INT_MIN)
	testing.expect(t, min_ok)
	got_min, _ := value_as_int(min_value)
	testing.expect_value(t, got_min, INT_MIN)

	_, overflow_ok := value_int(INT_MAX + 1)
	testing.expect(t, !overflow_ok)
	_, underflow_ok := value_int(INT_MIN - 1)
	testing.expect(t, !underflow_ok)
}

@(test)
test_float_rejects_non_finite_and_canonicalizes_zero :: proc(t: ^testing.T) {
	f := must_float(1.5)
	got, got_ok := value_as_float(f)
	testing.expect(t, got_ok)
	testing.expect_value(t, got, f32(1.5))

	_, nan_ok := value_float(transmute(f32)u32(0x7fc0_0000))
	testing.expect(t, !nan_ok)
	_, inf_ok := value_float(transmute(f32)u32(0x7f80_0000))
	testing.expect(t, !inf_ok)

	neg_zero := must_float(-0.0)
	pos_zero := must_float(0.0)
	testing.expect(t, value_eq(neg_zero, pos_zero))
}

@(test)
test_symbols_intern_stably :: proc(t: ^testing.T) {
	a := symbol_intern("mica-test-symbol")
	b := symbol_intern("mica-test-symbol")
	testing.expect_value(t, symbol_id(a), symbol_id(b))
	name, ok := symbol_name(a)
	testing.expect(t, ok)
	testing.expect_value(t, name, "mica-test-symbol")
}

@(test)
test_canonical_equality_separates_numeric_kinds :: proc(t: ^testing.T) {
	one := must_int(1)
	one_point_zero := must_float(1.0)

	testing.expect(t, !value_eq(one, one_point_zero))
	testing.expect(t, language_numeric_eq(one, one_point_zero))
	testing.expect(t, value_cmp(one, one_point_zero) != .Equal)
	testing.expect(t, language_numeric_cmp(one, one_point_zero) == .Equal)
}

@(test)
test_mixed_numeric_comparison_is_exact :: proc(t: ^testing.T) {
	big := must_int(1 << 54)
	higher := must_float(1.0)
	testing.expect(t, language_numeric_cmp(big, higher) == .Greater)

	one := must_int(1)
	one_and_half := must_float(1.5)
	testing.expect(t, language_numeric_cmp(one, one_and_half) == .Less)
	testing.expect(t, language_numeric_cmp(one_and_half, one) == .Greater)

	two := must_int(2)
	testing.expect(t, language_numeric_cmp(one_and_half, two) == .Less)
}

@(test)
test_checked_arithmetic :: proc(t: ^testing.T) {
	two := must_int(2)
	three := must_int(3)
	six := must_int(6)
	four := must_int(4)

	sum, ok := value_checked_add(two, three)
	testing.expect(t, ok)
	testing.expect(t, value_eq(sum, must_int(5)))

	exact, exact_ok := value_checked_div(six, three)
	testing.expect(t, exact_ok)
	testing.expect(t, value_eq(exact, two))

	inexact, inexact_ok := value_checked_div(three, four)
	testing.expect(t, inexact_ok)
	f, float_ok := value_as_float(inexact)
	testing.expect(t, float_ok)
	testing.expect_value(t, f, f32(0.75))

	_, div_zero_ok := value_checked_div(three, must_int(0))
	testing.expect(t, !div_zero_ok)

	_, overflow_ok := value_checked_mul(must_int(INT_MAX), two)
	testing.expect(t, !overflow_ok)
}

@(test)
test_tuple_operations :: proc(t: ^testing.T) {
	one := must_int(1)
	two := must_int(2)
	row := tuple_new(context.temp_allocator, []Value{one, two})
	testing.expect_value(t, tuple_arity(row), 2)

	selected := tuple_select(row, context.temp_allocator, []u16{1, 0})
	testing.expect_value(t, tuple_values(selected)[0], two)

	flag := value_bool(true)
	concatenated := tuple_concat(
		selected,
		tuple_from_slice([]Value{flag}),
		context.temp_allocator,
	)
	testing.expect_value(t, tuple_arity(concatenated), 3)

	bindings := []Binding{binding_of(two), Binding{}, binding_of(flag)}
	testing.expect(t, tuple_matches_bindings(concatenated, bindings))
	testing.expect(t, !tuple_matches_bindings(row, bindings))
}

@(test)
test_map_canonicalization_keeps_last_duplicate :: proc(t: ^testing.T) {
	one := must_int(1)
	two := must_int(2)
	string_a := value_string(context.temp_allocator, "a")
	string_b := value_string(context.temp_allocator, "b")

	m := value_map(
		context.temp_allocator,
		[]Map_Entry{{one, string_a}, {two, string_b}, {one, string_b}},
	)
	entries, ok := value_as_map(m)
	testing.expect(t, ok)
	testing.expect_value(t, len(entries), 2)
	testing.expect_value(t, entries[0].key, one)
	testing.expect(t, value_eq(entries[0].value, string_b))
}

@(test)
test_relation_canonicalizes_heading_rows_and_duplicates :: proc(t: ^testing.T) {
	a := symbol_intern("relation-test-column-a")
	b := symbol_intern("relation-test-column-b")

	four := must_int(4)
	three := must_int(3)
	two := must_int(2)
	one := must_int(1)

	row_43 := tuple_new(context.temp_allocator, []Value{four, three})
	row_21 := tuple_new(context.temp_allocator, []Value{two, one})
	relation_value, err := value_relation(
		context.temp_allocator,
		[]Symbol{b, a},
		[]Tuple{row_43, row_21, row_21},
	)
	testing.expect_value(t, err, Relation_Value_Error.None)

	relation, ok := value_as_relation(relation_value)
	testing.expect(t, ok)
	testing.expect_value(t, len(relation.heading), 2)
	testing.expect_value(t, relation.heading[0], a)
	testing.expect_value(t, len(relation.rows), 2)

	equivalent, equivalent_err := value_relation(
		context.temp_allocator,
		[]Symbol{a, b},
		[]Tuple{
			tuple_new(context.temp_allocator, []Value{one, two}),
			tuple_new(context.temp_allocator, []Value{three, four}),
		},
	)
	testing.expect_value(t, equivalent_err, Relation_Value_Error.None)
	testing.expect(t, value_eq(relation_value, equivalent))
}

@(test)
test_empty_and_unit_relations :: proc(t: ^testing.T) {
	empty_value, err := value_relation(context.temp_allocator, []Symbol{}, []Tuple{})
	testing.expect_value(t, err, Relation_Value_Error.None)
	testing.expect(t, value_is_empty_relation(empty_value))
	testing.expect_value(t, value_kind(empty_value), Value_Kind.Relation)

	unit_row := tuple_new(context.temp_allocator, []Value{})
	unit_value, unit_err := value_relation(context.temp_allocator, []Symbol{}, []Tuple{unit_row})
	testing.expect_value(t, unit_err, Relation_Value_Error.None)
	testing.expect(t, !value_is_empty_relation(unit_value))
	unit, unit_ok := value_as_relation(unit_value)
	testing.expect(t, unit_ok)
	testing.expect_value(t, len(unit.rows), 1)
}

@(test)
test_relation_rejects_duplicate_columns_and_arity_mismatch :: proc(t: ^testing.T) {
	column := symbol_intern("relation-test-column")
	_, duplicate_err := value_relation(context.temp_allocator, []Symbol{column, column}, []Tuple{})
	testing.expect_value(t, duplicate_err, Relation_Value_Error.Duplicate_Column)

	empty_row := tuple_new(context.temp_allocator, []Value{})
	_, arity_err := value_relation(context.temp_allocator, []Symbol{column}, []Tuple{empty_row})
	testing.expect_value(t, arity_err, Relation_Value_Error.Arity_Mismatch)
}

@(test)
test_display_formatting :: proc(t: ^testing.T) {
	identity, _ := identity_new(42)
	testing.expect_value(t, value_to_string(value_identity(identity), context.temp_allocator), "#42")
	testing.expect_value(t, value_to_string(sym("hello"), context.temp_allocator), ":hello")

	text := value_string(context.temp_allocator, "hi")
	testing.expect_value(t, value_to_string(text, context.temp_allocator), "hi")
	testing.expect_value(t, value_to_debug_string(text, context.temp_allocator), "\"hi\"")

	one := must_int(1)
	list := value_list(context.temp_allocator, []Value{one})
	testing.expect_value(t, value_to_string(list, context.temp_allocator), "{1}")
}
