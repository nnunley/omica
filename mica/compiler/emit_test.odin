package compiler

import "core:fmt"
import "core:mem"
import "core:mem/virtual"
import "core:strings"
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
		vm.vm_set_error(state, "E_ARITH", "double failed")
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
test_emit_retract_where_with_local :: proc(t: ^testing.T) {
	arena := emit_test_arena()
	defer emit_test_arena_destroy(arena)
	allocator := virtual.arena_allocator(arena)

	kernel: k.Kernel
	k.kernel_init(&kernel)
	defer k.kernel_destroy(&kernel)
	metadata := k.relation_metadata(k.Relation_ID(1), v.symbol_intern("Pair"), 2)
	snapshot, err := k.kernel_create_relation(&kernel, metadata)
	testing.expect_value(t, err, k.Kernel_Error.None)
	k.snapshot_release(snapshot)

	ctx := new_context()
	defer delete(ctx.builtins)
	defer delete(ctx.relations)
	defer delete(ctx.identities)
	ctx.relations["Pair"] = 1

	source := "verb drop(x)\n  retract Pair(x, _)\nend\nassert Pair(1, 2)\nassert Pair(3, 4)\ndrop(1)"
	program := compile_test_program(t, source, &ctx, allocator)
	tx := k.kernel_begin(&kernel)
	source_relation := k.Relation_Source{transaction = &tx, use_stored_derived = true}

	state: vm.VM
	vm.vm_init(&state, program, allocator)
	defer vm.vm_destroy(&state)
	vm.vm_set_workspace(&state, &source_relation, &tx)
	testing.expect_value(t, vm.vm_run(&state), vm.VM_Status.Halted)

	committed, commit_err := k.transaction_commit(&tx)
	testing.expect_value(t, commit_err, k.Kernel_Error.None)
	k.snapshot_release(committed)
	k.transaction_destroy(&tx)

	rows := make([dynamic]v.Tuple)
	k.kernel_scan_into(&kernel, k.Relation_ID(1), []v.Binding{{}, {}}, &rows)
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

	// A diverging right side (`return`) must not execute for a falsy left
	// side. Regression: the falsy path fell through into the return.
	diverge := "return false && return 1"
	program_diverge := compile_test_program(t, diverge, &ctx, allocator)
	state_diverge := run_test_program(t, program_diverge, allocator)
	defer vm.vm_destroy(&state_diverge)
	if one, is_int := v.value_as_int(state_diverge.result); is_int {
		testing.expectf(t, one != 1, "falsy && executed its return: %d", one)
	}

	// A truthy left side still runs the diverging right side.
	converge := "return true && return 1"
	program_converge := compile_test_program(t, converge, &ctx, allocator)
	state_converge := run_test_program(t, program_converge, allocator)
	defer vm.vm_destroy(&state_converge)
	expect_int_result(t, &state_converge, 1)
}

