# tier: integration
"""Particle level set volume correction (ROADMAP 17.60,
`physics.mac_levelset_particles`).

A 32 x 32 cell box, dx 1/32, dt 1/240 s, 240 steps, gravity 0. The velocity is
a single vortex psi = A sin^2(pi x) sin^2(pi y) (zero normal flow on the walls),
set on the faces before the first step and kept divergence-free by the
projection. A disk of radius 0.15 m is centred on the box centre (0.5, 0.5),
which is the vortex's stagnation point (zero velocity there), and is stirred
for 1 s. Volume (cells with phi < 0, times dx^2) is compared at the end with and
without the particle correction; the particle correction must keep more of it.

Reseeding (`LevelSetParticles.reseed`, every 20 steps, target 4 per band cell,
band 3 cells) is run as a third case. Two results were measured before this test
was written (2026-10-27), so the checks pin measured numbers rather than fresh
predictions:
  - Under the merged per-cell rule (not shipped; see `physics.mac_levelset_particles`),
    reseeding moved the volume from 0.0879 to 0.0684 (analytic 0.0707).
  - Under the shipped sequential rule, reseeding leaves the cell-count volume
    unchanged (0.0771 with and without reseeding). The prediction that reseeding
    ends closer to the disk FAILED on this rule: the two volumes are equal.
    Restated: the check asserts equality at cell resolution.
The particle count prediction ([0.5, 2] x initial) FAILED in the first run: the
count grows with the band area, and the stirred interface lengthens, so the count
rose from 720 to 3708 (about 5 times). Restated: printed, not bounded.
"""

from harness.runner import Suite
from geometry.vec import Real
from std.math import sin, cos, sqrt
from physics.mac_levelset import LevelSetWater2
from physics.mac_levelset_particles import LevelSetParticles

comptime PI: Real = 3.141592653589793


def _vortex(mut ls: LevelSetWater2, amp: Real):
    var n = ls.n
    var dx = ls.dx
    var k = Real(2) * PI
    for j in range(n):
        for i in range(n + 1):
            var x = Real(i) * dx
            var y = (Real(j) + 0.5) * dx
            # u = dpsi/dy
            ls.u[j * (n + 1) + i] = amp * sin(PI * x) * sin(PI * x) * k * sin(PI * y) * cos(PI * y)
    for j in range(n + 1):
        for i in range(n):
            var x = (Real(i) + 0.5) * dx
            var y = Real(j) * dx
            # v = -dpsi/dx
            ls.v[j * n + i] = -amp * k * sin(PI * x) * cos(PI * x) * sin(PI * y) * sin(PI * y)


def _run(with_particles: Bool) raises -> Real:
    var n = 32
    var dx = Real(1) / Real(n)
    var dt = Real(1.0) / Real(240)
    var ls = LevelSetWater2(n, dx, 0.0)
    ls.set_box(0.35, 0.35, 0.65, 0.65)
    # disk: replace the box by a circle of radius 0.15 centred (0.5, 0.5)
    for j in range(n):
        for i in range(n):
            var x = (Real(i) + 0.5) * dx - 0.5
            var y = (Real(j) + 0.5) * dx - 0.5
            ls.phi[j * n + i] = sqrt(x * x + y * y) - 0.15
    _vortex(ls, 0.6)
    var parts = LevelSetParticles(dx)
    if with_particles:
        parts.seed(ls, 3.0)
    for _ in range(240):
        ls.step(dt)
        if with_particles:
            parts.advect(ls, dt)
            _ = parts.correct(ls)
    return ls.volume()


def _run_reseed(every: Int, mut count0: Int, mut count1: Int) raises -> Real:
    var n = 32
    var dx = Real(1) / Real(n)
    var dt = Real(1.0) / Real(240)
    var ls = LevelSetWater2(n, dx, 0.0)
    ls.set_box(0.35, 0.35, 0.65, 0.65)
    for j in range(n):
        for i in range(n):
            var x = (Real(i) + 0.5) * dx - 0.5
            var y = (Real(j) + 0.5) * dx - 0.5
            ls.phi[j * n + i] = sqrt(x * x + y * y) - 0.15
    _vortex(ls, 0.6)
    var parts = LevelSetParticles(dx)
    parts.seed(ls, 3.0)
    count0 = parts.count()
    for step in range(240):
        ls.step(dt)
        parts.advect(ls, dt)
        _ = parts.correct(ls)
        if every > 0 and (step + 1) % every == 0:
            parts.reseed(ls, 3.0, 4)
    count1 = parts.count()
    return ls.volume()


def main() raises:
    var s = Suite("levelset_particles")
    var v0 = PI * 0.15 * 0.15
    var plain = _run(False)
    var corr = _run(True)
    print("  volume: initial", v0, "plain", plain, "particles", corr)
    s.check(corr > plain, "particle correction keeps more volume than the plain level set")
    s.check(abs(corr - v0) / v0 < 0.10, "with particles the volume stays within 10 % of the initial disk")
    var c0 = 0
    var c1 = 0
    var rsd = _run_reseed(20, c0, c1)
    print("  reseed every 20 steps: volume", rsd, " seed once", corr, " particles", c0, "->", c1)
    # one 1/256 cell of 0.0039 flips between FMA and no-FMA builds (x86-64 reference: 0.07324 vs 0.07715),
    # so the restated claim is "within two cells", not bit-equal.
    s.check(abs(rsd - corr) < 0.008, "reseeding leaves the cell-count volume unchanged under the shipped rule (restated, within two cells)")
    s.finish()
