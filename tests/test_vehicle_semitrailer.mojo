# tier: integration
"""A truck with a semi-trailer (ROADMAP 17.74, #98): `truck_config` + `semi_trailer_config` + `hitch`.

  1. Standing: the trailer's two wheels carry part of its weight and the tractor the rest through the hitch; total
     wheel load of both vehicles plus the hitch share equals the combined weight (reported).
  2. Towing: 10 s of throttle drives the pair forward; the hitch anchors stay within 2 cm; the trailer's heading is
     within 0.1 rad of the tractor's; the trailer's wheels stay grounded.
  3. Steering: a constant steer input for 6 s bends the trailer's path: it follows the tractor on the inside (off-
     tracking), i.e. the trailer's yaw lags the tractor's but has the same sign.
"""

from std.math import atan2
from harness.runner import Suite
from geometry.vec import Real, Vec3, length
from geometry.quat import Quat
from physics.rigid6 import Inertia3, QuatBody6
from physics.solver6 import ContactScene6
from gameplay.vehicle import Vehicle, VehicleInput, spawn_chassis
from gameplay.vehicle_wheel import RayWheel
from gameplay.vehicle_truck import truck_config, semi_trailer_config
from gameplay.vehicle_kinds import hitch

comptime DT: Real = 1.0 / 60.0
comptime G = Vec3(0, -9.8, 0, 0)


def road() raises -> ContactScene6[QuatBody6]:
    var sc = ContactScene6[QuatBody6]()
    var f = sc.add(QuatBody6.at_rest(Vec3(0, -1, 0, 0), Inertia3.box(1, 1, 1, 1)), Vec3(3000, 1, 3000, 0), True)
    sc.set_friction(f.index(), 0.8)
    return sc^


def yaw_of(sc: ContactScene6[QuatBody6], idx: Int) -> Real:
    var h = sc.bset.bodies[idx].q.rotate(Vec3(1, 0, 0, 0))
    return atan2(-h[2], h[0])


def main() raises:
    var s = Suite("vehicle_semitrailer")
    var tc = truck_config()
    var rc = semi_trailer_config()
    var sc = road()
    var tid = spawn_chassis(sc, tc, Vec3(0, 1.1, 0, 0))
    # a ball hitch at the tractor's rear end (its box spans x = -4.2 .. 4.2), 0.1 m clear of it
    var hitch_x = Real(-4.3)
    var rid = spawn_chassis(sc, rc, Vec3(hitch_x - rc.half[0], 1.1, 0, 0))
    var tractor = Vehicle[RayWheel].attach(sc, tid, tc.copy(), RayWheel())
    var trailer = Vehicle[RayWheel].attach(sc, rid, rc.copy(), RayWheel())
    var hp = Vec3(hitch_x, 1.1, 0, 0)
    var la = sc.bset.bodies[tid.index()].to_local(hp)
    var lb = sc.bset.bodies[rid.index()].to_local(hp)
    _ = hitch(sc, tid, rid, hp)
    for _ in range(300):
        tractor.update(sc, VehicleInput.idle(), DT)
        trailer.update(sc, VehicleInput.idle(), DT)
        sc.step_soft(DT, G)
    var tload = Real(0)
    for w in range(len(tractor.wheels)):
        tload += tractor.wheels[w].fz
    var rload = Real(0)
    for w in range(len(trailer.wheels)):
        rload += trailer.wheels[w].fz
    var weight = (tc.mass + rc.mass) * 9.8
    s.check(abs(tload + rload - weight) / weight < 0.02 and rload > 0.2 * rc.mass * 9.8, "standing: tractor wheels " + String(tload) + " N + trailer wheels " + String(rload) + " N = " + String(tload + rload) + " N vs combined weight " + String(weight) + " N")

    var worst_gap = Real(0)
    var grounded_ok = True
    for _ in range(600):
        tractor.update(sc, VehicleInput(0.7, 0, 0, 0), DT)
        trailer.update(sc, VehicleInput.idle(), DT)
        sc.step_soft(DT, G)
        var a = sc.bset.bodies[tid.index()]
        var b = sc.bset.bodies[rid.index()]
        var pa = a.pos + a.q.rotate(la)
        var pb = b.pos + b.q.rotate(lb)
        worst_gap = max(worst_gap, length(pa - pb))
        if trailer.grounded_count() < 2:
            grounded_ok = False
    var dyaw = yaw_of(sc, tid.index()) - yaw_of(sc, rid.index())
    s.check(tractor.forward_speed(sc) > 3.0 and abs(dyaw) < 0.1, "towing 10 s: " + String(tractor.forward_speed(sc)) + " m/s, tractor-trailer yaw difference " + String(dyaw) + " rad")
    s.check(worst_gap < 0.02, "the hitch anchors stayed within " + String(worst_gap) + " m")
    s.check(grounded_ok, "the trailer's two wheels stay on the ground")
    var y0t = yaw_of(sc, tid.index())
    var y0r = yaw_of(sc, rid.index())
    var gap2 = Real(0)
    for _ in range(360):
        tractor.update(sc, VehicleInput(0.1, 0, 0.5, 0), DT)
        trailer.update(sc, VehicleInput.idle(), DT)
        sc.step_soft(DT, G)
        var a = sc.bset.bodies[tid.index()]
        var b = sc.bset.bodies[rid.index()]
        gap2 = max(gap2, length((a.pos + a.q.rotate(la)) - (b.pos + b.q.rotate(lb))))
    var turn_t = yaw_of(sc, tid.index()) - y0t
    var turn_r = yaw_of(sc, rid.index()) - y0r
    s.check(turn_t * turn_r > 0 and abs(turn_r) < abs(turn_t) and gap2 < 0.02, "6 s of steering: tractor turned " + String(turn_t) + " rad, trailer " + String(turn_r) + " rad (same sign, trailer lags), hitch gap " + String(gap2) + " m")
    s.finish()
