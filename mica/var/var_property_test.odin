// Property-style tests with a deterministic pseudo-random generator.
//
// These tests exercise canonical ordering and deep copying over generated
// values. The generator uses a fixed seed, so a failure is repeatable.
package var

import "core:mem"
import "core:mem/virtual"
import "core:testing"

@(private)
Rng :: struct {
	state: u64,
}

@(private)
rng_init :: proc(seed: u64) -> Rng {
	return Rng{state = seed}
}

@(private)
rng_next :: proc(rng: ^Rng) -> u64 {
	rng.state = rng.state * 6364136223846793005 + 1442695040888963407
	return rng.state
}

@(private)
rng_below :: proc(rng: ^Rng, bound: int) -> int {
	if bound <= 0 {
		return 0
	}
	return int(rng_next(rng) % u64(bound))
}

@(private)
test_arena :: proc() -> ^virtual.Arena {
	arena := new(virtual.Arena)
	if err := virtual.arena_init_growing(arena); err != nil {
		panic("failed to initialize test arena")
	}
	return arena
}

@(private)
test_arena_destroy :: proc(arena: ^virtual.Arena) {
	virtual.arena_destroy(arena)
	free(arena)
}

@(private)
random_int_value :: proc(rng: ^Rng) -> Value {
	switch rng_below(rng, 6) {
	case 0:
		return must_int(INT_MIN)
	case 1:
		return must_int(INT_MAX)
	case 2:
		return must_int(0)
	case 3:
		return must_int(-1)
	case 4:
		return must_int(1)
	}
	return must_int(i64(rng_below(rng, 1_000_000)) - 500_000)
}

@(private)
random_float_value :: proc(rng: ^Rng) -> Value {
	choices := [6]f32{0, 1.5, -2.25, 1_000_000.5, 0.1, -1}
	value, _ := value_float(choices[rng_below(rng, len(choices))])
	return value
}

@(private)
random_symbol_value :: proc(rng: ^Rng, symbols: []Symbol) -> Value {
	return value_symbol(symbols[rng_below(rng, len(symbols))])
}

@(private)
random_string_value :: proc(rng: ^Rng, alloc: mem.Allocator) -> Value {
	texts := [5]string{"", "a", "hello", "λ", "line\nbreak"}
	return value_string(alloc, texts[rng_below(rng, len(texts))])
}

@(private)
random_bytes_value :: proc(rng: ^Rng, alloc: mem.Allocator) -> Value {
	buffers := [3][]u8{{}, {0, 1, 2}, {0xff, 0x00, 0x7f}}
	return value_bytes(alloc, buffers[rng_below(rng, len(buffers))])
}

@(private)
random_identity_value :: proc(rng: ^Rng) -> Value {
	raw := rng_next(rng) & PAYLOAD_MASK
	identity, _ := identity_new(raw)
	return value_identity(identity)
}

@(private)
random_capability_value :: proc(rng: ^Rng) -> Value {
	raw := (rng_next(rng) & PAYLOAD_MASK) | 1
	return value_capability(Capability_ID(raw))
}

@(private)
random_function_value :: proc(rng: ^Rng) -> Value {
	raw := rng_next(rng) & PAYLOAD_MASK
	return value_function(Function_ID(raw))
}

@(private)
random_immediate_value :: proc(rng: ^Rng, symbols: []Symbol) -> Value {
	switch rng_below(rng, 8) {
	case 0:
		return value_bool(rng_below(rng, 2) == 0)
	case 1, 2, 3:
		return random_int_value(rng)
	case 4:
		return random_float_value(rng)
	case 5:
		return random_symbol_value(rng, symbols)
	case 6:
		return random_identity_value(rng)
	}
	return value_error_code(symbols[rng_below(rng, len(symbols))])
}

