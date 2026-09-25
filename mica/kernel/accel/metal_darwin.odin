// Darwin Metal backend: compute-pipeline cache, buffer helpers, and the
// membership + cosine operators. Gated to Apple hardware at runtime via
// CreateSystemDefaultDevice; a nil device disables everything permanently.
#+build darwin
package accel

import MTL "vendor:darwin/Metal"
import NS "core:sys/darwin/Foundation"
import "core:sync"
import "core:mem"
import "core:slice"
import "core:strings"

// Minimum rows before GPU dispatch is considered. Below this the PCIe-less
// unified-memory launch overhead still exceeds the CPU scan.
MEMBERSHIP_MIN_ROWS :: 4096
COSINE_MIN_DOCS :: 1024
// Fewest probes the Metal join accepts (placement threshold; tuned on the
// engine join benchmark).
METAL_JOIN_MIN_PROBES :: 4096
// Two-key membership: at 12k probes (visible_items_rule) Metal took 0.96 ms
// against the CPU's 0.80, so it starts much later than the single key.
MEMBERSHIP2_MIN_ROWS :: 65536

MEMBERSHIP_SHADER :: `
#include <metal_stdlib>
using namespace metal;
// Binary search of each probe in the sorted-unique right column.
kernel void membership(device const ulong* left [[buffer(0)]],
                       device const ulong* right [[buffer(1)]],
                       device uint* out [[buffer(2)]],
                       constant uint& left_len [[buffer(3)]],
                       constant uint& right_len [[buffer(4)]],
                       constant uint& keep_matches [[buffer(5)]],
                       uint row [[thread_position_in_grid]]) {
    if (row >= left_len) return;
    ulong probe = left[row];
    uint lo = 0, hi = right_len;
    while (lo < hi) {
        uint mid = lo + ((hi - lo) >> 1);
        if (right[mid] < probe) lo = mid + 1;
        else hi = mid;
    }
    bool hit = (lo < right_len && right[lo] == probe);
    out[row] = (hit == bool(keep_matches)) ? 1u : 0u;
}
// Two-key membership: two columns per side; right pairs sorted-unique
// lexicographically.
kernel void membership2(device const ulong* left_a [[buffer(0)]],
                        device const ulong* left_b [[buffer(1)]],
                        device const ulong* right_a [[buffer(2)]],
                        device const ulong* right_b [[buffer(3)]],
                        device uint* out [[buffer(4)]],
                        constant uint& left_len [[buffer(5)]],
                        constant uint& right_len [[buffer(6)]],
                        constant uint& keep_matches [[buffer(7)]],
                        uint row [[thread_position_in_grid]]) {
    if (row >= left_len) return;
    ulong p0 = left_a[row], p1 = left_b[row];
    uint lo = 0, hi = right_len;
    while (lo < hi) {
        uint mid = lo + ((hi - lo) >> 1);
        ulong r0 = right_a[mid], r1 = right_b[mid];
        if (r0 < p0 || (r0 == p0 && r1 < p1)) lo = mid + 1;
        else hi = mid;
    }
    bool hit = (lo < right_len && right_a[lo] == p0 && right_b[lo] == p1);
    out[row] = (hit == bool(keep_matches)) ? 1u : 0u;
}
`

// One thread per (query, doc) pair; 15x faster than the per-query grid at
// 64x4096x768 on M3 (10ms vs 153ms CPU, 258ms naive per-query Metal).
COSINE_SHADER :: `
#include <metal_stdlib>
using namespace metal;
kernel void cosine(device const float* queries [[buffer(0)]],
                   device const float* docs [[buffer(1)]],
                   device float* out [[buffer(2)]],
                   constant uint& dim [[buffer(3)]],
                   constant uint& n_docs [[buffer(4)]],
                   constant uint& n_queries [[buffer(5)]],
                   uint tid [[thread_position_in_grid]]) {
    uint total = n_queries * n_docs;
    if (tid >= total) return;
    uint q = tid / n_docs;
    uint i = tid % n_docs;
    float d2 = 0.0, qn = 0.0, dn = 0.0;
    for (uint d = 0; d < dim; d++) {
        float qv = queries[q * dim + d];
        float dv = docs[i * dim + d];
        d2 += qv * dv; qn += qv * qv; dn += dv * dv;
    }
    out[tid] = d2 / (sqrt(qn) * sqrt(dn) + 1e-9);
}
`

