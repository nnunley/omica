// Role-based method dispatch matching.
//
// An invocation supplies role-value pairs. A method is applicable when every
// one of its parameter roles is present in the invocation and the invocation
// value matches the parameter restriction. Extra invocation roles are ignored
// (open signatures). Restrictions are matched directly, through the delegates
// closure, through primitive prototypes, or through the frob-only marker.
package kernel

import "core:mem"
import "core:slice"
import v "../var"

// Relation ids used by dispatch.
Dispatch_Relations :: struct {
	method_selector: Relation_ID,
	param:           Relation_ID,
	delegates:       Relation_ID,
}

// A role-value pair supplied by an invocation.
Role_Pair :: struct {
	role:  v.Value,
	value: v.Value,
}

// An applicable method and its parameter tuples.
Applicable_Method :: struct {
	method: v.Value,
	params: []v.Tuple,
}

// Returns the unrestricted dispatch restriction marker.
unrestricted_dispatch_restriction :: proc() -> v.Value {
	return v.value_symbol(v.symbol_intern("dispatch/unrestricted"))
}

// Returns a frob-only dispatch restriction for `delegate`.
frob_only_dispatch_restriction :: proc(alloc: mem.Allocator, delegate: v.Identity) -> v.Value {
	marker := v.value_symbol(v.symbol_intern("dispatch/frob_only"))
	return v.value_frob(alloc, delegate, marker)
}

// Returns the role value for a role, if present.
role_value :: proc(roles: []Role_Pair, role: v.Value) -> (v.Value, bool) {
	for pair in roles {
		if v.value_eq(pair.role, role) {
			return pair.value, true
		}
	}
	return v.Value(0), false
}

// Returns all applicable methods for a selector and role set.
applicable_method_entries :: proc(
	source: ^Relation_Source,
	relations: Dispatch_Relations,
	selector: v.Value,
	roles: []Role_Pair,
	alloc: mem.Allocator,
) -> []Applicable_Method {
	methods: [dynamic]Applicable_Method

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
		params: [dynamic]v.Tuple
		relation_source_scan_into(
			source,
			relations.param,
			[]v.Binding{v.binding_of(method), {}, {}, {}},
			&params,
		)
		if params_match(source, relations.delegates, roles, params[:]) {
			owned := make([]v.Tuple, len(params), alloc)
			copy(owned, params[:])
			append(&methods, Applicable_Method{method = method, params = owned})
		}
		delete(params)
	}

	slice.sort_by(methods[:], proc(a, b: Applicable_Method) -> bool {
		return v.value_cmp(a.method, b.method) == .Less
	})

	deduped: [dynamic]Applicable_Method
	for method in methods {
		duplicate := false
		for existing in deduped {
			if v.value_eq(existing.method, method.method) {
				duplicate = true
				break
			}
		}
		if !duplicate {
			append(&deduped, method)
		}
	}
	delete(methods)

	pruned := prune_named_methods(source, relations.delegates, deduped[:], alloc)
	delete(deduped)
	return pruned
}

// Returns only the method values of applicable methods.
applicable_methods :: proc(
	source: ^Relation_Source,
	relations: Dispatch_Relations,
	selector: v.Value,
	roles: []Role_Pair,
	alloc: mem.Allocator,
) -> []v.Value {
	entries := applicable_method_entries(source, relations, selector, roles, alloc)
	methods := make([]v.Value, len(entries), alloc)
	for entry, i in entries {
		methods[i] = entry.method
	}
	return methods
}

@(private)
prune_named_methods :: proc(
	source: ^Relation_Source,
	delegates_relation: Relation_ID,
	methods: []Applicable_Method,
	alloc: mem.Allocator,
) -> []Applicable_Method {
	pruned: [dynamic]Applicable_Method
	for candidate in methods {
		dominated := false
		for other in methods {
			if v.value_eq(candidate.method, other.method) {
				continue
			}
			if named_method_more_specific(source, delegates_relation, other, candidate) {
				dominated = true
				break
			}
		}
		if !dominated {
			append(&pruned, candidate)
		}
	}
	result := make([]Applicable_Method, len(pruned), alloc)
	copy(result, pruned[:])
	delete(pruned)
	return result
}

