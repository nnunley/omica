// JSON conversion.
//
// Mirrors the Rust runtime's mapping: object keys are symbols on decode and
// may be strings or symbols on encode; JSON null is the map `{:json -> :null}`;
// number tokens without a fraction or exponent are integers limited to the
// Mica 56-bit integer range, and every other number must narrow to a finite
// binary32 float.
package mica_runtime

import "core:fmt"
import "core:mem"
import "core:strconv"
import "core:strings"
import "core:unicode/utf8"
import v "../var"

JSON_INT_MIN :: -(i64(1) << 55)
JSON_INT_MAX :: (i64(1) << 55) - 1

@(private)
json_null :: proc(allocator := context.allocator) -> v.Value {
	return v.value_map(allocator, []v.Map_Entry {
		{
			key   = v.value_symbol(v.symbol_intern("json")),
			value = v.value_symbol(v.symbol_intern("null")),
		},
	})
}

@(private)
json_value_is_null :: proc(value: v.Value) -> bool {
	entries, is_map := v.value_as_map(value)
	if !is_map || len(entries) != 1 {
		return false
	}
	return v.value_eq(entries[0].key, v.value_symbol(v.symbol_intern("json"))) &&
		v.value_eq(entries[0].value, v.value_symbol(v.symbol_intern("null")))
}

// --- Encoding --------------------------------------------------------------

@(private)
json_encode_value :: proc(builder: ^strings.Builder, value: v.Value) -> bool {
	if json_value_is_null(value) {
		strings.write_string(builder, "null")
		return true
	}
	#partial switch v.value_kind(value) {
	case .Bool:
		flag, _ := v.value_as_bool(value)
		strings.write_string(builder, flag ? "true" : "false")
		return true
	case .Int:
		number, _ := v.value_as_int(value)
		fmt.sbprintf(builder, "%d", number)
		return true
	case .Float:
		number, _ := v.value_as_float(value)
		start := len(builder.buf)
		fmt.sbprintf(builder, "%v", number)
		written := string(builder.buf[start:])
		if strings.contains_any(written, ".eE") {
			return true
		}
		strings.write_string(builder, ".0")
		return true
	case .String:
		text, _ := v.value_as_string(value)
		json_write_string(builder, text)
		return true
	case .Symbol:
		symbol, _ := v.value_as_symbol(value)
		name, has_name := v.symbol_name(symbol)
		if !has_name {
			return false
		}
		json_write_string(builder, name)
		return true
	case .List:
		values, _ := v.value_as_list(value)
		strings.write_byte(builder, '[')
		for item, index in values {
			if index > 0 {
				strings.write_byte(builder, ',')
			}
			if !json_encode_value(builder, item) {
				return false
			}
		}
		strings.write_byte(builder, ']')
		return true
	case .Map:
		entries, _ := v.value_as_map(value)
		strings.write_byte(builder, '{')
		for entry, index in entries {
			key_text, key_ok := json_key_text(entry.key)
			if !key_ok {
				return false
			}
			if index > 0 {
				strings.write_byte(builder, ',')
			}
			json_write_string(builder, key_text)
			strings.write_byte(builder, ':')
			if !json_encode_value(builder, entry.value) {
				return false
			}
		}
		strings.write_byte(builder, '}')
		return true
	case:
		return false
	}
}

@(private)
json_key_text :: proc(key: v.Value) -> (string, bool) {
	if text, is_string := v.value_as_string(key); is_string {
		return text, true
	}
	if symbol, is_symbol := v.value_as_symbol(key); is_symbol {
		name, has_name := v.symbol_name(symbol)
		if has_name {
			return name, true
		}
	}
	return "", false
}

