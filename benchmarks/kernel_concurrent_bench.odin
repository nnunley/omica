// Concurrent transaction benchmarks.
//
// Each sample builds a fresh kernel, runs a fixed batch of transactions over
// real threads, and tears the kernel down. Parallel and serial batches perform
// the same number of commits so the reported throughput is directly
// comparable.
package main

import "base:runtime"
import "core:fmt"
import "core:sync"
import "core:thread"

import k "../mica/kernel"
import mm "../micromeasure"
import v "../mica/var"

DISJOINT_THREADS :: 8
DISJOINT_COMMITS_PER_THREAD :: 64
DISJOINT_TOTAL :: DISJOINT_THREADS * DISJOINT_COMMITS_PER_THREAD

CONTENDED_THREADS :: 8
CONTENDED_COMMITS_PER_THREAD :: 64
CONTENDED_TOTAL :: CONTENDED_THREADS * CONTENDED_COMMITS_PER_THREAD

READER_COUNT :: 4
READER_ROWS :: 1024
WRITER_COMMITS :: 256

@(private)
concurrent_identity :: proc(raw: u64) -> v.Value {
	value, _ := v.value_identity_raw(raw)
	return value
}

@(private)
concurrent_tuple1 :: proc(id: u64) -> v.Tuple {
	return v.tuple_new(context.temp_allocator, []v.Value{concurrent_identity(id)})
}

@(private)
concurrent_tuple2 :: proc(first: u64, second: u64) -> v.Tuple {
	return v.tuple_new(
		context.temp_allocator,
		[]v.Value{concurrent_identity(first), concurrent_identity(second)},
	)
}

@(private)
concurrent_relation :: proc(
	kernel: ^k.Kernel,
	id: u32,
	name: string,
	arity: u16,
	conflict: k.Conflict_Policy,
) -> k.Relation_ID {
	metadata := k.relation_metadata(k.Relation_ID(id), v.symbol_intern(name), arity)
	metadata.conflict = conflict
	snapshot, err := k.kernel_create_relation(kernel, metadata)
	assert(err == .None)
	k.snapshot_release(snapshot)
	return k.Relation_ID(id)
}

// --- Disjoint commits ------------------------------------------------------

@(private)
Disjoint_Bench_Worker :: struct {
	kernel:    ^k.Kernel,
	relation:  k.Relation_ID,
	thread_id: u64,
	count:     int,
	committed: int,
	failed:    k.Kernel_Error,
}

@(private)
disjoint_bench_worker :: proc(data: rawptr) {
	context = runtime.default_context()
	worker := (^Disjoint_Bench_Worker)(data)
	for index in 0 ..< worker.count {
		for {
			tx := k.kernel_begin(worker.kernel)
			tuple := concurrent_tuple1(worker.thread_id * 1_000_000 + u64(index) + 1)
			if err := k.transaction_assert(&tx, worker.relation, tuple); err != .None {
				worker.failed = err
				k.transaction_destroy(&tx)
				return
			}
			committed, err := k.transaction_commit(&tx)
			if err == .None {
				k.snapshot_release(committed)
				k.transaction_destroy(&tx)
				worker.committed += 1
				break
			}
			k.transaction_destroy(&tx)
			if err != .Conflict {
				worker.failed = err
				return
			}
		}
	}
}

@(private)
bench_parallel_disjoint_commits :: proc(_: rawptr, _: int, _: int) {
	kernel: k.Kernel
	k.kernel_init(&kernel)
	defer k.kernel_destroy(&kernel)
	relation := concurrent_relation(&kernel, 1, "BenchDisjoint", 1, k.conflict_set())

	workers: [DISJOINT_THREADS]Disjoint_Bench_Worker
	threads: [DISJOINT_THREADS]^thread.Thread
	for index in 0 ..< DISJOINT_THREADS {
		workers[index] = Disjoint_Bench_Worker {
			kernel    = &kernel,
			relation  = relation,
			thread_id = u64(index),
			count     = DISJOINT_COMMITS_PER_THREAD,
		}
		threads[index] = thread.create_and_start_with_data(
			&workers[index],
			disjoint_bench_worker,
		)
	}
	for index in 0 ..< DISJOINT_THREADS {
		thread.join(threads[index])
		thread.destroy(threads[index])
	}
	for worker in workers {
		assert(worker.failed == .None)
		assert(worker.committed == DISJOINT_COMMITS_PER_THREAD)
	}
}

