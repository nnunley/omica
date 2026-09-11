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
	current:      ^Snapshot,
	catalog_lock: sync.Mutex,

	// One striped lock per relation id. Commits hold the stripes for the
	// relations they write, so candidates for the same relation are prepared
	// in order while writes to different relations proceed in parallel.
	relation_locks: [RELATION_LOCK_STRIPES]sync.Mutex,

	// Group publication. Prepared candidates queue here; the first task
	// thread to enqueue drains the batch and publishes every candidate in one
	// snapshot. This stops independent tasks from invalidating each other's
	// candidates, which otherwise causes retry amplification under load.
	commit_queue_lock: sync.Mutex,
	commit_queue_cond: sync.Cond,
	pending_commits:   [dynamic]^Commit_Entry,
	committer_active:  bool,

	// Reader-count reclamation (RCU-style). A reader increments `readers`
	// around load-and-retain; a publisher swaps `current`, moves the previous
	// snapshot to `retired`, and frees retired snapshots only while no reader
	// is active. This closes the load-then-retain race without a lock on the
	// read path.
	readers:     [READER_SLOTS]Reader_Slot,
	retire_lock: sync.Mutex,
	retired:     [dynamic]^Snapshot,
	// Number of snapshots awaiting reclamation. Zero lets reader exits skip
	// the retire lock entirely.
	retire_pending: i32,

	// Relation metadata and rule definitions live here for the life of the
	// kernel; blocks and snapshots reference their slices.
	world:           ^virtual.Arena,
	world_allocator: mem.Allocator,

	// Arenas for transaction staging, snapshot arrays, derived rows, and
	// block payloads. Arenas are reset on release and reused, so the hot path
	// performs no arena creation at all.
	arena_pool: ^Arena_Pool,

	// Bearer capabilities minted for this world. Ephemeral; not persisted.
	capabilities: Capability_Store,

	// Bounded window of committed fact changes for subscriptions.
	changes: Change_Feed,
}

// A pool of reset-able virtual arenas shared by transactions, snapshots, and
// relation blocks. Sharded by thread so concurrent take/return paths do not
// convoy on a single lock.
ARENA_POOL_SHARDS :: 16

// Padded reader counters. Each thread touches its own slot, so snapshot
// acquisition under parallel load does not ping-pong one cache line.
READER_SLOTS :: 16

// Number of relation commit stripes.
RELATION_LOCK_STRIPES :: 64

@(private)
Reader_Slot :: struct {
	count:  i32,
	// Hazard pointer for borrowed (non-retained) snapshot reads.
	hazard: ^Snapshot,
	_pad:   [14]i32,
}

@(private)
global_reader_slot_counter: u32

@(thread_local)
reader_slot_hint: u32

@(thread_local)
reader_slot_ready: bool

@(private)
reader_slot_index :: proc() -> u32 {
	if !reader_slot_ready {
		assigned := sync.atomic_add(&global_reader_slot_counter, 1)
		reader_slot_hint = assigned % READER_SLOTS
		reader_slot_ready = true
	}
	return reader_slot_hint
}

// Reports whether any hazard slot pins `snapshot`.
@(private)
kernel_snapshot_hazarded :: proc(kernel: ^Kernel, snapshot: ^Snapshot) -> bool {
	for &slot in kernel.readers {
		if sync.atomic_load(&slot.hazard) == snapshot {
			return true
		}
	}
	return false
}

// Reports whether any reader is inside a load-and-retain window.
@(private)
kernel_readers_idle :: proc(kernel: ^Kernel) -> bool {
	for &slot in kernel.readers {
		if sync.atomic_load(&slot.count) != 0 {
			return false
		}
	}
	return true
}

Arena_Pool_Shard :: struct {
	lock:   sync.Mutex,
	arenas: [dynamic]^Frame_Arena,
}

Arena_Pool :: struct {
	shards: [ARENA_POOL_SHARDS]Arena_Pool_Shard,
	// Arenas currently checked out. Diagnostics only.
	live_arenas: i32,
}

// Each thread is assigned a stable shard once, avoiding a `gettid` syscall on
// every take and return.
@(private)
global_arena_shard_counter: u32

@(thread_local)
arena_pool_hint: u32

