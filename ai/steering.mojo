"""Steering behaviours, flocking and formations (ROADMAP 17.15).

Reynolds steering as pure functions returning a desired velocity change
(acceleration-like "steering force", clamped by the caller):
`seek`, `flee`, `arrive` (slows inside a radius), `pursue` / `evade`
(predict the quarry's position by distance / speed), `wander` (a point on a
circle ahead, jittered by a deterministic RNG state), `follow_path` (seek a
point a look-ahead distance further along a polyline).

`Flock`: boids (separation, cohesion, alignment) over a uniform grid of
cells the size of the neighbour radius (counting sort, no hashing); `step`
integrates with a speed cap and a minimum speed -- without the floor, a
dense flock stalls and its headings jitter instead of aligning (measured in
`test_ai_steering`'s development: local alignment stayed near 0.5).
Deterministic.

`Formation`: slot offsets in the leader's frame (`FORMATION_LINE`,
`FORMATION_COLUMN`, `FORMATION_WEDGE`); `slot_world(leader_pos, leader_fwd,
i)` gives slot i in the world; followers `arrive` at their slots.
"""

from std.math import sqrt, floor
from geometry.trig import cos, sin
from geometry.vec import Real, Vec3, dot

comptime FORMATION_LINE = 0
comptime FORMATION_COLUMN = 1
comptime FORMATION_WEDGE = 2


def _len(v: Vec3) -> Real:
    return sqrt(dot(v, v))


def _clamp_len(v: Vec3, m: Real) -> Vec3:
    var l = _len(v)
    if l > m and l > 0:
        return v * (m / l)
    return v


def seek(pos: Vec3, vel: Vec3, target: Vec3, max_speed: Real) -> Vec3:
    var d = target - pos
    var l = _len(d)
    if l <= 0:
        return -vel
    return d * (max_speed / l) - vel


def flee(pos: Vec3, vel: Vec3, threat: Vec3, max_speed: Real) -> Vec3:
    var d = pos - threat
    var l = _len(d)
    if l <= 0:
        return Vec3(max_speed, 0, 0, 0) - vel
    return d * (max_speed / l) - vel


def arrive(pos: Vec3, vel: Vec3, target: Vec3, max_speed: Real, slow_radius: Real) -> Vec3:
    var d = target - pos
    var l = _len(d)
    if l <= 1e-6:
        return -vel
    var sp = max_speed if l >= slow_radius else max_speed * l / slow_radius
    return d * (sp / l) - vel


def pursue(pos: Vec3, vel: Vec3, quarry: Vec3, quarry_vel: Vec3, max_speed: Real) -> Vec3:
    var t = _len(quarry - pos) / max(max_speed, Real(1e-6))
    return seek(pos, vel, quarry + quarry_vel * t, max_speed)


def evade(pos: Vec3, vel: Vec3, threat: Vec3, threat_vel: Vec3, max_speed: Real) -> Vec3:
    var t = _len(threat - pos) / max(max_speed, Real(1e-6))
    return flee(pos, vel, threat + threat_vel * t, max_speed)


def _rand(mut state: UInt64) -> Real:
    """SplitMix64 step -> [0, 1)."""
    state += 0x9E3779B97F4A7C15
    var z = state
    z = (z ^ (z >> 30)) * 0xBF58476D1CE4E5B9
    z = (z ^ (z >> 27)) * 0x94D049BB133111EB
    z = z ^ (z >> 31)
    return Real(Float64(z >> 11) * (1.0 / 9007199254740992.0))


def wander(
    pos: Vec3, vel: Vec3, mut angle: Real, mut rng: UInt64, max_speed: Real, dist: Real, radius: Real, jitter: Real
) -> Vec3:
    """Seek a point on a circle `dist` ahead; the point's angle drifts by up
    to +-jitter per call. `angle` and `rng` are the per-agent wander state."""
    angle += (_rand(rng) * 2 - 1) * jitter
    var l = _len(vel)
    var fwd = vel / l if l > 1e-6 else Vec3(1, 0, 0, 0)
    var right = Vec3(fwd[2], 0, -fwd[0], 0)
    var target = pos + fwd * dist + (fwd * cos(angle) + right * sin(angle)) * radius
    return seek(pos, vel, target, max_speed)


