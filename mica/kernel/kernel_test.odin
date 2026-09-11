package kernel

import "core:testing"
import v "../var"

@(private)
must_int :: proc(n: i64) -> v.Value {
	value, ok := v.value_int(n)
	assert(ok)
	return value
}

@(private)
must_identity :: proc(raw: u64) -> v.Value {
	value, ok := v.value_identity_raw(raw)
	assert(ok)
	return value
}

@(private)
sym :: proc(name: string) -> v.Value {
	return v.value_symbol(v.symbol_intern(name))
}

@(private)
tuple_of :: proc(values: ..v.Value) -> v.Tuple {
	return v.tuple_new(context.temp_allocator, values)
}

@(private)
create_relation :: proc(
	kernel: ^Kernel,
	id: u32,
	name: string,
	arity: u16,
) -> Relation_ID {
	return create_relation_with(kernel, id, name, arity, conflict_set(), nil)
}

@(private)
create_relation_with :: proc(
	kernel: ^Kernel,
	id: u32,
	name: string,
	arity: u16,
	conflict: Conflict_Policy,
	indexes: []Index_Spec,
) -> Relation_ID {
	metadata := relation_metadata(Relation_ID(id), v.symbol_intern(name), arity)
	metadata.conflict = conflict
	metadata.indexes = indexes
	snapshot, err := kernel_create_relation(kernel, metadata)
	assert(err == .None)
	snapshot_release(snapshot)
	return Relation_ID(id)
}

@(private)
commit_transaction :: proc(t: ^testing.T, tx: ^Transaction) {
	snapshot, err := transaction_commit(tx)
	testing.expect_value(t, err, Kernel_Error.None)
	snapshot_release(snapshot)
	transaction_destroy(tx)
}

@(private)
kernel_rows :: proc(kernel: ^Kernel, relation: Relation_ID, arity: int) -> [dynamic]v.Tuple {
	bindings := make([]v.Binding, arity, context.temp_allocator)
	rows: [dynamic]v.Tuple
	kernel_scan_into(kernel, relation, bindings, &rows)
	return rows
}

@(private)
transaction_rows :: proc(tx: ^Transaction, relation: Relation_ID, arity: int) -> [dynamic]v.Tuple {
	bindings := make([]v.Binding, arity, context.temp_allocator)
	rows: [dynamic]v.Tuple
	transaction_scan_extensional_into(tx, relation, bindings, &rows)
	if err := transaction_evaluate_derived(tx); err != .None {
		panic("transaction rule evaluation failed")
	}
	for row in transaction_derived_rows(tx, relation) {
		if v.tuple_matches_bindings(row, bindings) {
			append(&rows, row)
		}
	}
	return rows
}

@(private)
has_tuple :: proc(rows: []v.Tuple, tuple: v.Tuple) -> bool {
	for row in rows {
		if v.tuple_eq(row, tuple) {
			return true
		}
	}
	return false
}

@(private)
churn_temp :: proc() {
	for _ in 0 ..< 256 {
		data := make([]u8, 4096, context.temp_allocator)
		for i in 0 ..< len(data) {
			data[i] = 0xAA
		}
	}
}

@(test)
test_transaction_owns_asserted_values :: proc(t: ^testing.T) {
	kernel: Kernel
	kernel_init(&kernel)
	defer kernel_destroy(&kernel)

	relation := create_relation(&kernel, 1, "Label", 2)
	lamp := must_identity(1)

	tx := kernel_begin(&kernel)
	// The tuple and its string are allocated from caller scratch memory. The
	// transaction must copy them so the snapshot does not reference scratch
	// storage.
	transaction_assert(
		&tx,
		relation,
		tuple_of(lamp, v.value_string(context.temp_allocator, "ephemeral label")),
	)
	churn_temp()
	commit_transaction(t, &tx)

	rows := kernel_rows(&kernel, relation, 2)
	testing.expect_value(t, len(rows), 1)
	if len(rows) == 1 {
		label, is_string := v.value_as_string(v.tuple_values(rows[0])[1])
		testing.expect(t, is_string)
		testing.expect_value(t, label, "ephemeral label")
	}
	delete(rows)
}

