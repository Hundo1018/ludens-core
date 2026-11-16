"""Example 24 — a locomotion graph end to end (ROADMAP 17.6).

A state machine decides idle vs moving; while moving, the speed parameter
drives a 1-D blend space over walk and run (sampled at a shared phase so the
feet stay in step); an aim layer turns the arm; the root motion of the blended
cycle is handed to the character controller, and the pose (root stripped) is
skinned. Printed per half second: state, speed, blend weights, where the
controller is, where one skinned vertex on the arm ends up, and the ankle
height after foot planting (17.3) on the ground found by a world query.

Run:

    pixi run mojo run -I build examples/24_locomotion_graph.mojo
"""

from std.math import sin, cos
from geometry.vec import Real, Vec3
from geometry.quat import Quat
from geometry.motor import Motor3
from geometry.skinning import skin_motor
from physics.rigid6 import QuatBody6, Inertia3
from physics.solver6 import ContactScene6
from gameplay.character import CharacterController
from procedural.fsm import StateMachine
from procedural.anim import AnimClip
from procedural.anim_graph import Pose, BlendSpace1D, sample_phase, layer, root_motion, strip_root
from procedural.ik import foot_plant
from procedural.ik_pose import two_bone_pose
from collision.world_query import QueryFilter

comptime DT: Real = 1.0 / 60.0
comptime EV_GO = 0
comptime EV_STOP = 1


def _qy(deg: Real) -> Quat:
    var h = deg * Real(3.14159265358979 / 360.0)
    return Quat(0, sin(h), 0, cos(h))


def _cycle(frames: Int, speed: Real, sway: Real) raises -> AnimClip:
    var c = AnimClip(3, frames, 10)
    var dur = Real(frames - 1) / 10
    for f in range(frames):
        var t = Real(f) / 10
        c.set_key(f, 0, Vec3(speed * t, 1, 0, 0), Quat.identity())
        c.set_key(f, 1, Vec3(0, 0.5, 0, 0), _qy(sway * sin(t / dur * 6.2831853)))
        c.set_key(f, 2, Vec3(0.3, 0.4, 0, 0), Quat.identity())
    return c^


def main() raises:
    var clips = List[AnimClip]()
    clips.append(_cycle(11, 1.0, 10))  # walk 1.0 s, 1 m/s
    clips.append(_cycle(7, 3.0, 20))  # run 0.6 s, 3 m/s
    var aim = AnimClip(3, 1, 10)
    aim.set_key(0, 0, Vec3(0, 1, 0, 0), Quat.identity())
    aim.set_key(0, 1, Vec3(0, 0.5, 0, 0), Quat.identity())
    aim.set_key(0, 2, Vec3(0.3, 0.4, 0, 0), _qy(60))
    clips.append(aim^)

    var space = BlendSpace1D()
    space.add(1, 0)
    space.add(3, 1)
    var mask = List[Real]()
    mask.append(0)
    mask.append(0)
    mask.append(1)

    var fsm = StateMachine()
    var idle = fsm.add_state()
    var moving = fsm.add_state()
    fsm.add_transition(idle, EV_GO, moving)
    fsm.add_transition(moving, EV_STOP, idle)
    fsm.start(idle)

    var sc = ContactScene6[QuatBody6]()
    _ = sc.add(QuatBody6.at_rest(Vec3(0, -1, 0, 0), Inertia3.box(1, 1, 1, 1)), Vec3(40, 1, 40, 0), True)
    var ctl = CharacterController(Vec3(0, 0.92, 0, 0))
    var g = Vec3(0, -9.8, 0, 0)

    # one vertex on the arm, fully bound to bone 2
    var rest = List[Vec3]()
    rest.append(Vec3(0.6, 1.9, 0, 0))
    var ia = List[Int]()
    ia.append(2)
    var ib = List[Int]()
    ib.append(2)
    var wa = List[Real]()
    wa.append(1)
    var skinned = List[Vec3]()
    skinned.append(Vec3(0, 0, 0, 0))

    var phase = Real(0)
    for frame in range(240):
        var t = Real(frame) * DT
        if frame == 30:
            _ = fsm.fire(EV_GO)
        if frame == 200:
            _ = fsm.fire(EV_STOP)
        var speed = Real(0)
        if fsm.is_in(moving):
            speed = min(Real(1) + t, Real(3))  # accelerate from walk to run
        var w = space.weights(speed)
        # phase advances at the blended cycle rate
        var dur = w[0] * clips[0].duration() + w[1] * clips[1].duration()
        var p0 = phase
        if speed > 0:
            phase += DT / dur
            if phase >= 1:
                phase -= 1
        var pose = space.evaluate(clips, speed, phase)
        var aimed = layer(pose, sample_phase(clips[2], 0), mask, Real(1) if fsm.is_in(moving) else Real(0))
        # root motion of the blended cycle over this frame -> controller
        var v = Vec3(0, 0, 0, 0)
        if speed > 0:
            var rm0 = root_motion(clips[0], 0, p0 * clips[0].duration(), (p0 + DT / dur) * clips[0].duration())
            var rm1 = root_motion(clips[1], 0, p0 * clips[1].duration(), (p0 + DT / dur) * clips[1].duration())
            v = (rm0 * w[0] + rm1 * w[1]) * (1 / DT)
        ctl.update(sc, v, 0, DT, g)
        strip_root(aimed, 0)
        var motors = List[Motor3]()
        for b in range(3):
            motors.append(aimed.motor(b))
        skin_motor(motors, rest, ia, ib, wa, skinned)
        # foot planting (17.3): ground under the foot from a world query,
        # the ankle target lifted onto it, the leg solved analytically
        var foot = ctl.foot()
        var hit = sc.ray_cast(foot + Vec3(0, 1, 0, 0), Vec3(0, -1, 0, 0), 3, QueryFilter.all())
        var ankle_y = Real(-1)
        if hit.hit:
            var fp = foot_plant(foot + Vec3(0, 0.08, 0, 0), 0.08, hit.point[1], hit.normal, 0.3, 0.5)
            var hip = foot + Vec3(0, 0.9, 0, 0)
            # the leg as a world pose (hip, knee, ankle); two_bone_pose writes the solution back as bone rotations
            var leg = Pose(3)
            leg.set(0, hip, Quat.identity())
            leg.set(1, hip + Vec3(0, -0.45, 0.05, 0), Quat.identity())
            leg.set(2, foot + Vec3(0, 0.08, 0, 0), Quat.identity())
            _ = two_bone_pose(leg, [-1, 0, 1], 0, 1, 2, fp.ankle, hip + Vec3(0, 0, 1, 0))
            ankle_y = leg.p(2)[1]
        if frame % 30 == 0:
            print(
                "t", t, " state", "moving" if fsm.is_in(moving) else "idle",
                " speed", speed, " w(walk,run)", w[0], w[1],
                " controller x", ctl.position[0], " arm vertex", skinned[0],
                " planted ankle y", ankle_y,
            )
