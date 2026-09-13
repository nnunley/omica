// Host-side local password authentication: seeded users, Argon2id password
// hashes, and cookie sessions.
//
// The reference host uses Argon2 and signed session tokens. This port uses
// Argon2id (RFC parameters) and an opaque random token in an in-memory table.
// There is no persistence. User creation is not enabled.
package web

import "core:crypto"
import "core:crypto/argon2id"
import "core:fmt"
import "core:mem"
import "core:strings"
import "core:sync"
import "core:time"
import v "../../mica/var"

AUTH_COOKIE :: "mica_session"
AUTH_SESSION_TTL :: 24 * time.Hour
AUTH_TOKEN_BYTES :: 24

Auth_User :: struct {
	login: string,
	salt:  [argon2id.RECOMMENDED_SALT_SIZE]u8,
	hash:  [argon2id.RECOMMENDED_TAG_SIZE]u8,
	actor: v.Value,
}

Auth_Session :: struct {
	actor:   v.Value,
	expires: time.Tick,
}

Auth :: struct {
	lock:      sync.Mutex,
	users:     map[string]^Auth_User,
	sessions:  map[string]Auth_Session,
	allocator: mem.Allocator,
}

auth_init :: proc(auth: ^Auth, allocator := context.allocator) {
	auth.allocator = allocator
	auth.users = make(map[string]^Auth_User, allocator)
	auth.sessions = make(map[string]Auth_Session, allocator)
}

auth_destroy :: proc(auth: ^Auth) {
	for _, user in auth.users {
		delete(user.login, auth.allocator)
		free(user, auth.allocator)
	}
	delete(auth.users)
	for token in auth.sessions {
		delete(token, auth.allocator)
	}
	delete(auth.sessions)
}

// Registers a seeded user whose login maps to `actor`.
auth_seed_user :: proc(auth: ^Auth, login, password: string, actor: v.Value) -> bool {
	user := new(Auth_User, auth.allocator)
	user.login = strings.clone(login, auth.allocator)
	user.actor = actor
	crypto.rand_bytes(user.salt[:])
	if !auth_hash(user, password) {
		free(user, auth.allocator)
		return false
	}
	sync.mutex_lock(&auth.lock)
	if existing, found := auth.users[user.login]; found {
		// Re-seeding a login replaces it; free the previous user rather than
		// leaking it.
		delete(existing.login, auth.allocator)
		free(existing, auth.allocator)
	}
	auth.users[user.login] = user
	sync.mutex_unlock(&auth.lock)
	return true
}

@(private)
auth_hash :: proc(user: ^Auth_User, password: string) -> bool {
	err := argon2id.derive(
		&argon2id.PARAMS_OWASP_SMALL,
		transmute([]u8)password,
		user.salt[:],
		user.hash[:],
	)
	return err == nil
}

// Dummy credentials used to spend the same KDF work on an unknown login as on
// a known one, so response timing does not reveal whether an account exists.
@(private)
AUTH_DUMMY_SALT: [argon2id.RECOMMENDED_SALT_SIZE]u8

@(private)
AUTH_DUMMY_HASH: [argon2id.RECOMMENDED_TAG_SIZE]u8

auth_verify_user :: proc(auth: ^Auth, login, password: string) -> (v.Value, bool) {
	sync.mutex_lock(&auth.lock)
	user, found := auth.users[login]
	sync.mutex_unlock(&auth.lock)

	// Always derive: returning early for an unknown login leaks account
	// existence through timing.
	salt := AUTH_DUMMY_SALT
	expected := AUTH_DUMMY_HASH
	if found {
		salt = user.salt
		expected = user.hash
	}
	candidate: [argon2id.RECOMMENDED_TAG_SIZE]u8
	err := argon2id.derive(
		&argon2id.PARAMS_OWASP_SMALL,
		transmute([]u8)password,
		salt[:],
		candidate[:],
	)
	if err != nil || !found {
		return v.Value(0), false
	}
	diff: u8
	for index in 0 ..< len(candidate) {
		diff |= candidate[index] ~ expected[index]
	}
	if diff != 0 {
		return v.Value(0), false
	}
	return user.actor, true
}

