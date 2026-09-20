// Reference model for buffer text semantics.
//
// This package is the executable form of the semantic contracts in
// `docs/buffers-design.md`. It deliberately has no dependency on the kernel or
// on the production piece tree: milestone M0 freezes the semantics here, with
// tests, before any storage integration exists.
//
// The model is a list of scalars tagged with provenance. A *base* cell carries
// its base index; an *inserted* cell carries the id of the insertion run that
// created it. Normalization walks the list and derives a base-relative
// *replacement* set, which is the single unit of conflict, persistence, and
// client reconciliation:
//
//   Replacement{start, end, text}
//
// removes base interval [start, end) and inserts `text` at `start`. A pure
// insert has start == end; a pure delete has empty text.
//
// Deriving that set from content would be ambiguous ("aaa" -> "aa" could delete
// any of three positions, and the choice changes which edits conflict), so
// normalization is provenance-based. See `delta_derive`.
package buffer

import "core:mem"
import "core:strings"
import "core:unicode/utf8"

// A cell of a reference document.
Cell :: struct {
	// 0 for base material, otherwise the id of the insertion run that created
	// this cell. Cells of one insertion run share an id, modelling a chunk.
	run: u64,
	// Base index when `run == 0`; -1 for inserted cells.
	base: int,
	scalar: rune,
}

// A reference document: an ordered sequence of tagged scalars.
Document :: struct {
	cells: []Cell,
}

// Allocates insertion-run identifiers. Run ids start above every base index so
// that base provenance and inserted provenance cannot collide.
Run_Allocator :: struct {
	next: u64,
}

run_allocator_init :: proc(base_len: int) -> Run_Allocator {
	return Run_Allocator{next = u64(base_len) + 1}
}

run_allocator_take :: proc(allocator: ^Run_Allocator) -> u64 {
	id := allocator.next
	allocator.next += 1
	return id
}

// Builds a base document from `text`; cell `i` records base index `i`.
base_document :: proc(text: string, allocator := context.allocator) -> Document {
	cells := make([]Cell, utf8.rune_count_in_string(text), allocator)
	index := 0
	for scalar in text {
		cells[index] = Cell {
			run    = 0,
			base   = index,
			scalar = scalar,
		}
		index += 1
	}
	return Document{cells = cells}
}

// Renders a document as text. The result is owned by `allocator`; the internal
// builder is intentionally not destroyed because it owns the returned bytes.
document_text :: proc(doc: Document, allocator := context.allocator) -> string {
	builder: strings.Builder
	strings.builder_init(&builder, allocator)
	for cell in doc.cells {
		strings.write_rune(&builder, cell.scalar)
	}
	return strings.to_string(builder)
}

// A view-relative edit. Offsets address the current transaction view, never the
// base version; this is the coordinate contract from the design.
Edit :: struct {
	at:     int,
	remove: int,
	text:   string,
}

Edit_Error :: enum {
	None,
	Out_Of_Range,
}

// Applies a view-relative edit, creating one insertion run for `text`.
edit_apply :: proc(
	doc: Document,
	edit: Edit,
	runs: ^Run_Allocator,
	allocator := context.allocator,
) -> (
	Document,
	Edit_Error,
) {
	if edit.at < 0 || edit.remove < 0 || edit.at + edit.remove > len(doc.cells) {
		return doc, .Out_Of_Range
	}
	insert_count := utf8.rune_count_in_string(edit.text)
	next := make([]Cell, len(doc.cells) - edit.remove + insert_count, allocator)
	copy(next[:edit.at], doc.cells[:edit.at])

	index := edit.at
	if insert_count > 0 {
		run := run_allocator_take(runs)
		for scalar in edit.text {
			next[index] = Cell {
				run    = run,
				base   = -1,
				scalar = scalar,
			}
			index += 1
		}
	}
	copy(next[index:], doc.cells[edit.at + edit.remove:])
	return Document{cells = next}, .None
}

// A base-relative replacement. `text` replaces base interval [start, end).
Replacement :: struct {
	start: int,
	end:   int,
	text:  string,
}

// A normalized, base-relative delta. Replacements are ordered by `start` and do
// not overlap.
Delta :: struct {
	replacements: []Replacement,
}

