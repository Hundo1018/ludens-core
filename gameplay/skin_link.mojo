"""Skinning wired to the runtime and the simulation (ROADMAP 17.65).

  * `animator_palette`: an `Animators` slot's local pose -> world pose
    (`to_world` with the skeleton's parents) -> skinning palette
    (world motor x inverse bind, `bind_palette`): the buffer a host shader
    or `skin_motor_k` consumes.
  * `pin_cloth_to_skin`: cloth vertices that hang on a skinned mesh (a
    cape on the shoulders) are pinned (inverse mass 0) and moved to their
    skinned vertex each step, with the velocity of that move, so the
    cloth's own step sees a kinematic target. `pin_softbody_to_skin` does
    the same for the particles of a volumetric `SoftBody` (a skinned
    belly or cheek driving a jiggle lattice): a particle with inverse
    mass 0 is kinematic there, so it stays on its pin through the step
    (until 17.65's fix `SoftBody.predict` pulled it 6.9e-5 m off per
    1/60 s step and `momentum` divided by its zero inverse mass).
  * `pin_fem_to_skin`: the same for the nodes of a tetrahedral `FemBody`
    (a muscle or fat volume riding a bone): pinned nodes (inverse mass 0)
    are placed on their skinned vertices and the elastic forces of the
    next step pull the free nodes along.
  * `fit_bone_boxes` / `fit_bone_capsules`: collision shapes per bone from
    the skinning weights -- the vertices a bone owns with weight >=
    `threshold`, in that bone's bind frame. Boxes come as (half extents,
    centre offset), the two arguments `Ragdoll` takes per bone, so a
    ragdoll is built from the mesh instead of hand-sized boxes; capsules
    as (local endpoints a, b, radius) along the box's longest axis.
    A bone that owns no vertex gets a zero box / capsule.
"""

from std.math import sqrt
from geometry.vec import Real, Vec3
from geometry.quat import Quat
from geometry.motor import Motor3
from geometry.skinning import bind_palette
from procedural.anim_graph import Pose, to_world
from physics.cloth import MeshCloth
from physics.softbody import SoftBody
from physics.fem import FemBody
from .animator import Animators


def animator_palette(anims: Animators, slot: Int, parent: List[Int], inverse_bind: List[Motor3]) raises -> List[Motor3]:
    if slot < 0 or slot >= len(anims.graphs):
        raise Error("animator_palette: no such animator slot")
    var n = len(anims.pos[slot]) // 3
    if len(parent) != n or len(inverse_bind) != n:
        raise Error("animator_palette: one parent and one inverse bind motor per bone")
    var local = Pose(n)
    local.pos = anims.pos[slot].copy()
    local.rot = anims.rot[slot].copy()
    var world = to_world(local, parent)
    var motors = List[Motor3](capacity=n)
    for b in range(n):
        motors.append(world.motor(b))
    return bind_palette(motors, inverse_bind)


def pin_cloth_to_skin(mut cloth: MeshCloth, cloth_vert: List[Int], skin_vert: List[Int], skinned: List[Vec3], dt: Real) raises:
    if len(cloth_vert) != len(skin_vert) or not (dt > 0):
        raise Error("pin_cloth_to_skin: one skinned vertex per cloth vertex, dt > 0")
    for k in range(len(cloth_vert)):
        var c = cloth_vert[k]
        var sv = skin_vert[k]
        if c < 0 or c >= len(cloth.x) or sv < 0 or sv >= len(skinned):
            raise Error("pin_cloth_to_skin: vertex index out of range")
        cloth.w[c] = 0
        cloth.v[c] = (skinned[sv] - cloth.x[c]) * (1 / dt)
        cloth.x[c] = skinned[sv]
        cloth.prev[c] = skinned[sv]


def pin_softbody_to_skin(mut body: SoftBody, pts: List[Int], skin_vert: List[Int], skinned: List[Vec3], dt: Real) raises:
    if len(pts) != len(skin_vert) or not (dt > 0):
        raise Error("pin_softbody_to_skin: one skinned vertex per particle, dt > 0")
    for k in range(len(pts)):
        var c = pts[k]
        var sv = skin_vert[k]
        if c < 0 or c >= len(body.pts) or sv < 0 or sv >= len(skinned):
            raise Error("pin_softbody_to_skin: index out of range")
        body.pts[c].w = 0
        body.pts[c].v = (skinned[sv] - body.pts[c].x) * (1 / dt)
        body.pts[c].x = skinned[sv]


def pin_fem_to_skin(mut body: FemBody, nodes: List[Int], skin_vert: List[Int], skinned: List[Vec3]) raises:
    """Pin `nodes[k]` of a tetrahedral body to `skinned[skin_vert[k]]`:
    inverse mass 0 (the FEM steps keep such nodes still, velocity 0) and
    position set; call before each body step with the frame's skinned
    vertices."""
    if len(nodes) != len(skin_vert):
        raise Error("pin_fem_to_skin: one skinned vertex per node")
    for k in range(len(nodes)):
        var c = nodes[k]
        var sv = skin_vert[k]
        if c < 0 or c >= body.node_count() or sv < 0 or sv >= len(skinned):
            raise Error("pin_fem_to_skin: index out of range")
        body.inv_m[c] = 0
        body.x[c] = skinned[sv][0]
        body.y[c] = skinned[sv][1]
        body.z[c] = skinned[sv][2]
        body.vx[c] = 0
        body.vy[c] = 0
        body.vz[c] = 0


