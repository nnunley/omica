package vm

import "core:mem"
import "core:mem/virtual"
import "core:strings"
import "core:testing"
import v "../var"

@(private)
test_arena :: proc() -> ^virtual.Arena {
	arena := new(virtual.Arena)
	if err := virtual.arena_init_growing(arena); err != nil {
		panic("failed to initialize vm test arena")
	}
	return arena
}

@(private)
test_arena_destroy :: proc(arena: ^virtual.Arena) {
	virtual.arena_destroy(arena)
	free(arena)
}

@(private)
must_int :: proc(n: i64) -> v.Value {
	value, ok := v.value_int(n)
	assert(ok)
	return value
}

@(private)
constant :: proc(builder: ^Builder, n: i64) -> i32 {
	return i32(builder_add_constant(builder, must_int(n)))
}

@(test)
test_vm_arithmetic_and_return :: proc(t: ^testing.T) {
	arena := test_arena()
	defer test_arena_destroy(arena)
	alloc := virtual.arena_allocator(arena)

	builder: Builder
	builder_init(&builder)
	defer builder_destroy(&builder)

	two := constant(&builder, 2)
	three := constant(&builder, 3)
	builder_begin_function(&builder, v.symbol_intern("main"), 0, 4, true)
	builder_emit(&builder, .Load_Const, 0, 0, two, 0)
	builder_emit(&builder, .Load_Const, 0, 1, three, 0)
	builder_emit(&builder, .Binary, u8(Bin_Op.Add), 2, 0, 1)
	builder_emit(&builder, .Return, 0, 2, 0, 0)
	builder_end_function(&builder)

	program := builder_build(&builder, alloc)
	testing.expect_value(t, program_validate(program), Program_Error.None)

	state: VM
	vm_init(&state, program, alloc)
	defer vm_destroy(&state)

	testing.expect_value(t, vm_run(&state), VM_Status.Halted)
	testing.expect_value(t, state.result, must_int(5))
}

@(test)
test_vm_branch_selects_value :: proc(t: ^testing.T) {
	arena := test_arena()
	defer test_arena_destroy(arena)
	alloc := virtual.arena_allocator(arena)

	builder: Builder
	builder_init(&builder)
	defer builder_destroy(&builder)

	one := constant(&builder, 1)
	two := constant(&builder, 2)
	ten := constant(&builder, 10)
	twenty := constant(&builder, 20)

	builder_begin_function(&builder, v.symbol_intern("main"), 0, 4, true)
	builder_emit(&builder, .Load_Const, 0, 0, one, 0)
	builder_emit(&builder, .Load_Const, 0, 1, two, 0)
	builder_emit(&builder, .Binary, u8(Bin_Op.Lt), 2, 0, 1)
	builder_emit(&builder, .Branch, 0, 2, 2, 0)
	builder_emit(&builder, .Load_Const, 0, 3, twenty, 0)
	builder_emit(&builder, .Return, 0, 3, 0, 0)
	builder_emit(&builder, .Load_Const, 0, 3, ten, 0)
	builder_emit(&builder, .Return, 0, 3, 0, 0)
	builder_end_function(&builder)

	program := builder_build(&builder, alloc)
	testing.expect_value(t, program_validate(program), Program_Error.None)

	state: VM
	vm_init(&state, program, alloc)
	defer vm_destroy(&state)

	testing.expect_value(t, vm_run(&state), VM_Status.Halted)
	testing.expect_value(t, state.result, must_int(10))
}

