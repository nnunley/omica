// Editor bridge: authenticated sessions, ordered input, duplicate replay, and
// bounded viewport snapshots for the browser editor.
//
// The host does not decode or interpret browser input. It forwards the raw
// item JSON to Mica's `editor_input_json`, then, when Mica reports that a
// staged buffer apply needs finalizing, reads the completion in a later task
// through `editor_input_result`. The snapshot the browser paints also comes
// from Mica, so keymaps, commands, and buffer policy stay server-side.
//
package web

import "core:mem"
import "core:strconv"
import "core:strings"
import "core:sync"

import k "../../mica/kernel"
import r "../../mica/runtime"
import v "../../mica/var"

EDITOR_SNAPSHOT_LINES :: 200
EDITOR_SNAPSHOT_SCALARS :: 262144
EDITOR_MAX_SNAPSHOT_LINES :: 1000
EDITOR_MAX_SNAPSHOT_SCALARS :: 1048576
EDITOR_RESULT_LIMIT :: 256
EDITOR_MAX_SAFE_INTEGER :: u64(9007199254740991)

Editor_Result :: struct {
	sequence: u64,
	body:     string,
}

Editor_Session :: struct {
	lock:                   sync.Mutex,
	session_id:             u64,
	actor:                  v.Value,
	next_sequence:          u64,
	pending_sequence:       u64,
	pending_token:          u64,
	pending_result:         string,
	pending_needs_finalize: bool,
	results:                [dynamic]Editor_Result,
	allocator:              mem.Allocator,
}

Editor :: struct {
	lock:       sync.Mutex,
	world:      ^r.World,
	next_token: u64,
	sessions:   map[u64]^Editor_Session,
	allocator:  mem.Allocator,
}

editor_init :: proc(editor: ^Editor, world: ^r.World, allocator := context.allocator) {
	editor.world = world
	editor.next_token = 1
	editor.allocator = allocator
	editor.sessions = make(map[u64]^Editor_Session, allocator)
}

editor_destroy :: proc(editor: ^Editor) {
	if editor == nil || editor.sessions == nil {
		return
	}
	for _, session in editor.sessions {
		for result in session.results {
			delete(result.body, session.allocator)
		}
		delete(session.results)
		if session.pending_result != "" {
			delete(session.pending_result, session.allocator)
		}
		free(session, session.allocator)
	}
	delete(editor.sessions)
}

@(private)
editor_ensure_session :: proc(editor: ^Editor, session_id: u64, actor: v.Value) -> ^Editor_Session {
	sync.mutex_lock(&editor.lock)
	defer sync.mutex_unlock(&editor.lock)
	if session, found := editor.sessions[session_id]; found {
		if session.actor != actor {
			return nil
		}
		return session
	}
	session := new(Editor_Session, editor.allocator)
	session.session_id = session_id
	session.actor = actor
	session.next_sequence = 1
	session.allocator = editor.allocator
	session.results = make([dynamic]Editor_Result, editor.allocator)
	editor.sessions[session_id] = session
	return session
}

// Handles the editor's two routes. Returns false when the path is not an
// editor route, so the caller can continue its own dispatch.
editor_handle_request :: proc(
	editor: ^Editor,
	actor: v.Value,
	request: ^Http_Request,
	response: ^Http_Response,
) -> bool {
	if editor.world == nil {
		return false
	}
	principal := actor
	if v.value_is_empty_relation(principal) {
		principal = r.world_principal(editor.world)
	}
	path := http_request_path(request.target)
	switch {
	case request.method == "GET" && path == "/editor/snapshot":
		editor_handle_snapshot(editor, principal, request, response)
		return true
	case request.method == "POST" && path == "/editor/input":
		editor_handle_input(editor, principal, request, response)
		return true
	}
	return false
}

