// AST rule conversion into kernel rules.
package mica_runtime

import "core:fmt"
import "core:strconv"
import "core:strings"
import c "../compiler"
import k "../kernel"
import v "../var"

@(private)
Rule_Builder :: struct {
	ctx:            ^c.Compile_Context,
	anonymous_count: int,
}

@(private)
rule_builder_anonymous_name :: proc(builder: ^Rule_Builder) -> string {
	builder.anonymous_count += 1
	builder_out: strings.Builder
	strings.builder_init(&builder_out, context.temp_allocator)
	fmt.sbprintf(&builder_out, "_anon%d", builder.anonymous_count)
	return strings.to_string(builder_out)
}

@(private)
rule_term :: proc(builder: ^Rule_Builder, expr: ^c.Expr) -> (k.Term, bool) {
	#partial switch node in expr^ {
	case c.Query_Variable:
		return k.term_var(v.symbol_intern(node.name)), true
	case c.Name:
		return k.term_var(v.symbol_intern(name_text(node))), true
	case c.Wildcard:
		return k.term_var(v.symbol_intern(rule_builder_anonymous_name(builder))), true
	case c.Int_Literal:
		value, ok := strconv.parse_i64(node.text)
		if !ok {
			return {}, false
		}
		converted, converted_ok := v.value_int(value)
		if !converted_ok {
			return {}, false
		}
		return k.term_value(converted), true
	case c.Float_Literal:
		value, ok := strconv.parse_f64(node.text)
		if !ok {
			return {}, false
		}
		converted, converted_ok := v.value_float(f32(value))
		if !converted_ok {
			return {}, false
		}
		return k.term_value(converted), true
	case c.String_Literal:
		return k.term_value(v.value_string(context.temp_allocator, unquote(node.text))), true
	case c.Bool_Literal:
		return k.term_value(v.value_bool(node.value)), true
	case c.Symbol_Literal:
		return k.term_value(v.value_symbol(v.symbol_intern(unquote(node.name)))), true
	case c.Identity_Literal:
		if raw, ok := strconv.parse_u64(node.name); ok {
			converted, converted_ok := v.value_identity_raw(raw)
			if !converted_ok {
				return {}, false
			}
			return k.term_value(converted), true
		}
		if builder.ctx != nil {
			if value, found := builder.ctx.identities[node.name]; found {
				return k.term_value(value), true
			}
		}
		return {}, false
	case c.Error_Code_Literal:
		return k.term_value(v.value_error_code(v.symbol_intern(node.name))), true
	}
	return {}, false
}

@(private)
rule_atom :: proc(builder: ^Rule_Builder, call: c.Call, negated: bool) -> (k.Atom, bool) {
	callee, is_name := call.callee^.(c.Name)
	if !is_name || builder.ctx == nil {
		return {}, false
	}
	relation, found := builder.ctx.relations[name_text(callee)]
	if !found {
		return {}, false
	}
	terms := make([]k.Term, len(call.args), context.temp_allocator)
	for argument, index in call.args {
		term, term_ok := rule_term(builder, argument.expr)
		if !term_ok {
			return {}, false
		}
		terms[index] = term
	}
	if negated {
		return k.atom_negated(k.Relation_ID(relation), terms), true
	}
	return k.atom_positive(k.Relation_ID(relation), terms), true
}

@(private)
rule_body_item :: proc(builder: ^Rule_Builder, expr: ^c.Expr) -> (k.Rule_Body_Item, bool) {
	if call, is_call := expr^.(c.Call); is_call {
		atom, ok := rule_atom(builder, call, false)
		if !ok {
			return {}, false
		}
		return k.body_atom(atom), true
	}

	if unary, is_unary := expr^.(c.Unary); is_unary && unary.op == .Not {
		if call, is_call := unary.operand^.(c.Call); is_call {
			atom, ok := rule_atom(builder, call, true)
			if !ok {
				return {}, false
			}
			return k.body_atom(atom), true
		}
		return {}, false
	}

	if comparison, is_binary := expr^.(c.Binary); is_binary {
		op: k.Rule_Comparison_Op
		#partial switch comparison.op {
		case .Eq:
			op = .Eq
		case .Ne:
			op = .Ne
		case .Lt:
			op = .Lt
		case .Le:
			op = .Le
		case .Gt:
			op = .Gt
		case .Ge:
			op = .Ge
		case:
			return {}, false
		}
		left, left_ok := rule_term(builder, comparison.left)
		if !left_ok {
			return {}, false
		}
		right, right_ok := rule_term(builder, comparison.right)
		if !right_ok {
			return {}, false
		}
		return k.body_guard(k.rule_guard(op, left, right)), true
	}

	return {}, false
}

// Converts a parsed rule item into a kernel rule. Returns false when the rule
// uses a relation or term the runtime cannot lower yet.
convert_rule :: proc(
	rule_item: c.Rule_Item,
	ctx: ^c.Compile_Context,
) -> (
	k.Rule,
	bool,
) {
	call, is_call := rule_item.head^.(c.Call)
	if !is_call {
		return {}, false
	}
	callee, is_name := call.callee^.(c.Name)
	if !is_name {
		return {}, false
	}
	head_relation, found := ctx.relations[name_text(callee)]
	if !found {
		return {}, false
	}

	builder := Rule_Builder{ctx = ctx}
	head_terms := make([]k.Term, len(call.args), context.temp_allocator)
	for argument, index in call.args {
		term, term_ok := rule_term(&builder, argument.expr)
		if !term_ok {
			return {}, false
		}
		head_terms[index] = term
	}

	body := make([]k.Rule_Body_Item, len(rule_item.body), context.temp_allocator)
	for expression, index in rule_item.body {
		item, item_ok := rule_body_item(&builder, expression)
		if !item_ok {
			return {}, false
		}
		body[index] = item
	}

	return k.rule_new(k.Relation_ID(head_relation), head_terms, body), true
}

@(private)
name_text :: proc(name: c.Name) -> string {
	if len(name.parts) == 1 {
		return name.parts[0]
	}
	builder: strings.Builder
	strings.builder_init(&builder, context.temp_allocator)
	for part, index in name.parts {
		if index > 0 {
			strings.write_byte(&builder, '/')
		}
		strings.write_string(&builder, part)
	}
	return strings.to_string(builder)
}

@(private)
unquote :: proc(text: string, allocator := context.temp_allocator) -> string {
	if len(text) < 2 || text[0] != '"' {
		return text
	}
	return text[1 : len(text) - 1]
}
