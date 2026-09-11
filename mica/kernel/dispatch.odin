// Relation-driven method dispatch.
//
// Methods are ordinary relations installed by the runtime:
//
//   MethodSelector(method, selector)
//   Param(method, role, restriction, position)
//   MethodProgram(method, function index)
//   Delegates(child, prototype, ...)
//
// A dispatch site supplies a selector plus role values; a method applies when
// every parameter role is present and the value satisfies the parameter
// restriction. The most specific applicable method wins.
package kernel

import "core:mem"
import "core:slice"
import v "../var"

// Reserved relation ids for the dispatch tables. These sit above the range the
// runtime assigns to user relations.
DISPATCH_METHOD_SELECTOR_ID :: Relation_ID(0x7fff_ff01)
DISPATCH_PARAM_ID :: Relation_ID(0x7fff_ff02)
DISPATCH_DELEGATES_ID :: Relation_ID(0x7fff_ff03)
DISPATCH_METHOD_PROGRAM_ID :: Relation_ID(0x7fff_ff04)

Dispatch_Relations :: struct {
	method_selector: Relation_ID,
	param:           Relation_ID,
	delegates:       Relation_ID,
}

// A role binding supplied at a dispatch site.
Role_Pair :: struct {
	role:  v.Value,
	value: v.Value,
}

// A method whose parameters all accept the call's roles.
Applicable_Method :: struct {
	method: v.Value,
	params: []v.Tuple,
}

@(private)
unrestricted_marker :: proc() -> v.Value {
	return v.value_symbol(v.symbol_intern("dispatch/unrestricted"))
}

@(private)
frob_only_marker :: proc() -> v.Value {
	return v.value_symbol(v.symbol_intern("dispatch/frob_only"))
}

// Creates the metadata for the dispatch relations, in id order.
dispatch_relation_metadata :: proc(allocator := context.allocator) -> []Relation_Metadata {
	metadata := make([]Relation_Metadata, 4, allocator)
	metadata[0] = relation_metadata(
		DISPATCH_METHOD_SELECTOR_ID,
		v.symbol_intern("MethodSelector"),
		2,
	)
	metadata[1] = relation_metadata(DISPATCH_PARAM_ID, v.symbol_intern("Param"), 4)
	metadata[2] = relation_metadata(DISPATCH_DELEGATES_ID, v.symbol_intern("Delegates"), 3)
	metadata[3] = relation_metadata(
		DISPATCH_METHOD_PROGRAM_ID,
		v.symbol_intern("MethodProgram"),
		2,
	)
	return metadata
}

// The restriction meaning "any value".
unrestricted_dispatch_restriction :: proc() -> v.Value {
	return unrestricted_marker()
}

// The restriction meaning "a frob delegating to `delegate`".
frob_only_dispatch_restriction :: proc(allocator: mem.Allocator, delegate: v.Identity) -> v.Value {
	return v.value_frob(allocator, delegate, frob_only_marker())
}

// Returns the method values applicable to `selector` with the given roles.
applicable_methods :: proc(
	source: ^Relation_Source,
	relations: Dispatch_Relations,
	selector: v.Value,
	roles: []Role_Pair,
	allocator := context.temp_allocator,
) -> [dynamic]v.Value {
	entries := applicable_method_entries(source, relations, selector, roles, allocator)
	methods := make([dynamic]v.Value, 0, len(entries), allocator)
	for entry in entries {
		append(&methods, entry.method)
	}
	return methods
}