@(private)
random_value :: proc(
	rng: ^Rng,
	alloc: mem.Allocator,
	symbols: []Symbol,
	depth: int,
) -> Value {
	if depth >= 3 {
		return random_immediate_value(rng, symbols)
	}

	switch rng_below(rng, 14) {
	case 0:
		return random_string_value(rng, alloc)
	case 1:
		return random_bytes_value(rng, alloc)
	case 2:
		return random_capability_value(rng)
	case 3:
		return random_function_value(rng)
	case 4:
		length := rng_below(rng, 4)
		values := make([]Value, length, alloc)
		for i in 0 ..< length {
			values[i] = random_value(rng, alloc, symbols, depth + 1)
		}
		return value_list(alloc, values)
	case 5:
		count := rng_below(rng, 3)
		entries := make([]Map_Entry, count, alloc)
		for i in 0 ..< count {
			entries[i] = Map_Entry {
				key   = random_immediate_value(rng, symbols),
				value = random_value(rng, alloc, symbols, depth + 1),
			}
		}
		return value_map(alloc, entries)
	case 6:
		start := random_immediate_value(rng, symbols)
		has_end := rng_below(rng, 2) == 0
		end := random_immediate_value(rng, symbols)
		return value_range(alloc, start, end, has_end)
	case 7:
		code := symbols[rng_below(rng, len(symbols))]
		has_message := rng_below(rng, 2) == 0
		has_value := rng_below(rng, 2) == 0
		return value_error(
			alloc,
			code,
			"message",
			has_message,
			random_immediate_value(rng, symbols),
			has_value,
		)
	case 8:
		identity, _ := identity_new(rng_next(rng) & PAYLOAD_MASK)
		return value_frob(alloc, identity, random_value(rng, alloc, symbols, depth + 1))
	case 9:
		arity := rng_below(rng, 3)
		heading := make([]Symbol, arity, alloc)
		for i in 0 ..< arity {
			heading[i] = symbols[i]
		}
		row_count := rng_below(rng, 3)
		rows := make([]Tuple, row_count, alloc)
		for i in 0 ..< row_count {
			cells := make([]Value, arity, alloc)
			for j in 0 ..< arity {
				cells[j] = random_immediate_value(rng, symbols)
			}
			rows[i] = tuple_from_slice(cells)
		}
		relation, _ := value_relation(alloc, heading, rows)
		return relation
	case:
		return random_immediate_value(rng, symbols)
	}
}

@(private)
cmp_ordering :: proc(a, b: Value) -> Ordering {
	return value_cmp(a, b)
}

@(test)
test_value_cmp_is_a_total_order :: proc(t: ^testing.T) {
	arena := test_arena()
	defer test_arena_destroy(arena)
	alloc := virtual.arena_allocator(arena)

	rng := rng_init(0x5eed_cafe)
	symbols := []Symbol {
		symbol_intern("alpha"),
		symbol_intern("beta"),
		symbol_intern("gamma"),
		symbol_intern("delta"),
	}

	values: [48]Value
	for i in 0 ..< len(values) {
		values[i] = random_value(&rng, alloc, symbols, 0)
	}

	reflexive := true
	antisymmetric := true
	equality_consistent := true
	for a in values {
		if cmp_ordering(a, a) != .Equal {
			reflexive = false
		}
		for b in values {
			ab := cmp_ordering(a, b)
			ba := cmp_ordering(b, a)
			switch ab {
			case .Less:
				if ba != .Greater {
					antisymmetric = false
				}
			case .Greater:
				if ba != .Less {
					antisymmetric = false
				}
			case .Equal:
				if ba != .Equal {
					antisymmetric = false
				}
			}
			if value_eq(a, b) != (ab == .Equal) {
				equality_consistent = false
			}
		}
	}
	testing.expect(t, reflexive)
	testing.expect(t, antisymmetric)
	testing.expect(t, equality_consistent)

	transitive := true
	for a in values {
		for b in values {
			if cmp_ordering(a, b) == .Greater {
				continue
			}
			for c in values {
				if cmp_ordering(b, c) == .Greater {
					continue
				}
				if cmp_ordering(a, c) == .Greater {
					transitive = false
				}
			}
		}
	}
	testing.expect(t, transitive)
}

@(test)
test_value_cmp_orders_heap_kinds_consistently :: proc(t: ^testing.T) {
	arena := test_arena()
	defer test_arena_destroy(arena)
	alloc := virtual.arena_allocator(arena)

	// Equal content in a different arena compares equal and follows the same
	// order against a third value.
	first := value_list(alloc, []Value{must_int(1), must_int(2)})
	second := value_list(alloc, []Value{must_int(1), must_int(3)})
	equivalent := value_list(alloc, []Value{must_int(1), must_int(2)})

	testing.expect(t, value_eq(first, equivalent))
	testing.expect(t, value_cmp(first, equivalent) == .Equal)
	testing.expect(t, value_cmp(first, second) == .Less)
	testing.expect(t, value_cmp(second, first) == .Greater)

	// A list sorts before a map because List has a lower kind number.
	as_map := value_map(alloc, []Map_Entry{{key = must_int(1), value = must_int(2)}})
	testing.expect(t, value_cmp(first, as_map) == .Less)

	// Range end options order None before Some.
	open_range := value_range(alloc, must_int(0), 0, false)
	closed_range := value_range(alloc, must_int(0), must_int(1), true)
	testing.expect(t, value_cmp(open_range, closed_range) == .Less)
}

