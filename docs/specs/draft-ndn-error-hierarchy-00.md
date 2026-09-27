# draft-ndn-error-hierarchy-00: Error Hierarchy — Error Codes Related by Facts

**Status:** DRAFT
**Corpus:** red (spec-first: no implementation relates error codes yet)
**Category:** Standards-Track
**Authors:** Norman Nunley, Jr <nnunley@gmail.com>, Claude (drafting agent)

## Abstract

Mica error codes are flat: `catch E_X` matches exactly `E_X`. This
document relates codes by stored facts, `ErrorParent(code, parent)`, and
makes a catch clause match every code whose ancestors include the
clause's code. Code can then report the precise failure, such as
`E_KEY` for a missing map key, while callers that care only about the
general kind catch one ancestor, such as `E_LOOKUP`.

## Motivation

The book assigns one code to several different failures: "Reading an
absent list position, relation row, or map key raises `E_INDEX`"
(`mdbook/src/language/values.md`). That keeps generic handlers simple,
because `x[k]` means the same operation on a list, a map, or a relation,
but the code no longer says what went wrong. omica already raises
`E_KEY` for a missing map key, which the book does not define. Flat codes
force every language to pick one of those two costs; this is a MOO
inheritance Mica does not need.

Other languages keep both properties with a hierarchy: Python's
`KeyError` and `IndexError` share `LookupError`, and Common Lisp's
condition types allow more than one parent. Mica states knowledge as
relations, and an integration can already create codes with
`error_code(symbol)`, so the hierarchy belongs in the world as facts
rather than in a fixed table inside the implementation.

This document specifies those facts, how `catch` uses them, and the
built-in hierarchy.

## Terminology

The key words "MUST", "MUST NOT", "REQUIRED", "SHALL", "SHALL NOT", "SHOULD",
"SHOULD NOT", "RECOMMENDED", "NOT RECOMMENDED", "MAY", and "OPTIONAL" in this
document are to be interpreted as described in BCP 14 (RFC 2119, RFC 8174)
when, and only when, they appear in all capitals, as shown here.

- **parent link** — a fact `ErrorParent(code, parent)`: every `code`
  failure is also a `parent` failure.
- **ancestor** — `a` is an ancestor of `c` when `ErrorIsA(c, a)` holds:
  `c` itself, or an ancestor of one of `c`'s parents.
- **root code** — a code with no parent links. Every code is a root code
  until a link names it.

## Specification

This document defines the relations that relate error codes, how catch
clauses and recover clauses match against them, the built-in hierarchy,
and the codes for failed lookups. It does NOT define error values, the
`raise` statement, or result values; those stay as the book defines them
in "Errors and Recovery".

**A catch matches by ancestry, a comparison matches exactly.** `catch
E_LOOKUP` accepts any code descended from `E_LOOKUP`; `problem.code ==
E_LOOKUP` stays an exact comparison.

**The hierarchy is data.** Links are facts in a relation, changed like
any other facts, subject to write authority. No implementation table
overrides them.

### Data model

```
RELATION ErrorParent(code, parent)   -- stored; the built-in links ship as facts
RELATION ErrorIsA(code, ancestor)    -- derived: reflexive, transitive closure
```

`ErrorIsA` is defined by rules equivalent to:

```
ErrorIsA(code, code)     :- a code appears in ErrorParent, or is raised
ErrorIsA(code, ancestor) :- ErrorParent(code, parent), ErrorIsA(parent, ancestor)
```

The first line is descriptive: a code with no links is its own ancestor
even though no fact mentions it, so the matching algorithm below treats
the reflexive case directly.

**Built-in links.** A world starts with these facts:

| Parent | Children |
|---|---|
| `E_LOOKUP` | `E_INDEX` (list position, relation row), `E_KEY` (map key), `E_NOT_FOUND` |
| `E_TYPE` | `E_INVARG` |
| `E_ARITH` | `E_DIV` |
| `E_TRANSACTION` | `E_CONFLICT`, `E_RETRY` |
| `E_AUTHORITY` | `E_PERMISSION`, `E_CAPABILITY` |

