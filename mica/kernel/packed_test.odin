package kernel

import "core:mem/virtual"
import "core:sync"
import "core:testing"
import accel "./accel"
import v "../var"

@(private = "file")
int_value :: proc(n: i64) -> v.Value {
	value, _ := v.value_int(n)
	return value
}

@(test)
test_packed_keys_single_position_sorted_unique :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	keys, ok := packed_keys_from_columns([][]v.Value{{int_value(3), int_value(1), int_value(3)}}, 3, context.temp_allocator)
	testing.expect(t, ok)
	testing.expect_value(t, keys.width, 1)
	testing.expect_value(t, keys.count, 2)
	testing.expect_value(t, keys.columns[0][0], u64(int_value(1)))
	testing.expect_value(t, keys.columns[0][1], u64(int_value(3)))
}

@(test)
test_packed_keys_pairs_sorted_unique :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	a, b := must_identity(7), must_identity(5)
	keys, ok := packed_keys_from_columns([][]v.Value{{a, b, a, b}, {b, a, b, b}}, 4, context.temp_allocator)
	testing.expect(t, ok)
	testing.expect_value(t, keys.width, 2)
	testing.expect_value(t, keys.count, 3)
	testing.expect(t, accel.is_sorted_unique_pairs(keys.columns[0], keys.columns[1]))
}

@(test)
test_packed_keys_reject_heap_values_and_bad_widths :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	text := v.value_string(context.temp_allocator, "heap")
	_, heap_ok := packed_keys_from_columns([][]v.Value{{text}}, 1, context.temp_allocator)
	testing.expect(t, !heap_ok)
	one := []v.Value{int_value(1)}
	_, wide_ok := packed_keys_from_columns([][]v.Value{one, one, one}, 1, context.temp_allocator)
	testing.expect(t, !wide_ok)
	_, short_ok := packed_keys_from_columns([][]v.Value{one}, 2, context.temp_allocator)
	testing.expect(t, !short_ok)
	empty, empty_ok := packed_keys_from_columns([][]v.Value{nil}, 0, context.temp_allocator)
	testing.expect(t, empty_ok && empty.count == 0)
}

// One gather per (relation, width) per evaluation, however many rules and
// rounds probe it.
@(test)
test_packed_cache_builds_once_per_evaluation :: proc(t: ^testing.T) {
	sync.mutex_lock(&strategy_tests_lock)
	defer sync.mutex_unlock(&strategy_tests_lock)
	kernel: Kernel
	kernel_init(&kernel)
	defer kernel_destroy(&kernel)
	item := create_relation(&kernel, 1, "Item", 1)
	held := create_relation(&kernel, 2, "Held", 1)
	free_a := create_relation(&kernel, 3, "FreeA", 1)
	free_b := create_relation(&kernel, 4, "FreeB", 1)
	x := v.symbol_intern("x")
	for head, i in ([]Relation_ID{free_a, free_b}) {
		rule := rule_new(head, []Term{term_var(x)}, []Rule_Body_Item {
			body_atom(atom_positive(item, []Term{term_var(x)})),
			body_atom(atom_negated(held, []Term{term_var(x)})),
		})
		snapshot, err := kernel_install_rule(&kernel, v.Identity(900 + u64(i)), rule, "Free(x) :- Item(x), not Held(x).")
		testing.expect_value(t, err, Kernel_Error.None)
		snapshot_release(snapshot)
	}
	tx := kernel_begin(&kernel)
	for i in 1 ..= 64 {
		transaction_assert(&tx, item, tuple_of(must_identity(u64(i))))
		if i % 3 == 0 {
			transaction_assert(&tx, held, tuple_of(must_identity(u64(i))))
		}
	}
	commit_transaction(t, &tx)

	source := Relation_Source{kernel = &kernel, snapshot = kernel.current}
	evaluation: virtual.Arena
	testing.expect(t, virtual.arena_init_growing(&evaluation) == nil)
	defer virtual.arena_destroy(&evaluation)
	result := rules_derived_create(virtual.arena_allocator(&evaluation))
	err := rules_evaluate_source(virtual.arena_allocator(&evaluation), kernel.current.rules, &source, &result)
	testing.expect_value(t, err, Kernel_Error.None)
	// At most one gather: none when the commit's own evaluation already left
	// Held's keys in the cross-commit cache.
	testing.expect(t, packed_last_evaluation_builds() <= 1)
	testing.expect_value(t, rules_derived_count(&result, free_a), 43)
	testing.expect_value(t, rules_derived_count(&result, free_b), 43)
}

