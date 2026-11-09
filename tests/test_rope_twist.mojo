# tier: unit
"""Torsion along a rope (ROADMAP 17.86, #101): analytic profile, torque, wave speed, energy.

  1. Held tip, root turned by phi = 1 rad: the profile settles to phi (1 - i / (n - 1)) (max error < 1e-3) and the root
     torque to GJ phi / L (relative error < 1e-3).
  2. Free tip: every node settles to phi, root torque -> 0.
  3. A step at the root of a long chain reaches node m at about m sqrt(I / k) seconds (within 10 %).
  4. Undamped, free-free-ish chain after a kick: peak energy deviation over 20000 steps < 1.5e-2 relative at dt = 0.01 max_dt (measured 7.8e-3; 3.9e-3 at 0.005 max_dt, so it scales with dt).
  5. Refusals: n < 2, dt above max_dt.
"""

from std.math import sqrt
from harness.runner import Suite
from geometry.vec import Real
from physics.rope_twist import RopeTwist


def main() raises:
    var s = Suite("rope_twist")
    var n = 21
    var dl = Real(0.05)
    var gj = Real(2.0)
    var phi = Real(1.0)
    var a = RopeTwist(n, dl, gj, 0.001, 0.02)
    a.fix_tip(True)
    a.set_root(phi)
    for _ in range(200000):
        a.step(a.max_dt() * 0.5)
    var worst = Real(0)
    for i in range(n):
        var want = phi * (1 - Real(i) / Real(n - 1))
        var d = a.theta[i] - want
        worst = max(worst, d if d >= 0 else -d)
    var length = dl * Real(n - 1)
    var tq = a.root_torque()
    var want_tq = gj * phi / length
    s.check(worst < 1e-3, "held tip: linear profile, worst error " + String(worst))
    s.check(abs(tq - want_tq) / want_tq < 1e-3, "root torque " + String(tq) + " N m, GJ phi / L = " + String(want_tq))

    var b = RopeTwist(n, dl, gj, 0.001, 0.02)
    b.set_root(phi)
    for _ in range(200000):
        b.step(b.max_dt() * 0.5)
    var worst_b = Real(0)
    for i in range(n):
        var d = b.theta[i] - phi
        worst_b = max(worst_b, d if d >= 0 else -d)
    s.check(worst_b < 1e-3 and abs(b.root_torque()) < 1e-3 * want_tq, "free tip: theta = phi everywhere (worst " + String(worst_b) + "), root torque " + String(b.root_torque()))

    var c = RopeTwist(201, dl, gj, 0.001, 0.0)
    c.set_root(phi)
    var dt = c.max_dt() * 0.25
    var t = Real(0)
    var m = 80
    var arrive = Real(-1)
    for _ in range(200000):
        c.step(dt)
        t += dt
        if arrive < 0 and c.theta[m] > 0.5 * phi:
            arrive = t
    var want_t = Real(m) * sqrt(0.001 / c.k)
    s.check(arrive > 0 and abs(arrive - want_t) / want_t < 0.1, "front reaches node " + String(m) + " at " + String(arrive) + " s, analytic " + String(want_t) + " s")

    var d = RopeTwist(30, dl, gj, 0.001, 0.0)
    d.omega[10] = 1.0
    d.omega[11] = -0.5
    var e0 = d.energy()
    var emax = Real(0)
    for _ in range(20000):
        d.step(d.max_dt() * 0.01)
        emax = max(emax, abs(d.energy() - e0) / e0)
    s.check(emax < 1.5e-2, "undamped peak energy deviation " + String(emax))

    var raised = False
    try:
        _ = RopeTwist(1, dl, gj, 0.001)
    except:
        raised = True
    var raised2 = False
    try:
        d.step(d.max_dt() * 2)
    except:
        raised2 = True
    s.check(raised and raised2, "n < 2 and dt > max_dt are refused")
    s.finish()
