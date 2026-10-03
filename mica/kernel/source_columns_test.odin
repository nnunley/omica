package kernel

import "core:testing"
import v "../var"

// Scans `relation` both ways and requires the same rows and the same error.
@(private = "file")
expect_scan_matches_visit :: proc(
	t: ^testing.T,
	source: ^Relation_Source,
	relation: Relation_ID,
	bindings: []v.Binding,
	loc := #caller_location,
) -> int {
	rows := make([dynamic]v.Tuple, context.temp_allocator)
	source.error = .None
	relation_source_scan_into(source, relation, bindings, &rows)
	visit_error := source.error
	source.error = .None
	batch, err := relation_source_scan_columns(source, relation, bindings, context.temp_allocator)
	testing.expect_value(t, err, visit_error, loc = loc)
	testing.expect_value(t, source.error, visit_error, loc = loc)
	testing.expect_value(t, batch.count, len(rows), loc = loc)
	for i in 0 ..< batch.count {
		values := make([]v.Value, len(bindings), context.temp_allocator)
		for c in 0 ..< len(bindings) {
			values[c] = batch.columns[c][i]
		}
		testing.expectf(t, has_tuple(rows[:], v.Tuple(values)), "row %d is not on the visit path", i, loc = loc)
	}
	source.error = .None
	return batch.count
}

@(test)
test_scan_columns_mixed_asserted_and_derived :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	kernel: Kernel
	kernel_init(&kernel)
	defer kernel_destroy(&kernel)
	r := create_relation(&kernel, 1, "R", 2)
	s := create_relation(&kernel, 2, "S", 2)
	x, y := v.symbol_intern("x"), v.symbol_intern("y")
	rule := rule_new(r, []Term{term_var(x), term_var(y)}, []Rule_Body_Item {
		body_atom(atom_positive(s, []Term{term_var(x), term_var(y)})),
	})
	installed, err := kernel_install_rule(&kernel, v.Identity(700), rule, "R(x, y) :- S(x, y).")
	testing.expect_value(t, err, Kernel_Error.None)
	snapshot_release(installed)
	tx := kernel_begin(&kernel)
	transaction_assert(&tx, r, tuple_of(must_int(1), must_int(1)))
	transaction_assert(&tx, s, tuple_of(must_int(2), must_int(2)))
	commit_transaction(t, &tx)

	source := Relation_Source{kernel = &kernel, snapshot = kernel.current, use_stored_derived = true}
	testing.expect_value(t, expect_scan_matches_visit(t, &source, r, make([]v.Binding, 2, context.temp_allocator)), 2)
	testing.expect_value(t, expect_scan_matches_visit(t, &source, r, []v.Binding{v.binding_of(must_int(2)), {}}), 1)
}

@(test)
test_scan_columns_transaction_overlay_and_derived_layers :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	kernel: Kernel
	kernel_init(&kernel)
	defer kernel_destroy(&kernel)
	r := create_relation(&kernel, 1, "R", 2)
	setup := kernel_begin(&kernel)
	transaction_assert(&setup, r, tuple_of(must_int(1), must_int(1)))
	transaction_assert(&setup, r, tuple_of(must_int(3), must_int(3)))
	commit_transaction(t, &setup)

	tx := kernel_begin(&kernel)
	defer transaction_destroy(&tx)
	testing.expect_value(t, transaction_retract(&tx, r, tuple_of(must_int(1), must_int(1))), Kernel_Error.None)
	testing.expect_value(t, transaction_assert(&tx, r, tuple_of(must_int(4), must_int(4))), Kernel_Error.None)
	derived := rules_derived_create(context.temp_allocator)
	rules_derived_add(&derived, r, tuple_of(must_int(5), must_int(5)))
	delta := rules_derived_create(context.temp_allocator)
	rules_derived_add(&delta, r, tuple_of(must_int(6), must_int(6)))

	unbound := make([]v.Binding, 2, context.temp_allocator)
	source := Relation_Source{transaction = &tx, derived = &derived}
	// (3,3) and (4,4) from the overlay, (5,5) from the evaluation.
	testing.expect_value(t, expect_scan_matches_visit(t, &source, r, unbound), 3)
	source.delta, source.delta_relation, source.delta_active = &delta, r, true
	// Delta-restricted: the overlay plus (6,6) only.
	testing.expect_value(t, expect_scan_matches_visit(t, &source, r, unbound), 3)
	testing.expect_value(t, expect_scan_matches_visit(t, &source, r, []v.Binding{v.binding_of(must_int(6)), {}}), 1)
}

@(test)
test_scan_columns_permission_denied :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	kernel: Kernel
	kernel_init(&kernel)
	defer kernel_destroy(&kernel)
	r := create_relation(&kernel, 1, "R", 1)
	tx := kernel_begin(&kernel)
	transaction_assert(&tx, r, tuple_of(must_int(1)))
	commit_transaction(t, &tx)

	authority := Authority{allocator = context.allocator} // not root; reads nothing
	source := Relation_Source{kernel = &kernel, snapshot = kernel.current, authority = &authority}
	batch, err := relation_source_scan_columns(&source, r, make([]v.Binding, 1, context.temp_allocator), context.temp_allocator)
	testing.expect_value(t, err, Kernel_Error.Permission_Denied)
	testing.expect_value(t, source.error, Kernel_Error.Permission_Denied)
	testing.expect_value(t, batch.count, 0)
	testing.expect_value(t, expect_scan_matches_visit(t, &source, r, make([]v.Binding, 1, context.temp_allocator)), 0)
}

@(test)
test_scan_columns_computed_relation :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	kernel: Kernel
	kernel_init(&kernel)
	defer kernel_destroy(&kernel)
	even := create_relation(&kernel, 1, "Even", 1)
	testing.expect_value(t, kernel_register_computed_relation(&kernel, even, []u16{0},
		proc(user: rawptr, source: ^Relation_Source, bindings: []v.Binding, visit: Computed_Visit_Proc, visit_user: rawptr) -> Kernel_Error {
			n, ok := v.value_as_int(bindings[0].value)
			if ok && n % 2 == 0 {
				visit(visit_user, v.tuple_new(context.temp_allocator, []v.Value{bindings[0].value}))
			}
			return .None
		}), Kernel_Error.None)
	source := Relation_Source{kernel = &kernel, snapshot = kernel.current}
	testing.expect_value(t, expect_scan_matches_visit(t, &source, even, []v.Binding{v.binding_of(must_int(4))}), 1)
	testing.expect_value(t, expect_scan_matches_visit(t, &source, even, []v.Binding{v.binding_of(must_int(3))}), 0)
	// Unbound required key: both paths report the same error.
	expect_scan_matches_visit(t, &source, even, make([]v.Binding, 1, context.temp_allocator))
}
