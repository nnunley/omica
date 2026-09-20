// Conflict, epoch, and budget policy for buffer reconciliation.
//
// These are the decision procedures the design specifies. They are pure
// functions over base-relative replacements and revision/epoch pairs, so M0 can
// test them without a piece tree or a kernel.
package buffer

import "core:unicode/utf8"

// Whether two base-relative replacements conflict.
//
// The boundary cases are the contract, not incidental:
//   - two insertions conflict only at the same point;
//   - an insertion strictly inside another edit's removed range conflicts,
//     because its anchor is destroyed;
//   - an insertion exactly at a boundary does not conflict and orders
//     deterministically (before at the start, after at the end);
//   - adjacent ranges do not conflict.
replacements_conflict :: proc(a, b: Replacement) -> bool {
	a_empty := a.start == a.end
	b_empty := b.start == b.end

	switch {
	case a_empty && b_empty:
		return a.start == b.start
	case a_empty:
		return b.start < a.start && a.start < b.end
	case b_empty:
		return a.start < b.start && b.start < a.end
	}
	return a.start < b.end && b.start < a.end
}

// Whether any pair of replacements across two deltas conflicts.
deltas_conflict :: proc(a, b: Delta) -> bool {
	for left in a.replacements {
		for right in b.replacements {
			if replacements_conflict(left, right) {
				return true
			}
		}
	}
	return false
}

@(private)
delta_shift_by :: proc(replacement: Replacement) -> int {
	inserted := utf8.rune_count_in_string(replacement.text)
	return inserted - (replacement.end - replacement.start)
}

// New position of a range *start*.
//
// Everything that ends at or before the start lies before it, including an
// insertion exactly at it: an insertion at the start of a range stays outside,
// on the left, so the range moves right past it.
@(private)
delta_shift_start :: proc(base_delta: Delta, position: int) -> int {
	shift := 0
	for replacement in base_delta.replacements {
		if replacement.end <= position {
			shift += delta_shift_by(replacement)
		}
	}
	return position + shift
}

// New position of a range *end*.
//
// An insertion exactly at the end stays outside, on the right, so it does not
// move the end; a non-empty change ending there does, because its text is
// before the end.
@(private)
delta_shift_end :: proc(base_delta: Delta, position: int) -> int {
	shift := 0
	for replacement in base_delta.replacements {
		non_empty_ending_here := replacement.end == position &&
			replacement.start < replacement.end
		if replacement.end < position || non_empty_ending_here {
			shift += delta_shift_by(replacement)
		}
	}
	return position + shift
}

// Which side of text inserted exactly at a marker's position the marker ends up
// on. This is the only case an insertion type decides; every other edit moves a
// marker the same way.
Marker_Insertion_Type :: enum {
	// The marker ends up after text inserted at its position.
	After,
	// The marker ends up before text inserted at its position.
	Before,
}

// New position of a marker after `base_delta` is applied.
//
// A marker is a stable identity with a position that moves with edits, so a
// rebase is the same interval transform used for reconciliation, applied to a
// point:
//
//   - text inserted before the marker shifts it right by the inserted length;
//   - text removed before the marker shifts it left by the removed length;
//   - a marker strictly inside a removed range collapses to the deletion point,
//     rather than landing past the end of the text that replaced it;
//   - an insertion exactly at the marker's position is decided by
//     `insertion_type`, which is what makes a marker "sticky".
//
// `base_delta` must be a normalized, ascending base-relative delta, which is
// what `tree_provenance` and the change feed both produce.
marker_rebase :: proc(
	base_delta: Delta,
	position: int,
	insertion_type: Marker_Insertion_Type,
) -> int {
	shift := 0
	for replacement in base_delta.replacements {
		if replacement.start == replacement.end {
			// A pure insertion does not destroy the marker; it only decides
			// which side of the inserted text the marker sits on.
			if replacement.start < position ||
			   (replacement.start == position && insertion_type == .After) {
				shift += delta_shift_by(replacement)
			}
			continue
		}
		if position <= replacement.start {
			break
		}
		if position < replacement.end {
			// The marker was inside material that no longer exists: it
			// survives at the deletion point.
			return replacement.start + shift
		}
		shift += delta_shift_by(replacement)
	}
	return position + shift
}

