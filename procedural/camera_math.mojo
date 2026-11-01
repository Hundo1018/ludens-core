"""Camera math for the simulation side (ROADMAP 17.68).

  * `CameraPose`: position, orientation (looking down local -z, y up), field
    of view, aspect, near / far -- the value a host reads each frame.
  * `perspective` / `ortho`: reference projection matrices (right-handed,
    column vectors, clip z in [-1, 1], the OpenGL convention), so host and
    simulation agree on what "in view" means.
  * `Frustum`: the six inward planes of a camera; sphere and AABB tests for
    simulation queries (AI sight cones, observer sets) -- render culling is
    the host's.
  * `spring_damp`: a critically damped spring with a half-life (Holden's
    form), exact for any dt; `spring_damp_quat` springs an orientation along
    the shortest arc.
  * `Shake`: trauma-based camera shake (Eiserloh, GDC 2016): trauma decays
    linearly, the offset is trauma^2 x max x seeded noise of time, so the same
    seed and time give the same shake.
  * `CamSpring` (a seam, `SPRING_SPLIT` / `SPRING_MOTOR`): a critically damped
    spring on a whole pose with velocity state. SPLIT springs the position
    and the rotation (as a rotation vector) separately; MOTOR springs the
    6-vector log of the pose relative to the target, so a rotation about a
    pivot follows the screw (an arc around the pivot) instead of the chord.
    They agree for pure translation and for pure rotation.
  * `frame_targets`: where to put a camera looking along a direction so a set
    of spheres is inside the view (bounding sphere of the spheres).
  * `DollyRail`: a camera on a spline rail (17.36 arc-length table and
    rotation-minimising frames) that slides to the rail point nearest the
    target with a spring and looks at it, the frame's normal as up.
"""

from std.math import sqrt, tan, exp, acos, atan, isfinite
from geometry.trig import sin
from geometry.vec import Real, Vec3, dot, cross, length
from geometry.quat import Quat, slerp
from geometry.mat import Mat4
from geometry.motor import Motor3
from geometry.galie import Screw3, exp_screw3, log_motor3
from geometry.spline import BezierPath, ArcLengthTable, build_arc_length_table, build_rmf_frames, frame_at_distance, closest_point
from .noise import perlin2

comptime SPRING_SPLIT = 0
comptime SPRING_MOTOR = 1


@fieldwise_init
struct CameraPose(Copyable, ImplicitlyCopyable, Movable):
    var position: Vec3
    var rotation: Quat
    var fov_y: Real  # radians
    var aspect: Real
    var near: Real
    var far: Real

    def forward(self) -> Vec3:
        return self.rotation.rotate(Vec3(0, 0, -1, 0))

    def up(self) -> Vec3:
        return self.rotation.rotate(Vec3(0, 1, 0, 0))

    def right(self) -> Vec3:
        return self.rotation.rotate(Vec3(1, 0, 0, 0))


def look_rotation(forward: Vec3, up_hint: Vec3) -> Quat:
    """Orientation whose -z axis is `forward`. When `forward` is parallel to
    `up_hint` (looking straight up or down) a fallback up of +z is used, so
    the result never degenerates."""
    var f = forward / max(length(forward), Real(1e-12))
    var r = cross(f, up_hint)
    if length(r) < 1e-6:
        r = cross(f, Vec3(0, 0, 1, 0))
    r = r / length(r)
    var u = cross(r, f)
    # rotation matrix with columns r, u, -f -> quaternion
    var m00 = r[0]
    var m11 = u[1]
    var m22 = -f[2]
    var tr = m00 + m11 + m22
    var q: Quat
    if tr > 0:
        var s = sqrt(tr + 1) * 2
        q = Quat((u[2] - (-f[1])) / s, ((-f[0]) - r[2]) / s, (r[1] - u[0]) / s, 0.25 * s)
    elif m00 > m11 and m00 > m22:
        var s = sqrt(1 + m00 - m11 - m22) * 2
        q = Quat(0.25 * s, (u[0] + r[1]) / s, ((-f[0]) + r[2]) / s, (u[2] - (-f[1])) / s)
    elif m11 > m22:
        var s = sqrt(1 + m11 - m00 - m22) * 2
        q = Quat((u[0] + r[1]) / s, 0.25 * s, ((-f[1]) + u[2]) / s, ((-f[0]) - r[2]) / s)
    else:
        var s = sqrt(1 + m22 - m00 - m11) * 2
        q = Quat(((-f[0]) + r[2]) / s, ((-f[1]) + u[2]) / s, 0.25 * s, (r[1] - u[0]) / s)
    return q.normalized()


