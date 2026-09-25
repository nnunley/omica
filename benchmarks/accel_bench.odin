// A/B benchmarks: identical workloads through the CPU reference strategy
// and GPU strategies (Metal on Darwin, CUDA on Linux). Each pair shares
// inputs; the delta column (via -baseline) shows the speedup. GPU entries
// are registered only when their device is usable.
//
// accel/compare holds the small sizes the kernel's thresholds sit near;
// accel/scale holds sizes where a discrete GPU can amortize its PCIe copies
// (every call still copies inputs and results; nothing is device-resident).
package main

import "core:fmt"
import "core:mem"
import "core:mem/virtual"

import mm "../vendor/micromeasure/micromeasure-odin"
import accl "../mica/kernel/accel"
import v "../mica/var"

Accel_State :: struct {
	arena: virtual.Arena,
	alloc: mem.Allocator,

	cpu:   accl.Strategy,
	// Populated only on Darwin; the bench bodies that read it are
	// `when ODIN_OS == .Darwin` gated, so Linux never touches it.
	metal: accl.Strategy,
	// Populated only on Linux, likewise gated.
	cuda:  accl.Strategy,

	mem_left:  []u64,
	mem_right: []u64,

	cos_query: []f32,
	cos_docs:  []f32,
	cos_dim:   int,
	cos_docs_n: int,
	cos_cands: []accl.Cosine_Candidate,

	sink: u64,
}

// Large workloads for accel/scale, shared by every strategy.
Accel_Scale :: struct {
	mem_left:   []u64,
	mem_right:  []u64,
	queries:    []f32,
	docs:       []f32,
	n_queries:  int,
	n_docs:     int,
	dim:        int,
	sink:       u64,
}

// One registered scale benchmark: a strategy and, for CUDA, the device to
// select before each chunk (the CUDA strategy runs on the selected device).
Accel_Scale_Case :: struct {
	scale:    ^Accel_Scale,
	strategy: accl.Strategy,
	device:   int,
	// Resident copies of the scale column and documents, prepared once at
	// registration; empty when the strategy has no residency.
	column:   accl.Prepared,
	docs:     accl.Prepared,
}

SCALE_MEMBERSHIP_ROWS :: 1 << 20
SCALE_QUERIES :: 64
SCALE_DOCS :: 8192
SCALE_DIM :: 768

@(private)
accel_scale_init :: proc(allocator: mem.Allocator) -> ^Accel_Scale {
	scale := new(Accel_Scale, allocator)
	n := SCALE_MEMBERSHIP_ROWS
	scale.mem_left = make([]u64, n, allocator)
	scale.mem_right = make([]u64, n, allocator)
	for i in 0 ..< n {
		// Scattered probes over twice the right column's range: half hit.
		scale.mem_left[i] = (u64(i) * 2654435761) % u64(2 * n)
		scale.mem_right[i] = u64(i) * 2
	}
	scale.n_queries, scale.n_docs, scale.dim = SCALE_QUERIES, SCALE_DOCS, SCALE_DIM
	scale.queries = make([]f32, scale.n_queries * scale.dim, allocator)
	scale.docs = make([]f32, scale.n_docs * scale.dim, allocator)
	for i in 0 ..< len(scale.queries) {
		scale.queries[i] = f32((i * 37) % 23) / 11.0 - 1.0
	}
	for i in 0 ..< len(scale.docs) {
		scale.docs[i] = f32((i * 53) % 29) / 14.0 - 1.0
	}
	return scale
}

@(private)
scale_enter :: proc(sc: ^Accel_Scale_Case) {
	when ODIN_OS == .Linux {
		if sc.device >= 0 {
			accl.cuda_select_device(sc.device)
		}
	}
}

