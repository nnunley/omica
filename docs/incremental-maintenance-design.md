# Incremental maintenance of derived relations

Status: draft revised after pushback review, 2026-09-25. For review by Ryan
(storage sections 3 and 9 in particular).

## Why

Every commit recomputes every derived relation from scratch.
`transaction_build_candidate` (`mica/kernel/transaction.odin:1077`) applies the
transaction's writes to a fork of the current snapshot and calls
`kernel_compute_derived`, which runs the full rule fixpoint over the whole
store and copies the result into the new snapshot
(`snapshot_compute_derived`, `mica/kernel/snapshot.odin`).

On the OpenCyc corpus (870k facts, 17.9M derived rows) a commit that toggles
one `Isa` fact takes 12-18 s and peaks at 5.5-6.2 GB (M3 Mac and ndn, after the
memory and sort fixes of 2026-09-25; it was 25 s before them). The fixpoint
itself (joins, dedup inserts, hashing) is most of that time, and GPU strategies
change nothing (only negated membership is offloaded). The work is proportional
to the whole closure, not to the change.

Rust mica maintains derived relations incrementally with differential dataflow
once a derived relation has been read; its rederive bench runs in 13.7 ms at
20k subjects against omica's 27 ms (ndn). The same one-fact commit should cost
omica time proportional to the rows it affects.

## Scope

In scope:

- storing derived relations as relation blocks, shared between snapshots and
  indexed like extensional relations (section 3);
- maintaining a commit's derived relations from the parent's and the commit's
  net fact changes: positive and recursive rules (delete and rederive) and
  stratified negation;
- computed relations that declare what they read, so their changes can be
  traced (section 5);
- maintaining a transaction's private derived view (read-your-writes);
- persisting derived blocks with a rule-set fingerprint, so boot restores them
  and replays the log through maintenance instead of re-deriving;
- a fallback to the full fixpoint for every case maintenance does not handle,
  decided per commit, and a verification plan that extends the existing tests.

Out of scope: lazy maintenance (derive on first read, as Rust does);
aggregation and non-monotone constructs beyond stratified negation; a
device-resident GPU fixpoint and operator fusion (separate designs).

## Terms

- **Base** `P`: the parent snapshot, whose derived relations are complete.
- **Change set**: per relation, the rows a commit adds (`Δ⁺R`) and removes
  (`Δ⁻R`), net of no-ops: asserting a row `P` holds, or retracting one it lacks,
  changes nothing. Functional relations reject a conflicting assert
  (`Functional_Key_Violation`), so every removal is an explicit retract.
- **Old** and **new**: a relation's rows in `P` and in the commit's result.
- **Derivation**: one binding of a rule body that produces a head row.

## Design

### 1. When maintenance applies

`kernel_compute_derived` takes the maintained path when all hold:

1. `P` has complete derived relations (derivation was not suspended when `P`
   was published);
2. the fork's rule set and catalog equal `P`'s (no rule installed, removed,
   enabled or disabled, no relation created);
3. the work stays under the threshold (section 8);
4. the commit reaches `kernel_compute_derived` through
   `transaction_build_candidate` or `transaction_rebase_in_place`, with a
   change set computed against the snapshot it is built on.

Every other path (rule installs, `kernel_set_derivation`, a boot whose
fingerprint does not match, buffer commits that touch no declared dependency,
catalog changes) keeps the full fixpoint. `kernel_derivation_count` gains a
split: maintained, full, and aborted-to-full.

### 2. The change set

The transaction's `Relation_Writes` entries (`transaction.odin:36`) list staged
asserts and retracts per relation. After `transaction_prepare_writes` compacts
them, the change set is computed against `P`'s block and cleaned of no-ops. On a
rebase it is recomputed against the new base. Buffer writes enter the change
set as changes to the buffers they touch, for computed relations that declare
them (section 5). Relations no rule or computed relation reads are ignored.

### 3. Derived relations as blocks

Stored derived rows today are one sorted `[]Tuple` per relation in the
snapshot's frame arena (`Derived_Relation`, `snapshot.odin:18`). Every bound
lookup is a linear scan (`source.odin:138-152`, `:218-230`), and every commit
copies every derived row. Delta evaluation needs indexed access (step 2 of
section 6 binds heads to candidates), so derived relations become
`Relation_Block`s, the structure extensional relations already use: chunks,
lazily built secondary indexes (`49df67d`), copy-on-write sharing between
snapshots.

- **A separate list.** Derived blocks live in their own list on the snapshot
  (for example `snapshot.derived_blocks`), never in `snapshot.blocks`. The
  extensional checkpoint, the log and restore only see `snapshot.blocks`, so
  they cannot write or restore a derived row as a fact. A relation with both
  asserted and derived rows reads both lists, as it reads both kinds today.
- **Publishing** applies each derived relation's net change with
  `relation_block_apply` (the path commits use for facts), so a commit costs
  the chunks it changes; unchanged relations are shared, not copied.
