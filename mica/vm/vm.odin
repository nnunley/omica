// Register virtual machine execution core.
//
// The VM runs a `Program` until the entry function returns or an operation
// fails. It executes one instruction at a time, with a frame stack and a flat
// register window per active call. Host boundaries such as commit, dispatch,
// and builtin calls are added on top of this core.
package vm

import "core:mem"
import k "../kernel"
import v "../var"

VM_Status :: enum {
	Ready,
	Halted,
	Failed,
	// The VM stopped at a host boundary; inspect `request`, act, and call
	// `vm_run` again to continue.
	Boundary,
}

// A request from the VM to its host.
VM_Request :: enum {
	None,
	Commit,
}

// A builtin procedure. It returns false after recording an error with
// `vm_set_error`.
Builtin_Proc :: proc(state: ^VM, args: []v.Value) -> (v.Value, bool)

VM_Builtin :: struct {
	name: v.Symbol,
	argc: int,
	run:  Builtin_Proc,
}

Frame :: struct {
	function:      int,
	ip:            int,
	register_base: int,
	caller_base:   int,
	caller_dst:    i32,
}

VM :: struct {
	program:     ^Program,
	allocator:   mem.Allocator,
	registers:   [dynamic]v.Value,
	frames:      [dynamic]Frame,
	result:      v.Value,
	error:       v.Value,
	status:      VM_Status,
	source:      ^k.Relation_Source,
	transaction: ^k.Transaction,
	builtins:    [dynamic]VM_Builtin,
	request:     VM_Request,
	// Free slot for host data, for example a builtin environment.
	user:        rawptr,
}

vm_init :: proc(state: ^VM, program: ^Program, allocator := context.allocator) {
	state.program = program
	state.allocator = allocator
	state.registers = make([dynamic]v.Value)
	state.frames = make([dynamic]Frame)
	state.builtins = make([dynamic]VM_Builtin)
	state.request = .None
	state.result = v.value_empty_relation()
	state.error = v.value_empty_relation()
	state.status = .Ready
}

vm_destroy :: proc(state: ^VM) {
	delete(state.registers)
	delete(state.frames)
	delete(state.builtins)
}

// Registers a builtin procedure under `name`. Returns its index.
vm_register_builtin :: proc(
	state: ^VM,
	name: v.Symbol,
	argc: int,
	run: Builtin_Proc,
) -> int {
	append(&state.builtins, VM_Builtin{name = name, argc = argc, run = run})
	return len(state.builtins) - 1
}

// Sets the relation read source and write transaction for relation
// instructions. Either may be nil when the program does not use them.
vm_set_workspace :: proc(
	state: ^VM,
	source: ^k.Relation_Source,
	transaction: ^k.Transaction,
) {
	state.source = source
	state.transaction = transaction
}

