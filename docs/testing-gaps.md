# Testing Gap Matrix

This document records test coverage across the port. It lists the surface
tests cover, the surface tests do not cover, and the priority of each gap.
Update this document when a test closes a gap.

## Scope

- Repository: `mica-odin`
- Packages: `mica/var`, `mica/kernel`, `mica/vm`, `mica/compiler`, `mica/runtime`
- Tests at this revision: 37 in `mica/var`, 64 in `mica/kernel`, 20 in
  `mica/vm`, 58 in `mica/compiler`, 73 in `mica/runtime`, 8 in `mica/dom`,
  29 in `host/web`
- Base revision: `5cb9e73`. Port work continues through the subscription and
  reflection commit.
- Date: 2026-09-11

Run the tests:

```sh
odin test mica/var
odin test mica/kernel
odin test mica/vm
odin test mica/compiler
odin test mica/runtime
```

Run the filein driver against the corpus:

```sh
odin run tools/filein -- apps/shared/string.mica apps/shared/events.mica \
  apps/shared/retrieval.mica apps/shared/sync-host.mica apps/shared/sync-dom.mica \
  apps/mud/core.mica apps/mud/auth.mica apps/mud/command-parser.mica \
  apps/mud/event-substitutions.mica apps/mud/ui-session.mica \
  apps/mud/ui-actions.mica apps/mud/ui-compose.mica apps/mud/ui-narrative.mica \
  apps/mud/ui-mica-inspect.mica apps/mud/ui-retrieval.mica apps/mud/http.mica
```

Run the microbenchmarks:

```sh
odin run benchmarks -o:speed
odin run benchmarks -o:speed -- -suite=var -filter=string
odin run benchmarks -o:speed -- -save=baseline.tsv
odin run benchmarks -o:speed -- -baseline=baseline.tsv
```

## Legend

Status values:

- **Covered**: a test asserts the contract of the surface.
- **Indirect**: a higher-level test reaches the surface, but no test asserts its
  own contract.
- **Missing**: no test reaches the surface.
- **Dead**: the surface has no caller and no behaviour to test.

Priority values:

- **P0**: a defect here gives wrong data or wrong query results.
- **P1**: a defect here stops a class of operations or hides a semantic error.
- **P2**: a defect here causes a narrow failure or a bad error message.
- **P3**: a defect here is cosmetic or tooling-only.

## Summary

| Area | Status | Main gap | Priority |
| --- | --- | --- | --- |
| `var`: value core | Covered | mixed arithmetic arms are partly untested | P3 |
| `var`: numeric semantics | Partial | mixed add, subtract, and multiply arms lack tests | P3 |
| `var`: language comparison | Covered | none | - |
| `var`: symbols | Covered | none | - |
| `var`: tuples and bindings | Covered | none | - |
| `var`: heap collections | Covered | none | - |
| `var`: canonical ordering | Covered | none | - |
| `var`: display | Covered | none | - |
| `var`: deep copy | Covered | none | - |
| `kernel`: relation metadata | Partial | `Relation_Durability` and `Conflict_Kind.Event_Append` are recorded as catalog facts but have no storage behaviour | P2 |
| `kernel`: tuple store and indexes | Covered | none | - |
| `kernel`: snapshot lifecycle | Covered | `test_snapshot_chain_stays_bounded`, `test_committed_history_is_reclaimed`; retired snapshots drain and arena count stays flat | - |
| `kernel`: transactions | Covered | event append is a semantic gap | P2 |
| `kernel`: rules | Covered | `test_rule_planner_prefers_selective_atom`, `test_property_rule_programs` | greedy bound-count/size planning, no selectivity model | P3 |
| `kernel`: dispatch | Covered | none | - |
| `kernel`: closure | Covered | none | - |
| `kernel`: kernel API | Covered | none | - |
| `kernel`: concurrency | Covered | write commits prepare in parallel and publish in groups; parallel disjoint writes now beat serial; commit retries rebuild the candidate 8 times before reporting conflict; `benchmarks/kernel_concurrent_bench.odin` compares parallel and serial disjoint and contended commit batches | P3 |
| `kernel`: reclamation and COW | Covered | chunk capacity is fixed; very large or very small deltas may want tuning | P3 |
| `vm`: program and ops | Covered | `test_vm_dispatch_opcode` builds dispatch facts directly and asserts resolution and ambiguity; call depth and instruction budget are covered | - |
| `compiler`: lexer and parser | Covered | 38-file corpus parses end to end | - |
| `compiler`: emitter | Covered | unsupported forms (bare splices, stray patterns) are named errors; no known language form is left unlowered | - |
| `runtime`: filein driver | Covered | multi-file, builtins, dispatch, match, and DOM have end-to-end tests | - |
| `runtime`: scheduler and tasks | Covered | task resume, sleep, yield, spawn, cancel, mailboxes, and external requests have tests | - |
| `runtime`: authority | Covered | `test_authority_minted_from_policy_facts`, `test_vm_authority_denies_and_root_allows`, `test_run_authority_grants`, `test_run_authority_denies_unlisted` | `grant` blocks are expanded at load time | P3 |
| `runtime`: capability passing | Covered | `test_capability_store_revoke_and_expiry`, `test_authority_adopts_revocable_capability`, `test_run_capability_passing`, `test_run_capability_denied_without_adoption`, `test_run_capability_multi_revoke_and_expiry` | no codec/durability; no cross-world transfer | P2 |
| `kernel`: change feed | Covered | `test_change_feed_window_and_resync` | bounded window; subscribers older than the window resynchronize from a snapshot | P3 |
| `runtime`: subscriptions | Covered | `test_run_subscription_changes`, `test_run_subscription_snapshot_and_close`, `test_run_subscription_relation_derived`, `test_run_subscription_catalogue`, `test_run_subscription_queue_budget`, `test_run_subscription_revoked_marker`, `test_run_subscription_catalogue_needs_root` | `:facts`, `:relation`, and `:catalogue` subjects; queue budget, resynchronize, and revoked markers | - |
| `runtime`: grant blocks | Covered | `test_run_authority_grants` | grant targets must be symbols; `effect` takes no targets | - |
| `mica/dom`: sync DOM codec and diff | Covered | `dom_test.odin`, `diff.odin` tests | exact Rust-compatible JSON fixtures; tag and attribute validation; text, attr, child, and keyed diffs | - |
| `host/web`: HTTP, documents, sync, and auth | Covered | `http_test.odin`, `server_test.odin`, `response_test.odin`, `documents_test.odin`, `sync_protocol_test.odin`, `sync_test.odin`, `auth_test.odin`; logging in as alice streams the MUD game view, `/mud` serves 200, and a relation change streams a delta | a real browser check is manual; user creation and OAuth are disabled; per-session authority is not minted | P2 |
| Methodology | Partial | no differential test against Rust mica | P1 |

