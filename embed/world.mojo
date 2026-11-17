"""The embedding world (ROADMAP 12.1): the value-semantics API that
`embed/capi.mojo` exports one-to-one as C functions.

A host sees a world as an opaque handle plus plain numbers: bodies are
`Int64` handles (`slot | generation << 32`, so a handle to a removed body
stays detectably stale after its slot is reused), poses and velocities are
`Float32` triples / `x, y, z, w` quaternions, contact events are five
`Int64`s. Everything that can fail on caller input raises here (one
validation at the boundary); the C layer turns the raise into a status code
plus `ld_world_last_error`.

Stepping is fixed-step: `ticks_due(frame_dt)` runs the same accumulator as
`scheduler.gameloop.FixedLoop` (at most `max_steps` ticks per frame, excess
debt dropped), and each tick is `pre systems -> physics_tick -> post
systems`. Systems are host callbacks; the loop that calls them lives in the
C layer (`capi.mojo`), because a callback re-enters the API through the
handle and must not run while a Mojo reference to the world is held.

`save` / `load` round-trip the whole simulation state (tick, accumulator,
scene via `physics.serialize.scene_to_bytes`) exactly; `hash` is FNV-1a over
that blob, so two hosts that agree on `hash` agree on every body bit.
"""

from std.math import isfinite
from diag.counters import GAMELOOP_DEBT_DROPPED
from geometry.vec import Real, Vec3, length
from geometry.quat import Quat
from physics.body_set import BodyId
from physics.rigid6 import Inertia3, Pose6, QuatBody6
from physics.joints6 import JOINT_BROKEN, Joint6
from physics.solver6 import ContactScene6
from physics.solver_config import SolverConfig, UnitScale
from physics.serialize import scene_to_bytes, scene_from_bytes
from physics.capture import Capture
from physics.fracture import FractureSet, EVENT_BOND_BROKEN
from physics.flip import FlipWater2
from physics.flip_diffuse import DiffuseParticles
from geometry.polytope import Polytope
from geometry.fracture_cut import FragmentSet, scatter_seeds, voronoi_fracture
from collision.world_query import QueryFilter, QueryShape, pose3_of
from collision.collider_set import CompoundSpec
from physics.joint_ext import MOTOR_NONE, MOTOR_VELOCITY, MOTOR_POSITION
from physics.mass_props import hull_mass
from collision.contact_events import ContactEvent

comptime ABI_MAJOR = 0
comptime ABI_MINOR = 9

# Status codes (negative = error). Frozen for v0.x: values never change.
comptime LD_OK = 0
comptime LD_ERR_HANDLE = -1  # null / destroyed world or nav handle
comptime LD_ERR_ARG = -2  # invalid argument (NaN, non-positive size, ...)
comptime LD_ERR_STALE = -3  # body handle removed or never issued
comptime LD_ERR_BUFFER = -4  # output buffer too small (call reports the size needed)
comptime LD_ERR_FORMAT = -5  # save blob truncated or from another format
comptime LD_ERR_CALLBACK = -6  # a host system returned non-zero; the step stopped there
comptime LD_ERR_STATE = -7  # operation refused in the current state
comptime LD_ERR_THREAD = -8  # called from a thread other than the one bound by ld_world_bind_thread

comptime PHASE_PRE = 0  # before the physics tick
comptime PHASE_POST = 1  # after the physics tick (this tick's contact events visible)

# Contact event kinds (same values as collision.contact_events EV_*).
comptime EVENT_BEGAN = 0
comptime EVENT_STAY = 1
comptime EVENT_ENDED = 2

comptime _SAVE_MAGIC = 0x3057444C  # "LDW0" little-endian
comptime _USER_MAGIC = 0x3055444C  # "LDU0": optional host user-data trailer
comptime _FRAC_MAGIC = 0x3046444C  # "LDF0": optional fractured-object trailer (ROADMAP 17.93)
comptime _WATER_MAGIC = 0x3048444C  # "LDH0": the world had a water tank, which save does not carry (17.95)
comptime _FNV_OFFSET = UInt64(0xCBF29CE484222325)
comptime _FNV_PRIME = UInt64(0x100000001B3)


@no_inline
def teleport_rotation(rot: Quat) -> Quat:
    """The rotation `teleport` stores for `rot`: scaled by 1 / |rot| with exactly the arithmetic `teleport` and
    `teleport_many` use (they call this), so a host can predict what `state()` returns after a teleport.
    `rot` must be non-zero (teleport raises otherwise). Not inlined: one compiled body for every caller, so the
    compiler cannot contract the sum of squares into fused multiply-adds at one call site and not at another (inlined,
    11 % of 10 000 random rotations came out different in the last bits)."""
    var n2 = rot.x * rot.x + rot.y * rot.y + rot.z * rot.z + rot.w * rot.w
    var s = 1 / n2 ** 0.5
    return Quat(rot.x * s, rot.y * s, rot.z * s, rot.w * s)


def _round_rot(q: Quat, scale: Real) -> List[Int]:
    var r = List[Int]()
    r.append(Int(round(q.x * scale)))
    r.append(Int(round(q.y * scale)))
    r.append(Int(round(q.z * scale)))
    r.append(Int(round(q.w * scale)))
    return r^


def dequantize_rotation(r: List[Int], scale: Real = 1000000.0) -> Quat:
    """Four integers back to a quaternion (each divided by `scale`)."""
    return Quat(Real(r[0]) / scale, Real(r[1]) / scale, Real(r[2]) / scale, Real(r[3]) / scale)


def quantize_rotation(rot: Quat, scale: Real = 1000000.0) -> List[Int]:
    """A rotation as four integers (times `scale`, rounded) that survive a network round trip unchanged: on the
    receiving side dequantize_rotation, teleport, state().rot and rounding again give the same integers (ludens-engine
    #75: a plain rounding came back off by one on 2 of 160 integers). Found by iterating that map, which settles in one
    or two steps; when it cycles instead (one integer flipping by 1 forever: 4 of 10 000 random rotations), the
    integers within 1 of the last step are searched for a fixed point, the one nearest to it first."""
    var r = _round_rot(rot, scale)
    for _ in range(8):
        var n = _round_rot(teleport_rotation(dequantize_rotation(r, scale)), scale)
        if _same4(n, r):
            return r^
        r = n^
    var best = r.copy()
    var best_d = 5
    for code in range(81):
        var c = code
        var cand = List[Int]()
        var d = 0
        for k in range(4):
            var off = c % 3 - 1
            c //= 3
            cand.append(r[k] + off)
            d += abs(off)
        if d < best_d and _same4(_round_rot(teleport_rotation(dequantize_rotation(cand, scale)), scale), cand):
            best = cand^
            best_d = d
    return best^