@(test)
test_transaction_assert_retract_and_read_your_writes :: proc(t: ^testing.T) {
	kernel: Kernel
	kernel_init(&kernel)
	defer kernel_destroy(&kernel)

	held_by := create_relation(&kernel, 1, "HeldBy", 2)
	alice := must_identity(1)
	lamp := must_identity(2)

	tx := kernel_begin(&kernel)
	testing.expect_value(
		t,
		transaction_assert(&tx, held_by, tuple_of(alice, lamp)),
		Kernel_Error.None,
	)

	uncommitted := kernel_rows(&kernel, held_by, 2)
	testing.expect_value(t, len(uncommitted), 0)
	delete(uncommitted)

	visible := transaction_rows(&tx, held_by, 2)
	testing.expect(t, has_tuple(visible[:], tuple_of(alice, lamp)))
	delete(visible)

	commit_transaction(t, &tx)

	committed := kernel_rows(&kernel, held_by, 2)
	testing.expect(t, has_tuple(committed[:], tuple_of(alice, lamp)))
	delete(committed)

	// Retraction is visible in the transaction and after commit.
	tx2 := kernel_begin(&kernel)
	testing.expect_value(
		t,
		transaction_retract(&tx2, held_by, tuple_of(alice, lamp)),
		Kernel_Error.None,
	)
	after_retract := transaction_rows(&tx2, held_by, 2)
	testing.expect_value(t, len(after_retract), 0)
	delete(after_retract)
	commit_transaction(t, &tx2)

	final := kernel_rows(&kernel, held_by, 2)
	testing.expect_value(t, len(final), 0)
	delete(final)
}

@(test)
test_transaction_write_last_kind_wins :: proc(t: ^testing.T) {
	kernel: Kernel
	kernel_init(&kernel)
	defer kernel_destroy(&kernel)

	relation := create_relation(&kernel, 1, "Flag", 1)
	value := must_int(7)

	tx := kernel_begin(&kernel)
	transaction_assert(&tx, relation, tuple_of(value))
	transaction_retract(&tx, relation, tuple_of(value))
	transaction_assert(&tx, relation, tuple_of(value))
	commit_transaction(t, &tx)

	rows := kernel_rows(&kernel, relation, 1)
	testing.expect(t, has_tuple(rows[:], tuple_of(value)))
	delete(rows)
}

@(test)
test_transaction_rebase_merges_non_conflicting_writes :: proc(t: ^testing.T) {
	kernel: Kernel
	kernel_init(&kernel)
	defer kernel_destroy(&kernel)

	relation := create_relation(&kernel, 1, "HeldBy", 2)
	tuple_a := tuple_of(must_identity(1), must_identity(2))
	tuple_b := tuple_of(must_identity(3), must_identity(4))

	slow := kernel_begin(&kernel)
	fast := kernel_begin(&kernel)

	transaction_assert(&fast, relation, tuple_a)
	commit_transaction(t, &fast)

	transaction_assert(&slow, relation, tuple_b)
	commit_transaction(t, &slow)

	rows := kernel_rows(&kernel, relation, 2)
	testing.expect(t, has_tuple(rows[:], tuple_a))
	testing.expect(t, has_tuple(rows[:], tuple_b))
	delete(rows)
}

@(test)
test_transaction_set_conflict_detects_concurrent_retract :: proc(t: ^testing.T) {
	kernel: Kernel
	kernel_init(&kernel)
	defer kernel_destroy(&kernel)

	relation := create_relation(&kernel, 1, "HeldBy", 2)
	tuple := tuple_of(must_identity(1), must_identity(2))

	seed := kernel_begin(&kernel)
	transaction_assert(&seed, relation, tuple)
	commit_transaction(t, &seed)

	slow := kernel_begin(&kernel)
	fast := kernel_begin(&kernel)

	transaction_retract(&fast, relation, tuple)
	commit_transaction(t, &fast)

	testing.expect_value(
		t,
		transaction_assert(&slow, relation, tuple),
		Kernel_Error.None,
	)
	snapshot, err := transaction_commit(&slow)
	testing.expect_value(t, err, Kernel_Error.Conflict)
	if snapshot != nil {
		snapshot_release(snapshot)
	}
	transaction_destroy(&slow)
}

