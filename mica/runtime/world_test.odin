// Tests for the long-lived world API.
package mica_runtime

import "core:os"
import "core:testing"
import k "../kernel"
import v "../var"

@(private)
role_x :: proc(value: v.Value) -> k.Role_Pair {
	return k.Role_Pair {
		role  = v.value_symbol(v.symbol_intern("x")),
		value = value,
	}
}

@(test)
test_world_start_and_call :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	source := `make_relation(:Out, 1)
verb record(x)
  assert Out(x)
end
`
	path, path_ok := write_temp_source(t, "mica_world_call_test.mica", source)
	if !path_ok {
		return
	}
	defer os.remove(path)

	kernel: k.Kernel
	k.kernel_init(&kernel)
	defer k.kernel_destroy(&kernel)

	world, result := world_start(&kernel, []string{path}, context.temp_allocator)
	testing.expectf(t, result.ok, "world start failed: %s", result.message)
	if !result.ok {
		return
	}
	defer world_destroy(world)

	entry := world_wait(world, world.entry)
	testing.expect_value(t, entry.kind, Task_Outcome_Kind.Complete)

	seven, _ := v.value_int(7)
	eight, _ := v.value_int(8)
	outcome := world_call(world, "record", []k.Role_Pair{role_x(seven)})
	testing.expectf(t, outcome.kind == .Complete, "call failed: %s", outcome.message)
	outcome_two := world_call(world, "record", []k.Role_Pair{role_x(eight)})
	testing.expectf(t, outcome_two.kind == .Complete, "second call failed: %s", outcome_two.message)

	expect_relation_rows(t, &kernel, "Out", 2)
	// Released call entries leave only the entry task.
	testing.expect_value(t, len(world.scheduler.entries), 1)
}

@(test)
test_world_unknown_selector :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	source := "make_relation(:Out, 1)\n"
	path, path_ok := write_temp_source(t, "mica_world_missing_test.mica", source)
	if !path_ok {
		return
	}
	defer os.remove(path)

	kernel: k.Kernel
	k.kernel_init(&kernel)
	defer k.kernel_destroy(&kernel)

	world, result := world_start(&kernel, []string{path}, context.temp_allocator)
	testing.expectf(t, result.ok, "world start failed: %s", result.message)
	if !result.ok {
		return
	}
	defer world_destroy(world)

	outcome := world_call(world, "missing", nil)
	testing.expect_value(t, outcome.kind, Task_Outcome_Kind.Aborted)
	testing.expect_value(t, outcome.message, "no applicable method")
}

@(test)
test_world_multiple_workers :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	source := `make_relation(:Out, 1)
verb record(x)
  assert Out(x)
end
`
	path, path_ok := write_temp_source(t, "mica_world_workers_test.mica", source)
	if !path_ok {
		return
	}
	defer os.remove(path)

	kernel: k.Kernel
	k.kernel_init(&kernel)
	defer k.kernel_destroy(&kernel)

	world, result := world_start(
		&kernel,
		[]string{path},
		context.temp_allocator,
		World_Config{workers = 2},
	)
	testing.expectf(t, result.ok, "world start failed: %s", result.message)
	if !result.ok {
		return
	}
	defer world_destroy(world)

	entry := world_wait(world, world.entry)
	testing.expect_value(t, entry.kind, Task_Outcome_Kind.Complete)

	for index in 0 ..< 8 {
		value, _ := v.value_int(i64(index) + 1)
		outcome := world_call(world, "record", []k.Role_Pair{role_x(value)})
		testing.expectf(t, outcome.kind == .Complete, "call %d failed: %s", index, outcome.message)
	}
	expect_relation_rows(t, &kernel, "Out", 8)
}

@(test)
test_world_call_with_facts :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	source := `make_relation(:In, 1)
make_relation(:Out, 1)
verb probe(x)
  let found = In(?v)
  for row in found
    assert Out(row[:v])
  end
end
`
	path, path_ok := write_temp_source(t, "mica_world_facts_test.mica", source)
	if !path_ok {
		return
	}
	defer os.remove(path)

	kernel: k.Kernel
	k.kernel_init(&kernel)
	defer k.kernel_destroy(&kernel)

	world, start := world_start(&kernel, []string{path}, context.temp_allocator)
	testing.expectf(t, start.ok, "world start failed: %s", start.message)
	if !start.ok {
		return
	}
	defer world_destroy(world)

	entry := world_wait(world, world.entry)
	testing.expect_value(t, entry.kind, Task_Outcome_Kind.Complete)

	snapshot := k.kernel_snapshot(&kernel)
	metadata, found := k.snapshot_relation_metadata_named(snapshot, v.symbol_intern("In"))
	k.snapshot_release(snapshot)
	testing.expect(t, found)
	in_value, _ := v.value_int(42)
	placeholder, _ := v.value_int(0)
	facts := []World_Fact{{
		relation = metadata.id,
		tuple    = v.tuple_new(context.temp_allocator, []v.Value{in_value}),
	}}
	result := world_submit_call_with_facts(
		world,
		"probe",
		[]k.Role_Pair{role_x(placeholder)},
		facts,
	)
	testing.expect_value(t, result.error, Dispatch_Error.None)
	if result.id == 0 {
		return
	}
	outcome := world_wait(world, result.id)
	world_release(world, result.id)
	testing.expectf(t, outcome.kind == .Complete, "probe failed: %s", outcome.message)
	expect_relation_rows(t, &kernel, "Out", 1)
}