@(private)
json_write_string :: proc(builder: ^strings.Builder, text: string) {
	strings.write_byte(builder, '"')
	for index := 0; index < len(text); {
		ch := text[index]
		switch ch {
		case '"':
			strings.write_string(builder, "\\\"")
			index += 1
		case '\\':
			strings.write_string(builder, "\\\\")
			index += 1
		case '\n':
			strings.write_string(builder, "\\n")
			index += 1
		case '\r':
			strings.write_string(builder, "\\r")
			index += 1
		case '\t':
			strings.write_string(builder, "\\t")
			index += 1
		case 0x08:
			strings.write_string(builder, "\\b")
			index += 1
		case 0x0c:
			strings.write_string(builder, "\\f")
			index += 1
		case:
			if ch < 0x20 {
				fmt.sbprintf(builder, "\\u%04x", ch)
				index += 1
			} else {
				_, size := utf8.decode_rune(text[index:])
				strings.write_string(builder, text[index:index + size])
				index += size
			}
		}
	}
	strings.write_byte(builder, '"')
}

// --- Decoding --------------------------------------------------------------

@(private)
JSON_Parser :: struct {
	text: string,
	pos:  int,
}

@(private)
json_decode_text :: proc(
	allocator: mem.Allocator,
	text: string,
) -> (
	v.Value,
	string,
	bool,
) {
	parser := JSON_Parser{text = text}
	value, message, ok := json_parse_value(&parser, allocator)
	if !ok {
		return v.Value(0), message, false
	}
	json_skip_whitespace(&parser)
	if parser.pos < len(parser.text) {
		return v.Value(0), "trailing data after JSON value", false
	}
	return value, "", true
}

@(private)
json_parse_value :: proc(
	parser: ^JSON_Parser,
	allocator: mem.Allocator,
) -> (
	v.Value,
	string,
	bool,
) {
	json_skip_whitespace(parser)
	if parser.pos >= len(parser.text) {
		return v.Value(0), "expected JSON value", false
	}
	ch := parser.text[parser.pos]
	switch ch {
	case 'n':
		if !json_expect(parser, "null") {
			return v.Value(0), "invalid JSON literal", false
		}
		return json_null(allocator), "", true
	case 't':
		if !json_expect(parser, "true") {
			return v.Value(0), "invalid JSON literal", false
		}
		return v.value_bool(true), "", true
	case 'f':
		if !json_expect(parser, "false") {
			return v.Value(0), "invalid JSON literal", false
		}
		return v.value_bool(false), "", true
	case '"':
		text, message, ok := json_parse_string(parser, allocator)
		if !ok {
			return v.Value(0), message, false
		}
		return v.value_string(allocator, text), "", true
	case '[':
		return json_parse_array(parser, allocator)
	case '{':
		return json_parse_object(parser, allocator)
	case '-', '0' ..= '9':
		return json_parse_number(parser, allocator)
	}
	return v.Value(0), "expected JSON value", false
}

@(private)
json_parse_array :: proc(
	parser: ^JSON_Parser,
	allocator: mem.Allocator,
) -> (
	v.Value,
	string,
	bool,
) {
	parser.pos += 1
	values: [dynamic]v.Value
	defer delete(values)
	json_skip_whitespace(parser)
	if json_consume(parser, "]") {
		return v.value_list(allocator, nil), "", true
	}
	for {
		value, message, ok := json_parse_value(parser, allocator)
		if !ok {
			return v.Value(0), message, false
		}
		append(&values, value)
		json_skip_whitespace(parser)
		if json_consume(parser, "]") {
			break
		}
		if !json_expect(parser, ",") {
			return v.Value(0), "expected ',' or ']' in JSON array", false
		}
	}
	return v.value_list(allocator, values[:]), "", true
}