def perspective(fov_y: Real, aspect: Real, near: Real, far: Real) -> Mat4:
    var f = 1 / tan(fov_y / 2)
    var m = Mat4()
    m.set(0, 0, f / aspect)
    m.set(1, 1, f)
    m.set(2, 2, (far + near) / (near - far))
    m.set(2, 3, 2 * far * near / (near - far))
    m.set(3, 2, -1)
    return m^


def ortho(half_w: Real, half_h: Real, near: Real, far: Real) -> Mat4:
    var m = Mat4()
    m.set(0, 0, 1 / half_w)
    m.set(1, 1, 1 / half_h)
    m.set(2, 2, -2 / (far - near))
    m.set(2, 3, -(far + near) / (far - near))
    m.set(3, 3, 1)
    return m^


@fieldwise_init
struct Plane(Copyable, ImplicitlyCopyable, Movable):
    var n: Vec3  # unit, pointing into the frustum
    var d: Real  # dot(n, p) + d >= 0 inside


struct Frustum(Copyable, Movable):
    var planes: List[Plane]

    def __init__(out self, cam: CameraPose):
        var f = cam.forward()
        var u = cam.up()
        var r = cam.right()
        var p = cam.position
        var th = tan(cam.fov_y / 2)
        var tw = th * cam.aspect
        self.planes = List[Plane]()
        self.planes.append(Plane(f, -dot(f, p + f * cam.near)))  # near
        self.planes.append(Plane(-f, dot(f, p + f * cam.far)))  # far
        # side planes pass through the eye
        # (camera basis: r x u = -f) each normal points into the frustum
        var nl = cross(f - r * tw, u)  # left edge -> normal toward +r
        var nr = cross(u, f + r * tw)  # right edge -> toward -r
        var nt = cross(f + u * th, r)  # top edge -> toward -u
        var nb = cross(r, f - u * th)  # bottom edge -> toward +u
        for n0 in [nl, nr, nt, nb]:
            var n = n0 / length(n0)
            self.planes.append(Plane(n, -dot(n, p)))

    def sphere_visible(self, c: Vec3, radius: Real) -> Bool:
        for pl in self.planes:
            if dot(pl.n, c) + pl.d < -radius:
                return False
        return True

    def sphere_inside(self, c: Vec3, radius: Real) -> Bool:
        """The whole sphere is inside every plane."""
        for pl in self.planes:
            if dot(pl.n, c) + pl.d < radius:
                return False
        return True

    def aabb_visible(self, lo: Vec3, hi: Vec3) -> Bool:
        """Conservative: False only when the box is wholly outside one
        plane (the positive-vertex test)."""
        for pl in self.planes:
            var px = hi[0] if pl.n[0] >= 0 else lo[0]
            var py = hi[1] if pl.n[1] >= 0 else lo[1]
            var pz = hi[2] if pl.n[2] >= 0 else lo[2]
            if dot(pl.n, Vec3(px, py, pz, 0)) + pl.d < 0:
                return False
        return True


def spring_damp(x: Vec3, v: Vec3, target: Vec3, half_life: Real, dt: Real) -> Tuple[Vec3, Vec3]:
    """Critically damped spring toward `target` (exact solution, any dt);
    returns (position, velocity). `half_life` is the time to halve the gap."""
    var y = 4 * 0.69314718 / max(half_life, Real(1e-6)) / 2
    var j0 = x - target
    var j1 = v + j0 * y
    var e = exp(-y * dt)
    return (target + (j0 + j1 * dt) * e, (v - j1 * (y * dt)) * e)


def spring_damp_quat(q: Quat, target: Quat, half_life: Real, dt: Real) -> Quat:
    """Move `q` toward `target` along the shortest arc by the fraction a
    critically damped spring (starting at rest) closes in `dt`."""
    var y = 4 * 0.69314718 / max(half_life, Real(1e-6)) / 2
    var closed = 1 - (1 + y * dt) * exp(-y * dt)
    var t = target
    if q.x * t.x + q.y * t.y + q.z * t.z + q.w * t.w < 0:
        t = Quat(-t.x, -t.y, -t.z, -t.w)
    return slerp(q, t, closed).normalized()


