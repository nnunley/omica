// Placement counters: every step that could run on an accelerator records
// its outcome, process-wide, so tests and benchmarks can prove what ran
// instead of assuming it. Later stages add the placement decisions
// themselves (thresholds, validation) here.
package kernel

import "core:sync"
import accel "./accel"

Placement_Operator :: enum u8 {
	Negated_Membership,
	Positive_Join,
	Derived_Dedup,
	Cosine,
}

// Completed: the active strategy produced a validated result.
// Not_Packable: the input could not be encoded (heap values, mixed shapes).
// Invalid_Result: the strategy returned something that failed validation;
// the step reran on the CPU.
// Cpu_Fallback: recorded after a decline or invalid result when the CPU
// reference finished the step on packed keys instead of the row path.
Placement_Outcome :: enum u8 {
	Completed,
	Below_Threshold,
	Not_Packable,
	Busy,
	Unsupported,
	Unavailable,
	Failed,
	Invalid_Result,
	// The strategy declined (its reason is recorded too) and the CPU reference
	// finished the step on the already-packed keys.
	Cpu_Fallback,
}

Placement_Counts :: [Placement_Operator][Placement_Outcome]u64

@(private)
placement_counters: Placement_Counts

// The same counts for the calling thread only. Rule evaluation runs on the
// thread that commits, so a test reads exactly its own decisions here even
// while other tests record concurrently into the process-wide counts.
@(thread_local, private)
placement_thread_counters: Placement_Counts

placement_record :: proc(op: Placement_Operator, outcome: Placement_Outcome) {
	sync.atomic_add(&placement_counters[op][outcome], 1)
	placement_thread_counters[op][outcome] += 1
}

placement_counts_this_thread :: proc() -> Placement_Counts {
	return placement_thread_counters
}

// Records why the calling thread's last accel operator declined.
placement_record_decline :: proc(op: Placement_Operator) {
	outcome: Placement_Outcome
	switch accel.last_decline_reason() {
	case .Below_Threshold:
		outcome = .Below_Threshold
	case .Busy:
		outcome = .Busy
	case .Unsupported:
		outcome = .Unsupported
	case .Unavailable:
		outcome = .Unavailable
	case .Failed, .None:
		outcome = .Failed
	}
	placement_record(op, outcome)
}

placement_counts :: proc() -> (counts: Placement_Counts) {
	for op in Placement_Operator {
		for outcome in Placement_Outcome {
			counts[op][outcome] = sync.atomic_load(&placement_counters[op][outcome])
		}
	}
	return
}

placement_counts_delta :: proc(before, after: Placement_Counts) -> (delta: Placement_Counts) {
	for op in Placement_Operator {
		for outcome in Placement_Outcome {
			delta[op][outcome] = after[op][outcome] - before[op][outcome]
		}
	}
	return
}