// Runs the program from its entry function until it returns. Read
// `state.result` on success and `state.error` on failure.
vm_run :: proc(state: ^VM) -> VM_Status {
	if state.status == .Boundary {
		state.status = .Ready
		state.request = .None
	}
	if state.status != .Ready {
		return state.status
	}

	program := state.program
	if len(state.frames) == 0 {
		entry := program.entry
		entry_function := program.functions[entry]
		append(&state.frames, Frame {
			function      = entry,
			ip            = entry_function.code_offset,
			register_base = 0,
			caller_base   = 0,
			caller_dst    = -1,
		})
		resize(&state.registers, entry_function.register_count)
	}

	for {
		top := len(state.frames) - 1
		frame := state.frames[top]
		if frame.ip < 0 || frame.ip >= len(program.code) {
			vm_fail(state, "E_VM_FAULT", "instruction pointer out of range")
			return .Failed
		}

		instr := program.code[frame.ip]
		state.frames[top].ip = frame.ip + 1
		base := frame.register_base

		switch instr.op {
		case .Load_Const:
			state.registers[base + int(instr.a)] = program.constants[instr.b]

		case .Move:
			state.registers[base + int(instr.a)] = state.registers[base + int(instr.b)]

		case .Binary:
			if !vm_binary(state, base, instr) {
				return .Failed
			}

		case .Unary:
			if !vm_unary(state, base, instr) {
				return .Failed
			}

		case .Branch:
			condition, is_bool := v.value_as_bool(state.registers[base + int(instr.a)])
			if !is_bool {
				vm_fail(state, "E_TYPE", "branch condition is not a boolean")
				return .Failed
			}
			if condition {
				state.frames[top].ip += int(instr.b)
			}

		case .Jump:
			state.frames[top].ip += int(instr.b)

		case .Call:
			callee := program.functions[instr.b]
			callee_base := len(state.registers)
			resize(&state.registers, callee_base + callee.register_count)
			for index in 0 ..< callee.param_count {
				state.registers[callee_base + index] =
					state.registers[base + int(instr.c) + index]
			}
			append(&state.frames, Frame {
				function      = int(instr.b),
				ip            = callee.code_offset,
				register_base = callee_base,
				caller_base   = base,
				caller_dst    = instr.a,
			})

		case .Return:
			value := state.registers[base + int(instr.a)]
			returned := pop(&state.frames)
			resize(&state.registers, base)
			if len(state.frames) == 0 {
				state.result = value
				state.status = .Halted
				return .Halted
			}
			caller := state.frames[len(state.frames) - 1]
			state.registers[caller.register_base + int(returned.caller_dst)] = value

		case .Build_List:
			count := int(instr.c)
			items := make([]v.Value, count, context.temp_allocator)
			for index in 0 ..< count {
				items[index] = state.registers[base + int(instr.b) + index]
			}
			state.registers[base + int(instr.a)] = v.value_list(state.allocator, items)

		case .Build_Map:
			count := int(instr.c)
			entries := make([]v.Map_Entry, count, context.temp_allocator)
			for index in 0 ..< count {
				entries[index] = v.Map_Entry {
					key   = state.registers[base + int(instr.b) + index * 2],
					value = state.registers[base + int(instr.b) + index * 2 + 1],
				}
			}
			state.registers[base + int(instr.a)] = v.value_map(state.allocator, entries)

		case .Build_Range:
			has_end := (instr.flags & 1) != 0
			start := state.registers[base + int(instr.b)]
			end := state.registers[base + int(instr.c)]
			state.registers[base + int(instr.a)] = v.value_range(
				state.allocator,
				start,
				end,
				has_end,
			)

		case .Len:
			collection := state.registers[base + int(instr.b)]
			length: int
			length_ok: bool
			#partial switch v.value_kind(collection) {
			case .List:
				values, ok := v.value_as_list(collection)
				if ok {
					length = len(values)
					length_ok = true
				}
			case .Map:
				entries, ok := v.value_as_map(collection)
				if ok {
					length = len(entries)
					length_ok = true
				}
			case .Relation:
				relation, ok := v.value_as_relation(collection)
				if ok {
					length = len(relation.rows)
					length_ok = true
				}
			case:
			}
			if !length_ok {
				vm_fail(state, "E_TYPE", "len expects a list, map, or relation")
				return .Failed
			}
			length_value, length_ok_value := v.value_int(i64(length))
			if !length_ok_value {
				vm_fail(state, "E_RANGE", "length does not fit an integer")
				return .Failed
			}
			state.registers[base + int(instr.a)] = length_value

		case .Scan_Collect:
			if !vm_scan_collect(state, base, instr) {
				return .Failed
			}

		case .Scan_Exists:
			if !vm_scan_exists(state, base, instr) {
				return .Failed
			}

		case .Scan_First:
			if !vm_scan_first(state, base, instr) {
				return .Failed
			}

		case .Assert:
			if !vm_apply_write(state, base, instr, true) {
				return .Failed
			}

		case .Retract:
			if !vm_apply_write(state, base, instr, false) {
				return .Failed
			}

		case .Retract_Where:
			if !vm_retract_where(state, instr) {
				return .Failed
			}

		case .Build_Relation:
			if !vm_build_relation(state, base, instr) {
				return .Failed
			}

		case .Index:
			if !vm_index(state, base, instr) {
				return .Failed
			}

		case .Builtin_Call:
			if !vm_builtin_call(state, base, instr) {
				return .Failed
			}

		case .Commit:
			state.request = .Commit
			state.status = .Boundary
			return .Boundary

		case .Is_Truthy:
			truthy := vm_value_is_truthy(state.registers[base + int(instr.b)])
			state.registers[base + int(instr.a)] = v.value_bool(truthy)

		case .Scan_One:
			if !vm_scan_one(state, base, instr) {
				return .Failed
			}
		}
	}
}

