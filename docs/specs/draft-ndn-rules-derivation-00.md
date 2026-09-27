# draft-ndn-rules-derivation-00: Rules and Derivation

**Status:** DRAFT

**Corpus:** red (spec-first; evidence is the acceptance criteria)

**Category:** Standards-Track

**Authors:** Norman Nunley, Jr. <nnunley@gmail.com>


## Abstract

This RFC specifies rule safety validation, installation mechanics, evaluation strategies (stratified and semi-naive), visibility guarantees, and that no relation declares how it is evaluated.


## Motivation

Mica is a database, a programming language, and a runtime; the live world is the source of truth. Rules transform this world by deriving new facts.

Rust mica defers safety checks until first read, failing on queries that looked safe. omica validates at install and rejects unsafe rules immediately. This RFC settles safety timing, visibility, and the evaluation-strategy boundary.


## Terminology

The key words "MUST", "MUST NOT", "REQUIRED", "SHALL", "SHALL NOT", "SHOULD",
"SHOULD NOT", "RECOMMENDED", "NOT RECOMMENDED", "MAY", and "OPTIONAL" in this
document are to be interpreted as described in BCP 14 (RFC 2119, RFC 8174)
when, and only when, they appear in all capitals, as shown here.

- **rule** — A Datalog-style declaration: head relation :- body conditions. Asserts head tuples when all body conditions hold.
- **derived relation** — A relation populated by active rules; contains no directly asserted facts.
- **extensional fact** — A tuple directly asserted into a relation (not derived).
- **derived fact** — A tuple produced by evaluating a rule body.
- **stratum** — A level in the rule dependency graph; stratification ensures negation depends only on lower strata, preventing circular negation.
- **semi-naive evaluation** — Fixpoint evaluation that re-evaluates only rules affected by newly derived tuples (delta), not all rules with all tuples.
- **snapshot** — An immutable point-in-time view of the relation state, including both extensional and derived facts.
- **evaluation strategy** — how an engine computes a derived relation (materialized, maintained, or on demand); it never changes the answer.


## Specification

**Live installation.** Rules are installed, validated, derived, and published atomically while readers at earlier snapshots see their consistent view uninterrupted.


### Rule Validation at Installation

The system MUST reject any rule that violates safety constraints when the rule is installed, before any read, by raising `E_RULE` in the installing task. (`E_RULE` is a proposed code; the book says such rules are rejected but names no error.) [R-install-time-safety]

```mica mode=eval @R-install-time-safety
make_relation(:Person, 1)
make_relation(:Out, 1)
assert Person(:alice)
Out(x) :- Person(:alice)
return Out(?x)
```

```expect-error
E_RULE
```

The system MUST reject a rule if any variable appears in its head but is not bound by any body atom. [R-unbound-head-reject]

```mica mode=eval @R-unbound-head-reject
make_relation(:Person, 1)
make_relation(:Named, 2)
Named(x, y) :- Person(x)
return Named(?x, ?y)
```

```expect-error
E_RULE
```

The system MUST reject a rule if a negated atom contains an unbound variable or if a comparison guard references an unbound operand. [R-unsafe-negation-guard]

```mica mode=eval @R-unsafe-negation-guard
make_relation(:Item, 1)
make_relation(:Reserved, 1)
make_relation(:Free, 1)
Free(y) :- Item(y), not Reserved(x)
return Free(?y)
```

```expect-error
E_RULE
```

The system MUST reject a rule set if negation over a relation R would create a cycle in the rule dependency graph (stratification failure). [R-stratification]

```mica mode=eval @R-stratification
make_relation(:P, 1)
make_relation(:Q, 1)
P(x) :- Q(x)
Q(x) :- P(x), not P(x)
return P(?x)
```

```expect-error
E_RULE
```


**Holes in rule bodies.** Each `_` in a positive body atom MUST act as its own anonymous variable, matching any value independently of every other `_`. [R-rule-body-hole]

