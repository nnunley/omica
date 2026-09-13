// Heap-backed immutable values.
//
// Strings, bytes, lists, maps, ranges, errors, frobs, and relation values are
// allocated in an arena. The `Value` payload points at the header struct;
// payload data follows in separate arena allocations. Heap values are never
// mutated after construction and never freed individually; the owning arena
// reclaims them.
package var

import "core:mem"
import "core:slice"

// An immutable string value.
//
// `data` may have capacity beyond its length. That spare room is only valid
// for an append that is performed through `value_string_append`, which owns
// the buffer: any other holder of the same `Value` must not observe the
// appended bytes. `spare_owner` is a monotonically increasing token that
// records which append created the spare room, so an older copy of the value
// cannot reuse it after a newer append has claimed it.
Heap_String :: struct {
	data:        []u8,
	// Bytes allocated for `data`; `len(data)` may be smaller when the string
	// was produced by `value_string_append`, which reserves headroom.
	allocated:   int,
	spare_owner: u64,
}

// An immutable byte-string value.
Heap_Bytes :: struct {
	data: []u8,
}

// An immutable list value.
Heap_List :: struct {
	values: []Value,
}

// A canonicalized map entry.
Map_Entry :: struct {
	key:   Value,
	value: Value,
}

// An immutable map value with entries sorted by key.
Heap_Map :: struct {
	entries: []Map_Entry,
}

// An immutable half-open range value.
Heap_Range :: struct {
	start:   Value,
	has_end: bool,
	end:     Value,
}

// An immutable error value.
Heap_Error :: struct {
	code:        Symbol,
	message:     string,
	has_message: bool,
	value:       Value,
	has_value:   bool,
}

// An immutable frob: a delegated wrapper around another value.
Heap_Frob :: struct {
	delegate: Identity,
	value:    Value,
}

// An immutable finite relation value with a canonical named heading.
Relation_Value :: struct {
	heading: []Symbol,
	rows:    []Tuple,
}

// Errors from constructing a relation value.
Relation_Value_Error :: enum {
	None,
	Heading_Too_Wide,
	Duplicate_Column,
	Arity_Mismatch,
}

@(private)
empty_relation_value: Relation_Value

@(private)
value_heap :: proc(tag: Tag, ptr: rawptr) -> Value {
	p := u64(uintptr(ptr))
	assert(p != 0 && p <= PAYLOAD_MASK, "heap pointer escaped the value payload")
	return value_pack(tag, p)
}

@(private)
heap_header :: proc(v: Value, tag: Tag, $T: typeid) -> (^T, bool) {
	if value_tag(v) != tag {
		return nil, false
	}
	return (^T)(rawptr(uintptr(value_payload(v)))), true
}

@(private)
bytes_to_string :: proc(data: []u8) -> string {
	return transmute(string)data
}

// --- Constructors ----------------------------------------------------------

// Creates a string value by copying `s` into `alloc`.
value_string :: proc(alloc: mem.Allocator, s: string) -> Value {
	data := make([]u8, len(s), alloc)
	copy(data, transmute([]u8)s)
	header := new(Heap_String, alloc)
	header.data = data
	return value_heap(.String, header)
}

// A token handed out per append that creates spare capacity. Only the header
// holding the newest token may extend the buffer's tail; every append hands the
// token to its result and clears it on the base.
@(private)
string_spare_counter: u64

// Creates a string value taking ownership of `data` without copying. `data`
// must have come from `alloc` and must not be used or freed by the caller
// afterwards. The header itself is still allocated.
value_string_owned :: proc(alloc: mem.Allocator, data: []u8) -> Value {
	header := new(Heap_String, alloc)
	header.data = data
	header.allocated = len(data)
	return value_heap(.String, header)
}

