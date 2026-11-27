# tier: component
from harness.runner import Suite
from geometry.vec import Real, Vec2, Vec3
from geometry.aabb import AABB2, AABB3
from geometry.shape import Polygon
from geometry.sat import sat_collide
from geometry.obb import OBB, obb_collide
from geometry.gjk import ConvexPoly
from geometry.epa import gjk_collide, epa_witness3
from std.math import cos, sin
from collision.narrowphase import AABBNarrowPhase
from collision.manifold import (
    ContactManifold,
    AABBManifoldNarrowPhase,
    SATManifoldNarrowPhase,
    OBBManifoldNarrowPhase,
    Axes3,
    box_box_manifold,
    GjkManifoldNarrowPhase,
)


def _cube(cx: Float32, cy: Float32, cz: Float32, h: Float32) -> ConvexPoly[3]:
    var p = ConvexPoly[3]()
    p.add(Vec3(cx - h, cy - h, cz - h, 0))
    p.add(Vec3(cx + h, cy - h, cz - h, 0))
    p.add(Vec3(cx + h, cy + h, cz - h, 0))
    p.add(Vec3(cx - h, cy + h, cz - h, 0))
    p.add(Vec3(cx - h, cy - h, cz + h, 0))
    p.add(Vec3(cx + h, cy - h, cz + h, 0))
    p.add(Vec3(cx + h, cy + h, cz + h, 0))
    p.add(Vec3(cx - h, cy + h, cz + h, 0))
    return p^


