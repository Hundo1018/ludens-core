# tier: integration
"""What the scene already had, through EmbedWorld (ROADMAP 17.97, step 2 batch A): overlap and sweep queries, convex
hulls, triangle meshes, heightfields, and joint limits, motors, springs and break thresholds.

  queries    overlap_sphere / overlap_box find the bodies they touch, and the mask leaves others out; sweep_sphere
             down onto the ground hits at the gap distance; a sweep that starts inside reports start_solid.
  hull       a cube given as 8 vertices settles on the ground at its half height; an off-centre hull's handle reports
             its centre of mass.
  mesh       a sphere dropped on a two-triangle floor and on a flat heightfield comes to rest one radius up; on a
             sloped heightfield it rolls downhill.
  joints     a hinged pendulum with limits [-0.2, 0.2] stays inside them; a velocity motor spins a wheel at its
             target; a heavy weight on a joint with a break threshold releases it.
  extreme    bad inputs raise and add nothing.
"""

from std.math import atan2, sqrt
from harness.runner import Suite
from geometry.vec import Real, Vec3
from geometry.quat import Quat
from embed.world import EmbedWorld


def _v(x: Real, y: Real, z: Real) -> Vec3:
    return Vec3(x, y, z, 0)


def _ground() raises -> EmbedWorld:
    var w = EmbedWorld(1.0 / 60.0, _v(0, -9.8, 0))
    _ = w.add_box(_v(0, -0.5, 0), _v(20, 0.5, 20), 0, True)
    return w^


def _run(mut w: EmbedWorld, n: Int) raises:
    for _ in range(n):
        _ = w.ticks_due(0.0)
        w.physics_tick()


def _has(hs: List[Int64], h: Int64) -> Bool:
    for x in hs:
        if x == h:
            return True
    return False