struct Shake(Copyable, Movable):
    var trauma: Real
    var decay: Real  # trauma lost per second
    var max_offset: Real  # metres at trauma 1
    var max_angle: Real  # radians at trauma 1
    var freq: Real  # noise samples per second
    var seed: Int

    def __init__(out self, seed: Int, max_offset: Real = 0.3, max_angle: Real = 0.1, decay: Real = 1, freq: Real = 15):
        self.trauma = 0
        self.decay = decay
        self.max_offset = max_offset
        self.max_angle = max_angle
        self.freq = freq
        self.seed = seed

    def add(mut self, amount: Real):
        self.trauma = min(Real(1), max(Real(0), self.trauma + amount))

    def advance(mut self, dt: Real):
        self.trauma = max(Real(0), self.trauma - self.decay * dt)

    def offset(self, t: Real) -> Tuple[Vec3, Vec3]:
        """(translation, small rotation angles about x / y / z) at time t."""
        var s = self.trauma * self.trauma
        var u = t * self.freq
        var p = Vec3(perlin2(u, 0.5, self.seed), perlin2(u, 1.5, self.seed), perlin2(u, 2.5, self.seed), 0) * (s * self.max_offset)
        var a = Vec3(perlin2(u, 3.5, self.seed), perlin2(u, 4.5, self.seed), perlin2(u, 5.5, self.seed), 0) * (s * self.max_angle)
        return (p, a)


def _spring_rate(half_life: Real) -> Real:
    return 4 * 0.69314718 / max(half_life, Real(1e-6)) / 2


struct CamSpring(Copyable, Movable):
    """Critically damped spring on a camera pose (position + rotation) with
    velocity state. `mode` = SPRING_SPLIT or SPRING_MOTOR (see the module
    note); `va` / `vb` are the rates of the translation / rotation parts
    (world velocity and rotation-vector rate for SPLIT, the screw's parts in
    the target frame for MOTOR)."""

    var mode: Int
    var half_life: Real
    var position: Vec3
    var rotation: Quat
    var va: Vec3
    var vb: Vec3

    def __init__(out self, mode: Int, half_life: Real, position: Vec3, rotation: Quat) raises:
        if mode != SPRING_SPLIT and mode != SPRING_MOTOR:
            raise Error("CamSpring: mode must be SPRING_SPLIT or SPRING_MOTOR")
        if not (half_life > 0):
            raise Error("CamSpring: half_life must be > 0")
        self.mode = mode
        self.half_life = half_life
        self.position = position
        self.rotation = rotation
        self.va = Vec3(0, 0, 0, 0)
        self.vb = Vec3(0, 0, 0, 0)

    def update(mut self, target_pos: Vec3, target_rot: Quat, dt: Real):
        """One step of `dt` toward the target pose. `dt <= 0` or a
        non-finite target changes nothing."""
        if not (dt > 0) or not (isfinite(target_pos[0]) and isfinite(target_pos[1]) and isfinite(target_pos[2])):
            return
        var t = target_rot
        var q = self.rotation
        if q.x * t.x + q.y * t.y + q.z * t.z + q.w * t.w < 0:
            t = Quat(-t.x, -t.y, -t.z, -t.w)
        var zero = Vec3(0, 0, 0, 0)
        if self.mode == SPRING_SPLIT:
            var pr = spring_damp(self.position, self.va, target_pos, self.half_life, dt)
            self.position = pr[0]
            self.va = pr[1]
            var tm = Motor3.from_quat(t)
            var d = log_motor3(tm.reverse() * Motor3.from_quat(q))
            var rr = spring_damp(Vec3(d.b12, d.b13, d.b23, 0), self.vb, zero, self.half_life, dt)
            self.vb = rr[1]
            var e = rr[0]
            var m = (tm * exp_screw3(Screw3(e[0], e[1], e[2], 0, 0, 0))).normalized()
            self.rotation = m.to_quat_translation()[0].normalized()
            return
        var tm = Motor3.from_quat_translation(t, target_pos)
        var d = log_motor3(tm.reverse() * Motor3.from_quat_translation(q, self.position))
        var rr = spring_damp(Vec3(d.b12, d.b13, d.b23, 0), self.vb, zero, self.half_life, dt)
        var tr = spring_damp(Vec3(d.b10, d.b20, d.b30, 0), self.va, zero, self.half_life, dt)
        self.vb = rr[1]
        self.va = tr[1]
        var e = rr[0]
        var f = tr[0]
        var m = (tm * exp_screw3(Screw3(e[0], e[1], e[2], f[0], f[1], f[2]))).normalized()
        var qt = m.to_quat_translation()
        self.rotation = qt[0].normalized()
        self.position = qt[1]

    def pose(self, fov_y: Real, aspect: Real, near: Real, far: Real) -> CameraPose:
        return CameraPose(self.position, self.rotation, fov_y, aspect, near, far)


