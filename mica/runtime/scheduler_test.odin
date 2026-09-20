package mica_runtime

import "core:fmt"
import "core:sync"
import "core:testing"
import "core:time"
import k "../kernel"
import vm "../vm"
import v "../var"

@(private)
scheduler_task :: proc(program: ^vm.Program, kernel: ^k.Kernel) -> ^Task {
	task := new(Task)
	task_init(task, 0, kernel, program, nil)
	return task
}

@(private)
build_flag_program :: proc(
	relation: k.Relation_ID,
	cell: i64,
	allocator := context.temp_allocator,
) -> ^vm.Program {
	builder: vm.Builder
	vm.builder_init(&builder)
	defer vm.builder_destroy(&builder)
	flag_program(&builder, relation, cell)
	return vm.builder_build(&builder, allocator)
}

@(private)
flag_program :: proc(
	builder: ^vm.Builder,
	relation: k.Relation_ID,
	cell: i64,
) {
	row, row_err := v.value_relation(
		context.temp_allocator,
		[]v.Symbol{v.symbol_intern("value")},
		[]v.Tuple {
			v.tuple_new(context.temp_allocator, []v.Value{value_int_must(cell)}),
		},
	)
	assert(row_err == .None)
	flag := vm.builder_add_constant(builder, row)

	vm.builder_begin_function(builder, v.symbol_intern("main"), 0, 2, true)
	vm.builder_emit(builder, .Load_Const, 0, 0, i32(flag), 0)
	vm.builder_emit(builder, .Assert, 0, i32(relation), 0, 0)
	vm.builder_emit(builder, .Return, 0, 0, 0, 0)
	vm.builder_end_function(builder)
}

@(test)
test_scheduler_runs_task_to_completion :: proc(t: ^testing.T) {
	kernel: k.Kernel
	k.kernel_init(&kernel)
	defer k.kernel_destroy(&kernel)

	metadata := k.relation_metadata(k.Relation_ID(1), v.symbol_intern("Flag"), 1)
	snapshot, err := k.kernel_create_relation(&kernel, metadata)
	testing.expect_value(t, err, k.Kernel_Error.None)
	k.snapshot_release(snapshot)

	program := build_flag_program(k.Relation_ID(1), 1)

	scheduler: Scheduler
	scheduler_init(&scheduler, &kernel, Scheduler_Config{workers = 2})
	defer scheduler_destroy(&scheduler)

	id := scheduler_submit(&scheduler, scheduler_task(program, &kernel))
	outcome := scheduler_wait(&scheduler, id)
	testing.expect_value(t, outcome.kind, Task_Outcome_Kind.Complete)

	rows: [dynamic]v.Tuple
	defer delete(rows)
	k.kernel_scan_into(&kernel, k.Relation_ID(1), []v.Binding{{}}, &rows)
	testing.expect_value(t, len(rows), 1)
}

@(test)
test_scheduler_yields_requeue :: proc(t: ^testing.T) {
	kernel: k.Kernel
	k.kernel_init(&kernel)
	defer k.kernel_destroy(&kernel)

	program := compile_task_program(t, proc(builder: ^vm.Builder) {
		one := vm.builder_add_constant(builder, value_int_must(1))
		vm.builder_begin_function(builder, v.symbol_intern("main"), 0, 2, true)
		vm.builder_emit(builder, .Yield, 0, 0, 0, 0)
		vm.builder_emit(builder, .Yield, 0, 0, 0, 0)
		vm.builder_emit(builder, .Load_Const, 0, 0, i32(one), 0)
		vm.builder_emit(builder, .Return, 0, 0, 0, 0)
		vm.builder_end_function(builder)
	})

	scheduler: Scheduler
	scheduler_init(&scheduler, &kernel, Scheduler_Config{workers = 2})
	defer scheduler_destroy(&scheduler)

	id := scheduler_submit(&scheduler, scheduler_task(program, &kernel))
	outcome := scheduler_wait(&scheduler, id)
	testing.expect_value(t, outcome.kind, Task_Outcome_Kind.Complete)
	value, value_ok := v.value_as_int(outcome.value)
	testing.expect(t, value_ok)
	testing.expect_value(t, value, i64(1))
}

