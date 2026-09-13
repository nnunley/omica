// Minimal HTTP/1.1 request parsing and response encoding.
//
// The parser is incremental: callers push bytes as they arrive and poll for a
// complete request. Parsed fields are views into the parser buffer and stay
// valid until the next `http_parser_consume`.
package web

import "core:fmt"
import "core:mem"
import "core:strings"

// Server limits. Requests beyond these are rejected with a 4xx response.
Http_Limits :: struct {
	max_request_line: int,
	max_header_bytes: int,
	max_headers:      int,
	max_body_bytes:   int,
}

DEFAULT_HTTP_LIMITS :: Http_Limits {
	max_request_line = 8 * 1024,
	max_header_bytes = 32 * 1024,
	max_headers      = 100,
	max_body_bytes   = 1024 * 1024,
}

Http_Header :: struct {
	name:  string,
	value: string,
}

Http_Request :: struct {
	method:  string,
	target:  string,
	version: string,
	headers: []Http_Header,
	body:    []byte,
	// True when the connection must close after this response.
	close:   bool,
}

// Result of one parse attempt.
Http_Parse_State :: enum {
	Incomplete,
	Ready,
	Error,
}

Http_Parse_Error :: struct {
	status:  int,
	message: string,
}

Http_Parser :: struct {
	buffer:     [dynamic]u8,
	headers:    [dynamic]Http_Header,
	limits:     Http_Limits,
	pos:        int,
	last_total: int,
}

http_parser_init :: proc(parser: ^Http_Parser, limits := DEFAULT_HTTP_LIMITS) {
	parser.limits = limits
	parser.buffer = make([dynamic]u8)
	parser.headers = make([dynamic]Http_Header)
}

http_parser_destroy :: proc(parser: ^Http_Parser) {
	delete(parser.buffer)
	delete(parser.headers)
}

http_parser_push :: proc(parser: ^Http_Parser, bytes: []u8) {
	append(&parser.buffer, ..bytes)
}

// Drops the bytes of a consumed request. Call after the caller is done with the
// request views.
http_parser_consume :: proc(parser: ^Http_Parser, total: int) {
	parser.pos += total
	if parser.pos <= 0 {
		return
	}
	if parser.pos >= len(parser.buffer) {
		clear(&parser.buffer)
		parser.pos = 0
		return
	}
	// Compact when the consumed prefix passes half the buffer.
	if parser.pos * 2 >= len(parser.buffer) {
		remaining := len(parser.buffer) - parser.pos
		copy(parser.buffer[:remaining], parser.buffer[parser.pos:])
		resize(&parser.buffer, remaining)
		parser.pos = 0
	}
}

