package web

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

	world, start := r.world_start(&kernel, []string{path}, context.temp_allocator)
	testing.expectf(t, start.ok, "world start failed: %s", start.message)
	if !start.ok {
		return
	}
	defer r.world_destroy(world)
	entry := r.world_wait(world, world.entry)
	testing.expect_value(t, entry.kind, r.Task_Outcome_Kind.Complete)

	host: Sync_Host
	sync_host_init(&host, world)
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
	return string(session.messages[len(session.messages) - 1].payload)
}
