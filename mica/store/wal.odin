// Write-ahead log for the file-backed store.
//
// Layout:
//
//	header  "MICAWAL1" + version u32
//	record  payload_len u32 | checksum u32 | payload
//
// A record payload is the logical write set for one published version:
// version, fact writes, and new catalogue entries. Recovery stops at the
// first truncated or corrupt record and truncates the file there.
package store

import "core:mem"
import "core:os"
import "core:path/filepath"
import "core:sync"
import k "../kernel"
import v "../var"

WAL_MAGIC :: "MICAWAL1"
WAL_VERSION :: u32(1)
WAL_HEADER_SIZE :: 12

@(private)
fnv1a64 :: proc(data: []u8) -> u64 {
	hash := u64(0xcbf2_9ce4_8422_2325)
	for byte in data {
		hash = (hash ~ u64(byte)) * u64(0x0000_0100_0000_01b3)
	}
	return hash
}

@(private)
wal_encode_metadata :: proc(out: ^[dynamic]u8, metadata: k.Relation_Metadata) -> Codec_Error {
	codec_write_u32(out, u32(metadata.id))
	if error := codec_write_symbol(out, metadata.name); error != .None {
		return error
	}
	codec_write_u32(out, u32(metadata.arity))
	codec_write_u32(out, u32(len(metadata.argument_names)))
	for name in metadata.argument_names {
		if error := codec_write_symbol(out, name); error != .None {
			return error
		}
	}
	codec_write_u32(out, u32(len(metadata.indexes)))
	for spec in metadata.indexes {
		codec_write_u32(out, u32(len(spec.positions)))
		for position in spec.positions {
			codec_write_u32(out, u32(position))
		}
	}
	codec_write_u8(out, u8(metadata.conflict.kind))
	codec_write_u32(out, u32(len(metadata.conflict.key_positions)))
	for position in metadata.conflict.key_positions {
		codec_write_u32(out, u32(position))
	}
	codec_write_u8(out, u8(metadata.durability))
	return .None
}

@(private)
wal_decode_metadata :: proc(
	reader: ^Codec_Reader,
	allocator: mem.Allocator,
) -> (
	k.Relation_Metadata,
	Codec_Error,
) {
	id, id_error := codec_read_u32(reader)
	if id_error != .None {
		return {}, id_error
	}
	name, name_error := codec_read_string(reader, allocator)
	if name_error != .None {
		return {}, name_error
	}
	arity, arity_error := codec_read_u32(reader)
	if arity_error != .None {
		return {}, arity_error
	}
	argument_count, argument_error := codec_read_u32(reader)
	if argument_error != .None {
		return {}, argument_error
	}
	argument_names := make([]v.Symbol, int(argument_count), allocator)
	for index in 0 ..< int(argument_count) {
		argument, read_error := codec_read_string(reader, allocator)
		if read_error != .None {
			return {}, read_error
		}
		argument_names[index] = v.symbol_intern(argument)
	}
	index_count, index_error := codec_read_u32(reader)
	if index_error != .None {
		return {}, index_error
	}
	indexes := make([]k.Index_Spec, int(index_count), allocator)
	for index in 0 ..< int(index_count) {
		position_count, position_error := codec_read_u32(reader)
		if position_error != .None {
			return {}, position_error
		}
		positions := make([]u16, int(position_count), allocator)
		for position_index in 0 ..< int(position_count) {
			position, read_error := codec_read_u32(reader)
			if read_error != .None {
				return {}, read_error
			}
			positions[position_index] = u16(position)
		}
		indexes[index] = k.Index_Spec{positions = positions}
	}
	conflict_byte, conflict_error := codec_read_u8(reader)
	if conflict_error != .None {
		return {}, conflict_error
	}
	key_count, key_error := codec_read_u32(reader)
	if key_error != .None {
		return {}, key_error
	}
	key_positions := make([]u16, int(key_count), allocator)
	for index in 0 ..< int(key_count) {
		position, read_error := codec_read_u32(reader)
		if read_error != .None {
			return {}, read_error
		}
		key_positions[index] = u16(position)
	}
	durability_byte, durability_error := codec_read_u8(reader)
	if durability_error != .None {
		return {}, durability_error
	}
	return k.Relation_Metadata {
			id = k.Relation_ID(id),
			name = v.symbol_intern(name),
			arity = u16(arity),
			argument_names = argument_names,
			indexes = indexes,
			conflict = k.Conflict_Policy {
				kind = k.Conflict_Kind(conflict_byte),
				key_positions = key_positions,
			},
			durability = k.Relation_Durability(durability_byte),
		},
		.None
}

