// Lowering from the AST to `mica/vm` bytecode.
//
// This is a direct emitter rather than a separate HIR: expressions are lowered
// in one walk with a scope stack that tracks locals and register lifetimes.
// Each function gets a register window; locals keep their registers, and
// temporaries are reclaimed when a block scope ends.
package compiler

import "core:fmt"
import "core:mem"
import "core:strconv"
import "core:strings"
import vm "../vm"
import v "../var"

Compile_Error :: struct {
	message: string,
}

// What the emitter can resolve beyond locals: callable builtins and relation
// names for `assert` and `retract`.
Compile_Context :: struct {
	builtins:   map[string]bool,
	relations:  map[string]u32,
	identities: map[string]v.Value,
}

Compiled_Program :: struct {
	program: ^vm.Program,
	errors:  []Compile_Error,
}

@(private)
Local :: struct {
	name:     string,
	register: int,
	is_const: bool,
}

@(private)
Scope :: struct {
	register_mark: int,
	local_mark:    int,
}

@(private)
Emitter :: struct {
	builder:       ^vm.Builder,
	ctx:           ^Compile_Context,
	allocator:     mem.Allocator,
	errors:        [dynamic]Compile_Error,
	scopes:        [dynamic]Scope,
	locals:        [dynamic]Local,
	next_register: int,
	max_register:  int,
	functions:     map[string]int,
	break_patches: [dynamic]int,
	continue_targets: [dynamic]int,
	empty_constant: int,
}

// Compiles a parsed program into a VM program. `main` is the entry function;
// top-level expressions run in order and the last value is returned. Verbatim
// items become callable functions; rules are not lowered.
compile_program :: proc(
	ast: ^Program_AST,
	ctx: ^Compile_Context,
	allocator := context.allocator,
) -> Compiled_Program {
	builder: vm.Builder
	vm.builder_init(&builder)
	defer vm.builder_destroy(&builder)

	emitter := Emitter {
		builder   = &builder,
		ctx       = ctx,
		allocator = allocator,
		scopes    = make([dynamic]Scope),
		locals    = make([dynamic]Local),
		functions = make(map[string]int),
		break_patches = make([dynamic]int),
		continue_targets = make([dynamic]int),
	}
	defer {
		delete(emitter.scopes)
		delete(emitter.locals)
		delete(emitter.functions)
		delete(emitter.break_patches)
		delete(emitter.continue_targets)
	}

	// Assign verb function indices before emitting so calls can resolve.
	function_index := 1
	for item in ast.items {
		verb, is_verb := item.(Verb_Item)
		if is_verb {
			emitter.functions[verb.name] = function_index
			function_index += 1
		}
	}

	emitter.empty_constant = vm.builder_add_constant(&builder, v.value_empty_relation())

	// Entry function.
	main_index := vm.builder_begin_function(&builder, v.symbol_intern("main"), 0, 0, true)
	last_register := -1
	for item in ast.items {
		expr_item, is_expr := item.(Expr_Item)
		if !is_expr {
			continue
		}
		register, has_value := emit_expr(&emitter, expr_item.expr)
		if has_value {
			last_register = register
		}
	}
	return_register := last_register
	if return_register < 0 {
		return_register = emit_constant(&emitter, v.value_empty_relation())
	}
	vm.builder_emit(&builder, .Return, 0, i32(return_register), 0, 0)
	vm.builder_end_function(&builder)
	builder.functions[main_index].register_count = emitter.max_register

	// Verb bodies.
	for item in ast.items {
		verb, is_verb := item.(Verb_Item)
		if !is_verb {
			continue
		}
		index := vm.builder_begin_function(
			&builder,
			v.symbol_intern(verb.name),
			len(verb.params),
			0,
			false,
		)
		emitter.next_register = len(verb.params)
		emitter.max_register = emitter.next_register
		scope_enter(&emitter)
		for param, param_index in verb.params {
			append(&emitter.locals, Local {
				name     = param.name,
				register = param_index,
			})
		}
		body_register, has_body := emit_block(&emitter, verb.body)
		scope_leave(&emitter)
		if !has_body {
			body_register = emit_constant(&emitter, v.value_empty_relation())
		}
		vm.builder_emit(&builder, .Return, 0, i32(body_register), 0, 0)
		vm.builder_end_function(&builder)
		builder.functions[index].register_count = emitter.max_register
	}

	program := vm.builder_build(&builder, allocator)
	if validation := vm.program_validate(program); validation != .None {
		append(&emitter.errors, Compile_Error{message = "generated program failed validation"})
	}

	errors := make([]Compile_Error, len(emitter.errors), allocator)
	copy(errors, emitter.errors[:])
	return Compiled_Program{program = program, errors = errors}
}

// --- Emitter helpers -------------------------------------------------------

@(private)
push_error :: proc(emitter: ^Emitter, message: string) {
	append(&emitter.errors, Compile_Error{message = message})
}

