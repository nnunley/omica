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
	testing.expect_value(t, binding.name, "x")

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
