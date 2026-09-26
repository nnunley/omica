// Batched NearestEmbedding (docs/accel-engine-design.md §4): every key row of
// a rule step at once. Each index's member vectors are packed once per call;
// the queries of one dimension against one index are scored in one
// `cosine_queries` call in f32; each query's best `limit + 32` subjects are
// re-scored in f64 exactly as the row scanner does, then sorted and cut, so
// results match `nearest_embedding_scan` unless f32 error exceeds the gap to
// the 32nd extra candidate.
package mica_runtime

import "base:runtime"
import "core:mem/virtual"
import "core:slice"
import "core:sync"
import accel "../kernel/accel"
import k "../kernel"
import v "../var"

// Extra candidates re-scored in f64 beyond `limit`.
NEAREST_RESCORE_MARGIN :: 32
// Subjects whose f32 score is within this of the window's last score are
// re-scored too, so f32 ties and strategy-dependent f32 noise cannot push the
// f64 winner out of the window.
NEAREST_TIE_EPSILON :: f32(1e-4)

@(private)
Nearest_Member :: struct {
	subject: v.Value,
	values:  []v.Value, // the stored vector, for exact f64 re-scoring
	vector:  []f32,
}

// Members of one index with a usable vector: exactly one subject and one
// list vector, every entry numeric, non-zero norm (the row scanner's cosine
// rejects anything else).
@(private)
nearest_index_members :: proc(source: ^k.Relation_Source, index: v.Value, contains_id, embedding_of_id, vector_id: k.Relation_ID) -> []Nearest_Member {
	members := make([dynamic]v.Tuple, context.temp_allocator)
	k.relation_source_scan_into(source, contains_id, []v.Binding{v.binding_of(index), {}}, &members)
	out := make([dynamic]Nearest_Member, 0, len(members), context.temp_allocator)
	for member in members {
		embedding := v.tuple_values(member)[1]
		subject_rows := make([dynamic]v.Tuple, context.temp_allocator)
		vector_rows := make([dynamic]v.Tuple, context.temp_allocator)
		k.relation_source_scan_into(source, embedding_of_id, []v.Binding{v.binding_of(embedding), {}}, &subject_rows)
		k.relation_source_scan_into(source, vector_id, []v.Binding{v.binding_of(embedding), {}}, &vector_rows)
		if len(subject_rows) != 1 || len(vector_rows) != 1 {
			continue
		}
		values, ok := v.value_as_list(v.tuple_values(vector_rows[0])[1])
		if !ok || len(values) == 0 {
			continue
		}
		vector := make([]f32, len(values), context.temp_allocator)
		norm := f64(0)
		numeric := true
		for value, i in values {
			x, x_ok := numeric_value(value)
			if !x_ok {
				numeric = false
				break
			}
			vector[i] = f32(x)
			norm += x * x
		}
		if !numeric || norm == 0 {
			continue
		}
		append(&out, Nearest_Member{subject = v.tuple_values(subject_rows[0])[1], values = values, vector = vector})
	}
	return out[:]
}

@(private)
Nearest_Query :: struct {
	row:    int,
	values: []v.Value,
	vector: []f32,
	limit:  int,
}

