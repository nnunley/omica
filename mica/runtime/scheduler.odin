// A multithreaded task scheduler.
//
// One task runs per worker thread at a time. A task runs to its next host
// boundary on that worker, commits, and either completes or parks with a wake
// condition: ready (yield), a timer (sleep), or a host resume. Suspended tasks
// release their worker; the worker picks up the next runnable task.
//
// A single timer service thread wakes sleeping tasks. Timer entries carry a
// generation so a task that is resumed by other means ignores its stale timer.
package mica_runtime

import "core:fmt"
import "core:mem"
import "core:slice"
import "core:sync"
import "core:thread"
import "core:time"
import k "../kernel"
import vm "../vm"
import v "../var"

Scheduler_Config :: struct {
	workers: int,
}

DEFAULT_SCHEDULER_WORKERS :: 8

@(private)
Timer_Entry :: struct {
	deadline:   time.Tick,
	task_id:    Task_ID,
	generation: u64,
}

@(private)
Mailbox_Waiter :: struct {
	task_id:  Task_ID,
	receiver: v.Value,
}

@(private)
Mailbox :: struct {
	messages: [dynamic]v.Value,
	waiters:  [dynamic]Mailbox_Waiter,
	receiver: v.Value,
	sender:   v.Value,
	closed:   bool,
}

@(private)
Scheduler_Entry :: struct {
	task:          ^Task,
	started:       bool,
	generation:    u64,
	running:       bool,
	cancelled:     bool,
	owned_program: bool,
	arguments:     []v.Value,
	has_pending:   bool,
	pending_value: v.Value,
	result:        Task_Outcome,
	done:          bool,
}

Scheduler :: struct {
	kernel:    ^k.Kernel,
	allocator: mem.Allocator,

	lock: sync.Mutex,
	cond: sync.Cond,
	stop: bool,

	ready:   [dynamic]Task_ID,
	timers:  [dynamic]Timer_Entry,
	entries: map[Task_ID]^Scheduler_Entry,

	mailboxes:    map[u64]^Mailbox,
	next_mailbox: u64,

	threads: [dynamic]^thread.Thread,
	timer:   ^thread.Thread,

	next_id: u64,
	started: bool,
}

scheduler_init :: proc(
	scheduler: ^Scheduler,
	kernel: ^k.Kernel,
	config := Scheduler_Config{workers = DEFAULT_SCHEDULER_WORKERS},
	allocator := context.allocator,
) {
	scheduler.kernel = kernel
	scheduler.allocator = allocator
	scheduler.ready = make([dynamic]Task_ID, allocator)
	scheduler.timers = make([dynamic]Timer_Entry, allocator)
	scheduler.entries = make(map[Task_ID]^Scheduler_Entry, allocator)
	scheduler.mailboxes = make(map[u64]^Mailbox, allocator)
	scheduler.threads = make([dynamic]^thread.Thread, allocator)
	scheduler.next_id = 1

	scheduler.started = true
	worker_count := max(config.workers, 1)
	for _ in 0 ..< worker_count {
		worker := thread.create_and_start_with_data(scheduler, scheduler_worker_proc)
		append(&scheduler.threads, worker)
	}
	scheduler.timer = thread.create_and_start_with_data(scheduler, scheduler_timer_proc)
}

scheduler_destroy :: proc(scheduler: ^Scheduler) {
	scheduler_shutdown(scheduler)

	for _, entry in scheduler.entries {
		task_destroy(entry.task)
		if entry.owned_program {
			vm.program_destroy(entry.task.program, scheduler.allocator)
		}
		if entry.arguments != nil {
			delete(entry.arguments, scheduler.allocator)
		}
		free(entry.task, scheduler.allocator)
		free(entry, scheduler.allocator)
	}
	for _, mailbox in scheduler.mailboxes {
		delete(mailbox.messages)
		delete(mailbox.waiters)
		free(mailbox, scheduler.allocator)
	}
	delete(scheduler.mailboxes)
	delete(scheduler.entries)
	delete(scheduler.ready)
	delete(scheduler.timers)
	delete(scheduler.threads)
}