---

## `mica/var`

### Value core (`value.odin`)

| Surface | Status | Covered by | Gap | Priority |
| --- | --- | --- | --- | --- |
| `value_int`, `INT_MIN`, `INT_MAX` | Covered | `int_range_and_sign_roundtrip` | none | - |
| `value_float`, finiteness, zero | Covered | `float_rejects_non_finite_and_canonicalizes_zero` | none | - |
| `value_float_from_bits` | Covered | `value_float_from_bits` | none | - |
| `value_bool`, `value_as_bool` | Indirect | `display_all_kinds` | no direct round trip test | P3 |
| `value_identity`, `value_as_identity` | Covered | `bytes_range_error_frob_round_trip` | none | - |
| `value_identity_raw` | Covered | `capability_and_function_ids` | none | - |
| `value_capability`, `value_as_capability` | Covered | `capability_and_function_ids` | none | - |
| `value_function`, `value_as_function` | Covered | `capability_and_function_ids` | none | - |
| `value_symbol`, `value_as_symbol` | Covered | `symbols_intern_stably` | none | - |
| `value_error_code`, `value_as_error_code` | Covered | `bytes_range_error_frob_round_trip` | none | - |
| `value_kind`, `value_tag`, `value_payload` | Covered | `deep_copy_is_independent`, property tests | none | - |
| `value_is_immediate` | Covered | `value_is_immediate` | none | - |
| `value_is_empty_relation` | Covered | `empty_and_unit_relations` | none | - |
| `primitive_prototype_for_kind` | Covered | `primitive_prototypes` | none | - |
| `value_checked_add` | Covered | `checked_arithmetic` | none | - |
| `value_checked_sub` | Covered | `checked_sub_rem_neg` | none | - |
| `value_checked_mul` | Covered | `checked_arithmetic` | none | - |
| `value_checked_div` | Covered | `checked_arithmetic`, `division_edges` | none | - |
| `value_checked_rem` | Covered | `checked_sub_rem_neg` | none | - |
| `value_checked_neg` | Covered | `checked_sub_rem_neg` | none | - |
| float overflow to infinity | Covered | `float_overflow_rejected` | none | - |
| mixed int and float arithmetic | Partial | `checked_arithmetic`, `checked_sub_rem_neg` | several operand pairs are untested | P3 |
| `value_error_code_symbol` | Covered | `bytes_range_error_frob_round_trip` | none | - |

### Language comparison (`language_cmp.odin`)

| Surface | Status | Covered by | Gap | Priority |
| --- | --- | --- | --- | --- |
| `language_numeric_eq`, int and float | Covered | `canonical_equality_separates_numeric_kinds` | none | - |
| `language_numeric_cmp`, int and float | Covered | `mixed_numeric_comparison_is_exact` | none | - |
| `language_compare_int_float`, bounds | Covered | `language_compare_int_float_bounds` | none | - |
| negative fractional comparison | Covered | `language_compare_int_float_bounds` | none | - |
| non-numeric fallback to canonical order | Covered | `language_numeric_non_numeric_fallback` | none | - |

### Symbols (`symbol.odin`)

| Surface | Status | Covered by | Gap | Priority |
| --- | --- | --- | --- | --- |
| `symbol_intern`, id stability | Covered | `symbols_intern_stably` | none | - |
| `symbol_name` | Covered | `symbols_intern_stably` | none | - |
| unknown symbol id | Covered | `symbol_edge_names` | none | - |
| empty name and unicode name | Covered | `symbol_edge_names` | none | - |
| `symbol_from_id` | Covered | `symbol_edge_names`, `display_all_kinds` | none | - |

### Tuples and bindings (`tuple.odin`)

