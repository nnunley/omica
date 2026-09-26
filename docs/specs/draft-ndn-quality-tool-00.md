# draft-ndn-quality-tool-00: A Relational Code-Quality Tool for Omica

**Status:** DRAFT
**Corpus:** red (spec-first; the evidence is the acceptance criteria and no implementation exists yet)
**Category:** Experimental
**Authors:** Norman Nunley, Jr. <nnunley@gmail.com>


## Abstract

This document specifies `apps/quality`, a Mica application that measures the
quality of omica's own source, both Mica and Odin. It reports complexity,
maintainability, near-duplication, defect density, test reachability, rule
and relation health, and grant checks as queryable diagnostic facts. It also
reports a numeric score that an agent or reviewer can track. The document is
for omica contributors and for agents that call the tool.

## Motivation

At the time of writing (September 2026, upstream `main` at 74193f5), omica
holds about 89,000 lines of Odin in 157 files and about 25,500 lines of Mica
across `apps/`. The only quality signals are the test suite
(`scripts/test.sh`) and review. Nothing reports which procs or verbs are
hardest to change, which code the tests never reach, which relations nothing
reads, or which grants name things that do not exist. In the last 180 days,
106 commits began with `fix`. The files they touched cluster in
`mica/runtime` (75 file changes), `host/web` (51) and `mica/store` (33), and
nothing today connects that churn to the complexity of the code involved.
Dead or always-empty relations and dangling grants fail silently in a
relational system, because a query over a missing fact returns an empty
result, not an error.

omica already has most of the machinery such a tool needs. The Mica parser
in `apps/compiler/parse.mica` produces a relational syntax tree. The compiler
records relations, rules, units and grants as catalogue relations. Ryan
Daum's bootstrap proposal ([BOOTSTRAP]) argues for program facts, rules for
transitive analyses, and diagnostics as facts. This document applies that
design to a smaller, self-contained problem. The quality tool is useful on
its own, and it is an early test of the relational-program-facts approach
before the bootstrap generator depends on it.

## Terminology

The key words "MUST", "MUST NOT", "REQUIRED", "SHALL", "SHALL NOT", "SHOULD",
"SHOULD NOT", "RECOMMENDED", "NOT RECOMMENDED", "MAY", and "OPTIONAL" in this
document are to be interpreted as described in BCP 14 (RFC 2119, RFC 8174)
when, and only when, they appear in all capitals, as shown here.

- **corpus** — the set of `.mica` and `.odin` files one run analyses.
- **run world** — the disposable Mica world one run creates, analyses and discards.
- **syntax fact** — a row `(node, role, target, ordinal)` describing one edge of a syntax tree, in the shape `parse_rows` produces.
- **routine** — a unit that complexity measures apply to: a Mica verb, a Mica `fn` literal bound at top level, or an Odin procedure.
- **rule** — a Mica relation rule (`Head(...) :- Body`).
- **branch point** — a syntax node that adds one independent path through a routine (listed in "Complexity measures").
- **diagnostic** — a row of the `quality/Diagnostic` relation: one finding with a code, severity, subject node and message.
- **term** — one scored dimension (for example, cyclomatic complexity) with a value from 0 to 100.
- **score** — the weighted combination of terms for a file, a language, or the whole corpus.
- **test root** — a place where static test reachability starts: a top-level expression in a Mica test file, or an Odin procedure carrying `@(test)`.

## Specification

This document defines the quality tool: its inputs, the facts it derives,
the measures and their definitions, the scoring, the diagnostics, and its two
surfaces (a command-line report and an agent tool verb). It does NOT define
the git relations of the source host beyond the columns the tool reads; the
source host owns them. It does NOT define a pull-request workflow. A PR
delta is an extension point (see Out of Scope).

**One disposable world per run.** Each run loads its corpus into a fresh
run world with no store, reads it, and discards it. No state carries from one
run to the next. This follows [BOOTSTRAP] section 5.2 and makes results a
function of the inputs alone.

