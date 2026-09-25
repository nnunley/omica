// Linux CUDA backend: the membership + cosine operators on NVIDIA GPUs.
//
// Nothing links against CUDA. The driver API (libcuda.so.1) and NVRTC
// (libnvrtc) are loaded at runtime through core:dynlib, so the package builds
// and runs on any Linux machine; without a driver, a device, or NVRTC,
// `available` is false and every operator declines to CPU. Kernels are
// compiled once per device with NVRTC straight to a cubin for that device's
// architecture (no PTX JIT, so a newer NVRTC than the driver still loads).
//
// Prototype scope: every call copies its inputs to the device and the result
// back, like the Metal backend's shared buffers. Over PCIe that transfer is
// most of the cost for one-shot calls; device-resident columns and document
// matrices are the next step.
#+build linux
package accel

import "core:c"
import "core:dynlib"
import "core:fmt"
import "core:log"
import "core:mem"
import "core:sync"

// Minimum rows before CUDA dispatch is considered; smaller inputs decline to
// the CPU reference. Same starting points as Metal; tune from the benchmarks.
CUDA_MEMBERSHIP_MIN_ROWS :: 4096
CUDA_COSINE_MIN_DOCS :: 1024
// Fewest probes the CUDA join accepts (placement threshold; tuned on the
// engine join benchmark).
CUDA_JOIN_MIN_PROBES :: 4096

// Upper bound on devices tracked; extra devices are ignored.
@(private)
CUDA_MAX_DEVICES :: 16

CUDA_KERNELS :: `
extern "C" __global__ void membership(const unsigned long long* left,
                                      const unsigned long long* right,
                                      unsigned char* out,
                                      unsigned int left_len,
                                      unsigned int right_len,
                                      unsigned int keep_matches) {
    unsigned int row = blockIdx.x * blockDim.x + threadIdx.x;
    if (row >= left_len) return;
    unsigned long long probe = left[row];
    unsigned int lo = 0, hi = right_len;
    while (lo < hi) {
        unsigned int mid = lo + ((hi - lo) >> 1);
        if (right[mid] < probe) lo = mid + 1;
        else hi = mid;
    }
    bool hit = (lo < right_len && right[lo] == probe);
    out[row] = (hit == (keep_matches != 0)) ? 1 : 0;
}

// Two-key membership: two columns per side; the right pairs are sorted-unique
// lexicographically.
extern "C" __global__ void membership2(const unsigned long long* left_a,
                                       const unsigned long long* left_b,
                                       const unsigned long long* right_a,
                                       const unsigned long long* right_b,
                                       unsigned char* out,
                                       unsigned int left_len,
                                       unsigned int right_len,
                                       unsigned int keep_matches) {
    unsigned int row = blockIdx.x * blockDim.x + threadIdx.x;
    if (row >= left_len) return;
    unsigned long long p0 = left_a[row], p1 = left_b[row];
    unsigned int lo = 0, hi = right_len;
    while (lo < hi) {
        unsigned int mid = lo + ((hi - lo) >> 1);
        unsigned long long r0 = right_a[mid], r1 = right_b[mid];
        if (r0 < p0 || (r0 == p0 && r1 < p1)) lo = mid + 1;
        else hi = mid;
    }
    bool hit = (lo < right_len && right_a[lo] == p0 && right_b[lo] == p1);
    out[row] = (hit == (keep_matches != 0)) ? 1 : 0;
}

// One thread per (query, doc) pair, the same arithmetic as the CPU reference.
extern "C" __global__ void cosine(const float* queries,
                                  const float* docs,
                                  float* out,
                                  unsigned int dim,
                                  unsigned int n_docs,
                                  unsigned int n_queries) {
    unsigned long long tid = (unsigned long long)blockIdx.x * blockDim.x + threadIdx.x;
    unsigned long long total = (unsigned long long)n_queries * n_docs;
    if (tid >= total) return;
    unsigned int q = (unsigned int)(tid / n_docs);
    unsigned int i = (unsigned int)(tid % n_docs);
    const float* qv = queries + (unsigned long long)q * dim;
    const float* dv = docs + (unsigned long long)i * dim;
    float d2 = 0.0f, qn = 0.0f, dn = 0.0f;
    for (unsigned int d = 0; d < dim; d++) {
        float a = qv[d], b = dv[d];
        d2 += a * b; qn += a * a; dn += b * b;
    }
    out[tid] = d2 / (sqrtf(qn) * sqrtf(dn) + 1e-9f);
}

// Equality join over one or two key columns (see accel.join_pairs):
// join_count finds each probe's equal range in the sorted right keys, the
// host turns counts into offsets, join_fill writes each probe's pairs there.
__device__ int join_key_cmp(unsigned long long a0, unsigned long long a1,
                            unsigned long long b0, unsigned long long b1,
                            unsigned int width) {
    if (a0 < b0) return -1;
    if (a0 > b0) return 1;
    if (width == 1) return 0;
    if (a1 < b1) return -1;
    if (a1 > b1) return 1;
    return 0;
}

extern "C" __global__ void join_count(const unsigned long long* left_a,
                                      const unsigned long long* left_b,
                                      const unsigned long long* right_a,
                                      const unsigned long long* right_b,
                                      unsigned int* first,
                                      unsigned int* count,
                                      unsigned int left_len,
                                      unsigned int right_len,
                                      unsigned int width) {
    unsigned int row = blockIdx.x * blockDim.x + threadIdx.x;
    if (row >= left_len) return;
    unsigned long long p0 = left_a[row], p1 = width == 2 ? left_b[row] : 0;
    unsigned int lo = 0, hi = right_len;
    while (lo < hi) {
        unsigned int mid = lo + ((hi - lo) >> 1);
        if (join_key_cmp(right_a[mid], width == 2 ? right_b[mid] : 0, p0, p1, width) < 0) lo = mid + 1;
        else hi = mid;
    }
    unsigned int start = lo;
    hi = right_len;
    while (lo < hi) {
        unsigned int mid = lo + ((hi - lo) >> 1);
        if (join_key_cmp(right_a[mid], width == 2 ? right_b[mid] : 0, p0, p1, width) <= 0) lo = mid + 1;
        else hi = mid;
    }
    first[row] = start;
    count[row] = lo - start;
}

extern "C" __global__ void join_fill(const unsigned int* first,
                                     const unsigned int* count,
                                     const unsigned int* offset,
                                     const unsigned int* right_rows,
                                     unsigned int* out_left,
                                     unsigned int* out_right,
                                     unsigned int left_len) {
    unsigned int row = blockIdx.x * blockDim.x + threadIdx.x;
    if (row >= left_len) return;
    unsigned int o = offset[row], f = first[row], c = count[row];
    for (unsigned int k = 0; k < c; k++) {
        out_left[o + k] = row;
        out_right[o + k] = right_rows[f + k];
    }
}
`

