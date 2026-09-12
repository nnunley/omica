// Durable store spine: budget admission, a version-ordered writer, and a
// memory-backed WAL. File-backed pages and checkpoints build on this.
package store

import "core:fmt"
import "core:mem"
import "core:mem/virtual"
import "core:os"
import "core:path/filepath"
import "core:sync"
import "core:thread"
import "core:time"
import k "../kernel"
import v "../var"

Store_Mode :: enum {
	// Records are kept in memory; no file is written.
	Memory,
	// Records are appended to a write-ahead log under `path`.
	File,
}

// Controls when WAL appends are flushed to stable storage.
Durability :: enum {
	// One fsync per writer drain batch. The default.
	Group,
	// Never fsync; the OS decides.
	None,
	// One fsync per record.
	Strict,
}

Store_Options :: struct {
	mode:         Store_Mode,
	// Store directory for `File` mode.
	path:         string,
	// Pin the store to a retained checkpoint version for point-in-time reads.
	// Zero selects the latest manifest.
	version:      u64,
	durability:   Durability,
	budget_bytes: i64,
	warn_after:   time.Duration,
	timeout:      time.Duration,
	// Write a checkpoint once this many WAL bytes accumulate. Zero uses
	// `DEFAULT_CHECKPOINT_BYTES`; negative disables automatic checkpoints.
	checkpoint_bytes: i64,
}

DEFAULT_STORE_BUDGET_BYTES :: i64(128) << 20
DEFAULT_STORE_WARN_AFTER :: 2 * time.Second
DEFAULT_STORE_TIMEOUT :: 10 * time.Second
// Bytes of WAL allowed before a checkpoint is written automatically.
DEFAULT_CHECKPOINT_BYTES :: i64(64) << 20

// One persisted fact change.
Wal_Write :: struct {
	relation: k.Relation_ID,
	assert:   bool,
	tuple:    v.Tuple,
}

// One persisted catalogue change.
Wal_Catalog :: struct {
	metadata: k.Relation_Metadata,
}

// A durable write-ahead record for one published version.
Wal_Record :: struct {
	version: u64,
	writes:  []Wal_Write,
	catalog: []Wal_Catalog,
}

@(private)
Queue_Entry :: struct {
	version: u64,
	ticket:  k.Persist_Ticket,
	bytes:   i64,
	writes:  []Wal_Write,
	catalog: []Wal_Catalog,
}

Store :: struct {
	mode:      Store_Mode,
	allocator: mem.Allocator,

	lock: sync.Mutex,
	cond: sync.Cond,

	budget_bytes:   i64,
	reserved_bytes: i64,
	tickets:        map[k.Persist_Ticket]i64,
	next_ticket:    k.Persist_Ticket,

	queue:   [dynamic]Queue_Entry,
	records: [dynamic]Wal_Record,
	known:   map[k.Relation_ID]bool,
	durable: u64,
	// Highest version known to be fully persisted or to have had nothing to
	// persist. Empty publishes advance it; `wait_durable` accepts either.
	covered: u64,

	warn_after: time.Duration,
	timeout:    time.Duration,

	// Owns deep copies of queued and recorded facts; reset on destroy.
	arena:          ^virtual.Arena,
	copy_allocator: mem.Allocator,

	// File mode state.
	path:       string,
	wal_path:   string,
	lock_path:  string,
	lock_acquired: bool,
	last_error: string,
	file:       ^os.File,
	wal_end:    i64,
	durability: Durability,
	syncs:      u64,
	failed:     bool,

	// Serializes WAL appends with checkpoint rotation.
	wal_lock: sync.Mutex,

	// The kernel this store persists, set by `store_attach`; automatic
	// checkpoints read it.
	kernel:        ^k.Kernel,
	checkpoint_bytes: i64,
	wal_bytes_since_checkpoint: i64,

	// Chunk shadow pages and checkpoint manifest.
	pages_generation:   u32,
	pinned_version:     u64,
	checkpoint_only:    bool,
	pages_file:         ^os.File,
	pages_end:          i64,
	next_page_id:       u32,
	persisted:          map[u64]u32,
	page_index:         map[u32]Page_Index,
	checkpoint_version: u64,
	manifest_relations: []Checkpoint_Relation,
	checkpoint_lock:    sync.Mutex,

	thread: ^thread.Thread,
	stop:   bool,
	closed: bool,
}

