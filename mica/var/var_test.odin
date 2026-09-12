package var

import "core:fmt"
import "core:mem/virtual"
import "core:strings"
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

	// Inexact integer division fails rather than widening.
	_, inexact_ok := value_checked_div(three, four)
	testing.expect(t, !inexact_ok)

	// Mixed kinds fail rather than widening.
	_, mixed_ok := value_checked_add(three, must_float(0.5))
	testing.expect(t, !mixed_ok)

	_, div_zero_ok := value_checked_div(three, must_int(0))
	testing.expect(t, !div_zero_ok)

	_, overflow_ok := value_checked_mul(must_int(INT_MAX), two)
	testing.expect(t, !overflow_ok)
}

@(test)
test_explicit_numeric_conversions :: proc(t: ^testing.T) {
	converted_float, float_ok := value_to_float(must_int(7))
	testing.expect(t, float_ok)
	f, f_ok := value_as_float(converted_float)
	testing.expect(t, f_ok)
	testing.expect_value(t, f, f32(7))

	converted_int, int_ok := value_to_int(must_float(7))
	testing.expect(t, int_ok)
	testing.expect(t, value_eq(converted_int, must_int(7)))

	// A fractional float does not convert.
	_, fractional_ok := value_to_int(must_float(7.5))
	testing.expect(t, !fractional_ok)

	// Non-numeric values do not convert.
	_, string_float_ok := value_to_float(value_string(context.temp_allocator, "7"))
	testing.expect(t, !string_float_ok)
	_, string_int_ok := value_to_int(value_string(context.temp_allocator, "7"))
	testing.expect(t, !string_int_ok)

	// A float outside the integer range does not convert.
	_, max_float_ok := value_to_int(must_float(3.4028235e38))
	testing.expect(t, !max_float_ok)
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
test_checked_sub_rem_neg :: proc(t: ^testing.T) {
	seven := must_int(7)
	three := must_int(3)

	difference, difference_ok := value_checked_sub(seven, three)
	testing.expect(t, difference_ok)
	testing.expect(t, value_eq(difference, must_int(4)))

	_, underflow_ok := value_checked_sub(must_int(INT_MIN), must_int(1))
	testing.expect(t, !underflow_ok)

	remainder, remainder_ok := value_checked_rem(seven, three)
	testing.expect(t, remainder_ok)
	testing.expect(t, value_eq(remainder, must_int(1)))

	neg_three, neg_three_ok := value_checked_neg(three)
	testing.expect(t, neg_three_ok)
	negative_remainder, negative_ok := value_checked_rem(seven, neg_three)
	testing.expect(t, negative_ok)
	testing.expect(t, value_eq(negative_remainder, must_int(1)))

	_, rem_zero_ok := value_checked_rem(seven, must_int(0))
	testing.expect(t, !rem_zero_ok)

	float_remainder, float_ok := value_checked_rem(must_float(5.5), must_float(2))
	testing.expect(t, float_ok)
	f, f_ok := value_as_float(float_remainder)
	testing.expect(t, f_ok)
	testing.expect_value(t, f, f32(1.5))

	negated, negated_ok := value_checked_neg(seven)
	testing.expect(t, negated_ok)
	testing.expect(t, value_eq(negated, must_int(-7)))

	_, neg_overflow_ok := value_checked_neg(must_int(INT_MIN))
	testing.expect(t, !neg_overflow_ok)

	negated_float, negated_float_ok := value_checked_neg(must_float(1.5))
	testing.expect(t, negated_float_ok)
	nf, nf_ok := value_as_float(negated_float)
	testing.expect(t, nf_ok)
	testing.expect_value(t, nf, f32(-1.5))
}

@(test)
test_float_overflow_rejected :: proc(t: ^testing.T) {
	_, add_ok := value_checked_add(must_float(3e38), must_float(3e38))
	testing.expect(t, !add_ok)

	_, mul_ok := value_checked_mul(must_float(1e30), must_float(1e30))
	testing.expect(t, !mul_ok)

	sum, sum_ok := value_checked_add(must_float(1.5), must_float(2.25))
	testing.expect(t, sum_ok)
	f, f_ok := value_as_float(sum)
	testing.expect(t, f_ok)
	testing.expect_value(t, f, f32(3.75))
}

@(test)
test_language_compare_int_float_bounds :: proc(t: ^testing.T) {
	// 2^55 is exactly representable as binary32. Every Mica integer is less
	// than it.
	upper_float := f32(36028797018963968.0)
	upper := must_float(upper_float)
	testing.expect(t, language_numeric_cmp(must_int(INT_MAX), upper) == .Less)
	testing.expect(t, language_numeric_cmp(upper, must_int(INT_MAX)) == .Greater)

	// -2^55 is exactly representable and is exactly INT_MIN.
	lower := must_float(-36028797018963968.0)
	testing.expect(t, language_numeric_cmp(must_int(INT_MIN), lower) == .Equal)
	testing.expect(t, language_numeric_eq(must_int(INT_MIN), lower))

	// The next representable float below 2^55 still exceeds INT_MAX. For a
	// positive normal float, the predecessor is the bit pattern minus one.
	below_upper_bits := transmute(u32)upper_float - 1
	below_upper := must_float(transmute(f32)below_upper_bits)
	testing.expect(t, language_numeric_cmp(must_int(INT_MAX), below_upper) == .Greater)

	// Negative fractions compare in the correct direction.
	testing.expect(t, language_numeric_cmp(must_int(-1), must_float(-1.5)) == .Greater)
	testing.expect(t, language_numeric_cmp(must_float(-1.5), must_int(-1)) == .Less)
	testing.expect(t, language_numeric_cmp(must_int(0), must_float(0.5)) == .Less)
	testing.expect(t, language_numeric_cmp(must_float(2.5), must_int(3)) == .Less)
}

@(test)
test_tuple_cmp_ordering :: proc(t: ^testing.T) {
	one_two := tuple_new(context.temp_allocator, []Value{must_int(1), must_int(2)})
	one_three := tuple_new(context.temp_allocator, []Value{must_int(1), must_int(3)})
	one := tuple_new(context.temp_allocator, []Value{must_int(1)})
	equivalent := tuple_new(context.temp_allocator, []Value{must_int(1), must_int(2)})

	testing.expect(t, tuple_cmp(one_two, one_three) == .Less)
	testing.expect(t, tuple_cmp(one_three, one_two) == .Greater)
	testing.expect(t, tuple_cmp(one, one_two) == .Less)
	testing.expect(t, tuple_cmp(one_two, equivalent) == .Equal)
	testing.expect(t, tuple_eq(one_two, equivalent))
}

@(test)
test_heap_ordering :: proc(t: ^testing.T) {
	alloc := context.temp_allocator

	// Byte strings order lexicographically.
	bytes_low := value_bytes(alloc, []u8{1})
	bytes_high := value_bytes(alloc, []u8{2})
	testing.expect(t, value_cmp(bytes_low, bytes_high) == .Less)

	// Maps order by entries, key first and then value.
	map_low := value_map(alloc, []Map_Entry{{key = must_int(1), value = must_int(1)}})
	map_high := value_map(alloc, []Map_Entry{{key = must_int(1), value = must_int(2)}})
	testing.expect(t, value_cmp(map_low, map_high) == .Less)
	testing.expect(t, value_cmp(map_high, map_low) == .Greater)

	// Error values order by code, then message option, then value option.
	code_low := symbol_intern("error-order-low")
	code_high := symbol_intern("error-order-high")
	error_low := value_error(alloc, code_low, "", false, Value(0), false)
	error_high := value_error(alloc, code_high, "", false, Value(0), false)
	testing.expect(t, value_cmp(error_low, error_high) == .Less)

	without_message := value_error(alloc, code_low, "", false, Value(0), false)
	with_message := value_error(alloc, code_low, "why", true, Value(0), false)
	testing.expect(t, value_cmp(without_message, with_message) == .Less)

	without_value := value_error(alloc, code_low, "why", true, Value(0), false)
	with_value := value_error(alloc, code_low, "why", true, must_int(1), true)
	testing.expect(t, value_cmp(without_value, with_value) == .Less)

	// Frob values order by delegate, then payload.
	delegate_low, _ := identity_new(1)
	delegate_high, _ := identity_new(2)
	frob_low := value_frob(alloc, delegate_low, must_int(1))
	frob_high := value_frob(alloc, delegate_high, must_int(1))
	testing.expect(t, value_cmp(frob_low, frob_high) == .Less)

	// Relation values order by heading column ids, then rows.
	heading_low := []Symbol{symbol_intern("order-column-low")}
	heading_high := []Symbol{symbol_intern("order-column-high")}
	row_one := tuple_new(alloc, []Value{must_int(1)})
	row_two := tuple_new(alloc, []Value{must_int(2)})
	relation_low, _ := value_relation(alloc, heading_low, []Tuple{row_one})
	relation_heading_high, _ := value_relation(alloc, heading_high, []Tuple{row_one})
	relation_row_high, _ := value_relation(alloc, heading_low, []Tuple{row_two})
	testing.expect(t, value_cmp(relation_low, relation_heading_high) == .Less)
	testing.expect(t, value_cmp(relation_low, relation_row_high) == .Less)
}

@(test)
test_value_is_persistable :: proc(t: ^testing.T) {
	alloc := context.temp_allocator

	testing.expect(t, value_is_persistable(must_int(1)))
	testing.expect(t, value_is_persistable(value_string(alloc, "text")))

	capability := value_capability(Capability_ID(1))
	function := value_function(Function_ID(1))
	testing.expect(t, !value_is_persistable(capability))
	testing.expect(t, !value_is_persistable(function))

	// Capabilities are storable in a live world even though they cannot be
	// persisted.
	testing.expect(t, value_is_storable(capability))
	testing.expect(t, !value_is_storable(function))

	good_list := value_list(alloc, []Value{must_int(1), value_string(alloc, "text")})
	bad_list := value_list(alloc, []Value{capability})
	testing.expect(t, value_is_persistable(good_list))
	testing.expect(t, !value_is_persistable(bad_list))

	good_map := value_map(alloc, []Map_Entry{{key = must_int(1), value = good_list}})
	bad_map := value_map(alloc, []Map_Entry{{key = must_int(1), value = capability}})
	testing.expect(t, value_is_persistable(good_map))
	testing.expect(t, !value_is_persistable(bad_map))

	good_range := value_range(alloc, must_int(0), must_int(10), true)
	bad_range := value_range(alloc, must_int(0), capability, true)
	testing.expect(t, value_is_persistable(good_range))
	testing.expect(t, !value_is_persistable(bad_range))

	open_range := value_range(alloc, must_int(0), Value(0), false)
	testing.expect(t, value_is_persistable(open_range))

	good_error := value_error(alloc, symbol_intern("persist-error"), "", false, Value(0), false)
	bad_error := value_error(alloc, symbol_intern("persist-error"), "", false, capability, true)
	testing.expect(t, value_is_persistable(good_error))
	testing.expect(t, !value_is_persistable(bad_error))

	good_frob := value_frob(alloc, Identity(1), must_int(1))
	bad_frob := value_frob(alloc, Identity(1), capability)
	testing.expect(t, value_is_persistable(good_frob))
	testing.expect(t, !value_is_persistable(bad_frob))

	heading := []Symbol{symbol_intern("persist-column")}
	good_relation, _ := value_relation(alloc, heading, []Tuple{tuple_new(alloc, []Value{must_int(1)})})
	bad_relation, _ := value_relation(alloc, heading, []Tuple{tuple_new(alloc, []Value{capability})})
	testing.expect(t, value_is_persistable(good_relation))
	testing.expect(t, !value_is_persistable(bad_relation))
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

@(test)
test_capability_and_function_ids :: proc(t: ^testing.T) {
	_, zero_capability_ok := capability_id_new(0)
	testing.expect(t, !zero_capability_ok)

	capability, capability_ok := capability_id_new(5)
	testing.expect(t, capability_ok)
	testing.expect_value(t, capability_id_raw(capability), u64(5))

	capability_value := value_capability(capability)
	testing.expect_value(t, value_kind(capability_value), Value_Kind.Capability)
	round_trip, round_trip_ok := value_as_capability(capability_value)
	testing.expect(t, round_trip_ok)
	testing.expect_value(t, capability_id_raw(round_trip), u64(5))

	_, raw_zero_ok := value_capability_raw(0)
	testing.expect(t, !raw_zero_ok)

	_, out_of_range_ok := capability_id_new(PAYLOAD_MASK + 1)
	testing.expect(t, !out_of_range_ok)

	function, function_ok := function_id_new(9)
	testing.expect(t, function_ok)
	function_value := value_function(function)
	round_function, round_function_ok := value_as_function(function_value)
	testing.expect(t, round_function_ok)
	testing.expect_value(t, function_id_raw(round_function), u64(9))

	_, function_range_ok := function_id_new(PAYLOAD_MASK + 1)
	testing.expect(t, !function_range_ok)

	identity, identity_ok := identity_new(IDENTITY_MAX + 1)
	testing.expect(t, !identity_ok)
	_ = identity
}

@(test)
test_bytes_range_error_frob_round_trip :: proc(t: ^testing.T) {
	alloc := context.temp_allocator

	bytes := value_bytes(alloc, []u8{1, 2, 3})
	got_bytes, bytes_ok := value_as_bytes(bytes)
	testing.expect(t, bytes_ok)
	testing.expect_value(t, len(got_bytes), 3)
	testing.expect_value(t, got_bytes[2], u8(3))

	range_value := value_range(alloc, must_int(1), must_int(9), true)
	start, end, has_end, range_ok := value_as_range(range_value)
	testing.expect(t, range_ok && has_end)
	testing.expect_value(t, start, must_int(1))
	testing.expect_value(t, end, must_int(9))

	open := value_range(alloc, must_int(1), Value(0), false)
	_, _, open_has_end, open_ok := value_as_range(open)
	testing.expect(t, open_ok && !open_has_end)

	error_value := value_error(
		alloc,
		symbol_intern("round-trip-error"),
		"why",
		true,
		must_int(4),
		true,
	)
	error, error_ok := value_as_error(error_value)
	testing.expect(t, error_ok)
	testing.expect_value(t, error.message, "why")
	code, code_ok := value_error_code_symbol(error_value)
	testing.expect(t, code_ok)
	testing.expect_value(t, code, symbol_intern("round-trip-error"))

	frob := value_frob(alloc, Identity(7), must_int(4))
	delegate, delegate_ok := value_frob_delegate(frob)
	testing.expect(t, delegate_ok)
	testing.expect_value(t, delegate, Identity(7))
	inner, inner_ok := value_frob_value(frob)
	testing.expect(t, inner_ok)
	testing.expect_value(t, inner, must_int(4))

	// A value is not every kind it is not.
	testing.expect(t, value_kind(bytes) == .Bytes)
	_, wrong_kind_ok := value_as_string(bytes)
	testing.expect(t, !wrong_kind_ok)
	_, immediate_missing := value_as_error(must_int(1))
	testing.expect(t, !immediate_missing)
}

@(test)
test_display_all_kinds :: proc(t: ^testing.T) {
	alloc := context.temp_allocator

	testing.expect_value(t, value_to_string(value_bool(true), alloc), "true")
	testing.expect_value(t, value_to_string(must_float(1.5), alloc), "1.5")
	testing.expect_value(t, value_to_string(value_empty_relation(), alloc), "[] {}")

	unit_row := tuple_new(alloc, []Value{})
	unit, _ := value_relation(alloc, []Symbol{}, []Tuple{unit_row})
	testing.expect_value(t, value_to_string(unit, alloc), "()")

	testing.expect_value(t, value_to_string(value_bytes(alloc, []u8{1, 2, 3}), alloc), "b\"AQID\"")
	testing.expect_value(t, value_to_string(value_capability(Capability_ID(1)), alloc), "<cap>")
	testing.expect_value(t, value_to_string(value_function(Function_ID(1)), alloc), "<function>")
	testing.expect_value(t, value_to_string(value_error_code(symbol_intern("E_TEST")), alloc), "E_TEST")
	testing.expect_value(t, value_to_string(value_symbol(symbol_from_id(999_999)), alloc), ":#999999")

	map_text := value_to_string(
		value_map(alloc, []Map_Entry{{key = must_int(1), value = value_string(alloc, "a")}}),
		alloc,
	)
	testing.expect_value(t, map_text, "[1: a]")

	testing.expect_value(
		t,
		value_to_string(value_range(alloc, must_int(1), must_int(9), true), alloc),
		"1..9",
	)
	testing.expect_value(
		t,
		value_to_string(value_range(alloc, must_int(1), Value(0), false), alloc),
		"1.._",
	)

	error_text := value_to_string(
		value_error(alloc, symbol_intern("E_TEST"), "msg", true, Value(0), false),
		alloc,
	)
	testing.expect_value(t, error_text, "error(E_TEST, \"msg\")")
	error_with_value := value_to_string(
		value_error(alloc, symbol_intern("E_TEST"), "", false, must_int(3), true),
		alloc,
	)
	testing.expect_value(t, error_with_value, "error(E_TEST, none, 3)")

	frob_text := value_to_string(value_frob(alloc, Identity(7), must_int(4)), alloc)
	testing.expect_value(t, frob_text, "#7<4>")

	heap_relation, _ := value_relation(
		alloc,
		[]Symbol{symbol_intern("display-column")},
		[]Tuple{tuple_new(alloc, []Value{must_int(1)}), tuple_new(alloc, []Value{must_int(2)})},
	)
	testing.expect_value(t, value_to_string(heap_relation, alloc), "<relation 2x1>")
}

// Deeply nested values must not recurse without bound; display elides past a
// depth limit instead of overflowing the stack.
@(test)
test_display_depth_limit :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	alloc := context.temp_allocator

	value := must_int(1)
	for _ in 0 ..< 100 {
		value = value_list(alloc, []Value{value})
	}
	text := value_to_string(value, alloc)
	testing.expectf(t, strings.contains(text, "..."), "deep value was not elided: %s", text)

	debug := value_to_debug_string(value, alloc)
	testing.expectf(t, strings.contains(debug, "..."), "deep debug value was not elided: %s", debug)
}

@(test)
test_value_float_from_bits :: proc(t: ^testing.T) {
	valid, valid_ok := value_float_from_bits(transmute(u32)f32(1.5))
	testing.expect(t, valid_ok)
	round_trip, round_trip_ok := value_as_float(valid)
	testing.expect(t, round_trip_ok)
	testing.expect_value(t, round_trip, f32(1.5))

	negative_zero, negative_zero_ok := value_float_from_bits(0x8000_0000)
	testing.expect(t, negative_zero_ok)
	positive_zero, _ := value_float_from_bits(0)
	testing.expect(t, value_eq(negative_zero, positive_zero))

	_, nan_ok := value_float_from_bits(0x7fc0_0000)
	testing.expect(t, !nan_ok)
	_, inf_ok := value_float_from_bits(0x7f80_0000)
	testing.expect(t, !inf_ok)
	_, negative_inf_ok := value_float_from_bits(0xff80_0000)
	testing.expect(t, !negative_inf_ok)
}

@(test)
test_value_is_immediate :: proc(t: ^testing.T) {
	alloc := context.temp_allocator

	relation_value, _ := value_relation(
		alloc,
		[]Symbol{symbol_intern("immediate-column")},
		[]Tuple{tuple_new(alloc, []Value{must_int(1)})},
	)

	immediates := []Value {
		value_bool(true),
		must_int(1),
		must_float(1.0),
		value_identity(Identity(1)),
		sym("immediate-symbol"),
		value_error_code(symbol_intern("E_IMMEDIATE")),
		value_capability(Capability_ID(1)),
		value_function(Function_ID(1)),
		value_empty_relation(),
	}
	for value in immediates {
		testing.expect(t, value_is_immediate(value))
	}

	heap_values := []Value {
		value_string(alloc, "text"),
		value_bytes(alloc, []u8{1}),
		value_list(alloc, []Value{must_int(1)}),
		value_map(alloc, []Map_Entry{{key = must_int(1), value = must_int(2)}}),
		value_range(alloc, must_int(0), must_int(1), true),
		value_error(alloc, symbol_intern("E_IMMEDIATE"), "", false, Value(0), false),
		value_frob(alloc, Identity(1), must_int(1)),
		relation_value,
	}
	for value in heap_values {
		testing.expect(t, !value_is_immediate(value))
	}
}

@(test)
test_division_edges :: proc(t: ^testing.T) {
	three := must_int(3)
	two := must_int(2)

	exact_negative, exact_negative_ok := value_checked_div(must_int(-6), three)
	testing.expect(t, exact_negative_ok)
	testing.expect(t, value_eq(exact_negative, must_int(-2)))

	// Inexact negative integer division fails rather than widening.
	_, inexact_negative_ok := value_checked_div(must_int(-7), two)
	testing.expect(t, !inexact_negative_ok)

	_, float_zero_ok := value_checked_div(must_float(1.0), must_float(0.0))
	testing.expect(t, !float_zero_ok)

	// Mixed kinds fail rather than widening.
	_, float_by_int_ok := value_checked_div(must_float(3.0), two)
	testing.expect(t, !float_by_int_ok)

	_, int_by_float_ok := value_checked_div(three, must_float(2.0))
	testing.expect(t, !int_by_float_ok)

	// Explicit conversion restores float division.
	converted, converted_ok := value_to_float(three)
	testing.expect(t, converted_ok)
	float_by_float, float_by_float_ok := value_checked_div(converted, must_float(2.0))
	testing.expect(t, float_by_float_ok)
	float_by_float_value, _ := value_as_float(float_by_float)
	testing.expect_value(t, float_by_float_value, f32(1.5))

	// INT_MIN / -1 leaves the 56-bit integer range.
	_, overflow_ok := value_checked_div(must_int(INT_MIN), must_int(-1))
	testing.expect(t, !overflow_ok)
}

@(test)
test_primitive_prototypes :: proc(t: ^testing.T) {
	alloc := context.temp_allocator

	relation_value, _ := value_relation(
		alloc,
		[]Symbol{symbol_intern("prototype-column")},
		[]Tuple{tuple_new(alloc, []Value{must_int(1)})},
	)

	values := []Value {
		value_bool(true),
		must_int(1),
		must_float(1.5),
		value_identity(Identity(1)),
		sym("prototype-symbol"),
		value_error_code(symbol_intern("E_PROTOTYPE")),
		value_string(alloc, "text"),
		value_bytes(alloc, []u8{1}),
		value_list(alloc, []Value{must_int(1)}),
		value_map(alloc, []Map_Entry{{key = must_int(1), value = must_int(2)}}),
		value_range(alloc, must_int(0), must_int(1), true),
		value_error(alloc, symbol_intern("E_PROTOTYPE"), "", false, Value(0), false),
		value_capability(Capability_ID(1)),
		value_frob(alloc, Identity(1), must_int(1)),
		value_function(Function_ID(1)),
		relation_value,
	}
	expected := []Identity {
		BOOL_PROTOTYPE,
		INTEGER_PROTOTYPE,
		FLOAT_PROTOTYPE,
		IDENTITY_PROTOTYPE,
		SYMBOL_PROTOTYPE,
		ERROR_CODE_PROTOTYPE,
		STRING_PROTOTYPE,
		BYTES_PROTOTYPE,
		LIST_PROTOTYPE,
		MAP_PROTOTYPE,
		RANGE_PROTOTYPE,
		ERROR_PROTOTYPE,
		CAPABILITY_PROTOTYPE,
		FROB_PROTOTYPE,
		FUNCTION_PROTOTYPE,
		RELATION_PROTOTYPE,
	}

	for value, i in values {
		testing.expect_value(t, primitive_prototype_for_value(value), expected[i])
		testing.expect_value(t, primitive_prototype_for_kind(value_kind(value)), expected[i])
	}

	testing.expect_value(
		t,
		primitive_prototype_for_value(value_empty_relation()),
		RELATION_PROTOTYPE,
	)
}

@(test)
test_symbol_edge_names :: proc(t: ^testing.T) {
	empty := symbol_intern("")
	empty_name, empty_ok := symbol_name(empty)
	testing.expect(t, empty_ok)
	testing.expect_value(t, empty_name, "")
	testing.expect_value(t, symbol_intern(""), empty)

	unicode_symbol := symbol_intern("λμδ")
	unicode_name, unicode_ok := symbol_name(unicode_symbol)
	testing.expect(t, unicode_ok)
	testing.expect_value(t, unicode_name, "λμδ")

	unknown := symbol_from_id(0xffff_fff0)
	_, unknown_ok := symbol_name(unknown)
	testing.expect(t, !unknown_ok)

	round_trip := symbol_from_id(symbol_id(symbol_intern("round-trip-symbol")))
	testing.expect_value(t, round_trip, symbol_intern("round-trip-symbol"))
}

@(test)
test_deep_copy_error_and_frob :: proc(t: ^testing.T) {
	source_arena := test_arena()
	defer test_arena_destroy(source_arena)
	dest_arena := test_arena()
	defer test_arena_destroy(dest_arena)
	source_alloc := virtual.arena_allocator(source_arena)
	dest_alloc := virtual.arena_allocator(dest_arena)

	message := strings.clone("why", source_alloc)
	error_source := value_error(
		source_alloc,
		symbol_intern("copy-error"),
		message,
		true,
		value_string(source_alloc, "payload"),
		true,
	)
	error_copy := value_deep_copy(dest_alloc, error_source)
	testing.expect(t, value_eq(error_source, error_copy))
	testing.expect(t, value_payload(error_source) != value_payload(error_copy))

	source_header, _ := value_as_error(error_source)
	copy_header, _ := value_as_error(error_copy)
	testing.expect(t, value_payload(source_header.value) != value_payload(copy_header.value))
	copied_text, _ := value_as_string(copy_header.value)
	testing.expect_value(t, copied_text, "payload")
	testing.expect(
		t,
		raw_data(transmute([]u8)source_header.message) !=
		raw_data(transmute([]u8)copy_header.message),
	)

	frob_source := value_frob(
		source_alloc,
		Identity(3),
		value_list(source_alloc, []Value{value_string(source_alloc, "inner")}),
	)
	frob_copy := value_deep_copy(dest_alloc, frob_source)
	testing.expect(t, value_eq(frob_source, frob_copy))

	source_frob, _ := value_as_frob(frob_source)
	copy_frob, _ := value_as_frob(frob_copy)
	testing.expect(t, value_payload(source_frob.value) != value_payload(copy_frob.value))
	source_list, _ := value_as_list(source_frob.value)
	copy_list, _ := value_as_list(copy_frob.value)
	testing.expect(t, value_payload(source_list[0]) != value_payload(copy_list[0]))
}

@(test)
test_map_and_relation_equality :: proc(t: ^testing.T) {
	alloc := context.temp_allocator

	map_a := value_map(alloc, []Map_Entry {
		{key = must_int(1), value = value_string(alloc, "a")},
		{key = must_int(2), value = value_string(alloc, "b")},
	})
	map_b := value_map(alloc, []Map_Entry {
		{key = must_int(2), value = value_string(alloc, "b")},
		{key = must_int(1), value = value_string(alloc, "a")},
	})
	testing.expect(t, value_eq(map_a, map_b))

	map_shorter := value_map(alloc, []Map_Entry {
		{key = must_int(1), value = value_string(alloc, "a")},
	})
	testing.expect(t, !value_eq(map_a, map_shorter))

	map_different_value := value_map(alloc, []Map_Entry {
		{key = must_int(1), value = value_string(alloc, "a")},
		{key = must_int(2), value = value_string(alloc, "z")},
	})
	testing.expect(t, !value_eq(map_a, map_different_value))

	column := symbol_intern("equality-column")
	row_one := tuple_new(alloc, []Value{must_int(1)})
	row_two := tuple_new(alloc, []Value{must_int(2)})
	relation_a, _ := value_relation(alloc, []Symbol{column}, []Tuple{row_one, row_two})
	relation_b, _ := value_relation(alloc, []Symbol{column}, []Tuple{row_two, row_one})
	testing.expect(t, value_eq(relation_a, relation_b))

	relation_shorter, _ := value_relation(alloc, []Symbol{column}, []Tuple{row_one})
	testing.expect(t, !value_eq(relation_a, relation_shorter))

	other_column := symbol_intern("equality-column-other")
	relation_other_heading, _ := value_relation(
		alloc,
		[]Symbol{other_column},
		[]Tuple{row_one, row_two},
	)
	testing.expect(t, !value_eq(relation_a, relation_other_heading))
}

@(test)
test_debug_nested_forms :: proc(t: ^testing.T) {
	alloc := context.temp_allocator

	list := value_list(alloc, []Value{value_string(alloc, "a"), must_int(1)})
	testing.expect_value(t, value_to_debug_string(list, alloc), "{\"a\", 1}")

	map_value := value_map(alloc, []Map_Entry {
		{key = must_int(1), value = value_string(alloc, "b")},
	})
	testing.expect_value(t, value_to_debug_string(map_value, alloc), "[1: \"b\"]")
}

@(test)
test_display_float_format :: proc(t: ^testing.T) {
	alloc := context.temp_allocator
	testing.expect_value(t, value_to_string(must_float(1.0), alloc), "1")
	testing.expect_value(t, value_to_string(must_float(1.5), alloc), "1.5")
	testing.expect_value(t, value_to_string(must_float(-2.25), alloc), "-2.25")
	testing.expect_value(t, value_to_string(must_float(0.1), alloc), "0.1")
}

@(test)
test_language_numeric_non_numeric_fallback :: proc(t: ^testing.T) {
	symbol_a := sym("fallback-a")
	symbol_b := sym("fallback-b")
	testing.expect(t, language_numeric_cmp(symbol_a, symbol_b) == .Less)
	testing.expect(t, language_numeric_cmp(symbol_b, symbol_a) == .Greater)
	testing.expect(t, language_numeric_cmp(symbol_a, symbol_a) == .Equal)
	testing.expect(t, language_numeric_eq(symbol_a, symbol_a))
	testing.expect(t, !language_numeric_eq(symbol_a, symbol_b))

	text := value_string(context.temp_allocator, "text")
	testing.expect(t, language_numeric_cmp(must_int(1), text) != .Equal)
}

@(test)
test_binding_helpers :: proc(t: ^testing.T) {
	bound := binding_of(must_int(1))
	bindings := []Binding{bound, bound, Binding{}}
	testing.expect_value(t, binding_leading_bound_count(bindings), 2)

	index, found := binding_first_unbound(bindings)
	testing.expect(t, found)
	testing.expect_value(t, index, 2)

	all_bound := []Binding{bound, bound}
	testing.expect_value(t, binding_leading_bound_count(all_bound), 2)
	_, unfound := binding_first_unbound(all_bound)
	testing.expect(t, !unfound)

	boolean := value_bool(false)
	as_bool, as_bool_ok := value_as_bool(boolean)
	testing.expect(t, as_bool_ok)
	testing.expect(t, !as_bool)
}

@(test)
test_symbol_cache_cycles_through_many_names :: proc(t: ^testing.T) {
	first := symbol_intern("cache-cycle-first")
	buffer: [32]u8
	for index in 0 ..< 64 {
		name := fmt.bprintf(buffer[:], "cache-cycle-%d", index)
		_ = symbol_intern(name)
	}

	// The name fell out of the thread-local cache but the table still owns it.
	again := symbol_intern("cache-cycle-first")
	testing.expect_value(t, again, first)

	name, name_ok := symbol_name(again)
	testing.expect(t, name_ok)
	testing.expect_value(t, name, "cache-cycle-first")

	// Repeated interning is stable across cache refills.
	for _ in 0 ..< 8 {
		testing.expect_value(t, symbol_intern("cache-cycle-first"), first)
	}
}
