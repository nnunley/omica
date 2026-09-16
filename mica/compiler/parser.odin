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
	source:    string,
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
		source    = source,
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
		if is_contextual_keyword(parser, "grant") &&
		   (peek_at(parser, 1).kind == .Hash ||
			   (peek_at(parser, 1).kind == .Ident && peek_at(parser, 1).text == "role")) {
			return parse_grant(parser)
		}

		start := peek(parser).offset
		head := parse_expression(parser)
		if at(parser, .Colon_Dash) {
			advance(parser)
			body := parse_rule_body(parser)
			end := len(parser.source)
			if parser.pos < len(parser.tokens) {
				end = parser.tokens[parser.pos].offset
			}
			rule_source := ""
			if start >= 0 && end <= len(parser.source) && start < end {
				rule_source = strings.trim_space(parser.source[start:end])
			}
			return Rule_Item{head = head, body = body, source = rule_source}
		}
		return Expr_Item{expr = head}
	}
}

// --- Grant blocks ----------------------------------------------------------

@(private)
at_grant_section :: proc(parser: ^Parser) -> bool {
	if !at(parser, .Ident) {
		return false
	}
	switch peek(parser).text {
	case "read", "write", "invoke":
		return peek_at(parser, 1).kind == .Colon
	case "effect":
		return true
	}
	return false
}

@(private)
parse_grant :: proc(parser: ^Parser) -> Item {
	advance(parser) // grant
	is_role := false
	if is_contextual_keyword(parser, "role") {
		advance(parser)
		is_role = true
	}
	principal := parse_unary(parser)
	skip_separators(parser)

	sections: [dynamic]Grant_Section
	for !at(parser, .Eof) && !at(parser, .End) {
		if !at_grant_section(parser) {
			error_here(parser, "expected a grant section")
			for !at(parser, .Eof) && !at_separator(parser) && !at(parser, .End) {
				advance(parser)
			}
			skip_separators(parser)
			continue
		}

		kind: Grant_Section_Kind
		switch peek(parser).text {
		case "read":
			kind = .Read
		case "write":
			kind = .Write
		case "invoke":
			kind = .Invoke
		case:
			kind = .Effect
		}
		advance(parser)
		if kind != .Effect {
			expect(parser, .Colon, "expected ':' after the section name")
		}

		entries: [dynamic]^Expr
		skip_separators(parser)
		for !at(parser, .Eof) && !at(parser, .End) && !at_grant_section(parser) {
			append(&entries, parse_expression(parser))
			if !at_separator(parser) && !at(parser, .End) && !at_grant_section(parser) {
				error_here(parser, "expected newline after a grant entry")
				for !at(parser, .Eof) && !at_separator(parser) {
					advance(parser)
				}
			}
			skip_separators(parser)
		}
		append(&sections, Grant_Section {
			kind    = kind,
			entries = to_slice(parser, entries),
		})
	}

	expect(parser, .End, "expected 'end' to close grant")
	return Grant_Item {
		principal = principal,
		is_role   = is_role,
		sections  = to_slice(parser, sections),
	}
}

@(private)
parse_verb :: proc(parser: ^Parser) -> Item {
	start := peek(parser).offset
	advance(parser)
	name_token := expect(parser, .Ident, "expected verb name")
	verb_name := parse_qualified_name(parser, name_token)
	expect(parser, .LParen, "expected '(' after verb name")
	params := parse_params(parser)
	expect(parser, .RParen, "expected ')' after verb parameters")
	result_type := ""
	if at(parser, .Arrow) {
		advance(parser)
		result_type = parse_type_text(parser)
	}
	skip_separators(parser)
	body := parse_block_until(parser, []Token_Kind{.End})
	expect(parser, .End, "expected 'end' to close verb")
	end := len(parser.source)
	if parser.pos < len(parser.tokens) {
		end = parser.tokens[parser.pos].offset
	}
	verb_source := ""
	if start >= 0 && end <= len(parser.source) && start < end {
		verb_source = strings.trim_space(parser.source[start:end])
	}
	return Verb_Item {
		name        = verb_name,
		params      = params,
		result_type = result_type,
		body        = body,
		source      = verb_source,
	}
}

