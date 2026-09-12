package mica_runtime

import "core:sync"
import "core:testing"
import k "../kernel"
import v "../var"

@(private)
subscription_test_env :: proc(
	t: ^testing.T,
	kernel: ^k.Kernel,
	scheduler: ^Scheduler,
	env: ^Builtin_Env,
) {
	k.kernel_init(kernel)
	scheduler_init(scheduler, kernel, Scheduler_Config{workers = 1})
	env^ = Builtin_Env {
		kernel    = kernel,
		scheduler = scheduler,
		allocator = context.temp_allocator,
	}
	subscriptions_init(&env.subscriptions, context.temp_allocator)
}

@(private)
subscription_test_teardown :: proc(
	kernel: ^k.Kernel,
	scheduler: ^Scheduler,
	env: ^Builtin_Env,
) {
	subscriptions_destroy(&env.subscriptions)
	scheduler_destroy(scheduler)
	k.kernel_destroy(kernel)
}

// Stages a :Facts subscription for a sender of an open mailbox, as a task
// with an open transaction would. Returns the receiver, sender, and the
// staged pointer the task holds.
@(private)
subscription_stage_pending :: proc(
	t: ^testing.T,
	env: ^Builtin_Env,
	scheduler: ^Scheduler,
) -> (
	v.Value,
	v.Value,
	^Subscription,
	bool,
) {
	receiver, sender, minted := scheduler_mailbox_create(scheduler)
	testing.expect(t, minted)
	if !minted {
		return v.Value(0), v.Value(0), nil, false
	}
	_, subscription, registered := subscriptions_register(
		env,
		sender,
		.Facts,
		k.Relation_ID(0),
		nil,
		false,
		0,
		false,
		DEFAULT_SUBSCRIPTION_QUEUE_BUDGET,
		true,
	)
	testing.expect(t, registered)
	if !registered {
		return v.Value(0), v.Value(0), nil, false
	}
	return receiver, sender, subscription, true
}

@(private)
subscription_tombstone_state :: proc(store: ^Subscription_Store, id: u64) -> (bool, bool) {
	sync.mutex_lock(&store.lock)
	defer sync.mutex_unlock(&store.lock)
	current, exists := store.entries[id]
	if !exists {
		return false, false
	}
	return true, current.revoked
}

// Cancelling subscriptions for an open mailbox must not free an entry another
// task still has staged: the staging task dereferences the pointer on commit.
// Regression: release freed pending entries, so task_flush_pending touched
// freed memory.
@(test)
test_subscription_cancel_for_mailbox_keeps_staged :: proc(t: ^testing.T) {
	kernel: k.Kernel
	scheduler: Scheduler
	env: Builtin_Env
	subscription_test_env(t, &kernel, &scheduler, &env)
	defer subscription_test_teardown(&kernel, &scheduler, &env)

	receiver, _, staged, staged_ok := subscription_stage_pending(t, &env, &scheduler)
	if !staged_ok {
		return
	}

	// The mailbox is still open, so the cancel reaches the staged entry.
	removed := subscriptions_cancel_for_mailbox(&env, receiver)
	testing.expect_value(t, removed, 1)

	// The staged entry survives as a revoked tombstone, still registered.
	exists, revoked := subscription_tombstone_state(&env.subscriptions, staged.id)
	testing.expect(t, exists)
	testing.expect(t, revoked)
	sync.mutex_lock(&env.subscriptions.lock)
	still_pending := env.subscriptions.entries[staged.id].pending_commit
	sync.mutex_unlock(&env.subscriptions.lock)
	testing.expect(t, still_pending)

	// The stager commits: activation drops the revoked entry without sending
	// a snapshot for it.
	subscriptions_activate(&env, staged)
	sync.mutex_lock(&env.subscriptions.lock)
	_, still := env.subscriptions.entries[staged.id]
	sync.mutex_unlock(&env.subscriptions.lock)
	testing.expect(t, !still)
}

// An explicit cancel of a staged subscription tombstones it too; the stager's
// abort then frees the tombstone exactly once.
@(test)
test_subscription_cancel_then_discard_frees_once :: proc(t: ^testing.T) {
	kernel: k.Kernel
	scheduler: Scheduler
	env: Builtin_Env
	subscription_test_env(t, &kernel, &scheduler, &env)
	defer subscription_test_teardown(&kernel, &scheduler, &env)

	_, _, staged, staged_ok := subscription_stage_pending(t, &env, &scheduler)
	if !staged_ok {
		return
	}

	testing.expect(t, subscriptions_cancel(&env, staged.capability))
	exists, revoked := subscription_tombstone_state(&env.subscriptions, staged.id)
	testing.expect(t, exists)
	testing.expect(t, revoked)

	// The stager aborts: the tombstone is removed, not leaked.
	subscriptions_discard(&env, staged)
	sync.mutex_lock(&env.subscriptions.lock)
	_, still := env.subscriptions.entries[staged.id]
	empty := len(env.subscriptions.entries) == 0
	sync.mutex_unlock(&env.subscriptions.lock)
	testing.expect(t, !still)
	testing.expect(t, empty)
}

// A plain cancel of a live subscription still frees it immediately.
@(test)
test_subscription_cancel_live_frees :: proc(t: ^testing.T) {
	kernel: k.Kernel
	scheduler: Scheduler
	env: Builtin_Env
	subscription_test_env(t, &kernel, &scheduler, &env)
	defer subscription_test_teardown(&kernel, &scheduler, &env)

	_, sender, minted := scheduler_mailbox_create(&scheduler)
	testing.expect(t, minted)

	capability, subscription, registered := subscriptions_register(
		&env,
		sender,
		.Facts,
		k.Relation_ID(0),
		nil,
		false,
		0,
		false,
		DEFAULT_SUBSCRIPTION_QUEUE_BUDGET,
		false,
	)
	testing.expect(t, registered)
	if !registered {
		return
	}
	_ = subscription

	testing.expect(t, subscriptions_cancel(&env, capability))
	sync.mutex_lock(&env.subscriptions.lock)
	_, still := env.subscriptions.entries[subscription.id]
	empty := len(env.subscriptions.entries) == 0
	sync.mutex_unlock(&env.subscriptions.lock)
	testing.expect(t, !still)
	testing.expect(t, empty)
}
