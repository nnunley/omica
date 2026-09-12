// Structural DOM diffing: compares two trees and emits the patches that turn
// `before` into `after`. Mirrors `diff_dom_node` in the Rust host protocol.
package dom

import "core:mem"

dom_node_eq :: proc(a, b: Dom_Node) -> bool {
	#partial switch av in a {
	case Dom_Text:
		bv, b_ok := b.(Dom_Text)
		return b_ok && av.text == bv.text
	case Dom_Element:
		bv, b_ok := b.(Dom_Element)
		if !b_ok || av.tag != bv.tag {
			return false
		}
		if len(av.attrs) != len(bv.attrs) || len(av.children) != len(bv.children) {
			return false
		}
		for attribute, index in av.attrs {
			if bv.attrs[index].name != attribute.name ||
			   bv.attrs[index].value != attribute.value {
				return false
			}
		}
		for child, index in av.children {
			if !dom_node_eq(child, bv.children[index]) {
				return false
			}
		}
		return true
	}
	return false
}

dom_diff_nodes :: proc(
	before, after: Dom_Node,
	path: ^[dynamic]u64,
	patches: ^[dynamic]Dom_Patch,
	allocator: mem.Allocator,
) {
	if dom_node_eq(before, after) {
		return
	}
	#partial switch before_value in before {
	case Dom_Text:
		after_value, after_ok := after.(Dom_Text)
		if !after_ok {
			append(patches, Dom_Patch(Dom_Patch_Replace {
				path = dom_path_copy(path, allocator),
				node = after,
			}))
			return
		}
		append(patches, Dom_Patch(Dom_Patch_Set_Text {
			path = dom_path_copy(path, allocator),
			text = after_value.text,
		}))
	case Dom_Element:
		after_value, after_ok := after.(Dom_Element)
		if !after_ok || after_value.tag != before_value.tag {
			append(patches, Dom_Patch(Dom_Patch_Replace {
				path = dom_path_copy(path, allocator),
				node = after,
			}))
			return
		}
		dom_diff_attrs(before_value.attrs, after_value.attrs, path, patches, allocator)
		dom_diff_children(
			before_value.children,
			after_value.children,
			path,
			patches,
			allocator,
		)
	}
}

@(private)
dom_diff_attrs :: proc(
	before, after: []Dom_Attr,
	path: ^[dynamic]u64,
	patches: ^[dynamic]Dom_Patch,
	allocator: mem.Allocator,
) {
	for attribute in before {
		found := false
		for candidate in after {
			if candidate.name != attribute.name {
				continue
			}
			found = true
			if candidate.value != attribute.value {
				append(patches, Dom_Patch(Dom_Patch_Set_Attr {
					path  = dom_path_copy(path, allocator),
					name  = attribute.name,
					value = candidate.value,
				}))
			}
			break
		}
		if !found {
			append(patches, Dom_Patch(Dom_Patch_Remove_Attr {
				path = dom_path_copy(path, allocator),
				name = attribute.name,
			}))
		}
	}
	for attribute in after {
		found := false
		for candidate in before {
			if candidate.name == attribute.name {
				found = true
				break
			}
		}
		if !found {
			append(patches, Dom_Patch(Dom_Patch_Set_Attr {
				path  = dom_path_copy(path, allocator),
				name  = attribute.name,
				value = attribute.value,
			}))
		}
	}
}

@(private)
dom_diff_children :: proc(
	before, after: []Dom_Node,
	path: ^[dynamic]u64,
	patches: ^[dynamic]Dom_Patch,
	allocator: mem.Allocator,
) {
	before_keys, before_keyed := dom_child_keys(before, allocator)
	defer if before_keyed {
		delete(before_keys, allocator)
	}
	after_keys, after_keyed := dom_child_keys(after, allocator)
	defer if after_keyed {
		delete(after_keys, allocator)
	}
	if before_keyed && after_keyed {
		dom_diff_keyed_children(before, before_keys, after, after_keys, path, patches, allocator)
		return
	}

	shared := min(len(before), len(after))
	for index in 0 ..< shared {
		append(path, u64(index))
		dom_diff_nodes(before[index], after[index], path, patches, allocator)
		pop(path)
	}
	for index in shared ..< len(after) {
		append(patches, Dom_Patch(Dom_Patch_Append_Child {
			path = dom_path_copy(path, allocator),
			node = after[index],
		}))
	}
	for index := len(before) - 1; index >= len(after); index -= 1 {
		child_path := dom_path_append(path, u64(index), allocator)
		append(patches, Dom_Patch(Dom_Patch_Remove_Child{path = child_path}))
	}
}

