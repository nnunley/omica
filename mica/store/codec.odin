// Binary encoding for the persistable value subset.
//
// The format is versioned by `CODEC_VERSION` and little-endian. Symbols encode
// as their names and are re-interned on decode. Capability and function values
// are not persistable and fail with `Not_Persistable`.
package store

import "core:mem"
import v "../var"

CODEC_VERSION :: 1

Codec_Error :: enum {
	None,
	Not_Persistable,
	Truncated,
	Bad_Tag,
}

@(private)
codec_write_u8 :: proc(out: ^[dynamic]u8, value: u8) {
	append(out, value)
}

@(private)
codec_write_u32 :: proc(out: ^[dynamic]u8, value: u32) {
	append(out, u8(value), u8(value >> 8), u8(value >> 16), u8(value >> 24))
}

@(private)
codec_write_u64 :: proc(out: ^[dynamic]u8, value: u64) {
	for index in 0 ..< 8 {
		append(out, u8(value >> (8 * u32(index))))
	}
}

@(private)
codec_write_i64 :: proc(out: ^[dynamic]u8, value: i64) {
	codec_write_u64(out, u64(value))
}

@(private)
codec_write_string :: proc(out: ^[dynamic]u8, text: string) {
	codec_write_u32(out, u32(len(text)))
	append(out, ..transmute([]u8)text)
}

@(private)
codec_write_symbol :: proc(out: ^[dynamic]u8, symbol: v.Symbol) -> Codec_Error {
	name, has_name := v.symbol_name(symbol)
	if !has_name {
		return .Bad_Tag
	}
	codec_write_string(out, name)
	return .None
}

// Appends one value to `out`. Returns `Not_Persistable` for capability and
// function values and `Bad_Tag` for malformed immediates.
codec_encode_value :: proc(out: ^[dynamic]u8, value: v.Value) -> Codec_Error {
	kind := v.value_kind(value)
	codec_write_u8(out, u8(kind))
	#partial switch kind {
	case .Bool:
		boolean, ok := v.value_as_bool(value)
		if !ok {
			return .Bad_Tag
		}
		codec_write_u8(out, boolean ? 1 : 0)
	case .Int:
		number, ok := v.value_as_int(value)
		if !ok {
			return .Bad_Tag
		}
		codec_write_i64(out, number)
	case .Float:
		number, ok := v.value_as_float(value)
		if !ok {
			return .Bad_Tag
		}
		codec_write_u32(out, transmute(u32)number)
	case .Identity:
		identity, ok := v.value_as_identity(value)
		if !ok {
			return .Bad_Tag
		}
		codec_write_u64(out, v.identity_raw(identity))
	case .Symbol:
		symbol, ok := v.value_as_symbol(value)
		if !ok {
			return .Bad_Tag
		}
		return codec_write_symbol(out, symbol)
	case .Error_Code:
		symbol, ok := v.value_error_code_symbol(value)
		if !ok {
			return .Bad_Tag
		}
		return codec_write_symbol(out, symbol)
	case .String:
		text, ok := v.value_as_string(value)
		if !ok {
			return .Bad_Tag
		}
		codec_write_string(out, text)
	case .Bytes:
		data, ok := v.value_as_bytes(value)
		if !ok {
			return .Bad_Tag
		}
		codec_write_u32(out, u32(len(data)))
		append(out, ..data)
	case .List:
		values, ok := v.value_as_list(value)
		if !ok {
			return .Bad_Tag
		}
		codec_write_u32(out, u32(len(values)))
		for item in values {
			if error := codec_encode_value(out, item); error != .None {
				return error
			}
		}
	case .Map:
		entries, ok := v.value_as_map(value)
		if !ok {
			return .Bad_Tag
		}
		codec_write_u32(out, u32(len(entries)))
		for entry in entries {
			if error := codec_encode_value(out, entry.key); error != .None {
				return error
			}
			if error := codec_encode_value(out, entry.value); error != .None {
				return error
			}
		}
	case .Range:
		start, end, has_end, ok := v.value_as_range(value)
		if !ok {
			return .Bad_Tag
		}
		if error := codec_encode_value(out, start); error != .None {
			return error
		}
		codec_write_u8(out, has_end ? 1 : 0)
		if has_end {
			if error := codec_encode_value(out, end); error != .None {
				return error
			}
		}
	case .Error:
		header, ok := v.value_as_error(value)
		if !ok {
			return .Bad_Tag
		}
		if error := codec_write_symbol(out, header.code); error != .None {
			return error
		}
		codec_write_u8(out, header.has_message ? 1 : 0)
		if header.has_message {
			codec_write_string(out, header.message)
		}
		codec_write_u8(out, header.has_value ? 1 : 0)
		if header.has_value {
			if error := codec_encode_value(out, header.value); error != .None {
				return error
			}
		}
	case .Frob:
		header, ok := v.value_as_frob(value)
		if !ok {
			return .Bad_Tag
		}
		codec_write_u64(out, v.identity_raw(header.delegate))
		if error := codec_encode_value(out, header.value); error != .None {
			return error
		}
	case .Relation:
		relation, ok := v.value_as_relation(value)
		if !ok {
			return .Bad_Tag
		}
		codec_write_u32(out, u32(len(relation.heading)))
		for column in relation.heading {
			if error := codec_write_symbol(out, column); error != .None {
				return error
			}
		}
		codec_write_u32(out, u32(len(relation.rows)))
		for row in relation.rows {
			codec_write_u32(out, u32(v.tuple_arity(row)))
			for cell in v.tuple_values(row) {
				if error := codec_encode_value(out, cell); error != .None {
					return error
				}
			}
		}
	case .Capability, .Function:
		return .Not_Persistable
	case:
		return .Bad_Tag
	}
	return .None
}

