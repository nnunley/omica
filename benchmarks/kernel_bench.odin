// Microbenchmarks for the relation kernel.
package main

import "core:mem"
import "core:mem/virtual"

import k "../mica/kernel"
import mm "../micromeasure"
import v "../mica/var"

// Shared accumulation target for visitors.
Sink :: struct {
	value: u64,
}

@(private)
scan_visit :: proc(user: rawptr, row: v.Tuple) -> bool {
	sink := (^Sink)(user)
	cell, _ := v.value_as_int(v.tuple_values(row)[0])
	sink.value = sink.value + u64(cell)
	return true
}

// --- Store benchmarks ------------------------------------------------------

Store_State :: struct {
	arena:         virtual.Arena,
	scratch:       virtual.Arena,
	alloc:         mem.Allocator,
	scratch_alloc: mem.Allocator,

	metadata: k.Relation_Metadata,
	rows_1k:  []v.Tuple,
	block:    ^k.Relation_Block,

	unbound: []v.Binding,
	prefix:  []v.Binding,
	index:   []v.Binding,

	sink: Sink,
}

@(private)
store_state_init :: proc() -> ^Store_State {
	state := new(Store_State)
	if err := virtual.arena_init_growing(&state.arena); err != nil {
		panic("failed to initialize store benchmark arena")
	}
	if err := virtual.arena_init_growing(&state.scratch); err != nil {
		panic("failed to initialize store scratch arena")
	}
	state.alloc = virtual.arena_allocator(&state.arena)
	state.scratch_alloc = virtual.arena_allocator(&state.scratch)

	state.metadata = k.relation_metadata(k.Relation_ID(1), v.symbol_intern("Store"), 3)
	positions := make([]u16, 1, state.alloc)
	positions[0] = 1
	specs := make([]k.Index_Spec, 1, state.alloc)
	specs[0] = k.index_spec(positions)
	state.metadata.indexes = specs

	row_count := 10_000
	rows := make([]v.Tuple, row_count, state.alloc)
	for i in 0 ..< row_count {
		first, _ := v.value_int(i64(i % 100))
		second, _ := v.value_int(i64((i / 100) % 100))
		third, _ := v.value_int(i64(i))
		rows[i] = v.tuple_new(state.alloc, []v.Value{first, second, third})
	}
	state.rows_1k = rows[:1000]
	state.block = k.relation_block_build(state.alloc, state.metadata, rows)

	state.unbound = make([]v.Binding, 3, state.alloc)

	state.prefix = make([]v.Binding, 3, state.alloc)
	prefix, _ := v.value_int(1)
	state.prefix[0] = v.binding_of(prefix)

	state.index = make([]v.Binding, 3, state.alloc)
	indexed, _ := v.value_int(2)
	state.index[1] = v.binding_of(indexed)
	return state
}

@(private)
bench_scan_full :: proc(user: rawptr, chunk: int, _: int) {
	state := (^Store_State)(user)
	for _ in 0 ..< chunk {
		k.relation_block_visit(state.block, state.unbound, scan_visit, &state.sink)
	}
	state.sink.value = mm.black_box(state.sink.value)
}

@(private)
bench_scan_prefix :: proc(user: rawptr, chunk: int, _: int) {
	state := (^Store_State)(user)
	for _ in 0 ..< chunk {
		k.relation_block_visit(state.block, state.prefix, scan_visit, &state.sink)
	}
	state.sink.value = mm.black_box(state.sink.value)
}

@(private)
bench_scan_index :: proc(user: rawptr, chunk: int, _: int) {
	state := (^Store_State)(user)
	for _ in 0 ..< chunk {
		k.relation_block_visit(state.block, state.index, scan_visit, &state.sink)
	}
	state.sink.value = mm.black_box(state.sink.value)
}

