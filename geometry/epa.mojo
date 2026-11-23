"""EPA (Expanding Polytope Algorithm) penetration for 2D convex shapes.

GJK answers *whether* two convex shapes overlap; EPA recovers *by how much*. We
seed a polytope with GJK's terminating simplex, then repeatedly find the polytope
edge closest to the origin, push a support point outward along that edge's
normal, and insert it — until the support stops moving past the edge. The closest
edge's distance is the penetration depth and its normal the contact normal.

2D EPA expands a polygon of edges; 3D EPA (`epa3`) expands a polytope of
triangle faces and additionally tracks WITNESS points: every polytope vertex
remembers which support of A and of B produced it, so the closest face's
barycentric coordinates recover the deepest points of both shapes
(`Witness.point_a/point_b`, with `point_a - point_b == face_normal * depth`).
The 3D path seeds its own tetrahedron from supports (GJK's simplex stores only
CSO points, not the A/B pair) — GJK is still consulted first for the boolean.
Each dim-specific helper is only ever instantiated at its own `dim` (guarded by
`comptime if`), and SIMD points in Lists stay wrapped in structs (width-3
realloc hazard, see gjk.mojo). Normals are oriented from `a` toward `b`.
"""

from .vec import WorldType, Real, Vec2, Vec3, dot, normalize, length, PadW, cross
from .gjk import ConvexPoly, Simplex, Support3, gjk_query


@fieldwise_init
struct EpaResult[dim: Int](Copyable, ImplicitlyCopyable, Movable):
    var hit: Bool
    var normal: SIMD[WorldType, PadW[Self.dim]]  # points from a -> b
    var depth: Real

    @staticmethod
    def miss() -> Self:
        return Self(False, SIMD[WorldType, PadW[Self.dim]](0), 0)


def _centroid[dim: Int](p: ConvexPoly[dim]) -> SIMD[WorldType, PadW[dim]]:
    var c = SIMD[WorldType, PadW[dim]](0)
    for i in range(len(p.points)):
        c += p.points[i]
    return c / Real(len(p.points))


def _epa2[dim: Int](
    a: ConvexPoly[dim], b: ConvexPoly[dim], simplex: Simplex[dim]
) -> EpaResult[dim]:
    """2D EPA. Only instantiated at dim == 2, so Vec lists are realloc-safe."""
    var poly = List[SIMD[WorldType, PadW[dim]]]()
    # Seed from the simplex's (up to 3) distinct points.
    poly.append(simplex.pa)
    if not _same[dim](simplex.pb, simplex.pa):
        poly.append(simplex.pb)
    if not _same[dim](simplex.pc, simplex.pa) and not _same[dim](simplex.pc, simplex.pb):
        poly.append(simplex.pc)

    var ca = _centroid[dim](a)
    var cb = _centroid[dim](b)

    if len(poly) < 3:
        # Degenerate seed (shapes barely touching): fall back to centroid dir.
        var n = normalize(cb - ca)
        return EpaResult[dim](True, n, Real(1e-4))

    # Ensure CCW winding so edge right-normals point outward.
    if _signed_area[dim](poly) < 0:
        var rev = List[SIMD[WorldType, PadW[dim]]]()
        for i in range(len(poly)):
            rev.append(poly[len(poly) - 1 - i])
        poly = rev^

    var result_n = SIMD[WorldType, PadW[dim]](0)
    var result_d = Real(0)
    for _ in range(64):
        # Closest edge of the polytope to the origin.
        var min_dist = Real(1.0e30)
        var min_idx = 0
        var min_normal = SIMD[WorldType, PadW[dim]](0)
        var m = len(poly)
        for i in range(m):
            var p0 = poly[i]
            var p1 = poly[(i + 1) % m]
            var e = p1 - p0
            var nrm = normalize(_perp_out[dim](e))
            var dist = dot(nrm, p0)
            if dist < min_dist:
                min_dist = dist
                min_idx = i
                min_normal = nrm
        # Support of the Minkowski difference along the edge normal.
        var sp = a.support(min_normal) - b.support(-min_normal)
        var d = dot(sp, min_normal)
        result_n = min_normal
        result_d = min_dist
        if d - min_dist < Real(1e-4):
            break
        # Insert the support point after min_idx and continue expanding.
        var newpoly = List[SIMD[WorldType, PadW[dim]]]()
        for i in range(m):
            newpoly.append(poly[i])
            if i == min_idx:
                newpoly.append(sp)
        poly = newpoly^

    # Orient from a -> b.
    if dot(cb - ca, result_n) < 0:
        result_n = -result_n
    return EpaResult[dim](True, result_n, result_d)


def _same[dim: Int](a: SIMD[WorldType, PadW[dim]], b: SIMD[WorldType, PadW[dim]]) -> Bool:
    return length(a - b) < Real(1e-9)