@(test)
test_scheduler_sleep_wakes :: proc(t: ^testing.T) {
	kernel: k.Kernel
	k.kernel_init(&kernel)
	defer k.kernel_destroy(&kernel)

	program := compile_task_program(t, proc(builder: ^vm.Builder) {
		delay := vm.builder_add_constant(builder, value_int_must(15))
		vm.builder_begin_function(builder, v.symbol_intern("main"), 0, 2, true)
		vm.builder_emit(builder, .Load_Const, 0, 0, i32(delay), 0)
		vm.builder_emit(builder, .Sleep, 0, 0, 0, 0)
		vm.builder_emit(builder, .Return, 0, 0, 0, 0)
		vm.builder_end_function(builder)
	})

	scheduler: Scheduler
	scheduler_init(&scheduler, &kernel, Scheduler_Config{workers = 1})
	defer scheduler_destroy(&scheduler)

	start := time.tick_now()
	id := scheduler_submit(&scheduler, scheduler_task(program, &kernel))
	outcome := scheduler_wait(&scheduler, id)
	elapsed := time.tick_since(start)

	testing.expect_value(t, outcome.kind, Task_Outcome_Kind.Complete)
	testing.expect(t, elapsed >= 10 * time.Millisecond)
}

@(test)
test_scheduler_parallel_tasks :: proc(t: ^testing.T) {
	kernel: k.Kernel
	k.kernel_init(&kernel)
	defer k.kernel_destroy(&kernel)

	TASKS :: 4
	for index in 0 ..< TASKS {
		metadata := k.relation_metadata(
			k.Relation_ID(index + 1),
			v.symbol_intern(fmt.aprintf(
				"Parallel%d",
				index,
				allocator = context.temp_allocator,
			)),
			1,
		)
		snapshot, err := k.kernel_create_relation(&kernel, metadata)
		testing.expect_value(t, err, k.Kernel_Error.None)
		k.snapshot_release(snapshot)
	}

	scheduler: Scheduler
	scheduler_init(&scheduler, &kernel, Scheduler_Config{workers = TASKS})
	defer scheduler_destroy(&scheduler)

	ids: [TASKS]Task_ID
	programs: [TASKS]^vm.Program
	for index in 0 ..< TASKS {
		relation := k.Relation_ID(index + 1)
		programs[index] = build_flag_program(relation, i64(index) + 1)
		ids[index] = scheduler_submit(
			&scheduler,
			scheduler_task(programs[index], &kernel),
		)
	}

	for index in 0 ..< TASKS {
		outcome := scheduler_wait(&scheduler, ids[index])
		testing.expect_value(t, outcome.kind, Task_Outcome_Kind.Complete)
	}

	for index in 0 ..< TASKS {
		rows: [dynamic]v.Tuple
		k.kernel_scan_into(
			&kernel,
			k.Relation_ID(index + 1),
			[]v.Binding{{}},
			&rows,
		)
		testing.expect_value(t, len(rows), 1)
		delete(rows)
	}
}

@(private)
scheduler_wait_suspended :: proc(
	scheduler: ^Scheduler,
	id: Task_ID,
	suspend: Task_Suspend,
) -> bool {
	for _ in 0 ..< 2000 {
		sync.mutex_lock(&scheduler.lock)
		entry, found := scheduler.entries[id]
		parked := found &&
			entry.result.kind == .Pending &&
			entry.result.suspend == suspend
		sync.mutex_unlock(&scheduler.lock)
		if parked {
			return true
		}
		time.sleep(time.Millisecond)
	}
	return false
}