@(private)
bench_store_build_1k :: proc(user: rawptr, chunk: int, _: int) {
	state := (^Store_State)(user)
	virtual.arena_free_all(&state.scratch)
	accumulator := u64(0)
	for _ in 0 ..< chunk {
		block := k.relation_block_build(state.scratch_alloc, state.metadata, state.rows_1k)
		accumulator += u64(uintptr(block))
	}
	state.sink.value = mm.black_box(accumulator)
}

// --- Transaction benchmarks ------------------------------------------------

Txn_State :: struct {
	arena: virtual.Arena,
	alloc: mem.Allocator,

	kernel:        k.Kernel,
	relation:      k.Relation_ID,
	one_tuple:     v.Tuple,
	assert_tuples: []v.Tuple,
	bindings:      []v.Binding,

	sink: Sink,
}

@(private)
txn_state_init :: proc() -> ^Txn_State {
	state := new(Txn_State)
	if err := virtual.arena_init_growing(&state.arena); err != nil {
		panic("failed to initialize transaction benchmark arena")
	}
	state.alloc = virtual.arena_allocator(&state.arena)
	k.kernel_init(&state.kernel)

	metadata := k.relation_metadata(k.Relation_ID(1), v.symbol_intern("HeldBy"), 2)
	snapshot, err := k.kernel_create_relation(&state.kernel, metadata)
	assert(err == .None)
	k.snapshot_release(snapshot)
	state.relation = k.Relation_ID(1)

	left, _ := v.identity_new(1)
	right, _ := v.identity_new(2)
	state.one_tuple = v.tuple_new(state.alloc, []v.Value {
		v.value_identity(left),
		v.value_identity(right),
	})

	state.assert_tuples = make([]v.Tuple, 16, state.alloc)
	for i in 0 ..< len(state.assert_tuples) {
		first, _ := v.value_int(i64(i))
		second, _ := v.value_int(i64(100 + i))
		state.assert_tuples[i] = v.tuple_new(state.alloc, []v.Value{first, second})
	}
	state.bindings = make([]v.Binding, 2, state.alloc)
	return state
}

@(private)
bench_txn_commit :: proc(user: rawptr, chunk: int, _: int) {
	state := (^Txn_State)(user)
	for _ in 0 ..< chunk {
		tx := k.kernel_begin(&state.kernel)
		assert(k.transaction_assert(&tx, state.relation, state.one_tuple) == .None)
		snapshot, err := k.transaction_commit(&tx)
		assert(err == .None)
		k.snapshot_release(snapshot)
		k.transaction_destroy(&tx)
	}
}

@(private)
bench_txn_assert_scan :: proc(user: rawptr, chunk: int, _: int) {
	state := (^Txn_State)(user)
	for _ in 0 ..< chunk {
		tx := k.kernel_begin(&state.kernel)
		for tuple in state.assert_tuples {
			assert(k.transaction_assert(&tx, state.relation, tuple) == .None)
		}
		k.transaction_visit_extensional(
			&tx,
			state.relation,
			state.bindings,
			scan_visit,
			&state.sink,
		)
		k.transaction_destroy(&tx)
	}
	state.sink.value = mm.black_box(state.sink.value)
}

// --- Rule benchmarks -------------------------------------------------------

Rule_State :: struct {
	arena:         virtual.Arena,
	scratch:       virtual.Arena,
	alloc:         mem.Allocator,
	scratch_alloc: mem.Allocator,

	kernel:   k.Kernel,
	snapshot: ^k.Snapshot,
	rules:    []k.Rule_Definition,

	sink: Sink,
}