// Equality join over one or two key columns: join_count finds each probe's
// equal range in the sorted right keys, the host turns counts into offsets,
// join_fill writes each probe's pairs at its offset (pairs stay ordered by
// probe). Width 1 binds the first columns again as the unused second ones.
JOIN_SHADER :: `
#include <metal_stdlib>
using namespace metal;
inline int key_cmp(ulong a0, ulong a1, ulong b0, ulong b1, uint width) {
    if (a0 < b0) return -1;
    if (a0 > b0) return 1;
    if (width == 1) return 0;
    if (a1 < b1) return -1;
    if (a1 > b1) return 1;
    return 0;
}
kernel void join_count(device const ulong* left_a [[buffer(0)]],
                       device const ulong* left_b [[buffer(1)]],
                       device const ulong* right_a [[buffer(2)]],
                       device const ulong* right_b [[buffer(3)]],
                       device uint* first [[buffer(4)]],
                       device uint* count [[buffer(5)]],
                       constant uint& left_len [[buffer(6)]],
                       constant uint& right_len [[buffer(7)]],
                       constant uint& width [[buffer(8)]],
                       uint row [[thread_position_in_grid]]) {
    if (row >= left_len) return;
    ulong p0 = left_a[row], p1 = width == 2 ? left_b[row] : 0;
    uint lo = 0, hi = right_len;
    while (lo < hi) {
        uint mid = lo + ((hi - lo) >> 1);
        if (key_cmp(right_a[mid], width == 2 ? right_b[mid] : 0, p0, p1, width) < 0) lo = mid + 1;
        else hi = mid;
    }
    uint start = lo;
    hi = right_len;
    while (lo < hi) {
        uint mid = lo + ((hi - lo) >> 1);
        if (key_cmp(right_a[mid], width == 2 ? right_b[mid] : 0, p0, p1, width) <= 0) lo = mid + 1;
        else hi = mid;
    }
    first[row] = start;
    count[row] = lo - start;
}
kernel void join_fill(device const uint* first [[buffer(0)]],
                      device const uint* count [[buffer(1)]],
                      device const uint* offset [[buffer(2)]],
                      device const uint* right_rows [[buffer(3)]],
                      device uint* out_left [[buffer(4)]],
                      device uint* out_right [[buffer(5)]],
                      constant uint& left_len [[buffer(6)]],
                      uint row [[thread_position_in_grid]]) {
    if (row >= left_len) return;
    uint o = offset[row], f = first[row], c = count[row];
    for (uint k = 0; k < c; k++) {
        out_left[o + k] = row;
        out_right[o + k] = right_rows[f + k];
    }
}
`

// Tiled cosine for query batches: each 16x16 threadgroup computes 16 queries
// against 16 documents, staging 16-dimension slices of both in threadgroup
// memory so each value is read from device memory once per tile instead of
// once per pair. Every thread accumulates in dimension order, as `cosine`.
// Dispatched as whole threadgroups; out-of-range threads load zeros and do not
// write.
COSINE_TILED_SHADER :: `
#include <metal_stdlib>
using namespace metal;
kernel void cosine_tiled(device const float* queries [[buffer(0)]],
                         device const float* docs [[buffer(1)]],
                         device float* out [[buffer(2)]],
                         constant uint& dim [[buffer(3)]],
                         constant uint& n_docs [[buffer(4)]],
                         constant uint& n_queries [[buffer(5)]],
                         uint2 gid [[thread_position_in_grid]],
                         uint2 lid [[thread_position_in_threadgroup]]) {
    threadgroup float qt[16][16];
    threadgroup float dt[16][16];
    uint q0 = gid.y - lid.y, d0 = gid.x - lid.x;
    float dot = 0.0, qn = 0.0, dn = 0.0;
    for (uint k0 = 0; k0 < dim; k0 += 16) {
        uint k = k0 + lid.x;
        uint qrow = q0 + lid.y, drow = d0 + lid.y;
        qt[lid.y][lid.x] = (qrow < n_queries && k < dim) ? queries[qrow * dim + k] : 0.0;
        dt[lid.y][lid.x] = (drow < n_docs && k < dim) ? docs[drow * dim + k] : 0.0;
        threadgroup_barrier(mem_flags::mem_threadgroup);
        for (uint kk = 0; kk < 16; kk++) {
            float qv = qt[lid.y][kk];
            float dv = dt[lid.x][kk];
            dot += qv * dv; qn += qv * qv; dn += dv * dv;
        }
        threadgroup_barrier(mem_flags::mem_threadgroup);
    }
    if (gid.y < n_queries && gid.x < n_docs) {
        out[gid.y * n_docs + gid.x] = dot / (sqrt(qn) * sqrt(dn) + 1e-9);
    }
}
`

