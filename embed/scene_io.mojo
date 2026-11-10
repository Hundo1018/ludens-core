"""Scene read/write for an editor (ROADMAP 17.12, ludens-core #82).

A scene is the authored content of a world: settings plus its bodies. It is not the deterministic snapshot
(`EmbedWorld.save`, which also holds warm-start caches, sleep timers and the tick) and it carries no file
format. The file format is the host's: ludens-engine defines it (ludens-engine #9) and reads / writes the flat
`SceneField` list below, so a new body property is one new path here and no format change.

  `export_scene(world)`            -> `SceneDoc`        what an editor shows
  `import_scene(world, doc)`       fills an EMPTY world; bit-exact against the snapshot path (test_scene_io)
  `scene_to_fields` / `scene_from_fields`   the doc as (path, canonical text) rows, and back
  `scene_diff` / `scene_apply`     the rows that differ between two scenes, and applying them (prefab overrides)

Slice 1 covers box and sphere bodies (dynamic and static) with pose, velocity, collision layer, host material
and host user data, the per-body physics properties (`BodyProps`: friction, restitution, damping, gravity scale,
speed caps, contact model, sleep, CCD, axis locks), plus gravity, the step and the solver settings. Everything
else a world can hold (joints, kinematic bodies, other shapes, softs, rules, fractured objects, water, custom
inertia tensors, per-body gravity zones, frozen bodies, pending forces) is REFUSED by `export_scene` with a
message that names it, never dropped silently. The next slices add them one by one.

Real numbers are written as `Float64` text, which round-trips every `Real` bit for bit, so
document -> text -> document changes nothing.
"""
from std.math import isfinite
from collision.collider_set import SHAPE_BOX, SHAPE_CAPSULE, SHAPE_SPHERE
from embed.world import EmbedWorld, pack_body, unpack_body
from geometry.quat import Quat
from geometry.vec import Real, Vec3
from physics.ccd6 import CCD_AUTO
from physics.material import COMBINE_AVERAGE, COMBINE_MAX
from physics.joints6 import JOINT_BALL, JOINT_BROKEN, JOINT_DISTANCE, JOINT_HINGE, JOINT_WELD, Joint6
from physics.rigid6 import Inertia3

comptime SCENE_FORMAT_VERSION = 1
comptime BODY_BOX = 0
comptime BODY_SPHERE = 1
comptime BODY_CAPSULE = 2  # size = (radius, half length of the cylinder part, 0)

comptime CHANGE_ADDED = 0
comptime CHANGE_REMOVED = 1
comptime CHANGE_CHANGED = 2


@fieldwise_init
struct BodyProps(Copyable, Movable):
    """The per-body physics properties the solver reads (ROADMAP 17.23, 17.46, 17.48, 17.50). Every default is
    the value a body has before any setter is called, so a scene that never sets one is bit-identical to before."""
    var friction: Real  # < 0 = unset (the step's default friction)
    var static_friction: Real  # < 0 = same as `friction`
    var restitution: Real
    var friction_combine: Int
    var restitution_combine: Int
    var lin_damping: Real
    var ang_damping: Real
    var gravity_scale: Real
    var max_lin: Real  # <= 0 = no cap
    var max_ang: Real
    var rolling: Real
    var spinning: Real
    var contact_hertz: Real  # 0 = the step's
    var contact_zeta: Real
    var adhesion: Real
    var can_sleep: Bool
    var ccd_mode: Int
    var report: Bool
    var sleep_lin: Real  # < 0 = the config's
    var sleep_ang: Real
    var locks: Int  # bits 0..2 linear x/y/z, bits 3..5 angular x/y/z

    @staticmethod
    def defaults() -> Self:
        return Self(
            Real(-1), Real(-1), Real(0), COMBINE_AVERAGE, COMBINE_MAX, Real(0), Real(0), Real(1), Real(0), Real(0),
            Real(0), Real(0), Real(0), Real(0), Real(0), True, CCD_AUTO, False, Real(-1), Real(-1), 0,
        )


@fieldwise_init
struct SceneBody(Copyable, Movable):
    var kind: Int  # BODY_BOX / BODY_SPHERE
    var size: Vec3  # box: half extents; sphere: radius in x
    var mass: Real  # dynamic bodies; 0 for a static body
    var is_static: Bool
    var pos: Vec3
    var rot: Quat
    var vel: Vec3
    var omega: Vec3
    var category: UInt32
    var mask: UInt32
    var material: UInt32
    var user: UInt64
    var props: BodyProps
    var kinematic: Bool  # moved by its velocity, unaffected by forces (17.24); `mass` is kept for inertia

    @staticmethod
    def empty() -> Self:
        """A placeholder record (a body that does not exist): a unit box at the origin with default properties."""
        return Self(
            BODY_BOX, Vec3(1, 1, 1, 0), Real(1), False, Vec3(0, 0, 0, 0), Quat.identity(), Vec3(0, 0, 0, 0),
            Vec3(0, 0, 0, 0), 1, 0xFFFFFFFF, 0, 0, BodyProps.defaults(), False,
        )


@fieldwise_init
struct SceneMaterial(Copyable, Movable):
    """One entry of the surface material table (ROADMAP 17.50): friction and/or contact softness of material `id`.
    `mu < 0` = no friction set, `hertz <= 0` = no softness set."""
    var id: Int
    var mu: Real
    var hertz: Real
    var zeta: Real


