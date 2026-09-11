// Snapshot-published world state.
//
// A snapshot is immutable after publication. All snapshot data - values,
// tuples, blocks, metadata, and derived rows - lives in the kernel's shared
// committed store, so a snapshot holds no arena of its own. Each snapshot
// retains its parent so values inherited along the commit chain stay alive.
// Snapshots are reference-counted; the last release frees the header only,
// because the committed store outlives every snapshot.
package kernel

import "base:runtime"
import "core:mem"
import "core:mem/virtual"
import "core:slice"
import "core:sync"
import v "../var"

// A derived relation's rows, computed from rules at snapshot creation.
Derived_Relation :: struct {
	relation: Relation_ID,
	tuples:   []v.Tuple,
}

// Immutable world state at a version.
Snapshot :: struct {
	version:   u64,
	parent:    ^Snapshot,
	refs:      i32,
	allocator: mem.Allocator,
	catalog:   []Relation_Metadata,
	blocks:    []^Relation_Block,
	rules:     []Rule_Definition,
	derived:   []Derived_Relation,
}

// Creates an empty snapshot at `version` with an optional retained parent. The
// snapshot allocates from `allocator`, which must be the kernel's committed
// store and must outlive the snapshot.
snapshot_create :: proc(
	version: u64,
	parent: ^Snapshot,
	allocator: mem.Allocator,
) -> ^Snapshot {
	snapshot := new(Snapshot, runtime.default_allocator())
	snapshot.version = version
	snapshot.refs = 1
	snapshot.allocator = allocator
	snapshot.catalog = make([]Relation_Metadata, 0, snapshot.allocator)
	snapshot.blocks = make([]^Relation_Block, 0, snapshot.allocator)
	snapshot.rules = make([]Rule_Definition, 0, snapshot.allocator)
	snapshot.derived = make([]Derived_Relation, 0, snapshot.allocator)

	if parent != nil {
		snapshot_retain(parent)
		snapshot.parent = parent
	}
	return snapshot
}

// Increments the reference count of a snapshot. Thread-safe. A relaxed
// increment is sufficient: the reference itself is acquired with acquire
// semantics elsewhere.
snapshot_retain :: proc(snapshot: ^Snapshot) {
	if snapshot == nil {
		return
	}
	sync.atomic_add_explicit(&snapshot.refs, 1, .Relaxed)
}

// Decrements the reference count of a snapshot, destroying it and its arenas
// when the last reference is released. Thread-safe: a snapshot can only reach
// zero once every holder has released it.
snapshot_release :: proc(snapshot: ^Snapshot) {
	if snapshot == nil {
		return
	}
	// Only the releaser that observed the last reference may free. The other
	// releasers must not touch the snapshot after their decrement.
	if sync.atomic_sub_explicit(&snapshot.refs, 1, .Release) != 1 {
		return
	}
	// Acquire pairs with the release decrements so the freeing thread sees all
	// writes made while other holders still had references.
	sync.atomic_thread_fence(.Acquire)

	parent := snapshot.parent
	snapshot.parent = nil
	free(snapshot, runtime.default_allocator())
	snapshot_release(parent)
}

// Creates a child snapshot that inherits the parent catalog, blocks, and
// rules.
snapshot_fork :: proc(parent: ^Snapshot, allocator: mem.Allocator) -> ^Snapshot {
	snapshot := snapshot_create(parent.version + 1, parent, allocator)

	snapshot.catalog = make([]Relation_Metadata, len(parent.catalog), snapshot.allocator)
	copy(snapshot.catalog, parent.catalog)
	snapshot.blocks = make([]^Relation_Block, len(parent.blocks), snapshot.allocator)
	copy(snapshot.blocks, parent.blocks)
	snapshot.rules = make([]Rule_Definition, len(parent.rules), snapshot.allocator)
	copy(snapshot.rules, parent.rules)

	return snapshot
}

// Returns relation metadata by id.
snapshot_relation_metadata :: proc(
	snapshot: ^Snapshot,
	relation: Relation_ID,
) -> (
	Relation_Metadata,
	bool,
) {
	for metadata in snapshot.catalog {
		if metadata.id == relation {
			return metadata, true
		}
	}
	return {}, false
}

