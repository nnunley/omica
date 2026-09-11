// Filein driver: compile a `.mica` file and run it against a kernel
// transaction.
//
// The driver pre-scans top-level `make_identity`, `make_relation`, and
// `make_functional_relation` declarations, installs parsed rules, compiles the
// program, registers the builtins the runtime provides, and commits at the
// end or at a `commit()` boundary.
package mica_runtime

import "core:fmt"
import "core:mem"
import "core:os"
import "core:strconv"
import "core:strings"
import c "../compiler"
import k "../kernel"
import vm "../vm"
import v "../var"

Run_Result :: struct {
	ok:      bool,
	message: string,
}

@(private)
Field_Info :: struct {
	relation:      k.Relation_ID,
	key_positions: []u16,
}

@(private)
Builtin_Env :: struct {
	kernel:    ^k.Kernel,
	ctx:       ^c.Compile_Context,
	fields:    map[string]Field_Info,
	allocator: mem.Allocator,
}

// Compiles and runs a set of fileins as one world against `kernel`. On success
// the transaction is committed.
run_files :: proc(
	kernel: ^k.Kernel,
	paths: []string,
	allocator := context.allocator,
) -> Run_Result {
	asts := make([dynamic]^c.Program_AST, allocator)
	defer delete(asts)

	for path in paths {
		data, read_err := os.read_entire_file(path, allocator)
		if read_err != nil {
			return Run_Result{ok = false, message = fmt.aprintf(
				"cannot read %s",
				path,
				allocator = allocator,
			)}
		}
		ast, parse_errors := c.parse_program(string(data), allocator)
		if len(parse_errors) > 0 {
			first := parse_errors[0]
			return Run_Result{ok = false, message = fmt.aprintf(
				"%s:%d:%d: %s",
				path,
				first.line,
				first.column,
				first.message,
				allocator = allocator,
			)}
		}
		append(&asts, ast)
	}

	ctx := c.Compile_Context {
		builtins   = make(map[string]bool, allocator),
		relations  = make(map[string]u32, allocator),
		identities = make(map[string]v.Value, allocator),
	}
	ctx.builtins["make_identity"] = true
	ctx.builtins["make_relation"] = true
	ctx.builtins["make_functional_relation"] = true
	ctx.builtins["emit"] = true
	ctx.builtins["require"] = true

	env := Builtin_Env {
		kernel    = kernel,
		ctx       = &ctx,
		fields    = make(map[string]Field_Info, allocator),
		allocator = allocator,
	}

	declarations := Declarations {
		next_relation = 1,
		next_identity = 0x1000,
		next_rule     = 1,
	}
	for ast in asts {
		result := prescan_file(&env, ast, &declarations)
		if !result.ok {
			return result
		}
	}
	for path, index in paths {
		result := install_rules(&env, kernel, asts[index], &declarations, path)
		if !result.ok {
			return result
		}
	}

	items := make([dynamic]c.Item, allocator)
	defer delete(items)
	for ast in asts {
		for item in ast.items {
			append(&items, item)
		}
	}
	program_ast := c.Program_AST {
		items = items[:],
	}

	compiled := c.compile_program(&program_ast, &ctx, allocator)
	if len(compiled.errors) > 0 {
		return Run_Result{ok = false, message = compiled.errors[0].message}
	}

	tx := k.kernel_begin(kernel)
	defer k.transaction_destroy(&tx)
	source := k.Relation_Source {
		snapshot           = kernel.current,
		use_stored_derived = true,
	}

	state: vm.VM
	vm.vm_init(&state, compiled.program, allocator)
	defer vm.vm_destroy(&state)
	vm.vm_set_workspace(&state, &source, &tx)
	state.user = &env
	register_builtins(&state)

	for {
		status := vm.vm_run(&state)
		#partial switch status {
		case .Halted:
			committed, commit_err := k.transaction_commit(&tx)
			if commit_err != k.Kernel_Error.None {
				return Run_Result{ok = false, message = "commit failed"}
			}
			k.snapshot_release(committed)
			return Run_Result{ok = true, message = "loaded"}

		case .Boundary:
			if state.request != .Commit {
				return Run_Result{ok = false, message = "unknown host request"}
			}
			committed, commit_err := k.transaction_commit(&tx)
			if commit_err != k.Kernel_Error.None {
				return Run_Result{ok = false, message = "commit failed"}
			}
			k.snapshot_release(committed)
			k.transaction_destroy(&tx)
			tx = k.kernel_begin(kernel)
			source.snapshot = kernel.current
			state.request = .None

		case .Failed:
			return Run_Result{ok = false, message = format_error(state.error, allocator)}

		case .Ready:
			return Run_Result{ok = false, message = "vm did not run"}
		}
	}
}

