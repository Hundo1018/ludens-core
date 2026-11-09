# tier: integration
"""Fifth-wheel coupling (ROADMAP 17.74, #98): `fifth_wheel` against the ball `hitch`.

A static tractor box and a dynamic 12 t trailer box coupled at the trailer's front end, nothing under the trailer:
  1. Ball hitch: gravity swings the trailer down about the coupling (relative pitch far beyond 0.15 rad).
  2. Fifth wheel, limits +-0.15 pitch / +-0.10 roll: after 5 s the relative pitch is within 0.15 rad + 0.02 and the
     roll within 0.10 + 0.02; the trailer front stays within 2 cm of the coupling point.
  3. Yaw is free: the same initial angular velocity (0.8 rad/s about the vertical axis) gives the same relative yaw
     after 1 s as the ball hitch, within 15 %.
  4. A bad limit (<= 0) raises.
"""

from std.math import atan2, sqrt
from harness.runner import Suite
from geometry.vec import Real, Vec3, length
from geometry.quat import Quat
from physics.body_set import BodyId
from physics.rigid6 import Inertia3, QuatBody6
from physics.solver6 import ContactScene6
from gameplay.vehicle_kinds import hitch
from gameplay.vehicle_truck import fifth_wheel

comptime DT: Real = 1.0 / 60.0
comptime G = Vec3(0, -9.8, 0, 0)


def scene() raises -> ContactScene6[QuatBody6]:
    var sc = ContactScene6[QuatBody6]()
    _ = sc.add(QuatBody6.at_rest(Vec3(0, 5, 0, 0), Inertia3.box(8000, 4.0, 0.6, 1.0)), Vec3(4.0, 0.6, 1.0, 0), True)
    _ = sc.add(QuatBody6.at_rest(Vec3(-8.4, 5, 0, 0), Inertia3.box(12000, 4.0, 0.6, 1.0)), Vec3(4.0, 0.6, 1.0, 0), False)
    return sc^


def rel_angles(sc: ContactScene6[QuatBody6]) -> Tuple[Real, Real, Real]:
    """(roll about x, yaw about y, pitch about z) of the trailer (body 1) relative to the tractor (body 0): the
    rotation-vector components, as the D6 joint measures them."""
    var q = sc.bset.bodies[0].q.conjugate() * sc.bset.bodies[1].q
    if q.w < 0:
        q = Quat(-q.x, -q.y, -q.z, -q.w)
    return (2 * q.x, 2 * q.y, 2 * q.z)


def gap_of(sc: ContactScene6[QuatBody6], la: Vec3, lb: Vec3) -> Real:
    var a = sc.bset.bodies[0]
    var b = sc.bset.bodies[1]
    return length((a.pos + a.q.rotate(la)) - (b.pos + b.q.rotate(lb)))


def main() raises:
    var s = Suite("fifth_wheel")
    var point = Vec3(-4.4, 5, 0, 0)
    var tid = BodyId(0, 0)
    var rid = BodyId(1, 0)

    var sb = scene()
    _ = hitch(sb, tid, rid, point)
    var worst_ball = Real(0)
    for _ in range(300):
        sb.step_soft(DT, G)
        var p = rel_angles(sb)[2]
        worst_ball = max(worst_ball, abs(p))
    s.check(worst_ball > 0.5, "ball hitch: the trailer swings down, relative pitch up to " + String(worst_ball) + " rad")

    var sf = scene()
    _ = fifth_wheel(sf, tid, rid, point)
    var la = sf.bset.bodies[0].to_local(point)
    var lb = sf.bset.bodies[1].to_local(point)
    var worst_p = Real(0)
    var worst_r = Real(0)
    var worst_gap = Real(0)
    for _ in range(300):
        sf.step_soft(DT, G)
        var a = rel_angles(sf)
        worst_r = max(worst_r, abs(a[0]))
        worst_p = max(worst_p, abs(a[2]))
        worst_gap = max(worst_gap, gap_of(sf, la, lb))
    s.check(worst_p <= 0.17 and worst_r <= 0.12, "fifth wheel: pitch up to " + String(worst_p) + " rad (limit 0.15), roll up to " + String(worst_r) + " rad (limit 0.10)")
    s.check(worst_gap < 0.02, "the coupling stays together: gap up to " + String(worst_gap) + " m")

    # yaw: the same angular velocity on the trailer, with the ball hitch (free in all three) as the reference
    var sy = scene()
    _ = fifth_wheel(sy, tid, rid, point)
    sy.set_velocity(rid, Vec3(0, 0, 0, 0), Vec3(0, 0.8, 0, 0))
    var sr = scene()
    _ = hitch(sr, tid, rid, point)
    sr.set_velocity(rid, Vec3(0, 0, 0, 0), Vec3(0, 0.8, 0, 0))
    for _ in range(60):
        sy.step_soft(DT, Vec3(0, 0, 0, 0))  # no gravity: the comparison is about yaw alone
        sr.step_soft(DT, Vec3(0, 0, 0, 0))
    var yaw = abs(rel_angles(sy)[1])
    var yaw_ref = abs(rel_angles(sr)[1])
    s.check(yaw > 0.1 and abs(yaw - yaw_ref) <= 0.15 * yaw_ref, "yaw is free: " + String(yaw) + " rad after 1 s, the ball hitch gives " + String(yaw_ref) + " rad")

    var raised = False
    try:
        var s2 = scene()
        _ = fifth_wheel(s2, tid, rid, point, 0.0, 0.1)
    except:
        raised = True
    s.check(raised, "a zero pitch limit raises")
    s.finish()
