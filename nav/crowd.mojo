"""Crowd simulation on a navmesh with an avoidance seam (ROADMAP 17.14).

`Crowd[A]` moves agents along `PolyFunnel` paths. Per tick:

1. neighbours -- a uniform grid over the mesh bounds (counting sort into
   cells of `neighbor_dist`, no hashing, no allocation in steady state); each
   agent keeps up to `max_neighbors` nearest within `neighbor_dist`;
2. preferred velocity -- toward the next path corner at `max_speed`, slowing
   inside `slow_radius` of the final target; a corner is skipped as soon as
   the one after it is in straight view (`NavMesh.raycast`), so an agent
   pushed past a corner never turns back to it; an agent whose current
   corner is out of sight (pushed out of its corridor, or the corridor was
   carved) re-plans, at most once per `replan_cooldown` ticks; an agent whose
   target is unreachable waits and retries on the same cooldown;
3. avoidance -- the `Avoidance` variant turns preferred into new velocity;
4. move -- integrate through `NavMesh.move_along` (walks the motion cell by
   cell and slides along blocked cell edges), so an agent never leaves the
   walkable spans; y follows `NavMesh.height_at`.

Avoidance variants (seam `Avoidance`, all in the XZ plane):

- `Orca`: optimal reciprocal collision avoidance (van den Berg, Guy, Lin,
  Manocha 2011), the RVO2 library's half-plane construction and incremental
  2D linear programs (`_lp1` / `_lp2` / `_lp3`) ported line for line.
  Collision-free for agents that all run ORCA, up to the time step.
- `SampledRvo`: reciprocal velocity obstacles by sampling (van den Berg, Lin,
  Manocha 2008): candidates on rings up to `max_speed`, cost =
  |v - v_pref| + w / time-to-collision against the reciprocal VO.
- `SocialForce`: Helbing-style exponential repulsion added to a relaxation
  toward the preferred velocity. Cheapest; no collision-free guarantee.

Overlapping agents (distance 0) are separated along a direction derived from
their indices, so coincident spawns split deterministically instead of
producing NaN.
"""

from std.math import sqrt, floor, exp, pi
from geometry.trig import cos, sin
from geometry.vec import Real, Vec2, Vec3, dot
from nav.navmesh import NavMesh, dist3
from nav.path import NavPath, PolyFunnel, PATH_OFFMESH

comptime _EPS: Real = 1e-5
comptime WEIGHT_RVO: Real = 6.0


def _det(a: Vec2, b: Vec2) -> Real:
    return a[0] * b[1] - a[1] * b[0]


def _dot2(a: Vec2, b: Vec2) -> Real:
    return a[0] * b[0] + a[1] * b[1]


def _len2(a: Vec2) -> Real:
    return sqrt(_dot2(a, a))


def _xz(v: Vec3) -> Vec2:
    return Vec2(v[0], v[2])


def _separation_dir(i: Int, j: Int) -> Vec2:
    """Deterministic unit direction from agent j to agent i when they coincide."""
    var a = Real(((i * 7919 + j * 104729) % 360)) * Real(pi) / 180
    var d = Vec2(cos(a), sin(a))
    return d if i < j else -d


@fieldwise_init
struct CrowdParams(Copyable, ImplicitlyCopyable, Movable):
    var neighbor_dist: Real  # neighbour search radius (m)
    var max_neighbors: Int
    var time_horizon: Real  # ORCA / RVO look-ahead (s)
    var slow_radius: Real  # arrive: slow down within this distance of the target
    var arrive_radius: Real  # target reached within this distance
    var right_bias: Real  # sideways lean of the preferred velocity (fraction)
    var replan_cooldown: Int  # ticks between re-plans of one agent

    @staticmethod
    def default() -> CrowdParams:
        return CrowdParams(4.0, 10, 2.0, 1.0, 0.2, 0.05, 15)


trait Avoidance(Movable, Deinitable):
    def velocity(
        mut self,
        i: Int,
        pos: List[Vec2],
        vel: List[Vec2],
        radius: List[Real],
        neigh: List[Int],
        pref: Vec2,
        max_speed: Real,
        params: CrowdParams,
        dt: Real,
    ) -> Vec2:
        """New velocity for agent i given its neighbours (indices into the
        SoA lists) and preferred velocity."""
        ...


