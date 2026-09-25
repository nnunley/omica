// Rule application over column batches (docs/accel-engine-design.md §6).
// Each body step turns one Column_Batch into the next: positive atoms join
// (a hash join, or per-row lookups through the relation's access paths for
// small batches and computed relations), negated atoms and guards narrow the
// selection, and the head gathers columns into the derived relation. Every
// read goes through relation_source_scan_columns/_append. Batches use the
// scratch allocator, reset by the caller after each application; derived rows
// and packed keys use the evaluation arena.
package kernel

import "core:mem"
import "core:slice"
import v "../var"
import accel "./accel"

// Live rows at or below this count look each row up through the relation's
// access paths instead of hash-joining. A variable so tests can force either
// path; both give identical results.
rules_small_batch_rows := 16

@(private)
Rule_Step :: struct {
	slots:   ^Slot_Map,
	source:  ^Relation_Source,
	scratch: mem.Allocator,
}

@(private)
term_bound_in :: proc(term: Term, batch: ^Column_Batch, slots: ^Slot_Map) -> bool {
	if term.kind == .Value {
		return true
	}
	slot := slot_map_slot(slots, term.symbol)
	return slot >= 0 && slot < len(batch.bound) && batch.bound[slot]
}

@(private)
terms_bound_in :: proc(terms: []Term, batch: ^Column_Batch, slots: ^Slot_Map) -> bool {
	for term in terms {
		if !term_bound_in(term, batch, slots) {
			return false
		}
	}
	return true
}

// A term's values over the live rows: a constant broadcast, or its slot's
// column gathered through the selection. `unbound` is the error when the
// variable is not bound.
@(private)
term_live_column :: proc(step: ^Rule_Step, batch: ^Column_Batch, term: Term, unbound: Kernel_Error) -> ([]v.Value, Kernel_Error) {
	n := column_batch_live(batch)
	if term.kind == .Value {
		out := make([]v.Value, n, step.scratch)
		for i in 0 ..< n {
			out[i] = term.value
		}
		return out, .None
	}
	slot := slot_map_slot(step.slots, term.symbol)
	if slot < 0 || !batch.bound[slot] {
		return nil, unbound
	}
	return column_batch_live_column(batch, slot, step.scratch), .None
}

// Applies one rule to `source`, adding new head rows to `result` and, when
// non-nil, `delta`. `scratch` holds every batch; the caller resets it after
// the call. Derived rows are stored through `result`'s own allocator.
rules_apply :: proc(
	rule: Rule,
	source: ^Relation_Source,
	result: ^Rule_Derived,
	delta: ^Rule_Derived,
	alloc: mem.Allocator,
	scratch: mem.Allocator,
) -> (
	int,
	Kernel_Error,
) {
	rule := rule
	slots: Slot_Map
	slot_map_init(&slots, rule, scratch)
	step := Rule_Step {
		slots   = &slots,
		source  = source,
		scratch = scratch,
	}
	batch := column_batch_unit(len(slots.symbols), scratch)
	used := make([]bool, len(rule.body), scratch)
	for remaining := len(rule.body); remaining > 0; remaining -= 1 {
		// An empty batch derives nothing; later steps are skipped, as the row
		// evaluator's empty binding set made them no-ops.
		if column_batch_live(&batch) == 0 {
			return 0, .None
		}
		index, pick_err := pick_body_item(rule, used, &batch, &slots, source)
		if pick_err != .None {
			return 0, pick_err
		}
		used[index] = true
		item := &rule.body[index]
		err: Kernel_Error
		switch item.kind {
		case .Atom:
			if item.atom.negated {
				err = apply_negated_columns(&step, &item.atom, &batch)
			} else {
				batch, err = apply_positive_columns(&step, &item.atom, &batch)
			}
		case .Guard:
			err = apply_guard_columns(&step, item.guard, &batch)
		}
		if err != .None {
			return 0, err
		}
	}
	n := column_batch_live(&batch)
	if n == 0 {
		return 0, .None
	}
	columns := make([][]v.Value, len(rule.head_terms), scratch)
	for term, i in rule.head_terms {
		column, err := term_live_column(&step, &batch, term, .Unbound_Head_Variable)
		if err != .None {
			return 0, err
		}
		columns[i] = column
	}
	return rules_derived_add_columns(result, delta, rule.head_relation, columns, n, scratch), .None
}

@(private)
apply_guard_columns :: proc(step: ^Rule_Step, guard: Rule_Guard, batch: ^Column_Batch) -> Kernel_Error {
	left, left_err := term_live_column(step, batch, guard.left, .Unsafe_Guard)
	if left_err != .None {
		return left_err
	}
	right, right_err := term_live_column(step, batch, guard.right, .Unsafe_Guard)
	if right_err != .None {
		return right_err
	}
	keep := make([dynamic]u32, 0, len(left), step.scratch)
	for i in 0 ..< len(left) {
		if guard_holds(guard, left[i], right[i]) {
			append(&keep, u32(i))
		}
	}
	column_batch_select(batch, keep[:], step.scratch)
	return .None
}

