"""Single-rotor helicopter with a tail rotor (ROADMAP 17.74).

`Helicopter` is a force element on one body:

  * main rotor at `hub` (body frame), thrust `collective` (N, clamped to
    [0, max_thrust]) along the body up axis tilted by the cyclic angles
    (`cyclic_pitch` about body x, `cyclic_roll` about body z, radians,
    clamped to +-max_cyclic) -- tilting the thrust is how a helicopter
    pitches, rolls and moves;
  * the main rotor's drag reacts on the body as a yaw torque
    -`torque_ratio` x thrust about body up (the rotor spins one way, the
    fuselage wants to turn the other);
  * the tail rotor at `tail` pushes along body x with `tail_thrust` (N,
    +-max_tail), giving the yaw torque that cancels or exceeds that
    reaction.

`HeliController.command` is a PD loop: collective from height (vertical
speed from the height change between calls, as `QuadController`), cyclic
from tilt, tail thrust from heading error with the main rotor's reaction
fed forward.
"""

from std.math import atan2
from geometry.trig import sin, cos
from geometry.vec import Real, Vec3, cross
from geometry.quat import Quat
from physics.body_set import BodyId
from physics.rigid6 import QuatBody6
from physics.solver6 import ContactScene6
from .force_element import ForceElement


struct Helicopter(ForceElement, Copyable, Movable):
    var hub: Vec3
    var tail: Vec3
    var max_thrust: Real
    var max_cyclic: Real
    var max_tail: Real
    var torque_ratio: Real  # m: main-rotor reaction torque per newton
    var collective: Real
    var cyclic_pitch: Real
    var cyclic_roll: Real
    var tail_thrust: Real

    def __init__(out self, hub: Vec3, tail: Vec3, max_thrust: Real, max_cyclic: Real, max_tail: Real, torque_ratio: Real) raises:
        if not (max_thrust > 0 and max_cyclic > 0 and max_tail > 0 and torque_ratio >= 0):
            raise Error("Helicopter: positive limits, torque_ratio >= 0")
        if tail[2] == 0 and tail[1] == 0:
            raise Error("Helicopter: the tail rotor needs a lever arm along body z or y")
        self.hub = hub
        self.tail = tail
        self.max_thrust = max_thrust
        self.max_cyclic = max_cyclic
        self.max_tail = max_tail
        self.torque_ratio = torque_ratio
        self.collective = 0
        self.cyclic_pitch = 0
        self.cyclic_roll = 0
        self.tail_thrust = 0

    def thrust_dir_local(self) -> Vec3:
        var p = min(max(self.cyclic_pitch, -self.max_cyclic), self.max_cyclic)
        var r = min(max(self.cyclic_roll, -self.max_cyclic), self.max_cyclic)
        var q = Quat.from_axis_angle(Vec3(1, 0, 0, 0), p) * Quat.from_axis_angle(Vec3(0, 0, 1, 0), r)
        return q.rotate(Vec3(0, 1, 0, 0))

    def apply(mut self, mut sc: ContactScene6[QuatBody6], id: BodyId, t: Real) raises -> Vec3:
        var pose = sc.pose(id)
        var th = min(max(self.collective, Real(0)), self.max_thrust)
        var f = pose.rot.rotate(self.thrust_dir_local()) * th
        sc.add_force_at(id, f, pose.pos + pose.rot.rotate(self.hub))
        var up = pose.rot.rotate(Vec3(0, 1, 0, 0))
        sc.add_torque(id, up * (-self.torque_ratio * th))
        var tt = min(max(self.tail_thrust, -self.max_tail), self.max_tail)
        var ft = pose.rot.rotate(Vec3(1, 0, 0, 0)) * tt
        sc.add_force_at(id, ft, pose.pos + pose.rot.rotate(self.tail))
        return f + ft


struct HeliController(Copyable, Movable):
    var mass: Real
    var kp_h: Real
    var kd_h: Real
    var kp_att: Real
    var kd_att: Real
    var kp_yaw: Real
    var kd_yaw: Real
    var last_y: Real
    var started: Bool

    def __init__(out self, mass: Real, kp_h: Real, kd_h: Real, kp_att: Real, kd_att: Real, kp_yaw: Real, kd_yaw: Real):
        self.mass = mass
        self.kp_h = kp_h
        self.kd_h = kd_h
        self.kp_att = kp_att
        self.kd_att = kd_att
        self.kp_yaw = kp_yaw
        self.kd_yaw = kd_yaw
        self.last_y = 0
        self.started = False

    def command(mut self, mut heli: Helicopter, sc: ContactScene6[QuatBody6], id: BodyId, target_y: Real, target_yaw: Real, g: Real, dt: Real) raises:
        var pose = sc.pose(id)
        var w = sc.angular_velocity(id)
        var up = pose.rot.rotate(Vec3(0, 1, 0, 0))
        var vy = (pose.pos[1] - self.last_y) / dt if self.started else Real(0)
        self.last_y = pose.pos[1]
        self.started = True
        heli.collective = self.mass * (self.kp_h * (target_y - pose.pos[1]) - self.kd_h * vy + g) / max(up[1], Real(0.2))
        # cyclic: tilt the thrust against the body's tilt (local frame)
        var tl = pose.rot.conjugate().rotate(cross(up, Vec3(0, 1, 0, 0)))
        var wl = pose.rot.conjugate().rotate(w)
        heli.cyclic_pitch = self.kp_att * tl[0] - self.kd_att * wl[0]
        heli.cyclic_roll = self.kp_att * tl[2] - self.kd_att * wl[2]
        # tail: cancel the main rotor's reaction, then steer the heading
        var fwd = pose.rot.rotate(Vec3(0, 0, 1, 0))
        var e = target_yaw - atan2(fwd[0], fwd[2])
        while e > 3.14159265:
            e -= 6.2831853
        while e < -3.14159265:
            e += 6.2831853
        var yaw_torque = heli.torque_ratio * heli.collective + self.kp_yaw * e - self.kd_yaw * wl[1]
        # tail force along +x at z = tail[2] gives torque about y of tail[2] * f
        heli.tail_thrust = yaw_torque / heli.tail[2] if heli.tail[2] != 0 else Real(0)
