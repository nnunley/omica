// Reclamation tests: superseded blocks and their arenas must be recycled
// instead of accumulating with the commit count.
package kernel

import "base:runtime"
import "core:sync"
import "core:testing"
import "core:thread"
import v "../var"

@(test)
test_committed_history_is_reclaimed :: proc(t: ^testing.T) {
	kernel: Kernel
	kernel_init(&kernel)
	defer kernel_destroy(&kernel)

	relation := create_relation(&kernel, 1, "Reclaim", 1)

	commits := 256
	for index in 0 ..< commits {
		tx := kernel_begin(&kernel)
		testing.expect_value(
			t,
			transaction_assert(&tx, relation, tuple_of(must_identity(u64(index) + 1))),
			Kernel_Error.None,
		)
		committed, err := transaction_commit(&tx)
		testing.expect_value(t, err, Kernel_Error.None)
		snapshot_release(committed)
		transaction_destroy(&tx)
	}

	// Only the current block survives; every superseded block returned its
	// arena to the pool.
	block, found := snapshot_relation_block(kernel.current, relation)
	testing.expect(t, found)
	testing.expect_value(t, relation_block_len(block), commits)
	testing.expect_value(t, block.refs, i32(1))

	// The pool holds a small number of recycled arenas, not one per commit.
	total_arenas := 0
	for shard in kernel.arena_pool.shards {
		total_arenas += len(shard.arenas)
	}
	testing.expect(t, total_arenas <= 8)
}

@(test)
test_retained_snapshot_pins_its_block :: proc(t: ^testing.T) {
	kernel: Kernel
	kernel_init(&kernel)
	defer kernel_destroy(&kernel)

	relation := create_relation(&kernel, 1, "Pinned", 1)

	tx := kernel_begin(&kernel)
	transaction_assert(&tx, relation, tuple_of(must_identity(1)))
	committed, err := transaction_commit(&tx)
	testing.expect_value(t, err, Kernel_Error.None)
	snapshot_release(committed)
	transaction_destroy(&tx)

	held := kernel_snapshot(&kernel)
	defer snapshot_release(held)
	held_block, held_found := snapshot_relation_block(held, relation)
	testing.expect(t, held_found)

	// Advance the world. The held snapshot's block must stay readable and
	// unchanged because the snapshot pins it.
	tx2 := kernel_begin(&kernel)
	transaction_assert(&tx2, relation, tuple_of(must_identity(2)))
	committed2, err2 := transaction_commit(&tx2)
	testing.expect_value(t, err2, Kernel_Error.None)
	snapshot_release(committed2)
	transaction_destroy(&tx2)
	transaction_destroy(&tx2)

	testing.expect_value(t, held.version, u64(2))
	testing.expect_value(t, relation_block_len(held_block), 1)

	rows: [dynamic]v.Tuple
	defer delete(rows)
	relation_source_scan_into(
		&Relation_Source{snapshot = held, use_stored_derived = true},
		relation,
		[]v.Binding{{}},
		&rows,
	)
	testing.expect_value(t, len(rows), 1)

	current_block, current_found := snapshot_relation_block(kernel.current, relation)
	testing.expect(t, current_found)
	testing.expect_value(t, relation_block_len(current_block), 2)
}

@(test)
test_cow_commit_shares_untouched_chunks :: proc(t: ^testing.T) {
	kernel: Kernel
	kernel_init(&kernel)
	defer kernel_destroy(&kernel)

	relation := create_relation(&kernel, 1, "Cow", 1)

	// Seed 300 rows in one transaction: three full chunks.
	tx := kernel_begin(&kernel)
	for index in 0 ..< 300 {
		testing.expect_value(
			t,
			transaction_assert(&tx, relation, tuple_of(must_identity(u64(index + 1) * 2))),
			Kernel_Error.None,
		)
	}
	committed, err := transaction_commit(&tx)
	testing.expect_value(t, err, Kernel_Error.None)
	snapshot_release(committed)
	transaction_destroy(&tx)

	held := kernel_snapshot(&kernel)
	defer snapshot_release(held)
	block1, found1 := snapshot_relation_block(held, relation)
	testing.expect(t, found1)
	testing.expect_value(t, relation_block_len(block1), 300)
	testing.expect_value(t, len(block1.chunks), 3)

	// Insert into the middle chunk: only that chunk is rebuilt.
	tx2 := kernel_begin(&kernel)
	testing.expect_value(
		t,
		transaction_assert(&tx2, relation, tuple_of(must_identity(301))),
		Kernel_Error.None,
	)
	committed2, err2 := transaction_commit(&tx2)
	testing.expect_value(t, err2, Kernel_Error.None)
	snapshot_release(committed2)
	transaction_destroy(&tx2)

	held2 := kernel_snapshot(&kernel)
	defer snapshot_release(held2)
	block2, found2 := snapshot_relation_block(held2, relation)
	testing.expect(t, found2)
	testing.expect_value(t, relation_block_len(block2), 301)
	testing.expect(t, block2.chunks[0] == block1.chunks[0])
	testing.expect(t, block2.chunks[len(block2.chunks) - 1] == block1.chunks[2])
	testing.expect(t, block2.chunks[1] != block1.chunks[1])

	// Append beyond the end: every existing chunk is shared.
	tx3 := kernel_begin(&kernel)
	testing.expect_value(
		t,
		transaction_assert(&tx3, relation, tuple_of(must_identity(601))),
		Kernel_Error.None,
	)
	committed3, err3 := transaction_commit(&tx3)
	testing.expect_value(t, err3, Kernel_Error.None)
	snapshot_release(committed3)
	transaction_destroy(&tx3)

	block3, found3 := snapshot_relation_block(kernel.current, relation)
	testing.expect(t, found3)
	testing.expect_value(t, relation_block_len(block3), 302)

	// The append either filled the last chunk (replacing only it) or started a
	// new one; either way every earlier chunk is shared.
	testing.expect(t, block3.chunks[0] == block2.chunks[0])
	if len(block3.chunks) == len(block2.chunks) {
		testing.expect(t, block3.chunks[len(block3.chunks) - 1] != block2.chunks[len(block2.chunks) - 1])
		for index in 0 ..< len(block2.chunks) - 1 {
			testing.expect(t, block3.chunks[index] == block2.chunks[index])
		}
	} else {
		testing.expect_value(t, len(block3.chunks), len(block2.chunks) + 1)
		for index in 0 ..< len(block2.chunks) {
			testing.expect(t, block3.chunks[index] == block2.chunks[index])
		}
	}
}