// --- Negated atoms --------------------------------------------------------

@(private)
apply_negated_columns :: proc(step: ^Rule_Step, atom: ^Atom, batch: ^Column_Batch) -> Kernel_Error {
	probes := make([][]v.Value, len(atom.terms), step.scratch)
	fixed := true
	for term, p in atom.terms {
		column, err := term_live_column(step, batch, term, .Unsafe_Negation)
		if err != .None {
			return err
		}
		probes[p] = column
		if term.kind == .Value {
			fixed = fixed && v.value_is_immediate(term.value)
		} else {
			fixed = fixed && batch.fixed[slot_map_slot(step.slots, term.symbol)]
		}
	}
	n := column_batch_live(batch)
	absent, ok := negated_absent_packed(step, atom, probes, fixed, n)
	if !ok {
		err: Kernel_Error
		absent, err = negated_absent_hashed(step, atom, probes, n)
		if err != .None {
			return err
		}
	}
	column_batch_select(batch, absent, step.scratch)
	return .None
}

// Stage 1's membership over packed keys, on column probes: one or two
// positions of fixed-width values. Returns the live rows whose key is absent;
// ok=false declines to the hashed path. Every outcome is counted under
// .Negated_Membership.
@(private)
negated_absent_packed :: proc(step: ^Rule_Step, atom: ^Atom, probes: [][]v.Value, fixed: bool, n: int) -> ([]u32, bool) {
	width := len(probes)
	if width < 1 || width > 2 {
		placement_record(.Negated_Membership, .Unsupported)
		return nil, false
	}
	if !fixed {
		placement_record(.Negated_Membership, .Not_Packable)
		return nil, false
	}
	entry, found := packed_cache_lookup(step.source, atom.relation, width)
	if !found {
		placement_record(.Negated_Membership, entry == nil ? .Unsupported : .Not_Packable)
		return nil, false
	}
	left := make([][]u64, width, step.scratch)
	for p in 0 ..< width {
		left[p] = slice.reinterpret([]u64, probes[p])
	}
	// Single keys on a strategy with a residency threshold prepare one device
	// copy per evaluation, once a step is large enough to pay for the upload.
	strategy := accel.active_strategy()
	if width == 1 && !entry.prepare_tried && strategy.prepare_column != nil &&
	   strategy.resident_min_probes > 0 && n >= strategy.resident_min_probes {
		entry.prepare_tried = true
		step.source.packed.prepares += 1
		if prepared, prepared_ok := accel.prepare_column(strategy, entry.keys.columns[0]); prepared_ok {
			entry.prepared, entry.strategy = prepared, strategy
		}
	}
	absent: []u32
	result: accel.Membership_Result
	if width == 1 && entry.prepared.handle != nil {
		absent, result = accel.membership_selection_prepared(strategy, left[0], entry.prepared, false, step.scratch)
	} else {
		absent, result = accel.membership_selection(strategy, left, entry.keys.columns, false, step.scratch)
	}
	switch result {
	case .Completed:
		placement_record(.Negated_Membership, .Completed)
		return absent, true
	case .Declined:
		placement_record_decline(.Negated_Membership)
	case .Invalid:
		placement_record(.Negated_Membership, .Invalid_Result)
	}
	// The keys are already packed: the CPU reference finishes the step on
	// them, so a declining accelerator is never slower than the CPU strategy.
	absent, result = accel.membership_selection(accel.cpu_strategy(), left, entry.keys.columns, false, step.scratch)
	if result != .Completed {
		return nil, false
	}
	placement_record(.Negated_Membership, .Cpu_Fallback)
	return absent, true
}

// Negation for any arity or value kind: the relation's rows as a hash index;
// a live row survives when its probe tuple is absent. A computed relation that
// needs bound keys is probed row by row with every position bound.
@(private)
negated_absent_hashed :: proc(step: ^Rule_Step, atom: ^Atom, probes: [][]v.Value, n: int) -> ([]u32, Kernel_Error) {
	width := len(probes)
	rows, err := relation_source_scan_columns(step.source, atom.relation, make([]v.Binding, width, step.scratch), step.scratch)
	absent := make([dynamic]u32, 0, n, step.scratch)
	if err == .None {
		index := hash_index_build(rows.columns, row_iota(rows.count, step.scratch), step.scratch)
		present := hash_index_contains_rows(&index, probes, n, step.scratch)
		for i in 0 ..< n {
			if !present[i] {
				append(&absent, u32(i))
			}
		}
		return absent[:], .None
	}
	_, computed := kernel_computed_required_bindings(relation_source_kernel(step.source), atom.relation)
	if err == .Permission_Denied || !computed {
		return nil, err
	}
	step.source.error = .None
	bindings := make([]v.Binding, width, step.scratch)
	for i in 0 ..< n {
		for p in 0 ..< width {
			bindings[p] = v.binding_of(probes[p][i])
		}
		found, row_err := relation_source_scan_columns(step.source, atom.relation, bindings, step.scratch)
		if row_err != .None {
			return nil, row_err
		}
		if found.count == 0 {
			append(&absent, u32(i))
		}
	}
	return absent[:], .None
}

