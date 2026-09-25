package kernel

import "core:testing"
import v "../var"

@(private = "file")
Even_Counts :: struct {
	row_calls:   int,
	batch_calls: int,
	batch_rows:  int,
	// Emit a wrong candidate (the key plus one) alongside each real row.
	noisy:       bool,
	hidden:      Relation_ID,
}

@(private = "file")
even_row_scan :: proc(user: rawptr, source: ^Relation_Source, bindings: []v.Binding, visit: Computed_Visit_Proc, visit_user: rawptr) -> Kernel_Error {
	counts := (^Even_Counts)(user)
	counts.row_calls += 1
	n, ok := v.value_as_int(bindings[0].value)
	if ok && n % 2 == 0 {
		visit(visit_user, v.tuple_new(context.temp_allocator, []v.Value{bindings[0].value}))
	}
	return .None
}

@(private = "file")
even_batch_scan :: proc(user: rawptr, source: ^Relation_Source, keys: [][]v.Value, count: int, out: ^Column_Sink, input_rows: ^[dynamic]u32) -> Kernel_Error {
	counts := (^Even_Counts)(user)
	counts.batch_calls += 1
	counts.batch_rows += count
	if counts.hidden != 0 {
		// Reads a backing relation through the same source (authority applies).
		rows := make([dynamic]v.Tuple, context.temp_allocator)
		relation_source_scan_into(source, counts.hidden, []v.Binding{{}}, &rows)
	}
	for i in 0 ..< count {
		n, ok := v.value_as_int(keys[0][i])
		if ok && n % 2 == 0 {
			column_sink_append_tuple(out, v.tuple_new(context.temp_allocator, []v.Value{keys[0][i]}))
			append(input_rows, u32(i))
		}
		if counts.noisy {
			wrong, _ := v.value_int(n + 1)
			column_sink_append_tuple(out, v.tuple_new(context.temp_allocator, []v.Value{wrong}))
			append(input_rows, u32(i))
		}
	}
	return .None
}

@(private = "file")
Batch_Fixture :: struct {
	kernel: Kernel,
	item:   Relation_ID,
	even:   Relation_ID,
	out:    Relation_ID,
	counts: ^Even_Counts,
}

// Item(x) for x in 1..=100, computed Even(x) (required binding 0),
// Out(x) :- Item(x), Even(x). With `batch`, Even also has a batch scanner.
@(private = "file")
batch_fixture :: proc(t: ^testing.T, f: ^Batch_Fixture, batch: bool) {
	kernel_init(&f.kernel)
	f.item = create_relation(&f.kernel, 1, "Item", 1)
	f.even = create_relation(&f.kernel, 2, "Even", 1)
	f.out = create_relation(&f.kernel, 3, "Out", 1)
	f.counts = new(Even_Counts, context.temp_allocator)
	testing.expect_value(t, kernel_register_computed_relation(&f.kernel, f.even, []u16{0}, even_row_scan, f.counts), Kernel_Error.None)
	if batch {
		testing.expect_value(t, kernel_register_computed_batch_scan(&f.kernel, f.even, even_batch_scan), Kernel_Error.None)
	}
	x := v.symbol_intern("x")
	snapshot, err := kernel_install_rule(&f.kernel, v.Identity(950), rule_new(f.out, []Term{term_var(x)}, []Rule_Body_Item {
		body_atom(atom_positive(f.item, []Term{term_var(x)})),
		body_atom(atom_positive(f.even, []Term{term_var(x)})),
	}), "batch")
	testing.expect_value(t, err, Kernel_Error.None)
	snapshot_release(snapshot)
	tx := kernel_begin(&f.kernel)
	for i in 1 ..= 100 {
		transaction_assert(&tx, f.item, tuple_of(must_int(i64(i))))
	}
	commit_transaction(t, &tx)
}

@(test)
test_computed_batch_scan_called_once_per_step :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	f: Batch_Fixture
	batch_fixture(t, &f, true)
	defer kernel_destroy(&f.kernel)
	rows := snapshot_derived_rows(f.kernel.current, f.out)
	testing.expect_value(t, len(rows), 50)
	testing.expect_value(t, f.counts.batch_calls, 1)
	testing.expect_value(t, f.counts.batch_rows, 100)
	testing.expect_value(t, f.counts.row_calls, 0)

	row_only: Batch_Fixture
	batch_fixture(t, &row_only, false)
	defer kernel_destroy(&row_only.kernel)
	want := snapshot_derived_rows(row_only.kernel.current, row_only.out)
	testing.expect_value(t, len(want), len(rows))
	for row in rows {
		testing.expect(t, has_tuple(want, row))
	}
	testing.expect_value(t, row_only.counts.row_calls, 100)
}

