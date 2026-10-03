package kernel

import "core:slice"
import "core:testing"
import v "../var"

@(private = "file")
Pair :: struct {
	a, b: u32,
}

@(private = "file")
sorted_pairs :: proc(left, right: []u32) -> []Pair {
	out := make([]Pair, len(left), context.temp_allocator)
	for i in 0 ..< len(left) {
		out[i] = {left[i], right[i]}
	}
	slice.sort_by(out, proc(x, y: Pair) -> bool {return x.a < y.a || (x.a == y.a && x.b < y.b)})
	return out
}

@(test)
test_hash_join_matches_nested_loops :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	rng := Property_Rng{state = 0x51ed2701}
	for _ in 0 ..< 20 {
		nb := int(property_next(&rng) % 40)
		np := int(property_next(&rng) % 40)
		build := [][]v.Value{make([]v.Value, nb, context.temp_allocator), make([]v.Value, nb, context.temp_allocator)}
		probe := [][]v.Value{make([]v.Value, np, context.temp_allocator), make([]v.Value, np, context.temp_allocator)}
		for i in 0 ..< nb {
			build[0][i], build[1][i] = must_int(i64(property_next(&rng) % 4)), must_int(i64(property_next(&rng) % 3))
		}
		for i in 0 ..< np {
			probe[0][i], probe[1][i] = must_int(i64(property_next(&rng) % 4)), must_int(i64(property_next(&rng) % 3))
		}
		// Every other build row, all probe rows.
		build_rows := make([dynamic]u32, context.temp_allocator)
		for i in 0 ..< nb {
			if i % 2 == 0 {
				append(&build_rows, u32(i))
			}
		}
		probe_rows := row_iota(np, context.temp_allocator)
		got_b, got_p := hash_join_pairs(build, build_rows[:], probe, probe_rows, context.temp_allocator)
		want_b := make([dynamic]u32, context.temp_allocator)
		want_p := make([dynamic]u32, context.temp_allocator)
		for b in build_rows {
			for p in probe_rows {
				if key_rows_eq(build, int(b), probe, int(p)) {
					append(&want_b, b)
					append(&want_p, p)
				}
			}
		}
		testing.expect(t, slice.equal(sorted_pairs(got_b, got_p), sorted_pairs(want_b[:], want_p[:])))
	}
}

// Review Focus 5.
@(test)
test_hash_join_heap_values_equal_by_content :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	alpha := v.value_string(context.temp_allocator, "alpha")
	alpha_again := v.value_string(context.temp_allocator, "alpha")
	beta := v.value_string(context.temp_allocator, "beta")
	build := [][]v.Value{{alpha, beta}}
	probe := [][]v.Value{{alpha_again, must_int(1)}}
	b, p := hash_join_pairs(build, row_iota(2, context.temp_allocator), probe, row_iota(2, context.temp_allocator), context.temp_allocator)
	testing.expect(t, slice.equal(b, []u32{0}))
	testing.expect(t, slice.equal(p, []u32{0}))

	index := hash_index_build(build, row_iota(2, context.temp_allocator), context.temp_allocator)
	present := hash_index_contains_rows(&index, probe, 2, context.temp_allocator)
	testing.expect(t, slice.equal(present, []bool{true, false}))
}

@(test)
test_hash_index_contains_matches_scan :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	build := [][]v.Value{{must_int(1), must_int(2), must_int(2)}, {must_int(5), must_int(6), must_int(7)}, {must_int(0), must_int(0), must_int(0)}}
	probe := [][]v.Value{{must_int(2), must_int(2), must_int(1)}, {must_int(7), must_int(5), must_int(5)}, {must_int(0), must_int(0), must_int(1)}}
	index := hash_index_build(build, row_iota(3, context.temp_allocator), context.temp_allocator)
	present := hash_index_contains_rows(&index, probe, 3, context.temp_allocator)
	testing.expect(t, slice.equal(present, []bool{true, false, false}))
}
