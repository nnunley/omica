// Host builtin library: the low-level verbs fileins call by name.
//
// The scalar string surface mirrors the Rust runtime's `builtins/scalar.rs`;
// strings are indexed by Unicode scalar position, not bytes.
package mica_runtime

import "core:fmt"
import "core:mem"
import "core:os"
import "core:slice"
import "core:strconv"
import "core:strings"
import "core:time"
import "core:unicode/utf8"
import c "../compiler"
import k "../kernel"
import dom "../dom"
import vm "../vm"
import v "../var"

@(private)
Builtin_Spec :: struct {
	name: string,
	argc: int,
	run:  vm.Builtin_Proc,
}

// A negative arity is variadic: the VM reads the argument count from the
// calling instruction.
@(private)
runtime_builtins := [?]Builtin_Spec {
	{"make_identity", 1, builtin_make_identity},
	{"destroy_identity", 1, builtin_destroy_identity},
	{"make_relation", 2, builtin_relation},
	{"make_functional_relation", 3, builtin_relation},
	{"__set_field", 3, builtin_set_field},
	{"__get_field", 2, builtin_get_field},
	{"emit", 2, builtin_noop},
	{"require", 1, builtin_require},
	{"frob", 2, builtin_frob},
	{"frob_delegate", 1, builtin_frob_delegate},
	{"frob_value", 1, builtin_frob_value},
	{"is_frob", 1, builtin_is_frob},
	{"string_len", 1, builtin_string_len},
	{"string_chars", 1, builtin_string_chars},
	{"string_slice", 3, builtin_string_slice},
	{"string_from_chars", 1, builtin_string_from_chars},
	{"string_concat", -1, builtin_string_concat},
	{"string_join", 2, builtin_string_join},
	{"string_starts_with", 2, builtin_string_starts_with},
	{"string_contains", 2, builtin_string_contains},
	{"string_equal_fold", 2, builtin_string_equal_fold},
	{"lower", 1, builtin_lower},
	{"words", 1, builtin_words},
	{"sort", 1, builtin_sort},
	{"edit_distance", 2, builtin_edit_distance},
	{"parse_ordinal", 1, builtin_parse_ordinal},
	{"__list_concat", -1, builtin_list_concat},
	{"__list_slice", 3, builtin_list_slice},
	{"__index_option", 2, builtin_index_option},
	{"__len_option", 1, builtin_len_option},
	{"__set_index", 3, builtin_set_index},
	{"to_symbol", 1, builtin_to_symbol},
	{"map_pairs", 1, builtin_map_pairs},
	{"index_or", 3, builtin_index_or},
	{"url_encode_component", 1, builtin_url_encode_component},
	{"url_decode_component", 1, builtin_url_decode_component},
	{"os_getenv", 1, builtin_os_getenv},
	{"to_literal", 1, builtin_to_literal},
	{"endpoint", 0, builtin_endpoint},
	{"actor", 0, builtin_actor},
	{"principal", 0, builtin_principal},
	{"dom_text", 1, builtin_dom_text},
	{"dom_raw", 1, builtin_dom_raw},
	{"dom_element", 3, builtin_dom_element},
	{"dom_diff", 2, builtin_dom_diff},
	{"dom_html", 1, builtin_dom_html},
	{"from_xml", 1, builtin_from_xml},
	{"to_xml", 1, builtin_to_xml},
	{"sync_signature", 2, builtin_sync_signature},
	{"dom_snapshot_payload", 3, builtin_dom_snapshot_payload},
	{"embed_text", 2, builtin_embed_text},
	{"from_literal", 1, builtin_from_literal},
	{"mint_capability", -1, builtin_mint_capability},
	{"use_capability", 1, builtin_use_capability},
	{"restrict_capability", 2, builtin_restrict_capability},
	{"revoke_capability", 1, builtin_revoke_capability},
	{"drop_capability", 1, builtin_drop_capability},
	{"assume_actor", 1, builtin_assume_actor},
	{"enable_rule", 1, builtin_enable_rule},
	{"disable_rule", 1, builtin_disable_rule},
	{"rules", 1, builtin_rules},
	{"describe_rule", 1, builtin_describe_rule},
	{"fileout", 1, builtin_fileout},
	{"fileout_rules", -1, builtin_fileout_rules},
	{"tasks", 0, builtin_tasks},
	{"log", -1, builtin_log},
	{"project", -1, builtin_project},
	{"union", 2, builtin_union},
	{"difference", 2, builtin_difference},
	{"natural_join", 2, builtin_natural_join},
	{"json_encode", 1, builtin_json_encode},
	{"json_decode", 1, builtin_json_decode},
	{"json_null", 0, builtin_json_null},
	{"json_is_null", 1, builtin_json_is_null},
	{"subscribe_changes", -1, builtin_subscribe_changes},
	{"cancel_subscription", 1, builtin_cancel_subscription},
	{"mailbox", 0, builtin_mailbox},
	{"mailbox_send", 2, builtin_mailbox_send},
	{"mailbox_close", 1, builtin_mailbox_close},
	{"mailbox_recv", 1, builtin_mailbox_recv},
	{"external_request", 2, builtin_external_request},
}

@(private)
install_builtin_names :: proc(ctx: ^c.Compile_Context) {
	for spec in runtime_builtins {
		ctx.builtins[spec.name] = true
	}
}

// Primitive prototype identities such as `#string` and `#identity` are always
// available to source, independent of any `make_identity` declarations.
@(private)
install_primitive_identities :: proc(ctx: ^c.Compile_Context) {
	prototypes := [?]struct {
		name: string,
		id:   v.Identity,
	} {
		{"bool", v.BOOL_PROTOTYPE},
		{"integer", v.INTEGER_PROTOTYPE},
		{"float", v.FLOAT_PROTOTYPE},
		{"identity", v.IDENTITY_PROTOTYPE},
		{"symbol", v.SYMBOL_PROTOTYPE},
		{"error_code", v.ERROR_CODE_PROTOTYPE},
		{"string", v.STRING_PROTOTYPE},
		{"bytes", v.BYTES_PROTOTYPE},
		{"list", v.LIST_PROTOTYPE},
		{"map", v.MAP_PROTOTYPE},
		{"range", v.RANGE_PROTOTYPE},
		{"error", v.ERROR_PROTOTYPE},
		{"capability", v.CAPABILITY_PROTOTYPE},
		{"frob", v.FROB_PROTOTYPE},
		{"function", v.FUNCTION_PROTOTYPE},
		{"relation", v.RELATION_PROTOTYPE},
	}
	for prototype in prototypes {
		ctx.identities[prototype.name] = v.value_identity(prototype.id)
	}
}

@(private)
register_runtime_builtins :: proc(state: ^vm.VM) {
	for spec in runtime_builtins {
		vm.vm_register_builtin(state, v.symbol_intern(spec.name), spec.argc, spec.run)
	}
}

@(private)
builtin_endpoint :: proc(state: ^vm.VM, args: []v.Value) -> (v.Value, bool) {
	if len(args) != 0 {
		return builtin_error(state, "E_INVARG", "endpoint expects no arguments")
	}
	return state.endpoint, true
}

@(private)
builtin_actor :: proc(state: ^vm.VM, args: []v.Value) -> (v.Value, bool) {
	if len(args) != 0 {
		return builtin_error(state, "E_INVARG", "actor expects no arguments")
	}
	if v.value_is_empty_relation(state.actor) {
		return option_none_value(state.allocator), true
	}
	return option_some_value(state.allocator, state.actor), true
}

@(private)
builtin_principal :: proc(state: ^vm.VM, args: []v.Value) -> (v.Value, bool) {
	if len(args) != 0 {
		return builtin_error(state, "E_INVARG", "principal expects no arguments")
	}
	if v.value_is_empty_relation(state.principal) {
		return option_none_value(state.allocator), true
	}
	return option_some_value(state.allocator, state.principal), true
}

@(private)
builtin_assume_actor :: proc(state: ^vm.VM, args: []v.Value) -> (v.Value, bool) {
	env := builtin_env(state)
	if len(args) != 1 {
		return builtin_error(state, "E_INVARG", "assume_actor expects one identity")
	}
	actor_value, is_identity := v.value_as_identity(args[0])
	if !is_identity {
		return builtin_error(state, "E_TYPE", "assume_actor expects an identity")
	}
	if !actor_assumption_allowed(state, actor_value) {
		return builtin_error(state, "E_PERMISSION", "actor assumption denied")
	}

	previous_actor := state.actor
	state.actor = args[0]

	// Refresh the task's authority for the new actor, preserving adopted
	// capability grants.
	if state.authority != nil && !state.authority.root {
		adopted: [dynamic]^k.Capability_Grant
		defer delete(adopted)
		for grant in state.authority.capabilities {
			k.capability_retain(grant)
			append(&adopted, grant)
		}
		snapshot := k.kernel_snapshot(env.kernel)
		source := k.Relation_Source {
			snapshot = snapshot,
		}
		k.authority_destroy(state.authority)
		state.authority^ = k.authority_from_actor(
			&source,
			actor_value,
			env.allocator,
		)
		k.snapshot_release(snapshot)
		for grant in adopted {
			k.authority_adopt_capability(state.authority, grant)
			k.capability_release(grant)
		}
	}

	// Record the endpoint binding for the current endpoint.
	if state.transaction != nil && !v.value_is_empty_relation(state.endpoint) {
		_ = k.transaction_retract(
			state.transaction,
			k.SYSTEM_ENDPOINT_ACTOR_ID,
			v.tuple_new(env.allocator, []v.Value{state.endpoint, previous_actor}),
		)
		_ = k.transaction_assert(
			state.transaction,
			k.SYSTEM_ENDPOINT_ACTOR_ID,
			v.tuple_new(env.allocator, []v.Value{state.endpoint, args[0]}),
		)
	}
	return v.value_bool(true), true
}

// The caller may assume an actor when it has grant authority or when the
// principal policy allows it.
@(private)
actor_assumption_allowed :: proc(state: ^vm.VM, actor: v.Identity) -> bool {
	if k.authority_can_grant(state.authority) {
		return true
	}
	env := builtin_env(state)
	relation, found := env.ctx.relations["session/CanAssumeActor"]
	if !found || state.transaction == nil {
		return false
	}
	rows: [dynamic]v.Tuple
	defer delete(rows)
	source := k.Relation_Source {
		transaction = state.transaction,
	}
	k.relation_source_scan_into(
		&source,
		k.Relation_ID(relation),
		[]v.Binding{
			v.binding_of(state.principal),
			v.binding_of(v.value_identity(actor)),
		},
		&rows,
	)
	return len(rows) > 0
}

@(private)
builtin_dom_text :: proc(state: ^vm.VM, args: []v.Value) -> (v.Value, bool) {
	text, is_string := v.value_as_string(args[0])
	if !is_string {
		return builtin_error(state, "E_TYPE", "dom_text expects a string")
	}
	return v.value_map(state.allocator, []v.Map_Entry {
		{
			key   = v.value_symbol(v.symbol_intern("text")),
			value = v.value_string(state.allocator, text),
		},
	}), true
}

@(private)
builtin_dom_raw :: proc(state: ^vm.VM, args: []v.Value) -> (v.Value, bool) {
	text, is_string := v.value_as_string(args[0])
	if !is_string {
		return builtin_error(state, "E_TYPE", "dom_raw expects a string")
	}
	return v.value_map(state.allocator, []v.Map_Entry {
		{
			key   = v.value_symbol(v.symbol_intern("raw")),
			value = v.value_string(state.allocator, text),
		},
	}), true
}

@(private)
builtin_dom_element :: proc(state: ^vm.VM, args: []v.Value) -> (v.Value, bool) {
	tag, is_string := v.value_as_string(args[0])
	if !is_string {
		return builtin_error(state, "E_TYPE", "dom_element tag is not a string")
	}
	if _, is_map := v.value_as_map(args[1]); !is_map {
		return builtin_error(state, "E_TYPE", "dom_element attrs are not a map")
	}
	if _, is_list := v.value_as_list(args[2]); !is_list {
		return builtin_error(state, "E_TYPE", "dom_element children are not a list")
	}
	return v.value_map(state.allocator, []v.Map_Entry {
		{key = v.value_symbol(v.symbol_intern("attrs")), value = args[1]},
		{key = v.value_symbol(v.symbol_intern("children")), value = args[2]},
		{
			key   = v.value_symbol(v.symbol_intern("tag")),
			value = v.value_string(state.allocator, tag),
		},
	}), true
}

