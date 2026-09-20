// External host-request bridge tests: compiler lowering, worker dispatch, and
// stream delivery to a mailbox.
package mica_runtime

import "core:fmt"
import "core:os"
import "core:testing"
import c "../compiler"
import k "../kernel"
import v "../var"

@(private)
test_payload_lookup :: proc(payload: v.Value, name: string) -> (v.Value, bool) {
	entries, is_map := v.value_as_map(payload)
	if !is_map {
		return v.Value(0), false
	}
	key := v.value_symbol(v.symbol_intern(name))
	for entry in entries {
		if v.value_eq(entry.key, key) {
			return entry.value, true
		}
	}
	return v.Value(0), false
}

// A fake host bridge. It is stateless so tests can run concurrently under the
// Odin test runner: the answer echoes the service and model, and a payload
// with `stream_to` gets one stream event.
@(private)
test_external_handler :: proc(
	ctx: External_Context,
	service: v.Value,
	payload: v.Value,
) -> v.Value {
	service_name := ""
	if symbol, is_symbol := v.value_as_symbol(service); is_symbol {
		service_name, _ = v.symbol_name(symbol)
	}
	model := ""
	if model_value, found := test_payload_lookup(payload, "model"); found {
		model, _ = v.value_as_string(model_value)
	}
	if sender, streaming := test_payload_lookup(payload, "stream_to"); streaming {
		event := v.value_map(ctx.allocator, []v.Map_Entry {
			{
				key   = v.value_symbol(v.symbol_intern("type")),
				value = v.value_symbol(v.symbol_intern("text_delta")),
			},
			{
				key   = v.value_symbol(v.symbol_intern("delta")),
				value = v.value_string(ctx.allocator, "hello"),
			},
		})
		_ = ctx.deliver(ctx.user, sender, event)
		return v.value_map(ctx.allocator, []v.Map_Entry {
			{key = v.value_symbol(v.symbol_intern("started")), value = v.value_bool(true)},
		})
	}
	return v.value_string(
		ctx.allocator,
		fmt.aprintf("%s:%s", service_name, model, allocator = context.temp_allocator),
	)
}

// Starts a world over `source` with `handler`. The caller owns `kernel` and
// the returned world.
@(private)
external_world :: proc(
	t: ^testing.T,
	kernel: ^k.Kernel,
	source: string,
	handler: External_Handler,
	name: string,
) -> (^World, bool) {
	path, path_ok := write_temp_source(t, name, source)
	if !path_ok {
		return nil, false
	}
	defer os.remove(path)

	k.kernel_init(kernel)
	// The world allocator is used by scheduler and external worker threads
	// concurrently, so it must be the thread-safe temporary arena (as the
	// other world tests do), not the test runner's per-thread rollback stack.
	world, start := world_start(
		kernel,
		[]string{path},
		context.temp_allocator,
		World_Config {
			workers          = 1,
			external_handler = handler,
			external_workers = 1,
		},
	)
	if !start.ok {
		testing.expectf(t, false, "world start failed: %s", start.message)
		k.kernel_destroy(kernel)
		return nil, false
	}
	return world, true
}

@(private)
expect_string_relation :: proc(
	t: ^testing.T,
	kernel: ^k.Kernel,
	name: string,
	expected: string,
) {
	metadata, found := k.snapshot_relation_metadata_named(
		kernel.current,
		v.symbol_intern(name),
	)
	testing.expect(t, found)
	if !found {
		return
	}
	bindings := make([]v.Binding, metadata.arity, context.temp_allocator)
	rows: [dynamic]v.Tuple
	defer delete(rows)
	k.kernel_scan_into(kernel, metadata.id, bindings, &rows)
	testing.expectf(t, len(rows) == 1, "%s has %d rows, expected 1", name, len(rows))
	if len(rows) != 1 {
		return
	}
	values := v.tuple_values(rows[0])
	if len(values) != 1 {
		return
	}
	text, is_text := v.value_as_string(values[0])
	testing.expectf(
		t,
		is_text && text == expected,
		"%s holds %v, expected %q",
		name,
		values[0],
		expected,
	)
}