def main() raises:
    var s = Suite("manifold")

    # 2D — same scene as test_narrowphase's AABB case, so parity is direct.
    var mn = AABBManifoldNarrowPhase[2]()
    _ = mn.add(AABB2(Vec2(0, 0), Vec2(2, 2)))  # 0
    _ = mn.add(AABB2(Vec2(1.5, 0), Vec2(3.5, 2)))  # 1 overlaps by 0.5 in x
    _ = mn.add(AABB2(Vec2(10, 10), Vec2(11, 11)))  # 2 far
    var an = AABBNarrowPhase[2]()
    _ = an.add(AABB2(Vec2(0, 0), Vec2(2, 2)))
    _ = an.add(AABB2(Vec2(1.5, 0), Vec2(3.5, 2)))
    _ = an.add(AABB2(Vec2(10, 10), Vec2(11, 11)))

    var m = mn.test_manifold(0, 1)
    var c = an.test(0, 1)
    s.check(m.hit, "2d hit")
    s.check(m.count == 2, "2d manifold has 2 points")
    # Parity with the single-point path via summary().
    s.almost(Float64(m.summary().depth), Float64(c.depth), "2d depth parity")
    s.check(
        m.normal[0] == c.normal[0] and m.normal[1] == c.normal[1],
        "2d normal parity",
    )
    # Points lie in the overlap region x in [1.5,2], y in [0,2],
    # on the contact plane x = 1.75.
    for i in range(m.count):
        s.almost(Float64(m.points[i][0]), 1.75, "2d point on contact plane")
        s.check(
            m.points[i][1] >= 0 and m.points[i][1] <= 2, "2d point in overlap"
        )
        s.almost(Float64(m.depths[i]), 0.5, "2d per-point depth")
    s.check(m.points[0][1] != m.points[1][1], "2d points distinct")
    s.check(not mn.test_manifold(0, 2).hit, "2d far miss")
    s.check(mn.test_manifold(0, 2).count == 0, "2d miss has no points")

    # 3D — box resting on a ground box: contact axis y, 4 corner points.
    var mn3 = AABBManifoldNarrowPhase[3]()
    _ = mn3.add(AABB3(Vec3(0, 0, 0, 0), Vec3(2, 2, 2, 0)))  # 0 ground
    _ = mn3.add(AABB3(Vec3(0.25, 1.9, 0.25, 0), Vec3(1.75, 3.9, 1.75, 0)))  # 1 on top
    var an3 = AABBNarrowPhase[3]()
    _ = an3.add(AABB3(Vec3(0, 0, 0, 0), Vec3(2, 2, 2, 0)))
    _ = an3.add(AABB3(Vec3(0.25, 1.9, 0.25, 0), Vec3(1.75, 3.9, 1.75, 0)))

    var m3 = mn3.test_manifold(0, 1)
    var c3 = an3.test(0, 1)
    s.check(m3.hit, "3d hit")
    s.check(m3.count == 4, "3d manifold has 4 points")
    s.almost(Float64(m3.summary().depth), Float64(c3.depth), "3d depth parity")
    s.check(m3.normal[1] == c3.normal[1], "3d normal parity (+y)")
    # Points are the 4 corners of overlap rect x,z in [0.25,1.75], y = 1.95.
    var seen_x_lo = False
    var seen_x_hi = False
    for i in range(m3.count):
        s.almost(Float64(m3.points[i][1]), 1.95, "3d point on contact plane")
        s.check(
            m3.points[i][0] >= 0.25 and m3.points[i][0] <= 1.75,
            "3d point in overlap x",
        )
        s.check(
            m3.points[i][2] >= 0.25 and m3.points[i][2] <= 1.75,
            "3d point in overlap z",
        )
        s.almost(Float64(m3.depths[i]), 0.1, "3d per-point depth")
        if m3.points[i][0] < 1.0:
            seen_x_lo = True
        else:
            seen_x_hi = True
    s.check(seen_x_lo and seen_x_hi, "3d corners span the overlap rect")

    # SAT clipping manifold — face-face squares -> 2 points on the incident face.
    var sm = SATManifoldNarrowPhase()
    _ = sm.add(Polygon.box(0, 0, 1, 1))  # 0
    _ = sm.add(Polygon.box(1.5, 0, 1, 1))  # 1 overlap 0.5 in x
    _ = sm.add(Polygon.box(5, 0, 1, 1))  # 2 far
    var ms = sm.test_manifold(0, 1)
    var cs = sat_collide(Polygon.box(0, 0, 1, 1), Polygon.box(1.5, 0, 1, 1))
    s.check(ms.hit, "sat hit")
    s.check(ms.count == 2, "sat face-face -> 2 points")
    s.almost(Float64(ms.summary().depth), Float64(cs.depth), "sat depth parity")
    s.check(
        ms.normal[0] == cs.normal[0] and ms.normal[1] == cs.normal[1],
        "sat normal parity",
    )
    for i in range(ms.count):
        s.almost(Float64(ms.points[i][0]), 0.5, "sat point on incident face")
        s.check(
            ms.points[i][1] >= -1 and ms.points[i][1] <= 1,
            "sat point in overlap band",
        )
        s.almost(Float64(ms.depths[i]), 0.5, "sat per-point depth")
    s.check(ms.points[0][1] != ms.points[1][1], "sat points distinct")
    s.check(not sm.test_manifold(0, 2).hit, "sat far miss")

    # OBB clipping manifold — 45-degree diamond corner into a face -> 1 point.
    var square = OBB(Vec2(0, 0), Vec2(1, 1), 0)
    var diamond = OBB(Vec2(1.5, 0), Vec2(1, 1), 0.7853981633974483)
    var om = OBBManifoldNarrowPhase()
    _ = om.add(square)
    _ = om.add(diamond)
    var mo = om.test_manifold(0, 1)
    var co = obb_collide(square, diamond)
    s.check(mo.hit, "obb hit")
    s.check(mo.count == 1, "obb corner-face -> 1 point")
    s.almost(Float64(mo.summary().depth), Float64(co.depth), "obb depth parity")
    s.check(mo.normal[0] == co.normal[0], "obb normal parity (+x)")
    # The single point is the diamond's leftmost corner (1.5 - sqrt(2), 0).
    s.almost(
        Float64(mo.points[0][0]), 0.08578643762690485, "obb corner x", 1e-3
    )
    s.almost(Float64(mo.points[0][1]), 0.0, "obb corner y", 1e-3)
    s.almost(
        Float64(mo.depths[0]), Float64(co.depth), "obb per-point depth", 1e-3
    )

    # 3D EPA — cubes overlapping by 0.5 in x (was boolean-only / zero depth).
    var ge = gjk_collide[3](_cube(0, 0, 0, 1), _cube(1.5, 0, 0, 1))
    s.check(ge.hit, "epa3 hit")
    s.almost(Float64(ge.depth), 0.5, "epa3 nonzero depth (axis parity)", 1e-3)
    s.almost(Float64(ge.normal[0]), 1.0, "epa3 normal +x", 1e-3)

    # Witness points: deepest point of A on x=1, of B on x=0.5, and
    # point_a - point_b == normal * depth.
    var w = epa_witness3(_cube(0, 0, 0, 1), _cube(1.5, 0, 0, 1))
    s.check(w.hit, "witness hit")
    s.almost(Float64(w.point_a[0]), 1.0, "witness a on face x=1", 1e-3)
    s.almost(Float64(w.point_b[0]), 0.5, "witness b on face x=0.5", 1e-3)
    for k in range(3):
        s.almost(
            Float64(w.point_a[k] - w.point_b[k]),
            Float64(w.normal[k] * w.depth),
            "witness offset = normal*depth",
            1e-3,
        )
    s.check(not epa_witness3(_cube(0, 0, 0, 1), _cube(5, 0, 0, 1)).hit, "witness miss")

    # Deep penetration: offset (0.25, 0.1, 0) -> min axis x, depth 1.75.
    var wd = epa_witness3(_cube(0, 0, 0, 1), _cube(0.25, 0.1, 0, 1))
    s.check(wd.hit, "deep hit")
    s.almost(Float64(wd.depth), 1.75, "deep depth 1.75", 1e-3)
    s.almost(Float64(abs(wd.normal[0])), 1.0, "deep normal +-x", 1e-3)

    # GJK manifold seam: one witness-midpoint contact.
    var gm = GjkManifoldNarrowPhase()
    _ = gm.add(_cube(0, 0, 0, 1))
    _ = gm.add(_cube(1.5, 0, 0, 1))
    _ = gm.add(_cube(5, 0, 0, 1))
    var mg = gm.test_manifold(0, 1)
    s.check(mg.hit, "gjk manifold hit")
    s.check(mg.count == 1, "gjk manifold 1 witness point")
    s.almost(Float64(mg.points[0][0]), 0.75, "gjk manifold point at midpoint", 1e-3)
    s.almost(Float64(mg.summary().depth), Float64(ge.depth), "gjk manifold depth parity", 1e-3)
    s.check(not gm.test_manifold(0, 2).hit, "gjk manifold far miss")

    # Rotated box-box manifold: axis-aligned parity with the AABB path.
    var idax = Axes3(fill=Vec3(0, 0, 0, 0))
    idax[0] = Vec3(1, 0, 0, 0)
    idax[1] = Vec3(0, 1, 0, 0)
    idax[2] = Vec3(0, 0, 1, 0)
    var bb = box_box_manifold(
        Vec3(1, 1, 1, 0), idax, Vec3(1, 1, 1, 0),
        Vec3(1, 2.9, 1, 0), idax, Vec3(0.75, 1, 0.75, 0),
    )
    s.check(bb.hit, "bb hit")
    s.check(bb.count == 4, "bb axis-aligned -> 4 points")
    s.check(bb.normal[1] == 1, "bb normal +y (parity with AABB path)")
    for i in range(bb.count):
        s.almost(Float64(bb.depths[i]), 0.1, "bb per-point depth", 1e-4)
        s.almost(Float64(bb.points[i][1]), 1.9, "bb point on incident face", 1e-4)
        s.check(
            bb.points[i][0] >= 0.25 and bb.points[i][0] <= 1.75,
            "bb point in overlap x",
        )
    s.check(not box_box_manifold(
        Vec3(0, 0, 0, 0), idax, Vec3(1, 1, 1, 0),
        Vec3(5, 0, 0, 0), idax, Vec3(1, 1, 1, 0),
    ).hit, "bb far miss")

    # Tilted box on the ground: the manifold must be depth-ASYMMETRIC — the
    # dipped edge is deeper, which is what gives the solver a restoring torque.
    var th = Float32(0.05)
    var tax = Axes3(fill=Vec3(0, 0, 0, 0))
    tax[0] = Vec3(cos(th), sin(th), 0, 0)
    tax[1] = Vec3(-sin(th), cos(th), 0, 0)
    tax[2] = Vec3(0, 0, 1, 0)
    var tb = box_box_manifold(
        Vec3(0, -1, 0, 0), idax, Vec3(10, 1, 10, 0),
        Vec3(0, 0.245, 0, 0), tax, Vec3(0.25, 0.25, 0.25, 0),
    )
    s.check(tb.hit, "tilted bb hit")
    s.check(tb.count >= 2, "tilted bb has a patch")
    s.check(tb.normal[1] == 1, "tilted bb normal from ground face")
    # The kept contacts are the DIPPED edge: the patch centroid is displaced
    # from the box centre (x=0), so the normal impulses restore the tilt.
    var cx = Float64(0)
    for i in range(tb.count):
        cx += Float64(tb.points[i][0])
    cx /= Float64(tb.count)
    s.check(cx < -0.1, "tilted bb patch offset to the dipped edge (restoring)")

    # Speculative inflation (`spec`, ROADMAP 17.19, 2026-11-25): the test and
    # the depths are those of the inflated boxes, the points stay on the real
    # incident face. A 0.1 m box 0.68 m in front of a 2 x 2 m wall face, spec
    # 0.427 (the 50 m/s bullet of test_ccd6): inflating the extents had put
    # the four points at y, z = +-0.527.
    var sp = Real(0.42666665)
    var wb = box_box_manifold(
        Vec3(0, 0, 0, 0), idax, Vec3(0.05, 2, 2, 0),
        Vec3(-0.83333325, 0, 0, 0), idax, Vec3(0.1, 0.1, 0.1, 0), sp,
    )
    var wi = box_box_manifold(
        Vec3(0, 0, 0, 0), idax, Vec3(0.05 + sp, 2 + sp, 2 + sp, 0),
        Vec3(-0.83333325, 0, 0, 0), idax, Vec3(0.1 + sp, 0.1 + sp, 0.1 + sp, 0),
    )
    s.check(wb.hit and wi.hit, "spec bb hit, like the inflated boxes")
    s.check(wb.count == 4, "spec bb 4 points")
    s.check(wb.normal[0] == wi.normal[0], "spec bb normal = inflated normal")
    for i in range(wb.count):
        s.almost(Float64(wb.points[i][0]), -0.73333325, "spec bb point on the real face", 1e-5)
        s.check(abs(wb.points[i][1]) <= 0.1 + 1e-6 and abs(wb.points[i][2]) <= 0.1 + 1e-6,
            "spec bb point inside the real face")
        s.almost(Float64(wb.depths[i]), Float64(wi.depths[i]), "spec bb depth = inflated depth", 1e-5)
    s.check(not box_box_manifold(
        Vec3(0, 0, 0, 0), idax, Vec3(1, 1, 1, 0),
        Vec3(5, 0, 0, 0), idax, Vec3(1, 1, 1, 0), 0.4,
    ).hit, "spec bb miss beyond the margin")
    var zb = box_box_manifold(
        Vec3(1, 1, 1, 0), idax, Vec3(1, 1, 1, 0),
        Vec3(1, 2.9, 1, 0), idax, Vec3(0.75, 1, 0.75, 0), 0,
    )
    var same = zb.count == bb.count
    for i in range(min(zb.count, bb.count)):
        same = same and zb.depths[i] == bb.depths[i] and zb.points[i][0] == bb.points[i][0]
    s.check(same, "spec 0 is bit-identical to no spec")

    s.finish()
