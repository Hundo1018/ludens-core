"""Lie-group layer on PGA motors: exp / log / geodesic (screw interpolation).

The motor manifold is a Lie group whose algebra is the bivector space. `exp`
maps a bivector (an instantaneous screw: rotation rate + translation rate) to a
finite motor; `log` inverts it; `geodesic(a, b, t)` interpolates along the screw
axis — the PGA generalization of slerp that translates and rotates in one
uniform motion.

Closed forms (no series):
  2D — a PGA2 bivector squares to the scalar -a² (a = e12 coefficient), so
       exp(B) = cos(a) + sinc(a)·B.
  3D — write B = (u + v·I)·B̂ with I = e0123 (I² = 0, central) and B̂² = -1;
       dual-angle arithmetic gives exp(B) = (cos u - v sin u·I)
       + (sin u + v cos u·I)·B̂. `log` inverts via u = atan2(|B_E|, scalar).
"""

from std.math import sqrt, atan2
from .trig import cos, sin
from .vec import Real
from .multivector import PGA2, PGA3
from .motor import Motor2, Motor3

comptime _EPS: Real = 1e-8

# PGA3 bivector masks (bits: e1=1, e2=2, e3=4, e0=8)
comptime _B12 = 0b0011
comptime _B13 = 0b0101
comptime _B23 = 0b0110
comptime _B10 = 0b1001
comptime _B20 = 0b1010
comptime _B30 = 0b1100
comptime _PSS3 = 0b1111


@fieldwise_init
struct Screw3(Copyable, ImplicitlyCopyable, Movable, Deinitable):
    """A PGA3 bivector — the Lie algebra of Motor3 (instantaneous screw)."""

    var b12: Real
    var b13: Real
    var b23: Real
    var b10: Real
    var b20: Real
    var b30: Real

    @staticmethod
    def zero() -> Self:
        return Self(0, 0, 0, 0, 0, 0)

    def scaled(self, t: Real) -> Self:
        return Self(
            self.b12 * t, self.b13 * t, self.b23 * t,
            self.b10 * t, self.b20 * t, self.b30 * t,
        )


def exp_screw3(b: Screw3) -> Motor3:
    """Closed-form motor exponential (dual-angle formula)."""
    var u_sq = b.b12 * b.b12 + b.b13 * b.b13 + b.b23 * b.b23
    if u_sq < _EPS * _EPS:
        # pure translation: exp(B) = 1 + B
        return Motor3(1, b.b12, b.b13, b.b23, b.b10, b.b20, b.b30, 0)
    var u = sqrt(u_sq)
    # v = pitch part: <B, B̂_E> where B̂_E is the unit Euclidean bivector.
    # <B_ideal, B̂_E> pairs (b10,b20,b30) with (b23,-b13,b12) — the pseudoscalar
    # coefficient of B_E ∧ B_ideal ... computed via the algebra below instead.
    var mv = PGA3()
    mv.c[_B12] = b.b12
    mv.c[_B13] = b.b13
    mv.c[_B23] = b.b23
    mv.c[_B10] = b.b10
    mv.c[_B20] = b.b20
    mv.c[_B30] = b.b30
    # B^2 = -(u^2 + 2uv I): read u,v off the square (algebra does the bookkeeping)
    var sq = mv * mv
    var v = -sq.c[_PSS3] / (2 * u)
    # B̂ = B (u - vI)/u^2 ; I*B keeps only the Euclidean->ideal image (I*ideal = 0)
    var pss = PGA3.basis(_PSS3)
    var bhat = (mv * (PGA3.scalar(u) - pss.scaled(v))).scaled(1 / u_sq)
    # exp = (cos u - v sin u I) + (sin u + v cos u I) B̂
    var cu = cos(u)
    var su = sin(u)
    var out = (PGA3.scalar(cu) - pss.scaled(v * su)) + (
        bhat.scaled(su) + (pss * bhat).scaled(v * cu)
    )
    return Motor3.from_mv(out)


def log_motor3(m: Motor3) -> Screw3:
    """Closed-form motor logarithm (inverse of `exp_screw3`; angle in [0, π))."""
    var ue_sq = m.b12 * m.b12 + m.b13 * m.b13 + m.b23 * m.b23
    if ue_sq < _EPS * _EPS:
        # pure translation (or identity): M = 1 + B_ideal
        var inv = 1.0 if abs(m.s) < _EPS else 1.0 / m.s
        return Screw3(0, 0, 0, m.b10 * inv, m.b20 * inv, m.b30 * inv)
    var ue = sqrt(ue_sq)  # |sin u|
    var u = atan2(ue, m.s)
    var su = ue  # sin u (sign folded into the bivector direction)
    var cu = m.s
    var v = -m.pss / su
    # B̂ = M_biv (sin u - v cos u I)/sin^2 u ; then log = (u + vI) B̂
    var mb = PGA3()
    mb.c[_B12] = m.b12
    mb.c[_B13] = m.b13
    mb.c[_B23] = m.b23
    mb.c[_B10] = m.b10
    mb.c[_B20] = m.b20
    mb.c[_B30] = m.b30
    var pss = PGA3.basis(_PSS3)
    var bhat = (mb * (PGA3.scalar(su) - pss.scaled(v * cu))).scaled(1 / (su * su))
    var lg = bhat.scaled(u) + (pss * bhat).scaled(v)
    return Screw3(
        lg.c[_B12], lg.c[_B13], lg.c[_B23], lg.c[_B10], lg.c[_B20], lg.c[_B30]
    )


def geodesic3(a: Motor3, b: Motor3, t: Real) -> Motor3:
    """Screw interpolation `a * exp(t·log(rev(a)·b))` — uniform rigid motion."""
    return a * exp_screw3(log_motor3(a.reverse() * b).scaled(t))


# ---------------------------------------------------------------- 2D
@fieldwise_init
struct Screw2(Copyable, ImplicitlyCopyable, Movable, Deinitable):
    """A PGA2 bivector — the Lie algebra of Motor2."""

    var b12: Real
    var b10: Real
    var b20: Real

    @staticmethod
    def zero() -> Self:
        return Self(0, 0, 0)

    def scaled(self, t: Real) -> Self:
        return Self(self.b12 * t, self.b10 * t, self.b20 * t)


def exp_screw2(b: Screw2) -> Motor2:
    """2D closed form: B² = -b12², so exp(B) = cos(b12) + sinc(b12)·B."""
    var a = b.b12
    if abs(a) < _EPS:
        return Motor2(1, b.b12, b.b10, b.b20)
    var s = sin(a) / a
    return Motor2(cos(a), s * b.b12, s * b.b10, s * b.b20)


def log_motor2(m: Motor2) -> Screw2:
    var a = atan2(m.b12, m.s)  # rotation half-angle... folded: b12 = -sin(θ/2)
    if abs(m.b12) < _EPS:
        var inv = 1.0 if abs(m.s) < _EPS else 1.0 / m.s
        return Screw2(0, m.b10 * inv, m.b20 * inv)
    var s = a / sin(a)  # inverse sinc at the recovered angle
    return Screw2(a, s * m.b10, s * m.b20)


def geodesic2(a: Motor2, b: Motor2, t: Real) -> Motor2:
    return a * exp_screw2(log_motor2(a.reverse() * b).scaled(t))
