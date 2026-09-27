// Fact neighbourhoods: the stored facts around a value, as computed relations.
//
//	SubjectFact(subject, relation, tuple)                        facts whose first value is the subject
//	MentionedFact(subject, relation, position, tuple)            facts mentioning the subject anywhere
//	ExtensionalMentionedFact(subject, relation, position, tuple) the same, named for stored facts only
//
// The subject must be bound. The views cover stored facts in the source's view
// (a transaction sees its own writes): derived and computed relations are
// left out, and so are relations the reader may not read, so a neighbourhood
// never reveals more than the reader could query directly. The relation
// column holds the relation's value, as in RelationName, and the tuple column
// holds the fact as a list.
package mica_runtime

import k "../kernel"
import v "../var"

@(private)
subject_fact_scan :: proc(
	user: rawptr,
	source: ^k.Relation_Source,
	bindings: []v.Binding,
	visit: k.Computed_Visit_Proc,
	visit_user: rawptr,
) -> k.Kernel_Error {
	return neighbourhood_scan(source, bindings, false, visit, visit_user)
}

@(private)
mentioned_fact_scan :: proc(
	user: rawptr,
	source: ^k.Relation_Source,
	bindings: []v.Binding,
	visit: k.Computed_Visit_Proc,
	visit_user: rawptr,
) -> k.Kernel_Error {
	return neighbourhood_scan(source, bindings, true, visit, visit_user)
}

@(private)
neighbourhood_scan :: proc(
	source: ^k.Relation_Source,
	bindings: []v.Binding,
	any_position: bool,
	visit: k.Computed_Visit_Proc,
	visit_user: rawptr,
) -> k.Kernel_Error {
	if len(bindings) < 1 || !bindings[0].bound {
		return .Computed_Binding_Required
	}
	subject := bindings[0].value
	snapshot := source.snapshot
	if source.transaction != nil {
		snapshot = source.transaction.base
	}
	if snapshot == nil {
		return .None
	}
	kernel := k.relation_source_kernel(source)
	derived := make(map[k.Relation_ID]bool, allocator = context.temp_allocator)
	for definition in snapshot.rules {
		derived[definition.rule.head_relation] = true
	}
	for metadata in snapshot.catalog {
		if metadata.tombstoned || metadata.storage != .Tuple || metadata.arity == 0 ||
		   derived[metadata.id] || k.kernel_relation_is_computed(kernel, metadata.id) ||
		   !k.authority_can_read(source.authority, metadata.id) {
			continue
		}
		relation_value, relation_ok := v.value_identity_raw(u64(metadata.id))
		if !relation_ok {
			continue
		}
		// An explicitly bound relation column narrows the scan to one relation.
		if len(bindings) > 1 && bindings[1].bound && !v.value_eq(bindings[1].value, relation_value) {
			continue
		}
		positions := int(metadata.arity) if any_position else 1
		for position in 0 ..< positions {
			if !neighbourhood_emit(source, metadata, subject, relation_value, position, any_position, visit, visit_user) {
				return .None
			}
		}
	}
	return .None
}

// Visits the facts of one relation that hold `subject` at `position`.
// Reports false when the visitor asked to stop.
@(private)
neighbourhood_emit :: proc(
	source: ^k.Relation_Source,
	metadata: k.Relation_Metadata,
	subject: v.Value,
	relation_value: v.Value,
	position: int,
	with_position: bool,
	visit: k.Computed_Visit_Proc,
	visit_user: rawptr,
) -> bool {
	scan_bindings := make([]v.Binding, metadata.arity, context.temp_allocator)
	scan_bindings[position] = v.binding_of(subject)
	rows: [dynamic]v.Tuple
	defer delete(rows)
	k.relation_source_scan_into(source, metadata.id, scan_bindings, &rows)
	for row in rows {
		fact := v.value_list(context.temp_allocator, v.tuple_values(row))
		result: v.Tuple
		if with_position {
			result = v.tuple_new(
				context.temp_allocator,
				[]v.Value{subject, relation_value, computed_int(u64(position)), fact},
			)
		} else {
			result = v.tuple_new(context.temp_allocator, []v.Value{subject, relation_value, fact})
		}
		if !visit(visit_user, result) {
			return false
		}
	}
	return true
}

// Registers the fact-neighbourhood relations, which every world's catalogue
// declares.
@(private)
install_neighbourhood_computed_relations :: proc(env: ^Builtin_Env) -> Run_Result {
	registrations := []struct {
		relation: k.Relation_ID,
		scan:     k.Computed_Scan_Proc,
	} {
		{k.SYSTEM_SUBJECT_FACT_ID, subject_fact_scan},
		{k.SYSTEM_MENTIONED_FACT_ID, mentioned_fact_scan},
		{k.SYSTEM_EXTENSIONAL_MENTIONED_FACT_ID, mentioned_fact_scan},
	}
	for registration in registrations {
		if err := k.kernel_register_computed_relation(
			env.kernel,
			registration.relation,
			[]u16{0},
			registration.scan,
			rawptr(env),
		); err != .None {
			return Run_Result{ok = false, message = "cannot register fact-neighbourhood relation"}
		}
	}
	return Run_Result{ok = true, message = "loaded"}
}
