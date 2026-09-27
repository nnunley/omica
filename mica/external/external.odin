// Outbound HTTP services and the LLM stream bridge for Mica hosts.
//
// This package implements the external services the Rust port serves from
// `external-http`: generic `http`, `openai` Chat Completions,
// `openai_responses`, and `embedding` request shapes. `openai` and
// `openai_responses` accept a `stream_to` mailbox sender and deliver typed
// stream events as they arrive.
//
// `handle_request` matches `mica_runtime.External_Handler`; pass it in
// `World_Config.external_handler`. Handlers run on a runtime external worker
// thread with a private temporary arena that is reset between requests, so
// `context.temp_allocator` is safe for short-lived strings. Values returned
// or delivered must come from `ctx.allocator`, which lives as long as the
// world.
package mica_external

import "core:fmt"
import "core:mem"
import "core:os"
import "core:strings"
import r "../runtime"
import v "../var"

// The services this package answers. Anything else fails with an
// `ExternalError` value for the parked task.
handle_request :: proc(
	ctx: r.External_Context,
	service: v.Value,
	payload: v.Value,
) -> v.Value {
	symbol, is_symbol := v.value_as_symbol(service)
	if !is_symbol {
		return error_value(ctx, "external request service must be a symbol")
	}
	name, has_name := v.symbol_name(symbol)
	if !has_name {
		return error_value(ctx, "external request service has no name")
	}
	switch name {
	case "http":
		return handle_http(ctx, payload)
	case "openai":
		if sender, streaming := stream_sender(payload); streaming {
			return handle_stream(ctx, .Chat_Completions, payload, sender)
		}
		return handle_chat_completion(ctx, payload)
	case "openai_responses":
		if sender, streaming := stream_sender(payload); streaming {
			return handle_stream(ctx, .Responses, payload, sender)
		}
		return error_value(ctx, "openai_responses requires a `stream_to` mailbox")
	case "embedding":
		return handle_embedding(ctx, payload)
	}
	return error_value(ctx, fmt.aprintf("unknown external service %q", name))
}

// An `ExternalError` value the runtime resumes the parked task with. The
// message is copied into the world lifetime, so callers may pass temporary
// strings.
@(private)
error_value :: proc(ctx: r.External_Context, message: string) -> v.Value {
	return v.value_error(
		ctx.allocator,
		v.symbol_intern("ExternalError"),
		strings.clone(message, ctx.allocator),
		true,
		v.Value(0),
		false,
	)
}

// --- Value helpers ---------------------------------------------------------

@(private)
lookup :: proc(payload: v.Value, name: string) -> (v.Value, bool) {
	entries, is_map := v.value_as_map(payload)
	if !is_map {
		return v.Value(0), false
	}
	key := v.value_symbol(v.symbol_intern(name))
	for entry in entries {
		if v.value_eq(entry.key, key) {
			return entry.value, true
		}
	}
	return v.Value(0), false
}

// Strings and symbols both count as text, as in the Rust bridge.
@(private)
value_text :: proc(value: v.Value) -> (string, bool) {
	if text, is_string := v.value_as_string(value); is_string {
		return text, true
	}
	if symbol, is_symbol := v.value_as_symbol(value); is_symbol {
		name, has_name := v.symbol_name(symbol)
		return name, has_name
	}
	return "", false
}

// An optional string field.
@(private)
optional_string :: proc(payload: v.Value, name: string) -> (string, string, bool) {
	value, found := lookup(payload, name)
	if !found {
		return "", "", true
	}
	text, is_string := v.value_as_string(value)
	if !is_string {
		return "", fmt.aprintf("%q must be a string", name, allocator = context.temp_allocator), false
	}
	return text, "", true
}

@(private)
require_string :: proc(payload: v.Value, name: string) -> (string, string, bool) {
	text, message, ok := optional_string(payload, name)
	if !ok {
		return "", message, false
	}
	if text == "" {
		return "", fmt.aprintf("missing %q", name, allocator = context.temp_allocator), false
	}
	return text, "", true
}

// An optional `headers` field: a list of `[name, value]` pairs. Header lines
// are transient and allocated with `allocator`.
@(private)
optional_headers :: proc(
	payload: v.Value,
	allocator: mem.Allocator,
) -> (
	[dynamic]string,
	string,
	bool,
) {
	headers: [dynamic]string
	value, found := lookup(payload, "headers")
	if !found {
		return headers, "", true
	}
	pairs, is_list := v.value_as_list(value)
	if !is_list {
		return headers, "headers must be a list of pairs", false
	}
	for pair in pairs {
		parts, is_pair := v.value_as_list(pair)
		if !is_pair || len(parts) != 2 {
			return headers, "header pairs must contain name and value", false
		}
		name, name_ok := value_text(parts[0])
		header_value, value_ok := value_text(parts[1])
		if !name_ok || !value_ok {
			return headers, "header names and values must be strings", false
		}
		append(
			&headers,
			fmt.aprintf("%s: %s", name, header_value, allocator = allocator),
		)
	}
	return headers, "", true
}