def frame_targets(centers: List[Vec3], radii: List[Real], direction: Vec3, fov_y: Real, aspect: Real) raises -> Vec3:
    """Camera position looking along `direction` with every sphere inside
    the view: the spheres' bounding sphere (centre = middle of their box) at
    the distance where it fits the narrower of the two field-of-view
    half-angles. Raises on no targets, mismatched lists, a zero direction or
    a field of view outside (0, pi)."""
    var n = len(centers)
    if n == 0 or len(radii) != n:
        raise Error("frame_targets: need one radius per centre and at least one target")
    if not (fov_y > 0 and fov_y < 3.14159265) or not (aspect > 0):
        raise Error("frame_targets: fov_y must be in (0, pi) and aspect > 0")
    var l = length(direction)
    if not (l > 0):
        raise Error("frame_targets: zero direction")
    var lo = centers[0]
    var hi = centers[0]
    for i in range(n):
        lo = min(lo, centers[i])
        hi = max(hi, centers[i])
    var c = (lo + hi) * 0.5
    var r = Real(0)
    for i in range(n):
        r = max(r, length(centers[i] - c) + max(radii[i], Real(0)))
    var half = min(fov_y / 2, atan(tan(fov_y / 2) * aspect))
    return c - direction / l * (r / sin(half))


struct DollyRail(Copyable, Movable):
    """A camera on a spline rail: it slides (critically damped, along arc
    length) toward the rail point nearest the target and looks at the
    target with the rail's rotation-minimising normal as up, so it does not
    roll where the rail turns vertical."""

    var path: BezierPath[3]
    var table: ArcLengthTable
    var frames: List[Motor3]
    var s: Real  # arc length of the camera on the rail
    var speed: Real  # along the rail, m/s
    var half_life: Real

    def __init__(out self, var path: BezierPath[3], samples: Int = 128, half_life: Real = 0.3) raises:
        if samples < 2:
            raise Error("DollyRail: need at least 2 samples")
        self.table = build_arc_length_table[3](path, samples)
        self.frames = build_rmf_frames(path, self.table)
        self.path = path^
        self.s = 0
        self.speed = 0
        self.half_life = half_life

    def length(self) -> Real:
        return self.table.total_length()

    def nearest_s(self, p: Vec3) -> Real:
        """Arc length of the rail point nearest `p`."""
        var t = closest_point[3](self.path, p)
        ref ts = self.table.ts
        var n = len(ts)
        if t <= ts[0]:
            return 0
        if t >= ts[n - 1]:
            return self.table.cum[n - 1]
        var lo = 0
        var hi = n - 1
        while hi - lo > 1:
            var mid = (lo + hi) // 2
            if ts[mid] <= t:
                lo = mid
            else:
                hi = mid
        var f = (t - ts[lo]) / (ts[hi] - ts[lo])
        return self.table.cum[lo] + f * (self.table.cum[hi] - self.table.cum[lo])

    def update(mut self, target: Vec3, dt: Real, fov_y: Real = 1.0, aspect: Real = 16.0 / 9.0) -> CameraPose:
        """One step: slide toward the nearest rail point, look at `target`.
        `dt <= 0` or a non-finite target only re-evaluates the pose."""
        if dt > 0 and isfinite(target[0]) and isfinite(target[1]) and isfinite(target[2]):
            var goal = self.nearest_s(target)
            var y = _spring_rate(self.half_life)
            var j0 = self.s - goal
            var j1 = self.speed + j0 * y
            var e = exp(-y * dt)
            self.s = min(max(goal + (j0 + j1 * dt) * e, Real(0)), self.length())
            self.speed = (self.speed - j1 * (y * dt)) * e
        var fr = frame_at_distance(self.frames, self.table, self.s)
        var qt = fr.to_quat_translation()
        var pos = qt[1]
        var up = qt[0].rotate(Vec3(0, 1, 0, 0))
        var look = target - pos
        if not (length(look) > 1e-9) or not isfinite(look[0]):
            look = qt[0].rotate(Vec3(0, 0, 1, 0))
        return CameraPose(pos, look_rotation(look, up), fov_y, aspect, 0.1, 1000)
