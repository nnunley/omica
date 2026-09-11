// Recursive-descent parser for the Mica surface language.
//
// The parser produces the AST in `ast.odin`. It is error-tolerant: on a
// syntax error it records a diagnostic and skips to the next separator instead
// of aborting. Qualified names are assembled only when the `/` is adjacent to
// both identifiers, so `a/b` is a name while `a / b` is division.
package compiler

import "core:mem"
import "core:strings"

Parse_Error :: struct {
	message: string,
	line:    int,
	column:  int,
}

Parser :: struct {
	tokens:    []Token,
	pos:       int,
	allocator: mem.Allocator,
	errors:    [dynamic]Parse_Error,
}

// Parses source text into a program AST. The AST and diagnostics are
// allocated from `allocator`.
parse_program :: proc(
	source: string,
	allocator := context.allocator,
) -> (
	^Program_AST,
	[]Parse_Error,
) {
	lexed := lex(source, allocator)
	parser := Parser {
		tokens    = lexed.tokens,
		allocator = allocator,
	}
	for lex_error in lexed.errors {
		append(&parser.errors, Parse_Error {
			message = lex_error.message,
			line    = lex_error.line,
			column  = lex_error.column,
		})
	}

	items: [dynamic]Item
	skip_separators(&parser)
	for !at(&parser, .Eof) {
		append(&items, parse_item(&parser))
		if at(&parser, .Eof) {
			break
		}
		if !at_separator(&parser) {
			error_here(&parser, "expected newline or semicolon after item")
			for !at(&parser, .Eof) && !at_separator(&parser) {
				advance(&parser)
			}
		}
		skip_separators(&parser)
	}

	program := new(Program_AST, allocator)
	owned := make([]Item, len(items), allocator)
	copy(owned, items[:])
	program.items = owned
	delete(items)

	errors := make([]Parse_Error, len(parser.errors), allocator)
	copy(errors, parser.errors[:])
	delete(parser.errors)
	return program, errors
}

// --- Token helpers ---------------------------------------------------------

@(private)
peek :: proc(parser: ^Parser) -> Token {
	return parser.tokens[parser.pos]
}

@(private)
peek_at :: proc(parser: ^Parser, offset: int) -> Token {
	index := parser.pos + offset
	if index >= len(parser.tokens) {
		return parser.tokens[len(parser.tokens) - 1]
	}
	return parser.tokens[index]
}

@(private)
at :: proc(parser: ^Parser, kind: Token_Kind) -> bool {
	return peek(parser).kind == kind
}

@(private)
at_any :: proc(parser: ^Parser, kinds: []Token_Kind) -> bool {
	kind := peek(parser).kind
	for candidate in kinds {
		if candidate == kind {
			return true
		}
	}
	return false
}

@(private)
at_separator :: proc(parser: ^Parser) -> bool {
	kind := peek(parser).kind
	return kind == .Newline || kind == .Semi
}

@(private)
advance :: proc(parser: ^Parser) -> Token {
	token := peek(parser)
	if token.kind != .Eof {
		parser.pos += 1
	}
	return token
}

@(private)
match :: proc(parser: ^Parser, kind: Token_Kind) -> (Token, bool) {
	if at(parser, kind) {
		return advance(parser), true
	}
	return Token{}, false
}

@(private)
expect :: proc(parser: ^Parser, kind: Token_Kind, message: string) -> Token {
	if at(parser, kind) {
		return advance(parser)
	}
	error_here(parser, message)
	return peek(parser)
}

@(private)
error_here :: proc(parser: ^Parser, message: string) {
	token := peek(parser)
	append(&parser.errors, Parse_Error {
		message = message,
		line    = token.line,
		column  = token.column,
	})
}

@(private)
skip_separators :: proc(parser: ^Parser) {
	for at_separator(parser) {
		advance(parser)
	}
}

@(private)
skip_newlines :: proc(parser: ^Parser) {
	for at(parser, .Newline) {
		advance(parser)
	}
}

@(private)
tokens_adjacent :: proc(left, right: Token) -> bool {
	return left.line == right.line && left.column + len(left.text) == right.column
}

// --- Node helpers ----------------------------------------------------------

@(private)
expr_node :: proc(parser: ^Parser, value: $T) -> ^Expr {
	node := new(Expr, parser.allocator)
	node^ = value
	return node
}

@(private)
to_slice :: proc(parser: ^Parser, items: [dynamic]$T) -> []T {
	owned := make([]T, len(items), parser.allocator)
	copy(owned, items[:])
	delete(items)
	return owned
}

// --- Items -----------------------------------------------------------------