struct SceneDoc(Copyable, Movable):
    var version: Int
    var dt: Float64
    var gravity: Vec3
    var iters: Int
    var substeps: Int
    var bodies: List[SceneBody]
    var materials: List[SceneMaterial]
    var joints: List[SceneJoint]

    def __init__(out self):
        self.version = SCENE_FORMAT_VERSION
        self.dt = 1.0 / 60.0
        self.gravity = Vec3(0, 0, 0, 0)
        self.iters = 1
        self.substeps = 1
        self.bodies = List[SceneBody]()
        self.materials = List[SceneMaterial]()
        self.joints = List[SceneJoint]()


@fieldwise_init
struct SceneJoint(Copyable, Movable):
    """A joint between two bodies, named by their position in `SceneDoc.bodies`. `kind` is one of JOINT_BALL /
    JOINT_DISTANCE / JOINT_HINGE / JOINT_WELD; `rest` is the distance of a distance joint; `axis_a` / `axis_b` are
    the hinge axes (a weld keeps its reference rotation in `axis_a` and `rest`, as `Joint6.weld` does)."""
    var kind: Int
    var a: Int
    var b: Int
    var la: Vec3
    var lb: Vec3
    var rest: Real
    var axis_a: Vec3
    var axis_b: Vec3


@fieldwise_init
struct SceneField(Copyable, Movable):
    """One row of a scene: a dotted path and the canonical text of its value."""
    var path: String
    var text: String


@fieldwise_init
struct SceneChange(Copyable, Movable):
    var kind: Int  # CHANGE_ADDED / CHANGE_REMOVED / CHANGE_CHANGED
    var path: String
    var before: String  # empty when added
    var after: String  # empty when removed


# ------------------------------------------------------------------ export


def _same_inertia(a: Inertia3, b: Inertia3) -> Bool:
    return a.mass == b.mass and a.ix == b.ix and a.iy == b.iy and a.iz == b.iz


def export_body(world: EmbedWorld, i: Int) raises -> SceneBody:
    """The scene record of live slot `i`. Raises, naming the feature, if the body is something scene v1 cannot represent."""
    var kin = world.scene.bset.is_kinematic(i)
    var shape = world.scene.colliders.shape[i]
    if shape != SHAPE_BOX and shape != SHAPE_SPHERE and shape != SHAPE_CAPSULE:
        raise Error("export_scene: body " + String(i) + " has shape kind " + String(shape) + " (scene v1 has box, sphere and capsule)")
    ref b = world.scene.bset.bodies[i]
    var half = world.scene.colliders.half[i]
    var is_static = world.scene.bset.is_static(i)
    var kind = BODY_BOX
    if shape == SHAPE_SPHERE:
        kind = BODY_SPHERE
    elif shape == SHAPE_CAPSULE:
        kind = BODY_CAPSULE
    var mass = Real(0)
    if not is_static:
        mass = b.inertia.mass
        var derived = Inertia3.box(mass, half[0], half[1], half[2])
        if kind == BODY_SPHERE:
            derived = Inertia3.sphere(mass, half[0])
        elif kind == BODY_CAPSULE:
            derived = Inertia3.capsule(mass, half[0], half[1])
        if not _same_inertia(derived, b.inertia):
            raise Error("export_scene: body " + String(i) + " has a custom inertia tensor (scene v1 derives it from mass and shape)")
    ref bs = world.scene.bset
    if bs.grav_on[i]:
        raise Error("export_scene: body " + String(i) + " has its own gravity (not representable in scene v1)")
    if bs.frozen_motion[i] >= 0:
        raise Error("export_scene: body " + String(i) + " is frozen (not representable in scene v1)")
    if bs.force[i] != Vec3(0, 0, 0, 0) or bs.torque[i] != Vec3(0, 0, 0, 0):
        raise Error("export_scene: body " + String(i) + " has a force or torque pending for the next step (not representable in scene v1)")
    var props = BodyProps(
        bs.friction[i], bs.static_friction[i], bs.restitution[i], bs.friction_combine[i], bs.restitution_combine[i],
        bs.lin_damping[i], bs.ang_damping[i], bs.gravity_scale[i], bs.max_lin[i], bs.max_ang[i],
        bs.rolling[i], bs.spinning[i], bs.contact_hertz[i], bs.contact_zeta[i], bs.adhesion[i],
        bs.can_sleep[i], Int(bs.ccd_mode[i]), bs.report[i], bs.sleep_lin[i], bs.sleep_ang[i], bs.locks[i],
    )
    var h = pack_body(world.scene.bset.id_of(i))
    return SceneBody(
            kind, half if kind != BODY_CAPSULE else Vec3(half[0], half[1], Real(0), 0), mass, is_static, b.pos, b.q, b.vel, b.omega,
            world.scene.colliders.category[i], world.scene.colliders.mask[i],
            world.get_material(h), world.get_user(h), props^, kin,
    )