def _same4(a: List[Int], b: List[Int]) -> Bool:
    return a[0] == b[0] and a[1] == b[1] and a[2] == b[2] and a[3] == b[3]


def pack_body(id: BodyId) -> Int64:
    return Int64(id.slot) | (Int64(id.gen) << 32)


def unpack_body(h: Int64) -> BodyId:
    return BodyId(Int(h & 0xFFFFFFFF), UInt32(h >> 32))


def fnv1a(data: List[UInt8]) -> UInt64:
    var h = _FNV_OFFSET
    for b in data:
        h = (h ^ UInt64(b)) * _FNV_PRIME
    return h


def _finite3(v: Vec3) -> Bool:
    return isfinite(v[0]) and isfinite(v[1]) and isfinite(v[2])


@fieldwise_init
struct BodyState(Copyable, ImplicitlyCopyable, Movable):
    var pos: Vec3
    var rot: Quat
    var vel: Vec3
    var omega: Vec3


@fieldwise_init
struct RayResult(Copyable, ImplicitlyCopyable, Movable):
    var body: Int64  # -1 = no hit
    var t: Real
    var point: Vec3
    var normal: Vec3


@fieldwise_init
struct SweepResult(Copyable, ImplicitlyCopyable, Movable):
    """A shape swept along a direction (17.97): the first body it touches. `start_solid`: it already overlapped at t 0."""

    var body: Int64  # -1 = no hit
    var t: Real
    var point: Vec3
    var normal: Vec3
    var start_solid: Bool


@fieldwise_init
struct TickEvent(Copyable, ImplicitlyCopyable, Movable):
    """One contact event as the host sees it: body handles, not slots."""

    var tick: Int64
    var a: Int64
    var b: Int64
    var kind: Int64
    var feat: Int64
    # 17.90 payload (`ld_contact_event_ex`); zero for sensors / ENDED events
    var impulse: Float32
    var force: Float32
    var approach: Float32
    var peak: Float32
    var point: Vec3
    var normal: Vec3
    var tvel: Vec3
    var mat_a: UInt32
    var mat_b: UInt32


@fieldwise_init
struct FractureRec(Copyable, ImplicitlyCopyable, Movable):
    """One fracture event as the host sees it (17.90): body handles of the
    fragments, -1 where the other side is an external body (or none)."""

    var tick: Int64
    var kind: Int64  # LD_FRACTURE_BOND_BROKEN / LD_FRACTURE_EVICTED
    var bond: Int64
    var a: Int64
    var b: Int64


@fieldwise_init
struct BubbleRec(Copyable, ImplicitlyCopyable, Movable):
    """A particle that turned into an air bubble in the world's FLIP water (17.90)."""

    var tick: Int64
    var x: Float32
    var y: Float32
    var u: Float32
    var v: Float32