@(private)
scope_enter :: proc(emitter: ^Emitter) {
	append(&emitter.scopes, Scope {
		register_mark = emitter.next_register,
		local_mark    = len(emitter.locals),
	})
}

@(private)
scope_leave :: proc(emitter: ^Emitter) {
	if len(emitter.scopes) == 0 {
		return
	}
	scope := pop(&emitter.scopes)
	emitter.next_register = scope.register_mark
	resize(&emitter.locals, scope.local_mark)
}

@(private)
alloc_register :: proc(emitter: ^Emitter) -> int {
	register := emitter.next_register
	emitter.next_register += 1
	if emitter.next_register > emitter.max_register {
		emitter.max_register = emitter.next_register
	}
	return register
}

@(private)
declare_local :: proc(emitter: ^Emitter, name: string, register: int, is_const: bool) {
	append(&emitter.locals, Local {
		name     = name,
		register = register,
		is_const = is_const,
	})
}

@(private)
resolve_local :: proc(emitter: ^Emitter, name: string) -> (int, bool, bool) {
	for index := len(emitter.locals) - 1; index >= 0; index -= 1 {
		local := emitter.locals[index]
		if local.name == name {
			return local.register, local.is_const, true
		}
	}
	return 0, false, false
}

@(private)
int_value :: proc(n: i64) -> v.Value {
	value, ok := v.value_int(n)
	if !ok {
		panic("integer value out of range")
	}
	return value
}

@(private)
emit_constant :: proc(emitter: ^Emitter, value: v.Value) -> int {
	constant := vm.builder_add_constant(emitter.builder, value)
	register := alloc_register(emitter)
	vm.builder_emit(emitter.builder, .Load_Const, 0, i32(register), i32(constant), 0)
	return register
}

@(private)
current_offset :: proc(emitter: ^Emitter) -> int {
	return len(emitter.builder.code)
}

@(private)
emit_instruction :: proc(emitter: ^Emitter, op: vm.Op, flags: u8, a, b, c: int) -> int {
	index := current_offset(emitter)
	vm.builder_emit(emitter.builder, op, flags, i32(a), i32(b), i32(c))
	return index
}

@(private)
patch_jump :: proc(emitter: ^Emitter, at: int, target: int) {
	emitter.builder.code[at].b = i32(target - (at + 1))
}

// --- Expressions -----------------------------------------------------------

@(private)
emit_block :: proc(emitter: ^Emitter, body: []^Expr) -> (int, bool) {
	last_register := -1
	has_value := false
	for expression in body {
		register, expression_has_value := emit_expr(emitter, expression)
		if expression_has_value {
			last_register = register
			has_value = true
		}
	}
	return last_register, has_value
}

@(private)
emit_expr :: proc(emitter: ^Emitter, node: ^Expr) -> (int, bool) {
	if node == nil {
		return -1, false
	}

	#partial switch n in node^ {
	case Int_Literal:
		value, ok := strconv.parse_i64(n.text)
		if !ok {
			push_error(emitter, "invalid integer literal")
			return -1, false
		}
		converted, converted_ok := v.value_int(value)
		if !converted_ok {
			push_error(emitter, "integer literal is out of range")
			return -1, false
		}
		return emit_constant(emitter, converted), true

	case Float_Literal:
		value, ok := strconv.parse_f64(n.text)
		if !ok {
			push_error(emitter, "invalid float literal")
			return -1, false
		}
		converted, converted_ok := v.value_float(f32(value))
		if !converted_ok {
			push_error(emitter, "float literal is not finite")
			return -1, false
		}
		return emit_constant(emitter, converted), true

	case String_Literal:
		text := unquote_string(n.text, emitter.allocator)
		return emit_constant(emitter, v.value_string(emitter.allocator, text)), true

	case Bool_Literal:
		return emit_constant(emitter, v.value_bool(n.value)), true

	case Error_Code_Literal:
		return emit_constant(
			emitter,
			v.value_error_code(v.symbol_intern(n.name)),
		), true

	case Identity_Literal:
		return emit_identity(emitter, n)

	case Symbol_Literal:
		name := n.name
		if strings.has_prefix(name, "\"") {
			name = unquote_string(name, emitter.allocator)
		}
		return emit_constant(emitter, v.value_symbol(v.symbol_intern(name))), true

	case Name:
		return emit_name(emitter, n)

	case Binding:
		return emit_binding(emitter, n)

	case Assignment:
		return emit_assignment(emitter, n)

	case Unary:
		return emit_unary(emitter, n)

	case Binary:
		return emit_binary(emitter, n)

	case Call:
		return emit_call(emitter, n)

	case List_Literal:
		return emit_list(emitter, n)

	case Map_Literal:
		return emit_map(emitter, n)

	case Range_Literal:
		return emit_range(emitter, n)

	case Index:
		return emit_index(emitter, n)

	case Field:
		return emit_field_read(emitter, n)

	case Require:
		return emit_require(emitter, n)

	case If:
		return emit_if(emitter, n)

	case While:
		return emit_while(emitter, n)

	case For:
		return emit_for(emitter, n)

	case Begin:
		scope_enter(emitter)
		defer scope_leave(emitter)
		return emit_block(emitter, n.body)

	case Return:
		return emit_return(emitter, n)

	case Break:
		if len(emitter.break_patches) == 0 {
			push_error(emitter, "break outside a loop")
			return -1, false
		}
		append(&emitter.break_patches, emit_instruction(emitter, .Jump, 0, 0, 0, 0))
		return -1, false

	case Continue:
		if len(emitter.continue_targets) == 0 {
			push_error(emitter, "continue outside a loop")
			return -1, false
		}
		target := emitter.continue_targets[len(emitter.continue_targets) - 1]
		index := emit_instruction(emitter, .Jump, 0, 0, 0, 0)
		patch_jump(emitter, index, target)
		return -1, false

	case Assert:
		return emit_relation_write(emitter, n.atom, true)

	case Retract:
		return emit_relation_write(emitter, n.atom, false)

	case Match:
		push_error(emitter, "match expressions are not lowered yet")
		return -1, false

	case Try:
		push_error(emitter, "try expressions are not lowered yet")
		return -1, false

	case Raise:
		push_error(emitter, "raise expressions are not lowered yet")
		return -1, false

	case Spawn:
		push_error(emitter, "spawn expressions are not lowered yet")
		return -1, false

	case Structural_Literal:
		push_error(emitter, "structural literals are not lowered yet")
		return -1, false

	case Dom_Text, Dom_Element:
		push_error(emitter, "DOM markup is not lowered yet")
		return -1, false

	case Fn:
		push_error(emitter, "fn literals are not lowered yet")
		return -1, false

	case Splice:
		push_error(emitter, "splices are not lowered yet")
		return -1, false

	case Query_Variable:
		push_error(emitter, "query variables are not lowered yet")
		return -1, false

	case Wildcard:
		push_error(emitter, "wildcards are not lowered yet")
		return -1, false

	case Bytes_Literal:
		push_error(emitter, "byte literals are not lowered yet")
		return -1, false

	case:
		push_error(emitter, "this expression is not lowered yet")
		return -1, false
	}
}