def export_scene(world: EmbedWorld) raises -> SceneDoc:
    """The authored content of `world`. Raises, naming the feature, if the world holds anything slice 1 cannot
    represent. Removed slots are skipped, so a world that removed bodies exports compacted."""
    if world.fracture_on:
        raise Error("export_scene: the world has a fractured object (not representable in scene v1)")
    if world.water_on:
        raise Error("export_scene: the world has a water tank (not representable in scene v1)")
    if len(world.scene.softs) > 0:
        raise Error("export_scene: the world has soft bodies (not representable in scene v1)")
    if len(world.scene.rules) > 0:
        raise Error("export_scene: the world has contact rules (not representable in scene v1)")

    var doc = SceneDoc()
    doc.dt = world.dt
    doc.gravity = world.gravity
    doc.iters = world.cfg.iters
    doc.substeps = world.cfg.substeps
    for i in range(len(world.scene.bset.bodies)):
        if world.scene.bset.is_removed(i):
            continue
        doc.bodies.append(export_body(world, i))
    var doc_index = List[Int]()  # body slot -> position in doc.bodies, -1 for removed slots
    var pos = 0
    for i in range(len(world.scene.bset.bodies)):
        if world.scene.bset.is_removed(i):
            doc_index.append(-1)
        else:
            doc_index.append(pos)
            pos += 1
    for c in range(len(world.scene.joints)):
        ref j = world.scene.joints[c]
        if j.kind == JOINT_BROKEN:
            continue  # removed or released: not authored content
        if j.kind != JOINT_BALL and j.kind != JOINT_DISTANCE and j.kind != JOINT_HINGE and j.kind != JOINT_WELD:
            raise Error("export_scene: joint " + String(c) + " has kind " + String(j.kind) + " (scene v1 has ball, distance, hinge and weld joints)")
        if not world.scene.joint_is_plain(c):
            raise Error("export_scene: joint " + String(c) + " has a limit, motor, spring, drive, break threshold or a zero-angle reference that differs from where it was made (not representable in scene v1)")
        doc.joints.append(SceneJoint(j.kind, doc_index[j.a], doc_index[j.b], j.la, j.lb, j.rest, j.axis_a, j.axis_b))
    ref sc = world.scene
    var n_mat = len(sc.material_mu)
    if len(sc.material_hz) > n_mat:
        n_mat = len(sc.material_hz)
    for m in range(n_mat):
        var mu = sc.material_mu[m] if m < len(sc.material_mu) else Real(-1)
        var hz = sc.material_hz[m] if m < len(sc.material_hz) else Real(-1)
        var ze = sc.material_zeta[m] if m < len(sc.material_zeta) else Real(0)
        if mu >= 0 or hz > 0:
            doc.materials.append(SceneMaterial(m, mu, hz if hz > 0 else Real(-1), ze if hz > 0 else Real(0)))
    return doc^


# ------------------------------------------------------------------ import


def _finite3(v: Vec3) -> Bool:
    return isfinite(v[0]) and isfinite(v[1]) and isfinite(v[2])


def _validate_props(p: BodyProps, at: String) raises:
    var d = BodyProps.defaults()
    if not isfinite(p.friction) or (p.friction < 0 and p.friction != d.friction):
        raise Error(at + "friction must be >= 0 (or -1 for unset)")
    if not isfinite(p.static_friction) or (p.static_friction < 0 and p.static_friction != d.static_friction):
        raise Error(at + "static friction must be >= 0 (or -1 for unset)")
    if not (isfinite(p.restitution) and p.restitution >= 0 and p.restitution <= 1):
        raise Error(at + "restitution must be in [0, 1]")
    if not (p.lin_damping >= 0 and p.ang_damping >= 0 and isfinite(p.lin_damping) and isfinite(p.ang_damping)):
        raise Error(at + "damping must be finite and >= 0")
    if not (isfinite(p.gravity_scale) and isfinite(p.max_lin) and isfinite(p.max_ang)):
        raise Error(at + "gravity scale and speed caps must be finite")
    if not (isfinite(p.rolling) and isfinite(p.spinning) and p.rolling >= 0 and p.spinning >= 0):
        raise Error(at + "rolling and spinning resistance must be finite and >= 0")
    if p.contact_hertz != 0 and not (isfinite(p.contact_hertz) and p.contact_hertz > 0 and isfinite(p.contact_zeta) and p.contact_zeta >= 0):
        raise Error(at + "contact hertz must be > 0 and zeta >= 0")
    if p.contact_hertz == 0 and p.contact_zeta != 0:
        raise Error(at + "contact zeta is set without contact hertz")
    if not (isfinite(p.adhesion) and p.adhesion >= 0):
        raise Error(at + "adhesion must be finite and >= 0")
    if p.ccd_mode < 0 or p.ccd_mode > 2:
        raise Error(at + "ccd must be 0, 1 or 2")
    if not (isfinite(p.sleep_lin) and isfinite(p.sleep_ang)):
        raise Error(at + "sleep thresholds must be finite")
    if p.locks < 0 or p.locks > 63:
        raise Error(at + "locks must be a 6-bit mask")


