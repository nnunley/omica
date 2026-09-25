// Datalog-style rules: terms, atoms, guards, stratification, and fixpoint
// evaluation.
//
// Rules are evaluated per stratum. Within a stratum the engine iterates to a
// fixpoint, so positive recursion terminates. Negation is stratified: a
// negated atom may only read relations from strictly lower strata. Safety
// validation requires that every head variable and every negated/guard
// variable is bound by a positive body atom.
package kernel

import v "../var"
import "core:mem"
import "core:mem/virtual"
import "core:strings"

// A term in an atom, guard, or rule head.
Term_Kind :: enum {
	Var,
	Value,
}

// A variable or constant term.
Term :: struct {
	kind:   Term_Kind,
	symbol: v.Symbol,
	value:  v.Value,
}

// Creates a variable term.
term_var :: proc(symbol: v.Symbol) -> Term {
	return Term{kind = .Var, symbol = symbol}
}

// Creates a constant term.
term_value :: proc(value: v.Value) -> Term {
	return Term{kind = .Value, value = value}
}

// A relation atom in a rule body.
Atom :: struct {
	relation: Relation_ID,
	terms:    []Term,
	negated:  bool,
}

// Creates a positive atom.
atom_positive :: proc(relation: Relation_ID, terms: []Term) -> Atom {
	return Atom{relation = relation, terms = terms}
}

// Creates a negated atom.
atom_negated :: proc(relation: Relation_ID, terms: []Term) -> Atom {
	return Atom{relation = relation, terms = terms, negated = true}
}

// Comparison operators for rule guards.
Rule_Comparison_Op :: enum {
	Eq,
	Ne,
	Lt,
	Le,
	Gt,
	Ge,
}

// A comparison guard between two terms.
Rule_Guard :: struct {
	op:    Rule_Comparison_Op,
	left:  Term,
	right: Term,
}

// Creates a comparison guard.
rule_guard :: proc(op: Rule_Comparison_Op, left: Term, right: Term) -> Rule_Guard {
	return Rule_Guard{op = op, left = left, right = right}
}

// Kinds of rule body item.
Rule_Body_Kind :: enum {
	Atom,
	Guard,
}

// A body item: an atom or a guard.
Rule_Body_Item :: struct {
	kind:  Rule_Body_Kind,
	atom:  Atom,
	guard: Rule_Guard,
}

// Creates a body item for an atom.
body_atom :: proc(atom: Atom) -> Rule_Body_Item {
	return Rule_Body_Item{kind = .Atom, atom = atom}
}

// Creates a body item for a guard.
body_guard :: proc(guard: Rule_Guard) -> Rule_Body_Item {
	return Rule_Body_Item{kind = .Guard, guard = guard}
}

// A Horn rule: head relation and terms, body items.
Rule :: struct {
	head_relation: Relation_ID,
	head_terms:    []Term,
	body:          []Rule_Body_Item,
}

// Creates a rule.
rule_new :: proc(head_relation: Relation_ID, head_terms: []Term, body: []Rule_Body_Item) -> Rule {
	return Rule{head_relation = head_relation, head_terms = head_terms, body = body}
}

// A rule installed in the world.
Rule_Definition :: struct {
	id:     v.Identity,
	rule:   Rule,
	source: string,
	active: bool,
}

// Creates an active rule definition.
rule_definition :: proc(id: v.Identity, rule: Rule, source: string) -> Rule_Definition {
	return Rule_Definition{id = id, rule = rule, source = source, active = true}
}

@(private)
term_clone :: proc(alloc: mem.Allocator, term: Term) -> Term {
	result := term
	result.value = v.value_deep_copy(alloc, term.value)
	return result
}

// Copies a rule and all of its slices into `alloc`.
rule_clone :: proc(alloc: mem.Allocator, rule: Rule) -> Rule {
	result := rule
	result.head_terms = make([]Term, len(rule.head_terms), alloc)
	for term, i in rule.head_terms {
		result.head_terms[i] = term_clone(alloc, term)
	}

	result.body = make([]Rule_Body_Item, len(rule.body), alloc)
	for item, i in rule.body {
		cloned := item
		if item.kind == .Atom {
			cloned.atom.terms = make([]Term, len(item.atom.terms), alloc)
			for term, j in item.atom.terms {
				cloned.atom.terms[j] = term_clone(alloc, term)
			}
		} else {
			cloned.guard.left = term_clone(alloc, item.guard.left)
			cloned.guard.right = term_clone(alloc, item.guard.right)
		}
		result.body[i] = cloned
	}
	return result
}

