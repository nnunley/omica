package compiler

import "core:mem"
import "core:mem/virtual"
import "core:testing"
import k "../kernel"
import vm "../vm"
import v "../var"

@(private)
emit_test_arena :: proc() -> ^virtual.Arena {
	arena := new(virtual.Arena)
	if err := virtual.arena_init_growing(arena); err != nil {
		panic("failed to initialize emit test arena")
	}
	return arena
}

@(private)
emit_test_arena_destroy :: proc(arena: ^virtual.Arena) {
	virtual.arena_destroy(arena)
	free(arena)
}

@(private)
new_context :: proc() -> Compile_Context {
	return Compile_Context {
		builtins   = make(map[string]bool),
		relations  = make(map[string]u32),
		identities = make(map[string]v.Value),
	}
}

@(private)
compile_test_program :: proc(
	t: ^testing.T,
	source: string,
	ctx: ^Compile_Context,
	allocator: mem.Allocator,
) -> ^vm.Program {
	ast, parse_errors := parse_program(source, allocator)
	testing.expectf(t, len(parse_errors) == 0, "parse errors for %q: %v", source, parse_errors)
	compiled := compile_program(ast, ctx, allocator)
	testing.expectf(
		t,
		len(compiled.errors) == 0,
		"compile errors for %q: %v",
		source,
		compiled.errors,
	)
	return compiled.program
}

@(private)
run_test_program :: proc(
	t: ^testing.T,
	program: ^vm.Program,
	allocator: mem.Allocator,
) -> vm.VM {
	state: vm.VM
	vm.vm_init(&state, program, allocator)
	status := vm.vm_run(&state)
	testing.expectf(t, status == .Halted, "vm finished with %v", status)
	return state
}

@(private)
expect_int_result :: proc(t: ^testing.T, state: ^vm.VM, expected: i64) {
	value, ok := v.value_as_int(state.result)
	testing.expect(t, ok)
	testing.expect_value(t, value, expected)
}

@(private)
double_builtin :: proc(state: ^vm.VM, args: []v.Value) -> (v.Value, bool) {
	two, _ := v.value_int(2)
	result, ok := v.value_checked_mul(args[0], two)
	if !ok {
		vm.vm_set_error(state, "E_ARITHMETIC", "double failed")
		return v.Value(0), false
	}
	return result, true
}

@(test)
test_emit_arithmetic_and_locals :: proc(t: ^testing.T) {
	arena := emit_test_arena()
	defer emit_test_arena_destroy(arena)
	allocator := virtual.arena_allocator(arena)
	ctx := new_context()
	defer delete(ctx.builtins)
	defer delete(ctx.relations)
	defer delete(ctx.identities)

	program := compile_test_program(t, "let x = 1 + 2 * 3\nlet y = x - 1\ny", &ctx, allocator)
	state := run_test_program(t, program, allocator)
	defer vm.vm_destroy(&state)
	expect_int_result(t, &state, 6)
}

@(test)
test_emit_if_value :: proc(t: ^testing.T) {
	arena := emit_test_arena()
	defer emit_test_arena_destroy(arena)
	allocator := virtual.arena_allocator(arena)
	ctx := new_context()
	defer delete(ctx.builtins)
	defer delete(ctx.relations)
	defer delete(ctx.identities)

	source := "if 1 < 2\n  10\nelse\n  20\nend"
	program := compile_test_program(t, source, &ctx, allocator)
	state := run_test_program(t, program, allocator)
	defer vm.vm_destroy(&state)
	expect_int_result(t, &state, 10)
}

@(test)
test_emit_while_loop :: proc(t: ^testing.T) {
	arena := emit_test_arena()
	defer emit_test_arena_destroy(arena)
	allocator := virtual.arena_allocator(arena)
	ctx := new_context()
	defer delete(ctx.builtins)
	defer delete(ctx.relations)
	defer delete(ctx.identities)

	source := "let i = 0\nlet sum = 0\nwhile i < 10\n  sum = sum + i\n  i = i + 1\nend\nsum"
	program := compile_test_program(t, source, &ctx, allocator)
	state := run_test_program(t, program, allocator)
	defer vm.vm_destroy(&state)
	expect_int_result(t, &state, 45)
}

@(test)
test_emit_for_over_list :: proc(t: ^testing.T) {
	arena := emit_test_arena()
	defer emit_test_arena_destroy(arena)
	allocator := virtual.arena_allocator(arena)
	ctx := new_context()
	defer delete(ctx.builtins)
	defer delete(ctx.relations)
	defer delete(ctx.identities)

	source := "let total = 0\nfor item in [1, 2, 3, 4]\n  total = total + item\nend\ntotal"
	program := compile_test_program(t, source, &ctx, allocator)
	state := run_test_program(t, program, allocator)
	defer vm.vm_destroy(&state)
	expect_int_result(t, &state, 10)
}