@(private)
write_xml_text :: proc(builder: ^strings.Builder, text: string) {
	for ch in text {
		switch ch {
		case '&':
			strings.write_string(builder, "&amp;")
		case '<':
			strings.write_string(builder, "&lt;")
		case '>':
			strings.write_string(builder, "&gt;")
		case:
			strings.write_rune(builder, ch)
		}
	}
}

@(private)
write_xml_attribute :: proc(builder: ^strings.Builder, text: string) {
	for ch in text {
		switch ch {
		case '&':
			strings.write_string(builder, "&amp;")
		case '<':
			strings.write_string(builder, "&lt;")
		case '>':
			strings.write_string(builder, "&gt;")
		case '"':
			strings.write_string(builder, "&quot;")
		case:
			strings.write_rune(builder, ch)
		}
	}
}

@(private)
write_xml_value :: proc(builder: ^strings.Builder, value: v.Value) -> bool {
	if text, is_string := v.value_as_string(value); is_string {
		write_xml_text(builder, text)
		return true
	}
	if boolean, is_bool := v.value_as_bool(value); is_bool {
		strings.write_string(builder, boolean ? "true" : "false")
		return true
	}
	if integer, is_int := v.value_as_int(value); is_int {
		fmt.sbprintf(builder, "%d", integer)
		return true
	}
	return false
}

// Writes a DOM value as XML or HTML. In HTML mode, tags and attributes are
// restricted to the supported DOM surface, matching `dom_html` in the Rust
// runtime. Attribute names may be strings or named symbols.
@(private)
write_markup_node :: proc(builder: ^strings.Builder, value: v.Value, html: bool) -> bool {
	if _, is_list := v.value_as_list(value); is_list {
		nodes, _ := v.value_as_list(value)
		for node in nodes {
			if !write_markup_node(builder, node, html) {
				return false
			}
		}
		return true
	}

	entries, is_map := v.value_as_map(value)
	if !is_map {
		return write_xml_value(builder, value)
	}

	text: v.Value
	has_text := false
	raw: v.Value
	has_raw := false
	tag: v.Value
	has_tag := false
	attrs: v.Value
	has_attrs := false
	children: v.Value
	has_children := false
	for entry in entries {
		name, _ := v.value_as_symbol(entry.key)
		name_text, name_ok := v.symbol_name(name)
		if !name_ok {
			continue
		}
		switch name_text {
		case "text":
			text, has_text = entry.value, true
		case "raw":
			raw, has_raw = entry.value, true
		case "tag":
			tag, has_tag = entry.value, true
		case "attrs":
			attrs, has_attrs = entry.value, true
		case "children":
			children, has_children = entry.value, true
		}
	}

	if has_text {
		contents, _ := v.value_as_string(text)
		write_xml_text(builder, contents)
		return true
	}
	if has_raw {
		contents, _ := v.value_as_string(raw)
		strings.write_string(builder, contents)
		return true
	}
	if !has_tag {
		return false
	}
	tag_text, tag_ok := v.value_as_string(tag)
	if !tag_ok {
		return false
	}
	if html && !dom.is_supported_dom_tag(tag_text) {
		return false
	}
	strings.write_byte(builder, '<')
	strings.write_string(builder, tag_text)
	if has_attrs {
		attribute_entries, is_attrs := v.value_as_map(attrs)
		if !is_attrs {
			return false
		}
		for entry in attribute_entries {
			name_text, name_ok := markup_attribute_name(entry.key)
			if !name_ok {
				return false
			}
			if html && !dom.is_supported_dom_attribute(name_text) {
				return false
			}
			strings.write_byte(builder, ' ')
			strings.write_string(builder, name_text)
			strings.write_string(builder, "=\"")
			if contents, is_string := v.value_as_string(entry.value); is_string {
				write_xml_attribute(builder, contents)
			} else if !write_xml_value(builder, entry.value) {
				return false
			}
			strings.write_byte(builder, '"')
		}
	}
	strings.write_byte(builder, '>')
	if has_children {
		if !write_markup_node(builder, children, html) {
			return false
		}
	}
	strings.write_string(builder, "</")
	strings.write_string(builder, tag_text)
	strings.write_byte(builder, '>')
	return true
}

// Attribute names are strings or named symbols, matching the Rust host.
@(private)
markup_attribute_name :: proc(value: v.Value) -> (string, bool) {
	if text, is_string := v.value_as_string(value); is_string {
		return text, true
	}
	if symbol, is_symbol := v.value_as_symbol(value); is_symbol {
		return v.symbol_name(symbol)
	}
	return "", false
}

@(private)
builtin_dom_html :: proc(state: ^vm.VM, args: []v.Value) -> (v.Value, bool) {
	builder: strings.Builder
	strings.builder_init(&builder, state.allocator)
	if !write_markup_node(&builder, args[0], true) {
		strings.builder_destroy(&builder)
		return builtin_error(
			state,
			"E_TYPE",
			"dom_html expects DOM text, element, or node list with supported tags and attributes",
		)
	}
	return v.value_string(state.allocator, strings.to_string(builder)), true
}

@(private)
builtin_from_xml :: proc(state: ^vm.VM, args: []v.Value) -> (v.Value, bool) {
	text, is_string := v.value_as_string(args[0])
	if !is_string {
		return builtin_error(state, "E_TYPE", "from_xml expects XML text")
	}
	value, parse_error := dom.dom_parse_xml_value(text, state.allocator)
	if parse_error != "" {
		return builtin_error(state, "E_INVARG", parse_error)
	}
	return value, true
}

@(private)
builtin_to_xml :: proc(state: ^vm.VM, args: []v.Value) -> (v.Value, bool) {
	builder: strings.Builder
	strings.builder_init(&builder, state.allocator)
	if !write_markup_node(&builder, args[0], false) {
		strings.builder_destroy(&builder)
		return builtin_error(state, "E_TYPE", "to_xml expects DOM text, element, or node list")
	}
	return v.value_string(state.allocator, strings.to_string(builder)), true
}

@(private)
builtin_sync_signature :: proc(state: ^vm.VM, args: []v.Value) -> (v.Value, bool) {
	revision, is_int := v.value_as_int(args[0])
	if !is_int || revision < 0 {
		return builtin_error(
			state,
			"E_INVARG",
			"sync_signature revision must be a non-negative integer",
		)
	}
	payload, is_string := v.value_as_string(args[1])
	if !is_string {
		return builtin_error(state, "E_TYPE", "sync_signature payload must be a string")
	}
	hash := u64(0xcbf2_9ce4_8422_2325)
	raw_revision := u64(revision)
	for index in 0 ..< 8 {
		byte := u8(raw_revision >> (8 * u32(index)))
		hash = (hash ~ u64(byte)) * u64(0x0000_0100_0000_01b3)
	}
	for byte in transmute([]u8)payload {
		hash = (hash ~ u64(byte)) * u64(0x0000_0100_0000_01b3)
	}
	// Mica integers are 56-bit; the mask matches Rust's SIGNATURE_MASK.
	hash &= 0x007f_ffff_ffff_ffff
	result, _ := v.value_int(i64(hash))
	return result, true
}

@(private)
builtin_dom_snapshot_payload :: proc(state: ^vm.VM, args: []v.Value) -> (v.Value, bool) {
	view, view_ok := v.value_as_int(args[0])
	revision, revision_ok := v.value_as_int(args[1])
	if !view_ok || !revision_ok || view < 0 || revision < 0 {
		return builtin_error(
			state,
			"E_INVARG",
			"dom_snapshot_payload expects non-negative view and revision",
		)
	}
	node, node_error := dom.dom_node_from_value(args[2], state.allocator)
	if node_error != "" {
		return builtin_error(state, "E_TYPE", node_error)
	}
	payload := dom.dom_snapshot_payload_json(
		u64(view),
		u64(revision),
		node,
		state.allocator,
	)
	return v.value_string(state.allocator, payload), true
}

// A deterministic stand-in for a host embedding provider: hashes the text into
// eight floats so retrieval plans are reproducible without a model.
@(private)
builtin_embed_text :: proc(state: ^vm.VM, args: []v.Value) -> (v.Value, bool) {
	model, model_ok := v.value_as_string(args[0])
	if !model_ok {
		return builtin_error(state, "E_TYPE", "embed_text model must be a string")
	}
	text, text_ok := v.value_as_string(args[1])
	if !text_ok {
		return builtin_error(state, "E_TYPE", "embed_text text must be a string")
	}
	values := make([]v.Value, 8, context.temp_allocator)
	hash := u64(0xcbf2_9ce4_8422_2325)
	input := strings.concatenate([]string{model, "\x00", text}, context.temp_allocator)
	for byte in transmute([]u8)input {
		hash = (hash ~ u64(byte)) * u64(0x0000_0100_0000_01b3)
	}
	for index in 0 ..< len(values) {
		hash = (hash ~ u64(index)) * u64(0x0000_0100_0000_01b3)
		scaled := f32(f64(hash & 0xffff) / 65535.0)
		converted, converted_ok := v.value_float(scaled)
		if !converted_ok {
			return builtin_error(state, "E_RANGE", "embed_text produced a non-finite value")
		}
		values[index] = converted
	}
	return v.value_list(state.allocator, values), true
}

// Converts a DOM node back into the map shape `dom_element` and `dom_text`
// produce, matching `DomNode::to_mica_value` in the Rust host protocol.
@(private)
dom_node_to_value :: proc(node: dom.Dom_Node, allocator: mem.Allocator) -> v.Value {
	#partial switch n in node {
	case dom.Dom_Text:
		return v.value_map(allocator, []v.Map_Entry {
			{
				key   = v.value_symbol(v.symbol_intern("text")),
				value = v.value_string(allocator, n.text),
			},
		})
	case dom.Dom_Element:
		attrs := make([]v.Map_Entry, len(n.attrs), allocator)
		for attribute, index in n.attrs {
			attrs[index] = v.Map_Entry {
				key   = v.value_string(allocator, attribute.name),
				value = v.value_string(allocator, attribute.value),
			}
		}
		children := make([]v.Value, len(n.children), allocator)
		for child, index in n.children {
			children[index] = dom_node_to_value(child, allocator)
		}
		return v.value_map(allocator, []v.Map_Entry {
			{
				key   = v.value_symbol(v.symbol_intern("attrs")),
				value = v.value_map(allocator, attrs),
			},
			{
				key   = v.value_symbol(v.symbol_intern("children")),
				value = v.value_list(allocator, children),
			},
			{
				key   = v.value_symbol(v.symbol_intern("tag")),
				value = v.value_string(allocator, n.tag),
			},
		})
	}
	return v.value_map(allocator, []v.Map_Entry{})
}

