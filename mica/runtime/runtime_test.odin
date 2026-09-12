package mica_runtime

import "core:fmt"
import "core:strings"
import "core:os"
import "core:path/filepath"
import "core:testing"
import "core:time"
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

@(private)
expect_int_builtin :: proc(
	t: ^testing.T,
	ctx: ^c.Compile_Context,
	source: string,
	expected: i64,
) {
	state := compile_and_run(t, source, ctx)
	defer vm.vm_destroy(&state)
	value, ok := v.value_as_int(state.result)
	testing.expectf(t, ok, "%s: result is not an int", source)
	if ok {
		testing.expectf(t, value == expected, "%s = %d, expected %d", source, value, expected)
	}
}

@(private)
expect_string_builtin :: proc(
	t: ^testing.T,
	ctx: ^c.Compile_Context,
	source: string,
	expected: string,
) {
	state := compile_and_run(t, source, ctx)
	defer vm.vm_destroy(&state)
	value, ok := v.value_as_string(state.result)
	testing.expectf(t, ok, "%s: result is not a string", source)
	if ok {
		testing.expectf(t, value == expected, "%s = %q, expected %q", source, value, expected)
	}
}

@(private)
expect_bool_builtin :: proc(
	t: ^testing.T,
	ctx: ^c.Compile_Context,
	source: string,
	expected: bool,
) {
	state := compile_and_run(t, source, ctx)
	defer vm.vm_destroy(&state)
	value, ok := v.value_as_bool(state.result)
	testing.expectf(t, ok, "%s: result is not a bool", source)
	if ok {
		testing.expectf(t, value == expected, "%s = %v, expected %v", source, value, expected)
	}
}

@(private)
expect_builtin_error :: proc(
	t: ^testing.T,
	ctx: ^c.Compile_Context,
	source: string,
	expected_code: string,
) {
	ast, parse_errors := c.parse_program(source, context.temp_allocator)
	testing.expectf(t, len(parse_errors) == 0, "parse errors for %q: %v", source, parse_errors)
	compiled := c.compile_program(ast, ctx, context.temp_allocator)
	testing.expectf(t, len(compiled.errors) == 0, "compile errors for %q: %v", source, compiled.errors)

	state: vm.VM
	vm.vm_init(&state, compiled.program, context.temp_allocator)
	defer vm.vm_destroy(&state)
	register_runtime_builtins(&state)
	testing.expectf(t, vm.vm_run(&state) == .Failed, "%s should fail", source)
	error, error_ok := v.value_as_error(state.error)
	testing.expectf(t, error_ok, "%s: no error value", source)
	if error_ok {
		code, _ := v.symbol_name(error.code)
		testing.expectf(t, code == expected_code, "%s raised %s, expected %s", source, code, expected_code)
	}
}

@(test)
test_scalar_builtins :: proc(t: ^testing.T) {
	ctx := c.Compile_Context {
		builtins   = make(map[string]bool),
		relations  = make(map[string]u32),
		identities = make(map[string]v.Value),
	}
	defer delete(ctx.builtins)
	defer delete(ctx.relations)
	defer delete(ctx.identities)
	install_builtin_names(&ctx)

	expect_int_builtin(t, &ctx, `string_len("héllo")`, 5)
	expect_string_builtin(t, &ctx, `string_slice("héllo", 1, 4)`, "éll")
	expect_string_builtin(t, &ctx, `string_join(["a", "b", "c"], "-")`, "a-b-c")
	expect_bool_builtin(t, &ctx, `string_starts_with("hello", "he")`, true)
	expect_bool_builtin(t, &ctx, `string_starts_with("hello", "lo")`, false)
	expect_bool_builtin(t, &ctx, `string_contains("hello", "ell")`, true)
	expect_bool_builtin(t, &ctx, `string_contains("hello", "xyz")`, false)
	expect_bool_builtin(t, &ctx, `string_equal_fold("HeLLo", "hello")`, true)
	expect_string_builtin(t, &ctx, `lower("HeLLo")`, "hello")
	expect_int_builtin(t, &ctx, `edit_distance("kitten", "sitting")`, 3)
	expect_string_builtin(
		t,
		&ctx,
		`url_decode_component(url_encode_component("a b&c"))`,
		"a b&c",
	)
	expect_int_builtin(t, &ctx, `len(sort([3, 1, 2]))`, 3)

	expect_builtin_error(t, &ctx, `string_len(1)`, "E_TYPE")
	expect_builtin_error(t, &ctx, `string_slice("abc", 2, 1)`, "E_INDEX")
	expect_builtin_error(t, &ctx, `string_slice("abc", 0, 9)`, "E_INDEX")
	expect_builtin_error(t, &ctx, `string_slice("abc", "a", 1)`, "E_TYPE")
	expect_builtin_error(t, &ctx, `string_join([1], "-")`, "E_TYPE")
	expect_builtin_error(t, &ctx, `lower(3)`, "E_TYPE")
	expect_builtin_error(t, &ctx, `words(3)`, "E_TYPE")
	expect_builtin_error(t, &ctx, `sort(1)`, "E_TYPE")
	expect_builtin_error(t, &ctx, `edit_distance(1, "a")`, "E_TYPE")
	expect_builtin_error(t, &ctx, `map_pairs([1])`, "E_TYPE")
	expect_builtin_error(t, &ctx, `url_decode_component("%zz")`, "E_URL")
}

@(test)
test_builtin_splice_and_set_index :: proc(t: ^testing.T) {	ctx := c.Compile_Context {
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

@(test)
test_run_match_expression :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	source := `make_relation(:Score, 1)
make_relation(:Failed, 1)
verb classify(text)
  return match parse_ordinal(text)
  case ok(value) if value >= 0
    value
  case ok(ignored)
    -1
  case err(problem)
    -2
  end
end
assert Score(classify("7"))
assert Failed(classify("banana"))
`
	directory, directory_err := os.temp_dir(context.temp_allocator)
	if directory_err != nil {
		testing.expect(t, false, "cannot resolve a temporary directory")
		return
	}
	path := fmt.aprintf(
		"%s/mica_match_test.mica",
		directory,
		allocator = context.temp_allocator,
	)
	if write_err := os.write_entire_file(path, source); write_err != nil {
		testing.expect(t, false, "cannot write the match test file")
		return
	}
	defer os.remove(path)

	kernel: k.Kernel
	k.kernel_init(&kernel)
	defer k.kernel_destroy(&kernel)

	result := run_files(&kernel, []string{path}, context.temp_allocator)
	testing.expectf(t, result.ok, "filein failed: %s", result.message)

	expect_relation_rows(t, &kernel, "Score", 1)
	expect_relation_rows(t, &kernel, "Failed", 1)
}

@(test)
test_run_from_literal_and_to_xml :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	source := `make_identity(:alice)
make_relation(:Entity, 1)
make_relation(:Markup, 1)
verb entity_from_literal(text)
  return match from_literal(text)
  case ok(value)
    value
  case err(problem)
    none
  end
end
assert Entity(entity_from_literal("#alice"))
assert Markup(to_xml(dom <p class="note">hi</p>))
`
	directory, directory_err := os.temp_dir(context.temp_allocator)
	if directory_err != nil {
		testing.expect(t, false, "cannot resolve a temporary directory")
		return
	}
	path := fmt.aprintf(
		"%s/mica_literal_xml_test.mica",
		directory,
		allocator = context.temp_allocator,
	)
	if write_err := os.write_entire_file(path, source); write_err != nil {
		testing.expect(t, false, "cannot write the literal/XML test file")
		return
	}
	defer os.remove(path)

	kernel: k.Kernel
	k.kernel_init(&kernel)
	defer k.kernel_destroy(&kernel)

	result := run_files(&kernel, []string{path}, context.temp_allocator)
	testing.expectf(t, result.ok, "filein failed: %s", result.message)

	expect_relation_rows(t, &kernel, "Entity", 1)
	expect_relation_rows(t, &kernel, "Markup", 1)
}

@(test)
test_run_mud_app_world :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	core := corpus_candidate("apps/mud/core.mica")
	if core == "" {
		testing.expect(t, false, "mud corpus not found")
		return
	}
	apps := filepath.dir(filepath.dir(core))
	names := []string {
		"shared/string.mica",
		"shared/events.mica",
		"shared/retrieval.mica",
		"shared/sync-host.mica",
		"shared/sync-dom.mica",
		"mud/core.mica",
		"mud/auth.mica",
		"mud/command-parser.mica",
		"mud/event-substitutions.mica",
		"mud/ui-session.mica",
		"mud/ui-actions.mica",
		"mud/ui-compose.mica",
		"mud/ui-narrative.mica",
		"mud/ui-mica-inspect.mica",
		"mud/ui-retrieval.mica",
		"mud/http.mica",
	}
	paths := make([]string, len(names), context.temp_allocator)
	for name, index in names {
		joined, join_err := filepath.join(
			[]string{apps, name},
			context.temp_allocator,
		)
		if join_err != nil {
			testing.expect(t, false, "cannot join a corpus path")
			return
		}
		paths[index] = joined
	}

	kernel: k.Kernel
	k.kernel_init(&kernel)
	defer k.kernel_destroy(&kernel)

	result := run_files(&kernel, paths, context.temp_allocator)
	testing.expectf(t, result.ok, "mud world failed: %s", result.message)
}

