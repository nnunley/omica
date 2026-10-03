# Bycycle Index

Quick reference for all files created in this spike.

## Start Here

1. **[BYCYCLE_DELIVERY.md](../BYCYCLE_DELIVERY.md)** (5 min read)
   - Summary of what was delivered
   - Feasibility conclusion (YES ✓)
   - Success criteria for Phase 1

2. **[apps/bycycle/README.md](README.md)** (10 min read)
   - Design overview
   - Problem statement and solution
   - Example queries
   - Architecture diagram

3. **[apps/bycycle/NEXT_STEPS.md](NEXT_STEPS.md)** (20 min read + implementation)
   - Phase 1 detailed guide
   - Code templates for:
     - Term-to-Mica conversion
     - Predicate router
     - Batch loading loop
   - Test cases
   - Debugging guide

## Implementation Files

### Parser Library (Ready to Use ✓)
- **[mica/cycl/cycl.odin](../../mica/cycl/cycl.odin)** (310 lines)
  - Lexer: tokenizes CycL s-expressions
  - Parser: builds AST
  - Formula extraction: predicate + arguments
  - Tested: 99.5% success on 1.9M assertions

### Schema (Ready to Use ✓)
- **[apps/bycycle/00_schema.mica](00_schema.mica)** (65 lines)
  - Mt-scoped relation definitions
  - Covers 80%+ of assertions
  - Easy to extend

### Loader Skeleton (Partial ⚙️)
- **[tools/cycl-load-sample/main.odin](../../tools/cycl-load-sample/main.odin)** (~50% done)
  - Schema loading: ✓
  - Manual assertions: ✓
  - CycL dump integration: TODO (see NEXT_STEPS.md)

### Harness (Stub)
- **[apps/bycycle/10_loader.mica](10_loader.mica)** (stub)
  - Query test cases (TODO)

## Validation & Analysis

### Parser Validation Tool
- **[tools/cycl-parse-test/main.odin](../../tools/cycl-parse-test/main.odin)**
  - Usage: `odin build tools/cycl-parse-test -out:test-cycl && ./test-cycl kb5022.cycl`
  - Output: Parse stats, predicate frequencies, top-30 analysis
  - Result: 99.5% parse rate proven

### Statistics Output
From running parser validation on kb5022.cycl:
```
Total lines: 1,920,919
Success: 1,911,466 (99.5%)
Failures: 9,215 (0.5% - multi-line comments, acceptable)
Parse time: 19.3 seconds (267 MB)
Distinct predicates: 211
```

## Documentation

### Status Documents
- **[CYCL_LOAD_STATUS.md](../CYCL_LOAD_STATUS.md)** (comprehensive)
  - Current implementation status
  - Architecture diagram
  - Phase breakdown (Phases 1-4)
  - Design decisions with trade-offs
  - Testing plan
  - Known limitations

- **[BYCYCLE_DELIVERY.md](../BYCYCLE_DELIVERY.md)** (executive summary)
  - Deliverables checklist
  - Feasibility conclusion
  - Success criteria
  - Quick reference

### Implementation Guide
- **[NEXT_STEPS.md](NEXT_STEPS.md)** (actionable)
  - Step-by-step Phase 1 implementation
  - Code templates with examples
  - Test cases and debugging guide
  - Top-20 predicate reference table

### Design Documents
- **[README.md](README.md)** (conceptual)
  - Problem: CycL complexity
  - Solution: Mt-scoped relations
  - Example queries
  - Design rationale

## External Data

### KB Dump
- **`~/development/bycycle/data/kb5022.cycl`** (267 MB)
  - OpenCyc 4.0 full KB dump
  - 1.9M assertions in CycL format
  - Format: `(Mt formula :truth :direction :strength)`

### Dump Generator
- **`~/development/bycycle/tools/dump-kb.lisp`** (SubL script)
  - Regenerates kb5022.cycl from running OpenCyc 4.0 engine
  - Must run at `CYC(n):` prompt (interactive mode)
  - Used during spike to verify engine works

## Quick Links

| What | Where | Status |
|------|-------|--------|
| Read spec | [README.md](README.md) | ✓ |
| Understand design | [CYCL_LOAD_STATUS.md](../CYCL_LOAD_STATUS.md) | ✓ |
| See proof | Run `test-cycl` | ✓ |
| Implement Phase 1 | [NEXT_STEPS.md](NEXT_STEPS.md) | Guide ready |
| Use parser | `mica/cycl/cycl.odin` | ✓ Ready |
| Use schema | `00_schema.mica` | ✓ Ready |

## Phase Breakdown

| Phase | Duration | Status | Description |
|-------|----------|--------|-------------|
| 0 (Spike) | Done | ✓ Complete | Parser, schema, validation |
| 1 (Sample) | 2-3 hrs | Ready to implement | Load 1k-100k assertions |
| 2 (Full) | 2 hrs | Depends on Phase 1 | Load all 1.9M assertions |
| 3 (Mt Visibility) | 1-2 hrs | Depends on Phase 2 | Mt hierarchy traversal |
| 4 (Inference) | 4-6 hrs | Optional | Rule-based inference |

## How to Proceed

**Immediate (now):**
1. Read [BYCYCLE_DELIVERY.md](../BYCYCLE_DELIVERY.md) (5 min)
2. Read [README.md](README.md) (10 min)
3. Run parser validation (2 min)
4. Review [NEXT_STEPS.md](NEXT_STEPS.md) (20 min)

**Phase 1 Implementation (~2-3 hours):**
1. Implement `term_to_atom()` function
2. Implement `route_assertion()` switch function
3. Implement `load_cycl()` batch loader
4. Run test cases
5. Verify queries work

**Then:**
- Phase 2: Scale to full KB
- Phase 3: Add Mt visibility
- Phase 4: Inference (if needed)

## Success Metrics

**Phase 0 (Spike)** - Completed ✓
- [x] Parser works on real data (99.5% success)
- [x] Schema covers major predicates
- [x] No blockers identified

**Phase 1** - Ready to implement
- [ ] Load 1,000 assertions without error
- [ ] Execute query: `Isa(?x, #$Dog, #$BaseKB)`
- [ ] Execute Mt-scoped query: `Isa(?x, #$Dentist, #$PeopleDataMt)`

**Phase 2** - Depends on Phase 1
- [ ] Load 1.9M assertions
- [ ] Query performance acceptable
- [ ] Memory usage reasonable

---

**Last updated**: Now  
**Status**: Spike complete, ready for Phase 1 implementation  
**Next**: Follow NEXT_STEPS.md for Phase 1 implementation