@(private)
json_parse_object :: proc(
	parser: ^JSON_Parser,
	allocator: mem.Allocator,
) -> (
	v.Value,
	string,
	bool,
) {
	parser.pos += 1
	entries: [dynamic]v.Map_Entry
	defer delete(entries)
	json_skip_whitespace(parser)
	if json_consume(parser, "}") {
		return v.value_map(allocator, nil), "", true
	}
	for {
		json_skip_whitespace(parser)
		if parser.pos >= len(parser.text) || parser.text[parser.pos] != '"' {
			return v.Value(0), "expected JSON object key", false
		}
		key, message, key_ok := json_parse_string(parser, allocator)
		if !key_ok {
			return v.Value(0), message, false
		}
		json_skip_whitespace(parser)
		if !json_expect(parser, ":") {
			return v.Value(0), "expected ':' after JSON object key", false
		}
		value, value_message, value_ok := json_parse_value(parser, allocator)
		if !value_ok {
			return v.Value(0), value_message, false
		}
		append(&entries, v.Map_Entry {
			key   = v.value_symbol(v.symbol_intern(key)),
			value = value,
		})
		json_skip_whitespace(parser)
		if json_consume(parser, "}") {
			break
		}
		if !json_expect(parser, ",") {
			return v.Value(0), "expected ',' or '}' in JSON object", false
		}
	}
	return v.value_map(allocator, entries[:]), "", true
}

@(private)
json_parse_number :: proc(
	parser: ^JSON_Parser,
	allocator: mem.Allocator,
) -> (
	v.Value,
	string,
	bool,
) {
	start := parser.pos
	if parser.text[parser.pos] == '-' {
		parser.pos += 1
	}
	if parser.pos >= len(parser.text) {
		return v.Value(0), "invalid JSON number", false
	}
	switch parser.text[parser.pos] {
	case '0':
		parser.pos += 1
		if parser.pos < len(parser.text) &&
		   parser.text[parser.pos] >= '0' &&
		   parser.text[parser.pos] <= '9' {
			return v.Value(0), "leading zero in JSON number", false
		}
	case '1' ..= '9':
		for parser.pos < len(parser.text) &&
		    parser.text[parser.pos] >= '0' &&
		    parser.text[parser.pos] <= '9' {
			parser.pos += 1
		}
	case:
		return v.Value(0), "invalid JSON number", false
	}

	is_float := false
	if parser.pos < len(parser.text) && parser.text[parser.pos] == '.' {
		is_float = true
		parser.pos += 1
		if !json_consume_digits(parser) {
			return v.Value(0), "expected digit after decimal point", false
		}
	}
	if parser.pos < len(parser.text) &&
	   (parser.text[parser.pos] == 'e' || parser.text[parser.pos] == 'E') {
		is_float = true
		parser.pos += 1
		if parser.pos < len(parser.text) &&
		   (parser.text[parser.pos] == '+' || parser.text[parser.pos] == '-') {
			parser.pos += 1
		}
		if !json_consume_digits(parser) {
			return v.Value(0), "expected exponent digits", false
		}
	}

	token := parser.text[start:parser.pos]
	if !is_float {
		number, parsed := strconv.parse_i64(token)
		if !parsed || number < JSON_INT_MIN || number > JSON_INT_MAX {
			return v.Value(0), "JSON integer is outside the Mica integer range", false
		}
		converted, converted_ok := v.value_int(number)
		if !converted_ok {
			return v.Value(0), "invalid JSON integer", false
		}
		return converted, "", true
	}
	number, parsed := strconv.parse_f64(token)
	if !parsed {
		return v.Value(0), "invalid JSON float", false
	}
	converted, converted_ok := v.value_float(f32(number))
	if !converted_ok {
		return v.Value(0), "JSON float overflows binary32", false
	}
	return converted, "", true
}

