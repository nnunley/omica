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
	sink.value = sink.value + 1
	return true
}

// Visits and reads a column, like a real filter or projection.
@(private)
scan_checksum_visit :: proc(user: rawptr, row: v.Tuple) -> bool {
	sink := (^Sink)(user)
	identity, _ := v.value_as_identity(v.tuple_values(row)[0])
	sink.value = sink.value + v.identity_raw(identity)
	return true
}

// --- Store benchmarks ------------------------------------------------------
//
// The corpus matches the Rust relation_index_benches shape: 128 groups by 128
// items of identity values, with a symbol kind column. Prefix scans select one
// group and visit 128 rows.

Store_State :: struct {
	arena:         virtual.Arena,
	scratch:       virtual.Arena,
	alloc:         mem.Allocator,
	scratch_alloc: mem.Allocator,

	primary_metadata: k.Relation_Metadata,
	index_metadata:   k.Relation_Metadata,
	rows:             []v.Tuple,

	primary_block: ^k.Relation_Block,
	index_block:   ^k.Relation_Block,

	unbound: []v.Binding,
	prefix:  []v.Binding,
	index:   []v.Binding,

	sink: Sink,
}

@(private)
setup_store_state :: proc(state: ^Store_State) {
	GROUPS :: 128
	ITEMS_PER_GROUP :: 128

	state.primary_metadata = k.relation_metadata(
		k.Relation_ID(1),
		v.symbol_intern("Store"),
		3,
	)
	state.index_metadata = k.relation_metadata(
		k.Relation_ID(1),
		v.symbol_intern("Store"),
		3,
	)
	index_positions := make([]u16, 1, state.alloc)
	index_positions[0] = 0
	index_specs := make([]k.Index_Spec, 1, state.alloc)
	index_specs[0] = k.index_spec(index_positions)
	state.index_metadata.indexes = index_specs

	kind := v.value_symbol(v.symbol_intern("bench_kind"))
	state.rows = make([]v.Tuple, GROUPS * ITEMS_PER_GROUP, state.alloc)
	for group in 0 ..< GROUPS {
		group_id, _ := v.identity_new(u64(group))
		for item in 0 ..< ITEMS_PER_GROUP {
			item_id, _ := v.identity_new(u64(item))
			state.rows[group * ITEMS_PER_GROUP + item] = v.tuple_new(
				state.alloc,
				[]v.Value {
					v.value_identity(group_id),
					v.value_identity(item_id),
					kind,
				},
			)
		}
	}

	state.primary_block = k.relation_block_build(state.alloc, state.primary_metadata, state.rows)
	state.index_block = k.relation_block_build(state.alloc, state.index_metadata, state.rows)

	state.unbound = make([]v.Binding, 3, state.alloc)

	state.prefix = make([]v.Binding, 3, state.alloc)
	group_id, _ := v.identity_new(42)
	state.prefix[0] = v.binding_of(v.value_identity(group_id))

	state.index = make([]v.Binding, 3, state.alloc)
	state.index[0] = v.binding_of(v.value_identity(group_id))
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
	setup_store_state(state)
	return state
}

@(private)
bench_scan_full :: proc(user: rawptr, chunk: int, _: int) {
	state := (^Store_State)(user)
	for _ in 0 ..< chunk {
		k.relation_block_visit(state.primary_block, state.unbound, scan_visit, &state.sink)
	}
	state.sink.value = mm.black_box(state.sink.value)
}

@(private)
bench_scan_full_checksum :: proc(user: rawptr, chunk: int, _: int) {
	state := (^Store_State)(user)
	for _ in 0 ..< chunk {
		k.relation_block_visit(state.primary_block, state.unbound, scan_checksum_visit, &state.sink)
	}
	state.sink.value = mm.black_box(state.sink.value)
}