// Converts one DOM patch into the map shape `DomPatch::to_mica_value` uses.
@(private)
dom_patch_to_value :: proc(patch: ^dom.Dom_Patch, allocator: mem.Allocator) -> v.Value {
	op: string
	extra: []v.Map_Entry
	path: []u64
	switch value in patch^ {
	case dom.Dom_Patch_Replace:
		op = "replace"
		path = value.path
		extra = []v.Map_Entry {{
			key   = v.value_symbol(v.symbol_intern("node")),
			value = dom_node_to_value(value.node, allocator),
		}}
	case dom.Dom_Patch_Set_Text:
		op = "set_text"
		path = value.path
		extra = []v.Map_Entry {{
			key   = v.value_symbol(v.symbol_intern("text")),
			value = v.value_string(allocator, value.text),
		}}
	case dom.Dom_Patch_Set_Attr:
		op = "set_attr"
		path = value.path
		extra = []v.Map_Entry {
			{
				key   = v.value_symbol(v.symbol_intern("name")),
				value = v.value_string(allocator, value.name),
			},
			{
				key   = v.value_symbol(v.symbol_intern("value")),
				value = v.value_string(allocator, value.value),
			},
		}
	case dom.Dom_Patch_Remove_Attr:
		op = "remove_attr"
		path = value.path
		extra = []v.Map_Entry {{
			key   = v.value_symbol(v.symbol_intern("name")),
			value = v.value_string(allocator, value.name),
		}}
	case dom.Dom_Patch_Append_Child:
		op = "append_child"
		path = value.path
		extra = []v.Map_Entry {{
			key   = v.value_symbol(v.symbol_intern("node")),
			value = dom_node_to_value(value.node, allocator),
		}}
	case dom.Dom_Patch_Insert_Child:
		op = "insert_child"
		path = value.path
		index, _ := v.value_int(i64(value.index))
		extra = []v.Map_Entry {
			{key = v.value_symbol(v.symbol_intern("index")), value = index},
			{
				key   = v.value_symbol(v.symbol_intern("node")),
				value = dom_node_to_value(value.node, allocator),
			},
		}
	case dom.Dom_Patch_Remove_Child:
		op = "remove_child"
		path = value.path
	}
	path_values := make([]v.Value, len(path), allocator)
	for index, position in path {
		path_values[position], _ = v.value_int(i64(index))
	}
	entries := make([]v.Map_Entry, 2 + len(extra), allocator)
	entries[0] = v.Map_Entry {
		key   = v.value_symbol(v.symbol_intern("op")),
		value = v.value_string(allocator, op),
	}
	entries[1] = v.Map_Entry {
		key   = v.value_symbol(v.symbol_intern("path")),
		value = v.value_list(allocator, path_values),
	}
	for entry, index in extra {
		entries[2 + index] = entry
	}
	return v.value_map(allocator, entries)
}

@(private)
builtin_dom_diff :: proc(state: ^vm.VM, args: []v.Value) -> (v.Value, bool) {
	before, before_error := dom.dom_node_from_value(args[0], state.allocator)
	if before_error != "" {
		return builtin_error(state, "E_TYPE", before_error)
	}
	defer dom.dom_node_release(before, state.allocator)
	after, after_error := dom.dom_node_from_value(args[1], state.allocator)
	if after_error != "" {
		return builtin_error(state, "E_TYPE", after_error)
	}
	defer dom.dom_node_release(after, state.allocator)

	path: [dynamic]u64
	path = make([dynamic]u64, state.allocator)
	defer delete(path)
	patches: [dynamic]dom.Dom_Patch
	patches = make([dynamic]dom.Dom_Patch, state.allocator)
	defer {
		for &patch in patches {
			dom.dom_patch_release(&patch, state.allocator)
		}
		delete(patches)
	}
	dom.dom_diff_nodes(before, after, &path, &patches, state.allocator)
	values := make([]v.Value, len(patches), state.allocator)
	for &patch, index in patches {
		values[index] = dom_patch_to_value(&patch, state.allocator)
	}
	return v.value_list(state.allocator, values), true
}

// `log(message)` and `log(:level, message)`: records a host-facing log line.
// Levels are `:trace`, `:debug`, `:info`, `:warn`, and `:error`.
@(private)
builtin_log :: proc(state: ^vm.VM, args: []v.Value) -> (v.Value, bool) {
	if len(args) != 1 && len(args) != 2 {
		return builtin_error(state, "E_INVARG", "log expects log(message) or log(:level, message)")
	}
	if !k.authority_can_effect(state.authority) {
		return builtin_error(state, "E_PERMISSION", "log is not permitted")
	}
	level := "info"
	message_index := 0
	if len(args) == 2 {
		level_symbol, is_symbol := v.value_as_symbol(args[0])
		if !is_symbol {
			return builtin_error(state, "E_TYPE", "log level must be a symbol")
		}
		level_name, has_name := v.symbol_name(level_symbol)
		if !has_name {
			return builtin_error(state, "E_INVARG", "log level must be named")
		}
		level = level_name
		message_index = 1
	}
	message, is_string := v.value_as_string(args[message_index])
	if !is_string {
		return builtin_error(state, "E_TYPE", "log message must be a string")
	}
	switch level {
	case "trace", "debug", "info", "warn", "error":
	case:
		return builtin_error(
			state,
			"E_INVARG",
			"log level must be one of :trace, :debug, :info, :warn, or :error",
		)
	}
	fmt.eprintf("mica log [%s] %s\n", level, message)
	return v.value_empty_relation(), true
}

@(private)
literal_value :: proc(env: ^Builtin_Env, expr: ^c.Expr) -> (v.Value, bool) {
	#partial switch node in expr^ {
	case c.Int_Literal:
		number, parsed := strconv.parse_i64(node.text)
		if !parsed {
			return v.Value(0), false
		}
		converted, converted_ok := v.value_int(number)
		return converted, converted_ok

	case c.Float_Literal:
		number, parsed := strconv.parse_f64(node.text)
		if !parsed {
			return v.Value(0), false
		}
		converted, converted_ok := v.value_float(f32(number))
		return converted, converted_ok

	case c.String_Literal:
		return v.value_string(env.allocator, unquote(node.text)), true

	case c.Bool_Literal:
		return v.value_bool(node.value), true

	case c.Symbol_Literal:
		return v.value_symbol(v.symbol_intern(unquote(node.name))), true

	case c.Identity_Literal:
		if raw, parsed := strconv.parse_u64(node.name); parsed {
			return v.value_identity_raw(raw)
		}
		if value, found := env.ctx.identities[node.name]; found {
			return value, true
		}
		return v.Value(0), false

	case c.Error_Code_Literal:
		return v.value_error_code(v.symbol_intern(node.name)), true

	case c.Name:
		if len(node.parts) == 1 && node.parts[0] == "none" {
			empty, _ := v.value_relation(
				env.allocator,
				[]v.Symbol{v.symbol_intern("value")},
				nil,
			)
			return empty, true
		}
		return v.Value(0), false

	case c.List_Literal:
		values := make([]v.Value, len(node.elements), context.temp_allocator)
		for element, index in node.elements {
			value, element_ok := literal_value(env, element)
			if !element_ok {
				return v.Value(0), false
			}
			values[index] = value
		}
		return v.value_list(env.allocator, values), true

	case c.Map_Literal:
		entries := make([]v.Map_Entry, len(node.entries), context.temp_allocator)
		for entry, index in node.entries {
			key, key_ok := literal_value(env, entry.key)
			if !key_ok {
				return v.Value(0), false
			}
			value, value_ok := literal_value(env, entry.value)
			if !value_ok {
				return v.Value(0), false
			}
			entries[index] = v.Map_Entry{key = key, value = value}
		}
		return v.value_map(env.allocator, entries), true
	}
	return v.Value(0), false
}

@(private)
builtin_from_literal :: proc(state: ^vm.VM, args: []v.Value) -> (v.Value, bool) {
	text, is_string := string_argument(state, args, 0, "from_literal")
	if !is_string {
		return builtin_error(state, "E_TYPE", "from_literal expects a string")
	}
	ast, parse_errors := c.parse_program(text, context.temp_allocator)
	if len(parse_errors) > 0 {
		problem := v.value_error(
			state.allocator,
			v.symbol_intern("E_PARSE"),
			parse_errors[0].message,
			true,
			v.value_string(state.allocator, text),
			true,
		)
		return result_value(state.allocator, "error", problem), true
	}
	if len(ast.items) != 1 {
		problem := v.value_error(
			state.allocator,
			v.symbol_intern("E_PARSE"),
			"expected one literal expression",
			true,
			v.value_string(state.allocator, text),
			true,
		)
		return result_value(state.allocator, "error", problem), true
	}
	item, is_expr := ast.items[0].(c.Expr_Item)
	if !is_expr {
		problem := v.value_error(
			state.allocator,
			v.symbol_intern("E_TYPE"),
			"expected a literal expression",
			true,
			v.value_string(state.allocator, text),
			true,
		)
		return result_value(state.allocator, "error", problem), true
	}
	value, value_ok := literal_value(builtin_env(state), item.expr)
	if !value_ok {
		problem := v.value_error(
			state.allocator,
			v.symbol_intern("E_TYPE"),
			"unsupported literal expression",
			true,
			v.value_string(state.allocator, text),
			true,
		)
		return result_value(state.allocator, "error", problem), true
	}
	return result_value(state.allocator, "ok", value), true
}

@(private)
builtin_mailbox :: proc(state: ^vm.VM, args: []v.Value) -> (v.Value, bool) {
	env := builtin_env(state)
	if env.scheduler == nil {
		return builtin_error(state, "E_MAILBOX", "mailboxes need a running scheduler")
	}
	receiver, sender, ok := scheduler_mailbox_create(env.scheduler)
	if !ok {
		return builtin_error(state, "E_MAILBOX", "cannot create a mailbox")
	}
	return v.value_list(state.allocator, []v.Value{receiver, sender}), true
}

@(private)
builtin_mailbox_send :: proc(state: ^vm.VM, args: []v.Value) -> (v.Value, bool) {
	env := builtin_env(state)
	if env.scheduler == nil {
		return builtin_error(state, "E_MAILBOX", "mailboxes need a running scheduler")
	}
	if !scheduler_mailbox_send(env.scheduler, args[0], args[1]) {
		return builtin_error(state, "E_MAILBOX", "mailbox_send expects a live sender capability")
	}
	return args[1], true
}

@(private)
builtin_mailbox_close :: proc(state: ^vm.VM, args: []v.Value) -> (v.Value, bool) {
	env := builtin_env(state)
	if env.scheduler == nil {
		return builtin_error(state, "E_MAILBOX", "mailboxes need a running scheduler")
	}
	if !scheduler_mailbox_close(env.scheduler, args[0]) {
		return builtin_error(state, "E_MAILBOX", "mailbox_close expects a live receiver capability")
	}
	_ = subscriptions_cancel_for_mailbox(env, args[0])
	return v.value_empty_relation(), true
}

@(private)
builtin_mailbox_recv :: proc(state: ^vm.VM, args: []v.Value) -> (v.Value, bool) {
	return builtin_error(state, "E_VM_FAULT", "mailbox_recv must be lowered to a VM op")
}

@(private)
builtin_external_request :: proc(state: ^vm.VM, args: []v.Value) -> (v.Value, bool) {
	return builtin_error(state, "E_VM_FAULT", "external_request must be lowered to a VM op")
}

@(private)
builtin_mint_capability :: proc(state: ^vm.VM, args: []v.Value) -> (v.Value, bool) {
	env := builtin_env(state)
	if !k.authority_can_grant(state.authority) {
		return builtin_error(state, "E_PERMISSION", "capability minting denied")
	}
	if len(args) < 1 || len(args) > 3 {
		return builtin_error(
			state,
			"E_INVARG",
			"mint_capability expects rights, optional targets, and optional limits",
		)
	}
	rights, rights_ok := capability_rights_argument(state, args[0])
	if !rights_ok {
		return v.Value(0), false
	}
	scope := k.Capability_Scope.All
	relations: []k.Relation_ID
	selectors: []v.Symbol
	if len(args) >= 2 {
		parsed_scope, parsed_relations, parsed_selectors, targets_ok := capability_target_argument(
			state,
			env,
			args[1],
			rights,
		)
		if !targets_ok {
			return v.Value(0), false
		}
		scope = parsed_scope
		relations = parsed_relations
		selectors = parsed_selectors
	} else if !capability_rights_allow_all(rights) {
		// Absolute scopes (effect/grant) are fine without targets; read,
		// write, and invoke without targets mean "all".
	}
	limits := k.Capability_Limits{}
	if len(args) == 3 {
		parsed_limits, limits_ok := capability_limits_argument(state, env, args[2])
		if !limits_ok {
			return v.Value(0), false
		}
		limits = parsed_limits
	}
	value, minted := k.capability_store_mint(
		&env.kernel.capabilities,
		rights,
		scope,
		relations,
		selectors,
		limits,
	)
	if !minted {
		return builtin_error(state, "E_CAPABILITY", "cannot create capability")
	}
	return value, true
}

@(private)
builtin_use_capability :: proc(state: ^vm.VM, args: []v.Value) -> (v.Value, bool) {
	env := builtin_env(state)
	grant, found := k.capability_store_lookup(&env.kernel.capabilities, args[0])
	if !found {
		return builtin_error(state, "E_INVARG", "unknown capability")
	}
	if grant.scope == .Mailbox || grant.scope == .Subscription {
		return builtin_error(state, "E_INVARG", "handle is not an authority capability")
	}
	if !k.capability_live(grant, kernel_version(env), time.tick_now()) {
		return builtin_error(state, "E_INVARG", "capability is revoked or expired")
	}
	k.authority_adopt_capability(state.authority, grant)
	return v.value_bool(true), true
}

