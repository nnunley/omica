// Concurrent transaction tests.
//
// These exercise real threads: disjoint commits that must not lose writes,
// contended functional writes that must conflict and retry, snapshot
// isolation, and reader/writer stress that stresses snapshot lifetime.
package kernel

import "base:runtime"
import "core:fmt"
import "core:sync"
import "core:testing"
import "core:thread"
import v "../var"

@(private)
Disjoint_Worker :: struct {
	kernel:    ^Kernel,
	relation:  Relation_ID,
	thread_id: u64,
	count:     int,
	committed: int,
	conflicts: int,
	failed:    Kernel_Error,
}

@(private)
disjoint_worker :: proc(data: rawptr) {
	context = runtime.default_context()
	worker := (^Disjoint_Worker)(data)
	for index in 0 ..< worker.count {
		for {
			tx := kernel_begin(worker.kernel)
			tuple := tuple_of(must_identity(worker.thread_id * 1_000_000 + u64(index)))
			if err := transaction_assert(&tx, worker.relation, tuple); err != .None {
				worker.failed = err
				transaction_destroy(&tx)
				return
			}
			committed, err := transaction_commit(&tx)
			if err == .None {
				snapshot_release(committed)
				transaction_destroy(&tx)
				worker.committed += 1
				break
			}
			transaction_destroy(&tx)
			if err != .Conflict {
				worker.failed = err
				return
			}
			worker.conflicts += 1
		}
	}
}

@(test)
test_concurrent_disjoint_commits :: proc(t: ^testing.T) {
	kernel: Kernel
	kernel_init(&kernel)
	defer kernel_destroy(&kernel)

	relation := create_relation(&kernel, 1, "Concurrent", 1)

	THREADS :: 8
	PER_THREAD :: 32
	workers: [THREADS]Disjoint_Worker
	threads: [THREADS]^thread.Thread
	for index in 0 ..< THREADS {
		workers[index] = Disjoint_Worker {
			kernel    = &kernel,
			relation  = relation,
			thread_id = u64(index),
			count     = PER_THREAD,
		}
		threads[index] = thread.create_and_start_with_data(&workers[index], disjoint_worker)
	}
	for index in 0 ..< THREADS {
		thread.join(threads[index])
		thread.destroy(threads[index])
	}

	total_committed := 0
	for worker in workers {
		testing.expect_value(t, worker.failed, Kernel_Error.None)
		total_committed += worker.committed
	}
	testing.expect_value(t, total_committed, THREADS * PER_THREAD)
	testing.expect_value(t, kernel.current.version, u64(1 + THREADS * PER_THREAD))

	rows := kernel_rows(&kernel, relation, 1)
	defer delete(rows)
	testing.expect_value(t, len(rows), THREADS * PER_THREAD)
}

@(private)
Contended_Worker :: struct {
	kernel:       ^Kernel,
	relation:     Relation_ID,
	thread_id:    u64,
	ready:        ^i32,
	participants: i32,
	committed:    int,
	conflicts:    int,
	failed:       Kernel_Error,
}

@(private)
contended_worker :: proc(data: rawptr) {
	context = runtime.default_context()
	worker := (^Contended_Worker)(data)

	key_positions := []u16{0}
	key_values := make([]v.Value, 1, context.temp_allocator)
	key_values[0] = must_identity(1)
	tuple := tuple_of(must_identity(1), must_identity(worker.thread_id + 1))

	stage_set :: proc(
		worker: ^Contended_Worker,
		tx: ^Transaction,
		key_positions: []u16,
		key_values: []v.Value,
		tuple: v.Tuple,
	) -> Kernel_Error {
		if existing, found := transaction_tuple_for_key(
			tx,
			worker.relation,
			key_positions,
			key_values,
		); found {
			if err := transaction_retract(tx, worker.relation, existing); err != .None {
				return err
			}
		}
		return transaction_assert(tx, worker.relation, tuple)
	}

	tx := kernel_begin(worker.kernel)
	if err := stage_set(worker, &tx, key_positions, key_values, tuple); err != .None {
		worker.failed = err
		transaction_destroy(&tx)
		return
	}

	// Every worker stages before any commits, so every worker but one must
	// observe a functional-key conflict on its first commit.
	sync.atomic_add(worker.ready, 1)
	for sync.atomic_load(worker.ready) < worker.participants {
		sync.cpu_relax()
	}

	for {
		committed, err := transaction_commit(&tx)
		if err == .None {
			snapshot_release(committed)
			worker.committed += 1
			break
		}
		if err != .Conflict {
			worker.failed = err
			break
		}
		worker.conflicts += 1
		transaction_destroy(&tx)
		tx = kernel_begin(worker.kernel)
		if err = stage_set(worker, &tx, key_positions, key_values, tuple); err != .None {
			worker.failed = err
			break
		}
	}
	transaction_destroy(&tx)
}

