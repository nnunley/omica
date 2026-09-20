// Text chunks: immutable, reference-counted, bounded byte runs.
//
// A chunk owns the bytes of a run of text. Once published it never moves,
// grows, or mutates, so a reader that retains a root can borrow spans from it
// safely. Chunk storage is size-classed: a one-scalar insert takes a small
// class rather than a full target-sized block, so character-at-a-time editing
// does not waste memory even before a batching optimization exists.
//
// Two indexes make intra-chunk work independent of chunk size:
//
//   - a sampled scalar-to-byte offset table (reusing the `String_Index`
//     structure `mica/var` builds for long non-ASCII strings), so locating a
//     byte from a scalar offset does not scan;
//   - the scalar offset of every newline, so counting newlines in a piece and
//     locating a line inside a piece are logarithmic rather than a byte scan.
//
// The second index is what keeps edit cost logarithmic: an edit splits a base
// piece, and splitting recomputes each half's newline count. Scanning bytes to
// do that would make a middle edit O(document).
package buffer

import v "../var"
import "core:mem"
import "core:sync"
import "core:unicode/utf8"

// Targets for compaction and batching. Never a minimum allocation.
CHUNK_TARGET_BYTES :: 64 * 1024

Chunk_Kind :: enum {
	// Text present when the buffer was loaded or last compacted.
	Original,
	// Text appended by an edit.
	Added,
}

// Byte-size classes for chunk storage. Reused buffers are kept per class.
CHUNK_CLASS_COUNT :: 13

@(private)
chunk_size_classes := [CHUNK_CLASS_COUNT]int {
	16,
	32,
	64,
	128,
	256,
	512,
	1024,
	2048,
	4096,
	8192,
	16384,
	32768,
	65536,
}

Text_Chunk :: struct {
	refs:            i64,
	id:              u64,
	kind:            Chunk_Kind,
	// The used prefix of `storage`.
	bytes:           []u8,
	// The full class-sized buffer, returned to the pool on release.
	storage:         []u8,
	class:           int,
	scalars:         u64,
	// Number of newlines; the document line count is `newlines + 1`.
	newlines:        u64,
	// Scalar offset of every newline, ascending.
	newline_offsets: []u32,
	ascii:           bool,
	// Sampled scalar-to-byte offsets; nil for ASCII or short non-ASCII runs.
	index:           ^v.String_Index,
	generation:      u64,
	pool:            ^Chunk_Pool,
	owner:           mem.Allocator,
}

// Owns chunk storage and hands out class-sized buffers.
Chunk_Pool :: struct {
	lock:            sync.Mutex,
	allocator:       mem.Allocator,
	free:            [CHUNK_CLASS_COUNT][dynamic][]u8,
	next_id:         u64,
	next_generation: u64,
	allocations:     u64,
	reuses:          u64,
}

chunk_pool_init :: proc(pool: ^Chunk_Pool, allocator := context.allocator) {
	pool.allocator = allocator
	for class in 0 ..< CHUNK_CLASS_COUNT {
		pool.free[class] = make([dynamic][]u8, allocator)
	}
}

chunk_pool_destroy :: proc(pool: ^Chunk_Pool) {
	for class in 0 ..< CHUNK_CLASS_COUNT {
		for buffer in pool.free[class] {
			delete(buffer, pool.allocator)
		}
		delete(pool.free[class])
	}
}

@(private)
chunk_class_for :: proc(size: int) -> int {
	for class in 0 ..< CHUNK_CLASS_COUNT {
		if size <= chunk_size_classes[class] {
			return class
		}
	}
	return -1
}

@(private)
chunk_pool_take :: proc(pool: ^Chunk_Pool, size: int) -> ([]u8, int) {
	sync.mutex_lock(&pool.lock)
	defer sync.mutex_unlock(&pool.lock)
	class := chunk_class_for(size)
	if class >= 0 && len(pool.free[class]) > 0 {
		buffer := pop(&pool.free[class])
		pool.reuses += 1
		return buffer, class
	}
	capacity := size
	if class >= 0 {
		capacity = chunk_size_classes[class]
	}
	buffer := make([]u8, capacity, pool.allocator)
	pool.allocations += 1
	return buffer, class
}

@(private)
chunk_pool_give :: proc(pool: ^Chunk_Pool, buffer: []u8, class: int) {
	sync.mutex_lock(&pool.lock)
	defer sync.mutex_unlock(&pool.lock)
	if class < 0 {
		delete(buffer, pool.allocator)
		return
	}
	append(&pool.free[class], buffer)
}

// One pass over the bytes: scalar count, ASCII-ness, and newline positions.
@(private)
chunk_measure :: proc(bytes: []u8, newlines: ^[dynamic]u32) -> (scalars: u64, ascii: bool) {
	ascii = true
	scalar := u64(0)
	index := 0
	for index < len(bytes) {
		if bytes[index] == '\n' {
			append(newlines, u32(scalar))
		}
		if bytes[index] >= 0x80 {
			ascii = false
		}
		_, size := utf8.decode_rune_in_bytes(bytes[index:])
		if size <= 0 {
			size = 1
		}
		index += size
		scalar += 1
	}
	return scalar, ascii
}

