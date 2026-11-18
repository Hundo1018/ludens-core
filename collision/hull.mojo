"""Convex-hull contact: arbitrary convex shapes in the production solver.

Until now `ContactScene6` could only collide boxes, spheres and capsules: an
arbitrary convex shape had no way into the solver at all. This is that path.

It is not `geometry/quickhull.mojo` — that one is 2D, and it was the engine's
own example of an unwired capability. It now has a production entry point of
its own (`SATNarrowPhase.add_cloud`), and `_prune_interior` below is the
equivalent service on this 3D path: both let a caller hand over an unordered
point cloud instead of an already-correct convex shape.

Shape and depth come from GJK + EPA (`geometry/epa.mojo`), which already returns
a normal, a penetration depth and witness points on both bodies. What EPA does
NOT return is a contact PATCH: it gives one deepest point, and a single-point
manifold makes a resting box jitter and topple because there is no torque
resisting rotation about the contact. So the patch is built here:

  1. EPA gives the separating normal n (a -> b).
  2. Take each hull's SUPPORT FACE along ±n — every vertex within a tolerance
     of the extreme one. For a convex body that set is exactly the face (or
     edge, or vertex) touching the plane.
  3. Project both faces into the plane perpendicular to n and clip one against
     the other (Sutherland-Hodgman). The surviving polygon is the patch.
  4. Fall back to the EPA witness point whenever either support set is not a
     polygon — a vertex-vertex or vertex-edge touch genuinely has one point,
     and inventing more would be worse than reporting one.

Face extraction by support rather than by stored adjacency is what lets this
work on a bare vertex cloud: no face list, no winding, no half-edge structure —
which is also why it degrades gracefully on the degenerate hulls (coplanar,
collinear, single point) that `test_hull` exercises.
"""

from std.math import sqrt
from geometry.vec import WorldType, Real, Vec3, dot, length, normalize, cross
from geometry.gjk import ConvexPoly, gjk_query
from geometry.epa import Witness, epa_witness3
from .manifold import ContactManifold, spread4

comptime _FACE_EPS: Real = 1e-3  # support-face membership tolerance
comptime _MAX_FACE = 16  # vertices kept per support face


