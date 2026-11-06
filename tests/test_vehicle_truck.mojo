# tier: integration
"""A three-axle truck from `truck_config` (ROADMAP 17.74, #98).

  1. Parked: the six wheel loads sum to the weight (1 %) and each axle carries a third of it within 2 % (measured 6.7e-7; the preset puts the
     centre of mass where the three axles share equally; ).
  2. Driving: full throttle for 8 s on a flat road keeps the heading (|yaw| < 0.05 rad) and gains speed; only the
     two rear axles (4 wheels) receive drive torque, the front axle none.
  3. Steering: a constant steer input turns the truck; the turn radius is within 30 % of the bicycle model
     L / tan(delta) with L the front-to-mid-rear distance (measured value reported).
  4. A bad preset (wheelbase shorter than the axle gap) raises.
"""

from std.math import atan, tan, sqrt
from harness.runner import Suite
from geometry.vec import Real, Vec3, length
from geometry.quat import Quat
from physics.rigid6 import Inertia3, QuatBody6
from physics.solver6 import ContactScene6
from gameplay.vehicle import Vehicle, VehicleInput, spawn_chassis
from gameplay.vehicle_wheel import RayWheel
from gameplay.vehicle_truck import truck_config

comptime DT: Real = 1.0 / 60.0
comptime G = Vec3(0, -9.8, 0, 0)


def road() raises -> ContactScene6[QuatBody6]:
    var sc = ContactScene6[QuatBody6]()
    var f = sc.add(QuatBody6.at_rest(Vec3(0, -1, 0, 0), Inertia3.box(1, 1, 1, 1)), Vec3(3000, 1, 3000, 0), True)
    sc.set_friction(f.index(), 0.8)
    return sc^


def run(mut v: Vehicle[RayWheel], mut sc: ContactScene6[QuatBody6], inp: VehicleInput, steps: Int):
    for _ in range(steps):
        v.update(sc, inp, DT)
        sc.step_soft(DT, G)


def main() raises:
    var s = Suite("vehicle_truck")
    var cfg = truck_config()
    var sc = road()
    var id = spawn_chassis(sc, cfg, Vec3(0, 1.1, 0, 0))
    var v = Vehicle[RayWheel].attach(sc, id, cfg.copy(), RayWheel())
    run(v, sc, VehicleInput.idle(), 240)
    var total = Real(0)
    var axle = List[Real]()
    for _ in range(3):
        axle.append(0)
    for w in range(len(v.wheels)):
        total += v.wheels[w].fz
        axle[cfg.wheels[w].axle] += v.wheels[w].fz
    var weight = cfg.mass * 9.8
    s.check(abs(total - weight) / weight < 0.01, "six wheel loads sum to the weight: " + String(total) + " N vs " + String(weight) + " N")
    var worst = Real(0)
    for a in range(3):
        worst = max(worst, abs(axle[a] - weight / 3) / (weight / 3))
    s.check(worst < 0.02, "each axle carries a third of the weight: " + String(axle[0]) + ", " + String(axle[1]) + ", " + String(axle[2]) + " N (worst deviation " + String(worst) + ")")

    var x0 = sc.bset.bodies[id.index()].pos[0]
    run(v, sc, VehicleInput(1, 0, 0, 0), 480)
    var pos = sc.bset.bodies[id.index()].pos
    var fwd = v.forward_speed(sc)
    var rot = sc.bset.bodies[id.index()].q
    var heading = rot.rotate(Vec3(1, 0, 0, 0))
    var yaw = atan(heading[2] / heading[0])
    s.check(fwd > 3.0 and abs(yaw) < 0.05, "8 s of full throttle: " + String(fwd) + " m/s forward, travelled " + String(pos[0] - x0) + " m, yaw " + String(yaw) + " rad")
    var front_drive = Real(0)
    var rear_drive = Real(0)
    for w in range(len(v.wheels)):
        if cfg.wheels[w].axle == 0:
            front_drive += abs(v.wheels[w].drive_torque)
        else:
            rear_drive += abs(v.wheels[w].drive_torque)
    s.check(front_drive == 0 and rear_drive > 0, "drive torque only on the rear axles: front " + String(front_drive) + " N m, rear " + String(rear_drive) + " N m")

    var sc2 = road()
    var id2 = spawn_chassis(sc2, cfg, Vec3(0, 1.1, 0, 0))
    var v2 = Vehicle[RayWheel].attach(sc2, id2, cfg.copy(), RayWheel())
    run(v2, sc2, VehicleInput.idle(), 240)
    sc2.set_velocity(id2, Vec3(6, 0, 0, 0), Vec3(0, 0, 0, 0))
    v2.sync_wheels(6)
    run(v2, sc2, VehicleInput(0.3, 0, 0.5, 0), 360)
    var w2 = sc2.bset.bodies[id2.index()]
    var speed = length(Vec3(w2.vel[0], 0, w2.vel[2], 0))
    var yawrate = abs(w2.omega[1])
    var radius = speed / yawrate if yawrate > 1e-3 else Real(1e9)
    var wheelbase_eff = Real(4.4) + Real(1.4) / 2  # front axle to the mid point of the two rear axles
    var delta = 0.5 * cfg.max_steer
    var expect = wheelbase_eff / tan(delta)
    s.check(radius > 0.7 * expect and radius < 1.3 * expect, "steady turn radius " + String(radius) + " m, bicycle model " + String(expect) + " m (L = " + String(wheelbase_eff) + " m)")

    var raised = False
    try:
        _ = truck_config(8000, 1.0, 1.4, 1.9)
    except:
        raised = True
    s.check(raised, "a wheelbase shorter than the axle gap raises")
    s.finish()
