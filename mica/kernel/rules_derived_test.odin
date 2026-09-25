package kernel

import "core:mem/virtual"
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

// Reserving for a batch is bounded: many candidate rows collapsing to a few
// distinct ones must not size the evaluation-lifetime index by the batch.
@(test)
test_rules_derived_reserve_bounded_by_new_rows :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	d := rules_derived_create(context.temp_allocator)
	n := 500_000
	column := make([]v.Value, n, context.temp_allocator)
	for i in 0 ..< n {
		column[i] = must_int(i64(i % 10))
	}
	testing.expect_value(t, rules_derived_add_columns(&d, nil, Relation_ID(1), [][]v.Value{column}, n, context.temp_allocator), 10)
	entry := rules_derived_find(&d, Relation_ID(1))
	testing.expectf(t, len(entry.index) <= 2 * DERIVED_RESERVE_MAX, "index has %d slots for 10 rows", len(entry.index))
}

// A relation grown by many small batches must not leave a copy of its columns
// behind in the arena on every batch: growth is geometric, so the arena holds
// at most a small multiple of the live rows (the full OpenCyc derivation used
// 193 bytes per row, most of it abandoned column copies).
@(test)
test_rules_derived_batches_grow_geometrically :: proc(t: ^testing.T) {
	arena: virtual.Arena
	if err := virtual.arena_init_growing(&arena); err != nil {
		testing.fail_now(t, "arena init failed")
	}
	defer virtual.arena_destroy(&arena)
	alloc := virtual.arena_allocator(&arena)
	d := rules_derived_create(alloc)
	BATCHES :: 200
	ROWS :: 1000
	keys := make([]v.Value, ROWS, context.temp_allocator)
	values := make([]v.Value, ROWS, context.temp_allocator)
	defer free_all(context.temp_allocator)
	for batch in 0 ..< BATCHES {
		for r in 0 ..< ROWS {
			keys[r] = must_int(i64(batch * ROWS + r))
			values[r] = must_int(i64(r))
		}
		added := rules_derived_add_columns(&d, nil, Relation_ID(3), [][]v.Value{keys, values}, ROWS, context.temp_allocator)
		testing.expect_value(t, added, ROWS)
	}
	entry := rules_derived_find(&d, Relation_ID(3))
	live := BATCHES * ROWS * (2 * size_of(v.Value) + size_of(u64)) + len(entry.index) * size_of(u32)
	testing.expectf(t, int(arena.total_used) < 4 * live, "arena holds %d bytes for %d live", arena.total_used, live)
}

// The copy into a snapshot holds only the canonical rows, packed: sort keys,
// the unsorted row list and per-row allocations go to the scratch allocator
// (the snapshot's frame arena never frees them).
@(test)
test_derived_relations_from_packs_rows :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	d := rules_derived_create(context.temp_allocator)
	ROWS :: 5000
	keys := make([]v.Value, ROWS, context.temp_allocator)
	values := make([]v.Value, ROWS, context.temp_allocator)
	for r in 0 ..< ROWS {
		keys[r] = must_int(i64(ROWS - r))
		values[r] = must_int(i64(r % 7))
	}
	rules_derived_add_columns(&d, nil, Relation_ID(4), [][]v.Value{keys, values}, ROWS, context.temp_allocator)

	arena: virtual.Arena
	if err := virtual.arena_init_growing(&arena); err != nil {
		testing.fail_now(t, "arena init failed")
	}
	defer virtual.arena_destroy(&arena)
	relations := derived_relations_from(virtual.arena_allocator(&arena), &d, context.temp_allocator)
	testing.expect_value(t, len(relations), 1)
	rows := relations[0].tuples
	testing.expect_value(t, len(rows), ROWS)
	for i in 1 ..< len(rows) {
		testing.expect_value(t, v.tuple_cmp(rows[i - 1], rows[i]), v.Ordering.Less)
	}
	packed := ROWS * (size_of(v.Tuple) + 2 * size_of(v.Value))
	testing.expectf(t, int(arena.total_used) <= packed + 4096, "snapshot copy holds %d bytes for %d packed", arena.total_used, packed)
}
