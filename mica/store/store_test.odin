package store

import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:sync"
import "core:testing"
import "core:time"
import k "../kernel"
import v "../var"

@(private)
round_trip :: proc(t: ^testing.T, value: v.Value) {
	out: [dynamic]u8
	defer delete(out)
	encode_error := codec_encode_value(&out, value)
	testing.expectf(t, encode_error == .None, "encode failed: %v", encode_error)
	if encode_error != .None {
		return
	}
	cursor := 0
	decoded, decode_error := codec_decode_value(out[:], &cursor, context.temp_allocator)
	testing.expectf(t, decode_error == .None, "decode failed: %v", decode_error)
	if decode_error != .None {
		return
	}
	testing.expectf(t, v.value_eq(value, decoded), "value mismatch")
}

@(test)
test_codec_round_trip :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	round_trip(t, v.value_bool(true))
	integer, _ := v.value_int(-123456)
	round_trip(t, integer)
	float, _ := v.value_float(1.5)
	round_trip(t, float)
	identity, _ := v.value_identity_raw(0x1000)
	round_trip(t, identity)
	round_trip(t, v.value_symbol(v.symbol_intern("example")))
	round_trip(t, v.value_error_code(v.symbol_intern("E_TEST")))
	round_trip(t, v.value_string(context.temp_allocator, "hello \u00e9"))
	bytes := []u8{1, 2, 3, 255}
	round_trip(t, v.value_bytes(context.temp_allocator, bytes))

	list := v.value_list(context.temp_allocator, []v.Value{v.value_bool(false), v.value_symbol(v.symbol_intern("x"))})
	round_trip(t, list)
	one, _ := v.value_int(1)
	two, _ := v.value_int(2)
	map_value := v.value_map(context.temp_allocator, []v.Map_Entry{
		{key = v.value_symbol(v.symbol_intern("a")), value = one},
		{key = v.value_symbol(v.symbol_intern("b")), value = two},
	})
	round_trip(t, map_value)
	range_value := v.value_range(context.temp_allocator, one, two, true)
	round_trip(t, range_value)
	error_value := v.value_error(
		context.temp_allocator,
		v.symbol_intern("E_BAD"),
		"bad thing",
		true,
		one,
		true,
	)
	round_trip(t, error_value)
	frob := v.value_frob(context.temp_allocator, v.Identity(0x2000), two)
	round_trip(t, frob)

	heading := []v.Symbol{v.symbol_intern("a"), v.symbol_intern("b")}
	rows := []v.Tuple{v.tuple_new(context.temp_allocator, []v.Value{one, two})}
	relation, relation_error := v.value_relation(context.temp_allocator, heading, rows)
	testing.expect_value(t, relation_error, v.Relation_Value_Error.None)
	round_trip(t, relation)
	round_trip(t, v.value_empty_relation())
}

@(test)
test_codec_rejects_non_persistable :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	out: [dynamic]u8
	defer delete(out)
	capability, capability_ok := v.value_capability_raw(1)
	testing.expect(t, capability_ok)
	testing.expect_value(t, codec_encode_value(&out, capability), Codec_Error.Not_Persistable)
}

@(test)
test_store_admission_budget :: proc(t: ^testing.T) {
	store: Store
	store_init(&store, Store_Options{budget_bytes = 100, timeout = 20 * time.Millisecond})
	defer store_destroy(&store)

	first, first_ok := store_admit_hook(&store, 80)
	testing.expect(t, first_ok)
	testing.expect(t, first != 0)

	// The budget is exhausted; a second reservation times out.
	_, second_ok := store_admit_hook(&store, 80)
	testing.expect(t, !second_ok)

	// Releasing the first reservation makes room again.
	store_release_hook(&store, first)
	third, third_ok := store_admit_hook(&store, 80)
	testing.expect(t, third_ok)
	store_release_hook(&store, third)
	testing.expect_value(t, store_reserved_bytes(&store), i64(0))
}