struct HullShape(Movable, Deinitable):
    """Convex hull: LOCAL-frame vertices plus its face normals, stored FLAT.

    Both lists are `List[Real]` with stride 3, and so is the CONSTRUCTOR
    ARGUMENT, because on this nightly a `List[Vec3]` silently loses data the
    moment it crosses a function boundary. Reduced to a probe: build eight
    vertices, return the list, pass it to another function, copy it out — the
    last two elements come back as copies of earlier ones. It reproduces with
    `for ref` and with indexing, borrowed and `var`-owned alike, at a
    pre-reserved capacity so no reallocation is involved; only reading the list
    inside the function that built it, or passing it as an unbound rvalue,
    gives the right answer. That is a miscompile, not a lifetime mistake.

    The visible damage was a box that reported 5 face normals instead of 6, a
    resting hull that sank through the floor, and a crash once several hulls
    were alive. The engine already had the rule that would have prevented it —
    "never put a width-3 vector in a reallocating slot" (`geometry/mat.mojo`) —
    and this module is the evidence that it has to extend to the API, not just
    to storage: struct-wrapping the element (the `SkinVert` mitigation) fixed
    the teardown crash but left the data corruption in place. So no `List[Vec3]`
    is passed, returned or stored anywhere on this path.

    The faces are the reason this is a hull and not just a point cloud. GJK
    needs only `support()`, so detection works on a bare cloud — but building a
    contact PATCH needs the plane the bodies are flat against, and EPA's normal
    carries only its polytope's resolution (~1.4 deg on a box-box face
    contact). Over a 60-unit floor that tilt moves the far vertices 0.74 off
    the extreme, no tolerance recovers the face, and the patch collapses to one
    point — under a resting box, that is what makes it sink and topple.

    Faces are therefore enumerated ONCE, at construction: every vertex triple
    whose plane has all other vertices on one side. O(V^3), which is why it
    lives here and not in `hull_manifold`."""

    var v: List[Real]  # vertices, stride 3
    var f: List[Real]  # outward face normals, stride 3
    # Per-face plane offset (max vertex projection along that face's own
    # normal), aligned 1:1 with `f`/`face(i)` -- the exact local-frame plane
    # equation `dot(p, face(i)) <= face_offset(i)` for a point inside the
    # hull. Captured for free in `_build_faces` (it already computes this
    # value to test face membership); used by 17.0f's soft-particle-vs-hull
    # SAT query (`ColliderSet.soft_particle_contact`, F4b) so that query
    # never has to re-scan every vertex per face per particle per step.
    var fo: List[Real]
    # A box centred on its origin (8 vertices at (+-hx, +-hy, +-hz), 6 faces).
    # The speculative margin can still inflate THIS hull the old way, by
    # pushing each vertex out along its own octant, because for a centred box
    # that keeps every face flat and reproduces the dedicated box path exactly;
    # for any other hull it bends the faces (see `hull_manifold`).
    var box_like: Bool
    # ROADMAP 17.52: > 0 marks a tessellated cylinder of this radius about
    # local Y (half length = the hull's half extent in y). Its side contacts
    # use the capsule treatment (`ColliderSet.pair_manifold`, the round
    # anchors of `physics.contact6.round_core`), so it rolls like a cylinder
    # rather than like the polygon it is tessellated as.
    var round_r: Real

    def __init__(out self, verts: List[Real]):
        """`verts` is FLAT: x, y, z per vertex. Not `List[Vec3]` — see above."""
        self.v = List[Real](capacity=len(verts))
        for i in range(len(verts)):
            self.v.append(verts[i])
        self.f = List[Real](capacity=96)
        self.fo = List[Real](capacity=32)
        self.box_like = False
        self.round_r = 0
        self._build_faces()
        self._prune_interior()
        self._detect_box()

    def nv(self) -> Int:
        return len(self.v) // 3

    def vert(self, i: Int) -> Vec3:
        return Vec3(self.v[3 * i], self.v[3 * i + 1], self.v[3 * i + 2], 0)

    def nf(self) -> Int:
        return len(self.f) // 3

    def face(self, i: Int) -> Vec3:
        return Vec3(self.f[3 * i], self.f[3 * i + 1], self.f[3 * i + 2], 0)

    def face_offset(self, i: Int) -> Real:
        """`d` in the plane equation `dot(p, face(i)) <= d` (local frame)."""
        return self.fo[i]

    def _build_faces(mut self):
        var n = self.nv()
        if n < 4:
            return  # degenerate hull: no faces, the cloud path handles it
        var cen = Vec3(0, 0, 0, 0)
        for i in range(n):
            cen = cen + self.vert(i)
        cen = cen / Real(n)
        for i in range(n):
            for j in range(i + 1, n):
                for k in range(j + 1, n):
                    var e1 = self.vert(j) - self.vert(i)
                    var e2 = self.vert(k) - self.vert(i)
                    var c = Vec3(
                        e1[1] * e2[2] - e1[2] * e2[1],
                        e1[2] * e2[0] - e1[0] * e2[2],
                        e1[0] * e2[1] - e1[1] * e2[0],
                        0,
                    )
                    var cl = length(c)
                    if cl < 1e-9:
                        continue  # collinear triple
                    var nrm = c / cl
                    if dot(nrm, self.vert(i) - cen) < 0:
                        nrm = -nrm  # orient outward
                    var d = dot(nrm, self.vert(i))
                    var is_face = True
                    for m2 in range(n):
                        if dot(nrm, self.vert(m2)) > d + 1e-5:
                            is_face = False
                            break
                    if not is_face:
                        continue
                    var seen = False
                    for q in range(self.nf()):
                        if dot(self.face(q), nrm) > 0.999:
                            seen = True
                            break
                    if not seen and len(self.f) < 90:
                        self.f.append(nrm[0])
                        self.f.append(nrm[1])
                        self.f.append(nrm[2])
                        self.fo.append(d)

    def _detect_box(mut self):
        if self.nv() != 8 or self.nf() != 6:
            return
        var h = List[Real](capacity=3)
        for k in range(3):
            h.append(abs(self.v[k]))
        for i in range(8):
            for k in range(3):
                if h[k] <= 1e-9 or abs(abs(self.v[3 * i + k]) - h[k]) > 1e-6 * h[k]:
                    return
        # eight DISTINCT sign patterns
        var seen = 0
        for i in range(8):
            var code = 0
            for k in range(3):
                if self.v[3 * i + k] > 0:
                    code |= 1 << k
            seen |= 1 << code
        self.box_like = seen == 255

    def _prune_interior(mut self):
        """Drop vertices that lie strictly inside the hull.

        The input is allowed to be a raw point cloud — sampled, scanned, or a
        mesh's whole vertex list — and interior points cost real time later:
        every support query and every SAT axis scans all of them, once per pair
        per step, forever. They are found for free here, since a vertex is on
        the surface exactly when it touches at least one of the faces already
        enumerated. This is the 3D counterpart of what `convex_hull_2d` does
        for the 2D SAT path, done from the faces instead of by divide and
        conquer, because the faces are already in hand."""
        var nf = self.nf()
        var n = self.nv()
        if nf == 0 or n == 0:
            return  # degenerate: no surface to be inside of
        var kept = List[Real](capacity=len(self.v))
        for i in range(n):
            var on_surface = False
            for q in range(nf):
                var nq = self.face(q)
                var d = dot(nq, self.vert(0))
                for k in range(1, n):
                    var t = dot(nq, self.vert(k))
                    if t > d:
                        d = t
                if dot(nq, self.vert(i)) >= d - 1e-5:
                    on_surface = True
                    break
            if on_surface:
                kept.append(self.v[3 * i])
                kept.append(self.v[3 * i + 1])
                kept.append(self.v[3 * i + 2])
        self.v = kept^

    @staticmethod
    def box(half: Vec3) -> Self:
        var v = List[Real](capacity=24)
        for sx in range(2):
            for sy in range(2):
                for sz in range(2):
                    v.append(half[0] * (Real(1) if sx == 1 else Real(-1)))
                    v.append(half[1] * (Real(1) if sy == 1 else Real(-1)))
                    v.append(half[2] * (Real(1) if sz == 1 else Real(-1)))
        return Self(v)

    @staticmethod
    def box_world(half: Vec3, pos: Vec3, ax0: Vec3, ax1: Vec3, ax2: Vec3) -> ConvexPoly[3]:
        """`HullShape.box(half).world(pos, ax0, ax1, ax2)` without building the hull's faces: `world` reads only
        the vertices, and a box keeps all eight, in the order `box` lists them (sx, sy, sz). Same arithmetic,
        so the same bits; `test_hull` checks it against the hull for random boxes."""
        var p = ConvexPoly[3]()
        for sx in range(2):
            for sy in range(2):
                for sz in range(2):
                    var w = Vec3(
                        half[0] * (Real(1) if sx == 1 else Real(-1)),
                        half[1] * (Real(1) if sy == 1 else Real(-1)),
                        half[2] * (Real(1) if sz == 1 else Real(-1)),
                        0,
                    )
                    p.add(pos + ax0 * w[0] + ax1 * w[1] + ax2 * w[2])
        return p^

    @staticmethod
    def box_world_normals(half: Vec3, ax0: Vec3, ax1: Vec3, ax2: Vec3) -> List[Real]:
        """`HullShape.box(half).world_normals(ax0, ax1, ax2)` without the O(n^3) face search. For a box whose half
        extents are all >= 1e-3, `_build_faces` accepts exactly the six face planes, first from the vertex
        triples (0,1,2) -x, (0,1,4) -y, (0,2,4) -z, (1,3,5) +z, (2,3,6) +y, (4,5,6) +x (vertex index
        4 sx + 2 sy + sz); each normal is computed here from that triple with the same expressions. Smaller
        boxes take the hull path: there the absolute tolerances (1e-9, 1e-5) are within reach of the
        geometry. `test_hull` checks the two against each other."""
        if half[0] < 1e-3 or half[1] < 1e-3 or half[2] < 1e-3:
            return HullShape.box(half).world_normals(ax0, ax1, ax2)
        var v = List[Vec3](capacity=8)
        var cen = Vec3(0, 0, 0, 0)
        for sx in range(2):
            for sy in range(2):
                for sz in range(2):
                    var w = Vec3(
                        half[0] * (Real(1) if sx == 1 else Real(-1)),
                        half[1] * (Real(1) if sy == 1 else Real(-1)),
                        half[2] * (Real(1) if sz == 1 else Real(-1)),
                        0,
                    )
                    v.append(w)
                    cen = cen + w
        cen = cen / Real(8)
        var out = List[Real](capacity=18)
        comptime TRIPLES = (0, 1, 2, 0, 1, 4, 0, 2, 4, 1, 3, 5, 2, 3, 6, 4, 5, 6)
        comptime for f in range(6):
            var vi = v[TRIPLES[3 * f]]
            var e1 = v[TRIPLES[3 * f + 1]] - vi
            var e2 = v[TRIPLES[3 * f + 2]] - vi
            var c = Vec3(
                e1[1] * e2[2] - e1[2] * e2[1],
                e1[2] * e2[0] - e1[0] * e2[2],
                e1[0] * e2[1] - e1[1] * e2[0],
                0,
            )
            var nrm = c / length(c)
            if dot(nrm, vi - cen) < 0:
                nrm = -nrm
            var r = ax0 * nrm[0] + ax1 * nrm[1] + ax2 * nrm[2]
            out.append(r[0])
            out.append(r[1])
            out.append(r[2])
        return out^

    def world(self, pos: Vec3, ax0: Vec3, ax1: Vec3, ax2: Vec3) -> ConvexPoly[3]:
        var p = ConvexPoly[3]()
        for i in range(self.nv()):
            var w = self.vert(i)
            p.add(pos + ax0 * w[0] + ax1 * w[1] + ax2 * w[2])
        return p^

    def world_normals(self, ax0: Vec3, ax1: Vec3, ax2: Vec3) -> List[Real]:
        """World face normals, flat (stride 3)."""
        var out = List[Real](capacity=len(self.f))
        for i in range(self.nf()):
            var w = self.face(i)
            var r = ax0 * w[0] + ax1 * w[1] + ax2 * w[2]
            out.append(r[0])
            out.append(r[1])
            out.append(r[2])
        return out^


