// Compiles every Mica source under a directory with the Mica emitter and
// reports coverage (#81).
//
//   odin run tools/emitcov -- [directory]
//
// Each artifact is decoded and validated, so "ok" means the emitted program
// is well-formed, not just that emission returned bytes. Files the emitter
// cannot yet handle are reported with the first error, which names the
// unsupported construct.
package main

import "core:fmt"
import "core:os"
import "core:strings"

import k "../../mica/kernel"
import r "../../mica/runtime"
import v "../../mica/var"
import vm "../../mica/vm"

COMPILER :: []string{"apps/compiler/lex.mica", "apps/compiler/parse.mica", "apps/compiler/emit.mica"}

main :: proc() {
	dir := "benchmarks/mica"
	if len(os.args) > 1 {
		dir = os.args[1]
	}

	// Collect sources before loading the compiler, so a bad path fails fast.
	sources: [dynamic]string
	defer delete(sources)
	if !walk_collect(dir, &sources) {
		os.exit(1)
	}
	fmt.printf("%d Mica files under %s\n", len(sources), dir)

	// One compiler world for every file.
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

	ok, failed := 0, 0
	for path in sources {
		data, read_err := os.read_entire_file_from_path(path, context.allocator)
		if read_err != nil {
			fmt.printf("FAIL %s: cannot read\n", path)
			failed += 1
			continue
		}
		outcome := r.world_call(world, "emit_source", []k.Role_Pair{{
			role  = v.value_symbol(v.symbol_intern("source")),
			value = v.value_string(context.allocator, string(data)),
		}})
		if outcome.kind != .Complete {
			fmt.printf("FAIL %s: task failed\n", path)
			failed += 1
			continue
		}
		fields, fields_ok := v.value_as_map(outcome.value)
		if !fields_ok {
			fmt.printf("FAIL %s: no map\n", path)
			failed += 1
			continue
		}
		flag, _ := v.value_as_bool(map_get(fields, "ok"))
		if !flag {
			message := "?"
			if list, list_ok := v.value_as_list(map_get(fields, "errors")); list_ok && len(list) > 0 {
				if s, s_ok := v.value_as_string(list[0]); s_ok {
					message = s
				}
			}
			fmt.printf("FAIL %s: %s\n", path, message)
			failed += 1
			continue
		}
		artifact, artifact_ok := v.value_as_bytes(map_get(fields, "bytes"))
		if !artifact_ok {
			fmt.printf("FAIL %s: emitted no bytes\n", path)
			failed += 1
			continue
		}
		program, decode_error := vm.program_from_bytes(artifact, context.allocator)
		if decode_error != .None {
			fmt.printf("FAIL %s: decode %v\n", path, decode_error)
			failed += 1
			continue
		}
		if validation := vm.program_validate(program); validation != .None {
			fmt.printf("FAIL %s: invalid %v\n", path, validation)
			failed += 1
			continue
		}
		fmt.printf("ok   %s\n", path)
		ok += 1
	}
	fmt.printf("\nok=%d failed=%d\n", ok, failed)
	if failed > 0 {
		os.exit(failed)
	}
}

// Appends every .mica path under `dir`, recursively.
walk_collect :: proc(dir: string, out: ^[dynamic]string) -> bool {
	handle, open_err := os.open(dir)
	if open_err != nil {
		fmt.eprintln("cannot open", dir)
		return false
	}
	defer os.close(handle)
	entries, read_err := os.read_dir(handle, -1, context.allocator)
	if read_err != nil {
		fmt.eprintln("cannot read", dir)
		return false
	}
	for entry in entries {
		path := strings.concatenate([]string{dir, "/", entry.name}, context.allocator)
		if entry.type == .Directory {
			if !walk_collect(path, out) {
				return false
			}
			continue
		}
		if strings.has_suffix(entry.name, ".mica") {
			append(out, path)
		}
	}
	return true
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