@(private)
parse_item :: proc(parser: ^Parser) -> Item {
	#partial switch peek(parser).kind {
	case .Verb, .Method:
		return parse_verb(parser)
	case:
		head := parse_expression(parser)
		if at(parser, .Colon_Dash) {
			advance(parser)
			body := parse_rule_body(parser)
			return Rule_Item{head = head, body = body}
		}
		return Expr_Item{expr = head}
	}
}

@(private)
parse_verb :: proc(parser: ^Parser) -> Item {
	advance(parser)
	name_token := expect(parser, .Ident, "expected verb name")
	expect(parser, .LParen, "expected '(' after verb name")
	params := parse_params(parser)
	expect(parser, .RParen, "expected ')' after verb parameters")
	result_type := ""
	if at(parser, .Arrow) {
		advance(parser)
		result_type = expect(parser, .Ident, "expected result kind after '->'").text
	}
	skip_separators(parser)
	body := parse_block_until(parser, []Token_Kind{.End})
	expect(parser, .End, "expected 'end' to close verb")
	return Verb_Item {
		name        = name_token.text,
		params      = params,
		result_type = result_type,
		body        = body,
	}
}

@(private)
parse_params :: proc(parser: ^Parser) -> []Param {
	params: [dynamic]Param
	skip_newlines(parser)
	for !at(parser, .RParen) && !at(parser, .Eof) {
		name_token := expect(parser, .Ident, "expected parameter name")
		param := Param{name = name_token.text}
		if at(parser, .At) {
			advance(parser)
			param.restriction = parse_unary(parser)
			param.has_restriction = true
		}
		if at(parser, .Colon) {
			advance(parser)
			param.kind = expect(parser, .Ident, "expected kind after ':'").text
			param.has_kind = true
		}
		append(&params, param)
		if at(parser, .Comma) {
			advance(parser)
			skip_newlines(parser)
			continue
		}
		break
	}
	return to_slice(parser, params)
}

@(private)
parse_rule_body :: proc(parser: ^Parser) -> []^Expr {
	items: [dynamic]^Expr
	skip_newlines(parser)
	for !at_separator(parser) && !at(parser, .Eof) {
		append(&items, parse_expression(parser))
		skip_newlines(parser)
		if at(parser, .Comma) {
			advance(parser)
			skip_newlines(parser)
			continue
		}
		break
	}
	return to_slice(parser, items)
}

@(private)
parse_block_until :: proc(parser: ^Parser, stops: []Token_Kind) -> []^Expr {
	body: [dynamic]^Expr
	skip_separators(parser)
	for !at(parser, .Eof) {
		if at_any(parser, stops) {
			break
		}
		append(&body, parse_expression(parser))
		if !at_separator(parser) && !at_any(parser, stops) && !at(parser, .Eof) {
			error_here(parser, "expected newline or a block terminator")
			for !at(parser, .Eof) && !at_separator(parser) {
				advance(parser)
			}
		}
		skip_separators(parser)
	}
	return to_slice(parser, body)
}

// --- Statements ------------------------------------------------------------

@(private)
parse_expression :: proc(parser: ^Parser) -> ^Expr {
	#partial switch peek(parser).kind {
	case .Let:
		return parse_binding(parser, false)
	case .Const:
		return parse_binding(parser, true)
	case .If:
		return parse_if(parser)
	case .While:
		return parse_while(parser)
	case .For:
		return parse_for(parser)
	case .Begin:
		return parse_begin(parser)
	case .Return:
		return parse_return(parser)
	case .Break:
		advance(parser)
		return expr_node(parser, Break{})
	case .Continue:
		advance(parser)
		return expr_node(parser, Continue{})
	case .Assert:
		advance(parser)
		return expr_node(parser, Assert{atom = parse_expression(parser)})
	case .Retract:
		advance(parser)
		return expr_node(parser, Retract{atom = parse_expression(parser)})
	case .Require:
		advance(parser)
		return expr_node(parser, Require{condition = parse_expression(parser)})
	case .Raise:
		return parse_raise(parser)
	case .Fn:
		return parse_fn(parser)
	case:
		return parse_assignment(parser)
	}
}

@(private)
parse_binding :: proc(parser: ^Parser, is_const: bool) -> ^Expr {
	advance(parser)
	name_token := expect(parser, .Ident, "expected binding name")
	binding := Binding{is_const = is_const, name = name_token.text}
	if at(parser, .Colon) {
		advance(parser)
		binding.kind = expect(parser, .Ident, "expected kind after ':'").text
		binding.has_kind = true
	}
	expect(parser, .Eq, "expected '=' in binding")
	binding.value = parse_expression(parser)
	return expr_node(parser, binding)
}

