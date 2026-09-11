// The MSY1 sync envelope: a 56-byte header plus a payload.
//
// Header layout (little-endian):
//
//	0  magic "MSY1"
//	4  kind
//	5  flags (zero)
//	6  reserved u16 (zero)
//	8  session id u64
//	16 view id u64
//	24 client revision u64
//	32 client signature u64
//	40 server revision u64
//	48 server signature u64
//	56 payload
package web

SYNC_ENVELOPE_MAGIC: [4]u8 : {'M', 'S', 'Y', '1'}
SYNC_ENVELOPE_HEADER_LEN :: 56
SYNC_SIGNATURE_MASK :: u64(0x007f_ffff_ffff_ffff)

Sync_Kind :: enum u8 {
	Have_View     = 1,
	Need_View     = 2,
	View_Snapshot = 3,
	View_Delta    = 4,
}

Sync_Envelope :: struct {
	kind:             Sync_Kind,
	session_id:       u64,
	view_id:          u64,
	client_revision:  u64,
	client_signature: u64,
	server_revision:  u64,
	server_signature: u64,
	// A view into the input bytes for decoded envelopes, or an owned
	// allocation for envelopes built by the host.
	payload:          []u8,
}

sync_encode_envelope :: proc(envelope: ^Sync_Envelope, out: ^[dynamic]u8) {
	append(out, 'M', 'S', 'Y', '1')
	append(out, u8(envelope.kind), 0, 0, 0)
	append_le_u64(out, envelope.session_id)
	append_le_u64(out, envelope.view_id)
	append_le_u64(out, envelope.client_revision)
	append_le_u64(out, envelope.client_signature)
	append_le_u64(out, envelope.server_revision)
	append_le_u64(out, envelope.server_signature)
	append(out, ..envelope.payload)
}

sync_decode_envelope :: proc(bytes: []u8) -> (Sync_Envelope, bool) {
	if len(bytes) < SYNC_ENVELOPE_HEADER_LEN {
		return {}, false
	}
	if bytes[0] != SYNC_ENVELOPE_MAGIC[0] ||
	   bytes[1] != SYNC_ENVELOPE_MAGIC[1] ||
	   bytes[2] != SYNC_ENVELOPE_MAGIC[2] ||
	   bytes[3] != SYNC_ENVELOPE_MAGIC[3] {
		return {}, false
	}
	if bytes[4] < u8(Sync_Kind.Have_View) || bytes[4] > u8(Sync_Kind.View_Delta) {
		return {}, false
	}
	if bytes[5] != 0 || bytes[6] != 0 || bytes[7] != 0 {
		return {}, false
	}
	return Sync_Envelope {
		kind             = Sync_Kind(bytes[4]),
		session_id       = read_le_u64(bytes, 8),
		view_id          = read_le_u64(bytes, 16),
		client_revision  = read_le_u64(bytes, 24),
		client_signature = read_le_u64(bytes, 32),
		server_revision  = read_le_u64(bytes, 40),
		server_signature = read_le_u64(bytes, 48),
		payload          = bytes[SYNC_ENVELOPE_HEADER_LEN:],
	}, true
}

// FNV-1a over the little-endian revision bytes and the payload, masked to the
// Mica integer range. Mirrors `sync_payload_signature` in the Rust host.
sync_payload_signature :: proc(revision: u64, payload: []u8) -> u64 {
	hash := u64(0xcbf2_9ce4_8422_2325)
	revision_bytes: [8]u8
	for index in 0 ..< 8 {
		revision_bytes[index] = u8(revision >> (8 * u32(index)))
	}
	for byte in revision_bytes {
		hash = (hash ~ u64(byte)) * u64(0x0000_0100_0000_01b3)
	}
	for byte in payload {
		hash = (hash ~ u64(byte)) * u64(0x0000_0100_0000_01b3)
	}
	return hash & SYNC_SIGNATURE_MASK
}

@(private)
append_le_u64 :: proc(out: ^[dynamic]u8, value: u64) {
	for index in 0 ..< 8 {
		append(out, u8(value >> (8 * u32(index))))
	}
}

@(private)
read_le_u64 :: proc(bytes: []u8, offset: int) -> u64 {
	value: u64
	for index in 0 ..< 8 {
		value |= u64(bytes[offset + index]) << (8 * u32(index))
	}
	return value
}