```mica mode=eval @R-rule-body-hole
make_relation(:R, 3)
make_relation(:P, 1)
assert R(:a, 1, 2)
assert R(:b, 3, 3)
P(x) :- R(x, _, _)
return P(?x)
```

```expect
[:x] {[:a], [:b]}
```

### Rule Installation and Lifecycle

When a rule is installed, the system MUST atomically publish a new snapshot containing the rule's effects. [R-atomic-install]

Validate, acquire lock, fork snapshot, add rule, compute relations, CAS new snapshot as current. Readers at earlier snapshots continue uninterrupted.

```mica mode=eval @R-atomic-install
make_relation(:E, 2)
make_relation(:P, 2)
assert E(:a, :b)
P(x, y) :- E(x, y)
return P(?x, ?y)
```

```expect
[:x, :y] {[:a, :b]}
```

A disabled rule MUST be able to be enabled again with `enable_rule(rule)`, restoring its derivations atomically. (`enable_rule` is proposed; the book defines only `disable_rule`.) [R-enable-disable-retrigger]

```mica mode=eval @R-enable-disable-retrigger
make_relation(:E, 2)
make_relation(:P, 2)
assert E(:a, :b)
P(x, y) :- E(x, y)
let exactly {p} = RelationName(?p, :P)
let exactly {rule} = RuleHead(?rule, p)
disable_rule(rule)
commit()
require P(?x, ?y) == [:x, :y] {}
enable_rule(rule)
commit()
return P(?x, ?y)
```

```expect
[:x, :y] {[:a, :b]}
```

The system MUST support disabling a rule (setting its active flag to false) without removing it from the catalog. Disabling and enabling take effect when the task commits; before that, the task's reads MUST NOT mix the old and new state (omica today reports `ActiveRule` as false while still deriving from the rule; Rust mica shows both unchanged until commit). [R-disable-without-removal]

Disabled rule facts are removed; rule definition persists.

```mica mode=eval @R-disable-without-removal
make_relation(:Active, 1)
make_relation(:P, 1)
assert Active(:a)
P(x) :- Active(x)
let exactly {p} = RelationName(?p, :P)
let exactly {rule} = RuleHead(?rule, p)
disable_rule(rule)
commit()
require RuleHead(rule, p)
require P(?x) == [:x] {}
return ActiveRule(rule, ?active)
```

```expect
[:active] {[false]}
```

Facts derived only through disabled rules MUST no longer appear; facts still derived by active rules MUST remain. [R-disable-removes-facts]

```mica mode=eval @R-disable-removes-facts
make_relation(:A, 1)
make_relation(:B, 1)
make_relation(:P, 1)
assert A(:from_a)
assert B(:from_b)
P(x) :- A(x)
P(x) :- B(x)
let exactly {p} = RelationName(?p, :P)
let exactly {rule} = natural_join(RuleHead(?rule, p), RuleSource(?rule, "P(x) :- A(x)"))
disable_rule(rule)
commit()
return P(?x)
```

```expect
[:x] {[:from_b]}
```



### Evaluation Strategies

Rules MUST be evaluated in stratum order: a relation that another rule negates is complete before that negation is checked, and a later assertion can remove a conclusion. [R-stratified-eval]

```mica mode=eval @R-stratified-eval
make_relation(:Base, 1)
make_relation(:Derived, 1)
make_relation(:Missing, 1)
assert Base(:a)
assert Base(:b)
Derived(x) :- Base(x), not Missing(x)
assert Missing(:b)
return Derived(?x)
```

```expect
[:x] {[:a]}
```

Recursive rules MUST yield their least fixpoint; how an engine reaches it (semi-naive iteration, incremental maintenance, tabling) is its choice (draft-ndn-demand-evaluation-00). [R-semi-naive]

```mica mode=eval @R-semi-naive
make_relation(:E, 2)
make_relation(:P, 2)
assert E(:a, :b)
assert E(:b, :c)
P(x, y) :- E(x, y)
P(x, z) :- E(x, y), P(y, z)
return P(?x, ?y)
```