@(test)
test_emit_builtin_call :: proc(t: ^testing.T) {
	arena := emit_test_arena()
	defer emit_test_arena_destroy(arena)
	allocator := virtual.arena_allocator(arena)
	ctx := new_context()
	defer delete(ctx.builtins)
	defer delete(ctx.relations)
	defer delete(ctx.identities)
	ctx.builtins["double"] = true

	program := compile_test_program(t, "double(21)", &ctx, allocator)
	state: vm.VM
	vm.vm_init(&state, program, allocator)
	defer vm.vm_destroy(&state)
	vm.vm_register_builtin(&state, v.symbol_intern("double"), 1, double_builtin)
	testing.expect_value(t, vm.vm_run(&state), vm.VM_Status.Halted)
	expect_int_result(t, &state, 42)
}

@(test)
test_emit_verb_direct_call :: proc(t: ^testing.T) {
	arena := emit_test_arena()
	defer emit_test_arena_destroy(arena)
	allocator := virtual.arena_allocator(arena)
	ctx := new_context()
	defer delete(ctx.builtins)
	defer delete(ctx.relations)
	defer delete(ctx.identities)

	source := "verb twice(value)\n  return value * 2\nend\ntwice(21)"
	program := compile_test_program(t, source, &ctx, allocator)
	state := run_test_program(t, program, allocator)
	defer vm.vm_destroy(&state)
	expect_int_result(t, &state, 42)
}

@(test)
test_emit_list_index :: proc(t: ^testing.T) {
	arena := emit_test_arena()
	defer emit_test_arena_destroy(arena)
	allocator := virtual.arena_allocator(arena)
	ctx := new_context()
	defer delete(ctx.builtins)
	defer delete(ctx.relations)
	defer delete(ctx.identities)

	program := compile_test_program(t, "let items = [10, 20, 30]\nitems[1]", &ctx, allocator)
	state := run_test_program(t, program, allocator)
	defer vm.vm_destroy(&state)
	expect_int_result(t, &state, 20)
}

@(test)
test_emit_assert_relation :: proc(t: ^testing.T) {
	arena := emit_test_arena()
	defer emit_test_arena_destroy(arena)
	allocator := virtual.arena_allocator(arena)

	kernel: k.Kernel
	k.kernel_init(&kernel)
	defer k.kernel_destroy(&kernel)
	metadata := k.relation_metadata(k.Relation_ID(1), v.symbol_intern("Flag"), 1)
	snapshot, err := k.kernel_create_relation(&kernel, metadata)
	testing.expect_value(t, err, k.Kernel_Error.None)
	k.snapshot_release(snapshot)

	ctx := new_context()
	defer delete(ctx.builtins)
	defer delete(ctx.relations)
	defer delete(ctx.identities)
	ctx.relations["Flag"] = 1

	program := compile_test_program(t, "assert Flag(#1)", &ctx, allocator)
	source := k.Relation_Source{snapshot = kernel.current, use_stored_derived = true}
	tx := k.kernel_begin(&kernel)

	state: vm.VM
	vm.vm_init(&state, program, allocator)
	defer vm.vm_destroy(&state)
	vm.vm_set_workspace(&state, &source, &tx)
	testing.expect_value(t, vm.vm_run(&state), vm.VM_Status.Halted)

	committed, commit_err := k.transaction_commit(&tx)
	testing.expect_value(t, commit_err, k.Kernel_Error.None)
	k.snapshot_release(committed)
	k.transaction_destroy(&tx)

	rows := make([dynamic]v.Tuple)
	k.kernel_scan_into(&kernel, k.Relation_ID(1), []v.Binding{{}}, &rows)
	testing.expect_value(t, len(rows), 1)
	delete(rows)
}

@(test)
test_emit_short_circuit :: proc(t: ^testing.T) {
	arena := emit_test_arena()
	defer emit_test_arena_destroy(arena)
	allocator := virtual.arena_allocator(arena)
	ctx := new_context()
	defer delete(ctx.builtins)
	defer delete(ctx.relations)
	defer delete(ctx.identities)

	// `&&` gives false for a falsy left side and the right value otherwise.
	source := "let a = 1 < 0 && 5\nlet b = 0 < 1 && 5\nb"
	program := compile_test_program(t, source, &ctx, allocator)
	state := run_test_program(t, program, allocator)
	defer vm.vm_destroy(&state)
	expect_int_result(t, &state, 5)

	// `||` gives the right value for a falsy left side and true otherwise.
	source_or := "let a = 1 < 0 || 7\na"
	program_or := compile_test_program(t, source_or, &ctx, allocator)
	state_or := run_test_program(t, program_or, allocator)
	defer vm.vm_destroy(&state_or)
	expect_int_result(t, &state_or, 7)
}

@(test)
test_emit_map_pattern_over_variable :: proc(t: ^testing.T) {
	arena := emit_test_arena()
	defer emit_test_arena_destroy(arena)
	allocator := virtual.arena_allocator(arena)
	ctx := new_context()
	defer delete(ctx.builtins)
	defer delete(ctx.relations)
	defer delete(ctx.identities)

	source := "let delegates = {:delegate -> #1}\nlet exactly {delegate} = delegates\ndelegate"
	program := compile_test_program(t, source, &ctx, allocator)
	state := run_test_program(t, program, allocator)
	defer vm.vm_destroy(&state)

	identity, identity_ok := v.value_as_identity(state.result)
	testing.expect(t, identity_ok)
	testing.expect_value(t, v.identity_raw(identity), u64(1))
}
