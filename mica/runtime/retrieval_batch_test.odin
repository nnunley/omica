package mica_runtime

import "core:fmt"
import "core:mem/virtual"
import "core:sync"
import "core:testing"
import accel "../kernel/accel"
import k "../kernel"
import v "../var"

// The packed-index cache is process-wide: tests that fill it, evict from it
// or count its builds run one at a time.
@(private = "file")
nearest_cache_tests_lock: sync.Mutex

@(private = "file")
Retrieval_Rng :: struct {
	state: u64,
}

@(private = "file")
retrieval_next :: proc(r: ^Retrieval_Rng) -> u64 {
	r.state = r.state * 6364136223846793005 + 1442695040888963407
	return r.state >> 33
}

@(private = "file")
retrieval_relation :: proc(kernel: ^k.Kernel, id: u32, name: string, arity: u16) -> k.Relation_ID {
	metadata := k.relation_metadata(k.Relation_ID(id), v.symbol_intern(name), arity)
	snapshot, err := k.kernel_create_relation(kernel, metadata)
	assert(err == .None)
	k.snapshot_release(snapshot)
	return k.Relation_ID(id)
}

// A random vector of `dim` numbers; `mode` 1 makes it all zero, 2 puts a
// string in it (both are skipped by the row scanner's cosine).
@(private = "file")
retrieval_vector :: proc(r: ^Retrieval_Rng, dim: int, mode: int) -> v.Value {
	values := make([]v.Value, dim, context.temp_allocator)
	for i in 0 ..< dim {
		switch mode {
		case 1:
			values[i], _ = v.value_int(0)
		case:
			if retrieval_next(r) % 3 == 0 {
				values[i], _ = v.value_int(i64(retrieval_next(r) % 5) - 2)
			} else {
				values[i], _ = v.value_float(f32(retrieval_next(r) % 1000) / 250 - 2)
			}
		}
	}
	if mode == 2 {
		values[0] = v.value_string(context.temp_allocator, "x")
	}
	return v.value_list(context.temp_allocator, values)
}

@(private = "file")
collect_row :: proc(user: rawptr, row: v.Tuple) -> bool {
	append((^[dynamic]v.Tuple)(user), v.tuple_new(context.temp_allocator, v.tuple_values(row)))
	return true
}