// Copies a rule definition into `alloc`.
rule_definition_clone :: proc(
	alloc: mem.Allocator,
	definition: Rule_Definition,
) -> Rule_Definition {
	result := definition
	result.rule = rule_clone(alloc, definition.rule)
	result.source = strings.clone(definition.source, alloc)
	return result
}

// --- Validation and stratification ----------------------------------------

// Builds the set of variables in the positive body atoms of a rule.
positive_body_vars :: proc(rule: Rule, vars: ^map[v.Symbol]bool) {
	for item in rule.body {
		if item.kind != .Atom || item.atom.negated {
			continue
		}
		for term in item.atom.terms {
			if term.kind == .Var {
				vars[term.symbol] = true
			}
		}
	}
}

// Validates that every head, negated-atom, and guard variable is bound by a
// positive body atom. Body safety is checked first so that an unsafe negation
// or guard is reported in preference to an unbound head variable.
rule_validate_safety :: proc(rule: Rule, alloc: mem.Allocator) -> Kernel_Error {
	bound := make(map[v.Symbol]bool, alloc)
	positive_body_vars(rule, &bound)

	for item in rule.body {
		switch item.kind {
		case .Atom:
			if !item.atom.negated {
				continue
			}
			for term in item.atom.terms {
				if term.kind == .Var && !bound[term.symbol] {
					return .Unsafe_Negation
				}
			}
		case .Guard:
			if item.guard.left.kind == .Var && !bound[item.guard.left.symbol] {
				return .Unsafe_Guard
			}
			if item.guard.right.kind == .Var && !bound[item.guard.right.symbol] {
				return .Unsafe_Guard
			}
		}
	}
	for term in rule.head_terms {
		if term.kind == .Var && !bound[term.symbol] {
			return .Unbound_Head_Variable
		}
	}
	return .None
}

// Validates that every atom and the head of a rule use the arity of their
// relation. Unknown relations fail with `Unknown_Relation`.
rule_validate_arity :: proc(rule: Rule, snapshot: ^Snapshot) -> Kernel_Error {
	head, head_found := snapshot_relation_metadata(snapshot, rule.head_relation)
	if !head_found {
		return .Unknown_Relation
	}
	if int(head.arity) != len(rule.head_terms) {
		return .Arity_Mismatch
	}

	for item in rule.body {
		if item.kind != .Atom {
			continue
		}
		metadata, found := snapshot_relation_metadata(snapshot, item.atom.relation)
		if !found {
			return .Unknown_Relation
		}
		if int(metadata.arity) != len(item.atom.terms) {
			return .Arity_Mismatch
		}
	}
	return .None
}

// Orders rules into strata by dependency, adding one level for negation.
// Returns false when positive recursion through negation prevents
// stratification. Maps and result slices are allocated from `alloc`.
rules_stratify :: proc(rules: []Rule, alloc: mem.Allocator) -> ([][]Rule, bool) {
	derived_heads := make(map[Relation_ID]bool, alloc)
	for rule in rules {
		derived_heads[rule.head_relation] = true
	}

	strata := make(map[Relation_ID]int, alloc)
	for relation in derived_heads {
		strata[relation] = 0
	}

	settled := false
	for _ in 0 ..= len(derived_heads) {
		changed := false
		for rule in rules {
			head_stratum := strata[rule.head_relation]
			for item in rule.body {
				if item.kind != .Atom {
					continue
				}
				if !derived_heads[item.atom.relation] {
					continue
				}
				required := strata[item.atom.relation]
				if item.atom.negated {
					required += 1
				}
				if head_stratum < required {
					head_stratum = required
				}
			}
			if strata[rule.head_relation] != head_stratum {
				strata[rule.head_relation] = head_stratum
				changed = true
			}
		}
		if !changed {
			settled = true
			break
		}
	}
	if !settled {
		return nil, false
	}

	max_stratum := 0
	for relation in derived_heads {
		if strata[relation] > max_stratum {
			max_stratum = strata[relation]
		}
	}

	counts := make([]int, max_stratum + 1, alloc)
	for rule in rules {
		counts[strata[rule.head_relation]] += 1
	}

	result := make([][]Rule, max_stratum + 1, alloc)
	for i in 0 ..= max_stratum {
		result[i] = make([]Rule, counts[i], alloc)
	}

	write_indexes := make([]int, max_stratum + 1, alloc)
	for rule in rules {
		stratum := strata[rule.head_relation]
		result[stratum][write_indexes[stratum]] = rule
		write_indexes[stratum] += 1
	}
	return result, true
}

