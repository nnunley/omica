// Bearer capabilities: revocable, attenuable handles into world authority.
//
// A capability is a reference to a grant object. Grant objects are
// reference-counted and carry an atomic revoked flag, so revocation is
// observed immediately by every holder. Grants form a tree: a restricted
// capability is a child of the capability it was derived from, and revoking a
// node revokes its whole subtree.
//
// Capability values are ephemeral: they may live in in-memory relation tuples,
// but they are not durable and have no codec.
package kernel

import "core:mem"
import "core:sync"
import "core:time"
import v "../var"

Capability_Right :: enum u8 {
	Read,
	Write,
	Invoke,
	Effect,
	Grant,
}

Rights :: bit_set[Capability_Right]

Capability_Scope :: enum {
	All,
	Relations,
	Selectors,
	Mailbox,
	Subscription,
}

// Optional expiry limits. A zero deadline or epoch limit means no limit. Wall
// deadlines are monotonic ticks; epoch limits compare against the world
// version the capability is used at, which keeps expiry replayable.
Capability_Limits :: struct {
	deadline:    time.Tick,
	epoch_limit: u64,
}

Capability_Grant :: struct {
	rights:      Rights,
	scope:       Capability_Scope,
	relations:   []Relation_ID,
	selectors:   []v.Symbol,
	// Mailbox handles carry the world mailbox id and which end they are.
	mailbox:        u64,
	mailbox_sender: bool,
	// Subscription handles carry the subscription id.
	subscription:   u64,
	revoked:        i32,
	refs:        i32,
	limits:      Capability_Limits,
	children:    [dynamic]^Capability_Grant,
	allocator:   mem.Allocator,
}

// Capability ids start above the scheduler's mailbox ids so the bearer-token
// registries cannot collide.
CAPABILITY_ID_BASE :: u64(0x1_0000_0000)

Capability_Store :: struct {
	lock:      sync.Mutex,
	next_id:   u64,
	grants:    map[u64]^Capability_Grant,
	allocator: mem.Allocator,
}

capability_store_init :: proc(store: ^Capability_Store, allocator := context.allocator) {
	store.next_id = CAPABILITY_ID_BASE
	store.grants = make(map[u64]^Capability_Grant, allocator)
	store.allocator = allocator
}

capability_store_destroy :: proc(store: ^Capability_Store) {
	for _, grant in store.grants {
		capability_release(grant)
	}
	delete(store.grants)
}

// Creates a capability with the given rights and scope. Target slices are
// copied. Returns the capability value.
capability_store_mint :: proc(
	store: ^Capability_Store,
	rights: Rights,
	scope: Capability_Scope,
	relations: []Relation_ID,
	selectors: []v.Symbol,
	limits := Capability_Limits{},
) -> (
	v.Value,
	bool,
) {
	if card(rights) == 0 || (scope == .All && (len(relations) > 0 || len(selectors) > 0)) {
		return v.Value(0), false
	}
	if scope == .Relations && len(relations) == 0 {
		return v.Value(0), false
	}
	if scope == .Selectors && len(selectors) == 0 {
		return v.Value(0), false
	}
	if scope == .Mailbox || scope == .Subscription {
		return v.Value(0), false
	}
	grant := new(Capability_Grant, store.allocator)
	grant.rights = rights
	grant.scope = scope
	grant.limits = limits
	grant.allocator = store.allocator
	grant.children = make([dynamic]^Capability_Grant, store.allocator)
	if len(relations) > 0 {
		grant.relations = make([]Relation_ID, len(relations), store.allocator)
		copy(grant.relations, relations)
	}
	if len(selectors) > 0 {
		grant.selectors = make([]v.Symbol, len(selectors), store.allocator)
		copy(grant.selectors, selectors)
	}
	return capability_store_register(store, grant)
}

