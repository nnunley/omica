// Parses every .mica file in a corpus and prints a diagnostics report.
//
// Usage:
//
//	odin run tools/parse_corpus -- [corpus-directory]
//
// The default directory is ../mica/apps. The report lists per-file errors with
// the offending source line and a summary of diagnostic messages, which is the
// working gap list for the parser.
package main

import "core:fmt"
import "core:mem/virtual"
import "core:os"
import "core:slice"
import "core:strings"

import compiler "../../mica/compiler"

MAX_ERRORS_PER_FILE :: 6

@(private)
sort_by_count :: proc(a, b: Error_Group) -> bool {
	return a.count > b.count || (a.count == b.count && a.message < b.message)
}

Error_Group :: struct {
	message: string,
	count:   int,
}

main :: proc() {
	corpus := "../mica/apps"
	if len(os.args) > 1 {
		corpus = os.args[1]
	}
	if !os.is_dir(corpus) {
		fmt.eprintf("not a directory: %s\n", corpus)
		os.exit(1)
	}

	walker := os.walker_create_path(corpus)
	defer os.walker_destroy(&walker)

	file_count := 0
	clean_files := 0
	error_files := 0
	error_count := 0

	groups: [dynamic]Error_Group
	group_index := make(map[string]int)

	for info in os.walker_walk(&walker) {
		if _, walk_err := os.walker_error(&walker); walk_err != nil {
			continue
		}
		if info.type != .Regular || !strings.has_suffix(info.name, ".mica") {
			continue
		}

		arena: virtual.Arena
		if err := virtual.arena_init_growing(&arena); err != nil {
			panic("failed to initialize arena")
		}
		allocator := virtual.arena_allocator(&arena)
		data, read_err := os.read_entire_file(info.fullpath, allocator)
		if read_err != nil {
			fmt.eprintf("could not read %s\n", info.fullpath)
			virtual.arena_destroy(&arena)
			continue
		}

		file_count += 1
		source := string(data)
		_, errors := compiler.parse_program(source, allocator)
		if len(errors) == 0 {
			clean_files += 1
			virtual.arena_destroy(&arena)
			continue
		}

		error_files += 1
		error_count += len(errors)
		display := strings.trim_prefix(info.fullpath, corpus)
		fmt.printf("\n== %s (%d errors)\n", display, len(errors))
		lines := strings.split_lines(source, allocator)
		for parse_error, index in errors {
			if index >= MAX_ERRORS_PER_FILE {
				fmt.printf("   ... %d more\n", len(errors) - MAX_ERRORS_PER_FILE)
				break
			}
			snippet := ""
			if parse_error.line >= 1 && parse_error.line <= len(lines) {
				snippet = strings.trim_space(lines[parse_error.line - 1])
				if len(snippet) > 96 {
					snippet = snippet[:96]
				}
			}
			fmt.printf(
				"   %d:%d %s | %s\n",
				parse_error.line,
				parse_error.column,
				parse_error.message,
				snippet,
			)
		}

		for parse_error in errors {
			if index, found := group_index[parse_error.message]; found {
				groups[index].count += 1
			} else {
				group_index[parse_error.message] = len(groups)
				append(&groups, Error_Group{message = parse_error.message, count = 1})
			}
		}
		virtual.arena_destroy(&arena)
	}

	fmt.printf(
		"\nparsed %d files: %d clean, %d with errors, %d errors\n",
		file_count,
		clean_files,
		error_files,
		error_count,
	)

	if len(groups) == 0 {
		return
	}
	slice.sort_by(groups[:], sort_by_count)
	fmt.println("\ndiagnostic groups:")
	for group in groups {
		fmt.printf("  %4d  %s\n", group.count, group.message)
	}
}