// Attempts to parse one request from the pushed bytes.
http_parser_next :: proc(parser: ^Http_Parser) -> (Http_Request, Http_Parse_State, Http_Parse_Error) {
	view := parser.buffer[parser.pos:]
	if len(view) == 0 {
		return {}, .Incomplete, {}
	}
	terminator := strings.index(string(view), "\r\n\r\n")
	if terminator < 0 {
		if len(view) > parser.limits.max_header_bytes {
			return {}, .Error, Http_Parse_Error{431, "request headers are too large"}
		}
		return {}, .Incomplete, {}
	}
	if terminator + 4 > parser.limits.max_header_bytes {
		return {}, .Error, Http_Parse_Error{431, "request headers are too large"}
	}
	header_bytes := view[:terminator]
	header_end := terminator + 4

	line_end := strings.index(string(header_bytes), "\r\n")
	if line_end < 0 {
		line_end = len(header_bytes)
	}
	request_line := string(header_bytes[:line_end])
	if len(request_line) > parser.limits.max_request_line {
		return {}, .Error, Http_Parse_Error{414, "request line is too long"}
	}
	method, target, version, line_ok := parse_request_line(request_line)
	if !line_ok {
		return {}, .Error, Http_Parse_Error{400, "malformed request line"}
	}
	major, minor, version_ok := parse_http_version(version)
	if !version_ok {
		return {}, .Error, Http_Parse_Error{505, "unsupported HTTP version"}
	}

	clear(&parser.headers)
	// A request line with no trailing CRLF has no header region at all.
	remaining := header_bytes[min(line_end + 2, len(header_bytes)):]
	for len(remaining) > 0 {
		// The last header line has no trailing CRLF: its line ending is the
		// first half of the "\r\n\r\n" terminator.
		header_line_end := strings.index(string(remaining), "\r\n")
		line_length := header_line_end < 0 ? len(remaining) : header_line_end
		if line_length <= 0 {
			return {}, .Error, Http_Parse_Error{400, "malformed header line"}
		}
		colon := strings.index_byte(string(remaining[:line_length]), ':')
		if colon <= 0 {
			return {}, .Error, Http_Parse_Error{400, "malformed header line"}
		}
		name := string(remaining[:colon])
		if !is_token(name) {
			return {}, .Error, Http_Parse_Error{400, "invalid header name"}
		}
		value := strings.trim_space(string(remaining[colon + 1:line_length]))
		append(&parser.headers, Http_Header{name = name, value = value})
		if len(parser.headers) > parser.limits.max_headers {
			return {}, .Error, Http_Parse_Error{431, "too many request headers"}
		}
		if header_line_end < 0 {
			remaining = remaining[:0]
		} else {
			remaining = remaining[header_line_end + 2:]
		}
	}

	content_length := -1
	connection_close := false
	connection_keep_alive := false
	for header in parser.headers {
		switch {
		case strings.equal_fold(header.name, "content-length"):
			if content_length >= 0 {
				return {}, .Error, Http_Parse_Error{400, "duplicate content-length"}
			}
			parsed, ok := parse_content_length(header.value)
			if !ok {
				return {}, .Error, Http_Parse_Error{400, "invalid content-length"}
			}
			if parsed > parser.limits.max_body_bytes {
				return {}, .Error, Http_Parse_Error{413, "request body is too large"}
			}
			content_length = parsed
		case strings.equal_fold(header.name, "transfer-encoding"):
			return {}, .Error, Http_Parse_Error{400, "transfer-encoding is not supported"}
		case strings.equal_fold(header.name, "connection"):
			connection_close = connection_close || header_has_token(header.value, "close")
			connection_keep_alive =
				connection_keep_alive || header_has_token(header.value, "keep-alive")
		}
	}

	body_length := content_length < 0 ? 0 : content_length
	total := header_end + body_length
	if len(view) < total {
		return {}, .Incomplete, {}
	}

	close := false
	if major == 1 && minor == 0 {
		close = !connection_keep_alive
	} else {
		close = connection_close
	}

	parser.last_total = total
	request := Http_Request {
		method  = method,
		target  = target,
		version = version,
		headers = parser.headers[:],
		body    = view[header_end:total],
		close   = close,
	}
	return request, .Ready, {}
}

@(private)
parse_request_line :: proc(line: string) -> (method, target, version: string, ok: bool) {
	first := strings.index_byte(line, ' ')
	if first <= 0 {
		return "", "", "", false
	}
	rest := line[first + 1:]
	second := strings.index_byte(rest, ' ')
	if second <= 0 || second == len(rest) - 1 {
		return "", "", "", false
	}
	method = line[:first]
	target = rest[:second]
	version = rest[second + 1:]
	if !is_token(method) || len(target) == 0 {
		return "", "", "", false
	}
	return method, target, version, true
}

@(private)
parse_http_version :: proc(version: string) -> (major, minor: int, ok: bool) {
	if !strings.has_prefix(version, "HTTP/") {
		return 0, 0, false
	}
	rest := version[len("HTTP/"):]
	dot := strings.index_byte(rest, '.')
	if dot <= 0 || dot == len(rest) - 1 {
		return 0, 0, false
	}
	if !is_digits(rest[:dot]) || !is_digits(rest[dot + 1:]) {
		return 0, 0, false
	}
	major_value, major_ok := parse_decimal(rest[:dot])
	minor_value, minor_ok := parse_decimal(rest[dot + 1:])
	if !major_ok || !minor_ok {
		return 0, 0, false
	}
	return major_value, minor_value, true
}

@(private)
parse_content_length :: proc(value: string) -> (int, bool) {
	if !is_digits(value) {
		return 0, false
	}
	return parse_decimal(value)
}

@(private)
is_digits :: proc(text: string) -> bool {
	if len(text) == 0 {
		return false
	}
	for c in text {
		if c < '0' || c > '9' {
			return false
		}
	}
	return true
}

@(private)
parse_decimal :: proc(text: string) -> (int, bool) {
	if len(text) == 0 {
		return 0, false
	}
	value := 0
	for c in text {
		digit := int(c - '0')
		if digit < 0 || digit > 9 {
			return 0, false
		}
		if value > (max(int) - digit) / 10 {
			return 0, false
		}
		value = value * 10 + digit
	}
	return value, true
}