// Compiles and runs one filein against `kernel`. On success the transaction is
// committed.
run_filein :: proc(
	kernel: ^k.Kernel,
	path: string,
	allocator := context.allocator,
) -> Run_Result {
	return run_files(kernel, []string{path}, allocator)
}

@(private)
Declarations :: struct {
	next_relation: u32,
	next_identity: u64,
	next_rule:     u64,
}

// Pre-scans one file's top-level declarations into the shared compile context.
@(private)
prescan_file :: proc(
	env: ^Builtin_Env,
	ast: ^c.Program_AST,
	declarations: ^Declarations,
) -> Run_Result {
	ctx := env.ctx
	for item in ast.items {
		expression: ^c.Expr
		#partial switch matched in item {
		case c.Expr_Item:
			expression = matched.expr
		case:
			continue
		}

		if binding, is_binding := expression^.(c.Binding); is_binding {
			expression = binding.value
		}
		call, is_call := expression^.(c.Call)
		if !is_call {
			continue
		}
		callee, is_name := call.callee^.(c.Name)
		if !is_name {
			continue
		}
		declared := name_text(callee)

		switch declared {
		case "make_identity":
			if len(call.args) < 1 {
				continue
			}
			symbol_name := symbol_text(call.args[0].expr)
			if symbol_name == "" {
				continue
			}
			if _, exists := ctx.identities[symbol_name]; exists {
				continue
			}
			identity_value, identity_ok := v.value_identity_raw(declarations.next_identity)
			if identity_ok {
				ctx.identities[symbol_name] = identity_value
				declarations.next_identity += 1
			}

		case "make_relation", "make_functional_relation":
			if len(call.args) < 2 {
				continue
			}
			relation_name := symbol_text(call.args[0].expr)
			arity := int_argument(call.args[1].expr)
			if relation_name == "" || arity <= 0 {
				continue
			}
			if _, exists := ctx.relations[relation_name]; exists {
				continue
			}

			metadata := k.relation_metadata(
				k.Relation_ID(declarations.next_relation),
				v.symbol_intern(relation_name),
				u16(arity),
			)
			functional_keys: [dynamic]u16
			if declared == "make_functional_relation" && len(call.args) >= 3 {
				if list, is_list := call.args[2].expr^.(c.List_Literal); is_list {
					for element in list.elements {
						position := int_argument(element)
						if position >= 0 {
							append(&functional_keys, u16(position))
						}
					}
				}
				metadata.conflict = k.conflict_functional(functional_keys[:])
			}

			created, create_err := k.kernel_create_relation(env.kernel, metadata)
			if create_err != k.Kernel_Error.None {
				delete(functional_keys)
				return Run_Result{ok = false, message = fmt.aprintf(
					"cannot create relation %s: %v",
					relation_name,
					create_err,
					allocator = env.allocator,
				)}
			}
			k.snapshot_release(created)
			ctx.relations[relation_name] = declarations.next_relation

			if metadata.conflict.kind == .Functional {
				key_positions := make([]u16, len(metadata.conflict.key_positions), env.allocator)
				copy(key_positions, metadata.conflict.key_positions)
				env.fields[lower_first(relation_name, env.allocator)] = Field_Info {
					relation      = k.Relation_ID(declarations.next_relation),
					key_positions = key_positions,
				}
			}
			delete(functional_keys)
			declarations.next_relation += 1
		}
	}
	return Run_Result{ok = true, message = "loaded"}
}