Every other built-in code starts as a root code, including
`E_CARDINALITY`: a missing functional value is a cardinality violation,
not a failed lookup.

### Behavior

**The relations.** An implementation MUST provide `ErrorParent` with
the built-in links, and `ErrorIsA` as its reflexive, transitive closure.
[R-error-relations]

```mica mode=eval @R-error-relations
return [
  ErrorParent(E_KEY, ?parent),
  ErrorParent(E_DIV, ?parent),
  ErrorIsA(E_KEY, E_LOOKUP),
  ErrorIsA(E_KEY, E_KEY),
  ErrorIsA(E_LOOKUP, E_KEY)
]
```

```expect
[[:parent] {[E_LOOKUP]}, [:parent] {[E_ARITH]}, true, true, false]
```

**Catching by ancestry.** A `catch` clause naming code `a` MUST accept a
raised error with code `c` exactly when `ErrorIsA(c, a)` holds, and
`recover` clauses MUST match the same way. Comparing codes with `==`
MUST remain exact. [R-catch-by-ancestry]

```
FUNCTION clause_matches(raised, clause_code) -> Bool:
    -- Step 1: the reflexive case needs no facts
    IF raised == clause_code:
        RETURN true
    -- Step 2: otherwise walk parent links in the task's view
    RETURN ErrorIsA(raised, clause_code) holds in the raising task's view

-- Behavior:
--   - Clauses are still tried in source order; put specific codes first.
--   - A root code matches only itself, as every code does today.
```

```mica mode=eval @R-catch-by-ancestry
let caught = none
let exact = none
try
  raise E_KEY, "missing"
catch E_LOOKUP as problem
  caught = problem.code
  exact = problem.code == E_LOOKUP
end
return [caught, exact]
```

```expect
[E_KEY, false]
```

**Lookup codes.** Reading an absent map key MUST raise `E_KEY`. Reading
an absent list position or relation row MUST raise `E_INDEX`. Both are
`E_LOOKUP` failures, so a handler for any failed indexing catches
`E_LOOKUP`. [R-lookup-codes]

```mica mode=eval @R-lookup-codes
let settings = {:colour -> "amber"}
let codes = []
try
  settings[:size]
catch E_LOOKUP as problem
  codes = [@codes, problem.code]
end
try
  [1, 2][5]
catch E_LOOKUP as problem
  codes = [@codes, problem.code]
end
return codes
```

```expect
[E_KEY, E_INDEX]
```

**Extending the hierarchy.** A program MAY add parent links for any
code, including codes it creates, and a code MAY have more than one
parent. A catch MUST read links in the raising task's view, so links the
task asserted before raising apply even before it commits.
[R-extend-hierarchy]

```mica mode=eval @R-extend-hierarchy
assert ErrorParent(E_UPSTREAM_TIMEOUT, E_UPSTREAM)
assert ErrorParent(E_UPSTREAM_TIMEOUT, E_TIMEOUT)
let handled = []
try
  raise E_UPSTREAM_TIMEOUT
catch E_UPSTREAM
  handled = [@handled, :upstream]
end
try
  raise E_UPSTREAM_TIMEOUT
catch E_TIMEOUT
  handled = [@handled, :timeout]
end
return handled
```

```expect
[:upstream, :timeout]
```

**No cycles.** Asserting a parent link that would make a code its own
proper ancestor MUST fail with `E_INVARG`, and the task's other changes
follow the usual abort rules. A cycle would make every code in it catch
every other, which no program intends. [R-no-error-cycles]

```mica mode=eval @R-no-error-cycles
assert ErrorParent(E_LOOKUP, E_KEY)
```

```expect-error
E_INVARG
```

