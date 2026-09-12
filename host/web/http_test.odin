package web

import "core:strings"
import "core:testing"

@(private)
as_bytes :: proc(text: string) -> []u8 {
	return transmute([]byte)text
}

@(private)
parse_request :: proc(
	t: ^testing.T,
	parser: ^Http_Parser,
	source: string,
) -> (
	Http_Request,
	Http_Parse_State,
	Http_Parse_Error,
) {
	http_parser_push(parser, as_bytes(source))
	return http_parser_next(parser)
}

@(test)
test_http_parse_request :: proc(t: ^testing.T) {
	parser: Http_Parser
	http_parser_init(&parser)
	defer http_parser_destroy(&parser)

	source := "GET /x?y=1 HTTP/1.1\r\nHost: a\r\nContent-Length: 5\r\n\r\nhello"
	request, state, parse_error := parse_request(t, &parser, source)
	testing.expect_value(t, state, Http_Parse_State.Ready)
	testing.expectf(t, parse_error.status == 0, "unexpected parse error: %s", parse_error.message)
	testing.expect_value(t, request.method, "GET")
	testing.expect_value(t, request.target, "/x?y=1")
	testing.expect_value(t, request.version, "HTTP/1.1")
	testing.expect_value(t, len(request.headers), 2)
	testing.expect_value(t, request.headers[0].name, "Host")
	testing.expect_value(t, request.headers[0].value, "a")
	testing.expect_value(t, string(request.body), "hello")
	testing.expect(t, !request.close)
	testing.expect_value(t, parser.last_total, len(source))

	http_parser_consume(&parser, parser.last_total)
	_, next_state, _ := http_parser_next(&parser)
	testing.expect_value(t, next_state, Http_Parse_State.Incomplete)
}

// A request with no header lines must parse to an empty header set rather than
// trapping on the absent header region.
@(test)
test_http_parse_headerless_request :: proc(t: ^testing.T) {
	parser: Http_Parser
	http_parser_init(&parser)
	defer http_parser_destroy(&parser)

	request, state, parse_error := parse_request(t, &parser, "GET / HTTP/1.0\r\n\r\n")
	testing.expect_value(t, state, Http_Parse_State.Ready)
	testing.expectf(t, parse_error.status == 0, "unexpected parse error: %s", parse_error.message)
	testing.expect_value(t, request.method, "GET")
	testing.expect_value(t, request.target, "/")
	testing.expect_value(t, len(request.headers), 0)
}

@(test)
test_http_parse_incremental :: proc(t: ^testing.T) {
	parser: Http_Parser
	http_parser_init(&parser)
	defer http_parser_destroy(&parser)

	http_parser_push(&parser, as_bytes("GET /a HTTP/1.1\r\nHost: x\r\n"))
	_, state, _ := http_parser_next(&parser)
	testing.expect_value(t, state, Http_Parse_State.Incomplete)

	http_parser_push(&parser, as_bytes("Content-Length: 3\r\n\r\nab"))
	_, state_two, _ := http_parser_next(&parser)
	testing.expect_value(t, state_two, Http_Parse_State.Incomplete)

	http_parser_push(&parser, as_bytes("c"))
	request, state_three, _ := http_parser_next(&parser)
	testing.expect_value(t, state_three, Http_Parse_State.Ready)
	testing.expect_value(t, string(request.body), "abc")
}

@(test)
test_http_keepalive_policy :: proc(t: ^testing.T) {
	Case :: struct {
		source: string,
		close:  bool,
	}
	cases := []Case {
		{"GET / HTTP/1.1\r\nHost: a\r\n\r\n", false},
		{"GET / HTTP/1.1\r\nHost: a\r\nConnection: close\r\n\r\n", true},
		{"GET / HTTP/1.0\r\nHost: a\r\n\r\n", true},
		{"GET / HTTP/1.0\r\nHost: a\r\nConnection: keep-alive\r\n\r\n", false},
		{"GET / HTTP/1.1\r\nHost: a\r\nConnection: keep-alive, close\r\n\r\n", true},
	}
	for item in cases {
		parser: Http_Parser
		http_parser_init(&parser)
		request, state, _ := parse_request(t, &parser, item.source)
		testing.expectf(t, state == .Ready, "%q did not parse", item.source)
		testing.expectf(t, request.close == item.close, "%q close = %v", item.source, request.close)
		http_parser_destroy(&parser)
	}
}