// The batched scanner returns, for every key row, exactly the row scanner's
// rows in the same order: mixed dimensions, zero and non-numeric vectors,
// subjects with several embeddings, near ties, limits from 0 up.
@(test)
test_nearest_embedding_batch_matches_row_scanner :: proc(t: ^testing.T) {
	sync.mutex_lock(&nearest_cache_tests_lock)
	defer sync.mutex_unlock(&nearest_cache_tests_lock)
	defer free_all(context.temp_allocator)
	kernel: k.Kernel
	k.kernel_init(&kernel)
	defer k.kernel_destroy(&kernel)
	contains := retrieval_relation(&kernel, 1, "VectorIndexContains", 2)
	embedding_of := retrieval_relation(&kernel, 2, "EmbeddingOf", 2)
	vector := retrieval_relation(&kernel, 3, "EmbeddingVector", 2)
	rng := Retrieval_Rng{state = 0x1234_5678_9abc_def0}
	indexes := []v.Value{v.value_symbol(v.symbol_intern("docs")), v.value_symbol(v.symbol_intern("notes"))}

	tx := k.kernel_begin(&kernel)
	for e in 0 ..< 400 {
		embedding := v.value_symbol(v.symbol_intern(fmt.tprintf("e%d", e)))
		subject := v.value_symbol(v.symbol_intern(fmt.tprintf("s%d", e % 150)))
		index := indexes[e % 2]
		dim := e % 5 == 0 ? 3 : 2
		mode := e % 37 == 0 ? 1 : (e % 41 == 0 ? 2 : 0)
		vec := retrieval_vector(&rng, dim, mode)
		if e % 53 == 0 {
			// A near tie with the previous embedding's direction.
			vec = retrieval_vector(&rng, dim, 0)
		}
		k.transaction_assert(&tx, contains, v.tuple_new(context.temp_allocator, []v.Value{index, embedding}))
		k.transaction_assert(&tx, embedding_of, v.tuple_new(context.temp_allocator, []v.Value{embedding, subject}))
		k.transaction_assert(&tx, vector, v.tuple_new(context.temp_allocator, []v.Value{embedding, vec}))
	}
	_, commit_err := k.transaction_commit(&tx)
	testing.expect_value(t, commit_err, k.Kernel_Error.None)
	k.transaction_destroy(&tx)

	source := k.Relation_Source{kernel = &kernel, snapshot = kernel.current}
	count := 60
	keys := [][]v.Value{make([]v.Value, count, context.temp_allocator), make([]v.Value, count, context.temp_allocator), make([]v.Value, count, context.temp_allocator)}
	for i in 0 ..< count {
		keys[0][i] = indexes[retrieval_next(&rng) % 2]
		mode := i % 13 == 0 ? 1 : (i % 17 == 0 ? 2 : 0)
		keys[1][i] = retrieval_vector(&rng, i % 3 == 0 ? 3 : 2, mode)
		keys[2][i], _ = v.value_int(i64(retrieval_next(&rng) % 9))
	}
	sink := k.column_sink_make(6, context.temp_allocator)
	input_rows := make([dynamic]u32, context.temp_allocator)
	testing.expect_value(t, nearest_embedding_batch_scan(nil, &source, keys, count, &sink, &input_rows), k.Kernel_Error.None)
	batch := k.column_sink_batch(&sink)
	testing.expect_value(t, batch.count, len(input_rows))

	emitted := 0
	cursor := 0
	for i in 0 ..< count {
		want := make([dynamic]v.Tuple, context.temp_allocator)
		bindings := []v.Binding{v.binding_of(keys[0][i]), v.binding_of(keys[1][i]), v.binding_of(keys[2][i]), {}, {}, {}}
		testing.expect_value(t, nearest_embedding_scan(nil, &source, bindings, collect_row, &want), k.Kernel_Error.None)
		got := 0
		for cursor < len(input_rows) && int(input_rows[cursor]) == i {
			values := make([]v.Value, 6, context.temp_allocator)
			for c in 0 ..< 6 {
				values[c] = batch.columns[c][cursor]
			}
			testing.expectf(t, got < len(want) && v.tuple_eq(v.Tuple(values), want[got]), "key row %d result %d differs", i, got)
			got += 1
			cursor += 1
		}
		testing.expectf(t, got == len(want), "key row %d: %d rows, row scanner %d", i, got, len(want))
		emitted += got
	}
	testing.expect_value(t, cursor, len(input_rows))
	testing.expect(t, emitted > 50)
}

@(private = "file")
Retrieval_Fixture :: struct {
	kernel:                        k.Kernel,
	contains, embedding_of, vector: k.Relation_ID,
	other:                         k.Relation_ID,
	index:                         v.Value,
}

@(private = "file")
retrieval_fixture :: proc(t: ^testing.T, f: ^Retrieval_Fixture) {
	k.kernel_init(&f.kernel)
	f.contains = retrieval_relation(&f.kernel, 1, "VectorIndexContains", 2)
	f.embedding_of = retrieval_relation(&f.kernel, 2, "EmbeddingOf", 2)
	f.vector = retrieval_relation(&f.kernel, 3, "EmbeddingVector", 2)
	f.other = retrieval_relation(&f.kernel, 4, "Other", 1)
	f.index = v.value_symbol(v.symbol_intern("cache_docs"))
	rng := Retrieval_Rng{state = 99}
	tx := k.kernel_begin(&f.kernel)
	for e in 0 ..< 40 {
		embedding := v.value_symbol(v.symbol_intern(fmt.tprintf("ce%d", e)))
		k.transaction_assert(&tx, f.contains, v.tuple_new(context.temp_allocator, []v.Value{f.index, embedding}))
		k.transaction_assert(&tx, f.embedding_of, v.tuple_new(context.temp_allocator, []v.Value{embedding, v.value_symbol(v.symbol_intern(fmt.tprintf("cs%d", e)))}))
		k.transaction_assert(&tx, f.vector, v.tuple_new(context.temp_allocator, []v.Value{embedding, retrieval_vector(&rng, 2, 0)}))
	}
	_, err := k.transaction_commit(&tx)
	testing.expect_value(t, err, k.Kernel_Error.None)
	k.transaction_destroy(&tx)
}