@(test)
test_vm_loop_sums_to_55 :: proc(t: ^testing.T) {
	arena := test_arena()
	defer test_arena_destroy(arena)
	alloc := virtual.arena_allocator(arena)

	builder: Builder
	builder_init(&builder)
	defer builder_destroy(&builder)

	zero := constant(&builder, 0)
	one := constant(&builder, 1)
	ten := constant(&builder, 10)

	builder_begin_function(&builder, v.symbol_intern("main"), 0, 6, true)
	builder_emit(&builder, .Load_Const, 0, 0, ten, 0) // limit
	builder_emit(&builder, .Load_Const, 0, 1, zero, 0) // i
	builder_emit(&builder, .Load_Const, 0, 2, zero, 0) // sum
	builder_emit(&builder, .Load_Const, 0, 3, one, 0) // step
	// Exit when i > limit.
	builder_emit(&builder, .Binary, u8(Bin_Op.Gt), 4, 1, 0)
	builder_emit(&builder, .Branch, 0, 4, 3, 0) // true -> return at 9
	builder_emit(&builder, .Binary, u8(Bin_Op.Add), 2, 2, 1)
	builder_emit(&builder, .Binary, u8(Bin_Op.Add), 1, 1, 3)
	builder_emit(&builder, .Jump, 0, 0, -5, 0) // back to 4
	builder_emit(&builder, .Return, 0, 2, 0, 0)
	builder_end_function(&builder)

	program := builder_build(&builder, alloc)
	testing.expect_value(t, program_validate(program), Program_Error.None)

	state: VM
	vm_init(&state, program, alloc)
	defer vm_destroy(&state)

	testing.expect_value(t, vm_run(&state), VM_Status.Halted)
	testing.expect_value(t, state.result, must_int(55))
}

@(test)
test_vm_function_call :: proc(t: ^testing.T) {
	arena := test_arena()
	defer test_arena_destroy(arena)
	alloc := virtual.arena_allocator(arena)

	builder: Builder
	builder_init(&builder)
	defer builder_destroy(&builder)

	two := constant(&builder, 2)
	twenty_one := constant(&builder, 21)

	double := builder_begin_function(&builder, v.symbol_intern("double"), 1, 2)
	builder_emit(&builder, .Load_Const, 0, 1, two, 0)
	builder_emit(&builder, .Binary, u8(Bin_Op.Mul), 1, 0, 1)
	builder_emit(&builder, .Return, 0, 1, 0, 0)
	builder_end_function(&builder)

	builder_begin_function(&builder, v.symbol_intern("main"), 0, 3, true)
	builder_emit(&builder, .Load_Const, 0, 0, twenty_one, 0)
	builder_emit(&builder, .Call, 0, 1, i32(double), 0)
	builder_emit(&builder, .Return, 0, 1, 0, 0)
	builder_end_function(&builder)

	program := builder_build(&builder, alloc)
	testing.expect_value(t, program_validate(program), Program_Error.None)

	state: VM
	vm_init(&state, program, alloc)
	defer vm_destroy(&state)

	testing.expect_value(t, vm_run(&state), VM_Status.Halted)
	testing.expect_value(t, state.result, must_int(42))
}

@(test)
test_vm_build_list_and_len :: proc(t: ^testing.T) {
	arena := test_arena()
	defer test_arena_destroy(arena)
	alloc := virtual.arena_allocator(arena)

	builder: Builder
	builder_init(&builder)
	defer builder_destroy(&builder)

	one := constant(&builder, 1)
	two := constant(&builder, 2)
	three := constant(&builder, 3)

	builder_begin_function(&builder, v.symbol_intern("main"), 0, 5, true)
	builder_emit(&builder, .Load_Const, 0, 0, one, 0)
	builder_emit(&builder, .Load_Const, 0, 1, two, 0)
	builder_emit(&builder, .Load_Const, 0, 2, three, 0)
	builder_emit(&builder, .Build_List, 0, 3, 0, 3)
	builder_emit(&builder, .Len, 0, 4, 3, 0)
	builder_emit(&builder, .Return, 0, 4, 0, 0)
	builder_end_function(&builder)

	program := builder_build(&builder, alloc)
	testing.expect_value(t, program_validate(program), Program_Error.None)

	state: VM
	vm_init(&state, program, alloc)
	defer vm_destroy(&state)

	testing.expect_value(t, vm_run(&state), VM_Status.Halted)
	testing.expect_value(t, state.result, must_int(3))

	// Build a list and inspect its cells through a second program run.
	builder2: Builder
	builder_init(&builder2)
	defer builder_destroy(&builder2)
	one2 := constant(&builder2, 1)
	two2 := constant(&builder2, 2)
	three2 := constant(&builder2, 3)
	builder_begin_function(&builder2, v.symbol_intern("main"), 0, 4, true)
	builder_emit(&builder2, .Load_Const, 0, 0, one2, 0)
	builder_emit(&builder2, .Load_Const, 0, 1, two2, 0)
	builder_emit(&builder2, .Load_Const, 0, 2, three2, 0)
	builder_emit(&builder2, .Build_List, 0, 3, 0, 3)
	builder_emit(&builder2, .Return, 0, 3, 0, 0)
	builder_end_function(&builder2)
	program2 := builder_build(&builder2, alloc)
	testing.expect_value(t, program_validate(program2), Program_Error.None)
	state2: VM
	vm_init(&state2, program2, alloc)
	defer vm_destroy(&state2)
	testing.expect_value(t, vm_run(&state2), VM_Status.Halted)
	values, values_ok := v.value_as_list(state2.result)
	testing.expect(t, values_ok)
	testing.expect_value(t, len(values), 3)
	testing.expect_value(t, values[0], must_int(1))
	testing.expect_value(t, values[2], must_int(3))
}