| Surface | Status | Covered by | Gap | Priority |
| --- | --- | --- | --- | --- |
| `tuple_new`, `tuple_arity`, `tuple_values` | Covered | `tuple_operations` | none | - |
| `tuple_select`, `tuple_concat` | Covered | `tuple_operations` | none | - |
| `tuple_matches_bindings` | Covered | `tuple_operations` | none | - |
| `tuple_eq` | Covered | `tuple_cmp_ordering` | none | - |
| `tuple_cmp` | Covered | `tuple_cmp_ordering` | none | - |
| `binding_of`, full bindings | Covered | `tuple_operations` | none | - |
| `binding_first_unbound` | Covered | `binding_helpers` | none | - |
| `binding_leading_bound_count` | Covered | `binding_helpers`, `metadata_helpers` | none | - |

### Heap values (`heap.odin`)

| Surface | Status | Covered by | Gap | Priority |
| --- | --- | --- | --- | --- |
| `value_string`, `value_as_string` | Covered | `display_formatting` | none | - |
| `value_bytes`, `value_as_bytes` | Covered | `bytes_range_error_frob_round_trip` | none | - |
| `value_list`, `value_as_list` | Covered | `display_formatting`, `value_cmp_is_a_total_order` | none | - |
| `value_map`, `value_as_map` | Covered | `map_canonicalization_keeps_last_duplicate`, `map_and_relation_equality` | none | - |
| `value_relation`, `value_as_relation` | Covered | `relation_canonicalizes_heading_rows_and_duplicates`, `map_and_relation_equality` | none | - |
| `value_range`, `value_as_range` | Covered | `bytes_range_error_frob_round_trip` | none | - |
| `value_error`, `value_as_error` | Covered | `bytes_range_error_frob_round_trip` | none | - |
| `value_frob`, `value_frob_delegate`, `value_frob_value` | Covered | `bytes_range_error_frob_round_trip` | none | - |
| `value_is_persistable` | Covered | `value_is_persistable` | none | - |

### Canonical comparison (`compare.odin`)

| Surface | Status | Covered by | Gap | Priority |
| --- | --- | --- | --- | --- |
| `value_eq`, int and float | Covered | `canonical_equality_separates_numeric_kinds` | none | - |
| `value_cmp`, different kinds | Covered | `value_cmp_is_a_total_order` | none | - |
| `value_cmp`, heap kinds | Covered | `heap_ordering`, `value_cmp_orders_heap_kinds_consistently` | none | - |
| range end and error option order | Covered | `heap_ordering` | none | - |

### Display (`display.odin`)

| Surface | Status | Covered by | Gap | Priority |
| --- | --- | --- | --- | --- |
| identity, symbol, string | Covered | `display_formatting` | none | - |
| list | Covered | `display_formatting` | none | - |
| map, range, error, bytes, frob, capability, function | Covered | `display_all_kinds` | none | - |
| error code, unnamed symbol, relation, unit, empty relation | Covered | `display_all_kinds` | none | - |
| `value_to_debug_string` | Covered | `display_formatting`, `debug_nested_forms` | none | - |
| float formatting | Covered | `display_float_format` | the form can differ from Rust `Display` | P3 |

### Deep copy (`copy.odin`)

| Surface | Status | Covered by | Gap | Priority |
| --- | --- | --- | --- | --- |
| `tuple_deep_copy`, string cell | Covered | `transaction_owns_asserted_values`, `deep_copy_is_independent` | none | - |
| `value_deep_copy`, list | Covered | `deep_copy_is_independent` | none | - |
| `value_deep_copy`, map | Covered | `deep_copy_is_independent` | none | - |
| `value_deep_copy`, relation | Covered | `deep_copy_is_independent` | none | - |
| `value_deep_copy`, error and frob | Covered | `deep_copy_error_and_frob` | none | - |
| copy independence | Covered | `deep_copy_is_independent` | none | - |

---

## `mica/kernel`

### Relation metadata (`relation.odin`)

| Surface | Status | Covered by | Gap | Priority |
| --- | --- | --- | --- | --- |
| `relation_metadata` defaults | Covered | `metadata_defaults` | none | - |
| `metadata_with_indexes` | Indirect | `secondary_index_scan_returns_matching_rows` | none | - |
| `metadata_with_conflict` | Indirect | functional relation tests | none | - |
| `metadata_clone` | Covered | `metadata_helpers` | none | - |
| `metadata_argument_name` | Covered | `metadata_helpers` | none | - |
| `validate_relation_metadata` | Covered | `create_relation_rejects_duplicates_and_invalid_metadata` | none | - |
| `conflict_set`, `conflict_functional` | Indirect | transaction tests | none | - |
| `conflict_event_append` | Dead | none | the policy has no storage behaviour and no source declaration reaches it | P2 |
| `Relation_Durability` | Covered | `test_run_relation_reflection_facts` | recorded as `RelationDurability` facts; no storage effect | P2 |
| `index_is_natural_full_tuple` | Covered | `metadata_helpers` | none | - |
| `index_leading_bound_count` | Covered | `metadata_helpers` | none | - |
| `relation_id_raw` | Dead | none | no caller | P3 |

### Tuple store and indexes (`store.odin`)

