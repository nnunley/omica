// Interactive evaluation against a live world.
//
// Usage:
//
//	odin run tools/repl -- --store DIR [--actor NAME] [--durability MODE]
//	odin run tools/repl -- path/to/filein.mica
package main

import "core:bufio"
import "core:fmt"
import "core:os"
import "core:strings"

import k "../../mica/kernel"
import r "../../mica/runtime"
import s "../../mica/store"
import v "../../mica/var"

@(private)
USAGE :: "usage: repl [--store DIR] [--durability none|group|strict] " +
	"[--actor NAME] [--checkpoint] <path>...\n"

@(private)
parse_durability :: proc(text: string) -> s.Durability {
	switch text {
	case "none":
		return .None
	case "strict":
		return .Strict
	}
	return .Group
}

@(private)
print_outcome :: proc(world: ^r.World, outcome: r.Task_Outcome) {
	switch outcome.kind {
	case .Complete:
		text := r.world_value_literal(world, outcome.value)
		defer delete(text, context.allocator)
		fmt.println(text)
	case .Aborted:
		detail := outcome.message
		if header, is_error := v.value_as_error(outcome.error); is_error {
			code, _ := v.symbol_name(header.code)
			if header.has_message && header.message != "" {
				detail = header.message
				if code != "" {
					detail = fmt.aprintf("%s: %s", code, header.message)
				}
			} else if code != "" {
				detail = code
			}
		}
		fmt.eprintf("aborted: %s\n", detail)
	case .Pending:
		fmt.eprintf("aborted: task did not finish (%s)\n", outcome.message)
	}
}

@(private)
print_help :: proc() {
	fmt.println("  :help        show this help")
	fmt.println("  :checkpoint  write a store checkpoint")
	fmt.println("  :quit        leave the REPL")
	fmt.println("  anything else is compiled and evaluated against the world")
}

main :: proc() {
	store_path := ""
	actor := ""
	checkpoint := false
	durability := s.Durability.Group
	paths: [dynamic]string
	defer delete(paths)

	arguments := os.args[1:]
	for index := 0; index < len(arguments); index += 1 {
		switch arguments[index] {
		case "--store":
			if index + 1 >= len(arguments) {
				fmt.eprintf(USAGE)
				os.exit(1)
			}
			index += 1
			store_path = arguments[index]
		case "--durability":
			if index + 1 >= len(arguments) {
				fmt.eprintf(USAGE)
				os.exit(1)
			}
			index += 1
			durability = parse_durability(arguments[index])
		case "--actor":
			if index + 1 >= len(arguments) {
				fmt.eprintf(USAGE)
				os.exit(1)
			}
			index += 1
			actor = arguments[index]
		case "--checkpoint":
			checkpoint = true
		case "--help", "-h":
			fmt.printf(USAGE)
			return
		case:
			append(&paths, arguments[index])
		}
	}

	kernel: k.Kernel
	k.kernel_init(&kernel)
	defer k.kernel_destroy(&kernel)

	world, start := r.world_start(
		&kernel,
		paths[:],
		context.allocator,
		r.World_Config {
			actor      = actor,
			store_path = store_path,
			durability = durability,
		},
	)
	if !start.ok {
		fmt.eprintf("failed: %s\n", start.message)
		os.exit(1)
	}
	if world.entry != 0 {
		outcome := r.world_wait(world, world.entry)
		if outcome.kind != .Complete {
			print_outcome(world, outcome)
			r.world_destroy(world)
			os.exit(1)
		}
	}
	if checkpoint && !r.world_checkpoint(world) {
		fmt.eprintf("failed: checkpoint failed\n")
		r.world_destroy(world)
		os.exit(1)
	}

	reader: bufio.Reader
	bufio.reader_init(&reader, os.to_reader(os.stdin))
	defer bufio.reader_destroy(&reader)

	fmt.println("Mica REPL. Type :help for commands, :quit to exit.")
	for {
		fmt.printf("mica> ")
		line, read_error := bufio.reader_read_string(
			&reader,
			'\n',
			context.temp_allocator,
		)
		if read_error != nil {
			fmt.println()
			break
		}
		source := strings.trim_space(line)
		if source == "" {
			continue
		}
		if source == ":quit" || source == ":exit" {
			break
		}
		if source == ":help" {
			print_help()
			continue
		}
		if source == ":checkpoint" {
			if r.world_checkpoint(world) {
				fmt.println("checkpoint written")
			} else {
				fmt.println("no store attached")
			}
			continue
		}
		print_outcome(world, r.world_eval(world, source))
	}

	r.world_destroy(world)
}