@(private)
bench_scale_membership :: proc(user: rawptr, chunk: int, _: int) {
	sc := (^Accel_Scale_Case)(user)
	scale_enter(sc)
	total := u64(0)
	for _ in 0 ..< chunk {
		selected, ok := sc.strategy.membership_select(sc.scale.mem_left, sc.scale.mem_right, true, context.allocator)
		if ok {
			total += u64(len(selected))
			delete(selected)
		}
	}
	sc.scale.sink = mm.black_box(total)
}

@(private)
bench_scale_cosine :: proc(user: rawptr, chunk: int, _: int) {
	sc := (^Accel_Scale_Case)(user)
	scale_enter(sc)
	s := sc.scale
	total := u64(0)
	for _ in 0 ..< chunk {
		scores, ok := sc.strategy.cosine_queries(s.queries, s.docs, s.n_queries, s.n_docs, s.dim, context.allocator)
		if ok {
			total += u64(len(scores))
			delete(scores)
		}
	}
	s.sink = mm.black_box(total)
}

@(private)
bench_scale_membership_resident :: proc(user: rawptr, chunk: int, _: int) {
	sc := (^Accel_Scale_Case)(user)
	scale_enter(sc)
	total := u64(0)
	for _ in 0 ..< chunk {
		selected, ok := accl.membership_select_prepared(sc.strategy, sc.scale.mem_left, sc.column, true, context.allocator)
		if ok {
			total += u64(len(selected))
			delete(selected)
		}
	}
	sc.scale.sink = mm.black_box(total)
}

@(private)
bench_scale_cosine_resident :: proc(user: rawptr, chunk: int, _: int) {
	sc := (^Accel_Scale_Case)(user)
	scale_enter(sc)
	s := sc.scale
	total := u64(0)
	for _ in 0 ..< chunk {
		scores, ok := accl.cosine_queries_prepared(sc.strategy, s.queries, s.n_queries, sc.docs, context.allocator)
		if ok {
			total += u64(len(scores))
			delete(scores)
		}
	}
	s.sink = mm.black_box(total)
}

// Registers the scale benchmarks for one strategy, named <op>_<label>: inputs
// passed per call, then (when the strategy supports residency) against a
// column and document matrix prepared once. Prepared inputs live for the run.
@(private)
register_scale_case :: proc(group: ^mm.Group, scale: ^Accel_Scale, label: string, strategy: accl.Strategy, device: int) {
	sc := new(Accel_Scale_Case)
	sc^ = Accel_Scale_Case{scale = scale, strategy = strategy, device = device}
	mm.bench(group, fmt.aprintf("membership_%s_1m", label), sc, bench_scale_membership)
	mm.bench(group, fmt.aprintf("cosine_%s_64x8k_x768", label), sc, bench_scale_cosine)
	scale_enter(sc)
	if column, ok := accl.prepare_column(strategy, scale.mem_right); ok {
		sc.column = column
		mm.bench(group, fmt.aprintf("membership_%s_resident_1m", label), sc, bench_scale_membership_resident)
	}
	if docs, ok := accl.prepare_docs(strategy, scale.docs, scale.n_docs, scale.dim); ok {
		sc.docs = docs
		mm.bench(group, fmt.aprintf("cosine_%s_resident_64x8k_x768", label), sc, bench_scale_cosine_resident)
	}
}

