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
	// Kernel relation ids for relation-driven dispatch. Zero disables it.
	dispatch_method_selector_relation: u32,
	dispatch_param_relation:           u32,
	dispatch_delegates_relation:       u32,
	dispatch_method_program_relation:  u32,
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
	loop_depth: int,
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
	if ctx != nil {
		builder.dispatch_method_selector_relation = ctx.dispatch_method_selector_relation
		builder.dispatch_param_relation = ctx.dispatch_param_relation
		builder.dispatch_delegates_relation = ctx.dispatch_delegates_relation
		builder.dispatch_method_program_relation = ctx.dispatch_method_program_relation
	}

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
		if emitter.loop_depth == 0 {
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
		return emit_match(emitter, n)

	case Try:
		push_error(emitter, "try expressions are not lowered yet")
		return -1, false

	case Raise:
		return emit_raise(emitter, n)

	case Spawn:
		return emit_spawn(emitter, n)

	case Structural_Literal:
		return emit_frob(emitter, n)

	case Dom_Text:
		return emit_dom_text(emitter, n)

	case Dom_Element:
		return emit_dom_element(emitter, n)

	case Fn:
		push_error(emitter, "fn literals are not lowered yet")
		return -1, false

	case Splice:
		push_error(emitter, "splices are not lowered yet")
		return -1, false

	case Query_Variable:
		push_error(emitter, fmt.aprintf(
			"query variables are not lowered yet: ?%s",
			n.name,
			allocator = emitter.allocator,
		))
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
	if text == "none" {
		empty, _ := v.value_relation(
			emitter.allocator,
			[]v.Symbol{v.symbol_intern("value")},
			nil,
		)
		return emit_constant(emitter, empty), true
	}
	register, _, found := resolve_local(emitter, text)
	if !found {
		push_error(emitter, fmt.aprintf("unknown name: %s", text, allocator = emitter.allocator))
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
		if call_pattern, is_call_pattern := binding.pattern^.(Call_Pattern); is_call_pattern {
			return emit_call_pattern_binding(emitter, binding, call_pattern)
		}
		push_error(emitter, "this binding pattern is not lowered yet")
		return -1, false
	}

	if !has_value {
		value_register = alloc_register(emitter)
	}
	declare_local(emitter, pattern.name, value_register, binding.is_const)
	return value_register, true
}

// Binds `some(x)`, `ok(x)`, or `err(x)` patterns from the value's `value`
// column. The result is whether the value is present, so this also serves as
// the condition of `if let`.
@(private)
emit_call_pattern_binding :: proc(
	emitter: ^Emitter,
	binding: Binding,
	pattern: Call_Pattern,
) -> (int, bool) {
	if len(pattern.args) > 1 {
		push_error(emitter, "call patterns support one binding")
		return -1, false
	}
	value_register, has_value := emit_expr(emitter, binding.value)
	if !has_value {
		return -1, false
	}

	for argument in pattern.args {
		binding_pattern, is_binding := argument^.(Binding_Pattern)
		if !is_binding {
			push_error(emitter, "call pattern arguments must be names")
			return -1, false
		}
		column_symbol := emit_constant(
			emitter,
			v.value_symbol(v.symbol_intern("value")),
		)
		column := alloc_register(emitter)
		vm.builder_emit(
			emitter.builder,
			.Index,
			0,
			i32(column),
			i32(value_register),
			i32(column_symbol),
		)
		declare_local(emitter, binding_pattern.name, column, binding.is_const)
	}

	result := alloc_register(emitter)
	vm.builder_emit(
		emitter.builder,
		.Is_Truthy,
		0,
		i32(result),
		i32(value_register),
		0,
	)
	return result, true
}

// Reserves a contiguous register block for `registers` and moves each value
// into it. The VM reads call and build operands from consecutive registers.
@(private)
marshal_arguments :: proc(emitter: ^Emitter, registers: []int) -> int {
	if len(registers) == 0 {
		return 0
	}
	first := alloc_register(emitter)
	for _ in 1 ..< len(registers) {
		_ = alloc_register(emitter)
	}
	for register, index in registers {
		if register == first + index {
			continue
		}
		vm.builder_emit(
			emitter.builder,
			.Move,
			0,
			i32(first + index),
			i32(register),
			0,
		)
	}
	return first
}