@(private)
Codec_Reader :: struct {
	data:   []u8,
	cursor: int,
}

// Guards a length-prefixed allocation against a corrupt prefix: a count cannot
// exceed the bytes remaining when each element needs at least `min_bytes`.
// Without this, a bogus count drives a huge allocation before any element is
// read.
@(private)
codec_count_allowed :: proc(reader: ^Codec_Reader, count: u32, min_bytes := 1) -> bool {
	remaining := len(reader.data) - reader.cursor
	if remaining < 0 {
		return false
	}
	step := min_bytes
	if step < 1 {
		step = 1
	}
	return i64(count) * i64(step) <= i64(remaining)
}

@(private)
codec_read_u8 :: proc(reader: ^Codec_Reader) -> (u8, Codec_Error) {
	if reader.cursor + 1 > len(reader.data) {
		return 0, .Truncated
	}
	value := reader.data[reader.cursor]
	reader.cursor += 1
	return value, .None
}

@(private)
codec_read_u32 :: proc(reader: ^Codec_Reader) -> (u32, Codec_Error) {
	if reader.cursor + 4 > len(reader.data) {
		return 0, .Truncated
	}
	value := u32(reader.data[reader.cursor]) |
		u32(reader.data[reader.cursor + 1]) << 8 |
		u32(reader.data[reader.cursor + 2]) << 16 |
		u32(reader.data[reader.cursor + 3]) << 24
	reader.cursor += 4
	return value, .None
}

@(private)
codec_read_u64 :: proc(reader: ^Codec_Reader) -> (u64, Codec_Error) {
	if reader.cursor + 8 > len(reader.data) {
		return 0, .Truncated
	}
	value := u64(0)
	for index in 0 ..< 8 {
		value |= u64(reader.data[reader.cursor + index]) << (8 * u32(index))
	}
	reader.cursor += 8
	return value, .None
}

@(private)
codec_read_i64 :: proc(reader: ^Codec_Reader) -> (i64, Codec_Error) {
	raw, error := codec_read_u64(reader)
	return i64(raw), error
}

@(private)
codec_read_string :: proc(reader: ^Codec_Reader, allocator: mem.Allocator) -> (string, Codec_Error) {
	length, error := codec_read_u32(reader)
	if error != .None {
		return "", error
	}
	if reader.cursor + int(length) > len(reader.data) {
		return "", .Truncated
	}
	text := make([]u8, int(length), allocator)
	copy(text, reader.data[reader.cursor:reader.cursor + int(length)])
	reader.cursor += int(length)
	return transmute(string)text, .None
}

// Decodes one value starting at `cursor`, advancing it. Allocations use
// `allocator`.
codec_decode_value :: proc(
	data: []u8,
	cursor: ^int,
	allocator: mem.Allocator,
) -> (
	v.Value,
	Codec_Error,
) {
	reader := Codec_Reader{data = data, cursor = cursor^}
	value, error := codec_decode_value_reader(&reader, allocator)
	cursor^ = reader.cursor
	return value, error
}

