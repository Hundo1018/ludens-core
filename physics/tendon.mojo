"""Tendons: one tension acting on many joints at once.

A tendon is a length function `L(q)` plus the rule that a tension `F` pulling
it produces joint torques `tau = -F dL/dq`. Everything here follows from that
one line, which is also what makes tendons worth having as a primitive rather
than as bookkeeping in the caller: the coupling is expressed once, in the
geometry, and the torques fall out of it consistently.

Two kinds, differing only in how `L` is computed:

  FixedTendon    L = sum(c_i q_i). The moment arms ARE the coefficients, so
                 this is exact and free. It expresses gearing, differentials
                 and coupled fingers.
  SpatialTendon  L = the length of a path through attachment sites on links,
                 optionally routed around obstacles. The moment arms come from
                 the point Jacobians the contact solver already needs.

The wrapping deserves a note, because the reason it does not complicate the
moment arms is not obvious. A tendon over a sphere touches at tangent points
whose positions depend on `q`, so one would expect `dL/dq` to pick up terms
through them. It does not: the path is the SHORTEST one subject to lying on
the sphere, so `L` is stationary with respect to moving a tangent point along
the surface, and the only admissible variations are along the surface. The
tangent-point terms vanish identically. That is why `moment_arms` sums over
attachment sites only, and why the finite-difference test — which differences
the full length including the arc — is a real check on that claim rather than
a restatement of it.

Wrap obstacles are world-fixed here. A wrap body rigidly attached to a moving
link would add a term through the obstacle's own motion; that is a further
step, not a hidden assumption in what is written.
"""

from std.math import sqrt, acos
from geometry.vec import Real, Vec3, dot, length, normalize
from physics.chain import Chain


@fieldwise_init
struct TendonSite(Copyable, ImplicitlyCopyable, Movable):
    """An attachment point: `local` on `link`."""

    var link: Int
    var local: Vec3


@fieldwise_init
struct WrapSphere(Copyable, ImplicitlyCopyable, Movable):
    """A world-fixed obstacle the path must go around. `radius <= 0` disables
    it, so a segment with no obstacle is the same code path with no branch at
    the call site."""

    var center: Vec3
    var radius: Real

    @staticmethod
    def none() -> Self:
        return Self(Vec3(0, 0, 0, 0), -1)

    def active(self) -> Bool:
        return self.radius > 0


struct FixedTendon(Copyable, Movable):
    """`L = sum(coef_i * q_i)` — a linear constraint between joints."""

    var joints: List[Int]
    var coefs: List[Real]

    def __init__(out self):
        self.joints = List[Int]()
        self.coefs = List[Real]()

    def add(mut self, joint: Int, coef: Real):
        self.joints.append(joint)
        self.coefs.append(coef)

    def length(self, q: List[Real]) -> Real:
        var l = Real(0)
        for k in range(len(self.joints)):
            l += self.coefs[k] * q[self.joints[k]]
        return l

    def velocity(self, qd: List[Real]) -> Real:
        return self.length(qd)  # dL/dt is the same linear form on q̇

    def apply_tension(self, f: Real, mut tau: List[Real]):
        """`tau_i -= F * c_i`. Accumulates, like the actuator bank, so several
        tendons and an actuator can drive the same joint."""
        for k in range(len(self.joints)):
            tau[self.joints[k]] -= f * self.coefs[k]


def _seg_path(
    a: Vec3, b: Vec3, w: WrapSphere
) -> Tuple[Real, Vec3, Vec3, Bool]:
    """Length of the shortest path from `a` to `b` avoiding the sphere, plus
    the unit directions leaving `a` and arriving at `b`.

    Straight when the segment clears the obstacle. When it does not, the path
    is tangent-arc-tangent in the plane of `a`, `b` and the centre:

        L = sqrt(da^2 - r^2) + sqrt(db^2 - r^2) + r * (theta - alpha - beta)

    with `alpha = acos(r/da)` the half-angle the tangent subtends. The wrap
    engages exactly when that arc term turns positive, and at that instant the
    straight line is tangent to the sphere and the two formulas agree — so the
    length is continuous across the transition rather than jumping, which is
    what keeps the force finite when a tendon first touches an obstacle."""
    var d = b - a
    var lab = length(d)
    if not w.active() or lab < 1e-12:
        var u = d * (1.0 / (lab + 1e-30))
        return (lab, u, u, False)

    var oa = a - w.center
    var ob = b - w.center
    var da = length(oa)
    var db = length(ob)
    if da <= w.radius or db <= w.radius:
        # an endpoint is inside the obstacle: no well-posed wrap, stay straight
        var u = d * (1.0 / lab)
        return (lab, u, u, False)

    var ct = dot(oa, ob) / (da * db)
    ct = 1.0 if ct > 1.0 else (-1.0 if ct < -1.0 else ct)
    var theta = Real(acos(Float64(ct)))
    var alpha = Real(acos(Float64(w.radius / da)))
    var beta = Real(acos(Float64(w.radius / db)))
    var arc = theta - alpha - beta
    if arc <= 0:
        var u = d * (1.0 / lab)
        return (lab, u, u, False)

    var ta = sqrt(da * da - w.radius * w.radius)
    var tb = sqrt(db * db - w.radius * w.radius)
    var total = ta + tb + w.radius * arc

    # tangent points: rotate `oa` toward `ob` by alpha within their plane
    var n = _plane_normal(oa, ob)
    var t1 = w.center + _rotate_about(oa, n, alpha) * (w.radius / da)
    var t2 = w.center + _rotate_about(ob, n, -beta) * (w.radius / db)
    return (total, normalize(t1 - a), normalize(b - t2), True)


