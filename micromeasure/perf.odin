// Hardware performance counters via Linux perf_event_open.
//
// This mirrors the Rust micromeasure crate's PMU support: a group of CPU
// counters (cycles, instructions, branches, branch misses, cache events, and
// stall cycles) opened around the same measurement window as the wall clock,
// so a result carries work-per-operation in addition to time-per-operation.
// Time alone cannot separate dispatch overhead from the work an opcode does;
// instruction and cycle counts can.
//
// The counters are Linux-only. On any other platform, or when the kernel
// denies perf access, `counters_open` reports unavailable and the harness
// continues with timing only.
package micromeasure

import "core:fmt"
import "core:sys/linux"

when ODIN_OS == .Linux {

// The CPU counter set. Each field is optional: a counter the kernel will not
// schedule is simply absent, and its `has_*` flag stays false.
Counter_Kind :: enum {
	Cycles,
	Instructions,
	Cache_References,
	Cache_Misses,
	Branches,
	Branch_Misses,
	Stalled_Frontend,
	Stalled_Backend,
}

COUNTER_COUNT :: len(Counter_Kind)

counter_hardware_id :: proc(kind: Counter_Kind) -> linux.Perf_Hardware_Id {
	switch kind {
	case .Cycles:
		return .CPU_CYCLES
	case .Instructions:
		return .INSTRUCTIONS
	case .Cache_References:
		return .CACHE_REFERENCES
	case .Cache_Misses:
		return .CACHE_MISSES
	case .Branches:
		return .BRANCH_INSTRUCTIONS
	case .Branch_Misses:
		return .BRANCH_MISSES
	case .Stalled_Frontend:
		return .STALLED_CYCLES_FRONTEND
	case .Stalled_Backend:
		return .STALLED_CYCLES_BACKEND
	}
	return .INSTRUCTIONS
}

counter_name :: proc(kind: Counter_Kind) -> string {
	switch kind {
	case .Cycles:
		return "cycles"
	case .Instructions:
		return "instructions"
	case .Cache_References:
		return "cache_references"
	case .Cache_Misses:
		return "cache_misses"
	case .Branches:
		return "branches"
	case .Branch_Misses:
		return "branch_misses"
	case .Stalled_Frontend:
		return "stalled_cycles_frontend"
	case .Stalled_Backend:
		return "stalled_cycles_backend"
	}
	return "unknown"
}

// ioctl request numbers, from linux/perf_event.h: _IO('$', n).
PERF_IOC_ENABLE  :: u32(0x2400)
PERF_IOC_DISABLE :: u32(0x2401)
PERF_IOC_RESET   :: u32(0x2403)

// Counters are read as a plain u64 array when grouped; time fields are not
// requested, so each slot is one count.
Counter_Set :: struct {
	fds:      [COUNTER_COUNT]linux.Fd,
	open:     [COUNTER_COUNT]bool,
	// Last read values, and whether any counter is usable at all.
	values:   [COUNTER_COUNT]u64,
	usable:   bool,
	open_failed: bool,
}

// Opens and resets a counter group. `usable` is false when no counter could be
// opened, which is the normal case on non-Linux hosts or with restrictive
// perf_event_paranoid.
counters_open :: proc() -> Counter_Set {
	set: Counter_Set
	for kind in Counter_Kind {
		attr: linux.Perf_Event_Attr
		attr.type = .HARDWARE
		attr.size = u32(size_of(linux.Perf_Event_Attr))
		attr.config.hw = counter_hardware_id(kind)
		// Exclude kernel/hypervisor so the count describes this process.
		attr.flags = {.Exclude_Kernel, .Exclude_HV}
		fd, err := linux.perf_event_open(&attr, 0, -1, -1, {})
		if err != .NONE {
			continue
		}
		set.fds[kind] = fd
		set.open[kind] = true
		set.usable = true
	}
	return set
}

counters_close :: proc(set: ^Counter_Set) {
	for kind in Counter_Kind {
		if set.open[kind] {
			linux.close(set.fds[kind])
			set.open[kind] = false
		}
	}
	set.usable = false
}

// Resets and enables every open counter.
counters_begin :: proc(set: ^Counter_Set) {
	for kind in Counter_Kind {
		if !set.open[kind] {
			continue
		}
		_ = linux.ioctl(set.fds[kind], PERF_IOC_RESET, 0)
		_ = linux.ioctl(set.fds[kind], PERF_IOC_ENABLE, 0)
	}
}

// Disables every open counter and reads the counts into `values`.
counters_end :: proc(set: ^Counter_Set) {
	for kind in Counter_Kind {
		if !set.open[kind] {
			set.values[kind] = 0
			continue
		}
		_ = linux.ioctl(set.fds[kind], PERF_IOC_DISABLE, 0)
		buffer: [8]u8
		if n, err := linux.read(set.fds[kind], buffer[:]); err == .NONE && n == 8 {
			set.values[kind] = transmute(u64)buffer
		} else {
			set.values[kind] = 0
		}
	}
}

// Reports whether the last read produced a usable cycle count.
counters_has :: proc(set: ^Counter_Set, kind: Counter_Kind) -> bool {
	return set.open[kind]
}

} else {

// Non-Linux stub: the counters are never available, so callers compile and
// fall back to timing only.
Counter_Kind :: enum {
	Cycles,
	Instructions,
	Cache_References,
	Cache_Misses,
	Branches,
	Branch_Misses,
	Stalled_Frontend,
	Stalled_Backend,
}

COUNTER_COUNT :: len(Counter_Kind)

counter_name :: proc(kind: Counter_Kind) -> string {
	switch kind {
	case .Cycles:
		return "cycles"
	case .Instructions:
		return "instructions"
	case .Cache_References:
		return "cache_references"
	case .Cache_Misses:
		return "cache_misses"
	case .Branches:
		return "branches"
	case .Branch_Misses:
		return "branch_misses"
	case .Stalled_Frontend:
		return "stalled_cycles_frontend"
	case .Stalled_Backend:
		return "stalled_cycles_backend"
	}
	return "unknown"
}

Counter_Set :: struct {
	values:      [COUNTER_COUNT]u64,
	usable:      bool,
	open_failed: bool,
}

counters_open :: proc() -> Counter_Set {
	return {}
}
counters_close :: proc(set: ^Counter_Set) {}
counters_begin :: proc(set: ^Counter_Set) {}
counters_end :: proc(set: ^Counter_Set) {}
counters_has :: proc(set: ^Counter_Set, kind: Counter_Kind) -> bool {
	return false
}

}
