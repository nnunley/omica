// Times building a 16k-row block and the first indexed scan (which
// materializes the lazy secondary index).
//
//   odin build tools/indexprobe -o:speed -out:/tmp/indexprobe
//   /tmp/indexprobe [index_position]
package main

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:time"

import k "../../mica/kernel"
import v "../../mica/var"

ARITY :: 3

main :: proc() {
	position := u16(1)
	if len(os.args) > 1 {
		parsed, parsed_ok := strconv.parse_int(os.args[1])
		if !parsed_ok || parsed < 0 || parsed >= ARITY {
			fmt.eprintf("indexprobe: position must be 0..<%d\n", ARITY)
			os.exit(2)
		}
		position = u16(parsed)
	}

	kernel: k.Kernel
	k.kernel_init(&kernel)
	defer k.kernel_destroy(&kernel)

	index_positions := make([]u16, 1, context.allocator)
	index_positions[0] = position
	index_specs := make([]k.Index_Spec, 1, context.allocator)
	index_specs[0] = k.index_spec(index_positions)
	metadata := k.relation_metadata(k.Relation_ID(1), v.symbol_intern("Store"), 3)
	metadata.indexes = index_specs

	// Disjoint id spaces: group and item columns must not share values, or a
	// probe on one column could match on the other by accident.
	ITEMS_OFFSET :: 0x1000

	ROWS :: 16384
	rows := make([]v.Tuple, ROWS, context.allocator)
	for group in 0 ..< 128 {
		for item in 0 ..< 128 {
			group_id, _ := v.identity_new(u64(group))
			item_id, _ := v.identity_new(ITEMS_OFFSET + u64(item))
			rows[group * 128 + item] = v.tuple_new(
				context.allocator,
				[]v.Value {
					v.value_identity(group_id),
					v.value_identity(item_id),
					v.value_symbol(v.symbol_intern("bench_kind")),
				},
			)
		}
	}

	item_id, _ := v.identity_new(ITEMS_OFFSET + 7)
	group_id, _ := v.identity_new(42)
	bindings := make([]v.Binding, 3, context.allocator)
	bindings[position] = v.binding_of(v.value_identity(position == 0 ? group_id : item_id))

	ROUNDS :: 30
	build_best := i64(1 << 62)
	visit_best := i64(1 << 62)
	visited := 0
	for _ in 0 ..< ROUNDS {
		build_start := time.tick_now()
		block := k.relation_block_build_pooled(&kernel, metadata, rows)
		build_best = min(build_best, i64(time.tick_since(build_start)))

		visit_start := time.tick_now()
		k.relation_block_visit(
			block,
			bindings,
			proc(user: rawptr, row: v.Tuple) -> bool {
				(^int)(user)^ += 1
				return true
			},
			&visited,
		)
		visit_best = min(visit_best, i64(time.tick_since(visit_start)))
		k.relation_block_release(block)
	}

	fmt.printf(
		"position=%d build=%.3fms first_visit=%.3fms visited=%d\n",
		position,
		f64(build_best)/1e6,
		f64(visit_best)/1e6,
		visited / ROUNDS,
	)
}
