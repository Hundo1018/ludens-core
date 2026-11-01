"""Camera rigs that need the scene (ROADMAP 17.68).

  * `SpringArm`: a third-person boom from a target point at yaw / pitch and
    `length`. A sphere of `radius` is cast from the target toward the
    desired camera position; on a hit the arm shortens at once to stop in
    front of the surface (pulling in is never smoothed -- that is how a
    camera ends up inside a wall), and lets out again with a critically
    damped spring (`procedural.camera_math.spring_damp`).
  * `CameraBrain`: several candidate cameras with priorities; the highest
    priority wins, and a change of winner blends position, orientation and
    field of view over `blend_time` with an easing curve.
"""

from std.math import isfinite
from geometry.trig import cos, sin
from geometry.vec import Real, Vec3, length
from geometry.quat import Quat, slerp
from collision.world_query import QueryFilter
from collision.broadphase import BroadPhase
from physics.rigid6 import Body6
from physics.solver6 import ContactScene6
from procedural.camera_math import CameraPose, look_rotation, spring_damp
from procedural.tween import ease_dyn


struct SpringArm(Copyable, Movable):
    var length: Real
    var radius: Real
    var skin: Real
    var yaw: Real
    var pitch: Real
    var half_life: Real
    var fov_y: Real
    var arm: Real  # current arm length
    var arm_v: Real
    var filter: QueryFilter

    def __init__(out self, length: Real, radius: Real = 0.2, half_life: Real = 0.15, fov_y: Real = 1.0):
        self.length = length
        self.radius = radius
        self.skin = 0.02
        self.yaw = 0
        self.pitch = 0.3
        self.half_life = half_life
        self.fov_y = fov_y
        self.arm = length
        self.arm_v = 0
        self.filter = QueryFilter.all()

    def aim(mut self, yaw: Real, pitch: Real):
        """Set the boom angles. Use this rather than assigning the fields
        in a loop that also calls `update`: that pattern sent the Mojo 1.1
        compiler into a loop (bench_sequence, test_movement)."""
        self.yaw = yaw
        self.pitch = pitch

    def direction(self) -> Vec3:
        """From the target toward the camera."""
        return Vec3(sin(self.yaw) * cos(self.pitch), sin(self.pitch), cos(self.yaw) * cos(self.pitch), 0)

    def update[B: Body6, BP: BroadPhase](mut self, sc: ContactScene6[B, BP], target_in: Vec3, dt: Real) -> CameraPose:
        var target = target_in
        if not (isfinite(target[0]) and isfinite(target[1]) and isfinite(target[2])):
            target = Vec3(0, 0, 0, 0)
        var d = self.direction()
        var h = sc.sphere_cast(target, self.radius, d, self.length + self.skin, self.filter)
        var allowed = self.length
        if h.hit:
            allowed = max(Real(0), h.t - self.skin)
        if allowed < self.arm or dt <= 0:
            self.arm = allowed
            self.arm_v = 0
        else:
            var r = spring_damp(Vec3(self.arm, 0, 0, 0), Vec3(self.arm_v, 0, 0, 0), Vec3(allowed, 0, 0, 0), self.half_life, dt)
            self.arm = min(r[0][0], allowed)
            self.arm_v = r[1][0]
        var p = target + d * self.arm
        return CameraPose(p, look_rotation(-d, Vec3(0, 1, 0, 0)), self.fov_y, 16.0 / 9.0, 0.1, 500)


struct CameraBrain(Copyable, Movable):
    var priorities: List[Int]
    var active: Int
    var from_pose: CameraPose
    var elapsed: Real
    var blend_time: Real
    var ease: Int
    var blending: Bool

    def __init__(out self, blend_time: Real = 0.5, ease: Int = 0):
        self.priorities = List[Int]()
        self.active = -1
        self.from_pose = CameraPose(Vec3(0, 0, 0, 0), Quat(0, 0, 0, 1), 1, 1, 0.1, 100)
        self.elapsed = 0
        self.blend_time = blend_time
        self.ease = ease
        self.blending = False

    def update(mut self, cams: List[CameraPose], priorities: List[Int], dt: Real, last: CameraPose) -> CameraPose:
        """`cams` are this frame's candidate poses; `last` is the pose shown
        last frame (where a blend starts from)."""
        var best = -1
        for k in range(len(cams)):
            if best < 0 or priorities[k] > priorities[best]:
                best = k
        if best < 0:
            return last
        if best != self.active:
            if self.active >= 0 and self.blend_time > 0:
                self.from_pose = last
                self.elapsed = 0
                self.blending = True
            self.active = best
        var target = cams[best]
        if not self.blending:
            return target
        self.elapsed += dt
        var u = self.elapsed / self.blend_time
        if u >= 1:
            self.blending = False
            return target
        var w = ease_dyn(self.ease, u)
        var a = self.from_pose
        return CameraPose(
            a.position + (target.position - a.position) * w,
            slerp(a.rotation, target.rotation, w).normalized(),
            a.fov_y + (target.fov_y - a.fov_y) * w,
            target.aspect, target.near, target.far,
        )