@(test)
test_scheduler_resume_with_value :: proc(t: ^testing.T) {
	kernel: k.Kernel
	k.kernel_init(&kernel)
	defer k.kernel_destroy(&kernel)

	program := compile_task_program(t, proc(builder: ^vm.Builder) {
		delay := vm.builder_add_constant(builder, value_int_must(60_000))
		vm.builder_begin_function(builder, v.symbol_intern("main"), 0, 2, true)
		vm.builder_emit(builder, .Load_Const, 0, 0, i32(delay), 0)
		vm.builder_emit(builder, .Sleep, 0, 0, 0, 0)
		vm.builder_emit(builder, .Return, 0, 0, 0, 0)
		vm.builder_end_function(builder)
	})

	scheduler: Scheduler
	scheduler_init(&scheduler, &kernel, Scheduler_Config{workers = 1})
	defer scheduler_destroy(&scheduler)

	id := scheduler_submit(&scheduler, scheduler_task(program, &kernel))
	testing.expect(t, scheduler_wait_suspended(&scheduler, id, .Sleep))

	testing.expect(t, scheduler_resume(&scheduler, id, value_int_must(42)))

	outcome := scheduler_wait(&scheduler, id)
	testing.expect_value(t, outcome.kind, Task_Outcome_Kind.Complete)
	value, value_ok := v.value_as_int(outcome.value)
	testing.expect(t, value_ok)
	testing.expect_value(t, value, i64(42))
}

// An early host resume must invalidate the sleep timer: the stale timer firing
// later must not requeue or touch the entry. Regression for the lost-wakeup
// and stale-timer races.
@(test)
test_scheduler_resume_invalidates_timer :: proc(t: ^testing.T) {
	kernel: k.Kernel
	k.kernel_init(&kernel)
	defer k.kernel_destroy(&kernel)

	program := compile_task_program(t, proc(builder: ^vm.Builder) {
		delay := vm.builder_add_constant(builder, value_int_must(60_000))
		vm.builder_begin_function(builder, v.symbol_intern("main"), 0, 2, true)
		vm.builder_emit(builder, .Load_Const, 0, 0, i32(delay), 0)
		vm.builder_emit(builder, .Sleep, 0, 0, 0, 0)
		vm.builder_emit(builder, .Return, 0, 0, 0, 0)
		vm.builder_end_function(builder)
	})

	scheduler: Scheduler
	scheduler_init(&scheduler, &kernel, Scheduler_Config{workers = 1})
	defer scheduler_destroy(&scheduler)

	id := scheduler_submit(&scheduler, scheduler_task(program, &kernel))
	testing.expect(t, scheduler_wait_suspended(&scheduler, id, .Sleep))

	// The sleep armed exactly one timer carrying the entry's generation.
	sync.mutex_lock(&scheduler.lock)
	entry := scheduler.entries[id]
	armed := entry.generation
	armed_count := 0
	for timer in scheduler.timers {
		if timer.task_id == id && timer.generation == armed {
			armed_count += 1
		}
	}
	sync.mutex_unlock(&scheduler.lock)
	testing.expect_value(t, armed_count, 1)

	testing.expect(t, scheduler_resume(&scheduler, id, value_int_must(42)))

	// The resume bumped the generation, so the armed timer is now stale. The
	// fire helper requires the scheduler lock (the worker also touches the
	// entry under it).
	sync.mutex_lock(&scheduler.lock)
	stale := scheduler.entries[id].generation != armed
	testing.expect(t, stale)
	fired := scheduler_timer_fire_locked(
		&scheduler,
		Timer_Entry{task_id = id, generation = armed},
	)
	sync.mutex_unlock(&scheduler.lock)
	testing.expect(t, !fired)

	outcome := scheduler_wait(&scheduler, id)
	testing.expect_value(t, outcome.kind, Task_Outcome_Kind.Complete)
	value, value_ok := v.value_as_int(outcome.value)
	testing.expect(t, value_ok)
	testing.expect_value(t, value, i64(42))
}

