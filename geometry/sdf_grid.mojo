"""Signed distance grid baked from a triangle mesh (ROADMAP 17.45).

`geometry.sdf3.Sdf3` covers four analytic primitives. A sculpted mesh has no
formula, so this samples one: `bake_sdf_grid(verts, idx, res, pad)` puts an
`res`^3 lattice over the mesh bounds (grown by `pad`), and stores at every
node the distance to the nearest triangle, negative inside. Inside-ness is
the generalized winding number (Jacobson et al. 2013): the sum of the solid
angles the triangles subtend at the point, / 4 pi, is ~1 inside a closed
mesh and ~0 outside, and it degrades gracefully on meshes with small holes
where a ray-parity test flips. `distance(p)` is trilinear between nodes and
`gradient(p)` the analytic gradient of that trilinear cell, so sampling costs
eight reads whatever the triangle count.

Baking is brute force: every node visits every triangle (closest point +
solid angle), O(res^3 x T). Measured in `test_sdf_grid`; a BVH nearest query
is the way to make it scale (not done here). Errors: a node value is exact up
to float rounding; between nodes the trilinear interpolant differs from the
true distance by at most about one cell diagonal near sharp features.

Vertex layout as `geometry.mesh_bake`: flat `List[Real]` stride 3, triangles
flat `List[Int]` stride 3, CCW seen from outside.
"""

from std.math import sqrt, atan2, floor
from .vec import Real, Vec3, dot, cross, length
from .distance_field import DistanceField3
from std.collections import Dict

comptime _PI = 3.14159265358979323846


def _v(verts: List[Real], i: Int) -> Vec3:
    return Vec3(verts[3 * i], verts[3 * i + 1], verts[3 * i + 2], 0)


def closest_on_triangle(p: Vec3, a: Vec3, b: Vec3, c: Vec3) -> Vec3:
    """Ericson 5.1.5 (the same routine as `collision.trimesh`; geometry
    cannot import the higher collision layer)."""
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
        return a + ab * (d1 / (d1 - d3))
    var cp = p - c
    var d5 = dot(ab, cp)
    var d6 = dot(ac, cp)
    if d6 >= 0 and d5 <= d6:
        return c
    var vb = d5 * d2 - d1 * d6
    if vb <= 0 and d2 >= 0 and d6 <= 0:
        return a + ac * (d2 / (d2 - d6))
    var va = d3 * d6 - d5 * d4
    if va <= 0 and (d4 - d3) >= 0 and (d5 - d6) >= 0:
        return b + (c - b) * ((d4 - d3) / ((d4 - d3) + (d5 - d6)))
    var den = 1 / (va + vb + vc)
    return a + ab * (vb * den) + ac * (vc * den)


def _solid_angle(p: Vec3, a: Vec3, b: Vec3, c: Vec3) -> Float64:
    """Signed solid angle of triangle (a, b, c) seen from p (Van Oosterom &
    Strackee 1983), positive when the triangle winds CCW seen from p's side
    opposite its normal -- i.e. p inside a CCW-outward closed mesh sums to
    4 pi."""
    var x = a - p
    var y = b - p
    var z = c - p
    var lx = Float64(length(x))
    var ly = Float64(length(y))
    var lz = Float64(length(z))
    var num = Float64(dot(x, cross(y, z)))
    var den = lx * ly * lz + Float64(dot(x, y)) * lz + Float64(dot(y, z)) * lx + Float64(dot(z, x)) * ly
    return 2 * atan2(num, den)