// Stops the worker and timer threads and waits for them.
scheduler_shutdown :: proc(scheduler: ^Scheduler) {
	if !scheduler.started {
		return
	}
	sync.mutex_lock(&scheduler.lock)
	scheduler.stop = true
	sync.cond_broadcast(&scheduler.cond)
	sync.mutex_unlock(&scheduler.lock)

	for worker in scheduler.threads {
		thread.join(worker)
		thread.destroy(worker)
	}
	thread.join(scheduler.timer)
	thread.destroy(scheduler.timer)
	clear(&scheduler.threads)
	scheduler.started = false
}

// Takes ownership of `task` and makes it runnable. The task must already be
// initialized; its id is assigned here.
scheduler_submit :: proc(scheduler: ^Scheduler, task: ^Task) -> Task_ID {
	return scheduler_submit_task(scheduler, task, 0, false)
}

// Submits a task that owns its program. `scheduler_release` destroys the
// program together with the task.
scheduler_submit_owned :: proc(scheduler: ^Scheduler, task: ^Task) -> Task_ID {
	return scheduler_submit_task(scheduler, task, 0, true)
}

@(private)
scheduler_submit_task :: proc(
	scheduler: ^Scheduler,
	task: ^Task,
	delay_millis: i64,
	owned_program: bool,
	arguments: []v.Value = nil,
) -> Task_ID {
	sync.mutex_lock(&scheduler.lock)
	id := Task_ID(scheduler.next_id)
	scheduler.next_id += 1
	task.id = id
	entry := new(Scheduler_Entry, scheduler.allocator)
	entry.task = task
	entry.result = Task_Outcome{kind = .Pending}
	entry.owned_program = owned_program
	entry.arguments = arguments
	scheduler.entries[id] = entry
	if delay_millis > 0 {
		entry.generation = 1
		scheduler_push_timer(scheduler, Timer_Entry {
			deadline   = time.tick_add(time.tick_now(), time.Duration(delay_millis) * time.Millisecond),
			task_id    = id,
			generation = entry.generation,
		})
	} else {
		append(&scheduler.ready, id)
	}
	sync.cond_broadcast(&scheduler.cond)
	sync.mutex_unlock(&scheduler.lock)
	return id
}

// Requests cancellation. A parked task aborts immediately; a running task
// aborts at its next boundary. Returns the outcome if the task was terminal.
scheduler_cancel :: proc(scheduler: ^Scheduler, id: Task_ID) -> Task_Outcome {
	sync.mutex_lock(&scheduler.lock)
	entry, found := scheduler.entries[id]
	if !found || entry.done {
		sync.mutex_unlock(&scheduler.lock)
		if found {
			return entry.result
		}
		return Task_Outcome{kind = .Aborted, message = "unknown task"}
	}
	entry.cancelled = true
	entry.task.cancel_requested = true
	if !entry.running {
		scheduler_remove_mailbox_waiter_locked(scheduler, id)
		entry.result = task_cancel(entry.task)
		entry.done = true
		sync.cond_broadcast(&scheduler.cond)
	}
	result := entry.result
	sync.mutex_unlock(&scheduler.lock)
	return result
}

// Resumes a parked task with a value from the host. The task is queued for a
// worker; returns false when the task is unknown, terminal, busy, or already
// has a pending wakeup.
scheduler_resume :: proc(scheduler: ^Scheduler, id: Task_ID, value: v.Value) -> bool {
	sync.mutex_lock(&scheduler.lock)
	entry, found := scheduler.entries[id]
	if !found || entry.done || entry.running || entry.has_pending {
		sync.mutex_unlock(&scheduler.lock)
		return false
	}
	entry.has_pending = true
	entry.pending_value = value
	append(&scheduler.ready, id)
	sync.cond_broadcast(&scheduler.cond)
	sync.mutex_unlock(&scheduler.lock)
	return true
}

// Applies a task outcome and parks, requeues, or finishes the entry. The
// caller must hold the scheduler lock.
@(private)
scheduler_finish_locked :: proc(
	scheduler: ^Scheduler,
	id: Task_ID,
	entry: ^Scheduler_Entry,
	outcome: Task_Outcome,
) {
	entry.result = outcome
	#partial switch outcome.kind {
	case .Pending:
		switch outcome.suspend {
		case .Yield:
			append(&scheduler.ready, id)
		case .Sleep:
			entry.generation += 1
			scheduler_push_timer(scheduler, Timer_Entry {
				deadline   = time.tick_add(time.tick_now(), time.Duration(outcome.millis) * time.Millisecond),
				task_id    = id,
				generation = entry.generation,
			})
		case .Mailbox_Recv:
			scheduler_park_mailbox_locked(scheduler, id, entry, outcome.millis)
		case .Host_Request, .External_Request, .Spawn, .Commit, .None:
			// Parked until a host resumes the task.
		}
	case .Complete, .Aborted:
		entry.done = true
	}
}

