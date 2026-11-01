"""PGA motors: rigid transforms as even-subalgebra elements of Cl(2,0,1)/Cl(3,0,1).

`Motor2` (4 floats) and `Motor3` (8 floats — isomorphic to a dual quaternion)
store the even-grade coefficients compactly; all algebra goes through the
signature-generic `Multivector` (inlined, so the odd-grade zeros constant-fold
away). Composition is the geometric product; a point is moved by the sandwich
`M P reverse(M)`.

Conventions (canonical bit-order basis, bit i = e_i; the degenerate vector is
the HIGHEST bit — e0 = bit 2 in PGA2, bit 3 in PGA3):
  PGA3 point embed:  P(x,y,z) = e123 - x*e230 + y*e130 - z*e120
  PGA2 point embed:  P(x,y)   = e12 + x*e20 - y*e10
  translator:        T = 1 + (d/2) * (dx*e10 + dy*e20 [+ dz*e30])
  quat <-> rotor:    w + x*(-e23) + y*(+e13) + z*(-e12)
Derived by requiring `T P0 rev(T)` to translate the origin by +d; verified
against the Quat/Mat4 paths in `tests/test_motor_parity.mojo`.
"""

from std.math import sqrt
from .trig import cos, sin
from .vec import Real, Vec2, Vec3
from .quat import Quat, compose_trs4
from .mat import Mat4
from .multivector import Multivector, PGA2, PGA3


# ---------------------------------------------------------------- Motor3
# PGA3 blade masks (bits: e1=1, e2=2, e3=4, e0=8)
comptime _B12 = 0b0011  # e1e2
comptime _B13 = 0b0101  # e1e3
comptime _B23 = 0b0110  # e2e3
comptime _B10 = 0b1001  # e1e0
comptime _B20 = 0b1010  # e2e0
comptime _B30 = 0b1100  # e3e0
comptime _PSS3 = 0b1111  # e1e2e3e0
comptime _E123 = 0b0111
comptime _T230 = 0b1110  # e2e3e0
comptime _T130 = 0b1101  # e1e3e0
comptime _T120 = 0b1011  # e1e2e0


@fieldwise_init
struct Motor3(Copyable, ImplicitlyCopyable, Movable, Deinitable):
    """3D rigid motion (rotation + translation) — 8 floats, ≅ dual quaternion."""

    var s: Real  # scalar
    var b12: Real  # e1e2
    var b13: Real  # e1e3
    var b23: Real  # e2e3
    var b10: Real  # e1e0 (ideal / translational)
    var b20: Real  # e2e0
    var b30: Real  # e3e0
    var pss: Real  # e1e2e3e0

    @staticmethod
    def identity() -> Self:
        return Self(1, 0, 0, 0, 0, 0, 0, 0)

    # --- multivector bridge (inlined so odd-grade zeros fold away) ---
    @always_inline
    def to_mv(self) -> PGA3:
        var m = PGA3()
        m.c[0] = self.s
        m.c[_B12] = self.b12
        m.c[_B13] = self.b13
        m.c[_B23] = self.b23
        m.c[_B10] = self.b10
        m.c[_B20] = self.b20
        m.c[_B30] = self.b30
        m.c[_PSS3] = self.pss
        return m^

    @staticmethod
    @always_inline
    def from_mv(m: PGA3) -> Self:
        return Self(
            m.c[0], m.c[_B12], m.c[_B13], m.c[_B23],
            m.c[_B10], m.c[_B20], m.c[_B30], m.c[_PSS3],
        )

    # --- constructors ---
    @staticmethod
    def from_quat(q: Quat) -> Self:
        """Rotor from a unit quaternion: w + x(-e23) + y(+e13) + z(-e12)."""
        return Self(q.w, -q.z, q.y, -q.x, 0, 0, 0, 0)

    @staticmethod
    def from_translation(t: Vec3) -> Self:
        """Translator `1 + (t/2)·(tx e10 + ty e20 + tz e30)`."""
        return Self(1, 0, 0, 0, t[0] * 0.5, t[1] * 0.5, t[2] * 0.5, 0)

    @staticmethod
    def from_quat_translation(q: Quat, t: Vec3) -> Self:
        """Rotate then translate (world): `T * R`."""
        return Self.from_translation(t) * Self.from_quat(q)

    # --- algebra ---
    @always_inline
    def __mul__(self, o: Self) -> Self:
        """Composition = geometric product (applies `o` first, then `self`)."""
        return Self.from_mv(self.to_mv() * o.to_mv())

    @always_inline
    def reverse(self) -> Self:
        """Reverse — the inverse of a unit motor."""
        return Self(
            self.s, -self.b12, -self.b13, -self.b23,
            -self.b10, -self.b20, -self.b30, self.pss,
        )

    @always_inline
    def norm_sq(self) -> Real:
        """Euclidean-part squared norm (1 for a unit motor)."""
        return (
            self.s * self.s
            + self.b12 * self.b12
            + self.b13 * self.b13
            + self.b23 * self.b23
        )

    @always_inline
    def normalized(self) -> Self:
        var n = 1.0 / sqrt(self.norm_sq())
        return Self(
            self.s * n, self.b12 * n, self.b13 * n, self.b23 * n,
            self.b10 * n, self.b20 * n, self.b30 * n, self.pss * n,
        )

    def to_quat_translation(self) -> Tuple[Quat, Vec3]:
        """Split M = T·R into (rotation quat, translation)."""
        var q = Quat(-self.b23, self.b13, -self.b12, self.s)
        var t = self * Self.from_quat(q).reverse()
        return (q, Vec3(t.b10 * 2, t.b20 * 2, t.b30 * 2, 0))

    def to_mat4(self) -> Mat4:
        """Convert once, then batch-transform points by matrix — the sandwich
        (`apply_point`) is exact but costs two full geometric products, so bulk
        point work should go through the matrix (or a SIMD column)."""
        var qt = self.to_quat_translation()
        return compose_trs4(qt[1], qt[0], Vec3(1, 1, 1, 0))

    # --- action ---
    @always_inline
    def apply_point(self, pt: Vec3) -> Vec3:
        """Sandwich `M P rev(M)` on the point trivector."""
        var P = PGA3()
        P.c[_E123] = 1
        P.c[_T230] = -pt[0]
        P.c[_T130] = pt[1]
        P.c[_T120] = -pt[2]
        var R = self.to_mv() * P * self.to_mv().reverse()
        var w = R.c[_E123]
        return Vec3(-R.c[_T230] / w, R.c[_T130] / w, -R.c[_T120] / w, 0)


