// OpenAI-compatible request building: endpoint, headers, and JSON bodies.
//
// The body shapes match the Rust external-http bridge byte for byte where it
// matters: Chat Completions carries model/messages/tools/stream, and
// Responses carries model/input/instructions/tools/stream/store/include and
// drops previous_response_id so every request is stateless and driven by the
// full Mica-owned input.
package mica_external

import "core:fmt"
import "core:mem"
import "core:os"
import "core:strings"
import r "../runtime"
import v "../var"

Wire_API :: enum {
	Chat_Completions,
	Responses,
}

// A prepared request plus the metadata the streaming bridge reports.
Request_Spec :: struct {
	request:      Request,
	provider:     string,
	model:        string,
	raw_response: bool,
}

// Builds the request for `openai`/`openai_responses`. When the payload carries
// a raw `body` or `json`, `raw_response` is set and the caller returns the
// `{:status, :headers, :body}` map instead of parsing JSON.
build_spec :: proc(
	payload: v.Value,
	wire_api: Wire_API,
	streaming: bool,
	allocator: mem.Allocator,
) -> (
	Request_Spec,
	string,
	bool,
) {
	model, model_message, model_ok := require_string(payload, "model")
	if !model_ok {
		return {}, model_message, false
	}
	base_url, _, _ := optional_string(payload, "base_url")
	if base_url == "" {
		base_url, _ = os.lookup_env("MICA_OPENAI_BASE_URL", context.temp_allocator)
	}
	if base_url == "" {
		base_url, _ = os.lookup_env("OPENROUTER_BASE_URL", context.temp_allocator)
	}
	if base_url == "" {
		base_url = "https://openrouter.ai/api/v1"
	}
	default_path := wire_api == .Responses ? "/responses" : "/chat/completions"
	path, _, _ := optional_string(payload, "path")
	if path == "" {
		path = default_path
	}

	headers, headers_message, headers_ok := optional_headers(payload, allocator)
	if !headers_ok {
		return {}, headers_message, false
	}
	append(&headers, "Content-Type: application/json")
	if api_key := openai_api_key(payload); api_key != "" {
		append(&headers, fmt.aprintf("Authorization: Bearer %s", api_key, allocator = allocator))
	}
	referer, _, _ := optional_string(payload, "referer")
	if referer == "" {
		referer, _ = os.lookup_env("MICA_OPENROUTER_REFERER", context.temp_allocator)
	}
	if referer == "" {
		referer, _ = os.lookup_env("OPENROUTER_HTTP_REFERER", context.temp_allocator)
	}
	if referer != "" {
		append(&headers, fmt.aprintf("HTTP-Referer: %s", referer, allocator = allocator))
	}
	title, _, _ := optional_string(payload, "title")
	if title == "" {
		title, _ = os.lookup_env("MICA_OPENROUTER_TITLE", context.temp_allocator)
	}
	if title == "" {
		title, _ = os.lookup_env("OPENROUTER_TITLE", context.temp_allocator)
	}
	if title != "" {
		append(&headers, fmt.aprintf("X-OpenRouter-Title: %s", title, allocator = allocator))
	}

	spec := Request_Spec {
		request = Request {
			url = join_url_path(base_url, path, allocator),
			headers = headers[:],
			timeout_seconds = openai_timeout_seconds(),
		},
		provider = provider_name(base_url),
		model = model,
	}

	_, has_body := lookup(payload, "body")
	_, has_json := lookup(payload, "json")
	if !streaming && (has_body || has_json) {
		body, message, ok := request_body(payload, allocator)
		if !ok {
			return {}, message, false
		}
		spec.request.body = body
		spec.raw_response = true
		return spec, "", true
	}

	encoded, message, ok := wire_body(payload, wire_api, streaming, allocator)
	if !ok {
		return {}, message, false
	}
	spec.request.body = transmute([]byte)encoded
	return spec, "", true
}