def winding_number(verts: List[Real], idx: List[Int], p: Vec3) -> Float64:
    var w = Float64(0)
    for t in range(len(idx) // 3):
        w += _solid_angle(p, _v(verts, idx[3 * t]), _v(verts, idx[3 * t + 1]), _v(verts, idx[3 * t + 2]))
    return w / (4 * _PI)


struct SdfGrid(Movable, DistanceField3):
    var res: Int  # nodes per axis
    var origin: Vec3
    var cell: Real
    var values: List[Real]  # res^3, x fastest

    def __init__(out self, res: Int, origin: Vec3, cell: Real):
        self.res = res
        self.origin = origin
        self.cell = cell
        self.values = List[Real](capacity=res * res * res)
        for _ in range(res * res * res):
            self.values.append(0)

    @staticmethod
    def from_field[F: DistanceField3](f: F, res: Int, origin: Vec3, cell: Real) -> Self:
        """Sample any `DistanceField3` (an analytic `Sdf3`, another grid) at
        the `res`^3 nodes from `origin` with spacing `cell` (ROADMAP 17.52):
        the way an analytic or CSG field becomes a solver shape."""
        var g = Self(res, origin, cell)
        for k in range(res):
            for j in range(res):
                for i in range(res):
                    g.values[(k * res + j) * res + i] = f.distance(g.node(i, j, k))
        return g^

    def at(self, i: Int, j: Int, k: Int) -> Real:
        return self.values[(k * self.res + j) * self.res + i]

    def node(self, i: Int, j: Int, k: Int) -> Vec3:
        return self.origin + Vec3(Real(i), Real(j), Real(k), 0) * self.cell

    def _cell_of(self, p: Vec3) -> Tuple[Int, Int, Int, Vec3]:
        """Lower node of the cell holding p (clamped) and the fractional
        position inside it."""
        var q = (p - self.origin) / self.cell
        var hi = Real(self.res - 1)
        var ijk = Array[Int, 3](fill=0)
        var f = Vec3(0, 0, 0, 0)
        for a in range(3):
            var x = min(max(q[a], 0), hi)
            var ix = min(Int(floor(x)), self.res - 2) if self.res > 1 else 0
            ijk[a] = max(ix, 0)
            f[a] = x - Real(ijk[a])
        return (ijk[0], ijk[1], ijk[2], f)

    def distance(self, p: Vec3) -> Real:
        """Trilinear sample (clamped to the grid)."""
        if self.res == 1:
            return self.values[0]
        var c = self._cell_of(p)
        var i = c[0]
        var j = c[1]
        var k = c[2]
        var f = c[3]
        var c00 = self.at(i, j, k) * (1 - f[0]) + self.at(i + 1, j, k) * f[0]
        var c10 = self.at(i, j + 1, k) * (1 - f[0]) + self.at(i + 1, j + 1, k) * f[0]
        var c01 = self.at(i, j, k + 1) * (1 - f[0]) + self.at(i + 1, j, k + 1) * f[0]
        var c11 = self.at(i, j + 1, k + 1) * (1 - f[0]) + self.at(i + 1, j + 1, k + 1) * f[0]
        var c0 = c00 * (1 - f[1]) + c10 * f[1]
        var c1 = c01 * (1 - f[1]) + c11 * f[1]
        return c0 * (1 - f[2]) + c1 * f[2]

    def gradient(self, p: Vec3) -> Vec3:
        """Analytic gradient of the trilinear cell."""
        if self.res == 1:
            return Vec3(0, 0, 0, 0)
        var c = self._cell_of(p)
        var i = c[0]
        var j = c[1]
        var k = c[2]
        var f = c[3]
        var v = Array[Real, 8](fill=0)
        for n in range(8):
            v[n] = self.at(i + (n & 1), j + ((n >> 1) & 1), k + ((n >> 2) & 1))
        var gx = Real(0)
        var gy = Real(0)
        var gz = Real(0)
        for n in range(8):
            var bx = Real(n & 1)
            var by = Real((n >> 1) & 1)
            var bz = Real((n >> 2) & 1)
            var wx = f[0] if bx == 1 else 1 - f[0]
            var wy = f[1] if by == 1 else 1 - f[1]
            var wz = f[2] if bz == 1 else 1 - f[2]
            var sx = Real(1) if bx == 1 else Real(-1)
            var sy = Real(1) if by == 1 else Real(-1)
            var sz = Real(1) if bz == 1 else Real(-1)
            gx += v[n] * sx * wy * wz
            gy += v[n] * wx * sy * wz
            gz += v[n] * wx * wy * sz
        return Vec3(gx, gy, gz, 0) / self.cell


def bake_sdf_grid(verts: List[Real], idx: List[Int], res: Int, pad: Real) -> SdfGrid:
    """`res`^3 nodes spanning the mesh bounds grown by `pad` on every side
    (cubic cells; the longest axis sets the cell size). `res >= 1`."""
    var nv = len(verts) // 3
    var lo = Vec3(0, 0, 0, 0)
    var hi = Vec3(0, 0, 0, 0)
    if nv > 0:
        lo = _v(verts, 0)
        hi = lo
        for i in range(1, nv):
            var p = _v(verts, i)
            for a in range(3):
                lo[a] = min(lo[a], p[a])
                hi[a] = max(hi[a], p[a])
    lo = lo - Vec3(pad, pad, pad, 0)
    hi = hi + Vec3(pad, pad, pad, 0)
    var ext = hi - lo
    var span = max(ext[0], max(ext[1], ext[2]))
    var cell = span / Real(max(res - 1, 1))
    var g = SdfGrid(res, lo, cell)
    var nt = len(idx) // 3
    for k in range(res):
        for j in range(res):
            for i in range(res):
                var p = g.node(i, j, k)
                var best = Real(1e30)
                for t in range(nt):
                    var q = closest_on_triangle(p, _v(verts, idx[3 * t]), _v(verts, idx[3 * t + 1]), _v(verts, idx[3 * t + 2]))
                    best = min(best, length(q - p))
                if nt == 0:
                    best = 0
                var inside = nt > 0 and winding_number(verts, idx, p) > 0.5
                g.values[(k * res + j) * res + i] = -best if inside else best
    return g^


# ---------------------------------------------------------------- BVH bake
# ROADMAP 17.45: `bake_sdf_grid` scans every triangle per node (res^3 x T)
# and sums every triangle's solid angle for the sign. `bake_sdf_grid_bvh`
# finds the nearest triangle through a median-split BVH (exact: the same
# minimum over the same triangles, in any order), and on a closed mesh takes
# the sign from the angle-weighted pseudonormal of the face, edge or vertex
# holding the closest point; on open meshes (and points on the surface) it
# falls back to the winding number. Same values as the brute bake
# (`test_sdf_grid`).


struct _TriBvh(Movable):
    var lo: List[Vec3]
    var hi: List[Vec3]
    var left: List[Int]  # child index, or -1 for a leaf
    var right: List[Int]
    var first: List[Int]  # leaf: range into `order`
    var count: List[Int]
    var order: List[Int]

    def __init__(out self, verts: List[Real], idx: List[Int]):
        self.lo = List[Vec3]()
        self.hi = List[Vec3]()
        self.left = List[Int]()
        self.right = List[Int]()
        self.first = List[Int]()
        self.count = List[Int]()
        var nt = len(idx) // 3
        self.order = List[Int](capacity=nt)
        var cen = List[Vec3](capacity=nt)
        for t in range(nt):
            self.order.append(t)
            cen.append((_v(verts, idx[3 * t]) + _v(verts, idx[3 * t + 1]) + _v(verts, idx[3 * t + 2])) / 3)
        if nt > 0:
            _ = self._build(verts, idx, cen, 0, nt)

    def _build(mut self, verts: List[Real], idx: List[Int], cen: List[Vec3], a: Int, b: Int) -> Int:
        var node = len(self.lo)
        var lo = _v(verts, idx[3 * self.order[a]])
        var hi = lo
        for k in range(a, b):
            var t = self.order[k]
            for c in range(3):
                var p = _v(verts, idx[3 * t + c])
                for ax in range(3):
                    lo[ax] = min(lo[ax], p[ax])
                    hi[ax] = max(hi[ax], p[ax])
        self.lo.append(lo)
        self.hi.append(hi)
        self.left.append(-1)
        self.right.append(-1)
        self.first.append(a)
        self.count.append(b - a)
        if b - a <= 4:
            return node
        var ext = hi - lo
        var ax = 0
        if ext[1] > ext[ax]:
            ax = 1
        if ext[2] > ext[ax]:
            ax = 2
        # insertion-free median: sort the range by centroid on the axis
        var keys = List[Real](capacity=b - a)
        for k in range(a, b):
            keys.append(cen[self.order[k]][ax])
        for i in range(1, b - a):
            var j = i
            while j > 0 and keys[j] < keys[j - 1]:
                var tk = keys[j]
                keys[j] = keys[j - 1]
                keys[j - 1] = tk
                var to = self.order[a + j]
                self.order[a + j] = self.order[a + j - 1]
                self.order[a + j - 1] = to
                j -= 1
        var mid = (a + b) // 2
        var l = self._build(verts, idx, cen, a, mid)
        var r = self._build(verts, idx, cen, mid, b)
        self.left[node] = l
        self.right[node] = r
        return node

    def _box_d2(self, n: Int, p: Vec3) -> Real:
        var d2 = Real(0)
        for ax in range(3):
            var v = max(self.lo[n][ax] - p[ax], max(Real(0), p[ax] - self.hi[n][ax]))
            d2 += v * v
        return d2

    def nearest(self, verts: List[Real], idx: List[Int], p: Vec3) -> Tuple[Real, Int, Vec3]:
        """(distance, triangle, closest point)."""
        var best = Real(1e30)
        var best2 = Real(1e60)
        var bt = -1
        var bq = p
        if len(self.lo) == 0:
            return (best, bt, bq)
        var stack: List[Int] = [0]
        while len(stack) > 0:
            var n = stack.pop()
            if self._box_d2(n, p) > best2:
                continue
            if self.left[n] < 0:
                for k in range(self.first[n], self.first[n] + self.count[n]):
                    var t = self.order[k]
                    var q = closest_on_triangle(p, _v(verts, idx[3 * t]), _v(verts, idx[3 * t + 1]), _v(verts, idx[3 * t + 2]))
                    var d = length(q - p)
                    if d < best or (d == best and t < bt):
                        best = d
                        best2 = d * d
                        bt = t
                        bq = q
                continue
            var l = self.left[n]
            var r = self.right[n]
            # visit the nearer child first (pushed last)
            if self._box_d2(l, p) < self._box_d2(r, p):
                stack.append(r)
                stack.append(l)
            else:
                stack.append(l)
                stack.append(r)
        return (best, bt, bq)


struct _Pseudo(Movable):
    """Angle-weighted pseudonormals (Baerentzen and Aanaes 2005): for a
    closed, consistently oriented mesh, sign(dot(p - q, N)) with N the
    pseudonormal of the feature (face, edge or vertex) holding the closest
    point q is the inside / outside sign, exactly."""

    var face: List[Vec3]
    var vert: List[Vec3]
    var edge: Dict[Int, Int]  # a * nv + b (a < b) -> slot in `enorm`
    var enorm: List[Vec3]
    var nv: Int

    def __init__(out self, verts: List[Real], idx: List[Int]):
        self.nv = len(verts) // 3
        self.face = List[Vec3]()
        self.vert = List[Vec3](length=self.nv, fill=Vec3(0, 0, 0, 0))
        self.edge = Dict[Int, Int]()
        self.enorm = List[Vec3]()
        for t in range(len(idx) // 3):
            var ids: List[Int] = [idx[3 * t], idx[3 * t + 1], idx[3 * t + 2]]
            var a = _v(verts, ids[0])
            var b = _v(verts, ids[1])
            var c = _v(verts, ids[2])
            var n = cross(b - a, c - a)
            var ln = length(n)
            var fnrm = n / ln if ln > 0 else Vec3(0, 0, 0, 0)
            self.face.append(fnrm)
            var ps: List[Vec3] = [a, b, c]
            for k in range(3):
                var e1 = ps[(k + 1) % 3] - ps[k]
                var e2 = ps[(k + 2) % 3] - ps[k]
                var l1 = length(e1)
                var l2 = length(e2)
                if l1 > 0 and l2 > 0:
                    var ang = atan2(length(cross(e1, e2)), dot(e1, e2))
                    self.vert[ids[k]] = self.vert[ids[k]] + fnrm * ang
                var u = ids[k]
                var w = ids[(k + 1) % 3]
                var key = min(u, w) * self.nv + max(u, w)
                var slot = self.edge.get(key, -1)
                if slot < 0:
                    self.edge[key] = len(self.enorm)
                    self.enorm.append(fnrm)
                else:
                    self.enorm[slot] = self.enorm[slot] + fnrm

    def sign(self, verts: List[Real], idx: List[Int], t: Int, p: Vec3, q: Vec3) -> Int:
        """-1 inside, +1 outside, 0 undecided (p on the surface)."""
        var ids: List[Int] = [idx[3 * t], idx[3 * t + 1], idx[3 * t + 2]]
        var a = _v(verts, ids[0])
        var b = _v(verts, ids[1])
        var c = _v(verts, ids[2])
        var n = cross(b - a, c - a)
        var area2 = dot(n, n)
        if area2 <= 0:
            return 0
        var w = Array[Real, 3](fill=0)
        w[0] = dot(cross(b - q, c - q), n) / area2
        w[1] = dot(cross(c - q, a - q), n) / area2
        w[2] = 1 - w[0] - w[1]
        comptime EPS = Real(1e-5)
        var zeros = 0
        for k in range(3):
            if w[k] < EPS:
                zeros += 1
        var pn: Vec3
        match zeros:
            case 0:
                pn = self.face[t]
            case 1:
                # on the edge opposite the vertex whose weight vanished
                var k0 = 0
                for k in range(3):
                    if w[k] < EPS:
                        k0 = k
                var u = ids[(k0 + 1) % 3]
                var v2 = ids[(k0 + 2) % 3]
                pn = self.enorm[self.edge.get(min(u, v2) * self.nv + max(u, v2), 0)]
            case _:
                var kv = 0
                for k in range(3):
                    if w[k] >= EPS:
                        kv = k
                pn = self.vert[ids[kv]]
        var s = dot(p - q, pn)
        if s == 0:
            return 0
        return -1 if s < 0 else 1


def _weld_exact(verts: List[Real], idx: List[Int]) -> List[Int]:
    """Indices with bit-identical vertex positions merged (meshes built per
    triangle repeat their shared vertices; closedness and the pseudonormals
    need the shared ones to be one vertex)."""
    var nv = len(verts) // 3
    var canon = List[Int](length=nv, fill=-1)
    var seen = Dict[Int, Int]()  # hashed position -> first vertex with it
    for i in range(nv):
        var h = 1469598103934665603
        for a in range(3):
            var x = verts[3 * i + a]
            var bits = Int(Pointer(to=x).unsafe_bitcast[UInt32]()[])
            h = (h ^ bits) * 1099511628211
        var j = seen.get(h, -1)
        if j >= 0 and verts[3 * j] == verts[3 * i] and verts[3 * j + 1] == verts[3 * i + 1] and verts[3 * j + 2] == verts[3 * i + 2]:
            canon[i] = j
        else:
            if j < 0:
                seen[h] = i
            canon[i] = i
    var out = List[Int](capacity=len(idx))
    for i in idx:
        out.append(canon[i])
    return out^


def _is_closed(idx: List[Int]) -> Bool:
    """Every directed edge has its reverse in another triangle (a closed,
    consistently oriented mesh). An open mesh (a hemisphere) has a
    fractional winding number, where the face normal is not the sign."""
    var edges = Dict[Int, Int]()
    var nt = len(idx) // 3
    var nv = 0
    for i in idx:
        nv = max(nv, i + 1)
    for t in range(nt):
        for e in range(3):
            var a = idx[3 * t + e]
            var b = idx[3 * t + (e + 1) % 3]
            var key = a * nv + b
            edges[key] = edges.get(key, 0) + 1
    for t in range(nt):
        for e in range(3):
            var a = idx[3 * t + e]
            var b = idx[3 * t + (e + 1) % 3]
            if edges.get(b * nv + a, 0) != 1 or edges.get(a * nv + b, 0) != 1:
                return False
    return True


def bake_sdf_grid_bvh(verts: List[Real], idx: List[Int], res: Int, pad: Real) -> SdfGrid:
    """`bake_sdf_grid` through a triangle BVH (same grid, same values)."""
    var g = bake_sdf_grid(verts, List[Int](), res, pad)  # bounds and node layout only
    var nt = len(idx) // 3
    if nt == 0:
        return g^
    var bvh = _TriBvh(verts, idx)
    var welded = _weld_exact(verts, idx)
    var closed = _is_closed(welded)
    var pseudo = _Pseudo(verts, welded)
    for k in range(res):
        for j in range(res):
            for i in range(res):
                var p = g.node(i, j, k)
                var near = bvh.nearest(verts, idx, p)
                var sgn = pseudo.sign(verts, welded, near[1], p, near[2]) if closed else 0
                var inside: Bool
                if sgn != 0:
                    inside = sgn < 0
                else:
                    inside = winding_number(verts, idx, p) > 0.5
                g.values[(k * res + j) * res + i] = -near[0] if inside else near[0]
    return g^
