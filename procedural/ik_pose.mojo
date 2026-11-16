"""IK results written back into a `Pose` as per-bone rotations (ROADMAP 17.3 leftover).

`procedural.ik` solves on joint positions; this module turns a two-bone
solution into rotations of the bones themselves, so the result can be skinned
or blended like any other pose.

The pose here is a world (model-space) pose, as `anim_graph.to_world` returns;
`to_local` takes it back to parent-relative transforms. `two_bone_pose` makes
two rigid rotations:

  1. the subtree of `root` about the root joint, by the shortest arc taking
     the mid joint's direction onto the solved mid joint;
  2. the subtree of `mid` about the solved mid joint, by the shortest arc
     taking the end joint's direction onto the solved end.

Each bone b in a rotated subtree gets p' = pivot + r(p - pivot) and q' = r q,
so every bone keeps its transform relative to its parent except `root` and
`mid` themselves, and bone lengths are kept.
"""

from std.math import sqrt
from geometry.vec import Real, Vec3, dot, cross, length
from geometry.quat import Quat
from .ik import two_bone, TwoBone
from .anim_graph import Pose


def shortest_arc(a: Vec3, b: Vec3) -> Quat:
    """The smallest rotation taking direction `a` onto direction `b` (identity when either is zero).
    Opposite directions turn by pi about an axis perpendicular to `a`."""
    var la = length(a)
    var lb = length(b)
    if la < 1e-12 or lb < 1e-12:
        return Quat.identity()
    var c = cross(a, b)
    var w = la * lb + dot(a, b)
    if w < 1e-9 * la * lb:
        # a and b opposite: any axis perpendicular to a
        var axis = cross(a, Vec3(1, 0, 0, 0))
        if length(axis) < 1e-6 * la:
            axis = cross(a, Vec3(0, 1, 0, 0))
        var n = length(axis)
        return Quat(axis[0] / n, axis[1] / n, axis[2] / n, 0)
    return Quat(c[0], c[1], c[2], w).normalized()


def in_subtree(parent: List[Int], b: Int, top: Int) -> Bool:
    """Whether bone `b` is `top` or one of its descendants."""
    var k = b
    while k >= 0:
        if k == top:
            return True
        k = parent[k]
    return False


def rotate_subtree(mut pose: Pose, parent: List[Int], top: Int, pivot: Vec3, r: Quat):
    """Rotate bone `top` and every descendant rigidly by `r` about `pivot` (a world pose)."""
    for b in range(pose.bones):
        if in_subtree(parent, b, top):
            var p = pivot + r.rotate(pose.p(b) - pivot)
            pose.set(b, p, (r * pose.q(b)).normalized())


def two_bone_pose(
    mut pose: Pose, parent: List[Int], root: Int, mid: Int, end: Int, target: Vec3, pole: Vec3
) -> TwoBone:
    """Solve `procedural.ik.two_bone` on the joints `root`, `mid`, `end` of a world pose and write the result
    back as rotations of the root's and the mid's subtrees. Returns the solution (positions, reached)."""
    var pr = pose.p(root)
    var pm = pose.p(mid)
    var pe = pose.p(end)
    var tb = two_bone(pr, pm, pe, target, pole)
    rotate_subtree(pose, parent, root, pr, shortest_arc(pm - pr, tb.mid - pr))
    var pm1 = pose.p(mid)
    var pe1 = pose.p(end)
    rotate_subtree(pose, parent, mid, pm1, shortest_arc(pe1 - pm1, tb.end - pm1))
    return tb


def to_local(world: Pose, parent: List[Int]) -> Pose:
    """The inverse of `anim_graph.to_world`: local(b) = world(parent[b])^-1 * world(b)."""
    var out = Pose(world.bones)
    for b in range(world.bones):
        var p = world.p(b)
        var q = world.q(b)
        if parent[b] >= 0:
            var qi = world.q(parent[b]).conjugate()
            p = qi.rotate(p - world.p(parent[b]))
            q = (qi * q).normalized()
        out.set(b, p, q)
    return out^
