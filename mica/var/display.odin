// Display formatting for values.
package var

import "core:encoding/base64"
import "core:fmt"
import "core:strings"

// Writes a value in its display form to `builder`.
write_value :: proc(builder: ^strings.Builder, v: Value) {
	switch value_kind(v) {
	case .Bool:
		b, _ := value_as_bool(v)
		strings.write_string(builder, b ? "true" : "false")
	case .Int:
		n, _ := value_as_int(v)
		fmt.sbprintf(builder, "%d", n)
	case .Float:
		f, _ := value_as_float(v)
		fmt.sbprintf(builder, "%v", f)
	case .Identity:
		id, _ := value_as_identity(v)
		fmt.sbprintf(builder, "#%d", identity_raw(id))
	case .Capability:
		strings.write_string(builder, "<cap>")
	case .Function:
		strings.write_string(builder, "<function>")
	case .Symbol:
		symbol, _ := value_as_symbol(v)
		if name, ok := symbol_name(symbol); ok {
			fmt.sbprintf(builder, ":%s", name)
		} else {
			fmt.sbprintf(builder, ":#%d", symbol_id(symbol))
		}
	case .Error_Code:
		symbol, _ := value_as_error_code(v)
		if name, ok := symbol_name(symbol); ok {
			strings.write_string(builder, name)
		} else {
			fmt.sbprintf(builder, "E_#%d", symbol_id(symbol))
		}
	case .String:
		s, _ := value_as_string(v)
		strings.write_string(builder, s)
	case .Bytes:
		data, _ := value_as_bytes(v)
		encoded := base64.encode(data, base64.ENC_URL_TABLE, context.temp_allocator)
		fmt.sbprintf(builder, "b\"%s\"", encoded)
	case .List:
		values, _ := value_as_list(v)
		strings.write_byte(builder, '{')
		for value, i in values {
			if i != 0 {
				strings.write_string(builder, ", ")
			}
			write_value(builder, value)
		}
		strings.write_byte(builder, '}')
	case .Map:
		entries, _ := value_as_map(v)
		strings.write_byte(builder, '[')
		for entry, i in entries {
			if i != 0 {
				strings.write_string(builder, ", ")
			}
			write_value(builder, entry.key)
			strings.write_string(builder, ": ")
			write_value(builder, entry.value)
		}
		strings.write_byte(builder, ']')
	case .Range:
		start, end, has_end, _ := value_as_range(v)
		write_value(builder, start)
		strings.write_string(builder, "..")
		if has_end {
			write_value(builder, end)
		} else {
			strings.write_string(builder, "_")
		}
	case .Error:
		error, _ := value_as_error(v)
		strings.write_string(builder, "error(")
		if name, ok := symbol_name(error.code); ok {
			strings.write_string(builder, name)
		} else {
			fmt.sbprintf(builder, "E_#%d", symbol_id(error.code))
		}
		if error.has_message {
			fmt.sbprintf(builder, ", %q", error.message)
		}
		if error.has_value {
			if !error.has_message {
				strings.write_string(builder, ", none")
			}
			strings.write_string(builder, ", ")
			write_value(builder, error.value)
		}
		strings.write_byte(builder, ')')
	case .Frob:
		frob, _ := value_as_frob(v)
		fmt.sbprintf(builder, "#%d<", identity_raw(frob.delegate))
		write_value(builder, frob.value)
		strings.write_byte(builder, '>')
	case .Relation:
		switch {
		case value_is_empty_relation(v):
			strings.write_string(builder, "[] {}")
		case:
			relation, _ := value_as_relation(v)
			if len(relation.heading) == 0 && len(relation.rows) == 1 {
				strings.write_string(builder, "()")
			} else {
				fmt.sbprintf(builder, "<relation %dx%d>", len(relation.rows), len(relation.heading))
			}
		}
	}
}

// Returns the display form of a value, allocated from `alloc`.
value_to_string :: proc(v: Value, alloc := context.allocator) -> string {
	builder: strings.Builder
	strings.builder_init(&builder, alloc)
	write_value(&builder, v)
	return strings.to_string(builder)
}

// Returns a debug form of a value, allocated from `alloc`. Strings and
// payloads are quoted so that structure is visible.
value_to_debug_string :: proc(v: Value, alloc := context.allocator) -> string {
	builder: strings.Builder
	strings.builder_init(&builder, alloc)
	write_value_debug(&builder, v)
	return strings.to_string(builder)
}

// Writes a value in its debug form to `builder`.
write_value_debug :: proc(builder: ^strings.Builder, v: Value) {
	#partial switch value_kind(v) {
	case .String:
		s, _ := value_as_string(v)
		fmt.sbprintf(builder, "%q", s)
	case .List:
		values, _ := value_as_list(v)
		strings.write_byte(builder, '{')
		for value, i in values {
			if i != 0 {
				strings.write_string(builder, ", ")
			}
			write_value_debug(builder, value)
		}
		strings.write_byte(builder, '}')
	case .Map:
		entries, _ := value_as_map(v)
		strings.write_byte(builder, '[')
		for entry, i in entries {
			if i != 0 {
				strings.write_string(builder, ", ")
			}
			write_value_debug(builder, entry.key)
			strings.write_string(builder, ": ")
			write_value_debug(builder, entry.value)
		}
		strings.write_byte(builder, ']')
	case:
		write_value(builder, v)
	}
}
