# tier: integration
from std.math import sqrt
from harness.runner import Suite
from geometry.vec import Real, Vec3
from collision.manifold import Axes3
from collision.toi import swept_box_toi
from physics.rigid6 import Inertia3, QuatBody6
from physics.solver6 import ContactScene6
from physics.solver_config import SolverConfig
from physics.ccd6 import CCD_BULLET

comptime DT: Real = 1.0 / 60.0


def _len(v: Vec3) -> Float64:
    return Float64(sqrt(v[0] * v[0] + v[1] * v[1] + v[2] * v[2]))


def _id_axes() -> Axes3:
    var a = Axes3(fill=Vec3(0, 0, 0, 0))
    a[0] = Vec3(1, 0, 0, 0)
    a[1] = Vec3(0, 1, 0, 0)
    a[2] = Vec3(0, 0, 1, 0)
    return a^


def _rotz45_axes() -> Axes3:
    comptime C: Real = 0.7071067811865476
    var a = Axes3(fill=Vec3(0, 0, 0, 0))
    a[0] = Vec3(C, C, 0, 0)
    a[1] = Vec3(-C, C, 0, 0)
    a[2] = Vec3(0, 0, 1, 0)
    return a^


def main() raises:
    var s = Suite("ccd6")

    # 1. Bullet vs thin wall: 50 m/s covers 0.83 m per frame — far more than
    #    the 0.15 m combined thickness. Speculative margin must stop it AT the
    #    surface instead of tunnelling (no gravity, isolate the mechanism).
    var sc = ContactScene6[QuatBody6]()
    _ = sc.add(
        QuatBody6.at_rest(Vec3(0, 0, 0, 0), Inertia3.box(1, 0.05, 2, 2)),
        Vec3(0.05, 2, 2, 0),
        True,
    )
    var bullet = QuatBody6.at_rest(
        Vec3(-2.5, 0, 0, 0), Inertia3.box(1, 0.1, 0.1, 0.1)
    )
    bullet.vel = Vec3(50, 0, 0, 0)
    _ = sc.add(bullet, Vec3(0.1, 0.1, 0.1, 0), False)
    var max_x = Float64(-1e30)
    for _ in range(60):
        sc.step_soft(DT, Vec3(0, 0, 0, 0))
        var x = Float64(sc.bset.bodies[1].position()[0])
        if x > max_x:
            max_x = x
    var final_x = Float64(sc.bset.bodies[1].position()[0])
    print(
        "  bullet: max x =", max_x, "final x =", final_x,
        "final vx =", sc.bset.bodies[1].vel[0],
    )
    # Speculative-margin guarantees (Box2D-grade first-stage CCD): the bullet
    # may transiently overlap the wall band but must never tunnel through the
    # midplane, and must end up expelled to the surface with bounded speed.
    # (A true swept/TOI pass — Jolt LinearCast — is the follow-up refinement.)
    s.check(max_x < 0.0, "bullet never crosses the wall midplane")
    s.check(final_x < -0.14, "bullet ends outside the wall")
    s.check(
        abs(Float64(sc.bset.bodies[1].vel[0])) < 5.0,
        "bullet speed collapsed (50 -> <5 m/s, e=0 grade)",
    )

    # 2. Same bullet WITHOUT stepping soft margin would tunnel — sanity-check
    #    the test itself: one 0.83 m step jumps clean over the 0.15 m band.
    s.check(50.0 * Float64(DT) > 0.3, "test premise: per-frame travel >> wall")

    # 3. Non-regression: the speculative margin must not levitate a resting
    #    box or change its rest height.
    var one = ContactScene6[QuatBody6]()
    _ = one.add(
        QuatBody6.at_rest(Vec3(0, -1, 0, 0), Inertia3.box(1, 10, 1, 10)),
        Vec3(10, 1, 10, 0),
        True,
    )
    _ = one.add(
        QuatBody6.at_rest(Vec3(0, 0.3, 0, 0), Inertia3.box(2, 0.25, 0.25, 0.25)),
        Vec3(0.25, 0.25, 0.25, 0),
        False,
    )
    for _ in range(300):
        one.step_soft(DT, Vec3(0, -9.8, 0, 0))
    var y = Float64(one.bset.bodies[1].position()[1])
    print("  rest height with speculative margin:", y)
    s.check(abs(y - 0.25) < 0.005, "rest height unchanged by margin")
    s.check(_len(one.bset.bodies[1].vel) < 1e-3, "resting box still rests")

    # 4. A moderately fast drop lands without deep penetration or bounce:
    #    speculative contact catches it at the surface.
    var drop = ContactScene6[QuatBody6]()
    _ = drop.add(
        QuatBody6.at_rest(Vec3(0, -1, 0, 0), Inertia3.box(1, 10, 1, 10)),
        Vec3(10, 1, 10, 0),
        True,
    )
    var fast = QuatBody6.at_rest(
        Vec3(0, 3, 0, 0), Inertia3.box(2, 0.25, 0.25, 0.25)
    )
    fast.vel = Vec3(0, -20, 0, 0)  # 0.33 m per frame
    _ = drop.add(fast, Vec3(0.25, 0.25, 0.25, 0), False)
    var min_y = Float64(1e30)
    for _ in range(120):
        drop.step_soft(DT, Vec3(0, -9.8, 0, 0))
        var yy = Float64(drop.bset.bodies[1].position()[1])
        if yy < min_y:
            min_y = yy
    print("  fast drop: min y =", min_y)
    s.check(min_y > 0.2, "fast drop never sinks deep")
    s.check(
        abs(Float64(drop.bset.bodies[1].position()[1]) - 0.25) < 0.01,
        "fast drop settles at the surface",
    )

    # ---- swept/TOI second stage (4.1a) ----

    # 5. swept_box_toi against analytic times: unit cubes head-on, the gap
    #    between surfaces is 1.0 and the sweep covers 4.0 -> t = 0.25 exactly.
    var idax = _id_axes()
    var r_head = swept_box_toi(
        Vec3(0, 0, 0, 0), idax, Vec3(0.5, 0.5, 0.5, 0),
        Vec3(-2, 0, 0, 0), idax, Vec3(0.5, 0.5, 0.5, 0),
        Vec3(4, 0, 0, 0),
    )
    s.check(r_head.hit, "toi: head-on hits")
    s.almost(Float64(r_head.t), 0.25, "toi: head-on exact time", 1e-6)

    # 6. Offset flyby misses; started-overlapping reports t = 0.
    var r_miss = swept_box_toi(
        Vec3(0, 0, 0, 0), idax, Vec3(0.5, 0.5, 0.5, 0),
        Vec3(-2, 2, 0, 0), idax, Vec3(0.5, 0.5, 0.5, 0),
        Vec3(4, 0, 0, 0),
    )
    s.check(not r_miss.hit, "toi: offset flyby misses")
    var r_over = swept_box_toi(
        Vec3(0, 0, 0, 0), idax, Vec3(0.5, 0.5, 0.5, 0),
        Vec3(-0.5, 0, 0, 0), idax, Vec3(0.5, 0.5, 0.5, 0),
        Vec3(4, 0, 0, 0),
    )
    s.check(r_over.hit and r_over.t == 0, "toi: overlapping starts at t = 0")

    # 7. Rotated target (45 deg about z): projection radius grows to
    #    0.5*(cos45+sin45) = 0.70711, so contact is at center gap 1.20711.
    var r_rot = swept_box_toi(
        Vec3(0, 0, 0, 0), idax, Vec3(0.5, 0.5, 0.5, 0),
        Vec3(-3, 0, 0, 0), _rotz45_axes(), Vec3(0.5, 0.5, 0.5, 0),
        Vec3(4, 0, 0, 0),
    )
    s.check(r_rot.hit, "toi: rotated target hits")
    s.almost(Float64(r_rot.t), (3.0 - 1.2071067811865476) / 4.0,
             "toi: rotated target analytic time", 1e-5)

    # 8. Role symmetry: casting a against b with the negated displacement
    #    gives the same time (the relative sweep is one event).
    var r_sym = swept_box_toi(
        Vec3(-3, 0, 0, 0), _rotz45_axes(), Vec3(0.5, 0.5, 0.5, 0),
        Vec3(0, 0, 0, 0), idax, Vec3(0.5, 0.5, 0.5, 0),
        Vec3(-4, 0, 0, 0),
    )
    s.almost(Float64(r_sym.t), Float64(r_rot.t), "toi: symmetric roles", 1e-6)

    # 9. ZERO overshoot: the same 50 m/s bullet with the TOI stage may never
    #    cross the wall SURFACE (bullet center x = -0.15), not just the
    #    midplane — speculative-only transiently overshot ~8.5 cm here.
    var sw = ContactScene6[QuatBody6]()
    _ = sw.add(
        QuatBody6.at_rest(Vec3(0, 0, 0, 0), Inertia3.box(1, 0.05, 2, 2)),
        Vec3(0.05, 2, 2, 0),
        True,
    )
    var b2 = QuatBody6.at_rest(
        Vec3(-2.5, 0, 0, 0), Inertia3.box(1, 0.1, 0.1, 0.1)
    )
    b2.vel = Vec3(50, 0, 0, 0)
    _ = sw.add(b2, Vec3(0.1, 0.1, 0.1, 0), False)
    var max_sx = Float64(-1e30)
    for _ in range(60):
        sw.step_soft(DT, Vec3(0, 0, 0, 0), ccd=True)
        var x = Float64(sw.bset.bodies[1].position()[0])
        if x > max_sx:
            max_sx = x
    print(
        "  swept bullet: max x =", max_sx,
        "final vx =", sw.bset.bodies[1].vel[0],
    )
    s.check(max_sx <= -0.145, "swept: zero overshoot past the wall surface")
    s.check(max_sx > -0.30, "swept: bullet actually reached the wall")
    # Bias/warm-start energy gives a small rebound (the speculative-only
    # scenario above rebounds at ~4.3 m/s); the TOI stage must not be worse.
    s.check(
        abs(Float64(sw.bset.bodies[1].vel[0])) < 3.0,
        "swept: bullet speed collapsed (50 -> <3 m/s)",
    )

    # 10. Non-regression with ccd on: slow bodies take the bit-identical plain
    #     pose step, so rest height and the moderate-speed drop are unchanged.
    var one2 = ContactScene6[QuatBody6]()
    _ = one2.add(
        QuatBody6.at_rest(Vec3(0, -1, 0, 0), Inertia3.box(1, 10, 1, 10)),
        Vec3(10, 1, 10, 0),
        True,
    )
    _ = one2.add(
        QuatBody6.at_rest(Vec3(0, 0.3, 0, 0), Inertia3.box(2, 0.25, 0.25, 0.25)),
        Vec3(0.25, 0.25, 0.25, 0),
        False,
    )
    for _ in range(300):
        one2.step_soft(DT, Vec3(0, -9.8, 0, 0), ccd=True)
    var y2 = Float64(one2.bset.bodies[1].position()[1])
    print("  rest height with TOI stage:", y2)
    s.check(abs(y2 - 0.25) < 0.005, "swept: rest height unchanged")
    s.almost(y2, y, "swept: parity with speculative-only rest height", 1e-6)

    # Touching at t = 0 (ROADMAP 17.19): a bullet resting against a wall
    # and sliding along it, or leaving it, is no hit; moving deeper is.
    var ia = _id_axes()
    var touch = Vec3(0.3, 0, 0, 0)  # 0.25 + 0.05: face to face on x
    var slide = swept_box_toi(Vec3(0, 0, 0, 0), ia, Vec3(0.25, 1, 0.25, 0), touch, ia, Vec3(0.05, 0.05, 0.05, 0), Vec3(0, -0.2, 0, 0))
    var leave = swept_box_toi(Vec3(0, 0, 0, 0), ia, Vec3(0.25, 1, 0.25, 0), touch, ia, Vec3(0.05, 0.05, 0.05, 0), Vec3(0.2, 0, 0, 0))
    var into = swept_box_toi(Vec3(0, 0, 0, 0), ia, Vec3(0.25, 1, 0.25, 0), touch, ia, Vec3(0.05, 0.05, 0.05, 0), Vec3(-0.2, 0, 0, 0))
    print("touching at t=0: slide hit", slide.hit, " leave hit", leave.hit, " into hit", into.hit, "t", into.t)
    s.check(not slide.hit and not leave.hit and into.hit and into.t == 0, "touching: sliding or leaving is no hit, moving deeper is t = 0")
    var wall = ContactScene6[QuatBody6]()
    _ = wall.add(QuatBody6.at_rest(Vec3(0, -0.5, 0, 0), Inertia3.box(1, 20, 0.5, 20)), Vec3(20, 0.5, 20, 0), True)
    _ = wall.add(QuatBody6.at_rest(Vec3(0, 1, 0, 0), Inertia3.box(1, 0.25, 1, 0.25)), Vec3(0.25, 1, 0.25, 0), True)
    var bl = wall.add(QuatBody6.at_rest(Vec3(-0.3, 1.5, 0, 0), Inertia3.box(0.2, 0.05, 0.05, 0.05)), Vec3(0.05, 0.05, 0.05, 0), False)
    wall.set_ccd_mode(bl, CCD_BULLET)
    var wcfg = SolverConfig()
    for _ in range(60):
        wall.step(DT, Vec3(0, -9.8, 0, 0), wcfg)
    print("bullet released touching a wall, after 1 s: y", wall.pose(bl).pos[1])
    s.check(abs(wall.pose(bl).pos[1] - 0.05) < 0.01, "a CCD bullet touching a wall falls to the floor (was frozen at y 1.5)")
    # A spinning CCD bullet landing: the swept box sees only the linear
    # travel, so clamping it would also freeze the rotation that the
    # contact uses to settle; it must come to rest (17.19).
    var spin = ContactScene6[QuatBody6]()
    _ = spin.add(QuatBody6.at_rest(Vec3(0, -0.5, 0, 0), Inertia3.box(1, 50, 0.5, 50)), Vec3(50, 0.5, 50, 0), True)
    var sb = QuatBody6.at_rest(Vec3(0, 0.3, 0, 0), Inertia3.box(0.2, 0.05, 0.05, 0.05))
    sb.set_velocity(Vec3(0.3, -1, 0.5, 0), Vec3(5, 3, 40, 0))
    var sbi = spin.add(sb^, Vec3(0.05, 0.05, 0.05, 0), False)
    spin.set_ccd_mode(sbi, CCD_BULLET)
    var scfg = SolverConfig()
    scfg.ccd = True
    var slept_at = -1
    for k in range(300):
        spin.step(DT, Vec3(0, -9.8, 0, 0), scfg)
        if slept_at < 0 and spin.is_sleeping(sbi):
            slept_at = k
    print("spinning CCD bullet dropped on the floor: asleep at step", slept_at, " y", spin.pose(sbi).pos[1])
    s.check(slept_at >= 0 and abs(spin.pose(sbi).pos[1] - 0.05) < 0.005, "a spinning CCD bullet settles on the floor (was stuck above it)")
    s.finish()