@(private)
emit_identity :: proc(emitter: ^Emitter, literal: Identity_Literal) -> (int, bool) {
	// `#123` is a raw identity. `#name` must have been created by the world and
	// registered in the compile context.
	if raw, ok := strconv.parse_u64(literal.name); ok {
		converted, converted_ok := v.value_identity_raw(raw)
		if !converted_ok {
			push_error(emitter, "identity literal is out of range")
			return -1, false
		}
		return emit_constant(emitter, converted), true
	}

	if emitter.ctx != nil {
		if value, found := emitter.ctx.identities[literal.name]; found {
			return emit_constant(emitter, value), true
		}
	}
	push_error(emitter, "unknown identity literal")
	return -1, false
}

@(private)
emit_name :: proc(emitter: ^Emitter, name: Name) -> (int, bool) {
	text := join_name(name, emitter.allocator)
	register, _, found := resolve_local(emitter, text)
	if !found {
		push_error(emitter, "unknown name")
		return -1, false
	}
	destination := alloc_register(emitter)
	vm.builder_emit(emitter.builder, .Move, 0, i32(destination), i32(register), 0)
	return destination, true
}

@(private)
emit_binding :: proc(emitter: ^Emitter, binding: Binding) -> (int, bool) {
	value_register := -1
	has_value := false
	if binding.has_value {
		value_register, has_value = emit_expr(emitter, binding.value)
		if !has_value {
			return -1, false
		}
	}

	if map_pattern, is_map_pattern := binding.pattern^.(Map_Pattern); is_map_pattern {
		return emit_map_pattern_binding(emitter, binding, map_pattern)
	}

	pattern, is_binding_pattern := binding.pattern^.(Binding_Pattern)
	if !is_binding_pattern {
		push_error(emitter, "this binding pattern is not lowered yet")
		return -1, false
	}

	if !has_value {
		value_register = alloc_register(emitter)
	}
	declare_local(emitter, pattern.name, value_register, binding.is_const)
	return value_register, true
}