@(private)
parse_if :: proc(parser: ^Parser) -> ^Expr {
	advance(parser)
	branches: [dynamic]If_Branch
	condition := parse_expression(parser)
	skip_separators(parser)
	body := parse_block_until(parser, []Token_Kind{.Elseif, .Else, .End})
	append(&branches, If_Branch{condition = condition, body = body})

	for at(parser, .Elseif) {
		advance(parser)
		condition = parse_expression(parser)
		skip_separators(parser)
		body = parse_block_until(parser, []Token_Kind{.Elseif, .Else, .End})
		append(&branches, If_Branch{condition = condition, body = body})
	}

	result := If{branches = to_slice(parser, branches)}
	if at(parser, .Else) {
		advance(parser)
		result.else_body = parse_block_until(parser, []Token_Kind{.End})
		result.has_else = true
	}
	expect(parser, .End, "expected 'end' to close if")
	return expr_node(parser, result)
}

@(private)
parse_while :: proc(parser: ^Parser) -> ^Expr {
	advance(parser)
	condition := parse_expression(parser)
	skip_separators(parser)
	body := parse_block_until(parser, []Token_Kind{.End})
	expect(parser, .End, "expected 'end' to close while")
	return expr_node(parser, While{condition = condition, body = body})
}

@(private)
parse_for :: proc(parser: ^Parser) -> ^Expr {
	advance(parser)
	names: [dynamic]string
	append(&names, expect(parser, .Ident, "expected loop name").text)
	if at(parser, .Comma) {
		advance(parser)
		append(&names, expect(parser, .Ident, "expected second loop name").text)
	}
	expect(parser, .In, "expected 'in' in for loop")
	iterable := parse_expression(parser)
	skip_separators(parser)
	body := parse_block_until(parser, []Token_Kind{.End})
	expect(parser, .End, "expected 'end' to close for")
	return expr_node(parser, For {
		names    = to_slice(parser, names),
		iterable = iterable,
		body     = body,
	})
}

@(private)
parse_begin :: proc(parser: ^Parser) -> ^Expr {
	advance(parser)
	body := parse_block_until(parser, []Token_Kind{.End})
	expect(parser, .End, "expected 'end' to close begin")
	return expr_node(parser, Begin{body = body})
}

@(private)
parse_return :: proc(parser: ^Parser) -> ^Expr {
	advance(parser)
	result := Return{}
	if !at_separator(parser) && !at(parser, .Eof) && !at_any(parser, []Token_Kind{.End, .Elseif, .Else}) {
		result.value = parse_expression(parser)
		result.has_value = true
	}
	return expr_node(parser, result)
}

@(private)
parse_raise :: proc(parser: ^Parser) -> ^Expr {
	advance(parser)
	parts: [dynamic]^Expr
	for {
		append(&parts, parse_expression(parser))
		if at(parser, .Comma) {
			advance(parser)
			continue
		}
		break
	}
	return expr_node(parser, Raise{parts = to_slice(parser, parts)})
}

@(private)
parse_fn :: proc(parser: ^Parser) -> ^Expr {
	advance(parser)
	expect(parser, .LParen, "expected '(' after 'fn'")
	params := parse_params(parser)
	expect(parser, .RParen, "expected ')' after parameters")
	result := Fn{params = params}
	if at(parser, .Fat_Arrow) {
		advance(parser)
		result.expression_body = parse_expression(parser)
		result.has_expression_body = true
		return expr_node(parser, result)
	}
	skip_separators(parser)
	result.body = parse_block_until(parser, []Token_Kind{.End})
	expect(parser, .End, "expected 'end' to close fn")
	return expr_node(parser, result)
}

// --- Expressions -----------------------------------------------------------

@(private)
parse_assignment :: proc(parser: ^Parser) -> ^Expr {
	left := parse_or(parser)
	if at(parser, .Eq) {
		advance(parser)
		value := parse_assignment(parser)
		return expr_node(parser, Assignment{target = left, value = value})
	}
	return left
}

@(private)
parse_or :: proc(parser: ^Parser) -> ^Expr {
	left := parse_and(parser)
	for at(parser, .Pipe_Pipe) {
		advance(parser)
		right := parse_and(parser)
		left = expr_node(parser, Binary{op = .Or, left = left, right = right})
	}
	return left
}

@(private)
parse_and :: proc(parser: ^Parser) -> ^Expr {
	left := parse_equality(parser)
	for at(parser, .Amp_Amp) {
		advance(parser)
		right := parse_equality(parser)
		left = expr_node(parser, Binary{op = .And, left = left, right = right})
	}
	return left
}