@(test)
test_run_records_catalog_facts :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	source := `make_relation(:Widget, 2)
make_relation(:Parent, 2)
Parent(child, parent) :-
  Widget(child, parent)
`
	directory, directory_err := os.temp_dir(context.temp_allocator)
	if directory_err != nil {
		testing.expect(t, false, "cannot resolve a temporary directory")
		return
	}
	path := fmt.aprintf(
		"%s/mica_catalog_test.mica",
		directory,
		allocator = context.temp_allocator,
	)
	if write_err := os.write_entire_file(path, source); write_err != nil {
		testing.expect(t, false, "cannot write the catalog test file")
		return
	}
	defer os.remove(path)

	kernel: k.Kernel
	k.kernel_init(&kernel)
	defer k.kernel_destroy(&kernel)

	result := run_files(&kernel, []string{path}, context.temp_allocator)
	testing.expectf(t, result.ok, "filein failed: %s", result.message)

	widget, widget_found := k.snapshot_relation_metadata_named(
		k.kernel_snapshot(&kernel),
		v.symbol_intern("Widget"),
	)
	testing.expect(t, widget_found)

	names: [dynamic]v.Tuple
	defer delete(names)
	k.kernel_scan_into(
		&kernel,
		k.SYSTEM_RELATION_NAME_ID,
		[]v.Binding{{}, {}},
		&names,
	)
	found_name := false
	for row in names {
		values := v.tuple_values(row)
		if len(values) == 2 && v.value_eq(values[1], v.value_symbol(v.symbol_intern("Widget"))) {
			found_name = true
		}
	}
	testing.expect(t, found_name)

	arity_rows: [dynamic]v.Tuple
	defer delete(arity_rows)
	k.kernel_scan_into(
		&kernel,
		k.SYSTEM_ARITY_ID,
		[]v.Binding{{}, {}},
		&arity_rows,
	)
	found_arity := false
	for row in arity_rows {
		values := v.tuple_values(row)
		if len(values) != 2 {
			continue
		}
		raw, raw_ok := v.value_as_identity(values[0])
		arity, arity_ok := v.value_as_int(values[1])
		if raw_ok && arity_ok && u64(v.identity_raw(raw)) == u64(widget.id) && arity == 2 {
			found_arity = true
		}
	}
	testing.expect(t, found_arity)

	rule_rows: [dynamic]v.Tuple
	defer delete(rule_rows)
	k.kernel_scan_into(&kernel, k.SYSTEM_RULE_ID, []v.Binding{{}}, &rule_rows)
	testing.expect(t, len(rule_rows) >= 1)

	source_rows: [dynamic]v.Tuple
	defer delete(source_rows)
	k.kernel_scan_into(
		&kernel,
		k.SYSTEM_RULE_SOURCE_ID,
		[]v.Binding{{}, {}},
		&source_rows,
	)
	testing.expect(t, len(source_rows) >= 1)
}

@(test)
test_run_try_catch_codes :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	source := `make_relation(:Matched, 2)
verb probe(mode)
  try
    if mode == 1
      raise E_RANGE, "bad"
    elseif mode == 2
      raise E_TYPE, "wrong"
    end
    return 7
  catch E_RANGE
    return 1
  catch E_TYPE as err
    return 2
  end
end
assert Matched(probe(1), 1)
assert Matched(probe(2), 2)
assert Matched(probe(0), 7)
`
	directory, directory_err := os.temp_dir(context.temp_allocator)
	if directory_err != nil {
		testing.expect(t, false, "cannot resolve a temporary directory")
		return
	}
	path := fmt.aprintf(
		"%s/mica_try_codes_test.mica",
		directory,
		allocator = context.temp_allocator,
	)
	if write_err := os.write_entire_file(path, source); write_err != nil {
		testing.expect(t, false, "cannot write the try test file")
		return
	}
	defer os.remove(path)

	kernel: k.Kernel
	k.kernel_init(&kernel)
	defer k.kernel_destroy(&kernel)

	result := run_files(&kernel, []string{path}, context.temp_allocator)
	testing.expectf(t, result.ok, "filein failed: %s", result.message)
	expect_relation_rows(t, &kernel, "Matched", 3)
}

@(test)
test_run_try_catches_builtin_error :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	source := `make_relation(:Caught, 1)
verb indexed()
  try
    let items = [10]
    return items[4]
  catch err
    assert Caught(1)
    return 0
  end
end
assert Caught(indexed())
`
	directory, directory_err := os.temp_dir(context.temp_allocator)
	if directory_err != nil {
		testing.expect(t, false, "cannot resolve a temporary directory")
		return
	}
	path := fmt.aprintf(
		"%s/mica_try_builtin_test.mica",
		directory,
		allocator = context.temp_allocator,
	)
	if write_err := os.write_entire_file(path, source); write_err != nil {
		testing.expect(t, false, "cannot write the try builtin test file")
		return
	}
	defer os.remove(path)

	kernel: k.Kernel
	k.kernel_init(&kernel)
	defer k.kernel_destroy(&kernel)

	result := run_files(&kernel, []string{path}, context.temp_allocator)
	testing.expectf(t, result.ok, "filein failed: %s", result.message)
	expect_relation_rows(t, &kernel, "Caught", 2)
}

@(test)
test_run_try_finally_paths :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	source := `make_relation(:Cleanup, 1)
verb clean_normal()
  let value = 0
  try
    value = 3
  finally
    assert Cleanup(1)
  end
  return value
end
assert Cleanup(clean_normal())

verb clean_error()
  try
    raise E_RANGE, "bad"
  finally
    assert Cleanup(2)
  end
end
try
  clean_error()
catch err
  assert Cleanup(3)
end
`
	directory, directory_err := os.temp_dir(context.temp_allocator)
	if directory_err != nil {
		testing.expect(t, false, "cannot resolve a temporary directory")
		return
	}
	path := fmt.aprintf(
		"%s/mica_try_finally_test.mica",
		directory,
		allocator = context.temp_allocator,
	)
	if write_err := os.write_entire_file(path, source); write_err != nil {
		testing.expect(t, false, "cannot write the try finally test file")
		return
	}
	defer os.remove(path)

	kernel: k.Kernel
	k.kernel_init(&kernel)
	defer k.kernel_destroy(&kernel)

	result := run_files(&kernel, []string{path}, context.temp_allocator)
	testing.expectf(t, result.ok, "filein failed: %s", result.message)
	expect_relation_rows(t, &kernel, "Cleanup", 3)
}

@(test)
test_run_uncaught_inner_raise_propagates :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	source := `verb probe()
  try
    raise E_RANGE, "bad"
  catch E_TYPE
    return 1
  end
  return 0
end
probe()
`
	directory, directory_err := os.temp_dir(context.temp_allocator)
	if directory_err != nil {
		testing.expect(t, false, "cannot resolve a temporary directory")
		return
	}
	path := fmt.aprintf(
		"%s/mica_try_unmatched_test.mica",
		directory,
		allocator = context.temp_allocator,
	)
	if write_err := os.write_entire_file(path, source); write_err != nil {
		testing.expect(t, false, "cannot write the try unmatched test file")
		return
	}
	defer os.remove(path)

	kernel: k.Kernel
	k.kernel_init(&kernel)
	defer k.kernel_destroy(&kernel)

	result := run_files(&kernel, []string{path}, context.temp_allocator)
	testing.expect(t, !result.ok)
}

@(private)
write_temp_source :: proc(t: ^testing.T, name: string, source: string) -> (string, bool) {
	directory, directory_err := os.temp_dir(context.temp_allocator)
	if directory_err != nil {
		testing.expect(t, false, "cannot resolve a temporary directory")
		return "", false
	}
	path := fmt.aprintf(
		"%s/%s",
		directory,
		name,
		allocator = context.temp_allocator,
	)
	if write_err := os.write_entire_file(path, source); write_err != nil {
		testing.expect(t, false, "cannot write the test file")
		return "", false
	}
	return path, true
}

@(test)
test_run_mailbox_roundtrip :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	source := `make_relation(:Got, 1)
let [receiver, sender] = mailbox()
mailbox_send(sender, 42)
let ready = mailbox_recv([receiver])
let first = ready[0][1][0]
assert Got(first)
mailbox_close(receiver)
`
	path, path_ok := write_temp_source(t, "mica_mailbox_test.mica", source)
	if !path_ok {
		return
	}
	defer os.remove(path)

	kernel: k.Kernel
	k.kernel_init(&kernel)
	defer k.kernel_destroy(&kernel)

	result := run_files(&kernel, []string{path}, context.temp_allocator)
	testing.expectf(t, result.ok, "filein failed: %s", result.message)
	expect_relation_rows(t, &kernel, "Got", 1)
}

@(test)
test_run_mailbox_wakes_waiter :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	source := `make_relation(:Got, 1)
verb deliver(receiver, sender_cap)
  mailbox_send(sender_cap, 7)
end
let [receiver, sender] = mailbox()
spawn :deliver(receiver: receiver, sender_cap: sender)
let ready = mailbox_recv([receiver])
let first = ready[0][1][0]
assert Got(first)
`
	path, path_ok := write_temp_source(t, "mica_mailbox_wake_test.mica", source)
	if !path_ok {
		return
	}
	defer os.remove(path)

	kernel: k.Kernel
	k.kernel_init(&kernel)
	defer k.kernel_destroy(&kernel)

	result := run_files(&kernel, []string{path}, context.temp_allocator)
	testing.expectf(t, result.ok, "filein failed: %s", result.message)
	expect_relation_rows(t, &kernel, "Got", 1)
}

@(test)
test_run_mailbox_timeout :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	source := `make_relation(:TimedOut, 1)
let [receiver, sender] = mailbox()
let ready = mailbox_recv([receiver], 1)
require(ready == [])
assert TimedOut(1)
`
	path, path_ok := write_temp_source(t, "mica_mailbox_timeout_test.mica", source)
	if !path_ok {
		return
	}
	defer os.remove(path)

	kernel: k.Kernel
	k.kernel_init(&kernel)
	defer k.kernel_destroy(&kernel)

	result := run_files(&kernel, []string{path}, context.temp_allocator)
	testing.expectf(t, result.ok, "filein failed: %s", result.message)
	expect_relation_rows(t, &kernel, "TimedOut", 1)
}

@(test)
test_run_fn_literals :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	source := `make_relation(:Result, 2)
verb apply(f, x)
  return f(x)
end
let double = fn(x) => x * 2
let inc = fn(x)
  return x + 1
end
let choosers = [fn(x) => x + 1]
assert Result(1, apply(double, 21))
assert Result(2, inc(41))
assert Result(3, choosers[0](41))
let nested = fn(x) => (fn(y) => y * 3)(x)
assert Result(4, nested(14))
`
	path, path_ok := write_temp_source(t, "mica_fn_test.mica", source)
	if !path_ok {
		return
	}
	defer os.remove(path)

	kernel: k.Kernel
	k.kernel_init(&kernel)
	defer k.kernel_destroy(&kernel)

	result := run_files(&kernel, []string{path}, context.temp_allocator)
	testing.expectf(t, result.ok, "filein failed: %s", result.message)
	expect_relation_rows(t, &kernel, "Result", 4)
}