@(private)
vm_build_relation :: proc(state: ^VM, base: int, instr: Instruction) -> bool {
	shape := state.program.relation_shapes[instr.b]
	values := make([]v.Value, len(shape.heading), context.temp_allocator)
	for index in 0 ..< len(values) {
		values[index] = state.registers[base + int(instr.c) + index]
	}
	row := v.tuple_new(state.allocator, values)
	result, err := v.value_relation(state.allocator, shape.heading, []v.Tuple{row})
	if err != .None {
		vm_fail(state, "E_RELATION", "relation heading is invalid")
		return false
	}
	state.registers[base + int(instr.a)] = result
	return true
}

@(private)
vm_index :: proc(state: ^VM, base: int, instr: Instruction) -> bool {
	collection := state.registers[base + int(instr.b)]
	key := state.registers[base + int(instr.c)]
	result: v.Value

	#partial switch v.value_kind(collection) {
	case .List:
		index, is_int := v.value_as_int(key)
		if !is_int {
			vm_fail(state, "E_TYPE", "list index is not an integer")
			return false
		}
		values, _ := v.value_as_list(collection)
		if index < 0 || int(index) >= len(values) {
			vm_fail(state, "E_INDEX", "list index out of range")
			return false
		}
		result = values[index]

	case .Map:
		entries, _ := v.value_as_map(collection)
		found := false
		for entry in entries {
			if v.value_eq(entry.key, key) {
				result = entry.value
				found = true
				break
			}
		}
		if !found {
			vm_fail(state, "E_KEY", "map key is not present")
			return false
		}

	case .Relation:
		relation, _ := v.value_as_relation(collection)

		if row_index, is_int := v.value_as_int(key); is_int {
			if row_index < 0 || int(row_index) >= len(relation.rows) {
				vm_fail(state, "E_INDEX", "relation row index out of range")
				return false
			}
			row := relation.rows[row_index]
			entries := make([]v.Map_Entry, len(relation.heading), context.temp_allocator)
			for column, index in relation.heading {
				entries[index] = v.Map_Entry {
					key   = v.value_symbol(column),
					value = v.tuple_values(row)[index],
				}
			}
			state.registers[base + int(instr.a)] = v.value_map(state.allocator, entries)
			return true
		}

		symbol, is_symbol := v.value_as_symbol(key)
		if !is_symbol {
			vm_fail(state, "E_TYPE", "relation column key is not a symbol")
			return false
		}
		position := -1
		for column, index in relation.heading {
			if column == symbol {
				position = index
				break
			}
		}
		if position < 0 {
			vm_fail(state, "E_KEY", "relation column is not present")
			return false
		}
		if len(relation.rows) == 0 {
			result = v.value_list(state.allocator, nil)
		} else if len(relation.rows) == 1 {
			result = v.tuple_values(relation.rows[0])[position]
		} else {
			cells := make([]v.Value, len(relation.rows), context.temp_allocator)
			for row, index in relation.rows {
				cells[index] = v.tuple_values(row)[position]
			}
			result = v.value_list(state.allocator, cells)
		}

	case:
		vm_fail(state, "E_TYPE", "index expects a list, map, or relation")
		return false
	}

	state.registers[base + int(instr.a)] = result
	return true
}

@(private)
vm_builtin_call :: proc(state: ^VM, base: int, instr: Instruction) -> bool {
	name := state.program.builtins[instr.b]
	for builtin in state.builtins {
		if builtin.name != name {
			continue
		}
		argc := builtin.argc
		if argc < 0 {
			argc = int(instr.flags)
		}
		args := make([]v.Value, argc, context.temp_allocator)
		for index in 0 ..< argc {
			args[index] = state.registers[base + int(instr.c) + index]
		}
		result, ok := builtin.run(state, args)
		if !ok {
			if state.error == v.value_empty_relation() {
				vm_fail(state, "E_BUILTIN", "builtin failed")
			}
			return false
		}
		state.registers[base + int(instr.a)] = result
		return true
	}
	vm_fail(state, "E_UNKNOWN_BUILTIN", "builtin is not registered")
	return false
}

@(private)
vm_pattern_bindings :: proc(
	state: ^VM,
	base: int,
	pattern: Scan_Pattern,
	alloc: mem.Allocator,
) -> []v.Binding {
	bindings := make([]v.Binding, len(pattern.cells), alloc)
	for cell, index in pattern.cells {
		switch cell.kind {
		case .Const:
			bindings[index] = v.binding_of(state.program.constants[cell.operand])
		case .Bind:
			bindings[index] = v.binding_of(state.registers[base + int(cell.operand)])
		case .Output, .Wildcard:
		}
	}
	return bindings
}