@(private)
bench_serial_disjoint_commits :: proc(_: rawptr, _: int, _: int) {
	kernel: k.Kernel
	k.kernel_init(&kernel)
	defer k.kernel_destroy(&kernel)
	relation := concurrent_relation(&kernel, 1, "BenchDisjoint", 1, k.conflict_set())

	for index in 0 ..< DISJOINT_TOTAL {
		for {
			tx := k.kernel_begin(&kernel)
			tuple := concurrent_tuple1(u64(index) + 1)
			assert(k.transaction_assert(&tx, relation, tuple) == .None)
			committed, err := k.transaction_commit(&tx)
			if err == .None {
				k.snapshot_release(committed)
				k.transaction_destroy(&tx)
				break
			}
			k.transaction_destroy(&tx)
			assert(err == .Conflict)
		}
	}
}

// --- Contended functional commits ------------------------------------------

@(private)
Contended_Bench_Worker :: struct {
	kernel:    ^k.Kernel,
	relation:  k.Relation_ID,
	thread_id: u64,
	count:     int,
	committed: int,
	failed:    k.Kernel_Error,
}

@(private)
contended_bench_stage :: proc(
	worker: ^Contended_Bench_Worker,
	tx: ^k.Transaction,
	key_positions: []u16,
	key_values: []v.Value,
	tuple: v.Tuple,
) -> k.Kernel_Error {
	if existing, found := k.transaction_tuple_for_key(
		tx,
		worker.relation,
		key_positions,
		key_values,
	); found {
		if err := k.transaction_retract(tx, worker.relation, existing); err != .None {
			return err
		}
	}
	return k.transaction_assert(tx, worker.relation, tuple)
}

@(private)
contended_bench_worker :: proc(data: rawptr) {
	context = runtime.default_context()
	worker := (^Contended_Bench_Worker)(data)
	key_positions := []u16{0}
	key_values := make([]v.Value, 1, context.temp_allocator)
	key_values[0] = concurrent_identity(1)

	for index in 0 ..< worker.count {
		tuple := concurrent_tuple2(1, worker.thread_id * 1_000_000 + u64(index) + 2)
		for {
			tx := k.kernel_begin(worker.kernel)
			if err := contended_bench_stage(
				worker,
				&tx,
				key_positions,
				key_values,
				tuple,
			); err != .None {
				worker.failed = err
				k.transaction_destroy(&tx)
				return
			}
			committed, err := k.transaction_commit(&tx)
			if err == .None {
				k.snapshot_release(committed)
				k.transaction_destroy(&tx)
				worker.committed += 1
				break
			}
			k.transaction_destroy(&tx)
			if err != .Conflict {
				worker.failed = err
				return
			}
			sync.cpu_relax()
		}
	}
}

@(private)
bench_parallel_contended_commits :: proc(_: rawptr, _: int, _: int) {
	kernel: k.Kernel
	k.kernel_init(&kernel)
	defer k.kernel_destroy(&kernel)
	relation := concurrent_relation(
		&kernel,
		1,
		"BenchContended",
		2,
		k.conflict_functional([]u16{0}),
	)

	workers: [CONTENDED_THREADS]Contended_Bench_Worker
	threads: [CONTENDED_THREADS]^thread.Thread
	for index in 0 ..< CONTENDED_THREADS {
		workers[index] = Contended_Bench_Worker {
			kernel    = &kernel,
			relation  = relation,
			thread_id = u64(index),
			count     = CONTENDED_COMMITS_PER_THREAD,
		}
		threads[index] = thread.create_and_start_with_data(
			&workers[index],
			contended_bench_worker,
		)
	}
	for index in 0 ..< CONTENDED_THREADS {
		thread.join(threads[index])
		thread.destroy(threads[index])
	}
	for worker in workers {
		assert(worker.failed == .None)
		assert(worker.committed == CONTENDED_COMMITS_PER_THREAD)
	}
}

