// Datalog-style rules: terms, atoms, guards, stratification, and fixpoint
// evaluation.
//
// Rules are evaluated per stratum. Within a stratum the engine iterates to a
// fixpoint, so positive recursion terminates. Negation is stratified: a
// negated atom may only read relations from strictly lower strata. Safety
// validation requires that every head variable and every negated/guard
// variable is bound by a positive body atom.
package kernel

import "core:mem"
import "core:mem/virtual"
import "core:strings"
import v "../var"

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

// Derived facts accumulated during rule evaluation. All storage comes from the
// evaluation arena supplied by the caller.
Rule_Derived :: struct {
	relations: [dynamic]Relation_ID,
	rows:      [dynamic][dynamic]v.Tuple,
}

// Creates an empty derived set whose storage is allocated from `alloc`.
rules_derived_create :: proc(alloc: mem.Allocator) -> Rule_Derived {
	return Rule_Derived {
		relations = make([dynamic]Relation_ID, 0, alloc),
		rows      = make([dynamic][dynamic]v.Tuple, 0, alloc),
	}
}

// Returns the rows derived for a relation.
rules_derived_rows :: proc(derived: ^Rule_Derived, relation: Relation_ID) -> []v.Tuple {
	for entry, i in derived.relations {
		if entry == relation {
			return derived.rows[i][:]
		}
	}
	return nil
}

// Adds a derived tuple, returning true when it was new. The tuple and its
// storage are owned by the evaluation arena.
rules_derived_add :: proc(
	derived: ^Rule_Derived,
	alloc: mem.Allocator,
	relation: Relation_ID,
	tuple: v.Tuple,
) -> bool {
	for entry, i in derived.relations {
		if entry != relation {
			continue
		}
		for row in derived.rows[i] {
			if v.tuple_eq(row, tuple) {
				return false
			}
		}
		append(&derived.rows[i], tuple)
		return true
	}
	append(&derived.relations, relation)
	rows := make([dynamic]v.Tuple, 0, alloc)
	append(&rows, tuple)
	append(&derived.rows, rows)
	return true
}

// Visits derived rows matching a partial binding. Returns true when the
// visitor stopped the scan.
rules_derived_visit :: proc(
	derived: ^Rule_Derived,
	relation: Relation_ID,
	bindings: []v.Binding,
	visit: proc(user: rawptr, row: v.Tuple) -> bool,
	user: rawptr,
) -> bool {
	if derived == nil {
		return false
	}
	for entry, i in derived.relations {
		if entry != relation {
			continue
		}
		for row in derived.rows[i] {
			if v.tuple_matches_bindings(row, bindings) {
				if !visit(user, row) {
					return true
				}
			}
		}
	}
	return false
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
) -> (
	Rule_Derived,
	Kernel_Error,
) {
	result := rules_derived_create(alloc)
	source := Relation_Source{snapshot = snapshot, derived = &result}
	if err := rules_evaluate_source(alloc, definitions, &source, &result); err != .None {
		return Rule_Derived{}, err
	}
	return result, .None
}

// Evaluates active rule definitions into `result`, reading extensional facts
// from `source` and adding derived facts to both `result` and the source's
// derived layer. All evaluation storage and result storage come from `alloc`.
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

	strata, ok := rules_stratify(rules, alloc)
	if !ok {
		return .Unstratified_Negation
	}

	for stratum in strata {
		for {
			added := 0
			for rule in stratum {
				rule_added, err := rules_apply(rule, source, result, alloc)
				if err != .None {
					return err
				}
				added += rule_added
			}
			if added == 0 {
				break
			}
		}
	}
	return .None
}

@(private)
Slot_Map :: struct {
	symbols: []v.Symbol,
}

