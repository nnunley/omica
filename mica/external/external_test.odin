// Tests for the external HTTP/LLM bridge: SSE framing, request building,
// event normalization, DSML recovery, and live transfers through libcurl
// against a local stub server.
package mica_external

import "base:runtime"
import "core:mem"
import "core:net"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:sync"
import "core:testing"
import "core:thread"
import "core:time"
import k "../kernel"
import r "../runtime"
import v "../var"

// --- SSE decoder -----------------------------------------------------------

@(test)
test_sse_decoder_frames :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	decoder: Sse_Decoder
	sse_decoder_init(&decoder, context.temp_allocator)
	defer sse_decoder_destroy(&decoder)

	frames: [dynamic]string
	defer delete(frames)

	// A frame split across two pushes, with a multi-line data payload.
	first := "data: {\"a\":\ndata: 1}\n\n"
	sse_decoder_push(&decoder, transmute([]byte)first, &frames)
	testing.expect_value(t, len(frames), 1)
	if len(frames) == 1 {
		testing.expect_value(t, frames[0], "{\"a\":\n1}")
	}

	done := "data: [DONE]\r\n\r\n"
	sse_decoder_push(&decoder, transmute([]byte)done, &frames)
	testing.expect_value(t, len(frames), 2)
	if len(frames) == 2 {
		testing.expect_value(t, frames[1], "[DONE]")
	}
}

@(test)
test_sse_decoder_partial_frame :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	decoder: Sse_Decoder
	sse_decoder_init(&decoder, context.temp_allocator)
	defer sse_decoder_destroy(&decoder)

	frames: [dynamic]string
	defer delete(frames)

	head := "data: hel"
	sse_decoder_push(&decoder, transmute([]byte)head, &frames)
	testing.expect_value(t, len(frames), 0)
	middle := "lo\n"
	sse_decoder_push(&decoder, transmute([]byte)middle, &frames)
	testing.expect_value(t, len(frames), 0)
	tail := "\n"
	sse_decoder_push(&decoder, transmute([]byte)tail, &frames)
	testing.expect_value(t, len(frames), 1)
	if len(frames) == 1 {
		testing.expect_value(t, frames[0], "hello")
	}
}

// --- Request building ------------------------------------------------------

// Builds a payload map from name/value pairs allocated with the temp arena.
@(private)
test_payload :: proc(entries: ..v.Map_Entry) -> v.Value {
	return v.value_map(context.temp_allocator, entries[:])
}

@(private)
test_map_entry :: proc(name: string, value: v.Value) -> v.Map_Entry {
	return v.Map_Entry{key = v.value_symbol(v.symbol_intern(name)), value = value}
}

@(private)
test_string :: proc(text: string) -> v.Value {
	return v.value_string(context.temp_allocator, text)
}

@(private)
test_int :: proc(number: i64) -> v.Value {
	value, _ := v.value_int(number)
	return value
}

@(private)
test_lookup_text :: proc(t: ^testing.T, value: v.Value, name: string) -> string {
	field, found := lookup(value, name)
	testing.expectf(t, found, "missing field %q", name)
	if !found {
		return ""
	}
	text, is_text := v.value_as_string(field)
	testing.expectf(t, is_text, "field %q is not a string", name)
	return text
}

@(test)
test_wire_body_chat_completion :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	message := test_payload(
		test_map_entry("role", test_string("user")),
		test_map_entry("content", test_string("ping")),
	)
	options := test_payload(test_map_entry("temperature", test_int(0)))
	payload := test_payload(
		test_map_entry("model", test_string("test-model")),
		test_map_entry("messages", v.value_list(context.temp_allocator, []v.Value{message})),
		test_map_entry("options", options),
		// Explicit base URL: other tests set the environment variable, and the
		// Odin test runner runs tests concurrently.
		test_map_entry("base_url", test_string("https://openrouter.ai/api/v1")),
	)
	spec, message_text, ok := build_spec(payload, .Chat_Completions, false, context.temp_allocator)
	testing.expectf(t, ok, "build_spec failed: %s", message_text)
	if !ok {
		return
	}
	testing.expect_value(t, spec.provider, "openrouter")
	body, _, decoded := r.json_decode_text(context.temp_allocator, string(spec.request.body[:]))
	testing.expect(t, decoded)
	if decoded {
		testing.expect_value(t, test_lookup_text(t, body, "model"), "test-model")
		stream_value, found := lookup(body, "stream")
		testing.expect(t, found)
		if found {
			stream_flag, _ := v.value_as_bool(stream_value)
			testing.expect(t, !stream_flag)
		}
	}
	// The default endpoint is OpenRouter's.
	testing.expectf(
		t,
		strings.has_prefix(spec.request.url, "https://openrouter.ai/api/v1/"),
		"url: %s",
		spec.request.url,
	)
}

