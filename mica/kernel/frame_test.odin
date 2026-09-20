// Tests for the staging frame arena.
package kernel

import "core:testing"

// A `[dynamic]` built on the frame arena must be able to grow.
//
// Odin grows a dynamic array by resizing in place when the allocator supports
// it, and otherwise by allocating a new block, copying, and freeing the old one.
// The frame arena has no in-place resize, so that fallback is the only path, and
// it fails outright if the allocator refuses `.Free`. A refusal silently
// truncated the array: the copy had already happened, but the reserve reported
// failure and the array kept its old, too-small buffer. That regressed buffer
// compaction, which renders text into an arena-backed builder to re-chunk it.
@(test)
test_frame_arena_supports_dynamic_growth :: proc(t: ^testing.T) {
	arena: Frame_Arena
	// Small blocks so growth crosses several of them.
	frame_arena_init(&arena, 16)
	defer frame_arena_destroy(&arena)

	alloc := frame_arena_allocator(&arena)

	builder: [dynamic]u8
	builder = make([dynamic]u8, alloc)
	defer delete(builder)

	append(&builder, ..transmute([]u8)string("hello"))
	append(&builder, ..transmute([]u8)string(" there"))
	testing.expect_value(t, string(builder[:]), "hello there")

	// Keep growing across many blocks; the prefix must stay intact.
	for _ in 0 ..< 4096 {
		append(&builder, u8('x'))
	}
	testing.expect_value(t, len(builder), 11 + 4096)
	testing.expect_value(t, string(builder[:11]), "hello there")
}
