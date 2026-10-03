package accel

import "core:log"
import "core:math"
import "core:testing"

// Each dot kernel this CPU can run matches an f64 reference for the dot
// product and both squared norms, over dims covering every tail length of the
// widest kernel.
@(test)
test_cpu_dot_kernels_match_f64_oracle :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	for kernel in Cpu_Dot_Kernel {
		if !cpu_dot_kernel_supported(kernel) {
			log.infof("dot kernel %v unsupported on this CPU; skipped", kernel)
			continue
		}
		for dim in ([]int{1, 3, 7, 8, 9, 15, 16, 17, 31, 32, 33, 67, 768, 1000}) {
			a := make([]f32, dim, context.temp_allocator)
			b := make([]f32, dim, context.temp_allocator)
			for i in 0 ..< dim {
				a[i] = f32((i * 37 + dim) % 23) / 11.0 - 1.0
				b[i] = f32((i * 53 + dim) % 29) / 14.0 - 1.0
			}
			want_dot, want_a, want_b: f64
			for i in 0 ..< dim {
				want_dot += f64(a[i]) * f64(b[i])
				want_a += f64(a[i]) * f64(a[i])
				want_b += f64(b[i]) * f64(b[i])
			}
			dot, norm_a, norm_b := cpu_dot_norms_with(kernel, a, b)
			// f32 accumulation error grows with dim and magnitude.
			tolerance := 1e-5 * (want_a + want_b + 1) * math.sqrt(f64(dim))
			testing.expectf(t, abs(f64(dot) - want_dot) < tolerance, "%v dim %d: dot %v want %v", kernel, dim, dot, want_dot)
			testing.expectf(t, abs(f64(norm_a) - want_a) < tolerance, "%v dim %d: |a|^2 %v want %v", kernel, dim, norm_a, want_a)
			testing.expectf(t, abs(f64(norm_b) - want_b) < tolerance, "%v dim %d: |b|^2 %v want %v", kernel, dim, norm_b, want_b)
		}
	}
}

@(test)
test_cpu_dot_kernel_selection :: proc(t: ^testing.T) {
	testing.expect(t, cpu_dot_kernel_supported(.Portable), "the portable kernel runs everywhere")
	want := cpu_dot_kernel_supported(.Avx2_Fma) ? Cpu_Dot_Kernel.Avx2_Fma : Cpu_Dot_Kernel.Portable
	testing.expect_value(t, cpu_dot_kernel(), want)
	log.infof("selected CPU dot kernel: %v", cpu_dot_kernel())
}