// Appends `text` to `base`, returning the resulting string. When `base` owns
// the tail of a buffer with room, the append writes past its own length; the
// base's header loses the tail token and the result gains it. Otherwise a
// fresh buffer with headroom is allocated and the base is copied in. Either
// way the result carries spare capacity, so growing a string one piece at a
// time is linear rather than O(n^2).
//
// Soundness: a string value observes only `data[0..len]`. The bytes past the
// base's length are invisible through every existing value, and only the token
// holder may write there, so an append can never change what another value
// reads.
value_string_append :: proc(alloc: mem.Allocator, base: Value, text: string) -> Value {
	header, is_string := heap_header(base, .String, Heap_String)
	if is_string && header.data != nil && header.spare_owner != 0 {
		required := len(header.data) + len(text)
		if required <= header.allocated {
			// Rebuild the full allocation view from the pointer; the header's
			// own `data` only exposes the visible prefix.
			full := ([^]u8)(raw_data(header.data))[:header.allocated]
			copy(full[len(header.data):], transmute([]u8)text)
			// The base is no longer the tail owner; the result is.
			header.spare_owner = 0
			value := value_string_owned(alloc, full[:required])
			result, _ := heap_header(value, .String, Heap_String)
			result.allocated = header.allocated
			string_spare_counter += 1
			result.spare_owner = string_spare_counter
			return value
		}
	}
	required := len(text)
	if is_string {
		required += len(header.data)
	}
	capacity := required * 2
	if capacity < 16 {
		capacity = 16
	}
	buffer := make([]u8, capacity, alloc)
	write := 0
	if is_string {
		copy(buffer, header.data)
		write = len(header.data)
	}
	copy(buffer[write:], transmute([]u8)text)
	value := value_string_owned(alloc, buffer[:required])
	result, _ := heap_header(value, .String, Heap_String)
	result.allocated = capacity
	string_spare_counter += 1
	result.spare_owner = string_spare_counter
	return value
}

// Creates a byte-string value by copying `data` into `alloc`.
value_bytes :: proc(alloc: mem.Allocator, data: []u8) -> Value {
	owned := make([]u8, len(data), alloc)
	copy(owned, data)
	header := new(Heap_Bytes, alloc)
	header.data = owned
	return value_heap(.Bytes, header)
}

// Creates a list value by copying `values` into `alloc`.
value_list :: proc(alloc: mem.Allocator, values: []Value) -> Value {
	owned := make([]Value, len(values), alloc)
	copy(owned, values)
	header := new(Heap_List, alloc)
	header.values = owned
	return value_heap(.List, header)
}

// Creates a map value from `entries`, sorting by key and keeping the last
// value for duplicate keys.
value_map :: proc(alloc: mem.Allocator, entries: []Map_Entry) -> Value {
	owned := make([]Map_Entry, len(entries), alloc)
	copy(owned, entries)
	slice.stable_sort_by(owned, proc(a, b: Map_Entry) -> bool {
		return value_cmp(a.key, b.key) == .Less
	})

	write := 0
	for entry in owned {
		if write > 0 && value_eq(owned[write - 1].key, entry.key) {
			owned[write - 1].value = entry.value
			continue
		}
		owned[write] = entry
		write += 1
	}

	header := new(Heap_Map, alloc)
	header.entries = owned[:write]
	return value_heap(.Map, header)
}

@(private)
Heading_Sort_Entry :: struct {
	symbol: Symbol,
	index:  u16,
}

