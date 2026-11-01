"""A rigid body with torque as a `Coupler` part (ROADMAP 17.61).

`BallPart` is one immersed point at the centre of mass, so the air exerts no
torque on it. `RigidPart` immerses a set of body-fixed points. Each point
feels a linear drag F_i = c (u_i - v_i) toward the air velocity u_i it
receives, with v_i = v + w x r_i, and the whole step is solved implicitly for
the new linear and angular velocity (a 6 x 6 system, so any c dt / m is
stable):

    (m + n c dt) v' - c dt sum[r_i]x w'           = m v + c dt sum u_i
    c dt sum[r_i]x v' + (I + c dt sum S_i) w'     = I w + c dt sum r_i x u_i

with S_i = (r_i . r_i) 1 - r_i r_i^T and I the world-frame inertia of the
body at the start of the step. Gravity and the pose update (symplectic
Euler, q += dt/2 (0, w') q) follow. Same wire format as `ClothPart` (it
receives 3 reals per point and sends 9), so it plugs into `AirPart`.
"""

from std.math import sqrt
from geometry.vec import Real, Vec3, cross, dot
from geometry.quat import Quat
from .coupler import CoupledPart
from .state_io import StateWriter, StateReader


def _solve6(mut a: List[Real], mut b: List[Real]):
    """Gauss elimination with partial pivoting on a 6 x 6 system (row-major
    `a`, in place); the solution replaces `b`. A pivot that cancels below
    `1e-7` of the largest entry (c dt / m ~ 1e7 does this: the no-FMA x86-64
    reference build hits exactly 0, 17.89 / #75) is held at that floor, so the
    answer stays finite and bounded instead of NaN."""
    var scale = Real(0)
    for i in range(36):
        scale = max(scale, abs(a[i]))
    var floor = scale * 1e-7
    for col in range(6):
        var piv = col
        for r in range(col + 1, 6):
            if abs(a[r * 6 + col]) > abs(a[piv * 6 + col]):
                piv = r
        if piv != col:
            for c in range(6):
                var t = a[col * 6 + c]
                a[col * 6 + c] = a[piv * 6 + c]
                a[piv * 6 + c] = t
            var tb = b[col]
            b[col] = b[piv]
            b[piv] = tb
        var d = a[col * 6 + col]
        if abs(d) < floor:
            d = floor if d >= 0 else -floor
            a[col * 6 + col] = d
        for r in range(col + 1, 6):
            var f = a[r * 6 + col] / d
            if f == 0:
                continue
            for c in range(col, 6):
                a[r * 6 + c] -= f * a[col * 6 + c]
            b[r] -= f * b[col]
    for r in range(5, -1, -1):
        var s = b[r]
        for c in range(r + 1, 6):
            s -= a[r * 6 + c] * b[c]
        b[r] = s / a[r * 6 + r]


