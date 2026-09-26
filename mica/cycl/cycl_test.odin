package cycl

import "core:testing"

// Keywords keep their single colon: `:TRUE` is the atom ":TRUE" (the atom
// reader already includes the colon; prefixing another made "::TRUE").
@(test)
test_keyword_has_one_colon :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	keywords := []string{":TRUE", ":FORWARD", ":MONOTONIC"}
	for keyword in keywords {
		node, ok := parse(keyword, context.temp_allocator)
		testing.expect(t, ok)
		atom, is_atom := node.(Atom)
		testing.expectf(t, is_atom && string(atom) == keyword, "parsed %q as %v", keyword, node)
	}
}