// Creates a relation value with a canonical heading and row set. Fails on
// duplicate columns or row arity mismatches.
value_relation :: proc(
	alloc: mem.Allocator,
	heading: []Symbol,
	rows: []Tuple,
) -> (
	Value,
	Relation_Value_Error,
) {
	if len(heading) > int(max(u16)) {
		return Value(0), .Heading_Too_Wide
	}

	order := make([]Heading_Sort_Entry, len(heading), context.temp_allocator)
	for i in 0 ..< len(order) {
		order[i] = Heading_Sort_Entry{symbol = heading[i], index = u16(i)}
	}
	slice.sort_by(order, proc(a, b: Heading_Sort_Entry) -> bool {
		return symbol_id(a.symbol) < symbol_id(b.symbol)
	})
	for i in 1 ..< len(order) {
		if order[i - 1].symbol == order[i].symbol {
			return Value(0), .Duplicate_Column
		}
	}

	already_ordered := true
	for entry, i in order {
		if int(entry.index) != i {
			already_ordered = false
			break
		}
	}

	positions := make([]u16, len(order), context.temp_allocator)
	canonical_heading := make([]Symbol, len(heading), alloc)
	for entry, i in order {
		positions[i] = entry.index
		canonical_heading[i] = entry.symbol
	}

	canonical_rows := make([]Tuple, len(rows), alloc)
	rows_ordered := true
	for row, i in rows {
		if tuple_arity(row) != len(heading) {
			return Value(0), .Arity_Mismatch
		}
		canonical := row
		if !already_ordered {
			canonical = tuple_select(row, alloc, positions)
		}
		if rows_ordered && i > 0 && tuple_cmp(canonical_rows[i - 1], canonical) != .Less {
			rows_ordered = false
		}
		canonical_rows[i] = canonical
	}

	if !rows_ordered {
		slice.sort_by(canonical_rows, proc(a, b: Tuple) -> bool {
			return tuple_cmp(a, b) == .Less
		})
		unique := make([]Tuple, len(canonical_rows), alloc)
		write := 0
		for row in canonical_rows {
			if write > 0 && tuple_cmp(unique[write - 1], row) == .Equal {
				continue
			}
			unique[write] = row
			write += 1
		}
		canonical_rows = unique[:write]
	}

	header := new(Relation_Value, alloc)
	header.heading = canonical_heading
	header.rows = canonical_rows
	if len(canonical_heading) == 0 && len(canonical_rows) == 0 {
		return value_empty_relation(), .None
	}
	return value_heap(.Relation, header), .None
}

// Creates a range value. When `has_end` is false the range is open-ended.
value_range :: proc(alloc: mem.Allocator, start: Value, end: Value, has_end: bool) -> Value {
	header := new(Heap_Range, alloc)
	header.start = start
	header.has_end = has_end
	header.end = end
	return value_heap(.Range, header)
}

// Creates an error value.
value_error :: proc(
	alloc: mem.Allocator,
	code: Symbol,
	message: string,
	has_message: bool,
	value: Value,
	has_value: bool,
) -> Value {
	header := new(Heap_Error, alloc)
	header.code = code
	header.has_message = has_message
	header.message = has_message ? message : ""
	header.has_value = has_value
	header.value = has_value ? value : Value(0)
	return value_heap(.Error, header)
}

// Creates a frob delegating `inner` to `delegate`.
value_frob :: proc(alloc: mem.Allocator, delegate: Identity, inner: Value) -> Value {
	header := new(Heap_Frob, alloc)
	header.delegate = delegate
	header.value = inner
	return value_heap(.Frob, header)
}

// --- Accessors -------------------------------------------------------------

// Returns the string payload, if this is a string.
value_as_string :: proc(v: Value) -> (string, bool) {
	header, ok := heap_header(v, .String, Heap_String)
	if !ok {
		return "", false
	}
	return bytes_to_string(header.data), true
}

// Returns the byte-string payload, if this is a byte string.
value_as_bytes :: proc(v: Value) -> ([]u8, bool) {
	header, ok := heap_header(v, .Bytes, Heap_Bytes)
	if !ok {
		return nil, false
	}
	return header.data, true
}

// Returns the list payload, if this is a list.
value_as_list :: proc(v: Value) -> ([]Value, bool) {
	header, ok := heap_header(v, .List, Heap_List)
	if !ok {
		return nil, false
	}
	return header.values, true
}

// Returns the map entries, if this is a map.
value_as_map :: proc(v: Value) -> ([]Map_Entry, bool) {
	header, ok := heap_header(v, .Map, Heap_Map)
	if !ok {
		return nil, false
	}
	return header.entries, true
}

