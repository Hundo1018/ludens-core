# tier: integration
"""Joint loads reported to the host (ROADMAP 17.19 deferred clause "joint torque in events"; ludens-engine #92).

- a mass of 2 kg hanging from a ball joint reads m g = 19.62 N after it settles; a weld holding the same mass with its centre
  1 m to the side of the anchor point reads m g in force and m g * 1 = 19.62 N m in torque;
- turning load tracking on does not change the simulation (same world hash after 300 ticks);
- with tracking off `joint_load` is (0, 0);
- a joint whose break threshold the load exceeds is listed in `released_joints` the tick it breaks;
- an index out of range is refused.
Times are not printed (the golden compares this output)."""
from harness.runner import Suite
from embed.world import EmbedWorld
from geometry.vec import Real, Vec3
from physics.joints6 import Joint6

comptime DT = 1.0 / 60.0


def hanging(track: Bool) raises -> EmbedWorld:
    var w = EmbedWorld(DT, Vec3(0.0, -9.81, 0.0, 0.0))
    var a = w.add_box(Vec3(0.0, 5.0, 0.0, 0.0), Vec3(0.5, 0.5, 0.5, 0.0), 0.0, True)
    var b = w.add_box(Vec3(0.0, 3.0, 0.0, 0.0), Vec3(0.3, 0.3, 0.3, 0.0), 2.0, False)
    _ = w.scene.add_joint(Joint6.ball(0, 1, Vec3(0.0, 0.0, 0.0, 0.0), Vec3(0.0, 2.0, 0.0, 0.0)))
    _ = a
    _ = b
    w.track_joint_loads(track)
    return w^


def sideways(track: Bool) raises -> EmbedWorld:
    var w = EmbedWorld(DT, Vec3(0.0, -9.81, 0.0, 0.0))
    _ = w.add_box(Vec3(0.0, 5.0, 0.0, 0.0), Vec3(0.5, 0.5, 0.5, 0.0), 0.0, True)
    _ = w.add_box(Vec3(1.5, 5.0, 0.0, 0.0), Vec3(0.3, 0.3, 0.3, 0.0), 2.0, False)
    var rel = w.scene.bset.bodies[0].rotation().conjugate() * w.scene.bset.bodies[1].rotation()
    _ = w.scene.add_joint(Joint6.weld(0, 1, Vec3(0.5, 0.0, 0.0, 0.0), Vec3(-1.0, 0.0, 0.0, 0.0), rel))
    w.track_joint_loads(track)
    return w^


def run_ticks(mut w: EmbedWorld, n: Int) raises:
    for _ in range(n):
        for _ in range(w.ticks_due(DT)):
            w.physics_tick()


def close(a: Real, b: Real, rel: Real) -> Bool:
    var d = a - b
    return (d if d >= 0 else -d) <= rel * (b if b >= 0 else -b)


def main() raises:
    var s = Suite("joint_loads")
    var w = hanging(True)
    var before = w.joint_load(0)
    s.check(before[0] == 0 and before[1] == 0, "before the first step the load is (0, 0)")
    run_ticks(w, 300)
    var l = w.joint_load(0)
    s.check(close(l[0], 19.62, 0.03), "hanging 2 kg: force " + String(l[0]) + " N, expected 19.62")
    s.check(l[1] < 0.5, "hanging 2 kg: torque " + String(l[1]) + " N m is small")

    var sw = sideways(True)
    run_ticks(sw, 300)
    var ls = sw.joint_load(0)
    s.check(close(ls[0], 19.62, 0.05), "weld holding 2 kg 1 m from its anchor: force " + String(ls[0]) + " N, expected 19.62")
    s.check(close(ls[1], 19.62, 0.05), "...torque " + String(ls[1]) + " N m, expected 19.62 (lever arm 1 m)")

    var off = hanging(False)
    run_ticks(off, 300)
    var lo = off.joint_load(0)
    s.check(lo[0] == 0 and lo[1] == 0, "tracking off: (0, 0)")
    var on = hanging(True)
    run_ticks(on, 300)
    s.check(on.hash() == off.hash(), "tracking on does not change the simulation (same hash after 300 ticks)")

    var br = sideways(True)
    br.scene.set_joint_break(0, 10.0, 1.0e9)
    run_ticks(br, 120)
    s.check(br.scene.joints[0].kind == 3, "a load over the threshold released the joint")
    var after_break = sideways(True)
    after_break.scene.set_joint_break(0, 10.0, 1.0e9)
    var seen = False
    for _ in range(120):
        for _ in range(after_break.ticks_due(DT)):
            after_break.physics_tick()
            if len(after_break.released_joints()) > 0:
                seen = True
    s.check(seen, "released_joints listed the joint on the tick it broke")

    var raised = False
    try:
        _ = w.joint_load(9)
    except:
        raised = True
    s.check(raised, "a joint index out of range is refused")
    s.finish()