@(test)
test_wire_body_responses_stateless :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	options := test_payload(
		test_map_entry("previous_response_id", test_string("resp_1")),
		test_map_entry("temperature", test_int(0)),
	)
	payload := test_payload(
		test_map_entry("model", test_string("test-model")),
		test_map_entry("input", v.value_list(context.temp_allocator, []v.Value{})),
		test_map_entry("instructions", test_string("be brief")),
		test_map_entry("options", options),
		test_map_entry("base_url", test_string("https://openrouter.ai/api/v1")),
	)
	spec, message_text, ok := build_spec(payload, .Responses, true, context.temp_allocator)
	testing.expectf(t, ok, "build_spec failed: %s", message_text)
	if !ok {
		return
	}
	body, _, decoded := r.json_decode_text(context.temp_allocator, string(spec.request.body[:]))
	testing.expect(t, decoded)
	if !decoded {
		return
	}
	if _, found := lookup(body, "previous_response_id"); found {
		testing.expect(t, false, "previous_response_id must be dropped")
	}
	store_value, has_store := lookup(body, "store")
	testing.expect(t, has_store)
	if has_store {
		store_flag, _ := v.value_as_bool(store_value)
		testing.expect(t, !store_flag)
	}
	include, has_include := lookup(body, "include")
	testing.expect(t, has_include)
	if has_include {
		items, _ := v.value_as_list(include)
		testing.expect_value(t, len(items), 1)
		if len(items) == 1 {
			text, _ := v.value_as_string(items[0])
			testing.expect_value(t, text, "reasoning.encrypted_content")
		}
	}
	testing.expect_value(t, test_lookup_text(t, body, "instructions"), "be brief")
}

@(test)
test_spec_headers_and_url :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	payload := test_payload(
		test_map_entry("model", test_string("test-model")),
		test_map_entry("messages", v.value_list(context.temp_allocator, []v.Value{})),
		test_map_entry("base_url", test_string("http://127.0.0.1:1234/v1/")),
		test_map_entry("path", test_string("/chat/completions")),
		test_map_entry("api_key", test_string("secret")),
		test_map_entry("referer", test_string("https://mica.local")),
		test_map_entry("title", test_string("Mica")),
	)
	spec, message_text, ok := build_spec(payload, .Chat_Completions, false, context.temp_allocator)
	testing.expectf(t, ok, "build_spec failed: %s", message_text)
	if !ok {
		return
	}
	testing.expect_value(t, spec.request.url, "http://127.0.0.1:1234/v1/chat/completions")
	testing.expect_value(t, spec.provider, "api")
	joined := strings.join(spec.request.headers, "\n", context.temp_allocator)
	testing.expectf(t, strings.contains(joined, "Authorization: Bearer secret"), "%s", joined)
	testing.expectf(t, strings.contains(joined, "HTTP-Referer: https://mica.local"), "%s", joined)
	testing.expectf(t, strings.contains(joined, "X-OpenRouter-Title: Mica"), "%s", joined)
}

// --- Event normalization ---------------------------------------------------

@(private)
test_decoder :: proc(
	t: ^testing.T,
	wire_api: Wire_API,
	payloads: []string,
) -> [dynamic]v.Value {
	decoder: Event_Decoder
	event_decoder_init(&decoder, wire_api, "test", context.temp_allocator)
	defer event_decoder_destroy(&decoder)
	events: [dynamic]v.Value
	for payload in payloads {
		frame := fmt_aprintf_temp("data: %s\n\n", payload)
		if message, ok := event_decoder_push(
			&decoder,
			transmute([]byte)frame,
			&events,
		); !ok {
			testing.expectf(t, false, "decode failed: %s", message)
			return events
		}
	}
	if message, ok := event_decoder_finish(&decoder, &events); !ok {
		testing.expectf(t, false, "finish failed: %s", message)
	}
	return events
}

