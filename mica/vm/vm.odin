// Register virtual machine execution core.
//
// The VM runs a `Program` until the entry function returns or an operation
// fails. It executes one instruction at a time, with a frame stack and a flat
// register window per active call. Host boundaries such as commit, dispatch,
// and builtin calls are added on top of this core.
package vm

import "core:mem"
import v "../var"

VM_Status :: enum {
	Ready,
	Halted,
	Failed,
}

Frame :: struct {
	function:      int,
	ip:            int,
	register_base: int,
	caller_base:   int,
	caller_dst:    i32,
}

VM :: struct {
	program:   ^Program,
	allocator: mem.Allocator,
	registers: [dynamic]v.Value,
	frames:    [dynamic]Frame,
	result:    v.Value,
	error:     v.Value,
	status:    VM_Status,
}

vm_init :: proc(state: ^VM, program: ^Program, allocator := context.allocator) {
	state.program = program
	state.allocator = allocator
	state.registers = make([dynamic]v.Value)
	state.frames = make([dynamic]Frame)
	state.result = v.value_empty_relation()
	state.error = v.value_empty_relation()
	state.status = .Ready
}

vm_destroy :: proc(state: ^VM) {
	delete(state.registers)
	delete(state.frames)
}

// Runs the program from its entry function until it returns. Read
// `state.result` on success and `state.error` on failure.
vm_run :: proc(state: ^VM) -> VM_Status {
	if state.status != .Ready {
		return state.status
	}

	program := state.program
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
		}
	}
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

@(private)
vm_fail :: proc(state: ^VM, code: string, message: string) {
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