// Derives a weaker capability from `parent`. The new capability keeps the
// parent's scope and targets but only the requested subset of its rights, and
// becomes a child in the revocation tree.
capability_store_restrict :: proc(
	store: ^Capability_Store,
	parent_value: v.Value,
	rights: Rights,
) -> (
	v.Value,
	bool,
) {
	sync.mutex_lock(&store.lock)
	defer sync.mutex_unlock(&store.lock)
	parent := capability_store_lookup_locked(store, parent_value)
	if parent == nil || sync.atomic_load(&parent.revoked) != 0 {
		return v.Value(0), false
	}
	restricted := rights & parent.rights
	if card(restricted) == 0 {
		return v.Value(0), false
	}
	child := new(Capability_Grant, store.allocator)
	child.rights = restricted
	child.scope = parent.scope
	child.limits = parent.limits
	child.allocator = store.allocator
	child.children = make([dynamic]^Capability_Grant, store.allocator)
	if len(parent.relations) > 0 {
		child.relations = make([]Relation_ID, len(parent.relations), store.allocator)
		copy(child.relations, parent.relations)
	}
	if len(parent.selectors) > 0 {
		child.selectors = make([]v.Symbol, len(parent.selectors), store.allocator)
		copy(child.selectors, parent.selectors)
	}
	// The parent owns a reference to each child.
	sync.atomic_add(&child.refs, 1)
	append(&parent.children, child)
	value, registered := capability_store_register_locked(store, child)
	if !registered {
		return v.Value(0), false
	}
	return value, true
}

// Mints a mailbox handle: the receiver carries the read right, the sender the
// write right.
capability_store_mint_mailbox :: proc(
	store: ^Capability_Store,
	mailbox: u64,
	sender: bool,
) -> (
	v.Value,
	bool,
) {
	grant := new(Capability_Grant, store.allocator)
	grant.scope = .Mailbox
	grant.mailbox = mailbox
	grant.mailbox_sender = sender
	grant.rights = sender ? Rights{.Write} : Rights{.Read}
	grant.allocator = store.allocator
	grant.children = make([dynamic]^Capability_Grant, store.allocator)
	return capability_store_register(store, grant)
}

// Mints the receiver and sender handles for a mailbox.
capability_store_mint_mailbox_pair :: proc(
	store: ^Capability_Store,
	mailbox: u64,
) -> (
	receiver: v.Value,
	sender: v.Value,
	ok: bool,
) {
	receiver_value, receiver_ok := capability_store_mint_mailbox(store, mailbox, false)
	sender_value, sender_ok := capability_store_mint_mailbox(store, mailbox, true)
	return receiver_value, sender_value, receiver_ok && sender_ok
}

// Mints a subscription handle.
capability_store_mint_subscription :: proc(
	store: ^Capability_Store,
	subscription: u64,
) -> (
	v.Value,
	bool,
) {
	grant := new(Capability_Grant, store.allocator)
	grant.scope = .Subscription
	grant.subscription = subscription
	grant.rights = Rights{.Read}
	grant.allocator = store.allocator
	grant.children = make([dynamic]^Capability_Grant, store.allocator)
	return capability_store_register(store, grant)
}

// Revokes a capability and its whole subtree. Holders observe the revocation
// immediately; store entries for the subtree are removed.
capability_store_revoke :: proc(store: ^Capability_Store, value: v.Value) -> bool {
	sync.mutex_lock(&store.lock)
	defer sync.mutex_unlock(&store.lock)
	grant := capability_store_lookup_locked(store, value)
	if grant == nil {
		return false
	}
	capability_revoke_subtree(grant)
	// Drop store entries for the revoked subtree, releasing their refs. The
	// pointers stay alive while any authority still holds them.
	revoked_ids: [dynamic]u64
	defer delete(revoked_ids)
	for id, candidate in store.grants {
		if sync.atomic_load(&candidate.revoked) != 0 {
			append(&revoked_ids, id)
		}
	}
	for id in revoked_ids {
		if existing, found := store.grants[id]; found {
			delete_key(&store.grants, id)
			capability_release(existing)
		}
	}
	return true
}

@(private)
capability_revoke_subtree :: proc(grant: ^Capability_Grant) {
	if sync.atomic_load(&grant.revoked) != 0 {
		return
	}
	sync.atomic_store(&grant.revoked, 1)
	for child in grant.children {
		capability_revoke_subtree(child)
	}
}

// Looks up a capability by value. The returned grant is borrowed; it stays
// alive while the store entry or an authority reference exists.
capability_store_lookup :: proc(
	store: ^Capability_Store,
	value: v.Value,
) -> (
	^Capability_Grant,
	bool,
) {
	sync.mutex_lock(&store.lock)
	defer sync.mutex_unlock(&store.lock)
	grant := capability_store_lookup_locked(store, value)
	return grant, grant != nil
}

@(private)
capability_store_lookup_locked :: proc(
	store: ^Capability_Store,
	value: v.Value,
) -> ^Capability_Grant {
	id, id_ok := v.value_as_capability(value)
	if !id_ok {
		return nil
	}
	return store.grants[v.capability_id_raw(id)]
}

