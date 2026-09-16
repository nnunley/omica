// Times the Mica compiler compiling its own sources, the self-compile
// workload that dominates compilerperf's wall time (its timed stages compile a
// small target instead). Reports world load time and the best and median
// `emit_source` time over the joined compiler source.
//
// Run from the repository root: the compiler sources are read from
// `apps/compiler/` by relative path.
//
//   odin build tools/selfcompile -o:speed -out:/tmp/selfcompile
//   /tmp/selfcompile [iterations]
package main

import "core:fmt"
import "core:os"
import "core:slice"
import "core:strconv"
import "core:time"

import k "../../mica/kernel"
import r "../../mica/runtime"
import v "../../mica/var"

COMPILER :: []string{"apps/compiler/lex.mica", "apps/compiler/parse.mica", "apps/compiler/emit.mica"}

main :: proc() {
	iterations := 5
	if len(os.args) > 1 {
		if parsed, ok := strconv.parse_int(os.args[1]); ok {
			iterations = max(parsed, 1)
		}
	}
	source := read_compiler()
	fmt.printf("compiler source: %d bytes, %d iterations\n", len(source), iterations)

	kernel: k.Kernel
	k.kernel_init(&kernel)
	defer k.kernel_destroy(&kernel)
	load_tick := time.tick_now()
	world, start := r.world_start(&kernel, COMPILER, context.allocator)
	load_ns := i64(time.tick_since(load_tick))
	if !start.ok {
		fmt.eprintln("compiler load failed:", start.message)
		os.exit(1)
	}
	defer r.world_destroy(world)
	fmt.printf("world load: %8.3f ms\n", f64(load_ns)/1e6)
	_ = r.world_wait(world, world.entry)

	roles := []k.Role_Pair{{
		role  = v.value_symbol(v.symbol_intern("source")),
		value = v.value_string(context.allocator, source),
	}}
	for _ in 0 ..< 2 {
		call_emit(world, roles)
	}

	samples := make([]i64, iterations, context.temp_allocator)
	best := i64(1 << 62)
	for index in 0 ..< iterations {
		start_tick := time.tick_now()
		call_emit(world, roles)
		elapsed := i64(time.tick_since(start_tick))
		samples[index] = elapsed
		best = min(best, elapsed)
	}
	slice.sort(samples)
	fmt.printf(
		"self-compile: best %8.3f ms, median %8.3f ms (%d iterations)\n",
		f64(best)/1e6,
		f64(samples[len(samples)/2])/1e6,
		iterations,
	)
}

call_emit :: proc(world: ^r.World, roles: []k.Role_Pair) {
	outcome := r.world_call(world, "emit_source", roles)
	if outcome.kind != .Complete {
		fmt.eprintln("emit failed:", outcome.message)
		os.exit(1)
	}
	fields, fields_ok := v.value_as_map(outcome.value)
	if !fields_ok {
		fmt.eprintln("emit returned no fields")
		os.exit(1)
	}
	ok, _ := v.value_as_bool(map_get(fields, "ok"))
	if !ok {
		fmt.eprintln("emit reported failure")
		os.exit(1)
	}
}

read_compiler :: proc() -> string {
	total := 0
	parts: [3]string
	for path, index in COMPILER {
		data, read_err := os.read_entire_file_from_path(path, context.allocator)
		if read_err != nil {
			fmt.eprintln("cannot read", path)
			os.exit(1)
		}
		parts[index] = string(data)
		total += len(parts[index]) + 1
	}
	joined := make([dynamic]u8, 0, total, context.allocator)
	for part in parts {
		append(&joined, '\n')
		for ch in transmute([]u8)part {
			append(&joined, ch)
		}
	}
	return string(joined[:])
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
