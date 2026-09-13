// Lexer for the Mica surface language.
//
// The lexer produces significant tokens only: whitespace and comments are
// skipped, and runs of newlines collapse to one `Newline` token. Punctuation
// that forms a qualified name, identity, symbol, query variable, or splice is
// emitted as separate tokens (`#`, `?`, `@`, `:`, `/`); the parser assembles
// them. This mirrors the language's token surface, where `/` is also the
// division operator and only the parser can decide.
package compiler

// Token kinds.
Token_Kind :: enum {
	Eof,
	Newline,

	Ident,
	Int,
	Float,
	String,
	Bytes,
	Error_Code,

	// Keywords.
	Let,
	Const,
	If,
	Elseif,
	Else,
	End,
	Begin,
	For,
	In,
	While,
	Return,
	Raise,
	Recover,
	Spawn,
	After,
	Not,
	Break,
	Continue,
	Try,
	Catch,
	As,
	Finally,
	Fn,
	Method,
	Verb,
	Do,
	Assert,
	Retract,
	Require,
	True,
	False,

	// Punctuation.
	LParen,
	RParen,
	LBracket,
	RBracket,
	LBrace,
	RBrace,
	Comma,
	Semi,
	Hash,
	At,
	Question,
	Underscore,
	Dot,
	DotDot,
	Colon,
	Colon_Dash,
	Eq,
	Eq_Eq,
	Bang_Eq,
	Lt,
	Lt_Eq,
	Gt,
	Gt_Eq,
	Amp_Amp,
	Pipe_Pipe,
	Pipe,
	Membership,
	Arrow,
	Fat_Arrow,
	Plus,
	Minus,
	Star,
	Slash,
	Percent,
	Bang,
	Error,
}

Token :: struct {
	kind:   Token_Kind,
	text:   string,
	offset: int,
	line:   int,
	column: int,
}

Lex_Error :: struct {
	message: string,
	line:    int,
	column:  int,
}

Lex_Result :: struct {
	tokens: []Token,
	errors: []Lex_Error,
}

