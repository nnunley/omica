// Loads OpenCyc KB5022 CycL dump into Mica relations.
//
// Usage:
//   odin run tools/cycl-load -- --store /tmp/bycycle-world apps/bycycle/00_schema.mica ../../../development/bycycle/data/kb5022.cycl
//
// The dump format is: (Mt formula :truth :direction :strength)
// Example: (#$BaseKB (#$isa #$Fido #$Dog) :TRUE :FORWARD :MONOTONIC)

package main

import "core:fmt"
import "core:os"
import "core:strings"
import "core:bufio"

import k "../../mica/kernel"
import r "../../mica/runtime"
import s "../../mica/store"
import cyc "../../mica/cycl"

@(private)
USAGE :: "usage: cycl-load [--store DIR] [--checkpoint] <schema.mica> <kb.cycl>\n"

main :: proc() {
	when ODIN_OS == .Darwin {
		context.temp_allocator = make_temp_allocator(4 * 1024 * 1024)
	}
	when ODIN_OS == .Linux {
		context.temp_allocator = make_temp_allocator(4 * 1024 * 1024)
	}
	
	// Parse arguments
	store_path := ""
	checkpoint := false
	schema_file := ""
	cycl_file := ""
	
	i := 1
	for i < len(os.args) {
		arg := os.args[i]
		switch arg {
		case "--store":
			i += 1
			if i < len(os.args) {
				store_path = os.args[i]
			}
		case "--checkpoint":
			checkpoint = true
		case:
			if strings.has_prefix(arg, "-") {
				fmt.printf(USAGE)
				os.exit(1)
			}
			if schema_file == "" {
				schema_file = arg
			} else if cycl_file == "" {
				cycl_file = arg
			}
		}
		i += 1
	}
	
	if schema_file == "" || cycl_file == "" {
		fmt.printf(USAGE)
		os.exit(1)
	}
	
	// Create/open store
	world: s.World
	if store_path != "" {
		world = s.open(store_path) or_else {
			fmt.panicf("failed to open store: %v\n", _)
		}
	} else {
		world = s.create_temporary()
	}
	defer s.close(world)
	
	// Load schema
	fmt.printf("Loading schema from %s...\n", schema_file)
	err := load_schema(world, schema_file)
	if err != nil {
		fmt.panicf("schema load error: %v\n", err)
	}
	
	// Load CycL dump
	fmt.printf("Loading CycL assertions from %s...\n", cycl_file)
	err = load_cycl(world, cycl_file)
	if err != nil {
		fmt.panicf("CycL load error: %v\n", err)
	}
	
	if checkpoint {
		fmt.printf("Checkpointing...\n")
		s.checkpoint(world) or_else {
			fmt.panicf("checkpoint error: %v\n", _)
		}
	}
	
	fmt.printf("Load complete.\n")
}

load_schema :: proc(world: s.World, path: string) -> (err: string) {
	data, ok := os.read_entire_file(path)
	if !ok {
		return "failed to read schema file"
	}
	defer delete(data)
	
	source := string(data)
	tx := r.transaction_create(world)
	defer r.transaction_close(tx)
	
	result := r.execute(tx, source, {.trace_execution = false})
	if result.error != nil {
		return fmt.aprintf("schema execution error: %s", result.error)
	}
	
	r.transaction_commit(tx) or_else {
		return fmt.aprintf("transaction commit failed: %v", _)
	}
	
	return nil
}

load_cycl :: proc(world: s.World, path: string) -> (err: string) {
	file, ok := os.open(path)
	if !ok {
		return "failed to open CycL file"
	}
	defer os.close(file)
	
	reader := bufio.reader_create(file, bufio.DEFAULT_BUF_SIZE)
	defer bufio.reader_destroy(&reader)
	
	line_num := 0
	assertion_count := 0
	
	for {
		line, err := bufio.reader_read_string(&reader, '\n')
		if err != nil && err != .EOF {
			return fmt.aprintf("read error at line %d: %v", line_num, err)
		}
		
		if len(line) == 0 {
			break
		}
		
		line_num += 1
		line = strings.trim_suffix(line, "\n")
		
		if len(strings.trim_space(line)) == 0 {
			continue
		}
		
		if assertion_count % 100000 == 0 {
			fmt.printf("Processed %d assertions at line %d...\n", assertion_count, line_num)
		}
		
		// Parse the line as a CycL assertion
		node, ok := cyc.parse(line)
		if !ok {
			fmt.printf("Warning: failed to parse line %d: %s\n", line_num, strings.truncate(line, 100))
			continue
		}
		
		list, is_list := node.(cyc.List)
		if !is_list || len(list.elements) != 5 {
			fmt.printf("Warning: expected 5 elements at line %d, got %d\n", line_num, len(list.elements) if is_list else 0)
			continue
		}
		
		mt := list.elements[0]
		formula := list.elements[1]
		truth := list.elements[2]
		_direction := list.elements[3]  // :FORWARD, :BACKWARD, :CODE
		_strength := list.elements[4]   // :MONOTONIC, :DEFAULT
		
		// Extract predicate and arguments from formula
		pred, args, ok := cyc.extract_formula(formula)
		if !ok {
			fmt.printf("Warning: failed to extract predicate from line %d\n", line_num)
			continue
		}
		
		// Route to appropriate relation based on predicate
		// For now, just count; later add transactional assert calls
		assertion_count += 1
		
		if assertion_count > 100 {
			break  // Temporary limit for testing
		}
	}
	
	fmt.printf("Loaded %d assertions total\n", assertion_count)
	return nil
}

make_temp_allocator :: proc(size: int) -> mem.Allocator {
	data := make([dynamic]u8, size)
	return mem.Allocator{
		procedure = proc(allocator_data: rawptr, mode: mem.Allocator_Mode, size, alignment: int, old_memory: rawptr) -> rawptr {
			// Stub for now
			return nil
		},
		data = raw_data(data),
	}
}

import "core:mem"