@(private)
parse_params :: proc(parser: ^Parser) -> []Param {
	params: [dynamic]Param
	skip_newlines(parser)
	for !at(parser, .RParen) && !at(parser, .Eof) {
		param := Param{}
		if at(parser, .Question) {
			advance(parser)
			param.mode = .Optional
		} else if at(parser, .At) {
			advance(parser)
			param.mode = .Rest
		}
		name_token := expect(parser, .Ident, "expected parameter name")
		param.name = name_token.text
		if param.mode == .Optional && at(parser, .Eq) {
			advance(parser)
			param.default = parse_expression(parser)
			param.has_default = true
		}
		if at(parser, .At) && param.mode != .Rest {
			advance(parser)
			param.restriction = parse_unary(parser)
			param.has_restriction = true
		}
		if at(parser, .Colon) {
			advance(parser)
			param.kind = parse_type_text(parser)
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
	if is_contextual_keyword(parser, "match") {
		next := peek_at(parser, 1)
		#partial switch next.kind {
		case .LParen, .Eq, .Dot, .LBracket, .Colon, .Slash, .Colon_Dash:
		// `match(...)` or a variable named `match`; fall through.
		case:
			return parse_match(parser)
		}
	}

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
	is_exactly := false
	if is_contextual_keyword(parser, "exactly") {
		next := peek_at(parser, 1)
		if next.kind == .LBrace || next.kind == .LBracket {
			advance(parser)
			is_exactly = true
		}
	}
	pattern := parse_pattern(parser)
	binding := Binding {
		is_const   = is_const,
		is_exactly = is_exactly,
		pattern    = pattern,
	}
	if at(parser, .Colon) {
		advance(parser)
		binding.kind = parse_type_text(parser)
		binding.has_kind = true
	}
	if at(parser, .Eq) {
		advance(parser)
		binding.value = parse_expression(parser)
		binding.has_value = true
	}
	return expr_node(parser, binding)
}

// --- Patterns --------------------------------------------------------------

@(private)
pattern_node :: proc(parser: ^Parser, value: $T) -> ^Pattern {
	node := new(Pattern, parser.allocator)
	node^ = value
	return node
}

@(private)
is_contextual_keyword :: proc(parser: ^Parser, text: string) -> bool {
	token := peek(parser)
	return token.kind == .Ident && token.text == text
}

@(private)
parse_pattern :: proc(parser: ^Parser) -> ^Pattern {
	token := peek(parser)
	#partial switch token.kind {
	case .Underscore:
		advance(parser)
		return pattern_node(parser, Wildcard_Pattern{})
	case .At:
		advance(parser)
		name := expect(parser, .Ident, "expected name after '@'")
		return pattern_node(parser, Rest_Pattern{name = name.text})
	case .Question:
		advance(parser)
		name := expect(parser, .Ident, "expected name after '?'")
		pattern := Optional_Pattern{name = name.text}
		if at(parser, .Eq) {
			advance(parser)
			pattern.default = parse_expression(parser)
			pattern.has_default = true
		}
		return pattern_node(parser, pattern)
	case .LBracket:
		return parse_list_pattern(parser)
	case .LBrace:
		return parse_map_pattern(parser)
	case .Ident:
		name := advance(parser).text
		if at(parser, .LParen) {
			return parse_call_pattern(parser, name)
		}
		return pattern_node(parser, Binding_Pattern{name = name})
	case .Int, .Float, .String, .Bytes, .True, .False, .Error_Code, .Hash, .Colon:
		value := parse_primary(parser)
		return pattern_node(parser, Literal_Pattern{value = value})
	case:
		error_here(parser, "expected a pattern")
		return pattern_node(parser, Wildcard_Pattern{})
	}
}

