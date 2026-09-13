// Canonical S-expression rendering of a *relational* AST.
//
// `apps/compiler/parse.mica` produces the AST as a relation value with heading
// `[:node, :role, :target, :ordinal]`. This walks that graph from a root id and
// emits the same grammar `ast_sexpr` emits for the Odin AST, so the differential
// test compares the two parsers by their rendered structure rather than by node
// identities. Both renderers live in Odin, so formatting is identical and the
// only thing under test is the Mica parser's fact output.
//
// A fact is a four-element tuple. `:target` is a child node id when the role is
// an edge, or a scalar attribute otherwise. Repeated roles carry an ordinal.
package compiler

import "core:slice"
import "core:strings"
import v "../var"

// Renders a relational AST rooted at `root`. Returns "" if the relation is not
// a well-formed relational AST.
relation_ast_sexpr :: proc(
	root: int,
	facts: v.Value,
	allocator := context.allocator,
) -> string {
	rows, ok := v.value_as_relation(facts)
	if !ok {
		return ""
	}
	builder: strings.Builder
	strings.builder_init(&builder, allocator)
	rel_write_node(&builder, rows, root)
	return strings.to_string(builder)
}

// --- Fact lookup -----------------------------------------------------------

@(private)
Fact :: struct {
	role:    v.Symbol,
	target:  v.Value,
	ordinal: i64,
}

// Returns every fact for a node with a given role, sorted by ordinal.
@(private)
rel_facts :: proc(
	rows: ^v.Relation_Value,
	node: int,
	role: v.Symbol,
	allocator := context.temp_allocator,
) -> []Fact {
	out: [dynamic]Fact
	out = make([dynamic]Fact, 0, 4, allocator)
	for row in rows.rows {
		cells := v.tuple_values(row)
		if len(cells) != 4 {
			continue
		}
		row_node, node_ok := v.value_as_int(cells[0])
		row_role, role_ok := v.value_as_symbol(cells[1])
		if !node_ok || !role_ok || int(row_node) != node || row_role != role {
			continue
		}
		ordinal, _ := v.value_as_int(cells[3])
		append(&out, Fact{role = row_role, target = cells[2], ordinal = ordinal})
	}
	slice.sort_by(out[:], proc(a, b: Fact) -> bool { return a.ordinal < b.ordinal })
	return out[:]
}

// Returns the target of the first fact for `role`, or false when absent.
@(private)
rel_target :: proc(
	rows: ^v.Relation_Value,
	node: int,
	role: v.Symbol,
	allocator := context.temp_allocator,
) -> (v.Value, bool) {
	facts := rel_facts(rows, node, role, allocator)
	if len(facts) == 0 {
		return v.Value(0), false
	}
	return facts[0].target, true
}

@(private)
rel_kind :: proc(rows: ^v.Relation_Value, node: int) -> v.Symbol {
	target, ok := rel_target(rows, node, v.symbol_intern("kind"))
	if !ok {
		return v.Symbol(0)
	}
	symbol, _ := v.value_as_symbol(target)
	return symbol
}

@(private)
rel_child :: proc(rows: ^v.Relation_Value, node: int, role: string) -> (int, bool) {
	target, ok := rel_target(rows, node, v.symbol_intern(role))
	if !ok {
		return 0, false
	}
	value, is_int := v.value_as_int(target)
	if !is_int {
		return 0, false
	}
	return int(value), true
}

@(private)
rel_str :: proc(rows: ^v.Relation_Value, node: int, role: string) -> string {
	target, ok := rel_target(rows, node, v.symbol_intern(role))
	if !ok {
		return ""
	}
	text, _ := v.value_as_string(target)
	return text
}

@(private)
rel_int :: proc(rows: ^v.Relation_Value, node: int, role: string) -> i64 {
	target, ok := rel_target(rows, node, v.symbol_intern(role))
	if !ok {
		return 0
	}
	number, _ := v.value_as_int(target)
	return number
}

