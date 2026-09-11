// Microbenchmarks for the value layer.
package main

import "core:mem"
import "core:mem/virtual"

import mm "../micromeasure"
import v "../mica/var"

Var_State :: struct {
	arena:         virtual.Arena,
	alloc:         mem.Allocator,
	scratch:       virtual.Arena,
	scratch_alloc: mem.Allocator,

	symbol:           v.Symbol,
	symbol_name:      string,
	left:             v.Value,
	right:            v.Value,
	float_left:       v.Value,
	float_right:      v.Value,
	string_a:         v.Value,
	string_b:         v.Value,
	different_string: v.Value,
	tuple_a:          v.Tuple,
	tuple_b:          v.Tuple,
	list:             v.Value,

	sink: u64,
}

var_state_init :: proc() -> ^Var_State {
	state := new(Var_State)
	if err := virtual.arena_init_growing(&state.arena); err != nil {
		panic("failed to initialize var benchmark arena")
	}
	if err := virtual.arena_init_growing(&state.scratch); err != nil {
		panic("failed to initialize var scratch arena")
	}
	state.alloc = virtual.arena_allocator(&state.arena)
	state.scratch_alloc = virtual.arena_allocator(&state.scratch)

	state.symbol = v.symbol_intern("benchmark-symbol")
	state.symbol_name = "benchmark-symbol"

	left, _ := v.value_int(12345)
	right, _ := v.value_int(6789)
	state.left = left
	state.right = right

	float_left, _ := v.value_float(1.5)
	float_right, _ := v.value_float(2.25)
	state.float_left = float_left
	state.float_right = float_right

	state.string_a = v.value_string(state.alloc, "the quick brown fox jumps over the lazy dog")
	state.string_b = v.value_string(state.alloc, "the quick brown fox jumps over the lazy dog")
	state.different_string = v.value_string(
		state.alloc,
		"the quick brown fox jumps over the lazy cat",
	)

	state.tuple_a = v.tuple_new(state.alloc, []v.Value{state.left, state.string_a})
	state.tuple_b = v.tuple_new(state.alloc, []v.Value{state.right, state.different_string})
	state.list = v.value_list(state.alloc, []v.Value{state.left, state.right, state.string_a})
	return state
}

@(private)
bench_int_construct :: proc(user: rawptr, chunk: int, _: int) {
	state := (^Var_State)(user)
	accumulator := u64(0)
	for i in 0 ..< chunk {
		value, _ := v.value_int(i64(i))
		accumulator += u64(value)
	}
	state.sink = mm.black_box(accumulator)
}

@(private)
bench_int_add :: proc(user: rawptr, chunk: int, _: int) {
	state := (^Var_State)(user)
	accumulator := u64(0)
	for i in 0 ..< chunk {
		other, _ := v.value_int(i64(i & 0xff))
		value, _ := v.value_checked_add(state.left, other)
		accumulator += u64(value)
	}
	state.sink = mm.black_box(accumulator)
}

@(private)
bench_float_add :: proc(user: rawptr, chunk: int, _: int) {
	state := (^Var_State)(user)
	accumulator := u64(0)
	for i in 0 ..< chunk {
		other, _ := v.value_float(f32(i & 0x3f))
		value, _ := v.value_checked_add(state.float_left, other)
		accumulator += u64(value)
	}
	state.sink = mm.black_box(accumulator)
}

@(private)
bench_value_cmp_int :: proc(user: rawptr, chunk: int, _: int) {
	state := (^Var_State)(user)
	accumulator := u64(0)
	for _ in 0 ..< chunk {
		order := v.value_cmp(state.left, state.right)
		accumulator += u64(order)
	}
	state.sink = mm.black_box(accumulator)
}

@(private)
bench_value_eq_string :: proc(user: rawptr, chunk: int, _: int) {
	state := (^Var_State)(user)
	accumulator := u64(0)
	for _ in 0 ..< chunk {
		if v.value_eq(state.string_a, state.string_b) {
			accumulator += 1
		} else {
			accumulator += 2
		}
	}
	state.sink = mm.black_box(accumulator)
}

