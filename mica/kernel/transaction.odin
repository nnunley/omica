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
	arena:         ^virtual.Arena,
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
		allocator = virtual.arena_allocator(arena),
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
		if !v.value_is_persistable(cell) {
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
		if !v.value_is_persistable(cell) {
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
// snapshot is caller-owned. The transaction must be destroyed by the caller;
// its arena ownership transfers to the returned snapshot.
transaction_commit :: proc(transaction: ^Transaction) -> (^Snapshot, Kernel_Error) {
	kernel := transaction.kernel
	sync.mutex_lock(&kernel.commit_lock)
	defer sync.mutex_unlock(&kernel.commit_lock)

	current := sync.atomic_load(&kernel.current)
	if current.version != transaction.base.version {
		if err := transaction_validate_conflicts(transaction, current); err != .None {
			return nil, err
		}
	}

	fork := snapshot_create(current.version + 1, current, kernel.world_allocator)

	fork.catalog = make([]Relation_Metadata, len(current.catalog), fork.allocator)
	copy(fork.catalog, current.catalog)
	fork.blocks = make([]^Relation_Block, len(current.blocks), fork.allocator)
	copy(fork.blocks, current.blocks)
	fork.rules = make([]Rule_Definition, len(current.rules), fork.allocator)
	copy(fork.rules, current.rules)

	for &writes in transaction.writes {
		metadata, ok := snapshot_relation_metadata(current, writes.relation)
		if !ok {
			continue
		}

		rows := make([dynamic]v.Tuple, 0, context.temp_allocator)
		if block, has_block := snapshot_relation_block(current, writes.relation); has_block {
			for row in block.tuples {
				append(&rows, row)
			}
		}

		slice.sort_by(writes.entries[:], proc(a, b: Pending_Write) -> bool {
			return v.tuple_cmp(a.tuple, b.tuple) == .Less
		})

		base_block, has_base := snapshot_relation_block(transaction.base, writes.relation)
		for entry in writes.entries {
			switch entry.kind {
			case .Assert:
				// Staged tuples live in the transaction staging arena, which is
				// recycled after commit, so copy them into the committed store.
				append(&rows, v.tuple_deep_copy(kernel.world_allocator, entry.tuple))
			case .Retract:
				if has_base && relation_block_contains(base_block, entry.tuple) {
					remove_tuple(&rows, entry.tuple)
				}
			}
		}

		block := relation_block_build(kernel.world_allocator, metadata, rows[:])
		snapshot_set_block(fork, block)
	}

	snapshot_compute_derived(fork)
	kernel_publish_locked(kernel, fork)
	return fork, .None
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
