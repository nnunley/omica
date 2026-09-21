package web

import "base:runtime"
import "core:os"
import "core:strings"
import "core:sync"
import "core:testing"
import k "../../mica/kernel"
import r "../../mica/runtime"
import v "../../mica/var"

@(test)
test_auth_password_and_session :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	auth: Auth
	auth_init(&auth, context.temp_allocator)
	defer auth_destroy(&auth)

	actor, _ := v.value_identity_raw(0x2001)
	testing.expect(t, auth_seed_user(&auth, "alice", "alice-pass", actor))

	resolved, ok := auth_verify_user(&auth, "alice", "alice-pass")
	testing.expect(t, ok)
	testing.expect_value(t, resolved, actor)
	_, bad := auth_verify_user(&auth, "alice", "nope")
	testing.expect(t, !bad)
	_, missing := auth_verify_user(&auth, "bob", "alice-pass")
	testing.expect(t, !missing)

	token := auth_create_session(&auth, actor)
	from_token, session_ok := auth_actor(&auth, token)
	testing.expect(t, session_ok)
	testing.expect_value(t, from_token, actor)
	_, unknown := auth_actor(&auth, "deadbeef")
	testing.expect(t, !unknown)
}

@(test)
test_auth_form_decode :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	fields := auth_parse_form(as_bytes("login=alice&password=a%2Fb+c&return=%2Fmud"))
	testing.expect_value(t, auth_form_value(fields, "login"), "alice")
	testing.expect_value(t, auth_form_value(fields, "password"), "a/b c")
	testing.expect_value(t, auth_form_value(fields, "return"), "/mud")
}

// A login redirect target must be a local path with no control characters:
// embedded CRLF would split the response and // would redirect off-site.
@(test)
test_auth_login_return_path_sanitized :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	testing.expect_value(t, auth_safe_return_path("/mud"), "/mud")
	testing.expect_value(t, auth_safe_return_path("/deep/path?a=1"), "/deep/path?a=1")
	testing.expect_value(t, auth_safe_return_path(""), "/mud")
	testing.expect_value(t, auth_safe_return_path("relative"), "/mud")
	testing.expect_value(t, auth_safe_return_path("//evil.com"), "/mud")
	testing.expect_value(t, auth_safe_return_path("/\\evil.com"), "/mud")
	testing.expect_value(t, auth_safe_return_path("/x\r\nSet-Cookie: evil=1"), "/mud")

	auth: Auth
	auth_init(&auth, context.temp_allocator)
	defer auth_destroy(&auth)
	actor, _ := v.value_identity_raw(0x2003)
	testing.expect(t, auth_seed_user(&auth, "carol", "carol-pass", actor))

	request := Http_Request {
		method = "POST",
		target = "/auth/login",
	}
	request.body = as_bytes("login=carol&password=carol-pass&return=%2Fok%0D%0AX-Evil%3A%201")
	response: Http_Response
	testing.expect(t, auth_handle(&auth, &request, &response))
	testing.expect_value(t, response.status, 303)
	location := ""
	for header in response.headers {
		if header.name == "Location" {
			location = header.value
		}
	}
	testing.expect_value(t, location, "/mud")
}

@(test)
test_auth_login_request :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	auth: Auth
	auth_init(&auth, context.temp_allocator)
	defer auth_destroy(&auth)

	actor, _ := v.value_identity_raw(0x2002)
	testing.expect(t, auth_seed_user(&auth, "bob", "bob-pass", actor))

	request := Http_Request {
		method = "POST",
		target = "/auth/login",
	}
	request.body = as_bytes("login=bob&password=bob-pass&return=%2Fmud")
	response: Http_Response
	handled := auth_handle(&auth, &request, &response)
	testing.expect(t, handled)
	testing.expect_value(t, response.status, 303)
	testing.expect_value(t, len(response.headers), 2)

	cookie := ""
	for header in response.headers {
		if header.name == "Set-Cookie" {
			cookie = header.value
		}
	}
	testing.expectf(t, strings.contains(cookie, AUTH_COOKIE), "cookie: %q", cookie)
	token := strings.split(cookie, "=", context.temp_allocator)[1]
	token = strings.split(token, ";", context.temp_allocator)[0]
	session_actor, has_actor := auth_actor(&auth, token)
	testing.expect(t, has_actor)
	testing.expect_value(t, session_actor, actor)

	bad_request := Http_Request {
		method = "POST",
		target = "/auth/login",
	}
	bad_request.body = as_bytes("login=bob&password=wrong")
	bad_response: Http_Response
	testing.expect(t, auth_handle(&auth, &bad_request, &bad_response))
	testing.expect_value(t, bad_response.status, 401)

	get_request := Http_Request {
		method = "GET",
		target = "/auth/login",
	}
	get_response: Http_Response
	testing.expect(t, !auth_handle(&auth, &get_request, &get_response))
	_ = get_response
}

// Logout must revoke the token server-side. Regression (SEC3): the handler
// only cleared the browser cookie, so a copied token stayed valid.
// Re-seeding a login replaces the previous credentials (and frees them).
@(test)
test_auth_seed_user_reseeds :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	auth: Auth
	auth_init(&auth, context.temp_allocator)
	defer auth_destroy(&auth)
	first, _ := v.value_identity_raw(0x2005)
	second, _ := v.value_identity_raw(0x2006)
	testing.expect(t, auth_seed_user(&auth, "frank", "first-pass", first))
	testing.expect(t, auth_seed_user(&auth, "frank", "second-pass", second))

	resolved, ok := auth_verify_user(&auth, "frank", "second-pass")
	testing.expect(t, ok)
	testing.expect_value(t, resolved, second)
	_, old_ok := auth_verify_user(&auth, "frank", "first-pass")
	testing.expect(t, !old_ok)
}

