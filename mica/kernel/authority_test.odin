package kernel

import "core:testing"
import "core:time"
import v "../var"

@(test)
test_authority_minted_from_policy_facts :: proc(t: ^testing.T) {
	kernel: Kernel
	kernel_init(&kernel)
	defer kernel_destroy(&kernel)

	secret := create_relation(&kernel, 70, "Secret", 1)
	leak := create_relation(&kernel, 71, "Leak", 1)
	can_read := create_relation(&kernel, 72, "CanRead", 2)
	role_can_write := create_relation(&kernel, 73, "RoleCanWrite", 2)
	can_invoke := create_relation(&kernel, 74, "CanInvoke", 2)
	role_can_effect := create_relation(&kernel, 75, "RoleCanEffect", 1)
	delegates := create_relation(
		&kernel,
		u32(DISPATCH_DELEGATES_ID),
		"Delegates",
		3,
	)
	method_selector := create_relation(
		&kernel,
		u32(DISPATCH_METHOD_SELECTOR_ID),
		"MethodSelector",
		2,
	)

	actor_value := must_identity(0x100)
	role_value := must_identity(0x101)
	method_value := must_identity(0x200)
	selector := sym("look")

	tx := kernel_begin(&kernel)
	defer transaction_destroy(&tx)
	testing.expect_value(
		t,
		transaction_assert(&tx, delegates, tuple_of(actor_value, role_value, must_int(0))),
		Kernel_Error.None,
	)
	testing.expect_value(
		t,
		transaction_assert(&tx, can_read, tuple_of(actor_value, sym("Secret"))),
		Kernel_Error.None,
	)
	testing.expect_value(
		t,
		transaction_assert(&tx, role_can_write, tuple_of(role_value, sym("Leak"))),
		Kernel_Error.None,
	)
	testing.expect_value(
		t,
		transaction_assert(&tx, can_invoke, tuple_of(role_value, selector)),
		Kernel_Error.None,
	)
	testing.expect_value(
		t,
		transaction_assert(&tx, method_selector, tuple_of(method_value, selector)),
		Kernel_Error.None,
	)
	testing.expect_value(
		t,
		transaction_assert(&tx, role_can_effect, tuple_of(role_value)),
		Kernel_Error.None,
	)
	commit_transaction(t, &tx)

	actor, _ := v.value_as_identity(actor_value)
	source := Relation_Source {
		snapshot = kernel.current,
	}
	authority := authority_from_actor(&source, actor)
	defer authority_destroy(&authority)

	testing.expect(t, authority_can_read(&authority, secret))
	testing.expect(t, !authority_can_read(&authority, leak))
	testing.expect(t, authority_can_write(&authority, leak))
	testing.expect(t, !authority_can_write(&authority, secret))
	testing.expect(t, authority_can_invoke_method(&authority, method_value))
	testing.expect(t, authority_can_invoke_builtin(&authority, v.symbol_intern("look")))
	testing.expect(t, authority_can_effect(&authority))
}

@(test)
test_authority_empty_denies_and_root_allows :: proc(t: ^testing.T) {
	empty := authority_empty(context.temp_allocator)
	defer authority_destroy(&empty)
	testing.expect(t, !authority_can_read(&empty, Relation_ID(70)))
	testing.expect(t, !authority_can_write(&empty, Relation_ID(70)))
	testing.expect(t, !authority_can_effect(&empty))

	root := authority_root(context.temp_allocator)
	testing.expect(t, authority_can_read(&root, Relation_ID(70)))
	testing.expect(t, authority_can_write(&root, Relation_ID(70)))
	testing.expect(t, authority_can_effect(&root))
}

@(test)
test_capability_store_revoke_and_expiry :: proc(t: ^testing.T) {
	store: Capability_Store
	capability_store_init(&store, context.temp_allocator)
	defer capability_store_destroy(&store)

	secret := Relation_ID(70)
	leak := Relation_ID(71)
	now := time.tick_now()

	value, minted := capability_store_mint(
		&store,
		{.Read},
		.Relations,
		[]Relation_ID{secret},
		nil,
	)
	testing.expect(t, minted)
	grant, found := capability_store_lookup(&store, value)
	testing.expect(t, found)
	testing.expect(t, capability_live(grant, 0, now))
	testing.expect(t, capability_allows_read(grant, secret))
	testing.expect(t, !capability_allows_read(grant, leak))

	restricted_value, restricted_ok := capability_store_restrict(&store, value, {.Read})
	testing.expect(t, restricted_ok)
	restricted, restricted_found := capability_store_lookup(&store, restricted_value)
	testing.expect(t, restricted_found)
	testing.expect(t, capability_allows_read(restricted, secret))
	_, no_rights := capability_store_restrict(&store, value, {.Write})
	testing.expect(t, !no_rights)

	testing.expect(t, capability_store_revoke(&store, value))
	testing.expect(t, !capability_live(restricted, 0, time.tick_now()))
	testing.expect(t, !capability_store_revoke(&store, value))

	epoch_value, epoch_minted := capability_store_mint(
		&store,
		{.Read},
		.Relations,
		[]Relation_ID{secret},
		nil,
		Capability_Limits{epoch_limit = 10},
	)
	testing.expect(t, epoch_minted)
	epoch_grant, _ := capability_store_lookup(&store, epoch_value)
	testing.expect(t, capability_live(epoch_grant, 9, now))
	testing.expect(t, !capability_live(epoch_grant, 10, now))

	expired_value, expired_minted := capability_store_mint(
		&store,
		{.Read},
		.Relations,
		[]Relation_ID{secret},
		nil,
		Capability_Limits{deadline = time.tick_add(now, -time.Second)},
	)
	testing.expect(t, expired_minted)
	expired_grant, _ := capability_store_lookup(&store, expired_value)
	testing.expect(t, !capability_live(expired_grant, 0, now))
}

@(test)
test_authority_adopts_revocable_capability :: proc(t: ^testing.T) {
	store: Capability_Store
	capability_store_init(&store, context.temp_allocator)
	defer capability_store_destroy(&store)

	secret := Relation_ID(70)
	leak := Relation_ID(71)
	value, minted := capability_store_mint(
		&store,
		{.Read},
		.Relations,
		[]Relation_ID{secret},
		nil,
	)
	testing.expect(t, minted)
	grant, found := capability_store_lookup(&store, value)
	testing.expect(t, found)

	authority := authority_empty(context.temp_allocator)
	defer authority_destroy(&authority)
	authority_set_clock(&authority, 0, time.tick_now())
	authority_adopt_capability(&authority, grant)
	testing.expect(t, authority_holds_capability(&authority, grant))
	testing.expect(t, authority_can_read(&authority, secret))
	testing.expect(t, !authority_can_read(&authority, leak))

	testing.expect(t, authority_drop_capability(&authority, grant))
	testing.expect(t, !authority_can_read(&authority, secret))

	authority_adopt_capability(&authority, grant)
	testing.expect(t, authority_can_read(&authority, secret))
	testing.expect(t, capability_store_revoke(&store, value))
	testing.expect(t, !authority_can_read(&authority, secret))
}
