// Bytecode program format for the Mica virtual machine.
//
// A program is a flat array of fixed-size instructions, a constant pool, and a
// function table. Instructions use register operands and are designed for a
// simple switch dispatch in the execution loop. The format is deliberately
// compact and easy to validate, disassemble, and later serialise.
//
// This is an Odin-first design; it does not mirror the Rust opcode set.
package vm

import "core:fmt"
import "core:mem"
import "core:strings"
import v "../var"

Op :: enum u8 {
	// Load_Const: a = dst register, b = constant index.
	Load_Const,
	// Move: a = dst, b = src.
	Move,
	// Binary: a = dst, b = lhs, c = rhs; flags hold a Bin_Op.
	Binary,
	// Unary: a = dst, b = src; flags hold an Un_Op.
	Unary,
	// Branch: a = condition register, b = relative offset.
	Branch,
	// Jump: b = relative offset.
	Jump,
	// Call: a = dst, b = function index, c = first argument register.
	Call,
	// Return: a = source register.
	Return,
	// Build_List: a = dst, b = first element register, c = element count.
	Build_List,
	// Build_Map: a = dst, b = first entry register, c = entry count. Each
	// entry occupies two consecutive registers, key then value.
	Build_Map,
	// Build_Range: a = dst, b = start register, c = end register. flags bit 0
	// marks a bound end.
	Build_Range,
	// Len: a = dst, b = collection register.
	Len,
}

Bin_Op :: enum u8 {
	Add,
	Sub,
	Mul,
	Div,
	Rem,
	Eq,
	Ne,
	Lt,
	Le,
	Gt,
	Ge,
}

Un_Op :: enum u8 {
	Neg,
	Not,
}

Instruction :: struct {
	op:    Op,
	flags: u8,
	a:     i32,
	b:     i32,
	c:     i32,
}

Function :: struct {
	name:           v.Symbol,
	code_offset:    int,
	code_len:       int,
	register_count: int,
	param_count:    int,
}

Program :: struct {
	code:      []Instruction,
	constants: []v.Value,
	functions: []Function,
	entry:     int,
}

Program_Error :: enum {
	None,
	No_Entry,
	Bad_Register,
	Bad_Constant,
	Bad_Jump,
	Bad_Function,
	Bad_Arguments,
}

// --- Builder ---------------------------------------------------------------

Builder :: struct {
	code:          [dynamic]Instruction,
	constants:     [dynamic]v.Value,
	functions:     [dynamic]Function,
	entry:         int,
	open_function: int,
	open_offset:   int,
}

builder_init :: proc(builder: ^Builder) {
	builder.code = make([dynamic]Instruction)
	builder.constants = make([dynamic]v.Value)
	builder.functions = make([dynamic]Function)
	builder.entry = -1
	builder.open_function = -1
}

builder_destroy :: proc(builder: ^Builder) {
	delete(builder.code)
	delete(builder.constants)
	delete(builder.functions)
}

builder_add_constant :: proc(builder: ^Builder, value: v.Value) -> int {
	append(&builder.constants, value)
	return len(builder.constants) - 1
}

builder_begin_function :: proc(
	builder: ^Builder,
	name: v.Symbol,
	param_count: int,
	register_count: int,
	entry := false,
) -> int {
	index := len(builder.functions)
	append(&builder.functions, Function {
		name           = name,
		code_offset    = len(builder.code),
		code_len       = 0,
		register_count = register_count,
		param_count    = param_count,
	})
	builder.open_function = index
	builder.open_offset = len(builder.code)
	if entry {
		builder.entry = index
	}
	return index
}

builder_end_function :: proc(builder: ^Builder) {
	if builder.open_function < 0 {
		return
	}
	builder.functions[builder.open_function].code_len =
		len(builder.code) - builder.open_offset
	builder.open_function = -1
}

builder_emit :: proc(builder: ^Builder, op: Op, flags: u8, a, b, c: i32) {
	append(&builder.code, Instruction{op = op, flags = flags, a = a, b = b, c = c})
}

