// An independent oracle for rule evaluation (docs/accel-engine-design.md §6,
// Testing and gates): a naive stratified fixpoint that reads extensional rows
// through the snapshot API and shares no code with the evaluator. Random
// programs drawn from a menu of rule shapes (joins, repeated variables,
// constants, guards, one-, two- and three-position negation, recursion, cross
// products, heap values) must derive exactly what the oracle derives, on the
// commit path and under every strategy.
package kernel

import "core:mem"
import "core:mem/virtual"
import "core:slice"
import "core:sync"
import "core:testing"
import accel "./accel"
import v "../var"

@(private = "file")
Oracle_Env :: struct {
	count:   int,
	symbols: [8]v.Symbol,
	values:  [8]v.Value,
}

@(private = "file")
oracle_term :: proc(env: ^Oracle_Env, term: Term) -> (v.Value, bool) {
	if term.kind == .Value {
		return term.value, true
	}
	for i in 0 ..< env.count {
		if env.symbols[i] == term.symbol {
			return env.values[i], true
		}
	}
	return 0, false
}

// Extends env so that `terms` equal `row`; false on a mismatch.
@(private = "file")
oracle_unify :: proc(env: ^Oracle_Env, terms: []Term, row: v.Tuple) -> bool {
	values := v.tuple_values(row)
	for term, i in terms {
		if value, ok := oracle_term(env, term); ok {
			if !v.value_eq(value, values[i]) {
				return false
			}
		} else {
			env.symbols[env.count] = term.symbol
			env.values[env.count] = values[i]
			env.count += 1
		}
	}
	return true
}

@(private = "file")
oracle_contains :: proc(rows: []v.Tuple, row: v.Tuple) -> bool {
	for r in rows {
		if v.tuple_eq(r, row) {
			return true
		}
	}
	return false
}

@(private = "file")
oracle_guard :: proc(op: Rule_Comparison_Op, left, right: v.Value) -> bool {
	order := v.language_numeric_cmp(left, right)
	switch op {
	case .Eq:
		return v.language_numeric_eq(left, right)
	case .Ne:
		return !v.language_numeric_eq(left, right)
	case .Lt:
		return order == .Less
	case .Le:
		return order == .Less || order == .Equal
	case .Gt:
		return order == .Greater
	case .Ge:
		return order == .Greater || order == .Equal
	}
	return false
}

@(private = "file")
Oracle_Facts :: map[Relation_ID][dynamic]v.Tuple

@(private = "file")
oracle_rows :: proc(facts: ^Oracle_Facts, relation: Relation_ID) -> []v.Tuple {
	rows := facts^[relation]
	return rows[:]
}

// Every head tuple of `rule` over `facts`: positive atoms in body order by
// nested loops, then negations and guards as filters.
@(private = "file")
oracle_solve :: proc(
	rule: ^Rule,
	positives: []Atom,
	env: Oracle_Env,
	facts: ^Oracle_Facts,
	out: ^[dynamic]v.Tuple,
	alloc: mem.Allocator,
) {
	env := env
	if len(positives) == 0 {
		for item in rule.body {
			switch item.kind {
			case .Atom:
				if !item.atom.negated {
					continue
				}
				values := make([]v.Value, len(item.atom.terms), alloc)
				for term, i in item.atom.terms {
					values[i], _ = oracle_term(&env, term)
				}
				if oracle_contains(oracle_rows(facts, item.atom.relation), v.Tuple(values)) {
					return
				}
			case .Guard:
				left, _ := oracle_term(&env, item.guard.left)
				right, _ := oracle_term(&env, item.guard.right)
				if !oracle_guard(item.guard.op, left, right) {
					return
				}
			}
		}
		head := make([]v.Value, len(rule.head_terms), alloc)
		for term, i in rule.head_terms {
			head[i], _ = oracle_term(&env, term)
		}
		append(out, v.Tuple(head))
		return
	}
	atom := positives[0]
	for row in oracle_rows(facts, atom.relation) {
		next := env
		if oracle_unify(&next, atom.terms, row) {
			oracle_solve(rule, positives[1:], next, facts, out, alloc)
		}
	}
}

// Naive fixpoint per layer; layers are evaluated in order, so a negated
// relation is complete before any rule negates it.
@(private = "file")
oracle_evaluate :: proc(
	snapshot: ^Snapshot,
	base: []Relation_ID,
	layers: [][dynamic]Rule,
	alloc: mem.Allocator,
) -> Oracle_Facts {
	context.allocator = alloc
	facts := make(Oracle_Facts, alloc)
	for relation in base {
		metadata, _ := snapshot_relation_metadata(snapshot, relation)
		rows := make([dynamic]v.Tuple, alloc)
		snapshot_visit_extensional(
			snapshot,
			relation,
			make([]v.Binding, int(metadata.arity), alloc),
			proc(user: rawptr, row: v.Tuple) -> bool {
				append((^[dynamic]v.Tuple)(user), row)
				return true
			},
			&rows,
		)
		facts[relation] = rows
	}
	for layer in layers {
		for changed := true; changed; {
			changed = false
			for i in 0 ..< len(layer) {
				rule := &layer[i]
				positives := make([dynamic]Atom, alloc)
				for item in rule.body {
					if item.kind == .Atom && !item.atom.negated {
						append(&positives, item.atom)
					}
				}
				found := make([dynamic]v.Tuple, alloc)
				oracle_solve(rule, positives[:], Oracle_Env{}, &facts, &found, alloc)
				rows := facts[rule.head_relation]
				for row in found {
					if !oracle_contains(rows[:], row) {
						append(&rows, row)
						changed = true
					}
				}
				facts[rule.head_relation] = rows
			}
		}
	}
	return facts
}