// Initialises a memory store. Zero options use the defaults.
store_init :: proc(store: ^Store, options := Store_Options{}) {
	store_setup(store, options)
	store_start_writer(store)
}

// Opens a store, recovering any existing write-ahead log. Returns false when
// the store cannot be opened; the store is left destroyed on failure.
store_open :: proc(store: ^Store, options: Store_Options) -> bool {
	store_setup(store, options)
	if options.mode == .File {
		if !store_lock_acquire(store, options.path) {
			store_release(store)
			return false
		}
		if !store_wal_open(store, options.path) {
			store_release(store)
			return false
		}
		manifest_name := "MANIFEST"
		if options.version != 0 {
			store.pinned_version = options.version
			store.checkpoint_only = true
			manifest_name = fmt.aprintf(
				"MANIFEST.%d",
				options.version,
				allocator = context.temp_allocator,
			)
		}
		manifest_path, manifest_error := filepath.join(
			[]string{store.path, manifest_name},
			context.temp_allocator,
		)
		if manifest_error != nil {
			store_release(store)
			return false
		}
		if !store_manifest_open(store, manifest_path) {
			store_release(store)
			return false
		}
		if !store_pages_open(store) {
			store_release(store)
			return false
		}
	}
	store_start_writer(store)
	return true
}

@(private)
store_start_writer :: proc(store: ^Store) {
	store.thread = thread.create_and_start_with_data(store, store_writer_proc)
	if store.thread == nil {
		panic("failed to start store writer thread")
	}
}

@(private)
store_setup :: proc(store: ^Store, options: Store_Options) {
	store.mode = options.mode
	store.durability = options.durability
	store.allocator = context.allocator
	store.budget_bytes = options.budget_bytes
	if store.budget_bytes <= 0 {
		store.budget_bytes = DEFAULT_STORE_BUDGET_BYTES
	}
	store.warn_after = options.warn_after
	if store.warn_after <= 0 {
		store.warn_after = DEFAULT_STORE_WARN_AFTER
	}
	store.timeout = options.timeout
	if store.timeout <= 0 {
		store.timeout = DEFAULT_STORE_TIMEOUT
	}
	store.checkpoint_bytes = options.checkpoint_bytes
	if store.checkpoint_bytes == 0 {
		store.checkpoint_bytes = DEFAULT_CHECKPOINT_BYTES
	}
	store.tickets = make(map[k.Persist_Ticket]i64, store.allocator)
	store.known = make(map[k.Relation_ID]bool, store.allocator)
	store.persisted = make(map[u64]u32, store.allocator)
	store.page_index = make(map[u32]Page_Index, store.allocator)
	store.queue = make([dynamic]Queue_Entry, store.allocator)
	store.records = make([dynamic]Wal_Record, store.allocator)
	// Ticket zero means "no reservation"; real tickets start at one.
	store.next_ticket = 1

	store.arena = new(virtual.Arena, store.allocator)
	if error := virtual.arena_init_growing(store.arena); error != nil {
		panic("failed to initialize store arena")
	}
	store.copy_allocator = virtual.arena_allocator(store.arena)
}

store_destroy :: proc(store: ^Store) {
	sync.mutex_lock(&store.lock)
	store.stop = true
	store.closed = true
	sync.cond_broadcast(&store.cond)
	sync.mutex_unlock(&store.lock)

	if store.thread != nil {
		thread.join(store.thread)
		thread.destroy(store.thread)
		store.thread = nil
	}

	if store.file != nil {
		os.close(store.file)
		store.file = nil
	}
	if store.pages_file != nil {
		os.close(store.pages_file)
		store.pages_file = nil
	}
	store_lock_release(store)
	if store.path != "" {
		delete(store.path, store.allocator)
		store.path = ""
	}
	if store.wal_path != "" {
		delete(store.wal_path, store.allocator)
		store.wal_path = ""
	}

	delete(store.tickets)
	delete(store.known)
	delete(store.persisted)
	delete(store.page_index)
	delete(store.queue)
	delete(store.records)
	if store.arena != nil {
		virtual.arena_destroy(store.arena)
		free(store.arena, store.allocator)
		store.arena = nil
	}
}

