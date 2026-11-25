"""Fast inverse square root cost probe (ROADMAP 17.105).

`numeric_cost.mojo` timed scalar normalizations whose loop was dominated by
generating the input (an integer modulo, a conversion, a horizontal sum). The
1 / sqrt vs rsqrt difference was a small part of each iteration, so that number
said little. This probe isolates the operation.

Setup: three SoA arrays (x, y, z) of 4096 floats, which fit in L1. Each pass
normalizes them in place, W lanes at a time, with no dependency between
iterations. `W` comes from `-D W=4` (SSE) or `-D W=8` (AVX), and
`scripts/numeric_cost_probe.py --rsqrt` sets it per target. Variants:

- `exact`: v * (1 / sqrt(l2)), which compiles to sqrtps + divps. This is what
  the engine does.
- `rsqrt_newton`: rsqrtps plus one Newton step, the classic fast normalize.
- `rsqrt_raw`: rsqrtps alone (about 12 bits).

Output: `TIME <variant> <ns per vector>` and `ERR <variant> <max relative error>`.
"""

from std.benchmark import keep
from std.math import sqrt
from std.sys import llvm_intrinsic, get_defined_int
from harness.bench import now

comptime W = get_defined_int["W", 4]()
comptime N = 4096
comptime PASSES = 2000
comptime REPS = 5
comptime V = SIMD[DType.float32, W]


@always_inline
def _rsqrt(x: V) -> V:
    comptime if W == 8:
        return llvm_intrinsic["llvm.x86.avx.rsqrt.ps.256", V](x)
    else:
        return llvm_intrinsic["llvm.x86.sse.rsqrt.ps", V](x)


@always_inline
def _inv(l2: V, mode: Int) -> V:
    if mode == 0:
        return 1.0 / sqrt(l2)
    var r = _rsqrt(l2)
    if mode == 1:
        r = r * (1.5 - 0.5 * l2 * r * r)
    return r


def _fill(mut x: List[Float32], mut y: List[Float32], mut z: List[Float32]):
    for i in range(N):
        var f = Float32(i % 977) * 0.01 + 0.05
        x[i] = f
        y[i] = 1.0 - f * 0.3
        z[i] = f * f * 0.1 + 0.2


def run(mode: Int, name: String):
    var x = List[Float32](length=N, fill=0)
    var y = List[Float32](length=N, fill=0)
    var z = List[Float32](length=N, fill=0)
    var best = Int.MAX
    for _ in range(REPS):
        var t = 0
        for _ in range(PASSES):
            _fill(x, y, z)  # restore the inputs; not timed
            var px = x.unsafe_ptr()
            var py = y.unsafe_ptr()
            var pz = z.unsafe_ptr()
            var t0 = now()
            for i in range(0, N, W):
                var a = px.load[width=W](i)
                var b = py.load[width=W](i)
                var c = pz.load[width=W](i)
                var s = _inv(a * a + b * b + c * c, mode)
                px.store(i, a * s)
                py.store(i, b * s)
                pz.store(i, c * s)
            t += now() - t0
        best = min(best, t)
    keep(x[17])
    print("TIME", name, Float64(best) / Float64(PASSES * N))
    # error against 1/sqrt computed in f64
    _fill(x, y, z)
    var worst = Float64(0)
    var px = x.unsafe_ptr()
    var py = y.unsafe_ptr()
    var pz = z.unsafe_ptr()
    for i in range(0, N, W):
        var a = px.load[width=W](i)
        var b = py.load[width=W](i)
        var c = pz.load[width=W](i)
        var l2 = a * a + b * b + c * c
        var s = _inv(l2, mode)
        for k in range(W):
            var want = 1.0 / sqrt(Float64(l2[k]))
            worst = max(worst, abs(Float64(s[k]) - want) / want)
    print("ERR", name, worst)


def main():
    print("W", W)
    run(0, "exact")
    run(1, "rsqrt_newton")
    run(2, "rsqrt_raw")
