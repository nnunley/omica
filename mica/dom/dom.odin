// The sync DOM model: conversion from Mica DOM values and JSON encoding.
//
// The JSON shape matches `mica-host-protocol`'s `dom_sync` module, including
// sorted object keys and sorted attribute names, so payload signatures match
// the Rust host.
package dom

import "core:fmt"
import "core:mem"
import "core:slice"
import "core:strings"
import v "../var"

DOM_PATCH_PAYLOAD_TYPE :: "dom_patch"
DOM_EVENT_PAYLOAD_TYPE :: "dom_event"

DOM_TAGS := []string {
	"a",
	"abbr",
	"address",
	"area",
	"article",
	"aside",
	"audio",
	"b",
	"bdi",
	"bdo",
	"blockquote",
	"br",
	"button",
	"canvas",
	"caption",
	"cite",
	"code",
	"col",
	"colgroup",
	"data",
	"datalist",
	"dd",
	"del",
	"details",
	"dfn",
	"dialog",
	"div",
	"dl",
	"dt",
	"em",
	"fieldset",
	"figcaption",
	"figure",
	"footer",
	"form",
	"h1",
	"h2",
	"h3",
	"h4",
	"h5",
	"h6",
	"header",
	"hr",
	"i",
	"img",
	"input",
	"ins",
	"kbd",
	"label",
	"legend",
	"li",
	"main",
	"map",
	"mark",
	"menu",
	"meter",
	"nav",
	"ol",
	"optgroup",
	"option",
	"output",
	"p",
	"picture",
	"pre",
	"progress",
	"q",
	"rp",
	"rt",
	"ruby",
	"s",
	"samp",
	"section",
	"select",
	"small",
	"source",
	"span",
	"strong",
	"sub",
	"summary",
	"sup",
	"circle",
	"line",
	"path",
	"polygon",
	"polyline",
	"rect",
	"svg",
	"table",
	"tbody",
	"td",
	"template",
	"textarea",
	"tfoot",
	"th",
	"thead",
	"time",
	"tr",
	"track",
	"u",
	"ul",
	"var",
	"video",
	"wbr",
}

DOM_ATTRIBUTES := []string {
	"accept",
	"accept-charset",
	"action",
	"alt",
	"aria-busy",
	"aria-checked",
	"aria-controls",
	"aria-current",
	"aria-describedby",
	"aria-disabled",
	"aria-expanded",
	"aria-hidden",
	"aria-label",
	"aria-labelledby",
	"aria-live",
	"aria-pressed",
	"aria-selected",
	"autocomplete",
	"autofocus",
	"checked",
	"class",
	"cols",
	"colspan",
	"data-command",
	"data-entity",
	"data-sync-action",
	"data-sync-coalesce",
	"data-sync-debounce",
	"data-sync-event",
	"data-sync-fire-and-forget",
	"data-sync-follow",
	"data-sync-key",
	"data-sync-poll-ms",
	"data-sync-preserve-focus",
	"data-sync-reset",
	"data-sync-submit-key",
	"data-sync-throttle",
	"data-sync-on-viewport-top",
	"data-sync-stable-top",
	"data-sync-viewport-threshold",
	"datetime",
	"disabled",
	"download",
	"draggable",
	"for",
	"height",
	"hidden",
	"href",
	"id",
	"lang",
	"list",
	"loading",
	"max",
	"maxlength",
	"method",
	"min",
	"minlength",
	"multiple",
	"name",
	"open",
	"pattern",
	"placeholder",
	"readonly",
	"rel",
	"required",
	"role",
	"rows",
	"rowspan",
	"selected",
	"size",
	"span",
	"src",
	"step",
	"tabindex",
	"target",
	"title",
	"type",
	"value",
	"width",
	"wrap",
	"cx",
	"cy",
	"d",
	"fill",
	"points",
	"r",
	"rx",
	"ry",
	"stroke",
	"stroke-linecap",
	"stroke-linejoin",
	"stroke-width",
	"viewBox",
	"x",
	"x1",
	"x2",
	"y",
	"y1",
	"y2",
}

Dom_Text :: struct {
	text: string,
}

Dom_Attr :: struct {
	name:  string,
	value: string,
}

Dom_Element :: struct {
	tag:      string,
	attrs:    []Dom_Attr,
	children: []Dom_Node,
}

Dom_Node :: union {
	Dom_Text,
	Dom_Element,
}

is_supported_dom_tag :: proc(tag: string) -> bool {
	return slice.contains(DOM_TAGS, tag)
}

is_supported_dom_attribute :: proc(name: string) -> bool {
	if slice.contains(DOM_ATTRIBUTES, name) {
		return true
	}
	if strings.has_prefix(name, "aria-") {
		return is_custom_attr_suffix(name[len("aria-"):])
	}
	if strings.has_prefix(name, "data-") {
		return is_custom_attr_suffix(name[len("data-"):])
	}
	return false
}