// --- Evaluation ------------------------------------------------------------

// Evaluates active rule definitions over a snapshot. All result storage is
// allocated from `alloc`; the caller owns the arena and destroys it after
// copying the result.
rules_evaluate :: proc(
	alloc: mem.Allocator,
	definitions: []Rule_Definition,
	snapshot: ^Snapshot,
	kernel: ^Kernel = nil,
) -> (
	Rule_Derived,
	Kernel_Error,
) {
	result := rules_derived_create(alloc)
	source := Relation_Source {
		kernel   = kernel,
		snapshot = snapshot,
		derived  = &result,
	}
	if err := rules_evaluate_source(alloc, definitions, &source, &result); err != .None {
		return Rule_Derived{}, err
	}
	return result, .None
}

// Evaluates active rule definitions into `result`, reading extensional facts
// from `source` and adding derived facts to both `result` and the source's
// derived layer. All evaluation storage and result storage come from `alloc`.
//
// Evaluation is semi-naive: a stratum is first evaluated over the current
// state, then re-evaluated while restricting one recursive body atom at a time
// to the facts that the previous round derived. Re-deriving old facts is thus
// avoided.
rules_evaluate_source :: proc(
	alloc: mem.Allocator,
	definitions: []Rule_Definition,
	source: ^Relation_Source,
	result: ^Rule_Derived,
) -> Kernel_Error {
	// Evaluation bookkeeping (binding vectors, dynamic arrays, maps) uses the
	// context allocator, so redirect it to the evaluation arena for the call.
	previous_allocator := context.allocator
	context.allocator = alloc
	defer context.allocator = previous_allocator

	source.delta = nil
	source.delta_active = false
	source.packed = packed_cache_create(alloc)
	defer {
		packed_cache_destroy(source.packed)
		source.packed = nil
	}

	// Batches, join tables and selections live in a scratch arena reset after
	// every rule application; only derived rows (and packed keys) outlive it.
	// context.allocator stays the evaluation arena for computed scanners.
	scratch: virtual.Arena
	if virtual.arena_init_growing(&scratch) != nil {
		panic("failed to initialize rule scratch arena")
	}
	defer virtual.arena_destroy(&scratch)
	scratch_alloc := virtual.arena_allocator(&scratch)

	// Deltas alternate between two round arenas: a round reads the previous
	// delta from one and writes the next into the other, which is cleared
	// first. Only two rounds' deltas are ever held; delta rows copy values
	// whose payloads live in `alloc` or in snapshot blocks, not here.
	rounds_arena: [2]virtual.Arena
	for &round in rounds_arena {
		if virtual.arena_init_growing(&round) != nil {
			panic("failed to initialize rule round arena")
		}
	}
	defer for &round in rounds_arena {
		virtual.arena_destroy(&round)
	}
	current_round := 0

	rules := make([]Rule, len(definitions), alloc)
	write := 0
	for definition in definitions {
		if definition.active {
			rules[write] = definition.rule
			write += 1
		}
	}
	rules = rules[:write]
	if len(rules) == 0 {
		return .None
	}

	rounds := 0
	defer rules_last_rounds = rounds
	// Every exit, errors included, leaves the result readable in full.
	defer rules_derived_thaw(result)

	strata, ok := rules_stratify(rules, alloc)
	if !ok {
		return .Unstratified_Negation
	}

	for stratum in strata {
		stratum_heads := make(map[Relation_ID]bool, alloc)
		for rule in stratum {
			stratum_heads[rule.head_relation] = true
		}

		// Strict semi-naive: every pass reads the result as it stood when the
		// pass began; rows it derives become visible in the next round.
		// Seed the fixpoint with one full evaluation of the stratum.
		rounds += 1
		rules_derived_freeze(result)
		delta := rules_round_delta(&rounds_arena[current_round])
		for rule in stratum {
			_, err := rules_apply(rule, source, result, &delta, alloc, scratch_alloc)
			virtual.arena_free_all(&scratch)
			if err != .None {
				return err
			}
		}

		// Each round evaluates the delta variants of every recursive atom.
		for len(delta.relations) > 0 {
			rounds += 1
			rules_derived_freeze(result)
			other := 1 - current_round
			next := rules_round_delta(&rounds_arena[other])
			for rule in stratum {
				for item, index in rule.body {
					if item.kind != .Atom || item.atom.negated {
						continue
					}
					if !stratum_heads[item.atom.relation] {
						continue
					}
					if rules_derived_count(&delta, item.atom.relation) == 0 {
						continue
					}

					// This variant restricts only body atom `index` to the
					// previous round's rows; other atoms of the same relation
					// read it whole (rules_apply toggles delta_active per scan).
					source.delta = &delta
					source.delta_relation = item.atom.relation
					_, err := rules_apply(rule, source, result, &next, alloc, scratch_alloc, index)
					virtual.arena_free_all(&scratch)
					source.delta_active = false
					source.delta = nil
					if err != .None {
						return err
					}
				}
			}
			delta = next
			current_round = other
		}
		rules_derived_thaw(result)
	}
	return .None
}