// Batches of at least this many queries use the tiled kernel; smaller ones
// keep one thread per pair (a tile would be mostly empty).
METAL_TILED_COSINE_MIN_QUERIES :: 8

@(private)
Backend :: struct {
	mutex:        sync.Mutex,
	device:       ^MTL.Device,
	queue:        ^MTL.CommandQueue,
	membership:   ^MTL.ComputePipelineState,
	membership2:  ^MTL.ComputePipelineState,
	cosine:       ^MTL.ComputePipelineState,
	cosine_tiled: ^MTL.ComputePipelineState,
	join_count:   ^MTL.ComputePipelineState,
	join_fill:    ^MTL.ComputePipelineState,
	pool:         ^NS.AutoreleasePool,
	probed:       bool,
	enabled:      bool,
}

@(private)
backend: Backend

@(private)
ensure_backend :: proc() -> ^Backend {
	sync.mutex_lock(&backend.mutex)
	defer sync.mutex_unlock(&backend.mutex)
	if backend.probed {
		return &backend
	}
	backend.probed = true
	backend.pool = NS.AutoreleasePool.alloc()->init()
	device := MTL.CreateSystemDefaultDevice()
	if device == nil {
		return &backend
	}
	backend.device = device
	backend.queue = device->newCommandQueue()
	if backend.queue == nil {
		backend.device = nil
		return &backend
	}
	membership := compile(device, MEMBERSHIP_SHADER, "membership")
	membership2 := compile(device, MEMBERSHIP_SHADER, "membership2")
	cosine := compile(device, COSINE_SHADER, "cosine")
	cosine_tiled := compile(device, COSINE_TILED_SHADER, "cosine_tiled")
	join_count := compile(device, JOIN_SHADER, "join_count")
	join_fill := compile(device, JOIN_SHADER, "join_fill")
	if membership == nil || membership2 == nil || cosine == nil || cosine_tiled == nil || join_count == nil || join_fill == nil {
		backend.device = nil
		backend.queue = nil
		return &backend
	}
	backend.membership = membership
	backend.membership2 = membership2
	backend.cosine = cosine
	backend.cosine_tiled = cosine_tiled
	backend.join_count = join_count
	backend.join_fill = join_fill
	backend.enabled = true
	return &backend
}

@(private)
compile :: proc(
	device: ^MTL.Device,
	source: cstring,
	name: string,
) -> ^MTL.ComputePipelineState {
	src := NS.String.alloc()->initWithCString(source, .UTF8)
	if src == nil {
		return nil
	}
	lib, _ := device->newLibraryWithSource(src, nil)
	if lib == nil {
		return nil
	}
	fname := NS.String.alloc()->initWithCString(
		strings.clone_to_cstring(name, context.temp_allocator),
		.UTF8,
	)
	fn := lib->newFunctionWithName(fname)
	if fn == nil {
		return nil
	}
	pipe, _ := device->newComputePipelineStateWithFunction(fn)
	return pipe
}

@(private)
dispatch :: proc(
	be: ^Backend,
	pipe: ^MTL.ComputePipelineState,
	buffers: []^MTL.Buffer,
	threads: int,
	threadgroup: int = 256,
) {
	cbuf := be.queue->commandBuffer()
	enc := cbuf->computeCommandEncoder()
	enc->setComputePipelineState(pipe)
	for buf, i in buffers {
		enc->setBuffer(buf, 0, NS.UInteger(i))
	}
	enc->dispatchThreads(
		MTL.Size{width = NS.Integer(threads), height = 1, depth = 1},
		MTL.Size{width = NS.Integer(threadgroup), height = 1, depth = 1},
	)
	enc->endEncoding()
	cbuf->commit()
	cbuf->waitUntilCompleted()
}