def _owned_local(bind: Pose, rest: List[Vec3], idx: List[Int], w: List[Real], k: Int, bone: Int, threshold: Real) -> List[Vec3]:
    var q = bind.q(bone).conjugate()
    var p = bind.p(bone)
    var out = List[Vec3]()
    for v in range(len(rest)):
        for j in range(k):
            if idx[v * k + j] == bone and w[v * k + j] >= threshold:
                out.append(q.rotate(rest[v] - p))
                break
    return out^


def fit_bone_boxes(bind: Pose, rest: List[Vec3], idx: List[Int], w: List[Real], k: Int, threshold: Real = 0.5) raises -> Tuple[List[Vec3], List[Vec3]]:
    """(half extents, centre offset) per bone, in the bone's bind frame."""
    if len(idx) != len(rest) * k or len(w) != len(rest) * k:
        raise Error("fit_bone_boxes: K (index, weight) pairs per vertex")
    var halves = List[Vec3]()
    var offsets = List[Vec3]()
    for b in range(bind.bones):
        var pts = _owned_local(bind, rest, idx, w, k, b, threshold)
        if len(pts) == 0:
            halves.append(Vec3(0, 0, 0, 0))
            offsets.append(Vec3(0, 0, 0, 0))
            continue
        var lo = pts[0]
        var hi = pts[0]
        for p in pts:
            for a in range(3):
                lo[a] = min(lo[a], p[a])
                hi[a] = max(hi[a], p[a])
        halves.append((hi - lo) * 0.5)
        offsets.append((hi + lo) * 0.5)
    return (halves^, offsets^)


def fit_group_boxes(
    bind: Pose, rest: List[Vec3], idx: List[Int], w: List[Real], k: Int, body_of: List[Int], frame_of: List[Int],
    threshold: Real = 0.5,
) raises -> Tuple[List[Vec3], List[Vec3]]:
    """(half extents, centre offset) per body of a ragdoll whose bodies span several joints (ludens-engine#74): joint j
    belongs to body body_of[j] (-1: none), and body b's box is fitted to every vertex its joints own with weight >=
    `threshold`, in the bind frame of its frame bone frame_of[b]. A body that owns no vertex gets a zero box."""
    if len(idx) != len(rest) * k or len(w) != len(rest) * k:
        raise Error("fit_group_boxes: K (index, weight) pairs per vertex")
    if len(body_of) != bind.bones:
        raise Error("fit_group_boxes: one body index per joint")
    for b in body_of:
        if b >= len(frame_of):
            raise Error("fit_group_boxes: a joint names body " + String(b) + ", there are " + String(len(frame_of)))
    for f in frame_of:
        if f < 0 or f >= bind.bones:
            raise Error("fit_group_boxes: a frame bone is not a joint")
    var lo = List[Vec3](length=len(frame_of), fill=Vec3(0, 0, 0, 0))
    var hi = List[Vec3](length=len(frame_of), fill=Vec3(0, 0, 0, 0))
    var seen = List[Bool](length=len(frame_of), fill=False)
    for v in range(len(rest)):
        var counted = List[Bool](length=len(frame_of), fill=False)
        for j in range(k):
            var joint = idx[v * k + j]
            if joint < 0 or joint >= bind.bones or w[v * k + j] < threshold:
                continue
            var b = body_of[joint]
            if b < 0 or counted[b]:
                continue
            counted[b] = True
            var fb = frame_of[b]
            var p = bind.q(fb).conjugate().rotate(rest[v] - bind.p(fb))
            if not seen[b]:
                lo[b] = p
                hi[b] = p
                seen[b] = True
            else:
                for a in range(3):
                    lo[b][a] = min(lo[b][a], p[a])
                    hi[b][a] = max(hi[b][a], p[a])
    var halves = List[Vec3]()
    var offsets = List[Vec3]()
    for b in range(len(frame_of)):
        if seen[b]:
            halves.append((hi[b] - lo[b]) * 0.5)
            offsets.append((hi[b] + lo[b]) * 0.5)
        else:
            halves.append(Vec3(0, 0, 0, 0))
            offsets.append(Vec3(0, 0, 0, 0))
    return (halves^, offsets^)


def fit_bone_capsules(bind: Pose, rest: List[Vec3], idx: List[Int], w: List[Real], k: Int, threshold: Real = 0.5) raises -> Tuple[List[Vec3], List[Vec3], List[Real]]:
    """(a, b, radius) per bone in its bind frame: the segment runs along the
    longest axis of the fitted box through its centre, shortened by the
    radius at each end; the radius is the largest distance of an owned
    vertex from that axis line."""
    var boxes = fit_bone_boxes(bind, rest, idx, w, k, threshold)
    var ea = List[Vec3]()
    var eb = List[Vec3]()
    var rad = List[Real]()
    for b in range(bind.bones):
        var h = boxes[0][b]
        var c = boxes[1][b]
        var ax = 0
        if h[1] > h[ax]:
            ax = 1
        if h[2] > h[ax]:
            ax = 2
        var pts = _owned_local(bind, rest, idx, w, k, b, threshold)
        var r = Real(0)
        for p in pts:
            var d = p - c
            d[ax] = 0
            r = max(r, sqrt(d[0] * d[0] + d[1] * d[1] + d[2] * d[2]))
        var half_len = max(h[ax] - r, Real(0))
        var e = Vec3(0, 0, 0, 0)
        e[ax] = half_len
        ea.append(c - e)
        eb.append(c + e)
        rad.append(r)
    return (ea^, eb^, rad^)
