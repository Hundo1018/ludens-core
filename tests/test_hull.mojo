# tier: integration
"""Convex hulls in the production solver (architecture law v3).

`geometry/quickhull.mojo` existed for months without ever being reachable from
collision — the engine's own named example of a capability that does not exist.
This gates the wiring, in the three classes law v3 requires.

ORDINARY    a box EXPRESSED AS A HULL must reproduce the dedicated box-box
            manifold: same normal, same depth, and a multi-point patch. That
            parity is the strongest check available, because the two paths
            share no code — one is SAT with face clipping, the other GJK plus
            face-normal SAT with support-face clipping.
INTEGRATION hulls fall, rest and settle inside `ContactScene6` beside boxes and
            spheres; the broadphase seam stays bit-identical; a hull rests at
            the same height as an identical real box.
EXTREME     degenerate hulls (single vertex, collinear, coplanar, duplicated
            vertices), exactly coincident hulls, and a near-flat hull — where a
            support-face builder returns garbage instead of failing.

Each standalone case runs in its OWN function. That is not style: several
width-3 SIMD lists alive in one frame crash this nightly's runtime (the
documented `SkinVert` hazard), and a test that builds a dozen hulls in one
`main` reproduces it.
"""

from std.math import sqrt
from harness.runner import Suite
from geometry.vec import Real, Vec3, length, dot
from geometry.gjk import ConvexPoly
from collision.hull import HullShape, hull_manifold
from geometry.quat import Quat
from collision.manifold import box_box_manifold, ContactManifold
from physics.rigid6 import Inertia3, QuatBody6
from physics.solver6 import ContactScene6

comptime DT: Real = 1.0 / 60.0
comptime G = Vec3(0, -9.8, 0, 0)


# Vertex lists are FLAT (x, y, z per vertex). A `List[Vec3]` loses its tail
# elements when passed between functions on this nightly; `collision/hull.mojo`
# carries the reduced probe.
def _box_verts(h: Real) -> List[Real]:
    var v = List[Real](capacity=24)
    for sx in range(2):
        for sy in range(2):
            for sz in range(2):
                v.append(h * (Real(1) if sx == 1 else Real(-1)))
                v.append(h * (Real(1) if sy == 1 else Real(-1)))
                v.append(h * (Real(1) if sz == 1 else Real(-1)))
    return v^


def _shifted(verts: List[Real], off: Vec3) -> List[Real]:
    var v = List[Real](capacity=len(verts))
    for i in range(len(verts)):
        v.append(verts[i] + off[i % 3])
    return v^


# ---------------------------------------------------------------- ORDINARY
def case_face_face() -> List[Real]:
    """Two unit boxes overlapping 0.2 along y, as hulls. Returns
    [hit, count, |n.y|, depth]."""
    var ha = HullShape(_box_verts(0.5))
    var hb = HullShape(_shifted(_box_verts(0.5), Vec3(0, 0.8, 0, 0)))
    var ex = Vec3(1, 0, 0, 0)
    var ey = Vec3(0, 1, 0, 0)
    var ez = Vec3(0, 0, 1, 0)
    var pa = ha.world(Vec3(0, 0, 0, 0), ex, ey, ez)
    var pb = hb.world(Vec3(0, 0, 0, 0), ex, ey, ez)
    var na = ha.world_normals(ex, ey, ez)
    var nb = hb.world_normals(ex, ey, ez)
    var m = hull_manifold(pa, pb, na, nb)
    var out = List[Real](capacity=4)
    out.append(Real(1) if m.hit else Real(0))
    out.append(Real(m.count))
    out.append(abs(m.normal[1]))
    out.append(m.depths[0])
    return out^


def case_box_parity() -> List[Real]:
    """The same configuration through the dedicated box-box manifold."""
    var ax = Array[Vec3, 3](fill=Vec3(0, 0, 0, 0))
    ax[0] = Vec3(1, 0, 0, 0)
    ax[1] = Vec3(0, 1, 0, 0)
    ax[2] = Vec3(0, 0, 1, 0)
    var m = box_box_manifold(
        Vec3(0, 0, 0, 0), ax, Vec3(0.5, 0.5, 0.5, 0),
        Vec3(0, 0.8, 0, 0), ax, Vec3(0.5, 0.5, 0.5, 0),
    )
    var out = List[Real](capacity=3)
    out.append(Real(1) if m.hit else Real(0))
    out.append(abs(m.normal[1]))
    out.append(m.depths[0])
    return out^


