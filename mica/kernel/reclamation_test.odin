// Reclamation tests: superseded blocks and their arenas must be recycled
// instead of accumulating with the commit count.
package kernel

import "core:testing"
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
