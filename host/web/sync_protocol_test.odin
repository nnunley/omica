package web

import "core:strings"
import "core:testing"

@(test)
test_sync_envelope_roundtrip :: proc(t: ^testing.T) {
	envelope := Sync_Envelope {
		kind             = .View_Snapshot,
		session_id       = 7,
		view_id          = 11,
		client_revision  = 13,
		client_signature = 17,
		server_revision  = 19,
		server_signature = 23,
		payload          = string_bytes("hello"),
	}
	bytes: [dynamic]u8
	defer delete(bytes)
	sync_encode_envelope(&envelope, &bytes)
	testing.expect_value(t, len(bytes), SYNC_ENVELOPE_HEADER_LEN + 5)

	decoded, ok := sync_decode_envelope(bytes[:])
	testing.expect(t, ok)
	testing.expect_value(t, decoded.kind, Sync_Kind.View_Snapshot)
	testing.expect_value(t, decoded.session_id, u64(7))
	testing.expect_value(t, decoded.view_id, u64(11))
	testing.expect_value(t, decoded.client_revision, u64(13))
	testing.expect_value(t, decoded.client_signature, u64(17))
	testing.expect_value(t, decoded.server_revision, u64(19))
	testing.expect_value(t, decoded.server_signature, u64(23))
	testing.expect_value(t, string(decoded.payload), "hello")
}

@(test)
test_sync_envelope_rejects_bad_headers :: proc(t: ^testing.T) {
	valid := Sync_Envelope {
		kind       = .Need_View,
		session_id = 1,
		view_id    = 2,
	}
	bytes: [dynamic]u8
	defer delete(bytes)
	sync_encode_envelope(&valid, &bytes)

	_, short := sync_decode_envelope(bytes[:10])
	testing.expect(t, !short)

	bad_magic := make([]u8, len(bytes), context.temp_allocator)
	copy(bad_magic, bytes[:])
	bad_magic[0] = 'X'
	_, magic_ok := sync_decode_envelope(bad_magic)
	testing.expect(t, !magic_ok)

	bad_kind := make([]u8, len(bytes), context.temp_allocator)
	copy(bad_kind, bytes[:])
	bad_kind[4] = 9
	_, kind_ok := sync_decode_envelope(bad_kind)
	testing.expect(t, !kind_ok)

	bad_flags := make([]u8, len(bytes), context.temp_allocator)
	copy(bad_flags, bytes[:])
	bad_flags[5] = 1
	_, flags_ok := sync_decode_envelope(bad_flags)
	testing.expect(t, !flags_ok)

	bad_reserved := make([]u8, len(bytes), context.temp_allocator)
	copy(bad_reserved, bytes[:])
	bad_reserved[6] = 1
	_, reserved_ok := sync_decode_envelope(bad_reserved)
	testing.expect(t, !reserved_ok)
}

@(test)
test_sync_payload_signature :: proc(t: ^testing.T) {
	// Fixture computed with the Rust `sync_payload_signature` algorithm.
	testing.expect_value(
		t,
		sync_payload_signature(1, string_bytes("payload")),
		u64(19925319132186738),
	)
	testing.expect_value(
		t,
		sync_payload_signature(2, string_bytes("payload")),
		u64(12145294233695959),
	)
	testing.expect(
		t,
		sync_payload_signature(1, string_bytes("x")) <= SYNC_SIGNATURE_MASK,
	)
}

@(test)
test_sync_sse_event_format :: proc(t: ^testing.T) {
	envelope := Sync_Envelope {
		kind             = .View_Snapshot,
		session_id       = 7,
		view_id          = 11,
		client_revision  = 13,
		client_signature = 17,
		server_revision  = 19,
		server_signature = 23,
		payload          = string_bytes("he\"llo\n"),
	}
	builder: strings.Builder
	strings.builder_init(&builder)
	defer strings.builder_destroy(&builder)
	sync_write_event(&builder, &envelope)

	expected := "event: sync\n" +
		"data: {\"kind\":\"ViewSnapshot\",\"session\":\"7\",\"view\":\"11\"," +
		"\"clientRevision\":\"13\",\"clientSignature\":\"17\"," +
		"\"serverRevision\":\"19\",\"serverSignature\":\"23\"," +
		"\"payload\":\"he\\\"llo\\n\"}\n\n"
	testing.expect_value(t, strings.to_string(builder), expected)
}
