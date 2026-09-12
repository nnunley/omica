// Compact tagged-value representation.
//
// A `Value` is a single 64-bit word. The top byte holds a `Tag`; the low 56
// bits hold either an immediate payload (integer, float bits, symbol id,
// identity id, ...) or a pointer to an arena-allocated heap value. Identities,
// symbols, booleans, small integers, reduced-precision floats, and the
// zero-column empty relation stay inline.
//
// The layout follows the Rust `mica-var` crate deliberately so that ordering,
// equality, and display behaviour can be compared across the two
// implementations. Heap values are immutable and are owned by the snapshot or
// transaction arena that allocated them.
package var

import "core:math"

// The process-local value ABI version. Increment when the physical layout or
// invariants of `Value` change.
VALUE_ABI_VERSION :: 3

// A compact Mica value.
Value :: distinct u64

TAG_SHIFT :: 56
PAYLOAD_MASK :: u64(0x00ff_ffff_ffff_ffff)

INT_BITS :: 56
INT_MIN :: i64(-(i64(1) << (INT_BITS - 1)))
INT_MAX :: i64((i64(1) << (INT_BITS - 1)) - 1)

// Physical tag stored in the top byte of a `Value`.
Tag :: enum u8 {
	Empty_Relation = 0,
	Bool           = 1,
	Int            = 2,
	Float          = 3,
	Identity       = 4,
	Symbol         = 5,
	Error_Code     = 6,
	String         = 7,
	Bytes          = 8,
	List           = 9,
	Map            = 10,
	Range          = 11,
	Error          = 12,
	Capability     = 13,
	Frob           = 14,
	Function       = 15,
	Relation       = 16,
}

// Kinds of value as seen by language-level code. The zero-column empty
// relation is a relation, so it has no separate kind. The ordering of this
// enum is the canonical ordering between values of different kinds.
Value_Kind :: enum u8 {
	Bool       = 1,
	Int        = 2,
	Float      = 3,
	Identity   = 4,
	Symbol     = 5,
	Error_Code = 6,
	String     = 7,
	Bytes      = 8,
	List       = 9,
	Map        = 10,
	Range      = 11,
	Error      = 12,
	Capability = 13,
	Frob       = 14,
	Function   = 15,
	Relation   = 16,
}

@(private)
value_pack :: proc(tag: Tag, payload: u64) -> Value {
	return Value((u64(tag) << TAG_SHIFT) | (payload & PAYLOAD_MASK))
}

// Returns the physical tag of a value.
value_tag :: proc(v: Value) -> Tag {
	return Tag(u8(u64(v) >> TAG_SHIFT))
}

// Returns the raw low-56-bit payload of a value.
value_payload :: proc(v: Value) -> u64 {
	return u64(v) & PAYLOAD_MASK
}

// Returns the language-level kind of a value.
value_kind :: proc(v: Value) -> Value_Kind {
	tag := value_tag(v)
	if tag == .Empty_Relation {
		return .Relation
	}
	return Value_Kind(u8(tag))
}

// Returns the zero-column empty relation value, `[] {}` in source.
value_empty_relation :: proc() -> Value {
	return Value(0)
}

// Reports whether the value is the immediate zero-column empty relation.
value_is_empty_relation :: proc(v: Value) -> bool {
	return u64(v) == 0
}

// Reports whether the value is stored inline rather than on the heap.
value_is_immediate :: proc(v: Value) -> bool {
	#partial switch value_tag(v) {
	case .String, .Bytes, .List, .Map, .Range, .Error, .Frob, .Relation:
		return false
	case:
		return true
	}
}

// Stable entity identity payload.
Identity :: distinct u64

IDENTITY_MAX :: PAYLOAD_MASK

// Creates an identity from a raw id. Fails when the id exceeds the payload.
identity_new :: proc(raw: u64) -> (Identity, bool) {
	if raw > IDENTITY_MAX {
		return Identity(0), false
	}
	return Identity(raw), true
}

// Returns the raw id of an identity.
identity_raw :: proc(id: Identity) -> u64 {
	return u64(id)
}

