# draft-ndn-demand-evaluation-00: Evaluation Strategy — Eager, On Demand, and Tabled

**Status:** DRAFT
**Category:** Standards-Track
**Authors:** Norman Nunley, Jr <nnunley@gmail.com>, Claude (drafting agent)

## Abstract

A Mica rule defines a derived relation by its least fixpoint. How an
engine computes that relation (keeping it materialized, maintaining it
incrementally, or computing only what a query asks for, with tabling
for recursion) is an evaluation strategy, and a strategy never changes
the answer. This document states that contract: every strategy yields
the same answers, an engine may evaluate any relation on demand,
recursion terminates under every strategy, negation follows
stratification whatever the strategy, a watched relation is kept
current, and hints cannot change results. No relation declares its
strategy.

## Motivation

Backward chaining, with tabling that handles recursion, was chosen as a
capability Mica should have. An earlier version of this draft made it a
mode each relation declares. Other Datalog systems do not ask for that:
bottom-up engines such as Soufflé apply magic-set rewriting as an
optimization that preserves answers, and the Prolog systems that do
declare tabling (`:- table p/2.` in XSB and SWI-Prolog) need the
declaration because their default top-down resolution can fail to
terminate. Mica's default is bottom-up, which always terminates for
Datalog, so a declaration would be a knob with no meaning. What a
program can observe, and what this draft fixes, is the answer, not the
schedule.

## Terminology

The key words "MUST", "MUST NOT", "REQUIRED", "SHALL", "SHALL NOT", "SHOULD",
"SHOULD NOT", "RECOMMENDED", "NOT RECOMMENDED", "MAY", and "OPTIONAL" in this
document are to be interpreted as described in BCP 14 (RFC 2119, RFC 8174)
when, and only when, they appear in all capitals, as shown here.

- **evaluation strategy** — how an engine computes a derived relation: materialized at commit, maintained incrementally, or computed on demand for a query's bound arguments.
- **tabling** — remembering subgoal answers during on-demand evaluation so recursion terminates (SLG resolution).
- **watched relation** — a relation a subscription is following for changes.

## Specification

### Answers do not depend on strategy

For every derived relation and every query, an engine MUST return the
least fixpoint of the active rules over the facts visible to the
reader, under stratified negation, whatever strategy it uses, and every
implementation MUST return the same answer. No relation declares a
strategy. [R-eval-independence]

```mica mode=eval @R-eval-independence
make_relation(:Parent, 2)
make_relation(:Ancestor, 2)
assert Parent(:ann, :bob)
assert Parent(:bob, :cid)
assert Parent(:cid, :dee)
Ancestor(x, y) :- Parent(x, y)
Ancestor(x, z) :- Parent(x, y), Ancestor(y, z)
require Ancestor(:ann, ?who) == [:who] {[:bob], [:cid], [:dee]}
require Ancestor(?who, :dee) == [:who] {[:ann], [:bob], [:cid]}
return Ancestor(:bob, :dee)
```

```expect
true
```

### On-demand evaluation is permitted; recursion terminates

An engine MAY compute a derived relation only for the arguments a query
binds, by magic-set rewriting, tabling, or any other means that
satisfies [R-eval-independence]. Evaluation MUST terminate for every
program the rules accept, including left recursion and cycles in the
facts. [R-demand-terminates]

```mica mode=eval @R-demand-terminates
make_relation(:Edge, 2)
make_relation(:Path, 2)
assert Edge(:a, :b)
assert Edge(:b, :c)
assert Edge(:c, :a)
assert Edge(:d, :d)
Path(x, z) :- Path(x, y), Edge(y, z)
Path(x, y) :- Edge(x, y)
require Path(:a, ?to) == [:to] {[:a], [:b], [:c]}
return Path(?from, :a)
```

```expect
[:from] {[:a], [:b], [:c]}
```

### Negation follows stratification under every strategy

Negation over any derived relation MUST mean "not derivable in the
reader's view" and MUST be evaluated in stratum order whatever strategy
computes either relation. A program the stratification check accepts
MUST NOT be rejected, and MUST NOT give a different answer, because an
engine evaluates part of it on demand. [R-negation-any-strategy]

```mica mode=eval @R-negation-any-strategy
make_relation(:Edge, 2)
make_relation(:Path, 2)
make_relation(:Node, 1)
make_relation(:Unreached, 1)
assert Edge(:a, :b)
assert Edge(:b, :a)
assert Node(:a)
assert Node(:z)
Path(x, y) :- Edge(x, y)
Path(x, z) :- Edge(x, y), Path(y, z)
Unreached(n) :- Node(n), not Path(:a, n)
return Unreached(?n)
```

