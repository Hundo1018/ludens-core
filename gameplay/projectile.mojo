"""Ballistic projectiles (ROADMAP 17.71).

A fixed-capacity `ProjectileSet` (the pool: spawning when full drops the new
projectile and counts it in `dropped`, the hot-path row of
`docs/ARCHITECTURE.md` §2). Each step moves every live projectile under
gravity and drag and casts a ray along the segment it travelled, so a fast
round cannot skip a thin wall between ticks (no CCD needed). A hit stops
the projectile, is reported, and optionally hands `mass x velocity` to the
body as an impulse at the hit point.

Drag: DRAG_LINEAR (acceleration -k v) is integrated exactly per step (the
closed form, so the landing point matches the analytic trajectory for any
dt); DRAG_QUADRATIC (-k |v| v) has no closed form with gravity and uses one
RK4 step per tick.

Optional behaviours (ROADMAP 17.71, all off by default):

  * ricochet: a hit whose angle to the surface is below `ricochet_deg`
    reflects the velocity (times `restitution`) instead of stopping;
  * penetration: each projectile carries `penetration` metres of reference
    material; a body's resistance (`set_resistance`, default 1) multiplies
    its thickness, found with a ray cast back from `penetration /
    resistance` beyond the entry. If the projectile has enough left it exits
    the far side with its speed scaled by sqrt(left / before) (kinetic
    energy proportional to what is left), otherwise it stops;
  * homing: `set_homing(i, body, turn_rate)` turns the velocity toward the
    body's centre by at most `turn_rate` rad/s, keeping the speed;
  * proximity fuse: `fuse_radius` > 0 detonates a projectile whose step
    passes within that distance of a `fuse_targets` body's centre (before
    any surface hit further along the step).

A ricochet, a penetration or a fuse ends that projectile's travel for the
tick at the bounce / exit / detonation point. Every hit reports its kind
and the distance flown so far (for damage falloff, 17.70).

`lead_direction` gives the aim direction that intercepts a target moving at
constant velocity (no gravity), or zero when the target outruns the shot.
"""

from std.math import exp, sqrt, isfinite, acos
from geometry.trig import cos
from geometry.vec import Real, Vec3, dot, cross, length
from geometry.quat import Quat
from collision.world_query import QueryFilter
from collision.broadphase import BroadPhase
from physics.rigid6 import Body6
from physics.solver6 import ContactScene6

comptime DRAG_LINEAR = 0
comptime DRAG_QUADRATIC = 1

comptime HIT_STOP = 0
comptime HIT_PENETRATE = 1
comptime HIT_RICOCHET = 2
comptime HIT_FUSE = 3


@fieldwise_init
struct ProjectileHit(Copyable, ImplicitlyCopyable, Movable):
    var projectile: Int
    var body: Int
    var point: Vec3
    var normal: Vec3
    var velocity: Vec3
    var kind: Int  # HIT_STOP / HIT_PENETRATE / HIT_RICOCHET / HIT_FUSE
    var travelled: Real  # metres flown before this hit


def lead_direction(shooter: Vec3, speed: Real, target: Vec3, target_vel: Vec3) -> Vec3:
    """Unit aim direction for a shot at `speed` to meet a target moving at
    `target_vel` (straight lines, no gravity), the earliest intercept; zero
    when there is none."""
    var r = target - shooter
    var a = dot(target_vel, target_vel) - speed * speed
    var b = 2 * dot(r, target_vel)
    var c = dot(r, r)
    var t: Real
    if abs(a) < 1e-9:
        if abs(b) < 1e-12:
            return Vec3(0, 0, 0, 0)
        t = -c / b
    else:
        var disc = b * b - 4 * a * c
        if disc < 0:
            return Vec3(0, 0, 0, 0)
        var sq = sqrt(disc)
        var t1 = (-b - sq) / (2 * a)
        var t2 = (-b + sq) / (2 * a)
        t = min(t1, t2) if min(t1, t2) > 0 else max(t1, t2)
    if not (t > 0):
        return Vec3(0, 0, 0, 0)
    var d = r + target_vel * t
    var l = length(d)
    return d / l if l > 0 else Vec3(0, 0, 0, 0)