def _at(v: List[Real], i: Int) -> Vec3:
    return Vec3(v[3 * i], v[3 * i + 1], v[3 * i + 2], 0)


def _push(mut v: List[Real], p: Vec3):
    v.append(p[0])
    v.append(p[1])
    v.append(p[2])


def _basis(n: Vec3) -> Tuple[Vec3, Vec3]:
    """Any orthonormal pair spanning the plane perpendicular to `n`.

    A deliberately different variant from `geometry.vec.tangent_basis`: this
    one only needs *some* orthonormal pair (its callers don't care which),
    uses a different seed threshold (0.7, not 0.9) and cross operand order
    (`cross(n, x)`, not `cross(x, n)`), so unifying it with the canonical
    `tangent_basis` would flip signs / change the branch point for callers
    whose output is in the golden test log. Kept separate per audit F8's own
    resolution rule; built from the shared `cross` primitive instead of a
    third hand-inlined copy of the formula."""
    var a = Vec3(1, 0, 0, 0)
    if abs(n[0]) > 0.7:
        a = Vec3(0, 1, 0, 0)
    var t1 = normalize(cross(n, a))
    var t2 = cross(n, t1)
    return (t1, t2)


def _best_normal(faces: List[Real], n: Vec3) -> Vec3:
    """The unit face normal in `faces` (flat, stride 3) closest to `n`; `n`
    itself when there are none."""
    var nf = len(faces) // 3
    if nf == 0:
        return n
    var bi = 0
    var bd = dot(_at(faces, 0), n)
    for i in range(1, nf):
        var d = dot(_at(faces, i), n)
        if d > bd:
            bd = d
            bi = i
    var f = _at(faces, bi)
    var fl = length(f)
    if fl < 1e-9:
        return n
    return f / fl