@(private)
emit_assignment :: proc(emitter: ^Emitter, assignment: Assignment) -> (int, bool) {
	if field, is_field := assignment.target^.(Field); is_field {
		receiver, receiver_ok := emit_expr(emitter, field.receiver)
		if !receiver_ok {
			return -1, false
		}
		symbol_register := emit_constant(
			emitter,
			v.value_symbol(v.symbol_intern(field.name)),
		)
		value, value_ok := emit_expr(emitter, assignment.value)
		if !value_ok {
			return -1, false
		}
		first_argument := marshal_arguments(emitter, []int{receiver, symbol_register, value})
		destination := alloc_register(emitter)
		builtin := vm.builder_add_builtin(emitter.builder, v.symbol_intern("__set_field"))
		vm.builder_emit(
			emitter.builder,
			.Builtin_Call,
			0,
			i32(destination),
			builtin,
			i32(first_argument),
		)
		return value, true
	}

	if index_target, is_index := assignment.target^.(Index); is_index {
		collection_name, collection_is_name := index_target.collection^.(Name)
		if !collection_is_name {
			push_error(emitter, "indexed assignment requires a named collection")
			return -1, false
		}
		collection_text := join_name(collection_name, emitter.allocator)
		collection, is_const, found := resolve_local(emitter, collection_text)
		if !found {
			push_error(emitter, fmt.aprintf(
				"assignment to an unknown name: %s",
				collection_text,
				allocator = emitter.allocator,
			))
			return -1, false
		}
		if is_const {
			push_error(emitter, "assignment to a constant binding")
			return -1, false
		}
		index_register, index_ok := emit_expr(emitter, index_target.key)
		if !index_ok {
			return -1, false
		}
		value_register, value_ok := emit_expr(emitter, assignment.value)
		if !value_ok {
			return -1, false
		}
		first_argument := marshal_arguments(
			emitter,
			[]int{collection, index_register, value_register},
		)
		destination := alloc_register(emitter)
		builtin := vm.builder_add_builtin(emitter.builder, v.symbol_intern("__set_index"))
		vm.builder_emit(
			emitter.builder,
			.Builtin_Call,
			3,
			i32(destination),
			builtin,
			i32(first_argument),
		)
		vm.builder_emit(emitter.builder, .Move, 0, i32(collection), i32(destination), 0)
		return destination, true
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
		if symbol, is_symbol := call.callee^.(Symbol_Literal); is_symbol {
			return emit_role_dispatch(emitter, symbol, call)
		}
		push_error(emitter, "call target must be a name")
		return -1, false
	}
	text := join_name(callee, emitter.allocator)

	for argument in call.args {
		if argument.has_role {
			push_error(emitter, fmt.aprintf(
				"call to %s uses role arguments without a symbol selector",
				text,
				allocator = emitter.allocator,
			))
			return -1, false
		}
		if _, is_splice := argument.expr^.(Splice); is_splice {
			push_error(emitter, "argument splices are not lowered yet")
			return -1, false
		}
	}

	if text == "some" || text == "ok" || text == "err" {
		return emit_standard_constructor(emitter, text, call)
	}

	if text == "invoke" {
		if len(call.args) != 2 {
			push_error(emitter, "invoke expects a selector and a role map")
			return -1, false
		}
		for argument in call.args {
			if argument.has_role {
				push_error(emitter, "invoke does not accept named arguments")
				return -1, false
			}
		}
		selector, selector_ok := emit_expr(emitter, call.args[0].expr)
		if !selector_ok {
			return -1, false
		}
		roles, roles_ok := emit_expr(emitter, call.args[1].expr)
		if !roles_ok {
			return -1, false
		}
		destination := alloc_register(emitter)
		vm.builder_emit(
			emitter.builder,
			.Dynamic_Dispatch,
			0,
			i32(destination),
			i32(selector),
			i32(roles),
		)
		return destination, true
	}

	if text == "commit" {
		if len(call.args) != 0 {
			push_error(emitter, "commit expects no arguments")
			return -1, false
		}
		vm.builder_emit(emitter.builder, .Commit, 0, 0, 0, 0)
		return -1, false
	}

	if text == "suspend" {
		if len(call.args) > 1 {
			push_error(emitter, "suspend expects zero or one argument")
			return -1, false
		}
		destination := alloc_register(emitter)
		if len(call.args) == 1 {
			duration, has_value := emit_expr(emitter, call.args[0].expr)
			if !has_value {
				return -1, false
			}
			vm.builder_emit(
				emitter.builder,
				.Sleep,
				0,
				i32(destination),
				i32(duration),
				0,
			)
		} else {
			vm.builder_emit(
				emitter.builder,
				.Yield,
				0,
				i32(destination),
				0,
				0,
			)
		}
		return destination, true
	}

	// A relation query.
	if emitter.ctx != nil {
		if relation, found := emitter.ctx.relations[text]; found {
			return emit_relation_query(emitter, relation, call)
		}
	}

	argument_registers := make([dynamic]int, 0, len(call.args), emitter.allocator)
	defer delete(argument_registers)
	for argument in call.args {
		register, has_value := emit_expr(emitter, argument.expr)
		if !has_value {
			return -1, false
		}
		append(&argument_registers, register)
	}
	first_argument := marshal_arguments(emitter, argument_registers[:])

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
			u8(len(call.args)),
			i32(destination),
			builtin,
			i32(first_argument),
		)
		return destination, true
	}

	push_error(emitter, fmt.aprintf("unknown callable: %s", text, allocator = emitter.allocator))
	return -1, false
}