@(private)
parse_call_pattern :: proc(parser: ^Parser, name: string) -> ^Pattern {
	expect(parser, .LParen, "expected '('")
	args: [dynamic]^Pattern
	skip_newlines(parser)
	for !at(parser, .RParen) && !at(parser, .Eof) {
		append(&args, parse_pattern(parser))
		skip_newlines(parser)
		if at(parser, .Comma) {
			advance(parser)
			skip_newlines(parser)
			continue
		}
		break
	}
	expect(parser, .RParen, "expected ')' after pattern arguments")
	return pattern_node(parser, Call_Pattern{name = name, args = to_slice(parser, args)})
}

@(private)
parse_list_pattern :: proc(parser: ^Parser) -> ^Pattern {
	expect(parser, .LBracket, "expected '['")
	elements: [dynamic]^Pattern
	skip_newlines(parser)
	for !at(parser, .RBracket) && !at(parser, .Eof) {
		append(&elements, parse_pattern(parser))
		skip_newlines(parser)
		if at(parser, .Comma) {
			advance(parser)
			skip_newlines(parser)
			continue
		}
		break
	}
	expect(parser, .RBracket, "expected ']' after list pattern")
	return pattern_node(parser, List_Pattern{elements = to_slice(parser, elements)})
}

@(private)
parse_map_pattern :: proc(parser: ^Parser) -> ^Pattern {
	expect(parser, .LBrace, "expected '{'")
	entries: [dynamic]Map_Pattern_Entry
	skip_newlines(parser)
	for !at(parser, .RBrace) && !at(parser, .Eof) {
		entry := Map_Pattern_Entry{}
		#partial switch peek(parser).kind {
		case .Colon:
			advance(parser)
			key_token := advance(parser)
			entry.key = expr_node(parser, Symbol_Literal{name = key_token.text})
			if at(parser, .Arrow) {
				advance(parser)
				entry.pattern = parse_pattern(parser)
			} else {
				entry.shorthand = true
				entry.pattern = pattern_node(
					parser,
					Binding_Pattern{name = key_token.text},
				)
			}
		case .Ident:
			name := advance(parser).text
			entry.key = expr_node(parser, Symbol_Literal{name = name})
			if at(parser, .Arrow) {
				advance(parser)
				entry.pattern = parse_pattern(parser)
			} else {
				entry.shorthand = true
				entry.pattern = pattern_node(parser, Binding_Pattern{name = name})
			}
		case:
			error_here(parser, "expected a map pattern entry")
			for !at(parser, .Eof) && !at(parser, .Comma) && !at(parser, .RBrace) {
				advance(parser)
			}
		}
		append(&entries, entry)
		skip_newlines(parser)
		if at(parser, .Comma) {
			advance(parser)
			skip_newlines(parser)
			continue
		}
		break
	}
	expect(parser, .RBrace, "expected '}' after map pattern")
	return pattern_node(parser, Map_Pattern{entries = to_slice(parser, entries)})
}

// --- Match -----------------------------------------------------------------

@(private)
parse_match :: proc(parser: ^Parser) -> ^Expr {
	advance(parser)
	value := parse_expression(parser)
	skip_separators(parser)
	cases: [dynamic]Match_Case
	for is_contextual_keyword(parser, "case") {
		advance(parser)
		pattern := parse_pattern(parser)
		case_clause := Match_Case{pattern = pattern}
		if at(parser, .If) {
			advance(parser)
			case_clause.guard = parse_expression(parser)
			case_clause.has_guard = true
		}
		skip_separators(parser)
		case_clause.body = parse_case_body(parser)
		append(&cases, case_clause)
	}
	expect(parser, .End, "expected 'end' to close match")
	return expr_node(parser, Match{value = value, cases = to_slice(parser, cases)})
}

