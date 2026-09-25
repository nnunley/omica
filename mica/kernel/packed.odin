// Packed keys: one or two relation positions as sorted-unique raw 64-bit
// value words, for batched equality operators (membership now, joins in
// Stage 2). Only fixed-width (immediate) values pack: for them raw-word
// equality is value equality. Heap values (strings, lists, ...) do not, and
// their operators stay on the row path.
package kernel

import "core:mem"
import "core:slice"
import accel "./accel"
import v "../var"

Packed_Keys :: struct {
	width: int,
	count: int,
	// count * width words; pairs are interleaved (key i is keys[2i], keys[2i+1])
	// and sorted lexicographically.
	keys:  []u64,
}

packed_keys_from_rows :: proc(rows: []v.Tuple, positions: []u16, allocator: mem.Allocator) -> (keys: Packed_Keys, ok: bool) {
	width := len(positions)
	if width < 1 || width > 2 {
		return {}, false
	}
	words := make([]u64, len(rows) * width, allocator)
	for r, i in rows {
		cells := v.tuple_values(r)
		for position, j in positions {
			if int(position) >= len(cells) || !v.value_is_immediate(cells[position]) {
				return {}, false
			}
			words[i * width + j] = u64(cells[position])
		}
	}
	count := 0
	if width == 1 {
		slice.sort(words)
		for w in words {
			if count == 0 || words[count - 1] != w {
				words[count] = w
				count += 1
			}
		}
	} else {
		pairs := slice.reinterpret([][2]u64, words)
		slice.sort_by(pairs, proc(a, b: [2]u64) -> bool {
			return a[0] < b[0] || (a[0] == b[0] && a[1] < b[1])
		})
		for p in pairs {
			if count == 0 || pairs[count - 1] != p {
				pairs[count] = p
				count += 1
			}
		}
	}
	return Packed_Keys{width = width, count = count, keys = words[:count * width]}, true
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
	rows := make([dynamic]v.Tuple, 0, 64, cache.allocator)
	unbound := make([]v.Binding, width, cache.allocator)
	relation_source_scan_into(source, relation, unbound, &rows)
	if source.error != .None {
		// A computed relation that needs bound keys: no column; the caller's
		// row path probes each binding.
		source.error = .None
		return nil, false
	}
	positions := []u16{0, 1}
	keys, ok := packed_keys_from_rows(rows[:], positions[:width], cache.allocator)
	e := new(Packed_Entry, cache.allocator)
	e^ = Packed_Entry{relation = relation, width = width, ok = ok, keys = keys}
	append(&cache.entries, e)
	cache.builds += 1
	return e, ok
}