```expect
[:x, :y] {[:a, :b], [:a, :c], [:b, :c]}
```


### Derived Relation Visibility

Every reader (query, transaction, rule evaluation) MUST see a consistent union of extensional and derived facts at the snapshot it observes. [R-consistent-union]

No duplicates; no partial derivation states visible.

```mica mode=eval @R-consistent-union
make_relation(:Base, 1)
make_relation(:Der, 1)
assert Base(:a)
Der(x) :- Base(x)
assert Base(:b)
return [Base(?x), Der(?x)]
```

```expect
[[:x] {[:a], [:b]}, [:x] {[:a], [:b]}]
```

When a task reads a derived relation after writing to relations its rules depend on, the system MUST answer from the task's combined view (base snapshot plus its writes), and a later write in the same task MUST be reflected in the next read. [R-txn-read-derived]

```mica mode=eval @R-txn-read-derived
make_relation(:R, 1)
make_relation(:D, 1)
D(x) :- R(x)
assert R(:a)
require D(?x) == [:x] {[:a]}
assert R(:b)
return D(?x)
```

```expect
[:x] {[:a], [:b]}
```


### Derived State Persistence

The system MUST store derived facts separately from extensional facts and MUST NOT persist derived facts as extensional facts. On restart, re-derive from active rules; never restore directly from checkpoint. [R-never-persist-derived]

<!-- evidence: @R-never-persist-derived -->
| Scenario | Behavior |
|----------|----------|
| Rule installed, derived facts created, checkpoint written | Derived facts stored separately; not in checkpoint |
| Process restart | All derived relations recomputed from restored extensional facts and active rules |
| Rule disabled, checkpoint written | Disabled rule's facts are gone; checkpoint contains only extensional facts |
| Rule changed, process restart | New rule applied to extensional facts; old derived facts never restored |


### Incremental Maintenance

The system MUST maintain the guarantee that every reader sees all facts derived by the active rule set at the snapshot's version, whether derived eagerly at every commit or computed on demand when queried. [R-incremental-guarantee]

Implementations MAY re-derive eagerly, maintain incrementally, or hybrid; reader-visible result MUST be identical.

<!-- evidence: @R-incremental-guarantee -->
| Reader view | Guarantee |
|-------------|-----------|
| Query derived relation R at snapshot v | Reader sees all facts R produces under active rules at v |
| Concurrent reader at older snapshot v-1 | Sees all facts R produces under active rules at v-1; unaffected by v's derivation |
| Reader at v after eager re-derivation | Sees complete fixpoint of all active rules over current extensional facts |
| Reader at v after on-demand computation | Sees complete fixpoint of queried rules; uncomputed rules' derivations not visible unless queried |


### Evaluation strategy

A relation carries no declaration of how it is evaluated. Whether an
engine keeps a derived relation materialized, maintains it
incrementally, or computes it on demand with tabling is its choice, and
the answer is the same least fixpoint either way; draft-ndn-demand-evaluation-00
states that contract.


## Out of Scope

Query planning, tabling, computed relations, and functional key conflicts in derived relations are deferred.


## Alternatives Considered

Lazy validation surprises users; eager fails fast. Eager evaluation doesn't scale to large rule sets; demand evaluation enables lazy evaluation only of queried relations.


## Security Considerations

Rule installation is subject to authority checks owned by RFC #118. Derived relations inherit defining rule authority.


## Compatibility

Mica is a live database. Every world starts fresh; rules are installed live with snapshot consistency for readers.


## References

