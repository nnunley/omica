# draft-ndn-mica-snippets-00: Mica Snippets — Modes, Expected Values and Errors, Implementation Variants

**Status:** DRAFT
**Category:** Standards-Track
**Authors:** Norman Nunley, Jr <nnunley@gmail.com>, Claude (drafting agent)

## Abstract

Mica documentation and Mica specifications show code in fenced `mica`
blocks. This document profiles draft-ndn-snippet-attributes-00 for that
type: what `mode=parse`, `mode=eval` and `mode=filein` run, how an
`expect` block's Mica expression is compared with the result, what an
`expect-error` block asserts, and which profile facts select variants
between implementations. The same rules drive the Mica book's examples
and the evidence of Mica RFCs, so one harness checks both and any Mica
implementation, including a self-hosted one, can run the same cases.

## Motivation

Rust mica runs its book's examples as tests, and omica runs the same
book through `tools/bookcheck` (rdaum/omica#127). Those examples only
state that a block completes. A language contract needs more: the value
a block returns, the error it raises, and, while two implementations
converge, which cases hold for which one. Printed values cannot carry
that contract, because implementations print the same value differently
(omica prints `42` and `{:k -> 1}` where Rust mica prints `4.2e1` and
`[:k: 1]`). Expected results therefore have to be Mica values, compared
by Mica's own canonical equality.

## Terminology

The key words "MUST", "MUST NOT", "REQUIRED", "SHALL", "SHALL NOT", "SHOULD",
"SHOULD NOT", "RECOMMENDED", "NOT RECOMMENDED", "MAY", and "OPTIONAL" in this
document are to be interpreted as described in BCP 14 (RFC 2119, RFC 8174)
when, and only when, they appear in all capitals, as shown here.

- **Mica block** — a fenced block whose info string has type `mica`.
- **result** — the value a block's top-level code returns, or the error it aborts with.
- **canonical equality** — Mica's storage and join equality: values of different kinds are never equal, so `1` does not equal `1.0`.
- **harness** — a program that runs Mica blocks against one implementation (for omica, `tools/bookcheck`).

## Specification

### Modes

A Mica block's `mode=` is `parse`, `eval`, or `filein`; with none it is
`parse`. The legacy flags `mica,eval` and `mica,filein` MUST be read as
`mode=eval` and `mode=filein`. A harness MUST parse every Mica block. It
MUST run an `eval` block as the source of one task in a fresh world, and
a `filein` block as a unit filed into a fresh world; in both, the
block's top-level code MUST complete unless an `expect-error` block
follows. [R-mica-modes]

```mica mode=eval @R-mica-modes
let total = 0
for n in [1, 2, 3]
  total = total + n
end
require total == 6
```

### Expected values

An `expect` block after a Mica block holds one Mica expression. The
harness MUST evaluate it in the same world after the block completes and
MUST pass the block only when the block's result is canonically equal to
the expression's value. [R-mica-expect]

```mica mode=eval @R-mica-expect
return [len("héllo"), 7 % 2]
```

```expect
[5, 1]
```

Canonical equality is strict about kinds: an integer result MUST NOT
satisfy a float expectation, and a list MUST NOT satisfy a relation.
Write the expected value in the kind the language returns. [R-mica-expect-kinds]

<!-- evidence: @R-mica-expect-kinds template=mica-kind-case -->
| input | expect |
|---|---|
| `1 + 2` | `3` |
| `7.0 / 2.0` | `3.5` |
| `:ready` | `:ready` |
| `"a" == "a"` | `true` |

```mica id=mica-kind-case mode=eval
return {{input}}
```

### Expected errors

An `expect-error` block holds one error code. The harness MUST pass the
block only when its task aborts with that code; completing, or aborting
with another code, fails. [R-mica-expect-error]

```mica mode=eval @R-mica-expect-error
return [1, 2, 3][10]
```

```expect-error
E_INDEX
```

### Implementation variants

The profile fact `impl` names the implementation under test (`omica`,
`rust`, or another). While implementations disagree on a case, a
document MAY give one block per implementation with `when=impl:NAME`;
a harness MUST report a block whose condition does not hold as N/A.
A requirement MUST keep at least one block without a `when=` condition
once implementations agree, so the contract does not depend on which
implementation runs it. [R-mica-variants]

```mica mode=eval when=impl:omica @R-mica-variants
return 1
```

```mica mode=eval when=impl:rust @R-mica-variants
return 1
```

### Harness contract

| Input | Harness behavior |
|---|---|
| `mica` or `mica mode=parse` | parse; any parse error fails |
| `mode=eval` / `mica,eval` | run as one task in a fresh world |
| `mode=filein` / `mica,filein` | file in as a unit in a fresh world |
| following `expect` | evaluate the expression in that world; compare canonically |
| following `expect-error` | require an abort with that error code |
| `when=` not holding | report N/A |
| tangled block (rfc-tangle) | read `.attrs`, `.expect`, `.expect-error` sidecars |

For omica the harness is `tools/bookcheck`: `bookcheck <book-dir>` for a
book and `bookcheck --block FILE` for one tangled block, used by the
`mica` adapter in `docs/specs/adapters`. The series profile
`docs/specs/profile` sets `impl=omica`.

## Out of Scope

- Matching printed output. Printing differs between implementations;
  extension point: an `output` sidecar kind, if a printing contract is
  ever specified.
- Error messages and error values beyond the code. Extension point: an
  `expect-error` body with more lines (message, value) under a later
  revision.
- Multi-world scenarios (two sessions, a restart between blocks).
  Extension point: a `mode=` value for scripted sequences.

## Alternatives Considered

**Why compare values instead of printed text?** Printed forms differ
between implementations for the same value, so text would encode one
implementation's printer into the contract.

**Why canonical equality instead of `==`?** The language's `==` treats
`1 == 1.0` as true, so it cannot tell whether an implementation returned
the right kind. Canonical equality is the one both implementations
already use for storage and joins.

**Why error codes only?** Messages are prose each implementation words
differently; the code is what programs catch and what the language
documents.

## Security Considerations

Mica blocks run with the harness's authority in a fresh world. The
`mica` adapter runs under the RFC tooling's sandbox providers
(draft-ndn-sandbox-providers-00); blocks that reach the network or the
file system through builtins inherit whatever those providers allow.

## References

- draft-ndn-snippet-attributes-00 (llm-rfc-skill) — info strings, sidecars, templates, `when=`.
- rdaum/omica#127 — `tools/bookcheck` and the synced language chapters.
- Rust mica `crates/runtime/tests/book_examples.rs` — the book harness this profile extends.
- `mdbook/src/language/values.md` — canonical equality and error codes.
