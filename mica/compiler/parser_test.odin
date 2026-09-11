package compiler

import "core:testing"

@(private)
parse_ok :: proc(
	t: ^testing.T,
	source: string,
	allocator := context.temp_allocator,
) -> ^Program_AST {
	program, errors := parse_program(source, allocator)
	testing.expectf(t, len(errors) == 0, "parse errors for %q: %v", source, errors)
	return program
}

@(private)
binding_name :: proc(t: ^testing.T, binding: Binding) -> string {
	pattern, ok := binding.pattern^.(Binding_Pattern)
	testing.expect(t, ok)
	return pattern.name
}

@(private)
first_item_expr :: proc(t: ^testing.T, program: ^Program_AST) -> ^Expr {
	testing.expect(t, len(program.items) > 0)
	if len(program.items) == 0 {
		return nil
	}
	item, ok := program.items[0].(Expr_Item)
	testing.expect(t, ok)
	return item.expr
}

@(test)
test_parse_binding_and_precedence :: proc(t: ^testing.T) {
	program := parse_ok(t, "let x = 1 + 2 * 3")
	expr := first_item_expr(t, program)
	binding, binding_ok := expr^.(Binding)
	testing.expect(t, binding_ok)
	testing.expect_value(t, binding_name(t, binding), "x")

	binary, binary_ok := binding.value^.(Binary)
	testing.expect(t, binary_ok)
	testing.expect_value(t, binary.op, Binary_Op.Add)

	right, right_ok := binary.right^.(Binary)
	testing.expect(t, right_ok)
	testing.expect_value(t, right.op, Binary_Op.Mul)
}

@(test)
test_parse_qualified_name_vs_division :: proc(t: ^testing.T) {
	qualified := parse_ok(t, "let x = workflow/AssignedTo")
	expr := first_item_expr(t, qualified)
	binding, _ := expr^.(Binding)
	name, name_ok := binding.value^.(Name)
	testing.expect(t, name_ok)
	testing.expect_value(t, len(name.parts), 2)
	testing.expect_value(t, name.parts[0], "workflow")
	testing.expect_value(t, name.parts[1], "AssignedTo")

	divided := parse_ok(t, "let x = left / right")
	expr2 := first_item_expr(t, divided)
	binding2, _ := expr2^.(Binding)
	binary, binary_ok := binding2.value^.(Binary)
	testing.expect(t, binary_ok)
	testing.expect_value(t, binary.op, Binary_Op.Div)
}

@(test)
test_parse_calls_lists_and_maps :: proc(t: ^testing.T) {
	program := parse_ok(t, "f(1, item: #lamp, @rest)")
	expr := first_item_expr(t, program)
	call, call_ok := expr^.(Call)
	testing.expect(t, call_ok)
	testing.expect_value(t, len(call.args), 3)
	testing.expect(t, !call.args[0].has_role)
	testing.expect(t, call.args[1].has_role)
	testing.expect_value(t, call.args[1].role, "item")
	_, is_identity := call.args[1].expr^.(Identity_Literal)
	testing.expect(t, is_identity)
	_, is_splice := call.args[2].expr^.(Splice)
	testing.expect(t, is_splice)

	list_program := parse_ok(t, "let xs = [1, 2, @rest]")
	list_expr := first_item_expr(t, list_program)
	list_binding, _ := list_expr^.(Binding)
	list, list_ok := list_binding.value^.(List_Literal)
	testing.expect(t, list_ok)
	testing.expect_value(t, len(list.elements), 3)

	map_program := parse_ok(t, "let m = {:name -> \"sensor\"}")
	map_expr := first_item_expr(t, map_program)
	map_binding, _ := map_expr^.(Binding)
	map_value, map_ok := map_binding.value^.(Map_Literal)
	testing.expect(t, map_ok)
	testing.expect_value(t, len(map_value.entries), 1)
	_, key_is_symbol := map_value.entries[0].key^.(Symbol_Literal)
	testing.expect(t, key_is_symbol)
}

@(test)
test_parse_range :: proc(t: ^testing.T) {
	program := parse_ok(t, "let slice = items[2.._]")
	expr := first_item_expr(t, program)
	binding, _ := expr^.(Binding)
	index, index_ok := binding.value^.(Index)
	testing.expect(t, index_ok)
	range, range_ok := index.key^.(Range_Literal)
	testing.expect(t, range_ok)
	testing.expect(t, !range.has_end)
}