def _face_by_normal(p: ConvexPoly[3], faces: List[Real], n: Vec3) -> List[Real]:
    """Vertices of the face whose normal is closest to `n`, flat.

    Membership is measured along THAT FACE's own normal, not along `n`, which
    makes it independent of how far the body has tilted. Measuring along `n`
    with an absolute tolerance was an earlier bug: a resting box settles a
    fraction of a degree off axis, only its lowest vertex then falls inside the
    tolerance, and the patch collapses to a single point."""
    var out = List[Real](capacity=3 * _MAX_FACE)
    var np = len(p.points)
    if np == 0:
        return out^
    var nf = len(faces) // 3
    var f = n
    if nf > 0:
        var bi = 0
        var bd = dot(_at(faces, 0), n)
        for i in range(1, nf):
            var d = dot(_at(faces, i), n)
            if d > bd:
                bd = d
                bi = i
        f = _at(faces, bi)
    var fl = length(f)
    if fl < 1e-9:
        return out^
    f = f / fl
    var hi = dot(p.points[0], f)
    for i in range(1, np):
        var d = dot(p.points[i], f)
        if d > hi:
            hi = d
    for i in range(np):
        if dot(p.points[i], f) >= hi - _FACE_EPS and len(out) < 3 * _MAX_FACE:
            _push(out, p.points[i])
    return out^


