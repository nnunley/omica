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
	// Scan_Collect: a = dst, b = pattern index. Binds nothing; the result is
	// a relation value with one row per match.
	Scan_Collect,
	// Scan_Exists: a = dst (bool), b = pattern index.
	Scan_Exists,
	// Scan_First: a = dst (bool), b = pattern index. Writes bind cells from
	// the first match; returns false when there is no match.
	Scan_First,
	// Assert: a = relation id, b = register holding a single-row relation
	// value.
	Assert,
	// Retract: a = relation id, b = register holding a single-row relation
	// value.
	Retract,
	// Retract_Where: b = pattern index. Retracts every matching row.
	Retract_Where,
	// Build_Relation: a = dst, b = relation shape index, c = first cell
	// register. Builds a single-row relation value.
	Build_Relation,
	// Index: a = dst, b = collection register, c = key register.
	Index,
	// Collection_Key_At: a = dst, b = collection register, c = ordinal index
	// register. Yields the map key at that position, or the ordinal itself for
	// lists and relations.
	Collection_Key_At,
	// Collection_Value_At: a = dst, b = collection register, c = ordinal index
	// register.
	Collection_Value_At,
	// Builtin_Call: a = dst, b = builtin index, c = first argument register.
	Builtin_Call,
	// Commit: requests a transaction commit from the host.
	Commit,
	// Is_Truthy: a = dst (bool), b = source.
	Is_Truthy,
	// Scan_One: a = dst (bool), b = pattern index. Fails unless exactly one
	// row matches, then writes output cells.
	Scan_One,
	// Dispatch: a = dst, b = dispatch spec index. Resolves a method from the
	// selector and role arguments, then calls its program.
	Dispatch,
}

// A cell in a relation scan pattern.
Pattern_Cell_Kind :: enum u8 {
	// A constant constant-pool value.
	Const,
	// A register holding a join input value.
	Bind,
	// A register that receives the matched cell value.
	Output,
	// Any value.
	Wildcard,
}

Pattern_Cell :: struct {
	kind:    Pattern_Cell_Kind,
	operand: i32,
}

// A relation scan pattern. Column names head the relation value produced by
// Scan_Collect.
Scan_Pattern :: struct {
	relation:     u32,
	column_names: []v.Symbol,
	cells:        []Pattern_Cell,
}

// The heading of a relation value built at runtime.
Relation_Shape :: struct {
	heading: []v.Symbol,
}

// A role binding at a dispatch site. `register` is relative to the function
// frame.
Dispatch_Role :: struct {
	role:     v.Symbol,
	register: i32,
}

// A dispatch site: a selector symbol plus its role arguments.
Dispatch_Spec :: struct {
	selector: v.Symbol,
	roles:    []Dispatch_Role,
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
	patterns:        []Scan_Pattern,
	relation_shapes: []Relation_Shape,
	dispatch_specs:  []Dispatch_Spec,
	builtins:        []v.Symbol,
	entry:           int,
	// Kernel relation ids used to resolve dispatch. Zero disables dispatch.
	dispatch_method_selector_relation: u32,
	dispatch_param_relation:           u32,
	dispatch_delegates_relation:       u32,
	dispatch_method_program_relation:  u32,
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
	patterns:        [dynamic]Scan_Pattern,
	relation_shapes: [dynamic]Relation_Shape,
	dispatch_specs:  [dynamic]Dispatch_Spec,
	builtins:        [dynamic]v.Symbol,
	entry:           int,
	open_function:   int,
	open_offset:     int,
	dispatch_method_selector_relation: u32,
	dispatch_param_relation:           u32,
	dispatch_delegates_relation:       u32,
	dispatch_method_program_relation:  u32,
}

builder_init :: proc(builder: ^Builder) {
	builder.code = make([dynamic]Instruction)
	builder.constants = make([dynamic]v.Value)
	builder.functions = make([dynamic]Function)
	builder.patterns = make([dynamic]Scan_Pattern)
	builder.relation_shapes = make([dynamic]Relation_Shape)
	builder.dispatch_specs = make([dynamic]Dispatch_Spec)
	builder.builtins = make([dynamic]v.Symbol)
	builder.entry = -1
	builder.open_function = -1
}