@(private)
create_named_relation :: proc(t: ^testing.T, kernel: ^k.Kernel, id: u32, name: string, arity: u16, durability: k.Relation_Durability) {
	metadata := k.relation_metadata(k.Relation_ID(id), v.symbol_intern(name), arity)
	metadata.durability = durability
	created, create_error := k.kernel_create_relation(kernel, metadata)
	testing.expectf(t, create_error == k.Kernel_Error.None, "create failed: %v", create_error)
	if create_error == k.Kernel_Error.None {
		k.snapshot_release(created)
	}
}

@(test)
test_kernel_persist_pipeline :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	kernel: k.Kernel
	k.kernel_init(&kernel)
	defer k.kernel_destroy(&kernel)

	store: Store
	store_init(&store)
	defer store_destroy(&store)
	store_attach(&store, &kernel)

	create_named_relation(t, &kernel, 1, "Durable", 1, .Durable)
	create_named_relation(t, &kernel, 2, "Volatile", 1, .Volatile)

	tx := k.kernel_begin(&kernel)
	one, _ := v.value_int(1)
	two, _ := v.value_int(2)
	testing.expect_value(
		t,
		k.transaction_assert(&tx, 1, v.tuple_new(context.temp_allocator, []v.Value{one})),
		k.Kernel_Error.None,
	)
	testing.expect_value(
		t,
		k.transaction_assert(&tx, 2, v.tuple_new(context.temp_allocator, []v.Value{two})),
		k.Kernel_Error.None,
	)
	committed, commit_error := k.transaction_commit(&tx)
	k.transaction_destroy(&tx)
	testing.expectf(t, commit_error == k.Kernel_Error.None, "commit failed: %v", commit_error)
	if commit_error != k.Kernel_Error.None {
		return
	}
	defer k.snapshot_release(committed)

	store_wait_durable(&store, committed.version)
	testing.expect(t, store_durable_version(&store) >= committed.version)

	// Catalogue records for the durable relation, plus the write record; the
	// volatile relation contributes nothing.
	testing.expect(t, store_record_count(&store) >= 1)
	sync.mutex_lock(&store.lock)
	write_records := 0
	wrote_durable := false
	for record in store.records {
		write_records += len(record.writes)
		for write in record.writes {
			if write.relation == k.Relation_ID(1) && write.assert {
				wrote_durable = true
			}
			testing.expect(t, write.relation != k.Relation_ID(2))
		}
	}
	testing.expect_value(t, write_records, 1)
	testing.expect(t, wrote_durable)
	sync.mutex_unlock(&store.lock)
}

@(test)
test_kernel_admission_overload :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	kernel: k.Kernel
	k.kernel_init(&kernel)
	defer k.kernel_destroy(&kernel)

	store: Store
	store_init(&store, Store_Options{budget_bytes = 1, timeout = 10 * time.Millisecond})
	defer store_destroy(&store)
	store_attach(&store, &kernel)

	create_named_relation(t, &kernel, 1, "TooBig", 1, .Durable)

	tx := k.kernel_begin(&kernel)
	one, _ := v.value_int(1)
	testing.expect_value(
		t,
		k.transaction_assert(&tx, 1, v.tuple_new(context.temp_allocator, []v.Value{one})),
		k.Kernel_Error.None,
	)
	before := kernel.current.version
	committed, commit_error := k.transaction_commit(&tx)
	k.transaction_destroy(&tx)
	if committed != nil {
		k.snapshot_release(committed)
	}
	testing.expect_value(t, commit_error, k.Kernel_Error.Overloaded)
	testing.expect_value(t, kernel.current.version, before)
}

@(private)
temp_store_path :: proc(t: ^testing.T, name: string) -> string {
	directory, directory_error := os.temp_dir(context.temp_allocator)
	testing.expectf(t, directory_error == nil, "temp dir: %v", directory_error)
	if directory_error != nil {
		return ""
	}
	path, join_error := filepath.join(
		[]string{directory, name},
		context.temp_allocator,
	)
	testing.expectf(t, join_error == nil, "join: %v", join_error)
	return path
}

@(private)
file_relation_rows :: proc(t: ^testing.T, kernel: ^k.Kernel, name: string) -> int {
	snapshot := k.kernel_snapshot(kernel)
	metadata, found := k.snapshot_relation_metadata_named(snapshot, v.symbol_intern(name))
	k.snapshot_release(snapshot)
	if !found {
		return -1
	}
	rows: [dynamic]v.Tuple
	defer delete(rows)
	k.kernel_scan_into(kernel, metadata.id, []v.Binding{{}}, &rows)
	return len(rows)
}

