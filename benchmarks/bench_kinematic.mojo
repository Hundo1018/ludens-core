"""ROADMAP 17.24: cost of the kinematic path.

Same scene, N=16..1024 dynamic boxes resting on one wide platform, run once
with the platform STATIC and once KINEMATIC (velocity held constant). Both
scenes generate exactly the same NUMBER of dynamic-vs-platform contacts and
run the exact same per-pair `combine()` dispatch (ROADMAP 17.23 -- that
runs for every pair, static or kinematic alike, so it is not what this
table isolates). What differs is `moves(i)`: a kinematic platform's
`velocity_at` is read every contact point/substep (it carries into the
relative-velocity term that pushes the boxes along); a static one never
reads it at all (`_solve_pair`'s `if self.bset.moves(pr.a): ...` is skipped
outright). This table prices exactly that one extra read, at solver-scale
box counts.
"""

from std.time import perf_counter_ns
from harness.bench import BenchTable
from geometry.vec import Real, Vec3
from physics.rigid6 import Inertia3, QuatBody6
from physics.solver6 import ContactScene6

comptime DT: Real = 1.0 / 60.0
comptime G = Vec3(0, -9.8, 0, 0)
comptime STEPS = 120


def _scene(n: Int, kinematic: Bool) raises -> ContactScene6[QuatBody6]:
    var sc = ContactScene6[QuatBody6]()
    var half_w = Real(n) * 0.3 + 2
    var plat = sc.add(
        QuatBody6.at_rest(Vec3(0, -0.5, 0, 0), Inertia3.box(1, half_w, 0.5, 2)),
        Vec3(half_w, 0.5, 2, 0),
        not kinematic,
    )
    if kinematic:
        sc.set_kinematic(plat)
        sc.set_velocity(plat, Vec3(0.3, 0, 0, 0), Vec3(0, 0, 0, 0))
    var bi = Inertia3.box(1, 0.2, 0.2, 0.2)
    for i in range(n):
        var x = Real(i) * 0.5 - Real(n) * 0.25
        var b = sc.add(
            QuatBody6.at_rest(Vec3(x, 0.2, 0, 0), bi), Vec3(0.2, 0.2, 0.2, 0), False,
        )
        # Pinned awake in BOTH scenes: a resting box on a STATIC platform
        # falls asleep within ~35 frames (`test_sleep6`'s own number) and
        # then every one of its pairs is skipped outright (`BodySet.impulse_inert`)
        # -- that sleep-state asymmetry would swamp the one-branch delta
        # this bench exists to isolate, since "skip the pair entirely" costs
        # far less than either solve path. `set_can_sleep(False)` removes
        # that confound so both columns pay the FULL per-contact solve cost
        # every step, and the remaining delta is just `moves(i)`'s extra
        # `velocity_at` read on the kinematic side.
        sc.set_can_sleep(b, False)
    return sc^


def _run(mut sc: ContactScene6[QuatBody6]) raises -> Int:
    var t0 = Int(perf_counter_ns())
    for _ in range(STEPS):
        sc.step_soft(DT, G)
    return Int(perf_counter_ns()) - t0


def main() raises:
    var t = BenchTable("Kinematic path cost: N boxes on a static vs kinematic platform")
    var ns = List[Int]()
    ns.append(16)
    ns.append(64)
    ns.append(256)
    ns.append(1024)
    for i in range(len(ns)):
        var n = ns[i]
        var s = _scene(n, False)
        t.add("static platform", n, "step", _run(s), STEPS)
        var k = _scene(n, True)
        t.add("kinematic platform", n, "step", _run(k), STEPS)
    t.print_report()