@(private)
emit_assignment :: proc(emitter: ^Emitter, assignment: Assignment) -> (int, bool) {
	if field, is_field := assignment.target^.(Field); is_field {
		receiver, receiver_ok := emit_expr(emitter, field.receiver)
		if !receiver_ok {
			return -1, false
		}
		_ = emit_constant(
			emitter,
			v.value_symbol(v.symbol_intern(field.name)),
		)
		value, value_ok := emit_expr(emitter, assignment.value)
		if !value_ok {
			return -1, false
		}
		destination := alloc_register(emitter)
		builtin := vm.builder_add_builtin(emitter.builder, v.symbol_intern("__set_field"))
		vm.builder_emit(
			emitter.builder,
			.Builtin_Call,
			0,
			i32(destination),
			builtin,
			i32(receiver),
		)
		return value, true
	}

	target, is_name := assignment.target^.(Name)
	if !is_name {
		push_error(emitter, "assignment target must be a name or field")
		return -1, false
	}
	text := join_name(target, emitter.allocator)
	register, is_const, found := resolve_local(emitter, text)
	if !found {
		push_error(emitter, "assignment to an unknown name")
		return -1, false
	}
	if is_const {
		push_error(emitter, "assignment to a constant binding")
		return -1, false
	}

	value_register, has_value := emit_expr(emitter, assignment.value)
	if !has_value {
		return -1, false
	}
	vm.builder_emit(emitter.builder, .Move, 0, i32(register), i32(value_register), 0)
	return value_register, true
}

@(private)
emit_unary :: proc(emitter: ^Emitter, unary: Unary) -> (int, bool) {
	operand, has_operand := emit_expr(emitter, unary.operand)
	if !has_operand {
		return -1, false
	}
	destination := alloc_register(emitter)
	op: vm.Un_Op = .Neg
	if unary.op == .Not {
		op = .Not
	}
	vm.builder_emit(emitter.builder, .Unary, u8(op), i32(destination), i32(operand), 0)
	return destination, true
}

@(private)
emit_binary :: proc(emitter: ^Emitter, binary: Binary) -> (int, bool) {
	if binary.op == .And || binary.op == .Or {
		return emit_short_circuit(emitter, binary)
	}

	left, has_left := emit_expr(emitter, binary.left)
	if !has_left {
		return -1, false
	}
	right, has_right := emit_expr(emitter, binary.right)
	if !has_right {
		return -1, false
	}

	destination := alloc_register(emitter)
	vm.builder_emit(
		emitter.builder,
		.Binary,
		u8(binary_op(binary.op)),
		i32(destination),
		i32(left),
		i32(right),
	)
	return destination, true
}

@(private)
binary_op :: proc(op: Binary_Op) -> vm.Bin_Op {
	switch op {
	case .Add:
		return .Add
	case .Sub:
		return .Sub
	case .Mul:
		return .Mul
	case .Div:
		return .Div
	case .Rem:
		return .Rem
	case .Lt:
		return .Lt
	case .Le:
		return .Le
	case .Gt:
		return .Gt
	case .Ge:
		return .Ge
	case .Eq:
		return .Eq
	case .Ne:
		return .Ne
	case .Range, .And, .Or:
		return .Add
	}
	return .Add
}

@(private)
emit_call :: proc(emitter: ^Emitter, call: Call) -> (int, bool) {
	callee, is_name := call.callee^.(Name)
	if !is_name {
		push_error(emitter, "call target must be a name")
		return -1, false
	}
	text := join_name(callee, emitter.allocator)

	for argument in call.args {
		if argument.has_role {
			push_error(emitter, "named-role calls are not lowered yet")
			return -1, false
		}
		if _, is_splice := argument.expr^.(Splice); is_splice {
			push_error(emitter, "argument splices are not lowered yet")
			return -1, false
		}
	}

	// A relation query.
	if emitter.ctx != nil {
		if relation, found := emitter.ctx.relations[text]; found {
			return emit_relation_query(emitter, relation, call)
		}
	}

	first_argument := -1
	for argument, index in call.args {
		register, has_value := emit_expr(emitter, argument.expr)
		if !has_value {
			return -1, false
		}
		if index == 0 {
			first_argument = register
		}
	}
	if first_argument < 0 {
		first_argument = 0
	}

	// A directly callable verb.
	if function_index, found := emitter.functions[text]; found {
		destination := alloc_register(emitter)
		vm.builder_emit(
			emitter.builder,
			.Call,
			0,
			i32(destination),
			i32(function_index),
			i32(first_argument),
		)
		return destination, true
	}

	// A registered builtin.
	if emitter.ctx != nil && emitter.ctx.builtins[text] {
		destination := alloc_register(emitter)
		builtin := vm.builder_add_builtin(emitter.builder, v.symbol_intern(text))
		vm.builder_emit(
			emitter.builder,
			.Builtin_Call,
			0,
			i32(destination),
			builtin,
			i32(first_argument),
		)
		return destination, true
	}

	push_error(emitter, "unknown callable")
	return -1, false
}

@(private)
emit_list :: proc(emitter: ^Emitter, list: List_Literal) -> (int, bool) {
	first := -1
	count := 0
	for element in list.elements {
		if _, is_splice := element^.(Splice); is_splice {
			push_error(emitter, "list splices are not lowered yet")
			return -1, false
		}
		register, has_value := emit_expr(emitter, element)
		if !has_value {
			return -1, false
		}
		if first < 0 {
			first = register
		}
		count += 1
	}
	if first < 0 {
		first = 0
	}
	destination := alloc_register(emitter)
	vm.builder_emit(emitter.builder, .Build_List, 0, i32(destination), i32(first), i32(count))
	return destination, true
}