// Two rules negating the same relation, evaluated once; returns the Free
// rows of the first rule.
@(private = "file")
evaluate_shared_negation :: proc(t: ^testing.T) -> int {
	kernel: Kernel
	kernel_init(&kernel)
	defer kernel_destroy(&kernel)
	item := create_relation(&kernel, 1, "Item", 1)
	held := create_relation(&kernel, 2, "Held", 1)
	free_a := create_relation(&kernel, 3, "FreeA", 1)
	free_b := create_relation(&kernel, 4, "FreeB", 1)
	x := v.symbol_intern("x")
	for head, i in ([]Relation_ID{free_a, free_b}) {
		rule := rule_new(head, []Term{term_var(x)}, []Rule_Body_Item {
			body_atom(atom_positive(item, []Term{term_var(x)})),
			body_atom(atom_negated(held, []Term{term_var(x)})),
		})
		snapshot, err := kernel_install_rule(&kernel, v.Identity(950 + u64(i)), rule, "Free(x) :- Item(x), not Held(x).")
		testing.expect_value(t, err, Kernel_Error.None)
		snapshot_release(snapshot)
	}
	kernel_set_derivation(&kernel, false)
	tx := kernel_begin(&kernel)
	for i in 1 ..= 64 {
		transaction_assert(&tx, item, tuple_of(must_identity(u64(i))))
		if i % 3 == 0 {
			transaction_assert(&tx, held, tuple_of(must_identity(u64(i))))
		}
	}
	commit_transaction(t, &tx)
	evaluation: virtual.Arena
	testing.expect(t, virtual.arena_init_growing(&evaluation) == nil)
	defer virtual.arena_destroy(&evaluation)
	result := rules_derived_create(virtual.arena_allocator(&evaluation))
	source := Relation_Source{kernel = &kernel, snapshot = kernel.current, derived = &result}
	err := rules_evaluate_source(virtual.arena_allocator(&evaluation), kernel.current.rules, &source, &result)
	testing.expect_value(t, err, Kernel_Error.None)
	return rules_derived_count(&result, free_a)
}

// The CPU strategies gain nothing from a prepared copy: never prepare.
@(test)
test_cpu_strategies_do_not_prepare :: proc(t: ^testing.T) {
	sync.mutex_lock(&strategy_tests_lock)
	defer sync.mutex_unlock(&strategy_tests_lock)
	testing.expect_value(t, evaluate_shared_negation(t), 43)
	testing.expect_value(t, packed_last_evaluation_prepares(), 0)
}

@(private = "file")
failing_prepares: int

// A prepare that fails is not retried for every rule and round.
@(test)
test_failed_prepare_is_not_retried :: proc(t: ^testing.T) {
	sync.mutex_lock(&strategy_tests_lock)
	defer sync.mutex_unlock(&strategy_tests_lock)
	failing := accel.cpu_strategy()
	failing.name = "failing_prepare"
	failing.resident_min_probes = 1
	failing.prepare_column = proc(sorted_unique: []u64) -> (rawptr, bool) {
		return nil, false
	}
	accel.select_strategy(failing)
	defer accel.use_cpu()
	testing.expect_value(t, evaluate_shared_negation(t), 43)
	testing.expect_value(t, packed_last_evaluation_prepares(), 1)
}