@(private)
CU_Result :: c.int
@(private)
CU_Device :: c.int
@(private)
CU_Context :: distinct rawptr
@(private)
CU_Module :: distinct rawptr
@(private)
CU_Function :: distinct rawptr
@(private)
CU_Device_Ptr :: distinct u64

@(private)
CU_SUCCESS :: 0
@(private)
CU_DEVICE_ATTRIBUTE_COMPUTE_CAPABILITY_MAJOR :: 75
@(private)
CU_DEVICE_ATTRIBUTE_COMPUTE_CAPABILITY_MINOR :: 76

// Driver API entry points, resolved from libcuda.so.1.
@(private)
Cuda_Driver :: struct {
	__handle:             dynlib.Library,
	cuInit:               proc "c" (flags: c.uint) -> CU_Result,
	cuDeviceGetCount:     proc "c" (count: ^c.int) -> CU_Result,
	cuDeviceGet:          proc "c" (device: ^CU_Device, ordinal: c.int) -> CU_Result,
	cuDeviceGetName:      proc "c" (name: [^]u8, length: c.int, device: CU_Device) -> CU_Result,
	cuDeviceGetAttribute: proc "c" (value: ^c.int, attribute: c.int, device: CU_Device) -> CU_Result,
	cuDevicePrimaryCtxRetain: proc "c" (ctx: ^CU_Context, device: CU_Device) -> CU_Result,
	cuCtxSetCurrent:      proc "c" (ctx: CU_Context) -> CU_Result,
	cuCtxSynchronize:     proc "c" () -> CU_Result,
	cuModuleLoadData:     proc "c" (module: ^CU_Module, image: rawptr) -> CU_Result,
	cuModuleGetFunction:  proc "c" (function: ^CU_Function, module: CU_Module, name: cstring) -> CU_Result,
	cuMemAlloc:           proc "c" (ptr: ^CU_Device_Ptr, size: c.size_t) -> CU_Result `dynlib:"cuMemAlloc_v2"`,
	cuMemFree:            proc "c" (ptr: CU_Device_Ptr) -> CU_Result `dynlib:"cuMemFree_v2"`,
	cuMemcpyHtoD:         proc "c" (dst: CU_Device_Ptr, src: rawptr, size: c.size_t) -> CU_Result `dynlib:"cuMemcpyHtoD_v2"`,
	cuMemcpyDtoH:         proc "c" (dst: rawptr, src: CU_Device_Ptr, size: c.size_t) -> CU_Result `dynlib:"cuMemcpyDtoH_v2"`,
	cuLaunchKernel: proc "c" (
		function: CU_Function,
		grid_x, grid_y, grid_z: c.uint,
		block_x, block_y, block_z: c.uint,
		shared_bytes: c.uint,
		stream: rawptr,
		params: [^]rawptr,
		extra: [^]rawptr,
	) -> CU_Result,
}

@(private)
CUDA_DRIVER_SYMBOLS :: 15

@(private)
Nvrtc_Program :: distinct rawptr