// Receiver calls carry the receiver in the u8 argument count, so more than
// 254 arguments would wrap it. They are rejected like over-long plain calls.
@(test)
test_emit_receiver_call_argument_limit :: proc(t: ^testing.T) {
	arena := emit_test_arena()
	defer emit_test_arena_destroy(arena)
	allocator := virtual.arena_allocator(arena)
	ctx := new_context()
	defer delete(ctx.builtins)
	defer delete(ctx.relations)
	defer delete(ctx.identities)

	build_call :: proc(arg_count: int, allocator: mem.Allocator) -> string {
		builder: strings.Builder
		strings.builder_init(&builder, allocator)
		defer strings.builder_destroy(&builder)
		strings.write_string(&builder, "let x = 1\nlet r = x:foo(")
		for index in 0 ..< arg_count {
			if index > 0 {
				strings.write_string(&builder, ", ")
			}
			strings.write_string(&builder, "1")
		}
		strings.write_string(&builder, ")")
		return strings.to_string(builder)
	}

	ok_ast, ok_parse := parse_program(build_call(254, allocator), allocator)
	testing.expect_value(t, len(ok_parse), 0)
	ok_compiled := compile_program(ok_ast, &ctx, allocator)
	testing.expect_value(t, len(ok_compiled.errors), 0)

	bad_ast, bad_parse := parse_program(build_call(255, allocator), allocator)
	testing.expect_value(t, len(bad_parse), 0)
	bad_compiled := compile_program(bad_ast, &ctx, allocator)
	testing.expect(t, len(bad_compiled.errors) > 0)
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

@(private)
constructor_case_index :: proc(heading: []v.Symbol) -> int {
	for column, index in heading {
		name, ok := v.symbol_name(column)
		if ok && name == "case" {
			return index
		}
	}
	return -1
}

@(private)
test_frob_builtin :: proc(state: ^vm.VM, args: []v.Value) -> (v.Value, bool) {
	delegate, is_identity := v.value_as_identity(args[0])
	if !is_identity {
		vm.vm_set_error(state, "E_TYPE", "frob delegate must be an identity")
		return v.Value(0), false
	}
	return v.value_frob(state.allocator, delegate, args[1]), true
}

@(private)
test_pair_lengths_builtin :: proc(state: ^vm.VM, args: []v.Value) -> (v.Value, bool) {
	left, left_ok := v.value_as_list(args[0])
	right, right_ok := v.value_as_list(args[1])
	if !left_ok || !right_ok {
		vm.vm_set_error(state, "E_TYPE", "pair_lengths expects lists")
		return v.Value(0), false
	}
	total, _ := v.value_int(i64(len(left) + len(right)))
	return total, true
}

@(test)
test_emit_frob_literal :: proc(t: ^testing.T) {
	arena := emit_test_arena()
	defer emit_test_arena_destroy(arena)
	allocator := virtual.arena_allocator(arena)
	ctx := new_context()
	defer delete(ctx.builtins)
	defer delete(ctx.relations)
	defer delete(ctx.identities)
	ctx.builtins["frob"] = true
	delegate, _ := v.value_identity_raw(0x42)
	ctx.identities["thing"] = delegate

	program := compile_test_program(t, "#thing<[1, 2]>", &ctx, allocator)
	state: vm.VM
	vm.vm_init(&state, program, allocator)
	defer vm.vm_destroy(&state)
	vm.vm_register_builtin(&state, v.symbol_intern("frob"), 2, test_frob_builtin)
	testing.expect_value(t, vm.vm_run(&state), vm.VM_Status.Halted)

	got_delegate, delegate_ok := v.value_frob_delegate(state.result)
	testing.expect(t, delegate_ok)
	testing.expect_value(t, v.identity_raw(got_delegate), u64(0x42))

	payload, payload_ok := v.value_frob_value(state.result)
	testing.expect(t, payload_ok)
	values, list_ok := v.value_as_list(payload)
	testing.expect(t, list_ok)
	testing.expect_value(t, len(values), 2)
}

@(test)
test_emit_standard_constructors :: proc(t: ^testing.T) {
	arena := emit_test_arena()
	defer emit_test_arena_destroy(arena)
	allocator := virtual.arena_allocator(arena)
	ctx := new_context()
	defer delete(ctx.builtins)
	defer delete(ctx.relations)
	defer delete(ctx.identities)

	none_program := compile_test_program(t, "none", &ctx, allocator)
	none_state := run_test_program(t, none_program, allocator)
	defer vm.vm_destroy(&none_state)
	none_relation, none_ok := v.value_as_relation(none_state.result)
	testing.expect(t, none_ok)
	testing.expect_value(t, len(none_relation.heading), 1)
	testing.expect_value(t, len(none_relation.rows), 0)

	some_program := compile_test_program(t, "some(7)", &ctx, allocator)
	some_state := run_test_program(t, some_program, allocator)
	defer vm.vm_destroy(&some_state)
	some_relation, some_ok := v.value_as_relation(some_state.result)
	testing.expect(t, some_ok)
	testing.expect_value(t, len(some_relation.heading), 1)
	testing.expect_value(t, len(some_relation.rows), 1)
	some_row := v.tuple_values(some_relation.rows[0])
	value, value_ok := v.value_as_int(some_row[0])
	testing.expect(t, value_ok)
	testing.expect_value(t, value, i64(7))

	ok_program := compile_test_program(t, "ok(7)", &ctx, allocator)
	ok_state := run_test_program(t, ok_program, allocator)
	defer vm.vm_destroy(&ok_state)
	ok_relation, ok_ok := v.value_as_relation(ok_state.result)
	testing.expect(t, ok_ok)
	testing.expect_value(t, len(ok_relation.heading), 2)
	testing.expect_value(t, len(ok_relation.rows), 1)
	ok_row := v.tuple_values(ok_relation.rows[0])
	ok_case := constructor_case_index(ok_relation.heading)
	testing.expect(t, ok_case >= 0)
	tag, tag_ok := v.value_as_symbol(ok_row[ok_case])
	testing.expect(t, tag_ok)
	tag_name, tag_name_ok := v.symbol_name(tag)
	testing.expect(t, tag_name_ok)
	testing.expect_value(t, tag_name, "ok")

	err_program := compile_test_program(t, "err(7)", &ctx, allocator)
	err_state := run_test_program(t, err_program, allocator)
	defer vm.vm_destroy(&err_state)
	err_relation, err_ok := v.value_as_relation(err_state.result)
	testing.expect(t, err_ok)
	testing.expect_value(t, len(err_relation.rows), 1)
	err_row := v.tuple_values(err_relation.rows[0])
	err_case := constructor_case_index(err_relation.heading)
	testing.expect(t, err_case >= 0)
	err_tag, err_tag_ok := v.value_as_symbol(err_row[err_case])
	testing.expect(t, err_tag_ok)
	err_name, err_name_ok := v.symbol_name(err_tag)
	testing.expect(t, err_name_ok)
	testing.expect_value(t, err_name, "error")
}

@(test)
test_emit_call_argument_marshalling :: proc(t: ^testing.T) {
	arena := emit_test_arena()
	defer emit_test_arena_destroy(arena)
	allocator := virtual.arena_allocator(arena)
	ctx := new_context()
	defer delete(ctx.builtins)
	defer delete(ctx.relations)
	defer delete(ctx.identities)
	ctx.builtins["pair_lengths"] = true

	program := compile_test_program(t, "pair_lengths([1, 2], [3, 4, 5])", &ctx, allocator)
	state: vm.VM
	vm.vm_init(&state, program, allocator)
	defer vm.vm_destroy(&state)
	vm.vm_register_builtin(&state, v.symbol_intern("pair_lengths"), 2, test_pair_lengths_builtin)
	testing.expect_value(t, vm.vm_run(&state), vm.VM_Status.Halted)
	expect_int_result(t, &state, 5)
}

@(test)
test_emit_two_name_for :: proc(t: ^testing.T) {
	arena := emit_test_arena()
	defer emit_test_arena_destroy(arena)
	allocator := virtual.arena_allocator(arena)
	ctx := new_context()
	defer delete(ctx.builtins)
	defer delete(ctx.relations)
	defer delete(ctx.identities)

	source := "let xs = [10, 20, 30]\nlet total = 0\nfor index, value in xs\n  total = total + index + value\nend\ntotal"
	program := compile_test_program(t, source, &ctx, allocator)
	state := run_test_program(t, program, allocator)
	defer vm.vm_destroy(&state)
	expect_int_result(t, &state, 63)
}

@(test)
test_emit_break_inside_while :: proc(t: ^testing.T) {
	arena := emit_test_arena()
	defer emit_test_arena_destroy(arena)
	allocator := virtual.arena_allocator(arena)
	ctx := new_context()
	defer delete(ctx.builtins)
	defer delete(ctx.relations)
	defer delete(ctx.identities)

	source := "let i = 0\nwhile i < 10\n  i = i + 1\n  if i == 3\n    break\n  end\nend\ni"
	program := compile_test_program(t, source, &ctx, allocator)
	state := run_test_program(t, program, allocator)
	defer vm.vm_destroy(&state)
	expect_int_result(t, &state, 3)
}

@(test)
test_emit_role_dispatch_spec :: proc(t: ^testing.T) {
	arena := emit_test_arena()
	defer emit_test_arena_destroy(arena)
	allocator := virtual.arena_allocator(arena)
	ctx := new_context()
	defer delete(ctx.builtins)
	defer delete(ctx.relations)
	defer delete(ctx.identities)
	ctx.dispatch_method_selector_relation = 0x7fff_ff01
	ctx.dispatch_param_relation = 0x7fff_ff02
	ctx.dispatch_delegates_relation = 0x7fff_ff03
	ctx.dispatch_method_program_relation = 0x7fff_ff04

	program := compile_test_program(t, ":take(actor: #1, item: #2)", &ctx, allocator)
	testing.expect_value(t, len(program.dispatch_specs), 1)
	if len(program.dispatch_specs) == 1 {
		spec := program.dispatch_specs[0]
		name, name_ok := v.symbol_name(spec.selector)
		testing.expect(t, name_ok)
		testing.expect_value(t, name, "take")
		testing.expect_value(t, len(spec.roles), 2)
	}
}

@(test)
test_emit_spawn_spec :: proc(t: ^testing.T) {
	arena := emit_test_arena()
	defer emit_test_arena_destroy(arena)
	allocator := virtual.arena_allocator(arena)
	ctx := new_context()
	defer delete(ctx.builtins)
	defer delete(ctx.relations)
	defer delete(ctx.identities)

	program := compile_test_program(
		t,
		"spawn :take(actor: #1, item: #2) after 500",
		&ctx,
		allocator,
	)
	testing.expect_value(t, len(program.dispatch_specs), 1)
	if len(program.dispatch_specs) == 1 {
		spec := program.dispatch_specs[0]
		name, name_ok := v.symbol_name(spec.selector)
		testing.expect(t, name_ok)
		testing.expect_value(t, name, "take")
		testing.expect_value(t, len(spec.roles), 2)
	}

	spawns := 0
	for instruction in program.code {
		if instruction.op != .Spawn {
			continue
		}
		spawns += 1
		testing.expect_value(t, instruction.flags, u8(1))
	}
	testing.expect_value(t, spawns, 1)
}

@(test)
test_emit_raise :: proc(t: ^testing.T) {
	arena := emit_test_arena()
	defer emit_test_arena_destroy(arena)
	allocator := virtual.arena_allocator(arena)
	ctx := new_context()
	defer delete(ctx.builtins)
	defer delete(ctx.relations)
	defer delete(ctx.identities)

	program := compile_test_program(t, `raise E_RANGE, "out of range"`, &ctx, allocator)

	raises := 0
	for instruction in program.code {
		if instruction.op == .Raise {
			raises += 1
		}
	}
	testing.expect_value(t, raises, 1)
}

@(test)
test_emit_fn_literal :: proc(t: ^testing.T) {
	arena := emit_test_arena()
	defer emit_test_arena_destroy(arena)
	allocator := virtual.arena_allocator(arena)
	ctx := new_context()
	defer delete(ctx.builtins)
	defer delete(ctx.relations)
	defer delete(ctx.identities)

	program := compile_test_program(
		t,
		"let f = fn(x) => x\nf(1)",
		&ctx,
		allocator,
	)

	makes := 0
	calls := 0
	for instruction in program.code {
		if instruction.op == .Make_Function ||
		   instruction.op == .Make_Self_Function {
			makes += 1
		} else if instruction.op == .Call_Value {
			calls += 1
		}
	}
	testing.expect_value(t, makes, 1)
	testing.expect_value(t, calls, 1)
}

// Regression test for allocator ownership across the compiler -> VM builder
// boundary. `set_param_metadata` allocates `function.defaults` with the compile
// allocator, but `builder_destroy` frees them with whatever `context.allocator`
// is current. When the two differ, the free goes through the wrong allocator.
@(test)
test_compile_defaults_allocator_ownership :: proc(t: ^testing.T) {
	backing := context.allocator

	compile_track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&compile_track, backing)
	compile_track.bad_free_callback = mem.tracking_allocator_bad_free_callback_add_to_array
	defer mem.tracking_allocator_destroy(&compile_track)

	context_track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&context_track, backing)
	context_track.bad_free_callback = mem.tracking_allocator_bad_free_callback_add_to_array
	defer mem.tracking_allocator_destroy(&context_track)

	ctx := new_context()
	defer {
		delete(ctx.builtins)
		delete(ctx.relations)
		delete(ctx.identities)
	}

	source := `verb greet(?name = "world")
  return name
end
`
	compile_alloc := mem.tracking_allocator(&compile_track)
	ast, parse_errors := parse_program(source, compile_alloc)
	testing.expectf(t, len(parse_errors) == 0, "parse errors: %v", parse_errors)

	// Compile with a distinct ambient allocator so a free through
	// `context.allocator` shows up as a bad free rather than a clean free.
	previous := context.allocator
	context.allocator = mem.tracking_allocator(&context_track)
	compiled := compile_program(ast, &ctx, compile_alloc)
	context.allocator = previous

	testing.expectf(t, len(compiled.errors) == 0, "compile errors: %v", compiled.errors)
	testing.expectf(
		t,
		len(context_track.bad_free_array) == 0,
		"builder freed compiler-allocated memory through context.allocator: %v",
		context_track.bad_free_array,
	)
}