@(test)
test_file_wal_round_trip :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	path := temp_store_path(t, "mica_store_round_trip")
	if path == "" {
		return
	}
	os.remove_all(path)
	defer os.remove_all(path)

	{
		kernel: k.Kernel
		k.kernel_init(&kernel)
		store: Store
		testing.expect(
			t,
			store_open(
				&store,
				Store_Options{mode = .File, path = path, durability = .Group},
			),
		)
		store_attach(&store, &kernel)
		create_named_relation(t, &kernel, 1, "Kept", 1, .Durable)
		create_named_relation(t, &kernel, 2, "Gone", 1, .Volatile)

		tx := k.kernel_begin(&kernel)
		one, _ := v.value_int(1)
		two, _ := v.value_int(2)
		testing.expect_value(
			t,
			k.transaction_assert(&tx, 1, v.tuple_new(context.temp_allocator, []v.Value{one})),
			k.Kernel_Error.None,
		)
		testing.expect_value(
			t,
			k.transaction_assert(&tx, 1, v.tuple_new(context.temp_allocator, []v.Value{two})),
			k.Kernel_Error.None,
		)
		testing.expect_value(
			t,
			k.transaction_assert(&tx, 2, v.tuple_new(context.temp_allocator, []v.Value{two})),
			k.Kernel_Error.None,
		)
		committed, commit_error := k.transaction_commit(&tx)
		k.transaction_destroy(&tx)
		testing.expectf(t, commit_error == k.Kernel_Error.None, "commit: %v", commit_error)
		if commit_error != k.Kernel_Error.None {
			store_destroy(&store)
			k.kernel_destroy(&kernel)
			return
		}
		latest := committed.version
		k.snapshot_release(committed)
		store_wait_durable(&store, latest)
		testing.expect(t, store_sync_count(&store) >= 1)
		k.kernel_detach_store(&kernel)
		store_destroy(&store)
		k.kernel_destroy(&kernel)
	}

	kernel: k.Kernel
	k.kernel_init(&kernel)
	defer k.kernel_destroy(&kernel)
	store: Store
	testing.expect(
		t,
		store_open(&store, Store_Options{mode = .File, path = path, durability = .Group}),
	)
	defer store_destroy(&store)
	testing.expect(t, store_durable_version(&store) >= 1)
	testing.expect(t, store_restore(&store, &kernel))
	testing.expect_value(t, file_relation_rows(t, &kernel, "Kept"), 2)
	// Volatile schema is durable; its facts are not.
	testing.expect_value(t, file_relation_rows(t, &kernel, "Gone"), 0)
}

@(test)
test_file_wal_truncated_tail :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	path := temp_store_path(t, "mica_store_truncated")
	if path == "" {
		return
	}
	os.remove_all(path)
	defer os.remove_all(path)

	latest: u64
	{
		kernel: k.Kernel
		k.kernel_init(&kernel)
		store: Store
		testing.expect(
			t,
			store_open(
				&store,
				Store_Options{mode = .File, path = path, durability = .Group},
			),
		)
		store_attach(&store, &kernel)
		create_named_relation(t, &kernel, 1, "Kept", 1, .Durable)
		tx := k.kernel_begin(&kernel)
		one, _ := v.value_int(1)
		k.transaction_assert(&tx, 1, v.tuple_new(context.temp_allocator, []v.Value{one}))
		committed, commit_error := k.transaction_commit(&tx)
		k.transaction_destroy(&tx)
		testing.expect(t, commit_error == k.Kernel_Error.None)
		latest = committed.version
		k.snapshot_release(committed)
		store_wait_durable(&store, latest)
		k.kernel_detach_store(&kernel)
		store_destroy(&store)
		k.kernel_destroy(&kernel)
	}

	// Append a torn record header and reopening must drop it.
	wal_path, _ := filepath.join([]string{path, "wal"}, context.temp_allocator)
	wal_file, open_error := os.open(wal_path, os.O_WRONLY | os.O_APPEND)
	testing.expect(t, open_error == nil)
	if open_error == nil {
		garbage := []u8{0xde, 0xad, 0xbe}
		written, write_error := os.write(wal_file, garbage)
		testing.expect(t, write_error == nil && written == len(garbage))
		os.close(wal_file)
	}

	kernel: k.Kernel
	k.kernel_init(&kernel)
	defer k.kernel_destroy(&kernel)
	store: Store
	testing.expect(
		t,
		store_open(&store, Store_Options{mode = .File, path = path, durability = .Group}),
	)
	testing.expect_value(t, store_durable_version(&store), latest)
	testing.expect(t, !store_failed(&store))
	store_destroy(&store)

	// The torn tail is truncated, so reopening again is clean.
	second: Store
	testing.expect(
		t,
		store_open(&second, Store_Options{mode = .File, path = path, durability = .Group}),
	)
	testing.expect_value(t, store_durable_version(&second), latest)
	store_destroy(&second)
}

