// Abstract syntax for the Mica surface language.
//
// Expressions are the only statement form; blocks are slices of expressions.
// Nodes are allocated from a parsing arena and referenced by pointer so the
// tree is easy to lower and discard.
package compiler

// Unary operators.
Unary_Op :: enum {
	Neg,
	Not,
}

// Binary operators, in the language's precedence order where relevant.
Binary_Op :: enum {
	Add,
	Sub,
	Mul,
	Div,
	Rem,
	Range,
	Lt,
	Le,
	Gt,
	Ge,
	Eq,
	Ne,
	And,
	Or,
}

Int_Literal :: struct {
	text: string,
}

Float_Literal :: struct {
	text: string,
}

// String and bytes literals keep their raw source text, quotes included.
String_Literal :: struct {
	text: string,
}

Bytes_Literal :: struct {
	text: string,
}

Bool_Literal :: struct {
	value: bool,
}

Error_Code_Literal :: struct {
	name: string,
}

// `#lamp` or `#0`.
Identity_Literal :: struct {
	name: string,
}

// `:name` or `:"quoted"`.
Symbol_Literal :: struct {
	name: string,
}

// A possibly qualified name, such as `trim` or `workflow/AssignedTo`.
Name :: struct {
	parts: []string,
}

// `?name`.
Query_Variable :: struct {
	name: string,
}

// `_`.
Wildcard :: struct {
}

// `@name` or `@expr` in argument and element positions.
Splice :: struct {
	value: ^Expr,
}

List_Literal :: struct {
	elements: []^Expr,
}

Map_Entry_AST :: struct {
	key:   ^Expr,
	value: ^Expr,
}

Map_Literal :: struct {
	entries: []Map_Entry_AST,
}

// `start..end`, with `has_end` false for `start.._`.
Range_Literal :: struct {
	start:   ^Expr,
	end:     ^Expr,
	has_end: bool,
}

// Pattern nodes for bindings, `if let`, and `match`.
Binding_Pattern :: struct {
	name: string,
}

Wildcard_Pattern :: struct {
}

// A constant pattern, such as a case label.
Literal_Pattern :: struct {
	value: ^Expr,
}

// `@rest`.
Rest_Pattern :: struct {
	name: string,
}

// `?name` with an optional default, as in list destructuring.
Optional_Pattern :: struct {
	name:        string,
	default:     ^Expr,
	has_default: bool,
}

List_Pattern :: struct {
	elements: []^Pattern,
}

Map_Pattern_Entry :: struct {
	key:       ^Expr,
	pattern:   ^Pattern,
	shorthand: bool,
}

Map_Pattern :: struct {
	entries: []Map_Pattern_Entry,
}

// `some(x)`, `ok(x)`, `err(x)`, or any constructor-like pattern.
Call_Pattern :: struct {
	name: string,
	args: []^Pattern,
}

Pattern :: union {
	Binding_Pattern,
	Wildcard_Pattern,
	Literal_Pattern,
	Rest_Pattern,
	Optional_Pattern,
	List_Pattern,
	Map_Pattern,
	Call_Pattern,
}

// `let <pattern> = value` or `const <pattern> = value`. `is_exactly` marks
// the `let exactly <pattern> = ...` form, which requires one row.
Binding :: struct {
	is_const:   bool,
	is_exactly: bool,
	pattern:    ^Pattern,
	kind:       string,
	has_kind:   bool,
	value:      ^Expr,
	has_value:  bool,
}

Unary :: struct {
	op:      Unary_Op,
	operand: ^Expr,
}

Binary :: struct {
	op:    Binary_Op,
	left:  ^Expr,
	right: ^Expr,
}

Assignment :: struct {
	target: ^Expr,
	value:  ^Expr,
}

// An argument in a call or dispatch. A role is set for named-role calls.
Call_Argument :: struct {
	role:     string,
	has_role: bool,
	expr:     ^Expr,
}

Call :: struct {
	callee: ^Expr,
	args:   []Call_Argument,
}

Index :: struct {
	collection: ^Expr,
	key:        ^Expr,
}

Field :: struct {
	receiver: ^Expr,
	name:     string,
}

If_Branch :: struct {
	condition: ^Expr,
	body:      []^Expr,
}

If :: struct {
	branches:  []If_Branch,
	else_body: []^Expr,
	has_else:  bool,
}

While :: struct {
	condition: ^Expr,
	body:      []^Expr,
}

