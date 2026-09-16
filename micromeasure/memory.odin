// Memory measurement for benchmarks.
//
// Reports the process peak resident set size (VmHWM), read from the kernel's
// own accounting. This is the right signal for "how much memory does a
// growing relation hold": it is the high-water mark of pages actually faulted
// into RAM, not the virtual reservation.
//
// VmHWM is process-lifetime and cannot be reset. A benchmark that wants a
// per-run number records the value before the timed region and reports the
// delta afterwards; the absolute number is still useful as a cross-check.
package micromeasure

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"

// Reads a named field from /proc/self/status (Linux). Returns 0 when the file
// is unreadable or the field is absent. The field value is in kilobytes.
read_status_field_kb :: proc(field: string) -> int {
	data, err := os.read_entire_file("/proc/self/status", context.allocator)
	if err != nil {
		return 0
	}
	defer delete(data)

	lines := strings.split_lines(string(data), context.temp_allocator)
	for line in lines {
		if strings.has_prefix(line, field) {
			rest := line[len(field):]
			rest = strings.trim_space(rest)
			// Strip the trailing " kB" suffix.
			if strings.has_suffix(rest, "kB") {
				rest = strings.trim_space(rest[:len(rest) - len("kB")])
			}
			kb, ok := strconv.parse_int(rest)
			if !ok {
				return 0
			}
			return kb
		}
	}
	return 0
}

// Returns the process peak RSS in bytes, as known to the kernel (VmHWM).
//
// The value is monotonic for the lifetime of the process: the kernel does not
// lower VmHWM. A benchmark that wants a per-run high-water records the value
// before the timed region and reports the delta afterwards.
peak_rss_bytes :: proc() -> int {
	return read_status_field_kb("VmHWM:") * 1024
}

// Returns the current RSS in bytes, as known to the kernel (VmRSS). Useful
// for measuring the working set of a timed region without the lifetime
// high-water bias.
current_rss_bytes :: proc() -> int {
	return read_status_field_kb("VmRSS:") * 1024
}

// Formats a byte count as a human-readable size (B, KiB, MiB, GiB).
format_bytes :: proc(bytes: int) -> string {
	if bytes < 1024 {
		return fmt.aprintf("%d B", bytes)
	}
	units := []string{"KiB", "MiB", "GiB"}
	value := f64(bytes) / 1024
	unit := "KiB"
	for i in 0 ..< len(units) {
		unit = units[i]
		if value < 1024 || i == len(units) - 1 {
			break
		}
		value /= 1024
	}
	return fmt.aprintf("%.1f %s", value, unit)
}