**Facts in, facts out.** Every input the tool consumes and every finding it
produces is a relation in the run world. Reports are renderings of those
relations, never a separate data path.

**Analyses by rule, construction by verb.** Transitive analyses (reachability,
relation health) are stratified rules that do not allocate identities.
Counting measures and report rendering are ordinary verbs over a frozen
snapshot. This matches [BOOTSTRAP] section 5.1.

### Data model

Inputs, loaded into the run world:

```
-- Catalogue relations the ordinary compiler already writes (mica/kernel/dispatch.odin):
--   Relation, RelationName, Arity, FunctionalKey, ConflictPolicy,
--   Rule, RuleHead, RuleSource, ActiveRule,
--   UnitSource, MethodSource, NamedIdentity,
--   SourceOwnsFact, SourceOwnsRule, SourceOwnsRelation
-- Grant relations minted by mica/kernel/authority.odin:
--   CanRead, CanWrite, CanInvoke, CanEffect

RECORD SyntaxFact:                      -- relation quality/Syntax
    file        : String                -- corpus-relative path
    node        : Integer               -- node id, unique within the file
    role        : Symbol                -- :kind, :child, :callee, :op, :name, :line, ...
    target      : Value                 -- a node id, or an attribute value for attribute roles
    ordinal     : Integer               -- position among siblings with the same role

RECORD Routine:                         -- relation quality/Routine
    file        : String
    node        : Integer               -- the routine's root node
    name        : String                -- verb name, or package.proc for Odin
    language    : Language
    first_line  : Integer
    last_line   : Integer

RECORD CallEdge:                        -- relation quality/Calls (derived)
    caller      : Routine
    callee      : Routine | Unresolved  -- Unresolved for proc values and dynamic dispatch

ENUM Language:
    MICA
    ODIN
```

Outputs:

```
RECORD Diagnostic:                      -- relation quality/Diagnostic
    id          : Integer
    code        : DiagnosticCode
    severity    : Severity
    file        : String
    node        : Integer | None        -- None for file- or corpus-level findings
    message     : String                -- one sentence naming the measured value and its threshold

RECORD Evidence:                        -- relation quality/Evidence
    diagnostic  : Integer               -- Diagnostic.id
    position    : Integer
    detail      : Value                 -- e.g. a call-path element, a duplicate region, a commit id

RECORD TermScore:                       -- relation quality/Term
    scope       : String                -- a file path, "mica", "odin", or "corpus"
    term        : Symbol                -- see the Scoring table
    value       : Float                 -- raw measured value
    score       : Float                 -- 0..100

ENUM Severity:
    ERROR       -- a definite defect: a dangling grant, or a rule head that is also asserted directly
    WARNING     -- over a threshold
    NOTE        -- informational; does not affect the score
```

**Field constraints:** `Diagnostic.id` values are dense from 1 in emission
order, and emission order is deterministic (see [R-deterministic]). `message`
never embeds absolute paths or timestamps.

`DiagnosticCode` values and their meanings are listed in Appendix A.

### Configuration

| Key | Type | Default | Description |
|---|---|---|---|
| `--since` | Date or commit | 180 days before the run | Start of the defect-density window, resolved once to an explicit commit range that is printed in the report header |
| `--format` | `text` \| `mica` | `text` | Report rendering. `mica` prints the report as one Mica map value. |
| `--top` | Integer | `25` | Number of ranked issues printed in `text` format |
| `--root` | Path | current directory | Repository root; every corpus path is relative to it |
| paths | Path list | `apps`, `mica`, `host`, `tools` | Corpus roots, walked for `.mica` and `.odin` files |

The 180-day default matches let-go's tool and covers about two release
cycles of history without letting old churn dominate.

**Resolution precedence** (highest first):

1. Command-line flag
2. Argument passed to `tool/quality`
3. Default from the table above

### Loading

The tool MUST load the corpus's `.mica` files into the run world through the
same filein path an ordinary world uses, so that the catalogue relations
reflect exactly what the compiler records. [R-load-via-filein]

```transcript @R-load-via-filein
$ tools/quality --format mica tests/quality/fixtures/decls | grep -c ':relation :Seen'
1
? 0
```

