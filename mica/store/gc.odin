// Manifest retention, point-in-time selection, and page compaction.
//
// Retained manifests keep the page ids live for a bounded history of
// checkpoints. When enough pages are dead, compaction rewrites the live pages
// into a new generation file, remaps page ids in every retained manifest, and
// removes the old generation.
package store

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strconv"
import "core:strings"
import "core:sync"

@(private)
versioned_manifest_path :: proc(store: ^Store, version: u64) -> string {
	name := fmt.aprintf("MANIFEST.%d", version, allocator = context.temp_allocator)
	joined, join_error := filepath.join([]string{store.path, name}, context.temp_allocator)
	if join_error != nil {
		return ""
	}
	return joined
}

@(private)
pages_generation_path :: proc(store: ^Store, generation: u32) -> string {
	name := fmt.aprintf("pages.%d", generation, allocator = context.temp_allocator)
	joined, join_error := filepath.join([]string{store.path, name}, context.temp_allocator)
	if join_error != nil {
		return ""
	}
	return joined
}

// Lists retained checkpoint versions from `MANIFEST.<version>` files.
@(private)
store_manifest_versions :: proc(store: ^Store) -> []u64 {
	directory, open_error := os.open(store.path, os.O_RDONLY)
	if open_error != nil {
		return nil
	}
	defer os.close(directory)
	entries, read_error := os.read_directory(directory, 0, context.temp_allocator)
	if read_error != nil {
		return nil
	}
	versions: [dynamic]u64
	versions = make([dynamic]u64, context.temp_allocator)
	for entry in entries {
		if !strings.has_prefix(entry.name, "MANIFEST.") {
			continue
		}
		suffix := entry.name[len("MANIFEST."):]
		if strings.has_suffix(suffix, ".tmp") {
			continue
		}
		version, parsed := strconv.parse_u64(suffix)
		if parsed {
			append(&versions, version)
		}
	}
	slice.sort(versions[:])
	return versions[:]
}

// Deletes retained manifests beyond the retention window.
@(private)
store_manifest_prune :: proc(store: ^Store) {
	versions := store_manifest_versions(store)
	if len(versions) <= MANIFEST_RETENTION {
		return
	}
	for index in 0 ..< len(versions) - MANIFEST_RETENTION {
		os.remove(versioned_manifest_path(store, versions[index]))
	}
}

// Copies one page byte-for-byte to a new generation with `new_id`.
@(private)
store_page_copy_raw :: proc(
	store: ^Store,
	source: ^os.File,
	entry: Page_Index,
	target_file: ^os.File,
	offset: i64,
	new_id: u32,
) -> (
	Page_Index,
	bool,
) {
	data := make([]u8, entry.length, context.temp_allocator)
	defer delete(data, context.temp_allocator)
	if _, seek_error := os.seek(source, entry.offset, .Start); seek_error != nil {
		return {}, false
	}
	read, read_error := os.read(source, data)
	if read_error != nil || read != entry.length {
		return {}, false
	}
	data[8] = u8(new_id)
	data[9] = u8(new_id >> 8)
	data[10] = u8(new_id >> 16)
	data[11] = u8(new_id >> 24)
	written, write_error := os.write_at(target_file, data, offset)
	if write_error != nil || written != len(data) {
		return {}, false
	}
	return Page_Index {
		offset   = offset,
		length   = entry.length,
		relation = entry.relation,
		rows     = entry.rows,
	}, true
}

// Compacts live pages into a new generation and remaps every retained
// manifest. Returns false on any I/O or format error.
store_pages_compact :: proc(store: ^Store) -> bool {
	sync.mutex_lock(&store.checkpoint_lock)
	defer sync.mutex_unlock(&store.checkpoint_lock)
	return store_pages_compact_locked(store)
}

