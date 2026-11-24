"""Numeric policy cost probe (ROADMAP 17.105).

How much speed do the optimizations that break cross-target bit identity buy,
and how much error do they add? `scripts/numeric_cost_probe.py` compiles this
file once per CPU target / feature set (with and without FMA) and runs it.

Workloads, each timed as the minimum of `REPS` runs:

- `pile`: 400 boxes dropped onto a floor, 120 soft-contact steps with the
  broadphase. This is the contact solver at game scale. The state hash and the
  bodies' positions are printed, so the driver can measure drift between builds.
- `motor`: 2 000 000 compositions of a PGA motor plus point applications. This
  is the geometric-algebra product path, where FMA contraction matters most.
- `norm_exact` / `norm_rsqrt`: 4 000 000 Vec3 normalizations. The first uses
  1 / sqrt (what the engine does). The second uses the x86 `rsqrtps`
  approximation plus one Newton step, which is the classic game-engine
  "fast normalize". It prints its largest relative error against the exact
  version.

Output lines: `TIME <name> <ns>`, `HASH <name> <u64>`, `POS <floats>`,
`ERR norm_rsqrt <max relative error>`.
"""

from std.benchmark import keep
from std.math import sqrt
from std.sys import llvm_intrinsic
from harness.bench import now
from geometry.vec import Real, Vec3
from geometry.motor import Motor3
from geometry.quat import Quat
from physics.rigid6 import QuatBody6, Inertia3
from physics.solver6 import ContactScene6

comptime REPS = 5
comptime N_NORM = 4_000_000
comptime N_MOTOR = 2_000_000


def _bits(v: Float32) -> UInt32:
    var x = v
    return Pointer(to=x).unsafe_bitcast[UInt32]()[]


def _pile() -> ContactScene6[QuatBody6]:
    var sc = ContactScene6[QuatBody6]()
    _ = sc.add(QuatBody6.at_rest(Vec3(0, -0.5, 0, 0), Inertia3.box(1, 40, 0.5, 40)), Vec3(40, 0.5, 40, 0), True)
    for k in range(400):
        var x = Real(k % 20) * 0.6 - 6.0
        var z = Real((k // 20) % 20) * 0.6 - 6.0
        var y = 0.3 + Real(k // 400) * 0.55 + Real(k % 7) * 0.01
        _ = sc.add(QuatBody6.at_rest(Vec3(x, y, z, 0), Inertia3.box(1, 0.25, 0.25, 0.25)), Vec3(0.25, 0.25, 0.25, 0), False)
    return sc^


def time_pile():
    var best = Int.MAX
    var g = Vec3(0, -9.8, 0, 0)
    var last = _pile()
    for _ in range(REPS):
        var sc = _pile()
        var t0 = now()
        for _ in range(120):
            sc.step_soft(1.0 / 60.0, g, broadphase=True)
        best = min(best, now() - t0)
        last = sc^
    print("TIME pile", best)
    var h = UInt64(0xCBF29CE484222325)
    var line = String("POS")
    for i in range(len(last.bset.bodies)):
        var b = last.bset.bodies[i]
        for v in [Float32(b.pos[0]), Float32(b.pos[1]), Float32(b.pos[2])]:
            h ^= UInt64(_bits(v))
            h *= UInt64(0x100000001B3)
            line += " " + String(v)
    print("HASH pile", h)
    print(line)


def time_motor():
    var best = Int.MAX
    var acc = Vec3(0, 0, 0, 0)
    for _ in range(REPS):
        var m = Motor3.identity()
        var step = Motor3.from_quat_translation(Quat.from_axis_angle(Vec3(0.3, 0.8, 0.5, 0), 0.001), Vec3(0.001, 0, 0, 0)).normalized()
        var p = Vec3(1, 2, 3, 0)
        var t0 = now()
        for i in range(N_MOTOR):
            m = (m * step)
            if i % 1024 == 0:
                m = m.normalized()
            p = m.apply_point(Vec3(1, 2, 3, 0))
        best = min(best, now() - t0)
        acc = p
    keep(acc[0])
    print("TIME motor", best)
    print("HASH motor", UInt64(_bits(Float32(acc[0]))) * 4294967296 + UInt64(_bits(Float32(acc[1]))))


def _input(i: Int) -> SIMD[DType.float32, 4]:
    var f = Float32(i % 9973) * 0.001 + 0.01
    return SIMD[DType.float32, 4](f, 1.0 - f * 0.5, f * f + 0.2, 0.0)


@always_inline
def _norm_exact(v: SIMD[DType.float32, 4]) -> SIMD[DType.float32, 4]:
    var l2 = (v * v).reduce_add()
    return v * (1.0 / sqrt(l2))


@always_inline
def _norm_rsqrt(v: SIMD[DType.float32, 4]) -> SIMD[DType.float32, 4]:
    var l2 = (v * v).reduce_add()
    var x = SIMD[DType.float32, 4](l2)
    var r = llvm_intrinsic["llvm.x86.sse.rsqrt.ps", SIMD[DType.float32, 4]](x)
    r = r * (1.5 - 0.5 * x * r * r)  # one Newton step
    return v * r[0]


def time_norm():
    var be = Int.MAX
    var br = Int.MAX
    var se = SIMD[DType.float32, 4](0)
    var sr = SIMD[DType.float32, 4](0)
    for _ in range(REPS):
        var a = SIMD[DType.float32, 4](0)
        var t0 = now()
        for i in range(N_NORM):
            a += _norm_exact(_input(i))
        be = min(be, now() - t0)
        se = a
        var b = SIMD[DType.float32, 4](0)
        t0 = now()
        for i in range(N_NORM):
            b += _norm_rsqrt(_input(i))
        br = min(br, now() - t0)
        sr = b
    keep(se[0])
    keep(sr[0])
    var worst = Float64(0)
    for i in range(0, N_NORM, 97):
        var e = _norm_exact(_input(i))
        var r = _norm_rsqrt(_input(i))
        for k in range(3):
            if e[k] != 0:
                worst = max(worst, abs(Float64(r[k]) - Float64(e[k])) / abs(Float64(e[k])))
    print("TIME norm_exact", be)
    print("TIME norm_rsqrt", br)
    print("ERR norm_rsqrt", worst)


def main():
    time_pile()
    time_motor()
    time_norm()
