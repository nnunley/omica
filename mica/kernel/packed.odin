// Packed keys: one or two relation positions as sorted-unique raw 64-bit
// value words, for batched equality operators (membership now, joins in
// Stage 3). Only fixed-width (immediate) values pack: for them raw-word
// equality is value equality. Heap values (strings, lists, ...) do not, and
// their operators stay on the row path.
package kernel

import "core:mem"
import "core:slice"
import accel "./accel"
import v "../var"

Packed_Keys :: struct {
	width:   int,
	count:   int,
	// One column per key position, each `count` long. Two-position keys are
	// the pairs (columns[0][i], columns[1][i]), sorted lexicographically.
	columns: [][]u64,
}

// Packs rows 0..count-1 of `columns` (one per key position, 1 or 2) into
// sorted-unique keys. Fails when a value is not fixed-width or a column is
// shorter than `count`.
packed_keys_from_columns :: proc(columns: [][]v.Value, count: int, allocator: mem.Allocator) -> (keys: Packed_Keys, ok: bool) {
	width := len(columns)
	if width < 1 || width > 2 {
		return {}, false
	}
	for column in columns {
		if len(column) < count {
			return {}, false
		}
		for value in column[:count] {
			if !v.value_is_immediate(value) {
				return {}, false
			}
		}
	}
	out := make([][]u64, width, allocator)
	if width == 1 {
		words := make([]u64, count, allocator)
		copy(words, slice.reinterpret([]u64, columns[0][:count]))
		slice.sort(words)
		n := 0
		for w in words {
			if n == 0 || words[n - 1] != w {
				words[n] = w
				n += 1
			}
		}
		out[0] = words[:n]
		return Packed_Keys{width = 1, count = n, columns = out}, true
	}
	pairs := make([][2]u64, count, allocator)
	for i in 0 ..< count {
		pairs[i] = {u64(columns[0][i]), u64(columns[1][i])}
	}
	slice.sort_by(pairs, proc(a, b: [2]u64) -> bool {
		return a[0] < b[0] || (a[0] == b[0] && a[1] < b[1])
	})
	n := 0
	for p in pairs {
		if n == 0 || pairs[n - 1] != p {
			pairs[n] = p
			n += 1
		}
	}
	a := make([]u64, n, allocator)
	b := make([]u64, n, allocator)
	for i in 0 ..< n {
		a[i], b[i] = pairs[i][0], pairs[i][1]
	}
	out[0], out[1] = a, b
	return Packed_Keys{width = 2, count = n, columns = out}, true
}

// Keys packed for one relation at positions 0..width-1, plus an optional
// device-resident copy prepared for the strategy that was active when first
// requested.
Packed_Entry :: struct {
	relation: Relation_ID,
	width:    int,
	ok:       bool,
	keys:     Packed_Keys,
	prepared: accel.Prepared,
	strategy: accel.Strategy,
	// A prepare was attempted (successful or not): never retried in this
	// evaluation.
	prepare_tried: bool,
}

// Lives for one rules_evaluate_source call. A negated atom reads a relation
// from a strictly lower, finished stratum, so its rows cannot change during
// the evaluation and one gather serves every rule and round.
Packed_Cache :: struct {
	entries:   [dynamic]^Packed_Entry,
	allocator: mem.Allocator,
	builds:    int,
	prepares:  int,
}

@(thread_local, private)
packed_last_builds: int

@(thread_local, private)
packed_last_prepares: int

// Prepare attempts in the calling thread's most recent evaluation (tests).
packed_last_evaluation_prepares :: proc() -> int {
	return packed_last_prepares
}

// Gathers performed by the calling thread's most recent evaluation (tests).
packed_last_evaluation_builds :: proc() -> int {
	return packed_last_builds
}

packed_cache_create :: proc(allocator: mem.Allocator) -> ^Packed_Cache {
	cache := new(Packed_Cache, allocator)
	cache^ = Packed_Cache{entries = make([dynamic]^Packed_Entry, allocator), allocator = allocator}
	return cache
}

// Releases prepared (device) copies; memory belongs to the evaluation arena.
packed_cache_destroy :: proc(cache: ^Packed_Cache) {
	if cache == nil {
		return
	}
	for entry in cache.entries {
		accel.release_prepared(entry.strategy, &entry.prepared)
	}
	packed_last_builds = cache.builds
	packed_last_prepares = cache.prepares
}

// The entry for (relation, positions 0..width-1), gathered and packed on first
// use. found=false when the source has no cache or the scan errors (entry
// nil; source.error is cleared), or the rows do not pack (entry.ok=false,
// cached so the gather is not repeated).
packed_cache_lookup :: proc(source: ^Relation_Source, relation: Relation_ID, width: int) -> (entry: ^Packed_Entry, found: bool) {
	cache := source.packed
	if cache == nil || width < 1 || width > 2 {
		return nil, false
	}
	for e in cache.entries {
		if e.relation == relation && e.width == width {
			return e, e.ok
		}
	}
	unbound := make([]v.Binding, width, cache.allocator)
	batch, err := relation_source_scan_columns(source, relation, unbound, cache.allocator)
	if err != .None {
		// A computed relation that needs bound keys (or an unreadable one): no
		// column; the caller's other paths handle each row.
		source.error = .None
		return nil, false
	}
	keys, ok := packed_keys_from_columns(batch.columns[:width], batch.count, cache.allocator)
	e := new(Packed_Entry, cache.allocator)
	e^ = Packed_Entry{relation = relation, width = width, ok = ok, keys = keys}
	append(&cache.entries, e)
	cache.builds += 1
	return e, ok
}
