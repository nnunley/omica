// Relation identity, schema, and conflict metadata.
package kernel

import "core:mem"
import v "../var"

// Stable relation identity.
Relation_ID :: distinct u32

// Returns the numeric id of a relation.
relation_id_raw :: proc(id: Relation_ID) -> u32 {
	return u32(id)
}

// How concurrent changes to a relation are validated at commit.
Conflict_Kind :: enum {
	// Tuples form a set; a concurrent retraction of an asserted tuple conflicts.
	Set,
	// Key positions are unique; a concurrent change to a touched key conflicts.
	Functional,
	// Appends never conflict.
	Event_Append,
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

// Relation schema and storage metadata.
Relation_Metadata :: struct {
	id:              Relation_ID,
	name:            v.Symbol,
	arity:           u16,
	argument_names:  []v.Symbol,
	indexes:         []Index_Spec,
	conflict:        Conflict_Policy,
	durability:      Relation_Durability,
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
