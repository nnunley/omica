// Canonical S-expression rendering of the AST.
//
// The Mica parser (`apps/compiler/parse.mica`) produces a relational AST and
// renders it to this same form. The differential test parses each corpus file
// with both parsers and compares the two renderings, so structural equivalence
// is checked without coupling node identities.
//
// Grammar (a node is `(tag field...)`):
//
//   program     (program item...)
//   item        (expr-item e) | (verb-item "name" (param...) (result "type") body...)
//               | (rule-item (head e) body... "source")
//               | (grant-item principal role|principal (section kind entry...)...)
//   literals    (int "t") (float "t") (string "t") (bytes "t") (bool true|false)
//               (error-code "n") (identity "n") (symbol "n") (name "p"...) (qvar "n")
//               (wildcard) (splice e)
//   composite   (list e...) (relation (heading e...) (rows e...))
//               (map (e e)...) (range e e|_) (structural head named|positional (n|- value)...)
//   control     (binding let|const [exactly] pat (kind "t")? (value e)?)
//               (unary neg|not e) (binary op e e) (assign e e)
//               (call e (arg [role] e)...) (rcall e "sel" (arg...)...) (index e e) (field e "n")
//               (if (cond body...)... (else body...)?) (while cond body...)
//               (for (name "n" "k"?...) iter body...) (begin e...) (return e?) (break) (continue)
//               (assert e) (retract e) (require e) (raise e...)
//               (match e (pat (guard g)? body...)...)
//               (try body... (catch c|_ n|_ body...)... (finally body...)?)
//               (spawn call (after d)?) (fn (param...) body... | (fn (param...) => e))
//   dom         (dom-text "t") (dom-element "tag" (attr "n" v|present)... self|paired child...)
//   pattern     (bind-patt "n") (wild-patt) (lit-patt e) (rest-patt "n") (opt-patt "n" (default e)?)
//               (list-patt p...) (map-patt (entry key patt shorthand|long)...) (call-patt "n" p...)
//   param       (param "n" req|opt|rest (restrict e)? (kind "t")? (default e)?)
//
// This is a debug and test utility; it is not part of compilation.
package compiler

import "core:strings"

// Renders a program to its canonical S-expression. The caller owns the result.
ast_sexpr :: proc(program: ^Program_AST, allocator := context.allocator) -> string {
	builder: strings.Builder
	strings.builder_init(&builder, allocator)
	write_sexpr_string(&builder, "(program")
	for item in program.items {
		strings.write_byte(&builder, ' ')
		sexpr_item(&builder, item)
	}
	strings.write_byte(&builder, ')')
	return strings.to_string(builder)
}

@(private)
sexpr_atom :: proc(builder: ^strings.Builder, text: string) {
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

@(private)
write_sexpr_string :: proc(builder: ^strings.Builder, text: string) {
	strings.write_string(builder, text)
}

// --- Items -----------------------------------------------------------------

@(private)
sexpr_item :: proc(builder: ^strings.Builder, item: Item) {
	#partial switch n in item {
	case Expr_Item:
		strings.write_string(builder, "(expr-item ")
		sexpr_expr(builder, n.expr)
		strings.write_byte(builder, ')')
	case Verb_Item:
		strings.write_string(builder, "(verb-item ")
		sexpr_atom(builder, n.name)
		strings.write_byte(builder, ' ')
		sexpr_params(builder, n.params)
		strings.write_string(builder, " (result ")
		sexpr_atom(builder, n.result_type)
		strings.write_byte(builder, ')')
		for expr in n.body {
			strings.write_byte(builder, ' ')
			sexpr_expr(builder, expr)
		}
		strings.write_byte(builder, ')')
	case Rule_Item:
		strings.write_string(builder, "(rule-item (head ")
		sexpr_expr(builder, n.head)
		strings.write_byte(builder, ')')
		for expr in n.body {
			strings.write_byte(builder, ' ')
			sexpr_expr(builder, expr)
		}
		strings.write_byte(builder, ' ')
		sexpr_atom(builder, n.source)
		strings.write_byte(builder, ')')
	case Grant_Item:
		strings.write_string(builder, "(grant-item ")
		sexpr_expr(builder, n.principal)
		strings.write_string(builder, n.is_role ? " role" : " principal")
		for section in n.sections {
			strings.write_string(builder, " (section ")
			strings.write_string(builder, grant_section_name(section.kind))
			for entry in section.entries {
				strings.write_byte(builder, ' ')
				sexpr_expr(builder, entry)
			}
			strings.write_byte(builder, ')')
		}
		strings.write_byte(builder, ')')
	}
}