struct ProjectileSet(Movable):
    var pos: List[Vec3]
    var vel: List[Vec3]
    var alive: List[Bool]
    var capacity: Int
    var drag_kind: Int
    var k: Real
    var mass: Real
    var dropped: Int
    var filter: QueryFilter
    var pen: List[Real]  # metres of reference material left
    var travelled: List[Real]
    var home_body: List[Int]
    var home_rate: List[Real]
    var penetration: Real  # given to each new projectile
    var ricochet_deg: Real  # 0 = never
    var restitution: Real
    var resist: List[Real]  # per body index; missing = 1
    var fuse_radius: Real
    var fuse_targets: List[Int]

    def __init__(out self, capacity: Int, drag_kind: Int = DRAG_LINEAR, k: Real = 0, mass: Real = 0) raises:
        if capacity < 1:
            raise Error("ProjectileSet: capacity must be >= 1")
        self.pos = List[Vec3]()
        self.vel = List[Vec3]()
        self.alive = List[Bool]()
        self.capacity = capacity
        self.drag_kind = drag_kind
        self.k = k
        self.mass = mass
        self.dropped = 0
        self.filter = QueryFilter.all()
        self.pen = List[Real]()
        self.travelled = List[Real]()
        self.home_body = List[Int]()
        self.home_rate = List[Real]()
        self.penetration = 0
        self.ricochet_deg = 0
        self.restitution = 0.6
        self.resist = List[Real]()
        self.fuse_radius = 0
        self.fuse_targets = List[Int]()

    def set_resistance(mut self, body: Int, r: Real) raises:
        """Penetration cost per metre of `body` (1 = reference; larger is
        harder). Raises on a negative body index or r <= 0."""
        if body < 0 or not (r > 0):
            raise Error("ProjectileSet.set_resistance: body >= 0 and r > 0")
        while len(self.resist) <= body:
            self.resist.append(1)
        self.resist[body] = r

    def set_homing(mut self, i: Int, body: Int, turn_rate: Real) raises:
        if i < 0 or i >= len(self.alive) or not (turn_rate >= 0):
            raise Error("ProjectileSet.set_homing: bad projectile or turn rate")
        self.home_body[i] = body
        self.home_rate[i] = turn_rate

    def _resist(self, body: Int) -> Real:
        return self.resist[body] if body >= 0 and body < len(self.resist) else Real(1)

    def live(self) -> Int:
        var n = 0
        for a in self.alive:
            if a:
                n += 1
        return n

    def spawn(mut self, p: Vec3, v: Vec3) -> Int:
        """Index of the new projectile, or -1 (counted in `dropped`) when the
        pool is full or the input is not finite."""
        if not (isfinite(p[0]) and isfinite(p[1]) and isfinite(p[2]) and isfinite(v[0]) and isfinite(v[1]) and isfinite(v[2])):
            self.dropped += 1
            return -1
        for i in range(len(self.alive)):
            if not self.alive[i]:
                self.pos[i] = p
                self.vel[i] = v
                self.alive[i] = True
                self.pen[i] = self.penetration
                self.travelled[i] = 0
                self.home_body[i] = -1
                self.home_rate[i] = 0
                return i
        if len(self.alive) >= self.capacity:
            self.dropped += 1
            return -1
        self.pos.append(p)
        self.vel.append(v)
        self.alive.append(True)
        self.pen.append(self.penetration)
        self.travelled.append(0)
        self.home_body.append(-1)
        self.home_rate.append(0)
        return len(self.alive) - 1

    def _acc(self, v: Vec3, g: Vec3) -> Vec3:
        return g - v * (self.k * length(v))

    def advance_state(self, p: Vec3, v: Vec3, g: Vec3, dt: Real) -> Tuple[Vec3, Vec3]:
        """One step of free flight (no collision)."""
        if self.k <= 0:
            return (p + v * dt + g * (0.5 * dt * dt), v + g * dt)
        if self.drag_kind == DRAG_LINEAR:
            var e = exp(-self.k * dt)
            var vt = g / self.k  # terminal velocity
            return (p + (v - vt) * ((1 - e) / self.k) + vt * dt, (v - vt) * e + vt)
        var k1v = self._acc(v, g)
        var k1x = v
        var k2v = self._acc(v + k1v * (dt / 2), g)
        var k2x = v + k1v * (dt / 2)
        var k3v = self._acc(v + k2v * (dt / 2), g)
        var k3x = v + k2v * (dt / 2)
        var k4v = self._acc(v + k3v * dt, g)
        var k4x = v + k3v * dt
        return (p + (k1x + k2x * 2 + k3x * 2 + k4x) * (dt / 6), v + (k1v + k2v * 2 + k3v * 2 + k4v) * (dt / 6))

    def _home[B: Body6, BP: BroadPhase](mut self, sc: ContactScene6[B, BP], i: Int, dt: Real):
        var hb = self.home_body[i]
        if hb < 0 or hb >= len(sc.bset.bodies) or not sc.bset.is_valid(sc.bset.id_of(hb)):
            return
        var v = self.vel[i]
        var sp = length(v)
        var want = sc.bset.bodies[hb].act(Vec3(0, 0, 0, 0)) - self.pos[i]
        var wl = length(want)
        if not (sp > 0) or not (wl > 0):
            return
        var vd = v / sp
        var wd = want / wl
        var ang = acos(min(max(dot(vd, wd), Real(-1)), Real(1)))
        var turn = self.home_rate[i] * dt
        if ang <= turn:
            self.vel[i] = wd * sp
            return
        var ax = cross(vd, wd)
        var al = length(ax)
        if not (al > 1e-9):
            return
        self.vel[i] = Quat.from_axis_angle(ax / al, turn).rotate(vd) * sp

    def _fuse[B: Body6, BP: BroadPhase](self, sc: ContactScene6[B, BP], p: Vec3, seg: Vec3, l: Real) -> Tuple[Int, Real]:
        """(target body, distance along the step) of the first fuse target
        the step passes within `fuse_radius` of, or (-1, inf)."""
        var best = -1
        var best_t = Real(1e30)
        if not (self.fuse_radius > 0) or not (l > 0):
            return (best, best_t)
        var d = seg / l
        for tb in self.fuse_targets:
            if tb < 0 or tb >= len(sc.bset.bodies):
                continue
            var c = sc.bset.bodies[tb].act(Vec3(0, 0, 0, 0))
            var t = min(max(dot(c - p, d), Real(0)), l)
            if length(p + d * t - c) <= self.fuse_radius and t < best_t:
                best = tb
                best_t = t
        return (best, best_t)

    def _thickness[B: Body6, BP: BroadPhase](self, sc: ContactScene6[B, BP], at: Vec3, d: Vec3, body: Int, probe: Real) -> Real:
        """Thickness of `body` along `d` from the entry `at`, found by a ray
        cast back from `probe` beyond it; > probe when it is thicker."""
        var hits = sc.ray_cast_all(at + d * probe, -d, probe, self.filter)
        var t_exit = Real(-1)
        for h in hits:
            if h.body == body and (t_exit < 0 or h.t < t_exit):
                t_exit = h.t
        if t_exit <= 0:
            return probe * 2
        return probe - t_exit

    def step[B: Body6, BP: BroadPhase](mut self, mut sc: ContactScene6[B, BP], dt: Real, gravity: Vec3, push: Bool = False) raises -> List[ProjectileHit]:
        var hits = List[ProjectileHit]()
        for i in range(len(self.alive)):
            if not self.alive[i]:
                continue
            if self.home_body[i] >= 0:
                self._home(sc, i, dt)
            var nx = self.advance_state(self.pos[i], self.vel[i], gravity, dt)
            var seg = nx[0] - self.pos[i]
            var l = length(seg)
            if l > 0:
                var d = seg / l
                var h = sc.ray_cast(self.pos[i], d, l, self.filter)
                var fz = self._fuse(sc, self.pos[i], seg, l)
                if fz[0] >= 0 and (not h.hit or fz[1] <= h.t):
                    var fp = self.pos[i] + d * fz[1]
                    hits.append(ProjectileHit(i, fz[0], fp, Vec3(0, 0, 0, 0), self.vel[i], HIT_FUSE, self.travelled[i] + fz[1]))
                    self.alive[i] = False
                    continue
                if h.hit:
                    var at = self.pos[i] + d * h.t
                    var v = self.vel[i]
                    var flown = self.travelled[i] + h.t
                    # ricochet: grazing angle to the surface
                    if self.ricochet_deg > 0 and abs(dot(d, h.normal)) < cos((90 - self.ricochet_deg) * 0.017453292519943295):
                        var vr = (v - h.normal * (2 * dot(v, h.normal))) * self.restitution
                        hits.append(ProjectileHit(i, h.body, at, h.normal, v, HIT_RICOCHET, flown))
                        self.pos[i] = at + h.normal * 1e-4
                        self.vel[i] = vr
                        self.travelled[i] = flown
                        continue
                    # penetration
                    if self.pen[i] > 0 and h.body >= 0:
                        var r = self._resist(h.body)
                        var probe = self.pen[i] / r + 1e-3
                        var th = self._thickness(sc, at, d, h.body, probe)
                        if th * r <= self.pen[i]:
                            var left = self.pen[i] - th * r
                            var scale = sqrt(left / self.pen[i])
                            hits.append(ProjectileHit(i, h.body, at, h.normal, v, HIT_PENETRATE, flown))
                            if push and self.mass > 0 and sc.bset.is_dynamic(h.body):
                                sc.apply_impulse(sc.bset.id_of(h.body), v * (self.mass * (1 - scale)), at)
                            self.pen[i] = left
                            self.pos[i] = at + d * (th + 1e-4)
                            self.vel[i] = v * scale
                            self.travelled[i] = flown + th
                            if not (left > 0) or not (scale > 0):
                                self.alive[i] = False
                            continue
                    hits.append(ProjectileHit(i, h.body, at, h.normal, v, HIT_STOP, flown))
                    if push and self.mass > 0 and h.body >= 0 and sc.bset.is_dynamic(h.body):
                        sc.apply_impulse(sc.bset.id_of(h.body), v * self.mass, at)
                    self.alive[i] = False
                    continue
            self.travelled[i] += l
            self.pos[i] = nx[0]
            self.vel[i] = nx[1]
        return hits^