// Lexes source text into tokens. The returned slices are allocated from
// `allocator`.
lex :: proc(source: string, allocator := context.allocator) -> Lex_Result {
	tokens := make([dynamic]Token, 0, allocator)
	errors := make([dynamic]Lex_Error, 0, allocator)

	pos := 0
	line := 1
	column := 1

	append_token :: proc(
		tokens: ^[dynamic]Token,
		kind: Token_Kind,
		text: string,
		offset, line, column: int,
	) {
		append(tokens, Token {
			kind   = kind,
			text   = text,
			offset = offset,
			line   = line,
			column = column,
		})
	}

	advance :: proc(
		source: string,
		pos: ^int,
		line: ^int,
		column: ^int,
		count: int,
	) {
		for _ in 0 ..< count {
			if pos^ >= len(source) {
				return
			}
			ch := source[pos^]
			if ch == '\n' {
				// A `\n` that follows a `\r` is the second half of one `\r\n`
				// break; the line already advanced at the `\r`.
				if pos^ == 0 || source[pos^ - 1] != '\r' {
					line^ += 1
				}
				column^ = 1
			} else if ch == '\r' {
				line^ += 1
				column^ = 1
			} else if ch & 0xc0 != 0x80 {
				// Count columns in Unicode scalar values, not bytes, so a
				// multi-byte character advances the column by one. UTF-8
				// continuation bytes are 10xxxxxx.
				column^ += 1
			}
			pos^ += 1
		}
	}

	for pos < len(source) {
		start := pos
		start_line := line
		start_column := column
		ch := source[pos]

		switch {
		case ch == ' ' || ch == '\t':
			advance(source, &pos, &line, &column, 1)
			continue

		case ch == '\r' || ch == '\n':
			for pos < len(source) && (source[pos] == '\r' || source[pos] == '\n') {
				if source[pos] == '\r' && pos + 1 < len(source) && source[pos + 1] == '\n' {
					advance(source, &pos, &line, &column, 2)
				} else {
					advance(source, &pos, &line, &column, 1)
				}
			}
			append_token(&tokens, .Newline, source[start:pos], start, start_line, start_column)
			continue

		case ch == '/' && pos + 1 < len(source) && source[pos + 1] == '/':
			for pos < len(source) && source[pos] != '\r' && source[pos] != '\n' {
				advance(source, &pos, &line, &column, 1)
			}
			continue

		case ch == '"':
			advance(source, &pos, &line, &column, 1)
			terminated := false
			for pos < len(source) {
				if source[pos] == '\\' {
					advance(source, &pos, &line, &column, 2)
					continue
				}
				if source[pos] == '"' {
					advance(source, &pos, &line, &column, 1)
					terminated = true
					break
				}
				advance(source, &pos, &line, &column, 1)
			}
			if !terminated {
				append(&errors, Lex_Error {
					message = "unterminated string",
					line    = start_line,
					column  = start_column,
				})
				append_token(&tokens, .Error, source[start:pos], start, start_line, start_column)
				continue
			}
			append_token(&tokens, .String, source[start:pos], start, start_line, start_column)
			continue

		case ch == 'b' && pos + 1 < len(source) && source[pos + 1] == '"':
			advance(source, &pos, &line, &column, 2)
			terminated := false
			for pos < len(source) {
				if source[pos] == '"' {
					advance(source, &pos, &line, &column, 1)
					terminated = true
					break
				}
				advance(source, &pos, &line, &column, 1)
			}
			if !terminated {
				append(&errors, Lex_Error {
					message = "unterminated bytes literal",
					line    = start_line,
					column  = start_column,
				})
				append_token(&tokens, .Error, source[start:pos], start, start_line, start_column)
				continue
			}
			append_token(&tokens, .Bytes, source[start:pos], start, start_line, start_column)
			continue

		case ch >= '0' && ch <= '9':
			is_float := false
			for pos < len(source) && is_digit(source[pos]) {
				advance(source, &pos, &line, &column, 1)
			}
			if pos + 1 < len(source) &&
			   source[pos] == '.' &&
			   source[pos + 1] != '.' &&
			   is_digit(source[pos + 1]) {
				advance(source, &pos, &line, &column, 1)
				for pos < len(source) && is_digit(source[pos]) {
					advance(source, &pos, &line, &column, 1)
				}
				is_float = true
			}
			if pos < len(source) && (source[pos] == 'e' || source[pos] == 'E') {
				next := pos + 1
				if next < len(source) && (source[next] == '+' || source[next] == '-') {
					next += 1
				}
				if next < len(source) && is_digit(source[next]) {
					advance(source, &pos, &line, &column, next - pos)
					for pos < len(source) && is_digit(source[pos]) {
						advance(source, &pos, &line, &column, 1)
					}
					is_float = true
				}
			}
			kind := is_float ? Token_Kind.Float : Token_Kind.Int
			append_token(&tokens, kind, source[start:pos], start, start_line, start_column)
			continue

		case is_ident_start(ch):
			for pos < len(source) && is_ident_continue(source[pos]) {
				advance(source, &pos, &line, &column, 1)
			}
			text := source[start:pos]
			if kind, is_keyword := keyword_kind(text); is_keyword {
				append_token(&tokens, kind, text, start, start_line, start_column)
			} else if is_error_code(text) {
				append_token(&tokens, .Error_Code, text, start, start_line, start_column)
			} else {
				append_token(&tokens, .Ident, text, start, start_line, start_column)
			}
			continue

		case ch == '_':
			advance(source, &pos, &line, &column, 1)
			if pos < len(source) && is_ident_continue(source[pos]) {
				for pos < len(source) && is_ident_continue(source[pos]) {
					advance(source, &pos, &line, &column, 1)
				}
				append_token(&tokens, .Ident, source[start:pos], start, start_line, start_column)
			} else {
				append_token(&tokens, .Underscore, source[start:pos], start, start_line, start_column)
			}
			continue
		}

		// Punctuation, longest match first.
		switch ch {
		case '(':
			advance(source, &pos, &line, &column, 1)
			append_token(&tokens, .LParen, source[start:pos], start, start_line, start_column)
		case ')':
			advance(source, &pos, &line, &column, 1)
			append_token(&tokens, .RParen, source[start:pos], start, start_line, start_column)
		case '[':
			advance(source, &pos, &line, &column, 1)
			append_token(&tokens, .LBracket, source[start:pos], start, start_line, start_column)
		case ']':
			advance(source, &pos, &line, &column, 1)
			append_token(&tokens, .RBracket, source[start:pos], start, start_line, start_column)
		case '{':
			advance(source, &pos, &line, &column, 1)
			append_token(&tokens, .LBrace, source[start:pos], start, start_line, start_column)
		case '}':
			advance(source, &pos, &line, &column, 1)
			append_token(&tokens, .RBrace, source[start:pos], start, start_line, start_column)
		case ',':
			advance(source, &pos, &line, &column, 1)
			append_token(&tokens, .Comma, source[start:pos], start, start_line, start_column)
		case ';':
			advance(source, &pos, &line, &column, 1)
			append_token(&tokens, .Semi, source[start:pos], start, start_line, start_column)
		case '#':
			advance(source, &pos, &line, &column, 1)
			append_token(&tokens, .Hash, source[start:pos], start, start_line, start_column)
		case '@':
			advance(source, &pos, &line, &column, 1)
			append_token(&tokens, .At, source[start:pos], start, start_line, start_column)
		case '?':
			advance(source, &pos, &line, &column, 1)
			append_token(&tokens, .Question, source[start:pos], start, start_line, start_column)
		case '.':
			if pos + 1 < len(source) && source[pos + 1] == '.' {
				advance(source, &pos, &line, &column, 2)
				append_token(&tokens, .DotDot, source[start:pos], start, start_line, start_column)
			} else {
				advance(source, &pos, &line, &column, 1)
				append_token(&tokens, .Dot, source[start:pos], start, start_line, start_column)
			}
		case ':':
			if pos + 1 < len(source) && source[pos + 1] == '-' {
				advance(source, &pos, &line, &column, 2)
				append_token(&tokens, .Colon_Dash, source[start:pos], start, start_line, start_column)
			} else {
				advance(source, &pos, &line, &column, 1)
				append_token(&tokens, .Colon, source[start:pos], start, start_line, start_column)
			}
		case '=':
			if pos + 1 < len(source) && source[pos + 1] == '=' {
				advance(source, &pos, &line, &column, 2)
				append_token(&tokens, .Eq_Eq, source[start:pos], start, start_line, start_column)
			} else if pos + 1 < len(source) && source[pos + 1] == '>' {
				advance(source, &pos, &line, &column, 2)
				append_token(&tokens, .Fat_Arrow, source[start:pos], start, start_line, start_column)
			} else {
				advance(source, &pos, &line, &column, 1)
				append_token(&tokens, .Eq, source[start:pos], start, start_line, start_column)
			}
		case '!':
			if pos + 1 < len(source) && source[pos + 1] == '=' {
				advance(source, &pos, &line, &column, 2)
				append_token(&tokens, .Bang_Eq, source[start:pos], start, start_line, start_column)
			} else {
				advance(source, &pos, &line, &column, 1)
				append_token(&tokens, .Bang, source[start:pos], start, start_line, start_column)
			}
		case '<':
			if pos + 1 < len(source) && source[pos + 1] == '=' {
				advance(source, &pos, &line, &column, 2)
				append_token(&tokens, .Lt_Eq, source[start:pos], start, start_line, start_column)
			} else {
				advance(source, &pos, &line, &column, 1)
				append_token(&tokens, .Lt, source[start:pos], start, start_line, start_column)
			}
		case '>':
			if pos + 1 < len(source) && source[pos + 1] == '=' {
				advance(source, &pos, &line, &column, 2)
				append_token(&tokens, .Gt_Eq, source[start:pos], start, start_line, start_column)
			} else {
				advance(source, &pos, &line, &column, 1)
				append_token(&tokens, .Gt, source[start:pos], start, start_line, start_column)
			}
		case '&':
			if pos + 1 < len(source) && source[pos + 1] == '&' {
				advance(source, &pos, &line, &column, 2)
				append_token(&tokens, .Amp_Amp, source[start:pos], start, start_line, start_column)
			} else {
				advance(source, &pos, &line, &column, 1)
				append_token(&tokens, .Error, source[start:pos], start, start_line, start_column)
				append(&errors, Lex_Error {
					message = "unexpected '&'",
					line    = start_line,
					column  = start_column,
				})
			}
		case '|':
			if pos + 1 < len(source) && source[pos + 1] == '|' {
				advance(source, &pos, &line, &column, 2)
				append_token(&tokens, .Pipe_Pipe, source[start:pos], start, start_line, start_column)
			} else {
				advance(source, &pos, &line, &column, 1)
				append_token(&tokens, .Pipe, source[start:pos], start, start_line, start_column)
			}
		case '-':
			if pos + 1 < len(source) && source[pos + 1] == '>' {
				advance(source, &pos, &line, &column, 2)
				append_token(&tokens, .Arrow, source[start:pos], start, start_line, start_column)
			} else {
				advance(source, &pos, &line, &column, 1)
				append_token(&tokens, .Minus, source[start:pos], start, start_line, start_column)
			}
		case '+':
			advance(source, &pos, &line, &column, 1)
			append_token(&tokens, .Plus, source[start:pos], start, start_line, start_column)
		case '*':
			advance(source, &pos, &line, &column, 1)
			append_token(&tokens, .Star, source[start:pos], start, start_line, start_column)
		case '/':
			advance(source, &pos, &line, &column, 1)
			append_token(&tokens, .Slash, source[start:pos], start, start_line, start_column)
		case '%':
			advance(source, &pos, &line, &column, 1)
			append_token(&tokens, .Percent, source[start:pos], start, start_line, start_column)
		case:
			// UTF-8 membership operator.
			if pos + 2 < len(source) &&
			   source[pos] == 0xe2 &&
			   source[pos + 1] == 0x88 &&
			   source[pos + 2] == 0x88 {
				advance(source, &pos, &line, &column, 3)
				append_token(&tokens, .Membership, source[start:pos], start, start_line, start_column)
				continue
			}
			// Non-ASCII text can appear inside DOM markup. The lexer keeps
			// it as one error token without a diagnostic so the parser can
			// decide whether the position accepts raw text.
			if ch >= 0x80 {
				length := utf8_sequence_length(ch)
				if pos + length > len(source) {
					length = len(source) - pos
				}
				advance(source, &pos, &line, &column, length)
				append_token(&tokens, .Error, source[start:pos], start, start_line, start_column)
				continue
			}
			advance(source, &pos, &line, &column, 1)
			append_token(&tokens, .Error, source[start:pos], start, start_line, start_column)
			append(&errors, Lex_Error {
				message = "unexpected character",
				line    = start_line,
				column  = start_column,
			})
		}
	}

	append(&tokens, Token{kind = .Eof, text = "", offset = pos, line = line, column = column})
	return Lex_Result{tokens = tokens[:], errors = errors[:]}
}

