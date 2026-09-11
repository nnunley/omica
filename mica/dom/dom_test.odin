package dom

import "core:strings"
import "core:testing"
import v "../var"

@(private)
symbol :: proc(name: string) -> v.Value {
	return v.value_symbol(v.symbol_intern(name))
}

@(private)
string_value :: proc(text: string) -> v.Value {
	return v.value_string(context.temp_allocator, text)
}

@(private)
text_node :: proc(text: string) -> v.Value {
	return v.value_map(context.temp_allocator, []v.Map_Entry {
		{key = symbol("text"), value = string_value(text)},
	})
}

@(test)
test_dom_snapshot_payload_json :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	allocator := context.temp_allocator

	attrs := v.value_map(allocator, []v.Map_Entry {
		{key = string_value("class"), value = string_value("mud-login")},
		{key = string_value("id"), value = string_value("mud-root")},
	})
	br := v.value_map(allocator, []v.Map_Entry {
		{key = symbol("tag"), value = string_value("br")},
		{key = symbol("attrs"), value = v.value_map(allocator, nil)},
		{key = symbol("children"), value = v.value_list(allocator, nil)},
	})
	children := v.value_list(allocator, []v.Value{text_node("hi"), br})
	root := v.value_map(allocator, []v.Map_Entry {
		{key = symbol("tag"), value = string_value("div")},
		{key = symbol("attrs"), value = attrs},
		{key = symbol("children"), value = children},
	})

	node, node_error := dom_node_from_value(root, allocator)
	testing.expectf(t, node_error == "", "convert failed: %s", node_error)
	payload := dom_snapshot_payload_json(21, 1, node, allocator)
	expected := `{"revision":1,"root":{"attrs":{"class":"mud-login","id":"mud-root"},"children":[{"text":"hi"},{"attrs":{},"children":[],"tag":"br"}],"tag":"div"},"view":21}`
	testing.expect_value(t, payload, expected)
	testing.expect_value(t, dom_node_count(node), 3)
}

@(test)
test_dom_patch_payload_json :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	allocator := context.temp_allocator

	patches := []Dom_Patch {
		Dom_Patch_Set_Text{path = []u64{0, 1}, text = "a\"b"},
		Dom_Patch_Set_Attr{path = []u64{}, name = "class", value = "x"},
		Dom_Patch_Insert_Child {
			path = []u64{1},
			index = 2,
			node = Dom_Node(Dom_Text{text = "z"}),
		},
	}
	payload := dom_patch_payload_json(21, 3, patches, allocator)
	expected := `{"patches":[{"op":"set_text","path":[0,1],"text":"a\"b"},{"name":"class","op":"set_attr","path":[],"value":"x"},{"index":2,"node":{"text":"z"},"op":"insert_child","path":[1]}],"revision":3,"type":"dom_patch","view":21}`
	testing.expect_value(t, payload, expected)
}

@(test)
test_dom_attribute_coercion :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	allocator := context.temp_allocator

	hidden := v.value_bool(true)
	tabindex, _ := v.value_int(3)
	attrs := v.value_map(allocator, []v.Map_Entry {
		{key = string_value("hidden"), value = hidden},
		{key = string_value("tabindex"), value = tabindex},
	})
	root := v.value_map(allocator, []v.Map_Entry {
		{key = symbol("tag"), value = string_value("div")},
		{key = symbol("attrs"), value = attrs},
		{key = symbol("children"), value = v.value_list(allocator, nil)},
	})

	node, node_error := dom_node_from_value(root, allocator)
	testing.expectf(t, node_error == "", "convert failed: %s", node_error)
	builder: strings.Builder
	strings.builder_init(&builder, allocator)
	defer strings.builder_destroy(&builder)
	dom_write_node_json(&builder, node)
	testing.expect_value(
		t,
		strings.to_string(builder),
		`{"attrs":{"hidden":"true","tabindex":"3"},"children":[],"tag":"div"}`,
	)
}

@(test)
test_dom_rejects_invalid_nodes :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	allocator := context.temp_allocator

	_, raw_error := dom_node_from_value(
		v.value_map(allocator, []v.Map_Entry {
			{key = symbol("raw"), value = string_value("<b>x</b>")},
		}),
		allocator,
	)
	testing.expectf(t, raw_error != "", "raw node should be rejected")

	_, tag_error := dom_node_from_value(
		v.value_map(allocator, []v.Map_Entry {
			{key = symbol("tag"), value = string_value("bogus")},
			{key = symbol("attrs"), value = v.value_map(allocator, nil)},
			{key = symbol("children"), value = v.value_list(allocator, nil)},
		}),
		allocator,
	)
	testing.expect(t, strings.contains(tag_error, "unsupported DOM sync tag"))

	_, attr_error := dom_node_from_value(
		v.value_map(allocator, []v.Map_Entry {
			{key = symbol("tag"), value = string_value("div")},
			{
				key = symbol("attrs"),
				value = v.value_map(allocator, []v.Map_Entry {
					{key = string_value("onclick"), value = string_value("x")},
				}),
			},
			{key = symbol("children"), value = v.value_list(allocator, nil)},
		}),
		allocator,
	)
	testing.expect(t, strings.contains(attr_error, "unsupported DOM sync attribute"))

	_, missing_error := dom_node_from_value(
		v.value_map(allocator, []v.Map_Entry {
			{key = symbol("tag"), value = string_value("div")},
		}),
		allocator,
	)
	testing.expect(t, strings.contains(missing_error, "attrs"))

	_, children_error := dom_node_from_value(
		v.value_map(allocator, []v.Map_Entry {
			{key = symbol("tag"), value = string_value("div")},
			{key = symbol("attrs"), value = v.value_map(allocator, nil)},
			{key = symbol("children"), value = string_value("nope")},
		}),
		allocator,
	)
	testing.expect(t, strings.contains(children_error, "list"))

	bad_text, _ := v.value_int(3)
	_, text_error := dom_node_from_value(
		v.value_map(allocator, []v.Map_Entry {
			{key = symbol("text"), value = bad_text},
		}),
		allocator,
	)
	testing.expect(t, strings.contains(text_error, "text"))
}

@(test)
test_dom_support_predicates :: proc(t: ^testing.T) {
	testing.expect(t, is_supported_dom_tag("div"))
	testing.expect(t, is_supported_dom_tag("svg"))
	testing.expect(t, !is_supported_dom_tag("bogus"))
	testing.expect(t, is_supported_dom_attribute("class"))
	testing.expect(t, is_supported_dom_attribute("data-sync-event"))
	testing.expect(t, is_supported_dom_attribute("data-custom-thing"))
	testing.expect(t, is_supported_dom_attribute("aria-live"))
	testing.expect(t, !is_supported_dom_attribute("onclick"))
	testing.expect(t, !is_supported_dom_attribute("data-"))
	testing.expect(t, !is_supported_dom_attribute("data-HasUpper"))
}