@(test)
test_file_wal_durability_none_does_not_sync :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	path := temp_store_path(t, "mica_store_no_sync")
	if path == "" {
		return
	}
	os.remove_all(path)
	defer os.remove_all(path)

	kernel: k.Kernel
	k.kernel_init(&kernel)
	defer k.kernel_destroy(&kernel)
	store: Store
	testing.expect(
		t,
		store_open(&store, Store_Options{mode = .File, path = path, durability = .None}),
	)
	defer store_destroy(&store)
	store_attach(&store, &kernel)
	create_named_relation(t, &kernel, 1, "NoSync", 1, .Durable)
	tx := k.kernel_begin(&kernel)
	one, _ := v.value_int(1)
	k.transaction_assert(&tx, 1, v.tuple_new(context.temp_allocator, []v.Value{one}))
	committed, commit_error := k.transaction_commit(&tx)
	k.transaction_destroy(&tx)
	testing.expect(t, commit_error == k.Kernel_Error.None)
	if commit_error == k.Kernel_Error.None {
		store_wait_durable(&store, committed.version)
		k.snapshot_release(committed)
	}
	testing.expect_value(t, store_sync_count(&store), u64(0))
}

@(test)
test_checkpoint_round_trip :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	path := temp_store_path(t, "mica_store_checkpoint")
	if path == "" {
		return
	}
	os.remove_all(path)
	defer os.remove_all(path)

	checkpoint_version: u64
	{
		kernel: k.Kernel
		k.kernel_init(&kernel)
		store: Store
		testing.expect(
			t,
			store_open(
				&store,
				Store_Options{mode = .File, path = path, durability = .Group},
			),
		)
		store_attach(&store, &kernel)
		create_named_relation(t, &kernel, 1, "Kept", 1, .Durable)
		create_named_relation(t, &kernel, 2, "Gone", 1, .Volatile)

		tx := k.kernel_begin(&kernel)
		for index in 0 ..< 300 {
			number, _ := v.value_int(i64(index))
			testing.expect_value(
				t,
				k.transaction_assert(&tx, 1, v.tuple_new(context.temp_allocator, []v.Value{number})),
				k.Kernel_Error.None,
			)
		}
		volatile_number, _ := v.value_int(7)
		testing.expect_value(
			t,
			k.transaction_assert(&tx, 2, v.tuple_new(context.temp_allocator, []v.Value{volatile_number})),
			k.Kernel_Error.None,
		)
		committed, commit_error := k.transaction_commit(&tx)
		k.transaction_destroy(&tx)
		testing.expect(t, commit_error == k.Kernel_Error.None)
		if commit_error != k.Kernel_Error.None {
			store_destroy(&store)
			k.kernel_destroy(&kernel)
			return
		}
		k.snapshot_release(committed)

		testing.expect(t, store_checkpoint(&store, &kernel))
		checkpoint_version = store_checkpoint_version(&store)
		pages_after_checkpoint := store_page_count(&store)
		testing.expect(t, pages_after_checkpoint >= 1)

		// A small tail after the checkpoint.
		tx2 := k.kernel_begin(&kernel)
		tail_number, _ := v.value_int(999)
		k.transaction_assert(&tx2, 1, v.tuple_new(context.temp_allocator, []v.Value{tail_number}))
		tail, tail_error := k.transaction_commit(&tx2)
		k.transaction_destroy(&tx2)
		testing.expect(t, tail_error == k.Kernel_Error.None)
		if tail_error == k.Kernel_Error.None {
			store_wait_durable(&store, tail.version)
			k.snapshot_release(tail)
		}

		// A second checkpoint persists only the chunks the tail touched.
		testing.expect(t, store_checkpoint(&store, &kernel))
		checkpoint_version = store_checkpoint_version(&store)
		// The checkpoint truncates the log; nothing was committed after it.
		testing.expect_value(t, store_record_count(&store), 0)
		pages_after_tail := store_page_count(&store)
		testing.expectf(
			t,
			pages_after_tail - pages_after_checkpoint <= 2,
			"tail checkpoint added %d pages",
			pages_after_tail - pages_after_checkpoint,
		)

		k.kernel_detach_store(&kernel)
		store_destroy(&store)
		k.kernel_destroy(&kernel)
	}

	kernel: k.Kernel
	k.kernel_init(&kernel)
	defer k.kernel_destroy(&kernel)
	store: Store
	testing.expect(
		t,
		store_open(&store, Store_Options{mode = .File, path = path, durability = .Group}),
	)
	defer store_destroy(&store)
	testing.expect_value(t, store_checkpoint_version(&store), checkpoint_version)
	testing.expect(t, store_restore(&store, &kernel))
	testing.expect_value(t, file_relation_rows(t, &kernel, "Kept"), 301)
	testing.expect_value(t, file_relation_rows(t, &kernel, "Gone"), 0)
}