| Surface | Status | Covered by | Gap | Priority |
| --- | --- | --- | --- | --- |
| `relation_block_build` sort and dedupe | Covered | `store_search_paths_match_linear_filter` | none | - |
| `relation_block_contains` | Indirect | retract tests | no direct test | P3 |
| `relation_block_visit`, full scan | Covered | `store_search_paths_match_linear_filter` | none | - |
| `relation_block_visit`, fully bound lookup | Covered | `store_search_paths_match_linear_filter` | none | - |
| primary leading prefix | Covered | `store_search_paths_match_linear_filter` | none | - |
| secondary index prefix | Covered | `secondary_index_scan_returns_matching_rows`, `store_search_paths_match_linear_filter` | none | - |
| non-contiguous bound positions | Covered | `store_search_paths_match_linear_filter` | none | - |
| index on position 0 only | Covered | `store_search_paths_match_linear_filter` | none | - |
| multiple secondary indexes | Covered | `store_search_paths_match_linear_filter` | none | - |
| visit stop semantics | Covered | `store_search_paths_match_linear_filter` | none | - |
| `relation_block_tuple_for_key` | Indirect | functional key tests | no direct test | P3 |
| `relation_block_scan_into` | Covered | `store_search_paths_match_linear_filter` | none | - |

### Snapshot lifecycle (`snapshot.odin`)

| Surface | Status | Covered by | Gap | Priority |
| --- | --- | --- | --- | --- |
| `snapshot_create`, `snapshot_fork` | Covered | `snapshot_fork_and_version_inheritance` | none | - |
| `snapshot_retain`, `snapshot_release` | Covered | `snapshot_retain_release_keeps_old_version_readable` | none | - |
| old version read after commit | Covered | `snapshot_retain_release_keeps_old_version_readable` | none | - |
| `snapshot_relation_metadata` | Indirect | transaction tests | none | - |
| `snapshot_relation_metadata_named` | Covered | `snapshot_metadata_lookup_by_name` | none | - |
| `snapshot_has_relation` | Indirect | `create_relation` | none | - |
| `snapshot_relation_block`, `snapshot_set_block` | Covered | `snapshot_fork_and_version_inheritance` | none | - |
| `snapshot_contains`, `snapshot_contains_extensional` | Covered | `snapshot_retain_release_keeps_old_version_readable` | none | - |
| `snapshot_visit_extensional` | Indirect | rule and scan tests | none | - |
| `snapshot_tuple_for_key` | Covered | `snapshot_fork_and_version_inheritance` | none | - |
| `snapshot_derived_rows`, `snapshot_compute_derived` | Covered | rule tests | the rule error path is not tested | P2 |
| `snapshot_add_relation`, `snapshot_add_rule` | Indirect | kernel tests | none | - |
| `snapshot_set_derived` | Dead | none | no caller | P3 |
| chain depth and memory growth | Covered | `kernel/closure/large` and `kernel/mem/growth` benches in `benchmarks/kernel_large.odin` | the closure walk is linear in chain length; the memory bench reports the per-run VmHWM delta for a growing relation (closes the memory-growth gap; see the script header for the run-order caveat) | P1 |

### Transactions (`transaction.odin`)

| Surface | Status | Covered by | Gap | Priority |
| --- | --- | --- | --- | --- |
| `transaction_begin`, `transaction_destroy` | Covered | `transaction_derived_invalidation` | none | - |
| `transaction_assert`, `transaction_retract` | Covered | `transaction_assert_retract_and_read_your_writes` | none | - |
| read-your-own-writes | Covered | `transaction_assert_retract_and_read_your_writes` | none | - |
| write last-kind-wins | Covered | `transaction_write_last_kind_wins` | none | - |
| rebase onto a newer version | Covered | `transaction_rebase_merges_non_conflicting_writes` | none | - |
| set conflict | Covered | `transaction_set_conflict_detects_concurrent_retract` | none | - |
| functional key violation | Covered | `functional_relation_key_violation_and_replacement` | none | - |
| functional key conflict | Covered | `functional_relation_conflict_on_key_change` | none | - |
| event append conflict | Dead | none | the policy never conflicts | P2 |
| unknown relation | Covered | `transaction_error_matrix` | none | - |
| arity mismatch | Covered | `transaction_error_matrix` | none | - |
| non-persistable value | Covered | `transaction_error_matrix` | none | - |
| read-only transaction | Dead | none | `read_only` is always false | P3 |
| derived facts in a transaction | Covered | `transitive_rule_derives_reachable` | none | - |
| derived invalidation after a write | Covered | `transaction_derived_invalidation` | none | - |
| empty transaction commit | Covered | `empty_commit_and_idempotent_writes` | none | - |
| idempotent assert and retract | Covered | `empty_commit_and_idempotent_writes` | none | - |
| retract when the base lacks the tuple | Covered | `retract_ignores_tuple_absent_from_base` | none | - |
| conflicts across several relations | Covered | `conflict_in_one_relation_rolls_back_the_others` | none | - |
| arena transfer on commit | Indirect | `transaction_owns_asserted_values` | none | - |

### Rules (`rules.odin`)

