package mica_runtime

import "core:sync"
import "core:testing"
import k "../kernel"
import accel "../kernel/accel"

@(test)
test_accel_mode_parse :: proc(t: ^testing.T) {
	cases := []struct {
		text: string,
		mode: Accel_Mode,
		ok:   bool,
	} {
		{"cpu", .Cpu, true},
		{"cpu-parallel", .Cpu_Parallel, true},
		{"metal", .Metal, true},
		{"cuda", .Cuda, true},
		{"auto", .Auto, true},
		{"gpu", .Unchanged, false},
		{"", .Unchanged, false},
	}
	for c in cases {
		mode, ok := accel_mode_parse(c.text)
		testing.expectf(t, ok == c.ok && mode == c.mode, "%q: got %v %v", c.text, mode, ok)
	}
}

// The accelerator strategy is process-wide and tests run on parallel threads:
// tests that set it and then assert it hold this lock.
@(private = "file")
strategy_tests_lock: sync.Mutex

// world_start installs the configured strategy before workers start; the
// default (Unchanged) leaves the process strategy alone.
@(test)
test_world_start_installs_accel :: proc(t: ^testing.T) {
	sync.mutex_lock(&strategy_tests_lock)
	defer sync.mutex_unlock(&strategy_tests_lock)
	defer accel.use_cpu()
	kernel: k.Kernel
	k.kernel_init(&kernel)
	defer k.kernel_destroy(&kernel)
	world, result := world_start(&kernel, nil, context.allocator, World_Config{accel = .Cpu_Parallel, accel_workers = 2})
	testing.expect(t, result.ok)
	defer world_destroy(world)
	testing.expect_value(t, accel.active_strategy().name, "cpu_parallel")
	// Spec: the worker pool is created in world_start, not on first use.
	testing.expect(t, accel.cpu_pool_started(), "cpu-parallel world started without its worker pool")

	kernel2: k.Kernel
	k.kernel_init(&kernel2)
	defer k.kernel_destroy(&kernel2)
	world2, result2 := world_start(&kernel2, nil, context.allocator, World_Config{})
	testing.expect(t, result2.ok)
	defer world_destroy(world2)
	testing.expect_value(t, accel.active_strategy().name, "cpu_parallel")
}

// A GPU mode that cannot run here falls through to the multi-core CPU
// strategy instead of failing.
@(test)
test_accel_unavailable_gpu_falls_through_to_cpu :: proc(t: ^testing.T) {
	sync.mutex_lock(&strategy_tests_lock)
	defer sync.mutex_unlock(&strategy_tests_lock)
	defer accel.use_cpu()
	when ODIN_OS != .Linux {
		result := world_install_accel(.Cuda, 2)
		testing.expect(t, result.ok)
		testing.expect_value(t, accel.active_strategy().name, "cpu_parallel")
	}
	when ODIN_OS != .Darwin {
		result := world_install_accel(.Metal, 2)
		testing.expect(t, result.ok)
		testing.expect_value(t, accel.active_strategy().name, "cpu_parallel")
	}
}