@(private)
test_event_kind :: proc(event: v.Value) -> string {
	kind, _ := lookup_symbol_name(event, "type")
	return kind
}

// Expands `:batch` messages into the kinds of the events they carry.
@(private)
test_event_kinds_flat :: proc(
	events: []v.Value,
	allocator: mem.Allocator,
) -> [dynamic]string {
	kinds := make([dynamic]string, 0, len(events), allocator)
	for event in events {
		if test_event_kind(event) != "batch" {
			append(&kinds, test_event_kind(event))
			continue
		}
		batch, found := lookup(event, "events")
		if !found {
			continue
		}
		items, is_list := v.value_as_list(batch)
		if !is_list {
			continue
		}
		for item in items {
			append(&kinds, test_event_kind(item))
		}
	}
	return kinds
}

@(test)
test_chat_stream_events :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	payloads := []string {
		`{"choices":[{"delta":{"content":"hel"}}]}`,
		`{"choices":[{"delta":{"content":"lo"},"finish_reason":"stop"}]}`,
	}
	events := test_decoder(t, .Chat_Completions, payloads)
	defer delete(events)

	kinds := make([dynamic]string, 0, len(events), context.temp_allocator)
	for event in events {
		append(&kinds, test_event_kind(event))
	}
	testing.expect_value(t, len(kinds), 4)
	if len(kinds) != 4 {
		return
	}
	testing.expect_value(t, kinds[0], "started")
	testing.expect_value(t, kinds[1], "text_delta")
	testing.expect_value(t, kinds[2], "text_delta")
	testing.expect_value(t, kinds[3], "completed")
	if kinds[1] == "text_delta" && kinds[2] == "text_delta" {
		testing.expect_value(t, test_lookup_text(t, events[1], "delta"), "hel")
		testing.expect_value(t, test_lookup_text(t, events[2], "delta"), "lo")
	}
}

@(test)
test_chat_tool_call_events :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	payloads := []string {
		`{"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_1","function":{"name":"look","arguments":"{\"at\":"}}]}}]}`,
		`{"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"\"here\"}"}}]},"finish_reason":"tool_calls"}]}`,
		`[DONE]`,
	}
	events := test_decoder(t, .Chat_Completions, payloads)
	defer delete(events)

	kinds := make([dynamic]string, 0, len(events), context.temp_allocator)
	for event in events {
		append(&kinds, test_event_kind(event))
	}
	// started, two argument deltas, tool_call_ready, completed.
	testing.expect_value(t, len(kinds), 5)
	if len(kinds) != 5 {
		return
	}
	testing.expect_value(t, kinds[0], "started")
	testing.expect_value(t, kinds[1], "tool_arguments_delta")
	testing.expect_value(t, kinds[2], "tool_arguments_delta")
	testing.expect_value(t, kinds[3], "tool_call_ready")
	testing.expect_value(t, kinds[4], "completed")
	for event in events {
		if test_event_kind(event) == "tool_call_ready" {
			testing.expect_value(t, test_lookup_text(t, event, "call_id"), "call_1")
			testing.expect_value(t, test_lookup_text(t, event, "name"), "look")
			testing.expect_value(
				t,
				test_lookup_text(t, event, "arguments"),
				"{\"at\":\"here\"}",
			)
		}
	}
}

@(test)
test_responses_stream_events :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	payloads := []string {
		`{"type":"response.created"}`,
		`{"type":"response.output_text.delta","delta":"hi","item_id":"item_1","output_index":0,"content_index":0}`,
		`{"type":"response.output_item.added","item":{"type":"function_call","id":"fc_1","call_id":"call_9","name":"grep","arguments":""}}`,
		`{"type":"response.function_call_arguments.done","item_id":"fc_1","call_id":"call_9","name":"grep","arguments":"{\"q\":\"x\"}"}`,
		`{"type":"response.completed","response":{"usage":{"total_tokens":3},"output":[]}}`,
	}
	events := test_decoder(t, .Responses, payloads)
	defer delete(events)

	kinds := make([dynamic]string, 0, len(events), context.temp_allocator)
	for event in events {
		append(&kinds, test_event_kind(event))
	}
	testing.expect_value(t, len(kinds), 5)
	if len(kinds) != 5 {
		return
	}
	testing.expect_value(t, kinds[0], "started")
	testing.expect_value(t, kinds[1], "text_delta")
	testing.expect_value(t, kinds[2], "tool_call_started")
	testing.expect_value(t, kinds[3], "tool_call_ready")
	testing.expect_value(t, kinds[4], "completed")
	if kinds[4] == "completed" {
		_, has_usage := lookup(events[4], "usage")
		testing.expect(t, has_usage)
	}
}