The run world MUST have no store and MUST NOT grant the corpus any host
effect: no network, external-request, or subscription capability. [R-sandboxed-world]
Loading runs the corpus's top-level expressions; this rule bounds what a
hostile or broken corpus can do (see Security Considerations).

```transcript @R-sandboxed-world
$ tools/quality tests/quality/fixtures/effects | grep Q_LOAD
tests/quality/fixtures/effects/fetch.mica:1 Q_LOAD ERROR external_request is not available while loading a corpus
? 0
```

The tool MUST obtain Mica syntax facts from `parse_rows` in
`apps/compiler/parse.mica`, applied to each `UnitSource` text. [R-mica-syntax-from-parser]

```transcript @R-mica-syntax-from-parser
$ tools/quality --format mica tests/quality/fixtures/one-verb | grep -c ':kind :VerbItem'
1
? 0
```

The tool MUST obtain Odin syntax facts from `core:odin/parser`, through a
helper `tools/quality-facts` that writes rows in the `quality/Syntax` shape. [R-odin-syntax-from-core]
Using the compiler's own parser keeps the facts exact as Odin evolves; a
second Odin parser written in Mica would drift.

```transcript @R-odin-syntax-from-core
$ tools/quality-facts tests/quality/fixtures/one-proc/p.odin | grep -c 'proc_lit'
1
? 0
```

A file that fails to parse MUST produce one `Q_PARSE` diagnostic of severity
`ERROR` and MUST NOT stop the run. [R-parse-failure-isolated]

```transcript @R-parse-failure-isolated
$ tools/quality --format text tests/quality/fixtures/broken
file tests/quality/fixtures/broken/bad.mica: Q_PARSE ERROR 3:9 expected an expression
file tests/quality/fixtures/broken/good.mica: scored
? 0
```

### Complexity measures

Every measure below applies to every routine in both languages.

**Branch points.**

| Language | Branch points (each adds 1) |
|---|---|
| Mica | each conditional `IfBranch` (not the final `else`), each `MatchCase` after the first, `While`, `For`, `Comprehension`, `Catch`, and each `and`/`or` `Binary` |
| Odin | each `if`/`when` condition (including `else if`), `for`, each `case` clause after the first in `switch`, each `&&`/`\|\|`, and each `or_return`, `or_else`, `or_break`, `or_continue` |

Cyclomatic complexity of a routine MUST be 1 plus the number of its branch
points, excluding branch points inside nested routine literals, which count
toward those literals. [R-cyclomatic]

<!-- evidence: @R-cyclomatic -->
| language | routine body | cyclomatic |
|---|---|---|
| mica | `return x` | 1 |
| mica | `if a return 1 elseif b return 2 else return 3 end` | 3 |
| mica | `if a and b return 1 end` | 3 |
| mica | `match v case some(n) n case none 0 end` | 2 |
| odin | `return x` | 1 |
| odin | `if a && b { return 1 }` | 3 |
| odin | `x := f() or_return` | 2 |
| odin | `switch k { case .A: f() case .B: g() case: h() }` | 3 |

Cognitive complexity of a routine MUST follow [COGNITIVE]: add 1 for each
branch point, plus the current nesting depth for each branch point that opens
a nested block (`if`, `for`, `while`, `switch`, `match`, `try`), plus 1 for
each `break` or `continue` that targets a label, plus 1 for each direct
recursive call. A run of the same boolean operator counts once. [R-cognitive]

<!-- evidence: @R-cognitive -->
| language | routine body | cognitive |
|---|---|---|
| odin | `if a { return 1 }` | 1 |
| odin | `for x in xs { if x > 0 { n += 1 } }` | 3 |
| odin | `if a && b && c { return 1 }` | 2 |
| odin | `if a && b \|\| c { return 1 }` | 3 |
| mica | `for x in xs if x > 0 n = n + 1 end end` | 3 |

