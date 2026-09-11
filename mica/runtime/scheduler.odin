// A multithreaded task scheduler.
//
// One task runs per worker thread at a time. A task runs to its next host
// boundary on that worker, commits, and either completes or parks with a wake
// condition: ready (yield), a timer (sleep), or a host resume. Suspended tasks
// release their worker; the worker picks up the next runnable task.
//
// A single timer service thread wakes sleeping tasks. Timer entries carry a
// generation so a task that is resumed by other means ignores its stale timer.
package mica_runtime

import "core:mem"
import "core:sync"
import "core:thread"
import "core:time"
import k "../kernel"

Scheduler_Config :: struct {
	workers: int,
}

DEFAULT_SCHEDULER_WORKERS :: 8

@(private)
Timer_Entry :: struct {
	deadline:   time.Tick,
	task_id:    Task_ID,
	generation: u64,
}

@(private)
Scheduler_Entry :: struct {
	task:       ^Task,
	started:    bool,
	generation: u64,
	result:     Task_Outcome,
	done:       bool,
}

Scheduler :: struct {
	kernel:    ^k.Kernel,
	allocator: mem.Allocator,

	lock: sync.Mutex,
	cond: sync.Cond,
	stop: bool,

	ready:   [dynamic]Task_ID,
	timers:  [dynamic]Timer_Entry,
	entries: map[Task_ID]^Scheduler_Entry,

	threads: [dynamic]^thread.Thread,
	timer:   ^thread.Thread,

	next_id: u64,
	started: bool,
}

scheduler_init :: proc(
	scheduler: ^Scheduler,
	kernel: ^k.Kernel,
	config := Scheduler_Config{workers = DEFAULT_SCHEDULER_WORKERS},
	allocator := context.allocator,
) {
	scheduler.kernel = kernel
	scheduler.allocator = allocator
	scheduler.ready = make([dynamic]Task_ID, allocator)
	scheduler.timers = make([dynamic]Timer_Entry, allocator)
	scheduler.entries = make(map[Task_ID]^Scheduler_Entry, allocator)
	scheduler.threads = make([dynamic]^thread.Thread, allocator)
	scheduler.next_id = 1

	scheduler.started = true
	worker_count := max(config.workers, 1)
	for _ in 0 ..< worker_count {
		worker := thread.create_and_start_with_data(scheduler, scheduler_worker_proc)
		append(&scheduler.threads, worker)
	}
	scheduler.timer = thread.create_and_start_with_data(scheduler, scheduler_timer_proc)
}

scheduler_destroy :: proc(scheduler: ^Scheduler) {
	scheduler_shutdown(scheduler)

	for _, entry in scheduler.entries {
		task_destroy(entry.task)
		free(entry.task, scheduler.allocator)
		free(entry, scheduler.allocator)
	}
	delete(scheduler.entries)
	delete(scheduler.ready)
	delete(scheduler.timers)
	delete(scheduler.threads)
}

// Stops the worker and timer threads and waits for them.
scheduler_shutdown :: proc(scheduler: ^Scheduler) {
	if !scheduler.started {
		return
	}
	sync.mutex_lock(&scheduler.lock)
	scheduler.stop = true
	sync.cond_broadcast(&scheduler.cond)
	sync.mutex_unlock(&scheduler.lock)

	for worker in scheduler.threads {
		thread.join(worker)
		thread.destroy(worker)
	}
	thread.join(scheduler.timer)
	thread.destroy(scheduler.timer)
	clear(&scheduler.threads)
	scheduler.started = false
}

// Takes ownership of `task` and makes it runnable. The task must already be
// initialized; its id is assigned here.
scheduler_submit :: proc(scheduler: ^Scheduler, task: ^Task) -> Task_ID {
	sync.mutex_lock(&scheduler.lock)
	id := Task_ID(scheduler.next_id)
	scheduler.next_id += 1
	task.id = id
	entry := new(Scheduler_Entry, scheduler.allocator)
	entry.task = task
	entry.result = Task_Outcome{kind = .Pending}
	scheduler.entries[id] = entry
	append(&scheduler.ready, id)
	sync.cond_broadcast(&scheduler.cond)
	sync.mutex_unlock(&scheduler.lock)
	return id
}