@(private)
bench_symbol_intern_hit :: proc(user: rawptr, chunk: int, _: int) {
	state := (^Var_State)(user)
	accumulator := u64(0)
	for _ in 0 ..< chunk {
		symbol := v.symbol_intern(state.symbol_name)
		accumulator += u64(v.symbol_id(symbol))
	}
	state.sink = mm.black_box(accumulator)
}

@(private)
bench_tuple_cmp :: proc(user: rawptr, chunk: int, _: int) {
	state := (^Var_State)(user)
	accumulator := u64(0)
	for _ in 0 ..< chunk {
		order := v.tuple_cmp(state.tuple_a, state.tuple_b)
		accumulator += u64(order)
	}
	state.sink = mm.black_box(accumulator)
}

@(private)
bench_string_create :: proc(user: rawptr, chunk: int, _: int) {
	state := (^Var_State)(user)
	virtual.arena_free_all(&state.scratch)
	accumulator := u64(0)
	for _ in 0 ..< chunk {
		value := v.value_string(state.scratch_alloc, "hello world")
		accumulator += u64(value)
	}
	state.sink = mm.black_box(accumulator)
}

@(private)
bench_list_create :: proc(user: rawptr, chunk: int, _: int) {
	state := (^Var_State)(user)
	virtual.arena_free_all(&state.scratch)
	accumulator := u64(0)
	for _ in 0 ..< chunk {
		value := v.value_list(state.scratch_alloc, []v.Value{state.left, state.right, state.left})
		accumulator += u64(value)
	}
	state.sink = mm.black_box(accumulator)
}

@(private)
bench_map_create_8 :: proc(user: rawptr, chunk: int, _: int) {
	state := (^Var_State)(user)
	virtual.arena_free_all(&state.scratch)
	accumulator := u64(0)
	for _ in 0 ..< chunk {
		entries: [8]v.Map_Entry
		for index in 0 ..< len(entries) {
			key, _ := v.value_int(i64(index))
			entries[index] = v.Map_Entry {
				key   = key,
				value = state.string_a,
			}
		}
		value := v.value_map(state.scratch_alloc, entries[:])
		accumulator += u64(value)
	}
	state.sink = mm.black_box(accumulator)
}

@(private)
bench_list_deep_copy :: proc(user: rawptr, chunk: int, _: int) {
	state := (^Var_State)(user)
	virtual.arena_free_all(&state.scratch)
	accumulator := u64(0)
	for _ in 0 ..< chunk {
		value := v.value_deep_copy(state.scratch_alloc, state.list)
		accumulator += u64(value)
	}
	state.sink = mm.black_box(accumulator)
}

register_var_benches :: proc(runner: ^mm.Runner) {
	state := var_state_init()

	value_group := mm.group(runner, "var/value", mm.throughput_ops())
	mm.bench(value_group, "int_construct", state, bench_int_construct)
	mm.bench(value_group, "int_add", state, bench_int_add)
	mm.bench(value_group, "float_add", state, bench_float_add)
	mm.bench(value_group, "value_cmp_int", state, bench_value_cmp_int)
	mm.bench(value_group, "value_eq_string", state, bench_value_eq_string)
	mm.bench(value_group, "symbol_intern_hit", state, bench_symbol_intern_hit)
	mm.bench(value_group, "tuple_cmp", state, bench_tuple_cmp)

	heap_group := mm.group(runner, "var/heap", mm.throughput_ops())
	mm.bench_capped(heap_group, "string_create", state, bench_string_create, 1 << 16)
	mm.bench_capped(heap_group, "list_create_3", state, bench_list_create, 1 << 16)
	mm.bench_capped(heap_group, "map_create_8", state, bench_map_create_8, 1 << 14)
	mm.bench_capped(heap_group, "list_deep_copy_3", state, bench_list_deep_copy, 1 << 15)
}
