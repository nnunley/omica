// Accelerator strategies for Mica relation operators.
//
// Staged integration: strategies are values (CPU reference, Metal, later
// Vulkan/CUDA) invoked through explicit operator calls. The first kernel
// caller is the negated single-column atom fast path
// (`try_negated_atom_batch` in `rules.odin`), mirroring the Rust query
// engine's membership acceleration
// (`crates/relation-kernel/src/batch.rs`). Cosine scoring is exposed through
// `cosine_top_k` for retrieval use; no runtime computed-relation caller yet.
// Everything else in rule evaluation stays row-wise until the columnar
// projection lands. Benchmarks measure potential speedups; only wired paths
// realize them.
//
// The contract mirrors the Rust `RelationAccelerator` trait
// (`crates/relation-kernel/src/execution.rs`): optional, row-threshold gated,
// decline-on-anything-unexpected. The kernel must always be able to complete
// the operation on CPU.
package accel

import "core:mem"
import "core:sync"

// One operator set: availability probe plus the accelerated operators. Every
// operator returns `ok=false` to decline, in which case the caller runs its
// CPU path. Operators allocate results with the caller's allocator;
// short-lived temporaries come from `context.temp_allocator`.
Strategy :: struct {
	name:              string,
	available:         proc() -> bool,
	membership_select: proc(left: []u64, right_sorted_unique: []u64, keep_matches: bool, allocator: mem.Allocator) -> (selected: []bool, ok: bool),
	cosine_query:      proc(query: []f32, docs: []f32, n_docs: int, dim: int, allocator: mem.Allocator) -> (scores: []f32, ok: bool),
	// Batched cosine: n_queries x dim against n_docs x dim in one dispatch.
	// This is the fast path (one thread per query/doc pair on Metal); the
	// single-query operator wraps it with n_queries=1.
	cosine_queries: proc(queries: []f32, docs: []f32, n_queries: int, n_docs: int, dim: int, allocator: mem.Allocator) -> (scores: []f32, ok: bool),

	// Residency (optional; nil declines). A prepared input is copied once into
	// strategy-owned storage (device memory on a GPU) and reused across calls,
	// so repeated probes of one column or queries of one document matrix pay
	// the upload once. Call through `prepare_column`, `prepare_docs`,
	// `membership_select_prepared`, `cosine_queries_prepared` and
	// `release_prepared`, which validate before reaching these.
	prepare_column:             proc(sorted_unique: []u64) -> (handle: rawptr, ok: bool),
	membership_select_prepared: proc(left: []u64, column: rawptr, rows: int, keep_matches: bool, allocator: mem.Allocator) -> (selected: []bool, ok: bool),
	prepare_docs:               proc(docs: []f32, n_docs: int, dim: int) -> (handle: rawptr, ok: bool),
	cosine_queries_prepared:    proc(queries: []f32, n_queries: int, docs: rawptr, n_docs: int, dim: int, allocator: mem.Allocator) -> (scores: []f32, ok: bool),
	release:                    proc(handle: rawptr, kind: Prepared_Kind),
}

Prepared_Kind :: enum u8 {
	None,
	Column,
	Docs,
}

// A strategy-owned copy of a column or document matrix. Valid until
// `release_prepared`; usable only with the strategy that prepared it (by
// name) and only as the kind it was prepared as. The zero value is empty.
Prepared :: struct {
	strategy: string,
	kind:     Prepared_Kind,
	handle:   rawptr,
	rows:     int,
	dim:      int,
}

// Reference CPU operator set. Always available, handles any input size.
cpu_strategy :: proc() -> Strategy {
	return Strategy {
		name = "cpu",
		available = cpu_available,
		membership_select = cpu_membership_select,
		cosine_query = cpu_cosine_query,
		cosine_queries = cpu_cosine_queries,
		prepare_column = cpu_prepare_column,
		membership_select_prepared = cpu_membership_select_prepared,
		prepare_docs = cpu_prepare_docs,
		cosine_queries_prepared = cpu_cosine_queries_prepared,
		release = cpu_release,
	}
}

@(private)
active_mutex: sync.Mutex

@(private)
active_data: Strategy

@(private)
active_ready: bool

// The strategy production code dispatches through. Defaults to CPU;
// `select_strategy` overrides it for the process. GPU backends are strictly
// opt-in: call `use_metal()` on Darwin (later: Vulkan/CUDA constructors).
// The registry is mutex-guarded: the scheduler runs one task per worker
// thread and installs the strategy before workers start; the mutex makes a
// late install race fail safe (CPU fallback) instead of tearing.
active_strategy :: proc() -> Strategy {
	sync.mutex_lock(&active_mutex)
	defer sync.mutex_unlock(&active_mutex)
	if !active_ready {
		active_data = cpu_strategy()
		active_ready = true
	}
	return active_data
}

