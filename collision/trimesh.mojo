"""Static level geometry: triangle meshes and heightfields.

Everything the solver could stand on until now was a closed convex body. A
level is not convex, so there was no way to express one — the gap that makes
this table stakes rather than a refinement.

The contact itself is not new work. A triangle IS a convex hull, just a
degenerate one with three vertices and a single face, so `collision/hull.mojo`
already knows how to clip a box or a hull against it. What static geometry adds
is the MIDPHASE: a level has thousands of triangles and a falling crate touches
three of them, so the question is which triangles to hand to the narrowphase.

Two answers are implemented, because they scale differently and the engine's
rule is that comparable methods get compared:

  `TriMesh`     — arbitrary soup, indexed by a BVH over triangle boxes. Handles
                  overhangs, walls, and anything an artist exports. Query cost
                  is O(log T) plus the overlap set.
  `HeightField` — a regular grid sampled as a height per cell corner, with the
                  triangulation left implicit. Cannot express an overhang, but
                  the candidate lookup is arithmetic: clamp the query box to
                  cell indices and read them off, no tree, no memory to touch
                  outside the footprint. O(1) in the terrain's size.

They expose the same two operations (`candidates`, `tri`), so the solver has
one code path and the benchmark can put them side by side on identical terrain.

Vertex storage is flat `List[Real]`, stride 3. On this nightly a `List[Vec3]`
silently loses its tail elements the moment it crosses a function boundary —
`collision/hull.mojo` carries the reduced probe.
"""

from std.math import sqrt, floor
from geometry.trig import cos
from std.collections import Dict
from geometry.vec import Real, Vec3, dot, length, normalize
from geometry.aabb import AABB
from spatial.bvh import BVH
from geometry.ray import Ray
from geometry.gjk import ConvexPoly


def _tri_normal(a: Vec3, b: Vec3, c: Vec3) -> Vec3:
    """Outward normal from the winding, or zero for a degenerate triangle.

    Degenerate triangles are returned as zero rather than skipped so that
    triangle indices stay stable: a mesh's triangle 7 must be triangle 7 after
    any change here, because contact warm-starting keys on that index."""
    var e1 = b - a
    var e2 = c - a
    var n = Vec3(
        e1[1] * e2[2] - e1[2] * e2[1],
        e1[2] * e2[0] - e1[0] * e2[2],
        e1[0] * e2[1] - e1[1] * e2[0],
        0,
    )
    var l = length(n)
    if l < 1e-12:
        return Vec3(0, 0, 0, 0)
    return n / l


def closest_point_on_triangle(p: Vec3, a: Vec3, b: Vec3, c: Vec3) -> Vec3:
    """Closest point on triangle (a, b, c) to `p` (Ericson, Real-Time
    Collision Detection 5.1.5): region tests via barycentric coordinates
    that degrade gracefully to an edge or a vertex, never dividing by a
    zero triangle area on the path actually taken. Used by 17.0f's
    soft-particle-vs-mesh query (F4b) so a lattice resting on a trimesh or
    heightfield gets an exact surface point instead of the level-sized fake
    sphere the old code substituted."""
    var ab = b - a
    var ac = c - a
    var ap = p - a
    var d1 = dot(ab, ap)
    var d2 = dot(ac, ap)
    if d1 <= 0 and d2 <= 0:
        return a
    var bp = p - b
    var d3 = dot(ab, bp)
    var d4 = dot(ac, bp)
    if d3 >= 0 and d4 <= d3:
        return b
    var vc = d1 * d4 - d3 * d2
    if vc <= 0 and d1 >= 0 and d3 <= 0:
        var v = d1 / (d1 - d3)
        return a + ab * v
    var cp = p - c
    var d5 = dot(ab, cp)
    var d6 = dot(ac, cp)
    if d6 >= 0 and d5 <= d6:
        return c
    var vb = d5 * d2 - d1 * d6
    if vb <= 0 and d2 >= 0 and d6 <= 0:
        var w = d2 / (d2 - d6)
        return a + ac * w
    var va = d3 * d6 - d5 * d4
    if va <= 0 and (d4 - d3) >= 0 and (d5 - d6) >= 0:
        var w2 = (d4 - d3) / ((d4 - d3) + (d5 - d6))
        return b + (c - b) * w2
    var denom = 1 / (va + vb + vc)
    var v2 = vb * denom
    var w3 = vc * denom
    return a + ab * v2 + ac * w3