@(private)
commit_single :: proc(t: ^testing.T, kernel: ^k.Kernel, relation: k.Relation_ID, value: i64) {
	tx := k.kernel_begin(kernel)
	number, _ := v.value_int(value)
	testing.expect_value(
		t,
		k.transaction_assert(&tx, relation, v.tuple_new(context.temp_allocator, []v.Value{number})),
		k.Kernel_Error.None,
	)
	committed, commit_error := k.transaction_commit(&tx)
	k.transaction_destroy(&tx)
	testing.expect(t, commit_error == k.Kernel_Error.None)
	if commit_error == k.Kernel_Error.None {
		k.snapshot_release(committed)
	}
}

@(private)
restore_at_version :: proc(
	t: ^testing.T,
	path: string,
	version: u64,
) -> (
	k.Kernel,
	^Store,
	bool,
) {
	kernel: k.Kernel
	k.kernel_init(&kernel)
	store := new(Store, context.allocator)
	if !store_open(store, Store_Options {
		mode    = .File,
		path    = path,
		version = version,
	}) {
		free(store, context.allocator)
		k.kernel_destroy(&kernel)
		return {}, nil, false
	}
	if !store_restore(store, &kernel) {
		store_destroy(store)
		free(store, context.allocator)
		k.kernel_destroy(&kernel)
		return {}, nil, false
	}
	return kernel, store, true
}

@(private)
count_rows :: proc(kernel: ^k.Kernel, name: string) -> int {
	snapshot := k.kernel_snapshot(kernel)
	metadata, found := k.snapshot_relation_metadata_named(snapshot, v.symbol_intern(name))
	k.snapshot_release(snapshot)
	if !found {
		return -1
	}
	rows: [dynamic]v.Tuple
	defer delete(rows)
	k.kernel_scan_into(kernel, metadata.id, []v.Binding{{}}, &rows)
	return len(rows)
}

