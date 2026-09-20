// Relation identity, schema, and conflict metadata.
package kernel

import "core:mem"
import v "../var"

// Stable relation identity.
Relation_ID :: distinct u32

// What kind of storage backs a catalogue entry.
//
// A relation is a set of tuples; a buffer is a sequence of scalars. They share
// the catalogue, the transaction, snapshots, durability, and authority, and
// nothing else. See `docs/buffers-design.md`.
Storage_Kind :: enum {
	Tuple,
	Buffer,
}

// How concurrent changes to a relation are validated at commit.
Conflict_Kind :: enum {
	// Tuples form a set; a concurrent retraction of an asserted tuple conflicts.
	Set,
	// Key positions are unique; a concurrent change to a touched key conflicts.
	Functional,
	// Appends never conflict.
	Event_Append,
	// A buffer: any concurrent content change conflicts. The conservative
	// default until span merging is available.
	Reject,
	// A buffer: provenance merge, so disjoint base ranges merge.
	Span,
	// A buffer: last-writer-wins over the whole buffer. Destructive; opt-in.
	Whole,
}

// Relation conflict validation policy.
Conflict_Policy :: struct {
	kind:          Conflict_Kind,
	key_positions: []u16,
}

// Creates a set conflict policy.
conflict_set :: proc() -> Conflict_Policy {
	return Conflict_Policy{kind = .Set}
}

// Creates a functional conflict policy over the given key positions.
conflict_functional :: proc(key_positions: []u16) -> Conflict_Policy {
	return Conflict_Policy{kind = .Functional, key_positions = key_positions}
}

// Creates an event-append conflict policy.
conflict_event_append :: proc() -> Conflict_Policy {
	return Conflict_Policy{kind = .Event_Append}
}

// Whether a relation is durable or volatile across restarts.
Relation_Durability :: enum {
	Durable,
	Volatile,
}

// A secondary index specification over argument positions.
Index_Spec :: struct {
	positions: []u16,
}

// Returns an index spec over `positions`.
index_spec :: proc(positions: []u16) -> Index_Spec {
	return Index_Spec{positions = positions}
}

// Returns true when an index spec covers every position in order.
index_is_natural_full_tuple :: proc(spec: Index_Spec, arity: u16) -> bool {
	if len(spec.positions) != int(arity) {
		return false
	}
	for position, i in spec.positions {
		if int(position) != i {
			return false
		}
	}
	return true
}

// Number of leading bound positions this index can use for a scan.
index_leading_bound_count :: proc(spec: Index_Spec, bindings: []v.Binding) -> int {
	count := 0
	for position in spec.positions {
		if int(position) >= len(bindings) || !bindings[int(position)].bound {
			break
		}
		count += 1
	}
	return count
}

// Catalogue-entry schema and storage metadata.
//
// `storage` discriminates a tuple relation from a buffer. A buffer declares
// arity 0: it genuinely has no columns, so nothing is being ignored.
Relation_Metadata :: struct {
	id:              Relation_ID,
	name:            v.Symbol,
	arity:           u16,
	argument_names:  []v.Symbol,
	indexes:         []Index_Spec,
	conflict:        Conflict_Policy,
	durability:      Relation_Durability,
	storage:         Storage_Kind,
	// A killed entry. The id and name are never reused, so a stale reference
	// fails cleanly instead of aliasing a new object. Its content is released.
	tombstoned:      bool,
}

// Creates metadata for a relation with a natural full-tuple index and set
// conflict policy. Indexes do not include the natural full-tuple index; the
// primary tuple store serves it.
relation_metadata :: proc(id: Relation_ID, name: v.Symbol, arity: u16) -> Relation_Metadata {
	return Relation_Metadata {
		id = id,
		name = name,
		arity = arity,
		indexes = nil,
		conflict = conflict_set(),
		durability = .Durable,
		storage = .Tuple,
	}
}

// Returns metadata with the given secondary indexes.
metadata_with_indexes :: proc(
	metadata: Relation_Metadata,
	indexes: []Index_Spec,
) -> Relation_Metadata {
	result := metadata
	result.indexes = indexes
	return result
}

// Returns metadata with a functional conflict policy over `key_positions`.
metadata_with_conflict :: proc(
	metadata: Relation_Metadata,
	conflict: Conflict_Policy,
) -> Relation_Metadata {
	result := metadata
	result.conflict = conflict
	return result
}

// Returns metadata with the given storage kind.
metadata_with_storage :: proc(
	metadata: Relation_Metadata,
	storage: Storage_Kind,
) -> Relation_Metadata {
	result := metadata
	result.storage = storage
	return result
}

// Returns metadata with the given durability.
metadata_with_durability :: proc(
	metadata: Relation_Metadata,
	durability: Relation_Durability,
) -> Relation_Metadata {
	result := metadata
	result.durability = durability
	return result
}

// Returns the argument name at `position`, if set.
metadata_argument_name :: proc(metadata: Relation_Metadata, position: u16) -> (v.Symbol, bool) {
	if int(position) >= len(metadata.argument_names) {
		return v.Symbol(0), false
	}
	return metadata.argument_names[position], true
}

// Validates a metadata record against relation limits.
validate_relation_metadata :: proc(metadata: Relation_Metadata) -> Kernel_Error {
	for spec in metadata.indexes {
		for position in spec.positions {
			if position >= metadata.arity {
				return .Invalid_Metadata
			}
		}
	}
	if metadata.conflict.kind == .Functional {
		for position in metadata.conflict.key_positions {
			if position >= metadata.arity {
				return .Invalid_Metadata
			}
		}
	}

	// A buffer has no columns, no indexes, and no tuple conflict policy.
	if metadata.storage == .Buffer {
		if metadata.arity != 0 || len(metadata.indexes) != 0 {
			return .Invalid_Metadata
		}
		switch metadata.conflict.kind {
		case .Reject, .Span, .Whole:
		// A buffer's conflict policy is span- or whole-buffer based.
		case .Set, .Functional, .Event_Append:
			return .Invalid_Metadata
		}
	} else {
		// A tuple relation cannot carry a buffer conflict policy.
		switch metadata.conflict.kind {
		case .Set, .Functional, .Event_Append:
		case .Reject, .Span, .Whole:
			return .Invalid_Metadata
		}
	}
	return .None
}

// Creates an independent copy of metadata allocated from `alloc`.
metadata_clone :: proc(alloc: mem.Allocator, metadata: Relation_Metadata) -> Relation_Metadata {
	result := metadata
	if metadata.argument_names != nil {
		names := make([]v.Symbol, len(metadata.argument_names), alloc)
		copy(names, metadata.argument_names)
		result.argument_names = names
	}
	if metadata.indexes != nil {
		indexes := make([]Index_Spec, len(metadata.indexes), alloc)
		for spec, i in metadata.indexes {
			positions := make([]u16, len(spec.positions), alloc)
			copy(positions, spec.positions)
			indexes[i] = Index_Spec{positions = positions}
		}
		result.indexes = indexes
	}
	if metadata.conflict.key_positions != nil {
		keys := make([]u16, len(metadata.conflict.key_positions), alloc)
		copy(keys, metadata.conflict.key_positions)
		result.conflict = Conflict_Policy {
			kind          = metadata.conflict.kind,
			key_positions = keys,
		}
	}
	return result
}