| Surface | Status | Covered by | Gap | Priority |
| --- | --- | --- | --- | --- |
| `rule_new`, `atom_positive`, `body_atom` | Indirect | all rule tests | none | - |
| `atom_negated`, `body_guard` | Indirect | negation and guard tests | none | - |
| `rule_validate_safety`, unsafe negation | Covered | `unsafe_and_unstratified_rules_are_rejected` | none | - |
| unstratified negation | Covered | `unsafe_and_unstratified_rules_are_rejected` | none | - |
| unsafe guard | Covered | `rule_validation_errors` | none | - |
| unbound head variable | Covered | `rule_validation_errors` | none | - |
| rule atom and head arity | Covered | `rule_rejects_atom_and_head_arity_mismatch` | none | - |
| single stratum evaluation | Covered | many rule tests | none | - |
| positive recursion | Covered | `transitive_rule_derives_reachable` | none | - |
| multi-stratum evaluation | Covered | `multi_stratum_rules_negate_derived_relation` | none | - |
| guard `Gt` | Covered | `rule_guard_comparisons` | none | - |
| guards `Eq`, `Ne`, `Lt`, `Le`, `Ge` | Covered | `guard_operators` | none | - |
| mixed numeric guard comparison | Covered | `guard_operators` | none | - |
| repeated variable in one atom | Covered | `rule_terms_constants_and_repeated_variables` | none | - |
| constant terms in atoms | Covered | `rule_terms_constants_and_repeated_variables` | none | - |
| derived dedupe within a rule | Covered | `derived_dedupe` | none | - |
| `kernel_disable_rule` | Covered | `disable_rule_removes_derived_facts` | none | - |
| rule install with unknown relation | Covered | `rule_validation_errors` | none | - |
| `rule_clone`, `rule_definition_clone` | Indirect | rule install tests | term value deep copy is not tested | P3 |
| rule error during evaluation | Covered | `rule_evaluation_error_path` | none | - |

### Dispatch (`dispatch.odin`)

| Surface | Status | Covered by | Gap | Priority |
| --- | --- | --- | --- | --- |
| `unrestricted_dispatch_restriction` | Covered | `dispatch_open_signature_and_unrestricted_params` | none | - |
| direct identity restriction | Covered | `dispatch_matches_through_delegation` | none | - |
| delegation restriction | Covered | `dispatch_matches_through_delegation` | none | - |
| primitive prototype restriction | Covered | `dispatch_matches_primitive_prototype` | only the integer prototype is tested | P3 |
| open signature, missing role | Covered | `dispatch_open_signature_and_unrestricted_params` | none | - |
| open signature, extra roles | Covered | `dispatch_open_signature_and_unrestricted_params` | none | - |
| specificity pruning | Covered | `dispatch_prefers_more_specific_method` | none | - |
| `frob_only_dispatch_restriction` | Covered | `dispatch_frob_only_restrictions` | none | - |
| frob value matching | Covered | `dispatch_frob_only_restrictions` | none | - |
| `FROB_PROTOTYPE` fallback | Covered | `frob_prototype_fallback` | none | - |
| `applicable_method_entries` parameters | Covered | `dispatch_method_entries_expose_params` | none | - |
| duplicate roles in one invocation | Covered | `dispatch_role_duplicates_use_first_role` | none | - |

### Closure (`closure.odin`)

| Surface | Status | Covered by | Gap | Priority |
| --- | --- | --- | --- | --- |
| `delegates_reaches`, chain | Covered | `delegates_star_and_reaches` | none | - |
| `delegates_reaches`, negative | Covered | `delegates_star_and_reaches` | none | - |
| `delegates_star_from` | Covered | `delegates_star_and_reaches` | none | - |
| cycles and self loops | Covered | `closure_handles_cycles` | none | - |
| `delegates_star` pairs | Covered | `closure_handles_cycles` | none | - |

### Kernel API (`kernel.odin`)

| Surface | Status | Covered by | Gap | Priority |
| --- | --- | --- | --- | --- |
| `kernel_init`, `kernel_destroy` | Indirect | all kernel tests | no direct test | P3 |
| `kernel_begin` | Indirect | all transaction tests | none | - |
| `kernel_snapshot` | Covered | `snapshot_retain_release_keeps_old_version_readable` | none | - |
| `kernel_create_relation`, happy path | Covered | all kernel tests | none | - |
| duplicate relation name | Covered | `create_relation_rejects_duplicates_and_invalid_metadata` | none | - |
| duplicate relation id | Covered | `create_relation_rejects_duplicates_and_invalid_metadata` | none | - |
| invalid relation metadata | Covered | `create_relation_rejects_duplicates_and_invalid_metadata` | none | - |
| `kernel_install_rule`, happy path | Covered | rule tests | none | - |
| `kernel_install_rule`, unknown relation | Covered | `rule_validation_errors` | none | - |
| `kernel_disable_rule` | Covered | `disable_rule_removes_derived_facts` | none | - |
| `kernel_next_relation_id` | Covered | `kernel_next_relation_id` | none | - |
| `kernel_publish` | Indirect | all commits | none | - |
| `kernel_visit`, `kernel_contains` | Covered | `kernel_visit_and_contains` | none | - |
| `kernel_scan_into` | Covered | all scan tests | none | - |

---

---

## `mica/vm`