def main() raises:
    var s = Suite("embed_scene_native")

    # ---- queries
    var q = _ground()
    var a = q.add_box(_v(0, 1, 0), _v(0.5, 0.5, 0.5), 1, True)
    var b = q.add_box(_v(3, 1, 0), _v(0.5, 0.5, 0.5), 1, True)
    q.set_layer(b, 2, 0xFFFFFFFF)
    var near = q.overlap_sphere(_v(0.2, 1, 0), 0.6)
    s.check(_has(near, a) and not _has(near, b), "overlap_sphere at the first box finds it and not the second")
    var both = q.overlap_box(_v(1.5, 1, 0), _v(2, 0.25, 0.25), Quat.identity())
    s.check(_has(both, a) and _has(both, b), "a long box between them overlaps both")
    var masked = q.overlap_box(_v(1.5, 1, 0), _v(2, 0.25, 0.25), Quat.identity(), 2)
    s.check(not _has(masked, a) and _has(masked, b), "mask 2 keeps only the category-2 box")
    var turned = q.overlap_box(_v(1.5, 1, 0), _v(2, 0.25, 0.25), Quat(0, 0.70710678, 0, 0.70710678))
    s.check(not _has(turned, a) and not _has(turned, b), "the same box turned 90 degrees about y misses both")
    var sw = q.sweep_sphere(_v(-5, 5, 0), 0.5, _v(0, -1, 0), 10)
    s.check(sw.body >= 0 and abs(sw.t - 4.5) < 1e-3 and sw.normal[1] > 0.99,
            "sweep_sphere r 0.5 from y 5 down hits the ground at t 4.5 (" + String(sw.t) + ")")
    var miss = q.sweep_sphere(_v(-5, 5, 0), 0.5, _v(0, 1, 0), 10)
    s.check(miss.body == -1, "sweeping up hits nothing")
    var inside = q.sweep_box(_v(0, 1, 0), _v(0.1, 0.1, 0.1), Quat.identity(), _v(1, 0, 0), 1)
    s.check(inside.body == a and inside.start_solid and inside.t == 0, "a sweep that starts inside the box reports start_solid at t 0")

    # ---- convex hull
    var hw = _ground()
    var cube = List[Vec3]()
    for i in range(8):
        cube.append(_v(-0.5 + Real(i & 1), -0.5 + Real((i >> 1) & 1), -0.5 + Real((i >> 2) & 1)))
    var hc = hw.add_hull(_v(0, 2, 0), cube, 1, False)
    _run(hw, 180)
    var hy = hw.state(hc).pos[1]
    s.check(abs(hy - 0.5) < 0.02, "a cube hull settles at its half height 0.5 (" + String(hy) + ")")
    var wedge = List[Vec3]()
    for p in [_v(0, 0, 0), _v(1, 0, 0), _v(0, 1, 0), _v(0, 0, 1)]:
        wedge.append(p)
    var hw2 = _ground()
    var ht = hw2.add_hull(_v(0, 3, 0), wedge, 1, True)
    var com = hw2.state(ht).pos
    s.check(abs(com[0] - 0.25) < 1e-4 and abs(com[1] - 3.25) < 1e-4 and abs(com[2] - 0.25) < 1e-4,
            "a tetrahedron hull's handle reports its centre of mass (0.25, 3.25, 0.25)")

    # ---- triangle mesh and heightfield
    var mw = EmbedWorld(1.0 / 60.0, _v(0, -9.8, 0))
    var floor = List[Vec3]()
    for p in [_v(-10, 0, -10), _v(10, 0, -10), _v(10, 0, 10), _v(-10, 0, 10)]:
        floor.append(p)
    var tris: List[Int] = [0, 2, 1, 0, 3, 2]
    _ = mw.add_trimesh(_v(0, 0, 0), floor, tris)
    var ball = mw.add_sphere(_v(0, 2, 0), 0.5, 1, False)
    _run(mw, 180)
    var my = mw.state(ball).pos[1]
    s.check(abs(my - 0.5) < 0.02, "a sphere on a two-triangle floor rests one radius up (" + String(my) + ")")

    var fw = EmbedWorld(1.0 / 60.0, _v(0, -9.8, 0))
    var flat = List[Real](length=21 * 21, fill=Real(0))
    _ = fw.add_heightfield(flat, 21, 21, 1, -10, -10)
    var fb = fw.add_sphere(_v(0, 2, 0), 0.5, 1, False)
    _run(fw, 180)
    var fy = fw.state(fb).pos[1]
    s.check(abs(fy - 0.5) < 0.02, "a sphere on a flat heightfield rests one radius up (" + String(fy) + ")")

    var sl = EmbedWorld(1.0 / 60.0, _v(0, -9.8, 0))
    var slope = List[Real]()
    for _ in range(21):
        for i in range(21):
            slope.append(Real(20 - i) * 0.2)  # falls by 0.2 per metre towards +x
    _ = sl.add_heightfield(slope, 21, 21, 1, -10, -10)
    var sb = sl.add_sphere(_v(0, 3, 0), 0.5, 1, False)
    _run(sl, 120)
    var sx = sl.state(sb).pos[0]
    s.check(sx > 0.5, "a sphere on a heightfield that falls towards +x rolls that way (x " + String(sx) + ")")

    # ---- joints: limits, motor, break
    var jw = EmbedWorld(1.0 / 60.0, _v(0, -9.8, 0))
    var pivot = jw.add_box(_v(0, 5, 0), _v(0.1, 0.1, 0.1), 1, True)
    var arm = jw.add_box(_v(1, 5, 0), _v(0.5, 0.1, 0.1), 1, False)
    var hinge = jw.add_hinge_joint(pivot, arm, _v(0, 0, 0), _v(-1, 0, 0), _v(0, 0, 1))
    jw.set_joint_limits(hinge, -0.2, 0.2)
    var worst = Real(0)
    for _ in range(120):
        _run(jw, 1)
        var r = jw.state(arm).rot
        worst = max(worst, abs(2 * atan2(r.z, r.w)))
    s.check(worst < 0.25, "a limited pendulum released level stays within [-0.2, 0.2] rad (worst " + String(worst) + ")")

    var mo = EmbedWorld(1.0 / 60.0, _v(0, 0, 0))
    var axle = mo.add_box(_v(0, 0, -1), _v(0.1, 0.1, 0.1), 1, True)  # beside the wheel, so their colliders do not touch
    var wheel = mo.add_box(_v(0, 0, 0), _v(0.5, 0.5, 0.1), 1, False)
    var mj = mo.add_hinge_joint(axle, wheel, _v(0, 0, 1), _v(0, 0, 0), _v(0, 0, 1))
    mo.set_joint_motor(mj, 1, 2, 100)
    _run(mo, 60)
    var spin = mo.state(wheel).omega[2]
    s.check(abs(abs(spin) - 2) < 0.05, "a velocity motor spins the wheel at its 2 rad/s target (" + String(spin) + ")")

    var sleepy = EmbedWorld(1.0 / 60.0, _v(0, 0, 0))
    var axle2 = sleepy.add_box(_v(0, 0, -1), _v(0.1, 0.1, 0.1), 1, True)
    var wheel2 = sleepy.add_box(_v(0, 0, 0), _v(0.5, 0.5, 0.1), 1, False)
    var mj2 = sleepy.add_hinge_joint(axle2, wheel2, _v(0, 0, 1), _v(0, 0, 0), _v(0, 0, 1))
    _run(sleepy, 240)
    var slept = sleepy.is_sleeping(wheel2)
    sleepy.set_joint_motor(mj2, 1, 2, 100)
    _run(sleepy, 60)
    var spin2 = sleepy.state(wheel2).omega[2]
    s.check(slept and abs(abs(spin2) - 2) < 0.05,
            "a motor set on a wheel that has fallen asleep wakes it and spins it at 2 rad/s (asleep " + String(slept) + ", " + String(spin2) + ")")

    var bw = EmbedWorld(1.0 / 60.0, _v(0, -9.8, 0))
    var hook = bw.add_box(_v(0, 5, 0), _v(0.1, 0.1, 0.1), 1, True)
    var load = bw.add_box(_v(0, 4, 0), _v(0.3, 0.3, 0.3), 50, False)
    var bj = bw.add_ball_joint(hook, load, _v(0, -0.5, 0), _v(0, 0.5, 0))
    bw.set_joint_break(bj, 100, 100)
    var released = False
    for _ in range(30):
        _run(bw, 1)
        for k in bw.released_joints():
            released = released or k == bj
    s.check(released and bw.state(load).pos[1] < 3.5, "a 50 kg load on a joint that breaks at 100 N releases it and falls")

    # ---- extreme
    var xw = _ground()
    var n0 = len(xw.bodies())
    var errs = 0
    try:
        _ = xw.overlap_sphere(_v(0, 0, 0), -1)
    except:
        errs += 1
    try:
        _ = xw.sweep_sphere(_v(0, 0, 0), 0.5, _v(0, 0, 0), 1)
    except:
        errs += 1
    try:
        _ = xw.overlap_box(_v(0, 0, 0), _v(1, 1, 1), Quat(0, 0, 0, 0))
    except:
        errs += 1
    var flat3 = List[Vec3]()
    for p in [_v(0, 0, 0), _v(1, 0, 0), _v(0, 1, 0), _v(1, 1, 0)]:
        flat3.append(p)
    try:
        _ = xw.add_hull(_v(0, 1, 0), flat3, 1, False)
    except:
        errs += 1
    var bad_tris: List[Int] = [0, 1, 9]
    try:
        _ = xw.add_trimesh(_v(0, 0, 0), floor, bad_tris)
    except:
        errs += 1
    try:
        _ = xw.add_heightfield(flat, 21, 20, 1, 0, 0)
    except:
        errs += 1
    try:
        xw.set_joint_limits(5, 0, 1)
    except:
        errs += 1
    s.check(errs == 7 and len(xw.bodies()) == n0,
            "negative radius, zero direction, zero quaternion, flat hull, bad index, wrong height count, unknown joint raise; nothing added")
    s.finish()
