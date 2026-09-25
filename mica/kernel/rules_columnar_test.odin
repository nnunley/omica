package kernel

import "core:mem/virtual"
import "core:sync"
import "core:testing"
import v "../var"

@(private = "file")
evaluate_rows :: proc(t: ^testing.T, kernel: ^Kernel, source: ^Relation_Source, relation: Relation_ID) -> (rows: []v.Tuple, err: Kernel_Error) {
	arena: virtual.Arena
	testing.expect(t, virtual.arena_init_growing(&arena) == nil)
	defer virtual.arena_destroy(&arena)
	alloc := virtual.arena_allocator(&arena)
	result := rules_derived_create(alloc)
	source.derived = &result
	err = rules_evaluate_source(alloc, kernel.current.rules, source, &result)
	rows = rules_derived_tuples(&result, relation, context.temp_allocator)
	source.derived = nil
	return
}

@(private = "file")
install :: proc(t: ^testing.T, kernel: ^Kernel, id: u64, rule: Rule) {
	snapshot, err := kernel_install_rule(kernel, v.Identity(id), rule, "columnar test")
	testing.expect_value(t, err, Kernel_Error.None)
	snapshot_release(snapshot)
}

// Review Focus 1: a scanner that ignores its binding and returns every
// candidate; the index path re-checks keys with value_eq.
@(test)
test_columnar_computed_candidates_rechecked :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	kernel: Kernel
	kernel_init(&kernel)
	defer kernel_destroy(&kernel)
	item := create_relation(&kernel, 1, "Item", 1)
	candidates := create_relation(&kernel, 2, "Candidates", 1)
	out := create_relation(&kernel, 3, "Out", 1)
	testing.expect_value(t, kernel_register_computed_relation(&kernel, candidates, []u16{0},
		proc(user: rawptr, source: ^Relation_Source, bindings: []v.Binding, visit: Computed_Visit_Proc, visit_user: rawptr) -> Kernel_Error {
			for n in 1 ..= 4 {
				value, _ := v.value_int(i64(n))
				visit(visit_user, v.tuple_new(context.temp_allocator, []v.Value{value}))
			}
			return .None
		}), Kernel_Error.None)
	x := v.symbol_intern("x")
	install(t, &kernel, 900, rule_new(out, []Term{term_var(x)}, []Rule_Body_Item {
		body_atom(atom_positive(item, []Term{term_var(x)})),
		body_atom(atom_positive(candidates, []Term{term_var(x)})),
	}))
	tx := kernel_begin(&kernel)
	transaction_assert(&tx, item, tuple_of(must_int(2)))
	transaction_assert(&tx, item, tuple_of(must_int(9)))
	commit_transaction(t, &tx)
	source := Relation_Source{kernel = &kernel, snapshot = kernel.current}
	rows, err := evaluate_rows(t, &kernel, &source, out)
	testing.expect_value(t, err, Kernel_Error.None)
	testing.expect_value(t, len(rows), 1)
	testing.expect(t, has_tuple(rows, tuple_of(must_int(2))))
}

// Review Focus 2.
@(test)
test_columnar_zero_arity_head :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	kernel: Kernel
	kernel_init(&kernel)
	defer kernel_destroy(&kernel)
	item := create_relation(&kernel, 1, "Item", 1)
	flag := create_relation(&kernel, 2, "Flag", 0)
	x := v.symbol_intern("x")
	install(t, &kernel, 901, rule_new(flag, nil, []Rule_Body_Item{body_atom(atom_positive(item, []Term{term_var(x)}))}))
	tx := kernel_begin(&kernel)
	for i in 1 ..= 40 {
		transaction_assert(&tx, item, tuple_of(must_int(i64(i))))
	}
	commit_transaction(t, &tx)
	testing.expect_value(t, len(snapshot_derived_rows(kernel.current, flag)), 1)
}

