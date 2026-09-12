// Chunk shadow pages and checkpoint manifests.
//
// A checkpoint walks the current kernel snapshot's relation blocks and writes
// every chunk not yet persisted as an immutable page. Identical chunks shared
// between versions are written once and referenced by many manifests. The
// manifest lists, per durable relation, the page id and row count of every
// chunk; volatile relations appear with schema only.
//
// The manifest is swapped atomically (temp file + rename) after the pages it
// references are synced, so a crash leaves the previous manifest valid. The
// write-ahead log still covers commits after the checkpoint version, and boot
// replays only that tail.
package store

import "core:mem"
import "core:os"
import "core:path/filepath"
import "core:sync"
import k "../kernel"
import v "../var"

PAGE_MAGIC :: "MICAPG01"
PAGE_HEADER_SIZE :: 28
MANIFEST_MAGIC :: "MICAMF01"
MANIFEST_VERSION :: u32(1)

// One relation entry in a checkpoint manifest.
Checkpoint_Relation :: struct {
	metadata:   k.Relation_Metadata,
	page_ids:   []u32,
	row_counts: []u32,
}

@(private)
Page_Index :: struct {
	offset:   i64,
	length:   int,
	relation: k.Relation_ID,
	rows:     u32,
}

@(private)
page_write_u32 :: proc(out: ^[dynamic]u8, value: u32) {
	codec_write_u32(out, value)
}

// Appends one chunk's rows as a page. Returns the page id.
@(private)
store_page_append :: proc(
	store: ^Store,
	relation: k.Relation_ID,
	rows: []v.Tuple,
) -> (
	u32,
	bool,
) {
	payload: [dynamic]u8
	payload = make([dynamic]u8, context.temp_allocator)
	defer delete(payload)
	for row in rows {
		if error := codec_encode_tuple(&payload, row); error != .None {
			return 0, false
		}
	}

	frame: [dynamic]u8
	frame = make([dynamic]u8, context.temp_allocator)
	defer delete(frame)
	magic: string = PAGE_MAGIC
	append(&frame, ..transmute([]u8)magic)
	page_id := store.next_page_id
	codec_write_u32(&frame, page_id)
	codec_write_u32(&frame, u32(relation))
	codec_write_u32(&frame, u32(len(rows)))
	codec_write_u32(&frame, u32(len(payload)))
	codec_write_u32(&frame, u32(fnv1a64(payload[:]) & 0xffff_ffff))
	append(&frame, ..payload[:])

	written, write_error := os.write_at(store.pages_file, frame[:], store.pages_end)
	if write_error != nil || written != len(frame) {
		return 0, false
	}
	store.page_index[page_id] = Page_Index {
		offset   = store.pages_end,
		length   = len(frame),
		relation = relation,
		rows     = u32(len(rows)),
	}
	store.pages_end += i64(written)
	store.next_page_id += 1
	return page_id, true
}

// Reads one page's rows. The page index must already be built.
@(private)
store_page_read :: proc(
	store: ^Store,
	page_id: u32,
	allocator: mem.Allocator,
) -> (
	[]v.Tuple,
	Codec_Error,
) {
	entry, found := store.page_index[page_id]
	if !found {
		return nil, .Truncated
	}
	data := make([]u8, entry.length, context.temp_allocator)
	defer delete(data, context.temp_allocator)
	if _, seek_error := os.seek(store.pages_file, entry.offset, .Start); seek_error != nil {
		return nil, .Truncated
	}
	read, read_error := os.read(store.pages_file, data)
	if read_error != nil || read != entry.length {
		return nil, .Truncated
	}
	if data[0] != PAGE_MAGIC[0] || data[7] != PAGE_MAGIC[7] {
		return nil, .Bad_Tag
	}
	payload_length := u32(data[20]) |
		u32(data[21]) << 8 |
		u32(data[22]) << 16 |
		u32(data[23]) << 24
	if PAGE_HEADER_SIZE + int(payload_length) > entry.length {
		return nil, .Truncated
	}
	payload := data[PAGE_HEADER_SIZE:PAGE_HEADER_SIZE + int(payload_length)]
	checksum := u32(data[24]) |
		u32(data[25]) << 8 |
		u32(data[26]) << 16 |
		u32(data[27]) << 24
	if u32(fnv1a64(payload) & 0xffff_ffff) != checksum {
		return nil, .Bad_Tag
	}
	rows := make([]v.Tuple, int(entry.rows), allocator)
	cursor := 0
	for index in 0 ..< int(entry.rows) {
		tuple, tuple_error := codec_decode_tuple(payload, &cursor, allocator)
		if tuple_error != .None {
			return nil, tuple_error
		}
		rows[index] = tuple
	}
	return rows, .None
}

