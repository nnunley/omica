// Sync transport: `/sync/input` and the `/sync/events` SSE stream.
//
// Input decodes one MSY1 envelope, ensures the session, renders the view, and
// queues a snapshot. The stream writes SSE chunks from the session queue.
package web

import "core:fmt"
import "core:net"
import "core:strings"
import "core:sync"
import "core:time"
import dom "../../mica/dom"
import k "../../mica/kernel"
import r "../../mica/runtime"
import v "../../mica/var"

SYNC_EVENTS_PATH :: "/sync/events"
SYNC_INPUT_PATH :: "/sync/input"

// Heartbeat comment interval for idle streams.
SYNC_HEARTBEAT :: 15 * time.Second

@(private)
string_bytes :: proc(text: string) -> []u8 {
	return transmute([]byte)text
}

@(private)
allow_post_headers := []Http_Header{{"Allow", "POST"}}

// Handles a non-streaming sync request. Returns false when the path is not a
// sync request.
sync_handle_request :: proc(
	host: ^Sync_Host,
	actor: v.Value,
	request: ^Http_Request,
	response: ^Http_Response,
) -> bool {
	path := http_request_path(request.target)
	if path != SYNC_INPUT_PATH {
		return false
	}
	if !sync_host_ready(host) {
		http_response_text(response, 503, "text/plain; charset=utf-8", "no world loaded")
		return true
	}
	if request.method != "POST" {
		response.headers = allow_post_headers
		http_response_text(response, 405, "text/plain; charset=utf-8", "method not allowed")
		return true
	}
	envelope, decoded := sync_decode_envelope(request.body)
	if !decoded {
		return sync_handle_dom_event(host, actor, request.body, response)
	}
	// The SSE client wraps DOM events in a HaveView envelope whose payload is
	// the event JSON. Decode that payload before the view-refresh path.
	if event, is_event := dom_event_decode(envelope.payload, host.world.allocator); is_event {
		return sync_dispatch_dom_event(host, actor, event, response)
	}
	switch envelope.kind {
	case .Need_View:
		if !sync_render_view(
			host,
			envelope.session_id,
			actor,
			envelope.view_id,
			envelope.client_revision,
			envelope.client_signature,
			true,
		) {
			http_response_text(
				response,
				500,
				"text/plain; charset=utf-8",
				"cannot render view",
			)
			return true
		}
	case .Have_View:
		session := sync_host_ensure_session(host, envelope.session_id, actor)
		if session == nil {
			http_response_text(
				response,
				403,
				"text/plain; charset=utf-8",
				"session actor mismatch",
			)
			return true
		}
		view := sync_view_state(session, envelope.view_id)
		sync.mutex_lock(&view.render_lock)
		up_to_date := view.has_tree &&
			envelope.client_revision == view.revision &&
			envelope.client_signature == view.signature
		sync.mutex_unlock(&view.render_lock)
		if !up_to_date {
			if !sync_render_view(
				host,
				envelope.session_id,
				actor,
				envelope.view_id,
				envelope.client_revision,
				envelope.client_signature,
				true,
			) {
				http_response_text(
					response,
					500,
					"text/plain; charset=utf-8",
					"cannot render view",
				)
				return true
			}
		}
	case .View_Snapshot, .View_Delta:
		// Client view state is not forwarded into the world yet.
	}
	response.status = 202
	return true
}

// Handles a JSON DOM event from the client: dispatch `sync_event` as the
// session actor, then render the view so the delta comes back down the stream.
@(private)
sync_handle_dom_event :: proc(
	host: ^Sync_Host,
	actor: v.Value,
	body: []u8,
	response: ^Http_Response,
) -> bool {
	// Role values must outlive the connection thread's temp arena, so they are
	// allocated from the world allocator.
	event, parsed := dom_event_decode(body, host.world.allocator)
	if !parsed {
		http_response_text(response, 400, "text/plain; charset=utf-8", "invalid sync envelope")
		return true
	}
	return sync_dispatch_dom_event(host, actor, event, response)
}

@(private)
sync_dispatch_dom_event :: proc(
	host: ^Sync_Host,
	actor: v.Value,
	event: Dom_Event,
	response: ^Http_Response,
) -> bool {
	session := sync_host_ensure_session(host, event.session_id, actor)
	if session == nil {
		http_response_text(
			response,
			403,
			"text/plain; charset=utf-8",
			"session actor mismatch",
		)
		return true
	}
	session_value, _ := v.value_int(i64(event.session_id))
	view_value, _ := v.value_int(i64(event.view_id))
	field_entries := make([]v.Map_Entry, len(event.fields), host.world.allocator)
	for field, index in event.fields {
		field_entries[index] = v.Map_Entry {
			key   = v.value_symbol(v.symbol_intern(field.name)),
			value = v.value_string(host.world.allocator, field.value),
		}
	}
	roles := []k.Role_Pair {
		{role = v.value_symbol(v.symbol_intern("endpoint")), value = r.world_endpoint(host.world)},
		{role = v.value_symbol(v.symbol_intern("session")), value = session_value},
		{role = v.value_symbol(v.symbol_intern("view")), value = view_value},
		{
			role = v.value_symbol(v.symbol_intern("event")),
			value = v.value_string(host.world.allocator, event.event),
		},
		{
			role = v.value_symbol(v.symbol_intern("target")),
			value = v.value_string(host.world.allocator, event.target),
		},
		{
			role = v.value_symbol(v.symbol_intern("action")),
			value = v.value_string(host.world.allocator, event.action),
		},
		{
			role = v.value_symbol(v.symbol_intern("fields")),
			value = v.value_map(host.world.allocator, field_entries),
		},
	}
	event_outcome := sync_world_call(host, session, "sync_event", roles)
	if event_outcome.kind != .Complete {
		http_response_text(
			response,
			500,
			"text/plain; charset=utf-8",
			"sync event failed",
		)
		return true
	}

	// Send the resulting view. A client behind the current revision gets a
	// full snapshot; otherwise a delta.
	view := sync_view_state(session, event.view_id)
	sync.mutex_lock(&view.render_lock)
	stale := view.has_tree &&
		(event.revision != view.revision || event.signature != view.signature)
	sync.mutex_unlock(&view.render_lock)
	if !sync_render_view(
		host,
		event.session_id,
		actor,
		event.view_id,
		event.revision,
		event.signature,
		stale,
	) {
		http_response_text(
			response,
			500,
			"text/plain; charset=utf-8",
			"cannot render view",
		)
		return true
	}
	response.status = 202
	return true
}