// Spawns resume the parent immediately with the child id; the child runs on
// another worker.
@(private)
scheduler_run_spawns :: proc(
	scheduler: ^Scheduler,
	task: ^Task,
	outcome: Task_Outcome,
) -> Task_Outcome {
	result := outcome
	for result.kind == .Pending && result.suspend == .Spawn {
		child_id := scheduler_spawn_child(scheduler, task)
		child_value, _ := v.value_int(i64(child_id))
		result = task_resume_with(task, child_value)
	}
	return result
}

// --- Mailboxes -------------------------------------------------------------
//
// Mailbox endpoints are capability handles in the world capability store.
// Revoking or closing a handle invalidates it for every holder; the queue
// itself lives in the scheduler until shutdown.

// Resolves a mailbox handle of the requested kind. Epoch limits do not apply
// to mailbox handles, which are minted without them.
@(private)
mailbox_target :: proc(
	scheduler: ^Scheduler,
	value: v.Value,
	sender: bool,
) -> (
	u64,
	^k.Capability_Grant,
	bool,
) {
	grant, found := k.capability_store_lookup(&scheduler.kernel.capabilities, value)
	if !found || !k.capability_live(grant, 0, time.tick_now()) {
		return 0, nil, false
	}
	mailbox, target_ok := k.capability_mailbox_target(grant, sender)
	return mailbox, grant, target_ok
}

// Creates a mailbox and returns its receiver and sender handles.
scheduler_mailbox_create :: proc(
	scheduler: ^Scheduler,
) -> (
	receiver: v.Value,
	sender: v.Value,
	ok: bool,
) {
	sync.mutex_lock(&scheduler.lock)
	scheduler.next_mailbox += 1
	mailbox := scheduler.next_mailbox
	box := new(Mailbox, scheduler.allocator)
	box.messages = make([dynamic]v.Value, scheduler.allocator)
	box.waiters = make([dynamic]Mailbox_Waiter, scheduler.allocator)
	receiver_value, sender_value, minted := k.capability_store_mint_mailbox_pair(
		&scheduler.kernel.capabilities,
		mailbox,
	)
	box.receiver = receiver_value
	box.sender = sender_value
	scheduler.mailboxes[mailbox] = box
	sync.mutex_unlock(&scheduler.lock)
	return receiver_value, sender_value, minted
}

// Delivers a value through a sender handle, waking the first waiter.
scheduler_mailbox_send :: proc(
	scheduler: ^Scheduler,
	sender: v.Value,
	value: v.Value,
) -> bool {
	mailbox, _, ok := mailbox_target(scheduler, sender, true)
	if !ok {
		return false
	}
	if !mailbox_handle_live(scheduler, sender, true) {
		return false
	}
	sync.mutex_lock(&scheduler.lock)
	box, found := scheduler.mailboxes[mailbox]
	if !found || box.closed {
		sync.mutex_unlock(&scheduler.lock)
		return false
	}
	receiver_live := false
	if receiver_grant, receiver_found := k.capability_store_lookup(
		&scheduler.kernel.capabilities,
		box.receiver,
	); receiver_found {
		receiver_live = k.capability_live(receiver_grant, 0, time.tick_now())
	}
	if !receiver_live {
		sync.mutex_unlock(&scheduler.lock)
		return false
	}
	append(&box.messages, value)
	scheduler_wake_mailbox_locked(scheduler, box)
	sync.cond_broadcast(&scheduler.cond)
	sync.mutex_unlock(&scheduler.lock)
	return true
}

