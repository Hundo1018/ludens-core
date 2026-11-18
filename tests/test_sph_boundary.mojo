# tier: component  (override: spatial.cell_sort is the solver's internal neighbour grouping, not a second package under test)
"""SPH boundary particles vs clamped walls (ROADMAP 17.42 d).

  seam parity  with no boundary particles `sph_step_boundary` is
               `sph_step` bit for bit; with a floor of boundary particles
               but the fluid still more than a kernel radius above it, too.
  ordinary     a block of fluid spreading on the floor for one second:
               clamped walls let the bottom layer, missing half its
               neighbours, read under-dense and the fluid collapses onto
               the floor (centre of mass a few mm up); boundary particles
               supply the missing density and hold it several times higher.
  extreme      boundary psi is positive and uniform over the interior of
               the sampled floor; a single boundary particle has psi =
               rho0 / W(0).
"""

from harness.runner import Suite
from geometry.vec import Real, Vec3
from physics.pbf import PbfFluid, poly6
from physics.sph import sph_step, sph_step_boundary, box_floor_boundary, BoundaryParticles

comptime SP: Real = 0.05
comptime G = Vec3(0, -9.8, 0, 0)
comptime DT: Real = 1.0 / 2000.0


def _scene(y0: Real) -> PbfFluid:
    var f = PbfFluid(Vec3(0, 0, 0, 0), Vec3(0.6, 1.0, 0.6, 0))
    f.calibrate(SP)
    for i in range(6):
        for j in range(6):
            for k in range(6):
                f.add(Vec3(0.12 + Real(i) * SP, y0 + Real(j) * SP, 0.12 + Real(k) * SP, 0))
    return f^


def _com(f: PbfFluid) -> Real:
    var y = Real(0)
    for i in range(f.count()):
        y += f.y[i]
    return y / Real(f.count())


def _same(a: PbfFluid, b: PbfFluid) -> Bool:
    for i in range(a.count()):
        if a.x[i] != b.x[i] or a.y[i] != b.y[i] or a.z[i] != b.z[i]:
            return False
    return True


def main() raises:
    var s = Suite("sph_boundary")

    var a = _scene(0.3)
    var b = _scene(0.3)
    var c = _scene(0.3)
    var empty = BoundaryParticles()
    var floor = box_floor_boundary(a.lo, a.hi, SP, a.rho0)
    for _ in range(50):
        sph_step(a, DT, G)
        sph_step_boundary(b, empty, DT, G)
        sph_step_boundary(c, floor, DT, G)
    s.check(_same(a, b), "no boundary particles: sph_step_boundary == sph_step, bit for bit")
    s.check(_same(a, c), "floor particles out of kernel reach: still bit-identical")

    var cl = _scene(0.01)
    var bp = _scene(0.01)
    for _ in range(2000):
        sph_step(cl, DT, G)
        sph_step_boundary(bp, floor, DT, G)
    var ccl = _com(cl)
    var cbp = _com(bp)
    print("  after 1 s: centre of mass, clamped", ccl, " boundary particles", cbp)
    s.check(cbp > 0.4 * SP, "boundary particles hold the settled fluid up (COM > 0.4 spacing)")
    s.check(ccl < cbp / 2, "clamped walls let it collapse onto the floor")

    var interior = True
    var p0 = Real(-1)
    for k in range(len(floor.x)):
        if floor.psi[k] <= 0:
            interior = False
        if floor.x[k] > 0.2 and floor.x[k] < 0.4 and floor.z[k] > 0.2 and floor.z[k] < 0.4:
            if p0 < 0:
                p0 = floor.psi[k]
            elif abs(floor.psi[k] - p0) > 1e-3 * p0:
                interior = False
    s.check(interior, "psi positive everywhere and uniform over the floor interior")
    var one = BoundaryParticles()
    one.add(Vec3(0, 0, 0, 0))
    one.finalize(a.rho0)
    s.almost(Float64(one.psi[0]), Float64(a.rho0 / poly6(0)), "single particle: psi = rho0 / W(0)", 1e-3)
    s.finish()