// Batch and row scanner agree for one query on `source`; returns the batch rows.
@(private = "file")
expect_batch_equals_rows :: proc(t: ^testing.T, source: ^k.Relation_Source, index, query: v.Value, limit: int, loc := #caller_location) -> int {
	lim, _ := v.value_int(i64(limit))
	keys := [][]v.Value{{index}, {query}, {lim}}
	sink := k.column_sink_make(6, context.temp_allocator)
	input_rows := make([dynamic]u32, context.temp_allocator)
	testing.expect_value(t, nearest_embedding_batch_scan(nil, source, keys, 1, &sink, &input_rows), k.Kernel_Error.None, loc = loc)
	batch := k.column_sink_batch(&sink)
	want := make([dynamic]v.Tuple, context.temp_allocator)
	bindings := []v.Binding{v.binding_of(index), v.binding_of(query), v.binding_of(lim), {}, {}, {}}
	testing.expect_value(t, nearest_embedding_scan(nil, source, bindings, collect_row, &want), k.Kernel_Error.None, loc = loc)
	testing.expect_value(t, batch.count, len(want), loc = loc)
	for i in 0 ..< min(batch.count, len(want)) {
		values := make([]v.Value, 6, context.temp_allocator)
		for c in 0 ..< 6 {
			values[c] = batch.columns[c][i]
		}
		testing.expect(t, v.tuple_eq(v.Tuple(values), want[i]), loc = loc)
	}
	return batch.count
}

// The packed index is built once and reused across calls and across commits
// that leave its relations alone; a changed vector rebuilds it.
@(test)
test_nearest_cache_reuses_packed_index :: proc(t: ^testing.T) {
	sync.mutex_lock(&nearest_cache_tests_lock)
	defer sync.mutex_unlock(&nearest_cache_tests_lock)
	defer free_all(context.temp_allocator)
	f: Retrieval_Fixture
	retrieval_fixture(t, &f)
	defer k.kernel_destroy(&f.kernel)
	query := v.value_list(context.temp_allocator, []v.Value{must_float(1), must_float(0.5)})

	builds := nearest_cache_builds_this_thread()
	source := k.Relation_Source{kernel = &f.kernel, snapshot = f.kernel.current}
	expect_batch_equals_rows(t, &source, f.index, query, 5)
	expect_batch_equals_rows(t, &source, f.index, query, 5)
	testing.expect_value(t, nearest_cache_builds_this_thread() - builds, 1)

	tx := k.kernel_begin(&f.kernel)
	k.transaction_assert(&tx, f.other, v.tuple_new(context.temp_allocator, []v.Value{must_float(1)}))
	_, _ = k.transaction_commit(&tx)
	k.transaction_destroy(&tx)
	source = k.Relation_Source{kernel = &f.kernel, snapshot = f.kernel.current}
	expect_batch_equals_rows(t, &source, f.index, query, 5)
	testing.expect_value(t, nearest_cache_builds_this_thread() - builds, 1)

	// Make ce7 the exact query direction: it must now lead the results.
	tx = k.kernel_begin(&f.kernel)
	embedding := v.value_symbol(v.symbol_intern("ce7"))
	old := make([dynamic]v.Tuple, context.temp_allocator)
	k.relation_source_scan_into(&source, f.vector, []v.Binding{v.binding_of(embedding), {}}, &old)
	k.transaction_retract(&tx, f.vector, old[0])
	k.transaction_assert(&tx, f.vector, v.tuple_new(context.temp_allocator, []v.Value{embedding, v.value_list(context.temp_allocator, []v.Value{must_float(2), must_float(1)})}))
	_, _ = k.transaction_commit(&tx)
	k.transaction_destroy(&tx)
	source = k.Relation_Source{kernel = &f.kernel, snapshot = f.kernel.current}
	expect_batch_equals_rows(t, &source, f.index, query, 5)
	testing.expect_value(t, nearest_cache_builds_this_thread() - builds, 2)
}

// A transaction's uncommitted vector is visible to its own scans: the cache
// is bypassed.
@(test)
test_nearest_cache_bypassed_in_transactions :: proc(t: ^testing.T) {
	sync.mutex_lock(&nearest_cache_tests_lock)
	defer sync.mutex_unlock(&nearest_cache_tests_lock)
	defer free_all(context.temp_allocator)
	f: Retrieval_Fixture
	retrieval_fixture(t, &f)
	defer k.kernel_destroy(&f.kernel)
	query := v.value_list(context.temp_allocator, []v.Value{must_float(-1), must_float(3)})
	committed := k.Relation_Source{kernel = &f.kernel, snapshot = f.kernel.current}
	expect_batch_equals_rows(t, &committed, f.index, query, 3)

	tx := k.kernel_begin(&f.kernel)
	defer k.transaction_destroy(&tx)
	embedding := v.value_symbol(v.symbol_intern("fresh"))
	k.transaction_assert(&tx, f.contains, v.tuple_new(context.temp_allocator, []v.Value{f.index, embedding}))
	k.transaction_assert(&tx, f.embedding_of, v.tuple_new(context.temp_allocator, []v.Value{embedding, v.value_symbol(v.symbol_intern("fresh_subject"))}))
	k.transaction_assert(&tx, f.vector, v.tuple_new(context.temp_allocator, []v.Value{embedding, query}))
	source := k.Relation_Source{transaction = &tx}
	expect_batch_equals_rows(t, &source, f.index, query, 3)
}