@(private)
accel_state_init :: proc() -> ^Accel_State {
	state := new(Accel_State)
	if err := virtual.arena_init_growing(&state.arena); err != nil {
		panic("failed to initialize accel benchmark arena")
	}
	state.alloc = virtual.arena_allocator(&state.arena)
	state.cpu = accl.cpu_strategy()
	when ODIN_OS == .Darwin {
		state.metal = accl.metal_strategy()
	}
	when ODIN_OS == .Linux {
		state.cuda = accl.cuda_strategy()
	}

	n := 8192
	state.mem_left = make([]u64, n, state.alloc)
	state.mem_right = make([]u64, n / 2, state.alloc)
	for i in 0 ..< n {
		state.mem_left[i] = u64(i)
	}
	for i in 0 ..< n / 2 {
		state.mem_right[i] = u64(i * 2)
	}

	state.cos_dim = 64
	state.cos_docs_n = 2048
	state.cos_query = make([]f32, state.cos_dim, state.alloc)
	for i in 0 ..< state.cos_dim {
		state.cos_query[i] = f32(i + 1) / f32(state.cos_dim)
	}
	state.cos_docs = make([]f32, state.cos_docs_n * state.cos_dim, state.alloc)
	for i in 0 ..< len(state.cos_docs) {
		state.cos_docs[i] = f32((i % 37) + 1) / 37.0
	}
	state.cos_cands = make([]accl.Cosine_Candidate, state.cos_docs_n, state.alloc)
	for i in 0 ..< state.cos_docs_n {
		id, _ := v.identity_new(u64(1000 + i))
		state.cos_cands[i] = accl.Cosine_Candidate {
			subject = v.value_identity(id),
			vector  = state.cos_docs[i * state.cos_dim:(i + 1) * state.cos_dim],
		}
	}
	return state
}

@(private)
bench_cpu_membership :: proc(user: rawptr, chunk: int, _: int) {
	state := (^Accel_State)(user)
	total := u64(0)
	for _ in 0 ..< chunk {
		selected, ok := state.cpu.membership_select(state.mem_left, state.mem_right, true, context.temp_allocator)
			delete(selected, context.temp_allocator)
		if ok {
			total += u64(len(selected))
		}
	}
	state.sink = mm.black_box(total)
}

when ODIN_OS == .Darwin {

	@(private)
	bench_metal_membership :: proc(user: rawptr, chunk: int, _: int) {
		state := (^Accel_State)(user)
		total := u64(0)
		for _ in 0 ..< chunk {
			selected, ok := state.metal.membership_select(
				state.mem_left,
				state.mem_right,
				true,
				context.temp_allocator,
			)
			if ok {
				total += u64(len(selected))
				delete(selected, context.temp_allocator)
			}
		}
		state.sink = mm.black_box(total)
	}

	@(private)
	bench_metal_cosine :: proc(user: rawptr, chunk: int, _: int) {
		state := (^Accel_State)(user)
		total := u64(0)
		for _ in 0 ..< chunk {
			scores, ok := state.metal.cosine_query(
				state.cos_query,
				state.cos_docs,
				state.cos_docs_n,
				state.cos_dim,
				context.temp_allocator,
			)
			if ok {
				total += u64(len(scores))
				delete(scores, context.temp_allocator)
			}
		}
		state.sink = mm.black_box(total)
	}

	@(private)
	bench_metal_top_k :: proc(user: rawptr, chunk: int, _: int) {
		state := (^Accel_State)(user)
		top_k_loop(state, chunk, state.metal)
	}
}

when ODIN_OS == .Linux {

	@(private)
	bench_cuda_membership :: proc(user: rawptr, chunk: int, _: int) {
		state := (^Accel_State)(user)
		accl.cuda_select_device(0)
		total := u64(0)
		for _ in 0 ..< chunk {
			selected, ok := state.cuda.membership_select(state.mem_left, state.mem_right, true, context.temp_allocator)
			if ok {
				total += u64(len(selected))
				delete(selected, context.temp_allocator)
			}
		}
		state.sink = mm.black_box(total)
	}

	@(private)
	bench_cuda_cosine :: proc(user: rawptr, chunk: int, _: int) {
		state := (^Accel_State)(user)
		accl.cuda_select_device(0)
		total := u64(0)
		for _ in 0 ..< chunk {
			scores, ok := state.cuda.cosine_query(
				state.cos_query,
				state.cos_docs,
				state.cos_docs_n,
				state.cos_dim,
				context.temp_allocator,
			)
			if ok {
				total += u64(len(scores))
				delete(scores, context.temp_allocator)
			}
		}
		state.sink = mm.black_box(total)
	}

	@(private)
	bench_cuda_top_k :: proc(user: rawptr, chunk: int, _: int) {
		state := (^Accel_State)(user)
		accl.cuda_select_device(0)
		top_k_loop(state, chunk, state.cuda)
	}
}

