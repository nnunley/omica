# draft-ndn-casts-and-literals-00: Explicit Casts, Strict Comparison, and the Normative Literal Form

**Status:** DRAFT
**Category:** Standards-Track
**Corpus:** red (neither implementation has `as`, strict comparison, or name-ordered symbols yet)
**Authors:** Norman Nunley, Jr <nnunley@gmail.com>, Claude (drafting agent)

## Abstract

Mica converts between value kinds only when a program asks it to. This
document adds the cast operator `expr as kind`, makes comparison
operators compare values of one kind only, and fixes the text every
implementation produces for a value with `to_literal`: the form of
floats and quoted symbols, and a canonical order that sorts symbols by
name. With these rules the same program prints the same text on every
implementation.

## Motivation

Ryan Daum is working toward one normative form across Mica
implementations. Differential runs of `to_literal` on omica 5a22a77 and
Rust mica a433170 agree on integers, strings, simple symbols, lists,
ranges and relations, and disagree on:

| Value | omica | Rust mica | Problem |
|---|---|---|---|
| `1.0` | `1` | `1e0` | omica's text reads back as an integer |
| `100.0` | `100` | `1e2` | two float spellings |
| `0.0` | `0` | `0.0` | Rust mixes positional and exponent forms |
| `1.0e20` | `1e+20` | `1e20` | exponent sign spelling |
| `:"with space"` | `:with space` | `:"with space"` | omica's text cannot be read back |
| `ok(1)` | `[:case, :value] {…}` | `[:value, :case] {…}` | heading order differs |
| `{:alpha -> 1, :value -> 2}` | `:alpha` first | `:value` first | Rust orders symbols by interning |

The last two rows show that "canonical order" is decided by the order
in which each runtime happened to intern symbols. Separately, the
language compares `1 == 1.0` as true and orders `1 < "a"` across kinds,
so equality silently converts between kinds even though arithmetic
already refuses to (`1 + 1.5` raises `E_TYPE`).

## Terminology

The key words "MUST", "MUST NOT", "REQUIRED", "SHALL", "SHALL NOT", "SHOULD",
"SHOULD NOT", "RECOMMENDED", "NOT RECOMMENDED", "MAY", and "OPTIONAL" in this
document are to be interpreted as described in BCP 14 (RFC 2119, RFC 8174)
when, and only when, they appear in all capitals, as shown here.

- **kind** — a value kind as named in value-kind annotations: `int`, `float`, `string`, `symbol`, and the others.
- **cast** — the expression `expr as kind`.
- **literal form** — the text `to_literal` returns for a value.
- **canonical order** — the total order used for map keys, relation headings and rows, sorting, and printing.

## Specification

### The cast operator

`expr as kind` converts the value of `expr` to `kind`. `as` binds more
tightly than every binary operator and less tightly than unary operators
and postfix forms (calls, indexing, field access), so `-x as float`
converts `-x` and `a + b as float` converts only `b`. `kind` is a kind
name, not an expression. [R-cast-syntax]

```abnf
cast-expr  = unary-expr *( 1*SP "as" 1*SP kind-name )
unary-expr = <a unary or postfix expression of the language grammar>
kind-name  = "int" / "float" / "string" / "symbol"
```

```mica mode=eval @R-cast-syntax
return 3 as float
```

```expect
3.0
```

A cast MUST convert as the table below states. A cast between kinds the
table does not list MUST raise `E_TYPE`. A cast to the value's own kind
returns the value unchanged. [R-cast-table]

| From | `as int` | `as float` | `as string` | `as symbol` |
|---|---|---|---|---|
| int | itself | nearest binary32 (as `to_float`) | decimal digits | `E_TYPE` |
| float | exact integral value, else `E_TYPE` (as `to_int`) | itself | the literal form | `E_TYPE` |
| string | `parse_int`, `E_INVARG` if malformed | `parse_float`, `E_INVARG` if malformed | itself | the symbol with that name |
| symbol | `E_TYPE` | `E_TYPE` | its name, without `:` | itself |
| bool | `E_TYPE` | `E_TYPE` | `true` / `false` | `E_TYPE` |

<!-- evidence: @R-cast-table template=cast-case -->
| input | expect |
|---|---|
| `2.0 as int` | `2` |
| `"42" as int` | `42` |
| `"1.5e1" as float` | `15.0` |
| `:ready as string` | `"ready"` |
| `"go" as symbol` | `:go` |
| `true as string` | `"true"` |
| `7 as int` | `7` |

```mica id=cast-case mode=eval
return {{input}}
```

<!-- evidence: @R-cast-table template=cast-error -->
| input | expect-error |
|---|---|
| `2.5 as int` | `E_TYPE` |
| `"x" as int` | `E_INVARG` |
| `true as int` | `E_TYPE` |
| `:a as float` | `E_TYPE` |

```mica id=cast-error mode=eval
return {{input}}
```

The functions `to_int`, `to_float`, `parse_int` and `parse_float` keep
their meaning and equal the corresponding casts.

### Strict comparison

`==` and `!=` MUST compare by canonical equality: values of different
kinds are unequal, so `1 == 1.0` is false and `[1] == [1.0]` is false.
`<`, `<=`, `>` and `>=` MUST raise `E_TYPE` when their operands have
different kinds; compare after an explicit cast. Rule guards follow the
same rules. [R-strict-comparison]