@(private)
dom_diff_keyed_children :: proc(
	before: []Dom_Node,
	before_keys: []string,
	after: []Dom_Node,
	after_keys: []string,
	path: ^[dynamic]u64,
	patches: ^[dynamic]Dom_Patch,
	allocator: mem.Allocator,
) {
	current: [dynamic]Dom_Node
	current = make([dynamic]Dom_Node, allocator)
	append(&current, ..before)
	current_keys: [dynamic]string
	current_keys = make([dynamic]string, allocator)
	append(&current_keys, ..before_keys)
	defer delete(current)
	defer delete(current_keys)

	for index := len(current) - 1; index >= 0; index -= 1 {
		if dom_string_in(after_keys, current_keys[index]) {
			continue
		}
		child_path := dom_path_append(path, u64(index), allocator)
		append(patches, Dom_Patch(Dom_Patch_Remove_Child{path = child_path}))
		dom_remove_at(&current, index)
		dom_remove_at(&current_keys, index)
	}

	for index := 0; index < len(after); index += 1 {
		if index < len(current_keys) && current_keys[index] == after_keys[index] {
			append(path, u64(index))
			dom_diff_nodes(current[index], after[index], path, patches, allocator)
			pop(path)
			current[index] = after[index]
			continue
		}

		found := -1
		for candidate := index + 1; candidate < len(current_keys); candidate += 1 {
			if current_keys[candidate] == after_keys[index] {
				found = candidate
				break
			}
		}
		if found >= 0 {
			child_path := dom_path_append(path, u64(found), allocator)
			append(patches, Dom_Patch(Dom_Patch_Remove_Child{path = child_path}))
			dom_remove_at(&current, found)
			dom_remove_at(&current_keys, found)
		}

		if index == len(current) {
			append(patches, Dom_Patch(Dom_Patch_Append_Child {
				path = dom_path_copy(path, allocator),
				node = after[index],
			}))
		} else {
			append(patches, Dom_Patch(Dom_Patch_Insert_Child {
				path  = dom_path_copy(path, allocator),
				index = u64(index),
				node  = after[index],
			}))
		}
		dom_insert_at(&current, index, after[index])
		dom_insert_at(&current_keys, index, after_keys[index])
	}
}

// Returns the sync keys of every child, or false when any child lacks a unique
// `data-sync-key` or `id`.
@(private)
dom_child_keys :: proc(children: []Dom_Node, allocator: mem.Allocator) -> ([]string, bool) {
	if len(children) == 0 {
		// No keys needed for an empty child list; treat as unkeyed.
		return nil, false
	}
	keys := make([]string, len(children), allocator)
	for child, index in children {
		element, is_element := child.(Dom_Element)
		if !is_element {
			delete(keys, allocator)
			return nil, false
		}
		key := ""
		for attribute in element.attrs {
			if attribute.name == "data-sync-key" {
				key = attribute.value
				break
			}
			if attribute.name == "id" && key == "" {
				key = attribute.value
			}
		}
		if key == "" {
			delete(keys, allocator)
			return nil, false
		}
		for previous in keys[:index] {
			if previous == key {
				delete(keys, allocator)
				return nil, false
			}
		}
		keys[index] = key
	}
	return keys, true
}

@(private)
dom_path_copy :: proc(path: ^[dynamic]u64, allocator: mem.Allocator) -> []u64 {
	copied := make([]u64, len(path), allocator)
	copy(copied, path[:])
	return copied
}

@(private)
dom_path_append :: proc(path: ^[dynamic]u64, value: u64, allocator: mem.Allocator) -> []u64 {
	copied := make([]u64, len(path) + 1, allocator)
	copy(copied, path[:])
	copied[len(path)] = value
	return copied
}

@(private)
dom_string_in :: proc(values: []string, needle: string) -> bool {
	for value in values {
		if value == needle {
			return true
		}
	}
	return false
}

@(private)
dom_remove_at :: proc {
	dom_remove_node_at,
	dom_remove_string_at,
}

@(private)
dom_remove_node_at :: proc(values: ^[dynamic]Dom_Node, index: int) {
	copy(values[index:], values[index + 1:])
	resize(values, len(values) - 1)
}

@(private)
dom_remove_string_at :: proc(values: ^[dynamic]string, index: int) {
	copy(values[index:], values[index + 1:])
	resize(values, len(values) - 1)
}

@(private)
dom_insert_at :: proc {
	dom_insert_node_at,
	dom_insert_string_at,
}

@(private)
dom_insert_node_at :: proc(values: ^[dynamic]Dom_Node, index: int, value: Dom_Node) {
	append(values, value)
	copy(values[index + 1:], values[index:])
	values[index] = value
}

@(private)
dom_insert_string_at :: proc(values: ^[dynamic]string, index: int, value: string) {
	append(values, value)
	copy(values[index + 1:], values[index:])
	values[index] = value
}

// Frees the path storage of one patch. Node references are not freed.
dom_patch_release :: proc(patch: ^Dom_Patch, allocator: mem.Allocator) {
	#partial switch value in patch^ {
	case Dom_Patch_Replace:
		delete(value.path, allocator)
	case Dom_Patch_Set_Text:
		delete(value.path, allocator)
	case Dom_Patch_Set_Attr:
		delete(value.path, allocator)
	case Dom_Patch_Remove_Attr:
		delete(value.path, allocator)
	case Dom_Patch_Append_Child:
		delete(value.path, allocator)
	case Dom_Patch_Insert_Child:
		delete(value.path, allocator)
	case Dom_Patch_Remove_Child:
		delete(value.path, allocator)
	}
}

// Frees the array storage of a tree. Strings are views into Mica values and
// stay owned by the caller.
dom_node_release :: proc(node: Dom_Node, allocator: mem.Allocator) {
	element, is_element := node.(Dom_Element)
	if !is_element {
		return
	}
	for child in element.children {
		dom_node_release(child, allocator)
	}
	delete(element.attrs, allocator)
	delete(element.children, allocator)
}