// Issues a random session token for `actor`.
auth_create_session :: proc(auth: ^Auth, actor: v.Value) -> string {
	raw: [AUTH_TOKEN_BYTES]u8
	crypto.rand_bytes(raw[:])
	builder: strings.Builder
	strings.builder_init(&builder, auth.allocator)
	for byte in raw {
		fmt.sbprintf(&builder, "%02x", byte)
	}
	token := strings.to_string(builder)
	sync.mutex_lock(&auth.lock)
	auth.sessions[token] = Auth_Session {
		actor   = actor,
		expires = time.tick_add(time.tick_now(), AUTH_SESSION_TTL),
	}
	sync.mutex_unlock(&auth.lock)
	return token
}

// Resolves a session token to an actor. Expired sessions are dropped.
auth_actor :: proc(auth: ^Auth, token: string) -> (v.Value, bool) {
	if token == "" {
		return v.Value(0), false
	}
	now := time.tick_now()
	sync.mutex_lock(&auth.lock)
	session, found := auth.sessions[token]
	if found && time.tick_diff(now, session.expires) < 0 {
		delete_key(&auth.sessions, token)
		found = false
	}
	sync.mutex_unlock(&auth.lock)
	if !found {
		return v.Value(0), false
	}
	return session.actor, true
}

// Resolves the session cookie on a request. Returns the zero value for
// unauthenticated requests.
auth_actor_for_request :: proc(auth: ^Auth, request: ^Http_Request) -> v.Value {
	token := auth_request_cookie(request, AUTH_COOKIE)
	actor, _ := auth_actor(auth, token)
	return actor
}

// Returns the session token carried by the request, or "" when absent.
auth_request_token :: proc(request: ^Http_Request) -> string {
	return auth_request_cookie(request, AUTH_COOKIE)
}

// Revokes a session token server-side. Logout must not rely on the browser
// discarding its cookie: a copied token stays valid otherwise.
auth_revoke_session :: proc(auth: ^Auth, token: string) {
	if token == "" {
		return
	}
	sync.mutex_lock(&auth.lock)
	delete_key(&auth.sessions, token)
	sync.mutex_unlock(&auth.lock)
}

@(private)
auth_request_cookie :: proc(request: ^Http_Request, name: string) -> string {
	for header in request.headers {
		if !strings.equal_fold(header.name, "cookie") {
			continue
		}
		remaining := header.value
		for len(remaining) > 0 {
			part := remaining
			if end := strings.index_byte(remaining, ';'); end >= 0 {
				part = remaining[:end]
				remaining = remaining[end + 1:]
			} else {
				remaining = ""
			}
			part = strings.trim_space(part)
			equals := strings.index_byte(part, '=')
			if equals < 0 {
				continue
			}
			if part[:equals] == name {
				return part[equals + 1:]
			}
		}
	}
	return ""
}

// A login redirect target must be a local absolute path with no control
// characters, so it cannot inject response headers or redirect off-site.
@(private)
auth_safe_return_path :: proc(value: string) -> string {
	if value == "" || value[0] != '/' {
		return "/mud"
	}
	if len(value) > 1 && (value[1] == '/' || value[1] == '\\') {
		return "/mud"
	}
	for c in value {
		if c < 0x20 || c == 0x7f {
			return "/mud"
		}
	}
	return value
}

