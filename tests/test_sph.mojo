# tier: component  (override: spatial.cell_sort is the solver's internal neighbour grouping, not a second package under test)
"""SPH physical gates, and the CFL limit that separates it from PBF.

The same containment / conservation / settling checks PBF gets, run on the same
particle state and grid so a difference in outcome is a difference in solver
rather than in setup.

The last check is the one that matters for choosing between them. SPH enforces
incompressibility by making the fluid STIFF, and a stiff explicit integrator is
CFL-limited: past some timestep it does not merely lose accuracy, it diverges.
PBF's projection has no such limit. Asserting that SPH is stable below a
timestep AND unstable above one pins the constraint as a measured property
instead of leaving it as received wisdom — and it is the reason the benchmark
sweeps dt rather than particle count.
"""

from std.math import sqrt
from harness.runner import Suite
from geometry.vec import Real, Vec3
from physics.pbf import PbfFluid
from physics.sph import sph_step

comptime G = Vec3(0, -9.8, 0, 0)


def _block(mut f: PbfFluid, ox: Real, oy: Real, oz: Real, s: Int, sp: Real):
    for i in range(s):
        for j in range(s):
            for k in range(s):
                f.add(Vec3(ox + Real(i) * sp, oy + Real(j) * sp, oz + Real(k) * sp, 0))


def _scene(sp: Real) -> PbfFluid:
    var f = PbfFluid(Vec3(0, 0, 0, 0), Vec3(0.6, 1.0, 0.6, 0))
    f.calibrate(sp)
    _block(f, 0.12, 0.30, 0.12, 6, sp)
    return f^


def _inside(f: PbfFluid) -> Bool:
    for i in range(f.count()):
        if f.x[i] < f.lo[0] - 1e-3 or f.x[i] > f.hi[0] + 1e-3:
            return False
        if f.y[i] < f.lo[1] - 1e-3 or f.y[i] > f.hi[1] + 1e-3:
            return False
        if f.z[i] < f.lo[2] - 1e-3 or f.z[i] > f.hi[2] + 1e-3:
            return False
    return True


def _maxv(f: PbfFluid) -> Real:
    var m = Real(0)
    for i in range(f.count()):
        var v = f.vx[i] * f.vx[i] + f.vy[i] * f.vy[i] + f.vz[i] * f.vz[i]
        if v > m:
            m = v
    return sqrt(m)


def _finite(f: PbfFluid) -> Bool:
    for i in range(f.count()):
        var v = f.vx[i] * f.vx[i] + f.vy[i] * f.vy[i] + f.vz[i] * f.vz[i]
        if not (v < 1e12):  # catches NaN too: NaN fails every comparison
            return False
    return True


def _mean_rho(mut f: PbfFluid) -> Real:
    f._rebuild_grid()
    var nbr = List[Int]()
    var tot = Real(0)
    for i in range(f.count()):
        f._neighbors(i, nbr)
        tot += f.density(i, nbr)
    return tot / Real(f.count())


def main() raises:
    var s = Suite("sph")

    # ---- stable timestep: physical behaviour ----
    var f = _scene(0.06)
    s.eqi(f.count(), 216, "216 particles seeded")
    var ok_box = True
    # a full second of simulated time: the block has to LAND before pressure
    # does anything at all, because clamped-tension SPH exerts no force while
    # the fluid is still below rest density
    for _ in range(2000):
        sph_step(f, 1.0 / 2000.0, G)
        if not _inside(f):
            ok_box = False
    s.check(ok_box, "no particle leaves the box at a stable timestep")
    s.check(_finite(f), "velocities stay finite")
    s.eqi(f.count(), 216, "particle count is conserved")

    var rho = _mean_rho(f)
    print("  settled rho/rest:", rho / f.rho0, " max|v|:", _maxv(f))
    s.check(rho / f.rho0 > 0.9, "settled fluid reaches rest density")
    s.check(rho / f.rho0 < 1.1, "settled fluid is not compressed")
    s.check(_maxv(f) < 1.0, "settled fluid has come to rest")

    # ---- CFL: the same scene must DIVERGE at a large timestep ----
    # This is the property that distinguishes an explicit stiff solver from a
    # projection one, so it is asserted rather than assumed.
    # The wall clamp bounds positions, so divergence does NOT show up as NaN or
    # as an infinite velocity — it shows up as a fluid that never settles. The
    # gate is therefore physical: density far past rest and a velocity field
    # orders of magnitude above the stable run.
    var g = _scene(0.06)
    for _ in range(59):
        sph_step(g, 1.0 / 60.0, G)  # same 1 s of simulated time
    var rho_big = _mean_rho(g) / g.rho0
    var v_big = _maxv(g)
    print("  dt=1/60 -> rho/rest:", rho_big, " max|v|:", v_big)
    s.check(
        rho_big > 1.5 and v_big > 10.0,
        "SPH is CFL-limited: dt=1/60 fails to settle on this fluid",
    )

    # and the boundary is between 1/120 and 1/60, not somewhere vague
    var m = _scene(0.06)
    for _ in range(119):
        sph_step(m, 1.0 / 120.0, G)
    var rho_mid = _mean_rho(m) / m.rho0
    print("  dt=1/120 -> rho/rest:", rho_mid, " max|v|:", _maxv(m))
    s.check(rho_mid < 1.1 and _maxv(m) < 1.0, "dt=1/120 is still stable")

    s.finish()
