// Reads an OpenCyc KB5022 CycL dump against the bycycle CycL schema.
//
// Usage:
//   odin run tools/cycl-load -- [--store DIR] [--limit N] apps/bycycle/00_schema.mica kb5022.cycl
//
// The dump has one assertion per line: (Mt formula truth direction strength),
// e.g. (#$BaseKB (#$isa #$Fido #$Dog) :TRUE :FORWARD :MONOTONIC).
//
// Status: the schema loads into a real Mica world (in memory, or persisted
// in DIR with --store), and every dump line is parsed and counted per
// predicate. Routing assertions into the schema's relations (constant names
// to identities, non-atomic terms, microtheories) is the next step; until
// then this tool asserts nothing from the dump.

package main

import "core:bufio"
import "core:fmt"
import "core:os"
import "core:slice"
import "core:strconv"
import "core:strings"

import k "../../mica/kernel"
import r "../../mica/runtime"
import cyc "../../mica/cycl"

USAGE :: "usage: cycl-load [--store DIR] [--limit N] <schema.mica> <kb.cycl>\n"

main :: proc() {
	store_path := ""
	limit := 0
	files: [dynamic]string
	defer delete(files)
	for i := 1; i < len(os.args); i += 1 {
		switch arg := os.args[i]; arg {
		case "--store":
			i += 1
			if i < len(os.args) {
				store_path = os.args[i]
			}
		case "--limit":
			i += 1
			if i < len(os.args) {
				limit, _ = strconv.parse_int(os.args[i])
			}
		case "--help", "-h":
			fmt.print(USAGE)
			return
		case:
			if strings.has_prefix(arg, "-") {
				fmt.eprint(USAGE)
				os.exit(1)
			}
			append(&files, arg)
		}
	}
	if len(files) != 2 {
		fmt.eprint(USAGE)
		os.exit(1)
	}
	schema_file, cycl_file := files[0], files[1]

	kernel: k.Kernel
	k.kernel_init(&kernel)
	defer k.kernel_destroy(&kernel)
	world, start := r.world_start(
		&kernel,
		[]string{schema_file},
		context.allocator,
		r.World_Config{store_path = store_path},
	)
	if !start.ok {
		fmt.eprintf("schema load failed: %s\n", start.message)
		os.exit(1)
	}
	defer r.world_destroy(world)
	if entry := r.world_wait(world, world.entry); entry.kind != .Complete {
		fmt.eprintf("schema failed: %s\n", entry.message)
		os.exit(1)
	}
	fmt.printf("schema %s loaded\n", schema_file)

	if !read_dump(cycl_file, limit) {
		os.exit(1)
	}
}

// Parses every assertion line and reports how many there are per predicate.
read_dump :: proc(path: string, limit: int) -> bool {
	file, open_error := os.open(path)
	if open_error != nil {
		fmt.eprintf("cannot open %s: %v\n", path, open_error)
		return false
	}
	defer os.close(file)
	reader: bufio.Reader
	bufio.reader_init(&reader, os.to_stream(file))
	defer bufio.reader_destroy(&reader)

	counts := make(map[string]int)
	defer delete(counts)
	assertions, failures, line_number := 0, 0, 0
	for limit <= 0 || assertions < limit {
		line, read_error := bufio.reader_read_string(&reader, '\n', context.temp_allocator)
		if len(line) == 0 && read_error != nil {
			break
		}
		line_number += 1
		text := strings.trim_space(line)
		if len(text) == 0 {
			continue
		}
		node, parsed := cyc.parse(text, context.temp_allocator)
		list, is_list := node.(cyc.List)
		if !parsed || !is_list || len(list.elements) != 5 {
			failures += 1
			continue
		}
		predicate, _, is_formula := cyc.extract_formula(list.elements[1])
		if !is_formula {
			failures += 1
			continue
		}
		name := string(predicate)
		if name in counts {
			counts[name] += 1
		} else {
			counts[strings.clone(name)] = 1
		}
		assertions += 1
		if assertions % 100_000 == 0 {
			fmt.printf("  ... %d assertions (line %d)\n", assertions, line_number)
			free_all(context.temp_allocator)
		}
	}

	names := make([dynamic]string, 0, len(counts), context.temp_allocator)
	for name in counts {
		append(&names, name)
	}
	slice.sort_by(names[:], proc(a, b: string) -> bool {return a < b})
	fmt.printf("%d assertions parsed, %d lines skipped; %d predicates:\n", assertions, failures, len(names))
	for name in names {
		fmt.printf("%d\t%s\n", counts[name], name)
	}
	for name in names {
		delete(name)
	}
	fmt.println("routing into relations is not implemented yet: nothing was asserted from the dump")
	return true
}
