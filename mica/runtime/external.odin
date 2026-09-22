// Host bridge for `External_Request` boundaries.
//
// A task that calls `external_request(service, payload)`, or one of the
// compiler-recognized LLM host requests that lower to it, parks with
// `.External_Request`. The world answers the request on a small pool of host
// worker threads, which call the `External_Handler` configured in
// `World_Config` and resume the task with the handler's return value. Without
// a handler, requests resume with an `ExternalUnavailable` error value.
//
// Streaming handlers deliver typed events to a mailbox as they arrive. They
// return `{:started -> true}` immediately and run the stream on a tracked
// worker thread; the world joins tracked streams before it is torn down.
package mica_runtime

import "core:mem"
import "core:mem/virtual"
import "core:sync"
import "core:thread"
import v "../var"

// A host-side handler for external requests. It runs on an external worker
// thread, so it must not touch transactions. Values it returns and delivers
// must come from `ctx.allocator`.
External_Handler :: proc(ctx: External_Context, service: v.Value, payload: v.Value) -> v.Value

// The runtime services a handler may use. The struct is passed by value so a
// stream worker can keep a copy after the request returns.
External_Context :: struct {
	// The parked task, for diagnostics.
	task:      Task_ID,
	// Owns every value the handler returns or delivers. Lives as long as the
	// world.
	allocator: mem.Allocator,
	// Opaque configuration supplied by the host in `World_Config`.
	host_data: rawptr,
	// Posts a value through a mailbox sender handle from a host thread.
	// Returns false when the mailbox is closed, revoked, or the world is
	// stopping.
	deliver:   proc(user: rawptr, sender: v.Value, value: v.Value) -> bool,
	user:      rawptr,
	// Spawns a tracked stream worker. `worker` owns `data` and must return
	// once `stopping` reports true. Returns false when no thread could start.
	spawn:     proc(user: rawptr, worker: proc(data: rawptr), data: rawptr) -> bool,
	// Reports whether the world is shutting down.
	stopping:  proc(user: rawptr) -> bool,
}

// A tracked stream worker and its thread.
@(private)
External_Stream :: struct {
	thread: ^thread.Thread,
	worker: proc(data: rawptr),
	data:   rawptr,
	done:   i32,
}

@(private)
external_worker_proc :: proc(data: rawptr) {
	// A private temporary scratch arena, like a scheduler worker. Handlers may
	// use `context.temp_allocator` for short-lived strings; it is reset after
	// every request.
	temp_arena: virtual.Arena
	has_temp_arena := virtual.arena_init_growing(&temp_arena) == nil
	if has_temp_arena {
		context.temp_allocator = virtual.arena_allocator(&temp_arena)
		defer virtual.arena_destroy(&temp_arena)
	}
	world := (^World)(data)
	job: External_Job
	for scheduler_take_external(&world.scheduler, &job) {
		ctx := External_Context {
			task      = job.task_id,
			allocator = world.allocator,
			host_data = world.external_data,
			deliver   = world_external_deliver,
			user      = world,
			spawn     = world_external_spawn,
			stopping  = world_external_stopping,
		}
		result := world.external_handler(ctx, job.service, job.payload)
		scheduler_resume(&world.scheduler, job.task_id, result)
		if has_temp_arena {
			virtual.arena_free_all(&temp_arena)
		}
	}
}

@(private)
external_stream_proc :: proc(data: rawptr) {
	// Stream workers get their own scratch arena too; it lives for the stream
	// and is released when the worker returns.
	temp_arena: virtual.Arena
	if err := virtual.arena_init_growing(&temp_arena); err == nil {
		context.temp_allocator = virtual.arena_allocator(&temp_arena)
		defer virtual.arena_destroy(&temp_arena)
	}
	entry := (^External_Stream)(data)
	entry.worker(entry.data)
	sync.atomic_store(&entry.done, 1)
}

// Delivers a value through a mailbox sender handle. Safe to call from an
// external worker thread.
@(private)
world_external_deliver :: proc(user: rawptr, sender: v.Value, value: v.Value) -> bool {
	world := (^World)(user)
	if sync.atomic_load(&world.external_stopping) != 0 {
		return false
	}
	return scheduler_mailbox_send(&world.scheduler, sender, value)
}

// Spawns and tracks a stream worker. Finished workers are reaped here and at
// world shutdown.
@(private)
world_external_spawn :: proc(user: rawptr, worker: proc(data: rawptr), data: rawptr) -> bool {
	world := (^World)(user)
	entry := new(External_Stream, world.allocator)
	entry.worker = worker
	entry.data = data

	sync.mutex_lock(&world.external_lock)
	kept := 0
	for index := 0; index < len(world.external_streams); index += 1 {
		stream := world.external_streams[index]
		if sync.atomic_load(&stream.done) == 0 {
			world.external_streams[kept] = stream
			kept += 1
			continue
		}
		thread.join(stream.thread)
		thread.destroy(stream.thread)
		free(stream, world.allocator)
	}
	resize(&world.external_streams, kept)
	sync.mutex_unlock(&world.external_lock)

	started := thread.create_and_start_with_data(entry, external_stream_proc)
	if started == nil {
		free(entry, world.allocator)
		return false
	}
	entry.thread = started
	sync.mutex_lock(&world.external_lock)
	append(&world.external_streams, entry)
	sync.mutex_unlock(&world.external_lock)
	return true
}

@(private)
world_external_stopping :: proc(user: rawptr) -> bool {
	world := (^World)(user)
	return sync.atomic_load(&world.external_stopping) != 0
}

// Starts the external worker pool. Worlds without a handler stay inert: the
// scheduler answers external requests inline, so this allocates nothing and
// starts no thread.
@(private)
world_start_external :: proc(world: ^World, config: World_Config) {
	world.external_handler = config.external_handler
	world.external_data = config.external_data
	if world.external_handler == nil {
		return
	}
	world.external_streams = make([dynamic]^External_Stream, world.allocator)
	world.external_workers = make([dynamic]^thread.Thread, world.allocator)

	workers := config.external_workers
	if workers < 1 {
		workers = 1
	}
	for _ in 0 ..< workers {
		worker := thread.create_and_start_with_data(world, external_worker_proc)
		if worker != nil {
			append(&world.external_workers, worker)
		}
	}
}

// Stops the external worker pool and joins every tracked stream before the
// scheduler is destroyed. Streams deliver through scheduler mailboxes, so the
// scheduler must outlive them.
@(private)
world_stop_external :: proc(world: ^World) {
	if world.external_handler == nil {
		return
	}
	sync.atomic_store(&world.external_stopping, 1)
	scheduler_stop_external(&world.scheduler)

	for worker in world.external_workers {
		thread.join(worker)
		thread.destroy(worker)
	}
	delete(world.external_workers)

	sync.mutex_lock(&world.external_lock)
	for stream in world.external_streams {
		thread.join(stream.thread)
		thread.destroy(stream.thread)
		free(stream, world.allocator)
	}
	delete(world.external_streams)
	sync.mutex_unlock(&world.external_lock)
}
