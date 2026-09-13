// Register virtual machine execution core.
//
// The VM runs a `Program` until the entry function returns or an operation
// fails. It executes one instruction at a time, with a frame stack and a flat
// register window per active call. Host boundaries such as commit, dispatch,
// and builtin calls are added on top of this core.
package vm

import "core:fmt"
import "core:mem"
import "core:mem/virtual"
import "core:strings"
import "core:sync"
import "core:time"
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
// (-1 when the handler takes no value). A Finally handler also intercepts
// returns so the finally body runs before the frame is popped.
Handler_Kind :: enum {
	Catch,
	Finally,
}

Handler :: struct {
	frame:          int,
	target:         i32,
	error_register: i32,
	kind:           Handler_Kind,
	// A catch-body finally routes exceptions through itself before they
	// propagate outward; a try-body finally only intercepts returns.
	routes_exceptions: bool,
}

// A return diverted through a finally body.
Pending_Return :: struct {
	frame: int,
	value: v.Value,
}

// An exception diverted through a finally body, re-raised when the finally
// body completes.
Pending_Raise :: struct {
	frame: int,
	error: v.Value,
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
	// Returns diverted through a finally body, innermost last.
	pending_returns: [dynamic]Pending_Return,
	pending_raises:  [dynamic]Pending_Raise,
	// Execution limits. Zero means unlimited.
	max_call_depth:     int,
	instruction_budget: u64,
	// Set once the budget reaches zero, so a caught E_BUDGET cannot silently
	// turn the exhausted budget (0) into "unlimited".
	instruction_budget_exhausted: bool,
	// Runtime context identities: endpoint, actor, and principal.
	endpoint:  v.Value,
	actor:     v.Value,
	principal: v.Value,
	// Task authority. Nil means root access.
	authority: ^k.Authority,
	// Optional validator run before a Mailbox_Recv suspends, so an invalid
	// receiver fails inside the interpreter and can be caught.
	mailbox_validator:      proc(user: rawptr, receivers: []v.Value) -> bool,
	mailbox_validator_user: rawptr,
	// Free slot for host data, for example a builtin environment.
	user:        rawptr,
	// Values copied into the entry function's parameter registers before the
	// first run. The caller keeps them alive.
	entry_arguments: []v.Value,
	// When non-negative, the function index to start at instead of the program
	// entry. Used to start spawned method tasks.
	entry_function: i32,
	// The owning task, when the VM runs as part of one. Used by task-scoped
	// builtins to stage effects until the task commits.
	owner: rawptr,
	// VM-local scratch arena for per-instruction temporaries. Reset at the top
	// of each instruction so a long-running task does not grow the thread's
	// temp arena without bound.
	scratch:           ^virtual.Arena,
	scratch_allocator: mem.Allocator,
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
	state.max_call_depth = DEFAULT_MAX_CALL_DEPTH
	state.entry_function = -1
	state.handlers = make([dynamic]Handler)
	state.pending_returns = make([dynamic]Pending_Return)
	state.pending_raises = make([dynamic]Pending_Raise)
	state.result = v.value_empty_relation()
	state.error = v.value_empty_relation()
	state.status = .Ready
	state.scratch = new(virtual.Arena, allocator)
	if init_error := virtual.arena_init_growing(state.scratch); init_error != nil {
		panic("failed to initialize VM scratch arena")
	}
	state.scratch_allocator = virtual.arena_allocator(state.scratch)
}

