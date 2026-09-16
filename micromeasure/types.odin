// Measurement types for the harness.
package micromeasure

import "core:time"

// Timing and sampling configuration.
Config :: struct {
	// Time spent warming up each benchmark before calibration.
	warmup: time.Duration,
	// Target elapsed time for one sample.
	target_sample: time.Duration,
	// Minimum number of samples to collect.
	min_samples: int,
	// Maximum number of samples to collect.
	max_samples: int,
	// Stop after min_samples when the coefficient of variation is at or below
	// this value.
	noise_cv: f64,
}

// Throughput description for a benchmark.
Throughput :: struct {
	// Units processed by one operation.
	units_per_op: f64,
	// Label for the unit, for example "bytes" or "rows".
	unit: string,
}

// Returns a throughput spec of one operation per operation.
throughput_ops :: proc() -> Throughput {
	return Throughput{units_per_op = 1, unit = "op"}
}

// Returns a throughput spec of `units` units per operation.
throughput_per_op :: proc(units: f64, unit: string) -> Throughput {
	return Throughput{units_per_op = units, unit = unit}
}

// A benchmark body. It runs `chunk_size` operations and receives a sample
// counter in `chunk_num`.
Bench_Proc :: proc(user: rawptr, chunk_size: int, chunk_num: int)

// A registered benchmark.
Bench :: struct {
	name:      string,
	run:       Bench_Proc,
	user:      rawptr,
	// Optional upper bound for the calibrated chunk. Zero means no bound.
	max_chunk: int,
	// When non-nil, the harness calls it before the first warmup sample and
	// after the last measured sample, and records the difference (in bytes)
	// in the result's `memory` field. Use this for benchmarks that want to
	// report a per-run memory delta rather than the process-lifetime peak.
	memory_probe: proc() -> int,
}

// A named group of benchmarks with shared throughput configuration.
Group :: struct {
	name:       string,
	throughput: Throughput,
	benches:    [dynamic]Bench,
}

// Robust statistics over per-operation samples.
Stats :: struct {
	median:   f64,
	mean:     f64,
	min:      f64,
	max:      f64,
	stddev:   f64,
	mad:      f64,
	p95:      f64,
	cv:       f64,
	outliers: int,
}

// The measured result of one benchmark. Samples are nanoseconds per
// operation.
Result :: struct {
	group:          string,
	name:           string,
	throughput:     Throughput,
	chunk_size:     int,
	samples:        []f64,
	stats:          Stats,
	ops_per_second: f64,
	// Hardware counters for one operation, from the last measurement sample.
	// `counters_available` is false when no counter could be opened, in which
	// case the values are zero and the report omits them.
	counters:           Counters,
	counters_available: bool,
	// Optional memory observation for this benchmark, in bytes. When
	// `memory_available` is false the value is zero and the report omits the
	// column. A benchmark that measures memory growth records the delta
	// (after - before) so the number is per-run rather than process-lifetime.
	memory:            int,
	memory_available:  bool,
}

// Per-operation hardware counter values. Only the counters the kernel actually
// scheduled are meaningful; each `has_*` flag says which those are.
Counters :: struct {
	cycles:                 f64,
	instructions:           f64,
	cache_references:       f64,
	cache_misses:           f64,
	branches:               f64,
	branch_misses:          f64,
	stalled_cycles_frontend: f64,
	stalled_cycles_backend:  f64,
	has_cycles:             bool,
	has_instructions:       bool,
	has_cache_references:   bool,
	has_cache_misses:       bool,
	has_branches:           bool,
	has_branch_misses:      bool,
	has_stalled_frontend:   bool,
	has_stalled_backend:    bool,
}

// Returns the per-operation value and availability flag for one counter kind.
counter_value :: proc(counters: Counters, kind: Counter_Kind) -> (f64, bool) {
	switch kind {
	case .Cycles:
		return counters.cycles, counters.has_cycles
	case .Instructions:
		return counters.instructions, counters.has_instructions
	case .Cache_References:
		return counters.cache_references, counters.has_cache_references
	case .Cache_Misses:
		return counters.cache_misses, counters.has_cache_misses
	case .Branches:
		return counters.branches, counters.has_branches
	case .Branch_Misses:
		return counters.branch_misses, counters.has_branch_misses
	case .Stalled_Frontend:
		return counters.stalled_cycles_frontend, counters.has_stalled_frontend
	case .Stalled_Backend:
		return counters.stalled_cycles_backend, counters.has_stalled_backend
	}
	return 0, false
}