@(test)
test_concurrent_functional_conflicts :: proc(t: ^testing.T) {
	kernel: Kernel
	kernel_init(&kernel)
	defer kernel_destroy(&kernel)

	key_positions := []u16{0}
	relation := create_relation_with(
		&kernel,
		2,
		"Choice",
		2,
		conflict_functional(key_positions),
		nil,
	)

	THREADS :: 8
	ready: i32 = 0
	workers: [THREADS]Contended_Worker
	threads: [THREADS]^thread.Thread
	for index in 0 ..< THREADS {
		workers[index] = Contended_Worker {
			kernel       = &kernel,
			relation     = relation,
			thread_id    = u64(index),
			ready        = &ready,
			participants = THREADS,
		}
		threads[index] = thread.create_and_start_with_data(&workers[index], contended_worker)
	}
	for index in 0 ..< THREADS {
		thread.join(threads[index])
		thread.destroy(threads[index])
	}

	total_conflicts := 0
	for worker in workers {
		testing.expect_value(t, worker.failed, Kernel_Error.None)
		testing.expect_value(t, worker.committed, 1)
		total_conflicts += worker.conflicts
	}
	testing.expect(t, total_conflicts >= THREADS - 1)

	rows := kernel_rows(&kernel, relation, 2)
	defer delete(rows)
	testing.expect_value(t, len(rows), 1)

	values := v.tuple_values(rows[0])
	key, key_ok := v.value_as_identity(values[0])
	testing.expect(t, key_ok)
	testing.expect_value(t, v.identity_raw(key), u64(1))
}

@(private)
Isolation_Writer :: struct {
	kernel:    ^Kernel,
	relation:  Relation_ID,
	count:     int,
	committed: int,
	failed:    Kernel_Error,
}

@(private)
isolation_writer :: proc(data: rawptr) {
	context = runtime.default_context()
	worker := (^Isolation_Writer)(data)
	for index in 0 ..< worker.count {
		for {
			tx := kernel_begin(worker.kernel)
			tuple := tuple_of(must_identity(u64(index) + 1))
			if err := transaction_assert(&tx, worker.relation, tuple); err != .None {
				worker.failed = err
				transaction_destroy(&tx)
				return
			}
			committed, err := transaction_commit(&tx)
			if err == .None {
				snapshot_release(committed)
				transaction_destroy(&tx)
				worker.committed += 1
				break
			}
			transaction_destroy(&tx)
			if err != .Conflict {
				worker.failed = err
				return
			}
		}
	}
}

@(test)
test_snapshot_isolation_during_commits :: proc(t: ^testing.T) {
	kernel: Kernel
	kernel_init(&kernel)
	defer kernel_destroy(&kernel)

	relation := create_relation(&kernel, 1, "Isolated", 1)

	base := kernel_snapshot(&kernel)
	defer snapshot_release(base)

	constant := 64
	worker := Isolation_Writer {
		kernel   = &kernel,
		relation = relation,
		count    = constant,
	}
	writer := thread.create_and_start_with_data(&worker, isolation_writer)
	thread.join(writer)
	thread.destroy(writer)
	testing.expect_value(t, worker.failed, Kernel_Error.None)
	testing.expect_value(t, worker.committed, constant)

	testing.expect_value(t, base.version, u64(1))

	base_rows: [dynamic]v.Tuple
	defer delete(base_rows)
	relation_source_scan_into(
		&Relation_Source{snapshot = base, use_stored_derived = true},
		relation,
		[]v.Binding{{}},
		&base_rows,
	)
	testing.expect_value(t, len(base_rows), 0)

	rows := kernel_rows(&kernel, relation, 1)
	defer delete(rows)
	testing.expect_value(t, len(rows), constant)
	testing.expect_value(t, kernel.current.version, u64(1 + constant))
}

