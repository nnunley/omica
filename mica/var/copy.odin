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
		copied := make([]Value, len(values), alloc)
		for item, i in values {
			copied[i] = value_deep_copy(alloc, item)
		}
		return value_list(alloc, copied)
	case .Map:
		entries, _ := value_as_map(value)
		copied := make([]Map_Entry, len(entries), alloc)
		for entry, i in entries {
			copied[i] = Map_Entry {
				key   = value_deep_copy(alloc, entry.key),
				value = value_deep_copy(alloc, entry.value),
			}
		}
		return value_map(alloc, copied)
	case .Relation:
		relation, _ := value_as_relation(value)
		rows := make([]Tuple, len(relation.rows), alloc)
		for row, i in relation.rows {
			rows[i] = tuple_deep_copy(alloc, row)
		}
		copied, _ := value_relation(alloc, relation.heading, rows)
		return copied
	case .Range:
		start, end, has_end, _ := value_as_range(value)
		return value_range(alloc, value_deep_copy(alloc, start), value_deep_copy(alloc, end), has_end)
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