@(private)
json_parse_string :: proc(
	parser: ^JSON_Parser,
	allocator: mem.Allocator,
) -> (
	string,
	string,
	bool,
) {
	parser.pos += 1
	builder: strings.Builder
	strings.builder_init(&builder, allocator)
	for parser.pos < len(parser.text) {
		ch := parser.text[parser.pos]
		switch ch {
		case '"':
			parser.pos += 1
			return strings.to_string(builder), "", true
		case '\\':
			parser.pos += 1
			if parser.pos >= len(parser.text) {
				strings.builder_destroy(&builder)
				return "", "unterminated JSON string escape", false
			}
			escape := parser.text[parser.pos]
			parser.pos += 1
			switch escape {
			case '"':
				strings.write_byte(&builder, '"')
			case '\\':
				strings.write_byte(&builder, '\\')
			case '/':
				strings.write_byte(&builder, '/')
			case 'b':
				strings.write_byte(&builder, 0x08)
			case 'f':
				strings.write_byte(&builder, 0x0c)
			case 'n':
				strings.write_byte(&builder, '\n')
			case 'r':
				strings.write_byte(&builder, '\r')
			case 't':
				strings.write_byte(&builder, '\t')
			case 'u':
				rune_value, rune_ok := json_parse_hex4(parser)
				if !rune_ok {
					strings.builder_destroy(&builder)
					return "", "invalid JSON unicode escape", false
				}
				if rune_value >= 0xd800 && rune_value <= 0xdbff {
					low, low_ok := json_parse_low_surrogate(parser)
					if !low_ok {
						strings.builder_destroy(&builder)
						return "", "invalid JSON surrogate pair", false
					}
					rune_value = 0x10000 +
						((rune_value - 0xd800) << 10) +
						(low - 0xdc00)
				} else if rune_value >= 0xdc00 && rune_value <= 0xdfff {
					strings.builder_destroy(&builder)
					return "", "unpaired JSON surrogate", false
				}
				strings.write_rune(&builder, rune(rune_value))
			case:
				strings.builder_destroy(&builder)
				return "", "invalid JSON string escape", false
			}
		case:
			if ch < 0x20 {
				strings.builder_destroy(&builder)
				return "", "control character in JSON string", false
			}
			_, size := utf8.decode_rune(parser.text[parser.pos:])
			strings.write_string(
				&builder,
				parser.text[parser.pos:parser.pos + size],
			)
			parser.pos += size
		}
	}
	strings.builder_destroy(&builder)
	return "", "unterminated JSON string", false
}

@(private)
json_parse_hex4 :: proc(parser: ^JSON_Parser) -> (u32, bool) {
	if parser.pos + 4 > len(parser.text) {
		return 0, false
	}
	value: u32
	for _ in 0 ..< 4 {
		ch := parser.text[parser.pos]
		digit: u32
		switch ch {
		case '0' ..= '9':
			digit = u32(ch - '0')
		case 'a' ..= 'f':
			digit = u32(ch - 'a') + 10
		case 'A' ..= 'F':
			digit = u32(ch - 'A') + 10
		case:
			return 0, false
		}
		value = value * 16 + digit
		parser.pos += 1
	}
	return value, true
}

@(private)
json_parse_low_surrogate :: proc(parser: ^JSON_Parser) -> (u32, bool) {
	if parser.pos + 2 > len(parser.text) ||
	   parser.text[parser.pos] != '\\' ||
	   parser.text[parser.pos + 1] != 'u' {
		return 0, false
	}
	parser.pos += 2
	value, ok := json_parse_hex4(parser)
	if !ok || value < 0xdc00 || value > 0xdfff {
		return 0, false
	}
	return value, true
}

@(private)
json_skip_whitespace :: proc(parser: ^JSON_Parser) {
	for parser.pos < len(parser.text) {
		switch parser.text[parser.pos] {
		case ' ', '\n', '\r', '\t':
			parser.pos += 1
		case:
			return
		}
	}
}

@(private)
json_consume :: proc(parser: ^JSON_Parser, expected: string) -> bool {
	if parser.pos + len(expected) > len(parser.text) {
		return false
	}
	if parser.text[parser.pos:parser.pos + len(expected)] != expected {
		return false
	}
	parser.pos += len(expected)
	return true
}

@(private)
json_expect :: proc(parser: ^JSON_Parser, expected: string) -> bool {
	return json_consume(parser, expected)
}

@(private)
json_consume_digits :: proc(parser: ^JSON_Parser) -> bool {
	if parser.pos >= len(parser.text) ||
	   parser.text[parser.pos] < '0' ||
	   parser.text[parser.pos] > '9' {
		return false
	}
	for parser.pos < len(parser.text) &&
	    parser.text[parser.pos] >= '0' &&
	    parser.text[parser.pos] <= '9' {
		parser.pos += 1
	}
	return true
}