Maximum nesting depth, routine length (lines excluding blank and
comment-only lines), parameter count, fan-out (distinct resolved callees) and
fan-in (distinct resolved callers) MUST be computed for every routine. [R-shape-measures]

<!-- evidence: @R-shape-measures -->
| language | routine | nesting | length | parameters |
|---|---|---|---|---|
| odin | `f :: proc(a, b: int) -> int { if a > 0 { for i in 0..<b { a += i } }; return a }` | 2 | 1 | 2 |
| mica | `verb f(a, b) if a > 0 for i in b a = a + i end end return a end` | 2 | 1 | 2 |

For each rule, the tool MUST compute rule complexity: the number of body
atoms, with each negated atom counting 2. [R-rule-complexity]

<!-- evidence: @R-rule-complexity -->
| rule | rule complexity |
|---|---|
| `Path(?x, ?y) :- Edge(?x, ?y)` | 1 |
| `Path(?x, ?z) :- Edge(?x, ?y), Path(?y, ?z)` | 2 |
| `Allowed(?x) :- Person(?x), not Banned(?x)` | 3 |

### Maintainability and duplication

The maintainability index of a file MUST be
`clamp(171 − 5.2·ln(V) − 0.23·CC_total − 16.2·ln(LOC) + 50·sin(√(2.4·CR)), 0, 100)`.
Here `V` is Halstead volume from the file's syntax facts: operators are node
kinds and operator tokens, and operands are names and literals. `CC_total`
is the sum of routine cyclomatic complexity, `LOC` counts non-blank lines,
and `CR` is the ratio of comment lines to all lines. [R-maintainability]
This is the formula let-go's tool uses, so scores are comparable across the
two projects.

<!-- evidence: @R-maintainability -->
| V | CC_total | LOC | CR | index |
|---|---|---|---|---|
| 1 | 1 | 1 | 0 | 100 |
| 1000 | 20 | 200 | 0 | 44.6 |

Near-duplication MUST use winnowing ([WINNOW]) with k = 25 tokens and window
w = 40. Tokens come from `lex` in `apps/compiler/lex.mica` for Mica and from
`core:odin/tokenizer` for Odin. Identifiers normalize to `ID`, string and
numeric literals to `STR` and `NUM`, and comments are dropped. Files are
compared only with files of the same language. [R-duplication]

```transcript @R-duplication
$ tools/quality tests/quality/fixtures/dup | grep -c Q_DUP
1
? 0
```

Each duplicate region pair MUST produce one `Q_DUP` diagnostic whose evidence
names both regions by file and line range. [R-dup-evidence]

```transcript @R-dup-evidence
$ tools/quality tests/quality/fixtures/dup | grep Q_DUP
tests/quality/fixtures/dup/a.odin:3 Q_DUP WARNING 31 tokens duplicated with tests/quality/fixtures/dup/b.odin:5-14
? 0
```

### History

Defect density of a file MUST be the number of commits in the `--since`
window whose subject matches `^fix` and which touch the file, divided by the
file's non-blank lines in thousands. [R-defect-density]
The count reads the source host's git relations (see Compatibility); the tool
never shells out to `git`.

<!-- evidence: @R-defect-density -->
| fix commits touching file | non-blank lines | defects per KLOC | term score |
|---|---|---|---|
| 0 | 500 | 0 | 100 |
| 1 | 500 | 2 | 60 |
| 3 | 500 | 6 | 0 |

The report header MUST print the resolved commit range. [R-history-range-printed]

```transcript @R-history-range-printed
$ tools/quality --since 2026-03-01 --root tests/quality/fixtures/repo | head -1
quality 0.1  roots: .  history: 1a2b3c4..9f8e7d6 (2026-03-01..HEAD)
? 0
```

### Test reachability and testing density

Test roots are the top-level expressions of files under `apps/*/tests/` and
the Odin procedures carrying `@(test)`.

The tool MUST derive `quality/Reached` with stratified rules equivalent to:

```
Reached(r)  :- TestRoot(r).
Reached(g)  :- Reached(f), Calls(f, g).
Reached(rl) :- Reached(f), Reads(f, rel), RuleHead(rl, rel).
Reached(g)  :- Reached(rl), RuleBodyReads(rl, rel), Deriving(g, rel).
```

