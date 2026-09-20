// Client revision contract for revision-checked buffer edits.
//
// The transaction model cannot catch a stale client offset: a submission
// computed against revision 41 that arrives after revision 42 committed begins
// on the new snapshot, finds nothing to conflict with, and silently edits the
// wrong position. This state machine makes that case explicit.
//
// The operation is split in two because a staging builtin cannot return a
// committed result -- the commit has not happened, and later code in the same
// transaction may edit further or abort. The completion is composed *before*
// publication, so a failure to compose it can never be reported for edits that
// are already durable.
package buffer

// Outcome of a revision-checked operation.
Apply_Status :: enum {
	// The edits are staged in the transaction view; no commit yet.
	Staged,
	// `expected_revision` did not match the snapshot; nothing was staged.
	Stale,
	// Committed, with an authoritative delta relative to `expected_revision`.
	Ok,
	// The authoritative delta could not be composed; nothing was published.
	Resync,
	// A concurrent transaction changed an overlapping range.
	Conflict,
	// A second revision-checked apply, or a mutation after one, in the same
	// transaction on the same buffer.
	Rejected_State,
	Aborted,
}

// Where the transaction sits between staging and publication.
Lifecycle :: enum {
	Fresh,
	Staged,
	Prepared,
	Published,
	Aborted,
}

// Per-transaction, per-buffer apply state.
Apply_State :: struct {
	expected_revision: u64,
	// Whether a revision-checked apply has already happened for this buffer in
	// this transaction. A matching snapshot revision does not make client
	// offsets safe once an earlier builtin has moved the transaction view, so
	// at most one apply precedes other mutations.
	applied:   bool,
	lifecycle: Lifecycle,
}

// Begins a revision-checked apply, comparing the client's expected revision
// against the revision visible to the transaction's snapshot.
apply_begin :: proc(
	expected_revision, current_revision: u64,
) -> (
	Apply_State,
	Apply_Status,
) {
	if expected_revision != current_revision {
		return Apply_State {
			expected_revision = expected_revision,
			lifecycle = .Aborted,
		}, .Stale
	}
	return Apply_State {
		expected_revision = expected_revision,
		applied = true,
		lifecycle = .Staged,
	}, .Staged
}

// A second revision-checked apply on the same buffer in the same transaction.
apply_again :: proc(state: Apply_State) -> Apply_Status {
	if state.applied {
		return .Rejected_State
	}
	return .Staged
}

// Whether a bare builtin (`buffer_insert` and friends) may still mutate this
// buffer in this transaction.
bare_mutation_allowed :: proc(state: Apply_State) -> bool {
	return !state.applied
}

// The result delivered after publication.
Apply_Completion :: struct {
	status:    Apply_Status,
	revision:  u64,
	applied:   []Replacement,
	lifecycle: Lifecycle,
}

// Composes the completion before publication.
//
// `prepared` is false when the authoritative delta could not be composed --
// an epoch boundary was crossed, the rebase budget was exhausted, or the
// client's revision is no longer derivable. In that case nothing may be
// published and the client must resynchronize.
completion_prepare :: proc(
	prepared: bool,
	committed_revision, current_revision: u64,
	applied: []Replacement,
) -> Apply_Completion {
	if !prepared {
		return Apply_Completion {
			status = .Resync,
			revision = current_revision,
			lifecycle = .Aborted,
		}
	}
	return Apply_Completion {
		status = .Ok,
		revision = committed_revision,
		applied = applied,
		lifecycle = .Prepared,
	}
}

// A concurrent transaction changed an overlapping range on the same baseline.
completion_conflict :: proc(current_revision: u64) -> Apply_Completion {
	return Apply_Completion {
		status = .Conflict,
		revision = current_revision,
		lifecycle = .Aborted,
	}
}

// Whether this completion may be published. Only a prepared `:ok` may be.
completion_publishable :: proc(completion: Apply_Completion) -> bool {
	return completion.status == .Ok && completion.lifecycle == .Prepared
}

// Marks a prepared completion published. The completion is composed in full
// beforehand, so publication cannot turn it into a `:resync`.
completion_publish :: proc(completion: Apply_Completion, published: bool) -> Apply_Completion {
	result := completion
	if published {
		result.lifecycle = .Published
	}
	return result
}