def _validate(doc: SceneDoc) raises:
    """Every check import needs, before it touches the world, so a bad document changes nothing."""
    if doc.version != SCENE_FORMAT_VERSION:
        raise Error("import_scene: scene version " + String(doc.version) + " (this build reads " + String(SCENE_FORMAT_VERSION) + ")")
    if not (doc.dt > 0) or not isfinite(doc.dt):
        raise Error("import_scene: dt must be finite and > 0")
    if not _finite3(doc.gravity):
        raise Error("import_scene: gravity must be finite")
    if doc.iters < 1 or doc.substeps < 1:
        raise Error("import_scene: solver iterations and substeps must be >= 1")
    for k in range(len(doc.joints)):
        ref j = doc.joints[k]
        var at = "import_scene: joint " + String(k) + ": "
        if j.kind != JOINT_BALL and j.kind != JOINT_DISTANCE and j.kind != JOINT_HINGE and j.kind != JOINT_WELD:
            raise Error(at + "unknown kind " + String(j.kind))
        if j.a < 0 or j.a >= len(doc.bodies) or j.b < 0 or j.b >= len(doc.bodies):
            raise Error(at + "body index out of range")
        if j.a == j.b:
            raise Error(at + "the two bodies must differ")
        if not (_finite3(j.la) and _finite3(j.lb) and _finite3(j.axis_a) and _finite3(j.axis_b) and isfinite(j.rest)):
            raise Error(at + "anchors, axes and rest length must be finite")
        if j.kind == JOINT_DISTANCE and j.rest < 0:
            raise Error(at + "rest length must be >= 0")
    for k in range(len(doc.materials)):
        ref m = doc.materials[k]
        var at = "import_scene: material " + String(k) + ": "
        if m.id < 0 or m.id > 65535:
            raise Error(at + "id must be in 0 .. 65535")
        for j in range(k):
            if doc.materials[j].id == m.id:
                raise Error(at + "id " + String(m.id) + " appears twice")
        if not (m.mu < 0 or (isfinite(m.mu) and m.mu >= 0)):
            raise Error(at + "friction must be >= 0 (or -1 for unset)")
        if m.hertz > 0 and not (isfinite(m.hertz) and isfinite(m.zeta) and m.zeta >= 0):
            raise Error(at + "softness needs finite hertz > 0 and zeta >= 0")
        if m.mu < 0 and not (m.hertz > 0):
            raise Error(at + "sets neither friction nor softness")
    for i in range(len(doc.bodies)):
        ref b = doc.bodies[i]
        var at = "import_scene: body " + String(i) + ": "
        if b.kind != BODY_BOX and b.kind != BODY_SPHERE and b.kind != BODY_CAPSULE:
            raise Error(at + "unknown kind " + String(b.kind))
        if b.kind == BODY_CAPSULE and not (isfinite(b.size[0]) and b.size[0] > 0 and isfinite(b.size[1]) and b.size[1] > 0):
            raise Error(at + "capsule radius and half length must be finite and > 0")
        if b.kinematic and b.is_static:
            raise Error(at + "a body cannot be both static and kinematic")
        if b.kind == BODY_BOX and not (_finite3(b.size) and b.size[0] > 0 and b.size[1] > 0 and b.size[2] > 0):
            raise Error(at + "half extents must be finite and > 0")
        if b.kind == BODY_SPHERE and not (isfinite(b.size[0]) and b.size[0] > 0):
            raise Error(at + "radius must be finite and > 0")
        if not b.is_static and not (isfinite(b.mass) and b.mass > 0):
            raise Error(at + "mass must be finite and > 0")
        if not (_finite3(b.pos) and _finite3(b.vel) and _finite3(b.omega)):
            raise Error(at + "pose and velocity must be finite")
        var n2 = b.rot.x * b.rot.x + b.rot.y * b.rot.y + b.rot.z * b.rot.z + b.rot.w * b.rot.w
        if not isfinite(n2) or n2 < Real(0.99) or n2 > Real(1.01):
            raise Error(at + "rotation must be a unit quaternion")
        _validate_props(b.props, at)


def _apply_props(mut world: EmbedWorld, slot: Int, p: BodyProps) raises:
    """Only what differs from the defaults is set, through the scene's own setters, so the `any_*` flags the
    solver gates on are raised exactly when a property is in use."""
    var d = BodyProps.defaults()
    var id = world.scene.bset.id_of(slot)
    if p.restitution != d.restitution:
        world.scene.set_restitution(slot, p.restitution)
    if p.restitution_combine != d.restitution_combine:
        world.scene.set_restitution_combine(slot, p.restitution_combine)
    if p.friction >= 0:
        world.scene.set_friction(slot, p.friction)
    if p.static_friction >= 0:
        world.scene.set_static_friction(slot, p.static_friction)
    if p.friction_combine != d.friction_combine:
        world.scene.set_friction_combine(slot, p.friction_combine)
    if p.lin_damping != 0 or p.ang_damping != 0:
        world.scene.set_damping(id, p.lin_damping, p.ang_damping)
    if p.gravity_scale != d.gravity_scale:
        world.scene.set_gravity_scale(id, p.gravity_scale)
    if p.max_lin != 0 or p.max_ang != 0:
        world.scene.set_max_velocity(id, p.max_lin, p.max_ang)
    if p.rolling != 0:
        world.scene.set_rolling_resistance(slot, p.rolling)
    if p.spinning != 0:
        world.scene.set_spinning_resistance(slot, p.spinning)
    if p.contact_hertz != 0:
        world.scene.set_contact_softness(slot, p.contact_hertz, p.contact_zeta)
    if p.adhesion != 0:
        world.scene.set_adhesion(slot, p.adhesion)
    if not p.can_sleep:
        world.scene.set_can_sleep(id, False)
    if p.ccd_mode != d.ccd_mode:
        world.scene.set_ccd_mode(id, p.ccd_mode)
    if p.report:
        world.scene.set_contact_reporting(id, True)
    if p.sleep_lin != d.sleep_lin or p.sleep_ang != d.sleep_ang:
        world.scene.set_sleep_thresholds(id, p.sleep_lin, p.sleep_ang)
    if p.locks != 0:
        world.scene.set_axis_locks(
            id, (p.locks & 1) != 0, (p.locks & 2) != 0, (p.locks & 4) != 0,
            (p.locks & 8) != 0, (p.locks & 16) != 0, (p.locks & 32) != 0,
        )


