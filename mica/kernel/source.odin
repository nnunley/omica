// Read sources for rules and dispatch.
//
// A `Relation_Source` layers the visible extensional tuples of a snapshot or
// transaction with derived facts. During rule evaluation the derived layer is
// the in-progress accumulator; for ordinary reads it is the stored derived set
// of the snapshot or transaction.
package kernel

import v "../var"

// A source of relation tuples for rule evaluation and dispatch matching.
Relation_Source :: struct {
	snapshot:           ^Snapshot,
	transaction:        ^Transaction,
	derived:            ^Rule_Derived,
	use_stored_derived: bool,
}

@(private)
Visit_State :: struct {
	visit:   proc(user: rawptr, row: v.Tuple) -> bool,
	user:    rawptr,
	stopped: bool,
}

@(private)
visit_state_trampoline :: proc(user: rawptr, row: v.Tuple) -> bool {
	state := (^Visit_State)(user)
	if !state.visit(state.user, row) {
		state.stopped = true
		return false
	}
	return true
}

// Visits tuples from a source matching a partial binding. Returns true when
// the visitor stopped the scan.
relation_source_visit :: proc(
	source: ^Relation_Source,
	relation: Relation_ID,
	bindings: []v.Binding,
	visit: proc(user: rawptr, row: v.Tuple) -> bool,
	user: rawptr,
) -> bool {
	state := Visit_State{visit = visit, user = user}

	if source.snapshot != nil {
		snapshot_visit_extensional(source.snapshot, relation, bindings, visit_state_trampoline, &state)
	} else if source.transaction != nil {
		transaction_visit_extensional(source.transaction, relation, bindings, visit_state_trampoline, &state)
	}
	if state.stopped {
		return true
	}

	if source.derived != nil {
		if rules_derived_visit(source.derived, relation, bindings, visit, user) {
			return true
		}
	}

	if source.use_stored_derived {
		if source.snapshot != nil {
			for row in snapshot_derived_rows(source.snapshot, relation) {
				if v.tuple_matches_bindings(row, bindings) {
					if !visit(user, row) {
						return true
					}
				}
			}
		} else if source.transaction != nil {
			for row in transaction_derived_rows(source.transaction, relation) {
				if v.tuple_matches_bindings(row, bindings) {
					if !visit(user, row) {
						return true
					}
				}
			}
		}
	}
	return false
}

// Visits tuples from a source matching a partial binding and appends them to
// `out`.
relation_source_scan_into :: proc(
	source: ^Relation_Source,
	relation: Relation_ID,
	bindings: []v.Binding,
	out: ^[dynamic]v.Tuple,
) {
	relation_source_visit(
		source,
		relation,
		bindings,
		proc(user: rawptr, row: v.Tuple) -> bool {
			append((^[dynamic]v.Tuple)(user), row)
			return true
		},
		out,
	)
}