@(test)
test_functional_relation_key_violation_and_replacement :: proc(t: ^testing.T) {
	kernel: Kernel
	kernel_init(&kernel)
	defer kernel_destroy(&kernel)

	keys := [1]u16{0}
	name := create_relation_with(&kernel, 1, "Name", 2, conflict_functional(keys[:]), nil)
	lamp := must_identity(1)

	tx := kernel_begin(&kernel)
	transaction_assert(&tx, name, tuple_of(lamp, v.value_string(context.temp_allocator, "brass lamp")))
	commit_transaction(t, &tx)

	tx2 := kernel_begin(&kernel)
	testing.expect_value(
		t,
		transaction_assert(&tx2, name, tuple_of(lamp, v.value_string(context.temp_allocator, "silver lamp"))),
		Kernel_Error.Functional_Key_Violation,
	)

	old := tuple_of(lamp, v.value_string(context.temp_allocator, "brass lamp"))
	new_value := v.value_string(context.temp_allocator, "silver lamp")
	transaction_retract(&tx2, name, old)
	testing.expect_value(
		t,
		transaction_assert(&tx2, name, tuple_of(lamp, new_value)),
		Kernel_Error.None,
	)
	commit_transaction(t, &tx2)

	rows := kernel_rows(&kernel, name, 2)
	testing.expect_value(t, len(rows), 1)
	testing.expect(t, has_tuple(rows[:], tuple_of(lamp, new_value)))
	delete(rows)
}

@(test)
test_functional_relation_conflict_on_key_change :: proc(t: ^testing.T) {
	kernel: Kernel
	kernel_init(&kernel)
	defer kernel_destroy(&kernel)

	keys := [1]u16{0}
	name := create_relation_with(&kernel, 1, "Name", 2, conflict_functional(keys[:]), nil)
	lamp := must_identity(1)
	old := tuple_of(lamp, v.value_string(context.temp_allocator, "old"))

	seed := kernel_begin(&kernel)
	transaction_assert(&seed, name, old)
	commit_transaction(t, &seed)

	slow := kernel_begin(&kernel)
	fast := kernel_begin(&kernel)

	transaction_retract(&fast, name, old)
	transaction_assert(&fast, name, tuple_of(lamp, v.value_string(context.temp_allocator, "fast")))
	commit_transaction(t, &fast)

	transaction_retract(&slow, name, old)
	transaction_assert(&slow, name, tuple_of(lamp, v.value_string(context.temp_allocator, "slow")))
	snapshot, err := transaction_commit(&slow)
	testing.expect_value(t, err, Kernel_Error.Conflict)
	if snapshot != nil {
		snapshot_release(snapshot)
	}
	transaction_destroy(&slow)
}

@(test)
test_secondary_index_scan_returns_matching_rows :: proc(t: ^testing.T) {
	kernel: Kernel
	kernel_init(&kernel)
	defer kernel_destroy(&kernel)

	indexes := [1]Index_Spec{index_spec([]u16{1, 2})}
	relation := create_relation_with(&kernel, 1, "Located", 3, conflict_set(), indexes[:])

	tx := kernel_begin(&kernel)
	transaction_assert(&tx, relation, tuple_of(must_identity(1), must_identity(10), must_int(0)))
	transaction_assert(&tx, relation, tuple_of(must_identity(2), must_identity(10), must_int(1)))
	transaction_assert(&tx, relation, tuple_of(must_identity(3), must_identity(20), must_int(0)))
	commit_transaction(t, &tx)

	bindings := []v.Binding{{}, v.binding_of(must_identity(10)), {}}
	rows: [dynamic]v.Tuple
	kernel_scan_into(&kernel, relation, bindings, &rows)
	testing.expect_value(t, len(rows), 2)
	delete(rows)
}

