package web

import "base:runtime"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"

import k "../../mica/kernel"
import r "../../mica/runtime"
import v "../../mica/var"

@(private)
editor_file_test_map :: proc(entries: ..v.Map_Entry) -> v.Value {
	return v.value_map(context.temp_allocator, entries[:])
}

@(private)
editor_file_test_entry :: proc(name: string, value: v.Value) -> v.Map_Entry {
	return {key = v.value_symbol(v.symbol_intern(name)), value = value}
}

@(private)
editor_file_test_string :: proc(text: string) -> v.Value {
	return v.value_string(context.temp_allocator, text)
}

@(private)
editor_file_test_int :: proc(number: i64) -> v.Value {
	value, _ := v.value_int(number)
	return value
}

@(private)
editor_file_test_get :: proc(value: v.Value, name: string) -> v.Value {
	entries, _ := v.value_as_map(value)
	key := v.value_symbol(v.symbol_intern(name))
	for entry in entries {
		if entry.key == key {
			return entry.value
		}
	}
	return {}
}

@(private)
editor_file_test_status :: proc(value: v.Value) -> string {
	status := editor_file_test_get(value, "status")
	symbol, _ := v.value_as_symbol(status)
	name, _ := v.symbol_name(symbol)
	return name
}

@(private)
Editor_File_Test_Host :: struct {
	files:               ^Editor_Files,
	world:               ^r.World,
	during_save_source:  string,
	during_save_outcome: r.Task_Outcome,
	language_none_stamp: bool,
}

@(private)
editor_file_test_external :: proc(
	ctx: r.External_Context,
	service: v.Value,
	payload: v.Value,
) -> v.Value {
	host := (^Editor_File_Test_Host)(ctx.host_data)
	result := editor_file_handle_request(ctx, host.files, service, payload)
	if service == editor_file_symbol("editor_file_write_atomic") && host.during_save_source != "" {
		// Complete another transaction while the save task is suspended.
		source := host.during_save_source
		host.during_save_source = ""
		host.during_save_outcome = r.world_eval(host.world, source, runtime.default_allocator())
	}
	if host.language_none_stamp &&
	   editor_file_test_status(result) == "changed" &&
	   v.value_is_empty_relation(editor_file_test_get(result, "current_stamp")) {
		// Both zero-column emptiness and language `none` denote a missing file.
		entries, _ := v.value_as_map(result)
		copied := make([]v.Map_Entry, len(entries), context.temp_allocator)
		copy(copied, entries)
		for &entry in copied {
			if entry.key == editor_file_symbol("current_stamp") {
				entry.value, _ = v.value_relation(
					ctx.allocator,
					[]v.Symbol{v.symbol_intern("value")},
					nil,
				)
			}
		}
		result = v.value_map(ctx.allocator, copied)
	}
	return result
}

@(private)
editor_file_test_source :: proc(relative: string) -> string {
	candidates := []string {
		relative,
		fmt.aprintf("../%s", relative, allocator = context.temp_allocator),
		fmt.aprintf("../../%s", relative, allocator = context.temp_allocator),
	}
	for candidate in candidates {
		if os.is_file(candidate) {
			return candidate
		}
	}
	return ""
}

@(private)
editor_file_test_input :: proc(
	world: ^r.World,
	session, actor: v.Value,
	json: string,
) -> r.Task_Outcome {
	return r.world_call(
		world,
		"editor_input_json",
		[]k.Role_Pair {
			{role = editor_file_symbol("endpoint"), value = r.world_endpoint(world)},
			{role = editor_file_symbol("session"), value = session},
			{role = editor_file_symbol("actor"), value = actor},
			{role = editor_file_symbol("frame"), value = editor_file_test_int(1)},
			{role = editor_file_symbol("text"), value = editor_file_test_string(json)},
			{role = editor_file_symbol("client_token"), value = editor_file_test_int(0)},
			{
				role = editor_file_symbol("known_keymap_generation"),
				value = editor_file_test_int(0),
			},
		},
	)
}

@(private)
editor_file_test_key :: proc(
	world: ^r.World,
	session, actor: v.Value,
	key: string,
) -> r.Task_Outcome {
	return editor_file_test_input(
		world,
		session,
		actor,
		strings.concatenate({`{"kind":"key","key":"`, key, `"}`}, context.temp_allocator),
	)
}

@(private)
editor_file_test_outcome_message :: proc(outcome: r.Task_Outcome) -> string {
	if error_value, is_error := v.value_as_error(outcome.error); is_error {
		return error_value.message
	}
	return outcome.message
}