def _material_ids(ids: List[Int], ntri: Int, who: String) raises -> List[UInt16]:
    var out = List[UInt16]()
    if len(ids) == 0:
        return out^
    if len(ids) != ntri:
        raise Error(who + ": one material id per triangle expected")
    out.reserve(ntri)
    for t in range(ntri):
        if ids[t] < 0 or ids[t] > 65535:
            raise Error(who + ": material id must be in 0 .. 65535")
        out.append(UInt16(ids[t]))
    return out^


struct TriMesh(Movable, Deinitable):
    """A static triangle soup with a BVH midphase.

    Normals are stored per triangle rather than recomputed per query. They are
    the reason mesh contact works at all: the narrowphase picks its separating
    axis by minimum penetration over the two shapes' face normals, and a
    triangle contributes exactly one — its own. Without it a crate landing on a
    ramp would be pushed along whichever of ITS faces happened to overlap
    least, which is the box's axis, not the slope's.

    Single-sided, by the winding. A level's triangles have an inside, and
    accepting contact from behind would let a fast body that has already
    tunnelled be pushed further through instead of back out."""

    var v: List[Real]  # vertices, stride 3
    var idx: List[Int]  # 3 vertex indices per triangle
    var nrm: List[Real]  # one outward normal per triangle, stride 3
    # ROADMAP 17.45: per triangle, bit k set = edge (v_k, v_{k+1}) is ACTIVE
    # (a crease or a boundary). Every edge is active by default, which keeps
    # contact generation exactly as before; `geometry.mesh_bake.active_edges`
    # computes real flags, and `contact_gen.try_mesh_pair` then stops flat
    # seams between coplanar triangles from producing edge normals.
    var active: List[UInt8]
    # ROADMAP 17.53: per-triangle surface material id (empty = none set;
    # `ColliderSet.material` then reports -1)
    var material: List[UInt16]
    var bvh: BVH[3]

    def __init__(out self, verts: List[Real], indices: List[Int]) raises:
        """Audit E13: `indices` not a multiple of 3 leaves a partial trailing
        triangle whose missing vertex silently reads whatever `_vert`
        happens to compute from out-of-range `self.v` offsets; an index
        `>= len(verts) // 3` is a straight out-of-bounds read in `_vert`.
        Both are caught once here rather than left as UB the first time
        `tri()`/`_vert()` is called during BVH construction just below."""
        if len(indices) % 3 != 0:
            raise Error("TriMesh: len(indices) must be a multiple of 3")
        var nverts = len(verts) // 3
        for i in range(len(indices)):
            if indices[i] < 0 or indices[i] >= nverts:
                raise Error("TriMesh: vertex index out of range")
        self.v = List[Real](capacity=len(verts))
        for i in range(len(verts)):
            self.v.append(verts[i])
        self.idx = List[Int](capacity=len(indices))
        for i in range(len(indices)):
            self.idx.append(indices[i])
        var nt = len(self.idx) // 3
        self.nrm = List[Real](capacity=3 * nt)
        self.active = List[UInt8](capacity=nt)
        for _ in range(nt):
            self.active.append(7)
        self.material = List[UInt16]()
        self.bvh = BVH[3]()  # before any self method call: all fields must be live
        var boxes = List[AABB[3]](capacity=nt)
        var proxies = List[Int](capacity=nt)
        for t in range(nt):
            var a = self._vert(self.idx[3 * t])
            var b = self._vert(self.idx[3 * t + 1])
            var c = self._vert(self.idx[3 * t + 2])
            var n = _tri_normal(a, b, c)
            self.nrm.append(n[0])
            self.nrm.append(n[1])
            self.nrm.append(n[2])
            var lo = Vec3(0, 0, 0, 0)
            var hi = Vec3(0, 0, 0, 0)
            comptime for k in range(3):
                lo[k] = min(a[k], min(b[k], c[k]))
                hi[k] = max(a[k], max(b[k], c[k]))
            boxes.append(AABB[3](lo, hi))
            proxies.append(t)
        if nt > 0:
            # SAH: a level is built once and queried every step of every frame,
            # so build time is the cheap side of the trade by a wide margin.
            self.bvh.build_boxes(boxes, proxies, sah=True)

    def set_active_angle(mut self, angle: Real):
        """Compute the active-edge flags from the mesh itself (ROADMAP 17.19):
        an edge shared by exactly two triangles (same vertex indices) whose
        normals differ by at most `angle` radians is inactive; boundary
        edges, creases and edges shared by more than two stay active. A
        negative angle makes every edge active again. The same rule as
        `HeightField.set_active_angle`, for meshes whose seams share
        vertices."""
        var nt = self.ntri()
        if angle < 0:
            for t in range(nt):
                self.active[t] = 7
            return
        var c = cos(angle)
        var first = Dict[Int, Int]()  # edge key -> first triangle * 3 + edge
        var other = List[Int](length=3 * nt, fill=-1)  # neighbour triangle per edge, -2 = shared by > 2
        var nv = len(self.v) // 3 + 1
        for t in range(nt):
            for k in range(3):
                var a = self.idx[3 * t + k]
                var b = self.idx[3 * t + (k + 1) % 3]
                var key = min(a, b) * nv + max(a, b)
                var f = first.get(key, -1)
                if f < 0:
                    first[key] = 3 * t + k
                else:
                    var t0 = f // 3
                    if other[f] == -1:
                        other[f] = t
                        other[3 * t + k] = t0
                    else:
                        other[f] = -2
                        other[3 * t + k] = -2
        for t in range(nt):
            var bits = UInt8(0)
            var n0 = Vec3(self.nrm[3 * t], self.nrm[3 * t + 1], self.nrm[3 * t + 2], 0)
            for k in range(3):
                var o = other[3 * t + k]
                var act = True
                if o >= 0:
                    var n1 = Vec3(self.nrm[3 * o], self.nrm[3 * o + 1], self.nrm[3 * o + 2], 0)
                    act = dot(n0, n1) < c
                if act:
                    bits |= UInt8(1) << UInt8(k)
            self.active[t] = bits

    def set_active_edges(mut self, flags: List[UInt8]) raises:
        """Install per-triangle active-edge flags (see the field)."""
        if len(flags) != self.ntri():
            raise Error("TriMesh.set_active_edges: one flag byte per triangle expected")
        for t in range(len(flags)):
            self.active[t] = flags[t] & 7

    def set_materials(mut self, ids: List[Int]) raises:
        """Per-triangle surface material ids (ROADMAP 17.53), 0..65535; an
        empty list clears them."""
        self.material = _material_ids(ids, self.ntri(), "TriMesh.set_materials")

    def _vert(self, i: Int) -> Vec3:
        return Vec3(self.v[3 * i], self.v[3 * i + 1], self.v[3 * i + 2], 0)

    def ntri(self) -> Int:
        return len(self.idx) // 3

    def tri(self, t: Int) -> ConvexPoly[3]:
        var p = ConvexPoly[3]()
        p.add(self._vert(self.idx[3 * t]))
        p.add(self._vert(self.idx[3 * t + 1]))
        p.add(self._vert(self.idx[3 * t + 2]))
        return p^

    def tri_faces(self, t: Int) -> List[Real]:
        """The triangle's single face normal, flat — the `faces_b` the hull
        narrowphase expects. EMPTY for a zero-area triangle, which is how the
        solver is told to skip it: such a triangle is still a perfectly valid
        convex object (a segment or a point), so GJK will happily report a hit
        against it and a crate will come to rest balanced on a mathematical
        line. Having no surface, it must contribute no contact."""
        var f = List[Real](capacity=3)
        var n = Vec3(self.nrm[3 * t], self.nrm[3 * t + 1], self.nrm[3 * t + 2], 0)
        if length(n) < 0.5:  # stored normals are unit or exactly zero
            return f^
        f.append(n[0])
        f.append(n[1])
        f.append(n[2])
        return f^

    def candidates(self, box: AABB[3], mut out: List[Int]):
        self.bvh.query_region(box, out)

    def ray_candidates(self, o: Vec3, d: Vec3, max_t: Real, mut out: List[Int]):
        """Triangles whose BVH boxes the ray segment enters (ROADMAP 17.53)."""
        self.bvh.ray_leaves(Ray[3](o, d, max_t), out)

    def bounds(self) -> AABB[3]:
        var n = len(self.v) // 3
        if n == 0:
            return AABB[3](Vec3(0, 0, 0, 0), Vec3(0, 0, 0, 0))
        var lo = self._vert(0)
        var hi = self._vert(0)
        for i in range(1, n):
            var p = self._vert(i)
            comptime for k in range(3):
                lo[k] = min(lo[k], p[k])
                hi[k] = max(hi[k], p[k])
        return AABB[3](lo, hi)