@(private)
Stress_Writer :: struct {
	kernel:    ^Kernel,
	relation:  Relation_ID,
	count:     int,
	committed: int,
	failed:    Kernel_Error,
}

@(private)
stress_writer :: proc(data: rawptr) {
	context = runtime.default_context()
	worker := (^Stress_Writer)(data)
	for index in 0 ..< worker.count {
		for {
			tx := kernel_begin(worker.kernel)
			tuple := tuple_of(must_identity(u64(index) + 1))
			if err := transaction_assert(&tx, worker.relation, tuple); err != .None {
				worker.failed = err
				transaction_destroy(&tx)
				return
			}
			committed, err := transaction_commit(&tx)
			if err == .None {
				snapshot_release(committed)
				transaction_destroy(&tx)
				worker.committed += 1
				break
			}
			transaction_destroy(&tx)
			if err != .Conflict {
				worker.failed = err
				return
			}
		}
	}
}

@(private)
Stress_Reader :: struct {
	kernel:    ^Kernel,
	relation:  Relation_ID,
	count:     int,
	reads:     int,
	failed:    Kernel_Error,
}

@(private)
stress_reader :: proc(data: rawptr) {
	context = runtime.default_context()
	worker := (^Stress_Reader)(data)
	for _ in 0 ..< worker.count {
		current := kernel_snapshot(worker.kernel)
		rows: [dynamic]v.Tuple
		relation_source_scan_into(
			&Relation_Source{snapshot = current, use_stored_derived = true},
			worker.relation,
			[]v.Binding{{}},
			&rows,
		)
		delete(rows)
		snapshot_release(current)
		worker.reads += 1
	}
}

@(test)
test_concurrent_readers_and_writers :: proc(t: ^testing.T) {
	kernel: Kernel
	kernel_init(&kernel)
	defer kernel_destroy(&kernel)

	relation := create_relation(&kernel, 1, "Stress", 1)

	WRITER_COUNT :: 512
	READER_COUNT :: 512
	READERS :: 4

	writer_worker := Stress_Writer {
		kernel   = &kernel,
		relation = relation,
		count    = WRITER_COUNT,
	}
	reader_workers: [READERS]Stress_Reader
	threads: [1 + READERS]^thread.Thread
	threads[0] = thread.create_and_start_with_data(&writer_worker, stress_writer)
	for index in 0 ..< READERS {
		reader_workers[index] = Stress_Reader {
			kernel   = &kernel,
			relation = relation,
			count    = READER_COUNT,
		}
		threads[index + 1] = thread.create_and_start_with_data(&reader_workers[index], stress_reader)
	}
	for index in 0 ..< len(threads) {
		thread.join(threads[index])
		thread.destroy(threads[index])
	}

	testing.expect_value(t, writer_worker.failed, Kernel_Error.None)
	testing.expect_value(t, writer_worker.committed, WRITER_COUNT)
	for reader in reader_workers {
		testing.expect_value(t, reader.failed, Kernel_Error.None)
		testing.expect_value(t, reader.reads, READER_COUNT)
	}

	rows := kernel_rows(&kernel, relation, 1)
	defer delete(rows)
	testing.expect_value(t, len(rows), WRITER_COUNT)
}

@(private)
Create_Worker :: struct {
	kernel:  ^Kernel,
	id:      u32,
	ordinal: int,
	failed:  Kernel_Error,
}

