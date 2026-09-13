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
import "core:unicode/utf8"

// An immutable string value.
//
// `data` may have capacity beyond its length. That spare room is only valid
// for an append that is performed through `value_string_append`, which owns
// the buffer: any other holder of the same `Value` must not observe the
// appended bytes. `spare_owner` is a monotonically increasing token that
// records which append created the spare room, so an older copy of the value
// cannot reuse it after a newer append has claimed it.
//
// Strings are UTF-8. Their characters are Unicode scalar values, but UTF-8 is
// variable-width, so mapping a scalar position to a byte offset is a scan.
// `ascii` records that every byte is < 0x80, which makes the scalar count equal
// the byte count and every scalar position equal a byte offset. For long
// non-ASCII strings, `index` is a sampled offset table that bounds the scan to
// `STRING_INDEX_STRIDE` scalars; it is built once at construction and never
// mutated.
Heap_String :: struct {
	data:        []u8,
	// Bytes allocated for `data`; `len(data)` may be smaller when the string
	// was produced by `value_string_append`, which reserves headroom.
	allocated:   int,
	spare_owner: u64,
	ascii:       bool,
	index:       ^String_Index,
}

// Scalar positions between two samples. A sampled offset makes scalar lookup
// O(stride) instead of O(n); the memory cost is four bytes per stride scalars
// (about 12.5% for ASCII-sized scalars, far less than a full offset table).
STRING_INDEX_STRIDE :: 32

// A sampled scalar-offset table for a non-ASCII string. `offsets[k]` is the
// byte offset of scalar `k * STRING_INDEX_STRIDE`; `count` is the total scalar
// count.
String_Index :: struct {
	offsets: []u32,
	count:   int,
}

// An immutable byte-string value.
Heap_Bytes :: struct {
	data: []u8,
}