@(private)
builtin_restrict_capability :: proc(state: ^vm.VM, args: []v.Value) -> (v.Value, bool) {
	env := builtin_env(state)
	parent, found := k.capability_store_lookup(&env.kernel.capabilities, args[0])
	if !found {
		return builtin_error(state, "E_INVARG", "unknown capability")
	}
	if parent.scope == .Mailbox || parent.scope == .Subscription {
		return builtin_error(state, "E_INVARG", "handles cannot be restricted")
	}
	if !k.authority_holds_capability(state.authority, parent) &&
	   !k.authority_can_grant(state.authority) {
		return builtin_error(state, "E_PERMISSION", "capability restriction denied")
	}
	rights, rights_ok := capability_rights_argument(state, args[1])
	if !rights_ok {
		return v.Value(0), false
	}
	value, restricted := k.capability_store_restrict(
		&env.kernel.capabilities,
		args[0],
		rights,
	)
	if !restricted {
		return builtin_error(state, "E_INVARG", "cannot restrict capability")
	}
	return value, true
}

@(private)
builtin_revoke_capability :: proc(state: ^vm.VM, args: []v.Value) -> (v.Value, bool) {
	env := builtin_env(state)
	grant, found := k.capability_store_lookup(&env.kernel.capabilities, args[0])
	if !found {
		return builtin_error(state, "E_INVARG", "unknown capability")
	}
	if !k.authority_holds_capability(state.authority, grant) &&
	   !k.authority_can_grant(state.authority) {
		return builtin_error(state, "E_PERMISSION", "capability revocation denied")
	}
	if !k.capability_store_revoke(&env.kernel.capabilities, args[0]) {
		return builtin_error(state, "E_INVARG", "capability is already revoked")
	}
	return v.value_bool(true), true
}

@(private)
builtin_drop_capability :: proc(state: ^vm.VM, args: []v.Value) -> (v.Value, bool) {
	env := builtin_env(state)
	grant, found := k.capability_store_lookup(&env.kernel.capabilities, args[0])
	if !found {
		return builtin_error(state, "E_INVARG", "unknown capability")
	}
	return v.value_bool(k.authority_drop_capability(state.authority, grant)), true
}

// Parses a rights argument: a symbol or a list of symbols.
@(private)
capability_rights_argument :: proc(state: ^vm.VM, value: v.Value) -> (k.Rights, bool) {
	rights: k.Rights
	if list, is_list := v.value_as_list(value); is_list {
		for item in list {
			item_right, item_ok := capability_right(state, item)
			if !item_ok {
				return {}, false
			}
			rights += item_right
		}
	} else {
		right, right_ok := capability_right(state, value)
		if !right_ok {
			return {}, false
		}
		rights = right
	}
	if card(rights) == 0 {
		vm.vm_set_error(state, "E_INVARG", "capability needs at least one right")
		return {}, false
	}
	return rights, true
}

@(private)
capability_right :: proc(state: ^vm.VM, value: v.Value) -> (k.Rights, bool) {
	symbol, is_symbol := v.value_as_symbol(value)
	if !is_symbol {
		vm.vm_set_error(state, "E_TYPE", "capability rights must be symbols")
		return {}, false
	}
	name, name_ok := v.symbol_name(symbol)
	if !name_ok {
		vm.vm_set_error(state, "E_TYPE", "capability right is unknown")
		return {}, false
	}
	switch name {
	case "read":
		return {.Read}, true
	case "write":
		return {.Write}, true
	case "invoke":
		return {.Invoke}, true
	case "effect":
		return {.Effect}, true
	case "grant":
		return {.Grant}, true
	case "all":
		return {.Read, .Write, .Invoke, .Effect, .Grant}, true
	}
	vm.vm_set_error(state, "E_INVARG", "unknown capability right")
	return {}, false
}

@(private)
capability_rights_allow_all :: proc(rights: k.Rights) -> bool {
	return card(rights) > 0
}

// Parses a target argument. Read/write rights take relation names; invoke
// takes selectors; effect/grant take no targets.
@(private)
capability_target_argument :: proc(
	state: ^vm.VM,
	env: ^Builtin_Env,
	value: v.Value,
	rights: k.Rights,
) -> (
	scope: k.Capability_Scope,
	relations: []k.Relation_ID,
	selectors: []v.Symbol,
	ok: bool,
) {
	targets: [dynamic]v.Symbol
	defer delete(targets)
	if list, is_list := v.value_as_list(value); is_list {
		for item in list {
			symbol, is_symbol := v.value_as_symbol(item)
			if !is_symbol {
				vm.vm_set_error(state, "E_TYPE", "capability targets must be symbols")
				return .All, nil, nil, false
			}
			append(&targets, symbol)
		}
	} else if symbol, is_symbol := v.value_as_symbol(value); is_symbol {
		append(&targets, symbol)
	} else if v.value_is_empty_relation(value) {
		return .All, nil, nil, true
	} else {
		vm.vm_set_error(state, "E_TYPE", "capability targets must be symbols")
		return .All, nil, nil, false
	}
	if len(targets) == 0 {
		return .All, nil, nil, true
	}

	has_relation_rights := .Read in rights || .Write in rights
	has_selector_rights := .Invoke in rights
	if has_relation_rights && has_selector_rights {
		vm.vm_set_error(
			state,
			"E_INVARG",
			"cannot combine read/write and invoke rights on named targets",
		)
		return .All, nil, nil, false
	}
	if has_relation_rights {
		relation_targets := make([]k.Relation_ID, len(targets), context.temp_allocator)
		for target, index in targets {
			name, name_ok := v.symbol_name(target)
			if !name_ok {
				vm.vm_set_error(state, "E_TYPE", "capability target is unknown")
				return .All, nil, nil, false
			}
			relation, found := env.ctx.relations[name]
			if !found {
				vm.vm_set_error(state, "E_INVARG", "capability target is not a relation")
				return .All, nil, nil, false
			}
			relation_targets[index] = k.Relation_ID(relation)
		}
		return .Relations, relation_targets, nil, true
	}
	if has_selector_rights {
		selector_targets := make([]v.Symbol, len(targets), context.temp_allocator)
		copy(selector_targets, targets[:])
		return .Selectors, nil, selector_targets, true
	}
	vm.vm_set_error(state, "E_INVARG", "effect and grant capabilities take no targets")
	return .All, nil, nil, false
}

// Parses a limits map: `:ttl_millis`, `:epochs`, or `:epoch_limit`.
@(private)
capability_limits_argument :: proc(
	state: ^vm.VM,
	env: ^Builtin_Env,
	value: v.Value,
) -> (
	limits: k.Capability_Limits,
	ok: bool,
) {
	entries, is_map := v.value_as_map(value)
	if !is_map {
		vm.vm_set_error(state, "E_TYPE", "capability limits must be a map")
		return {}, false
	}
	version := kernel_version(env)
	for entry in entries {
		key, key_ok := v.value_as_symbol(entry.key)
		if !key_ok {
			vm.vm_set_error(state, "E_TYPE", "capability limit keys must be symbols")
			return {}, false
		}
		name, name_ok := v.symbol_name(key)
		if !name_ok {
			continue
		}
		number, number_ok := v.value_as_int(entry.value)
		if !number_ok || number < 0 {
			vm.vm_set_error(state, "E_INVARG", "capability limits must be non-negative integers")
			return {}, false
		}
		switch name {
		case "ttl_millis":
			limits.deadline = time.tick_add(
				time.tick_now(),
				time.Duration(number) * time.Millisecond,
			)
		case "epochs":
			limits.epoch_limit = version + u64(number)
		case "epoch_limit":
			limits.epoch_limit = u64(number)
		}
	}
	return limits, true
}

@(private)
kernel_version :: proc(env: ^Builtin_Env) -> u64 {
	snapshot := k.kernel_snapshot(env.kernel)
	defer k.snapshot_release(snapshot)
	return snapshot.version
}

@(private)
builtin_enable_rule :: proc(state: ^vm.VM, args: []v.Value) -> (v.Value, bool) {
	return rule_active_builtin(state, args, true)
}

@(private)
builtin_disable_rule :: proc(state: ^vm.VM, args: []v.Value) -> (v.Value, bool) {
	return rule_active_builtin(state, args, false)
}

@(private)
rule_active_builtin :: proc(
	state: ^vm.VM,
	args: []v.Value,
	active: bool,
) -> (v.Value, bool) {
	env := builtin_env(state)
	if !k.authority_can_grant(state.authority) {
		return builtin_error(state, "E_PERMISSION", "rule administration denied")
	}
	if len(args) != 1 {
		return builtin_error(state, "E_INVARG", "rule administration expects a rule id")
	}
	rule_value := args[0]
	raw: u64
	if identity, is_identity := v.value_as_identity(rule_value); is_identity {
		raw = v.identity_raw(identity)
	} else if number, is_int := v.value_as_int(rule_value); is_int && number >= 0 {
		raw = u64(number)
	} else {
		return builtin_error(state, "E_TYPE", "rule id must be an identity or integer")
	}

	updated, err := k.kernel_set_rule_active(env.kernel, v.Identity(raw), active)
	if err != k.Kernel_Error.None {
		if err == .No_Such_Rule {
			return builtin_error(state, "E_INVARG", "unknown rule")
		}
		return builtin_error(state, "E_RULE", "rule update failed")
	}
	k.snapshot_release(updated)

	if state.transaction != nil {
		_ = k.transaction_retract(
			state.transaction,
			k.SYSTEM_ACTIVE_RULE_ID,
			v.tuple_new(env.allocator, []v.Value{rule_value, v.value_bool(!active)}),
		)
		_ = k.transaction_assert(
			state.transaction,
			k.SYSTEM_ACTIVE_RULE_ID,
			v.tuple_new(env.allocator, []v.Value{rule_value, v.value_bool(active)}),
		)
	}
	return v.value_bool(true), true
}

// Rule introspection: `rules(:Relation)` returns the active rule identities
// whose head relation matches the named relation; `describe_rule(#rule)`
// returns one rule's installed source.
@(private)
builtin_rules :: proc(state: ^vm.VM, args: []v.Value) -> (v.Value, bool) {
	if len(args) != 1 {
		return builtin_error(state, "E_INVARG", "rules expects rules(:Relation)")
	}
	name_symbol, is_symbol := v.value_as_symbol(args[0])
	if !is_symbol {
		return builtin_error(state, "E_TYPE", "rules expects a relation name symbol")
	}
	name, has_name := v.symbol_name(name_symbol)
	if !has_name {
		return builtin_error(state, "E_INVARG", "rules expects a named relation symbol")
	}
	env := builtin_env(state)
	relation_id, known := env.ctx.relations[name]
	if !known {
		return builtin_error(
			state,
			"E_INVARG",
			fmt.aprintf("unknown relation :%s", name, allocator = state.allocator),
		)
	}
	snapshot := k.kernel_snapshot(env.kernel)
	defer k.snapshot_release(snapshot)
	rule_ids: [dynamic]v.Value
	rule_ids = make([dynamic]v.Value, state.allocator)
	for definition in snapshot.rules {
		if !definition.active || definition.rule.head_relation != k.Relation_ID(relation_id) {
			continue
		}
		identity, identity_ok := v.value_identity_raw(u64(definition.id))
		if identity_ok {
			append(&rule_ids, identity)
		}
	}
	return v.value_list(state.allocator, rule_ids[:]), true
}

@(private)
builtin_describe_rule :: proc(state: ^vm.VM, args: []v.Value) -> (v.Value, bool) {
	if len(args) != 1 {
		return builtin_error(state, "E_INVARG", "describe_rule expects describe_rule(#rule)")
	}
	rule_value := args[0]
	raw: u64
	if identity, is_identity := v.value_as_identity(rule_value); is_identity {
		raw = v.identity_raw(identity)
	} else if number, is_int := v.value_as_int(rule_value); is_int && number >= 0 {
		raw = u64(number)
	} else {
		return builtin_error(state, "E_TYPE", "rule id must be an identity or integer")
	}
	env := builtin_env(state)
	snapshot := k.kernel_snapshot(env.kernel)
	defer k.snapshot_release(snapshot)
	for definition in snapshot.rules {
		if v.identity_raw(definition.id) != raw {
			continue
		}
		return v.value_string(state.allocator, definition.source), true
	}
	return builtin_error(state, "E_INVARG", "rule does not exist")
}

