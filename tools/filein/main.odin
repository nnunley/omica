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

main :: proc() {
	unit := ""
	paths: [dynamic]string
	defer delete(paths)
	arguments := os.args[1:]
	for index := 0; index < len(arguments); index += 1 {
		if arguments[index] == "--unit" {
			if index + 1 >= len(arguments) {
				fmt.eprintln("usage: filein [--unit NAME] <path>...")
				os.exit(1)
			}
			unit = arguments[index + 1]
			index += 1
			continue
		}
		append(&paths, arguments[index])
	}
	if len(paths) == 0 {
		fmt.eprintln("usage: filein [--unit NAME] <path>...")
		os.exit(1)
	}

	kernel: k.Kernel
	k.kernel_init(&kernel)
	defer k.kernel_destroy(&kernel)

	result := r.run_files(&kernel, paths[:], context.allocator, r.Run_Options{unit = unit})
	if result.ok {
		for path in paths {
			fmt.printf("loaded %s\n", path)
		}
	} else {
		fmt.eprintf("failed: %s\n", result.message)
		os.exit(1)
	}
}
