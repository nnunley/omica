// Host builtin library: the low-level verbs fileins call by name.
//
// The scalar string surface mirrors the Rust runtime's `builtins/scalar.rs`;
// strings are indexed by Unicode scalar position, not bytes.
package mica_runtime

import "core:fmt"
import "core:mem"
import "core:os"
import "core:slice"
import "core:strings"
import "core:unicode/utf8"
import c "../compiler"
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
	{"__set_index", 3, builtin_set_index},
	{"to_symbol", 1, builtin_to_symbol},
	{"map_pairs", 1, builtin_map_pairs},
	{"index_or", 3, builtin_index_or},
	{"url_encode_component", 1, builtin_url_encode_component},
	{"url_decode_component", 1, builtin_url_decode_component},
	{"os_getenv", 1, builtin_os_getenv},
	{"to_literal", 1, builtin_to_literal},
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
