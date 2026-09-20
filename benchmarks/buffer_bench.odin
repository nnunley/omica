// Microbenchmarks for the buffer piece tree.
//
// The point of the tree is that an edit costs structure proportional to its
// depth and its own size, not to the document. These benches measure the
// per-edit cost against a fixed base document, plus reads, line lookup, and the
// provenance walk.
package main

import "core:fmt"
import "core:mem"
import "core:mem/virtual"
import "core:strings"

import mm "../micromeasure"
import b "../mica/buffer"

BUFFER_BENCH_LINES :: 2000

Buffer_State :: struct {
	arena:         virtual.Arena,
	alloc:         mem.Allocator,
	scratch:       virtual.Arena,
	scratch_alloc: mem.Allocator,
	store:         b.Store,
	base:          ^b.Piece_Node,
	base_scalars:  u64,
	sink:          u64,
}

buffer_state_init :: proc() -> ^Buffer_State {
	state := new(Buffer_State)
	if err := virtual.arena_init_growing(&state.arena); err != nil {
		panic("failed to initialize buffer benchmark arena")
	}
	if err := virtual.arena_init_growing(&state.scratch); err != nil {
		panic("failed to initialize buffer benchmark scratch arena")
	}
	state.alloc = virtual.arena_allocator(&state.arena)
	state.scratch_alloc = virtual.arena_allocator(&state.scratch)
	b.store_init(&state.store, state.alloc)

	builder: strings.Builder
	strings.builder_init(&builder, state.alloc)
	for line in 0 ..< BUFFER_BENCH_LINES {
		fmt.sbprintf(&builder, "line %d: the quick brown fox jumps over the lazy dog\n", line)
	}
	text := strings.to_string(builder)
	state.base = b.tree_from_text(&state.store, text, .Original)
	state.base_scalars = b.tree_scalars(state.base)
	return state
}

@(private)
Span_Counter :: struct {
	bytes: u64,
	spans: u64,
}

@(private)
count_span_bytes :: proc(user: rawptr, text: string, offset: u64) -> bool {
	counter := cast(^Span_Counter)user
	counter.bytes += u64(len(text))
	counter.spans += 1
	return true
}

@(private)
bench_buffer_append :: proc(user: rawptr, chunk_size: int, chunk_num: int) {
	state := cast(^Buffer_State)user
	at := state.base_scalars
	for _ in 0 ..< chunk_size {
		edited := b.tree_edit(&state.store, state.base, at, 0, "x", .Added)
		state.sink = mm.black_box(state.sink + b.tree_scalars(edited))
		b.tree_release(&state.store, edited)
	}
}

@(private)
bench_buffer_insert_middle :: proc(user: rawptr, chunk_size: int, chunk_num: int) {
	state := cast(^Buffer_State)user
	at := state.base_scalars / 2
	for _ in 0 ..< chunk_size {
		edited := b.tree_edit(&state.store, state.base, at, 0, "x", .Added)
		state.sink = mm.black_box(state.sink + b.tree_scalars(edited))
		b.tree_release(&state.store, edited)
	}
}

@(private)
bench_buffer_replace_middle :: proc(user: rawptr, chunk_size: int, chunk_num: int) {
	state := cast(^Buffer_State)user
	at := state.base_scalars / 2
	for _ in 0 ..< chunk_size {
		edited := b.tree_edit(&state.store, state.base, at, 4, "XYZ", .Added)
		state.sink = mm.black_box(state.sink + b.tree_scalars(edited))
		b.tree_release(&state.store, edited)
	}
}

@(private)
bench_buffer_window_read :: proc(user: rawptr, chunk_size: int, chunk_num: int) {
	state := cast(^Buffer_State)user
	start := state.base_scalars / 2
	counter: Span_Counter
	for _ in 0 ..< chunk_size {
		b.tree_visit_spans(state.base, start, start + 800, count_span_bytes, &counter)
	}
	state.sink = mm.black_box(state.sink + counter.bytes)
}

@(private)
bench_buffer_line_lookup :: proc(user: rawptr, chunk_size: int, chunk_num: int) {
	state := cast(^Buffer_State)user
	for index in 0 ..< chunk_size {
		line := u64(index % BUFFER_BENCH_LINES)
		state.sink = mm.black_box(state.sink + b.tree_line_start(state.base, line))
	}
}

@(private)
bench_buffer_retain_release :: proc(user: rawptr, chunk_size: int, chunk_num: int) {
	state := cast(^Buffer_State)user
	for _ in 0 ..< chunk_size {
		held := b.tree_retain(state.base)
		b.tree_release(&state.store, held)
	}
	state.sink = mm.black_box(state.sink + b.tree_scalars(state.base))
}

@(private)
bench_buffer_provenance :: proc(user: rawptr, chunk_size: int, chunk_num: int) {
	state := cast(^Buffer_State)user
	edited := b.tree_edit(&state.store, state.base, state.base_scalars / 2, 4, "XYZ", .Added)
	defer b.tree_release(&state.store, edited)

	for _ in 0 ..< chunk_size {
		// The walk allocates from scratch, which is reset each iteration so the
		// benchmark measures work rather than growth.
		free_all(state.scratch_alloc)
		delta, err := b.tree_provenance(&state.store, state.base, edited, state.scratch_alloc)
		if err == .None {
			state.sink = mm.black_box(state.sink + u64(len(delta.replacements)))
		}
	}
}

register_buffer_benches :: proc(runner: ^mm.Runner) {
	state := buffer_state_init()

	edit_group := mm.group(runner, "buffer/edit", mm.throughput_ops())
	mm.bench_capped(edit_group, "append", state, bench_buffer_append, 1 << 14)
	mm.bench_capped(edit_group, "insert_middle", state, bench_buffer_insert_middle, 1 << 14)
	mm.bench_capped(edit_group, "replace_middle", state, bench_buffer_replace_middle, 1 << 14)

	read_group := mm.group(runner, "buffer/read", mm.throughput_ops())
	mm.bench(read_group, "window_800_scalars", state, bench_buffer_window_read)
	mm.bench(read_group, "line_lookup", state, bench_buffer_line_lookup)
	mm.bench(read_group, "retain_release", state, bench_buffer_retain_release)

	provenance_group := mm.group(runner, "buffer/provenance", mm.throughput_ops())
	mm.bench_capped(
		provenance_group,
		"walk_vs_base",
		state,
		bench_buffer_provenance,
		1 << 12,
	)
}
