// Transactions: staged writes over a base snapshot with read-your-own-writes
// and snapshot-isolation commit.
//
// A transaction owns an arena for values and tuples it creates. On commit the
// arena is handed to the new snapshot; on abort it is destroyed with the
// transaction. Commit either succeeds against the published snapshot, or
// validates conflicts for a rebase onto a newer published snapshot, matching
// the relation conflict policy.
package kernel

import "base:runtime"
import "core:mem"
import "core:mem/virtual"
import "core:slice"
import "core:sync"
import v "../var"

// The kind of a staged write.
Write_Kind :: enum {
	Assert,
	Retract,
}

// A staged tuple change.
Pending_Write :: struct {
	tuple: v.Tuple,
	kind:  Write_Kind,
}

// Staged writes for one relation.
Relation_Writes :: struct {
	relation: Relation_ID,
	entries:  [dynamic]Pending_Write,
}

// A snapshot-isolated transaction over a base snapshot.
Transaction :: struct {
	kernel:        ^Kernel,
	base:          ^Snapshot,
	arena:         ^Frame_Arena,
	allocator:     mem.Allocator,
	writes:        [dynamic]Relation_Writes,
	derived:       []Derived_Relation,
	derived_valid: bool,
	read_only:     bool,
}

// Creates a transaction over the kernel's current snapshot. The transaction
// takes a reset staging arena from the kernel pool.
transaction_begin :: proc(kernel: ^Kernel) -> Transaction {
	arena := kernel_take_arena(kernel)
	base := kernel_snapshot(kernel)
	return Transaction {
		kernel = kernel,
		base = base,
		arena = arena,
		allocator = frame_arena_allocator(arena),
		read_only = false,
	}
}

// Releases transaction resources. Safe to call after commit.
transaction_destroy :: proc(transaction: ^Transaction) {
	for &writes in transaction.writes {
		delete(writes.entries)
	}
	delete(transaction.writes)
	transaction.writes = nil

	if transaction.arena != nil {
		kernel_return_arena(transaction.kernel, transaction.arena)
		transaction.arena = nil
	}
	snapshot_release(transaction.base)
	transaction.base = nil
}

// Returns the base version of the transaction.
transaction_base_version :: proc(transaction: ^Transaction) -> u64 {
	return transaction.base.version
}

@(private)
transaction_relation_writes :: proc(
	transaction: ^Transaction,
	relation: Relation_ID,
	create: bool,
) -> (
	^Relation_Writes,
	bool,
) {
	for &writes in transaction.writes {
		if writes.relation == relation {
			return &writes, true
		}
	}
	if !create {
		return nil, false
	}
	append(&transaction.writes, Relation_Writes{relation = relation})
	return &transaction.writes[len(transaction.writes) - 1], true
}

@(private)
transaction_record_write :: proc(
	transaction: ^Transaction,
	relation: Relation_ID,
	tuple: v.Tuple,
	kind: Write_Kind,
) {
	writes, _ := transaction_relation_writes(transaction, relation, true)
	for &entry in writes.entries {
		if v.tuple_eq(entry.tuple, tuple) {
			entry.kind = kind
			return
		}
	}
	append(&writes.entries, Pending_Write{tuple = tuple, kind = kind})
}

@(private)
tuple_key_values :: proc(
	tuple: v.Tuple,
	positions: []u16,
	alloc: mem.Allocator,
) -> []v.Value {
	values := make([]v.Value, len(positions), alloc)
	for position, i in positions {
		values[i] = v.tuple_values(tuple)[int(position)]
	}
	return values
}

// Returns the effective staged change for a tuple, if any.
transaction_effective_write :: proc(
	transaction: ^Transaction,
	relation: Relation_ID,
	tuple: v.Tuple,
) -> (
	Write_Kind,
	bool,
) {
	writes, ok := transaction_relation_writes(transaction, relation, false)
	if !ok {
		return .Assert, false
	}
	for entry in writes.entries {
		if v.tuple_eq(entry.tuple, tuple) {
			return entry.kind, true
		}
	}
	return .Assert, false
}