builder_destroy :: proc(builder: ^Builder) {
	delete(builder.code)
	delete(builder.constants)
	delete(builder.functions)
	for pattern in builder.patterns {
		delete(pattern.column_names)
		delete(pattern.cells)
	}
	delete(builder.patterns)
	for shape in builder.relation_shapes {
		delete(shape.heading)
	}
	delete(builder.relation_shapes)
	for spec in builder.dispatch_specs {
		delete(spec.roles)
	}
	delete(builder.dispatch_specs)
	delete(builder.builtins)
}

// Adds a relation value heading, copying it. Returns the shape index.
builder_add_relation_shape :: proc(builder: ^Builder, heading: []v.Symbol) -> i32 {
	names := make([]v.Symbol, len(heading))
	copy(names, heading)
	append(&builder.relation_shapes, Relation_Shape{heading = names})
	return i32(len(builder.relation_shapes) - 1)
}

// Adds a builtin reference by name. Returns the builtin index.
builder_add_builtin :: proc(builder: ^Builder, name: v.Symbol) -> i32 {
	append(&builder.builtins, name)
	return i32(len(builder.builtins) - 1)
}

// Adds a scan pattern, copying its slices. Returns the pattern index.
builder_add_pattern :: proc(
	builder: ^Builder,
	relation: u32,
	column_names: []v.Symbol,
	cells: []Pattern_Cell,
) -> i32 {
	names := make([]v.Symbol, len(column_names))
	copy(names, column_names)
	pattern_cells := make([]Pattern_Cell, len(cells))
	copy(pattern_cells, cells)
	append(&builder.patterns, Scan_Pattern {
		relation     = relation,
		column_names = names,
		cells        = pattern_cells,
	})
	return i32(len(builder.patterns) - 1)
}

builder_add_dispatch_spec :: proc(
	builder: ^Builder,
	selector: v.Symbol,
	roles: []Dispatch_Role,
) -> i32 {
	owned := make([]Dispatch_Role, len(roles))
	copy(owned, roles)
	append(&builder.dispatch_specs, Dispatch_Spec {
		selector = selector,
		roles    = owned,
	})
	return i32(len(builder.dispatch_specs) - 1)
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
	program.patterns = make([]Scan_Pattern, len(builder.patterns), alloc)
	program.relation_shapes = make([]Relation_Shape, len(builder.relation_shapes), alloc)
	for pattern, i in builder.patterns {
		names := make([]v.Symbol, len(pattern.column_names), alloc)
		copy(names, pattern.column_names)
		cells := make([]Pattern_Cell, len(pattern.cells), alloc)
		copy(cells, pattern.cells)
		program.patterns[i] = Scan_Pattern {
			relation     = pattern.relation,
			column_names = names,
			cells        = cells,
		}
	}
	for shape, i in builder.relation_shapes {
		heading := make([]v.Symbol, len(shape.heading), alloc)
		copy(heading, shape.heading)
		program.relation_shapes[i] = Relation_Shape{heading = heading}
	}
	program.dispatch_specs = make([]Dispatch_Spec, len(builder.dispatch_specs), alloc)
	for spec, i in builder.dispatch_specs {
		roles := make([]Dispatch_Role, len(spec.roles), alloc)
		copy(roles, spec.roles)
		program.dispatch_specs[i] = Dispatch_Spec {
			selector = spec.selector,
			roles    = roles,
		}
	}
	program.builtins = make([]v.Symbol, len(builder.builtins), alloc)
	copy(program.builtins, builder.builtins[:])
	program.entry = builder.entry
	program.dispatch_method_selector_relation = builder.dispatch_method_selector_relation
	program.dispatch_param_relation = builder.dispatch_param_relation
	program.dispatch_delegates_relation = builder.dispatch_delegates_relation
	program.dispatch_method_program_relation = builder.dispatch_method_program_relation
	return program
}

