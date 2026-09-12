// SSE event encoding for sync envelopes and the sync host state.
package web

import "core:fmt"
import "core:mem"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:time"
import r "../../mica/runtime"
import v "../../mica/var"

// Bound on queued envelopes per session.
SYNC_OUTPUT_LIMIT :: 128

sync_kind_name :: proc(kind: Sync_Kind) -> string {
	switch kind {
	case .Have_View:
		return "HaveView"
	case .Need_View:
		return "NeedView"
	case .View_Snapshot:
		return "ViewSnapshot"
	case .View_Delta:
		return "ViewDelta"
	}
	return "Unknown"
}

// Writes one SSE event:
//
//	event: sync
//	data: {"kind":...,"session":"...",...}
//
// Revision and signature fields are decimal strings, matching the JS client.
sync_write_event :: proc(builder: ^strings.Builder, envelope: ^Sync_Envelope) {
	strings.write_string(builder, "event: sync\ndata: {\"kind\":\"")
	strings.write_string(builder, sync_kind_name(envelope.kind))
	fmt.sbprintf(
		builder,
		"\",\"session\":\"%d\",\"view\":\"%d\",\"clientRevision\":\"%d\",\"clientSignature\":\"%d\"",
		envelope.session_id,
		envelope.view_id,
		envelope.client_revision,
		envelope.client_signature,
	)
	fmt.sbprintf(
		builder,
		",\"serverRevision\":\"%d\",\"serverSignature\":\"%d\",\"payload\":\"",
		envelope.server_revision,
		envelope.server_signature,
	)
	sync_write_json_string(builder, string(envelope.payload))
	strings.write_string(builder, "\"}\n\n")
}

@(private)
sync_write_json_string :: proc(builder: ^strings.Builder, text: string) {
	for c in text {
		switch c {
		case '"':
			strings.write_string(builder, "\\\"")
		case '\\':
			strings.write_string(builder, "\\\\")
		case '\n':
			strings.write_string(builder, "\\n")
		case '\r':
			strings.write_string(builder, "\\r")
		case '\t':
			strings.write_string(builder, "\\t")
		case:
			if c < 0x20 {
				fmt.sbprintf(builder, "\\u%04x", u32(c))
			} else {
				strings.write_rune(builder, c)
			}
		}
	}
}

// --- Sessions --------------------------------------------------------------

Sync_Session :: struct {
	lock:          sync.Mutex,
	cond:          sync.Cond,
	session_id:    u64,
	closed:        bool,
	generation:    u64,
	writer_active: bool,
	messages:      [dynamic]Sync_Envelope,
	allocator:     mem.Allocator,
	// View state and the dependency-subscription mailbox.
	views:         map[u64]^View_State,
	receiver:      v.Value,
	sender:        v.Value,
	has_mailbox:   bool,
}

// The in-process sync host: a session table, the world used to render views,
// and a pump that turns dependency changes into deltas.
Sync_Host :: struct {
	lock:                sync.Mutex,
	sessions:            map[u64]^Sync_Session,
	subscription_views:  map[u64]View_Key,
	world:               ^r.World,
	allocator:           mem.Allocator,
	stopping:            bool,
	pump:                ^thread.Thread,
}

sync_host_init :: proc(host: ^Sync_Host, world: ^r.World, allocator := context.allocator) {
	host.world = world
	host.allocator = allocator
	host.sessions = make(map[u64]^Sync_Session, allocator)
	host.subscription_views = make(map[u64]View_Key, allocator)
	if world != nil {
		host.pump = thread.create_and_start_with_data(host, sync_pump_proc)
	}
}

// Reports whether the host has a world to render with.
sync_host_ready :: proc(host: ^Sync_Host) -> bool {
	return host != nil && host.world != nil
}

sync_host_destroy :: proc(host: ^Sync_Host) {
	if host == nil {
		return
	}
	sync.mutex_lock(&host.lock)
	host.stopping = true
	sync.mutex_unlock(&host.lock)
	if host.pump != nil {
		thread.join(host.pump)
		thread.destroy(host.pump)
	}
	for _, session in host.sessions {
		sync_session_close(session)
	}
	for _, session in host.sessions {
		sync_session_wait_idle(session)
	}
	for _, session in host.sessions {
		sync_session_destroy(host, session)
	}
	delete(host.sessions)
	delete(host.subscription_views)
}

