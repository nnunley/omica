// Native baseline: parse and compile a Mica source with the Odin compiler
// directly, no VM in the loop. This is the apples-to-apples comparison to the
// interpreted `emit_source` the other tools time.
//
//   odin run tools/nativebaseline -o:speed -- [iterations] [target]
package main

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:time"

import c "../../mica/compiler"
import v "../../mica/var"

main :: proc() {
	iterations := 15
	if len(os.args) > 1 {
		if parsed, ok := strconv.parse_int(os.args[1]); ok {
			iterations = max(parsed, 1)
		}
	}
	target_path := "apps/compiler/parse.mica"
	if len(os.args) > 2 {
		target_path = os.args[2]
	}
	data, read_err := os.read_entire_file_from_path(target_path, context.allocator)
	if read_err != nil {
		fmt.eprintln("cannot read", target_path)
		os.exit(1)
	}
	source := string(data)
	fmt.printf("target: %s (%d bytes), %d iterations\n", target_path, len(source), iterations)

	// Warm up.
	for _ in 0 ..< 2 {
		run_once(source)
	}
	best := i64(1 << 62)
	for _ in 0 ..< iterations {
		start := time.tick_now()
		run_once(source)
		elapsed := i64(time.tick_since(start))
		best = min(best, elapsed)
	}
	fmt.printf("native (odin compiler, no VM): %8.3f us  (%.3f us/byte)\n",
		f64(best)/1000.0, f64(best)/f64(len(source)))
}

run_once :: proc(source: string) {
	ast, parse_errors := c.parse_program(source, context.temp_allocator)
	if len(parse_errors) > 0 {
		fmt.eprintln("parse:", parse_errors[0].message)
		os.exit(1)
	}
	ctx := c.Compile_Context {
		builtins   = make(map[string]bool, context.temp_allocator),
		relations  = make(map[string]u32, context.temp_allocator),
		identities = make(map[string]v.Value, context.temp_allocator),
	}
	compiled := c.compile_program(ast, &ctx, context.temp_allocator)
	if len(compiled.errors) > 0 {
		fmt.eprintln("compile:", compiled.errors[0].message)
		os.exit(1)
	}
}