@(private)
capability_store_register :: proc(
	store: ^Capability_Store,
	grant: ^Capability_Grant,
) -> (
	v.Value,
	bool,
) {
	sync.mutex_lock(&store.lock)
	defer sync.mutex_unlock(&store.lock)
	return capability_store_register_locked(store, grant)
}

@(private)
capability_store_register_locked :: proc(
	store: ^Capability_Store,
	grant: ^Capability_Grant,
) -> (
	v.Value,
	bool,
) {
	store.next_id += 1
	id, id_ok := v.capability_id_new(store.next_id)
	if !id_ok {
		return v.Value(0), false
	}
	sync.atomic_add(&grant.refs, 1)
	store.grants[store.next_id] = grant
	return v.value_capability(id), true
}

// Retains a reference to a grant.
capability_retain :: proc(grant: ^Capability_Grant) {
	if grant == nil {
		return
	}
	sync.atomic_add(&grant.refs, 1)
}

// Releases a reference, freeing the grant and its children at zero.
capability_release :: proc(grant: ^Capability_Grant) {
	if grant == nil {
		return
	}
	old := sync.atomic_sub(&grant.refs, 1)
	if old != 1 {
		return
	}
	for child in grant.children {
		capability_release(child)
	}
	delete(grant.children)
	if grant.relations != nil {
		delete(grant.relations, grant.allocator)
	}
	if grant.selectors != nil {
		delete(grant.selectors, grant.allocator)
	}
	free(grant, grant.allocator)
}

// Reports whether a grant is live at the given world version and wall time.
capability_live :: proc(grant: ^Capability_Grant, epoch: u64, now: time.Tick) -> bool {
	if grant == nil || sync.atomic_load(&grant.revoked) != 0 {
		return false
	}
	if grant.limits.deadline._nsec != 0 &&
	   time.tick_diff(grant.limits.deadline, now) > 0 {
		return false
	}
	if grant.limits.epoch_limit != 0 && epoch >= grant.limits.epoch_limit {
		return false
	}
	return true
}

capability_allows_read :: proc(grant: ^Capability_Grant, relation: Relation_ID) -> bool {
	if .Read not_in grant.rights {
		return false
	}
	switch grant.scope {
	case .All:
		return true
	case .Relations:
		for candidate in grant.relations {
			if candidate == relation {
				return true
			}
		}
	case .Selectors, .Mailbox, .Subscription:
	}
	return false
}

capability_allows_write :: proc(grant: ^Capability_Grant, relation: Relation_ID) -> bool {
	if .Write not_in grant.rights {
		return false
	}
	switch grant.scope {
	case .All:
		return true
	case .Relations:
		for candidate in grant.relations {
			if candidate == relation {
				return true
			}
		}
	case .Selectors, .Mailbox, .Subscription:
	}
	return false
}

capability_allows_invoke :: proc(grant: ^Capability_Grant, selector: v.Symbol) -> bool {
	if .Invoke not_in grant.rights {
		return false
	}
	switch grant.scope {
	case .All:
		return true
	case .Selectors:
		for candidate in grant.selectors {
			if candidate == selector {
				return true
			}
		}
	case .Relations, .Mailbox, .Subscription:
	}
	return false
}

// Returns the mailbox id when the grant is a live handle of the requested
// kind.
capability_mailbox_target :: proc(
	grant: ^Capability_Grant,
	sender: bool,
) -> (
	u64,
	bool,
) {
	if grant == nil || grant.scope != .Mailbox || grant.mailbox_sender != sender {
		return 0, false
	}
	return grant.mailbox, true
}

// Returns the subscription id when the grant is a subscription handle.
capability_subscription_target :: proc(grant: ^Capability_Grant) -> (u64, bool) {
	if grant == nil || grant.scope != .Subscription {
		return 0, false
	}
	return grant.subscription, true
}

// Reports whether the grant allows invoking any method (all-scoped invoke).
capability_allows_invoke_any :: proc(grant: ^Capability_Grant) -> bool {
	return .Invoke in grant.rights && grant.scope == .All
}

capability_allows_effect :: proc(grant: ^Capability_Grant) -> bool {
	return .Effect in grant.rights && grant.scope == .All
}

capability_allows_grant :: proc(grant: ^Capability_Grant) -> bool {
	return .Grant in grant.rights && grant.scope == .All
}