@fieldwise_init
struct Line(Copyable, ImplicitlyCopyable, Movable):
    var point: Vec2
    var direction: Vec2


def _lp1(lines: List[Line], no: Int, radius: Real, opt: Vec2, dir_opt: Bool, mut result: Vec2) -> Bool:
    var dp = _dot2(lines[no].point, lines[no].direction)
    var disc = dp * dp + radius * radius - _dot2(lines[no].point, lines[no].point)
    if disc < 0:
        return False
    var sd = sqrt(disc)
    var t_left = -dp - sd
    var t_right = -dp + sd
    for i in range(no):
        var den = _det(lines[no].direction, lines[i].direction)
        var num = _det(lines[i].direction, lines[no].point - lines[i].point)
        if abs(den) <= _EPS:
            if num < 0:
                return False
            continue
        var t = num / den
        if den >= 0:
            t_right = min(t_right, t)
        else:
            t_left = max(t_left, t)
        if t_left > t_right:
            return False
    if dir_opt:
        if _dot2(opt, lines[no].direction) > 0:
            result = lines[no].point + lines[no].direction * t_right
        else:
            result = lines[no].point + lines[no].direction * t_left
    else:
        var t = _dot2(lines[no].direction, opt - lines[no].point)
        if t < t_left:
            result = lines[no].point + lines[no].direction * t_left
        elif t > t_right:
            result = lines[no].point + lines[no].direction * t_right
        else:
            result = lines[no].point + lines[no].direction * t
    return True


def _lp2(lines: List[Line], radius: Real, opt: Vec2, dir_opt: Bool, mut result: Vec2) -> Int:
    if dir_opt:
        result = opt * radius
    elif _dot2(opt, opt) > radius * radius:
        result = opt * (radius / _len2(opt))
    else:
        result = opt
    for i in range(len(lines)):
        if _det(lines[i].direction, lines[i].point - result) > 0:
            var tmp = result
            if not _lp1(lines, i, radius, opt, dir_opt, result):
                result = tmp
                return i
    return len(lines)


def _lp3(lines: List[Line], begin: Int, radius: Real, mut result: Vec2):
    var distance = Real(0)
    for i in range(begin, len(lines)):
        if _det(lines[i].direction, lines[i].point - result) > distance:
            var proj = List[Line]()
            for j in range(i):
                var pt: Vec2
                var d = _det(lines[i].direction, lines[j].direction)
                if abs(d) <= _EPS:
                    if _dot2(lines[i].direction, lines[j].direction) > 0:
                        continue
                    pt = (lines[i].point + lines[j].point) * 0.5
                else:
                    pt = lines[i].point + lines[i].direction * (
                        _det(lines[j].direction, lines[i].point - lines[j].point) / d
                    )
                var dd = lines[j].direction - lines[i].direction
                var l = _len2(dd)
                if l <= _EPS:
                    continue
                proj.append(Line(pt, dd / l))
            var tmp = result
            if _lp2(proj, radius, Vec2(-lines[i].direction[1], lines[i].direction[0]), True, result) < len(proj):
                result = tmp
            distance = _det(lines[i].direction, lines[i].point - result)