@(private)
editor_handle_snapshot :: proc(
	editor: ^Editor,
	actor: v.Value,
	request: ^Http_Request,
	response: ^Http_Response,
) {
	session_id, valid_session := editor_query_u64(request.target, "session")
	if !valid_session || session_id == 0 || session_id > EDITOR_MAX_SAFE_INTEGER {
		http_response_text(response, 400, "text/plain; charset=utf-8", "invalid editor session")
		return
	}
	host_session := editor_ensure_session(editor, session_id, actor)
	if host_session == nil {
		http_response_text(response, 403, "text/plain; charset=utf-8", "session actor mismatch")
		return
	}
	sync.mutex_lock(&host_session.lock)
	defer sync.mutex_unlock(&host_session.lock)
	session := editor_int(i64(session_id))
	lines := editor_query_bounded(
		request.target,
		"lines",
		EDITOR_SNAPSHOT_LINES,
		1,
		EDITOR_MAX_SNAPSHOT_LINES,
	)
	budget := editor_query_bounded(
		request.target,
		"max",
		EDITOR_SNAPSHOT_SCALARS,
		1,
		EDITOR_MAX_SNAPSHOT_SCALARS,
	)
	roles := []k.Role_Pair {
		{role = v.value_symbol(v.symbol_intern("session")), value = session},
		{role = v.value_symbol(v.symbol_intern("actor")), value = actor},
		{role = v.value_symbol(v.symbol_intern("lines")), value = editor_int(lines)},
		{role = v.value_symbol(v.symbol_intern("max_scalars")), value = editor_int(budget)},
	}
	text, ok, message := editor_call_text(editor, actor, "editor/snapshot_json", roles)
	if !ok {
		http_response_text(response, 500, "text/plain; charset=utf-8", message)
		return
	}
	editor_respond_json(response, text)
}