// Handles local auth POSTs: `/auth/login` and `/auth/logout`. Returns false
// for other paths so document routes can serve the login page.
auth_handle :: proc(auth: ^Auth, request: ^Http_Request, response: ^Http_Response) -> bool {
	path := http_request_path(request.target)
	if request.method != "POST" {
		return false
	}
	switch path {
	case "/auth/login":
		form := auth_parse_form(request.body)
		login := auth_form_value(form, "login")
		password := auth_form_value(form, "password")
		return_path := auth_safe_return_path(auth_form_value(form, "return"))
		if login == "" || password == "" {
			http_response_text(response, 400, "text/plain; charset=utf-8", "login and password are required")
			return true
		}
		actor, verified := auth_verify_user(auth, login, password)
		if !verified {
			http_response_text(response, 401, "text/plain; charset=utf-8", "invalid login or password")
			return true
		}
		token := auth_create_session(auth, actor)
		response.status = 303
		response.headers = make([]Http_Header, 2, context.temp_allocator)
		response.headers[0] = Http_Header{"Location", return_path}
		response.headers[1] = Http_Header {
			"Set-Cookie",
			fmt.aprintf(
				"%s=%s; Path=/; HttpOnly; SameSite=Lax",
				AUTH_COOKIE,
				token,
				allocator = context.temp_allocator,
			),
		}
		return true
	case "/auth/create":
		http_response_text(
			response,
			400,
			"text/plain; charset=utf-8",
			"user creation is not enabled in this port",
		)
		return true
	case "/auth/logout":
		// End the session server-side as well; the browser discarding its
		// cookie does not invalidate a token someone else may hold.
		auth_revoke_session(auth, auth_request_cookie(request, AUTH_COOKIE))
		response.status = 303
		response.headers = make([]Http_Header, 2, context.temp_allocator)
		response.headers[0] = Http_Header{"Location", "/mud"}
		response.headers[1] = Http_Header {
			"Set-Cookie",
			fmt.aprintf(
				"%s=; Path=/; HttpOnly; SameSite=Lax; Max-Age=0",
				AUTH_COOKIE,
				allocator = context.temp_allocator,
			),
		}
		return true
	}
	return false
}

@(private)
auth_parse_form :: proc(body: []u8) -> []Form_Field {
	fields: [dynamic]Form_Field
	fields = make([dynamic]Form_Field, context.temp_allocator)
	remaining := string(body)
	for len(remaining) > 0 {
		part := remaining
		if end := strings.index_byte(remaining, '&'); end >= 0 {
			part = remaining[:end]
			remaining = remaining[end + 1:]
		} else {
			remaining = ""
		}
		equals := strings.index_byte(part, '=')
		if equals < 0 {
			continue
		}
		append(&fields, Form_Field {
			name  = auth_url_decode(part[:equals]),
			value = auth_url_decode(part[equals + 1:]),
		})
	}
	return fields[:]
}

Form_Field :: struct {
	name:  string,
	value: string,
}

@(private)
auth_form_value :: proc(fields: []Form_Field, name: string) -> string {
	for field in fields {
		if field.name == name {
			return field.value
		}
	}
	return ""
}

@(private)
auth_url_decode :: proc(text: string) -> string {
	if !strings.contains_any(text, "%+") {
		return text
	}
	builder: strings.Builder
	strings.builder_init(&builder, context.temp_allocator)
	index := 0
	for index < len(text) {
		c := text[index]
		switch c {
		case '+':
			strings.write_byte(&builder, ' ')
			index += 1
		case '%':
			if index + 2 >= len(text) {
				strings.write_byte(&builder, c)
				index += 1
				continue
			}
			high := auth_hex_value(text[index + 1])
			low := auth_hex_value(text[index + 2])
			if high < 0 || low < 0 {
				strings.write_byte(&builder, c)
				index += 1
				continue
			}
			strings.write_byte(&builder, u8(high << 4 | low))
			index += 3
		case:
			strings.write_byte(&builder, c)
			index += 1
		}
	}
	return strings.to_string(builder)
}

@(private)
auth_hex_value :: proc(c: u8) -> int {
	switch c {
	case '0' ..= '9':
		return int(c - '0')
	case 'a' ..= 'f':
		return int(c - 'a') + 10
	case 'A' ..= 'F':
		return int(c - 'A') + 10
	}
	return -1
}