// Delivers a subscription message through a sender handle, bounding the number
// of queued messages that belong to `capability`. When the budget is reached
// the queued messages are replaced by `marker` and overflow is true.
scheduler_mailbox_deliver_subscription :: proc(
	scheduler: ^Scheduler,
	sender: v.Value,
	capability: v.Value,
	message: v.Value,
	marker: v.Value,
	budget: int,
) -> (
	ok: bool,
	overflow: bool,
) {
	mailbox, _, target_ok := mailbox_target(scheduler, sender, true)
	if !target_ok {
		return false, false
	}
	sync.mutex_lock(&scheduler.lock)
	defer sync.mutex_unlock(&scheduler.lock)
	box, found := scheduler.mailboxes[mailbox]
	if !found || box.closed || !mailbox_receiver_live_locked(scheduler, box) {
		return false, false
	}
	queued := 0
	for entry in box.messages {
		if v.value_eq(subscription_message_capability(entry), capability) {
			queued += 1
		}
	}
	if queued >= budget {
		overflow = true
		subscription_messages_remove_locked(box, capability)
	}
	append(&box.messages, overflow ? marker : message)
	scheduler_wake_mailbox_locked(scheduler, box)
	sync.cond_broadcast(&scheduler.cond)
	return true, overflow
}

// Replaces every queued message that belongs to `capability` with `value`.
scheduler_mailbox_replace_subscription :: proc(
	scheduler: ^Scheduler,
	sender: v.Value,
	capability: v.Value,
	value: v.Value,
) -> bool {
	mailbox, _, target_ok := mailbox_target(scheduler, sender, true)
	if !target_ok {
		return false
	}
	sync.mutex_lock(&scheduler.lock)
	defer sync.mutex_unlock(&scheduler.lock)
	box, found := scheduler.mailboxes[mailbox]
	if !found || box.closed || !mailbox_receiver_live_locked(scheduler, box) {
		return false
	}
	subscription_messages_remove_locked(box, capability)
	append(&box.messages, value)
	scheduler_wake_mailbox_locked(scheduler, box)
	sync.cond_broadcast(&scheduler.cond)
	return true
}

@(private)
mailbox_receiver_live_locked :: proc(scheduler: ^Scheduler, box: ^Mailbox) -> bool {
	receiver_grant, receiver_found := k.capability_store_lookup(
		&scheduler.kernel.capabilities,
		box.receiver,
	)
	return receiver_found && k.capability_live(receiver_grant, 0, time.tick_now())
}

// Removes queued subscription messages for `capability`. The caller holds the
// scheduler lock.
@(private)
subscription_messages_remove_locked :: proc(box: ^Mailbox, capability: v.Value) {
	write := 0
	for entry in box.messages {
		if v.value_eq(subscription_message_capability(entry), capability) {
			continue
		}
		box.messages[write] = entry
		write += 1
	}
	resize(&box.messages, write)
}

// Returns the `:subscription` cell of a subscription message, or zero.
@(private)
subscription_message_capability :: proc(value: v.Value) -> v.Value {
	entries, is_map := v.value_as_map(value)
	if !is_map {
		return v.Value(0)
	}
	key := v.value_symbol(v.symbol_intern("subscription"))
	for entry in entries {
		if v.value_eq(entry.key, key) {
			return entry.value
		}
	}
	return v.Value(0)
}

// Closes a mailbox from its receiver handle, revoking both endpoints.
scheduler_mailbox_close :: proc(scheduler: ^Scheduler, receiver: v.Value) -> bool {
	mailbox, _, ok := mailbox_target(scheduler, receiver, false)
	if !ok {
		return false
	}
	sync.mutex_lock(&scheduler.lock)
	box, found := scheduler.mailboxes[mailbox]
	if !found || box.closed {
		sync.mutex_unlock(&scheduler.lock)
		return found
	}
	box.closed = true
	sync.mutex_unlock(&scheduler.lock)
	k.capability_store_revoke(&scheduler.kernel.capabilities, box.receiver)
	k.capability_store_revoke(&scheduler.kernel.capabilities, box.sender)
	return true
}

// Wakes the first waiter of `box` with all queued messages for that mailbox.
@(private)
scheduler_wake_mailbox_locked :: proc(scheduler: ^Scheduler, box: ^Mailbox) {
	if len(box.messages) == 0 || len(box.waiters) == 0 {
		return
	}
	waiter := box.waiters[0]
	ordered_remove(&box.waiters, 0)
	entry, found := scheduler.entries[waiter.task_id]
	if !found || entry.done || entry.has_pending {
		return
	}
	messages := v.value_list(scheduler.allocator, box.messages[:])
	clear(&box.messages)
	group := v.value_list(scheduler.allocator, []v.Value{waiter.receiver, messages})
	entry.pending_value = v.value_list(scheduler.allocator, []v.Value{group})
	entry.has_pending = true
	entry.generation += 1
	append(&scheduler.ready, waiter.task_id)
}