// Installs one file's rules into the kernel.
@(private)
install_rules :: proc(
	env: ^Builtin_Env,
	kernel: ^k.Kernel,
	ast: ^c.Program_AST,
	declarations: ^Declarations,
	path: string,
) -> Run_Result {
	for item in ast.items {
		rule_item, is_rule := item.(c.Rule_Item)
		if !is_rule {
			continue
		}
		rule, rule_ok := convert_rule(rule_item, env.ctx)
		if !rule_ok {
			return Run_Result{ok = false, message = fmt.aprintf(
				"%s: could not lower a rule",
				path,
				allocator = env.allocator,
			)}
		}
		installed, install_err := k.kernel_install_rule(
			kernel,
			v.Identity(declarations.next_rule),
			rule,
			path,
		)
		if install_err != k.Kernel_Error.None {
			return Run_Result{ok = false, message = fmt.aprintf(
				"%s: rule install failed: %v",
				path,
				install_err,
				allocator = env.allocator,
			)}
		}
		k.snapshot_release(installed)
		declarations.next_rule += 1
	}
	return Run_Result{ok = true, message = "loaded"}
}

// --- Builtins --------------------------------------------------------------

@(private)
register_builtins :: proc(state: ^vm.VM) {
	vm.vm_register_builtin(state, v.symbol_intern("make_identity"), 1, builtin_make_identity)
	vm.vm_register_builtin(state, v.symbol_intern("make_relation"), 2, builtin_relation)
	vm.vm_register_builtin(
		state,
		v.symbol_intern("make_functional_relation"),
		3,
		builtin_relation,
	)
	vm.vm_register_builtin(state, v.symbol_intern("__set_field"), 3, builtin_set_field)
	vm.vm_register_builtin(state, v.symbol_intern("__get_field"), 2, builtin_get_field)
	vm.vm_register_builtin(state, v.symbol_intern("emit"), 2, builtin_noop)
	vm.vm_register_builtin(state, v.symbol_intern("require"), 1, builtin_require)
}

@(private)
builtin_env :: proc(state: ^vm.VM) -> ^Builtin_Env {
	return (^Builtin_Env)(state.user)
}

@(private)
builtin_make_identity :: proc(state: ^vm.VM, args: []v.Value) -> (v.Value, bool) {
	env := builtin_env(state)
	symbol, is_symbol := v.value_as_symbol(args[0])
	if !is_symbol {
		vm.vm_set_error(state, "E_TYPE", "make_identity expects a symbol")
		return v.Value(0), false
	}
	name, name_ok := v.symbol_name(symbol)
	if !name_ok {
		vm.vm_set_error(state, "E_IDENTITY", "unknown identity name")
		return v.Value(0), false
	}
	value, found := env.ctx.identities[name]
	if !found {
		vm.vm_set_error(state, "E_IDENTITY", "identity was not declared")
		return v.Value(0), false
	}
	return value, true
}

@(private)
builtin_relation :: proc(state: ^vm.VM, args: []v.Value) -> (v.Value, bool) {
	return v.value_empty_relation(), true
}

@(private)
builtin_noop :: proc(state: ^vm.VM, args: []v.Value) -> (v.Value, bool) {
	return v.value_empty_relation(), true
}

@(private)
builtin_require :: proc(state: ^vm.VM, args: []v.Value) -> (v.Value, bool) {
	if !vm.vm_value_is_truthy(args[0]) {
		vm.vm_set_error(state, "E_REQUIRE", "required condition is not satisfied")
		return v.Value(0), false
	}
	return v.value_bool(true), true
}