@(private)
parse_case_body :: proc(parser: ^Parser) -> []^Expr {
	body: [dynamic]^Expr
	skip_separators(parser)
	for !at(parser, .Eof) && !at(parser, .End) && !is_contextual_keyword(parser, "case") {
		append(&body, parse_expression(parser))
		if !at_separator(parser) &&
		   !at(parser, .End) &&
		   !is_contextual_keyword(parser, "case") {
			error_here(parser, "expected newline or 'case'")
			for !at(parser, .Eof) && !at_separator(parser) {
				advance(parser)
			}
		}
		skip_separators(parser)
	}
	return to_slice(parser, body)
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
	// Destructuring headers bind each item against a list, map, or
	// wildcard pattern. Anything else stays on the legacy name path so
	// `for x in ...`, `for k, v in ...`, and annotations parse unchanged.
	// The kinds compare directly: at_any would allocate its kind slice on
	// every loop header.
	head := peek(parser)
	if head.kind == .LBracket || head.kind == .LBrace || head.kind == .Underscore {
		pattern := parse_pattern(parser)
		#partial switch _ in pattern^ {
		case List_Pattern, Map_Pattern, Wildcard_Pattern:
		case:
			error_here(parser, "for loop pattern must be a list, map, or wildcard")
			pattern = pattern_node(parser, Wildcard_Pattern{})
		}
		expect(parser, .In, "expected 'in' in for loop")
		iterable := parse_expression(parser)
		skip_separators(parser)
		body := parse_block_until(parser, []Token_Kind{.End})
		expect(parser, .End, "expected 'end' to close for")
		return expr_node(parser, For {
			pattern  = pattern,
			iterable = iterable,
			body     = body,
		})
	}
	names: [dynamic]string
	kinds: [dynamic]string
	for {
		append(&names, expect(parser, .Ident, "expected loop name").text)
		kind := ""
		if at(parser, .Colon) {
			advance(parser)
			kind = parse_type_text(parser)
		}
		append(&kinds, kind)
		if at(parser, .Comma) {
			advance(parser)
			continue
		}
		break
	}
	expect(parser, .In, "expected 'in' in for loop")
	iterable := parse_expression(parser)
	skip_separators(parser)
	body := parse_block_until(parser, []Token_Kind{.End})
	expect(parser, .End, "expected 'end' to close for")
	return expr_node(parser, For {
		names    = to_slice(parser, names),
		kinds    = to_slice(parser, kinds),
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
	name := ""
	if at(parser, .Ident) && peek_at(parser, 1).kind == .LParen {
		name = advance(parser).text
	}
	expect(parser, .LParen, "expected '(' after 'fn'")
	params := parse_params(parser)
	expect(parser, .RParen, "expected ')' after parameters")
	result := Fn{params = params}
	if at(parser, .Fat_Arrow) {
		advance(parser)
		result.expression_body = parse_expression(parser)
		result.has_expression_body = true
	} else {
		skip_separators(parser)
		result.body = parse_block_until(parser, []Token_Kind{.End})
		expect(parser, .End, "expected 'end' to close fn")
	}
	if name == "" {
		return expr_node(parser, result)
	}
	// A named fn is a self-recursive binding.
	return expr_node(parser, Binding {
		pattern    = pattern_node(parser, Binding_Pattern{name = name}),
		value      = expr_node(parser, result),
		has_value  = true,
	})
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
			node = expr_node(parser, Field {
				receiver = node,
				name     = parse_qualified_name(parser, name),
			})
		case .Colon:
			next := peek_at(parser, 1)
			after := peek_at(parser, 2)
			if next.kind != .Ident || after.kind != .LParen {
				return node
			}
			advance(parser)
			selector := advance(parser).text
			args := parse_call_arguments(parser)
			node = expr_node(parser, Receiver_Call {
				receiver = node,
				selector = selector,
				args     = args,
			})
		case .Lt:
			// `#id<[...]>` and `#id<{...}>` are variants when the `<` is
			// adjacent to the head. `a < b` stays a comparison.
			last := parser.tokens[parser.pos - 1]
			if tokens_adjacent(last, peek(parser)) && is_structural_head(node) {
				node = parse_structural_literal(parser, node)
			} else {
				return node
			}
		case:
			return node
		}
	}
}

