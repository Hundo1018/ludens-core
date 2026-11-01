"""Reduced-coordinate articulated chains (the Featherstone direction).

A serial chain of revolute joints integrated in JOINT space: n coordinates
for n joints, constraints exact by construction — the reduced-coordinate
counterpart to `ContactScene6`'s maximal-coordinate hinge joints (soft
constraints). Two completely independent formulations of the same mechanics,
which makes their agreement a strong cross-validation gate
(`test_chain`), and their cost difference a fair benchmark.

This slice implements CRBA + RNEA (mass matrix + bias forces) with the
COMPACT spatial-inertia form {m, h = m·c, I_o (3x3 about the link origin)} —
rigid and composite inertias both stay in this form for a serial chain, so no
6x6 matrices appear anywhere. Forward kinematics runs on PGA motors
(`Motor3`), keeping the engine's "Featherstone spatial vectors are motors"
thesis literal. The O(n) articulated-body algorithm (ABA) is the follow-up;
CRBA+RNEA is O(n^2)/O(n^3), which at game chain lengths is already fast.

Conventions (Featherstone RBDA): all spatial quantities in the LINK frame;
joint i rotates about `axis` (unit, link frame); the link frame origin sits ON
the joint; the child pivot is at `pivot` in this link's frame.
"""

from std.math import sqrt, atan2
from geometry.trig import cos, sin
from geometry.vec import Real, Vec3, dot, cross, tangent_basis, length
from geometry.quat import Quat
from geometry.motor import Motor3
from numerics.dense import solve_dense, cholesky, cholesky_solve
from .state_io import StateWriter, StateReader
from collision.collider_set import ColliderSet, Pose3
from collision.world_query import QueryFilter, nearest_surface


comptime _Rows3 = Array[Vec3, 3]


def _sym_add(a: _Rows3, b: _Rows3) -> _Rows3:
    var r = _Rows3(fill=Vec3(0, 0, 0, 0))
    for i in range(3):
        r[i] = a[i] + b[i]
    return r^


def _matvec(m: _Rows3, v: Vec3) -> Vec3:
    return Vec3(dot(m[0], v), dot(m[1], v), dot(m[2], v), 0)


def _rot_rows(q: Quat) -> _Rows3:
    """Rows of Rᵀ (so `_matvec(rt, v)` = Rᵀ·v, world/parent -> local).
    Row i of Rᵀ is column i of R — exactly the image of basis vector i."""
    var r = _Rows3(fill=Vec3(0, 0, 0, 0))
    r[0] = q.rotate(Vec3(1, 0, 0, 0))
    r[1] = q.rotate(Vec3(0, 1, 0, 0))
    r[2] = q.rotate(Vec3(0, 0, 1, 0))
    return r^


@fieldwise_init
struct SpInertia(Copyable, ImplicitlyCopyable, Movable):
    """Compact spatial inertia about the frame origin: {m, h = m·c, I_o}."""

    var m: Real
    var h: Vec3
    var io: _Rows3

    def __init__(out self, *, copy: Self):
        """Explicit copy: `Array` is not `ImplicitlyCopyable` in
        Mojo 1.0, so a struct holding one gets no synthesised copy."""
        self.m = copy.m
        self.h = copy.h
        self.io = copy.io.copy()

    @staticmethod
    def of_link(mass: Real, com: Vec3, i_diag: Vec3) -> Self:
        """Rigid link: principal inertia about its COM, offset to the origin
        (parallel axis: I_o = I_c + m(|c|² 1 − c cᵀ))."""
        var c = com
        var c2 = dot(c, c)
        var io = _Rows3(fill=Vec3(0, 0, 0, 0))
        for i in range(3):
            var row = Vec3(0, 0, 0, 0)
            for j in range(3):
                var v = -mass * c[i] * c[j]
                if i == j:
                    v += mass * c2 + i_diag[i]
                row[j] = v
            io[i] = row
        return Self(mass, c * mass, io^)

    def apply(self, w: Vec3, v: Vec3) -> Tuple[Vec3, Vec3]:
        """Spatial momentum/force map: (Iw + h×v, m·v − h×w)."""
        return (
            _matvec(self.io, w) + cross(self.h, v),
            v * self.m - cross(self.h, w),
        )


comptime JOINT_REVOLUTE = 0
comptime JOINT_PRISMATIC = 1


@fieldwise_init
struct BallLimit(Copyable, ImplicitlyCopyable, Movable):
    """Swing-twist limit of one ball joint (17.51): the body axis `axis`
    stays within `swing` (rad) of `ref_dir` (a parent-frame direction, the
    axis where the limit was set; swing < 0 = no cone), and the twist about
    it relative to `ref_rot` stays in [twist_lo, twist_hi] (lo > hi = no
    twist limit)."""

    var axis: Vec3
    var ref_dir: Vec3
    var ref_rot: Quat
    var swing: Real
    var twist_lo: Real
    var twist_hi: Real


@fieldwise_init
struct ChainLink(Copyable, ImplicitlyCopyable, Movable):
    var axis: Vec3  # joint axis, unit, link frame
    var pivot: Vec3  # this joint's position in the PARENT link frame
    var com: Vec3  # centre of mass, link frame
    var mass: Real
    var i_diag: Vec3  # principal inertia about the COM
    var kind: Int  # JOINT_REVOLUTE | JOINT_PRISMATIC
    var lo: Real  # joint limit, low (lo >= hi disables limits)
    var hi: Real

    @staticmethod
    def revolute(
        axis: Vec3, pivot: Vec3, com: Vec3, mass: Real, i_diag: Vec3
    ) -> Self:
        return Self(axis, pivot, com, mass, i_diag, JOINT_REVOLUTE, 1, -1)

    @staticmethod
    def prismatic(
        axis: Vec3, pivot: Vec3, com: Vec3, mass: Real, i_diag: Vec3
    ) -> Self:
        """A sliding joint: `q` translates along `axis` instead of rotating.

        The whole difference in the dynamics is the MOTION SUBSPACE — S is
        (axis, 0) for a revolute joint and (0, axis) for a prismatic one — so
        every sweep that projects onto S needs the same two-way branch, and
        nothing else changes. That is why the joint kind lives on the link
        rather than in a separate solver path."""
        return Self(axis, pivot, com, mass, i_diag, JOINT_PRISMATIC, 1, -1)

    def limited(self, lo: Real, hi: Real) -> Self:
        """Copy with a joint range. `lo >= hi` means unlimited, which is the
        default, so an unconstrained joint costs no branch in the limit pass."""
        return Self(
            self.axis, self.pivot, self.com, self.mass, self.i_diag,
            self.kind, lo, hi,
        )

    def has_limits(self) -> Bool:
        return self.hi > self.lo


def _shift_inertia(ci: SpInertia, q: Quat, p: Vec3) -> SpInertia:
    """Re-express a spatial inertia in the parent frame: rotate by `q`, then
    move the reference point by `p`.

    Split out of the CRBA loop because the floating-base variant needs the
    SAME transform to carry the root composite into the base frame. Two copies
    of a parallel-axis identity is exactly the kind of duplication that stays
    correct until one of them is edited."""
    var h_p = q.rotate(ci.h) + p * ci.m
    # R I Rᵀ (columns = R·I·Rᵀ·e_a), assembled into rows explicitly
    var rt = _rot_rows(q)  # Rᵀ rows
    var c0 = q.rotate(_matvec(ci.io, _matvec(rt, Vec3(1, 0, 0, 0))))
    var c1 = q.rotate(_matvec(ci.io, _matvec(rt, Vec3(0, 1, 0, 0))))
    var c2 = q.rotate(_matvec(ci.io, _matvec(rt, Vec3(0, 0, 1, 0))))
    var rrows = _Rows3(fill=Vec3(0, 0, 0, 0))
    rrows[0] = Vec3(c0[0], c1[0], c2[0], 0)
    rrows[1] = Vec3(c0[1], c1[1], c2[1], 0)
    rrows[2] = Vec3(c0[2], c1[2], c2[2], 0)
    var hr = q.rotate(ci.h)
    # exact identity for the point shift: I' = RIRᵀ − p×[hr]× − [p]×[hr+mp]×
    var px_hr = _cross_mat_mul(p, hr)
    var px_hmp = _cross_mat_mul(p, hr + p * ci.m)
    for r in range(3):
        rrows[r] = rrows[r] - px_hr[r] - _transpose_row(px_hmp, r)
    return SpInertia(ci.m, h_p, rrows^)


def _merge_inertia(a: SpInertia, b: SpInertia) -> SpInertia:
    """Add two spatial inertias already expressed about the same point."""
    return SpInertia(a.m + b.m, a.h + b.h, _sym_add(a.io, b.io))