// Review Focus 3.
@(test)
test_columnar_permission_denied_in_body :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	kernel: Kernel
	kernel_init(&kernel)
	defer kernel_destroy(&kernel)
	item := create_relation(&kernel, 1, "Item", 1)
	held := create_relation(&kernel, 2, "Held", 1)
	free := create_relation(&kernel, 3, "Free", 1)
	x := v.symbol_intern("x")
	install(t, &kernel, 902, rule_new(free, []Term{term_var(x)}, []Rule_Body_Item {
		body_atom(atom_positive(item, []Term{term_var(x)})),
		body_atom(atom_negated(held, []Term{term_var(x)})),
	}))
	tx := kernel_begin(&kernel)
	transaction_assert(&tx, item, tuple_of(must_int(1)))
	commit_transaction(t, &tx)

	authority := Authority{allocator = context.allocator}
	authority.read = make(map[Relation_ID]bool, context.temp_allocator)
	authority.read[item] = true // Held is unreadable
	source := Relation_Source{kernel = &kernel, snapshot = kernel.current, authority = &authority}
	_, err := evaluate_rows(t, &kernel, &source, free)
	testing.expect_value(t, err, Kernel_Error.Permission_Denied)

	delete_key(&authority.read, item) // now the positive atom is unreadable too
	source = Relation_Source{kernel = &kernel, snapshot = kernel.current, authority = &authority}
	_, err = evaluate_rows(t, &kernel, &source, free)
	testing.expect_value(t, err, Kernel_Error.Permission_Denied)
}

// Review Focus 4: Item is empty, so the batch empties before Even (whose key
// Item would bind) runs; like the row evaluator, no error and no rows.
@(test)
test_columnar_empty_batch_skips_remaining_steps :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	kernel: Kernel
	kernel_init(&kernel)
	defer kernel_destroy(&kernel)
	item := create_relation(&kernel, 1, "Item", 1)
	even := create_relation(&kernel, 2, "Even", 1)
	out := create_relation(&kernel, 3, "Out", 1)
	testing.expect_value(t, kernel_register_computed_relation(&kernel, even, []u16{0},
		proc(user: rawptr, source: ^Relation_Source, bindings: []v.Binding, visit: Computed_Visit_Proc, visit_user: rawptr) -> Kernel_Error {
			return .None
		}), Kernel_Error.None)
	x := v.symbol_intern("x")
	install(t, &kernel, 903, rule_new(out, []Term{term_var(x)}, []Rule_Body_Item {
		body_atom(atom_positive(item, []Term{term_var(x)})),
		body_atom(atom_positive(even, []Term{term_var(x)})),
	}))
	source := Relation_Source{kernel = &kernel, snapshot = kernel.current}
	rows, err := evaluate_rows(t, &kernel, &source, out)
	testing.expect_value(t, err, Kernel_Error.None)
	testing.expect_value(t, len(rows), 0)
}

// Review Focus 5: heap-value keys are Not_Packable and take the hashed path;
// equal strings from distinct allocations negate each other.
@(test)
test_columnar_negation_heap_values :: proc(t: ^testing.T) {
	sync.mutex_lock(&strategy_tests_lock)
	defer sync.mutex_unlock(&strategy_tests_lock)
	defer free_all(context.temp_allocator)
	kernel: Kernel
	kernel_init(&kernel)
	defer kernel_destroy(&kernel)
	name := create_relation(&kernel, 1, "Name", 1)
	banned := create_relation(&kernel, 2, "Banned", 1)
	ok := create_relation(&kernel, 3, "Ok", 1)
	x := v.symbol_intern("x")
	install(t, &kernel, 904, rule_new(ok, []Term{term_var(x)}, []Rule_Body_Item {
		body_atom(atom_positive(name, []Term{term_var(x)})),
		body_atom(atom_negated(banned, []Term{term_var(x)})),
	}))
	before := placement_counts_this_thread()
	tx := kernel_begin(&kernel)
	transaction_assert(&tx, name, tuple_of(v.value_string(context.temp_allocator, "ann")))
	transaction_assert(&tx, name, tuple_of(v.value_string(context.temp_allocator, "bob")))
	transaction_assert(&tx, banned, tuple_of(v.value_string(context.temp_allocator, "bob")))
	commit_transaction(t, &tx)
	delta := placement_counts_delta(before, placement_counts_this_thread())
	testing.expect(t, delta[.Negated_Membership][.Not_Packable] >= 1)
	rows := snapshot_derived_rows(kernel.current, ok)
	testing.expect_value(t, len(rows), 1)
	testing.expect(t, has_tuple(rows, tuple_of(v.value_string(context.temp_allocator, "ann"))))
}