// Returns relation metadata by name.
snapshot_relation_metadata_named :: proc(
	snapshot: ^Snapshot,
	name: v.Symbol,
) -> (
	Relation_Metadata,
	bool,
) {
	for metadata in snapshot.catalog {
		if metadata.name == name {
			return metadata, true
		}
	}
	return {}, false
}

// Returns true when a relation exists in this snapshot's catalog.
snapshot_has_relation :: proc(snapshot: ^Snapshot, relation: Relation_ID) -> bool {
	for metadata in snapshot.catalog {
		if metadata.id == relation {
			return true
		}
	}
	return false
}

// Returns the materialized block for a relation, if any.
snapshot_relation_block :: proc(
	snapshot: ^Snapshot,
	relation: Relation_ID,
) -> (
	^Relation_Block,
	bool,
) {
	for block in snapshot.blocks {
		if block.metadata.id == relation {
			return block, true
		}
	}
	return nil, false
}

// Returns the rows of a derived relation stored on this snapshot.
snapshot_derived_rows :: proc(snapshot: ^Snapshot, relation: Relation_ID) -> []v.Tuple {
	for derived in snapshot.derived {
		if derived.relation == relation {
			return derived.tuples
		}
	}
	return nil
}

// Reports whether a relation tuple is visible in this snapshot, including
// derived facts.
snapshot_contains :: proc(
	snapshot: ^Snapshot,
	relation: Relation_ID,
	tuple: v.Tuple,
) -> bool {
	if block, ok := snapshot_relation_block(snapshot, relation); ok {
		if relation_block_contains(block, tuple) {
			return true
		}
	}
	for row in snapshot_derived_rows(snapshot, relation) {
		if v.tuple_eq(row, tuple) {
			return true
		}
	}
	return false
}

// Reports whether a relation tuple is stored extensionally in this snapshot.
snapshot_contains_extensional :: proc(
	snapshot: ^Snapshot,
	relation: Relation_ID,
	tuple: v.Tuple,
) -> bool {
	if block, ok := snapshot_relation_block(snapshot, relation); ok {
		return relation_block_contains(block, tuple)
	}
	return false
}

// Visits extensional tuples matching a partial binding.
snapshot_visit_extensional :: proc(
	snapshot: ^Snapshot,
	relation: Relation_ID,
	bindings: []v.Binding,
	visit: proc(user: rawptr, row: v.Tuple) -> bool,
	user: rawptr,
) {
	if block, ok := snapshot_relation_block(snapshot, relation); ok {
		relation_block_visit(block, bindings, visit, user)
	}
}

// Looks up the extensional tuple for an exact projected key.
snapshot_tuple_for_key :: proc(
	snapshot: ^Snapshot,
	relation: Relation_ID,
	positions: []u16,
	key_values: []v.Value,
) -> (
	v.Tuple,
	bool,
) {
	if block, ok := snapshot_relation_block(snapshot, relation); ok {
		return relation_block_tuple_for_key(block, positions, key_values)
	}
	return nil, false
}

// Replaces a relation block in a snapshot's block list, inserting in relation
// id order. The block list is reallocated from the snapshot allocator.
snapshot_set_block :: proc(snapshot: ^Snapshot, block: ^Relation_Block) {
	replaced := false
	for existing, i in snapshot.blocks {
		if existing.metadata.id == block.metadata.id {
			snapshot.blocks[i] = block
			replaced = true
			break
		}
	}
	if replaced {
		return
	}

	blocks := make([]^Relation_Block, len(snapshot.blocks) + 1, snapshot.allocator)
	write := 0
	inserted := false
	for existing in snapshot.blocks {
		if !inserted && existing.metadata.id > block.metadata.id {
			blocks[write] = block
			write += 1
			inserted = true
		}
		blocks[write] = existing
		write += 1
	}
	if !inserted {
		blocks[write] = block
	}
	snapshot.blocks = blocks
}