@(private)
editor_handle_input :: proc(
	editor: ^Editor,
	actor: v.Value,
	request: ^Http_Request,
	response: ^Http_Response,
) {
	session_id, valid_session := editor_query_u64(request.target, "session")
	sequence, valid_sequence := editor_query_u64(request.target, "sequence")
	if !valid_session || session_id == 0 || session_id > EDITOR_MAX_SAFE_INTEGER ||
	   !valid_sequence || sequence == 0 || sequence > EDITOR_MAX_SAFE_INTEGER {
		http_response_text(response, 400, "text/plain; charset=utf-8", "invalid editor session or sequence")
		return
	}
	host_session := editor_ensure_session(editor, session_id, actor)
	if host_session == nil {
		http_response_text(response, 403, "text/plain; charset=utf-8", "session actor mismatch")
		return
	}
	sync.mutex_lock(&host_session.lock)
	defer sync.mutex_unlock(&host_session.lock)

	if sequence < host_session.next_sequence {
		for result in host_session.results {
			if result.sequence == sequence {
				editor_respond_json(response, result.body)
				return
			}
		}
		http_response_text(response, 409, "text/plain; charset=utf-8", "editor result replay window expired")
		return
	}
	if sequence > host_session.next_sequence {
		http_response_text(response, 409, "text/plain; charset=utf-8", "editor input sequence gap")
		return
	}

	session := editor_int(i64(session_id))
	frame := editor_query_bounded(request.target, "frame", 1, 1, 0x7fffffff)
	lines := editor_query_bounded(
		request.target,
		"lines",
		EDITOR_SNAPSHOT_LINES,
		1,
		EDITOR_MAX_SNAPSHOT_LINES,
	)
	budget := editor_query_bounded(
		request.target,
		"max",
		EDITOR_SNAPSHOT_SCALARS,
		1,
		EDITOR_MAX_SNAPSHOT_SCALARS,
	)
	endpoint := r.world_endpoint(editor.world)
	endpoint_role := v.value_symbol(v.symbol_intern("endpoint"))
	session_role := v.value_symbol(v.symbol_intern("session"))
	token_role := v.value_symbol(v.symbol_intern("client_token"))

	result_json := host_session.pending_result
	if host_session.pending_sequence == 0 {
		token := sync.atomic_add(&editor.next_token, 1)
		input_roles := []k.Role_Pair {
			{role = endpoint_role, value = endpoint},
			{role = session_role, value = session},
			{role = v.value_symbol(v.symbol_intern("actor")), value = actor},
			{role = v.value_symbol(v.symbol_intern("frame")), value = editor_int(frame)},
			{
				role = v.value_symbol(v.symbol_intern("text")),
				value = v.value_string(context.temp_allocator, string(request.body)),
			},
			{role = token_role, value = editor_int(i64(token))},
		}
		value_json, ok, message := editor_call_json(editor, actor, "editor_input_json", input_roles)
		if !ok {
			http_response_text(response, 500, "text/plain; charset=utf-8", message)
			return
		}
		host_session.pending_sequence = sequence
		host_session.pending_token = token
		host_session.pending_result = strings.clone(value_json, host_session.allocator)
		host_session.pending_needs_finalize = strings.contains(value_json, "\"needs_finalize\":true")
		result_json = host_session.pending_result
	} else if host_session.pending_sequence != sequence {
		http_response_text(response, 409, "text/plain; charset=utf-8", "another editor input is incomplete")
		return
	}

	// A retry resumes here instead of applying the input again. This makes an
	// ambiguous connection failure safe whether the first task committed or not.
	if host_session.pending_needs_finalize {
		final_roles := []k.Role_Pair {
			{role = endpoint_role, value = endpoint},
			{role = session_role, value = session},
			{role = token_role, value = editor_int(i64(host_session.pending_token))},
		}
		final_json, final_ok, final_message := editor_call_json(
			editor,
			actor,
			"editor_input_result",
			final_roles,
		)
		if !final_ok {
			http_response_text(response, 500, "text/plain; charset=utf-8", final_message)
			return
		}
		delete(host_session.pending_result, host_session.allocator)
		host_session.pending_result = strings.clone(final_json, host_session.allocator)
		host_session.pending_needs_finalize = false
		result_json = host_session.pending_result
	}

	// Step 3: the snapshot the browser paints.
	snapshot_roles := []k.Role_Pair {
		{role = session_role, value = session},
		{role = v.value_symbol(v.symbol_intern("actor")), value = actor},
		{role = v.value_symbol(v.symbol_intern("lines")), value = editor_int(lines)},
		{role = v.value_symbol(v.symbol_intern("max_scalars")), value = editor_int(budget)},
	}
	snapshot_json, snapshot_ok, snapshot_message := editor_call_text(
		editor,
		actor,
		"editor/snapshot_json",
		snapshot_roles,
	)
	if !snapshot_ok {
		http_response_text(response, 500, "text/plain; charset=utf-8", snapshot_message)
		return
	}
	sequence_buffer: [32]byte
	sequence_text := strconv.write_uint(sequence_buffer[:], sequence, 10)
	body := strings.concatenate(
		{
			"{\"through_sequence\":",
			sequence_text,
			",\"result\":",
			result_json,
			",\"snapshot\":",
			snapshot_json,
			"}",
		},
		context.temp_allocator,
	)
	append(&host_session.results, Editor_Result {
		sequence = sequence,
		body = strings.clone(body, host_session.allocator),
	})
	if len(host_session.results) > EDITOR_RESULT_LIMIT {
		delete(host_session.results[0].body, host_session.allocator)
		ordered_remove(&host_session.results, 0)
	}
	delete(host_session.pending_result, host_session.allocator)
	host_session.pending_result = ""
	host_session.pending_sequence = 0
	host_session.pending_token = 0
	host_session.next_sequence += 1
	editor_respond_json(response, body)
}

// Submits one Mica call as `actor` and copies the encoded result before the
// task entry is released: Mica values are task-allocated, so they must not be
// read after `world_release`.
@(private)
editor_call_json :: proc(
	editor: ^Editor,
	actor: v.Value,
	selector: string,
	roles: []k.Role_Pair,
) -> (
	string,
	bool,
	string,
) {
	result := r.world_submit_call_with_options(
		editor.world,
		selector,
		roles,
		nil,
		0,
		r.World_Call_Options{actor = actor},
	)
	if result.id == 0 {
		return "", false, "cannot dispatch the editor call"
	}
	outcome := r.world_wait(editor.world, result.id)
	text := ""
	ok := false
	message := ""
	if outcome.kind != .Complete {
		message = outcome.message
		if error_value, is_error := v.value_as_error(outcome.error); is_error {
			message = error_value.message
		}
		if message == "" {
			message = "editor call failed"
		}
	} else if encoded, encoded_ok := r.json_encode_text(context.temp_allocator, outcome.value);
	   encoded_ok {
		text = encoded
		ok = true
	} else {
		message = "cannot encode the editor result"
	}
	r.world_release(editor.world, result.id)
	return text, ok, message
}