def add_body_record(mut world: EmbedWorld, s: SceneBody) raises -> Int64:
    """Add the body `s` describes and return its handle. The record must be valid (`import_scene` checks a whole
    document first; `restore_body` checks one record)."""
    var h: Int64
    if s.kind == BODY_BOX:
        h = world.add_box(s.pos, s.size, s.mass, s.is_static)
    elif s.kind == BODY_CAPSULE:
        h = world.add_capsule(s.pos, s.size[0], s.size[1], s.mass, s.is_static)
    else:
        h = world.add_sphere(s.pos, s.size[0], s.mass, s.is_static)
    if s.kinematic:
        world.set_kinematic(h)
    var slot = unpack_body(h).index()
    world.scene.bset.bodies[slot].q = s.rot
    world.scene.bset.bodies[slot].vel = s.vel
    world.scene.bset.bodies[slot].omega = s.omega
    _apply_props(world, slot, s.props)
    world.set_layer(h, s.category, s.mask)
    if s.material != 0:
        world.set_material(h, s.material)
    if s.user != 0:
        world.set_user(h, s.user)
    return h


def import_scene(mut world: EmbedWorld, doc: SceneDoc) raises:
    """Fill an empty world with `doc`. The rotation is stored as it is, not renormalized, so a document made by
    `export_scene` gives back the exact state it came from."""
    _validate(doc)
    if len(world.scene.bset.bodies) != 0 or world.fracture_on or world.water_on:
        raise Error("import_scene: the world must be empty")
    world.set_gravity(doc.gravity)
    world.set_solver(doc.iters, doc.substeps)
    world.dt = doc.dt
    for i in range(len(doc.bodies)):
        _ = add_body_record(world, doc.bodies[i])
    for k in range(len(doc.joints)):
        ref j = doc.joints[k]
        var zero = Vec3(0, 0, 0, 0)
        _ = world.scene.add_joint(Joint6(j.kind, j.a, j.b, j.la, j.lb, j.rest, j.axis_a, j.axis_b, zero, zero, 1))
    for k in range(len(doc.materials)):
        ref m = doc.materials[k]
        if m.mu >= 0:
            world.set_material_friction(m.id, m.mu)
        if m.hertz > 0:
            world.set_material_softness(m.id, m.hertz, m.zeta)


# ------------------------------------------------------------------ fields


def _t(r: Real) -> String:
    return String(Float64(r))


def _push(mut out: List[SceneField], path: String, text: String):
    out.append(SceneField(path, text))


def _push_vec(mut out: List[SceneField], path: String, v: Vec3):
    _push(out, path + ".x", _t(v[0]))
    _push(out, path + ".y", _t(v[1]))
    _push(out, path + ".z", _t(v[2]))


def _push_body(mut out: List[SceneField], i: Int, b: SceneBody):
    var p = "body." + String(i) + "."
    _push(out, p + "kind", "box" if b.kind == BODY_BOX else ("sphere" if b.kind == BODY_SPHERE else "capsule"))
    _push_vec(out, p + "size", b.size)
    _push(out, p + "static", "true" if b.is_static else "false")
    if b.kinematic:  # only written when set, so scenes without kinematic bodies keep their rows
        _push(out, p + "kinematic", "true")
    _push(out, p + "mass", _t(b.mass))
    _push_vec(out, p + "pos", b.pos)
    _push(out, p + "rot.x", _t(b.rot.x))
    _push(out, p + "rot.y", _t(b.rot.y))
    _push(out, p + "rot.z", _t(b.rot.z))
    _push(out, p + "rot.w", _t(b.rot.w))
    _push_vec(out, p + "vel", b.vel)
    _push_vec(out, p + "omega", b.omega)
    _push(out, p + "category", String(b.category))
    _push(out, p + "mask", String(b.mask))
    _push(out, p + "material", String(b.material))
    _push(out, p + "user", String(b.user))
    ref q = b.props
    _push(out, p + "friction", _t(q.friction))
    _push(out, p + "static_friction", _t(q.static_friction))
    _push(out, p + "restitution", _t(q.restitution))
    _push(out, p + "friction_combine", String(q.friction_combine))
    _push(out, p + "restitution_combine", String(q.restitution_combine))
    _push(out, p + "lin_damping", _t(q.lin_damping))
    _push(out, p + "ang_damping", _t(q.ang_damping))
    _push(out, p + "gravity_scale", _t(q.gravity_scale))
    _push(out, p + "max_lin", _t(q.max_lin))
    _push(out, p + "max_ang", _t(q.max_ang))
    _push(out, p + "rolling", _t(q.rolling))
    _push(out, p + "spinning", _t(q.spinning))
    _push(out, p + "contact_hertz", _t(q.contact_hertz))
    _push(out, p + "contact_zeta", _t(q.contact_zeta))
    _push(out, p + "adhesion", _t(q.adhesion))
    _push(out, p + "can_sleep", "true" if q.can_sleep else "false")
    _push(out, p + "ccd", String(q.ccd_mode))
    _push(out, p + "report", "true" if q.report else "false")
    _push(out, p + "sleep_lin", _t(q.sleep_lin))
    _push(out, p + "sleep_ang", _t(q.sleep_ang))
    _push(out, p + "locks", String(q.locks))