slot_map_init :: proc(mapping: ^Slot_Map, rule: Rule, alloc: mem.Allocator) {
	symbols: [dynamic]v.Symbol
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
			if item.guard.right.kind == .Var && !slot_map_has(symbols[:], item.guard.right.symbol) {
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
Unify_Context :: struct {
	atom:    ^Atom,
	binding: []v.Binding,
	slots:   ^Slot_Map,
	out:     ^[dynamic][]v.Binding,
	alloc:   mem.Allocator,
}

@(private)
unify_visit :: proc(user: rawptr, row: v.Tuple) -> bool {
	ctx := (^Unify_Context)(user)
	next := make([]v.Binding, len(ctx.binding), ctx.alloc)
	copy(next, ctx.binding)

	for term, i in ctx.atom.terms {
		value := v.tuple_values(row)[i]
		switch term.kind {
		case .Value:
			if !v.value_eq(term.value, value) {
				return true
			}
		case .Var:
			slot := slot_map_slot(ctx.slots, term.symbol)
			if next[slot].bound {
				if !v.value_eq(next[slot].value, value) {
					return true
				}
			} else {
				next[slot] = v.binding_of(value)
			}
		}
	}
	append(ctx.out, next)
	return true
}

@(private)
apply_positive_atom :: proc(
	atom: ^Atom,
	bindings: [][]v.Binding,
	slots: ^Slot_Map,
	source: ^Relation_Source,
	alloc: mem.Allocator,
) -> (
	[dynamic][]v.Binding,
	Kernel_Error,
) {
	out: [dynamic][]v.Binding
	for binding in bindings {
		scan_bindings := make([]v.Binding, len(atom.terms), alloc)
		for term, i in atom.terms {
			switch term.kind {
			case .Value:
				scan_bindings[i] = v.binding_of(term.value)
			case .Var:
				slot := slot_map_slot(slots, term.symbol)
				scan_bindings[i] = binding[slot]
			}
		}

		unify := Unify_Context {
			atom    = atom,
			binding = binding,
			slots   = slots,
			out     = &out,
			alloc   = alloc,
		}
		relation_source_visit(source, atom.relation, scan_bindings, unify_visit, &unify)
	}
	return out, .None
}

@(private)
term_is_bound :: proc(term: Term, binding: []v.Binding, slots: ^Slot_Map) -> bool {
	if term.kind == .Value {
		return true
	}
	slot := slot_map_slot(slots, term.symbol)
	if slot < 0 || slot >= len(binding) {
		return false
	}
	return binding[slot].bound
}

@(private)
binding_all_bound :: proc(
	terms: []Term,
	bindings: [][]v.Binding,
	slots: ^Slot_Map,
) -> bool {
	for binding in bindings {
		for term in terms {
			if !term_is_bound(term, binding, slots) {
				return false
			}
		}
	}
	return true
}

@(private)
term_evaluate :: proc(term: Term, binding: []v.Binding, slots: ^Slot_Map) -> (v.Value, Kernel_Error) {
	if term.kind == .Value {
		return term.value, .None
	}
	slot := slot_map_slot(slots, term.symbol)
	if slot < 0 || slot >= len(binding) || !binding[slot].bound {
		return v.Value(0), .Unbound_Head_Variable
	}
	return binding[slot].value, .None
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

@(private)
Negated_Visit_Context :: struct {
	found: bool,
}

@(private)
negated_visit :: proc(user: rawptr, row: v.Tuple) -> bool {
	ctx := (^Negated_Visit_Context)(user)
	ctx.found = true
	return false
}

@(private)
apply_negated_atom :: proc(
	atom: ^Atom,
	bindings: [][]v.Binding,
	slots: ^Slot_Map,
	source: ^Relation_Source,
	alloc: mem.Allocator,
) -> (
	[dynamic][]v.Binding,
	Kernel_Error,
) {
	if !binding_all_bound(atom.terms, bindings, slots) {
		return {}, .Unsafe_Negation
	}

	out: [dynamic][]v.Binding
	for binding in bindings {
		scan_bindings := make([]v.Binding, len(atom.terms), alloc)
		for term, i in atom.terms {
			switch term.kind {
			case .Value:
				scan_bindings[i] = v.binding_of(term.value)
			case .Var:
				slot := slot_map_slot(slots, term.symbol)
				scan_bindings[i] = binding[slot]
			}
		}
		state := Negated_Visit_Context{}
		relation_source_visit(source, atom.relation, scan_bindings, negated_visit, &state)
		if !state.found {
			next := make([]v.Binding, len(binding), alloc)
			copy(next, binding)
			append(&out, next)
		}
	}
	return out, .None
}

@(private)
apply_guard :: proc(
	guard: Rule_Guard,
	bindings: [][]v.Binding,
	slots: ^Slot_Map,
	alloc: mem.Allocator,
) -> (
	[dynamic][]v.Binding,
	Kernel_Error,
) {
	terms := []Term{guard.left, guard.right}
	if !binding_all_bound(terms, bindings, slots) {
		return {}, .Unsafe_Guard
	}

	out: [dynamic][]v.Binding
	for binding in bindings {
		left, left_err := term_evaluate(guard.left, binding, slots)
		if left_err != .None {
			return {}, left_err
		}
		right, right_err := term_evaluate(guard.right, binding, slots)
		if right_err != .None {
			return {}, right_err
		}
		if guard_holds(guard, left, right) {
			next := make([]v.Binding, len(binding), alloc)
			copy(next, binding)
			append(&out, next)
		}
	}
	return out, .None
}

@(private)
pick_body_item :: proc(
	rule: Rule,
	used: []bool,
	bindings: [][]v.Binding,
	slots: ^Slot_Map,
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
			if !item.atom.negated {
				return i, .None
			}
			if binding_all_bound(item.atom.terms, bindings, slots) {
				return i, .None
			}
		case .Guard:
			terms := []Term{item.guard.left, item.guard.right}
			if binding_all_bound(terms, bindings, slots) {
				return i, .None
			}
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

@(private)
rules_apply :: proc(
	rule: Rule,
	source: ^Relation_Source,
	result: ^Rule_Derived,
	alloc: mem.Allocator,
) -> (
	int,
	Kernel_Error,
) {
	slots: Slot_Map
	slot_map_init(&slots, rule, alloc)

	bindings: [dynamic][]v.Binding
	initial := make([]v.Binding, len(slots.symbols), alloc)
	append(&bindings, initial)

	used := make([]bool, len(rule.body), alloc)
	remaining := len(rule.body)
	for remaining > 0 {
		index, pick_err := pick_body_item(rule, used, bindings[:], &slots)
		if pick_err != .None {
			return 0, pick_err
		}
		item := rule.body[index]
		used[index] = true
		remaining -= 1

		next: [dynamic][]v.Binding
		apply_err: Kernel_Error
		switch item.kind {
		case .Atom:
			if item.atom.negated {
				next, apply_err = apply_negated_atom(&item.atom, bindings[:], &slots, source, alloc)
			} else {
				next, apply_err = apply_positive_atom(&item.atom, bindings[:], &slots, source, alloc)
			}
		case .Guard:
			next, apply_err = apply_guard(item.guard, bindings[:], &slots, alloc)
		}
		if apply_err != .None {
			return 0, apply_err
		}
		bindings = next
	}

	added := 0
	for binding in bindings {
		values := make([]v.Value, len(rule.head_terms), alloc)
		for term, i in rule.head_terms {
			value, term_err := term_evaluate(term, binding, &slots)
			if term_err != .None {
				return 0, term_err
			}
			values[i] = value
		}
		tuple := v.tuple_from_slice(values)
		if rules_derived_add(result, alloc, rule.head_relation, tuple) {
			added += 1
		}
	}
	return added, .None
}
