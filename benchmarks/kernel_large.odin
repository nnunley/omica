// Large-scale kernel benchmarks.
//
// The suite in `kernel_bench.odin` tops out at 16,384 rows; these benches push
// the same kernel surfaces to 10^4, 10^5, and 10^6 rows so that scaling
// regressions and improvements are visible against the committed baseline.
//
// Each state builds a fresh kernel for its target row count. The hot ops are
// repeated through `bench_capped` so one sample does not allocate more than
// the cap implies. The memory-growth bench registers a memory probe with the
// harness so the report and the TSV carry a per-run RSS delta in addition to
// the timing.
package main

import "core:fmt"
import "core:mem"
import "core:mem/virtual"

import k "../mica/kernel"
import mm "../micromeasure"
import v "../mica/var"

// Row-count ladder. 10^4 / 10^5 / 10^6 cover the gap named in
// `docs/testing-gaps.md` ("chain depth and memory growth — Missing") and the
// issue scope.
ROW_COUNTS :: [3]int{10_000, 100_000, 1_000_000}

// --- Store scans at scale ---------------------------------------------------
//
// `Sink` is the shared accumulator type from kernel_bench.odin; the two
// files compile as one package so the type is shared, not duplicated.

@(private)
large_scan_visit :: proc(user: rawptr, row: v.Tuple) -> bool {
	sink := (^Sink)(user)
	sink.value = sink.value + 1
	return true
}

// A large store: one primary block plus one indexed block over the same rows.
// The metadata for both blocks is the same so the row layout is identical;
// the indexed block also carries the secondary index, which is the cost the
// scan-index bench measures.
Large_Store_State :: struct {
	kernel:         k.Kernel,
	arena:          virtual.Arena,
	alloc:          mem.Allocator,
	rows:           []v.Tuple,
	primary_block:  ^k.Relation_Block,
	index_block:    ^k.Relation_Block,
	primary_meta:   k.Relation_Metadata,
	index_meta:     k.Relation_Metadata,
	unbound:        []v.Binding,
	prefix:         []v.Binding,
	index_bind:     []v.Binding,
	sink:           Sink,
}

@(private)
large_store_state_init :: proc(rows: int) -> ^Large_Store_State {
	state := new(Large_Store_State)
	if err := virtual.arena_init_growing(&state.arena); err != nil {
		panic("failed to initialize large store arena")
	}
	state.alloc = virtual.arena_allocator(&state.arena)
	k.kernel_init(&state.kernel)

	state.primary_meta = k.relation_metadata(k.Relation_ID(1), v.symbol_intern("Large"), 2)
	state.index_meta = k.relation_metadata(k.Relation_ID(1), v.symbol_intern("Large"), 2)
	index_positions := make([]u16, 1, state.alloc)
	index_positions[0] = 0
	index_specs := make([]k.Index_Spec, 1, state.alloc)
	index_specs[0] = k.index_spec(index_positions)
	state.index_meta.indexes = index_specs

	state.rows = make([]v.Tuple, rows, state.alloc)
	// Two columns: (group, item). The group is the index key; the item is a
	// unique filler so the rows are distinct and the index stays dense.
	group_size := 1024
	for i in 0 ..< rows {
		group_id, _ := v.identity_new(u64(i / group_size))
		item_id, _ := v.identity_new(u64(i))
		state.rows[i] = v.tuple_new(state.alloc, []v.Value{
			v.value_identity(group_id),
			v.value_identity(item_id),
		})
	}

	state.primary_block = k.relation_block_build_pooled(
		&state.kernel, state.primary_meta, state.rows,
	)
	state.index_block = k.relation_block_build_pooled(
		&state.kernel, state.index_meta, state.rows,
	)

	state.unbound = make([]v.Binding, 2, state.alloc)

	state.prefix = make([]v.Binding, 2, state.alloc)
	// Bind the first group: 1024 rows.
	group_id, _ := v.identity_new(u64(0))
	state.prefix[0] = v.binding_of(v.value_identity(group_id))

	state.index_bind = make([]v.Binding, 2, state.alloc)
	state.index_bind[0] = v.binding_of(v.value_identity(group_id))
	return state
}

