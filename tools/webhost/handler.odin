// The webhost request handler: built-in routes first, then world documents.
package main

import web "../../host/web"

Webhost :: struct {
	routes:    web.Routes,
	documents: web.Documents,
}

webhost_handle :: proc(user: rawptr, request: ^web.Http_Request, response: ^web.Http_Response) {
	host := (^Webhost)(user)
	path := web.http_request_path(request.target)
	if path == "/healthz" || path == "/sync-client.js" {
		web.routes_handle(&host.routes, request, response)
		return
	}
	web.documents_handle(&host.documents, request, response)
}
