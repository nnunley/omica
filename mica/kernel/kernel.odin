// Kernel entry point: published world state and catalog changes.
//
// The kernel owns the current snapshot. Relation creation, rule installation,
// and rule disabling publish a new snapshot immediately. Ordinary fact changes
// go through transactions obtained from `kernel_begin`.
package kernel

import "base:runtime"
import "core:mem"
import "core:mem/virtual"
import "core:sync"
import v "../var"

// Published world state.
//
// `current` is published atomically. Readers load and retain the snapshot with
// no lock; this is safe because every snapshot retains its parent, so a
// snapshot loaded just before a concurrent publish stays alive through its
// descendant chain. Writers serialise validate-fork-publish on `commit_lock`,
// matching Rust mica's commit mutex. Loads are lock-free, so a long commit
// never blocks transaction begins or scans.
Kernel :: struct {
	current:     ^Snapshot,
	commit_lock: sync.Mutex,
	// Guards the `current` pointer swap and snapshot load-and-retain. Held
	// only for those operations, never for a whole commit, so readers never
	// wait on commit work. This closes the load-then-retain race that letting
	// publishers free unreferenced snapshots would otherwise open.
	snapshot_lock: sync.Mutex,

	// Relation metadata and rule definitions live here for the life of the
	// kernel; blocks and snapshots reference their slices.
	world:           ^virtual.Arena,
	world_allocator: mem.Allocator,

	// Arenas for transaction staging, snapshot arrays, derived rows, and
	// block payloads. Arenas are reset on release and reused, so the hot path
	// performs no arena creation at all.
	arena_pool: ^Arena_Pool,
}

// A pool of reset-able virtual arenas shared by transactions, snapshots, and
// relation blocks. Thread-safe.
Arena_Pool :: struct {
	lock:   sync.Mutex,
	arenas: [dynamic]^virtual.Arena,
}

arena_pool_init :: proc(pool: ^Arena_Pool) {
	pool.arenas = make([dynamic]^virtual.Arena)
}

arena_pool_take :: proc(pool: ^Arena_Pool) -> ^virtual.Arena {
	sync.mutex_lock(&pool.lock)
	if len(pool.arenas) > 0 {
		arena := pop(&pool.arenas)
		sync.mutex_unlock(&pool.lock)
		return arena
	}
	sync.mutex_unlock(&pool.lock)

	arena := new(virtual.Arena, runtime.default_allocator())
	if err := virtual.arena_init_growing(arena); err != nil {
		panic("failed to initialize a pooled arena")
	}
	return arena
}

arena_pool_return :: proc(pool: ^Arena_Pool, arena: ^virtual.Arena) {
	if arena == nil {
		return
	}
	virtual.arena_free_all(arena)
	sync.mutex_lock(&pool.lock)
	append(&pool.arenas, arena)
	sync.mutex_unlock(&pool.lock)
}

arena_pool_destroy :: proc(pool: ^Arena_Pool) {
	for arena in pool.arenas {
		virtual.arena_destroy(arena)
		free(arena, runtime.default_allocator())
	}
	delete(pool.arenas)
}

// Creates a kernel with an empty snapshot and an empty committed store.
kernel_init :: proc(kernel: ^Kernel) {
	kernel.world = new(virtual.Arena, runtime.default_allocator())
	if err := virtual.arena_init_growing(kernel.world); err != nil {
		panic("failed to initialize the committed store arena")
	}
	kernel.world_allocator = virtual.arena_allocator(kernel.world)
	kernel.arena_pool = new(Arena_Pool, runtime.default_allocator())
	arena_pool_init(kernel.arena_pool)
	kernel.current = snapshot_create(kernel, 0, nil)
}

// Releases the published snapshot, the committed store, and the staging pool.
// The caller must guarantee no other thread uses the kernel.
kernel_destroy :: proc(kernel: ^Kernel) {
	sync.mutex_lock(&kernel.snapshot_lock)
	current := sync.atomic_load(&kernel.current)
	sync.atomic_store(&kernel.current, nil)
	sync.mutex_unlock(&kernel.snapshot_lock)
	snapshot_release(current)

	if kernel.arena_pool != nil {
		arena_pool_destroy(kernel.arena_pool)
		free(kernel.arena_pool, runtime.default_allocator())
		kernel.arena_pool = nil
	}

	if kernel.world != nil {
		virtual.arena_destroy(kernel.world)
		free(kernel.world, runtime.default_allocator())
		kernel.world = nil
	}
}

// Returns a reset staging arena, creating one on demand.
kernel_take_arena :: proc(kernel: ^Kernel) -> ^virtual.Arena {
	return arena_pool_take(kernel.arena_pool)
}

// Resets `arena` and returns it to the pool for reuse.
kernel_return_arena :: proc(kernel: ^Kernel, arena: ^virtual.Arena) {
	arena_pool_return(kernel.arena_pool, arena)
}

// Returns a retained reference to the current snapshot. The caller must
// release it.
kernel_snapshot :: proc(kernel: ^Kernel) -> ^Snapshot {
	sync.mutex_lock(&kernel.snapshot_lock)
	current := sync.atomic_load(&kernel.current)
	snapshot_retain(current)
	sync.mutex_unlock(&kernel.snapshot_lock)
	return current
}

// Begins a transaction over the current snapshot.
kernel_begin :: proc(kernel: ^Kernel) -> Transaction {
	return transaction_begin(kernel)
}