// `openai_chat_completion` lowers to an external request, the configured
// handler answers it, and the task observes the returned value.
@(test)
test_run_external_handler_request :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	source := `make_relation(:Got, 1)
let answer = openai_chat_completion("test-model", [{:role -> "user", :content -> "ping"}])
assert Got(answer)
`
	kernel: k.Kernel
	world, ok := external_world(t, &kernel, source, test_external_handler, "mica_external_test.mica")
	if !ok {
		return
	}
	defer k.kernel_destroy(&kernel)
	defer world_destroy(world)

	outcome := world_wait(world, world.entry)
	testing.expectf(
		t,
		outcome.kind == .Complete,
		"entry outcome: %v %s",
		outcome.kind,
		outcome.message,
	)
	expect_string_relation(t, &kernel, "Got", "openai:test-model")
}

// The streaming entry point resumes with `{:started -> true}` and delivers
// events to the mailbox as a host handler would.
@(test)
test_run_external_stream_to_mailbox :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	source := `make_relation(:Got, 1)
let [receiver, sender] = mailbox()
llm_chat_stream_to("stream-model", [{:role -> "user", :content -> "ping"}], {:stream -> true}, [], sender)
let ready = mailbox_recv([receiver], 200)
if ready != []
  let first = ready[0][1][0]
  assert Got(first)
end
mailbox_close(receiver)
`
	kernel: k.Kernel
	world, ok := external_world(
		t,
		&kernel,
		source,
		test_external_handler,
		"mica_external_stream_test.mica",
	)
	if !ok {
		return
	}
	defer k.kernel_destroy(&kernel)
	defer world_destroy(world)

	outcome := world_wait(world, world.entry)
	testing.expectf(
		t,
		outcome.kind == .Complete,
		"entry outcome: %v %s",
		outcome.kind,
		outcome.message,
	)
	// The fact records the stream event the handler delivered.
	expect_relation_rows(t, &kernel, "Got", 1)
}

// Without a configured handler the parked task resumes with an
// `ExternalUnavailable` error value instead of hanging.
@(test)
test_run_external_unavailable_without_handler :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	source := `openai_chat_completion("test-model", [])`
	kernel: k.Kernel
	world, ok := external_world(t, &kernel, source, nil, "mica_external_unavailable_test.mica")
	if !ok {
		return
	}
	defer k.kernel_destroy(&kernel)
	defer world_destroy(world)

	outcome := world_wait(world, world.entry)
	testing.expectf(
		t,
		outcome.kind == .Complete,
		"entry outcome: %v %s",
		outcome.kind,
		outcome.message,
	)
	error_value, is_error := v.value_as_error(outcome.value)
	testing.expect(t, is_error)
	if is_error {
		code, _ := v.symbol_name(error_value.code)
		testing.expect_value(t, code, "ExternalUnavailable")
	}
}

// Host requests are compiler-recognized: the wrong argument count is a
// compile error, not a later dispatch failure.
@(test)
test_host_request_argument_count :: proc(t: ^testing.T) {
	ctx := c.Compile_Context {
		builtins   = make(map[string]bool),
		relations  = make(map[string]u32),
		identities = make(map[string]v.Value),
	}
	defer delete(ctx.builtins)
	defer delete(ctx.relations)
	defer delete(ctx.identities)
	install_builtin_names(&ctx)

	ast, parse_errors := c.parse_program(`llm_responses_stream("model")`, context.temp_allocator)
	testing.expectf(t, len(parse_errors) == 0, "parse errors: %v", parse_errors)
	compiled := c.compile_program(ast, &ctx, context.temp_allocator)
	testing.expect(t, len(compiled.errors) > 0)
}