@(private)
store_release :: proc(store: ^Store) {
	if store.file != nil {
		os.close(store.file)
		store.file = nil
	}
	if store.pages_file != nil {
		os.close(store.pages_file)
		store.pages_file = nil
	}
	store_lock_release(store)
	if store.path != "" {
		delete(store.path, store.allocator)
		store.path = ""
	}
	if store.wal_path != "" {
		delete(store.wal_path, store.allocator)
		store.wal_path = ""
	}
	delete(store.tickets)
	delete(store.known)
	delete(store.persisted)
	delete(store.page_index)
	delete(store.queue)
	delete(store.records)
	if store.arena != nil {
		virtual.arena_destroy(store.arena)
		free(store.arena, store.allocator)
		store.arena = nil
	}
}

// Creates the exclusive `LOCK` file. A second process on the same store fails
// with a clear message; a stale lock after a crash must be removed by hand.
@(private)
store_lock_acquire :: proc(store: ^Store, path: string) -> bool {
	if directory_error := os.make_directory_all(path, os.Permissions_Default); directory_error != nil {
		if directory_error != .Exist {
			store.last_error = fmt.aprintf(
				"cannot create store directory: %v",
				directory_error,
				allocator = store.allocator,
			)
			return false
		}
	}
	lock_path, join_error := filepath.join(
		[]string{path, "LOCK"},
		store.allocator,
	)
	if join_error != nil {
		return false
	}
	file, open_error := os.open(lock_path, os.O_RDWR | os.O_CREATE | os.O_EXCL)
	if open_error == .Exist {
		store.last_error = "store is locked by another process"
		delete(lock_path, store.allocator)
		return false
	}
	if open_error != nil {
		store.last_error = fmt.aprintf(
			"cannot create store lock: %v",
			open_error,
			allocator = store.allocator,
		)
		delete(lock_path, store.allocator)
		return false
	}
	os.close(file)
	store.lock_path = lock_path
	store.lock_acquired = true
	return true
}

@(private)
store_lock_release :: proc(store: ^Store) {
	if store.lock_acquired && store.lock_path != "" {
		os.remove(store.lock_path)
		store.lock_acquired = false
	}
	if store.lock_path != "" {
		delete(store.lock_path, store.allocator)
		store.lock_path = ""
	}
}

// Attaches the store to a kernel so commits admit and publish into it.
store_attach :: proc(store: ^Store, kernel: ^k.Kernel) {
	store.kernel = kernel
	k.kernel_attach_store(kernel, store_hooks(store))
}

// Human-readable reason the last open failed, or "".
store_last_error :: proc(store: ^Store) -> string {
	return store.last_error
}

store_hooks :: proc(store: ^Store) -> k.Store_Hooks {
	return k.Store_Hooks {
		user             = store,
		admit            = store_admit_hook,
		release          = store_release_hook,
		publish          = store_publish_hook,
		wait_durable     = store_wait_durable_hook,
		durable_version  = store_durable_version_hook,
	}
}

// Blocks until `version` is durable. A version with no persistable writes is
// covered as soon as everything published before it is written.
store_wait_durable :: proc(store: ^Store, version: u64) {
	sync.mutex_lock(&store.lock)
	for store.durable < version && store.covered < version && !store.closed {
		sync.cond_wait(&store.cond, &store.lock)
	}
	sync.mutex_unlock(&store.lock)
}

store_durable_version :: proc(store: ^Store) -> u64 {
	sync.mutex_lock(&store.lock)
	defer sync.mutex_unlock(&store.lock)
	return store.durable
}

store_reserved_bytes :: proc(store: ^Store) -> i64 {
	sync.mutex_lock(&store.lock)
	defer sync.mutex_unlock(&store.lock)
	return store.reserved_bytes
}

store_record_count :: proc(store: ^Store) -> int {
	sync.mutex_lock(&store.lock)
	defer sync.mutex_unlock(&store.lock)
	return len(store.records)
}

// --- Hooks ------------------------------------------------------------------

@(private)
store_admit_hook :: proc(user: rawptr, bytes: i64) -> (k.Persist_Ticket, bool) {
	store := (^Store)(user)
	if bytes <= 0 {
		return 0, true
	}

	sync.mutex_lock(&store.lock)
	defer sync.mutex_unlock(&store.lock)
	if store.failed {
		return 0, false
	}
	deadline := time.tick_add(time.tick_now(), store.timeout)
	for store.reserved_bytes + bytes > store.budget_bytes && !store.closed {
		remaining := time.tick_diff(time.tick_now(), deadline)
		if remaining <= 0 {
			return 0, false
		}
		sync.cond_wait_with_timeout(&store.cond, &store.lock, remaining)
	}
	if store.closed {
		return 0, false
	}
	ticket := store.next_ticket
	store.next_ticket += 1
	store.tickets[ticket] = bytes
	store.reserved_bytes += bytes
	return ticket, true
}

