// Concurrent host calls into one world.
package mica_runtime

import "base:runtime"
import "core:os"
import "core:testing"
import k "../kernel"
import v "../var"

// Many calls in flight at once, each dispatching to a verb that commits. The
// world gets a thread-safe allocator, but the test's own context allocator is
// not thread-safe: scheduler threads must not inherit it.
@(test)
test_world_concurrent_calls :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	source := `make_identity(:rock)
make_relation(:Heard, 2)
verb note(who, what)
  assert Heard(who, what)
end
`
	path, ok := write_temp_source(t, "mica_concurrent_calls.mica", source)
	if !ok {
		return
	}
	defer os.remove(path)

	kernel: k.Kernel
	k.kernel_init(&kernel)
	defer k.kernel_destroy(&kernel)
	world, start := world_start(
		&kernel,
		[]string{path},
		runtime.heap_allocator(),
		World_Config{workers = 4},
	)
	testing.expectf(t, start.ok, "load failed: %s", start.message)
	if !start.ok {
		return
	}
	defer world_destroy(world)
	testing.expect_value(t, world_wait(world, world.entry).kind, Task_Outcome_Kind.Complete)

	CALLS :: 40
	ids: [CALLS]Task_ID
	rock := world.ctx.identities["rock"]
	for index in 0 ..< CALLS {
		what, what_ok := v.value_int(i64(index))
		testing.expect(t, what_ok)
		ids[index] = world_submit_call(
			world,
			"note",
			[]k.Role_Pair {
				{role = v.value_symbol(v.symbol_intern("who")), value = rock},
				{role = v.value_symbol(v.symbol_intern("what")), value = what},
			},
		)
		testing.expect(t, ids[index] != 0)
	}
	for id in ids {
		outcome := world_wait(world, id)
		testing.expectf(t, outcome.kind == .Complete, "concurrent note failed: %s", outcome.message)
		world_release(world, id)
	}
	expect_relation_rows(t, &kernel, "Heard", CALLS)
}

// Tasks talk to each other through mailboxes while many run at once: each
// call spawns a partner task, which sends a value back to the caller's
// mailbox, so message values cross tasks and scheduler threads.
@(test)
test_world_concurrent_mailbox_exchange :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	source := `make_relation(:Echoed, 2)
verb echo(sender_cap, value)
  mailbox_send(sender_cap, [value, value * 2])
end
verb ask(n)
  let [receiver, sender] = mailbox()
  spawn :echo(sender_cap: sender, value: n)
  let ready = mailbox_recv([receiver])
  let reply = ready[0][1][0]
  assert Echoed(reply[0], reply[1])
  return reply[1]
end
`
	path, ok := write_temp_source(t, "mica_concurrent_mailbox.mica", source)
	if !ok {
		return
	}
	defer os.remove(path)

	kernel: k.Kernel
	k.kernel_init(&kernel)
	defer k.kernel_destroy(&kernel)
	world, start := world_start(
		&kernel,
		[]string{path},
		runtime.heap_allocator(),
		World_Config{workers = 4},
	)
	testing.expectf(t, start.ok, "load failed: %s", start.message)
	if !start.ok {
		return
	}
	defer world_destroy(world)
	testing.expect_value(t, world_wait(world, world.entry).kind, Task_Outcome_Kind.Complete)

	CALLS :: 40
	ids: [CALLS]Task_ID
	for index in 0 ..< CALLS {
		n, n_ok := v.value_int(i64(index))
		testing.expect(t, n_ok)
		ids[index] = world_submit_call(
			world,
			"ask",
			[]k.Role_Pair{{role = v.value_symbol(v.symbol_intern("n")), value = n}},
		)
		testing.expect(t, ids[index] != 0)
	}
	for id, index in ids {
		outcome := world_wait(world, id)
		testing.expectf(t, outcome.kind == .Complete, "ask failed: %s", outcome.message)
		if outcome.kind == .Complete {
			doubled, is_int := v.value_as_int(outcome.value)
			testing.expect(t, is_int && doubled == i64(index * 2))
		}
		world_release(world, id)
	}
	expect_relation_rows(t, &kernel, "Echoed", CALLS)
}
