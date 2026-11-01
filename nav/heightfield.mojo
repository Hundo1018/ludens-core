"""Voxel heightfield and compact walkable field for navmesh baking (ROADMAP 17.14).

The bake follows the first half of the Recast pipeline:

1. `rasterize` -- every input triangle is clipped against the XZ cell grid; the
   clipped piece's y-extent becomes a solid span in that column (Recast
   `rasterizeTri`). Overlapping spans in a column merge; a triangle whose
   normal `cross(b - a, c - a)` points up within `max_slope_deg` marks its span
   walkable.
2. Filters -- `filter_low_hanging` (a non-walkable span whose top is within
   `max_climb` of a walkable span below it becomes walkable: stair risers,
   kerbs) and `filter_low_height` (a walkable span with less than
   `agent_height` of open space above it is not).
3. `CompactField` -- one open span per walkable floor (floor y, clearance),
   4-neighbour connections where the floor step is within `max_climb` and the
   shared opening is at least `agent_height`.
4. `erode` -- two-pass chamfer distance (2 per straight, 3 per diagonal step)
   from the walkable boundary; spans closer than `agent_radius` drop out, so the
   centre of an agent anywhere on the result keeps `agent_radius` of clearance.

Dynamic obstacles (`NavMesh.add_obstacle`) set `blocked` on spans; `erode`
treats a blocked span as a boundary, so carving needs no re-rasterisation.

Integer units: span heights are in `cell_height` steps above `bmin.y`, columns
are `x + z * width`.
"""

from std.math import sqrt, floor, ceil, pi
from geometry.trig import cos
from geometry.vec import Real, Vec3, cross, dot

comptime DIR_DX = SIMD[DType.int32, 4](1, 0, -1, 0)
"""Direction encoding shared by the nav package: 0 = +x, 1 = +z, 2 = -x, 3 = -z."""
comptime DIR_DZ = SIMD[DType.int32, 4](0, 1, 0, -1)
comptime _SPAN_TOP = 1 << 24  # "no span above": open to the sky


def dir_dx(d: Int) -> Int:
    return Int(DIR_DX[d])


def dir_dz(d: Int) -> Int:
    return Int(DIR_DZ[d])


@fieldwise_init
struct NavBakeConfig(Copyable, ImplicitlyCopyable, Movable):
    """Agent and voxel parameters for one navmesh bake (Recast `rcConfig`)."""

    var cell_size: Real  # XZ voxel side (m)
    var cell_height: Real  # Y voxel side (m)
    var agent_height: Real  # minimum headroom (m)
    var agent_radius: Real  # clearance kept from walls and ledges (m)
    var max_climb: Real  # largest step between adjacent floors (m)
    var max_slope_deg: Real  # steepest walkable triangle
    var tile_size: Int  # cells per tile side; polygons never cross a tile

    @staticmethod
    def default() -> NavBakeConfig:
        return NavBakeConfig(0.25, 0.1, 1.8, 0.3, 0.4, 45.0, 32)

    def validate(self) raises:
        if self.cell_size <= 0 or self.cell_height <= 0:
            raise Error("NavBakeConfig: cell_size and cell_height must be > 0")
        if self.agent_height <= 0 or self.agent_radius < 0 or self.max_climb < 0:
            raise Error("NavBakeConfig: agent_height > 0, agent_radius >= 0, max_climb >= 0")
        if self.max_slope_deg < 0 or self.max_slope_deg >= 90:
            raise Error("NavBakeConfig: max_slope_deg must be in [0, 90)")
        if self.tile_size < 1:
            raise Error("NavBakeConfig: tile_size must be >= 1")

    def walkable_height(self) -> Int:
        return Int(ceil(self.agent_height / self.cell_height))

    def walkable_climb(self) -> Int:
        return Int(floor(self.max_climb / self.cell_height))

    def walkable_radius(self) -> Int:
        return Int(ceil(self.agent_radius / self.cell_size))