// Attributes whose value is a URL and so must not carry an executable scheme
// such as `javascript:`.
@(private)
DOM_URL_ATTRIBUTES := []string{"action", "href", "src"}

@(private)
DOM_URL_SCHEMES := []string{"http", "https", "mailto", "tel"}

// Reports whether a URL-valued attribute is safe: a relative URL, or an
// absolute URL with an allowed scheme. Browsers ignore ASCII whitespace and
// control characters inside a scheme, so they are skipped before the scheme
// is compared (for example "java\tscript:" is still javascript:).
is_safe_dom_url :: proc(value: string) -> bool {
	index := 0
	for index < len(value) {
		c := value[index]
		if c > 0x20 && c != 0x7f {
			break
		}
		index += 1
	}
	scheme: [16]u8
	scheme_len := 0
	for index < len(value) {
		c := value[index]
		switch {
		case c == ':':
			if scheme_len == 0 {
				return true
			}
			return dom_scheme_allowed(scheme[:scheme_len])
		case c == '/' || c == '?' || c == '#':
			return true
		case c == '\t' || c == '\n' || c == '\r' || c < 0x20 || c == 0x7f:
			index += 1
		case:
			if scheme_len >= len(scheme) {
				return false
			}
			scheme[scheme_len] = c
			scheme_len += 1
			index += 1
		}
	}
	return true
}

@(private)
dom_scheme_allowed :: proc(scheme: []u8) -> bool {
	for allowed in DOM_URL_SCHEMES {
		if len(allowed) != len(scheme) {
			continue
		}
		match := true
		for i in 0 ..< len(scheme) {
			c := scheme[i]
			if c >= 'A' && c <= 'Z' {
				c += 'a' - 'A'
			}
			if c != allowed[i] {
				match = false
				break
			}
		}
		if match {
			return true
		}
	}
	return false
}

@(private)
is_custom_attr_suffix :: proc(suffix: string) -> bool {
	if len(suffix) == 0 {
		return false
	}
	for c in suffix {
		if (c < 'a' || c > 'z') && (c < '0' || c > '9') && c != '-' {
			return false
		}
	}
	return true
}

// Converts a Mica DOM value to a Dom_Node. Strings become text nodes; maps
// with `:text` become text nodes; maps with `:tag` become elements. `:raw`
// nodes are rejected because they are outside the sync contract.
dom_node_from_value :: proc(
	value: v.Value,
	allocator: mem.Allocator,
) -> (
	Dom_Node,
	string,
) {
	if text, is_text := v.value_as_string(value); is_text {
		return Dom_Node(Dom_Text{text = text}), ""
	}
	if text_value, has_text := dom_map_get(value, "text"); has_text {
		text, is_text := v.value_as_string(text_value)
		if !is_text {
			return nil, "DOM text node requires a string"
		}
		return Dom_Node(Dom_Text{text = text}), ""
	}
	if _, has_raw := dom_map_get(value, "raw"); has_raw {
		return nil, "raw DOM nodes are not valid sync payload nodes"
	}

	tag_value, has_tag := dom_map_get(value, "tag")
	if !has_tag {
		return nil, "DOM element requires string tag"
	}
	tag, is_tag_string := v.value_as_string(tag_value)
	if !is_tag_string {
		return nil, "DOM element requires string tag"
	}
	if !is_supported_dom_tag(tag) {
		return nil, fmt.aprintf(
			"unsupported DOM sync tag: %s",
			tag,
			allocator = allocator,
		)
	}

	attrs_value, has_attrs := dom_map_get(value, "attrs")
	if !has_attrs {
		return nil, "DOM element requires attrs map"
	}
	children_value, has_children := dom_map_get(value, "children")
	if !has_children {
		return nil, "DOM element requires children list"
	}

	attrs, attrs_error := dom_attrs_from_value(attrs_value, allocator)
	if attrs_error != "" {
		return nil, attrs_error
	}
	children_list, is_children_list := v.value_as_list(children_value)
	if !is_children_list {
		return nil, "DOM element children must be a list"
	}
	children: [dynamic]Dom_Node
	children = make([dynamic]Dom_Node, allocator)
	for child in children_list {
		// List interpolations expand into their elements, matching the XML
		// writer's flattening.
		if nested, is_list := v.value_as_list(child); is_list {
			for element in nested {
				node, child_error := dom_node_from_value(element, allocator)
				if child_error != "" {
					return nil, child_error
				}
				append(&children, node)
			}
			continue
		}
		node, child_error := dom_node_from_value(child, allocator)
		if child_error != "" {
			return nil, child_error
		}
		append(&children, node)
	}
	return Dom_Node(Dom_Element {
		tag      = tag,
		attrs    = attrs,
		children = children[:],
	}), ""
}

