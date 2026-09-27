// Scratch memory for long-lived threads.
//
// A thread that loops forever cannot rely on anyone freeing its
// `context.temp_allocator`. `loop` gives each step of such a thread an arena
// that is emptied after the step, so temporaries never outlive one step.
package scratch

import "core:mem/virtual"

// Calls `step(data)` until it returns false. Each call runs with an arena as
// `context.temp_allocator`, emptied after the call. The arena is installed
// here, at the scope of the loop: a `context` assignment or `defer` inside an
// inner block would end with that block. If the arena cannot be created the
// steps still run, on the thread's default temp allocator.
loop :: proc(step: proc(data: rawptr) -> bool, data: rawptr) {
	arena: virtual.Arena
	ok := virtual.arena_init_growing(&arena) == nil
	defer if ok {
		virtual.arena_destroy(&arena)
	}
	context.temp_allocator = virtual.arena_allocator(&arena) if ok else context.temp_allocator
	for step(data) {
		free_all(context.temp_allocator)
	}
}