@(thread_local)
arena_pool_hint_ready: bool

@(private)
arena_pool_shard_index :: proc() -> u32 {
	if !arena_pool_hint_ready {
		assigned := sync.atomic_add(&global_arena_shard_counter, 1)
		arena_pool_hint = assigned % ARENA_POOL_SHARDS
		arena_pool_hint_ready = true
	}
	return arena_pool_hint
}

@(private)
arena_pool_shard :: proc(pool: ^Arena_Pool) -> ^Arena_Pool_Shard {
	return &pool.shards[arena_pool_shard_index()]
}

arena_pool_init :: proc(pool: ^Arena_Pool) {
	for index in 0 ..< ARENA_POOL_SHARDS {
		pool.shards[index].arenas = make([dynamic]^Frame_Arena)
	}
}

arena_pool_take :: proc(pool: ^Arena_Pool) -> ^Frame_Arena {
	hint := arena_pool_shard_index()

	// Prefer the local shard, then steal from siblings. Arenas are created and
	// released by different committing threads, so without stealing the hot
	// path falls back to a fresh arena (and mmap) on nearly every commit.
	for offset in 0 ..< ARENA_POOL_SHARDS {
		shard := &pool.shards[(hint + u32(offset)) % ARENA_POOL_SHARDS]
		sync.mutex_lock(&shard.lock)
		if len(shard.arenas) > 0 {
			arena := pop(&shard.arenas)
			sync.mutex_unlock(&shard.lock)
			sync.atomic_add(&pool.live_arenas, 1)
			return arena
		}
		sync.mutex_unlock(&shard.lock)
	}

	arena := new(Frame_Arena, runtime.default_allocator())
	frame_arena_init(arena)
	sync.atomic_add(&pool.live_arenas, 1)
	return arena
}

// Returns the number of arenas currently checked out of the pool.
arena_pool_live_count :: proc(pool: ^Arena_Pool) -> int {
	return int(sync.atomic_load(&pool.live_arenas))
}

// Returns the number of idle arenas held by the pool.
arena_pool_idle_count :: proc(pool: ^Arena_Pool) -> int {
	total := 0
	for index in 0 ..< ARENA_POOL_SHARDS {
		shard := &pool.shards[index]
		sync.mutex_lock(&shard.lock)
		total += len(shard.arenas)
		sync.mutex_unlock(&shard.lock)
	}
	return total
}

arena_pool_return :: proc(pool: ^Arena_Pool, arena: ^Frame_Arena) {
	if arena == nil {
		return
	}
	frame_arena_reset(arena)
	sync.atomic_sub(&pool.live_arenas, 1)

	// Return to the local shard; a thread's arenas tend to be reused by it.
	shard := arena_pool_shard(pool)
	sync.mutex_lock(&shard.lock)
	append(&shard.arenas, arena)
	sync.mutex_unlock(&shard.lock)
}

arena_pool_destroy :: proc(pool: ^Arena_Pool) {
	for index in 0 ..< ARENA_POOL_SHARDS {
		shard := &pool.shards[index]
		for arena in shard.arenas {
			frame_arena_destroy(arena)
			free(arena, runtime.default_allocator())
		}
		delete(shard.arenas)
	}
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
	kernel.retired = make([dynamic]^Snapshot)
	kernel.pending_commits = make([dynamic]^Commit_Entry)
	capability_store_init(&kernel.capabilities)
	changes_init(&kernel.changes)
	kernel.current = snapshot_create(kernel, 0, nil)
}