// The timer must only wake an entry still parked on the wait that armed it:
// terminal, running, already-woken, or re-parked entries are left alone.
@(test)
test_scheduler_timer_fire_guards :: proc(t: ^testing.T) {
	kernel: k.Kernel
	k.kernel_init(&kernel)
	defer k.kernel_destroy(&kernel)

	program := compile_task_program(t, proc(builder: ^vm.Builder) {
		delay := vm.builder_add_constant(builder, value_int_must(60_000))
		vm.builder_begin_function(builder, v.symbol_intern("main"), 0, 2, true)
		vm.builder_emit(builder, .Load_Const, 0, 0, i32(delay), 0)
		vm.builder_emit(builder, .Sleep, 0, 0, 0, 0)
		vm.builder_emit(builder, .Return, 0, 0, 0, 0)
		vm.builder_end_function(builder)
	})

	scheduler: Scheduler
	scheduler_init(&scheduler, &kernel, Scheduler_Config{workers = 1})
	defer scheduler_destroy(&scheduler)

	id := scheduler_submit(&scheduler, scheduler_task(program, &kernel))
	testing.expect(t, scheduler_wait_suspended(&scheduler, id, .Sleep))

	sync.mutex_lock(&scheduler.lock)
	entry := scheduler.entries[id]
	generation := entry.generation
	ready_before := len(scheduler.ready)

	// The live timer for the current park fires.
	testing.expect(
		t,
		scheduler_timer_fire_locked(
			&scheduler,
			Timer_Entry{task_id = id, generation = generation},
		),
	)
	testing.expect_value(t, len(scheduler.ready), ready_before + 1)

	// A stale generation, a running entry, and an already-woken entry do not.
	entry.running = true
	testing.expect(
		t,
		!scheduler_timer_fire_locked(
			&scheduler,
			Timer_Entry{task_id = id, generation = generation},
		),
	)
	entry.running = false
	entry.has_pending = true
	testing.expect(
		t,
		!scheduler_timer_fire_locked(
			&scheduler,
			Timer_Entry{task_id = id, generation = generation},
		),
	)
	entry.has_pending = false
	testing.expect(
		t,
		!scheduler_timer_fire_locked(
			&scheduler,
			Timer_Entry{task_id = id, generation = generation + 1},
		),
	)
	// The live firing above queued the entry; wake a worker for it exactly as
	// the timer loop does after firing.
	sync.cond_broadcast(&scheduler.cond)
	sync.mutex_unlock(&scheduler.lock)

	// The single live firing above woke the sleeper; it runs to completion.
	outcome := scheduler_wait(&scheduler, id)
	testing.expect_value(t, outcome.kind, Task_Outcome_Kind.Complete)
}