@(private)
named_method_more_specific :: proc(
	source: ^Relation_Source,
	delegates_relation: Relation_ID,
	left: Applicable_Method,
	right: Applicable_Method,
) -> bool {
	stricter := len(left.params) > len(right.params)

	for right_param in right.params {
		role := v.tuple_values(right_param)[1]
		left_param: v.Tuple = nil
		for param in left.params {
			if v.value_eq(v.tuple_values(param)[1], role) {
				left_param = param
				break
			}
		}
		if left_param == nil {
			return false
		}
		left_restriction := v.tuple_values(left_param)[2]
		right_restriction := v.tuple_values(right_param)[2]
		if !restriction_implies(source, delegates_relation, left_restriction, right_restriction) {
			return false
		}
		if !restriction_implies(source, delegates_relation, right_restriction, left_restriction) {
			stricter = true
		}
	}
	return stricter
}

@(private)
restriction_implies :: proc(
	source: ^Relation_Source,
	delegates_relation: Relation_ID,
	specific: v.Value,
	general: v.Value,
) -> bool {
	unrestricted := unrestricted_dispatch_restriction()
	if v.value_eq(specific, general) || v.value_eq(general, unrestricted) {
		return true
	}
	if v.value_eq(specific, unrestricted) {
		return false
	}
	return matches_restriction(source, delegates_relation, specific, general)
}

@(private)
params_match :: proc(
	source: ^Relation_Source,
	delegates_relation: Relation_ID,
	roles: []Role_Pair,
	params: []v.Tuple,
) -> bool {
	for param in params {
		role := v.tuple_values(param)[1]
		restriction := v.tuple_values(param)[2]
		value, found := role_value(roles, role)
		if !found {
			return false
		}
		if !matches_restriction(source, delegates_relation, value, restriction) {
			return false
		}
	}
	return true
}

@(private)
matches_restriction :: proc(
	source: ^Relation_Source,
	delegates_relation: Relation_ID,
	value: v.Value,
	restriction: v.Value,
) -> bool {
	if v.value_eq(restriction, unrestricted_dispatch_restriction()) {
		return true
	}

	if required_delegate, ok := frob_only_restriction(restriction); ok {
		value_delegate, has_delegate := v.value_frob_delegate(value)
		if !has_delegate {
			return false
		}
		return identity_matches(source, delegates_relation, value_delegate, required_delegate)
	}

	if v.value_eq(value, restriction) {
		return true
	}

	_, is_frob := v.value_frob_delegate(value)
	if !is_frob && delegates_reaches(source, delegates_relation, value, restriction) {
		return true
	}

	if identity, ok := v.value_as_identity(value); ok {
		if identity_matches(source, delegates_relation, identity, restriction) {
			return true
		}
		prototype := v.primitive_prototype_for_value(value)
		return identity_matches(source, delegates_relation, prototype, restriction)
	}

	if delegate, ok := v.value_frob_delegate(value); ok {
		if identity_matches(source, delegates_relation, delegate, restriction) {
			return true
		}
		return identity_matches(
			source,
			delegates_relation,
			v.FROB_PROTOTYPE,
			restriction,
		)
	}

	prototype := v.primitive_prototype_for_value(value)
	return identity_matches(source, delegates_relation, prototype, restriction)
}

@(private)
frob_only_restriction :: proc(restriction: v.Value) -> (v.Value, bool) {
	header, ok := v.value_as_frob(restriction)
	if !ok {
		return v.Value(0), false
	}
	marker := v.value_symbol(v.symbol_intern("dispatch/frob_only"))
	if !v.value_eq(header.value, marker) {
		return v.Value(0), false
	}
	return v.value_identity(header.delegate), true
}

@(private)
identity_matches :: proc(
	source: ^Relation_Source,
	delegates_relation: Relation_ID,
	identity: v.Identity,
	restriction: v.Value,
) -> bool {
	prototype := v.value_identity(identity)
	if v.value_eq(prototype, restriction) {
		return true
	}
	return delegates_reaches(source, delegates_relation, prototype, restriction)
}
