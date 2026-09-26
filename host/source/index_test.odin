// Tests for the local-worktree indexer: a small tree indexes into the source
// relations the agent tools query.
package source

import "base:runtime"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:testing"
import "core:time"

import k "../../mica/kernel"
import r "../../mica/runtime"
import v "../../mica/var"

@(private)
SCHEMA_SOURCE :: `make_identity(:source/repo_default)
make_identity(:source/rev_worktree)
make_relation(:source/RepositoryEntry, 7)
make_relation(:source/FileText, 7)
make_relation(:source/FileLineCount, 6)
make_relation(:source/IndexedFile, 6)
`

@(private)
relation_rows :: proc(world: ^r.World, name: string) -> (rows: [dynamic]v.Tuple, ok: bool) {
	relation, has_relation := world.ctx.relations[name]
	if !has_relation {
		return rows, false
	}
	metadata, has_metadata := k.snapshot_relation_metadata(
		world.kernel.current,
		k.Relation_ID(relation),
	)
	if !has_metadata {
		return rows, false
	}
	bindings := make([]v.Binding, metadata.arity, context.temp_allocator)
	k.kernel_scan_into(world.kernel, k.Relation_ID(relation), bindings, &rows)
	return rows, true
}

@(test)
test_index_workspace_tree :: proc(t: ^testing.T) {
	test_index_workspace_tree_with_root(t, "plain")
}

@(test)
test_index_workspace_normalized_root :: proc(t: ^testing.T) {
	test_index_workspace_tree_with_root(t, "normalized")
}

@(test)
test_index_workspace_symlink_root :: proc(t: ^testing.T) {
	test_index_workspace_tree_with_root(t, "symlink")
}

@(test)
test_index_workspace_relative_root :: proc(t: ^testing.T) {
	test_index_workspace_tree_with_root(t, "relative")
}

