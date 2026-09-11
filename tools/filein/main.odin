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

	failed := false
	for path in os.args[1:] {
		result := r.run_filein(&kernel, path)
		if result.ok {
			fmt.printf("loaded %s\n", path)
		} else {
			fmt.eprintf("failed %s: %s\n", path, result.message)
			failed = true
		}
	}
	if failed {
		os.exit(1)
	}
}