// Releases the published snapshot, the committed store, and the staging pool.
// The caller must guarantee no other thread uses the kernel.
kernel_destroy :: proc(kernel: ^Kernel) {
	current := sync.atomic_load(&kernel.current)
	sync.atomic_store(&kernel.current, nil)
	snapshot_release(current)

	for retired in kernel.retired {
		snapshot_release(retired)
	}
	delete(kernel.retired)
	delete(kernel.pending_commits)
	capability_store_destroy(&kernel.capabilities)
	changes_destroy(&kernel.changes)

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
kernel_take_arena :: proc(kernel: ^Kernel) -> ^Frame_Arena {
	return arena_pool_take(kernel.arena_pool)
}

// Resets `arena` and returns it to the pool for reuse.
kernel_return_arena :: proc(kernel: ^Kernel, arena: ^Frame_Arena) {
	arena_pool_return(kernel.arena_pool, arena)
}

// Returns a retained reference to the current snapshot. The caller must
// release it. Lock-free: the reader is announced in `readers` while it loads
// and retains, so a publisher cannot free the snapshot underneath it.
kernel_snapshot :: proc(kernel: ^Kernel) -> ^Snapshot {
	slot := &kernel.readers[reader_slot_index()]
	sync.atomic_add_explicit(&slot.count, 1, .Acq_Rel)
	current := sync.atomic_load(&kernel.current)
	snapshot_retain(current)
	if sync.atomic_sub_explicit(&slot.count, 1, .Acq_Rel) == 1 &&
	   sync.atomic_load(&kernel.retire_pending) > 0 &&
	   kernel_readers_idle(kernel) {
		kernel_reclaim(kernel)
	}
	return current
}

// Borrows the current snapshot without retaining it. The caller must use it
// only until `kernel_hazard_clear`, and must not release it. Reclamation keeps
// a hazard-pinned snapshot alive.
kernel_snapshot_borrow :: proc(kernel: ^Kernel) -> ^Snapshot {
	slot := &kernel.readers[reader_slot_index()]
	for {
		current := sync.atomic_load(&kernel.current)
		sync.atomic_store_explicit(&slot.hazard, current, .Release)
		// If a publisher swapped between the load and the hazard store, pin
		// the newer snapshot instead.
		if sync.atomic_load(&kernel.current) == current {
			return current
		}
	}
}

// Clears the calling thread's hazard pointer.
kernel_hazard_clear :: proc(kernel: ^Kernel) {
	slot := &kernel.readers[reader_slot_index()]
	sync.atomic_store_explicit(&slot.hazard, nil, .Release)
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

// Publishes `next` if `expected` is still the published snapshot. Each task
// commits on its own thread, so this is a direct compare-exchange: on failure
// the caller holds the winner, rebases its prepared blocks in place, and tries
// again. On success the kernel holds a reference to `next` and the previous
// snapshot is returned for the caller to retire.
@(private)
kernel_try_publish :: proc(
	kernel: ^Kernel,
	expected, next: ^Snapshot,
) -> (
	previous: ^Snapshot,
	published: bool,
) {
	snapshot_retain(next)
	_, swapped := sync.atomic_compare_exchange_strong_explicit(
		&kernel.current,
		expected,
		next,
		.Acq_Rel,
		.Acquire,
	)
	if swapped {
		changes_note_version(&kernel.changes, next.version)
		return expected, true
	}
	snapshot_release(next)
	return nil, false
}

// Maximum rebase attempts for a solo publication before reporting a conflict.
PUBLISH_ATTEMPT_LIMIT :: 64

// A prepared commit waiting for a group publication.
Commit_Entry :: struct {
	transaction: ^Transaction,
	// The snapshot the candidate was prepared against, retained by the owner.
	base:      ^Snapshot,
	candidate: ^Snapshot,
	published: ^Snapshot,
	done:      bool,
}

// Adds a prepared candidate to the commit queue. Returns true when the caller
// should drain the queue.
@(private)
kernel_commit_enqueue :: proc(kernel: ^Kernel, entry: ^Commit_Entry) -> bool {
	sync.mutex_lock(&kernel.commit_queue_lock)
	append(&kernel.pending_commits, entry)
	become_committer := !kernel.committer_active
	if become_committer {
		kernel.committer_active = true
	}
	sync.mutex_unlock(&kernel.commit_queue_lock)
	return become_committer
}

// Blocks until `entry` has been published.
@(private)
kernel_commit_wait :: proc(kernel: ^Kernel, entry: ^Commit_Entry) {
	sync.mutex_lock(&kernel.commit_queue_lock)
	for !entry.done {
		sync.cond_wait(&kernel.commit_queue_cond, &kernel.commit_queue_lock)
	}
	sync.mutex_unlock(&kernel.commit_queue_lock)
}

// Drains and publishes commit batches until the queue is empty. Any task
// thread can be the committer; the role is not a dedicated thread.
@(private)
kernel_committer_drain :: proc(kernel: ^Kernel) {
	for {
		sync.mutex_lock(&kernel.commit_queue_lock)
		if len(kernel.pending_commits) == 0 {
			kernel.committer_active = false
			sync.mutex_unlock(&kernel.commit_queue_lock)
			return
		}
		batch := make([dynamic]^Commit_Entry, len(kernel.pending_commits))
		copy(batch[:], kernel.pending_commits[:])
		clear(&kernel.pending_commits)
		sync.mutex_unlock(&kernel.commit_queue_lock)

		kernel_publish_group(kernel, batch[:])

		sync.mutex_lock(&kernel.commit_queue_lock)
		for entry in batch {
			entry.done = true
		}
		sync.cond_broadcast(&kernel.commit_queue_cond)
		sync.mutex_unlock(&kernel.commit_queue_lock)
		delete(batch)
	}
}

// Merges every candidate's prepared blocks into one snapshot and publishes it
// once. Candidates are stripe-protected and write disjoint relations, so the
// merge adopts prepared blocks; only the surrounding snapshot arrays are
// rebuilt. A lone candidate publishes directly.
@(private)
kernel_publish_group :: proc(kernel: ^Kernel, batch: []^Commit_Entry) {
	if len(batch) == 1 {
		entry := batch[0]
		for _ in 0 ..< PUBLISH_ATTEMPT_LIMIT {
			previous, published := kernel_try_publish(kernel, entry.base, entry.candidate)
			if published {
				kernel_retire(kernel, previous)
				snapshot_release(entry.base)
				entry.base = nil
				entry.published = entry.candidate
				changes_record_writes(
					&kernel.changes,
					entry.candidate.version,
					entry.transaction.writes[:],
				)
				return
			}
			winner := kernel_snapshot(kernel)
			if transaction_rebase_in_place(
				kernel,
				entry.transaction,
				entry.candidate,
				winner,
			) {
				snapshot_release(entry.base)
				entry.base = winner
				continue
			}
			// The winner's shape changed (a catalog operation). Adopt it as
			// the new base and rebuild the candidate from it.
			snapshot_release(entry.candidate)
			snapshot_release(entry.base)
			entry.base = winner
			entry.candidate = transaction_build_candidate(
				kernel,
				entry.transaction,
				entry.base,
			)
		}
		// Give up rather than spin; the owner retries the transaction.
		snapshot_release(entry.candidate)
		snapshot_release(entry.base)
		entry.candidate = nil
		entry.base = nil
		entry.published = nil
		return
	}

	for {
		base := kernel_snapshot(kernel)
		merged := snapshot_fork(kernel, base)
		for entry in batch {
			for block in entry.candidate.blocks {
				relation_block_retain(block)
				snapshot_set_block(merged, block)
			}
		}
		snapshot_compute_derived(merged)

		previous, published := kernel_try_publish(kernel, base, merged)
		if published {
			kernel_retire(kernel, previous)
			merged_writes: [dynamic]Relation_Writes
			defer delete(merged_writes)
			for entry in batch {
				append(&merged_writes, ..entry.transaction.writes[:])
				snapshot_retain(merged)
				entry.published = merged
				snapshot_release(entry.candidate)
				snapshot_release(entry.base)
				entry.base = nil
			}
			changes_record_writes(
				&kernel.changes,
				merged.version,
				merged_writes[:],
			)
			snapshot_release(base)
			return
		}
		snapshot_release(merged)
		snapshot_release(base)
	}
}

// Moves `snapshot` to the retired list and reclaims retired snapshots when no
// reader is in its load-and-retain window.
@(private)
kernel_retire :: proc(kernel: ^Kernel, snapshot: ^Snapshot) {
	if snapshot == nil {
		return
	}
	sync.mutex_lock(&kernel.retire_lock)
	append(&kernel.retired, snapshot)
	sync.atomic_add(&kernel.retire_pending, 1)
	sync.mutex_unlock(&kernel.retire_lock)

	if kernel_readers_idle(kernel) {
		kernel_reclaim(kernel)
	}
}

// Releases every retired snapshot when no reader is active. Safe to call from
// any thread; the final reader out of its window calls it.
@(private)
kernel_reclaim :: proc(kernel: ^Kernel) {
	sync.mutex_lock(&kernel.retire_lock)
	defer sync.mutex_unlock(&kernel.retire_lock)

	// A reader may have entered while we waited for the lock.
	if !kernel_readers_idle(kernel) {
		return
	}
	write := 0
	released := 0
	for retired in kernel.retired {
		if kernel_snapshot_hazarded(kernel, retired) {
			kernel.retired[write] = retired
			write += 1
			continue
		}
		snapshot_release(retired)
		released += 1
	}
	resize(&kernel.retired, write)
	sync.atomic_sub(&kernel.retire_pending, i32(released))
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
	sync.mutex_lock(&kernel.catalog_lock)
	defer sync.mutex_unlock(&kernel.catalog_lock)

	for {
		current := kernel_snapshot(kernel)
		if _, exists := snapshot_relation_metadata_named(current, metadata.name); exists {
			snapshot_release(current)
			return nil, .Duplicate_Relation_Name
		}
		if snapshot_has_relation(current, metadata.id) {
			snapshot_release(current)
			return nil, .Invalid_Metadata
		}
		if err := validate_relation_metadata(metadata); err != .None {
			snapshot_release(current)
			return nil, err
		}

		next := snapshot_fork(kernel, current)
		snapshot_add_relation(next, metadata_clone(kernel.world_allocator, metadata))
		snapshot_compute_derived(next)
		previous, published := kernel_try_publish(kernel, current, next)
		if published {
			kernel_retire(kernel, previous)
			snapshot_release(current)
			return next, .None
		}
		snapshot_release(next)
		snapshot_release(current)
	}
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
	sync.mutex_lock(&kernel.catalog_lock)
	defer sync.mutex_unlock(&kernel.catalog_lock)

	scratch := new(virtual.Arena)
	if err := virtual.arena_init_growing(scratch); err != nil {
		panic("failed to initialize rule validation arena")
	}
	defer {
		virtual.arena_destroy(scratch)
		free(scratch)
	}
	scratch_alloc := virtual.arena_allocator(scratch)

	for {
		current := kernel_snapshot(kernel)
		if err := rule_validate_arity(rule, current); err != .None {
			snapshot_release(current)
			return nil, err
		}
		if err := rule_validate_safety(rule, scratch_alloc); err != .None {
			snapshot_release(current)
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
			snapshot_release(current)
			return nil, .Unstratified_Negation
		}

		snapshot_compute_derived(next)
		previous, published := kernel_try_publish(kernel, current, next)
		if published {
			kernel_retire(kernel, previous)
			snapshot_release(current)
			return next, .None
		}
		snapshot_release(next)
		snapshot_release(current)
	}
}

// Sets a rule's active flag and publishes a new snapshot with recomputed
// derived relations. The returned snapshot is caller-owned.
kernel_set_rule_active :: proc(
	kernel: ^Kernel,
	rule_id: v.Identity,
	active: bool,
) -> (
	^Snapshot,
	Kernel_Error,
) {
	sync.mutex_lock(&kernel.catalog_lock)
	defer sync.mutex_unlock(&kernel.catalog_lock)

	for {
		current := kernel_snapshot(kernel)
		found := false
		for definition in current.rules {
			if definition.id == rule_id {
				if definition.active == active {
					return current, .None
				}
				found = true
				break
			}
		}
		if !found {
			snapshot_release(current)
			return nil, .No_Such_Rule
		}

		next := snapshot_fork(kernel, current)
		for &definition in next.rules {
			if definition.id == rule_id {
				definition.active = active
			}
		}
		snapshot_compute_derived(next)
		previous, published := kernel_try_publish(kernel, current, next)
		if published {
			kernel_retire(kernel, previous)
			snapshot_release(current)
			return next, .None
		}
		snapshot_release(next)
		snapshot_release(current)
	}
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
	return kernel_set_rule_active(kernel, rule_id, false)
}

// Activates a rule and publishes a new snapshot. The returned snapshot is
// caller-owned.
kernel_enable_rule :: proc(
	kernel: ^Kernel,
	rule_id: v.Identity,
) -> (
	^Snapshot,
	Kernel_Error,
) {
	return kernel_set_rule_active(kernel, rule_id, true)
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