def _order_ccw(mut pts: List[Real], t1: Vec3, t2: Vec3):
    """Sort a coplanar set into convex-polygon order by angle about its
    centroid. Valid because a convex body's support face IS convex."""
    from std.math import atan2

    var n = len(pts) // 3
    if n < 3:
        return
    var cx = Real(0)
    var cy = Real(0)
    for i in range(n):
        cx += dot(_at(pts, i), t1)
        cy += dot(_at(pts, i), t2)
    cx /= Real(n)
    cy /= Real(n)
    var ang = List[Real](capacity=n)
    for i in range(n):
        ang.append(
            Real(atan2(
                Float64(dot(_at(pts, i), t2) - cy),
                Float64(dot(_at(pts, i), t1) - cx),
            ))
        )
    for i in range(1, n):
        var ka = ang[i]
        var px = pts[3 * i]
        var py = pts[3 * i + 1]
        var pz = pts[3 * i + 2]
        var j = i - 1
        while j >= 0 and ang[j] > ka:
            ang[j + 1] = ang[j]
            pts[3 * (j + 1)] = pts[3 * j]
            pts[3 * (j + 1) + 1] = pts[3 * j + 1]
            pts[3 * (j + 1) + 2] = pts[3 * j + 2]
            j -= 1
        ang[j + 1] = ka
        pts[3 * (j + 1)] = px
        pts[3 * (j + 1) + 1] = py
        pts[3 * (j + 1) + 2] = pz


def _clip_poly(
    subject: List[Real], clipper: List[Real], t1: Vec3, t2: Vec3
) -> List[Real]:
    """Sutherland-Hodgman clip of `subject` against `clipper`, both projected
    into the (t1, t2) plane."""
    var out = List[Real](capacity=6 * _MAX_FACE)
    for i in range(len(subject)):
        out.append(subject[i])
    var m = len(clipper) // 3
    if m < 3:
        return out^
    var cu = Real(0)
    var cv = Real(0)
    for i in range(m):
        cu += dot(_at(clipper, i), t1)
        cv += dot(_at(clipper, i), t2)
    cu /= Real(m)
    cv /= Real(m)
    for e in range(m):
        var k = len(out) // 3
        if k == 0:
            return out^
        var a = _at(clipper, e)
        var b = _at(clipper, (e + 1) % m)
        var eu = dot(b - a, t1)
        var ev = dot(b - a, t2)
        var nu = -ev
        var nv = eu
        var off = nu * dot(a, t1) + nv * dot(a, t2)
        if nu * cu + nv * cv < off:  # orient the clipper's interior positive
            nu = -nu
            nv = -nv
            off = -off
        var kept = List[Real](capacity=6 * _MAX_FACE)
        for i in range(k):
            var cur = _at(out, i)
            var nxt = _at(out, (i + 1) % k)
            var dc = nu * dot(cur, t1) + nv * dot(cur, t2) - off
            var dn = nu * dot(nxt, t1) + nv * dot(nxt, t2) - off
            if dc >= 0:
                _push(kept, cur)
            if (dc >= 0) != (dn >= 0):
                var den = dc - dn
                var t = dc / den if abs(den) > 1e-12 else Real(0)
                _push(kept, cur + (nxt - cur) * t)
        out = kept^
    return out^