@(test)
test_run_fn_captures :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	source := `make_relation(:Result, 2)
let base = 10
let add = fn(x) => x + base
assert Result(1, add(5))
base = 100
assert Result(2, add(5))
verb apply(f, x)
  return f(x)
end
assert Result(3, apply(add, 5))
let outer = fn(x)
  let scale = 3
  return fn(y) => (x + y) * scale
end
assert Result(4, outer(2)(4))
let makers = []
for i in [1, 2]
  makers = [@makers, fn() => i]
end
assert Result(5, makers[0]())
assert Result(6, makers[1]())
assert Result(7, [{:f -> add}][0][:f](5))
`
	path, path_ok := write_temp_source(t, "mica_fn_capture_test.mica", source)
	if !path_ok {
		return
	}
	defer os.remove(path)

	kernel: k.Kernel
	k.kernel_init(&kernel)
	defer k.kernel_destroy(&kernel)

	result := run_files(&kernel, []string{path}, context.temp_allocator)
	testing.expectf(t, result.ok, "filein failed: %s", result.message)
	expect_relation_rows(t, &kernel, "Result", 7)
}

@(test)
test_run_byte_literals :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	source := `make_relation(:Payload, 1)
require(b"3q2-7w==" == b"3q2-7w==")
require(b"" == b"")
assert Payload(b"3q2-7w==")
`
	path, path_ok := write_temp_source(t, "mica_bytes_test.mica", source)
	if !path_ok {
		return
	}
	defer os.remove(path)

	kernel: k.Kernel
	k.kernel_init(&kernel)
	defer k.kernel_destroy(&kernel)

	result := run_files(&kernel, []string{path}, context.temp_allocator)
	testing.expectf(t, result.ok, "filein failed: %s", result.message)
	expect_relation_rows(t, &kernel, "Payload", 1)
}

@(test)
test_run_argument_splices :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	source := `make_relation(:Result, 1)
verb sum3(a, b, c)
  return a + b + c
end
let xs = [1, 2, 3]
require(sum3(@xs) == 6)
require(sum3(1, @[2, 3]) == 6)
let f = fn(a, b) => a * b
let pair = [6, 7]
require(f(@pair) == 42)
require(string_concat(@["a", "b", "c"]) == "abc")
let pick = [f]
require(pick[0](@pair) == 42)
assert Result(sum3(@xs))
`
	path, path_ok := write_temp_source(t, "mica_splice_test.mica", source)
	if !path_ok {
		return
	}
	defer os.remove(path)

	kernel: k.Kernel
	k.kernel_init(&kernel)
	defer k.kernel_destroy(&kernel)

	result := run_files(&kernel, []string{path}, context.temp_allocator)
	testing.expectf(t, result.ok, "filein failed: %s", result.message)
	expect_relation_rows(t, &kernel, "Result", 1)
}

@(test)
test_run_match_collection_patterns :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	source := `make_relation(:Out, 1)
verb classify(value)
  return match value
  case [a, b]
    a + b
  case [first, @rest]
    first + len(rest)
  case {:kind -> :pair, :left -> l, :right -> r}
    l * r
  case _
    -1
  end
end
require(classify([1, 2]) == 3)
require(classify([5, 6, 7]) == 7)
require(classify({:kind -> :pair, :left -> 3, :right -> 4}) == 12)
require(classify(:nope) == -1)
assert Out(classify([1, 2]))
`
	path, path_ok := write_temp_source(t, "mica_match_patterns_test.mica", source)
	if !path_ok {
		return
	}
	defer os.remove(path)

	kernel: k.Kernel
	k.kernel_init(&kernel)
	defer k.kernel_destroy(&kernel)

	result := run_files(&kernel, []string{path}, context.temp_allocator)
	testing.expectf(t, result.ok, "filein failed: %s", result.message)
	expect_relation_rows(t, &kernel, "Out", 1)
}

@(test)
test_run_scatter_bindings :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	source := `make_relation(:Out, 1)
let [a, b] = [1, 2]
let [first, @rest] = [10, 20, 30]
let [x, ?y = 9, @tail] = [4]
let [p, ?q, @remaining] = [4, 5, 6, 7]
require(a + b == 3)
require(first + len(rest) == 12)
require(x + y + len(tail) == 13)
require(p + q + len(remaining) == 11)
assert Out(a)
`
	path, path_ok := write_temp_source(t, "mica_scatter_test.mica", source)
	if !path_ok {
		return
	}
	defer os.remove(path)

	kernel: k.Kernel
	k.kernel_init(&kernel)
	defer k.kernel_destroy(&kernel)

	result := run_files(&kernel, []string{path}, context.temp_allocator)
	testing.expectf(t, result.ok, "filein failed: %s", result.message)
	expect_relation_rows(t, &kernel, "Out", 1)
}

@(test)
test_run_finally_on_return :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	source := `make_relation(:Cleanup, 1)
verb compute(mode)
  try
    if mode == 1
      raise E_RANGE, "bad"
    end
    return 42
  finally
    assert Cleanup(1)
  end
end
require(compute(0) == 42)
verb nested()
  try
    try
      return 7
    finally
      assert Cleanup(2)
    end
  finally
    assert Cleanup(3)
  end
end
require(nested() == 7)
verb error_return(mode)
  try
    return 5
  finally
    if mode == 1
      raise E_TYPE, "cleanup failed"
    end
  end
end
require(error_return(0) == 5)
try
  error_return(1)
catch err
  assert Cleanup(4)
end
verb loop_return()
  for i in [1, 2, 3]
    try
      if i == 2
        return i
      end
    finally
      assert Cleanup(5)
    end
  end
  return 0
end
require(loop_return() == 2)
`
	path, path_ok := write_temp_source(t, "mica_finally_return_test.mica", source)
	if !path_ok {
		return
	}
	defer os.remove(path)

	kernel: k.Kernel
	k.kernel_init(&kernel)
	defer k.kernel_destroy(&kernel)

	result := run_files(&kernel, []string{path}, context.temp_allocator)
	testing.expectf(t, result.ok, "filein failed: %s", result.message)
	expect_relation_rows(t, &kernel, "Cleanup", 5)
}

@(test)
test_run_finally_on_catch_return :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	source := `make_relation(:Cleanup, 1)
verb caught(mode)
  try
    if mode == 1
      raise E_RANGE, "bad"
    end
    return 1
  catch err
    if mode == 1
      return 2
    end
    return 3
  finally
    assert Cleanup(1)
  end
end
require(caught(1) == 2)
require(caught(0) == 1)
assert Cleanup(1)
`
	path, path_ok := write_temp_source(t, "mica_catch_return_test.mica", source)
	if !path_ok {
		return
	}
	defer os.remove(path)

	kernel: k.Kernel
	k.kernel_init(&kernel)
	defer k.kernel_destroy(&kernel)

	result := run_files(&kernel, []string{path}, context.temp_allocator)
	testing.expectf(t, result.ok, "filein failed: %s", result.message)
	expect_relation_rows(t, &kernel, "Cleanup", 1)
}

@(test)
test_run_recursion :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	source := `make_relation(:Out, 1)
let fact = fn(n)
  if n <= 1
    return 1
  end
  return n * fact(n - 1)
end
fn fib(n)
  if n < 2
    return n
  end
  return fib(n - 1) + fib(n - 2)
end
fn tripled(x) => x * 3
require(fact(5) == 120)
require(fib(10) == 55)
require(tripled(7) == 21)
let other = fn(n)
  if n <= 0
    return 0
  end
  return 1 + other(n - 1)
end
require(other(4) == 4)
require(fact(4) == 24)
assert Out(fact(5))
`
	path, path_ok := write_temp_source(t, "mica_recursion_test.mica", source)
	if !path_ok {
		return
	}
	defer os.remove(path)

	kernel: k.Kernel
	k.kernel_init(&kernel)
	defer k.kernel_destroy(&kernel)

	result := run_files(&kernel, []string{path}, context.temp_allocator)
	testing.expectf(t, result.ok, "filein failed: %s", result.message)
	expect_relation_rows(t, &kernel, "Out", 1)
}

@(test)
test_run_optional_rest_params :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	source := `make_relation(:Out, 1)
verb greet(name, ?greeting = "hello", @extras)
  return [name, greeting, extras]
end
require(greet("x") == ["x", "hello", []])
require(greet("x", "yo") == ["x", "yo", []])
require(greet("x", "yo", 1, 2) == ["x", "yo", [1, 2]])
verb optional_none(a, ?b)
  return b
end
require(optional_none(1) == none)
verb collect(a, @rest)
  return [a, rest]
end
require(collect(1) == [1, []])
require(collect(1, 2, 3) == [1, [2, 3]])
fn opt(x, ?y = 2) => x + y
require(opt(1) == 3)
let f = fn(a, ?b = 5, @rest) => [a, b, rest]
let g = f
require(g(1) == [1, 5, []])
require(g(1, 2, 3, 4) == [1, 2, [3, 4]])
assert Out(greet("z", "bonjour"))
`
	path, path_ok := write_temp_source(t, "mica_optional_params_test.mica", source)
	if !path_ok {
		return
	}
	defer os.remove(path)

	kernel: k.Kernel
	k.kernel_init(&kernel)
	defer k.kernel_destroy(&kernel)

	result := run_files(&kernel, []string{path}, context.temp_allocator)
	testing.expectf(t, result.ok, "filein failed: %s", result.message)
	expect_relation_rows(t, &kernel, "Out", 1)
}

@(test)
test_run_receiver_dispatch :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	source := `make_identity(:player)
make_identity(:alice)
make_identity(:coin)
make_identity(:gem)
make_relation(:Taken, 2)
assert Delegates(#alice, #player, 0)
assert Delegates(#coin, #player, 0)
assert Delegates(#gem, #player, 0)
verb take(actor @ #player, item @ #player)
  assert Taken(actor, item)
  return :generic
end
verb take(actor @ #player, item @ #coin)
  assert Taken(actor, item)
  return :specific
end
require(#alice:take(#coin) == :specific)
require(#alice:take(#gem) == :generic)
let carried = #alice
require(carried:take(#gem) == :generic)
assert Taken(#alice, #coin)
`
	path, path_ok := write_temp_source(t, "mica_receiver_dispatch_test.mica", source)
	if !path_ok {
		return
	}
	defer os.remove(path)

	kernel: k.Kernel
	k.kernel_init(&kernel)
	defer k.kernel_destroy(&kernel)

	result := run_files(&kernel, []string{path}, context.temp_allocator)
	testing.expectf(t, result.ok, "filein failed: %s", result.message)
	expect_relation_rows(t, &kernel, "Taken", 2)
}