// Calls a selector that returns JSON text, copying the text before release.
@(private)
editor_call_text :: proc(
	editor: ^Editor,
	actor: v.Value,
	selector: string,
	roles: []k.Role_Pair,
) -> (
	string,
	bool,
	string,
) {
	result := r.world_submit_call_with_options(
		editor.world,
		selector,
		roles,
		nil,
		0,
		r.World_Call_Options{actor = actor},
	)
	if result.id == 0 {
		return "", false, "cannot dispatch the editor call"
	}
	outcome := r.world_wait(editor.world, result.id)
	text := ""
	ok := false
	message := ""
	if outcome.kind != .Complete {
		message = outcome.message
		if error_value, is_error := v.value_as_error(outcome.error); is_error {
			message = error_value.message
		}
		if message == "" {
			message = "editor call failed"
		}
	} else if borrowed, is_text := v.value_as_string(outcome.value); is_text {
		text = strings.clone(borrowed, context.temp_allocator)
		ok = true
	} else {
		message = "editor snapshot is not text"
	}
	r.world_release(editor.world, result.id)
	return text, ok, message
}

@(private)
editor_int :: proc(number: i64) -> v.Value {
	value, _ := v.value_int(number)
	return value
}

@(private)
editor_respond_json :: proc(response: ^Http_Response, text: string) {
	response.status = 200
	response.content_type = "application/json; charset=utf-8"
	response.body = transmute([]byte)strings.clone(text, context.temp_allocator)
}

// Reads `name` from the request target's query string, or returns `default`.
// Values arrived percent-encoded from the browser, so they are decoded: without
// this, `editor%2Fdefault` and the re-encoded `editor%252Fdefault` would each
// become different sessions.
@(private)
editor_query :: proc(target, name: string, default: string) -> string {
	query := strings.index_byte(target, '?')
	if query < 0 {
		return default
	}
	fields := strings.split(target[query + 1:], "&", context.temp_allocator)
	for field in fields {
		equals := strings.index_byte(field, '=')
		if equals < 0 {
			continue
		}
		if field[:equals] == name {
			return editor_url_decode(field[equals + 1:])
		}
	}
	return default
}

// Decodes percent escapes and `+` in one query value.
@(private)
editor_url_decode :: proc(text: string) -> string {
	if !strings.contains_any(text, "%+") {
		return text
	}
	out := make([dynamic]u8, 0, len(text), context.temp_allocator)
	for index := 0; index < len(text); index += 1 {
		byte := text[index]
		switch byte {
		case '%':
			if index + 2 < len(text) {
				high, high_ok := editor_hex_digit(text[index + 1])
				low, low_ok := editor_hex_digit(text[index + 2])
				if high_ok && low_ok {
					append(&out, high * 16 + low)
					index += 2
					continue
				}
			}
			append(&out, byte)
		case '+':
			append(&out, ' ')
		case:
			append(&out, byte)
		}
	}
	return string(out[:])
}

@(private)
editor_hex_digit :: proc(byte: u8) -> (u8, bool) {
	switch {
	case byte >= '0' && byte <= '9':
		return byte - '0', true
	case byte >= 'a' && byte <= 'f':
		return byte - 'a' + 10, true
	case byte >= 'A' && byte <= 'F':
		return byte - 'A' + 10, true
	}
	return 0, false
}

@(private)
editor_query_int :: proc(target, name: string, default: i64) -> i64 {
	text := editor_query(target, name, "")
	if text == "" {
		return default
	}
	parsed, ok := strconv.parse_i64(text)
	if !ok || parsed < 0 {
		return default
	}
	return parsed
}

@(private)
editor_query_bounded :: proc(target, name: string, default, minimum, maximum: i64) -> i64 {
	value := editor_query_int(target, name, default)
	return clamp(value, minimum, maximum)
}

@(private)
editor_query_u64 :: proc(target, name: string) -> (u64, bool) {
	text := editor_query(target, name, "")
	if text == "" {
		return 0, false
	}
	return strconv.parse_u64(text)
}