def scene_to_fields(doc: SceneDoc) -> List[SceneField]:
    """The scene as rows in a fixed order: settings, then each body's properties."""
    var out = List[SceneField]()
    _push(out, "version", String(doc.version))
    _push(out, "dt", String(doc.dt))
    _push_vec(out, "gravity", doc.gravity)
    _push(out, "solver.iters", String(doc.iters))
    _push(out, "solver.substeps", String(doc.substeps))
    _push(out, "bodies.count", String(len(doc.bodies)))
    for i in range(len(doc.bodies)):
        _push_body(out, i, doc.bodies[i])
    if len(doc.joints) > 0:  # only written when there are joints, so scenes without joints keep their rows
        _push(out, "joints.count", String(len(doc.joints)))
        for k in range(len(doc.joints)):
            var p = "joint." + String(k) + "."
            ref j = doc.joints[k]
            var kn = "ball"
            if j.kind == JOINT_DISTANCE:
                kn = "distance"
            elif j.kind == JOINT_HINGE:
                kn = "hinge"
            elif j.kind == JOINT_WELD:
                kn = "weld"
            _push(out, p + "kind", kn)
            _push(out, p + "a", String(j.a))
            _push(out, p + "b", String(j.b))
            _push_vec(out, p + "la", j.la)
            _push_vec(out, p + "lb", j.lb)
            _push(out, p + "rest", _t(j.rest))
            _push_vec(out, p + "axis_a", j.axis_a)
            _push_vec(out, p + "axis_b", j.axis_b)
    if len(doc.materials) > 0:  # only written when the table is not empty, so scenes without one keep their rows
        _push(out, "materials.count", String(len(doc.materials)))
        for k in range(len(doc.materials)):
            var p = "material." + String(k) + "."
            _push(out, p + "id", String(doc.materials[k].id))
            _push(out, p + "friction", _t(doc.materials[k].mu))
            _push(out, p + "hertz", _t(doc.materials[k].hertz))
            _push(out, p + "zeta", _t(doc.materials[k].zeta))
    return out^


struct _Rows:
    var d: Dict[String, String]

    def __init__(out self, fields: List[SceneField]):
        self.d = Dict[String, String]()
        for i in range(len(fields)):
            self.d[fields[i].path] = fields[i].text

    def has(self, path: String) -> Bool:
        return path in self.d

    def text(self, path: String) raises -> String:
        if path not in self.d:
            raise Error("scene_from_fields: missing field `" + path + "`")
        return self.d[path]

    def real(self, path: String) raises -> Real:
        return Real(Float64(self.text(path)))

    def int(self, path: String) raises -> Int:
        return Int(self.text(path))

    def uint(self, path: String) raises -> UInt64:
        """A non-negative integer up to 2^64 - 1, parsed digit by digit (`Int` stops at 2^63 - 1)."""
        var text = self.text(path)
        var bytes = text.as_bytes()
        if len(bytes) == 0:
            raise Error("scene_from_fields: `" + path + "` is empty")
        var v = UInt64(0)
        for i in range(len(bytes)):
            var d = Int(bytes[i]) - 48
            if d < 0 or d > 9:
                raise Error("scene_from_fields: `" + path + "` must be a non-negative integer, got `" + text + "`")
            if v > (UInt64(0xFFFFFFFFFFFFFFFF) - UInt64(d)) // 10:
                raise Error("scene_from_fields: `" + path + "` does not fit 64 bits: `" + text + "`")
            v = v * 10 + UInt64(d)
        return v

    def vec(self, path: String) raises -> Vec3:
        return Vec3(self.real(path + ".x"), self.real(path + ".y"), self.real(path + ".z"), 0)

    def flag(self, path: String) raises -> Bool:
        var t = self.text(path)
        if t == "true":
            return True
        if t == "false":
            return False
        raise Error("scene_from_fields: `" + path + "` must be true or false, got `" + t + "`")