// A host resume drops the entry's mailbox waiters, so a later send cannot
// wake the entry through a stale waiter once it has moved on.
@(test)
test_scheduler_resume_removes_mailbox_waiters :: proc(t: ^testing.T) {
	kernel: k.Kernel
	k.kernel_init(&kernel)
	defer k.kernel_destroy(&kernel)

	program := compile_task_program(t, proc(builder: ^vm.Builder) {
		delay := vm.builder_add_constant(builder, value_int_must(60_000))
		vm.builder_begin_function(builder, v.symbol_intern("main"), 0, 2, true)
		vm.builder_emit(builder, .Load_Const, 0, 0, i32(delay), 0)
		vm.builder_emit(builder, .Sleep, 0, 0, 0, 0)
		vm.builder_emit(builder, .Return, 0, 0, 0, 0)
		vm.builder_end_function(builder)
	})

	scheduler: Scheduler
	scheduler_init(&scheduler, &kernel, Scheduler_Config{workers = 1})
	defer scheduler_destroy(&scheduler)

	receiver, _, minted := scheduler_mailbox_create(&scheduler)
	testing.expect(t, minted)

	id := scheduler_submit(&scheduler, scheduler_task(program, &kernel))
	testing.expect(t, scheduler_wait_suspended(&scheduler, id, .Sleep))

	// Register a waiter for the parked entry, as a mailbox park would.
	sync.mutex_lock(&scheduler.lock)
	entry := scheduler.entries[id]
	entry.task.state.request_value = v.value_list(
		context.temp_allocator,
		[]v.Value{receiver},
	)
	scheduler_park_mailbox_locked(&scheduler, id, entry, 0)
	waiters := 0
	for _, box in scheduler.mailboxes {
		for waiter in box.waiters {
			if waiter.task_id == id {
				waiters += 1
			}
		}
	}
	sync.mutex_unlock(&scheduler.lock)
	testing.expect_value(t, waiters, 1)

	testing.expect(t, scheduler_resume(&scheduler, id, value_int_must(7)))

	sync.mutex_lock(&scheduler.lock)
	waiters = 0
	for _, box in scheduler.mailboxes {
		for waiter in box.waiters {
			if waiter.task_id == id {
				waiters += 1
			}
		}
	}
	sync.mutex_unlock(&scheduler.lock)
	testing.expect_value(t, waiters, 0)

	outcome := scheduler_wait(&scheduler, id)
	testing.expect_value(t, outcome.kind, Task_Outcome_Kind.Complete)
	value, value_ok := v.value_as_int(outcome.value)
	testing.expect(t, value_ok)
	testing.expect_value(t, value, i64(7))
}

// A dead waiter at the head of the queue must not strand messages for the
// live waiters behind it. Regression: the wake dropped the delivery when the
// first waiter was gone, terminal, or already woken.
@(test)
test_scheduler_wake_skips_dead_waiters :: proc(t: ^testing.T) {
	kernel: k.Kernel
	k.kernel_init(&kernel)
	defer k.kernel_destroy(&kernel)

	scheduler: Scheduler
	scheduler_init(&scheduler, &kernel, Scheduler_Config{workers = 1})
	defer scheduler_destroy(&scheduler)

	// Stop the worker before injecting fake entries below; it must never pop
	// and try to run an entry with no task.
	sync.mutex_lock(&scheduler.lock)
	scheduler.stop = true
	sync.mutex_unlock(&scheduler.lock)

	receiver, _, minted := scheduler_mailbox_create(&scheduler)
	testing.expect(t, minted)

	// A terminal entry and a live entry; neither runs, so no task pointers
	// are needed and both are removed before destroy.
	done_entry := new(Scheduler_Entry, context.allocator)
	done_entry.done = true
	live_entry := new(Scheduler_Entry, context.allocator)
	sync.mutex_lock(&scheduler.lock)
	scheduler.entries[9001] = done_entry
	scheduler.entries[9002] = live_entry
	mailbox, mailbox_ok := mailbox_target(&scheduler, receiver, false)
	testing.expect(t, mailbox_ok)
	box := scheduler.mailboxes[mailbox]
	message, _ := v.value_int(1)
	append(&box.messages, message)
	append(&box.waiters, Mailbox_Waiter{task_id = 9001, receiver = receiver})
	append(&box.waiters, Mailbox_Waiter{task_id = 9002, receiver = receiver})
	ready_before := len(scheduler.ready)

	scheduler_wake_mailbox_locked(&scheduler, box)

	testing.expect(t, !done_entry.has_pending)
	testing.expect(t, live_entry.has_pending)
	testing.expect_value(t, len(scheduler.ready), ready_before + 1)
	testing.expect_value(t, scheduler.ready[len(scheduler.ready) - 1], Task_ID(9002))
	testing.expect_value(t, len(box.waiters), 0)
	testing.expect_value(t, len(box.messages), 0)

	delete_key(&scheduler.entries, Task_ID(9001))
	delete_key(&scheduler.entries, Task_ID(9002))
	sync.mutex_unlock(&scheduler.lock)
	free(done_entry, context.allocator)
	free(live_entry, context.allocator)
}