// Appends a relation to the catalog.
snapshot_add_relation :: proc(snapshot: ^Snapshot, metadata: Relation_Metadata) {
	catalog := make([]Relation_Metadata, len(snapshot.catalog) + 1, snapshot.allocator)
	copy(catalog, snapshot.catalog)
	catalog[len(snapshot.catalog)] = metadata
	snapshot.catalog = catalog
}

// Appends a rule definition to the snapshot.
snapshot_add_rule :: proc(snapshot: ^Snapshot, rule: Rule_Definition) {
	rules := make([]Rule_Definition, len(snapshot.rules) + 1, snapshot.allocator)
	copy(rules, snapshot.rules)
	rules[len(snapshot.rules)] = rule
	snapshot.rules = rules
}

// Returns active rules from a snapshot, allocated from `alloc`.
snapshot_active_rules :: proc(snapshot: ^Snapshot, alloc: mem.Allocator) -> []Rule {
	rules := make([]Rule, len(snapshot.rules), alloc)
	write := 0
	for definition in snapshot.rules {
		if definition.active {
			rules[write] = definition.rule
			write += 1
		}
	}
	return rules[:write]
}

// Allocates a derived relation row set into the snapshot allocator, sorting
// and deduplicating the rows.
snapshot_set_derived :: proc(
	snapshot: ^Snapshot,
	relation: Relation_ID,
	rows: []v.Tuple,
) {
	tuples := make([]v.Tuple, len(rows), snapshot.allocator)
	copy(tuples, rows)
	tuples = canonicalize_tuples(tuples)

	derived := snapshot.derived
	found := false
	for entry, i in derived {
		if entry.relation == relation {
			derived[i] = Derived_Relation{relation = relation, tuples = tuples}
			found = true
			break
		}
	}
	if !found {
		next := make([]Derived_Relation, len(derived) + 1, snapshot.allocator)
		copy(next, derived)
		next[len(derived)] = Derived_Relation{relation = relation, tuples = tuples}
		snapshot.derived = next
	}
}

@(private)
canonicalize_tuples :: proc(tuples: []v.Tuple) -> []v.Tuple {
	slice.sort_by(tuples, proc(a, b: v.Tuple) -> bool {
		return v.tuple_cmp(a, b) == .Less
	})
	write := 0
	for row in tuples {
		if write > 0 && v.tuple_cmp(tuples[write - 1], row) == .Equal {
			continue
		}
		tuples[write] = row
		write += 1
	}
	return tuples[:write]
}

// Converts an evaluation result into sorted relation row sets allocated from
// `alloc`. Tuples are deep-copied so the result does not reference evaluation
// scratch storage.
derived_relations_from :: proc(alloc: mem.Allocator, derived: ^Rule_Derived) -> []Derived_Relation {
	relations := make([]Derived_Relation, len(derived.relations), alloc)
	for relation, i in derived.relations {
		rows := make([]v.Tuple, len(derived.rows[i]), alloc)
		for row, j in derived.rows[i] {
			rows[j] = v.tuple_new(alloc, v.tuple_values(row))
		}
		relations[i] = Derived_Relation {
			relation = relation,
			tuples   = canonicalize_tuples(rows),
		}
	}
	return relations
}

// Computes all derived relations for a snapshot from its active rules and
// stores them on the snapshot. Evaluation runs in a short-lived arena; the
// surviving tuples are deep-copied into the snapshot arena.
snapshot_compute_derived :: proc(snapshot: ^Snapshot) {
	if len(snapshot.rules) == 0 {
		snapshot.derived = make([]Derived_Relation, 0, snapshot.allocator)
		return
	}

	arena := new(virtual.Arena, runtime.default_allocator())
	if err := virtual.arena_init_growing(arena); err != nil {
		panic("failed to initialize rule evaluation arena")
	}
	defer {
		virtual.arena_destroy(arena)
		free(arena, runtime.default_allocator())
	}
	alloc := virtual.arena_allocator(arena)

	derived, err := rules_evaluate(alloc, snapshot.rules, snapshot)
	if err != .None {
		snapshot.derived = make([]Derived_Relation, 0, snapshot.allocator)
		return
	}
	snapshot.derived = derived_relations_from(snapshot.allocator, &derived)
}
