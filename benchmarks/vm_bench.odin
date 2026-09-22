// Microbenchmarks for VM opcode dispatch.
//
// Each program is a straight-line sequence of identical opcodes ending in a
// Return, so the measured cost is instruction dispatch with no loop control to
// subtract. One benchmark operation is one program run; the reported
// throughput is the number of target opcodes executed per second.
//
//	odin run benchmarks -o:speed -- -suite=vm
package main

import "core:mem"
import "core:mem/virtual"

import mm "../vendor/micromeasure/micromeasure-odin"
import v "../mica/var"
import vm "../mica/vm"

// Target opcodes per program. Large enough that the prologue and the single
// Return are noise.
VM_OPS :: 20000

// One opcode benchmark: a built program plus the VM to run it.
Vm_Bench :: struct {
	program:     ^vm.Program,
	state:       vm.VM,
	ops_per_run: int,
}

Vm_Body_Kind :: enum {
	Move,
	Load_Const,
	Binary_Add,
	Binary_Cmp,
	Unary_Not,
	Index_List,
	Is_Truthy,
	Call,
	Builtin_Call,
}

// A no-op builtin so Builtin_Call measures dispatch, not work.
vm_noop_builtin :: proc(_: ^vm.VM, _: []v.Value) -> (v.Value, bool) {
	return v.value_bool(true), true
}

vm_bench_init :: proc(kind: Vm_Body_Kind) -> ^Vm_Bench {
	bench := new(Vm_Bench)
	arena := new(virtual.Arena)
	if err := virtual.arena_init_growing(arena); err != nil {
		panic("failed to initialize vm bench arena")
	}
	alloc := virtual.arena_allocator(arena)

	b: vm.Builder
	vm.builder_init(&b, alloc)

	zero, _ := v.value_int(0)
	one, _ := v.value_int(1)
	list := v.value_list(alloc, []v.Value{one})
	c_one := i32(vm.builder_add_constant(&b, one))
	c_list := i32(vm.builder_add_constant(&b, list))
	c_key := i32(vm.builder_add_constant(&b, zero))
	builtin_index: i32 = -1
	if kind == .Builtin_Call {
		builtin_index = vm.builder_add_builtin(&b, v.symbol_intern("noop"))
	}

	// A helper function returning its argument, for Call benchmarks.
	helper_index: i32 = -1
	if kind == .Call {
		helper_index = i32(vm.builder_begin_function(&b, v.symbol_intern("id"), 1, 2))
		vm.builder_emit(&b, .Return, 0, 0, 0, 0)
		vm.builder_end_function(&b)
	}

	// Register plan: r0 = operand A, r1 = operand B, r2 = destination,
	// r3 = key register (0).
	vm.builder_begin_function(&b, v.symbol_intern("main"), 0, 4, true)
	vm.builder_emit(&b, .Load_Const, 0, 0, c_one, 0)
	vm.builder_emit(&b, .Load_Const, 0, 1, c_one, 0)
	vm.builder_emit(&b, .Load_Const, 0, 3, c_key, 0)
	for _ in 0 ..< VM_OPS {
		switch kind {
		case .Move:
			vm.builder_emit(&b, .Move, 0, 2, 0, 0)
		case .Load_Const:
			vm.builder_emit(&b, .Load_Const, 0, 2, c_one, 0)
		case .Binary_Add:
			vm.builder_emit(&b, .Binary, u8(vm.Bin_Op.Add), 2, 0, 1)
		case .Binary_Cmp:
			vm.builder_emit(&b, .Binary, u8(vm.Bin_Op.Eq), 2, 0, 1)
		case .Unary_Not:
			vm.builder_emit(&b, .Unary, u8(vm.Un_Op.Not), 0, 0, 0)
		case .Index_List:
			// collection register holds the list; key register holds 0.
			vm.builder_emit(&b, .Load_Const, 0, 2, c_list, 0)
			vm.builder_emit(&b, .Index, 0, 2, 2, 3)
		case .Is_Truthy:
			vm.builder_emit(&b, .Is_Truthy, 0, 2, 0, 0)
		case .Call:
			vm.builder_emit(&b, .Call, 1, 2, helper_index, 0)
		case .Builtin_Call:
			vm.builder_emit(&b, .Builtin_Call, 0, 2, builtin_index, 0)
		}
	}
	vm.builder_emit(&b, .Return, 0, 2, 0, 0)
	vm.builder_end_function(&b)

	program := vm.builder_build(&b, alloc)
	vm.builder_destroy(&b)

	// Index_List emits two instructions per counted opcode, so its op count is
	// the instruction count, not VM_OPS.
	bench.program = program
	bench.ops_per_run = VM_OPS * 2 if kind == .Index_List else VM_OPS
	vm.vm_init(&bench.state, program, alloc)
	if kind == .Builtin_Call {
		vm.vm_register_builtin(&bench.state, v.symbol_intern("noop"), 0, vm_noop_builtin)
		vm.vm_resolve_builtins(&bench.state)
	}
	return bench
}

// Runs the program `chunk` times, resetting the VM between runs.
@(private)
vm_run_chunk :: proc(user: rawptr, chunk: int, _: int) {
	bench := (^Vm_Bench)(user)
	for _ in 0 ..< chunk {
		vm.vm_reset(&bench.state)
		if vm.vm_run(&bench.state) != .Halted {
			panic("vm opcode benchmark program did not halt")
		}
	}
}

// One operation is one program run; throughput counts target opcodes.
@(private)
vm_throughput :: proc(user: rawptr) -> mm.Throughput {
	bench := (^Vm_Bench)(user)
	return mm.throughput_per_op(f64(bench.ops_per_run), "opcode")
}

register_vm_benches :: proc(runner: ^mm.Runner) {
	cases := [?]struct {
		name: string,
		kind: Vm_Body_Kind,
	} {
		{"move", .Move},
		{"load_const", .Load_Const},
		{"binary_add", .Binary_Add},
		{"binary_cmp", .Binary_Cmp},
		{"unary_not", .Unary_Not},
		{"index_list", .Index_List},
		{"is_truthy", .Is_Truthy},
		{"call", .Call},
		{"builtin_call", .Builtin_Call},
	}
	for entry in cases {
		bench := vm_bench_init(entry.kind)
		group := mm.group(runner, "vm/opcode", vm_throughput(bench))
		mm.bench(group, entry.name, bench, vm_run_chunk)
	}
}
