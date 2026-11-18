"""Fixed hull workload for a function-level instruction profile (ROADMAP 17.98 item 5; `scripts/fn_share.py`):
40 convex hulls (a 0.25 box with two corners cut, 10 vertices) piled on a static box floor, 60 steps of step_soft:
the hull-vs-hull and hull-vs-box pairs go through ColliderSet.hull_faces_d / as_hull_d."""
from std.benchmark import keep
from geometry.vec import Real, Vec3
from physics.rigid6 import QuatBody6, Inertia3
from physics.solver6 import ContactScene6


def _verts(h: Real) -> List[Real]:
    var v = List[Real](capacity=30)
    for sx in range(2):
        for sy in range(2):
            for sz in range(2):
                var x = h * (Real(1) if sx == 1 else Real(-1))
                var y = h * (Real(1) if sy == 1 else Real(-1))
                var z = h * (Real(1) if sz == 1 else Real(-1))
                if sx == 1 and sy == 1:
                    v.append(x * 0.6)
                    v.append(y)
                    v.append(z)
                    v.append(x)
                    v.append(y * 0.6)
                    v.append(z)
                else:
                    v.append(x)
                    v.append(y)
                    v.append(z)
    return v^


def main():
    var sc = ContactScene6[QuatBody6]()
    _ = sc.add(QuatBody6.at_rest(Vec3(0, -0.5, 0, 0), Inertia3.box(1, 20, 0.5, 20)), Vec3(20, 0.5, 20, 0), True)
    for k in range(40):
        _ = sc.add_hull(
            QuatBody6.at_rest(
                Vec3(Real(k % 5) * 0.6 - 1.2, 0.3 + Real(k // 5) * 0.55, Real(k % 3) * 0.1, 0),
                Inertia3.box(1, 0.25, 0.25, 0.25),
            ),
            _verts(0.25), False,
        )
    for _ in range(60):
        sc.step_soft(1.0 / 60.0, Vec3(0, -9.8, 0, 0))
    keep(sc.bset.bodies[3].pos[1])
