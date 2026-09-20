// A pooled bump allocator for short-lived kernel memory.
//
// `virtual.Arena` takes a mutex on every allocation, maps and protects pages
// incrementally, and zeroes used memory on reset. None of that is wanted for
// staging, snapshot, or block memory that is filled in one thread and reset
// every commit. A `Frame_Arena` instead chains plain heap blocks, bumps a
// cursor per allocation, and resets by pointer: no locks, no `mprotect`, no
// zeroing. Blocks are kept across resets, so a pooled arena's capacity is
// reused instead of re-mapped.
package kernel

import "base:runtime"

Frame_Block :: struct {
	data: []byte,
	used: int,
	next: ^Frame_Block,
}

Frame_Arena :: struct {
	first:      ^Frame_Block,
	current:    ^Frame_Block,
	block_size: int,
}

FRAME_DEFAULT_BLOCK_SIZE :: 64 * 1024
FRAME_MAX_BLOCK_SIZE :: 8 * 1024 * 1024

frame_arena_init :: proc(arena: ^Frame_Arena, block_size := FRAME_DEFAULT_BLOCK_SIZE) {
	arena.block_size = block_size
	arena.first = nil
	arena.current = nil
}

frame_arena_destroy :: proc(arena: ^Frame_Arena) {
	block := arena.first
	for block != nil {
		next := block.next
		free(raw_data(block.data), runtime.default_allocator())
		free(block, runtime.default_allocator())
		block = next
	}
	arena.first = nil
	arena.current = nil
}

// Resets the arena to its first block. All blocks stay allocated and their
// contents are left as-is; allocations overwrite them.
frame_arena_reset :: proc(arena: ^Frame_Arena) {
	for block := arena.first; block != nil; block = block.next {
		block.used = 0
	}
	arena.current = arena.first
}

frame_arena_allocator :: proc(arena: ^Frame_Arena) -> runtime.Allocator {
	return runtime.Allocator {
		procedure = frame_alloc_proc,
		data      = arena,
	}
}

@(private)
frame_block_create :: proc(arena: ^Frame_Arena, capacity: int) -> ^Frame_Block {
	block := new(Frame_Block, runtime.default_allocator())
	data, err := make([]byte, capacity, runtime.default_allocator())
	if err != nil {
		panic("frame arena block allocation failed")
	}
	block.data = data
	block.used = 0
	block.next = nil

	if arena.block_size < FRAME_MAX_BLOCK_SIZE {
		arena.block_size = min(arena.block_size * 2, FRAME_MAX_BLOCK_SIZE)
	}
	return block
}

@(private)
frame_alloc_proc :: proc(
	allocator_data: rawptr,
	mode: runtime.Allocator_Mode,
	size, alignment: int,
	old_memory: rawptr,
	old_size: int,
	location := #caller_location,
) -> ([]byte, runtime.Allocator_Error) {
	arena := (^Frame_Arena)(allocator_data)
	switch mode {
	case .Alloc, .Alloc_Non_Zeroed:
		// Deliberately not zeroed, even for `.Alloc`: the arena hands back
		// recycled blocks and every caller overwrites what it allocates. Odin
		// expects `.Alloc` to return zeroed memory, so users of this allocator
		// must not rely on `new`/`make` zeroing; assign a struct literal or
		// write every field (see the `Relation_Block` constructors).
		if size == 0 {
			return nil, nil
		}
		for {
			if arena.current == nil {
				block := frame_block_create(arena, max(size + alignment, arena.block_size))
				arena.first = block
				arena.current = block
			}
			block := arena.current
			offset := (block.used + alignment - 1) & ~(alignment - 1)
			if offset + size <= len(block.data) {
				block.used = offset + size
				return block.data[offset:offset + size], nil
			}
			if block.next != nil {
				block.next.used = 0
				arena.current = block.next
				continue
			}
			created := frame_block_create(arena, max(size + alignment, arena.block_size))
			block.next = created
			arena.current = created
		}

	case .Free:
		// A bump arena reclaims everything at reset, so a freed allocation
		// simply stops being used. Reporting '.Mode_Not_Implemented' here would
		// break Odin's growth path for a `[dynamic]` built on this allocator:
		// when `.Resize` is unimplemented the runtime allocates a new block,
		// copies, and frees the old one, and an error from that free makes the
		// whole resize fail even though the copy already happened.
		return nil, nil

	case .Free_All:
		frame_arena_reset(arena)
		return nil, nil

	case .Resize, .Resize_Non_Zeroed:
		return nil, .Mode_Not_Implemented

	case .Query_Features:
		set := (^runtime.Allocator_Mode_Set)(old_memory)
		if set != nil {
			set^ = {.Alloc, .Alloc_Non_Zeroed, .Free, .Free_All}
		}
		return nil, nil

	case .Query_Info:
		return nil, .Mode_Not_Implemented
	}
	return nil, nil
}