nearest_embedding_batch_scan :: proc(
	user: rawptr,
	source: ^k.Relation_Source,
	keys: [][]v.Value,
	count: int,
	out: ^k.Column_Sink,
	input_rows: ^[dynamic]u32,
) -> k.Kernel_Error {
	if len(keys) < 3 || keys[0] == nil || keys[1] == nil || keys[2] == nil {
		return .Computed_Binding_Required
	}
	// Validate every key row first, as the row scanner would for each.
	for i in 0 ..< count {
		_, query_ok := v.value_as_list(keys[1][i])
		limit, limit_ok := v.value_as_int(keys[2][i])
		if !query_ok || !limit_ok || limit < 0 {
			return .Arity_Mismatch
		}
	}
	contains_id, has_contains := computed_relation_id(source, "VectorIndexContains")
	embedding_of_id, has_embedding_of := computed_relation_id(source, "EmbeddingOf")
	vector_id, has_vector := computed_relation_id(source, "EmbeddingVector")
	if !has_contains || !has_embedding_of || !has_vector {
		return .None
	}
	version := source.snapshot != nil ? source.snapshot.version : source.transaction.base.version

	// Results per key row, emitted in key-row order at the end.
	results := make([][dynamic]Nearest_Candidate, count, context.temp_allocator)
	done := make([]bool, count, context.temp_allocator)
	for first in 0 ..< count {
		if done[first] {
			continue
		}
		index := keys[0][first]
		members, pin := nearest_members_cached(source, index, contains_id, embedding_of_id, vector_id)
		defer nearest_cache_unpin(pin)
		grouped := nearest_group_subjects(members)
		// Every key row on this index, by query dimension.
		by_dim := make(map[int][dynamic]Nearest_Query, context.temp_allocator)
		for i in first ..< count {
			if done[i] || !v.value_eq(keys[0][i], index) {
				continue
			}
			done[i] = true
			values, _ := v.value_as_list(keys[1][i])
			limit, _ := v.value_as_int(keys[2][i])
			if limit == 0 || len(values) == 0 {
				continue
			}
			vector := make([]f32, len(values), context.temp_allocator)
			norm := f64(0)
			numeric := true
			for value, j in values {
				x, x_ok := numeric_value(value)
				if !x_ok {
					numeric = false
					break
				}
				vector[j] = f32(x)
				norm += x * x
			}
			if !numeric || norm == 0 {
				continue
			}
			queries := by_dim[len(values)]
			append(&queries, Nearest_Query{row = i, values = values, vector = vector, limit = int(limit)})
			by_dim[len(values)] = queries
		}
		for dim, queries in by_dim {
			dm := nearest_matrix(pin, members, dim)
			if len(dm.doc_members) == 0 {
				continue
			}
			query_matrix := make([]f32, len(queries) * dim, context.temp_allocator)
			for q, qi in queries {
				copy(query_matrix[qi * dim:], q.vector)
			}
			scores := nearest_cosine_scores(query_matrix, dm, len(queries), dim, pin != nil)
			n_docs := len(dm.doc_members)
			for q, qi in queries {
				results[q.row] = nearest_rank(q, members, &grouped, dm.doc_members, scores[qi * n_docs:(qi + 1) * n_docs])
			}
		}
	}

	for i in 0 ..< count {
		for candidate in results[i] {
			score, score_ok := v.value_float(f32(candidate.score))
			if !score_ok {
				continue
			}
			k.column_sink_append_tuple(
				out,
				v.tuple_new(context.temp_allocator, []v.Value{keys[0][i], keys[1][i], keys[2][i], candidate.subject, score, computed_int(version)}),
			)
			append(input_rows, u32(i))
		}
	}
	return .None
}

// The members of one dimension as a document matrix, with each document's
// member index. Cached on the (pinned) entry when there is one, with at most
// one resident copy made by the strategy that last scored it.
@(private)
Nearest_Matrix :: struct {
	dim:         int,
	docs:        []f32,
	doc_members: []int,
	prepared:    accel.Prepared,
	strategy:    accel.Strategy,
	// Scoring calls using `prepared` right now; it is not released or
	// replaced while any are (guarded by the cache lock).
	users:       int,
}

@(private)
nearest_build_matrix :: proc(members: []Nearest_Member, dim: int, allocator: runtime.Allocator) -> Nearest_Matrix {
	n := 0
	for member in members {
		if len(member.vector) == dim {
			n += 1
		}
	}
	dm := Nearest_Matrix {
		dim         = dim,
		docs        = make([]f32, n * dim, allocator),
		doc_members = make([]int, n, allocator),
	}
	d := 0
	for member, m in members {
		if len(member.vector) == dim {
			copy(dm.docs[d * dim:], member.vector)
			dm.doc_members[d] = m
			d += 1
		}
	}
	return dm
}

// The matrix for `dim`: the entry's cached one (built on first use in the
// entry's arena), or a per-call one in temp when uncached.
@(private)
nearest_matrix :: proc(pin: ^Nearest_Cache_Entry, members: []Nearest_Member, dim: int) -> ^Nearest_Matrix {
	if pin == nil {
		dm := new(Nearest_Matrix, context.temp_allocator)
		dm^ = nearest_build_matrix(members, dim, context.temp_allocator)
		return dm
	}
	sync.mutex_lock(&nearest_cache.lock)
	defer sync.mutex_unlock(&nearest_cache.lock)
	for m in pin.matrices {
		if m.dim == dim {
			return m
		}
	}
	// The entry's arena owns what the entry keeps (see nearest_cache).
	alloc := virtual.arena_allocator(pin.arena)
	dm := new(Nearest_Matrix, alloc)
	dm^ = nearest_build_matrix(members, dim, alloc)
	if pin.matrices == nil {
		pin.matrices = make([dynamic]^Nearest_Matrix, alloc)
	}
	append(&pin.matrices, dm)
	return dm
}

@(thread_local, private)
nearest_docs_prepares: int

// Resident document copies made by the calling thread (tests).
nearest_docs_prepares_this_thread :: proc() -> int {
	return nearest_docs_prepares
}