@(private)
rel_bool :: proc(rows: ^v.Relation_Value, node: int, role: string) -> bool {
	target, ok := rel_target(rows, node, v.symbol_intern(role))
	if !ok {
		return false
	}
	value, _ := v.value_as_bool(target)
	return value
}

@(private)
rel_symbol_name :: proc(symbol: v.Symbol) -> string {
	name, _ := v.symbol_name(symbol)
	return name
}

@(private)
rel_atom :: proc(builder: ^strings.Builder, text: string) {
	strings.write_byte(builder, '"')
	for byte in transmute([]u8)text {
		switch byte {
		case '"':
			strings.write_string(builder, "\\\"")
		case '\\':
			strings.write_string(builder, "\\\\")
		case:
			strings.write_byte(builder, byte)
		}
	}
	strings.write_byte(builder, '"')
}

// --- Node rendering --------------------------------------------------------

@(private)
rel_write_body :: proc(builder: ^strings.Builder, rows: ^v.Relation_Value, node: int, role: string) {
	facts := rel_facts(rows, node, v.symbol_intern(role))
	for fact in facts {
		child, _ := v.value_as_int(fact.target)
		strings.write_byte(builder, ' ')
		rel_write_node(builder, rows, int(child))
	}
}

@(private)
rel_write_params :: proc(builder: ^strings.Builder, rows: ^v.Relation_Value, node: int) {
	strings.write_string(builder, "(params")
	facts := rel_facts(rows, node, v.symbol_intern("param"))
	for fact in facts {
		param, _ := v.value_as_int(fact.target)
		strings.write_string(builder, " (param ")
		rel_atom(builder, rel_str(rows, int(param), "name"))
		strings.write_byte(builder, ' ')
		switch rel_symbol_name(rel_kind(rows, int(param))) {
		case "Required":
			strings.write_string(builder, "req")
		case "Optional":
			strings.write_string(builder, "opt")
		case "Rest":
			strings.write_string(builder, "rest")
		case:
		}
		if restrict, ok := rel_child(rows, int(param), "restrict"); ok {
			strings.write_string(builder, " (restrict ")
			rel_write_node(builder, rows, restrict)
			strings.write_byte(builder, ')')
		}
		if kind_text, ok := rel_target(rows, int(param), v.symbol_intern("kind-annotation")); ok {
			text, _ := v.value_as_string(kind_text)
			strings.write_string(builder, " (kind ")
			rel_atom(builder, text)
			strings.write_byte(builder, ')')
		}
		if default_value, ok := rel_child(rows, int(param), "default"); ok {
			strings.write_string(builder, " (default ")
			rel_write_node(builder, rows, default_value)
			strings.write_byte(builder, ')')
		}
		strings.write_byte(builder, ')')
	}
	strings.write_byte(builder, ')')
}

@(private)
rel_write_args :: proc(builder: ^strings.Builder, rows: ^v.Relation_Value, node: int) {
	facts := rel_facts(rows, node, v.symbol_intern("arg"))
	for fact in facts {
		arg, _ := v.value_as_int(fact.target)
		strings.write_string(builder, " (arg ")
		if role_text, ok := rel_target(rows, int(arg), v.symbol_intern("role")); ok {
			text, _ := v.value_as_string(role_text)
			rel_atom(builder, text)
			strings.write_byte(builder, ' ')
		}
		expr, _ := rel_child(rows, int(arg), "expr")
		rel_write_node(builder, rows, expr)
		strings.write_byte(builder, ')')
	}
}

