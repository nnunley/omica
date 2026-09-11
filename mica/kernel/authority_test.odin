package kernel

import "core:testing"
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
