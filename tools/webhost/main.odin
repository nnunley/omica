// Serves Mica worlds over HTTP/1.1 and SSE.
//
// M1: health check, the sync client script, and document routes that dispatch
// the world's `http_request` verb. Sync sessions arrive in a later milestone.
//
// Usage:
//
//	odin run tools/webhost -- --filein apps/... --bind 127.0.0.1:8080
package main

import "core:c/libc"
import "core:fmt"
import "core:net"
import "core:os"
import "core:sync"
import "core:thread"
import "core:time"

import sourcelib "../../host/source"
import web "../../host/web"
import ext "../../mica/external"
import k "../../mica/kernel"
import r "../../mica/runtime"
import s "../../mica/store"
import v "../../mica/var"

DEFAULT_BIND :: "127.0.0.1:8080"
DEFAULT_WORKERS :: 4

main :: proc() {
	bind := DEFAULT_BIND
	sync_client := ""
	editor_client := ""
	actor := ""
	store_path := ""
	durability_text := "group"
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
		case "--editor-client":
			if index + 1 >= len(args) {
				usage()
				os.exit(1)
			}
			index += 1
			editor_client = args[index]
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
		case "--store":
			if index + 1 >= len(args) {
				usage()
				os.exit(1)
			}
			index += 1
			store_path = args[index]
		case "--durability":
			if index + 1 >= len(args) {
				usage()
				os.exit(1)
			}
			index += 1
			durability_text = args[index]
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
	web.auth_init(&host.auth, context.allocator)
	defer web.auth_destroy(&host.auth)
	if ok, message := web.routes_init(&host.routes, sync_client, editor_client); !ok {
		fmt.eprintf("webhost: %s\n", message)
		os.exit(1)
	}
	defer web.routes_destroy(&host.routes)

	world: ^r.World
	if len(fileins) > 0 || store_path != "" {
		started_world, result := r.world_start(
			&kernel,
			fileins[:],
			context.allocator,
			r.World_Config {
				actor            = actor,
				workers          = DEFAULT_WORKERS,
				store_path       = store_path,
				durability       = parse_durability(durability_text),
				external_handler = ext.handle_request,
				external_workers = 2,
			},
		)
		if !result.ok {
			fmt.eprintf("webhost: cannot load world: %s\n", result.message)
			os.exit(1)
		}
		world = started_world

		if world.entry != 0 {
			entry := r.world_wait(world, world.entry)
			if entry.kind != .Complete {
				fmt.eprintf("webhost: world entry task did not finish: %s\n", entry.message)
				os.exit(1)
			}
		}
		// A world that declares the source schema gets a local index of
		// MICA_SOURCE_ROOTS, so the agent's file tools have data.
		if indexed, attempted := sourcelib.index_from_env(world); attempted {
			if indexed.ok {
				fmt.printf(
					"indexed %d files (%d directories, %d skipped)\n",
					indexed.files,
					indexed.directories,
					indexed.skipped,
				)
			} else {
				fmt.eprintf("source index skipped: %s\n", indexed.message)
			}
		}
		web.documents_init(&host.documents, world)
		web.sync_host_init(&host.sync, world)
		web.editor_init(&host.editor, world, &host.sync)
		webhost_configure_auth(world, true, false)
		webhost_seed_person(world, "alice", "Alice")
		webhost_seed_person(world, "bob", "Bob")
		if actor, found := world.ctx.identities["alice"]; found {
			_ = web.auth_seed_user(&host.auth, "alice", "alice-pass", actor)
		}
		if actor, found := world.ctx.identities["bob"]; found {
			_ = web.auth_seed_user(&host.auth, "bob", "bob-pass", actor)
		}
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
	// A clean SIGINT/SIGTERM runs the deferred world_destroy, which
	// checkpoints the store and releases its lock.
	libc.signal(libc.SIGINT, webhost_signal_handler)
	libc.signal(libc.SIGTERM, webhost_signal_handler)
	watcher := thread.create_and_start_with_data(&server, webhost_shutdown_watcher)
	web.web_server_run(&server)
	if watcher != nil {
		thread.join(watcher)
		thread.destroy(watcher)
	}
	// The run loop has returned, so no accept is in flight and the listener
	// fd can be closed without risking reuse by another socket.
	web.web_server_destroy(&server)
	// The acceptor and every connection thread are stopped. Retire the sync
	// pump before the deferred world_destroy tears down the runtime it reads.
	if world != nil {
		web.editor_destroy(&host.editor)
		web.sync_host_destroy(&host.sync)
	}
}

// Publishes the mud RuntimeConfig sign-in flags when the world declares the
// schema. Local password auth is enabled; GitHub OAuth is not implemented.
@(private)
webhost_configure_auth :: proc(world: ^r.World, local_enabled, github_enabled: bool) {
	config_relation, has_relation := world.ctx.relations["mud/RuntimeConfig"]
	local_identity, has_local := world.ctx.identities["mud/config_local_password_auth"]
	github_identity, has_github := world.ctx.identities["mud/config_github_auth"]
	if !has_relation || !has_local || !has_github {
		return
	}
	facts := []r.World_Fact {
		{
			relation = k.Relation_ID(config_relation),
			tuple    = v.tuple_new(
				context.temp_allocator,
				[]v.Value{local_identity, v.value_bool(local_enabled)},
			),
		},
		{
			relation = k.Relation_ID(config_relation),
			tuple    = v.tuple_new(
				context.temp_allocator,
				[]v.Value{github_identity, v.value_bool(github_enabled)},
			),
		},
	}
	_ = r.world_apply_facts(world, facts)
}

// Asserts the person facts a seeded user needs to act as a player. The
// reference auth store writes these when it ensures a user person.
@(private)
webhost_seed_person :: proc(world: ^r.World, login, display_name: string) {
	person_relation, has_person := world.ctx.relations["mud/Person"]
	person, has_person_identity := world.ctx.identities[login]
	if !has_person || !has_person_identity {
		return
	}
	facts: [dynamic]r.World_Fact
	facts = make([dynamic]r.World_Fact, context.temp_allocator)
	append(&facts, r.World_Fact {
		relation = k.Relation_ID(person_relation),
		tuple    = v.tuple_new(context.temp_allocator, []v.Value{person}),
	})
	if display_relation, has_display := world.ctx.relations["mud/DisplayName"]; has_display {
		append(&facts, r.World_Fact {
			relation = k.Relation_ID(display_relation),
			tuple    = v.tuple_new(context.temp_allocator, []v.Value {
				person,
				v.value_string(context.temp_allocator, display_name),
			}),
		})
	}
	if description_relation, has_description := world.ctx.relations["mud/Description"]; has_description {
		append(&facts, r.World_Fact {
			relation = k.Relation_ID(description_relation),
			tuple    = v.tuple_new(context.temp_allocator, []v.Value {
				person,
				v.value_string(
					context.temp_allocator,
					fmt.aprintf(
						"%s, present through local login.",
						display_name,
						allocator = context.temp_allocator,
					),
				),
			}),
		})
	}
	_ = r.world_apply_facts(world, facts[:])
}

@(private)
shutdown_requested: i32

@(private)
webhost_signal_handler :: proc "c" (signal: i32) {
	sync.atomic_store(&shutdown_requested, 1)
}

@(private)
webhost_shutdown_watcher :: proc(data: rawptr) {
	server := (^web.Web_Server)(data)
	for sync.atomic_load(&shutdown_requested) == 0 {
		time.sleep(20 * time.Millisecond)
	}
	web.web_server_stop(server)
}

@(private)
parse_durability :: proc(text: string) -> s.Durability {
	switch text {
	case "none":
		return .None
	case "strict":
		return .Strict
	}
	return .Group
}

usage :: proc() {
	fmt.eprintln(
		"usage: webhost [--bind address:port] [--filein path]... " +
		"[--sync-client path.js] [--editor-client path.js] [--actor name] " +
		"[--store dir] [--durability none|group|strict]",
	)
}
