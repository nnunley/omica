// Writes the raw program bytes the Mica emitter produces for one `.mica`
// source file, so two emitter revisions can be compared byte for byte.
//
// Usage:
//
//	odin run tools/emitraw -- <source.mica> <out.bin>
package main

import "core:fmt"
import "core:os"

import k "../../mica/kernel"
import r "../../mica/runtime"
import v "../../mica/var"

COMPILER :: []string{"apps/compiler/lex.mica", "apps/compiler/parse.mica", "apps/compiler/emit.mica"}

main :: proc() {
	if len(os.args) != 3 {
		fmt.eprintln("usage: emitraw <source.mica> <out.bin>")
		os.exit(2)
	}
	path := os.args[1]
	out := os.args[2]
	source, read_err := os.read_entire_file_from_path(path, context.allocator)
	if read_err != nil {
		fmt.eprintln("cannot read", path)
		os.exit(1)
	}

	kernel: k.Kernel
	k.kernel_init(&kernel)
	defer k.kernel_destroy(&kernel)
	world, start := r.world_start(&kernel, COMPILER, context.allocator)
	if !start.ok {
		fmt.eprintln("compiler load failed:", start.message)
		os.exit(1)
	}
	defer r.world_destroy(world)
	_ = r.world_wait(world, world.entry)

	outcome := r.world_call(world, "emit_source", []k.Role_Pair{{
		role  = v.value_symbol(v.symbol_intern("source")),
		value = v.value_string(context.allocator, string(source)),
	}})
	if outcome.kind != .Complete {
		fmt.eprintln("emit failed:", outcome.message)
		os.exit(1)
	}
	fields, _ := v.value_as_map(outcome.value)
	ok, _ := v.value_as_bool(map_get(fields, "ok"))
	if !ok {
		errors, _ := v.value_as_list(map_get(fields, "errors"))
		if len(errors) > 0 {
			if message, is_string := v.value_as_string(errors[0]); is_string {
				fmt.eprintln("emitter error:", message)
			}
		}
		os.exit(1)
	}
	artifact, _ := v.value_as_bytes(map_get(fields, "bytes"))
	if write_err := os.write_entire_file(out, artifact); write_err != nil {
		fmt.eprintln("cannot write", out)
		os.exit(1)
	}
	fmt.println("wrote", len(artifact), "bytes to", out)
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
