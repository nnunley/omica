# micromeasure for Odin

This package measures repeated benchmark operations. It has no Mica dependencies and imports only Odin's `core:` and `base:` collections.

The package includes warmup, batch calibration, sample statistics, optional Linux hardware counters, process memory observations, and reports.

## Run the example

From the directory above `micromeasure`, run:

```sh
odin run micromeasure/examples/basic -o:speed -- /tmp/micromeasure-results.json
odin test micromeasure
bash micromeasure/check-standalone.sh
```

The standalone check copies this directory into a temporary directory. It runs the package tests and the example there.

## Use the package in another project

Copy this directory into your project, or use a checkout pinned to a specific revision.
The directory includes its tests, example, documentation, and license.

For a local copy, import the package through its relative path:

```odin
import mm "../micromeasure"
```

For a shared checkout, define an Odin collection that points to the directory above `micromeasure`:

```sh
odin run benchmarks -o:speed -collection:bench=/path/to/packages
```

Then use this import:

```odin
import mm "bench:micromeasure"
```

The package uses AGPLv3, as specified in [LICENSE](LICENSE). Extraction does not change the license.

## Measurement contract

A body receives `(user, chunk_size, chunk_num)` and performs exactly `chunk_size` operations.
One operation means one iteration in the body's operation loop.
A body that ignores the chunk size must use `bench_capped` with a limit of one.

Timing and hardware counters both use this operation as their denominator.
Throughput describes additional units per operation, such as bytes or opcodes.
It does not change the denominator of `ns/op`, `insn/op`, or `cyc/op`.
Fractional throughput units are valid.

Warmup uses chunks of one. Calibration selects a batch size near `target_sample`, subject to the chunk limit.
Warmup, calibration, and sampling share the caller's state.
The `chunk_num` value is zero during warmup and calibration, then starts at zero again during sampling.

`bench_register` accepts a `Bench` with optional `prepare` and `cleanup` callbacks.
Both callbacks receive the exact chunk size and chunk number for each invocation, including warmup and calibration.
Preparation runs before timing and counters. Cleanup runs after both measurements stop.
Preparation can reset state or allocate a batch of inputs.
Cleanup can release scratch storage.
The caller owns benchmark state and releases it after the run.

`runner_init` rejects invalid durations, sample limits, and noise thresholds.
At least two samples are required.
Each `runner_run` replaces previous results.
`runner_clear_results` releases results but preserves benchmark registration.

The runner copies group names, benchmark names, and throughput labels.
It owns result names and sample arrays until the next run, result clear, or destruction.
The runner retains its allocator for release of this storage.
The caller's filter is borrowed for each `runner_run` call.
Results borrow their group names and throughput labels from the runner's registration storage.
Benchmark callbacks can reset `context.temp_allocator` without corrupting runner metadata.

## Statistics and comparisons

Samples contain batch elapsed time divided by the number of operations.
`batch-p95` describes these batch averages. It does not measure individual-operation tail latency.
Percentiles use nearest rank. For an even sample count, the median is the lower middle value.
Standard deviation uses the sample formula with denominator `n - 1`.

Outliers differ from the median by more than three median absolute deviations (MAD).
If MAD is zero, every value different from the median counts as an outlier.
The calculation retains all samples, including outliers.

The runner stops at the sample limit or after the minimum count satisfies the configured coefficient of variation (CV).
This stopping rule does not produce a confidence interval.
A baseline percentage describes a change between medians. It does not establish statistical significance.

## Hardware counters

`Config.collect_counters` controls counter collection. Both standard configurations enable it.
A group can set `counter_scope = .Disabled`.
The only supported measurement scope is `.Calling_Thread`, in user space.
Worker threads and kernel execution are excluded.
Concurrent workloads must disable these counters or explicitly interpret them as calling-thread observations.
The Mica concurrency and task suites disable counters, including their serial comparison cases.

Cycles and instructions share a scheduling group. IPC appears only when both have valid measurements from that group.
Other events use independent scheduling groups.
Counts use differences in cumulative event counts, enabled time, and running time for each sample.
The runner scales counts by enabled time divided by running time.
Multiplexed counts are estimates. Their accuracy depends on how well scheduled intervals represent the workload.

A failed control operation, failed read, or zero running time makes that sample's counter unavailable.
A counter is unavailable for the result if any measured sample is invalid.
A valid zero count remains available.
`run%` is the minimum scheduling coverage across available counters and samples.
JSON retains coverage for each counter. `counter_names` supplies the array order.
The counter window also includes timer reads and some counter-control overhead outside the wall-clock interval.

Linux kernel permissions and hardware support determine which events are available.
Other platforms use timing-only stubs.

## Memory observations

A `Memory_Probe` receives the benchmark's user pointer and returns a `Memory_Reading`.
The reading contains bytes, availability, and a measurement kind.
The runner calls the probe before warmup and after the final sample's cleanup, before statistics calculation.
The signed delta includes warmup, calibration, callbacks, and harness activity.
A valid zero remains visible. An unavailable reading produces an unavailable delta.

`current_rss_bytes` returns an approximate Linux process RSS observation.
Its delta measures the change between observations. It misses temporary memory released between probes.
`peak_rss_bytes` returns the process-lifetime high-water mark.
Its delta measures additional high-water growth. Earlier allocations can mask later activity.
Neither probe measures allocation counts or per-operation memory cost.
Neither probe is available on platforms without the Linux status fields.

A filter selects benchmark execution after registration. It does not isolate memory allocated during registration.
A dedicated process with controlled setup is necessary for an isolated process-memory experiment.

## Reports and ownership

`report` prints the table. `format_report` returns an owned string that the caller must delete.
`save_report` writes the compact TSV baseline format.
`load_baseline` loads valid positive medians and uses the last valid value for duplicate names.
`baseline_destroy(&baseline)` releases the map and its owned keys.
Missing or unreadable files return a nil map.
TSV names cannot contain tabs or newlines.

`save_json_report` writes schema version 1 with raw samples, statistics, configuration, metric units, availability, and coverage.
The document also records the compiler version, operating system, and architecture.
`Report_Context` accepts machine details, build flags, and a revision from the caller.
Empty provenance fields mean that the caller did not supply them.
Configuration durations use nanoseconds.

## Validation

Local validation uses Odin `dev-2026-09-nightly:a2fb372`.
CI runs the package tests and copied-package example on Linux and macOS.
The tests cover counter scaling, invalid samples, result ownership, hooks, calibration limits, memory observations, and report round trips.
Hardware smoke checks accept unavailable counters because kernel access differs across hosts.

`black_box` uses volatile accesses. Apply it to inputs before computation and to the final result.
Output-only use does not prevent constant folding or loop-invariant computation.
Inspect generated code for very small benchmark bodies.