// Moves the built program into `alloc`.
builder_build :: proc(builder: ^Builder, alloc: mem.Allocator) -> ^Program {
	program := new(Program, alloc)
	program.code = make([]Instruction, len(builder.code), alloc)
	copy(program.code, builder.code[:])
	program.constants = make([]v.Value, len(builder.constants), alloc)
	copy(program.constants, builder.constants[:])
	program.functions = make([]Function, len(builder.functions), alloc)
	copy(program.functions, builder.functions[:])
	program.entry = builder.entry
	return program
}

program_destroy :: proc(program: ^Program, alloc: mem.Allocator) {
	free(raw_data(program.code), alloc)
	free(raw_data(program.constants), alloc)
	free(raw_data(program.functions), alloc)
	free(program, alloc)
}

// --- Validation ------------------------------------------------------------

// Validates register, constant, jump, and function references.
program_validate :: proc(program: ^Program) -> Program_Error {
	if program.entry < 0 || program.entry >= len(program.functions) {
		return .No_Entry
	}
	for function, function_index in program.functions {
		if function.code_offset < 0 ||
		   function.code_len < 0 ||
		   function.code_offset + function.code_len > len(program.code) {
			return .Bad_Function
		}

		code_end := function.code_offset + function.code_len
		for offset in function.code_offset ..< code_end {
			instr := program.code[offset]
			register_count := function.register_count

			switch instr.op {
			case .Load_Const:
				if !valid_register(instr.a, register_count) {
					return .Bad_Register
				}
				if instr.b < 0 || int(instr.b) >= len(program.constants) {
					return .Bad_Constant
				}
			case .Move:
				if !valid_register(instr.a, register_count) ||
				   !valid_register(instr.b, register_count) {
					return .Bad_Register
				}
			case .Binary:
				if !valid_register(instr.a, register_count) ||
				   !valid_register(instr.b, register_count) ||
				   !valid_register(instr.c, register_count) {
					return .Bad_Register
				}
				if u8(instr.flags) > u8(Bin_Op.Ge) {
					return .Bad_Function
				}
			case .Unary:
				if !valid_register(instr.a, register_count) ||
				   !valid_register(instr.b, register_count) {
					return .Bad_Register
				}
				if u8(instr.flags) > u8(Un_Op.Not) {
					return .Bad_Function
				}
			case .Branch:
				if !valid_register(instr.a, register_count) {
					return .Bad_Register
				}
				target := offset + 1 + int(instr.b)
				if target < function.code_offset || target >= code_end {
					return .Bad_Jump
				}
			case .Jump:
				target := offset + 1 + int(instr.b)
				if target < function.code_offset || target >= code_end {
					return .Bad_Jump
				}
			case .Call:
				if !valid_register(instr.a, register_count) {
					return .Bad_Register
				}
				if instr.b < 0 || int(instr.b) >= len(program.functions) {
					return .Bad_Function
				}
				callee := program.functions[instr.b]
				if instr.c < 0 ||
				   int(instr.c) + callee.param_count > register_count ||
				   callee.param_count > register_count {
					return .Bad_Arguments
				}
				// Direct recursion is allowed; depth is a runtime concern.
			case .Return:
				if !valid_register(instr.a, register_count) {
					return .Bad_Register
				}
			case .Build_List:
				if !valid_register(instr.a, register_count) {
					return .Bad_Register
				}
				if instr.c < 0 {
					return .Bad_Arguments
				}
				for item in 0 ..< int(instr.c) {
					if !valid_register(instr.b + i32(item), register_count) {
						return .Bad_Register
					}
				}
			case .Build_Map:
				if !valid_register(instr.a, register_count) {
					return .Bad_Register
				}
				if instr.c < 0 {
					return .Bad_Arguments
				}
				for item in 0 ..< int(instr.c) * 2 {
					if !valid_register(instr.b + i32(item), register_count) {
						return .Bad_Register
					}
				}
			case .Build_Range:
				if !valid_register(instr.a, register_count) ||
				   !valid_register(instr.b, register_count) ||
				   !valid_register(instr.c, register_count) {
					return .Bad_Register
				}
			case .Len:
				if !valid_register(instr.a, register_count) ||
				   !valid_register(instr.b, register_count) {
					return .Bad_Register
				}
			}
		}
	}
	return .None
}