@(private)
emit_map :: proc(emitter: ^Emitter, map_literal: Map_Literal) -> (int, bool) {
	first := -1
	count := 0
	for entry in map_literal.entries {
		key_register, key_ok := emit_expr(emitter, entry.key)
		if !key_ok {
			return -1, false
		}
		value_register, value_ok := emit_expr(emitter, entry.value)
		if !value_ok {
			return -1, false
		}
		if first < 0 {
			first = key_register
		}
		count += 1
	}
	if first < 0 {
		first = 0
	}
	destination := alloc_register(emitter)
	vm.builder_emit(emitter.builder, .Build_Map, 0, i32(destination), i32(first), i32(count))
	return destination, true
}

@(private)
emit_range :: proc(emitter: ^Emitter, range: Range_Literal) -> (int, bool) {
	start, start_ok := emit_expr(emitter, range.start)
	if !start_ok {
		return -1, false
	}
	end := start
	if range.has_end {
		end_register, end_ok := emit_expr(emitter, range.end)
		if !end_ok {
			return -1, false
		}
		end = end_register
	}
	destination := alloc_register(emitter)
	flags: u8 = range.has_end ? 1 : 0
	vm.builder_emit(emitter.builder, .Build_Range, flags, i32(destination), i32(start), i32(end))
	return destination, true
}

@(private)
emit_index :: proc(emitter: ^Emitter, index: Index) -> (int, bool) {
	collection, collection_ok := emit_expr(emitter, index.collection)
	if !collection_ok {
		return -1, false
	}
	key, key_ok := emit_expr(emitter, index.key)
	if !key_ok {
		return -1, false
	}
	destination := alloc_register(emitter)
	vm.builder_emit(emitter.builder, .Index, 0, i32(destination), i32(collection), i32(key))
	return destination, true
}

@(private)
emit_if :: proc(emitter: ^Emitter, conditional: If) -> (int, bool) {
	result := alloc_register(emitter)
	end_patches: [dynamic]int
	defer delete(end_patches)

	previous_skip := -1
	for branch in conditional.branches {
		if previous_skip >= 0 {
			patch_jump(emitter, previous_skip, current_offset(emitter))
		}
		condition, condition_ok := emit_expr(emitter, branch.condition)
		if !condition_ok {
			return -1, false
		}
		branch_jump := emit_instruction(emitter, .Branch, 0, condition, 0, 0)
		skip_jump := emit_instruction(emitter, .Jump, 0, 0, 0, 0)
		patch_jump(emitter, branch_jump, current_offset(emitter))

		scope_enter(emitter)
		body_register, body_has_value := emit_block(emitter, branch.body)
		scope_leave(emitter)
		if body_has_value {
			vm.builder_emit(emitter.builder, .Move, 0, i32(result), i32(body_register), 0)
		}
		append(&end_patches, emit_instruction(emitter, .Jump, 0, 0, 0, 0))
		previous_skip = skip_jump
	}
	if previous_skip >= 0 {
		patch_jump(emitter, previous_skip, current_offset(emitter))
	}

	if conditional.has_else {
		scope_enter(emitter)
		body_register, body_has_value := emit_block(emitter, conditional.else_body)
		scope_leave(emitter)
		if body_has_value {
			vm.builder_emit(emitter.builder, .Move, 0, i32(result), i32(body_register), 0)
		}
	}
	for patch in end_patches {
		patch_jump(emitter, patch, current_offset(emitter))
	}
	return result, true
}

@(private)
emit_while :: proc(emitter: ^Emitter, loop: While) -> (int, bool) {
	result := alloc_register(emitter)
	break_mark := len(emitter.break_patches)

	loop_start := current_offset(emitter)
	append(&emitter.continue_targets, loop_start)

	condition, condition_ok := emit_expr(emitter, loop.condition)
	if !condition_ok {
		return -1, false
	}
	body_jump := emit_instruction(emitter, .Branch, 0, condition, 0, 0)
	exit_jump := emit_instruction(emitter, .Jump, 0, 0, 0, 0)
	patch_jump(emitter, body_jump, current_offset(emitter))

	scope_enter(emitter)
	body_register, body_has_value := emit_block(emitter, loop.body)
	scope_leave(emitter)
	if body_has_value {
		vm.builder_emit(emitter.builder, .Move, 0, i32(result), i32(body_register), 0)
	}

	back_jump := emit_instruction(emitter, .Jump, 0, 0, 0, 0)
	patch_jump(emitter, back_jump, loop_start)

	pop(&emitter.continue_targets)
	patch_jump(emitter, exit_jump, current_offset(emitter))
	for index in break_mark ..< len(emitter.break_patches) {
		patch_jump(emitter, emitter.break_patches[index], current_offset(emitter))
	}
	resize(&emitter.break_patches, break_mark)
	return result, true
}