// The result of draining mailbox receivers.
Mailbox_Take_Kind :: enum {
	Ready,
	Empty,
	No_Receivers,
}

Mailbox_Take :: struct {
	kind:  Mailbox_Take_Kind,
	value: v.Value,
}

// Drains ready messages for the receivers of a task parked on `mailbox_recv`.
// `No_Receivers` means every supplied handle is unknown, revoked, or expired.
scheduler_mailbox_take :: proc(scheduler: ^Scheduler, task: ^Task) -> Mailbox_Take {
	receivers, is_list := v.value_as_list(task.state.request_value)
	if !is_list || len(receivers) == 0 {
		return Mailbox_Take{kind = .No_Receivers}
	}
	groups: [dynamic]v.Value
	defer delete(groups)
	live_receivers := 0
	sync.mutex_lock(&scheduler.lock)
	for receiver in receivers {
		mailbox, _, ok := mailbox_target(scheduler, receiver, false)
		if !ok {
			continue
		}
		live_receivers += 1
		box, found := scheduler.mailboxes[mailbox]
		if !found || len(box.messages) == 0 {
			continue
		}
		messages := v.value_list(scheduler.allocator, box.messages[:])
		clear(&box.messages)
		group := v.value_list(scheduler.allocator, []v.Value{receiver, messages})
		append(&groups, group)
	}
	sync.mutex_unlock(&scheduler.lock)
	if len(groups) > 0 {
		return Mailbox_Take {
			kind  = .Ready,
			value = v.value_list(scheduler.allocator, groups[:]),
		}
	}
	if live_receivers == 0 {
		return Mailbox_Take{kind = .No_Receivers}
	}
	return Mailbox_Take{kind = .Empty}
}

// Drains queued messages for a receiver handle. The caller owns the returned
// messages and the dynamic array. Returns false for an unknown handle.
scheduler_mailbox_drain :: proc(
	scheduler: ^Scheduler,
	receiver: v.Value,
	allocator: mem.Allocator,
) -> (
	[dynamic]v.Value,
	bool,
) {
	mailbox, _, ok := mailbox_target(scheduler, receiver, false)
	if !ok {
		return nil, false
	}
	sync.mutex_lock(&scheduler.lock)
	defer sync.mutex_unlock(&scheduler.lock)
	box, found := scheduler.mailboxes[mailbox]
	if !found {
		return nil, false
	}
	messages := make([dynamic]v.Value, allocator)
	append(&messages, ..box.messages[:])
	clear(&box.messages)
	return messages, true
}

// Reports whether a mailbox handle is a live endpoint of the requested kind.
@(private)
mailbox_handle_live :: proc(scheduler: ^Scheduler, value: v.Value, sender: bool) -> bool {
	_, _, ok := mailbox_target(scheduler, value, sender)
	return ok
}

// Reports whether `value` is a live receiver handle.
scheduler_mailbox_handle_live :: proc(scheduler: ^Scheduler, value: v.Value) -> bool {
	return mailbox_handle_live(scheduler, value, false)
}

// Reports whether `value` is a live sender handle.
scheduler_mailbox_sender_handle_live :: proc(scheduler: ^Scheduler, value: v.Value) -> bool {
	return mailbox_handle_live(scheduler, value, true)
}

@(private)
scheduler_park_mailbox_locked :: proc(
	scheduler: ^Scheduler,
	id: Task_ID,
	entry: ^Scheduler_Entry,
	millis: i64,
) {
	receivers, is_list := v.value_as_list(entry.task.state.request_value)
	if is_list {
		seen: [dynamic]u64
		defer delete(seen)
		for receiver in receivers {
			mailbox, _, ok := mailbox_target(scheduler, receiver, false)
			if !ok {
				continue
			}
			duplicate := false
			for existing in seen {
				if existing == mailbox {
					duplicate = true
					break
				}
			}
			if duplicate {
				continue
			}
			box, found := scheduler.mailboxes[mailbox]
			if !found {
				continue
			}
			append(&seen, mailbox)
			append(&box.waiters, Mailbox_Waiter {
				task_id  = id,
				receiver = receiver,
			})
		}
	}
	if millis > 0 {
		entry.generation += 1
		scheduler_push_timer(scheduler, Timer_Entry {
			deadline   = time.tick_add(time.tick_now(), time.Duration(millis) * time.Millisecond),
			task_id    = id,
			generation = entry.generation,
		})
	}
}

