"""Contact manifolds: multi-point contact geometry for angular dynamics.

`Contact[dim]` (narrowphase.mojo) answers hit/normal/depth — enough for linear
response but not for torque: rotational dynamics needs to know WHERE the bodies
touch. `ContactManifold[dim]` carries up to four contact points (positions plus
per-point depths) sharing one normal, and `summary()` collapses back to a
`Contact` so parity against the single-point path stays checkable.

`ManifoldNarrowPhase` is the swap seam, mirroring `NarrowPhase` (per-proxy
registry, `test_manifold(a, b)`). First implementation:

  * `AABBManifoldNarrowPhase[dim]` — for axis-aligned boxes the contact patch
    is the overlap region's slab on the min-penetration axis: its corners over
    the other axes, at the slab centre on the contact axis. 2 points in 2D,
    4 points in 3D; every point carries the same axis overlap as depth.
  * `SATManifoldNarrowPhase` — 2D convex polygons: SAT axis + reference/
    incident edge clipping (`geometry/clip.mojo`), 1-2 points with per-point
    depths (2 for face-face, 1 for corner-face).
  * `OBBManifoldNarrowPhase` — 2D oriented boxes: the analytic 4-axis OBB test
    for the axis, then the same clipping over `to_polygon()`.
  * `GjkManifoldNarrowPhase` — 3D convex shapes: GJK + witness-tracking EPA
    (`geometry/epa.mojo`), one contact point at the witness midpoint.
  * `box_box_manifold` — ROTATED 3D boxes: 15-axis SAT (6 faces + 9 edge
    crosses, faces preferred within 5% to avoid axis flip jitter), then
    reference-face / incident-face quad clipping for face contacts (up to 4
    deepest points, per-point depth) or closest-point-of-edges for edge-edge.
    This is what gives tilted boxes their restoring torque — an axis-aligned
    manifold cannot (see ROADMAP 2.1 diagnosis).
"""

from std.math import sqrt
from geometry.vec import WorldType, Real, Vec2, Vec3, dot, PadW, cross
from geometry.aabb import AABB
from geometry.shape import Polygon
from geometry.quickhull import convex_hull_2d
from geometry.sat import SATResult, sat_collide
from geometry.obb import OBB, obb_collide
from .clip import best_edge, clip_manifold
from geometry.gjk import ConvexPoly
from geometry.epa import epa_witness3
from .narrowphase import Contact


struct ContactManifold[dim: Int](Copyable, ImplicitlyCopyable, Movable):
    comptime MAX: Int = 4
    var hit: Bool
    var normal: SIMD[WorldType, PadW[Self.dim]]  # points from a -> b
    var count: Int
    var points: Array[SIMD[WorldType, PadW[Self.dim]], Self.MAX]
    var depths: Array[Real, Self.MAX]

    def __init__(out self):
        self.hit = False
        self.normal = SIMD[WorldType, PadW[Self.dim]](0)
        self.count = 0
        self.points = Array[SIMD[WorldType, PadW[Self.dim]], Self.MAX](
            fill=SIMD[WorldType, PadW[Self.dim]](0)
        )
        self.depths = Array[Real, Self.MAX](fill=0)

    def __init__(out self, *, copy: Self):
        """Explicit copy: `Array` stopped being `ImplicitlyCopyable` in
        Mojo 1.0, so a struct holding one no longer gets a synthesised one."""
        self.hit = copy.hit
        self.normal = copy.normal
        self.count = copy.count
        self.points = copy.points.copy()
        self.depths = copy.depths.copy()

    @staticmethod
    def miss() -> Self:
        return Self()

    @staticmethod
    def hit_along(normal: SIMD[WorldType, PadW[Self.dim]]) -> Self:
        var m = Self()
        m.hit = True
        m.normal = normal
        return m

    def add(mut self, p: SIMD[WorldType, PadW[Self.dim]], depth: Real):
        if self.count < Self.MAX:
            self.points[self.count] = p
            self.depths[self.count] = depth
            self.count += 1

    def max_depth(self) -> Real:
        var d = Real(0)
        for i in range(self.count):
            if self.depths[i] > d:
                d = self.depths[i]
        return d

    def summary(self) -> Contact[Self.dim]:
        """Collapse to the single-point contract (parity bridge)."""
        return Contact[Self.dim](self.hit, self.normal, self.max_depth())