@(test)
test_stream_without_terminal_reports_error :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	events := test_decoder(
		t,
		.Chat_Completions,
		[]string{`{"choices":[{"delta":{"content":"x"}}]}`},
	)
	defer delete(events)
	last := events[len(events) - 1]
	testing.expect_value(t, test_event_kind(last), "error")
}

// A provider that leaks DSML tool calls as streamed text: the markup can be
// split across deltas, and the recovered call must arrive before `completed`.
@(test)
test_chat_stream_dsml_recovery :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	payloads := []string {
		`{"choices":[{"delta":{"content":"Let me look. "}}]}`,
		`{"choices":[{"delta":{"content":"<｜DSML｜tool_calls><｜DSML｜invoke name=\"ls\"><｜DSML｜param"}}]}`,
		`{"choices":[{"delta":{"content":"eter name=\"path\" string=\"true\">.</｜DSML｜parameter></｜DSML｜invoke></｜DSML｜tool_calls>"}}]}`,
		`{"choices":[{"delta":{},"finish_reason":"stop"}]}`,
		`[DONE]`,
	}
	events := test_decoder(t, .Chat_Completions, payloads)
	defer delete(events)

	kinds := test_event_kinds_flat(events[:], context.temp_allocator)
	testing.expect_value(t, len(kinds), 4)
	if len(kinds) != 4 {
		return
	}
	testing.expect_value(t, kinds[0], "started")
	testing.expect_value(t, kinds[1], "text_delta")
	testing.expect_value(t, kinds[2], "tool_call_ready")
	testing.expect_value(t, kinds[3], "completed")
	for event in events {
		switch test_event_kind(event) {
		case "text_delta":
			delta := test_lookup_text(t, event, "delta")
			testing.expectf(t, !strings.contains(delta, "DSML"), "leaked DSML: %s", delta)
			testing.expect_value(t, delta, "Let me look. ")
		case "tool_call_ready":
			testing.expect_value(t, test_lookup_text(t, event, "call_id"), "dsml_tool_1")
			testing.expect_value(t, test_lookup_text(t, event, "name"), "ls")
			arguments := test_lookup_text(t, event, "arguments")
			testing.expectf(
				t,
				strings.contains(arguments, "\"path\""),
				"arguments: %s",
				arguments,
			)
		}
	}
}

@(test)
test_responses_stream_dsml_recovery :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	payloads := []string {
		`{"type":"response.output_text.delta","delta":"Working","item_id":"i1","output_index":0,"content_index":0}`,
		`{"type":"response.output_text.delta","delta":" < | DSML | tool_calls>< | DSML | invoke name=\"read\">< | DSML | parameter name=\"path\" string=\"true\">a.mica</ | DSML | parameter></ | DSML | invoke></ | DSML | tool_calls>","item_id":"i1","output_index":0,"content_index":0}`,
		`{"type":"response.output_text.delta","delta":" after","item_id":"i1","output_index":0,"content_index":0}`,
		`{"type":"response.completed","response":{"output":[]}}`,
	}
	events := test_decoder(t, .Responses, payloads)
	defer delete(events)

	kinds := test_event_kinds_flat(events[:], context.temp_allocator)
	// The space before the marker is its own delta, then the held " after".
	testing.expect_value(t, len(kinds), 6)
	if len(kinds) != 6 {
		return
	}
	testing.expect_value(t, kinds[0], "started")
	testing.expect_value(t, kinds[1], "text_delta")
	testing.expect_value(t, kinds[2], "text_delta")
	testing.expect_value(t, kinds[3], "tool_call_ready")
	testing.expect_value(t, kinds[4], "text_delta")
	testing.expect_value(t, kinds[5], "completed")

	builder: strings.Builder
	strings.builder_init(&builder, context.temp_allocator)
	defer strings.builder_destroy(&builder)
	for event in events {
		if test_event_kind(event) == "text_delta" {
			strings.write_string(&builder, test_lookup_text(t, event, "delta"))
		}
		if test_event_kind(event) == "tool_call_ready" {
			testing.expect_value(t, test_lookup_text(t, event, "name"), "read")
			arguments := test_lookup_text(t, event, "arguments")
			testing.expectf(t, strings.contains(arguments, "a.mica"), "arguments: %s", arguments)
		}
	}
	// The space before the marker and the leading space of the trailing text
	// are both real stream content.
	testing.expect_value(t, strings.to_string(builder), "Working  after")
}