@(private)
scheduler_remove_mailbox_waiter_locked :: proc(scheduler: ^Scheduler, id: Task_ID) {
	for _, box in scheduler.mailboxes {
		for waiter, index in box.waiters {
			if waiter.task_id == id {
				ordered_remove(&box.waiters, index)
				break
			}
		}
	}
}

// Blocks until the task reaches a terminal outcome.
scheduler_wait :: proc(scheduler: ^Scheduler, id: Task_ID) -> Task_Outcome {
	sync.mutex_lock(&scheduler.lock)
	defer sync.mutex_unlock(&scheduler.lock)
	for {
		entry, found := scheduler.entries[id]
		if !found {
			return Task_Outcome{kind = .Aborted, message = "unknown task"}
		}
		if entry.done {
			return entry.result
		}
		sync.cond_wait(&scheduler.cond, &scheduler.lock)
	}
}

// Returns one map per managed task, sorted by id: `:id` is the task id and
// `:state` is `:running` or `:suspended`. Terminal tasks are omitted.
scheduler_task_values :: proc(scheduler: ^Scheduler, allocator: mem.Allocator) -> []v.Value {
	sync.mutex_lock(&scheduler.lock)
	defer sync.mutex_unlock(&scheduler.lock)

	ids: [dynamic]Task_ID
	ids = make([dynamic]Task_ID, 0, len(scheduler.entries), context.temp_allocator)
	for id, entry in scheduler.entries {
		if entry.done {
			continue
		}
		append(&ids, id)
	}
	slice.sort(ids[:])

	values := make([]v.Value, len(ids), allocator)
	for id, index in ids {
		entry := scheduler.entries[id]
		state := "suspended"
		if entry.running {
			state = "running"
		}
		id_value, id_ok := v.value_int(i64(id))
		if !id_ok {
			id_value = v.value_string(allocator, fmt.aprintf("%d", id, allocator = context.temp_allocator))
		}
		values[index] = v.value_map(allocator, []v.Map_Entry {
			{
				key   = v.value_symbol(v.symbol_intern("id")),
				value = id_value,
			},
			{
				key   = v.value_symbol(v.symbol_intern("state")),
				value = v.value_symbol(v.symbol_intern(state)),
			},
		})
	}
	return values
}

// Returns the latest outcome without blocking. Reports false while the task is
// running, queued but not started, or unknown.
scheduler_task_outcome :: proc(scheduler: ^Scheduler, id: Task_ID) -> (Task_Outcome, bool) {
	sync.mutex_lock(&scheduler.lock)
	defer sync.mutex_unlock(&scheduler.lock)
	entry, found := scheduler.entries[id]
	if !found || entry.running || entry.has_pending || !entry.started {
		return Task_Outcome{}, false
	}
	return entry.result, true
}

// Returns the metadata of a task parked on `read`. The boolean reports
// whether the task is currently waiting for host input.
scheduler_task_request :: proc(scheduler: ^Scheduler, id: Task_ID) -> (v.Value, bool) {
	sync.mutex_lock(&scheduler.lock)
	defer sync.mutex_unlock(&scheduler.lock)
	entry, found := scheduler.entries[id]
	if !found || entry.done || entry.running {
		return v.Value(0), false
	}
	if entry.result.kind != .Pending || entry.result.suspend != .Host_Request {
		return v.Value(0), false
	}
	return entry.result.request, true
}

// Frees a terminal task entry. Call after reading the outcome. The outcome's
// value stays valid because owner values live in the world allocator.
scheduler_release :: proc(scheduler: ^Scheduler, id: Task_ID) {
	entry: ^Scheduler_Entry
	sync.mutex_lock(&scheduler.lock)
	if found, exists := scheduler.entries[id]; exists && found.done {
		delete_key(&scheduler.entries, id)
		entry = found
	}
	sync.mutex_unlock(&scheduler.lock)
	if entry == nil {
		return
	}
	if entry.owned_program {
		vm.program_destroy(entry.task.program, scheduler.allocator)
	}
	if entry.arguments != nil {
		delete(entry.arguments, scheduler.allocator)
	}
	task_destroy(entry.task)
	free(entry.task, scheduler.allocator)
	free(entry, scheduler.allocator)
}

// Returns true when every submitted task has reached a terminal outcome.
scheduler_idle :: proc(scheduler: ^Scheduler) -> bool {
	sync.mutex_lock(&scheduler.lock)
	defer sync.mutex_unlock(&scheduler.lock)
	for _, entry in scheduler.entries {
		if !entry.done {
			return false
		}
	}
	return true
}