@(test)
test_auth_logout_revokes_token :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	auth: Auth
	auth_init(&auth, context.temp_allocator)
	defer auth_destroy(&auth)

	actor, _ := v.value_identity_raw(0x2004)
	testing.expect(t, auth_seed_user(&auth, "dave", "dave-pass", actor))

	login := Http_Request{method = "POST", target = "/auth/login"}
	login.body = as_bytes("login=dave&password=dave-pass")
	login_response: Http_Response
	testing.expect(t, auth_handle(&auth, &login, &login_response))
	testing.expect_value(t, login_response.status, 303)

	cookie := ""
	for header in login_response.headers {
		if header.name == "Set-Cookie" {
			cookie = header.value
		}
	}
	token := strings.split(cookie, "=", context.temp_allocator)[1]
	token = strings.split(token, ";", context.temp_allocator)[0]
	resolved, has_actor := auth_actor(&auth, token)
	testing.expect(t, has_actor)
	testing.expect_value(t, resolved, actor)

	logout := Http_Request{method = "POST", target = "/auth/logout"}
	logout.headers = make([]Http_Header, 1, context.temp_allocator)
	logout.headers[0] = Http_Header {
		"Cookie",
		strings.concatenate([]string{AUTH_COOKIE, "=", token}, context.temp_allocator),
	}
	logout_response: Http_Response
	testing.expect(t, auth_handle(&auth, &logout, &logout_response))
	testing.expect_value(t, logout_response.status, 303)

	// The token no longer resolves, and a request presenting it is anonymous.
	_, still := auth_actor(&auth, token)
	testing.expect(t, !still)
	testing.expect(t, auth_actor_for_request(&auth, &logout) == v.Value(0))
}

@(test)
test_sync_render_uses_session_actor :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	source := `make_identity(:alice)
verb sync_view_tree(view)
  if let some(who) = actor()
    if who == #alice
      return dom <p>signed-in</p>
    end
  end
  return dom <p>guest</p>
end
`
	path, path_ok := write_document_source(t, "mica_sync_actor.mica", source)
	if !path_ok {
		return
	}
	defer os.remove(path)

	kernel: k.Kernel
	k.kernel_init(&kernel)
	defer k.kernel_destroy(&kernel)

	world, start := r.world_start(&kernel, []string{path}, runtime.default_allocator(), r.World_Config{workers = 1})
	testing.expectf(t, start.ok, "world start failed: %s", start.message)
	if !start.ok {
		return
	}
	defer r.world_destroy(world)
	entry := r.world_wait(world, world.entry)
	testing.expect_value(t, entry.kind, r.Task_Outcome_Kind.Complete)

	host: Sync_Host
	sync_host_init(&host, world, runtime.default_allocator())
	defer sync_host_destroy(&host)

	alice, found := world.ctx.identities["alice"]
	testing.expect(t, found)

	session := sync_host_ensure_session(&host, 1, alice)
	testing.expect(t, sync_render_view(&host, 1, alice, 1, 0, 0, true))
	payload := session_payload(t, session)
	testing.expectf(t, strings.contains(payload, "signed-in"), "payload: %q", payload)

	// Another actor cannot render Alice's session.
	bob, bob_ok := v.value_identity_raw(0x2002)
	testing.expect(t, bob_ok)
	testing.expect(t, !sync_render_view(&host, 1, bob, 1, 0, 0, true))

	guest_session := sync_host_ensure_session(&host, 2, v.Value(0))
	testing.expect(t, sync_render_view(&host, 2, v.Value(0), 1, 0, 0, true))
	guest_payload := session_payload(t, guest_session)
	testing.expectf(t, strings.contains(guest_payload, "guest"), "payload: %q", guest_payload)
}

// Regression test: a session id is bound to the actor that created it. A
// different authenticated actor presenting the same id must not be able to
// attach to (and rebind) that session.
@(test)
test_sync_session_actor_binding :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)

	host: Sync_Host
	sync_host_init(&host, nil)
	defer sync_host_destroy(&host)

	alice, alice_ok := v.value_identity_raw(0x2001)
	bob, bob_ok := v.value_identity_raw(0x2002)
	testing.expect(t, alice_ok && bob_ok)
	testing.expect(t, alice != bob)

	alice_session := sync_host_ensure_session(&host, 42, alice)
	testing.expect(t, alice_session != nil)
	if alice_session == nil {
		return
	}
	testing.expect(t, alice_session.actor == alice)

	// Bob presents Alice's session id: rejected, not rebound.
	testing.expect(t, sync_host_ensure_session(&host, 42, bob) == nil)

	// The original actor can still reach the same session.
	again := sync_host_ensure_session(&host, 42, alice)
	testing.expect(t, again == alice_session)
	if again != nil {
		testing.expect(t, again.actor == alice)
	}
}

@(private)
session_payload :: proc(t: ^testing.T, session: ^Sync_Session) -> string {
	sync.mutex_lock(&session.lock)
	defer sync.mutex_unlock(&session.lock)
	testing.expect(t, len(session.messages) >= 1)
	if len(session.messages) == 0 {
		return ""
	}
	message := session.messages[len(session.messages) - 1]
	testing.expect_value(t, message.kind, Sync_Output_Kind.Sync)
	return string(message.envelope.payload)
}
