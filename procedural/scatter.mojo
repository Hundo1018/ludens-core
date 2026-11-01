"""Point distributions (ROADMAP 17.69).

Three samplers of a w x h rectangle, all pure functions of (params, seed):
the random numbers come from the integer hash `noise._hash`, not from a
stateful RNG (`procedural` is layer 2 and cannot import `scheduler.rng`).

  * `poisson_disk` (Bridson 2007): every pair at least `r` apart; grows from
    a seed point, k candidates per active point in the annulus [r, 2r];
    stops when no point is active. Blue noise.
  * `dart_throwing`: `tries` uniform darts, each kept if it is at least r
    from every kept one. Same guarantee, fewer points per try budget.
  * `jittered_grid`: one point per `cell`, moved by up to `jitter` x cell
    in each axis. No distance guarantee unless jitter < 0.5 (then
    >= (1 - 2 jitter) cell).

`density` (optional, values in [0, 1] sampled at the point) thins any of
them: a point survives if a hashed uniform is below it.
"""

from std.math import sqrt, pi
from geometry.trig import cos, sin
from geometry.vec import Real, Vec2
from .noise import _hash


def _u(seed: Int, a: Int, b: Int) -> Real:
    """Uniform in [0, 1) from (seed, a, b)."""
    return Real(Float64(_hash(a, b, 0x5CA77E, seed)) / 4294967296.0)


def poisson_disk(w: Real, h: Real, r: Real, seed: Int, k: Int = 30) raises -> List[Vec2]:
    if w <= 0 or h <= 0 or r <= 0:
        raise Error("poisson_disk: w, h, r must be > 0")
    var cell = r / sqrt(Real(2))
    var gx = Int(w / cell) + 1
    var gy = Int(h / cell) + 1
    var grid = List[Int](length=gx * gy, fill=-1)
    var pts = List[Vec2]()
    var active = List[Int]()
    var p0 = Vec2(_u(seed, 0, 0) * w, _u(seed, 0, 1) * h)
    pts.append(p0)
    active.append(0)
    grid[Int(p0[1] / cell) * gx + Int(p0[0] / cell)] = 0
    var draw = 1
    var r2 = r * r
    while len(active) > 0:
        var ai = Int(_u(seed, draw, 2) * Real(len(active)))
        ai = min(ai, len(active) - 1)
        var base = pts[active[ai]]
        var found = False
        for c in range(k):
            var ang = _u(seed, draw, 3 + 2 * c) * 2 * Real(pi)
            var rad = r * (1 + _u(seed, draw, 4 + 2 * c))
            var q = Vec2(base[0] + rad * cos(ang), base[1] + rad * sin(ang))
            if q[0] < 0 or q[0] >= w or q[1] < 0 or q[1] >= h:
                continue
            var cx = Int(q[0] / cell)
            var cy = Int(q[1] / cell)
            var ok = True
            for yy in range(max(cy - 2, 0), min(cy + 3, gy)):
                for xx in range(max(cx - 2, 0), min(cx + 3, gx)):
                    var j = grid[yy * gx + xx]
                    if j >= 0:
                        var d = pts[j] - q
                        if d[0] * d[0] + d[1] * d[1] < r2:
                            ok = False
            if ok:
                grid[cy * gx + cx] = len(pts)
                active.append(len(pts))
                pts.append(q)
                found = True
                break
        draw += 1
        if not found:
            active[ai] = active[len(active) - 1]
            _ = active.pop()
    return pts^


def dart_throwing(w: Real, h: Real, r: Real, seed: Int, tries: Int) raises -> List[Vec2]:
    if w <= 0 or h <= 0 or r <= 0:
        raise Error("dart_throwing: w, h, r must be > 0")
    var pts = List[Vec2]()
    var r2 = r * r
    for t in range(tries):
        var q = Vec2(_u(seed, t, 7) * w, _u(seed, t, 8) * h)
        var ok = True
        for p in pts:
            var d = p - q
            if d[0] * d[0] + d[1] * d[1] < r2:
                ok = False
                break
        if ok:
            pts.append(q)
    return pts^


def jittered_grid(w: Real, h: Real, cell: Real, jitter: Real, seed: Int) raises -> List[Vec2]:
    if w <= 0 or h <= 0 or cell <= 0:
        raise Error("jittered_grid: w, h, cell must be > 0")
    var pts = List[Vec2]()
    var nx = Int(w / cell)
    var ny = Int(h / cell)
    for j in range(ny):
        for i in range(nx):
            var jx = (_u(seed, i, 2 * j) * 2 - 1) * jitter
            var jy = (_u(seed, i, 2 * j + 1) * 2 - 1) * jitter
            pts.append(Vec2((Real(i) + 0.5 + jx) * cell, (Real(j) + 0.5 + jy) * cell))
    return pts^


def thin(pts: List[Vec2], density: List[Real], seed: Int) -> List[Vec2]:
    """Keep point i when a hashed uniform is below density[i]."""
    var out = List[Vec2]()
    for i in range(len(pts)):
        if _u(seed, i, 11) < density[i]:
            out.append(pts[i])
    return out^


def min_distance(pts: List[Vec2]) -> Real:
    """Smallest pairwise distance (O(n^2); for tests and tools)."""
    var best = Real.MAX
    for i in range(len(pts)):
        for j in range(i + 1, len(pts)):
            var d = pts[i] - pts[j]
            best = min(best, sqrt(d[0] * d[0] + d[1] * d[1]))
    return best
