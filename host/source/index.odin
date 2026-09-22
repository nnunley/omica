// A minimal local-worktree source provider.
//
// The Rust source provider exposes computed relations backed by the
// filesystem, git, and a semantic index. This port has no computed-relation
// hook, so instead of computing rows on demand it eagerly indexes one
// workspace root into ordinary facts at world start:
//
//   source/RepositoryEntry   directory listings (parent, child, kind, name)
//   source/FileText          file contents, hash, provider version
//   source/FileLineCount     line counts for the read tool
//   source/IndexedFile       file titles and languages for glob and panels
//
// The agent's read/ls/glob tools query exactly those relations, so they work
// unchanged; the agent app scans FileText for grep because TextSearch is not
// indexed here. Facts are idempotent, so an unchanged tree re-indexes to the
// same rows; deleted files leave stale rows until the store is rebuilt.
package source

import "core:fmt"
import "core:mem"
import "core:mem/virtual"
import "core:os"
import "core:path/filepath"
import "core:strings"

import k "../../mica/kernel"
import r "../../mica/runtime"
import v "../../mica/var"

Options :: struct {
	// Workspace root to index. Defaults to ".".
	root: string,
	// Name stored in `source/IndexedFile` rows. Defaults to "default".
	repository_name: string,
	// Files larger than this are listed but not indexed for content.
	// Defaults to 1 MiB.
	max_file_bytes: i64,
}

Index_Result :: struct {
	ok:          bool,
	files:       int,
	directories: int,
	skipped:     int,
	message:     string,
}

DEFAULT_MAX_FILE_BYTES :: 1024 * 1024
FACT_BATCH :: 512

@(private)
PROVIDER :: "local-worktree"

@(private)
INDEX_LABEL :: "local"

@(private)
SOURCE_VERSION :: "1"

@(private)
SKIP_DIRECTORIES := []string {
	".git",
	".hg",
	".svn",
	".cache",
	"node_modules",
	"target",
	"__pycache__",
	".venv",
	"venv",
	"dist",
	"build",
}

// Indexes the first root in `MICA_SOURCE_ROOTS`, when set. The boolean
// reports whether indexing was attempted; a world that does not declare the
// source schema is not an error.
index_from_env :: proc(world: ^r.World) -> (Index_Result, bool) {
	roots, found := os.lookup_env("MICA_SOURCE_ROOTS", context.temp_allocator)
	if !found || roots == "" {
		return {}, false
	}
	root := roots
	// `workspaces.mica` binds only the first root, so index the same one.
	if colon := strings.index_byte(roots, ':'); colon >= 0 {
		root = roots[:colon]
	}
	root = strings.trim_space(root)
	if root == "" {
		return {}, false
	}
	return index_world(world, Options{root = root}), true
}

