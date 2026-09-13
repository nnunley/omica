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

// URL-valued attributes must not carry an executable scheme.
@(test)
test_dom_rejects_unsafe_url_attributes :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	testing.expect(t, is_safe_dom_url("/mud"))
	testing.expect(t, is_safe_dom_url("mud/page.html"))
	testing.expect(t, is_safe_dom_url("#section"))
	testing.expect(t, is_safe_dom_url("?q=1"))
	testing.expect(t, is_safe_dom_url("https://example.com"))
	testing.expect(t, is_safe_dom_url("HTTP://example.com"))
	testing.expect(t, is_safe_dom_url("mailto:a@b.c"))
	testing.expect(t, !is_safe_dom_url("javascript:alert(1)"))
	testing.expect(t, !is_safe_dom_url("JavaScript:alert(1)"))
	testing.expect(t, !is_safe_dom_url("java\tscript:alert(1)"))
	testing.expect(t, !is_safe_dom_url("  javascript:alert(1)"))
	testing.expect(t, !is_safe_dom_url("data:text/html,<script>"))
	testing.expect(t, !is_safe_dom_url("vbscript:msgbox(1)"))

	allocator := context.temp_allocator
	_, url_error := dom_node_from_value(
		v.value_map(allocator, []v.Map_Entry {
			{key = symbol("tag"), value = string_value("a")},
			{
				key = symbol("attrs"),
				value = v.value_map(allocator, []v.Map_Entry {
					{key = string_value("href"), value = string_value("javascript:alert(1)")},
				}),
			},
			{key = symbol("children"), value = v.value_list(allocator, nil)},
		}),
		allocator,
	)
	testing.expect(t, strings.contains(url_error, "unsafe DOM URL attribute"))

	_, ok_error := dom_node_from_value(
		v.value_map(allocator, []v.Map_Entry {
			{key = symbol("tag"), value = string_value("a")},
			{
				key = symbol("attrs"),
				value = v.value_map(allocator, []v.Map_Entry {
					{key = string_value("href"), value = string_value("/mud/page")},
				}),
			},
			{key = symbol("children"), value = v.value_list(allocator, nil)},
		}),
		allocator,
	)
	testing.expect_value(t, ok_error, "")
}

@(test)
test_dom_support_predicates :: proc(t: ^testing.T) {
	testing.expect(t, is_supported_dom_tag("div"))
	testing.expect(t, is_supported_dom_tag("svg"))
	testing.expect(t, !is_supported_dom_tag("bogus"))
	testing.expect(t, is_supported_dom_attribute("class"))
	testing.expect(t, is_supported_dom_attribute("data-sync-event"))
	testing.expect(t, is_supported_dom_attribute("data-sync-disable-with"))
	testing.expect(t, is_supported_dom_attribute("data-custom-thing"))
	testing.expect(t, is_supported_dom_attribute("aria-live"))
	testing.expect(t, !is_supported_dom_attribute("onclick"))
	testing.expect(t, !is_supported_dom_attribute("data-"))
	testing.expect(t, !is_supported_dom_attribute("data-HasUpper"))
}

@(private)
diff_element :: proc(tag: string, attrs: []Dom_Attr, children: []Dom_Node) -> Dom_Node {
	return Dom_Node(Dom_Element{tag = tag, attrs = attrs, children = children})
}

@(private)
diff_text :: proc(text: string) -> Dom_Node {
	return Dom_Node(Dom_Text{text = text})
}

@(private)
diff_payload :: proc(before, after: Dom_Node) -> string {
	path: [dynamic]u64
	path = make([dynamic]u64, context.temp_allocator)
	defer delete(path)
	patches: [dynamic]Dom_Patch
	patches = make([dynamic]Dom_Patch, context.temp_allocator)
	defer delete(patches)
	dom_diff_nodes(before, after, &path, &patches, context.temp_allocator)
	return dom_patch_payload_json(1, 2, patches[:], context.temp_allocator)
}

@(test)
test_dom_diff_text_and_attrs :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	payload := diff_payload(
		diff_element("div", nil, []Dom_Node{diff_text("a")}),
		diff_element("div", nil, []Dom_Node{diff_text("b")}),
	)
	testing.expect_value(
		t,
		payload,
		`{"patches":[{"op":"set_text","path":[0],"text":"b"}],"revision":2,"type":"dom_patch","view":1}`,
	)

	payload = diff_payload(
		diff_element("div", []Dom_Attr{{"class", "a"}}, nil),
		diff_element("div", []Dom_Attr{{"class", "b"}}, nil),
	)
	testing.expect_value(
		t,
		payload,
		`{"patches":[{"name":"class","op":"set_attr","path":[],"value":"b"}],"revision":2,"type":"dom_patch","view":1}`,
	)

	payload = diff_payload(
		diff_element("div", []Dom_Attr{{"class", "a"}}, nil),
		diff_element("div", nil, nil),
	)
	testing.expect_value(
		t,
		payload,
		`{"patches":[{"name":"class","op":"remove_attr","path":[]}],"revision":2,"type":"dom_patch","view":1}`,
	)
}

@(test)
test_dom_diff_children :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	payload := diff_payload(
		diff_element("div", nil, []Dom_Node{diff_text("a")}),
		diff_element("div", nil, []Dom_Node{diff_text("a"), diff_text("c")}),
	)
	testing.expect_value(
		t,
		payload,
		`{"patches":[{"node":{"text":"c"},"op":"append_child","path":[]}],"revision":2,"type":"dom_patch","view":1}`,
	)

	payload = diff_payload(
		diff_element("div", nil, []Dom_Node{diff_text("a"), diff_text("b")}),
		diff_element("div", nil, []Dom_Node{diff_text("a")}),
	)
	testing.expect_value(
		t,
		payload,
		`{"patches":[{"op":"remove_child","path":[1]}],"revision":2,"type":"dom_patch","view":1}`,
	)

	payload = diff_payload(
		diff_element("div", nil, nil),
		diff_element("span", nil, nil),
	)
	testing.expect_value(
		t,
		payload,
		`{"patches":[{"node":{"attrs":{},"children":[],"tag":"span"},"op":"replace","path":[]}],"revision":2,"type":"dom_patch","view":1}`,
	)
}

@(test)
test_dom_diff_keyed_children :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	first := diff_element("li", []Dom_Attr{{"id", "a"}}, nil)
	second := diff_element("li", []Dom_Attr{{"id", "b"}}, nil)
	payload := diff_payload(
		diff_element("ul", nil, []Dom_Node{first, second}),
		diff_element("ul", nil, []Dom_Node{second, first}),
	)
	expected := `{"patches":[{"op":"remove_child","path":[1]},{"index":0,"node":{"attrs":{"id":"b"},"children":[],"tag":"li"},"op":"insert_child","path":[]}],"revision":2,"type":"dom_patch","view":1}`
	testing.expect_value(t, payload, expected)
}
