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

@(test)
test_extract_blocks_attributes_and_expect :: proc(t: ^testing.T) {
	markdown := "```mica mode=eval when=impl:omica @R-len\n" +
		"return len(\"héllo\")\n" +
		"```\n" +
		"\n" +
		"```expect\n" +
		"5\n" +
		"```\n" +
		"```mica mode=filein\n" +
		"make_relation(:R, 1)\n" +
		"```\n" +
		"```expect-error\n" +
		"E_INDEX\n" +
		"```\n"
	blocks, ok := extract_blocks(markdown, context.temp_allocator)
	defer free_all(context.temp_allocator)
	testing.expect(t, ok)
	testing.expect_value(t, len(blocks), 2)
	if len(blocks) != 2 {
		return
	}
	testing.expect_value(t, blocks[0].mode, Mode.Eval)
	testing.expect_value(t, blocks[0].condition, "impl:omica")
	testing.expect_value(t, blocks[0].expect, "5\n")
	testing.expect(t, blocks[0].has_expect)
	testing.expect_value(t, blocks[1].mode, Mode.Filein)
	testing.expect_value(t, blocks[1].expect_error, "E_INDEX\n")
	testing.expect(t, blocks[1].has_expect_error)
}

@(test)
test_when_matches_profile :: proc(t: ^testing.T) {
	profile := make(map[string]string)
	defer delete(profile)
	profile["impl"] = "omica"
	testing.expect(t, when_holds("", profile))
	testing.expect(t, when_holds("impl:omica", profile))
	testing.expect(t, !when_holds("impl:rust", profile))
	testing.expect(t, !when_holds("impl:omica,os:linux", profile))
}