@(test)
test_run_positional_dispatch_restrictions :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	source := `make_identity(:template/name)
make_identity(:template/conjugation)
make_identity(:alice)

verb render_part(part @ #string, bindings, viewer)
  return :text
end

verb render_part(part @ #template/name<_>, bindings, viewer)
  return :name
end

verb render_part(part @ #template/conjugation<_>, bindings, viewer)
  return :conjugation
end

verb pick(part, x)
  return :any
end

verb pick(part @ #template/name<_>, x)
  return :name
end

require(render_part(frob(#template/name, {:binding -> #alice}), {}, #alice) == :name)
require(render_part(frob(#template/conjugation, {:binding -> #alice}), {}, #alice) == :conjugation)
require(render_part("plain", {}, #alice) == :text)
require(pick(frob(#template/name, {:binding -> #alice}), #alice) == :name)
require(pick("plain", #alice) == :any)
`
	path, path_ok := write_temp_source(t, "mica_positional_dispatch_test.mica", source)
	if !path_ok {
		return
	}
	defer os.remove(path)

	kernel: k.Kernel
	k.kernel_init(&kernel)
	defer k.kernel_destroy(&kernel)

	result := run_files(&kernel, []string{path}, context.temp_allocator)
	testing.expectf(t, result.ok, "filein failed: %s", result.message)
}

@(test)
test_run_return_in_finally :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	source := `make_relation(:Ran, 1)
verb override()
  try
    return 1
  finally
    return 2
  end
end
verb override_error()
  try
    raise E_RANGE, "bad"
  finally
    return 3
  end
end
verb nested()
  try
    try
      return 4
    finally
      assert Ran(1)
      return 5
    end
  finally
    assert Ran(2)
  end
end
require(override() == 2)
require(override_error() == 3)
require(nested() == 5)
`
	path, path_ok := write_temp_source(t, "mica_finally_return2_test.mica", source)
	if !path_ok {
		return
	}
	defer os.remove(path)

	kernel: k.Kernel
	k.kernel_init(&kernel)
	defer k.kernel_destroy(&kernel)

	result := run_files(&kernel, []string{path}, context.temp_allocator)
	testing.expectf(t, result.ok, "filein failed: %s", result.message)
	expect_relation_rows(t, &kernel, "Ran", 2)
}

@(test)
test_run_constant_defaults :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	source := `make_relation(:Out, 1)
verb conf(a, ?tags = [], ?opts = {:mode -> :fast}, ?pair = some(1), ?flag = -2, ?raw = b"AAEC", ?missing = none)
  return [a, tags, opts, pair, flag, raw, missing]
end
require(conf(1) == [1, [], {:mode -> :fast}, some(1), -2, b"AAEC", none])
require(conf(1, [2], {:mode -> :slow}, some(9), 5, b"", none) == [1, [2], {:mode -> :slow}, some(9), 5, b"", none])
fn f(?x = [1, 2], ?list = {:a -> [3]}) => [x, list]
require(f() == [[1, 2], {:a -> [3]}])
assert Out(conf(1))
`
	path, path_ok := write_temp_source(t, "mica_const_defaults_test.mica", source)
	if !path_ok {
		return
	}
	defer os.remove(path)

	kernel: k.Kernel
	k.kernel_init(&kernel)
	defer k.kernel_destroy(&kernel)

	result := run_files(&kernel, []string{path}, context.temp_allocator)
	testing.expectf(t, result.ok, "filein failed: %s", result.message)
	expect_relation_rows(t, &kernel, "Out", 1)
}

@(test)
test_run_cross_task_closure :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	source := `make_relation(:Out, 2)
verb run_it(f, tag)
  let value = f()
  assert Out(tag, value)
end
let base = 10
let closure = fn(?step = 1) => base + step
spawn :run_it(f: closure, tag: 1)
suspend()
`
	path, path_ok := write_temp_source(t, "mica_cross_task_closure_test.mica", source)
	if !path_ok {
		return
	}
	defer os.remove(path)

	kernel: k.Kernel
	k.kernel_init(&kernel)
	defer k.kernel_destroy(&kernel)

	result := run_files(&kernel, []string{path}, context.temp_allocator)
	testing.expectf(t, result.ok, "filein failed: %s", result.message)
	expect_relation_rows(t, &kernel, "Out", 1)
}

@(test)
test_run_dispatch_optional_rest_params :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	source := `make_identity(:alice)
make_identity(:bob)
make_relation(:Out, 1)
assert Delegates(#bob, #alice, 0)
verb act(receiver @ #alice, ?extra = 7, @rest)
  return [receiver, extra, rest]
end
require(#bob:act() == [#bob, 7, []])
require(#bob:act(9) == [#bob, 9, []])
require(#bob:act(9, 1, 2) == [#bob, 9, [1, 2]])
assert Out(#bob:act())
`
	path, path_ok := write_temp_source(t, "mica_dispatch_modes_test.mica", source)
	if !path_ok {
		return
	}
	defer os.remove(path)

	kernel: k.Kernel
	k.kernel_init(&kernel)
	defer k.kernel_destroy(&kernel)

	result := run_files(&kernel, []string{path}, context.temp_allocator)
	testing.expectf(t, result.ok, "filein failed: %s", result.message)
	expect_relation_rows(t, &kernel, "Out", 1)
}

@(test)
test_run_authority_grants :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	source := `make_identity(:alice)
make_identity(:reader)
make_relation(:RoleCanRead, 2)
make_relation(:RoleCanWrite, 2)
make_relation(:Secret, 1)
make_relation(:Leak, 1)
assert Delegates(#alice, #reader, 0)
assert Secret(1)
grant role #reader
  read:
    :Secret
  write:
    :Leak
end
commit()
verb peek()
  assert Leak(len(Secret(1)))
end
spawn :peek()
suspend()
`
	path, path_ok := write_temp_source(t, "mica_authority_grant_test.mica", source)
	if !path_ok {
		return
	}
	defer os.remove(path)

	kernel: k.Kernel
	k.kernel_init(&kernel)
	defer k.kernel_destroy(&kernel)

	result := run_files(
		&kernel,
		[]string{path},
		context.temp_allocator,
		Run_Options{actor = "alice"},
	)
	testing.expectf(t, result.ok, "filein failed: %s", result.message)
	expect_relation_rows(t, &kernel, "Leak", 1)
}

@(test)
test_run_authority_denies_unlisted :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	source := `make_identity(:alice)
make_relation(:CanRead, 2)
make_relation(:CanWrite, 2)
make_relation(:CanInvoke, 2)
make_relation(:CanEffect, 1)
make_relation(:Secret, 1)
make_relation(:DeniedRead, 1)
make_relation(:DeniedInvoke, 1)
make_relation(:DeniedEffect, 1)
make_relation(:AllowedRead, 1)
make_relation(:AllowedInvoke, 1)
make_relation(:AllowedEffect, 1)
assert Secret(1)
grant #alice
  write:
    :DeniedRead
    :DeniedInvoke
    :DeniedEffect
    :AllowedRead
    :AllowedInvoke
    :AllowedEffect
end
commit()
verb peek()
  try
    let rows = Secret(1)
    assert AllowedRead(1)
  catch err
    assert DeniedRead(1)
  end
  try
    let text = string_concat("a", "b")
    assert AllowedInvoke(1)
  catch err
    assert DeniedInvoke(1)
  end
  try
    external_request(:svc, 1)
    assert AllowedEffect(1)
  catch err
    assert DeniedEffect(1)
  end
end
spawn :peek()
suspend()
`
	path, path_ok := write_temp_source(t, "mica_authority_denied_test.mica", source)
	if !path_ok {
		return
	}
	defer os.remove(path)

	kernel: k.Kernel
	k.kernel_init(&kernel)
	defer k.kernel_destroy(&kernel)

	result := run_files(
		&kernel,
		[]string{path},
		context.temp_allocator,
		Run_Options{actor = "alice"},
	)
	testing.expectf(t, result.ok, "filein failed: %s", result.message)
	expect_relation_rows(t, &kernel, "DeniedRead", 1)
	expect_relation_rows(t, &kernel, "DeniedInvoke", 1)
	expect_relation_rows(t, &kernel, "DeniedEffect", 1)
	expect_relation_rows(t, &kernel, "AllowedRead", 0)
	expect_relation_rows(t, &kernel, "AllowedInvoke", 0)
	expect_relation_rows(t, &kernel, "AllowedEffect", 0)
}

@(test)
test_run_capability_passing :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	source := `make_identity(:alice)
make_relation(:Secret, 1)
make_relation(:Leak, 1)
assert Secret(1)
let read_cap = mint_capability(:read, :Secret)
let write_cap = mint_capability(:write, :Leak)
verb peek(read_cap, write_cap)
  use_capability(read_cap)
  use_capability(write_cap)
  assert Leak(len(Secret(1)))
end
spawn :peek(read_cap: read_cap, write_cap: write_cap)
suspend()
`
	path, path_ok := write_temp_source(t, "mica_capability_passing_test.mica", source)
	if !path_ok {
		return
	}
	defer os.remove(path)

	kernel: k.Kernel
	k.kernel_init(&kernel)
	defer k.kernel_destroy(&kernel)

	result := run_files(
		&kernel,
		[]string{path},
		context.temp_allocator,
		Run_Options{actor = "alice"},
	)
	testing.expectf(t, result.ok, "filein failed: %s", result.message)
	expect_relation_rows(t, &kernel, "Leak", 1)
}