struct RigidPart(CoupledPart):
    var x: Vec3
    var q: Quat
    var v: Vec3
    var w: Vec3
    var m: Real
    var inertia: Vec3  # principal moments, body frame
    var c: Real  # drag per point, kg / s
    var gravity: Vec3
    var local: List[Vec3]  # immersed points, body frame
    var air_u: List[Vec3]
    var x_drag: List[Vec3]
    var jv: List[Vec3]
    var received: Vec3
    var total: Vec3
    var _x: Vec3
    var _q: Quat
    var _v: Vec3
    var _w: Vec3
    var _xd: List[Vec3]
    var _jv: List[Vec3]

    def __init__(out self, x: Vec3, q: Quat, m: Real, inertia: Vec3, c: Real, gravity: Vec3, var local: List[Vec3]) raises:
        if not (m > 0) or not (c >= 0) or not (inertia[0] > 0 and inertia[1] > 0 and inertia[2] > 0) or len(local) < 1:
            raise Error("RigidPart: m > 0, principal moments > 0, c >= 0 and at least one point")
        self.x = x
        self.q = q
        self.v = Vec3(0, 0, 0, 0)
        self.w = Vec3(0, 0, 0, 0)
        self.m = m
        self.inertia = inertia
        self.c = c
        self.gravity = gravity
        self.local = local^
        var n = len(self.local)
        self.air_u = List[Vec3](length=n, fill=Vec3(0, 0, 0, 0))
        self.x_drag = List[Vec3]()
        for i in range(n):
            self.x_drag.append(x + q.rotate(self.local[i]))
        self.jv = List[Vec3](length=n, fill=Vec3(0, 0, 0, 0))
        self.received = Vec3(0, 0, 0, 0)
        self.total = Vec3(0, 0, 0, 0)
        self._x = x
        self._q = q
        self._v = self.v
        self._w = self.w
        self._xd = self.x_drag.copy()
        self._jv = self.jv.copy()

    def point(self, i: Int) -> Vec3:
        return self.x + self.q.rotate(self.local[i])

    def _inertia_world(self, e: Vec3) -> Vec3:
        """I_world e = R diag(I) R^T e."""
        var b = self.q.conjugate().rotate(e)
        return self.q.rotate(Vec3(self.inertia[0] * b[0], self.inertia[1] * b[1], self.inertia[2] * b[2], 0))

    def advance(mut self, dt: Real) raises:
        var n = len(self.local)
        var cd = self.c * dt
        var a = List[Real](length=36, fill=0)
        var b = List[Real](length=6, fill=0)
        # world-frame inertia columns
        var ex = self._inertia_world(Vec3(1, 0, 0, 0))
        var ey = self._inertia_world(Vec3(0, 1, 0, 0))
        var ez = self._inertia_world(Vec3(0, 0, 1, 0))
        var iw = List[Real](length=9, fill=0)
        for r in range(3):
            iw[r * 3 + 0] = ex[r]
            iw[r * 3 + 1] = ey[r]
            iw[r * 3 + 2] = ez[r]
        var sum_u = Vec3(0, 0, 0, 0)
        var sum_ru = Vec3(0, 0, 0, 0)
        var rs = List[Vec3]()
        for i in range(n):
            var r = self.q.rotate(self.local[i])
            rs.append(r)
            sum_u = sum_u + self.air_u[i]
            sum_ru = sum_ru + cross(r, self.air_u[i])
            # [r]x blocks: A12 -= cd [r]x, A21 += cd [r]x
            var rx = List[Real](length=9, fill=0)
            rx[1] = -r[2]
            rx[2] = r[1]
            rx[3] = r[2]
            rx[5] = -r[0]
            rx[6] = -r[1]
            rx[7] = r[0]
            var rr = dot(r, r)
            for p in range(3):
                for q in range(3):
                    a[p * 6 + 3 + q] -= cd * rx[p * 3 + q]
                    a[(3 + p) * 6 + q] += cd * rx[p * 3 + q]
                    var s = (rr if p == q else Real(0)) - r[p] * r[q]
                    a[(3 + p) * 6 + 3 + q] += cd * s
        for p in range(3):
            a[p * 6 + p] += self.m + Real(n) * cd
            for q in range(3):
                a[(3 + p) * 6 + 3 + q] += iw[p * 3 + q]
        var mv = self.v * self.m + sum_u * cd
        var iww = self._inertia_world(self.w) + sum_ru * cd
        for p in range(3):
            b[p] = mv[p]
            b[3 + p] = iww[p]
        _solve6(a, b)
        var v_new = Vec3(b[0], b[1], b[2], 0)
        var w_new = Vec3(b[3], b[4], b[5], 0)
        self.received = Vec3(0, 0, 0, 0)
        for i in range(n):
            self.x_drag[i] = self.x + rs[i]
            var vi = v_new + cross(w_new, rs[i])
            self.jv[i] = (self.air_u[i] - vi) * cd
            self.received = self.received + self.jv[i]
        self.total = self.total + self.received
        self.v = v_new + self.gravity * dt
        self.w = w_new
        self.x = self.x + self.v * dt
        var dq = Quat(w_new[0] * 0.5 * dt, w_new[1] * 0.5 * dt, w_new[2] * 0.5 * dt, 0) * self.q
        self.q = Quat(self.q.x + dq.x, self.q.y + dq.y, self.q.z + dq.z, self.q.w + dq.w).normalized()

    def send(self) -> List[Real]:
        var n = len(self.local)
        var out = List[Real](capacity=9 * n)
        for i in range(n):
            var p = self.point(i)
            for c in range(3):
                out.append(p[c])
            for c in range(3):
                out.append(self.x_drag[i][c])
            for c in range(3):
                out.append(self.jv[i][c])
        return out^

    def recv(mut self, data: List[Real]):
        for i in range(len(self.local)):
            self.air_u[i] = Vec3(data[3 * i], data[3 * i + 1], data[3 * i + 2], 0)

    def impulse(self) -> List[Real]:
        return [self.received[0], self.received[1], self.received[2]]

    def save(mut self):
        self._x = self.x
        self._q = self.q
        self._v = self.v
        self._w = self.w
        self._xd = self.x_drag.copy()
        self._jv = self.jv.copy()

    def restore(mut self):
        self.x = self._x
        self.q = self._q
        self.v = self._v
        self.w = self._w
        self.x_drag = self._xd.copy()
        self.jv = self._jv.copy()

    def write_state[W: StateWriter](self, mut w: W):
        w.wv(self.x)
        w.wf(self.q.x)
        w.wf(self.q.y)
        w.wf(self.q.z)
        w.wf(self.q.w)
        w.wv(self.v)
        w.wv(self.w)
        w.wi(len(self.local))
        for i in range(len(self.local)):
            w.wv(self.air_u[i])
            w.wv(self.x_drag[i])
            w.wv(self.jv[i])
        w.wv(self.received)
        w.wv(self.total)

    def read_state[R: StateReader](mut self, mut r: R) raises:
        self.x = r.rv()
        var qx = r.rf()
        var qy = r.rf()
        var qz = r.rf()
        var qw = r.rf()
        self.q = Quat(qx, qy, qz, qw)
        self.v = r.rv()
        self.w = r.rv()
        var n = r.ri()
        if n != len(self.local):
            raise Error("RigidPart.read_state: point count differs")
        for i in range(n):
            self.air_u[i] = r.rv()
            self.x_drag[i] = r.rv()
            self.jv[i] = r.rv()
        self.received = r.rv()
        self.total = r.rv()
