# tier: unit
"""Flux-form (conservative) advection on `MacFluid3` (ROADMAP 17.61 in 3-D,
`MacFluid3.use_flux_advection`, first-order upwind finite volume).

16^3 periodic box, dx 1/16, dt 1/60, nu 0, no body force, 20 steps. The
initial velocity is the non-symmetric deterministic field of
`test_fluid3_multigrid`, so no term vanishes by symmetry. Each step advects,
then projects. Projection conserves the periodic sums (the pressure gradient
telescopes), so the three sums sum(u), sum(v), sum(w) change only through the
advection.

Predictions, written before the run:

  * Flux path: after 20 steps each sum changes by less than 1e-5 of
    sum |u| (relative drift). The flux form telescopes, so the change is f32
    rounding.
  * The semi-Lagrangian path is printed for contrast. It is not conserved
    (interpolation), and no bound is set on it here.
  * CFL: max |u| is about 1 for this field, so 3 |u| dt / dx = 3 * (1/60) * 16
    = 0.8 and the sub-cycle count is 1 at the start.

Measured (one run): relative drift of the sums 5.2e-10 for the flux path,
9.3e-4 for semi-Lagrangian. The first is within the prediction, and the
second is the contrast the header asked to record. Only this field is tested;
the 2-D point-drag case of `test_fluid_flux` covers the point source.
"""

from std.math import sin, cos
from harness.runner import Suite
from geometry.vec import Real
from physics.mac_fluid3 import MacFluid3

comptime N = 16
comptime DX: Real = 1.0 / 16.0
comptime DT: Real = 1.0 / 60.0


def _field(mut f: MacFluid3):
    var m = f.cells()
    for c in range(m):
        var t = Real(c)
        f.u[c] = sin(0.91 * t)
        f.v[c] = cos(0.53 * t)
        f.w[c] = sin(1.7 * t + 0.3)


def _sums(f: MacFluid3) -> Tuple[Real, Real, Real, Real]:
    """(sum u, sum v, sum w, sum |u| + |v| + |w|), accumulated in f64."""
    var su = Float64(0)
    var sv = Float64(0)
    var sw = Float64(0)
    var sa = Float64(0)
    for c in range(f.cells()):
        su += Float64(f.u[c])
        sv += Float64(f.v[c])
        sw += Float64(f.w[c])
        sa += Float64(abs(f.u[c]) + abs(f.v[c]) + abs(f.w[c]))
    return (Real(su), Real(sv), Real(sw), Real(sa))


def _drift(flux: Bool) raises -> Real:
    """Largest relative change of the three sums over 20 steps."""
    var f = MacFluid3(N, DX, 0)
    _field(f)
    if flux:
        f.use_flux_advection()
    var s0 = _sums(f)
    for _ in range(20):
        f.step(DT)
    var s1 = _sums(f)
    var d = max(abs(s1[0] - s0[0]), max(abs(s1[1] - s0[1]), abs(s1[2] - s0[2])))
    return d / s0[3]


def main() raises:
    var s = Suite("fluid3_flux")
    var dflux = _drift(True)
    var dsl = _drift(False)
    print("  relative drift of the sums after 20 steps: flux", dflux, "  semi-Lagrangian", dsl)
    s.check(dflux < 1e-5, "flux form conserves the periodic sums of u, v, w to 1e-5 relative")
    s.finish()
