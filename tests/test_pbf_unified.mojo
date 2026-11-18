# tier: unit  (override: spatial.cell_sort is the solver's internal neighbour grouping, not a second package under test)
"""Fluid and rigid bodies in one position-based solve (ROADMAP 17.59,
`physics.pbf_unified`).

A 0.6 x 1.2 x 0.6 m tank with wall particles, 1152 fluid particles at
5 cm (8 layers, 0.4 m), a 4 x 4 x 4-particle box (0.2 m), 4 iterations,
dt 1/60 s, 6 s.

  1. Ordinary: a light box (density 0.3 of the fluid's) released 5 cm
     above the floor under the water rises to the surface (released flush
     on the floor it stays: no water gets under it); a heavy one (3.0)
     dropped from above sinks to the floor.
  2. Integration: the light box floats higher than a 0.6 box (draft
     fractions printed, ordering checked); no body is thrown out (the
     earlier explicit-force attempt sent a density-300 box to -11 m at
     15 m/s): every body speed stays under the free-fall speed from the
     release height (sqrt(2 g 0.6) = 3.43 m/s; measured 2.43, reached in
     the air before the water) and every particle in the tank; the
     particle count is unchanged.
  3. The kernel radius is a constructor parameter (default `pbf.H`).
     Measured limit: the drafts sit about one particle layer too deep
     (0.59 / 0.84 for ratios 0.3 / 0.6; slope 0.82, offset +0.29),
     about the same at 10 and 20 iterations. Wall particles (`add_walls`) are on:
     without them the fluid packed against the walls, the 0.4 m column
     settled at ~0.30 m and the drafts were 0.77 / 1.07.
"""

from harness.runner import Suite
from geometry.vec import Real, Vec3
from physics.pbf_unified import UnifiedPbf

comptime SP: Real = 0.05


def tank() -> UnifiedPbf:
    var u = UnifiedPbf(Vec3(0, 0, 0, 0), Vec3(0.6, 1.2, 0.6, 0))
    u.calibrate(SP)
    u.add_walls(SP)
    for k in range(12):
        for j in range(8):
            for i in range(12):
                u.add_fluid(Vec3((Real(i) + 0.5) * SP, (Real(j) + 0.5) * SP, (Real(k) + 0.5) * SP, 0))
    return u^


def cube(y0: Real) -> List[Vec3]:
    var pts = List[Vec3]()
    for k in range(4):
        for j in range(4):
            for i in range(4):
                pts.append(Vec3(0.225 + Real(i) * SP, y0 + Real(j) * SP, 0.225 + Real(k) * SP, 0))
    return pts^


def surface(u: UnifiedPbf) -> Real:
    var top = Real(0)
    for k in range(u.count()):
        if u.body[k] == -1 and (u.x[k][0] < 0.1 or u.x[k][0] > 0.5):
            top = max(top, u.x[k][1])
    return top + SP / 2


def draft(u: UnifiedPbf, b: Int) -> Real:
    var lo = Real(1e9)
    for k in range(u.body_first[b], u.body_first[b] + u.body_count[b]):
        lo = min(lo, u.x[k][1])
    return (surface(u) - (lo - SP / 2)) / (4 * SP)


def run(mut u: UnifiedPbf, b: Int, mut vmax: Real, mut inside: Bool) raises:
    for _ in range(360):
        u.step(1.0 / 60.0, Vec3(0, -9.8, 0, 0), 4)
        var vy = u.body_velocity(b)
        vmax = max(vmax, (vy[0] * vy[0] + vy[1] * vy[1] + vy[2] * vy[2]) ** 0.5)
    for k in range(u.count()):
        if u.body[k] == -2:
            continue  # wall particles sit outside the box
        var q = u.x[k]
        var tol = Real(0) if u.body[k] == -1 else SP / 2  # shape matching follows the clamp
        inside = inside and q[0] >= -tol and q[0] <= 0.6 + tol and q[1] >= -tol and q[1] <= 1.2 + tol and q[2] >= -tol and q[2] <= 0.6 + tol


def main() raises:
    var s = Suite("pbf_unified")
    var vmax = Real(0)
    var inside = True

    # light box released on the floor, under the water: it rises
    var a = tank()
    var nf = a.fluid_count()
    var la = a.add_body(cube(0.075), 0.3)
    var y_start = a.body_centroid(la)[1]
    run(a, la, vmax, inside)
    var y_end = a.body_centroid(la)[1]
    print("  density 0.3 released 5 cm above the floor, under water: centroid y", y_start, "->", y_end, " surface", surface(a), " draft fraction", draft(a, la))
    s.check(y_end > y_start + 0.1 and draft(a, la) < 1, "a light box released under water rises and breaks the surface")
    # flush on the floor it stays there: no water under it, nothing pushes it up

    var h = tank()
    var hb = h.add_body(cube(0.6), 3.0)
    run(h, hb, vmax, inside)
    print("  density 3.0 dropped from above: centroid y", h.body_centroid(hb)[1], " (resting on the floor: 0.075)")
    s.check(h.body_centroid(hb)[1] < 0.1, "a heavy box sinks to the floor")

    var m = tank()
    var mb = m.add_body(cube(0.6), 0.6)
    run(m, mb, vmax, inside)
    var l2 = tank()
    var lb = l2.add_body(cube(0.6), 0.3)
    run(l2, lb, vmax, inside)
    var d3 = draft(l2, lb)
    var d6 = draft(m, mb)
    var slope = (d6 - d3) / 0.3
    print("  dropped from above: draft fraction density 0.3", d3, " 0.6", d6, " slope", slope, " offset", d3 - 0.3, " (ideal: slope 1, offset 0)")
    s.check(d3 < d6 and d6 < 1, "both float, lighter higher (0.3 above 0.6)")
    s.check(slope > 0.7 and slope < 1.3, "draft grows with density at slope ~1 (0.7..1.3)")
    print("  largest body speed over all runs", vmax, " all particles in the tank", inside)
    s.check(vmax < 3.43 and inside, "no body thrown out: speeds under free fall from 0.6 m (3.43 m/s), every particle in the tank")
    s.check(a.fluid_count() == nf and nf == 1152, "fluid particle count unchanged")

    # the kernel radius is a parameter: a lattice's rest density scales as
    # 1 / spacing^3 when h scales with the spacing (normalised kernels)
    var k1 = UnifiedPbf(Vec3(0, 0, 0, 0), Vec3(1, 1, 1, 0), 0.1)
    k1.calibrate(0.05)
    var k2 = UnifiedPbf(Vec3(0, 0, 0, 0), Vec3(1, 1, 1, 0), 0.05)
    k2.calibrate(0.025)
    var ratio = Float64(k2.rho0) / Float64(k1.rho0)
    print("  rest density at (h 0.05, spacing 0.025) over (h 0.1, spacing 0.05):", ratio, " (8 expected)")
    s.check(abs(ratio / 8 - 1) < 1e-3, "rest density scales as 1 / spacing^3 with the kernel radius")
    s.finish()
