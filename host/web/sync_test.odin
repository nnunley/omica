package web

import "core:fmt"
import "core:net"
import "core:os"
import "core:strings"
import "core:testing"
import "core:thread"
import "core:time"
import k "../../mica/kernel"
import v "../../mica/var"
import r "../../mica/runtime"

@(private)
Sync_Fixture_Host :: struct {
	sync: Sync_Host,
}

@(private)
sync_fixture_handler :: proc(user: rawptr, request: ^Http_Request, response: ^Http_Response) {
	host := (^Sync_Fixture_Host)(user)
	if !sync_handle_request(&host.sync, v.Value(0), request, response) {
		http_response_text(response, 404, "text/plain; charset=utf-8", "not found\n")
	}
}

@(private)
sync_fixture_stream :: proc(user: rawptr, request: ^Http_Request, socket: net.TCP_Socket) -> bool {
	host := (^Sync_Fixture_Host)(user)
	return sync_events_stream(&host.sync, v.Value(0), request, socket)
}

// Reads until the accumulated bytes contain `needle` or the deadline passes.
// Receive timeouts are expected on an open stream and do not end the read.
@(private)
read_until :: proc(
	socket: net.TCP_Socket,
	needle: string,
	timeout: time.Duration,
) -> []u8 {
	bytes: [dynamic]u8
	chunk: [4096]u8
	start := time.tick_now()
	for time.tick_since(start) < timeout {
		read, recv_err := net.recv_tcp(socket, chunk[:])
		if read > 0 {
			append(&bytes, ..chunk[:read])
			if strings.contains(string(bytes[:]), needle) {
				break
			}
		}
		if recv_err == .None && read == 0 {
			break
		}
	}
	return bytes[:]
}

@(test)
test_sync_query_u64 :: proc(t: ^testing.T) {
	value, ok := sync_query_u64("/sync/events?session=42&x=1", "session")
	testing.expect(t, ok)
	testing.expect_value(t, value, u64(42))

	_, missing := sync_query_u64("/sync/events", "session")
	testing.expect(t, !missing)

	_, bad := sync_query_u64("/sync/events?session=abc", "session")
	testing.expect(t, !bad)

	first, first_ok := sync_query_u64("/sync/events?x=1&session=9", "session")
	testing.expect(t, first_ok)
	testing.expect_value(t, first, u64(9))
}

@(test)
test_sync_input_and_stream :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	source := `verb sync_view_tree(view)
  return dom <div id="mount"><span>hello</span></div>
end
`
	path, path_ok := write_document_source(t, "mica_sync_fixture.mica", source)
	if !path_ok {
		return
	}
	defer os.remove(path)

	kernel: k.Kernel
	k.kernel_init(&kernel)
	defer k.kernel_destroy(&kernel)

	world, start := r.world_start(&kernel, []string{path}, context.temp_allocator)
	testing.expectf(t, start.ok, "world start failed: %s", start.message)
	if !start.ok {
		return
	}
	defer r.world_destroy(world)
	entry := r.world_wait(world, world.entry)
	testing.expect_value(t, entry.kind, r.Task_Outcome_Kind.Complete)

	host: Sync_Fixture_Host
	sync_host_init(&host.sync, world)
	defer sync_host_destroy(&host.sync)

	server: Web_Server
	ok, message := web_server_init(&server, "127.0.0.1:0", sync_fixture_handler, &host)
	testing.expectf(t, ok, "server init failed: %s", message)
	if !ok {
		return
	}
	web_server_set_stream_handler(&server, sync_fixture_stream)
	run_thread := thread.create_and_start_with_data(&server, server_run_worker)
	if run_thread == nil {
		return
	}

	sse_client := dial_server(t, &server)
	send_text(sse_client, "GET /sync/events?session=7 HTTP/1.1\r\nHost: a\r\n\r\n")
	connected := read_until(sse_client, ": connected", 3 * time.Second)
	defer delete(connected)
	testing.expectf(
		t,
		strings.contains(string(connected), "text/event-stream"),
		"headers: %q",
		string(connected),
	)
	testing.expectf(
		t,
		strings.contains(string(connected), ": connected"),
		"connected: %q",
		string(connected),
	)

	envelope := Sync_Envelope {
		kind       = .Need_View,
		session_id = 7,
		view_id    = 1,
	}
	bytes: [dynamic]u8
	defer delete(bytes)
	sync_encode_envelope(&envelope, &bytes)

	input_client := dial_server(t, &server)
	request_line := fmt.aprintf(
		"POST /sync/input HTTP/1.1\r\nHost: a\r\nContent-Length: %d\r\n\r\n",
		len(bytes),
		allocator = context.temp_allocator,
	)
	send_text(input_client, request_line)
	_, _ = net.send_tcp(input_client, bytes[:])
	input_response := read_response(input_client)
	defer delete(input_response)
	testing.expectf(
		t,
		strings.contains(string(input_response), "202 Accepted"),
		"input: %q",
		string(input_response),
	)

	event := read_until(sse_client, "\"kind\":\"ViewSnapshot\"", 3 * time.Second)
	defer delete(event)
	text := string(event)
	testing.expectf(t, strings.contains(text, "event: sync"), "event: %q", text)
	testing.expectf(t, strings.contains(text, "\"kind\":\"ViewSnapshot\""), "event: %q", text)
	testing.expectf(t, strings.contains(text, "\"session\":\"7\""), "event: %q", text)
	testing.expectf(t, strings.contains(text, "\"view\":\"1\""), "event: %q", text)
	// The payload is DOM node JSON, not an XML string.
	testing.expectf(t, strings.contains(text, `\"root\":{\"attrs\"`), "event: %q", text)
	testing.expectf(t, strings.contains(text, `\"tag\":\"span\"`), "event: %q", text)

	net.close(input_client)
	net.close(sse_client)
	web_server_stop(&server)
	thread.join(run_thread)
	thread.destroy(run_thread)
}

