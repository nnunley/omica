// Fact neighbourhoods: SubjectFact, MentionedFact and ExtensionalMentionedFact
// report the stored facts around a value, under the reader's read authority.
package mica_runtime

import "core:os"
import "core:testing"
import k "../kernel"

@(test)
test_fact_neighbourhoods :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	source := `make_identity(:lamp)
make_identity(:room)
make_relation(:LocatedIn, 2)
make_relation(:Pair, 2)
make_relation(:Near, 2)
make_relation(:Done, 1)
assert LocatedIn(#lamp, #room)
assert Pair(#room, #room)
Near(x, y) :- LocatedIn(x, y)
let exactly {relation} = RelationName(?relation, :LocatedIn)
let exactly {pair} = RelationName(?pair, :Pair)
let exactly {near} = RelationName(?near, :Near)
require SubjectFact(#lamp, relation, ?tuple) == [:tuple] {[[#lamp, #room]]}
require MentionedFact(#room, relation, ?position, ?tuple) == [:position, :tuple] {[1, [#lamp, #room]]}
require MentionedFact(#room, pair, ?position, ?tuple) == [:position, :tuple] {[0, [#room, #room]], [1, [#room, #room]]}
require ExtensionalMentionedFact(#room, relation, ?position, ?tuple) == [:position, :tuple] {[1, [#lamp, #room]]}
require Near(#lamp, #room)
require SubjectFact(#lamp, near, ?tuple) == [:tuple] {}
assert Done(1)
`
	path, path_ok := write_temp_source(t, "mica_fact_neighbourhoods_test.mica", source)
	if !path_ok {
		return
	}
	defer os.remove(path)

	kernel: k.Kernel
	k.kernel_init(&kernel)
	defer k.kernel_destroy(&kernel)

	result := run_files(&kernel, []string{path}, context.temp_allocator)
	testing.expectf(t, result.ok, "filein failed: %s", result.message)
	expect_relation_rows(t, &kernel, "Done", 1)
}

@(test)
test_fact_neighbourhoods_obey_read_authority :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	source := `make_identity(:alice)
make_identity(:reader)
make_identity(:lamp)
make_relation(:RoleCanRead, 2)
make_relation(:RoleCanWrite, 2)
make_relation(:Visible, 1)
make_relation(:Secret, 1)
make_relation(:Seen, 1)
assert Delegates(#alice, #reader, 0)
assert Visible(#lamp)
assert Secret(#lamp)
grant role #reader
  read:
    :SubjectFact
    :RelationName
    :Visible
  write:
    :Seen
end
commit()
verb peek()
  // The actor may not call require, so the check writes its verdict.
  let exactly {visible} = RelationName(?visible, :Visible)
  if SubjectFact(#lamp, ?relation, ?tuple) == [:relation, :tuple] {[visible, [#lamp]]}
    assert Seen(1)
  end
end
spawn :peek()
suspend()
`
	path, path_ok := write_temp_source(t, "mica_fact_neighbourhood_authority_test.mica", source)
	if !path_ok {
		return
	}
	defer os.remove(path)

	kernel: k.Kernel
	k.kernel_init(&kernel)
	defer k.kernel_destroy(&kernel)

	result := run_files(
		&kernel,
		[]string{path},
		context.temp_allocator,
		Run_Options{actor = "alice"},
	)
	testing.expectf(t, result.ok, "filein failed: %s", result.message)
	expect_relation_rows(t, &kernel, "Seen", 1)
}
