// Tests for the chunk layer: measurement, size-classed storage, pooling, and
// scalar-to-byte localization.
package buffer

import "core:testing"

@(test)
test_chunk_measures_scalars_newlines_and_ascii :: proc(t: ^testing.T) {
	alloc, arena := test_allocator(t)
	defer test_allocator_destroy(arena)

	pool: Chunk_Pool
	chunk_pool_init(&pool, alloc)
	defer chunk_pool_destroy(&pool)

	ascii := chunk_create(&pool, "hello\nworld", .Original, alloc)
	testing.expect_value(t, ascii.scalars, u64(11))
	testing.expect_value(t, ascii.newlines, u64(1))
	testing.expect(t, ascii.ascii)
	testing.expect_value(t, len(ascii.bytes), 11)
	// A small run takes a small class, never the chunk target.
	testing.expect(t, len(ascii.storage) <= 16)
	chunk_release(ascii)

	unicode := chunk_create(&pool, "héllo→", .Original, alloc)
	testing.expect_value(t, unicode.scalars, u64(6))
	testing.expect_value(t, unicode.newlines, u64(0))
	testing.expect(t, !unicode.ascii)
	testing.expect_value(t, len(unicode.bytes), 9)
	chunk_release(unicode)
}

@(test)
test_chunk_scalar_to_byte_localization :: proc(t: ^testing.T) {
	alloc, arena := test_allocator(t)
	defer test_allocator_destroy(arena)

	pool: Chunk_Pool
	chunk_pool_init(&pool, alloc)
	defer chunk_pool_destroy(&pool)

	chunk := chunk_create(&pool, "héllo→", .Original, alloc)
	defer chunk_release(chunk)

	// h(1) é(2) l l o →(3): scalar offsets 0,1,2,3,4,5 -> bytes 0,1,3,4,5,6.
	testing.expect_value(t, chunk_byte_offset(chunk, 0), 0)
	testing.expect_value(t, chunk_byte_offset(chunk, 1), 1)
	testing.expect_value(t, chunk_byte_offset(chunk, 2), 3)
	testing.expect_value(t, chunk_byte_offset(chunk, 5), 6)
	testing.expect_value(t, chunk_byte_offset(chunk, 6), 9)
}

@(test)
test_chunk_newline_offsets :: proc(t: ^testing.T) {
	alloc, arena := test_allocator(t)
	defer test_allocator_destroy(arena)

	pool: Chunk_Pool
	chunk_pool_init(&pool, alloc)
	defer chunk_pool_destroy(&pool)

	chunk := chunk_create(&pool, "ab\ncd\nef", .Original, alloc)
	defer chunk_release(chunk)

	testing.expect_value(t, chunk.newlines, u64(2))
	testing.expect_value(t, chunk_newline_offset(chunk, 0), i64(2))
	testing.expect_value(t, chunk_newline_offset(chunk, 1), i64(5))
	testing.expect_value(t, chunk_newline_offset(chunk, 2), i64(-1))
}

@(test)
test_chunk_pool_recycles_class_buffers :: proc(t: ^testing.T) {
	alloc, arena := test_allocator(t)
	defer test_allocator_destroy(arena)

	pool: Chunk_Pool
	chunk_pool_init(&pool, alloc)
	defer chunk_pool_destroy(&pool)

	first := chunk_create(&pool, "abc", .Original, alloc)
	class := first.class
	chunk_release(first)
	testing.expect_value(t, len(pool.free[class]), 1)

	second := chunk_create(&pool, "de", .Added, alloc)
	testing.expect(t, pool.reuses >= 1)
	testing.expect_value(t, second.class, class)
	chunk_release(second)
}

@(test)
test_chunk_write_range_copies_scalars :: proc(t: ^testing.T) {
	alloc, arena := test_allocator(t)
	defer test_allocator_destroy(arena)

	pool: Chunk_Pool
	chunk_pool_init(&pool, alloc)
	defer chunk_pool_destroy(&pool)

	chunk := chunk_create(&pool, "héllo→", .Original, alloc)
	defer chunk_release(chunk)

	builder: [dynamic]u8
	builder = make([dynamic]u8, alloc)
	chunk_write_range(chunk, 1, 3, &builder)
	testing.expect_value(t, string(builder[:]), "él")
}