@(private)
bench_scan_prefix_checksum :: proc(user: rawptr, chunk: int, _: int) {
	state := (^Store_State)(user)
	for _ in 0 ..< chunk {
		k.relation_block_visit(state.primary_block, state.prefix, scan_checksum_visit, &state.sink)
	}
	state.sink.value = mm.black_box(state.sink.value)
}

@(private)
bench_scan_prefix :: proc(user: rawptr, chunk: int, _: int) {
	state := (^Store_State)(user)
	for _ in 0 ..< chunk {
		k.relation_block_visit(state.primary_block, state.prefix, scan_visit, &state.sink)
	}
	state.sink.value = mm.black_box(state.sink.value)
}

@(private)
bench_scan_index :: proc(user: rawptr, chunk: int, _: int) {
	state := (^Store_State)(user)
	for _ in 0 ..< chunk {
		k.relation_block_visit(state.index_block, state.index, scan_visit, &state.sink)
	}
	state.sink.value = mm.black_box(state.sink.value)
}

@(private)
bench_store_rebuild :: proc(user: rawptr, chunk: int, _: int) {
	state := (^Store_State)(user)
	virtual.arena_free_all(&state.scratch)
	accumulator := u64(0)
	for _ in 0 ..< chunk {
		block := k.relation_block_build(state.scratch_alloc, state.index_metadata, state.rows)
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
	chain_length := 48
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

// --- Visible-items rule benchmark ------------------------------------------
//
// Mirrors the Rust visible_items seed_world and rule: 96 rooms, 64 items per
// room, 24 actors that can see 8 rooms each, and every 17th item hidden from
// one actor.

@(private)
bench_identity :: proc(raw: u64) -> v.Identity {
	identity, _ := v.identity_new(raw)
	return identity
}

Visible_State :: struct {
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
visible_state_init :: proc() -> ^Visible_State {
	ROOMS :: 96
	ITEMS_PER_ROOM :: 64
	ACTORS :: 24
	ROOMS_PER_ACTOR :: 8
	HIDDEN_EVERY :: 17

	state := new(Visible_State)
	if err := virtual.arena_init_growing(&state.arena); err != nil {
		panic("failed to initialize visible benchmark arena")
	}
	if err := virtual.arena_init_growing(&state.scratch); err != nil {
		panic("failed to initialize visible scratch arena")
	}
	state.alloc = virtual.arena_allocator(&state.arena)
	state.scratch_alloc = virtual.arena_allocator(&state.scratch)
	k.kernel_init(&state.kernel)

	located_in := create_relation(&state.kernel, 10, "LocatedIn", 2)
	can_see_room := create_relation(&state.kernel, 11, "CanSeeRoom", 2)
	portable := create_relation(&state.kernel, 12, "Portable", 1)
	hidden_from := create_relation(&state.kernel, 13, "HiddenFrom", 2)
	visible := create_relation(&state.kernel, 14, "Visible", 2)

	actor := v.symbol_intern("actor")
	item := v.symbol_intern("item")
	room := v.symbol_intern("room")

	rule := k.rule_new(
		visible,
		[]k.Term{k.term_var(actor), k.term_var(item)},
		[]k.Rule_Body_Item {
			k.body_atom(k.atom_positive(located_in, []k.Term{k.term_var(item), k.term_var(room)})),
			k.body_atom(
				k.atom_positive(can_see_room, []k.Term{k.term_var(actor), k.term_var(room)}),
			),
			k.body_atom(k.atom_positive(portable, []k.Term{k.term_var(item)})),
			k.body_atom(
				k.atom_negated(hidden_from, []k.Term{k.term_var(item), k.term_var(actor)}),
			),
		},
	)
	snapshot, err := k.kernel_install_rule(&state.kernel, v.Identity(20), rule, "visible")
	assert(err == .None)
	k.snapshot_release(snapshot)

	tx := k.kernel_begin(&state.kernel)
	for room_index in 0 ..< ROOMS {
		for item_index in 0 ..< ITEMS_PER_ROOM {
			item_id := bench_identity(u64(room_index * ITEMS_PER_ROOM + item_index))
			room_id := bench_identity(u64(100_000 + room_index))

			located := v.tuple_new(state.alloc, []v.Value {
				v.value_identity(item_id),
				v.value_identity(room_id),
			})
			assert(k.transaction_assert(&tx, located_in, located) == .None)

			portable_row := v.tuple_new(state.alloc, []v.Value{v.value_identity(item_id)})
			assert(k.transaction_assert(&tx, portable, portable_row) == .None)

			if item_index % HIDDEN_EVERY == 0 {
				hidden_actor := bench_identity(u64(200_000 + room_index % ACTORS))
				hidden := v.tuple_new(state.alloc, []v.Value {
					v.value_identity(item_id),
					v.value_identity(hidden_actor),
				})
				assert(k.transaction_assert(&tx, hidden_from, hidden) == .None)
			}
		}
	}
	for actor_index in 0 ..< ACTORS {
		for offset in 0 ..< ROOMS_PER_ACTOR {
			room_index := (actor_index * ROOMS_PER_ACTOR + offset) % ROOMS
			actor_id := bench_identity(u64(200_000 + actor_index))
			room_id := bench_identity(u64(100_000 + room_index))
			sees := v.tuple_new(state.alloc, []v.Value {
				v.value_identity(actor_id),
				v.value_identity(room_id),
			})
			assert(k.transaction_assert(&tx, can_see_room, sees) == .None)
		}
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
bench_visible_items :: proc(user: rawptr, chunk: int, _: int) {
	state := (^Visible_State)(user)
	accumulator := u64(0)
	for _ in 0 ..< chunk {
		virtual.arena_free_all(&state.scratch)
		derived, err := k.rules_evaluate(state.scratch_alloc, state.rules, state.snapshot)
		if err == .None {
			for relation in derived.relations {
				accumulator += u64(len(k.rules_derived_rows(&derived, relation)))
			}
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
		current := k.kernel_snapshot(&state.kernel)
		fork := k.snapshot_fork(current)
		k.snapshot_release(current)
		k.snapshot_release(fork)
	}
}

register_kernel_benches :: proc(runner: ^mm.Runner) {
	store_state := store_state_init()
	store_group := mm.group(runner, "kernel/store")
	mm.bench(store_group, "scan_full_16k", store_state, bench_scan_full)
	mm.bench(store_group, "scan_full_checksum_16k", store_state, bench_scan_full_checksum)
	mm.bench(store_group, "scan_prefix_16k", store_state, bench_scan_prefix)
	mm.bench(store_group, "scan_prefix_checksum_16k", store_state, bench_scan_prefix_checksum)
	mm.bench(store_group, "scan_index_16k", store_state, bench_scan_index)
	mm.bench_capped(store_group, "rebuild_16k", store_state, bench_store_rebuild, 8)

	txn_state := txn_state_init()
	txn_group := mm.group(runner, "kernel/txn")
	mm.bench(txn_group, "commit_single_write", txn_state, bench_txn_commit)
	mm.bench(txn_group, "begin_assert16_scan", txn_state, bench_txn_assert_scan)
	mm.bench(txn_group, "snapshot_fork_release", txn_state, bench_snapshot_fork)

	rule_state := rule_state_init()
	visible_state := visible_state_init()
	rules_group := mm.group(runner, "kernel/rules")
	mm.bench(rules_group, "transitive_chain_48", rule_state, bench_rules_eval)
	mm.bench(rules_group, "visible_items_rule", visible_state, bench_visible_items)

	closure_state := closure_state_init()
	closure_group := mm.group(runner, "kernel/closure")
	mm.bench(closure_group, "reaches_chain_100", closure_state, bench_closure_reaches)

	dispatch_state := dispatch_state_init()
	dispatch_group := mm.group(runner, "kernel/dispatch")
	mm.bench(dispatch_group, "applicable_10_methods", dispatch_state, bench_dispatch)

	register_kernel_concurrent_benches(runner)
}
