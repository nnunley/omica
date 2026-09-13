// Reports parser throughput as a single number with a tight spread.
//
//   odin run tools/parseprof -o:speed -- [bytes] [iterations]
//
// Loads apps/compiler/lex.mica and apps/compiler/parse.mica, parses a repeated
// well-formed source of the requested size, and reports the minimum over
// `iterations` runs. A development tool, not a gate; the differential parser
// test is the correctness gate.
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
	parser_path := "apps/compiler/parse.mica"
	if len(os.args) > 3 {
		parser_path = os.args[3]
	}
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
	// A snippet with declarations, a rule, and a verb.
	snippet := "make_identity(:a)\nmake_relation(:R, 2)\nR(x, y) :- S(x, y)\nverb f(a, b)\n  let c = a + b\n  return c\nend\n"
	builder: strings.Builder
	strings.builder_init(&builder, context.temp_allocator)
	for len(strings.to_string(builder)) < size {
		strings.write_string(&builder, snippet)
	}
	source := strings.to_string(builder)

	kernel: k.Kernel
	k.kernel_init(&kernel)
	defer k.kernel_destroy(&kernel)
	world, start := r.world_start(
		&kernel,
		[]string{"apps/compiler/lex.mica", parser_path},
		context.temp_allocator,
	)
	if !start.ok {
		fmt.eprintln("load failed:", start.message)
		os.exit(1)
	}
	defer r.world_destroy(world)
	_ = r.world_wait(world, world.entry)

	best := time.Duration(1 << 62)
	worst := time.Duration(0)
	nodes := 0
	for _ in 0 ..< iterations {
		start_tick := time.tick_now()
		outcome := r.world_call(world, "parse", []k.Role_Pair{{
			role  = v.value_symbol(v.symbol_intern("source")),
			value = v.value_string(context.temp_allocator, source),
		}})
		elapsed := time.tick_since(start_tick)
		if outcome.kind != .Complete {
			fmt.eprintln("parse failed:", outcome.message)
			os.exit(1)
		}
		best = min(best, elapsed)
		worst = max(worst, elapsed)
		result, _ := v.value_as_map(outcome.value)
		if relation, relation_ok := v.value_as_relation(map_get(result, "nodes")); relation_ok {
			nodes = len(relation.rows)
		}
	}
	fmt.printf("bytes=%d facts=%d min=%v max=%v\n", len(source), nodes, best, worst)
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