@(private)
rule_state_init :: proc() -> ^Rule_State {
	state := new(Rule_State)
	if err := virtual.arena_init_growing(&state.arena); err != nil {
		panic("failed to initialize rule benchmark arena")
	}
	if err := virtual.arena_init_growing(&state.scratch); err != nil {
		panic("failed to initialize rule scratch arena")
	}
	state.alloc = virtual.arena_allocator(&state.arena)
	state.scratch_alloc = virtual.arena_allocator(&state.scratch)
	k.kernel_init(&state.kernel)

	exit := create_relation(&state.kernel, 3, "Exit", 2)
	reachable := create_relation(&state.kernel, 4, "Reachable", 2)

	from := v.symbol_intern("from")
	to := v.symbol_intern("to")
	mid := v.symbol_intern("mid")

	base_rule := k.rule_new(
		reachable,
		[]k.Term{k.term_var(from), k.term_var(to)},
		[]k.Rule_Body_Item {
			k.body_atom(k.atom_positive(exit, []k.Term{k.term_var(from), k.term_var(to)})),
		},
	)
	recursive_rule := k.rule_new(
		reachable,
		[]k.Term{k.term_var(from), k.term_var(to)},
		[]k.Rule_Body_Item {
			k.body_atom(k.atom_positive(exit, []k.Term{k.term_var(from), k.term_var(mid)})),
			k.body_atom(
				k.atom_positive(reachable, []k.Term{k.term_var(mid), k.term_var(to)}),
			),
		},
	)
	base_snapshot, base_err := k.kernel_install_rule(&state.kernel, v.Identity(1), base_rule, "base")
	assert(base_err == .None)
	k.snapshot_release(base_snapshot)
	recursive_snapshot, recursive_err := k.kernel_install_rule(
		&state.kernel,
		v.Identity(2),
		recursive_rule,
		"recursive",
	)
	assert(recursive_err == .None)
	k.snapshot_release(recursive_snapshot)

	tx := k.kernel_begin(&state.kernel)
	chain_length := 50
	for i in 0 ..< chain_length {
		first_id, _ := v.identity_new(u64(i + 1))
		second_id, _ := v.identity_new(u64(i + 2))
		edge := v.tuple_new(state.alloc, []v.Value {
			v.value_identity(first_id),
			v.value_identity(second_id),
		})
		err := k.transaction_assert(&tx, exit, edge)
		assert(err == .None)
	}
	committed, commit_err := k.transaction_commit(&tx)
	assert(commit_err == .None)
	k.snapshot_release(committed)
	k.transaction_destroy(&tx)

	state.snapshot = k.kernel_snapshot(&state.kernel)
	state.rules = state.snapshot.rules
	return state
}

@(private)
bench_rules_eval :: proc(user: rawptr, chunk: int, _: int) {
	state := (^Rule_State)(user)
	accumulator := u64(0)
	for _ in 0 ..< chunk {
		virtual.arena_free_all(&state.scratch)
		derived, err := k.rules_evaluate(state.scratch_alloc, state.rules, state.snapshot)
		if err == .None {
			accumulator += u64(len(derived.relations))
		}
	}
	state.sink.value = mm.black_box(accumulator)
}

// --- Closure benchmarks ----------------------------------------------------

Closure_State :: struct {
	arena:         virtual.Arena,
	scratch:       virtual.Arena,
	alloc:         mem.Allocator,
	scratch_alloc: mem.Allocator,

	kernel:   k.Kernel,
	snapshot: ^k.Snapshot,
	relation: k.Relation_ID,
	head:     v.Value,
	tail:     v.Value,

	sink: Sink,
}

