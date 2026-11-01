"""Lifting surfaces (ROADMAP 17.74).

`Wing` is a force element: a flat lifting surface at a body-fixed point
with a chord direction and a lift-reference normal. From the air velocity
relative to that point (wind - body point velocity) it takes the angle of
attack alpha in the chord-normal plane and applies
lift = q A CL(alpha) perpendicular to the relative air, in that plane, and
drag = q A CD(alpha) along it, q = rho |v|^2 / 2.

CL / CD: thin-airfoil CL = 2 pi alpha (times `cl_scale`) up to the stall
angle; past it a flat plate, CL = sin 2 alpha, CD = 2 sin^2 alpha, blended
over `stall_blend` radians so the curve is continuous. Pre-stall
CD = cd0 + k CL^2. Defined for any alpha in [-pi, pi] (tumbling).
"""

from std.math import atan2, pi, sqrt
from geometry.trig import sin, cos
from geometry.vec import Real, Vec3, dot, cross, length
from physics.body_set import BodyId
from physics.rigid6 import QuatBody6
from physics.solver6 import ContactScene6
from .force_element import ForceElement


@fieldwise_init
struct Wing(ForceElement, Copyable, Movable):
    var local_pos: Vec3
    var local_chord: Vec3  # unit, leading edge direction (forward)
    var local_normal: Vec3  # unit, lift reference (up), perpendicular to chord
    var area: Real
    var rho: Real
    var wind: Vec3
    var cl_scale: Real
    var stall: Real  # radians
    var stall_blend: Real
    var cd0: Real
    var k_induced: Real
    var table_cl: List[Real]  # polar samples at alpha = i * table_step on [0, pi / 2]; empty: analytic model
    var table_cd: List[Real]
    var table_step: Real

    @staticmethod
    def simple(local_pos: Vec3, area: Real) -> Wing:
        return Wing(local_pos, Vec3(1, 0, 0, 0), Vec3(0, 1, 0, 0), area, 1.225, Vec3(0, 0, 0, 0), 1, 0.26, 0.1, 0.02, 0.05, List[Real](), List[Real](), 0)

    def set_polar(mut self, var cl: List[Real], var cd: List[Real], step: Real) raises:
        """Use a sampled polar of a symmetric section (e.g. from `plate_polar`)
        instead of the analytic model: `cl[i]`, `cd[i]` at alpha = i step from
        0 to pi / 2, odd in alpha for CL and mirrored about pi / 2 beyond."""
        if len(cl) != len(cd) or len(cl) < 2 or step <= 0:
            raise Error("Wing.set_polar: equal-length tables of >= 2 samples and step > 0")
        self.table_cl = cl^
        self.table_cd = cd^
        self.table_step = step

    def _tabulated(self, alpha: Real) -> Tuple[Real, Real]:
        var a = abs(alpha)
        var sign = Real(1) if alpha >= 0 else Real(-1)
        if a > Real(pi) / 2:
            a = Real(pi) - a
            sign = -sign  # CL is odd about pi / 2 for a symmetric section
        var x = a / self.table_step
        var n = len(self.table_cl)
        var i = Int(x)
        if i >= n - 1:
            return (sign * self.table_cl[n - 1], self.table_cd[n - 1])
        var f = x - Real(i)
        return (sign * (self.table_cl[i] * (1 - f) + self.table_cl[i + 1] * f), self.table_cd[i] * (1 - f) + self.table_cd[i + 1] * f)

    def coefficients(self, alpha: Real) -> Tuple[Real, Real]:
        if len(self.table_cl) > 0:
            return self._tabulated(alpha)
        var lin_cl = self.cl_scale * 2 * Real(pi) * alpha
        var lin_cd = self.cd0 + self.k_induced * lin_cl * lin_cl
        var plate_cl = sin(2 * alpha)
        var plate_cd = 2 * sin(alpha) * sin(alpha)
        var a = abs(alpha)
        if a <= self.stall:
            return (lin_cl, lin_cd)
        if a >= self.stall + self.stall_blend:
            return (plate_cl, max(plate_cd, self.cd0))
        var u = (a - self.stall) / self.stall_blend
        var s_cl = self.cl_scale * 2 * Real(pi) * self.stall * (Real(1) if alpha > 0 else Real(-1))
        var s_cd = self.cd0 + self.k_induced * s_cl * s_cl
        return (s_cl * (1 - u) + plate_cl * u, s_cd * (1 - u) + max(plate_cd, self.cd0) * u)

    def apply(mut self, mut sc: ContactScene6[QuatBody6], id: BodyId, t: Real) raises -> Vec3:
        var pose = sc.pose(id)
        var p = pose.pos + pose.rot.rotate(self.local_pos)
        var i = id.index()
        var air = self.wind - sc.bset.bodies[i].velocity_at(p)
        var chord = pose.rot.rotate(self.local_chord)
        var nrm = pose.rot.rotate(self.local_normal)
        # relative wind in the chord-normal plane (the span component does
        # not make lift)
        var u = dot(air, chord)
        var w = dot(air, nrm)
        var v2 = u * u + w * w
        if v2 < 1e-12:
            return Vec3(0, 0, 0, 0)
        # air flowing toward -chord (aircraft moving forward) at alpha > 0
        # comes from below: w > 0
        var alpha = atan2(w, -u)
        var c = self.coefficients(alpha)
        var q = Real(0.5) * self.rho * v2 * self.area
        var vel = chord * u + nrm * w  # air velocity in the plane
        var dir_d = vel * (1 / sqrt(v2))
        var span = cross(chord, nrm)
        var dir_l = cross(dir_d, span)  # perpendicular to the air, in the plane
        if dot(dir_l, nrm) * cos(alpha) < 0:
            dir_l = dir_l * Real(-1)
        var f = dir_l * (q * c[0]) + dir_d * (q * c[1])
        sc.add_force_at(id, f, p)
        return f
