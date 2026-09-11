// Change subscriptions.
//
// `subscribe_changes` registers a relation pattern and a mailbox sender handle.
// After every committed transaction the store drains the kernel change feed
// from each subscription's cursor and posts change messages to the mailbox.
// Subscription handles are capability-store entries, so they can be revoked
// like any other capability or cancelled explicitly.
package mica_runtime

import "core:mem"
import "core:sync"
import "core:time"
import k "../kernel"
import v "../var"

@(private)
Subscription :: struct {
	capability: v.Value,
	sender:     v.Value,
	relation:   k.Relation_ID,
	bindings:   []v.Binding,
	cursor:     u64,
}

@(private)
Subscription_Store :: struct {
	lock:      sync.Mutex,
	next_id:   u64,
	entries:   map[u64]^Subscription,
	allocator: mem.Allocator,
}

@(private)
subscriptions_init :: proc(store: ^Subscription_Store, allocator: mem.Allocator) {
	store.entries = make(map[u64]^Subscription, allocator)
	store.allocator = allocator
	store.next_id = 1
}

@(private)
subscriptions_destroy :: proc(store: ^Subscription_Store) {
	for _, subscription in store.entries {
		if subscription.bindings != nil {
			delete(subscription.bindings, store.allocator)
		}
		free(subscription, store.allocator)
	}
	delete(store.entries)
}

// Registers a subscription and returns its capability handle. When
// `initial_snapshot` is set and no cursor is given, the current matching rows
// are delivered before registration.
@(private)
subscriptions_register :: proc(
	env: ^Builtin_Env,
	sender: v.Value,
	relation: k.Relation_ID,
	bindings: []v.Binding,
	initial_snapshot: bool,
	cursor: u64,
	has_cursor: bool,
) -> (
	v.Value,
	bool,
) {
	if env.scheduler == nil {
		return v.Value(0), false
	}
	snapshot := k.kernel_snapshot(env.kernel)
	version := snapshot.version
	k.snapshot_release(snapshot)

	cursor_value := version
	if has_cursor {
		cursor_value = cursor
	}

	sync.mutex_lock(&env.subscriptions.lock)
	env.subscriptions.next_id += 1
	subscription_id := env.subscriptions.next_id
	capability, minted := k.capability_store_mint_subscription(
		&env.kernel.capabilities,
		subscription_id,
	)
	if !minted {
		sync.mutex_unlock(&env.subscriptions.lock)
		return v.Value(0), false
	}
	subscription := new(Subscription, env.subscriptions.allocator)
	subscription.capability = capability
	subscription.sender = sender
	subscription.relation = relation
	subscription.bindings = make([]v.Binding, len(bindings), env.subscriptions.allocator)
	copy(subscription.bindings, bindings)
	subscription.cursor = cursor_value
	env.subscriptions.entries[subscription_id] = subscription
	sync.mutex_unlock(&env.subscriptions.lock)

	if initial_snapshot && !has_cursor {
		rows := subscription_scan_rows(env, relation, bindings)
		defer delete(rows)
		row_values := subscription_row_values(env, rows[:])
		defer delete(row_values)
		message := subscription_message(
			env,
			capability,
			"snapshot",
			version,
			row_values[:],
			nil,
		)
		_ = scheduler_mailbox_send(env.scheduler, sender, message)
	}
	return capability, true
}

// Cancels a subscription by its capability handle.
@(private)
subscriptions_cancel :: proc(env: ^Builtin_Env, capability: v.Value) -> bool {
	grant, found := k.capability_store_lookup(&env.kernel.capabilities, capability)
	if !found {
		return false
	}
	subscription_id, is_subscription := k.capability_subscription_target(grant)
	if !is_subscription {
		return false
	}
	sync.mutex_lock(&env.subscriptions.lock)
	subscriptions_release_locked(&env.subscriptions, subscription_id)
	sync.mutex_unlock(&env.subscriptions.lock)
	k.capability_store_revoke(&env.kernel.capabilities, capability)
	return true
}

