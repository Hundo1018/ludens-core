# tier: unit
"""Fire on a grid (ROADMAP 17.61 fire / combustion; ludens-engine #95).

- one cell, no conduction: it burns to the adiabatic temperature T0 + heat_per_fuel * fuel (analytic), the heat it gained
  is exactly heat_per_fuel times the fuel it lost (the ledger), and a step of 2 dt burns what two steps of dt do;
- below the ignition temperature nothing burns, with or without fuel; no fuel means no heat and no spread;
- a flame front on a 1D bar moves at a steady speed (the second half of the run within 25% of the first) and a 4x faster
  burn rate runs between 1.6x and 2.5x faster (the sqrt(alpha k) scaling); fuel burned + fuel left = fuel at the start;
- bad parameters are refused.
Times are not printed (the golden compares this output); the measured speeds are in the ROADMAP note."""
from std.math import exp
from harness.runner import Suite
from physics.combustion import FireGrid
from geometry.vec import Real


def relerr(a: Real, b: Real) -> Real:
    var d = a - b
    return (d if d >= 0 else -d) / (b if b >= 0 else -b)


def front_after(k: Real, seconds: Int, mut fuel_ok: Bool) raises -> Tuple[Int, Int]:
    """Front index (cells) at `seconds` and at `seconds / 2`, on a 200-cell bar."""
    var f = FireGrid(200, 1, 1, 0.01, 1e-3, 300.0, 600.0, k, 900.0)
    for i in range(200):
        f.set_fuel(i, 0, 0, 1.0)
    var start = f.fuel_left()
    f.ignite(0, 0, 0, 1200.0)
    var dt = Real(0.01)
    var half = 0
    var steps = seconds * 100
    for n in range(steps):
        f.step(dt)
        if n + 1 == steps // 2:
            half = f.front()
    var d = f.fuel_left() + f.burned_total - start
    fuel_ok = (d if d >= 0 else -d) < 1e-4 * start
    return (f.front(), half)


def main() raises:
    var s = Suite("combustion")

    # one cell
    var c = FireGrid(1, 1, 1, 0.01, 1e-4, 300.0, 600.0, 2.0, 300.0)
    c.set_fuel(0, 0, 0, 2.0)
    c.ignite(0, 0, 0, 700.0)
    for _ in range(1000):
        c.step(0.01)
    s.check(relerr(c.heat.t[0], 700.0 + 300.0 * 2.0) < 1e-5, "one cell burns out to the adiabatic temperature: " + String(c.heat.t[0]) + " K (700 + 300 * 2)")
    s.check(c.fuel[0] < 1e-6, "...and the fuel is gone")
    s.check(relerr(Real(c.released), c.heat.t[0] - 700.0) < 1e-5 and relerr(Real(c.released), Real(300.0 * c.burned_total)) < 1e-9, "the heat gained is exactly heat_per_fuel times the fuel lost")

    var a = FireGrid(1, 1, 1, 0.01, 1e-4, 300.0, 600.0, 2.0, 300.0)
    var b = FireGrid(1, 1, 1, 0.01, 1e-4, 300.0, 600.0, 2.0, 300.0)
    a.set_fuel(0, 0, 0, 2.0)
    b.set_fuel(0, 0, 0, 2.0)
    a.ignite(0, 0, 0, 700.0)
    b.ignite(0, 0, 0, 700.0)
    a.step(0.02)
    b.step(0.01)
    b.step(0.01)
    s.check(relerr(a.fuel[0], b.fuel[0]) < 1e-5, "one step of 2 dt burns what two steps of dt do (" + String(a.fuel[0]) + " vs " + String(b.fuel[0]) + ")")

    # thresholds
    var cold = FireGrid(1, 1, 1, 0.01, 1e-4, 300.0, 600.0, 2.0, 300.0)
    cold.set_fuel(0, 0, 0, 2.0)
    cold.ignite(0, 0, 0, 590.0)
    for _ in range(500):
        cold.step(0.01)
    s.check(cold.fuel[0] == 2.0 and cold.heat.t[0] <= 590.0 and cold.released == 0, "below the ignition temperature nothing burns")
    var empty = FireGrid(20, 1, 1, 0.01, 1e-4, 300.0, 600.0, 2.0, 300.0)
    empty.ignite(0, 0, 0, 1200.0)
    for _ in range(500):
        empty.step(0.01)
    s.check(empty.released == 0 and empty.burning() == 0 and empty.heat.t[19] < 301.0, "a spark in a bar with no fuel: no heat released, nothing spreads beyond conduction")

    # flame front
    var ok1 = False
    var ok4 = False
    var slow = front_after(1.0, 20, ok1)
    var fast = front_after(4.0, 20, ok4)
    var v_first = Real(slow[1]) / 10.0
    var v_second = Real(slow[0] - slow[1]) / 10.0
    s.check(slow[0] > 20 and slow[0] < 199, "the front advanced and did not reach the end in 20 s (cell " + String(slow[0]) + ")")
    s.check(v_second > 0.75 * v_first and v_second < 1.33 * v_first, "steady speed: " + String(v_first) + " cells/s in the first 10 s, " + String(v_second) + " in the second")
    var vs = Real(slow[0]) / 20.0
    var vf = Real(fast[0]) / 20.0
    s.check(vf / vs > 1.6 and vf / vs < 2.5, "a 4x faster burn runs " + String(vf / vs) + "x faster (sqrt scaling, expected near 2)")
    s.check(ok1 and ok4, "fuel burned + fuel left = fuel at the start, to 1e-4 relative (Float32 cells)")

    # refusals
    var bad = False
    try:
        _ = FireGrid(1, 1, 1, 0.01, 1e-4, 300.0, 250.0, 2.0, 300.0)
    except:
        bad = True
    s.check(bad, "an ignition temperature below the start temperature is refused")
    bad = False
    try:
        var g = FireGrid(1, 1, 1, 0.01, 1e-4, 300.0, 600.0, 2.0, 300.0)
        g.set_fuel(0, 0, 0, -1.0)
    except:
        bad = True
    s.check(bad, "negative fuel is refused")
    bad = False
    try:
        var g2 = FireGrid(4, 1, 1, 0.01, 1e-4, 300.0, 600.0, 2.0, 300.0)
        g2.step(1.0)
    except:
        bad = True
    s.check(bad, "a step above the conduction stability limit is refused")
    s.finish()
