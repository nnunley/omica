// DOM event payloads sent by the client to `/sync/input`.
//
// Shape (JSON): {"type":"dom_event","session":N,"view":N,"revision":N,
// "signature":N,"refresh":bool,"event":"...","target":"...","action":"...",
// "fields":{"name":"value",...}}
package web

import "core:mem"
import r "../../mica/runtime"
import v "../../mica/var"

DOM_EVENT_TYPE :: "dom_event"

Dom_Event :: struct {
	session_id: u64,
	view_id:    u64,
	revision:   u64,
	signature:  u64,
	refresh:    bool,
	event:      string,
	target:     string,
	action:     string,
	fields:     []Dom_Event_Field,
}

Dom_Event_Field :: struct {
	name:  string,
	value: string,
}

dom_event_decode :: proc(body: []u8, allocator: mem.Allocator) -> (Dom_Event, bool) {
	value, _, decoded := r.json_decode_text(allocator, string(body))
	if !decoded {
		return {}, false
	}
	entries, is_map := v.value_as_map(value)
	if !is_map {
		return {}, false
	}
	type_value, has_type := dom_event_get(entries, "type")
	type_text, is_text := v.value_as_string(type_value)
	if !has_type || !is_text || type_text != DOM_EVENT_TYPE {
		return {}, false
	}
	session_id, has_session := dom_event_u64(entries, "session")
	view_id, has_view := dom_event_u64(entries, "view")
	revision, has_revision := dom_event_u64(entries, "revision")
	signature, has_signature := dom_event_u64(entries, "signature")
	event_text, has_event := dom_event_string(entries, "event")
	target_text, has_target := dom_event_string(entries, "target")
	if !has_session || !has_view || !has_revision || !has_signature ||
	   !has_event || !has_target {
		return {}, false
	}
	action_text, _ := dom_event_string(entries, "action")
	refresh := true
	if refresh_value, has_refresh := dom_event_get(entries, "refresh"); has_refresh {
		if boolean, is_bool := v.value_as_bool(refresh_value); is_bool {
			refresh = boolean
		}
	}
	fields: [dynamic]Dom_Event_Field
	fields = make([dynamic]Dom_Event_Field, allocator)
	if fields_value, has_fields := dom_event_get(entries, "fields"); has_fields {
		field_entries, is_fields := v.value_as_map(fields_value)
		if !is_fields {
			return {}, false
		}
		for entry in field_entries {
			name: string
			if text, is_text := v.value_as_string(entry.key); is_text {
				name = text
			} else if symbol, is_symbol := v.value_as_symbol(entry.key); is_symbol {
				symbol_name, has_name := v.symbol_name(symbol)
				if !has_name {
					return {}, false
				}
				name = symbol_name
			} else {
				return {}, false
			}
			field_value, value_ok := v.value_as_string(entry.value)
			if !value_ok {
				return {}, false
			}
			append(&fields, Dom_Event_Field{name = name, value = field_value})
		}
	}
	return Dom_Event {
		session_id = session_id,
		view_id    = view_id,
		revision   = revision,
		signature  = signature,
		refresh    = refresh,
		event      = event_text,
		target     = target_text,
		action     = action_text,
		fields     = fields[:],
	}, true
}

// The runtime JSON decoder stores object keys as symbols. Accept string keys
// too, which is how Rust's serde maps behave.
@(private)
dom_event_get :: proc(entries: []v.Map_Entry, key: string) -> (v.Value, bool) {
	symbol_key := v.value_symbol(v.symbol_intern(key))
	string_key := v.value_string(context.temp_allocator, key)
	for entry in entries {
		if v.value_eq(entry.key, symbol_key) || v.value_eq(entry.key, string_key) {
			return entry.value, true
		}
	}
	return v.Value(0), false
}

@(private)
dom_event_u64 :: proc(entries: []v.Map_Entry, key: string) -> (u64, bool) {
	value, found := dom_event_get(entries, key)
	if !found {
		return 0, false
	}
	integer, is_int := v.value_as_int(value)
	if !is_int || integer < 0 {
		return 0, false
	}
	return u64(integer), true
}

@(private)
dom_event_string :: proc(entries: []v.Map_Entry, key: string) -> (string, bool) {
	value, found := dom_event_get(entries, key)
	if !found {
		return "", false
	}
	return v.value_as_string(value)
}
