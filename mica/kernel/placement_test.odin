package kernel

import "core:testing"
import accel "./accel"

@(test)
test_placement_counts_record_and_delta :: proc(t: ^testing.T) {
	before := placement_counts_this_thread()
	global_before := placement_counts()
	placement_record(.Negated_Membership, .Completed)
	placement_record(.Negated_Membership, .Completed)
	placement_record(.Cosine, .Not_Packable)
	// This thread's counts are exact; the process-wide counts also include
	// other tests running concurrently, so only a lower bound holds there.
	delta := placement_counts_delta(before, placement_counts_this_thread())
	testing.expect_value(t, delta[.Negated_Membership][.Completed], 2)
	testing.expect_value(t, delta[.Cosine][.Not_Packable], 1)
	global := placement_counts_delta(global_before, placement_counts())
	testing.expect(t, global[.Negated_Membership][.Completed] >= 2)
}

@(test)
test_placement_record_decline_uses_strategy_reason :: proc(t: ^testing.T) {
	before := placement_counts_this_thread()
	_, ok := accel.cpu_strategy().membership_select([]u64{1}, []u64{3, 1, 2}, true, context.temp_allocator)
	testing.expect(t, !ok)
	placement_record_decline(.Negated_Membership)
	delta := placement_counts_delta(before, placement_counts_this_thread())
	testing.expect_value(t, delta[.Negated_Membership][.Unsupported], 1)
	free_all(context.temp_allocator)
}