@(test)
test_vm_division_by_zero_fails :: proc(t: ^testing.T) {
	arena := test_arena()
	defer test_arena_destroy(arena)
	alloc := virtual.arena_allocator(arena)

	builder: Builder
	builder_init(&builder)
	defer builder_destroy(&builder)

	one := constant(&builder, 1)
	zero := constant(&builder, 0)

	builder_begin_function(&builder, v.symbol_intern("main"), 0, 3, true)
	builder_emit(&builder, .Load_Const, 0, 0, one, 0)
	builder_emit(&builder, .Load_Const, 0, 1, zero, 0)
	builder_emit(&builder, .Binary, u8(Bin_Op.Div), 2, 0, 1)
	builder_emit(&builder, .Return, 0, 2, 0, 0)
	builder_end_function(&builder)

	program := builder_build(&builder, alloc)
	testing.expect_value(t, program_validate(program), Program_Error.None)

	state: VM
	vm_init(&state, program, alloc)
	defer vm_destroy(&state)

	testing.expect_value(t, vm_run(&state), VM_Status.Failed)
	error, error_ok := v.value_as_error(state.error)
	testing.expect(t, error_ok)
	code_name, code_ok := v.symbol_name(error.code)
	testing.expect(t, code_ok)
	testing.expect_value(t, code_name, "E_ARITHMETIC")
}

@(test)
test_program_validation_rejects_bad_register :: proc(t: ^testing.T) {
	arena := test_arena()
	defer test_arena_destroy(arena)
	alloc := virtual.arena_allocator(arena)

	builder: Builder
	builder_init(&builder)
	defer builder_destroy(&builder)

	value := constant(&builder, 1)
	builder_begin_function(&builder, v.symbol_intern("main"), 0, 1, true)
	builder_emit(&builder, .Load_Const, 0, 5, value, 0)
	builder_emit(&builder, .Return, 0, 0, 0, 0)
	builder_end_function(&builder)

	program := builder_build(&builder, alloc)
	testing.expect_value(t, program_validate(program), Program_Error.Bad_Register)
}

@(test)
test_program_disassembly :: proc(t: ^testing.T) {
	arena := test_arena()
	defer test_arena_destroy(arena)
	alloc := virtual.arena_allocator(arena)

	builder: Builder
	builder_init(&builder)
	defer builder_destroy(&builder)

	value := constant(&builder, 7)
	builder_begin_function(&builder, v.symbol_intern("main"), 0, 2, true)
	builder_emit(&builder, .Load_Const, 0, 0, value, 0)
	builder_emit(&builder, .Return, 0, 0, 0, 0)
	builder_end_function(&builder)

	program := builder_build(&builder, alloc)
	text := program_disassemble(program, alloc)
	testing.expect(t, strings.contains(text, "function main"))
	testing.expect(t, strings.contains(text, "load_const"))
	testing.expect(t, strings.contains(text, "r0 c0"))
	testing.expect(t, strings.contains(text, "return"))
}
