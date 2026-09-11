// Built-in routes for the M0 host: health check, the sync client script, and a
// landing stub. World document routes arrive in M1 through the handler.
package web

import "core:mem"
import "core:os"
import "core:strings"

Routes :: struct {
	sync_client: []u8,
	allocator:   mem.Allocator,
}

// Static header lists. Handlers must not return slice literals that outlive
// their frame, so these live at file scope.
@(private)
allow_get_headers := []Http_Header{{"Allow", "GET"}}

@(private)
no_store_headers := []Http_Header{{"Cache-Control", "no-store"}}

// Loads the sync client script from disk. An empty path leaves it unserved.
routes_init :: proc(
	routes: ^Routes,
	sync_client_path: string,
	allocator := context.allocator,
) -> (
	ok: bool,
	message: string,
) {
	routes.allocator = allocator
	if sync_client_path == "" {
		return true, ""
	}
	data, read_err := os.read_entire_file(sync_client_path, allocator)
	if read_err != nil {
		return false, "cannot read the sync client script"
	}
	routes.sync_client = data
	return true, ""
}

routes_destroy :: proc(routes: ^Routes) {
	if routes.sync_client != nil {
		delete(routes.sync_client, routes.allocator)
	}
}

routes_handle :: proc(user: rawptr, request: ^Http_Request, response: ^Http_Response) {
	routes := (^Routes)(user)
	path := http_request_path(request.target)

	if request.method != "GET" {
		response.headers = allow_get_headers
		http_response_text(response, 405, "text/plain", "method not allowed\n")
		return
	}

	switch {
	case path == "/healthz":
		http_response_text(response, 200, "text/plain; charset=utf-8", "ok\n")
	case path == "/sync-client.js":
		if len(routes.sync_client) == 0 {
			http_response_text(response, 404, "text/plain", "not found\n")
			return
		}
		response.status = 200
		response.content_type = "text/javascript; charset=utf-8"
		response.headers = no_store_headers
		response.body = routes.sync_client
	case path == "/":
		http_response_text(
			response,
			200,
			"text/html; charset=utf-8",
			"<!doctype html><html><head><meta charset=\"utf-8\">" +
			"<title>Mica</title></head><body><main>" +
			"<h1>Mica</h1><p>HTTP/1.1 host is running.</p>" +
			"</main></body></html>\n",
		)
	case:
		http_response_text(response, 404, "text/plain", "not found\n")
	}
}

// Strips the query string from a request target.
http_request_path :: proc(target: string) -> string {
	query := strings.index_byte(target, '?')
	if query < 0 {
		return target
	}
	return target[:query]
}