// Sorted by (key, row), whatever the key bits: duplicates, top-bit keys, two
// columns, and candidate rows given in increasing order (as the kernel does).
@(test)
test_packed_join_keys_sorted_by_key_then_row :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	rng := Property_Rng{state = 0xdeadbeefcafe}
	for width in 1 ..= 2 {
		n := 5000
		columns := make([][]v.Value, width, context.temp_allocator)
		for c in 0 ..< width {
			columns[c] = make([]v.Value, n, context.temp_allocator)
			for i in 0 ..< n {
				r := property_next(&rng)
				// Mix small duplicate-heavy keys with full 64-bit ones.
				columns[c][i] = v.Value(i % 3 == 0 ? r : (r % 17) | (u64(c) << 63))
			}
		}
		rows := make([dynamic]u32, context.temp_allocator)
		for i in 0 ..< n {
			if i % 4 != 1 {
				append(&rows, u32(i))
			}
		}
		keys := packed_join_keys(columns, rows[:], context.temp_allocator)
		testing.expect_value(t, len(keys.rows), len(rows))
		seen := make(map[u32]bool, context.temp_allocator)
		for j in 0 ..< len(keys.rows) {
			row := keys.rows[j]
			seen[row] = true
			for c in 0 ..< width {
				testing.expect_value(t, keys.columns[c][j], u64(columns[c][row]))
			}
			if j > 0 {
				order := accel.join_key_cmp(keys.columns, j - 1, keys.columns, j)
				testing.expectf(t, order < 0 || (order == 0 && keys.rows[j - 1] < row), "width %d: entries %d and %d out of order", width, j - 1, j)
			}
		}
		testing.expect_value(t, len(seen), len(rows))
	}
}

// Cached sorted join keys are found only at the row count they were built
// for: a relation that grew since must be packed again.
@(test)
test_packed_join_lookup_keys_on_row_count :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	cache := packed_cache_create(context.temp_allocator)
	keys := packed_join_keys([][]v.Value{{int_value(2), int_value(1)}}, []u32{0, 1}, context.temp_allocator)
	packed_join_store(cache, Relation_ID(7), []int{1}, 2, keys)
	testing.expect(t, packed_join_lookup(cache, Relation_ID(7), []int{1}, 2) != nil)
	testing.expect(t, packed_join_lookup(cache, Relation_ID(7), []int{1}, 3) == nil)
	testing.expect(t, packed_join_lookup(cache, Relation_ID(7), []int{0}, 2) == nil)
	testing.expect(t, packed_join_lookup(cache, Relation_ID(8), []int{1}, 2) == nil)
	testing.expect(t, packed_join_lookup(cache, Relation_ID(7), []int{1, 0}, 2) == nil)
}

// Packed keys of an extensional relation survive across evaluations and
// commits that leave its block alone; a commit that changes it repacks.
@(test)
test_packed_keys_shared_across_commits :: proc(t: ^testing.T) {
	sync.mutex_lock(&strategy_tests_lock)
	defer sync.mutex_unlock(&strategy_tests_lock)
	defer free_all(context.temp_allocator)
	kernel: Kernel
	kernel_init(&kernel)
	defer kernel_destroy(&kernel)
	item := create_relation(&kernel, 1, "Item", 1)
	held := create_relation(&kernel, 2, "Held", 1)
	free := create_relation(&kernel, 3, "Free", 1)
	x := v.symbol_intern("x")
	rule := rule_new(free, []Term{term_var(x)}, []Rule_Body_Item {
		body_atom(atom_positive(item, []Term{term_var(x)})),
		body_atom(atom_negated(held, []Term{term_var(x)})),
	})
	snapshot, err := kernel_install_rule(&kernel, v.Identity(960), rule, "Free(x) :- Item(x), not Held(x).")
	testing.expect_value(t, err, Kernel_Error.None)
	snapshot_release(snapshot)
	commit :: proc(t: ^testing.T, kernel: ^Kernel, relation: Relation_ID, n: int) {
		tx := kernel_begin(kernel)
		transaction_assert(&tx, relation, tuple_of(must_identity(u64(n))))
		commit_transaction(t, &tx)
	}
	for i in 1 ..= 40 {
		commit(t, &kernel, item, i)
	}
	commit(t, &kernel, held, 3)
	testing.expect_value(t, packed_last_evaluation_builds(), 1) // Held changed: packed
	commit(t, &kernel, item, 41)
	testing.expect_value(t, packed_last_evaluation_builds(), 0) // Held unchanged: shared
	commit(t, &kernel, held, 5)
	testing.expect_value(t, packed_last_evaluation_builds(), 1) // Held changed again
	rows := snapshot_derived_rows(kernel.current, free)
	testing.expect_value(t, len(rows), 39)
	testing.expect(t, !has_tuple(rows, tuple_of(must_identity(3))))
	testing.expect(t, !has_tuple(rows, tuple_of(must_identity(5))))
}