// Returns applicable methods with their parameter rows, most specific first.
applicable_method_entries :: proc(
	source: ^Relation_Source,
	relations: Dispatch_Relations,
	selector: v.Value,
	roles: []Role_Pair,
	allocator := context.temp_allocator,
) -> [dynamic]Applicable_Method {
	methods := make([dynamic]Applicable_Method, 0, 4, allocator)
	selector_rows: [dynamic]v.Tuple
	defer delete(selector_rows)
	relation_source_scan_into(
		source,
		relations.method_selector,
		[]v.Binding{{}, v.binding_of(selector)},
		&selector_rows,
	)
	for row in selector_rows {
		method := v.tuple_values(row)[0]
		param_rows: [dynamic]v.Tuple
		relation_source_scan_into(
			source,
			relations.param,
			[]v.Binding{v.binding_of(method), {}, {}, {}},
			&param_rows,
		)
		if !params_match(source, relations.delegates, roles, param_rows[:]) {
			delete(param_rows)
			continue
		}
		params := make([]v.Tuple, len(param_rows), allocator)
		copy(params, param_rows[:])
		delete(param_rows)
		append(&methods, Applicable_Method{method = method, params = params})
	}

	slice.sort_by(methods[:], proc(a, b: Applicable_Method) -> bool {
		return v.value_cmp(a.method, b.method) == .Less
	})
	prune_duplicate_methods(&methods)
	return prune_dominated_methods(source, relations.delegates, methods)
}

@(private)
prune_duplicate_methods :: proc(methods: ^[dynamic]Applicable_Method) {
	write := 0
	for method in methods {
		if write > 0 && v.value_eq(methods[write - 1].method, method.method) {
			continue
		}
		methods[write] = method
		write += 1
	}
	resize(methods, write)
}

@(private)
prune_dominated_methods :: proc(
	source: ^Relation_Source,
	delegates: Relation_ID,
	methods: [dynamic]Applicable_Method,
) -> [dynamic]Applicable_Method {
	pruned := make([dynamic]Applicable_Method, 0, len(methods), context.temp_allocator)
	for candidate in methods {
		dominated := false
		for other in methods {
			if v.value_eq(candidate.method, other.method) {
				continue
			}
			if method_more_specific(source, delegates, other, candidate) {
				dominated = true
				break
			}
		}
		if !dominated {
			append(&pruned, candidate)
		}
	}
	return pruned
}

@(private)
method_more_specific :: proc(
	source: ^Relation_Source,
	delegates: Relation_ID,
	left, right: Applicable_Method,
) -> bool {
	stricter := len(left.params) > len(right.params)
	for right_param in right.params {
		right_values := v.tuple_values(right_param)
		left_param := param_for_role(left.params, right_values[1])
		if left_param == nil {
			return false
		}
		left_values := v.tuple_values(left_param)
		if !restriction_implies(source, delegates, left_values[2], right_values[2]) {
			return false
		}
		if !restriction_implies(source, delegates, right_values[2], left_values[2]) {
			stricter = true
		}
	}
	return stricter
}

@(private)
param_for_role :: proc(params: []v.Tuple, role: v.Value) -> v.Tuple {
	for param in params {
		if v.value_eq(v.tuple_values(param)[1], role) {
			return param
		}
	}
	return nil
}

@(private)
restriction_implies :: proc(
	source: ^Relation_Source,
	delegates: Relation_ID,
	specific, general: v.Value,
) -> bool {
	if v.value_eq(specific, general) || v.value_eq(general, unrestricted_marker()) {
		return true
	}
	if v.value_eq(specific, unrestricted_marker()) {
		return false
	}
	return matches_restriction(source, delegates, specific, general)
}

@(private)
params_match :: proc(
	source: ^Relation_Source,
	delegates: Relation_ID,
	roles: []Role_Pair,
	params: []v.Tuple,
) -> bool {
	for param in params {
		values := v.tuple_values(param)
		value, found := role_value(roles, values[1])
		if !found {
			return false
		}
		if !matches_restriction(source, delegates, value, values[2]) {
			return false
		}
	}
	return true
}

// Returns the first value bound to `role`.
role_value :: proc(roles: []Role_Pair, role: v.Value) -> (v.Value, bool) {
	for binding in roles {
		if v.value_eq(binding.role, role) {
			return binding.value, true
		}
	}
	return v.Value(0), false
}

