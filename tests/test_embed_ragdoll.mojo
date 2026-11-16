# tier: integration
"""A ragdoll built through an EmbedWorld (embed/ragdoll.mojo; ludens-engine#74).

  ordinary     a three-body figure (pelvis box, torso box, head sphere on two ball joints) built at (5, 0, 5) turned by
               0.6 rad: the bodies are where the spec puts them, turned; rest poses are recorded; after 2 s on a static
               floor it has fallen (pelvis below its start) and stays above the floor, joints holding (anchors within
               2 cm).
  parity       the same figure added by hand with add_box / add_sphere / teleport / add_ball_joint steps to the same
               body states bit for bit.
  extreme      remove takes every body and joint out; an empty spec, a joint naming a missing body and a zero mass
               raise.
"""

from std.math import sin, cos
from harness.runner import Suite
from geometry.vec import Real, Vec3, length
from geometry.quat import Quat
from embed.world import EmbedWorld
from embed.ragdoll import RagdollSpec, EmbedRagdoll


def _spec() -> RagdollSpec:
    var s = RagdollSpec()
    var pelvis = s.box(Vec3(0, 0.65, 0, 0), Vec3(0.11, 0.07, 0.08, 0), 12.0)
    var torso = s.box(Vec3(0.01, 0.92, -0.02, 0), Vec3(0.13, 0.2, 0.08, 0), 20.0)
    var head = s.sphere(Vec3(0.02, 1.22, -0.05, 0), 0.1, 5.0)
    s.ball(pelvis, torso, Vec3(0, 0.07, 0, 0), Vec3(-0.01, -0.2, 0.02, 0))
    s.ball(torso, head, Vec3(0.01, 0.2, -0.03, 0), Vec3(0, -0.1, 0, 0))
    return s^


def _world() raises -> EmbedWorld:
    var w = EmbedWorld(1.0 / 60.0, Vec3(0, -9.81, 0, 0))
    _ = w.add_box(Vec3(0, -0.5, 0, 0), Vec3(50, 0.5, 50, 0), 0.0, True)
    return w^


def main() raises:
    var s = Suite("embed_ragdoll")
    var at = Vec3(5, 0, 5, 0)
    var yaw = Real(0.6)
    var w = _world()
    var r = EmbedRagdoll.build(w, _spec(), at, yaw)
    var c = cos(yaw)
    var sn = sin(yaw)
    var want = Vec3(5 + c * 0.01 + sn * -0.02, 0.92, 5 - sn * 0.01 + c * -0.02, 0)
    s.check(len(r.bodies) == 3 and len(r.joints) == 2 and len(r.rest_pos) == 3, "3 bodies, 2 joints, 3 rest poses")
    s.check(length(r.rest_pos[1] - want) < 1e-5, "the torso is at the spec's centre, turned by the yaw and moved")
    s.check(abs(r.rest_rot[0].y - sin(yaw * 0.5)) < 1e-6, "every body is turned by the yaw about +Y")

    # the same figure by hand
    var w2 = _world()
    var p = w2.add_box(Vec3(5 + c * 0 + sn * 0, 0.65, 5 - sn * 0 + c * 0, 0), Vec3(0.11, 0.07, 0.08, 0), 12.0, False)
    var t = w2.add_box(want, Vec3(0.13, 0.2, 0.08, 0), 20.0, False)
    var hd = w2.add_sphere(Vec3(5 + c * 0.02 + sn * -0.05, 1.22, 5 - sn * 0.02 + c * -0.05, 0), 0.1, 5.0, False)
    var turn = Quat(0, sin(yaw * 0.5), 0, cos(yaw * 0.5))
    for h in [p, t, hd]:
        w2.teleport(h, w2.state(h).pos, turn)
    _ = w2.add_ball_joint(p, t, Vec3(0, 0.07, 0, 0), Vec3(-0.01, -0.2, 0.02, 0))
    _ = w2.add_ball_joint(t, hd, Vec3(0.01, 0.2, -0.03, 0), Vec3(0, -0.1, 0, 0))
    for _ in range(120):
        w.physics_tick()
        w2.physics_tick()
    var same = True
    var hand: List[Int64] = [p, t, hd]
    for i in range(3):
        var a = w.state(r.bodies[i])
        var b = w2.state(hand[i])
        same = same and a.pos[0] == b.pos[0] and a.pos[1] == b.pos[1] and a.pos[2] == b.pos[2] and a.rot.w == b.rot.w
    s.check(same, "built and hand-made figures step to the same states bit for bit (120 ticks)")
    var pel = w.state(r.bodies[0])
    s.check(pel.pos[1] < Real(0.65) and pel.pos[1] > Real(0.0), "after 2 s the pelvis has fallen and is above the floor (y " + String(pel.pos[1]) + ")")
    var ta = w.state(r.bodies[0])
    var tb = w.state(r.bodies[1])
    var ja = ta.pos + ta.rot.rotate(Vec3(0, 0.07, 0, 0))
    var jb = tb.pos + tb.rot.rotate(Vec3(-0.01, -0.2, 0.02, 0))
    s.check(length(ja - jb) < 0.02, "the pelvis-torso joint holds (" + String(length(ja - jb)) + " m apart)")

    var before = len(w.bodies())
    r.remove(w)
    s.check(len(w.bodies()) == before - 3 and len(r.bodies) == 0, "remove takes the 3 bodies out (" + String(before) + " -> " + String(len(w.bodies())) + ")")
    var raised = 0
    try:
        _ = EmbedRagdoll.build(w, RagdollSpec(), at, 0)
    except:
        raised += 1
    try:
        var bad = _spec()
        bad.ball(0, 7, Vec3(0, 0, 0, 0), Vec3(0, 0, 0, 0))
        _ = EmbedRagdoll.build(w, bad, at, 0)
    except:
        raised += 1
    try:
        var zero = RagdollSpec()
        _ = zero.box(Vec3(0, 1, 0, 0), Vec3(0.1, 0.1, 0.1, 0), 0.0)
        _ = EmbedRagdoll.build(w, zero, at, 0)
    except:
        raised += 1
    s.check(raised == 3, "an empty spec, a missing body and a zero mass raise (" + String(raised) + ")")
    s.finish()
