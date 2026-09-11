package web

import "core:testing"
import v "../../mica/var"

@(private)
symbol_value :: proc(name: string) -> v.Value {
	return v.value_symbol(v.symbol_intern(name))
}

@(private)
string_value :: proc(text: string) -> v.Value {
	return v.value_string(context.temp_allocator, text)
}

@(test)
test_web_decode_string_response :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	response: Http_Response
	ok, message := web_decode_response(string_value("hello"), &response)
	testing.expectf(t, ok, "decode failed: %s", message)
	testing.expect_value(t, response.status, 200)
	testing.expect_value(t, string(response.body), "hello")
	testing.expect_value(t, response.content_type, "text/plain; charset=utf-8")
}

@(test)
test_web_decode_unit_response :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	response: Http_Response
	ok, message := web_decode_response(v.value_empty_relation(), &response)
	testing.expectf(t, ok, "decode failed: %s", message)
	testing.expect_value(t, response.status, 204)
	testing.expect_value(t, len(response.body), 0)
}

@(test)
test_web_decode_map_response :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	allocator := context.temp_allocator
	status_value, _ := v.value_int(201)
	headers := v.value_list(allocator, []v.Value {
		v.value_list(allocator, []v.Value {
			string_value("content-type"),
			string_value("text/plain"),
		}),
		v.value_list(allocator, []v.Value {
			string_value("x-bytes"),
			v.value_bytes(allocator, as_bytes("ab")),
		}),
	})
	value := v.value_map(allocator, []v.Map_Entry {
		{key = symbol_value("status"), value = status_value},
		{key = symbol_value("reason"), value = string_value("Created Thing")},
		{key = symbol_value("headers"), value = headers},
		{key = symbol_value("body"), value = string_value("hi")},
	})

	response: Http_Response
	ok, message := web_decode_response(value, &response)
	testing.expectf(t, ok, "decode failed: %s", message)
	testing.expect_value(t, response.status, 201)
	testing.expect_value(t, response.reason, "Created Thing")
	testing.expect_value(t, len(response.headers), 2)
	testing.expect_value(t, response.headers[0].name, "content-type")
	testing.expect_value(t, response.headers[0].value, "text/plain")
	testing.expect_value(t, response.headers[1].name, "x-bytes")
	testing.expect_value(t, response.headers[1].value, "ab")
	testing.expect_value(t, string(response.body), "hi")
}

@(test)
test_web_decode_map_errors :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	allocator := context.temp_allocator

	bad_status := v.value_map(allocator, []v.Map_Entry {
		{key = symbol_value("status"), value = string_value("nope")},
	})
	response: Http_Response
	ok, _ := web_decode_response(bad_status, &response)
	testing.expect(t, !ok)

	out_of_range, _ := v.value_int(99)
	bad_range := v.value_map(allocator, []v.Map_Entry {
		{key = symbol_value("status"), value = out_of_range},
	})
	ok, _ = web_decode_response(bad_range, &response)
	testing.expect(t, !ok)

	bad_reason := v.value_map(allocator, []v.Map_Entry {
		{key = symbol_value("reason"), value = string_value("bad\nreason")},
	})
	ok, _ = web_decode_response(bad_reason, &response)
	testing.expect(t, !ok)

	bad_header_name := v.value_map(allocator, []v.Map_Entry {
		{
			key = symbol_value("headers"),
			value = v.value_list(allocator, []v.Value {
				v.value_list(allocator, []v.Value {
					string_value("bad name"),
					string_value("v"),
				}),
			}),
		},
	})
	ok, _ = web_decode_response(bad_header_name, &response)
	testing.expect(t, !ok)

	bad_header_value := v.value_map(allocator, []v.Map_Entry {
		{
			key = symbol_value("headers"),
			value = v.value_list(allocator, []v.Value {
				v.value_list(allocator, []v.Value {
					string_value("x"),
					string_value("bad\rvalue"),
				}),
			}),
		},
	})
	ok, _ = web_decode_response(bad_header_value, &response)
	testing.expect(t, !ok)

	body_int, _ := v.value_int(3)
	bad_body := v.value_map(allocator, []v.Map_Entry {
		{key = symbol_value("body"), value = body_int},
	})
	ok, _ = web_decode_response(bad_body, &response)
	testing.expect(t, !ok)

	not_a_response, _ := v.value_int(7)
	ok, _ = web_decode_response(not_a_response, &response)
	testing.expect(t, !ok)
}