// `fileout(:unit)`: the source text loaded for a filein unit.
@(private)
builtin_fileout :: proc(state: ^vm.VM, args: []v.Value) -> (v.Value, bool) {
	if len(args) != 1 {
		return builtin_error(state, "E_INVARG", "fileout expects fileout(:unit)")
	}
	name_symbol, is_symbol := v.value_as_symbol(args[0])
	if !is_symbol {
		return builtin_error(state, "E_TYPE", "fileout expects a unit symbol")
	}
	name, has_name := v.symbol_name(name_symbol)
	if !has_name {
		return builtin_error(state, "E_INVARG", "fileout expects a named unit symbol")
	}
	env := builtin_env(state)
	source, found := env.unit_sources[name]
	if !found {
		return builtin_error(
			state,
			"E_INVARG",
			fmt.aprintf("unknown filein unit :%s", name, allocator = state.allocator),
		)
	}
	return v.value_string(state.allocator, source), true
}

// `fileout_rules([:Relation])`: active rule source, optionally filtered to one
// head relation. Rules are separated by a blank line.
@(private)
builtin_fileout_rules :: proc(state: ^vm.VM, args: []v.Value) -> (v.Value, bool) {
	if len(args) > 1 {
		return builtin_error(
			state,
			"E_INVARG",
			"fileout_rules expects fileout_rules() or fileout_rules(:Relation)",
		)
	}
	env := builtin_env(state)
	relation_id := k.Relation_ID(0)
	filter := false
	if len(args) == 1 {
		name_symbol, is_symbol := v.value_as_symbol(args[0])
		if !is_symbol {
			return builtin_error(state, "E_TYPE", "fileout_rules expects a relation name symbol")
		}
		name, has_name := v.symbol_name(name_symbol)
		if !has_name {
			return builtin_error(state, "E_INVARG", "fileout_rules expects a named relation symbol")
		}
		known_id, known := env.ctx.relations[name]
		if !known {
			return builtin_error(
				state,
				"E_INVARG",
				fmt.aprintf("unknown relation :%s", name, allocator = state.allocator),
			)
		}
		relation_id = k.Relation_ID(known_id)
		filter = true
	}
	snapshot := k.kernel_snapshot(env.kernel)
	defer k.snapshot_release(snapshot)
	builder: strings.Builder
	strings.builder_init(&builder, state.allocator)
	first := true
	for definition in snapshot.rules {
		if !definition.active {
			continue
		}
		if filter && definition.rule.head_relation != relation_id {
			continue
		}
		if !first {
			strings.write_string(&builder, "\n\n")
		}
		first = false
		strings.write_string(&builder, definition.source)
	}
	return v.value_string(state.allocator, strings.to_string(builder)), true
}

// `tasks()`: snapshots of managed tasks as `[:id, :state]` maps.
@(private)
builtin_tasks :: proc(state: ^vm.VM, args: []v.Value) -> (v.Value, bool) {
	if len(args) != 0 {
		return builtin_error(state, "E_INVARG", "tasks expects tasks()")
	}
	env := builtin_env(state)
	if env.scheduler == nil {
		return v.value_list(state.allocator, nil), true
	}
	return v.value_list(
		state.allocator,
		scheduler_task_values(env.scheduler, state.allocator),
	), true
}

@(private)
builtin_json_encode :: proc(state: ^vm.VM, args: []v.Value) -> (v.Value, bool) {
	builder: strings.Builder
	strings.builder_init(&builder, state.allocator)
	if !json_encode_value(&builder, args[0]) {
		strings.builder_destroy(&builder)
		return builtin_error(state, "E_INVARG", "value cannot be encoded as JSON")
	}
	return v.value_string(state.allocator, strings.to_string(builder)), true
}

@(private)
builtin_json_decode :: proc(state: ^vm.VM, args: []v.Value) -> (v.Value, bool) {
	text, text_ok := string_argument(state, args, 0, "json_decode")
	if !text_ok {
		return builtin_error(state, "E_TYPE", "json_decode expects a string")
	}
	value, message, decoded := json_decode_text(state.allocator, text)
	if !decoded {
		return builtin_error(state, "E_INVARG", message)
	}
	return value, true
}

@(private)
builtin_json_null :: proc(state: ^vm.VM, args: []v.Value) -> (v.Value, bool) {
	if len(args) != 0 {
		return builtin_error(state, "E_INVARG", "json_null expects no arguments")
	}
	return json_null(state.allocator), true
}

@(private)
builtin_json_is_null :: proc(state: ^vm.VM, args: []v.Value) -> (v.Value, bool) {
	if len(args) != 1 {
		return builtin_error(state, "E_INVARG", "json_is_null expects one argument")
	}
	return v.value_bool(json_value_is_null(args[0])), true
}

@(private)
builtin_subscribe_changes :: proc(state: ^vm.VM, args: []v.Value) -> (v.Value, bool) {
	env := builtin_env(state)
	if env.scheduler == nil {
		return builtin_error(state, "E_INVARG", "subscriptions need a running scheduler")
	}
	if len(args) < 5 || len(args) > 7 {
		return builtin_error(
			state,
			"E_INVARG",
			"subscribe_changes expects sender, subject, relation, bindings, initial[, cursor[, queue_budget]]",
		)
	}
	sender := args[0]
	if !scheduler_mailbox_sender_handle_live(env.scheduler, sender) {
		return builtin_error(state, "E_INVARG", "subscription sender must be a live mailbox sender")
	}

	subject_symbol, subject_ok := v.value_as_symbol(args[1])
	if !subject_ok {
		return builtin_error(state, "E_TYPE", "subscription subject must be a symbol")
	}
	subject_name, subject_name_ok := v.symbol_name(subject_symbol)
	subject: Subscription_Subject
	switch subject_name {
	case "facts":
		subject = .Facts
	case "relation":
		subject = .Relation
	case "catalogue":
		subject = .Catalogue
	case:
		subject_name_ok = false
	}
	if !subject_name_ok {
		return builtin_error(state, "E_INVARG", "unsupported subscription subject")
	}
	if subject == .Catalogue && !(state.authority == nil || state.authority.root) {
		return builtin_error(state, "E_PERMISSION", "catalogue subscriptions require root authority")
	}

	relation_value, has_relation := option_payload(args[2])
	relation_id: k.Relation_ID
	if subject == .Catalogue {
		if has_relation {
			return builtin_error(state, "E_INVARG", "catalogue subscriptions take no relation")
		}
	} else {
		if !has_relation {
			return builtin_error(state, "E_INVARG", "subscription needs a relation")
		}
		relation_symbol, relation_ok := v.value_as_symbol(relation_value)
		if !relation_ok {
			return builtin_error(state, "E_TYPE", "subscription relation must be a symbol")
		}
		relation_name, relation_name_ok := v.symbol_name(relation_symbol)
		if !relation_name_ok {
			return builtin_error(state, "E_INVARG", "unknown subscription relation")
		}
		relation, found := env.ctx.relations[relation_name]
		if !found {
			return builtin_error(state, "E_INVARG", "unknown subscription relation")
		}
		if !k.authority_can_read(state.authority, k.Relation_ID(relation)) {
			return builtin_error(state, "E_PERMISSION", "subscription relation read denied")
		}
		relation_id = k.Relation_ID(relation)
	}

	binding_list, bindings_ok := v.value_as_list(args[3])
	if !bindings_ok {
		return builtin_error(state, "E_TYPE", "subscription bindings must be a list")
	}
	if subject == .Catalogue && len(binding_list) != 0 {
		return builtin_error(state, "E_INVARG", "catalogue subscriptions take no bindings")
	}
	bindings := make([]v.Binding, len(binding_list), context.temp_allocator)
	for item, index in binding_list {
		payload, has_payload := option_payload(item)
		if has_payload {
			bindings[index] = v.binding_of(payload)
		} else {
			bindings[index] = v.Binding{}
		}
	}

	initial_symbol, initial_ok := v.value_as_symbol(args[4])
	if !initial_ok {
		return builtin_error(state, "E_TYPE", "subscription initial mode must be a symbol")
	}
	initial, initial_name_ok := v.symbol_name(initial_symbol)
	if !initial_name_ok || (initial != "changes" && initial != "snapshot") {
		return builtin_error(state, "E_INVARG", "unsupported subscription initial mode")
	}

	cursor := u64(0)
	has_cursor := false
	if len(args) >= 6 {
		if value, has := option_payload(args[5]); has {
			cursor_value, is_int := v.value_as_int(value)
			if !is_int || cursor_value < 0 {
				return builtin_error(state, "E_INVARG", "subscription cursor must be non-negative")
			}
			cursor = u64(cursor_value)
			has_cursor = true
		}
	}

	queue_budget := DEFAULT_SUBSCRIPTION_QUEUE_BUDGET
	if len(args) >= 7 && !v.value_is_empty_relation(args[6]) {
		budget_value, is_int := v.value_as_int(args[6])
		if !is_int || budget_value < 1 {
			return builtin_error(state, "E_INVARG", "queue budget must be positive")
		}
		queue_budget = int(budget_value)
	}

	capability, registered := subscriptions_register(
		env,
		sender,
		subject,
		relation_id,
		bindings,
		initial == "snapshot",
		cursor,
		has_cursor,
		queue_budget,
	)
	if !registered {
		return builtin_error(state, "E_SUBSCRIPTION", "cannot register subscription")
	}
	return capability, true
}

@(private)
builtin_cancel_subscription :: proc(state: ^vm.VM, args: []v.Value) -> (v.Value, bool) {
	env := builtin_env(state)
	if !subscriptions_cancel(env, args[0]) {
		return builtin_error(state, "E_INVARG", "unknown subscription")
	}
	return v.value_bool(true), true
}

// Unwraps a standard option value: some(x) yields (x, true), none false.
@(private)
option_payload :: proc(value: v.Value) -> (v.Value, bool) {
	relation, is_relation := v.value_as_relation(value)
	if !is_relation || len(relation.rows) == 0 {
		return v.Value(0), false
	}
	cells := v.tuple_values(relation.rows[0])
	if len(cells) == 0 {
		return v.Value(0), false
	}
	return cells[0], true
}

// --- Helpers ---------------------------------------------------------------
@(private)
builtin_error :: proc(state: ^vm.VM, code, message: string) -> (v.Value, bool) {
	vm.vm_set_error(state, code, message)
	return v.Value(0), false
}

@(private)
string_argument :: proc(
	state: ^vm.VM,
	args: []v.Value,
	index: int,
	name: string,
) -> (string, bool) {
	text, ok := v.value_as_string(args[index])
	if !ok {
		return "", false
	}
	_ = name
	return text, true
}

@(private)
option_none_value :: proc(alloc: mem.Allocator) -> v.Value {
	value, _ := v.value_relation(alloc, []v.Symbol{v.symbol_intern("value")}, nil)
	return value
}

@(private)
option_some_value :: proc(alloc: mem.Allocator, inner: v.Value) -> v.Value {
	value, _ := v.value_relation(
		alloc,
		[]v.Symbol{v.symbol_intern("value")},
		[]v.Tuple{v.tuple_new(alloc, []v.Value{inner})},
	)
	return value
}

@(private)
result_value :: proc(alloc: mem.Allocator, case_name: string, inner: v.Value) -> v.Value {
	value, _ := v.value_relation(
		alloc,
		[]v.Symbol{v.symbol_intern("case"), v.symbol_intern("value")},
		[]v.Tuple {
			v.tuple_new(alloc, []v.Value{v.value_symbol(v.symbol_intern(case_name)), inner}),
		},
	)
	return value
}

// --- Frob accessors --------------------------------------------------------

@(private)
builtin_frob_delegate :: proc(state: ^vm.VM, args: []v.Value) -> (v.Value, bool) {
	delegate, ok := v.value_frob_delegate(args[0])
	if !ok {
		return builtin_error(state, "E_TYPE", "frob_delegate expected a frob")
	}
	return v.value_identity(delegate), true
}

