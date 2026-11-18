# tier: unit
"""3-D multigrid pressure solve on `MacFluid3` (ROADMAP 17.60,
`numerics.multigrid3` `PeriodicPoissonMG3`, the 3-D counterpart of 17.84).

A 32^3 periodic box with a deterministic, non-symmetric velocity field (not a
symmetric flow, so no term of the projection vanishes by symmetry). The same
field is projected twice: once with Jacobi-preconditioned CG (the default) and
once with `use_multigrid()` (MGPCG). Both solve the same Poisson problem to
the same tolerance, 1e-6.

Predictions, written before the run:

  * MGPCG needs at most 25 iterations, and Jacobi PCG needs at least 3 times
    as many. The 2-D result (17.84) is a constant-iteration count against an
    n-dependent one; the 3-D count should follow it.
  * Both paths converge.
  * The projected velocities agree: max |u_mg - u_jacobi| below 1e-3 of
    max |u| (both solve to the same residual; the difference is the
    tolerance, not a different answer).
  * After projection the divergence is below 1e-3 of its value before.
  * n = 12 (not a power of two) makes `use_multigrid` raise.

Measured (one run, n = 32): Jacobi PCG 56 iterations, MGPCG 3; both residuals
about 1e-6. Max |u| difference 2.6e-6 relative. Divergence after projection
2.2e-4 (Jacobi) and 3.8e-4 (MGPCG), from 131 before. All six checks pass.

The 25-iteration bound was set before the run and is loose: the measured MGPCG
count is 3. Only n = 32 is measured here. The claim that the count stays
constant as n grows is not tested by this file.
"""

from std.math import sin, cos
from harness.runner import Suite
from geometry.vec import Real
from physics.mac_fluid3 import MacFluid3

comptime N = 32
comptime DX: Real = 1.0 / 32.0
comptime DT: Real = 1.0 / 60.0


def _field(mut f: MacFluid3):
    var m = f.cells()
    for c in range(m):
        var t = Real(c)
        f.u[c] = sin(0.91 * t)
        f.v[c] = cos(0.53 * t)
        f.w[c] = sin(1.7 * t + 0.3)


def _maxabs(a: List[Real]) -> Real:
    var mx = Real(0)
    for c in range(len(a)):
        mx = max(mx, abs(a[c]))
    return mx


def main() raises:
    var s = Suite("fluid3_multigrid")
    var jac = MacFluid3(N, DX, 0)
    _field(jac)
    var mg = MacFluid3(N, DX, 0)
    _field(mg)
    mg.use_multigrid()
    var div_before = _maxabs(jac.divergence())
    var rj = jac.project(DT)
    var rm = mg.project(DT)
    var div_after = _maxabs(jac.divergence())
    var div_after_mg = _maxabs(mg.divergence())
    var umax = Real(0)
    var dmax = Real(0)
    for c in range(jac.cells()):
        umax = max(umax, max(abs(jac.u[c]), max(abs(jac.v[c]), abs(jac.w[c]))))
        var d = max(abs(jac.u[c] - mg.u[c]), max(abs(jac.v[c] - mg.v[c]), abs(jac.w[c] - mg.w[c])))
        dmax = max(dmax, d)
    print("  iterations: Jacobi", rj.iters, " MGPCG", rm.iters, "  residual Jacobi", rj.residual, " MGPCG", rm.residual)
    print("  max |u| diff / max |u|", dmax / umax, "  divergence after: Jacobi", div_after, " MGPCG", div_after_mg, "  before", div_before)
    s.check(rm.converged and rj.converged, "both solves converge")
    s.check(rm.iters <= 25, "MGPCG needs at most 25 iterations at n = 32")
    s.check(rj.iters >= 3 * rm.iters, "Jacobi PCG needs at least 3 times the MGPCG iterations")
    s.check(dmax / umax < 1e-3, "the two paths give the same projected velocity (1e-3 relative)")
    s.check(div_after_mg < 1e-3 * div_before and div_after < 1e-3 * div_before, "projection removes the divergence on both paths")
    var raised = 0
    try:
        var g = MacFluid3(12, DX, 0)
        g.use_multigrid()
    except:
        raised += 1
    s.check(raised == 1, "use_multigrid raises for n = 12 (not a power of two)")
    s.finish()
