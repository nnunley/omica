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
import vm "../vm"
import v "../var"

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
	task:          ^Task,
	started:       bool,
	generation:    u64,
	running:       bool,
	cancelled:     bool,
	owned_program: bool,
	arguments:     []v.Value,
	result:        Task_Outcome,
	done:          bool,
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
		if entry.owned_program {
			vm.program_destroy(entry.task.program, scheduler.allocator)
		}
		if entry.arguments != nil {
			delete(entry.arguments)
		}
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
	return scheduler_submit_task(scheduler, task, 0, false)
}

@(private)
scheduler_submit_task :: proc(
	scheduler: ^Scheduler,
	task: ^Task,
	delay_millis: i64,
	owned_program: bool,
	arguments: []v.Value = nil,
) -> Task_ID {
	sync.mutex_lock(&scheduler.lock)
	id := Task_ID(scheduler.next_id)
	scheduler.next_id += 1
	task.id = id
	entry := new(Scheduler_Entry, scheduler.allocator)
	entry.task = task
	entry.result = Task_Outcome{kind = .Pending}
	entry.owned_program = owned_program
	entry.arguments = arguments
	scheduler.entries[id] = entry
	if delay_millis > 0 {
		entry.generation = 1
		scheduler_push_timer(scheduler, Timer_Entry {
			deadline   = time.tick_add(time.tick_now(), time.Duration(delay_millis) * time.Millisecond),
			task_id    = id,
			generation = entry.generation,
		})
	} else {
		append(&scheduler.ready, id)
	}
	sync.cond_broadcast(&scheduler.cond)
	sync.mutex_unlock(&scheduler.lock)
	return id
}

// Requests cancellation. A parked task aborts immediately; a running task
// aborts at its next boundary. Returns the outcome if the task was terminal.
scheduler_cancel :: proc(scheduler: ^Scheduler, id: Task_ID) -> Task_Outcome {
	sync.mutex_lock(&scheduler.lock)
	entry, found := scheduler.entries[id]
	if !found || entry.done {
		sync.mutex_unlock(&scheduler.lock)
		if found {
			return entry.result
		}
		return Task_Outcome{kind = .Aborted, message = "unknown task"}
	}
	entry.cancelled = true
	entry.task.cancel_requested = true
	if !entry.running {
		entry.result = task_cancel(entry.task)
		entry.done = true
		sync.cond_broadcast(&scheduler.cond)
	}
	result := entry.result
	sync.mutex_unlock(&scheduler.lock)
	return result
}

// Resumes a parked task with a value from the host. Returns false when the
// task is unknown, terminal, or currently running.
scheduler_resume :: proc(scheduler: ^Scheduler, id: Task_ID, value: v.Value) -> bool {
	sync.mutex_lock(&scheduler.lock)
	entry, found := scheduler.entries[id]
	if !found || entry.done || entry.running {
		sync.mutex_unlock(&scheduler.lock)
		return false
	}
	entry.running = true
	sync.mutex_unlock(&scheduler.lock)

	outcome := task_resume_with(entry.task, value)
	outcome = scheduler_run_spawns(scheduler, entry.task, outcome)

	sync.mutex_lock(&scheduler.lock)
	entry.running = false
	if entry.cancelled && outcome.kind == .Pending {
		outcome = task_cancel(entry.task)
	}
	scheduler_finish_locked(scheduler, id, entry, outcome)
	sync.cond_broadcast(&scheduler.cond)
	sync.mutex_unlock(&scheduler.lock)
	return true
}

// Applies a task outcome and parks, requeues, or finishes the entry. The
// caller must hold the scheduler lock.
@(private)
scheduler_finish_locked :: proc(
	scheduler: ^Scheduler,
	id: Task_ID,
	entry: ^Scheduler_Entry,
	outcome: Task_Outcome,
) {
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
}

// Spawns resume the parent immediately with the child id; the child runs on
// another worker.
@(private)
scheduler_run_spawns :: proc(
	scheduler: ^Scheduler,
	task: ^Task,
	outcome: Task_Outcome,
) -> Task_Outcome {
	result := outcome
	for result.kind == .Pending && result.suspend == .Spawn {
		child_id := scheduler_spawn_child(scheduler, task)
		child_value, _ := v.value_int(i64(child_id))
		result = task_resume_with(task, child_value)
	}
	return result
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

// Builds a child task from a parent's `.Spawn` suspension. The selector and
// role values are resolved through the kernel's dispatch relations to the
// method's function, which the child starts at in the shared world program.
// The parent is resumed with the child's task id.
@(private)
scheduler_spawn_child :: proc(scheduler: ^Scheduler, parent: ^Task) -> Task_ID {
	spec := parent.program.dispatch_specs[parent.state.request_spec]
	base := vm.vm_frame_base(&parent.state)

	roles := make([]k.Role_Pair, len(spec.roles), context.temp_allocator)
	for role, index in spec.roles {
		roles[index] = k.Role_Pair {
			role  = v.value_symbol(role.role),
			value = parent.state.registers[base + int(role.register)],
		}
	}

	snapshot := k.kernel_snapshot(scheduler.kernel)
	defer k.snapshot_release(snapshot)
	source := k.Relation_Source {
		snapshot           = snapshot,
		use_stored_derived = true,
	}
	relations := k.Dispatch_Relations {
		method_selector = k.DISPATCH_METHOD_SELECTOR_ID,
		param           = k.DISPATCH_PARAM_ID,
		delegates       = k.DISPATCH_DELEGATES_ID,
	}
	selector := v.value_symbol(spec.selector)
	entries := k.applicable_method_entries(
		&source,
		relations,
		selector,
		roles,
		context.temp_allocator,
	)
	if len(entries) == 0 {
		return 0
	}
	method := entries[0]
	program_value, found := k.dispatch_method_program(
		&source,
		k.DISPATCH_METHOD_PROGRAM_ID,
		method.method,
	)
	if !found {
		return 0
	}
	function_index, is_int := v.value_as_int(program_value)
	if !is_int {
		return 0
	}
	arguments, args_ok := k.dispatch_method_args(
		method.params,
		roles,
		scheduler.allocator,
	)
	if !args_ok {
		return 0
	}

	task := new(Task, scheduler.allocator)
	task_init(task, 0, scheduler.kernel, parent.program, parent.env, scheduler.allocator)
	vm.vm_set_entry_function(&task.state, i32(function_index))
	vm.vm_set_entry_arguments(&task.state, arguments)
	return scheduler_submit_task(
		scheduler,
		task,
		parent.state.request_millis,
		false,
		arguments,
	)
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
		entry.running = true
		sync.mutex_unlock(&scheduler.lock)

		outcome: Task_Outcome
		if entry.started {
			outcome = task_resume(entry.task)
		} else {
			outcome = task_run(entry.task)
			entry.started = true
		}

		// Spawns resume the parent immediately with the child id; the child
		// runs on another worker.
		outcome = scheduler_run_spawns(scheduler, entry.task, outcome)

		sync.mutex_lock(&scheduler.lock)
		entry.running = false
		if entry.cancelled && outcome.kind == .Pending {
			outcome = task_cancel(entry.task)
		}
		scheduler_finish_locked(scheduler, id, entry, outcome)
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