**Matching needs no read authority.** Matching a catch clause MUST NOT
require the task's actor to hold read authority on `ErrorParent`; the
runtime reads the links on the task's behalf, as dispatch reads
`Delegates`. Querying `ErrorParent` or `ErrorIsA` directly follows the
normal read rules.

### Errors

| Error | Example | Recovery |
|---|---|---|
| `E_INVARG` | `assert ErrorParent(E_LOOKUP, E_KEY)`, closing a cycle | Remove the link; relate the codes in one direction. |
| `E_PERMISSION` | asserting a link without write authority on `ErrorParent` | Obtain a grant, or catch the existing ancestor instead. |

## Out of Scope

**Structured error types with fields per kind.** Python and Common Lisp
attach typed slots to each condition class. Mica errors keep one shape
(code, message, payload). Extension point: a relation keyed by code that
declares the expected payload kind, checked like value-kind annotations.

**Restarts.** Common Lisp conditions can offer restarts to the handler.
Extension point: draft-ndn-language-00's `recover` clauses.

## Alternatives Considered

**Why not keep flat codes, as MOO does?** One code per operation loses
the precise failure; one code per failure forces generic handlers to
list every code. The hierarchy keeps both.

**Why not a fixed hierarchy inside the implementation, as Python's
classes are?** Integrations already create codes with `error_code`, and a
fixed table cannot place them. A fixed table also allows one parent
only.

**Why not encode the hierarchy in names, such as `E_LOOKUP_KEY`?**
Matching by prefix ties the hierarchy to spelling, allows one parent,
and renames every code when the tree changes.

**Why not forbid links on built-in codes, so no program can widen a
library's catch?** Other languages allow the equivalent (reopening or
monkey-patching classes), and write authority already governs who may
change `ErrorParent`. A world administrator may regroup codes for that
world.

**Why not keep `E_INDEX` for missing map keys?** It is the current book
rule and the least churn, but a handler cannot tell a missing key from a
bad list position. Under the hierarchy, code that caught `E_INDEX` for
any lookup catches `E_LOOKUP` instead.

## Security Considerations

A parent link widens every catch clause naming an ancestor. An actor
with write authority on `ErrorParent` can therefore make other code
swallow failures, for example by linking `E_PERMISSION` under a code
that some handler catches and ignores. Write authority on `ErrorParent`
SHOULD be granted only to world administrators. Matching reads links
without the actor's read authority, but reveals only whether a clause
matched, which the actor could observe anyway.

## Compatibility

Programs that catch exact codes keep working: a root code matches only
itself, and every built-in link adds a parent above an existing code, so
no existing clause stops matching.

One book rule changes: a missing map key raises `E_KEY`, not `E_INDEX`.
Code that catches `E_INDEX` expecting map misses changes to `catch
E_KEY` or `catch E_LOOKUP`. At the time of writing (September 2026),
Rust mica raises `E_INDEX` for map keys and omica raises `E_KEY`; neither
relates codes. The book sections to update are "Values" (indexing) and
"Structural Relation Types" (strict indexing).

## References

- R. Daum, *A Relational Theory of Objecthood and Identity* (outline), [revision de5bc29](https://gist.github.com/rdaum/fdfb78358b0d76f778f52adadedcdece/de5bc29005582355ce79f17201fdb8bd0bda4dc2): knowledge stated as relations and derived by rules.
- `mdbook/src/language/errors-and-recovery.md` — error values, `raise`, `catch`, `recover`.
- `mdbook/src/language/values.md` — the current indexing rule.
- Python, *Built-in Exceptions*, <https://docs.python.org/3/library/exceptions.html>: `LookupError` over `IndexError` and `KeyError`.
- K. Pitman, *Condition Handling in the Lisp Language Family*, <https://www.nhplace.com/kent/Papers/Condition-Handling-2001.html>: condition types with multiple parents.
- draft-ndn-authority-00 — write authority over relations.
- draft-ndn-language-00 — `recover` and catch patterns.