@(private)
grant_section_name :: proc(kind: Grant_Section_Kind) -> string {
	switch kind {
	case .Read:
		return "read"
	case .Write:
		return "write"
	case .Invoke:
		return "invoke"
	case .Effect:
		return "effect"
	}
	return "read"
}

@(private)
sexpr_params :: proc(builder: ^strings.Builder, params: []Param) {
	strings.write_string(builder, "(params")
	for param in params {
		strings.write_string(builder, " (param ")
		sexpr_atom(builder, param.name)
		strings.write_byte(builder, ' ')
		switch param.mode {
		case .Required:
			strings.write_string(builder, "req")
		case .Optional:
			strings.write_string(builder, "opt")
		case .Rest:
			strings.write_string(builder, "rest")
		}
		if param.has_restriction {
			strings.write_string(builder, " (restrict ")
			sexpr_expr(builder, param.restriction)
			strings.write_byte(builder, ')')
		}
		if param.has_kind {
			strings.write_string(builder, " (kind ")
			sexpr_atom(builder, param.kind)
			strings.write_byte(builder, ')')
		}
		if param.has_default {
			strings.write_string(builder, " (default ")
			sexpr_expr(builder, param.default)
			strings.write_byte(builder, ')')
		}
		strings.write_byte(builder, ')')
	}
	strings.write_byte(builder, ')')
}

// --- Expressions -----------------------------------------------------------

