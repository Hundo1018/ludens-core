"""Dimension-generic dense linear algebra: square matrices + affine helpers.

Matrices are stored **row-major in a flat `Array[Real, n*n]`** and every
operation is a scalar `comptime for` loop — never width-3 SIMD. This is the same
discipline as `vec.mojo`: width-3 `reduce_*`/realloc silently drops a lane in
this nightly, so we never put a width-3 vector in a reallocating slot. A `Mat3`
is treated as a 2D affine transform (implicit last row `[0,0,1]`); a `Mat4` as a
3D affine (implicit last row `[0,0,0,1]`).

Width-4 SIMD *is* safe, so `transform_point4_simd` is offered as the SIMD fast
path for the scalar-vs-SIMD benchmark axis.

`Quat` lives in `quat.mojo`, which depends on this module (for matrix
conversion); `compose_trs4` (needs a quaternion) therefore lives there too, to
keep this module quaternion-free and break the dependency cycle.
"""

from .trig import sin, cos
from .vec import WorldType, Real, Vec2, Vec3, PadW


struct Mat[n: Int](Copyable, ImplicitlyCopyable, Movable, Deinitable):
    """Square `n×n` matrix, row-major. Aliased as `Mat2`/`Mat3`/`Mat4`."""

    comptime SIZE = Self.n * Self.n
    var m: Array[Real, Self.SIZE]

    def __init__(out self):
        self.m = Array[Real, Self.SIZE](fill=Real(0))

    def __init__(out self, *, copy: Self):
        """Explicit copy: `Array` stopped being `ImplicitlyCopyable` in
        Mojo 1.0, so a struct holding one can no longer have its copy
        constructor synthesised."""
        self.m = copy.m.copy()

    @staticmethod
    def zero() -> Self:
        return Self()

    @staticmethod
    def identity() -> Self:
        var r = Self()
        comptime for i in range(Self.n):
            r.m[i * Self.n + i] = Real(1)
        return r^

    def get(self, row: Int, col: Int) -> Real:
        return self.m[row * Self.n + col]

    def set(mut self, row: Int, col: Int, v: Real):
        self.m[row * Self.n + col] = v

    def __mul__(self, o: Self) -> Self:
        var r = Self()
        comptime for i in range(Self.n):
            comptime for j in range(Self.n):
                var s = Real(0)
                comptime for k in range(Self.n):
                    s += self.m[i * Self.n + k] * o.m[k * Self.n + j]
                r.m[i * Self.n + j] = s
        return r^

    def transpose(self) -> Self:
        var r = Self()
        comptime for i in range(Self.n):
            comptime for j in range(Self.n):
                r.m[j * Self.n + i] = self.m[i * Self.n + j]
        return r^

    def row(self, i: Int) -> SIMD[WorldType, PadW[Self.n]]:
        var v = SIMD[WorldType, PadW[Self.n]](0)
        comptime for k in range(Self.n):
            v[k] = self.m[i * Self.n + k]
        return v


comptime Mat2 = Mat[2]
comptime Mat3 = Mat[3]
comptime Mat4 = Mat[4]


# --- affine transforms ------------------------------------------------------
# A Mat3 carries a 2D affine map; a Mat4 a 3D affine map. `point` applies the
# translation column, `dir` does not.

def transform_point3(mt: Mat3, p: Vec2) -> Vec2:
    var res = Vec2(0)
    res[0] = mt.get(0, 0) * p[0] + mt.get(0, 1) * p[1] + mt.get(0, 2)
    res[1] = mt.get(1, 0) * p[0] + mt.get(1, 1) * p[1] + mt.get(1, 2)
    return res


def transform_dir3(mt: Mat3, v: Vec2) -> Vec2:
    var res = Vec2(0)
    res[0] = mt.get(0, 0) * v[0] + mt.get(0, 1) * v[1]
    res[1] = mt.get(1, 0) * v[0] + mt.get(1, 1) * v[1]
    return res


def transform_point4(mt: Mat4, p: Vec3) -> Vec3:
    var res = Vec3(0)
    comptime for i in range(3):
        res[i] = (
            mt.get(i, 0) * p[0]
            + mt.get(i, 1) * p[1]
            + mt.get(i, 2) * p[2]
            + mt.get(i, 3)
        )
    return res