@(private)
is_structural_head :: proc(node: ^Expr) -> bool {
	if _, ok := node^.(Identity_Literal); ok {
		return true
	}
	if _, ok := node^.(Name); ok {
		return true
	}
	if _, ok := node^.(Symbol_Literal); ok {
		return true
	}
	return false
}

@(private)
parse_structural_literal :: proc(parser: ^Parser, head: ^Expr) -> ^Expr {
	advance(parser) // <
	cells: [dynamic]Structural_Cell
	named := false

	#partial switch peek(parser).kind {
	case .LBracket:
		advance(parser)
		skip_newlines(parser)
		for !at(parser, .RBracket) && !at(parser, .Eof) {
			append(&cells, Structural_Cell{value = parse_expression(parser)})
			skip_newlines(parser)
			if at(parser, .Comma) {
				advance(parser)
				skip_newlines(parser)
				continue
			}
			break
		}
		expect(parser, .RBracket, "expected ']' after structural cells")
	case .LBrace:
		named = true
		advance(parser)
		skip_newlines(parser)
		for !at(parser, .RBrace) && !at(parser, .Eof) {
			name := parse_expression(parser)
			expect(parser, .Arrow, "expected '->' in structural fields")
			value := parse_expression(parser)
			append(&cells, Structural_Cell{name = name, value = value})
			skip_newlines(parser)
			if at(parser, .Comma) {
				advance(parser)
				skip_newlines(parser)
				continue
			}
			break
		}
		expect(parser, .RBrace, "expected '}' after structural fields")
	case:
		// Bare cells, as in `#sync_action<_>`. Parse at unary precedence so
		// the closing '>' is not consumed as a comparison.
		for !at(parser, .Gt) && !at(parser, .Eof) {
			append(&cells, Structural_Cell{value = parse_unary(parser)})
			skip_newlines(parser)
			if at(parser, .Comma) {
				advance(parser)
				skip_newlines(parser)
				continue
			}
			break
		}
	}

	expect(parser, .Gt, "expected '>' after structural cells")
	return expr_node(parser, Structural_Literal {
		head  = head,
		cells = to_slice(parser, cells),
		named = named,
	})
}

// Parses a kind annotation, including generic arguments such as
// `option<option<string>>`, and returns its source text.
@(private)
parse_type_text :: proc(parser: ^Parser) -> string {
	start_token := peek(parser)
	if start_token.kind != .Ident {
		error_here(parser, "expected a kind")
		return ""
	}

	start := start_token.offset
	end := start
	depth := 0
	done := false
	for !done && !at(parser, .Eof) {
		#partial switch peek(parser).kind {
		case .Ident:
			if depth == 0 && end > start {
				done = true
				break
			}
			last := advance(parser)
			end = last.offset + len(last.text)
		case .Lt:
			depth += 1
			last := advance(parser)
			end = last.offset + len(last.text)
		case .Gt:
			if depth == 0 {
				done = true
				break
			}
			depth -= 1
			last := advance(parser)
			end = last.offset + len(last.text)
		case .Slash, .Dot:
			last := advance(parser)
			end = last.offset + len(last.text)
		case:
			done = true
		}
	}
	return strings.trim_space(parser.source[start:end])
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
		if at(parser, .At) {
			advance(parser)
			argument.expr = expr_node(parser, Splice{value = parse_unary(parser)})
		} else {
			argument.expr = parse_expression(parser)
		}
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
			first := len(elements) == 0
			append(&elements, parse_expression(parser))
			skip_newlines(parser)
			// `[body for pattern in iterable if condition sort key]`.
			// `for` cannot continue any expression, so it unambiguously
			// opens a comprehension after a single leading element. The
			// elements array is closed out here: to_slice would delete it
			// on the list path, so the early return must free it instead.
			if first && at(parser, .For) {
				body := elements[0]
				delete(elements)
				return parse_comprehension(parser, body)
			}
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
	elements_slice := to_slice(parser, elements)
	if at(parser, .LBrace) {
		advance(parser)
		rows: [dynamic]^Expr
		skip_newlines(parser)
		for !at(parser, .RBrace) && !at(parser, .Eof) {
			append(&rows, parse_expression(parser))
			skip_newlines(parser)
			if at(parser, .Comma) {
				advance(parser)
				skip_newlines(parser)
				continue
			}
			break
		}
		expect(parser, .RBrace, "expected '}' after relation literal rows")
		return expr_node(parser, Relation_Literal {
			heading = elements_slice,
			rows    = to_slice(parser, rows),
		})
	}
	return expr_node(parser, List_Literal{elements = elements_slice})
}

