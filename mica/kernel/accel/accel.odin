// Accelerator strategies for Mica relation operators.
//
// Staged integration: strategies are values (CPU reference, Metal, later
// Vulkan/CUDA) invoked through explicit operator calls. The first kernel
// caller is negated membership over one or two key columns
// (`negated_absent_packed` in `rules_columnar.odin`), mirroring the Rust query
// engine's membership acceleration
// (`crates/relation-kernel/src/batch.rs`). Cosine scoring is exposed through
// `cosine_top_k` for retrieval use; no runtime computed-relation caller yet.
// Benchmarks measure potential speedups; only wired paths realize them.
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
	// Two-key membership (optional; nil declines). Each side is two columns;
	// the right pairs (right_a[i], right_b[i]) are sorted-unique
	// lexicographically. selected[i] = (left pair i in right) == keep_matches.
	membership_select2: proc(left_a, left_b, right_a, right_b: []u64, keep_matches: bool, allocator: mem.Allocator) -> (selected: []bool, ok: bool),
	// Equality join over one or two key columns per side (optional; nil
	// declines). `right` is sorted lexicographically (duplicates allowed) and
	// right_rows[j] is sorted entry j's source row. Returns every (left row i,
	// right_rows[j]) with equal keys, ordered by i then j.
	join_equality:   proc(left, right: [][]u64, right_rows: []u32, allocator: mem.Allocator) -> (left_out, right_out: []u32, ok: bool),
	// Fewest probes for which the strategy's join beats the kernel's CPU hash
	// join. Zero: the kernel never offers the join (the CPU reference).
	join_min_probes: int,

	// Residency (optional; nil declines). A prepared input is copied once into
	// strategy-owned storage (device memory on a GPU) and reused across calls,
	// so repeated probes of one column or queries of one document matrix pay
	// the upload once. Call through `prepare_column`, `prepare_docs`,
	// `membership_select_prepared`, `cosine_queries_prepared` and
	// `release_prepared`, which validate before reaching these.
	prepare_column:             proc(sorted_unique: []u64) -> (handle: rawptr, ok: bool),
	// Fewest probes for which a prepared (device-resident) column pays for its
	// upload. Zero: never prepare, whatever prepare_column is (the CPU
	// strategies, where a "prepared" copy is just a second copy).
	resident_min_probes:        int,
	membership_select_prepared: proc(left: []u64, column: rawptr, rows: int, keep_matches: bool, allocator: mem.Allocator) -> (selected: []bool, ok: bool),
	prepare_docs:               proc(docs: []f32, n_docs: int, dim: int) -> (handle: rawptr, ok: bool),
	cosine_queries_prepared:    proc(queries: []f32, n_queries: int, docs: rawptr, n_docs: int, dim: int, allocator: mem.Allocator) -> (scores: []f32, ok: bool),
	release:                    proc(handle: rawptr, kind: Prepared_Kind),
}

// Why an operator declined. Strategies set it before every `ok = false`
// return and clear it on success; the kernel's placement layer reads it to
// count outcomes by reason.
Decline :: enum u8 {
	None,
	Below_Threshold,
	Busy,
	Unsupported,
	Unavailable,
	Failed,
}

// Thread-local: operators run on whichever thread calls them.
@(thread_local, private)
last_decline: Decline

last_decline_reason :: proc() -> Decline {
	return last_decline
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
		membership_select2 = cpu_membership_select2,
		join_equality = cpu_join_equality,
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

// Two key columns whose pairs are strictly ascending lexicographically.
is_sorted_unique_pairs :: proc(a, b: []u64) -> bool {
	if len(a) != len(b) {
		return false
	}
	for i in 1 ..< len(a) {
		if a[i - 1] > a[i] || (a[i - 1] == a[i] && b[i - 1] >= b[i]) {
			return false
		}
	}
	return true
}

// Declined: the strategy declined (last_decline_reason says why). Invalid:
// it returned a result of the wrong shape.
Operator_Result :: enum u8 {
	Completed,
	Declined,
	Invalid,
}

Membership_Result :: Operator_Result

// Membership as a selection: the indexes, increasing, of the left rows whose
// key is in `right` (keep_matches) or absent from it (!keep_matches). Each side
// has one column per key position (1 or 2); `right` is sorted-unique,
// lexicographically for two columns.
membership_selection :: proc(
	s: Strategy,
	left, right: [][]u64,
	keep_matches: bool,
	allocator := context.allocator,
) -> (
	selection: []u32,
	result: Operator_Result,
) {
	if len(left) < 1 || len(left) > 2 || len(right) != len(left) {
		last_decline = .Unsupported
		return nil, .Declined
	}
	n := len(left[0])
	selected: []bool
	ok: bool
	if len(left) == 1 {
		selected, ok = s.membership_select(left[0], right[0], keep_matches, allocator)
	} else {
		if s.membership_select2 == nil || len(left[1]) != n || !is_sorted_unique_pairs(right[0], right[1]) {
			last_decline = .Unsupported
			return nil, .Declined
		}
		selected, ok = s.membership_select2(left[0], left[1], right[0], right[1], keep_matches, allocator)
	}
	return selection_from_mask(selected, ok, n, allocator)
}

// `membership_selection` against a prepared (resident) single-key column.
membership_selection_prepared :: proc(
	s: Strategy,
	left: []u64,
	p: Prepared,
	keep_matches: bool,
	allocator := context.allocator,
) -> (
	[]u32,
	Operator_Result,
) {
	selected, ok := membership_select_prepared(s, left, p, keep_matches, allocator)
	return selection_from_mask(selected, ok, len(left), allocator)
}

@(private)
selection_from_mask :: proc(selected: []bool, ok: bool, n: int, allocator: mem.Allocator) -> ([]u32, Operator_Result) {
	if !ok {
		return nil, .Declined
	}
	if len(selected) != n {
		return nil, .Invalid
	}
	count := 0
	for keep in selected {
		if keep {
			count += 1
		}
	}
	out := make([]u32, count, allocator)
	write := 0
	for keep, i in selected {
		if keep {
			out[write] = u32(i)
			write += 1
		}
	}
	return out, .Completed
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
		last_decline = .Unsupported
		return {}, false
	}
	// A strategy may set a more specific reason (Unavailable) on failure.
	last_decline = .Failed
	handle := s.prepare_column(sorted_unique) or_return
	last_decline = .None
	return Prepared{strategy = s.name, kind = .Column, handle = handle, rows = len(sorted_unique)}, true
}