@(test)
test_run_capability_denied_without_adoption :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	source := `make_identity(:alice)
make_relation(:Secret, 1)
make_relation(:DeniedRead, 1)
make_relation(:DeniedMint, 1)
make_relation(:AllowedRead, 1)
make_relation(:AllowedMint, 1)
assert Secret(1)
let read_cap = mint_capability(:read, :Secret)
let observe_cap = mint_capability(:write, :DeniedRead)
let observe_cap_two = mint_capability(:write, :DeniedMint)
let observe_cap_three = mint_capability(:write, :AllowedRead)
let observe_cap_four = mint_capability(:write, :AllowedMint)
verb peek(read_cap, observe_cap, observe_cap_two, observe_cap_three, observe_cap_four)
  use_capability(observe_cap)
  use_capability(observe_cap_two)
  use_capability(observe_cap_three)
  use_capability(observe_cap_four)
  try
    let rows = Secret(1)
    assert AllowedRead(1)
  catch err
    assert DeniedRead(1)
  end
  try
    let minted = mint_capability(:read, :Secret)
    assert AllowedMint(1)
  catch err
    assert DeniedMint(1)
  end
end
spawn :peek(read_cap: read_cap, observe_cap: observe_cap, observe_cap_two: observe_cap_two, observe_cap_three: observe_cap_three, observe_cap_four: observe_cap_four)
suspend()
`
	path, path_ok := write_temp_source(t, "mica_capability_denied_test.mica", source)
	if !path_ok {
		return
	}
	defer os.remove(path)

	kernel: k.Kernel
	k.kernel_init(&kernel)
	defer k.kernel_destroy(&kernel)

	result := run_files(
		&kernel,
		[]string{path},
		context.temp_allocator,
		Run_Options{actor = "alice"},
	)
	testing.expectf(t, result.ok, "filein failed: %s", result.message)
	expect_relation_rows(t, &kernel, "DeniedRead", 1)
	expect_relation_rows(t, &kernel, "DeniedMint", 1)
	expect_relation_rows(t, &kernel, "AllowedRead", 0)
	expect_relation_rows(t, &kernel, "AllowedMint", 0)
}

@(test)
test_run_capability_multi_revoke_and_expiry :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	source := `make_identity(:alice)
make_relation(:A, 1)
make_relation(:B, 1)
make_relation(:Rw, 2)
make_relation(:Vault, 1)
make_relation(:Ephemeral, 1)
make_relation(:Denied, 1)
make_relation(:Expired, 1)
make_relation(:Allowed, 1)
make_relation(:ChildBoom, 1)
assert A(1)
assert B(2)
assert Ephemeral(3)
let read_two = mint_capability(:read, [:A, :B])
let rw = mint_capability([:read, :write], :Rw)
let vault = mint_capability([:read, :write], :Vault)
let short = mint_capability(:read, :Ephemeral, {:ttl_millis -> 100})
let write_denied = mint_capability(:write, :Denied)
let write_expired = mint_capability(:write, :Expired)
let write_allowed = mint_capability(:write, :Allowed)
let write_boom = mint_capability(:write, :ChildBoom)
let call_cap = mint_capability(:invoke, [:mailbox_send])
verb work(read_two, rw, vault, short, write_denied, write_expired, write_allowed, write_boom, call_cap, sender_cap)
  use_capability(call_cap)
  use_capability(write_boom)
  mailbox_send(sender_cap, :start)
  try
    use_capability(read_two)
    use_capability(rw)
    use_capability(vault)
    use_capability(short)
    use_capability(write_denied)
    use_capability(write_expired)
    use_capability(write_allowed)
    let a_rows = A(1)
    let b_rows = B(2)
    assert Rw(1, 2)
    let rw_rows = Rw(1, 2)
    assert Vault(read_two)
    let vault_rows = Vault(read_two)
    let restricted = restrict_capability(read_two, [:read])
    use_capability(restricted)
    revoke_capability(read_two)
    try
      let rows = B(2)
      assert Allowed(1)
    catch err
      assert Denied(1)
    end
    try
      use_capability(read_two)
    catch err
      assert Denied(2)
    end
    suspend(150)
    try
      let rows = Ephemeral(3)
      assert Allowed(2)
    catch err
      assert Expired(1)
    end
  catch err
    assert ChildBoom(err.code)
  end
  mailbox_send(sender_cap, :done)
end
let [receiver, sender] = mailbox()
let child_id = spawn :work(read_two: read_two, rw: rw, vault: vault, short: short, write_denied: write_denied, write_expired: write_expired, write_allowed: write_allowed, write_boom: write_boom, call_cap: call_cap, sender_cap: sender)
require(child_id != 0)
let started = mailbox_recv([receiver], 2000)
require(len(started) == 1)
require(len(mailbox_recv([receiver], 2000)) == 1)
`
	path, path_ok := write_temp_source(t, "mica_capability_full_test.mica", source)
	if !path_ok {
		return
	}
	defer os.remove(path)

	kernel: k.Kernel
	k.kernel_init(&kernel)
	defer k.kernel_destroy(&kernel)

	result := run_files(
		&kernel,
		[]string{path},
		context.temp_allocator,
		Run_Options{actor = "alice"},
	)
	testing.expectf(t, result.ok, "filein failed: %s", result.message)
	expect_relation_rows(t, &kernel, "ChildBoom", 0)
	expect_relation_rows(t, &kernel, "Denied", 2)
	expect_relation_rows(t, &kernel, "Expired", 1)
	expect_relation_rows(t, &kernel, "Allowed", 0)
	expect_relation_rows(t, &kernel, "Vault", 1)
	expect_relation_rows(t, &kernel, "Rw", 1)
}

@(test)
test_run_mailbox_handle_revocation :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	source := `make_relation(:Out, 1)
let [receiver, sender] = mailbox()
revoke_capability(receiver)
try
  mailbox_send(sender, 1)
  assert Out(0)
catch err
  assert Out(1)
end
try
  mailbox_recv([receiver])
  assert Out(2)
catch err
  assert Out(3)
end
let [receiver_two, sender_two] = mailbox()
mailbox_close(receiver_two)
try
  mailbox_send(sender_two, 1)
  assert Out(4)
catch err
  assert Out(5)
end
`
	path, path_ok := write_temp_source(t, "mica_mailbox_revoke_test.mica", source)
	if !path_ok {
		return
	}
	defer os.remove(path)

	kernel: k.Kernel
	k.kernel_init(&kernel)
	defer k.kernel_destroy(&kernel)

	result := run_files(&kernel, []string{path}, context.temp_allocator)
	testing.expectf(t, result.ok, "filein failed: %s", result.message)
	expect_relation_rows(t, &kernel, "Out", 3)
}

@(test)
test_run_subscription_changes :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	source := `make_relation(:Note, 2)
let [receiver, sender] = mailbox()
let sub = subscribe_changes(sender, :facts, some(:Note), [some(1), none], :changes)
assert Note(1, 10)
assert Note(1, 11)
assert Note(2, 12)
commit()
let ready = mailbox_recv([receiver])
let message = ready[0][1][0]
require(index_or(message, :kind, none) == :changes)
let assertions = index_or(message, :assertions, [])
require(len(assertions) == 2)
require(len(index_or(message, :retractions, [])) == 0)
cancel_subscription(sub)
assert Note(1, 13)
commit()
let remaining = mailbox_recv([receiver], 0)
require(len(remaining) == 0)
`
	path, path_ok := write_temp_source(t, "mica_subscription_changes_test.mica", source)
	if !path_ok {
		return
	}
	defer os.remove(path)

	kernel: k.Kernel
	k.kernel_init(&kernel)
	defer k.kernel_destroy(&kernel)

	result := run_files(&kernel, []string{path}, context.temp_allocator)
	testing.expectf(t, result.ok, "filein failed: %s", result.message)
	expect_relation_rows(t, &kernel, "Note", 4)
}

@(test)
test_run_subscription_snapshot_and_close :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	source := `make_relation(:Note, 2)
make_relation(:CloseFailed, 1)
let [receiver, sender] = mailbox()
assert Note(5, 50)
commit()
let sub = subscribe_changes(sender, :facts, some(:Note), [none, none], :snapshot)
let ready = mailbox_recv([receiver])
let message = ready[0][1][0]
require(index_or(message, :kind, none) == :snapshot)
require(len(index_or(message, :assertions, [])) == 1)

let [receiver_two, sender_two] = mailbox()
let sub_two = subscribe_changes(sender_two, :facts, some(:Note), [none, none], :changes)
mailbox_close(receiver_two)
assert Note(5, 51)
commit()
try
  mailbox_recv([receiver_two])
  assert CloseFailed(0)
catch err
  assert CloseFailed(1)
end
`
	path, path_ok := write_temp_source(t, "mica_subscription_snapshot_test.mica", source)
	if !path_ok {
		return
	}
	defer os.remove(path)

	kernel: k.Kernel
	k.kernel_init(&kernel)
	defer k.kernel_destroy(&kernel)

	result := run_files(&kernel, []string{path}, context.temp_allocator)
	testing.expectf(t, result.ok, "filein failed: %s", result.message)
	expect_relation_rows(t, &kernel, "CloseFailed", 1)
}

@(test)
test_run_json_roundtrip :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	source := `make_relation(:Out, 1)
let decoded = json_decode("{\"a\":[1,2.5,true,null,1e3],\"b\":\"x\"}")
let items = index_or(decoded, :a, [])
require(items[0] == 1)
require(items[1] == 2.5)
require(items[2] == true)
require(json_is_null(items[3]))
require(items[4] == 1000.0)
require(index_or(decoded, :b, "") == "x")
let encoded = json_encode({:a -> [1, 2.5, true, json_null()], :b -> "x"})
require(encoded == "{\"a\":[1,2.5,true,null],\"b\":\"x\"}")
require(json_decode("\"A\u0041\u00e9\ud83d\ude00\"") == "AAé😀")
try
  json_decode("{} junk")
  assert Out(0)
catch err
  assert Out(1)
end
try
  json_decode("36028797018963968")
  assert Out(2)
catch err
  assert Out(3)
end
assert Out(decoded)
`
	path, path_ok := write_temp_source(t, "mica_json_test.mica", source)
	if !path_ok {
		return
	}
	defer os.remove(path)

	kernel: k.Kernel
	k.kernel_init(&kernel)
	defer k.kernel_destroy(&kernel)

	result := run_files(&kernel, []string{path}, context.temp_allocator)
	testing.expectf(t, result.ok, "filein failed: %s", result.message)
	expect_relation_rows(t, &kernel, "Out", 3)
}