// `for name[, value] in iterable`. `kinds` is parallel to `names`; empty
// strings mean no annotation.
For :: struct {
	names:    []string,
	kinds:    []string,
	iterable: ^Expr,
	body:     []^Expr,
}

Begin :: struct {
	body: []^Expr,
}

Return :: struct {
	value:     ^Expr,
	has_value: bool,
}

Break :: struct {
}

Continue :: struct {
}

Assert :: struct {
	atom: ^Expr,
}

Retract :: struct {
	atom: ^Expr,
}

Require :: struct {
	condition: ^Expr,
}

Raise :: struct {
	parts: []^Expr,
}

Param_Mode :: enum {
	Required,
	Optional,
	Rest,
}

// A function parameter with an optional role restriction and kind annotation.
// Optional parameters take a default when the call omits them; a rest
// parameter collects the remaining arguments into a list.
Param :: struct {
	name:            string,
	restriction:     ^Expr,
	has_restriction: bool,
	kind:            string,
	has_kind:        bool,
	mode:            Param_Mode,
	default:         ^Expr,
	has_default:     bool,
}

// A cell in a structural variant value. `name` is set for named fields.
Structural_Cell :: struct {
	name:  ^Expr,
	value: ^Expr,
}

// `#id<[cells]>` or `#id<{field -> value}>`.
Structural_Literal :: struct {
	head:  ^Expr,
	cells: []Structural_Cell,
	named: bool,
}

// A DOM attribute. Attributes without a value are boolean presence.
Dom_Attribute :: struct {
	name:      string,
	value:     ^Expr,
	has_value: bool,
}

// Literal text inside DOM markup.
Dom_Text :: struct {
	text: string,
}

// `dom <tag ...>children</tag>`.
Dom_Element :: struct {
	tag:          string,
	attributes:   []Dom_Attribute,
	children:     []^Expr,
	self_closing: bool,
}

Match_Case :: struct {
	pattern:   ^Pattern,
	guard:     ^Expr,
	has_guard: bool,
	body:      []^Expr,
}

Match :: struct {
	value: ^Expr,
	cases: []Match_Case,
}

Catch_Clause :: struct {
	code:     string,
	has_code: bool,
	name:     string,
	has_name: bool,
	body:     []^Expr,
}

Try :: struct {
	body:         []^Expr,
	catches:      []Catch_Clause,
	finally_body: []^Expr,
	has_finally:  bool,
}

Spawn :: struct {
	call:      ^Expr,
	delay:     ^Expr,
	has_delay: bool,
}

Fn :: struct {
	params:              []Param,
	body:                []^Expr,
	expression_body:     ^Expr,
	has_expression_body: bool,
}

// The expression union. Every language form is an expression.
Expr :: union {
	Int_Literal,
	Float_Literal,
	String_Literal,
	Bytes_Literal,
	Bool_Literal,
	Error_Code_Literal,
	Identity_Literal,
	Symbol_Literal,
	Name,
	Query_Variable,
	Wildcard,
	Splice,
	List_Literal,
	Map_Literal,
	Range_Literal,
	Binding,
	Unary,
	Binary,
	Assignment,
	Call,
	Index,
	Field,
	If,
	While,
	For,
	Begin,
	Return,
	Break,
	Continue,
	Assert,
	Retract,
	Require,
	Raise,
	Match,
	Try,
	Spawn,
	Structural_Literal,
	Dom_Text,
	Dom_Element,
	Fn,
}

// Authority sections inside a `grant` block.
Grant_Section_Kind :: enum {
	Read,
	Write,
	Invoke,
	Effect,
}

Grant_Section :: struct {
	kind:    Grant_Section_Kind,
	entries: []^Expr,
}

// `grant #principal` or `grant role #principal` with read, write, invoke, and
// effect sections.
Grant_Item :: struct {
	principal: ^Expr,
	is_role:   bool,
	sections:  []Grant_Section,
}

Expr_Item :: struct {
	expr: ^Expr,
}

Verb_Item :: struct {
	name:        string,
	params:      []Param,
	result_type: string,
	body:        []^Expr,
}

Rule_Item :: struct {
	head: ^Expr,
	body: []^Expr,
}

Item :: union {
	Expr_Item,
	Verb_Item,
	Rule_Item,
	Grant_Item,
}

Program_AST :: struct {
	items: []Item,
}