@(test)
test_transitive_rule_derives_reachable :: proc(t: ^testing.T) {
	kernel: Kernel
	kernel_init(&kernel)
	defer kernel_destroy(&kernel)

	exit := create_relation(&kernel, 1, "Exit", 2)
	reachable := create_relation(&kernel, 2, "Reachable", 2)

	from := v.symbol_intern("from")
	to := v.symbol_intern("to")
	mid := v.symbol_intern("mid")

	base_rule := rule_new(
		reachable,
		[]Term{term_var(from), term_var(to)},
		[]Rule_Body_Item {
			body_atom(atom_positive(exit, []Term{term_var(from), term_var(to)})),
		},
	)
	recursive_rule := rule_new(
		reachable,
		[]Term{term_var(from), term_var(to)},
		[]Rule_Body_Item {
			body_atom(atom_positive(exit, []Term{term_var(from), term_var(mid)})),
			body_atom(atom_positive(reachable, []Term{term_var(mid), term_var(to)})),
		},
	)

	snapshot, err := kernel_install_rule(&kernel, v.Identity(100), base_rule, "Reachable(f,t) :- Exit(f,t).")
	testing.expect_value(t, err, Kernel_Error.None)
	snapshot_release(snapshot)
	snapshot, err = kernel_install_rule(&kernel, v.Identity(101), recursive_rule, "Reachable(f,t) :- Exit(f,m), Reachable(m,t).")
	testing.expect_value(t, err, Kernel_Error.None)
	snapshot_release(snapshot)

	a := must_identity(1)
	b := must_identity(2)
	c := must_identity(3)
	d := must_identity(4)

	tx := kernel_begin(&kernel)
	transaction_assert(&tx, exit, tuple_of(a, b))
	transaction_assert(&tx, exit, tuple_of(b, c))
	transaction_assert(&tx, exit, tuple_of(c, d))

	// Derived facts are visible inside the transaction.
	in_tx := transaction_rows(&tx, reachable, 2)
	testing.expect(t, has_tuple(in_tx[:], tuple_of(a, c)))
	testing.expect(t, has_tuple(in_tx[:], tuple_of(a, d)))
	delete(in_tx)

	commit_transaction(t, &tx)

	rows := kernel_rows(&kernel, reachable, 2)
	testing.expect(t, has_tuple(rows[:], tuple_of(a, b)))
	testing.expect(t, has_tuple(rows[:], tuple_of(a, c)))
	testing.expect(t, has_tuple(rows[:], tuple_of(a, d)))
	testing.expect(t, has_tuple(rows[:], tuple_of(b, d)))
	testing.expect_value(t, len(rows), 6)
	delete(rows)
}

@(test)
test_stratified_negation_updates_with_facts :: proc(t: ^testing.T) {
	kernel: Kernel
	kernel_init(&kernel)
	defer kernel_destroy(&kernel)

	item := create_relation(&kernel, 1, "Item", 1)
	held := create_relation(&kernel, 2, "Held", 1)
	free := create_relation(&kernel, 3, "Free", 1)

	x := v.symbol_intern("x")
	rule := rule_new(
		free,
		[]Term{term_var(x)},
		[]Rule_Body_Item {
			body_atom(atom_positive(item, []Term{term_var(x)})),
			body_atom(atom_negated(held, []Term{term_var(x)})),
		},
	)
	snapshot, err := kernel_install_rule(&kernel, v.Identity(200), rule, "Free(x) :- Item(x), not Held(x).")
	testing.expect_value(t, err, Kernel_Error.None)
	snapshot_release(snapshot)

	coin := must_identity(1)
	tx := kernel_begin(&kernel)
	transaction_assert(&tx, item, tuple_of(coin))
	commit_transaction(t, &tx)

	rows := kernel_rows(&kernel, free, 1)
	testing.expect(t, has_tuple(rows[:], tuple_of(coin)))
	delete(rows)

	tx2 := kernel_begin(&kernel)
	transaction_assert(&tx2, held, tuple_of(coin))
	commit_transaction(t, &tx2)

	rows2 := kernel_rows(&kernel, free, 1)
	testing.expect(t, !has_tuple(rows2[:], tuple_of(coin)))
	delete(rows2)
}