// Re-expresses `delta`, which was computed against the same base as
// `base_delta`, in the coordinates that result from applying `base_delta`.
//
// This is the transform that lets a prepared change be re-applied to a base
// that has moved. It is only meaningful when the two deltas do not conflict, so
// callers check that first; transforming overlapping edits would silently
// interleave them.
delta_transform :: proc(base_delta, delta: Delta, allocator := context.allocator) -> Delta {
	replacements := make([]Replacement, len(delta.replacements), allocator)
	for replacement, index in delta.replacements {
		replacements[index] = Replacement {
			start = delta_shift_start(base_delta, replacement.start),
			end   = delta_shift_end(base_delta, replacement.end),
			text  = replacement.text,
		}
	}
	return Delta{replacements = replacements}
}

// What a transaction must do when it finds its base superseded.
//
// The epoch constrains the *published result*, not merely permission to merge:
// a transaction that based itself on pre-compaction chunks must not publish
// those chunks under the post-compaction epoch, even though compaction changed
// no content. That case re-applies its delta to the current root instead.
Rebase_Action :: enum {
	// No concurrent change: the candidate is publishable as built.
	Publish_As_Built,
	// Content unchanged but lineage moved (compaction): re-apply the delta to
	// the current root and publish under the current epoch.
	Reapply_Delta,
	// Same lineage, later revision: provenance merge.
	Merge,
	// Provenance cannot compare across the boundary.
	Conflict,
}

rebase_action :: proc(revision0, epoch0, revision1, epoch1: u64) -> Rebase_Action {
	revision_changed := revision0 != revision1
	epoch_changed := epoch0 != epoch1

	switch {
	case !revision_changed && !epoch_changed:
		return .Publish_As_Built
	case !revision_changed && epoch_changed:
		return .Reapply_Delta
	case revision_changed && !epoch_changed:
		return .Merge
	}
	return .Conflict
}

// Failure classes. Ordinary limits and reconciliation limits are distinct: a
// caller that resynchronizes cannot fix an oversized ordinary edit, because the
// same snapshot and the same edit fail identically.
Failure :: enum {
	None,
	// The edit's own normalization or encoded size exceeds a configured limit.
	Buffer_Edit_Too_Large,
	// The durable store refused admission.
	Overloaded,
	// Reconciling against concurrent changes exceeded the rebase budget.
	Rebase_Budget_Exceeded,
}

// Whether a client resynchronization and retry can succeed where the failure
// occurred. Only reconciliation failures are resyncable; an oversized ordinary
// edit is not.
failure_is_resyncable :: proc(failure: Failure) -> bool {
	return failure == .Rebase_Budget_Exceeded
}

// Provisional rebase budgets. These limit work performed, not the size of the
// result: comparing two large, equal but independently chunked roots can do
// substantial work and produce no hunks at all. Benchmark before treating them
// as production defaults.
Rebase_Budget :: struct {
	comparison_steps: u64,
	text_bytes:       u64,
	hunks:            u64,
	alloc_bytes:      u64,
}

DEFAULT_REBASE_BUDGET :: Rebase_Budget {
	comparison_steps = 4096,
	text_bytes       = 1 << 20,
	hunks            = 1024,
	alloc_bytes      = 1 << 20,
}

// Work consumed so far by reconciliation in one transaction. Budgets are shared
// across every rebase a transaction performs.
Budget_Usage :: struct {
	comparison_steps: u64,
	text_bytes:       u64,
	hunks:            u64,
	alloc_bytes:      u64,
}

budget_exceeded :: proc(budget: Rebase_Budget, usage: Budget_Usage) -> bool {
	return(
		usage.comparison_steps > budget.comparison_steps ||
		usage.text_bytes > budget.text_bytes ||
		usage.hunks > budget.hunks ||
		usage.alloc_bytes > budget.alloc_bytes
	)
}