@(private)
matches_restriction :: proc(
	source: ^Relation_Source,
	delegates: Relation_ID,
	value, restriction: v.Value,
) -> bool {
	if v.value_eq(restriction, unrestricted_marker()) {
		return true
	}
	if required_delegate, is_frob_only := restriction_frob_delegate(restriction); is_frob_only {
		delegate, is_frob := v.value_frob_delegate(value)
		if !is_frob {
			return false
		}
		return identity_matches(
			source,
			delegates,
			delegate,
			v.value_identity(required_delegate),
		)
	}
	if v.value_eq(value, restriction) {
		return true
	}

	if _, is_frob := v.value_as_frob(value); !is_frob {
		if delegates_reaches(source, delegates, value, restriction) {
			return true
		}
	}

	if identity, is_identity := v.value_as_identity(value); is_identity {
		if identity_matches(source, delegates, identity, restriction) {
			return true
		}
		return identity_matches(
			source,
			delegates,
			v.primitive_prototype_for_kind(v.value_kind(value)),
			restriction,
		)
	}

	if delegate, is_frob := v.value_frob_delegate(value); is_frob {
		if identity_matches(source, delegates, delegate, restriction) {
			return true
		}
		return identity_matches(source, delegates, v.FROB_PROTOTYPE, restriction)
	}

	prototype := v.primitive_prototype_for_kind(v.value_kind(value))
	return identity_matches(source, delegates, prototype, restriction)
}

// Returns the required delegate when `restriction` is a frob-only marker.
@(private)
restriction_frob_delegate :: proc(restriction: v.Value) -> (v.Identity, bool) {
	delegate, is_frob := v.value_frob_delegate(restriction)
	if !is_frob {
		return v.Identity(0), false
	}
	payload, has_payload := v.value_frob_value(restriction)
	if !has_payload || !v.value_eq(payload, frob_only_marker()) {
		return v.Identity(0), false
	}
	return delegate, true
}

@(private)
identity_matches :: proc(
	source: ^Relation_Source,
	delegates: Relation_ID,
	identity: v.Identity,
	restriction: v.Value,
) -> bool {
	prototype := v.value_identity(identity)
	if v.value_eq(prototype, restriction) {
		return true
	}
	return delegates_reaches(source, delegates, prototype, restriction)
}

// Returns the function index registered for `method`.
dispatch_method_program :: proc(
	source: ^Relation_Source,
	method_program: Relation_ID,
	method: v.Value,
) -> (v.Value, bool) {
	rows: [dynamic]v.Tuple
	defer delete(rows)
	relation_source_scan_into(
		source,
		method_program,
		[]v.Binding{v.binding_of(method), {}},
		&rows,
	)
	if len(rows) == 0 {
		return v.Value(0), false
	}
	return v.tuple_values(rows[0])[1], true
}

// Orders the call's role values by each parameter's declared position.
dispatch_method_args :: proc(
	params: []v.Tuple,
	roles: []Role_Pair,
	allocator := context.temp_allocator,
) -> ([]v.Value, bool) {
	ordered := make([]v.Tuple, len(params), allocator)
	copy(ordered, params)
	slice.sort_by(ordered, proc(a, b: v.Tuple) -> bool {
		return param_position(a) < param_position(b)
	})
	args := make([]v.Value, len(ordered), allocator)
	for param, index in ordered {
		role := v.tuple_values(param)[1]
		value, found := role_value(roles, role)
		if !found {
			return nil, false
		}
		args[index] = value
	}
	return args, true
}

@(private)
param_position :: proc(param: v.Tuple) -> i64 {
	values := v.tuple_values(param)
	if len(values) < 4 {
		return i64(0x7fff_ffff_ffff_ffff)
	}
	position, ok := v.value_as_int(values[3])
	if !ok {
		return i64(0x7fff_ffff_ffff_ffff)
	}
	return position
}
