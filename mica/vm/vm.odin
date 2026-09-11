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
	// Commit the transaction and continue.
	Commit,
	// Suspend the task; it is runnable again immediately.
	Yield,
	// Suspend the task until at least `request_millis` have passed.
	Sleep,
	// Suspend the task and ask the host to start a child task described by
	// `request_spec`, then resume with the child's task id.
	Spawn,
	// Suspend the task and ask the host for a value.
	Host_Request,
	// Suspend the task until a message arrives on one of `request_value`'s
	// mailboxes, or until `request_millis` passes.
	Mailbox_Recv,
	// Suspend the task and ask the host to resolve `request_value` (a service
	// symbol) with `request_payload`.
	External_Request,
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

// A compiled exception handler: errors raised at or below `frame` jump to the
// absolute code offset `target` with the error delivered to `error_register`
// (-1 when the handler takes no value).
Handler :: struct {
	frame:          int,
	target:         i32,
	error_register: i32,
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
	// Sleep duration in milliseconds when `request == .Sleep`, or the child
	// start delay when `request == .Spawn`.
	request_millis: i64,
	// Dispatch spec index for a `.Spawn` request.
	request_spec: i32,
	// Primary request value: the receiver list for `.Mailbox_Recv`, or the
	// service symbol for `.External_Request`.
	request_value: v.Value,
	// Secondary request value: the payload for `.External_Request`.
	request_payload: v.Value,
	// Register (frame-relative) that receives the resume value.
	pending_resume: i32,
	// Active exception handlers, innermost last.
	handlers: [dynamic]Handler,
	// Free slot for host data, for example a builtin environment.
	user:        rawptr,
	// Values copied into the entry function's parameter registers before the
	// first run. The caller keeps them alive.
	entry_arguments: []v.Value,
	// When non-negative, the function index to start at instead of the program
	// entry. Used to start spawned method tasks.
	entry_function: i32,
}

vm_init :: proc(state: ^VM, program: ^Program, allocator := context.allocator) {
	state.program = program
	state.allocator = allocator
	state.registers = make([dynamic]v.Value)
	state.frames = make([dynamic]Frame)
	state.builtins = make([dynamic]VM_Builtin)
	state.request = .None
	state.request_spec = -1
	state.request_value = v.Value(0)
	state.request_payload = v.Value(0)
	state.pending_resume = -1
	state.entry_function = -1
	state.handlers = make([dynamic]Handler)
	state.result = v.value_empty_relation()
	state.error = v.value_empty_relation()
	state.status = .Ready
}

vm_destroy :: proc(state: ^VM) {
	delete(state.handlers)
	delete(state.registers)
	delete(state.frames)
	delete(state.builtins)
}

// Writes a resume value into the register the suspended instruction named.
// Does nothing when the suspension has no destination.
vm_resume_with :: proc(state: ^VM, value: v.Value) {
	if state.pending_resume < 0 || len(state.frames) == 0 {
		return
	}
	frame := state.frames[len(state.frames) - 1]
	state.registers[frame.register_base + int(state.pending_resume)] = value
	state.pending_resume = -1
}

// Starts execution at `function_index` instead of the program entry.
vm_set_entry_function :: proc(state: ^VM, function_index: i32) {
	state.entry_function = function_index
}

// Seeds the entry function's parameter registers.
vm_set_entry_arguments :: proc(state: ^VM, arguments: []v.Value) {
	state.entry_arguments = arguments
}

