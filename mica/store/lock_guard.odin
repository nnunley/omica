// A stable inode serializes store ownership and stale-lock recovery. LOCK
// contains owner metadata and can be removed; LOCK.guard must never be removed
// while the store directory is in use. Closing the descriptor releases flock.
package store

import "core:c"
import "core:os"
import "core:path/filepath"
import "core:sys/posix"

when ODIN_OS == .Darwin {
	foreign import lock_lib "system:System"
} else {
	foreign import lock_lib "system:c"
}

foreign lock_lib {
	@(link_name = "flock")
	lock_flock :: proc(fd: c.int, operation: c.int) -> c.int ---
}

// Separate opens contend even in the same process. The descriptor is not
// inherited across exec. A busy guard never permits forced recovery.
@(private)
lock_guard_acquire :: proc(path: string) -> (file: ^os.File, busy: bool, err: os.Error) {
	guard_path, join_error := filepath.join([]string{path, "LOCK.guard"}, context.temp_allocator)
	if join_error != nil {
		return nil, false, .Invalid_Path
	}
	guard, open_error := os.open(guard_path, os.O_RDWR | os.O_CREATE)
	if open_error != nil {
		return nil, false, open_error
	}
	LOCK_EX :: 2
	LOCK_NB :: 4
	for lock_flock(c.int(os.fd(guard)), LOCK_EX | LOCK_NB) != 0 {
		lock_error := posix.errno()
		if lock_error == .EINTR {
			continue
		}
		os.close(guard)
		if lock_error == .EWOULDBLOCK {
			return nil, true, nil
		}
		return nil, false, os.Platform_Error(lock_error)
	}
	return guard, false, nil
}
