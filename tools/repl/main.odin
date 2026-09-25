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
import "core:time"

import ext "../../mica/external"
import k "../../mica/kernel"
import r "../../mica/runtime"
import s "../../mica/store"
import v "../../mica/var"

@(private)
USAGE :: "usage: repl [--store DIR] [--durability none|group|strict] " +
	"[--accel " + r.ACCEL_MODE_NAMES + "] " +
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

// Runs a submitted eval to completion, supplying lines typed at the prompt
// when the task parks on `read`.
@(private)
drive_task :: proc(world: ^r.World, id: r.Task_ID, reader: ^bufio.Reader) {
	for {
		outcome, observed := r.world_task_outcome(world, id)
		if !observed {
			time.sleep(2 * time.Millisecond)
			continue
		}
		switch outcome.kind {
		case .Complete, .Aborted:
			print_outcome(world, outcome)
			r.world_release(world, id)
			return
		case .Pending:
			if outcome.suspend != r.Task_Suspend.Host_Request {
				time.sleep(5 * time.Millisecond)
				continue
			}
			metadata, has_request := r.world_task_request(world, id)
			label := ""
			if has_request {
				if symbol, is_symbol := v.value_as_symbol(metadata); is_symbol {
					if name, has_name := v.symbol_name(symbol); has_name {
						label = name
					}
				}
			}
			if label != "" {
				fmt.printf("read(%s)> ", label)
			} else {
				fmt.printf("read> ")
			}
			line, read_error := bufio.reader_read_string(
				reader,
				'\n',
				context.temp_allocator,
			)
			if read_error != nil {
				fmt.println()
				fmt.println("input closed; task left suspended")
				return
			}
			input := strings.trim_right(line, "\r\n")
			if !r.world_resume(world, id, v.value_string(world.allocator, input)) {
				fmt.eprintln("could not deliver input")
				return
			}
		}
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
	accel_mode := r.Accel_Mode.Unchanged
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
		case "--accel":
			if index + 1 >= len(arguments) {
				fmt.eprintf(USAGE)
				os.exit(1)
			}
			index += 1
			mode, ok := r.accel_mode_parse(arguments[index])
			if !ok {
				fmt.eprintf("--accel: expected %s, got %q\n%s", r.ACCEL_MODE_NAMES, arguments[index], USAGE)
				os.exit(1)
			}
			accel_mode = mode
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
			actor            = actor,
			store_path       = store_path,
			durability       = durability,
			external_handler = ext.handle_request,
			external_workers = 2,
			accel            = accel_mode,
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
		id, failure, submitted := r.world_eval_submit(world, source)
		if !submitted {
			print_outcome(world, failure)
			continue
		}
		drive_task(world, id, &reader)
	}

	r.world_destroy(world)
}