@(private)
vm_scan_rows :: proc(
	state: ^VM,
	base: int,
	pattern: Scan_Pattern,
	out: ^[dynamic]v.Tuple,
) -> bool {
	if state.source == nil {
		vm_fail(state, "E_NO_SOURCE", "relation scan has no source")
		return false
	}
	bindings := vm_pattern_bindings(state, base, pattern, context.temp_allocator)
	k.relation_source_scan_into(state.source, k.Relation_ID(pattern.relation), bindings, out)
	return true
}

@(private)
vm_scan_collect :: proc(state: ^VM, base: int, instr: Instruction) -> bool {
	pattern := state.program.patterns[instr.b]
	rows: [dynamic]v.Tuple
	defer delete(rows)
	if !vm_scan_rows(state, base, pattern, &rows) {
		return false
	}
	result, err := v.value_relation(state.allocator, pattern.column_names, rows[:])
	if err != .None {
		vm_fail(state, "E_RELATION", "scan result columns are invalid")
		return false
	}
	state.registers[base + int(instr.a)] = result
	return true
}

@(private)
First_Binding_Context :: struct {
	vm:      ^VM,
	base:    int,
	pattern: ^Scan_Pattern,
	found:   bool,
}

@(private)
first_binding_visit :: proc(user: rawptr, row: v.Tuple) -> bool {
	ctx := (^First_Binding_Context)(user)
	for cell, index in ctx.pattern.cells {
		if cell.kind == .Output {
			ctx.vm.registers[ctx.base + int(cell.operand)] = v.tuple_values(row)[index]
		}
	}
	ctx.found = true
	return false
}

@(private)
vm_scan_first :: proc(state: ^VM, base: int, instr: Instruction) -> bool {
	if state.source == nil {
		vm_fail(state, "E_NO_SOURCE", "relation scan has no source")
		return false
	}
	pattern := state.program.patterns[instr.b]
	bindings := vm_pattern_bindings(state, base, pattern, context.temp_allocator)
	ctx := First_Binding_Context {
		vm      = state,
		base    = base,
		pattern = &pattern,
	}
	k.relation_source_visit(state.source, k.Relation_ID(pattern.relation), bindings, first_binding_visit, &ctx)
	state.registers[base + int(instr.a)] = v.value_bool(ctx.found)
	return true
}

@(private)
vm_scan_exists :: proc(state: ^VM, base: int, instr: Instruction) -> bool {
	pattern := state.program.patterns[instr.b]
	rows: [dynamic]v.Tuple
	defer delete(rows)
	if !vm_scan_rows(state, base, pattern, &rows) {
		return false
	}
	state.registers[base + int(instr.a)] = v.value_bool(len(rows) > 0)
	return true
}

@(private)
vm_scan_one :: proc(state: ^VM, base: int, instr: Instruction) -> bool {
	pattern := state.program.patterns[instr.b]
	rows: [dynamic]v.Tuple
	defer delete(rows)
	if !vm_scan_rows(state, base, pattern, &rows) {
		return false
	}
	if len(rows) != 1 {
		vm_fail(state, "E_ONE", "exactly one row is required")
		return false
	}
	for cell, index in pattern.cells {
		if cell.kind == .Output {
			state.registers[base + int(cell.operand)] = v.tuple_values(rows[0])[index]
		}
	}
	state.registers[base + int(instr.a)] = v.value_bool(true)
	return true
}

// Truthiness used by `if`, `&&`, and `||`: false and the empty option and
// relation values are falsy; everything else is truthy.
vm_value_is_truthy :: proc(value: v.Value) -> bool {
	if boolean, ok := v.value_as_bool(value); ok {
		return boolean
	}
	if v.value_is_empty_relation(value) {
		return false
	}
	if relation, ok := v.value_as_relation(value); ok {
		return len(relation.rows) > 0
	}
	return true
}

@(private)
vm_apply_write :: proc(
	state: ^VM,
	base: int,
	instr: Instruction,
	assert_write: bool,
) -> bool {
	if state.transaction == nil {
		vm_fail(state, "E_NO_TRANSACTION", "relation write has no transaction")
		return false
	}
	value := state.registers[base + int(instr.b)]
	relation, ok := v.value_as_relation(value)
	if !ok || len(relation.rows) != 1 {
		vm_fail(state, "E_TYPE", "relation write expects a single-row relation value")
		return false
	}
	tuple := relation.rows[0]
	relation_id := k.Relation_ID(u32(instr.a))
	err: k.Kernel_Error
	if assert_write {
		err = k.transaction_assert(state.transaction, relation_id, tuple)
	} else {
		err = k.transaction_retract(state.transaction, relation_id, tuple)
	}
	if err != .None {
		vm_fail(state, kernel_error_code(err), "relation write failed")
		return false
	}
	return true
}