// On an invalid parameter list the function must be left untouched. The old
// code assigned required_count / has_rest / defaults before returning false.
@(test)
test_param_metadata_not_mutated_on_error :: proc(t: ^testing.T) {
	arena := emit_test_arena()
	defer emit_test_arena_destroy(arena)
	allocator := virtual.arena_allocator(arena)
	ctx := new_context()
	defer {
		delete(ctx.builtins)
		delete(ctx.relations)
		delete(ctx.identities)
	}

	source := `verb broken(?optional = 1, required)
  return required
end
`
	ast, parse_errors := parse_program(source, allocator)
	testing.expectf(t, len(parse_errors) == 0, "parse errors: %v", parse_errors)
	compiled := compile_program(ast, &ctx, allocator)
	testing.expectf(t, len(compiled.errors) > 0, "expected a compile error")

	name := v.symbol_intern("broken")
	found := false
	for function in compiled.program.functions {
		if function.name != name {
			continue
		}
		found = true
		testing.expect_value(t, function.required_count, 0)
		testing.expect(t, function.has_rest == false)
		testing.expect(t, function.defaults == nil)
	}
	testing.expect(t, found)
}

// A call with more than 255 arguments must be rejected rather than narrowing
// the count to a byte and losing arguments.
@(test)
test_call_arity_limit_is_diagnosed :: proc(t: ^testing.T) {
	arena := emit_test_arena()
	defer emit_test_arena_destroy(arena)
	allocator := virtual.arena_allocator(arena)
	ctx := new_context()
	defer {
		delete(ctx.builtins)
		delete(ctx.relations)
		delete(ctx.identities)
	}

	source_builder := strings.builder_make(allocator)
	defer strings.builder_destroy(&source_builder)
	strings.write_string(&source_builder, "probe(")
	for index in 0 ..< 256 {
		if index > 0 {
			strings.write_string(&source_builder, ", ")
		}
		fmt.sbprintf(&source_builder, "%d", index)
	}
	strings.write_string(&source_builder, ")")

	ast, parse_errors := parse_program(strings.to_string(source_builder), allocator)
	testing.expectf(t, len(parse_errors) == 0, "parse errors: %v", parse_errors)
	compiled := compile_program(ast, &ctx, allocator)
	testing.expectf(t, len(compiled.errors) > 0, "expected an arity diagnostic")
}

