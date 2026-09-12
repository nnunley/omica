// Persistence hooks.
//
// The durable store lives outside the kernel (`mica/store`); the kernel calls
// these hooks at admission and publication time. Keeping the interface here
// avoids a kernel-to-store import cycle.
package kernel

import v "../var"

// Identifies one reserved share of the store's durable budget.
Persist_Ticket :: u64

Store_Hooks :: struct {
	user: rawptr,
	// Reserves `bytes` of durable capacity. Returns false on timeout or when
	// the store is closed; the caller must not publish.
	admit: proc(user: rawptr, bytes: i64) -> (Persist_Ticket, bool),
	// Returns an unused reservation.
	release: proc(user: rawptr, ticket: Persist_Ticket),
	// Hands a published version's writes to the store. The store copies what
	// it needs before returning; it must not retain the slices.
	publish: proc(
		user: rawptr,
		ticket: Persist_Ticket,
		version: u64,
		snapshot: ^Snapshot,
		writes: []Relation_Writes,
	),
	// Blocks until `version` is durable.
	wait_durable:    proc(user: rawptr, version: u64),
	durable_version: proc(user: rawptr) -> u64,
}

kernel_attach_store :: proc(kernel: ^Kernel, hooks: Store_Hooks) {
	kernel.store = hooks
}

kernel_detach_store :: proc(kernel: ^Kernel) {
	kernel.store = {}
}

kernel_store_attached :: proc(kernel: ^Kernel) -> bool {
	return kernel.store.publish != nil
}

kernel_admit_persist :: proc(kernel: ^Kernel, bytes: i64) -> (Persist_Ticket, bool) {
	if kernel.store.admit == nil || bytes <= 0 {
		return 0, true
	}
	return kernel.store.admit(kernel.store.user, bytes)
}

kernel_release_persist :: proc(kernel: ^Kernel, ticket: Persist_Ticket) {
	if kernel.store.release == nil || ticket == 0 {
		return
	}
	kernel.store.release(kernel.store.user, ticket)
}

kernel_store_persist :: proc(
	kernel: ^Kernel,
	ticket: Persist_Ticket,
	version: u64,
	snapshot: ^Snapshot,
	writes: []Relation_Writes,
) {
	if kernel.store.publish == nil {
		return
	}
	kernel.store.publish(kernel.store.user, ticket, version, snapshot, writes)
}

kernel_wait_durable :: proc(kernel: ^Kernel, version: u64) {
	if kernel.store.wait_durable == nil {
		return
	}
	kernel.store.wait_durable(kernel.store.user, version)
}

kernel_durable_version :: proc(kernel: ^Kernel) -> u64 {
	if kernel.store.durable_version == nil {
		return 0
	}
	return kernel.store.durable_version(kernel.store.user)
}

// Estimates the durable bytes one transaction will produce. Volatile relations
// are excluded. The estimate is intentionally coarse; the store only needs a
// deterministic, monotonic sizing for its budget.
kernel_persist_bytes :: proc(transaction: ^Transaction) -> i64 {
	total := i64(0)
	for relation_writes in transaction.writes {
		metadata, found := snapshot_relation_metadata(
			transaction.base,
			relation_writes.relation,
		)
		if !found || metadata.durability == .Volatile {
			continue
		}
		for entry in relation_writes.entries {
			total += 64 + i64(v.tuple_arity(entry.tuple)) * 24
		}
	}
	return total
}