struct Chain(Movable, Deinitable):
    var links: List[ChainLink]
    var q: List[Real]
    var qd: List[Real]
    # parent link index (-1 = root); serial add_link chains i-1 -> i, and
    # add_link_to grows TREES (ragdolls) / forests (parent = -1 anywhere).
    # Parents always precede children (append order), so every forward
    # sweep can read parent state by index.
    var parent: List[Int]
    # Root motion, base frame. Zero for a fixed base, which is what every
    # existing caller gets: the sweeps read these where they previously read
    # literal zeros, so a bolted-down chain is the special case rather than a
    # separate code path. `FloatingChain` drives them through
    # `set_base_motion`; nothing else writes them.
    var _base_w: Vec3  # angular velocity of the root frame
    var _base_v: Vec3  # linear velocity of the root frame origin
    var _base_wa: Vec3  # angular acceleration
    var _base_va: Vec3  # linear acceleration, BEFORE the gravity shift
    # ROADMAP 17.51 joint properties, one per joint, all 0 by default (then
    # `step_implicit` reduces to a plain semi-implicit step): viscous damping
    # (N m s / rad), spring stiffness toward `rest`, armature (rotor inertia
    # added to the joint's diagonal), Coulomb friction (N m).
    var damping: List[Real]
    var stiffness: List[Real]
    var rest: List[Real]
    var armature: List[Real]
    var friction: List[Real]
    # ROADMAP 17.51 ball joints: a ball is three revolute DOFs about the
    # link's own x / y / z on three consecutive links (two massless), and
    # its accumulated orientation lives in `ball_rot` of the first; after
    # every integration `fold_balls` moves the three small angles into it,
    # sets them back to 0 and turns their rates into the body angular
    # velocity, so the Euler-angle singularity (middle angle +-pi/2) is
    # never approached. `balls` lists the first link of each.
    var ball_head: List[Bool]
    var ball_rot: List[Quat]
    var balls: List[Int]
    var ball_lim: List[BallLimit]  # parallel to `balls`

    def __init__(out self):
        self.links = List[ChainLink]()
        self.q = List[Real]()
        self.qd = List[Real]()
        self.parent = List[Int]()
        self._base_w = Vec3(0, 0, 0, 0)
        self._base_v = Vec3(0, 0, 0, 0)
        self._base_wa = Vec3(0, 0, 0, 0)
        self._base_va = Vec3(0, 0, 0, 0)
        self.damping = List[Real]()
        self.stiffness = List[Real]()
        self.rest = List[Real]()
        self.armature = List[Real]()
        self.friction = List[Real]()
        self.ball_head = List[Bool]()
        self.ball_rot = List[Quat]()
        self.balls = List[Int]()
        self.ball_lim = List[BallLimit]()

    def _push_props(mut self):
        self.damping.append(0)
        self.stiffness.append(0)
        self.rest.append(0)
        self.armature.append(0)
        self.friction.append(0)
        self.ball_head.append(False)
        self.ball_rot.append(Quat.identity())

    def add_ball(
        mut self, p: Int, pivot: Vec3, com: Vec3, mass: Real, i_diag: Vec3
    ) raises -> Int:
        """A ball (spherical, 3-DOF) joint under link `p` (-1 = root) at
        `pivot` in the parent frame, carrying a link of `mass`, `com` and
        principal inertia `i_diag` (17.51). Adds three links (x, y, z
        rotation; the body is the third) and returns the body's index; its
        three DOFs are the body angular velocity components about its own
        axes. Mass must be > 0."""
        if not (mass > 0):
            raise Error("Chain.add_ball: mass must be > 0")
        var z0 = Vec3(0, 0, 0, 0)
        var hx = self.add_link_to(p, ChainLink.revolute(Vec3(1, 0, 0, 0), pivot, z0, 0, z0))
        var hy = self.add_link_to(hx, ChainLink.revolute(Vec3(0, 1, 0, 0), z0, z0, 0, z0))
        var hz = self.add_link_to(hy, ChainLink.revolute(Vec3(0, 0, 1, 0), z0, com, mass, i_diag))
        self.ball_head[hx] = True
        self.balls.append(hx)
        self.ball_lim.append(BallLimit(Vec3(0, 1, 0, 0), Vec3(0, 1, 0, 0), Quat.identity(), -1, 1, -1))
        return hz

    def set_ball_limits(
        mut self, body: Int, axis: Vec3, swing: Real, twist_lo: Real = 1, twist_hi: Real = -1
    ) raises:
        """Swing-twist limit on the ball whose body link is `body` (17.51):
        the body-frame `axis` stays within `swing` rad of where it points
        now (a cone; swing < 0 removes it), and the twist about it stays in
        [twist_lo, twist_hi] rad from the current twist (lo > hi: none)."""
        var k = -1
        for b in range(len(self.balls)):
            if self.balls[b] + 2 == body:
                k = b
        if k < 0:
            raise Error("Chain.set_ball_limits: link is not a ball joint's body")
        var al = length(axis)
        if not (al > 0):
            raise Error("Chain.set_ball_limits: axis must be non-zero")
        if swing > Real(3.14159265):
            raise Error("Chain.set_ball_limits: swing must be <= pi")
        var a = axis / al
        var r = self.ball_orientation(body)
        self.ball_lim[k] = BallLimit(a, r.rotate(a), r, swing, twist_lo, twist_hi)

    def ball_swing_twist(self, body: Int) raises -> Tuple[Real, Real]:
        """(swing, twist) of a limited ball's body relative to where its limit
        was set (rad)."""
        for b in range(len(self.balls)):
            if self.balls[b] + 2 == body:
                return self._swing_twist(b)
        raise Error("Chain.ball_swing_twist: link is not a ball joint's body")

    def _swing_twist(self, b: Int) -> Tuple[Real, Real]:
        ref lim = self.ball_lim[b]
        var r = self.ball_orientation(self.balls[b] + 2)
        var ra = r.rotate(lim.axis)
        var c = min(max(dot(ra, lim.ref_dir), Real(-1)), Real(1))
        var swing = atan2(length(cross(lim.ref_dir, ra)), c)
        var rel = lim.ref_rot.conjugate() * r
        var tw = 2 * atan2(dot(Vec3(rel.x, rel.y, rel.z, 0), lim.axis), rel.w)
        if tw > Real(3.14159265):
            tw -= Real(6.2831853)
        elif tw < Real(-3.14159265):
            tw += Real(6.2831853)
        return (swing, tw)

    def _ball_rows(self, b: Int) -> Tuple[List[Real], List[Real]]:
        """Joint-space rows of ball `b`'s swing and twist rates: the swing
        axis and the twist axis in the body frame, on the ball's DOFs."""
        var n = len(self.links)
        ref lim = self.ball_lim[b]
        var h = self.balls[b]
        var r = self.ball_orientation(h + 2)
        var ra = r.rotate(lim.axis)
        var sw = cross(lim.ref_dir, ra)
        var sl = length(sw)
        var nb = r.conjugate().rotate(sw / sl) if sl > 1e-9 else Vec3(0, 0, 0, 0)
        var js = List[Real](length=n, fill=0)
        var jt = List[Real](length=n, fill=0)
        for k in range(3):
            js[h + k] = nb[k]
            jt[h + k] = lim.axis[k]
        return (js^, jt^)

    def _row_impulse(mut self, h: List[Real], j: List[Real], target_dv: Real) raises:
        var n = len(self.links)
        var hinv = solve_dense(h.copy(), j.copy(), n)
        var w = Real(0)
        for k in range(n):
            w += j[k] * hinv[k]
        if w < 1e-12:
            return
        var lam = target_dv / w
        for k in range(n):
            self.qd[k] += hinv[k] * lam

    def _row_rate(self, j: List[Real]) -> Real:
        var v = Real(0)
        for k in range(len(j)):
            v += j[k] * self.qd[k]
        return v

    def _ball_limit_pass(mut self, h: List[Real], dt: Real, position: Bool) raises:
        """One sweep over the limited balls: velocity (stop motion into a
        violated bound) or position (pseudo-velocity back to the bound)."""
        for b in range(len(self.balls)):
            var lim = self.ball_lim[b]  # a copy: the impulses below mutate self
            var st = self._swing_twist(b)
            var rows = self._ball_rows(b)
            if lim.swing >= 0 and st[0] > lim.swing:
                var rate = self._row_rate(rows[0])
                if position:
                    self._row_impulse(h, rows[0], (lim.swing - st[0]) / dt - rate)
                elif rate > 0:
                    self._row_impulse(h, rows[0], -rate)
            if lim.twist_lo <= lim.twist_hi:
                var rate_t = self._row_rate(rows[1])
                if st[1] > lim.twist_hi:
                    if position:
                        self._row_impulse(h, rows[1], (lim.twist_hi - st[1]) / dt - rate_t)
                    elif rate_t > 0:
                        self._row_impulse(h, rows[1], -rate_t)
                elif st[1] < lim.twist_lo:
                    if position:
                        self._row_impulse(h, rows[1], (lim.twist_lo - st[1]) / dt - rate_t)
                    elif rate_t < 0:
                        self._row_impulse(h, rows[1], -rate_t)

    def _balls_violated(self) -> Int:
        var c = 0
        for b in range(len(self.balls)):
            ref lim = self.ball_lim[b]
            var st = self._swing_twist(b)
            if lim.swing >= 0 and st[0] > lim.swing:
                c += 1
            if lim.twist_lo <= lim.twist_hi and (st[1] > lim.twist_hi or st[1] < lim.twist_lo):
                c += 1
        return c

    def add_universal(
        mut self, p: Int, pivot: Vec3, axis1: Vec3, axis2: Vec3, com: Vec3,
        mass: Real, i_diag: Vec3,
    ) raises -> Int:
        """A universal (Cardan) joint under link `p` (17.51): rotation about
        `axis1` (parent frame) then about `axis2` (perpendicular to it) --
        two revolute links, the first massless. Returns the body's index.
        Its singular pose (the second angle at +-pi/2, where the first and
        a body axis would align) is the joint's own: a real cross locks
        there too."""
        if not (mass > 0):
            raise Error("Chain.add_universal: mass must be > 0")
        if abs(dot(axis1, axis2)) > Real(1e-4) * length(axis1) * length(axis2):
            raise Error("Chain.add_universal: axes must be perpendicular")
        var z0 = Vec3(0, 0, 0, 0)
        var a = self.add_link_to(p, ChainLink.revolute(axis1 / length(axis1), pivot, z0, 0, z0))
        return self.add_link_to(a, ChainLink.revolute(axis2 / length(axis2), z0, com, mass, i_diag))

    def add_planar(
        mut self, p: Int, pivot: Vec3, u: Vec3, v: Vec3, com: Vec3, mass: Real,
        i_diag: Vec3,
    ) raises -> Int:
        """A planar joint under link `p` (17.51): translation along `u` and
        `v` (perpendicular, parent frame) and rotation about u x v -- two
        massless prismatic links and a revolute. Returns the body's index."""
        if not (mass > 0):
            raise Error("Chain.add_planar: mass must be > 0")
        if abs(dot(u, v)) > Real(1e-4) * length(u) * length(v):
            raise Error("Chain.add_planar: u and v must be perpendicular")
        var z0 = Vec3(0, 0, 0, 0)
        var un = u / length(u)
        var vn = v / length(v)
        var a = self.add_link_to(p, ChainLink.prismatic(un, pivot, z0, 0, z0))
        var b = self.add_link_to(a, ChainLink.prismatic(vn, z0, z0, 0, z0))
        return self.add_link_to(b, ChainLink.revolute(cross(un, vn), z0, com, mass, i_diag))

    def add_free(
        mut self, p: Int, pivot: Vec3, com: Vec3, mass: Real, i_diag: Vec3
    ) raises -> Int:
        """A free (6-DOF) joint under link `p` (17.51): translation along the
        parent's x / y / z (three massless prismatic links) and a ball
        (`add_ball`) for the rotation. Returns the body's index; its DOFs
        are the origin's velocity in the parent frame, then the body
        angular velocity."""
        if not (mass > 0):
            raise Error("Chain.add_free: mass must be > 0")
        var z0 = Vec3(0, 0, 0, 0)
        var a = self.add_link_to(p, ChainLink.prismatic(Vec3(1, 0, 0, 0), pivot, z0, 0, z0))
        var b = self.add_link_to(a, ChainLink.prismatic(Vec3(0, 1, 0, 0), z0, z0, 0, z0))
        var c = self.add_link_to(b, ChainLink.prismatic(Vec3(0, 0, 1, 0), z0, z0, 0, z0))
        return self.add_ball(c, z0, com, mass, i_diag)

    def ball_orientation(self, body: Int) -> Quat:
        """Parent -> body rotation of the ball whose body link is `body`."""
        var h = body - 2
        return (
            self.ball_rot[h]
            * Quat.from_axis_angle(self.links[h].axis, self.q[h])
            * Quat.from_axis_angle(self.links[h + 1].axis, self.q[h + 1])
            * Quat.from_axis_angle(self.links[h + 2].axis, self.q[h + 2])
        )

    def fold_balls(mut self):
        """Move each ball's three small angles into its quaternion and turn
        their rates into the body angular velocity (body frame): the rates
        of the x, y, z rotations at angles (a, b, c) give the relative
        angular velocity Rz^T Ry^T e_x a' + Rz^T e_y b' + e_z c' in the body
        frame, which are the new three DOFs once the angles are 0. Runs
        after every integration; a no-op without balls."""
        for h in self.balls:
            var rx = Quat.from_axis_angle(Vec3(1, 0, 0, 0), self.q[h])
            var ry = Quat.from_axis_angle(Vec3(0, 1, 0, 0), self.q[h + 1])
            var rz = Quat.from_axis_angle(Vec3(0, 0, 1, 0), self.q[h + 2])
            var r = rx * ry * rz
            var w0 = (
                Vec3(1, 0, 0, 0) * self.qd[h]
                + rx.rotate(Vec3(0, 1, 0, 0)) * self.qd[h + 1]
                + (rx * ry).rotate(Vec3(0, 0, 1, 0)) * self.qd[h + 2]
            )
            var w = r.conjugate().rotate(w0)
            self.ball_rot[h] = (self.ball_rot[h] * r).normalized()
            self.q[h] = 0
            self.q[h + 1] = 0
            self.q[h + 2] = 0
            self.qd[h] = w[0]
            self.qd[h + 1] = w[1]
            self.qd[h + 2] = w[2]

    def set_joint_props(
        mut self, i: Int, damping: Real = 0, stiffness: Real = 0, rest: Real = 0,
        armature: Real = 0, friction: Real = 0,
    ) raises:
        """Joint `i`'s damping, spring (stiffness toward `rest`), armature and
        Coulomb friction (ROADMAP 17.51); all must be >= 0 (rest any value).
        Used by `step_implicit`."""
        if i < 0 or i >= len(self.links):
            raise Error("Chain.set_joint_props: joint index out of range")
        if not (damping >= 0 and stiffness >= 0 and armature >= 0 and friction >= 0):
            raise Error("Chain.set_joint_props: damping, stiffness, armature, friction must be >= 0")
        if stiffness > 0 and (self.ball_head[i] or (i >= 1 and self.ball_head[i - 1]) or (i >= 2 and self.ball_head[i - 2])):
            raise Error("Chain.set_joint_props: a ball joint's DOFs have no fixed rest angle (fold_balls resets them); no stiffness")
        self.damping[i] = damping
        self.stiffness[i] = stiffness
        self.rest[i] = rest
        self.armature[i] = armature
        self.friction[i] = friction

    def set_base_motion(
        mut self, w: Vec3, v: Vec3, wa: Vec3 = Vec3(0, 0, 0, 0),
        va: Vec3 = Vec3(0, 0, 0, 0),
    ):
        """Set the root frame's motion for the next dynamics call, all in the
        base frame: angular and linear velocity `w`, `v`, and angular and
        linear acceleration `wa`, `va` (the latter BEFORE the gravity shift).

        The one sanctioned way to move the root. A bolted-down chain never
        calls it and keeps all four at zero; `FloatingChain` calls it before
        every sweep so the two never hold diverging copies of the base state.
        Setting all four together (the acceleration pair defaults to zero)
        is deliberate: a half-updated base is the bug this replaces."""
        self._base_w = w
        self._base_v = v
        self._base_wa = wa
        self._base_va = va

    def add_link(mut self, link: ChainLink):
        self.links.append(link)
        self.q.append(0)
        self.qd.append(0)
        self.parent.append(len(self.links) - 2)
        self._push_props()

    def add_link_to(mut self, p: Int, link: ChainLink) raises -> Int:
        """Attach under link `p` (or -1 for a new root); returns the index."""
        if p >= len(self.links) or p < -1:
            raise Error("parent must exist before the child")
        self.links.append(link)
        self.q.append(0)
        self.qd.append(0)
        self.parent.append(p)
        self._push_props()
        return len(self.links) - 1

    def fk(self) -> List[Motor3]:
        """World pose of every link frame — pure motor composition (GA)."""
        var out = List[Motor3]()
        for i in range(len(self.links)):
            var base = Motor3.identity()
            if self.parent[i] >= 0:
                base = out[self.parent[i]]
            var pose = (
                base
                * Motor3.from_translation(self._joint_offset(i))
                * Motor3.from_quat(self._joint_rot(i))
            )
            out.append(pose)
        return out^

    def _joint_rot(self, i: Int) -> Quat:
        """Parent -> link rotation. A prismatic joint does not rotate."""
        if self.links[i].kind == JOINT_PRISMATIC:
            return Quat.identity()
        if self.ball_head[i]:
            return self.ball_rot[i] * Quat.from_axis_angle(self.links[i].axis, self.q[i])
        return Quat.from_axis_angle(self.links[i].axis, self.q[i])

    def _joint_offset(self, i: Int) -> Vec3:
        """This joint's origin in the PARENT frame. A prismatic joint slides
        its own origin along the axis, so `q` enters here instead of in the
        rotation."""
        var l = self.links[i]
        if l.kind == JOINT_PRISMATIC:
            return l.pivot + l.axis * self.q[i]
        return l.pivot

    def link_motion(
        self, qdd: List[Real], gravity: Vec3
    ) raises -> Tuple[List[Vec3], List[Vec3], List[Vec3], List[Vec3]]:
        """Per-link (w, v, wa, va) in the LINK frame — the RNEA forward sweep.

        Exposed because sensors read exactly this. Note the gravity trick means
        `va` is already the PROPER acceleration: the base is given -g, so every
        link's linear acceleration carries the weight term an accelerometer
        actually measures. In free fall it is zero, which is the physical fact
        that makes it the right quantity rather than a convenient one."""
        var n = len(self.links)
        # --- forward pass: link-frame velocities and accelerations ---------
        var ws = List[Vec3]()  # angular velocity, link frame
        var vs = List[Vec3]()  # linear velocity of frame origin, link frame
        var wa = List[Vec3]()  # angular acceleration
        var va = List[Vec3]()  # linear acceleration (incl. -gravity)
        # gravity trick: the base "accelerates" at −g so every link feels
        # weight (standard Featherstone convention; the analytic pendulum and
        # the large-swing energy gates guard the sign chain end-to-end)
        for i in range(n):
            var l = self.links[i]
            var pi = self.parent[i]
            var w_p = ws[pi] if pi >= 0 else self._base_w
            var v_p = vs[pi] if pi >= 0 else self._base_v
            var wa_p = wa[pi] if pi >= 0 else self._base_wa
            var va_p = va[pi] if pi >= 0 else self._base_va - gravity
            var rt = _rot_rows(self._joint_rot(i))  # parent -> link (Rᵀ)
            var off = self._joint_offset(i)
            # motion subspace: S = (axis, 0) revolute, (0, axis) prismatic
            var rev = l.kind == JOINT_REVOLUTE
            var s_w = l.axis if rev else Vec3(0, 0, 0, 0)
            var s_v = Vec3(0, 0, 0, 0) if rev else l.axis
            var w_here = _matvec(rt, w_p) + s_w * self.qd[i]
            var v_here = _matvec(rt, v_p + cross(w_p, off)) + s_v * self.qd[i]
            # SPATIAL accelerations: same transform as velocities, plus the
            # velocity-product joint term  v_i ×ₘ (S q̇)  =  (w × s_w q̇,
            # w × s_v q̇ + v × s_w q̇), plus the joint acceleration S·q̈ (zero
            # in the bias case). The prismatic term w × s_v q̇ has coefficient
            # 1 here: the classical Coriolis 2ω×v is split between it and the
            # transform of the parent's spatial acceleration (ROADMAP 17.17
            # found a factor 2 here that made a bead on a spinning rod
            # decelerate the rod 1.5x too fast; tests/test_artic_batch.mojo
            # pins the analytic answer).
            var wa_here = (
                _matvec(rt, wa_p)
                + cross(w_here, s_w * self.qd[i])
                + s_w * qdd[i]
            )
            var va_here = (
                _matvec(rt, va_p + cross(wa_p, off))
                + cross(v_here, s_w * self.qd[i])
                + cross(w_here, s_v * self.qd[i])
                + s_v * qdd[i]
            )
            ws.append((w_here))
            vs.append((v_here))
            wa.append((wa_here))
            va.append((va_here))
        return (ws^, vs^, wa^, va^)

    def rnea_root(
        self, qdd: List[Real], gravity: Vec3
    ) raises -> Tuple[List[Real], Vec3, Vec3]:
        """Joint torques AND the wrench the root must supply, base frame.

        A fixed base absorbs that wrench through its mount and nobody looks at
        it; a floating base cannot, so the six numbers become equations. The
        backward sweep already accumulated them — links with no parent had
        their force dropped on the floor — so exposing them costs nothing and
        guarantees the two agree by construction."""
        return self._rnea_impl(qdd, gravity)

    def _rnea(self, qdd: List[Real], gravity: Vec3) raises -> List[Real]:
        """Recursive Newton-Euler: the joint torques that produce `qdd`.

        With `qdd = 0` this is the bias term C(q, q̇) that `dynamics` subtracts;
        with a real `qdd` it IS exact inverse dynamics, because the only
        difference is the joint-acceleration term `S·q̈` entering the forward
        sweep. Sharing one routine is what makes `inverse_dynamics` free rather
        than a second implementation to keep in sync — and what lets the
        round-trip test (τ → q̈ → τ) actually mean something."""
        var r = self._rnea_impl(qdd, gravity)
        return r[0].copy()

    def _rnea_impl(
        self, qdd: List[Real], gravity: Vec3
    ) raises -> Tuple[List[Real], Vec3, Vec3]:
        var n = len(self.links)
        var m = self.link_motion(qdd, gravity)
        # tuple elements are moved out one at a time: List[Vec3] is not
        # implicitly copyable, so binding them by value needs the transfer
        var ws = m[0].copy()
        var vs = m[1].copy()
        var wa = m[2].copy()
        var va = m[3].copy()
        # --- backward: link forces -> joint torques ------------------------
        var fw = List[Vec3]()  # angular (torque) part, link frame
        var fv = List[Vec3]()  # linear part
        for i in range(n):
            var li = self.links[i]
            var ii = SpInertia.of_link(li.mass, li.com, li.i_diag)
            var mom = ii.apply(ws[i], vs[i])
            var acc = ii.apply(wa[i], va[i])
            # f = I a + v ×* (I v)
            fw.append(
                (acc[0] + cross(ws[i], mom[0]) + cross(vs[i], mom[1]))
            )
            fv.append((acc[1] + cross(ws[i], mom[1])))
        var out = List[Real]()
        for _ in range(n):
            out.append(0)
        var root_w = Vec3(0, 0, 0, 0)
        var root_v = Vec3(0, 0, 0, 0)
        var i2 = n - 1
        while i2 >= 0:
            var li2 = self.links[i2]
            # tau = Sᵀ f: the angular half for a revolute joint, the linear
            # half for a prismatic one
            if li2.kind == JOINT_REVOLUTE:
                out[i2] = dot(li2.axis, fw[i2])
            else:
                out[i2] = dot(li2.axis, fv[i2])
            var par = self.parent[i2]
            if par >= 0:
                # push into the parent frame (rotate by R, shift by the joint
                # offset — which slides for a prismatic joint)
                var q = self._joint_rot(i2)
                var off2 = self._joint_offset(i2)
                var fw_p = q.rotate(fw[i2])
                var fv_p = q.rotate(fv[i2])
                fw[par] = (fw[par] + fw_p + cross(off2, fv_p))
                fv[par] = (fv[par] + fv_p)
            else:
                # no parent: this force lands on the root
                var q0 = self._joint_rot(i2)
                var o0 = self._joint_offset(i2)
                var fw0 = q0.rotate(fw[i2])
                var fv0 = q0.rotate(fv[i2])
                root_w = root_w + fw0 + cross(o0, fv0)
                root_v = root_v + fv0
            i2 -= 1
        return (out^, root_w, root_v)

    def inverse_dynamics(
        self, qdd: List[Real], gravity: Vec3
    ) raises -> List[Real]:
        """τ = ID(q, q̇, q̈) — exact, O(n), no mass matrix formed.

        The control-side counterpart of `dynamics`: feed-forward torques,
        contact-force estimation and system identification all start here.
        Note it costs O(n) where inverting the mass matrix costs O(n³), which
        is the whole reason a controller uses ID rather than solving FD
        backwards."""
        return self._rnea(qdd, gravity)

    def mass_matrix(self) raises -> List[Real]:
        """The CRBA joint-space inertia H, row-major n x n.

        Exposed because contact resolution needs it: an impulse applied at a
        point costs `J H⁻¹ Jᵀ` in effective mass, so the contact solver cannot
        work from forward dynamics alone. `dynamics` calls this rather than
        keeping its own copy."""
        var n = len(self.links)
        # --- CRBA: composite inertias + mass matrix ------------------------
        var comp = List[SpInertia]()
        for i in range(n):
            var li = self.links[i]
            comp.append(SpInertia.of_link(li.mass, li.com, li.i_diag))
        var i3 = n - 1
        while i3 > 0:
            if self.parent[i3] < 0:
                i3 -= 1
                continue
            # fold child composite into the parent frame
            var par3 = self.parent[i3]
            comp[par3] = _merge_inertia(
                comp[par3],
                _shift_inertia(
                    comp[i3], self._joint_rot(i3), self._joint_offset(i3)
                ),
            )
            i3 -= 1
        # H[i][j]: propagate F = I^C_i S_i toward the base
        var hmat = List[Real]()  # n*n row-major
        for _ in range(n * n):
            hmat.append(0)
        for i in range(n):
            var li = self.links[i]
            var rev_i = li.kind == JOINT_REVOLUTE
            var f = (
                comp[i].apply(li.axis, Vec3(0, 0, 0, 0)) if rev_i
                else comp[i].apply(Vec3(0, 0, 0, 0), li.axis)
            )
            var fwc = f[0]
            var fvc = f[1]
            hmat[i * n + i] = dot(li.axis, fwc) if rev_i else dot(li.axis, fvc)
            var j = i
            while self.parent[j] >= 0:
                var q = self._joint_rot(j)
                var p = self._joint_offset(j)
                var fw_pp = q.rotate(fwc)
                var fv_pp = q.rotate(fvc)
                fwc = fw_pp + cross(p, fv_pp)
                fvc = fv_pp
                j = self.parent[j]
                var lj = self.links[j]
                hmat[i * n + j] = (
                    dot(lj.axis, fwc) if lj.kind == JOINT_REVOLUTE
                    else dot(lj.axis, fvc)
                )
                hmat[j * n + i] = hmat[i * n + j]
        return hmat^

    def mass_matrix_floating(self, base: SpInertia) raises -> List[Real]:
        """The (6+n)x(6+n) inertia by CRBA, row-major [angular, linear, q].

        The same composite-inertia recursion as `mass_matrix`, carried one
        step further. The joint block is identical; what is new is that the
        force `F_i = Ic_i S_i`, which the fixed-base version stops propagating
        when it runs out of parents, is pushed ONE more transform into the
        base frame — those six numbers are the coupling column `H_bj`, the
        thing that says how swinging joint `i` shoves the body it is bolted
        to. `H_bb` is the whole system's composite inertia gathered at the
        base, obtained by applying it to the six unit motions.

        This shares the recursion with the fixed-base path, so it cannot
        disagree with it about the joint block. It CAN disagree about the new
        blocks, which is why `FloatingChain` keeps the unit-acceleration
        assembly as an independent second derivation and the test demands the
        two agree."""
        var n = len(self.links)
        var d = 6 + n
        var comp = List[SpInertia]()
        for i in range(n):
            var li = self.links[i]
            comp.append(SpInertia.of_link(li.mass, li.com, li.i_diag))
        var i3 = n - 1
        while i3 > 0:
            if self.parent[i3] >= 0:
                var par3 = self.parent[i3]
                comp[par3] = _merge_inertia(
                    comp[par3],
                    _shift_inertia(
                        comp[i3], self._joint_rot(i3), self._joint_offset(i3)
                    ),
                )
            i3 -= 1

        var hmat = List[Real]()
        for _ in range(d * d):
            hmat.append(0)

        # --- H_bb: every root composite carried into the base frame --------
        var total = base
        for i in range(n):
            if self.parent[i] < 0:
                total = _merge_inertia(
                    total,
                    _shift_inertia(
                        comp[i], self._joint_rot(i), self._joint_offset(i)
                    ),
                )
        for k in range(6):
            var aw = Vec3(
                Real(1) if k == 0 else Real(0),
                Real(1) if k == 1 else Real(0),
                Real(1) if k == 2 else Real(0),
                0,
            )
            var av = Vec3(
                Real(1) if k == 3 else Real(0),
                Real(1) if k == 4 else Real(0),
                Real(1) if k == 5 else Real(0),
                0,
            )
            var f = total.apply(aw, av)
            for r in range(3):
                hmat[r * d + k] = f[0][r]
                hmat[(3 + r) * d + k] = f[1][r]

        # --- H_jj and H_bj: propagate F = Ic_i S_i up, then into the base --
        for i in range(n):
            var li = self.links[i]
            var rev_i = li.kind == JOINT_REVOLUTE
            var f = (
                comp[i].apply(li.axis, Vec3(0, 0, 0, 0)) if rev_i
                else comp[i].apply(Vec3(0, 0, 0, 0), li.axis)
            )
            var fwc = f[0]
            var fvc = f[1]
            hmat[(6 + i) * d + 6 + i] = (
                dot(li.axis, fwc) if rev_i else dot(li.axis, fvc)
            )
            var j = i
            while self.parent[j] >= 0:
                var q = self._joint_rot(j)
                var p = self._joint_offset(j)
                var fw_pp = q.rotate(fwc)
                var fv_pp = q.rotate(fvc)
                fwc = fw_pp + cross(p, fv_pp)
                fvc = fv_pp
                j = self.parent[j]
                var lj = self.links[j]
                var e = (
                    dot(lj.axis, fwc) if lj.kind == JOINT_REVOLUTE
                    else dot(lj.axis, fvc)
                )
                hmat[(6 + i) * d + 6 + j] = e
                hmat[(6 + j) * d + 6 + i] = e
            # one transform past the root: now in the base frame
            var qr = self._joint_rot(j)
            var pr = self._joint_offset(j)
            var fw_b = qr.rotate(fwc)
            var fv_b = qr.rotate(fvc)
            fw_b = fw_b + cross(pr, fv_b)
            for r in range(3):
                hmat[r * d + 6 + i] = fw_b[r]
                hmat[(3 + r) * d + 6 + i] = fv_b[r]
                hmat[(6 + i) * d + r] = fw_b[r]
                hmat[(6 + i) * d + 3 + r] = fv_b[r]
        return hmat^

    def dynamics(self, tau: List[Real], gravity: Vec3) raises -> List[Real]:
        """`qdd = H⁻¹ (tau − C)` — CRBA mass matrix + RNEA bias, dense solve."""
        var n = len(self.links)
        var zero_qdd = List[Real]()
        for _ in range(n):
            zero_qdd.append(0)
        var c_bias = self._rnea(zero_qdd, gravity)
        var hmat = self.mass_matrix()
        var rhs = List[Real]()
        for i in range(n):
            rhs.append(tau[i] - c_bias[i])
        return solve_dense(hmat^, rhs^, n)


    # ------------------------------------------------ contact coupling
    # A reduced-coordinate body has no world-space impulse to push on: every
    # force must arrive through the joints. The bridge is the point Jacobian —
    # the row mapping joint velocities to the velocity of one material point
    # along one direction — and its transpose, which maps an impulse at that
    # point back to joint torques. `J H⁻¹ Jᵀ` is then the effective mass the
    # contact sees, which is what makes the impulse solvable in joint space.

    def point_world(self, i: Int, local: Vec3) -> Vec3:
        """World position of a point given in link `i`'s frame."""
        var poses = self.fk()
        return poses[i].apply_point(local)

    def point_jacobian(
        self, i: Int, local: Vec3, dir: Vec3
    ) -> List[Real]:
        """Row `J` with `J q̇ = (velocity of the point) · dir`.

        Only ancestors of link `i` contribute: a joint that is not on the path
        to the root cannot move the point at all, and its column is exactly
        zero. Walking the ancestor chain rather than all joints is what keeps
        this O(depth) instead of O(n)."""
        var n = len(self.links)
        var poses = self.fk()
        var pw = poses[i].apply_point(local)
        var j = List[Real]()
        for _ in range(n):
            j.append(0)
        var k = i
        while k >= 0:
            # joint k's axis and origin in world (one decomposition serves
            # both: the quaternion rotates the axis, the translation IS the
            # joint origin)
            var qt = poses[k].to_quat_translation()
            var axis_w = qt[0].rotate(self.links[k].axis)
            var origin_w = qt[1]
            if self.links[k].kind == JOINT_REVOLUTE:
                # revolute: the point moves at omega x r
                j[k] = dot(cross(axis_w, pw - origin_w), dir)
            else:
                # prismatic: the point translates with the axis, independent
                # of where it sits relative to the joint
                j[k] = dot(axis_w, dir)
            k = self.parent[k]
        return j^

    def point_velocity(self, i: Int, local: Vec3, dir: Vec3) -> Real:
        var j = self.point_jacobian(i, local, dir)
        var v = Real(0)
        for k in range(len(j)):
            v += j[k] * self.qd[k]
        return v

    def apply_impulse_with(
        mut self, h: List[Real], i: Int, local: Vec3, dir: Vec3, target_dv: Real
    ) raises -> Real:
        """`apply_impulse` with the mass matrix supplied.

        H depends only on `q`, which does NOT change during a velocity
        iteration, so recomputing it per contact per iteration is pure waste —
        it made the contact pass cost an O(n³) solve times contacts times
        iterations, and dominated the step by ~29x at 2 links."""
        var n = len(self.links)
        var j = self.point_jacobian(i, local, dir)
        var hinv_jt = solve_dense(h.copy(), j.copy(), n)
        var w = Real(0)
        for k in range(n):
            w += j[k] * hinv_jt[k]
        if w < 1e-12:
            return 0
        var lam = target_dv / w
        for k in range(n):
            self.qd[k] += hinv_jt[k] * lam
        return lam

    def apply_impulse_chol(
        mut self, l: List[Real], i: Int, local: Vec3, dir: Vec3, target_dv: Real
    ) raises -> Real:
        """`apply_impulse_with` from the Cholesky factor of H (17.51): H is
        factored once per contact pass, each impulse is then two O(n^2)
        triangular solves instead of an O(n^3) elimination."""
        var n = len(self.links)
        var j = self.point_jacobian(i, local, dir)
        var hinv_jt = cholesky_solve(l, j, n)
        var w = Real(0)
        for k in range(n):
            w += j[k] * hinv_jt[k]
        if w < 1e-12:
            return 0
        var lam = target_dv / w
        for k in range(n):
            self.qd[k] += hinv_jt[k] * lam
        return lam

    def hinv_aba(mut self, tau: List[Real]) raises -> List[Real]:
        """H^-1 tau in O(n) (17.51): with the joint rates and the root
        motion zeroed and no gravity the bias term vanishes, so the
        articulated-body algorithm's acceleration IS H^-1 tau -- no mass
        matrix, no factorisation. State is restored before returning."""
        var saved = self.qd.copy()
        var bw = self._base_w
        var bv = self._base_v
        var bwa = self._base_wa
        var bva = self._base_va
        for k in range(len(self.qd)):
            self.qd[k] = 0
        var z = Vec3(0, 0, 0, 0)
        self.set_base_motion(z, z, z, z)
        var out = self.dynamics_aba(tau, z)
        self.qd = saved^
        self.set_base_motion(bw, bv, bwa, bva)
        return out^

    def apply_impulse_aba(
        mut self, i: Int, local: Vec3, dir: Vec3, target_dv: Real
    ) raises -> Real:
        """`apply_impulse` with H^-1 J^T from `hinv_aba` (O(n))."""
        var n = len(self.links)
        var j = self.point_jacobian(i, local, dir)
        var hinv_jt = self.hinv_aba(j)
        var w = Real(0)
        for k in range(n):
            w += j[k] * hinv_jt[k]
        if w < 1e-12:
            return 0
        var lam = target_dv / w
        for k in range(n):
            self.qd[k] += hinv_jt[k] * lam
        return lam

    def _impulse(
        mut self, h: List[Real], l: List[Real], chol: Bool, i: Int, local: Vec3, dir: Vec3, target_dv: Real,
        aba: Bool = False,
    ) raises -> Real:
        if aba:
            return self.apply_impulse_aba(i, local, dir, target_dv)
        if chol:
            return self.apply_impulse_chol(l, i, local, dir, target_dv)
        return self.apply_impulse_with(h, i, local, dir, target_dv)

    def _friction(
        mut self, h: List[Real], l: List[Real], chol: Bool, i: Int, local: Vec3,
        t: Vec3, cap: Real, mut acc: Real,
    ) raises:
        """One tangent row of a Coulomb contact (17.51): the impulse that stops
        sliding along `t`, with the accumulated total kept in [-cap, cap]."""
        var n = len(self.links)
        var j = self.point_jacobian(i, local, t)
        var hinv_jt = cholesky_solve(l, j, n) if chol else solve_dense(h.copy(), j.copy(), n)
        var w = Real(0)
        var vt = Real(0)
        for k in range(n):
            w += j[k] * hinv_jt[k]
            vt += j[k] * self.qd[k]
        if w < 1e-12:
            return
        var na = min(max(acc - vt / w, -cap), cap)
        var dl = na - acc
        acc = na
        for k in range(n):
            self.qd[k] += hinv_jt[k] * dl

    def apply_impulse(
        mut self, i: Int, local: Vec3, dir: Vec3, target_dv: Real
    ) raises -> Real:
        """Apply the impulse at (link `i`, `local`) along `dir` that changes the
        point's velocity along `dir` by `target_dv`. Returns the impulse.

        Effective mass is `1 / (J H⁻¹ Jᵀ)`; the velocity update is
        `Δq̇ = H⁻¹ Jᵀ λ`. Both need the same `H⁻¹ Jᵀ`, so it is solved once."""
        var n = len(self.links)
        var j = self.point_jacobian(i, local, dir)
        var h = self.mass_matrix()
        var hinv_jt = solve_dense(h^, j.copy(), n)
        var w = Real(0)
        for k in range(n):
            w += j[k] * hinv_jt[k]
        if w < 1e-12:
            return 0  # the point cannot be moved along `dir` by any joint
        var lam = target_dv / w
        for k in range(n):
            self.qd[k] += hinv_jt[k] * lam
        return lam

    def resolve_contacts(
        mut self,
        world: ColliderSet,
        poses: List[Pose3],
        restitution: Real,
        contacts: List[Int],
        locals: List[Vec3],
        dt: Real,
        iters: Int = 8,
        factor: Bool = True,
        mu: Real = 0,
        aba: Bool = False,
    ) raises -> Int:
        """Sequential-impulse contact against a `collision.ColliderSet`, SPLIT
        into velocity and position.

        `factor` (17.51): H is Cholesky-factored once per pass and every
        impulse reuses the factor (O(n^2) each); False keeps the dense
        elimination per impulse (O(n^3) each) -- the parity reference.

        `aba` (17.51): every H^-1 J^T comes from the articulated-body
        algorithm (`hinv_aba`, O(n) each) and no mass matrix is formed;
        friction rows still use the factored H.

        `mu` (17.51): Coulomb friction. Each touching contact accumulates its
        normal impulse over the velocity iterations; two tangent rows then
        stop the sliding with their totals kept within mu times it. 0 (the
        default) skips them -- the frictionless contact it always was.

        Each contact is a material point (link `contacts[c]`, offset
        `locals[c]` in its frame). Where it touches the world is NOT decided
        here: `collision.world_query.nearest_surface` names the closest
        collider and returns the signed distance and push-out normal, so the
        ground can be a box slab, a sphere, a hull, or (touch only, see that
        function) a level mesh, with whatever orientation it has. `poses[k]`
        is collider `k`'s world pose; the colliders are static as far as this
        call is concerned.

        The velocity pass applies only impulses that make the normal velocity
        non-negative, which by construction removes kinetic energy or leaves it
        alone. The penetration is then repaired in a SECOND pass that runs on a
        pseudo-velocity: it moves `q` and is discarded rather than accumulated
        into `q̇`.

        Doing both in one pass — a Baumgarte bias folded into the velocity
        target — is the obvious formulation and it PUMPS ENERGY: the positional
        term is not a physical impulse, so whatever it adds to the velocity
        stays there and comes back as speed on the next bounce. Measured here
        at nearly 3x the free-swinging peak before the split.

        Returns how many contacts were active on entry, not on exit: after a
        successful resolve none are active, so the exit count is always zero
        and would report "nothing touched" for every working contact."""
        var n = len(self.links)
        var filt = QueryFilter.all()
        var initial_active = 0
        for c in range(len(contacts)):
            var pw = self.point_world(contacts[c], locals[c])
            var hit = nearest_surface(world, poses, pw, filt)
            if hit[0] >= 0 and hit[1].dist <= 0:
                initial_active += 1
        if initial_active == 0:
            return 0

        # H is a function of q alone, so it is computed ONCE per pass rather
        # than per contact per iteration
        var need_h = not aba or mu > 0
        var h1 = self.mass_matrix() if need_h else List[Real]()
        var f1 = cholesky(h1, n) if factor and need_h else (List[Real](), False)
        var acc_n = List[Real](length=len(contacts), fill=0)
        var acc_t1 = List[Real](length=len(contacts), fill=0)
        var acc_t2 = List[Real](length=len(contacts), fill=0)
        # --- pass 1: velocity only (physical impulses) ---------------------
        for _ in range(iters):
            for c in range(len(contacts)):
                var i = contacts[c]
                var pw = self.point_world(i, locals[c])
                var hit = nearest_surface(world, poses, pw, filt)
                if hit[0] < 0 or hit[1].dist > 0:
                    continue
                var vn = self.point_velocity(i, locals[c], hit[1].normal)
                if vn < 0:
                    acc_n[c] += self._impulse(
                        h1, f1[0], f1[1], i, locals[c], hit[1].normal, -(1 + restitution) * vn, aba
                    )
                if mu > 0 and acc_n[c] > 0:
                    var tb = tangent_basis(hit[1].normal)
                    self._friction(h1, f1[0], f1[1], i, locals[c], tb[0], mu * acc_n[c], acc_t1[c])
                    self._friction(h1, f1[0], f1[1], i, locals[c], tb[1], mu * acc_n[c], acc_t2[c])

        # --- pass 2: positional repair on a pseudo-velocity ----------------
        var saved = self.qd.copy()
        var h2 = self.mass_matrix() if not aba else List[Real]()
        var f2 = cholesky(h2, n) if factor and not aba else (List[Real](), False)
        for k in range(n):
            self.qd[k] = 0
        for _ in range(iters):
            for c in range(len(contacts)):
                var i = contacts[c]
                var pw = self.point_world(i, locals[c])
                var hit = nearest_surface(world, poses, pw, filt)
                if hit[0] < 0:
                    continue
                var pen = -hit[1].dist
                if pen <= 0:
                    continue
                var vn = self.point_velocity(i, locals[c], hit[1].normal)
                var want = pen / dt - vn
                if want <= 0:
                    continue
                _ = self._impulse(h2, f2[0], f2[1], i, locals[c], hit[1].normal, want, aba)
        for k in range(n):
            self.q[k] += self.qd[k] * dt
            self.qd[k] = saved[k]
        if len(self.balls) > 0:
            self.fold_balls()
        return initial_active

    def resolve_limits(mut self, dt: Real, iters: Int = 8) raises -> Int:
        """Stop joints at their range, by impulse rather than by clamping.

        Clamping `q` directly is the tempting one-liner and it is wrong twice
        over: it leaves `q̇` pointing into the wall, so the joint re-violates
        every step and jitters, and it injects position without a corresponding
        impulse, so a limited joint silently gains energy. Solving it as a
        one-sided constraint uses the same machinery as contact — a joint's
        "Jacobian" is just the unit vector eₖ, so the effective mass is
        (H⁻¹)ₖₖ — and gets the same velocity/position split for free.

        Returns how many limits were violated on entry."""
        var n = len(self.links)
        var initial = 0
        for k in range(n):
            var l = self.links[k]
            if not l.has_limits():
                continue
            if self.q[k] < l.lo or self.q[k] > l.hi:
                initial += 1
        if len(self.balls) > 0:
            initial += self._balls_violated()
        if initial == 0:
            return 0

        var h1 = self.mass_matrix()
        # --- velocity pass: kill motion INTO the stop ----------------------
        for _ in range(iters):
            for k in range(n):
                var l = self.links[k]
                if not l.has_limits():
                    continue
                var low = self.q[k] < l.lo
                var high = self.q[k] > l.hi
                if not (low or high):
                    continue
                # moving away from the stop already? leave it alone — a limit
                # is one-sided, and pushing back would glue the joint to it
                if low and self.qd[k] >= 0:
                    continue
                if high and self.qd[k] <= 0:
                    continue
                _ = self._joint_impulse(h1, k, -self.qd[k])
            if len(self.balls) > 0:
                self._ball_limit_pass(h1, dt, False)

        # --- position pass on a pseudo-velocity, as in resolve_contacts ------
        var saved = self.qd.copy()
        var h2 = self.mass_matrix()
        for k in range(n):
            self.qd[k] = 0
        for _ in range(iters):
            for k in range(n):
                var l = self.links[k]
                if not l.has_limits():
                    continue
                var err: Real
                if self.q[k] < l.lo:
                    err = l.lo - self.q[k]
                elif self.q[k] > l.hi:
                    err = l.hi - self.q[k]
                else:
                    continue
                _ = self._joint_impulse(h2, k, err / dt - self.qd[k])
            if len(self.balls) > 0:
                self._ball_limit_pass(h2, dt, True)
        for k in range(n):
            self.q[k] += self.qd[k] * dt
            self.qd[k] = saved[k]
        if len(self.balls) > 0:
            self.fold_balls()
        return initial

    def _joint_impulse(
        mut self, h: List[Real], k: Int, target_dv: Real
    ) raises -> Real:
        """Impulse along joint coordinate `k` alone: the contact machinery with
        `J = eₖ`, so the effective mass is the k-th diagonal of `H⁻¹`."""
        var n = len(self.links)
        var e = List[Real]()
        for i in range(n):
            e.append(Real(1) if i == k else Real(0))
        var hinv_e = solve_dense(h.copy(), e^, n)
        var w = hinv_e[k]
        if w < 1e-12:
            return 0
        var lam = target_dv / w
        for i in range(n):
            self.qd[i] += hinv_e[i] * lam
        return lam

    def step(mut self, dt: Real, tau: List[Real], gravity: Vec3) raises:
        """Semi-implicit Euler in joint space."""
        var qdd = self.dynamics(tau, gravity)
        for i in range(len(self.links)):
            self.qd[i] += qdd[i] * dt
            self.q[i] += self.qd[i] * dt
        if len(self.balls) > 0:
            self.fold_balls()

    def step_implicit(mut self, dt: Real, tau: List[Real], gravity: Vec3) raises:
        """One step with the joint properties treated implicitly (17.51).

        With M = H + diag(armature), B = diag(damping) and
        K = diag(stiffness), backward Euler on the linear terms gives

            (M + dt B + dt^2 K) qd' = M qd + dt (tau - C(q, qd) - K (q - rest))

        then q' = q + dt qd'. The dt-scaled terms only ever ADD to the
        diagonal, so the system stays positive definite however stiff the
        spring or heavy the damping -- an explicit PD torque of the same
        stiffness diverges once dt exceeds about 2 / omega
        (`test_chain_props`). Coulomb friction then removes up to
        `friction * dt` of each joint's momentum against its motion, using
        the joint's diagonal effective mass (it stops the joint rather than
        reversing it)."""
        var n = len(self.links)
        var zero = List[Real]()
        for _ in range(n):
            zero.append(0)
        var c = self._rnea(zero, gravity)
        var h = self.mass_matrix()
        for i in range(n):
            h[i * n + i] += self.armature[i]
        var rhs = List[Real]()
        for i in range(n):
            var mq = Real(0)
            for j in range(n):
                mq += h[i * n + j] * self.qd[j]
            rhs.append(mq + dt * (tau[i] - c[i] - self.stiffness[i] * (self.q[i] - self.rest[i])))
        for i in range(n):
            h[i * n + i] += dt * self.damping[i] + dt * dt * self.stiffness[i]
        var diag = List[Real]()
        for i in range(n):
            diag.append(h[i * n + i])
        var qd = solve_dense(h^, rhs^, n)
        for i in range(n):
            var f = self.friction[i]
            if f > 0:
                var dv = f * dt / diag[i]
                if abs(qd[i]) <= dv:
                    qd[i] = 0
                else:
                    qd[i] -= dv if qd[i] > 0 else -dv
            self.qd[i] = qd[i]
            self.q[i] += qd[i] * dt
        if len(self.balls) > 0:
            self.fold_balls()

    def dynamics_aba(
        self, tau: List[Real], gravity: Vec3
    ) raises -> List[Real]:
        """`qdd` via the articulated-body algorithm (Featherstone RBDA 7.3):
        three O(n) sweeps instead of CRBA's O(n²) matrix + O(n³) solve.
        Same answer as `dynamics()` (parity-gated in test_aba); the U Uᵀ/d
        update breaks the compact {m,h,I_o} form, so articulated inertias
        carry full symmetric 6x6 blocks (`_ABI`)."""
        var n = len(self.links)
        # --- pass 1 (outward): velocities, joint bias c, bias force p ------
        var ws = List[Vec3]()
        var vs = List[Vec3]()
        var cw = List[Vec3]()
        var cv = List[Vec3]()
        var pw = List[Vec3]()
        var pv = List[Vec3]()
        for i in range(n):
            var l = self.links[i]
            var pi = self.parent[i]
            var w_p = ws[pi] if pi >= 0 else Vec3(0, 0, 0, 0)
            var v_p = vs[pi] if pi >= 0 else Vec3(0, 0, 0, 0)
            var rt = _rot_rows(self._joint_rot(i))
            var w_here = _matvec(rt, w_p) + l.axis * self.qd[i]
            var v_here = _matvec(rt, v_p + cross(w_p, l.pivot))
            var sqd = l.axis * self.qd[i]
            cw.append((cross(w_here, sqd)))
            cv.append((cross(v_here, sqd)))
            var ii = SpInertia.of_link(l.mass, l.com, l.i_diag)
            var mom = ii.apply(w_here, v_here)
            pw.append(
                (cross(w_here, mom[0]) + cross(v_here, mom[1]))
            )
            pv.append((cross(w_here, mom[1])))
            ws.append((w_here))
            vs.append((v_here))
        # --- pass 2 (inward): articulated inertias ------------------------
        var ia = List[_ABI]()
        for i in range(n):
            var l = self.links[i]
            ia.append(_ABI.of(SpInertia.of_link(l.mass, l.com, l.i_diag)))
        var uw = List[Vec3]()
        var uv = List[Vec3]()
        var dd = List[Real]()
        var uu = List[Real]()
        for _ in range(n):
            uw.append((Vec3(0, 0, 0, 0)))
            uv.append((Vec3(0, 0, 0, 0)))
            dd.append(0)
            uu.append(0)
        var i2 = n - 1
        while i2 >= 0:
            var l = self.links[i2]
            var u_ = ia[i2].apply(l.axis, Vec3(0, 0, 0, 0))
            uw[i2] = (u_[0])
            uv[i2] = (u_[1])
            dd[i2] = dot(l.axis, u_[0])
            uu[i2] = tau[i2] - dot(l.axis, pw[i2])
            var par = self.parent[i2]
            if par >= 0:
                var inv_d = 1 / dd[i2]
                # Ia = IA − U Uᵀ/d (rank-1, symmetric by construction)
                var a2 = _msub(ia[i2].a, _outer_scaled(u_[0], u_[0], inv_d))
                var b2 = _msub(ia[i2].b, _outer_scaled(u_[0], u_[1], inv_d))
                var d2 = _msub(ia[i2].d, _outer_scaled(u_[1], u_[1], inv_d))
                # pa = p^A + Ia c + U u/d
                var iac = _ABI(a2.copy(), b2.copy(), d2.copy()).apply(cw[i2], cv[i2])
                var paw = pw[i2] + iac[0] + u_[0] * (uu[i2] * inv_d)
                var pav = pv[i2] + iac[1] + u_[1] * (uu[i2] * inv_d)
                # into the parent frame: rotate blocks, then shift by pivot
                # (same composition as the force push in dynamics()):
                # A' = A₁ − B₁P + PB₁ᵀ − PD₁P ; B' = B₁ + PD₁ ; D' = D₁
                var q = self._joint_rot(i2)
                var p = l.pivot
                var a1 = _rot_mat(q, a2)
                var b1 = _rot_mat(q, b2)
                var d1 = _rot_mat(q, d2)
                var px = _skew(p)
                var ap = _msub(
                    _msub(
                        _madd(a1, _matmul(px, _transpose(b1))),
                        _matmul(b1, px),
                    ),
                    _matmul(_matmul(px, d1), px),
                )
                var bp = _madd(b1, _matmul(px, d1))
                ia[par] = _ABI(
                    _madd(ia[par].a, ap),
                    _madd(ia[par].b, bp),
                    _madd(ia[par].d, d1),
                )
                var fw_p = q.rotate(paw)
                var fv_p = q.rotate(pav)
                pw[par] = (pw[par] + fw_p + cross(p, fv_p))
                pv[par] = (pv[par] + fv_p)
            i2 -= 1
        # --- pass 3 (outward): accelerations ------------------------------
        var qdd = List[Real]()
        for _ in range(n):
            qdd.append(0)
        var aw = List[Vec3]()
        var av = List[Vec3]()
        for i in range(n):
            var l = self.links[i]
            var pi = self.parent[i]
            # same base-acceleration gravity trick at every root
            var wa_p = aw[pi] if pi >= 0 else Vec3(0, 0, 0, 0)
            var va_p = av[pi] if pi >= 0 else -gravity
            var rt = _rot_rows(self._joint_rot(i))
            var w_a = _matvec(rt, wa_p) + cw[i]
            var v_a = _matvec(rt, va_p + cross(wa_p, l.pivot)) + cv[i]
            qdd[i] = (
                uu[i] - dot(uw[i], w_a) - dot(uv[i], v_a)
            ) / dd[i]
            aw.append((w_a + l.axis * qdd[i]))
            av.append((v_a))
        return qdd^

    def step_aba(mut self, dt: Real, tau: List[Real], gravity: Vec3) raises:
        """Semi-implicit Euler in joint space, O(n) dynamics."""
        var qdd = self.dynamics_aba(tau, gravity)
        for i in range(len(self.links)):
            self.qd[i] += qdd[i] * dt
            self.q[i] += self.qd[i] * dt
        if len(self.balls) > 0:
            self.fold_balls()

    def energy(self, gravity: Vec3) raises -> Real:
        """Kinetic (via the velocity recursion) + potential (via motor FK)."""
        var n = len(self.links)
        var e = Real(0)
        var poses = self.fk()
        var ws2 = List[Vec3]()
        var vs2 = List[Vec3]()
        for i in range(n):
            var l = self.links[i]
            var pi = self.parent[i]
            var w_p = ws2[pi] if pi >= 0 else Vec3(0, 0, 0, 0)
            var v_p = vs2[pi] if pi >= 0 else Vec3(0, 0, 0, 0)
            var rt = _rot_rows(self._joint_rot(i))
            # same motion subspace and moving origin as `link_motion`: a
            # prismatic joint adds axis*qd to v, not w (ROADMAP 17.17 found
            # this treating every joint as revolute)
            var rev = l.kind == JOINT_REVOLUTE
            var s_w = l.axis if rev else Vec3(0, 0, 0, 0)
            var s_v = Vec3(0, 0, 0, 0) if rev else l.axis
            var w = _matvec(rt, w_p) + s_w * self.qd[i]
            var v = _matvec(rt, v_p + cross(w_p, self._joint_offset(i))) + s_v * self.qd[i]
            var ii = SpInertia.of_link(l.mass, l.com, l.i_diag)
            var mom = ii.apply(w, v)
            e += (dot(w, mom[0]) + dot(v, mom[1])) * 0.5
            var com_w = poses[i].apply_point(l.com)
            e -= l.mass * dot(gravity, com_w)
            ws2.append((w))
            vs2.append((v))
        return e