// An immutable list value.
//
// `values` may have capacity beyond its length. That spare room is only valid
// for an append performed through `value_list_append`, which owns the buffer:
// any other holder of the same `Value` observes only `values[0..len]`.
// `spare_owner` records which append last created the spare room, so an older
// copy cannot reuse a tail a newer append has claimed.
Heap_List :: struct {
	values:      []Value,
	allocated:   int,
	spare_owner: u64,
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

// --- String scalar scanning ------------------------------------------------

// Counts the Unicode scalar values in UTF-8 `data`. Invalid bytes (including
// stray continuation bytes) count as one scalar each, matching the tolerant
// decoding used everywhere else; see `string_scalar_count`.
string_scalar_count_bytes :: proc(data: []u8) -> int {
	count := 0
	for offset := 0; offset < len(data); {
		_, size := utf8.decode_rune_in_bytes(data[offset:])
		if size <= 0 {
			size = 1
		}
		offset += size
		count += 1
	}
	return count
}

// Reports whether every byte is ASCII, which makes scalar positions equal byte
// offsets.
string_is_ascii :: proc(data: []u8) -> bool {
	for byte in data {
		if byte >= 0x80 {
			return false
		}
	}
	return true
}

// Builds a sampled offset table for `data`, which must be non-ASCII and longer
// than the index threshold. Sampling is on scalar positions, so `offsets[k]`
// is the byte offset of scalar `k * STRING_INDEX_STRIDE`.
string_index_build :: proc(alloc: mem.Allocator, data: []u8) -> ^String_Index {
	count := string_scalar_count_bytes(data)
	sample_count := (count + STRING_INDEX_STRIDE) / STRING_INDEX_STRIDE
	offsets := make([]u32, sample_count, alloc)
	scalar := 0
	sample := 0
	for offset := 0; offset < len(data); {
		if scalar % STRING_INDEX_STRIDE == 0 {
			offsets[sample] = u32(offset)
			sample += 1
		}
		_, size := utf8.decode_rune_in_bytes(data[offset:])
		if size <= 0 {
			size = 1
		}
		offset += size
		scalar += 1
	}
	index := new(String_Index, alloc)
	index.offsets = offsets
	index.count = count
	// When the scalar count is an exact multiple of the stride, the loop stops
	// before recording the end offset. Write it so a position equal to the
	// count resolves to the end of the string rather than to sample zero.
	if sample < sample_count {
		offsets[sample] = u32(len(data))
	}
	return index
}

// Initializes the string descriptor for `data`. `ascii` is computed from the
// bytes; a non-ASCII string longer than `STRING_INDEX_MIN` gets a sampled
// offset table. The table is built once here, so no operation mutates the
// header afterwards.
@(private)
string_describe :: proc(alloc: mem.Allocator, header: ^Heap_String) {
	header.ascii = string_is_ascii(header.data)
	if !header.ascii && len(header.data) >= STRING_INDEX_MIN {
		header.index = string_index_build(alloc, header.data)
	}
}

// Non-ASCII strings shorter than this scan instead of carrying an offset table:
// four bytes per 32 scalars is not worth it below this size, and a bounded scan
// is cheap.
STRING_INDEX_MIN :: 128

// Returns the number of Unicode scalar values in a string.
string_scalar_count :: proc(v: Value) -> (int, bool) {
	header, ok := heap_header(v, .String, Heap_String)
	if !ok {
		return 0, false
	}
	if header.ascii {
		return len(header.data), true
	}
	if header.index != nil {
		return header.index.count, true
	}
	return string_scalar_count_bytes(header.data), true
}

// Returns the byte offset of scalar position `position`, which must satisfy
// `0 <= position <= scalar_count`. ASCII strings map positions directly; an
// indexed string walks at most one stride from the nearest sample.
string_byte_offset :: proc(v: Value, position: int) -> (int, bool) {
	header, ok := heap_header(v, .String, Heap_String)
	if !ok {
		return 0, false
	}
	if header.ascii {
		return position, true
	}
	if header.index != nil {
		count := header.index.count
		if position < 0 || position > count {
			return 0, false
		}
		sample := position / STRING_INDEX_STRIDE
		offset := int(header.index.offsets[sample])
		scalar := sample * STRING_INDEX_STRIDE
		for scalar < position {
			_, size := utf8.decode_rune_in_bytes(header.data[offset:])
			if size <= 0 {
				size = 1
			}
			offset += size
			scalar += 1
		}
		return offset, true
	}
	// No index: scan from the start. Bounded by STRING_INDEX_MIN for strings
	// that were not indexed at construction.
	count := 0
	for offset := 0; offset < len(header.data); {
		if count == position {
			return offset, true
		}
		_, size := utf8.decode_rune_in_bytes(header.data[offset:])
		if size <= 0 {
			size = 1
		}
		offset += size
		count += 1
	}
	if count == position {
		return len(header.data), true
	}
	return 0, false
}

// Returns the Unicode scalar value at scalar position `position`.
string_scalar_at :: proc(v: Value, position: int) -> (rune, bool) {
	header, ok := heap_header(v, .String, Heap_String)
	if !ok {
		return 0, false
	}
	if header.ascii {
		if position < 0 || position >= len(header.data) {
			return 0, false
		}
		return rune(header.data[position]), true
	}
	offset, found := string_byte_offset(v, position)
	if !found {
		return 0, false
	}
	if offset >= len(header.data) {
		return 0, false
	}
	scalar, size := utf8.decode_rune_in_bytes(header.data[offset:])
	if size <= 0 {
		return 0, false
	}
	return scalar, true
}

// Converts a scalar range to a byte range. Both positions must be valid
// boundaries, so the resulting byte range never splits a scalar.
string_byte_range :: proc(v: Value, start, end: int) -> (int, int, bool) {
	byte_start, start_ok := string_byte_offset(v, start)
	if !start_ok {
		return 0, 0, false
	}
	byte_end, end_ok := string_byte_offset(v, end)
	if !end_ok {
		return 0, 0, false
	}
	return byte_start, byte_end, true
}

// --- Constructors ----------------------------------------------------------

// Creates a string value by copying `s` into `alloc`.
value_string :: proc(alloc: mem.Allocator, s: string) -> Value {
	data := make([]u8, len(s), alloc)
	copy(data, transmute([]u8)s)
	header := new(Heap_String, alloc)
	header.data = data
	string_describe(alloc, header)
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
//
// `desc` selects whether the ASCII flag and sampled index are computed for the
// owned bytes. A builder that has already counted (append) passes false and
// transfers the counts; a caller that hands over arbitrary bytes (concat,
// join, codec) passes true. An undescribed value is never left observable: the
// append path fills the counts before returning.
value_string_owned :: proc(alloc: mem.Allocator, data: []u8, desc := true) -> Value {
	header := new(Heap_String, alloc)
	header.data = data
	header.allocated = len(data)
	if desc {
		string_describe(alloc, header)
	}
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
//
// The ASCII flag and scalar count are carried across, so a grow loop does not
// rescan the prefix. The sampled index is not carried: maintaining it across
// appends would mean rebuilding it per append, so an append result scans (it
// is bounded by the index threshold, and the compiler's indexed strings come
// from a single construction, not from repeated appends).
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
			value := value_string_owned(alloc, full[:required], false)
			result, _ := heap_header(value, .String, Heap_String)
			result.allocated = header.allocated
			result.ascii = header.ascii && string_is_ascii(transmute([]u8)text)
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
	value := value_string_owned(alloc, buffer[:required], false)
	result, _ := heap_header(value, .String, Heap_String)
	result.allocated = capacity
	result.ascii = (!is_string || header.ascii) && string_is_ascii(transmute([]u8)text)
	string_spare_counter += 1
	result.spare_owner = string_spare_counter
	return value
}

// Concatenates `base` with each part in order. Growth goes through
// `value_string_append`, so when the accumulator owns the tail of a buffer with
// room the next part is written past its visible prefix instead of rebuilding
// the whole string. Repeated concatenation (`s = concat(s, x)`) is therefore
// linear rather than O(n^2), matching an in-place append of an unshared string.
// The bytes are identical to a single exact-sized copy; the result carries
// spare capacity.
value_string_concat :: proc(alloc: mem.Allocator, base: Value, parts: []string) -> Value {
	result := base
	for part in parts {
		result = value_string_append(alloc, result, part)
	}
	return result
}

// Creates a byte-string value by copying `data` into `alloc`.
value_bytes :: proc(alloc: mem.Allocator, data: []u8) -> Value {
	owned := make([]u8, len(data), alloc)
	copy(owned, data)
	header := new(Heap_Bytes, alloc)
	header.data = owned
	return value_heap(.Bytes, header)
}

/// Map size at or below which the exact scan is used instead of the binary
/// search. The scan is O(n) with a cheap comparison; the binary search is
/// O(log n) but runs the recursive canonical comparator per probe. The
/// crossover measured between 8 and 16 entries.
MAP_EXACT_SCAN_LIMIT :: 12

// Returns the entry index for `key`, using a cheap exact comparison for the
// common key kinds and falling back to the canonical ordering only when the
// cheap comparison cannot decide. Entries are canonicalized sorted by key (see
// `value_map`), so a binary search is valid.
map_entry_index :: proc(entries: []Map_Entry, key: Value) -> (int, bool) {
	if len(entries) == 0 {
		return 0, false
	}
	// Fast path for a small map: a scan with the cheap payload comparison
	// avoids the recursive comparator on every binary-search probe. Above the
	// limit the linear scan loses, so the search is used.
	key_kind := value_kind(key)
	if len(entries) <= MAP_EXACT_SCAN_LIMIT && map_key_kind_is_exact(key_kind) {
		all_same_kind := true
		for entry in entries {
			if value_kind(entry.key) != key_kind {
				all_same_kind = false
				break
			}
		}
		if all_same_kind {
			for entry, index in entries {
				if value_eq(entry.key, key) {
					return index, true
				}
			}
			return 0, false
		}
	}
	index, found := slice.binary_search_by(
		entries,
		key,
		proc(entry: Map_Entry, key: Value) -> (slice.Ordering) {
			switch value_cmp(entry.key, key) {
			case .Less:
				return .Less
			case .Greater:
				return .Greater
			case .Equal:
				return .Equal
			}
			return .Equal
		},
	)
	return index, found
}

// Reports whether this kind's equality is a payload comparison (see
// `value_eq`), so an exact scan can be used instead of the ordered comparator.
// Floats are excluded: their equality needs canonicalization care.
@(private)
map_key_kind_is_exact :: proc(kind: Value_Kind) -> bool {
	switch kind {
	case .Symbol, .Int, .Identity, .Error_Code, .Bool, .Capability, .Function:
		return true
	case .Float, .String, .Bytes, .List, .Map, .Range, .Error, .Frob, .Relation:
		return false
	}
	return false
}

// Creates a list value by copying `values` into `alloc`.
value_list :: proc(alloc: mem.Allocator, values: []Value) -> Value {
	owned := make([]Value, len(values), alloc)
	copy(owned, values)
	header := new(Heap_List, alloc)
	header.values = owned
	header.allocated = len(owned)
	return value_heap(.List, header)
}

// Creates a list value taking ownership of `values` without copying. `values`
// must have come from `alloc` and must not be used or freed by the caller
// afterwards. The header itself is still allocated.
value_list_owned :: proc(alloc: mem.Allocator, values: []Value) -> Value {
	header := new(Heap_List, alloc)
	header.values = values
	header.allocated = len(values)
	return value_heap(.List, header)
}

// A token handed out per append that creates spare capacity. Only the header
// holding the newest token may extend the buffer's tail.
@(private)
list_spare_counter: u64

// Appends `item` to `base`, returning the resulting list. When `base` owns the
// tail of a buffer with room, the append writes past its own length; otherwise
// a fresh buffer with headroom is allocated and `base` is copied in. Either way
// the result carries spare capacity, so building a list one item at a time is
// linear rather than O(n^2).
//
// Soundness matches the string append: a list value observes only
// `values[0..len]`, so bytes past the base's length are invisible through every
// existing value, and only the token holder may write there.
value_list_append :: proc(alloc: mem.Allocator, base: Value, item: Value) -> Value {
	header, is_list := heap_header(base, .List, Heap_List)
	if is_list && header.values != nil && header.spare_owner != 0 {
		required := len(header.values) + 1
		if required <= header.allocated {
			full := ([^]Value)(raw_data(header.values))[:header.allocated]
			full[len(header.values)] = item
			header.spare_owner = 0
			value := value_list_owned(alloc, full[:required])
			result, _ := heap_header(value, .List, Heap_List)
			result.allocated = header.allocated
			list_spare_counter += 1
			result.spare_owner = list_spare_counter
			return value
		}
	}
	required := 1
	if is_list {
		required += len(header.values)
	}
	capacity := required * 2
	if capacity < 8 {
		capacity = 8
	}
	buffer := make([]Value, capacity, alloc)
	write := 0
	if is_list {
		copy(buffer, header.values)
		write = len(header.values)
	}
	buffer[write] = item
	value := value_list_owned(alloc, buffer[:required])
	result, _ := heap_header(value, .List, Heap_List)
	result.allocated = capacity
	list_spare_counter += 1
	result.spare_owner = list_spare_counter
	return value
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