// Dispatches whole `group` x `group` threadgroups covering width x height.
@(private)
dispatch_tiles :: proc(be: ^Backend, pipe: ^MTL.ComputePipelineState, buffers: []^MTL.Buffer, width, height, group: int) {
	cbuf := be.queue->commandBuffer()
	enc := cbuf->computeCommandEncoder()
	enc->setComputePipelineState(pipe)
	for buf, i in buffers {
		enc->setBuffer(buf, 0, NS.UInteger(i))
	}
	enc->dispatchThreadgroups(
		MTL.Size{width = NS.Integer((width + group - 1) / group), height = NS.Integer((height + group - 1) / group), depth = 1},
		MTL.Size{width = NS.Integer(group), height = NS.Integer(group), depth = 1},
	)
	enc->endEncoding()
	cbuf->commit()
	cbuf->waitUntilCompleted()
}

@(thread_local, private)
metal_cosine_tiled_used: bool

// Whether the calling thread's last Metal cosine used the tiled kernel (tests).
metal_last_cosine_tiled :: proc() -> bool {
	return metal_cosine_tiled_used
}

metal_available_impl :: proc() -> bool {
	be := ensure_backend()
	return be.enabled
}

// Buffers created for one operator call, released together.
// A fixed array, so an operator allocates nothing for its bookkeeping (it may
// run on a scheduler worker whose temp allocator is never reset).
@(private)
Metal_Buffers :: struct {
	list:  [16]^MTL.Buffer,
	count: int,
}

@(private)
metal_keep :: proc(bufs: ^Metal_Buffers, b: ^MTL.Buffer) -> ^MTL.Buffer {
	assert(bufs.count < len(bufs.list), "Metal_Buffers is full")
	bufs.list[bufs.count] = b
	bufs.count += 1
	return b
}

@(private)
metal_release_all :: proc(bufs: ^Metal_Buffers) {
	for b in bufs.list[:bufs.count] {
		if b != nil {
			b->release()
		}
	}
	bufs.count = 0
}

@(private)
metal_all_created :: proc(bufs: ^Metal_Buffers) -> bool {
	for b in bufs.list[:bufs.count] {
		if b == nil {
			return false
		}
	}
	return true
}

@(private)
metal_u32 :: proc(be: ^Backend, bufs: ^Metal_Buffers, x: u32) -> ^MTL.Buffer {
	return metal_keep(bufs, be.device->newBufferWithSlice(([]u32{x})[:], MTL.ResourceStorageModeShared))
}

// Size and device checks shared by the membership operators; takes the
// backend lock without waiting. The caller unlocks on true.
@(private)
metal_membership_enter :: proc(left_len, right_len: int) -> (^Backend, bool) {
	if left_len < MEMBERSHIP_MIN_ROWS || right_len == 0 {
		last_decline = .Below_Threshold
		return nil, false
	}
	if left_len > int(max(u32)) || right_len > int(max(u32)) {
		last_decline = .Unsupported
		return nil, false
	}
	be := ensure_backend()
	if !be.enabled {
		last_decline = .Unavailable
		return nil, false
	}
	// Never wait for the device: a busy accelerator declines and the caller
	// runs its CPU path.
	if !sync.mutex_try_lock(&be.mutex) {
		last_decline = .Busy
		return nil, false
	}
	return be, true
}

// Probes `left` against a sorted-unique column already in a device buffer.
// Caller holds the backend lock.
@(private)
metal_membership_locked :: proc(be: ^Backend, left: []u64, right: ^MTL.Buffer, right_len: int, keep_matches: bool, allocator: mem.Allocator) -> ([]bool, bool) {
	bufs: Metal_Buffers
	defer metal_release_all(&bufs)
	lbuf := metal_keep(&bufs, be.device->newBufferWithSlice(left, MTL.ResourceStorageModeShared))
	// The shader writes every flag, so the buffer needs no host copy.
	fbuf := metal_keep(&bufs, be.device->newBufferWithLength(NS.UInteger(len(left) * 4), MTL.ResourceStorageModeShared))
	llbuf := metal_u32(be, &bufs, u32(len(left)))
	rlbuf := metal_u32(be, &bufs, u32(right_len))
	kmbuf := metal_u32(be, &bufs, u32(keep_matches ? 1 : 0))
	if !metal_all_created(&bufs) {
		return nil, false
	}
	dispatch(be, be.membership, []^MTL.Buffer{lbuf, right, fbuf, llbuf, rlbuf, kmbuf}, len(left))
	flags := slice.reinterpret([]u32, fbuf->contents()[:len(left) * 4])
	out := make([]bool, len(left), allocator)
	for i in 0 ..< len(left) {
		out[i] = flags[i] != 0
	}
	last_decline = .None
	return out, true
}