// A join keyed on a bound slot gives the same rows on the hash-join and the
// per-row index path.
@(test)
test_columnar_join_paths_agree :: proc(t: ^testing.T) {
	sync.mutex_lock(&strategy_tests_lock)
	defer sync.mutex_unlock(&strategy_tests_lock)
	defer free_all(context.temp_allocator)
	previous := rules_small_batch_rows
	defer rules_small_batch_rows = previous
	kernel: Kernel
	kernel_init(&kernel)
	defer kernel_destroy(&kernel)
	edge := create_relation(&kernel, 1, "Edge", 2)
	two := create_relation(&kernel, 2, "Two", 2)
	x, y, z := v.symbol_intern("x"), v.symbol_intern("y"), v.symbol_intern("z")
	install(t, &kernel, 905, rule_new(two, []Term{term_var(x), term_var(z)}, []Rule_Body_Item {
		body_atom(atom_positive(edge, []Term{term_var(x), term_var(y)})),
		body_atom(atom_positive(edge, []Term{term_var(y), term_var(z)})),
	}))
	tx := kernel_begin(&kernel)
	for i in 0 ..< 60 {
		transaction_assert(&tx, edge, tuple_of(must_int(i64(i % 20)), must_int(i64((i * 7) % 20))))
	}
	commit_transaction(t, &tx)
	want := len(snapshot_derived_rows(kernel.current, two))
	testing.expect(t, want > 0)
	for threshold in ([]int{0, max(int)}) {
		rules_small_batch_rows = threshold
		source := Relation_Source{kernel = &kernel, snapshot = kernel.current}
		rows, err := evaluate_rows(t, &kernel, &source, two)
		testing.expect_value(t, err, Kernel_Error.None)
		testing.expect_value(t, len(rows), want)
	}
}

@(private = "file")
Hidden_User :: struct {
	hidden: Relation_ID,
}

// A computed relation whose scanner reads a backing relation the authority
// cannot read reports the denial only through source.error; the columnar scan
// must surface it, for positive and negated atoms alike (the row evaluator
// checked source.error after every visit).
@(test)
test_columnar_nested_denial_in_computed_scanner :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	for negated in ([]bool{false, true}) {
		kernel: Kernel
		kernel_init(&kernel)
		item := create_relation(&kernel, 1, "Item", 1)
		hidden := create_relation(&kernel, 2, "Hidden", 1)
		c := create_relation(&kernel, 3, "C", 1)
		out := create_relation(&kernel, 4, "Out", 1)
		user := new(Hidden_User, context.temp_allocator)
		user.hidden = hidden
		testing.expect_value(t, kernel_register_computed_relation(&kernel, c, nil,
			proc(u: rawptr, source: ^Relation_Source, bindings: []v.Binding, visit: Computed_Visit_Proc, visit_user: rawptr) -> Kernel_Error {
				rows := make([dynamic]v.Tuple, context.temp_allocator)
				relation_source_scan_into(source, (^Hidden_User)(u).hidden, []v.Binding{{}}, &rows)
				for row in rows {
					visit(visit_user, row)
				}
				return .None
			}, user), Kernel_Error.None)
		x := v.symbol_intern("x")
		atom := negated ? atom_negated(c, []Term{term_var(x)}) : atom_positive(c, []Term{term_var(x)})
		install(t, &kernel, 906, rule_new(out, []Term{term_var(x)}, []Rule_Body_Item {
			body_atom(atom_positive(item, []Term{term_var(x)})),
			body_atom(atom),
		}))
		tx := kernel_begin(&kernel)
		transaction_assert(&tx, item, tuple_of(must_int(1)))
		transaction_assert(&tx, hidden, tuple_of(must_int(1)))
		commit_transaction(t, &tx)

		authority := Authority{allocator = context.allocator}
		authority.read = make(map[Relation_ID]bool, context.temp_allocator)
		authority.read[item] = true
		authority.read[c] = true
		source := Relation_Source{kernel = &kernel, snapshot = kernel.current, authority = &authority}
		_, err := evaluate_rows(t, &kernel, &source, out)
		testing.expectf(t, err == .Permission_Denied, "negated=%v: got %v", negated, err)
		kernel_destroy(&kernel)
	}
}