// A block the model never closes still produces its call before `completed`.
@(test)
test_chat_stream_dsml_without_close :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	payloads := []string {
		`{"choices":[{"delta":{"content":"<｜DSML｜tool_calls><｜DSML｜invoke name=\"look\"><｜DSML｜parameter name=\"at\" string=\"true\">here</｜DSML｜parameter></｜DSML｜invoke>"}}]}`,
		`{"choices":[{"delta":{},"finish_reason":"stop"}]}`,
	}
	events := test_decoder(t, .Chat_Completions, payloads)
	defer delete(events)

	kinds := test_event_kinds_flat(events[:], context.temp_allocator)
	testing.expect_value(t, len(kinds), 3)
	if len(kinds) != 3 {
		return
	}
	testing.expect_value(t, kinds[0], "started")
	testing.expect_value(t, kinds[1], "tool_call_ready")
	testing.expect_value(t, kinds[2], "completed")
}

// Ordinary text with an angle bracket is not mistaken for markup.
@(test)
test_chat_stream_plain_angle_text :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	payloads := []string {
		`{"choices":[{"delta":{"content":"a < b"}}]}`,
		`{"choices":[{"delta":{"content":" c"}}]}`,
		`{"choices":[{"delta":{},"finish_reason":"stop"}]}`,
	}
	events := test_decoder(t, .Chat_Completions, payloads)
	defer delete(events)

	builder: strings.Builder
	strings.builder_init(&builder, context.temp_allocator)
	defer strings.builder_destroy(&builder)
	for event in events {
		if test_event_kind(event) == "text_delta" {
			strings.write_string(&builder, test_lookup_text(t, event, "delta"))
		}
	}
	testing.expect_value(t, strings.to_string(builder), "a < b c")
}

// --- DSML ------------------------------------------------------------------

@(test)
test_dsml_normalization :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	response_text := `{"choices":[{"message":{"role":"assistant","content":"< | DSML | invoke name=\"source_file_window\">< | DSML | parameter name=\"path\" string=\"true\">crates/kernel.rs</ | DSML | parameter>< | DSML | parameter name=\"start_line\" string=\"false\">150</ | DSML | parameter></ | DSML | invoke>"}}]}`
	response, message, decoded := r.json_decode_text(context.temp_allocator, response_text)
	testing.expectf(t, decoded, "decode failed: %s", message)
	if !decoded {
		return
	}
	ctx := r.External_Context{allocator = context.temp_allocator}
	normalized := normalize_openai_tool_calls(ctx, response)
	choices_value, _ := lookup(normalized, "choices")
	choices, _ := v.value_as_list(choices_value)
	testing.expect_value(t, len(choices), 1)
	if len(choices) != 1 {
		return
	}
	message_value, _ := lookup(choices[0], "message")
	calls_value, found := lookup(message_value, "tool_calls")
	testing.expect(t, found)
	if !found {
		return
	}
	calls, _ := v.value_as_list(calls_value)
	testing.expect_value(t, len(calls), 1)
	if len(calls) != 1 {
		return
	}
	function, _ := lookup(calls[0], "function")
	testing.expect_value(t, test_lookup_text(t, function, "name"), "source_file_window")
	arguments := test_lookup_text(t, function, "arguments")
	parsed, _, arguments_ok := r.json_decode_text(context.temp_allocator, arguments)
	testing.expectf(t, arguments_ok, "arguments not JSON: %s", arguments)
	if arguments_ok {
		testing.expect_value(t, test_lookup_text(t, parsed, "path"), "crates/kernel.rs")
		start_line, _ := lookup(parsed, "start_line")
		line, _ := v.value_as_int(start_line)
		testing.expect_value(t, line, i64(150))
	}
}

// --- Live transfers through libcurl ----------------------------------------

