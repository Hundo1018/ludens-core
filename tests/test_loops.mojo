# tier: integration
"""Closed kinematic loops and direct constraint solves (ROADMAP 17.51).

  1. Ordinary: a parallelogram four-bar (crank, coupler and rocker of a
     `Chain`, the rocker's tip closed to a ground pivot by `LoopClosure`)
     driven at 2 rad/s without gravity: the loop stays closed, the coupler
     stays parallel to the ground (q0 + q1 = 0) and, the kinetic energy
     being configuration-independent for this linkage, the crank keeps
     2 rad/s to within 5 % (measured 1.94 .. 2.015: the step plus the
     velocity projection is not energy-exact).
  2. Integration (17.51's example): a 10-link chain with link masses
     alternating 1 and 100 kg, both ends pinned (a closed loop) and released
     with a twist: the velocity rows' residual after projected Gauss-Seidel
     at 20 and 100 iterations, after `solve_active_set` (exact) and after
     `solve_cg`; and the loop gap after 1 s of gravity under each solver.
     Measured: one closure is only three rows, and PGS converges on it
     (PGS 20 1.5e-4, PGS 100 4.1e-6); direct 5.5e-6 and CG 1.5e-6 sit at
     the f32 floor -- the 100x gap the ROADMAP example expected does not
     appear on this system.
  3. Extreme: the same closure added twice (redundant rows) stays finite
     under the direct solve; `solve_active_set` refuses friction rows and
     `solve_cg` refuses limit rows.
"""

from std.math import isfinite
from harness.runner import Suite
from geometry.vec import Real, Vec3
from physics.chain import Chain, ChainLink
from physics.constraints import (
    ConstraintSet, LoopClosure, resolve_loops, SOLVE_PGS, SOLVE_DIRECT, SOLVE_CG,
)

comptime DT: Real = 1.0 / 120.0
comptime G = Vec3(0, -9.8, 0, 0)
comptime Z = Vec3(0, 0, 1, 0)
comptime ZERO = Vec3(0, 0, 0, 0)


def _four_bar(l: Real, d: Real) raises -> Chain:
    var c = Chain()
    c.add_link(ChainLink.revolute(Z, ZERO, Vec3(0, l / 2, 0, 0), 1, Vec3(l * l / 12, 1e-4, l * l / 12, 0)))
    _ = c.add_link_to(0, ChainLink.revolute(Z, Vec3(0, l, 0, 0), Vec3(d / 2, 0, 0, 0), 1, Vec3(1e-4, d * d / 12, d * d / 12, 0)))
    _ = c.add_link_to(1, ChainLink.revolute(Z, Vec3(d, 0, 0, 0), Vec3(0, -l / 2, 0, 0), 1, Vec3(l * l / 12, 1e-4, l * l / 12, 0)))
    return c^


def _heavy_loop() raises -> Chain:
    """10 links of 0.5 m along +x from the origin, masses 1 / 100
    alternating; its tip is pinned at its start position by the caller."""
    var c = Chain()
    for k in range(10):
        var m = Real(1) if k % 2 == 0 else Real(100)
        var piv = ZERO if k == 0 else Vec3(0.5, 0, 0, 0)
        var link = ChainLink.revolute(Z, piv, Vec3(0.25, 0, 0, 0), m, Vec3(1e-3 * m, m * 0.25 * 0.25 / 3, m * 0.25 * 0.25 / 3, 0))
        if k == 0:
            c.add_link(link)
        else:
            _ = c.add_link_to(k - 1, link)
    # a gentle arch so the closed chain is not straight (straight is singular)
    for k in range(10):
        c.q[k] = Real(0.3) if k == 0 else (Real(-0.3) if k == 9 else Real(0))
    c.q[5] = -0.3
    c.q[4] = 0.0
    return c^