@(private)
editor_file_test_root :: proc(t: ^testing.T) -> (string, bool) {
	base, base_error := os.temp_dir(context.temp_allocator)
	if base_error != nil {
		testing.expect(t, false, "cannot resolve the temporary directory")
		return "", false
	}
	root, root_error := os.make_directory_temp(
		base,
		"omica-editor-files-*",
		context.temp_allocator,
	)
	if root_error != nil {
		testing.expect(t, false, "cannot create an editor file root")
		return "", false
	}
	return root, true
}

@(test)
test_editor_files_read_list_and_restrict_roots :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	root, root_ok := editor_file_test_root(t)
	if !root_ok {
		return
	}
	defer os.remove(root)
	file_path := fmt.aprintf("%s/notes.txt", root, allocator = context.temp_allocator)
	directory_path := fmt.aprintf("%s/sub", root, allocator = context.temp_allocator)
	testing.expect(t, os.write_entire_file(file_path, "alpha\r\nbeta\r\n") == nil)
	defer os.remove(file_path)
	testing.expect(t, os.make_directory(directory_path) == nil)
	defer os.remove(directory_path)

	files: Editor_Files
	ok, message := editor_files_init(&files, []string{root}, context.temp_allocator)
	testing.expectf(t, ok, "init failed: %s", message)
	if !ok {
		return
	}
	defer editor_files_destroy(&files)
	ctx := r.External_Context {
		allocator = context.temp_allocator,
	}
	read := editor_file_handle_request(
		ctx,
		&files,
		editor_file_symbol("editor_file_read"),
		editor_file_test_map(editor_file_test_entry("path", editor_file_test_string(file_path))),
	)
	testing.expect_value(t, editor_file_test_status(read), "ok")
	text, _ := v.value_as_string(editor_file_test_get(read, "text"))
	testing.expect_value(t, text, "alpha\nbeta\n")
	line_ending, _ := v.value_as_symbol(editor_file_test_get(read, "line_ending"))
	line_ending_name, _ := v.symbol_name(line_ending)
	testing.expect_value(t, line_ending_name, "crlf")

	listed := editor_file_handle_request(
		ctx,
		&files,
		editor_file_symbol("editor_file_list"),
		editor_file_test_map(
			editor_file_test_entry("query", editor_file_test_string("")),
			editor_file_test_entry("limit", editor_file_test_int(100)),
		),
	)
	testing.expect_value(t, editor_file_test_status(listed), "ok")
	candidates, candidates_ok := v.value_as_list(editor_file_test_get(listed, "candidates"))
	testing.expect(t, candidates_ok)
	testing.expect_value(t, len(candidates), 2)
	if len(candidates) == 2 {
		first_annotation, _ := v.value_as_string(editor_file_test_get(candidates[0], "annotation"))
		testing.expect_value(t, first_annotation, "directory")
	}

	outside := fmt.aprintf("%s-outside.txt", root, allocator = context.temp_allocator)
	testing.expect(t, os.write_entire_file(outside, "secret") == nil)
	defer os.remove(outside)
	denied := editor_file_handle_request(
		ctx,
		&files,
		editor_file_symbol("editor_file_read"),
		editor_file_test_map(editor_file_test_entry("path", editor_file_test_string(outside))),
	)
	testing.expect_value(t, editor_file_test_status(denied), "denied")

	link_path := fmt.aprintf("%s/link.txt", root, allocator = context.temp_allocator)
	if os.symlink(outside, link_path) == nil {
		defer os.remove(link_path)
		linked := editor_file_handle_request(
			ctx,
			&files,
			editor_file_symbol("editor_file_read"),
			editor_file_test_map(
				editor_file_test_entry("path", editor_file_test_string(link_path)),
			),
		)
		testing.expect_value(t, editor_file_test_status(linked), "denied")
	}
}