@(private)
sexpr_expr :: proc(builder: ^strings.Builder, expr: ^Expr) {
	if expr == nil {
		strings.write_string(builder, "(nil)")
		return
	}
	#partial switch n in expr^ {
	case Int_Literal:
		strings.write_string(builder, "(int ")
		sexpr_atom(builder, n.text)
		strings.write_byte(builder, ')')
	case Float_Literal:
		strings.write_string(builder, "(float ")
		sexpr_atom(builder, n.text)
		strings.write_byte(builder, ')')
	case String_Literal:
		strings.write_string(builder, "(string ")
		sexpr_atom(builder, n.text)
		strings.write_byte(builder, ')')
	case Bytes_Literal:
		strings.write_string(builder, "(bytes ")
		sexpr_atom(builder, n.text)
		strings.write_byte(builder, ')')
	case Bool_Literal:
		strings.write_string(builder, n.value ? "(bool true)" : "(bool false)")
	case Error_Code_Literal:
		strings.write_string(builder, "(error-code ")
		sexpr_atom(builder, n.name)
		strings.write_byte(builder, ')')
	case Identity_Literal:
		strings.write_string(builder, "(identity ")
		sexpr_atom(builder, n.name)
		strings.write_byte(builder, ')')
	case Symbol_Literal:
		strings.write_string(builder, "(symbol ")
		sexpr_atom(builder, n.name)
		strings.write_byte(builder, ')')
	case Name:
		strings.write_string(builder, "(name")
		for part in n.parts {
			strings.write_byte(builder, ' ')
			sexpr_atom(builder, part)
		}
		strings.write_byte(builder, ')')
	case Query_Variable:
		strings.write_string(builder, "(qvar ")
		sexpr_atom(builder, n.name)
		strings.write_byte(builder, ')')
	case Wildcard:
		strings.write_string(builder, "(wildcard)")
	case Splice:
		strings.write_string(builder, "(splice ")
		sexpr_expr(builder, n.value)
		strings.write_byte(builder, ')')
	case List_Literal:
		strings.write_string(builder, "(list")
		for element in n.elements {
			strings.write_byte(builder, ' ')
			sexpr_expr(builder, element)
		}
		strings.write_byte(builder, ')')
	case Relation_Literal:
		strings.write_string(builder, "(relation (heading")
		for heading in n.heading {
			strings.write_byte(builder, ' ')
			sexpr_expr(builder, heading)
		}
		strings.write_string(builder, ") (rows")
		for row in n.rows {
			strings.write_byte(builder, ' ')
			sexpr_expr(builder, row)
		}
		strings.write_string(builder, "))")
	case Map_Literal:
		strings.write_string(builder, "(map")
		for entry in n.entries {
			strings.write_string(builder, " (")
			sexpr_expr(builder, entry.key)
			strings.write_byte(builder, ' ')
			sexpr_expr(builder, entry.value)
			strings.write_byte(builder, ')')
		}
		strings.write_byte(builder, ')')
	case Range_Literal:
		strings.write_string(builder, "(range ")
		sexpr_expr(builder, n.start)
		strings.write_byte(builder, ' ')
		if n.has_end {
			sexpr_expr(builder, n.end)
		} else {
			strings.write_byte(builder, '_')
		}
		strings.write_byte(builder, ')')
	case Binding:
		strings.write_string(builder, "(binding ")
		strings.write_string(builder, n.is_const ? "const" : "let")
		if n.is_exactly {
			strings.write_string(builder, " exactly")
		}
		strings.write_byte(builder, ' ')
		sexpr_pattern(builder, n.pattern)
		if n.has_kind {
			strings.write_string(builder, " (kind ")
			sexpr_atom(builder, n.kind)
			strings.write_byte(builder, ')')
		}
		if n.has_value {
			strings.write_string(builder, " (value ")
			sexpr_expr(builder, n.value)
			strings.write_byte(builder, ')')
		}
		strings.write_byte(builder, ')')
	case Unary:
		strings.write_string(builder, "(unary ")
		strings.write_string(builder, n.op == .Neg ? "neg" : "not")
		strings.write_byte(builder, ' ')
		sexpr_expr(builder, n.operand)
		strings.write_byte(builder, ')')
	case Binary:
		strings.write_string(builder, "(binary ")
		strings.write_string(builder, binary_op_name(n.op))
		strings.write_byte(builder, ' ')
		sexpr_expr(builder, n.left)
		strings.write_byte(builder, ' ')
		sexpr_expr(builder, n.right)
		strings.write_byte(builder, ')')
	case Assignment:
		strings.write_string(builder, "(assign ")
		sexpr_expr(builder, n.target)
		strings.write_byte(builder, ' ')
		sexpr_expr(builder, n.value)
		strings.write_byte(builder, ')')
	case Call:
		strings.write_string(builder, "(call ")
		sexpr_expr(builder, n.callee)
		sexpr_args(builder, n.args)
		strings.write_byte(builder, ')')
	case Receiver_Call:
		strings.write_string(builder, "(rcall ")
		sexpr_expr(builder, n.receiver)
		strings.write_byte(builder, ' ')
		sexpr_atom(builder, n.selector)
		sexpr_args(builder, n.args)
		strings.write_byte(builder, ')')
	case Index:
		strings.write_string(builder, "(index ")
		sexpr_expr(builder, n.collection)
		strings.write_byte(builder, ' ')
		sexpr_expr(builder, n.key)
		strings.write_byte(builder, ')')
	case Field:
		strings.write_string(builder, "(field ")
		sexpr_expr(builder, n.receiver)
		strings.write_byte(builder, ' ')
		sexpr_atom(builder, n.name)
		strings.write_byte(builder, ')')
	case If:
		strings.write_string(builder, "(if")
		for branch in n.branches {
			strings.write_string(builder, " (")
			sexpr_expr(builder, branch.condition)
			sexpr_body(builder, branch.body)
			strings.write_byte(builder, ')')
		}
		if n.has_else {
			strings.write_string(builder, " (else")
			sexpr_body(builder, n.else_body)
			strings.write_byte(builder, ')')
		}
		strings.write_byte(builder, ')')
	case While:
		strings.write_string(builder, "(while ")
		sexpr_expr(builder, n.condition)
		sexpr_body(builder, n.body)
		strings.write_byte(builder, ')')
	case For:
		strings.write_string(builder, "(for (names")
		for name, index in n.names {
			strings.write_string(builder, " (name ")
			sexpr_atom(builder, name)
			if index < len(n.kinds) && n.kinds[index] != "" {
				strings.write_byte(builder, ' ')
				sexpr_atom(builder, n.kinds[index])
			}
			strings.write_byte(builder, ')')
		}
		strings.write_string(builder, ") ")
		sexpr_expr(builder, n.iterable)
		sexpr_body(builder, n.body)
		strings.write_byte(builder, ')')
	case Begin:
		strings.write_string(builder, "(begin")
		sexpr_body(builder, n.body)
		strings.write_byte(builder, ')')
	case Return:
		strings.write_string(builder, "(return")
		if n.has_value {
			strings.write_byte(builder, ' ')
			sexpr_expr(builder, n.value)
		}
		strings.write_byte(builder, ')')
	case Break:
		strings.write_string(builder, "(break)")
	case Continue:
		strings.write_string(builder, "(continue)")
	case Assert:
		strings.write_string(builder, "(assert ")
		sexpr_expr(builder, n.atom)
		strings.write_byte(builder, ')')
	case Retract:
		strings.write_string(builder, "(retract ")
		sexpr_expr(builder, n.atom)
		strings.write_byte(builder, ')')
	case Require:
		strings.write_string(builder, "(require ")
		sexpr_expr(builder, n.condition)
		strings.write_byte(builder, ')')
	case Raise:
		strings.write_string(builder, "(raise")
		for part in n.parts {
			strings.write_byte(builder, ' ')
			sexpr_expr(builder, part)
		}
		strings.write_byte(builder, ')')
	case Match:
		strings.write_string(builder, "(match ")
		sexpr_expr(builder, n.value)
		for case_clause in n.cases {
			strings.write_string(builder, " (")
			sexpr_pattern(builder, case_clause.pattern)
			if case_clause.has_guard {
				strings.write_string(builder, " (guard ")
				sexpr_expr(builder, case_clause.guard)
				strings.write_byte(builder, ')')
			}
			sexpr_body(builder, case_clause.body)
			strings.write_byte(builder, ')')
		}
		strings.write_byte(builder, ')')
	case Try:
		strings.write_string(builder, "(try")
		sexpr_body(builder, n.body)
		for clause in n.catches {
			strings.write_string(builder, " (catch ")
			if clause.has_code {
				sexpr_atom(builder, clause.code)
			} else {
				strings.write_byte(builder, '_')
			}
			strings.write_byte(builder, ' ')
			if clause.has_name {
				sexpr_atom(builder, clause.name)
			} else {
				strings.write_byte(builder, '_')
			}
			sexpr_body(builder, clause.body)
			strings.write_byte(builder, ')')
		}
		if n.has_finally {
			strings.write_string(builder, " (finally")
			sexpr_body(builder, n.finally_body)
			strings.write_byte(builder, ')')
		}
		strings.write_byte(builder, ')')
	case Spawn:
		strings.write_string(builder, "(spawn ")
		sexpr_expr(builder, n.call)
		if n.has_delay {
			strings.write_string(builder, " (after ")
			sexpr_expr(builder, n.delay)
			strings.write_byte(builder, ')')
		}
		strings.write_byte(builder, ')')
	case Structural_Literal:
		strings.write_string(builder, "(structural ")
		sexpr_expr(builder, n.head)
		strings.write_string(builder, n.named ? " named" : " positional")
		for cell in n.cells {
			strings.write_string(builder, " (")
			if cell.name != nil {
				sexpr_expr(builder, cell.name)
			} else {
				strings.write_byte(builder, '_')
			}
			strings.write_byte(builder, ' ')
			sexpr_expr(builder, cell.value)
			strings.write_byte(builder, ')')
		}
		strings.write_byte(builder, ')')
	case Dom_Text:
		strings.write_string(builder, "(dom-text ")
		sexpr_atom(builder, n.text)
		strings.write_byte(builder, ')')
	case Dom_Element:
		strings.write_string(builder, "(dom-element ")
		sexpr_atom(builder, n.tag)
		for attribute in n.attributes {
			strings.write_string(builder, " (attr ")
			sexpr_atom(builder, attribute.name)
			if attribute.has_value {
				strings.write_byte(builder, ' ')
				sexpr_expr(builder, attribute.value)
			} else {
				strings.write_string(builder, " present")
			}
			strings.write_byte(builder, ')')
		}
		strings.write_string(builder, n.self_closing ? " self" : " paired")
		for child in n.children {
			strings.write_byte(builder, ' ')
			sexpr_expr(builder, child)
		}
		strings.write_byte(builder, ')')
	case Fn:
		strings.write_string(builder, "(fn ")
		sexpr_params(builder, n.params)
		if n.has_expression_body {
			strings.write_string(builder, " (=> ")
			sexpr_expr(builder, n.expression_body)
			strings.write_byte(builder, ')')
		} else {
			sexpr_body(builder, n.body)
		}
		strings.write_byte(builder, ')')
	}
}