def main() raises:
    var s = Suite("loops")

    # ---- four-bar -------------------------------------------------------------------------------------
    var fb = _four_bar(1, 2)
    var loops = List[LoopClosure]()
    loops.append(LoopClosure(2, Vec3(0, -1, 0, 0), -1, Vec3(2, 0, 0, 0)))
    fb.qd[0] = 2
    fb.qd[1] = -2
    fb.qd[2] = 2
    var zero3 = List[Real](length=3, fill=0)
    var gap = Real(0)
    var par = Real(0)
    var wmin = Real(1e9)
    var wmax = Real(-1e9)
    for _ in range(240):
        fb.step(DT, zero3, ZERO)
        gap = max(gap, resolve_loops(fb, loops, DT))
        par = max(par, abs(fb.q[0] + fb.q[1]))
        wmin = min(wmin, fb.qd[0])
        wmax = max(wmax, fb.qd[0])
    print("  parallelogram four-bar at 2 rad/s, 2 s (", fb.q[0], "rad turned): max loop gap", gap, " max |q0 + q1|", par, " crank speed", wmin, "..", wmax)
    s.check(gap < 1e-4 and par < 1e-3, "four-bar: the loop stays closed and the coupler parallel")
    s.check(abs(wmin - 2) < 0.1 and abs(wmax - 2) < 0.1, "four-bar: the crank keeps 2 rad/s within 5 %")

    # ---- 1:100 closed chain: solver residuals --------------------------------------------------------------
    var base = _heavy_loop()
    var tip_local = Vec3(0.5, 0, 0, 0)
    var anchor = base.point_world(9, tip_local)
    var hl = List[LoopClosure]()
    hl.append(LoopClosure(9, tip_local, -1, anchor))
    # a twist that breaks the loop: every joint at 1 rad/s
    var res = List[Real]()
    for mode in range(4):
        var c = _heavy_loop()
        for k in range(10):
            c.qd[k] = 1
        var cs = ConstraintSet(10)
        for k in range(3):
            var e = Vec3(0, 0, 0, 0)
            e[k] = 1
            _ = cs.add_equality(c.point_jacobian(9, tip_local, e), 0)
        var qd = c.qd.copy()
        match mode:
            case 0:
                cs.solve(c.mass_matrix(), qd, 20)
            case 1:
                cs.solve(c.mass_matrix(), qd, 100)
            case 2:
                _ = cs.solve_active_set(c.mass_matrix(), qd)
            case _:
                _ = cs.solve_cg(c.mass_matrix(), qd, 50)
        res.append(cs.residual(qd))
    print("  1:100 closed chain, loop-breaking twist: velocity residual PGS 20", res[0], " PGS 100", res[1], " direct", res[2], " CG", res[3])
    s.check(res[2] < 3e-5 and res[3] < 3e-5 and res[0] > 5 * res[2], "direct and CG solves reach the f32 floor (< 3e-5; x86-64 no-FMA measures 1.4e-5); PGS 20 leaves over 5x that")

    var gaps = List[Real]()
    for mode in [SOLVE_PGS, SOLVE_DIRECT, SOLVE_CG]:
        var c = _heavy_loop()
        var z10 = List[Real](length=10, fill=0)
        var worst = Real(0)
        for _ in range(120):
            c.step(DT, z10, G)
            worst = max(worst, resolve_loops(c, hl, DT, mode, 20))
        gaps.append(worst)
    print("  1:100 closed chain under gravity, 1 s: max loop gap PGS(20)", gaps[0], " direct", gaps[1], " CG", gaps[2])
    s.check(gaps[1] < 1e-3 and gaps[2] < 1e-3, "direct and CG keep the loop closed within 1 mm under gravity")

    # ---- extremes ---------------------------------------------------------------------------------------------
    var rd = _four_bar(1, 2)
    var twice = List[LoopClosure]()
    twice.append(LoopClosure(2, Vec3(0, -1, 0, 0), -1, Vec3(2, 0, 0, 0)))
    twice.append(LoopClosure(2, Vec3(0, -1, 0, 0), -1, Vec3(2, 0, 0, 0)))
    rd.qd[0] = 1
    var g2 = Real(0)
    for _ in range(60):
        rd.step(DT, zero3, G)
        g2 = max(g2, resolve_loops(rd, twice, DT, SOLVE_DIRECT))
    s.check(isfinite(rd.q[0]) and isfinite(rd.q[2]) and g2 < 1e-3, "a closure added twice (redundant rows) stays finite and closed")
    var raised = 0
    var cf = ConstraintSet(3)
    var n0 = cf.add_contact([Real(1), 0, 0], 0)
    _ = cf.add_tangents([Real(0), 1, 0], [Real(0), 0, 1], n0, 0.5)
    var qv = List[Real](length=3, fill=0)
    var hm = List[Real](length=9, fill=0)
    hm[0] = 1
    hm[4] = 1
    hm[8] = 1
    try:
        _ = cf.solve_active_set(hm.copy(), qv)
    except:
        raised += 1
    var cl = ConstraintSet(3)
    _ = cl.add_limit([Real(1), 0, 0], 0)
    try:
        _ = cl.solve_cg(hm.copy(), qv)
    except:
        raised += 1
    s.check(raised == 2, "solve_active_set refuses friction rows, solve_cg limit rows")
    s.finish()