// Cosine scores (queries x docs, query-major) in f32 on the active strategy,
// against the matrix's resident copy when the strategy supports one (made on
// first use, replacing another strategy's); a decline or a result of the
// wrong length falls back to the CPU reference. Every call is counted under
// .Cosine.
@(private)
nearest_cosine_scores :: proc(queries: []f32, dm: ^Nearest_Matrix, n_queries, dim: int, cached: bool) -> []f32 {
	docs, n_docs := dm.docs, len(dm.doc_members)
	strategy := accel.active_strategy()
	scores: []f32
	ok: bool
	if prepared, resident := nearest_matrix_acquire(dm, strategy, cached); resident {
		scores, ok = accel.cosine_queries_prepared(strategy, queries, n_queries, prepared, context.temp_allocator)
		nearest_matrix_release_use(dm)
	} else {
		scores, ok = strategy.cosine_queries(queries, docs, n_queries, n_docs, dim, context.temp_allocator)
	}
	if ok && len(scores) == n_queries * n_docs {
		k.placement_record(.Cosine, .Completed)
		return scores
	}
	if ok {
		k.placement_record(.Cosine, .Invalid_Result)
	} else {
		k.placement_record_decline(.Cosine)
	}
	scores, ok = accel.cpu_strategy().cosine_queries(queries, docs, n_queries, n_docs, dim, context.temp_allocator)
	assert(ok, "CPU cosine reference declined valid input")
	k.placement_record(.Cosine, .Cpu_Fallback)
	return scores
}

// Members of one index grouped by subject: dense subject ids in first-seen
// order, each member's id, and each subject's members.
@(private)
Nearest_Subjects :: struct {
	subjects:   []v.Value,
	subject_of: []int,
	members_of: [][dynamic]int,
}

@(private)
nearest_group_subjects :: proc(members: []Nearest_Member) -> Nearest_Subjects {
	ids := make(map[v.Value]int, len(members), context.temp_allocator)
	subjects := make([dynamic]v.Value, 0, len(members), context.temp_allocator)
	subject_of := make([]int, len(members), context.temp_allocator)
	for m, i in members {
		id, found := ids[m.subject]
		if !found {
			id = len(subjects)
			ids[m.subject] = id
			append(&subjects, m.subject)
		}
		subject_of[i] = id
	}
	members_of := make([][dynamic]int, len(subjects), context.temp_allocator)
	for id, i in subject_of {
		append(&members_of[id], i)
	}
	return Nearest_Subjects{subjects = subjects[:], subject_of = subject_of, members_of = members_of}
}

// One query's results: best f32 score per subject, the best `limit + margin`
// subjects (kept in an insertion-sorted window) re-scored in f64 over the
// subject's vectors of the query's dimension, sorted and cut.
@(private)
nearest_rank :: proc(q: Nearest_Query, members: []Nearest_Member, grouped: ^Nearest_Subjects, doc_members: []int, scores: []f32) -> [dynamic]Nearest_Candidate {
	n_subjects := len(grouped.subjects)
	best := make([]f32, n_subjects, context.temp_allocator)
	seen := make([]bool, n_subjects, context.temp_allocator)
	for m, d in doc_members {
		id := grouped.subject_of[m]
		if !seen[id] || scores[d] > best[id] {
			best[id], seen[id] = scores[d], true
		}
	}
	// a ranks before b: higher score, then lower subject.
	before :: proc(grouped: ^Nearest_Subjects, best: []f32, a, b: int) -> bool {
		if best[a] != best[b] {
			return best[a] > best[b]
		}
		return v.value_cmp(grouped.subjects[a], grouped.subjects[b]) == .Less
	}
	window := q.limit + NEAREST_RESCORE_MARGIN
	top := make([dynamic]int, 0, window + 1, context.temp_allocator)
	for id in 0 ..< n_subjects {
		if !seen[id] {
			continue
		}
		if len(top) == window && !before(grouped, best, id, top[window - 1]) {
			continue
		}
		at := len(top)
		for at > 0 && before(grouped, best, id, top[at - 1]) {
			at -= 1
		}
		inject_at(&top, at, id)
		if len(top) > window {
			pop(&top)
		}
	}
	if len(top) > 0 {
		in_top := make([]bool, n_subjects, context.temp_allocator)
		for id in top {
			in_top[id] = true
		}
		cutoff := best[top[len(top) - 1]] - NEAREST_TIE_EPSILON
		for id in 0 ..< n_subjects {
			if seen[id] && !in_top[id] && best[id] >= cutoff {
				append(&top, id)
			}
		}
	}
	dim := len(q.values)
	exact := make([dynamic]Nearest_Candidate, 0, len(top), context.temp_allocator)
	for id in top {
		score := f64(0)
		found := false
		for m in grouped.members_of[id] {
			if len(members[m].vector) != dim {
				continue
			}
			if s, ok := cosine_similarity(q.values, members[m].values); ok && (!found || s > score) {
				score, found = s, true
			}
		}
		if found {
			append(&exact, Nearest_Candidate{subject = grouped.subjects[id], score = score})
		}
	}
	slice.sort_by(exact[:], proc(a, b: Nearest_Candidate) -> bool {
		if a.score != b.score {
			return a.score > b.score
		}
		return v.value_cmp(a.subject, b.subject) == .Less
	})
	if len(exact) > q.limit {
		resize(&exact, q.limit)
	}
	// Subjects point into the (pinned) cache entry, which may be evicted once
	// this index is done; results flow into the evaluation's derived rows, so
	// they are copied into context.allocator, the evaluation arena.
	for &c in exact {
		c.subject = v.value_deep_copy(context.allocator, c.subject)
	}
	return exact
}

