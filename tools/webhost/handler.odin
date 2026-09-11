// The webhost request handler: built-in routes, sync input, then world
// documents. The SSE stream runs through the streaming handler.
package main

import "core:net"
import web "../../host/web"

Webhost :: struct {
	routes:    web.Routes,
	documents: web.Documents,
	sync:      web.Sync_Host,
}

webhost_handle :: proc(user: rawptr, request: ^web.Http_Request, response: ^web.Http_Response) {
	host := (^Webhost)(user)
	path := web.http_request_path(request.target)
	if path == "/healthz" || path == "/sync-client.js" {
		web.routes_handle(&host.routes, request, response)
		return
	}
	if path == web.SYNC_INPUT_PATH {
		web.sync_handle_request(&host.sync, request, response)
		return
	}
	web.documents_handle(&host.documents, request, response)
}

webhost_stream :: proc(user: rawptr, request: ^web.Http_Request, socket: net.TCP_Socket) -> bool {
	host := (^Webhost)(user)
	return web.sync_events_stream(&host.sync, request, socket)
}
