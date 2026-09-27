// Runs the Mica examples in a book, like the Rust book harness does.
//
//	odin run tools/bookcheck -- [--known FILE] mdbook/src
//
// Every ```mica block must parse. Every ```mica,eval and ```mica,filein block
// is loaded into a fresh world, and its top-level code must complete. A failing
// `require` aborts the task, so book examples assert their own results.
//
// The known-failures file lists `path:line` of examples omica does not pass
// yet, relative to the book directory. The run fails on a failure that is not
// listed, and on a listed example that now passes, so the list only shrinks.
package bookcheck

import "base:runtime"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"
import c "../../mica/compiler"
import k "../../mica/kernel"
import r "../../mica/runtime"
import v "../../mica/var"

USAGE :: "usage: bookcheck [--known FILE] <book-src-dir>\n"

main :: proc() {
	known_path := ""
	book := ""
	args := os.args[1:]
	for i := 0; i < len(args); i += 1 {
		switch {
		case args[i] == "--known" && i + 1 < len(args):
			i += 1
			known_path = args[i]
		case book == "":
			book = args[i]
		case:
			fmt.eprintf(USAGE)
			os.exit(2)
		}
	}
	if book == "" {
		fmt.eprintf(USAGE)
		os.exit(2)
	}

	known := make(map[string]bool)
	if known_path != "" {
		data, read_err := os.read_entire_file(known_path, context.allocator)
		if read_err != nil {
			fmt.eprintf("cannot read %s\n", known_path)
			os.exit(2)
		}
		text := string(data)
		for line in strings.split_lines_iterator(&text) {
			entry := strings.trim_space(line)
			if entry != "" && !strings.has_prefix(entry, "#") {
				known[entry] = true
			}
		}
	}

	// Directory entries come back as absolute paths, so the book root must be
	// absolute too for locations to be relative to it.
	root, abs_err := filepath.abs(book, context.allocator)
	if abs_err != nil {
		fmt.eprintf("cannot resolve %s\n", book)
		os.exit(2)
	}
	files := make([dynamic]string)
	collect_markdown(root, &files)
	slice.sort(files[:])

	scratch, dir_err := os.temp_dir(context.allocator)
	if dir_err != nil {
		fmt.eprintf("cannot resolve a temporary directory\n")
		os.exit(2)
	}
	scratch_file := fmt.aprintf("%s/bookcheck-%d.mica", scratch, os.get_pid())
	defer os.remove(scratch_file)

	checked, passed := 0, 0
	unexpected, stale := 0, 0
	for path in files {
		relative, rel_err := filepath.rel(root, path, context.allocator)
		if rel_err != .None {
			fmt.eprintf("cannot relate %s to %s\n", path, root)
			os.exit(2)
		}
		data, read_err := os.read_entire_file(path, context.allocator)
		if read_err != nil {
			fmt.eprintf("cannot read %s\n", path)
			os.exit(2)
		}
		blocks, closed := extract_blocks(string(data), context.allocator)
		if !closed {
			fmt.printf("FAIL %s: unclosed Mica code fence\n", relative)
			unexpected += 1
		}
		for block in blocks {
			location := fmt.aprintf("%s:%d", relative, block.line)
			checked += 1
			message, ok := check_block(block, scratch_file)
			is_known := known[location]
			switch {
			case ok && is_known:
				fmt.printf("STALE %s: passes now; remove it from the known failures\n", location)
				stale += 1
			case ok:
				passed += 1
			case is_known:
				fmt.printf("known %s: %s\n", location, message)
			case:
				fmt.printf("FAIL %s: %s\n", location, message)
				unexpected += 1
			}
			free_all(context.temp_allocator)
		}
	}
	fmt.printf(
		"bookcheck: %d examples, %d pass, %d known failures, %d unexpected failures, %d stale\n",
		checked,
		passed,
		checked - passed - unexpected - stale,
		unexpected,
		stale,
	)
	if unexpected > 0 || stale > 0 {
		os.exit(1)
	}
}

@(private)
collect_markdown :: proc(directory: string, files: ^[dynamic]string) {
	handle, open_err := os.open(directory)
	if open_err != nil {
		fmt.eprintf("cannot open %s\n", directory)
		os.exit(2)
	}
	defer os.close(handle)
	entries, read_err := os.read_dir(handle, -1, context.allocator)
	if read_err != nil {
		fmt.eprintf("cannot read %s\n", directory)
		os.exit(2)
	}
	for entry in entries {
		if entry.type == .Directory {
			collect_markdown(entry.fullpath, files)
		} else if strings.has_suffix(entry.name, ".md") {
			append(files, entry.fullpath)
		}
	}
}

// Parses the block, and for eval and filein blocks runs it in a fresh world.
@(private)
check_block :: proc(block: Block, scratch_file: string) -> (string, bool) {
	_, errors := c.parse_program(block.source, context.temp_allocator)
	if len(errors) > 0 {
		return fmt.tprintf("parse: %s", errors[0].message), false
	}
	if block.mode == .Parse {
		return "", true
	}
	if write_err := os.write_entire_file(scratch_file, transmute([]u8)block.source); write_err != nil {
		return "cannot write the example to a temporary file", false
	}
	kernel: k.Kernel
	k.kernel_init(&kernel)
	defer k.kernel_destroy(&kernel)
	// World threads share this allocator, so it must be thread-safe.
	world, start := r.world_start(&kernel, []string{scratch_file}, runtime.heap_allocator())
	if !start.ok {
		return fmt.tprintf("load: %s", start.message), false
	}
	defer r.world_destroy(world)
	if world.entry == 0 {
		return "", true
	}
	outcome := r.world_wait(world, world.entry)
	if outcome.kind != .Complete {
		return fmt.tprintf("%v: %s", outcome.kind, outcome_detail(outcome)), false
	}
	return "", true
}

@(private)
outcome_detail :: proc(outcome: r.Task_Outcome) -> string {
	if header, is_error := v.value_as_error(outcome.error); is_error {
		code, _ := v.symbol_name(header.code)
		if header.has_message && header.message != "" {
			return fmt.tprintf("%s: %s", code, header.message)
		}
		return code
	}
	return outcome.message
}