def _cross_mat_mul(a: Vec3, b: Vec3) -> _Rows3:
    """Rows of [a]× [b]× (product of two cross matrices)."""
    var r = _Rows3(fill=Vec3(0, 0, 0, 0))
    var ab = dot(a, b)
    for i in range(3):
        var row = Vec3(0, 0, 0, 0)
        for j in range(3):
            var v = b[i] * a[j]
            if i == j:
                v -= ab
            row[j] = v
        r[i] = row
    return r^


def _transpose_row(m: _Rows3, r: Int) -> Vec3:
    return Vec3(m[0][r], m[1][r], m[2][r], 0)


def _skew(p: Vec3) -> _Rows3:
    """Rows of [p]×."""
    var r = _Rows3(fill=Vec3(0, 0, 0, 0))
    r[0] = Vec3(0, -p[2], p[1], 0)
    r[1] = Vec3(p[2], 0, -p[0], 0)
    r[2] = Vec3(-p[1], p[0], 0, 0)
    return r^


def _outer_scaled(u: Vec3, v: Vec3, s: Real) -> _Rows3:
    """Rows of s·(u vᵀ)."""
    var r = _Rows3(fill=Vec3(0, 0, 0, 0))
    for i in range(3):
        r[i] = v * (u[i] * s)
    return r^


