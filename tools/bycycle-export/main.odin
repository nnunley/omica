// Exports an OpenCyc (bycycle OWL) store as self-contained benchmark corpora
// that run unchanged on omica (`tools/micabench`) and Rust mica
// (`mica-runner bench`): docs/accel-engine-design.md, "Workloads and
// comparison".
//
// Usage:
//
//	odin run tools/bycycle-export -- --store DIR --out DIR [--subjects N]...
//
// For each subject count N (default 20000, 60000 and every subject), the first
// N subjects by OpenCyc GUID are selected; every row of the rule-relevant
// relations whose subject is selected is exported. Each corpus file holds
// the grant preamble, the bycycle ontology with Rust-compatible rules (no
// `_` in rule bodies), a `setup()` verb that asserts the facts in one
// transaction, and a `bench()` verb:
//
//	bycycle_<N>_rederive.mica  toggles one Isa fact per call: one commit, one
//	                           full rederivation of the closure.
//	bycycle_<N>_query.mica     counts InstanceOf rows of the most populated
//	                           collection plus every InconsistentWith and
//	                           DirectChild row.
package main

import "core:fmt"
import "core:os"
import "core:slice"
import "core:strconv"
import "core:strings"

import k "../../mica/kernel"
import r "../../mica/runtime"
import v "../../mica/var"

USAGE :: "usage: bycycle-export --store DIR --out DIR [--subjects N]...\n"

// The ontology files. The retrieval schema comes first because the bycycle
// files define rules whose heads it declares; omica accepts that forward
// reference but Rust mica compiles declarations in order.
ONTOLOGY :: [?]string {
	"apps/shared/retrieval.mica",
	"apps/bycycle-owl/00_schema.mica",
	"apps/bycycle-owl/10_taxonomy.mica",
	"apps/bycycle-owl/20_constraints.mica",
	"apps/bycycle-owl/30_graph.mica",
}

// Extensional relations the rules read (all binary).
EXPORTED :: [?]string{"Isa", "Genls", "DisjointWith", "QuotedIsa", "TypeGenls", "RewriteOf", "BroaderTerm", "Label"}

// Derived relations the query bench reads.
DERIVED :: [?]string {
	"Subsumes",
	"InstanceOf",
	"DirectChild",
	"IndirectChild",
	"InconsistentWith",
	"QuotedInstanceOf",
	"TypedInstanceOf",
	"Broader",
	"RewrittenTo",
	"TextUnit",
	"TextUnitText",
}

// Rows per list literal in setup(): keeps each statement a manageable size.
CHUNK :: 4096

Subject :: struct {
	value: v.Value,
	guid:  string,
}

main :: proc() {
	store_path, out_dir := "", ""
	counts := make([dynamic]int)
	args := os.args[1:]
	for i := 0; i < len(args); i += 1 {
		switch args[i] {
		case "--store":
			i += 1
			store_path = args[i]
		case "--out":
			i += 1
			out_dir = args[i]
		case "--subjects":
			i += 1
			n, ok := strconv.parse_int(args[i])
			if !ok || n < 1 {
				fmt.eprintf(USAGE)
				os.exit(1)
			}
			append(&counts, n)
		case:
			fmt.eprintf(USAGE)
			os.exit(1)
		}
	}
	if store_path == "" || out_dir == "" {
		fmt.eprintf(USAGE)
		os.exit(1)
	}
	if len(counts) == 0 {
		append(&counts, 20_000, 60_000, max(int))
	}

	kernel: k.Kernel
	k.kernel_init(&kernel)
	defer k.kernel_destroy(&kernel)
	world, start := r.world_start(&kernel, nil, context.allocator, r.World_Config{store_path = store_path})
	if !start.ok {
		fmt.eprintf("failed to open %s: %s\n", store_path, start.message)
		os.exit(1)
	}
	defer r.world_destroy(world)

	// The runtime's name lookup scans every named identity per literal; over
	// a full store's facts that is quadratic, so invert the names once.
	for name, value in world.ctx.identities {
		if identity, ok := v.value_as_identity(value); ok {
			identity_names[identity] = name
		}
	}
	defer delete(identity_names)

	subjects := select_subjects(world)
	fmt.printf("%d subjects with a GUID\n", len(subjects))
	ontology := rust_compatible_ontology()
	os.make_directory(out_dir)
	for n in counts {
		take := min(n, len(subjects))
		label := n == max(int) ? "all" : (n % 1000 == 0 ? fmt.tprintf("%dk", n / 1000) : fmt.tprintf("%d", n))
		if take < n && n != max(int) {
			fmt.eprintf("only %d subjects: %s corpus uses all of them\n", len(subjects), label)
		}
		export_corpus(world, subjects[:take], ontology, out_dir, label)
	}
}

relation_id :: proc(world: ^r.World, name: string) -> (k.Relation_ID, bool) {
	id, ok := world.env.ctx.relations[name]
	return k.Relation_ID(id), ok
}