@(private)
valid_register :: proc(index: i32, count: int) -> bool {
	return index >= 0 && int(index) < count
}

// --- Disassembly -----------------------------------------------------------

// Formats a program listing into a newly allocated string.
program_disassemble :: proc(program: ^Program, alloc := context.allocator) -> string {
	builder: strings.Builder
	strings.builder_init(&builder, alloc)
	defer strings.builder_destroy(&builder)

	for function, function_index in program.functions {
		entry_mark := function_index == program.entry ? " entry" : ""
		name, _ := v.symbol_name(function.name)
		fmt.sbprintf(
			&builder,
			"function %s params=%d regs=%d%s\n",
			name,
			function.param_count,
			function.register_count,
			entry_mark,
		)
		for offset in function.code_offset ..< function.code_offset + function.code_len {
			instr := program.code[offset]
			op_name := op_name(instr.op)
			fmt.sbprintf(&builder, "  %04d  %-12s", offset, op_name)
			switch instr.op {
			case .Load_Const:
				fmt.sbprintf(&builder, " r%d c%d", instr.a, instr.b)
			case .Move:
				fmt.sbprintf(&builder, " r%d r%d", instr.a, instr.b)
			case .Binary:
				fmt.sbprintf(
					&builder,
					" %s r%d r%d r%d",
					bin_op_name(Bin_Op(instr.flags)),
					instr.a,
					instr.b,
					instr.c,
				)
			case .Unary:
				fmt.sbprintf(
					&builder,
					" %s r%d r%d",
					un_op_name(Un_Op(instr.flags)),
					instr.a,
					instr.b,
				)
			case .Branch:
				fmt.sbprintf(
					&builder,
					" r%d -> %d",
					instr.a,
					offset + 1 + int(instr.b),
				)
			case .Jump:
				fmt.sbprintf(&builder, " -> %d", offset + 1 + int(instr.b))
			case .Call:
				fmt.sbprintf(&builder, " r%d fn%d args@r%d", instr.a, instr.b, instr.c)
			case .Return:
				fmt.sbprintf(&builder, " r%d", instr.a)
			case .Build_List:
				fmt.sbprintf(&builder, " r%d r%d..%d", instr.a, instr.b, instr.b + instr.c)
			case .Build_Map:
				fmt.sbprintf(
					&builder,
					" r%d r%d..%d",
					instr.a,
					instr.b,
					instr.b + instr.c * 2,
				)
			case .Build_Range:
				fmt.sbprintf(&builder, " r%d r%d..r%d", instr.a, instr.b, instr.c)
			case .Len:
				fmt.sbprintf(&builder, " r%d r%d", instr.a, instr.b)
			}
			strings.write_byte(&builder, '\n')
		}
	}
	return strings.to_string(builder)
}

@(private)
op_name :: proc(op: Op) -> string {
	switch op {
	case .Load_Const:
		return "load_const"
	case .Move:
		return "move"
	case .Binary:
		return "binary"
	case .Unary:
		return "unary"
	case .Branch:
		return "branch"
	case .Jump:
		return "jump"
	case .Call:
		return "call"
	case .Return:
		return "return"
	case .Build_List:
		return "build_list"
	case .Build_Map:
		return "build_map"
	case .Build_Range:
		return "build_range"
	case .Len:
		return "len"
	}
	return "?"
}

@(private)
bin_op_name :: proc(op: Bin_Op) -> string {
	switch op {
	case .Add:
		return "add"
	case .Sub:
		return "sub"
	case .Mul:
		return "mul"
	case .Div:
		return "div"
	case .Rem:
		return "rem"
	case .Eq:
		return "eq"
	case .Ne:
		return "ne"
	case .Lt:
		return "lt"
	case .Le:
		return "le"
	case .Gt:
		return "gt"
	case .Ge:
		return "ge"
	}
	return "?"
}

@(private)
un_op_name :: proc(op: Un_Op) -> string {
	switch op {
	case .Neg:
		return "neg"
	case .Not:
		return "not"
	}
	return "?"
}