@(test)
test_editor_files_atomic_write_checks_the_expected_stamp :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	root, root_ok := editor_file_test_root(t)
	if !root_ok {
		return
	}
	defer os.remove(root)
	file_path := fmt.aprintf("%s/notes.txt", root, allocator = context.temp_allocator)
	testing.expect(t, os.write_entire_file(file_path, "old\n") == nil)
	expected_mode := os.perm(0o640)
	testing.expect(t, os.chmod(file_path, expected_mode) == nil)
	defer os.remove(file_path)

	files: Editor_Files
	ok, message := editor_files_init(&files, []string{root}, context.temp_allocator)
	testing.expectf(t, ok, "init failed: %s", message)
	if !ok {
		return
	}
	defer editor_files_destroy(&files)
	ctx := r.External_Context {
		allocator = context.temp_allocator,
	}
	read := editor_file_handle_request(
		ctx,
		&files,
		editor_file_symbol("editor_file_read"),
		editor_file_test_map(editor_file_test_entry("path", editor_file_test_string(file_path))),
	)
	stamp := editor_file_test_get(read, "stamp")
	testing.expect(t, os.write_entire_file(file_path, "external\n") == nil)

	stale := editor_file_handle_request(
		ctx,
		&files,
		editor_file_symbol("editor_file_write_atomic"),
		editor_file_test_map(
			editor_file_test_entry("path", editor_file_test_string(file_path)),
			editor_file_test_entry("text", editor_file_test_string("saved\n")),
			editor_file_test_entry("expected_stamp", stamp),
			editor_file_test_entry("line_ending", editor_file_symbol("crlf")),
		),
	)
	testing.expect_value(t, editor_file_test_status(stale), "changed")
	current := editor_file_test_get(stale, "current_stamp")

	written := editor_file_handle_request(
		ctx,
		&files,
		editor_file_symbol("editor_file_write_atomic"),
		editor_file_test_map(
			editor_file_test_entry("path", editor_file_test_string(file_path)),
			editor_file_test_entry("text", editor_file_test_string("saved\n")),
			editor_file_test_entry("expected_stamp", current),
			editor_file_test_entry("line_ending", editor_file_symbol("crlf")),
		),
	)
	testing.expect_value(t, editor_file_test_status(written), "ok")
	data, read_error := os.read_entire_file(file_path, context.temp_allocator)
	testing.expect(t, read_error == nil)
	testing.expect_value(t, string(data), "saved\r\n")
	info, stat_error := os.stat(file_path, context.temp_allocator)
	testing.expect(t, stat_error == nil)
	testing.expect_value(t, info.mode, expected_mode)

	new_path := fmt.aprintf("%s/new.txt", root, allocator = context.temp_allocator)
	defer os.remove(new_path)
	created := editor_file_handle_request(
		ctx,
		&files,
		editor_file_symbol("editor_file_write_atomic"),
		editor_file_test_map(
			editor_file_test_entry("path", editor_file_test_string(new_path)),
			editor_file_test_entry("text", editor_file_test_string("new\n")),
			editor_file_test_entry("expected_stamp", v.value_empty_relation()),
			editor_file_test_entry("line_ending", editor_file_symbol("lf")),
		),
	)
	testing.expect_value(t, editor_file_test_status(created), "ok")
}

