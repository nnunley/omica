package mica_runtime

import "core:fmt"
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

@(test)
test_run_dispatch_role_call :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	source := `make_identity(:player)
make_identity(:thing)
make_identity(:alice)
make_identity(:coin)
make_relation(:Taken, 2)
assert Delegates(#alice, #player, 0)
assert Delegates(#coin, #thing, 0)
verb take(actor @ #player, item @ #thing)
  assert Taken(actor, item)
end
:take(actor: #alice, item: #coin)
`
	directory, directory_err := os.temp_dir(context.temp_allocator)
	if directory_err != nil {
		testing.expect(t, false, "cannot resolve a temporary directory")
		return
	}
	path := fmt.aprintf(
		"%s/mica_dispatch_test.mica",
		directory,
		allocator = context.temp_allocator,
	)
	if write_err := os.write_entire_file(path, source); write_err != nil {
		testing.expect(t, false, "cannot write the dispatch test file")
		return
	}
	defer os.remove(path)

	kernel: k.Kernel
	k.kernel_init(&kernel)
	defer k.kernel_destroy(&kernel)

	result := run_files(&kernel, []string{path}, context.temp_allocator)
	testing.expectf(t, result.ok, "filein failed: %s", result.message)

	expect_relation_rows(t, &kernel, "Taken", 1)
}

@(test)
test_run_dispatch_without_method_fails :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	source := "make_identity(:alice)\n:missing(actor: #alice)\n"
	directory, directory_err := os.temp_dir(context.temp_allocator)
	if directory_err != nil {
		testing.expect(t, false, "cannot resolve a temporary directory")
		return
	}
	path := fmt.aprintf(
		"%s/mica_dispatch_missing_test.mica",
		directory,
		allocator = context.temp_allocator,
	)
	if write_err := os.write_entire_file(path, source); write_err != nil {
		testing.expect(t, false, "cannot write the dispatch test file")
		return
	}
	defer os.remove(path)

	kernel: k.Kernel
	k.kernel_init(&kernel)
	defer k.kernel_destroy(&kernel)

	result := run_files(&kernel, []string{path}, context.temp_allocator)
	testing.expect(t, !result.ok)
}

@(test)
test_run_multiple_files_share_verbs :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	directory, directory_err := os.temp_dir(context.temp_allocator)
	if directory_err != nil {
		testing.expect(t, false, "cannot resolve a temporary directory")
		return
	}
	library := `make_relation(:Shared, 1)
verb shared/add(value)
  assert Shared(value)
end
`
	caller := `shared/add(7)
`
	library_path := fmt.aprintf(
		"%s/mica_library_test.mica",
		directory,
		allocator = context.temp_allocator,
	)
	caller_path := fmt.aprintf(
		"%s/mica_caller_test.mica",
		directory,
		allocator = context.temp_allocator,
	)
	if os.write_entire_file(library_path, library) != nil ||
	   os.write_entire_file(caller_path, caller) != nil {
		testing.expect(t, false, "cannot write the multi-file test files")
		return
	}
	defer os.remove(library_path)
	defer os.remove(caller_path)

	kernel: k.Kernel
	k.kernel_init(&kernel)
	defer k.kernel_destroy(&kernel)

	result := run_files(
		&kernel,
		[]string{library_path, caller_path},
		context.temp_allocator,
	)
	testing.expectf(t, result.ok, "filein failed: %s", result.message)
	expect_relation_rows(t, &kernel, "Shared", 1)
}

@(test)
test_run_spawn_task :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	source := `make_relation(:Done, 1)
verb child()
  assert Done(1)
end
spawn :child()
suspend()
`
	directory, directory_err := os.temp_dir(context.temp_allocator)
	if directory_err != nil {
		testing.expect(t, false, "cannot resolve a temporary directory")
		return
	}
	path := fmt.aprintf(
		"%s/mica_spawn_test.mica",
		directory,
		allocator = context.temp_allocator,
	)
	if write_err := os.write_entire_file(path, source); write_err != nil {
		testing.expect(t, false, "cannot write the spawn test file")
		return
	}
	defer os.remove(path)

	kernel: k.Kernel
	k.kernel_init(&kernel)
	defer k.kernel_destroy(&kernel)

	result := run_files(&kernel, []string{path}, context.temp_allocator)
	testing.expectf(t, result.ok, "filein failed: %s", result.message)

	expect_relation_rows(t, &kernel, "Done", 1)
}

@(test)
test_run_raise_reports_error :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	source := `raise E_RANGE, "out of range"
`
	directory, directory_err := os.temp_dir(context.temp_allocator)
	if directory_err != nil {
		testing.expect(t, false, "cannot resolve a temporary directory")
		return
	}
	path := fmt.aprintf(
		"%s/mica_raise_test.mica",
		directory,
		allocator = context.temp_allocator,
	)
	if write_err := os.write_entire_file(path, source); write_err != nil {
		testing.expect(t, false, "cannot write the raise test file")
		return
	}
	defer os.remove(path)

	kernel: k.Kernel
	k.kernel_init(&kernel)
	defer k.kernel_destroy(&kernel)

	result := run_files(&kernel, []string{path}, context.temp_allocator)
	testing.expect(t, !result.ok)
	testing.expectf(
		t,
		len(result.message) > 0,
		"raise should report a message, got %q",
		result.message,
	)
}

@(test)
test_run_invoke_dynamic_dispatch :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	source := `make_identity(:player)
make_identity(:alice)
make_relation(:Taken, 1)
assert Delegates(#alice, #player, 0)
verb take(actor @ #player)
  assert Taken(actor)
end
invoke(:take, {:actor -> #alice})
`
	directory, directory_err := os.temp_dir(context.temp_allocator)
	if directory_err != nil {
		testing.expect(t, false, "cannot resolve a temporary directory")
		return
	}
	path := fmt.aprintf(
		"%s/mica_invoke_test.mica",
		directory,
		allocator = context.temp_allocator,
	)
	if write_err := os.write_entire_file(path, source); write_err != nil {
		testing.expect(t, false, "cannot write the invoke test file")
		return
	}
	defer os.remove(path)

	kernel: k.Kernel
	k.kernel_init(&kernel)
	defer k.kernel_destroy(&kernel)

	result := run_files(&kernel, []string{path}, context.temp_allocator)
	testing.expectf(t, result.ok, "filein failed: %s", result.message)

	expect_relation_rows(t, &kernel, "Taken", 1)
}