def case_separated() -> Real:
    var ha = HullShape(_box_verts(0.5))
    var hb = HullShape(_shifted(_box_verts(0.5), Vec3(0, 3.0, 0, 0)))
    var ex = Vec3(1, 0, 0, 0)
    var ey = Vec3(0, 1, 0, 0)
    var ez = Vec3(0, 0, 1, 0)
    var na = ha.world_normals(ex, ey, ez)
    var nb = hb.world_normals(ex, ey, ez)
    var m = hull_manifold(
        ha.world(Vec3(0, 0, 0, 0), ex, ey, ez),
        hb.world(Vec3(0, 0, 0, 0), ex, ey, ez),
        na, nb,
    )
    return Real(1) if m.hit else Real(0)


# ------------------------------------------------------------- INTEGRATION
def case_rest(use_hull: Bool, use_bp: Bool) -> List[Real]:
    """A 0.5-cube dropped on a static floor, as a hull or as a real box.
    Returns [rest y, speed, bit pattern of y]."""
    var sc = ContactScene6[QuatBody6]()
    _ = sc.add(
        QuatBody6.at_rest(Vec3(0, -1, 0, 0), Inertia3.box(1, 30, 1, 30)),
        Vec3(30, 1, 30, 0), True,
    )
    var b: Int
    if use_hull:
        b = sc.add_hull(
            QuatBody6.at_rest(Vec3(0, 0.6, 0, 0), Inertia3.box(2, 0.25, 0.25, 0.25)),
            _box_verts(0.25), False,
        ).index()
    else:
        b = sc.add(
            QuatBody6.at_rest(Vec3(0, 0.6, 0, 0), Inertia3.box(2, 0.25, 0.25, 0.25)),
            Vec3(0.25, 0.25, 0.25, 0), False,
        ).index()
    for _ in range(240):
        sc.step_soft(DT, G, broadphase=use_bp)
    var out = List[Real](capacity=2)
    out.append(sc.bset.bodies[b].position()[1])
    out.append(length(sc.bset.bodies[b].vel))
    return out^


def case_mixed() -> List[Real]:
    """Hull, box and sphere resting in one scene."""
    var sc = ContactScene6[QuatBody6]()
    _ = sc.add(
        QuatBody6.at_rest(Vec3(0, -1, 0, 0), Inertia3.box(1, 30, 1, 30)),
        Vec3(30, 1, 30, 0), True,
    )
    var h = sc.add_hull(
        QuatBody6.at_rest(Vec3(-1, 0.6, 0, 0), Inertia3.box(2, 0.25, 0.25, 0.25)),
        _box_verts(0.25), False,
    ).index()
    var bx = sc.add(
        QuatBody6.at_rest(Vec3(0, 0.6, 0, 0), Inertia3.box(2, 0.25, 0.25, 0.25)),
        Vec3(0.25, 0.25, 0.25, 0), False,
    ).index()
    var sp = sc.add_sphere(
        QuatBody6.at_rest(Vec3(1, 0.6, 0, 0), Inertia3.sphere(2, 0.25)), 0.25, False
    ).index()
    for _ in range(240):
        sc.step_soft(DT, G)
    var out = List[Real](capacity=3)
    out.append(sc.bset.bodies[h].position()[1])
    out.append(sc.bset.bodies[bx].position()[1])
    out.append(sc.bset.bodies[sp].position()[1])
    return out^