// Membership probe against a sorted-unique right column. Small inputs and any
// failure decline to CPU.
membership_select_impl :: proc(
	left: []u64,
	right_sorted_unique: []u64,
	keep_matches: bool,
	allocator: mem.Allocator,
) -> (
	selected: []bool,
	accelerated: bool,
) {
	last_decline = .Failed
	if !is_sorted_unique(right_sorted_unique) {
		last_decline = .Unsupported
		return nil, false
	}
	be, entered := metal_membership_enter(len(left), len(right_sorted_unique))
	if !entered {
		return nil, false
	}
	defer sync.mutex_unlock(&be.mutex)
	bufs: Metal_Buffers
	defer metal_release_all(&bufs)
	rbuf := metal_keep(&bufs, be.device->newBufferWithSlice(right_sorted_unique, MTL.ResourceStorageModeShared))
	if rbuf == nil {
		return nil, false
	}
	return metal_membership_locked(be, left, rbuf, len(right_sorted_unique), keep_matches, allocator)
}

// Two-key membership over two columns per side; membership_selection has
// checked shape and sort order.
membership_select2_impl :: proc(
	left_a, left_b, right_a, right_b: []u64,
	keep_matches: bool,
	allocator: mem.Allocator,
) -> (
	selected: []bool,
	accelerated: bool,
) {
	last_decline = .Failed
	n := len(left_a)
	if n < MEMBERSHIP2_MIN_ROWS {
		last_decline = .Below_Threshold
		return nil, false
	}
	be, entered := metal_membership_enter(n, len(right_a))
	if !entered {
		return nil, false
	}
	defer sync.mutex_unlock(&be.mutex)
	bufs: Metal_Buffers
	defer metal_release_all(&bufs)
	la := metal_keep(&bufs, be.device->newBufferWithSlice(left_a, MTL.ResourceStorageModeShared))
	lb := metal_keep(&bufs, be.device->newBufferWithSlice(left_b, MTL.ResourceStorageModeShared))
	ra := metal_keep(&bufs, be.device->newBufferWithSlice(right_a, MTL.ResourceStorageModeShared))
	rb := metal_keep(&bufs, be.device->newBufferWithSlice(right_b, MTL.ResourceStorageModeShared))
	fbuf := metal_keep(&bufs, be.device->newBufferWithLength(NS.UInteger(n * 4), MTL.ResourceStorageModeShared))
	ln := metal_u32(be, &bufs, u32(n))
	rn := metal_u32(be, &bufs, u32(len(right_a)))
	km := metal_u32(be, &bufs, u32(keep_matches ? 1 : 0))
	if !metal_all_created(&bufs) {
		return nil, false
	}
	dispatch(be, be.membership2, []^MTL.Buffer{la, lb, ra, rb, fbuf, ln, rn, km}, n)
	flags := slice.reinterpret([]u32, fbuf->contents()[:n * 4])
	out := make([]bool, n, allocator)
	for i in 0 ..< n {
		out[i] = flags[i] != 0
	}
	last_decline = .None
	return out, true
}

// A resident copy of a sorted-unique column: the Metal buffer is the handle.
prepare_column_impl :: proc(sorted_unique: []u64) -> (handle: rawptr, ok: bool) {
	be := ensure_backend()
	if !be.enabled {
		last_decline = .Unavailable
		return nil, false
	}
	if len(sorted_unique) == 0 {
		last_decline = .Unsupported
		return nil, false
	}
	buf := be.device->newBufferWithSlice(sorted_unique, MTL.ResourceStorageModeShared)
	if buf == nil {
		return nil, false
	}
	return rawptr(buf), true
}

membership_select_prepared_impl :: proc(
	left: []u64,
	column: rawptr,
	rows: int,
	keep_matches: bool,
	allocator: mem.Allocator,
) -> (
	selected: []bool,
	accelerated: bool,
) {
	last_decline = .Failed
	be, entered := metal_membership_enter(len(left), rows)
	if !entered {
		return nil, false
	}
	defer sync.mutex_unlock(&be.mutex)
	return metal_membership_locked(be, left, (^MTL.Buffer)(column), rows, keep_matches, allocator)
}

