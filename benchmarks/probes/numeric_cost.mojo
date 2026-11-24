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

Normalization (exact 1 / sqrt vs `rsqrtps`) is measured separately in
`rsqrt_cost.mojo`. An earlier scalar version of it lived here, but its loop was
dominated by generating the input, so its numbers did not measure the operation.

Output lines: `TIME <name> <ns>`, `HASH <name> <u64>`, `POS <floats>`.
"""

from std.benchmark import keep
from harness.bench import now
from geometry.vec import Real, Vec3
from geometry.motor import Motor3
from geometry.quat import Quat
from physics.rigid6 import QuatBody6, Inertia3
from physics.solver6 import ContactScene6

comptime REPS = 5
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


def main():
    time_pile()
    time_motor()