// --- Packed-index cache ------------------------------------------------------
//
// A few indexes' usable members, keyed by the index value and the serials of
// the three backing blocks (process-unique, so no reference is held and a
// commit that leaves those relations alone keeps the entry). Members are deep
// copied into the entry's own arena. Entries in use are pinned and never
// evicted. Transactions (which may hold uncommitted writes), heap-valued index
// keys, and readers that cannot read every backing relation bypass the cache.

NEAREST_CACHE_ENTRIES :: 4

@(private)
Nearest_Cache_Entry :: struct {
	index:    v.Value,
	serials:  [3]u64,
	arena:    ^virtual.Arena,
	members:  []Nearest_Member,
	// Per-dimension document matrices, built on first use (under the lock).
	matrices: [dynamic]^Nearest_Matrix,
	used:     u64,
	pins:     int,
}

// A resident copy of a cached matrix on `strategy` for one scoring call,
// made on first use. Fails (the caller scores from the host matrix) when the
// matrix is not cached, the strategy cannot prepare documents, or another
// strategy's copy is in use, or the strategy has no residency threshold. Pair
// every success with nearest_matrix_release_use.
@(private)
nearest_matrix_acquire :: proc(dm: ^Nearest_Matrix, strategy: accel.Strategy, cached: bool) -> (accel.Prepared, bool) {
	// A strategy without a residency threshold (the CPU ones) would only copy
	// the host matrix the entry already holds.
	if !cached || strategy.prepare_docs == nil || strategy.resident_min_probes <= 0 || len(dm.doc_members) == 0 {
		return {}, false
	}
	sync.mutex_lock(&nearest_cache.lock)
	defer sync.mutex_unlock(&nearest_cache.lock)
	if dm.prepared.handle != nil && dm.prepared.strategy == strategy.name {
		dm.users += 1
		return dm.prepared, true
	}
	if dm.users > 0 {
		return {}, false
	}
	accel.release_prepared(dm.strategy, &dm.prepared)
	prepared, ok := accel.prepare_docs(strategy, dm.docs, len(dm.doc_members), dm.dim)
	if !ok {
		return {}, false
	}
	dm.prepared, dm.strategy = prepared, strategy
	dm.users = 1
	nearest_docs_prepares += 1
	return prepared, true
}

@(private)
nearest_matrix_release_use :: proc(dm: ^Nearest_Matrix) {
	sync.mutex_lock(&nearest_cache.lock)
	dm.users -= 1
	sync.mutex_unlock(&nearest_cache.lock)
}

// Releases an entry's resident copies. Caller holds the cache lock.
@(private)
nearest_entry_release :: proc(e: ^Nearest_Cache_Entry) {
	for m in e.matrices {
		accel.release_prepared(m.strategy, &m.prepared)
	}
}

// The table is static storage, so an entry lives from insertion until
// eviction, across evaluations and worlds: its arena and the arena's header
// are process-lifetime allocations, owned by `allocator`. The scanner runs
// with context.allocator set to the evaluation arena, which must never own
// cache memory.
@(private)
nearest_cache: struct {
	lock:      sync.Mutex,
	entries:   [NEAREST_CACHE_ENTRIES]Nearest_Cache_Entry,
	clock:     u64,
	allocator: runtime.Allocator,
}

// The cache's owner allocator, chosen on first use (under the lock).
@(private)
nearest_cache_allocator :: proc() -> runtime.Allocator {
	if nearest_cache.allocator.procedure == nil {
		nearest_cache.allocator = runtime.heap_allocator()
	}
	return nearest_cache.allocator
}

