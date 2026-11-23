# tier: integration
from std.math import sqrt
from harness.runner import Suite
from geometry.vec import Real, Vec3
from physics.rigid6 import Inertia3, QuatBody6
from physics.solver6 import ContactScene6, Joint6
from physics.serialize import scene_to_bytes

comptime DT: Real = 1.0 / 60.0
comptime G = Vec3(0, -9.8, 0, 0)


def _scene() raises -> ContactScene6[QuatBody6]:
    """4 separated 3-box towers + a ball-joint pendulum + a bouncy sphere:
    six independent islands exercising contacts, joints, restitution and
    every shape path."""
    var sc = ContactScene6[QuatBody6]()
    _ = sc.add(
        QuatBody6.at_rest(Vec3(0, -1, 0, 0), Inertia3.box(1, 30, 1, 30)),
        Vec3(30, 1, 30, 0),
        True,
    )
    var bi = Inertia3.box(2, 0.25, 0.25, 0.25)
    for t in range(4):
        var x = Real(t) * 4 - 6
        for i in range(3):
            _ = sc.add(
                QuatBody6.at_rest(Vec3(x, 0.3 + 0.52 * Real(i), 0, 0), bi),
                Vec3(0.25, 0.25, 0.25, 0),
                False,
            )
    var anchor = sc.add(
        QuatBody6.at_rest(Vec3(10, 2, 0, 0), Inertia3.box(1, 0.05, 0.05, 0.05)),
        Vec3(0.05, 0.05, 0.05, 0),
        True,
    ).index()
    var bob = sc.add(
        QuatBody6.at_rest(Vec3(10, 1, 0, 0), Inertia3.box(1, 0.15, 0.15, 0.15)),
        Vec3(0.15, 0.15, 0.15, 0),
        False,
    ).index()
    _ = sc.add_joint(Joint6.ball(anchor, bob, Vec3(0, 0, 0, 0), Vec3(0, 1, 0, 0)))
    sc.bset.bodies[bob].vel = Vec3(0.3, 0, 0, 0)
    var ball = sc.add_sphere(
        QuatBody6.at_rest(Vec3(-10, 1.3, 0, 0), Inertia3.sphere(2, 0.3)), 0.3, False
    ).index()
    sc.set_restitution(ball, 0.7)
    return sc^


def _same_bytes(a: List[UInt8], b: List[UInt8]) -> Bool:
    if len(a) != len(b):
        return False
    for i in range(len(a)):
        if a[i] != b[i]:
            return False
    return True


def _tiered(par: Bool) raises -> ContactScene6[QuatBody6]:
    """The same scene with a two-tier table (period 1 and 2) and every second
    body in tier 1, stepped 300 times."""
    var sc = _scene()
    var it = List[Int]()
    var su = List[Int]()
    var pe = List[Int]()
    for p in range(2):
        it.append(4)
        su.append(4)
        pe.append(p + 1)
    sc.set_tier_table(it, su, pe)
    var tiers = List[Int]()
    for i in range(len(sc.bset.bodies)):
        tiers.append(i % 2)
    sc.set_body_tiers(tiers)
    for _ in range(300):
        sc.step_soft(DT, G, parallel=par)
    return sc^


def main() raises:
    var s = Suite("islands_par")

    var ser = _scene()
    var par = _scene()
    for _ in range(400):
        ser.step_soft(DT, G)
        par.step_soft(DT, G, parallel=True)

    # 1. Bit-identical states across every body (the whole point: islands
    #    share nothing, so threading must not change a single bit).
    var same_pos = True
    var same_rot = True
    var same_sleep = True
    for i in range(len(ser.bset.bodies)):
        var dp = ser.bset.bodies[i].pos - par.bset.bodies[i].pos
        if dp[0] != 0 or dp[1] != 0 or dp[2] != 0:
            same_pos = False
            print("  pos mismatch body", i)
        if (
            ser.bset.bodies[i].q.x != par.bset.bodies[i].q.x
            or ser.bset.bodies[i].q.w != par.bset.bodies[i].q.w
        ):
            same_rot = False
        if ser.bset.sleeping[i] != par.bset.sleeping[i]:
            same_sleep = False
    s.check(same_pos, "parallel == serial positions (bit-identical)")
    s.check(same_rot, "parallel == serial rotations")
    s.check(same_sleep, "parallel == serial sleep states")

    # 2. The scene really is multi-island (the parallelism is real).
    print("  islands:", par.island_count())
    s.check(par.island_count() >= 5, "scene splits into many islands")

    # 3. Physics sanity on the parallel path: towers stand, sphere bounced.
    var ok = True
    for t in range(4):
        for i in range(3):
            var idx = 1 + t * 3 + i
            var y = Float64(par.bset.bodies[idx].position()[1])
            if abs(y - (0.25 + 0.5 * Float64(i))) > 0.02:
                ok = False
    s.check(ok, "all four towers stand under the parallel solver")

    # 4. WORKER-COUNT INVARIANCE. `workers` pins the fan-out width so the
    #    core-scaling curve can be swept; because the island partition is what
    #    makes the writes disjoint, the count changes only the schedule. Every
    #    width must reproduce the serial state bit-for-bit — otherwise a
    #    scaling curve would be comparing different computations per point.
    var widths = List[Int]()
    widths.append(1)
    widths.append(2)
    widths.append(3)
    widths.append(5)
    widths.append(8)
    widths.append(16)
    var all_same = True
    for wi in range(len(widths)):
        var w = widths[wi]
        var sc = _scene()
        for _ in range(400):
            sc.step_soft(DT, G, parallel=True, workers=w)
        for i in range(len(ser.bset.bodies)):
            var d = ser.bset.bodies[i].pos - sc.bset.bodies[i].pos
            if d[0] != 0 or d[1] != 0 or d[2] != 0:
                all_same = False
                print("  workers=", w, " pos mismatch body", i)
            if ser.bset.bodies[i].q.w != sc.bset.bodies[i].q.w:
                all_same = False
    s.check(all_same, "every worker count is bit-identical to serial")

    # 5. ROADMAP 17.100 item 6: the WHOLE state, contact cache included. The
    #    island path used to skip the held loads and the excess report and to
    #    drop pairs whose bodies were both asleep, so positions matched while
    #    the saved state (and the world hash) did not.
    var inert = 0
    for c in range(len(ser.cache)):
        if ser.bset.impulse_inert(ser.cache[c].a) and ser.bset.impulse_inert(ser.cache[c].b):
            inert += 1
    print("  pairs with both ends asleep or static:", inert, "of", len(ser.cache))
    s.check(inert > 0, "the scene has resting pairs no island owns")
    s.check(len(ser.cache) == len(par.cache), "parallel keeps every cached pair")
    s.check(_same_bytes(scene_to_bytes(ser), scene_to_bytes(par)), "parallel == serial serialized state (bit-identical)")

    # 6. Tiered islands through the dispatcher (17.100 item 6): bit-identical to
    #    the tiered serial loop.
    var ts = _tiered(False)
    var tp = _tiered(True)
    s.check(_same_bytes(scene_to_bytes(ts), scene_to_bytes(tp)), "tiered parallel == tiered serial serialized state")

    s.finish()