The rules MUST NOT allocate identities, and an `Unresolved` callee MUST NOT
count as reached. [R-reachability-rules]
An unresolved edge is reported, not guessed; guessing would inflate coverage.

<!-- evidence: @R-reachability-rules -->
| fixture | subject | reached |
|---|---|---|
| `reach` | `helper`, called from a test | yes |
| `reach` | `unused`, called by nothing | no |
| `reach` | `callback`, called only through a proc value | no |
| `reach` | the rule deriving `Path`, read by a tested verb | yes |

Coverage MUST be the reached routines and rules divided by all routines and
rules, per language. [R-coverage]

<!-- evidence: @R-coverage -->
| routines and rules | reached | coverage % |
|---|---|---|
| 4 | 2 | 50 |
| 10 | 10 | 100 |

Testing density MUST be assertion calls per thousand non-blank lines, where
an assertion is a call to a verb whose name starts with `test/assert` (Mica)
or to `testing.expect`, `testing.expectf` or `testing.expect_value` (Odin). [R-testing-density]

<!-- evidence: @R-testing-density -->
| assertion calls | non-blank lines | assertions per KLOC | term score |
|---|---|---|---|
| 0 | 1000 | 0 | 0 |
| 10 | 1000 | 10 | 50 |
| 40 | 1000 | 40 | 100 |

### Rule and relation health

Each of the following MUST produce one diagnostic per subject, with the listed
code and severity. [R-health]

<!-- evidence: @R-health -->
| code | severity | condition |
|---|---|---|
| `Q_DEAD_RELATION` | WARNING | a declared relation that no routine or rule body reads |
| `Q_EMPTY_RELATION` | WARNING | a relation that is read, but is never asserted, is no rule's head, has no loaded facts, and is neither computed nor host-provided |
| `Q_MIXED_DERIVATION` | ERROR | a relation that is both some rule's head and the target of a direct `assert` |
| `Q_INACTIVE_RULE` | NOTE | a rule whose `ActiveRule` value is false |
| `Q_RULE_COMPLEXITY` | WARNING | rule complexity above its threshold |

### Authority and grants

Each of the following MUST produce one diagnostic per grant row or verb. [R-grants]

<!-- evidence: @R-grants -->
| code | severity | condition |
|---|---|---|
| `Q_DANGLING_GRANT` | ERROR | a `CanRead`, `CanWrite`, `CanInvoke` or `CanEffect` row naming an undeclared relation, verb or identity |
| `Q_SYSTEM_GRANT` | ERROR | a grant on a catalogue relation to a subject other than root |
| `Q_DERIVED_WRITE_GRANT` | WARNING | a `CanWrite` grant on a relation that is a rule head |
| `Q_UNGRANTED_TOOL` | WARNING | a `tool/*` verb that no `CanInvoke` row covers |

### Scoring

| Term | 100 at | 0 at | Between | Weight |
|---|---|---|---|---|
| Cyclomatic (routine max per file) | ≤ 10 | ≥ 30 | linear | 15 |
| Cognitive (routine max per file) | ≤ 15 | ≥ 50 | linear | 15 |
| Maintainability index | 100 | 0 | identity | 15 |
| Duplication % | 0 | ≥ 50 | `100 − 2·dup%` | 15 |
| Defects per KLOC | 0 | ≥ 5 | `100 − 20·d` | 10 |
| Coverage % | 100 | 0 | identity | 20 |
| Testing density (assertions per KLOC) | ≥ 20 | 0 | linear | 10 |

Nesting depth, length, parameter count and fan-in/fan-out are reported as
`WARNING` diagnostics above these thresholds and do not enter the score: nesting 4,
length 60 lines, parameters 5, fan-out 15, fan-in 20, rule complexity 6.
Scoring them as well would count the same complexity twice.