// The request body for a generic request: a `body` string, or an encoded
// `json` value, or nothing.
@(private)
request_body :: proc(
	payload: v.Value,
	allocator: mem.Allocator,
) -> (
	[]byte,
	string,
	bool,
) {
	if body, found := lookup(payload, "body"); found {
		if text, is_string := v.value_as_string(body); is_string {
			return transmute([]byte)text, "", true
		}
		return nil, "body must be a string", false
	}
	if json_value, found := lookup(payload, "json"); found {
		text, ok := r.json_encode_text(allocator, json_value)
		if !ok {
			return nil, "json body is not encodable", false
		}
		return transmute([]byte)text, "", true
	}
	return nil, "", true
}

// The Mica JSON null value, `{:json -> :null}`.
@(private)
json_null_value :: proc(allocator: mem.Allocator) -> v.Value {
	return v.value_map(allocator, []v.Map_Entry {
		{
			key   = v.value_symbol(v.symbol_intern("json")),
			value = v.value_symbol(v.symbol_intern("null")),
		},
	})
}

// --- Generic HTTP ----------------------------------------------------------

@(private)
handle_http :: proc(ctx: r.External_Context, payload: v.Value) -> v.Value {
	url, url_message, url_ok := require_string(payload, "url")
	if !url_ok {
		return error_value(ctx, url_message)
	}
	method, method_message, method_ok := optional_string(payload, "method")
	if !method_ok {
		return error_value(ctx, method_message)
	}
	headers, headers_message, headers_ok := optional_headers(payload, context.temp_allocator)
	if !headers_ok {
		return error_value(ctx, headers_message)
	}
	body, body_message, body_ok := request_body(payload, context.temp_allocator)
	if !body_ok {
		return error_value(ctx, body_message)
	}

	result, curl_message := curl_perform(
		Request{url = url, method = method, headers = headers[:], body = body},
		context.temp_allocator,
	)
	if curl_message != "" {
		return error_value(ctx, curl_message)
	}
	return http_response_value(ctx, result)
}

// The `{:status, :headers, :body}` map both generic HTTP and raw OpenAI
// responses use.
@(private)
http_response_value :: proc(ctx: r.External_Context, result: Curl_Result) -> v.Value {
	status_value, _ := v.value_int(i64(result.status))
	header_values := make([]v.Value, len(result.headers), context.temp_allocator)
	for header, index in result.headers {
		header_values[index] = v.value_list(ctx.allocator, []v.Value {
			v.value_string(ctx.allocator, header[0]),
			v.value_string(ctx.allocator, header[1]),
		})
	}
	return v.value_map(ctx.allocator, []v.Map_Entry {
		{key = v.value_symbol(v.symbol_intern("status")), value = status_value},
		{
			key = v.value_symbol(v.symbol_intern("headers")),
			value = v.value_list(ctx.allocator, header_values),
		},
		{
			key = v.value_symbol(v.symbol_intern("body")),
			value = v.value_string(ctx.allocator, string(result.body[:])),
		},
	})
}

// --- Embeddings ------------------------------------------------------------