def _matmul(x: _Rows3, y: _Rows3) -> _Rows3:
    """Rows of X·Y (both given as rows)."""
    var r = _Rows3(fill=Vec3(0, 0, 0, 0))
    for i in range(3):
        r[i] = y[0] * x[i][0] + y[1] * x[i][1] + y[2] * x[i][2]
    return r^


def _madd(a: _Rows3, b: _Rows3) -> _Rows3:
    var r = _Rows3(fill=Vec3(0, 0, 0, 0))
    for i in range(3):
        r[i] = a[i] + b[i]
    return r^


def _msub(a: _Rows3, b: _Rows3) -> _Rows3:
    var r = _Rows3(fill=Vec3(0, 0, 0, 0))
    for i in range(3):
        r[i] = a[i] - b[i]
    return r^


def _transpose(m: _Rows3) -> _Rows3:
    var r = _Rows3(fill=Vec3(0, 0, 0, 0))
    for i in range(3):
        r[i] = Vec3(m[0][i], m[1][i], m[2][i], 0)
    return r^


def _tmatvec(m: _Rows3, v: Vec3) -> Vec3:
    """Mᵀ·v for M given as rows."""
    return m[0] * v[0] + m[1] * v[1] + m[2] * v[2]


def _rot_mat(q: Quat, m: _Rows3) -> _Rows3:
    """Rows of R·M·Rᵀ for a general 3x3 M (column-wise, like dynamics())."""
    var rt = _rot_rows(q)
    var c0 = q.rotate(_matvec(m, _matvec(rt, Vec3(1, 0, 0, 0))))
    var c1 = q.rotate(_matvec(m, _matvec(rt, Vec3(0, 1, 0, 0))))
    var c2 = q.rotate(_matvec(m, _matvec(rt, Vec3(0, 0, 1, 0))))
    var r = _Rows3(fill=Vec3(0, 0, 0, 0))
    for i in range(3):
        r[i] = Vec3(c0[i], c1[i], c2[i], 0)
    return r^