@(test)
test_sync_dependency_delta :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	source := `make_relation(:Item, 1)

verb bump(x)
  assert Item(x)
end

verb sync_view_tree(view)
  let items = Item(?v)
  let rows = []
  for row in items
    let text = to_literal(row[:v])
    rows = [@rows, dom <li id={text}>{text}</li>]
  end
  return dom <ul id="items">{rows}</ul>
end

verb sync_view_dependencies(view)
  return [{:subject -> :facts, :relation -> :Item, :bindings -> [none]}]
end
`
	path, path_ok := write_document_source(t, "mica_sync_delta_fixture.mica", source)
	if !path_ok {
		return
	}
	defer os.remove(path)

	kernel: k.Kernel
	k.kernel_init(&kernel)
	defer k.kernel_destroy(&kernel)

	world, start := r.world_start(&kernel, []string{path}, context.temp_allocator)
	testing.expectf(t, start.ok, "world start failed: %s", start.message)
	if !start.ok {
		return
	}
	defer r.world_destroy(world)
	entry := r.world_wait(world, world.entry)
	testing.expect_value(t, entry.kind, r.Task_Outcome_Kind.Complete)

	host: Sync_Fixture_Host
	sync_host_init(&host.sync, world)
	defer sync_host_destroy(&host.sync)

	probe_session := sync_host_ensure_session(&host.sync, 77)
	probe_view_state := sync_view_state(probe_session, 1)
	probe_loaded := sync_ensure_view_subscriptions(
		&host.sync,
		probe_session,
		probe_view_state,
		1,
	)
	testing.expectf(t, probe_loaded, "ensure subscriptions returned false")
	testing.expectf(
		t,
		len(probe_view_state.subscriptions) >= 1,
		"view subscriptions %d",
		len(probe_view_state.subscriptions),
	)

	server: Web_Server
	ok, message := web_server_init(&server, "127.0.0.1:0", sync_fixture_handler, &host)
	testing.expectf(t, ok, "server init failed: %s", message)
	if !ok {
		return
	}
	web_server_set_stream_handler(&server, sync_fixture_stream)
	run_thread := thread.create_and_start_with_data(&server, server_run_worker)
	if run_thread == nil {
		return
	}

	sse_client := dial_server(t, &server)
	send_text(sse_client, "GET /sync/events?session=11 HTTP/1.1\r\nHost: a\r\n\r\n")
	connected := read_until(sse_client, ": connected", 3 * time.Second)
	defer delete(connected)

	envelope := Sync_Envelope {
		kind       = .Need_View,
		session_id = 11,
		view_id    = 1,
	}
	bytes: [dynamic]u8
	defer delete(bytes)
	sync_encode_envelope(&envelope, &bytes)
	input_client := dial_server(t, &server)
	request_line := fmt.aprintf(
		"POST /sync/input HTTP/1.1\r\nHost: a\r\nContent-Length: %d\r\n\r\n",
		len(bytes),
		allocator = context.temp_allocator,
	)
	send_text(input_client, request_line)
	_, _ = net.send_tcp(input_client, bytes[:])
	input_result := read_response(input_client)
	defer delete(input_result)
	testing.expectf(
		t,
		strings.contains(string(input_result), "202 Accepted"),
		"input: %q",
		string(input_result),
	)

	snapshot := read_until(sse_client, "\"kind\":\"ViewSnapshot\"", 3 * time.Second)
	defer delete(snapshot)
	testing.expectf(
		t,
		strings.contains(string(snapshot), `\"tag\":\"ul\"`),
		"snapshot: %q",
		string(snapshot),
	)
	testing.expectf(
		t,
		len(host.sync.subscription_views) >= 1,
		"subscription count %d",
		len(host.sync.subscription_views),
	)
	one, _ := v.value_int(1)
	bump := r.world_call(world, "bump", []k.Role_Pair{{
		role  = v.value_symbol(v.symbol_intern("x")),
		value = one,
	}})
	testing.expectf(t, bump.kind == .Complete, "bump failed: %s", bump.message)

	delta := read_until(sse_client, "\"kind\":\"ViewDelta\"", 5 * time.Second)
	defer delete(delta)
	text := string(delta)
	testing.expectf(t, strings.contains(text, `\"type\":\"dom_patch\"`), "delta: %q", text)
	testing.expectf(t, strings.contains(text, `\"op\":\"append_child\"`), "delta: %q", text)
	testing.expectf(t, strings.contains(text, `\"revision\":2`), "delta: %q", text)

	net.close(input_client)
	net.close(sse_client)
	web_server_stop(&server)
	thread.join(run_thread)
	thread.destroy(run_thread)
}
