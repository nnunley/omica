// The AVX2+FMA dot kernel; see cpu_dot_kernel.odin. Compiled with those
// features enabled for this procedure only and called only after
// cpu_dot_kernel_supported(.Avx2_Fma), so the rest of the program keeps the
// build's baseline target.
//
// Nothing here may call a non-inlined procedure that takes or returns a
// #simd value (simd.from_slice, for one): its baseline-target ABI passes an
// 8-lane vector as two SSE registers while this procedure expects one YMM
// register, which silently dropped half the lanes. Loads use the
// unaligned_load intrinsic, which is inlined. The same goes for the
// runtime's bounds checks, which are not AVX-compiled: left on, each check was
// a real call that spilled the accumulators and ran vzeroupper, making this
// kernel 2.6x slower than the portable one; the loop runs #no_bounds_check.
#+build amd64
package accel

import "base:intrinsics"
import "core:simd"

@(private, enable_target_feature = "avx2,fma")
cpu_dot_norms_avx2_fma :: proc(a, b: []f32) -> (dot, norm_a, norm_b: f32) {
	n := min(len(a), len(b))
	vd, va, vb: F32_Lanes
	i := 0
	// i + COSINE_LANES <= n <= len(a), len(b): every load is in range.
	#no_bounds_check for ; i + COSINE_LANES <= n; i += COSINE_LANES {
		x := intrinsics.unaligned_load((^F32_Lanes)(&a[i]))
		y := intrinsics.unaligned_load((^F32_Lanes)(&b[i]))
		vd = simd.fma(x, y, vd)
		va = simd.fma(x, x, va)
		vb = simd.fma(y, y, vb)
	}
	dot = simd.reduce_add_bisect(vd)
	norm_a = simd.reduce_add_bisect(va)
	norm_b = simd.reduce_add_bisect(vb)
	#no_bounds_check for ; i < n; i += 1 {
		dot += a[i] * b[i]
		norm_a += a[i] * a[i]
		norm_b += b[i] * b[i]
	}
	return
}
