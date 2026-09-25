// Load a sample of OpenCyc KB5022 into Mica for testing
//
// Usage:
//   odin run tools/cycl-load-sample -- --store /tmp/bycycle-sample apps/bycycle/00_schema.mica

package main

import "core:fmt"
import "core:os"
import "core:strings"
import "core:mem"

import r "../../mica/runtime"
import s "../../mica/store"
import cyc "../../mica/cycl"

main :: proc() {
	allocator := context.allocator
	
	// Parse arguments
	store_path := ""
	schema_file := ""
	
	i := 1
	for i < len(os.args) {
		arg := os.args[i]
		switch arg {
		case "--store":
			i += 1
			if i < len(os.args) {
				store_path = os.args[i]
			}
		case:
			if schema_file == "" {
				schema_file = arg
			}
		}
		i += 1
	}
	
	if schema_file == "" {
		fmt.printf("usage: cycl-load-sample --store DIR <schema.mica>\n")
		os.exit(1)
	}
	
	// Create store
	world := s.create_temporary()
	defer s.close(world)
	
	// Load schema
	fmt.printf("Loading schema from %s...\n", schema_file)
	schema_data, err := os.read_entire_file_from_path(schema_file, allocator)
	if err != nil {
		fmt.printf("Failed to read schema: %v\n", err)
		os.exit(1)
	}
	defer delete(schema_data)
	
	tx := r.transaction_create(world)
	result := r.execute(tx, string(schema_data), {.trace_execution = false})
	if result.error != nil {
		fmt.printf("Schema error: %s\n", result.error)
		os.exit(1)
	}
	r.transaction_commit(tx) or_else {
		fmt.printf("Commit error: %v\n", _)
		os.exit(1)
	}
	
	fmt.printf("Schema loaded successfully\n")
	
	// Generate sample Mica code that asserts some test facts
	mica_code := `
// Sample assertions for testing Mt-scoped queries
Isa(#$Fido, #$Dog, #$BaseKB)
Isa(#$Fido, #$Animal, #$BaseKB)
Isa(#$Alice, #$Dentist, #$PeopleDataMt)
Isa(#$Bob, #$Dentist, #$PeopleDataMt)
Isa(#$Charlie, #$Person, #$PeopleDataMt)
Genls(#$Dentist, #$Person, #$PeopleDataMt)
Genls(#$Person, #$Animal, #$BaseKB)
GenlMt(#$PeopleDataMt, #$BaseKB, #$BaseKB)
`
	
	fmt.printf("\nLoading sample assertions...\n")
	tx = r.transaction_create(world)
	result = r.execute(tx, mica_code, {.trace_execution = false})
	if result.error != nil {
		fmt.printf("Assertion error: %s\n", result.error)
	}
	r.transaction_commit(tx) or_else {
		fmt.printf("Commit error: %v\n", _)
		os.exit(1)
	}
	
	fmt.printf("Sample loaded. Schema ready for CycL dump loading.\n")
	fmt.printf("Next: parse kb5022.cycl and route assertions to relations.\n")
}