// Scans the pages file, rebuilding the page index, and truncates a torn tail.
@(private)
store_pages_open :: proc(store: ^Store) -> bool {
	path, join_error := filepath_join(store.allocator, store.path, "pages")
	if join_error != nil {
		return false
	}
	file, open_error := os.open(path, os.O_RDWR | os.O_CREATE)
	if open_error != nil {
		return false
	}
	store.pages_file = file

	size, size_error := os.file_size(file)
	if size_error != nil {
		return false
	}
	position := i64(0)
	for position + PAGE_HEADER_SIZE <= size {
		header: [PAGE_HEADER_SIZE]u8
		if _, seek_error := os.seek(file, position, .Start); seek_error != nil {
			return false
		}
		read, read_error := os.read(file, header[:])
		if read_error != nil || read != PAGE_HEADER_SIZE {
			break
		}
		if header[0] != PAGE_MAGIC[0] || header[7] != PAGE_MAGIC[7] {
			break
		}
		page_id := u32(header[8]) |
			u32(header[9]) << 8 |
			u32(header[10]) << 16 |
			u32(header[11]) << 24
		relation := u32(header[12]) |
			u32(header[13]) << 8 |
			u32(header[14]) << 16 |
			u32(header[15]) << 24
		payload_length := u32(header[20]) |
			u32(header[21]) << 8 |
			u32(header[22]) << 16 |
			u32(header[23]) << 24
		rows := u32(header[16]) |
			u32(header[17]) << 8 |
			u32(header[18]) << 16 |
			u32(header[19]) << 24
		length := PAGE_HEADER_SIZE + int(payload_length)
		if position + i64(length) > size {
			break
		}
		store.page_index[page_id] = Page_Index {
			offset   = position,
			length   = length,
			relation = k.Relation_ID(relation),
			rows     = rows,
		}
		if page_id >= store.next_page_id {
			store.next_page_id = page_id + 1
		}
		position += i64(length)
	}
	store.pages_end = position
	if position < size {
		if truncate_error := os.truncate(file, position); truncate_error != nil {
			return false
		}
	}
	return true
}

// Encodes the manifest for `relations`.
@(private)
store_manifest_encode :: proc(
	out: ^[dynamic]u8,
	version: u64,
	relations: []Checkpoint_Relation,
) -> bool {
	manifest_magic: string = MANIFEST_MAGIC
	append(out, ..transmute([]u8)manifest_magic)
	codec_write_u32(out, MANIFEST_VERSION)
	codec_write_u64(out, version)
	codec_write_u32(out, u32(len(relations)))
	for relation in relations {
		if error := wal_encode_metadata(out, relation.metadata); error != .None {
			return false
		}
		codec_write_u32(out, u32(len(relation.page_ids)))
		for page_id, index in relation.page_ids {
			codec_write_u32(out, page_id)
			codec_write_u32(out, relation.row_counts[index])
		}
	}
	return true
}

// Writes a new manifest generation and switches `MANIFEST` atomically.
@(private)
store_manifest_write :: proc(
	store: ^Store,
	version: u64,
	relations: []Checkpoint_Relation,
) -> bool {
	data: [dynamic]u8
	data = make([dynamic]u8, context.temp_allocator)
	defer delete(data)
	if !store_manifest_encode(&data, version, relations) {
		return false
	}
	temp_path, temp_error := filepath_join(store.allocator, store.path, "MANIFEST.tmp")
	if temp_error != nil {
		return false
	}
	manifest_path, manifest_error := filepath_join(store.allocator, store.path, "MANIFEST")
	if manifest_error != nil {
		return false
	}
	file, open_error := os.open(
		temp_path,
		os.O_RDWR | os.O_CREATE | os.O_TRUNC,
	)
	if open_error != nil {
		return false
	}
	written, write_error := os.write(file, data[:])
	if write_error != nil || written != len(data) {
		os.close(file)
		return false
	}
	if sync_error := os.sync(file); sync_error != nil {
		os.close(file)
		return false
	}
	os.close(file)
	if rename_error := os.rename(temp_path, manifest_path); rename_error != nil {
		return false
	}
	return true
}

// Reads the manifest if it exists into `store.manifest_relations`.
@(private)
store_manifest_open :: proc(store: ^Store) -> bool {
	path, join_error := filepath_join(store.allocator, store.path, "MANIFEST")
	if join_error != nil {
		return false
	}
	if !os.exists(path) {
		return true
	}
	file, open_error := os.open(path, os.O_RDONLY)
	if open_error != nil {
		return false
	}
	defer os.close(file)
	size, size_error := os.file_size(file)
	if size_error != nil || size < 12 {
		return false
	}
	data := make([]u8, int(size), context.temp_allocator)
	defer delete(data, context.temp_allocator)
	read, read_error := os.read(file, data)
	if read_error != nil || read != int(size) {
		return false
	}
	if data[0] != MANIFEST_MAGIC[0] || data[7] != MANIFEST_MAGIC[7] {
		return false
	}
	reader := Codec_Reader{data = data, cursor = 12}
	version, version_error := codec_read_u64(&reader)
	if version_error != .None {
		return false
	}
	count, count_error := codec_read_u32(&reader)
	if count_error != .None {
		return false
	}
	relations := make([]Checkpoint_Relation, int(count), store.copy_allocator)
	for index in 0 ..< int(count) {
		metadata, metadata_error := wal_decode_metadata(&reader, store.copy_allocator)
		if metadata_error != .None {
			return false
		}
		chunk_count, chunk_error := codec_read_u32(&reader)
		if chunk_error != .None {
			return false
		}
		page_ids := make([]u32, int(chunk_count), store.copy_allocator)
		row_counts := make([]u32, int(chunk_count), store.copy_allocator)
		for chunk_index in 0 ..< int(chunk_count) {
			page_id, page_error := codec_read_u32(&reader)
			if page_error != .None {
				return false
			}
			rows, rows_error := codec_read_u32(&reader)
			if rows_error != .None {
				return false
			}
			page_ids[chunk_index] = page_id
			row_counts[chunk_index] = rows
		}
		relations[index] = Checkpoint_Relation {
			metadata   = metadata,
			page_ids   = page_ids,
			row_counts = row_counts,
		}
	}
	store.manifest_relations = relations
	store.checkpoint_version = version
	return true
}