// Parses the tail of a comprehension once the leading body element and
// `for` are consumed: a binding pattern (or single name), the iterable,
// and optional `if` and `sort` clauses.
@(private)
parse_comprehension :: proc(parser: ^Parser, body: ^Expr) -> ^Expr {
	advance(parser)
	pattern: ^Pattern
	// A bare name binds directly; anything structural goes through patterns.
	// Call patterns make no sense over iteration items.
	if at(parser, .Ident) && peek_at(parser, 1).kind != .LParen {
		pattern = pattern_node(parser, Binding_Pattern{name = advance(parser).text})
	} else {
		pattern = parse_pattern(parser)
		#partial switch _ in pattern^ {
		case Binding_Pattern, List_Pattern, Map_Pattern, Wildcard_Pattern:
		case:
			error_here(parser, "comprehension pattern must be a name, list, map, or wildcard")
			pattern = pattern_node(parser, Wildcard_Pattern{})
		}
	}
	expect(parser, .In, "expected 'in' in comprehension")
	iterable := parse_expression(parser)
	condition: ^Expr
	if at(parser, .If) {
		advance(parser)
		condition = parse_expression(parser)
	}
	has_sort := false
	key: ^Expr
	if is_contextual_keyword(parser, "sort") {
		advance(parser)
		has_sort = true
		skip_newlines(parser)
		if !at(parser, .RBracket) {
			key = parse_expression(parser)
		}
	}
	skip_newlines(parser)
	expect(parser, .RBracket, "expected ']' to close comprehension")
	return expr_node(parser, Comprehension {
		body      = body,
		pattern   = pattern,
		iterable  = iterable,
		condition = condition,
		key       = key,
		has_sort  = has_sort,
	})
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
	if is_contextual_keyword(parser, "match") {
		next := peek_at(parser, 1)
		#partial switch next.kind {
		case .LParen, .Eq, .Dot, .LBracket, .Colon, .Slash, .Colon_Dash:
		case:
			return parse_match(parser)
		}
	}

	// Statement forms are expressions, so they are valid operands of `&&`,
	// `||`, and the binary operators.
	#partial switch peek(parser).kind {
	case .Return:
		return parse_return(parser)
	case .Break:
		advance(parser)
		return expr_node(parser, Break{})
	case .Continue:
		advance(parser)
		return expr_node(parser, Continue{})
	case .Raise:
		return parse_raise(parser)
	case .Assert:
		advance(parser)
		return expr_node(parser, Assert{atom = parse_expression(parser)})
	case .Retract:
		advance(parser)
		return expr_node(parser, Retract{atom = parse_expression(parser)})
	case .Require:
		advance(parser)
		return expr_node(parser, Require{condition = parse_expression(parser)})
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
	case .Try:
		return parse_try(parser)
	case .Spawn:
		return parse_spawn(parser)
	case .Fn:
		return parse_fn(parser)
	}

	// `dom <tag ...>` is markup when a tag name follows the `<`. `dom < 2`
	// remains an ordinary comparison.
	if is_contextual_keyword(parser, "dom") {
		next := peek_at(parser, 1)
		third := peek_at(parser, 2)
		if next.kind == .Lt && third.kind == .Ident {
			return parse_dom(parser)
		}
	}

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
		skip_newlines(parser)
		inner := parse_expression(parser)
		skip_newlines(parser)
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