@(private)
parse_equality :: proc(parser: ^Parser) -> ^Expr {
	left := parse_comparison(parser)
	for {
		op: Binary_Op
		#partial switch peek(parser).kind {
		case .Eq_Eq:
			op = .Eq
		case .Bang_Eq:
			op = .Ne
		case:
			return left
		}
		advance(parser)
		right := parse_comparison(parser)
		left = expr_node(parser, Binary{op = op, left = left, right = right})
	}
}

@(private)
parse_comparison :: proc(parser: ^Parser) -> ^Expr {
	left := parse_range(parser)
	for {
		op: Binary_Op
		#partial switch peek(parser).kind {
		case .Lt:
			op = .Lt
		case .Lt_Eq:
			op = .Le
		case .Gt:
			op = .Gt
		case .Gt_Eq:
			op = .Ge
		case:
			return left
		}
		advance(parser)
		right := parse_range(parser)
		left = expr_node(parser, Binary{op = op, left = left, right = right})
	}
}

@(private)
parse_range :: proc(parser: ^Parser) -> ^Expr {
	left := parse_additive(parser)
	if at(parser, .DotDot) {
		advance(parser)
		if at(parser, .Underscore) {
			advance(parser)
			return expr_node(parser, Range_Literal{start = left, has_end = false})
		}
		right := parse_additive(parser)
		return expr_node(parser, Range_Literal{start = left, end = right, has_end = true})
	}
	return left
}

@(private)
parse_additive :: proc(parser: ^Parser) -> ^Expr {
	left := parse_multiplicative(parser)
	for {
		op: Binary_Op
		#partial switch peek(parser).kind {
		case .Plus:
			op = .Add
		case .Minus:
			op = .Sub
		case:
			return left
		}
		advance(parser)
		right := parse_multiplicative(parser)
		left = expr_node(parser, Binary{op = op, left = left, right = right})
	}
}

@(private)
parse_multiplicative :: proc(parser: ^Parser) -> ^Expr {
	left := parse_unary(parser)
	for {
		op: Binary_Op
		#partial switch peek(parser).kind {
		case .Star:
			op = .Mul
		case .Slash:
			op = .Div
		case .Percent:
			op = .Rem
		case:
			return left
		}
		advance(parser)
		right := parse_unary(parser)
		left = expr_node(parser, Binary{op = op, left = left, right = right})
	}
}

@(private)
parse_unary :: proc(parser: ^Parser) -> ^Expr {
	#partial switch peek(parser).kind {
	case .Minus:
		advance(parser)
		return expr_node(parser, Unary{op = .Neg, operand = parse_unary(parser)})
	case .Bang, .Not:
		advance(parser)
		return expr_node(parser, Unary{op = .Not, operand = parse_unary(parser)})
	case:
		return parse_postfix(parser)
	}
}

@(private)
parse_postfix :: proc(parser: ^Parser) -> ^Expr {
	node := parse_primary(parser)
	for {
		#partial switch peek(parser).kind {
		case .LParen:
			args := parse_call_arguments(parser)
			node = expr_node(parser, Call{callee = node, args = args})
		case .LBracket:
			advance(parser)
			key := parse_expression(parser)
			expect(parser, .RBracket, "expected ']' after index")
			node = expr_node(parser, Index{collection = node, key = key})
		case .Dot:
			advance(parser)
			name := expect(parser, .Ident, "expected field name after '.'")
			node = expr_node(parser, Field{receiver = node, name = name.text})
		case:
			return node
		}
	}
}

@(private)
parse_qualified_name :: proc(parser: ^Parser, first: Token) -> string {
	if !at(parser, .Slash) {
		return first.text
	}
	parts: [dynamic]string
	append(&parts, first.text)
	last := first
	for at(parser, .Slash) {
		slash := peek(parser)
		next := peek_at(parser, 1)
		if next.kind != .Ident || !tokens_adjacent(last, slash) || !tokens_adjacent(slash, next) {
			break
		}
		advance(parser)
		last = advance(parser)
		append(&parts, last.text)
	}

	builder: strings.Builder
	strings.builder_init(&builder, parser.allocator)
	for part, index in parts {
		if index > 0 {
			strings.write_byte(&builder, '/')
		}
		strings.write_string(&builder, part)
	}
	delete(parts)
	return strings.to_string(builder)
}

