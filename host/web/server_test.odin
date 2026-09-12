package web

import "base:runtime"
import "core:fmt"
import "core:net"
import "core:os"
import "core:strings"
import "core:sync"
import "core:testing"
import "core:thread"
import "core:time"

@(private)
server_run_worker :: proc(data: rawptr) {
	context = runtime.default_context()
	web_server_run((^Web_Server)(data))
}

@(private)
start_server :: proc(t: ^testing.T, server: ^Web_Server, routes: ^Routes) -> ^thread.Thread {
	ok, message := web_server_init(server, "127.0.0.1:0", routes_handle, routes)
	if !ok {
		testing.expectf(t, false, "server init failed: %s", message)
		return nil
	}
	return thread.create_and_start_with_data(server, server_run_worker)
}

@(private)
dial_server :: proc(t: ^testing.T, server: ^Web_Server) -> net.TCP_Socket {
	endpoint, endpoint_ok := web_server_endpoint(server)
	testing.expect(t, endpoint_ok)
	client, dial_err := net.dial_tcp(endpoint)
	testing.expect(t, dial_err == nil)
	_ = net.set_option(client, .Receive_Timeout, 200 * time.Millisecond)
	return client
}

@(private)
send_text :: proc(socket: net.TCP_Socket, text: string) {
	_, _ = net.send_tcp(socket, transmute([]byte)text)
}

// Reads until the peer closes or the receive timeout fires.
@(private)
read_response :: proc(socket: net.TCP_Socket) -> []u8 {
	bytes: [dynamic]u8
	chunk: [4096]u8
	start := time.tick_now()
	for time.tick_since(start) < 2 * time.Second {
		read, recv_err := net.recv_tcp(socket, chunk[:])
		if read > 0 {
			append(&bytes, ..chunk[:read])
		}
		if read == 0 || recv_err != .None {
			break
		}
	}
	return bytes[:]
}

@(test)
test_server_healthz :: proc(t: ^testing.T) {
	routes: Routes
	defer routes_destroy(&routes)
	server: Web_Server
	run_thread := start_server(t, &server, &routes)
	if run_thread == nil {
		return
	}

	client := dial_server(t, &server)
	send_text(client, "GET /healthz HTTP/1.1\r\nHost: a\r\n\r\n")
	response := read_response(client)
	defer delete(response)
	text := string(response)
	testing.expectf(t, strings.contains(text, "HTTP/1.1 200 OK"), "response: %q", text)
	testing.expectf(t, strings.contains(text, "Content-Length: 3"), "response: %q", text)
	testing.expectf(t, strings.contains(text, "ok\n"), "response: %q", text)

	net.close(client)
	web_server_stop(&server)
	thread.join(run_thread)
	thread.destroy(run_thread)
}

@(test)
test_server_keep_alive :: proc(t: ^testing.T) {
	routes: Routes
	defer routes_destroy(&routes)
	server: Web_Server
	run_thread := start_server(t, &server, &routes)
	if run_thread == nil {
		return
	}

	client := dial_server(t, &server)
	send_text(client, "GET /healthz HTTP/1.1\r\nHost: a\r\n\r\n")
	net.set_option(client, .Receive_Timeout, 200 * time.Millisecond)
	first := read_response(client)
	defer delete(first)
	testing.expectf(t, strings.contains(string(first), "ok\n"), "first: %q", string(first))

	// The connection stays open for a second request.
	send_text(client, "GET /healthz HTTP/1.1\r\nHost: a\r\n\r\n")
	second := read_response(client)
	defer delete(second)
	testing.expectf(t, strings.contains(string(second), "ok\n"), "second: %q", string(second))

	net.close(client)
	web_server_stop(&server)
	thread.join(run_thread)
	thread.destroy(run_thread)
}

