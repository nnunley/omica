// Multi-core CPU strategy: the CPU reference operators with large calls split
// by rows across worker threads. Partitioning changes no arithmetic, so the
// results equal `cpu_strategy`'s exactly.
//
// Opt-in, like the GPU strategies: the scheduler already runs one task per
// worker thread, so fanning out inside an operator can oversubscribe cores.
// Admission bounds that: one parallel call runs at a time process-wide, and a
// call arriving while it runs executes serially on its own thread instead of
// waiting (the same non-blocking decline as a busy GPU). Workers come from the
// process-wide pool in cpu_pool.odin, created once.
package accel

import "core:mem"
import "core:os"
import "core:sync"

// Below these sizes a call runs serially: waking the pool and splitting the
// work would exceed the saving.
CPU_PARALLEL_MIN_PROBES :: 65536
// Query/document pairs for cosine.
CPU_PARALLEL_MIN_PAIRS :: 16384

@(private)
cpu_parallel_workers: int

@(private)
cpu_parallel_busy: bool

@(private)
cpu_parallel_spawn_failures: int

// Pool threads that failed to start; the pool runs with that many fewer
// workers.
cpu_parallel_spawn_failure_count :: proc() -> int {
	return sync.atomic_load(&cpu_parallel_spawn_failures)
}

// The multi-core operator set. `workers` sets the process-wide worker count
// (including the calling thread); 0 means one per processor core. Residency
// is the CPU reference's.
cpu_parallel_strategy :: proc(workers := 0) -> Strategy {
	n := workers
	if n <= 0 {
		n = os.get_processor_core_count()
	}
	sync.atomic_store(&cpu_parallel_workers, max(n, 1))
	s := cpu_strategy()
	s.name = "cpu_parallel"
	s.membership_select = cpu_parallel_membership_select
	s.membership_select2 = cpu_parallel_membership_select2
	s.cosine_query = cpu_parallel_cosine_query
	s.cosine_queries = cpu_parallel_cosine_queries
	s.membership_select_prepared = cpu_parallel_membership_select_prepared
	s.cosine_queries_prepared = cpu_parallel_cosine_queries_prepared
	return s
}

// Opts production dispatch into the multi-core CPU strategy.
use_cpu_parallel :: proc(workers := 0) {
	select_strategy(cpu_parallel_strategy(workers))
}

// Runs run(job, first, last) over [0, total) split into worker-sized chunks
// on the process-wide pool (cpu_pool.odin), the calling thread taking the
// first. Returns false, having run nothing, when another parallel call holds
// the workers.
@(private)
cpu_parallel_for :: proc(total: int, job: rawptr, run: proc(job: rawptr, first, last: int)) -> bool {
	workers := min(sync.atomic_load(&cpu_parallel_workers), total)
	if workers <= 1 {
		run(job, 0, total)
		return true
	}
	if _, acquired := sync.atomic_compare_exchange_strong(&cpu_parallel_busy, false, true); !acquired {
		return false
	}
	defer sync.atomic_store(&cpu_parallel_busy, false)
	cpu_pool_start()
	cpu_pool_run(workers, total, job, run)
	return true
}

@(private)
Cpu_Membership_Job :: struct {
	left:  []u64,
	right: []u64,
	keep:  bool,
	out:   []bool,
}

@(private)
cpu_parallel_membership_rows :: proc(job: rawptr, first, last: int) {
	j := (^Cpu_Membership_Job)(job)
	for i in first ..< last {
		j.out[i] = cpu_sorted_contains(j.right, j.left[i]) == j.keep
	}
}

@(private)
cpu_parallel_membership_select :: proc(
	left: []u64,
	right_sorted_unique: []u64,
	keep_matches: bool,
	allocator: mem.Allocator,
) -> (
	selected: []bool,
	ok: bool,
) {
	if len(left) < CPU_PARALLEL_MIN_PROBES || len(right_sorted_unique) == 0 {
		return cpu_membership_select(left, right_sorted_unique, keep_matches, allocator)
	}
	if !is_sorted_unique(right_sorted_unique) {
		last_decline = .Unsupported
		return nil, false
	}
	last_decline = .None
	job := Cpu_Membership_Job{left = left, right = right_sorted_unique, keep = keep_matches}
	job.out = make([]bool, len(left), allocator)
	if !cpu_parallel_for(len(left), &job, cpu_parallel_membership_rows) {
		cpu_parallel_membership_rows(&job, 0, len(left))
	}
	return job.out, true
}

