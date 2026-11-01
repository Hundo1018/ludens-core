"""Free-rotation integrator seam: how to advance a tumbling rigid body.

The torque-free Euler equations `ω̇ = I⁻¹(−ω × Iω)` (principal body frame) are
the classic stress test for integrators — the Dzhanibekov / tennis-racket
tumble is chaotic about the intermediate axis, and cheap integrators leak
energy. `SpinIntegrator` is the swap seam; the pose always advances by the
closed-form motor exponential (`galie.exp_screw3`), what varies is the ω
update:

  * `EulerSpin`    — semi-implicit forward Euler (matches `ScrewBody6.step`).
  * `Rk2Spin`      — explicit midpoint (RK2): O(dt²) local energy error.
  * `MidpointSpin` — IMPLICIT midpoint via fixed-point iteration: symplectic
    flavor, near-conserves energy and momentum over long runs.
  * `LgvciSpin`    — the true Lie-group VARIATIONAL integrator (ROADMAP 4.1b):
    Moser–Veselov discrete Euler equations. The relative rotation F ∈ SO(3)
    solves `F·J_d − J_d·Fᵀ = h·skew(Π)` (J_d the mass-distribution matrix,
    Π = Iω the body momentum), then `Π' = Fᵀ·Π`, `R' = R·F`. Because the
    scheme derives from a DISCRETE variational principle, the body momentum
    is transported by an exact rotation — world angular momentum is conserved
    to roundoff (not just to O(dtⁿ)) and energy oscillates boundedly.

Gates: `tests/test_integrator6.mojo` (cross parity + conservation ordering),
`benchmarks/bench_rigid6.mojo` (cost + drift tables).
"""

from std.math import sqrt
from geometry.trig import sin, cos
from geometry.vec import Real, Vec3, cross
from geometry.motor import Motor3
from geometry.galie import exp_screw3
from .screw import screw_velocity
from .rigid6 import Inertia3


def _torque_free(wb: Vec3, inertia: Inertia3) -> Vec3:
    """ω̇ = I⁻¹(−ω × Iω) in the principal body frame."""
    return inertia.apply_inv(-cross(wb, inertia.apply(wb)))


def _advance(pose: Motor3, wb: Vec3, dt: Real) -> Motor3:
    """Rotate the pose by the body rate ω over dt (closed-form motor exp)."""
    return (
        pose * exp_screw3(screw_velocity(wb, Vec3(0, 0, 0, 0)).scaled(dt))
    ).normalized()


trait SpinIntegrator(Movable, Deinitable):
    @staticmethod
    def step(
        pose: Motor3, wb: Vec3, inertia: Inertia3, dt: Real
    ) -> Tuple[Motor3, Vec3]: ...


struct EulerSpin(SpinIntegrator, Movable, Deinitable):
    @staticmethod
    def step(
        pose: Motor3, wb: Vec3, inertia: Inertia3, dt: Real
    ) -> Tuple[Motor3, Vec3]:
        var w2 = wb + _torque_free(wb, inertia) * dt
        return (_advance(pose, w2, dt), w2)


struct Rk2Spin(SpinIntegrator, Movable, Deinitable):
    @staticmethod
    def step(
        pose: Motor3, wb: Vec3, inertia: Inertia3, dt: Real
    ) -> Tuple[Motor3, Vec3]:
        var wm = wb + _torque_free(wb, inertia) * (dt * 0.5)
        var w2 = wb + _torque_free(wm, inertia) * dt
        return (_advance(pose, wm, dt), w2)


struct MidpointSpin(SpinIntegrator, Movable, Deinitable):
    """Implicit midpoint `ω½ = ω + f(ω½)·dt/2` by fixed-point iteration
    (converges fast for dt·|ω| ≪ 1), then `ω' = 2ω½ − ω`."""

    @staticmethod
    def step(
        pose: Motor3, wb: Vec3, inertia: Inertia3, dt: Real
    ) -> Tuple[Motor3, Vec3]:
        var wh = wb
        for _ in range(4):
            wh = wb + _torque_free(wh, inertia) * (dt * 0.5)
        var w2 = wh * 2 - wb
        return (_advance(pose, wh, dt), w2)


comptime _Rows3 = Array[Vec3, 3]


