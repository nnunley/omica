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
}