vm_destroy :: proc(state: ^VM) {
	delete(state.pending_returns)
	delete(state.pending_raises)
	delete(state.handlers)
	delete(state.registers)
	delete(state.frames)
	delete(state.builtins)
	if state.scratch != nil {
		virtual.arena_destroy(state.scratch)
		free(state.scratch, state.allocator)
		state.scratch = nil
	}
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

// Default nesting limit for call frames.
DEFAULT_MAX_CALL_DEPTH :: 1024

// Limits the number of nested call frames. Zero means unlimited.
vm_set_max_call_depth :: proc(state: ^VM, depth: int) {
	state.max_call_depth = depth
}

// Limits how many instructions the VM may execute before failing. The budget
// is not reset by boundaries. Zero means unlimited; exceeding a positive budget
// fails even if the task catches `E_BUDGET`.
vm_set_instruction_budget :: proc(state: ^VM, budget: u64) {
	state.instruction_budget = budget
	state.instruction_budget_exhausted = false
}

// Sets the authority used for permission checks. Nil means root access.
vm_set_authority :: proc(state: ^VM, authority: ^k.Authority) {
	state.authority = authority
}

// Sets the runtime context identities returned by `endpoint`, `actor`, and
// `principal`.
vm_set_identities :: proc(
	state: ^VM,
	endpoint: v.Value,
	actor: v.Value,
	principal: v.Value,
) {
	state.endpoint = endpoint
	state.actor = actor
	state.principal = principal
}

// Registers a validator for mailbox receiver lists. It returns false when no
// receiver is a live mailbox handle.
vm_set_mailbox_validator :: proc(
	state: ^VM,
	validator: proc(user: rawptr, receivers: []v.Value) -> bool,
	user: rawptr,
) {
	state.mailbox_validator = validator
	state.mailbox_validator_user = user
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
	if state.authority != nil {
		epoch: u64 = 0
		if state.transaction != nil {
			epoch = state.transaction.base.version
		}
		k.authority_set_clock(state.authority, epoch, time.tick_now())
	}

	program := state.program
	if len(state.frames) == 0 {
		entry := program.entry
		if state.entry_function >= 0 {
			entry = int(state.entry_function)
		}
		// A hand-built program or a bogus entry override must fail cleanly,
		// not index past the function table. Compiler output always passes
		// program_validate before running.
		if entry < 0 || entry >= len(program.functions) {
			vm_fail(state, "E_VM_FAULT", "entry function out of range")
			return .Failed
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
		if len(state.entry_arguments) > len(state.registers) {
			vm_fail(state, "E_VM_FAULT", "too many entry arguments")
			return .Failed
		}
		for argument, index in state.entry_arguments {
			state.registers[index] = argument
		}
	}

	for {
		// Per-instruction temporaries live in the VM scratch arena. Reclaim
		// them only when the arena was actually used: freeing unconditionally
		// takes an arena mutex and zeroes memory on every instruction, which
		// dominated simple integer loops.
		if state.scratch.total_used > 0 {
			virtual.arena_free_all(state.scratch)
		}
		top := len(state.frames) - 1
		frame := state.frames[top]
		if frame.ip < 0 || frame.ip >= len(program.code) {
			vm_fail(state, "E_VM_FAULT", "instruction pointer out of range")
			return .Failed
		}

		if state.instruction_budget_exhausted {
			vm_fail(state, "E_BUDGET", "instruction budget exhausted")
			if vm_unwind(state) {
				continue
			}
			return .Failed
		}
		if state.instruction_budget > 0 {
			state.instruction_budget -= 1
			if state.instruction_budget == 0 {
				state.instruction_budget_exhausted = true
				vm_fail(state, "E_BUDGET", "instruction budget exhausted")
				if vm_unwind(state) {
					continue
				}
				return .Failed
			}
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
			if vm_truthy(state.registers[base + int(instr.a)]) {
				state.frames[top].ip += int(instr.b)
			}

		case .Jump:
			state.frames[top].ip += int(instr.b)

		case .Call:
			if vm_depth_exceeded(state) {
				break
			}
			callee := program.functions[instr.b]
			argument_count := int(instr.flags)
			args := make([]v.Value, argument_count, state.scratch_allocator)
			for index in 0 ..< argument_count {
				args[index] = state.registers[base + int(instr.c) + index]
			}
			callee_base := len(state.registers)
			resize(&state.registers, callee_base + callee.register_count)
			if !vm_bind_params(state, callee, args, callee_base) {
				break
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
			if handler_index := vm_finally_handler(state, top); handler_index >= 0 {
				handler := state.handlers[handler_index]
				ordered_remove(&state.handlers, handler_index)
				append(&state.pending_returns, Pending_Return {
					frame = top,
					value = value,
				})
				state.frames[top].ip = int(handler.target)
				break
			}
			vm_remove_frame_handlers(state, top)
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
			items := make([]v.Value, count, state.scratch_allocator)
			for index in 0 ..< count {
				items[index] = state.registers[base + int(instr.b) + index]
			}
			state.registers[base + int(instr.a)] = v.value_list(state.allocator, items)

		case .Build_Map:
			count := int(instr.c)
			entries := make([]v.Map_Entry, count, state.scratch_allocator)
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
			receiver_list, is_list := v.value_as_list(receivers)
			if !is_list {
				vm_fail(state, "E_TYPE", "mailbox_recv expects a list of receivers")
				break
			}
			if state.mailbox_validator != nil &&
			   !state.mailbox_validator(state.mailbox_validator_user, receiver_list) {
				vm_fail(state, "E_INVARG", "mailbox has no live receivers")
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
			if !k.authority_can_effect(state.authority) {
				vm_fail(state, "E_PERMISSION", "effect denied")
				break
			}
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

		case .Read:
			state.pending_resume = instr.a
			state.request = .Host_Request
			if instr.b >= 0 {
				state.request_value = state.registers[base + int(instr.b)]
			} else {
				state.request_value = v.Value(0)
			}
			state.request_millis = 0
			state.status = .Boundary
			return .Boundary

		case .Make_Self_Function:
			capture_count := int(instr.flags)
			if capture_count == 0 {
				vm_fail(state, "E_VM_FAULT", "self function needs a capture slot")
				break
			}
			captures := make([]v.Value, capture_count, state.allocator)
			for index in 0 ..< capture_count {
				captures[index] = state.registers[base + int(instr.c) + index]
			}
			captures[capture_count - 1] = v.Value(0)
			sync.mutex_lock(&program.callables_mutex)
			callable_id := i32(len(program.callables))
			append(&program.callables, Callable_Info {
				function = instr.b,
				captures = captures,
			})
			value, value_ok := v.value_function_raw(u64(callable_id))
			if value_ok {
				program.callables[int(callable_id)].captures[capture_count - 1] = value
			}
			sync.mutex_unlock(&program.callables_mutex)
			if !value_ok {
				vm_fail(state, "E_TYPE", "callable index is out of range")
				break
			}
			state.registers[base + int(instr.a)] = value

		case .Make_Function:
			if instr.b < 0 || int(instr.b) >= len(program.functions) {
				vm_fail(state, "E_TYPE", "function index is out of range")
				break
			}
			capture_count := int(instr.flags)
			captures := make([]v.Value, capture_count, state.allocator)
			for index in 0 ..< capture_count {
				captures[index] = state.registers[base + int(instr.c) + index]
			}
			callable_id := vm_intern_callable(state, instr.b, captures)
			function, function_ok := v.value_function_raw(u64(callable_id))
			if !function_ok {
				vm_fail(state, "E_TYPE", "callable index is out of range")
				break
			}
			state.registers[base + int(instr.a)] = function

		case .Call_Value:
			if vm_depth_exceeded(state) {
				break
			}
			target := state.registers[base + int(instr.b)]
			function_id, is_function := v.value_as_function(target)
			if !is_function {
				vm_fail(state, "E_TYPE", "call target is not a function")
				break
			}
			callable, callable_ok := vm_resolve_callable(state, function_id)
			if !callable_ok {
				vm_fail(state, "E_DISPATCH", "callable index is invalid")
				break
			}
			function_index := int(callable.function)
			if function_index < 0 || function_index >= len(program.functions) {
				vm_fail(state, "E_DISPATCH", "function index is invalid")
				break
			}
			callee := program.functions[function_index]
			capture_count := len(callable.captures)
			argument_count := int(instr.flags)
			args := make([]v.Value, argument_count, state.scratch_allocator)
			for index in 0 ..< argument_count {
				args[index] = state.registers[base + int(instr.c) + index]
			}
			callee_base := len(state.registers)
			resize(&state.registers, callee_base + callee.register_count)
			for capture, index in callable.captures {
				state.registers[callee_base + index] = capture
			}
			if !vm_bind_params(
				state,
				callee,
				args,
				callee_base + capture_count,
			) {
				break
			}
			append(&state.frames, Frame {
				function      = function_index,
				ip            = callee.code_offset,
				register_base = callee_base,
				caller_base   = base,
				caller_dst    = instr.a,
			})

		case .Call_Splice:
			if vm_depth_exceeded(state) {
				break
			}
			args, args_ok := vm_list_args(state, base, instr.c)
			if !args_ok {
				break
			}
			if instr.b < 0 || int(instr.b) >= len(program.functions) {
				vm_fail(state, "E_DISPATCH", "function index is invalid")
				break
			}
			callee := program.functions[instr.b]
			callee_base := len(state.registers)
			resize(&state.registers, callee_base + callee.register_count)
			if !vm_bind_params(state, callee, args, callee_base) {
				break
			}
			append(&state.frames, Frame {
				function      = int(instr.b),
				ip            = callee.code_offset,
				register_base = callee_base,
				caller_base   = base,
				caller_dst    = instr.a,
			})

		case .Builtin_Call_Splice:
			args, args_ok := vm_list_args(state, base, instr.c)
			if !args_ok {
				break
			}
			if instr.b < 0 || int(instr.b) >= len(program.builtins) {
				vm_fail(state, "E_UNKNOWN_BUILTIN", "builtin is not registered")
				break
			}
			name := program.builtins[instr.b]
			if !vm_builtin_allowed(state, name) {
				vm_fail(state, "E_PERMISSION", "builtin invoke denied")
				break
			}
			matched := false
			for builtin in state.builtins {
				if builtin.name != name {
					continue
				}
				result, builtin_ok := builtin.run(state, args)
				if !builtin_ok {
					if state.error == v.value_empty_relation() {
						vm_fail(state, "E_BUILTIN", "builtin failed")
					}
					break
				}
				state.registers[base + int(instr.a)] = result
				matched = true
				break
			}
			if !matched && state.error == v.value_empty_relation() {
				vm_fail(state, "E_UNKNOWN_BUILTIN", "builtin is not registered")
			}

		case .Call_Value_Splice:
			if vm_depth_exceeded(state) {
				break
			}
			target := state.registers[base + int(instr.b)]
			function_id, is_function := v.value_as_function(target)
			if !is_function {
				vm_fail(state, "E_TYPE", "call target is not a function")
				break
			}
			callable, callable_ok := vm_resolve_callable(state, function_id)
			if !callable_ok {
				vm_fail(state, "E_DISPATCH", "callable index is invalid")
				break
			}
			function_index := int(callable.function)
			if function_index < 0 || function_index >= len(program.functions) {
				vm_fail(state, "E_DISPATCH", "function index is invalid")
				break
			}
			args, args_ok := vm_list_args(state, base, instr.c)
			if !args_ok {
				break
			}
			callee := program.functions[function_index]
			capture_count := len(callable.captures)
			callee_base := len(state.registers)
			resize(&state.registers, callee_base + callee.register_count)
			for capture, index in callable.captures {
				state.registers[callee_base + index] = capture
			}
			if !vm_bind_params(
				state,
				callee,
				args,
				callee_base + capture_count,
			) {
				break
			}
			append(&state.frames, Frame {
				function      = function_index,
				ip            = callee.code_offset,
				register_base = callee_base,
				caller_base   = base,
				caller_dst    = instr.a,
			})

		case .Push_Finally:
			append(&state.handlers, Handler {
				frame             = top,
				target            = instr.a,
				error_register    = -1,
				kind              = .Finally,
				routes_exceptions = instr.flags & 1 != 0,
			})

		case .Resume_Return:
			if len(state.pending_raises) > 0 &&
			   state.pending_raises[len(state.pending_raises) - 1].frame == top {
				// An exception diverted through this finally: re-raise it.
				pending := pop(&state.pending_raises)
				state.error = pending.error
				state.status = .Failed
				break
			}
			if len(state.pending_returns) > 0 &&
			   state.pending_returns[len(state.pending_returns) - 1].frame == top {
				pending := state.pending_returns[len(state.pending_returns) - 1]
				if handler_index := vm_finally_handler(state, top); handler_index >= 0 {
					handler := state.handlers[handler_index]
					ordered_remove(&state.handlers, handler_index)
					state.frames[top].ip = int(handler.target)
					break
				}
				pop(&state.pending_returns)
				vm_remove_frame_handlers(state, top)
				returned := pop(&state.frames)
				resize(&state.registers, base)
				if len(state.frames) == 0 {
					state.result = pending.value
					state.status = .Halted
					return .Halted
				}
				caller := state.frames[len(state.frames) - 1]
				state.registers[caller.register_base + int(returned.caller_dst)] = pending.value
			}

		case .Is_Truthy:
			truthy := vm_truthy(state.registers[base + int(instr.b)])
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

		case .Positional_Dispatch:
			if !vm_positional_dispatch(state, base, instr) {
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

// Returns the index of the innermost Finally handler for `frame`, or -1.
@(private)
vm_finally_handler :: proc(state: ^VM, frame: int) -> int {
	for index := len(state.handlers) - 1; index >= 0; index -= 1 {
		handler := state.handlers[index]
		if handler.frame == frame && handler.kind == .Finally {
			return index
		}
	}
	return -1
}

// Retires every handler (and pending return) owned by `frame` when its call
// frame is popped. Without this, a handler left behind by an early return can
// be found by a later unwind at the same depth and use the wrong register
// window.
@(private)
vm_remove_frame_handlers :: proc(state: ^VM, frame: int) {
	write := 0
	for handler in state.handlers {
		if handler.frame == frame {
			continue
		}
		state.handlers[write] = handler
		write += 1
	}
	if write != len(state.handlers) {
		resize(&state.handlers, write)
	}
	pending_write := 0
	for pending in state.pending_returns {
		if pending.frame == frame {
			continue
		}
		state.pending_returns[pending_write] = pending
		pending_write += 1
	}
	if pending_write != len(state.pending_returns) {
		resize(&state.pending_returns, pending_write)
	}
	raise_write := 0
	for pending in state.pending_raises {
		if pending.frame == frame {
			continue
		}
		state.pending_raises[raise_write] = pending
		raise_write += 1
	}
	if raise_write != len(state.pending_raises) {
		resize(&state.pending_raises, raise_write)
	}
}

// Transfers control to the innermost handler. Returns false when no handler
// exists and the error must escape the VM.
@(private)
vm_unwind :: proc(state: ^VM) -> bool {
	if len(state.handlers) == 0 {
		return false
	}
	handler_index := -1
	handler_is_finally := false
	for index := len(state.handlers) - 1; index >= 0; index -= 1 {
		handler := state.handlers[index]
		if handler.kind == .Catch ||
		   (handler.kind == .Finally && handler.routes_exceptions) {
			handler_index = index
			handler_is_finally = handler.kind == .Finally
			break
		}
	}
	if handler_index < 0 {
		return false
	}
	handler := state.handlers[handler_index]
	resize(&state.handlers, handler_index)
	for len(state.pending_returns) > 0 &&
	    state.pending_returns[len(state.pending_returns) - 1].frame >= handler.frame {
		pop(&state.pending_returns)
	}
	if handler.frame >= len(state.frames) {
		return false
	}
	resize(&state.frames, handler.frame + 1)
	frame := state.frames[handler.frame]
	state.frames[handler.frame].ip = int(handler.target)
	// Drop the dead frames' registers, mirroring Return: only the handler
	// frame's window stays live. Without this, errors caught in a loop grow
	// the register file on every iteration.
	if frame.function >= 0 && frame.function < len(state.program.functions) {
		function := state.program.functions[frame.function]
		if frame.register_base + function.register_count < len(state.registers) {
			resize(&state.registers, frame.register_base + function.register_count)
		}
	}
	if handler_is_finally {
		// Run the finally body, then re-raise the error when it completes.
		append(&state.pending_raises, Pending_Raise {
			frame = handler.frame,
			error = state.error,
		})
		state.status = .Ready
		return true
	}
	if handler.error_register >= 0 {
		state.registers[frame.register_base + int(handler.error_register)] = state.error
	}
	state.status = .Ready
	return true
}

@(private)
vm_build_relation :: proc(state: ^VM, base: int, instr: Instruction) -> bool {
	shape := state.program.relation_shapes[instr.b]
	values := make([]v.Value, len(shape.heading), state.scratch_allocator)
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
		entries := make([]v.Map_Entry, len(relation.heading), state.scratch_allocator)
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
			entries := make([]v.Map_Entry, len(relation.heading), state.scratch_allocator)
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
			cells := make([]v.Value, len(relation.rows), state.scratch_allocator)
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
	if !vm_builtin_allowed(state, name) {
		vm_fail(state, "E_PERMISSION", "builtin invoke denied")
		return false
	}
	for builtin in state.builtins {
		if builtin.name != name {
			continue
		}
		argc := builtin.argc
		if argc < 0 {
			argc = int(instr.flags)
		}
		args := make([]v.Value, argc, state.scratch_allocator)
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
	if !k.authority_can_read(state.authority, k.Relation_ID(pattern.relation)) {
		vm_fail(state, "E_PERMISSION", "relation read denied")
		return false
	}
	bindings := vm_pattern_bindings(state, base, pattern, state.scratch_allocator)
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
	// Only named query variables are result columns; bound values and
	// wildcards participate in matching but do not appear in the heading.
	output_count := 0
	for cell in pattern.cells {
		if cell.kind == .Output {
			output_count += 1
		}
	}
	result: v.Value
	if output_count == len(pattern.cells) {
		converted, err := v.value_relation(state.allocator, pattern.column_names, rows[:])
		if err != .None {
			vm_fail(state, "E_RELATION", "scan result columns are invalid")
			return false
		}
		result = converted
	} else {
		heading := make([]v.Symbol, output_count, state.scratch_allocator)
		positions := make([]u16, output_count, state.scratch_allocator)
		write := 0
		for cell, index in pattern.cells {
			if cell.kind == .Output {
				heading[write] = pattern.column_names[index]
				positions[write] = u16(index)
				write += 1
			}
		}
		projected := make([]v.Tuple, len(rows), state.scratch_allocator)
		for row, index in rows {
			projected[index] = v.tuple_select(row, state.allocator, positions)
		}
		converted, err := v.value_relation(state.allocator, heading, projected)
		if err != .None {
			vm_fail(state, "E_RELATION", "scan result columns are invalid")
			return false
		}
		result = converted
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
	if !k.authority_can_read(state.authority, k.Relation_ID(pattern.relation)) {
		vm_fail(state, "E_PERMISSION", "relation read denied")
		return false
	}
	bindings := vm_pattern_bindings(state, base, pattern, state.scratch_allocator)
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
	if !k.authority_can_write(state.authority, relation_id) {
		vm_fail(state, "E_PERMISSION", "relation write denied")
		return false
	}
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
	roles := make([]k.Role_Pair, len(spec.roles), state.scratch_allocator)
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
	all_entries := k.applicable_method_entries(
		state.source,
		relations,
		selector,
		roles,
		state.scratch_allocator,
	)
	if len(all_entries) == 0 {
		vm_fail(state, "E_DISPATCH", "no applicable method")
		return false
	}
	selector_symbol, _ := v.value_as_symbol(selector)
	entries: [dynamic]k.Applicable_Method
	defer delete(entries)
	for entry in all_entries {
		if k.authority_can_invoke_method(state.authority, entry.method) ||
		   k.authority_can_invoke_selector(state.authority, selector_symbol) {
			append(&entries, entry)
		}
	}
	if len(entries) == 0 {
		vm_fail(state, "E_PERMISSION", "method invoke denied")
		return false
	}
	if len(entries) > 1 {
		vm_fail(state, "E_DISPATCH", "ambiguous method dispatch")
		return false
	}
	entry := entries[0]
	args, args_ok := k.dispatch_method_args(entry.params, roles, state.scratch_allocator)
	if !args_ok {
		vm_fail(state, "E_DISPATCH", "method parameters cannot be bound")
		return false
	}
	return vm_call_dispatch_entry(state, base, destination, entry, args)
}

// Resolves the method's function index and calls it with `args`.
@(private)
vm_call_dispatch_entry :: proc(
	state: ^VM,
	base: int,
	destination: i32,
	entry: k.Applicable_Method,
	args: []v.Value,
) -> bool {
	program := state.program
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
	return vm_call_function(state, base, destination, int(function_index), nil, args)
}

// Calls a program function from a dispatch site, binding `args` to its
// parameters.
@(private)
vm_call_function :: proc(
	state: ^VM,
	base: int,
	destination: i32,
	function_index: int,
	captures: []v.Value,
	args: []v.Value,
) -> bool {
	if vm_depth_exceeded(state) {
		return false
	}
	program := state.program
	callee := program.functions[function_index]
	capture_count := len(captures)
	callee_base := len(state.registers)
	resize(&state.registers, callee_base + callee.register_count)
	for capture, index in captures {
		state.registers[callee_base + index] = capture
	}
	if !vm_bind_params(state, callee, args, callee_base + capture_count) {
		return false
	}
	append(&state.frames, Frame {
		function      = function_index,
		ip            = callee.code_offset,
		register_base = callee_base,
		caller_base   = base,
		caller_dst    = destination,
	})
	return true
}

@(private)
vm_positional_dispatch :: proc(state: ^VM, base: int, instr: Instruction) -> bool {
	program := state.program
	if state.source == nil {
		vm_fail(state, "E_NO_SOURCE", "dispatch has no relation source")
		return false
	}
	selector := state.registers[base + int(instr.b)]
	if _, is_symbol := v.value_as_symbol(selector); !is_symbol {
		vm_fail(state, "E_TYPE", "receiver dispatch selector is not a symbol")
		return false
	}
	argument_count := int(instr.flags)
	args := make([]v.Value, argument_count, state.scratch_allocator)
	for index in 0 ..< argument_count {
		args[index] = state.registers[base + int(instr.c) + index]
	}
	relations := k.Dispatch_Relations {
		method_selector = k.Relation_ID(program.dispatch_method_selector_relation),
		param           = k.Relation_ID(program.dispatch_param_relation),
		delegates       = k.Relation_ID(program.dispatch_delegates_relation),
	}
	all_entries := k.applicable_positional_method_entries(
		state.source,
		relations,
		selector,
		args,
	)
	if len(all_entries) == 0 {
		vm_fail(state, "E_DISPATCH", "no applicable method")
		return false
	}
	selector_symbol, _ := v.value_as_symbol(selector)
	entries: [dynamic]k.Applicable_Method
	defer delete(entries)
	for entry in all_entries {
		if k.authority_can_invoke_method(state.authority, entry.method) ||
		   k.authority_can_invoke_selector(state.authority, selector_symbol) {
			append(&entries, entry)
		}
	}
	if len(entries) == 0 {
		vm_fail(state, "E_PERMISSION", "method invoke denied")
		return false
	}
	if len(entries) > 1 {
		vm_fail(state, "E_DISPATCH", "ambiguous method dispatch")
		return false
	}
	return vm_call_dispatch_entry(state, base, instr.a, entries[0], args)
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
	roles := make([]k.Role_Pair, len(entries), state.scratch_allocator)
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
	if !k.authority_can_write(state.authority, k.Relation_ID(pattern.relation)) {
		vm_fail(state, "E_PERMISSION", "relation write denied")
		return false
	}
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
	case .Overloaded:
		return "E_OVERLOADED"
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
		vm_arithmetic_fail(state, op, left, right)
		return false
	}
	state.registers[base + int(instr.a)] = result
	return true
}

// Records an arithmetic failure with the error code the language documents.
// A zero divisor in division or remainder raises E_DIV carrying the operands;
// mixing an integer and a float raises E_TYPE; every other failure, such as
// overflow or a non-finite float result, raises E_ARITH.
@(private)
vm_arithmetic_fail :: proc(state: ^VM, op: Bin_Op, left, right: v.Value) {
	code := "E_ARITH"
	message := "invalid arithmetic"
	#partial switch op {
	case .Div, .Rem:
		divisor_is_zero := false
		if divisor, ok := v.value_as_int(right); ok && divisor == 0 {
			divisor_is_zero = true
		}
		if divisor, ok := v.value_as_float(right); ok && divisor == 0 {
			divisor_is_zero = true
		}
		if divisor_is_zero {
			code = "E_DIV"
			message = op == .Div ? "division by zero" : "remainder by zero"
		}
	}
	left_is_int := v.value_kind(left) == .Int
	right_is_int := v.value_kind(right) == .Int
	left_is_numeric := left_is_int || v.value_kind(left) == .Float
	right_is_numeric := right_is_int || v.value_kind(right) == .Float
	if left_is_numeric && right_is_numeric && left_is_int != right_is_int {
		code = "E_TYPE"
		message = "numeric operands must have the same kind"
	}

	payload := v.value_list(state.allocator, []v.Value{left, right})
	state.error = v.value_error(
		state.allocator,
		v.symbol_intern(code),
		message,
		true,
		payload,
		true,
	)
	state.status = .Failed
}

// Truthiness used by conditions, `&&`, `||`, `!`, and `require`: false, an
// empty list, and an empty relation are falsy; everything else is truthy.
vm_truthy :: proc(value: v.Value) -> bool {
	#partial switch v.value_kind(value) {
	case .Bool:
		result, _ := v.value_as_bool(value)
		return result
	case .List:
		values, _ := v.value_as_list(value)
		return len(values) > 0
	case .Relation:
		relation, _ := v.value_as_relation(value)
		return len(relation.rows) > 0
	}
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
			vm_fail(state, "E_ARITH", "invalid unary arithmetic")
			return false
		}
		state.registers[base + int(instr.a)] = result
	case .Not:
		state.registers[base + int(instr.a)] = v.value_bool(!vm_truthy(source))
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

// Fails the VM when the frame stack is at the configured call-depth limit.
@(private)
vm_depth_exceeded :: proc(state: ^VM) -> bool {
	if state.max_call_depth > 0 && len(state.frames) >= state.max_call_depth {
		vm_fail(state, "E_DEPTH", "call depth exceeded")
		return true
	}
	return false
}

// The `none` value: an empty relation headed by `value`, matching the literal.
@(private)
vm_none_value :: proc(state: ^VM) -> v.Value {
	result, _ := v.value_relation(
		state.allocator,
		[]v.Symbol{v.symbol_intern("value")},
		nil,
	)
	return result
}

// Binds call arguments into a callee's parameter registers, applying optional
// defaults and packing a rest parameter. `param_base` is the register where
// parameters start (after any captures).
@(private)
vm_bind_params :: proc(
	state: ^VM,
	callee: Function,
	args: []v.Value,
	param_base: int,
) -> bool {
	program := state.program
	required := int(callee.required_count)
	non_rest := callee.param_count
	if callee.has_rest {
		non_rest -= 1
	}
	if len(args) < required || (!callee.has_rest && len(args) > non_rest) {
		vm_fail(state, "E_ARITY", "wrong number of arguments for function call")
		return false
	}
	for index in 0 ..< non_rest {
		value: v.Value
		if index < len(args) {
			value = args[index]
		} else if callee.defaults != nil &&
		   index < len(callee.defaults) &&
		   callee.defaults[index] >= 0 {
			value = program.constants[callee.defaults[index]]
		} else {
			value = vm_none_value(state)
		}
		state.registers[param_base + index] = value
	}
	if callee.has_rest {
		rest_count := len(args) - non_rest
		if rest_count < 0 {
			rest_count = 0
		}
		rest := make([]v.Value, rest_count, state.scratch_allocator)
		for index in 0 ..< rest_count {
			rest[index] = args[non_rest + index]
		}
		state.registers[param_base + non_rest] = v.value_list(state.allocator, rest)
	}
	return true
}

// Returns the list value in `register` as call arguments.
@(private)
vm_list_args :: proc(state: ^VM, base: int, register: i32) -> ([]v.Value, bool) {
	value := state.registers[base + int(register)]
	args, is_list := v.value_as_list(value)
	if !is_list {
		vm_fail(state, "E_TYPE", "spliced arguments must be a list")
		return nil, false
	}
	return args, true
}

// Internal builtins (`__` prefix) are always invocable; other builtins need an
// invoke grant when the task has a non-root authority.
@(private)
vm_builtin_allowed :: proc(state: ^VM, name: v.Symbol) -> bool {
	if state.authority == nil || state.authority.root {
		return true
	}
	text, _ := v.symbol_name(name)
	if strings.has_prefix(text, "__") {
		return true
	}
	if text == "emit" {
		return k.authority_can_effect(state.authority)
	}
	// Capability bootstrap: the capability builtins check their own authority.
	if text == "use_capability" ||
	   text == "mint_capability" ||
	   text == "restrict_capability" ||
	   text == "revoke_capability" ||
	   text == "drop_capability" {
		return true
	}
	return k.authority_can_invoke_builtin(state.authority, name)
}

// Resolves a function value to its callable, copying the info out under the
// program callable lock.
@(private)
vm_resolve_callable :: proc(state: ^VM, id: v.Function_ID) -> (Callable_Info, bool) {
	program := state.program
	index := int(v.function_id_raw(id))
	sync.mutex_lock(&program.callables_mutex)
	defer sync.mutex_unlock(&program.callables_mutex)
	if index < 0 || index >= len(program.callables) {
		return {}, false
	}
	return program.callables[index], true
}

// Interns a callable, reusing an existing entry with the same function and
// captured values. Takes ownership of `captures`.
@(private)
vm_intern_callable :: proc(state: ^VM, function: i32, captures: []v.Value) -> i32 {
	program := state.program
	sync.mutex_lock(&program.callables_mutex)
	defer sync.mutex_unlock(&program.callables_mutex)
	for callable, index in program.callables {
		if callable.function != function || len(callable.captures) != len(captures) {
			continue
		}
		matches := true
		for capture, capture_index in captures {
			if !v.value_eq(callable.captures[capture_index], capture) {
				matches = false
				break
			}
		}
		if matches {
			delete(captures)
			return i32(index)
		}
	}
	index := len(program.callables)
	append(&program.callables, Callable_Info {
		function = function,
		captures = captures,
	})
	return i32(index)
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