// Returns the frame-relative register base of the suspended frame.
vm_frame_base :: proc(state: ^VM) -> int {
	if len(state.frames) == 0 {
		return 0
	}
	return state.frames[len(state.frames) - 1].register_base
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
		state.request_spec = -1
		state.request_value = v.Value(0)
		state.request_payload = v.Value(0)
	}
	if state.status != .Ready {
		return state.status
	}

	program := state.program
	if len(state.frames) == 0 {
		entry := program.entry
		if state.entry_function >= 0 {
			entry = int(state.entry_function)
		}
		entry_function := program.functions[entry]
		append(&state.frames, Frame {
			function      = entry,
			ip            = entry_function.code_offset,
			register_base = 0,
			caller_base   = 0,
			caller_dst    = -1,
		})
		resize(&state.registers, entry_function.register_count)
		for argument, index in state.entry_arguments {
			state.registers[index] = argument
		}
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
				break
			}

		case .Unary:
			if !vm_unary(state, base, instr) {
				break
			}

		case .Branch:
			condition, is_bool := v.value_as_bool(state.registers[base + int(instr.a)])
			if !is_bool {
				vm_fail(state, "E_TYPE", "branch condition is not a boolean")
				break
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
				break
			}
			length_value, length_ok_value := v.value_int(i64(length))
			if !length_ok_value {
				vm_fail(state, "E_RANGE", "length does not fit an integer")
				break
			}
			state.registers[base + int(instr.a)] = length_value

		case .Scan_Collect:
			if !vm_scan_collect(state, base, instr) {
				break
			}

		case .Scan_Exists:
			if !vm_scan_exists(state, base, instr) {
				break
			}

		case .Scan_First:
			if !vm_scan_first(state, base, instr) {
				break
			}

		case .Assert:
			if !vm_apply_write(state, base, instr, true) {
				break
			}

		case .Retract:
			if !vm_apply_write(state, base, instr, false) {
				break
			}

		case .Retract_Where:
			if !vm_retract_where(state, base, instr) {
				break
			}

		case .Build_Relation:
			if !vm_build_relation(state, base, instr) {
				break
			}

		case .Index:
			if !vm_index(state, base, instr) {
				break
			}

		case .Collection_Key_At:
			if !vm_collection_key_at(state, base, instr) {
				break
			}

		case .Collection_Value_At:
			if !vm_collection_value_at(state, base, instr) {
				break
			}

		case .Builtin_Call:
			if !vm_builtin_call(state, base, instr) {
				break
			}

		case .Commit:
			state.request = .Commit
			state.status = .Boundary
			return .Boundary

		case .Yield:
			state.pending_resume = instr.a
			state.request = .Yield
			state.status = .Boundary
			return .Boundary

		case .Sleep:
			millis, is_int := v.value_as_int(state.registers[base + int(instr.b)])
			if !is_int || millis < 0 {
				vm_fail(state, "E_TYPE", "sleep duration must be a non-negative integer")
				break
			}
			state.pending_resume = instr.a
			state.request = .Sleep
			state.request_millis = millis
			state.status = .Boundary
			return .Boundary

		case .Raise:
			state.error = vm_raised_error(state, base, instr)
			state.status = .Failed
			break

		case .Push_Handler:
			append(&state.handlers, Handler {
				frame          = top,
				target         = instr.a,
				error_register = instr.b,
			})

		case .Pop_Handler:
			if len(state.handlers) > 0 {
				pop(&state.handlers)
			}

		case .Spawn:
			delay_millis := i64(0)
			if instr.flags & 1 != 0 {
				millis, is_int := v.value_as_int(state.registers[base + int(instr.c)])
				if !is_int || millis < 0 {
					vm_fail(state, "E_TYPE", "spawn delay must be a non-negative integer")
					break
				}
				delay_millis = millis
			}
			state.pending_resume = instr.a
			state.request = .Spawn
			state.request_spec = instr.b
			state.request_millis = delay_millis
			state.status = .Boundary
			return .Boundary

		case .Mailbox_Recv:
			receivers := state.registers[base + int(instr.b)]
			if _, is_list := v.value_as_list(receivers); !is_list {
				vm_fail(state, "E_TYPE", "mailbox_recv expects a list of receivers")
				break
			}
			timeout_millis := i64(-1)
			if instr.flags & 1 != 0 {
				millis, is_int := v.value_as_int(state.registers[base + int(instr.c)])
				if !is_int || millis < 0 {
					vm_fail(state, "E_TYPE", "mailbox_recv timeout must be a non-negative integer")
					break
				}
				timeout_millis = millis
			}
			state.pending_resume = instr.a
			state.request = .Mailbox_Recv
			state.request_value = receivers
			state.request_millis = timeout_millis
			state.status = .Boundary
			return .Boundary

		case .External_Request:
			service := state.registers[base + int(instr.b)]
			if _, is_symbol := v.value_as_symbol(service); !is_symbol {
				vm_fail(state, "E_TYPE", "external_request expects a service symbol")
				break
			}
			state.pending_resume = instr.a
			state.request = .External_Request
			state.request_value = service
			state.request_payload = state.registers[base + int(instr.c)]
			state.status = .Boundary
			return .Boundary

		case .Make_Function:
			function, function_ok := v.value_function_raw(u64(instr.b))
			if !function_ok {
				vm_fail(state, "E_TYPE", "function index is out of range")
				break
			}
			state.registers[base + int(instr.a)] = function

		case .Call_Value:
			target := state.registers[base + int(instr.b)]
			function_id, is_function := v.value_as_function(target)
			if !is_function {
				vm_fail(state, "E_TYPE", "call target is not a function")
				break
			}
			function_index := int(v.function_id_raw(function_id))
			if function_index < 0 || function_index >= len(program.functions) {
				vm_fail(state, "E_DISPATCH", "function index is invalid")
				break
			}
			callee := program.functions[function_index]
			callee_base := len(state.registers)
			resize(&state.registers, callee_base + callee.register_count)
			for index in 0 ..< callee.param_count {
				state.registers[callee_base + index] =
					state.registers[base + int(instr.c) + index]
			}
			append(&state.frames, Frame {
				function      = function_index,
				ip            = callee.code_offset,
				register_base = callee_base,
				caller_base   = base,
				caller_dst    = instr.a,
			})

		case .Is_Truthy:
			truthy := vm_value_is_truthy(state.registers[base + int(instr.b)])
			state.registers[base + int(instr.a)] = v.value_bool(truthy)

		case .Scan_One:
			if !vm_scan_one(state, base, instr) {
				break
			}

		case .Dispatch:
			if !vm_dispatch(state, base, instr) {
				break
			}

		case .Dynamic_Dispatch:
			if !vm_dynamic_dispatch(state, base, instr) {
				break
			}
		}

		if state.status == .Failed {
			if vm_unwind(state) {
				continue
			}
			return .Failed
		}
	}
}

