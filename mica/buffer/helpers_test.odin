// Shared test helpers. Test-only, so the package build stays free of the
// virtual-arena dependency.
package buffer

import "core:mem"
import "core:mem/virtual"
import "core:testing"

@(private)
test_allocator :: proc(t: ^testing.T) -> (mem.Allocator, ^virtual.Arena) {
	arena := new(virtual.Arena, context.allocator)
	if err := virtual.arena_init_growing(arena); err != nil {
		testing.expectf(t, false, "cannot initialize test arena: %v", err)
	}
	return virtual.arena_allocator(arena), arena
}

@(private)
test_allocator_destroy :: proc(arena: ^virtual.Arena) {
	virtual.arena_destroy(arena)
	free(arena, context.allocator)
}

// A view-relative edit that only inserts.
@(private)
insert :: proc(at: int, text: string) -> Edit {
	return Edit{at = at, remove = 0, text = text}
}

// A view-relative edit that only removes.
@(private)
remove :: proc(at, count: int) -> Edit {
	return Edit{at = at, remove = count, text = ""}
}

// A view-relative replacement.
@(private)
replace :: proc(at, count: int, text: string) -> Edit {
	return Edit{at = at, remove = count, text = text}
}

// Insertion texts for generated scripts. Includes a newline and a multi-byte
// scalar so line accounting and byte localization are exercised.
@(private)
insertion_sources := []string{"x", "YZ", "!", "qq", " \n", "→"}
