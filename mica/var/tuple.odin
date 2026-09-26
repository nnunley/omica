// Immutable rows of Mica values.
package var

import "core:mem"

// An immutable row of Mica values. A tuple has no relation identity or schema
// of its own; relation storage and relation values supply that context.
Tuple :: distinct []Value

// Creates a tuple by copying `values` into `alloc`.
tuple_new :: proc(alloc: mem.Allocator, values: []Value) -> Tuple {
	owned := make([]Value, len(values), alloc)
	copy(owned, values)
	return Tuple(owned)
}

// Wraps a slice as a tuple without copying. The caller transfers ownership of
// the slice, which must remain valid and unmodified for the tuple's lifetime.
tuple_from_slice :: proc(values: []Value) -> Tuple {
	return Tuple(values)
}

// Returns the values of a tuple.
tuple_values :: proc(t: Tuple) -> []Value {
	return ([]Value)(t)
}

// Returns the number of values in a tuple.
tuple_arity :: proc(t: Tuple) -> int {
	return len(([]Value)(t))
}

// Creates a tuple from selected positions of another tuple. Positions beyond
// the source yield the zero value rather than reading out of bounds.
tuple_select :: proc(t: Tuple, alloc: mem.Allocator, positions: []u16) -> Tuple {
	values := make([]Value, len(positions), alloc)
	source := tuple_values(t)
	for position, i in positions {
		index := int(position)
		if index < len(source) {
			values[i] = source[index]
		}
	}
	return Tuple(values)
}

// Concatenates two tuples into a new tuple allocated from `alloc`.
tuple_concat :: proc(a, b: Tuple, alloc: mem.Allocator) -> Tuple {
	av := tuple_values(a)
	bv := tuple_values(b)
	values := make([]Value, len(av) + len(bv), alloc)
	copy(values, av)
	copy(values[len(av):], bv)
	return Tuple(values)
}

// A slot in a partial tuple binding. `bound` is false for a wildcard.
Binding :: struct {
	bound: bool,
	value: Value,
}

// Creates a bound binding.
binding_of :: proc(value: Value) -> Binding {
	return Binding{bound = true, value = value}
}

// Compares two tuples lexicographically.
tuple_cmp :: proc(a, b: Tuple) -> Ordering {
	av := tuple_values(a)
	bv := tuple_values(b)
	n := min(len(av), len(bv))
	for i in 0 ..< n {
		if order := value_cmp(av[i], bv[i]); order != .Equal {
			return order
		}
	}
	switch {
	case len(av) < len(bv):
		return .Less
	case len(av) > len(bv):
		return .Greater
	}
	return .Equal
}

// Reports whether two tuples are equal.
tuple_eq :: proc(a, b: Tuple) -> bool {
	av := tuple_values(a)
	bv := tuple_values(b)
	if len(av) != len(bv) {
		return false
	}
	for value, i in av {
		if !value_eq(value, bv[i]) {
			return false
		}
	}
	return true
}

// Reports whether a tuple's values match a partial binding. `bindings` must
// have the same arity as the tuple.
tuple_matches_bindings :: proc(t: Tuple, bindings: []Binding) -> bool {
	if len(bindings) != tuple_arity(t) {
		return false
	}
	for binding, i in bindings {
		if binding.bound && !value_eq(tuple_values(t)[i], binding.value) {
			return false
		}
	}
	return true
}

// Returns the first unbound position in a binding, if any.
binding_first_unbound :: proc(bindings: []Binding) -> (int, bool) {
	for binding, i in bindings {
		if !binding.bound {
			return i, true
		}
	}
	return 0, false
}

// Returns the number of bound leading positions in a binding.
binding_leading_bound_count :: proc(bindings: []Binding) -> int {
	count := 0
	for binding in bindings {
		if !binding.bound {
			break
		}
		count += 1
	}
	return count
}
