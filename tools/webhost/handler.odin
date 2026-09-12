// The webhost request handler: built-in routes, sync input, then world
// documents. The SSE stream runs through the streaming handler.
package main

import "core:net"
import web "../../host/web"

Webhost :: struct {
	routes:    web.Routes,
	documents: web.Documents,
	sync:      web.Sync_Host,
	auth:      web.Auth,
}

webhost_handle :: proc(user: rawptr, request: ^web.Http_Request, response: ^web.Http_Response) {
	host := (^Webhost)(user)
	path := web.http_request_path(request.target)
	if path == "/healthz" || path == "/sync-client.js" {
		web.routes_handle(&host.routes, request, response)
		return
	}
	if web.auth_handle(&host.auth, request, response) {
		return
	}
	actor := web.auth_actor_for_request(&host.auth, request)
	if path == web.SYNC_INPUT_PATH {
		web.sync_handle_request(&host.sync, actor, request, response)
		return
	}
	web.documents_handle_actor(&host.documents, actor, request, response)
}

webhost_stream :: proc(user: rawptr, request: ^web.Http_Request, socket: net.TCP_Socket) -> bool {
	host := (^Webhost)(user)
	actor := web.auth_actor_for_request(&host.auth, request)
	return web.sync_events_stream(
		&host.sync,
		actor,
		&host.auth,
		web.auth_request_token(request),
		request,
		socket,
	)
}