@(private = "file")
must_float :: proc(x: f32) -> v.Value {
	value, _ := v.value_float(x)
	return value
}

// Cache entries outlive the evaluation arena that is context.allocator while
// the scanner runs: fill the cache under a temporary arena, destroy it, then
// force every entry out through evictions.
@(test)
test_nearest_cache_outlives_evaluation_arena :: proc(t: ^testing.T) {
	sync.mutex_lock(&nearest_cache_tests_lock)
	defer sync.mutex_unlock(&nearest_cache_tests_lock)
	defer free_all(context.temp_allocator)
	f: Retrieval_Fixture
	retrieval_fixture(t, &f)
	defer k.kernel_destroy(&f.kernel)
	query := v.value_list(context.temp_allocator, []v.Value{must_float(1), must_float(2)})
	source := k.Relation_Source{kernel = &f.kernel, snapshot = f.kernel.current}
	{
		evaluation: virtual.Arena
		testing.expect(t, virtual.arena_init_growing(&evaluation) == nil)
		context.allocator = virtual.arena_allocator(&evaluation)
		expect_batch_equals_rows(t, &source, f.index, query, 3)
		virtual.arena_destroy(&evaluation)
	}
	// Distinct index keys evict every entry, including the one built above.
	for i in 0 ..< 2 * NEAREST_CACHE_ENTRIES {
		other := v.value_symbol(v.symbol_intern(fmt.tprintf("evict%d", i)))
		expect_batch_equals_rows(t, &source, other, query, 3)
	}
	expect_batch_equals_rows(t, &source, f.index, query, 3)
}

// Scores come from the active strategy (GPU where available) and match the
// row scanner exactly after the f64 re-score; every scoring call is counted
// under .Cosine. 1,600 documents clear the GPU thresholds.
@(test)
test_nearest_embedding_batch_on_every_strategy :: proc(t: ^testing.T) {
	sync.mutex_lock(&nearest_cache_tests_lock)
	defer sync.mutex_unlock(&nearest_cache_tests_lock)
	sync.mutex_lock(&strategy_tests_lock)
	defer sync.mutex_unlock(&strategy_tests_lock)
	defer accel.use_cpu()
	defer free_all(context.temp_allocator)
	kernel: k.Kernel
	k.kernel_init(&kernel)
	defer k.kernel_destroy(&kernel)
	contains := retrieval_relation(&kernel, 1, "VectorIndexContains", 2)
	embedding_of := retrieval_relation(&kernel, 2, "EmbeddingOf", 2)
	vector := retrieval_relation(&kernel, 3, "EmbeddingVector", 2)
	index := v.value_symbol(v.symbol_intern("big"))
	rng := Retrieval_Rng{state = 7}
	tx := k.kernel_begin(&kernel)
	for e in 0 ..< 1600 {
		embedding := v.value_symbol(v.symbol_intern(fmt.tprintf("be%d", e)))
		k.transaction_assert(&tx, contains, v.tuple_new(context.temp_allocator, []v.Value{index, embedding}))
		k.transaction_assert(&tx, embedding_of, v.tuple_new(context.temp_allocator, []v.Value{embedding, v.value_symbol(v.symbol_intern(fmt.tprintf("bs%d", e % 700)))}))
		k.transaction_assert(&tx, vector, v.tuple_new(context.temp_allocator, []v.Value{embedding, retrieval_vector(&rng, 8, 0)}))
	}
	_, err := k.transaction_commit(&tx)
	testing.expect_value(t, err, k.Kernel_Error.None)
	k.transaction_destroy(&tx)

	strategies := make([dynamic]accel.Strategy, context.temp_allocator)
	append(&strategies, accel.cpu_strategy(), accel.cpu_parallel_strategy())
	when ODIN_OS == .Darwin {
		if s := accel.metal_strategy(); s.available() {
			append(&strategies, s)
		}
	}
	when ODIN_OS == .Linux {
		if accel.cuda_select_device(0) {
			append(&strategies, accel.cuda_strategy())
		}
	}
	queries := make([]v.Value, 24, context.temp_allocator)
	for i in 0 ..< len(queries) {
		queries[i] = retrieval_vector(&rng, 8, 0)
	}
	source := k.Relation_Source{kernel = &kernel, snapshot = kernel.current}
	for s in strategies {
		accel.select_strategy(s)
		before := k.placement_counts_this_thread()
		for q in queries {
			expect_batch_equals_rows(t, &source, index, q, 10)
		}
		delta := k.placement_counts_delta(before, k.placement_counts_this_thread())
		accel.use_cpu()
		testing.expectf(t, delta[.Cosine][.Completed] + delta[.Cosine][.Cpu_Fallback] >= u64(len(queries)), "%s: cosine outcomes %v", s.name, delta[.Cosine])
		if s.name == "metal" || s.name == "cuda" {
			testing.expectf(t, delta[.Cosine][.Completed] >= u64(len(queries)), "%s: GPU did not score: %v", s.name, delta[.Cosine])
		}
	}
}

