// Capability boundary for editor file access.
//
// The browser never calls this package. Mica requests one of the fixed
// services through the runtime's external-request boundary. Every path is
// canonicalized and checked against an immutable host-configured root list.
package web

import "core:fmt"
import "core:hash"
import "core:mem"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"
import "core:time"
import "core:unicode/utf8"

import r "../../mica/runtime"
import v "../../mica/var"

EDITOR_FILE_MAX_BYTES :: 8 * 1024 * 1024
EDITOR_FILE_LIST_LIMIT :: 100

Editor_Files :: struct {
	roots:     [dynamic]string,
	allocator: mem.Allocator,
}

editor_files_init :: proc(
	files: ^Editor_Files,
	roots: []string,
	allocator := context.allocator,
) -> (
	bool,
	string,
) {
	files.allocator = allocator
	files.roots = make([dynamic]string, 0, len(roots), allocator)
	for root in roots {
		canonical, canonical_error := filepath.abs(root, context.temp_allocator)
		if canonical_error != nil {
			editor_files_destroy(files)
			return false, fmt.aprintf("cannot resolve editor root %q", root, allocator = allocator)
		}
		info, stat_error := os.stat(canonical, context.temp_allocator)
		if stat_error != nil || info.type != .Directory {
			editor_files_destroy(files)
			return false, fmt.aprintf(
				"editor root is not a directory: %q",
				root,
				allocator = allocator,
			)
		}
		append(&files.roots, strings.clone(canonical, allocator))
	}
	return true, ""
}

editor_files_destroy :: proc(files: ^Editor_Files) {
	if files == nil || files.roots == nil {
		return
	}
	for root in files.roots {
		delete(root, files.allocator)
	}
	delete(files.roots)
}

editor_file_service :: proc(service: v.Value) -> bool {
	symbol, is_symbol := v.value_as_symbol(service)
	if !is_symbol {
		return false
	}
	name, has_name := v.symbol_name(symbol)
	if !has_name {
		return false
	}
	return(
		name == "editor_file_read" ||
		name == "editor_file_write_atomic" ||
		name == "editor_file_stat" ||
		name == "editor_file_list" \
	)
}

editor_file_handle_request :: proc(
	ctx: r.External_Context,
	files: ^Editor_Files,
	service: v.Value,
	payload: v.Value,
) -> v.Value {
	if files == nil || len(files.roots) == 0 {
		return editor_file_response(ctx, "denied", "the editor has no configured file roots")
	}
	symbol, _ := v.value_as_symbol(service)
	name, _ := v.symbol_name(symbol)
	switch name {
	case "editor_file_read":
		return editor_file_read(ctx, files, payload)
	case "editor_file_write_atomic":
		return editor_file_write_atomic(ctx, files, payload)
	case "editor_file_stat":
		return editor_file_stat(ctx, files, payload)
	case "editor_file_list":
		return editor_file_list(ctx, files, payload)
	}
	return editor_file_response(ctx, "error", "unknown editor file service")
}

@(private)
editor_file_lookup :: proc(payload: v.Value, name: string) -> (v.Value, bool) {
	entries, is_map := v.value_as_map(payload)
	if !is_map {
		return {}, false
	}
	key := v.value_symbol(v.symbol_intern(name))
	for entry in entries {
		if v.value_eq(entry.key, key) {
			return entry.value, true
		}
	}
	return {}, false
}

@(private)
editor_file_string :: proc(payload: v.Value, name: string) -> (string, bool) {
	value, found := editor_file_lookup(payload, name)
	if !found {
		return "", false
	}
	return v.value_as_string(value)
}

@(private)
editor_file_symbol :: proc(name: string) -> v.Value {
	return v.value_symbol(v.symbol_intern(name))
}

@(private)
editor_file_entry :: proc(name: string, value: v.Value) -> v.Map_Entry {
	return {key = editor_file_symbol(name), value = value}
}

@(private)
editor_file_response :: proc(ctx: r.External_Context, status, message: string) -> v.Value {
	return v.value_map(
		ctx.allocator,
		[]v.Map_Entry {
			editor_file_entry("status", editor_file_symbol(status)),
			editor_file_entry("message", v.value_string(ctx.allocator, message)),
		},
	)
}