// Writes every chunk not yet persisted as a page, then switches to a new
// manifest. Safe to run while commits continue: the snapshot is immutable and
// retains its chunks, so serialization needs no kernel lock.
store_checkpoint :: proc(store: ^Store, kernel: ^k.Kernel) -> bool {
	sync.mutex_lock(&store.checkpoint_lock)
	defer sync.mutex_unlock(&store.checkpoint_lock)

	snapshot := k.kernel_snapshot(kernel)
	defer k.snapshot_release(snapshot)
	store_wait_durable(store, snapshot.version)

	relations: [dynamic]Checkpoint_Relation
	relations = make([dynamic]Checkpoint_Relation, context.temp_allocator)
	defer delete(relations)

	for block in snapshot.blocks {
		relation := Checkpoint_Relation {
			metadata = clone_metadata(store.copy_allocator, block.metadata),
		}
		if block.metadata.durability == .Durable {
			page_ids: [dynamic]u32
			page_ids = make([dynamic]u32, context.temp_allocator)
			row_counts: [dynamic]u32
			row_counts = make([dynamic]u32, context.temp_allocator)
			for chunk in block.chunks {
				key := rawptr(chunk)
				page_id, found := store.persisted[key]
				if !found {
					appended, appended_ok := store_page_append(
						store,
						block.metadata.id,
						chunk.tuples,
					)
					if !appended_ok {
						delete(page_ids)
						delete(row_counts)
						return false
					}
					page_id = appended
					store.persisted[key] = page_id
				}
				append(&page_ids, page_id)
				append(&row_counts, u32(len(chunk.tuples)))
			}
			owned_ids := make([]u32, len(page_ids), store.copy_allocator)
			copy(owned_ids, page_ids[:])
			owned_counts := make([]u32, len(row_counts), store.copy_allocator)
			copy(owned_counts, row_counts[:])
			relation.page_ids = owned_ids
			relation.row_counts = owned_counts
			delete(page_ids)
			delete(row_counts)
		}
		append(&relations, relation)
	}

	if sync_error := os.sync(store.pages_file); sync_error != nil {
		return false
	}
	if !store_manifest_write(store, snapshot.version, relations[:]) {
		return false
	}
	if !store_wal_rotate(store, snapshot.version) {
		return false
	}

	owned := make([]Checkpoint_Relation, len(relations), store.copy_allocator)
	copy(owned, relations[:])
	store.manifest_relations = owned
	store.checkpoint_version = snapshot.version
	return true
}

// Materializes the checkpoint into a fresh kernel. Replaces any existing
// relation blocks and catalogs.
@(private)
store_materialize_checkpoint :: proc(store: ^Store, kernel: ^k.Kernel) -> bool {
	if len(store.manifest_relations) == 0 {
		return true
	}
	entries: [dynamic]k.Checkpoint_Relation
	entries = make([dynamic]k.Checkpoint_Relation, context.temp_allocator)
	defer delete(entries)

	for relation in store.manifest_relations {
		rows: [dynamic]v.Tuple
		rows = make([dynamic]v.Tuple, context.temp_allocator)
		if relation.metadata.durability == .Durable {
			for page_id in relation.page_ids {
				page_rows, page_error := store_page_read(
					store,
					page_id,
					store.copy_allocator,
				)
				if page_error != .None {
					delete(rows)
					return false
				}
				append(&rows, ..page_rows)
			}
		}
		block := k.relation_block_build_pooled(kernel, relation.metadata, rows[:])
		append(&entries, k.Checkpoint_Relation {
			metadata = relation.metadata,
			block    = block,
		})
		delete(rows)
	}
	return k.kernel_install_checkpoint(kernel, entries[:])
}

store_page_count :: proc(store: ^Store) -> int {
	return len(store.page_index)
}

store_checkpoint_version :: proc(store: ^Store) -> u64 {
	return store.checkpoint_version
}

// Joins two path components, returning the join error.
@(private)
filepath_join :: proc(allocator: mem.Allocator, parts: ..string) -> (string, os.Error) {
	return filepath.join(parts, allocator)
}
