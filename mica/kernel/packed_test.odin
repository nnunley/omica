package kernel

import "core:mem/virtual"
import "core:sync"
import "core:testing"
import accel "./accel"
import v "../var"

@(private = "file")
row :: proc(values: ..v.Value) -> v.Tuple {
	return v.tuple_new(context.temp_allocator, values)
}

@(private = "file")
int_value :: proc(n: i64) -> v.Value {
	value, _ := v.value_int(n)
	return value
}

@(test)
test_packed_keys_single_position_sorted_unique :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	rows := []v.Tuple{row(int_value(3), int_value(1)), row(int_value(1), int_value(2)), row(int_value(3), int_value(9))}
	keys, ok := packed_keys_from_rows(rows, []u16{0}, context.temp_allocator)
	testing.expect(t, ok)
	testing.expect_value(t, keys.width, 1)
	testing.expect_value(t, keys.count, 2)
	testing.expect_value(t, keys.keys[0], u64(int_value(1)))
	testing.expect_value(t, keys.keys[1], u64(int_value(3)))
}

@(test)
test_packed_keys_pairs_sorted_unique :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	a, b := must_identity(7), must_identity(5)
	rows := []v.Tuple{row(a, b), row(b, a), row(a, b), row(b, b)}
	keys, ok := packed_keys_from_rows(rows, []u16{0, 1}, context.temp_allocator)
	testing.expect(t, ok)
	testing.expect_value(t, keys.width, 2)
	testing.expect_value(t, keys.count, 3)
	for i in 1 ..< keys.count {
		p0, p1, q0, q1 := keys.keys[2 * i - 2], keys.keys[2 * i - 1], keys.keys[2 * i], keys.keys[2 * i + 1]
		testing.expect(t, p0 < q0 || (p0 == q0 && p1 < q1))
	}
}

@(test)
test_packed_keys_reject_heap_values_and_bad_widths :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	text := v.value_string(context.temp_allocator, "heap")
	_, heap_ok := packed_keys_from_rows([]v.Tuple{row(text)}, []u16{0}, context.temp_allocator)
	testing.expect(t, !heap_ok)
	_, wide_ok := packed_keys_from_rows([]v.Tuple{row(int_value(1), int_value(2), int_value(3))}, []u16{0, 1, 2}, context.temp_allocator)
	testing.expect(t, !wide_ok)
	_, short_ok := packed_keys_from_rows([]v.Tuple{row(int_value(1))}, []u16{1}, context.temp_allocator)
	testing.expect(t, !short_ok)
	empty, empty_ok := packed_keys_from_rows(nil, []u16{0}, context.temp_allocator)
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
	testing.expect_value(t, packed_last_evaluation_builds(), 1)
	testing.expect_value(t, len(rules_derived_rows(&result, free_a)), 43)
	testing.expect_value(t, len(rules_derived_rows(&result, free_b)), 43)
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
	return len(rules_derived_rows(&result, free_a))
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