@(private)
scheduler_push_timer :: proc(scheduler: ^Scheduler, entry: Timer_Entry) {
	insert := len(scheduler.timers)
	for index in 0 ..< len(scheduler.timers) {
		if time.tick_diff(entry.deadline, scheduler.timers[index].deadline) > 0 {
			insert = index
			break
		}
	}
	append(&scheduler.timers, Timer_Entry{})
	copy(scheduler.timers[insert + 1:], scheduler.timers[insert:])
	scheduler.timers[insert] = entry
}

// Why a dispatch submission failed.
Dispatch_Error :: enum {
	None,
	// No method matched the selector and roles.
	No_Method,
	// The method has no program index or it is not an integer.
	No_Program,
	// The method parameters cannot bind to the supplied roles.
	Arguments,
	// A prepared fact could not be asserted; see `kernel`.
	Fact,
}

Dispatch_Result :: struct {
	id:     Task_ID,
	error:  Dispatch_Error,
	kernel: k.Kernel_Error,
}

// Resolves `selector` with `roles` and submits a task that starts at the
// method's function in `program`. `facts` are asserted into the task
// transaction before it starts. A zero id means the submission failed.
scheduler_submit_dispatch :: proc(
	scheduler: ^Scheduler,
	env: ^Builtin_Env,
	program: ^vm.Program,
	selector: v.Value,
	roles: []k.Role_Pair,
	delay_millis: i64,
	facts: []World_Fact = nil,
	options: World_Call_Options = {},
) -> Dispatch_Result {
	snapshot := k.kernel_snapshot(scheduler.kernel)
	defer k.snapshot_release(snapshot)
	source := k.Relation_Source {
		snapshot           = snapshot,
		use_stored_derived = true,
	}
	relations := k.Dispatch_Relations {
		method_selector = k.DISPATCH_METHOD_SELECTOR_ID,
		param           = k.DISPATCH_PARAM_ID,
		delegates       = k.DISPATCH_DELEGATES_ID,
	}
	entries := k.applicable_method_entries(
		&source,
		relations,
		selector,
		roles,
		context.temp_allocator,
	)
	if len(entries) == 0 {
		return Dispatch_Result{error = .No_Method}
	}
	method := entries[0]
	program_value, found := k.dispatch_method_program(
		&source,
		k.DISPATCH_METHOD_PROGRAM_ID,
		method.method,
	)
	if !found {
		return Dispatch_Result{error = .No_Program}
	}
	function_index, is_int := v.value_as_int(program_value)
	if !is_int {
		return Dispatch_Result{error = .No_Program}
	}
	arguments, args_ok := k.dispatch_method_args(
		method.params,
		roles,
		scheduler.allocator,
	)
	if !args_ok {
		return Dispatch_Result{error = .Arguments}
	}

	task := new(Task, scheduler.allocator)
	task_init(task, 0, scheduler.kernel, program, env, scheduler.allocator)
	for fact in facts {
		if err := k.transaction_assert(&task.tx, fact.relation, fact.tuple); err != .None {
			task_destroy(task)
			free(task, scheduler.allocator)
			return Dispatch_Result{error = .Fact, kernel = err}
		}
	}
	// A per-call actor overrides the world identities for this task.
	if !v.value_is_empty_relation(options.actor) {
		endpoint := options.endpoint
		if v.value_is_empty_relation(endpoint) {
			endpoint = env.endpoint
		}
		principal := options.principal
		if v.value_is_empty_relation(principal) {
			principal = options.actor
		}
		vm.vm_set_identities(&task.state, endpoint, options.actor, principal)
		// The task authority was minted from the world default in `task_init`;
		// remint it from the effective per-call actor.
		if env != nil && env.enforce_authority {
			if _, has_actor := v.value_as_identity(options.actor); has_actor {
				task_set_actor_authority(task, options.actor, scheduler.allocator)
			}
		}
	}
	vm.vm_set_entry_function(&task.state, i32(function_index))
	vm.vm_set_entry_arguments(&task.state, arguments)
	id := scheduler_submit_task(
		scheduler,
		task,
		delay_millis,
		false,
		arguments,
	)
	return Dispatch_Result{id = id}
}