// One full scan of the primary block, chunked by the harness.
@(private)
bench_large_scan_full :: proc(user: rawptr, chunk: int, _: int) {
	state := (^Large_Store_State)(user)
	for _ in 0 ..< chunk {
		k.relation_block_visit(state.primary_block, state.unbound, large_scan_visit, &state.sink)
	}
	state.sink.value = mm.black_box(state.sink.value)
}

// One prefix scan of the primary block: bind group 0 and visit its rows.
@(private)
bench_large_scan_prefix :: proc(user: rawptr, chunk: int, _: int) {
	state := (^Large_Store_State)(user)
	for _ in 0 ..< chunk {
		k.relation_block_visit(state.primary_block, state.prefix, large_scan_visit, &state.sink)
	}
	state.sink.value = mm.black_box(state.sink.value)
}

// One index lookup on the indexed block: the index narrows the scan to the
// bound group before visiting.
@(private)
bench_large_scan_index :: proc(user: rawptr, chunk: int, _: int) {
	state := (^Large_Store_State)(user)
	for _ in 0 ..< chunk {
		k.relation_block_visit(state.index_block, state.index_bind, large_scan_visit, &state.sink)
	}
	state.sink.value = mm.black_box(state.sink.value)
}

// --- Bulk load at scale -----------------------------------------------------
//
// One sample builds a fresh block of `rows` tuples (sort + dedup + chunk +
// index build) and publishes it over the relation's current block via
// `kernel_replace_relation_block`. The timed region is the bulk load, not a
// transaction commit; the issue's "commit latency … over the loader path" is
// a different surface and is measured by the existing `kernel/txn` benches.
Bulk_State :: struct {
	kernel:   k.Kernel,
	arena:    virtual.Arena,
	alloc:    mem.Allocator,
	relation: k.Relation_ID,
	metadata: k.Relation_Metadata,
	rows:     int,
	sink:     Sink,
}

@(private)
bulk_state_init :: proc(rows: int, indexed: bool) -> ^Bulk_State {
	state := new(Bulk_State)
	if err := virtual.arena_init_growing(&state.arena); err != nil {
		panic("failed to initialize bulk arena")
	}
	state.alloc = virtual.arena_allocator(&state.arena)
	k.kernel_init(&state.kernel)
	state.rows = rows

	state.metadata = k.relation_metadata(k.Relation_ID(1), v.symbol_intern("Bulk"), 2)
	if indexed {
		index_positions := make([]u16, 1, state.alloc)
		index_positions[0] = 0
		index_specs := make([]k.Index_Spec, 1, state.alloc)
		index_specs[0] = k.index_spec(index_positions)
		state.metadata.indexes = index_specs
	}
	snapshot, err := k.kernel_create_relation(&state.kernel, state.metadata)
	assert(err == .None)
	k.snapshot_release(snapshot)
	state.relation = k.Relation_ID(1)
	return state
}

// Builds a fresh block of `state.rows` tuples and publishes it over the
// relation's current block. `kernel_replace_relation_block` takes ownership
// of the block reference on every path (the published snapshot owns it on
// success; the fork releases it on `.Conflict`), so the bench must not
// release the block afterwards. The temporary arena that holds the row cells
// is destroyed after the publish; the block's own storage (the frame arena)
// is owned by the kernel's pool and recycled on the next replace.
@(private)
bench_bulk_load :: proc(user: rawptr, chunk: int, _: int) {
	state := (^Bulk_State)(user)

	arena := new(virtual.Arena)
	if err := virtual.arena_init_growing(arena); err != nil {
		panic("failed to initialize bulk arena")
	}
	alloc := virtual.arena_allocator(arena)

	rows := make([]v.Tuple, state.rows, alloc)
	for i in 0 ..< state.rows {
		group_id, _ := v.identity_new(u64(i / 1024))
		item_id, _ := v.identity_new(u64(i))
		rows[i] = v.tuple_new(alloc, []v.Value{
			v.value_identity(group_id),
			v.value_identity(item_id),
		})
	}

	block := k.relation_block_build(alloc, state.metadata, rows)
	committed, err := k.kernel_replace_relation_block(&state.kernel, block)
	if err == .None {
		k.snapshot_release(committed)
	}
	// The block is owned by the kernel on both paths; do not release it.
	virtual.arena_destroy(arena)
	free(arena)

	state.sink.value = mm.black_box(u64(state.rows))
}

