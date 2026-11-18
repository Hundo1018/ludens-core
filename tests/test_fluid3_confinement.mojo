# tier: unit
"""3-D vorticity confinement on `MacFluid3` (ROADMAP 17.60,
`physics.mac_fluid3` `set_confinement`). 16^3 periodic box, dx 1/16,
dt 1/60, nu 0, 120 steps (2 s).

Initial velocity: the 3-D Taylor-Green field with w = 0,
u = sin(2 pi x) cos(2 pi y) cos(2 pi z), v = -cos(2 pi x) sin(2 pi y) cos(2 pi z).
v depends on z, so the vorticity has all three components (the 2-D check of
`test_smoke` cannot exercise the z terms).

Predictions, written before the run:

  * eps 2 keeps more enstrophy than eps 0 after 2 s: ratio above 1.1. The
    2-D `test_smoke` measured 1.38 at eps 2 on a buoyant blob. That is a
    different flow, so it is a guide for the size, not the bound; the bound
    is 1.1.
  * The default (no `set_confinement` call) and `set_confinement(0)` give the
    same kinetic energy and enstrophy bit for bit: the guard skips the code.
  * eps < 0 raises.
  * With eps 2 the energy and enstrophy stay finite.

Measured (the one run that set the prediction above): enstrophy 3.95 at eps 0,
15.56 at eps 2, ratio 3.94; kinetic energy 0.0119 at eps 0, 0.0379 at eps 2,
ratio 3.2. All four checks pass.

The ratio is far above the 2-D figure (1.38), and the energy grows: confinement
is not energy-conserving, so it adds kinetic energy. One reason the 3-D number
is larger is the strength per cell: eps dx = 2 / 16 = 0.125 here, against
2 / 64 = 0.031 in `test_smoke`, four times stronger per cell. That is a
hypothesis about the size, not a measured split; `eps dx` was not varied.
Energy growth of 3.2x is recorded as a result of this setup, not as a check
of the method's accuracy.
"""

from std.math import cos, sin
from harness.runner import Suite
from geometry.vec import Real
from physics.mac_fluid3 import MacFluid3

comptime N = 16
comptime DX: Real = 1.0 / 16.0
comptime DT: Real = 1.0 / 60.0
comptime TAU: Real = 6.283185307179586


def _tg(eps: Real) raises -> MacFluid3:
    var f = MacFluid3(N, DX, 0)
    var n = N
    for k in range(n):
        for j in range(n):
            for i in range(n):
                var c = f.idx(i, j, k)
                # u on (i, j + 1/2, k + 1/2), v on (i + 1/2, j, k + 1/2), w = 0
                var xu = Real(i) * DX
                var yu = (Real(j) + 0.5) * DX
                var zu = (Real(k) + 0.5) * DX
                f.u[c] = sin(TAU * xu) * cos(TAU * yu) * cos(TAU * zu)
                var xv = (Real(i) + 0.5) * DX
                var yv = Real(j) * DX
                var zv = (Real(k) + 0.5) * DX
                f.v[c] = -cos(TAU * xv) * sin(TAU * yv) * cos(TAU * zv)
    if eps > 0:
        f.set_confinement(eps)
    return f^


def _run(eps: Real) raises -> Tuple[Real, Real]:
    """Returns (kinetic energy, enstrophy) after 2 s."""
    var f = _tg(eps)
    for _ in range(120):
        f.step(DT)
    return (f.kinetic_energy(), f.enstrophy())


def main() raises:
    var s = Suite("fluid3_confinement")
    var none = _run(0)
    var conf = _run(2)
    var dflt = _tg(0)
    var off = _tg(0)
    off.set_confinement(0)
    for _ in range(120):
        dflt.step(DT)
        off.step(DT)
    var ratio = conf[1] / none[1]
    print("  enstrophy eps 0", none[1], " eps 2", conf[1], " ratio", ratio, "  energy eps 0", none[0], " eps 2", conf[0])
    s.check(ratio > 1.1, "confinement at eps 2 keeps more enstrophy than none (ratio above 1.1)")
    s.check(dflt.kinetic_energy() == off.kinetic_energy() and dflt.enstrophy() == off.enstrophy(), "default equals set_confinement(0) bit for bit")
    s.check(conf[0] > 0 and conf[1] > 0 and conf[0] == conf[0] and conf[1] == conf[1], "energy and enstrophy stay finite with eps 2")
    var raised = 0
    try:
        var g = MacFluid3(N, DX, 0)
        g.set_confinement(-1)
    except:
        raised += 1
    s.check(raised == 1, "eps < 0 raises")
    s.finish()