// Heap-valued subjects in rows the batched scanner returns stay valid after
// the call, even when later indexes in the same call evict the entry they
// came from.
@(test)
test_nearest_batch_heap_subjects_survive_eviction :: proc(t: ^testing.T) {
	sync.mutex_lock(&nearest_cache_tests_lock)
	defer sync.mutex_unlock(&nearest_cache_tests_lock)
	defer free_all(context.temp_allocator)
	kernel: k.Kernel
	k.kernel_init(&kernel)
	defer k.kernel_destroy(&kernel)
	contains := retrieval_relation(&kernel, 1, "VectorIndexContains", 2)
	embedding_of := retrieval_relation(&kernel, 2, "EmbeddingOf", 2)
	vector := retrieval_relation(&kernel, 3, "EmbeddingVector", 2)
	N :: NEAREST_CACHE_ENTRIES + 2
	indexes: [N]v.Value
	tx := k.kernel_begin(&kernel)
	for i in 0 ..< N {
		indexes[i] = v.value_symbol(v.symbol_intern(fmt.tprintf("evict_heap_%d", i)))
		embedding := v.value_symbol(v.symbol_intern(fmt.tprintf("evict_heap_e%d", i)))
		k.transaction_assert(&tx, contains, v.tuple_new(context.temp_allocator, []v.Value{indexes[i], embedding}))
		k.transaction_assert(&tx, embedding_of, v.tuple_new(context.temp_allocator, []v.Value{embedding, v.value_string(context.temp_allocator, fmt.tprintf("subject number %d", i))}))
		k.transaction_assert(&tx, vector, v.tuple_new(context.temp_allocator, []v.Value{embedding, v.value_list(context.temp_allocator, []v.Value{must_float(1), must_float(f32(i))})}))
	}
	_, err := k.transaction_commit(&tx)
	testing.expect_value(t, err, k.Kernel_Error.None)
	k.transaction_destroy(&tx)

	source := k.Relation_Source{kernel = &kernel, snapshot = kernel.current}
	query := v.value_list(context.temp_allocator, []v.Value{must_float(1), must_float(1)})
	lim, _ := v.value_int(3)
	keys := [][]v.Value{make([]v.Value, N, context.temp_allocator), make([]v.Value, N, context.temp_allocator), make([]v.Value, N, context.temp_allocator)}
	for i in 0 ..< N {
		keys[0][i], keys[1][i], keys[2][i] = indexes[i], query, lim
	}
	sink := k.column_sink_make(6, context.temp_allocator)
	input_rows := make([dynamic]u32, context.temp_allocator)
	testing.expect_value(t, nearest_embedding_batch_scan(nil, &source, keys, N, &sink, &input_rows), k.Kernel_Error.None)
	batch := k.column_sink_batch(&sink)
	testing.expect_value(t, batch.count, N)
	for row in 0 ..< batch.count {
		i := int(input_rows[row])
		text, ok := v.value_as_string(batch.columns[3][row])
		testing.expectf(t, ok && text == fmt.tprintf("subject number %d", i), "row %d: subject %q", row, text)
	}
}

