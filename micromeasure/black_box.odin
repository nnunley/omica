// Anti-optimization helper.
package micromeasure

import "base:intrinsics"

// black_box pushes a value through a volatile cell. The optimizer cannot fold
// away the work that produced the value. Apply it to inputs and to the final
// accumulated result.
black_box :: proc(value: $T) -> T {
	local := value
	intrinsics.volatile_store(&local, value)
	return intrinsics.volatile_load(&local)
}