@(private)
editor_file_inside_root :: proc(files: ^Editor_Files, path: string) -> bool {
	for root in files.roots {
		relative, rel_error := filepath.rel(root, path, context.temp_allocator)
		if rel_error != .None {
			continue
		}
		if relative == "." ||
		   (relative != ".." &&
				   !strings.has_prefix(relative, "../") &&
				   !strings.has_prefix(relative, "..\\")) {
			return true
		}
	}
	return false
}

// Resolves existing paths through symbolic links. For a new file, it resolves
// the existing parent and appends one leaf name. It does not create folders.
@(private)
editor_file_canonical_path :: proc(
	files: ^Editor_Files,
	input: string,
	allow_missing: bool,
) -> (
	string,
	bool,
	bool,
) {
	if input == "" {
		return "", false, false
	}
	candidate := input
	if !filepath.is_abs(candidate) {
		joined, join_error := filepath.join(
			[]string{files.roots[0], candidate},
			context.temp_allocator,
		)
		if join_error != nil {
			return "", false, false
		}
		candidate = joined
	}
	canonical, absolute_error := filepath.abs(candidate, context.temp_allocator)
	exists := absolute_error == nil
	if !exists {
		if !allow_missing {
			return "", false, false
		}
		parent, leaf := os.split_path(candidate)
		if leaf == "" || leaf == "." || leaf == ".." {
			return "", false, false
		}
		canonical_parent, parent_error := filepath.abs(parent, context.temp_allocator)
		if parent_error != nil {
			return "", false, false
		}
		joined, join_error := filepath.join(
			[]string{canonical_parent, leaf},
			context.temp_allocator,
		)
		if join_error != nil {
			return "", false, false
		}
		canonical = joined
	}
	if !editor_file_inside_root(files, canonical) {
		return "", false, false
	}
	return canonical, exists, true
}

@(private)
editor_file_stamp :: proc(ctx: r.External_Context, path: string, data: []byte) -> (v.Value, bool) {
	info, stat_error := os.stat(path, context.temp_allocator)
	if stat_error != nil || info.type != .Regular {
		return {}, false
	}
	size_value, _ := v.value_int(info.size)
	modified_value, _ := v.value_int(time.time_to_unix_nano(info.modification_time))
	hash_text := fmt.aprintf("%08x", hash.crc32(data), allocator = context.temp_allocator)
	return v.value_map(
			ctx.allocator,
			[]v.Map_Entry {
				editor_file_entry("size", size_value),
				editor_file_entry("modified_ns", modified_value),
				editor_file_entry("content_hash", v.value_string(ctx.allocator, hash_text)),
			},
		),
		true
}

@(private)
editor_file_current_stamp :: proc(ctx: r.External_Context, path: string) -> (v.Value, bool, bool) {
	info, stat_error := os.stat(path, context.temp_allocator)
	if stat_error != nil {
		if !os.exists(path) {
			return v.value_empty_relation(), false, true
		}
		return {}, false, false
	}
	if info.type != .Regular || info.size > EDITOR_FILE_MAX_BYTES {
		return {}, false, false
	}
	data, read_error := os.read_entire_file(path, context.temp_allocator)
	if read_error != nil {
		if !os.exists(path) {
			return v.value_empty_relation(), false, true
		}
		return {}, false, false
	}
	stamp, stamp_ok := editor_file_stamp(ctx, path, data)
	return stamp, true, stamp_ok
}