scan_all :: proc(world: ^r.World, relation: k.Relation_ID, arity: int) -> [dynamic]v.Tuple {
	rows := make([dynamic]v.Tuple)
	k.kernel_scan_into(world.kernel, relation, make([]v.Binding, arity, context.temp_allocator), &rows)
	return rows
}

// Every subject with a GuidOf row, sorted by GUID so the selection is the
// same for any store loaded from the same dump.
select_subjects :: proc(world: ^r.World) -> []Subject {
	guid_of, ok := relation_id(world, "GuidOf")
	if !ok {
		fmt.eprintf("store has no GuidOf relation: not a bycycle store\n")
		os.exit(1)
	}
	rows := scan_all(world, guid_of, 2)
	subjects := make([]Subject, len(rows))
	for row, i in rows {
		values := v.tuple_values(row)
		text, _ := v.value_as_string(values[1])
		subjects[i] = Subject{values[0], strings.clone(text)}
	}
	slice.sort_by(subjects, proc(a, b: Subject) -> bool {return a.guid < b.guid})
	return subjects
}

// Writes a rule line with each standalone `_` replaced by a fresh named
// variable.
write_rule_line :: proc(b: ^strings.Builder, line: string, fresh: ^int) {
	is_word :: proc(c: u8) -> bool {
		return c == '_' || (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == ':' || c == '#' || c == '/'
	}
	for i := 0; i < len(line); i += 1 {
		c := line[i]
		if c == '_' && (i == 0 || !is_word(line[i - 1])) && (i + 1 == len(line) || !is_word(line[i + 1])) {
			fresh^ += 1
			fmt.sbprintf(b, "unused_%d", fresh^)
			continue
		}
		strings.write_byte(b, c)
	}
}

// The ontology files concatenated, with each `_` in a rule body replaced by a
// fresh named variable (Rust mica rejects `_` there).
rust_compatible_ontology :: proc() -> string {
	b: strings.Builder
	strings.builder_init(&b)
	fresh := 0
	for path in ONTOLOGY {
		data, err := os.read_entire_file(path, context.allocator)
		if err != nil {
			fmt.eprintf("cannot read %s (run from the repository root)\n", path)
			os.exit(1)
		}
		fmt.sbprintf(&b, "// --- %s\n", path)
		// A rule is a line containing `:-` plus the indented continuation
		// lines of its body, up to the first one not ending in a comma.
		in_rule := false
		for line in strings.split_lines(string(data)) {
			trimmed := strings.trim_space(line)
			starts_rule := strings.contains(line, ":-")
			if starts_rule || in_rule {
				write_rule_line(&b, line, &fresh)
				// The body continues while the line ends in `:-` or `,`.
				in_rule = strings.has_suffix(trimmed, ":-") || strings.has_suffix(trimmed, ",")
			} else {
				strings.write_string(&b, line)
			}
			strings.write_byte(&b, '\n')
		}
		strings.write_byte(&b, '\n')
	}
	return strings.to_string(b)
}

Exported_Rows :: struct {
	name: string,
	rows: [dynamic][2]string, // source literals
}

export_corpus :: proc(world: ^r.World, subjects: []Subject, ontology: string, out_dir: string, label: string) {
	selected := make(map[v.Value]bool, len(subjects))
	defer delete(selected)
	for s in subjects {
		selected[s.value] = true
	}
	identities := make(map[string]bool)
	defer delete(identities)
	exported := make([dynamic]Exported_Rows)
	isa_counts := make(map[string]int)
	defer delete(isa_counts)
	total := 0
	for name in EXPORTED {
		id, ok := relation_id(world, name)
		if !ok {
			continue
		}
		rows := scan_all(world, id, 2)
		out := Exported_Rows{name = name}
		for row in rows {
			values := v.tuple_values(row)
			if !selected[values[0]] {
				continue
			}
			pair: [2]string
			for value, c in values {
				literal := value_literal(world, value)
				pair[c] = literal
				if v.value_tag(value) == .Identity && strings.has_prefix(literal, "#") {
					identities[literal] = true
				}
			}
			if name == "Isa" {
				isa_counts[pair[1]] += 1
			}
			append(&out.rows, pair)
		}
		total += len(out.rows)
		append(&exported, out)
		delete(rows)
	}
	// The most populated collection anchors the query and the toggled fact.
	top, top_count := "", -1
	for class, count in isa_counts {
		if count > top_count || (count == top_count && class < top) {
			top, top_count = class, count
		}
	}
	item := value_literal(world, subjects[0].value)
	// The rederive bench toggles Isa(item, top); declare both even when the
	// first subject has no exported rows.
	identities[item] = true
	if top != "" {
		identities[top] = true
	}
	fmt.printf("%s: %d subjects, %d rows, %d identities; anchor %s (%d instances)\n", label, len(subjects), total, len(identities), top, top_count)

	body := corpus_body(ontology, exported[:], identities)
	write_corpus(out_dir, label, "rederive", body, fmt.tprintf(
		// Reading a derived relation first makes every commit maintain it: an
		// engine that derives lazily (Rust mica skips maintenance until a
		// derived relation has been read) would otherwise time a bare write.
		"verb bench()\n  let instances = len(InstanceOf(?item, %s))\n  if Isa(%s, %s)\n    retract Isa(%s, %s)\n  else\n    assert Isa(%s, %s)\n  end\n  return instances\nend\n",
		top, item, top, item, top, item, top,
	))
	write_corpus(out_dir, label, "query", body, fmt.tprintf(
		"verb bench()\n  let instances = InstanceOf(?item, %s)\n  let conflicts = InconsistentWith(?item, ?a, ?b)\n  let children = DirectChild(?parent, ?child)\n  return len(instances) + len(conflicts) + len(children)\nend\n",
		top,
	))
	for e in exported {
		delete(e.rows)
	}
	delete(exported)
}

// Identity -> name, built once from the world's names (see main).
identity_names: map[v.Identity]string

// A value's source literal. An identity without a registered name would print
// as its raw id (#17115), which is not valid source; it becomes #anon_17115,
// declared like any other identity the facts reference.
value_literal :: proc(world: ^r.World, value: v.Value) -> string {
	if identity, ok := v.value_as_identity(value); ok {
		if name, named := identity_names[identity]; named {
			return fmt.aprintf("#%s", name)
		}
		return fmt.aprintf("#anon_%d", v.identity_raw(identity))
	}
	return r.world_value_literal(world, value)
}

corpus_body :: proc(ontology: string, exported: []Exported_Rows, identities: map[string]bool) -> string {
	b: strings.Builder
	strings.builder_init(&b)
	strings.write_string(&b, "// Generated by tools/bycycle-export. Shared benchmark grant preamble.\n")
	strings.write_string(&b, "make_identity(:bench)\nmake_relation(:CanInvoke, 2)\nmake_relation(:CanRead, 2)\nmake_relation(:CanWrite, 2)\n\n")
	strings.write_string(&b, ontology)
	strings.write_string(&b, "\n// --- identities referenced by the facts\n")
	names := make([dynamic]string, 0, len(identities))
	defer delete(names)
	for literal in identities {
		append(&names, literal)
	}
	slice.sort(names[:])
	for literal in names {
		fmt.sbprintf(&b, "make_identity(:%s)\n", literal[1:])
	}
	// One verb per chunk of rows: Rust mica caps a method's list item table
	// at u16, which one setup() holding every fact exceeds.
	chunks := 0
	for e in exported {
		chunks += (len(e.rows) + CHUNK - 1) / CHUNK
	}
	strings.write_string(&b, "\ngrant #bench\n  invoke:\n    :bench\n    :setup\n")
	for i in 0 ..< chunks {
		fmt.sbprintf(&b, "    :setup_facts_%d\n", i)
	}
	strings.write_string(&b, "  read:\n")
	for name in EXPORTED {
		fmt.sbprintf(&b, "    :%s\n", name)
	}
	for name in DERIVED {
		fmt.sbprintf(&b, "    :%s\n", name)
	}
	strings.write_string(&b, "  write:\n")
	for name in EXPORTED {
		fmt.sbprintf(&b, "    :%s\n", name)
	}
	strings.write_string(&b, "end\n\n// --- facts, asserted once in one transaction\n")
	chunk := 0
	for e in exported {
		for start := 0; start < len(e.rows); start += CHUNK {
			end := min(start + CHUNK, len(e.rows))
			fmt.sbprintf(&b, "verb setup_facts_%d()\n", chunk)
			chunk += 1
			strings.write_string(&b, "  for row in [")
			for pair, i in e.rows[start:end] {
				if i > 0 {
					strings.write_string(&b, ", ")
				}
				fmt.sbprintf(&b, "[%s, %s]", pair[0], pair[1])
			}
			fmt.sbprintf(&b, "]\n    assert %s(row[0], row[1])\n  end\nend\n\n", e.name)
		}
	}
	strings.write_string(&b, "verb setup()\n")
	for i in 0 ..< chunks {
		fmt.sbprintf(&b, "  setup_facts_%d()\n", i)
	}
	strings.write_string(&b, "end\n\n")
	return strings.to_string(b)
}

write_corpus :: proc(out_dir, label, kind, body, bench: string) {
	path := fmt.tprintf("%s/bycycle_%s_%s.mica", out_dir, label, kind)
	text := strings.concatenate({body, bench})
	defer delete(text)
	if err := os.write_entire_file(path, transmute([]u8)text); err != nil {
		fmt.eprintf("cannot write %s\n", path)
		os.exit(1)
	}
	fmt.printf("wrote %s (%d bytes)\n", path, len(text))
}
