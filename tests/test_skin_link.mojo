# tier: integration
"""Skinning wired to the runtime and simulation (ROADMAP 17.65,
`gameplay.skin_link`).

Skeleton: bone 0 at (0, 0.9, 0), bone 1 0.5 above it (local), bind pose
unrotated. Mesh: a cylinder of radius 0.2 from y 0.9 to y 2.9 in rings of
8 every 0.1 m, rings below y 1.9 on bone 0, the rest on bone 1.

  1. Palette from an `Animators` slot: at the bind pose every palette
     entry moves nothing (1e-6); with bone 1 turned 90 deg about z, the
     vertex at (0, 2.4, 0) on bone 1 goes to (-1.0, 1.4, 0) (rotation about
     the joint at y 1.4).
  2. Cloth pinned to skinned vertices: after pinning and the cloth's own
     step, the pinned vertices sit exactly on their skinned vertices.
  3. Fitted shapes: bone 0's box half extents (0.2, 0.45, 0.2) about
     (0, 0.45, 0) in its frame; capsule radius 0.2 along y 0.2 .. 0.7; a `Ragdoll`
     built from the fitted boxes stands up for 1 s (simulated bone 1 hangs
     on the kinematic bone 0 and stays finite).
"""

from std.math import sin, cos, isfinite
from harness.runner import Suite
from geometry.vec import Real, Vec3, length
from geometry.quat import Quat
from geometry.motor import Motor3
from geometry.skinning import skin_motor_k, inverse_bind
from procedural.anim import AnimClip
from procedural.anim_events import EventTrack
from procedural.anim_state import AnimGraph
from procedural.anim_graph import Pose, to_world
from physics.cloth import MeshCloth, grid_mesh
from physics.rigid6 import QuatBody6
from physics.solver6 import ContactScene6
from physics.solver_config import SolverConfig
from gameplay.animator import AnimLibrary, Animators
from gameplay.ragdoll import Ragdoll
from gameplay.skin_link import animator_palette, pin_cloth_to_skin, fit_bone_boxes, fit_bone_capsules, fit_group_boxes


def clip(angle: Real) raises -> AnimClip:
    var c = AnimClip(2, 2, 10, True)
    var q = Quat.from_axis_angle(Vec3(0, 0, 1, 0), angle)
    for f in range(2):
        c.set_key(f, 0, Vec3(0, 0.9, 0, 0), Quat(0, 0, 0, 1))
        c.set_key(f, 1, Vec3(0, 0.5, 0, 0), q)
    return c^


def bind_world() -> Pose:
    var local = Pose(2)
    local.set(0, Vec3(0, 0.9, 0, 0), Quat(0, 0, 0, 1))
    local.set(1, Vec3(0, 0.5, 0, 0), Quat(0, 0, 0, 1))
    return to_world(local, [-1, 0])


def palette_for(angle: Real) raises -> List[Motor3]:
    var lib = AnimLibrary()
    _ = lib.add(clip(angle), EventTrack())
    var g = AnimGraph(2)
    _ = g.add_state(0, 1.0)
    var an = Animators()
    var slot = an.add(g^)
    an.tick_all(lib, 0.01)
    var bw = bind_world()
    var bm: List[Motor3] = [bw.motor(0), bw.motor(1)]
    return animator_palette(an, slot, [-1, 0], inverse_bind(bm))


