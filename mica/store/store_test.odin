package store

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

	// Catalogue plus one durable write; the volatile relation is skipped.
	testing.expect_value(t, store_record_count(&store), 1)
	sync.mutex_lock(&store.lock)
	record := store.records[0]
	testing.expect_value(t, len(record.writes), 1)
	if len(record.writes) == 1 {
		testing.expect_value(t, record.writes[0].relation, k.Relation_ID(1))
		testing.expect(t, record.writes[0].assert)
	}
	testing.expect(t, len(record.catalog) >= 1)
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
