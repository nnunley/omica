# omica specifications

## Introduction

These documents specify Mica: a relation-based, persistent, deductive
programming system with both object and relational aspects. Their
framing comes from Ryan Daum's *A Relational Theory of Objecthood and
Identity* ([outline, revision de5bc29](https://gist.github.com/rdaum/fdfb78358b0d76f778f52adadedcdece/de5bc29005582355ce79f17201fdb8bd0bda4dc2)), which is the introduction
to read first.

Its thesis: a durable reference value is useful but ontologically poor.
A handle lets facts, transactions, rules, permissions and histories
coordinate reference, but it does not decide what a thing is, which
attributes belong to it, which behaviours it owns, or which taxonomy
gives it meaning. State is a set of propositions in named relations;
sameness, equivalence and role are claims defended by relations and
queries; and an object is a view computed over the facts around a
handle. The outline keeps four notions apart, and so do these
specifications:

1. **Handle equality**: equality of durable reference values (`#lamp == #lamp`).
2. **Equivalence**: a relation, often contextual and authority-bound (`SameAs(a, b)`).
3. **Objecthood**: a computed view or neighbourhood around a reference.
4. **Identity**: a defended claim of continuity or sameness, not the mere existence of a handle.

How the series carries that out:

| Outline theme | Where it is specified |
|---|---|
| handles as reference values; state as propositions | Values and Equality; Declarations and the Catalogue |
| knowledge derived and reformulated by query | Rules and Derivation; Demand-Driven Evaluation |
| delegation and role-based behaviour, not owned methods | Language (verbs, dispatch) |
| encapsulation as query and write policy | Authority and Grants |
| live revision made coherent by transactions | Transactions, Persistence, and the Change Log; Units |
| a shared world reached by people and services | Hosts and the Host Protocol |

Numbered RFCs for omica. A draft is named `draft-<author>-<slug>-NN.md` and
gets a number only when it is published; the next number is taken from the
table below, and the entry is added in the publishing commit.

## Published

| Number | Title | Category | Status |
|---|---|---|---|

## Drafts

| Draft | Title | Category |
|---|---|---|
| [draft-ndn-values-equality-00](draft-ndn-values-equality-00.md) | Values and Equality | Standards-Track |
| [draft-ndn-declarations-catalogue-00](draft-ndn-declarations-catalogue-00.md) | Declarations and the Catalogue | Standards-Track |
| [draft-ndn-rules-derivation-00](draft-ndn-rules-derivation-00.md) | Rules and Derivation | Standards-Track |
| [draft-ndn-demand-evaluation-00](draft-ndn-demand-evaluation-00.md) | Demand-Driven Evaluation (Backward Chaining) | Experimental |
| [draft-ndn-transactions-changelog-00](draft-ndn-transactions-changelog-00.md) | Transactions, Persistence, and the Change Log | Standards-Track |
| [draft-ndn-units-00](draft-ndn-units-00.md) | Units: Filein, Fileout and Unit State | Standards-Track |
| [draft-ndn-language-00](draft-ndn-language-00.md) | Language: Recover, Exhaustive Match, Catch Patterns and Dispatch | Standards-Track |
| [draft-ndn-authority-00](draft-ndn-authority-00.md) | Authority and Grants | Standards-Track |
| [draft-ndn-source-git-00](draft-ndn-source-git-00.md) | Source Host Git Relations | Standards-Track |
| [draft-ndn-hosts-00](draft-ndn-hosts-00.md) | Hosts and the Host Protocol | Informational |