// NVRTC entry points, resolved from the first libnvrtc that loads.
@(private)
Cuda_Nvrtc :: struct {
	__handle:               dynlib.Library,
	nvrtcCreateProgram: proc "c" (
		program: ^Nvrtc_Program,
		source: cstring,
		name: cstring,
		num_headers: c.int,
		headers: [^]cstring,
		include_names: [^]cstring,
	) -> c.int,
	nvrtcCompileProgram:    proc "c" (program: Nvrtc_Program, num_options: c.int, options: [^]cstring) -> c.int,
	nvrtcGetCUBINSize:      proc "c" (program: Nvrtc_Program, size: ^c.size_t) -> c.int,
	nvrtcGetCUBIN:          proc "c" (program: Nvrtc_Program, cubin: [^]u8) -> c.int,
	nvrtcGetProgramLogSize: proc "c" (program: Nvrtc_Program, size: ^c.size_t) -> c.int,
	nvrtcGetProgramLog:     proc "c" (program: Nvrtc_Program, log: [^]u8) -> c.int,
	nvrtcDestroyProgram:    proc "c" (program: ^Nvrtc_Program) -> c.int,
}

@(private)
CUDA_NVRTC_SYMBOLS :: 7

// Tried in order; the unversioned name only exists with a toolkit's dev
// symlink, so the sonames come first.
@(private)
NVRTC_LIBRARIES :: [?]string{"libnvrtc.so.13", "libnvrtc.so.12", "libnvrtc.so"}

// One device's context and compiled kernels, built on first use.
@(private)
Cuda_Device_State :: struct {
	tried:      bool,
	ready:      bool,
	device:     CU_Device,
	ctx:        CU_Context,
	module:     CU_Module,
	membership: CU_Function,
	membership2: CU_Function,
	cosine:     CU_Function,
	join_count: CU_Function,
	join_fill:  CU_Function,
	name_buf:   [128]u8,
	name:       string,
	cc_major:   int,
	cc_minor:   int,
}

@(private)
Cuda_Backend :: struct {
	mutex:        sync.Mutex,
	probed:       bool,
	loaded:       bool,
	driver:       Cuda_Driver,
	nvrtc:        Cuda_Nvrtc,
	device_count: int,
	current:      int,
	devices:      [CUDA_MAX_DEVICES]Cuda_Device_State,
}

@(private)
cuda_backend: Cuda_Backend

// Loads the libraries and counts devices, once. Caller holds the mutex.
@(private)
cuda_probe_locked :: proc() {
	be := &cuda_backend
	if be.probed {
		return
	}
	be.probed = true
	count, ok := dynlib.initialize_symbols(&be.driver, "libcuda.so.1")
	if !ok || count != CUDA_DRIVER_SYMBOLS {
		return
	}
	nvrtc_ok := false
	for path in NVRTC_LIBRARIES {
		n, loaded := dynlib.initialize_symbols(&be.nvrtc, path)
		if loaded && n == CUDA_NVRTC_SYMBOLS {
			nvrtc_ok = true
			break
		}
	}
	if !nvrtc_ok {
		return
	}
	if be.driver.cuInit(0) != CU_SUCCESS {
		return
	}
	n: c.int
	if be.driver.cuDeviceGetCount(&n) != CU_SUCCESS || n < 1 {
		return
	}
	be.device_count = min(int(n), CUDA_MAX_DEVICES)
	be.loaded = true
}

// Reports why a device cannot be used, once (device init runs once).
@(private)
cuda_device_failed :: proc(ordinal: int, step: string, result: CU_Result) -> ^Cuda_Device_State {
	log.warnf("accel: CUDA device %d unusable: %s failed (CUresult %d)", ordinal, step, result)
	return nil
}

