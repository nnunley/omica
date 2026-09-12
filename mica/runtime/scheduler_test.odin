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
	scheduler_init(&scheduler, &kernel, Scheduler_Config{workers = 1})
	defer scheduler_destroy(&scheduler)

	id := scheduler_submit(&scheduler, scheduler_task(program, &kernel))
	testing.expect(t, scheduler_wait_suspended(&scheduler, id, .External_Request))

	sync.mutex_lock(&scheduler.lock)
	entry := scheduler.entries[id]
	request_service, service_ok := v.value_as_symbol(entry.task.state.request_value)
	request_payload, payload_ok := v.value_as_int(entry.task.state.request_payload)
	sync.mutex_unlock(&scheduler.lock)
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