struct Heightfield(Movable):
    """Solid spans per column, kept as singly linked lists sorted by height."""

    var width: Int
    var depth: Int
    var bmin: Vec3
    var cs: Real
    var ch: Real
    var head: List[Int]  # first span of each column, -1 = empty
    var smin: List[Int]
    var smax: List[Int]
    var walk: List[Bool]
    var next: List[Int]

    def __init__(out self, bmin: Vec3, bmax: Vec3, cs: Real, ch: Real):
        self.cs = cs
        self.ch = ch
        self.bmin = bmin
        self.width = max(1, Int(ceil((bmax[0] - bmin[0]) / cs)))
        self.depth = max(1, Int(ceil((bmax[2] - bmin[2]) / cs)))
        self.head = List[Int](length=self.width * self.depth, fill=-1)
        self.smin = List[Int]()
        self.smax = List[Int]()
        self.walk = List[Bool]()
        self.next = List[Int]()

    def add_span(mut self, x: Int, z: Int, smin_in: Int, smax_in: Int, walk_in: Bool, merge_thr: Int):
        """Insert [smin, smax] into column (x, z), merging every span it touches
        (Recast `addSpan`): the merged span is walkable if the walkable input's
        top is within `merge_thr` of the merged top."""
        var col = x + z * self.width
        var lo = smin_in
        var hi = smax_in
        var w = walk_in
        var prev = -1
        var cur = self.head[col]
        while cur >= 0:
            if self.smin[cur] > hi:
                break
            if self.smax[cur] < lo:
                prev = cur
                cur = self.next[cur]
                continue
            if self.smin[cur] < lo:
                lo = self.smin[cur]
            if self.smax[cur] > hi:
                hi = self.smax[cur]
            if abs(hi - self.smax[cur]) <= merge_thr:
                w = w or self.walk[cur]
            var nxt = self.next[cur]
            if prev >= 0:
                self.next[prev] = nxt
            else:
                self.head[col] = nxt
            cur = nxt
        var s = len(self.smin)
        self.smin.append(lo)
        self.smax.append(hi)
        self.walk.append(w)
        if prev >= 0:
            self.next.append(self.next[prev])
            self.next[prev] = s
        else:
            self.next.append(self.head[col])
            self.head[col] = s

    def span_count(self) -> Int:
        var n = 0
        for c in range(len(self.head)):
            var s = self.head[c]
            while s >= 0:
                n += 1
                s = self.next[s]
        return n


def _clip(poly: List[Vec3], axis: Int, v: Real, keep_above: Bool) -> List[Vec3]:
    """Sutherland-Hodgman against the axis-aligned plane `p[axis] = v`."""
    var out = List[Vec3]()
    var n = len(poly)
    if n == 0:
        return out^
    for i in range(n):
        var a = poly[i]
        var b = poly[(i + 1) % n]
        var da = a[axis] - v if keep_above else v - a[axis]
        var db = b[axis] - v if keep_above else v - b[axis]
        var ina = da >= 0
        var inb = db >= 0
        if ina:
            out.append(a)
        if ina != inb:
            var t = da / (da - db)
            out.append(a + (b - a) * t)
    return out^


def _sliver(poly: List[Vec3], axis: Int, tri_extent: Real) -> Bool:
    """A clipped piece with zero extent on `axis` from a triangle that does
    extend along it only touches the cell's boundary (a floor quad whose edge
    lies on a grid line): it belongs to the neighbouring cell. A wall lying in
    the grid plane has zero extent itself and is kept."""
    if tri_extent <= 0:
        return False
    var lo = poly[0][axis]
    var hi = poly[0][axis]
    for k in range(1, len(poly)):
        lo = min(lo, poly[k][axis])
        hi = max(hi, poly[k][axis])
    return hi - lo <= tri_extent * Real(1e-6)