// Encodes one record as a framed payload.
@(private)
wal_encode_record :: proc(out: ^[dynamic]u8, record: ^Wal_Record) -> Codec_Error {
	payload: [dynamic]u8
	payload = make([dynamic]u8, context.temp_allocator)
	defer delete(payload)

	codec_write_u64(&payload, record.version)
	codec_write_u32(&payload, u32(len(record.writes)))
	for write in record.writes {
		codec_write_u32(&payload, u32(write.relation))
		codec_write_u8(&payload, write.assert ? 1 : 0)
		if error := codec_encode_tuple(&payload, write.tuple); error != .None {
			return error
		}
	}
	codec_write_u32(&payload, u32(len(record.catalog)))
	for catalog in record.catalog {
		if error := wal_encode_metadata(&payload, catalog.metadata); error != .None {
			return error
		}
	}
	codec_write_u32(out, u32(len(payload)))
	codec_write_u32(out, u32(fnv1a64(payload[:]) & 0xffff_ffff))
	append(out, ..payload[:])
	return .None
}

// Decodes one framed record at `cursor`, advancing it.
@(private)
wal_decode_record :: proc(
	data: []u8,
	cursor: ^int,
	allocator: mem.Allocator,
) -> (
	Wal_Record,
	Codec_Error,
) {
	position := cursor^
	if position + 8 > len(data) {
		return {}, .Truncated
	}
	length := u32(data[position]) |
		u32(data[position + 1]) << 8 |
		u32(data[position + 2]) << 16 |
		u32(data[position + 3]) << 24
	checksum := u32(data[position + 4]) |
		u32(data[position + 5]) << 8 |
		u32(data[position + 6]) << 16 |
		u32(data[position + 7]) << 24
	if position + 8 + int(length) > len(data) {
		return {}, .Truncated
	}
	payload := data[position + 8:position + 8 + int(length)]
	if u32(fnv1a64(payload) & 0xffff_ffff) != checksum {
		return {}, .Bad_Tag
	}

	reader := Codec_Reader{data = payload}
	version, version_error := codec_read_u64(&reader)
	if version_error != .None {
		return {}, version_error
	}
	write_count, write_error := codec_read_u32(&reader)
	if write_error != .None {
		return {}, write_error
	}
	writes := make([]Wal_Write, int(write_count), allocator)
	for index in 0 ..< int(write_count) {
		relation, relation_error := codec_read_u32(&reader)
		if relation_error != .None {
			return {}, relation_error
		}
		assert_byte, assert_error := codec_read_u8(&reader)
		if assert_error != .None {
			return {}, assert_error
		}
		tuple, tuple_error := codec_decode_tuple(payload, &reader.cursor, allocator)
		if tuple_error != .None {
			return {}, tuple_error
		}
		writes[index] = Wal_Write {
			relation = k.Relation_ID(relation),
			assert   = assert_byte != 0,
			tuple    = tuple,
		}
	}
	catalog_count, catalog_error := codec_read_u32(&reader)
	if catalog_error != .None {
		return {}, catalog_error
	}
	catalog := make([]Wal_Catalog, int(catalog_count), allocator)
	for index in 0 ..< int(catalog_count) {
		metadata, metadata_error := wal_decode_metadata(&reader, allocator)
		if metadata_error != .None {
			return {}, metadata_error
		}
		catalog[index] = Wal_Catalog{metadata = metadata}
	}
	if reader.cursor != len(payload) {
		return {}, .Bad_Tag
	}
	cursor^ = position + 8 + int(length)
	return Wal_Record{version = version, writes = writes, catalog = catalog}, .None
}