// --- Recursive closure at scale ---------------------------------------------
//
// `delegates_reaches` walks a chain from `child` to `ancestor`. The chain
// length is the row count of the delegates relation; the bench reports the
// time to walk the whole chain from one end to the other.
Large_Closure_State :: struct {
	kernel:   k.Kernel,
	arena:    virtual.Arena,
	scratch:  virtual.Arena,
	alloc:    mem.Allocator,
	scratch_alloc: mem.Allocator,
	snapshot: ^k.Snapshot,
	relation: k.Relation_ID,
	head:     v.Value,
	tail:     v.Value,
	sink:     Sink,
}

@(private)
large_closure_state_init :: proc(chain: int) -> ^Large_Closure_State {
	state := new(Large_Closure_State)
	if err := virtual.arena_init_growing(&state.arena); err != nil {
		panic("failed to initialize closure arena")
	}
	if err := virtual.arena_init_growing(&state.scratch); err != nil {
		panic("failed to initialize closure scratch")
	}
	state.alloc = virtual.arena_allocator(&state.arena)
	state.scratch_alloc = virtual.arena_allocator(&state.scratch)
	k.kernel_init(&state.kernel)

	state.relation = create_relation_with(
		&state.kernel,
		5,
		"LargeDelegates",
		3,
		k.conflict_set(),
		[]k.Index_Spec{k.index_spec(make_positions(state.alloc, 0))},
	)

	tx := k.kernel_begin(&state.kernel)
	for i in 0 ..< chain {
		child, _ := v.identity_new(u64(i + 1))
		parent, _ := v.identity_new(u64(i + 2))
		order, _ := v.value_int(0)
		edge := v.tuple_new(state.alloc, []v.Value{
			v.value_identity(child),
			v.value_identity(parent),
			order,
		})
		assert(k.transaction_assert(&tx, state.relation, edge) == .None)
	}
	committed, commit_err := k.transaction_commit(&tx)
	assert(commit_err == .None)
	k.snapshot_release(committed)
	k.transaction_destroy(&tx)

	state.snapshot = k.kernel_snapshot(&state.kernel)
	head, _ := v.identity_new(1)
	tail, _ := v.identity_new(u64(chain + 1))
	state.head = v.value_identity(head)
	state.tail = v.value_identity(tail)
	return state
}