@(test)
test_rule_guard_comparisons :: proc(t: ^testing.T) {
	kernel: Kernel
	kernel_init(&kernel)
	defer kernel_destroy(&kernel)

	number := create_relation(&kernel, 1, "Number", 1)
	big := create_relation(&kernel, 2, "Big", 1)

	x := v.symbol_intern("x")
	rule := rule_new(
		big,
		[]Term{term_var(x)},
		[]Rule_Body_Item {
			body_atom(atom_positive(number, []Term{term_var(x)})),
			body_guard(rule_guard(.Gt, term_var(x), term_value(must_int(10)))),
		},
	)
	snapshot, err := kernel_install_rule(&kernel, v.Identity(300), rule, "Big(x) :- Number(x), x > 10.")
	testing.expect_value(t, err, Kernel_Error.None)
	snapshot_release(snapshot)

	tx := kernel_begin(&kernel)
	transaction_assert(&tx, number, tuple_of(must_int(5)))
	transaction_assert(&tx, number, tuple_of(must_int(11)))
	transaction_assert(&tx, number, tuple_of(must_int(100)))
	commit_transaction(t, &tx)

	rows := kernel_rows(&kernel, big, 1)
	testing.expect_value(t, len(rows), 2)
	testing.expect(t, has_tuple(rows[:], tuple_of(must_int(11))))
	testing.expect(t, has_tuple(rows[:], tuple_of(must_int(100))))
	testing.expect(t, !has_tuple(rows[:], tuple_of(must_int(5))))
	delete(rows)
}

@(test)
test_unsafe_and_unstratified_rules_are_rejected :: proc(t: ^testing.T) {
	kernel: Kernel
	kernel_init(&kernel)
	defer kernel_destroy(&kernel)

	base := create_relation(&kernel, 1, "Base", 1)
	derived := create_relation(&kernel, 2, "Derived", 1)

	x := v.symbol_intern("x")

	unsafe := rule_new(
		derived,
		[]Term{term_var(x)},
		[]Rule_Body_Item {
			body_atom(atom_negated(base, []Term{term_var(x)})),
		},
	)
	_, unsafe_err := kernel_install_rule(&kernel, v.Identity(1), unsafe, "Derived(x) :- not Base(x).")
	testing.expect_value(t, unsafe_err, Kernel_Error.Unsafe_Negation)

	unstratified := rule_new(
		derived,
		[]Term{term_var(x)},
		[]Rule_Body_Item {
			body_atom(atom_positive(base, []Term{term_var(x)})),
			body_atom(atom_negated(derived, []Term{term_var(x)})),
		},
	)
	_, unstratified_err := kernel_install_rule(
		&kernel,
		v.Identity(2),
		unstratified,
		"Derived(x) :- Base(x), not Derived(x).",
	)
	testing.expect_value(t, unstratified_err, Kernel_Error.Unstratified_Negation)
}

@(test)
test_delegates_star_and_reaches :: proc(t: ^testing.T) {
	kernel: Kernel
	kernel_init(&kernel)
	defer kernel_destroy(&kernel)

	delegates := create_relation(&kernel, 1, "Delegates", 3)

	tx := kernel_begin(&kernel)
	transaction_assert(&tx, delegates, tuple_of(must_identity(1), must_identity(2), must_int(0)))
	transaction_assert(&tx, delegates, tuple_of(must_identity(2), must_identity(3), must_int(0)))
	transaction_assert(&tx, delegates, tuple_of(must_identity(4), must_identity(5), must_int(0)))
	commit_transaction(t, &tx)

	source := Relation_Source{snapshot = kernel.current, use_stored_derived = true}
	testing.expect(
		t,
		delegates_reaches(&source, delegates, must_identity(1), must_identity(3)),
	)
	testing.expect(
		t,
		!delegates_reaches(&source, delegates, must_identity(1), must_identity(4)),
	)

	prototypes := delegates_star_from(&source, delegates, must_identity(1), context.temp_allocator)
	testing.expect_value(t, len(prototypes), 2)
}