@fieldwise_init
struct _ABI(Copyable, ImplicitlyCopyable, Movable):
    """Articulated-body inertia: symmetric 6x6 in {angular, linear} blocks
    [[A, B], [Bᵀ, D]]; the rank-1 U Uᵀ/d update breaks the rigid compact
    form, so ABA carries these where CRBA kept {m, h, I_o}."""

    var a: _Rows3
    var b: _Rows3
    var d: _Rows3

    def __init__(out self, *, copy: Self):
        """Explicit copy: `Array` is not `ImplicitlyCopyable` in
        Mojo 1.0, so a struct holding one gets no synthesised copy."""
        self.a = copy.a.copy()
        self.b = copy.b.copy()
        self.d = copy.d.copy()

    @staticmethod
    def of(ii: SpInertia) -> Self:
        var b = _skew(ii.h)
        var d = _Rows3(fill=Vec3(0, 0, 0, 0))
        d[0] = Vec3(ii.m, 0, 0, 0)
        d[1] = Vec3(0, ii.m, 0, 0)
        d[2] = Vec3(0, 0, ii.m, 0)
        return Self(ii.io.copy(), b^, d^)

    def apply(self, w: Vec3, v: Vec3) -> Tuple[Vec3, Vec3]:
        """Force = [[A, B], [Bᵀ, D]] · (w, v)."""
        return (
            _matvec(self.a, w) + _matvec(self.b, v),
            _tmatvec(self.b, w) + _matvec(self.d, v),
        )


