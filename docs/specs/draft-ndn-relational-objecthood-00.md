# draft-ndn-relational-objecthood-00: Relational Objecthood — Handles, Equivalence, Objects as Views, and Claims with History

**Status:** DRAFT
**Category:** Standards-Track
**Corpus:** red (claim history and unnamed handles are not yet specified in the Mica book or implemented)
**Authors:** Norman Nunley, Jr <nnunley@gmail.com>, Claude (drafting agent)

## Abstract

This document states the object model Mica is built around, taken from
Ryan Daum's *A Relational Theory of Objecthood and Identity*, as
requirements any Mica implementation must meet. A handle is a reference
value that carries no meaning of its own; state is propositions in
relations; equivalence and identity are claims made with relations;
objects are views computed over the facts around a handle; delegation
and every inheritance-like default are explicit relations and named
rules; and claims keep their history. It also records, for each body of
prior work the model draws on, which of its semantics Mica adopts and
which it excludes, and why. Requirements are not limited to what
current implementations do; the status appendix says where each stands.

## Motivation

The other drafts in this series were derived by comparing two
implementations. That method finds where they disagree but cannot find
what both lack, and it tends to encode an implementation's accidents as
the contract. The outline states the model the language is for: its
concepts should be requirements whether or not a runtime has them yet.
And because Mica borrows from Codd, SQL, the Third Manifesto, Self,
Smalltalk, OWL, RDF, Datalog and others, a reader needs to know which
of each source's semantics came along and which were left behind, with
the reason, so that later work does not import them by accident.

## Terminology

The key words "MUST", "MUST NOT", "REQUIRED", "SHALL", "SHALL NOT", "SHOULD",
"SHOULD NOT", "RECOMMENDED", "NOT RECOMMENDED", "MAY", and "OPTIONAL" in this
document are to be interpreted as described in BCP 14 (RFC 2119, RFC 8174)
when, and only when, they appear in all capitals, as shown here.

- **handle** — a durable reference value such as `#lamp` (the language calls it an identity value).
- **proposition** — a fact: a tuple in a named relation.
- **fact neighbourhood** — the facts, derived facts, rules, behaviour, authority and history around a handle.
- **object** — a view over a handle's fact neighbourhood under some inquiry.
- **equivalence claim** — a fact relating two handles or values under a purpose and an authority.
- **identity claim** — a claim of sameness or continuity supported by propositions, rules, history and authority.

## Specification

### Handles carry no meaning

A handle MUST carry nothing but its reference: no attributes, class,
kind, layout, or behaviour. Everything known about the thing it names
MUST be propositions that mention it, so a newly made handle has an
empty fact neighbourhood. [R-handle-poor]

```mica mode=eval @R-handle-poor
make_identity(:fresh)
return SubjectFact(#fresh, ?relation, ?tuple)
```

```expect
[:relation, :tuple] {}
```

### Handle equality is not sameness

`==` on handles MUST compare references only. No equivalence claim, rule
or derivation MAY change whether two handles are `==`, and the runtime
MUST NOT merge handles. [R-handle-equality]

```mica mode=eval @R-handle-equality
make_identity(:morning_star)
make_identity(:evening_star)
make_relation(:SameAs, 2)
assert SameAs(#morning_star, #evening_star)
require SameAs(#morning_star, #evening_star)
return #morning_star == #evening_star
```

```expect
false
```

### Equivalence and identity are claims made with relations

Equivalence, coreference, substitutability, representation and
versioning MUST be expressible as ordinary or derived relations, with
the purpose and the asserting authority as arguments when the domain
needs them (`EquivalentFor(a, b, :rendering)`). A program MUST be able
to derive closures of such claims with rules, including recursion, and
to hold several such relations at once without any of them being
privileged. [R-equivalence-claims]

```mica mode=eval @R-equivalence-claims
make_identity(:a)
make_identity(:b)
make_identity(:c)
make_relation(:EquivalentFor, 3)
make_relation(:EquivalentUnder, 3)
assert EquivalentFor(#a, #b, :rendering)
assert EquivalentFor(#b, #c, :rendering)
EquivalentUnder(x, y, p) :- EquivalentFor(x, y, p)
EquivalentUnder(x, z, p) :- EquivalentFor(x, y, p), EquivalentUnder(y, z, p)
require EquivalentUnder(#a, #c, :rendering)
return EquivalentUnder(#a, #c, :billing)
```

```expect
false
```

### Delegation is a relation; defaults are named rules

`Delegates` MUST be an ordinary relation that dispatch matching reads.
The runtime MUST NOT answer a query, a field read, or a dot read for one
handle from facts about another handle it delegates to. Any
inheritance-like default MUST be written as a named derived relation,
so a program can see and change where a value comes from.
[R-delegation-explicit]

