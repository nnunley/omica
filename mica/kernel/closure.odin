// Delegation closure helpers.
package kernel

import "core:mem"
import v "../var"

// Returns all transitive delegation pairs `(child, prototype)` reachable
// through the delegates relation.
delegates_star :: proc(
	source: ^Relation_Source,
	delegates_relation: Relation_ID,
	alloc: mem.Allocator,
) -> []v.Tuple {
	children: map[v.Value]bool
	defer delete(children)
	edges: [dynamic]v.Tuple
	relation_source_scan_into(
		source,
		delegates_relation,
		[]v.Binding{{}, {}, {}},
		&edges,
	)
	for edge in edges {
		children[v.tuple_values(edge)[0]] = true
	}

	pairs: [dynamic]v.Tuple
	for child in children {
		prototypes := delegates_star_from(source, delegates_relation, child, alloc)
		for proto in prototypes {
			tuple := make([]v.Value, 2, alloc)
			tuple[0] = child
			tuple[1] = proto
			append(&pairs, v.tuple_from_slice(tuple))
		}
	}
	return pairs[:]
}

// Returns all prototypes reachable from `child` through the delegates
// relation.
delegates_star_from :: proc(
	source: ^Relation_Source,
	delegates_relation: Relation_ID,
	child: v.Value,
	alloc: mem.Allocator,
) -> []v.Value {
	seen: map[v.Value]bool
	defer delete(seen)

	frontier: [dynamic]v.Value
	defer delete(frontier)
	append(&frontier, child)

	result: [dynamic]v.Value
	for len(frontier) > 0 {
		current := pop(&frontier)
		edges: [dynamic]v.Tuple
		relation_source_scan_into(
			source,
			delegates_relation,
			[]v.Binding{v.binding_of(current), {}, {}},
			&edges,
		)
		for edge in edges {
			proto := v.tuple_values(edge)[1]
			if !seen[proto] {
				seen[proto] = true
				append(&frontier, proto)
				append(&result, proto)
			}
		}
		delete(edges)
	}

	owned := make([]v.Value, len(result), alloc)
	copy(owned, result[:])
	delete(result)
	return owned
}

// Reports whether `child` reaches `ancestor` through the delegates relation.
delegates_reaches :: proc(
	source: ^Relation_Source,
	delegates_relation: Relation_ID,
	child: v.Value,
	ancestor: v.Value,
) -> bool {
	seen: map[v.Value]bool
	defer delete(seen)

	frontier: [dynamic]v.Value
	defer delete(frontier)
	append(&frontier, child)

	for len(frontier) > 0 {
		current := pop(&frontier)
		edges: [dynamic]v.Tuple
		relation_source_scan_into(
			source,
			delegates_relation,
			[]v.Binding{v.binding_of(current), {}, {}},
			&edges,
		)
		for edge in edges {
			proto := v.tuple_values(edge)[1]
			if v.value_eq(proto, ancestor) {
				delete(edges)
				return true
			}
			if !seen[proto] {
				seen[proto] = true
				append(&frontier, proto)
			}
		}
		delete(edges)
	}
	return false
}