@(private)
Stub_Response :: struct {
	listener: net.TCP_Socket,
	start:    time.Tick,
	response: string,
	// The bytes curl sent, for request assertions. Guarded by `mutex`: the
	// serving thread appends while the test thread reads after the transfer,
	// and the network is not a synchronization edge ThreadSanitizer can see.
	mutex:    sync.Mutex,
	received: [dynamic]u8,
}

@(private)
stub_received_append :: proc(server: ^Stub_Response, data: []byte) {
	sync.mutex_lock(&server.mutex)
	append(&server.received, ..data)
	sync.mutex_unlock(&server.mutex)
}

@(private)
stub_received_length :: proc(server: ^Stub_Response) -> int {
	sync.mutex_lock(&server.mutex)
	defer sync.mutex_unlock(&server.mutex)
	return len(server.received)
}

@(private)
stub_received_find_header_end :: proc(server: ^Stub_Response) -> int {
	sync.mutex_lock(&server.mutex)
	defer sync.mutex_unlock(&server.mutex)
	return strings.index(string(server.received[:]), "\r\n\r\n")
}

@(private)
stub_received_headers :: proc(server: ^Stub_Response) -> string {
	sync.mutex_lock(&server.mutex)
	defer sync.mutex_unlock(&server.mutex)
	return string(server.received[:])
}

@(private)
stub_received_text :: proc(server: ^Stub_Response) -> string {
	sync.mutex_lock(&server.mutex)
	defer sync.mutex_unlock(&server.mutex)
	return strings.clone(string(server.received[:]), context.temp_allocator)
}

@(private)
stub_server_proc :: proc(data: rawptr) {
	context = runtime.default_context()
	server := (^Stub_Response)(data)
	client, _, accept_err := net.accept_tcp(server.listener)
	if accept_err != nil {
		return
	}
	defer net.close(client)
	_ = net.set_option(client, .Receive_Timeout, 2 * time.Second)

	// Read until the header block and any declared body have arrived.
	header_end := -1
	expected := 0
	chunk: [4096]u8
	for time.tick_since(server.start) < 5 * time.Second {
		read, recv_err := net.recv_tcp(client, chunk[:])
		if read > 0 {
			stub_received_append(server, chunk[:read])
			if header_end < 0 {
				if index := stub_received_find_header_end(server); index >= 0 {
					header_end = index + 4
					headers := stub_received_headers(server)
					expected = header_end + stub_content_length(headers[:header_end])
				}
			}
			if header_end >= 0 && stub_received_length(server) >= expected {
				break
			}
			continue
		}
		if recv_err == .Would_Block || recv_err == .Timeout || recv_err == .Interrupted {
			continue
		}
		break
	}

	response := server.response
	sent := 0
	for sent < len(response) {
		count, send_err := net.send_tcp(client, transmute([]byte)response[sent:])
		if send_err != .None || count <= 0 {
			break
		}
		sent += count
	}
}

@(private)
stub_content_length :: proc(headers: string) -> int {
	text := headers
	for line in strings.split_lines_iterator(&text) {
		trimmed := strings.trim_space(line)
		if !strings.has_prefix(strings.to_lower(trimmed, context.temp_allocator), "content-length:") {
			continue
		}
		value := strings.trim_space(trimmed[len("content-length:"):])
		if parsed, ok := strconv.parse_int(value); ok {
			return parsed
		}
	}
	return 0
}

@(private)
Stub_Server :: struct {
	listener: net.TCP_Socket,
	// Heap-allocated because the serving thread outlives this struct's
	// creation point; a stack copy would be freed under it.
	state:    ^Stub_Response,
	thread:   ^thread.Thread,
}

@(private)
stub_start :: proc(t: ^testing.T, response: string) -> (Stub_Server, bool) {
	server: Stub_Server
	listener, listen_err := net.listen_tcp(net.Endpoint {
		address = net.IP4_Address{127, 0, 0, 1},
		port    = 0,
	})
	if listen_err != nil {
		testing.expectf(t, false, "listen failed: %v", listen_err)
		return server, false
	}
	// The serving thread appends while the test thread runs curl, so the
	// buffer needs a thread-safe allocator, not the test rollback stack.
	allocator := runtime.default_allocator()
	state := new(Stub_Response, allocator)
	state.response = response
	state.received = make([dynamic]u8, 0, 4096, allocator)
	state.listener = listener
	state.start = time.tick_now()
	server.listener = listener
	server.state = state
	server.thread = thread.create_and_start_with_data(state, stub_server_proc)
	if server.thread == nil {
		net.close(listener)
		free(state, allocator)
		testing.expect(t, false, "cannot start stub server")
		return server, false
	}
	return server, true
}

