# tier: component
"""IK results written back into a Pose (ROADMAP 17.3 leftover: procedural/ik_pose.mojo).

  ordinary     a six-bone leg (pelvis, hip, knee, ankle, toe; spine off the
               pelvis): two_bone_pose puts the ankle on a reachable target,
               keeps both bone lengths, changes only the local rotations of
               the hip and the knee (every local position and every other
               local rotation unchanged), and leaves the bones outside the
               hip's subtree alone.
  round trip   to_world(to_local(world)) == world.
  extreme      unreachable target: the chain points straight at it and the
               ankle is at l1 + l2 from the hip; shortest_arc on equal,
               opposite and zero vectors.
"""

from std.math import sqrt
from harness.runner import Suite
from geometry.vec import Real, Vec3, dot, length
from geometry.quat import Quat
from procedural.anim_graph import Pose, to_world
from procedural.ik_pose import two_bone_pose, shortest_arc, to_local


def _v(x: Real, y: Real, z: Real) -> Vec3:
    return Vec3(x, y, z, 0)


def _leg() -> Tuple[Pose, List[Int]]:
    """Local pose: pelvis 0 at (0, 1, 0); hip 1; knee 2; ankle 3; toe 4; spine 5 (child of the pelvis)."""
    var parent: List[Int] = [-1, 0, 1, 2, 3, 0]
    var loc = Pose(6)
    loc.set(0, _v(0, 1.0, 0), Quat.from_axis_angle(_v(0, 1, 0), 0.3))
    loc.set(1, _v(0.1, -0.05, 0), Quat.from_axis_angle(_v(1, 0, 0), 0.2))
    loc.set(2, _v(0, -0.45, 0.02), Quat.from_axis_angle(_v(1, 0.2, 0), -0.4))
    loc.set(3, _v(0, -0.42, -0.03), Quat.from_axis_angle(_v(0, 0, 1), 0.1))
    loc.set(4, _v(0, -0.05, 0.14), Quat.identity())
    loc.set(5, _v(0, 0.2, 0), Quat.from_axis_angle(_v(0, 0, 1), 0.05))
    return (to_world(loc, parent), parent^)


def _qdiff(a: Quat, b: Quat) -> Real:
    """1 - |<a, b>|: 0 when a and b are the same rotation."""
    return 1 - abs(a.x * b.x + a.y * b.y + a.z * b.z + a.w * b.w)


def main() raises:
    var s = Suite("ik_pose")
    var leg = _leg()
    var w0 = leg[0].copy()
    var parent = leg[1].copy()
    var l0 = to_local(w0, parent)

    # round trip
    var rt = to_world(l0, parent)
    var rt_err = Real(0)
    for b in range(w0.bones):
        rt_err = max(rt_err, length(rt.p(b) - w0.p(b)))
        rt_err = max(rt_err, _qdiff(rt.q(b), w0.q(b)))
    s.check(rt_err < 1e-6, "to_world(to_local(w)) == w (max err " + String(rt_err) + ")")

    # reachable target
    var w = w0.copy()
    var len1 = length(w.p(2) - w.p(1))
    var len2 = length(w.p(3) - w.p(2))
    var target = w.p(3) + _v(0.05, 0.25, 0.1)
    var pole = w.p(2) + _v(0, 0, 1)
    var tb = two_bone_pose(w, parent, 1, 2, 3, target, pole)
    s.check(tb.reached, "reachable target reported reached")
    s.check(length(w.p(3) - target) < 1e-4, "ankle on target (" + String(length(w.p(3) - target)) + " m)")
    s.check(length(w.p(2) - tb.mid) < 1e-4, "knee on the solved knee")
    s.almost(Float64(length(w.p(2) - w.p(1))), Float64(len1), "thigh length kept", 1e-6)
    s.almost(Float64(length(w.p(3) - w.p(2))), Float64(len2), "shin length kept", 1e-6)
    var l1 = to_local(w, parent)
    var pos_err = Real(0)
    var rot_err = Real(0)
    for b in range(w.bones):
        pos_err = max(pos_err, length(l1.p(b) - l0.p(b)))
        if b != 1 and b != 2:
            rot_err = max(rot_err, _qdiff(l1.q(b), l0.q(b)))
    s.check(pos_err < 1e-6, "every local position unchanged (max " + String(pos_err) + ")")
    s.check(rot_err < 1e-6, "local rotations other than hip and knee unchanged (max " + String(rot_err) + ")")
    s.check(_qdiff(l1.q(1), l0.q(1)) > 1e-6 and _qdiff(l1.q(2), l0.q(2)) > 1e-6, "hip and knee rotations changed")
    var outside = Real(0)
    for b in [0, 5]:
        outside = max(outside, length(w.p(b) - w0.p(b)) + _qdiff(w.q(b), w0.q(b)))
    s.check(outside < 1e-6, "pelvis and spine untouched")
    var bend = dot(w.p(2) - (w.p(1) + w.p(3)) * Real(0.5), _v(0, 0, 1))
    s.check(bend > 0, "knee bends toward the pole")

    # unreachable target
    var u = w0.copy()
    var far = u.p(1) + _v(0.3, -2.0, 0.5)
    var tu = two_bone_pose(u, parent, 1, 2, 3, far, u.p(2) + _v(0, 0, 1))
    var dir_far = (far - u.p(1)) * (1 / length(far - u.p(1)))
    var dir_end = (u.p(3) - u.p(1)) * (1 / length(u.p(3) - u.p(1)))
    s.check(not tu.reached, "unreachable target reported")
    s.almost(Float64(length(u.p(3) - u.p(1))), Float64(len1 + len2), "straight chain length l1 + l2", 1e-5)
    s.check(dot(dir_far, dir_end) > 1 - 1e-6, "chain points at the unreachable target")

    # shortest_arc
    var a = _v(1, 2, 3)
    var b = _v(-2, 0.5, 1)
    var r = shortest_arc(a, b)
    var ra = r.rotate(a) * (1 / length(a))
    s.check(length(ra - b * (1 / length(b))) < 1e-5, "shortest_arc takes a onto b")
    var ro = shortest_arc(a, a * Real(-3))
    s.check(length(ro.rotate(a) + a) < 1e-5, "shortest_arc on opposite vectors turns by pi")
    var rx = shortest_arc(_v(1, 0, 0), _v(-1, 0, 0))
    s.check(length(rx.rotate(_v(1, 0, 0)) - _v(-1, 0, 0)) < 1e-5, "opposite along x (the fallback axis)")
    var rz = shortest_arc(_v(0, 0, 0), b)
    s.check(_qdiff(rz, Quat.identity()) < 1e-6, "zero vector gives identity")
    var re = shortest_arc(a, a * Real(2))
    s.check(_qdiff(re, Quat.identity()) < 1e-6, "same direction gives identity")
    s.finish()