@(private)
vm_retract_where :: proc(state: ^VM, instr: Instruction) -> bool {
	if state.transaction == nil {
		vm_fail(state, "E_NO_TRANSACTION", "relation write has no transaction")
		return false
	}
	pattern := state.program.patterns[instr.b]
	rows: [dynamic]v.Tuple
	defer delete(rows)
	if !vm_scan_rows(state, 0, pattern, &rows) {
		return false
	}
	for row in rows {
		err := k.transaction_retract(
			state.transaction,
			k.Relation_ID(pattern.relation),
			row,
		)
		if err != .None {
			vm_fail(state, kernel_error_code(err), "relation retract failed")
			return false
		}
	}
	return true
}

@(private)
kernel_error_code :: proc(err: k.Kernel_Error) -> string {
	switch err {
	case .Unknown_Relation:
		return "E_UNKNOWN_RELATION"
	case .Arity_Mismatch:
		return "E_ARITY"
	case .Non_Persistent_Value:
		return "E_NOT_PERSISTENT"
	case .Functional_Key_Violation:
		return "E_FUNCTIONAL_KEY"
	case .Read_Only:
		return "E_READ_ONLY"
	case .Conflict:
		return "E_CONFLICT"
	case .Duplicate_Relation_Name, .Invalid_Metadata:
		return "E_METADATA"
	case .No_Such_Rule, .Unstratified_Negation, .Unsafe_Negation, .Unsafe_Guard, .Unbound_Head_Variable:
		return "E_RULE"
	case .None:
		return "E_NONE"
	}
	return "E_KERNEL"
}

@(private)
vm_binary :: proc(state: ^VM, base: int, instr: Instruction) -> bool {
	left := state.registers[base + int(instr.b)]
	right := state.registers[base + int(instr.c)]
	op := Bin_Op(instr.flags)

	result: v.Value
	ok: bool
	switch op {
	case .Add:
		result, ok = v.value_checked_add(left, right)
	case .Sub:
		result, ok = v.value_checked_sub(left, right)
	case .Mul:
		result, ok = v.value_checked_mul(left, right)
	case .Div:
		result, ok = v.value_checked_div(left, right)
	case .Rem:
		result, ok = v.value_checked_rem(left, right)
	case .Eq:
		result = v.value_bool(v.language_numeric_eq(left, right))
		ok = true
	case .Ne:
		result = v.value_bool(!v.language_numeric_eq(left, right))
		ok = true
	case .Lt:
		result = v.value_bool(v.language_numeric_cmp(left, right) == .Less)
		ok = true
	case .Le:
		order := v.language_numeric_cmp(left, right)
		result = v.value_bool(order == .Less || order == .Equal)
		ok = true
	case .Gt:
		result = v.value_bool(v.language_numeric_cmp(left, right) == .Greater)
		ok = true
	case .Ge:
		order := v.language_numeric_cmp(left, right)
		result = v.value_bool(order == .Greater || order == .Equal)
		ok = true
	}

	if !ok {
		vm_fail(state, "E_ARITHMETIC", "arithmetic operation failed")
		return false
	}
	state.registers[base + int(instr.a)] = result
	return true
}

@(private)
vm_unary :: proc(state: ^VM, base: int, instr: Instruction) -> bool {
	source := state.registers[base + int(instr.b)]
	op := Un_Op(instr.flags)

	switch op {
	case .Neg:
		result, ok := v.value_checked_neg(source)
		if !ok {
			vm_fail(state, "E_ARITHMETIC", "negation failed")
			return false
		}
		state.registers[base + int(instr.a)] = result
	case .Not:
		boolean, ok := v.value_as_bool(source)
		if !ok {
			vm_fail(state, "E_TYPE", "not expects a boolean")
			return false
		}
		state.registers[base + int(instr.a)] = v.value_bool(!boolean)
	}
	return true
}

// Records an error and marks the VM failed. Available to builtins.
vm_set_error :: proc(state: ^VM, code: string, message: string) {
	state.error = v.value_error(
		state.allocator,
		v.symbol_intern(code),
		message,
		true,
		v.Value(0),
		false,
	)
	state.status = .Failed
}

@(private)
vm_fail :: proc(state: ^VM, code: string, message: string) {
	vm_set_error(state, code, message)
}
