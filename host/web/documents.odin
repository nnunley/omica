// Document routes: dispatch the world's `http_request` verb and decode its
// response.
//
// The connection thread builds the request facts, submits a task with them,
// waits for the outcome, and decodes the response. Task work stays on the
// scheduler; the connection thread never touches a transaction.
package web

import "core:fmt"
import "core:strings"
import "core:sync"
import k "../../mica/kernel"
import r "../../mica/runtime"
import v "../../mica/var"

// Host request identities start high so they cannot collide with identities a
// world declares.
DOCUMENT_IDENTITY_BASE :: u64(0x0080_0000_0000_0000)

Documents :: struct {
	world:           ^r.World,
	kernel:          ^k.Kernel,
	next_request_id: u64,
}

documents_init :: proc(documents: ^Documents, world: ^r.World) {
	documents.world = world
	documents.kernel = world.kernel
	documents.next_request_id = DOCUMENT_IDENTITY_BASE
}

documents_handle :: proc(user: rawptr, request: ^Http_Request, response: ^Http_Response) {
	documents_handle_actor(user, v.Value(0), request, response)
}

// Handles a document route as `actor`. A zero actor uses the world defaults.
documents_handle_actor :: proc(
	user: rawptr,
	actor: v.Value,
	request: ^Http_Request,
	response: ^Http_Response,
) {
	documents := (^Documents)(user)
	if documents.world == nil {
		http_response_text(response, 500, "text/plain; charset=utf-8", "no world loaded")
		return
	}
	request_value, facts, built, message := documents_build_request(documents, actor, request)
	if !built {
		http_response_text(response, 500, "text/plain; charset=utf-8", message)
		return
	}
	defer delete(facts)

	roles := []k.Role_Pair {
		{role = v.value_symbol(v.symbol_intern("request")), value = request_value},
	}
	result := r.world_submit_call_with_options(
		documents.world,
		"http_request",
		roles,
		facts[:],
		0,
		r.World_Call_Options{actor = actor},
	)
	if result.id == 0 {
		http_response_text(response, 500, "text/plain; charset=utf-8", dispatch_failure(result))
		return
	}
	outcome := r.world_wait(documents.world, result.id)
	r.world_release(documents.world, result.id)
	if outcome.kind != .Complete {
		text := outcome.message
		if text == "" {
			text = "request failed"
		}
		http_response_text(response, 500, "text/plain; charset=utf-8", text)
		return
	}
	decoded, decode_message := web_decode_response(outcome.value, response)
	if !decoded {
		http_response_text(response, 500, "text/plain; charset=utf-8", decode_message)
	}
}

@(private)
documents_build_request :: proc(
	documents: ^Documents,
	actor: v.Value,
	request: ^Http_Request,
) -> (
	v.Value,
	[dynamic]r.World_Fact,
	bool,
	string,
) {
	allocator := context.temp_allocator
	raw := sync.atomic_add(&documents.next_request_id, 1)
	if raw > v.IDENTITY_MAX {
		return v.Value(0), nil, false, "request identity space is exhausted"
	}
	request_value, identity_ok := v.value_identity_raw(raw)
	if !identity_ok {
		return v.Value(0), nil, false, "request identity is out of range"
	}

	snapshot := k.kernel_snapshot(documents.kernel)
	defer k.snapshot_release(snapshot)

	http_request_rel, has_http_request := document_relation(snapshot, "HttpRequest")
	method_rel, has_method := document_relation(snapshot, "RequestMethod")
	path_rel, has_path := document_relation(snapshot, "RequestPath")
	if !has_http_request || !has_method || !has_path {
		return v.Value(0), nil, false, "world does not declare HttpRequest, RequestMethod, and RequestPath"
	}

	facts: [dynamic]r.World_Fact
	append(&facts, r.World_Fact {
		relation = http_request_rel,
		tuple    = v.tuple_new(allocator, []v.Value{request_value}),
	})
	append(&facts, r.World_Fact {
		relation = method_rel,
		tuple    = v.tuple_new(allocator, []v.Value {
			request_value,
			v.value_string(allocator, request.method),
		}),
	})
	append(&facts, r.World_Fact {
		relation = path_rel,
		tuple    = v.tuple_new(allocator, []v.Value {
			request_value,
			v.value_string(allocator, request.target),
		}),
	})

	if version_rel, has_version := document_relation(snapshot, "RequestVersion"); has_version {
		version := i64(0)
		if request.version == "HTTP/1.1" {
			version = 1
		}
		version_value, _ := v.value_int(version)
		append(&facts, r.World_Fact {
			relation = version_rel,
			tuple    = v.tuple_new(allocator, []v.Value{request_value, version_value}),
		})
	}
	principal := actor
	if v.value_is_empty_relation(principal) {
		principal = r.world_principal(documents.world)
	}
	if principal_rel, has_principal := document_relation(snapshot, "RequestPrincipal"); has_principal {
		if !v.value_is_empty_relation(principal) {
			append(&facts, r.World_Fact {
				relation = principal_rel,
				tuple    = v.tuple_new(allocator, []v.Value{request_value, principal}),
			})
		}
	}
	if actor_rel, has_actor := document_relation(snapshot, "RequestActor"); has_actor {
		if !v.value_is_empty_relation(actor) {
			append(&facts, r.World_Fact {
				relation = actor_rel,
				tuple    = v.tuple_new(allocator, []v.Value{request_value, actor}),
			})
		}
	}
	if header_rel, has_header := document_relation(snapshot, "RequestHeader"); has_header {
		for header in request.headers {
			name, _ := strings.to_lower(header.name, allocator)
			append(&facts, r.World_Fact {
				relation = header_rel,
				tuple    = v.tuple_new(allocator, []v.Value {
					request_value,
					v.value_string(allocator, name),
					v.value_bytes(allocator, transmute([]byte)header.value),
				}),
			})
		}
	}
	if body_rel, has_body := document_relation(snapshot, "RequestBody"); has_body && len(request.body) > 0 {
		append(&facts, r.World_Fact {
			relation = body_rel,
			tuple    = v.tuple_new(allocator, []v.Value {
				request_value,
				v.value_bytes(allocator, request.body),
			}),
		})
	}
	return request_value, facts, true, ""
}

@(private)
document_relation :: proc(snapshot: ^k.Snapshot, name: string) -> (k.Relation_ID, bool) {
	metadata, found := k.snapshot_relation_metadata_named(snapshot, v.symbol_intern(name))
	return metadata.id, found
}

@(private)
dispatch_failure :: proc(result: r.Dispatch_Result) -> string {
	switch result.error {
	case .No_Method:
		return "no applicable http_request method"
	case .No_Program:
		return "http_request method has no program"
	case .Arguments:
		return "http_request parameters cannot bind"
	case .Fact:
		return fmt.tprintf("cannot prepare request facts: %v", result.kernel)
	case .None:
	}
	return "request submission failed"
}