@(private)
dom_attrs_from_value :: proc(
	value: v.Value,
	allocator: mem.Allocator,
) -> (
	[]Dom_Attr,
	string,
) {
	entries, is_map := v.value_as_map(value)
	if !is_map {
		return nil, "DOM element attrs must be a map"
	}
	attrs: [dynamic]Dom_Attr
	attrs = make([dynamic]Dom_Attr, allocator)
	for entry in entries {
		name: string
		if text, is_text := v.value_as_string(entry.key); is_text {
			name = text
		} else if symbol, is_symbol := v.value_as_symbol(entry.key); is_symbol {
			symbol_name, has_name := v.symbol_name(symbol)
			if !has_name {
				return nil, "DOM attribute names must be strings or named symbols"
			}
			name = symbol_name
		} else {
			return nil, "DOM attribute names must be strings or named symbols"
		}
		if !is_supported_dom_attribute(name) {
			return nil, fmt.aprintf(
				"unsupported DOM sync attribute: %s",
				name,
				allocator = allocator,
			)
		}
		attribute_value: string
		if text, is_text := v.value_as_string(entry.value); is_text {
			attribute_value = text
		} else if boolean, is_bool := v.value_as_bool(entry.value); is_bool {
			attribute_value = boolean ? "true" : "false"
		} else if integer, is_int := v.value_as_int(entry.value); is_int {
			attribute_value = fmt.aprintf("%d", integer, allocator = allocator)
		} else {
			return nil, "DOM attribute values must be strings, booleans, or integers"
		}
		if slice.contains(DOM_URL_ATTRIBUTES, name) && !is_safe_dom_url(attribute_value) {
			return nil, fmt.aprintf(
				"unsafe DOM URL attribute value for %s",
				name,
				allocator = allocator,
			)
		}
		append(&attrs, Dom_Attr{name = name, value = attribute_value})
	}
	slice.sort_by(attrs[:], proc(a, b: Dom_Attr) -> bool {
		return a.name < b.name
	})
	return attrs[:], ""
}

@(private)
dom_map_get :: proc(value: v.Value, key: string) -> (v.Value, bool) {
	entries, is_map := v.value_as_map(value)
	if !is_map {
		return v.Value(0), false
	}
	key_value := v.value_symbol(v.symbol_intern(key))
	for entry in entries {
		if v.value_eq(entry.key, key_value) {
			return entry.value, true
		}
	}
	return v.Value(0), false
}

// --- JSON ------------------------------------------------------------------

dom_node_count :: proc(node: Dom_Node) -> int {
	switch value in node {
	case Dom_Text:
		return 1
	case Dom_Element:
		total := 1
		for child in value.children {
			total += dom_node_count(child)
		}
		return total
	}
	return 0
}

dom_write_node_json :: proc(builder: ^strings.Builder, node: Dom_Node) {
	switch value in node {
	case Dom_Text:
		strings.write_string(builder, "{\"text\":\"")
		dom_write_json_string(builder, value.text)
		strings.write_string(builder, "\"}")
	case Dom_Element:
		strings.write_string(builder, "{\"attrs\":{")
		for attribute, index in value.attrs {
			if index > 0 {
				strings.write_byte(builder, ',')
			}
			strings.write_byte(builder, '"')
			dom_write_json_string(builder, attribute.name)
			strings.write_string(builder, "\":\"")
			dom_write_json_string(builder, attribute.value)
			strings.write_byte(builder, '"')
		}
		strings.write_string(builder, "},\"children\":[")
		for child, index in value.children {
			if index > 0 {
				strings.write_byte(builder, ',')
			}
			dom_write_node_json(builder, child)
		}
		strings.write_string(builder, "],\"tag\":\"")
		dom_write_json_string(builder, value.tag)
		strings.write_string(builder, "\"}")
	}
}

dom_snapshot_payload_json :: proc(
	view: u64,
	revision: u64,
	root: Dom_Node,
	allocator: mem.Allocator,
) -> string {
	builder: strings.Builder
	strings.builder_init(&builder, allocator)
	defer strings.builder_destroy(&builder)
	strings.write_string(&builder, "{\"revision\":")
	fmt.sbprintf(&builder, "%d", revision)
	strings.write_string(&builder, ",\"root\":")
	dom_write_node_json(&builder, root)
	strings.write_string(&builder, ",\"view\":")
	fmt.sbprintf(&builder, "%d", view)
	strings.write_byte(&builder, '}')
	return strings.clone(strings.to_string(builder), allocator)
}

@(private)
dom_write_json_string :: proc(builder: ^strings.Builder, text: string) {
	for c in text {
		switch c {
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
			if c < 0x20 {
				fmt.sbprintf(builder, "\\u%04x", u32(c))
			} else {
				strings.write_rune(builder, c)
			}
		}
	}
}