# ------------------------------------------------------------ snapshot (17.51)


def write_chain[W: StateWriter](ch: Chain, mut out: W):
    """Everything `Chain` steps from: links, tree, joint state, root motion,
    joint properties (ROADMAP 17.51; `read_chain` restores it exactly)."""
    out.wi(len(ch.links))
    for i in range(len(ch.links)):
        var l = ch.links[i]
        out.wv(l.axis)
        out.wv(l.pivot)
        out.wv(l.com)
        out.wf(l.mass)
        out.wv(l.i_diag)
        out.wi(l.kind)
        out.wf(l.lo)
        out.wf(l.hi)
        out.wi(ch.parent[i])
        out.wf(ch.q[i])
        out.wf(ch.qd[i])
        out.wf(ch.damping[i])
        out.wf(ch.stiffness[i])
        out.wf(ch.rest[i])
        out.wf(ch.armature[i])
        out.wf(ch.friction[i])
    out.wv(ch._base_w)
    out.wv(ch._base_v)
    out.wv(ch._base_wa)
    out.wv(ch._base_va)
    out.wi(len(ch.balls))
    for b in range(len(ch.balls)):
        var h = ch.balls[b]
        out.wi(h)
        var r = ch.ball_rot[h]
        out.wf(r.x)
        out.wf(r.y)
        out.wf(r.z)
        out.wf(r.w)
        var lim = ch.ball_lim[b]
        out.wv(lim.axis)
        out.wv(lim.ref_dir)
        out.wf(lim.ref_rot.x)
        out.wf(lim.ref_rot.y)
        out.wf(lim.ref_rot.z)
        out.wf(lim.ref_rot.w)
        out.wf(lim.swing)
        out.wf(lim.twist_lo)
        out.wf(lim.twist_hi)