@(test)
test_deep_copy_is_independent :: proc(t: ^testing.T) {
	source_arena := test_arena()
	defer test_arena_destroy(source_arena)
	dest_arena := test_arena()
	defer test_arena_destroy(dest_arena)
	source_alloc := virtual.arena_allocator(source_arena)
	dest_alloc := virtual.arena_allocator(dest_arena)

	inner := value_list(
		source_alloc,
		[]Value{must_int(1), value_string(source_alloc, "inner")},
	)
	original := value_map(
		source_alloc,
		[]Map_Entry{{key = must_int(1), value = inner}},
	)

	copied := value_deep_copy(dest_alloc, original)
	testing.expect(t, value_eq(original, copied))
	testing.expect(t, value_payload(original) != value_payload(copied))

	original_entries, original_ok := value_as_map(original)
	copied_entries, copied_ok := value_as_map(copied)
	testing.expect(t, original_ok && copied_ok)
	testing.expect_value(t, len(copied_entries), len(original_entries))
	testing.expect(
		t,
		value_payload(original_entries[0].value) != value_payload(copied_entries[0].value),
	)

	original_list, _ := value_as_list(original_entries[0].value)
	copied_list, _ := value_as_list(copied_entries[0].value)
	testing.expect(
		t,
		value_payload(original_list[1]) != value_payload(copied_list[1]),
	)
	copied_text, text_ok := value_as_string(copied_list[1])
	testing.expect(t, text_ok)
	testing.expect_value(t, copied_text, "inner")

	immediate := must_int(7)
	testing.expect_value(t, value_deep_copy(dest_alloc, immediate), immediate)

	// Tuple copies replace every heap cell.
	source_tuple := tuple_new(
		source_alloc,
		[]Value{value_string(source_alloc, "cell"), must_int(3)},
	)
	copied_tuple := tuple_deep_copy(dest_alloc, source_tuple)
	testing.expect(t, tuple_eq(source_tuple, copied_tuple))
	testing.expect(
		t,
		value_payload(tuple_values(source_tuple)[0]) != value_payload(tuple_values(copied_tuple)[0]),
	)
	testing.expect_value(t, tuple_values(copied_tuple)[1], must_int(3))

	// Relation values copy their rows and cells.
	heading := []Symbol{symbol_intern("deep-copy-column")}
	rows := []Tuple {
		tuple_new(source_alloc, []Value{value_string(source_alloc, "row")}),
	}
	relation_value, relation_err := value_relation(source_alloc, heading, rows)
	testing.expect_value(t, relation_err, Relation_Value_Error.None)
	copied_relation := value_deep_copy(dest_alloc, relation_value)
	testing.expect(t, value_eq(relation_value, copied_relation))
	original_relation, _ := value_as_relation(relation_value)
	copied_relation_view, _ := value_as_relation(copied_relation)
	testing.expect(
		t,
		value_payload(tuple_values(original_relation.rows[0])[0]) !=
		value_payload(tuple_values(copied_relation_view.rows[0])[0]),
	)
}

@(test)
test_value_hash_matches_equality :: proc(t: ^testing.T) {
	arena := test_arena()
	defer test_arena_destroy(arena)
	alloc := virtual.arena_allocator(arena)

	rng := rng_init(0x5eed_face)
	symbols := []Symbol {
		symbol_intern("hash-alpha"),
		symbol_intern("hash-beta"),
		symbol_intern("hash-gamma"),
	}

	values: [48]Value
	for i in 0 ..< len(values) {
		values[i] = random_value(&rng, alloc, symbols, 0)
	}

	consistent := true
	for a in values {
		for b in values {
			if value_eq(a, b) && value_hash(a) != value_hash(b) {
				consistent = false
			}
		}
	}
	testing.expect(t, consistent)

	// Tuple hashing follows tuple equality.
	rows: [16]Tuple
	for i in 0 ..< len(rows) {
		row_values := make([]Value, 2, alloc)
		row_values[0] = random_value(&rng, alloc, symbols, 1)
		row_values[1] = random_value(&rng, alloc, symbols, 1)
		rows[i] = tuple_from_slice(row_values)
	}
	tuple_consistent := true
	for a in rows {
		for b in rows {
			if tuple_eq(a, b) && tuple_hash(a) != tuple_hash(b) {
				tuple_consistent = false
			}
		}
	}
	testing.expect(t, tuple_consistent)
}