// More than limit + 32 subjects tie in f32: the f64 winner must still be
// found (the row scanner's answer), whatever the strategy's f32 noise.
@(test)
test_nearest_batch_f32_ties :: proc(t: ^testing.T) {
	sync.mutex_lock(&nearest_cache_tests_lock)
	defer sync.mutex_unlock(&nearest_cache_tests_lock)
	defer free_all(context.temp_allocator)
	kernel: k.Kernel
	k.kernel_init(&kernel)
	defer k.kernel_destroy(&kernel)
	contains := retrieval_relation(&kernel, 1, "VectorIndexContains", 2)
	embedding_of := retrieval_relation(&kernel, 2, "EmbeddingOf", 2)
	vector := retrieval_relation(&kernel, 3, "EmbeddingVector", 2)
	index := v.value_symbol(v.symbol_intern("f32_ties"))
	N :: 100
	tx := k.kernel_begin(&kernel)
	for e in 0 ..< N {
		embedding, _ := v.value_int(i64(1000 + e))
		subject, _ := v.value_int(i64(e))
		a, _ := v.value_int(1_000_000)
		b, _ := v.value_int(i64(1_000_000 + N - e))
		k.transaction_assert(&tx, contains, v.tuple_new(context.temp_allocator, []v.Value{index, embedding}))
		k.transaction_assert(&tx, embedding_of, v.tuple_new(context.temp_allocator, []v.Value{embedding, subject}))
		k.transaction_assert(&tx, vector, v.tuple_new(context.temp_allocator, []v.Value{embedding, v.value_list(context.temp_allocator, []v.Value{a, b})}))
	}
	_, err := k.transaction_commit(&tx)
	testing.expect_value(t, err, k.Kernel_Error.None)
	k.transaction_destroy(&tx)
	source := k.Relation_Source{kernel = &kernel, snapshot = kernel.current}
	one, _ := v.value_int(1)
	query := v.value_list(context.temp_allocator, []v.Value{one, one})
	for limit in ([]int{1, 5}) {
		expect_batch_equals_rows(t, &source, index, query, limit)
	}
}

// The document matrix of a cached index is packed and prepared (made resident
// on the strategy) once, then reused by later calls with the same strategy.
@(test)
test_nearest_cache_prepares_docs_once :: proc(t: ^testing.T) {
	sync.mutex_lock(&strategy_tests_lock)
	defer sync.mutex_unlock(&strategy_tests_lock)
	sync.mutex_lock(&nearest_cache_tests_lock)
	defer sync.mutex_unlock(&nearest_cache_tests_lock)
	defer accel.use_cpu()
	defer free_all(context.temp_allocator)
	f: Retrieval_Fixture
	retrieval_fixture(t, &f)
	defer k.kernel_destroy(&f.kernel)
	// The CPU reference never prepares documents (no residency threshold): a
	// variant that declares one stands in for a GPU strategy.
	resident := accel.cpu_strategy()
	resident.name = "cpu_resident_test"
	resident.resident_min_probes = 1
	accel.select_strategy(resident)
	query := v.value_list(context.temp_allocator, []v.Value{must_float(0.5), must_float(-1)})
	source := k.Relation_Source{kernel = &f.kernel, snapshot = f.kernel.current}
	before := nearest_docs_prepares_this_thread()
	expect_batch_equals_rows(t, &source, f.index, query, 4)
	testing.expect_value(t, nearest_docs_prepares_this_thread() - before, 1)
	expect_batch_equals_rows(t, &source, f.index, query, 4)
	expect_batch_equals_rows(t, &source, f.index, query, 7)
	testing.expect_value(t, nearest_docs_prepares_this_thread() - before, 1)
}

// CPU strategies (no residency threshold) never make a resident document
// copy: it would duplicate the matrix the cache entry already holds.
@(test)
test_nearest_cache_cpu_does_not_duplicate_docs :: proc(t: ^testing.T) {
	sync.mutex_lock(&strategy_tests_lock)
	defer sync.mutex_unlock(&strategy_tests_lock)
	sync.mutex_lock(&nearest_cache_tests_lock)
	defer sync.mutex_unlock(&nearest_cache_tests_lock)
	defer accel.use_cpu()
	defer free_all(context.temp_allocator)
	f: Retrieval_Fixture
	retrieval_fixture(t, &f)
	defer k.kernel_destroy(&f.kernel)
	query := v.value_list(context.temp_allocator, []v.Value{must_float(0.5), must_float(-1)})
	source := k.Relation_Source{kernel = &f.kernel, snapshot = f.kernel.current}
	before := nearest_docs_prepares_this_thread()
	accel.use_cpu()
	expect_batch_equals_rows(t, &source, f.index, query, 4)
	accel.select_strategy(accel.cpu_parallel_strategy())
	expect_batch_equals_rows(t, &source, f.index, query, 4)
	testing.expect_value(t, nearest_docs_prepares_this_thread() - before, 0)
}