The tool MUST compute a score per file, per language (weighted by file
non-blank lines), and for the corpus (the two language scores weighted by
their non-blank lines). [R-score-aggregation]
Weighting by lines keeps 89,000 lines of Odin from being outvoted by a few
small Mica files, and the reverse.

<!-- evidence: @R-score-aggregation -->
| mica score | mica lines | odin score | odin lines | corpus score |
|---|---|---|---|---|
| 60 | 1000 | 80 | 3000 | 75 |
| 90 | 25500 | 70 | 89000 | 74.45 |

Ranked issues MUST be ordered by the corpus-score gain from bringing the
subject to its threshold, largest first, with ties broken by file path and
then line. [R-ranking]

<!-- evidence: @R-ranking -->
| issue | score gain | file | line | rank |
|---|---|---|---|---|
| deep proc | 1.8 | mica/kernel/b.odin | 40 | 1 |
| duplicate | 0.9 | mica/kernel/a.odin | 10 | 2 |
| long verb | 0.9 | mica/kernel/a.odin | 90 | 3 |

### Determinism

Two runs over the same corpus, the same history range and the same options
MUST produce byte-identical reports, regardless of file system enumeration
order, symbol interning order or fact insertion order. [R-deterministic]
Reports that shift between identical runs cannot be compared, and an agent
optimizing the score would chase noise.

```transcript @R-deterministic
$ tools/quality --format mica tests/quality/fixtures/mixed > /tmp/q1
$ QUALITY_SHUFFLE_SEED=7 tools/quality --format mica tests/quality/fixtures/mixed > /tmp/q2
$ cmp /tmp/q1 /tmp/q2 && echo same
same
? 0
```

### Surfaces

The command-line tool MUST exit 0 when it completes, whatever the score, and
MUST exit 1 only when it cannot complete (unreadable root, failed world
start). [R-exit-status]
The tool reports; gating on the score is a policy choice for CI, not for the tool.

```transcript @R-exit-status
$ tools/quality --root /nonexistent
quality: root /nonexistent does not exist
? 1
```

The `text` report MUST begin with a header (tool version, corpus roots,
resolved history range), then the corpus and per-language scores, then the
top `--top` ranked issues, each as `path:line code severity message`. [R-text-report]

The `mica` report MUST be a single Mica map value with the keys `:header`,
`:scores`, `:terms` and `:diagnostics`. Its content MUST equal the
`quality/Term` and `quality/Diagnostic` relations of the run. [R-mica-report]

```transcript @R-mica-report
$ tools/quality --format mica tests/quality/fixtures/mixed | head -c 25
{:header -> {:version ->
? 0
```

The verb `tool/quality(agent, arguments)` MUST return the same map the `mica`
report prints, for the paths in `arguments[:paths]`. It MUST be callable only
by subjects that hold a `CanInvoke` grant on it. [R-tool-verb]

```transcript @R-tool-verb
$ tools/filein apps/quality/*.mica --eval 'return tool/quality(#agent, {:paths -> ["tests/quality/fixtures/mixed"]})[:scores][:corpus]'
71.4
? 0
```

```transcript @R-text-report
$ tools/quality tests/quality/fixtures/mixed
quality 0.1  roots: tests/quality/fixtures/mixed  history: none (not a repository)
score corpus 71.4  mica 68.0  odin 73.9
tests/quality/fixtures/mixed/deep.odin:3 Q_COGNITIVE WARNING cognitive complexity 22 exceeds 15
tests/quality/fixtures/mixed/rules.mica:4 Q_MIXED_DERIVATION ERROR Seen is a rule head and is asserted directly
? 0
```

### Errors

| Error | Example | Recovery |
|---|---|---|
| `Q_PARSE` (diagnostic) | a `.mica` file with a syntax error | Record the diagnostic, skip the file's measures, continue |
| `Q_LOAD` (diagnostic) | a filein expression aborts while the corpus loads | Record it with the unit name; keep what loaded; continue |
| `Q_NO_HISTORY` (diagnostic, NOTE) | the root is not a git repository | Skip defect density; its term weight moves to the others in proportion |
| `Q_UNRESOLVED_CALL` (diagnostic, NOTE) | an Odin call through a proc value | Keep the edge as unresolved; never count it as reached |
| exit 1 | `--root` does not exist | Print the reason to stderr and exit 1 |