@(private)
bench_serial_contended_commits :: proc(_: rawptr, _: int, _: int) {
	kernel: k.Kernel
	k.kernel_init(&kernel)
	defer k.kernel_destroy(&kernel)
	relation := concurrent_relation(
		&kernel,
		1,
		"BenchContended",
		2,
		k.conflict_functional([]u16{0}),
	)

	key_positions := []u16{0}
	key_values := make([]v.Value, 1, context.temp_allocator)
	key_values[0] = concurrent_identity(1)

	for index in 0 ..< CONTENDED_TOTAL {
		tuple := concurrent_tuple2(1, u64(index) + 2)
		for {
			tx := k.kernel_begin(&kernel)
			if existing, found := k.transaction_tuple_for_key(
				&tx,
				relation,
				key_positions,
				key_values,
			); found {
				assert(k.transaction_retract(&tx, relation, existing) == .None)
			}
			assert(k.transaction_assert(&tx, relation, tuple) == .None)
			committed, err := k.transaction_commit(&tx)
			if err == .None {
				k.snapshot_release(committed)
				k.transaction_destroy(&tx)
				break
			}
			k.transaction_destroy(&tx)
			assert(err == .Conflict)
		}
	}
}

// --- Transaction begin/destroy ---------------------------------------------

@(private)
Begin_Bench_Worker :: struct {
	kernel: ^k.Kernel,
	count:  int,
}

@(private)
begin_bench_worker :: proc(data: rawptr) {
	context = runtime.default_context()
	worker := (^Begin_Bench_Worker)(data)
	for _ in 0 ..< worker.count {
		tx := k.kernel_begin(worker.kernel)
		k.transaction_destroy(&tx)
	}
}

BEGIN_THREADS :: 8
BEGIN_PER_THREAD :: 256
BEGIN_TOTAL :: BEGIN_THREADS * BEGIN_PER_THREAD

@(private)
bench_parallel_begins :: proc(_: rawptr, _: int, _: int) {
	kernel: k.Kernel
	k.kernel_init(&kernel)
	defer k.kernel_destroy(&kernel)

	workers: [BEGIN_THREADS]Begin_Bench_Worker
	threads: [BEGIN_THREADS]^thread.Thread
	for index in 0 ..< BEGIN_THREADS {
		workers[index] = Begin_Bench_Worker {
			kernel = &kernel,
			count  = BEGIN_PER_THREAD,
		}
		threads[index] = thread.create_and_start_with_data(
			&workers[index],
			begin_bench_worker,
		)
	}
	for index in 0 ..< BEGIN_THREADS {
		thread.join(threads[index])
		thread.destroy(threads[index])
	}
}

@(private)
bench_serial_begins :: proc(_: rawptr, _: int, _: int) {
	kernel: k.Kernel
	k.kernel_init(&kernel)
	defer k.kernel_destroy(&kernel)
	for _ in 0 ..< BEGIN_TOTAL {
		tx := k.kernel_begin(&kernel)
		k.transaction_destroy(&tx)
	}
}

// --- Readers during a writer -----------------------------------------------

@(private)
Reader_Bench_Worker :: struct {
	kernel:  ^k.Kernel,
	relation: k.Relation_ID,
	done:    ^i32,
	scans:   int,
}

@(private)
reader_bench_worker :: proc(data: rawptr) {
	context = runtime.default_context()
	worker := (^Reader_Bench_Worker)(data)
	for sync.atomic_load(worker.done) == 0 {
		current := k.kernel_snapshot(worker.kernel)
		rows: [dynamic]v.Tuple
		k.relation_source_scan_into(
			&k.Relation_Source{snapshot = current, use_stored_derived = true},
			worker.relation,
			[]v.Binding{{}},
			&rows,
		)
		delete(rows)
		k.snapshot_release(current)
		worker.scans += 1
	}
}

@(private)
Write_Bench_Worker :: struct {
	kernel:   ^k.Kernel,
	relation: k.Relation_ID,
	count:    int,
	done:     ^i32,
	failed:   k.Kernel_Error,
}