trait ManifoldNarrowPhase(Movable, Deinitable):
    comptime dim: Int
    def test_manifold(self, a: Int, b: Int) -> ContactManifold[Self.dim]: ...


struct AABBManifoldNarrowPhase[D: Int](ManifoldNarrowPhase):
    comptime dim: Int = Self.D
    var boxes: List[AABB[Self.D]]

    def __init__(out self):
        self.boxes = List[AABB[Self.D]]()

    def add(mut self, box: AABB[Self.D]) -> Int:
        self.boxes.append(box)
        return len(self.boxes) - 1

    def test_manifold(self, a: Int, b: Int) -> ContactManifold[Self.D]:
        var ba = self.boxes[a]
        var bb = self.boxes[b]
        # Min-penetration axis, same rule as AABBNarrowPhase.test.
        var lo = SIMD[WorldType, PadW[Self.D]](0)
        var hi = SIMD[WorldType, PadW[Self.D]](0)
        var best_depth = Real(1.0e30)
        var best_axis = 0
        comptime for k in range(Self.D):
            var l = max(ba.min[k], bb.min[k])
            var h = min(ba.max[k], bb.max[k])
            if h - l <= 0:
                return ContactManifold[Self.D].miss()
            lo[k] = l
            hi[k] = h
            if h - l < best_depth:
                best_depth = h - l
                best_axis = k
        var n = SIMD[WorldType, PadW[Self.D]](0)
        var dir = bb.center()[best_axis] - ba.center()[best_axis]
        n[best_axis] = 1 if dir >= 0 else -1
        var m = ContactManifold[Self.D].hit_along(n)
        # Contact patch = the overlap slab's corners over the non-contact axes,
        # at the slab centre on the contact axis (2 points in 2D, 4 in 3D).
        var mid = (lo[best_axis] + hi[best_axis]) * Real(0.5)
        for mask in range(1 << (Self.D - 1)):
            var p = SIMD[WorldType, PadW[Self.D]](0)
            var bit = 0
            comptime for k in range(Self.D):
                if k == best_axis:
                    p[k] = mid
                else:
                    p[k] = hi[k] if ((mask >> bit) & 1) == 1 else lo[k]
                    bit += 1
            m.add(p, best_depth)
        return m


def _clipped_manifold(pa: Polygon, pb: Polygon, r: SATResult) -> ContactManifold[2]:
    """Manifold from an already-computed SAT result via edge clipping."""
    if not r.hit:
        return ContactManifold[2].miss()
    var m = ContactManifold[2].hit_along(r.normal)
    var pts = List[Vec2]()
    var ds = List[Real]()
    if clip_manifold(pa, pb, r.normal, pts, ds):
        for i in range(len(pts)):
            m.add(pts[i], ds[i])
    else:
        # Degenerate clip (barely touching): incident support point, SAT depth.
        m.add(best_edge(pb, -r.normal).maxv, r.depth)
    return m


struct SATManifoldNarrowPhase(ManifoldNarrowPhase):
    comptime dim: Int = 2
    var polys: List[Polygon]

    def __init__(out self):
        self.polys = List[Polygon]()

    def add(mut self, var p: Polygon) -> Int:
        self.polys.append(p^)
        return len(self.polys) - 1

    def add_cloud(mut self, points: List[Vec2]) raises -> Int:
        """A shape given as an unordered 2D point cloud; see the same method on
        `SATNarrowPhase`. Face clipping needs the CCW winding that
        `convex_hull_2d` establishes even more than the boolean test does."""
        return self.add(convex_hull_2d(points))

    def test_manifold(self, a: Int, b: Int) -> ContactManifold[2]:
        return _clipped_manifold(
            self.polys[a], self.polys[b], sat_collide(self.polys[a], self.polys[b])
        )


struct OBBManifoldNarrowPhase(ManifoldNarrowPhase):
    comptime dim: Int = 2
    var boxes: List[OBB]

    def __init__(out self):
        self.boxes = List[OBB]()

    def add(mut self, box: OBB) -> Int:
        self.boxes.append(box)
        return len(self.boxes) - 1

    def test_manifold(self, a: Int, b: Int) -> ContactManifold[2]:
        # Analytic 4-axis test for the normal, polygon clipping for the points.
        return _clipped_manifold(
            self.boxes[a].to_polygon(),
            self.boxes[b].to_polygon(),
            obb_collide(self.boxes[a], self.boxes[b]),
        )


