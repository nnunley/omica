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

The outline's model is stated as requirements in
draft-ndn-relational-objecthood-00 (rdaum/omica#133), which also records
which semantics from each source Mica adopts or excludes, and why. The
series is not limited to what current implementations do.

How the series carries that out:

| Outline theme | Where it is specified |
|---|---|
| handles as reference values; state as propositions | Values and Equality; Declarations and the Catalogue |
| knowledge derived and reformulated by query | Rules and Derivation; Demand-Driven Evaluation |
| delegation and role-based behaviour, not owned methods | Language (verbs, dispatch) |
| encapsulation as query and write policy | Authority and Grants |
| live revision made coherent by transactions | Transactions, Persistence, and the Change Log; Units |
| a shared world reached by people and services | Hosts and the Host Protocol |

## Sources and lineage

The outline's argument rests on the works below; the README's
Background section adds Mica's own lineage. Each row says what the
series takes from the work and where. Works marked *(supplied)* are
named in the outline or README without a citation; the citation is
added here.

| Work | What the series takes from it | Applied in |
|---|---|---|
| E. F. Codd, "A Relational Model of Data for Large Shared Data Banks," *CACM* 13(6), 1970 | knowledge as relations; data independence | Declarations; Rules |
| E. F. Codd, "Extending the Database Relational Model to Capture More Meaning" (RM/T), *ACM TODS* 4(4), 1979 | system-assigned surrogates that identify without describing: the ancestor of Mica's handles | Values (identities); Declarations |
| C. J. Date, *SQL and Relational Theory*, O'Reilly, 2009 | SQL as an imperfect relational language; no implicit coercion | Values; Casts and Literals (#130) |
| C. J. Date and H. Darwen, *Databases, Types, and the Relational Model: The Third Manifesto*, 3rd ed., 2006 | typed relational model; equality defined within a type | Values; Casts and Literals (#130) |
| H. G. Baker, "Equal Rights for Functional Objects or, The More Things Change, The More They Are the Same," 1993 | one principled equality for immutable values | Values (canonical equality); Casts and Literals (#130) |
| B. Moseley and P. Marks, "Out of the Tar Pit," 2006 | essential versus accidental state; derived data is not state; the "Identity and State" critique | Rules; Transactions; Incremental maintenance |
| F. P. Brooks, "No Silver Bullet," *IEEE Computer* 20(4), 1987 *(supplied)* | essential versus accidental complexity | Introduction |
| A. Kay, "Clarification of 'object-oriented'," email, 2003 | messaging and extreme late binding | Language (dispatch); Hosts |
| A. Goldberg and D. Robson, *Smalltalk-80: The Language and its Implementation*, 1983 *(supplied)* | the image as the source of truth; live revision | Units (filein, fileout) |
| D. Ungar and R. B. Smith, "Self: The Power of Simplicity," OOPSLA 1987 *(supplied)* | prototype delegation instead of class inheritance | Language (`Delegates`) |
| R. B. Smith and D. Ungar, "A Simple and Unifying Approach to Subjective Objects," *TAPOS* 2(3), 1996 | behaviour that depends on perspective | Authority; Language |
| C. Chambers, "Object-Oriented Multi-Methods in Cecil," ECOOP 1992 *(supplied)* | multimethod dispatch | Language (role dispatch) |
| M. Ernst, C. Kaplan, C. Chambers, "Predicate Dispatching: A Unified Theory of Dispatch," ECOOP 1998 *(supplied)* | dispatch as predicates over arguments | Language (role restrictions) |
| D. Gelernter, "Generative Communication in Linda," *ACM TOPLAS* 7(1), 1985 *(supplied)* | shared facts that independent processes read, write and react to | Transactions (change feed); Hosts (mailboxes) |
| S. Ceri, G. Gottlob, L. Tanca, "What You Always Wanted to Know About Datalog," *IEEE TKDE* 1(1), 1989 *(supplied)* | Datalog-style derived relations | Rules and Derivation |
| W. Chen and D. S. Warren, "Tabled Evaluation with Delaying for General Logic Programs," *JACM* 43(1), 1996 *(supplied)* | SLG tabling, including recursion | Demand-Driven Evaluation |
| M. Aref et al., "Rel: A Programming Language for Relational Data," arXiv:2504.10323, 2025 | relational programming in the large | Declarations; Rules |
| W3C, *RDF 1.1 Concepts and Abstract Syntax*, 2014 | IRIs as names for described resources; blank nodes | Values (handles) |
| W3C, *OWL 2 Primer* and *Direct Semantics*, 2012 | `owl:sameAs`; no unique-name assumption | Values (equivalence is a relation) |
| P. Curtis, *LambdaMOO Programmer's Manual*, 1993–1997; R. Daum, *mooR* *(supplied)* | multiuser worlds, online extension, image-based authoring | Units; Hosts |

Two citations need confirming before publication: the outline lists
Baker's paper in *Journal of Object-Oriented Programming* 4(4), while
it is commonly cited from *ACM OOPS Messenger* 4(4); and the Smalltalk,
Self and Linda entries are the standard sources for ideas the outline
and README name, not works either cites.

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
| [draft-ndn-quality-tool-00](draft-ndn-quality-tool-00.md) | A Relational Code-Quality Tool for Omica | Experimental |
| [draft-ndn-relational-objecthood-00](draft-ndn-relational-objecthood-00.md) (rdaum/omica#133) | Relational Objecthood: Handles, Equivalence, Objects as Views, and Claims with History | Standards-Track |
| [draft-ndn-mica-snippets-00](draft-ndn-mica-snippets-00.md) | Mica Snippets: Modes, Expected Values and Errors, Implementation Variants | Standards-Track |
| [draft-ndn-casts-and-literals-00](draft-ndn-casts-and-literals-00.md) (rdaum/omica#130) | Explicit Casts, Strict Comparison, and the Normative Literal Form | Standards-Track |