```mica mode=eval @R-delegation-explicit
make_identity(:proto)
make_identity(:child)
make_functional_relation(:Lit, 2, [0])
make_relation(:HasLocalLit, 1)
make_relation(:EffectiveLit, 2)
assert Delegates(#child, #proto, 0)
assert Lit(#proto, :on)
EffectiveLit(obj, val) :- Lit(obj, val)
EffectiveLit(obj, val) :- Delegates(obj, proto, _), EffectiveLit(proto, val), not HasLocalLit(obj)
require Lit(#child, ?v) == [:v] {}
return EffectiveLit(#child, ?v)
```

```expect
[:v] {[:on]}
```

No relation, including `Delegates` or any `is-a` relation a world
defines, MUST be treated by the runtime as the ontology; a world MAY
define many parallel taxonomies (`PartOf`, `LocatedIn`, `RoleIn`).

### Objects are views

The runtime MUST provide the fact neighbourhood of a handle as queryable
relations (facts whose subject is the handle; facts that mention it
anywhere), and those views MUST obey the reader's read authority. Tools
that show objects (browsers, outliners, inspectors) MUST build them from
these views rather than from a stored object record. [R-objecthood-views]

```mica mode=eval @R-objecthood-views
make_identity(:lamp)
make_identity(:room)
make_relation(:LocatedIn, 2)
assert LocatedIn(#lamp, #room)
let exactly {relation} = RelationName(?relation, :LocatedIn)
require SubjectFact(#lamp, relation, ?tuple) == [:tuple] {[[#lamp, #room]]}
return MentionedFact(#room, relation, ?position, ?tuple)
```

```expect
[:position, :tuple] {[1, [#lamp, #room]]}
```

Dot syntax (`#lamp.name`) MUST be sugar for a read or write of a
functional relation keyed by the handle; it MUST NOT imply that the
handle owns the value.

### Behaviour is chosen by roles; hiding is authority

Behaviour MUST be selected from the roles of all arguments, with no
receiver privileged, and each applicable method MUST be a handle with
its own facts (draft-ndn-language-00). Hiding MUST be expressed as read
and write authority over relations (draft-ndn-authority-00), not as
facts stored inside a handle.

### Claims keep their history

A program MUST be able to ask, by query, which actor asserted or
retracted a fact and at which committed version, and what a relation
held at an earlier committed version, subject to read authority. The
relation `FactOrigin(relation, tuple, actor, version)` is the proposed
interface; the requirement is the answer, not the name.
[R-claim-history]

```mica mode=eval @R-claim-history
make_identity(:lamp)
make_relation(:Portable, 1)
assert Portable(#lamp)
commit()
let exactly {relation} = RelationName(?relation, :Portable)
return len(FactOrigin(relation, [#lamp], ?actor, ?version))
```

```expect
1
```

### Handles without names

A program SHOULD be able to make a fresh handle with no name, for things
worth referring to but not naming (RDF's blank nodes are the
precedent). Such a handle is written in its numeric form `#12345`.
[R-unnamed-handles]

```mica mode=eval @R-unnamed-handles
let h = make_identity()
require h != make_identity()
return SubjectFact(h, ?relation, ?tuple)
```

```expect
[:relation, :tuple] {}
```

## Semantics adopted and excluded

Each row names a source, what Mica takes from it, what it leaves out,
and why. Reasons cite the outline (§ numbers) where it argues the point.

| Source | Adopted | Excluded | Why |
|---|---|---|---|
| Codd, relational model (1970) | relations as sets of propositions; composable queries; data independence | — | the model's starting point (§4) |
| Codd, RM/T (1979) | surrogates that identify without describing (handles) | entity types built into the model | surrogates give reference without ontology; entity typing would fix a taxonomy (§3, §8) |
| SQL | — | bag semantics, `NULL` and three-valued logic, column order and anonymous or duplicate columns, the query-sublanguage split | Date's critique; absence is a missing fact or an option value; Mica is one language for queries and programs (§5) |
| Date and Darwen, Third Manifesto | equality within a kind; no implicit conversion (draft-ndn-casts-and-literals-00) | type inheritance as the route to substitutability | the outline chooses a relation-first route: substitutability is by roles, predicates and relations, not subtypes (§7) |
| Baker, EGAL | one equality for immutable values | object identity separate from value equality | Mica values are immutable; mutable identity is what the model removes (§6) |
| Moseley and Marks, "Out of the Tar Pit" | essential state as base relations; derived data is not state; indexes and caches are accidental | intensional object identity | the paper's critique of intensional identity is the problem this model answers (§6) |
| Class-based OO | polymorphism, extensibility, interfaces, live inspection (§7) | classes, class inheritance, fields owned by objects, receiver-owned methods | premature classification is accidental complexity (§3, §9) |
| Self | prototype delegation for matching and live authoring | implicit slot search through parents | delegation is a queryable relation; defaults are named rules (§9, §10) |
| Smalltalk | the live image; inspect and change a running world | changes outside transactions | a shared world needs coherent revision at commit (§13) |
| Kay, messaging | late binding; callers independent of implementation | every message routed through a private capsule | knowledge stays in shared relations (§4, §7) |
| Actors and services | message and mailbox communication | private state as the home of knowledge | an actor is still an identity-bearing capsule (§1, §4) |
| Cecil multimethods; predicate dispatch | dispatch on all argument roles and predicates | single-receiver dispatch | no receiver is privileged (§11) |
| OWL | no unique-name assumption; `sameAs`-style claims | `owl:sameAs` merging (full substitutability of everything); the open-world assumption for queries | equivalence is contextual and never merges handles (§8); queries answer from the facts present, and missing knowledge is modelled with relations |
| RDF | named resources as handles; unnamed local identity ([R-unnamed-handles]) | triples as the only shape | relations are n-ary (§12) |
| Datalog | rules, recursion, stratified negation | — | derived knowledge (§6); demand evaluation adds tabling |
| Linda, tuple spaces | shared facts that independent tasks read, write and react to | blocking destructive `in` as the way to consume facts | retraction is an explicit, authorized transaction step |
| Rel | one relational language for programming in the large | — | answers the SQL split (§5) |

