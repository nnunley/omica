package accel

import "core:testing"

@(test)
test_decline_reason_unsorted_column :: proc(t: ^testing.T) {
	_, ok := cpu_strategy().membership_select([]u64{1}, []u64{3, 1, 2}, true, context.temp_allocator)
	testing.expect(t, !ok)
	testing.expect_value(t, last_decline_reason(), Decline.Unsupported)
	free_all(context.temp_allocator)
}

@(test)
test_decline_reason_cleared_on_success :: proc(t: ^testing.T) {
	_, _ = cpu_strategy().membership_select([]u64{1}, []u64{3, 1, 2}, true, context.temp_allocator)
	selected, ok := cpu_strategy().membership_select([]u64{1, 2}, []u64{2}, true, context.temp_allocator)
	testing.expect(t, ok)
	testing.expect_value(t, len(selected), 2)
	testing.expect_value(t, last_decline_reason(), Decline.None)
	free_all(context.temp_allocator)
}

@(test)
test_decline_reason_bad_cosine_shape :: proc(t: ^testing.T) {
	_, ok := cpu_strategy().cosine_queries([]f32{1}, []f32{1}, 1, 1, 0, context.temp_allocator)
	testing.expect(t, !ok)
	testing.expect_value(t, last_decline_reason(), Decline.Unsupported)
}