def read_chain[R: StateReader](mut r: R) raises -> Chain:
    var ch = Chain()
    var n = r.ri()
    if n < 0:
        raise Error("physics.chain: corrupt snapshot (negative link count)")
    for _ in range(n):
        var axis = r.rv()
        var pivot = r.rv()
        var com = r.rv()
        var mass = r.rf()
        var idiag = r.rv()
        var kind = r.ri()
        var lo = r.rf()
        var hi = r.rf()
        var p = r.ri()
        var i = ch.add_link_to(p, ChainLink(axis, pivot, com, mass, idiag, kind, lo, hi))
        ch.q[i] = r.rf()
        ch.qd[i] = r.rf()
        ch.damping[i] = r.rf()
        ch.stiffness[i] = r.rf()
        ch.rest[i] = r.rf()
        ch.armature[i] = r.rf()
        ch.friction[i] = r.rf()
    var bw = r.rv()
    var bv = r.rv()
    var bwa = r.rv()
    var bva = r.rv()
    ch.set_base_motion(bw, bv, bwa, bva)
    var nb = r.ri()
    if nb < 0 or 3 * nb > n:
        raise Error("physics.chain: corrupt snapshot (ball count)")
    for _ in range(nb):
        var h = r.ri()
        if h < 0 or h + 2 >= n:
            raise Error("physics.chain: corrupt snapshot (ball link index)")
        var qx = r.rf()
        var qy = r.rf()
        var qz = r.rf()
        var qw = r.rf()
        ch.ball_head[h] = True
        ch.ball_rot[h] = Quat(qx, qy, qz, qw)
        ch.balls.append(h)
        var la = r.rv()
        var lr = r.rv()
        var rx = r.rf()
        var ry = r.rf()
        var rz = r.rf()
        var rw = r.rf()
        var sw = r.rf()
        var tlo = r.rf()
        var thi = r.rf()
        ch.ball_lim.append(BallLimit(la, lr, Quat(rx, ry, rz, rw), sw, tlo, thi))
    return ch^