// Opens (or creates) the WAL under `path` and recovers its records. Returns
// false when the directory or file cannot be used.
@(private)
store_wal_open :: proc(store: ^Store, path: string) -> bool {
	if path == "" {
		return false
	}
	store.path = clone_string(store.allocator, path)
	if directory_error := os.make_directory_all(path, os.Permissions_Default); directory_error != nil {
		if directory_error != .Exist {
			return false
		}
	}
	wal_path, join_error := filepath.join([]string{path, "wal"}, store.allocator)
	if join_error != nil {
		return false
	}
	store.wal_path = wal_path

	file, open_error := os.open(wal_path, os.O_RDWR | os.O_CREATE)
	if open_error != nil {
		return false
	}
	store.file = file

	size, size_error := os.file_size(file)
	if size_error != nil {
		return false
	}
	if size == 0 {
		header: [WAL_HEADER_SIZE]u8
		copy(header[:8], WAL_MAGIC)
		version := WAL_VERSION
		header[8] = u8(version)
		header[9] = u8(version >> 8)
		header[10] = u8(version >> 16)
		header[11] = u8(version >> 24)
		written, write_error := os.write(file, header[:])
		if write_error != nil || written != WAL_HEADER_SIZE {
			return false
		}
		store.wal_end = WAL_HEADER_SIZE
		return true
	}

	data := make([]u8, int(size), context.temp_allocator)
	defer delete(data, context.temp_allocator)
	if _, seek_error := os.seek(file, 0, .Start); seek_error != nil {
		return false
	}
	read, read_error := os.read(file, data)
	if read_error != nil || read != int(size) {
		return false
	}
	if data[0] != WAL_MAGIC[0] ||
	   data[1] != WAL_MAGIC[1] ||
	   data[2] != WAL_MAGIC[2] ||
	   data[3] != WAL_MAGIC[3] ||
	   data[4] != WAL_MAGIC[4] ||
	   data[5] != WAL_MAGIC[5] ||
	   data[6] != WAL_MAGIC[6] ||
	   data[7] != WAL_MAGIC[7] {
		return false
	}

	cursor := WAL_HEADER_SIZE
	last_good := WAL_HEADER_SIZE
	for cursor < len(data) {
		record, decode_error := wal_decode_record(data, &cursor, store.copy_allocator)
		if decode_error != .None {
			break
		}
		append(&store.records, record)
		if record.version > store.durable {
			store.durable = record.version
		}
		last_good = cursor
	}
	if last_good < len(data) {
		// Drop the torn tail so later appends start at a record boundary.
		if truncate_error := os.truncate(file, i64(last_good)); truncate_error != nil {
			return false
		}
	}
	store.wal_end = i64(last_good)
	return true
}

// Appends and syncs one batch of records. Runs on the writer thread.
@(private)
store_wal_append_batch :: proc(store: ^Store, entries: []Queue_Entry) -> bool {
	if store.file == nil {
		return true
	}
	buffer: [dynamic]u8
	buffer = make([dynamic]u8, context.temp_allocator)
	defer delete(buffer)

	for entry in entries {
		record := Wal_Record {
			version = entry.version,
			writes  = entry.writes,
			catalog = entry.catalog,
		}
		clear(&buffer)
		if encode_error := wal_encode_record(&buffer, &record); encode_error != .None {
			return false
		}
		written, write_error := os.write_at(store.file, buffer[:], store.wal_end)
		if write_error != nil || written != len(buffer) {
			return false
		}
		store.wal_end += i64(written)
		if store.durability == .Strict {
			if sync_error := os.sync(store.file); sync_error != nil {
				return false
			}
			sync.atomic_add(&store.syncs, 1)
		}
	}
	if store.durability == .Group && len(entries) > 0 {
		if sync_error := os.sync(store.file); sync_error != nil {
			return false
		}
		sync.atomic_add(&store.syncs, 1)
	}
	return true
}