// Transfers control to the innermost handler. Returns false when no handler
// exists and the error must escape the VM.
@(private)
vm_unwind :: proc(state: ^VM) -> bool {
	if len(state.handlers) == 0 {
		return false
	}
	handler := pop(&state.handlers)
	if handler.frame >= len(state.frames) {
		return false
	}
	resize(&state.frames, handler.frame + 1)
	frame := state.frames[handler.frame]
	state.frames[handler.frame].ip = int(handler.target)
	if handler.error_register >= 0 {
		state.registers[frame.register_base + int(handler.error_register)] = state.error
	}
	state.status = .Ready
	return true
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
vm_collection_key_at :: proc(state: ^VM, base: int, instr: Instruction) -> bool {
	collection := state.registers[base + int(instr.b)]
	index, is_int := v.value_as_int(state.registers[base + int(instr.c)])
	if !is_int || index < 0 {
		vm_fail(state, "E_TYPE", "collection index is not a non-negative integer")
		return false
	}

	#partial switch v.value_kind(collection) {
	case .List:
		values, _ := v.value_as_list(collection)
		if int(index) >= len(values) {
			vm_fail(state, "E_INDEX", "collection index out of range")
			return false
		}
		result, _ := v.value_int(index)
		state.registers[base + int(instr.a)] = result

	case .Map:
		entries, _ := v.value_as_map(collection)
		if int(index) >= len(entries) {
			vm_fail(state, "E_INDEX", "collection index out of range")
			return false
		}
		state.registers[base + int(instr.a)] = entries[index].key

	case .Relation:
		relation, _ := v.value_as_relation(collection)
		if int(index) >= len(relation.rows) {
			vm_fail(state, "E_INDEX", "collection index out of range")
			return false
		}
		result, _ := v.value_int(index)
		state.registers[base + int(instr.a)] = result

	case:
		vm_fail(state, "E_TYPE", "collection key iteration needs a list, map, or relation")
		return false
	}
	return true
}

