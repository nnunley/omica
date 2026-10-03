# Phase 1: Load Sample CycL Assertions

This guide walks through the remaining work to load a sample of kb5022.cycl into Mica.

## Current State (✓ Complete)

- [x] CycL s-expression parser (`mica/cycl/cycl.odin`)
- [x] Parser validation on full kb5022.cycl (99.5% success)
- [x] Mt-scoped relational schema (`apps/bycycle/00_schema.mica`)
- [x] Predicate analysis (211 predicates identified)
- [x] Loader framework skeleton (`tools/cycl-load-sample/main.odin`)

## Remaining Work (2-3 hours)

### Step 1: Implement Term-to-Mica Conversion

**File**: `tools/cycl-load-sample/main.odin` (after load_schema function)

Convert CycL AST nodes to Mica values. Mica's runtime accepts atoms as value representations.

```odin
// Convert CycL node to Mica atom representation
term_to_atom :: proc(node: cyc.Node) -> string {
	switch n in node {
	case cyc.Atom:
		return string(n)  // "#$Foo" stays as-is
	case cyc.Variable:
		return string(n)  // "?X" stays as-is
	case cyc.String:
		return fmt.aprintf("\"quoted_%s\"", string(n))  // Strings become quoted
	case cyc.Number:
		return fmt.aprintf("number_%f", n)  // Numbers get prefix
	case cyc.List:
		// NARTs: (#$function arg1 arg2) becomes "fn_arg1_arg2"
		elements := make([dynamic]string)
		for elem in n.elements {
			append(&elements, term_to_atom(elem))
		}
		return fmt.aprintf("nart_%s", strings.join(elements, "_"))
	case nil:
		return "nil"
	}
	return ""
}
```

### Step 2: Implement Predicate Router

**File**: `tools/cycl-load-sample/main.odin` (add to load_cycl function)

For each parsed CycL assertion, route to appropriate Mica relation.

```odin
route_assertion :: proc(tx: r.Transaction, mt: cyc.Node, pred: cyc.Atom, args: []cyc.Node) {
	pred_str := string(pred)
	
	switch pred_str {
	case "#$isa":
		if len(args) == 2 {
			subject := term_to_atom(args[0])
			collection := term_to_atom(args[1])
			mt_atom := term_to_atom(mt)
			// Insert: Isa(subject, collection, Mt)
			// Call r.insert() with appropriate relation tuple
		}
	
	case "#$genls":
		if len(args) == 2 {
			child := term_to_atom(args[0])
			parent := term_to_atom(args[1])
			mt_atom := term_to_atom(mt)
			// Insert: Genls(child, parent, Mt)
		}
	
	case "#$comment":
		if len(args) == 2 {
			term := term_to_atom(args[0])
			text := term_to_atom(args[1])
			mt_atom := term_to_atom(mt)
			// Insert: Comment(term, text, Mt)
		}
	
	// ... Handle ~30+ more predicates based on top-predicate list
	// See predicate analysis output for frequencies
	
	case:
		// Unknown predicate: skip or log
		_ = pred_str
	}
}
```

### Step 3: Batch Loading Loop

**File**: `tools/cycl-load-sample/main.odin` (replace stub load_cycl)

Load first N assertions in batches for performance.

```odin
load_cycl :: proc(world: s.World, path: string, limit: int) -> string {
	file, err := os.open(path)
	if err != nil {
		return "failed to open kb5022.cycl"
	}
	defer os.close(file)
	
	reader := create_buffered_reader(file)  // Odin bufio
	defer destroy_reader(&reader)
	
	batch_size := 1000
	tx := r.transaction_create(world)
	assertions_in_batch := 0
	total_assertions := 0
	
	for {
		line, err := read_line(&reader)  // Read next line
		if err != nil || len(line) == 0 {
			break  // EOF
		}
		
		if len(strings.trim_space(line)) == 0 {
			continue  // Skip empty lines
		}
		
		// Parse and route
		node, ok := cyc.parse(line)
		if !ok {
			continue  // Skip unparseable lines
		}
		
		list, is_list := node.(cyc.List)
		if !is_list || len(list.elements) != 5 {
			continue
		}
		
		mt := list.elements[0]
		formula := list.elements[1]
		
		pred, args, ok := cyc.extract_formula(formula)
		if !ok {
			continue
		}
		
		route_assertion(tx, mt, pred, args)
		assertions_in_batch += 1
		total_assertions += 1
		
		// Batch commit
		if assertions_in_batch >= batch_size {
			if err := r.transaction_commit(tx); err != nil {
				return "commit failed"
			}
			tx = r.transaction_create(world)
			assertions_in_batch = 0
			
			if total_assertions % 10000 == 0 {
				fmt.printf("Loaded %d assertions\n", total_assertions)
			}
		}
		
		// Limit for testing
		if limit > 0 && total_assertions >= limit {
			break
		}
	}
	
	// Final batch commit
	if assertions_in_batch > 0 {
		r.transaction_commit(tx) or_else {
			return "final commit failed"
		}
	}
	
	fmt.printf("Loaded %d assertions total\n", total_assertions)
	return nil
}
```