@(test)
test_dispatch_matches_through_delegation :: proc(t: ^testing.T) {
	kernel: Kernel
	kernel_init(&kernel)
	defer kernel_destroy(&kernel)

	method_selector := create_relation(&kernel, 40, "MethodSelector", 2)
	param := create_relation(&kernel, 41, "Param", 4)
	delegates := create_relation(&kernel, 42, "Delegates", 3)
	relations := Dispatch_Relations {
		method_selector = method_selector,
		param           = param,
		delegates       = delegates,
	}

	tx := kernel_begin(&kernel)
	method := must_int(100)
	actor := must_identity(10)
	item := must_identity(1)
	player := must_identity(11)
	thing := must_identity(2)

	transaction_assert(&tx, method_selector, tuple_of(method, sym("take")))
	transaction_assert(&tx, param, tuple_of(method, sym("actor"), player, must_int(0)))
	transaction_assert(&tx, param, tuple_of(method, sym("item"), thing, must_int(1)))
	transaction_assert(&tx, delegates, tuple_of(actor, player, must_int(0)))
	transaction_assert(&tx, delegates, tuple_of(item, thing, must_int(0)))

	source := Relation_Source{transaction = &tx, use_stored_derived = true}
	roles := []Role_Pair {
		{role = sym("actor"), value = actor},
		{role = sym("item"), value = item},
	}
	methods := applicable_methods(&source, relations, sym("take"), roles, context.temp_allocator)
	testing.expect_value(t, len(methods), 1)
	if len(methods) == 1 {
		testing.expect(t, v.value_eq(methods[0], method))
	}
	commit_transaction(t, &tx)
}

@(test)
test_dispatch_open_signature_and_unrestricted_params :: proc(t: ^testing.T) {
	kernel: Kernel
	kernel_init(&kernel)
	defer kernel_destroy(&kernel)

	method_selector := create_relation(&kernel, 40, "MethodSelector", 2)
	param := create_relation(&kernel, 41, "Param", 4)
	delegates := create_relation(&kernel, 42, "Delegates", 3)
	relations := Dispatch_Relations {
		method_selector = method_selector,
		param           = param,
		delegates       = delegates,
	}

	tx := kernel_begin(&kernel)
	method := must_int(100)
	transaction_assert(&tx, method_selector, tuple_of(method, sym("say")))
	transaction_assert(
		&tx,
		param,
		tuple_of(method, sym("message"), unrestricted_dispatch_restriction(), must_int(0)),
	)

	source := Relation_Source{transaction = &tx, use_stored_derived = true}

	// Missing role means not applicable (open signature).
	missing := applicable_methods(
		&source,
		relations,
		sym("say"),
		[]Role_Pair{{role = sym("actor"), value = must_identity(10)}},
		context.temp_allocator,
	)
	testing.expect_value(t, len(missing), 0)

	// Extra roles are ignored.
	present := applicable_methods(
		&source,
		relations,
		sym("say"),
		[]Role_Pair {
			{role = sym("actor"), value = must_identity(10)},
			{role = sym("message"), value = v.value_string(context.temp_allocator, "hi")},
			{role = sym("extra"), value = must_int(3)},
		},
		context.temp_allocator,
	)
	testing.expect_value(t, len(present), 1)
	commit_transaction(t, &tx)
}

@(test)
test_dispatch_matches_primitive_prototype :: proc(t: ^testing.T) {
	kernel: Kernel
	kernel_init(&kernel)
	defer kernel_destroy(&kernel)

	method_selector := create_relation(&kernel, 40, "MethodSelector", 2)
	param := create_relation(&kernel, 41, "Param", 4)
	delegates := create_relation(&kernel, 42, "Delegates", 3)
	relations := Dispatch_Relations {
		method_selector = method_selector,
		param           = param,
		delegates       = delegates,
	}

	tx := kernel_begin(&kernel)
	method := must_int(100)
	integer_restriction := v.value_identity(v.INTEGER_PROTOTYPE)
	transaction_assert(&tx, method_selector, tuple_of(method, sym("bump")))
	transaction_assert(&tx, param, tuple_of(method, sym("amount"), integer_restriction, must_int(0)))

	source := Relation_Source{transaction = &tx, use_stored_derived = true}
	matches := applicable_methods(
		&source,
		relations,
		sym("bump"),
		[]Role_Pair{{role = sym("amount"), value = must_int(5)}},
		context.temp_allocator,
	)
	testing.expect_value(t, len(matches), 1)

	rejects := applicable_methods(
		&source,
		relations,
		sym("bump"),
		[]Role_Pair{{role = sym("amount"), value = v.value_string(context.temp_allocator, "five")}},
		context.temp_allocator,
	)
	testing.expect_value(t, len(rejects), 0)
	commit_transaction(t, &tx)
}
