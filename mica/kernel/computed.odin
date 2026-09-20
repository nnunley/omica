// Runtime-produced, read-only relation surfaces.
package kernel

import v "../var"
import "core:mem"
import "core:sync"

Computed_Visit_Proc :: #type proc(user: rawptr, row: v.Tuple) -> bool

// A scanner produces candidate tuples for one relation. The source identifies
// the exact snapshot or transaction view that the scan must observe.
Computed_Scan_Proc :: #type proc(
	user: rawptr,
	source: ^Relation_Source,
	bindings: []v.Binding,
	visit: Computed_Visit_Proc,
	visit_user: rawptr,
) -> Kernel_Error

Computed_Relation :: struct {
	relation:          Relation_ID,
	required_bindings: []u16,
	scan:              Computed_Scan_Proc,
	user:              rawptr,
}

Computed_Registry :: struct {
	lock:      sync.Mutex,
	entries:   [dynamic]Computed_Relation,
	allocator: mem.Allocator,
}

computed_registry_init :: proc(registry: ^Computed_Registry, allocator := context.allocator) {
	registry.allocator = allocator
	registry.entries = make([dynamic]Computed_Relation, allocator)
}

computed_registry_destroy :: proc(registry: ^Computed_Registry) {
	for entry in registry.entries {
		delete(entry.required_bindings, registry.allocator)
	}
	delete(registry.entries)
}

kernel_register_computed_relation :: proc(
	kernel: ^Kernel,
	relation: Relation_ID,
	required_bindings: []u16,
	scan: Computed_Scan_Proc,
	user: rawptr = nil,
) -> Kernel_Error {
	metadata, found := snapshot_relation_metadata(kernel.current, relation)
	if !found || metadata.storage != .Tuple {
		return .Unknown_Relation
	}
	for position in required_bindings {
		if position >= metadata.arity {
			return .Arity_Mismatch
		}
	}

	registry := &kernel.computed
	sync.mutex_lock(&registry.lock)
	defer sync.mutex_unlock(&registry.lock)
	for &entry in registry.entries {
		if entry.relation != relation {
			continue
		}
		delete(entry.required_bindings, registry.allocator)
		entry.required_bindings = make([]u16, len(required_bindings), registry.allocator)
		copy(entry.required_bindings, required_bindings)
		entry.scan = scan
		entry.user = user
		return .None
	}
	required := make([]u16, len(required_bindings), registry.allocator)
	copy(required, required_bindings)
	append(
		&registry.entries,
		Computed_Relation {
			relation = relation,
			required_bindings = required,
			scan = scan,
			user = user,
		},
	)
	return .None
}

// Removes registrations owned by one runtime world. The user pointer is also
// the ownership token, so destroying an older world cannot remove callbacks
// that a newer world installed for the same relation.
kernel_unregister_computed_relations_by_user :: proc(kernel: ^Kernel, user: rawptr) {
	if kernel == nil || user == nil {
		return
	}
	registry := &kernel.computed
	sync.mutex_lock(&registry.lock)
	defer sync.mutex_unlock(&registry.lock)
	for index := len(registry.entries) - 1; index >= 0; index -= 1 {
		if registry.entries[index].user != user {
			continue
		}
		delete(registry.entries[index].required_bindings, registry.allocator)
		for move := index; move + 1 < len(registry.entries); move += 1 {
			registry.entries[move] = registry.entries[move + 1]
		}
		_ = pop(&registry.entries)
	}
}

kernel_relation_is_computed :: proc(kernel: ^Kernel, relation: Relation_ID) -> bool {
	registry := &kernel.computed
	sync.mutex_lock(&registry.lock)
	defer sync.mutex_unlock(&registry.lock)
	for entry in registry.entries {
		if entry.relation == relation {
			return true
		}
	}
	return false
}

// Returns the stable registration-time requirement slice. Registrations are
// replaced only while a world is loading, before query workers start.
kernel_computed_required_bindings :: proc(
	kernel: ^Kernel,
	relation: Relation_ID,
) -> (
	[]u16,
	bool,
) {
	if kernel == nil {
		return nil, false
	}
	entry, found := computed_relation_lookup(kernel, relation)
	return entry.required_bindings, found
}

@(private)
computed_relation_lookup :: proc(
	kernel: ^Kernel,
	relation: Relation_ID,
) -> (
	Computed_Relation,
	bool,
) {
	registry := &kernel.computed
	sync.mutex_lock(&registry.lock)
	defer sync.mutex_unlock(&registry.lock)
	for entry in registry.entries {
		if entry.relation == relation {
			return entry, true
		}
	}
	return {}, false
}

@(private)
Computed_Filter :: struct {
	bindings: []v.Binding,
	visit:    Computed_Visit_Proc,
	user:     rawptr,
}

@(private)
computed_filter_visit :: proc(user: rawptr, row: v.Tuple) -> bool {
	filter := (^Computed_Filter)(user)
	if !v.tuple_matches_bindings(row, filter.bindings) {
		return true
	}
	return filter.visit(filter.user, row)
}

// Returns `(true, error)` when `relation` is computed. Candidate filtering is
// centralized here, so implementations only produce their natural result set.
computed_relation_visit :: proc(
	source: ^Relation_Source,
	relation: Relation_ID,
	bindings: []v.Binding,
	visit: Computed_Visit_Proc,
	user: rawptr,
) -> (
	bool,
	Kernel_Error,
) {
	kernel := relation_source_kernel(source)
	if kernel == nil {
		return false, .None
	}
	entry, found := computed_relation_lookup(kernel, relation)
	if !found {
		return false, .None
	}
	for position in entry.required_bindings {
		if int(position) >= len(bindings) || !bindings[position].bound {
			return true, .Computed_Binding_Required
		}
	}
	filter := Computed_Filter {
		bindings = bindings,
		visit    = visit,
		user     = user,
	}
	return true, entry.scan(entry.user, source, bindings, computed_filter_visit, &filter)
}
