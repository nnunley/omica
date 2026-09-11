// Serves Mica worlds over HTTP/1.1 and SSE.
//
// M0: health check, the sync client script, and a landing stub. World
// document routes and sync sessions arrive in later milestones.
//
// Usage:
//
//	odin run tools/webhost -- --bind 127.0.0.1:8080 --sync-client path.js
package main

import "core:fmt"
import "core:net"
import "core:os"

import web "../../host/web"

DEFAULT_BIND :: "127.0.0.1:8080"

main :: proc() {
	bind := DEFAULT_BIND
	sync_client := ""

	args := os.args[1:]
	for index := 0; index < len(args); index += 1 {
		switch args[index] {
		case "--bind":
			if index + 1 >= len(args) {
				usage()
				os.exit(1)
			}
			index += 1
			bind = args[index]
		case "--sync-client":
			if index + 1 >= len(args) {
				usage()
				os.exit(1)
			}
			index += 1
			sync_client = args[index]
		case "--help", "-h":
			usage()
			return
		case:
			fmt.eprintf("webhost: unknown argument %s\n", args[index])
			usage()
			os.exit(1)
		}
	}

	routes: web.Routes
	if ok, message := web.routes_init(&routes, sync_client); !ok {
		fmt.eprintf("webhost: %s\n", message)
		os.exit(1)
	}
	defer web.routes_destroy(&routes)

	server: web.Web_Server
	if ok, message := web.web_server_init(&server, bind, web.routes_handle, &routes); !ok {
		fmt.eprintf("webhost: %s: %s\n", bind, message)
		os.exit(1)
	}

	if endpoint, endpoint_ok := web.web_server_endpoint(&server); endpoint_ok {
		fmt.printf("listening on http://%s/\n", net.endpoint_to_string(endpoint))
	} else {
		fmt.printf("listening on %s\n", bind)
	}
	web.web_server_run(&server)
}

@(private)
usage :: proc() {
	fmt.eprintln("usage: webhost [--bind address:port] [--sync-client path.js]")
}
