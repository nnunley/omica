package compiler

import "core:mem/virtual"
import "core:os"
import "core:strings"
import "core:testing"

// Lexes every `.mica` file under the sibling mica corpus when it is present.
// Set `MICA_CORPUS` to point at a different corpus. The test passes when no
// corpus is available so the package remains self-contained.
@(test)
test_lex_corpus :: proc(t: ^testing.T) {
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
		result := lex(string(data), allocator)
		if len(result.errors) > 0 {
			failures += 1
			for lex_error in result.errors {
				testing.expectf(
					t,
					false,
					"%s:%d:%d: %s",
					info.fullpath,
					lex_error.line,
					lex_error.column,
					lex_error.message,
				)
			}
		}
		for token in result.tokens {
			if token.kind != .Error {
				continue
			}
			// Non-ASCII error tokens are allowed; they are raw DOM text
			// that the parser handles. ASCII junk is always a failure.
			ascii := true
			for index in 0 ..< len(token.text) {
				if token.text[index] >= 0x80 {
					ascii = false
					break
				}
			}
			if ascii {
				failures += 1
				testing.expectf(
					t,
					false,
					"%s:%d:%d: error token %q",
					info.fullpath,
					token.line,
					token.column,
					token.text,
				)
			}
		}
		virtual.arena_destroy(&arena)
	}

	testing.expectf(t, file_count > 0, "no .mica files found under %s", corpus)
	testing.expectf(t, failures == 0, "%d failures across %d corpus files", failures, file_count)
}

@(private)
corpus_directory :: proc() -> string {
	if configured := os.get_env("MICA_CORPUS", context.temp_allocator); configured != "" {
		if os.is_dir(configured) {
			return configured
		}
	}
	candidates := []string{"../mica/apps", "../../mica/apps", "../../../mica/apps"}
	for candidate in candidates {
		if os.is_dir(candidate) {
			return candidate
		}
	}
	return ""
}