@(private)
builtin_frob_value :: proc(state: ^vm.VM, args: []v.Value) -> (v.Value, bool) {
	inner, ok := v.value_frob_value(args[0])
	if !ok {
		return builtin_error(state, "E_TYPE", "frob_value expected a frob")
	}
	return inner, true
}

@(private)
builtin_is_frob :: proc(state: ^vm.VM, args: []v.Value) -> (v.Value, bool) {
	_, ok := v.value_as_frob(args[0])
	return v.value_bool(ok), true
}

// --- Strings ---------------------------------------------------------------

@(private)
builtin_string_len :: proc(state: ^vm.VM, args: []v.Value) -> (v.Value, bool) {
	text, ok := string_argument(state, args, 0, "string_len")
	if !ok {
		return builtin_error(state, "E_TYPE", "string_len expects a string")
	}
	result, value_ok := v.value_int(i64(utf8.rune_count_in_string(text)))
	if !value_ok {
		return builtin_error(state, "E_RANGE", "string length is out of range")
	}
	return result, true
}

@(private)
builtin_string_chars :: proc(state: ^vm.VM, args: []v.Value) -> (v.Value, bool) {
	text, ok := string_argument(state, args, 0, "string_chars")
	if !ok {
		return builtin_error(state, "E_TYPE", "string_chars expects a string")
	}
	values := make([dynamic]v.Value, 0, utf8.rune_count_in_string(text), state.allocator)
	for ch in text {
		buf, size := utf8.encode_rune(ch)
		append(&values, v.value_string(state.allocator, string(buf[:size])))
	}
	return v.value_list(state.allocator, values[:]), true
}

@(private)
builtin_string_slice :: proc(state: ^vm.VM, args: []v.Value) -> (v.Value, bool) {
	text, ok := string_argument(state, args, 0, "string_slice")
	if !ok {
		return builtin_error(state, "E_TYPE", "string_slice expects a string")
	}
	start, start_ok := v.value_as_int(args[1])
	end, end_ok := v.value_as_int(args[2])
	if !start_ok || !end_ok {
		return builtin_error(state, "E_TYPE", "string_slice expects integer positions")
	}
	char_len := utf8.rune_count_in_string(text)
	if start < 0 || start > end || end > i64(char_len) {
		return builtin_error(state, "E_INDEX", "string_slice bounds are invalid")
	}

	byte_start := len(text)
	byte_end := len(text)
	if end < i64(char_len) || start < i64(char_len) {
		position := 0
		for offset := 0; offset < len(text); {
			if position == int(start) {
				byte_start = offset
			}
			if position == int(end) {
				byte_end = offset
				break
			}
			_, size := utf8.decode_rune_in_string(text[offset:])
			offset += size
			position += 1
		}
	}
	return v.value_string(state.allocator, text[byte_start:byte_end]), true
}

@(private)
builtin_string_from_chars :: proc(state: ^vm.VM, args: []v.Value) -> (v.Value, bool) {
	chars, ok := v.value_as_list(args[0])
	if !ok {
		return builtin_error(state, "E_TYPE", "string_from_chars expects a list")
	}
	builder: strings.Builder
	strings.builder_init(&builder, state.allocator)
	defer strings.builder_destroy(&builder)
	for ch in chars {
		part, part_ok := v.value_as_string(ch)
		if !part_ok {
			return builtin_error(state, "E_TYPE", "string_from_chars expects string elements")
		}
		strings.write_string(&builder, part)
	}
	return v.value_string(state.allocator, strings.to_string(builder)), true
}

@(private)
builtin_string_concat :: proc(state: ^vm.VM, args: []v.Value) -> (v.Value, bool) {
	builder: strings.Builder
	strings.builder_init(&builder, state.allocator)
	defer strings.builder_destroy(&builder)
	for part in args {
		text, ok := v.value_as_string(part)
		if !ok {
			return builtin_error(state, "E_TYPE", "string_concat expects strings")
		}
		strings.write_string(&builder, text)
	}
	return v.value_string(state.allocator, strings.to_string(builder)), true
}

@(private)
builtin_string_join :: proc(state: ^vm.VM, args: []v.Value) -> (v.Value, bool) {
	parts, ok := v.value_as_list(args[0])
	if !ok {
		return builtin_error(state, "E_TYPE", "string_join expects a string list")
	}
	separator, separator_ok := v.value_as_string(args[1])
	if !separator_ok {
		return builtin_error(state, "E_TYPE", "string_join expects a string separator")
	}
	builder: strings.Builder
	strings.builder_init(&builder, state.allocator)
	defer strings.builder_destroy(&builder)
	for part, index in parts {
		text, part_ok := v.value_as_string(part)
		if !part_ok {
			return builtin_error(state, "E_TYPE", "string_join expects string elements")
		}
		if index > 0 {
			strings.write_string(&builder, separator)
		}
		strings.write_string(&builder, text)
	}
	return v.value_string(state.allocator, strings.to_string(builder)), true
}

@(private)
builtin_string_starts_with :: proc(state: ^vm.VM, args: []v.Value) -> (v.Value, bool) {
	text, text_ok := v.value_as_string(args[0])
	prefix, prefix_ok := v.value_as_string(args[1])
	if !text_ok || !prefix_ok {
		return builtin_error(state, "E_TYPE", "string_starts_with expects strings")
	}
	return v.value_bool(strings.has_prefix(text, prefix)), true
}

@(private)
builtin_string_contains :: proc(state: ^vm.VM, args: []v.Value) -> (v.Value, bool) {
	text, text_ok := v.value_as_string(args[0])
	subject, subject_ok := v.value_as_string(args[1])
	if !text_ok || !subject_ok {
		return builtin_error(state, "E_TYPE", "string_contains expects strings")
	}
	return v.value_bool(strings.contains(text, subject)), true
}

@(private)
builtin_string_equal_fold :: proc(state: ^vm.VM, args: []v.Value) -> (v.Value, bool) {
	left, left_ok := v.value_as_string(args[0])
	right, right_ok := v.value_as_string(args[1])
	if !left_ok || !right_ok {
		return builtin_error(state, "E_TYPE", "string_equal_fold expects strings")
	}
	folded_left, _ := strings.to_lower(left, state.allocator)
	folded_right, _ := strings.to_lower(right, state.allocator)
	return v.value_bool(folded_left == folded_right), true
}

@(private)
builtin_lower :: proc(state: ^vm.VM, args: []v.Value) -> (v.Value, bool) {
	text, ok := string_argument(state, args, 0, "lower")
	if !ok {
		return builtin_error(state, "E_TYPE", "lower expects a string")
	}
	lowered, _ := strings.to_lower(text, state.allocator)
	return v.value_string(state.allocator, lowered), true
}

// --- Collections -----------------------------------------------------------

@(private)
builtin_words :: proc(state: ^vm.VM, args: []v.Value) -> (v.Value, bool) {
	text, ok := string_argument(state, args, 0, "words")
	if !ok {
		return builtin_error(state, "E_TYPE", "words expects a string")
	}
	words := make([dynamic]v.Value, state.allocator)
	current: strings.Builder
	strings.builder_init(&current, state.allocator)
	defer strings.builder_destroy(&current)
	in_quotes := false
	escaped := false
	flush :: proc(
		state: ^vm.VM,
		current: ^strings.Builder,
		words: ^[dynamic]v.Value,
	) {
		if strings.builder_len(current^) == 0 {
			return
		}
		append(words, v.value_string(state.allocator, strings.to_string(current^)))
		strings.builder_reset(current)
	}
	for ch in text {
		if escaped {
			strings.write_rune(&current, ch)
			escaped = false
			continue
		}
		if ch == '\\' {
			escaped = true
			continue
		}
		if ch == '"' {
			in_quotes = !in_quotes
			continue
		}
		if unicode_is_space(ch) && !in_quotes {
			flush(state, &current, &words)
			continue
		}
		strings.write_rune(&current, ch)
	}
	if escaped {
		strings.write_rune(&current, '\\')
	}
	flush(state, &current, &words)
	return v.value_list(state.allocator, words[:]), true
}

@(private)
unicode_is_space :: proc(ch: rune) -> bool {
	switch ch {
	case ' ', '\t', '\n', '\r', '\v', '\f', 0x85, 0xA0:
		return true
	}
	return false
}

@(private)
builtin_sort :: proc(state: ^vm.VM, args: []v.Value) -> (v.Value, bool) {
	values, ok := v.value_as_list(args[0])
	if !ok {
		return builtin_error(state, "E_TYPE", "sort expects a list")
	}
	sorted := make([]v.Value, len(values), state.allocator)
	copy(sorted, values)
	slice.sort_by(sorted, proc(a, b: v.Value) -> bool {
		return v.value_cmp(a, b) == .Less
	})
	return v.value_list(state.allocator, sorted), true
}

@(private)
builtin_list_slice :: proc(state: ^vm.VM, args: []v.Value) -> (v.Value, bool) {
	items, is_list := v.value_as_list(args[0])
	if !is_list {
		return v.value_list(state.allocator, nil), true
	}
	start, start_ok := v.value_as_int(args[1])
	end, end_ok := v.value_as_int(args[2])
	if !start_ok || !end_ok {
		return builtin_error(state, "E_TYPE", "__list_slice bounds must be integers")
	}
	length := i64(len(items))
	if end < 0 {
		end = length
	}
	if start < 0 || start > length || end < start || end > length {
		return v.value_list(state.allocator, nil), true
	}
	return v.value_list(state.allocator, items[int(start):int(end)]), true
}

// Returns some(length) for a list, map, or relation, and none otherwise.
@(private)
builtin_len_option :: proc(state: ^vm.VM, args: []v.Value) -> (v.Value, bool) {
	length := 0
	#partial switch v.value_kind(args[0]) {
	case .List:
		values, _ := v.value_as_list(args[0])
		length = len(values)
	case .Map:
		entries, _ := v.value_as_map(args[0])
		length = len(entries)
	case .Relation:
		relation, _ := v.value_as_relation(args[0])
		length = len(relation.rows)
	case:
		return option_none_value(state.allocator), true
	}
	converted, converted_ok := v.value_int(i64(length))
	if !converted_ok {
		return option_none_value(state.allocator), true
	}
	return option_some_value(state.allocator, converted), true
}

// Looks up a collection element for pattern matching. Returns some(value)
// when present and none otherwise; never raises.
@(private)
builtin_index_option :: proc(state: ^vm.VM, args: []v.Value) -> (v.Value, bool) {
	collection := args[0]
	key := args[1]
	#partial switch v.value_kind(collection) {
	case .List:
		items, _ := v.value_as_list(collection)
		index, index_ok := v.value_as_int(key)
		if index_ok && index >= 0 && int(index) < len(items) {
			return option_some_value(state.allocator, items[index]), true
		}
	case .Map:
		entries, _ := v.value_as_map(collection)
		for entry in entries {
			if v.value_eq(entry.key, key) {
				return option_some_value(state.allocator, entry.value), true
			}
		}
	case .Relation:
		relation, _ := v.value_as_relation(collection)
		if len(relation.rows) == 0 {
			return option_none_value(state.allocator), true
		}
		symbol, symbol_ok := v.value_as_symbol(key)
		if symbol_ok {
			for column, position in relation.heading {
				if column == symbol {
					values := v.tuple_values(relation.rows[0])
					return option_some_value(state.allocator, values[position]), true
				}
			}
		}
	case:
	}
	return option_none_value(state.allocator), true
}

@(private)
builtin_list_concat :: proc(state: ^vm.VM, args: []v.Value) -> (v.Value, bool) {
	values := make([dynamic]v.Value, 0, 8, state.allocator)
	defer delete(values)
	for part in args {
		items, ok := v.value_as_list(part)
		if !ok {
			return builtin_error(state, "E_TYPE", "__list_concat expects lists")
		}
		for item in items {
			append(&values, item)
		}
	}
	return v.value_list(state.allocator, values[:]), true
}

