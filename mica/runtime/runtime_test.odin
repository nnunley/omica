package mica_runtime

import "core:fmt"
import "core:os"
import "core:path/filepath"
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