struct Orca(Avoidance):
    var lines: List[Line]

    def __init__(out self):
        self.lines = List[Line]()

    def velocity(
        mut self,
        i: Int,
        pos: List[Vec2],
        vel: List[Vec2],
        radius: List[Real],
        neigh: List[Int],
        pref: Vec2,
        max_speed: Real,
        params: CrowdParams,
        dt: Real,
    ) -> Vec2:
        self.lines.clear()
        var inv_th = 1 / params.time_horizon
        for k in range(len(neigh)):
            var j = neigh[k]
            var rel_pos = pos[j] - pos[i]
            var rel_vel = vel[i] - vel[j]
            var dist_sq = _dot2(rel_pos, rel_pos)
            var cr = radius[i] + radius[j]
            var cr_sq = cr * cr
            var direction: Vec2
            var u: Vec2
            if dist_sq > cr_sq:
                var w = rel_vel - rel_pos * inv_th
                var w_sq = _dot2(w, w)
                var dp1 = _dot2(w, rel_pos)
                if dp1 < 0 and dp1 * dp1 > cr_sq * w_sq:
                    var wl = sqrt(w_sq)
                    var uw = w / wl
                    direction = Vec2(uw[1], -uw[0])
                    u = uw * (cr * inv_th - wl)
                else:
                    var leg = sqrt(dist_sq - cr_sq)
                    if _det(rel_pos, w) > 0:
                        direction = Vec2(
                            rel_pos[0] * leg - rel_pos[1] * cr, rel_pos[0] * cr + rel_pos[1] * leg
                        ) / dist_sq
                    else:
                        direction = -Vec2(
                            rel_pos[0] * leg + rel_pos[1] * cr, -rel_pos[0] * cr + rel_pos[1] * leg
                        ) / dist_sq
                    var dp2 = _dot2(rel_vel, direction)
                    u = direction * dp2 - rel_vel
            else:
                # already overlapping: resolve within one step
                var inv_dt = 1 / dt
                var w = rel_vel - rel_pos * inv_dt
                var wl = _len2(w)
                var uw: Vec2
                if wl <= _EPS:
                    uw = _separation_dir(i, j)
                    wl = 0
                else:
                    uw = w / wl
                direction = Vec2(uw[1], -uw[0])
                u = uw * (cr * inv_dt - wl)
            self.lines.append(Line(vel[i] + u * 0.5, direction))
        var result = Vec2(0)
        var fail = _lp2(self.lines, max_speed, pref, False, result)
        if fail < len(self.lines):
            _lp3(self.lines, fail, max_speed, result)
        return result


struct SampledRvo(Avoidance):
    """Sampling-based reciprocal velocity obstacles. Candidates: v_pref and
    `rings` x `dirs` velocities on circles up to max_speed. Zero velocity is
    deliberately not a candidate: with it, stopping undercuts every detour
    and two groups meeting head-on freeze (measured: corridor and door
    scenarios deadlock)."""

    var rings: Int
    var dirs: Int
    var weight: Real  # time-to-collision penalty weight (m)

    def __init__(out self, rings: Int = 4, dirs: Int = 24, weight: Real = WEIGHT_RVO):
        self.rings = rings
        self.dirs = dirs
        self.weight = weight

    def _ttc(self, i: Int, cand: Vec2, pos: List[Vec2], vel: List[Vec2], radius: List[Real], neigh: List[Int]) -> Real:
        """Earliest time agent i moving at `cand` hits a neighbour's reciprocal
        velocity obstacle (relative velocity 2 cand - v_i - v_j)."""
        var best = Real(1e30)
        for k in range(len(neigh)):
            var j = neigh[k]
            var rp = pos[j] - pos[i]
            var rv = cand * 2 - vel[i] - vel[j]
            var cr = radius[i] + radius[j]
            var c = _dot2(rp, rp) - cr * cr
            if c < 0:
                return 0  # overlapping now
            var a = _dot2(rv, rv)
            var b = _dot2(rp, rv)
            if b <= 0 or a <= _EPS:
                continue
            var disc = b * b - a * c
            if disc < 0:
                continue
            var t = (b - sqrt(disc)) / a
            if t >= 0 and t < best:
                best = t
        return best

    def velocity(
        mut self,
        i: Int,
        pos: List[Vec2],
        vel: List[Vec2],
        radius: List[Real],
        neigh: List[Int],
        pref: Vec2,
        max_speed: Real,
        params: CrowdParams,
        dt: Real,
    ) -> Vec2:
        var best = pref
        var best_cost = Real(1e30)
        var n = 1 + self.rings * self.dirs
        for c in range(n):
            var cand: Vec2
            if c == 0:
                cand = pref
            else:
                var ring = (c - 1) // self.dirs + 1
                var k = (c - 1) % self.dirs
                var a = Real(2) * Real(pi) * Real(k) / Real(self.dirs)
                var sp = max_speed * Real(ring) / Real(self.rings)
                cand = Vec2(cos(a), sin(a)) * sp
            var t = self._ttc(i, cand, pos, vel, radius, neigh)
            var pen = Real(0)
            if t <= 0:
                # overlapping: prefer velocities that move apart
                pen = Real(1e3)
                for k in range(len(neigh)):
                    var j = neigh[k]
                    var rp = pos[i] - pos[j]
                    var l = _len2(rp)
                    var away = rp / l if l > _EPS else _separation_dir(i, j)
                    pen -= _dot2(cand, away) * Real(10)
            elif t < params.time_horizon:
                pen = self.weight / t
            var dv = cand - pref
            var cost = _len2(dv) + pen
            if cost < best_cost:
                best_cost = cost
                best = cand
        return best