@(private)
store_release_hook :: proc(user: rawptr, ticket: k.Persist_Ticket) {
	store := (^Store)(user)
	if ticket == 0 {
		return
	}
	sync.mutex_lock(&store.lock)
	if bytes, found := store.tickets[ticket]; found {
		delete_key(&store.tickets, ticket)
		store.reserved_bytes -= bytes
		sync.cond_broadcast(&store.cond)
	}
	sync.mutex_unlock(&store.lock)
}

// Copies the published writes and any new catalogue entries, then queues them
// for the writer. Runs on the committing thread; it only copies memory.
@(private)
store_publish_hook :: proc(
	user: rawptr,
	ticket: k.Persist_Ticket,
	version: u64,
	snapshot: ^k.Snapshot,
	writes: []k.Relation_Writes,
) {
	store := (^Store)(user)
	entry := Queue_Entry{version = version, ticket = ticket}

	writes_list: [dynamic]Wal_Write
	for relation_writes in writes {
		metadata, found := k.snapshot_relation_metadata(snapshot, relation_writes.relation)
		if !found || metadata.durability == .Volatile {
				continue
		}
		for write in relation_writes.entries {
			// Facts that carry ephemeral values (capability handles) are
			// runtime state; they are skipped rather than failing the store.
			persistable := true
			for cell in v.tuple_values(write.tuple) {
				if !v.value_is_persistable(cell) {
					persistable = false
					break
				}
			}
			if !persistable {
				continue
			}
			append(&writes_list, Wal_Write {
				relation = relation_writes.relation,
				assert   = write.kind == .Assert,
				tuple    = v.tuple_deep_copy(store.copy_allocator, write.tuple),
			})
		}
	}
	if len(writes_list) > 0 {
		entry.writes = make([]Wal_Write, len(writes_list), store.copy_allocator)
		copy(entry.writes, writes_list[:])
		delete(writes_list)
	}

	// New relations are rare; a full catalogue comparison keeps the kernel
	// side simple. This is the place to pass created relations explicitly if
	// the scan ever shows up on a hot path.
	// Catalogue entries persist for volatile relations too: their schema is
	// durable while their facts are not.
	catalog_list: [dynamic]Wal_Catalog
	sync.mutex_lock(&store.lock)
	for metadata in snapshot.catalog {
		if store.known[metadata.id] {
			continue
		}
		// Claim the entry while holding the lock so two concurrent writers
		// cannot both decide it is new.
		store.known[metadata.id] = true
		append(&catalog_list, Wal_Catalog{metadata = clone_metadata(store.copy_allocator, metadata)})
	}
	sync.mutex_unlock(&store.lock)
	if len(catalog_list) > 0 {
		entry.catalog = make([]Wal_Catalog, len(catalog_list), store.copy_allocator)
		copy(entry.catalog, catalog_list[:])
		delete(catalog_list)
	}

	if len(entry.writes) == 0 && len(entry.catalog) == 0 {
		// Nothing durable in this publish (for example a read-only commit or
		// a volatile-only write set); return the reservation untouched. When
		// no earlier write is in flight, this version is covered.
		sync.mutex_lock(&store.lock)
		if bytes, found := store.tickets[ticket]; found {
			delete_key(&store.tickets, ticket)
			store.reserved_bytes -= bytes
		}
		if len(store.queue) == 0 && store.reserved_bytes == 0 && version > store.covered {
			store.covered = version
		}
		sync.cond_broadcast(&store.cond)
		sync.mutex_unlock(&store.lock)
		return
	}

	sync.mutex_lock(&store.lock)
	if bytes, found := store.tickets[ticket]; found {
		entry.bytes = bytes
		delete_key(&store.tickets, ticket)
	}
	// `store.known` was claimed for these entries during the scan above.
	append(&store.queue, entry)
	sync.cond_broadcast(&store.cond)
	sync.mutex_unlock(&store.lock)
}