struct GjkManifoldNarrowPhase(ManifoldNarrowPhase):
    comptime dim: Int = 3
    var shapes: List[ConvexPoly[3]]

    def __init__(out self):
        self.shapes = List[ConvexPoly[3]]()

    def add(mut self, var s: ConvexPoly[3]) -> Int:
        self.shapes.append(s^)
        return len(self.shapes) - 1

    def test_manifold(self, a: Int, b: Int) -> ContactManifold[3]:
        var w = epa_witness3(self.shapes[a], self.shapes[b])
        if not w.hit:
            return ContactManifold[3].miss()
        var m = ContactManifold[3].hit_along(w.normal)
        m.add((w.point_a + w.point_b) * Real(0.5), w.depth)
        return m


# --- rotated 3D box-box manifold (SAT + face clipping) -----------------------


comptime Axes3 = Array[Vec3, 3]


def _proj_radius(ax: Axes3, h: Vec3, l: Vec3) -> Real:
    """Half-width of an oriented box projected onto unit axis `l`."""
    return (
        h[0] * abs(dot(ax[0], l))
        + h[1] * abs(dot(ax[1], l))
        + h[2] * abs(dot(ax[2], l))
    )


def _face_verts(c: Vec3, ax: Axes3, h: Vec3, j: Int, sign: Real) -> Array[Vec3, 4]:
    """The 4 corners of face `j` (normal ax[j]*sign) of an oriented box."""
    var u = (j + 1) % 3
    var v = (j + 2) % 3
    var fc = c + ax[j] * (h[j] * sign)
    var eu = ax[u] * h[u]
    var ev = ax[v] * h[v]
    var out = Array[Vec3, 4](fill=fc)
    out[0] = fc + eu + ev
    out[1] = fc - eu + ev
    out[2] = fc - eu - ev
    out[3] = fc + eu - ev
    return out^


def _clip_poly_plane(
    pts: Array[Vec3, 8],
    n_in: Int,
    axis: Vec3,
    offset: Real,
) -> Tuple[Array[Vec3, 8], Int]:
    """Keep the part of the polygon with dot(axis, p) <= offset."""
    var out = Array[Vec3, 8](fill=Vec3(0, 0, 0, 0))
    var n_out = 0
    for i in range(n_in):
        var p0 = pts[i]
        var p1 = pts[(i + 1) % n_in]
        var d0 = dot(axis, p0) - offset
        var d1 = dot(axis, p1) - offset
        if d0 <= 0:
            if n_out < 8:
                out[n_out] = p0
                n_out += 1
        if d0 * d1 < 0:
            var t = d0 / (d0 - d1)
            if n_out < 8:
                out[n_out] = p0 + (p1 - p0) * t
                n_out += 1
    return (out^, n_out)


def spread4_core(pts: Span[Vec3, _], dep: Span[Real, _], c: Int, n: Vec3) -> Tuple[Array[Int, 4], Int]:
    """Indices of at most 4 contact points (ROADMAP 17.52). Up to 4: all, in
    order. More (a clipped face with many vertices, e.g. a tessellated
    cylinder's cap, or two boxes face to face with a slight yaw): the
    deepest (of near-equal depths, the one farthest from the centroid),
    the farthest from it, the farthest from the line through
    those two, then the largest triangle on the other side of that line --
    a spread patch. Keeping the first four in polygon order put all four on
    one arc of a 32-gon and the cylinder tipped over; keeping the four
    deepest of a box pair's 8 clipped points (depths equal to 1e-7) could
    keep two points at one corner and none at another, and a resting
    3-box stack kicked.

    Works on spans of the first `c` points and returns at most 4 indices in
    a fixed array (no allocation: the box-box path calls it for every
    manifold, ROADMAP 17.79)."""
    var out = Array[Int, 4](fill=-1)
    var k = 0
    if c <= 4:
        for i in range(c):
            out[i] = i
        return (out^, c)
    # the deepest point -- or, among points within a tolerance of the
    # deepest (a flat contact, depths equal to round-off), the one farthest
    # from the centroid: an incident edge nearly parallel to a clip plane
    # crosses it anywhere along its length, and starting from that mid-edge
    # point left a corner of a resting box unsupported. The tolerance is
    # relative to the patch (2.8e-5 of its radius: 1e-5 for a 0.25 m box
    # face); an absolute 1e-5 tied two points at one scale and not at 16x,
    # which reordered the manifold (ROADMAP 17.75 scale residual).
    var dmax = dep[0]
    var cen = pts[0]
    for i in range(1, c):
        dmax = max(dmax, dep[i])
        cen = cen + pts[i]
    cen = cen / Real(c)
    var rad2 = Real(0)
    for i in range(c):
        var dv = pts[i] - cen
        rad2 = max(rad2, dot(dv, dv))
    var tie = Real(2.8e-5) * sqrt(rad2)
    var i0 = -1
    var far = Real(-1)
    for i in range(c):
        if dep[i] >= dmax - tie:
            var dv = pts[i] - cen
            var f2 = dot(dv, dv)
            if f2 > far:
                far = f2
                i0 = i
    var i1 = -1
    var best = Real(-1)
    for i in range(c):
        var d = pts[i] - pts[i0]
        var l2 = dot(d, d)
        if l2 > best:
            best = l2
            i1 = i
    var e = pts[i1] - pts[i0]
    var i2 = -1
    var s2 = Real(0)
    best = Real(-1)
    for i in range(c):
        var a = dot(cross(e, pts[i] - pts[i0]), n)
        if abs(a) > best:
            best = abs(a)
            i2 = i
            s2 = a
    var i3 = -1
    best = Real(-1)
    for i in range(c):
        if i == i0 or i == i1 or i == i2:
            continue
        var a = dot(cross(e, pts[i] - pts[i0]), n)
        var score = -a if s2 >= 0 else a  # other side of the i0-i1 line
        if score > best:
            best = score
            i3 = i
    out[k] = i0
    k += 1
    out[k] = i1
    k += 1
    if i2 != i0 and i2 != i1:
        out[k] = i2
        k += 1
    if i3 >= 0:
        out[k] = i3
        k += 1
    return (out^, k)