@(private)
is_token :: proc(text: string) -> bool {
	if len(text) == 0 {
		return false
	}
	for c in text {
		if !is_token_char(c) {
			return false
		}
	}
	return true
}

@(private)
is_token_char :: proc(c: rune) -> bool {
	switch c {
	case 'a' ..= 'z', 'A' ..= 'Z', '0' ..= '9':
		return true
	case '!', '#', '$', '%', '&', '\'', '*', '+', '-', '.', '^', '_', '`', '|', '~':
		return true
	}
	return false
}

// Reports whether a comma-separated header value contains `token`.
@(private)
header_has_token :: proc(value, token: string) -> bool {
	remaining := value
	for len(remaining) > 0 {
		end := strings.index_byte(remaining, ',')
		part: string
		if end < 0 {
			part = remaining
			remaining = ""
		} else {
			part = remaining[:end]
			remaining = remaining[end + 1:]
		}
		if strings.equal_fold(strings.trim_space(part), token) {
			return true
		}
	}
	return false
}

// --- Responses -------------------------------------------------------------

Http_Response :: struct {
	status:       int,
	reason:       string,
	content_type: string,
	headers:      []Http_Header,
	body:         []byte,
	close:        bool,
}

http_response_reset :: proc(response: ^Http_Response) {
	response^ = {}
}

// Sets a string body without copying. The caller keeps the string alive until
// the response is written.
http_response_text :: proc(
	response: ^Http_Response,
	status: int,
	content_type: string,
	body: string,
) {
	response.status = status
	response.content_type = content_type
	response.body = transmute([]byte)body
}

http_response_bytes :: proc(response: ^Http_Response, status: int, body: []byte) {
	response.status = status
	response.body = body
}

// Encodes a full response with a Content-Length body.
http_encode_response :: proc(response: ^Http_Response, builder: ^strings.Builder) {
	status := response.status
	reason := response.reason
	if reason == "" {
		reason = http_status_reason(status)
	}
	fmt.sbprintf(builder, "HTTP/1.1 %d %s\r\n", status, reason)
	fmt.sbprintf(builder, "Content-Length: %d\r\n", len(response.body))
	if response.content_type != "" {
		fmt.sbprintf(builder, "Content-Type: %s\r\n", response.content_type)
	} else if len(response.body) > 0 {
		// Never let an untyped body be sniffed into a different type.
		strings.write_string(builder, "Content-Type: application/octet-stream\r\n")
	}
	strings.write_string(builder, "X-Content-Type-Options: nosniff\r\n")
	for header in response.headers {
		// Never emit a name or value that could split the response; callers
		// should have validated, this is defense in depth.
		if !is_token(header.name) || !valid_header_value(header.value) {
			continue
		}
		fmt.sbprintf(builder, "%s: %s\r\n", header.name, header.value)
	}
	if response.close {
		strings.write_string(builder, "Connection: close\r\n")
	} else {
		strings.write_string(builder, "Connection: keep-alive\r\n")
	}
	strings.write_string(builder, "\r\n")
	if len(response.body) > 0 {
		strings.write_bytes(builder, response.body)
	}
}

// Writes one HTTP chunk. Used by the SSE event stream.
http_write_chunk :: proc(builder: ^strings.Builder, payload: []byte) {
	fmt.sbprintf(builder, "%X\r\n", len(payload))
	strings.write_bytes(builder, payload)
	strings.write_string(builder, "\r\n")
}

http_status_reason :: proc(status: int) -> string {
	switch status {
	case 200:
		return "OK"
	case 202:
		return "Accepted"
	case 204:
		return "No Content"
	case 301:
		return "Moved Permanently"
	case 302:
		return "Found"
	case 303:
		return "See Other"
	case 304:
		return "Not Modified"
	case 400:
		return "Bad Request"
	case 401:
		return "Unauthorized"
	case 403:
		return "Forbidden"
	case 404:
		return "Not Found"
	case 405:
		return "Method Not Allowed"
	case 408:
		return "Request Timeout"
	case 413:
		return "Payload Too Large"
	case 414:
		return "URI Too Long"
	case 429:
		return "Too Many Requests"
	case 431:
		return "Request Header Fields Too Large"
	case 500:
		return "Internal Server Error"
	case 501:
		return "Not Implemented"
	case 503:
		return "Service Unavailable"
	case 505:
		return "HTTP Version Not Supported"
	}
	return "Unknown"
}
