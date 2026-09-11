// Task authority: the capability set a task runs with.
//
// Policy facts are ordinary relations. An actor's authority is minted at task
// start from `Can*`/`Grant*` facts for the actor and `RoleCan*` facts for the
// actor plus the roles it delegates to. A nil authority means root access; a
// root authority passes every check.
package kernel

import "core:mem"
import v "../var"

Authority :: struct {
	root:       bool,
	read:       map[Relation_ID]bool,
	write:      map[Relation_ID]bool,
	methods:    map[v.Value]bool,
	builtins:   map[v.Symbol]bool,
	selectors:  map[v.Symbol]bool,
	read_all:   bool,
	write_all:  bool,
	invoke_all: bool,
	effect:     bool,
	can_grant:  bool,
	allocator:  mem.Allocator,
}

// A root authority passes every check. It is the default for loaders and for
// tasks with no runtime context.
authority_root :: proc(allocator := context.allocator) -> Authority {
	return Authority {
		root      = true,
		allocator = allocator,
	}
}

authority_empty :: proc(allocator := context.allocator) -> Authority {
	return Authority {
		read      = make(map[Relation_ID]bool, allocator),
		write     = make(map[Relation_ID]bool, allocator),
		methods   = make(map[v.Value]bool, allocator),
		builtins  = make(map[v.Symbol]bool, allocator),
		selectors = make(map[v.Symbol]bool, allocator),
		allocator = allocator,
	}
}

authority_destroy :: proc(authority: ^Authority) {
	if authority == nil || authority.root {
		return
	}
	delete(authority.read)
	delete(authority.write)
	delete(authority.methods)
	delete(authority.builtins)
	delete(authority.selectors)
}

authority_can_read :: proc(authority: ^Authority, relation: Relation_ID) -> bool {
	if authority == nil || authority.root {
		return true
	}
	return authority.read_all || bool(authority.read[relation])
}

authority_can_write :: proc(authority: ^Authority, relation: Relation_ID) -> bool {
	if authority == nil || authority.root {
		return true
	}
	return authority.write_all || bool(authority.write[relation])
}

authority_can_invoke_method :: proc(authority: ^Authority, method: v.Value) -> bool {
	if authority == nil || authority.root {
		return true
	}
	return authority.invoke_all || bool(authority.methods[method])
}

authority_can_invoke_builtin :: proc(authority: ^Authority, name: v.Symbol) -> bool {
	if authority == nil || authority.root {
		return true
	}
	return authority.invoke_all ||
		bool(authority.builtins[name]) ||
		bool(authority.selectors[name])
}

// Reports whether the authority may invoke a method selected by `selector`.
authority_can_invoke_selector :: proc(authority: ^Authority, selector: v.Symbol) -> bool {
	if authority == nil || authority.root {
		return true
	}
	return authority.invoke_all || bool(authority.selectors[selector])
}

authority_can_effect :: proc(authority: ^Authority) -> bool {
	if authority == nil || authority.root {
		return true
	}
	return authority.effect
}

// Reports whether the authority may mint capabilities.
authority_can_grant :: proc(authority: ^Authority) -> bool {
	if authority == nil || authority.root {
		return true
	}
	return authority.can_grant
}

// Merges a capability grant into the authority.
authority_adopt_grant :: proc(authority: ^Authority, grant: Capability_Grant) {
	if authority == nil || authority.root {
		return
	}
	switch grant.scope {
	case .All:
		if grant.read {
			authority.read_all = true
		}
		if grant.write {
			authority.write_all = true
		}
		if grant.invoke {
			authority.invoke_all = true
		}
		if grant.effect {
			authority.effect = true
		}
		if grant.grant {
			authority.can_grant = true
		}
	case .Relation:
		if grant.read {
			authority.read[grant.relation] = true
		}
		if grant.write {
			authority.write[grant.relation] = true
		}
	case .Method, .Builtin:
		authority.selectors[grant.selector] = true
		authority.builtins[grant.selector] = true
	}
}