def transform_dir4(mt: Mat4, v: Vec3) -> Vec3:
    var res = Vec3(0)
    comptime for i in range(3):
        res[i] = mt.get(i, 0) * v[0] + mt.get(i, 1) * v[1] + mt.get(i, 2) * v[2]
    return res


def transform_point4_simd(mt: Mat4, p: Vec3) -> Vec3:
    """Same as `transform_point4` but each row·point is a width-4 SIMD dot.

    Width-4 `reduce_add` is safe (only width-3 is broken), so this is the SIMD
    fast path used by the linear-algebra benchmark.
    """
    var ph = SIMD[WorldType, 4](p[0], p[1], p[2], 1)
    var res = Vec3(0)
    comptime for i in range(3):
        var rowv = SIMD[WorldType, 4](
            mt.get(i, 0), mt.get(i, 1), mt.get(i, 2), mt.get(i, 3)
        )
        res[i] = (rowv * ph).reduce_add()
    return res


def affine_inverse3(mt: Mat3) -> Mat3:
    """Inverse of a 2D affine map: invert the 2×2 linear block, re-map the offset."""
    var a = mt.get(0, 0)
    var b = mt.get(0, 1)
    var c = mt.get(1, 0)
    var d = mt.get(1, 1)
    var det = a * d - b * c
    var inv = Real(0)
    if det != 0:
        inv = Real(1) / det
    var r = Mat3.identity()
    r.set(0, 0, d * inv)
    r.set(0, 1, -b * inv)
    r.set(1, 0, -c * inv)
    r.set(1, 1, a * inv)
    var tx = mt.get(0, 2)
    var ty = mt.get(1, 2)
    r.set(0, 2, -(r.get(0, 0) * tx + r.get(0, 1) * ty))
    r.set(1, 2, -(r.get(1, 0) * tx + r.get(1, 1) * ty))
    return r^


def affine_inverse4(mt: Mat4) -> Mat4:
    """Inverse of a 3D affine map: invert the 3×3 linear block (cofactors), re-map the offset."""
    var a = mt.get(0, 0)
    var b = mt.get(0, 1)
    var c = mt.get(0, 2)
    var d = mt.get(1, 0)
    var e = mt.get(1, 1)
    var f = mt.get(1, 2)
    var g = mt.get(2, 0)
    var h = mt.get(2, 1)
    var ii = mt.get(2, 2)
    var det = a * (e * ii - f * h) - b * (d * ii - f * g) + c * (d * h - e * g)
    var inv = Real(0)
    if det != 0:
        inv = Real(1) / det
    var r = Mat4.identity()
    r.set(0, 0, (e * ii - f * h) * inv)
    r.set(0, 1, (c * h - b * ii) * inv)
    r.set(0, 2, (b * f - c * e) * inv)
    r.set(1, 0, (f * g - d * ii) * inv)
    r.set(1, 1, (a * ii - c * g) * inv)
    r.set(1, 2, (c * d - a * f) * inv)
    r.set(2, 0, (d * h - e * g) * inv)
    r.set(2, 1, (b * g - a * h) * inv)
    r.set(2, 2, (a * e - b * d) * inv)
    var tx = mt.get(0, 3)
    var ty = mt.get(1, 3)
    var tz = mt.get(2, 3)
    r.set(0, 3, -(r.get(0, 0) * tx + r.get(0, 1) * ty + r.get(0, 2) * tz))
    r.set(1, 3, -(r.get(1, 0) * tx + r.get(1, 1) * ty + r.get(1, 2) * tz))
    r.set(2, 3, -(r.get(2, 0) * tx + r.get(2, 1) * ty + r.get(2, 2) * tz))
    return r^


def compose_trs3(t: Vec2, angle: Real, s: Vec2) -> Mat3:
    """2D TRS: translate `t`, rotate `angle` (radians), scale `s` -> affine Mat3."""
    var ca = cos(angle)
    var sa = sin(angle)
    var r = Mat3.identity()
    r.set(0, 0, ca * s[0])
    r.set(0, 1, -sa * s[1])
    r.set(1, 0, sa * s[0])
    r.set(1, 1, ca * s[1])
    r.set(0, 2, t[0])
    r.set(1, 2, t[1])
    return r^