@(private)
handle_embedding :: proc(ctx: r.External_Context, payload: v.Value) -> v.Value {
	model, model_message, model_ok := require_string(payload, "model")
	if !model_ok {
		return error_value(ctx, model_message)
	}
	text, text_message, text_ok := require_string(payload, "text")
	if !text_ok {
		return error_value(ctx, text_message)
	}
	base_url, _, _ := optional_string(payload, "base_url")
	if base_url == "" {
		base_url, _ = os.lookup_env("MICA_VLLM_BASE_URL", context.temp_allocator)
	}
	if base_url == "" {
		base_url = "http://127.0.0.1:8000/v1"
	}
	path, _, _ := optional_string(payload, "path")
	if path == "" {
		path = "/embeddings"
	}
	headers, headers_message, headers_ok := optional_headers(payload, context.temp_allocator)
	if !headers_ok {
		return error_value(ctx, headers_message)
	}

	body_entries: [dynamic]v.Map_Entry
	body_entries = make([dynamic]v.Map_Entry, 0, 4, context.temp_allocator)
	append(&body_entries, v.Map_Entry {
		key   = v.value_symbol(v.symbol_intern("input")),
		value = v.value_string(context.temp_allocator, text),
	})
	append(&body_entries, v.Map_Entry {
		key   = v.value_symbol(v.symbol_intern("model")),
		value = v.value_string(context.temp_allocator, model),
	})
	if truncate, has_truncate := truncate_prompt_tokens(); has_truncate {
		truncate_value, _ := v.value_int(truncate)
		append(&body_entries, v.Map_Entry {
			key   = v.value_symbol(v.symbol_intern("truncate_prompt_tokens")),
			value = truncate_value,
		})
	}
	body_value := v.value_map(context.temp_allocator, body_entries[:])
	body_text, encoded := r.json_encode_text(context.temp_allocator, body_value)
	if !encoded {
		return error_value(ctx, "cannot encode the embedding request")
	}

	request_headers := make([dynamic]string, 0, len(headers) + 1, context.temp_allocator)
	append(&request_headers, ..headers[:])
	if api_key := vllm_api_key(); api_key != "" {
		append(
			&request_headers,
			fmt.aprintf(
				"Authorization: Bearer %s",
				api_key,
				allocator = context.temp_allocator,
			),
		)
	}

	result, curl_message := curl_perform(
		Request {
			url = join_url_path(base_url, path, context.temp_allocator),
			headers = request_headers[:],
			body = transmute([]byte)body_text,
			timeout_seconds = openai_timeout_seconds(),
		},
		context.temp_allocator,
	)
	if curl_message != "" {
		return error_value(ctx, curl_message)
	}
	if result.status < 200 || result.status >= 300 {
		return error_value(ctx, fmt.aprintf(
			"embedding request failed with HTTP %d: %s",
			result.status,
			string(result.body[:]),
		))
	}
	response, parse_message, parsed := r.json_decode_text(
		context.temp_allocator,
		string(result.body[:]),
	)
	if !parsed {
		return error_value(ctx, fmt.aprintf("invalid embedding response: %s", parse_message))
	}
	return embedding_values(ctx, response)
}

@(private)
embedding_values :: proc(ctx: r.External_Context, response: v.Value) -> v.Value {
	missing :: "embedding response did not contain data[0].embedding"
	data, found := lookup(response, "data")
	if !found {
		return error_value(ctx, missing)
	}
	items, items_ok := v.value_as_list(data)
	if !items_ok || len(items) == 0 {
		return error_value(ctx, missing)
	}
	embedding, embedding_found := lookup(items[0], "embedding")
	if !embedding_found {
		return error_value(ctx, missing)
	}
	values, values_ok := v.value_as_list(embedding)
	if !values_ok {
		return error_value(ctx, missing)
	}
	converted := make([]v.Value, len(values), context.temp_allocator)
	for value, index in values {
		number, is_float := v.value_as_float(value)
		if !is_float {
			int_value, is_int := v.value_as_int(value)
			if !is_int {
				return error_value(ctx, fmt.aprintf(
					"embedding value at index %d was not a finite binary32",
					index,
				))
			}
			number = f32(int_value)
		}
		converted_value, converted_ok := v.value_float(number)
		if !converted_ok {
			return error_value(ctx, fmt.aprintf(
				"embedding value at index %d was not a finite binary32",
				index,
			))
		}
		converted[index] = converted_value
	}
	return v.value_list(ctx.allocator, converted)
}

// --- Shared configuration --------------------------------------------------

@(private)
join_url_path :: proc(base_url, path: string, allocator: mem.Allocator) -> string {
	return fmt.aprintf(
		"%s/%s",
		strings.trim_right(base_url, "/"),
		strings.trim_left(path, "/"),
		allocator = allocator,
	)
}

// The per-request LLM timeout. `MICA_OPENAI_TIMEOUT_SECS` defaults to 60;
// zero or less disables the timeout.
@(private)
openai_timeout_seconds :: proc() -> i64 {
	text, found := os.lookup_env("MICA_OPENAI_TIMEOUT_SECS", context.temp_allocator)
	if !found {
		return 60
	}
	seconds, parsed := parse_i64(text)
	if !parsed {
		return 60
	}
	return seconds > 0 ? seconds : 0
}

@(private)
truncate_prompt_tokens :: proc() -> (i64, bool) {
	text, found := os.lookup_env("MICA_VLLM_TRUNCATE_PROMPT_TOKENS", context.temp_allocator)
	if !found {
		return 512, true
	}
	value, parsed := parse_i64(text)
	if !parsed {
		return 0, false
	}
	if value == 0 {
		return 0, false
	}
	return value, true
}

@(private)
vllm_api_key :: proc() -> string {
	key, _ := os.lookup_env("MICA_VLLM_API_KEY", context.temp_allocator)
	return key
}

@(private)
parse_i64 :: proc(text: string) -> (i64, bool) {
	if text == "" {
		return 0, false
	}
	negative := false
	index := 0
	if text[0] == '-' {
		negative = true
		index = 1
	}
	if index >= len(text) {
		return 0, false
	}
	value: i64
	for ; index < len(text); index += 1 {
		ch := text[index]
		if ch < '0' || ch > '9' {
			return 0, false
		}
		value = value * 10 + i64(ch - '0')
	}
	return negative ? -value : value, true
}