@(test)
test_server_static_sync_client :: proc(t: ^testing.T) {
	directory, directory_err := os.temp_dir(context.temp_allocator)
	if directory_err != nil {
		testing.expect(t, false, "cannot resolve a temporary directory")
		return
	}
	path := fmt.aprintf(
		"%s/mica_sync_client.js",
		directory,
		allocator = context.temp_allocator,
	)
	script := "export const marker = 1;\n"
	if write_err := os.write_entire_file(path, transmute([]byte)script); write_err != nil {
		testing.expect(t, false, "cannot write the static file")
		return
	}
	defer os.remove(path)

	routes: Routes
	if ok, message := routes_init(&routes, path); !ok {
		testing.expectf(t, false, "routes init failed: %s", message)
		return
	}
	defer routes_destroy(&routes)

	server: Web_Server
	run_thread := start_server(t, &server, &routes)
	if run_thread == nil {
		return
	}

	client := dial_server(t, &server)
	send_text(client, "GET /sync-client.js HTTP/1.1\r\nHost: a\r\n\r\n")
	response := read_response(client)
	defer delete(response)
	text := string(response)
	testing.expectf(t, strings.contains(text, "HTTP/1.1 200 OK"), "response: %q", text)
	testing.expectf(t, strings.contains(text, "text/javascript"), "response: %q", text)
	testing.expectf(t, strings.contains(text, script), "response: %q", text)

	net.close(client)
	web_server_stop(&server)
	thread.join(run_thread)
	thread.destroy(run_thread)
}

@(test)
test_server_rejects_chunked :: proc(t: ^testing.T) {
	routes: Routes
	defer routes_destroy(&routes)
	server: Web_Server
	run_thread := start_server(t, &server, &routes)
	if run_thread == nil {
		return
	}

	client := dial_server(t, &server)
	send_text(
		client,
		"POST / HTTP/1.1\r\nHost: a\r\nTransfer-Encoding: chunked\r\n\r\n0\r\n\r\n",
	)
	response := read_response(client)
	defer delete(response)
	testing.expectf(
		t,
		strings.contains(string(response), "HTTP/1.1 400 Bad Request"),
		"response: %q",
		string(response),
	)

	net.close(client)
	web_server_stop(&server)
	thread.join(run_thread)
	thread.destroy(run_thread)
}

@(test)
test_server_method_not_allowed :: proc(t: ^testing.T) {
	routes: Routes
	defer routes_destroy(&routes)
	server: Web_Server
	run_thread := start_server(t, &server, &routes)
	if run_thread == nil {
		return
	}

	client := dial_server(t, &server)
	send_text(client, "POST /healthz HTTP/1.1\r\nHost: a\r\nContent-Length: 0\r\n\r\n")
	response := read_response(client)
	defer delete(response)
	testing.expectf(
		t,
		strings.contains(string(response), "HTTP/1.1 405 Method Not Allowed"),
		"response: %q",
		string(response),
	)

	net.close(client)
	web_server_stop(&server)
	thread.join(run_thread)
	thread.destroy(run_thread)
}

// Completed connections must be reclaimed during operation, not only at
// shutdown.
@(test)
test_server_reaps_completed_connections :: proc(t: ^testing.T) {
	routes: Routes
	defer routes_destroy(&routes)
	server: Web_Server
	run_thread := start_server(t, &server, &routes)
	if run_thread == nil {
		return
	}

	for _ in 0 ..< 3 {
		client := dial_server(t, &server)
		send_text(client, "GET /healthz HTTP/1.1\r\nHost: a\r\n\r\n")
		response := read_response(client)
		delete(response)
		net.close(client)
	}

	remaining := 0
	for _ in 0 ..< 100 {
		sync.mutex_lock(&server.lock)
		remaining = len(server.connections)
		sync.mutex_unlock(&server.lock)
		if remaining == 0 {
			break
		}
		time.sleep(10 * time.Millisecond)
	}
	testing.expect_value(t, remaining, 0)

	web_server_stop(&server)
	thread.join(run_thread)
	thread.destroy(run_thread)
}