@(test)
test_snapshot_chain_stays_bounded :: proc(t: ^testing.T) {
	kernel: Kernel
	kernel_init(&kernel)
	defer kernel_destroy(&kernel)

	relation := create_relation(&kernel, 90, "Chain", 1)

	// Hold a snapshot for the whole chain. It keeps blocks alive but must not
	// keep superseded snapshots alive.
	old := kernel_snapshot(&kernel)
	defer snapshot_release(old)

	for index in 0 ..< 100 {
		commit_chain_row(t, &kernel, relation, index)
	}
	arenas_after_warmup := arena_pool_live_count(kernel.arena_pool) +
		arena_pool_idle_count(kernel.arena_pool)

	for index in 100 ..< 400 {
		commit_chain_row(t, &kernel, relation, index)
	}
	arenas_after_chain := arena_pool_live_count(kernel.arena_pool) +
		arena_pool_idle_count(kernel.arena_pool)

	// Retired snapshots drain after every commit because the held snapshot is
	// a block owner, not a chain member.
	testing.expect_value(t, len(kernel.retired), 0)
	testing.expectf(
		t,
		arenas_after_chain <= arenas_after_warmup + 4,
		"arena count grew from %d to %d over 300 commits",
		arenas_after_warmup,
		arenas_after_chain,
	)
	testing.expect_value(t, old.version, u64(1))
}

@(private)
commit_chain_row :: proc(t: ^testing.T, kernel: ^Kernel, relation: Relation_ID, index: int) {
	tx := kernel_begin(kernel)
	testing.expect_value(
		t,
		transaction_assert(&tx, relation, tuple_of(must_identity(u64(index) + 1))),
		Kernel_Error.None,
	)
	published, err := transaction_commit(&tx)
	testing.expect_value(t, err, Kernel_Error.None)
	snapshot_release(published)
	transaction_destroy(&tx)
}

@(private)
Hazard_Writer :: struct {
	kernel:   ^Kernel,
	relation: Relation_ID,
	count:    int,
	done:     i32,
	failed:   Kernel_Error,
}

@(private)
hazard_writer :: proc(data: rawptr) {
	context = runtime.default_context()
	worker := (^Hazard_Writer)(data)
	for index in 0 ..< worker.count {
		tx := kernel_begin(worker.kernel)
		if err := transaction_assert(
			&tx,
			worker.relation,
			tuple_of(must_identity(u64(index) + 1)),
		); err != .None {
			worker.failed = err
			transaction_destroy(&tx)
			return
		}
		published, err := transaction_commit(&tx)
		if err != .None {
			worker.failed = err
			transaction_destroy(&tx)
			return
		}
		snapshot_release(published)
		transaction_destroy(&tx)
	}
	sync.atomic_store(&worker.done, 1)
}

@(private)
Hazard_Reader :: struct {
	kernel:    ^Kernel,
	writer_done: ^i32,
	iterations: int,
	last:      u64,
	monotonic: bool,
}

@(private)
hazard_reader :: proc(data: rawptr) {
	context = runtime.default_context()
	worker := (^Hazard_Reader)(data)
	for _ in 0 ..< worker.iterations {
		snapshot := kernel_snapshot_borrow(worker.kernel)
		version := snapshot.version
		kernel_hazard_clear(worker.kernel)
		if version < worker.last {
			worker.monotonic = false
		}
		worker.last = version
		if sync.atomic_load(worker.writer_done) != 0 {
			break
		}
	}
}

@(test)
test_snapshot_hazard_borrow_scales :: proc(t: ^testing.T) {
	kernel: Kernel
	kernel_init(&kernel)
	defer kernel_destroy(&kernel)

	relation := create_relation(&kernel, 91, "Hazard", 1)
	writer := Hazard_Writer {
		kernel   = &kernel,
		relation = relation,
		count    = 500,
	}
	reader := Hazard_Reader {
		kernel      = &kernel,
		writer_done = &writer.done,
		iterations  = 2_000_000,
		monotonic   = true,
	}
	writer_thread := thread.create_and_start_with_data(&writer, hazard_writer)
	reader_thread := thread.create_and_start_with_data(&reader, hazard_reader)
	thread.join(writer_thread)
	thread.destroy(writer_thread)
	thread.join(reader_thread)
	thread.destroy(reader_thread)

	testing.expect_value(t, writer.failed, Kernel_Error.None)
	testing.expect(t, reader.monotonic)
	testing.expect(t, reader.last >= 1)
	testing.expect(t, kernel.current.version >= u64(writer.count))
	testing.expect_value(t, len(kernel.retired), 0)
}