def spread4(pts: List[Vec3], dep: List[Real], n: Vec3) -> List[Int]:
    """`spread4_core` over lists (hull and mesh callers, any number of
    points)."""
    var r = spread4_core(Span(pts), Span(dep), len(pts), n)
    var out = List[Int](capacity=r[1])
    for k in range(r[1]):
        out.append(r[0][k])
    return out^


def _face_manifold(
    rc: Vec3,
    rax: Axes3,
    rh: Vec3,
    ic: Vec3,
    iax: Axes3,
    ih: Vec3,
    j: Int,
    sign: Real,
    n_out: Vec3,
    spec: Real = 0,
) -> ContactManifold[3]:
    """Clip the incident box's most anti-parallel face against reference face
    `j` of the reference box; `n_out` is the manifold normal (a -> b).

    `spec` > 0 (speculative margin, `box_box_manifold`): the incident face is
    the real one, so the points lie on the body; the reference side planes
    are moved out by `spec`, and each depth is the real separation plus
    `2 spec` (the depth the two boxes inflated by `spec` would report)."""
    var nf = rax[j] * sign  # reference face outward normal (toward incident)
    # incident face: axis of the incident box most anti-parallel to nf
    var best_k = 0
    var best_d = Real(1e30)
    var best_sign = Real(1)
    for k in range(3):
        var d = dot(iax[k], nf)
        if d < best_d:
            best_d = d
            best_k = k
            best_sign = 1
        if -d < best_d:
            best_d = -d
            best_k = k
            best_sign = -1
    var quad4 = _face_verts(ic, iax, ih, best_k, best_sign)
    var pts = Array[Vec3, 8](fill=Vec3(0, 0, 0, 0))
    for i in range(4):
        pts[i] = quad4[i]
    var count = 4
    # clip against the reference face's 4 side planes
    var u = (j + 1) % 3
    var v = (j + 2) % 3
    var r = _clip_poly_plane(pts, count, rax[u], dot(rax[u], rc) + rh[u] + spec)
    pts = r[0].copy()
    count = r[1]
    r = _clip_poly_plane(pts, count, -rax[u], -(dot(rax[u], rc) - rh[u] - spec))
    pts = r[0].copy()
    count = r[1]
    r = _clip_poly_plane(pts, count, rax[v], dot(rax[v], rc) + rh[v] + spec)
    pts = r[0].copy()
    count = r[1]
    r = _clip_poly_plane(pts, count, -rax[v], -(dot(rax[v], rc) - rh[v] - spec))
    pts = r[0].copy()
    count = r[1]
    if count == 0:
        return ContactManifold[3].miss()
    # keep points behind the reference face; depth = distance behind
    var face_off = dot(nf, rc + rax[j] * (rh[j] * sign))
    var m = ContactManifold[3].hit_along(n_out)
    # the points behind the face (depth > 4e-6 of the reference box's half
    # extent along the normal: 1e-6 for a 0.25 m box; relative so a scene
    # scaled by 2^k keeps the same points, ROADMAP 17.75), then a spread
    # four of them
    # (fixed arrays: at most 8 clipped points, no allocation per manifold;
    # the List versions were ~2400 allocations per step for 200 boxes,
    # ROADMAP 17.79)
    var cand = Array[Vec3, 8](fill=Vec3(0, 0, 0, 0))
    var cdep = Array[Real, 8](fill=0)
    var nc = 0
    var behind = Real(4e-6) * rh[j]
    for i in range(count):
        var dd = face_off - dot(nf, pts[i]) + 2 * spec  # >0 means behind the face
        if dd > behind:
            cand[nc] = pts[i]
            cdep[nc] = dd
            nc += 1
    var picked = spread4_core(Span(cand), Span(cdep), nc, nf)
    var pick = picked[0].copy()
    var np = picked[1]
    if nc <= 4:
        # unchanged order for up to four: deepest first, as before
        np = 0
        var used = Array[Bool, 8](fill=False)
        for _ in range(nc):
            var bi = -1
            var bd = Real(-1)
            for i in range(nc):
                if not used[i] and cdep[i] > bd:
                    bd = cdep[i]
                    bi = i
            used[bi] = True
            pick[np] = bi
            np += 1
    for k in range(np):
        m.add(cand[pick[k]], cdep[pick[k]])
    if m.count == 0:
        return ContactManifold[3].miss()
    return m