// Creates a chunk holding `text`. `kind` distinguishes material inherited from
// the base from material appended by an edit; provenance depends on it.
chunk_create :: proc(
	pool: ^Chunk_Pool,
	text: string,
	kind: Chunk_Kind,
	allocator := context.allocator,
) -> ^Text_Chunk {
	size := len(text)
	storage, class := chunk_pool_take(pool, size)
	bytes := storage[:size]
	copy(bytes, transmute([]u8)text)

	chunk := new(Text_Chunk, allocator)
	chunk.refs = 1
	chunk.id = sync.atomic_add_explicit(&pool.next_id, 1, .Relaxed) + 1
	chunk.kind = kind
	chunk.bytes = bytes
	chunk.storage = storage
	chunk.class = class
	chunk.pool = pool
	chunk.owner = allocator
	chunk.generation = sync.atomic_add_explicit(&pool.next_generation, 1, .Relaxed) + 1

	newlines: [dynamic]u32
	newlines = make([dynamic]u32, allocator)
	scalars, ascii := chunk_measure(bytes, &newlines)
	chunk.scalars = scalars
	chunk.ascii = ascii
	chunk.newlines = u64(len(newlines))
	if len(newlines) > 0 {
		offsets := make([]u32, len(newlines), allocator)
		copy(offsets, newlines[:])
		chunk.newline_offsets = offsets
	}
	delete(newlines)

	if !ascii && scalars >= v.STRING_INDEX_MIN {
		chunk.index = v.string_index_build(allocator, bytes)
	}
	return chunk
}

chunk_retain :: proc(chunk: ^Text_Chunk) -> ^Text_Chunk {
	if chunk != nil {
		sync.atomic_add_explicit(&chunk.refs, 1, .Relaxed)
	}
	return chunk
}

// Releases one reference, returning storage to the pool at zero.
chunk_release :: proc(chunk: ^Text_Chunk) {
	if chunk == nil {
		return
	}
	if sync.atomic_sub_explicit(&chunk.refs, 1, .Acq_Rel) != 1 {
		return
	}
	if chunk.index != nil {
		delete(chunk.index.offsets, chunk.owner)
		free(chunk.index, chunk.owner)
	}
	if chunk.newline_offsets != nil {
		delete(chunk.newline_offsets, chunk.owner)
	}
	chunk_pool_give(chunk.pool, chunk.storage, chunk.class)
	free(chunk, chunk.owner)
}

// Byte offset of scalar `index` within the chunk.
chunk_byte_offset :: proc(chunk: ^Text_Chunk, index: u64) -> int {
	if index == 0 {
		return 0
	}
	if index >= chunk.scalars {
		return len(chunk.bytes)
	}
	if chunk.ascii {
		return int(index)
	}

	scalar := u64(0)
	offset := 0
	if chunk.index != nil {
		sample := index / v.STRING_INDEX_STRIDE
		offset = int(chunk.index.offsets[sample])
		scalar = sample * v.STRING_INDEX_STRIDE
	}
	for scalar < index {
		_, size := utf8.decode_rune_in_bytes(chunk.bytes[offset:])
		if size <= 0 {
			size = 1
		}
		offset += size
		scalar += 1
	}
	return offset
}

// Copies the scalar range `[start, end)` of a chunk into `builder`.
chunk_write_range :: proc(chunk: ^Text_Chunk, start, end: u64, builder: ^[dynamic]u8) {
	byte_start := chunk_byte_offset(chunk, start)
	byte_end := chunk_byte_offset(chunk, end)
	append(builder, ..chunk.bytes[byte_start:byte_end])
}

// Index of the first newline at or after `scalar`.
@(private)
chunk_newline_lower_bound :: proc(chunk: ^Text_Chunk, scalar: u64) -> int {
	offsets := chunk.newline_offsets
	low := 0
	high := len(offsets)
	for low < high {
		mid := (low + high) / 2
		if u64(offsets[mid]) < scalar {
			low = mid + 1
		} else {
			high = mid
		}
	}
	return low
}

// Newlines in scalar range `[start, end)`.
chunk_newlines_in_range :: proc(chunk: ^Text_Chunk, start, end: u64) -> u64 {
	if chunk.newlines == 0 {
		return 0
	}
	low := chunk_newline_lower_bound(chunk, start)
	high := chunk_newline_lower_bound(chunk, end)
	return u64(high - low)
}

// Scalar offset of the `n`-th newline inside `[start, end)`, or -1.
chunk_nth_newline_in_range :: proc(chunk: ^Text_Chunk, start, end: u64, n: u64) -> i64 {
	if chunk.newlines == 0 {
		return -1
	}
	low := chunk_newline_lower_bound(chunk, start)
	index := low + int(n)
	if index >= len(chunk.newline_offsets) {
		return -1
	}
	offset := u64(chunk.newline_offsets[index])
	if offset >= end {
		return -1
	}
	return i64(offset)
}

// Scalar offset of the `n`-th newline in the chunk (0-based), or -1.
chunk_newline_offset :: proc(chunk: ^Text_Chunk, n: u64) -> i64 {
	if n >= chunk.newlines {
		return -1
	}
	return i64(chunk.newline_offsets[n])
}