@(private)
bench_large_closure_reaches :: proc(user: rawptr, chunk: int, _: int) {
	state := (^Large_Closure_State)(user)
	previous := context.allocator
	context.allocator = state.scratch_alloc
	virtual.arena_free_all(&state.scratch)

	accumulator := u64(0)
	for _ in 0 ..< chunk {
		source := k.Relation_Source{
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

// --- Memory growth ----------------------------------------------------------
//
// A bench that bulk-loads `rows` tuples into a fresh relation and reports the
// per-run RSS delta through the harness's memory probe. The timed region is
// the bulk load (sort + dedup + chunk + index build + publish); the memory
// column is the VmHWM delta measured by the probe before warmup and after the
// last sample. VmHWM is a lifetime high-water, so the delta is run-
// order-dependent: run with a filter for a clean per-scale reading.
Mem_State :: struct {
	kernel:   k.Kernel,
	relation: k.Relation_ID,
	metadata: k.Relation_Metadata,
	rows:     int,
	sink:     Sink,
}

@(private)
mem_state_init :: proc(rows: int) -> ^Mem_State {
	state := new(Mem_State)
	k.kernel_init(&state.kernel)
	state.rows = rows
	state.metadata = k.relation_metadata(k.Relation_ID(1), v.symbol_intern("Mem"), 1)
	snapshot, err := k.kernel_create_relation(&state.kernel, state.metadata)
	assert(err == .None)
	k.snapshot_release(snapshot)
	state.relation = k.Relation_ID(1)
	return state
}

// Builds a fresh block of `state.rows` tuples and publishes it over the
// relation's current block. Same ownership contract as `bench_bulk_load`:
// the kernel owns the block on both paths, so the bench must not release it.
@(private)
bench_mem_grow :: proc(user: rawptr, chunk: int, _: int) {
	state := (^Mem_State)(user)

	arena := new(virtual.Arena)
	if err := virtual.arena_init_growing(arena); err != nil {
		panic("failed to initialize grow arena")
	}
	alloc := virtual.arena_allocator(arena)

	rows := make([]v.Tuple, state.rows, alloc)
	for i in 0 ..< state.rows {
		id, _ := v.identity_new(u64(i + 1))
		rows[i] = v.tuple_new(alloc, []v.Value{v.value_identity(id)})
	}

	block := k.relation_block_build(alloc, state.metadata, rows)
	committed, err := k.kernel_replace_relation_block(&state.kernel, block)
	if err == .None {
		k.snapshot_release(committed)
	}
	// The block is owned by the kernel on both paths; do not release it.
	virtual.arena_destroy(arena)
	free(arena)

	state.sink.value = mm.black_box(u64(state.rows))
}

// --- Rule fixpoint at scale -------------------------------------------------
//
// One sample commits `batches` transactions of `rows / batches` facts each.
// With derivation enabled every commit re-runs the whole fixpoint; suspended,
// the batches apply extensional writes only and the resume derives once. Both
// variants reset the extensional relation to an empty block first, so samples
// are independent.
Rule_Load_State :: struct {
	kernel:          k.Kernel,
	arena:           virtual.Arena,
	alloc:           mem.Allocator,
	edge:            k.Relation_ID,
	reach:           k.Relation_ID,
	edge_metadata:   k.Relation_Metadata,
	root:            v.Value,
	batches:         int,
	edges_per_batch: int,
	// Chain edges (i -> i + 1) instead of star edges (root -> i). A chain
	// makes the transitive closure grow quadratically.
	chain:           bool,
	next_leaf:       u64,
	sink:            Sink,
}

@(private)
rule_load_state_init :: proc(rows: int, batches: int, chain: bool) -> ^Rule_Load_State {
	state := new(Rule_Load_State)
	if err := virtual.arena_init_growing(&state.arena); err != nil {
		panic("failed to initialize rule load arena")
	}
	state.alloc = virtual.arena_allocator(&state.arena)
	k.kernel_init(&state.kernel)

	state.edge = create_relation_with(
		&state.kernel,
		1,
		"RuleEdge",
		2,
		k.conflict_set(),
		nil,
	)
	state.reach = create_relation_with(
		&state.kernel,
		2,
		"RuleReach",
		2,
		k.conflict_set(),
		nil,
	)
	current := k.kernel_snapshot(&state.kernel)
	state.edge_metadata, _ = k.snapshot_relation_metadata(current, state.edge)
	k.snapshot_release(current)

	from := v.symbol_intern("From")
	to := v.symbol_intern("To")
	mid := v.symbol_intern("Mid")
	base_rule := k.rule_new(
		state.reach,
		[]k.Term{k.term_var(from), k.term_var(to)},
		[]k.Rule_Body_Item {
			k.body_atom(k.atom_positive(state.edge, []k.Term{k.term_var(from), k.term_var(to)})),
		},
	)
	installed, install_err := k.kernel_install_rule(&state.kernel, v.Identity(100), base_rule, "base")
	assert(install_err == .None)
	k.snapshot_release(installed)
	if chain {
		recursive_rule := k.rule_new(
			state.reach,
			[]k.Term{k.term_var(from), k.term_var(to)},
			[]k.Rule_Body_Item {
				k.body_atom(k.atom_positive(state.edge, []k.Term{k.term_var(from), k.term_var(mid)})),
				k.body_atom(k.atom_positive(state.reach, []k.Term{k.term_var(mid), k.term_var(to)})),
			},
		)
		installed, install_err = k.kernel_install_rule(&state.kernel, v.Identity(101), recursive_rule, "recursive")
		assert(install_err == .None)
		k.snapshot_release(installed)
	}

	root, _ := v.identity_new(0)
	state.root = v.value_identity(root)
	state.batches = batches
	state.edges_per_batch = rows / batches
	state.chain = chain
	state.next_leaf = 1
	return state
}

// Empties the extensional relation without recomputing derived facts. The next
// commit (derived variant) or resume (suspended variant) brings them up to
// date, so samples start from equivalent state.
@(private)
rule_load_reset :: proc(state: ^Rule_Load_State) {
	empty := k.relation_block_build_pooled(&state.kernel, state.edge_metadata, nil)
	replaced, err := k.kernel_replace_relation_block(&state.kernel, empty)
	if err == .None {
		k.snapshot_release(replaced)
	}
}

// One load: optionally suspend derivation, commit `batches` transactions, then
// optionally resume. Returns the number of facts committed.
@(private)
rule_load_run :: proc(state: ^Rule_Load_State, suspended: bool) -> u64 {
	rule_load_reset(state)
	if suspended {
		k.kernel_set_derivation(&state.kernel, false)
	}

	arena: virtual.Arena
	if err := virtual.arena_init_growing(&arena); err != nil {
		panic("failed to initialize rule load op arena")
	}
	defer virtual.arena_destroy(&arena)
	alloc := virtual.arena_allocator(&arena)

	facts := u64(0)
	for _ in 0 ..< state.batches {
		tx := k.kernel_begin(&state.kernel)
		for _ in 0 ..< state.edges_per_batch {
			leaf, _ := v.identity_new(state.next_leaf)
			state.next_leaf += 1
			source := state.root
			target := v.value_identity(leaf)
			if state.chain {
				source = target
				next, _ := v.identity_new(state.next_leaf)
				state.next_leaf += 1
				target = v.value_identity(next)
			}
			edge_tuple := v.tuple_new(alloc, []v.Value{source, target})
			if err := k.transaction_assert(&tx, state.edge, edge_tuple); err != .None {
				k.transaction_destroy(&tx)
				return facts
			}
			facts += 1
		}
		committed, commit_err := k.transaction_commit(&tx)
		k.transaction_destroy(&tx)
		if commit_err != .None {
			return facts
		}
		k.snapshot_release(committed)
	}

	if suspended {
		k.kernel_set_derivation(&state.kernel, true)
	}
	return facts
}

@(private)
bench_rule_load_suspended :: proc(user: rawptr, chunk: int, _: int) {
	state := (^Rule_Load_State)(user)
	total := u64(0)
	for _ in 0 ..< chunk {
		total += rule_load_run(state, true)
	}
	state.sink.value = mm.black_box(total)
}

@(private)
bench_rule_load_derived :: proc(user: rawptr, chunk: int, _: int) {
	state := (^Rule_Load_State)(user)
	total := u64(0)
	for _ in 0 ..< chunk {
		total += rule_load_run(state, false)
	}
	state.sink.value = mm.black_box(total)
}

// --- Registration -----------------------------------------------------------

// Builds a state for each row count, registers the corresponding bench, and
// returns the number of benches registered. The row count is encoded in the
// bench name so the filter can select a single scale.
@(private)
register_store_large :: proc(runner: ^mm.Runner) {
	group := mm.group(
		runner,
		"kernel/store/large",
		mm.throughput_per_op(1, "scan"),
	)
	for rows in ROW_COUNTS {
		state := large_store_state_init(rows)
		mm.bench(group, fmt.aprintf("scan_full_%s", row_name(rows)), state, bench_large_scan_full)
		mm.bench(group, fmt.aprintf("scan_prefix_%s", row_name(rows)), state, bench_large_scan_prefix)
		mm.bench(group, fmt.aprintf("scan_index_%s", row_name(rows)), state, bench_large_scan_index)
	}
}

@(private)
register_bulk_load :: proc(runner: ^mm.Runner) {
	group := mm.group(
		runner,
		"kernel/bulk/large",
		mm.throughput_per_op(1, "load"),
	)
	for rows in ROW_COUNTS {
		unindexed := bulk_state_init(rows, false)
		indexed := bulk_state_init(rows, true)
		mm.bench_capped(group, fmt.aprintf("load_unindexed_%s", row_name(rows)), unindexed, bench_bulk_load, 1)
		mm.bench_capped(group, fmt.aprintf("load_indexed_%s", row_name(rows)), indexed, bench_bulk_load, 1)
	}
}

@(private)
register_closure_large :: proc(runner: ^mm.Runner) {
	group := mm.group(
		runner,
		"kernel/closure/large",
		mm.throughput_per_op(1, "walk"),
	)
	// Chain lengths: 10^3, 10^4, 10^5. 10^6 is the row-count ceiling for
	// the store and bulk benches; a closure walk of 10^6 would take
	// several seconds per op and is not a useful per-run sample.
	chain_lengths := [3]int{1_000, 10_000, 100_000}
	for chain in chain_lengths {
		state := large_closure_state_init(chain)
		mm.bench(group, fmt.aprintf("reaches_chain_%s", row_name(chain)), state, bench_large_closure_reaches)
	}
}

@(private)
register_mem_growth :: proc(runner: ^mm.Runner) {
	group := mm.group(
		runner,
		"kernel/mem/growth",
		mm.throughput_per_op(1, "load"),
	)
	for rows in ROW_COUNTS {
		state := mem_state_init(rows)
		// The memory probe reads VmHWM (peak RSS) before warmup and after
		// the last sample; the harness records the delta in the result's
		// `memory` field. VmHWM is a lifetime high-water, so the delta is
		// run-order-dependent: a later 1M-row bench lifts the peak above
		// what an earlier 10k-row bench can reach, and the earlier bench's
		// delta clamps to zero. For a clean per-scale reading, run with a
		// filter (e.g. `filter=10k`) so only one scale's states are built.
		mm.bench_with_memory(
			group,
			fmt.aprintf("grow_%s", row_name(rows)),
			state,
			bench_mem_grow,
			1,
			mm.peak_rss_bytes,
		)
	}
}

// Encodes a row count in a bench name: 10k, 100k, 1M.
@(private)
row_name :: proc(rows: int) -> string {
	switch rows {
	case 10_000: return "10k"
	case 100_000: return "100k"
	case 1_000_000: return "1M"
	}
	return fmt.aprintf("%d", rows)
}

@(private)
register_rules_large :: proc(runner: ^mm.Runner) {
	group := mm.group(runner, "kernel/rules/large", mm.throughput_per_op(1, "load"))

	// Per-batch fixpoint repetition with a non-recursive rule: ten 2k-fact
	// batches. Suspended, the fixpoint runs once; derived, once per batch.
	mm.bench_capped(
		group,
		"suspended_load_20k",
		rule_load_state_init(20_000, 10, false),
		bench_rule_load_suspended,
		1,
	)
	mm.bench_capped(
		group,
		"derived_load_20k",
		rule_load_state_init(20_000, 10, false),
		bench_rule_load_derived,
		1,
	)
	// Transitive closure growth: four 100-edge batches over a chain. The
	// closure reaches ~80k rows, so the derived variant re-pays it per batch.
	mm.bench_capped(
		group,
		"suspended_chain_400",
		rule_load_state_init(400, 4, true),
		bench_rule_load_suspended,
		1,
	)
	mm.bench_capped(
		group,
		"derived_chain_400",
		rule_load_state_init(400, 4, true),
		bench_rule_load_derived,
		1,
	)
}

// Registers every large-scale bench. Called from `register_kernel_benches` in
// kernel_bench.odin so the `-suite=kernel` run picks them up.
register_kernel_large_benches :: proc(runner: ^mm.Runner) {
	register_store_large(runner)
	register_bulk_load(runner)
	register_closure_large(runner)
	register_mem_growth(runner)
	register_rules_large(runner)
}
