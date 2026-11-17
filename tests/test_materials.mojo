# tier: integration
"""ROADMAP 17.23 (per-body materials + per-pair combine modes). Ordinary:
each combine mode's raw arithmetic, including the PhysX "higher mode wins"
pair rule. Integration/extreme: parity (all four modes agree when both
bodies' coefficients AND combine modes are equal -- a fixed point of every
formula, so the four runs must be bit-identical, not just similar) and
ice-on-rubber slide distances ordered by combined friction."""
from harness.runner import Suite
from geometry.vec import Real, Vec3
from physics.rigid6 import Inertia3, QuatBody6
from physics.solver6 import ContactScene6
from physics.material import combine, COMBINE_AVERAGE, COMBINE_MIN, COMBINE_MULTIPLY, COMBINE_MAX

comptime DT: Real = 1.0 / 60.0
comptime G = Vec3(0, -9.8, 0, 0)


def _slide_scene(f_ground: Real, f_box: Real, mode: Int) raises -> ContactScene6[QuatBody6]:
    var sc = ContactScene6[QuatBody6]()
    var ground = sc.add(
        QuatBody6.at_rest(Vec3(0, -0.5, 0, 0), Inertia3.box(1, 50, 0.5, 5)),
        Vec3(50, 0.5, 5, 0),
        True,
    )
    sc.set_friction(ground.index(), f_ground)
    sc.set_friction_combine(ground.index(), mode)
    var box = sc.add(
        QuatBody6.at_rest(Vec3(0, 0.25, 0, 0), Inertia3.box(1, 0.25, 0.25, 0.25)),
        Vec3(0.25, 0.25, 0.25, 0),
        False,
    )
    sc.set_friction(box.index(), f_box)
    sc.set_friction_combine(box.index(), mode)
    sc.bset.bodies[box.index()].vel = Vec3(4, 0, 0, 0)
    return sc^


def _slide_distance(f_ground: Real, f_box: Real, mode: Int, steps: Int) raises -> Float64:
    var sc = _slide_scene(f_ground, f_box, mode)
    var x0 = Float64(sc.bset.bodies[1].pos[0])
    for _ in range(steps):
        sc.step_soft(DT, G)
    return Float64(sc.bset.bodies[1].pos[0]) - x0