// Stages an assertion. Fails for unknown relations, arity mismatches,
// non-persistable values, and functional-key violations against the visible
// transaction state.
transaction_assert :: proc(
	transaction: ^Transaction,
	relation: Relation_ID,
	tuple: v.Tuple,
) -> Kernel_Error {
	if transaction.read_only {
		return .Read_Only
	}
	metadata, ok := snapshot_relation_metadata(transaction.base, relation)
	if !ok {
		return .Unknown_Relation
	}
	if int(metadata.arity) != v.tuple_arity(tuple) {
		return .Arity_Mismatch
	}
	for cell in v.tuple_values(tuple) {
		if !v.value_is_storable(cell) {
			return .Non_Persistent_Value
		}
	}

	owned := v.tuple_deep_copy(transaction.allocator, tuple)
	if metadata.conflict.kind == .Functional {
		key_values := tuple_key_values(owned, metadata.conflict.key_positions, context.temp_allocator)
		existing, found := transaction_tuple_for_key(
			transaction,
			relation,
			metadata.conflict.key_positions,
			key_values,
		)
		if found && !v.tuple_eq(existing, owned) {
			return .Functional_Key_Violation
		}
	}

	transaction_record_write(transaction, relation, owned, .Assert)
	transaction.derived_valid = false
	return .None
}

// Stages a retraction. Fails for unknown relations, arity mismatches, and
// non-persistable values.
transaction_retract :: proc(
	transaction: ^Transaction,
	relation: Relation_ID,
	tuple: v.Tuple,
) -> Kernel_Error {
	if transaction.read_only {
		return .Read_Only
	}
	metadata, ok := snapshot_relation_metadata(transaction.base, relation)
	if !ok {
		return .Unknown_Relation
	}
	if int(metadata.arity) != v.tuple_arity(tuple) {
		return .Arity_Mismatch
	}
	for cell in v.tuple_values(tuple) {
		if !v.value_is_storable(cell) {
			return .Non_Persistent_Value
		}
	}

	owned := v.tuple_deep_copy(transaction.allocator, tuple)
	transaction_record_write(transaction, relation, owned, .Retract)
	transaction.derived_valid = false
	return .None
}

// Visits transaction-visible extensional tuples matching a partial binding.
// The visitor returns false to stop.
transaction_visit_extensional :: proc(
	transaction: ^Transaction,
	relation: Relation_ID,
	bindings: []v.Binding,
	visit: proc(user: rawptr, row: v.Tuple) -> bool,
	user: rawptr,
) {
	if block, ok := snapshot_relation_block(transaction.base, relation); ok {
		ctx := Transaction_Base_Scan {
			transaction = transaction,
			relation = relation,
			visit = visit,
			user = user,
		}
		relation_block_visit(block, bindings, transaction_base_visit, &ctx)
		if ctx.stopped {
			return
		}
	}

	writes, has_writes := transaction_relation_writes(transaction, relation, false)
	if !has_writes {
		return
	}
	for entry in writes.entries {
		if entry.kind != .Assert {
			continue
		}
		if snapshot_contains_extensional(transaction.base, relation, entry.tuple) {
			continue
		}
		if !v.tuple_matches_bindings(entry.tuple, bindings) {
			continue
		}
		if !visit(user, entry.tuple) {
			return
		}
	}
}

@(private)
Transaction_Base_Scan :: struct {
	transaction: ^Transaction,
	relation:    Relation_ID,
	visit:       proc(user: rawptr, row: v.Tuple) -> bool,
	user:        rawptr,
	stopped:     bool,
}

@(private)
transaction_base_visit :: proc(user: rawptr, row: v.Tuple) -> bool {
	ctx := (^Transaction_Base_Scan)(user)
	if kind, ok := transaction_effective_write(ctx.transaction, ctx.relation, row); ok {
		if kind == .Retract {
			return true
		}
	}
	if !ctx.visit(ctx.user, row) {
		ctx.stopped = true
		return false
	}
	return true
}

