"""Navigation end to end (ROADMAP 17.14).

Bake a navmesh from a level (floor, a wall with a doorway, a raised platform
reached by a ramp), plan one path, then walk a 20-agent ORCA crowd through
the doorway to the platform, and drop a crate into the doorway as a dynamic
obstacle: agents whose corridor it cuts re-plan, find no route (the doorway
is the only one) and wait, retrying on their cooldown until the crate is
removed.

Run: pixi run mojo run -I build examples/26_navigation_crowd.mojo
"""

from geometry.vec import Real, Vec3
from nav.heightfield import NavBakeConfig
from nav.navmesh import bake_navmesh
from nav.nav_input import nav_quad, nav_box
from nav.path import PolyFunnel
from nav.crowd import Crowd, CrowdParams, Orca


def _v(x: Real, y: Real, z: Real) -> Vec3:
    return Vec3(x, y, z, 0)


def _quad(mut v: List[Vec3], mut t: List[Int], x0: Real, z0: Real, x1: Real, z1: Real, y0: Real, y1: Real):
    """Up-facing quad, height y0 at x0 -> y1 at x1."""
    var n = len(v)
    v.append(_v(x0, y0, z0))
    v.append(_v(x0, y0, z1))
    v.append(_v(x1, y1, z0))
    v.append(_v(x1, y1, z1))
    for k in [0, 1, 2, 2, 1, 3]:
        t.append(n + k)


def _wall(mut v: List[Vec3], mut t: List[Int], x0: Real, z0: Real, x1: Real, z1: Real, h: Real):
    """Box from the floor to height h (nav.nav_input.nav_box)."""
    nav_box(v, t, _v((x0 + x1) / 2, h / 2, (z0 + z1) / 2), _v((x1 - x0) / 2, h / 2, (z1 - z0) / 2))


def main() raises:
    var v = List[Vec3]()
    var t = List[Int]()
    nav_quad(v, t, 0, 0, 20, 20, 0)  # floor
    _wall(v, t, 9.75, 0, 10.25, 8.5, 2.5)  # wall at x = 10 with a 3 m doorway at z 8.5..11.5
    _wall(v, t, 9.75, 11.5, 10.25, 20, 2.5)
    _quad(v, t, 20, 6, 26, 14, 0, 1.5)  # ramp up to x = 26
    nav_quad(v, t, 26, 6, 32, 14, 1.5)  # platform
    var cfg = NavBakeConfig(0.25, 0.1, 1.8, 0.3, 0.4, 45.0, 16)
    var mesh = bake_navmesh(v, t, cfg)
    print("navmesh:", mesh.poly_count(), "polygons,", mesh.link_count(), "links, walkable", mesh.walkable_area(), "m^2")

    var pf = PolyFunnel()
    var path = pf.find(mesh, _v(2, 0, 2), _v(30, 1.5, 10))
    print("path found:", path.found, "length", path.length(), "m, corners", len(path.points) - 2)
    for p in path.points:
        print("  ", p[0], p[1], p[2])

    var crowd = Crowd[Orca](Orca(), CrowdParams.default())
    for i in range(20):
        _ = crowd.add_agent(mesh, _v(2 + Real(i % 5) * 1.2, 0, 4 + Real(i // 5) * 1.5), 0.3, 1.4)
    for i in range(20):
        _ = crowd.set_target(mesh, i, _v(27 + Real(i % 5) * 1.0, 1.5, 7 + Real(i // 5) * 1.5))
    var dt = Real(1.0 / 30.0)
    var crate = -1
    for k in range(60 * 30):
        if k == 150:
            crate = mesh.add_obstacle(_v(9, -0.5, 8.5), _v(11, 1.0, 11.5))
            print("t =", Real(k) * dt, "s: crate dropped in the doorway, tiles rebuilt", mesh.update())
        if k == 450:
            mesh.remove_obstacle(crate)
            print("t =", Real(k) * dt, "s: crate removed, tiles rebuilt", mesh.update())
        crowd.step(mesh, dt)
        if k == 300:
            var waiting = 0
            for i in range(20):
                if not crowd.arrived[i] and not crowd.has_target[i]:
                    waiting += 1
            print("t =", Real(k) * dt, "s:", waiting, "agents waiting for a route")
        if crowd.all_arrived():
            print("all 20 agents arrived at t =", Real(k + 1) * dt, "s; min separation", crowd.min_separation(), "m; replans", crowd.replans)
            return
    var n = 0
    for i in range(20):
        if crowd.arrived[i]:
            n += 1
    print("after 60 s:", n, "of 20 arrived")