// Builds a child task from a parent's `.Spawn` suspension. The selector and
// role values are resolved through the kernel's dispatch relations to the
// method's function, which the child starts at in the shared world program.
// The parent is resumed with the child's task id.
@(private)
scheduler_spawn_child :: proc(scheduler: ^Scheduler, parent: ^Task) -> Task_ID {
	spec := parent.program.dispatch_specs[parent.state.request_spec]
	base := vm.vm_frame_base(&parent.state)

	roles := make([]k.Role_Pair, len(spec.roles), context.temp_allocator)
	for role, index in spec.roles {
		roles[index] = k.Role_Pair {
			role  = v.value_symbol(role.role),
			value = parent.state.registers[base + int(role.register)],
		}
	}
	result := scheduler_submit_dispatch(
		scheduler,
		parent.env,
		parent.program,
		v.value_symbol(spec.selector),
		roles,
		parent.state.request_millis,
	)
	return result.id
}

@(private)
scheduler_worker_proc :: proc(data: rawptr) {
	scheduler := (^Scheduler)(data)
	for {
		sync.mutex_lock(&scheduler.lock)
		for len(scheduler.ready) == 0 && !scheduler.stop {
			sync.cond_wait(&scheduler.cond, &scheduler.lock)
		}
		if scheduler.stop {
			sync.mutex_unlock(&scheduler.lock)
			return
		}
		id := pop(&scheduler.ready)
		entry := scheduler.entries[id]
		entry.running = true
		sync.mutex_unlock(&scheduler.lock)

		outcome: Task_Outcome
		if entry.has_pending {
			pending := entry.pending_value
			entry.has_pending = false
			outcome = task_resume_with(entry.task, pending)
		} else if entry.started {
			outcome = task_resume(entry.task)
		} else {
			outcome = task_run(entry.task)
			entry.started = true
		}

		// Spawns resume the parent immediately with the child id; the child
		// runs on another worker.
		outcome = scheduler_run_spawns(scheduler, entry.task, outcome)

		// Mailbox receives with queued messages resume without parking.
		for outcome.kind == .Pending && outcome.suspend == .Mailbox_Recv {
			take := scheduler_mailbox_take(scheduler, entry.task)
			switch take.kind {
			case .Ready:
				outcome = task_resume_with(entry.task, take.value)
				continue
			case .No_Receivers:
				outcome = task_fail(
					entry.task,
					"E_INVARG",
					"mailbox has no live receivers",
				)
			case .Empty:
				if outcome.millis == 0 {
					empty := v.value_list(scheduler.allocator, nil)
					outcome = task_resume_with(entry.task, empty)
					continue
				}
			}
			break
		}

		sync.mutex_lock(&scheduler.lock)
		entry.running = false
		if entry.cancelled && outcome.kind == .Pending {
			outcome = task_cancel(entry.task)
		}
		scheduler_finish_locked(scheduler, id, entry, outcome)
		sync.cond_broadcast(&scheduler.cond)
		sync.mutex_unlock(&scheduler.lock)
	}
}

@(private)
scheduler_timer_proc :: proc(data: rawptr) {
	scheduler := (^Scheduler)(data)
	for {
		sync.mutex_lock(&scheduler.lock)
		if scheduler.stop {
			sync.mutex_unlock(&scheduler.lock)
			return
		}

		now := time.tick_now()
		if len(scheduler.timers) == 0 {
			sync.cond_wait(&scheduler.cond, &scheduler.lock)
			sync.mutex_unlock(&scheduler.lock)
			continue
		}

		next := scheduler.timers[0]
		if time.tick_diff(now, next.deadline) > 0 {
			sync.cond_wait_with_timeout(
				&scheduler.cond,
				&scheduler.lock,
				time.tick_diff(now, next.deadline),
			)
			sync.mutex_unlock(&scheduler.lock)
			continue
		}

		pop(&scheduler.timers)
		entry, found := scheduler.entries[next.task_id]
		if found && !entry.done && entry.generation == next.generation {
			if entry.result.suspend == .Mailbox_Recv {
				scheduler_remove_mailbox_waiter_locked(scheduler, next.task_id)
				entry.pending_value = v.value_list(scheduler.allocator, nil)
				entry.has_pending = true
			}
			append(&scheduler.ready, next.task_id)
		}
		sync.cond_broadcast(&scheduler.cond)
		sync.mutex_unlock(&scheduler.lock)
	}
}