@(test)
test_editor_find_file_edits_and_saves_on_the_host :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	root, root_ok := editor_file_test_root(t)
	if !root_ok {
		return
	}
	defer os.remove(root)
	file_path := fmt.aprintf("%s/notes.txt", root, allocator = context.temp_allocator)
	testing.expect(t, os.write_entire_file(file_path, "abc\r\n") == nil)
	defer os.remove(file_path)

	files: Editor_Files
	ok, message := editor_files_init(&files, []string{root}, runtime.default_allocator())
	testing.expectf(t, ok, "init failed: %s", message)
	if !ok {
		return
	}
	defer editor_files_destroy(&files)

	relative := []string {
		"apps/shared/buffers.mica",
		"apps/editor/schema.mica",
		"apps/editor/windows.mica",
		"apps/editor/buffers.mica",
		"apps/editor/keymaps.mica",
		"apps/editor/undo.mica",
		"apps/editor/commands.mica",
		"apps/editor/session.mica",
		"apps/editor/picker.mica",
		"apps/editor/minibuffer.mica",
		"apps/editor/files.mica",
		"apps/editor/ui.mica",
		"apps/editor/defaults.mica",
	}
	sources := make([]string, len(relative), context.temp_allocator)
	for name, index in relative {
		sources[index] = editor_file_test_source(name)
		if sources[index] == "" {
			testing.expectf(t, false, "editor source not found: %s", name)
			return
		}
	}

	kernel: k.Kernel
	k.kernel_init(&kernel)
	defer k.kernel_destroy(&kernel)
	host := Editor_File_Test_Host {
		files = &files,
	}
	world, start := r.world_start(
		&kernel,
		sources,
		runtime.default_allocator(),
		r.World_Config {
			workers = 2,
			external_handler = editor_file_test_external,
			external_data = &host,
			external_workers = 1,
		},
	)
	testing.expectf(t, start.ok, "world failed to start: %s", start.message)
	if !start.ok {
		return
	}
	defer r.world_destroy(world)
	host.world = world
	entry := r.world_wait(world, world.entry)
	testing.expect_value(t, entry.kind, r.Task_Outcome_Kind.Complete)

	session := editor_file_symbol("editor/test/files-session")
	actor := editor_file_symbol("editor/test/files-actor")
	for key in ([]string{"C-x", "C-f"}) {
		outcome := editor_file_test_key(world, session, actor, key)
		testing.expectf(
			t,
			outcome.kind == .Complete,
			"%s failed: %s",
			key,
			editor_file_test_outcome_message(outcome),
		)
	}
	typed := editor_file_test_input(
		world,
		session,
		actor,
		strings.concatenate({`{"kind":"text","text":"`, file_path, `"}`}, context.temp_allocator),
	)
	testing.expectf(
		t,
		typed.kind == .Complete,
		"typing path failed: %s",
		editor_file_test_outcome_message(typed),
	)
	opened := editor_file_test_key(world, session, actor, "<return>")
	testing.expectf(
		t,
		opened.kind == .Complete,
		"opening failed: %s",
		editor_file_test_outcome_message(opened),
	)
	if opened.kind != .Complete {
		return
	}
	testing.expect_value(t, editor_file_test_status(opened.value), "ok")
	name, _ := v.value_as_string(editor_file_test_get(opened.value, "buffer_name"))
	testing.expect_value(t, name, "notes.txt")
	first_buffer := editor_file_test_get(opened.value, "buffer")

	edited := editor_file_test_input(world, session, actor, "{\"kind\":\"text\",\"text\":\"Z\"}")
	testing.expect_value(t, edited.kind, r.Task_Outcome_Kind.Complete)
	for key in ([]string{"C-x", "C-s"}) {
		saved := editor_file_test_key(world, session, actor, key)
		testing.expect_value(t, saved.kind, r.Task_Outcome_Kind.Complete)
	}
	data, read_error := os.read_entire_file(file_path, context.temp_allocator)
	testing.expect(t, read_error == nil)
	testing.expect_value(t, string(data), "Zabc\r\n")

	// A second visit selects the already-live buffer instead of loading a
	// duplicate buffer for the same actor and canonical path.
	for key in ([]string{"C-x", "C-f"}) {
		_ = editor_file_test_key(world, session, actor, key)
	}
	_ = editor_file_test_input(
		world,
		session,
		actor,
		strings.concatenate({`{"kind":"text","text":"`, file_path, `"}`}, context.temp_allocator),
	)
	reopened := editor_file_test_key(world, session, actor, "<return>")
	testing.expect_value(t, reopened.kind, r.Task_Outcome_Kind.Complete)
	if reopened.kind == .Complete {
		testing.expect(t, v.value_eq(editor_file_test_get(reopened.value, "buffer"), first_buffer))
	}

	// A new browser session for the same actor reuses the durable file buffer.
	second_session := editor_file_symbol("editor/test/files-session-2")
	for key in ([]string{"C-x", "C-f"}) {
		_ = editor_file_test_key(world, second_session, actor, key)
	}
	_ = editor_file_test_input(
		world,
		second_session,
		actor,
		strings.concatenate({`{"kind":"text","text":"`, file_path, `"}`}, context.temp_allocator),
	)
	resumed := editor_file_test_key(world, second_session, actor, "<return>")
	testing.expect_value(t, resumed.kind, r.Task_Outcome_Kind.Complete)
	if resumed.kind == .Complete {
		testing.expect(t, v.value_eq(editor_file_test_get(resumed.value, "buffer"), first_buffer))
		modified, _ := v.value_as_bool(editor_file_test_get(resumed.value, "modified"))
		testing.expect(t, !modified)
	}

	// The first save after an external change refuses to overwrite. Repeating
	// the exact save command confirms the replacement.
	_ = editor_file_test_input(world, session, actor, "{\"kind\":\"text\",\"text\":\"Q\"}")
	testing.expect(t, os.write_entire_file(file_path, "external\n") == nil)
	_ = editor_file_test_key(world, session, actor, "C-x")
	conflict := editor_file_test_key(world, session, actor, "C-s")
	testing.expect_value(t, conflict.kind, r.Task_Outcome_Kind.Complete)
	if conflict.kind == .Complete {
		conflict_message, _ := v.value_as_string(editor_file_test_get(conflict.value, "message"))
		testing.expect_value(
			t,
			conflict_message,
			"File changed on disk; repeat C-x C-s to overwrite",
		)
	}
	data, read_error = os.read_entire_file(file_path, context.temp_allocator)
	testing.expect(t, read_error == nil)
	testing.expect_value(t, string(data), "external\n")

	_ = editor_file_test_key(world, session, actor, "C-x")
	confirmed := editor_file_test_key(world, session, actor, "C-s")
	testing.expect_value(t, confirmed.kind, r.Task_Outcome_Kind.Complete)
	data, read_error = os.read_entire_file(file_path, context.temp_allocator)
	testing.expect(t, read_error == nil)
	testing.expect_value(t, string(data), "ZQabc\r\n")


	// A second task edits the same buffer after the host writes the snapshot,
	// but before the save continuation resumes. That edit must remain dirty.
	_ = editor_file_test_input(world, session, actor, `{"kind":"text","text":"R"}`)
	buffer_symbol, _ := v.value_as_symbol(first_buffer)
	buffer_name, _ := v.symbol_name(buffer_symbol)
	host.during_save_source = fmt.aprintf(
		"let target = to_symbol(\"%s\")\nbuffer_insert(target, buffer_len(target), \"L\")",
		buffer_name,
		allocator = context.temp_allocator,
	)
	_ = editor_file_test_key(world, session, actor, "C-x")
	raced_save := editor_file_test_key(world, session, actor, "C-s")
	testing.expectf(
		t,
		host.during_save_outcome.kind == .Complete,
		"during-save edit: %s (source %s)",
		editor_file_test_outcome_message(host.during_save_outcome),
		buffer_name,
	)
	testing.expect_value(t, raced_save.kind, r.Task_Outcome_Kind.Complete)
	modified, _ := v.value_as_bool(editor_file_test_get(raced_save.value, "modified"))
	testing.expect(t, modified, "edits made during a save must remain unsaved")
	data, read_error = os.read_entire_file(file_path, context.temp_allocator)
	testing.expect(t, read_error == nil)
	testing.expect_value(t, string(data), "ZQRabc\r\n")
	_ = editor_file_test_key(world, session, actor, "C-x")
	_ = editor_file_test_key(world, session, actor, "C-s")
	data, read_error = os.read_entire_file(file_path, context.temp_allocator)
	testing.expect(t, read_error == nil)
	testing.expect_value(t, string(data), "ZQRabc\r\nL")

	// Deletion on disk has a real `none` stamp. A repeated save must confirm
	// that stamp and recreate the file, rather than repeat the conflict.
	_ = editor_file_test_input(world, session, actor, `{"kind":"text","text":"S"}`)
	testing.expect(t, os.remove(file_path) == nil)
	_ = editor_file_test_key(world, session, actor, "C-x")
	deleted_conflict := editor_file_test_key(world, session, actor, "C-s")
	testing.expect_value(t, deleted_conflict.kind, r.Task_Outcome_Kind.Complete)
	testing.expect(t, !os.exists(file_path))
	_ = editor_file_test_key(world, session, actor, "C-x")
	recreated := editor_file_test_key(world, session, actor, "C-s")
	testing.expect_value(t, recreated.kind, r.Task_Outcome_Kind.Complete)
	data, read_error = os.read_entire_file(file_path, context.temp_allocator)
	testing.expect(t, read_error == nil, "confirmed save must recreate a deleted file")
	testing.expect_value(t, string(data), "ZQRSabc\r\nL")

	// A host using Mica's headed `none` must also permit confirmation.
	host.language_none_stamp = true
	_ = editor_file_test_input(world, session, actor, `{"kind":"text","text":"T"}`)
	testing.expect(t, os.remove(file_path) == nil)
	_ = editor_file_test_key(world, session, actor, "C-x")
	_ = editor_file_test_key(world, session, actor, "C-s")
	testing.expect(t, !os.exists(file_path))
	_ = editor_file_test_key(world, session, actor, "C-x")
	_ = editor_file_test_key(world, session, actor, "C-s")
	data, read_error = os.read_entire_file(file_path, context.temp_allocator)
	testing.expect(t, read_error == nil, "a language-none stamp is a confirmable missing file")
	testing.expect_value(t, string(data), "ZQRSTabc\r\nL")

	new_path := fmt.aprintf("%s/new.txt", root, allocator = context.temp_allocator)
	defer os.remove(new_path)
	for key in ([]string{"C-x", "C-f"}) {
		_ = editor_file_test_key(world, session, actor, key)
	}
	new_typed := editor_file_test_input(
		world,
		session,
		actor,
		strings.concatenate({`{"kind":"text","text":"`, new_path, `"}`}, context.temp_allocator),
	)
	testing.expectf(
		t,
		new_typed.kind == .Complete,
		"typing new path failed: %s",
		editor_file_test_outcome_message(new_typed),
	)
	created := editor_file_test_key(world, session, actor, "<return>")
	testing.expectf(
		t,
		created.kind == .Complete,
		"creating buffer failed: %s",
		editor_file_test_outcome_message(created),
	)
	if created.kind == .Complete {
		created_name, _ := v.value_as_string(editor_file_test_get(created.value, "buffer_name"))
		testing.expect_value(t, created_name, "new.txt")
	}
	new_edit := editor_file_test_input(
		world,
		session,
		actor,
		"{\"kind\":\"text\",\"text\":\"fresh\\n\"}",
	)
	testing.expectf(
		t,
		new_edit.kind == .Complete,
		"editing new file failed: %s",
		editor_file_test_outcome_message(new_edit),
	)
	if new_edit.kind == .Complete {
		testing.expect_value(t, editor_file_test_status(new_edit.value), "ok")
	}
	new_prefix := editor_file_test_key(world, session, actor, "C-x")
	testing.expectf(
		t,
		new_prefix.kind == .Complete,
		"new save prefix failed: %s",
		editor_file_test_outcome_message(new_prefix),
	)
	new_saved := editor_file_test_key(world, session, actor, "C-s")
	testing.expectf(
		t,
		new_saved.kind == .Complete,
		"saving new file failed: %s",
		editor_file_test_outcome_message(new_saved),
	)
	if new_saved.kind == .Complete {
		testing.expect_value(t, editor_file_test_status(new_saved.value), "ok")
		save_message, _ := v.value_as_string(editor_file_test_get(new_saved.value, "message"))
		testing.expectf(
			t,
			strings.has_prefix(save_message, "Wrote "),
			"new save message: %s",
			save_message,
		)
	}
	data, read_error = os.read_entire_file(new_path, context.temp_allocator)
	testing.expect(t, read_error == nil)
	testing.expect_value(t, string(data), "fresh\n")
}