@(private)
bench_cpu_cosine :: proc(user: rawptr, chunk: int, _: int) {
	state := (^Accel_State)(user)
	total := u64(0)
	for _ in 0 ..< chunk {
		scores, ok := state.cpu.cosine_query(
			state.cos_query,
			state.cos_docs,
			state.cos_docs_n,
			state.cos_dim,
			context.temp_allocator,
		)
		if ok {
			total += u64(len(scores))
			delete(scores, context.temp_allocator)
		}
	}
	state.sink = mm.black_box(total)
}

@(private)
bench_cpu_top_k :: proc(user: rawptr, chunk: int, _: int) {
	state := (^Accel_State)(user)
	top_k_loop(state, chunk, state.cpu)
}

// Scratch arena per call: top_k allocates per-hit maps and sort temporaries,
// which must not accumulate across the chunk.
@(private)
top_k_loop :: proc(state: ^Accel_State, chunk: int, s: accl.Strategy) {
	scratch: virtual.Arena
	if err := virtual.arena_init_growing(&scratch); err != nil {
		return
	}
	defer virtual.arena_destroy(&scratch)
	total := u64(0)
	for _ in 0 ..< chunk {
		virtual.arena_free_all(&scratch)
		hits, ok := accl.cosine_top_k(
			state.cos_query,
			state.cos_cands,
			8,
			virtual.arena_allocator(&scratch),
			s,
		)
		if ok {
			total += u64(len(hits))
		}
	}
	state.sink = mm.black_box(total)
}

register_accel_benches :: proc(runner: ^mm.Runner) {
	fmt.eprintf("accel: CPU dot kernel %v\n", accl.cpu_dot_kernel())
	state := accel_state_init()
	compare := mm.group(runner, "accel/compare")
	mm.bench(compare, "membership_cpu_8k", state, bench_cpu_membership)
	mm.bench(compare, "cosine_cpu_2k_x64", state, bench_cpu_cosine)
	mm.bench(compare, "top_k_cpu_2k_x64", state, bench_cpu_top_k)
	when ODIN_OS == .Darwin {
		mm.bench(compare, "membership_metal_8k", state, bench_metal_membership)
		mm.bench(compare, "cosine_metal_2k_x64", state, bench_metal_cosine)
		mm.bench(compare, "top_k_metal_2k_x64", state, bench_metal_top_k)
	}
	when ODIN_OS == .Linux {
		if accl.cuda_select_device(0) {
			mm.bench(compare, "membership_cuda0_8k", state, bench_cuda_membership)
			mm.bench(compare, "cosine_cuda0_2k_x64", state, bench_cuda_cosine)
			mm.bench(compare, "top_k_cuda0_2k_x64", state, bench_cuda_top_k)
		}
	}

	scale := accel_scale_init(state.alloc)
	scale_group := mm.group(runner, "accel/scale")
	register_scale_case(scale_group, scale, "cpu", accl.cpu_strategy(), -1)
	register_scale_case(scale_group, scale, "cpu_parallel", accl.cpu_parallel_strategy(), -1)
	when ODIN_OS == .Darwin {
		if accl.metal_strategy().available() {
			register_scale_case(scale_group, scale, "metal", accl.metal_strategy(), -1)
		}
	}
	when ODIN_OS == .Linux {
		for device in 0 ..< accl.cuda_device_count() {
			if accl.cuda_select_device(device) {
				register_scale_case(scale_group, scale, fmt.aprintf("cuda%d", device), accl.cuda_strategy(), device)
			}
		}
		accl.cuda_select_device(0)
	}
}
