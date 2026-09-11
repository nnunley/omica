package compiler

import "core:mem/virtual"
import "core:os"
import "core:strings"
import "core:testing"

// Parses every `.mica` file under the sibling mica corpus when it is present.
// Set `MICA_CORPUS` to point at a different corpus. The test passes when no
// corpus is available so the package remains self-contained.
@(test)
test_parse_corpus :: proc(t: ^testing.T) {
	corpus := corpus_directory()
	if corpus == "" {
		return
	}

	walker := os.walker_create_path(corpus)
	defer os.walker_destroy(&walker)

	file_count := 0
	failures := 0
	for info in os.walker_walk(&walker) {
		if _, walk_err := os.walker_error(&walker); walk_err != nil {
			continue
		}
		if info.type != .Regular || !strings.has_suffix(info.name, ".mica") {
			continue
		}

		arena: virtual.Arena
		if err := virtual.arena_init_growing(&arena); err != nil {
			panic("failed to initialize corpus arena")
		}
		allocator := virtual.arena_allocator(&arena)
		data, read_err := os.read_entire_file(info.fullpath, allocator)
		if read_err != nil {
			failures += 1
			testing.expectf(t, false, "could not read %s: %v", info.fullpath, read_err)
			virtual.arena_destroy(&arena)
			continue
		}

		file_count += 1
		_, errors := parse_program(string(data), allocator)
		if len(errors) > 0 {
			failures += 1
			for parse_error in errors {
				testing.expectf(
					t,
					false,
					"%s:%d:%d: %s",
					info.fullpath,
					parse_error.line,
					parse_error.column,
					parse_error.message,
				)
			}
		}
		virtual.arena_destroy(&arena)
	}

	testing.expectf(t, file_count > 0, "no .mica files found under %s", corpus)
	testing.expectf(t, failures == 0, "%d of %d corpus files failed to parse", failures, file_count)
}
