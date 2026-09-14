// Compiles the Mica compiler's own sources through the Mica emitter, which is
// the strongest self-hosting check available before the whole bootstrap: the
// Mica emitter must accept the same language it is written in.
package main

import "core:fmt"
import "core:os"

import k "../../mica/kernel"
import r "../../mica/runtime"
import v "../../mica/var"
import vm "../../mica/vm"

main :: proc() {
	paths := os.args[1:]
	failed := 0
	for path in paths {
		source, read_err := os.read_entire_file_from_path(path, context.allocator)
		if read_err != nil {
			fmt.eprintln("cannot read", path)
			os.exit(1)
		}
		kernel: k.Kernel
		k.kernel_init(&kernel)
		world, start := r.world_start(
			&kernel,
			[]string{"apps/compiler/lex.mica", "apps/compiler/parse.mica", "apps/compiler/emit.mica"},
			context.allocator,
		)
		if !start.ok {
			fmt.eprintln("compiler load failed:", start.message)
			os.exit(1)
		}
		_ = r.world_wait(world, world.entry)
		outcome := r.world_call(world, "emit_source", []k.Role_Pair{{
			role  = v.value_symbol(v.symbol_intern("source")),
			value = v.value_string(context.allocator, string(source)),
		}})
		if outcome.kind != .Complete {
			fmt.printf("FAIL %s: task failed\n", path)
			failed += 1
		} else if fields, fields_ok := v.value_as_map(outcome.value); fields_ok {
			ok, _ := v.value_as_bool(map_get(fields, "ok"))
			if !ok {
				errors := map_get(fields, "errors")
				message := "?"
				if list, list_ok := v.value_as_list(errors); list_ok && len(list) > 0 {
					if s, s_ok := v.value_as_string(list[0]); s_ok {
						message = s
					}
				}
				fmt.printf("FAIL %s: %s\n", path, message)
				failed += 1
			} else if artifact, artifact_ok := v.value_as_bytes(map_get(fields, "bytes")); artifact_ok {
				if program, decode_error := vm.program_from_bytes(artifact, context.allocator); decode_error != .None {
					fmt.printf("FAIL %s: decode %v\n", path, decode_error)
					failed += 1
				} else if validation := vm.program_validate(program); validation != .None {
					fmt.printf("FAIL %s: invalid %v\n", path, validation)
					failed += 1
				} else {
					fmt.printf("ok   %s (%d bytes, %d functions)\n", path, len(artifact), len(program.functions))
				}
			} else {
				fmt.printf("FAIL %s: no bytes\n", path)
				failed += 1
			}
		}
		r.world_destroy(world)
		k.kernel_destroy(&kernel)
	}
	fmt.printf("\nfailed=%d\n", failed)
	os.exit(failed)
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
