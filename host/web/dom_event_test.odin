package web

import "core:testing"
import r "../../mica/runtime"
import v "../../mica/var"

@(test)
test_dom_event_decode :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	body := `{"type":"dom_event","session":"9","view":"21","revision":"1","signature":"12531108388691183","refresh":true,"event":"submit","target":"exit-north","action":"mud_command","fields":{"text":"north"}}`
	value, message, decoded := r.json_decode_text(context.temp_allocator, body)
	testing.expectf(t, decoded, "json: %s", message)
	entries, is_map := v.value_as_map(value)
	testing.expect(t, is_map)
	type_value, has_type := dom_event_get(entries, "type")
	type_text, is_text := v.value_as_string(type_value)
	testing.expect(t, has_type && is_text && type_text == "dom_event")
	event, parsed := dom_event_decode(as_bytes(body), context.temp_allocator)
	testing.expect(t, parsed)
	testing.expect_value(t, event.session_id, u64(9))
	testing.expect_value(t, event.view_id, u64(21))
	testing.expect_value(t, event.revision, u64(1))
	testing.expect_value(t, event.signature, u64(12531108388691183))
	testing.expect_value(t, event.event, "submit")
	testing.expect_value(t, event.target, "exit-north")
	testing.expect_value(t, event.action, "mud_command")
	testing.expect_value(t, len(event.fields), 1)
	if len(event.fields) == 1 {
		testing.expect_value(t, event.fields[0].name, "text")
		testing.expect_value(t, event.fields[0].value, "north")
	}
}
