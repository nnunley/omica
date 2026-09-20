// DSML tool-call normalization.
//
// Some OpenAI-compatible providers leak tool calls into message content as
// DSML markup instead of populating `tool_calls`. The Rust bridge recognizes
// that markup and rewrites the response so callers see ordinary tool calls.
// This ports that normalization.
package mica_external

import "core:mem"
import "core:strconv"
import "core:strings"
import r "../runtime"
import v "../var"

// Rewrites any choice whose message content holds DSML tool calls. Returns the
// original response when nothing needed changing.
@(private)
normalize_openai_tool_calls :: proc(ctx: r.External_Context, response: v.Value) -> v.Value {
	choices_value, found := lookup(response, "choices")
	if !found {
		return response
	}
	choices, is_list := v.value_as_list(choices_value)
	if !is_list {
		return response
	}
	updated_choices := make([]v.Value, len(choices), context.temp_allocator)
	copy(updated_choices, choices)
	changed := false
	for choice, index in choices {
		message, has_message := lookup(choice, "message")
		if !has_message {
			continue
		}
		if _, has_tool_calls := lookup(message, "tool_calls"); has_tool_calls {
			continue
		}
		content, has_content := lookup_text(message, "content")
		if !has_content {
			continue
		}
		calls, count := parse_dsml_tool_calls(content, ctx.allocator)
		if count == 0 {
			continue
		}
		updated_message, message_ok := map_set(ctx.allocator, message, "tool_calls", calls)
		if !message_ok {
			continue
		}
		updated_message, message_ok = map_set(
			ctx.allocator,
			updated_message,
			"content",
			json_null_value(ctx.allocator),
		)
		if !message_ok {
			continue
		}
		updated_choice, choice_ok := map_set(
			ctx.allocator,
			choice,
			"message",
			updated_message,
		)
		if !choice_ok {
			continue
		}
		updated_choices[index] = updated_choice
		changed = true
	}
	if !changed {
		return response
	}
	updated, ok := map_set(
		ctx.allocator,
		response,
		"choices",
		v.value_list(ctx.allocator, updated_choices),
	)
	if !ok {
		return response
	}
	return updated
}

// Adds or replaces a symbol-keyed map entry. Later entries win in
// `value_map`, so the override is appended.
@(private)
map_set :: proc(
	allocator: mem.Allocator,
	map_value: v.Value,
	name: string,
	value: v.Value,
) -> (
	v.Value,
	bool,
) {
	entries, is_map := v.value_as_map(map_value)
	if !is_map {
		return v.Value(0), false
	}
	updated := make([]v.Map_Entry, len(entries) + 1, context.temp_allocator)
	copy(updated, entries)
	updated[len(entries)] = symbol_entry(name, value)
	return v.value_map(allocator, updated), true
}

// Parses DSML markup into a list of tool-call maps and the number found.
// `first_index` numbers the generated call ids, so a stream that flushes
// several DSML blocks keeps its ids unique.
@(private)
parse_dsml_tool_calls :: proc(
	content: string,
	allocator: mem.Allocator,
	first_index := 1,
) -> (
	v.Value,
	int,
) {
	calls := make([dynamic]v.Value, 0, 2, context.temp_allocator)
	if !strings.contains(content, "DSML") || !strings.contains(content, "invoke name=\"") {
		return v.value_list(allocator, calls[:]), 0
	}
	marker :: "invoke name=\""
	cursor := 0
	for {
		relative_start := strings.index(content[cursor:], marker)
		if relative_start < 0 {
			break
		}
		invoke_start := cursor + relative_start
		name_start := invoke_start + len(marker)
		relative_name_end := strings.index(content[name_start:], "\"")
		if relative_name_end < 0 {
			break
		}
		name_end := name_start + relative_name_end
		name := content[name_start:name_end]
		relative_tag_end := strings.index(content[name_end:], ">")
		if relative_tag_end < 0 {
			break
		}
		tag_end := name_end + relative_tag_end
		next_invoke := len(content)
		if relative_next := strings.index(content[tag_end + 1:], marker); relative_next >= 0 {
			next_invoke = tag_end + 1 + relative_next
		}
		block := content[tag_end + 1:next_invoke]
		arguments_map := parse_dsml_parameters(block, allocator)
		arguments_text, encoded := r.json_encode_text(allocator, arguments_map)
		if !encoded {
			arguments_text = "{}"
		}
		function := v.value_map(allocator, []v.Map_Entry {
			symbol_entry("name", v.value_string(allocator, decode_dsml_text(name))),
			symbol_entry("arguments", v.value_string(allocator, arguments_text)),
		})
		call := v.value_map(allocator, []v.Map_Entry {
			symbol_entry(
				"id",
				v.value_string(
					allocator,
					fmt_aprintf_temp("dsml_tool_%d", first_index + len(calls)),
				),
			),
			symbol_entry("type", v.value_string(allocator, "function")),
			symbol_entry("function", function),
		})
		append(&calls, call)
		cursor = next_invoke
	}
	return v.value_list(allocator, calls[:]), len(calls)
}