def _perp_out[dim: Int](e: SIMD[WorldType, PadW[dim]]) -> SIMD[WorldType, PadW[dim]]:
    """Right-hand normal of edge `e` (outward for a CCW polygon)."""
    var r = SIMD[WorldType, PadW[dim]](0)
    r[0] = e[1]
    r[1] = -e[0]
    return r


def _signed_area[dim: Int](poly: List[SIMD[WorldType, PadW[dim]]]) -> Real:
    var area = Real(0)
    var n = len(poly)
    for i in range(n):
        var p0 = poly[i]
        var p1 = poly[(i + 1) % n]
        area += p0[0] * p1[1] - p1[0] * p0[1]
    return area


def gjk_collide[dim: Int](
    a: ConvexPoly[dim], b: ConvexPoly[dim]
) -> EpaResult[dim]:
    """GJK overlap test; on a hit, EPA penetration (2D and 3D)."""
    var q = gjk_query[dim](a, b)
    if not q.hit:
        return EpaResult[dim].miss()
    comptime if dim == 2:
        return _epa2[dim](a, b, q.simplex)
    else:
        var w = epa3(a, b)
        var n = SIMD[WorldType, PadW[dim]](0)
        comptime for k in range(min(dim, 3)):
            n[k] = w.normal[k]
        return EpaResult[dim](True, n, w.depth)


# --- 3D EPA with witness points ---------------------------------------------


@fieldwise_init
struct Witness[dim: Int](Copyable, ImplicitlyCopyable, Movable):
    """Penetration contact with witness points: the deepest point of each
    shape, recovered barycentrically from EPA's closest face. Up to float
    error `point_a - point_b == normal * depth` (sign flips only when the
    centroid a->b orientation disagrees with the face normal)."""

    var hit: Bool
    var normal: SIMD[WorldType, PadW[Self.dim]]  # points from a -> b
    var depth: Real
    var point_a: SIMD[WorldType, PadW[Self.dim]]
    var point_b: SIMD[WorldType, PadW[Self.dim]]

    @staticmethod
    def miss() -> Self:
        var z = SIMD[WorldType, PadW[Self.dim]](0)
        return Self(False, z, 0, z, z)


@fieldwise_init
struct _WVert(Copyable, ImplicitlyCopyable, Movable):
    var v: Vec3  # CSO point (= sa - sb)
    var sa: Vec3  # support of A
    var sb: Vec3  # support of B


@fieldwise_init
struct _Face(Copyable, ImplicitlyCopyable, Movable):
    var i0: Int
    var i1: Int
    var i2: Int
    var n: Vec3  # outward unit normal
    var d: Real  # signed distance from the origin along n


@fieldwise_init
struct _Edge(Copyable, ImplicitlyCopyable, Movable):
    var a: Int
    var b: Int


def _wsupport[A: Support3, B: Support3](a: A, b: B, dir: Vec3) -> _WVert:
    var sa = a.support_point(dir)
    var sb = b.support_point(-dir)
    return _WVert(sa - sb, sa, sb)


def _mk_face(
    verts: List[_WVert], i0: Int, i1: Int, i2: Int, interior: Vec3
) -> _Face:
    """Face oriented away from `interior`; degenerate faces get d = 1e30 so
    they are never selected as closest."""
    var v0 = verts[i0].v
    var n = cross[3](verts[i1].v - v0, verts[i2].v - v0)
    var ln = length(n)
    if ln < Real(1e-12):
        return _Face(i0, i1, i2, Vec3(0, 0, 0, 0), Real(1e30))
    n = n / ln
    if dot(n, v0 - interior) < 0:
        return _Face(i0, i2, i1, -n, dot(-n, v0))
    return _Face(i0, i1, i2, n, dot(n, v0))


def _add_edge(mut edges: List[_Edge], a: Int, b: Int):
    """Accumulate horizon edges: an edge shared by two removed faces cancels,
    edges seen once form the horizon loop."""
    for i in range(len(edges)):
        if (edges[i].a == b and edges[i].b == a) or (
            edges[i].a == a and edges[i].b == b
        ):
            edges[i] = edges[len(edges) - 1]
            _ = edges.pop()
            return
    edges.append(_Edge(a, b))


def _touch_fallback[A: Support3, B: Support3](a: A, b: B) -> Witness[3]:
    """Flat CSO (shapes barely touching): centroid-direction contact."""
    var n = b.center_point() - a.center_point()
    if dot(n, n) < Real(1e-12):
        n = Vec3(1, 0, 0, 0)
    n = normalize(n)
    return Witness[3](True, n, Real(1e-4), a.support_point(n), b.support_point(-n))


