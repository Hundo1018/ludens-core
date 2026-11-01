"""Environment queries (EQS-style point scoring) (ROADMAP 17.15).

An `EnvQuery` generates candidate points, runs tests on them, filters and
scores, and returns them best first:

- generators: `grid(center, half_extent, spacing)`, `ring(center, radius,
  count)`, `points(list)`; `project_to_navmesh` keeps only points over the
  navmesh and snaps them to its floor;
- tests (each adds one raw value per point): `distance_to(p)`,
  `facing(from, fwd)` (cosine), `path_length(mesh, from)` (navmesh path, -1 =
  unreachable), `navmesh_visible(mesh, from)` (1 / 0, 2.5D raycast) and
  `external(values)` -- any value the host computed, e.g. 3D line of sight
  from `collision.world_query.ray_cast_batch` over the generated points;
- per test: an optional filter range [min, max] on the raw value, and a
  score weight; scores are the raw values min-max normalised over the
  surviving points (inverted when `prefer_low`), times the weight, summed.

Ties keep generation order, so results are deterministic.
"""

from std.math import sqrt, pi, floor
from geometry.trig import cos, sin
from geometry.vec import Real, Vec3, dot
from nav.navmesh import NavMesh, dist3
from nav.path import PolyFunnel


struct EnvQuery(Movable, Sized):
    var pts: List[Vec3]
    var alive: List[Bool]
    var raw: List[List[Real]]  # per test, per point
    var weight: List[Real]
    var prefer_low: List[Bool]
    var fmin: List[Real]
    var fmax: List[Real]
    var score: List[Real]

    def __init__(out self):
        self.pts = List[Vec3]()
        self.alive = List[Bool]()
        self.raw = List[List[Real]]()
        self.weight = List[Real]()
        self.prefer_low = List[Bool]()
        self.fmin = List[Real]()
        self.fmax = List[Real]()
        self.score = List[Real]()

    def __len__(self) -> Int:
        return len(self.pts)

    # ------------------------------------------------------------ generators

    def grid(mut self, center: Vec3, half_extent: Real, spacing: Real) raises:
        if spacing <= 0:
            raise Error("EnvQuery.grid: spacing must be > 0")
        var n = Int(floor(half_extent / spacing))
        for i in range(-n, n + 1):
            for j in range(-n, n + 1):
                self._add(center + Vec3(Real(i) * spacing, 0, Real(j) * spacing, 0))

    def ring(mut self, center: Vec3, radius: Real, count: Int):
        for k in range(count):
            var a = Real(2) * Real(pi) * Real(k) / Real(max(count, 1))
            self._add(center + Vec3(radius * cos(a), 0, radius * sin(a), 0))

    def points(mut self, ps: List[Vec3]):
        for p in ps:
            self._add(p)

    def _add(mut self, p: Vec3):
        self.pts.append(p)
        self.alive.append(True)

    def project_to_navmesh(mut self, mesh: NavMesh, max_dy: Real = 2.0):
        for i in range(len(self.pts)):
            var p = self.pts[i]
            var s = mesh.field.span_at(p, max_dy)
            if s < 0 or mesh.span_poly[s] < 0:
                self.alive[i] = False
                continue
            self.pts[i] = Vec3(p[0], mesh.height_at(mesh.span_poly[s], p), p[2], 0)

    # ------------------------------------------------------------ tests

    def _test(mut self, var vals: List[Real], weight: Real, prefer_low: Bool, fmin: Real, fmax: Real):
        self.raw.append(vals^)
        self.weight.append(weight)
        self.prefer_low.append(prefer_low)
        self.fmin.append(fmin)
        self.fmax.append(fmax)

    def distance_to(mut self, p: Vec3, weight: Real = 1, prefer_low: Bool = True, fmin: Real = -1e30, fmax: Real = 1e30):
        var v = List[Real]()
        for q in self.pts:
            v.append(dist3(q, p))
        self._test(v^, weight, prefer_low, fmin, fmax)

    def facing(mut self, frm: Vec3, fwd: Vec3, weight: Real = 1, fmin: Real = -1e30, fmax: Real = 1e30):
        var v = List[Real]()
        var fl = sqrt(dot(fwd, fwd))
        for q in self.pts:
            var d = q - frm
            var dl = sqrt(dot(d, d))
            v.append(dot(d, fwd) / (dl * fl) if dl > 0 and fl > 0 else Real(0))
        self._test(v^, weight, False, fmin, fmax)

    def path_length(mut self, mesh: NavMesh, frm: Vec3, weight: Real = 1, max_len: Real = 1e30):
        """Navmesh path length from `frm`; unreachable points are filtered out."""
        var pf = PolyFunnel()
        var v = List[Real]()
        for i in range(len(self.pts)):
            if not self.alive[i]:
                v.append(-1)
                continue
            var p = pf.find(mesh, frm, self.pts[i])
            v.append(p.length() if p.found else Real(-1))
        self._test(v^, weight, True, 0, max_len)

    def navmesh_visible(mut self, mesh: NavMesh, frm: Vec3, weight: Real = 1, require: Int = -1):
        """1 if the 2.5D navmesh raycast from `frm` reaches the point. `require`
        = 1 keeps only visible points, 0 only hidden ones, -1 scores only."""
        var v = List[Real]()
        for q in self.pts:
            v.append(Real(1) if mesh.raycast(frm, q) else Real(0))
        var lo = Real(-1e30)
        var hi = Real(1e30)
        if require == 1:
            lo = 0.5
        elif require == 0:
            hi = 0.5
        self._test(v^, weight, False, lo, hi)

    def external(mut self, var values: List[Real], weight: Real = 1, prefer_low: Bool = False, fmin: Real = -1e30, fmax: Real = 1e30) raises:
        if len(values) != len(self.pts):
            raise Error("EnvQuery.external: one value per generated point")
        self._test(values^, weight, prefer_low, fmin, fmax)

    # ------------------------------------------------------------ result

    def run(mut self) -> List[Int]:
        """Filter, score, and return surviving point indices, best first."""
        var n = len(self.pts)
        for t in range(len(self.raw)):
            for i in range(n):
                var x = self.raw[t][i]
                if x < self.fmin[t] or x > self.fmax[t]:
                    self.alive[i] = False
        self.score = List[Real](length=n, fill=0)
        for t in range(len(self.raw)):
            var lo = Real(1e30)
            var hi = Real(-1e30)
            for i in range(n):
                if self.alive[i]:
                    lo = min(lo, self.raw[t][i])
                    hi = max(hi, self.raw[t][i])
            var span = hi - lo
            for i in range(n):
                if not self.alive[i]:
                    continue
                var x = (self.raw[t][i] - lo) / span if span > 0 else Real(1)
                if self.prefer_low[t] and span > 0:
                    x = 1 - x
                self.score[i] += x * self.weight[t]
        var order = List[Int]()
        for i in range(n):
            if self.alive[i]:
                order.append(i)
        # stable insertion sort by descending score
        for a in range(1, len(order)):
            var v = order[a]
            var b = a
            while b > 0 and self.score[order[b - 1]] < self.score[v]:
                order[b] = order[b - 1]
                b -= 1
            order[b] = v
        return order^