def main() raises:
    var s = Suite("skin_link")
    # mesh
    var rest = List[Vec3]()
    var idx = List[Int]()
    var w = List[Real]()
    for r in range(21):
        var y = 0.9 + 0.1 * Real(r)
        for k in range(8):
            var a = Real(k) * 0.785398163
            rest.append(Vec3(0.2 * cos(a), y, 0.2 * sin(a), 0))
            idx.append(0 if y < 1.85 else 1)
            w.append(1.0)

    # 1. palette
    var p0 = palette_for(0)
    var out = List[Vec3](length=len(rest), fill=Vec3(0, 0, 0, 0))
    skin_motor_k(p0, rest, idx, w, 1, out)
    var worst = Real(0)
    for v in range(len(rest)):
        worst = max(worst, length(out[v] - rest[v]))
    var p90 = palette_for(1.5707963)
    var tip: List[Vec3] = [Vec3(0, 2.4, 0, 0)]
    var tip_out: List[Vec3] = [Vec3(0, 0, 0, 0)]
    skin_motor_k(p90, tip, [1], [1.0], 1, tip_out)
    print("bind pose: worst vertex move", worst, "   bone 1 at 90 deg: (0, 2.4, 0) ->", tip_out[0][0], tip_out[0][1], tip_out[0][2])
    s.check(worst < 1e-6, "bind pose palette moves nothing")
    s.check(length(tip_out[0] - Vec3(-1.0, 1.4, 0, 0)) < 1e-5, "animated palette rotates bone 1's vertices about its joint")

    # 2. cloth pinned to the skinned mesh: top two corners on two top-ring vertices
    skin_motor_k(p90, rest, idx, w, 1, out)
    var m = grid_mesh(4, 4, 0.3, 0.3, Vec3(-0.15, 2.9, -0.15, 0))
    var cloth = MeshCloth(m[0], m[1], 0.2, 0, 1e-3)
    var top = 20 * 8
    pin_cloth_to_skin(cloth, [0, 4], [top, top + 4], out, 1.0 / 60.0)
    cloth.advance(1.0 / 60.0, Vec3(0, -9.8, 0, 0))
    var pinned_ok = length(cloth.x[0] - out[top]) == 0 and length(cloth.x[4] - out[top + 4]) == 0
    s.check(pinned_ok and cloth.w[0] == 0, "pinned cloth vertices sit on their skinned vertices after the cloth step")

    # 3. fitted boxes / capsules and a ragdoll from them
    var bw = bind_world()
    var boxes = fit_bone_boxes(bw, rest, idx, w, 1)
    var half = boxes[0].copy()
    var off = boxes[1].copy()
    var caps = fit_bone_capsules(bw, rest, idx, w, 1)
    var ca = caps[0].copy()
    var cb = caps[1].copy()
    var cr = caps[2].copy()
    print("bone 0 box half", half[0][0], half[0][1], half[0][2], " offset", off[0][1], "  capsule radius", cr[0], " axis", ca[0][1], "..", cb[0][1])
    s.check(abs(half[0][0] - 0.2) < 1e-5 and abs(half[0][1] - 0.45) < 1e-5 and abs(off[0][1] - 0.45) < 1e-5, "bone 0 box: half (0.2, 0.45, 0.2) about y 0.45 in its frame")
    s.check(abs(cr[0] - 0.2) < 1e-5 and abs(ca[0][1] - 0.2) < 1e-5 and abs(cb[0][1] - 0.7) < 1e-5, "bone 0 capsule: radius 0.2 along y from 0.2 to 0.7")
    # group fit (ludens-engine#74): both bones as one body in bone 0's frame; bone 1 alone matches fit_bone_boxes
    var g1 = fit_group_boxes(bw, rest, idx, w, 1, [0, 0], [0])
    s.check(abs(g1[0][0][1] - 1.0) < 1e-5 and abs(g1[1][0][1] - 1.0) < 1e-5 and abs(g1[0][0][0] - 0.2) < 1e-5,
            "one body over both bones: half y 1.0 about y 1.0 in bone 0's frame (" + String(g1[0][0][1]) + ")")
    var g2 = fit_group_boxes(bw, rest, idx, w, 1, [-1, 0], [1])
    s.check(abs(g2[0][0][1] - half[1][1]) < 1e-6 and abs(g2[1][0][1] - off[1][1]) < 1e-6,
            "a body of bone 1 alone, in its own frame, is fit_bone_boxes' bone 1 box")
    var g3 = fit_group_boxes(bw, rest, idx, w, 1, [-1, -1], [0])
    s.check(g3[0][0][0] == 0 and g3[0][0][1] == 0, "a body that owns no vertex gets a zero box")
    var graised = 0
    try:
        _ = fit_group_boxes(bw, rest, idx, w, 1, [0, 2], [0])
    except:
        graised += 1
    try:
        _ = fit_group_boxes(bw, rest, idx, w, 1, [0, 0], [5])
    except:
        graised += 1
    s.check(graised == 2, "a body index past the frame list and a frame bone that is not a joint raise")
    var sc = ContactScene6[QuatBody6]()
    var rd = Ragdoll(sc, bw, [-1, 0], half, off.copy(), [False, True])
    var cfg = SolverConfig()
    for _ in range(60):
        sc.step(1.0 / 60.0, Vec3(0, -9.8, 0, 0), cfg)
    var b1 = sc.bset.bodies[rd.ids[1].index()].pos
    print("ragdoll bone 1 body after 1 s:", b1[0], b1[1], b1[2])
    s.check(isfinite(b1[0]) and isfinite(b1[1]) and b1[1] > 1.0, "ragdoll from fitted boxes hangs on its kinematic root, finite")
    s.finish()