// --- DOM markup ------------------------------------------------------------

// DOM tag and attribute names accept keyword spellings, such as the HTML
// attribute `method`.
@(private)
token_is_name :: proc(token: Token) -> bool {
	if token.kind == .Ident {
		return true
	}
	if len(token.text) == 0 {
		return false
	}
	if !is_ident_start(token.text[0]) {
		return false
	}
	for index in 1 ..< len(token.text) {
		if !is_ident_continue(token.text[index]) {
			return false
		}
	}
	return true
}

@(private)
parse_dom :: proc(parser: ^Parser) -> ^Expr {
	advance(parser) // dom
	expect(parser, .Lt, "expected '<' after 'dom'")
	return expr_node(parser, parse_dom_element(parser))
}

@(private)
parse_dom_element :: proc(parser: ^Parser) -> Dom_Element {
	element := Dom_Element{}
	if !token_is_name(peek(parser)) {
		error_here(parser, "expected a tag name")
		for !at(parser, .Gt) && !at(parser, .Eof) {
			advance(parser)
		}
		if at(parser, .Gt) {
			advance(parser)
		}
		return element
	}
	tag_token := advance(parser)
	element.tag = parse_dom_name_segments(parser, tag_token)
	element.attributes = parse_dom_attributes(parser)

	if at(parser, .Slash) && peek_at(parser, 1).kind == .Gt {
		advance(parser)
		advance(parser)
		element.self_closing = true
		return element
	}

	expect(parser, .Gt, "expected '>' after attributes")
	element.children = parse_dom_children(parser, element.tag)
	return element
}

// Joins adjacent name segments such as `data-sync-key` and `aria:selected`.
@(private)
parse_dom_name_segments :: proc(parser: ^Parser, first: Token) -> string {
	parts: [dynamic]string
	append(&parts, first.text)
	last := first
	for at(parser, .Minus) || at(parser, .Colon) {
		separator := peek(parser)
		next := peek_at(parser, 1)
		if !token_is_name(next) ||
		   !tokens_adjacent(last, separator) ||
		   !tokens_adjacent(separator, next) {
			break
		}
		advance(parser)
		last = advance(parser)
		append(&parts, separator.text)
		append(&parts, last.text)
	}

	builder: strings.Builder
	strings.builder_init(&builder, parser.allocator)
	for part in parts {
		strings.write_string(&builder, part)
	}
	delete(parts)
	return strings.to_string(builder)
}

@(private)
parse_dom_attributes :: proc(parser: ^Parser) -> []Dom_Attribute {
	attributes: [dynamic]Dom_Attribute
	skip_newlines(parser)
	for !at(parser, .Gt) && !at(parser, .Eof) {
		if at(parser, .Slash) && peek_at(parser, 1).kind == .Gt {
			break
		}
		if !token_is_name(peek(parser)) {
			error_here(parser, "expected an attribute name")
			advance(parser)
			skip_newlines(parser)
			continue
		}
		first := advance(parser)
		attribute := Dom_Attribute{name = parse_dom_name_segments(parser, first)}
		if at(parser, .Eq) {
			advance(parser)
			attribute.has_value = true
			#partial switch peek(parser).kind {
			case .LBrace:
				advance(parser)
				attribute.value = parse_expression(parser)
				expect(parser, .RBrace, "expected '}' after attribute value")
			case .String:
				token := advance(parser)
				attribute.value = expr_node(parser, String_Literal{text = token.text})
			case:
				error_here(parser, "expected an attribute value")
			}
		}
		append(&attributes, attribute)
		skip_newlines(parser)
	}
	return to_slice(parser, attributes)
}

