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
from geometry.vec import Real, Vec3, length
from geometry.quat import Quat
from physics.body_set import BodyId
from physics.rigid6 import Inertia3, Pose6, QuatBody6
from physics.joints6 import Joint6
from physics.solver6 import ContactScene6
from physics.solver_config import SolverConfig, UnitScale
from physics.serialize import scene_to_bytes, scene_from_bytes
from physics.capture import Capture
from physics.fracture import FractureSet, EVENT_BOND_BROKEN
from physics.flip import FlipWater2
from physics.flip_diffuse import DiffuseParticles
from geometry.polytope import Polytope
from geometry.fracture_cut import FragmentSet, scatter_seeds, voronoi_fracture
from collision.world_query import QueryFilter
from collision.contact_events import ContactEvent

comptime ABI_MAJOR = 0
comptime ABI_MINOR = 7

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
comptime _FNV_OFFSET = UInt64(0xCBF29CE484222325)
comptime _FNV_PRIME = UInt64(0x100000001B3)


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
    var debt_dropped: Int  # frames whose excess time was dropped (FixedLoop's E22 rule)
    var fracture: FractureSet  # 17.90: fragments + bonds added by `add_fracture_box`
    var fracture_on: Bool
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
        self.debt_dropped = 0
        self.fracture = FractureSet(Real(1000), 0)
        self.fracture_on = False
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
        var src = Polytope.box(0, 0, 0, Float64(half[0]), Float64(half[1]), Float64(half[2]))
        var seeds = scatter_seeds(src.bounds(), pieces, seed, 0.0, 0.0, 0.0, 0.0)
        var fs = FragmentSet(List[Polytope](), List[Int](), List[Int]())
        voronoi_fracture(src, seeds, 0, 1e-9, fs)
        self.fracture = FractureSet(density, 0)
        var first = self.fracture.spawn(self.scene, fs, pos, Quat.identity(), Vec3(0, 0, 0, 0), Vec3(0, 0, 0, 0))
        if self.fracture.fragments() == 0:
            raise Error("add_fracture_box: no fragments produced")
        _ = self.fracture.bond_neighbors(self.scene, first, stress)
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
        var s = 1 / n2 ** 0.5
        self.scene.teleport(self._id(h), Pose6(pos, Quat(rot.x * s, rot.y * s, rot.z * s, rot.w * s)))

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
            var s = 1 / n2 ** 0.5
            ids.append(self._id(hs[k]))
            poses.append(Pose6(pos[k], Quat(r.x * s, r.y * s, r.z * s, r.w * s)))
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
            self.debt_dropped += 1
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
        debug_assert(not self.fracture_on and not self.water_on, "save of a world with a fractured object or water is refused by the C-ABI")
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
        return out^

    def load(mut self, data: List[UInt8]) raises:
        """Replace the simulation state with a `save` blob. Settings (dt,
        gravity, solver, systems) are the host's and stay as they are."""
        if self.fracture_on or self.water_on:
            raise Error("load: refused while the world has a fractured object or a water tank")
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
        if pos < len(data):
            if _get(data, pos) != UInt64(_USER_MAGIC):
                raise Error("load: unknown trailer")
            var m = Int(_get(data, pos))
            if m < 0 or pos + 24 * m != len(data):
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
        var sc = scene_from_bytes(body^)
        sc.events_on = True
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
        return fnv1a(self.save())


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