@(private)
builtin_set_index :: proc(state: ^vm.VM, args: []v.Value) -> (v.Value, bool) {
	collection := args[0]
	index := args[1]
	value := args[2]

	if values, is_list := v.value_as_list(collection); is_list {
		position, ok := v.value_as_int(index)
		if !ok || position < 0 || position >= i64(len(values)) {
			return builtin_error(state, "E_INDEX", "list index is missing or invalid")
		}
		updated := make([]v.Value, len(values), state.allocator)
		copy(updated, values)
		updated[position] = value
		return v.value_list(state.allocator, updated), true
	}

	if entries, is_map := v.value_as_map(collection); is_map {
		updated := make([dynamic]v.Map_Entry, 0, len(entries) + 1, state.allocator)
		replaced := false
		for entry in entries {
			if v.value_eq(entry.key, index) {
				append(&updated, v.Map_Entry{key = entry.key, value = value})
				replaced = true
			} else {
				append(&updated, entry)
			}
		}
		if !replaced {
			append(&updated, v.Map_Entry{key = index, value = value})
		}
		return v.value_map(state.allocator, updated[:]), true
	}

	return builtin_error(state, "E_INDEX", "collection index is missing or invalid")
}

@(private)
builtin_map_pairs :: proc(state: ^vm.VM, args: []v.Value) -> (v.Value, bool) {
	entries, ok := v.value_as_map(args[0])
	if !ok {
		return builtin_error(state, "E_TYPE", "map_pairs expects a map")
	}
	pairs := make([]v.Value, len(entries), state.allocator)
	for entry, index in entries {
		pairs[index] = v.value_list(state.allocator, []v.Value{entry.key, entry.value})
	}
	return v.value_list(state.allocator, pairs), true
}

@(private)
builtin_index_or :: proc(state: ^vm.VM, args: []v.Value) -> (v.Value, bool) {
	collection := args[0]
	index := args[1]
	default := args[2]

	if entries, is_map := v.value_as_map(collection); is_map {
		for entry in entries {
			if v.value_eq(entry.key, index) {
				return entry.value, true
			}
		}
		return default, true
	}

	if values, is_list := v.value_as_list(collection); is_list {
		position, ok := v.value_as_int(index)
		if !ok || position < 0 {
			return builtin_error(state, "E_TYPE", "list indexes must be non-negative integers")
		}
		if position >= i64(len(values)) {
			return default, true
		}
		return values[position], true
	}

	if relation, is_relation := v.value_as_relation(collection); is_relation {
		position, ok := v.value_as_int(index)
		if !ok || position < 0 {
			return builtin_error(state, "E_TYPE", "relation indexes must be non-negative integers")
		}
		if position >= i64(len(relation.rows)) {
			return default, true
		}
		row := v.tuple_values(relation.rows[position])
		entries := make([]v.Map_Entry, len(relation.heading), state.allocator)
		for column, column_index in relation.heading {
			entries[column_index] = v.Map_Entry {
				key   = v.value_symbol(column),
				value = row[column_index],
			}
		}
		return v.value_map(state.allocator, entries), true
	}

	return builtin_error(state, "E_TYPE", "index_or expects a map, list, or relation")
}

// --- Relation value algebra ------------------------------------------------

// Reports whether two relation values have the same heading.
@(private)
relation_headings_equal :: proc(left, right: ^v.Relation_Value) -> bool {
	if len(left.heading) != len(right.heading) {
		return false
	}
	for column, index in left.heading {
		if column != right.heading[index] {
			return false
		}
	}
	return true
}

@(private)
relation_argument :: proc(args: []v.Value, index: int) -> (^v.Relation_Value, bool) {
	relation, is_relation := v.value_as_relation(args[index])
	if !is_relation {
		return nil, false
	}
	return relation, true
}

@(private)
builtin_project :: proc(state: ^vm.VM, args: []v.Value) -> (v.Value, bool) {
	if len(args) < 1 {
		return builtin_error(state, "E_INVARG", "project expects project(relation, :column, ...)")
	}
	relation, is_relation := v.value_as_relation(args[0])
	if !is_relation {
		return builtin_error(state, "E_TYPE", "project expects a relation argument")
	}
	if len(args) == 1 {
		// The zero-column projection: an existence test as a relation.
		rows := make([]v.Tuple, len(relation.rows), context.temp_allocator)
		for _, index in relation.rows {
			rows[index] = v.tuple_new(state.allocator, nil)
		}
		empty_heading := make([]v.Symbol, 0, context.temp_allocator)
		value, relation_error := v.value_relation(state.allocator, empty_heading, rows)
		if relation_error != .None {
			return builtin_error(state, "E_INVARG", "project could not build a relation")
		}
		return value, true
	}

	positions := make([]int, len(args) - 1, context.temp_allocator)
	for argument, index in args[1:] {
		column, is_symbol := v.value_as_symbol(argument)
		if !is_symbol {
			return builtin_error(state, "E_TYPE", "project expects symbol column arguments")
		}
		position := -1
		for name, name_index in relation.heading {
			if name == column {
				position = name_index
				break
			}
		}
		if position < 0 {
			column_name, _ := v.symbol_name(column)
			return builtin_error(
				state,
				"E_INVARG",
				fmt.aprintf(
					"relation has no column :%s",
					column_name,
					allocator = state.allocator,
				),
			)
		}
		positions[index] = position
	}

	heading := make([]v.Symbol, len(positions), context.temp_allocator)
	for position, index in positions {
		heading[index] = relation.heading[position]
	}
	rows := make([]v.Tuple, len(relation.rows), context.temp_allocator)
	for row, row_index in relation.rows {
		values := v.tuple_values(row)
		selected := make([]v.Value, len(positions), context.temp_allocator)
		for position, index in positions {
			selected[index] = values[position]
		}
		rows[row_index] = v.tuple_new(state.allocator, selected)
	}
	value, relation_error := v.value_relation(state.allocator, heading, rows)
	if relation_error != .None {
		return builtin_error(state, "E_INVARG", "project could not build a relation")
	}
	return value, true
}

@(private)
builtin_union :: proc(state: ^vm.VM, args: []v.Value) -> (v.Value, bool) {
	if len(args) != 2 {
		return builtin_error(state, "E_INVARG", "union expects union(left, right)")
	}
	left, left_ok := relation_argument(args, 0)
	if !left_ok {
		return builtin_error(state, "E_TYPE", "union expects relation arguments")
	}
	right, right_ok := relation_argument(args, 1)
	if !right_ok {
		return builtin_error(state, "E_TYPE", "union expects relation arguments")
	}
	if !relation_headings_equal(left, right) {
		return builtin_error(state, "E_INVARG", "relation headings are incompatible")
	}
	rows: [dynamic]v.Tuple
	rows = make([dynamic]v.Tuple, 0, len(left.rows) + len(right.rows), context.temp_allocator)
	append(&rows, ..left.rows)
	append(&rows, ..right.rows)
	value, relation_error := v.value_relation(state.allocator, left.heading, rows[:])
	if relation_error != .None {
		return builtin_error(state, "E_INVARG", "union could not build a relation")
	}
	return value, true
}

@(private)
builtin_difference :: proc(state: ^vm.VM, args: []v.Value) -> (v.Value, bool) {
	if len(args) != 2 {
		return builtin_error(state, "E_INVARG", "difference expects difference(left, right)")
	}
	left, left_ok := relation_argument(args, 0)
	if !left_ok {
		return builtin_error(state, "E_TYPE", "difference expects relation arguments")
	}
	right, right_ok := relation_argument(args, 1)
	if !right_ok {
		return builtin_error(state, "E_TYPE", "difference expects relation arguments")
	}
	if !relation_headings_equal(left, right) {
		return builtin_error(state, "E_INVARG", "relation headings are incompatible")
	}
	rows: [dynamic]v.Tuple
	rows = make([dynamic]v.Tuple, 0, len(left.rows), context.temp_allocator)
	for row in left.rows {
		found := false
		for other in right.rows {
			if v.tuple_cmp(row, other) == .Equal {
				found = true
				break
			}
		}
		if !found {
			append(&rows, row)
		}
	}
	value, relation_error := v.value_relation(state.allocator, left.heading, rows[:])
	if relation_error != .None {
		return builtin_error(state, "E_INVARG", "difference could not build a relation")
	}
	return value, true
}

@(private)
builtin_natural_join :: proc(state: ^vm.VM, args: []v.Value) -> (v.Value, bool) {
	if len(args) != 2 {
		return builtin_error(state, "E_INVARG", "natural_join expects natural_join(left, right)")
	}
	left, left_ok := relation_argument(args, 0)
	if !left_ok {
		return builtin_error(state, "E_TYPE", "natural_join expects relation arguments")
	}
	right, right_ok := relation_argument(args, 1)
	if !right_ok {
		return builtin_error(state, "E_TYPE", "natural_join expects relation arguments")
	}

	left_positions := make([dynamic]int, 0, len(left.heading), context.temp_allocator)
	right_positions := make([dynamic]int, 0, len(left.heading), context.temp_allocator)
	for column, left_position in left.heading {
		for name, right_position in right.heading {
			if name != column {
				continue
			}
			append(&left_positions, left_position)
			append(&right_positions, right_position)
			break
		}
	}
	right_only := make([dynamic]int, 0, len(right.heading), context.temp_allocator)
	for column, right_position in right.heading {
		shared := false
		for name in left.heading {
			if name == column {
				shared = true
				break
			}
		}
		if !shared {
			append(&right_only, right_position)
		}
	}

	heading: [dynamic]v.Symbol
	heading = make([dynamic]v.Symbol, 0, len(left.heading) + len(right_only), context.temp_allocator)
	append(&heading, ..left.heading)
	for position in right_only {
		append(&heading, right.heading[position])
	}

	rows: [dynamic]v.Tuple
	rows = make([dynamic]v.Tuple, 0, 16, context.temp_allocator)
	for left_row in left.rows {
		left_values := v.tuple_values(left_row)
		for right_row in right.rows {
			right_values := v.tuple_values(right_row)
			matched := true
			for shared_index in 0 ..< len(left_positions) {
				left_value := left_values[left_positions[shared_index]]
				right_value := right_values[right_positions[shared_index]]
				if !v.value_eq(left_value, right_value) {
					matched = false
					break
				}
			}
			if !matched {
				continue
			}
			combined: [dynamic]v.Value
			combined = make([dynamic]v.Value, 0, len(left_values) + len(right_only), context.temp_allocator)
			append(&combined, ..left_values)
			for position in right_only {
				append(&combined, right_values[position])
			}
			append(&rows, v.tuple_new(state.allocator, combined[:]))
		}
	}
	value, relation_error := v.value_relation(state.allocator, heading[:], rows[:])
	if relation_error != .None {
		return builtin_error(state, "E_INVARG", "natural_join could not build a relation")
	}
	return value, true
}

// --- Text utilities --------------------------------------------------------

@(private)
builtin_edit_distance :: proc(state: ^vm.VM, args: []v.Value) -> (v.Value, bool) {
	left, left_ok := v.value_as_string(args[0])
	right, right_ok := v.value_as_string(args[1])
	if !left_ok || !right_ok {
		return builtin_error(state, "E_TYPE", "edit_distance expects strings")
	}
	distance := levenshtein_chars(left, right)
	result, value_ok := v.value_int(i64(distance))
	if !value_ok {
		return builtin_error(state, "E_RANGE", "edit distance is out of range")
	}
	return result, true
}

@(private)
levenshtein_chars :: proc(left, right: string) -> int {
	left_runes := utf8.string_to_runes(left, context.temp_allocator)
	right_runes := utf8.string_to_runes(right, context.temp_allocator)
	if len(left_runes) == 0 {
		return len(right_runes)
	}
	if len(right_runes) == 0 {
		return len(left_runes)
	}

	previous := make([]int, len(right_runes) + 1, context.temp_allocator)
	current := make([]int, len(right_runes) + 1, context.temp_allocator)
	for index in 0 ..= len(right_runes) {
		previous[index] = index
	}
	for left_index in 0 ..< len(left_runes) {
		current[0] = left_index + 1
		for right_index in 0 ..< len(right_runes) {
			substitution := 0
			if left_runes[left_index] != right_runes[right_index] {
				substitution = 1
			}
			insert := previous[right_index + 1] + 1
			delete := current[right_index] + 1
			substitute := previous[right_index] + substitution
			best := min(insert, delete)
			current[right_index + 1] = min(best, substitute)
		}
		swap := previous
		previous = current
		current = swap
	}
	return previous[len(right_runes)]
}

