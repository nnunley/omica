// Tests for the editor host bridge's request parsing.
//
// Query parsing, bounded viewport admission, and actor-bound editor sessions.
package web

import "core:testing"

@(test)
test_editor_query_decodes_percent_escapes :: proc(t: ^testing.T) {
	target := "/editor/input?session=editor%2Fdefault&frame=1&lines=200&max=262144"
	testing.expect_value(t, editor_query(target, "session", ""), "editor/default")
	testing.expect_value(t, editor_query(target, "frame", "1"), "1")
	testing.expect_value(t, editor_query(target, "missing", "fallback"), "fallback")
}

@(test)
test_editor_query_decodes_plus_and_hex_case :: proc(t: ^testing.T) {
	testing.expect_value(t, editor_query("/x?a=one+two", "a", ""), "one two")
	testing.expect_value(t, editor_query("/x?a=%41%62", "a", ""), "Ab")
	// A malformed escape is kept literally rather than dropping the value.
	testing.expect_value(t, editor_query("/x?a=bad%zz", "a", ""), "bad%zz")
}

@(test)
test_editor_query_without_a_query_returns_default :: proc(t: ^testing.T) {
	testing.expect_value(t, editor_query("/editor/snapshot", "session", "editor/default"), "editor/default")
}

@(test)
test_editor_query_bounds_viewport_values :: proc(t: ^testing.T) {
	testing.expect_value(t, editor_query_bounded("/x?lines=999999", "lines", 200, 1, 1000), i64(1000))
	testing.expect_value(t, editor_query_bounded("/x?lines=0", "lines", 200, 1, 1000), i64(1))
	testing.expect_value(t, editor_query_bounded("/x?lines=no", "lines", 200, 1, 1000), i64(200))
	id, ok := editor_query_u64("/x?session=42", "session")
	testing.expect(t, ok)
	testing.expect_value(t, id, u64(42))
	_, invalid := editor_query_u64("/x?session=editor%2Fdefault", "session")
	testing.expect(t, !invalid)
}

@(test)
test_editor_session_is_bound_to_its_actor :: proc(t: ^testing.T) {
	editor: Editor
	editor_init(&editor, nil)
	defer editor_destroy(&editor)
	alice := editor_int(11)
	bob := editor_int(12)
	session := editor_ensure_session(&editor, 7, alice)
	testing.expect(t, session != nil)
	testing.expect(t, editor_ensure_session(&editor, 7, alice) == session)
	testing.expect(t, editor_ensure_session(&editor, 7, bob) == nil)
}

@(test)
test_editor_batch_is_admitted_atomically :: proc(t: ^testing.T) {
	editor: Editor
	editor_init(&editor, nil)
	defer editor_destroy(&editor)
	request := Http_Request {
		method = "POST",
		target = "/editor/input",
		body   = string_bytes(
			"{\"type\":\"editor_input\",\"session\":\"41\",\"items\":[" +
			"{\"sequence\":\"1\",\"depends_on\":\"0\",\"frame\":\"1\",\"kind\":\"text\",\"text\":\"a\"}," +
			"{\"sequence\":\"2\",\"depends_on\":\"1\",\"frame\":\"1\",\"kind\":\"text\",\"text\":\"b\"}]}",
		),
	}
	response: Http_Response
	actor := editor_int(11)
	editor_handle_input_batch(&editor, actor, &request, &response)
	testing.expect_value(t, response.status, 202)
	session := editor_ensure_session(&editor, 41, actor)
	testing.expect_value(t, len(session.inputs), 2)
	testing.expect_value(t, session.next_admitted, u64(3))
	testing.expect_value(t, session.inputs[0].sequence, u64(1))
	testing.expect_value(t, session.inputs[1].sequence, u64(2))

	bad_request := request
	bad_request.body = string_bytes(
		"{\"session\":\"41\",\"items\":[" +
		"{\"sequence\":\"3\",\"depends_on\":\"1\",\"kind\":\"text\",\"text\":\"x\"}]}",
	)
	bad_response: Http_Response
	editor_handle_input_batch(&editor, actor, &bad_request, &bad_response)
	testing.expect_value(t, bad_response.status, 400)
	testing.expect_value(t, len(session.inputs), 2)
}