// Creates device `ordinal`'s context and kernels on first use. Caller holds
// the mutex. Returns the state, or nil when the device cannot be used.
@(private)
cuda_device_locked :: proc(ordinal: int) -> ^Cuda_Device_State {
	be := &cuda_backend
	cuda_probe_locked()
	if !be.loaded || ordinal < 0 || ordinal >= be.device_count {
		return nil
	}
	state := &be.devices[ordinal]
	if state.tried {
		return state.ready ? state : nil
	}
	state.tried = true
	drv := &be.driver
	if r := drv.cuDeviceGet(&state.device, c.int(ordinal)); r != CU_SUCCESS {
		return cuda_device_failed(ordinal, "cuDeviceGet", r)
	}
	major, minor: c.int
	if r := drv.cuDeviceGetAttribute(&major, CU_DEVICE_ATTRIBUTE_COMPUTE_CAPABILITY_MAJOR, state.device); r != CU_SUCCESS {
		return cuda_device_failed(ordinal, "compute capability", r)
	}
	if r := drv.cuDeviceGetAttribute(&minor, CU_DEVICE_ATTRIBUTE_COMPUTE_CAPABILITY_MINOR, state.device); r != CU_SUCCESS {
		return cuda_device_failed(ordinal, "compute capability", r)
	}
	state.cc_major, state.cc_minor = int(major), int(minor)
	if drv.cuDeviceGetName(&state.name_buf[0], len(state.name_buf) - 1, state.device) == CU_SUCCESS {
		state.name = string(cstring(&state.name_buf[0]))
	}
	if r := drv.cuDevicePrimaryCtxRetain(&state.ctx, state.device); r != CU_SUCCESS {
		return cuda_device_failed(ordinal, "cuDevicePrimaryCtxRetain", r)
	}
	if r := drv.cuCtxSetCurrent(state.ctx); r != CU_SUCCESS {
		return cuda_device_failed(ordinal, "cuCtxSetCurrent", r)
	}
	cubin, cubin_ok := cuda_compile(&be.nvrtc, state.cc_major, state.cc_minor)
	if !cubin_ok {
		return cuda_device_failed(ordinal, "NVRTC compile", 0)
	}
	defer delete(cubin)
	if r := drv.cuModuleLoadData(&state.module, raw_data(cubin)); r != CU_SUCCESS {
		return cuda_device_failed(ordinal, "cuModuleLoadData", r)
	}
	if r := drv.cuModuleGetFunction(&state.membership, state.module, "membership"); r != CU_SUCCESS {
		return cuda_device_failed(ordinal, "cuModuleGetFunction(membership)", r)
	}
	if r := drv.cuModuleGetFunction(&state.membership2, state.module, "membership2"); r != CU_SUCCESS {
		return cuda_device_failed(ordinal, "cuModuleGetFunction(membership2)", r)
	}
	if r := drv.cuModuleGetFunction(&state.cosine, state.module, "cosine"); r != CU_SUCCESS {
		return cuda_device_failed(ordinal, "cuModuleGetFunction(cosine)", r)
	}
	if r := drv.cuModuleGetFunction(&state.join_count, state.module, "join_count"); r != CU_SUCCESS {
		return cuda_device_failed(ordinal, "cuModuleGetFunction(join_count)", r)
	}
	if r := drv.cuModuleGetFunction(&state.join_fill, state.module, "join_fill"); r != CU_SUCCESS {
		return cuda_device_failed(ordinal, "cuModuleGetFunction(join_fill)", r)
	}
	state.ready = true
	return state
}

// Compiles CUDA_KERNELS to a cubin for compute capability major.minor.
@(private)
cuda_compile :: proc(nvrtc: ^Cuda_Nvrtc, major, minor: int) -> (cubin: []u8, ok: bool) {
	program: Nvrtc_Program
	if nvrtc.nvrtcCreateProgram(&program, CUDA_KERNELS, "mica_accel.cu", 0, nil, nil) != 0 {
		return nil, false
	}
	defer nvrtc.nvrtcDestroyProgram(&program)
	arch := fmt.ctprintf("--gpu-architecture=sm_%d%d", major, minor)
	options := [?]cstring{arch, "--std=c++11"}
	if nvrtc.nvrtcCompileProgram(program, len(options), &options[0]) != 0 {
		log_size: c.size_t
		if nvrtc.nvrtcGetProgramLogSize(program, &log_size) == 0 && log_size > 1 {
			program_log := make([]u8, int(log_size), context.temp_allocator)
			nvrtc.nvrtcGetProgramLog(program, raw_data(program_log))
			log.errorf("accel: NVRTC compile for sm_%d%d failed:\n%s", major, minor, string(program_log))
		}
		return nil, false
	}
	size: c.size_t
	if nvrtc.nvrtcGetCUBINSize(program, &size) != 0 || size == 0 {
		return nil, false
	}
	cubin = make([]u8, int(size))
	if nvrtc.nvrtcGetCUBIN(program, raw_data(cubin)) != 0 {
		delete(cubin)
		return nil, false
	}
	return cubin, true
}

// Number of CUDA devices usable by this process (0 without a driver).
cuda_device_count :: proc() -> int {
	sync.mutex_lock(&cuda_backend.mutex)
	defer sync.mutex_unlock(&cuda_backend.mutex)
	cuda_probe_locked()
	return cuda_backend.device_count
}

// Routes subsequent CUDA operators to device `ordinal`. Returns false, leaving
// the selection unchanged, when that device is out of range or unusable.
cuda_select_device :: proc(ordinal: int) -> bool {
	sync.mutex_lock(&cuda_backend.mutex)
	defer sync.mutex_unlock(&cuda_backend.mutex)
	if cuda_device_locked(ordinal) == nil {
		return false
	}
	cuda_backend.current = ordinal
	return true
}

// Name and compute capability of the selected device, for reports.
cuda_device_name :: proc() -> (name: string, cc_major: int, cc_minor: int, ok: bool) {
	sync.mutex_lock(&cuda_backend.mutex)
	defer sync.mutex_unlock(&cuda_backend.mutex)
	state := cuda_device_locked(cuda_backend.current)
	if state == nil {
		return "", 0, 0, false
	}
	return state.name, state.cc_major, state.cc_minor, true
}

cuda_available_impl :: proc() -> bool {
	sync.mutex_lock(&cuda_backend.mutex)
	defer sync.mutex_unlock(&cuda_backend.mutex)
	return cuda_device_locked(cuda_backend.current) != nil
}