def box_box_manifold(
    ca: Vec3,
    axa: Axes3,
    ha: Vec3,
    cb: Vec3,
    axb: Axes3,
    hb: Vec3,
    spec: Real = 0,
) -> ContactManifold[3]:
    """Contact manifold between two ORIENTED 3D boxes (world-frame axes).

    `spec` >= 0 is the speculative inflation of each box's half extents
    (`contact_gen.try_pair`: half the pair margin). The separating-axis test
    and the depths are those of the inflated boxes, but the points come from
    the real boxes: inflating the extents also moved the points sideways by
    `spec`, so a 0.1 m box at 50 m/s (margin 0.85 m) got contact points
    0.527 m from its centre, and a head-on hit left it spinning at 28 rad/s
    (ROADMAP 17.19, 2026-11-25)."""
    var hai = ha + Vec3(spec, spec, spec, 0)
    var hbi = hb + Vec3(spec, spec, spec, 0)
    var t = cb - ca
    var best_overlap = Real(1e30)
    var best_axis = Vec3(0, 0, 0, 0)
    var best_is_a = True
    var best_j = 0
    # 6 face axes (preferred), then 9 edge-cross axes with a 5% penalty.
    for j in range(3):
        var l = axa[j]
        var overlap = _proj_radius(axa, hai, l) + _proj_radius(axb, hbi, l) - abs(
            dot(t, l)
        )
        if overlap < 0:
            return ContactManifold[3].miss()
        if overlap < best_overlap:
            best_overlap = overlap
            best_axis = l
            best_is_a = True
            best_j = j
    for j in range(3):
        var l = axb[j]
        var overlap = _proj_radius(axa, hai, l) + _proj_radius(axb, hbi, l) - abs(
            dot(t, l)
        )
        if overlap < 0:
            return ContactManifold[3].miss()
        if overlap < best_overlap:
            best_overlap = overlap
            best_axis = l
            best_is_a = False
            best_j = j
    var best_edge_axis = Vec3(0, 0, 0, 0)
    var best_edge_overlap = Real(1e30)
    for ja in range(3):
        for jb in range(3):
            var l = cross(axa[ja], axb[jb])
            var ll = dot(l, l)
            if ll < Real(1e-10):
                continue  # near-parallel edges: face axes cover this
            l = l / sqrt(ll)
            var overlap = _proj_radius(axa, hai, l) + _proj_radius(
                axb, hbi, l
            ) - abs(dot(t, l))
            if overlap < 0:
                return ContactManifold[3].miss()
            if overlap < best_edge_overlap:
                best_edge_overlap = overlap
                best_edge_axis = l
    if best_edge_overlap < best_overlap * Real(0.95):
        # Edge-edge contact: single point midway between the closest edges.
        var n = best_edge_axis
        if dot(t, n) < 0:
            n = -n
        # supporting corners along +-n, then closest points of the two edges
        var pa = ca
        for j in range(3):
            var d = dot(axa[j], n)
            pa = pa + axa[j] * (ha[j] * (Real(1) if d > 0 else Real(-1)))
        var pb = cb
        for j in range(3):
            var d = dot(axb[j], n)
            pb = pb + axb[j] * (hb[j] * (Real(-1) if d > 0 else Real(1)))
        var m = ContactManifold[3].hit_along(n)
        m.add((pa + pb) * Real(0.5), best_edge_overlap)
        return m
    # Face contact: clip incident against reference.
    if best_is_a:
        var sign = Real(1) if dot(t, best_axis) >= 0 else Real(-1)
        var n = best_axis * sign  # a -> b
        return _face_manifold(ca, axa, ha, cb, axb, hb, best_j, sign, n, spec)
    else:
        # reference face on B; its outward normal points toward A (= -n).
        var sign = Real(1) if dot(-t, best_axis) >= 0 else Real(-1)
        var n = best_axis * (-sign)  # a -> b
        return _face_manifold(cb, axb, hb, ca, axa, ha, best_j, sign, n, spec)


