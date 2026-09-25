// Linux CUDA strategy: the operator set backed by NVIDIA GPUs, a sibling of
// the Darwin Metal strategy against the same `Strategy` shape.
#+build linux
package accel

import "core:mem"

// The CUDA operator set, on the device chosen with `cuda_select_device`
// (device 0 by default). Gated at runtime: without a driver, device, or NVRTC
// `available` is false and every operator declines.
cuda_strategy :: proc() -> Strategy {
	return Strategy {
		name = "cuda",
		available = cuda_available_impl,
		membership_select = cuda_membership_select,
		cosine_query = cuda_cosine_query,
		cosine_queries = cuda_cosine_queries,
		prepare_column = cuda_prepare_column_impl,
		membership_select_prepared = cuda_membership_select_prepared_impl,
		prepare_docs = cuda_prepare_docs_impl,
		cosine_queries_prepared = cuda_cosine_queries_prepared_impl,
		release = cuda_release_impl,
	}
}

cuda_membership_select :: proc(
	left: []u64,
	right_sorted_unique: []u64,
	keep_matches: bool,
	allocator: mem.Allocator,
) -> (
	selected: []bool,
	ok: bool,
) {
	return cuda_membership_select_impl(left, right_sorted_unique, keep_matches, allocator)
}

cuda_cosine_query :: proc(
	query: []f32,
	docs: []f32,
	n_docs: int,
	dim: int,
	allocator: mem.Allocator,
) -> (
	scores: []f32,
	ok: bool,
) {
	return cuda_cosine_query_impl(query, docs, n_docs, dim, allocator)
}

cuda_cosine_queries :: proc(
	queries: []f32,
	docs: []f32,
	n_queries: int,
	n_docs: int,
	dim: int,
	allocator: mem.Allocator,
) -> (
	scores: []f32,
	ok: bool,
) {
	return cuda_cosine_queries_impl(queries, docs, n_queries, n_docs, dim, allocator)
}

// Opts production dispatch into CUDA, declining to CPU per operator.
use_cuda :: proc() {
	select_strategy(cuda_strategy())
}
