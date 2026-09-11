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