@(test)
test_parse_if_while_for :: proc(t: ^testing.T) {
	if_program := parse_ok(
		t,
		"if x > 1\n  return x\nelseif x == 1\n  return 0\nelse\n  return -1\nend",
	)
	if_expr := first_item_expr(t, if_program)
	conditional, conditional_ok := if_expr^.(If)
	testing.expect(t, conditional_ok)
	testing.expect_value(t, len(conditional.branches), 2)
	testing.expect(t, conditional.has_else)
	testing.expect_value(t, len(conditional.else_body), 1)

	while_program := parse_ok(t, "while start < stop\n  start = start + 1\nend")
	while_expr := first_item_expr(t, while_program)
	loop, loop_ok := while_expr^.(While)
	testing.expect(t, loop_ok)
	testing.expect_value(t, len(loop.body), 1)

	for_program := parse_ok(t, "for key, value in map\n  emit(key, value)\nend")
	for_expr := first_item_expr(t, for_program)
	iteration, iteration_ok := for_expr^.(For)
	testing.expect(t, iteration_ok)
	testing.expect_value(t, len(iteration.names), 2)
	testing.expect_value(t, iteration.names[0], "key")
	testing.expect_value(t, iteration.names[1], "value")
}

@(test)
test_parse_verb :: proc(t: ^testing.T) {
	source := "verb trim(text @ #string: string) -> string\n  return text\nend"
	program := parse_ok(t, source)
	testing.expect_value(t, len(program.items), 1)
	item, item_ok := program.items[0].(Verb_Item)
	testing.expect(t, item_ok)
	testing.expect_value(t, item.name, "trim")
	testing.expect_value(t, item.result_type, "string")
	testing.expect_value(t, len(item.params), 1)
	testing.expect_value(t, item.params[0].name, "text")
	testing.expect(t, item.params[0].has_restriction)
	testing.expect(t, item.params[0].has_kind)
	testing.expect_value(t, item.params[0].kind, "string")
	testing.expect_value(t, len(item.body), 1)
}

@(test)
test_parse_rule :: proc(t: ^testing.T) {
	source := "ReadyForReview(reviewer, change) :- AssignedReviewer(change, reviewer), not ReviewRecorded(change)"
	program := parse_ok(t, source)
	testing.expect_value(t, len(program.items), 1)
	item, item_ok := program.items[0].(Rule_Item)
	testing.expect(t, item_ok)
	testing.expect_value(t, len(item.body), 2)

	_, head_is_call := item.head^.(Call)
	testing.expect(t, head_is_call)
	negation, negation_ok := item.body[1]^.(Unary)
	testing.expect(t, negation_ok)
	testing.expect_value(t, negation.op, Unary_Op.Not)
}

@(test)
test_parse_reports_errors :: proc(t: ^testing.T) {
	_, errors := parse_program("let = 1", context.temp_allocator)
	testing.expect(t, len(errors) > 0)
}

@(test)
test_parse_exactly_pattern_binding :: proc(t: ^testing.T) {
	program := parse_ok(t, "let exactly {:delegate -> found_delegate} = delegates")
	expr := first_item_expr(t, program)
	binding, binding_ok := expr^.(Binding)
	testing.expect(t, binding_ok)
	testing.expect(t, binding.is_exactly)

	map_pattern, map_ok := binding.pattern^.(Map_Pattern)
	testing.expect(t, map_ok)
	testing.expect_value(t, len(map_pattern.entries), 1)
	entry := map_pattern.entries[0]
	_, key_is_symbol := entry.key^.(Symbol_Literal)
	testing.expect(t, key_is_symbol)
	sub_pattern, sub_ok := entry.pattern^.(Binding_Pattern)
	testing.expect(t, sub_ok)
	testing.expect_value(t, sub_pattern.name, "found_delegate")
}

@(test)
test_parse_shorthand_and_list_patterns :: proc(t: ^testing.T) {
	program := parse_ok(t, "let exactly {label} = Label(#sensor, ?label)")
	expr := first_item_expr(t, program)
	binding, _ := expr^.(Binding)
	map_pattern, map_ok := binding.pattern^.(Map_Pattern)
	testing.expect(t, map_ok)
	testing.expect_value(t, len(map_pattern.entries), 1)
	testing.expect(t, map_pattern.entries[0].shorthand)

	list_program := parse_ok(t, "let [first, ?middle = none, @rest] = values")
	list_expr := first_item_expr(t, list_program)
	list_binding, _ := list_expr^.(Binding)
	list_pattern, list_ok := list_binding.pattern^.(List_Pattern)
	testing.expect(t, list_ok)
	testing.expect_value(t, len(list_pattern.elements), 3)
	_, first_ok := list_pattern.elements[0]^.(Binding_Pattern)
	testing.expect(t, first_ok)

	optional, optional_ok := list_pattern.elements[1]^.(Optional_Pattern)
	testing.expect(t, optional_ok)
	testing.expect_value(t, optional.name, "middle")
	testing.expect(t, optional.has_default)

	rest, rest_ok := list_pattern.elements[2]^.(Rest_Pattern)
	testing.expect(t, rest_ok)
	testing.expect_value(t, rest.name, "rest")
}