// A DOM patch, mirroring `DomPatch` in the Rust host protocol.
Dom_Patch_Replace :: struct {
	path: []u64,
	node: Dom_Node,
}

Dom_Patch_Set_Text :: struct {
	path: []u64,
	text: string,
}

Dom_Patch_Set_Attr :: struct {
	path:  []u64,
	name:  string,
	value: string,
}

Dom_Patch_Remove_Attr :: struct {
	path: []u64,
	name: string,
}

Dom_Patch_Append_Child :: struct {
	path: []u64,
	node: Dom_Node,
}

Dom_Patch_Insert_Child :: struct {
	path:  []u64,
	index: u64,
	node:  Dom_Node,
}

Dom_Patch_Remove_Child :: struct {
	path: []u64,
}

Dom_Patch :: union {
	Dom_Patch_Replace,
	Dom_Patch_Set_Text,
	Dom_Patch_Set_Attr,
	Dom_Patch_Remove_Attr,
	Dom_Patch_Append_Child,
	Dom_Patch_Insert_Child,
	Dom_Patch_Remove_Child,
}

dom_write_patch_json :: proc(builder: ^strings.Builder, patch: ^Dom_Patch) {
	switch value in patch {
	case Dom_Patch_Replace:
		strings.write_string(builder, "{\"node\":")
		dom_write_node_json(builder, value.node)
		strings.write_string(builder, ",\"op\":\"replace\",\"path\":")
		dom_write_path_json(builder, value.path)
		strings.write_byte(builder, '}')
	case Dom_Patch_Set_Text:
		strings.write_string(builder, "{\"op\":\"set_text\",\"path\":")
		dom_write_path_json(builder, value.path)
		strings.write_string(builder, ",\"text\":\"")
		dom_write_json_string(builder, value.text)
		strings.write_string(builder, "\"}")
	case Dom_Patch_Set_Attr:
		strings.write_string(builder, "{\"name\":\"")
		dom_write_json_string(builder, value.name)
		strings.write_string(builder, "\",\"op\":\"set_attr\",\"path\":")
		dom_write_path_json(builder, value.path)
		strings.write_string(builder, ",\"value\":\"")
		dom_write_json_string(builder, value.value)
		strings.write_string(builder, "\"}")
	case Dom_Patch_Remove_Attr:
		strings.write_string(builder, "{\"name\":\"")
		dom_write_json_string(builder, value.name)
		strings.write_string(builder, "\",\"op\":\"remove_attr\",\"path\":")
		dom_write_path_json(builder, value.path)
		strings.write_byte(builder, '}')
	case Dom_Patch_Append_Child:
		strings.write_string(builder, "{\"node\":")
		dom_write_node_json(builder, value.node)
		strings.write_string(builder, ",\"op\":\"append_child\",\"path\":")
		dom_write_path_json(builder, value.path)
		strings.write_byte(builder, '}')
	case Dom_Patch_Insert_Child:
		strings.write_string(builder, "{\"index\":")
		fmt.sbprintf(builder, "%d", value.index)
		strings.write_string(builder, ",\"node\":")
		dom_write_node_json(builder, value.node)
		strings.write_string(builder, ",\"op\":\"insert_child\",\"path\":")
		dom_write_path_json(builder, value.path)
		strings.write_byte(builder, '}')
	case Dom_Patch_Remove_Child:
		strings.write_string(builder, "{\"op\":\"remove_child\",\"path\":")
		dom_write_path_json(builder, value.path)
		strings.write_byte(builder, '}')
	}
}

dom_patch_payload_json :: proc(
	view: u64,
	revision: u64,
	patches: []Dom_Patch,
	allocator: mem.Allocator,
) -> string {
	builder: strings.Builder
	strings.builder_init(&builder, allocator)
	defer strings.builder_destroy(&builder)
	strings.write_string(&builder, "{\"patches\":[")
	for &patch, index in patches {
		if index > 0 {
			strings.write_byte(&builder, ',')
		}
		dom_write_patch_json(&builder, &patch)
	}
	strings.write_string(&builder, "],\"revision\":")
	fmt.sbprintf(&builder, "%d", revision)
	strings.write_string(&builder, ",\"type\":\"")
	strings.write_string(&builder, DOM_PATCH_PAYLOAD_TYPE)
	strings.write_string(&builder, "\",\"view\":")
	fmt.sbprintf(&builder, "%d", view)
	strings.write_byte(&builder, '}')
	return strings.clone(strings.to_string(builder), allocator)
}

@(private)
dom_write_path_json :: proc(builder: ^strings.Builder, path: []u64) {
	strings.write_byte(builder, '[')
	for value, index in path {
		if index > 0 {
			strings.write_byte(builder, ',')
		}
		fmt.sbprintf(builder, "%d", value)
	}
	strings.write_byte(builder, ']')
}