| Surface | Status | Covered by | Gap | Priority |
| --- | --- | --- | --- | --- |
| bytecode builder, validation, disassembly | Covered | `vm_test.odin` | no golden disassembly fixture | P3 |
| arithmetic, unary, moves, locals | Covered | `vm_test.odin` | none | - |
| branches, jumps, calls, returns | Covered | `vm_test.odin` | none | - |
| relation scan and write ops | Covered | `vm_test.odin`, `mica/compiler` emit tests | none | - |
| `Build_List`, `Build_Map`, `Build_Range`, `Build_Relation` | Covered | `vm_test.odin`, emit tests | none | - |
| `Index`, `Collection_Key_At`, `Collection_Value_At` | Covered | emit tests for indexed reads and two-name `for` | no direct VM test for the collection ops | P3 |
| `Builtin_Call`, variadic builtins | Covered | `mica/runtime` builtin tests | none | - |
| `Commit` boundary | Covered | `mica/runtime` `run_files` tests | none | - |
| `Dispatch` | Indirect | `mica/runtime` `test_run_dispatch_role_call` | no VM-level fixture builds dispatch relations directly | P2 |
| program serialisation | Missing | none | `Program` has no codec; runtime stores function indices, not program bytes | P2 |

## `mica/compiler`

| Surface | Status | Covered by | Gap | Priority |
| --- | --- | --- | --- | --- |
| lexer | Covered | `lexer_test.odin`, `test_lex_corpus` | none | - |
| parser unit forms | Covered | `parser_test.odin` | none | - |
| parser, app corpus | Covered | `test_parse_corpus`, `corpus_test.odin` (38 files) | none | - |
| emit: literals, bindings, arithmetic | Covered | `emit_test.odin` | none | - |
| emit: `if`, `while`, `for`, `begin`, `break`, `continue` | Covered | `emit_test.odin` (one- and two-name `for`, `break` inside `while`) | no `continue` test | P3 |
| emit: relations (`assert`, `retract`, pattern retract, queries) | Covered | `emit_test.odin` | named-role relation atoms are rejected | P2 |
| emit: calls, builtins, argument marshalling | Covered | `emit_test.odin`, `mica/runtime` tests | none | - |
| emit: frobs and `none`/`some`/`ok`/`err` | Covered | `emit_test.odin` | none | - |
| emit: list splices, indexed assignment | Covered | `emit_test.odin`, `mica/runtime` tests | none | - |
| emit: role dispatch | Covered | `test_emit_role_dispatch_spec`, `mica/runtime` dispatch tests | receiver dispatch syntax is not parsed | P2 |
| emit: `match`, `raise`, DOM, `spawn` | Covered | `test_emit_spawn_spec`, `test_emit_raise`, runtime match/DOM tests | `try`/`catch` is the remaining form and produces a named error | P1 |
| emit: `if let` constructor bindings | Covered | runtime `if let` corpus tests | only `some`/`ok`/`err` arities are bound | P3 |
| emit: named fn declarations | Covered | `test_run_recursion` (`fn fib`) | none | - |
| emit: `try`/`catch`/`finally` | Covered | `test_run_try_catch_codes`, `test_run_try_finally_paths`, `test_run_try_catches_builtin_error`, `test_run_finally_on_return`, `test_run_finally_on_catch_return` | a `return` inside a finally body is not lowered | P3 |
| emit: `fn` literals, captures, and recursion | Covered | `test_emit_fn_literal`, `test_run_fn_literals`, `test_run_fn_captures`, `test_run_recursion` | cross-task function values are not resolved | P3 |
| emit: optional and rest parameters | Covered | `test_run_optional_rest_params`, `test_run_constant_defaults` | defaults must be constant expressions; named-role dispatch still requires every role | P3 |
| emit: receiver dispatch | Covered | `test_run_receiver_dispatch`, `test_run_dispatch_optional_rest_params` | named-role receiver dispatch expects a `receiver` parameter name | P3 |
| emit: return inside finally | Covered | `test_run_return_in_finally` | none | - |
| runtime: function values across tasks | Covered | `test_run_cross_task_closure` | closures cannot cross process/world boundaries | P3 |
| emit: byte literals | Covered | `test_run_byte_literals` | none | - |
| emit: argument splices | Covered | `test_run_argument_splices` | relation queries do not splice | P3 |
| emit: collection match patterns | Covered | `test_run_match_collection_patterns` | map pattern keys must be literal names | P3 |
| emit: scatter bindings | Covered | `test_run_scatter_bindings` | rest must be the last element | P3 |
| emit: `len()` | Covered | `test_run_match_collection_patterns` | none | - |
| emit: named-role call arguments on plain names | Missing | none | `foo(role: value)` is rejected; only `:selector(...)` dispatches | P3 |

## `mica/runtime`