@(private)
create_worker :: proc(data: rawptr) {
	context = runtime.default_context()
	worker := (^Create_Worker)(data)
	name := fmt.aprintf(
		"ConcurrentRelation%d",
		worker.ordinal,
		allocator = context.temp_allocator,
	)
	metadata := relation_metadata(
		Relation_ID(worker.id),
		v.symbol_intern(name),
		1,
	)
	created, err := kernel_create_relation(worker.kernel, metadata)
	if err != .None {
		worker.failed = err
		return
	}
	snapshot_release(created)
}

@(test)
test_concurrent_relation_creation :: proc(t: ^testing.T) {
	kernel: Kernel
	kernel_init(&kernel)
	defer kernel_destroy(&kernel)

	THREADS :: 8
	workers: [THREADS]Create_Worker
	threads: [THREADS]^thread.Thread
	for index in 0 ..< THREADS {
		workers[index] = Create_Worker {
			kernel  = &kernel,
			id      = u32(100 + index),
			ordinal = index,
		}
		threads[index] = thread.create_and_start_with_data(&workers[index], create_worker)
	}
	for index in 0 ..< THREADS {
		thread.join(threads[index])
		thread.destroy(threads[index])
	}

	for worker, index in workers {
		testing.expect_value(t, worker.failed, Kernel_Error.None)
		_, found := snapshot_relation_metadata(kernel.current, Relation_ID(100 + index))
		testing.expect(t, found)
	}
	testing.expect_value(t, kernel.current.version, u64(THREADS))
}

// Readers racing to materialize a block's secondary index for the first time.
// The one-time build is guarded by a sync.Once on the block; without it,
// concurrent first readers could observe a half-built index.
@(private)
Index_Reader :: struct {
	block:      ^Relation_Block,
	bindings:   []v.Binding,
	expected:   int,
	iterations: int,
	failures:   int,
}

@(private)
index_reader :: proc(data: rawptr) {
	context = runtime.default_context()
	worker := (^Index_Reader)(data)
	rows: [dynamic]v.Tuple
	defer delete(rows)
	for _ in 0 ..< worker.iterations {
		clear(&rows)
		relation_block_scan_into(worker.block, worker.bindings, &rows)
		if len(rows) != worker.expected {
			worker.failures += 1
		}
	}
}

@(test)
test_concurrent_first_index_materialization :: proc(t: ^testing.T) {
	kernel: Kernel
	kernel_init(&kernel)
	defer kernel_destroy(&kernel)

	// 4096 rows in four groups of 1024; index over the group column. The
	// pooled block gives the readers a thread-safe allocator for the one-time
	// index build.
	metadata := relation_metadata(Relation_ID(1), v.symbol_intern("IndexRace"), 2)
	metadata.indexes = []Index_Spec{index_spec([]u16{0})}
	rows := make([]v.Tuple, 4096, context.temp_allocator)
	for i in 0 ..< len(rows) {
		group, _ := v.identity_new(u64(i / 1024))
		item, _ := v.identity_new(u64(i))
		rows[i] = tuple_of(v.value_identity(group), v.value_identity(item))
	}
	block := relation_block_build_pooled(&kernel, metadata, rows)
	defer relation_block_release(block)

	group, _ := v.identity_new(1)
	bindings := []v.Binding{v.binding_of(v.value_identity(group)), {}}

	READERS :: 4
	ITERATIONS :: 200
	readers: [READERS]Index_Reader
	threads: [READERS]^thread.Thread
	for index in 0 ..< READERS {
		readers[index] = Index_Reader {
			block      = block,
			bindings   = bindings,
			expected   = 1024,
			iterations = ITERATIONS,
		}
		threads[index] = thread.create_and_start_with_data(&readers[index], index_reader)
	}
	for index in 0 ..< len(threads) {
		thread.join(threads[index])
		thread.destroy(threads[index])
	}
	for reader in readers {
		testing.expect_value(t, reader.failures, 0)
		testing.expect_value(t, reader.iterations, ITERATIONS)
	}
}