// Candidates that do not match their key row are dropped, as for row scanners.
@(test)
test_computed_batch_scan_candidates_rechecked :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	f: Batch_Fixture
	kernel_init(&f.kernel)
	defer kernel_destroy(&f.kernel)
	f.item = create_relation(&f.kernel, 1, "Item", 1)
	f.even = create_relation(&f.kernel, 2, "Even", 1)
	f.out = create_relation(&f.kernel, 3, "Out", 1)
	f.counts = new(Even_Counts, context.temp_allocator)
	f.counts.noisy = true
	kernel_register_computed_relation(&f.kernel, f.even, []u16{0}, even_row_scan, f.counts)
	kernel_register_computed_batch_scan(&f.kernel, f.even, even_batch_scan)
	x := v.symbol_intern("x")
	snapshot, _ := kernel_install_rule(&f.kernel, v.Identity(951), rule_new(f.out, []Term{term_var(x)}, []Rule_Body_Item {
		body_atom(atom_positive(f.item, []Term{term_var(x)})),
		body_atom(atom_positive(f.even, []Term{term_var(x)})),
	}), "noisy")
	snapshot_release(snapshot)
	tx := kernel_begin(&f.kernel)
	for i in 1 ..= 10 {
		transaction_assert(&tx, f.item, tuple_of(must_int(i64(i))))
	}
	commit_transaction(t, &tx)
	testing.expect_value(t, len(snapshot_derived_rows(f.kernel.current, f.out)), 5)
}

// Two key rows with the same key each get the scanner's rows.
@(test)
test_computed_batch_scan_duplicate_key_rows :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	kernel: Kernel
	kernel_init(&kernel)
	defer kernel_destroy(&kernel)
	pair := create_relation(&kernel, 1, "Pair", 2)
	even := create_relation(&kernel, 2, "Even", 1)
	out := create_relation(&kernel, 3, "Out", 2)
	counts := new(Even_Counts, context.temp_allocator)
	kernel_register_computed_relation(&kernel, even, []u16{0}, even_row_scan, counts)
	kernel_register_computed_batch_scan(&kernel, even, even_batch_scan)
	x, y := v.symbol_intern("x"), v.symbol_intern("y")
	snapshot, _ := kernel_install_rule(&kernel, v.Identity(952), rule_new(out, []Term{term_var(x), term_var(y)}, []Rule_Body_Item {
		body_atom(atom_positive(pair, []Term{term_var(x), term_var(y)})),
		body_atom(atom_positive(even, []Term{term_var(y)})),
	}), "dups")
	snapshot_release(snapshot)
	tx := kernel_begin(&kernel)
	transaction_assert(&tx, pair, tuple_of(must_int(1), must_int(2)))
	transaction_assert(&tx, pair, tuple_of(must_int(3), must_int(2)))
	transaction_assert(&tx, pair, tuple_of(must_int(5), must_int(7)))
	commit_transaction(t, &tx)
	rows := snapshot_derived_rows(kernel.current, out)
	testing.expect_value(t, len(rows), 2)
	testing.expect(t, has_tuple(rows, tuple_of(must_int(1), must_int(2))))
	testing.expect(t, has_tuple(rows, tuple_of(must_int(3), must_int(2))))
	testing.expect_value(t, counts.batch_calls, 1)
}

// A batch scanner reading a backing relation the authority cannot read fails
// the step with Permission_Denied (reported only through source.error).
@(test)
test_computed_batch_scan_nested_denial :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	f: Batch_Fixture
	batch_fixture(t, &f, true)
	defer kernel_destroy(&f.kernel)
	hidden := create_relation(&f.kernel, 9, "Hidden", 1)
	f.counts.hidden = hidden
	authority := Authority{allocator = context.allocator}
	authority.read = make(map[Relation_ID]bool, context.temp_allocator)
	authority.read[f.item] = true
	authority.read[f.even] = true
	source := Relation_Source{kernel = &f.kernel, snapshot = f.kernel.current, authority = &authority}
	result := rules_derived_create(context.temp_allocator)
	source.derived = &result
	err := rules_evaluate_source(context.temp_allocator, f.kernel.current.rules, &source, &result)
	testing.expect_value(t, err, Kernel_Error.Permission_Denied)
}