comptime _HB = 16  # heightfield bounds-summary block size (corners)


struct HeightField(Movable, Deinitable):
    """A regular grid of heights, triangulated implicitly.

    `h[iz * nx + ix]` is the height at grid corner (ix, iz); the cell between
    four corners is two triangles split along its (ix+iz) diagonal, alternating
    per cell so the tessellation has no directional bias — a ball rolled across
    a uniform slope should not drift sideways because every diagonal ran the
    same way.

    The triangles are never stored. `candidates` converts a query box straight
    into a range of cell indices, which is what makes this O(1) in the size of
    the terrain instead of O(log T): a 512x512 field is 522,242 triangles that
    a BVH would have to be built over, sorted, and traversed, and none of that
    memory is touched here."""

    var h: List[Real]
    var nx: Int
    var nz: Int
    var cell: Real
    var ox: Real  # world x of grid corner (0, 0)
    var oz: Real
    # ROADMAP 17.30: min/max height of each _HB x _HB block of corners, so a
    # local edit re-derives the field's vertical bounds from the touched
    # blocks plus the block table instead of rescanning every height.
    var bmin: List[Real]
    var bmax: List[Real]
    var nbx: Int
    var nbz: Int
    # ROADMAP 17.45: cosine of the crease angle above which an edge is active;
    # 2 (the default) = every edge active, the old behaviour bit for bit.
    var active_cos: Real
    var material: List[UInt16]  # ROADMAP 17.53: per triangle; empty = none

    def __init__(
        out self, heights: List[Real], nx: Int, nz: Int,
        cell: Real, ox: Real = 0, oz: Real = 0,
    ) raises:
        """Audit E13: `len(heights) != nx * nz` misaligns every `h[iz * nx +
        ix]` lookup in `_corner` from the caller's grid intent (silent
        truncation or an out-of-bounds read, depending on direction);
        `cell <= 0` divides by zero/flips sign in `_coord` and every caller
        of it (`candidates`' cell-range clamp, `to_trimesh`'s corner-index
        recovery)."""
        if len(heights) != nx * nz:
            raise Error("HeightField: len(heights) must equal nx * nz")
        if cell <= 0:
            raise Error("HeightField: cell must be > 0")
        self.h = List[Real](capacity=len(heights))
        for i in range(len(heights)):
            self.h.append(heights[i])
        self.nx = nx
        self.nz = nz
        self.cell = cell
        self.ox = ox
        self.oz = oz
        self.nbx = (nx + _HB - 1) // _HB
        self.nbz = (nz + _HB - 1) // _HB
        self.active_cos = 2
        self.material = List[UInt16]()
        self.bmin = List[Real](length=self.nbx * self.nbz, fill=0)
        self.bmax = List[Real](length=self.nbx * self.nbz, fill=0)
        for bz in range(self.nbz):
            for bx in range(self.nbx):
                self._refresh_block(bx, bz)

    def _refresh_block(mut self, bx: Int, bz: Int):
        var lo = Real.MAX
        var hi = -Real.MAX
        for iz in range(bz * _HB, min((bz + 1) * _HB, self.nz)):
            for ix in range(bx * _HB, min((bx + 1) * _HB, self.nx)):
                var y = self.h[iz * self.nx + ix]
                lo = min(lo, y)
                hi = max(hi, y)
        self.bmin[bz * self.nbx + bx] = lo
        self.bmax[bz * self.nbx + bx] = hi

    def height_at(self, ix: Int, iz: Int) -> Real:
        return self.h[min(max(iz, 0), self.nz - 1) * self.nx + min(max(ix, 0), self.nx - 1)]

    def set_height(mut self, ix: Int, iz: Int, y: Real):
        """Set one corner (ignored outside the grid)."""
        if ix < 0 or iz < 0 or ix >= self.nx or iz >= self.nz:
            return
        self.h[iz * self.nx + ix] = y
        self._refresh_block(ix // _HB, iz // _HB)

    def deform(mut self, cx: Real, cz: Real, radius: Real, delta: Real) -> Int:
        """Raise (delta > 0) or dig (delta < 0) a smooth disc of `radius`
        around world (cx, cz): corner heights change by
        delta * (1 - (d / radius)^2). Returns the number of corners edited;
        only the blocks they sit in are re-summarised."""
        if radius <= 0 or self.nx == 0 or self.nz == 0:
            return 0
        var ix0 = max(Int((cx - radius - self.ox) / self.cell), 0)
        var ix1 = min(Int((cx + radius - self.ox) / self.cell) + 1, self.nx - 1)
        var iz0 = max(Int((cz - radius - self.oz) / self.cell), 0)
        var iz1 = min(Int((cz + radius - self.oz) / self.cell) + 1, self.nz - 1)
        var edited = 0
        for iz in range(iz0, iz1 + 1):
            for ix in range(ix0, ix1 + 1):
                var dx = self.ox + Real(ix) * self.cell - cx
                var dz = self.oz + Real(iz) * self.cell - cz
                var d2 = dx * dx + dz * dz
                if d2 < radius * radius:
                    self.h[iz * self.nx + ix] += delta * (1 - d2 / (radius * radius))
                    edited += 1
        if edited > 0:
            for bz in range(iz0 // _HB, iz1 // _HB + 1):
                for bx in range(ix0 // _HB, ix1 // _HB + 1):
                    self._refresh_block(bx, bz)
        return edited

    def bounds_blocks(self) -> AABB[3]:
        """`bounds()` from the block table (the incremental path)."""
        if len(self.h) == 0:
            return AABB[3](Vec3(0, 0, 0, 0), Vec3(0, 0, 0, 0))
        var lo = self.bmin[0]
        var hi = self.bmax[0]
        for i in range(1, len(self.bmin)):
            lo = min(lo, self.bmin[i])
            hi = max(hi, self.bmax[i])
        return AABB[3](
            Vec3(self.ox, lo, self.oz, 0),
            Vec3(
                self.ox + Real(self.nx - 1) * self.cell,
                hi,
                self.oz + Real(self.nz - 1) * self.cell,
                0,
            ),
        )

    def ntri(self) -> Int:
        if self.nx < 2 or self.nz < 2:
            return 0
        return (self.nx - 1) * (self.nz - 1) * 2

    def set_materials(mut self, ids: List[Int]) raises:
        """Per-triangle surface material ids (ROADMAP 17.53; triangle t as in
        `tri(t)`: cell (t // 2) row-major, two per cell); empty clears."""
        self.material = _material_ids(ids, self.ntri(), "HeightField.set_materials")

    def _corner(self, ix: Int, iz: Int) -> Vec3:
        var cx = min(max(ix, 0), self.nx - 1)
        var cz = min(max(iz, 0), self.nz - 1)
        return Vec3(
            self.ox + Real(cx) * self.cell,
            self.h[cz * self.nx + cx],
            self.oz + Real(cz) * self.cell,
            0,
        )

    def _tri_ij(self, t: Int) -> List[Int]:
        """Grid corners (ix, iz) of triangle t's three vertices, in the order
        `tri` emits them (flat: x0, z0, x1, z1, x2, z2)."""
        var per_row = (self.nx - 1) * 2
        var iz = t // per_row
        var rem = t - iz * per_row
        var ix = rem // 2
        var second = (rem & 1) == 1
        if ((ix + iz) & 1) == 0:
            if not second:
                return [ix, iz, ix, iz + 1, ix + 1, iz + 1]
            return [ix, iz, ix + 1, iz + 1, ix + 1, iz]
        if not second:
            return [ix, iz, ix, iz + 1, ix + 1, iz]
        return [ix + 1, iz, ix, iz + 1, ix + 1, iz + 1]

    def set_active_angle(mut self, angle: Real):
        """Edges between triangles whose normals differ by at most `angle`
        radians become inactive (flat seams stop producing edge normals);
        computed per query from the current heights, so `deform` keeps them
        right. A negative angle restores every edge active."""
        self.active_cos = cos(angle) if angle >= 0 else Real(2)

    def active(self, t: Int) -> UInt8:
        """Active-edge bits of triangle t (bit k = edge (v_k, v_k+1))."""
        if self.active_cos > 1:
            return 7
        var me = self._tri_ij(t)
        var n0 = self._tri_n(t)
        var per_row = (self.nx - 1) * 2
        var bits = UInt8(0)
        for k in range(3):
            var ax = me[2 * k]
            var az = me[2 * k + 1]
            var bx = me[2 * ((k + 1) % 3)]
            var bz = me[2 * ((k + 1) % 3) + 1]
            # the other triangle with both corners lies in a cell touching
            # the edge: scan the up to 3 x 3 cells around it
            var found = -1
            var cx0 = min(ax, bx) - 1
            var cz0 = min(az, bz) - 1
            for zz in range(cz0, cz0 + 3):
                for xx in range(cx0, cx0 + 3):
                    if xx < 0 or zz < 0 or xx >= self.nx - 1 or zz >= self.nz - 1:
                        continue
                    for half in range(2):
                        var u = zz * per_row + xx * 2 + half
                        if u == t:
                            continue
                        var o = self._tri_ij(u)
                        var hit = 0
                        for m in range(3):
                            if (o[2 * m] == ax and o[2 * m + 1] == az) or (o[2 * m] == bx and o[2 * m + 1] == bz):
                                hit += 1
                        if hit == 2:
                            found = u
            var act = True
            if found >= 0:
                act = dot(n0, self._tri_n(found)) < self.active_cos
            if act:
                bits |= UInt8(1) << UInt8(k)
        return bits

    def _tri_n(self, t: Int) -> Vec3:
        var p = self.tri(t)
        var n = _tri_normal(p.points[0], p.points[1], p.points[2])
        var l = length(n)
        if l <= 0:
            return Vec3(0, 1, 0, 0)
        return n / l if n[1] >= 0 else n / (-l)

    def tri(self, t: Int) -> ConvexPoly[3]:
        """Triangle `t` of the implicit tessellation. Two per cell, in
        row-major cell order, so the index is stable for warm-starting."""
        var p = ConvexPoly[3]()
        if self.nx < 2 or self.nz < 2:
            return p^
        var per_row = (self.nx - 1) * 2
        var iz = t // per_row
        var rem = t - iz * per_row
        var ix = rem // 2
        var second = (rem & 1) == 1
        var v00 = self._corner(ix, iz)
        var v10 = self._corner(ix + 1, iz)
        var v01 = self._corner(ix, iz + 1)
        var v11 = self._corner(ix + 1, iz + 1)
        # Alternating diagonal, so the tessellation carries no net direction.
        if ((ix + iz) & 1) == 0:
            if not second:
                p.add(v00)
                p.add(v01)
                p.add(v11)
            else:
                p.add(v00)
                p.add(v11)
                p.add(v10)
        else:
            if not second:
                p.add(v00)
                p.add(v01)
                p.add(v10)
            else:
                p.add(v10)
                p.add(v01)
                p.add(v11)
        return p^

    def tri_faces(self, t: Int) -> List[Real]:
        var p = self.tri(t)
        var f = List[Real](capacity=3)
        if len(p.points) < 3:
            return f^
        var n = _tri_normal(p.points[0], p.points[1], p.points[2])
        if length(n) < 0.5:
            return f^  # degenerate cell: no surface, no contact
        if n[1] < 0:
            n = -n  # terrain faces up; winding is an implementation detail here
        f.append(n[0])
        f.append(n[1])
        f.append(n[2])
        return f^

    def ray_candidates(self, o: Vec3, d: Vec3, max_t: Real, mut out: List[Int]):
        """Triangles of the cells the ray's x/z projection crosses, in order
        (ROADMAP 17.53: a grid DDA, Amanatides-Woo 1987). A cell is skipped
        when the ray's height over it stays above the cell's highest corner
        or below its lowest."""
        if self.nx < 2 or self.nz < 2:
            return
        var x_hi = self.ox + Real(self.nx - 1) * self.cell
        var z_hi = self.oz + Real(self.nz - 1) * self.cell
        # clip the segment to the grid's x / z slab
        var t0 = Real(0)
        var t1 = max_t
        for kk in range(2):
            var k = 2 * kk  # x, then z
            var lo = self.ox if k == 0 else self.oz
            var hi = x_hi if k == 0 else z_hi
            if abs(d[k]) < 1e-12:
                if o[k] < lo or o[k] > hi:
                    return
                continue
            var ta = (lo - o[k]) / d[k]
            var tb = (hi - o[k]) / d[k]
            if ta > tb:
                var tmp = ta
                ta = tb
                tb = tmp
            t0 = max(t0, ta)
            t1 = min(t1, tb)
        if t0 > t1:
            return
        var px = o[0] + d[0] * t0
        var pz = o[2] + d[2] * t0
        var ix = min(max(Int(floor(Float64((px - self.ox) / self.cell))), 0), self.nx - 2)
        var iz = min(max(Int(floor(Float64((pz - self.oz) / self.cell))), 0), self.nz - 2)
        var sx = 1 if d[0] > 0 else -1
        var sz = 1 if d[2] > 0 else -1
        var big = Real(1e30)
        var tdx = self.cell / abs(d[0]) if abs(d[0]) > 1e-12 else big
        var tdz = self.cell / abs(d[2]) if abs(d[2]) > 1e-12 else big
        var nxb = self.ox + Real(ix + (1 if sx > 0 else 0)) * self.cell
        var nzb = self.oz + Real(iz + (1 if sz > 0 else 0)) * self.cell
        var tmx = (nxb - o[0]) / d[0] if abs(d[0]) > 1e-12 else big
        var tmz = (nzb - o[2]) / d[2] if abs(d[2]) > 1e-12 else big
        var per_row = (self.nx - 1) * 2
        var t = t0
        while True:
            var t_exit = min(min(tmx, tmz), t1)
            var y_a = o[1] + d[1] * t
            var y_b = o[1] + d[1] * t_exit
            var c_lo = min(min(self.height_at(ix, iz), self.height_at(ix + 1, iz)), min(self.height_at(ix, iz + 1), self.height_at(ix + 1, iz + 1)))
            var c_hi = max(max(self.height_at(ix, iz), self.height_at(ix + 1, iz)), max(self.height_at(ix, iz + 1), self.height_at(ix + 1, iz + 1)))
            if not (min(y_a, y_b) > c_hi + 1e-4 or max(y_a, y_b) < c_lo - 1e-4):
                out.append(iz * per_row + 2 * ix)
                out.append(iz * per_row + 2 * ix + 1)
            if t_exit >= t1:
                return
            if tmx < tmz:
                ix += sx
                t = tmx
                tmx += tdx
            else:
                iz += sz
                t = tmz
                tmz += tdz
            if ix < 0 or ix > self.nx - 2 or iz < 0 or iz > self.nz - 2:
                return

    def candidates(self, box: AABB[3], mut out: List[Int]):
        """Cells overlapping the query box, as triangle indices. No tree: the
        box's x/z range maps directly onto cell indices."""
        if self.nx < 2 or self.nz < 2:
            return
        var per_row = (self.nx - 1) * 2
        var x0 = Int(floor(Float64((box.min[0] - self.ox) / self.cell)))
        var x1 = Int(floor(Float64((box.max[0] - self.ox) / self.cell)))
        var z0 = Int(floor(Float64((box.min[2] - self.oz) / self.cell)))
        var z1 = Int(floor(Float64((box.max[2] - self.oz) / self.cell)))
        x0 = min(max(x0, 0), self.nx - 2)
        x1 = min(max(x1, 0), self.nx - 2)
        z0 = min(max(z0, 0), self.nz - 2)
        z1 = min(max(z1, 0), self.nz - 2)
        if box.max[0] < self.ox or box.min[0] > self.ox + Real(self.nx - 1) * self.cell:
            return
        if box.max[2] < self.oz or box.min[2] > self.oz + Real(self.nz - 1) * self.cell:
            return
        for iz in range(z0, z1 + 1):
            for ix in range(x0, x1 + 1):
                # The y test is what keeps the candidate set honest: a box high
                # above the terrain overlaps the cell in x/z but touches
                # nothing, and reporting it would make this look cheaper than a
                # BVH while doing more narrowphase work.
                var lo = self._corner(ix, iz)[1]
                var hi = lo
                comptime for c in range(4):
                    var y = self._corner(ix + (c & 1), iz + (c >> 1))[1]
                    lo = min(lo, y)
                    hi = max(hi, y)
                if box.max[1] < lo or box.min[1] > hi:
                    continue
                out.append((iz * per_row) + ix * 2)
                out.append((iz * per_row) + ix * 2 + 1)

    def bounds(self) -> AABB[3]:
        if len(self.h) == 0:
            return AABB[3](Vec3(0, 0, 0, 0), Vec3(0, 0, 0, 0))
        var lo = self.h[0]
        var hi = self.h[0]
        for i in range(1, len(self.h)):
            lo = min(lo, self.h[i])
            hi = max(hi, self.h[i])
        return AABB[3](
            Vec3(self.ox, lo, self.oz, 0),
            Vec3(
                self.ox + Real(self.nx - 1) * self.cell,
                hi,
                self.oz + Real(self.nz - 1) * self.cell,
                0,
            ),
        )

    def to_trimesh(self) raises -> TriMesh:
        """The same surface as an explicit soup — the parity reference. If the
        two disagree on a resting height, one of the two candidate paths is
        wrong, and the test says which."""
        var verts = List[Real](capacity=3 * self.nx * self.nz)
        for iz in range(self.nz):
            for ix in range(self.nx):
                var c = self._corner(ix, iz)
                verts.append(c[0])
                verts.append(c[1])
                verts.append(c[2])
        var nt = self.ntri()
        var idx = List[Int](capacity=3 * nt)
        for t in range(nt):
            var p = self.tri(t)
            for k in range(3):
                # Recover the corner index from the position: the grid is
                # regular, so this is exact arithmetic, not a search.
                var q = p.points[k]
                var ix = Int(
                    floor(Float64((q[0] - self.ox) / self.cell + 0.5))
                )
                var iz = Int(
                    floor(Float64((q[2] - self.oz) / self.cell + 0.5))
                )
                idx.append(iz * self.nx + ix)
        return TriMesh(verts, idx)
