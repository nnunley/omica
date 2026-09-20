// A bounded commit change feed.
//
// Every published version is noted; versions that carry fact writes also keep
// deep copies of the asserted and retracted rows for a bounded window. Change
// subscribers drain the feed from a cursor and resynchronize from a snapshot
// when their cursor falls out of the window.
package kernel

import "core:mem"
import "core:strings"
import "core:sync"
import buf "../buffer"
import v "../var"

// What kind of catalog change a record carries.
Catalog_Change_Kind :: enum {
	Relation_Created,
	Rule_Installed,
	Rule_Disabled,
}

// A catalog change visible at a version: a relation was created, a rule was
// installed, or a rule's active flag was toggled.
Catalog_Change :: struct {
	kind:     Catalog_Change_Kind,
	relation: Relation_ID,
	rule:     v.Identity,
	name:     v.Symbol,
}

// A buffer content change visible at a version.
//
// The delta is the committed base-relative change -- the same one recorded in
// the log -- so an observer can apply it to its own copy of the text without
// holding a snapshot. `epoch` is carried because a compaction publishes an empty
// delta and a new epoch: the content is unchanged, but the chunk lineage moved.
Buffer_Change :: struct {
	relation:      Relation_ID,
	base_revision: u64,
	new_revision:  u64,
	epoch:         u64,
	delta:         buf.Delta,
}

Change_Record :: struct {
	version:   u64,
	relation:  Relation_ID,
	asserted:  []v.Tuple,
	retracted: []v.Tuple,
	catalogue: []Catalog_Change,
	buffers:   []Buffer_Change,
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
	for &record in feed.records {
		change_record_free(feed, &record)
	}
	delete(feed.records)
}

// Releases everything a record owns: deep-copied tuples, the catalogue slice,
// and deep-copied buffer delta texts.
@(private)
change_record_free :: proc(feed: ^Change_Feed, record: ^Change_Record) {
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
	if record.catalogue != nil {
		delete(record.catalogue, feed.allocator)
	}
	for &change in record.buffers {
		for replacement in change.delta.replacements {
			if replacement.text != "" {
				delete(replacement.text, feed.allocator)
			}
		}
		if change.delta.replacements != nil {
			delete(change.delta.replacements, feed.allocator)
		}
	}
	if record.buffers != nil {
		delete(record.buffers, feed.allocator)
	}
}

// Drops the oldest records until the feed fits its capacity. Subscribers that
// fall behind resynchronize from the current snapshot.
@(private)
changes_trim :: proc(feed: ^Change_Feed) {
	for len(feed.records) > feed.capacity {
		change_record_free(feed, &feed.records[0])
		ordered_remove_first(&feed.records)
	}
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
	changes_trim(feed)
}

// Records the buffer content changes that became visible at `version`.
//
// A buffer write carries no tuples: its payload is the committed base-relative
// delta, which is deep-copied into the feed so an observer can apply it to its
// own copy of the text. A compaction publishes an empty delta and a new epoch,
// and is recorded too, because the lineage change is observable.
changes_record_buffers :: proc(
	feed: ^Change_Feed,
	version: u64,
	writes: []Buffer_Writes,
) {
	sync.mutex_lock(&feed.lock)
	defer sync.mutex_unlock(&feed.lock)
	if version > feed.latest {
		feed.latest = version
	}
	for buffer_writes in writes {
		if !buffer_writes.committed {
			continue
		}
		replacements := make(
			[]buf.Replacement,
			len(buffer_writes.delta.replacements),
			feed.allocator,
		)
		for replacement, index in buffer_writes.delta.replacements {
			text := replacement.text
			if text != "" {
				text = strings.clone(replacement.text, feed.allocator)
			}
			replacements[index] = buf.Replacement {
				start = replacement.start,
				end   = replacement.end,
				text  = text,
			}
		}
		buffers := make([]Buffer_Change, 1, feed.allocator)
		buffers[0] = Buffer_Change {
			relation      = buffer_writes.relation,
			base_revision = buffer_writes.base_revision,
			new_revision  = buffer_writes.new_revision,
			epoch         = buffer_writes.epoch,
			delta         = buf.Delta{replacements = replacements},
		}
		append(&feed.records, Change_Record{version = version, buffers = buffers})
	}
	changes_trim(feed)
}

// Records catalog changes that became visible at `version`: relation creation,
// rule installation, and rule toggles.
changes_record_catalog :: proc(
	feed: ^Change_Feed,
	version: u64,
	changes: []Catalog_Change,
) {
	if len(changes) == 0 {
		return
	}
	sync.mutex_lock(&feed.lock)
	defer sync.mutex_unlock(&feed.lock)
	if version > feed.latest {
		feed.latest = version
	}
	copied := make([]Catalog_Change, len(changes), feed.allocator)
	copy(copied, changes)
	append(&feed.records, Change_Record{version = version, catalogue = copied})
	changes_trim(feed)
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
