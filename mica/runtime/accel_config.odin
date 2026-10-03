// Accelerator selection for a world. The strategy registry in
// mica/kernel/accel is process-wide, so the zero mode (Unchanged) leaves it
// alone: worlds that do not ask for a strategy never reset one another's.
package mica_runtime

import "core:log"
import accel "../kernel/accel"

Accel_Mode :: enum u8 {
	Unchanged,
	Cpu,
	Cpu_Parallel,
	Metal,
	Cuda,
	Auto,
}

ACCEL_MODE_NAMES :: "cpu|cpu-parallel|metal|cuda|auto"

accel_mode_parse :: proc(text: string) -> (Accel_Mode, bool) {
	switch text {
	case "cpu":
		return .Cpu, true
	case "cpu-parallel":
		return .Cpu_Parallel, true
	case "metal":
		return .Metal, true
	case "cuda":
		return .Cuda, true
	case "auto":
		return .Auto, true
	}
	return .Unchanged, false
}

// Installs the strategy for `mode`. A GPU mode whose device is unusable, or
// absent on this platform, falls through to the multi-core CPU strategy with a
// logged warning, as Auto does; worlds always start.
world_install_accel :: proc(mode: Accel_Mode, workers: int) -> Run_Result {
	gpu_installed := false
	switch mode {
	case .Unchanged:
		return {ok = true}
	case .Cpu:
		accel.use_cpu()
	case .Cpu_Parallel:
		accel.use_cpu_parallel(workers)
		// Spec §5: the pool is created here, before the scheduler starts, not
		// on the first large operator.
		accel.cpu_pool_start()
	case .Metal, .Cuda, .Auto:
		when ODIN_OS == .Darwin {
			if mode != .Cuda {
				if s := accel.metal_strategy(); s.available() {
					accel.select_strategy(s)
					gpu_installed = true
				}
			}
		}
		when ODIN_OS == .Linux {
			if mode != .Metal {
				if s := accel.cuda_strategy(); s.available() {
					accel.select_strategy(s)
					gpu_installed = true
				}
			}
		}
		if !gpu_installed {
			if mode != .Auto {
				log.warnf("accel: %v requested but unavailable; falling back to the multi-core CPU strategy", mode)
			}
			accel.use_cpu_parallel(workers)
			accel.cpu_pool_start()
		}
	}
	log.infof("accel: strategy %s", accel.active_strategy().name)
	return {ok = true}
}