@(test)
test_run_rule_enable_disable :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	source := `make_relation(:Base, 1)
make_relation(:Derived, 1)
make_relation(:Out, 1)
Derived(x) :- Base(x)
assert Base(1)
commit()
require(len(Derived(1)) == 1)
let rules = Rule(?rule)
let rule_count = 0
for found in rules
  disable_rule(found[:rule])
  rule_count = rule_count + 1
end
require(rule_count == 1)
commit()
require(len(Derived(1)) == 0)
for found in rules
  enable_rule(found[:rule])
end
commit()
require(len(Derived(1)) == 1)
assert Out(1)
`
	path, path_ok := write_temp_source(t, "mica_rule_toggle_test.mica", source)
	if !path_ok {
		return
	}
	defer os.remove(path)

	kernel: k.Kernel
	k.kernel_init(&kernel)
	defer k.kernel_destroy(&kernel)

	result := run_files(&kernel, []string{path}, context.temp_allocator)
	testing.expectf(t, result.ok, "filein failed: %s", result.message)
	expect_relation_rows(t, &kernel, "Out", 1)
}

@(test)
test_run_relation_reflection_facts :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	source := `make_relation(:Plain, 2)
make_functional_relation(:Keyed, 2, [0], :volatile)
make_relation(:Out, 1)

verb greet(name)
  assert Out(1)
end

let plain_names = RelationName(?rel, :Plain)
for found in plain_names
  let plain = found[:rel]
  require(len(ConflictPolicy(plain, :set)) == 1)
  require(len(RelationDurability(plain, :durable)) == 1)
end
let keyed_names = RelationName(?rel, :Keyed)
for found in keyed_names
  let keyed = found[:rel]
  require(len(ConflictPolicy(keyed, :functional)) == 1)
  require(len(FunctionalKey(keyed, 0, 0)) == 1)
  require(len(RelationDurability(keyed, :volatile)) == 1)
  let indexes = Index(keyed, ?idx)
  require(len(indexes) == 1)
  let idx = indexes[0][:idx]
  require(len(IndexPosition(idx, 0, 0)) == 1)
  require(len(IndexPosition(idx, 1, 1)) == 1)
  require(len(IndexStorageKind(idx, :btree)) == 1)
end
let endpoints = RelationName(?rel, :Endpoint)
require(len(endpoints) == 1)
for found in endpoints
  let endpoint_rel = found[:rel]
  require(len(RelationDurability(endpoint_rel, :volatile)) == 1)
end
let methods = MethodSelector(?mm, :greet)
require(len(methods) == 1)
let m = methods[0][:mm]
let sources = MethodSource(m, ?src)
require(len(sources) == 1)
let text = sources[0][:src]
require(text != "")
assert Out(2)
`
	path, path_ok := write_temp_source(t, "mica_reflection_facts_test.mica", source)
	if !path_ok {
		return
	}
	defer os.remove(path)

	kernel: k.Kernel
	k.kernel_init(&kernel)
	defer k.kernel_destroy(&kernel)

	result := run_files(&kernel, []string{path}, context.temp_allocator)
	testing.expectf(t, result.ok, "filein failed: %s", result.message)
	expect_relation_rows(t, &kernel, "Out", 1)
}

@(test)
test_run_subscription_relation_derived :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	source := `make_relation(:Base, 1)
make_relation(:Derived, 1)
make_relation(:Out, 1)
Derived(x) :- Base(x)
let [receiver, sender] = mailbox()
let sub = subscribe_changes(sender, :relation, some(:Derived), [none], :changes)
assert Base(1)
commit()
let first = mailbox_recv([receiver])
let first_message = first[0][1][0]
require(index_or(first_message, :kind, none) == :changes)
require(index_or(first_message, :subject, none) == :relation)
require(len(index_or(first_message, :assertions, [])) == 1)
assert Base(2)
commit()
let second = mailbox_recv([receiver])
let second_message = second[0][1][0]
require(len(index_or(second_message, :assertions, [])) == 1)
require(len(index_or(second_message, :retractions, [])) == 0)
retract Base(1)
commit()
let third = mailbox_recv([receiver])
let third_message = third[0][1][0]
require(len(index_or(third_message, :assertions, [])) == 0)
require(len(index_or(third_message, :retractions, [])) == 1)
cancel_subscription(sub)
assert Out(1)
`
	path, path_ok := write_temp_source(t, "mica_subscription_relation_test.mica", source)
	if !path_ok {
		return
	}
	defer os.remove(path)

	kernel: k.Kernel
	k.kernel_init(&kernel)
	defer k.kernel_destroy(&kernel)

	result := run_files(&kernel, []string{path}, context.temp_allocator)
	testing.expectf(t, result.ok, "filein failed: %s", result.message)
	expect_relation_rows(t, &kernel, "Out", 1)
}

@(test)
test_run_subscription_catalogue :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	source := `make_relation(:Base, 1)
make_relation(:Derived, 1)
make_relation(:Out, 1)
Derived(x) :- Base(x)
let [receiver, sender] = mailbox()
let sub = subscribe_changes(sender, :catalogue, none, [], :snapshot)
let ready = mailbox_recv([receiver])
let message = ready[0][1][0]
require(index_or(message, :kind, none) == :snapshot)
require(index_or(message, :subject, none) == :catalogue)
require(len(index_or(message, :entries, [])) > 0)
let rules = Rule(?rule)
for found in rules
  disable_rule(found[:rule])
end
commit()
let changed = mailbox_recv([receiver])
let changes = changed[0][1][0]
require(index_or(changes, :kind, none) == :changes)
require(index_or(changes, :subject, none) == :catalogue)
let entries = index_or(changes, :entries, [])
require(len(entries) == 1)
require(index_or(entries[0], :kind, none) == :rule_disabled)
cancel_subscription(sub)
assert Out(1)
`
	path, path_ok := write_temp_source(t, "mica_subscription_catalogue_test.mica", source)
	if !path_ok {
		return
	}
	defer os.remove(path)

	kernel: k.Kernel
	k.kernel_init(&kernel)
	defer k.kernel_destroy(&kernel)

	result := run_files(&kernel, []string{path}, context.temp_allocator)
	testing.expectf(t, result.ok, "filein failed: %s", result.message)
	expect_relation_rows(t, &kernel, "Out", 1)
}

@(test)
test_run_subscription_queue_budget :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	source := `make_relation(:Note, 1)
make_relation(:Out, 1)
let [receiver, sender] = mailbox()
let sub = subscribe_changes(sender, :facts, some(:Note), [none], :changes, none, 1)
assert Note(1)
commit()
assert Note(2)
commit()
let ready = mailbox_recv([receiver])
let queued = ready[0][1]
require(len(queued) == 1)
require(index_or(queued[0], :kind, none) == :snapshot)
require(len(index_or(queued[0], :assertions, [])) == 2)
assert Note(3)
assert Note(4)
commit()
let resynced = mailbox_recv([receiver])
let snapshot = resynced[0][1][0]
require(index_or(snapshot, :kind, none) == :snapshot)
require(len(index_or(snapshot, :assertions, [])) == 4)
cancel_subscription(sub)
assert Out(1)
`
	path, path_ok := write_temp_source(t, "mica_subscription_budget_test.mica", source)
	if !path_ok {
		return
	}
	defer os.remove(path)

	kernel: k.Kernel
	k.kernel_init(&kernel)
	defer k.kernel_destroy(&kernel)

	result := run_files(&kernel, []string{path}, context.temp_allocator)
	testing.expectf(t, result.ok, "filein failed: %s", result.message)
	expect_relation_rows(t, &kernel, "Out", 1)
}

@(test)
test_run_subscription_revoked_marker :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	source := `make_relation(:Note, 1)
make_relation(:Out, 1)
let [receiver, sender] = mailbox()
let sub = subscribe_changes(sender, :facts, some(:Note), [none], :changes)
assert Note(1)
commit()
revoke_capability(sub)
assert Note(2)
commit()
let ready = mailbox_recv([receiver])
let queued = ready[0][1]
require(len(queued) == 1)
require(index_or(queued[0], :kind, none) == :revoked)
assert Out(1)
`
	path, path_ok := write_temp_source(t, "mica_subscription_revoked_test.mica", source)
	if !path_ok {
		return
	}
	defer os.remove(path)

	kernel: k.Kernel
	k.kernel_init(&kernel)
	defer k.kernel_destroy(&kernel)

	result := run_files(&kernel, []string{path}, context.temp_allocator)
	testing.expectf(t, result.ok, "filein failed: %s", result.message)
	expect_relation_rows(t, &kernel, "Out", 1)
}

@(test)
test_run_subscription_catalogue_needs_root :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	source := `make_identity(:alice)
make_relation(:Out, 1)
let [receiver, sender] = mailbox()
try
  let sub = subscribe_changes(sender, :catalogue, none, [], :snapshot)
  assert Out(0)
catch err
  assert Out(1)
end
`
	path, path_ok := write_temp_source(t, "mica_subscription_catalogue_denied_test.mica", source)
	if !path_ok {
		return
	}
	defer os.remove(path)

	kernel: k.Kernel
	k.kernel_init(&kernel)
	defer k.kernel_destroy(&kernel)

	result := run_files(
		&kernel,
		[]string{path},
		context.temp_allocator,
		Run_Options{actor = "alice"},
	)
	testing.expectf(t, result.ok, "filein failed: %s", result.message)
	expect_relation_rows(t, &kernel, "Out", 1)
}