// Prototype identities for primitive value kinds. Dispatch uses these to
// match domain restrictions such as `#integer` or `#string`.
BOOL_PROTOTYPE :: Identity(0x00c0_0000_0000_0002)
INTEGER_PROTOTYPE :: Identity(0x00c0_0000_0000_0003)
FLOAT_PROTOTYPE :: Identity(0x00c0_0000_0000_0004)
IDENTITY_PROTOTYPE :: Identity(0x00c0_0000_0000_0005)
SYMBOL_PROTOTYPE :: Identity(0x00c0_0000_0000_0006)
ERROR_CODE_PROTOTYPE :: Identity(0x00c0_0000_0000_0007)
STRING_PROTOTYPE :: Identity(0x00c0_0000_0000_0008)
BYTES_PROTOTYPE :: Identity(0x00c0_0000_0000_0009)
LIST_PROTOTYPE :: Identity(0x00c0_0000_0000_000a)
MAP_PROTOTYPE :: Identity(0x00c0_0000_0000_000b)
RANGE_PROTOTYPE :: Identity(0x00c0_0000_0000_000c)
ERROR_PROTOTYPE :: Identity(0x00c0_0000_0000_000d)
CAPABILITY_PROTOTYPE :: Identity(0x00c0_0000_0000_000e)
FROB_PROTOTYPE :: Identity(0x00c0_0000_0000_000f)
FUNCTION_PROTOTYPE :: Identity(0x00c0_0000_0000_0010)
RELATION_PROTOTYPE :: Identity(0x00c0_0000_0000_0011)

// Returns the prototype identity for a value kind.
primitive_prototype_for_kind :: proc(kind: Value_Kind) -> Identity {
	switch kind {
	case .Bool:
		return BOOL_PROTOTYPE
	case .Int:
		return INTEGER_PROTOTYPE
	case .Float:
		return FLOAT_PROTOTYPE
	case .Identity:
		return IDENTITY_PROTOTYPE
	case .Symbol:
		return SYMBOL_PROTOTYPE
	case .Error_Code:
		return ERROR_CODE_PROTOTYPE
	case .String:
		return STRING_PROTOTYPE
	case .Bytes:
		return BYTES_PROTOTYPE
	case .List:
		return LIST_PROTOTYPE
	case .Map:
		return MAP_PROTOTYPE
	case .Range:
		return RANGE_PROTOTYPE
	case .Error:
		return ERROR_PROTOTYPE
	case .Capability:
		return CAPABILITY_PROTOTYPE
	case .Frob:
		return FROB_PROTOTYPE
	case .Function:
		return FUNCTION_PROTOTYPE
	case .Relation:
		return RELATION_PROTOTYPE
	}
	return RELATION_PROTOTYPE
}

// Returns the prototype identity for a value.
primitive_prototype_for_value :: proc(value: Value) -> Identity {
	return primitive_prototype_for_kind(value_kind(value))
}

// Ephemeral authority designation payload. Capability ids are not durable
// world data and must not be persisted in relation tuples.
Capability_ID :: distinct u64

// Creates a capability id. Zero and out-of-range ids are rejected.
capability_id_new :: proc(raw: u64) -> (Capability_ID, bool) {
	if raw == 0 || raw > PAYLOAD_MASK {
		return Capability_ID(0), false
	}
	return Capability_ID(raw), true
}

// Returns the raw id of a capability id.
capability_id_raw :: proc(id: Capability_ID) -> u64 {
	return u64(id)
}

// Ephemeral VM-local function designation payload. Function ids are not
// durable world data and must not be persisted in relation tuples.
Function_ID :: distinct u64

// Creates a function id. Out-of-range ids are rejected.
function_id_new :: proc(raw: u64) -> (Function_ID, bool) {
	if raw > PAYLOAD_MASK {
		return Function_ID(0), false
	}
	return Function_ID(raw), true
}

// Returns the raw id of a function id.
function_id_raw :: proc(id: Function_ID) -> u64 {
	return u64(id)
}

// --- Constructors ----------------------------------------------------------

// Creates a boolean value.
value_bool :: proc(b: bool) -> Value {
	return value_pack(.Bool, b ? 1 : 0)
}

// Creates an integer value. Fails when the value does not fit in 56 signed
// bits.
value_int :: proc(n: i64) -> (Value, bool) {
	if n < INT_MIN || n > INT_MAX {
		return Value(0), false
	}
	return value_pack(.Int, u64(n)), true
}