// Makes the selected device's context current on this thread. Caller holds
// the mutex. CUDA contexts are per-thread, and operators run on whichever
// scheduler worker calls them.
@(private)
cuda_enter_locked :: proc() -> ^Cuda_Device_State {
	state := cuda_device_locked(cuda_backend.current)
	if state == nil {
		return nil
	}
	if cuda_backend.driver.cuCtxSetCurrent(state.ctx) != CU_SUCCESS {
		return nil
	}
	return state
}

// Device allocations for one operator call, freed together.
@(private)
Cuda_Buffers :: struct {
	ptrs:  [16]CU_Device_Ptr,
	count: int,
}

@(private)
cuda_alloc :: proc(drv: ^Cuda_Driver, bufs: ^Cuda_Buffers, size: int) -> (CU_Device_Ptr, bool) {
	ptr: CU_Device_Ptr
	if drv.cuMemAlloc(&ptr, c.size_t(max(size, 1))) != CU_SUCCESS {
		return 0, false
	}
	bufs.ptrs[bufs.count] = ptr
	bufs.count += 1
	return ptr, true
}

@(private)
cuda_free_all :: proc(drv: ^Cuda_Driver, bufs: ^Cuda_Buffers) {
	for i in 0 ..< bufs.count {
		drv.cuMemFree(bufs.ptrs[i])
	}
	bufs.count = 0
}

@(private)
CUDA_BLOCK :: 256

@(private)
cuda_launch :: proc(drv: ^Cuda_Driver, function: CU_Function, threads: int, params: []rawptr) -> bool {
	blocks := (threads + CUDA_BLOCK - 1) / CUDA_BLOCK
	if blocks > int(max(u32)) {
		return false
	}
	if drv.cuLaunchKernel(function, c.uint(blocks), 1, 1, CUDA_BLOCK, 1, 1, 0, nil, raw_data(params), nil) != CU_SUCCESS {
		return false
	}
	return drv.cuCtxSynchronize() == CU_SUCCESS
}

// Probes `left` against a sorted-unique column already on the current device.
// Caller holds the mutex and has entered the device.
@(private)
cuda_membership_run_locked :: proc(
	state: ^Cuda_Device_State,
	left: []u64,
	d_right: CU_Device_Ptr,
	right_len: int,
	keep_matches: bool,
	allocator: mem.Allocator,
) -> (
	selected: []bool,
	ok: bool,
) {
	drv := &cuda_backend.driver
	bufs: Cuda_Buffers
	defer cuda_free_all(drv, &bufs)
	left_bytes := len(left) * size_of(u64)
	d_left := cuda_alloc(drv, &bufs, left_bytes) or_return
	d_out := cuda_alloc(drv, &bufs, len(left)) or_return
	if drv.cuMemcpyHtoD(d_left, raw_data(left), c.size_t(left_bytes)) != CU_SUCCESS {
		return nil, false
	}
	d_right_arg := d_right
	left_len := u32(len(left))
	right_len_u := u32(right_len)
	keep := u32(keep_matches ? 1 : 0)
	params := [?]rawptr{&d_left, &d_right_arg, &d_out, &left_len, &right_len_u, &keep}
	if !cuda_launch(drv, state.membership, len(left), params[:]) {
		return nil, false
	}
	// The kernel writes 0/1 bytes, which is Odin's bool layout: copy straight
	// into the result.
	out := make([]bool, len(left), allocator)
	if drv.cuMemcpyDtoH(raw_data(out), d_out, c.size_t(len(left))) != CU_SUCCESS {
		delete(out, allocator)
		return nil, false
	}
	last_decline = .None
	return out, true
}

// Scores queries against documents already on the current device. Caller
// holds the mutex and has entered the device.
@(private)
cuda_cosine_run_locked :: proc(
	state: ^Cuda_Device_State,
	queries: []f32,
	n_queries: int,
	d_docs: CU_Device_Ptr,
	n_docs: int,
	dim: int,
	allocator: mem.Allocator,
) -> (
	scores: []f32,
	ok: bool,
) {
	drv := &cuda_backend.driver
	bufs: Cuda_Buffers
	defer cuda_free_all(drv, &bufs)
	total := n_queries * n_docs
	query_bytes := n_queries * dim * size_of(f32)
	d_queries := cuda_alloc(drv, &bufs, query_bytes) or_return
	d_out := cuda_alloc(drv, &bufs, total * size_of(f32)) or_return
	if drv.cuMemcpyHtoD(d_queries, raw_data(queries), c.size_t(query_bytes)) != CU_SUCCESS {
		return nil, false
	}
	d_docs_arg := d_docs
	dim_u := u32(dim)
	nd_u := u32(n_docs)
	nq_u := u32(n_queries)
	params := [?]rawptr{&d_queries, &d_docs_arg, &d_out, &dim_u, &nd_u, &nq_u}
	if !cuda_launch(drv, state.cosine, total, params[:]) {
		return nil, false
	}
	out := make([]f32, total, allocator)
	if drv.cuMemcpyDtoH(raw_data(out), d_out, c.size_t(total * size_of(f32))) != CU_SUCCESS {
		delete(out, allocator)
		return nil, false
	}
	last_decline = .None
	return out, true
}

