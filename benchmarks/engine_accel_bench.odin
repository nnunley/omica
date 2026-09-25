// Engine-level accelerator benchmarks: whole rule evaluations
// (k.rules_evaluate) run under each strategy, so the numbers measure omica,
// not an isolated operator. Before registering a strategy's variant, one
// evaluation must produce the same derived rows as the CPU reference; the
// check prints the rows and the placement outcomes it recorded.
package main

import "core:fmt"
import "core:mem"
import "core:mem/virtual"

import mm "../vendor/micromeasure/micromeasure-odin"
import accl "../mica/kernel/accel"
import k "../mica/kernel"
import v "../mica/var"

// 262,144 items, every third held: Free(x) :- Item(x), not Held(x).
NEGATION_ITEMS :: 262_144

Negation_State :: struct {
	arena:         virtual.Arena,
	scratch:       virtual.Arena,
	alloc:         mem.Allocator,
	scratch_alloc: mem.Allocator,
	kernel:        k.Kernel,
	snapshot:      ^k.Snapshot,
	rules:         []k.Rule_Definition,
	sink:          Sink,
}

@(private)
negation_state_init :: proc() -> ^Negation_State {
	state := new(Negation_State)
	if virtual.arena_init_growing(&state.arena) != nil || virtual.arena_init_growing(&state.scratch) != nil {
		panic("failed to initialize negation benchmark arenas")
	}
	state.alloc = virtual.arena_allocator(&state.arena)
	state.scratch_alloc = virtual.arena_allocator(&state.scratch)
	k.kernel_init(&state.kernel)
	item := create_relation(&state.kernel, 30, "Item", 1)
	held := create_relation(&state.kernel, 31, "Held", 1)
	free := create_relation(&state.kernel, 32, "Free", 1)
	x := v.symbol_intern("x")
	rule := k.rule_new(free, []k.Term{k.term_var(x)}, []k.Rule_Body_Item {
		k.body_atom(k.atom_positive(item, []k.Term{k.term_var(x)})),
		k.body_atom(k.atom_negated(held, []k.Term{k.term_var(x)})),
	})
	snapshot, err := k.kernel_install_rule(&state.kernel, v.Identity(40), rule, "negation_large")
	assert(err == .None)
	k.snapshot_release(snapshot)
	// Derivation is suspended while seeding so the commit does not evaluate
	// the rule 262k rows at a time on the way in.
	k.kernel_set_derivation(&state.kernel, false)
	tx := k.kernel_begin(&state.kernel)
	for i in 0 ..< NEGATION_ITEMS {
		id := v.value_identity(bench_identity(u64(1_000_000 + i)))
		assert(k.transaction_assert(&tx, item, v.tuple_new(state.alloc, []v.Value{id})) == .None)
		if i % 3 == 0 {
			assert(k.transaction_assert(&tx, held, v.tuple_new(state.alloc, []v.Value{id})) == .None)
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

// One evaluation of `rules` against `snapshot` in a reset scratch arena;
// returns the total derived rows and an order-independent digest of their
// contents (wrapping sum of per-row hashes mixed with the relation).
@(private)
engine_evaluate :: proc(scratch: ^virtual.Arena, scratch_alloc: mem.Allocator, rules: []k.Rule_Definition, snapshot: ^k.Snapshot) -> (total: u64, digest: u64) {
	virtual.arena_free_all(scratch)
	derived, err := k.rules_evaluate(scratch_alloc, rules, snapshot)
	if err != .None {
		return 0, 0
	}
	for entry in derived.relations {
		hashes := k.rules_derived_hashes(&derived, entry.relation)
		total += u64(len(hashes))
		for hash in hashes {
			digest += hash ~ (u64(entry.relation) * 0x9e3779b97f4a7c15)
		}
	}
	return
}

@(private)
negation_rows :: proc(user: rawptr) -> (u64, u64) {
	s := (^Negation_State)(user)
	return engine_evaluate(&s.scratch, s.scratch_alloc, s.rules, s.snapshot)
}

@(private)
visible_rows :: proc(user: rawptr) -> (u64, u64) {
	s := (^Visible_State)(user)
	return engine_evaluate(&s.scratch, s.scratch_alloc, s.rules, s.snapshot)
}

// One registered (workload, strategy) pair.
Engine_Case :: struct {
	state:    rawptr,
	rows:     proc(user: rawptr) -> (u64, u64),
	strategy: accl.Strategy,
	sink:     Sink,
}

@(private)
bench_engine_case :: proc(user: rawptr, chunk: int, _: int) {
	c := (^Engine_Case)(user)
	accl.select_strategy(c.strategy)
	defer accl.use_cpu()
	total := u64(0)
	for _ in 0 ..< chunk {
		rows, _ := c.rows(c.state)
		total += rows
	}
	c.sink.value = mm.black_box(total)
}

// Runs one evaluation under `strategy` and reports rows, their digest, and
// the negated membership outcomes it recorded on this thread.
@(private)
engine_check :: proc(label: string, state: rawptr, rows: proc(rawptr) -> (u64, u64), strategy: accl.Strategy) -> (total: u64, digest: u64, completed: u64) {
	accl.select_strategy(strategy)
	defer accl.use_cpu()
	before := k.placement_counts_this_thread()
	total, digest = rows(state)
	delta := k.placement_counts_delta(before, k.placement_counts_this_thread())
	completed = delta[.Negated_Membership][.Completed]
	fmt.eprintf("accel-check: %s %s rows=%d digest=%x negated_membership=%v\n", label, strategy.name, total, digest, delta[.Negated_Membership])
	return
}

register_engine_accel_benches :: proc(runner: ^mm.Runner) {
	strategies := make([dynamic]accl.Strategy)
	append(&strategies, accl.cpu_strategy(), accl.cpu_parallel_strategy())
	when ODIN_OS == .Darwin {
		if s := accl.metal_strategy(); s.available() {
			append(&strategies, s)
		}
	}
	when ODIN_OS == .Linux {
		if accl.cuda_select_device(0) {
			append(&strategies, accl.cuda_strategy())
		}
	}
	accl.use_cpu()

	Workload :: struct {
		name:  string,
		state: rawptr,
		rows:  proc(rawptr) -> (u64, u64),
	}
	workloads := []Workload {
		{"visible_items_rule", visible_state_init(), visible_rows},
		{"negation_large_262k", negation_state_init(), negation_rows},
	}
	group := mm.group(runner, "kernel/rules_accel")
	for w in workloads {
		reference_rows, reference_digest, _ := engine_check(w.name, w.state, w.rows, strategies[0])
		for s in strategies {
			rows, digest, completed := engine_check(w.name, w.state, w.rows, s)
			if rows != reference_rows || digest != reference_digest {
				fmt.eprintf("accel-check: %s %s rows %d/%x differ from the CPU reference %d/%x; variant skipped\n", w.name, s.name, rows, digest, reference_rows, reference_digest)
				continue
			}
			// A strategy that completed nothing measures the CPU fallback, not
			// itself: say so in the benchmark name.
			suffix := completed > 0 ? "" : "_declined"
			c := new(Engine_Case)
			c^ = Engine_Case{state = w.state, rows = w.rows, strategy = s}
			mm.bench(group, fmt.aprintf("%s_%s%s", w.name, s.name, suffix), c, bench_engine_case)
		}
	}
}
