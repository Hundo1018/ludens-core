"""A three-axle truck configuration (ROADMAP 17.74, #98, multi-axle trucks).

`VehicleConfig` already takes up to 8 wheels on axles 0..3 and splits engine torque across the driven axles; what was
missing was a preset that uses it. `truck_config(...)` builds a 6x4: a steered front axle (axle 0, undriven) and two
driven rear axles (axles 1 and 2), dual-sided, with a diesel torque curve and six gears, and with the mass, inertia, spring rate and brake torque scaled from the
sedan's defaults to a heavy chassis. The wheel loads, not the config, decide how the weight is shared; the test
(`test_vehicle_truck`) measures that.
"""

from geometry.vec import Real, Vec3
from physics.body_set import BodyId
from physics.joints6 import Joint6
from physics.joint_ext import D6_FREE, D6_LIMITED
from physics.rigid6 import Inertia3, QuatBody6
from physics.solver6 import ContactScene6
from .vehicle import VehicleConfig, WheelConfig
from .vehicle_drive import TorqueCurve


def truck_config(mass: Real = 8000, wheelbase: Real = 4.4, axle_gap: Real = 1.4, track: Real = 1.9) raises -> VehicleConfig:
    """Axles are placed so the centre of mass carries the three axles equally: the front axle at +a, the rear axles at
    -b and -b - `axle_gap`, with a + b = `wheelbase` (front to first rear axle) and a = 2 b + axle_gap, i.e.
    b = (wheelbase - axle_gap) / 3. `track` is the distance between the left and right wheels."""
    if not (mass > 0) or not (axle_gap > 0) or not (track > 0) or not (wheelbase > axle_gap):
        raise Error("truck_config: mass, track and axle gap must be > 0 and the wheelbase longer than the axle gap")
    var b = (wheelbase - axle_gap) / 3
    var a = wheelbase - b
    var cfg = VehicleConfig()
    cfg.mass = mass
    var half = Vec3(a + 0.8, 0.6, track / 2 + 0.2, 0)
    cfg.half = half
    var ib = Inertia3.box(mass, half[0], half[1], half[2])
    cfg.inertia = Vec3(ib.ix, ib.iy, ib.iz, 0)
    cfg.wheels = List[WheelConfig]()
    var xs = List[Real]()
    xs.append(a)  # front
    xs.append(-b)  # first rear
    xs.append(-b - axle_gap)  # second rear
    for a in range(3):
        for side in range(2):
            var z = -track / 2 if side == 0 else track / 2
            cfg.wheels.append(
                WheelConfig(
                    Vec3(xs[a], -0.3, z, 0), 0.5, 0.15, 6.0,
                    a,
                    Real(1.0) if a == 0 else Real(0.0),
                    a != 0,
                    a != 0,
                    Real(0.3) if a == 0 else Real(0.35),
                )
            )
    # scale the sedan's suspension, brakes and drive to the heavy chassis
    var k = mass / 1200
    cfg.susp.length = 0.5
    cfg.susp.stiffness = cfg.susp.stiffness * k
    cfg.susp.damp_compress = cfg.susp.damp_compress * k
    cfg.susp.damp_rebound = cfg.susp.damp_rebound * k
    cfg.brake_torque = cfg.brake_torque * k * Real(0.5)
    cfg.handbrake_torque = cfg.handbrake_torque * k * Real(0.5)
    cfg.max_steer = 0.4
    # diesel drivetrain: a wide, low-rpm torque band and six ratios; the sedan's curve peaks at 300 Nm
    cfg.drive.torque = TorqueCurve.diesel_truck()
    cfg.drive.idle_rpm = 600
    cfg.drive.launch_rpm = 1200
    cfg.drive.redline_rpm = 2500
    cfg.drive.up_rpm = 2200
    cfg.drive.down_rpm = 1100
    cfg.drive.gears = [Real(7.0), Real(4.2), Real(2.7), Real(1.8), Real(1.25), Real(1.0)]
    cfg.drive.final_drive = 4.1
    cfg.drive.engine_brake = 400
    cfg.drive.shift_time = 0.5
    cfg.validate()
    return cfg^


def semi_trailer_config(mass: Real = 12000, length: Real = 8.0, track: Real = 1.9) raises -> VehicleConfig:
    """A one-axle semi-trailer: two undriven, unsteered wheels near the rear and a box `length` long. Its front is
    carried by the tractor through a ball joint (`gameplay.vehicle_kinds.hitch`) at the box's front end, so with the
    tractor it behaves like a 6x4 with a fifth wheel. The chassis origin is the box centre; the hitch point in the
    trailer frame is (+length / 2, y, 0)."""
    if not (mass > 0) or not (length > 2) or not (track > 0):
        raise Error("semi_trailer_config: mass, track must be > 0 and length > 2")
    var cfg = truck_config(mass, 4.4, 1.4, track)
    var half = Vec3(length / 2, 0.6, track / 2 + 0.2, 0)
    cfg.half = half
    var ib = Inertia3.box(mass, half[0], half[1], half[2])
    cfg.inertia = Vec3(ib.ix, ib.iy, ib.iz, 0)
    cfg.wheels = List[WheelConfig]()
    for side in range(2):
        var z = -track / 2 if side == 0 else track / 2
        cfg.wheels.append(WheelConfig(Vec3(-length / 2 + 1.2, -0.3, z, 0), 0.5, 0.15, 6.0, 1, Real(0.0), False, False, Real(0.5)))
    cfg.validate()
    return cfg^


def fifth_wheel(
    mut sc: ContactScene6[QuatBody6], tractor: BodyId, trailer: BodyId, point: Vec3, max_pitch: Real = 0.15, max_roll: Real = 0.1
) raises -> Int:
    """A fifth-wheel coupling between a tractor and a semi-trailer: the anchors are tied at the world `point`, yaw about
    the tractor's up axis is free (the trailer swings behind the tractor), and pitch and roll are limited to +-`max_pitch`
    and +-`max_roll` rad. A ball hitch (`gameplay.vehicle_kinds.hitch`) leaves all three free, so a semi-trailer rests on
    its landing gear or its wheels; this one carries the front of the trailer and keeps it level. A D6 joint
    (`ContactScene6.set_d6_axis`), axes in the tractor's frame (x forward, y up, z right): 3 = roll, 4 = yaw, 5 = pitch."""
    if not (max_pitch > 0) or not (max_roll > 0):
        raise Error("fifth_wheel: pitch and roll limits must be > 0")
    ref a = sc.bset.bodies[tractor.index()]
    ref b = sc.bset.bodies[trailer.index()]
    var j = sc.add_joint(Joint6.d6(tractor.index(), trailer.index(), a.to_local(point), b.to_local(point)))
    sc.set_d6_axis(j, 3, D6_LIMITED, -max_roll, max_roll)
    sc.set_d6_axis(j, 4, D6_FREE)
    sc.set_d6_axis(j, 5, D6_LIMITED, -max_pitch, max_pitch)
    return j
