// Property test: generated positive rule programs over a random edge set must
// agree with a naive reference fixpoint evaluator.
package kernel

import "core:testing"
import v "../var"

@(private)
Property_Rng :: struct {
	state: u64,
}

@(private)
property_next :: proc(rng: ^Property_Rng) -> u64 {
	x := rng.state
	x ~= x >> 12
	x ~= x << 25
	x ~= x >> 27
	rng.state = x
	return x * 0x2545f4914f6cdd1d
}

@(private)
Property_Rule_Kind :: enum {
	// Path(x, y) :- Edge(x, y)
	Base,
	// Path(x, z) :- Edge(x, y), Path(y, z)
	Edge_Prefix,
	// Path(x, z) :- Path(x, y), Edge(y, z)
	Edge_Suffix,
	// Path(x, z) :- Path(x, y), Path(y, z)
	Path_Path,
}

@(test)
test_property_rule_programs :: proc(t: ^testing.T) {
	DOMAIN :: 4
	rng := Property_Rng{state = 0x243f6a8885a308d3}

	for sample in 0 ..< 24 {
		kernel: Kernel
		kernel_init(&kernel)
		defer kernel_destroy(&kernel)

		edge := create_relation(&kernel, 1, "Edge", 2)
		path := create_relation(&kernel, 2, "Path", 2)

		selected: [len(Property_Rule_Kind)]bool
		any_rule := false
		for kind in 0 ..< len(Property_Rule_Kind) {
			if property_next(&rng) % 2 == 0 {
				selected[kind] = true
				any_rule = true
			}
		}
		if !any_rule {
			selected[int(Property_Rule_Kind.Base)] = true
		}

		x := v.symbol_intern("x")
		y := v.symbol_intern("y")
		z := v.symbol_intern("z")
		for kind in 0 ..< len(Property_Rule_Kind) {
			if !selected[kind] {
				continue
			}
			rule: Rule
			switch Property_Rule_Kind(kind) {
			case .Base:
				rule = rule_new(
					path,
					[]Term{term_var(x), term_var(y)},
					[]Rule_Body_Item {
						body_atom(atom_positive(edge, []Term{term_var(x), term_var(y)})),
					},
				)
			case .Edge_Prefix:
				rule = rule_new(
					path,
					[]Term{term_var(x), term_var(z)},
					[]Rule_Body_Item {
						body_atom(atom_positive(edge, []Term{term_var(x), term_var(y)})),
						body_atom(atom_positive(path, []Term{term_var(y), term_var(z)})),
					},
				)
			case .Edge_Suffix:
				rule = rule_new(
					path,
					[]Term{term_var(x), term_var(z)},
					[]Rule_Body_Item {
						body_atom(atom_positive(path, []Term{term_var(x), term_var(y)})),
						body_atom(atom_positive(edge, []Term{term_var(y), term_var(z)})),
					},
				)
			case .Path_Path:
				rule = rule_new(
					path,
					[]Term{term_var(x), term_var(z)},
					[]Rule_Body_Item {
						body_atom(atom_positive(path, []Term{term_var(x), term_var(y)})),
						body_atom(atom_positive(path, []Term{term_var(y), term_var(z)})),
					},
				)
			}
			installed, err := kernel_install_rule(
				&kernel,
				v.Identity(100 + u64(kind)),
				rule,
				"property",
			)
			if err != Kernel_Error.None {
				testing.expectf(t, false, "sample %d kind %v: rule install failed: %v", sample, Property_Rule_Kind(kind), err)
				return
			}
			snapshot_release(installed)
		}

		edges: [DOMAIN][DOMAIN]bool
		reference: [DOMAIN][DOMAIN]bool
		tx := kernel_begin(&kernel)
		for a in 0 ..< DOMAIN {
			for b in 0 ..< DOMAIN {
				if property_next(&rng) % 3 == 0 {
					edges[a][b] = true
					if selected[int(Property_Rule_Kind.Base)] {
						reference[a][b] = true
					}
					if err := transaction_assert(
						&tx,
						edge,
						tuple_of(must_int(i64(a) + 1), must_int(i64(b) + 1)),
					); err != Kernel_Error.None {
						testing.expectf(t, false, "sample %d: assert failed: %v", sample, err)
						transaction_destroy(&tx)
						return
					}
				}
			}
		}
		commit_transaction(t, &tx)

		for changed := true; changed; {
			changed = false
			for kind in 0 ..< len(Property_Rule_Kind) {
				if !selected[kind] {
					continue
				}
				switch Property_Rule_Kind(kind) {
				case .Base:
					for a in 0 ..< DOMAIN {
						for b in 0 ..< DOMAIN {
							if edges[a][b] && !reference[a][b] {
								reference[a][b] = true
								changed = true
							}
						}
					}
				case .Edge_Prefix:
					for a in 0 ..< DOMAIN {
						for b in 0 ..< DOMAIN {
							for c in 0 ..< DOMAIN {
								if edges[a][b] && reference[b][c] && !reference[a][c] {
									reference[a][c] = true
									changed = true
								}
							}
						}
					}
				case .Edge_Suffix:
					for a in 0 ..< DOMAIN {
						for b in 0 ..< DOMAIN {
							for c in 0 ..< DOMAIN {
								if reference[a][b] && edges[b][c] && !reference[a][c] {
									reference[a][c] = true
									changed = true
								}
							}
						}
					}
				case .Path_Path:
					for a in 0 ..< DOMAIN {
						for b in 0 ..< DOMAIN {
							for c in 0 ..< DOMAIN {
								if reference[a][b] && reference[b][c] && !reference[a][c] {
									reference[a][c] = true
									changed = true
								}
							}
						}
					}
				}
			}
		}

		observed: [DOMAIN][DOMAIN]bool
		rows := kernel_rows(&kernel, path, 2)
		defer delete(rows)
		for row in rows {
			values := v.tuple_values(row)
			a, a_ok := v.value_as_int(values[0])
			b, b_ok := v.value_as_int(values[1])
			if !a_ok || !b_ok || a < 1 || b < 1 || a > DOMAIN || b > DOMAIN {
				testing.expectf(t, false, "sample %d: unexpected row", sample)
				return
			}
			observed[a - 1][b - 1] = true
		}
		testing.expectf(t, observed == reference, "sample %d: derived rows disagree with reference", sample)
	}
}
