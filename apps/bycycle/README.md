# Bycycle: OpenCyc KB5022 on Mica

This app demonstrates loading OpenCyc KB5022 knowledge base into Mica using an Mt-scoped (microtheory-scoped) relational schema.

## Current Status

### ✅ Completed
1. **CycL S-Expression Parser** (`mica/cycl/cycl.odin`)
   - Parses CycL syntax: atoms, variables, strings, numbers, nested lists
   - Handles CycL-specific forms: `#$Constants`, `:Keywords`, `?Variables`
   - Parse rate: **99.5%** on kb5022.cycl (1.9M assertions)
   - Parse speed: **19 seconds** for 267 MB file

2. **Parser Validation** (`tools/cycl-parse-test/`)
   - Verified parser on full kb5022.cycl dump
   - Identified parse failures: multi-line comments (acceptable, 0.5% of lines)
   - Extracted predicate statistics: 211 distinct predicates

3. **Mt-Scoped Schema** (`apps/bycycle/00_schema.mica`)
   - Relations parametrized by Mt (microtheory)
   - Schema covers top 40+ predicates:
     - Core taxonomy: Isa, Genls, DisjointWith, QuotedIsa
     - Predicate metadata: Arity, ArgIsa, Arg1Isa, Arg2Isa, ResultIsa, etc.
     - Microtheory semantics: GenlMt (Mt visibility)
     - Logical forms: Implies, Not, FunctionalInArgs, etc.
     - Display: Comment, PrettyString, BroaderTerm

### 🚧 In Progress
- Full loader tool (routes CycL assertions to Mica relations)
- Transactional batch loading of 1.9M assertions
- Mt-scoped query execution

### 📋 Next Steps

**Phase 1: Load Sample (1-2 hours)**
- Implement assertion router: (Mt, predicate, args) → Mica relation call
- Handle all data types: atoms, variables, NARTs, strings, numbers
- Load first 10k-100k assertions into Mica
- Test basic Mt-scoped query: `Isa(?x, Dentist, #$PeopleDataMt)`

**Phase 2: Full Load (2-4 hours)**
- Batch transactional loading of all 1.9M assertions
- Progress checkpointing (resume from crash point)
- Assertion count verification
- Memory/performance profiling

**Phase 3: Mt Visibility (1-2 hours)**
- Implement GenlMt traversal for query scope
- Support queries like: "find all X in PeopleDataMt and its parent Mts"
- Test transitive closure over genlMt hierarchy

**Phase 4: Inference (4+ hours)**
- Convert `Implies` rules to Mica query rules
- Implement backward chaining for non-Horn rules
- Test rule-based inference on loaded KB

## Design: Mt-Scoped Relational KB

### Problem Statement
- OpenCyc assertions live in microtheories (Mt), a scoping mechanism
- Each assertion is `(Mt predicate arg1 arg2 ... :truth :direction :strength)`
- Queries should respect Mt visibility (transitive genlMt closure)
- Goal: make knowledge accessible at relation level, avoid Cyc's complexity

### Solution
- Every relation is Mt-scoped: `Isa(subject, collection, Mt)`
- Mt's are constants: `#$BaseKB`, `#$PeopleDataMt`, etc.
- Queries are straightforward Mica rules with Mt as a parameter
- Mt visibility handled by rules (easier to optimize than interpreter)

### Example: Find Dentists in PeopleDataMt

```
// Schema
Isa(subject, collection, Mt)        // Mt-scoped
Genls(child, parent, Mt)            // Mt-scoped
GenlMt(specialMt, generalMt, Mt)    // Mt hierarchy

// Transitive closure rules
InstanceOf(item, ancestor, Mt) :-
  Isa(item, collection, Mt),
  Subsumes(collection, ancestor, Mt)

Subsumes(child, parent, Mt) :-
  Genls(child, parent, Mt)

Subsumes(child, parent, Mt) :-
  Genls(child, middle, Mt),
  Subsumes(middle, parent, Mt)

// Query: Find dentists in PeopleDataMt
DentistInPeopleData(Person) :-
  Isa(Person, Dentist, #$PeopleDataMt)
```

## Key Files

- `00_schema.mica` - Mt-scoped relation definitions
- `10_loader.mica` - Loader harness and rules
- `../../../mica/cycl/cycl.odin` - CycL parser library
- `../../../tools/cycl-parse-test/` - Parser validation tool
- `../../../tools/cycl-load-sample/` - Sample loader POC
- `../../../development/bycycle/data/kb5022.cycl` - Full KB dump (267 MB)

## Running

```bash
# Validate parser on full dump
odin build tools/cycl-parse-test -out:test-cycl
./test-cycl /path/to/kb5022.cycl

# Load the schema and 7 Mt-scoped sample facts (in memory, or --store DIR)
odin run tools/cycl-load-sample -- --store /tmp/bycycle-sample apps/bycycle/00_schema.mica
odin run tools/filein -- --store /tmp/bycycle-sample --eval 'return len(Isa(?s, ?c, ?mt))'

# Read the full dump against the schema: parses every assertion and counts
# them per predicate. Routing into relations is not implemented yet, so
# nothing from the dump is asserted.
odin run tools/cycl-load -o:speed -- [--store DIR] [--limit N] \
  apps/bycycle/00_schema.mica /path/to/kb5022.cycl
```

## Analysis: Is This Feasible?

**Yes.** Evidence:
- Parser works reliably (99.5% success)
- Schema can express all major predicates
- Mt-scoped relations are straightforward in Mica
- No need to port SubL; relational encoding is simpler
- Parsing is fast (19s for 267MB suggests ~8-10 min for load with routing)

**Trade-offs:**
- No inference engine (Cyc's tactic, SAT solver, etc.)
  - Solution: encode rules as Mica queries + backward chaining
- No procedural code execution
  - Solution: stub out predicates; most KB is declarative
- Mt visibility is query-time, not interpreter-level
  - Solution: simpler, debuggable, no performance cost

**Recommendation:** Proceed with Phase 1 (sample load). Once sample loads and queries work, Phase 2 (full load) is straightforward engineering.
