// Loads the bycycle CycL schema into a Mica world with a few Mt-scoped sample
// facts, to try queries before the full KB5022 loader routes the dump.
//
// Usage:
//   odin run tools/cycl-load-sample -- [--store DIR] apps/bycycle/00_schema.mica
//
// Without --store the world is in memory; with it the world (and the facts)
// persist in DIR, which then opens with tools/filein or tools/repl.

package main

import "core:fmt"
import "core:os"
import "core:path/filepath"

import k "../../mica/kernel"
import r "../../mica/runtime"

USAGE :: "usage: cycl-load-sample [--store DIR] <schema.mica>\n"

// Sample facts in Mica syntax: identities first, then Mt-scoped assertions
// (the schema's relations take the microtheory as their last column).
SAMPLE :: `make_identity(:fido)
make_identity(:alice)
make_identity(:bob)
make_identity(:charlie)
make_identity(:dog)
make_identity(:animal)
make_identity(:dentist)
make_identity(:person)
make_identity(:base_kb)
make_identity(:people_data_mt)

assert Isa(#fido, #dog, #base_kb)
assert Isa(#fido, #animal, #base_kb)
assert Isa(#alice, #dentist, #people_data_mt)
assert Isa(#bob, #dentist, #people_data_mt)
assert Isa(#charlie, #person, #people_data_mt)
assert Genls(#dentist, #person, #people_data_mt)
assert Genls(#person, #animal, #base_kb)
`

main :: proc() {
	store_path := ""
	schema_file := ""
	for i := 1; i < len(os.args); i += 1 {
		switch arg := os.args[i]; arg {
		case "--store":
			i += 1
			if i < len(os.args) {
				store_path = os.args[i]
			}
		case "--help", "-h":
			fmt.print(USAGE)
			return
		case:
			schema_file = arg
		}
	}
	if schema_file == "" {
		fmt.eprint(USAGE)
		os.exit(1)
	}

	// The sample facts go through the ordinary filein path after the schema.
	directory, directory_error := os.temp_dir(context.allocator)
	if directory_error != nil {
		fmt.eprintln("cannot resolve a temporary directory")
		os.exit(1)
	}
	sample_path, _ := filepath.join([]string{directory, "cycl-load-sample.mica"}, context.allocator)
	if err := os.write_entire_file(sample_path, transmute([]u8)string(SAMPLE)); err != nil {
		fmt.eprintf("cannot write %s\n", sample_path)
		os.exit(1)
	}
	defer os.remove(sample_path)

	kernel: k.Kernel
	k.kernel_init(&kernel)
	defer k.kernel_destroy(&kernel)
	world, start := r.world_start(
		&kernel,
		[]string{schema_file, sample_path},
		context.allocator,
		r.World_Config{store_path = store_path},
	)
	if !start.ok {
		fmt.eprintf("load failed: %s\n", start.message)
		os.exit(1)
	}
	defer r.world_destroy(world)
	if entry := r.world_wait(world, world.entry); entry.kind != .Complete {
		fmt.eprintf("sample facts failed: %s\n", entry.message)
		os.exit(1)
	}
	if store_path != "" && !r.world_checkpoint(world) {
		fmt.eprintf("checkpoint of %s failed\n", store_path)
		os.exit(1)
	}
	fmt.printf("schema %s and 7 sample facts loaded%s\n", schema_file, store_path == "" ? "" : fmt.tprintf(" into %s", store_path))
}
