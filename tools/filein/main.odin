// Runs Mica fileins against an in-memory kernel.
//
// Usage:
//
//	odin run tools/filein -- apps/shared/capabilities.mica
package main

import "core:fmt"
import "core:os"

import k "../../mica/kernel"
import r "../../mica/runtime"

main :: proc() {
	if len(os.args) < 2 {
		fmt.eprintln("usage: filein <path>...")
		os.exit(1)
	}

	kernel: k.Kernel
	k.kernel_init(&kernel)
	defer k.kernel_destroy(&kernel)

	result := r.run_files(&kernel, os.args[1:])
	if result.ok {
		for path in os.args[1:] {
			fmt.printf("loaded %s\n", path)
		}
	} else {
		fmt.eprintf("failed: %s\n", result.message)
		os.exit(1)
	}
}