def case_tetra_rest() -> Real:
    """A genuinely non-box hull: a tetrahedron dropped on the floor. Boxes are
    the easy case for face clipping; a tet lands on a triangular face and has
    no opposing parallel face, so it exercises the path a box cannot."""
    var v = List[Real](capacity=12)
    v.append(0.3); v.append(-0.2); v.append(0.3)
    v.append(-0.3); v.append(-0.2); v.append(0.3)
    v.append(0.0); v.append(-0.2); v.append(-0.35)
    v.append(0.0); v.append(0.35); v.append(0.0)
    var sc = ContactScene6[QuatBody6]()
    _ = sc.add(
        QuatBody6.at_rest(Vec3(0, -1, 0, 0), Inertia3.box(1, 30, 1, 30)),
        Vec3(30, 1, 30, 0), True,
    )
    var t = sc.add_hull(
        QuatBody6.at_rest(Vec3(0, 0.6, 0, 0), Inertia3.box(2, 0.3, 0.3, 0.3)),
        v^, False,
    ).index()
    for _ in range(300):
        sc.step_soft(DT, G)
    return sc.bset.bodies[t].position()[1]


# ---------------------------------------------------------------- EXTREME
def case_point_point() -> Real:
    var a = ConvexPoly[3]()
    a.add(Vec3(0, 0, 0, 0))
    var b = ConvexPoly[3]()
    b.add(Vec3(0, 0, 0, 0))
    var none = List[Real](capacity=1)
    return Real(hull_manifold(a, b, none, none).count)


def case_collinear() -> Real:
    """A segment hull against a box: no face on the segment side."""
    var ha = HullShape(_box_verts(0.5))
    var ex = Vec3(1, 0, 0, 0)
    var ey = Vec3(0, 1, 0, 0)
    var ez = Vec3(0, 0, 1, 0)
    var seg = ConvexPoly[3]()
    seg.add(Vec3(-0.4, 0.45, 0, 0))
    seg.add(Vec3(0.4, 0.45, 0, 0))
    var na = ha.world_normals(ex, ey, ez)
    var none = List[Real](capacity=1)
    var m = hull_manifold(ha.world(Vec3(0, 0, 0, 0), ex, ey, ez), seg, na, none)
    return Real(m.count)


def case_duplicates() -> Real:
    """Every vertex listed twice must not change the normal."""
    var ha = HullShape(_box_verts(0.5))
    var raw = _shifted(_box_verts(0.5), Vec3(0, 0.8, 0, 0))
    var dbl = List[Real](capacity=48)
    for i in range(len(raw)):
        dbl.append(raw[i])
    for i in range(len(raw)):
        dbl.append(raw[i])
    var hb = HullShape(dbl)
    var ex = Vec3(1, 0, 0, 0)
    var ey = Vec3(0, 1, 0, 0)
    var ez = Vec3(0, 0, 1, 0)
    var na = ha.world_normals(ex, ey, ez)
    var nb = hb.world_normals(ex, ey, ez)
    var m = hull_manifold(
        ha.world(Vec3(0, 0, 0, 0), ex, ey, ez),
        hb.world(Vec3(0, 0, 0, 0), ex, ey, ez),
        na, nb,
    )
    return abs(m.normal[1]) if m.hit else Real(0)


def case_coincident() -> Real:
    """Exactly coincident hulls: the deepest direction is undefined, so the
    only requirement is termination with a finite depth."""
    var ha = HullShape(_box_verts(0.5))
    var hb = HullShape(_box_verts(0.5))
    var ex = Vec3(1, 0, 0, 0)
    var ey = Vec3(0, 1, 0, 0)
    var ez = Vec3(0, 0, 1, 0)
    var na = ha.world_normals(ex, ey, ez)
    var nb = hb.world_normals(ex, ey, ez)
    var m = hull_manifold(
        ha.world(Vec3(0, 0, 0, 0), ex, ey, ez),
        hb.world(Vec3(0, 0, 0, 0), ex, ey, ez),
        na, nb,
    )
    var worst = Real(0)
    for k in range(m.count):
        if abs(m.depths[k]) > worst:
            worst = abs(m.depths[k])
    return worst


