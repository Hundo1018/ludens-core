# tier: unit  (override: spatial.cell_sort is the solver's internal neighbour grouping, not a second package under test)
"""Position-Based Fluids: physical gates, not pictures.

A fluid solver is easy to make look plausible and hard to make correct, so the
checks here are the properties that fail loudly when the constraint projection
is wrong:

  containment  — no particle may leave the box, ever. A density solver that
                 overshoots pushes particles through walls, and this catches it
                 on every step rather than at the end.
  conservation — particle count and total mass are invariant by construction;
                 asserting them catches an indexing bug in the grid rebuild
                 that would silently drop particles from neighbour lists.
  compression  — a settled column must approach rest density. This is the
                 constraint actually doing its job, and it is checked as an
                 improvement over the unsolved state so the bar cannot be met
                 by a solver that does nothing.
  settling     — a dam break must lose kinetic energy and come to rest. A
                 solver with a sign error or a runaway lambda gains energy
                 instead, which no static check would catch.
"""

from std.math import sqrt
from harness.runner import Suite
from geometry.vec import Real, Vec3
from physics.pbf import PbfFluid, poly6

comptime DT: Real = 1.0 / 120.0
comptime G = Vec3(0, -9.8, 0, 0)


def _block(mut f: PbfFluid, ox: Real, oy: Real, oz: Real, nx: Int, ny: Int, nz: Int, sp: Real):
    for i in range(nx):
        for j in range(ny):
            for k in range(nz):
                f.add(Vec3(ox + Real(i) * sp, oy + Real(j) * sp, oz + Real(k) * sp, 0))


def _ke(f: PbfFluid) -> Real:
    var e = Real(0)
    for i in range(f.count()):
        e += f.vx[i] * f.vx[i] + f.vy[i] * f.vy[i] + f.vz[i] * f.vz[i]
    return e


def _inside(f: PbfFluid) -> Bool:
    for i in range(f.count()):
        if f.x[i] < f.lo[0] - 1e-3 or f.x[i] > f.hi[0] + 1e-3:
            return False
        if f.y[i] < f.lo[1] - 1e-3 or f.y[i] > f.hi[1] + 1e-3:
            return False
        if f.z[i] < f.lo[2] - 1e-3 or f.z[i] > f.hi[2] + 1e-3:
            return False
    return True


def _mean_density(mut f: PbfFluid) -> Real:
    f._rebuild_grid()
    var nbr = List[Int]()
    var tot = Real(0)
    for i in range(f.count()):
        f._neighbors(i, nbr)
        tot += f.density(i, nbr)
    return tot / Real(f.count())


def main() raises:
    var s = Suite("pbf")

    # ---- settling column ----
    var f = PbfFluid(Vec3(0, 0, 0, 0), Vec3(0.6, 1.0, 0.6, 0))
    f.calibrate(0.06)
    _block(f, 0.12, 0.30, 0.12, 6, 6, 6, 0.06)
    s.eqi(f.count(), 216, "216 particles seeded")

    var rho_start = _mean_density(f)
    var contained = True
    for _ in range(120):
        f.step(DT, G, 6)
        if not _inside(f):
            contained = False
    s.check(contained, "no particle ever leaves the box")
    s.eqi(f.count(), 216, "particle count is conserved")

    var rho_end = _mean_density(f)
    print("  mean density: start", rho_start, " settled", rho_end, " rest", f.rho0)
    # settled fluid must be DENSER than the loose initial sampling and must
    # not have blown past rest density into a compressed lump
    s.check(rho_end > rho_start, "settling increases density toward rest")
    # a converged density solver lands NEAR rest, not merely below a loose cap:
    # 3 iterations collapses this scene to ~16x rest, 6 reaches ~1%, so a wide
    # bound here would pass a solver that is visibly broken
    s.check(rho_end < 1.25 * f.rho0, "settled density is within 25% of rest")

    # STABILITY IN THE ITERATION COUNT. Before the per-iteration displacement
    # clamp, this scene converged at 2 and 4 iterations but collapsed to ~16x
    # rest density at 3 and 6 — erratic in the iteration count, which is the
    # signature of a diverging projection rather than of under-resolution.
    # Every count must now land near rest, and more iterations must not make
    # things worse.
    var stable = True
    var counts = List[Int]()
    counts.append(2)
    counts.append(3)
    counts.append(4)
    counts.append(6)
    counts.append(10)
    for ci in range(len(counts)):
        var fi = PbfFluid(Vec3(0, 0, 0, 0), Vec3(0.6, 1.0, 0.6, 0))
        fi.calibrate(0.06)
        _block(fi, 0.12, 0.30, 0.12, 6, 6, 6, 0.06)
        for _ in range(120):
            fi.step(DT, G, counts[ci])
        var r = _mean_density(fi) / fi.rho0
        print("    iters", counts[ci], " rho/rest", r)
        if r > 1.25 or r < 0.5:
            stable = False
    s.check(stable, "every iteration count converges (no divergence cliff)")

    # ---- dam break: must dissipate, not gain, energy ----
    var d = PbfFluid(Vec3(0, 0, 0, 0), Vec3(1.0, 0.8, 0.4, 0))
    d.calibrate(0.06)
    _block(d, 0.05, 0.05, 0.08, 5, 10, 4, 0.06)
    var n0 = d.count()
    for _ in range(20):
        d.step(DT, G, 6)
    var ke_early = _ke(d)
    var ok_box = True
    for _ in range(200):
        d.step(DT, G, 6)
        if not _inside(d):
            ok_box = False
    var ke_late = _ke(d)
    print("  dam-break KE: early", ke_early, " late", ke_late)
    s.check(ok_box, "dam break stays inside the container")
    s.eqi(d.count(), n0, "dam break conserves particle count")
    s.check(ke_late < ke_early, "dam break dissipates kinetic energy")

    # ---- the fluid actually spread out (it is not a frozen lump) ----
    var minx = d.x[0]
    var maxx = d.x[0]
    for i in range(d.count()):
        if d.x[i] < minx:
            minx = d.x[i]
        if d.x[i] > maxx:
            maxx = d.x[i]
    print("  dam-break x spread:", maxx - minx, " (initial 0.24)")
    s.check(maxx - minx > 0.30, "the column collapsed and spread")

    s.finish()
