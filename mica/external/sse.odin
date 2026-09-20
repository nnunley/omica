// Server-sent event framing, matching the Rust external-http decoder.
//
// A frame ends at a blank line (`\r\n\r\n` or `\n\n`). Only `data:` lines
// matter; multiple data lines are joined with newlines, as the SSE spec says.
package mica_external

import "core:mem"
import "core:strings"

@(private)
Sse_Decoder :: struct {
	buffer:    [dynamic]u8,
	allocator: mem.Allocator,
}

@(private)
sse_decoder_init :: proc(decoder: ^Sse_Decoder, allocator: mem.Allocator) {
	decoder.allocator = allocator
	decoder.buffer = make([dynamic]u8, 0, 4096, allocator)
}

@(private)
sse_decoder_destroy :: proc(decoder: ^Sse_Decoder) {
	if decoder.buffer != nil {
		delete(decoder.buffer)
	}
}

// Appends bytes and returns every complete frame's data payload. Payloads are
// allocated with the decoder's allocator.
@(private)
sse_decoder_push :: proc(
	decoder: ^Sse_Decoder,
	bytes: []byte,
	frames: ^[dynamic]string,
) {
	if len(bytes) > 0 {
		append(&decoder.buffer, ..bytes)
	}
	for {
		frame_end, delimiter_len := sse_frame_end(decoder.buffer[:])
		if frame_end < 0 {
			break
		}
		frame := decoder.buffer[:frame_end]
		if payload, has_payload := sse_frame_data(frame, decoder.allocator); has_payload {
			append(frames, payload)
		}
		remove_range(&decoder.buffer, 0, frame_end + delimiter_len)
	}
}

// Returns any trailing frame left in the buffer when the stream ends.
@(private)
sse_decoder_finish :: proc(decoder: ^Sse_Decoder, frames: ^[dynamic]string) {
	if len(decoder.buffer) == 0 {
		return
	}
	frame := decoder.buffer[:]
	clear(&decoder.buffer)
	if payload, has_payload := sse_frame_data(frame, decoder.allocator); has_payload {
		append(frames, payload)
	}
}

// Finds the first frame boundary: (start index, delimiter length), or -1.
@(private)
sse_frame_end :: proc(bytes: []byte) -> (int, int) {
	if len(bytes) < 2 {
		return -1, 0
	}
	for index := 0; index + 1 < len(bytes); index += 1 {
		if index + 3 < len(bytes) &&
		   bytes[index] == '\r' &&
		   bytes[index + 1] == '\n' &&
		   bytes[index + 2] == '\r' &&
		   bytes[index + 3] == '\n' {
			return index, 4
		}
		if bytes[index] == '\n' && bytes[index + 1] == '\n' {
			return index, 2
		}
	}
	return -1, 0
}

// Extracts the joined `data:` lines of one frame. Returns false when the frame
// carries no data.
@(private)
sse_frame_data :: proc(frame: []byte, allocator: mem.Allocator) -> (string, bool) {
	lines: [dynamic]string
	lines = make([dynamic]string, 0, 4, allocator)
	defer delete(lines)

	text := string(frame)
	for raw_line in strings.split_iterator(&text, "\n") {
		line := strings.trim_suffix(raw_line, "\r")
		if !strings.has_prefix(line, "data:") {
			continue
		}
		value := line[len("data:"):]
		if strings.has_prefix(value, " ") {
			value = value[1:]
		}
		append(&lines, value)
	}
	if len(lines) == 0 {
		return "", false
	}
	return strings.join(lines[:], "\n", allocator), true
}