- R. Daum, *A Relational Theory of Objecthood and Identity* (outline), [revision de5bc29](https://gist.github.com/rdaum/fdfb78358b0d76f778f52adadedcdece/de5bc29005582355ce79f17201fdb8bd0bda4dc2): the series' framing: handles, equivalence, objecthood and identity claims.
- S. Ceri, G. Gottlob, L. Tanca, "What You Always Wanted to Know About Datalog," IEEE TKDE 1(1), 1989.
- B. Moseley and P. Marks, "Out of the Tar Pit," 2006: derived data is not state.
- RFC 2119, RFC 8174: BCP 14 keywords
- Datalog semantics: Ullman, "Database and Knowledge-Base Systems" (foundational reference for stratified Datalog)
- Incremental maintenance: omica `docs/incremental-maintenance-design.md`; stage 1 in rdaum/omica#125
- Rule authority and program installation: rdaum/omica#118
- Evaluation strategy, including demand evaluation with tabling: draft-ndn-demand-evaluation-00 (rdaum/omica#136)


## Appendix A: Relation to Rust mica

| Behavior | Rust | omica today | This RFC | Class |
|----------|------|-------------|----------|-------|
| Unbound head variable validation | Lazy: install succeeds, first read fails with `UnboundHeadVariable` error | Eager: install fails with `Unbound_Head_Variable` error | Eager validation at install time (Rust behavior changes to match omica) | Improvement |
| `_` holes in positive rule bodies | rejected at parse at 2bbceb0; independent anonymous variables at a433170 | independent anonymous variables | independent anonymous variables | Parity (at a433170) |
| Stratification validation | At install time, rejects unstratified rules | At install time, rejects unstratified rules | At install time (no change) | Parity |
| Negation and guard safety (unbound terms) | Unsafe negation installs, then the first read fails with `E_DB UnsafeNegation`; a comparison on a query variable is rejected at parse | Rejected at install: `Unsafe_Negation`, `Unsafe_Guard` | Rejected at install ([R-unsafe-negation-guard]) | Improvement (differential run D-022) |
| Guard safety check (unbound operands) | At evaluation time, fails | At evaluation time, fails | At evaluation time (no change) | Parity |
| Non-recursive evaluation (stratified) | Single pass through strata | Single pass or fixpoint with 1 iteration | Stratified single-pass semantics (no change) | Parity |
| Recursive evaluation (fixpoint) | Semi-naive: seed + delta rounds until convergence | Semi-naive: seed + delta rounds until convergence | Semi-naive fixpoint (no change) | Parity |
| Join equality semantics | Canonical Value equality (int(1) ≠ float(1.0)) | Canonical Value equality (int(1) ≠ float(1.0)) | Canonical equality in joins; numeric equality in guards (no change) | Parity |
| Derived relation visibility | Union of extensional + derived, consistent snapshot | Union of extensional + derived, consistent snapshot | Union with consistency guarantee (no change) | Parity |
| Transaction read-your-writes for derived | Evaluates rule over txn view, caches result | Evaluates rule over txn view, caches result | Consistent semantics (no change) | Parity |
| Incremental maintenance | Lazy differential: weighted deltas, maintained after first read | Full fixpoint recompute on every commit (Stage 1: blocks + COW) | Observable guarantee only; algorithm deferred to incremental-maintenance design | Gap → Scheduled |
| Derived state persistence | Separate from extensional; fingerprint-based recovery (planned) | Separate from extensional; always re-derived | Never persist derived facts; re-derive on restart (no change) | Parity |
| Rule enable/disable | Supported; recomputes derived relations | Supported; recomputes derived relations | Supported (no change) | Parity |
| Evaluation strategy | lazy differential maintenance after first read | full recompute per commit | undeclared; any strategy, same answer (draft-ndn-demand-evaluation-00) | Parity (answers) |
| Cache invalidation strategy | Explicit on rule install | Implicit (no persistent cache) | Not specified; implementations may vary | Implementation-defined |
| Rejection error code (`E_RULE`, proposed) | unsafe rules fail on first read with `E_DB` | rejected at load with a message, no code | raised in the installing task | **spec**: the book says rejected but names no code |
| `enable_rule` (proposed) | only `disable_rule` | has `enable_rule` | defined | **spec**: the book defines only `disable_rule` |
| Rule toggles before commit | both `ActiveRule` and answers unchanged until commit | `ActiveRule` changes, answers do not | no mixed state before commit | **omica**: reads disagree within the task |
