package accel

import "core:math"
import "core:testing"

// Independent oracle: cosine in f64 with the library sqrt, per pair.
@(private = "file")
cosine_f64 :: proc(a, b: []f32) -> f64 {
	dot, na, nb: f64
	for i in 0 ..< len(a) {
		dot += f64(a[i]) * f64(b[i])
		na += f64(a[i]) * f64(a[i])
		nb += f64(b[i]) * f64(b[i])
	}
	return dot / (math.sqrt(na) * math.sqrt(nb) + 1e-9)
}

// Every dim from tiny through past several vector widths, plus odd tails, so
// both the vector body and the scalar remainder are exercised.
@(private = "file")
COSINE_TEST_DIMS :: [?]int{1, 3, 7, 8, 9, 15, 16, 17, 31, 32, 33, 67, 768}

@(test)
test_cpu_cosine_matches_f64_oracle :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	c := cpu_strategy()
	n_queries, n_docs := 3, 11
	for dim in COSINE_TEST_DIMS {
		queries := make([]f32, n_queries * dim, context.temp_allocator)
		docs := make([]f32, n_docs * dim, context.temp_allocator)
		for i in 0 ..< len(queries) {
			queries[i] = f32((i * 37 + dim) % 23) / 11.0 - 1.0
		}
		for i in dim ..< len(docs) { // doc 0 stays the zero vector
			docs[i] = f32((i * 53 + dim) % 29) / 14.0 - 1.0
		}
		scores, ok := c.cosine_queries(queries, docs, n_queries, n_docs, dim, context.temp_allocator)
		testing.expectf(t, ok, "dim %d: declined", dim)
		if !ok {
			continue
		}
		for q in 0 ..< n_queries {
			for d in 0 ..< n_docs {
				want := cosine_f64(queries[q * dim:(q + 1) * dim], docs[d * dim:(d + 1) * dim])
				got := f64(scores[q * n_docs + d])
				testing.expectf(t, abs(got - want) < 1e-5, "dim %d q %d doc %d: got %v want %v", dim, q, d, got, want)
			}
		}
	}
}

@(test)
test_cpu_cosine_single_query_matches_batch :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	c := cpu_strategy()
	dim, n_docs := 67, 9
	query := make([]f32, dim, context.temp_allocator)
	docs := make([]f32, n_docs * dim, context.temp_allocator)
	for i in 0 ..< dim {
		query[i] = f32(i % 5) - 2
	}
	for i in 0 ..< len(docs) {
		docs[i] = f32(i % 7) - 3
	}
	single, single_ok := c.cosine_query(query, docs, n_docs, dim, context.temp_allocator)
	batch, batch_ok := c.cosine_queries(query, docs, 1, n_docs, dim, context.temp_allocator)
	testing.expect(t, single_ok && batch_ok)
	if single_ok && batch_ok {
		for i in 0 ..< n_docs {
			testing.expect_value(t, single[i], batch[i])
		}
	}
}
