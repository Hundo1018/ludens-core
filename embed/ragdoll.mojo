"""A ragdoll built through an EmbedWorld (ludens-engine#74): `gameplay.ragdoll.Ragdoll` takes a raw ContactScene6, which an
EmbedWorld owns, so a host world could not hold one.

A `RagdollSpec` lists bodies (box or sphere, centre and half extents in the figure's own frame, mass) and ball joints
between them (two body indices and an anchor in each body's frame). `EmbedRagdoll.build` places the figure at a ground
position turned by a yaw about +Y, adds its bodies and joints through the world's public API (so they collide with
everything else in it), and keeps each body's pose at that moment (`rest_pos`, `rest_rot`: what a skinned mesh's
deltas are measured from). `remove` takes the joints and the bodies out again.
"""

from geometry.trig import sin, cos
from geometry.vec import Real, Vec3
from geometry.quat import Quat
from .world import EmbedWorld

comptime RAG_BOX = 0
comptime RAG_SPHERE = 1


struct RagdollSpec(Copyable, Movable):
    var kind: List[Int]  # RAG_BOX / RAG_SPHERE
    var centre: List[Vec3]  # in the figure's frame (y up, the ground at y 0)
    var half: List[Vec3]  # a sphere's radius is half[0]
    var mass: List[Real]
    var joint_a: List[Int]
    var joint_b: List[Int]
    var anchor_a: List[Vec3]  # in body a's frame
    var anchor_b: List[Vec3]

    def __init__(out self):
        self.kind = List[Int]()
        self.centre = List[Vec3]()
        self.half = List[Vec3]()
        self.mass = List[Real]()
        self.joint_a = List[Int]()
        self.joint_b = List[Int]()
        self.anchor_a = List[Vec3]()
        self.anchor_b = List[Vec3]()

    def box(mut self, centre: Vec3, half: Vec3, mass: Real) -> Int:
        self.kind.append(RAG_BOX)
        self.centre.append(centre)
        self.half.append(half)
        self.mass.append(mass)
        return len(self.kind) - 1

    def sphere(mut self, centre: Vec3, radius: Real, mass: Real) -> Int:
        self.kind.append(RAG_SPHERE)
        self.centre.append(centre)
        self.half.append(Vec3(radius, radius, radius, 0))
        self.mass.append(mass)
        return len(self.kind) - 1

    def ball(mut self, a: Int, b: Int, anchor_a: Vec3, anchor_b: Vec3):
        self.joint_a.append(a)
        self.joint_b.append(b)
        self.anchor_a.append(anchor_a)
        self.anchor_b.append(anchor_b)

    def bodies(self) -> Int:
        return len(self.kind)


def _turned(pos: Vec3, c: Real, s: Real, p: Vec3) -> Vec3:
    """A figure-frame point turned by the yaw (cos c, sin s) about +Y and moved to pos on the ground (pos.y ignored)."""
    return Vec3(pos[0] + c * p[0] + s * p[2], p[1], pos[2] - s * p[0] + c * p[2], 0)


struct EmbedRagdoll(Movable):
    var bodies: List[Int64]
    var joints: List[Int]
    var rest_pos: List[Vec3]
    var rest_rot: List[Quat]

    def __init__(out self):
        self.bodies = List[Int64]()
        self.joints = List[Int]()
        self.rest_pos = List[Vec3]()
        self.rest_rot = List[Quat]()

    @staticmethod
    def build(mut world: EmbedWorld, spec: RagdollSpec, pos: Vec3, yaw: Real) raises -> Self:
        """Add the figure at ground position `pos`, turned by `yaw` about +Y. Raises on a bad spec (no bodies, a joint
        naming a body that is not there, a mass that is not positive)."""
        if spec.bodies() == 0:
            raise Error("EmbedRagdoll.build: the spec has no bodies")
        for i in range(spec.bodies()):
            if not (spec.mass[i] > 0):
                raise Error("EmbedRagdoll.build: body " + String(i) + " needs a positive mass")
        for k in range(len(spec.joint_a)):
            if spec.joint_a[k] < 0 or spec.joint_a[k] >= spec.bodies() or spec.joint_b[k] < 0 or spec.joint_b[k] >= spec.bodies():
                raise Error("EmbedRagdoll.build: joint " + String(k) + " names a body that is not in the spec")
        var out = Self()
        var c = cos(yaw)
        var s = sin(yaw)
        var q = Quat(0, sin(yaw * 0.5), 0, cos(yaw * 0.5))
        for i in range(spec.bodies()):
            var at = _turned(pos, c, s, spec.centre[i])
            var h: Int64
            if spec.kind[i] == RAG_SPHERE:
                h = world.add_sphere(at, spec.half[i][0], spec.mass[i], False)
            else:
                h = world.add_box(at, spec.half[i], spec.mass[i], False)
            out.bodies.append(h)
        for h in out.bodies:
            world.teleport(h, world.state(h).pos, q)
        for k in range(len(spec.joint_a)):
            out.joints.append(world.add_ball_joint(out.bodies[spec.joint_a[k]], out.bodies[spec.joint_b[k]], spec.anchor_a[k], spec.anchor_b[k]))
        for h in out.bodies:
            var st = world.state(h)
            out.rest_pos.append(st.pos)
            out.rest_rot.append(st.rot)
        return out^

    def remove(mut self, mut world: EmbedWorld) raises:
        """Take the joints, then the bodies, out of the world."""
        for j in self.joints:
            world.remove_joint(j)
        for h in self.bodies:
            world.remove(h)
        self.joints.clear()
        self.bodies.clear()
        self.rest_pos.clear()
        self.rest_rot.clear()