@(private)
vm_collection_value_at :: proc(state: ^VM, base: int, instr: Instruction) -> bool {
	collection := state.registers[base + int(instr.b)]
	index, is_int := v.value_as_int(state.registers[base + int(instr.c)])
	if !is_int || index < 0 {
		vm_fail(state, "E_TYPE", "collection index is not a non-negative integer")
		return false
	}

	#partial switch v.value_kind(collection) {
	case .List:
		values, _ := v.value_as_list(collection)
		if int(index) >= len(values) {
			vm_fail(state, "E_INDEX", "collection index out of range")
			return false
		}
		state.registers[base + int(instr.a)] = values[index]

	case .Map:
		entries, _ := v.value_as_map(collection)
		if int(index) >= len(entries) {
			vm_fail(state, "E_INDEX", "collection index out of range")
			return false
		}
		state.registers[base + int(instr.a)] = entries[index].value

	case .Relation:
		relation, _ := v.value_as_relation(collection)
		if int(index) >= len(relation.rows) {
			vm_fail(state, "E_INDEX", "collection index out of range")
			return false
		}
		row := v.tuple_values(relation.rows[index])
		entries := make([]v.Map_Entry, len(relation.heading), context.temp_allocator)
		for column, column_index in relation.heading {
			entries[column_index] = v.Map_Entry {
				key   = v.value_symbol(column),
				value = row[column_index],
			}
		}
		state.registers[base + int(instr.a)] = v.value_map(state.allocator, entries)

	case:
		vm_fail(state, "E_TYPE", "collection value iteration needs a list, map, or relation")
		return false
	}
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
vm_dispatch :: proc(state: ^VM, base: int, instr: Instruction) -> bool {
	program := state.program
	spec := program.dispatch_specs[instr.b]
	selector := v.value_symbol(spec.selector)
	roles := make([]k.Role_Pair, len(spec.roles), context.temp_allocator)
	for role, index in spec.roles {
		roles[index] = k.Role_Pair {
			role  = v.value_symbol(role.role),
			value = state.registers[base + int(role.register)],
		}
	}
	return vm_dispatch_call(state, base, instr.a, selector, roles)
}

