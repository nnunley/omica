// Serves Mica worlds over HTTP/1.1 and SSE.
//
// M1: health check, the sync client script, and document routes that dispatch
// the world's `http_request` verb. Sync sessions arrive in a later milestone.
//
// Usage:
//
//	odin run tools/webhost -- --filein apps/... --bind 127.0.0.1:8080
package main

import "core:fmt"
import "core:net"
import "core:os"

import web "../../host/web"
import k "../../mica/kernel"
import r "../../mica/runtime"

DEFAULT_BIND :: "127.0.0.1:8080"
DEFAULT_WORKERS :: 4

main :: proc() {
	bind := DEFAULT_BIND
	sync_client := ""
	actor := ""
	fileins: [dynamic]string
	defer delete(fileins)

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
		case "--filein":
			if index + 1 >= len(args) {
				usage()
				os.exit(1)
			}
			index += 1
			append(&fileins, args[index])
		case "--actor":
			if index + 1 >= len(args) {
				usage()
				os.exit(1)
			}
			index += 1
			actor = args[index]
		case "--help", "-h":
			usage()
			return
		case:
			fmt.eprintf("webhost: unknown argument %s\n", args[index])
			usage()
			os.exit(1)
		}
	}

	kernel: k.Kernel
	k.kernel_init(&kernel)
	defer k.kernel_destroy(&kernel)

	host: Webhost
	if ok, message := web.routes_init(&host.routes, sync_client); !ok {
		fmt.eprintf("webhost: %s\n", message)
		os.exit(1)
	}
	defer web.routes_destroy(&host.routes)

	world: ^r.World
	if len(fileins) > 0 {
		started_world, result := r.world_start(
			&kernel,
			fileins[:],
			context.allocator,
			r.World_Config{actor = actor, workers = DEFAULT_WORKERS},
		)
		if !result.ok {
			fmt.eprintf("webhost: cannot load world: %s\n", result.message)
			os.exit(1)
		}
		world = started_world

		entry := r.world_wait(world, world.entry)
		if entry.kind != .Complete {
			fmt.eprintf("webhost: world entry task did not finish: %s\n", entry.message)
			os.exit(1)
		}
		web.documents_init(&host.documents, world)
		web.sync_host_init(&host.sync, world)
	}
	// Runs at process exit, not at the end of the block above.
	defer r.world_destroy(world)

	server: web.Web_Server
	if ok, message := web.web_server_init(&server, bind, webhost_handle, &host); !ok {
		fmt.eprintf("webhost: %s: %s\n", bind, message)
		os.exit(1)
	}
	web.web_server_set_stream_handler(&server, webhost_stream)

	if endpoint, endpoint_ok := web.web_server_endpoint(&server); endpoint_ok {
		fmt.printf("listening on http://%s/\n", net.endpoint_to_string(endpoint))
	} else {
		fmt.printf("listening on %s\n", bind)
	}
	web.web_server_run(&server)
}

@(private)
usage :: proc() {
	fmt.eprintln(
		"usage: webhost [--bind address:port] [--filein path]... " +
		"[--sync-client path.js] [--actor name]",
	)
}