Cpu_Membership2_Job :: struct {
	left_a, left_b, right_a, right_b: []u64,
	keep:                             bool,
	out:                              []bool,
}

@(private)
cpu_parallel_membership2_rows :: proc(job: rawptr, first, last: int) {
	j := (^Cpu_Membership2_Job)(job)
	for i in first ..< last {
		j.out[i] = cpu_sorted_contains_pair(j.right_a, j.right_b, j.left_a[i], j.left_b[i]) == j.keep
	}
}

@(private)
cpu_parallel_membership_select2 :: proc(
	left_a, left_b, right_a, right_b: []u64,
	keep_matches: bool,
	allocator: mem.Allocator,
) -> (
	selected: []bool,
	ok: bool,
) {
	n := len(left_a)
	if n < CPU_PARALLEL_MIN_PROBES {
		return cpu_membership_select2(left_a, left_b, right_a, right_b, keep_matches, allocator)
	}
	last_decline = .None
	job := Cpu_Membership2_Job {
		left_a  = left_a,
		left_b  = left_b,
		right_a = right_a,
		right_b = right_b,
		keep    = keep_matches,
	}
	job.out = make([]bool, n, allocator)
	if !cpu_parallel_for(n, &job, cpu_parallel_membership2_rows) {
		cpu_parallel_membership2_rows(&job, 0, n)
	}
	return job.out, true
}

@(private)
cpu_parallel_membership_select_prepared :: proc(
	left: []u64,
	column: rawptr,
	rows: int,
	keep_matches: bool,
	allocator: mem.Allocator,
) -> (
	selected: []bool,
	ok: bool,
) {
	return cpu_parallel_membership_select(left, (^Cpu_Prepared)(column).column, keep_matches, allocator)
}

@(private)
Cpu_Cosine_Job :: struct {
	queries: []f32,
	docs:    []f32,
	n_docs:  int,
	dim:     int,
	out:     []f32,
}

// Scores pairs [first, last) of the query-major n_queries x n_docs grid.
@(private)
cpu_parallel_cosine_pairs :: proc(job: rawptr, first, last: int) {
	j := (^Cpu_Cosine_Job)(job)
	pair := first
	for pair < last {
		q := pair / j.n_docs
		doc := pair % j.n_docs
		stop := min(last - pair, j.n_docs - doc) + doc
		row := j.out[q * j.n_docs:(q + 1) * j.n_docs]
		cpu_cosine_rows(j.queries[q * j.dim:(q + 1) * j.dim], j.docs, j.dim, doc, stop, row)
		pair += stop - doc
	}
}

@(private)
cpu_parallel_cosine_queries :: proc(
	queries: []f32,
	docs: []f32,
	n_queries: int,
	n_docs: int,
	dim: int,
	allocator: mem.Allocator,
) -> (
	scores: []f32,
	ok: bool,
) {
	if n_queries * n_docs < CPU_PARALLEL_MIN_PAIRS {
		return cpu_cosine_queries(queries, docs, n_queries, n_docs, dim, allocator)
	}
	if n_queries < 1 || n_docs < 1 || dim < 1 || len(queries) < n_queries * dim || len(docs) < n_docs * dim {
		last_decline = .Unsupported
		return nil, false
	}
	last_decline = .None
	job := Cpu_Cosine_Job{queries = queries, docs = docs, n_docs = n_docs, dim = dim}
	job.out = make([]f32, n_queries * n_docs, allocator)
	total := n_queries * n_docs
	if !cpu_parallel_for(total, &job, cpu_parallel_cosine_pairs) {
		cpu_parallel_cosine_pairs(&job, 0, total)
	}
	return job.out, true
}

@(private)
cpu_parallel_cosine_query :: proc(
	query: []f32,
	docs: []f32,
	n_docs: int,
	dim: int,
	allocator: mem.Allocator,
) -> (
	scores: []f32,
	ok: bool,
) {
	return cpu_parallel_cosine_queries(query, docs, 1, n_docs, dim, allocator)
}

@(private)
cpu_parallel_cosine_queries_prepared :: proc(
	queries: []f32,
	n_queries: int,
	docs: rawptr,
	n_docs: int,
	dim: int,
	allocator: mem.Allocator,
) -> (
	scores: []f32,
	ok: bool,
) {
	return cpu_parallel_cosine_queries(queries, (^Cpu_Prepared)(docs).docs, n_queries, n_docs, dim, allocator)
}