// The JSON request body encoded as text.
@(private)
wire_body :: proc(
	payload: v.Value,
	wire_api: Wire_API,
	streaming: bool,
	allocator: mem.Allocator,
) -> (
	string,
	string,
	bool,
) {
	entries: [dynamic]v.Map_Entry
	entries = make([dynamic]v.Map_Entry, 0, 16, allocator)
	if options, found := lookup(payload, "options"); found {
		option_entries, is_map := v.value_as_map(options)
		if !is_map {
			return "", "\"options\" must be a map", false
		}
		for entry in option_entries {
			if wire_api == .Responses && is_symbol_key(entry.key, "previous_response_id") {
				continue
			}
			append(&entries, entry)
		}
	}

	model, message, ok := require_string(payload, "model")
	if !ok {
		return "", message, false
	}
	append(&entries, symbol_entry("model", v.value_string(allocator, model)))

	switch wire_api {
	case .Chat_Completions:
		messages, found := lookup(payload, "messages")
		if !found {
			return "", "missing \"messages\"", false
		}
		append(&entries, symbol_entry("messages", messages))
		if tools, found := lookup(payload, "tools"); found {
			append(&entries, symbol_entry("tools", tools))
		}
		append(&entries, symbol_entry("stream", v.value_bool(streaming)))

	case .Responses:
		input, found := lookup(payload, "input")
		if !found {
			return "", "missing \"input\"", false
		}
		append(&entries, symbol_entry("input", input))
		append(&entries, symbol_entry("stream", v.value_bool(true)))
		append(&entries, symbol_entry("store", v.value_bool(false)))
		if !has_symbol_key(entries[:], "include") {
			include := v.value_list(allocator, []v.Value {
				v.value_string(allocator, "reasoning.encrypted_content"),
			})
			append(&entries, symbol_entry("include", include))
		}
		if instructions, found := lookup(payload, "instructions"); found {
			append(&entries, symbol_entry("instructions", instructions))
		}
		if tools, found := lookup(payload, "tools"); found {
			append(&entries, symbol_entry("tools", tools))
		}
	}

	body := v.value_map(allocator, entries[:])
	text, encoded := r.json_encode_text(allocator, body)
	if !encoded {
		return "", "cannot encode the request body", false
	}
	return text, "", true
}

// The non-streaming `openai` request. A raw body/json payload returns the HTTP
// map; otherwise the JSON response is parsed, with leaked DSML tool calls in
// message content normalized.
@(private)
handle_chat_completion :: proc(ctx: r.External_Context, payload: v.Value) -> v.Value {
	// The request is built and consumed within this call, so its strings can
	// live in the worker's temporary arena.
	spec, message, ok := build_spec(payload, .Chat_Completions, false, context.temp_allocator)
	if !ok {
		return error_value(ctx, message)
	}
	result, curl_message := curl_perform(spec.request, context.temp_allocator)
	if curl_message != "" {
		return error_value(ctx, curl_message)
	}
	if spec.raw_response {
		return http_response_value(ctx, result)
	}
	if result.status < 200 || result.status >= 300 {
		return error_value(ctx, fmt_aprintf_temp(
			"OpenAI chat completion failed with HTTP %d: %s",
			result.status,
			string(result.body[:]),
		))
	}
	response, parse_message, parsed := r.json_decode_text(
		context.temp_allocator,
		string(result.body[:]),
	)
	if !parsed {
		return error_value(ctx, fmt_aprintf_temp(
			"OpenAI response is not valid JSON: %s",
			parse_message,
		))
	}
	return normalize_openai_tool_calls(ctx, response)
}

// --- Helpers ---------------------------------------------------------------

@(private)
fmt_aprintf_temp :: proc(format: string, args: ..any) -> string {
	return fmt.aprintf(format, ..args, allocator = context.temp_allocator)
}

@(private)
symbol_entry :: proc(name: string, value: v.Value) -> v.Map_Entry {
	return v.Map_Entry {
		key   = v.value_symbol(v.symbol_intern(name)),
		value = value,
	}
}

@(private)
is_symbol_key :: proc(key: v.Value, name: string) -> bool {
	return v.value_eq(key, v.value_symbol(v.symbol_intern(name)))
}

@(private)
has_symbol_key :: proc(entries: []v.Map_Entry, name: string) -> bool {
	for entry in entries {
		if is_symbol_key(entry.key, name) {
			return true
		}
	}
	return false
}

@(private)
openai_api_key :: proc(payload: v.Value) -> string {
	key, _, _ := optional_string(payload, "api_key")
	if key != "" {
		return key
	}
	key, _ = os.lookup_env("OPENROUTER_API_KEY", context.temp_allocator)
	if key != "" {
		return key
	}
	key, _ = os.lookup_env("OPENAI_API_KEY", context.temp_allocator)
	return key
}

@(private)
provider_name :: proc(base_url: string) -> string {
	if strings.contains(base_url, "openrouter") {
		return "openrouter"
	}
	if strings.contains(base_url, "api.openai.com") {
		return "openai"
	}
	return "api"
}