### Step 4: Testing

**Test Case 1: Load 1000 assertions**
```bash
odin run tools/cycl-load-sample -- \
  --store /tmp/bycycle-test \
  --limit 1000 \
  apps/bycycle/00_schema.mica
```

**Test Case 2: Query loaded assertions**

Add query test to `apps/bycycle/10_loader.mica`:
```
?- Isa(?x, #$Dog, #$BaseKB).
?- Genls(#$Dentist, ?y, #$PeopleDataMt).
?- Comment(#$Fido, ?text, #$BaseKB).
```

## Expected Outcome

- [ ] First 1000 assertions load without error
- [ ] Schema relations created and populated
- [ ] Basic queries execute and return results
- [ ] No parse errors or assertion routing failures
- [ ] Memory usage reasonable (expect ~50-100MB for 1k assertions)

## Debugging Checklist

1. **Schema doesn't load**
   - Check Mica syntax in `00_schema.mica`
   - Verify relation names match predicate routes

2. **Assertions fail to route**
   - Add logging to `route_assertion()` to see which predicates are unhandled
   - Check predicate name mapping (case-sensitive!)

3. **Queries return empty**
   - Verify atoms are stored correctly (check term_to_atom conversion)
   - Ensure Mt constants match (e.g., `#$BaseKB` vs `BaseKB`)

4. **Performance slow**
   - Reduce batch size if memory constrained
   - Check for missing indexes on frequently-queried columns

## Once Step 1 Works

This confirms:
- Parser works on real data ✓
- Mica can hold Mt-scoped relations ✓
- Query execution works ✓

Then proceed to Phase 2: **Full KB Load**
- Increase limit to 100k, then 1M
- Add checkpointing (resume point tracking)
- Profile memory and query performance
- Optimize predicate routing if needed

## Files to Modify

```
tools/cycl-load-sample/main.odin  - Add term_to_atom, route_assertion, load_cycl
apps/bycycle/10_loader.mica        - Add test queries
```

## Reference: Top 20 Predicates

These cover ~80% of assertions. Implement routing for at least these:

| # | Predicate | Count | Relation |
|---|-----------|-------|----------|
| 1 | #$isa | 517k | Isa/3 |
| 2 | #$prettyString | 372k | (display) |
| 3 | #$genls | 195k | Genls/3 |
| 4 | #$broaderTerm | 132k | BroaderTerm/3 |
| 5 | #$comment | 97k | Comment/3 |
| 6 | #$argIsa | 53k | ArgIsa/4 |
| 7 | #$termOfUnit | 48k | TermOfUnit/3 |
| 8 | #$quotedIsa | 35k | QuotedIsa/3 |
| 9 | #$disjointWith | 34k | DisjointWith/3 |
| 10 | #$arity | 26k | Arity/3 |
| 11 | #$arg1Isa | 25k | Arg1Isa/3 |
| 12 | #$genlMt | 25k | GenlMt/3 |
| 13 | #$arg2Isa | 21k | Arg2Isa/3 |
| 14 | #$genlPreds | 10k | GenlPreds/3 |
| 15 | #$argGenl | 7k | ArgGenl/4 |
| 16 | #$argFormat | 7k | ArgFormat/4 |
| 17 | #$resultIsa | 5k | ResultIsa/3 |
| 18 | #$arg2Format | 5k | Arg2Format/3 |
| 19 | #$arg3Isa | 4k | Arg3Isa/3 |
| 20 | #$singleEntryFormatInArgs | 4k | SingleEntryFormatInArgs/3 |

Good luck! 🚀