- **Full derivation** (the fallback and stage 1) builds blocks from the
  fixpoint result instead of `[]Tuple`.
- **Readers.** `snapshot_derived_rows`, the scan paths in `source.odin`,
  `packed.odin:241`, `transaction.odin:711-736` and `snapshot_contains` read
  derived blocks.

### 4. Strata and affected rules

`rules_stratify` (`rules.odin:249`) orders rules so negated atoms read a lower
stratum. Maintenance walks strata in order. A stratum is affected when one of
its rules reads a relation with a non-empty change: extensional, derived by a
lower stratum, or computed with a changed dependency (section 5). An
unaffected stratum's blocks carry over from `P`.

### 5. Computed relations declare what they read

`kernel_register_computed_relation` takes a dependency declaration: the
relations and buffers the scanner reads, or **volatile** when it depends on
anything else (time, external services). A computed relation counts as changed
when any declared dependency changed; volatile ones count as changed on every
commit. A changed computed relation's rows are rescanned for the keys the
affected rules bind, or its reading stratum is recomputed in full.

The declaration is enforced: computed scanners read through
`Relation_Source`, and in tests and under the debug cross-check (section 10)
the kernel records every relation and buffer a scanner touches and fails on an
undeclared one. The two current computed relations declare:
NearestEmbedding reads `VectorIndexContains`, `EmbeddingOf` and
`EmbeddingVector`; the buffer statistics read their buffer.

### 6. Positive strata: delete and rederive (DRed)

For an affected stratum with positive rules, given the changes `Δ⁺`, `Δ⁻` to
the relations it reads:

1. **Over-delete.** Compute every head row with at least one derivation that
   uses a removed row, against the old state: for each rule and each body atom
   whose relation lost rows, evaluate the rule with that atom restricted to the
   removed rows and the others reading old rows. Head rows found are
   candidates for deletion. For recursive rules the candidates are removed rows
   of the head relation and feed the next round, until no new candidates
   appear. This reuses the semi-naive machinery: `Relation_Source.delta` with
   `delta_active` per atom occurrence (`rules.odin:450-480`).
2. **Rederive.** A candidate stays if it still has a derivation in the new
   state: evaluate each rule with its head bound to the candidates and every
   body atom reading the new state (old rows minus candidates, plus
   insertions). Restored rows can support other candidates, so this iterates.
   The derived blocks' secondary indexes make the bound lookups cheap.
3. **Insert.** Semi-naive rounds seeded with the added rows (`Δ⁺` of the inputs
   and restored rows not in the old head), reading the new state, until no
   round adds a row.

The stratum's net change is `removed = candidates − restored` and
`added = inserted − old`, the input to higher strata. An insert-only commit
skips steps 1 and 2.

### 7. Negation

A negated atom `not R(...)` reads a lower stratum, so `R`'s change is known
first, and it acts in reverse: rows added to `R` produce over-delete candidates
(evaluate with the negated atom replaced by a positive atom restricted to
`Δ⁺R`, against the old state); rows removed from `R` seed insertion (restricted
to `Δ⁻R`, against the new state). In the bycycle rules `DirectChild` negates
`IndirectChild`; an `Isa` toggle changes neither, so both strata are skipped.

### 8. Threshold

Maintenance proceeds while the change set plus over-delete candidates stays
under a fraction of all derived rows, initially 5%. The attempt checks the
count as candidates grow and aborts to the full fixpoint as soon as it crosses,
so the worst case is the full fixpoint plus about 5%. Stage 9 tunes the
fraction from measurements.

### 9. Transaction views

A transaction that reads a derived relation after writing
(`transaction_evaluate_derived`, `transaction.odin:723-765`) maintains a
private view instead of running the full fixpoint: the change set is the
transaction's staged writes against its base, the old view is the base's
derived blocks, and the result is an overlay the transaction discards, or
reuses as the commit's derived change when it publishes without a rebase.
`transaction.derived_valid` keeps its meaning: writes invalidate the view, and
the next read maintains it from the previous view.

### 10. Persisting derived blocks

A checkpoint writes the derived block list in its own section, in the same
chunk and page format as extensional blocks, tagged with a **rule-set
fingerprint**: the active rules' sources and enabled flags, the catalog shape
of every relation they read, the computed relations' dependency declarations,
and a format version. Facts and derived blocks are written at the same version.

On boot, a matching fingerprint restores the derived blocks and replays the
log tail through maintenance, commit by commit; a mismatch (or a missing
section) runs the full derivation as today. Derived rows are never written
through the fact path, so a restore cannot turn them into facts.