// A resident n_docs x dim document matrix: the Metal buffer is the handle.
prepare_docs_impl :: proc(docs: []f32, n_docs: int, dim: int) -> (handle: rawptr, ok: bool) {
	be := ensure_backend()
	if !be.enabled {
		last_decline = .Unavailable
		return nil, false
	}
	buf := be.device->newBufferWithBytes(mem.slice_to_bytes(docs[:n_docs * dim]), MTL.ResourceStorageModeShared)
	if buf == nil {
		return nil, false
	}
	return rawptr(buf), true
}

release_impl :: proc(handle: rawptr, kind: Prepared_Kind) {
	if handle != nil {
		(^MTL.Buffer)(handle)->release()
	}
}

// Cosine against documents already in a device buffer. Caller holds the lock.
@(private)
metal_cosine_locked :: proc(be: ^Backend, queries: []f32, dbuf: ^MTL.Buffer, n_queries, n_docs, dim: int, allocator: mem.Allocator) -> ([]f32, bool) {
	bufs: Metal_Buffers
	defer metal_release_all(&bufs)
	total := n_queries * n_docs
	qbuf := metal_keep(&bufs, be.device->newBufferWithBytes(mem.slice_to_bytes(queries[:n_queries * dim]), MTL.ResourceStorageModeShared))
	obuf := metal_keep(&bufs, be.device->newBufferWithLength(NS.UInteger(total * 4), MTL.ResourceStorageModeShared))
	dimbuf := metal_u32(be, &bufs, u32(dim))
	ndbuf := metal_u32(be, &bufs, u32(n_docs))
	nqbuf := metal_u32(be, &bufs, u32(n_queries))
	if !metal_all_created(&bufs) {
		return nil, false
	}
	metal_cosine_tiled_used = n_queries >= METAL_TILED_COSINE_MIN_QUERIES
	if metal_cosine_tiled_used {
		dispatch_tiles(be, be.cosine_tiled, []^MTL.Buffer{qbuf, dbuf, obuf, dimbuf, ndbuf, nqbuf}, n_docs, n_queries, 16)
	} else {
		dispatch(be, be.cosine, []^MTL.Buffer{qbuf, dbuf, obuf, dimbuf, ndbuf, nqbuf}, total)
	}
	out := make([]f32, total, allocator)
	copy(mem.slice_to_bytes(out), obuf->contents()[:total * 4])
	last_decline = .None
	return out, true
}

@(private)
metal_cosine_enter :: proc(n_queries, n_docs, dim: int, queries_len: int) -> (^Backend, bool) {
	if n_docs < COSINE_MIN_DOCS {
		last_decline = .Below_Threshold
		return nil, false
	}
	if n_queries < 1 || dim < 1 || queries_len < n_queries * dim || n_queries * n_docs > int(max(u32)) {
		last_decline = .Unsupported
		return nil, false
	}
	be := ensure_backend()
	if !be.enabled {
		last_decline = .Unavailable
		return nil, false
	}
	if !sync.mutex_try_lock(&be.mutex) {
		last_decline = .Busy
		return nil, false
	}
	return be, true
}

// Cosine similarity of `queries` (n_queries x dim) against `docs`.
// `docs` must hold n_docs * dim floats; returns n_queries * n_docs scores.
cosine_queries_impl :: proc(
	queries: []f32,
	docs: []f32,
	n_queries: int,
	n_docs: int,
	dim: int,
	allocator: mem.Allocator,
) -> (
	scores: []f32,
	accelerated: bool,
) {
	last_decline = .Failed
	if len(docs) < n_docs * dim {
		last_decline = .Unsupported
		return nil, false
	}
	be, entered := metal_cosine_enter(n_queries, n_docs, dim, len(queries))
	if !entered {
		return nil, false
	}
	defer sync.mutex_unlock(&be.mutex)
	bufs: Metal_Buffers
	defer metal_release_all(&bufs)
	dbuf := metal_keep(&bufs, be.device->newBufferWithBytes(mem.slice_to_bytes(docs[:n_docs * dim]), MTL.ResourceStorageModeShared))
	if dbuf == nil {
		return nil, false
	}
	return metal_cosine_locked(be, queries, dbuf, n_queries, n_docs, dim, allocator)
}

cosine_queries_prepared_impl :: proc(
	queries: []f32,
	n_queries: int,
	docs: rawptr,
	n_docs: int,
	dim: int,
	allocator: mem.Allocator,
) -> (
	scores: []f32,
	accelerated: bool,
) {
	last_decline = .Failed
	be, entered := metal_cosine_enter(n_queries, n_docs, dim, len(queries))
	if !entered {
		return nil, false
	}
	defer sync.mutex_unlock(&be.mutex)
	return metal_cosine_locked(be, queries, (^MTL.Buffer)(docs), n_queries, n_docs, dim, allocator)
}

