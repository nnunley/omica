// CPU dot-product kernels for cosine: the per-pair dot product and squared
// norms, in variants chosen once per process by what the CPU supports.
//
// The portable kernel is the reference: 8 f32 lanes of multiply-then-add,
// which LLVM lowers to whatever the build target has (two SSE registers on
// baseline x86-64, two NEON registers on arm64). It must not use simd.fma: on
// a target without FMA, LLVM keeps fma's exact rounding by calling libm fmaf
// per lane (measured 33x slower than multiply-then-add).
//
// On amd64 an AVX2+FMA variant is compiled alongside with
// @(enable_target_feature) and selected at startup when the CPU and OS
// support it, so a portable build still gets 8-wide AVX2 where available.
// Building the whole program for a newer target (-microarch:x86-64-v3) is a
// separate, deployment-level choice this does not make.
package accel

import "base:intrinsics"
import "core:simd"
import "core:sys/info"

Cpu_Dot_Kernel :: enum u8 {
	Portable,
	Avx2_Fma,
}

@(private)
COSINE_LANES :: 8

@(private)
F32_Lanes :: #simd[COSINE_LANES]f32

@(private)
cpu_selected_dot: Cpu_Dot_Kernel

// Chosen before any thread runs, so reads never race.
@(init, private)
cpu_select_dot_kernel :: proc "contextless" () {
	cpu_selected_dot = cpu_dot_kernel_supported(.Avx2_Fma) ? .Avx2_Fma : .Portable
}

// The kernel CPU cosine uses in this process.
cpu_dot_kernel :: proc() -> Cpu_Dot_Kernel {
	return cpu_selected_dot
}

// Whether this CPU (and OS) can run `kernel`.
cpu_dot_kernel_supported :: proc "contextless" (kernel: Cpu_Dot_Kernel) -> bool {
	switch kernel {
	case .Portable:
		return true
	case .Avx2_Fma:
		when ODIN_ARCH == .amd64 {
			features := info.cpu_features()
			return .avx2 in features && .fma in features
		} else {
			return false
		}
	}
	return false
}

// Dot product and both squared norms of a and b through the selected kernel.
@(private)
cpu_dot_norms :: proc(a, b: []f32) -> (dot, norm_a, norm_b: f32) {
	return cpu_dot_norms_with(cpu_selected_dot, a, b)
}

// Dot product and both squared norms through a given kernel; the caller must
// have checked `cpu_dot_kernel_supported`.
cpu_dot_norms_with :: proc(kernel: Cpu_Dot_Kernel, a, b: []f32) -> (dot, norm_a, norm_b: f32) {
	when ODIN_ARCH == .amd64 {
		if kernel == .Avx2_Fma {
			return cpu_dot_norms_avx2_fma(a, b)
		}
	}
	return cpu_dot_norms_portable(a, b)
}

// Summation order differs from a sequential loop, within f32 rounding.
@(private)
cpu_dot_norms_portable :: proc(a, b: []f32) -> (dot, norm_a, norm_b: f32) {
	n := min(len(a), len(b))
	vd, va, vb: F32_Lanes
	i := 0
	// i + COSINE_LANES <= n <= len(a), len(b): every load is in range.
	#no_bounds_check for ; i + COSINE_LANES <= n; i += COSINE_LANES {
		x := intrinsics.unaligned_load((^F32_Lanes)(&a[i]))
		y := intrinsics.unaligned_load((^F32_Lanes)(&b[i]))
		vd += x * y
		va += x * x
		vb += y * y
	}
	dot = simd.reduce_add_bisect(vd)
	norm_a = simd.reduce_add_bisect(va)
	norm_b = simd.reduce_add_bisect(vb)
	for ; i < n; i += 1 {
		dot += a[i] * b[i]
		norm_a += a[i] * a[i]
		norm_b += b[i] * b[i]
	}
	return
}
