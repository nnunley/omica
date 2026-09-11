// A Mica task: one VM instance over one transaction, run to a host boundary.
//
// The task model matches the Rust runtime: a task owns its VM and its
// transaction, commits at every host boundary, and reports one of three
// outcomes. Suspension commits and releases the transaction; resume begins a
// new one.
package mica_runtime

import "core:mem"
import k "../kernel"
import vm "../vm"
import v "../var"

Task_ID :: distinct u64

// Why a task stopped at a boundary.
Task_Suspend :: enum {
	None,
	Commit,
	Yield,
	Sleep,
	Host_Request,
	Spawn,
}

Task_Outcome_Kind :: enum {
	Pending,
	Complete,
	Aborted,
}

Task_Outcome :: struct {
	kind:    Task_Outcome_Kind,
	value:   v.Value,
	error:   v.Value,
	message: string,
	suspend: Task_Suspend,
	millis:  i64,
}

Task :: struct {
	id:        Task_ID,
	kernel:    ^k.Kernel,
	program:   ^vm.Program,
	env:       ^Builtin_Env,
	allocator: mem.Allocator,

	state:   vm.VM,
	tx:      k.Transaction,
	source:  k.Relation_Source,
	has_tx:  bool,
	outcome: Task_Outcome,
}

// Creates a task over `kernel`. The caller owns `program` and `env` and must
// keep them alive for the task's lifetime.
task_init :: proc(
	task: ^Task,
	id: Task_ID,
	kernel: ^k.Kernel,
	program: ^vm.Program,
	env: ^Builtin_Env,
	allocator := context.allocator,
) {
	task.id = id
	task.kernel = kernel
	task.program = program
	task.env = env
	task.allocator = allocator
	task.outcome = Task_Outcome{kind = .Pending}
	vm.vm_init(&task.state, program, allocator)
	task.source = k.Relation_Source {
		use_stored_derived = true,
	}
	vm.vm_set_workspace(&task.state, &task.source, &task.tx)
	task.state.user = env
	register_runtime_builtins(&task.state)
	task_begin_tx(task)
}

task_destroy :: proc(task: ^Task) {
	task_discard_tx(task)
	vm.vm_destroy(&task.state)
}

@(private)
task_begin_tx :: proc(task: ^Task) {
	task.tx = k.kernel_begin(task.kernel)
	task.source.transaction = &task.tx
	task.has_tx = true
}

@(private)
task_end_tx :: proc(task: ^Task) {
	if !task.has_tx {
		return
	}
	k.transaction_destroy(&task.tx)
	task.has_tx = false
	task.source.transaction = nil
}

@(private)
task_discard_tx :: proc(task: ^Task) {
	task_end_tx(task)
}

@(private)
task_commit :: proc(task: ^Task) -> k.Kernel_Error {
	if !task.has_tx {
		return k.Kernel_Error.None
	}
	committed, err := k.transaction_commit(&task.tx)
	if err != k.Kernel_Error.None {
		return err
	}
	k.snapshot_release(committed)
	return k.Kernel_Error.None
}

@(private)
task_abort :: proc(task: ^Task, message: string) -> Task_Outcome {
	task_discard_tx(task)
	task.outcome = Task_Outcome {
		kind    = .Aborted,
		error   = task.state.error,
		message = message,
	}
	return task.outcome
}

// Runs the task until it completes, aborts, or suspends.
task_run :: proc(task: ^Task) -> Task_Outcome {
	for {
		status := vm.vm_run(&task.state)
		switch status {
		case .Halted:
			if err := task_commit(task); err != k.Kernel_Error.None {
				return task_abort(task, "commit failed")
			}
			task_end_tx(task)
			task.outcome = Task_Outcome {
				kind  = .Complete,
				value = task.state.result,
			}
			return task.outcome

		case .Failed:
			return task_abort(task, "task failed")

		case .Boundary:
			switch task.state.request {
			case .Commit:
				if err := task_commit(task); err != k.Kernel_Error.None {
					return task_abort(task, "commit failed")
				}
				task_end_tx(task)
				task_begin_tx(task)
				task.state.request = .None

			case .Yield, .Sleep:
				if err := task_commit(task); err != k.Kernel_Error.None {
					return task_abort(task, "commit failed")
				}
				suspend := task.state.request == .Yield ? Task_Suspend.Yield : Task_Suspend.Sleep
				millis := task.state.request_millis
				task_end_tx(task)
				task.state.request = .None
				task.state.request_millis = 0
				task.outcome = Task_Outcome {
					kind    = .Pending,
					suspend = suspend,
					millis  = millis,
				}
				return task.outcome

			case .None:
				return task_abort(task, "unknown host request")
			}

		case .Ready:
			return task_abort(task, "vm did not run")
		}
	}
}

// Resumes a suspended task from its next boundary.
task_resume :: proc(task: ^Task) -> Task_Outcome {
	if task.outcome.kind != .Pending {
		return task.outcome
	}
	if !task.has_tx {
		task_begin_tx(task)
	}
	task.outcome.suspend = .None
	return task_run(task)
}
