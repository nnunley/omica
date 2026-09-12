// A small HTTP/1.1 server: one acceptor thread plus one thread per connection.
//
// Connection threads parse requests, call the handler, and write responses.
// They never touch the kernel. The handler is expected to hand work to tasks
// and wait for results off the connection thread.
package web

import "base:runtime"
import "core:mem"
import "core:net"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:time"

// Fills `response` for one request. The response body must stay alive until
// the response is written.
Web_Handler :: proc(user: rawptr, request: ^Http_Request, response: ^Http_Response)

// Takes over a connection to write a streaming response. Returns true when the
// request was handled; the server closes the connection when the handler
// returns.
Web_Stream_Handler :: proc(user: rawptr, request: ^Http_Request, socket: net.TCP_Socket) -> bool

DEFAULT_BACKLOG :: 512
RECV_BUFFER_SIZE :: 16 * 1024

Web_Connection :: struct {
	server: ^Web_Server,
	socket: net.TCP_Socket,
	thread: ^thread.Thread,
	// Guarded by `server.lock`. Set before the socket closes.
	done:   bool,
}

Web_Server :: struct {
	listener:       net.TCP_Socket,
	handler:        Web_Handler,
	stream_handler: Web_Stream_Handler,
	user:           rawptr,
	limits:      Http_Limits,
	lock:        sync.Mutex,
	stopping:    bool,
	connections: [dynamic]^Web_Connection,
	allocator:   mem.Allocator,
}

// Binds and listens. Returns false with a message on failure.
web_server_init :: proc(
	server: ^Web_Server,
	bind: string,
	handler: Web_Handler,
	user: rawptr,
	limits := DEFAULT_HTTP_LIMITS,
	allocator := context.allocator,
) -> (
	ok: bool,
	message: string,
) {
	server.handler = handler
	server.user = user
	server.limits = limits
	server.allocator = allocator
	server.connections = make([dynamic]^Web_Connection, allocator)

	endpoint, parsed := net.parse_endpoint(bind)
	if !parsed {
		return false, "invalid bind address"
	}
	listener, listen_err := net.listen_tcp(endpoint, DEFAULT_BACKLOG)
	if listen_err != nil {
		return false, "cannot listen on the bind address"
	}
	// Non-blocking accept lets `web_server_stop` wake the acceptor by closing
	// the listener.
	_ = net.set_blocking(listener, false)
	server.listener = listener
	return true, ""
}

// Registers a handler that gets first chance at each request and can write a
// streaming response.
web_server_set_stream_handler :: proc(server: ^Web_Server, handler: Web_Stream_Handler) {
	server.stream_handler = handler
}

// The actual bound endpoint. Useful when the bind port is zero.
web_server_endpoint :: proc(server: ^Web_Server) -> (net.Endpoint, bool) {
	endpoint, err := net.bound_endpoint(server.listener)
	return endpoint, err == .None
}

// Accepts connections until `web_server_stop` closes the listener. Each
// connection runs on its own thread.
web_server_run :: proc(server: ^Web_Server) {
	for {
		client, _, accept_err := net.accept_tcp(server.listener)
		if accept_err != .None {
			sync.mutex_lock(&server.lock)
			stopping := server.stopping
			sync.mutex_unlock(&server.lock)
			if stopping {
				return
			}
			if accept_err == .Would_Block {
				time.sleep(1 * time.Millisecond)
			}
			continue
		}
		// Accepted sockets inherit the listener's non-blocking flag on
		// BSD/macOS (but not Linux). Restore blocking mode so keep-alive
		// reads wait for the next request and SO_RCVTIMEO bounds the SSE
		// path; the acceptor stays non-blocking to poll for shutdown.
		_ = net.set_blocking(client, true)
		net.set_option(client, .TCP_Nodelay, true)
		connection := new(Web_Connection, server.allocator)
		connection.server = server
		connection.socket = client
		connection.thread = thread.create_and_start_with_data(
			connection,
			web_connection_worker,
		)
		if connection.thread == nil {
			net.close(client)
			free(connection, server.allocator)
			continue
		}
		sync.mutex_lock(&server.lock)
		append(&server.connections, connection)
		sync.mutex_unlock(&server.lock)
	}
}

// Stops the acceptor, unblocks active connections, and joins every connection
// thread. Must be called once after `web_server_run` is running or has failed.
web_server_stop :: proc(server: ^Web_Server) {
	sync.mutex_lock(&server.lock)
	server.stopping = true
	sync.mutex_unlock(&server.lock)
	net.close(server.listener)

	sync.mutex_lock(&server.lock)
	for connection in server.connections {
		if !connection.done {
			net.shutdown(connection.socket, .Both)
		}
	}
	sync.mutex_unlock(&server.lock)

	for connection in server.connections {
		if connection.thread != nil {
			thread.join(connection.thread)
			thread.destroy(connection.thread)
		}
		free(connection, server.allocator)
	}
	delete(server.connections)
}

@(private)
web_connection_worker :: proc(data: rawptr) {
	context = runtime.default_context()
	connection := (^Web_Connection)(data)
	web_connection_serve(connection)
	sync.mutex_lock(&connection.server.lock)
	connection.done = true
	net.close(connection.socket)
	sync.mutex_unlock(&connection.server.lock)
}

// Serves requests on one connection until it closes or faults.
web_connection_serve :: proc(connection: ^Web_Connection) {
	server := connection.server
	parser: Http_Parser
	http_parser_init(&parser, server.limits)
	defer http_parser_destroy(&parser)

	recv_buffer: [RECV_BUFFER_SIZE]u8
	response_builder: strings.Builder
	strings.builder_init(&response_builder, server.allocator)
	defer strings.builder_destroy(&response_builder)

	for {
		request, state, parse_error := http_parser_next(&parser)
		switch state {
		case .Ready:
			if server.stream_handler != nil {
				if server.stream_handler(server.user, &request, connection.socket) {
					http_parser_consume(&parser, parser.last_total)
					return
				}
			}
			response: Http_Response
			response.close = request.close
			server.handler(server.user, &request, &response)
			http_encode_response(&response, &response_builder)
			sent := web_send_all(connection.socket, transmute([]byte)strings.to_string(response_builder))
			http_parser_consume(&parser, parser.last_total)
			strings.builder_reset(&response_builder)
			if !sent || request.close {
				return
			}
		case .Incomplete:
			read, recv_err := net.recv_tcp(connection.socket, recv_buffer[:])
			if read <= 0 || recv_err != .None {
				return
			}
			http_parser_push(&parser, recv_buffer[:read])
		case .Error:
			write_parse_error(connection, parse_error)
			return
		}
	}
}

@(private)
write_parse_error :: proc(connection: ^Web_Connection, parse_error: Http_Parse_Error) {
	builder: strings.Builder
	strings.builder_init(&builder, connection.server.allocator)
	defer strings.builder_destroy(&builder)

	response := Http_Response {
		status = parse_error.status,
		close  = true,
	}
	http_response_text(&response, parse_error.status, "text/plain", parse_error.message)
	http_encode_response(&response, &builder)
	_ = web_send_all(connection.socket, transmute([]byte)strings.to_string(builder))
}

// Writes every byte or reports failure.
@(private)
web_send_all :: proc(socket: net.TCP_Socket, bytes: []u8) -> bool {
	written := 0
	for written < len(bytes) {
		count, send_err := net.send_tcp(socket, bytes[written:])
		if count <= 0 || send_err != .None {
			return false
		}
		written += count
	}
	return true
}