@(private)
closure_state_init :: proc() -> ^Closure_State {
	state := new(Closure_State)
	if err := virtual.arena_init_growing(&state.arena); err != nil {
		panic("failed to initialize closure benchmark arena")
	}
	if err := virtual.arena_init_growing(&state.scratch); err != nil {
		panic("failed to initialize closure scratch arena")
	}
	state.alloc = virtual.arena_allocator(&state.arena)
	state.scratch_alloc = virtual.arena_allocator(&state.scratch)
	k.kernel_init(&state.kernel)

	state.relation = create_relation_with(
		&state.kernel,
		5,
		"Delegates",
		3,
		k.conflict_set(),
		[]k.Index_Spec{k.index_spec(make_positions(state.alloc, 0))},
	)

	chain_length := 100
	tx := k.kernel_begin(&state.kernel)
	for i in 0 ..< chain_length {
		child, _ := v.identity_new(u64(i + 1))
		parent, _ := v.identity_new(u64(i + 2))
		order, _ := v.value_int(0)
		edge := v.tuple_new(state.alloc, []v.Value {
			v.value_identity(child),
			v.value_identity(parent),
			order,
		})
		err := k.transaction_assert(&tx, state.relation, edge)
		assert(err == .None)
	}
	committed, commit_err := k.transaction_commit(&tx)
	assert(commit_err == .None)
	k.snapshot_release(committed)
	k.transaction_destroy(&tx)

	state.snapshot = k.kernel_snapshot(&state.kernel)
	head, _ := v.identity_new(1)
	tail, _ := v.identity_new(u64(chain_length + 1))
	state.head = v.value_identity(head)
	state.tail = v.value_identity(tail)
	return state
}

@(private)
bench_closure_reaches :: proc(user: rawptr, chunk: int, _: int) {
	state := (^Closure_State)(user)
	previous := context.allocator
	context.allocator = state.scratch_alloc
	virtual.arena_free_all(&state.scratch)

	accumulator := u64(0)
	for _ in 0 ..< chunk {
		source := k.Relation_Source {
			snapshot           = state.snapshot,
			use_stored_derived = true,
		}
		if k.delegates_reaches(&source, state.relation, state.head, state.tail) {
			accumulator += 1
		}
	}
	context.allocator = previous
	state.sink.value = mm.black_box(accumulator)
}

// --- Dispatch benchmarks ---------------------------------------------------

Dispatch_State :: struct {
	arena:         virtual.Arena,
	scratch:       virtual.Arena,
	alloc:         mem.Allocator,
	scratch_alloc: mem.Allocator,

	kernel:   k.Kernel,
	snapshot: ^k.Snapshot,
	relations: k.Dispatch_Relations,
	selector:  v.Value,
	roles:     []k.Role_Pair,

	sink: Sink,
}

@(private)
dispatch_state_init :: proc() -> ^Dispatch_State {
	state := new(Dispatch_State)
	if err := virtual.arena_init_growing(&state.arena); err != nil {
		panic("failed to initialize dispatch benchmark arena")
	}
	if err := virtual.arena_init_growing(&state.scratch); err != nil {
		panic("failed to initialize dispatch scratch arena")
	}
	state.alloc = virtual.arena_allocator(&state.arena)
	state.scratch_alloc = virtual.arena_allocator(&state.scratch)
	k.kernel_init(&state.kernel)

	method_selector := create_relation(&state.kernel, 40, "MethodSelector", 2)
	param := create_relation(&state.kernel, 41, "Param", 4)
	delegates := create_relation(&state.kernel, 42, "DispatchDelegates", 3)
	state.relations = k.Dispatch_Relations {
		method_selector = method_selector,
		param           = param,
		delegates       = delegates,
	}
	state.selector = v.value_symbol(v.symbol_intern("take"))

	tx := k.kernel_begin(&state.kernel)
	for i in 0 ..< 10 {
		method, _ := v.value_int(i64(100 + i))
		selector := v.value_symbol(v.symbol_intern("take"))
		role := v.value_symbol(v.symbol_intern("item"))
		restriction_id, _ := v.identity_new(u64(1000 + i))
		position, _ := v.value_int(0)
		restriction := v.value_identity(restriction_id)

		err := k.transaction_assert(
			&tx,
			method_selector,
			v.tuple_new(state.alloc, []v.Value{method, selector}),
		)
		assert(err == .None)
		err = k.transaction_assert(
			&tx,
			param,
			v.tuple_new(state.alloc, []v.Value{method, role, restriction, position}),
		)
		assert(err == .None)
	}
	committed, commit_err := k.transaction_commit(&tx)
	assert(commit_err == .None)
	k.snapshot_release(committed)
	k.transaction_destroy(&tx)

	state.snapshot = k.kernel_snapshot(&state.kernel)
	invoked_id, _ := v.identity_new(1005)
	state.roles = make([]k.Role_Pair, 1, state.alloc)
	state.roles[0] = k.Role_Pair {
		role  = v.value_symbol(v.symbol_intern("item")),
		value = v.value_identity(invoked_id),
	}
	return state
}