// Mints the authority for `actor` from the policy relations in `source`.
authority_from_actor :: proc(
	source: ^Relation_Source,
	actor: v.Identity,
	allocator := context.allocator,
) -> Authority {
	authority := authority_empty(allocator)
	roles := make([dynamic]v.Identity, 0, 4, context.temp_allocator)
	append(&roles, actor)
	if delegates, found := authority_policy_relation(source, "Delegates", 3); found {
		rows: [dynamic]v.Tuple
		defer delete(rows)
		relation_source_scan_into(
			source,
			delegates,
			[]v.Binding{v.binding_of(v.value_identity(actor)), {}, {}},
			&rows,
		)
		for row in rows {
			values := v.tuple_values(row)
			if role, is_identity := v.value_as_identity(values[1]); is_identity {
				append(&roles, role)
			}
		}
	}

	for role in roles {
		subject := v.value_identity(role)
		authority_mint_relations(source, &authority, subject, "CanRead", "GrantRead", true)
		authority_mint_relations(source, &authority, subject, "RoleCanRead", "", true)
		authority_mint_relations(source, &authority, subject, "CanWrite", "GrantWrite", false)
		authority_mint_relations(source, &authority, subject, "RoleCanWrite", "", false)
		authority_mint_invokes(source, &authority, subject, "CanInvoke")
		authority_mint_invokes(source, &authority, subject, "GrantInvoke")
		authority_mint_invokes(source, &authority, subject, "RoleCanInvoke")
		authority_mint_effects(source, &authority, subject, "CanEffect")
		authority_mint_effects(source, &authority, subject, "GrantEffect")
		authority_mint_effects(source, &authority, subject, "RoleCanEffect")
	}
	return authority
}

@(private)
authority_policy_relation :: proc(
	source: ^Relation_Source,
	name: string,
	arity: u16,
) -> (
	Relation_ID,
	bool,
) {
	if source == nil || source.snapshot == nil {
		return Relation_ID(0), false
	}
	metadata, found := snapshot_relation_metadata_named(
		source.snapshot,
		v.symbol_intern(name),
	)
	if !found || metadata.arity != arity {
		return Relation_ID(0), false
	}
	return metadata.id, true
}

@(private)
authority_relation_by_name :: proc(
	source: ^Relation_Source,
	name: v.Symbol,
) -> (
	Relation_ID,
	bool,
) {
	if source == nil || source.snapshot == nil {
		return Relation_ID(0), false
	}
	metadata, found := snapshot_relation_metadata_named(source.snapshot, name)
	if !found {
		return Relation_ID(0), false
	}
	return metadata.id, true
}

@(private)
authority_mint_relations :: proc(
	source: ^Relation_Source,
	authority: ^Authority,
	subject: v.Value,
	primary: string,
	secondary: string,
	is_read: bool,
) {
	names := [2]string{primary, secondary}
	for name in names {
		if name == "" {
			continue
		}
		relation, found := authority_policy_relation(source, name, 2)
		if !found {
			continue
		}
		rows: [dynamic]v.Tuple
		defer delete(rows)
		relation_source_scan_into(
			source,
			relation,
			[]v.Binding{v.binding_of(subject), {}},
			&rows,
		)
		for row in rows {
			values := v.tuple_values(row)
			target, is_symbol := v.value_as_symbol(values[1])
			if !is_symbol {
				continue
			}
			relation_id, resolved := authority_relation_by_name(source, target)
			if !resolved {
				continue
			}
			if is_read {
				authority.read[relation_id] = true
			} else {
				authority.write[relation_id] = true
			}
		}
	}
}

@(private)
authority_mint_invokes :: proc(
	source: ^Relation_Source,
	authority: ^Authority,
	subject: v.Value,
	name: string,
) {
	relation, found := authority_policy_relation(source, name, 2)
	if !found {
		return
	}
	rows: [dynamic]v.Tuple
	defer delete(rows)
	relation_source_scan_into(
		source,
		relation,
		[]v.Binding{v.binding_of(subject), {}},
		&rows,
	)
	for row in rows {
		values := v.tuple_values(row)
		selector, is_symbol := v.value_as_symbol(values[1])
		if !is_symbol {
			continue
		}
		// A granted selector names a method and, when the name is also a
		// builtin, allows that builtin.
		authority.builtins[selector] = true
		authority.selectors[selector] = true
		method_rows: [dynamic]v.Tuple
		defer delete(method_rows)
		relation_source_scan_into(
			source,
			DISPATCH_METHOD_SELECTOR_ID,
			[]v.Binding{{}, v.binding_of(v.value_symbol(selector))},
			&method_rows,
		)
		for method_row in method_rows {
			method_values := v.tuple_values(method_row)
			authority.methods[method_values[0]] = true
		}
	}
}

@(private)
authority_mint_effects :: proc(
	source: ^Relation_Source,
	authority: ^Authority,
	subject: v.Value,
	name: string,
) {
	relation, found := authority_policy_relation(source, name, 1)
	if !found {
		return
	}
	rows: [dynamic]v.Tuple
	defer delete(rows)
	relation_source_scan_into(
		source,
		relation,
		[]v.Binding{v.binding_of(subject)},
		&rows,
	)
	if len(rows) > 0 {
		authority.effect = true
	}
}
