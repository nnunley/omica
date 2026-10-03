// Microbenchmark driver for the mica-odin data core.
//
// Usage:
//
//	odin run benchmarks -o:speed
//	odin run benchmarks -o:speed -- -suite=var -filter=string
//	odin run benchmarks -o:speed -- -save=baseline.tsv
//	odin run benchmarks -o:speed -- -baseline=baseline.tsv
package main

import "core:fmt"
import "core:os"
import "core:strings"

import mm "../vendor/micromeasure/micromeasure-odin"

Args :: struct {
	config:     mm.Config,
	filter:     string,
	suite:      string,
	save:       string,
	baseline:   string,
	json:       string,
	provenance: mm.Report_Context,
}

main :: proc() {
	args := parse_args()
	runner: mm.Runner
	mm.runner_init(&runner, args.config)
	defer mm.runner_destroy(&runner)

	switch args.suite {
	case "var":
		register_var_benches(&runner)
	case "kernel":
		register_kernel_benches(&runner)
	case "tasks":
		register_task_benches(&runner)
	case "vm":
		register_vm_benches(&runner)
	case "buffer":
		register_buffer_benches(&runner)
	case "accel":
		register_accel_benches(&runner)
	case "all":
		register_var_benches(&runner)
		register_kernel_benches(&runner)
		register_task_benches(&runner)
		register_vm_benches(&runner)
		register_buffer_benches(&runner)
		register_accel_benches(&runner)
	case:
		fmt.eprintf("unknown suite: %s (use all, var, kernel, tasks, vm, buffer, or accel)\n", args.suite)
		os.exit(1)
	}
	runner.filter = args.filter

	if args.filter != "" {
		fmt.eprintf("running benchmarks matching filter: %q\n", args.filter)
	}

	ran := mm.runner_run(&runner)
	if ran == 0 {
		fmt.eprintln("no benchmarks matched")
		os.exit(1)
	}

	baseline: map[string]f64
	defer mm.baseline_destroy(&baseline)
	if args.baseline != "" {
		baseline = mm.load_baseline(args.baseline)
		if baseline == nil {
			fmt.eprintf("could not read baseline: %s\n", args.baseline)
			os.exit(1)
		}
	}
	mm.report(&runner, baseline)
	if args.json != "" && !mm.save_json_report(args.json, &runner, args.provenance) {
		fmt.eprintf("could not save JSON report: %s\n", args.json)
		os.exit(1)
	}

	if args.save != "" {
		if mm.save_report(args.save, &runner) {
			fmt.printf("results saved to %s\n", args.save)
		} else {
			fmt.eprintf("could not save results to %s\n", args.save)
			os.exit(1)
		}
	}
}

@(private)
parse_args :: proc() -> Args {
	args := Args {
		config = mm.DEFAULT_CONFIG,
		suite  = "all",
	}
	for raw in os.args[1:] {
		arg := raw
		switch {
		case strings.has_prefix(arg, "-filter="):
			args.filter = arg[len("-filter="):]
		case strings.has_prefix(arg, "-suite="):
			args.suite = arg[len("-suite="):]
		case strings.has_prefix(arg, "-save="):
			args.save = arg[len("-save="):]
		case strings.has_prefix(arg, "-runner-id="):
			args.provenance.runner_id = arg[len("-runner-id="):]
		case strings.has_prefix(arg, "-machine="):
			args.provenance.machine = arg[len("-machine="):]
		case strings.has_prefix(arg, "-revision="):
			args.provenance.revision = arg[len("-revision="):]
		case strings.has_prefix(arg, "-build-flags="):
			args.provenance.build_flags = arg[len("-build-flags="):]
		case strings.has_prefix(arg, "-json="):
			args.json = arg[len("-json="):]
		case strings.has_prefix(arg, "-baseline="):
			args.baseline = arg[len("-baseline="):]
		case arg == "-quick":
			args.config = mm.QUICK_CONFIG
		case !strings.has_prefix(arg, "-"):
			args.filter = arg
		}
	}
	args.provenance.suite = args.suite
	if args.json != "" && strings.trim_space(args.provenance.runner_id) == "" {
		fmt.eprintln("JSON export requires -runner-id=<stable machine identity>")
		os.exit(1)
	}
	return args
}