@(private)
write_bench_worker :: proc(data: rawptr) {
	context = runtime.default_context()
	worker := (^Write_Bench_Worker)(data)
	commits: for index in 0 ..< worker.count {
		for {
			tx := k.kernel_begin(worker.kernel)
			tuple := concurrent_tuple1(u64(index) + 1_000_000)
			if err := k.transaction_assert(&tx, worker.relation, tuple); err != .None {
				worker.failed = err
				k.transaction_destroy(&tx)
				break commits
			}
			committed, err := k.transaction_commit(&tx)
			if err == .None {
				k.snapshot_release(committed)
				k.transaction_destroy(&tx)
				break
			}
			k.transaction_destroy(&tx)
			if err != .Conflict {
				worker.failed = err
				break commits
			}
		}
	}
	sync.atomic_store(worker.done, 1)
}

@(private)
bench_readers_during_writer :: proc(_: rawptr, _: int, _: int) {
	kernel: k.Kernel
	k.kernel_init(&kernel)
	defer k.kernel_destroy(&kernel)
	relation := concurrent_relation(&kernel, 1, "BenchRead", 1, k.conflict_set())
	write_relation := concurrent_relation(&kernel, 2, "BenchWrite", 1, k.conflict_set())

	// Preload the read relation in one transaction.
	{
		tx := k.kernel_begin(&kernel)
		for index in 0 ..< READER_ROWS {
			assert(k.transaction_assert(&tx, relation, concurrent_tuple1(u64(index) + 1)) == .None)
		}
		committed, err := k.transaction_commit(&tx)
		assert(err == .None)
		k.snapshot_release(committed)
		k.transaction_destroy(&tx)
	}

	done: i32 = 0
	writer := Write_Bench_Worker {
		kernel   = &kernel,
		relation = write_relation,
		count    = WRITER_COMMITS,
		done     = &done,
	}
	readers: [READER_COUNT]Reader_Bench_Worker
	threads: [1 + READER_COUNT]^thread.Thread
	threads[0] = thread.create_and_start_with_data(&writer, write_bench_worker)
	for index in 0 ..< READER_COUNT {
		readers[index] = Reader_Bench_Worker {
			kernel   = &kernel,
			relation = relation,
			done     = &done,
		}
		threads[index + 1] = thread.create_and_start_with_data(
			&readers[index],
			reader_bench_worker,
		)
	}
	for index in 0 ..< len(threads) {
		thread.join(threads[index])
		thread.destroy(threads[index])
	}
	assert(writer.failed == .None)
	total_scans := 0
	for reader in readers {
		total_scans += reader.scans
	}
	assert(total_scans > 0)
}

@(private)
register_kernel_concurrent_benches :: proc(runner: ^mm.Runner) {
	disjoint := mm.group(
		runner,
		"kernel/concurrent/disjoint",
		mm.throughput_per_op(DISJOINT_TOTAL, "commit"),
	)
	mm.bench_capped(disjoint, "parallel_8x64", nil, bench_parallel_disjoint_commits, 1)
	mm.bench_capped(disjoint, "serial_512", nil, bench_serial_disjoint_commits, 1)

	contended := mm.group(
		runner,
		"kernel/concurrent/contended",
		mm.throughput_per_op(CONTENDED_TOTAL, "set-op"),
	)
	mm.bench_capped(contended, "parallel_8x64", nil, bench_parallel_contended_commits, 1)
	mm.bench_capped(contended, "serial_512", nil, bench_serial_contended_commits, 1)

	begins := mm.group(
		runner,
		"kernel/concurrent/begin",
		mm.throughput_per_op(BEGIN_TOTAL, "begin"),
	)
	mm.bench_capped(begins, "parallel_8x256", nil, bench_parallel_begins, 1)
	mm.bench_capped(begins, "serial_2048", nil, bench_serial_begins, 1)

	relations_group := mm.group(
		runner,
		"kernel/concurrent/relations",
		mm.throughput_per_op(RELATION_TOTAL, "commit"),
	)
	mm.bench_capped(
		relations_group,
		"parallel_8x64",
		nil,
		bench_parallel_relation_commits,
		1,
	)
	mm.bench_capped(
		relations_group,
		"serial_512",
		nil,
		bench_serial_relation_commits,
		1,
	)

	read_write := mm.group(
		runner,
		"kernel/concurrent/read-write",
		mm.throughput_per_op(1, "batch"),
	)
	mm.bench_capped(
		read_write,
		"readers_during_writer",
		nil,
		bench_readers_during_writer,
		1,
	)
}