@(private)
emit_singleton_list :: proc(emitter: ^Emitter, register: int) -> int {
	destination := alloc_register(emitter)
	vm.builder_emit(
		emitter.builder,
		.Build_List,
		0,
		i32(destination),
		i32(register),
		1,
	)
	return destination
}

@(private)
emit_list_concat :: proc(emitter: ^Emitter, lists: []int) -> (int, bool) {
	first := marshal_arguments(emitter, lists)
	destination := alloc_register(emitter)
	builtin := vm.builder_add_builtin(emitter.builder, v.symbol_intern("__list_concat"))
	vm.builder_emit(
		emitter.builder,
		.Builtin_Call,
		u8(len(lists)),
		i32(destination),
		builtin,
		i32(first),
	)
	return destination, true
}

@(private)
emit_list :: proc(emitter: ^Emitter, list: List_Literal) -> (int, bool) {
	has_splice := false
	for element in list.elements {
		if _, is_splice := element^.(Splice); is_splice {
			has_splice = true
			break
		}
	}

	registers := make([dynamic]int, 0, len(list.elements), emitter.allocator)
	defer delete(registers)
	for element in list.elements {
		if splice, is_splice := element^.(Splice); is_splice {
			register, has_value := emit_expr(emitter, splice.value)
			if !has_value {
				return -1, false
			}
			append(&registers, register)
			continue
		}
		register, has_value := emit_expr(emitter, element)
		if !has_value {
			return -1, false
		}
		if has_splice {
			register = emit_singleton_list(emitter, register)
		}
		append(&registers, register)
	}

	if has_splice {
		return emit_list_concat(emitter, registers[:])
	}
	first := marshal_arguments(emitter, registers[:])
	destination := alloc_register(emitter)
	vm.builder_emit(
		emitter.builder,
		.Build_List,
		0,
		i32(destination),
		i32(first),
		i32(len(registers)),
	)
	return destination, true
}

