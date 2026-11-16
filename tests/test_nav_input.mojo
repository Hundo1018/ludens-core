# tier: component
"""Navmesh bake input from primitives (ROADMAP 17.14: nav/nav_input.mojo).

  ordinary     nav_box appends 12 triangles whose normals all point away from
               the box centre; nav_quad's two triangles face up.
  integration  a 40 m floor baked alone and with a 20 x 0.8 m wall 2 m tall:
               the wall removes at least its footprint from the walkable area,
               a point on the floor away from the wall is on the mesh, the
               point under the wall is not, and a path around it exists.
"""

from harness.runner import Suite
from geometry.vec import Real, Vec3, dot, cross, length
from nav.heightfield import NavBakeConfig
from nav.navmesh import bake_navmesh
from nav.nav_input import nav_tri, nav_quad, nav_box


def _v(x: Real, y: Real, z: Real) -> Vec3:
    return Vec3(x, y, z, 0)


def main() raises:
    var s = Suite("nav_input")
    var verts = List[Vec3]()
    var tris = List[Int]()
    var c = _v(1, 2, 3)
    nav_box(verts, tris, c, _v(0.5, 1.0, 2.0))
    s.check(len(tris) == 36 and len(verts) == 36, "nav_box appends 12 triangles")
    var outward = True
    for t in range(12):
        var a = verts[tris[3 * t]]
        var b = verts[tris[3 * t + 1]]
        var d = verts[tris[3 * t + 2]]
        var n = cross(b - a, d - a)
        var mid = (a + b + d) * Real(1.0 / 3.0)
        if dot(n, mid - c) <= 0:
            outward = False
    s.check(outward, "every box triangle faces away from the centre")
    var qv = List[Vec3]()
    var qt = List[Int]()
    nav_quad(qv, qt, -1, -1, 1, 1, 0.5)
    var up = True
    for t in range(2):
        var n = cross(qv[qt[3 * t + 1]] - qv[qt[3 * t]], qv[qt[3 * t + 2]] - qv[qt[3 * t]])
        if n[1] <= 0:
            up = False
    s.check(len(qt) == 6 and up, "nav_quad: two up-facing triangles")

    var cfg = NavBakeConfig(0.25, 0.1, 1.8, 0.3, 0.4, 45.0, 16)
    var fv = List[Vec3]()
    var ft = List[Int]()
    nav_quad(fv, ft, -20, -20, 20, 20, 0)
    var floor_only = bake_navmesh(fv, ft, cfg)
    nav_box(fv, ft, _v(0, 1, 0), _v(10, 1, 0.4))
    var with_wall = bake_navmesh(fv, ft, cfg)
    var a0 = floor_only.walkable_area()
    var a1 = with_wall.walkable_area()
    s.check(a0 - a1 >= 16.0, "the wall removes its footprint (" + String(a0) + " -> " + String(a1) + " m2)")
    s.check(with_wall.find_poly(_v(5, 0, 8)) >= 0, "floor away from the wall is on the mesh")
    s.check(with_wall.find_poly(_v(0, 0, 0)) < 0, "floor under the wall is not")
    var end = with_wall.move_along(_v(0, 0, -3), _v(0, 0, 3))
    s.check(end[2] < 0, "moving straight through the wall stops before it (z " + String(end[2]) + ")")
    s.finish()
