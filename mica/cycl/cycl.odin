package cycl

import "core:fmt"
import "core:strings"
import "core:mem"
import "core:strconv"

// CycL AST node types
Node :: union {
	Atom,
	List,
	String,
	Number,
	Variable,
}

Atom :: distinct string
Variable :: distinct string
String :: distinct string
Number :: distinct f64

List :: struct {
	elements: [dynamic]Node,
}

// Lexer state
Lexer :: struct {
	input:  string,
	pos:    int,
	ch:     u8,
}

lexer_create :: proc(input: string) -> Lexer {
	ch: u8 = 0
	if len(input) > 0 {
		ch = input[0]
	}
	return Lexer{
		input = input,
		pos = 0,
		ch = ch,
	}
}

lexer_skip_whitespace :: proc(lex: ^Lexer) {
	for lex.ch != 0 && (lex.ch == ' ' || lex.ch == '\t' || lex.ch == '\n' || lex.ch == '\r') {
		lex.pos += 1
		if lex.pos < len(lex.input) {
			lex.ch = lex.input[lex.pos]
		} else {
			lex.ch = 0
		}
	}
}

is_digit :: proc(ch: u8) -> bool {
	return ch >= '0' && ch <= '9'
}

is_atom_char :: proc(ch: u8) -> bool {
	return ch != 0 && ch != ' ' && ch != '\t' && ch != '\n' && ch != '\r' && ch != '(' && ch != ')' && ch != '"'
}

lexer_read_atom :: proc(lex: ^Lexer) -> string {
	start := lex.pos
	for is_atom_char(lex.ch) {
		lex.pos += 1
		if lex.pos < len(lex.input) {
			lex.ch = lex.input[lex.pos]
		} else {
			lex.ch = 0
		}
	}
	return lex.input[start:lex.pos]
}

lexer_read_string :: proc(lex: ^Lexer) -> string {
	lex.pos += 1  // skip opening "
	if lex.pos < len(lex.input) {
		lex.ch = lex.input[lex.pos]
	} else {
		lex.ch = 0
	}
	
	start := lex.pos
	for lex.ch != 0 && lex.ch != '"' {
		if lex.ch == '\\' {
			lex.pos += 1
			if lex.pos < len(lex.input) {
				lex.ch = lex.input[lex.pos]
			} else {
				lex.ch = 0
			}
		}
		lex.pos += 1
		if lex.pos < len(lex.input) {
			lex.ch = lex.input[lex.pos]
		} else {
			lex.ch = 0
		}
	}
	
	result := lex.input[start:lex.pos]
	if lex.ch == '"' {
		lex.pos += 1
		if lex.pos < len(lex.input) {
			lex.ch = lex.input[lex.pos]
		} else {
			lex.ch = 0
		}
	}
	return result
}

lexer_read_number :: proc(lex: ^Lexer) -> f64 {
	start := lex.pos
	if lex.ch == '-' || lex.ch == '+' {
		lex.pos += 1
		if lex.pos < len(lex.input) {
			lex.ch = lex.input[lex.pos]
		} else {
			lex.ch = 0
		}
	}
	
	for is_digit(lex.ch) {
		lex.pos += 1
		if lex.pos < len(lex.input) {
			lex.ch = lex.input[lex.pos]
		} else {
			lex.ch = 0
		}
	}
	
	if lex.ch == '.' {
		lex.pos += 1
		if lex.pos < len(lex.input) {
			lex.ch = lex.input[lex.pos]
		} else {
			lex.ch = 0
		}
		for is_digit(lex.ch) {
			lex.pos += 1
			if lex.pos < len(lex.input) {
				lex.ch = lex.input[lex.pos]
			} else {
				lex.ch = 0
			}
		}
	}
	
	num_str := lex.input[start:lex.pos]
	value, _ := strconv.parse_f64(num_str)
	return value
}

// Parse a CycL s-expression
parse :: proc(input: string, allocator := context.allocator) -> (Node, bool) {
	lex := lexer_create(input)
	context.allocator = allocator
	node, ok := parse_node(&lex, allocator)
	return node, ok
}