def _rodrigues(f: Vec3) -> _Rows3:
    """Rotation matrix rows of exp(f̂): R = 1 + a·f̂ + b·f̂² (series-guarded)."""
    var t2 = f[0] * f[0] + f[1] * f[1] + f[2] * f[2]
    var a = 1 - t2 / 6  # series fallback for tiny angles
    var b = 0.5 - t2 / 24
    if t2 > 1e-8:
        var t = sqrt(t2)
        a = sin(t) / t
        b = (1 - cos(t)) / t2
    var r = _Rows3(fill=Vec3(0, 0, 0, 0))
    r[0] = Vec3(
        1 + b * (-f[1] * f[1] - f[2] * f[2]),
        -a * f[2] + b * f[0] * f[1],
        a * f[1] + b * f[0] * f[2],
        0,
    )
    r[1] = Vec3(
        a * f[2] + b * f[0] * f[1],
        1 + b * (-f[0] * f[0] - f[2] * f[2]),
        -a * f[0] + b * f[1] * f[2],
        0,
    )
    r[2] = Vec3(
        -a * f[1] + b * f[0] * f[2],
        a * f[0] + b * f[1] * f[2],
        1 + b * (-f[0] * f[0] - f[1] * f[1]),
        0,
    )
    return r^


def _ax_fjd(r: _Rows3, jd: Vec3) -> Vec3:
    """Axial vector of `F·J_d − (F·J_d)ᵀ` for diagonal J_d (M_ij = F_ij·jd_j)."""
    return Vec3(
        r[2][1] * jd[1] - r[1][2] * jd[2],
        r[0][2] * jd[2] - r[2][0] * jd[0],
        r[1][0] * jd[0] - r[0][1] * jd[1],
        0,
    )


struct LgvciSpin(SpinIntegrator, Movable, Deinitable):
    """Moser–Veselov DMV step. The implicit equation is solved by fixed point
    on the rotation vector: `ax(F(f)·J_d − J_d·F(f)ᵀ) = I·f + O(|f|²)`, so
    `f ← f + I⁻¹(h·Π − ax(...))` contracts at rate O(h|ω|) from the explicit
    guess f₀ = h·ω (same convergence class as `MidpointSpin`'s iteration)."""

    @staticmethod
    def step(
        pose: Motor3, wb: Vec3, inertia: Inertia3, dt: Real
    ) -> Tuple[Motor3, Vec3]:
        # J_d from the principal moments: I = tr(J_d)·1 − J_d.
        var jd = Vec3(
            (-inertia.ix + inertia.iy + inertia.iz) * 0.5,
            (inertia.ix - inertia.iy + inertia.iz) * 0.5,
            (inertia.ix + inertia.iy - inertia.iz) * 0.5,
            0,
        )
        var pi = inertia.apply(wb)
        var g = pi * dt  # h·Π
        var f = wb * dt
        for _ in range(5):
            f = f + inertia.apply_inv(g - _ax_fjd(_rodrigues(f), jd))
        var r = _rodrigues(f)
        # Π' = Fᵀ·Π — an exact rotation of the body momentum.
        var pi2 = Vec3(
            r[0][0] * pi[0] + r[1][0] * pi[1] + r[2][0] * pi[2],
            r[0][1] * pi[0] + r[1][1] * pi[1] + r[2][1] * pi[2],
            r[0][2] * pi[0] + r[1][2] * pi[1] + r[2][2] * pi[2],
            0,
        )
        var w2 = inertia.apply_inv(pi2)
        var pose2 = (
            pose * exp_screw3(screw_velocity(f, Vec3(0, 0, 0, 0)).scaled(1))
        ).normalized()
        return (pose2, w2)


def run_spin[I: SpinIntegrator](
    var pose: Motor3, var wb: Vec3, inertia: Inertia3, dt: Real, steps: Int
) -> Tuple[Motor3, Vec3]:
    for _ in range(steps):
        var r = I.step(pose, wb, inertia, dt)
        pose = r[0]
        wb = r[1]
    return (pose, wb)


def spin_energy(wb: Vec3, inertia: Inertia3) -> Real:
    var l = inertia.apply(wb)
    return (wb[0] * l[0] + wb[1] * l[1] + wb[2] * l[2]) * 0.5


def spin_momentum_world(pose: Motor3, wb: Vec3, inertia: Inertia3) -> Vec3:
    """World-frame angular momentum (exactly conserved by the true flow)."""
    return pose.to_quat_translation()[0].rotate(inertia.apply(wb))