@(test)
test_parse_if_let :: proc(t: ^testing.T) {
	source := "if let {location} = LocatedAt(#sensor, ?location)\n  return location\nend"
	program := parse_ok(t, source)
	expr := first_item_expr(t, program)
	conditional, conditional_ok := expr^.(If)
	testing.expect(t, conditional_ok)
	testing.expect_value(t, len(conditional.branches), 1)
	condition, condition_ok := conditional.branches[0].condition^.(Binding)
	testing.expect(t, condition_ok)
	_, map_ok := condition.pattern^.(Map_Pattern)
	testing.expect(t, map_ok)
}

@(test)
test_parse_match :: proc(t: ^testing.T) {
	source := "let result = match from_literal(\"42\")\ncase ok(value)\n  some(value)\ncase err(problem)\n  none\nend"
	program := parse_ok(t, source)
	expr := first_item_expr(t, program)
	binding, _ := expr^.(Binding)
	match, match_ok := binding.value^.(Match)
	testing.expect(t, match_ok)
	testing.expect_value(t, len(match.cases), 2)

	call_pattern, call_ok := match.cases[0].pattern^.(Call_Pattern)
	testing.expect(t, call_ok)
	testing.expect_value(t, call_pattern.name, "ok")
	testing.expect_value(t, len(call_pattern.args), 1)
	testing.expect_value(t, len(match.cases[0].body), 1)
}

@(test)
test_parse_dom_markup :: proc(t: ^testing.T) {
	source := "return dom <button type=\"submit\" class={class} disabled>Save</button>"
	program := parse_ok(t, source)
	expr := first_item_expr(t, program)
	return_statement, return_ok := expr^.(Return)
	testing.expect(t, return_ok)
	element, element_ok := return_statement.value^.(Dom_Element)
	testing.expect(t, element_ok)
	testing.expect_value(t, element.tag, "button")
	testing.expect_value(t, len(element.attributes), 3)
	testing.expect_value(t, element.attributes[0].name, "type")
	testing.expect(t, element.attributes[0].has_value)
	testing.expect_value(t, element.attributes[1].name, "class")
	testing.expect(t, element.attributes[1].has_value)
	testing.expect_value(t, element.attributes[2].name, "disabled")
	testing.expect(t, !element.attributes[2].has_value)
	testing.expect_value(t, len(element.children), 1)

	text, text_ok := element.children[0]^.(Dom_Text)
	testing.expect(t, text_ok)
	testing.expect_value(t, text.text, "Save")
}

@(test)
test_parse_dom_nested_and_splice :: proc(t: ^testing.T) {
	source := "return dom <ul class=\"list\">\n  <li>One</li>\n  {@items}\n</ul>"
	program := parse_ok(t, source)
	expr := first_item_expr(t, program)
	return_statement, _ := expr^.(Return)
	element, element_ok := return_statement.value^.(Dom_Element)
	testing.expect(t, element_ok)
	testing.expect_value(t, element.tag, "ul")
	testing.expect_value(t, len(element.children), 2)

	item, item_ok := element.children[0]^.(Dom_Element)
	testing.expect(t, item_ok)
	testing.expect_value(t, item.tag, "li")
	testing.expect_value(t, len(item.children), 1)

	_, splice_ok := element.children[1]^.(Splice)
	testing.expect(t, splice_ok)
}

@(test)
test_parse_dom_hyphenated_attrs_and_self_closing :: proc(t: ^testing.T) {
	source := "return dom <input data-sync-key={key} aria:selected=\"true\" />"
	program := parse_ok(t, source)
	expr := first_item_expr(t, program)
	return_statement, _ := expr^.(Return)
	element, element_ok := return_statement.value^.(Dom_Element)
	testing.expect(t, element_ok)
	testing.expect(t, element.self_closing)
	testing.expect_value(t, element.tag, "input")
	testing.expect_value(t, len(element.attributes), 2)
	testing.expect_value(t, element.attributes[0].name, "data-sync-key")
	testing.expect_value(t, element.attributes[1].name, "aria:selected")
}

@(test)
test_parse_dom_vs_comparison :: proc(t: ^testing.T) {
	program := parse_ok(t, "let dom = 1\nreturn dom < 2")
	testing.expect_value(t, len(program.items), 2)
	item, item_ok := program.items[1].(Expr_Item)
	testing.expect(t, item_ok)
	return_statement, return_ok := item.expr^.(Return)
	testing.expect(t, return_ok)
	_, comparison_ok := return_statement.value^.(Binary)
	testing.expect(t, comparison_ok)
}

