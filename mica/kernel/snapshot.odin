// Snapshot-published world state.
//
// A snapshot is immutable after publication. All snapshot data - values,
// tuples, blocks, metadata, and derived rows - lives in the kernel's shared
// committed store, so a snapshot holds no arena of its own. Each snapshot
// retains its parent so values inherited along the commit chain stay alive.
// Snapshots are reference-counted; the last release frees the header only,
// because the committed store outlives every snapshot.
package kernel

import v "../var"
import "base:runtime"
import "core:mem"
import "core:mem/virtual"
import "core:slice"
import "core:sync"

// A derived relation's rows, computed from rules at snapshot creation.
Derived_Relation :: struct {
	relation: Relation_ID,
	tuples:   []v.Tuple,
}

// Immutable world state at a version.
//
// A snapshot owns an arena for its catalog/blocks/rules arrays and derived
// rows, plus one reference to every block in `blocks`. It does not own its
// parent: `parent` is a borrowed link for version ancestry only, because block
// reference counts keep shared data alive independently of the version chain.
Snapshot :: struct {
	version:   u64,
	parent:    ^Snapshot,
	refs:      i32,
	arena:     ^Frame_Arena,
	pool:      ^Arena_Pool,
	allocator: mem.Allocator,
	catalog:   []Relation_Metadata,
	blocks:    []^Relation_Block,
	buffers:   []^Buffer_Block,
	rules:     []Rule_Definition,
	derived:   []Derived_Relation,
}

// Creates an empty snapshot with arrays allocated from a pooled arena owned by
// the snapshot. `parent` is borrowed, not retained.
snapshot_create :: proc(kernel: ^Kernel, version: u64, parent: ^Snapshot) -> ^Snapshot {
	arena := arena_pool_take(kernel.arena_pool)
	snapshot := new(Snapshot, runtime.default_allocator())
	snapshot.version = version
	snapshot.refs = 1
	snapshot.parent = parent
	snapshot.arena = arena
	snapshot.pool = kernel.arena_pool
	snapshot.allocator = frame_arena_allocator(arena)
	// Callers that fork or add entries assign these arrays; leaving them nil
	// avoids four allocator round-trips per snapshot.
	snapshot.catalog = nil
	snapshot.blocks = nil
	snapshot.buffers = nil
	snapshot.rules = nil
	snapshot.derived = nil
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
	// Only the releaser that observed the last reference may free. Acq_Rel
	// pairs with earlier decrements so the freeing thread sees every write
	// made while other holders still had references; the other releasers must
	// not touch the snapshot after their decrement.
	if sync.atomic_sub_explicit(&snapshot.refs, 1, .Acq_Rel) != 1 {
		return
	}

	for block in snapshot.blocks {
		relation_block_release(block)
	}
	snapshot.blocks = nil
	for block in snapshot.buffers {
		buffer_block_release(block)
	}
	snapshot.buffers = nil
	if snapshot.arena != nil {
		arena_pool_return(snapshot.pool, snapshot.arena)
		snapshot.arena = nil
	}
	free(snapshot, runtime.default_allocator())
}