// Size checks for membership: small inputs decline Below_Threshold, inputs
// past the kernels' u32 indexing decline Unsupported.
@(private)
cuda_membership_admit :: proc(left_len: int, right_len: int) -> bool {
	if left_len < CUDA_MEMBERSHIP_MIN_ROWS || right_len == 0 {
		last_decline = .Below_Threshold
		return false
	}
	if left_len > int(max(u32)) || right_len > int(max(u32)) {
		last_decline = .Unsupported
		return false
	}
	return true
}

// Size and shape checks for cosine, with the same reasons as membership.
@(private)
cuda_cosine_admit :: proc(n_queries: int, n_docs: int, dim: int) -> bool {
	if n_docs < CUDA_COSINE_MIN_DOCS {
		last_decline = .Below_Threshold
		return false
	}
	if n_queries < 1 || dim < 1 || n_docs > int(max(u32)) || n_queries > int(max(u32)) || dim > int(max(u32)) {
		last_decline = .Unsupported
		return false
	}
	return true
}

// Operators never wait for the device: a held backend lock declines Busy so
// the caller runs its CPU path (the same rule as Rust mica's admission).
// Device setup, uploads and release still wait.
@(private)
cuda_operator_try_lock :: proc() -> bool {
	if !sync.mutex_try_lock(&cuda_backend.mutex) {
		last_decline = .Busy
		return false
	}
	return true
}

// Membership probe against a sorted-unique right column, uploaded for this
// call only. Small inputs and any failure decline to CPU.
cuda_membership_select_impl :: proc(
	left: []u64,
	right_sorted_unique: []u64,
	keep_matches: bool,
	allocator: mem.Allocator,
) -> (
	selected: []bool,
	accelerated: bool,
) {
	last_decline = .Failed
	if !cuda_membership_admit(len(left), len(right_sorted_unique)) {
		return nil, false
	}
	if !is_sorted_unique(right_sorted_unique) {
		last_decline = .Unsupported
		return nil, false
	}
	if !cuda_operator_try_lock() {
		return nil, false
	}
	defer sync.mutex_unlock(&cuda_backend.mutex)
	state := cuda_enter_locked()
	if state == nil {
		last_decline = .Unavailable
		return nil, false
	}
	drv := &cuda_backend.driver
	bufs: Cuda_Buffers
	defer cuda_free_all(drv, &bufs)
	right_bytes := len(right_sorted_unique) * size_of(u64)
	d_right := cuda_alloc(drv, &bufs, right_bytes) or_return
	if drv.cuMemcpyHtoD(d_right, raw_data(right_sorted_unique), c.size_t(right_bytes)) != CU_SUCCESS {
		return nil, false
	}
	return cuda_membership_run_locked(state, left, d_right, len(right_sorted_unique), keep_matches, allocator)
}

// Two-key membership over two columns per side, uploaded for this call only.
// membership_selection has checked shape and sort order.
cuda_membership_select2_impl :: proc(
	left_a, left_b, right_a, right_b: []u64,
	keep_matches: bool,
	allocator: mem.Allocator,
) -> (
	selected: []bool,
	accelerated: bool,
) {
	last_decline = .Failed
	n_left, n_right := len(left_a), len(right_a)
	if !cuda_membership_admit(n_left, n_right) {
		return nil, false
	}
	if !cuda_operator_try_lock() {
		return nil, false
	}
	defer sync.mutex_unlock(&cuda_backend.mutex)
	state := cuda_enter_locked()
	if state == nil {
		last_decline = .Unavailable
		return nil, false
	}
	drv := &cuda_backend.driver
	bufs: Cuda_Buffers
	defer cuda_free_all(drv, &bufs)
	left_bytes := n_left * size_of(u64)
	right_bytes := n_right * size_of(u64)
	d_left_a := cuda_alloc(drv, &bufs, left_bytes) or_return
	d_left_b := cuda_alloc(drv, &bufs, left_bytes) or_return
	d_right_a := cuda_alloc(drv, &bufs, right_bytes) or_return
	d_right_b := cuda_alloc(drv, &bufs, right_bytes) or_return
	d_out := cuda_alloc(drv, &bufs, n_left) or_return
	if drv.cuMemcpyHtoD(d_left_a, raw_data(left_a), c.size_t(left_bytes)) != CU_SUCCESS ||
	   drv.cuMemcpyHtoD(d_left_b, raw_data(left_b), c.size_t(left_bytes)) != CU_SUCCESS ||
	   drv.cuMemcpyHtoD(d_right_a, raw_data(right_a), c.size_t(right_bytes)) != CU_SUCCESS ||
	   drv.cuMemcpyHtoD(d_right_b, raw_data(right_b), c.size_t(right_bytes)) != CU_SUCCESS {
		return nil, false
	}
	left_len := u32(n_left)
	right_len := u32(n_right)
	keep := u32(keep_matches ? 1 : 0)
	params := [?]rawptr{&d_left_a, &d_left_b, &d_right_a, &d_right_b, &d_out, &left_len, &right_len, &keep}
	if !cuda_launch(drv, state.membership2, n_left, params[:]) {
		return nil, false
	}
	out := make([]bool, n_left, allocator)
	if drv.cuMemcpyDtoH(raw_data(out), d_out, c.size_t(n_left)) != CU_SUCCESS {
		delete(out, allocator)
		return nil, false
	}
	last_decline = .None
	return out, true
}

