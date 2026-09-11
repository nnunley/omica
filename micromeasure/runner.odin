// Benchmark registration and measurement.
package micromeasure

import "core:fmt"
import "core:math"
import "core:strings"
import "core:time"

// Maximum calibrated chunk size.
MAX_CHUNK :: 1 << 30

// A benchmark session.
Runner :: struct {
	config:  Config,
	groups:  [dynamic]^Group,
	filter:  string,
	results: [dynamic]Result,
}

// Creates a runner with the given configuration.
runner_init :: proc(runner: ^Runner, config := DEFAULT_CONFIG) {
	runner.config = config
	runner.groups = make([dynamic]^Group)
	runner.results = make([dynamic]Result)
}

// Releases all runner storage.
runner_destroy :: proc(runner: ^Runner) {
	for result in runner.results {
		delete(result.samples)
	}
	delete(runner.results)
	for group in runner.groups {
		delete(group.benches)
		free(group)
	}
	delete(runner.groups)
}

// Adds a benchmark group with a shared throughput description.
group :: proc(
	runner: ^Runner,
	name: string,
	throughput := Throughput{units_per_op = 1, unit = "op"},
) -> ^Group {
	created := new(Group)
	created.name = name
	created.throughput = throughput
	append(&runner.groups, created)
	return created
}

// Registers a benchmark in a group.
bench :: proc(group: ^Group, name: string, user: rawptr, run: Bench_Proc) {
	append(&group.benches, Bench{name = name, run = run, user = user})
}

// Registers a benchmark with an upper bound on the calibrated chunk. Use this
// for allocation-heavy bodies so that one sample does not reserve too much
// memory.
bench_capped :: proc(
	group: ^Group,
	name: string,
	user: rawptr,
	run: Bench_Proc,
	max_chunk: int,
) {
	append(&group.benches, Bench {
		name      = name,
		run       = run,
		user      = user,
		max_chunk = max_chunk,
	})
}

// Runs every registered benchmark that matches the filter. Returns the number
// of benchmarks that ran.
runner_run :: proc(runner: ^Runner) -> int {
	ran := 0
	for group in runner.groups {
		for bench in group.benches {
			full_name := bench_full_name(group.name, bench.name, context.temp_allocator)
			if runner.filter != "" && !strings.contains(full_name, runner.filter) {
				continue
			}
			fmt.eprintf("benchmark: %s\n", full_name)
			result := measure_bench(runner, group^, bench, full_name)
			append(&runner.results, result)
			ran += 1
		}
	}
	return ran
}

@(private)
bench_full_name :: proc(group, name: string, allocator := context.allocator) -> string {
	builder: strings.Builder
	strings.builder_init(&builder, allocator)
	strings.write_string(&builder, group)
	strings.write_string(&builder, "/")
	strings.write_string(&builder, name)
	return strings.to_string(builder)
}

@(private)
sample_ns :: proc(bench: Bench, chunk: int, chunk_num: int) -> i64 {
	start := time.tick_now()
	bench.run(bench.user, chunk, chunk_num)
	end := time.tick_now()
	return time.duration_nanoseconds(time.tick_diff(start, end))
}

@(private)
calibrate_chunk :: proc(runner: ^Runner, bench: Bench) -> int {
	target_ns := f64(time.duration_nanoseconds(runner.config.target_sample))
	chunk := 1
	for _ in 0 ..< 12 {
		elapsed := sample_ns(bench, chunk, 0)
		per_op := f64(elapsed) / f64(max(chunk, 1))
		if per_op < 0.05 {
			per_op = 0.05
		}
		desired := int(target_ns / per_op)
		desired = clamp(desired, 1, MAX_CHUNK)
		if bench.max_chunk > 0 && desired > bench.max_chunk {
			desired = bench.max_chunk
		}
		chunk = desired
		if elapsed >= i64(target_ns) {
			break
		}
		if bench.max_chunk > 0 && chunk >= bench.max_chunk {
			break
		}
	}
	return chunk
}

@(private)
measure_bench :: proc(
	runner: ^Runner,
	group: Group,
	bench: Bench,
	full_name: string,
) -> Result {
	// Warm up the code paths and caches.
	warmup_start := time.tick_now()
	for time.duration_nanoseconds(time.tick_diff(warmup_start, time.tick_now())) <
	    time.duration_nanoseconds(runner.config.warmup) {
		bench.run(bench.user, 1, 0)
	}

	chunk := calibrate_chunk(runner, bench)

	max_samples := max(runner.config.max_samples, 1)
	min_samples := clamp(runner.config.min_samples, 1, max_samples)
	per_op := make([dynamic]f64, 0, max_samples)
	for sample_index in 0 ..< max_samples {
		elapsed := sample_ns(bench, chunk, sample_index)
		append(&per_op, f64(elapsed) / f64(max(chunk, 1)))
		if len(per_op) >= min_samples {
			if coefficient_of_variation(per_op[:]) <= runner.config.noise_cv {
				break
			}
		}
	}

	stats := compute_stats(per_op[:])
	result := Result {
		group      = group.name,
		name       = full_name,
		throughput = group.throughput,
		chunk_size = chunk,
		stats      = stats,
	}
	if stats.median > 0 {
		result.ops_per_second = 1e9 / stats.median
	}

	owned := make([]f64, len(per_op))
	copy(owned, per_op[:])
	result.samples = owned
	delete(per_op)
	return result
}