// Resolves a method for `selector` with `roles` and calls its function in this
// program. The destination register receives the method's return value.
@(private)
vm_dispatch_call :: proc(
	state: ^VM,
	base: int,
	destination: i32,
	selector: v.Value,
	roles: []k.Role_Pair,
) -> bool {
	program := state.program
	if state.source == nil {
		vm_fail(state, "E_NO_SOURCE", "dispatch has no relation source")
		return false
	}
	if program.dispatch_method_selector_relation == 0 ||
	   program.dispatch_param_relation == 0 ||
	   program.dispatch_delegates_relation == 0 ||
	   program.dispatch_method_program_relation == 0 {
		vm_fail(state, "E_DISPATCH", "dispatch relations are not configured")
		return false
	}

	relations := k.Dispatch_Relations {
		method_selector = k.Relation_ID(program.dispatch_method_selector_relation),
		param           = k.Relation_ID(program.dispatch_param_relation),
		delegates       = k.Relation_ID(program.dispatch_delegates_relation),
	}
	entries := k.applicable_method_entries(state.source, relations, selector, roles)
	if len(entries) == 0 {
		vm_fail(state, "E_DISPATCH", "no applicable method")
		return false
	}
	if len(entries) > 1 {
		vm_fail(state, "E_DISPATCH", "ambiguous method dispatch")
		return false
	}
	entry := entries[0]

	program_value, found := k.dispatch_method_program(
		state.source,
		k.Relation_ID(program.dispatch_method_program_relation),
		entry.method,
	)
	if !found {
		vm_fail(state, "E_DISPATCH", "method has no program")
		return false
	}
	function_index, is_int := v.value_as_int(program_value)
	if !is_int || function_index < 0 || int(function_index) >= len(program.functions) {
		vm_fail(state, "E_DISPATCH", "method program index is invalid")
		return false
	}

	args, args_ok := k.dispatch_method_args(entry.params, roles)
	if !args_ok {
		vm_fail(state, "E_DISPATCH", "method parameters cannot be bound")
		return false
	}

	callee := program.functions[function_index]
	callee_base := len(state.registers)
	resize(&state.registers, callee_base + callee.register_count)
	for index in 0 ..< min(callee.param_count, len(args)) {
		state.registers[callee_base + index] = args[index]
	}
	append(&state.frames, Frame {
		function      = int(function_index),
		ip            = callee.code_offset,
		register_base = callee_base,
		caller_base   = base,
		caller_dst    = destination,
	})
	return true
}

@(private)
vm_dynamic_dispatch :: proc(state: ^VM, base: int, instr: Instruction) -> bool {
	selector := state.registers[base + int(instr.b)]
	if _, is_symbol := v.value_as_symbol(selector); !is_symbol {
		vm_fail(state, "E_TYPE", "invoke selector is not a symbol")
		return false
	}
	entries, is_map := v.value_as_map(state.registers[base + int(instr.c)])
	if !is_map {
		vm_fail(state, "E_TYPE", "invoke roles are not a map")
		return false
	}
	roles := make([]k.Role_Pair, len(entries), context.temp_allocator)
	for entry, index in entries {
		role, is_symbol := v.value_as_symbol(entry.key)
		if !is_symbol {
			vm_fail(state, "E_TYPE", "invoke role name is not a symbol")
			return false
		}
		roles[index] = k.Role_Pair {
			role  = v.value_symbol(role),
			value = entry.value,
		}
	}
	return vm_dispatch_call(state, base, instr.a, selector, roles)
}

@(private)
vm_retract_where :: proc(state: ^VM, base: int, instr: Instruction) -> bool {
	if state.transaction == nil {
		vm_fail(state, "E_NO_TRANSACTION", "relation write has no transaction")
		return false
	}
	pattern := state.program.patterns[instr.b]
	rows: [dynamic]v.Tuple
	defer delete(rows)
	if !vm_scan_rows(state, base, pattern, &rows) {
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

// Builds the error value for a Raise instruction, mirroring the Rust VM:
// raising an existing error merges its message and value.
@(private)
vm_raised_error :: proc(state: ^VM, base: int, instr: Instruction) -> v.Value {
	raised := state.registers[base + int(instr.a)]

	has_message := false
	message: string
	if instr.b >= 0 {
		text, is_string := v.value_as_string(state.registers[base + int(instr.b)])
		if !is_string {
			vm_fail(state, "E_TYPE", "raise message is not a string")
			return state.error
		}
		message = text
		has_message = true
	}
	has_value := instr.c >= 0
	value := v.Value(0)
	if has_value {
		value = state.registers[base + int(instr.c)]
	}

	if code, is_code := v.value_as_error_code(raised); is_code {
		return v.value_error(state.allocator, code, message, has_message, value, has_value)
	}
	if existing, is_error := v.value_as_error(raised); is_error {
		return v.value_error(
			state.allocator,
			existing.code,
			has_message ? message : existing.message,
			has_message || existing.has_message,
			has_value ? value : existing.value,
			has_value || existing.has_value,
		)
	}
	vm_fail(state, "E_TYPE", "raise expects an error code or error value")
	return state.error
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