// A resident copy in use by one scoring call is not released or replaced when
// another strategy scores the same matrix meanwhile; that call scores from
// the host matrix instead.
@(test)
test_nearest_matrix_resident_copy_not_released_while_in_use :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	members := []Nearest_Member{{vector = []f32{1, 0}}, {vector = []f32{0, 1}}}
	dm := nearest_build_matrix(members, 2, context.temp_allocator)
	a := accel.cpu_strategy()
	a.name = "resident_a"
	a.resident_min_probes = 1
	b := a
	b.name = "resident_b"
	prepared_a, ok_a := nearest_matrix_acquire(&dm, a, true)
	testing.expect(t, ok_a)
	_, ok_b := nearest_matrix_acquire(&dm, b, true)
	testing.expect(t, !ok_b) // a's copy is in use: b scores from the host matrix
	testing.expect(t, dm.prepared.handle == prepared_a.handle && dm.prepared.strategy == "resident_a")
	nearest_matrix_release_use(&dm)
	prepared_b, ok_b2 := nearest_matrix_acquire(&dm, b, true)
	testing.expect(t, ok_b2 && prepared_b.strategy == "resident_b")
	nearest_matrix_release_use(&dm)
	accel.release_prepared(dm.strategy, &dm.prepared)
}

// Members derived by a rule change without any backing relation's block
// changing: a derived VectorIndexContains row added through Staged must be
// visible to the next batched scan, not hidden by a cached member list.
@(test)
test_nearest_cache_sees_derived_members :: proc(t: ^testing.T) {
	sync.mutex_lock(&nearest_cache_tests_lock)
	defer sync.mutex_unlock(&nearest_cache_tests_lock)
	defer free_all(context.temp_allocator)
	f: Retrieval_Fixture
	retrieval_fixture(t, &f)
	defer k.kernel_destroy(&f.kernel)
	staged := retrieval_relation(&f.kernel, 5, "Staged", 2)
	i, e := v.symbol_intern("i"), v.symbol_intern("e")
	rule := k.rule_new(f.contains, []k.Term{k.term_var(i), k.term_var(e)}, []k.Rule_Body_Item{k.body_atom(k.atom_positive(staged, []k.Term{k.term_var(i), k.term_var(e)}))})
	installed, install_error := k.kernel_install_rule(&f.kernel, v.Identity(970), rule, "derived members")
	testing.expect_value(t, install_error, k.Kernel_Error.None)
	k.snapshot_release(installed)

	// The member's embedding and vector exist up front (pointing exactly along
	// the query), so the later commit changes only Staged: no backing block.
	query := v.value_list(context.temp_allocator, []v.Value{must_float(1), must_float(0.5)})
	embedding := v.value_symbol(v.symbol_intern("derived_member"))
	tx := k.kernel_begin(&f.kernel)
	k.transaction_assert(&tx, f.embedding_of, v.tuple_new(context.temp_allocator, []v.Value{embedding, v.value_symbol(v.symbol_intern("derived_subject"))}))
	k.transaction_assert(&tx, f.vector, v.tuple_new(context.temp_allocator, []v.Value{embedding, query}))
	_, _ = k.transaction_commit(&tx)
	k.transaction_destroy(&tx)
	source := k.Relation_Source{kernel = &f.kernel, snapshot = f.kernel.current, use_stored_derived = true}
	expect_batch_equals_rows(t, &source, f.index, query, 3)

	// Staged makes it a member through the rule.
	tx = k.kernel_begin(&f.kernel)
	k.transaction_assert(&tx, staged, v.tuple_new(context.temp_allocator, []v.Value{f.index, embedding}))
	_, _ = k.transaction_commit(&tx)
	k.transaction_destroy(&tx)
	source = k.Relation_Source{kernel = &f.kernel, snapshot = f.kernel.current, use_stored_derived = true}
	expect_batch_equals_rows(t, &source, f.index, query, 3)
}