// --- Parallel commits across relations -------------------------------------

@(private)
Relation_Bench_Worker :: struct {
	kernel:   ^k.Kernel,
	relation: k.Relation_ID,
	count:    int,
	committed: int,
	failed:   k.Kernel_Error,
}

@(private)
relation_bench_worker :: proc(data: rawptr) {
	context = runtime.default_context()
	worker := (^Relation_Bench_Worker)(data)
	for index in 0 ..< worker.count {
		for {
			tx := k.kernel_begin(worker.kernel)
			tuple := concurrent_tuple1(u64(index) + 1)
			if err := k.transaction_assert(&tx, worker.relation, tuple); err != .None {
				worker.failed = err
				k.transaction_destroy(&tx)
				return
			}
			committed, err := k.transaction_commit(&tx)
			if err == .None {
				k.snapshot_release(committed)
				k.transaction_destroy(&tx)
				worker.committed += 1
				break
			}
			k.transaction_destroy(&tx)
			if err != .Conflict {
				worker.failed = err
				return
			}
		}
	}
}

RELATION_THREADS :: 8
RELATION_COMMITS_PER_THREAD :: 256
RELATION_TOTAL :: RELATION_THREADS * RELATION_COMMITS_PER_THREAD

@(private)
bench_parallel_relation_commits :: proc(_: rawptr, _: int, _: int) {
	kernel: k.Kernel
	k.kernel_init(&kernel)
	defer k.kernel_destroy(&kernel)

	relations: [RELATION_THREADS]k.Relation_ID
	workers: [RELATION_THREADS]Relation_Bench_Worker
	threads: [RELATION_THREADS]^thread.Thread
	for index in 0 ..< RELATION_THREADS {
		relations[index] = concurrent_relation(
			&kernel,
			u32(100 + index),
			fmt.aprintf("BenchRelation%d", index, allocator = context.temp_allocator),
			1,
			k.conflict_set(),
		)
		workers[index] = Relation_Bench_Worker {
			kernel   = &kernel,
			relation = relations[index],
			count    = RELATION_COMMITS_PER_THREAD,
		}
		threads[index] = thread.create_and_start_with_data(
			&workers[index],
			relation_bench_worker,
		)
	}
	for index in 0 ..< RELATION_THREADS {
		thread.join(threads[index])
		thread.destroy(threads[index])
	}
	for worker in workers {
		assert(worker.failed == .None)
		assert(worker.committed == RELATION_COMMITS_PER_THREAD)
	}
}

@(private)
bench_serial_relation_commits :: proc(_: rawptr, _: int, _: int) {
	kernel: k.Kernel
	k.kernel_init(&kernel)
	defer k.kernel_destroy(&kernel)

	relations: [RELATION_THREADS]k.Relation_ID
	for index in 0 ..< RELATION_THREADS {
		relations[index] = concurrent_relation(
			&kernel,
			u32(100 + index),
			fmt.aprintf("BenchRelation%d", index, allocator = context.temp_allocator),
			1,
			k.conflict_set(),
		)
	}

	for index in 0 ..< RELATION_TOTAL {
		relation := relations[index % RELATION_THREADS]
		for {
			tx := k.kernel_begin(&kernel)
			tuple := concurrent_tuple1(u64(index / RELATION_THREADS) + 1)
			assert(k.transaction_assert(&tx, relation, tuple) == .None)
			committed, err := k.transaction_commit(&tx)
			if err == .None {
				k.snapshot_release(committed)
				k.transaction_destroy(&tx)
				break
			}
			k.transaction_destroy(&tx)
			assert(err == .Conflict)
		}
	}
}