@(private)
codec_decode_value_reader :: proc(
	reader: ^Codec_Reader,
	allocator: mem.Allocator,
) -> (
	v.Value,
	Codec_Error,
) {
	kind_byte, error := codec_read_u8(reader)
	if error != .None {
		return v.Value(0), error
	}
	#partial switch v.Value_Kind(kind_byte) {
	case .Bool:
		raw, raw_error := codec_read_u8(reader)
		if raw_error != .None {
			return v.Value(0), raw_error
		}
		return v.value_bool(raw != 0), .None
	case .Int:
		number, number_error := codec_read_i64(reader)
		if number_error != .None {
			return v.Value(0), number_error
		}
		result, ok := v.value_int(number)
		if !ok {
			return v.Value(0), .Bad_Tag
		}
		return result, .None
	case .Float:
		bits, bits_error := codec_read_u32(reader)
		if bits_error != .None {
			return v.Value(0), bits_error
		}
		result, ok := v.value_float_from_bits(bits)
		if !ok {
			return v.Value(0), .Bad_Tag
		}
		return result, .None
	case .Identity:
		raw, raw_error := codec_read_u64(reader)
		if raw_error != .None {
			return v.Value(0), raw_error
		}
		result, ok := v.value_identity_raw(raw)
		if !ok {
			return v.Value(0), .Bad_Tag
		}
		return result, .None
	case .Symbol:
		name, name_error := codec_read_string(reader, allocator)
		if name_error != .None {
			return v.Value(0), name_error
		}
		return v.value_symbol(v.symbol_intern(name)), .None
	case .Error_Code:
		name, name_error := codec_read_string(reader, allocator)
		if name_error != .None {
			return v.Value(0), name_error
		}
		return v.value_error_code(v.symbol_intern(name)), .None
	case .String:
		text, text_error := codec_read_string(reader, allocator)
		if text_error != .None {
			return v.Value(0), text_error
		}
		return v.value_string(allocator, text), .None
	case .Bytes:
		length, length_error := codec_read_u32(reader)
		if length_error != .None {
			return v.Value(0), length_error
		}
		if reader.cursor + int(length) > len(reader.data) {
			return v.Value(0), .Truncated
		}
		data := make([]u8, int(length), allocator)
		copy(data, reader.data[reader.cursor:reader.cursor + int(length)])
		reader.cursor += int(length)
		return v.value_bytes(allocator, data), .None
	case .List:
		count, count_error := codec_read_u32(reader)
		if count_error != .None {
			return v.Value(0), count_error
		}
		if !codec_count_allowed(reader, count) {
			return v.Value(0), .Truncated
		}
		values := make([]v.Value, int(count), allocator)
		for index in 0 ..< int(count) {
			item, item_error := codec_decode_value_reader(reader, allocator)
			if item_error != .None {
				return v.Value(0), item_error
			}
			values[index] = item
		}
		return v.value_list(allocator, values), .None
	case .Map:
		count, count_error := codec_read_u32(reader)
		if count_error != .None {
			return v.Value(0), count_error
		}
		if !codec_count_allowed(reader, count) {
			return v.Value(0), .Truncated
		}
		entries := make([]v.Map_Entry, int(count), allocator)
		for index in 0 ..< int(count) {
			key, key_error := codec_decode_value_reader(reader, allocator)
			if key_error != .None {
				return v.Value(0), key_error
			}
			value, value_error := codec_decode_value_reader(reader, allocator)
			if value_error != .None {
				return v.Value(0), value_error
			}
			entries[index] = v.Map_Entry{key = key, value = value}
		}
		return v.value_map(allocator, entries), .None
	case .Range:
		start, start_error := codec_decode_value_reader(reader, allocator)
		if start_error != .None {
			return v.Value(0), start_error
		}
		has_end, has_end_error := codec_read_u8(reader)
		if has_end_error != .None {
			return v.Value(0), has_end_error
		}
		end := v.Value(0)
		if has_end != 0 {
			decoded, end_error := codec_decode_value_reader(reader, allocator)
			if end_error != .None {
				return v.Value(0), end_error
			}
			end = decoded
		}
		return v.value_range(allocator, start, end, has_end != 0), .None
	case .Error:
		code, code_error := codec_read_string(reader, allocator)
		if code_error != .None {
			return v.Value(0), code_error
		}
		has_message, has_message_error := codec_read_u8(reader)
		if has_message_error != .None {
			return v.Value(0), has_message_error
		}
		message := ""
		if has_message != 0 {
			decoded, message_error := codec_read_string(reader, allocator)
			if message_error != .None {
				return v.Value(0), message_error
			}
			message = decoded
		}
		has_value, has_value_error := codec_read_u8(reader)
		if has_value_error != .None {
			return v.Value(0), has_value_error
		}
		payload := v.Value(0)
		if has_value != 0 {
			decoded, value_error := codec_decode_value_reader(reader, allocator)
			if value_error != .None {
				return v.Value(0), value_error
			}
			payload = decoded
		}
		return v.value_error(
			allocator,
			v.symbol_intern(code),
			message,
			has_message != 0,
			payload,
			has_value != 0,
		), .None
	case .Frob:
		raw, raw_error := codec_read_u64(reader)
		if raw_error != .None {
			return v.Value(0), raw_error
		}
		inner, inner_error := codec_decode_value_reader(reader, allocator)
		if inner_error != .None {
			return v.Value(0), inner_error
		}
		return v.value_frob(allocator, v.Identity(raw), inner), .None
	case .Relation:
		heading_count, heading_error := codec_read_u32(reader)
		if heading_error != .None {
			return v.Value(0), heading_error
		}
		if !codec_count_allowed(reader, heading_count, 4) {
			return v.Value(0), .Truncated
		}
		heading := make([]v.Symbol, int(heading_count), allocator)
		for index in 0 ..< int(heading_count) {
			name, name_error := codec_read_string(reader, allocator)
			if name_error != .None {
				return v.Value(0), name_error
			}
			heading[index] = v.symbol_intern(name)
		}
		row_count, row_error := codec_read_u32(reader)
		if row_error != .None {
			return v.Value(0), row_error
		}
		if !codec_count_allowed(reader, row_count, 4) {
			return v.Value(0), .Truncated
		}
		rows := make([]v.Tuple, int(row_count), allocator)
		for row_index in 0 ..< int(row_count) {
			cell_count, cell_error := codec_read_u32(reader)
			if cell_error != .None {
				return v.Value(0), cell_error
			}
			if !codec_count_allowed(reader, cell_count) {
				return v.Value(0), .Truncated
			}
			cells := make([]v.Value, int(cell_count), allocator)
			for cell_index in 0 ..< int(cell_count) {
				cell, value_error := codec_decode_value_reader(reader, allocator)
				if value_error != .None {
					return v.Value(0), value_error
				}
				cells[cell_index] = cell
			}
			rows[row_index] = v.tuple_from_slice(cells)
		}
		relation, relation_error := v.value_relation(allocator, heading, rows)
		if relation_error != .None {
			return v.Value(0), .Bad_Tag
		}
		return relation, .None
	case:
		return v.Value(0), .Bad_Tag
	}
}