// Appends transaction-visible extensional tuples matching a partial binding.
transaction_scan_extensional_into :: proc(
	transaction: ^Transaction,
	relation: Relation_ID,
	bindings: []v.Binding,
	out: ^[dynamic]v.Tuple,
) {
	transaction_visit_extensional(
		transaction,
		relation,
		bindings,
		proc(user: rawptr, row: v.Tuple) -> bool {
			append((^[dynamic]v.Tuple)(user), row)
			return true
		},
		out,
	)
}

// Returns the tuple visible for an exact projected key in the transaction.
transaction_tuple_for_key :: proc(
	transaction: ^Transaction,
	relation: Relation_ID,
	positions: []u16,
	key_values: []v.Value,
) -> (
	v.Tuple,
	bool,
) {
	metadata, ok := snapshot_relation_metadata(transaction.base, relation)
	if !ok {
		return nil, false
	}
	if len(key_values) != len(positions) {
		return nil, false
	}
	scan_bindings := make([]v.Binding, metadata.arity, context.temp_allocator)
	for position, i in positions {
		scan_bindings[int(position)] = v.binding_of(key_values[i])
	}

	found: v.Tuple
	transaction_visit_extensional(
		transaction,
		relation,
		scan_bindings,
		proc(user: rawptr, row: v.Tuple) -> bool {
			(^v.Tuple)(user)^ = row
			return false
		},
		&found,
	)
	return found, found != nil
}

// Returns transaction-stored derived rows for a relation.
transaction_derived_rows :: proc(transaction: ^Transaction, relation: Relation_ID) -> []v.Tuple {
	for derived in transaction.derived {
		if derived.relation == relation {
			return derived.tuples
		}
	}
	return nil
}

// Recomputes derived facts visible in the transaction, if stale. Evaluation
// runs in a short-lived arena; surviving tuples are deep-copied into the
// transaction arena.
transaction_evaluate_derived :: proc(transaction: ^Transaction) -> Kernel_Error {
	if transaction.derived_valid {
		return .None
	}

	arena := new(virtual.Arena)
	if err := virtual.arena_init_growing(arena); err != nil {
		panic("failed to initialize rule evaluation arena")
	}
	defer {
		virtual.arena_destroy(arena)
		free(arena)
	}
	alloc := virtual.arena_allocator(arena)

	result := rules_derived_create(alloc)
	source := Relation_Source {
		transaction = transaction,
		derived     = &result,
	}
	if err := rules_evaluate_source(alloc, transaction.base.rules, &source, &result); err != .None {
		return err
	}

	transaction.derived = derived_relations_from(transaction.allocator, &result)
	transaction.derived_valid = true
	return .None
}

// Validates a transaction's writes against a newer published snapshot.
@(private)
transaction_validate_conflicts :: proc(
	transaction: ^Transaction,
	current: ^Snapshot,
) -> Kernel_Error {
	for &writes in transaction.writes {
		metadata, ok := snapshot_relation_metadata(transaction.base, writes.relation)
		if !ok {
			continue
		}
		switch metadata.conflict.kind {
		case .Event_Append:
			continue
		case .Set:
			for entry in writes.entries {
				if entry.kind != .Assert {
					continue
				}
				base_has := snapshot_contains_extensional(transaction.base, writes.relation, entry.tuple)
				current_has := snapshot_contains_extensional(current, writes.relation, entry.tuple)
				if base_has && !current_has {
					return .Conflict
				}
			}
		case .Functional:
			keys: [dynamic][]v.Value
			defer delete(keys)
			for entry in writes.entries {
				key := make([]v.Value, len(metadata.conflict.key_positions), context.temp_allocator)
				for position, i in metadata.conflict.key_positions {
					key[i] = v.tuple_values(entry.tuple)[int(position)]
				}
				duplicate := false
				for existing in keys {
					if key_values_equal(existing, key) {
						duplicate = true
						break
					}
				}
				if !duplicate {
					append(&keys, key)
				}
			}

			for key in keys {
				base_tuple, base_ok := snapshot_tuple_for_key(
					transaction.base,
					writes.relation,
					metadata.conflict.key_positions,
					key,
				)
				current_tuple, current_ok := snapshot_tuple_for_key(
					current,
					writes.relation,
					metadata.conflict.key_positions,
					key,
				)
				if !optional_tuple_eq(base_tuple, base_ok, current_tuple, current_ok) {
					return .Conflict
				}
			}
		}
	}
	return .None
}

