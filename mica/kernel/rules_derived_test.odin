package kernel

import "core:testing"
import v "../var"

@(test)
test_rules_derived_batch_dedups_within_and_across :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	d := rules_derived_create(context.temp_allocator)
	delta := rules_derived_create(context.temp_allocator)
	a := v.value_string(context.temp_allocator, "a")
	b := v.value_string(context.temp_allocator, "b")
	columns := [][]v.Value{{must_int(1), must_int(2), must_int(1)}, {a, b, a}}
	testing.expect_value(t, rules_derived_add_columns(&d, &delta, Relation_ID(7), columns, 3, context.temp_allocator), 2)
	testing.expect_value(t, rules_derived_count(&d, Relation_ID(7)), 2)
	testing.expect_value(t, rules_derived_count(&delta, Relation_ID(7)), 2)
	again := [][]v.Value{{must_int(2)}, {b}}
	testing.expect_value(t, rules_derived_add_columns(&d, &delta, Relation_ID(7), again, 1, context.temp_allocator), 0)
	testing.expect_value(t, rules_derived_count(&d, Relation_ID(7)), 2)
	testing.expect_value(t, rules_derived_count(&d, Relation_ID(8)), 0)
	testing.expect(t, rules_derived_find(&d, Relation_ID(8)) == nil)
}

// Review Focus 5: single-row and batch adds share one hash, and equal strings
// from distinct allocations are the same row.
@(test)
test_rules_derived_single_and_batch_agree :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	d := rules_derived_create(context.temp_allocator)
	alpha := v.value_string(context.temp_allocator, "alpha")
	alpha_again := v.value_string(context.temp_allocator, "alpha")
	testing.expect(t, rules_derived_add(&d, Relation_ID(1), tuple_of(must_int(1), alpha)))
	testing.expect(t, !rules_derived_add(&d, Relation_ID(1), tuple_of(must_int(1), alpha_again)))
	batch := [][]v.Value{{must_int(1), must_int(2)}, {alpha_again, alpha}}
	testing.expect_value(t, rules_derived_add_columns(&d, nil, Relation_ID(1), batch, 2, context.temp_allocator), 1)
	hashes := rules_derived_hashes(&d, Relation_ID(1))
	rows := rules_derived_tuples(&d, Relation_ID(1), context.temp_allocator)
	testing.expect_value(t, len(rows), 2)
	for row, i in rows {
		testing.expect_value(t, hashes[i], v.tuple_hash(row))
	}
}

@(test)
test_rules_derived_grows_index :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	d := rules_derived_create(context.temp_allocator)
	for start := 0; start < 1000; start += 7 {
		n := min(7, 1000 - start)
		col := make([]v.Value, n, context.temp_allocator)
		for i in 0 ..< n {
			col[i] = must_int(i64(start + i))
		}
		testing.expect_value(t, rules_derived_add_columns(&d, nil, Relation_ID(3), [][]v.Value{col}, n, context.temp_allocator), n)
	}
	testing.expect_value(t, rules_derived_count(&d, Relation_ID(3)), 1000)
	for i in 0 ..< 1000 {
		testing.expect(t, !rules_derived_add(&d, Relation_ID(3), tuple_of(must_int(i64(i)))))
	}
}

// Review Focus 2.
@(test)
test_rules_derived_zero_arity :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	d := rules_derived_create(context.temp_allocator)
	testing.expect_value(t, rules_derived_add_columns(&d, nil, Relation_ID(4), nil, 3, context.temp_allocator), 1)
	testing.expect_value(t, rules_derived_add_columns(&d, nil, Relation_ID(4), nil, 2, context.temp_allocator), 0)
	testing.expect_value(t, rules_derived_count(&d, Relation_ID(4)), 1)
	testing.expect_value(t, len(rules_derived_tuples(&d, Relation_ID(4), context.temp_allocator)[0]), 0)
}

@(test)
test_rules_derived_visit_filters_and_materializes :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	d := rules_derived_create(context.temp_allocator)
	columns := [][]v.Value{{must_int(1), must_int(2), must_int(1)}, {must_int(5), must_int(6), must_int(7)}}
	rules_derived_add_columns(&d, nil, Relation_ID(2), columns, 3, context.temp_allocator)
	seen := make([dynamic]v.Tuple, context.temp_allocator)
	bindings := []v.Binding{v.binding_of(must_int(1)), {}}
	stopped := rules_derived_visit(&d, Relation_ID(2), bindings, proc(user: rawptr, row: v.Tuple) -> bool {
		append((^[dynamic]v.Tuple)(user), row)
		return true
	}, &seen)
	testing.expect(t, !stopped)
	testing.expect_value(t, len(seen), 2)
	testing.expect(t, has_tuple(seen[:], tuple_of(must_int(1), must_int(5))))
	testing.expect(t, has_tuple(seen[:], tuple_of(must_int(1), must_int(7))))
}

@(test)
test_derived_relations_from_is_canonical_rows :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	d := rules_derived_create(context.temp_allocator)
	columns := [][]v.Value{{must_int(3), must_int(1), must_int(2)}}
	rules_derived_add_columns(&d, nil, Relation_ID(9), columns, 3, context.temp_allocator)
	relations := derived_relations_from(context.temp_allocator, &d)
	testing.expect_value(t, len(relations), 1)
	testing.expect_value(t, relations[0].relation, Relation_ID(9))
	want := v.canonicalize_tuples([]v.Tuple{tuple_of(must_int(3)), tuple_of(must_int(1)), tuple_of(must_int(2))}, context.temp_allocator)
	testing.expect_value(t, len(relations[0].tuples), len(want))
	for row, i in relations[0].tuples {
		testing.expect(t, v.tuple_eq(row, want[i]))
	}
}

// A frozen result shows scans only the rows present at the freeze, while
// deduplication still sees every row; relations first created while frozen
// are invisible until the thaw.
@(test)
test_rules_derived_freeze_limits_scans_not_dedup :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	d := rules_derived_create(context.temp_allocator)
	rules_derived_add(&d, Relation_ID(1), tuple_of(must_int(1)))
	rules_derived_add(&d, Relation_ID(1), tuple_of(must_int(2)))
	rules_derived_freeze(&d)
	testing.expect(t, rules_derived_add(&d, Relation_ID(1), tuple_of(must_int(3))))
	testing.expect(t, !rules_derived_add(&d, Relation_ID(1), tuple_of(must_int(3))))
	testing.expect(t, !rules_derived_add(&d, Relation_ID(1), tuple_of(must_int(1))))
	testing.expect(t, rules_derived_add(&d, Relation_ID(2), tuple_of(must_int(9))))
	testing.expect_value(t, rules_derived_count(&d, Relation_ID(1)), 2)
	testing.expect_value(t, rules_derived_count(&d, Relation_ID(2)), 0)

	seen := 0
	rules_derived_visit(&d, Relation_ID(1), []v.Binding{{}}, proc(user: rawptr, row: v.Tuple) -> bool {
		(^int)(user)^ += 1
		return true
	}, &seen)
	testing.expect_value(t, seen, 2)
	source := Relation_Source{derived = &d}
	batch, err := relation_source_scan_columns(&source, Relation_ID(1), []v.Binding{{}}, context.temp_allocator)
	testing.expect_value(t, err, Kernel_Error.None)
	testing.expect_value(t, batch.count, 2)

	rules_derived_thaw(&d)
	testing.expect_value(t, rules_derived_count(&d, Relation_ID(1)), 3)
	testing.expect_value(t, rules_derived_count(&d, Relation_ID(2)), 1)
}