@(private)
stub_stop :: proc(server: ^Stub_Server) {
	if server.thread != nil {
		thread.join(server.thread)
		thread.destroy(server.thread)
	}
	net.close(server.listener)
	if server.state != nil {
		delete(server.state.received)
		free(server.state, runtime.default_allocator())
		server.state = nil
	}
}

@(private)
stub_url :: proc(server: ^Stub_Server) -> string {
	endpoint, endpoint_err := net.bound_endpoint(server.listener)
	if endpoint_err != nil {
		return ""
	}
	return fmt_aprintf_temp("http://%s", net.endpoint_to_string(endpoint))
}

// A fake runtime context for the live tests. `spawn` runs the stream worker
// inline so the test is deterministic; `deliver` records events.
@(private)
Test_Delivery :: struct {
	events:    [dynamic]v.Value,
	allocator: mem.Allocator,
}

@(private)
test_deliver :: proc(user: rawptr, sender: v.Value, value: v.Value) -> bool {
	delivery := (^Test_Delivery)(user)
	append(&delivery.events, value)
	return true
}

@(private)
test_stopping :: proc(user: rawptr) -> bool {
	return false
}

@(private)
test_spawn :: proc(user: rawptr, worker: proc(data: rawptr), data: rawptr) -> bool {
	worker(data)
	return true
}

@(private)
test_context :: proc(delivery: ^Test_Delivery) -> r.External_Context {
	return r.External_Context {
		allocator = delivery.allocator,
		deliver = test_deliver,
		user = delivery,
		spawn = test_spawn,
		stopping = test_stopping,
	}
}

@(test)
test_live_chat_completion :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	response_body := `{"id":"chatcmpl-1","choices":[{"message":{"role":"assistant","content":"pong"}}]}`
	response := fmt_aprintf_temp(
		"HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: %d\r\nConnection: close\r\n\r\n%s",
		len(response_body),
		response_body,
	)
	server, ok := stub_start(t, response)
	if !ok {
		return
	}
	defer stub_stop(&server)

	delivery := Test_Delivery {
		events    = make([dynamic]v.Value, 0, 4, context.temp_allocator),
		allocator = context.temp_allocator,
	}
	defer delete(delivery.events)
	ctx := test_context(&delivery)
	payload := test_payload(
		test_map_entry("model", test_string("test-model")),
		test_map_entry("messages", v.value_list(context.temp_allocator, []v.Value{})),
		test_map_entry("base_url", test_string(stub_url(&server))),
	)
	result := handle_request(ctx, v.value_symbol(v.symbol_intern("openai")), payload)
	error_value, is_error := v.value_as_error(result)
	if is_error {
		code, _ := v.symbol_name(error_value.code)
		testing.expectf(t, false, "request failed: %s %s", code, error_value.message)
		return
	}
	choices_value, _ := lookup(result, "choices")
	choices, _ := v.value_as_list(choices_value)
	testing.expect_value(t, len(choices), 1)
	if len(choices) == 1 {
		message, _ := lookup(choices[0], "message")
		testing.expect_value(t, test_lookup_text(t, message, "content"), "pong")
	}
	received := stub_received_text(server.state)
	testing.expectf(
		t,
		strings.contains(received, "\"model\":\"test-model\""),
		"request body: %s",
		received,
	)
}

