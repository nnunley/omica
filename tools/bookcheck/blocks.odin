package bookcheck

import "core:mem"
import "core:strings"

// How a fenced Mica example is checked, following the Rust book harness
// (crates/runtime/tests/book_examples.rs): ```mica must parse, ```mica,eval
// runs as one task that must complete, and ```mica,filein loads as a file.
Mode :: enum {
	Parse,
	Eval,
	Filein,
}

Block :: struct {
	line:   int, // line of the opening fence, 1-based
	mode:   Mode,
	source: string,
}

// Returns the Mica blocks in `markdown`. Reports false when a Mica fence is
// never closed.
extract_blocks :: proc(markdown: string, allocator: mem.Allocator) -> ([dynamic]Block, bool) {
	blocks := make([dynamic]Block, allocator)
	source := strings.builder_make(allocator)
	open := false
	current: Block
	rest := markdown
	line := 0
	for text in strings.split_lines_iterator(&rest) {
		line += 1
		if strings.has_prefix(text, "```") {
			info := text[3:]
			if open {
				current.source = strings.clone(strings.to_string(source), allocator)
				append(&blocks, current)
				open = false
				continue
			}
			mode, is_mica := block_mode(info)
			if is_mica {
				current = Block{line = line, mode = mode}
				strings.builder_reset(&source)
				open = true
			}
			continue
		}
		if open {
			strings.write_string(&source, text)
			strings.write_byte(&source, '\n')
		}
	}
	return blocks, !open
}

@(private)
block_mode :: proc(info: string) -> (Mode, bool) {
	switch info {
	case "mica":
		return .Parse, true
	case "mica,eval":
		return .Eval, true
	case "mica,filein":
		return .Filein, true
	}
	return .Parse, false
}