// Creates a child snapshot that inherits the parent catalog, blocks, and
// rules. The child takes its own reference to every inherited block.
snapshot_fork :: proc(kernel: ^Kernel, parent: ^Snapshot) -> ^Snapshot {
	snapshot := snapshot_create(kernel, parent.version + 1, parent)

	snapshot.catalog = make([]Relation_Metadata, len(parent.catalog), snapshot.allocator)
	copy(snapshot.catalog, parent.catalog)
	snapshot.blocks = make([]^Relation_Block, len(parent.blocks), snapshot.allocator)
	for block, index in parent.blocks {
		relation_block_retain(block)
		snapshot.blocks[index] = block
	}
	snapshot.buffers = make([]^Buffer_Block, len(parent.buffers), snapshot.allocator)
	for block, index in parent.buffers {
		buffer_block_retain(block)
		snapshot.buffers[index] = block
	}
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
snapshot_contains :: proc(snapshot: ^Snapshot, relation: Relation_ID, tuple: v.Tuple) -> bool {
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
			relation_block_release(existing)
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


// Converts an evaluation result into sorted relation row sets allocated from
// `alloc`: the canonical rows of each relation are deep-copied into one packed
// value array, so the result references no evaluation storage and `alloc` (a
// snapshot's frame arena, which never frees) holds only the rows. Sorting
// happens in a temporary region of `scratch` (a private arena when nil) that
// is rolled back after each relation, so its peak follows the largest
// relation.
derived_relations_from :: proc(
	alloc: mem.Allocator,
	derived: ^Rule_Derived,
	scratch_arena: ^virtual.Arena = nil,
) -> []Derived_Relation {
	scratch := scratch_arena
	own: virtual.Arena
	if scratch == nil {
		if virtual.arena_init_growing(&own) != nil {
			panic("failed to initialize derived copy scratch arena")
		}
		scratch = &own
	}
	defer if scratch == &own {
		virtual.arena_destroy(&own)
	}

	relations := make([]Derived_Relation, len(derived.relations), alloc)
	for entry, i in derived.relations {
		temp := virtual.arena_temp_begin(scratch)
		temp_alloc := virtual.arena_allocator(scratch)
		arity := entry.arity
		tuples: []v.Tuple
		if order, count, keyed := derived_canonical_order(entry, temp_alloc); keyed {
			packed := make([]v.Value, count * arity, alloc)
			tuples = make([]v.Tuple, count, alloc)
			for r in 0 ..< count {
				row := int(order[r])
				values := packed[r * arity:(r + 1) * arity]
				for c in 0 ..< arity {
					values[c] = v.value_deep_copy(alloc, entry.columns[c][row])
				}
				tuples[r] = v.Tuple(values)
			}
		} else {
			tuples = derived_canonical_rows_cmp(entry, alloc, temp_alloc)
		}
		virtual.arena_temp_end(temp)
		relations[i] = Derived_Relation {
			relation = entry.relation,
			tuples   = tuples,
		}
	}
	return relations
}

@(private)
Derived_Key_Order :: struct {
	keys:  []u64,
	arity: int,
}

// The canonical order of a relation's rows, computed from its columns: one
// sort key per cell (`value_sort_key`), rows ordered by their keys and runs of
// equal keys reduced to their first row, as `canonicalize_tuples` does. Returns
// ok=false when a cell has no key (heap values), in which case the caller sorts
// with `tuple_cmp`. The returned order is allocated from `alloc`.
derived_canonical_order :: proc(
	entry: ^Derived_Columns,
	alloc: mem.Allocator,
) -> (
	order: []u32,
	count: int,
	ok: bool,
) {
	rows := len(entry.hashes)
	arity := entry.arity
	keys := make([]u64, rows * arity, alloc)
	for c in 0 ..< arity {
		for value, r in entry.columns[c][:rows] {
			key, keyed := v.value_sort_key(value)
			if !keyed {
				delete(keys, alloc)
				return nil, 0, false
			}
			keys[r * arity + c] = key
		}
	}
	order = make([]u32, rows, alloc)
	for r in 0 ..< rows {
		order[r] = u32(r)
	}
	by := Derived_Key_Order{keys = keys, arity = arity}
	slice.sort_by_with_data(order, derived_key_less, &by)

	// Keep the first row of each run of equal keys (compacting in place:
	// `count` never passes the current position).
	for index in order {
		if count > 0 {
			previous := order[count - 1]
			equal := true
			for c in 0 ..< arity {
				if keys[int(index) * arity + c] != keys[int(previous) * arity + c] {
					equal = false
					break
				}
			}
			if equal {
				continue
			}
		}
		order[count] = index
		count += 1
	}
	delete(keys, alloc)
	return order, count, true
}

@(private)
derived_key_less :: proc(a, b: u32, user: rawptr) -> bool {
	by := (^Derived_Key_Order)(user)
	base_a := int(a) * by.arity
	base_b := int(b) * by.arity
	for c in 0 ..< by.arity {
		ka := by.keys[base_a + c]
		kb := by.keys[base_b + c]
		if ka != kb {
			return ka < kb
		}
	}
	return false
}

// Rows with heap values: gathered and canonicalized with `tuple_cmp` in
// `scratch`, then deep-copied packed into `alloc`.
@(private)
derived_canonical_rows_cmp :: proc(entry: ^Derived_Columns, alloc, scratch: mem.Allocator) -> []v.Tuple {
	count := len(entry.hashes)
	arity := entry.arity
	gathered := make([]v.Value, count * arity, scratch)
	rows := make([]v.Tuple, count, scratch)
	for row in 0 ..< count {
		values := gathered[row * arity:(row + 1) * arity]
		for c in 0 ..< arity {
			values[c] = entry.columns[c][row]
		}
		rows[row] = v.Tuple(values)
	}
	canonical := v.canonicalize_tuples(rows, scratch)
	packed := make([]v.Value, len(canonical) * arity, alloc)
	tuples := make([]v.Tuple, len(canonical), alloc)
	for row, r in canonical {
		values := packed[r * arity:(r + 1) * arity]
		for value, c in v.tuple_values(row) {
			values[c] = v.value_deep_copy(alloc, value)
		}
		tuples[r] = v.Tuple(values)
	}
	return tuples
}

// Computes all derived relations for a snapshot from its active rules and
// stores them on the snapshot. Evaluation runs in a short-lived arena; the
// surviving tuples are deep-copied into the snapshot arena.
snapshot_compute_derived :: proc(snapshot: ^Snapshot, kernel: ^Kernel = nil) {
	if len(snapshot.rules) == 0 {
		snapshot.derived = nil
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

	if kernel != nil {
		sync.atomic_add_explicit(&kernel.derivations, 1, .Release)
	}
	// Result rows on the heap: a growing relation frees each outgrown column,
	// where the evaluation arena would keep every copy until the end.
	derived, err := rules_evaluate(alloc, snapshot.rules, snapshot, kernel, runtime.heap_allocator())
	if err != .None {
		snapshot.derived = nil
		return
	}
	snapshot.derived = derived_relations_from(snapshot.allocator, &derived, arena)
	rules_derived_destroy(&derived)
}

// Returns the buffer block for a relation, if any.
snapshot_buffer :: proc(snapshot: ^Snapshot, relation: Relation_ID) -> (^Buffer_Block, bool) {
	for block in snapshot.buffers {
		if block.relation == relation {
			return block, true
		}
	}
	return nil, false
}

// Replaces a buffer block in a snapshot's buffer list, inserting in relation id
// order. Mirrors `snapshot_set_block`.
snapshot_set_buffer :: proc(snapshot: ^Snapshot, block: ^Buffer_Block) {
	replaced := false
	for existing, i in snapshot.buffers {
		if existing.relation == block.relation {
			snapshot.buffers[i] = block
			buffer_block_release(existing)
			replaced = true
			break
		}
	}
	if replaced {
		return
	}

	buffers := make([]^Buffer_Block, len(snapshot.buffers) + 1, snapshot.allocator)
	write := 0
	inserted := false
	for existing in snapshot.buffers {
		if !inserted && existing.relation > block.relation {
			buffers[write] = block
			write += 1
			inserted = true
		}
		buffers[write] = existing
		write += 1
	}
	if !inserted {
		buffers[write] = block
	}
	snapshot.buffers = buffers
}