@(private)
builtin_parse_ordinal :: proc(state: ^vm.VM, args: []v.Value) -> (v.Value, bool) {
	text, ok := string_argument(state, args, 0, "parse_ordinal")
	if !ok {
		return builtin_error(state, "E_TYPE", "parse_ordinal expects a string")
	}
	lowered, _ := strings.to_lower(strings.trim_space(text), state.allocator)
	if value, found := parse_ordinal_text(lowered); found {
		return result_value(state.allocator, "ok", value_int_must(value)), true
	}
	problem := v.value_error(
		state.allocator,
		v.symbol_intern("E_PARSE"),
		"invalid ordinal",
		true,
		v.value_string(state.allocator, text),
		true,
	)
	return result_value(state.allocator, "error", problem), true
}

@(private)
value_int_must :: proc(value: i64) -> v.Value {
	result, _ := v.value_int(value)
	return result
}

@(private)
parse_ordinal_text :: proc(text: string) -> (i64, bool) {
	if len(text) == 0 {
		return 0, false
	}
	if number, numeric := parse_numeric_ordinal(text); numeric {
		return number, true
	}
	total := i64(0)
	remaining := text
	for len(remaining) > 0 {
		part := remaining
		if index := strings.index_byte(remaining, '-'); index >= 0 {
			part = remaining[:index]
			remaining = remaining[index + 1:]
		} else {
			remaining = ""
		}
		value, known := simple_ordinal_value(part)
		if !known {
			return 0, false
		}
		total += value
	}
	if total <= 0 {
		return 0, false
	}
	return total, true
}

@(private)
parse_numeric_ordinal :: proc(text: string) -> (i64, bool) {
	trimmed := text
	for suffix in ([]string{"st", "nd", "rd", "th"}) {
		if strings.has_suffix(trimmed, suffix) {
			trimmed = trimmed[:len(trimmed) - len(suffix)]
			break
		}
	}
	if strings.has_suffix(trimmed, ".") {
		trimmed = trimmed[:len(trimmed) - 1]
	}
	value, _ := strconv_parse_i64(trimmed)
	if value <= 0 {
		return 0, false
	}
	return value, true
}

@(private)
strconv_parse_i64 :: proc(text: string) -> (i64, bool) {
	value: i64
	negative := false
	for index in 0 ..< len(text) {
		ch := text[index]
		if index == 0 && ch == '-' {
			negative = true
			continue
		}
		if ch < '0' || ch > '9' {
			return 0, false
		}
		value = value * 10 + i64(ch - '0')
	}
	if negative {
		value = -value
	}
	return value, true
}

@(private)
simple_ordinal_value :: proc(text: string) -> (i64, bool) {
	switch text {
	case "first":
		return 1, true
	case "second":
		return 2, true
	case "third":
		return 3, true
	case "fourth":
		return 4, true
	case "fifth":
		return 5, true
	case "sixth":
		return 6, true
	case "seventh":
		return 7, true
	case "eighth":
		return 8, true
	case "ninth":
		return 9, true
	case "tenth":
		return 10, true
	case "eleventh":
		return 11, true
	case "twelfth":
		return 12, true
	case "thirteenth":
		return 13, true
	case "fourteenth":
		return 14, true
	case "fifteenth":
		return 15, true
	case "sixteenth":
		return 16, true
	case "seventeenth":
		return 17, true
	case "eighteenth":
		return 18, true
	case "nineteenth":
		return 19, true
	case "twentieth":
		return 20, true
	case "thirtieth":
		return 30, true
	case "fortieth":
		return 40, true
	case "fiftieth":
		return 50, true
	case "sixtieth":
		return 60, true
	case "seventieth":
		return 70, true
	case "eightieth":
		return 80, true
	case "ninetieth":
		return 90, true
	case "hundred":
		return 100, true
	case "thousand":
		return 1000, true
	}
	return 0, false
}

@(private)
builtin_to_symbol :: proc(state: ^vm.VM, args: []v.Value) -> (v.Value, bool) {
	if _, already := v.value_as_symbol(args[0]); already {
		return args[0], true
	}
	text, ok := v.value_as_string(args[0])
	if !ok {
		return builtin_error(state, "E_TYPE", "to_symbol expects a string")
	}
	return v.value_symbol(v.symbol_intern(text)), true
}

// --- URL components --------------------------------------------------------

@(private)
builtin_url_encode_component :: proc(state: ^vm.VM, args: []v.Value) -> (v.Value, bool) {
	text, ok := string_argument(state, args, 0, "url_encode_component")
	if !ok {
		return builtin_error(state, "E_TYPE", "url_encode_component expects a string")
	}
	builder: strings.Builder
	strings.builder_init(&builder, state.allocator)
	defer strings.builder_destroy(&builder)
	for index in 0 ..< len(text) {
		byte := text[index]
		if is_url_unreserved(byte) {
			strings.write_byte(&builder, byte)
		} else {
			fmt.sbprintf(&builder, "%%%02X", byte)
		}
	}
	return v.value_string(state.allocator, strings.to_string(builder)), true
}

@(private)
is_url_unreserved :: proc(byte: u8) -> bool {
	if byte >= 'a' && byte <= 'z' {
		return true
	}
	if byte >= 'A' && byte <= 'Z' {
		return true
	}
	if byte >= '0' && byte <= '9' {
		return true
	}
	return byte == '-' || byte == '_' || byte == '.' || byte == '~'
}

@(private)
builtin_url_decode_component :: proc(state: ^vm.VM, args: []v.Value) -> (v.Value, bool) {
	text, ok := string_argument(state, args, 0, "url_decode_component")
	if !ok {
		return builtin_error(state, "E_TYPE", "url_decode_component expects a string")
	}
	bytes := make([dynamic]u8, 0, len(text), state.allocator)
	defer delete(bytes)
	index := 0
	for index < len(text) {
		byte := text[index]
		switch byte {
		case '%':
			if index + 2 >= len(text) {
				return builtin_error(state, "E_URL", "incomplete percent escape")
			}
			high, high_ok := hex_value(text[index + 1])
			low, low_ok := hex_value(text[index + 2])
			if !high_ok || !low_ok {
				return builtin_error(state, "E_URL", "invalid percent escape")
			}
			append(&bytes, high << 4 | low)
			index += 3
		case '+':
			append(&bytes, ' ')
			index += 1
		case:
			append(&bytes, byte)
			index += 1
		}
	}
	if !utf8.valid_string(string(bytes[:])) {
		return builtin_error(state, "E_URL", "decoded component is not valid UTF-8")
	}
	return v.value_string(state.allocator, string(bytes[:])), true
}

@(private)
hex_value :: proc(byte: u8) -> (u8, bool) {
	switch byte {
	case '0' ..= '9':
		return byte - '0', true
	case 'a' ..= 'f':
		return byte - 'a' + 10, true
	case 'A' ..= 'F':
		return byte - 'A' + 10, true
	}
	return 0, false
}

// --- Host ------------------------------------------------------------------

@(private)
builtin_os_getenv :: proc(state: ^vm.VM, args: []v.Value) -> (v.Value, bool) {
	name, ok := string_argument(state, args, 0, "os_getenv")
	if !ok {
		return builtin_error(state, "E_TYPE", "os_getenv expects a string")
	}
	value, found := os.lookup_env(name, state.allocator)
	if !found {
		return option_none_value(state.allocator), true
	}
	return option_some_value(state.allocator, v.value_string(state.allocator, value)), true
}

// --- Literals --------------------------------------------------------------

@(private)
builtin_to_literal :: proc(state: ^vm.VM, args: []v.Value) -> (v.Value, bool) {
	if !v.value_is_persistable(args[0]) {
		return builtin_error(state, "E_TYPE", "this value does not have a source literal")
	}
	env := builtin_env(state)
	builder: strings.Builder
	strings.builder_init(&builder, state.allocator)
	defer strings.builder_destroy(&builder)
	write_source_literal(&builder, env, args[0])
	return v.value_string(state.allocator, strings.to_string(builder)), true
}

@(private)
write_source_literal :: proc(builder: ^strings.Builder, env: ^Builtin_Env, value: v.Value) {
	tag := v.value_tag(value)
	#partial switch tag {
	case .Bool:
		flag, _ := v.value_as_bool(value)
		strings.write_string(builder, flag ? "true" : "false")
	case .Int:
		number, _ := v.value_as_int(value)
		fmt.sbprintf(builder, "%d", number)
	case .Float:
		number, _ := v.value_as_float(value)
		fmt.sbprintf(builder, "%v", number)
	case .Identity:
		identity, _ := v.value_as_identity(value)
		if name, found := identity_name(env, identity); found {
			strings.write_string(builder, "#")
			strings.write_string(builder, name)
		} else {
			fmt.sbprintf(builder, "#%d", v.identity_raw(identity))
		}
	case .Symbol:
		symbol, _ := v.value_as_symbol(value)
		name, _ := v.symbol_name(symbol)
		strings.write_string(builder, ":")
		strings.write_string(builder, name)
	case .String:
		text, _ := v.value_as_string(value)
		write_quoted_string(builder, text)
	case .List:
		values, _ := v.value_as_list(value)
		strings.write_string(builder, "[")
		for item, index in values {
			if index > 0 {
				strings.write_string(builder, ", ")
			}
			write_source_literal(builder, env, item)
		}
		strings.write_string(builder, "]")
	case .Map:
		entries, _ := v.value_as_map(value)
		strings.write_string(builder, "{")
		for entry, index in entries {
			if index > 0 {
				strings.write_string(builder, ", ")
			}
			write_source_literal(builder, env, entry.key)
			strings.write_string(builder, " -> ")
			write_source_literal(builder, env, entry.value)
		}
		strings.write_string(builder, "}")
	case .Frob:
		delegate, _ := v.value_frob_delegate(value)
		inner, _ := v.value_frob_value(value)
		strings.write_string(builder, "#")
		if name, found := identity_name(env, delegate); found {
			strings.write_string(builder, name)
		} else {
			fmt.sbprintf(builder, "%d", v.identity_raw(delegate))
		}
		strings.write_string(builder, "<")
		write_source_literal(builder, env, inner)
		strings.write_string(builder, ">")
	case .Range:
		start, end, has_end, _ := v.value_as_range(value)
		write_source_literal(builder, env, start)
		strings.write_string(builder, "..")
		if has_end {
			write_source_literal(builder, env, end)
		} else {
			strings.write_string(builder, "_")
		}
	case .Relation:
		relation, _ := v.value_as_relation(value)
		strings.write_string(builder, "[")
		for column, index in relation.heading {
			if index > 0 {
				strings.write_string(builder, ", ")
			}
			strings.write_string(builder, ":")
			name, _ := v.symbol_name(column)
			strings.write_string(builder, name)
		}
		strings.write_string(builder, "] {")
		for row, row_index in relation.rows {
			if row_index > 0 {
				strings.write_string(builder, ", ")
			}
			strings.write_string(builder, "[")
			for cell, cell_index in v.tuple_values(row) {
				if cell_index > 0 {
					strings.write_string(builder, ", ")
				}
				write_source_literal(builder, env, cell)
			}
			strings.write_string(builder, "]")
		}
		strings.write_string(builder, "}")
	case:
		strings.write_string(builder, v.value_to_string(value, context.temp_allocator))
	}
}

@(private)
write_quoted_string :: proc(builder: ^strings.Builder, text: string) {
	strings.write_byte(builder, '"')
	for ch in text {
		switch ch {
		case '"':
			strings.write_string(builder, "\\\"")
		case '\\':
			strings.write_string(builder, "\\\\")
		case '\n':
			strings.write_string(builder, "\\n")
		case '\r':
			strings.write_string(builder, "\\r")
		case '\t':
			strings.write_string(builder, "\\t")
		case:
			strings.write_rune(builder, ch)
		}
	}
	strings.write_byte(builder, '"')
}

@(private)
identity_name :: proc(env: ^Builtin_Env, identity: v.Identity) -> (string, bool) {
	for name, value in env.ctx.identities {
		candidate, ok := v.value_as_identity(value)
		if ok && candidate == identity {
			return name, true
		}
	}
	return "", false
}