// Cancels every subscription that delivers to `receiver`'s mailbox.
@(private)
subscriptions_cancel_for_mailbox :: proc(env: ^Builtin_Env, receiver: v.Value) -> int {
	grant, found := k.capability_store_lookup(&env.kernel.capabilities, receiver)
	if !found {
		return 0
	}
	mailbox, is_receiver := k.capability_mailbox_target(grant, false)
	if !is_receiver {
		return 0
	}
	sync.mutex_lock(&env.subscriptions.lock)
	removed := 0
	to_cancel: [dynamic]v.Value
	defer delete(to_cancel)
	for _, subscription in env.subscriptions.entries {
		sender_grant, sender_found := k.capability_store_lookup(
			&env.kernel.capabilities,
			subscription.sender,
		)
		if !sender_found {
			continue
		}
		sender_mailbox, is_sender := k.capability_mailbox_target(sender_grant, true)
		if !is_sender || sender_mailbox != mailbox {
			continue
		}
		append(&to_cancel, subscription.capability)
	}
	for capability in to_cancel {
		if grant_value, grant_found := k.capability_store_lookup(
			&env.kernel.capabilities,
			capability,
		); grant_found {
			if subscription_id, is_subscription := k.capability_subscription_target(
				grant_value,
			); is_subscription {
				subscriptions_release_locked(&env.subscriptions, subscription_id)
				removed += 1
			}
		}
	}
	sync.mutex_unlock(&env.subscriptions.lock)
	for capability in to_cancel {
		k.capability_store_revoke(&env.kernel.capabilities, capability)
	}
	return removed
}

@(private)
subscriptions_release_locked :: proc(store: ^Subscription_Store, subscription_id: u64) {
	if subscription, exists := store.entries[subscription_id]; exists {
		if subscription.bindings != nil {
			delete(subscription.bindings, store.allocator)
		}
		free(subscription, store.allocator)
		delete_key(&store.entries, subscription_id)
	}
}

// Delivers pending changes for every live subscription. Runs after a
// transaction commits.
@(private)
subscriptions_dispatch :: proc(env: ^Builtin_Env) {
	if env == nil || env.scheduler == nil {
		return
	}
	store := &env.subscriptions
	sync.mutex_lock(&store.lock)
	to_release: [dynamic]u64
	defer delete(to_release)
	for subscription_id, subscription in store.entries {
		if !subscription_is_live(env, subscription) {
			append(&to_release, subscription_id)
			continue
		}
		if !subscription_deliver(env, subscription) {
			append(&to_release, subscription_id)
		}
	}
	for subscription_id in to_release {
		subscriptions_release_locked(store, subscription_id)
	}
	sync.mutex_unlock(&store.lock)
}

@(private)
subscription_is_live :: proc(env: ^Builtin_Env, subscription: ^Subscription) -> bool {
	grant, found := k.capability_store_lookup(
		&env.kernel.capabilities,
		subscription.capability,
	)
	if !found {
		return false
	}
	if _, is_subscription := k.capability_subscription_target(grant); !is_subscription {
		return false
	}
	return k.capability_live(grant, 0, time.tick_now())
}

@(private)
Subscription_Collector :: struct {
	env:          ^Builtin_Env,
	subscription: ^Subscription,
	asserted:     [dynamic]v.Value,
	retracted:    [dynamic]v.Value,
}