@(private)
test_index_workspace_tree_with_root :: proc(t: ^testing.T, root_kind: string) {
	defer free_all(context.temp_allocator)
	directory, directory_err := os.temp_dir(context.temp_allocator)
	if directory_err != nil {
		testing.expect(t, false, "cannot resolve a temporary directory")
		return
	}
	root := fmt.aprintf(
		"%s/omica-source-test-%d",
		directory,
		time.tick_now(),
		allocator = context.temp_allocator,
	)
	defer os.remove_all(root)
	if err := os.make_directory_all(
		fmt.aprintf("%s/src", root, allocator = context.temp_allocator),
	); err != nil {
		testing.expectf(t, false, "cannot create test tree: %v", err)
		return
	}
	if err := os.write_entire_file(
		fmt.aprintf("%s/README.md", root, allocator = context.temp_allocator),
		"Hello\nworld\n",
	); err != nil {
		testing.expectf(t, false, "cannot write README: %v", err)
		return
	}
	if err := os.write_entire_file(
		fmt.aprintf("%s/src/main.mica", root, allocator = context.temp_allocator),
		"verb main()\nend\n",
	); err != nil {
		testing.expectf(t, false, "cannot write main.mica: %v", err)
		return
	}

	// The schema file lives outside the indexed root so it is not indexed.
	schema_path := fmt.aprintf(
		"%s/omica-source-schema-%d.mica",
		directory,
		time.tick_now(),
		allocator = context.temp_allocator,
	)
	defer os.remove(schema_path)
	if err := os.write_entire_file(schema_path, SCHEMA_SOURCE); err != nil {
		testing.expectf(t, false, "cannot write schema: %v", err)
		return
	}

	kernel: k.Kernel
	k.kernel_init(&kernel)
	defer k.kernel_destroy(&kernel)
	world, start := r.world_start(
		&kernel,
		[]string{schema_path},
		runtime.heap_allocator(),
		r.World_Config{workers = 1},
	)
	if !start.ok {
		testing.expectf(t, false, "world start failed: %s", start.message)
		return
	}
	defer r.world_destroy(world)
	r.world_wait(world, world.entry)

	indexed_root := root
	switch root_kind {
	case "normalized":
		indexed_root = fmt.aprintf("%s//.", root, allocator = context.temp_allocator)
	case "symlink":
		indexed_root = fmt.aprintf("%s-link", root, allocator = context.temp_allocator)
		err := os.symlink(root, indexed_root)
		testing.expectf(t, err == nil, "cannot create root alias: %v", err)
		if err != nil {return}
	case "relative":
		cwd, cwd_err := os.getwd(context.temp_allocator)
		testing.expect(t, cwd_err == nil)
		if cwd_err != nil {return}
		relative, rel_err := filepath.rel(cwd, root, context.temp_allocator)
		testing.expect(t, rel_err == .None)
		if rel_err != .None {return}
		indexed_root = relative
	}
	defer if root_kind == "symlink" {os.remove(indexed_root)}
	result := index_world(world, Options{root = indexed_root})
	testing.expectf(t, result.ok, "index failed: %s", result.message)
	testing.expect_value(t, result.files, 2)
	testing.expect_value(t, result.directories, 1)

	entries, entries_ok := relation_rows(world, "source/RepositoryEntry")
	testing.expect(t, entries_ok)
	testing.expect_value(t, len(entries), 3)

	texts, texts_ok := relation_rows(world, "source/FileText")
	testing.expect(t, texts_ok)
	testing.expect_value(t, len(texts), 2)
	if len(texts) == 2 {
		// Rows are canonically ordered by path: README.md then src/main.mica.
		first := v.tuple_values(texts[0])
		path, _ := v.value_as_string(first[2])
		text, _ := v.value_as_string(first[4])
		testing.expect_value(t, path, "README.md")
		testing.expect_value(t, text, "Hello\nworld\n")
	}

	line_counts, line_ok := relation_rows(world, "source/FileLineCount")
	testing.expect(t, line_ok)
	testing.expect_value(t, len(line_counts), 2)
	if len(line_counts) == 2 {
		first := v.tuple_values(line_counts[0])
		count, _ := v.value_as_int(first[3])
		testing.expect_value(t, count, i64(2))
	}

	indexed, indexed_ok := relation_rows(world, "source/IndexedFile")
	testing.expect(t, indexed_ok)
	testing.expect_value(t, len(indexed), 2)
	if len(indexed) == 2 {
		first := v.tuple_values(indexed[0])
		language, _ := v.value_as_string(first[4])
		testing.expect_value(t, language, "markdown")
	}

	delete(entries)
	delete(texts)
	delete(line_counts)
	delete(indexed)
}

// A world without the source schema is reported, not an error.
@(test)
test_index_skips_world_without_schema :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	directory, directory_err := os.temp_dir(context.temp_allocator)
	if directory_err != nil {
		testing.expect(t, false, "cannot resolve a temporary directory")
		return
	}
	path := fmt.aprintf(
		"%s/omica-source-empty-%d.mica",
		directory,
		time.tick_now(),
		allocator = context.temp_allocator,
	)
	defer os.remove(path)
	if err := os.write_entire_file(path, "make_relation(:Marker, 1)\n"); err != nil {
		testing.expectf(t, false, "cannot write source: %v", err)
		return
	}
	kernel: k.Kernel
	k.kernel_init(&kernel)
	defer k.kernel_destroy(&kernel)
	world, start := r.world_start(
		&kernel,
		[]string{path},
		runtime.heap_allocator(),
		r.World_Config{workers = 1},
	)
	if !start.ok {
		testing.expectf(t, false, "world start failed: %s", start.message)
		return
	}
	defer r.world_destroy(world)
	r.world_wait(world, world.entry)

	result := index_world(world, Options{root = directory})
	testing.expect(t, !result.ok)
	testing.expectf(t, result.message != "", "expected a message")
}
