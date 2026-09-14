// Round-trip and corruption tests for the program artifact encoding.
package vm

import "core:mem/virtual"
import "core:testing"
import v "../var"

// Builds a program exercising every artifact section: several constant
// kinds, two functions (one with defaults), a pattern with every cell
// kind, a relation shape, a dispatch spec, builtins, and header ids.
@(private)
artifact_fixture :: proc(builder: ^Builder) {
	int_index := builder_add_constant(builder, must_int(7))
	float_index := builder_add_constant(builder, must_float(1.5))
	string_index := builder_add_constant(
		builder,
		v.value_string(builder.allocator, "seven"),
	)
	bool_index := builder_add_constant(builder, v.value_bool(true))
	symbol_index := builder_add_constant(
		builder,
		v.value_symbol(v.symbol_intern("seven")),
	)

	main := builder_begin_function(builder, v.symbol_intern("main"), 0, 4, true)
	builder_emit(builder, .Load_Const, 0, 0, i32(int_index), 0)
	builder_emit(builder, .Load_Const, 0, 1, i32(float_index), 0)
	builder_emit(builder, .Call, 0, 2, 1, 0)
	builder_emit(builder, .Return, 0, 2, 0, 0)
	builder_end_function(builder)

	helper := builder_begin_function(builder, v.symbol_intern("helper"), 2, 4, false)
	builder_emit(builder, .Load_Const, 0, 2, i32(string_index), 0)
	builder_emit(builder, .Load_Const, 0, 3, i32(bool_index), 0)
	builder_emit(builder, .Return, 0, 2, 0, 0)
	builder_end_function(builder)
	defaults := make([]i32, 1, builder.allocator)
	defaults[0] = i32(symbol_index)
	builder.functions[helper].defaults = defaults
	builder.functions[helper].required_count = 1
	builder.functions[helper].has_rest = true
	_ = main

	builder_add_pattern(
		builder,
		99,
		[]v.Symbol{v.symbol_intern("x"), v.symbol_intern("y")},
		[]Pattern_Cell{
			{kind = .Const, operand = i32(int_index)},
			{kind = .Bind, operand = 0},
			{kind = .Output, operand = 1},
			{kind = .Wildcard, operand = -1},
		},
	)
	builder_add_relation_shape(builder, []v.Symbol{v.symbol_intern("a"), v.symbol_intern("b")})
	builder_add_dispatch_spec(
		builder,
		v.symbol_intern("go"),
		[]Dispatch_Role{{role = v.symbol_intern("x"), register = 0}},
	)
	builder_add_builtin(builder, v.symbol_intern("len"))
	builder.dispatch_method_selector_relation = 11
	builder.dispatch_param_relation = 12
	builder.dispatch_delegates_relation = 13
	builder.dispatch_method_program_relation = 14
}

@(test)
test_artifact_round_trip :: proc(t: ^testing.T) {
	arena := test_arena()
	defer test_arena_destroy(arena)
	alloc := virtual.arena_allocator(arena)

	builder: Builder
	builder_init(&builder, alloc)
	defer builder_destroy(&builder)
	artifact_fixture(&builder)

	original := builder_build(&builder, alloc)
	testing.expect_value(t, program_validate(original), Program_Error.None)

	bytes: [dynamic]u8
	defer delete(bytes)
	testing.expect_value(t, program_to_bytes(original, &bytes), Artifact_Error.None)
	testing.expect(t, len(bytes) > len(ARTIFACT_MAGIC))

	decoded, decode_error := program_from_bytes(bytes[:], alloc)
	testing.expect_value(t, decode_error, Artifact_Error.None)
	if decoded == nil {
		return
	}
	testing.expect_value(t, program_validate(decoded), Program_Error.None)
	testing.expect_value(t, decoded.entry, original.entry)
	testing.expect_value(t, len(decoded.code), len(original.code))
	testing.expect_value(t, len(decoded.constants), len(original.constants))
	testing.expect_value(t, len(decoded.functions), len(original.functions))
	testing.expect_value(t, len(decoded.patterns), len(original.patterns))
	testing.expect_value(t, len(decoded.dispatch_specs), len(original.dispatch_specs))
	testing.expect_value(t, len(decoded.builtins), len(original.builtins))
	testing.expect_value(
		t,
		decoded.dispatch_method_program_relation,
		original.dispatch_method_program_relation,
	)
	if len(decoded.functions) == len(original.functions) {
		testing.expect_value(
			t,
			decoded.functions[1].required_count,
			original.functions[1].required_count,
		)
		testing.expect_value(
			t,
			decoded.functions[1].has_rest,
			original.functions[1].has_rest,
		)
		testing.expect_value(
			t,
			len(decoded.functions[1].defaults),
			len(original.functions[1].defaults),
		)
	}
	if first, ok := v.value_as_int(decoded.constants[0]); ok {
		testing.expect_value(t, first, i64(7))
	} else {
		testing.expect(t, false, "first constant did not decode as an int")
	}

	// Canonical framing: decoding and re-encoding is byte-identical, and
	// the fingerprint is stable over it but moves with the content.
	reencoded: [dynamic]u8
	defer delete(reencoded)
	testing.expect_value(t, program_to_bytes(decoded, &reencoded), Artifact_Error.None)
	testing.expect_value(t, len(reencoded), len(bytes))
	testing.expect(t, string(reencoded[:]) == string(bytes[:]))
	testing.expect_value(
		t,
		program_artifact_fingerprint(reencoded[:]),
		program_artifact_fingerprint(bytes[:]),
	)

	changed := builder_build(&builder, alloc)
	changed.constants[0] = must_int(8)
	changed_bytes: [dynamic]u8
	defer delete(changed_bytes)
	testing.expect_value(t, program_to_bytes(changed, &changed_bytes), Artifact_Error.None)
	testing.expect(
		t,
		program_artifact_fingerprint(changed_bytes[:]) != program_artifact_fingerprint(bytes[:]),
		"fingerprint did not move with changed content",
	)
}

