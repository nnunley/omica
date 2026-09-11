// Language-level numeric comparison.
//
// Canonical `value_cmp`/`value_eq` keep integers and floats distinct. Language
// comparison treats them numerically: `1 == 1.0` is true and `1 < 1.5` holds,
// while stored values remain distinguishable as map and relation keys.
package var

// -2^55 as binary32 bits. Exactly representable, as is 2^55 below.
@(private)
INT_LOWER :: f32(-36028797018963968.0)

// 2^55 as binary32 bits: every Mica integer is strictly below this.
@(private)
INT_UPPER_EXCLUSIVE :: f32(36028797018963968.0)

// Compares a Mica integer with a finite binary32 float exactly, without
// converting the integer to a float.
language_compare_int_float :: proc(integer: i64, float: f32) -> Ordering {
	if float < INT_LOWER {
		return .Greater
	}
	if float >= INT_UPPER_EXCLUSIVE {
		return .Less
	}

	truncated := i64(float)
	switch {
	case integer < truncated:
		return .Less
	case integer > truncated:
		return .Greater
	}

	fraction := float - f32(truncated)
	switch {
	case fraction > 0:
		return .Less
	case fraction < 0:
		return .Greater
	}
	return .Equal
}

// Returns the numeric ordering of two values for language comparison.
// Non-numeric pairs retain canonical ordering.
language_numeric_cmp :: proc(left, right: Value) -> Ordering {
	left_kind := value_kind(left)
	right_kind := value_kind(right)

	if left_kind == .Int && right_kind == .Int {
		l, _ := value_as_int(left)
		r, _ := value_as_int(right)
		switch {
		case l < r:
			return .Less
		case l > r:
			return .Greater
		}
		return .Equal
	}
	if left_kind == .Float && right_kind == .Float {
		l, _ := value_as_float(left)
		r, _ := value_as_float(right)
		switch {
		case l < r:
			return .Less
		case l > r:
			return .Greater
		}
		return .Equal
	}
	if left_kind == .Int && right_kind == .Float {
		l, _ := value_as_int(left)
		r, _ := value_as_float(right)
		return language_compare_int_float(l, r)
	}
	if left_kind == .Float && right_kind == .Int {
		l, _ := value_as_float(left)
		r, _ := value_as_int(right)
		switch language_compare_int_float(r, l) {
		case .Less:
			return .Greater
		case .Greater:
			return .Less
		case .Equal:
			return .Equal
		}
	}
	return value_cmp(left, right)
}

// Returns true if two values are numerically equal for language comparison.
// Non-numeric pairs retain canonical equality.
language_numeric_eq :: proc(left, right: Value) -> bool {
	left_kind := value_kind(left)
	right_kind := value_kind(right)

	if left_kind == .Int && right_kind == .Int {
		l, _ := value_as_int(left)
		r, _ := value_as_int(right)
		return l == r
	}
	if left_kind == .Float && right_kind == .Float {
		l, _ := value_as_float(left)
		r, _ := value_as_float(right)
		return l == r
	}
	if left_kind == .Int && right_kind == .Float {
		l, _ := value_as_int(left)
		r, _ := value_as_float(right)
		return language_compare_int_float(l, r) == .Equal
	}
	if left_kind == .Float && right_kind == .Int {
		l, _ := value_as_float(left)
		r, _ := value_as_int(right)
		return language_compare_int_float(r, l) == .Equal
	}
	return value_eq(left, right)
}