@(private)
emit_map :: proc(emitter: ^Emitter, map_literal: Map_Literal) -> (int, bool) {
	registers := make([dynamic]int, 0, len(map_literal.entries) * 2, emitter.allocator)
	defer delete(registers)
	for entry in map_literal.entries {
		key_register, key_ok := emit_expr(emitter, entry.key)
		if !key_ok {
			return -1, false
		}
		value_register, value_ok := emit_expr(emitter, entry.value)
		if !value_ok {
			return -1, false
		}
		append(&registers, key_register, value_register)
	}
	first := marshal_arguments(emitter, registers[:])
	destination := alloc_register(emitter)
	vm.builder_emit(
		emitter.builder,
		.Build_Map,
		0,
		i32(destination),
		i32(first),
		i32(len(map_literal.entries)),
	)
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
emit_frob :: proc(emitter: ^Emitter, frob: Structural_Literal) -> (int, bool) {
	head, is_identity := frob.head^.(Identity_Literal)
	if !is_identity {
		push_error(emitter, "frob delegate must be an identity")
		return -1, false
	}
	delegate, delegate_ok := emit_identity(emitter, head)
	if !delegate_ok {
		return -1, false
	}
	payload, payload_ok := emit_frob_payload(emitter, frob)
	if !payload_ok {
		return -1, false
	}
	if emitter.ctx == nil || !emitter.ctx.builtins["frob"] {
		push_error(emitter, "frob is not available")
		return -1, false
	}

	first_argument := marshal_arguments(emitter, []int{delegate, payload})

	destination := alloc_register(emitter)
	builtin := vm.builder_add_builtin(emitter.builder, v.symbol_intern("frob"))
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

@(private)
emit_role_dispatch :: proc(
	emitter: ^Emitter,
	selector: Symbol_Literal,
	call: Call,
) -> (int, bool) {
	roles := make([dynamic]vm.Dispatch_Role, 0, len(call.args), emitter.allocator)
	defer delete(roles)
	for argument in call.args {
		if !argument.has_role {
			push_error(emitter, "dispatch arguments must use explicit role names")
			return -1, false
		}
		register, has_value := emit_expr(emitter, argument.expr)
		if !has_value {
			return -1, false
		}
		append(&roles, vm.Dispatch_Role {
			role     = v.symbol_intern(argument.role),
			register = i32(register),
		})
	}
	spec := vm.builder_add_dispatch_spec(
		emitter.builder,
		v.symbol_intern(selector.name),
		roles[:],
	)
	destination := alloc_register(emitter)
	vm.builder_emit(
		emitter.builder,
		.Dispatch,
		0,
		i32(destination),
		spec,
		0,
	)
	return destination, true
}

// Lowers a match expression to an ordered chain of pattern tests. Bindings
// declared by a case are visible in its guard and body.
@(private)
emit_match :: proc(emitter: ^Emitter, matched: Match) -> (int, bool) {
	subject, subject_ok := emit_expr(emitter, matched.value)
	if !subject_ok {
		return -1, false
	}

	result := alloc_register(emitter)
	end_patches: [dynamic]int
	defer delete(end_patches)
	next_case_patches: [dynamic]int
	defer delete(next_case_patches)

	for match_case in matched.cases {
		scope_enter(emitter)
		test, test_ok := emit_match_pattern(emitter, subject, match_case.pattern)
		if !test_ok {
			scope_leave(emitter)
			return -1, false
		}
		test_branch := emit_instruction(emitter, .Branch, 0, test, 0, 0)
		append(&next_case_patches, emit_instruction(emitter, .Jump, 0, 0, 0, 0))
		patch_jump(emitter, test_branch, current_offset(emitter))

		if match_case.has_guard {
			guard, guard_ok := emit_expr(emitter, match_case.guard)
			if !guard_ok {
				scope_leave(emitter)
				return -1, false
			}
			guard_branch := emit_instruction(emitter, .Branch, 0, guard, 0, 0)
			append(&next_case_patches, emit_instruction(emitter, .Jump, 0, 0, 0, 0))
			patch_jump(emitter, guard_branch, current_offset(emitter))
		}

		body_register, body_has_value := emit_block(emitter, match_case.body)
		scope_leave(emitter)
		if body_has_value {
			vm.builder_emit(
				emitter.builder,
				.Move,
				0,
				i32(result),
				i32(body_register),
				0,
			)
		}
		append(&end_patches, emit_instruction(emitter, .Jump, 0, 0, 0, 0))

		for patch in next_case_patches {
			patch_jump(emitter, patch, current_offset(emitter))
		}
		clear(&next_case_patches)
	}
	for patch in end_patches {
		patch_jump(emitter, patch, current_offset(emitter))
	}
	return result, true
}

@(private)
emit_read_column :: proc(
	emitter: ^Emitter,
	subject: int,
	name: string,
) -> int {
	symbol_register := emit_constant(
		emitter,
		v.value_symbol(v.symbol_intern(name)),
	)
	column := alloc_register(emitter)
	vm.builder_emit(
		emitter.builder,
		.Index,
		0,
		i32(column),
		i32(subject),
		i32(symbol_register),
	)
	return column
}

@(private)
emit_match_pattern :: proc(
	emitter: ^Emitter,
	subject: int,
	pattern: ^Pattern,
) -> (int, bool) {
	#partial switch node in pattern^ {
	case Wildcard_Pattern:
		return emit_constant(emitter, v.value_bool(true)), true

	case Binding_Pattern:
		destination := alloc_register(emitter)
		vm.builder_emit(
			emitter.builder,
			.Move,
			0,
			i32(destination),
			i32(subject),
			0,
		)
		declare_local(emitter, node.name, destination, false)
		return emit_constant(emitter, v.value_bool(true)), true

	case Literal_Pattern:
		literal, literal_ok := emit_expr(emitter, node.value)
		if !literal_ok {
			return -1, false
		}
		test := alloc_register(emitter)
		vm.builder_emit(
			emitter.builder,
			.Binary,
			u8(vm.Bin_Op.Eq),
			i32(test),
			i32(subject),
			i32(literal),
		)
		return test, true

	case Call_Pattern:
		return emit_match_call_pattern(emitter, subject, node)
	}

	push_error(emitter, "this match pattern is not lowered yet")
	return -1, false
}

@(private)
emit_match_call_pattern :: proc(
	emitter: ^Emitter,
	subject: int,
	pattern: Call_Pattern,
) -> (int, bool) {
	test := alloc_register(emitter)
	if pattern.name == "some" {
		vm.builder_emit(
			emitter.builder,
			.Is_Truthy,
			0,
			i32(test),
			i32(subject),
			0,
		)
	} else if pattern.name == "ok" || pattern.name == "err" {
		expected_name := pattern.name == "err" ? "error" : "ok"
		actual := emit_read_column(emitter, subject, "case")
		expected := emit_constant(
			emitter,
			v.value_symbol(v.symbol_intern(expected_name)),
		)
		vm.builder_emit(
			emitter.builder,
			.Binary,
			u8(vm.Bin_Op.Eq),
			i32(test),
			i32(actual),
			i32(expected),
		)
	} else {
		push_error(emitter, fmt.aprintf(
			"unknown match constructor: %s",
			pattern.name,
			allocator = emitter.allocator,
		))
		return -1, false
	}

	if len(pattern.args) == 1 {
		binding, is_binding := pattern.args[0]^.(Binding_Pattern)
		if !is_binding {
			push_error(emitter, "match pattern arguments must be names")
			return -1, false
		}
		column := emit_read_column(emitter, subject, "value")
		declare_local(emitter, binding.name, column, false)
	} else if len(pattern.args) > 1 {
		push_error(emitter, "match constructors take at most one binding")
		return -1, false
	}
	return test, true
}

// Lowers a DOM text node to the `dom_text` builtin.
@(private)
emit_dom_text :: proc(emitter: ^Emitter, text: Dom_Text) -> (int, bool) {
	argument := emit_constant(
		emitter,
		v.value_string(emitter.allocator, text.text),
	)
	destination := alloc_register(emitter)
	builtin := vm.builder_add_builtin(emitter.builder, v.symbol_intern("dom_text"))
	vm.builder_emit(
		emitter.builder,
		.Builtin_Call,
		1,
		i32(destination),
		builtin,
		i32(argument),
	)
	return destination, true
}

// Lowers `dom <tag ...>children</tag>` to a `dom_element` call. Attributes
// become a string-keyed map; valueless attributes take the value true.
@(private)
emit_dom_element :: proc(emitter: ^Emitter, element: Dom_Element) -> (int, bool) {
	tag := emit_constant(
		emitter,
		v.value_string(emitter.allocator, element.tag),
	)

	attribute_registers := make([dynamic]int, 0, len(element.attributes) * 2, emitter.allocator)
	defer delete(attribute_registers)
	for attribute in element.attributes {
		key := emit_constant(
			emitter,
			v.value_string(emitter.allocator, attribute.name),
		)
		value := 0
		if attribute.has_value {
			emitted, has_value := emit_expr(emitter, attribute.value)
			if !has_value {
				return -1, false
			}
			value = emitted
		} else {
			value = emit_constant(emitter, v.value_bool(true))
		}
		append(&attribute_registers, key, value)
	}
	first_attribute := marshal_arguments(emitter, attribute_registers[:])
	attributes := alloc_register(emitter)
	vm.builder_emit(
		emitter.builder,
		.Build_Map,
		0,
		i32(attributes),
		i32(first_attribute),
		i32(len(element.attributes)),
	)

	children, children_ok := emit_list(
		emitter,
		List_Literal{elements = element.children},
	)
	if !children_ok {
		return -1, false
	}

	first := marshal_arguments(emitter, []int{tag, attributes, children})
	destination := alloc_register(emitter)
	builtin := vm.builder_add_builtin(emitter.builder, v.symbol_intern("dom_element"))
	vm.builder_emit(
		emitter.builder,
		.Builtin_Call,
		3,
		i32(destination),
		builtin,
		i32(first),
	)
	return destination, true
}

// Lowers `raise code, message, value` to a Raise instruction. The VM aborts
// the task with the resulting error value.
@(private)
emit_raise :: proc(emitter: ^Emitter, raise: Raise) -> (int, bool) {
	if len(raise.parts) == 0 || len(raise.parts) > 3 {
		push_error(emitter, "raise expects an error code and optional message and value")
		return -1, false
	}

	code, code_ok := emit_expr(emitter, raise.parts[0])
	if !code_ok {
		return -1, false
	}
	message := i32(-1)
	if len(raise.parts) > 1 {
		register, has_value := emit_expr(emitter, raise.parts[1])
		if !has_value {
			return -1, false
		}
		message = i32(register)
	}
	value := i32(-1)
	if len(raise.parts) > 2 {
		register, has_value := emit_expr(emitter, raise.parts[2])
		if !has_value {
			return -1, false
		}
		value = i32(register)
	}

	vm.builder_emit(
		emitter.builder,
		.Raise,
		0,
		i32(code),
		message,
		value,
	)
	return -1, false
}

// Lowers `spawn :verb(role: value, ...) [after millis]` to a Spawn
// instruction. The destination register receives the child task id when the
// parent resumes.
@(private)
emit_spawn :: proc(emitter: ^Emitter, spawn: Spawn) -> (int, bool) {
	call, is_call := spawn.call^.(Call)
	if !is_call {
		push_error(emitter, "spawn target must be a symbol call")
		return -1, false
	}
	selector, is_symbol := call.callee^.(Symbol_Literal)
	if !is_symbol {
		push_error(emitter, "spawn target must use a symbol selector like :verb(...)")
		return -1, false
	}

	roles := make([dynamic]vm.Dispatch_Role, 0, len(call.args), emitter.allocator)
	defer delete(roles)
	for argument in call.args {
		if !argument.has_role {
			push_error(emitter, "spawn arguments must use explicit role names")
			return -1, false
		}
		register, has_value := emit_expr(emitter, argument.expr)
		if !has_value {
			return -1, false
		}
		append(&roles, vm.Dispatch_Role {
			role     = v.symbol_intern(argument.role),
			register = i32(register),
		})
	}
	spec := vm.builder_add_dispatch_spec(
		emitter.builder,
		v.symbol_intern(selector.name),
		roles[:],
	)

	flags := u8(0)
	delay_register := i32(0)
	if spawn.has_delay {
		delay, has_value := emit_expr(emitter, spawn.delay)
		if !has_value {
			return -1, false
		}
		flags = 1
		delay_register = i32(delay)
	}

	destination := alloc_register(emitter)
	vm.builder_emit(
		emitter.builder,
		.Spawn,
		flags,
		i32(destination),
		spec,
		delay_register,
	)
	return destination, true
}

@(private)
emit_standard_constructor :: proc(
	emitter: ^Emitter,
	name: string,
	call: Call,
) -> (int, bool) {
	if len(call.args) != 1 {
		push_error(emitter, fmt.aprintf(
			"%s expects one positional argument",
			name,
			allocator = emitter.allocator,
		))
		return -1, false
	}
	payload, payload_ok := emit_expr(emitter, call.args[0].expr)
	if !payload_ok {
		return -1, false
	}

	heading: []v.Symbol
	first := 0
	switch name {
	case "some":
		heading = []v.Symbol{v.symbol_intern("value")}
		first = marshal_arguments(emitter, []int{payload})

	case "ok", "err":
		heading = []v.Symbol{v.symbol_intern("case"), v.symbol_intern("value")}
		tag := "ok" if name == "ok" else "error"
		tag_register := emit_constant(emitter, v.value_symbol(v.symbol_intern(tag)))
		first = marshal_arguments(emitter, []int{tag_register, payload})
	}

	shape := vm.builder_add_relation_shape(emitter.builder, heading)
	destination := alloc_register(emitter)
	vm.builder_emit(
		emitter.builder,
		.Build_Relation,
		0,
		i32(destination),
		shape,
		i32(first),
	)
	return destination, true
}

@(private)
emit_frob_payload :: proc(emitter: ^Emitter, frob: Structural_Literal) -> (int, bool) {
	if frob.named {
		entries := make([]Map_Entry_AST, len(frob.cells), emitter.allocator)
		for cell, index in frob.cells {
			entries[index] = Map_Entry_AST {
				key   = cell.name,
				value = cell.value,
			}
		}
		return emit_map(emitter, Map_Literal{entries = entries})
	}
	if len(frob.cells) == 1 {
		return emit_expr(emitter, frob.cells[0].value)
	}
	elements := make([]^Expr, len(frob.cells), emitter.allocator)
	for cell, index in frob.cells {
		elements[index] = cell.value
	}
	return emit_list(emitter, List_Literal{elements = elements})
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
	emitter.loop_depth += 1
	defer emitter.loop_depth -= 1

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
	if len(loop.names) != 1 && len(loop.names) != 2 {
		push_error(emitter, "for loops take one or two bindings")
		return -1, false
	}

	iterable, iterable_ok := emit_expr(emitter, loop.iterable)
	if !iterable_ok {
		return -1, false
	}

	emitter.loop_depth += 1
	defer emitter.loop_depth -= 1

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
	if len(loop.names) == 2 {
		key_register := alloc_register(emitter)
		vm.builder_emit(
			emitter.builder,
			.Collection_Key_At,
			0,
			i32(key_register),
			i32(iterable),
			i32(index_register),
		)
		value_register := alloc_register(emitter)
		vm.builder_emit(
			emitter.builder,
			.Collection_Value_At,
			0,
			i32(value_register),
			i32(iterable),
			i32(index_register),
		)
		declare_local(emitter, loop.names[0], key_register, false)
		declare_local(emitter, loop.names[1], value_register, false)
	} else {
		item_register := alloc_register(emitter)
		vm.builder_emit(
			emitter.builder,
			.Collection_Value_At,
			0,
			i32(item_register),
			i32(iterable),
			i32(index_register),
		)
		declare_local(emitter, loop.names[0], item_register, false)
	}

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
		push_error(emitter, fmt.aprintf("unknown relation in assert or retract: %s", name, allocator = emitter.allocator))
		return -1, false
	}

	if !assert_write {
		has_wildcard := false
		for argument in call.args {
			if _, is_wildcard := argument.expr^.(Wildcard); is_wildcard {
				has_wildcard = true
				break
			}
		}
		if has_wildcard {
			return emit_retract_where(emitter, relation, call)
		}
	}

	heading := make([]v.Symbol, len(call.args), emitter.allocator)
	for index in 0 ..< len(heading) {
		builder: strings.Builder
		strings.builder_init(&builder, emitter.allocator)
		fmt.sbprintf(&builder, "column%d", index)
		heading[index] = v.symbol_intern(strings.to_string(builder))
	}
	shape := vm.builder_add_relation_shape(emitter.builder, heading)

	argument_registers := make([dynamic]int, 0, len(call.args), emitter.allocator)
	defer delete(argument_registers)
	for argument in call.args {
		if argument.has_role {
			push_error(emitter, "named-role relation atoms are not lowered yet")
			return -1, false
		}
		register, has_value := emit_expr(emitter, argument.expr)
		if !has_value {
			return -1, false
		}
		append(&argument_registers, register)
	}
	first_argument := marshal_arguments(emitter, argument_registers[:])

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

@(private)
emit_retract_where :: proc(
	emitter: ^Emitter,
	relation: u32,
	call: Call,
) -> (int, bool) {
	column_names := make([]v.Symbol, len(call.args), context.temp_allocator)
	cells := make([]vm.Pattern_Cell, len(call.args), context.temp_allocator)
	for argument, index in call.args {
		column_names[index] = v.symbol_intern(generated_column(index, emitter.allocator))
		if _, is_wildcard := argument.expr^.(Wildcard); is_wildcard {
			cells[index] = vm.Pattern_Cell{kind = .Wildcard}
			continue
		}
		register, has_value := emit_expr(emitter, argument.expr)
		if !has_value {
			return -1, false
		}
		cells[index] = vm.Pattern_Cell{kind = .Bind, operand = i32(register)}
	}
	pattern := vm.builder_add_pattern(emitter.builder, relation, column_names, cells)
	destination := alloc_register(emitter)
	vm.builder_emit(
		emitter.builder,
		.Retract_Where,
		0,
		i32(destination),
		pattern,
		0,
	)
	return destination, true
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
	first_argument := marshal_arguments(emitter, []int{receiver, symbol_register})
	destination := alloc_register(emitter)
	builtin := vm.builder_add_builtin(emitter.builder, v.symbol_intern("__get_field"))
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
