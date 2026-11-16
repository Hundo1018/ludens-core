"""Example 28 — a ragdoll in an EmbedWorld (ludens-engine#74; embed/ragdoll.mojo).

A six-body figure (pelvis, torso, head, two thighs, an arm) on ball joints is built at (2, 0, 3) turned by 0.8 rad, pushed
sideways and stepped for 2 s on a floor with a crate. Printed every half second: the pelvis and head heights; then the
figure is removed and the body count printed.

Run:

    pixi run mojo run -I build examples/28_ragdoll_embed.mojo
"""

from geometry.vec import Real, Vec3
from embed.world import EmbedWorld
from embed.ragdoll import RagdollSpec, EmbedRagdoll


def main() raises:
    var w = EmbedWorld(1.0 / 60.0, Vec3(0, -9.81, 0, 0))
    _ = w.add_box(Vec3(0, -0.5, 0, 0), Vec3(50, 0.5, 50, 0), 0.0, True)
    _ = w.add_box(Vec3(3, 0.3, 3, 0), Vec3(0.3, 0.3, 0.3, 0), 10.0, False)
    var s = RagdollSpec()
    var pelvis = s.box(Vec3(0, 0.65, 0, 0), Vec3(0.11, 0.07, 0.08, 0), 12.0)
    var torso = s.box(Vec3(0.01, 0.92, -0.02, 0), Vec3(0.13, 0.2, 0.08, 0), 20.0)
    var head = s.sphere(Vec3(0.02, 1.22, -0.05, 0), 0.1, 5.0)
    var lthigh = s.box(Vec3(0.087, 0.426, 0.03, 0), Vec3(0.05, 0.14, 0.05, 0), 7.0)
    var rthigh = s.box(Vec3(-0.054, 0.439, 0.07, 0), Vec3(0.05, 0.14, 0.05, 0), 7.0)
    var arm = s.box(Vec3(0.124, 0.898, -0.06, 0), Vec3(0.04, 0.13, 0.04, 0), 4.0)
    s.ball(pelvis, torso, Vec3(0, 0.07, 0, 0), Vec3(-0.01, -0.2, 0.02, 0))
    s.ball(torso, head, Vec3(0.01, 0.2, -0.03, 0), Vec3(0, -0.1, 0, 0))
    s.ball(pelvis, lthigh, Vec3(0.066, -0.093, 0.025, 0), Vec3(-0.021, 0.13, -0.005, 0))
    s.ball(pelvis, rthigh, Vec3(-0.069, -0.084, 0.038, 0), Vec3(-0.015, 0.127, -0.032, 0))
    s.ball(torso, arm, Vec3(0.102, 0.097, -0.02, 0), Vec3(-0.012, 0.119, 0.02, 0))
    var r = EmbedRagdoll.build(w, s, Vec3(2, 0, 3, 0), 0.8)
    for h in r.bodies:
        w.set_velocity(h, Vec3(2.5, 0, 0, 0), Vec3(0, 0, 0, 0))
    for tick in range(1, 121):
        w.physics_tick()
        if tick % 30 == 0:
            print("t", Real(tick) / 60, "s: pelvis y", w.state(r.bodies[0]).pos[1], "head y", w.state(r.bodies[2]).pos[1])
    var before = len(w.bodies())
    r.remove(w)
    print("bodies", before, "->", len(w.bodies()), "after remove")