<!-- evidence: @R-strict-comparison template=compare-case -->
| input | expect |
|---|---|
| `1 == 1.0` | `false` |
| `1 as float == 1.0` | `true` |
| `1 != 1.0` | `true` |
| `2 < 3` | `true` |

```mica id=compare-case mode=eval
return {{input}}
```

```mica mode=eval @R-strict-comparison
return 1 < 1.5
```

```expect-error
E_TYPE
```

### The literal form

`to_literal(value)` MUST produce text that `from_literal` reads back to
a canonically equal value, and every implementation MUST produce the
same text for the same value. [R-literal-form]

- **int**: decimal digits with a leading `-` when negative.
- **float**: the shortest decimal digit string that reads back to the
  same binary32 value. When the value is zero or its magnitude is at
  least `1e-4` and below `1e7`, it is written positionally with at least
  one digit after the point (`1.0`, `0.1`, `100.0`, `-2.5`, `0.0`).
  Otherwise it is written as a mantissa with exactly one digit before
  the point and at least one after, then `e`, then the exponent with a
  `-` only when negative (`1.0e20`, `1.5e-5`).
- **string**: double-quoted, with the escapes of the values chapter.
- **symbol**: `:name` when the name is a plain identifier, else `:` followed by the quoted string form of the name.
- **list, map, range, relation, error**: as the values chapter writes
  them, with map entries, relation heading names, and relation rows in
  canonical order.

<!-- evidence: @R-literal-form template=literal-case -->
| input | expect |
|---|---|
| `1.0` | `"1.0"` |
| `100.0` | `"100.0"` |
| `0.0` | `"0.0"` |
| `-2.5` | `"-2.5"` |
| `1.0e20` | `"1.0e20"` |
| `0.00001` | `"1.0e-5"` |
| `:"with space"` | `":\"with space\""` |
| `42` | `"42"` |

```mica id=literal-case mode=eval
return to_literal({{input}})
```

### Canonical order of symbols

Canonical order MUST sort symbols by name, comparing names as sequences
of Unicode scalar values. It MUST NOT depend on the order in which an
implementation created or interned symbols. [R-symbol-order]

<!-- evidence: @R-symbol-order template=literal-case -->
| input | expect |
|---|---|
| `{:zeta -> 1, :alpha -> 2}` | `"{:alpha -> 2, :zeta -> 1}"` |
| `{:alpha -> 1, :value -> 2}` | `"{:alpha -> 1, :value -> 2}"` |
| `[:zeta, :alpha] { [1, 2] }` | `"[:alpha, :zeta] {[2, 1]}"` |

## Out of Scope

- Casts to collection kinds (`as list`, `as map`, `as relation`).
  Extension point: new columns in the cast table.
- Ordering across kinds for sorting: canonical order still orders
  values of different kinds by kind; only the comparison operators
  become kind-strict. Extension point: a `compare` builtin.
- The literal form of identities, frobs, capabilities and functions.
  Extension point: a row per kind in the literal form list.

## Alternatives Considered

**Why an operator rather than only conversion functions?** The
functions exist and stay, but a program that must say every conversion
reads better with one construct, and a Mica compiler lowers one form
instead of four builtins.

**Why not kind-named constructors like `float(x)`?** Call syntax
already means verbs and `some`/`ok`/`error` constructors; `as` is
already a keyword and cannot collide with a verb name.

**Why raise instead of converting in `<`?** A comparison that converts
hides the same mistake mixed arithmetic already rejects; making both
refuse keeps one rule.

**Why this float format?** It keeps integers and floats distinguishable
in text (every float has a point), matches how people write floats in
the ordinary range, and uses an exponent only where positional digits
would mislead about binary32 precision. The thresholds are a proposal;
the requirement is that one rule holds everywhere.

## Security Considerations

None beyond existing value handling: casts do not reach outside the
value, and `string as symbol` interns a name exactly as a symbol literal
does. Implementations that bound symbol creation apply the same bound
here.

## Compatibility

`1 == 1.0` changes from true to false, and mixed-kind `<` changes from
an answer to `E_TYPE`. Programs relying on either must cast explicitly.
Stored data does not change: canonical equality already governed keys
and joins.

## References

- R. Daum, *A Relational Theory of Objecthood and Identity* (outline), [revision de5bc29](https://gist.github.com/rdaum/fdfb78358b0d76f778f52adadedcdece/de5bc29005582355ce79f17201fdb8bd0bda4dc2): the series' framing: handles, equivalence, objecthood and identity claims.
- H. G. Baker, "Equal Rights for Functional Objects or, The More Things Change, The More They Are the Same," 1993: one equality for immutable values.
- C. J. Date and H. Darwen, The Third Manifesto, 3rd ed., 2006: equality within a type, no implicit coercion.
- C. J. Date, SQL and Relational Theory, O'Reilly, 2009: implicit conversion as a source of error in SQL.
- `mdbook/src/language/values.md` — numeric kinds, conversion functions, escapes.
- draft-ndn-mica-snippets-00 — the `mica` evidence and `expect` rules used here.
- rdaum/omica#127 — the book harness; the book's cast examples are listed as known failures until an implementation supports them.