// The checked-in demo filein loads in a real world, streams from the stub
// server through `handle_request`, and records its assembled answer.
@(test)
test_example_filein_streams_against_stub :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	demo_path := example_candidate()
	if demo_path == "" {
		testing.expect(t, false, "apps/examples/llm-chat.mica not found")
		return
	}

	response_body := "data: {\"choices\":[{\"delta\":{\"content\":\"hello \"}}]}\n\n" +
		"data: {\"choices\":[{\"delta\":{\"content\":\"world\"},\"finish_reason\":\"stop\"}]}\n\n" +
		"data: [DONE]\n\n"
	response := fmt_aprintf_temp(
		"HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nContent-Length: %d\r\nConnection: close\r\n\r\n%s",
		len(response_body),
		response_body,
	)
	server, ok := stub_start(t, response)
	if !ok {
		return
	}
	defer stub_stop(&server)

	_ = os.set_env("MICA_OPENAI_BASE_URL", stub_url(&server))
	defer os.unset_env("MICA_OPENAI_BASE_URL")
	_ = os.set_env("MICA_LLM_DEMO_MODEL", "stub-model")
	defer os.unset_env("MICA_LLM_DEMO_MODEL")
	_ = os.set_env("MICA_LLM_DEMO_PROMPT", "hi")
	defer os.unset_env("MICA_LLM_DEMO_PROMPT")

	kernel: k.Kernel
	k.kernel_init(&kernel)
	defer k.kernel_destroy(&kernel)

	// Thread-safe world allocator: scheduler and external worker threads
	// allocate from it concurrently.
	world, start := r.world_start(
		&kernel,
		[]string{demo_path},
		context.temp_allocator,
		r.World_Config {
			workers          = 1,
			external_handler = handle_request,
			external_workers = 1,
		},
	)
	if !start.ok {
		testing.expectf(t, false, "world start failed: %s", start.message)
		return
	}
	defer r.world_destroy(world)

	outcome := r.world_wait(world, world.entry)
	testing.expectf(
		t,
		outcome.kind == .Complete,
		"entry outcome: %v %s",
		outcome.kind,
		outcome.message,
	)
	metadata, found := k.snapshot_relation_metadata_named(
		kernel.current,
		v.symbol_intern("llm/DemoResult"),
	)
	testing.expect(t, found)
	if !found {
		return
	}
	bindings := make([]v.Binding, metadata.arity, context.temp_allocator)
	rows: [dynamic]v.Tuple
	defer delete(rows)
	k.kernel_scan_into(&kernel, metadata.id, bindings, &rows)
	testing.expectf(t, len(rows) == 1, "DemoResult has %d rows", len(rows))
	if len(rows) != 1 {
		return
	}
	values := v.tuple_values(rows[0])
	if len(values) != 2 {
		return
	}
	prompt, _ := v.value_as_string(values[0])
	answer, _ := v.value_as_string(values[1])
	testing.expect_value(t, prompt, "hi")
	testing.expect_value(t, answer, "hello world")
}

@(private)
example_candidate :: proc() -> string {
	candidates := []string{
		"apps/examples/llm-chat.mica",
		"../apps/examples/llm-chat.mica",
		"../../apps/examples/llm-chat.mica",
	}
	for candidate in candidates {
		if os.is_file(candidate) {
			return candidate
		}
	}
	return ""
}

@(test)
test_live_chat_stream :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	response_body := "data: {\"choices\":[{\"delta\":{\"content\":\"hello\"}}]}\n\n" +
		"data: [DONE]\n\n"
	response := fmt_aprintf_temp(
		"HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nContent-Length: %d\r\nConnection: close\r\n\r\n%s",
		len(response_body),
		response_body,
	)
	server, ok := stub_start(t, response)
	if !ok {
		return
	}
	defer stub_stop(&server)

	delivery := Test_Delivery {
		events    = make([dynamic]v.Value, 0, 4, context.temp_allocator),
		allocator = context.temp_allocator,
	}
	defer delete(delivery.events)
	ctx := test_context(&delivery)
	payload := test_payload(
		test_map_entry("model", test_string("test-model")),
		test_map_entry("messages", v.value_list(context.temp_allocator, []v.Value{})),
		test_map_entry("base_url", test_string(stub_url(&server))),
		test_map_entry("stream_to", test_string("mailbox")),
	)
	result := handle_request(ctx, v.value_symbol(v.symbol_intern("openai")), payload)
	started, found := lookup(result, "started")
	testing.expect(t, found)
	if found {
		started_flag, _ := v.value_as_bool(started)
		testing.expect(t, started_flag)
	}

	kinds := test_event_kinds_flat(delivery.events[:], context.temp_allocator)
	testing.expect_value(t, len(kinds), 3)
	if len(kinds) != 3 {
		return
	}
	testing.expect_value(t, kinds[0], "started")
	testing.expect_value(t, kinds[1], "text_delta")
	testing.expect_value(t, kinds[2], "completed")
	received := stub_received_text(server.state)
	testing.expectf(
		t,
		strings.contains(received, "\"stream\":true"),
		"request body: %s",
		received,
	)
}