@(private)
key_values_equal :: proc(a, b: []v.Value) -> bool {
	if len(a) != len(b) {
		return false
	}
	for value, i in a {
		if !v.value_eq(value, b[i]) {
			return false
		}
	}
	return true
}

@(private)
optional_tuple_eq :: proc(a: v.Tuple, a_ok: bool, b: v.Tuple, b_ok: bool) -> bool {
	if a_ok != b_ok {
		return false
	}
	if !a_ok {
		return true
	}
	return v.tuple_eq(a, b)
}

// Commits the transaction, publishing a new snapshot. On success the returned
// snapshot is caller-owned. The transaction must be destroyed by the caller.
//
// A task owns one thread and one transaction. Commits to the same relation are
// serialised by striped relation locks so a candidate is prepared against a
// stable relation block; commits to different relations proceed concurrently.
// Publication happens in groups: whichever task thread arrives first drains
// the queued candidates and merges them into one snapshot, so independent
// tasks do not invalidate one another's prepared work.
transaction_commit :: proc(transaction: ^Transaction) -> (^Snapshot, Kernel_Error) {
	kernel := transaction.kernel

	write_stripes := transaction_write_stripes(transaction)
	for present, stripe in write_stripes {
		if present {
			sync.mutex_lock(&kernel.relation_locks[stripe])
		}
	}
	defer {
		for present, stripe in write_stripes {
			if present {
				sync.mutex_unlock(&kernel.relation_locks[stripe])
			}
		}
	}

	current := kernel_snapshot(kernel)
	if current.version != transaction.base.version {
		if err := transaction_validate_conflicts(transaction, current); err != .None {
			snapshot_release(current)
			return nil, err
		}
	}

	transaction_prepare_writes(transaction)
	candidate := transaction_build_candidate(kernel, transaction, current)

	// The entry owns its own reference to the base so the committer can
	// replace it while rebasing; the task keeps its `current` reference.
	snapshot_retain(current)
	entry := Commit_Entry {
		transaction = transaction,
		base        = current,
		candidate   = candidate,
	}
	if kernel_commit_enqueue(kernel, &entry) {
		kernel_committer_drain(kernel)
	} else {
		kernel_commit_wait(kernel, &entry)
	}

	snapshot_release(current)
	if entry.published == nil {
		return nil, .Conflict
	}
	return entry.published, .None
}

// Returns the lock stripes for the transaction's writes as a stack bitset.
@(private)
transaction_write_stripes :: proc(transaction: ^Transaction) -> [RELATION_LOCK_STRIPES]bool {
	stripes: [RELATION_LOCK_STRIPES]bool
	for writes in transaction.writes {
		stripes[int(writes.relation) % RELATION_LOCK_STRIPES] = true
	}
	return stripes
}