@(private)
emit_for :: proc(emitter: ^Emitter, loop: For) -> (int, bool) {
	if len(loop.names) != 1 {
		push_error(emitter, "only single-name for loops are lowered yet")
		return -1, false
	}

	iterable, iterable_ok := emit_expr(emitter, loop.iterable)
	if !iterable_ok {
		return -1, false
	}

	scope_enter(emitter)
	defer scope_leave(emitter)

	index_register := alloc_register(emitter)
	zero_index := emit_constant(emitter, int_value(0))
	vm.builder_emit(emitter.builder, .Move, 0, i32(index_register), i32(zero_index), 0)

	length_register := alloc_register(emitter)
	vm.builder_emit(emitter.builder, .Len, 0, i32(length_register), i32(iterable), 0)

	break_mark := len(emitter.break_patches)
	loop_start := current_offset(emitter)
	append(&emitter.continue_targets, loop_start)

	condition_register := alloc_register(emitter)
	vm.builder_emit(
		emitter.builder,
		.Binary,
		u8(vm.Bin_Op.Lt),
		i32(condition_register),
		i32(index_register),
		i32(length_register),
	)
	body_jump := emit_instruction(emitter, .Branch, 0, condition_register, 0, 0)
	exit_jump := emit_instruction(emitter, .Jump, 0, 0, 0, 0)
	patch_jump(emitter, body_jump, current_offset(emitter))

	scope_enter(emitter)
	item_register := alloc_register(emitter)
	vm.builder_emit(
		emitter.builder,
		.Index,
		0,
		i32(item_register),
		i32(iterable),
		i32(index_register),
	)
	declare_local(emitter, loop.names[0], item_register, false)

	result, has_result := emit_block(emitter, loop.body)
	scope_leave(emitter)
	_ = result
	_ = has_result

	one_register := emit_constant(emitter, int_value(1))
	vm.builder_emit(
		emitter.builder,
		.Binary,
		u8(vm.Bin_Op.Add),
		i32(index_register),
		i32(index_register),
		i32(one_register),
	)

	back_jump := emit_instruction(emitter, .Jump, 0, 0, 0, 0)
	patch_jump(emitter, back_jump, loop_start)

	pop(&emitter.continue_targets)
	patch_jump(emitter, exit_jump, current_offset(emitter))
	for index in break_mark ..< len(emitter.break_patches) {
		patch_jump(emitter, emitter.break_patches[index], current_offset(emitter))
	}
	resize(&emitter.break_patches, break_mark)

	return -1, false
}

@(private)
emit_return :: proc(emitter: ^Emitter, return_stmt: Return) -> (int, bool) {
	register := -1
	if return_stmt.has_value {
		value_register, has_value := emit_expr(emitter, return_stmt.value)
		if !has_value {
			return -1, false
		}
		register = value_register
	} else {
		register = emit_constant(emitter, v.value_empty_relation())
	}
	vm.builder_emit(emitter.builder, .Return, 0, i32(register), 0, 0)
	return -1, false
}

@(private)
emit_relation_write :: proc(
	emitter: ^Emitter,
	atom: ^Expr,
	assert_write: bool,
) -> (int, bool) {
	call, is_call := atom^.(Call)
	if !is_call {
		push_error(emitter, "assert and retract need a relation atom")
		return -1, false
	}
	callee, is_name := call.callee^.(Name)
	if !is_name {
		push_error(emitter, "assert and retract need a relation name")
		return -1, false
	}
	name := join_name(callee, emitter.allocator)

	relation: u32
	found := false
	if emitter.ctx != nil {
		relation, found = emitter.ctx.relations[name]
	}
	if !found {
		push_error(emitter, "unknown relation in assert or retract")
		return -1, false
	}

	heading := make([]v.Symbol, len(call.args), emitter.allocator)
	for index in 0 ..< len(heading) {
		builder: strings.Builder
		strings.builder_init(&builder, emitter.allocator)
		fmt.sbprintf(&builder, "column%d", index)
		heading[index] = v.symbol_intern(strings.to_string(builder))
	}
	shape := vm.builder_add_relation_shape(emitter.builder, heading)

	first_argument := -1
	for argument, index in call.args {
		if argument.has_role {
			push_error(emitter, "named-role relation atoms are not lowered yet")
			return -1, false
		}
		register, has_value := emit_expr(emitter, argument.expr)
		if !has_value {
			return -1, false
		}
		if index == 0 {
			first_argument = register
		}
	}
	if first_argument < 0 {
		first_argument = 0
	}

	row_register := alloc_register(emitter)
	vm.builder_emit(
		emitter.builder,
		.Build_Relation,
		0,
		i32(row_register),
		shape,
		i32(first_argument),
	)

	op: vm.Op = assert_write ? .Assert : .Retract
	vm.builder_emit(emitter.builder, op, 0, i32(relation), i32(row_register), 0)
	return row_register, true
}

// --- Shared helpers --------------------------------------------------------