// --- Positive atoms -------------------------------------------------------

// How an atom position relates to the batch: a constant, a key (its variable
// is bound in the batch), the first occurrence of a new variable, or a repeat
// of a new variable at an earlier position.
@(private)
Atom_Role :: enum u8 {
	Constant,
	Key,
	New,
	Repeat,
}

@(private)
Atom_Plan :: struct {
	atom:    ^Atom,
	roles:   []Atom_Role,
	slot_of: []int,
	first:   []int,
	keys:    []int,
}

@(private)
atom_plan :: proc(step: ^Rule_Step, atom: ^Atom, batch: ^Column_Batch) -> Atom_Plan {
	arity := len(atom.terms)
	plan := Atom_Plan {
		atom    = atom,
		roles   = make([]Atom_Role, arity, step.scratch),
		slot_of = make([]int, arity, step.scratch),
		first   = make([]int, arity, step.scratch),
	}
	keys := make([dynamic]int, 0, arity, step.scratch)
	for term, p in atom.terms {
		if term.kind == .Value {
			plan.roles[p] = .Constant
			continue
		}
		slot := slot_map_slot(step.slots, term.symbol)
		plan.slot_of[p] = slot
		if batch.bound[slot] {
			plan.roles[p] = .Key
			append(&keys, p)
			continue
		}
		plan.roles[p] = .New
		for q in 0 ..< p {
			if plan.roles[q] == .New && plan.slot_of[q] == slot {
				plan.roles[p] = .Repeat
				plan.first[p] = q
				break
			}
		}
	}
	plan.keys = keys[:]
	return plan
}

// Relation row `r` agrees with the atom's constants and repeated variables.
@(private)
atom_row_ok :: #force_inline proc(plan: ^Atom_Plan, rows: ^Column_Batch, r: int) -> bool {
	for role, p in plan.roles {
		switch role {
		case .Constant:
			if !v.value_eq(rows.columns[p][r], plan.atom.terms[p].value) {
				return false
			}
		case .Repeat:
			if !v.value_eq(rows.columns[p][r], rows.columns[plan.first[p]][r]) {
				return false
			}
		case .Key, .New:
		}
	}
	return true
}

@(private)
apply_positive_columns :: proc(step: ^Rule_Step, atom: ^Atom, batch: ^Column_Batch) -> (Column_Batch, Kernel_Error) {
	plan := atom_plan(step, atom, batch)
	arity := len(atom.terms)
	n := column_batch_live(batch)
	// Constants bound, keys marked bound (for the access-path check), the
	// rest unbound.
	template := make([]v.Binding, arity, step.scratch)
	for role, p in plan.roles {
		#partial switch role {
		case .Constant:
			template[p] = v.binding_of(atom.terms[p].value)
		case .Key:
			template[p] = v.Binding{bound = true}
		}
	}
	_, computed := kernel_computed_required_bindings(relation_source_kernel(step.source), atom.relation)
	use_index := computed
	if !use_index && len(plan.keys) > 0 {
		use_index =
			n <= rules_small_batch_rows ||
			(n * 16 <= rules_source_cardinality(step.source, atom.relation) &&
					relation_source_index_prefix(step.source, atom.relation, template) > 0)
	}
	rows: Column_Batch
	left, right: []u32
	err: Kernel_Error
	if use_index {
		rows, left, right, err = positive_pairs_indexed(step, &plan, batch, template)
	} else {
		rows, left, right, err = positive_pairs_hashed(step, &plan, batch, template)
	}
	if err != .None {
		return {}, err
	}
	return positive_gather(step, &plan, batch, &rows, left, right), .None
}