// Creates a reduced-precision float value. NaN, infinities, and out-of-range
// values are rejected; negative zero canonicalizes to positive zero.
value_float :: proc(f: f32) -> (Value, bool) {
	if !float_is_finite(f) {
		return Value(0), false
	}
	canonical := f
	if canonical == 0 {
		canonical = 0
	}
	return value_pack(.Float, u64(transmute(u32)canonical)), true
}

// Creates a float from binary32 bits, validating finiteness.
value_float_from_bits :: proc(bits: u32) -> (Value, bool) {
	f := transmute(f32)bits
	if !float_is_finite(f) {
		return Value(0), false
	}
	canonical := bits
	if f == 0 {
		canonical = 0
	}
	return value_pack(.Float, u64(canonical)), true
}

// Creates an identity value.
value_identity :: proc(id: Identity) -> Value {
	return value_pack(.Identity, u64(id))
}

// Creates an identity value from a raw id.
value_identity_raw :: proc(raw: u64) -> (Value, bool) {
	id, ok := identity_new(raw)
	if !ok {
		return Value(0), false
	}
	return value_identity(id), true
}

// Creates a capability value.
value_capability :: proc(id: Capability_ID) -> Value {
	return value_pack(.Capability, u64(id))
}

// Creates a capability value from a raw id.
value_capability_raw :: proc(raw: u64) -> (Value, bool) {
	id, ok := capability_id_new(raw)
	if !ok {
		return Value(0), false
	}
	return value_capability(id), true
}

// Creates a function designation value.
value_function :: proc(id: Function_ID) -> Value {
	return value_pack(.Function, u64(id))
}

// Creates a function designation value from a raw id.
value_function_raw :: proc(raw: u64) -> (Value, bool) {
	id, ok := function_id_new(raw)
	if !ok {
		return Value(0), false
	}
	return value_function(id), true
}

// Creates a symbol value.
value_symbol :: proc(s: Symbol) -> Value {
	return value_pack(.Symbol, u64(symbol_id(s)))
}

// Creates an error-code value.
value_error_code :: proc(s: Symbol) -> Value {
	return value_pack(.Error_Code, u64(symbol_id(s)))
}

// --- Accessors -------------------------------------------------------------

// Returns the boolean payload, if this is a boolean.
value_as_bool :: proc(v: Value) -> (bool, bool) {
	if value_tag(v) != .Bool {
		return false, false
	}
	return value_payload(v) != 0, true
}

// Returns the integer payload, if this is an integer.
value_as_int :: proc(v: Value) -> (i64, bool) {
	if value_tag(v) != .Int {
		return 0, false
	}
	return (i64(value_payload(v) << 8)) >> 8, true
}

// Returns the float payload, if this is a float.
value_as_float :: proc(v: Value) -> (f32, bool) {
	if value_tag(v) != .Float {
		return 0, false
	}
	return transmute(f32)u32(value_payload(v)), true
}

// Returns the identity payload, if this is an identity.
value_as_identity :: proc(v: Value) -> (Identity, bool) {
	if value_tag(v) != .Identity {
		return Identity(0), false
	}
	return Identity(value_payload(v)), true
}

// Returns the capability payload, if this is a capability.
value_as_capability :: proc(v: Value) -> (Capability_ID, bool) {
	if value_tag(v) != .Capability {
		return Capability_ID(0), false
	}
	return Capability_ID(value_payload(v)), true
}

// Returns the function payload, if this is a function designation.
value_as_function :: proc(v: Value) -> (Function_ID, bool) {
	if value_tag(v) != .Function {
		return Function_ID(0), false
	}
	return Function_ID(value_payload(v)), true
}

// Returns the symbol payload, if this is a symbol.
value_as_symbol :: proc(v: Value) -> (Symbol, bool) {
	if value_tag(v) != .Symbol {
		return Symbol(0), false
	}
	return Symbol(u32(value_payload(v))), true
}

// Returns the symbol payload, if this is an error-code value.
value_as_error_code :: proc(v: Value) -> (Symbol, bool) {
	if value_tag(v) != .Error_Code {
		return Symbol(0), false
	}
	return Symbol(u32(value_payload(v))), true
}

// --- Numeric operations ----------------------------------------------------

@(private)
float_is_finite :: proc(f: f32) -> bool {
	bits := transmute(u32)f
	exponent := (bits >> 23) & 0xff
	return exponent != 0xff
}

