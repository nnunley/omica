// Bearer capabilities: minted grants that a task can adopt into its authority.
//
// Capability values are ephemeral; persistence is deliberately out of scope.
// A world-scoped store maps capability ids to grants. A task adopts a
// capability by looking it up and merging the grant into its authority.
package kernel

import "core:mem"
import "core:sync"
import v "../var"

Capability_Scope :: enum {
	All,
	Relation,
	Method,
	Builtin,
}

// A grant describes what a capability allows. Relation and method scopes carry
// their target; effect and grant capabilities use the All scope.
Capability_Grant :: struct {
	read:     bool,
	write:    bool,
	invoke:   bool,
	effect:   bool,
	grant:    bool,
	scope:    Capability_Scope,
	relation: Relation_ID,
	selector: v.Symbol,
}

capability_grant_all :: proc() -> Capability_Grant {
	return Capability_Grant {
		read   = true,
		write  = true,
		invoke = true,
		effect = true,
		grant  = true,
		scope  = .All,
	}
}

capability_grant_relation :: proc(relation: Relation_ID, read: bool) -> Capability_Grant {
	return Capability_Grant {
		read     = read,
		write    = !read,
		scope    = .Relation,
		relation = relation,
	}
}

capability_grant_invoke :: proc(selector: v.Symbol) -> Capability_Grant {
	return Capability_Grant {
		invoke   = true,
		scope    = .Builtin,
		selector = selector,
	}
}

capability_grant_effect :: proc() -> Capability_Grant {
	return Capability_Grant {
		effect = true,
		scope  = .All,
	}
}

capability_grant_grant :: proc() -> Capability_Grant {
	return Capability_Grant {
		grant = true,
		scope = .All,
	}
}

// The capability id space starts above the scheduler's mailbox ids so the two
// bearer-token registries cannot collide.
CAPABILITY_ID_BASE :: u64(0x1_0000_0000)

Capability_Store :: struct {
	lock:    sync.Mutex,
	next_id: u64,
	grants:  map[u64]Capability_Grant,
}

capability_store_init :: proc(store: ^Capability_Store, allocator := context.allocator) {
	store.next_id = CAPABILITY_ID_BASE
	store.grants = make(map[u64]Capability_Grant, allocator)
}

capability_store_destroy :: proc(store: ^Capability_Store) {
	delete(store.grants)
}

// Creates a capability value for `grant`.
capability_store_mint :: proc(
	store: ^Capability_Store,
	grant: Capability_Grant,
) -> (
	v.Value,
	bool,
) {
	sync.mutex_lock(&store.lock)
	defer sync.mutex_unlock(&store.lock)
	store.next_id += 1
	id, id_ok := v.capability_id_new(store.next_id)
	if !id_ok {
		return v.Value(0), false
	}
	store.grants[store.next_id] = grant
	return v.value_capability(id), true
}

// Looks up the grant behind a capability value.
capability_store_lookup :: proc(
	store: ^Capability_Store,
	value: v.Value,
) -> (
	Capability_Grant,
	bool,
) {
	id, id_ok := v.value_as_capability(value)
	if !id_ok {
		return {}, false
	}
	sync.mutex_lock(&store.lock)
	defer sync.mutex_unlock(&store.lock)
	grant, found := store.grants[v.capability_id_raw(id)]
	return grant, found
}