@(private)
editor_file_test_open_failure :: proc(_: string) -> (^os.File, os.Error) {
	return nil, os.General_Error.Invalid_Dir
}

@(private)
editor_file_test_sync_failure :: proc(_: ^os.File) -> os.Error {
	return os.General_Error.Invalid_File
}

@(test)
test_editor_file_save_reports_directory_flush_failures :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	root, root_ok := editor_file_test_root(t)
	if !root_ok {return}
	defer os.remove(root)
	path := fmt.aprintf("%s/save.txt", root, allocator = context.temp_allocator)
	defer os.remove(path)
	files: Editor_Files
	ok, _ := editor_files_init(&files, []string{root}, context.temp_allocator)
	testing.expect(t, ok)
	if !ok {return}
	defer editor_files_destroy(&files)
	ctx := r.External_Context {
		allocator = context.temp_allocator,
	}
	for failure in 0 ..< 2 {
		testing.expect(t, os.write_entire_file(path, "before") == nil)
		read := editor_file_read(
			ctx,
			&files,
			editor_file_test_map(editor_file_test_entry("path", editor_file_test_string(path))),
		)
		open_directory := editor_file_open_directory
		sync_directory := os.sync
		if failure ==
		   0 {open_directory = editor_file_test_open_failure} else {sync_directory = editor_file_test_sync_failure}
		result := editor_file_write_atomic(
			ctx,
			&files,
			editor_file_test_map(
				editor_file_test_entry("path", editor_file_test_string(path)),
				editor_file_test_entry("text", editor_file_test_string("after")),
				editor_file_test_entry("expected_stamp", editor_file_test_get(read, "stamp")),
			),
			open_directory,
			sync_directory,
		)
		testing.expect_value(t, editor_file_test_status(result), "error")
		message, _ := v.value_as_string(editor_file_test_get(result, "message"))
		testing.expect(t, strings.contains(message, "replaced"))
		// Replacement happened: the error must not claim the old contents remain.
		data, err := os.read_entire_file(path, context.temp_allocator)
		testing.expect(t, err == nil)
		testing.expect_value(t, string(data), "after")
	}
}
