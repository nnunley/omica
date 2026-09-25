// Multi-core CPU strategy: the CPU reference operators with large calls split
// by rows across worker threads. Partitioning changes no arithmetic, so the
// results equal `cpu_strategy`'s exactly.
//
// Opt-in, like the GPU strategies: the scheduler already runs one task per
// worker thread, so fanning out inside an operator can oversubscribe cores.
// Admission bounds that: one parallel call runs at a time process-wide, and a
// call arriving while it runs executes serially on its own thread instead of
// waiting (the same non-blocking decline as a busy GPU).
package accel

import "core:log"
import "core:mem"
import "core:os"
import "core:sync"
import "core:thread"

// Below these sizes a call runs serially: thread start-up (tens of
// microseconds per worker) would exceed the saving.
CPU_PARALLEL_MIN_PROBES :: 65536
// Query/document pairs for cosine.
CPU_PARALLEL_MIN_PAIRS :: 16384

@(private)
cpu_parallel_workers: int

@(private)
cpu_parallel_busy: bool

@(private)
cpu_parallel_spawn_failures: int

// Worker threads that failed to start since process start; their chunks ran
// on the calling thread instead.
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

// One contiguous slice of an operator's rows, run on one thread.
@(private)
Cpu_Chunk :: struct {
	job:   rawptr,
	first: int,
	last:  int,
	run:   proc(job: rawptr, first, last: int),
}

// Runs run(job, first, last) over [0, total) split into worker-sized chunks,
// the calling thread taking the first. Returns false, having run nothing,
// when another parallel call holds the workers.
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
	chunk := (total + workers - 1) / workers
	threads := make([]^thread.Thread, workers - 1, context.temp_allocator)
	started := 0
	for w in 1 ..< workers {
		first := w * chunk
		if first >= total {
			break
		}
		last := min(first + chunk, total)
		th := thread.create_and_start_with_poly_data(
			Cpu_Chunk{job = job, first = first, last = last, run = run},
			proc(c: Cpu_Chunk) {c.run(c.job, c.first, c.last)},
		)
		if th == nil {
			// Thread creation can fail; the caller runs the chunk itself so the
			// result stays complete. Observed intermittently on Linux under the
			// test runner (errno 0, so not an allocation failure; core:thread
			// discards pthread_create's error code).
			if sync.atomic_add(&cpu_parallel_spawn_failures, 1) == 0 {
				log.warn("accel: worker thread creation failed; running its chunk on the caller (logged once)")
			}
			run(job, first, last)
			continue
		}
		threads[started] = th
		started += 1
	}
	run(job, 0, min(chunk, total))
	for th in threads[:started] {
		thread.join(th)
		thread.destroy(th)
	}
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
		return nil, false
	}
	job := Cpu_Membership_Job{left = left, right = right_sorted_unique, keep = keep_matches}
	job.out = make([]bool, len(left), allocator)
	if !cpu_parallel_for(len(left), &job, cpu_parallel_membership_rows) {
		cpu_parallel_membership_rows(&job, 0, len(left))
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
		return nil, false
	}
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