## Formal Grammar

```abnf
command     = "tools/quality" *( SP option ) *( SP path )
option      = since / format / top / root
since       = "--since" SP ( date / commit )
format      = "--format" SP ( %s"text" / %s"mica" )
top         = "--top" SP 1*DIGIT
root        = "--root" SP path
date        = 4DIGIT "-" 2DIGIT "-" 2DIGIT
commit      = 7*40HEXDIG
path        = 1*( ALPHA / DIGIT / "/" / "." / "_" / "-" )
issue-line  = path ":" 1*DIGIT SP code SP severity SP message
code        = %s"Q_" 1*( %x41-5A / "_" )
severity    = %s"ERROR" / %s"WARNING" / %s"NOTE"
message     = 1*( %x20-7E )
```

## Out of Scope

**Pull-request delta.** Scoring only the files and routines a change touches,
against a base revision. It is excluded until the git relations exist and the
full-corpus report has been used for a while. Extension point: a `--base
<commit>` option that restricts the subjects to those `source/ChangedFiles`
reports, reusing [R-ranking].

**Dynamic coverage.** Branch coverage from running the tests. Excluded
because omica's VM has no hit counters today. Extension point: a
`quality/Hit(file, node)` relation filled by an instrumented test run, which
replaces `Reached` in [R-coverage].

**Ratchet baseline.** Failing CI when the score drops. Excluded because it is
a CI policy, not a measurement (see [R-exit-status]). Extension point: a
script that compares two `mica` reports.

**Auto-fixing.** Out of scope; the tool only reports.

## Alternatives Considered

**Why not extend omica's Odin compiler to emit structure facts?** That changes
the compiler for a tool's benefit. `parse.mica` already produces the facts,
and the self-differential tool checks them against the Odin parser.

**Why not write an Odin parser in Mica?** It would duplicate
`core:odin/parser`, which is exact, maintained with the language, and already
on every machine that builds omica.

**Why not compute reachability and health with hand-written tree walks?**
They are transitive queries over relations. Rules state them in a few lines,
are stratified by construction, and follow the idiom [BOOTSTRAP] sets for
generator analyses. Walks would re-implement joins by hand.

**Why not emit plain text only?** Agents and tools would have to scrape the
text, and findings could not be queried or joined with other facts, such as
"which dead relations were added in the last month".

**Why not run let-go's tool?** It runs on let-go and understands only let-go
and Go. Its metric definitions are reused here; its code cannot be.

**Why not score nesting, length, parameters and fan-in/fan-out?** Each
correlates strongly with cyclomatic or cognitive complexity; scoring them
too would penalize one long proc several times over.

**Why not shell out to `git` for history?** Parsing command output is
fragile. Relations in the source host make history queryable by the same
rules as everything else, and the host already bounds file access to the
repository root.

## Security Considerations

Loading a corpus runs its top-level Mica expressions. A hostile or broken
corpus can therefore run arbitrary Mica during a run. [R-sandboxed-world]
bounds this: the run world has no store, so nothing persists, and it has no
network, external-request, subscription or other host-effect capability.
What remains is CPU and memory use. A run SHOULD be started under a memory
limit and a time limit when the corpus is not trusted.

The Odin helper parses files and never executes them.

Git relations are read-only and confined to `--root`. The history walk is
bounded (at most 512 commits per walk, as in the Rust source provider) so a
large repository cannot stall a run.

Reports contain paths relative to `--root` and short messages. They never
contain file contents beyond the identifiers named in a message, so a report
does not leak more source than the reader of the repository already has.

The `tool/quality` verb requires a `CanInvoke` grant [R-tool-verb], so an
agent without that grant cannot make the host parse arbitrary paths.

## Compatibility

The tool adds files and changes no existing behavior. It requires three
additions outside `apps/quality/`:

