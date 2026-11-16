"""Navmesh bake input built from primitives (ROADMAP 17.14).

`bake_navmesh` takes a triangle soup (`verts`, `tris`). Games that lay out a
level from boxes need the same two helpers to build it: `nav_tri` appends one
triangle, `nav_box` appends a box as 12 outward-facing triangles. A box's side
faces are vertical, steeper than any `max_slope`, so the bake marks only its
top as walkable; a box taller than `agent_height` minus `max_climb` is an
obstacle. `nav_quad` appends a horizontal floor rectangle (two up-facing
triangles).
"""

from geometry.vec import Real, Vec3


def nav_tri(mut verts: List[Vec3], mut tris: List[Int], a: Vec3, b: Vec3, c: Vec3):
    """Append the triangle (a, b, c)."""
    var n = len(verts)
    verts.append(a)
    verts.append(b)
    verts.append(c)
    tris.append(n)
    tris.append(n + 1)
    tris.append(n + 2)


def nav_quad(mut verts: List[Vec3], mut tris: List[Int], x0: Real, z0: Real, x1: Real, z1: Real, y: Real):
    """Append the floor rectangle [x0, x1] x [z0, z1] at height y as two up-facing triangles."""
    nav_tri(verts, tris, Vec3(x0, y, z0, 0), Vec3(x0, y, z1, 0), Vec3(x1, y, z0, 0))
    nav_tri(verts, tris, Vec3(x1, y, z0, 0), Vec3(x0, y, z1, 0), Vec3(x1, y, z1, 0))


def nav_box(mut verts: List[Vec3], mut tris: List[Int], c: Vec3, h: Vec3):
    """Append the box with centre `c` and half extents `h` as 12 outward-facing triangles."""
    var x0 = c[0] - h[0]
    var x1 = c[0] + h[0]
    var y0 = c[1] - h[1]
    var y1 = c[1] + h[1]
    var z0 = c[2] - h[2]
    var z1 = c[2] + h[2]
    # -x, +x
    nav_tri(verts, tris, Vec3(x0, y0, z0, 0), Vec3(x0, y0, z1, 0), Vec3(x0, y1, z0, 0))
    nav_tri(verts, tris, Vec3(x0, y0, z1, 0), Vec3(x0, y1, z1, 0), Vec3(x0, y1, z0, 0))
    nav_tri(verts, tris, Vec3(x1, y0, z0, 0), Vec3(x1, y1, z0, 0), Vec3(x1, y0, z1, 0))
    nav_tri(verts, tris, Vec3(x1, y0, z1, 0), Vec3(x1, y1, z0, 0), Vec3(x1, y1, z1, 0))
    # -z, +z
    nav_tri(verts, tris, Vec3(x0, y0, z0, 0), Vec3(x0, y1, z0, 0), Vec3(x1, y0, z0, 0))
    nav_tri(verts, tris, Vec3(x1, y0, z0, 0), Vec3(x0, y1, z0, 0), Vec3(x1, y1, z0, 0))
    nav_tri(verts, tris, Vec3(x0, y0, z1, 0), Vec3(x1, y0, z1, 0), Vec3(x0, y1, z1, 0))
    nav_tri(verts, tris, Vec3(x1, y0, z1, 0), Vec3(x1, y1, z1, 0), Vec3(x0, y1, z1, 0))
    # top (up-facing) and bottom
    nav_tri(verts, tris, Vec3(x0, y1, z0, 0), Vec3(x0, y1, z1, 0), Vec3(x1, y1, z0, 0))
    nav_tri(verts, tris, Vec3(x1, y1, z0, 0), Vec3(x0, y1, z1, 0), Vec3(x1, y1, z1, 0))
    nav_tri(verts, tris, Vec3(x0, y0, z0, 0), Vec3(x1, y0, z0, 0), Vec3(x0, y0, z1, 0))
    nav_tri(verts, tris, Vec3(x1, y0, z0, 0), Vec3(x1, y0, z1, 0), Vec3(x0, y0, z1, 0))
