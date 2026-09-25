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

@(private)
Backend :: struct {
	mutex:        sync.Mutex,
	device:       ^MTL.Device,
	queue:        ^MTL.CommandQueue,
	membership:   ^MTL.ComputePipelineState,
	cosine:       ^MTL.ComputePipelineState,
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
	cosine := compile(device, COSINE_SHADER, "cosine")
	join_count := compile(device, JOIN_SHADER, "join_count")
	join_fill := compile(device, JOIN_SHADER, "join_fill")
	if membership == nil || cosine == nil || join_count == nil || join_fill == nil {
		backend.device = nil
		backend.queue = nil
		return &backend
	}
	backend.membership = membership
	backend.cosine = cosine
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

metal_available_impl :: proc() -> bool {
	be := ensure_backend()
	return be.enabled
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
	if len(left) < MEMBERSHIP_MIN_ROWS || len(right_sorted_unique) == 0 {
		last_decline = .Below_Threshold
		return nil, false
	}
	if !is_sorted_unique(right_sorted_unique) {
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
	defer sync.mutex_unlock(&be.mutex)

	lbuf := be.device->newBufferWithSlice(left, MTL.ResourceStorageModeShared)
	rbuf := be.device->newBufferWithSlice(right_sorted_unique, MTL.ResourceStorageModeShared)
	// The shader writes every flag, so the buffer needs no host copy (and no
	// scratch from the worker thread's never-reset temp allocator).
	fbuf := be.device->newBufferWithLength(NS.UInteger(len(left) * 4), MTL.ResourceStorageModeShared)
	ll := u32(len(left))
	rl := u32(len(right_sorted_unique))
	km := u32(keep_matches ? 1 : 0)
	llbuf := be.device->newBufferWithSlice(([]u32{ll})[:], MTL.ResourceStorageModeShared)
	rlbuf := be.device->newBufferWithSlice(([]u32{rl})[:], MTL.ResourceStorageModeShared)
	kmbuf := be.device->newBufferWithSlice(([]u32{km})[:], MTL.ResourceStorageModeShared)
	if lbuf == nil || rbuf == nil || fbuf == nil || llbuf == nil || rlbuf == nil || kmbuf == nil {
		return nil, false
	}
	dispatch(
		be,
		be.membership,
		[]^MTL.Buffer{lbuf, rbuf, fbuf, llbuf, rlbuf, kmbuf},
		len(left),
	)
	raw := fbuf->contents()
	out := make([]bool, len(left), allocator)
	for i in 0 ..< len(left) {
		out[i] = raw[i * 4] != 0
	}
	last_decline = .None
	return out, true
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
	if n_docs < COSINE_MIN_DOCS {
		last_decline = .Below_Threshold
		return nil, false
	}
	if n_queries < 1 || dim < 1 || len(queries) < n_queries * dim || len(docs) < n_docs * dim {
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
	defer sync.mutex_unlock(&be.mutex)

	total := n_queries * n_docs
	qbuf := be.device->newBufferWithBytes(
		mem.slice_to_bytes(queries[:n_queries * dim]),
		MTL.ResourceStorageModeShared,
	)
	dbuf := be.device->newBufferWithBytes(
		mem.slice_to_bytes(docs[:n_docs * dim]),
		MTL.ResourceStorageModeShared,
	)
	obuf := be.device->newBufferWithLength(NS.UInteger(total * 4), MTL.ResourceStorageModeShared)
	dim_u := u32(dim)
	nd_u := u32(n_docs)
	nq_u := u32(n_queries)
	dimbuf := be.device->newBufferWithSlice(([]u32{dim_u})[:], MTL.ResourceStorageModeShared)
	ndbuf := be.device->newBufferWithSlice(([]u32{nd_u})[:], MTL.ResourceStorageModeShared)
	nqbuf := be.device->newBufferWithSlice(([]u32{nq_u})[:], MTL.ResourceStorageModeShared)
	if qbuf == nil || dbuf == nil || obuf == nil || dimbuf == nil || ndbuf == nil || nqbuf == nil {
		return nil, false
	}
	dispatch(be, be.cosine, []^MTL.Buffer{qbuf, dbuf, obuf, dimbuf, ndbuf, nqbuf}, total)
	raw := obuf->contents()
	out := make([]f32, total, allocator)
	copy(mem.slice_to_bytes(out), raw[:total * 4])
	last_decline = .None
	return out, true
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

	buffers := make([dynamic]^MTL.Buffer, 0, 16, context.temp_allocator)
	defer for b in buffers {
		if b != nil {
			b->release()
		}
	}
	keep :: proc(buffers: ^[dynamic]^MTL.Buffer, b: ^MTL.Buffer) -> ^MTL.Buffer {
		append(buffers, b)
		return b
	}
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
	for b in buffers {
		if b == nil {
			return nil, nil, false
		}
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