@(private)
join_name :: proc(name: Name, allocator: mem.Allocator) -> string {
	if len(name.parts) == 1 {
		return name.parts[0]
	}
	builder: strings.Builder
	strings.builder_init(&builder, allocator)
	for part, index in name.parts {
		if index > 0 {
			strings.write_byte(&builder, '/')
		}
		strings.write_string(&builder, part)
	}
	return strings.to_string(builder)
}

@(private)
unquote_string :: proc(text: string, allocator: mem.Allocator) -> string {
	if len(text) < 2 || text[0] != '"' {
		return text
	}
	body := text[1 : len(text) - 1]
	if !strings.contains(text, "\\") {
		return body
	}

	builder: strings.Builder
	strings.builder_init(&builder, allocator)
	index := 0
	for index < len(body) {
		char := body[index]
		if char != '\\' || index + 1 >= len(body) {
			strings.write_byte(&builder, char)
			index += 1
			continue
		}
		index += 1
		escape := body[index]
		switch escape {
		case 'n':
			strings.write_byte(&builder, '\n')
		case 't':
			strings.write_byte(&builder, '\t')
		case 'r':
			strings.write_byte(&builder, '\r')
		case '0':
			strings.write_byte(&builder, 0)
		case '\\':
			strings.write_byte(&builder, '\\')
		case '"':
			strings.write_byte(&builder, '"')
		case:
			strings.write_byte(&builder, '\\')
			strings.write_byte(&builder, escape)
		}
		index += 1
	}
	return strings.to_string(builder)
}

// --- Short circuit and relation queries ------------------------------------

@(private)
emit_short_circuit :: proc(emitter: ^Emitter, binary: Binary) -> (int, bool) {
	left, left_ok := emit_expr(emitter, binary.left)
	if !left_ok {
		return -1, false
	}
	result := alloc_register(emitter)
	truth := alloc_register(emitter)
	vm.builder_emit(emitter.builder, .Is_Truthy, 0, i32(truth), i32(left), 0)
	branch := emit_instruction(emitter, .Branch, 0, truth, 0, 0)

	if binary.op == .And {
		// Falsy: the result is false.
		false_register := emit_constant(emitter, v.value_bool(false))
		vm.builder_emit(emitter.builder, .Move, 0, i32(result), i32(false_register), 0)
		end_jump := emit_instruction(emitter, .Jump, 0, 0, 0, 0)
		patch_jump(emitter, branch, current_offset(emitter))

		right, right_ok := emit_expr(emitter, binary.right)
		if !right_ok {
			return -1, false
		}
		vm.builder_emit(emitter.builder, .Move, 0, i32(result), i32(right), 0)
		patch_jump(emitter, end_jump, current_offset(emitter))
		return result, true
	}

	// Or: truthy gives true, otherwise the right operand.
	right, right_ok := emit_expr(emitter, binary.right)
	if !right_ok {
		return -1, false
	}
	vm.builder_emit(emitter.builder, .Move, 0, i32(result), i32(right), 0)
	end_jump := emit_instruction(emitter, .Jump, 0, 0, 0, 0)
	patch_jump(emitter, branch, current_offset(emitter))

	true_register := emit_constant(emitter, v.value_bool(true))
	vm.builder_emit(emitter.builder, .Move, 0, i32(result), i32(true_register), 0)
	patch_jump(emitter, end_jump, current_offset(emitter))
	return result, true
}

@(private)
relation_call :: proc(emitter: ^Emitter, call: Call) -> (u32, Name, bool) {
	callee, is_name := call.callee^.(Name)
	if !is_name || emitter.ctx == nil {
		return 0, {}, false
	}
	text := join_name(callee, emitter.allocator)
	relation, found := emitter.ctx.relations[text]
	return relation, callee, found
}

@(private)
relation_cells :: proc(
	emitter: ^Emitter,
	call: Call,
	allocator: mem.Allocator,
) -> (
	[]vm.Pattern_Cell,
	[]v.Symbol,
	bool,
) {
	cells := make([]vm.Pattern_Cell, len(call.args), allocator)
	names := make([]v.Symbol, len(call.args), allocator)
	for argument, index in call.args {
		#partial switch term in argument.expr^ {
		case Query_Variable:
			register := alloc_register(emitter)
			cells[index] = vm.Pattern_Cell{kind = .Output, operand = i32(register)}
			names[index] = v.symbol_intern(term.name)
		case Wildcard:
			cells[index] = vm.Pattern_Cell{kind = .Wildcard}
			names[index] = v.symbol_intern(generated_column(index, allocator))
		case:
			register, has_value := emit_expr(emitter, argument.expr)
			if !has_value {
				return nil, nil, false
			}
			cells[index] = vm.Pattern_Cell{kind = .Bind, operand = i32(register)}
			names[index] = v.symbol_intern(generated_column(index, allocator))
		}
	}
	return cells, names, true
}