1. `tools/quality-facts` (Odin), which writes Odin syntax facts and tokens.
2. Git relations in the source host (`host/source/`), read-only:
   `source/CommitLog(repository, commit, parent, subject, author, time)` and
   `source/ChangedFiles(repository, from, to, path, change)`, modeled on the
   Rust source provider's relations of the same names ([RUST-SOURCE]).
3. `tools/quality`, a thin Odin entry point that starts a run world, loads
   `apps/quality/`, and prints the report.

Until item 2 lands, runs emit `Q_NO_HISTORY` and score without defect density.

## References

- [BOOTSTRAP] R. Daum, "A runtime generated by Mica", draft for discussion, 2026-09-26, https://gist.github.com/rdaum/566a6d0afe1358742b40e5728b7893a3
- [COGNITIVE] G. A. Campbell, "Cognitive Complexity: A new way of measuring understandability", SonarSource, 2018, https://www.sonarsource.com/docs/CognitiveComplexity.pdf
- [WINNOW] S. Schleimer, D. Wilkerson, A. Aiken, "Winnowing: Local Algorithms for Document Fingerprinting", SIGMOD 2003, https://doi.org/10.1145/872757.872770
- [MI] P. Oman, J. Hagemeister, "Metrics for assessing a software system's maintainability", ICSM 1992, https://doi.org/10.1109/ICSM.1992.242525
- [RUST-SOURCE] timbran-project/mica, `crates/source-provider/src/relations.rs` (commit 2bbceb0): `CommitLog`, `ChangedFiles`, `FileHistory`.
- Reference project: let-go, `scripts/quality.lg` and `scripts/quality/*.lg`, Go/let-go. It is the source of the metric definitions, the scoring table shape, and the ranked-issue report worth studying.
- omica code this document builds on: `apps/compiler/parse.mica`, `apps/compiler/lex.mica`, `mica/kernel/dispatch.odin` (catalogue relations), `mica/kernel/authority.odin` (grant minting), `host/source/index.odin` (source relations), `apps/agent/tools.mica` (`tool/*` verbs).

## Appendix A. Diagnostic codes

| Code | Severity | Meaning |
|---|---|---|
| `Q_PARSE` | ERROR | the file does not parse |
| `Q_LOAD` | ERROR | a filein expression aborted while the corpus loaded |
| `Q_COMPLEXITY` | WARNING | cyclomatic complexity above 10 |
| `Q_COGNITIVE` | WARNING | cognitive complexity above 15 |
| `Q_NESTING` | WARNING | nesting depth above 4 |
| `Q_LENGTH` | WARNING | routine longer than 60 lines |
| `Q_PARAMETERS` | WARNING | more than 5 parameters |
| `Q_FAN_OUT` | WARNING | more than 15 distinct callees |
| `Q_FAN_IN` | WARNING | more than 20 distinct callers |
| `Q_RULE_COMPLEXITY` | WARNING | rule complexity above 6 |
| `Q_MAINTAINABILITY` | WARNING | file maintainability index below 65 |
| `Q_DUP` | WARNING | a near-duplicate region pair |
| `Q_DEFECTS` | NOTE | file defect density above 2 per KLOC |
| `Q_UNREACHED` | NOTE | a routine or rule no test reaches |
| `Q_UNRESOLVED_CALL` | NOTE | a call edge the tool cannot resolve |
| `Q_NO_HISTORY` | NOTE | no git history is available |
| `Q_DEAD_RELATION` | WARNING | see Rule and relation health |
| `Q_EMPTY_RELATION` | WARNING | see Rule and relation health |
| `Q_MIXED_DERIVATION` | ERROR | see Rule and relation health |
| `Q_INACTIVE_RULE` | NOTE | see Rule and relation health |
| `Q_DANGLING_GRANT` | ERROR | see Authority and grants |
| `Q_SYSTEM_GRANT` | ERROR | see Authority and grants |
| `Q_DERIVED_WRITE_GRANT` | WARNING | see Authority and grants |
| `Q_UNGRANTED_TOOL` | WARNING | see Authority and grants |