def _seed_tetra[A: Support3, B: Support3](a: A, b: B, mut verts: List[_WVert]) -> Bool:
    """Build a non-degenerate seed tetrahedron on the CSO hull from supports."""
    var d0 = Vec3(1, 0, 0, 0)
    verts.append(_wsupport(a, b, d0))
    var d1 = -verts[0].v
    if dot(d1, d1) < Real(1e-12):
        d1 = -d0
    verts.append(_wsupport(a, b, normalize(d1)))
    var ab = verts[1].v - verts[0].v
    var ao = -verts[0].v
    # Perpendicular to the segment, toward the origin.
    var d2 = ao * dot(ab, ab) - ab * dot(ab, ao)
    if dot(d2, d2) < Real(1e-12):
        var ax = Vec3(1, 0, 0, 0)
        d2 = cross[3](ab, ax)
        if dot(d2, d2) < Real(1e-12):
            ax[0] = 0
            ax[1] = 1
            d2 = cross[3](ab, ax)
    verts.append(_wsupport(a, b, normalize(d2)))
    var n = cross[3](
        verts[1].v - verts[0].v, verts[2].v - verts[0].v
    )
    if dot(n, n) < Real(1e-12):
        return False  # collinear: flat CSO
    if dot(n, -verts[0].v) < 0:
        n = -n
    verts.append(_wsupport(a, b, normalize(n)))
    if abs(dot(verts[3].v - verts[0].v, n)) < Real(1e-9):
        # Apex landed on the base plane: try the other side.
        verts[3] = _wsupport(a, b, -normalize(n))
        if abs(dot(verts[3].v - verts[0].v, n)) < Real(1e-9):
            return False  # planar CSO: touching contact
    return True


def epa3[A: Support3, B: Support3](a: A, b: B) -> Witness[3]:
    """3D EPA over a triangle-faced polytope, on any two `Support3` shapes
    (point clouds or analytic, ROADMAP 17.52). Callers must have confirmed
    the overlap (GJK)."""
    var verts = List[_WVert]()
    if not _seed_tetra(a, b, verts):
        return _touch_fallback(a, b)
    var interior = (
        verts[0].v + verts[1].v + verts[2].v + verts[3].v
    ) * Real(0.25)
    var faces = List[_Face]()
    faces.append(_mk_face(verts, 0, 1, 2, interior))
    faces.append(_mk_face(verts, 0, 1, 3, interior))
    faces.append(_mk_face(verts, 0, 2, 3, interior))
    faces.append(_mk_face(verts, 1, 2, 3, interior))

    var best = 0
    for _ in range(64):
        best = 0
        var best_d = faces[0].d
        for i in range(1, len(faces)):
            if faces[i].d < best_d:
                best_d = faces[i].d
                best = i
        if best_d >= Real(1e29):
            return _touch_fallback(a, b)  # every face degenerate
        var w = _wsupport(a, b, faces[best].n)
        if dot(w.v, faces[best].n) - best_d < Real(1e-4):
            break  # support no longer expands past the closest face
        var kept = List[_Face]()
        var edges = List[_Edge]()
        for i in range(len(faces)):
            if dot(faces[i].n, w.v) - faces[i].d > 0:
                _add_edge(edges, faces[i].i0, faces[i].i1)
                _add_edge(edges, faces[i].i1, faces[i].i2)
                _add_edge(edges, faces[i].i2, faces[i].i0)
            else:
                kept.append(faces[i])
        if len(kept) == len(faces):
            break  # numerically stuck: accept the current closest face
        var wi = len(verts)
        verts.append(w)
        for e in range(len(edges)):
            kept.append(
                _mk_face(verts, edges[e].a, edges[e].b, wi, interior)
            )
        faces = kept^

    # Witness points: barycentric coordinates of the origin's projection
    # onto the closest face, applied to the tracked A/B supports.
    var f = faces[best]
    var v0 = verts[f.i0]
    var v1 = verts[f.i1]
    var v2 = verts[f.i2]
    var p = f.n * f.d
    var e1 = v1.v - v0.v
    var e2 = v2.v - v0.v
    var ep = p - v0.v
    var d00 = dot(e1, e1)
    var d01 = dot(e1, e2)
    var d11 = dot(e2, e2)
    var d20 = dot(ep, e1)
    var d21 = dot(ep, e2)
    var den = d00 * d11 - d01 * d01
    var l1 = Real(0)
    var l2 = Real(0)
    if abs(den) > Real(1e-12):
        l1 = (d11 * d20 - d01 * d21) / den
        l2 = (d00 * d21 - d01 * d20) / den
    var l0 = 1 - l1 - l2
    var pa = v0.sa * l0 + v1.sa * l1 + v2.sa * l2
    var pb = v0.sb * l0 + v1.sb * l1 + v2.sb * l2
    var depth = f.d if f.d > 0 else Real(0)
    # Orient from a -> b, matching the 2D path.
    var n = f.n
    if dot(b.center_point() - a.center_point(), n) < 0:
        n = -n
    return Witness[3](True, n, depth, pa, pb)


def epa_witness3(a: ConvexPoly[3], b: ConvexPoly[3]) -> Witness[3]:
    """GJK boolean + 3D EPA witness contact (miss when the shapes are apart)."""
    if not gjk_query[3](a, b).hit:
        return Witness[3].miss()
    return epa3(a, b)
