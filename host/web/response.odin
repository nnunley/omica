// Decodes a Mica response value into an HTTP response.
//
// The contract mirrors the Rust web host: a string is a `200 OK` body, the
// empty relation (unit) is `204 No Content`, and a map carries status, reason,
// headers, and body.
package web

import v "../../mica/var"

web_decode_response :: proc(value: v.Value, response: ^Http_Response) -> (ok: bool, message: string) {
	if text, is_text := v.value_as_string(value); is_text {
		http_response_text(response, 200, "text/plain; charset=utf-8", text)
		return true, ""
	}
	if v.value_is_empty_relation(value) {
		response.status = 204
		return true, ""
	}
	entries, is_map := v.value_as_map(value)
	if !is_map {
		return false, "response must be a string, unit, or response map"
	}

	status := 200
	if status_value, found := response_map_get(entries, "status"); found {
		parsed, is_int := v.value_as_int(status_value)
		if !is_int || parsed < 100 || parsed > 999 {
			return false, "response :status must be an integer between 100 and 999"
		}
		status = int(parsed)
	}
	response.status = status

	if reason_value, found := response_map_get(entries, "reason"); found {
		reason, is_string := v.value_as_string(reason_value)
		if !is_string {
			return false, "response :reason must be a string"
		}
		if !valid_reason(reason) {
			return false, "response :reason contains invalid characters"
		}
		response.reason = reason
	}

	if headers_value, found := response_map_get(entries, "headers"); found {
		header_list, is_list := v.value_as_list(headers_value)
		if !is_list {
			return false, "response :headers must be a list"
		}
		headers := make([dynamic]Http_Header, context.temp_allocator)
		for item in header_list {
			pair, pair_ok := v.value_as_list(item)
			if !pair_ok || len(pair) != 2 {
				return false, "response header entries must be [name, value]"
			}
			name, name_ok := v.value_as_string(pair[0])
			if !name_ok || !is_token(name) {
				return false, "response header name is invalid"
			}
			header_value: string
			if text, text_ok := v.value_as_string(pair[1]); text_ok {
				header_value = text
			} else if bytes, bytes_ok := v.value_as_bytes(pair[1]); bytes_ok {
				header_value = string(bytes)
			} else {
				return false, "response header value must be a string or bytes"
			}
			if !valid_header_value(header_value) {
				return false, "response header value contains invalid characters"
			}
			append(&headers, Http_Header{name = name, value = header_value})
		}
		response.headers = headers[:]
	}

	if body_value, found := response_map_get(entries, "body"); found {
		if text, is_string := v.value_as_string(body_value); is_string {
			response.body = transmute([]byte)text
		} else if bytes, is_bytes := v.value_as_bytes(body_value); is_bytes {
			response.body = bytes
		} else {
			return false, "response :body must be a string or bytes"
		}
	}
	return true, ""
}

@(private)
response_map_get :: proc(entries: []v.Map_Entry, key: string) -> (v.Value, bool) {
	key_value := v.value_symbol(v.symbol_intern(key))
	for entry in entries {
		if v.value_eq(entry.key, key_value) {
			return entry.value, true
		}
	}
	return v.Value(0), false
}

@(private)
valid_reason :: proc(text: string) -> bool {
	for c in text {
		if c == '\r' || c == '\n' || c == 0x7f {
			return false
		}
		if c < 0x20 && c != '\t' {
			return false
		}
	}
	return true
}

@(private)
valid_header_value :: proc(text: string) -> bool {
	for c in text {
		if c == '\r' || c == '\n' || c == 0 || c == 0x7f {
			return false
		}
		if c < 0x20 && c != '\t' {
			return false
		}
	}
	return true
}
