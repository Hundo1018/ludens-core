# tier: unit
"""Point drag in 3-D on `MacFluid3` (ROADMAP 17.61 in 3-D): the 3-D counterpart of
`test_fluid_flux` / `test_fluid_momentum`.

16^3 periodic box, dx 1/16, dt 1/120, nu 1e-3, 120 steps (1 s). A point starts at
the centre (0.5, 0.5, 0.5) moving +x at 1 m/s and is dragged toward the air
velocity with rate k (point-drag rule as in the 2-D test). Each step the impulse
it gives the air is applied with `add_impulse` (trilinear adjoint, per dx^3).
The air's total momentum should then change by exactly the total impulse.

Predictions, written before the run:

  * k = 5, flux path: relative residual below 1e-4 (the same argument as 2-D:
    flux form conserves the total, so the change equals the impulse up to f32
    accumulation).
  * k = 5, semi-Lagrangian path: relative residual above 0.10. The 2-D value at
    the same k was 2.27; that is recorded, not the bound.
  * The flux sub-step count is printed. dx^3 is 4x smaller than the 2-D dx^2 at
    n = 32, so the impulse per step is 4x larger, and the sub-step count may be
    heavy. If it is, the count is recorded; the test is not dropped for it.

Measured (one run): k 5 flux residual 2.3e-7, flux sub-steps 8398 over 120
steps (about 70 per step); semi-Lagrangian residual 1.69. Both predictions hold.
The semi-Lagrangian residual is smaller than the 2-D 2.27 at the same k. The
two setups differ in n, dx, and dimension, so no single cause is assigned; this
is one run, not a scaling law.
"""

from harness.runner import Suite
from geometry.vec import Real
from physics.mac_fluid3 import MacFluid3

comptime N = 16
comptime DX: Real = 1.0 / 16.0
comptime DT: Real = 1.0 / 120.0


def _coupled(k: Real, flux: Bool) raises -> Tuple[Real, Int]:
    """Returns (relative residual, flux sub-steps taken)."""
    var f = MacFluid3(N, DX, Real(1e-3))
    if flux:
        f.use_flux_advection()
    var xp = Real(0.5)
    var yp = Real(0.5)
    var zp = Real(0.5)
    var vpx = Real(1)
    var vpy = Real(0)
    var vpz = Real(0)
    var imp = (Real(0), Real(0), Real(0))
    var a0 = f.momentum()
    for _ in range(120):
        var ua = f.velocity(xp, yp, zp)
        var a = k * DT
        var nvx = (vpx + a * ua[0]) / (1 + a)
        var nvy = (vpy + a * ua[1]) / (1 + a)
        var nvz = (vpz + a * ua[2]) / (1 + a)
        var ix = vpx - nvx
        var iy = vpy - nvy
        var iz = vpz - nvz
        f.add_impulse(xp, yp, zp, ix, iy, iz)
        imp = (imp[0] + ix, imp[1] + iy, imp[2] + iz)
        vpx = nvx
        vpy = nvy
        vpz = nvz
        xp += vpx * DT
        yp += vpy * DT
        zp += vpz * DT
        f.step(DT)
    var a1 = f.momentum()
    var dm = (a1[0] - a0[0], a1[1] - a0[1], a1[2] - a0[2])
    var mag = abs(imp[0]) + abs(imp[1]) + abs(imp[2])
    var rel = (abs(dm[0] - imp[0]) + abs(dm[1] - imp[1]) + abs(dm[2] - imp[2])) / mag
    return (rel, f.flux_substeps)


def main() raises:
    var s = Suite("fluid3_point")
    var fl = _coupled(Real(5), True)
    var sl = _coupled(Real(5), False)
    print("  k 5 flux residual", fl[0], " flux sub-steps", fl[1], "  semi-Lagrangian residual", sl[0])
    s.check(fl[0] < 1e-4, "flux form at k = 5 conserves the total to 1e-4 in 3-D")
    s.check(sl[0] > 0.10, "semi-Lagrangian at k = 5 leaves a residual above 10 % in 3-D")
    s.finish()