// Streams SSE events for one session. Returns false when the path is not
// `/sync/events`; otherwise it owns the connection until the stream ends.
sync_events_stream :: proc(
	host: ^Sync_Host,
	actor: v.Value,
	request: ^Http_Request,
	socket: net.TCP_Socket,
) -> bool {
	if http_request_path(request.target) != SYNC_EVENTS_PATH {
		return false
	}
	if request.method != "GET" {
		sync_write_error(socket, 405, "method not allowed")
		return true
	}
	if !sync_host_ready(host) {
		sync_write_error(socket, 503, "no world loaded")
		return true
	}
	session_id, has_session := sync_query_u64(request.target, "session")
	if !has_session {
		sync_write_error(socket, 400, "sync event stream requires ?session=<u64>")
		return true
	}

	session := sync_host_ensure_session(host, session_id, actor)
	if session == nil {
		sync_write_error(socket, 403, "session actor mismatch")
		return true
	}
	generation := sync_session_claim_writer(session)
	defer sync_session_release_writer(session, generation)

	builder: strings.Builder
	strings.builder_init(&builder, context.temp_allocator)
	defer strings.builder_destroy(&builder)
	chunk_builder: strings.Builder
	strings.builder_init(&chunk_builder, context.temp_allocator)
	defer strings.builder_destroy(&chunk_builder)

	strings.write_string(&builder, "HTTP/1.1 200 OK\r\n")
	strings.write_string(&builder, "Content-Type: text/event-stream; charset=utf-8\r\n")
	strings.write_string(&builder, "Cache-Control: no-store\r\n")
	strings.write_string(&builder, "Connection: keep-alive\r\n")
	strings.write_string(&builder, "Transfer-Encoding: chunked\r\n")
	strings.write_string(&builder, "X-Accel-Buffering: no\r\n\r\n")
	if !web_send_all(socket, transmute([]u8)strings.to_string(builder)) {
		return true
	}
	strings.builder_reset(&builder)
	http_write_chunk(&builder, string_bytes(": connected\n\n"))
	if !web_send_all(socket, transmute([]u8)strings.to_string(builder)) {
		return true
	}

	// Short receive timeout lets the writer notice a closed peer between
	// heartbeats without sending.
	_ = net.set_option(socket, .Receive_Timeout, 250 * time.Millisecond)
	last_heartbeat := time.tick_now()
	probe: [1]u8
	for {
		batch, kind := sync_session_take(session, generation, 0)
		switch kind {
		case .Messages:
			for _, index in batch {
				strings.builder_reset(&builder)
				sync_write_event(&builder, &batch[index])
				strings.builder_reset(&chunk_builder)
				http_write_chunk(
					&chunk_builder,
					transmute([]u8)strings.to_string(builder),
				)
				sent := web_send_all(
					socket,
					transmute([]u8)strings.to_string(chunk_builder),
				)
				delete(batch[index].payload, session.allocator)
				if !sent {
					delete(batch)
					return true
				}
			}
			delete(batch)
			continue
		case .Closed, .Replaced:
			return true
		case .Timeout:
		}

		read, recv_err := net.recv_tcp(socket, probe[:])
		if read == 0 && recv_err == .None {
			// The client closed the stream.
			return true
		}
		if time.tick_since(last_heartbeat) >= SYNC_HEARTBEAT {
			last_heartbeat = time.tick_now()
			strings.builder_reset(&builder)
			http_write_chunk(&builder, string_bytes(": keepalive\n\n"))
			if !web_send_all(socket, transmute([]u8)strings.to_string(builder)) {
				return true
			}
		}
	}
}

@(private)
sync_write_error :: proc(socket: net.TCP_Socket, status: int, message: string) {
	builder: strings.Builder
	strings.builder_init(&builder, context.temp_allocator)
	defer strings.builder_destroy(&builder)

	response := Http_Response {
		status = status,
		close  = true,
	}
	http_response_text(&response, status, "text/plain; charset=utf-8", message)
	http_encode_response(&response, &builder)
	_ = web_send_all(socket, transmute([]u8)strings.to_string(builder))
}

@(private)
sync_query_u64 :: proc(target: string, key: string) -> (u64, bool) {
	query := strings.index_byte(target, '?')
	if query < 0 {
		return 0, false
	}
	remaining := target[query + 1:]
	for len(remaining) > 0 {
		pair := remaining
		if pair_end := strings.index_byte(remaining, '&'); pair_end >= 0 {
			pair = remaining[:pair_end]
			remaining = remaining[pair_end + 1:]
		} else {
			remaining = ""
		}
		equals := strings.index_byte(pair, '=')
		if equals < 0 || pair[:equals] != key {
			continue
		}
		value := pair[equals + 1:]
		if len(value) == 0 {
			return 0, false
		}
		parsed := u64(0)
		for c in value {
			if c < '0' || c > '9' {
				return 0, false
			}
			parsed = parsed * 10 + u64(c - '0')
		}
		return parsed, true
	}
	return 0, false
}
