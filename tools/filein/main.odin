// Runs Mica fileins against an in-memory kernel.
//
// Usage:
//
//	odin run tools/filein -- apps/shared/capabilities.mica
//	odin run tools/filein -- --unit equipment apps/examples/equipment-service.mica
package main

import "core:fmt"
import "core:os"

import k "../../mica/kernel"
import r "../../mica/runtime"
import s "../../mica/store"

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

main :: proc() {
	unit := ""
	store_path := ""
	checkpoint := false
	durability := s.Durability.Group
	paths: [dynamic]string
	defer delete(paths)
	arguments := os.args[1:]
	for index := 0; index < len(arguments); index += 1 {
		if arguments[index] == "--unit" {
			if index + 1 >= len(arguments) {
				fmt.eprintln("usage: filein [--unit NAME] [--store DIR] <path>...")
				os.exit(1)
			}
			unit = arguments[index + 1]
			index += 1
			continue
		}
		if arguments[index] == "--checkpoint" {
			checkpoint = true
			continue
		}
		if arguments[index] == "--durability" {
			if index + 1 >= len(arguments) {
				fmt.eprintln("usage: filein [--unit NAME] [--store DIR] [--durability none|group|strict] <path>...")
				os.exit(1)
			}
			durability = parse_durability(arguments[index + 1])
			index += 1
			continue
		}
		if arguments[index] == "--store" {
			if index + 1 >= len(arguments) {
				fmt.eprintln("usage: filein [--unit NAME] [--store DIR] <path>...")
				os.exit(1)
			}
			store_path = arguments[index + 1]
			index += 1
			continue
		}
		append(&paths, arguments[index])
	}
	if len(paths) == 0 && store_path == "" {
		fmt.eprintln("usage: filein [--unit NAME] [--store DIR] <path>...")
		os.exit(1)
	}

	kernel: k.Kernel
	k.kernel_init(&kernel)
	defer k.kernel_destroy(&kernel)

	world, start := r.world_start(
		&kernel,
		paths[:],
		context.allocator,
		r.World_Config {
			unit       = unit,
			store_path = store_path,
			durability = durability,
		},
	)
	if !start.ok {
		fmt.eprintf("failed: %s\n", start.message)
		os.exit(1)
	}
	result := r.Run_Result{ok = true, message = start.message}
	if world.entry != 0 {
		outcome := r.world_wait(world, world.entry)
		if outcome.kind != .Complete {
			result = r.Run_Result{ok = false, message = outcome.message}
		}
	}
	if checkpoint && !r.world_checkpoint(world) {
		result = r.Run_Result{ok = false, message = "checkpoint failed"}
	}
	r.world_destroy(world)
	if result.ok {
		for path in paths {
			fmt.printf("loaded %s\n", path)
		}
	} else {
		fmt.eprintf("failed: %s\n", result.message)
		os.exit(1)
	}
}