@(private)
rel_write_pattern :: proc(builder: ^strings.Builder, rows: ^v.Relation_Value, node: int) {
	switch rel_symbol_name(rel_kind(rows, node)) {
	case "Binding_Pattern":
		strings.write_string(builder, "(bind-patt ")
		rel_atom(builder, rel_str(rows, node, "name"))
		strings.write_byte(builder, ')')
	case "Wildcard_Pattern":
		strings.write_string(builder, "(wild-patt)")
	case "Literal_Pattern":
		strings.write_string(builder, "(lit-patt ")
		value, _ := rel_child(rows, node, "value")
		rel_write_node(builder, rows, value)
		strings.write_byte(builder, ')')
	case "Rest_Pattern":
		strings.write_string(builder, "(rest-patt ")
		rel_atom(builder, rel_str(rows, node, "name"))
		strings.write_byte(builder, ')')
	case "Optional_Pattern":
		strings.write_string(builder, "(opt-patt ")
		rel_atom(builder, rel_str(rows, node, "name"))
		if default_value, ok := rel_child(rows, node, "default"); ok {
			strings.write_string(builder, " (default ")
			rel_write_node(builder, rows, default_value)
			strings.write_byte(builder, ')')
		}
		strings.write_byte(builder, ')')
	case "List_Pattern":
		strings.write_string(builder, "(list-patt")
		facts := rel_facts(rows, node, v.symbol_intern("element"))
		for fact in facts {
			element, _ := v.value_as_int(fact.target)
			strings.write_byte(builder, ' ')
			rel_write_pattern(builder, rows, int(element))
		}
		strings.write_byte(builder, ')')
	case "Map_Pattern":
		strings.write_string(builder, "(map-patt")
		facts := rel_facts(rows, node, v.symbol_intern("entry"))
		for fact in facts {
			entry, _ := v.value_as_int(fact.target)
			strings.write_string(builder, " (entry ")
			key, _ := rel_child(rows, int(entry), "key")
			rel_write_node(builder, rows, key)
			strings.write_byte(builder, ' ')
			pattern, _ := rel_child(rows, int(entry), "pattern")
			rel_write_pattern(builder, rows, pattern)
			strings.write_string(builder, rel_bool(rows, int(entry), "shorthand") ? " shorthand" : " long")
			strings.write_byte(builder, ')')
		}
		strings.write_byte(builder, ')')
	case "Call_Pattern":
		strings.write_string(builder, "(call-patt ")
		rel_atom(builder, rel_str(rows, node, "name"))
		facts := rel_facts(rows, node, v.symbol_intern("arg"))
		for fact in facts {
			argument, _ := v.value_as_int(fact.target)
			strings.write_byte(builder, ' ')
			rel_write_pattern(builder, rows, int(argument))
		}
		strings.write_byte(builder, ')')
	case:
		strings.write_string(builder, "(nil)")
	}
}