parse_node :: proc(lex: ^Lexer, allocator: mem.Allocator) -> (Node, bool) {
	context.allocator = allocator
	
	lexer_skip_whitespace(lex)
	
	if lex.ch == '(' {
		lex.pos += 1
		if lex.pos < len(lex.input) {
			lex.ch = lex.input[lex.pos]
		} else {
			lex.ch = 0
		}
		
		elements := make([dynamic]Node, allocator)
		for {
			lexer_skip_whitespace(lex)
			if lex.ch == ')' {
				lex.pos += 1
				if lex.pos < len(lex.input) {
					lex.ch = lex.input[lex.pos]
				} else {
					lex.ch = 0
				}
				break
			}
			
			node, ok := parse_node(lex, allocator)
			if !ok {
				return nil, false
			}
			append(&elements, node)
		}
		
		return List{elements}, true
		
	} else if lex.ch == '"' {
		str := lexer_read_string(lex)
		return String(str), true
		
	} else if lex.ch == '?' {
		lex.pos += 1
		if lex.pos < len(lex.input) {
			lex.ch = lex.input[lex.pos]
		} else {
			lex.ch = 0
		}
		atom := lexer_read_atom(lex)
		return Variable(fmt.aprintf("?%s", atom)), true
		
	} else if lex.ch == '#' {
		lex.pos += 1
		if lex.pos < len(lex.input) {
			lex.ch = lex.input[lex.pos]
		} else {
			lex.ch = 0
		}
		
		if lex.ch == '$' {
			lex.pos += 1
			if lex.pos < len(lex.input) {
				lex.ch = lex.input[lex.pos]
			} else {
				lex.ch = 0
			}
		}
		
		atom := lexer_read_atom(lex)
		return Atom(fmt.aprintf("#$%s", atom)), true
		
	} else if lex.ch == ':' {
		atom := lexer_read_atom(lex)
		return Atom(fmt.aprintf(":%s", atom)), true
		
	} else if lex.ch == '-' || lex.ch == '+' {
		ch := lex.ch
		lex.pos += 1
		if lex.pos < len(lex.input) {
			lex.ch = lex.input[lex.pos]
		} else {
			lex.ch = 0
		}
		
		if is_digit(lex.ch) {
			lex.pos -= 1
			lex.ch = ch
			num := lexer_read_number(lex)
			return Number(num), true
		} else {
			lex.pos -= 1
			lex.ch = ch
			atom := lexer_read_atom(lex)
			return Atom(atom), true
		}
		
	} else if is_digit(lex.ch) {
		num := lexer_read_number(lex)
		return Number(num), true
		
	} else if lex.ch == 0 {
		return nil, false
		
	} else {
		atom := lexer_read_atom(lex)
		if len(atom) > 0 {
			return Atom(atom), true
		}
		return nil, false
	}
}

// Helper: convert Node to string for debugging
to_string :: proc(node: Node) -> string {
	switch n in node {
	case Atom:
		return string(n)
	case Variable:
		return string(n)
	case String:
		return fmt.tprintf("\"%s\"", string(n))
	case Number:
		return fmt.tprintf("%f", n)
	case List:
		sb := strings.builder_make()
		strings.write_string(&sb, "(")
		for elem in n.elements {
			strings.write_string(&sb, to_string(elem))
			strings.write_string(&sb, " ")
		}
		strings.write_string(&sb, ")")
		return strings.to_string(sb)
	case nil:
		return "nil"
	}
	return ""
}

// Extract predicate name and arguments from a formula node
// Formula: (predicate arg1 arg2 ...)
extract_formula :: proc(formula: Node) -> (predicate: Atom, args: []Node, ok: bool) {
	list, is_list := formula.(List)
	if !is_list || len(list.elements) == 0 {
		return Atom(""), nil, false
	}
	
	pred, is_atom := list.elements[0].(Atom)
	if !is_atom {
		return Atom(""), nil, false
	}
	
	return pred, list.elements[1:], true
}
