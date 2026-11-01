"""Collision-mesh baking: weld, repair, simplify, active edges (ROADMAP 17.45).

An artist's mesh is not a collision mesh. Exporters split vertices along UV
and normal seams, so faces that look joined share no edge; files carry
zero-area and duplicate triangles and the odd flipped face; a 100k-triangle
rock costs a crate landing on it 100k candidate tests' worth of BVH work.
`bake_collision_mesh` turns such a soup into what `collision.trimesh.TriMesh`
should be built from, at load time, and says what it did (`BakeReport`).

Stages, each usable alone:

  `weld`      merge vertices closer than `tol` (spatial hash, cell = tol, so a
              merge looks at the 27 neighbouring cells). Triangle order is
              kept; indices are remapped.
  `repair`    drop triangles whose vertices coincide after welding or are
              collinear (exact `orient`-style test on the cross product's
              squared length against zero), drop duplicates (same vertex set),
              make the winding consistent across every manifold edge (flood
              fill: a neighbour that walks a shared edge in the SAME direction
              is flipped), and count open edges (used once) and non-manifold
              edges (used more than twice).
  `simplify`  quadric-error edge collapse (Garland-Heckbert 1997): each vertex
              carries the sum of its faces' plane quadrics, an edge's cost is
              the quadric error of collapsing it to the better of its two
              endpoints, and edges are collapsed cheapest first in passes
              until the triangle budget is met or the next collapse would
              exceed `max_error` (in length units: sqrt of the quadric error).
              Boundary vertices never move (open edges stay where they are)
              and a collapse that would flip a face is refused.
  `active_edges`  per triangle, three flags: an edge is ACTIVE when it is a
              boundary or the two faces meet at more than `angle` (a real
              crease); inactive edges are flat seams between coplanar-ish
              faces, where contact generation must not invent an edge normal
              (`collision.contact_gen` uses this against "ghost" collisions).

Vertex storage is flat `List[Real]` stride 3, triangles flat `List[Int]`
stride 3 -- the same layout `TriMesh` takes.
"""

from std.math import sqrt, floor
from .trig import cos
from .vec import Real, Vec3, dot, cross, length


@fieldwise_init
struct BakeReport(Copyable, Movable):
    var verts_in: Int
    var verts_out: Int
    var tris_in: Int
    var tris_out: Int
    var welded: Int  # vertices merged away
    var degenerate_removed: Int
    var duplicate_removed: Int
    var flipped: Int  # triangles whose winding was reversed for consistency
    var open_edges: Int
    var nonmanifold_edges: Int
    var collapses: Int  # simplify: edge collapses performed
    var max_error: Float64  # simplify: largest collapse error accepted (length units)


struct BakedMesh(Movable):
    var verts: List[Real]
    var idx: List[Int]
    var active: List[UInt8]  # per triangle: bit k = edge (v_k, v_{k+1 mod 3}) is active
    var report: BakeReport

    def __init__(out self, var verts: List[Real], var idx: List[Int], var active: List[UInt8], var report: BakeReport):
        self.verts = verts^
        self.idx = idx^
        self.active = active^
        self.report = report^

    def ntri(self) -> Int:
        return len(self.idx) // 3


def _fill_bool(n: Int, v: Bool) -> List[Bool]:
    var out = List[Bool](capacity=n)
    for _ in range(n):
        out.append(v)
    return out^


def _fill_int(n: Int, v: Int) -> List[Int]:
    var out = List[Int](capacity=n)
    for _ in range(n):
        out.append(v)
    return out^


def _fill_u8(n: Int) -> List[UInt8]:
    var out = List[UInt8](capacity=n)
    for _ in range(n):
        out.append(0)
    return out^


def _fill_quadric(n: Int) -> List[_Quadric]:
    var out = List[_Quadric](capacity=n)
    for _ in range(n):
        out.append(_Quadric.zero())
    return out^


def _fill_lists(n: Int) -> List[List[Int]]:
    var out = List[List[Int]](capacity=n)
    for _ in range(n):
        out.append(List[Int]())
    return out^