def follow_path(pos: Vec3, vel: Vec3, path: List[Vec3], look_ahead: Real, max_speed: Real) -> Vec3:
    """Seek the point `look_ahead` further along the path than the point of
    the path nearest to pos (arrive at the end)."""
    if len(path) == 0:
        return -vel
    if len(path) == 1:
        return arrive(pos, vel, path[0], max_speed, look_ahead)
    # nearest point on the polyline, as arc length
    var best_d = Real(1e30)
    var best_s = Real(0)
    var acc = Real(0)
    for i in range(len(path) - 1):
        var a = path[i]
        var b = path[i + 1]
        var ab = b - a
        var l2 = dot(ab, ab)
        var t = min(max(dot(pos - a, ab) / l2, 0), 1) if l2 > 0 else Real(0)
        var q = a + ab * t
        var d = _len(pos - q)
        var seg = sqrt(l2)
        if d < best_d:
            best_d = d
            best_s = acc + seg * t
        acc += seg
    var s = best_s + look_ahead
    if s >= acc:
        return arrive(pos, vel, path[len(path) - 1], max_speed, look_ahead)
    acc = 0
    for i in range(len(path) - 1):
        var seg = _len(path[i + 1] - path[i])
        if acc + seg >= s:
            var t = (s - acc) / seg if seg > 0 else Real(0)
            return seek(pos, vel, path[i] + (path[i + 1] - path[i]) * t, max_speed)
        acc += seg
    return arrive(pos, vel, path[len(path) - 1], max_speed, look_ahead)


@fieldwise_init
struct FlockParams(Copyable, ImplicitlyCopyable, Movable):
    var radius: Real  # neighbour radius
    var separation: Real
    var cohesion: Real
    var alignment: Real
    var max_speed: Real
    var max_force: Real
    var sep_radius: Real  # separation acts inside this distance
    var min_speed: Real  # boids keep at least this speed (Reynolds' boids fly at near-constant speed)