@(private)
editor_file_read :: proc(
	ctx: r.External_Context,
	files: ^Editor_Files,
	payload: v.Value,
) -> v.Value {
	input, has_path := editor_file_string(payload, "path")
	if !has_path {
		return editor_file_response(ctx, "error", "file read requires a path")
	}
	path, exists, allowed := editor_file_canonical_path(files, input, true)
	if !allowed {
		return editor_file_response(ctx, "denied", "path is outside the configured editor roots")
	}
	_, name := os.split_path(path)
	if !exists {
		return v.value_map(
			ctx.allocator,
			[]v.Map_Entry {
				editor_file_entry("status", editor_file_symbol("missing")),
				editor_file_entry("path", v.value_string(ctx.allocator, path)),
				editor_file_entry("name", v.value_string(ctx.allocator, name)),
			},
		)
	}
	info, stat_error := os.stat(path, context.temp_allocator)
	if stat_error != nil {
		return editor_file_response(ctx, "error", "cannot inspect the file")
	}
	if info.type == .Directory {
		return editor_file_response(ctx, "directory", "path names a directory")
	}
	if info.type != .Regular || info.size > EDITOR_FILE_MAX_BYTES {
		return editor_file_response(ctx, "error", "file is not a supported regular file")
	}
	data, read_error := os.read_entire_file(path, context.temp_allocator)
	if read_error != nil {
		return editor_file_response(ctx, "error", "cannot read the file")
	}
	text := string(data)
	if !utf8.valid_string(text) {
		return editor_file_response(ctx, "error", "file is not valid UTF-8")
	}
	line_ending := "lf"
	if strings.contains(text, "\r\n") {
		line_ending = "crlf"
		text, _ = strings.replace_all(text, "\r\n", "\n", context.temp_allocator)
	}
	stamp, stamp_ok := editor_file_stamp(ctx, path, data)
	if !stamp_ok {
		return editor_file_response(ctx, "error", "cannot stamp the file")
	}
	return v.value_map(
		ctx.allocator,
		[]v.Map_Entry {
			editor_file_entry("status", editor_file_symbol("ok")),
			editor_file_entry("path", v.value_string(ctx.allocator, path)),
			editor_file_entry("name", v.value_string(ctx.allocator, name)),
			editor_file_entry("text", v.value_string(ctx.allocator, text)),
			editor_file_entry("stamp", stamp),
			editor_file_entry("encoding", v.value_string(ctx.allocator, "utf-8")),
			editor_file_entry("line_ending", editor_file_symbol(line_ending)),
		},
	)
}

@(private)
editor_file_stat :: proc(
	ctx: r.External_Context,
	files: ^Editor_Files,
	payload: v.Value,
) -> v.Value {
	input, has_path := editor_file_string(payload, "path")
	if !has_path {
		return editor_file_response(ctx, "error", "file stat requires a path")
	}
	path, exists, allowed := editor_file_canonical_path(files, input, true)
	if !allowed {
		return editor_file_response(ctx, "denied", "path is outside the configured editor roots")
	}
	if !exists {
		return v.value_map(
			ctx.allocator,
			[]v.Map_Entry {
				editor_file_entry("status", editor_file_symbol("missing")),
				editor_file_entry("path", v.value_string(ctx.allocator, path)),
			},
		)
	}
	stamp, stamp_exists, stamp_ok := editor_file_current_stamp(ctx, path)
	if !stamp_ok || !stamp_exists {
		return editor_file_response(ctx, "error", "path is not a regular file")
	}
	return v.value_map(
		ctx.allocator,
		[]v.Map_Entry {
			editor_file_entry("status", editor_file_symbol("ok")),
			editor_file_entry("path", v.value_string(ctx.allocator, path)),
			editor_file_entry("stamp", stamp),
		},
	)
}

@(private)
editor_file_stamp_is_none :: proc(stamp: v.Value) -> bool {
	if relation, is_relation := v.value_as_relation(stamp); is_relation {
		return len(relation.rows) == 0
	}
	return false
}

@(private)
editor_file_stamp_matches :: proc(expected, actual: v.Value) -> bool {
	expected_none := editor_file_stamp_is_none(expected)
	actual_none := editor_file_stamp_is_none(actual)
	if expected_none || actual_none {
		return expected_none && actual_none
	}
	return v.value_eq(expected, actual)
}

@(private)
editor_file_write_all :: proc(file: ^os.File, data: []byte) -> bool {
	written := 0
	for written < len(data) {
		count, write_error := os.write(file, data[written:])
		if write_error != nil || count <= 0 {
			return false
		}
		written += count
	}
	return true
}

@(private)
editor_file_changed_response :: proc(
	ctx: r.External_Context,
	path: string,
	current: v.Value,
) -> v.Value {
	return v.value_map(
		ctx.allocator,
		[]v.Map_Entry {
			editor_file_entry("status", editor_file_symbol("changed")),
			editor_file_entry("path", v.value_string(ctx.allocator, path)),
			editor_file_entry("current_stamp", current),
			editor_file_entry("message", v.value_string(ctx.allocator, "file changed on disk")),
		},
	)
}

@(private)
editor_file_open_directory :: proc(path: string) -> (^os.File, os.Error) {
	return os.open(path)
}

