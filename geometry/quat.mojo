"""Quaternion rotations + 3D TRS composition.

A `Quat` is stored as four scalars `(x, y, z, w)` — never a width-4 SIMD field
that gets reallocated. Vector rotation uses the expanded
`v + 2w(qv×v) + 2(qv×(qv×v))` form (one cross helper), not the `q·v·q⁻¹` double
Hamilton product. Depends on `mat.mojo` for matrix conversion, and hosts
`compose_trs4` (a 3D TRS needs a quaternion) to keep `mat.mojo` quaternion-free.
"""

from std.math import sqrt, acos
from .trig import sin, cos
from .vec import WorldType, Real, Vec3, normalize, cross
from .mat import Mat3, Mat4


@fieldwise_init
struct Quat(Copyable, ImplicitlyCopyable, Movable, Deinitable):
    var x: Real
    var y: Real
    var z: Real
    var w: Real

    @staticmethod
    def identity() -> Self:
        return Self(0, 0, 0, 1)

    @staticmethod
    def from_axis_angle(axis: Vec3, angle: Real) -> Self:
        var n = normalize(axis)
        var half = angle * Real(0.5)
        var s = sin(half)
        return Self(n[0] * s, n[1] * s, n[2] * s, cos(half))

    @staticmethod
    def from_euler(rx: Real, ry: Real, rz: Real) -> Self:
        var qx = Self.from_axis_angle(Vec3(1, 0, 0, 0), rx)
        var qy = Self.from_axis_angle(Vec3(0, 1, 0, 0), ry)
        var qz = Self.from_axis_angle(Vec3(0, 0, 1, 0), rz)
        return qz * (qy * qx)

    def __mul__(self, o: Self) -> Self:
        var w = self.w * o.w - self.x * o.x - self.y * o.y - self.z * o.z
        var x = self.w * o.x + self.x * o.w + self.y * o.z - self.z * o.y
        var y = self.w * o.y - self.x * o.z + self.y * o.w + self.z * o.x
        var z = self.w * o.z + self.x * o.y - self.y * o.x + self.z * o.w
        return Self(x, y, z, w)

    def conjugate(self) -> Self:
        return Self(-self.x, -self.y, -self.z, self.w)

    def norm(self) -> Real:
        return sqrt(
            self.x * self.x + self.y * self.y + self.z * self.z + self.w * self.w
        )

    def normalized(self) -> Self:
        var n = self.norm()
        if n == 0:
            return Self.identity()
        var inv = Real(1) / n
        return Self(self.x * inv, self.y * inv, self.z * inv, self.w * inv)

    def rotate(self, v: Vec3) -> Vec3:
        var qv = Vec3(self.x, self.y, self.z, 0)
        var t = cross(qv, v) * Real(2)
        return v + t * self.w + cross(qv, t)

    def to_mat3(self) -> Mat3:
        var x = self.x
        var y = self.y
        var z = self.z
        var w = self.w
        var r = Mat3.identity()
        r.set(0, 0, 1 - 2 * (y * y + z * z))
        r.set(0, 1, 2 * (x * y - w * z))
        r.set(0, 2, 2 * (x * z + w * y))
        r.set(1, 0, 2 * (x * y + w * z))
        r.set(1, 1, 1 - 2 * (x * x + z * z))
        r.set(1, 2, 2 * (y * z - w * x))
        r.set(2, 0, 2 * (x * z - w * y))
        r.set(2, 1, 2 * (y * z + w * x))
        r.set(2, 2, 1 - 2 * (x * x + y * y))
        return r^

    def to_mat4(self) -> Mat4:
        var m3 = self.to_mat3()
        var r = Mat4.identity()
        comptime for i in range(3):
            comptime for j in range(3):
                r.set(i, j, m3.get(i, j))
        return r^


def quat_from_mat3(m: Mat3) -> Quat:
    """Recover a quaternion from a rotation matrix (Shepperd's method)."""
    var m00 = m.get(0, 0)
    var m11 = m.get(1, 1)
    var m22 = m.get(2, 2)
    var trace = m00 + m11 + m22
    if trace > 0:
        var s = sqrt(trace + 1) * 2  # s = 4*qw
        var w = Real(0.25) * s
        var x = (m.get(2, 1) - m.get(1, 2)) / s
        var y = (m.get(0, 2) - m.get(2, 0)) / s
        var z = (m.get(1, 0) - m.get(0, 1)) / s
        return Quat(x, y, z, w)
    elif Bool(m00 > m11) and Bool(m00 > m22):
        var s = sqrt(1 + m00 - m11 - m22) * 2  # s = 4*qx
        var w = (m.get(2, 1) - m.get(1, 2)) / s
        var x = Real(0.25) * s
        var y = (m.get(0, 1) + m.get(1, 0)) / s
        var z = (m.get(0, 2) + m.get(2, 0)) / s
        return Quat(x, y, z, w)
    elif m11 > m22:
        var s = sqrt(1 + m11 - m00 - m22) * 2  # s = 4*qy
        var w = (m.get(0, 2) - m.get(2, 0)) / s
        var x = (m.get(0, 1) + m.get(1, 0)) / s
        var y = Real(0.25) * s
        var z = (m.get(1, 2) + m.get(2, 1)) / s
        return Quat(x, y, z, w)
    else:
        var s = sqrt(1 + m22 - m00 - m11) * 2  # s = 4*qz
        var w = (m.get(1, 0) - m.get(0, 1)) / s
        var x = (m.get(0, 2) + m.get(2, 0)) / s
        var y = (m.get(1, 2) + m.get(2, 1)) / s
        var z = Real(0.25) * s
        return Quat(x, y, z, w)


def slerp(a: Quat, b: Quat, t: Real) -> Quat:
    """Shortest-arc spherical interpolation; falls back to nlerp very near t≈1."""
    var d = a.x * b.x + a.y * b.y + a.z * b.z + a.w * b.w
    var bx = b.x
    var by = b.y
    var bz = b.z
    var bw = b.w
    if d < 0:
        d = -d
        bx = -bx
        by = -by
        bz = -bz
        bw = -bw
    if d > Real(0.9995):
        var rx = a.x + (bx - a.x) * t
        var ry = a.y + (by - a.y) * t
        var rz = a.z + (bz - a.z) * t
        var rw = a.w + (bw - a.w) * t
        return Quat(rx, ry, rz, rw).normalized()
    var theta0 = acos(d)
    var theta = theta0 * t
    var sin0 = sin(theta0)
    var s0 = sin(theta0 - theta) / sin0
    var s1 = sin(theta) / sin0
    return Quat(
        a.x * s0 + bx * s1,
        a.y * s0 + by * s1,
        a.z * s0 + bz * s1,
        a.w * s0 + bw * s1,
    )


def compose_trs4(t: Vec3, q: Quat, s: Vec3) -> Mat4:
    """3D TRS: translate `t`, rotate `q`, scale `s` -> affine Mat4."""
    var rot = q.to_mat3()
    var r = Mat4.identity()
    comptime for i in range(3):
        comptime for j in range(3):
            r.set(i, j, rot.get(i, j) * s[j])
    r.set(0, 3, t[0])
    r.set(1, 3, t[1])
    r.set(2, 3, t[2])
    return r^