// An empty delta in `arena`, cleared of the delta it held two rounds ago.
@(private)
rules_round_delta :: proc(arena: ^virtual.Arena) -> Rule_Derived {
	virtual.arena_free_all(arena)
	return rules_derived_create(virtual.arena_allocator(arena))
}

@(thread_local, private)
rules_last_rounds: int

// Rounds of the calling thread's most recent evaluation: one seed pass per
// stratum plus each semi-naive round (tests).
rules_last_evaluation_rounds :: proc() -> int {
	return rules_last_rounds
}

@(private)
Slot_Map :: struct {
	symbols: []v.Symbol,
}

slot_map_init :: proc(mapping: ^Slot_Map, rule: Rule, alloc: mem.Allocator) {
	symbols: [dynamic]v.Symbol
	defer delete(symbols)
	for term in rule.head_terms {
		if term.kind != .Var {
			continue
		}
		if !slot_map_has(symbols[:], term.symbol) {
			append(&symbols, term.symbol)
		}
	}
	for item in rule.body {
		switch item.kind {
		case .Guard:
			if item.guard.left.kind == .Var && !slot_map_has(symbols[:], item.guard.left.symbol) {
				append(&symbols, item.guard.left.symbol)
			}
			if item.guard.right.kind == .Var &&
			   !slot_map_has(symbols[:], item.guard.right.symbol) {
				append(&symbols, item.guard.right.symbol)
			}
		case .Atom:
			for term in item.atom.terms {
				if term.kind == .Var && !slot_map_has(symbols[:], term.symbol) {
					append(&symbols, term.symbol)
				}
			}
		}
	}
	mapping.symbols = make([]v.Symbol, len(symbols), alloc)
	copy(mapping.symbols, symbols[:])
}

slot_map_has :: proc(symbols: []v.Symbol, symbol: v.Symbol) -> bool {
	for existing in symbols {
		if existing == symbol {
			return true
		}
	}
	return false
}

slot_map_slot :: proc(mapping: ^Slot_Map, symbol: v.Symbol) -> int {
	for existing, i in mapping.symbols {
		if existing == symbol {
			return i
		}
	}
	return -1
}

