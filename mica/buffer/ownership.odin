// Reference ownership model for insertion runs.
//
// Production chunks are immutable and reference-counted, allocated from a
// size-class pool; piece nodes retain their children; a snapshot retains each
// buffer block. M0 models the observable lifetime rule at the reference level:
//
//   - base material has no run and is never freed;
//   - an insertion run is retained by every document that references it;
//   - abandoning a candidate releases exactly the runs that reach zero.
//
// The design's required answers follow from this: published runs never move, so
// borrowed spans stay valid while a root is retained; text appended by an
// abandoned candidate is released with it; and old roots keep their own runs
// alive after compaction.
package buffer

import "core:mem"

Origin_Table :: struct {
	refs:      [dynamic]int,
	allocator: mem.Allocator,
}

origin_table_init :: proc(table: ^Origin_Table, allocator := context.allocator) {
	table.allocator = allocator
	table.refs = make([dynamic]int, allocator)
}

origin_table_destroy :: proc(table: ^Origin_Table) {
	delete(table.refs)
	table.refs = nil
}

// Retains insertion run `run`. Base cells carry run 0 and are ignored.
origin_retain :: proc(table: ^Origin_Table, run: u64) {
	if run == 0 {
		return
	}
	index := int(run)
	for len(table.refs) <= index {
		append(&table.refs, 0)
	}
	table.refs[index] += 1
}

// Releases insertion run `run`, returning true when its last reference is gone.
origin_release :: proc(table: ^Origin_Table, run: u64) -> bool {
	if run == 0 {
		return false
	}
	index := int(run)
	if index >= len(table.refs) || table.refs[index] == 0 {
		return false
	}
	table.refs[index] -= 1
	return table.refs[index] == 0
}

origin_refs :: proc(table: ^Origin_Table, run: u64) -> int {
	if run == 0 {
		return 0
	}
	index := int(run)
	if index >= len(table.refs) {
		return 0
	}
	return table.refs[index]
}

// Retains every distinct insertion run a document references. Run cells are
// contiguous, so a run is counted once.
document_retain :: proc(table: ^Origin_Table, doc: Document) {
	last := u64(0)
	for cell in doc.cells {
		if cell.run != 0 && cell.run != last {
			origin_retain(table, cell.run)
			last = cell.run
		}
	}
}

// Releases every distinct insertion run a document references, appending runs
// whose last reference was dropped to `freed` when `freed` is not nil.
document_release :: proc(table: ^Origin_Table, doc: Document, freed: ^[dynamic]u64 = nil) {
	last := u64(0)
	for cell in doc.cells {
		if cell.run != 0 && cell.run != last {
			if origin_release(table, cell.run) && freed != nil {
				append(freed, cell.run)
			}
			last = cell.run
		}
	}
}
