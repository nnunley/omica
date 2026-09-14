package main

import "core:fmt"
import "core:os"

import k "../../mica/kernel"
import r "../../mica/runtime"
import v "../../mica/var"
import vm "../../mica/vm"

COMPILER :: []string{"apps/compiler/lex.mica", "apps/compiler/parse.mica", "apps/compiler/emit.mica"}

main :: proc() {
	// Odin-compiled program.
	kernel: k.Kernel
	k.kernel_init(&kernel)
	defer k.kernel_destroy(&kernel)
	world, start := r.world_start(&kernel, COMPILER, context.allocator)
	if !start.ok {
		fmt.eprintln("load failed:", start.message)
		os.exit(1)
	}
	defer r.world_destroy(world)
	_ = r.world_wait(world, world.entry)
	odin_total := total_instructions(world.program)

	// Mica-emitted program.
	source := read_compiler()
	artifact := emit_artifact(world, source)
	if artifact == nil {
		fmt.eprintln("emit failed")
		os.exit(1)
	}
	program, decode_error := vm.program_from_bytes(artifact, context.allocator)
	if decode_error != .None {
		fmt.eprintln("decode:", decode_error)
		os.exit(1)
	}
	mica_total := total_instructions(program)

	fmt.printf("program          functions   instructions\n")
	fmt.printf("odin-compiled    %9d   %12d\n", len(world.program.functions), odin_total)
	fmt.printf("mica-emitted     %9d   %12d\n", len(program.functions), mica_total)
	fmt.printf("ratio (mica/odin)                %8.2fx\n", f64(mica_total)/f64(odin_total))

	// Op mix for each.
	print_mix("odin", world.program)
	print_mix("mica", program)
}

total_instructions :: proc(program: ^vm.Program) -> int {
	total := 0
	for fn in program.functions {
		total += fn.code_len
	}
	return total
}

// Counts *emitted* instructions, not executed ones. Executed count needs a VM
// hook; this at least shows program size parity.
print_mix :: proc(label: string, program: ^vm.Program) {
	counts: [256]int
	for fn in program.functions {
		for index in fn.code_offset ..< fn.code_offset + fn.code_len {
			counts[u8(program.code[index].op)] += 1
		}
	}
	move := counts[u8(vm.Op.Move)]
	load := counts[u8(vm.Op.Load_Const)]
	total := total_instructions(program)
	fmt.printf("\n%s: move %d (%.1f%%), load_const %d (%.1f%%)\n",
		label, move, 100.0*f64(move)/f64(total), load, 100.0*f64(load)/f64(total))
}

read_compiler :: proc() -> string {
	joined := make([dynamic]u8, 0, 160000, context.allocator)
	for path in COMPILER {
		data, read_err := os.read_entire_file_from_path(path, context.allocator)
		if read_err != nil {
			os.exit(1)
		}
		append(&joined, '\n')
		for ch in transmute([]u8)string(data) {
			append(&joined, ch)
		}
	}
	return string(joined[:])
}

emit_artifact :: proc(world: ^r.World, source: string) -> []u8 {
	outcome := r.world_call(world, "emit_source", []k.Role_Pair{{
		role  = v.value_symbol(v.symbol_intern("source")),
		value = v.value_string(context.allocator, source),
	}})
	if outcome.kind != .Complete {
		return nil
	}
	fields, _ := v.value_as_map(outcome.value)
	ok, _ := v.value_as_bool(map_get(fields, "ok"))
	if !ok {
		return nil
	}
	artifact, _ := v.value_as_bytes(map_get(fields, "bytes"))
	owned := make([]u8, len(artifact), context.allocator)
	copy(owned, artifact)
	return owned
}

map_get :: proc(entries: []v.Map_Entry, name: string) -> v.Value {
	key := v.value_symbol(v.symbol_intern(name))
	for entry in entries {
		if entry.key == key {
			return entry.value
		}
	}
	return v.Value(0)
}