// Returns the relation value, if this is a relation value.
value_as_relation :: proc(v: Value) -> (^Relation_Value, bool) {
	if value_is_empty_relation(v) {
		return &empty_relation_value, true
	}
	return heap_header(v, .Relation, Relation_Value)
}

// Returns the range payload, if this is a range.
value_as_range :: proc(v: Value) -> (start: Value, end: Value, has_end: bool, ok: bool) {
	header, header_ok := heap_header(v, .Range, Heap_Range)
	if !header_ok {
		return Value(0), Value(0), false, false
	}
	return header.start, header.end, header.has_end, true
}

// Returns the error payload, if this is an error value.
value_as_error :: proc(v: Value) -> (^Heap_Error, bool) {
	return heap_header(v, .Error, Heap_Error)
}

// Returns the frob payload, if this is a frob.
value_as_frob :: proc(v: Value) -> (^Heap_Frob, bool) {
	return heap_header(v, .Frob, Heap_Frob)
}

// Returns the frob delegate, if this is a frob.
value_frob_delegate :: proc(v: Value) -> (Identity, bool) {
	header, ok := value_as_frob(v)
	if !ok {
		return Identity(0), false
	}
	return header.delegate, true
}

// Returns the frob payload value, if this is a frob.
value_frob_value :: proc(v: Value) -> (Value, bool) {
	header, ok := value_as_frob(v)
	if !ok {
		return Value(0), false
	}
	return header.value, true
}

// Returns the error code for an error code or error value.
value_error_code_symbol :: proc(v: Value) -> (Symbol, bool) {
	if code, ok := value_as_error_code(v); ok {
		return code, true
	}
	if error, ok := value_as_error(v); ok {
		return error.code, true
	}
	return Symbol(0), false
}

// Reports whether a value can be persisted in a durable relation store.
// Capabilities and function designations never persist; heap values are
// checked recursively.
value_is_persistable :: proc(v: Value) -> bool {
	return value_ephemeral_ok(v, false)
}

// Reports whether a value can live in an in-memory relation tuple. This is
// weaker than persistence: capabilities are ephemeral handles that may be
// stored in a live world but have no codec.
value_is_storable :: proc(v: Value) -> bool {
	return value_ephemeral_ok(v, true)
}

@(private)
value_ephemeral_ok :: proc(v: Value, allow_capabilities: bool) -> bool {
	#partial switch value_kind(v) {
	case .Capability:
		return allow_capabilities
	case .Function:
		return false
	case .List:
		values, ok := value_as_list(v)
		if !ok {
			return false
		}
		for item in values {
			if !value_ephemeral_ok(item, allow_capabilities) {
				return false
			}
		}
		return true
	case .Map:
		entries, ok := value_as_map(v)
		if !ok {
			return false
		}
		for entry in entries {
			if !value_ephemeral_ok(entry.key, allow_capabilities) ||
			   !value_ephemeral_ok(entry.value, allow_capabilities) {
				return false
			}
		}
		return true
	case .Range:
		start, end, has_end, ok := value_as_range(v)
		if !ok {
			return false
		}
		return value_ephemeral_ok(start, allow_capabilities) &&
			(!has_end || value_ephemeral_ok(end, allow_capabilities))
	case .Error:
		header, ok := value_as_error(v)
		if !ok {
			return false
		}
		return !header.has_value || value_ephemeral_ok(header.value, allow_capabilities)
	case .Frob:
		header, ok := value_as_frob(v)
		if !ok {
			return false
		}
		return value_ephemeral_ok(header.value, allow_capabilities)
	case .Relation:
		relation, ok := value_as_relation(v)
		if !ok {
			return false
		}
		for row in relation.rows {
			for cell in tuple_values(row) {
				if !value_ephemeral_ok(cell, allow_capabilities) {
					return false
				}
			}
		}
		return true
	case:
		return true
	}
}
