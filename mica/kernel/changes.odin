// A bounded commit change feed.
//
// Every published version is noted; versions that carry fact writes also keep
// deep copies of the asserted and retracted rows for a bounded window. Change
// subscribers drain the feed from a cursor and resynchronize from a snapshot
// when their cursor falls out of the window.
package kernel

import "core:mem"
import "core:sync"
import v "../var"

Change_Record :: struct {
	version:   u64,
	relation:  Relation_ID,
	asserted:  []v.Tuple,
	retracted: []v.Tuple,
}

Change_Feed :: struct {
	lock:      sync.Mutex,
	records:   [dynamic]Change_Record,
	latest:    u64,
	capacity:  int,
	allocator: mem.Allocator,
}

DEFAULT_CHANGE_CAPACITY :: 512

changes_init :: proc(
	feed: ^Change_Feed,
	capacity := DEFAULT_CHANGE_CAPACITY,
	allocator := context.allocator,
) {
	feed.capacity = capacity
	feed.allocator = allocator
	feed.records = make([dynamic]Change_Record, allocator)
}

changes_destroy :: proc(feed: ^Change_Feed) {
	for record in feed.records {
		for tuple in record.asserted {
			tuple_deep_free(feed.allocator, tuple)
		}
		for tuple in record.retracted {
			tuple_deep_free(feed.allocator, tuple)
		}
		if record.asserted != nil {
			delete(record.asserted, feed.allocator)
		}
		if record.retracted != nil {
			delete(record.retracted, feed.allocator)
		}
	}
	delete(feed.records)
}

// Notes a published version even when it carries no fact changes.
changes_note_version :: proc(feed: ^Change_Feed, version: u64) {
	sync.mutex_lock(&feed.lock)
	if version > feed.latest {
		feed.latest = version
	}
	sync.mutex_unlock(&feed.lock)
}

// Records the fact writes that became visible at `version`.
changes_record_writes :: proc(
	feed: ^Change_Feed,
	version: u64,
	writes: []Relation_Writes,
) {
	sync.mutex_lock(&feed.lock)
	defer sync.mutex_unlock(&feed.lock)
	if version > feed.latest {
		feed.latest = version
	}
	for relation_writes in writes {
		asserted := make([dynamic]v.Tuple, feed.allocator)
		retracted := make([dynamic]v.Tuple, feed.allocator)
		for pending in relation_writes.entries {
			switch pending.kind {
			case .Assert:
				append(&asserted, v.tuple_deep_copy(feed.allocator, pending.tuple))
			case .Retract:
				append(&retracted, v.tuple_deep_copy(feed.allocator, pending.tuple))
			}
		}
		if len(asserted) == 0 && len(retracted) == 0 {
			delete(asserted)
			delete(retracted)
			continue
		}
		append(&feed.records, Change_Record {
			version   = version,
			relation  = relation_writes.relation,
			asserted  = asserted[:],
			retracted = retracted[:],
		})
	}
	// Evict the oldest records beyond capacity. Subscribers that fall behind
	// resynchronize from the current snapshot.
	for len(feed.records) > feed.capacity {
		record := feed.records[0]
		for tuple in record.asserted {
			tuple_deep_free(feed.allocator, tuple)
		}
		for tuple in record.retracted {
			tuple_deep_free(feed.allocator, tuple)
		}
		delete(record.asserted, feed.allocator)
		delete(record.retracted, feed.allocator)
		ordered_remove_first(&feed.records)
	}
}

// Visits records with a version greater than `cursor`. Returns the newest
// recorded version and false when the cursor is older than the retained window
// and the caller must resynchronize.
changes_visit :: proc(
	feed: ^Change_Feed,
	cursor: u64,
	user: rawptr,
	visit: proc(user: rawptr, record: ^Change_Record) -> bool,
) -> (
	latest: u64,
	ok: bool,
) {
	sync.mutex_lock(&feed.lock)
	defer sync.mutex_unlock(&feed.lock)
	latest = feed.latest
	if len(feed.records) > 0 && cursor + 1 < feed.records[0].version {
		return latest, false
	}
	for index in 0 ..< len(feed.records) {
		record := &feed.records[index]
		if record.version <= cursor {
			continue
		}
		if !visit(user, record) {
			return latest, false
		}
	}
	return latest, true
}

@(private)
ordered_remove_first :: proc(records: ^[dynamic]Change_Record) {
	if len(records) == 0 {
		return
	}
	for index in 1 ..< len(records) {
		records[index - 1] = records[index]
	}
	resize(records, len(records) - 1)
}

// Frees a tuple deep copy made with `tuple_deep_copy`.
@(private)
tuple_deep_free :: proc(alloc: mem.Allocator, tuple: v.Tuple) {
	values := v.tuple_values(tuple)
	for cell in values {
		v.value_deep_free(alloc, cell)
	}
	delete(values, alloc)
}