@(test)
test_run_assume_actor :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	source := `make_identity(:alice)
make_identity(:bob)
make_identity(:carol)
make_relation(:CanRead, 2)
make_relation(:CanWrite, 2)
make_relation(:session/CanAssumeActor, 2)
make_relation(:Secret, 1)
make_relation(:Out, 1)
make_relation(:Denied, 1)
make_relation(:Phase, 1)
assert CanRead(#bob, :Secret)
assert session/CanAssumeActor(#alice, #bob)
assert Secret(1)
let call_cap = mint_capability(:invoke, [:assume_actor, :actor])
let out_cap = mint_capability(:write, :Out)
let denied_cap = mint_capability(:write, :Denied)
let phase_cap = mint_capability(:write, :Phase)
commit()
verb work(call_cap, out_cap, denied_cap, phase_cap)
  use_capability(call_cap)
  use_capability(out_cap)
  use_capability(denied_cap)
  use_capability(phase_cap)
  if let some(current) = actor()
    if current == #alice
      assert Phase(1)
    else
      assert Phase(2)
    end
  end
  assume_actor(#bob)
  if let some(adopted) = actor()
    if adopted == #bob
      assert Phase(3)
    else
      assert Phase(4)
    end
  end
  assert Out(len(Secret(1)))
  try
    assume_actor(#carol)
    assert Denied(0)
  catch err
    assert Denied(1)
  end
end
spawn :work(call_cap: call_cap, out_cap: out_cap, denied_cap: denied_cap, phase_cap: phase_cap)
suspend()
`
	path, path_ok := write_temp_source(t, "mica_assume_actor_test.mica", source)
	if !path_ok {
		return
	}
	defer os.remove(path)

	kernel: k.Kernel
	k.kernel_init(&kernel)
	defer k.kernel_destroy(&kernel)

	result := run_files(
		&kernel,
		[]string{path},
		context.temp_allocator,
		Run_Options{actor = "alice"},
	)
	testing.expectf(t, result.ok, "filein failed: %s", result.message)
	expect_relation_rows(t, &kernel, "Out", 1)
	expect_relation_rows(t, &kernel, "Denied", 1)
	expect_relation_rows(t, &kernel, "Phase", 2)
}

@(test)
test_run_truthiness_and_options :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	source := `make_relation(:Flag, 1)
make_relation(:Out, 1)

verb probe()
  let empty = Flag(2)
  if Flag(1)
    assert Out(1)
  end
  if not Flag(2)
    assert Out(2)
  end
  if not empty
    assert Out(3)
  end
  if actor()
    assert Out(4)
  end
  if let some(current) = actor()
    assert Out(5)
  end
  if let some(p) = principal()
    assert Out(6)
  end
  if sync_signature(1, "payload") > 0
    assert Out(7)
  end
  return none
end

assert Flag(1)
probe()
`
	path, path_ok := write_temp_source(t, "mica_truthiness_test.mica", source)
	if !path_ok {
		return
	}
	defer os.remove(path)

	kernel: k.Kernel
	k.kernel_init(&kernel)
	defer k.kernel_destroy(&kernel)

	result := run_files(&kernel, []string{path}, context.temp_allocator)
	testing.expectf(t, result.ok, "filein failed: %s", result.message)
	expect_relation_rows(t, &kernel, "Out", 7)
}

@(test)
test_run_relation_algebra :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	source := `make_relation(:Person, 2)
make_relation(:Active, 1)
make_relation(:TeamOnce, 1)
make_relation(:PersonActive, 2)
make_relation(:AnyPerson, 1)
make_relation(:Remaining, 1)
make_relation(:Color, 1)

assert Person(:alice, :ops)
assert Person(:bob, :ops)
assert Person(:chandra, :research)
assert Active(:alice)
assert Active(:bob)
assert TeamOnce(:ops)
assert TeamOnce(:research)
assert PersonActive(:alice, :ops)
assert PersonActive(:bob, :ops)
assert AnyPerson(:alice)
assert AnyPerson(:bob)
assert AnyPerson(:chandra)
assert Remaining(:chandra)
assert Color(:red)
assert Color(:blue)

let people = Person(?person, ?team)
let active = Active(?person)
let remaining = Remaining(?person)
let any_person = AnyPerson(?person)

require project(people, :team) == TeamOnce(?team)
require len(project(people)) == 1
require natural_join(people, active) == PersonActive(?person, ?team)
require union(active, remaining) == any_person
require difference(any_person, active) == remaining
require len(natural_join(people, Color(?color))) == 6
`
	path, path_ok := write_temp_source(t, "mica_relation_algebra_test.mica", source)
	if !path_ok {
		return
	}
	defer os.remove(path)

	kernel: k.Kernel
	k.kernel_init(&kernel)
	defer k.kernel_destroy(&kernel)

	result := run_files(&kernel, []string{path}, context.temp_allocator)
	testing.expectf(t, result.ok, "filein failed: %s", result.message)
}

@(test)
test_run_relation_algebra_errors :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	source := `make_relation(:Person, 2)
make_relation(:Active, 1)
make_relation(:Caught, 1)

assert Person(:alice, :ops)
assert Active(:alice)

verb probe()
  try
    return union(Person(?person, ?team), Active(?person))
  catch E_INVARG
    return :heading_mismatch
  end
end
assert Caught(probe())
`
	path, path_ok := write_temp_source(t, "mica_relation_algebra_error_test.mica", source)
	if !path_ok {
		return
	}
	defer os.remove(path)

	kernel: k.Kernel
	k.kernel_init(&kernel)
	defer k.kernel_destroy(&kernel)

	result := run_files(&kernel, []string{path}, context.temp_allocator)
	testing.expectf(t, result.ok, "filein failed: %s", result.message)
	expect_relation_rows(t, &kernel, "Caught", 1)
}

@(test)
test_run_dom_diff_builtin :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	source := `let patches = dom_diff(dom_text("old"), dom_text("new"))
require len(patches) == 1
require patches[0][:op] == "set_text"
require patches[0][:text] == "new"
require len(patches[0][:path]) == 0

let element_patches = dom_diff(
  dom_element("ul", {}, []),
  dom_element("ul", {:id -> "messages"}, [dom_text("hi")])
)
require len(element_patches) == 2
require element_patches[0][:op] == "set_attr"
require element_patches[0][:name] == "id"
require element_patches[0][:value] == "messages"
require element_patches[1][:op] == "append_child"
require element_patches[1][:node][:text] == "hi"
`
	path, path_ok := write_temp_source(t, "mica_dom_diff_test.mica", source)
	if !path_ok {
		return
	}
	defer os.remove(path)

	kernel: k.Kernel
	k.kernel_init(&kernel)
	defer k.kernel_destroy(&kernel)

	result := run_files(&kernel, []string{path}, context.temp_allocator)
	testing.expectf(t, result.ok, "filein failed: %s", result.message)
}

@(test)
test_run_log_builtin :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	source := `make_relation(:Caught, 1)

verb probe()
  try
    log(:nope, "bad level")
    return :no_error
  catch E_INVARG
    return :caught
  end
end

log("hello")
log(:debug, "lower level")
assert Caught(probe())
`
	path, path_ok := write_temp_source(t, "mica_log_test.mica", source)
	if !path_ok {
		return
	}
	defer os.remove(path)

	kernel: k.Kernel
	k.kernel_init(&kernel)
	defer k.kernel_destroy(&kernel)

	result := run_files(&kernel, []string{path}, context.temp_allocator)
	testing.expectf(t, result.ok, "filein failed: %s", result.message)
	expect_relation_rows(t, &kernel, "Caught", 1)
}

@(test)
test_run_rule_introspection :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	source := `make_relation(:DirectDependency, 2)
make_relation(:DependsOn, 2)

DependsOn(component, dependency) :-
  DirectDependency(component, dependency)

assert DirectDependency(:service_a, :service_b)

let active = rules(:DependsOn)
require len(active) == 1
let source = describe_rule(active[0])
require string_contains(source, "DirectDependency")

disable_rule(active[0])
require len(rules(:DependsOn)) == 0
enable_rule(active[0])
require len(rules(:DependsOn)) == 1
`
	path, path_ok := write_temp_source(t, "mica_rule_introspection_test.mica", source)
	if !path_ok {
		return
	}
	defer os.remove(path)

	kernel: k.Kernel
	k.kernel_init(&kernel)
	defer k.kernel_destroy(&kernel)

	result := run_files(&kernel, []string{path}, context.temp_allocator)
	testing.expectf(t, result.ok, "filein failed: %s", result.message)
}

@(test)
test_run_dom_html_builtin :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	source := `make_relation(:Caught, 1)

require dom_html(dom_element("button", {:id -> "send", :type -> "submit"}, [dom_text("Send & go")])) == "<button id=\"send\" type=\"submit\">Send &amp; go</button>"
require dom_html(dom_element("h4", {}, [dom_text("References")])) == "<h4>References</h4>"

let label = "Send & go"
let extra = [dom <span class="note">!</span>]
let composed = dom_html(dom <button id="send" type="submit">{label}{@extra}</button>)
require string_contains(composed, "Send &amp; go")
require string_contains(composed, "<span class=\"note\">!</span>")

let expanded = dom_html(dom_element("img", {:alt -> "Logo", "aria-describedby" -> "caption", "data-route" -> "home", :loading -> "lazy", :src -> "/logo.png"}, []))
require string_starts_with(expanded, "<img ")
require string_contains(expanded, "alt=\"Logo\"")
require string_contains(expanded, "aria-describedby=\"caption\"")
require string_contains(expanded, "data-route=\"home\"")
require string_contains(expanded, "loading=\"lazy\"")
require string_contains(expanded, "src=\"/logo.png\"")

verb probe()
  try
    return dom_html(dom_element("widget", {}, []))
  catch E_TYPE
    return :caught
  end
end
assert Caught(probe())
`
	path, path_ok := write_temp_source(t, "mica_dom_html_test.mica", source)
	if !path_ok {
		return
	}
	defer os.remove(path)

	kernel: k.Kernel
	k.kernel_init(&kernel)
	defer k.kernel_destroy(&kernel)

	result := run_files(&kernel, []string{path}, context.temp_allocator)
	testing.expectf(t, result.ok, "filein failed: %s", result.message)
	expect_relation_rows(t, &kernel, "Caught", 1)
}

