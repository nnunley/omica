// Outbound HTTP through libcurl.
//
// Requests run synchronously on the calling host thread. A streaming request
// hands response bytes to a sink as they arrive, so the LLM bridge can decode
// SSE without buffering the whole response. libcurl's easy interface runs one
// transfer per thread, which is exactly how the external worker pool calls it.
package mica_external

import "base:runtime"
import "core:c"
import "core:fmt"
import "core:mem"
import "core:strings"
import "vendor:curl"

// A request to perform. An empty method becomes GET, or POST when a body is
// present.
Request :: struct {
	url:             string,
	method:          string,
	headers:         []string,
	body:            []byte,
	timeout_seconds: i64,
}

// Incremental response data. Returning false from either callback aborts the
// transfer. `on_status` fires when a response status line is parsed, before
// any body bytes.
Stream_Sink :: struct {
	user:      rawptr,
	on_status: proc(user: rawptr, status: u16) -> bool,
	on_data:   proc(user: rawptr, data: []byte) -> bool,
}

// A completed transfer. `body` and `headers` are owned by the caller.
Curl_Result :: struct {
	status:  u16,
	headers: [dynamic][2]string,
	body:    [dynamic]u8,
}

// Cap on buffered response bytes. Streaming sinks are not capped; buffered
// responses (chat completions, embeddings, generic HTTP) are.
CURL_MAX_BUFFER :: 8 * 1024 * 1024

@(private)
Curl_Call :: struct {
	result:    Curl_Result,
	sink:      Stream_Sink,
	allocator: mem.Allocator,
	// The caller's context, restored inside the C callbacks so the Odin
	// helpers they call have an allocator.
	ctx:       runtime.Context,
}

// Performs a request, buffering the response body. On failure the returned
// message describes the transport error and the result is not usable.
curl_perform :: proc(
	request: Request,
	allocator: mem.Allocator,
) -> (
	Curl_Result,
	string,
) {
	return curl_transfer(request, Stream_Sink{}, allocator)
}

// Performs a request, passing every response byte to `sink.on_data`. The
// result's status and headers are still reported; its body stays empty.
curl_perform_stream :: proc(
	request: Request,
	sink: Stream_Sink,
	allocator: mem.Allocator,
) -> (
	Curl_Result,
	string,
) {
	return curl_transfer(request, sink, allocator)
}

@(private)
curl_transfer :: proc(
	request: Request,
	sink: Stream_Sink,
	allocator: mem.Allocator,
) -> (
	Curl_Result,
	string,
) {
	call := Curl_Call {
		sink      = sink,
		allocator = allocator,
		ctx       = context,
	}
	call.result.body = make([dynamic]u8, 0, 4096, allocator)
	call.result.headers = make([dynamic][2]string, 0, 16, allocator)

	handle := curl.easy_init()
	if handle == nil {
		delete(call.result.body)
		delete(call.result.headers)
		return {}, "cannot initialize curl"
	}
	defer curl.easy_cleanup(handle)

	url := strings.clone_to_cstring(request.url, allocator)
	defer delete(url, allocator)

	header_list: ^curl.slist
	for header in request.headers {
		header_text := strings.clone_to_cstring(header, allocator)
		defer delete(header_text, allocator)
		header_list = curl.slist_append(header_list, header_text)
	}
	defer curl.slist_free_all(header_list)

	curl.easy_setopt(handle, curl.option.URL, url)
	curl.easy_setopt(handle, curl.option.HTTPHEADER, header_list)
	curl.easy_setopt(handle, curl.option.WRITEFUNCTION, curl_write_callback)
	curl.easy_setopt(handle, curl.option.WRITEDATA, &call)
	curl.easy_setopt(handle, curl.option.HEADERFUNCTION, curl_header_callback)
	curl.easy_setopt(handle, curl.option.HEADERDATA, &call)
	curl.easy_setopt(handle, curl.option.NOSIGNAL, c.long(1))
	curl.easy_setopt(handle, curl.option.CONNECTTIMEOUT, c.long(15))
	if request.timeout_seconds > 0 {
		curl.easy_setopt(handle, curl.option.TIMEOUT, c.long(request.timeout_seconds))
	}
	if len(request.body) > 0 {
		curl.easy_setopt(handle, curl.option.POSTFIELDS, raw_data(request.body))
		curl.easy_setopt(handle, curl.option.POSTFIELDSIZE, c.long(len(request.body)))
	} else if request.method != "" && request.method != "GET" {
		method := strings.clone_to_cstring(request.method, allocator)
		defer delete(method, allocator)
		curl.easy_setopt(handle, curl.option.CUSTOMREQUEST, method)
	}

	code := curl.easy_perform(handle)
	if code != .E_OK {
		message := fmt.aprintf("curl: %s", curl.easy_strerror(code), allocator = allocator)
		delete(call.result.body)
		delete(call.result.headers)
		return {}, message
	}

	status: c.long
	curl.easy_getinfo(handle, curl.INFO.RESPONSE_CODE, &status)
	call.result.status = u16(status)
	return call.result, ""
}

@(private)
curl_write_callback :: proc "c" (
	ptr: [^]u8,
	size: c.size_t,
	nmemb: c.size_t,
	userdata: rawptr,
) -> c.size_t {
	call := (^Curl_Call)(userdata)
	context = call.ctx
	count := size * nmemb
	if curl_write(call, ptr[:count]) {
		return count
	}
	return 0
}

@(private)
curl_write :: proc(call: ^Curl_Call, data: []byte) -> bool {
	if call.sink.on_data != nil {
		return call.sink.on_data(call.sink.user, data)
	}
	if len(call.result.body) + len(data) > CURL_MAX_BUFFER {
		return false
	}
	append(&call.result.body, ..data)
	return true
}

@(private)
curl_header_callback :: proc "c" (
	ptr: [^]u8,
	size: c.size_t,
	nmemb: c.size_t,
	userdata: rawptr,
) -> c.size_t {
	call := (^Curl_Call)(userdata)
	context = call.ctx
	count := size * nmemb
	if curl_header(call, ptr[:count]) {
		return count
	}
	return 0
}

@(private)
curl_header :: proc(call: ^Curl_Call, line: []byte) -> bool {
	text := strings.trim_space(string(line))
	if text == "" {
		return true
	}
	// A status line starts a response (redirects and 100-continue can produce
	// several); the last one wins.
	if strings.has_prefix(text, "HTTP/") {
		if space := strings.index_byte(text, ' '); space >= 0 {
			rest := text[space + 1:]
			status_text := rest
			if end := strings.index_byte(rest, ' '); end >= 0 {
				status_text = rest[:end]
			}
			if status, ok := parse_u16(status_text); ok {
				call.result.status = status
				if call.sink.on_status != nil {
					return call.sink.on_status(call.sink.user, status)
				}
			}
		}
		return true
	}
	separator := strings.index(text, ":")
	if separator <= 0 {
		return true
	}
	name := strings.trim_space(text[:separator])
	value := strings.trim_space(text[separator + 1:])
	append(
		&call.result.headers,
		[2]string{strings.clone(name, call.allocator), strings.clone(value, call.allocator)},
	)
	return true
}

@(private)
parse_u16 :: proc(text: string) -> (u16, bool) {
	value := 0
	if text == "" {
		return 0, false
	}
	for ch in text {
		if ch < '0' || ch > '9' {
			return 0, false
		}
		value = value * 10 + int(ch - '0')
		if value > 65535 {
			return 0, false
		}
	}
	return u16(value), true
}