// Returns the next unused relation id.
kernel_next_relation_id :: proc(kernel: ^Kernel) -> Relation_ID {
	current := kernel_snapshot(kernel)
	defer snapshot_release(current)

	next := u32(1)
	for metadata in current.catalog {
		if u32(metadata.id) >= next {
			next = u32(metadata.id) + 1
		}
	}
	return Relation_ID(next)
}

// Publishes `next` while the caller holds the exclusive kernel lock.
@(private)
kernel_publish_locked :: proc(kernel: ^Kernel, next: ^Snapshot) {
	snapshot_retain(next)

	// Swap under the snapshot lock so a concurrent load-and-retain either sees
	// `next` or holds a reference to `previous` before it is released below.
	sync.mutex_lock(&kernel.snapshot_lock)
	previous := sync.atomic_load(&kernel.current)
	sync.atomic_store(&kernel.current, next)
	sync.mutex_unlock(&kernel.snapshot_lock)

	snapshot_release(previous)
}

// Creates a relation and publishes a new snapshot. The returned snapshot is
// caller-owned.
kernel_create_relation :: proc(
	kernel: ^Kernel,
	metadata: Relation_Metadata,
) -> (
	^Snapshot,
	Kernel_Error,
) {
	sync.mutex_lock(&kernel.commit_lock)
	defer sync.mutex_unlock(&kernel.commit_lock)

	current := sync.atomic_load(&kernel.current)
	if _, exists := snapshot_relation_metadata_named(current, metadata.name); exists {
		return nil, .Duplicate_Relation_Name
	}
	if snapshot_has_relation(current, metadata.id) {
		return nil, .Invalid_Metadata
	}
	if err := validate_relation_metadata(metadata); err != .None {
		return nil, err
	}

	next := snapshot_fork(kernel, current)
	snapshot_add_relation(next, metadata_clone(kernel.world_allocator, metadata))
	snapshot_compute_derived(next)
	kernel_publish_locked(kernel, next)
	return next, .None
}

// Installs a rule and publishes a new snapshot. The returned snapshot is
// caller-owned.
kernel_install_rule :: proc(
	kernel: ^Kernel,
	id: v.Identity,
	rule: Rule,
	source: string,
) -> (
	^Snapshot,
	Kernel_Error,
) {
	sync.mutex_lock(&kernel.commit_lock)
	defer sync.mutex_unlock(&kernel.commit_lock)

	current := sync.atomic_load(&kernel.current)
	if err := rule_validate_arity(rule, current); err != .None {
		return nil, err
	}

	scratch := new(virtual.Arena)
	if err := virtual.arena_init_growing(scratch); err != nil {
		panic("failed to initialize rule validation arena")
	}
	defer {
		virtual.arena_destroy(scratch)
		free(scratch)
	}
	scratch_alloc := virtual.arena_allocator(scratch)

	if err := rule_validate_safety(rule, scratch_alloc); err != .None {
		return nil, err
	}

	next := snapshot_fork(kernel, current)
	snapshot_add_rule(
		next,
		rule_definition_clone(kernel.world_allocator, rule_definition(id, rule, source)),
	)

	active := snapshot_active_rules(next, scratch_alloc)
	if _, ok := rules_stratify(active, scratch_alloc); !ok {
		snapshot_release(next)
		return nil, .Unstratified_Negation
	}

	snapshot_compute_derived(next)
	kernel_publish_locked(kernel, next)
	return next, .None
}

// Deactivates a rule and publishes a new snapshot. The returned snapshot is
// caller-owned.
kernel_disable_rule :: proc(
	kernel: ^Kernel,
	rule_id: v.Identity,
) -> (
	^Snapshot,
	Kernel_Error,
) {
	sync.mutex_lock(&kernel.commit_lock)
	defer sync.mutex_unlock(&kernel.commit_lock)

	current := sync.atomic_load(&kernel.current)
	found := false
	for definition in current.rules {
		if definition.id == rule_id {
			found = true
			break
		}
	}
	if !found {
		return nil, .No_Such_Rule
	}

	next := snapshot_fork(kernel, current)
	for &definition in next.rules {
		if definition.id == rule_id {
			definition.active = false
		}
	}
	snapshot_compute_derived(next)
	kernel_publish_locked(kernel, next)
	return next, .None
}

// Visits visible tuples of a relation in the current snapshot, including
// derived facts.
kernel_visit :: proc(
	kernel: ^Kernel,
	relation: Relation_ID,
	bindings: []v.Binding,
	visit: proc(user: rawptr, row: v.Tuple) -> bool,
	user: rawptr,
) -> bool {
	current := kernel_snapshot(kernel)
	defer snapshot_release(current)

	source := Relation_Source{snapshot = current, use_stored_derived = true}
	return relation_source_visit(&source, relation, bindings, visit, user)
}

// Appends visible tuples of a relation in the current snapshot, including
// derived facts.
kernel_scan_into :: proc(
	kernel: ^Kernel,
	relation: Relation_ID,
	bindings: []v.Binding,
	out: ^[dynamic]v.Tuple,
) {
	current := kernel_snapshot(kernel)
	defer snapshot_release(current)

	relation_source_scan_into(
		&Relation_Source{snapshot = current, use_stored_derived = true},
		relation,
		bindings,
		out,
	)
}

// Reports whether a relation tuple is visible in the current snapshot.
kernel_contains :: proc(kernel: ^Kernel, relation: Relation_ID, tuple: v.Tuple) -> bool {
	current := kernel_snapshot(kernel)
	defer snapshot_release(current)
	return snapshot_contains(current, relation, tuple)
}