@(private)
bench_dispatch :: proc(user: rawptr, chunk: int, _: int) {
	state := (^Dispatch_State)(user)
	previous := context.allocator
	context.allocator = state.scratch_alloc
	virtual.arena_free_all(&state.scratch)

	accumulator := u64(0)
	for _ in 0 ..< chunk {
		source := k.Relation_Source {
			snapshot           = state.snapshot,
			use_stored_derived = true,
		}
		methods := k.applicable_methods(
			&source,
			state.relations,
			state.selector,
			state.roles,
			state.scratch_alloc,
		)
		accumulator += u64(len(methods))
	}
	context.allocator = previous
	state.sink.value = mm.black_box(accumulator)
}

// --- Shared helpers --------------------------------------------------------

@(private)
make_positions :: proc(alloc: mem.Allocator, position: u16) -> []u16 {
	positions := make([]u16, 1, alloc)
	positions[0] = position
	return positions
}

@(private)
create_relation :: proc(
	kernel: ^k.Kernel,
	id: u32,
	name: string,
	arity: u16,
) -> k.Relation_ID {
	return create_relation_with(kernel, id, name, arity, k.conflict_set(), nil)
}

@(private)
create_relation_with :: proc(
	kernel: ^k.Kernel,
	id: u32,
	name: string,
	arity: u16,
	conflict: k.Conflict_Policy,
	indexes: []k.Index_Spec,
) -> k.Relation_ID {
	metadata := k.relation_metadata(k.Relation_ID(id), v.symbol_intern(name), arity)
	metadata.conflict = conflict
	metadata.indexes = indexes
	snapshot, err := k.kernel_create_relation(kernel, metadata)
	assert(err == .None)
	k.snapshot_release(snapshot)
	return k.Relation_ID(id)
}

@(private)
bench_snapshot_fork :: proc(user: rawptr, chunk: int, _: int) {
	state := (^Txn_State)(user)
	for _ in 0 ..< chunk {
		fork := k.snapshot_fork(state.kernel.current)
		k.snapshot_release(fork)
	}
}

register_kernel_benches :: proc(runner: ^mm.Runner) {
	store_state := store_state_init()
	store_group := mm.group(runner, "kernel/store")
	mm.bench(store_group, "scan_full_10k", store_state, bench_scan_full)
	mm.bench(store_group, "scan_prefix_10k", store_state, bench_scan_prefix)
	mm.bench(store_group, "scan_index_10k", store_state, bench_scan_index)
	mm.bench_capped(store_group, "build_1k", store_state, bench_store_build_1k, 64)

	txn_state := txn_state_init()
	txn_group := mm.group(runner, "kernel/txn")
	mm.bench(txn_group, "commit_single_write", txn_state, bench_txn_commit)
	mm.bench(txn_group, "begin_assert16_scan", txn_state, bench_txn_assert_scan)
	mm.bench(txn_group, "snapshot_fork_release", txn_state, bench_snapshot_fork)

	rule_state := rule_state_init()
	rules_group := mm.group(runner, "kernel/rules")
	mm.bench(rules_group, "transitive_chain_50", rule_state, bench_rules_eval)

	closure_state := closure_state_init()
	closure_group := mm.group(runner, "kernel/closure")
	mm.bench(closure_group, "reaches_chain_100", closure_state, bench_closure_reaches)

	dispatch_state := dispatch_state_init()
	dispatch_group := mm.group(runner, "kernel/dispatch")
	mm.bench(dispatch_group, "applicable_10_methods", dispatch_state, bench_dispatch)
}