# --- sphere / capsule manifolds ----------------------------------------------


def sphere_sphere_manifold(
    ca: Vec3, ra: Real, cb: Vec3, rb: Real
) -> ContactManifold[3]:
    """One-point manifold between two spheres (normal a -> b)."""
    var d = cb - ca
    var d2 = dot(d, d)
    var rsum = ra + rb
    if d2 > rsum * rsum:
        return ContactManifold[3].miss()
    var dist = sqrt(max(d2, Real(1e-12)))
    var n = d / dist if dist > 1e-6 else Vec3(0, 1, 0, 0)
    var m = ContactManifold[3].hit_along(n)
    m.add(ca + n * (ra - (rsum - dist) * 0.5), rsum - dist)
    return m


def _box_closest_local(lp: Vec3, h: Vec3) -> Vec3:
    return Vec3(
        min(max(lp[0], -h[0]), h[0]),
        min(max(lp[1], -h[1]), h[1]),
        min(max(lp[2], -h[2]), h[2]),
        0,
    )


def _box_local_world(c: Vec3, ax: Axes3, lp: Vec3) -> Vec3:
    return c + ax[0] * lp[0] + ax[1] * lp[1] + ax[2] * lp[2]


def _box_to_local(c: Vec3, ax: Axes3, p: Vec3) -> Vec3:
    var d = p - c
    return Vec3(dot(d, ax[0]), dot(d, ax[1]), dot(d, ax[2]), 0)


def sphere_box_manifold(
    cs: Vec3, r: Real, cb: Vec3, axb: Axes3, hb: Vec3
) -> ContactManifold[3]:
    """One-point manifold; normal points SPHERE -> BOX (caller flips)."""
    var lp = _box_to_local(cb, axb, cs)
    var q = _box_closest_local(lp, hb)
    var dl = lp - q
    var d2 = dot(dl, dl)
    # "centre on the surface" cut-off relative to the radius (ROADMAP 17.76):
    # an absolute 1e-12 sent the same centre down different branches at
    # different unit scales (`test_unit_scale` on targets without FMA)
    var tiny = r * r * 1e-12
    if d2 > r * r and d2 > tiny:
        return ContactManifold[3].miss()
    var n_world: Vec3
    var depth: Real
    var point: Vec3
    if d2 > tiny:
        # centre outside the box: normal along centre -> surface point
        var dist = sqrt(d2)
        var nl = dl / dist
        n_world = axb[0] * nl[0] + axb[1] * nl[1] + axb[2] * nl[2]
        n_world = -n_world  # sphere -> box
        depth = r - dist
        point = _box_local_world(cb, axb, q)
    else:
        # centre inside: min-axis pushout
        var pen = Real(1e30)
        var axk = 0
        comptime for k in range(3):
            var pk = hb[k] - abs(lp[k])
            if pk < pen:
                pen = pk
                axk = k
        var sgn = Real(1) if lp[axk] >= 0 else Real(-1)
        n_world = axb[axk] * (-sgn)  # sphere(inside) -> box interior dir
        depth = pen + r
        point = cs
    var m = ContactManifold[3].hit_along(n_world)
    m.add(point, depth)
    return m