@(test)
test_manifest_retention_and_point_in_time :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	path := temp_store_path(t, "mica_store_history")
	if path == "" {
		return
	}
	os.remove_all(path)
	defer os.remove_all(path)

	first_version: u64
	{
		kernel: k.Kernel
		k.kernel_init(&kernel)
		store: Store
		testing.expect(
			t,
			store_open(&store, Store_Options{mode = .File, path = path, durability = .Group}),
		)
		store_attach(&store, &kernel)
		create_named_relation(t, &kernel, 1, "K", 1, .Durable)

		// Six commits and checkpoints; retention keeps the last four.
		for index in 1 ..= 6 {
			commit_single(t, &kernel, 1, i64(index))
			testing.expect(t, store_checkpoint(&store, &kernel))
		}
		testing.expect_value(t, store_retained_version_count(&store), MANIFEST_RETENTION)
		first_version = store_oldest_retained_version(&store)
		testing.expect(t, first_version != 0)
		k.kernel_detach_store(&kernel)
		store_destroy(&store)
		k.kernel_destroy(&kernel)
	}

	// Point in time: the oldest retained checkpoint follows the third commit.
	kernel, store, restored := restore_at_version(t, path, first_version)
	if restored {
		testing.expect_value(t, count_rows(&kernel, "K"), 3)
		store_destroy(store)
		free(store, context.allocator)
		k.kernel_destroy(&kernel)
	}

	// Latest: every row.
	latest_kernel, latest_store, latest_ok := restore_at_version(t, path, 0)
	if latest_ok {
		testing.expect_value(t, count_rows(&latest_kernel, "K"), 6)
		store_destroy(latest_store)
		free(latest_store, context.allocator)
		k.kernel_destroy(&latest_kernel)
	}
}

@(test)
test_page_compaction :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	path := temp_store_path(t, "mica_store_compact")
	if path == "" {
		return
	}
	os.remove_all(path)
	defer os.remove_all(path)

	{
		kernel: k.Kernel
		k.kernel_init(&kernel)
		store: Store
		testing.expect(
			t,
			store_open(&store, Store_Options{mode = .File, path = path, durability = .Group}),
		)
		store_attach(&store, &kernel)
		create_named_relation(t, &kernel, 1, "K", 1, .Durable)

		tx := k.kernel_begin(&kernel)
		for index in 0 ..< 300 {
			number, _ := v.value_int(i64(index))
			k.transaction_assert(&tx, 1, v.tuple_new(context.temp_allocator, []v.Value{number}))
		}
		committed, commit_error := k.transaction_commit(&tx)
		k.transaction_destroy(&tx)
		testing.expect(t, commit_error == k.Kernel_Error.None)
		if commit_error == k.Kernel_Error.None {
			k.snapshot_release(committed)
		}
		testing.expect(t, store_checkpoint(&store, &kernel))

		// Churn enough that pruning leaves dead pages behind.
		for index in 0 ..< 6 {
			commit_single(t, &kernel, 1, i64(1000 + index))
			testing.expect(t, store_checkpoint(&store, &kernel))
			}
		pages_before := store_page_count(&store)
		testing.expect(t, store_pages_compact(&store))
		pages_after := store_page_count(&store)
		testing.expectf(t, pages_after < pages_before, "pages %d -> %d", pages_before, pages_after)

		// The store stays writable and checkpoints after compaction.
		commit_single(t, &kernel, 1, 2000)
		testing.expect(t, store_checkpoint(&store, &kernel))
		k.kernel_detach_store(&kernel)
		store_destroy(&store)
		k.kernel_destroy(&kernel)
	}

	kernel, store, restored := restore_at_version(t, path, 0)
	if restored {
		testing.expect_value(t, count_rows(&kernel, "K"), 307)
		store_destroy(store)
		free(store, context.allocator)
		k.kernel_destroy(&kernel)
	}
}

@(test)
test_store_lock :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	path := temp_store_path(t, "mica_store_lock")
	if path == "" {
		return
	}
	os.remove_all(path)
	defer os.remove_all(path)

	first: Store
	testing.expect(t, store_open(&first, Store_Options{mode = .File, path = path}))

	second: Store
	testing.expect(t, !store_open(&second, Store_Options{mode = .File, path = path}))
	testing.expect(
		t,
		strings.contains(store_last_error(&second), "locked"),
	)
	store_destroy(&first)

	third: Store
	testing.expect(t, store_open(&third, Store_Options{mode = .File, path = path}))
	store_destroy(&third)
}

