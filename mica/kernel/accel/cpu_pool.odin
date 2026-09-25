// Process-wide worker pool for the multi-core CPU strategy. Threads are
// created once and reused, so a parallel call costs a wake-up, not thread
// creation (which also fails intermittently on Linux under the test runner;
// see cpu_parallel_spawn_failures). One job runs at a time: the caller holds
// cpu_parallel_busy for the job's duration.
package accel

import "base:runtime"
import "core:log"
import "core:os"
import "core:sync"
import "core:thread"

@(private)
Cpu_Pool :: struct {
	once:       sync.Once,
	mutex:      sync.Mutex,
	wake:       sync.Cond,
	finished:   sync.Cond,
	threads:    [dynamic]^thread.Thread,
	generation: u64,
	job:        rawptr,
	run:        proc(job: rawptr, first, last: int),
	total:      int,
	chunk:      int,
	remaining:  int,
	started:    bool,
}

@(private)
cpu_pool: Cpu_Pool

@(private)
Cpu_Pool_Worker :: struct {
	index: int, // chunk index this worker runs (1-based; the caller runs 0)
}

// Starts the pool: one thread per core, minus the calling thread. Idempotent.
cpu_pool_start :: proc() {
	sync.once_do(&cpu_pool.once, proc() {
		// Heap allocations: the pool lives for the process, outside any
		// caller's (possibly tracking) allocator.
		context.allocator = runtime.heap_allocator()
		want := max(os.get_processor_core_count() - 1, 0)
		cpu_pool.threads = make([dynamic]^thread.Thread, 0, want)
		for _ in 0 ..< want {
			th := thread.create_and_start_with_poly_data(
				Cpu_Pool_Worker{index = len(cpu_pool.threads) + 1},
				cpu_pool_worker,
			)
			if th == nil {
				if sync.atomic_add(&cpu_parallel_spawn_failures, 1) == 0 {
					log.warn("accel: CPU pool thread creation failed; the pool runs with fewer workers (logged once)")
				}
				continue
			}
			append(&cpu_pool.threads, th)
		}
		sync.atomic_store(&cpu_pool.started, true)
	})
}

// Whether the pool has been started (without starting it).
cpu_pool_started :: proc() -> bool {
	return sync.atomic_load(&cpu_pool.started)
}

// Worker threads in the pool (the calling thread is extra).
cpu_pool_threads :: proc() -> int {
	cpu_pool_start()
	return len(cpu_pool.threads)
}

@(private)
cpu_pool_worker :: proc(w: Cpu_Pool_Worker) {
	seen: u64
	for {
		sync.mutex_lock(&cpu_pool.mutex)
		for cpu_pool.generation == seen {
			sync.cond_wait(&cpu_pool.wake, &cpu_pool.mutex)
		}
		seen = cpu_pool.generation
		job, run, total, chunk := cpu_pool.job, cpu_pool.run, cpu_pool.total, cpu_pool.chunk
		sync.mutex_unlock(&cpu_pool.mutex)

		first := w.index * chunk
		if first < total {
			run(job, first, min(first + chunk, total))
		}

		sync.mutex_lock(&cpu_pool.mutex)
		cpu_pool.remaining -= 1
		if cpu_pool.remaining == 0 {
			sync.cond_signal(&cpu_pool.finished)
		}
		sync.mutex_unlock(&cpu_pool.mutex)
	}
}

// Runs run(job, first, last) over [0, total) on `workers` threads including
// the caller (chunk 0). The caller must hold cpu_parallel_busy.
@(private)
cpu_pool_run :: proc(workers: int, total: int, job: rawptr, run: proc(job: rawptr, first, last: int)) {
	helpers := min(workers - 1, len(cpu_pool.threads))
	if helpers <= 0 {
		run(job, 0, total)
		return
	}
	chunk := (total + helpers) / (helpers + 1)
	sync.mutex_lock(&cpu_pool.mutex)
	cpu_pool.job, cpu_pool.run, cpu_pool.total = job, run, total
	cpu_pool.chunk = chunk
	// Every pool thread wakes each generation; threads past `helpers` find an
	// empty chunk (first >= total) and just report in.
	cpu_pool.remaining = len(cpu_pool.threads)
	cpu_pool.generation += 1
	sync.cond_broadcast(&cpu_pool.wake)
	sync.mutex_unlock(&cpu_pool.mutex)

	run(job, 0, min(chunk, total))

	sync.mutex_lock(&cpu_pool.mutex)
	for cpu_pool.remaining > 0 {
		sync.cond_wait(&cpu_pool.finished, &cpu_pool.mutex)
	}
	sync.mutex_unlock(&cpu_pool.mutex)
}