// A verb runs as a world method in its own task, so it has no access to the
// loading script's locals. Referencing one must be an "unknown name"
// diagnostic, not a move from a register that only exists in the entry frame.
@(test)
test_verb_cannot_read_entry_locals :: proc(t: ^testing.T) {
	arena := emit_test_arena()
	defer emit_test_arena_destroy(arena)
	allocator := virtual.arena_allocator(arena)
	ctx := new_context()
	defer delete(ctx.builtins)
	defer delete(ctx.relations)
	defer delete(ctx.identities)

	source := `let loaderValue = 7
verb probe()
  return loaderValue
end
`
	ast, parse_errors := parse_program(source, allocator)
	testing.expectf(t, len(parse_errors) == 0, "parse errors: %v", parse_errors)
	compiled := compile_program(ast, &ctx, allocator)
	testing.expectf(
		t,
		len(compiled.errors) > 0,
		"a verb reading an entry local should be an unknown name",
	)
	if len(compiled.errors) > 0 {
		testing.expectf(
			t,
			strings.contains(compiled.errors[0].message, "unknown name"),
			"expected an unknown name diagnostic, got %q",
			compiled.errors[0].message,
		)
	}
}

// The same name is valid inside the entry task, which owns it.
@(test)
test_entry_task_reads_its_own_locals :: proc(t: ^testing.T) {
	arena := emit_test_arena()
	defer emit_test_arena_destroy(arena)
	allocator := virtual.arena_allocator(arena)
	ctx := new_context()
	defer delete(ctx.builtins)
	defer delete(ctx.relations)
	defer delete(ctx.identities)

	program := compile_test_program(t, "let loaderValue = 7\nloaderValue + 1", &ctx, allocator)
	state := run_test_program(t, program, allocator)
	defer vm.vm_destroy(&state)
	expect_int_result(t, &state, 8)
}