// Indexes `options.root` into the world's `source/*` relations. Returns a
// result with `ok = false` when the world does not declare the source schema,
// so callers can skip indexing worlds that do not use it.
index_world :: proc(world: ^r.World, options: Options) -> Index_Result {
	root := options.root
	if root == "" {
		root = "."
	}
	root = strings.trim_right(root, "/")
	if root == "" {
		root = "/"
	}

	repository, has_repository := world.ctx.identities["source/repo_default"]
	revision, has_revision := world.ctx.identities["source/rev_worktree"]
	entry_relation, has_entry := world.ctx.relations["source/RepositoryEntry"]
	text_relation, has_text := world.ctx.relations["source/FileText"]
	line_relation, has_line := world.ctx.relations["source/FileLineCount"]
	index_relation, has_index := world.ctx.relations["source/IndexedFile"]
	if !has_repository ||
	   !has_revision ||
	   !has_entry ||
	   !has_text ||
	   !has_line ||
	   !has_index {
		return Index_Result{message = "world does not declare the source relations"}
	}
	// The walker reports canonical absolute paths. Normalize the root to the
	// same form before removing its prefix, including macOS temporary aliases.
	canonical_root, root_error := filepath.abs(root, context.temp_allocator)
	if root_error != nil {
		return Index_Result {
			message = fmt.aprintf(
				"cannot resolve source root %s: %v",
				root,
				root_error,
				allocator = context.temp_allocator,
			),
		}
	}
	root = canonical_root
	repository_name := options.repository_name
	if repository_name == "" {
		repository_name = "default"
	}
	max_bytes := options.max_file_bytes
	if max_bytes <= 0 {
		max_bytes = DEFAULT_MAX_FILE_BYTES
	}

	result := Index_Result{ok = true}
	batch: [dynamic]r.World_Fact
	batch = make([dynamic]r.World_Fact, 0, FACT_BATCH, context.allocator)
	defer delete(batch)

	// Batch values are built in a private scratch arena and released after
	// each commit. The kernel deep-copies asserted values, so nothing in a
	// batch outlives `world_apply_facts`. The arena is not the caller's
	// temporary allocator: that one can be the world's own allocator, and
	// resetting it would destroy the compile context.
	scratch_arena: virtual.Arena
	has_scratch := virtual.arena_init_growing(&scratch_arena) == nil
	scratch := context.temp_allocator
	if has_scratch {
		scratch = virtual.arena_allocator(&scratch_arena)
		defer virtual.arena_destroy(&scratch_arena)
	}

	walker: os.Walker
	os.walker_init(&walker, root)
	defer os.walker_destroy(&walker)

	for {
		info, has_entry_info := os.walker_walk(&walker)
		if !has_entry_info {
			break
		}
		relative := relative_to(root, info.fullpath)
		if relative == "" {
			continue
		}
		parent := filepath.dir(relative)
		if parent == "." {
			parent = ""
		}
		if info.type == .Directory {
			if should_skip_directory(relative, info.name) {
				os.walker_skip_dir(&walker)
			}
			append(
				&batch,
				entry_fact(
					entry_relation,
					repository,
					revision,
					parent,
					relative,
					info.name,
					"directory",
					scratch,
				),
			)
			result.directories += 1
		} else if info.type == .Regular {
			append(
				&batch,
				entry_fact(
					entry_relation,
					repository,
					revision,
					parent,
					relative,
					info.name,
					"file",
					scratch,
				),
			)
			if info.size > max_bytes {
				result.skipped += 1
			} else if data, read_err := os.read_entire_file(
				info.fullpath,
				context.temp_allocator,
			); read_err == nil {
				if strings.contains(string(data), "\x00") {
					// Binary files are listed but not indexed for content.
					result.skipped += 1
				} else {
					append(
						&batch,
						text_fact(
						text_relation,
						repository,
						revision,
						relative,
						string(data),
						scratch,
					),
					)
					append(
						&batch,
						line_count_fact(
							line_relation,
							repository,
							revision,
							relative,
							count_lines(data),
							scratch,
						),
					)
					append(
						&batch,
						indexed_file_fact(
							index_relation,
							repository_name,
							relative,
							info.name,
							scratch,
						),
					)
					result.files += 1
				}
			} else {
				result.skipped += 1
			}
		}
		if len(batch) >= FACT_BATCH {
			if err := flush_batch(world, &batch, scratch, has_scratch); err != k.Kernel_Error.None {
				result.ok = false
				result.message = fmt.aprintf(
					"indexing %s failed: %v",
					info.fullpath,
					err,
					allocator = context.temp_allocator,
				)
				return result
			}
		}
	}
	if err := flush_batch(world, &batch, scratch, has_scratch); err != k.Kernel_Error.None {
		result.ok = false
		result.message = fmt.aprintf(
			"indexing %s failed: %v",
			root,
			err,
			allocator = context.temp_allocator,
		)
		return result
	}
	return result
}

@(private)
flush_batch :: proc(
	world: ^r.World,
	batch: ^[dynamic]r.World_Fact,
	scratch: mem.Allocator,
	reclaim: bool,
) -> k.Kernel_Error {
	if len(batch) == 0 {
		return .None
	}
	err := r.world_apply_facts(world, batch[:])
	clear(batch)
	if reclaim {
		free_all(scratch)
	}
	return err
}