@(private)
store_wait_durable_hook :: proc(user: rawptr, version: u64) {
	store_wait_durable((^Store)(user), version)
}

@(private)
store_durable_version_hook :: proc(user: rawptr) -> u64 {
	store := (^Store)(user)
	sync.mutex_lock(&store.lock)
	defer sync.mutex_unlock(&store.lock)
	return store.durable
}

// --- Writer -----------------------------------------------------------------

@(private)
store_writer_proc :: proc(data: rawptr) {
	store := (^Store)(data)
	batch: [dynamic]Queue_Entry
	batch = make([dynamic]Queue_Entry, store.allocator)
	defer delete(batch)
	for {
		sync.mutex_lock(&store.lock)
		for len(store.queue) == 0 && !store.stop {
			sync.cond_wait(&store.cond, &store.lock)
		}
		if len(store.queue) == 0 && store.stop {
			sync.mutex_unlock(&store.lock)
			return
		}
		append(&batch, ..store.queue[:])
		clear(&store.queue)
		sync.mutex_unlock(&store.lock)

		// I/O runs outside the store lock: commits hand off, they do not wait.
		durable := true
		if store.mode == .File {
			sync.mutex_lock(&store.lock)
			failed := store.failed
			sync.mutex_unlock(&store.lock)
			if !failed {
				sync.mutex_lock(&store.wal_lock)
				durable = store_wal_append_batch(store, batch[:])
				sync.mutex_unlock(&store.wal_lock)
			}
		}

		sync.mutex_lock(&store.lock)
		if !durable {
			store.failed = true
		}
		if durable {
			for entry in batch {
				append(&store.records, Wal_Record {
					version = entry.version,
					writes  = entry.writes,
					catalog = entry.catalog,
				})
				if entry.version > store.durable {
					store.durable = entry.version
				}
			}
			if len(store.queue) == 0 && store.durable > store.covered {
				store.covered = store.durable
			}
		}
		for entry in batch {
			store.reserved_bytes -= entry.bytes
		}
		sync.cond_broadcast(&store.cond)
		sync.mutex_unlock(&store.lock)
		clear(&batch)

		if durable && store.mode == .File && store.kernel != nil &&
		   store.checkpoint_bytes > 0 &&
		   sync.atomic_load(&store.wal_bytes_since_checkpoint) >= store.checkpoint_bytes {
			if !store_checkpoint_internal(store, store.kernel, false) {
				// Do not silently continue after a failed automatic
				// checkpoint: mark the store failed so later commits are
				// refused and `.Strict` cannot report success.
				sync.mutex_lock(&store.lock)
				store.failed = true
				store.last_error = "automatic checkpoint failed"
				sync.cond_broadcast(&store.cond)
				sync.mutex_unlock(&store.lock)
			}
		}
	}
}

store_sync_count :: proc(store: ^Store) -> u64 {
	return sync.atomic_load(&store.syncs)
}

store_failed :: proc(store: ^Store) -> bool {
	sync.mutex_lock(&store.lock)
	defer sync.mutex_unlock(&store.lock)
	return store.failed
}

// Reports whether durable writes have been appended since the last checkpoint.
// A world that only booted and read can skip its shutdown checkpoint.
store_has_pending_writes :: proc(store: ^Store) -> bool {
	return sync.atomic_load(&store.wal_bytes_since_checkpoint) > 0
}

// --- Copies -----------------------------------------------------------------

@(private)
clone_metadata :: proc(
	allocator: mem.Allocator,
	metadata: k.Relation_Metadata,
) -> k.Relation_Metadata {
	result := metadata
	if len(metadata.argument_names) > 0 {
		result.argument_names = make([]v.Symbol, len(metadata.argument_names), allocator)
		copy(result.argument_names, metadata.argument_names)
	}
	if len(metadata.indexes) > 0 {
		result.indexes = make([]k.Index_Spec, len(metadata.indexes), allocator)
		for spec, index in metadata.indexes {
			positions := make([]u16, len(spec.positions), allocator)
			copy(positions, spec.positions)
			result.indexes[index] = k.Index_Spec{positions = positions}
		}
	}
	if len(metadata.conflict.key_positions) > 0 {
		keys := make([]u16, len(metadata.conflict.key_positions), allocator)
		copy(keys, metadata.conflict.key_positions)
		result.conflict.key_positions = keys
	}
	return result
}