@(private)
parse_dsml_parameters :: proc(block: string, allocator: mem.Allocator) -> v.Value {
	parameters: [dynamic]v.Map_Entry
	parameters = make([dynamic]v.Map_Entry, 0, 4, context.temp_allocator)
	marker :: "parameter name=\""
	cursor := 0
	for {
		relative_start := strings.index(block[cursor:], marker)
		if relative_start < 0 {
			break
		}
		parameter_start := cursor + relative_start
		name_start := parameter_start + len(marker)
		relative_name_end := strings.index(block[name_start:], "\"")
		if relative_name_end < 0 {
			break
		}
		name_end := name_start + relative_name_end
		name := decode_dsml_text(block[name_start:name_end])
		relative_tag_end := strings.index(block[name_end:], ">")
		if relative_tag_end < 0 {
			break
		}
		tag_end := name_end + relative_tag_end
		tag := block[parameter_start:tag_end + 1]
		value_start := tag_end + 1
		relative_value_end := strings.index(block[value_start:], "</")
		if relative_value_end < 0 {
			break
		}
		value_end := value_start + relative_value_end
		raw_value := decode_dsml_text(block[value_start:value_end])
		string_attribute, has_string_attribute := quoted_attr_value(tag, "string")
		is_string := !has_string_attribute || string_attribute != "false"
		append(
			&parameters,
			symbol_entry(name, dsml_parameter_value(raw_value, is_string, allocator)),
		)
		cursor = value_end + 2
	}
	return v.value_map(allocator, parameters[:])
}

@(private)
quoted_attr_value :: proc(tag: string, attribute: string) -> (string, bool) {
	marker := fmt_aprintf_temp("%s=\"", attribute)
	value_start := strings.index(tag, marker)
	if value_start < 0 {
		return "", false
	}
	value_start += len(marker)
	relative_end := strings.index(tag[value_start:], "\"")
	if relative_end < 0 {
		return "", false
	}
	return tag[value_start:value_start + relative_end], true
}

@(private)
dsml_parameter_value :: proc(
	raw_value: string,
	is_string: bool,
	allocator: mem.Allocator,
) -> v.Value {
	if is_string {
		return v.value_string(allocator, raw_value)
	}
	trimmed := strings.trim_space(raw_value)
	switch trimmed {
	case "true":
		return v.value_bool(true)
	case "false":
		return v.value_bool(false)
	case "null":
		return json_null_value(allocator)
	}
	if integer, parsed := strconv.parse_i64(trimmed); parsed {
		if value, ok := v.value_int(integer); ok {
			return value
		}
	}
	if number, parsed := strconv.parse_f32(trimmed); parsed {
		if value, ok := v.value_float(number); ok {
			return value
		}
	}
	return v.value_string(allocator, raw_value)
}

@(private)
decode_dsml_text :: proc(value: string) -> string {
	replaced, _ := strings.replace_all(
		value,
		"&quot;",
		"\"",
		allocator = context.temp_allocator,
	)
	replaced, _ = strings.replace_all(
		replaced,
		"&apos;",
		"'",
		allocator = context.temp_allocator,
	)
	replaced, _ = strings.replace_all(
		replaced,
		"&lt;",
		"<",
		allocator = context.temp_allocator,
	)
	replaced, _ = strings.replace_all(
		replaced,
		"&gt;",
		">",
		allocator = context.temp_allocator,
	)
	replaced, _ = strings.replace_all(
		replaced,
		"&amp;",
		"&",
		allocator = context.temp_allocator,
	)
	return replaced
}
