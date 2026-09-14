package main

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"

import k "../../mica/kernel"
import r "../../mica/runtime"
import v "../../mica/var"

main :: proc() {
	dir := "benchmarks/mica"
	handle, open_err := os.open(dir)
	if open_err != nil {
		fmt.eprintln("cannot open corpus:", open_err)
		os.exit(1)
	}
	defer os.close(handle)
	entries, read_err := os.read_dir(handle, -1, context.allocator)
	if read_err != nil {
		fmt.eprintln("cannot read corpus:", read_err)
		os.exit(1)
	}
	ok, failed := 0, 0
	for entry in entries {
		if !strings.has_suffix(entry.name, ".mica") {
			continue
		}
		parts := []string{dir, entry.name}
		path, join_err := filepath.join(parts, context.allocator)
		if join_err != nil {
			continue
		}
		source, read_err2 := os.read_entire_file_from_path(path, context.allocator)
		if read_err2 != nil {
			continue
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
		if outcome.kind == .Complete {
			fields, _ := v.value_as_map(outcome.value)
			ok_value := map_get(fields, "ok")
			if flag, flag_ok := v.value_as_bool(ok_value); flag_ok && flag {
				fmt.printf("ok   %s\n", entry.name)
				ok += 1
			} else {
				errs := map_get(fields, "errors")
				message := "?"
				if list, list_ok := v.value_as_list(errs); list_ok && len(list) > 0 {
					if s, s_ok := v.value_as_string(list[0]); s_ok {
						message = s
					}
				}
				fmt.printf("FAIL %s: %s\n", entry.name, message)
				failed += 1
			}
		} else {
			fmt.printf("FAIL %s: task failed\n", entry.name)
			failed += 1
		}
		r.world_destroy(world)
		k.kernel_destroy(&kernel)
	}
	fmt.printf("\nok=%d failed=%d\n", ok, failed)
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