struct Flock(Movable, Sized):
    var p: FlockParams
    var pos: List[Vec3]
    var vel: List[Vec3]
    var goal_force: List[Vec3]  # extra steering per boid (seek a goal, ...)
    var _cell_start: List[Int]
    var _items: List[Int]
    var _lo: Vec3
    var _gx: Int
    var _gz: Int
    var neighbour_checks: Int

    def __init__(out self, p: FlockParams):
        self.p = p
        self.pos = List[Vec3]()
        self.vel = List[Vec3]()
        self.goal_force = List[Vec3]()
        self._cell_start = List[Int]()
        self._items = List[Int]()
        self._lo = Vec3(0)
        self._gx = 1
        self._gz = 1
        self.neighbour_checks = 0

    def __len__(self) -> Int:
        return len(self.pos)

    def add(mut self, p: Vec3, v: Vec3) -> Int:
        self.pos.append(p)
        self.vel.append(v)
        self.goal_force.append(Vec3(0))
        return len(self.pos) - 1

    def _cell(self, p: Vec3) -> Int:
        var r = self.p.radius
        var x = min(max(Int(floor((p[0] - self._lo[0]) / r)), 0), self._gx - 1)
        var z = min(max(Int(floor((p[2] - self._lo[2]) / r)), 0), self._gz - 1)
        return x + z * self._gx

    def _grid(mut self):
        var n = len(self.pos)
        if n == 0:
            return
        var lo = self.pos[0]
        var hi = self.pos[0]
        for q in self.pos:
            for a in range(3):
                lo[a] = min(lo[a], q[a])
                hi[a] = max(hi[a], q[a])
        self._lo = lo
        self._gx = Int((hi[0] - lo[0]) / self.p.radius) + 1
        self._gz = Int((hi[2] - lo[2]) / self.p.radius) + 1
        var nc = self._gx * self._gz
        self._cell_start = List[Int](length=nc + 1, fill=0)
        self._items = List[Int](length=n, fill=0)
        for i in range(n):
            self._cell_start[self._cell(self.pos[i]) + 1] += 1
        for c in range(nc):
            self._cell_start[c + 1] += self._cell_start[c]
        var fill = self._cell_start.copy()
        for i in range(n):
            var c = self._cell(self.pos[i])
            self._items[fill[c]] = i
            fill[c] += 1

    def step(mut self, dt: Real):
        var n = len(self.pos)
        self._grid()
        var acc = List[Vec3](length=n, fill=Vec3(0))
        var r2 = self.p.radius * self.p.radius
        var s2 = self.p.sep_radius * self.p.sep_radius
        for i in range(n):
            var c = self._cell(self.pos[i])
            var cx = c % self._gx
            var cz = c // self._gx
            var sep = Vec3(0)
            var center = Vec3(0)
            var avg_v = Vec3(0)
            var cnt = 0
            for z in range(max(cz - 1, 0), min(cz + 1, self._gz - 1) + 1):
                for x in range(max(cx - 1, 0), min(cx + 1, self._gx - 1) + 1):
                    var cell = x + z * self._gx
                    for k in range(self._cell_start[cell], self._cell_start[cell + 1]):
                        var j = self._items[k]
                        if j == i:
                            continue
                        self.neighbour_checks += 1
                        var d = self.pos[i] - self.pos[j]
                        var d2 = dot(d, d)
                        if d2 > r2:
                            continue
                        cnt += 1
                        center += self.pos[j]
                        avg_v += self.vel[j]
                        if d2 < s2 and d2 > 0:
                            sep += d / d2
            var f = self.goal_force[i]
            if cnt > 0:
                var inv = Real(1) / Real(cnt)
                f += _clamp_len(sep, self.p.max_force) * self.p.separation
                f += _clamp_len(seek(self.pos[i], self.vel[i], center * inv, self.p.max_speed), self.p.max_force) * self.p.cohesion
                f += _clamp_len(avg_v * inv - self.vel[i], self.p.max_force) * self.p.alignment
            acc[i] = f
        for i in range(n):
            var v = _clamp_len(self.vel[i] + acc[i] * dt, self.p.max_speed)
            var l = _len(v)
            if l < self.p.min_speed:
                v = v * (self.p.min_speed / l) if l > 1e-6 else self.vel[i]
            self.vel[i] = v
            self.pos[i] = self.pos[i] + v * dt

    def min_distance(self) -> Real:
        var best = Real(1e30)
        for i in range(len(self.pos)):
            for j in range(i + 1, len(self.pos)):
                best = min(best, _len(self.pos[i] - self.pos[j]))
        return best


struct Formation(Copyable, Movable):
    var kind: Int
    var spacing: Real

    def __init__(out self, kind: Int, spacing: Real):
        self.kind = kind
        self.spacing = spacing

    def slot_local(self, i: Int) -> Vec3:
        """Offset of slot i (0 = right behind / beside the leader) in the
        leader frame: +x right, -z behind."""
        var s = self.spacing
        if self.kind == FORMATION_LINE:
            var side = Real(1) if i % 2 == 0 else Real(-1)
            return Vec3(side * s * Real(i // 2 + 1), 0, 0, 0)
        if self.kind == FORMATION_COLUMN:
            return Vec3(0, 0, -s * Real(i + 1), 0)
        var side = Real(1) if i % 2 == 0 else Real(-1)
        var row = Real(i // 2 + 1)
        return Vec3(side * s * row, 0, -s * row, 0)

    def slot_world(self, leader_pos: Vec3, leader_fwd: Vec3, i: Int) -> Vec3:
        var f = leader_fwd
        f[1] = 0
        var l = _len(f)
        f = f / l if l > 1e-6 else Vec3(0, 0, 1, 0)
        var right = Vec3(f[2], 0, -f[0], 0)
        var o = self.slot_local(i)
        return leader_pos + right * o[0] + f * o[2]