@(private)
subscription_deliver :: proc(env: ^Builtin_Env, subscription: ^Subscription) -> bool {
	collector := Subscription_Collector {
		env          = env,
		subscription = subscription,
	}
	defer delete(collector.asserted)
	defer delete(collector.retracted)

	latest, within_window := k.changes_visit(
		&env.kernel.changes,
		subscription.cursor,
		&collector,
		subscription_collect,
	)
	if !within_window {
		rows := subscription_scan_rows(env, subscription.relation, subscription.bindings)
		defer delete(rows)
		row_values := subscription_row_values(env, rows[:])
		defer delete(row_values)
		message := subscription_message(
			env,
			subscription.capability,
			"snapshot",
			latest,
			row_values[:],
			nil,
		)
		subscription.cursor = latest
		return scheduler_mailbox_send(env.scheduler, subscription.sender, message)
	}
	if len(collector.asserted) == 0 && len(collector.retracted) == 0 {
		subscription.cursor = latest
		return true
	}
	message := subscription_message(
		env,
		subscription.capability,
		"changes",
		latest,
		collector.asserted[:],
		collector.retracted[:],
	)
	subscription.cursor = latest
	return scheduler_mailbox_send(env.scheduler, subscription.sender, message)
}

@(private)
subscription_collect :: proc(user: rawptr, record: ^k.Change_Record) -> bool {
	collector := (^Subscription_Collector)(user)
	if record.relation != collector.subscription.relation {
		return true
	}
	for tuple in record.asserted {
		if subscription_row_matches(collector.subscription.bindings, tuple) {
			append(
				&collector.asserted,
				subscription_row_value(collector.env, tuple),
			)
		}
	}
	for tuple in record.retracted {
		if subscription_row_matches(collector.subscription.bindings, tuple) {
			append(
				&collector.retracted,
				subscription_row_value(collector.env, tuple),
			)
		}
	}
	return true
}

@(private)
subscription_row_matches :: proc(bindings: []v.Binding, tuple: v.Tuple) -> bool {
	cells := v.tuple_values(tuple)
	if len(bindings) > 0 && len(bindings) != len(cells) {
		return false
	}
	for binding, index in bindings {
		if binding.bound && !v.value_eq(binding.value, cells[index]) {
			return false
		}
	}
	return true
}

@(private)
subscription_row_value :: proc(env: ^Builtin_Env, tuple: v.Tuple) -> v.Value {
	return v.value_list(env.allocator, v.tuple_values(tuple))
}

@(private)
subscription_row_values :: proc(env: ^Builtin_Env, rows: []v.Tuple) -> [dynamic]v.Value {
	values: [dynamic]v.Value
	for row in rows {
		append(&values, subscription_row_value(env, row))
	}
	return values
}

@(private)
subscription_scan_rows :: proc(
	env: ^Builtin_Env,
	relation: k.Relation_ID,
	bindings: []v.Binding,
) -> [dynamic]v.Tuple {
	rows: [dynamic]v.Tuple
	snapshot := k.kernel_snapshot(env.kernel)
	defer k.snapshot_release(snapshot)
	source := k.Relation_Source {
		snapshot           = snapshot,
		use_stored_derived = true,
	}
	k.relation_source_scan_into(&source, relation, bindings, &rows)
	return rows
}

@(private)
subscription_message :: proc(
	env: ^Builtin_Env,
	capability: v.Value,
	kind: string,
	cursor: u64,
	asserted: []v.Value,
	retracted: []v.Value,
) -> v.Value {
	cursor_value, _ := v.value_int(i64(cursor))
	return v.value_map(env.allocator, []v.Map_Entry {
		{
			key   = v.value_symbol(v.symbol_intern("kind")),
			value = v.value_symbol(v.symbol_intern(kind)),
		},
		{key = v.value_symbol(v.symbol_intern("subscription")), value = capability},
		{key = v.value_symbol(v.symbol_intern("cursor")), value = cursor_value},
		{
			key   = v.value_symbol(v.symbol_intern("subject")),
			value = v.value_symbol(v.symbol_intern("facts")),
		},
		{
			key   = v.value_symbol(v.symbol_intern("assertions")),
			value = v.value_list(env.allocator, asserted),
		},
		{
			key   = v.value_symbol(v.symbol_intern("retractions")),
			value = v.value_list(env.allocator, retracted),
		},
	})
}