struct EmbedWorld(Movable):
    var scene: ContactScene6[QuatBody6]
    var cfg: SolverConfig
    var per_meter: Real  # host length units per meter (17.78; `set_unit_scale`)
    var gravity: Vec3
    var dt: Float64
    var acc: Float64
    var max_steps: Int
    var tick: Int
    var fracture: FractureSet  # 17.90: fragments + bonds added by `add_fracture_box`
    var fracture_on: Bool
    var frac_params: List[Float64]  # add_fracture_box's pos (3), half (3), stress, density, pieces, seed: to rebuild on load
    var frame_fracture: List[FractureRec]
    var water: FlipWater2  # 17.90: a 2D FLIP tank (xy plane) added by `add_water`
    var diffuse: DiffuseParticles
    var water_on: Bool
    var frame_bubbles: List[BubbleRec]
    var frame_events: List[TickEvent]  # every event of the ticks run by the current / last frame
    var tick_events: List[TickEvent]  # events of the latest tick only
    var error: String
    # ROADMAP 17.80: a physics capture of the ticks run while `capturing`
    var capturing: Bool
    var capture: Capture
    # ROADMAP 17.78: host user data per body slot (0 = none), valid while
    # the slot's generation matches `user_gen`
    var user: List[UInt64]
    var user_gen: List[UInt32]
    var material: List[UInt32]  # 17.90 host material id per body slot (0 = none)
    var material_gen: List[UInt32]

    def __init__(out self, dt: Float64, gravity: Vec3, max_steps: Int = 8) raises:
        if not (dt > 0) or not isfinite(dt):
            raise Error("world: dt must be finite and > 0")
        if not _finite3(gravity):
            raise Error("world: gravity must be finite")
        if max_steps < 1:
            raise Error("world: max_steps must be >= 1")
        self.scene = ContactScene6[QuatBody6]()
        self.scene.events_on = True
        self.capturing = False
        self.capture = Capture(60)
        self.cfg = SolverConfig()
        self.per_meter = 1
        self.cfg.broadphase = True
        self.gravity = gravity
        self.dt = dt
        self.acc = 0
        self.max_steps = max_steps
        self.tick = 0
        self.fracture = FractureSet(Real(1000), 0)
        self.fracture_on = False
        self.frac_params = List[Float64]()
        self.frame_fracture = List[FractureRec]()
        self.water = FlipWater2(2, 2, Real(1))
        self.diffuse = DiffuseParticles(UInt64(1), 1)
        self.water_on = False
        self.frame_bubbles = List[BubbleRec]()
        self.frame_events = List[TickEvent]()
        self.tick_events = List[TickEvent]()
        self.error = String()
        self.user = List[UInt64]()
        self.user_gen = List[UInt32]()
        self.material = List[UInt32]()
        self.material_gen = List[UInt32]()

    # ------------------------------------------------------------ settings

    def set_solver(mut self, iters: Int, substeps: Int) raises:
        if iters < 1 or substeps < 1:
            raise Error("set_solver: iterations and substeps must be >= 1")
        self.cfg.iters = iters
        self.cfg.substeps = substeps

    def set_unit_scale(mut self, per_meter: Real) raises:
        """The host's length unit (ROADMAP 17.78 / 17.75): `per_meter` host
        units make one meter (100 for centimetres). Every position, size,
        velocity and the gravity the host passes is in its own unit; this
        rescales the solver's absolute length tolerances to match
        (`UnitScale`). Calls compose: the tolerances are rescaled by the
        ratio to the previous value. A setting, not saved with the world."""
        if not (per_meter > 0) or not isfinite(per_meter):
            raise Error("set_unit_scale: per_meter must be finite and > 0")
        self.cfg = UnitScale(per_meter / self.per_meter).apply(self.cfg)
        self.per_meter = per_meter

    def set_gravity(mut self, g: Vec3) raises:
        if not _finite3(g):
            raise Error("set_gravity: gravity must be finite")
        self.gravity = g

    # -------------------------------------------------------------- bodies

    def _check_new(self, pos: Vec3, mass: Real, is_static: Bool) raises:
        if not _finite3(pos):
            raise Error("add body: position must be finite")
        if not is_static and (not (mass > 0) or not isfinite(mass)):
            raise Error("add body: dynamic body mass must be finite and > 0")

    def add_box(mut self, pos: Vec3, half: Vec3, mass: Real, is_static: Bool) raises -> Int64:
        self._check_new(pos, mass, is_static)
        if not _finite3(half) or not (half[0] > 0 and half[1] > 0 and half[2] > 0):
            raise Error("add_box: half extents must be finite and > 0")
        var m = mass if not is_static else Real(1)
        var id = self.scene.add(QuatBody6.at_rest(pos, Inertia3.box(m, half[0], half[1], half[2])), half, is_static)
        return pack_body(id)

    def add_sphere(mut self, pos: Vec3, r: Real, mass: Real, is_static: Bool) raises -> Int64:
        self._check_new(pos, mass, is_static)
        if not (r > 0) or not isfinite(r):
            raise Error("add_sphere: radius must be finite and > 0")
        var m = mass if not is_static else Real(1)
        var id = self.scene.add_sphere(QuatBody6.at_rest(pos, Inertia3.sphere(m, r)), r, is_static)
        return pack_body(id)

    def add_capsule(mut self, pos: Vec3, r: Real, half_len: Real, mass: Real, is_static: Bool) raises -> Int64:
        """A capsule whose axis is the body's local y; `half_len` is half the length of the cylinder part."""
        self._check_new(pos, mass, is_static)
        if not (r > 0) or not isfinite(r) or not (half_len > 0) or not isfinite(half_len):
            raise Error("add_capsule: radius and half length must be finite and > 0")
        var m = mass if not is_static else Real(1)
        var id = self.scene.add_capsule(QuatBody6.at_rest(pos, Inertia3.capsule(m, r, half_len)), r, half_len, is_static)
        return pack_body(id)

    def add_hull(mut self, pos: Vec3, verts: List[Vec3], mass: Real, is_static: Bool) raises -> Int64:
        """A convex body from the hull of `verts` (body frame, around `pos`). Its centre of mass and principal axes come
        from the hull at uniform density, so the body's origin moves to the centre of mass; `state(h).pos` is that
        centre (17.97). 4..4096 vertices."""
        self._check_new(pos, mass, is_static)
        if len(verts) < 4 or len(verts) > 4096:
            raise Error("add_hull: need 4 to 4096 vertices")
        var flat = List[Real]()
        for v in verts:
            if not _finite3(v):
                raise Error("add_hull: vertices must be finite")
            flat.append(v[0])
            flat.append(v[1])
            flat.append(v[2])
        var vol = hull_mass(flat, Real(1))[0]
        if not (vol > Real(1e-12)):
            raise Error("add_hull: the vertices span no volume")
        var spec = CompoundSpec()
        spec.hull(flat, Vec3(0), Quat.identity())
        var density = (mass if not is_static else Real(1)) / vol
        var id = self.scene.add_compound(QuatBody6.at_rest(pos, Inertia3.box(Real(1), 1, 1, 1)), spec, density, is_static)
        return pack_body(id)

    def add_trimesh(mut self, pos: Vec3, verts: List[Vec3], tris: List[Int]) raises -> Int64:
        """A static triangle mesh; `verts` in the body frame at `pos`, `tris` three vertex indices per triangle."""
        self._check_new(pos, 1, True)
        if len(verts) < 3 or len(tris) < 3 or len(tris) % 3 != 0:
            raise Error("add_trimesh: need >= 3 vertices and a multiple of 3 indices")
        var flat = List[Real]()
        for v in verts:
            if not _finite3(v):
                raise Error("add_trimesh: vertices must be finite")
            flat.append(v[0])
            flat.append(v[1])
            flat.append(v[2])
        for i in tris:
            if i < 0 or i >= len(verts):
                raise Error("add_trimesh: an index is outside the vertex list")
        var id = self.scene.add_trimesh(QuatBody6.at_rest(pos, Inertia3.box(Real(1), 1, 1, 1)), flat, tris, List[UInt8](), True)
        return pack_body(id)

    def add_heightfield(mut self, heights: List[Real], nx: Int, nz: Int, cell: Real, ox: Real, oz: Real) raises -> Int64:
        """A static heightfield: nx x nz samples `cell` apart, row-major by z, sample (i, k) at (ox + i cell, h, oz + k cell)."""
        if nx < 2 or nz < 2 or len(heights) != nx * nz:
            raise Error("add_heightfield: need nx, nz >= 2 and nx * nz heights")
        if not (cell > 0) or not isfinite(cell) or not isfinite(ox) or not isfinite(oz):
            raise Error("add_heightfield: cell must be > 0 and the origin finite")
        for h in heights:
            if not isfinite(h):
                raise Error("add_heightfield: heights must be finite")
        var id = self.scene.add_heightfield(QuatBody6.at_rest(Vec3(0), Inertia3.box(Real(1), 1, 1, 1)), heights, nx, nz, cell, ox, oz)
        return pack_body(id)

    def set_kinematic(mut self, h: Int64) raises:
        """Make a live body kinematic (ROADMAP 17.24): moved by its velocity, unaffected by forces."""
        var id = unpack_body(h)
        if not self.scene.bset.is_valid(id):
            raise Error("set_kinematic: the handle is not a live body")
        self.scene.set_kinematic(id)

    def set_material_friction(mut self, material: Int, mu: Real) raises:
        """Friction of surface material `material` (ids 0..65535), used for mesh / heightfield triangles and
        `surface_friction`. The table is part of the snapshot."""
        self.scene.set_material_friction(material, mu)

    def set_material_softness(mut self, material: Int, hertz: Real, zeta: Real) raises:
        """Contact stiffness of surface material `material` (hertz > 0, zeta >= 0)."""
        self.scene.set_material_softness(material, hertz, zeta)

    def track_joint_loads(mut self, on: Bool):
        """Measure the load of every joint each step (see `joint_load`). Does not change the simulation."""
        self.scene.set_track_joint_loads(on)

    def joint_load(self, j: Int) raises -> Tuple[Real, Real]:
        """(force N, torque N m): the peak constraint load of joint `j` in the last tick; (0, 0) when not tracking."""
        return self.scene.joint_load(j)

    def released_joints(self) -> List[Int]:
        """Joints whose break threshold was exceeded in the last tick (they are now inert)."""
        return self.scene.broken_joints.copy()

    def _joint_bodies(self, a: Int64, b: Int64) raises -> Tuple[Int, Int]:
        var ia = self._id(a).index()
        var ib = self._id(b).index()
        if ia == ib:
            raise Error("joint: the two bodies must differ")
        return (ia, ib)

    def add_ball_joint(mut self, a: Int64, b: Int64, la: Vec3, lb: Vec3) raises -> Int:
        """Anchors `la` (body a's frame) and `lb` (body b's frame) are held together. Returns the joint index."""
        var ab = self._joint_bodies(a, b)
        return self.scene.add_joint(Joint6.ball(ab[0], ab[1], la, lb))

    def add_distance_joint(mut self, a: Int64, b: Int64, la: Vec3, lb: Vec3, rest: Real) raises -> Int:
        if not (rest >= 0) or not isfinite(rest):
            raise Error("add_distance_joint: rest length must be finite and >= 0")
        var ab = self._joint_bodies(a, b)
        return self.scene.add_joint(Joint6.distance(ab[0], ab[1], la, lb, rest))

    def add_hinge_joint(mut self, a: Int64, b: Int64, la: Vec3, lb: Vec3, axis: Vec3) raises -> Int:
        """Anchors held together and `axis` (a unit vector in each body's frame) kept aligned."""
        if not _finite3(axis) or not (length(axis) > 1e-6):
            raise Error("add_hinge_joint: the axis must be finite and non-zero")
        var ab = self._joint_bodies(a, b)
        return self.scene.add_joint(Joint6.hinge(ab[0], ab[1], la, lb, axis))

    def add_weld_joint(mut self, a: Int64, b: Int64, la: Vec3, lb: Vec3) raises -> Int:
        """A rigid bond: anchors together and the current relative rotation held."""
        var ab = self._joint_bodies(a, b)
        var rel = self.scene.bset.bodies[ab[0]].rotation().conjugate() * self.scene.bset.bodies[ab[1]].rotation()
        return self.scene.add_joint(Joint6.weld(ab[0], ab[1], la, lb, rel))

    def remove_joint(mut self, j: Int) raises:
        self.scene.remove_joint(j)

    def joint_record(self, j: Int) raises -> Joint6:
        """The raw state of joint slot `j` (kind, bodies by slot, anchors, axes), for an undo log to keep."""
        if j < 0 or j >= len(self.scene.joints):
            raise Error("joint_record: joint index out of range")
        return self.scene.joints[j]

    def restore_joint(mut self, j: Int, rec: Joint6) raises:
        """Put joint slot `j` back to `rec` (accumulated impulses start at zero, as for a new joint). A live record
        needs both of its bodies alive."""
        self.scene.restore_joint(j, rec)

    # 17.97: limits, motor, spring and break threshold of a joint (ContactScene6's joint ext; saved with the scene).

    def _joint_ok(self, j: Int, what: String) raises:
        if j < 0 or j >= len(self.scene.joints):
            raise Error(what + ": no joint with this index")

    def _wake_joint(mut self, j: Int) raises:
        """A changed limit, motor or spring must act now: wake both bodies' islands (static ones are a no-op)."""
        var a = self.scene.joints[j].a
        var b = self.scene.joints[j].b
        if a >= 0:
            self.scene.wake(self.scene.bset.id_of(a))
        if b >= 0:
            self.scene.wake(self.scene.bset.id_of(b))

    def set_joint_limits(mut self, j: Int, lo: Real, hi: Real) raises:
        """Hinge angle (rad, 0 where the joint was made) kept in [lo, hi]."""
        self._joint_ok(j, "set_joint_limits")
        if not isfinite(lo) or not isfinite(hi):
            raise Error("set_joint_limits: lo and hi must be finite")
        self.scene.set_joint_limits(j, lo, hi)
        self._wake_joint(j)

    def set_joint_motor(mut self, j: Int, mode: Int, target: Real, max_force: Real, hertz: Real = 5, zeta: Real = 1) raises:
        """Mode 0 off, 1 velocity (target in rad/s), 2 position (target in rad, a spring of hertz / zeta);
        max_force caps the motor's force or torque."""
        self._joint_ok(j, "set_joint_motor")
        if not isfinite(target) or not (max_force >= 0) or not isfinite(max_force):
            raise Error("set_joint_motor: target must be finite and max_force >= 0")
        self.scene.set_joint_motor(j, mode, target, max_force, hertz, zeta)
        self._wake_joint(j)

    def set_joint_spring(mut self, j: Int, hertz: Real, zeta: Real, rest: Real) raises:
        self._joint_ok(j, "set_joint_spring")
        if not (hertz > 0) or not (zeta >= 0) or not isfinite(rest) or not isfinite(hertz) or not isfinite(zeta):
            raise Error("set_joint_spring: need hertz > 0, zeta >= 0 and a finite rest")
        self.scene.set_joint_spring(j, hertz, zeta, rest)
        self._wake_joint(j)

    def set_joint_break(mut self, j: Int, force: Real, torque: Real) raises:
        """Release the joint when its force exceeds `force` (N) or its torque `torque` (N m); see `released_joints`."""
        self._joint_ok(j, "set_joint_break")
        self.scene.set_joint_break(j, force, torque)

    def joint_count(self) -> Int:
        """Joint slots ever added, removed ones included (indices never shift)."""
        return len(self.scene.joints)

    def reserve_slot(mut self, h: Int64) raises:
        """One-shot: the next body added gets exactly the identity `h` had (its slot and generation). The slot must be
        free and `h` from an earlier life of it. Undo of a remove uses this; bodies added and removed in between
        (and undone before it) have moved the slot's generation on, which is why `BodySet.gen_hwm` keeps handing out
        fresh ones afterwards."""
        var id = unpack_body(h)
        if id.slot < 0 or id.slot >= len(self.scene.bset.generation):
            raise Error("reserve_slot: no such slot")
        if not self.scene.bset.is_removed(id.slot) or not (id.gen < self.scene.bset.generation[id.slot]):
            raise Error("reserve_slot: the slot is occupied, or the handle is not from an earlier life of it")
        if self.scene.bset.free_index(id.slot) < 0:
            raise Error("reserve_slot: the slot is not free")
        self.scene.bset.reuse_slot = id.slot
        self.scene.bset.reuse_gen = id.gen

    def is_alive(self, h: Int64) -> Bool:
        if h < 0:
            return False
        var id = unpack_body(h)
        if id.slot >= len(self.scene.bset.bodies):
            return False
        return self.scene.bset.is_valid(id)

    def _id(self, h: Int64) raises -> BodyId:
        if not self.is_alive(h):
            raise Error("stale or unknown body handle")
        return unpack_body(h)

    def remove(mut self, h: Int64) raises:
        self.scene.remove_body(self._id(h))

    # ------------------------------------------------- host mapping (17.78)

    def set_layer(mut self, h: Int64, category: UInt32, mask: UInt32) raises:
        """Collision layer of a body (host layer -> category bits, and the
        categories it collides with)."""
        self.scene.set_filter(self._id(h).index(), category, mask)

    def _frag_handle(self, frag: Int) -> Int64:
        if frag < 0 or frag >= len(self.fracture.bid):
            return -1
        return pack_body(self.fracture.bid[frag])

    def add_water(
        mut self, nx: Int, ny: Int, cell: Real, x0: Real, y0: Real, x1: Real, y1: Real, seed: Int
    ) raises -> Int:
        """A 2D FLIP tank of nx x ny cells (xy plane, walls all round) filled in
        [x0, x1] x [y0, y1], with foam / spray / bubble particles on top. Bubble
        spawns come back as events. One tank per world; gravity is the world's
        -y component. Returns the water particle count."""
        if self.water_on:
            raise Error("add_water: this world already has a water tank")
        if nx < 2 or ny < 2 or nx * ny > 1000000 or not (cell > 0) or not isfinite(cell):
            raise Error("add_water: need 2..1e6 cells and a finite cell size > 0")
        if not (x1 > x0) or not (y1 > y0) or not isfinite(x0 + y0 + x1 + y1):
            raise Error("add_water: the fill box must be finite and non-empty")
        var g = -self.gravity[1]
        self.water = FlipWater2(nx, ny, cell, g if g > 0 else Real(0))
        self.water.fill_box(x0, y0, x1, y1)
        self.diffuse = DiffuseParticles(UInt64(seed))
        self.water_on = True
        return self.water.count()

    def _step_water(mut self) raises:
        var left = Real(self.dt)
        var guard = 0
        while left > 0 and guard < 64:
            var h = min(left, self.water.max_dt())
            self.water.step(h)
            self.diffuse.update(self.water, h)
            left -= h
            guard += 1

    def add_fracture_box(
        mut self, pos: Vec3, half: Vec3, pieces: Int, seed: Int, stress: Real, density: Real
    ) raises -> Int64:
        """A box of Voronoi fragments welded along their shared faces (17.90).
        Each weld breaks at `stress` (Pa) times its seam area and reports a
        fracture event. Returns the handle of the first fragment; the others
        are handles `fragment_handle(1..)`. At most one fractured object per
        world; the world cannot be saved or loaded while it exists."""
        if self.fracture_on:
            raise Error("add_fracture_box: this world already has a fractured object")
        if pieces < 1 or pieces > 4096:
            raise Error("add_fracture_box: pieces must be in [1, 4096]")
        if not (half[0] > 0 and half[1] > 0 and half[2] > 0) or not (stress > 0) or not (density > 0):
            raise Error("add_fracture_box: half extents, stress and density must be > 0")
        var first = _build_fracture(self.scene, self.fracture, pos, half, pieces, seed, stress, density)
        self.frac_params = List[Float64]()
        for v in [Float64(pos[0]), Float64(pos[1]), Float64(pos[2]), Float64(half[0]), Float64(half[1]), Float64(half[2]),
                  Float64(stress), Float64(density), Float64(pieces), Float64(seed)]:
            self.frac_params.append(v)
        self.fracture_on = True
        return pack_body(self.fracture.bid[first])

    def fragment_handle(self, i: Int) -> Int64:
        return self._frag_handle(i)

    def set_material(mut self, h: Int64, m: UInt32) raises:
        """Host material id of a body (17.90; 0 = none), reported on its contact events."""
        var id = self._id(h)
        var i = id.index()
        while len(self.material) <= i:
            self.material.append(0)
            self.material_gen.append(0)
        self.material[i] = m
        self.material_gen[i] = id.gen

    def get_material(self, h: Int64) raises -> UInt32:
        var id = self._id(h)
        return self._material_of(id.index()) if self._material_gen_ok(id) else UInt32(0)

    def _material_gen_ok(self, id: BodyId) -> Bool:
        var i = id.index()
        return i < len(self.material) and self.material_gen[i] == id.gen

    def _material_of(self, slot: Int) -> UInt32:
        """Material of the live body in `slot` (0 if none was set)."""
        if slot < len(self.material) and self.material_gen[slot] == self.scene.bset.id_of(slot).gen:
            return self.material[slot]
        return 0

    def set_user(mut self, h: Int64, u: UInt64) raises:
        """Attach a host value (node id, pointer) to a body; 0 clears."""
        var id = self._id(h)
        var i = id.index()
        while len(self.user) <= i:
            self.user.append(0)
            self.user_gen.append(0)
        self.user[i] = u
        self.user_gen[i] = id.gen

    def get_user(self, h: Int64) raises -> UInt64:
        var id = self._id(h)
        var i = id.index()
        if i < len(self.user) and self.user_gen[i] == id.gen:
            return self.user[i]
        return 0

    def find_user(self, u: UInt64) -> Int64:
        """Handle of the live body carrying host value `u` (the lowest slot
        if several do), or -1."""
        if u == 0:
            return -1
        for i in range(len(self.user)):
            if self.user[i] != u or self.scene.bset.is_removed(i):
                continue
            var id = self.scene.bset.id_of(i)
            if id.gen == self.user_gen[i]:
                return pack_body(id)
        return -1

    def set_velocity(mut self, h: Int64, v: Vec3, w: Vec3) raises:
        if not _finite3(v) or not _finite3(w):
            raise Error("set_velocity: velocities must be finite")
        var id = self._id(h)
        self.scene.set_velocity(id, v, w)
        self.scene.wake(id)

    def apply_impulse(mut self, h: Int64, j: Vec3) raises:
        """Linear impulse through the centre of mass (kg m/s); wakes the island."""
        if not _finite3(j):
            raise Error("apply_impulse: impulse must be finite")
        var id = self._id(h)
        var i = id.index()
        if not self.scene.bset.is_dynamic(i):
            raise Error("apply_impulse: body is not dynamic")
        self.scene.apply_impulse(id, j, self.scene.pose(id).pos)

    def teleport(mut self, h: Int64, pos: Vec3, rot: Quat) raises:
        if not _finite3(pos) or not (isfinite(rot.x) and isfinite(rot.y) and isfinite(rot.z) and isfinite(rot.w)):
            raise Error("teleport: pose must be finite")
        var n2 = rot.x * rot.x + rot.y * rot.y + rot.z * rot.z + rot.w * rot.w
        if n2 < 1e-12:
            raise Error("teleport: quaternion must be non-zero")
        self.scene.teleport(self._id(h), Pose6(pos, teleport_rotation(rot)))

    def teleport_many(mut self, hs: List[Int64], pos: List[Vec3], rot: List[Quat]) raises:
        """`teleport` for many bodies at once (ROADMAP 17.78): every input
        is validated first, then one `ContactScene6.teleport_many`."""
        var ids = List[BodyId]()
        var poses = List[Pose6]()
        for k in range(len(hs)):
            var r = rot[k]
            if not _finite3(pos[k]) or not (isfinite(r.x) and isfinite(r.y) and isfinite(r.z) and isfinite(r.w)):
                raise Error("teleport_many: pose must be finite")
            var n2 = r.x * r.x + r.y * r.y + r.z * r.z + r.w * r.w
            if n2 < 1e-12:
                raise Error("teleport_many: quaternion must be non-zero")
            ids.append(self._id(hs[k]))
            poses.append(Pose6(pos[k], teleport_rotation(r)))
        self.scene.teleport_many(ids, poses)

    def state(self, h: Int64) raises -> BodyState:
        var i = self._id(h).index()
        ref b = self.scene.bset.bodies[i]
        return BodyState(b.position(), b.rotation(), b.linear_velocity(), b.omega_world())

    def is_sleeping(self, h: Int64) raises -> Bool:
        return self.scene.is_sleeping(self._id(h))

    def bodies(self) -> List[Int64]:
        """Handles of every live body, in slot order."""
        var out = List[Int64]()
        for i in range(len(self.scene.bset.bodies)):
            if not self.scene.bset.is_removed(i):
                out.append(pack_body(self.scene.bset.id_of(i)))
        return out^

    # ------------------------------------------------------------- queries

    def raycast(self, origin: Vec3, dir: Vec3, max_t: Real, mask: UInt32 = 0xFFFFFFFF) raises -> RayResult:
        if not _finite3(origin) or not _finite3(dir) or not (max_t >= 0):
            raise Error("raycast: origin, direction and max_t must be finite, max_t >= 0")
        var l2 = dir[0] * dir[0] + dir[1] * dir[1] + dir[2] * dir[2]
        if l2 < 1e-12:
            raise Error("raycast: direction must be non-zero")
        var f = QueryFilter.all()
        f.mask = mask
        var hit = self.scene.ray_cast(origin, dir / l2 ** 0.5, max_t, f)
        if not hit.hit:
            return RayResult(-1, 0, Vec3(0), Vec3(0))
        return RayResult(pack_body(self.scene.bset.id_of(hit.body)), hit.t, hit.point, hit.normal)

    # 17.97: overlap and sweep queries (stateless; the scene's world_query). `mask` filters by collision category.

    def _unit(self, rot: Quat, what: String) raises -> Quat:
        if rot.x * rot.x + rot.y * rot.y + rot.z * rot.z + rot.w * rot.w < 1e-12:
            raise Error(what + ": quaternion must be non-zero")
        return teleport_rotation(rot)

    def _handles(self, slots: List[Int]) -> List[Int64]:
        var out = List[Int64]()
        for i in slots:
            out.append(pack_body(self.scene.bset.id_of(i)))
        return out^

    def overlap_sphere(self, c: Vec3, r: Real, mask: UInt32 = 0xFFFFFFFF) raises -> List[Int64]:
        """Bodies whose collider overlaps the sphere, in slot order."""
        if not _finite3(c) or not (r > 0) or not isfinite(r):
            raise Error("overlap_sphere: centre must be finite and radius > 0")
        var f = QueryFilter.all()
        f.mask = mask
        return self._handles(self.scene.overlap_sphere(c, r, f))

    def overlap_box(self, c: Vec3, half: Vec3, rot: Quat, mask: UInt32 = 0xFFFFFFFF) raises -> List[Int64]:
        """Bodies whose collider overlaps the oriented box, in slot order."""
        if not _finite3(c) or not _finite3(half) or not (half[0] > 0 and half[1] > 0 and half[2] > 0):
            raise Error("overlap_box: centre must be finite and half extents > 0")
        var f = QueryFilter.all()
        f.mask = mask
        return self._handles(self.scene.overlap_shape(QueryShape.box(half), pose3_of(c, self._unit(rot, "overlap_box")), f))

    def _sweep(self, shape: QueryShape, pos: Vec3, rot: Quat, dir: Vec3, max_t: Real, mask: UInt32) raises -> SweepResult:
        if not _finite3(pos) or not _finite3(dir) or not (max_t >= 0) or not isfinite(max_t):
            raise Error("sweep: start, direction and max_t must be finite, max_t >= 0")
        var l2 = dir[0] * dir[0] + dir[1] * dir[1] + dir[2] * dir[2]
        if l2 < 1e-12:
            raise Error("sweep: direction must be non-zero")
        var f = QueryFilter.all()
        f.mask = mask
        var hit = self.scene.shape_cast(shape, pose3_of(pos, self._unit(rot, "sweep")), dir / l2 ** 0.5, max_t, f)
        if not hit.hit:
            return SweepResult(-1, 0, Vec3(0), Vec3(0), False)
        return SweepResult(pack_body(self.scene.bset.id_of(hit.body)), hit.t, hit.point, hit.normal, hit.start_solid)

    def sweep_sphere(self, pos: Vec3, r: Real, dir: Vec3, max_t: Real, mask: UInt32 = 0xFFFFFFFF) raises -> SweepResult:
        if not (r > 0) or not isfinite(r):
            raise Error("sweep_sphere: radius must be > 0")
        return self._sweep(QueryShape.sphere(r), pos, Quat.identity(), dir, max_t, mask)

    def sweep_box(self, pos: Vec3, half: Vec3, rot: Quat, dir: Vec3, max_t: Real, mask: UInt32 = 0xFFFFFFFF) raises -> SweepResult:
        if not _finite3(half) or not (half[0] > 0 and half[1] > 0 and half[2] > 0):
            raise Error("sweep_box: half extents must be finite and > 0")
        return self._sweep(QueryShape.box(half), pos, rot, dir, max_t, mask)

    # ------------------------------------------------------------ stepping

    def ticks_due(mut self, frame_dt: Float64) raises -> Int:
        """Accumulate `frame_dt` and return how many fixed ticks to run now;
        also starts a new frame's event list."""
        if not (frame_dt >= 0) or not isfinite(frame_dt):
            raise Error("step: frame_dt must be finite and >= 0")
        self.frame_events.clear()
        self.frame_fracture.clear()
        self.frame_bubbles.clear()
        self.acc += frame_dt
        var n = 0
        while self.acc >= self.dt and n < self.max_steps:
            self.acc -= self.dt
            n += 1
        if self.acc >= self.dt:
            self.acc = 0
            self.scene.counters.incr(GAMELOOP_DEBT_DROPPED)  # the same counter FixedLoop bumps (E22); ld_world_get_counters reads it
        return n

    def touching(self, a: Int64, b: Int64) -> Bool:
        """True when bodies `a` and `b` are in contact after the latest physics tick: the tick reported a BEGAN or STAY
        event for the pair, in either order. Read-only (the world hash does not change). A removed body, a == b or a
        handle that was never valid gives False. The same events `ld_world_subscribe_contacts` delivers (17.12)."""
        if a == b:
            return False
        for e in self.tick_events:
            if e.kind == Int64(EVENT_ENDED):
                continue
            if (e.a == a and e.b == b) or (e.a == b and e.b == a):
                return True
        return False

    def touching_count(self) -> Int:
        """Number of body pairs in contact after the latest physics tick (ENDED events are not counted)."""
        var n = 0
        for e in self.tick_events:
            if e.kind != Int64(EVENT_ENDED):
                n += 1
        return n

    def physics_tick(mut self):
        """One fixed tick of the scene; collects its contact events."""
        self.scene.step(Real(self.dt), self.gravity, self.cfg)
        self.tick_events.clear()
        for e in self.scene.events:
            var ev = TickEvent(
                Int64(self.tick),
                pack_body(self.scene.bset.id_of(e.a)),
                pack_body(self.scene.bset.id_of(e.b)),
                Int64(e.kind),
                Int64(e.feat),
                Float32(e.impulse),
                Float32(e.force),
                Float32(e.approach),
                Float32(e.peak),
                e.point,
                e.normal,
                e.tvel,
                self._material_of(e.a),
                self._material_of(e.b),
            )
            self.tick_events.append(ev)
            self.frame_events.append(ev)
        if self.fracture_on:
            _ = self.fracture.poll(self.scene)
            for k in range(len(self.fracture.events)):
                var fe = self.fracture.events[k]
                self.frame_fracture.append(
                    FractureRec(
                        Int64(self.tick),
                        Int64(fe.kind),
                        Int64(fe.bond),
                        self._frag_handle(fe.frag_a),
                        self._frag_handle(fe.frag_b),
                    )
                )
        if self.water_on:
            try:
                self._step_water()
            except e:
                self.error = String(e)
            var nb = len(self.diffuse.bubble_ev) // 4
            for k in range(nb):
                self.frame_bubbles.append(
                    BubbleRec(
                        Int64(self.tick),
                        Float32(self.diffuse.bubble_ev[4 * k]),
                        Float32(self.diffuse.bubble_ev[4 * k + 1]),
                        Float32(self.diffuse.bubble_ev[4 * k + 2]),
                        Float32(self.diffuse.bubble_ev[4 * k + 3]),
                    )
                )
            self.diffuse.clear_bubble_events()
        if self.capturing:
            self.capture.record(self.scene)
        self.tick += 1

    def capture_begin(mut self, key_every: Int) raises:
        """Start a new capture (17.80); the previous one is discarded."""
        self.capture = Capture(key_every)
        self.capturing = True

    def capture_end(mut self):
        """Stop recording; the capture stays readable until the next begin."""
        self.capturing = False

    # -------------------------------------------------------- save / load

    def save(self) -> List[UInt8]:
        var out = List[UInt8]()
        _put(out, UInt64(_SAVE_MAGIC))
        _put(out, UInt64(self.tick))
        _put(out, UInt64(self.acc.to_bits()))
        var body = scene_to_bytes(self.scene)
        _put(out, UInt64(len(body)))
        out.extend(body^)
        # 17.78: host user data, only when some is set (so a world without
        # it saves -- and hashes -- exactly as before)
        var live = List[Int]()
        for i in range(len(self.user)):
            if self.user[i] != 0 and not self.scene.bset.is_removed(i) and self.scene.bset.id_of(i).gen == self.user_gen[i]:
                live.append(i)
        if len(live) > 0:
            _put(out, UInt64(_USER_MAGIC))
            _put(out, UInt64(len(live)))
            for i in live:
                _put(out, UInt64(i))
                _put(out, UInt64(self.user_gen[i]))
                _put(out, self.user[i])
        # 17.95: a water tank is not carried; the marker makes `load` refuse the blob instead of dropping the water
        if self.water_on:
            _put(out, UInt64(_WATER_MAGIC))
        # 17.93: the fractured object, when there is one: what rebuilds it (add_fracture_box's arguments) and what has
        # changed since (which welds are live, how many each fragment still has), plus the body and joint indices that tie
        # it to the scene above. A world without one saves -- and hashes -- exactly as before.
        if self.fracture_on:
            ref f = self.fracture
            _put(out, UInt64(_FRAC_MAGIC))
            for v in self.frac_params:
                _put(out, UInt64(v.to_bits()))
            _put(out, UInt64(f.fragments()))
            _put(out, UInt64(len(f.bond_live)))
            for i in range(f.fragments()):
                _put(out, UInt64(f.body[i]))
                _put(out, UInt64(f.bid[i].slot))
                _put(out, UInt64(f.bid[i].gen))
                _put(out, UInt64(f.nbond[i] + 1))  # nbond can be set to 1 by the budget; +1 keeps it unsigned
                _put(out, UInt64(1 if f.alive[i] else 0))
            for b in range(len(f.bond_live)):
                _put(out, UInt64(f.bond_body_a[b] + 1))
                _put(out, UInt64(f.bond_body_b[b] + 1))
                _put(out, UInt64(f.bond_joint[b]))
                _put(out, UInt64(1 if f.bond_live[b] else 0))
        return out^

    def load(mut self, data: List[UInt8]) raises:
        """Replace the simulation state with a `save` blob. Settings (dt,
        gravity, solver, systems) are the host's and stay as they are."""
        if self.water_on:
            raise Error("load: refused while the world has a water tank")
        var pos = 0
        if _get(data, pos) != UInt64(_SAVE_MAGIC):
            raise Error("load: not a ludens world blob")
        var tick = Int(_get(data, pos))
        var acc_bits = _get(data, pos)
        var acc = Pointer(to=acc_bits).unsafe_bitcast[Float64]()[]
        var n = Int(_get(data, pos))
        if n < 0 or pos + n > len(data):
            raise Error("load: blob length mismatch")
        var body = List[UInt8](capacity=n)
        for i in range(n):
            body.append(data[pos + i])
        pos += n
        var user = List[UInt64]()
        var user_gen = List[UInt32]()
        var frac_at = -1
        # trailers, each optional, in the order save writes them: user data, water marker, fracture
        var stage = 0
        while pos < len(data) and frac_at < 0:
            var magic = _get(data, pos)
            if magic == UInt64(_USER_MAGIC) and stage < 1:
                stage = 1
                var m = Int(_get(data, pos))
                if m < 0 or pos + 24 * m > len(data):
                    raise Error("load: user-data length mismatch")
                for _ in range(m):
                    var i = Int(_get(data, pos))
                    var g = UInt32(_get(data, pos))
                    var u = _get(data, pos)
                    if i < 0 or i > (1 << 31):
                        raise Error("load: bad user-data slot")
                    while len(user) <= i:
                        user.append(0)
                        user_gen.append(0)
                    user[i] = u
                    user_gen[i] = g
            elif magic == UInt64(_WATER_MAGIC):
                raise Error("load: the blob was saved from a world with a water tank, which save does not carry (ROADMAP 17.95)")
            elif magic == UInt64(_FRAC_MAGIC):
                frac_at = pos - 8
            else:
                raise Error("load: unknown trailer")
        var sc = scene_from_bytes(body^)
        sc.events_on = True
        if frac_at >= 0:
            var fp = frac_at + 8
            var params = List[Float64]()
            for _ in range(10):
                var bits = _get(data, fp)
                params.append(Pointer(to=bits).unsafe_bitcast[Float64]()[])
            var nfrag = Int(_get(data, fp))
            var nbonds = Int(_get(data, fp))
            if nfrag < 0 or nbonds < 0 or fp + 40 * nfrag + 32 * nbonds != len(data):
                raise Error("load: fracture trailer length mismatch")
            # rebuild the fragments and welds (shapes, volumes, bond topology) from the same arguments in a scratch
            # scene, then point them at the loaded scene's bodies and joints and restore what changed since
            var scratch = ContactScene6[QuatBody6]()
            var pos3 = Vec3(Real(params[0]), Real(params[1]), Real(params[2]), 0)
            var half3 = Vec3(Real(params[3]), Real(params[4]), Real(params[5]), 0)
            var f = FractureSet(Real(params[7]), 0)
            _ = _build_fracture(scratch, f, pos3, half3, Int(params[8]), Int(params[9]), Real(params[6]), Real(params[7]))
            if f.fragments() != nfrag or len(f.bond_live) != nbonds:
                raise Error("load: the fractured object rebuilt to a different shape")
            for i in range(nfrag):
                f.body[i] = Int(_get(data, fp))
                var slot = Int(_get(data, fp))
                var gen = UInt32(_get(data, fp))
                f.bid[i] = BodyId(slot, gen)
                f.nbond[i] = Int(_get(data, fp)) - 1
                f.alive[i] = _get(data, fp) != 0
            for b in range(nbonds):
                f.bond_body_a[b] = Int(_get(data, fp)) - 1
                f.bond_body_b[b] = Int(_get(data, fp)) - 1
                f.bond_joint[b] = Int(_get(data, fp))
                f.bond_live[b] = _get(data, fp) != 0
            f.events.clear()
            self.fracture = f^
            self.frac_params = params^
            self.fracture_on = True
        else:
            self.fracture = FractureSet(Real(1000), 0)
            self.frac_params = List[Float64]()
            self.fracture_on = False
        self.scene = sc^
        self.tick = tick
        self.acc = acc
        self.user = user^
        self.user_gen = user_gen^
        self.frame_events.clear()
        self.frame_fracture.clear()
        self.frame_bubbles.clear()
        self.tick_events.clear()

    def hash(self) -> UInt64:
        """FNV-1a of `save()`, plus, while a water tank is on, its particles and diffuse particles (which save does not
        carry). Host settings (`save_excludes`) are not in it."""
        var b = self.save()
        if self.water_on:
            for v in self.water.px:
                _put(b, UInt64(Float64(v).to_bits()))
            for v in self.water.py:
                _put(b, UInt64(Float64(v).to_bits()))
            for v in self.water.pu:
                _put(b, UInt64(Float64(v).to_bits()))
            for v in self.water.pv:
                _put(b, UInt64(Float64(v).to_bits()))
            for v in self.diffuse.x:
                _put(b, UInt64(Float64(v).to_bits()))
            for v in self.diffuse.y:
                _put(b, UInt64(Float64(v).to_bits()))
        return fnv1a(b)