// Cosine similarity of `queries` (n_queries x dim) against `docs`
// (n_docs x dim), uploaded for this call only; returns n_queries * n_docs
// scores, query-major.
cuda_cosine_queries_impl :: proc(
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
	if !cuda_cosine_admit(n_queries, n_docs, dim) {
		return nil, false
	}
	if len(queries) < n_queries * dim || len(docs) < n_docs * dim {
		last_decline = .Unsupported
		return nil, false
	}
	if !cuda_operator_try_lock() {
		return nil, false
	}
	defer sync.mutex_unlock(&cuda_backend.mutex)
	state := cuda_enter_locked()
	if state == nil {
		last_decline = .Unavailable
		return nil, false
	}
	drv := &cuda_backend.driver
	bufs: Cuda_Buffers
	defer cuda_free_all(drv, &bufs)
	doc_bytes := n_docs * dim * size_of(f32)
	d_docs := cuda_alloc(drv, &bufs, doc_bytes) or_return
	if drv.cuMemcpyHtoD(d_docs, raw_data(docs), c.size_t(doc_bytes)) != CU_SUCCESS {
		return nil, false
	}
	return cuda_cosine_run_locked(state, queries, n_queries, d_docs, n_docs, dim, allocator)
}

cuda_cosine_query_impl :: proc(
	query: []f32,
	docs: []f32,
	n_docs: int,
	dim: int,
	allocator: mem.Allocator,
) -> (
	scores: []f32,
	accelerated: bool,
) {
	return cuda_cosine_queries_impl(query, docs, 1, n_docs, dim, allocator)
}

// A prepared input in device memory. Owned by the device it was uploaded to:
// operators decline it while another device is selected.
@(private)
Cuda_Resident :: struct {
	device: int,
	ptr:    CU_Device_Ptr,
}

// Uploads bytes to the selected device and wraps them as a resident handle.
@(private)
cuda_upload_resident :: proc(data: rawptr, size: int) -> (handle: rawptr, ok: bool) {
	// Called from rule evaluation: like the operators, never wait for the
	// device (spec §2); a busy backend declines and the step runs unprepared.
	if !cuda_operator_try_lock() {
		return nil, false
	}
	defer sync.mutex_unlock(&cuda_backend.mutex)
	if cuda_enter_locked() == nil {
		last_decline = .Unavailable
		return nil, false
	}
	drv := &cuda_backend.driver
	ptr: CU_Device_Ptr
	if drv.cuMemAlloc(&ptr, c.size_t(max(size, 1))) != CU_SUCCESS {
		return nil, false
	}
	if drv.cuMemcpyHtoD(ptr, data, c.size_t(size)) != CU_SUCCESS {
		drv.cuMemFree(ptr)
		return nil, false
	}
	resident := new(Cuda_Resident)
	resident^ = Cuda_Resident{device = cuda_backend.current, ptr = ptr}
	return resident, true
}

// Enters the device a resident handle lives on, if it is the selected one.
// Caller holds the mutex.
@(private)
cuda_enter_resident_locked :: proc(handle: rawptr) -> ^Cuda_Device_State {
	if (^Cuda_Resident)(handle).device != cuda_backend.current {
		return nil
	}
	return cuda_enter_locked()
}

cuda_prepare_column_impl :: proc(sorted_unique: []u64) -> (handle: rawptr, ok: bool) {
	if len(sorted_unique) == 0 || len(sorted_unique) > int(max(u32)) {
		return nil, false
	}
	return cuda_upload_resident(raw_data(sorted_unique), len(sorted_unique) * size_of(u64))
}

cuda_prepare_docs_impl :: proc(docs: []f32, n_docs: int, dim: int) -> (handle: rawptr, ok: bool) {
	if n_docs > int(max(u32)) || dim > int(max(u32)) {
		return nil, false
	}
	return cuda_upload_resident(raw_data(docs), n_docs * dim * size_of(f32))
}

// Membership against a resident column: only the probes and flags cross PCIe.
cuda_membership_select_prepared_impl :: proc(
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
	if !cuda_membership_admit(len(left), rows) {
		return nil, false
	}
	if !cuda_operator_try_lock() {
		return nil, false
	}
	defer sync.mutex_unlock(&cuda_backend.mutex)
	state := cuda_enter_resident_locked(column)
	if state == nil {
		last_decline = .Unavailable
		return nil, false
	}
	return cuda_membership_run_locked(state, left, (^Cuda_Resident)(column).ptr, rows, keep_matches, allocator)
}