def case_cloud() -> List[Real]:
    """A raw point cloud: the eight box corners plus interior points, some of
    them at the centre. The hull must be the box — the interior points dropped,
    the manifold identical to the clean box's. Returns [kept verts, count,
    |n.y|, depth]."""
    var cloud = List[Real](capacity=24 + 27)
    var clean = _box_verts(0.5)
    for i in range(len(clean)):
        cloud.append(clean[i])
    for gx in range(3):  # a 3x3x3 lattice strictly inside
        for gy in range(3):
            for gz in range(3):
                cloud.append(Real(gx - 1) * 0.3)
                cloud.append(Real(gy - 1) * 0.3)
                cloud.append(Real(gz - 1) * 0.3)
    var ha = HullShape(cloud)
    var hb = HullShape(_shifted(_box_verts(0.5), Vec3(0, 0.8, 0, 0)))
    var ex = Vec3(1, 0, 0, 0)
    var ey = Vec3(0, 1, 0, 0)
    var ez = Vec3(0, 0, 1, 0)
    var m = hull_manifold(
        ha.world(Vec3(0, 0, 0, 0), ex, ey, ez),
        hb.world(Vec3(0, 0, 0, 0), ex, ey, ez),
        ha.world_normals(ex, ey, ez),
        hb.world_normals(ex, ey, ez),
    )
    var out = List[Real](capacity=4)
    out.append(Real(ha.nv()))
    out.append(Real(m.count))
    out.append(abs(m.normal[1]))
    out.append(m.depths[0])
    return out^


def case_flat() -> List[Real]:
    """A hull 1e-4 thick — its support face is effectively the whole body."""
    var ha = HullShape(_box_verts(0.5))
    var thin = List[Real](capacity=24)
    for sx in range(2):
        for sy in range(2):
            for sz in range(2):
                thin.append(0.5 * (Real(1) if sx == 1 else Real(-1)))
                thin.append(0.5 + 0.00005 * (Real(1) if sy == 1 else Real(-1)))
                thin.append(0.5 * (Real(1) if sz == 1 else Real(-1)))
    var hb = HullShape(thin)
    var ex = Vec3(1, 0, 0, 0)
    var ey = Vec3(0, 1, 0, 0)
    var ez = Vec3(0, 0, 1, 0)
    var na = ha.world_normals(ex, ey, ez)
    var nb = hb.world_normals(ex, ey, ez)
    var m = hull_manifold(
        ha.world(Vec3(0, 0, 0, 0), ex, ey, ez),
        hb.world(Vec3(0, 0, 0, 0), ex, ey, ez),
        na, nb,
    )
    var worst = Real(0)
    for k in range(m.count):
        if abs(m.depths[k]) > worst:
            worst = abs(m.depths[k])
    var out = List[Real](capacity=2)
    out.append(Real(1) if m.hit else Real(0))
    out.append(worst)
    return out^


def case_box_fast() -> List[Int]:
    """`HullShape.box_world` / `box_world_normals` against the hull they replace, on 300 boxes with half
    extents from 2e-4 to 3 m (the ones under 1e-3 take the hull path) at random orientations and positions.
    Returns [values compared, values whose bits differ]."""
    var seed = UInt64(12345)
    var compared = 0
    var differ = 0
    for _ in range(300):
        var r = List[Real](capacity=10)
        for _ in range(10):
            seed = seed * 6364136223846793005 + 1442695040888963407
            r.append(Real(Float64(seed >> 11) / 9007199254740992.0))
        var half = Vec3(Real(2e-4) + r[0] * r[0] * 3, Real(2e-4) + r[1] * r[1] * 3, Real(2e-4) + r[2] * r[2] * 3, 0)
        var q = Quat.from_euler(r[3] * 6.28, r[4] * 6.28, r[5] * 6.28)
        var ax0 = q.rotate(Vec3(1, 0, 0, 0))
        var ax1 = q.rotate(Vec3(0, 1, 0, 0))
        var ax2 = q.rotate(Vec3(0, 0, 1, 0))
        var pos = Vec3(r[6] * 10 - 5, r[7] * 10 - 5, r[8] * 10 - 5, 0)
        var hull = HullShape.box(half)
        var want_n = hull.world_normals(ax0, ax1, ax2)
        var got_n = HullShape.box_world_normals(half, ax0, ax1, ax2)
        compared += len(want_n)
        if len(got_n) != len(want_n):
            differ += len(want_n)
        else:
            for k in range(len(want_n)):
                if got_n[k].to_bits() != want_n[k].to_bits():
                    differ += 1
        var want_p = hull.world(pos, ax0, ax1, ax2)
        var got_p = HullShape.box_world(half, pos, ax0, ax1, ax2)
        compared += 3 * len(want_p.points)
        if len(got_p.points) != len(want_p.points):
            differ += 3 * len(want_p.points)
        else:
            for k in range(len(want_p.points)):
                for c in range(3):
                    if got_p.points[k][c].to_bits() != want_p.points[k][c].to_bits():
                        differ += 1
    var out = List[Int](capacity=2)
    out.append(compared)
    out.append(differ)
    return out^