// Compaction body; the caller holds `checkpoint_lock`.
@(private)
store_pages_compact_locked :: proc(store: ^Store) -> bool {
	if len(store.page_index) == 0 {
		return true
	}

	// Load retained manifests and union their page ids.
	versions := store_manifest_versions(store)
	manifests: [dynamic]Manifest_Data
	manifests = make([dynamic]Manifest_Data, context.temp_allocator)
	defer delete(manifests)
	live: map[u32]bool
	live = make(map[u32]bool, context.temp_allocator)
	defer delete(live)
	for version in versions {
		data, read_ok := store_manifest_read(store, versioned_manifest_path(store, version))
		if !read_ok {
			return false
		}
		// A manifest from a different generation is a leftover from a
		// compaction that crashed mid-rewrite. Its page ids are unusable;
		// drop it so it cannot wedge compaction forever.
		if data.generation != store.pages_generation {
			os.remove(versioned_manifest_path(store, version))
			continue
		}
		append(&manifests, data)
		for relation in data.relations {
			for page_id in relation.page_ids {
				live[page_id] = true
			}
		}
	}

	// Copy live pages into the next generation file, remapping ids.
	new_generation := store.pages_generation + 1
	new_path := pages_generation_path(store, new_generation)
	temp_path := strings.concatenate(
		[]string{new_path, ".tmp"},
		context.temp_allocator,
	)
	target, open_error := os.open(temp_path, os.O_RDWR | os.O_CREATE | os.O_TRUNC)
	if open_error != nil {
		return false
	}
	ids: [dynamic]u32
	ids = make([dynamic]u32, context.temp_allocator)
	defer delete(ids)
	for page_id in live {
		append(&ids, page_id)
	}
	slice.sort(ids[:])
	remap: map[u32]u32
	remap = make(map[u32]u32, context.temp_allocator)
	defer delete(remap)
	new_index: map[u32]Page_Index
	new_index = make(map[u32]Page_Index, store.allocator)
	offset := i64(0)
	for page_id, new_id in ids {
		entry, found := store.page_index[page_id]
		if !found {
			os.close(target)
			return false
		}
		copied, copy_ok := store_page_copy_raw(
			store,
			store.pages_file,
			entry,
			target,
			offset,
			u32(new_id),
		)
		if !copy_ok {
			os.close(target)
			return false
		}
		remap[page_id] = u32(new_id)
		new_index[u32(new_id)] = copied
		offset += i64(copied.length)
	}
	if sync_error := os.sync(target); sync_error != nil {
		os.close(target)
		return false
	}
	os.close(target)
	if rename_error := os.rename(temp_path, new_path); rename_error != nil {
		return false
	}
	store_sync_dir(store.path)

	// Rewrite retained manifests with remapped ids and the new generation.
	for &data in manifests {
		data.generation = new_generation
		for &relation in data.relations {
			for &page_id in relation.page_ids {
				page_id = remap[page_id]
			}
		}
		if !store_manifest_write_to(store, versioned_manifest_path(store, data.version), &data) {
			return false
		}
	}

	// Remap the in-memory current manifest and rewrite MANIFEST.
	for &relation in store.manifest_relations {
		for &page_id in relation.page_ids {
			page_id = remap[page_id]
		}
	}
	current := Manifest_Data {
		version    = sync.atomic_load(&store.checkpoint_version),
		generation = new_generation,
		relations  = store.manifest_relations,
	}
	current_path, path_error := filepath.join(
		[]string{store.path, "MANIFEST"},
		context.temp_allocator,
	)
	if path_error != nil {
		return false
	}
	if !store_manifest_write_to(store, current_path, &current) {
		return false
	}

	// Swap the pages file and drop dead entries from the persistence map.
	old_file := store.pages_file
	old_path := pages_generation_path(store, store.pages_generation)
	reopened, reopen_error := os.open(new_path, os.O_RDWR)
	if reopen_error != nil {
		return false
	}
	store.pages_file = reopened
	// Free the pre-compaction index map before replacing it; its backing
	// storage would otherwise leak on every compaction.
	delete(store.page_index)
	store.page_index = new_index
	store.pages_end = offset
	store.pages_generation = new_generation
	stale: [dynamic]u64
	stale = make([dynamic]u64, context.temp_allocator)
	for key, page_id in store.persisted {
		if mapped, found := remap[page_id]; found {
			store.persisted[key] = mapped
		} else {
			append(&stale, key)
		}
	}
	for key in stale {
		delete_key(&store.persisted, key)
	}
	delete(stale)
	if old_file != nil {
		os.close(old_file)
	}
	os.remove(old_path)
	return true
}

// Compacts pages when dead pages dominate the file.
@(private)
store_gc_if_needed :: proc(store: ^Store) {
	versions := store_manifest_versions(store)
	live: map[u32]bool
	live = make(map[u32]bool, context.temp_allocator)
	defer delete(live)
	for version in versions {
		data, read_ok := store_manifest_read(store, versioned_manifest_path(store, version))
		if !read_ok {
			return
		}
		// See store_pages_compact_locked: an interrupted compaction can leave
		// a manifest from the old generation behind. Drop it.
		if data.generation != store.pages_generation {
			os.remove(versioned_manifest_path(store, version))
			continue
		}
		for relation in data.relations {
			for page_id in relation.page_ids {
				live[page_id] = true
			}
		}
	}
	dead := len(store.page_index) - len(live)
	if dead >= GC_DEAD_MIN && dead * 4 > len(store.page_index) {
		_ = store_pages_compact_locked(store)
	}
}

// Oldest retained checkpoint version, or zero when none exist.
store_oldest_retained_version :: proc(store: ^Store) -> u64 {
	versions := store_manifest_versions(store)
	if len(versions) == 0 {
		return 0
	}
	return versions[0]
}
