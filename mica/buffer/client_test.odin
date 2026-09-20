// Tests for the client revision contract: stale rejection, one apply per buffer
// per transaction, and preparation before publication.
package buffer

import "core:testing"

@(test)
test_apply_begin_rejects_stale_revision :: proc(t: ^testing.T) {
	state, status := apply_begin(41, 42)
	testing.expect_value(t, status, Apply_Status.Stale)
	testing.expect_value(t, state.lifecycle, Lifecycle.Aborted)
	// A stale apply changed nothing, so bare mutations remain available.
	testing.expect(t, !state.applied)
	testing.expect(t, bare_mutation_allowed(state))
}

@(test)
test_apply_begin_stages_matching_revision :: proc(t: ^testing.T) {
	state, status := apply_begin(42, 42)
	testing.expect_value(t, status, Apply_Status.Staged)
	testing.expect_value(t, state.lifecycle, Lifecycle.Staged)
	testing.expect(t, state.applied)
}

@(test)
test_one_apply_per_buffer_per_transaction :: proc(t: ^testing.T) {
	state, status := apply_begin(42, 42)
	testing.expect_value(t, status, Apply_Status.Staged)

	// A second revision-checked apply is rejected.
	testing.expect_value(t, apply_again(state), Apply_Status.Rejected_State)

	// A bare mutation after a revision-checked apply is not allowed: the client
	// offsets were computed against the view before the apply, and the revision
	// check cannot make them safe once the view has moved.
	testing.expect(t, !bare_mutation_allowed(state))

	// Before any apply, bare mutations are fine.
	fresh := Apply_State{expected_revision = 42, lifecycle = .Fresh}
	testing.expect(t, bare_mutation_allowed(fresh))
}

@(test)
test_completion_prepare_failure_blocks_publication :: proc(t: ^testing.T) {
	// Composition failed: nothing was published, and the client must resync.
	completion := completion_prepare(false, 99, 42, nil)
	testing.expect_value(t, completion.status, Apply_Status.Resync)
	testing.expect_value(t, completion.lifecycle, Lifecycle.Aborted)
	testing.expect_value(t, completion.revision, 42)
	testing.expect(t, !completion_publishable(completion))
}

@(test)
test_published_completion_is_never_resync :: proc(t: ^testing.T) {
	applied := []Replacement{{start = 3, end = 3, text = "!"}}
	prepared := completion_prepare(true, 43, 42, applied)
	testing.expect_value(t, prepared.status, Apply_Status.Ok)
	testing.expect_value(t, prepared.lifecycle, Lifecycle.Prepared)
	testing.expect(t, completion_publishable(prepared))

	published := completion_publish(prepared, true)
	testing.expect_value(t, published.lifecycle, Lifecycle.Published)
	// The completion was composed in full before publication, so publication
	// cannot turn a committed edit into an uncommitted resync.
	testing.expect_value(t, published.status, Apply_Status.Ok)
	testing.expect_value(t, published.revision, 43)
	testing.expect_value(t, len(published.applied), 1)
	testing.expect(t, published.status != Apply_Status.Resync)
}

@(test)
test_conflict_completion_is_not_publishable :: proc(t: ^testing.T) {
	conflict := completion_conflict(42)
	testing.expect_value(t, conflict.status, Apply_Status.Conflict)
	testing.expect_value(t, conflict.lifecycle, Lifecycle.Aborted)
	testing.expect(t, !completion_publishable(conflict))
}
