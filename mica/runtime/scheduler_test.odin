package mica_runtime

import "core:fmt"
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