def _argsort(costs: List[Float64]) -> List[Int]:
    """Indices ordering `costs` ascending, ties by index (stable merge sort),
    so the collapse order is deterministic."""
    var n = len(costs)
    var a = _fill_int(n, 0)
    for i in range(n):
        a[i] = i
    var tmp = _fill_int(n, 0)
    var width = 1
    while width < n:
        var lo = 0
        while lo < n:
            var mid = min(lo + width, n)
            var hi = min(lo + 2 * width, n)
            var i = lo
            var j = mid
            var k = lo
            while i < mid and j < hi:
                if costs[a[j]] < costs[a[i]]:
                    tmp[k] = a[j]
                    j += 1
                else:
                    tmp[k] = a[i]
                    i += 1
                k += 1
            while i < mid:
                tmp[k] = a[i]
                i += 1
                k += 1
            while j < hi:
                tmp[k] = a[j]
                j += 1
                k += 1
            lo += 2 * width
        for m in range(n):
            a[m] = tmp[m]
        width *= 2
    return a^


def _v(verts: List[Real], i: Int) -> Vec3:
    return Vec3(verts[3 * i], verts[3 * i + 1], verts[3 * i + 2], 0)


def _ekey(a: Int, b: Int) -> Int:
    """Undirected edge key (vertex counts stay below 2^31)."""
    return (min(a, b) << 32) | max(a, b)


# ---------------------------------------------------------------- weld


def weld(verts: List[Real], idx: List[Int], tol: Real) -> Tuple[List[Real], List[Int], Int]:
    """(welded vertices, remapped indices, vertices merged away). A vertex
    merges into the FIRST earlier vertex within `tol` (Euclidean), so the
    result does not depend on hash order. `tol <= 0` merges exact duplicates
    only."""
    var n = len(verts) // 3
    var cell = tol if tol > 0 else Real(1e-6)
    var grid = Dict[Int, List[Int]]()  # cell key -> representative vertex ids (in output numbering)
    var out = List[Real](capacity=len(verts))
    var remap = List[Int](capacity=n)
    var merged = 0

    def key(ix: Int, iy: Int, iz: Int) -> Int:
        # 21 bits per axis, offset so negative cells hash too
        return ((ix + (1 << 20)) << 42) | ((iy + (1 << 20)) << 21) | (iz + (1 << 20))

    for i in range(n):
        var p = _v(verts, i)
        var cx = Int(floor(p[0] / cell))
        var cy = Int(floor(p[1] / cell))
        var cz = Int(floor(p[2] / cell))
        var found = -1
        for dx in range(-1, 2):
            for dy in range(-1, 2):
                for dz in range(-1, 2):
                    var k = key(cx + dx, cy + dy, cz + dz)
                    if k in grid:
                        try:
                            ref lst = grid[k]
                            for j in range(len(lst)):
                                var q = _v(out, lst[j])
                                var d = q - p
                                if dot(d, d) <= tol * tol and (found < 0 or lst[j] < found):
                                    found = lst[j]
                        except:
                            pass
        if found >= 0:
            remap.append(found)
            merged += 1
        else:
            var id = len(out) // 3
            out.append(p[0])
            out.append(p[1])
            out.append(p[2])
            remap.append(id)
            var k0 = key(cx, cy, cz)
            if k0 not in grid:
                grid[k0] = List[Int]()
            try:
                grid[k0].append(id)
            except:
                pass
    var nidx = List[Int](capacity=len(idx))
    for t in range(len(idx)):
        nidx.append(remap[idx[t]])
    return (out^, nidx^, merged)


# --------------------------------------------------------------- repair


def _area2(verts: List[Real], a: Int, b: Int, c: Int) -> Real:
    """Squared length of the (unnormalised) triangle normal."""
    var n = cross(_v(verts, b) - _v(verts, a), _v(verts, c) - _v(verts, a))
    return dot(n, n)


@fieldwise_init
struct RepairResult(Copyable, Movable):
    var degenerate: Int
    var duplicate: Int
    var flipped: Int
    var open_edges: Int
    var nonmanifold_edges: Int