## Out of Scope

- The concrete interface for claim history beyond `FactOrigin`
  (bitemporal validity, retention). Extension point: the history
  relations named in [R-claim-history].
- User-defined scalar types with possible representations, as in the
  Third Manifesto. Extension point: a value-types draft.
- A formal calculus of handles, facts, delegation, dispatch and claims,
  which the outline lists as an open question.

## Alternatives Considered

**Why state requirements no implementation meets?** The contract
describes the language, not its current implementations; a status
appendix keeps the gap visible without lowering the bar.

**Why keep handles at all?** Continuity, authority, history and
coordination need a subject (§3); the model constrains what a handle
may mean, not whether it exists.

**Why not merge handles on `SameAs`, as OWL reasoners do?** A merge
makes one claim global and irreversible; claims here are contextual,
authority-bound and revisable (§8).

**Why a closed-world reading of queries?** Rules, negation and
constraints need a definite answer from the facts present. Uncertainty
and disagreement are themselves modelled as facts (`Believes`,
`BelievedBy`), which keeps them queryable (§12).

## Security Considerations

Neighbourhood views and claim history reveal facts, so both MUST obey
read authority ([R-objecthood-views], [R-claim-history]). History that
records actors is personal data in some worlds; retention and access
belong to the authority model.

## References

- R. Daum, *A Relational Theory of Objecthood and Identity* (outline), [revision de5bc29](https://gist.github.com/rdaum/fdfb78358b0d76f778f52adadedcdece/de5bc29005582355ce79f17201fdb8bd0bda4dc2): the model this draft states; § numbers above refer to it.
- The sources and lineage table in `docs/specs/index.md` (rdaum/omica#120), for full citations.
- draft-ndn-language-00, draft-ndn-authority-00, draft-ndn-values-equality-00, draft-ndn-casts-and-literals-00.
- draft-ndn-mica-snippets-00 — the evidence format used here.

## Appendix A: Coverage and gaps (non-normative)

A gap belongs to the Mica specification (the mdbook and these drafts)
when the book does not define the behaviour; it belongs to an
implementation only when the book, or Rust mica as the reference
implementation, already covers it. Differential runs: omica 5a22a77,
Rust mica a433170.

| Requirement | Mica book | Rust mica | omica | Gap |
|---|---|---|---|---|
| R-handle-poor | defined (`values.md`, identities) | meets | meets | none |
| R-handle-equality | defined (`values.md`: equivalence is a modelled relationship) | meets | meets | none |
| R-equivalence-claims | not defined: the book shows a domain claim but not purpose- or authority-bound equivalence or its closure | expressible with user relations and rules | same | **spec**: defined by rdaum/omica#135 (`values.md`) |
| R-delegation-explicit | partly: `Delegates` feeds dispatch matching (`frobs.md`, `verbs-roles-dispatch.md`); that reads never follow it, and that defaults are named rules, is unwritten | behaves so; dot read raises `E_CARDINALITY` | behaves so; dot read raises `E_KEY` | **spec**: defined by rdaum/omica#135 (`verbs-roles-dispatch.md`); **omica**: dot read should raise `E_CARDINALITY` as the book says (`keyed-relations.md`), not `E_KEY` |
| R-objecthood-views | defined (`runtime/catalogue-and-introspection.md`) | meets | returns no rows on main | **omica**: fixed by rdaum/omica#134 |
| R-claim-history | not defined (buffer text provenance only) | absent | absent | **spec**: needs design (interface, retention, authority) |
| R-unnamed-handles | not defined: the numeric `#12345` literal form exists, but no way to make such a handle | absent | absent | **spec**: needs design |