def _seg_box_closest_t(
    p0: Vec3, p1: Vec3, cb: Vec3, axb: Axes3, hb: Vec3
) -> Real:
    """Parameter t of the segment point closest to the box (ternary search on
    the convex distance function — deterministic, ~1e-4 accuracy)."""
    var lo = Real(0)
    var hi = Real(1)
    for _ in range(40):
        var t1 = lo + (hi - lo) / 3
        var t2 = hi - (hi - lo) / 3
        var a1 = p0 + (p1 - p0) * t1
        var a2 = p0 + (p1 - p0) * t2
        var l1 = _box_to_local(cb, axb, a1)
        var l2 = _box_to_local(cb, axb, a2)
        var d1 = l1 - _box_closest_local(l1, hb)
        var d2v = l2 - _box_closest_local(l2, hb)
        if dot(d1, d1) < dot(d2v, d2v):
            hi = t2
        else:
            lo = t1
    return (lo + hi) * 0.5


def capsule_box_manifold(
    cc: Vec3, cax: Vec3, hl: Real, r: Real, cb: Vec3, axb: Axes3, hb: Vec3
) -> ContactManifold[3]:
    """Up to 2 points (deepest segment point + a penetrating endpoint);
    normal points CAPSULE -> BOX."""
    var p0 = cc - cax * hl
    var p1 = cc + cax * hl
    var m = ContactManifold[3].miss()
    var have = False
    var probes = Array[Real, 3](fill=0)
    probes[0] = _seg_box_closest_t(p0, p1, cb, axb, hb)
    probes[1] = 0
    probes[2] = 1
    for pi in range(3):
        var t = probes[pi]
        var sp = p0 + (p1 - p0) * t
        var sm = sphere_box_manifold(sp, r, cb, axb, hb)
        if not sm.hit:
            continue
        if not have:
            m = ContactManifold[3].hit_along(sm.normal)
            m.add(sm.points[0], sm.depths[0])
            have = True
        else:
            # keep distinct probe points only (avoid t*==endpoint dupes)
            var dpt = sm.points[0] - m.points[0]
            if dot(dpt, dpt) > r * r * 0.04:
                m.add(sm.points[0], sm.depths[0])
        if m.count >= 2:
            break
    return m


def _seg_seg_closest(
    a0: Vec3, a1: Vec3, b0: Vec3, b1: Vec3
) -> Tuple[Vec3, Vec3]:
    """Closest points between two segments (standard clamped solve)."""
    var d1 = a1 - a0
    var d2 = b1 - b0
    var rr = a0 - b0
    var la = dot(d1, d1)
    var lb = dot(d2, d2)
    var f = dot(d2, rr)
    var s = Real(0)
    var t = Real(0)
    if la > 1e-12 and lb > 1e-12:
        var c = dot(d1, rr)
        var b = dot(d1, d2)
        var den = la * lb - b * b
        if abs(den) > 1e-12:
            s = min(max((b * f - c * lb) / den, 0), 1)
        t = (b * s + f) / lb
        if t < 0:
            t = 0
            s = min(max(-c / la, 0), 1)
        elif t > 1:
            t = 1
            s = min(max((b - c) / la, 0), 1)
    elif la > 1e-12:
        s = min(max(-dot(d1, rr) / la, 0), 1)
    elif lb > 1e-12:
        t = min(max(f / lb, 0), 1)
    return (a0 + d1 * s, b0 + d2 * t)


def capsule_capsule_manifold(
    ca: Vec3, axa: Vec3, ha: Real, ra: Real,
    cb: Vec3, axb: Vec3, hb: Real, rb: Real,
) -> ContactManifold[3]:
    var pts = _seg_seg_closest(
        ca - axa * ha, ca + axa * ha, cb - axb * hb, cb + axb * hb
    )
    return sphere_sphere_manifold(pts[0], ra, pts[1], rb)


def capsule_sphere_manifold(
    cc: Vec3, cax: Vec3, hl: Real, r: Real, cs: Vec3, rs: Real
) -> ContactManifold[3]:
    """Normal points CAPSULE -> SPHERE."""
    var p0 = cc - cax * hl
    var p1 = cc + cax * hl
    var d = p1 - p0
    var t = Real(0)
    var l2 = dot(d, d)
    if l2 > 1e-12:
        t = min(max(dot(cs - p0, d) / l2, 0), 1)
    return sphere_sphere_manifold(p0 + d * t, r, cs, rs)