@(test)
test_scheduler_cancel_parked :: proc(t: ^testing.T) {
	kernel: k.Kernel
	k.kernel_init(&kernel)
	defer k.kernel_destroy(&kernel)

	program := compile_task_program(t, proc(builder: ^vm.Builder) {
		delay := vm.builder_add_constant(builder, value_int_must(60_000))
		vm.builder_begin_function(builder, v.symbol_intern("main"), 0, 2, true)
		vm.builder_emit(builder, .Load_Const, 0, 0, i32(delay), 0)
		vm.builder_emit(builder, .Sleep, 0, 0, 0, 0)
		vm.builder_emit(builder, .Return, 0, 0, 0, 0)
		vm.builder_end_function(builder)
	})

	scheduler: Scheduler
	scheduler_init(&scheduler, &kernel, Scheduler_Config{workers = 1})
	defer scheduler_destroy(&scheduler)

	id := scheduler_submit(&scheduler, scheduler_task(program, &kernel))
	testing.expect(t, scheduler_wait_suspended(&scheduler, id, .Sleep))

	outcome := scheduler_cancel(&scheduler, id)
	testing.expect_value(t, outcome.kind, Task_Outcome_Kind.Aborted)
	testing.expect(t, scheduler_idle(&scheduler))
}

@(test)
test_scheduler_spawn_child :: proc(t: ^testing.T) {
	kernel: k.Kernel
	k.kernel_init(&kernel)
	defer k.kernel_destroy(&kernel)

	metadata := k.dispatch_relation_metadata(context.temp_allocator)
	for entry in metadata {
		created, create_err := k.kernel_create_relation(&kernel, entry)
		testing.expect_value(t, create_err, k.Kernel_Error.None)
		k.snapshot_release(created)
	}

	method_value, identity_ok := v.value_identity_raw(0)
	testing.expect(t, identity_ok)
	install := k.kernel_begin(&kernel)
	defer k.transaction_destroy(&install)
	testing.expect_value(
		t,
		k.transaction_assert(
			&install,
			k.DISPATCH_METHOD_SELECTOR_ID,
			v.tuple_new(context.temp_allocator, []v.Value {
				method_value,
				v.value_symbol(v.symbol_intern("child")),
			}),
		),
		k.Kernel_Error.None,
	)
	testing.expect_value(
		t,
		k.transaction_assert(
			&install,
			k.DISPATCH_METHOD_PROGRAM_ID,
			v.tuple_new(context.temp_allocator, []v.Value {
				method_value,
				value_int_must(0),
			}),
		),
		k.Kernel_Error.None,
	)
	committed, commit_err := k.transaction_commit(&install)
	testing.expect_value(t, commit_err, k.Kernel_Error.None)
	k.snapshot_release(committed)

	metadata_flag := k.relation_metadata(
		k.Relation_ID(1),
		v.symbol_intern("Flag"),
		1,
	)
	flag_snapshot, flag_err := k.kernel_create_relation(&kernel, metadata_flag)
	testing.expect_value(t, flag_err, k.Kernel_Error.None)
	k.snapshot_release(flag_snapshot)

	// Function 0 is the spawned child body; function 1 is the parent.
	program := compile_task_program(t, proc(builder: ^vm.Builder) {
		cell := v.tuple_new(context.temp_allocator, []v.Value{value_int_must(7)})
		row, row_err := v.value_relation(
			context.temp_allocator,
			[]v.Symbol{v.symbol_intern("value")},
			[]v.Tuple{cell},
		)
		assert(row_err == .None)
		flag := vm.builder_add_constant(builder, row)

		vm.builder_begin_function(builder, v.symbol_intern("child"), 0, 2, false)
		vm.builder_emit(builder, .Load_Const, 0, 0, i32(flag), 0)
		vm.builder_emit(builder, .Assert, 0, 1, 0, 0)
		vm.builder_emit(builder, .Return, 0, 0, 0, 0)
		vm.builder_end_function(builder)

		spec := vm.builder_add_dispatch_spec(
			builder,
			v.symbol_intern("child"),
			nil,
		)
		vm.builder_begin_function(builder, v.symbol_intern("main"), 0, 2, true)
		vm.builder_emit(builder, .Spawn, 0, i32(spec), 0, 0)
		vm.builder_emit(builder, .Return, 0, 0, 0, 0)
		vm.builder_end_function(builder)
	})

	scheduler: Scheduler
	scheduler_init(&scheduler, &kernel, Scheduler_Config{workers = 2})
	defer scheduler_destroy(&scheduler)

	parent_id := scheduler_submit(&scheduler, scheduler_task(program, &kernel))
	outcome := scheduler_wait(&scheduler, parent_id)
	testing.expect_value(t, outcome.kind, Task_Outcome_Kind.Complete)
	child_raw, child_ok := v.value_as_int(outcome.value)
	testing.expect(t, child_ok)

	child_outcome := scheduler_wait(&scheduler, Task_ID(child_raw))
	testing.expect_value(t, child_outcome.kind, Task_Outcome_Kind.Complete)

	rows: [dynamic]v.Tuple
	defer delete(rows)
	k.kernel_scan_into(&kernel, k.Relation_ID(1), []v.Binding{{}}, &rows)
	testing.expect_value(t, len(rows), 1)
}