// Adds two numeric values with checked overflow. Integer operands produce an
// integer; float operands produce a float. Mixed kinds fail.
value_checked_add :: proc(a, b: Value) -> (Value, bool) {
	if left, lok := value_as_int(a); lok {
		if right, rok := value_as_int(b); rok {
			if sum, ok := value_int(left + right); ok {
				return sum, true
			}
			return Value(0), false
		}
		return Value(0), false
	}
	l, lok := value_as_float(a)
	r, rok := value_as_float(b)
	if !lok || !rok {
		return Value(0), false
	}
	return value_float(l + r)
}

// Subtracts two numeric values with checked overflow.
value_checked_sub :: proc(a, b: Value) -> (Value, bool) {
	if left, lok := value_as_int(a); lok {
		if right, rok := value_as_int(b); rok {
			if diff, ok := value_int(left - right); ok {
				return diff, true
			}
			return Value(0), false
		}
		return Value(0), false
	}
	l, lok := value_as_float(a)
	r, rok := value_as_float(b)
	if !lok || !rok {
		return Value(0), false
	}
	return value_float(l - r)
}

// Multiplies two numeric values with checked overflow.
value_checked_mul :: proc(a, b: Value) -> (Value, bool) {
	if left, lok := value_as_int(a); lok {
		if right, rok := value_as_int(b); rok {
			if product, ok := value_int(left * right); ok {
				return product, true
			}
			return Value(0), false
		}
		return Value(0), false
	}
	l, lok := value_as_float(a)
	r, rok := value_as_float(b)
	if !lok || !rok {
		return Value(0), false
	}
	return value_float(l * r)
}

// Divides two numeric values. Integer division that is exact produces an
// integer; all other divisions fail, including mixing an integer and a float.
// Division by zero or overflow fails.
value_checked_div :: proc(a, b: Value) -> (Value, bool) {
	if left, lok := value_as_int(a); lok {
		if right, rok := value_as_int(b); rok {
			if right == 0 || left % right != 0 {
				return Value(0), false
			}
			if quotient, ok := value_int(left / right); ok {
				return quotient, true
			}
			return Value(0), false
		}
		return Value(0), false
	}
	l, lok := value_as_float(a)
	r, rok := value_as_float(b)
	if !lok || !rok || r == 0 {
		return Value(0), false
	}
	return value_float(l / r)
}

// Computes the remainder of two numeric values. Division by zero or mixed
// kinds fail.
value_checked_rem :: proc(a, b: Value) -> (Value, bool) {
	if left, lok := value_as_int(a); lok {
		if right, rok := value_as_int(b); rok {
			if right == 0 {
				return Value(0), false
			}
			if rem, ok := value_int(left % right); ok {
				return rem, true
			}
			return Value(0), false
		}
		return Value(0), false
	}
	l, lok := value_as_float(a)
	r, rok := value_as_float(b)
	if !lok || !rok || r == 0 {
		return Value(0), false
	}
	return value_float(float_rem(l, r))
}

// Explicitly converts a numeric value to a float. Integers round to the
// nearest binary32 value; floats are returned unchanged. Non-numeric values
// fail.
value_to_float :: proc(v: Value) -> (Value, bool) {
	if n, ok := value_as_int(v); ok {
		return value_float(f32(n))
	}
	if _, ok := value_as_float(v); ok {
		return v, true
	}
	return Value(0), false
}

// Explicitly converts a numeric value to an integer. A float converts only
// when it is exactly integral and within the Mica integer range; integers are
// returned unchanged. Other values fail.
value_to_int :: proc(v: Value) -> (Value, bool) {
	if f, ok := value_as_float(v); ok {
		if f != math.trunc(f) {
			return Value(0), false
		}
		return value_int(i64(f))
	}
	if _, ok := value_as_int(v); ok {
		return v, true
	}
	return Value(0), false
}

@(private)
float_rem :: proc(x, y: f32) -> f32 {
	return x - math.trunc(x / y) * y
}

// Negates a numeric value with checked overflow.
value_checked_neg :: proc(a: Value) -> (Value, bool) {
	if n, ok := value_as_int(a); ok {
		if negated, ok := value_int(-n); ok {
			return negated, true
		}
		return Value(0), false
	}
	f, ok := value_as_float(a)
	if !ok {
		return Value(0), false
	}
	return value_float(-f)
}