// Releases lexer storage.
lex_destroy :: proc(result: ^Lex_Result, allocator := context.allocator) {
	free(raw_data(result.tokens), allocator)
	free(raw_data(result.errors), allocator)
	result.tokens = nil
	result.errors = nil
}

@(private)
is_digit :: proc(ch: byte) -> bool {
	return ch >= '0' && ch <= '9'
}

@(private)
is_ident_start :: proc(ch: byte) -> bool {
	return (ch >= 'a' && ch <= 'z') || (ch >= 'A' && ch <= 'Z')
}

@(private)
is_ident_continue :: proc(ch: byte) -> bool {
	return is_ident_start(ch) || is_digit(ch) || ch == '_'
}

@(private)
utf8_sequence_length :: proc(lead: byte) -> int {
	switch {
	case lead & 0xe0 == 0xc0:
		return 2
	case lead & 0xf0 == 0xe0:
		return 3
	case lead & 0xf8 == 0xf0:
		return 4
	}
	return 1
}

@(private)
is_error_code :: proc(text: string) -> bool {
	return len(text) > 2 && text[0] == 'E' && text[1] == '_'
}

@(private)
keyword_kind :: proc(text: string) -> (Token_Kind, bool) {
	switch text {
	case "let":
		return .Let, true
	case "const":
		return .Const, true
	case "if":
		return .If, true
	case "elseif":
		return .Elseif, true
	case "else":
		return .Else, true
	case "end":
		return .End, true
	case "begin":
		return .Begin, true
	case "for":
		return .For, true
	case "in":
		return .In, true
	case "while":
		return .While, true
	case "return":
		return .Return, true
	case "raise":
		return .Raise, true
	case "recover":
		return .Recover, true
	case "spawn":
		return .Spawn, true
	case "after":
		return .After, true
	case "not":
		return .Not, true
	case "break":
		return .Break, true
	case "continue":
		return .Continue, true
	case "try":
		return .Try, true
	case "catch":
		return .Catch, true
	case "as":
		return .As, true
	case "finally":
		return .Finally, true
	case "fn":
		return .Fn, true
	case "method":
		return .Method, true
	case "verb":
		return .Verb, true
	case "do":
		return .Do, true
	case "assert":
		return .Assert, true
	case "retract":
		return .Retract, true
	case "require":
		return .Require, true
	case "true":
		return .True, true
	case "false":
		return .False, true
	case:
		return .Ident, false
	}
}