def rasterize(mut hf: Heightfield, verts: List[Vec3], tris: List[Int], cfg: NavBakeConfig) raises:
    """Clip every triangle against the XZ grid and add one span per covered cell."""
    if len(tris) % 3 != 0:
        raise Error("rasterize: tris length must be a multiple of 3")
    for i in range(len(tris)):
        if tris[i] < 0 or tris[i] >= len(verts):
            raise Error("rasterize: triangle index out of range")
    var cos_slope = cos(cfg.max_slope_deg * Real(pi) / 180)
    var climb = cfg.walkable_climb()
    var y_cells = _SPAN_TOP - 1
    for t in range(len(tris) // 3):
        var a = verts[tris[3 * t]]
        var b = verts[tris[3 * t + 1]]
        var c = verts[tris[3 * t + 2]]
        var n = cross(b - a, c - a)
        var nl = sqrt(dot(n, n))
        if nl <= 0:
            continue  # degenerate: covers no area
        var walk = n[1] / nl >= cos_slope
        var lo = a
        var hi = a
        for k in range(3):
            var p = b if k == 1 else (c if k == 2 else a)
            for ax in range(3):
                lo[ax] = min(lo[ax], p[ax])
                hi[ax] = max(hi[ax], p[ax])
        var z0 = max(0, Int(floor((lo[2] - hf.bmin[2]) / hf.cs)))
        var z1 = min(hf.depth - 1, Int(floor((hi[2] - hf.bmin[2]) / hf.cs)))
        var x0 = max(0, Int(floor((lo[0] - hf.bmin[0]) / hf.cs)))
        var x1 = min(hf.width - 1, Int(floor((hi[0] - hf.bmin[0]) / hf.cs)))
        if z0 > z1 or x0 > x1:
            continue
        var tri = List[Vec3]()
        tri.append(a)
        tri.append(b)
        tri.append(c)
        for z in range(z0, z1 + 1):
            var zlo = hf.bmin[2] + Real(z) * hf.cs
            var row = _clip(_clip(tri, 2, zlo, True), 2, zlo + hf.cs, False)
            if len(row) < 3 or _sliver(row, 2, hi[2] - lo[2]):
                continue
            for x in range(x0, x1 + 1):
                var xlo = hf.bmin[0] + Real(x) * hf.cs
                var cell = _clip(_clip(row, 0, xlo, True), 0, xlo + hf.cs, False)
                if len(cell) < 3 or _sliver(cell, 0, hi[0] - lo[0]):
                    continue
                var ymin = cell[0][1]
                var ymax = cell[0][1]
                for k in range(1, len(cell)):
                    ymin = min(ymin, cell[k][1])
                    ymax = max(ymax, cell[k][1])
                # the 1e-3 cell slack keeps a floor that lies exactly on a
                # voxel boundary from rounding up a whole cell in float32
                # A flat floor exactly on a voxel boundary keeps its height:
                # the span is [top - 1, top], not [top, top + 1].
                var smax = Int(ceil((ymax - hf.bmin[1]) / hf.ch - 1e-3))
                var smin = min(Int(floor((ymin - hf.bmin[1]) / hf.ch + 1e-3)), smax - 1)
                if smax < 1 or smin > y_cells:
                    continue
                smin = max(0, min(smin, y_cells - 1))
                smax = max(smin + 1, min(smax, y_cells))
                hf.add_span(x, z, smin, smax, walk, climb)


def filter_low_hanging(mut hf: Heightfield, cfg: NavBakeConfig):
    """A non-walkable span whose top is within `max_climb` above a walkable
    span becomes walkable (Recast `filterLowHangingWalkableObstacles`)."""
    var climb = cfg.walkable_climb()
    for col in range(len(hf.head)):
        var prev_walk = False
        var prev_top = 0
        var s = hf.head[col]
        var first = True
        while s >= 0:
            var was = hf.walk[s]
            if not first and not was and prev_walk and hf.smax[s] - prev_top <= climb:
                hf.walk[s] = True
            prev_walk = was
            prev_top = hf.smax[s]
            first = False
            s = hf.next[s]


def filter_low_height(mut hf: Heightfield, cfg: NavBakeConfig):
    """Drop walkability where the open space above a span is below `agent_height`."""
    var need = cfg.walkable_height()
    for col in range(len(hf.head)):
        var s = hf.head[col]
        while s >= 0:
            var nxt = hf.next[s]
            var top = hf.smin[nxt] if nxt >= 0 else _SPAN_TOP
            if top - hf.smax[s] < need:
                hf.walk[s] = False
            s = nxt


struct CompactField(Movable):
    """Open (walkable-floor) spans with 4-neighbour connectivity.

    `avail` = walkable after the filters; `blocked` = carved by a dynamic
    obstacle; `walk` = available, not blocked, and at least `agent_radius` from
    any boundary (written by `erode`). Connections are made between available
    spans once and never change: carving and erosion only toggle flags."""

    var width: Int
    var depth: Int
    var bmin: Vec3
    var cs: Real
    var ch: Real
    var cell_start: List[Int]
    var cell_count: List[Int]
    var y: List[Int]  # floor, cell_height units above bmin.y
    var h: List[Int]  # clearance above the floor (capped)
    var cx: List[Int]
    var cz: List[Int]
    var con: List[Int]  # 4 per span: neighbour span or -1
    var avail: List[Bool]
    var blocked: List[Bool]
    var walk: List[Bool]
    var dist: List[Int]  # chamfer distance to the boundary (2 per cell)

    def __init__(out self, hf: Heightfield, cfg: NavBakeConfig):
        self.width = hf.width
        self.depth = hf.depth
        self.bmin = hf.bmin
        self.cs = hf.cs
        self.ch = hf.ch
        var ncols = hf.width * hf.depth
        self.cell_start = List[Int](length=ncols, fill=0)
        self.cell_count = List[Int](length=ncols, fill=0)
        self.y = List[Int]()
        self.h = List[Int]()
        self.cx = List[Int]()
        self.cz = List[Int]()
        for z in range(hf.depth):
            for x in range(hf.width):
                var col = x + z * hf.width
                self.cell_start[col] = len(self.y)
                var s = hf.head[col]
                while s >= 0:
                    var nxt = hf.next[s]
                    if hf.walk[s]:
                        var top = hf.smin[nxt] if nxt >= 0 else _SPAN_TOP
                        self.y.append(hf.smax[s])
                        self.h.append(min(top - hf.smax[s], 0xFFFF))
                        self.cx.append(x)
                        self.cz.append(z)
                    s = nxt
                self.cell_count[col] = len(self.y) - self.cell_start[col]
        var n = len(self.y)
        self.con = List[Int](length=4 * n, fill=-1)
        self.avail = List[Bool](length=n, fill=True)
        self.blocked = List[Bool](length=n, fill=False)
        self.walk = List[Bool](length=n, fill=True)
        self.dist = List[Int](length=n, fill=0)
        var need = cfg.walkable_height()
        var climb = cfg.walkable_climb()
        for s in range(n):
            for d in range(4):
                var nx = self.cx[s] + dir_dx(d)
                var nz = self.cz[s] + dir_dz(d)
                if nx < 0 or nz < 0 or nx >= self.width or nz >= self.depth:
                    continue
                var ncol = nx + nz * self.width
                for k in range(self.cell_count[ncol]):
                    var t = self.cell_start[ncol] + k
                    var bot = max(self.y[s], self.y[t])
                    var top = min(self.y[s] + self.h[s], self.y[t] + self.h[t])
                    if top - bot >= need and abs(self.y[t] - self.y[s]) <= climb:
                        self.con[4 * s + d] = t
                        break

    def span_count(self) -> Int:
        return len(self.y)

    def world_floor(self, s: Int) -> Vec3:
        """Centre of span `s`'s floor cell in world coordinates."""
        return Vec3(
            self.bmin[0] + (Real(self.cx[s]) + 0.5) * self.cs,
            self.bmin[1] + Real(self.y[s]) * self.ch,
            self.bmin[2] + (Real(self.cz[s]) + 0.5) * self.cs,
            0,
        )

    def neighbour(self, s: Int, d: Int) -> Int:
        """Walkable neighbour of `s` in direction `d`, or -1."""
        var t = self.con[4 * s + d]
        if t >= 0 and self.walk[t]:
            return t
        return -1

    def diagonal(self, s: Int, d: Int) -> Int:
        """Walkable diagonal neighbour between directions `d` and `d + 1`,
        reachable through BOTH orthogonal neighbours (no corner cutting)."""
        var a = self.neighbour(s, d)
        var b = self.neighbour(s, (d + 1) & 3)
        if a < 0 or b < 0:
            return -1
        var da = self.neighbour(a, (d + 1) & 3)
        var db = self.neighbour(b, d)
        if da < 0 or da != db:
            return -1
        return da

    def column_of(self, p: Vec3) -> Int:
        var x = Int(floor((p[0] - self.bmin[0]) / self.cs))
        var z = Int(floor((p[2] - self.bmin[2]) / self.cs))
        if x < 0 or z < 0 or x >= self.width or z >= self.depth:
            return -1
        return x + z * self.width

    def span_at(self, p: Vec3, max_dy: Real) -> Int:
        """Walkable span in `p`'s column whose floor is nearest to p.y, within
        `max_dy`; -1 if none."""
        var col = self.column_of(p)
        if col < 0:
            return -1
        var best = -1
        var best_dy = max_dy
        for k in range(self.cell_count[col]):
            var s = self.cell_start[col] + k
            if not self.walk[s]:
                continue
            var dy = abs(self.bmin[1] + Real(self.y[s]) * self.ch - p[1])
            if dy <= best_dy:
                best_dy = dy
                best = s
        return best


def erode(mut f: CompactField, radius_cells: Int):
    """Recompute `walk` for the whole field (see `erode_window`)."""
    erode_window(f, radius_cells, 0, 0, f.width - 1, f.depth - 1)


def erode_window(mut f: CompactField, radius_cells: Int, wx0: Int, wz0: Int, wx1: Int, wz1: Int):
    """Recompute `walk` from `avail`, `blocked` and the agent radius for the
    cells in [wx0, wx1] x [wz0, wz1].

    Two-pass chamfer (Recast `rcErodeWalkableArea`): a usable span missing any
    usable 4-neighbour is boundary (0); others start at a large value and
    relax over the 8-neighbourhood with weights 2 / 3. Spans with distance
    below `2 * radius_cells` are not walkable.

    Locality: the distances are computed over the write window grown by
    `radius_cells + 1`, ignoring everything outside it. A shortest chamfer
    path is monotone, so it stays inside the box of its two ends; a distance
    below 2r therefore comes from a boundary within r cells and is exact,
    and a larger one can only be over-estimated, which leaves the flag
    unchanged. Hence the written flags equal a whole-field erosion."""
    var g = radius_cells + 1
    var cx0 = max(0, wx0 - g)
    var cz0 = max(0, wz0 - g)
    var cx1 = min(f.width - 1, wx1 + g)
    var cz1 = min(f.depth - 1, wz1 + g)
    comptime BIG = 1 << 20
    for z in range(cz0, cz1 + 1):
        for x in range(cx0, cx1 + 1):
            var col = x + z * f.width
            for k in range(f.cell_count[col]):
                var s = f.cell_start[col] + k
                var ok = f.avail[s] and not f.blocked[s]
                if not ok:
                    f.dist[s] = -1
                    continue
                var boundary = False
                for d in range(4):
                    var t = f.con[4 * s + d]
                    if t < 0 or not f.avail[t] or f.blocked[t]:
                        boundary = True
                        break
                f.dist[s] = 0 if boundary else BIG

    # Pass 1: (-x), (-x,-z), (-z), (+x,-z) -- already visited in scan order.
    for z in range(cz0, cz1 + 1):
        for x in range(cx0, cx1 + 1):
            var col = x + z * f.width
            for k in range(f.cell_count[col]):
                var s = f.cell_start[col] + k
                if f.dist[s] <= 0:
                    continue
                if x > cx0:
                    var a = f.con[4 * s + 2]  # -x
                    if a >= 0 and f.dist[a] >= 0:
                        f.dist[s] = min(f.dist[s], f.dist[a] + 2)
                        if z > cz0:
                            var ad = f.con[4 * a + 3]  # -x,-z
                            if ad >= 0 and f.dist[ad] >= 0:
                                f.dist[s] = min(f.dist[s], f.dist[ad] + 3)
                if z > cz0:
                    var b = f.con[4 * s + 3]  # -z
                    if b >= 0 and f.dist[b] >= 0:
                        f.dist[s] = min(f.dist[s], f.dist[b] + 2)
                        if x < cx1:
                            var bd = f.con[4 * b + 0]  # +x,-z
                            if bd >= 0 and f.dist[bd] >= 0:
                                f.dist[s] = min(f.dist[s], f.dist[bd] + 3)
    # Pass 2: (+x), (+x,+z), (+z), (-x,+z) -- reverse scan order.
    for zz in range(cz1 - cz0 + 1):
        var z = cz1 - zz
        for xx in range(cx1 - cx0 + 1):
            var x = cx1 - xx
            var col = x + z * f.width
            for k in range(f.cell_count[col]):
                var s = f.cell_start[col] + k
                if f.dist[s] <= 0:
                    continue
                if x < cx1:
                    var a = f.con[4 * s + 0]  # +x
                    if a >= 0 and f.dist[a] >= 0:
                        f.dist[s] = min(f.dist[s], f.dist[a] + 2)
                        if z < cz1:
                            var ad = f.con[4 * a + 1]  # +x,+z
                            if ad >= 0 and f.dist[ad] >= 0:
                                f.dist[s] = min(f.dist[s], f.dist[ad] + 3)
                if z < cz1:
                    var b = f.con[4 * s + 1]  # +z
                    if b >= 0 and f.dist[b] >= 0:
                        f.dist[s] = min(f.dist[s], f.dist[b] + 2)
                        if x > cx0:
                            var bd = f.con[4 * b + 2]  # -x,+z
                            if bd >= 0 and f.dist[bd] >= 0:
                                f.dist[s] = min(f.dist[s], f.dist[bd] + 3)
    var thr = 2 * radius_cells
    for z in range(wz0, wz1 + 1):
        for x in range(wx0, wx1 + 1):
            var col = x + z * f.width
            for k in range(f.cell_count[col]):
                var s = f.cell_start[col] + k
                f.walk[s] = f.dist[s] >= 0 and f.dist[s] >= thr