@(private)
generated_column :: proc(index: int, allocator: mem.Allocator) -> string {
	builder: strings.Builder
	strings.builder_init(&builder, allocator)
	fmt.sbprintf(&builder, "column%d", index)
	return strings.to_string(builder)
}

@(private)
emit_relation_query :: proc(emitter: ^Emitter, relation: u32, call: Call) -> (int, bool) {
	cells, names, cells_ok := relation_cells(emitter, call, context.temp_allocator)
	if !cells_ok {
		return -1, false
	}
	pattern := vm.builder_add_pattern(emitter.builder, relation, names, cells)
	destination := alloc_register(emitter)
	vm.builder_emit(
		emitter.builder,
		.Scan_Collect,
		0,
		i32(destination),
		pattern,
		0,
	)
	return destination, true
}

@(private)
emit_map_pattern_binding :: proc(
	emitter: ^Emitter,
	binding: Binding,
	pattern: Map_Pattern,
) -> (int, bool) {
	// A relation call binds columns directly by name.
	if call, is_call := binding.value^.(Call); is_call {
		if relation, _, found := relation_call(emitter, call); found {
			cells, names, cells_ok := relation_cells(emitter, call, context.temp_allocator)
			if !cells_ok {
				return -1, false
			}
			builder_pattern := vm.builder_add_pattern(emitter.builder, relation, names, cells)
			result := alloc_register(emitter)
			op: vm.Op = binding.is_exactly ? .Scan_One : .Scan_First
			vm.builder_emit(emitter.builder, op, 0, i32(result), builder_pattern, 0)
			for entry in pattern.entries {
				key_name := pattern_key_name(entry, emitter.allocator)
				cell_register := relation_cell_register(cells, names, key_name)
				binding_pattern, is_binding := entry.pattern^.(Binding_Pattern)
				if !is_binding {
					push_error(emitter, "map pattern values must be names")
					return -1, false
				}
				if cell_register < 0 {
					push_error(emitter, "map pattern column is not in the query")
					return -1, false
				}
				declare_local(emitter, binding_pattern.name, cell_register, binding.is_const)
			}
			return result, true
		}
	}

	// Otherwise read columns from the value with symbol indexing.
	value_register, has_value := emit_expr(emitter, binding.value)
	if !has_value {
		return -1, false
	}
	result := alloc_register(emitter)
	for entry in pattern.entries {
		key_name := pattern_key_name(entry, emitter.allocator)
		symbol_register := emit_constant(
			emitter,
			v.value_symbol(v.symbol_intern(key_name)),
		)
		column := alloc_register(emitter)
		vm.builder_emit(
			emitter.builder,
			.Index,
			0,
			i32(column),
			i32(value_register),
			i32(symbol_register),
		)
		binding_pattern, is_binding := entry.pattern^.(Binding_Pattern)
		if !is_binding {
			push_error(emitter, "map pattern values must be names")
			return -1, false
		}
		declare_local(emitter, binding_pattern.name, column, binding.is_const)
		vm.builder_emit(emitter.builder, .Move, 0, i32(result), i32(column), 0)
	}
	return result, true
}

@(private)
pattern_key_name :: proc(entry: Map_Pattern_Entry, allocator: mem.Allocator) -> string {
	symbol, is_symbol := entry.key^.(Symbol_Literal)
	if !is_symbol {
		return ""
	}
	if strings.has_prefix(symbol.name, "\"") {
		return unquote_string(symbol.name, allocator)
	}
	return symbol.name
}

@(private)
relation_cell_register :: proc(
	cells: []vm.Pattern_Cell,
	names: []v.Symbol,
	name: string,
) -> int {
	for cell, index in cells {
		if cell.kind != .Output {
			continue
		}
		column_name, ok := v.symbol_name(names[index])
		if ok && column_name == name {
			return int(cell.operand)
		}
	}
	return -1
}

@(private)
emit_field_read :: proc(emitter: ^Emitter, field: Field) -> (int, bool) {
	receiver, receiver_ok := emit_expr(emitter, field.receiver)
	if !receiver_ok {
		return -1, false
	}
	symbol_register := emit_constant(emitter, v.value_symbol(v.symbol_intern(field.name)))
	destination := alloc_register(emitter)
	builtin := vm.builder_add_builtin(emitter.builder, v.symbol_intern("__get_field"))
	vm.builder_emit(
		emitter.builder,
		.Builtin_Call,
		0,
		i32(destination),
		builtin,
		i32(receiver),
	)
	return destination, true
}

@(private)
emit_require :: proc(emitter: ^Emitter, require: Require) -> (int, bool) {
	condition, condition_ok := emit_expr(emitter, require.condition)
	if !condition_ok {
		return -1, false
	}
	destination := alloc_register(emitter)
	builtin := vm.builder_add_builtin(emitter.builder, v.symbol_intern("require"))
	vm.builder_emit(
		emitter.builder,
		.Builtin_Call,
		0,
		i32(destination),
		builtin,
		i32(condition),
	)
	return destination, true
}