// Builds an unpublished candidate snapshot from `current`. The caller owns the
// returned reference.
@(private)
transaction_build_candidate :: proc(
	kernel: ^Kernel,
	transaction: ^Transaction,
	current: ^Snapshot,
) -> ^Snapshot {
	fork := snapshot_create(kernel, current.version + 1, current)

	fork.catalog = make([]Relation_Metadata, len(current.catalog), fork.allocator)
	copy(fork.catalog, current.catalog)
	fork.blocks = make([]^Relation_Block, len(current.blocks), fork.allocator)
	for block, index in current.blocks {
		relation_block_retain(block)
		fork.blocks[index] = block
	}
	fork.rules = make([]Rule_Definition, len(current.rules), fork.allocator)
	copy(fork.rules, current.rules)

	for &writes in transaction.writes {
		metadata, ok := snapshot_relation_metadata(current, writes.relation)
		if !ok {
			continue
		}

		// Copy-on-write against the block in the snapshot we are committing
		// onto, so a rebase merges with the other transaction's changes.
		current_block, _ := snapshot_relation_block(current, writes.relation)
		block := relation_block_apply(kernel, current_block, metadata, writes.entries[:])
		snapshot_set_block(fork, block)
	}

	snapshot_compute_derived(fork)
	return fork
}

// Adopts the winner's state into an existing candidate in place: blocks the
// winner replaced for relations this transaction did not write are swapped in,
// catalog and rules are refreshed, and derived facts are recomputed. Returns
// false when the candidate's shape no longer matches the winner (for example a
// concurrent relation creation), in which case the caller rebuilds.
@(private)
transaction_rebase_in_place :: proc(
	kernel: ^Kernel,
	transaction: ^Transaction,
	candidate: ^Snapshot,
	winner: ^Snapshot,
) -> bool {
	if len(candidate.catalog) != len(winner.catalog) ||
	   len(candidate.rules) != len(winner.rules) ||
	   len(candidate.blocks) != len(winner.blocks) {
		return false
	}

	for block, index in candidate.blocks {
		winner_block := winner.blocks[index]
		if winner_block.metadata.id != block.metadata.id {
			// The two snapshots materialized different relation blocks, so
			// positions are not comparable. Rebuild from the winner instead.
			return false
		}
		if winner_block == block {
			continue
		}
		if transaction_writes_relation(transaction, block.metadata.id) {
			// Our prepared block is authoritative for a relation whose stripe
			// we hold; the winner cannot have changed it.
			continue
		}
		relation_block_retain(winner_block)
		candidate.blocks[index] = winner_block
		relation_block_release(block)
	}

	copy(candidate.catalog, winner.catalog)
	copy(candidate.rules, winner.rules)
	candidate.version = winner.version + 1
	candidate.parent = winner
	snapshot_compute_derived(candidate)
	return true
}

// Filters and sorts staged writes once, before candidate construction. A
// rebased retract only removes tuples the transaction's base actually held; a
// concurrent assert of a tuple the base lacked survives. Asserts always apply.
@(private)
transaction_prepare_writes :: proc(transaction: ^Transaction) {
	for &writes in transaction.writes {
		base_block, _ := snapshot_relation_block(transaction.base, writes.relation)
		write := 0
		for entry in writes.entries {
			if entry.kind == .Retract &&
			   (base_block == nil || !relation_block_contains(base_block, entry.tuple)) {
				continue
			}
			writes.entries[write] = entry
			write += 1
		}
		if write != len(writes.entries) {
			resize(&writes.entries, write)
		}
		if len(writes.entries) > 1 {
			slice.sort_by(writes.entries[:], proc(a, b: Pending_Write) -> bool {
				return v.tuple_cmp(a.tuple, b.tuple) == .Less
			})
		}
	}
}

@(private)
transaction_writes_relation :: proc(transaction: ^Transaction, relation: Relation_ID) -> bool {
	for writes in transaction.writes {
		if writes.relation == relation {
			return true
		}
	}
	return false
}

@(private)
remove_tuple :: proc(rows: ^[dynamic]v.Tuple, tuple: v.Tuple) {
	for row, i in rows {
		if v.tuple_eq(row, tuple) {
			ordered_remove(rows, i)
			return
		}
	}
}

@(private)
ordered_remove :: proc(rows: ^[dynamic]v.Tuple, index: int) {
	for i in index ..< len(rows) - 1 {
		rows[i] = rows[i + 1]
	}
	pop(rows)
}