def main() raises:
    var s = Suite("hull")

    # ---- ORDINARY ----
    var ff = case_face_face()
    print("  face-face: hit", ff[0], " count", ff[1], " |n.y|", ff[2], " depth", ff[3])
    s.check(ff[0] > 0, "overlapping hulls report a hit")
    s.check(ff[2] > 0.99, "normal is the y axis")
    s.check(ff[1] >= 3, "face-face contact yields a PATCH, not one point")
    s.check(abs(ff[3] - 0.2) < 0.02, "depth is the 0.2 overlap")

    var bp = case_box_parity()
    print("  box-box reference: |n.y|", bp[1], " depth", bp[2])
    s.check(bp[0] > 0, "box-box reference also hits")
    s.check(abs(ff[2] - bp[1]) < 0.01, "hull normal == box-box SAT normal")
    s.check(abs(ff[3] - bp[2]) < 0.02, "hull depth == box-box SAT depth")

    s.check(case_separated() == 0, "separated hulls miss")

    # ---- INTEGRATION ----
    var rh = case_rest(True, False)
    var rb = case_rest(False, False)
    print("  rest y — hull", rh[0], " real box", rb[0], "  hull speed", rh[1])
    s.check(abs(Float64(rh[0]) - 0.25) < 0.02, "a hull box rests at its half-height")
    s.check(
        abs(Float64(rh[0] - rb[0])) < 0.005,
        "a hull rests at the SAME height as an identical real box",
    )
    s.check(Float64(rh[1]) < 0.05, "the hull settles (the patch resists rotation)")

    var rbp = case_rest(True, True)
    s.check(
        rbp[0] == rh[0],
        "broadphase on/off is bit-identical with hulls present",
    )

    var mx = case_mixed()
    print("  mixed — hull", mx[0], " box", mx[1], " sphere", mx[2])
    var mixed_ok = True
    for k in range(3):
        if abs(Float64(mx[k]) - 0.25) > 0.05:
            mixed_ok = False
    s.check(mixed_ok, "hull, box and sphere all rest correctly in one scene")

    var ty = case_tetra_rest()
    print("  tetrahedron rest y:", ty, " (spawned at 0.6)")
    s.check(Float64(ty) > -0.1 and Float64(ty) < 0.6, "a tetrahedron lands and stays")

    # ---- EXTREME ----
    s.check(case_point_point() <= 1, "point-vs-point yields at most one contact")
    var cl = case_collinear()
    print("  collinear-hull contact count:", cl)
    s.check(cl <= Real(ContactManifold[3].MAX), "collinear hull: bounded count")
    var du = case_duplicates()
    print("  duplicated-vertex |n.y|:", du)
    s.check(du > 0.99, "duplicated vertices give the same normal")
    var co = case_coincident()
    print("  coincident-hull worst depth:", co)
    s.check(Float64(co) < 1e6, "coincident hulls terminate with a finite depth")
    var cd = case_cloud()
    print("  point cloud (35 in) -> kept", cd[0], " count", cd[1], " |n.y|", cd[2])
    s.check(cd[0] == 8, "interior points are pruned: 35 in, 8 hull vertices out")
    s.check(cd[1] == ff[1], "a cloud gives the same patch as the clean box")
    s.check(abs(cd[2] - ff[2]) < 1e-4, "a cloud gives the same normal")
    s.check(abs(cd[3] - ff[3]) < 1e-4, "a cloud gives the same depth")

    var fl = case_flat()
    print("  near-flat hull: hit", fl[0], " worst depth", fl[1])
    s.check(fl[0] > 0, "a near-flat hull still collides")
    s.check(Float64(fl[1]) < 1.0, "near-flat hull depths stay bounded")

    var bf = case_box_fast()
    print("  box fast path: values compared", bf[0], " bits differing", bf[1])
    s.check(bf[1] == 0, "box_world / box_world_normals give the hull's bits")

    s.finish()