@(private)
editor_file_write_atomic :: proc(
	ctx: r.External_Context,
	files: ^Editor_Files,
	payload: v.Value,
	open_directory := editor_file_open_directory,
	sync_directory := os.sync,
) -> v.Value {
	input, has_path := editor_file_string(payload, "path")
	text, has_text := editor_file_string(payload, "text")
	expected, has_expected := editor_file_lookup(payload, "expected_stamp")
	line_ending_value, has_line_ending := editor_file_lookup(payload, "line_ending")
	line_ending := "lf"
	if has_line_ending {
		if symbol, is_symbol := v.value_as_symbol(line_ending_value); is_symbol {
			line_ending, _ = v.symbol_name(symbol)
		}
	}
	if !has_path || !has_text || !has_expected || (line_ending != "lf" && line_ending != "crlf") {
		return editor_file_response(ctx, "error", "file write has invalid arguments")
	}
	if !utf8.valid_string(text) || len(text) > EDITOR_FILE_MAX_BYTES {
		return editor_file_response(ctx, "error", "file text is not supported UTF-8")
	}
	path, _, allowed := editor_file_canonical_path(files, input, true)
	if !allowed {
		return editor_file_response(ctx, "denied", "path is outside the configured editor roots")
	}
	current, _, current_ok := editor_file_current_stamp(ctx, path)
	if !current_ok {
		return editor_file_response(ctx, "error", "cannot inspect the current file")
	}
	if !editor_file_stamp_matches(expected, current) {
		return editor_file_changed_response(ctx, path, current)
	}

	bytes := transmute([]byte)text
	if line_ending == "crlf" {
		converted, _ := strings.replace_all(text, "\n", "\r\n", context.temp_allocator)
		bytes = transmute([]byte)converted
	}
	parent, _ := os.split_path(path)
	temp, temp_error := os.create_temp_file(parent, ".omica-save-*", {.Sync})
	if temp_error != nil {
		return editor_file_response(ctx, "error", "cannot create a temporary save file")
	}
	temp_path := strings.clone(os.name(temp), context.temp_allocator)
	keep_temp := true
	defer if keep_temp {
		_ = os.remove(temp_path)
	}
	permissions := os.Permissions_Default_File
	if info, stat_error := os.stat(path, context.temp_allocator); stat_error == nil {
		permissions = info.mode
	}
	mode_set := os.fchmod(temp, permissions) == nil
	wrote := editor_file_write_all(temp, bytes)
	synced := wrote && os.sync(temp) == nil
	closed := os.close(temp) == nil
	if !mode_set || !wrote || !synced || !closed {
		return editor_file_response(ctx, "error", "cannot write the temporary save file")
	}
	checked_path, _, still_allowed := editor_file_canonical_path(files, path, true)
	if !still_allowed || checked_path != path {
		return editor_file_response(ctx, "denied", "file path changed before replacement")
	}
	latest, _, latest_ok := editor_file_current_stamp(ctx, path)
	if !latest_ok {
		return editor_file_response(ctx, "error", "cannot inspect the file before replacement")
	}
	if !editor_file_stamp_matches(expected, latest) {
		return editor_file_changed_response(ctx, path, latest)
	}
	if rename_error := os.rename(temp_path, path); rename_error != nil {
		return editor_file_response(ctx, "error", "cannot replace the file")
	}
	keep_temp = false
	directory, open_error := open_directory(parent)
	if open_error != nil {
		return editor_file_response(
			ctx,
			"error",
			"file was replaced but its directory could not be opened for sync",
		)
	}
	directory_synced := sync_directory(directory) == nil
	directory_closed := os.close(directory) == nil
	if !directory_synced || !directory_closed {
		return editor_file_response(
			ctx,
			"error",
			"file was replaced but its directory could not be flushed and closed",
		)
	}
	stamp, stamp_ok := editor_file_stamp(ctx, path, bytes)
	if !stamp_ok {
		return editor_file_response(ctx, "error", "file was saved but could not be stamped")
	}
	return v.value_map(
		ctx.allocator,
		[]v.Map_Entry {
			editor_file_entry("status", editor_file_symbol("ok")),
			editor_file_entry("path", v.value_string(ctx.allocator, path)),
			editor_file_entry("stamp", stamp),
		},
	)
}