@(private)
parse_dom_children :: proc(parser: ^Parser, tag: string) -> []^Expr {
	children: [dynamic]^Expr
	text_start := peek(parser).offset

	for !at(parser, .Eof) {
		if at(parser, .Lt) {
			text := dom_text_between(parser, text_start, peek(parser).offset)
			if text != "" {
				append(&children, expr_node(parser, Dom_Text{text = text}))
			}

			if peek_at(parser, 1).kind == .Slash {
				advance(parser)
				advance(parser)
				if !token_is_name(peek(parser)) {
					error_here(parser, "expected a closing tag name")
				} else {
					closing := advance(parser)
					if closing.text != tag {
						error_here(parser, "closing tag does not match the opening tag")
					}
				}
				expect(parser, .Gt, "expected '>' after the closing tag")
				return to_slice(parser, children)
			}

			advance(parser)
			append(&children, expr_node(parser, parse_dom_element(parser)))
			text_start = peek(parser).offset
			continue
		}

		if at(parser, .LBrace) {
			text := dom_text_between(parser, text_start, peek(parser).offset)
			if text != "" {
				append(&children, expr_node(parser, Dom_Text{text = text}))
			}
			advance(parser)
			if at(parser, .At) {
				advance(parser)
				value := parse_expression(parser)
				append(&children, expr_node(parser, Splice{value = value}))
			} else {
				append(&children, parse_expression(parser))
			}
			expect(parser, .RBrace, "expected '}' after a DOM child expression")
			text_start = peek(parser).offset
			continue
		}

		advance(parser)
	}

	error_here(parser, "unterminated DOM element")
	return to_slice(parser, children)
}

@(private)
dom_text_between :: proc(parser: ^Parser, start: int, end: int) -> string {
	if start >= end || len(parser.source) == 0 {
		return ""
	}
	return strings.trim_space(parser.source[start:end])
}

// --- Try and spawn ---------------------------------------------------------

@(private)
parse_try :: proc(parser: ^Parser) -> ^Expr {
	advance(parser)
	result := Try{}
	skip_separators(parser)
	result.body = parse_block_until(parser, []Token_Kind{.Catch, .Finally, .End})

	catches: [dynamic]Catch_Clause
	for at(parser, .Catch) {
		advance(parser)
		clause := Catch_Clause{}
		if at(parser, .Error_Code) {
			clause.code = advance(parser).text
			clause.has_code = true
		}
		if at(parser, .As) {
			advance(parser)
			name := expect(parser, .Ident, "expected a name after 'as'")
			clause.name = name.text
			clause.has_name = true
		} else if at(parser, .Ident) {
			name := advance(parser)
			clause.name = name.text
			clause.has_name = true
		}
		skip_separators(parser)
		clause.body = parse_block_until(parser, []Token_Kind{.Catch, .Finally, .End})
		append(&catches, clause)
	}
	result.catches = to_slice(parser, catches)

	if at(parser, .Finally) {
		advance(parser)
		skip_separators(parser)
		result.finally_body = parse_block_until(parser, []Token_Kind{.End})
		result.has_finally = true
	}

	expect(parser, .End, "expected 'end' to close try")
	return expr_node(parser, result)
}

@(private)
parse_spawn :: proc(parser: ^Parser) -> ^Expr {
	advance(parser)
	result := Spawn{}
	result.call = parse_unary(parser)
	if at(parser, .After) {
		advance(parser)
		result.delay = parse_unary(parser)
		result.has_delay = true
	}
	return expr_node(parser, result)
}