@(thread_local, private)
nearest_builds: int

// Cache builds by the calling thread (tests).
nearest_cache_builds_this_thread :: proc() -> int {
	return nearest_builds
}

// Whether an active rule of `snapshot` derives rows of `relation`.
@(private)
nearest_relation_is_derived :: proc(snapshot: ^k.Snapshot, relation: k.Relation_ID) -> bool {
	for definition in snapshot.rules {
		if definition.active && definition.rule.head_relation == relation {
			return true
		}
	}
	return false
}

// The index's members, from the cache when possible. `pin` (possibly nil)
// must be passed to nearest_cache_unpin once the members are no longer used.
@(private)
nearest_members_cached :: proc(
	source: ^k.Relation_Source,
	index: v.Value,
	contains_id, embedding_of_id, vector_id: k.Relation_ID,
) -> (
	members: []Nearest_Member,
	pin: ^Nearest_Cache_Entry,
) {
	ids := [3]k.Relation_ID{contains_id, embedding_of_id, vector_id}
	cacheable := source.snapshot != nil && source.transaction == nil && v.value_is_immediate(index)
	serials: [3]u64
	if cacheable {
		for id, i in ids {
			if !k.authority_can_read(source.authority, id) {
				cacheable = false
				break
			}
			// The key covers only extensional blocks: rows a rule derives, or a
			// computed relation supplies, can change while every serial stays
			// the same, so such indexes are read fresh.
			if (source.kernel != nil && k.kernel_relation_is_computed(source.kernel, id)) || nearest_relation_is_derived(source.snapshot, id) {
				cacheable = false
				break
			}
			if block, ok := k.snapshot_relation_block(source.snapshot, id); ok {
				serials[i] = block.serial
			}
		}
	}
	if !cacheable {
		return nearest_index_members(source, index, contains_id, embedding_of_id, vector_id), nil
	}

	sync.mutex_lock(&nearest_cache.lock)
	nearest_cache.clock += 1
	for &e in nearest_cache.entries {
		if e.arena != nil && e.index == index && e.serials == serials {
			e.used = nearest_cache.clock
			e.pins += 1
			sync.mutex_unlock(&nearest_cache.lock)
			return e.members, &e
		}
	}
	sync.mutex_unlock(&nearest_cache.lock)

	built := nearest_index_members(source, index, contains_id, embedding_of_id, vector_id)
	if source.error != .None {
		return built, nil
	}
	nearest_builds += 1
	sync.mutex_lock(&nearest_cache.lock)
	owner := nearest_cache_allocator()
	sync.mutex_unlock(&nearest_cache.lock)
	arena := new(virtual.Arena, owner)
	if virtual.arena_init_growing(arena) != nil {
		free(arena, owner)
		return built, nil
	}
	alloc := virtual.arena_allocator(arena)
	owned := make([]Nearest_Member, len(built), alloc)
	for m, i in built {
		list := v.value_deep_copy(alloc, v.value_list(context.temp_allocator, m.values))
		values, _ := v.value_as_list(list)
		vector := make([]f32, len(m.vector), alloc)
		copy(vector, m.vector)
		owned[i] = Nearest_Member{subject = v.value_deep_copy(alloc, m.subject), values = values, vector = vector}
	}

	sync.mutex_lock(&nearest_cache.lock)
	defer sync.mutex_unlock(&nearest_cache.lock)
	victim := -1
	for e, i in nearest_cache.entries {
		if e.arena == nil {
			victim = i
			break
		}
		if e.pins == 0 && (victim < 0 || e.used < nearest_cache.entries[victim].used) {
			victim = i
		}
	}
	if victim < 0 {
		// Every entry is in use: serve this call from its own arena copy.
		virtual.arena_destroy(arena)
		free(arena, owner)
		return built, nil
	}
	e := &nearest_cache.entries[victim]
	if e.arena != nil {
		nearest_entry_release(e)
		virtual.arena_destroy(e.arena)
		free(e.arena, owner)
	}
	e^ = Nearest_Cache_Entry {
		index   = index,
		serials = serials,
		arena   = arena,
		members = owned,
		used    = nearest_cache.clock,
		pins    = 1,
	}
	return e.members, e
}

@(private)
nearest_cache_unpin :: proc(pin: ^Nearest_Cache_Entry) {
	if pin == nil {
		return
	}
	sync.mutex_lock(&nearest_cache.lock)
	pin.pins -= 1
	sync.mutex_unlock(&nearest_cache.lock)
}
