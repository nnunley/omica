package mica_runtime

import "core:testing"
import k "../kernel"
import vm "../vm"
import v "../var"

@(private)
compile_task_program :: proc(
	t: ^testing.T,
	build: proc(builder: ^vm.Builder),
	allocator := context.temp_allocator,
) -> ^vm.Program {
	builder: vm.Builder
	vm.builder_init(&builder)
	defer vm.builder_destroy(&builder)
	build(&builder)
	return vm.builder_build(&builder, allocator)
}

@(test)
test_task_yield_and_resume :: proc(t: ^testing.T) {
	kernel: k.Kernel
	k.kernel_init(&kernel)
	defer k.kernel_destroy(&kernel)

	program := compile_task_program(t, proc(builder: ^vm.Builder) {
		forty_two := vm.builder_add_constant(builder, value_int_must(42))
		vm.builder_begin_function(builder, v.symbol_intern("main"), 0, 2, true)
		vm.builder_emit(builder, .Load_Const, 0, 0, i32(forty_two), 0)
		vm.builder_emit(builder, .Yield, 0, 0, 0, 0)
		vm.builder_emit(builder, .Return, 0, 0, 0, 0)
		vm.builder_end_function(builder)
	})

	task: Task
	task_init(&task, 1, &kernel, program, nil)
	defer task_destroy(&task)

	outcome := task_run(&task)
	testing.expect_value(t, outcome.kind, Task_Outcome_Kind.Pending)
	testing.expect_value(t, outcome.suspend, Task_Suspend.Yield)

	outcome = task_resume(&task)
	testing.expect_value(t, outcome.kind, Task_Outcome_Kind.Complete)
	value, value_ok := v.value_as_int(outcome.value)
	testing.expect(t, value_ok)
	testing.expect_value(t, value, i64(42))
}

@(test)
test_task_sleep_and_resume :: proc(t: ^testing.T) {
	kernel: k.Kernel
	k.kernel_init(&kernel)
	defer k.kernel_destroy(&kernel)

	program := compile_task_program(t, proc(builder: ^vm.Builder) {
		five := vm.builder_add_constant(builder, value_int_must(5))
		vm.builder_begin_function(builder, v.symbol_intern("main"), 0, 2, true)
		vm.builder_emit(builder, .Load_Const, 0, 0, i32(five), 0)
		vm.builder_emit(builder, .Sleep, 0, 0, 0, 0)
		vm.builder_emit(builder, .Return, 0, 0, 0, 0)
		vm.builder_end_function(builder)
	})

	task: Task
	task_init(&task, 2, &kernel, program, nil)
	defer task_destroy(&task)

	outcome := task_run(&task)
	testing.expect_value(t, outcome.kind, Task_Outcome_Kind.Pending)
	testing.expect_value(t, outcome.suspend, Task_Suspend.Sleep)
	testing.expect_value(t, outcome.millis, i64(5))

	outcome = task_resume(&task)
	testing.expect_value(t, outcome.kind, Task_Outcome_Kind.Complete)
}

@(test)
test_task_commit_boundary_continues :: proc(t: ^testing.T) {
	kernel: k.Kernel
	k.kernel_init(&kernel)
	defer k.kernel_destroy(&kernel)

	initial_version := kernel.current.version

	program := compile_task_program(t, proc(builder: ^vm.Builder) {
		seven := vm.builder_add_constant(builder, value_int_must(7))
		vm.builder_begin_function(builder, v.symbol_intern("main"), 0, 2, true)
		vm.builder_emit(builder, .Commit, 0, 0, 0, 0)
		vm.builder_emit(builder, .Load_Const, 0, 0, i32(seven), 0)
		vm.builder_emit(builder, .Return, 0, 0, 0, 0)
		vm.builder_end_function(builder)
	})

	task: Task
	task_init(&task, 3, &kernel, program, nil)
	defer task_destroy(&task)

	outcome := task_run(&task)
	testing.expect_value(t, outcome.kind, Task_Outcome_Kind.Complete)
	testing.expect(t, kernel.current.version > initial_version)
}

@(test)
test_task_writes_survive_suspend :: proc(t: ^testing.T) {
	kernel: k.Kernel
	k.kernel_init(&kernel)
	defer k.kernel_destroy(&kernel)

	metadata := k.relation_metadata(k.Relation_ID(1), v.symbol_intern("Flag"), 1)
	snapshot, err := k.kernel_create_relation(&kernel, metadata)
	testing.expect_value(t, err, k.Kernel_Error.None)
	k.snapshot_release(snapshot)

	program := compile_task_program(t, proc(builder: ^vm.Builder) {
		cell := v.tuple_new(context.temp_allocator, []v.Value{value_int_must(1)})
		row, row_err := v.value_relation(
			context.temp_allocator,
			[]v.Symbol{v.symbol_intern("value")},
			[]v.Tuple{cell},
		)
		assert(row_err == .None)
		flag := vm.builder_add_constant(builder, row)

		second_cell := v.tuple_new(context.temp_allocator, []v.Value{value_int_must(2)})
		second_row, second_err := v.value_relation(
			context.temp_allocator,
			[]v.Symbol{v.symbol_intern("value")},
			[]v.Tuple{second_cell},
		)
		assert(second_err == .None)
		flag_two := vm.builder_add_constant(builder, second_row)

		vm.builder_begin_function(builder, v.symbol_intern("main"), 0, 2, true)
		vm.builder_emit(builder, .Load_Const, 0, 0, i32(flag), 0)
		vm.builder_emit(builder, .Assert, 0, 1, 0, 0)
		vm.builder_emit(builder, .Commit, 0, 0, 0, 0)
		vm.builder_emit(builder, .Yield, 0, 0, 0, 0)
		vm.builder_emit(builder, .Load_Const, 0, 0, i32(flag_two), 0)
		vm.builder_emit(builder, .Assert, 0, 1, 0, 0)
		vm.builder_emit(builder, .Return, 0, 0, 0, 0)
		vm.builder_end_function(builder)
	})

	task: Task
	task_init(&task, 4, &kernel, program, nil)
	defer task_destroy(&task)

	outcome := task_run(&task)
	testing.expect_value(t, outcome.kind, Task_Outcome_Kind.Pending)
	testing.expect_value(t, outcome.suspend, Task_Suspend.Yield)

	rows: [dynamic]v.Tuple
	defer delete(rows)
	k.kernel_scan_into(&kernel, k.Relation_ID(1), []v.Binding{{}}, &rows)
	testing.expect_value(t, len(rows), 1)

	outcome = task_resume(&task)
	testing.expect_value(t, outcome.kind, Task_Outcome_Kind.Complete)

	clear(&rows)
	k.kernel_scan_into(&kernel, k.Relation_ID(1), []v.Binding{{}}, &rows)
	testing.expect_value(t, len(rows), 2)
}