| Surface | Status | Covered by | Gap | Priority |
| --- | --- | --- | --- | --- |
| `run_filein` / `run_files`, multi-file | Covered | `test_run_capabilities_filein`, `test_run_multiple_files_share_verbs` | none | - |
| relation and identity pre-scan | Covered | `test_run_capabilities_filein` | none | - |
| rule installation | Covered | `test_run_capabilities_filein` | rule conversion errors have no negative test | P3 |
| builtin string surface | Covered | `test_builtin_string_surface`, `test_scalar_builtins` | DOM and literal builtins still lack direct error-arm tests | P3 |
| JSON builtins (`json_encode`, `json_decode`, `json_null`, `json_is_null`) | Covered | `test_run_json_roundtrip` | symbols encode as strings; only string/symbol map keys; 56-bit integer range | - |
| splices and indexed assignment | Covered | `test_builtin_splice_and_set_index` | none | - |
| primitive prototype identities | Covered | `test_primitive_identity_prototypes` | none | - |
| method installation and role dispatch | Covered | `test_run_dispatch_role_call`, `test_run_dispatch_without_method_fails`, `test_vm_dispatch_opcode` | ambiguous dispatch is covered at the VM level | - |
| `invoke` dynamic dispatch | Covered | `test_run_invoke_dynamic_dispatch` | splices and non-map role collections are untested | P3 |
| `spawn` and task lifecycle | Covered | `test_run_spawn_task`, `test_scheduler_spawn_child`, `test_task_resume_with_value`, `test_scheduler_cancel_parked` | cancellation of a running task takes effect only at the next boundary | P3 |
| `external_request` | Covered | `test_scheduler_external_request` | no timeout form; the host must call `scheduler_resume` | P3 |
| mailboxes (`mailbox`, `mailbox_send`, `mailbox_close`, `mailbox_recv`) | Covered | `test_run_mailbox_roundtrip`, `test_run_mailbox_wakes_waiter`, `test_run_mailbox_timeout`, `test_run_mailbox_handle_revocation` | handles are capability-store entries; subscription delivery uses the same queues | - |
| reflection relations (`Relation`, `RelationName`, `Arity`, `RelationDurability`, `ConflictPolicy`, `FunctionalKey`, `Index`, `IndexPosition`, `IndexStorageKind`, `MethodSource`, `Rule`, `RuleHead`, `RuleSource`, `ActiveRule`) | Covered | `test_run_relation_reflection_facts`, `test_run_records_catalog_facts` | `ArgumentName` is populated from metadata but source declarations do not set names; `ProgramBytes` is not recorded | P2 |
| host value builtins (`endpoint`, `actor`, `principal`, `to_xml`, `from_literal`, `embed_text`, `sync_signature`) | Covered | `test_run_from_literal_and_to_xml`, mud world corpus test | `to_xml` escaping is not asserted directly | P3 |
| full mud world load | Covered | `test_run_mud_app_world` (16 fileins, shared + UI) | loaded world assertions only check success | P2 |

## Cross-cutting methodology

| Area | Status | Gap | Priority |
| --- | --- | --- | --- |
| Property tests | Partial | value and rule-program generators exist; store blocks need generated inputs | P1 |
| Differential tests | Missing | no test compares results with Rust mica | P1 |
| Fuzzing | Missing | no fuzz target for values, tuples, or rule programs | P2 |
| Leak detection | Covered | the Odin test runner reports leaks and the suite is clean | - |
| Concurrency | Covered | kernel concurrency tests and the task scheduler run parallel commits and tasks; TSan-clean when run serialized | - |
| Benchmarks | Covered | the micromeasure harness and data core benchmarks exist | - |

## Known semantic gaps

These items are not test gaps. The behaviour is absent or deliberately
incomplete, so a test cannot exist yet.

1. `Conflict_Kind.Event_Append` skips conflict validation; storage stays set
   semantics. This matches the Rust runtime, which also inserts into a set
   without conflict checks.
2. `Relation_Durability` has no storage effect: there is no durable provider.
   The declared durability is asserted as a `RelationDurability` catalog fact.
3. Snapshot ancestry is borrowed, not owned: a snapshot keeps only a
   `parent` link, while blocks, chunks, and metadata are kept alive by reference
   counts and the kernel-lifetime world store. Superseded chunks return their
   arenas to the pool, so memory no longer grows with the commit count.
   Reclamation is hazard-based: refcounted readers announce in padded
   per-thread slots, transient reads use a lock-free `kernel_snapshot_borrow`
   hazard pointer, and retired snapshots are freed only when no reader window
   or hazard pins them. Parallel hazard borrows scale flat; transaction begins
   still touch a shared refcount and an arena pool shard.
4. `Transaction.read_only` is always false. The `Read_Only` error path is
   unreachable.
5. Authority is enforced at read, write, method invoke, builtin invoke, and
   effect points. Tasks mint authority from `Can*`/`Grant*`/`RoleCan*` policy
   facts; `run_files` entry tasks stay root so declarations load, and spawned
   tasks run as `Run_Options.actor`. `assume_actor` switches the task actor
   (grant authority or a `session/CanAssumeActor(principal, actor)` fact),
   refreshes policy authority while preserving adopted capabilities, and
   records the `EndpointActor` binding. Endpoint relations are installed
   but no host populates them yet. Capabilities are reference-counted grant
   objects with an atomic revoked flag, multi-right scopes, and optional wall
   or epoch expiry. `mint_capability` needs grant authority; `use_capability`
   adopts; `restrict_capability` derives a weaker child; `revoke_capability`
   invalidates a whole subtree; `drop_capability` releases one adoption.
   Revocation is observed by every holder immediately. Capability values are
   storable in in-memory relation tuples (`value_is_storable`) but remain
   unpersistable; there is no codec and no cross-world transfer.
6. Values have no codec and no persisted format.
7. Rule evaluation has a greedy planner: ready guards and negations run first,
   then the positive atom with the most bound variables, breaking ties by
   estimated relation or delta size. There is no cost model over join
   selectivity and no general-purpose query planner outside rules.