@(private)
builtin_set_field :: proc(state: ^vm.VM, args: []v.Value) -> (v.Value, bool) {
	env := builtin_env(state)
	if state.transaction == nil {
		vm.vm_set_error(state, "E_NO_TRANSACTION", "field write outside a transaction")
		return v.Value(0), false
	}

	symbol, is_symbol := v.value_as_symbol(args[1])
	if !is_symbol {
		vm.vm_set_error(state, "E_TYPE", "field name must be a symbol")
		return v.Value(0), false
	}
	name, name_ok := v.symbol_name(symbol)
	if !name_ok {
		vm.vm_set_error(state, "E_FIELD", "unknown field")
		return v.Value(0), false
	}
	info, found := env.fields[name]
	if !found || len(info.key_positions) == 0 {
		vm.vm_set_error(state, "E_FIELD", "unknown functional field")
		return v.Value(0), false
	}

	receiver := args[0]
	value := args[2]
	key_values := make([]v.Value, len(info.key_positions), context.temp_allocator)
	for position, index in info.key_positions {
		if position != 0 {
			vm.vm_set_error(state, "E_FIELD", "only a first-position key is supported")
			return v.Value(0), false
		}
		key_values[index] = receiver
	}

	existing, has_existing := k.transaction_tuple_for_key(
		state.transaction,
		info.relation,
		info.key_positions,
		key_values,
	)

	metadata, metadata_found := k.snapshot_relation_metadata(env.kernel.current, info.relation)
	if !metadata_found || metadata.arity != 2 {
		vm.vm_set_error(state, "E_FIELD", "only binary functional relations are supported")
		return v.Value(0), false
	}

	new_tuple := v.tuple_new(env.allocator, []v.Value{receiver, value})
	if has_existing {
		if v.tuple_eq(existing, new_tuple) {
			return value, true
		}
		if err := k.transaction_retract(state.transaction, info.relation, existing); err != .None {
			vm.vm_set_error(state, "E_FIELD", "could not replace the functional tuple")
			return v.Value(0), false
		}
	}
	if err := k.transaction_assert(state.transaction, info.relation, new_tuple); err != .None {
		vm.vm_set_error(state, "E_FIELD", "could not assert the functional tuple")
		return v.Value(0), false
	}
	return value, true
}

@(private)
builtin_get_field :: proc(state: ^vm.VM, args: []v.Value) -> (v.Value, bool) {
	env := builtin_env(state)
	if state.transaction == nil {
		vm.vm_set_error(state, "E_NO_TRANSACTION", "field read outside a transaction")
		return v.Value(0), false
	}
	symbol, is_symbol := v.value_as_symbol(args[1])
	if !is_symbol {
		vm.vm_set_error(state, "E_TYPE", "field name must be a symbol")
		return v.Value(0), false
	}
	name, name_ok := v.symbol_name(symbol)
	if !name_ok {
		vm.vm_set_error(state, "E_FIELD", "unknown field")
		return v.Value(0), false
	}
	info, found := env.fields[name]
	if !found || len(info.key_positions) != 1 || info.key_positions[0] != 0 {
		vm.vm_set_error(state, "E_FIELD", "unknown functional field")
		return v.Value(0), false
	}

	key_values := []v.Value{args[0]}
	existing, has_existing := k.transaction_tuple_for_key(
		state.transaction,
		info.relation,
		info.key_positions,
		key_values,
	)
	if !has_existing {
		vm.vm_set_error(state, "E_KEY", "no field value")
		return v.Value(0), false
	}
	return v.tuple_values(existing)[1], true
}

// --- Helpers ---------------------------------------------------------------

@(private)
symbol_text :: proc(expr: ^c.Expr) -> string {
	symbol, is_symbol := expr^.(c.Symbol_Literal)
	if !is_symbol {
		return ""
	}
	if strings.has_prefix(symbol.name, "\"") && len(symbol.name) >= 2 {
		return symbol.name[1 : len(symbol.name) - 1]
	}
	return symbol.name
}

@(private)
int_argument :: proc(expr: ^c.Expr) -> int {
	literal, is_literal := expr^.(c.Int_Literal)
	if !is_literal {
		return -1
	}
	value, ok := strconv.parse_i64(literal.text)
	if !ok {
		return -1
	}
	return int(value)
}

@(private)
lower_first :: proc(name: string, allocator: mem.Allocator) -> string {
	if len(name) == 0 {
		return name
	}
	builder: strings.Builder
	strings.builder_init(&builder, allocator)
	first := name[0]
	if first >= 'A' && first <= 'Z' {
		first += 'a' - 'A'
	}
	strings.write_byte(&builder, first)
	strings.write_string(&builder, name[1:])
	return strings.to_string(builder)
}

@(private)
format_error :: proc(error_value: v.Value, allocator: mem.Allocator) -> string {
	if error, is_error := v.value_as_error(error_value); is_error {
		code_name := "E_UNKNOWN"
		if name, name_ok := v.symbol_name(error.code); name_ok {
			code_name = name
		}
		if error.has_message {
			return fmt.aprintf("%s: %s", code_name, error.message, allocator = allocator)
		}
		return strings.clone(code_name, allocator)
	}
	return v.value_to_string(error_value, allocator)
}
