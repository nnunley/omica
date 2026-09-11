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

// `let name = value` or `const name = value`, with an optional kind.
Binding :: struct {
	is_const: bool,
	name:     string,
	kind:     string,
	has_kind: bool,
	value:    ^Expr,
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

// `for name[, value] in iterable`.
For :: struct {
	names:    []string,
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

// A function parameter with an optional role restriction and kind annotation.
Param :: struct {
	name:           string,
	restriction:    ^Expr,
	has_restriction: bool,
	kind:           string,
	has_kind:       bool,
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
	Fn,
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
}

Program_AST :: struct {
	items: []Item,
}