// Cosine against resident documents: only the queries and scores cross PCIe.
cuda_cosine_queries_prepared_impl :: proc(
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
	if !cuda_cosine_admit(n_queries, n_docs, dim) {
		return nil, false
	}
	if !cuda_operator_try_lock() {
		return nil, false
	}
	defer sync.mutex_unlock(&cuda_backend.mutex)
	state := cuda_enter_resident_locked(docs)
	if state == nil {
		last_decline = .Unavailable
		return nil, false
	}
	return cuda_cosine_run_locked(state, queries, n_queries, (^Cuda_Resident)(docs).ptr, n_docs, dim, allocator)
}

// Frees a resident handle on the device that owns it, whichever is selected.
cuda_release_impl :: proc(handle: rawptr, kind: Prepared_Kind) {
	resident := (^Cuda_Resident)(handle)
	sync.mutex_lock(&cuda_backend.mutex)
	defer sync.mutex_unlock(&cuda_backend.mutex)
	state := &cuda_backend.devices[resident.device]
	if state.ready && cuda_backend.driver.cuCtxSetCurrent(state.ctx) == CU_SUCCESS {
		cuda_backend.driver.cuMemFree(resident.ptr)
	}
	free(resident)
}

// Equality join on the current device, inputs uploaded for this call only.
// join_pairs has checked shape and sort order.
cuda_join_equality_impl :: proc(
	left, right: [][]u64,
	right_rows: []u32,
	allocator: mem.Allocator,
) -> (
	left_out, right_out: []u32,
	accelerated: bool,
) {
	last_decline = .Failed
	n, m := len(left[0]), len(right_rows)
	if n < CUDA_JOIN_MIN_PROBES {
		last_decline = .Below_Threshold
		return nil, nil, false
	}
	if n > int(max(u32)) || m > int(max(u32)) {
		last_decline = .Unsupported
		return nil, nil, false
	}
	if !cuda_operator_try_lock() {
		return nil, nil, false
	}
	defer sync.mutex_unlock(&cuda_backend.mutex)
	state := cuda_enter_locked()
	if state == nil {
		last_decline = .Unavailable
		return nil, nil, false
	}
	drv := &cuda_backend.driver
	bufs: Cuda_Buffers
	defer cuda_free_all(drv, &bufs)
	width := len(left)
	upload :: proc(drv: ^Cuda_Driver, bufs: ^Cuda_Buffers, data: []$T) -> (ptr: CU_Device_Ptr, ok: bool) {
		bytes := len(data) * size_of(T)
		ptr = cuda_alloc(drv, bufs, bytes) or_return
		if bytes > 0 && drv.cuMemcpyHtoD(ptr, raw_data(data), c.size_t(bytes)) != CU_SUCCESS {
			return 0, false
		}
		return ptr, true
	}
	d_la := upload(drv, &bufs, left[0]) or_return
	d_ra := upload(drv, &bufs, right[0]) or_return
	d_lb, d_rb := d_la, d_ra
	if width == 2 {
		d_lb = upload(drv, &bufs, left[1]) or_return
		d_rb = upload(drv, &bufs, right[1]) or_return
	}
	d_first := cuda_alloc(drv, &bufs, n * 4) or_return
	d_count := cuda_alloc(drv, &bufs, n * 4) or_return
	left_len, right_len, w := u32(n), u32(m), u32(width)
	count_params := [?]rawptr{&d_la, &d_lb, &d_ra, &d_rb, &d_first, &d_count, &left_len, &right_len, &w}
	if !cuda_launch(drv, state.join_count, n, count_params[:]) {
		return nil, nil, false
	}
	counts := make([]u32, n, context.temp_allocator)
	if drv.cuMemcpyDtoH(raw_data(counts), d_count, c.size_t(n * 4)) != CU_SUCCESS {
		return nil, nil, false
	}
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
	if total > int(max(u32)) {
		last_decline = .Unsupported
		return nil, nil, false
	}
	d_offset := upload(drv, &bufs, offsets) or_return
	d_rows := upload(drv, &bufs, right_rows) or_return
	d_outl := cuda_alloc(drv, &bufs, total * 4) or_return
	d_outr := cuda_alloc(drv, &bufs, total * 4) or_return
	fill_params := [?]rawptr{&d_first, &d_count, &d_offset, &d_rows, &d_outl, &d_outr, &left_len}
	if !cuda_launch(drv, state.join_fill, n, fill_params[:]) {
		return nil, nil, false
	}
	left_out = make([]u32, total, allocator)
	right_out = make([]u32, total, allocator)
	if drv.cuMemcpyDtoH(raw_data(left_out), d_outl, c.size_t(total * 4)) != CU_SUCCESS ||
	   drv.cuMemcpyDtoH(raw_data(right_out), d_outr, c.size_t(total * 4)) != CU_SUCCESS {
		delete(left_out, allocator)
		delete(right_out, allocator)
		return nil, nil, false
	}
	last_decline = .None
	return left_out, right_out, true
}