// Base: E(2) F(2) N(1) M(2). Layer 0: P(2) Q(1). Layer 1: R(1) S(2) T(3).
// Layer 2: U(1).
@(private = "file")
Oracle_Relations :: struct {
	e, f, n, m, p, q, r, s, tt, u: Relation_ID,
}

// Draws a program from the menu. Runs with context.allocator set to the test
// arena: every slice a rule keeps is cloned there, since variadic arguments
// and slice literals live on the stack.
@(private = "file")
oracle_program :: proc(rng: ^Property_Rng, rel: Oracle_Relations, domain: []v.Value) -> (layers: [3][dynamic]Rule) {
	x, y, z := v.symbol_intern("x"), v.symbol_intern("y"), v.symbol_intern("z")
	X, Y, Z := term_var(x), term_var(y), term_var(z)
	pick := proc(rng: ^Property_Rng, domain: []v.Value) -> Term {
		return term_value(domain[property_next(rng) % u64(len(domain))])
	}
	pos := proc(r: Relation_ID, terms: ..Term) -> Rule_Body_Item {
		return body_atom(atom_positive(r, slice.clone(terms)))
	}
	neg := proc(r: Relation_ID, terms: ..Term) -> Rule_Body_Item {
		return body_atom(atom_negated(r, slice.clone(terms)))
	}
	heads := proc(terms: ..Term) -> []Term {
		return slice.clone(terms)
	}
	body := proc(items: ..Rule_Body_Item) -> []Rule_Body_Item {
		return slice.clone(items)
	}
	on := proc(rng: ^Property_Rng) -> bool {
		return property_next(rng) % 2 == 0
	}
	c := pick(rng, domain)
	d := pick(rng, domain)
	// Layer 0
	append(&layers[0], rule_new(rel.p, heads(X, Y), body(pos(rel.e, X, Y))))
	if on(rng) {append(&layers[0], rule_new(rel.p, heads(X, Z), body(pos(rel.p, X, Y), pos(rel.f, Y, Z))))}
	if on(rng) {append(&layers[0], rule_new(rel.p, heads(X, Z), body(pos(rel.e, X, Y), pos(rel.e, Y, Z), body_guard(rule_guard(.Ne, X, Z)))))}
	if on(rng) {append(&layers[0], rule_new(rel.q, heads(X), body(pos(rel.e, X, X))))}
	if on(rng) {append(&layers[0], rule_new(rel.q, heads(Y), body(pos(rel.f, c, Y))))}
	if on(rng) {append(&layers[0], rule_new(rel.p, heads(X, Y), body(pos(rel.f, X, Y), pos(rel.n, X))))}
	if on(rng) {append(&layers[0], rule_new(rel.q, heads(X), body(pos(rel.p, X, Y), body_guard(rule_guard(.Lt, Y, d)))))}
	if on(rng) {append(&layers[0], rule_new(rel.q, heads(X), body(pos(rel.n, X), pos(rel.f, Y, Y))))}
	// Layer 1
	if on(rng) {append(&layers[1], rule_new(rel.r, heads(X), body(pos(rel.q, X), neg(rel.n, X))))}
	if on(rng) {append(&layers[1], rule_new(rel.s, heads(X, Y), body(pos(rel.p, X, Y), neg(rel.m, X, Y))))}
	if on(rng) {append(&layers[1], rule_new(rel.r, heads(X), body(pos(rel.e, X, Y), neg(rel.q, Y))))}
	if on(rng) {append(&layers[1], rule_new(rel.s, heads(X, Y), body(pos(rel.p, X, Y), neg(rel.e, Y, X))))}
	if on(rng) {append(&layers[1], rule_new(rel.tt, heads(X, Y, Z), body(pos(rel.e, X, Y), pos(rel.f, Y, Z), neg(rel.p, X, Z))))}
	if on(rng) {append(&layers[1], rule_new(rel.s, heads(X, c), body(pos(rel.q, X), neg(rel.m, X, c))))}
	// Layer 2
	if on(rng) {append(&layers[2], rule_new(rel.u, heads(X), body(pos(rel.n, X), neg(rel.tt, X, X, X))))}
	if on(rng) {append(&layers[2], rule_new(rel.u, heads(Y), body(pos(rel.s, X, Y), pos(rel.s, Y, X), body_guard(rule_guard(.Eq, X, Y)))))}
	return
}