// Blocks until the task reaches a terminal outcome.
scheduler_wait :: proc(scheduler: ^Scheduler, id: Task_ID) -> Task_Outcome {
	sync.mutex_lock(&scheduler.lock)
	defer sync.mutex_unlock(&scheduler.lock)
	for {
		entry, found := scheduler.entries[id]
		if !found {
			return Task_Outcome{kind = .Aborted, message = "unknown task"}
		}
		if entry.done {
			return entry.result
		}
		sync.cond_wait(&scheduler.cond, &scheduler.lock)
	}
}

// Returns true when every submitted task has reached a terminal outcome.
scheduler_idle :: proc(scheduler: ^Scheduler) -> bool {
	sync.mutex_lock(&scheduler.lock)
	defer sync.mutex_unlock(&scheduler.lock)
	for _, entry in scheduler.entries {
		if !entry.done {
			return false
		}
	}
	return true
}

@(private)
scheduler_push_timer :: proc(scheduler: ^Scheduler, entry: Timer_Entry) {
	insert := len(scheduler.timers)
	for index in 0 ..< len(scheduler.timers) {
		if time.tick_diff(entry.deadline, scheduler.timers[index].deadline) > 0 {
			insert = index
			break
		}
	}
	append(&scheduler.timers, Timer_Entry{})
	copy(scheduler.timers[insert + 1:], scheduler.timers[insert:])
	scheduler.timers[insert] = entry
}

@(private)
scheduler_worker_proc :: proc(data: rawptr) {
	scheduler := (^Scheduler)(data)
	for {
		sync.mutex_lock(&scheduler.lock)
		for len(scheduler.ready) == 0 && !scheduler.stop {
			sync.cond_wait(&scheduler.cond, &scheduler.lock)
		}
		if scheduler.stop {
			sync.mutex_unlock(&scheduler.lock)
			return
		}
		id := pop(&scheduler.ready)
		entry := scheduler.entries[id]
		sync.mutex_unlock(&scheduler.lock)

		outcome: Task_Outcome
		if entry.started {
			outcome = task_resume(entry.task)
		} else {
			outcome = task_run(entry.task)
			entry.started = true
		}

		sync.mutex_lock(&scheduler.lock)
		entry.result = outcome
		#partial switch outcome.kind {
		case .Pending:
			switch outcome.suspend {
			case .Yield:
				append(&scheduler.ready, id)
			case .Sleep:
				entry.generation += 1
				scheduler_push_timer(scheduler, Timer_Entry {
					deadline   = time.tick_add(time.tick_now(), time.Duration(outcome.millis) * time.Millisecond),
					task_id    = id,
					generation = entry.generation,
				})
			case .Host_Request, .Spawn, .Commit, .None:
				// Parked until a host resumes the task.
			}
		case .Complete, .Aborted:
			entry.done = true
		}
		sync.cond_broadcast(&scheduler.cond)
		sync.mutex_unlock(&scheduler.lock)
	}
}

@(private)
scheduler_timer_proc :: proc(data: rawptr) {
	scheduler := (^Scheduler)(data)
	for {
		sync.mutex_lock(&scheduler.lock)
		if scheduler.stop {
			sync.mutex_unlock(&scheduler.lock)
			return
		}

		now := time.tick_now()
		if len(scheduler.timers) == 0 {
			sync.cond_wait(&scheduler.cond, &scheduler.lock)
			sync.mutex_unlock(&scheduler.lock)
			continue
		}

		next := scheduler.timers[0]
		if time.tick_diff(now, next.deadline) > 0 {
			sync.cond_wait_with_timeout(
				&scheduler.cond,
				&scheduler.lock,
				time.tick_diff(now, next.deadline),
			)
			sync.mutex_unlock(&scheduler.lock)
			continue
		}

		pop(&scheduler.timers)
		entry, found := scheduler.entries[next.task_id]
		if found && !entry.done && entry.generation == next.generation {
			append(&scheduler.ready, next.task_id)
		}
		sync.cond_broadcast(&scheduler.cond)
		sync.mutex_unlock(&scheduler.lock)
	}
}