@(private)
sexpr_args :: proc(builder: ^strings.Builder, args: []Call_Argument) {
	for argument in args {
		strings.write_string(builder, " (arg ")
		if argument.has_role {
			sexpr_atom(builder, argument.role)
			strings.write_byte(builder, ' ')
		}
		sexpr_expr(builder, argument.expr)
		strings.write_byte(builder, ')')
	}
}

@(private)
sexpr_body :: proc(builder: ^strings.Builder, body: []^Expr) {
	for expr in body {
		strings.write_byte(builder, ' ')
		sexpr_expr(builder, expr)
	}
}

@(private)
binary_op_name :: proc(op: Binary_Op) -> string {
	switch op {
	case .Add:
		return "add"
	case .Sub:
		return "sub"
	case .Mul:
		return "mul"
	case .Div:
		return "div"
	case .Rem:
		return "rem"
	case .Range:
		return "range"
	case .Lt:
		return "lt"
	case .Le:
		return "le"
	case .Gt:
		return "gt"
	case .Ge:
		return "ge"
	case .Eq:
		return "eq"
	case .Ne:
		return "ne"
	case .And:
		return "and"
	case .Or:
		return "or"
	}
	return "add"
}

// --- Patterns --------------------------------------------------------------

@(private)
sexpr_pattern :: proc(builder: ^strings.Builder, pattern: ^Pattern) {
	if pattern == nil {
		strings.write_string(builder, "(nil)")
		return
	}
	#partial switch n in pattern^ {
	case Binding_Pattern:
		strings.write_string(builder, "(bind-patt ")
		sexpr_atom(builder, n.name)
		strings.write_byte(builder, ')')
	case Wildcard_Pattern:
		strings.write_string(builder, "(wild-patt)")
	case Literal_Pattern:
		strings.write_string(builder, "(lit-patt ")
		sexpr_expr(builder, n.value)
		strings.write_byte(builder, ')')
	case Rest_Pattern:
		strings.write_string(builder, "(rest-patt ")
		sexpr_atom(builder, n.name)
		strings.write_byte(builder, ')')
	case Optional_Pattern:
		strings.write_string(builder, "(opt-patt ")
		sexpr_atom(builder, n.name)
		if n.has_default {
			strings.write_string(builder, " (default ")
			sexpr_expr(builder, n.default)
			strings.write_byte(builder, ')')
		}
		strings.write_byte(builder, ')')
	case List_Pattern:
		strings.write_string(builder, "(list-patt")
		for element in n.elements {
			strings.write_byte(builder, ' ')
			sexpr_pattern(builder, element)
		}
		strings.write_byte(builder, ')')
	case Map_Pattern:
		strings.write_string(builder, "(map-patt")
		for entry in n.entries {
			strings.write_string(builder, " (entry ")
			sexpr_expr(builder, entry.key)
			strings.write_byte(builder, ' ')
			sexpr_pattern(builder, entry.pattern)
			strings.write_string(builder, entry.shorthand ? " shorthand" : " long")
			strings.write_byte(builder, ')')
		}
		strings.write_byte(builder, ')')
	case Call_Pattern:
		strings.write_string(builder, "(call-patt ")
		sexpr_atom(builder, n.name)
		for argument in n.args {
			strings.write_byte(builder, ' ')
			sexpr_pattern(builder, argument)
		}
		strings.write_byte(builder, ')')
	}
}
