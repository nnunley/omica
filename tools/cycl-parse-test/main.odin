// Test parser for CycL s-expressions - show failures
package main

import "core:fmt"
import "core:os"
import "core:strings"

import cyc "../../mica/cycl"

main :: proc() {
	allocator := context.allocator
	
	if len(os.args) < 2 {
		fmt.printf("usage: cycl-parse-test <kb.cycl>\n")
		os.exit(1)
	}
	
	path := os.args[1]
	data, err := os.read_entire_file_from_path(path, allocator)
	if err != nil {
		fmt.printf("Failed to read %s: %v\n", path, err)
		os.exit(1)
	}
	defer delete(data)
	
	content := string(data)
	lines := strings.split(content, "\n", allocator)
	defer delete(lines)
	
	fail_count := 0
	
	for i := 0; i < len(lines); i += 1 {
		line := lines[i]
		
		if len(strings.trim_space(line)) == 0 {
			continue
		}
		
		node, ok := cyc.parse(line, allocator)
		if !ok {
			fail_count += 1
			if fail_count <= 20 {
				// Show first 150 chars
				display_line := line
				if len(line) > 150 {
					display_line = line[:150]
				}
				fmt.printf("Line %d FAIL: %s\n", i+1, display_line)
			}
		}
	}
	
	fmt.printf("Total failures: %d\n", fail_count)
}