def scene_from_fields(fields: List[SceneField]) raises -> SceneDoc:
    """Rebuild a document from rows. Strict: a missing or malformed row raises with its path. Rows that this
    build does not know are ignored, so a newer file still opens (the version row says what it needs)."""
    var rows = _Rows(fields)
    var doc = SceneDoc()
    doc.version = rows.int("version")
    doc.dt = Float64(rows.text("dt"))
    doc.gravity = rows.vec("gravity")
    doc.iters = rows.int("solver.iters")
    doc.substeps = rows.int("solver.substeps")
    var n = rows.int("bodies.count")
    if n < 0:
        raise Error("scene_from_fields: bodies.count must be >= 0")
    for i in range(n):
        var p = "body." + String(i) + "."
        var kind_text = rows.text(p + "kind")
        var kind: Int
        if kind_text == "box":
            kind = BODY_BOX
        elif kind_text == "sphere":
            kind = BODY_SPHERE
        elif kind_text == "capsule":
            kind = BODY_CAPSULE
        else:
            raise Error("scene_from_fields: `" + p + "kind` must be box, sphere or capsule, got `" + kind_text + "`")
        doc.bodies.append(
            SceneBody(
                kind, rows.vec(p + "size"), rows.real(p + "mass"), rows.flag(p + "static"),
                rows.vec(p + "pos"),
                Quat(rows.real(p + "rot.x"), rows.real(p + "rot.y"), rows.real(p + "rot.z"), rows.real(p + "rot.w")),
                rows.vec(p + "vel"), rows.vec(p + "omega"),
                UInt32(rows.uint(p + "category")), UInt32(rows.uint(p + "mask")),
                UInt32(rows.uint(p + "material")), rows.uint(p + "user"),
                BodyProps(
                    rows.real(p + "friction"), rows.real(p + "static_friction"), rows.real(p + "restitution"),
                    rows.int(p + "friction_combine"), rows.int(p + "restitution_combine"),
                    rows.real(p + "lin_damping"), rows.real(p + "ang_damping"), rows.real(p + "gravity_scale"),
                    rows.real(p + "max_lin"), rows.real(p + "max_ang"), rows.real(p + "rolling"),
                    rows.real(p + "spinning"), rows.real(p + "contact_hertz"), rows.real(p + "contact_zeta"),
                    rows.real(p + "adhesion"), rows.flag(p + "can_sleep"), rows.int(p + "ccd"),
                    rows.flag(p + "report"), rows.real(p + "sleep_lin"), rows.real(p + "sleep_ang"),
                    rows.int(p + "locks"),
                ),
                rows.has(p + "kinematic") and rows.flag(p + "kinematic"),
            )
        )
    if rows.has("joints.count"):
        var nj = rows.int("joints.count")
        if nj < 0:
            raise Error("scene_from_fields: joints.count must be >= 0")
        for k in range(nj):
            var p = "joint." + String(k) + "."
            var kt = rows.text(p + "kind")
            var kind = JOINT_BALL
            if kt == "distance":
                kind = JOINT_DISTANCE
            elif kt == "hinge":
                kind = JOINT_HINGE
            elif kt == "weld":
                kind = JOINT_WELD
            elif kt != "ball":
                raise Error("scene_from_fields: `" + p + "kind` must be ball, distance, hinge or weld, got `" + kt + "`")
            doc.joints.append(SceneJoint(kind, rows.int(p + "a"), rows.int(p + "b"), rows.vec(p + "la"), rows.vec(p + "lb"), rows.real(p + "rest"), rows.vec(p + "axis_a"), rows.vec(p + "axis_b")))
    if rows.has("materials.count"):
        var nm = rows.int("materials.count")
        if nm < 0:
            raise Error("scene_from_fields: materials.count must be >= 0")
        for k in range(nm):
            var p = "material." + String(k) + "."
            doc.materials.append(SceneMaterial(rows.int(p + "id"), rows.real(p + "friction"), rows.real(p + "hertz"), rows.real(p + "zeta")))
    return doc^


# -------------------------------------------------------------------- diff


def scene_diff(a: List[SceneField], b: List[SceneField]) -> List[SceneChange]:
    """What turns `a` into `b`, row by row: removed and changed rows in the order of `a`, then added rows in the
    order of `b`. Body rows are addressed by position (`body.3.pos.x`), so inserting a body in the middle shows
    up as the changes of every body after it."""
    var out = List[SceneChange]()
    var in_b = Dict[String, String]()
    for i in range(len(b)):
        in_b[b[i].path] = b[i].text
    var in_a = Dict[String, String]()
    for i in range(len(a)):
        in_a[a[i].path] = a[i].text
    for i in range(len(a)):
        var path = a[i].path
        var other = in_b.get(path)
        if not other:
            out.append(SceneChange(CHANGE_REMOVED, path, a[i].text, String()))
        elif other.value() != a[i].text:
            out.append(SceneChange(CHANGE_CHANGED, path, a[i].text, other.value()))
    for i in range(len(b)):
        if b[i].path not in in_a:
            out.append(SceneChange(CHANGE_ADDED, b[i].path, String(), b[i].text))
    return out^


def scene_apply(base: List[SceneField], changes: List[SceneChange]) raises -> List[SceneField]:
    """`base` with `changes` applied: a prefab instance is its prefab's rows plus the instance's changes. A change
    whose `before` does not match the row it touches raises, so an override never lands on the wrong base."""
    var removed = Dict[String, Bool]()
    var changed = Dict[String, String]()
    var before = Dict[String, String]()
    var added = List[SceneField]()
    for i in range(len(changes)):
        ref c = changes[i]
        if c.kind == CHANGE_ADDED:
            added.append(SceneField(c.path, c.after))
        elif c.kind == CHANGE_REMOVED:
            removed[c.path] = True
            before[c.path] = c.before
        else:
            changed[c.path] = c.after
            before[c.path] = c.before
    var out = List[SceneField]()
    for i in range(len(base)):
        var path = base[i].path
        if path in before and before[path] != base[i].text:
            raise Error("scene_apply: `" + path + "` is `" + base[i].text + "`, the change expects `" + before[path] + "`")
        if path in removed:
            continue
        if path in changed:
            out.append(SceneField(path, changed[path]))
        else:
            out.append(SceneField(path, base[i].text))
    for i in range(len(added)):
        out.append(added[i].copy())
    return out^


