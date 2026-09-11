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
	testing.expect(t, len(kernel.arena_pool.arenas) <= 4)
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