def _dedup(p: ConvexPoly[3]) -> ConvexPoly[3]:
    """Drop coincident vertices: EPA expands a polytope by adding support
    points, and duplicated vertices produce zero-area faces whose normals are
    undefined — which crashed the runtime on a hull listing its vertices
    twice."""
    var out = ConvexPoly[3]()
    for i in range(len(p.points)):
        var v = p.points[i]
        var dup = False
        for j in range(len(out.points)):
            if length(v - out.points[j]) < 1e-6:
                dup = True
                break
        if not dup:
            out.add(v)
    return out^


def _incident_contact(
    mut m: ContactManifold[3], inc: List[Real], n: Vec3, ref_level: Real, ref_is_a: Bool
):
    """Contact from the incident body's support set (one vertex, or the ends of
    an edge) against the reference body's face, each point at its own depth
    below the reference plane. Used when EPA has nothing to say because the
    hulls are not overlapping yet (a speculative contact)."""
    m.count = min(len(inc) // 3, ContactManifold[3].MAX)
    for i in range(m.count):
        var q = _at(inc, i)
        var dq = (ref_level - dot(q, n)) if ref_is_a else (dot(q, n) - ref_level)
        m.points[i] = q
        m.depths[i] = dq


def hull_manifold(
    a_in: ConvexPoly[3], b_in: ConvexPoly[3],
    faces_a: List[Real], faces_b: List[Real],
    margin: Real = 0,
) -> ContactManifold[3]:
    """Contact patch between two convex hulls. Normal points a -> b, matching
    every other manifold in `collision/manifold.mojo`.

    `faces_*` are world-frame face normals (flat, stride 3) from
    `HullShape.world_normals`; empty lists fall back to the cloud path, which
    then degrades to a single contact point on large flat bodies.

    `margin` is the SPECULATIVE distance: hulls that do not overlap yet but are
    closer than `margin` along some face axis still produce a contact, with a
    NEGATIVE depth (minus the gap), so the solver can let them close exactly to
    touching. The hulls are NOT inflated to get this. (They used to be:
    `ColliderSet.as_hull` pushed every vertex out along its own octant, which
    keeps a box's faces flat but bends every other hull's -- a vertex of a
    sloped face moved up to `infl * (|nx| + |ny| + |nz|)` off its face plane,
    only one vertex then qualified as "on" the face, the patch collapsed to a
    point that hopped from frame to frame, and an irregular hull -- a fracture
    fragment -- rocked with growing amplitude and sank through the floor.)
    Depths are returned as `max(sep, -margin)`, which for `margin == 0` is the
    old `max(sep, 0)`; the caller adds `margin` back to reproduce the
    inflated-hull convention `try_pair` subtracts from."""
    var a = _dedup(a_in)
    var b = _dedup(b_in)
    var m = ContactManifold[3].miss()
    if len(a.points) == 0 or len(b.points) == 0:
        return m
    var overlapping = gjk_query[3](a, b).hit
    if not overlapping and margin <= 0:
        return m

    # Normal and depth by SAT over the two bodies' FACE NORMALS, not by EPA.
    # EPA's normal carries its polytope's resolution and is worst at shallow
    # penetration — exactly the resting case. Since both hulls carry exact face
    # normals, the minimum-penetration axis among them IS the answer for a face
    # contact, with no tolerance to tune. Edge-edge contacts have their axis in
    # neither face set, so EPA stays as the fallback.
    var na = len(faces_a) // 3
    var nb = len(faces_b) // 3
    var best_d = Real(1e30)
    var n = Vec3(0, 1, 0, 0)
    var found = False
    var axis_from_a = True
    var best_amax = Real(0)
    var best_bmin = Real(0)
    for fi in range(na + nb):
        var ax = _at(faces_a, fi) if fi < na else -_at(faces_b, fi - na)
        var la = length(ax)
        if la < 1e-9:
            continue
        ax = ax / la
        var amax = dot(a.points[0], ax)
        for i in range(1, len(a.points)):
            var d = dot(a.points[i], ax)
            if d > amax:
                amax = d
        var bmin = dot(b.points[0], ax)
        for i in range(1, len(b.points)):
            var d = dot(b.points[i], ax)
            if d < bmin:
                bmin = d
        var overlap = amax - bmin
        if overlap < best_d:
            best_d = overlap
            n = ax
            found = True
            axis_from_a = fi < na
            best_amax = amax
            best_bmin = bmin

    if not overlapping:
        # speculative: only a face axis along which they are separated by less
        # than `margin` qualifies (an edge-edge near miss gets no contact)
        if not found or best_d > 0 or best_d < -margin:
            return m

    var w = epa_witness3(a, b) if overlapping else Witness[3].miss()
    if overlapping and (not found or best_d <= 0):
        if not w.hit:
            return m
        var nl = length(w.normal)
        if nl < 1e-9:
            return m
        m.hit = True
        m.normal = w.normal / nl
        m.count = 1
        m.points[0] = (w.point_a + w.point_b) * 0.5
        m.depths[0] = w.depth
        return m

    m.hit = True
    m.normal = n

    var fa = _face_by_normal(a, faces_a, n)
    var fb = _face_by_normal(b, faces_b, -n)
    var ref_level = best_amax if axis_from_a else best_bmin
    if len(fa) < 9 or len(fb) < 9:
        if not overlapping:
            _incident_contact(m, fb if axis_from_a else fa, n, ref_level, axis_from_a)
            return m
        # vertex or edge touch: EPA's witness pair IS the contact
        m.count = 1
        m.points[0] = (w.point_a + w.point_b) * 0.5
        m.depths[0] = w.depth
        return m

    var tb = _basis(n)
    var t1 = tb[0]
    var t2 = tb[1]
    _order_ccw(fa, t1, t2)
    _order_ccw(fb, t1, t2)
    var clipped = _clip_poly(fb, fa, t1, t2)
    if len(clipped) == 0:
        if not overlapping:
            _incident_contact(m, fb if axis_from_a else fa, n, ref_level, axis_from_a)
            return m
        m.count = 1
        m.points[0] = (w.point_a + w.point_b) * 0.5
        m.depths[0] = w.depth
        return m

    # The clipped points lie on b's face; each one's depth is its distance to
    # a's face plane. Along `n` that is `plane_d - dot(p, n)` only when `n` IS
    # a's face normal. When the axis came from b (a tilted box on a mesh
    # triangle), measure along a's own face normal `fna` and convert to `n`:
    # one level for every point (the old formula) hid the tilt, and a box
    # resting across two triangles tipped off the one it was leaving with
    # every contact there reading "separated" (ROADMAP 17.45).
    var fna = n
    if not axis_from_a:
        fna = _best_normal(faces_a, n)
    var cosn = dot(n, fna)
    if cosn < Real(0.5):
        fna = n
        cosn = 1
    var plane_d = dot(_at(fa, 0), fna)
    var cand = List[Vec3]()
    var cdep = List[Real]()
    for i in range(len(clipped) // 3):
        var p = _at(clipped, i)
        var sep = plane_d - dot(p, n) if axis_from_a else (plane_d - dot(p, fna)) / cosn
        if sep < -(_FACE_EPS + margin):
            continue  # above the reference face: not in contact
        cand.append(p)
        cdep.append(sep if sep > -margin else -margin)
    var pick = spread4(cand, cdep, n)
    var cnt = len(pick)
    for k in range(cnt):
        m.points[k] = cand[pick[k]]
        m.depths[k] = cdep[pick[k]]
    if cnt == 0:
        if not overlapping:
            _incident_contact(m, fb if axis_from_a else fa, n, ref_level, axis_from_a)
            return m
        m.count = 1
        m.points[0] = (w.point_a + w.point_b) * 0.5
        m.depths[0] = w.depth
        return m
    m.count = cnt
    return m


# NOTE: a `hull_manifold_cloud(a, b)` convenience that rebuilt the hulls from
# the point clouds used to live here. It was removed rather than kept: on this
# nightly the callee saw its borrowed face lists as EMPTY when they were built
# inside that wrapper — the identical code inlined at the call site returned the
# full four-point patch, and neither binding the lists to locals nor binding the
# result before returning changed it. Rather than ship an API that silently
# degrades a contact patch to one point, callers build a `HullShape` and pass
# its `world_normals`, which is what `ContactScene6` does anyway.