@(test)
test_scheduler_external_request :: proc(t: ^testing.T) {
	kernel: k.Kernel
	k.kernel_init(&kernel)
	defer k.kernel_destroy(&kernel)

	program := compile_task_program(t, proc(builder: ^vm.Builder) {
		service := i32(vm.builder_add_constant(
			builder,
			v.value_symbol(v.symbol_intern("svc")),
		))
		payload := i32(vm.builder_add_constant(builder, value_int_must(5)))
		vm.builder_begin_function(builder, v.symbol_intern("main"), 0, 3, true)
		vm.builder_emit(builder, .Load_Const, 0, 0, service, 0)
		vm.builder_emit(builder, .Load_Const, 0, 1, payload, 0)
		vm.builder_emit(builder, .External_Request, 0, 2, 0, 1)
		vm.builder_emit(builder, .Return, 0, 2, 0, 0)
		vm.builder_end_function(builder)
	})

	scheduler: Scheduler
	scheduler_init(&scheduler, &kernel, Scheduler_Config{workers = 1, external_enabled = true})
	defer scheduler_destroy(&scheduler)

	id := scheduler_submit(&scheduler, scheduler_task(program, &kernel))
	testing.expect(t, scheduler_wait_suspended(&scheduler, id, .External_Request))

	job: External_Job
	testing.expect(t, scheduler_take_external(&scheduler, &job))
	testing.expect_value(t, job.task_id, id)
	request_service, service_ok := v.value_as_symbol(job.service)
	request_payload, payload_ok := v.value_as_int(job.payload)
	testing.expect(t, service_ok)
	name, name_ok := v.symbol_name(request_service)
	testing.expect(t, name_ok)
	testing.expect_value(t, name, "svc")
	testing.expect(t, payload_ok)
	testing.expect_value(t, request_payload, i64(5))

	testing.expect(t, scheduler_resume(&scheduler, id, value_int_must(99)))
	outcome := scheduler_wait(&scheduler, id)
	testing.expect_value(t, outcome.kind, Task_Outcome_Kind.Complete)
	value, value_ok := v.value_as_int(outcome.value)
	testing.expect(t, value_ok)
	testing.expect_value(t, value, i64(99))
}