@(private)
rel_write_node :: proc(builder: ^strings.Builder, rows: ^v.Relation_Value, node: int) {
	kind := rel_symbol_name(rel_kind(rows, node))
	switch kind {
	case "Program":
		strings.write_string(builder, "(program")
		rel_write_body(builder, rows, node, "item")
		strings.write_byte(builder, ')')
	case "ExprItem":
		strings.write_string(builder, "(expr-item ")
		expr, _ := rel_child(rows, node, "expr")
		rel_write_node(builder, rows, expr)
		strings.write_byte(builder, ')')
	case "VerbItem":
		strings.write_string(builder, "(verb-item ")
		rel_atom(builder, rel_str(rows, node, "name"))
		strings.write_byte(builder, ' ')
		rel_write_params(builder, rows, node)
		strings.write_string(builder, " (result ")
		rel_atom(builder, rel_str(rows, node, "result"))
		strings.write_byte(builder, ')')
		rel_write_body(builder, rows, node, "body")
		strings.write_byte(builder, ')')
	case "RuleItem":
		strings.write_string(builder, "(rule-item (head ")
		head, _ := rel_child(rows, node, "head")
		rel_write_node(builder, rows, head)
		strings.write_byte(builder, ')')
		rel_write_body(builder, rows, node, "body")
		strings.write_byte(builder, ' ')
		rel_atom(builder, rel_str(rows, node, "source"))
		strings.write_byte(builder, ')')
	case "GrantItem":
		strings.write_string(builder, "(grant-item ")
		principal, _ := rel_child(rows, node, "principal")
		rel_write_node(builder, rows, principal)
		strings.write_string(builder, rel_bool(rows, node, "is-role") ? " role" : " principal")
		section_facts := rel_facts(rows, node, v.symbol_intern("section"))
		for fact in section_facts {
			section, _ := v.value_as_int(fact.target)
			strings.write_string(builder, " (section ")
			strings.write_string(builder, rel_symbol_name(rel_kind(rows, int(section))))
			entry_facts := rel_facts(rows, int(section), v.symbol_intern("entry"))
			for entry_fact in entry_facts {
				entry, _ := v.value_as_int(entry_fact.target)
				strings.write_byte(builder, ' ')
				rel_write_node(builder, rows, int(entry))
			}
			strings.write_byte(builder, ')')
		}
		strings.write_byte(builder, ')')

	case "Int_Literal":
		strings.write_string(builder, "(int ")
		rel_atom(builder, rel_str(rows, node, "text"))
		strings.write_byte(builder, ')')
	case "Float_Literal":
		strings.write_string(builder, "(float ")
		rel_atom(builder, rel_str(rows, node, "text"))
		strings.write_byte(builder, ')')
	case "String_Literal":
		strings.write_string(builder, "(string ")
		rel_atom(builder, rel_str(rows, node, "text"))
		strings.write_byte(builder, ')')
	case "Bytes_Literal":
		strings.write_string(builder, "(bytes ")
		rel_atom(builder, rel_str(rows, node, "text"))
		strings.write_byte(builder, ')')
	case "Bool_Literal":
		strings.write_string(builder, rel_bool(rows, node, "value") ? "(bool true)" : "(bool false)")
	case "Error_Code_Literal":
		strings.write_string(builder, "(error-code ")
		rel_atom(builder, rel_str(rows, node, "name"))
		strings.write_byte(builder, ')')
	case "Identity_Literal":
		strings.write_string(builder, "(identity ")
		rel_atom(builder, rel_str(rows, node, "name"))
		strings.write_byte(builder, ')')
	case "Symbol_Literal":
		strings.write_string(builder, "(symbol ")
		rel_atom(builder, rel_str(rows, node, "name"))
		strings.write_byte(builder, ')')
	case "Name":
		strings.write_string(builder, "(name")
		facts := rel_facts(rows, node, v.symbol_intern("part"))
		for fact in facts {
			text, _ := v.value_as_string(fact.target)
			strings.write_byte(builder, ' ')
			rel_atom(builder, text)
		}
		strings.write_byte(builder, ')')
	case "Query_Variable":
		strings.write_string(builder, "(qvar ")
		rel_atom(builder, rel_str(rows, node, "name"))
		strings.write_byte(builder, ')')
	case "Wildcard":
		strings.write_string(builder, "(wildcard)")
	case "Splice":
		strings.write_string(builder, "(splice ")
		value, _ := rel_child(rows, node, "value")
		rel_write_node(builder, rows, value)
		strings.write_byte(builder, ')')
	case "List_Literal":
		strings.write_string(builder, "(list")
		rel_write_body(builder, rows, node, "element")
		strings.write_byte(builder, ')')
	case "Relation_Literal":
		strings.write_string(builder, "(relation (heading")
		rel_write_body(builder, rows, node, "heading")
		strings.write_string(builder, ") (rows")
		rel_write_body(builder, rows, node, "row")
		strings.write_string(builder, "))")
	case "Map_Literal":
		strings.write_string(builder, "(map")
		facts := rel_facts(rows, node, v.symbol_intern("entry"))
		for fact in facts {
			entry, _ := v.value_as_int(fact.target)
			strings.write_string(builder, " (")
			key, _ := rel_child(rows, int(entry), "key")
			rel_write_node(builder, rows, key)
			strings.write_byte(builder, ' ')
			value, _ := rel_child(rows, int(entry), "value")
			rel_write_node(builder, rows, value)
			strings.write_byte(builder, ')')
		}
		strings.write_byte(builder, ')')
	case "Range_Literal":
		strings.write_string(builder, "(range ")
		start, _ := rel_child(rows, node, "start")
		rel_write_node(builder, rows, start)
		strings.write_byte(builder, ' ')
		if end, ok := rel_child(rows, node, "end"); ok {
			rel_write_node(builder, rows, end)
		} else {
			strings.write_byte(builder, '_')
		}
		strings.write_byte(builder, ')')
	case "Binding":
		strings.write_string(builder, "(binding ")
		strings.write_string(builder, rel_bool(rows, node, "is-const") ? "const" : "let")
		if rel_bool(rows, node, "is-exactly") {
			strings.write_string(builder, " exactly")
		}
		strings.write_byte(builder, ' ')
		pattern, _ := rel_child(rows, node, "pattern")
		rel_write_pattern(builder, rows, pattern)
		if kind_text, ok := rel_target(rows, node, v.symbol_intern("kind-annotation")); ok {
			text, _ := v.value_as_string(kind_text)
			strings.write_string(builder, " (kind ")
			rel_atom(builder, text)
			strings.write_byte(builder, ')')
		}
		if value, ok := rel_child(rows, node, "value"); ok {
			strings.write_string(builder, " (value ")
			rel_write_node(builder, rows, value)
			strings.write_byte(builder, ')')
		}
		strings.write_byte(builder, ')')
	case "Unary":
		strings.write_string(builder, "(unary ")
		strings.write_string(builder, rel_symbol_name(rel_kind_of(rows, node, "op")))
		strings.write_byte(builder, ' ')
		operand, _ := rel_child(rows, node, "operand")
		rel_write_node(builder, rows, operand)
		strings.write_byte(builder, ')')
	case "Binary":
		strings.write_string(builder, "(binary ")
		strings.write_string(builder, binary_op_name_from_symbol(rel_kind_of(rows, node, "op")))
		strings.write_byte(builder, ' ')
		left, _ := rel_child(rows, node, "left")
		rel_write_node(builder, rows, left)
		strings.write_byte(builder, ' ')
		right, _ := rel_child(rows, node, "right")
		rel_write_node(builder, rows, right)
		strings.write_byte(builder, ')')
	case "Assignment":
		strings.write_string(builder, "(assign ")
		target, _ := rel_child(rows, node, "target")
		rel_write_node(builder, rows, target)
		strings.write_byte(builder, ' ')
		value, _ := rel_child(rows, node, "value")
		rel_write_node(builder, rows, value)
		strings.write_byte(builder, ')')
	case "Call":
		strings.write_string(builder, "(call ")
		callee, _ := rel_child(rows, node, "callee")
		rel_write_node(builder, rows, callee)
		rel_write_args(builder, rows, node)
		strings.write_byte(builder, ')')
	case "Receiver_Call":
		strings.write_string(builder, "(rcall ")
		receiver, _ := rel_child(rows, node, "receiver")
		rel_write_node(builder, rows, receiver)
		strings.write_byte(builder, ' ')
		rel_atom(builder, rel_str(rows, node, "selector"))
		rel_write_args(builder, rows, node)
		strings.write_byte(builder, ')')
	case "Index":
		strings.write_string(builder, "(index ")
		collection, _ := rel_child(rows, node, "collection")
		rel_write_node(builder, rows, collection)
		strings.write_byte(builder, ' ')
		key, _ := rel_child(rows, node, "key")
		rel_write_node(builder, rows, key)
		strings.write_byte(builder, ')')
	case "Field":
		strings.write_string(builder, "(field ")
		receiver, _ := rel_child(rows, node, "receiver")
		rel_write_node(builder, rows, receiver)
		strings.write_byte(builder, ' ')
		rel_atom(builder, rel_str(rows, node, "name"))
		strings.write_byte(builder, ')')
	case "If":
		strings.write_string(builder, "(if")
		branch_facts := rel_facts(rows, node, v.symbol_intern("branch"))
		for fact in branch_facts {
			branch, _ := v.value_as_int(fact.target)
			strings.write_string(builder, " (")
			condition, _ := rel_child(rows, int(branch), "condition")
			rel_write_node(builder, rows, condition)
			rel_write_body(builder, rows, int(branch), "body")
			strings.write_byte(builder, ')')
		}
		if rel_bool(rows, node, "has-else") {
			strings.write_string(builder, " (else")
			rel_write_body(builder, rows, node, "else")
			strings.write_byte(builder, ')')
		}
		strings.write_byte(builder, ')')
	case "While":
		strings.write_string(builder, "(while ")
		condition, _ := rel_child(rows, node, "condition")
		rel_write_node(builder, rows, condition)
		rel_write_body(builder, rows, node, "body")
		strings.write_byte(builder, ')')
	case "For":
		strings.write_string(builder, "(for (names")
		name_facts := rel_facts(rows, node, v.symbol_intern("name"))
		for fact in name_facts {
			strings.write_string(builder, " (name ")
			rel_atom(builder, rel_str(rows, int(fact.target), "name"))
			kind_text := rel_str(rows, int(fact.target), "kind")
			if kind_text != "" {
				strings.write_byte(builder, ' ')
				rel_atom(builder, kind_text)
			}
			strings.write_byte(builder, ')')
		}
		strings.write_string(builder, ") ")
		iterable, _ := rel_child(rows, node, "iterable")
		rel_write_node(builder, rows, iterable)
		rel_write_body(builder, rows, node, "body")
		strings.write_byte(builder, ')')
	case "Begin":
		strings.write_string(builder, "(begin")
		rel_write_body(builder, rows, node, "body")
		strings.write_byte(builder, ')')
	case "Return":
		strings.write_string(builder, "(return")
		if value, ok := rel_child(rows, node, "value"); ok {
			strings.write_byte(builder, ' ')
			rel_write_node(builder, rows, value)
		}
		strings.write_byte(builder, ')')
	case "Break":
		strings.write_string(builder, "(break)")
	case "Continue":
		strings.write_string(builder, "(continue)")
	case "Assert":
		strings.write_string(builder, "(assert ")
		atom, _ := rel_child(rows, node, "atom")
		rel_write_node(builder, rows, atom)
		strings.write_byte(builder, ')')
	case "Retract":
		strings.write_string(builder, "(retract ")
		atom, _ := rel_child(rows, node, "atom")
		rel_write_node(builder, rows, atom)
		strings.write_byte(builder, ')')
	case "Require":
		strings.write_string(builder, "(require ")
		condition, _ := rel_child(rows, node, "condition")
		rel_write_node(builder, rows, condition)
		strings.write_byte(builder, ')')
	case "Raise":
		strings.write_string(builder, "(raise")
		rel_write_body(builder, rows, node, "part")
		strings.write_byte(builder, ')')
	case "Match":
		strings.write_string(builder, "(match ")
		value, _ := rel_child(rows, node, "value")
		rel_write_node(builder, rows, value)
		case_facts := rel_facts(rows, node, v.symbol_intern("case"))
		for fact in case_facts {
			case_node, _ := v.value_as_int(fact.target)
			strings.write_string(builder, " (")
			pattern, _ := rel_child(rows, int(case_node), "pattern")
			rel_write_pattern(builder, rows, pattern)
			if rel_bool(rows, int(case_node), "has-guard") {
				strings.write_string(builder, " (guard ")
				guard, _ := rel_child(rows, int(case_node), "guard")
				rel_write_node(builder, rows, guard)
				strings.write_byte(builder, ')')
			}
			rel_write_body(builder, rows, int(case_node), "body")
			strings.write_byte(builder, ')')
		}
		strings.write_byte(builder, ')')
	case "Try":
		strings.write_string(builder, "(try")
		rel_write_body(builder, rows, node, "body")
		catch_facts := rel_facts(rows, node, v.symbol_intern("catch"))
		for fact in catch_facts {
			clause, _ := v.value_as_int(fact.target)
			strings.write_string(builder, " (catch ")
			if rel_bool(rows, int(clause), "has-code") {
				rel_atom(builder, rel_str(rows, int(clause), "code"))
			} else {
				strings.write_byte(builder, '_')
			}
			strings.write_byte(builder, ' ')
			if rel_bool(rows, int(clause), "has-name") {
				rel_atom(builder, rel_str(rows, int(clause), "name"))
			} else {
				strings.write_byte(builder, '_')
			}
			rel_write_body(builder, rows, int(clause), "body")
			strings.write_byte(builder, ')')
		}
		if rel_bool(rows, node, "has-finally") {
			strings.write_string(builder, " (finally")
			rel_write_body(builder, rows, node, "finally")
			strings.write_byte(builder, ')')
		}
		strings.write_byte(builder, ')')
	case "Spawn":
		strings.write_string(builder, "(spawn ")
		call, _ := rel_child(rows, node, "call")
		rel_write_node(builder, rows, call)
		if rel_bool(rows, node, "has-delay") {
			strings.write_string(builder, " (after ")
			delay, _ := rel_child(rows, node, "delay")
			rel_write_node(builder, rows, delay)
			strings.write_byte(builder, ')')
		}
		strings.write_byte(builder, ')')
	case "Structural_Literal":
		strings.write_string(builder, "(structural ")
		head, _ := rel_child(rows, node, "head")
		rel_write_node(builder, rows, head)
		strings.write_string(builder, rel_bool(rows, node, "named") ? " named" : " positional")
		cell_facts := rel_facts(rows, node, v.symbol_intern("cell"))
		for fact in cell_facts {
			cell, _ := v.value_as_int(fact.target)
			strings.write_string(builder, " (")
			if name, ok := rel_child(rows, int(cell), "name"); ok {
				rel_write_node(builder, rows, name)
			} else {
				strings.write_byte(builder, '_')
			}
			strings.write_byte(builder, ' ')
			value, _ := rel_child(rows, int(cell), "value")
			rel_write_node(builder, rows, value)
			strings.write_byte(builder, ')')
		}
		strings.write_byte(builder, ')')
	case "Dom_Text":
		strings.write_string(builder, "(dom-text ")
		rel_atom(builder, rel_str(rows, node, "text"))
		strings.write_byte(builder, ')')
	case "Dom_Element":
		strings.write_string(builder, "(dom-element ")
		rel_atom(builder, rel_str(rows, node, "tag"))
		attr_facts := rel_facts(rows, node, v.symbol_intern("attribute"))
		for fact in attr_facts {
			attribute, _ := v.value_as_int(fact.target)
			strings.write_string(builder, " (attr ")
			rel_atom(builder, rel_str(rows, int(attribute), "name"))
			if value, ok := rel_child(rows, int(attribute), "value"); ok {
				strings.write_byte(builder, ' ')
				rel_write_node(builder, rows, value)
			} else {
				strings.write_string(builder, " present")
			}
			strings.write_byte(builder, ')')
		}
		strings.write_string(builder, rel_bool(rows, node, "self-closing") ? " self" : " paired")
		rel_write_body(builder, rows, node, "child")
		strings.write_byte(builder, ')')
	case "Fn":
		strings.write_string(builder, "(fn ")
		rel_write_params(builder, rows, node)
		if rel_bool(rows, node, "has-expression-body") {
			strings.write_string(builder, " (=> ")
			body, _ := rel_child(rows, node, "expression-body")
			rel_write_node(builder, rows, body)
			strings.write_byte(builder, ')')
		} else {
			rel_write_body(builder, rows, node, "body")
		}
		strings.write_byte(builder, ')')
	case:
		strings.write_string(builder, "(unknown:")
		strings.write_string(builder, kind)
		strings.write_byte(builder, ')')
	}
}

// Reads a symbol-valued attribute role on a node, for `:op` and the like.
@(private)
rel_kind_of :: proc(rows: ^v.Relation_Value, node: int, role: string) -> v.Symbol {
	target, ok := rel_target(rows, node, v.symbol_intern(role))
	if !ok {
		return v.Symbol(0)
	}
	symbol, _ := v.value_as_symbol(target)
	return symbol
}

@(private)
binary_op_name_from_symbol :: proc(symbol: v.Symbol) -> string {
	name, _ := v.symbol_name(symbol)
	return name
}