def _plane_normal(u: Vec3, v: Vec3) -> Vec3:
    var n = Vec3(
        u[1] * v[2] - u[2] * v[1],
        u[2] * v[0] - u[0] * v[2],
        u[0] * v[1] - u[1] * v[0],
        0,
    )
    var ln = length(n)
    if ln < 1e-9:  # collinear: any perpendicular will do
        var t = Vec3(1, 0, 0, 0) if abs(u[0]) < 0.9 else Vec3(0, 1, 0, 0)
        n = Vec3(
            u[1] * t[2] - u[2] * t[1],
            u[2] * t[0] - u[0] * t[2],
            u[0] * t[1] - u[1] * t[0],
            0,
        )
        ln = length(n)
    return n * (1.0 / ln)


def _rotate_about(v: Vec3, axis: Vec3, ang: Real) -> Vec3:
    """Rodrigues, spelled out — the tangent points need one rotation each and
    pulling in a quaternion for it would cost more than it saves."""
    var c = Real(0)
    var s = Real(0)
    _cos_sin(ang, c, s)
    var cr = Vec3(
        axis[1] * v[2] - axis[2] * v[1],
        axis[2] * v[0] - axis[0] * v[2],
        axis[0] * v[1] - axis[1] * v[0],
        0,
    )
    return v * c + cr * s + axis * (dot(axis, v) * (1 - c))


def _cos_sin(a: Real, mut c: Real, mut s: Real):
    from geometry.trig import cos, sin

    c = cos(a)
    s = sin(a)


struct SpatialTendon(Copyable, Movable):
    """A path through attachment sites, with an optional obstacle per segment.

    `wraps[k]` guards the segment from site `k` to site `k+1`."""

    var sites: List[TendonSite]
    var wraps: List[WrapSphere]

    def __init__(out self):
        self.sites = List[TendonSite]()
        self.wraps = List[WrapSphere]()

    def add_site(mut self, link: Int, local: Vec3):
        self.sites.append(TendonSite(link, local))
        if len(self.sites) > 1:
            self.wraps.append(WrapSphere.none())

    def wrap_last(mut self, center: Vec3, radius: Real) raises:
        """Put an obstacle on the segment just added."""
        if len(self.wraps) == 0:
            raise Error("no segment to wrap yet")
        self.wraps[len(self.wraps) - 1] = WrapSphere(center, radius)

    def length(self, c: Chain) -> Real:
        var pts = self._points(c)
        var total = Real(0)
        for k in range(len(pts) - 1):
            var r = _seg_path(pts[k], pts[k + 1], self.wraps[k])
            total += r[0]
        return total

    def _points(self, c: Chain) -> List[Vec3]:
        var pts = List[Vec3]()
        for k in range(len(self.sites)):
            pts.append(c.point_world(self.sites[k].link, self.sites[k].local))
        return pts^

    def moment_arms(self, c: Chain) -> List[Real]:
        """`dL/dq`, from the path directions at each attachment site.

        Site `k` sees the tendon leave toward `k+1` and arrive from `k-1`; the
        length grows with `q_i` at the rate `(u_in - u_out) . dp_k/dq_i`. The
        Jacobian columns are the same ones the contact solver uses, so a bug in
        either shows up in both."""
        var n = len(c.links)
        var out = List[Real]()
        for _ in range(n):
            out.append(0)
        var pts = self._points(c)
        var m = len(pts)
        for k in range(m):
            var u_out = Vec3(0, 0, 0, 0)
            var u_in = Vec3(0, 0, 0, 0)
            if k + 1 < m:
                var r = _seg_path(pts[k], pts[k + 1], self.wraps[k])
                u_out = r[1]
            if k > 0:
                var r = _seg_path(pts[k - 1], pts[k], self.wraps[k - 1])
                u_in = r[2]
            var w = u_in - u_out
            if length(w) < 1e-12:
                continue
            var jx = c.point_jacobian(self.sites[k].link, self.sites[k].local, Vec3(1, 0, 0, 0))
            var jy = c.point_jacobian(self.sites[k].link, self.sites[k].local, Vec3(0, 1, 0, 0))
            var jz = c.point_jacobian(self.sites[k].link, self.sites[k].local, Vec3(0, 0, 1, 0))
            for i in range(n):
                out[i] += w[0] * jx[i] + w[1] * jy[i] + w[2] * jz[i]
        return out^

    def apply_tension(self, c: Chain, f: Real, mut tau: List[Real]):
        """`tau -= F dL/dq`. A positive tension SHORTENS the tendon, which is
        the sign that makes the power balance come out: the tendon does work
        `-F dL/dt` on the mechanism."""
        var ma = self.moment_arms(c)
        for i in range(len(tau)):
            tau[i] -= f * ma[i]

    def velocity(self, c: Chain) -> Real:
        """`dL/dt` from the moment arms and the joint rates."""
        var ma = self.moment_arms(c)
        var v = Real(0)
        for i in range(len(ma)):
            v += ma[i] * c.qd[i]
        return v