// Rewrites the WAL with only the records after `version`. The checkpoint
// covers everything at or below it. Runs at the end of a checkpoint while
// holding the WAL lock, so no writer I/O interleaves.
@(private)
store_wal_rotate :: proc(store: ^Store, version: u64) -> bool {
	sync.mutex_lock(&store.wal_lock)
	defer sync.mutex_unlock(&store.wal_lock)

	sync.mutex_lock(&store.lock)
	tail: [dynamic]Wal_Record
	tail = make([dynamic]Wal_Record, context.temp_allocator)
	for record in store.records {
		if record.version > version {
			append(&tail, record)
		}
	}
	sync.mutex_unlock(&store.lock)

	temp_path, temp_error := filepath.join([]string{store.path, "wal.tmp"}, context.temp_allocator)
	if temp_error != nil {
		delete(tail)
		return false
	}
	file, open_error := os.open(temp_path, os.O_RDWR | os.O_CREATE | os.O_TRUNC)
	if open_error != nil {
		delete(tail)
		return false
	}
	header: [WAL_HEADER_SIZE]u8
	copy(header[:8], WAL_MAGIC)
	version_bytes := WAL_VERSION
	header[8] = u8(version_bytes)
	header[9] = u8(version_bytes >> 8)
	header[10] = u8(version_bytes >> 16)
	header[11] = u8(version_bytes >> 24)
	written, write_error := os.write(file, header[:])
	if write_error != nil || written != WAL_HEADER_SIZE {
		os.close(file)
		delete(tail)
		return false
	}
	position := i64(WAL_HEADER_SIZE)
	buffer: [dynamic]u8
	buffer = make([dynamic]u8, context.temp_allocator)
	defer delete(buffer)
	for &record in tail {
		clear(&buffer)
		if encode_error := wal_encode_record(&buffer, &record); encode_error != .None {
			os.close(file)
			delete(tail)
			return false
		}
		count, append_error := os.write_at(file, buffer[:], position)
		if append_error != nil || count != len(buffer) {
			os.close(file)
			delete(tail)
			return false
		}
		position += i64(count)
	}
	if sync_error := os.sync(file); sync_error != nil {
		os.close(file)
		delete(tail)
		return false
	}
	os.close(file)

	wal_path, wal_error := filepath.join([]string{store.path, "wal"}, context.temp_allocator)
	if wal_error != nil {
		delete(tail)
		return false
	}
	if rename_error := os.rename(temp_path, wal_path); rename_error != nil {
		delete(tail)
		return false
	}
	reopened, reopen_error := os.open(wal_path, os.O_RDWR)
	if reopen_error != nil {
		delete(tail)
		return false
	}

	sync.mutex_lock(&store.lock)
	if store.file != nil {
		os.close(store.file)
	}
	store.file = reopened
	store.wal_end = position
	clear(&store.records)
	append(&store.records, ..tail[:])
	sync.mutex_unlock(&store.lock)
	delete(tail)
	return true
}

// Replays every recovered record into a fresh kernel. The store must not be
// attached to the kernel during restore.
store_restore :: proc(store: ^Store, kernel: ^k.Kernel) -> bool {
	sync.mutex_lock(&store.lock)
	records := make([]Wal_Record, len(store.records), context.temp_allocator)
	copy(records, store.records[:])
	durable := store.durable
	sync.mutex_unlock(&store.lock)

	// The checkpoint supplies the base state; only later WAL records replay.
	if !store_materialize_checkpoint(store, kernel) {
		return false
	}

	// Records published in one group share a version. Replay each version as
	// one transaction so set semantics (for example a functional key retract
	// and assert in one commit) are preserved.
	group_start := 0
	for group_start < len(records) {
		version := records[group_start].version
		group_end := group_start
		for group_end < len(records) && records[group_end].version == version {
			group_end += 1
		}
		if version <= store.checkpoint_version {
			group_start = group_end
			continue
		}

		for record_index in group_start ..< group_end {
			for catalog in records[record_index].catalog {
				created, create_error := k.kernel_create_relation(kernel, catalog.metadata)
				if create_error == .Duplicate_Relation_Name || create_error == .Invalid_Metadata {
					continue
				}
				if create_error != .None {
					return false
				}
				k.snapshot_release(created)
			}
		}

		transaction := k.kernel_begin(kernel)
		has_writes := false
		for record_index in group_start ..< group_end {
			for write in records[record_index].writes {
				has_writes = true
				error: k.Kernel_Error
				if write.assert {
					error = k.transaction_assert(&transaction, write.relation, write.tuple)
				} else {
					error = k.transaction_retract(&transaction, write.relation, write.tuple)
				}
				if error != .None {
					k.transaction_destroy(&transaction)
					return false
				}
			}
		}
		if !has_writes {
			k.transaction_destroy(&transaction)
		} else {
			committed, commit_error := k.transaction_commit(&transaction)
			k.transaction_destroy(&transaction)
			if commit_error != .None {
				return false
			}
			k.snapshot_release(committed)
		}
		group_start = group_end
	}

	// New commits must resume above the durable log's versions.
	if durable > 0 {
		_ = k.kernel_advance_version(kernel, durable)
	}
	return true
}

@(private)
clone_string :: proc(allocator: mem.Allocator, text: string) -> string {
	owned := make([]u8, len(text), allocator)
	copy(owned, text)
	return transmute(string)owned
}
