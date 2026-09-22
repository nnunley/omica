// Task-runtime benchmarks: one thread per task, one transaction per commit.
//
// Each task asserts a batch of rows into its own relation and commits every
// 128 rows, so tasks have real VM and transaction work to overlap. The worker
// count varies while the task count stays fixed.
package main

import "core:fmt"
import "core:mem"

import k "../mica/kernel"
import r "../mica/runtime"
import vm "../mica/vm"
import mm "../vendor/micromeasure/micromeasure-odin"
import v "../mica/var"

TASK_BENCH_TASKS :: 64
TASK_BENCH_ROWS :: 2048
TASK_BENCH_COMMIT_EVERY :: 128

@(private)
Task_Bench_State :: struct {
	tasks:   int,
	rows:    int,
	workers: int,
}

@(private)
build_task_program :: proc(
	relation: k.Relation_ID,
	rows: int,
	allocator: mem.Allocator,
) -> ^vm.Program {
	builder: vm.Builder
	vm.builder_init(&builder)
	defer vm.builder_destroy(&builder)

	vm.builder_begin_function(&builder, v.symbol_intern("main"), 0, 2, true)
	for index in 0 ..< rows {
		identity, _ := v.value_identity_raw(u64(index) + 1)
		row, row_err := v.value_relation(
			allocator,
			[]v.Symbol{v.symbol_intern("value")},
			[]v.Tuple {
				v.tuple_new(allocator, []v.Value{identity}),
			},
		)
		assert(row_err == .None)
		row_constant := vm.builder_add_constant(&builder, row)
		vm.builder_emit(&builder, .Load_Const, 0, 0, i32(row_constant), 0)
		vm.builder_emit(&builder, .Assert, 0, i32(relation), 0, 0)
		if (index + 1) % TASK_BENCH_COMMIT_EVERY == 0 {
			vm.builder_emit(&builder, .Commit, 0, 0, 0, 0)
		}
	}
	vm.builder_emit(&builder, .Return, 0, 0, 0, 0)
	vm.builder_end_function(&builder)

	return vm.builder_build(&builder, allocator)
}

@(private)
bench_tasks :: proc(user: rawptr, _: int, _: int) {
	state := (^Task_Bench_State)(user)

	kernel: k.Kernel
	k.kernel_init(&kernel)
	defer k.kernel_destroy(&kernel)

	scheduler: r.Scheduler
	r.scheduler_init(
		&scheduler,
		&kernel,
		r.Scheduler_Config{workers = state.workers},
	)
	defer r.scheduler_destroy(&scheduler)

	ids := make([]r.Task_ID, state.tasks, context.temp_allocator)
	for index in 0 ..< state.tasks {
		relation := k.Relation_ID(index + 1)
		metadata := k.relation_metadata(
			relation,
			v.symbol_intern(fmt.aprintf(
				"TaskBench%d",
				index,
				allocator = context.temp_allocator,
			)),
			1,
		)
		snapshot, err := k.kernel_create_relation(&kernel, metadata)
		assert(err == .None)
		k.snapshot_release(snapshot)

		program := build_task_program(relation, state.rows, context.temp_allocator)
		task := new(r.Task)
		r.task_init(task, 0, &kernel, program, nil)
		ids[index] = r.scheduler_submit(&scheduler, task)
	}

	for id in ids {
		outcome := r.scheduler_wait(&scheduler, id)
		assert(outcome.kind == .Complete)
	}
}

@(private)
task_bench_states: [4]Task_Bench_State

@(private)
register_task_benches :: proc(runner: ^mm.Runner) {
	worker_counts := [4]int{1, 2, 4, 8}
	group := mm.group(
		runner,
		"runtime/tasks",
		mm.throughput_per_op(f64(TASK_BENCH_TASKS * TASK_BENCH_ROWS), "row"),
	)
	group.counter_scope = .Disabled // Work runs on scheduler threads.
	for workers, index in worker_counts {
		task_bench_states[index] = Task_Bench_State {
			tasks   = TASK_BENCH_TASKS,
			rows    = TASK_BENCH_ROWS,
			workers = workers,
		}
		mm.bench_capped(
			group,
			fmt.aprintf("workers_%d", workers),
			&task_bench_states[index],
			bench_tasks,
			1,
		)
	}
}