@(test)
test_run_from_xml_builtin :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	source := `make_relation(:Caught, 1)

require to_xml(from_xml("<p>a &amp; b</p>")) == "<p>a &amp; b</p>"
require to_xml(from_xml("<a></a><b></b>")) == "<a></a><b></b>"
require to_xml(from_xml("<ul><!-- note --><li>one</li><li>two</li></ul>")) == "<ul><li>one</li><li>two</li></ul>"
require to_xml(from_xml("<input id='actor'/>")) == "<input id=\"actor\"></input>"

let composer = from_xml("<form id='chat-composer' data-sync-event='submit' data-sync-action='chat_post'><input id='actor' name='actor' autocomplete='name' value='browser' aria-label='Actor'/><input id='message' name='text' autocomplete='off' placeholder='Message' aria-label='Message'/><button id='send' type='submit'>Send</button></form>")
require composer[:tag] == "form"
let rendered = to_xml(composer)
require string_contains(rendered, "<form ")
require string_contains(rendered, "id=\"chat-composer\"")
require string_contains(rendered, "data-sync-event=\"submit\"")
require string_contains(rendered, "data-sync-action=\"chat_post\"")
require string_contains(rendered, "<input ")
require string_contains(rendered, "aria-label=\"Actor\"")
require string_contains(rendered, "<button ")
require string_contains(rendered, ">Send</button>")

verb probe()
  try
    return from_xml("<a><b></a>")
  catch E_INVARG
    return :caught
  end
end
assert Caught(probe())
`
	path, path_ok := write_temp_source(t, "mica_from_xml_test.mica", source)
	if !path_ok {
		return
	}
	defer os.remove(path)

	kernel: k.Kernel
	k.kernel_init(&kernel)
	defer k.kernel_destroy(&kernel)

	result := run_files(&kernel, []string{path}, context.temp_allocator)
	testing.expectf(t, result.ok, "filein failed: %s", result.message)
	expect_relation_rows(t, &kernel, "Caught", 1)
}

@(test)
test_run_tasks_builtin :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	source := `make_relation(:Slept, 1)
make_relation(:ObservedRunning, 1)
make_relation(:ObservedSuspended, 1)

verb sleeper()
  assert Slept(1)
  suspend(10000)
end

verb observer()
  let snapshot = tasks()
  for entry in snapshot
    if entry[:state] == :running
      assert ObservedRunning(1)
    end
    if entry[:state] == :suspended
      assert ObservedSuspended(1)
    end
  end
end
`
	path, path_ok := write_temp_source(t, "mica_tasks_test.mica", source)
	if !path_ok {
		return
	}
	defer os.remove(path)

	kernel: k.Kernel
	k.kernel_init(&kernel)
	defer k.kernel_destroy(&kernel)

	world, start := world_start(&kernel, []string{path}, context.temp_allocator)
	testing.expectf(t, start.ok, "world start failed: %s", start.message)
	if !start.ok {
		return
	}
	defer world_destroy(world)
	entry := world_wait(world, world.entry)
	testing.expect_value(t, entry.kind, Task_Outcome_Kind.Complete)

	sleeper_id := world_submit_call(world, "sleeper", nil)
	testing.expect(t, sleeper_id != 0)

	// Wait until the sleeper has asserted its fact and parked.
	slept := false
	deadline := time.tick_now()
	for time.tick_since(deadline) < 2 * time.Second {
		snapshot := k.kernel_snapshot(&kernel)
		metadata, found := k.snapshot_relation_metadata_named(
			snapshot,
			v.symbol_intern("Slept"),
		)
		k.snapshot_release(snapshot)
		if found {
			one, _ := v.value_int(1)
			if k.kernel_contains(
				&kernel,
				metadata.id,
				v.tuple_new(context.temp_allocator, []v.Value{one}),
			) {
				slept = true
				break
			}
		}
		time.sleep(1 * time.Millisecond)
	}
	testing.expect(t, slept, "sleeper did not park")

	observer := world_call(world, "observer", nil)
	testing.expectf(t, observer.kind == .Complete, "observer failed: %s", observer.message)
	expect_relation_rows(t, &kernel, "ObservedRunning", 1)
	expect_relation_rows(t, &kernel, "ObservedSuspended", 1)
}

@(test)
test_run_destroy_identity :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	source := `make_identity(:thing)
make_identity(:room)
make_relation(:Object, 1)
make_relation(:LocatedIn, 2)
make_relation(:Destroyed, 1)

assert Object(#thing)
assert Object(#room)
assert LocatedIn(#thing, #room)
assert LocatedIn(#room, #thing)
assert Destroyed(destroy_identity(#thing))

require Object(#room)
require LocatedIn(#room, #thing)
require !Object(#thing)
require !LocatedIn(#thing, #room)
`
	path, path_ok := write_temp_source(t, "mica_destroy_identity_test.mica", source)
	if !path_ok {
		return
	}
	defer os.remove(path)

	kernel: k.Kernel
	k.kernel_init(&kernel)
	defer k.kernel_destroy(&kernel)

	result := run_files(&kernel, []string{path}, context.temp_allocator)
	testing.expectf(t, result.ok, "filein failed: %s", result.message)
	expect_relation_rows(t, &kernel, "Destroyed", 1)
	expect_relation_rows(t, &kernel, "Object", 1)
	expect_relation_rows(t, &kernel, "LocatedIn", 1)

	// The two subject facts of #thing were retracted.
	metadata, found := k.snapshot_relation_metadata_named(
		k.kernel_snapshot(&kernel),
		v.symbol_intern("Destroyed"),
	)
	testing.expect(t, found)
	if found {
		rows: [dynamic]v.Tuple
		k.kernel_scan_into(&kernel, metadata.id, []v.Binding{{}}, &rows)
		if len(rows) == 1 {
			count, is_int := v.value_as_int(v.tuple_values(rows[0])[0])
			testing.expectf(t, is_int && count == 2, "destroyed count %d", count)
		}
		delete(rows)
	}
}

@(test)
test_run_fileout_rules :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	source := `make_relation(:DirectDependency, 2)
make_relation(:DependsOn, 2)

DependsOn(component, dependency) :-
  DirectDependency(component, dependency)

require fileout_rules(:DependsOn) == "DependsOn(component, dependency) :-\n  DirectDependency(component, dependency)"
require fileout_rules(:DirectDependency) == ""
require string_contains(fileout_rules(), "DirectDependency")

let rule = rules(:DependsOn)
disable_rule(rule[0])
require fileout_rules(:DependsOn) == ""
`
	path, path_ok := write_temp_source(t, "mica_fileout_rules_test.mica", source)
	if !path_ok {
		return
	}
	defer os.remove(path)

	kernel: k.Kernel
	k.kernel_init(&kernel)
	defer k.kernel_destroy(&kernel)

	result := run_files(&kernel, []string{path}, context.temp_allocator)
	testing.expectf(t, result.ok, "filein failed: %s", result.message)
}

@(test)
test_run_fileout_unit :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	source := `make_relation(:Source, 1)
make_relation(:Caught, 1)

assert Source(fileout(:example))

verb probe()
  try
    return fileout(:missing)
  catch E_INVARG
    return :caught
  end
end
assert Caught(probe())
`
	path, path_ok := write_temp_source(t, "mica_fileout_unit_test.mica", source)
	if !path_ok {
		return
	}
	defer os.remove(path)

	kernel: k.Kernel
	k.kernel_init(&kernel)
	defer k.kernel_destroy(&kernel)

	result := run_files(
		&kernel,
		[]string{path},
		context.temp_allocator,
		Run_Options{unit = "example"},
	)
	testing.expectf(t, result.ok, "filein failed: %s", result.message)
	expect_relation_rows(t, &kernel, "Caught", 1)

	snapshot := k.kernel_snapshot(&kernel)
	metadata, found := k.snapshot_relation_metadata_named(snapshot, v.symbol_intern("Source"))
	k.snapshot_release(snapshot)
	testing.expect(t, found)
	if !found {
		return
	}
	rows: [dynamic]v.Tuple
	defer delete(rows)
	k.kernel_scan_into(&kernel, metadata.id, []v.Binding{{}}, &rows)
	if len(rows) != 1 {
		testing.expectf(t, false, "Source has %d rows", len(rows))
		return
	}
	text, is_string := v.value_as_string(v.tuple_values(rows[0])[0])
	testing.expect(t, is_string)
	testing.expectf(t, text == source, "fileout text: %q", text)
}

@(test)
test_run_read_waits_for_input :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	source := `verb ask()
  return read()
end

verb answer()
  return read(:line)
end
`
	path, path_ok := write_temp_source(t, "mica_read_test.mica", source)
	if !path_ok {
		return
	}
	defer os.remove(path)

	kernel: k.Kernel
	k.kernel_init(&kernel)
	defer k.kernel_destroy(&kernel)

	world, start := world_start(&kernel, []string{path}, context.temp_allocator)
	testing.expectf(t, start.ok, "world start failed: %s", start.message)
	if !start.ok {
		return
	}
	defer world_destroy(world)
	entry := world_wait(world, world.entry)
	testing.expect_value(t, entry.kind, Task_Outcome_Kind.Complete)

	answer_id := world_submit_call(world, "answer", nil)
	testing.expect(t, answer_id != 0)
	metadata := v.Value(0)
	has_request := false
	deadline := time.tick_now()
	for time.tick_since(deadline) < 2 * time.Second {
		metadata, has_request = world_task_request(world, answer_id)
		if has_request {
			break
		}
		time.sleep(1 * time.Millisecond)
	}
	testing.expect(t, has_request)
	symbol, is_symbol := v.value_as_symbol(metadata)
	testing.expect(t, is_symbol)
	name, has_name := v.symbol_name(symbol)
	testing.expect(t, has_name)
	testing.expect_value(t, name, "line")

	input := v.value_string(context.temp_allocator, "look")
	testing.expect(t, world_resume(world, answer_id, input))
	answer := world_wait(world, answer_id)
	testing.expect_value(t, answer.kind, Task_Outcome_Kind.Complete)
	text, is_text := v.value_as_string(answer.value)
	testing.expect(t, is_text)
	testing.expect_value(t, text, "look")
	world_release(world, answer_id)

	// A read with no metadata waits without a request value.
	ask_id := world_submit_call(world, "ask", nil)
	testing.expect(t, ask_id != 0)
	ask_parked := false
	deadline = time.tick_now()
	for time.tick_since(deadline) < 2 * time.Second {
		_, ask_parked = world_task_request(world, ask_id)
		if ask_parked {
			break
		}
		time.sleep(1 * time.Millisecond)
	}
	testing.expect(t, ask_parked)
	done := v.value_symbol(v.symbol_intern("done"))
	testing.expect(t, world_resume(world, ask_id, done))
	ask_answer := world_wait(world, ask_id)
	testing.expect_value(t, ask_answer.kind, Task_Outcome_Kind.Complete)
	testing.expect(t, v.value_eq(ask_answer.value, done))
	world_release(world, ask_id)
}