def main() raises:
    var s = Suite("materials")

    # 1. Ordinary: each mode's raw arithmetic on a pair (0.2, 0.8), plus the
    #    PhysX pair rule -- when the two bodies disagree, the HIGHER-valued
    #    mode decides, regardless of which body (a or b) it came from.
    s.check(combine(0.2, 0.8, COMBINE_MIN, COMBINE_MIN) == 0.2, "MIN(0.2, 0.8) == 0.2")
    s.check(combine(0.2, 0.8, COMBINE_MAX, COMBINE_MAX) == 0.8, "MAX(0.2, 0.8) == 0.8")
    s.check(
        abs(Float64(combine(0.2, 0.8, COMBINE_MULTIPLY, COMBINE_MULTIPLY)) - 0.16) < 1e-6,
        "MULTIPLY(0.2, 0.8) == 0.16",
    )
    s.check(
        abs(Float64(combine(0.2, 0.8, COMBINE_AVERAGE, COMBINE_AVERAGE)) - 0.5) < 1e-6,
        "AVERAGE(0.2, 0.8) == 0.5",
    )
    s.check(
        combine(0.2, 0.8, COMBINE_AVERAGE, COMBINE_MAX) == 0.8,
        "disagreement: a=AVERAGE, b=MAX -> MAX wins (higher mode)",
    )
    s.check(
        abs(Float64(combine(0.2, 0.8, COMBINE_MULTIPLY, COMBINE_MIN)) - 0.16) < 1e-6,
        "disagreement: a=MULTIPLY, b=MIN -> MULTIPLY wins (higher mode)",
    )
    s.check(
        combine(0.2, 0.8, COMBINE_MAX, COMBINE_AVERAGE)
        == combine(0.2, 0.8, COMBINE_AVERAGE, COMBINE_MAX),
        "pair rule is symmetric in which body supplies the winning mode",
    )

    # 2. Identity: the default per-body state (never called set_friction /
    #    set_friction_combine) reproduces today's single shared `mu` --
    #    `combine(mu, mu, AVERAGE, AVERAGE) == mu` bit-exactly.
    var mu_default: Real = 0.5
    s.check(
        combine(mu_default, mu_default, COMBINE_AVERAGE, COMBINE_AVERAGE) == mu_default,
        "AVERAGE of two equal unset-default coefficients is bit-exact (identity gate)",
    )

    # 3. Parity: all four modes agree when both bodies' coefficient AND
    #    combine mode are equal to 1.0 -- a genuine fixed point of every
    #    formula (1*1==1==min(1,1)==max(1,1)==(1+1)*0.5), so the four
    #    simulated runs use the EXACT SAME pair_mu every step and must come
    #    out bit-identical, not merely close.
    var modes = [COMBINE_AVERAGE, COMBINE_MIN, COMBINE_MULTIPLY, COMBINE_MAX]
    var x_ref = Float64(0)
    var all_parity = True
    for mi in range(4):
        var d = _slide_distance(1.0, 1.0, modes[mi], 60)
        if mi == 0:
            x_ref = d
        elif d != x_ref:
            all_parity = False
    s.check(all_parity, "all 4 combine modes bit-identical when both coefficients == 1.0")

    # 4. Extreme/ordinary: ice-on-rubber slide distances ordered by the
    #    COMBINED friction each mode produces (not hardcoded -- computed
    #    the same way the solver does, via `combine`). For any two
    #    coefficients both in [0, 1], MULTIPLY <= MIN <= AVERAGE <= MAX
    #    always (a*b <= min(a,b) <= (a+b)/2 <= max(a,b)), so slide distance
    #    should be monotonically non-increasing in that same order.
    comptime F_ICE: Real = 0.05
    comptime F_RUBBER: Real = 0.8
    var mu_avg = combine(F_ICE, F_RUBBER, COMBINE_AVERAGE, COMBINE_AVERAGE)
    var mu_min = combine(F_ICE, F_RUBBER, COMBINE_MIN, COMBINE_MIN)
    var mu_mul = combine(F_ICE, F_RUBBER, COMBINE_MULTIPLY, COMBINE_MULTIPLY)
    var mu_max = combine(F_ICE, F_RUBBER, COMBINE_MAX, COMBINE_MAX)
    s.check(
        mu_mul <= mu_min and mu_min <= mu_avg and mu_avg <= mu_max,
        "combined mu ordering: MULTIPLY <= MIN <= AVERAGE <= MAX for coefficients in [0,1]",
    )
    var d_avg = _slide_distance(F_ICE, F_RUBBER, COMBINE_AVERAGE, 60)
    var d_min = _slide_distance(F_ICE, F_RUBBER, COMBINE_MIN, 60)
    var d_mul = _slide_distance(F_ICE, F_RUBBER, COMBINE_MULTIPLY, 60)
    var d_max = _slide_distance(F_ICE, F_RUBBER, COMBINE_MAX, 60)
    print("  slide distances -- multiply:", d_mul, " min:", d_min, " average:", d_avg, " max:", d_max)
    s.check(d_mul >= d_min, "lower combined mu (MULTIPLY) slides at least as far as MIN")
    s.check(d_min >= d_avg, "MIN slides at least as far as AVERAGE")
    s.check(d_avg >= d_max, "AVERAGE slides at least as far as MAX (highest combined mu, shortest slide)")
    s.check(d_max < d_mul, "the highest- and lowest-friction pairings are clearly distinguishable")

    # 5. Extreme: restitution combine defaults to MAX -- a lively ball
    #    resting on a dead-default floor bounces (per today's hardcoded
    #    `max(a, b)` behaviour, now via `combine` with the default per-body
    #    `restitution_combine`).
    var scr = ContactScene6[QuatBody6]()
    var floor_r = scr.add(
        QuatBody6.at_rest(Vec3(0, -0.5, 0, 0), Inertia3.box(1, 20, 0.5, 20)),
        Vec3(20, 0.5, 20, 0),
        True,
    )
    var ball_r = scr.add_sphere(
        QuatBody6.at_rest(Vec3(0, 3, 0, 0), Inertia3.sphere(1, 0.3)), 0.3, False,
    )
    scr.set_restitution(ball_r.index(), 0.8)
    var min_y = Float64(1e9)
    var max_y_after_bounce = Float64(-1e9)
    var bounced_once = False
    for _ in range(180):
        scr.step_soft(DT, G)
        var y = Float64(scr.bset.bodies[ball_r.index()].pos[1])
        if y < min_y:
            min_y = y
        if min_y < 0.4 and y > max_y_after_bounce:
            max_y_after_bounce = y
            bounced_once = True
    s.check(bounced_once and max_y_after_bounce > 0.6, "default restitution_combine (MAX) still bounces, matching today's hardcoded max()")
    _ = floor_r

    # the combine setters validate their input (they were unchecked writes into the per-body arrays)
    var bad = 0
    try:
        scr.set_friction_combine(9999, COMBINE_MAX)
    except:
        bad += 1
    try:
        scr.set_restitution_combine(-1, COMBINE_MAX)
    except:
        bad += 1
    try:
        scr.set_friction_combine(0, 7)
    except:
        bad += 1
    try:
        scr.set_restitution_combine(0, -1)
    except:
        bad += 1
    s.check(bad == 4, "set_*_combine: an out-of-range body and an unknown mode raise")

    s.finish()