@(test)
test_parse_structural_literal :: proc(t: ^testing.T) {
	program := parse_ok(t, "let message = #chat_message<[room, seq]>")
	expr := first_item_expr(t, program)
	binding, _ := expr^.(Binding)
	literal, literal_ok := binding.value^.(Structural_Literal)
	testing.expect(t, literal_ok)
	testing.expect(t, !literal.named)
	testing.expect_value(t, len(literal.cells), 2)
	_, head_ok := literal.head^.(Identity_Literal)
	testing.expect(t, head_ok)

	named_program := parse_ok(
		t,
		"return #template/pronoun<{:binding -> binding, :cap -> cap}>",
	)
	named_expr := first_item_expr(t, named_program)
	return_statement, _ := named_expr^.(Return)
	named, named_ok := return_statement.value^.(Structural_Literal)
	testing.expect(t, named_ok)
	testing.expect(t, named.named)
	testing.expect_value(t, len(named.cells), 2)
	_, name_is_symbol := named.cells[0].name^.(Symbol_Literal)
	testing.expect(t, name_is_symbol)
}

@(test)
test_parse_structural_wildcard_cell :: proc(t: ^testing.T) {
	source := "verb handle(source @ #sync_action<_>)\n  return source\nend"
	program := parse_ok(t, source)
	item, item_ok := program.items[0].(Verb_Item)
	testing.expect(t, item_ok)
	testing.expect(t, item.params[0].has_restriction)
	literal, literal_ok := item.params[0].restriction^.(Structural_Literal)
	testing.expect(t, literal_ok)
	testing.expect_value(t, len(literal.cells), 1)
	_, wildcard_ok := literal.cells[0].value^.(Wildcard)
	testing.expect(t, wildcard_ok)
}

@(test)
test_parse_generic_kind_annotations :: proc(t: ^testing.T) {
	program := parse_ok(t, "let message: option<option<string>> = none")
	expr := first_item_expr(t, program)
	binding, _ := expr^.(Binding)
	testing.expect(t, binding.has_kind)
	testing.expect_value(t, binding.kind, "option<option<string>>")

	verb_program := parse_ok(
		t,
		"verb describe(value: option<string>) -> option<string>\n  return value\nend",
	)
	item, item_ok := verb_program.items[0].(Verb_Item)
	testing.expect(t, item_ok)
	testing.expect_value(t, item.params[0].kind, "option<string>")
	testing.expect_value(t, item.result_type, "option<string>")
}

@(test)
test_parse_qualified_verb_name :: proc(t: ^testing.T) {
	source := "verb ui/icon_node(name)\n  return name\nend"
	program := parse_ok(t, source)
	item, item_ok := program.items[0].(Verb_Item)
	testing.expect(t, item_ok)
	testing.expect_value(t, item.name, "ui/icon_node")
}

@(test)
test_parse_typed_for :: proc(t: ^testing.T) {
	source := "for part: string in parts\n  emit(part)\nend"
	program := parse_ok(t, source)
	expr := first_item_expr(t, program)
	iteration, iteration_ok := expr^.(For)
	testing.expect(t, iteration_ok)
	testing.expect_value(t, iteration.names[0], "part")
	testing.expect_value(t, iteration.kinds[0], "string")
}

@(test)
test_parse_grant_block :: proc(t: ^testing.T) {
	source := "grant role #builder\n  read:\n    :inspection\n  write:\n    :editing\n  invoke:\n    :maintenance\n  effect\nend"
	program := parse_ok(t, source)
	item, item_ok := program.items[0].(Grant_Item)
	testing.expect(t, item_ok)
	testing.expect(t, item.is_role)
	testing.expect_value(t, len(item.sections), 4)
	testing.expect_value(t, item.sections[0].kind, Grant_Section_Kind.Read)
	testing.expect_value(t, len(item.sections[0].entries), 1)
	_, entry_is_symbol := item.sections[0].entries[0]^.(Symbol_Literal)
	testing.expect(t, entry_is_symbol)
	testing.expect_value(t, item.sections[3].kind, Grant_Section_Kind.Effect)
	testing.expect_value(t, len(item.sections[3].entries), 0)
}

@(test)
test_parse_multiline_rule :: proc(t: ^testing.T) {
	source := "DependsOn(component, dependency) :-\n  DirectDependency(component, intermediate),\n  DependsOn(intermediate, dependency)\n\nAffected(component) :-\n  Unavailable(component)\n"
	program := parse_ok(t, source)
	testing.expect_value(t, len(program.items), 2)

	first, first_ok := program.items[0].(Rule_Item)
	testing.expect(t, first_ok)
	testing.expect_value(t, len(first.body), 2)

	second, second_ok := program.items[1].(Rule_Item)
	testing.expect(t, second_ok)
	testing.expect_value(t, len(second.body), 1)
}