@(private = "file")
oracle_strategies :: proc() -> [dynamic]accel.Strategy {
	out := make([dynamic]accel.Strategy)
	append(&out, accel.cpu_strategy(), accel.cpu_parallel_strategy())
	when ODIN_OS == .Darwin {
		if s := accel.metal_strategy(); s.available() {
			append(&out, s)
		}
	}
	when ODIN_OS == .Linux {
		if accel.cuda_select_device(0) {
			append(&out, accel.cuda_strategy())
		}
	}
	return out
}

@(private = "file")
oracle_expect_rows :: proc(t: ^testing.T, sample: int, label: string, relation: Relation_ID, got, want: []v.Tuple) {
	testing.expectf(t, len(got) == len(want), "sample %d %s relation %v: %d rows, oracle %d", sample, label, relation, len(got), len(want))
	for row in got {
		testing.expectf(t, oracle_contains(want, row), "sample %d %s relation %v: unexpected row %v", sample, label, relation, row)
	}
}

@(test)
test_rule_programs_match_oracle :: proc(t: ^testing.T) {
	sync.mutex_lock(&strategy_tests_lock)
	defer sync.mutex_unlock(&strategy_tests_lock)
	defer accel.use_cpu()
	arena: virtual.Arena
	testing.expect(t, virtual.arena_init_growing(&arena) == nil)
	defer virtual.arena_destroy(&arena)
	alloc := virtual.arena_allocator(&arena)

	domain := []v.Value {
		must_int(1),
		must_int(2),
		must_int(3),
		must_int(4),
		must_int(5),
		v.value_string(alloc, "a"),
		v.value_string(alloc, "b"),
	}
	// Heap, not temp: kernel commits free the temp allocator.
	strategies := oracle_strategies()
	defer delete(strategies)
	rng := Property_Rng{state = 0x9e3779b97f4a7c15}

	for sample in 0 ..< 40 {
		kernel: Kernel
		kernel_init(&kernel)
		rel := Oracle_Relations {
			e  = create_relation(&kernel, 1, "E", 2),
			f  = create_relation(&kernel, 2, "F", 2),
			n  = create_relation(&kernel, 3, "N", 1),
			m  = create_relation(&kernel, 4, "M", 2),
			p  = create_relation(&kernel, 10, "P", 2),
			q  = create_relation(&kernel, 11, "Q", 1),
			r  = create_relation(&kernel, 20, "R", 1),
			s  = create_relation(&kernel, 21, "S", 2),
			tt = create_relation(&kernel, 22, "T", 3),
			u  = create_relation(&kernel, 30, "U", 1),
		}
		layers: [3][dynamic]Rule
		{
			context.allocator = alloc
			layers = oracle_program(&rng, rel, domain)
		}
		id := u64(1000)
		for layer in layers {
			for rule in layer {
				installed, err := kernel_install_rule(&kernel, v.Identity(id), rule, "oracle")
				testing.expectf(t, err == .None, "sample %d: install failed: %v", sample, err)
				snapshot_release(installed)
				id += 1
			}
		}
		tx := kernel_begin(&kernel)
		for a in domain {
			if property_next(&rng) % 3 == 0 {
				transaction_assert(&tx, rel.n, tuple_of(a))
			}
			for b in domain {
				if property_next(&rng) % 5 == 0 {transaction_assert(&tx, rel.e, tuple_of(a, b))}
				if property_next(&rng) % 5 == 0 {transaction_assert(&tx, rel.f, tuple_of(a, b))}
				if property_next(&rng) % 5 == 0 {transaction_assert(&tx, rel.m, tuple_of(a, b))}
			}
		}
		commit_transaction(t, &tx)

		snapshot := kernel.current
		want := oracle_evaluate(snapshot, []Relation_ID{rel.e, rel.f, rel.n, rel.m}, layers[:], alloc)
		derived_relations := []Relation_ID{rel.p, rel.q, rel.r, rel.s, rel.tt, rel.u}
		for relation in derived_relations {
			oracle_expect_rows(t, sample, "commit", relation, snapshot_derived_rows(snapshot, relation), oracle_rows(&want, relation))
		}
		// Both join paths: 0 hash-joins whenever keys exist, max(int) looks up
		// every row through the relation's access paths.
		previous := rules_small_batch_rows
		for threshold in ([]int{0, max(int)}) {
			rules_small_batch_rows = threshold
			for s in strategies {
				evaluation: virtual.Arena
				testing.expect(t, virtual.arena_init_growing(&evaluation) == nil)
				accel.select_strategy(s)
				got, err := rules_evaluate(virtual.arena_allocator(&evaluation), snapshot.rules, snapshot, &kernel)
				accel.use_cpu()
				testing.expectf(t, err == .None, "sample %d %s: %v", sample, s.name, err)
				for relation in derived_relations {
					oracle_expect_rows(t, sample, s.name, relation, rules_derived_tuples(&got, relation, alloc), oracle_rows(&want, relation))
				}
				virtual.arena_destroy(&evaluation)
			}
		}
		rules_small_batch_rows = previous
		kernel_destroy(&kernel)
		free_all(context.temp_allocator)
		virtual.arena_free_all(&arena)
		// The domain's strings lived in the arena: recreate them for the next sample.
		domain[5] = v.value_string(alloc, "a")
		domain[6] = v.value_string(alloc, "b")
	}
}