def save_excludes() -> List[String]:
    """World state that save / load and hash do not carry (tests/test_save_coverage.mojo checks this list, ROADMAP 17.95).

    gravity, solver, unit_scale: host settings. `load` keeps the host's (see its docstring), so a host that changes them
    at run time sets them again after a load; two worlds that differ only in them hash the same.
    host_material: host data, kept by the world across an in-place `load` and carried between modules by
    `embed/transfer.mojo` (ROADMAP 17.91), not by `save`.
    A water tank is not in the list: `save` marks it and `load` refuses the blob, and `hash` covers its particles."""
    var out: List[String] = ["gravity", "solver", "unit_scale", "host_material"]
    return out^


def _build_fracture(
    mut sc: ContactScene6[QuatBody6], mut f: FractureSet, pos: Vec3, half: Vec3, pieces: Int, seed: Int, stress: Real,
    density: Real,
) raises -> Int:
    """add_fracture_box's construction into `f`: Voronoi fragments of the box, welded along shared faces. Returns the
    first fragment's index. Deterministic in its arguments, so load rebuilds the same fragments and welds."""
    var src = Polytope.box(0, 0, 0, Float64(half[0]), Float64(half[1]), Float64(half[2]))
    var seeds = scatter_seeds(src.bounds(), pieces, seed, 0.0, 0.0, 0.0, 0.0)
    var fs = FragmentSet(List[Polytope](), List[Int](), List[Int]())
    voronoi_fracture(src, seeds, 0, 1e-9, fs)
    f = FractureSet(density, 0)
    var first = f.spawn(sc, fs, pos, Quat.identity(), Vec3(0, 0, 0, 0), Vec3(0, 0, 0, 0))
    if f.fragments() == 0:
        raise Error("add_fracture_box: no fragments produced")
    _ = f.bond_neighbors(sc, first, stress)
    return first


def _put(mut out: List[UInt8], v: UInt64):
    for k in range(8):
        out.append(UInt8((v >> UInt64(8 * k)) & 0xFF))


def _get(data: List[UInt8], mut pos: Int) raises -> UInt64:
    if pos + 8 > len(data):
        raise Error("load: blob truncated")
    var v = UInt64(0)
    for k in range(8):
        v |= UInt64(data[pos + k]) << UInt64(8 * k)
    pos += 8
    return v