**Volatile inputs are never restored from.** A volatile relation
(`Relation_Durability.Volatile`) is not persisted, and a volatile computed
relation (section 5) has no checkpoint-time value, so a derived relation that
depends on either, through rules at any depth, can be wrong after a reopen
even though every fingerprint input matches: with `D(x) :- V(x)` and volatile
`V`, a checkpoint of a non-empty `V` reopened with no log tail would restore a
non-empty `D` over an empty `V`. The checkpoint therefore omits the derived
blocks of every relation whose dependency closure (over active rules, and
computed relations' declared dependencies) reaches a volatile relation or a
volatile computed relation, and boot recomputes those strata after restoring
the rest. The dependency closure uses the same rule graph as `rules_stratify`;
relations' durability flags are part of the fingerprint's catalog shape.

Ryan is planning on-disk columnar storage; this section deliberately reuses
the existing chunk/page format so that whatever layout replaces it for facts
applies to derived blocks unchanged. Rust mica offers no precedent: its store
is Fjall (tuples as keys), its relations are in-memory versioned radix trees,
and its maintained state is not persisted.

### 11. Verification

Coverage extends the tests that already exist rather than adding parallel
ones:

| Risk | Test extended |
|---|---|
| Maintenance vs full recomputation | `test_rule_programs_match_oracle` / `test_property_rule_programs`: random commit sequences (inserts, deletes, toggles, mixed) over the existing random programs, compared with a full derivation after each commit |
| Boot oracle | the same property test gains checkpoint-and-reopen at random points, with and without a log tail |
| Derived section round trip; no derived row restored as a fact | `test_checkpoint_round_trip` |
| Crash between checkpoint sections | `test_file_wal_truncated_tail`, `test_file_checkpoint_survives_chunk_reuse` |
| Fast boot vs fallback | `test_run_store_boot_derives_once`: 0 derivations on a matching fingerprint, 1 on a mismatch |
| Fingerprint inputs | one new table-driven test: changing each input forces a full derivation |
| Volatile dependencies | the same table-driven test: `D(x) :- V(x)` with volatile `V` (and a volatile computed relation) checkpointed non-empty and reopened with no log tail yields empty `D`, recomputed rather than restored |
| Computed dependencies | the read-tracking check runs under the existing NearestEmbedding and buffer tests |
| Transaction views | `test_transaction_derived_invalidation`, `test_scan_columns_transaction_overlay_and_derived_layers` |
| Negation, rule disable, rebase | `test_stratified_negation_updates_with_facts`, `test_disable_rule_removes_derived_facts`, `test_kernel_whole_rebase_records_delta_against_winner` (their commits become maintained) |

Stage 1 also folds `test_derived_relations_from_is_canonical_rows` into
`test_derived_relations_from_matches_canonicalize`, which covers it.

A **debug cross-check** (a kernel flag, on in the suite) recomputes after every
maintained commit and every fingerprint-matched boot and panics on a
difference. **Measurement**: the bycycle rederive and query benches (20k, 60k,
full) on the Mac and ndn beside Rust mica, one short run per build.

## Stages

Each stage ships on its own with the suite green.

| Stage | Content | Done when |
|---|---|---|
| 1 | Derived relations as a separate block list: full derivation writes blocks, readers use them, unchanged relations shared | Suite green; per-commit copy of unchanged derived rows gone |
| 2 | Change set, eligibility check, counters, the random-commit oracle harness (full vs full) | Harness in the suite; every commit reports full |
| 3 | Insert-only maintenance (section 6, step 3) | Oracle passes on insert-only sequences; bycycle asserts maintained |
| 4 | Deletions: over-delete and rederive | Oracle passes on mixed sequences; rederive bench maintained both ways |
| 5 | Stratified negation | Oracle passes with negation |
| 6 | Computed-relation dependency declarations and read tracking | Existing computed tests pass under enforcement |
| 7 | Transaction views | Transaction tests maintained; no full fixpoint on read-after-write |
| 8 | Persisted derived blocks, fingerprint, boot through maintenance | Boot oracle and fingerprint tests pass; full-store open no longer re-derives |
| 9 | Threshold tuning; measurements beside Rust mica; spec update | Numbers recorded |

## Risks

- **Correctness.** DRed is subtle under recursion and negation. The oracle over
  random commit sequences, the boot oracle and the debug cross-check are the
  guard; the fallback keeps unsupported shapes correct by construction.
- **Over-deletion near roots** is capped by the threshold abort (section 8).
- **Undeclared computed reads** would leave stale rows; read tracking turns them
  into test failures (section 5).
- **Persistence.** A stale fingerprint or a torn checkpoint would survive
  reboots; the fingerprint covers every input, facts and derived blocks share a
  version, crash tests cover the sections, and derived relations with volatile
  inputs are recomputed at boot instead of restored (sections 10, 11).
- **Rebase.** A commit that loses a publication race recomputes its change set
  against the new base, or falls back.

## Open questions

1. **Storage (for Ryan).** Derived blocks reuse the extensional chunk format
   in memory and on disk (sections 3 and 10). Does that fit the columnar
   storage he plans, and should derived relations be the first user of it?
2. **Canonical order.** Nothing found so far requires derived rows sorted
   beyond what blocks already keep; confirm with the readers in section 3.
3. **Lazy versus eager.** Omica stays eager (every derived relation current at
   commit); lazy maintenance could follow.