@(test)
test_http_rejects_chunked :: proc(t: ^testing.T) {
	parser: Http_Parser
	http_parser_init(&parser)
	defer http_parser_destroy(&parser)

	_, state, parse_error := parse_request(
		t,
		&parser,
		"POST / HTTP/1.1\r\nHost: a\r\nTransfer-Encoding: chunked\r\n\r\n",
	)
	testing.expect_value(t, state, Http_Parse_State.Error)
	testing.expect_value(t, parse_error.status, 400)
}

@(test)
test_http_content_length_errors :: proc(t: ^testing.T) {
	parser: Http_Parser
	http_parser_init(&parser)
	defer http_parser_destroy(&parser)

	_, state, parse_error := parse_request(
		t,
		&parser,
		"POST / HTTP/1.1\r\nContent-Length: nope\r\n\r\n",
	)
	testing.expect_value(t, state, Http_Parse_State.Error)
	testing.expect_value(t, parse_error.status, 400)

	parser_two: Http_Parser
	http_parser_init(&parser_two)
	defer http_parser_destroy(&parser_two)
	_, state_two, parse_error_two := parse_request(
		t,
		&parser_two,
		"POST / HTTP/1.1\r\nContent-Length: 1\r\nContent-Length: 2\r\n\r\n",
	)
	testing.expect_value(t, state_two, Http_Parse_State.Error)
	testing.expect_value(t, parse_error_two.status, 400)
}

@(test)
test_http_limits :: proc(t: ^testing.T) {
	limits := DEFAULT_HTTP_LIMITS
	limits.max_request_line = 24
	limits.max_header_bytes = 64
	limits.max_headers = 1
	limits.max_body_bytes = 4

	parser: Http_Parser
	http_parser_init(&parser, limits)
	defer http_parser_destroy(&parser)

	_, state, parse_error := parse_request(
		t,
		&parser,
		"GET /this-path-is-far-too-long HTTP/1.1\r\n\r\n",
	)
	testing.expect_value(t, state, Http_Parse_State.Error)
	testing.expect_value(t, parse_error.status, 414)

	parser_two: Http_Parser
	http_parser_init(&parser_two, limits)
	defer http_parser_destroy(&parser_two)
	long_header := "GET / HTTP/1.1\r\nX-Long: aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\r\n\r\n"
	_, state_two, parse_error_two := parse_request(t, &parser_two, long_header)
	testing.expect_value(t, state_two, Http_Parse_State.Error)
	testing.expect_value(t, parse_error_two.status, 431)

	parser_three: Http_Parser
	http_parser_init(&parser_three, limits)
	defer http_parser_destroy(&parser_three)
	_, state_three, parse_error_three := parse_request(
		t,
		&parser_three,
		"GET / HTTP/1.1\r\nA: 1\r\nB: 2\r\n\r\n",
	)
	testing.expect_value(t, state_three, Http_Parse_State.Error)
	testing.expect_value(t, parse_error_three.status, 431)

	parser_four: Http_Parser
	http_parser_init(&parser_four, limits)
	defer http_parser_destroy(&parser_four)
	_, state_four, parse_error_four := parse_request(
		t,
		&parser_four,
		"POST / HTTP/1.1\r\nContent-Length: 5\r\n\r\nhello",
	)
	testing.expect_value(t, state_four, Http_Parse_State.Error)
	testing.expect_value(t, parse_error_four.status, 413)
}

@(private)
test_headers := []Http_Header{{"X-Test", "1"}}

@(test)
test_http_encode_response :: proc(t: ^testing.T) {
	response: Http_Response
	http_response_text(&response, 200, "text/plain", "hi")
	response.close = true
	response.headers = test_headers

	builder: strings.Builder
	strings.builder_init(&builder)
	defer strings.builder_destroy(&builder)
	http_encode_response(&response, &builder)

	expected := "HTTP/1.1 200 OK\r\n" +
		"Content-Length: 2\r\n" +
		"Content-Type: text/plain\r\n" +
		"X-Test: 1\r\n" +
		"Connection: close\r\n" +
		"\r\n" +
		"hi"
	testing.expect_value(t, strings.to_string(builder), expected)
}

@(test)
test_http_chunk_framing :: proc(t: ^testing.T) {
	builder: strings.Builder
	strings.builder_init(&builder)
	defer strings.builder_destroy(&builder)

	http_write_chunk(&builder, as_bytes("hello"))
	http_write_chunk(&builder, as_bytes("!"))
	testing.expect_value(t, strings.to_string(builder), "5\r\nhello\r\n1\r\n!\r\n")
}
