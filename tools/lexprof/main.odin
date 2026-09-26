// Reports lexer throughput as a single number with a tight spread, so a codegen
// change can be judged without the benchmark driver's warmup noise.
//
//   odin run tools/lexprof -- [bytes] [iterations] [lexer-path]
//
// The source is a well-formed Mica snippet repeated to the requested size, so
// every run lexes identical work. The reported minimum is over `iterations`
// runs; the min/max spread is the run-to-run noise on this machine.
//
// This is a development tool, not a gate. The differential lexer test in
// `mica/runtime/runtime_test.odin` is the correctness gate.
package main

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:time"
import k "../../mica/kernel"
import r "../../mica/runtime"
import v "../../mica/var"

DEFAULT_BYTES :: 65536
DEFAULT_ITERATIONS :: 7

main :: proc() {
	size := DEFAULT_BYTES
	iterations := DEFAULT_ITERATIONS
	if len(os.args) > 1 {
		if parsed, ok := strconv.parse_int(os.args[1]); ok {
			size = parsed
		}
	}
	if len(os.args) > 2 {
		if parsed, ok := strconv.parse_int(os.args[2]); ok {
			iterations = max(parsed, 1)
		}
	}
	lexer_path := "apps/compiler/lex.mica"
	if len(os.args) > 3 {
		lexer_path = os.args[3]
	}

	// A snippet exercising identifiers, keywords, numbers, punctuation, and a
	// string literal: a representative token mix.
	snippet := "verb foo(a, b)\n  let x = a + b * 3\n  // note\n  return \"x\"\nend\n"
	builder: strings.Builder
	strings.builder_init(&builder, context.temp_allocator)
	for len(strings.to_string(builder)) < size {
		strings.write_string(&builder, snippet)
	}
	source := strings.to_string(builder)

	kernel: k.Kernel
	k.kernel_init(&kernel)
	defer k.kernel_destroy(&kernel)
	world, start := r.world_start(&kernel, []string{lexer_path}, context.allocator)
	if !start.ok {
		fmt.eprintln("load failed:", start.message)
		os.exit(1)
	}
	defer r.world_destroy(world)
	_ = r.world_wait(world, world.entry)

	best := time.Duration(1 << 62)
	worst := time.Duration(0)
	tokens := 0
	for _ in 0 ..< iterations {
		start_tick := time.tick_now()
		outcome := r.world_call(world, "lex", []k.Role_Pair{{
			role  = v.value_symbol(v.symbol_intern("source")),
			value = v.value_string(context.temp_allocator, source),
		}})
		elapsed := time.tick_since(start_tick)
		if outcome.kind != .Complete {
			fmt.eprintln("lex failed:", outcome.message)
			os.exit(1)
		}
		best = min(best, elapsed)
		worst = max(worst, elapsed)
		result, _ := v.value_as_list(outcome.value)
		list, _ := v.value_as_list(result[0])
		tokens = len(list)
	}
	fmt.printf("bytes=%d tokens=%d min=%v max=%v\n", len(source), tokens, best, worst)
}