// Without a handler the scheduler answers an external request inline: the task
// resumes with an `ExternalUnavailable` error value and never parks.
@(test)
test_scheduler_external_unavailable_without_handler :: proc(t: ^testing.T) {
	kernel: k.Kernel
	k.kernel_init(&kernel)
	defer k.kernel_destroy(&kernel)

	program := compile_task_program(t, proc(builder: ^vm.Builder) {
		service := i32(vm.builder_add_constant(
			builder,
			v.value_symbol(v.symbol_intern("svc")),
		))
		payload := i32(vm.builder_add_constant(builder, value_int_must(5)))
		vm.builder_begin_function(builder, v.symbol_intern("main"), 0, 3, true)
		vm.builder_emit(builder, .Load_Const, 0, 0, service, 0)
		vm.builder_emit(builder, .Load_Const, 0, 1, payload, 0)
		vm.builder_emit(builder, .External_Request, 0, 2, 0, 1)
		vm.builder_emit(builder, .Return, 0, 2, 0, 0)
		vm.builder_end_function(builder)
	})

	scheduler: Scheduler
	scheduler_init(&scheduler, &kernel, Scheduler_Config{workers = 1})
	defer scheduler_destroy(&scheduler)

	id := scheduler_submit(&scheduler, scheduler_task(program, &kernel))
	outcome := scheduler_wait(&scheduler, id)
	testing.expect_value(t, outcome.kind, Task_Outcome_Kind.Complete)
	error_value, is_error := v.value_as_error(outcome.value)
	testing.expect(t, is_error)
	if !is_error {
		return
	}
	code, code_ok := v.symbol_name(error_value.code)
	testing.expect(t, code_ok)
	testing.expect_value(t, code, "ExternalUnavailable")
}

// Two delayed tasks must both wake: the timer service must remove the timer it
// selected, not the last entry.
@(test)
test_scheduler_multiple_timers :: proc(t: ^testing.T) {
	kernel: k.Kernel
	k.kernel_init(&kernel)
	defer k.kernel_destroy(&kernel)

	program_a := compile_task_program(t, proc(builder: ^vm.Builder) {
		delay := vm.builder_add_constant(builder, value_int_must(50))
		vm.builder_begin_function(builder, v.symbol_intern("main"), 0, 2, true)
		vm.builder_emit(builder, .Load_Const, 0, 0, i32(delay), 0)
		vm.builder_emit(builder, .Sleep, 0, 0, 0, 0)
		vm.builder_emit(builder, .Return, 0, 0, 0, 0)
		vm.builder_end_function(builder)
	})
	program_b := compile_task_program(t, proc(builder: ^vm.Builder) {
		delay := vm.builder_add_constant(builder, value_int_must(100))
		vm.builder_begin_function(builder, v.symbol_intern("main"), 0, 2, true)
		vm.builder_emit(builder, .Load_Const, 0, 0, i32(delay), 0)
		vm.builder_emit(builder, .Sleep, 0, 0, 0, 0)
		vm.builder_emit(builder, .Return, 0, 0, 0, 0)
		vm.builder_end_function(builder)
	})

	scheduler: Scheduler
	scheduler_init(&scheduler, &kernel, Scheduler_Config{workers = 2})
	defer scheduler_destroy(&scheduler)

	id_a := scheduler_submit(&scheduler, scheduler_task(program_a, &kernel))
	id_b := scheduler_submit(&scheduler, scheduler_task(program_b, &kernel))

	time.sleep(200 * time.Millisecond)

	done_a := false
	done_b := false
	sync.mutex_lock(&scheduler.lock)
	if entry, ok := scheduler.entries[id_a]; ok {
		done_a = entry.done
	}
	if entry, ok := scheduler.entries[id_b]; ok {
		done_b = entry.done
	}
	sync.mutex_unlock(&scheduler.lock)

	testing.expect(t, done_a)
	testing.expect(t, done_b)

	// Cancel anything still parked so destroy does not wait on it.
	if !done_a {
		_ = scheduler_cancel(&scheduler, id_a)
	}
	if !done_b {
		_ = scheduler_cancel(&scheduler, id_b)
	}
}