program_destroy :: proc(program: ^Program, alloc: mem.Allocator) {
	free(raw_data(program.code), alloc)
	free(raw_data(program.constants), alloc)
	free(raw_data(program.functions), alloc)
	for pattern in program.patterns {
		free(raw_data(pattern.column_names), alloc)
		free(raw_data(pattern.cells), alloc)
	}
	free(raw_data(program.patterns), alloc)
	for shape in program.relation_shapes {
		free(raw_data(shape.heading), alloc)
	}
	free(raw_data(program.relation_shapes), alloc)
	for spec in program.dispatch_specs {
		free(raw_data(spec.roles), alloc)
	}
	free(raw_data(program.dispatch_specs), alloc)
	free(raw_data(program.builtins), alloc)
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
			case .Scan_Collect, .Scan_Exists, .Scan_First, .Scan_One:
				if !valid_register(instr.a, register_count) {
					return .Bad_Register
				}
				if instr.b < 0 || int(instr.b) >= len(program.patterns) {
					return .Bad_Function
				}
			case .Retract_Where:
				if instr.b < 0 || int(instr.b) >= len(program.patterns) {
					return .Bad_Function
				}
			case .Assert, .Retract:
				if instr.a < 0 {
					return .Bad_Function
				}
				if !valid_register(instr.b, register_count) {
					return .Bad_Register
				}
			case .Build_Relation:
				if !valid_register(instr.a, register_count) {
					return .Bad_Register
				}
				if instr.b < 0 || int(instr.b) >= len(program.relation_shapes) {
					return .Bad_Function
				}
				arity := len(program.relation_shapes[instr.b].heading)
				for cell in 0 ..< arity {
					if !valid_register(instr.c + i32(cell), register_count) {
						return .Bad_Register
					}
				}
			case .Index:
				if !valid_register(instr.a, register_count) ||
				   !valid_register(instr.b, register_count) ||
				   !valid_register(instr.c, register_count) {
					return .Bad_Register
				}
			case .Collection_Key_At, .Collection_Value_At:
				if !valid_register(instr.a, register_count) ||
				   !valid_register(instr.b, register_count) ||
				   !valid_register(instr.c, register_count) {
					return .Bad_Register
				}
			case .Builtin_Call:
				if !valid_register(instr.a, register_count) {
					return .Bad_Register
				}
				if instr.b < 0 || int(instr.b) >= len(program.builtins) {
					return .Bad_Function
				}
				if !valid_register(instr.c, register_count) {
					return .Bad_Register
				}
			case .Commit:
			case .Is_Truthy:
				if !valid_register(instr.a, register_count) ||
				   !valid_register(instr.b, register_count) {
					return .Bad_Register
				}
			case .Dispatch:
				if !valid_register(instr.a, register_count) {
					return .Bad_Register
				}
				if instr.b < 0 || int(instr.b) >= len(program.dispatch_specs) {
					return .Bad_Function
				}
				for role in program.dispatch_specs[instr.b].roles {
					if !valid_register(role.register, register_count) {
						return .Bad_Register
					}
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
			case .Scan_Collect, .Scan_Exists, .Scan_First:
				fmt.sbprintf(&builder, " r%d pat%d", instr.a, instr.b)
			case .Assert:
				fmt.sbprintf(&builder, " rel%d r%d", instr.a, instr.b)
			case .Retract:
				fmt.sbprintf(&builder, " rel%d r%d", instr.a, instr.b)
			case .Retract_Where:
				fmt.sbprintf(&builder, " pat%d", instr.b)
			case .Build_Relation:
				fmt.sbprintf(&builder, " r%d shape%d r%d..", instr.a, instr.b, instr.c)
			case .Index:
				fmt.sbprintf(&builder, " r%d r%d r%d", instr.a, instr.b, instr.c)
			case .Collection_Key_At, .Collection_Value_At:
				fmt.sbprintf(&builder, " r%d r%d r%d", instr.a, instr.b, instr.c)
			case .Builtin_Call:
				builtin_name, _ := v.symbol_name(program.builtins[instr.b])
				fmt.sbprintf(&builder, " r%d %s args@r%d", instr.a, builtin_name, instr.c)
			case .Commit:
				fmt.sbprintf(&builder, "")
			case .Is_Truthy:
				fmt.sbprintf(&builder, " r%d r%d", instr.a, instr.b)
			case .Scan_One:
				fmt.sbprintf(&builder, " r%d pat%d", instr.a, instr.b)
			case .Dispatch:
				fmt.sbprintf(&builder, " r%d spec%d", instr.a, instr.b)
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
	case .Scan_Collect:
		return "scan_collect"
	case .Scan_Exists:
		return "scan_exists"
	case .Scan_First:
		return "scan_first"
	case .Assert:
		return "assert"
	case .Retract:
		return "retract"
	case .Retract_Where:
		return "retract_where"
	case .Build_Relation:
		return "build_relation"
	case .Index:
		return "index"
	case .Collection_Key_At:
		return "collection_key_at"
	case .Collection_Value_At:
		return "collection_value_at"
	case .Builtin_Call:
		return "builtin_call"
	case .Commit:
		return "commit"
	case .Is_Truthy:
		return "is_truthy"
	case .Scan_One:
		return "scan_one"
	case .Dispatch:
		return "dispatch"
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