Delta_Error :: enum {
	None,
	// A cell claims base provenance that the base cannot account for: an index
	// out of range, or out of order. Under splices this cannot occur, so it
	// signals a foreign root (for example an adopted historical root), which
	// the design forbids.
	Foreign_Base_Cell,
}

@(private)
delta_flush :: proc(
	reps: ^[dynamic]Replacement,
	pending: ^strings.Builder,
	start, end: int,
	allocator: mem.Allocator,
) {
	// The builder is reset for the next region, so the text must be cloned:
	// resetting keeps the same buffer and later writes would overwrite it.
	text := strings.clone(strings.to_string(pending^), allocator)
	append(reps, Replacement{start = start, end = end, text = text})
	strings.builder_reset(pending)
}

// Derives the base-relative delta by walking provenance.
//
// A cell is *retained base material* only when it carries base provenance the
// base actually contains, in order. Retained cells advance the base cursor;
// anything else is gathered into the non-retained region that spans from the
// end of the previous retained run to the start of the next one. Emitting one
// replacement per region (rather than separate inserts and deletes) is what
// makes an adjacent delete-plus-insert normalize to a single replacement.
delta_derive :: proc(
	doc: Document,
	base_len: int,
	allocator := context.allocator,
) -> (
	Delta,
	Delta_Error,
) {
	reps: [dynamic]Replacement
	reps = make([dynamic]Replacement, allocator)

	pending: strings.Builder
	strings.builder_init(&pending, allocator)

	have_pending := false
	region_start := 0
	next_base := 0

	for cell in doc.cells {
		if cell.run == 0 {
			if cell.base < 0 || cell.base >= base_len || cell.base < next_base {
				return Delta{}, .Foreign_Base_Cell
			}
			// Close the region either because insertions are pending or
			// because base material was skipped (a deletion). A region with
			// only a deletion starts at the base cursor, not at the previous
			// region's origin.
			if have_pending || cell.base > next_base {
				if !have_pending {
					region_start = next_base
				}
				delta_flush(&reps, &pending, region_start, cell.base, allocator)
				have_pending = false
			}
			next_base = cell.base + 1
		} else {
			if !have_pending {
				region_start = next_base
				have_pending = true
			}
			strings.write_rune(&pending, cell.scalar)
		}
	}

	// A trailing insertion, a trailing deletion, or both.
	if have_pending || next_base < base_len {
		if !have_pending {
			region_start = next_base
		}
		delta_flush(&reps, &pending, region_start, base_len, allocator)
	}

	return Delta{replacements = reps[:]}, .None
}

// Applies a base-relative delta to a document. Replacements are applied from
// last to first so earlier base coordinates stay valid.
delta_apply :: proc(
	doc: Document,
	delta: Delta,
	runs: ^Run_Allocator,
	allocator := context.allocator,
) -> (
	Document,
	Edit_Error,
) {
	result := doc
	for index := len(delta.replacements) - 1; index >= 0; index -= 1 {
		rep := delta.replacements[index]
		applied, err := edit_apply(
			result,
			Edit {
				at     = rep.start,
				remove = rep.end - rep.start,
				text   = rep.text,
			},
			runs,
			allocator,
		)
		if err != .None {
			return result, err
		}
		result = applied
	}
	return result, .None
}

// Stages a reversion as a whole-buffer replacement built from fresh cells.
//
// Reversion never adopts a historical root: adopting one would resurrect chunk
// intervals absent from the transaction's base and mix structure epochs. A
// whole-buffer splice stays inside the splice model and yields an ordinary,
// conflict-checkable delta.
revert_as_splice :: proc(
	base: Document,
	old_text: string,
	runs: ^Run_Allocator,
	allocator := context.allocator,
) -> (
	Document,
	Delta,
	Edit_Error,
) {
	base_len := len(base.cells)
	reverted, err := edit_apply(
		base,
		Edit{at = 0, remove = base_len, text = old_text},
		runs,
		allocator,
	)
	if err != .None {
		return base, {}, err
	}
	replacements := make([]Replacement, 1, allocator)
	replacements[0] = Replacement{start = 0, end = base_len, text = old_text}
	return reverted, Delta{replacements = replacements}, .None
}