@(private)
guard_holds :: proc(guard: Rule_Guard, left, right: v.Value) -> bool {
	switch guard.op {
	case .Eq:
		return v.language_numeric_eq(left, right)
	case .Ne:
		return !v.language_numeric_eq(left, right)
	case .Lt:
		return v.language_numeric_cmp(left, right) == .Less
	case .Le:
		order := v.language_numeric_cmp(left, right)
		return order == .Less || order == .Equal
	case .Gt:
		return v.language_numeric_cmp(left, right) == .Greater
	case .Ge:
		order := v.language_numeric_cmp(left, right)
		return order == .Greater || order == .Equal
	}
	return false
}

// Chooses the next body item. Ready guards and negations run first as cheap
// filters; otherwise the positive atom with the most bound variables wins,
// breaking ties by estimated relation size so small relations drive the join.
@(private)
pick_body_item :: proc(
	rule: Rule,
	used: []bool,
	batch: ^Column_Batch,
	slots: ^Slot_Map,
	source: ^Relation_Source,
	delta_index := -1,
) -> (
	int,
	Kernel_Error,
) {
	for item, i in rule.body {
		if used[i] {
			continue
		}
		switch item.kind {
		case .Atom:
			if item.atom.negated && terms_bound_in(item.atom.terms, batch, slots) {
				return i, .None
			}
		case .Guard:
			if terms_bound_in([]Term{item.guard.left, item.guard.right}, batch, slots) {
				return i, .None
			}
		}
	}

	best := -1
	best_bound := -1
	best_rows := 0
	for index in 0 ..< len(rule.body) {
		if used[index] {
			continue
		}
		item := rule.body[index]
		if item.kind != .Atom || item.atom.negated {
			continue
		}
		if required, computed := kernel_computed_required_bindings(
			relation_source_kernel(source),
			item.atom.relation,
		); computed {
			ready := true
			for position in required {
				if int(position) >= len(item.atom.terms) ||
				   !term_bound_in(item.atom.terms[position], batch, slots) {
					ready = false
					break
				}
			}
			if !ready {
				continue
			}
		}
		bound := atom_bound_count(&item.atom, batch, slots)
		rows := rules_source_cardinality(source, item.atom.relation)
		if index == delta_index && source.delta != nil {
			rows = rules_derived_count(source.delta, item.atom.relation)
		}
		if best < 0 || bound > best_bound || (bound == best_bound && rows < best_rows) {
			best = index
			best_bound = bound
			best_rows = rows
		}
	}
	if best >= 0 {
		return best, .None
	}

	// A remaining positive computed atom has an access pattern that prior
	// atoms did not satisfy. Report that contract directly instead of calling
	// the scanner with an unbound key.
	for item, i in rule.body {
		if used[i] || item.kind != .Atom || item.atom.negated {
			continue
		}
		if _, computed := kernel_computed_required_bindings(
			relation_source_kernel(source),
			item.atom.relation,
		); computed {
			return -1, .Computed_Binding_Required
		}
	}

	for item, i in rule.body {
		if used[i] {
			continue
		}
		if item.kind == .Atom && item.atom.negated {
			return -1, .Unsafe_Negation
		}
	}
	return -1, .Unsafe_Guard
}

// Counts the variable terms of an atom that the batch binds.
@(private)
atom_bound_count :: proc(atom: ^Atom, batch: ^Column_Batch, slots: ^Slot_Map) -> int {
	count := 0
	for term in atom.terms {
		if term.kind == .Var && term_bound_in(term, batch, slots) {
			count += 1
		}
	}
	return count
}

// Estimates how many rows a relation contributes to a scan: the delta size
// during semi-naive evaluation, otherwise the visible block length.
@(private)
rules_source_cardinality :: proc(source: ^Relation_Source, relation: Relation_ID) -> int {
	if source != nil &&
	   source.delta_active &&
	   source.delta != nil &&
	   relation == source.delta_relation {
		return rules_derived_count(source.delta, relation)
	}
	block: ^Relation_Block
	if source != nil && source.snapshot != nil {
		if found, ok := snapshot_relation_block(source.snapshot, relation); ok {
			block = found
		}
	} else if source != nil && source.transaction != nil {
		if found, ok := snapshot_relation_block(source.transaction.base, relation); ok {
			block = found
		}
	}
	if block == nil {
		return 0
	}
	return relation_block_len(block)
}