// Encodes a tuple as a length-prefixed cell list.
codec_encode_tuple :: proc(out: ^[dynamic]u8, tuple: v.Tuple) -> Codec_Error {
	cells := v.tuple_values(tuple)
	codec_write_u32(out, u32(len(cells)))
	for cell in cells {
		if error := codec_encode_value(out, cell); error != .None {
			return error
		}
	}
	return .None
}

// Decodes a tuple written by `codec_encode_tuple`.
codec_decode_tuple :: proc(
	data: []u8,
	cursor: ^int,
	allocator: mem.Allocator,
) -> (
	v.Tuple,
	Codec_Error,
) {
	reader := Codec_Reader{data = data, cursor = cursor^}
	count, error := codec_read_u32(&reader)
	if error != .None {
		cursor^ = reader.cursor
		return nil, error
	}
	if !codec_count_allowed(&reader, count) {
		cursor^ = reader.cursor
		return nil, .Truncated
	}
	cells := make([]v.Value, int(count), allocator)
	for index in 0 ..< int(count) {
		cell, cell_error := codec_decode_value_reader(&reader, allocator)
		if cell_error != .None {
			cursor^ = reader.cursor
			return nil, cell_error
		}
		cells[index] = cell
	}
	cursor^ = reader.cursor
	return v.tuple_from_slice(cells), .None
}
