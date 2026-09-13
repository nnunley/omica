// Deep copying of values into a destination allocator.
//
// Values are normally shared between snapshots and transactions: a value's
// arena outlives every reference to it along the commit chain. When a value
// crosses an ownership boundary, for example from caller scratch memory into a
// transaction arena, it must be deep-copied so the destination owns all of its
// storage.
package var

import "core:mem"
import "core:strings"

// Copies a value and all heap storage it references into `alloc`. Immediate
// values are returned unchanged.
value_deep_copy :: proc(alloc: mem.Allocator, value: Value) -> Value {
	if value_is_immediate(value) {
		return value
	}
	#partial switch value_kind(value) {
	case .String:
		text, _ := value_as_string(value)
		return value_string(alloc, text)
	case .Bytes:
		data, _ := value_as_bytes(value)
		return value_bytes(alloc, data)
	case .List:
		values, _ := value_as_list(value)
		scratch := make([]Value, len(values), alloc)
		for item, i in values {
			scratch[i] = value_deep_copy(alloc, item)
		}
		// `value_list` copies its input, so free the scratch array afterwards.
		result := value_list(alloc, scratch)
		delete(scratch, alloc)
		return result
	case .Map:
		entries, _ := value_as_map(value)
		scratch := make([]Map_Entry, len(entries), alloc)
		for entry, i in entries {
			scratch[i] = Map_Entry {
				key   = value_deep_copy(alloc, entry.key),
				value = value_deep_copy(alloc, entry.value),
			}
		}
		result := value_map(alloc, scratch)
		delete(scratch, alloc)
		return result
	case .Relation:
		relation, _ := value_as_relation(value)
		scratch := make([]Tuple, len(relation.rows), alloc)
		for row, i in relation.rows {
			scratch[i] = tuple_deep_copy(alloc, row)
		}
		// `value_relation` copies its heading and rows; free the scratch array.
		copied, _ := value_relation(alloc, relation.heading, scratch)
		delete(scratch, alloc)
		return copied
	case .Range:
		start, end, has_end, _ := value_as_range(value)
		return value_range(
			alloc,
			value_deep_copy(alloc, start),
			value_deep_copy(alloc, end),
			has_end,
		)
	case .Error:
		error, _ := value_as_error(value)
		message := error.message
		if error.has_message {
			message = strings.clone(error.message, alloc)
		}
		return value_error(
			alloc,
			error.code,
			message,
			error.has_message,
			value_deep_copy(alloc, error.value),
			error.has_value,
		)
	case .Frob:
		frob, _ := value_as_frob(value)
		return value_frob(alloc, frob.delegate, value_deep_copy(alloc, frob.value))
	case:
		return value
	}
}

// Copies a tuple and all heap storage it references into `alloc`.
tuple_deep_copy :: proc(alloc: mem.Allocator, tuple: Tuple) -> Tuple {
	values := tuple_values(tuple)
	copied := make([]Value, len(values), alloc)
	for value, i in values {
		copied[i] = value_deep_copy(alloc, value)
	}
	return Tuple(copied)
}

// Frees a value created by `value_deep_copy`, including heap headers.
value_deep_free :: proc(alloc: mem.Allocator, value: Value) {
	if value_is_immediate(value) || value_is_empty_relation(value) {
		return
	}
	#partial switch value_kind(value) {
	case .String:
		if header, ok := heap_header(value, .String, Heap_String); ok {
			if header.data != nil {
				// Free the full allocation, not just the visible prefix; an
				// appended string may have reserved headroom.
				full := ([^]u8)(raw_data(header.data))[:header.allocated]
				delete(full, alloc)
			}
			free(header, alloc)
		}
	case .Bytes:
		if header, ok := heap_header(value, .Bytes, Heap_Bytes); ok {
			delete(header.data, alloc)
			free(header, alloc)
		}
	case .List:
		if header, ok := heap_header(value, .List, Heap_List); ok {
			for item in header.values {
				value_deep_free(alloc, item)
			}
			delete(header.values, alloc)
			free(header, alloc)
		}
	case .Map:
		if header, ok := heap_header(value, .Map, Heap_Map); ok {
			for entry in header.entries {
				value_deep_free(alloc, entry.key)
				value_deep_free(alloc, entry.value)
			}
			delete(header.entries, alloc)
			free(header, alloc)
		}
	case .Range:
		if header, ok := heap_header(value, .Range, Heap_Range); ok {
			value_deep_free(alloc, header.start)
			if header.has_end {
				value_deep_free(alloc, header.end)
			}
			free(header, alloc)
		}
	case .Error:
		if header, ok := heap_header(value, .Error, Heap_Error); ok {
			if header.has_message {
				delete(header.message, alloc)
			}
			if header.has_value {
				value_deep_free(alloc, header.value)
			}
			free(header, alloc)
		}
	case .Frob:
		if header, ok := heap_header(value, .Frob, Heap_Frob); ok {
			value_deep_free(alloc, header.value)
			free(header, alloc)
		}
	case .Relation:
		if header, ok := heap_header(value, .Relation, Relation_Value); ok {
			for row in header.rows {
				cells := tuple_values(row)
				for cell in cells {
					value_deep_free(alloc, cell)
				}
				delete(cells, alloc)
			}
			delete(header.rows, alloc)
			delete(header.heading, alloc)
			free(header, alloc)
		}
	}
}