def repair(verts: List[Real], mut idx: List[Int]) -> RepairResult:
    """In place on `idx` (vertices untouched). See the module docstring."""
    var kept = List[Int](capacity=len(idx))
    var seen = Dict[Int, Bool]()
    var degenerate = 0
    var duplicate = 0
    for t in range(len(idx) // 3):
        var a = idx[3 * t]
        var b = idx[3 * t + 1]
        var c = idx[3 * t + 2]
        if a == b or b == c or a == c or _area2(verts, a, b, c) == 0:
            degenerate += 1
            continue
        # duplicate: same vertex SET, whatever the winding
        var lo = min(a, min(b, c))
        var hi = max(a, max(b, c))
        var mid = a + b + c - lo - hi
        var k = (lo << 42) | (mid << 21) | hi
        if k in seen:
            duplicate += 1
            continue
        seen[k] = True
        kept.append(a)
        kept.append(b)
        kept.append(c)
    idx = kept^
    var nt = len(idx) // 3

    # edge -> incident triangles
    var edges = Dict[Int, List[Int]]()
    for t in range(nt):
        for k in range(3):
            var e = _ekey(idx[3 * t + k], idx[3 * t + (k + 1) % 3])
            if e not in edges:
                edges[e] = List[Int]()
            try:
                edges[e].append(t)
            except:
                pass
    var open_edges = 0
    var nonmanifold = 0
    for e in edges.values():
        if len(e) == 1:
            open_edges += 1
        elif len(e) > 2:
            nonmanifold += 1

    # consistent winding by flood fill over manifold edges
    var visited = _fill_bool(nt, False)
    var flipped = 0
    for seed in range(nt):
        if visited[seed]:
            continue
        visited[seed] = True
        var stack = List[Int]()
        stack.append(seed)
        while len(stack) > 0:
            var t = stack.pop()
            for k in range(3):
                var a = idx[3 * t + k]
                var b = idx[3 * t + (k + 1) % 3]
                var nbrs = edges.get(_ekey(a, b), List[Int]())
                if len(nbrs) != 2:
                    continue
                var u = nbrs[0] if nbrs[0] != t else nbrs[1]
                if visited[u]:
                    continue
                # u is consistent when it walks the shared edge b -> a
                var same_dir = False
                for m in range(3):
                    if idx[3 * u + m] == a and idx[3 * u + (m + 1) % 3] == b:
                        same_dir = True
                if same_dir:
                    var tmp = idx[3 * u + 1]
                    idx[3 * u + 1] = idx[3 * u + 2]
                    idx[3 * u + 2] = tmp
                    flipped += 1
                visited[u] = True
                stack.append(u)
    return RepairResult(degenerate, duplicate, flipped, open_edges, nonmanifold)


# ------------------------------------------------------------- simplify


@fieldwise_init
struct _Quadric(Copyable, ImplicitlyCopyable, Movable):
    """Symmetric 4x4 plane quadric, upper triangle (10 terms in lanes 0..9)."""

    var q: SIMD[DType.float64, 16]

    @staticmethod
    def zero() -> Self:
        return Self(SIMD[DType.float64, 16](0))

    @staticmethod
    def plane(n: Vec3, d: Float64) -> Self:
        var a = Float64(n[0])
        var b = Float64(n[1])
        var c = Float64(n[2])
        var q = SIMD[DType.float64, 16](0)
        q[0] = a * a
        q[1] = a * b
        q[2] = a * c
        q[3] = a * d
        q[4] = b * b
        q[5] = b * c
        q[6] = b * d
        q[7] = c * c
        q[8] = c * d
        q[9] = d * d
        return Self(q)

    def add(mut self, o: Self):
        self.q += o.q

    def error(self, p: Vec3) -> Float64:
        var x = Float64(p[0])
        var y = Float64(p[1])
        var z = Float64(p[2])
        var q = self.q
        return (
            q[0] * x * x + 2 * q[1] * x * y + 2 * q[2] * x * z + 2 * q[3] * x
            + q[4] * y * y + 2 * q[5] * y * z + 2 * q[6] * y
            + q[7] * z * z + 2 * q[8] * z
            + q[9]
        )


def _face_plane(verts: List[Real], a: Int, b: Int, c: Int) -> Tuple[Vec3, Float64, Bool]:
    var n = cross(_v(verts, b) - _v(verts, a), _v(verts, c) - _v(verts, a))
    var l = length(n)
    if l == 0:
        return (Vec3(0, 0, 0, 0), Float64(0), False)
    n = n / l
    return (n, -Float64(dot(n, _v(verts, a))), True)


def simplify(
    mut verts: List[Real], mut idx: List[Int], target_tris: Int, max_error: Real
) -> Tuple[Int, Float64]:
    """Quadric-error edge collapse in place. Returns (collapses, largest
    accepted error in length units). Unreferenced vertices are dropped and
    indices compacted at the end; removed (collapsed-away) triangles are
    dropped too."""
    var nv = len(verts) // 3
    var nt = len(idx) // 3
    var alive = _fill_bool(nt, True)
    var vq = _fill_quadric(nv)
    for t in range(nt):
        var pl = _face_plane(verts, idx[3 * t], idx[3 * t + 1], idx[3 * t + 2])
        if pl[2]:
            var qq = _Quadric.plane(pl[0], pl[1])
            for k in range(3):
                vq[idx[3 * t + k]].add(qq)
    # boundary vertices are pinned
    var ecount = Dict[Int, Int]()
    for t in range(nt):
        for k in range(3):
            var e = _ekey(idx[3 * t + k], idx[3 * t + (k + 1) % 3])
            ecount[e] = ecount.get(e, 0) + 1
    var pinned = _fill_bool(nv, False)
    for t in range(nt):
        for k in range(3):
            var a = idx[3 * t + k]
            var b = idx[3 * t + (k + 1) % 3]
            if ecount.get(_ekey(a, b), 0) != 2:
                pinned[a] = True
                pinned[b] = True
    # vertex -> incident triangles
    var vt = _fill_lists(nv)
    for t in range(nt):
        for k in range(3):
            vt[idx[3 * t + k]].append(t)

    var live = nt
    var collapses = 0
    var worst = Float64(0)
    var limit = Float64(max_error) * Float64(max_error)
    while live > target_tris:
        # candidate edges with their cost and the surviving vertex
        var cand_a = List[Int]()
        var cand_b = List[Int]()  # b is removed, a survives at a's or b's position
        var cand_pos = List[Int]()  # 0: keep a's position, 1: move a to b's position
        var cand_cost = List[Float64]()
        var seen = Dict[Int, Bool]()
        for t in range(nt):
            if not alive[t]:
                continue
            for k in range(3):
                var a = idx[3 * t + k]
                var b = idx[3 * t + (k + 1) % 3]
                var e = _ekey(a, b)
                if e in seen:
                    continue
                seen[e] = True
                if pinned[a] and pinned[b]:
                    continue
                var q = vq[a]
                q.add(vq[b])
                var pa = _v(verts, a)
                var pb = _v(verts, b)
                var ca = q.error(pa) if not pinned[b] else Float64(1e300)
                var cb = q.error(pb) if not pinned[a] else Float64(1e300)
                var cost = min(ca, cb)
                if cost > limit:
                    continue
                cand_a.append(a)
                cand_b.append(b)
                cand_pos.append(0 if ca <= cb else 1)
                cand_cost.append(max(cost, 0))
        if len(cand_a) == 0:
            break
        var order = _argsort(cand_cost)
        var touched = _fill_bool(nv, False)
        var did = 0
        for ki in range(len(order)):
            if live <= target_tris:
                break
            var c = order[ki]
            var a = cand_a[c]
            var b = cand_b[c]
            if touched[a] or touched[b]:
                continue
            # surviving vertex s, removed r, final position p
            var s = a
            var r = b
            var p = _v(verts, a) if cand_pos[c] == 0 else _v(verts, b)
            if pinned[a]:
                s = a
                r = b
                p = _v(verts, a)
            elif pinned[b]:
                s = b
                r = a
                p = _v(verts, b)
            # refuse collapses that flip any surviving face around s or r
            var ok = True
            for which in range(2):
                var w = s if which == 0 else r
                for ti in range(len(vt[w])):
                    var t = vt[w][ti]
                    if not alive[t]:
                        continue
                    var has_s = False
                    var has_r = False
                    for k in range(3):
                        if idx[3 * t + k] == s:
                            has_s = True
                        if idx[3 * t + k] == r:
                            has_r = True
                    if has_s and has_r:
                        continue  # this face disappears
                    var before = cross(_v(verts, idx[3 * t + 1]) - _v(verts, idx[3 * t]), _v(verts, idx[3 * t + 2]) - _v(verts, idx[3 * t]))
                    var pts = Array[Vec3, 3](fill=Vec3(0, 0, 0, 0))
                    for k in range(3):
                        var vk = idx[3 * t + k]
                        pts[k] = p if (vk == s or vk == r) else _v(verts, vk)
                    var after = cross(pts[1] - pts[0], pts[2] - pts[0])
                    if dot(before, after) <= 0:
                        ok = False
            if not ok:
                continue
            # collapse r into s at p
            verts[3 * s] = p[0]
            verts[3 * s + 1] = p[1]
            verts[3 * s + 2] = p[2]
            var qr = vq[r]
            vq[s].add(qr)
            for ti in range(len(vt[r])):
                var t = vt[r][ti]
                if not alive[t]:
                    continue
                var has_s = False
                for k in range(3):
                    if idx[3 * t + k] == s:
                        has_s = True
                if has_s:
                    alive[t] = False
                    live -= 1
                else:
                    for k in range(3):
                        if idx[3 * t + k] == r:
                            idx[3 * t + k] = s
                    vt[s].append(t)
            touched[s] = True
            touched[r] = True
            for ti in range(len(vt[s])):
                var t = vt[s][ti]
                for k in range(3):
                    touched[idx[3 * t + k]] = True
            collapses += 1
            did += 1
            worst = max(worst, cand_cost[c])
        if did == 0:
            break
    # compact
    var used = _fill_int(nv, -1)
    var nverts = List[Real]()
    var nidx = List[Int]()
    for t in range(nt):
        if not alive[t]:
            continue
        for k in range(3):
            var o = idx[3 * t + k]
            if used[o] < 0:
                used[o] = len(nverts) // 3
                nverts.append(verts[3 * o])
                nverts.append(verts[3 * o + 1])
                nverts.append(verts[3 * o + 2])
            nidx.append(used[o])
    verts = nverts^
    idx = nidx^
    return (collapses, sqrt(worst))


# --------------------------------------------------------- active edges


def active_edges(verts: List[Real], idx: List[Int], angle: Real) -> List[UInt8]:
    """Per triangle, bit k set when edge (v_k, v_{k+1}) is active: an open or
    non-manifold edge, or a manifold edge whose two face normals differ by
    more than `angle` radians."""
    var nt = len(idx) // 3
    var cos_t = Float64(cos_approx(angle))
    var edges = Dict[Int, List[Int]]()
    for t in range(nt):
        for k in range(3):
            var e = _ekey(idx[3 * t + k], idx[3 * t + (k + 1) % 3])
            if e not in edges:
                edges[e] = List[Int]()
            try:
                edges[e].append(t)
            except:
                pass
    var nrm = List[Vec3](capacity=nt)
    for t in range(nt):
        var pl = _face_plane(verts, idx[3 * t], idx[3 * t + 1], idx[3 * t + 2])
        nrm.append(pl[0])
    var out = _fill_u8(nt)
    for t in range(nt):
        var bits = UInt8(0)
        for k in range(3):
            var nb = edges.get(_ekey(idx[3 * t + k], idx[3 * t + (k + 1) % 3]), List[Int]())
            var active = True
            if len(nb) == 2:
                var u = nb[0] if nb[0] != t else nb[1]
                active = Float64(dot(nrm[t], nrm[u])) < cos_t
            if active:
                bits |= UInt8(1) << UInt8(k)
        out[t] = bits
    return out^


def cos_approx(x: Real) -> Real:
    return cos(x)


# ----------------------------------------------------------------- bake


def bake_collision_mesh(
    verts: List[Real], idx: List[Int], weld_tol: Real, target_tris: Int = -1,
    max_error: Real = 0, active_angle: Real = 0.0872664626,  # 5 degrees
) -> BakedMesh:
    """Weld -> repair -> (simplify when `target_tris >= 0`) -> repair ->
    active edges, with a report of every stage."""
    var w = weld(verts, idx, weld_tol)
    var v = w[0].copy()
    var ix = w[1].copy()
    var r1 = repair(v, ix)
    var collapses = 0
    var err = Float64(0)
    var r2 = r1.copy()
    if target_tris >= 0:
        var sres = simplify(v, ix, target_tris, max_error)
        collapses = sres[0]
        err = sres[1]
        r2 = repair(v, ix)
    var act = active_edges(v, ix, active_angle)
    var rep = BakeReport(
        len(verts) // 3, len(v) // 3, len(idx) // 3, len(ix) // 3, w[2],
        r1.degenerate + (r2.degenerate if target_tris >= 0 else 0),
        r1.duplicate + (r2.duplicate if target_tris >= 0 else 0),
        r1.flipped + (r2.flipped if target_tris >= 0 else 0),
        r2.open_edges, r2.nonmanifold_edges, collapses, err,
    )
    return BakedMesh(v^, ix^, act^, rep^)