@(test)
test_auto_checkpoint_on_wal_bytes :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	path := temp_store_path(t, "mica_store_auto_checkpoint")
	if path == "" {
		return
	}
	os.remove_all(path)
	defer os.remove_all(path)

	kernel: k.Kernel
	k.kernel_init(&kernel)
	defer k.kernel_destroy(&kernel)
	store: Store
	testing.expect(
		t,
		store_open(&store, Store_Options {
			mode             = .File,
			path             = path,
			durability       = .Group,
			checkpoint_bytes = 1024,
		}),
	)
	defer store_destroy(&store)
	store_attach(&store, &kernel)
	create_named_relation(t, &kernel, 1, "Auto", 1, .Durable)

	for index in 0 ..< 60 {
		commit_single(t, &kernel, 1, i64(index))
	}
	deadline := time.tick_now()
	for time.tick_since(deadline) < 5 * time.Second {
		if store_checkpoint_version(&store) > 0 {
			break
		}
		time.sleep(2 * time.Millisecond)
	}
	testing.expect(t, store_checkpoint_version(&store) > 0)
	k.kernel_detach_store(&kernel)
}

// A functional replacement (retract the old key value, assert the new) must
// replay from the WAL. Sorting staged writes by tuple value puts the assert
// before the retract, which replays as a functional-key conflict.
@(test)
test_file_wal_replays_functional_replacement :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	path := temp_store_path(t, "mica_store_functional")
	if path == "" {
		return
	}
	os.remove_all(path)
	defer os.remove_all(path)

	{
		kernel: k.Kernel
		k.kernel_init(&kernel)
		store: Store
		testing.expect(
			t,
			store_open(&store, Store_Options{mode = .File, path = path, durability = .Group}),
		)
		store_attach(&store, &kernel)
		metadata := k.relation_metadata(1, v.symbol_intern("Current"), 2)
		metadata.conflict = k.conflict_functional([]u16{0})
		metadata.durability = .Durable
		created, create_error := k.kernel_create_relation(&kernel, metadata)
		testing.expect_value(t, create_error, k.Kernel_Error.None)
		k.snapshot_release(created)

		key, _ := v.value_int(1)
		old_value, _ := v.value_int(2)
		new_value, _ := v.value_int(1)

		tx := k.kernel_begin(&kernel)
		testing.expect_value(
			t,
			k.transaction_assert(
				&tx,
				1,
				v.tuple_new(context.temp_allocator, []v.Value{key, old_value}),
			),
			k.Kernel_Error.None,
		)
		committed, commit_error := k.transaction_commit(&tx)
		k.transaction_destroy(&tx)
		testing.expect_value(t, commit_error, k.Kernel_Error.None)
		latest := committed.version
		k.snapshot_release(committed)

		// Replace the key's value: retract (1,2), assert (1,1).
		tx2 := k.kernel_begin(&kernel)
		testing.expect_value(
			t,
			k.transaction_retract(
				&tx2,
				1,
				v.tuple_new(context.temp_allocator, []v.Value{key, old_value}),
			),
			k.Kernel_Error.None,
		)
		testing.expect_value(
			t,
			k.transaction_assert(
				&tx2,
				1,
				v.tuple_new(context.temp_allocator, []v.Value{key, new_value}),
			),
			k.Kernel_Error.None,
		)
		committed2, commit_error2 := k.transaction_commit(&tx2)
		k.transaction_destroy(&tx2)
		testing.expect_value(t, commit_error2, k.Kernel_Error.None)
		latest = committed2.version
		k.snapshot_release(committed2)

		store_wait_durable(&store, latest)
		k.kernel_detach_store(&kernel)
		store_destroy(&store)
		k.kernel_destroy(&kernel)
	}

	kernel: k.Kernel
	k.kernel_init(&kernel)
	defer k.kernel_destroy(&kernel)
	store: Store
	testing.expect(
		t,
		store_open(&store, Store_Options{mode = .File, path = path, durability = .Group}),
	)
	defer store_destroy(&store)
	testing.expect(t, store_restore(&store, &kernel))
	rows: [dynamic]v.Tuple
	defer delete(rows)
	k.kernel_scan_into(&kernel, 1, []v.Binding{{}, {}}, &rows)
	testing.expect_value(t, len(rows), 1)
	if len(rows) == 1 {
		expected, _ := v.value_int(1)
		testing.expect(t, v.value_eq(v.tuple_values(rows[0])[1], expected))
	}
}