@(private)
entry_fact :: proc(
	relation: u32,
	repository: v.Value,
	revision: v.Value,
	parent: string,
	child: string,
	name: string,
	kind: string,
	allocator: mem.Allocator,
) -> r.World_Fact {
	return r.World_Fact {
		relation = k.Relation_ID(relation),
		tuple = v.tuple_new(
			allocator,
			[]v.Value {
				repository,
				revision,
				v.value_string(allocator, parent),
				v.value_string(allocator, child),
				v.value_string(allocator, kind),
				v.value_string(allocator, name),
				v.value_string(allocator, PROVIDER),
			},
		),
	}
}

@(private)
text_fact :: proc(
	relation: u32,
	repository: v.Value,
	revision: v.Value,
	path: string,
	text: string,
	allocator: mem.Allocator,
) -> r.World_Fact {
	return r.World_Fact {
		relation = k.Relation_ID(relation),
		tuple = v.tuple_new(
			allocator,
			[]v.Value {
				repository,
				revision,
				v.value_string(allocator, path),
				v.value_string(allocator, PROVIDER),
				v.value_string(allocator, text),
				v.value_string(allocator, content_hash(transmute([]byte)text, allocator)),
				v.value_string(allocator, SOURCE_VERSION),
			},
		),
	}
}

@(private)
line_count_fact :: proc(
	relation: u32,
	repository: v.Value,
	revision: v.Value,
	path: string,
	line_count: i64,
	allocator: mem.Allocator,
) -> r.World_Fact {
	count, _ := v.value_int(line_count)
	return r.World_Fact {
		relation = k.Relation_ID(relation),
		tuple = v.tuple_new(
			allocator,
			[]v.Value {
				repository,
				revision,
				v.value_string(allocator, path),
				count,
				v.value_string(allocator, PROVIDER),
				v.value_string(allocator, SOURCE_VERSION),
			},
		),
	}
}

@(private)
indexed_file_fact :: proc(
	relation: u32,
	repository_name: string,
	path: string,
	title: string,
	allocator: mem.Allocator,
) -> r.World_Fact {
	return r.World_Fact {
		relation = k.Relation_ID(relation),
		tuple = v.tuple_new(
			allocator,
			[]v.Value {
				v.value_string(allocator, INDEX_LABEL),
				v.value_string(allocator, repository_name),
				v.value_string(allocator, path),
				v.value_string(allocator, title),
				v.value_string(allocator, language_of(path)),
				v.value_string(allocator, PROVIDER),
			},
		),
	}
}

@(private)
relative_to :: proc(root: string, fullpath: string) -> string {
	relative := fullpath
	if strings.has_prefix(relative, root) {
		relative = relative[len(root):]
	}
	return strings.trim_left(relative, "/")
}

@(private)
should_skip_directory :: proc(relative: string, name: string) -> bool {
	for skip in SKIP_DIRECTORIES {
		if name == skip {
			return true
		}
	}
	// The generated mdBook output.
	return relative == "mdbook/book"
}

@(private)
count_lines :: proc(data: []byte) -> i64 {
	if len(data) == 0 {
		return 0
	}
	count: i64 = 0
	for byte in data {
		if byte == '\n' {
			count += 1
		}
	}
	if data[len(data) - 1] != '\n' {
		count += 1
	}
	return count
}

@(private)
content_hash :: proc(data: []byte, allocator: mem.Allocator) -> string {
	hash := u64(0xcbf2_9ce4_8422_2325)
	for byte in data {
		hash = (hash ~ u64(byte)) * u64(0x0000_0100_0000_01b3)
	}
	return fmt.aprintf("fnv1a:%016x", hash, allocator = context.temp_allocator)
}

@(private)
language_of :: proc(path: string) -> string {
	extension := filepath.ext(path)
	switch extension {
	case ".rs":
		return "rust"
	case ".mica":
		return "mica"
	case ".md":
		return "markdown"
	case ".js", ".mjs", ".cjs":
		return "javascript"
	}
	return "file"
}