cosine_query_impl :: proc(
	query: []f32,
	docs: []f32,
	n_docs: int,
	dim: int,
	allocator: mem.Allocator,
) -> (
	scores: []f32,
	accelerated: bool,
) {
	return cosine_queries_impl(query, docs, 1, n_docs, dim, allocator)
}

// Equality join (see JOIN_SHADER). Every buffer it creates is released
// before returning. Declines below METAL_JOIN_MIN_PROBES probes, when busy,
// and on any allocation failure.
join_equality_impl :: proc(
	left, right: [][]u64,
	right_rows: []u32,
	allocator: mem.Allocator,
) -> (
	left_out, right_out: []u32,
	accelerated: bool,
) {
	last_decline = .Failed
	n, m := len(left[0]), len(right_rows)
	if n < METAL_JOIN_MIN_PROBES {
		last_decline = .Below_Threshold
		return nil, nil, false
	}
	be := ensure_backend()
	if !be.enabled {
		last_decline = .Unavailable
		return nil, nil, false
	}
	if !sync.mutex_try_lock(&be.mutex) {
		last_decline = .Busy
		return nil, nil, false
	}
	defer sync.mutex_unlock(&be.mutex)

	buffers: Metal_Buffers
	defer metal_release_all(&buffers)
	keep :: metal_keep
	width := len(left)
	la := keep(&buffers, be.device->newBufferWithSlice(left[0], MTL.ResourceStorageModeShared))
	lb := la
	ra := keep(&buffers, be.device->newBufferWithSlice(right[0], MTL.ResourceStorageModeShared))
	rb := ra
	if width == 2 {
		lb = keep(&buffers, be.device->newBufferWithSlice(left[1], MTL.ResourceStorageModeShared))
		rb = keep(&buffers, be.device->newBufferWithSlice(right[1], MTL.ResourceStorageModeShared))
	}
	first := keep(&buffers, be.device->newBufferWithLength(NS.UInteger(n * 4), MTL.ResourceStorageModeShared))
	count := keep(&buffers, be.device->newBufferWithLength(NS.UInteger(n * 4), MTL.ResourceStorageModeShared))
	ln := keep(&buffers, be.device->newBufferWithSlice(([]u32{u32(n)})[:], MTL.ResourceStorageModeShared))
	rn := keep(&buffers, be.device->newBufferWithSlice(([]u32{u32(m)})[:], MTL.ResourceStorageModeShared))
	wd := keep(&buffers, be.device->newBufferWithSlice(([]u32{u32(width)})[:], MTL.ResourceStorageModeShared))
	if !metal_all_created(&buffers) {
		return nil, nil, false
	}
	dispatch(be, be.join_count, []^MTL.Buffer{la, lb, ra, rb, first, count, ln, rn, wd}, n)

	counts := slice.reinterpret([]u32, count->contents()[:n * 4])
	offsets := make([]u32, n, context.temp_allocator)
	total := 0
	for i in 0 ..< n {
		offsets[i] = u32(total)
		total += int(counts[i])
	}
	if total == 0 {
		last_decline = .None
		return nil, nil, true
	}
	ob := keep(&buffers, be.device->newBufferWithSlice(offsets, MTL.ResourceStorageModeShared))
	rr := keep(&buffers, be.device->newBufferWithSlice(right_rows, MTL.ResourceStorageModeShared))
	outl := keep(&buffers, be.device->newBufferWithLength(NS.UInteger(total * 4), MTL.ResourceStorageModeShared))
	outr := keep(&buffers, be.device->newBufferWithLength(NS.UInteger(total * 4), MTL.ResourceStorageModeShared))
	if ob == nil || rr == nil || outl == nil || outr == nil {
		return nil, nil, false
	}
	dispatch(be, be.join_fill, []^MTL.Buffer{first, count, ob, rr, outl, outr, ln}, n)
	left_out = make([]u32, total, allocator)
	right_out = make([]u32, total, allocator)
	copy(left_out, slice.reinterpret([]u32, outl->contents()[:total * 4]))
	copy(right_out, slice.reinterpret([]u32, outr->contents()[:total * 4]))
	last_decline = .None
	return left_out, right_out, true
}
