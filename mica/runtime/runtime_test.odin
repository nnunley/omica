package mica_runtime

import "core:os"
import "core:testing"
import c "../compiler"
import k "../kernel"
import vm "../vm"
import v "../var"

@(private)
corpus_candidate :: proc(name: string) -> string {
	candidates := []string{
		"apps/shared/capabilities.mica",
		"../apps/shared/capabilities.mica",
		"../../apps/shared/capabilities.mica",
	}
	for candidate in candidates {
		if os.is_file(candidate) {
			return candidate
		}
	}
	return ""
}

@(private)
expect_relation_rows :: proc(t: ^testing.T, kernel: ^k.Kernel, name: string, expected: int) {
	metadata, found := k.snapshot_relation_metadata_named(kernel.current, v.symbol_intern(name))
	testing.expect(t, found)
	if !found {
		return
	}
	bindings := make([]v.Binding, metadata.arity, context.temp_allocator)
	rows: [dynamic]v.Tuple
	k.kernel_scan_into(kernel, metadata.id, bindings, &rows)
	testing.expectf(t, len(rows) == expected, "%s has %d rows, expected %d", name, len(rows), expected)
	delete(rows)
}

@(test)
test_run_capabilities_filein :: proc(t: ^testing.T) {
	path := corpus_candidate("apps/shared/capabilities.mica")
	if path == "" {
		testing.expect(t, false, "capabilities.mica not found")
		return
	}

	kernel: k.Kernel
	k.kernel_init(&kernel)
	defer k.kernel_destroy(&kernel)

	result := run_filein(&kernel, path, context.temp_allocator)
	testing.expectf(t, result.ok, "filein failed: %s", result.message)

	expect_relation_rows(t, &kernel, "Delegates", 3)
	expect_relation_rows(t, &kernel, "Name", 1)
	expect_relation_rows(t, &kernel, "HasRole", 2)
	expect_relation_rows(t, &kernel, "RelationInSurface", 2)
}

@(private)
compile_and_run :: proc(
	t: ^testing.T,
	source: string,
	ctx: ^c.Compile_Context,
) -> vm.VM {
	ast, parse_errors := c.parse_program(source, context.temp_allocator)
	testing.expectf(t, len(parse_errors) == 0, "parse errors for %q: %v", source, parse_errors)
	compiled := c.compile_program(ast, ctx, context.temp_allocator)
	testing.expectf(t, len(compiled.errors) == 0, "compile errors for %q: %v", source, compiled.errors)

	state: vm.VM
	vm.vm_init(&state, compiled.program, context.temp_allocator)
	register_runtime_builtins(&state)
	testing.expectf(t, vm.vm_run(&state) == .Halted, "vm did not halt for %q", source)
	return state
}

@(test)
test_builtin_string_surface :: proc(t: ^testing.T) {
	ctx := c.Compile_Context {
		builtins   = make(map[string]bool),
		relations  = make(map[string]u32),
		identities = make(map[string]v.Value),
	}
	defer delete(ctx.builtins)
	defer delete(ctx.relations)
	defer delete(ctx.identities)
	install_builtin_names(&ctx)

	state := compile_and_run(
		t,
		"string_concat(\"a\", string_from_chars(string_chars(\"bc\")))",
		&ctx,
	)
	defer vm.vm_destroy(&state)
	text, ok := v.value_as_string(state.result)
	testing.expect(t, ok)
	testing.expect_value(t, text, "abc")
}

@(test)
test_builtin_splice_and_set_index :: proc(t: ^testing.T) {
	ctx := c.Compile_Context {
		builtins   = make(map[string]bool),
		relations  = make(map[string]u32),
		identities = make(map[string]v.Value),
	}
	defer delete(ctx.builtins)
	defer delete(ctx.relations)
	defer delete(ctx.identities)
	install_builtin_names(&ctx)

	state := compile_and_run(t, "let xs = [1, 2]\n[@xs, 3]", &ctx)
	defer vm.vm_destroy(&state)
	values, ok := v.value_as_list(state.result)
	testing.expect(t, ok)
	testing.expect_value(t, len(values), 3)

	indexed := compile_and_run(t, "let m = {:a -> 1}\nm[:b] = 2\nm", &ctx)
	defer vm.vm_destroy(&indexed)
	entries, map_ok := v.value_as_map(indexed.result)
	testing.expect(t, map_ok)
	testing.expect_value(t, len(entries), 2)
}

@(test)
test_primitive_identity_prototypes :: proc(t: ^testing.T) {
	ctx := c.Compile_Context {
		builtins   = make(map[string]bool),
		relations  = make(map[string]u32),
		identities = make(map[string]v.Value),
	}
	defer delete(ctx.builtins)
	defer delete(ctx.relations)
	defer delete(ctx.identities)
	install_builtin_names(&ctx)
	install_primitive_identities(&ctx)

	state := compile_and_run(t, "#string", &ctx)
	defer vm.vm_destroy(&state)
	identity, ok := v.value_as_identity(state.result)
	testing.expect(t, ok)
	testing.expect_value(t, v.identity_raw(identity), u64(v.STRING_PROTOTYPE))
}
