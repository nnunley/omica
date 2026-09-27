package bookcheck

import "core:testing"

@(test)
test_extract_blocks_modes_and_lines :: proc(t: ^testing.T) {
	markdown := "# Title\n" +
		"```mica\n" +
		"let a = 1\n" +
		"```\n" +
		"text\n" +
		"```mica,eval\n" +
		"require 1 == 1\n" +
		"```\n" +
		"```rust\n" +
		"fn main() {}\n" +
		"```\n" +
		"```mica,filein\n" +
		"make_relation(:R, 1)\n" +
		"```\n"
	blocks, ok := extract_blocks(markdown, context.temp_allocator)
	defer free_all(context.temp_allocator)
	testing.expect(t, ok)
	testing.expect_value(t, len(blocks), 3)
	if len(blocks) != 3 {
		return
	}
	testing.expect_value(t, blocks[0].mode, Mode.Parse)
	testing.expect_value(t, blocks[0].line, 2)
	testing.expect_value(t, blocks[0].source, "let a = 1\n")
	testing.expect_value(t, blocks[1].mode, Mode.Eval)
	testing.expect_value(t, blocks[1].line, 6)
	testing.expect_value(t, blocks[1].source, "require 1 == 1\n")
	testing.expect_value(t, blocks[2].mode, Mode.Filein)
	testing.expect_value(t, blocks[2].line, 12)
}

@(test)
test_extract_blocks_reports_unclosed_fence :: proc(t: ^testing.T) {
	_, ok := extract_blocks("```mica,eval\nrequire true\n", context.temp_allocator)
	defer free_all(context.temp_allocator)
	testing.expect(t, !ok)
}