# --------------------------------------------------------- single-body records (undo / redo, ROADMAP 17.43)


def body_equal(a: SceneBody, b: SceneBody) -> Bool:
    """True when every row of the two records is equal."""
    var ra = List[SceneField]()
    var rb = List[SceneField]()
    _push_body(ra, 0, a)
    _push_body(rb, 0, b)
    if len(ra) != len(rb):
        return False
    for i in range(len(ra)):
        if ra[i].text != rb[i].text:
            return False
    return True


def same_shape(a: SceneBody, b: SceneBody) -> Bool:
    """Same kind, size, mass and motion type: the record can be written in place (a different shape needs the body
    removed and added again)."""
    return (
        a.kind == b.kind and a.size[0] == b.size[0] and a.size[1] == b.size[1] and a.size[2] == b.size[2]
        and a.mass == b.mass and a.is_static == b.is_static and a.kinematic == b.kinematic
    )


def body_record(world: EmbedWorld, h: Int64) raises -> SceneBody:
    if not world.is_alive(h):
        raise Error("body_record: the handle is not a live body")
    return export_body(world, unpack_body(h).index())


def _check_record(s: SceneBody) raises:
    var doc = SceneDoc()
    doc.bodies.append(s.copy())
    _validate(doc)


def _refresh_flags(mut world: EmbedWorld):
    """`any_report` and `any_bullet` mean "some live body is flagged"; recompute them so removing the last flagged
    body (or writing its flag off) switches the solver's special case off again, as the setters do."""
    var any_report = False
    var any_bullet = False
    for k in range(len(world.scene.bset.bodies)):
        if world.scene.bset.is_removed(k):
            continue
        if world.scene.bset.report[k]:
            any_report = True
        if Int(world.scene.bset.ccd_mode[k]) == 2:
            any_bullet = True
    world.scene.bset.any_report = any_report
    world.scene.bset.any_bullet = any_bullet


def _write_props(mut world: EmbedWorld, slot: Int, p: BodyProps):
    """Write every property of slot `slot`, defaults included (the setters cannot set "unset" again). The flags the
    solver gates on only go up here, except the two `_refresh_flags` recomputes."""
    ref bs = world.scene.bset
    bs.friction[slot] = p.friction
    bs.static_friction[slot] = p.static_friction
    bs.restitution[slot] = p.restitution
    bs.friction_combine[slot] = p.friction_combine
    bs.restitution_combine[slot] = p.restitution_combine
    bs.lin_damping[slot] = p.lin_damping
    bs.ang_damping[slot] = p.ang_damping
    bs.gravity_scale[slot] = p.gravity_scale
    bs.max_lin[slot] = p.max_lin
    bs.max_ang[slot] = p.max_ang
    bs.rolling[slot] = p.rolling
    bs.spinning[slot] = p.spinning
    bs.contact_hertz[slot] = p.contact_hertz
    bs.contact_zeta[slot] = p.contact_zeta
    bs.adhesion[slot] = p.adhesion
    bs.can_sleep[slot] = p.can_sleep
    bs.ccd_mode[slot] = UInt8(p.ccd_mode)
    bs.report[slot] = p.report
    bs.sleep_lin[slot] = p.sleep_lin
    bs.sleep_ang[slot] = p.sleep_ang
    bs.locks[slot] = p.locks
    var d = BodyProps.defaults()
    if (
        p.lin_damping != 0 or p.ang_damping != 0 or p.gravity_scale != d.gravity_scale or p.max_lin != 0
        or p.max_ang != 0 or p.locks != 0 or p.sleep_lin != d.sleep_lin or p.sleep_ang != d.sleep_ang
    ):
        bs.any_props = True
    if p.static_friction >= 0 or p.rolling != 0 or p.spinning != 0 or p.contact_hertz != 0 or p.adhesion != 0:
        bs.any_contact_model = True
    _refresh_flags(world)


def write_body_record(mut world: EmbedWorld, h: Int64, s: SceneBody) raises:
    """Overwrite the live body `h` with the record `s`, in place: pose, velocities, properties, collision layer, host
    material and user data. The shape and mass must be the body's own (`same_shape`); otherwise remove the body and
    `restore_body` it. Wakes the body, as the engine's own setters do."""
    _check_record(s)
    if not world.is_alive(h):
        raise Error("write_body_record: the handle is not a live body")
    var slot = unpack_body(h).index()
    if not same_shape(export_body(world, slot), s):
        raise Error("write_body_record: the record has a different shape or mass than the body")
    world.scene.bset.bodies[slot].pos = s.pos
    world.scene.bset.bodies[slot].q = s.rot
    world.scene.bset.bodies[slot].vel = s.vel
    world.scene.bset.bodies[slot].omega = s.omega
    _write_props(world, slot, s.props)
    world.set_layer(h, s.category, s.mask)
    world.set_material(h, s.material)
    world.set_user(h, s.user)
    world.scene.wake(world.scene.bset.id_of(slot))


def restore_body(mut world: EmbedWorld, h: Int64, s: SceneBody) raises:
    """Add the body `s` describes back with the identity (slot and generation) `h` had before it was removed, so
    handles held by an editor (selection, references) are valid again."""
    _check_record(s)
    world.reserve_slot(h)
    var got = add_body_record(world, s)
    if got != h:
        raise Error("restore_body: the engine gave a different handle than the one reserved")