8. Relation metadata lives in a struct list, but its catalog facts are now
   recorded into the system relations and are queryable: `Relation`,
   `RelationName`, `Arity`, `RelationDurability`, `ConflictPolicy`,
   `FunctionalKey`, `Index`, `IndexPosition`, `IndexStorageKind`,
   `ArgumentName`, `MethodSource`, and the rule facts. `ProgramBytes` is not
   recorded because programs are not serialised.
9. Value display can differ from Rust mica for floats.
10. `conflict_event_append` is reachable only from tests: no source
    declaration selects the event-append policy, and storage keeps set
    semantics.
11. Dispatch stores a function index in `MethodProgram` instead of serialised
    program bytes. Cross-program methods and dynamic program loading do not
    exist.
12. Role dispatch matches named roles and prototype restrictions. Receiver
    and positional dispatch, including optional and rest parameters, are
    ported. Unauthorized methods are filtered before specificity pruning, so a
    denied method can fall back to a more general one.
13. `try`/`catch`/`finally` is lowered with a VM handler stack. Returns
    inside a try, catch, or finally body run the remaining finally bodies
    first, and an error raised inside a finally propagates without running it
    twice.
14. `mica/compiler` is a clean-room subset. It does not mirror the Rust
    HIR/backend opcode set.
19. `fn` literals capture every visible local by value at creation time.
    Named `fn name(...)` declarations, self-recursive bindings, and function
    values passed to spawned tasks all work; callables are interned on the
    program so tasks sharing a program resolve them. Closures still have no
    codec, so they cannot be persisted or sent between processes.
20. Optional parameter defaults may be any constant expression (literals,
    lists, maps, `some`/`ok`/`err`, `none`, negated numbers). Defaults that
    call functions or reference other parameters are not supported, and only
    positional dispatch matches methods with optional or rest parameters.
18. The scheduler resolves `spawn` by dispatch and resumes the parent with the
    child id. It implements mailboxes, `mailbox_recv` wakeups and timeouts,
    `external_request` suspensions that a host resumes, and `subscribe_changes`
    subscriptions (`:facts`, `:relation`, `:catalogue`) with per-subscription
    queue budgets. `read` is not implemented, and `run_files` returns once the
    entry task finishes even if children are parked.
21. Subscription delivery diverges from Rust mica in two visible ways. First,
    overflow and lost-window handling post a `:resynchronize` marker, but the
    next dispatch resolves the flag with a fresh snapshot instead of leaving the
    marker queued and waiting for the host to reinstall the subscription.
    Second, facts and relation snapshot messages use `:kind :snapshot` with
    `:subject :facts` or `:relation`; Rust sends `:kind :changes` with
    `:subject :snapshot`. Catalogue messages match Rust (`:kind :snapshot` for
    the initial snapshot, `:kind :changes` for increments, `:subject
    :catalogue`, `:entries`). Catalogue subscriptions require root authority.
22. Rust sends a `:revoked` marker when a live subscription loses read
    authority; the port sends one when the subscription capability is revoked
    and still registered. Explicit `cancel_subscription` and `mailbox_close`
    remove the subscription without a marker. A task parked on `mailbox_recv`
    at a revoked or closed handle wakes only on a send, timeout, or scheduler
    cancellation; this matches Rust, which also leaves the waiter parked.
    The VM fails fast with `E_INVARG` when a program sends or receives through
    a revoked handle.
15. Superseded by item 16: commits now prepare candidates in parallel and a
    group committer publishes a merged snapshot.
16. Write commits prepare candidates in parallel and a group committer merges
    a batch into one snapshot publication. With the frame allocator removing
    arena locks and page-commit churn from the prepare path, parallel disjoint
    writes to distinct relations are faster than serial. Publication is still a
    single global serial point, so throughput scales with prepared work, not
    with commit count alone. Hazard-based snapshot acquisition scales flat; the
    concurrent benchmark records the acquire group, and
    `test_snapshot_hazard_borrow_scales` checks a borrow reader never sees a
    version go backwards during a concurrent writer run.
17. `Kernel` is a copyable value, but its snapshots and blocks hold a pointer
    to its heap `arena_pool`. Treat a kernel as a handle: copying shares the
    pool and world, and the copy must not outlive the kernel lifetime.

## Prioritized backlog

Each item names the proposed test and the behaviour that it must assert.

### P0

No open P0 items at this revision.

### P1

| Proposed test | Behaviour |
| --- | --- |
| `test_differential_value_ordering` | A tool or fixture compares value order and display with Rust mica. |

### P2

| Proposed test | Behaviour |
| --- | --- |
| `test_program_codec_roundtrip` | A serialised program validates and runs identically, once a codec exists. |

### P3

| Proposed test | Behaviour |
| --- | --- |
| Benchmark harness | It records scan, commit, and rule cost. |

## Maintenance

1. Close a gap only when a test asserts the contract.
2. Move the row to Covered and name the test.
3. Keep the summary table and the revision line current.
4. Add a new row when a surface has no test.
5. Odin toolchain notes. First, a slice compound literal passed into a
   function that stores it in a returned value can escape onto the caller's
   stack frame without a diagnostic. The compiler rejects only direct
   `Struct{field = []T{...}}` returns. Construct rule and tuple slices inline
   at the call site, or copy them into an owned allocation first. Second,
   `core:fmt` treats braces in a format string as argument syntax, so format
   strings that contain JSON braces must be split around `fmt.sbprintf` calls
   or written with `strings.write_string`.
