# tier: component
"""MPM transfer and wall friction, measured (ROADMAP 17.58 未做 items).

  1. G2P transfer: a free-falling 4 x 4 x 4 block has no forces except gravity,
     so its mean velocity must be g t and its kinetic energy 1/2 M (g t)^2.
     Measured after 0.2 s (400 steps of 1/2000 s), both `step` and `step_ext`:
     mean v 1.9599984 vs g t 1.96 (1e-6 relative), KE ratio 0.99999803.
  2. Domain walls: the grid's 3-cell wall band zeroes only the normal velocity,
     so a block on the domain floor slides freely. Measured acceleration over
     g sin(theta) at 10 / 20 / 40 degrees: +0.25 % each. The effective wall
     friction is zero; there is no configurable mu for domain walls.
  3. Obstacles: `step_ext` honours the obstacle mu. A 0.6 box top sticks at
     20 degrees (acceleration 0.009 m/s^2) and slides at 40 degrees at 1.856
     m/s^2 vs g (sin - mu cos) = 1.795 (+3.4 %).
     `step` does not apply obstacle friction at all: 3.360 and 6.315 m/s^2 at
     20 and 40 degrees are the frictionless free slide (measured with the
     obstacle present, before `step` got its `debug_assert`). `step` now
     asserts it has no obstacles; continuum routes obstacle solvers to
     `step_ext`, so this test only runs `step_ext` with obstacles.
"""

from harness.runner import Suite
from geometry.vec import Real, Vec3
from geometry.sdf3 import Sdf3
from std.math import sin, cos
from physics.mpm import MpmSolver

comptime DX: Real = 0.05
comptime N = 32
comptime DT: Real = 1.0 / 2000.0
comptime SP: Real = 0.03
comptime G0: Real = 9.8
comptime DEG: Real = 0.017453292519943295


def _block(mut m: MpmSolver, x0: Real, y0: Real, z0: Real, nx: Int, ny: Int, nz: Int):
    var vol = SP * SP * SP
    for i in range(nx):
        for j in range(ny):
            for k in range(nz):
                m.add(Vec3(x0 + Real(i) * SP, y0 + Real(j) * SP, z0 + Real(k) * SP, 0), vol * 1600.0, vol)


def _mean_x(m: MpmSolver) -> Real:
    var x = Real(0)
    for ref q in m.p:
        x += q.x[0]
    return x / Real(m.count())


def _fall(ext: Bool, steps: Int) -> Vec3:
    """Returns (mean vy, KE / KE_ideal, 0)."""
    var m = MpmSolver(Vec3(0, 0, 0, 0), DX, N, 2.0e5, 0.3)
    _block(m, 0.6, 0.6, 0.6, 4, 4, 4)
    var g = Vec3(0, -G0, 0, 0)
    for _ in range(steps):
        if ext:
            m.step_ext(DT, g)
        else:
            m.step(DT, g)
    var t = Real(steps) * DT
    var vy = Real(0)
    var ke = Real(0)
    for ref q in m.p:
        vy += q.v[1]
        ke += 0.5 * q.mass * (q.v[1] * q.v[1])
    vy /= Real(m.count())
    var ideal = G0 * t
    var ke_ideal = 0.5 * m.total_mass() * ideal * ideal
    return Vec3(vy, ke / ke_ideal, 0, 0)


def _wall_acc(theta_deg: Real) -> Real:
    """Block on the domain floor (y = 0), gravity tilted toward +x, `step`."""
    var m = MpmSolver(Vec3(0, 0, 0, 0), DX, N, 2.0e5, 0.3)
    _block(m, 0.6, 0.06, 0.6, 4, 2, 4)
    var th = theta_deg * DEG
    var g = Vec3(G0 * sin(th), -G0 * cos(th), 0, 0)
    var x0 = _mean_x(m)
    for _ in range(400):
        m.step(DT, g)
    var t = Real(400) * DT
    return 2 * (_mean_x(m) - x0) / (t * t)


def _box_acc(theta_deg: Real, mu: Real) raises -> Real:
    var m = MpmSolver(Vec3(0, 0, 0, 0), DX, N, 2.0e5, 0.3)
    m.add_obstacle(Sdf3.box(Vec3(0.8, 0.1, 0.8, 0), Vec3(0.8, 0.1, 0.8, 0)), mu)
    _block(m, 0.6, 0.215, 0.6, 4, 2, 4)
    var th = theta_deg * DEG
    var g = Vec3(G0 * sin(th), -G0 * cos(th), 0, 0)
    var x0 = _mean_x(m)
    for _ in range(400):
        m.step_ext(DT, g)
    var t = Real(400) * DT
    return 2 * (_mean_x(m) - x0) / (t * t)


def main() raises:
    var s = Suite("mpm_domain")

    # 1. G2P transfer does not dissipate free fall.
    for ext in [False, True]:
        var r = _fall(ext, 400)
        var lab = String("step_ext") if ext else String("step")
        s.almost(Float64(r[0]), -1.96, "free fall " + lab + ": mean v = -g t", tol=1e-4)
        s.almost(Float64(r[1]), 1.0, "free fall " + lab + ": KE = 1/2 M (g t)^2", tol=5e-5)  # x86-64 no-FMA: 0.999989

    # 2. Domain walls: the grid wall band gives no friction.
    for th in [Real(10), Real(20), Real(40)]:
        var a = _wall_acc(th)
        var want = G0 * sin(th * DEG)
        s.check(abs(a - want) / want < 0.01, "domain floor at " + String(Int(th)) + " deg slides freely (within 1 % of g sin)")

    # 3. Obstacles: step_ext applies mu; step applies none.
    var stick = _box_acc(20, 0.6)
    s.check(abs(stick) < 0.05, "box mu 0.6: sticks at 20 deg (|a| < 0.05 m/s^2)")
    var slide = _box_acc(40, 0.6)
    var ref40 = G0 * (sin(40 * DEG) - 0.6 * cos(40 * DEG))
    s.check(abs(slide - ref40) / ref40 < 0.05, "box mu 0.6: slides at 40 deg within 5 % of g (sin - mu cos)")

    s.finish()