@(private)
parse_call_arguments :: proc(parser: ^Parser) -> []Call_Argument {
	expect(parser, .LParen, "expected '('")
	args: [dynamic]Call_Argument
	skip_newlines(parser)
	for !at(parser, .RParen) && !at(parser, .Eof) {
		argument := Call_Argument{}
		if at(parser, .Ident) && peek_at(parser, 1).kind == .Colon {
			argument.role = advance(parser).text
			argument.has_role = true
			advance(parser)
		}
		argument.expr = parse_expression(parser)
		append(&args, argument)
		skip_newlines(parser)
		if at(parser, .Comma) {
			advance(parser)
			skip_newlines(parser)
			continue
		}
		break
	}
	expect(parser, .RParen, "expected ')' after arguments")
	return to_slice(parser, args)
}

@(private)
parse_list_literal :: proc(parser: ^Parser) -> ^Expr {
	elements: [dynamic]^Expr
	skip_newlines(parser)
	for !at(parser, .RBracket) && !at(parser, .Eof) {
		if at(parser, .At) {
			advance(parser)
			append(&elements, expr_node(parser, Splice{value = parse_unary(parser)}))
		} else {
			append(&elements, parse_expression(parser))
		}
		skip_newlines(parser)
		if at(parser, .Comma) {
			advance(parser)
			skip_newlines(parser)
			continue
		}
		break
	}
	expect(parser, .RBracket, "expected ']' after list elements")
	return expr_node(parser, List_Literal{elements = to_slice(parser, elements)})
}

@(private)
parse_map_literal :: proc(parser: ^Parser) -> ^Expr {
	entries: [dynamic]Map_Entry_AST
	skip_newlines(parser)
	for !at(parser, .RBrace) && !at(parser, .Eof) {
		key := parse_expression(parser)
		expect(parser, .Arrow, "expected '->' in map entry")
		value := parse_expression(parser)
		append(&entries, Map_Entry_AST{key = key, value = value})
		skip_newlines(parser)
		if at(parser, .Comma) {
			advance(parser)
			skip_newlines(parser)
			continue
		}
		break
	}
	expect(parser, .RBrace, "expected '}' after map entries")
	return expr_node(parser, Map_Literal{entries = to_slice(parser, entries)})
}

@(private)
parse_primary :: proc(parser: ^Parser) -> ^Expr {
	token := advance(parser)
	#partial switch token.kind {
	case .Int:
		return expr_node(parser, Int_Literal{text = token.text})
	case .Float:
		return expr_node(parser, Float_Literal{text = token.text})
	case .String:
		return expr_node(parser, String_Literal{text = token.text})
	case .Bytes:
		return expr_node(parser, Bytes_Literal{text = token.text})
	case .True:
		return expr_node(parser, Bool_Literal{value = true})
	case .False:
		return expr_node(parser, Bool_Literal{value = false})
	case .Error_Code:
		return expr_node(parser, Error_Code_Literal{name = token.text})
	case .Underscore:
		return expr_node(parser, Wildcard{})
	case .Question:
		name := expect(parser, .Ident, "expected name after '?'")
		return expr_node(parser, Query_Variable{name = name.text})
	case .Hash:
		next := advance(parser)
		#partial switch next.kind {
		case .Int:
			return expr_node(parser, Identity_Literal{name = next.text})
		case .Ident:
			return expr_node(parser, Identity_Literal{name = parse_qualified_name(parser, next)})
		case:
			error_here(parser, "expected identity name after '#'")
			return expr_node(parser, Wildcard{})
		}
	case .Colon:
		next := advance(parser)
		#partial switch next.kind {
		case .Ident:
			return expr_node(parser, Symbol_Literal{name = parse_qualified_name(parser, next)})
		case .String:
			return expr_node(parser, Symbol_Literal{name = next.text})
		case:
			error_here(parser, "expected symbol name after ':'")
			return expr_node(parser, Wildcard{})
		}
	case .At:
		return expr_node(parser, Splice{value = parse_unary(parser)})
	case .Ident:
		name := parse_qualified_name(parser, token)
		return expr_node(parser, Name{parts = to_slice(parser, make_name_parts(parser, name))})
	case .LParen:
		inner := parse_expression(parser)
		expect(parser, .RParen, "expected ')' after expression")
		return inner
	case .LBracket:
		return parse_list_literal(parser)
	case .LBrace:
		return parse_map_literal(parser)
	case:
		error_here(parser, "expected an expression")
		return expr_node(parser, Wildcard{})
	}
}

@(private)
make_name_parts :: proc(parser: ^Parser, name: string) -> [dynamic]string {
	parts: [dynamic]string
	start := 0
	for index in 0 ..= len(name) {
		if index == len(name) || name[index] == '/' {
			append(&parts, name[start:index])
			start = index + 1
		}
	}
	return parts
}