struct SocialForce(Avoidance):
    """Update: v' = v + dt * ((v_pref - v) / tau + sum_j A exp((r_ij - d_ij) / B) n_ij)."""

    var tau: Real
    var a: Real
    var b: Real

    def __init__(out self, tau: Real = 0.5, a: Real = 8.0, b: Real = 0.3):
        self.tau = tau
        self.a = a
        self.b = b

    def velocity(
        mut self,
        i: Int,
        pos: List[Vec2],
        vel: List[Vec2],
        radius: List[Real],
        neigh: List[Int],
        pref: Vec2,
        max_speed: Real,
        params: CrowdParams,
        dt: Real,
    ) -> Vec2:
        var f = (pref - vel[i]) / self.tau
        for k in range(len(neigh)):
            var j = neigh[k]
            var d = pos[i] - pos[j]
            var l = _len2(d)
            var n = d / l if l > _EPS else _separation_dir(i, j)
            f += n * (self.a * exp((radius[i] + radius[j] - l) / self.b))
        var v = vel[i] + f * dt
        var sp = _len2(v)
        if sp > max_speed:
            v = v * (max_speed / sp)
        return v


struct Crowd[A: Avoidance](Movable, Sized):
    var params: CrowdParams
    var avoid: Self.A
    var pos: List[Vec3]
    var vel: List[Vec2]
    var radius: List[Real]
    var max_speed: List[Real]
    var target: List[Vec3]
    var has_target: List[Bool]
    var arrived: List[Bool]
    var path: List[List[Vec3]]
    var path_flags: List[List[Int]]
    var corner: List[Int]
    var replan_wait: List[Int]
    var finder: PolyFunnel
    # scratch
    var _p2: List[Vec2]
    var _new_vel: List[Vec2]
    var _cell_start: List[Int]
    var _cell_items: List[Int]
    var _neigh: List[Int]
    var _nd: List[Real]
    var blocked_moves: Int  # moves shortened by the mesh constraint (diagnostic)
    var replans: Int  # paths re-planned because the next corner went out of sight

    def __init__(out self, var avoid: Self.A, params: CrowdParams):
        self.params = params
        self.avoid = avoid^
        self.pos = List[Vec3]()
        self.vel = List[Vec2]()
        self.radius = List[Real]()
        self.max_speed = List[Real]()
        self.target = List[Vec3]()
        self.has_target = List[Bool]()
        self.arrived = List[Bool]()
        self.path = List[List[Vec3]]()
        self.path_flags = List[List[Int]]()
        self.corner = List[Int]()
        self.replan_wait = List[Int]()
        self.finder = PolyFunnel()
        self._p2 = List[Vec2]()
        self._new_vel = List[Vec2]()
        self._cell_start = List[Int]()
        self._cell_items = List[Int]()
        self._neigh = List[Int]()
        self._nd = List[Real]()
        self.blocked_moves = 0
        self.replans = 0

    def __len__(self) -> Int:
        return len(self.pos)

    def add_agent(mut self, mesh: NavMesh, p: Vec3, radius: Real, max_speed: Real) raises -> Int:
        if radius <= 0 or max_speed <= 0:
            raise Error("Crowd.add_agent: radius and max_speed must be > 0")
        if mesh.find_span(p) < 0:
            raise Error("Crowd.add_agent: position is not on the navmesh")
        self.pos.append(mesh.snap(p, 0))
        self.vel.append(Vec2(0))
        self.radius.append(radius)
        self.max_speed.append(max_speed)
        self.target.append(p)
        self.has_target.append(False)
        self.arrived.append(True)
        self.path.append(List[Vec3]())
        self.path_flags.append(List[Int]())
        self.corner.append(0)
        self.replan_wait.append(0)
        return len(self.pos) - 1

    def set_target(mut self, mesh: NavMesh, i: Int, t: Vec3) -> Bool:
        """Plan a path to t. When t is unreachable the agent stays put and
        counts as not arrived (waiting) until a later `set_target` succeeds."""
        var p = self.finder.find(mesh, self.pos[i], t)
        self.target[i] = t
        if not p.found:
            self.has_target[i] = False
            self.arrived[i] = False
            self.path[i] = List[Vec3]()
            self.path_flags[i] = List[Int]()
            return False
        self.has_target[i] = True
        self.arrived[i] = False
        self.path[i] = p.points.copy()
        self.path_flags[i] = p.flags.copy()
        self.corner[i] = 1 if len(p.points) > 1 else 0
        return True

    def _build_grid(mut self, mesh: NavMesh):
        var cs = self.params.neighbor_dist
        var w = mesh.field.width
        var gx = max(1, Int(Real(w) * mesh.field.cs / cs) + 1)
        var gz = max(1, Int(Real(mesh.field.depth) * mesh.field.cs / cs) + 1)
        var n = len(self.pos)
        self._cell_start = List[Int](length=gx * gz + 1, fill=0)
        self._cell_items = List[Int](length=n, fill=0)
        for i in range(n):
            self._cell_start[self._cell(mesh, i, gx, gz) + 1] += 1
        for c in range(gx * gz):
            self._cell_start[c + 1] += self._cell_start[c]
        var fill = self._cell_start.copy()
        for i in range(n):
            var c = self._cell(mesh, i, gx, gz)
            self._cell_items[fill[c]] = i
            fill[c] += 1

    def _cell(self, mesh: NavMesh, i: Int, gx: Int, gz: Int) -> Int:
        var cs = self.params.neighbor_dist
        var x = min(max(Int(floor((self.pos[i][0] - mesh.field.bmin[0]) / cs)), 0), gx - 1)
        var z = min(max(Int(floor((self.pos[i][2] - mesh.field.bmin[2]) / cs)), 0), gz - 1)
        return x + z * gx

    def _neighbours(mut self, mesh: NavMesh, i: Int):
        """Up to max_neighbors nearest agents within neighbor_dist, nearest
        first (insertion into a short sorted list)."""
        self._neigh.clear()
        self._nd.clear()
        var cs = self.params.neighbor_dist
        var gx = max(1, Int(Real(mesh.field.width) * mesh.field.cs / cs) + 1)
        var gz = max(1, Int(Real(mesh.field.depth) * mesh.field.cs / cs) + 1)
        var c = self._cell(mesh, i, gx, gz)
        var cx = c % gx
        var cz = c // gx
        var r2 = cs * cs
        for z in range(max(cz - 1, 0), min(cz + 1, gz - 1) + 1):
            for x in range(max(cx - 1, 0), min(cx + 1, gx - 1) + 1):
                var cell = x + z * gx
                for k in range(self._cell_start[cell], self._cell_start[cell + 1]):
                    var j = self._cell_items[k]
                    if j == i:
                        continue
                    var d = self._p2[j] - self._p2[i]
                    var d2 = _dot2(d, d)
                    if d2 > r2:
                        continue
                    # sorted insert, keep max_neighbors
                    var at = len(self._nd)
                    while at > 0 and (self._nd[at - 1] > d2 or (self._nd[at - 1] == d2 and self._neigh[at - 1] > j)):
                        at -= 1
                    if at >= self.params.max_neighbors:
                        continue
                    self._nd.insert(at, d2)
                    self._neigh.insert(at, j)
                    if len(self._nd) > self.params.max_neighbors:
                        _ = self._nd.pop()
                        _ = self._neigh.pop()

    def _pref(self, i: Int) -> Vec2:
        if not self.has_target[i] or self.arrived[i]:
            return Vec2(0)
        var c = self.path[i][self.corner[i]]
        var d = _xz(c) - _xz(self.pos[i])
        var l = _len2(d)
        if l <= _EPS:
            return Vec2(0)
        var sp = self.max_speed[i]
        var last = self.corner[i] == len(self.path[i]) - 1
        if last and l < self.params.slow_radius:
            sp *= l / self.params.slow_radius
        # Right-hand rule: every agent leans `right_bias` to its right. It
        # breaks perfectly symmetric standoffs (RVO2's examples perturb v_pref
        # for the same reason) and, being the same for everyone, turns a
        # head-on jam into a vortex that drains; deterministic.
        var dir = d / l
        var side = Vec2(dir[1], -dir[0]) * self.params.right_bias
        return (dir + side) * sp

    def step(mut self, mesh: NavMesh, dt: Real):
        var n = len(self.pos)
        self._p2 = List[Vec2](capacity=n)
        for i in range(n):
            self._p2.append(_xz(self.pos[i]))
        self._build_grid(mesh)
        self._new_vel = List[Vec2](length=n, fill=Vec2(0))
        for i in range(n):
            self._neighbours(mesh, i)
            var pref = self._pref(i)
            self._new_vel[i] = self.avoid.velocity(
                i, self._p2, self.vel, self.radius, self._neigh, pref, self.max_speed[i], self.params, dt
            )
        for i in range(n):
            var v = self._new_vel[i]
            var p0 = self.pos[i]
            var offmesh = (
                self.has_target[i]
                and not self.arrived[i]
                and self.corner[i] > 0
                and self.path_flags[i][self.corner[i] - 1] == PATH_OFFMESH
            )
            if offmesh:
                # traversing an off-mesh link: straight at the landing, no avoidance
                var d = _xz(self.path[i][self.corner[i]]) - _xz(p0)
                var l = _len2(d)
                var stp = min(l, self.max_speed[i] * dt)
                v = d * (stp / dt / l) if l > _EPS else Vec2(0)
                var t = self.path[i][self.corner[i]]
                var frac = stp / l if l > _EPS else Real(1)
                self.pos[i] = t if frac >= 1 else p0 + (t - p0) * frac
                self.vel[i] = v
            else:
                var want = p0 + Vec3(v[0], 0, v[1], 0) * dt
                var p1 = mesh.move_along(p0, want)
                var dx = p1[0] - want[0]
                var dz = p1[2] - want[2]
                if dx * dx + dz * dz > Real(1e-8):
                    self.blocked_moves += 1
                    v = Vec2(p1[0] - p0[0], p1[2] - p0[2]) / dt
                self.pos[i] = p1
                self.vel[i] = v
            # corner advance
            if self.has_target[i] and not self.arrived[i]:
                var last_i = len(self.path[i]) - 1
                if offmesh:
                    # a traversal ends only at its landing point
                    if _len2(_xz(self.path[i][self.corner[i]]) - _xz(self.pos[i])) <= Real(1e-4):
                        self.corner[i] = min(self.corner[i] + 1, last_i)
                else:
                    # skip corners once the following one is in straight view
                    # (an agent pushed past a corner must not walk back to it);
                    # never skip an off-mesh take-off point
                    while (
                        self.corner[i] < last_i
                        and self.path_flags[i][self.corner[i]] != PATH_OFFMESH
                        and mesh.raycast(self.pos[i], self.path[i][self.corner[i] + 1])
                    ):
                        self.corner[i] += 1
                    var c = self.corner[i]
                    var d = _len2(_xz(self.path[i][c]) - _xz(self.pos[i]))
                    if c == last_i and d <= self.params.arrive_radius:
                        self.arrived[i] = True
                    elif self.path_flags[i][c] == PATH_OFFMESH and d <= self.params.arrive_radius:
                        self.corner[i] = c + 1  # start the traversal
                    elif self.replan_wait[i] > 0:
                        self.replan_wait[i] -= 1
                    elif not mesh.raycast(self.pos[i], self.path[i][c]):
                        # pushed off the corridor, or the corridor was carved
                        self.replans += 1
                        self.replan_wait[i] = self.params.replan_cooldown
                        _ = self.set_target(mesh, i, self.target[i])
            elif not self.arrived[i]:
                # waiting: the target was unreachable; retry on the cooldown
                if self.replan_wait[i] > 0:
                    self.replan_wait[i] -= 1
                else:
                    self.replans += 1
                    self.replan_wait[i] = self.params.replan_cooldown
                    _ = self.set_target(mesh, i, self.target[i])

    def all_arrived(self) -> Bool:
        """Every agent is at its target (agents never given one count as
        arrived; agents whose target was unreachable do not)."""
        for i in range(len(self.pos)):
            if not self.arrived[i]:
                return False
        return True

    def min_separation(self) -> Real:
        """Smallest (distance - r_i - r_j) over all pairs; negative = overlap.
        O(n^2): for tests and benchmarks, not the step."""
        var best = Real(1e30)
        for i in range(len(self.pos)):
            for j in range(i + 1, len(self.pos)):
                var d = _len2(_xz(self.pos[i]) - _xz(self.pos[j])) - self.radius[i] - self.radius[j]
                best = min(best, d)
        return best
