package compiler

import "core:testing"

@(private)
lex_kinds :: proc(source: string, allocator := context.temp_allocator) -> []Token_Kind {
	result := lex(source, allocator)
	kinds := make([]Token_Kind, len(result.tokens), allocator)
	for token, index in result.tokens {
		kinds[index] = token.kind
	}
	return kinds
}

@(private)
expect_kinds :: proc(t: ^testing.T, source: string, expected: []Token_Kind) {
	kinds := lex_kinds(source)
	testing.expect_value(t, len(kinds), len(expected))
	for kind, index in expected {
		if index >= len(kinds) {
			return
		}
		testing.expectf(
			t,
			kinds[index] == kind,
			"%q token %d: expected %v, got %v",
			source,
			index,
			kind,
			kinds[index],
		)
	}
}

@(test)
test_lex_keywords_and_idents :: proc(t: ^testing.T) {
	expect_kinds(t, "let x = 1", []Token_Kind{.Let, .Ident, .Eq, .Int, .Eof})
	expect_kinds(t, "verb trim", []Token_Kind{.Verb, .Ident, .Eof})
	expect_kinds(t, "return true", []Token_Kind{.Return, .True, .Eof})
	expect_kinds(t, "not false", []Token_Kind{.Not, .False, .Eof})
}

@(test)
test_lex_error_codes :: proc(t: ^testing.T) {
	result := lex("E_PERMISSION e_lower", context.temp_allocator)
	testing.expect_value(t, result.tokens[0].kind, Token_Kind.Error_Code)
	testing.expect_value(t, result.tokens[1].kind, Token_Kind.Ident)
}

@(test)
test_lex_symbols_identities_queries :: proc(t: ^testing.T) {
	expect_kinds(
		t,
		":name #lamp ?item @rest _ _x",
		[]Token_Kind {
			.Colon,
			.Ident,
			.Hash,
			.Ident,
			.Question,
			.Ident,
			.At,
			.Ident,
			.Underscore,
			.Ident,
			.Eof,
		},
	)

	// Qualified names stay separate; only the parser can tell them from
	// division.
	expect_kinds(
		t,
		"#workflow/reviewer",
		[]Token_Kind{.Hash, .Ident, .Slash, .Ident, .Eof},
	)

	// Quoted symbols.
	expect_kinds(t, ":\"display name\"", []Token_Kind{.Colon, .String, .Eof})
}

@(test)
test_lex_numbers :: proc(t: ^testing.T) {
	expect_kinds(t, "1 1.5 1e3 1..2", []Token_Kind {
		.Int,
		.Float,
		.Float,
		.Int,
		.DotDot,
		.Int,
		.Eof,
	})
	expect_kinds(t, "2.5e-3", []Token_Kind{.Float, .Eof})
}

@(test)
test_lex_operators :: proc(t: ^testing.T) {
	expect_kinds(t, "== != <= >= && || !", []Token_Kind {
		.Eq_Eq,
		.Bang_Eq,
		.Lt_Eq,
		.Gt_Eq,
		.Amp_Amp,
		.Pipe_Pipe,
		.Bang,
		.Eof,
	})
	expect_kinds(t, "-> => :- ..", []Token_Kind {
		.Arrow,
		.Fat_Arrow,
		.Colon_Dash,
		.DotDot,
		.Eof,
	})
	expect_kinds(t, "+ - * / %", []Token_Kind {
		.Plus,
		.Minus,
		.Star,
		.Slash,
		.Percent,
		.Eof,
	})
}

@(test)
test_lex_comments_and_newlines :: proc(t: ^testing.T) {
	source := "let x = 1 // comment\n\n\nlet y = 2"
	result := lex(source, context.temp_allocator)

	newlines := 0
	for token in result.tokens {
		if token.kind == .Newline {
			newlines += 1
		}
	}
	testing.expect_value(t, newlines, 1)
	testing.expect_value(t, len(result.errors), 0)

	// Line numbers advance across the collapsed newline.
	last := result.tokens[len(result.tokens) - 2]
	testing.expect_value(t, last.line, 4)
}

@(test)
test_lex_strings_and_bytes :: proc(t: ^testing.T) {
	result := lex("\"a\\\"b\" b\"aGk=\"", context.temp_allocator)
	testing.expect_value(t, len(result.errors), 0)
	testing.expect_value(t, result.tokens[0].kind, Token_Kind.String)
	testing.expect_value(t, result.tokens[0].text, "\"a\\\"b\"")
	testing.expect_value(t, result.tokens[1].kind, Token_Kind.Bytes)
	testing.expect_value(t, result.tokens[1].text, "b\"aGk=\"")
}

@(test)
test_lex_unterminated_string_records_error :: proc(t: ^testing.T) {
	result := lex("\"abc", context.temp_allocator)
	testing.expect_value(t, len(result.errors), 1)
	testing.expect_value(t, result.tokens[0].kind, Token_Kind.Error)
	testing.expect_value(t, result.tokens[len(result.tokens) - 1].kind, Token_Kind.Eof)
}

// `\r\n`, `\n`, and a lone `\r` each count as exactly one line break. A lone
// `\r` previously emitted a `Newline` token without advancing the line, which
// put later tokens on the wrong line.
@(test)
test_lex_line_break_forms :: proc(t: ^testing.T) {
	// Tokens are (kind, line). `a` is line 1; a collapsed break token is
	// reported on the line where it started; the next token is on the line
	// after the break(s).
	expect_lines :: proc(t: ^testing.T, source: string, expected: []int) {
		result := lex(source, context.temp_allocator)
		testing.expectf(
			t,
			len(result.tokens) == len(expected),
			"%q: expected %d tokens, got %d",
			source,
			len(expected),
			len(result.tokens),
		)
		for line, index in expected {
			if index >= len(result.tokens) {
				return
			}
			testing.expectf(
				t,
				result.tokens[index].line == line,
				"%q token %d: expected line %d, got %d",
				source,
				index,
				line,
				result.tokens[index].line,
			)
		}
	}

	// a / NL / b / NL / eof
	expect_lines(t, "a\nb\n", []int{1, 1, 2, 2, 3})
	expect_lines(t, "a\r\nb\r\n", []int{1, 1, 2, 2, 3})
	// a / NL / b / eof: one break from `\r`.
	expect_lines(t, "a\rb", []int{1, 1, 2, 2})
	// a / NL(2 breaks) / b / eof.
	expect_lines(t, "a\r\n\r\nb", []int{1, 1, 3, 3})
	// a / NL(4 breaks) / b / eof.
	expect_lines(t, "a\n\n\r\n\rb", []int{1, 1, 5, 5})
}

// Line breaks inside a string or bytes literal advance the line the same way,
// and `\r\n` counts once rather than once per byte.
@(test)
test_lex_line_breaks_in_literals :: proc(t: ^testing.T) {
	for source in ([]string {
		"\"a\rb\"\nx",
		"\"a\r\nb\"\nx",
		"b\"a\rb\"\nx",
	}) {
		result := lex(source, context.temp_allocator)
		// The trailing identifier `x` sits on line 3: one break inside the
		// literal, one after it.
		last_ident := result.tokens[len(result.tokens) - 2]
		testing.expect_value(t, last_ident.kind, Token_Kind.Ident)
		testing.expectf(
			t,
			last_ident.line == 3,
			"%q: expected the identifier on line 3, got %d",
			source,
			last_ident.line,
		)
	}
}