```expect
[:n] {[:z]}
```

### Answers reflect the reader's current view

A query MUST see the facts of the reader's view, including writes and
retractions earlier in the same task, and every committed rule or
authority change: an engine that keeps tables or materialized answers
MUST NOT return one computed before such a change. Rule changes take
effect at commit (draft-ndn-rules-derivation-00). [R-current-view]

```mica mode=eval @R-current-view
make_relation(:Parent, 2)
make_relation(:Ancestor, 2)
assert Parent(:ann, :bob)
Ancestor(x, y) :- Parent(x, y)
Ancestor(x, z) :- Parent(x, y), Ancestor(y, z)
require Ancestor(:ann, ?who) == [:who] {[:bob]}
assert Parent(:bob, :cid)
require Ancestor(:ann, ?who) == [:who] {[:bob], [:cid]}
retract Parent(:ann, :bob)
return Ancestor(:ann, ?who)
```

```expect
[:who] {}
```

### Watched relations stay current; hints are inert

While a subscription watches a derived relation, the engine MUST
deliver its changes as they commit, as if the relation were kept
materialized, whatever strategy it uses otherwise. An implementation
MAY accept evaluation hints (for example, which relations to rewrite for
demand); a hint MUST NOT change any answer, error, or delivered change.
[R-watched-and-hints]

<!-- evidence: @R-watched-and-hints -->
| Situation | Required behaviour |
|---|---|
| a subscription watches `Ancestor`; a commit adds `Parent(:dee, :eve)` | the subscriber receives the new `Ancestor` rows in that commit's change |
| the subscription closes | on-demand computation of `Ancestor` is permitted again |
| the same program with and without a hint | identical answers, errors, and delivered changes |

## Out of Scope

- A syntax for evaluation hints. Extension point: a pragma form, if one
  is ever needed; it would be bound by [R-watched-and-hints].
- Well-founded semantics for programs the stratification check rejects.
  Extension point: a later draft replacing stratification.
- Persisting tabled answers. Derived results are not state
  (draft-ndn-rules-derivation-00); an engine may cache them only in ways
  that satisfy [R-current-view].

## Alternatives Considered

**Why not declare demand per relation, as the earlier draft did?** It
changes nothing a program can observe, adds syntax, and forces a choice
the engine is better placed to make from the query's bound arguments.

**Why not reject negation over demand-evaluated relations?** The earlier
draft did, to simplify an implementation. Stratification already orders
the evaluation; rejecting accepted programs because of an engine's
internal choice would make the answer depend on strategy.

**Why keep tabling in the contract at all?** Termination on recursion is
the observable reason tabling exists; the requirement states the
guarantee and leaves the technique to the engine.

## Security Considerations

On-demand evaluation reads the same relations eager evaluation would,
under the reader's authority. A cached or tabled answer computed under
one authority MUST NOT be returned to a reader with different read
rights ([R-current-view] covers authority changes).

## References

- R. Daum, *A Relational Theory of Objecthood and Identity* (outline), [revision de5bc29](https://gist.github.com/rdaum/fdfb78358b0d76f778f52adadedcdece/de5bc29005582355ce79f17201fdb8bd0bda4dc2): queries as repeatable acts over propositions.
- W. Chen and D. S. Warren, "Tabled Evaluation with Delaying for General Logic Programs," *JACM* 43(1), 1996: SLG resolution.
- F. Bancilhon, D. Maier, Y. Sagiv, J. Ullman, "Magic Sets and Other Strange Ways to Implement Logic Programs," PODS 1986.
- S. Ceri, G. Gottlob, L. Tanca, "What You Always Wanted to Know About Datalog," *IEEE TKDE* 1(1), 1989.
- draft-ndn-rules-derivation-00 — rules, safety, stratification, visibility.
- draft-ndn-mica-snippets-00 — the evidence format.

## Appendix A: Coverage (non-normative)

| Requirement | Mica book | Rust mica | omica |
|---|---|---|---|
| R-eval-independence | `rules.md` (least fixpoint; this draft's PR adds the strategy rule) | meets (lazy differential maintenance) | meets (recompute per commit) |
| R-demand-terminates | `rules.md` recursion | meets bottom-up; no demand evaluation | same |
| R-negation-any-strategy | `rules.md` stratified negation | meets | meets |
| R-current-view | `rules.md` | meets | meets |
| R-watched-and-hints | not in the book | subscriptions maintained | change feed; no hints |

On-demand evaluation itself exists in neither implementation. Because
it cannot change an answer, that is an optimization still to build, not
a specification gap.