# ---------------------------------------------------------------- Motor2
# PGA2 blade masks (bits: e1=1, e2=2, e0=4)
comptime _A12 = 0b011  # e1e2
comptime _A10 = 0b101  # e1e0
comptime _A20 = 0b110  # e2e0
comptime _E12 = 0b011


@fieldwise_init
struct Motor2(Copyable, ImplicitlyCopyable, Movable, Deinitable):
    """2D rigid motion — 4 floats (rotation angle + translation)."""

    var s: Real  # scalar
    var b12: Real  # e1e2 (rotation)
    var b10: Real  # e1e0 (ideal)
    var b20: Real  # e2e0

    @staticmethod
    def identity() -> Self:
        return Self(1, 0, 0, 0)

    @always_inline
    def to_mv(self) -> PGA2:
        var m = PGA2()
        m.c[0] = self.s
        m.c[_A12] = self.b12
        m.c[_A10] = self.b10
        m.c[_A20] = self.b20
        return m^

    @staticmethod
    @always_inline
    def from_mv(m: PGA2) -> Self:
        return Self(m.c[0], m.c[_A12], m.c[_A10], m.c[_A20])

    @staticmethod
    def from_angle(angle: Real) -> Self:
        """Rotor about the origin: cos(θ/2) - sin(θ/2) e12 (CCW-positive)."""
        return Self(cos(angle * 0.5), -sin(angle * 0.5), 0, 0)

    @staticmethod
    def from_translation(t: Vec2) -> Self:
        return Self(1, 0, t[0] * 0.5, t[1] * 0.5)

    @staticmethod
    def from_angle_translation(angle: Real, t: Vec2) -> Self:
        return Self.from_translation(t) * Self.from_angle(angle)

    @always_inline
    def __mul__(self, o: Self) -> Self:
        return Self.from_mv(self.to_mv() * o.to_mv())

    @always_inline
    def reverse(self) -> Self:
        return Self(self.s, -self.b12, -self.b10, -self.b20)

    @always_inline
    def norm_sq(self) -> Real:
        return self.s * self.s + self.b12 * self.b12

    @always_inline
    def normalized(self) -> Self:
        var n = 1.0 / sqrt(self.norm_sq())
        return Self(self.s * n, self.b12 * n, self.b10 * n, self.b20 * n)

    @always_inline
    def apply_point(self, pt: Vec2) -> Vec2:
        """Sandwich on the 2D point bivector `e12 + x e20 - y e10`."""
        var P = PGA2()
        P.c[_E12] = 1
        P.c[_A20] = pt[0]
        P.c[_A10] = -pt[1]
        var R = self.to_mv() * P * self.to_mv().reverse()
        var w = R.c[_E12]
        return Vec2(R.c[_A20] / w, -R.c[_A10] / w)