// Installs the strategy production code dispatches through. Serialized
// against concurrent readers; install before workers start.
select_strategy :: proc(s: Strategy) {
	sync.mutex_lock(&active_mutex)
	active_data = s
	active_ready = true
	sync.mutex_unlock(&active_mutex)
}

// Production dispatches through the CPU reference only.
use_cpu :: proc() {
	select_strategy(cpu_strategy())
}

// Membership probe dispatched through the active strategy.
membership_select :: proc(
	left: []u64,
	right_sorted_unique: []u64,
	keep_matches: bool,
	allocator := context.allocator,
) -> (
	selected: []bool,
	ok: bool,
) {
	s := active_strategy()
	return s.membership_select(left, right_sorted_unique, keep_matches, allocator)
}

// Cosine similarity dispatched through the active strategy.
cosine_query :: proc(
	query: []f32,
	docs: []f32,
	n_docs: int,
	dim: int,
	allocator := context.allocator,
) -> (
	scores: []f32,
	ok: bool,
) {
	s := active_strategy()
	return s.cosine_query(query, docs, n_docs, dim, allocator)
}

// Batched cosine dispatched through the active strategy.
cosine_queries :: proc(
	queries: []f32,
	docs: []f32,
	n_queries: int,
	n_docs: int,
	dim: int,
	allocator := context.allocator,
) -> (
	scores: []f32,
	ok: bool,
) {
	s := active_strategy()
	return s.cosine_queries(queries, docs, n_queries, n_docs, dim, allocator)
}

// Encoded u64 column sort order expected by the membership operator: ascending.
is_sorted_unique :: proc(rows: []u64) -> bool {
	if len(rows) < 2 {
		return true
	}
	for i in 1 ..< len(rows) {
		if rows[i - 1] >= rows[i] {
			return false
		}
	}
	return true
}

// Copies a sorted-unique column into strategy-owned storage for repeated
// membership probes. Declines an unsorted column or a strategy without
// residency.
prepare_column :: proc(s: Strategy, sorted_unique: []u64) -> (prepared: Prepared, ok: bool) {
	if s.prepare_column == nil || !is_sorted_unique(sorted_unique) {
		return {}, false
	}
	handle := s.prepare_column(sorted_unique) or_return
	return Prepared{strategy = s.name, kind = .Column, handle = handle, rows = len(sorted_unique)}, true
}

// Copies an n_docs x dim document matrix into strategy-owned storage for
// repeated cosine queries.
prepare_docs :: proc(s: Strategy, docs: []f32, n_docs: int, dim: int) -> (prepared: Prepared, ok: bool) {
	if s.prepare_docs == nil || n_docs < 1 || dim < 1 || len(docs) < n_docs * dim {
		return {}, false
	}
	handle := s.prepare_docs(docs[:n_docs * dim], n_docs, dim) or_return
	return Prepared{strategy = s.name, kind = .Docs, handle = handle, rows = n_docs, dim = dim}, true
}

@(private)
prepared_usable :: proc(s: Strategy, p: Prepared, kind: Prepared_Kind) -> bool {
	return p.handle != nil && p.kind == kind && p.strategy == s.name
}

// Membership of each probe in a prepared column; same result as
// `membership_select` on the column it was prepared from.
membership_select_prepared :: proc(
	s: Strategy,
	left: []u64,
	column: Prepared,
	keep_matches: bool,
	allocator := context.allocator,
) -> (
	selected: []bool,
	ok: bool,
) {
	if s.membership_select_prepared == nil || !prepared_usable(s, column, .Column) {
		return nil, false
	}
	return s.membership_select_prepared(left, column.handle, column.rows, keep_matches, allocator)
}

// Cosine of n_queries x dim queries against prepared documents; same result
// as `cosine_queries` on the matrix they were prepared from.
cosine_queries_prepared :: proc(
	s: Strategy,
	queries: []f32,
	n_queries: int,
	docs: Prepared,
	allocator := context.allocator,
) -> (
	scores: []f32,
	ok: bool,
) {
	if s.cosine_queries_prepared == nil || !prepared_usable(s, docs, .Docs) {
		return nil, false
	}
	if n_queries < 1 || len(queries) < n_queries * docs.dim {
		return nil, false
	}
	return s.cosine_queries_prepared(queries, n_queries, docs.handle, docs.rows, docs.dim, allocator)
}

// Frees a prepared input and zeroes it. Safe on the zero value.
release_prepared :: proc(s: Strategy, p: ^Prepared) {
	if p.handle != nil && s.release != nil && p.strategy == s.name {
		s.release(p.handle, p.kind)
	}
	p^ = {}
}
