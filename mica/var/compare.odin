// Canonical value equality and ordering.
//
// Canonical comparison separates values by kind first: `1` and `1.0` are
// distinct values, and `1 == 1.0` is false here. Language-level numeric
// comparison is in `language_cmp`.
package var

import "core:slice"

// Result of a three-way comparison.
Ordering :: enum i8 {
	Less    = -1,
	Equal   = 0,
	Greater = 1,
}

@(private)
bytes_cmp :: proc(a, b: []u8) -> Ordering {
	n := min(len(a), len(b))
	for i in 0 ..< n {
		if a[i] < b[i] {
			return .Less
		}
		if a[i] > b[i] {
			return .Greater
		}
	}
	switch {
	case len(a) < len(b):
		return .Less
	case len(a) > len(b):
		return .Greater
	}
	return .Equal
}

@(private)
option_value_cmp :: proc(a: Value, a_has: bool, b: Value, b_has: bool) -> Ordering {
	switch {
	case !a_has && !b_has:
		return .Equal
	case !a_has:
		return .Less
	case !b_has:
		return .Greater
	}
	return value_cmp(a, b)
}

@(private)
value_cmp_same_kind :: proc(left, right: Value, kind: Value_Kind) -> Ordering {
	switch kind {
	case .Bool:
		l, _ := value_as_bool(left)
		r, _ := value_as_bool(right)
		switch {
		case !l && r:
			return .Less
		case l && !r:
			return .Greater
		}
		return .Equal
	case .Int:
		l, _ := value_as_int(left)
		r, _ := value_as_int(right)
		switch {
		case l < r:
			return .Less
		case l > r:
			return .Greater
		}
		return .Equal
	case .Float:
		l, _ := value_as_float(left)
		r, _ := value_as_float(right)
		switch {
		case l < r:
			return .Less
		case l > r:
			return .Greater
		}
		return .Equal
	case .Identity, .Symbol, .Error_Code, .Capability, .Function:
		l := value_payload(left)
		r := value_payload(right)
		switch {
		case l < r:
			return .Less
		case l > r:
			return .Greater
		}
		return .Equal
	case .String:
		l, _ := value_as_string(left)
		r, _ := value_as_string(right)
		return bytes_cmp(transmute([]u8)l, transmute([]u8)r)
	case .Bytes:
		l, _ := value_as_bytes(left)
		r, _ := value_as_bytes(right)
		return bytes_cmp(l, r)
	case .List:
		l, _ := value_as_list(left)
		r, _ := value_as_list(right)
		n := min(len(l), len(r))
		for i in 0 ..< n {
			if order := value_cmp(l[i], r[i]); order != .Equal {
				return order
			}
		}
		switch {
		case len(l) < len(r):
			return .Less
		case len(l) > len(r):
			return .Greater
		}
		return .Equal
	case .Map:
		l, _ := value_as_map(left)
		r, _ := value_as_map(right)
		n := min(len(l), len(r))
		for i in 0 ..< n {
			if order := value_cmp(l[i].key, r[i].key); order != .Equal {
				return order
			}
			if order := value_cmp(l[i].value, r[i].value); order != .Equal {
				return order
			}
		}
		switch {
		case len(l) < len(r):
			return .Less
		case len(l) > len(r):
			return .Greater
		}
		return .Equal
	case .Range:
		l_start, l_end, l_has_end, _ := value_as_range(left)
		r_start, r_end, r_has_end, _ := value_as_range(right)
		if order := value_cmp(l_start, r_start); order != .Equal {
			return order
		}
		return option_value_cmp(l_end, l_has_end, r_end, r_has_end)
	case .Error:
		l, _ := value_as_error(left)
		r, _ := value_as_error(right)
		l_code := symbol_id(l.code)
		r_code := symbol_id(r.code)
		switch {
		case l_code < r_code:
			return .Less
		case l_code > r_code:
			return .Greater
		}
		if order := option_bytes_cmp(
			transmute([]u8)l.message,
			l.has_message,
			transmute([]u8)r.message,
			r.has_message,
		); order != .Equal {
			return order
		}
		return option_value_cmp(l.value, l.has_value, r.value, r.has_value)
	case .Frob:
		l, _ := value_as_frob(left)
		r, _ := value_as_frob(right)
		l_delegate := identity_raw(l.delegate)
		r_delegate := identity_raw(r.delegate)
		switch {
		case l_delegate < r_delegate:
			return .Less
		case l_delegate > r_delegate:
			return .Greater
		}
		return value_cmp(l.value, r.value)
	case .Relation:
		l, _ := value_as_relation(left)
		r, _ := value_as_relation(right)
		n := min(len(l.heading), len(r.heading))
		for i in 0 ..< n {
			if l.heading[i] != r.heading[i] {
				if symbol_id(l.heading[i]) < symbol_id(r.heading[i]) {
					return .Less
				}
				return .Greater
			}
		}
		switch {
		case len(l.heading) < len(r.heading):
			return .Less
		case len(l.heading) > len(r.heading):
			return .Greater
		}
		m := min(len(l.rows), len(r.rows))
		for i in 0 ..< m {
			if order := tuple_cmp(l.rows[i], r.rows[i]); order != .Equal {
				return order
			}
		}
		switch {
		case len(l.rows) < len(r.rows):
			return .Less
		case len(l.rows) > len(r.rows):
			return .Greater
		}
		return .Equal
	}
	return .Equal
}

@(private)
option_bytes_cmp :: proc(a: []u8, a_has: bool, b: []u8, b_has: bool) -> Ordering {
	switch {
	case !a_has && !b_has:
		return .Equal
	case !a_has:
		return .Less
	case !b_has:
		return .Greater
	}
	return bytes_cmp(a, b)
}

// Reports whether two values are canonically equal.
value_eq :: proc(left, right: Value) -> bool {
	left_kind := value_kind(left)
	if left_kind != value_kind(right) {
		return false
	}
	#partial switch left_kind {
	case .Identity, .Symbol, .Error_Code, .Capability, .Function, .Bool, .Int, .Float:
		return value_payload(left) == value_payload(right)
	}
	return value_cmp_same_kind(left, right, left_kind) == .Equal
}

// Compares two values canonically. Values of different kinds order by kind.
value_cmp :: proc(left, right: Value) -> Ordering {
	left_kind := value_kind(left)
	right_kind := value_kind(right)
	if left_kind != right_kind {
		switch {
		case u8(left_kind) < u8(right_kind):
			return .Less
		case u8(left_kind) > u8(right_kind):
			return .Greater
		}
		return .Equal
	}
	return value_cmp_same_kind(left, right, left_kind)
}

// Sorts and deduplicates a slice of values in place, returning the unique
// prefix. The slice is modified.
@(private)
values_canonicalize :: proc(values: []Value) -> []Value {
	slice.sort_by(values, proc(a, b: Value) -> bool {
		return value_cmp(a, b) == .Less
	})
	write := 0
	for value in values {
		if write > 0 && value_eq(values[write - 1], value) {
			continue
		}
		values[write] = value
		write += 1
	}
	return values[:write]
}