// One scan per live row with its keys bound (constants too), appended into
// one sink; pairs record which batch row produced each relation row. Rows are
// re-checked with value_eq: computed scanners return candidates.
@(private)
positive_pairs_indexed :: proc(
	step: ^Rule_Step,
	plan: ^Atom_Plan,
	batch: ^Column_Batch,
	template: []v.Binding,
) -> (
	rows: Column_Batch,
	left, right: []u32,
	err: Kernel_Error,
) {
	arity := len(plan.roles)
	sink := column_sink_make(arity, step.scratch)
	bindings := make([]v.Binding, arity, step.scratch)
	l := make([dynamic]u32, 0, step.scratch)
	r := make([dynamic]u32, 0, step.scratch)
	for i in 0 ..< column_batch_live(batch) {
		row := column_batch_row(batch, i)
		for role, p in plan.roles {
			switch role {
			case .Constant:
				bindings[p] = template[p]
			case .Key:
				bindings[p] = v.binding_of(batch.columns[plan.slot_of[p]][row])
			case .New, .Repeat:
				bindings[p] = {}
			}
		}
		before := sink.count
		if scan_err := relation_source_scan_append(step.source, plan.atom.relation, bindings, &sink); scan_err != .None {
			return {}, nil, nil, scan_err
		}
		for k in before ..< sink.count {
			append(&l, u32(row))
			append(&r, u32(k))
		}
	}
	rows = column_sink_batch(&sink)
	write := 0
	for k in 0 ..< len(l) {
		rel_row := int(r[k])
		ok := atom_row_ok(plan, &rows, rel_row)
		for p in plan.keys {
			ok = ok && v.value_eq(rows.columns[p][rel_row], batch.columns[plan.slot_of[p]][l[k]])
		}
		if ok {
			l[write], r[write] = l[k], r[k]
			write += 1
		}
	}
	return rows, l[:write], r[:write], .None
}

// One scan with constants bound; candidate rows pass the constant and
// repeated-variable checks; then a hash join on the key positions (built on
// the smaller side), or a cross product when there are no keys.
@(private)
positive_pairs_hashed :: proc(
	step: ^Rule_Step,
	plan: ^Atom_Plan,
	batch: ^Column_Batch,
	template: []v.Binding,
) -> (
	rows: Column_Batch,
	left, right: []u32,
	err: Kernel_Error,
) {
	arity := len(plan.roles)
	scan := make([]v.Binding, arity, step.scratch)
	for role, p in plan.roles {
		if role == .Constant {
			scan[p] = template[p]
		}
	}
	rows, err = relation_source_scan_columns(step.source, plan.atom.relation, scan, step.scratch)
	if err != .None {
		return
	}
	candidates := make([dynamic]u32, 0, rows.count, step.scratch)
	for k in 0 ..< rows.count {
		if atom_row_ok(plan, &rows, k) {
			append(&candidates, u32(k))
		}
	}
	live := column_batch_live_rows(batch, step.scratch)
	if len(plan.keys) == 0 {
		m := len(live) * len(candidates)
		left = make([]u32, m, step.scratch)
		right = make([]u32, m, step.scratch)
		k := 0
		for l in live {
			for c in candidates {
				left[k], right[k] = l, c
				k += 1
			}
		}
		return
	}
	rel_keys := make([][]v.Value, len(plan.keys), step.scratch)
	batch_keys := make([][]v.Value, len(plan.keys), step.scratch)
	for p, j in plan.keys {
		rel_keys[j] = rows.columns[p]
		batch_keys[j] = batch.columns[plan.slot_of[p]]
	}
	if len(live) < len(candidates) {
		left, right = hash_join_pairs(batch_keys, live, rel_keys, candidates[:], step.scratch)
	} else {
		right, left = hash_join_pairs(rel_keys, candidates[:], batch_keys, live, step.scratch)
	}
	return
}

// The next batch: the batch's bound slots gathered by `left`, the atom's new
// variables gathered from the relation rows by `right`. When `right` is
// exactly 0..rows.count-1 (the first atom of a rule, unfiltered), relation
// columns are used without a copy.
@(private)
positive_gather :: proc(
	step: ^Rule_Step,
	plan: ^Atom_Plan,
	batch: ^Column_Batch,
	rows: ^Column_Batch,
	left, right: []u32,
) -> Column_Batch {
	m := len(left)
	out := column_batch_make(len(batch.bound), step.scratch)
	out.count = m
	for s in 0 ..< len(batch.bound) {
		if !batch.bound[s] {
			continue
		}
		column := make([]v.Value, m, step.scratch)
		from := batch.columns[s]
		for k in 0 ..< m {
			column[k] = from[left[k]]
		}
		out.columns[s], out.bound[s], out.fixed[s] = column, true, batch.fixed[s]
	}
	identity := m == rows.count
	for k := 0; identity && k < m; k += 1 {
		identity = int(right[k]) == k
	}
	for role, p in plan.roles {
		if role != .New {
			continue
		}
		s := plan.slot_of[p]
		if identity {
			out.columns[s] = rows.columns[p][:m]
		} else {
			column := make([]v.Value, m, step.scratch)
			from := rows.columns[p]
			for k in 0 ..< m {
				column[k] = from[right[k]]
			}
			out.columns[s] = column
		}
		out.bound[s], out.fixed[s] = true, rows.fixed[p]
	}
	return out
}