// Copies an n_docs x dim document matrix into strategy-owned storage for
// repeated cosine queries.
prepare_docs :: proc(s: Strategy, docs: []f32, n_docs: int, dim: int) -> (prepared: Prepared, ok: bool) {
	if s.prepare_docs == nil || n_docs < 1 || dim < 1 || len(docs) < n_docs * dim {
		last_decline = .Unsupported
		return {}, false
	}
	last_decline = .Failed
	handle := s.prepare_docs(docs[:n_docs * dim], n_docs, dim) or_return
	last_decline = .None
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

join_key_cmp :: #force_inline proc(left: [][]u64, i: int, right: [][]u64, j: int) -> int {
	for c in 0 ..< len(left) {
		a, b := left[c][i], right[c][j]
		if a < b {
			return -1
		}
		if a > b {
			return 1
		}
	}
	return 0
}

// First sorted position whose key is not below left key i.
join_lower_bound :: proc(left: [][]u64, i: int, right: [][]u64) -> int {
	lo, hi := 0, len(right[0])
	for lo < hi {
		mid := lo + ((hi - lo) >> 1)
		if join_key_cmp(left, i, right, mid) > 0 {
			lo = mid + 1
		} else {
			hi = mid
		}
	}
	return lo
}

// Key columns whose rows are lexicographically non-decreasing.
is_sorted_keys :: proc(columns: [][]u64) -> bool {
	for j in 1 ..< len(columns[0]) {
		if join_key_cmp(columns, j - 1, columns, j) > 0 {
			return false
		}
	}
	return true
}

// Equality join on the strategy, validated: every (left row, right row) pair
// with equal keys, ordered by left row. Declined: the strategy has no join or
// declined (last_decline_reason says why). Invalid: it returned pairs of the
// wrong shape, out of range, or out of order.
join_pairs :: proc(
	s: Strategy,
	left, right: [][]u64,
	right_rows: []u32,
	allocator := context.allocator,
) -> (
	left_out, right_out: []u32,
	result: Operator_Result,
) {
	if s.join_equality == nil || len(left) < 1 || len(left) > 2 || len(right) != len(left) {
		last_decline = .Unsupported
		return nil, nil, .Declined
	}
	n, m := len(left[0]), len(right_rows)
	for column in left {
		if len(column) != n {
			last_decline = .Unsupported
			return nil, nil, .Declined
		}
	}
	for column in right {
		if len(column) != m {
			last_decline = .Unsupported
			return nil, nil, .Declined
		}
	}
	if !is_sorted_keys(right) {
		last_decline = .Unsupported
		return nil, nil, .Declined
	}
	if n == 0 || m == 0 {
		last_decline = .None
		return nil, nil, .Completed
	}
	l, r, ok := s.join_equality(left, right, right_rows, allocator)
	if !ok {
		return nil, nil, .Declined
	}
	if len(l) != len(r) {
		return nil, nil, .Invalid
	}
	previous := 0
	for x in l {
		if int(x) >= n || int(x) < previous {
			return nil, nil, .Invalid
		}
		previous = int(x)
	}
	// Right indexes must be source rows the caller supplied: the kernel
	// gathers relation columns by them.
	max_row := u32(0)
	for row in right_rows {
		max_row = max(max_row, row)
	}
	for x in r {
		if x > max_row {
			return nil, nil, .Invalid
		}
	}
	return l, r, .Completed
}