sync_host_ensure_session :: proc(host: ^Sync_Host, session_id: u64) -> ^Sync_Session {
	sync.mutex_lock(&host.lock)
	if existing, found := host.sessions[session_id]; found {
		sync.mutex_unlock(&host.lock)
		return existing
	}
	session := new(Sync_Session, host.allocator)
	session.session_id = session_id
	session.allocator = host.allocator
	session.messages = make([dynamic]Sync_Envelope, host.allocator)
	session.views = make(map[u64]^View_State, host.allocator)
	if host.world != nil {
		receiver, sender, mailbox_ok := r.world_mailbox_create(host.world)
		if mailbox_ok {
			session.receiver = receiver
			session.sender = sender
			session.has_mailbox = true
		}
	}
	host.sessions[session_id] = session
	sync.mutex_unlock(&host.lock)
	return session
}

// Claims the connection as the session's stream writer. The previous writer
// sees a generation mismatch and stops.
sync_session_claim_writer :: proc(session: ^Sync_Session) -> u64 {
	sync.mutex_lock(&session.lock)
	session.generation += 1
	session.writer_active = true
	generation := session.generation
	sync.cond_broadcast(&session.cond)
	sync.mutex_unlock(&session.lock)
	return generation
}

// Releases the writer claim when its stream ends.
sync_session_release_writer :: proc(session: ^Sync_Session, generation: u64) {
	sync.mutex_lock(&session.lock)
	if session.generation == generation {
		session.writer_active = false
	}
	sync.cond_broadcast(&session.cond)
	sync.mutex_unlock(&session.lock)
}

// Queues an envelope. A `ViewSnapshot` replaces queued snapshots for the same
// session and view, so a slow client gets the newest snapshot.
sync_session_post :: proc(session: ^Sync_Session, envelope: ^Sync_Envelope) -> bool {
	payload := make([]u8, len(envelope.payload), session.allocator)
	copy(payload, envelope.payload)

	sync.mutex_lock(&session.lock)
	if session.closed {
		sync.mutex_unlock(&session.lock)
		delete(payload, session.allocator)
		return false
	}
	if envelope.kind == .View_Snapshot {
		write := 0
		for message in session.messages {
			if message.session_id == envelope.session_id &&
			   message.view_id == envelope.view_id {
				delete(message.payload, session.allocator)
				continue
			}
			session.messages[write] = message
			write += 1
		}
		resize(&session.messages, write)
	}
	copied := envelope^
	copied.payload = payload
	append(&session.messages, copied)
	for len(session.messages) > SYNC_OUTPUT_LIMIT {
		delete(session.messages[0].payload, session.allocator)
		copy(session.messages[:], session.messages[1:])
		resize(&session.messages, len(session.messages) - 1)
	}
	sync.cond_broadcast(&session.cond)
	sync.mutex_unlock(&session.lock)
	return true
}

Sync_Take_Kind :: enum {
	Messages,
	Timeout,
	Closed,
	Replaced,
}

// Waits up to `timeout` for queued envelopes. The batch and its payloads are
// owned by the caller.
sync_session_take :: proc(
	session: ^Sync_Session,
	generation: u64,
	timeout: time.Duration,
) -> (
	batch: [dynamic]Sync_Envelope,
	kind: Sync_Take_Kind,
) {
	start := time.tick_now()
	sync.mutex_lock(&session.lock)
	defer sync.mutex_unlock(&session.lock)
	for {
		if session.generation != generation {
			return nil, .Replaced
		}
		if session.closed {
			return nil, .Closed
		}
		if len(session.messages) > 0 {
			batch = make([dynamic]Sync_Envelope, session.allocator)
			for message in session.messages {
				append(&batch, message)
			}
			clear(&session.messages)
			return batch, .Messages
		}
		remaining := timeout - time.tick_since(start)
		if remaining <= 0 {
			return nil, .Timeout
		}
		sync.cond_wait_with_timeout(&session.cond, &session.lock, remaining)
	}
}

sync_session_close :: proc(session: ^Sync_Session) {
	sync.mutex_lock(&session.lock)
	session.closed = true
	sync.cond_broadcast(&session.cond)
	sync.mutex_unlock(&session.lock)
}

@(private)
sync_session_wait_idle :: proc(session: ^Sync_Session) {
	for {
		sync.mutex_lock(&session.lock)
		active := session.writer_active
		done := !active
		if !done {
			sync.cond_wait_with_timeout(&session.cond, &session.lock, 10 * time.Millisecond)
		}
		sync.mutex_unlock(&session.lock)
		if done {
			return
		}
	}
}

@(private)
sync_session_destroy :: proc(host: ^Sync_Host, session: ^Sync_Session) {
	for message in session.messages {
		delete(message.payload, session.allocator)
	}
	delete(session.messages)
	for _, view in session.views {
		sync_view_destroy(host, view)
	}
	delete(session.views)
	free(session, session.allocator)
}