Editor_File_Candidate :: struct {
	path:         string,
	label:        string,
	annotation:   string,
	is_directory: bool,
}

@(private)
editor_file_candidate_less :: proc(a, b: Editor_File_Candidate) -> bool {
	if a.is_directory != b.is_directory {
		return a.is_directory
	}
	return strings.compare(a.label, b.label) < 0
}

@(private)
editor_file_list :: proc(
	ctx: r.External_Context,
	files: ^Editor_Files,
	payload: v.Value,
) -> v.Value {
	query, has_query := editor_file_string(payload, "query")
	if !has_query {
		return editor_file_response(ctx, "error", "file list requires a query")
	}
	limit := EDITOR_FILE_LIST_LIMIT
	if limit_value, has_limit := editor_file_lookup(payload, "limit"); has_limit {
		if requested, is_int := v.value_as_int(limit_value); is_int {
			limit = clamp(int(requested), 1, EDITOR_FILE_LIST_LIMIT)
		}
	}

	candidate := query
	if candidate == "" {
		candidate = files.roots[0]
	} else if !filepath.is_abs(candidate) {
		joined, join_error := filepath.join(
			[]string{files.roots[0], candidate},
			context.temp_allocator,
		)
		if join_error != nil {
			return editor_file_response(ctx, "error", "cannot resolve the completion path")
		}
		candidate = joined
	}

	directory_input :=
		query == "" || strings.has_suffix(query, "/") || strings.has_suffix(query, "\\")
	directory := candidate
	prefix := ""
	if !directory_input {
		directory, prefix = os.split_path(candidate)
	}
	canonical_directory, directory_error := filepath.abs(directory, context.temp_allocator)
	if directory_error != nil || !editor_file_inside_root(files, canonical_directory) {
		return v.value_map(
			ctx.allocator,
			[]v.Map_Entry {
				editor_file_entry("status", editor_file_symbol("ok")),
				editor_file_entry("candidates", v.value_list(ctx.allocator, []v.Value{})),
			},
		)
	}
	infos, read_error := os.read_all_directory_by_path(canonical_directory, context.temp_allocator)
	if read_error != nil {
		return editor_file_response(ctx, "error", "cannot list the completion directory")
	}

	candidates := make(
		[dynamic]Editor_File_Candidate,
		0,
		min(len(infos) + 1, limit),
		context.temp_allocator,
	)
	exact := false
	for info in infos {
		if !strings.has_prefix(info.name, prefix) ||
		   (info.type != .Regular && info.type != .Directory) {
			continue
		}
		path, join_error := filepath.join(
			[]string{canonical_directory, info.name},
			context.temp_allocator,
		)
		if join_error != nil {
			continue
		}
		if info.type == .Directory {
			path = fmt.aprintf("%s/", path, allocator = context.temp_allocator)
		}
		append(
			&candidates,
			Editor_File_Candidate {
				path = path,
				label = path,
				annotation = info.type == .Directory ? "directory" : "",
				is_directory = info.type == .Directory,
			},
		)
		if info.name == prefix {
			exact = true
		}
	}
	if prefix != "" && !exact {
		new_path, join_error := filepath.join(
			[]string{canonical_directory, prefix},
			context.temp_allocator,
		)
		if join_error == nil && editor_file_inside_root(files, new_path) {
			append(
				&candidates,
				Editor_File_Candidate{path = new_path, label = new_path, annotation = "new file"},
			)
		}
	}
	slice.sort_by(candidates[:], editor_file_candidate_less)
	if len(candidates) > limit {
		resize(&candidates, limit)
	}
	values := make([]v.Value, len(candidates), context.temp_allocator)
	for item, index in candidates {
		values[index] = v.value_map(
			ctx.allocator,
			[]v.Map_Entry {
				editor_file_entry("key", v.value_string(ctx.allocator, item.path)),
				editor_file_entry("value", v.value_string(ctx.allocator, item.path)),
				editor_file_entry("label", v.value_string(ctx.allocator, item.label)),
				editor_file_entry("annotation", v.value_string(ctx.allocator, item.annotation)),
			},
		)
	}
	return v.value_map(
		ctx.allocator,
		[]v.Map_Entry {
			editor_file_entry("status", editor_file_symbol("ok")),
			editor_file_entry("candidates", v.value_list(ctx.allocator, values)),
		},
	)
}
