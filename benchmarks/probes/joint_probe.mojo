"""Fixed jointed workload for a function-level instruction profile (ROADMAP 17.98, phase-3 upper bounds).

12 chains of 6 boxes, joined alternately by ball, hinge and distance joints, hang from static anchors and
swing into each other and a floor for 60 steps of `step_soft`. `scripts/fn_share.py` runs it under
callgrind; the self cost of `joint_sweep` (outside `joint_axis` and the per-kind rows) bounds what
bucketing joints by kind could save.
"""
from std.benchmark import keep
from geometry.vec import Real, Vec3
from physics.rigid6 import QuatBody6, Inertia3
from physics.solver6 import ContactScene6
from physics.joints6 import Joint6


def main() raises:
    var sc = ContactScene6[QuatBody6]()
    _ = sc.add(QuatBody6.at_rest(Vec3(0, -0.5, 0, 0), Inertia3.box(1, 20, 0.5, 20)), Vec3(20, 0.5, 20, 0), True)
    var hl = Vec3(0, 0.15, 0, 0)
    for c in range(12):
        var x = Real(c % 4) * 0.5 - 0.75
        var z = Real(c // 4) * 0.5 - 0.5
        var top = sc.add(QuatBody6.at_rest(Vec3(x, 2.2, z, 0), Inertia3.box(1, 0.1, 0.1, 0.1)), Vec3(0.1, 0.1, 0.1, 0), True)
        var prev = top.index()
        for k in range(6):
            var b = sc.add(
                QuatBody6.at_rest(Vec3(x + Real(k) * 0.12, 1.9 - Real(k) * 0.3, z, 0), Inertia3.box(1, 0.08, 0.15, 0.08)),
                Vec3(0.08, 0.15, 0.08, 0), False,
            )
            var kind = k % 3
            if kind == 0:
                _ = sc.add_joint(Joint6.ball(prev, b.index(), -hl, hl))
            elif kind == 1:
                _ = sc.add_joint(Joint6.hinge(prev, b.index(), -hl, hl, Vec3(0, 0, 1, 0)))
            else:
                _ = sc.add_joint(Joint6.distance(prev, b.index(), -hl, hl, 0.02))
            prev = b.index()
    for _ in range(60):
        sc.step_soft(1.0 / 60.0, Vec3(0, -9.8, 0, 0))
    keep(sc.bset.bodies[5].pos[1])