@(test)
test_artifact_rejects_corrupt :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	arena := test_arena()
	defer test_arena_destroy(arena)
	alloc := virtual.arena_allocator(arena)

	builder: Builder
	builder_init(&builder, alloc)
	defer builder_destroy(&builder)
	artifact_fixture(&builder)
	program := builder_build(&builder, alloc)

	bytes: [dynamic]u8
	defer delete(bytes)
	testing.expect_value(t, program_to_bytes(program, &bytes), Artifact_Error.None)

	// First instruction op sits after magic(8) + version(4) + entry(8) +
	// header ids(16) + code count(4).
	OP_OFFSET :: 8 + 4 + 8 + 16 + 4
	// Code count prefix precedes it by four bytes.
	COUNT_OFFSET :: OP_OFFSET - 4

	cases := [?]struct {
		name:     string,
		mutate:   proc(original: []u8) -> []u8,
		expected: Artifact_Error,
	} {
		{"empty", proc(original: []u8) -> []u8 {return nil}, .Bad_Magic},
		{
			"bad magic",
			proc(original: []u8) -> []u8 {
				mutated := slice_clone(original)
				mutated[0] = 'X'
				return mutated
			},
			.Bad_Magic,
		},
		{
			"bad version",
			proc(original: []u8) -> []u8 {
				mutated := slice_clone(original)
				mutated[8] = 2
				return mutated
			},
			.Bad_Version,
		},
		{
			"bad op",
			proc(original: []u8) -> []u8 {
				mutated := slice_clone(original)
				mutated[OP_OFFSET] = 0xff
				return mutated
			},
			.Bad_Op,
		},
		{
			"bad count",
			proc(original: []u8) -> []u8 {
				mutated := slice_clone(original)
				mutated[COUNT_OFFSET] = 0xff
				return mutated
			},
			.Bad_Count,
		},
		{
			"truncated",
			proc(original: []u8) -> []u8 {
				return original[:10]
			},
			.Truncated,
		},
		{
			"truncated tail",
			proc(original: []u8) -> []u8 {
				return original[:len(original) - 1]
			},
			.Bad_Value,
		},
		{
			"trailing",
			proc(original: []u8) -> []u8 {
				mutated := make([]u8, len(original) + 1, context.temp_allocator)
				copy(mutated, original)
				mutated[len(original)] = 0
				return mutated
			},
			.Trailing_Bytes,
		},
	}

	for entry in cases {
		_, error := program_from_bytes(entry.mutate(bytes[:]), alloc)
		testing.expectf(t, error == entry.expected, "%s: got %v", entry.name, error)
	}
}

// Clones a byte slice into the temporary allocator.
@(private)
slice_clone :: proc(original: []u8) -> []u8 {
	mutated := make([]u8, len(original), context.temp_allocator)
	copy(mutated, original)
	return mutated
}

@(test)
test_artifact_rejects_non_persistable :: proc(t: ^testing.T) {
	arena := test_arena()
	defer test_arena_destroy(arena)
	alloc := virtual.arena_allocator(arena)

	builder: Builder
	builder_init(&builder, alloc)
	defer builder_destroy(&builder)
	artifact_fixture(&builder)
	capability, capability_ok := v.value_capability_raw(1)
	testing.expect(t, capability_ok)
	builder_add_constant(&builder, capability)
	program := builder_build(&builder, alloc)

	bytes: [dynamic]u8
	defer delete(bytes)
	testing.expect_value(
		t,
		program_to_bytes(program, &bytes),
		Artifact_Error.Not_Persistable,
	)
}
