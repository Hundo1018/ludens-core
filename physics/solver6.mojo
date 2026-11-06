"""6-DOF contact solving: `ContactManifold` points -> sequential impulses.

The engine's 3-D contact solver (the earlier 2-D linear-only path was
removed on 2026-09-29). `ContactScene6[B, BP]` is generic over the `Body6`
representation (quat+tensor or motor+screw) AND over the `BroadPhase`
backend that enumerates candidate pairs (`collision.broadphase`; defaults to
the rebuild-per-step BVH), so the same scene is both a parity gate between
the classical and the GA path, and a parity gate across every broadphase
backend (`tests/test_solver_bp_seam.mojo`).

The collider registry (shape kinds, hull/mesh/heightfield tables, filters,
sensors) and the shape-pair narrowphase dispatch live in
`collision.collider_set.ColliderSet` (audit finding F1) — this scene *holds*
one (`self.colliders`) instead of owning that data itself, so 17.13 scene
queries and the 17.1 character controller can use the real collider geometry
without importing physics. Candidate-pair enumeration through the
`BroadPhase` seam and the geometry half of the per-pair narrowphase test live
in `collision.contact_gen` (finding F2); this module keeps warm-start
matching and the body-frame anchor / approach-speed prep that need a
`Body6` (`collision.contact_gen`'s docstring explains the split).

Two step modes share the collision prep:

  * `step` — one-shot: gravity -> manifolds -> Gauss-Seidel accumulated
    normal impulses with a Baumgarte velocity bias -> pose integration.
  * `step_soft` — SUB-STEPPED SOFT-CONSTRAINT solver (Box2D v3 "Soft Step" /
    Small Steps): collide once per frame, then n substeps of {integrate
    velocities -> soft-biased impulse sweeps -> integrate poses -> a bias-free
    RELAX sweep that removes the bias energy}. Contact separation is updated
    across substeps from body translation along the normal (rotation term
    neglected — small per substep). Soft coefficients follow Solver2D:
    ω = 2π·hertz, biasRate = ω/(2ζ + hω), c = hω(2ζ + hω),
    massScale = c/(1+c), impulseScale = 1/(1+c).

`step_soft` also solves Coulomb friction (two tangent impulses per point,
clamped to μ·λₙ) — without it, box spin is undamped and, since the box
narrowphase is axis-aligned, geometrically unconstrained. Restitution is still
deferred (e = 0 scenes).
"""

from std.math import sqrt, isfinite
from geometry.trig import sin, cos
from std.os import abort
from std.time import perf_counter_ns
from std.collections import Dict
from scheduler.dispatch import Dispatch, Task, dispatch_for
from geometry.vec import Real, Vec3, WorldType, dot, cross, tangent_basis
from geometry.aabb import AABB
from geometry.quat import Quat
from collision.manifold import ContactManifold, Axes3
from collision.world_query import (
    QueryFilter,
    Hit,
    Probe,
    Penetration,
    ray_cast as wq_ray_cast,
    sphere_cast as wq_sphere_cast,
    capsule_cast as wq_capsule_cast,
    overlap_sphere as wq_overlap_sphere,
    capsule_penetrations as wq_capsule_penetrations,
    point_distance as wq_point_distance,
    ray_cast_all as wq_ray_cast_all,
    ray_cast_any as wq_ray_cast_any,
    ray_cast_indexed as wq_ray_cast_indexed,
    shape_cast as wq_shape_cast,
    overlap_shape as wq_overlap_shape,
    shape_penetrations as wq_shape_penetrations,
    closest_points as wq_closest_points,
    QueryShape,
    QueryIndex,
)
from geometry.gjk_distance import ConvexDistance
from collision.collider_set import (
    SPEC_BASE,
    ColliderSet,
    Pose3,
    SHAPE_BOX,
    SHAPE_SPHERE,
    SHAPE_CAPSULE,
    SHAPE_HULL,
    SHAPE_TRIMESH,
    SHAPE_HEIGHTFIELD,
    SHAPE_SDF,
    SHAPE_ELLIPSOID,
)
from geometry.sdf_grid import SdfGrid
from collision.collider_set import CompoundSpec, ShapeDesc, SHAPE_COMPOUND, COMPOUND_MAX_CHILDREN
from .mass_props import compound_mass
from collision.contact_gen import RawContact, collect_bp_pairs, try_pair
from collision.contact_events import ContactEvent, pack_key, diff_events, EV_STAY, EV_ENDED
from collision.broadphase import BroadPhase, Pair
from collision.bp_bvh import BVHBroadPhase
from collision.toi import swept_box_toi
from collision.hull import HullShape
from collision.trimesh import TriMesh, HeightField
from diag.counters import (
    Counters, PARALLEL_FALLBACK_SERIAL, COLOR_OVERFLOW, NAN_QUARANTINED, TIER_FALLBACK,
    NARROWPHASE_PAIRS, CONTACT_MANIFOLDS, CONTACT_POINTS, VELOCITY_CLAMPED, TRACE_DROPPED, CONTACT_DROPPED,
)
from diag.log import LogRing, log
from diag.level import Level, DEBUG_DRAW_ON, TRACE_ON
from diag.trace import TraceBuffer
from diag.draw import DrawQueue
from .rigid6 import Body6, QuatBody6, Inertia3, Pose6
from .body_set import BodySet, BodyId, MOTION_STATIC, MOTION_DYNAMIC, MOTION_KINEMATIC
from .solver_config import SolverConfig, IMPULSE_SUBSTEP_SUM, IMPULSE_LAST_SUBSTEP, CONTACT_BLOCK, MASS_RATIO_DEFAULT
from .state_io import StateWriter, StateReader
from .softbody import SoftBody, SP, SEdge
from .contact6 import (
    island_color,
    ContactConstraint,
    contact_island,
    make_contact,
    cache_index,
    make_sensor_contact,
    warm_start_contacts,
    solve_point,
    soft_sweep,
    sweep_colored,
    restitution_pass,
    accumulate_step_impulse,
    add_restitution_impulse,
    ContactRule,
    apply_rules,
)
from .joints6 import (
    Joint6,
    _scaled_linear,
    JOINT_BALL,
    JOINT_DISTANCE,
    JOINT_HINGE,
    JOINT_WELD,
    warm_start_joints,
    joint_sweep,
    JOINT_BROKEN,
    check_breaks,
    sample_loads,
    AngularDrive,
    warm_start_drives,
    drive_sweep,
    joint_island,
    JOINT_SLIDER,
    JOINT_CONE_TWIST,
    JOINT_ROPE,
    JOINT_D6,
)
from .joint_ext import (
    JointExt,
    MOTOR_NONE,
    MOTOR_VELOCITY,
    MOTOR_POSITION,
    ext_sweep,
    warm_start_ext,
    ext_impulse,
    sample_ext_loads,
    D6_FREE,
    D6_LOCKED,
    D6_LIMITED,
    D6_ALL_LOCKED,
    joint_coordinate,
)
from .islands import (
    island_count as count_islands,
    island_labels,
    refresh_islands,
    update_sleep,
    wake_island,
)
from .ccd6 import ccd_advance, ccd_advance_island, CCD_AUTO, CCD_OFF, CCD_BULLET
from .collide_par import narrow_parallel, prep_parallel, pairs_parallel, NARROW_PAR_MIN, BP_PAR_MIN
from .soft_couple import softbody_pass


# The `_Pt` / `_LV` / `_Half` wrappers that used to sit here existed for one
# stated reason: a bare `List[SIMD[_, 3]]` corrupted on realloc. Width 3 was
# never a supported SIMD width; `Vec3` is four lanes now and the claim was
# retested before removal -- a list grown from capacity 0 to 10,000 elements
# reads back with zero wrong entries.


# `ContactScene6.add_force` modes (ROADMAP 17.48; Unity's ForceMode names).
comptime FORCE_MODE_FORCE = 0  # N, over the next step
comptime FORCE_MODE_IMPULSE = 1  # N s, now
comptime FORCE_MODE_VELOCITY_CHANGE = 2  # m/s, now (mass-independent)
comptime FORCE_MODE_ACCELERATION = 3  # m/s^2, over the next step (mass-independent)


@fieldwise_init
struct ContactReport(Copyable, ImplicitlyCopyable, Movable):
    """One contact of a body, from that body's side (ROADMAP 17.49,
    `ContactScene6.contacts_of`). Impulses are this step's totals; `force`
    is the impulse over the time it covers."""

    var other: Int  # the other body's slot
    var feat: Int  # triangle index for mesh contacts, 0 otherwise
    var point: Vec3  # contact point carrying the largest normal impulse
    var normal: Vec3  # from this body toward the other
    var normal_impulse: Real  # >= 0 (N s)
    var impulse: Vec3  # on this body: normal + friction (N s)
    var force: Vec3  # impulse / step time (N)


def _excess_jn(pr: ContactConstraint, jn: Real) -> Real:
    """ROADMAP 17.19 A2: a pair's compressive normal impulse `jn` (summed
    over its points) less the scaled excess its report carries
    (`ContactScene6._report_excess`). The excess is on the pair, so the
    sign is the side it supports: +1 when `pr.a` is the supported body,
    -1 when `pr.b` is. `contacts_of` and the events both read through this."""
    if pr.excess_up < 0:
        return jn
    var along = pr.span * dot(pr.excess, pr.m.normal)
    return jn + along if pr.excess_up == pr.a else jn - along


struct ContactScene6[B: Body6, BP: BroadPhase = BVHBroadPhase[3]](Movable, Deinitable):
    """Boxes (dynamic or static) under gravity with contact impulses."""

    var bset: BodySet[Self.B]  # body identity + per-body SoA (F5): bodies,
    # motion (static/dynamic), sleeping, sleep_timer, island, restitution --
    # see `physics/body_set.mojo`.
    var cache: List[ContactConstraint]  # last frame's pairs (cross-frame warm starting)
    var joints: List[Joint6]
    # ROADMAP 17.47: per joint, limits / motor / spring / references /
    # collide flag (`physics.joint_ext`); `any_ext` gates the extra pass.
    var jext: List[JointExt]
    var any_ext: Bool
    # ROADMAP 17.45: kinematic triangle meshes -- body index and the mesh's
    # vertices in that body's frame; re-placed at the body pose every step
    var kin_mesh: List[Int]
    var kin_local: List[List[Real]]
    var kin_at: List[Pose6]  # pose the mesh was last placed at
    # ROADMAP 17.53: friction per surface material id (-1 = not set); a
    # mesh / heightfield triangle's id comes from `colliders.material`
    var material_mu: List[Real]
    var material_hz: List[Real]  # 17.50: contact hertz per material (<= 0 = not set)
    var material_zeta: List[Real]
    var drives: List[AngularDrive]  # ROADMAP 17.2: soft angular motors
    # ROADMAP 17.29: per-joint break thresholds (parallel to `joints`,
    # +inf = unbreakable) and the joints released by the last step.
    var break_force: List[Real]
    var break_torque: List[Real]
    var broken_joints: List[Int]
    var peak_force: List[Real]  # per-substep load peaks of the current step
    var peak_torque: List[Real]
    var any_break: Bool  # some joint has a finite threshold: sample loads
    var rules: List[ContactRule]  # ROADMAP 17.26: per-contact modification
    var softs: List[SoftBody]
    var colliders: ColliderSet  # shape kinds, hull/mesh tables, filters (F1)
    var counters: Counters  # diag counters (F23: parallel fallback to serial)
    var max_push: Real  # this step's SolverConfig.max_push_speed, for the island path (17.75)
    # ROADMAP 17.85 narrowphase reuse (`_narrow_reuse`): last collection's
    # candidates (key i * n + j -> index), their output ranges, the outputs,
    # and the inputs they were computed from. `np_reused` = candidates copied
    # in the last collection.
    var _np_keys: Dict[Int, Int]
    var _np_lo: List[Int]
    var _np_cnt: List[Int]
    var _np_slo: List[Int]
    var _np_scnt: List[Int]
    var _np_raws: List[RawContact]
    var _np_sraws: List[RawContact]
    var _np_pose: List[Pose3]
    var _np_vel: List[Vec3]
    var _np_epoch: Int
    var _np_spec: Real
    var _np_margin: Real
    var np_reused: Int
    var impulse_estimator: Int  # this step's SolverConfig.impulse_estimator (17.49)
    # ROADMAP 17.49: per joint, this step's summed linear / angular impulse
    # and the time it covers (`joint_reaction`).
    var jsum_f: List[Vec3]
    var jsum_t: List[Vec3]
    var jspan: List[Real]
    # ROADMAP 17.19 A2: per joint, the upward force this step's scaled solve
    # carried through it beyond the true load (`_report_excess`); jexcess_up is
    # the carrier body, -1 for none.
    var jexcess: List[Vec3]
    var jexcess_up: List[Int]
    # ROADMAP 17.0h: `diag` wired into the production solver path.
    # `trace`/`log` are solver-owned, mirroring `counters` above (a caller
    # reads `sc.trace`/`sc.log` directly, the same shape as `sc.counters`);
    # `trace` costs nothing when `-D LUDENS_TRACE` is off (`begin`/`end` are
    # `comptime if`-eliminated -- see `diag/trace.mojo`) and `log` costs
    # nothing to construct-and-never-push. `draw` likewise costs nothing
    # unless `-D LUDENS_DEBUG_DRAW` is defined; kept on the scene rather than
    # threaded through `step`/`step_soft` as a new parameter because both are
    # ~100-call-site APIs (same reasoning as `SolverConfig.validated()`) --
    # "the caller passes/owns" the spec asks for means the caller drains
    # `sc.draw`/calls `sc.draw.tick()` every frame, not that it lives on
    # their stack.
    var trace: TraceBuffer
    var log: LogRing[256]
    var draw: DrawQueue[WorldType]
    var bp: Self.BP  # persistent broadphase, used when `step_soft(broadphase=True)`
    # A sensor reports overlap and never receives an impulse. Its pairs are
    # collected separately rather than flagged in `pairs`, so that not one of
    # the solve, warm-start, island or restitution loops needs to learn about
    # them.
    var sensor_pairs: List[ContactConstraint]
    # Contact events, rebuilt every step when `events` is on. Off by default:
    # the diff sorts the contact set, which is real work for a scene that never
    # reads the result.
    var events_on: Bool
    var events: List[ContactEvent]
    var _prev_keys: List[Int]
    var _prev_peak: List[Real]  # 17.49: peak impulse per `_prev_keys` entry
    # ROADMAP 17.85: tiered simulation. A tier table (per tier: iters,
    # substeps, period; period 0 = never solved) and a tier per body slot
    # (missing entries = tier 0). Empty table = untiered (the existing path).
    var tier_iters: List[Int]
    var tier_substeps: List[Int]
    var tier_period: List[Int]
    var tier_of: List[Int]
    var step_index: Int  # steps taken; the tier phase clock
    var islands_solved: Int  # islands the last tiered step solved (diagnostic)
    var islands_skipped: Int

    def __init__(out self):
        comptime assert Self.BP.dim == 3, (
            "ContactScene6 is a 3-D solver: its BroadPhase must have dim == 3"
        )
        self.bset = BodySet[Self.B]()
        self.cache = List[ContactConstraint]()
        self.joints = List[Joint6]()
        self.jext = List[JointExt]()
        self.any_ext = False
        self.kin_mesh = List[Int]()
        self.kin_local = List[List[Real]]()
        self.kin_at = List[Pose6]()
        self.material_mu = List[Real]()
        self.material_hz = List[Real]()
        self.material_zeta = List[Real]()
        self.drives = List[AngularDrive]()
        self.break_force = List[Real]()
        self.break_torque = List[Real]()
        self.broken_joints = List[Int]()
        self.peak_force = List[Real]()
        self.peak_torque = List[Real]()
        self.any_break = False
        self.rules = List[ContactRule]()
        self.softs = List[SoftBody]()
        self.colliders = ColliderSet()
        self.counters = Counters()
        self.max_push = 4
        self._np_keys = Dict[Int, Int]()
        self._np_lo = List[Int]()
        self._np_cnt = List[Int]()
        self._np_slo = List[Int]()
        self._np_scnt = List[Int]()
        self._np_raws = List[RawContact]()
        self._np_sraws = List[RawContact]()
        self._np_pose = List[Pose3]()
        self._np_vel = List[Vec3]()
        self._np_epoch = -1
        self._np_spec = -1
        self._np_margin = -1
        self.np_reused = 0
        self.impulse_estimator = IMPULSE_SUBSTEP_SUM
        self.jsum_f = List[Vec3]()
        self.jsum_t = List[Vec3]()
        self.jspan = List[Real]()
        self.jexcess = List[Vec3]()
        self.jexcess_up = List[Int]()
        self.trace = TraceBuffer(capacity=512)
        self.log = LogRing[256]()
        self.draw = DrawQueue[WorldType](capacity=1024)
        self.bp = Self.BP()
        self.sensor_pairs = List[ContactConstraint]()
        self.events_on = False
        self.events = List[ContactEvent]()
        self._prev_keys = List[Int]()
        self._prev_peak = List[Real]()
        self.tier_iters = List[Int]()
        self.tier_substeps = List[Int]()
        self.tier_period = List[Int]()
        self.tier_of = List[Int]()
        self.step_index = 0
        self.islands_solved = 0
        self.islands_skipped = 0

    # ------------------------------------------------------------ tiers (17.85)

    def set_tier_table(mut self, iters: List[Int], substeps: List[Int], period: List[Int]) raises:
        """Quality per tier: tier t solves with `iters[t]` iterations and
        `substeps[t]` substeps, once every `period[t]` steps over `period[t]`
        steps' worth of time (catch-up, so simulated time is preserved);
        `period[t] == 0` never solves (the island holds still but stays an
        obstacle). Tier 0 should match the step's own config: an all-tier-0
        plan is then bit-identical to the untiered step."""
        if len(iters) == 0 or len(iters) != len(substeps) or len(iters) != len(period):
            raise Error("set_tier_table: iters, substeps and period need the same non-zero length")
        for t in range(len(iters)):
            if iters[t] < 1 or substeps[t] < 1 or period[t] < 0:
                raise Error("set_tier_table: iters >= 1, substeps >= 1, period >= 0")
        self.tier_iters = iters.copy()
        self.tier_substeps = substeps.copy()
        self.tier_period = period.copy()

    def set_body_tiers(mut self, tiers: List[Int]) raises:
        """Tier per body slot (index = `BodyId.index()`); slots past the end
        count as tier 0. Needs a tier table."""
        if len(self.tier_period) == 0:
            raise Error("set_body_tiers: set a tier table first")
        for t in tiers:
            if t < 0 or t >= len(self.tier_period):
                raise Error("set_body_tiers: tier out of range")
        self.tier_of = tiers.copy()

    def clear_tiers(mut self):
        self.tier_iters = List[Int]()
        self.tier_substeps = List[Int]()
        self.tier_period = List[Int]()
        self.tier_of = List[Int]()

    def body_tier(self, i: Int) -> Int:
        return self.tier_of[i] if i < len(self.tier_of) else 0

    def set_soft_period(mut self, s: Int, period: Int, phase: Int = 0) raises:
        """ROADMAP 17.85: soft body `s` steps every `period` scene steps,
        each time over period x dt (catch-up), offset by `phase`. Raises
        for a bad index, period < 1 or phase < 0."""
        if s < 0 or s >= len(self.softs):
            raise Error("ContactScene6.set_soft_period: soft body index out of range")
        if period < 1 or phase < 0:
            raise Error("ContactScene6.set_soft_period: period must be >= 1 and phase >= 0")
        self.softs[s].period = period
        self.softs[s].phase = phase % period

    def add_soft(mut self, var sb: SoftBody) -> Int:
        self.softs.append(sb^)
        return len(self.softs) - 1

    def add_joint(mut self, j: Joint6) raises -> Int:
        """Audit E12: a joint whose `a`/`b` body index is out of range would
        be an out-of-bounds write the first time the solver walks `joints`
        (`_joint_sweep`/`_warm_start_joints` index `self.bset.bodies`
        directly) -- caught here, once, at the public boundary, rather than
        left as UB in a release build."""
        var n = len(self.bset.bodies)
        if j.a < 0 or j.a >= n or j.b < 0 or j.b >= n:
            raise Error("ContactScene6.add_joint: body index out of range")
        self.joints.append(j)
        self.break_force.append(Real.MAX)
        self.break_torque.append(Real.MAX)
        self.peak_force.append(0)
        self.peak_torque.append(0)
        self._ensure_ext()
        return len(self.joints) - 1

    def _local_dir(self, i: Int, w: Vec3) -> Vec3:
        var p = self.bset.bodies[i].position()
        return self.bset.bodies[i].to_local(p + w) - self.bset.bodies[i].to_local(p)

    def _new_ext(self, jt: Joint6) -> JointExt:
        """Ext for a newly added joint: the zero-angle references are taken
        from the current poses (a hinge's angle is 0 where it was made), a
        slider records the relative rotation it holds, a rope its limit."""
        var ex = JointExt.default()
        var axa = self.bset.bodies[jt.a].act(jt.axis_a) - self.bset.bodies[jt.a].act(Vec3(0, 0, 0, 0))
        var ref_w = tangent_basis(axa)[0]
        ex.ref_a = self._local_dir(jt.a, ref_w)
        ex.ref_b = self._local_dir(jt.b, ref_w)
        if jt.kind == JOINT_SLIDER or jt.kind == JOINT_D6:
            ex.ref_rel = self.bset.bodies[jt.a].rotation().conjugate() * self.bset.bodies[jt.b].rotation()
        if jt.kind == JOINT_D6:
            ex.d6_mode = D6_ALL_LOCKED
            ex.collide = False
        if jt.kind == JOINT_ROPE:
            ex.lim_on = True
            ex.lo = 0
            ex.hi = jt.rest
        if jt.kind == JOINT_WELD:
            ex.collide = False
        return ex

    def remove_joint(mut self, c: Int) raises:
        """Take joint `c` out of the simulation. The slot stays (joint indices do not shift, so drives, break
        thresholds and held indices stay valid) and becomes a `JOINT_BROKEN` one, which nothing solves, and a
        body it referenced can then be removed. Removing a joint twice is an error."""
        if c < 0 or c >= len(self.joints):
            raise Error("ContactScene6.remove_joint: joint index out of range")
        if self.joints[c].kind == JOINT_BROKEN:
            raise Error("ContactScene6.remove_joint: the joint is already removed or broken")
        self.joints[c].kind = JOINT_BROKEN
        self.joints[c].acc = Vec3(0, 0, 0, 0)
        self.joints[c].acc_ang = Vec3(0, 0, 0, 0)
        self._ensure_ext()

    def restore_joint(mut self, c: Int, rec: Joint6) raises:
        """Put joint slot `c` back to `rec`, e.g. to undo `remove_joint` or to make a slot inert again. A live
        record needs both bodies alive. Accumulated impulses restart at zero, as for a joint just added."""
        if c < 0 or c >= len(self.joints):
            raise Error("ContactScene6.restore_joint: joint index out of range")
        if rec.kind != JOINT_BROKEN:
            if rec.a < 0 or rec.a >= len(self.bset.bodies) or rec.b < 0 or rec.b >= len(self.bset.bodies):
                raise Error("ContactScene6.restore_joint: body index out of range")
            if self.bset.is_removed(rec.a) or self.bset.is_removed(rec.b):
                raise Error("ContactScene6.restore_joint: a body of the joint is not alive")
        self.joints[c] = rec
        self.joints[c].acc = Vec3(0, 0, 0, 0)
        self.joints[c].acc_ang = Vec3(0, 0, 0, 0)
        self._ensure_ext()

    def joint_is_plain(self, c: Int) -> Bool:
        """True when joint `c` has the state `add_joint` gives a new joint at the bodies' current poses: no limit,
        motor, spring, cone or D6, the zero-angle references where creation would put them, no break thresholds.
        A scene can describe such a joint by its kind, bodies and anchors alone."""
        if c < 0 or c >= len(self.joints) or c >= len(self.jext):
            return False
        if self.break_force[c] < Real.MAX or self.break_torque[c] < Real.MAX:
            return False
        for d in range(len(self.drives)):
            if self.drives[d].a == self.joints[c].a and self.drives[d].b == self.joints[c].b:
                return False
        ref e = self.jext[c]
        var f = self._new_ext(self.joints[c])
        return (
            not e.active() and e.collide == f.collide and e.ref_a == f.ref_a and e.ref_b == f.ref_b
            and e.ref_rel.x == f.ref_rel.x and e.ref_rel.y == f.ref_rel.y and e.ref_rel.z == f.ref_rel.z and e.ref_rel.w == f.ref_rel.w
            and e.lim_on == f.lim_on
        )

    def _ensure_ext(mut self):
        """Keep `jext` as long as `joints` (joints added by any path) and
        `any_ext` current."""
        while len(self.jext) < len(self.joints):
            self.jext.append(self._new_ext(self.joints[len(self.jext)]))
        var any = False
        for c in range(len(self.joints)):
            var k = self.joints[c].kind
            if k == JOINT_SLIDER or k == JOINT_ROPE or self.jext[c].active():
                any = True
        self.any_ext = any

    def set_joint_break(mut self, j: Int, force: Real, torque: Real) raises:
        """Joint `j` releases once its constraint force exceeds `force` (N)
        or its torque exceeds `torque` (N·m) -- ROADMAP 17.29. Released
        joints are listed in `broken_joints` after the step that broke
        them and are never solved again."""
        if j < 0 or j >= len(self.joints):
            raise Error("ContactScene6.set_joint_break: joint index out of range")
        if not (force > 0 and torque > 0):
            raise Error("ContactScene6.set_joint_break: thresholds must be > 0")
        self.break_force[j] = force
        self.break_torque[j] = torque
        self.any_break = True

    def add_contact_rule(mut self, r: ContactRule) raises -> Int:
        """Register a per-contact rule (one-way platform, conveyor, friction
        override -- `physics.contact6.ContactRule`)."""
        if r.body < 0 or r.body >= len(self.bset.bodies):
            raise Error("ContactScene6.add_contact_rule: body index out of range")
        self.rules.append(r)
        return len(self.rules) - 1

    def add_drive(mut self, d: AngularDrive) raises -> Int:
        """Register a soft angular motor between bodies `d.a` and `d.b`
        (ROADMAP 17.2). Same boundary check as `add_joint`."""
        var n = len(self.bset.bodies)
        if d.a < 0 or d.a >= n or d.b < 0 or d.b >= n:
            raise Error("ContactScene6.add_drive: body index out of range")
        self.drives.append(d)
        return len(self.drives) - 1

    def island_count(self) -> Int:
        """Number of distinct dynamic islands from the last `step_soft`."""
        return count_islands(self.bset)


    def _push_body(mut self, var b: Self.B, is_static: Bool) -> BodyId:
        """The body-list half of registration, shared by every `add*`
        variant -- always called exactly once per body, through
        `BodySet.push` (the one append site, F5), in lockstep with exactly
        one `self.colliders.add*` call, so the two index spaces stay
        aligned (collider `i` <-> body `i`; `add` below asserts it)."""
        return self.bset.push(b^, MOTION_STATIC if is_static else MOTION_DYNAMIC)

    def _debug_assert_dynamic_inertia(self, b: Self.B, is_static: Bool):
        """audit E1/E2: a DYNAMIC body with `mass <= 0` or a zero/negative
        principal moment turns into a NaN pose within one integration step
        (`inv_mass()` -> `inf`, or `apply_inv` dividing by zero). Every
        `add*` constructor is a ~100-call-site API (see `SolverConfig
        .validated()`'s docstring for the same trade-off), so this is a
        `debug_assert`, not a `raise`: a caller that wants a raising check
        at ITS OWN boundary can call `Inertia3.validated()` before handing
        the body here. Static/kinematic bodies are exempt -- the solver
        never dereferences their `Inertia3` (`BodySet.is_dynamic`'s gate)."""
        if is_static:
            return
        var inertia = b.get_inertia()
        debug_assert(
            inertia.mass > 0, "ContactScene6.add*: dynamic body mass must be > 0"
        )
        debug_assert(
            inertia.ix > 0 and inertia.iy > 0 and inertia.iz > 0,
            "ContactScene6.add*: dynamic body principal inertia must be > 0",
        )

    def add(mut self, var b: Self.B, half: Vec3, is_static: Bool) -> BodyId:
        self._debug_assert_dynamic_inertia(b, is_static)
        var id = self._push_body(b^, is_static)
        var ci = self.colliders.add(half, id.index())
        debug_assert(
            ci == id.index(), "ContactScene6.add: body/collider index desync"
        )
        return id

    def add_sphere(mut self, var b: Self.B, r: Real, is_static: Bool) -> BodyId:
        self._debug_assert_dynamic_inertia(b, is_static)
        var id = self._push_body(b^, is_static)
        var ci = self.colliders.add_sphere(r, id.index())
        debug_assert(
            ci == id.index(),
            "ContactScene6.add_sphere: body/collider index desync",
        )
        return id

    def add_ellipsoid(mut self, var b: Self.B, radii: Vec3, is_static: Bool) -> BodyId:
        """Solid ellipsoid, semi-axes `radii` along the body's local x, y, z
        (ROADMAP 17.52; inertia `Inertia3.ellipsoid`). Contacts use its exact
        support mapping: one point per pair (GJK distance, EPA on overlap)."""
        self._debug_assert_dynamic_inertia(b, is_static)
        var id = self._push_body(b^, is_static)
        var ci = self.colliders.add_ellipsoid(radii, id.index())
        debug_assert(ci == id.index(), "ContactScene6.add_ellipsoid: body/collider index desync")
        return id

    def add_capsule(
        mut self, var b: Self.B, r: Real, half_len: Real, is_static: Bool
    ) -> BodyId:
        self._debug_assert_dynamic_inertia(b, is_static)
        var id = self._push_body(b^, is_static)
        var ci = self.colliders.add_capsule(r, half_len, id.index())
        debug_assert(
            ci == id.index(),
            "ContactScene6.add_capsule: body/collider index desync",
        )
        return id

    def add_hull(
        mut self, var b: Self.B, var verts: List[Real], is_static: Bool
    ) -> BodyId:
        """A convex body given by its LOCAL-frame vertices, FLAT (x, y, z per
        vertex) -- see `collision.collider_set.ColliderSet.add_hull`."""
        self._debug_assert_dynamic_inertia(b, is_static)
        var id = self._push_body(b^, is_static)
        var ci = self.colliders.add_hull(verts^, id.index())
        debug_assert(
            ci == id.index(), "ContactScene6.add_hull: body/collider index desync"
        )
        return id

    def add_compound(
        mut self, var b: Self.B, spec: CompoundSpec, density: Real, is_static: Bool
    ) raises -> BodyId:
        """One body made of several convex children (ROADMAP 17.44). `b`'s
        pose is the frame `spec`'s child poses are given in; its inertia is
        replaced. The children's mass properties at `density` give the
        centre of mass and principal axes (`physics.mass_props`); the body
        origin moves to that centre and its axes onto that frame, and the
        children are re-expressed there, so the world placement of every
        child is unchanged and `Inertia3`'s diagonal is exact.

        Raises: no children, more than 1024, density <= 0, a non-unit child
        rotation (|q| off by > 1e-4), or a child with a non-positive size."""
        var n = len(spec)
        if n == 0 or n > COMPOUND_MAX_CHILDREN:
            raise Error("ContactScene6.add_compound: 1 to 1024 children")
        if not (density > 0 and density < Real(1e30)):
            raise Error("ContactScene6.add_compound: density must be finite and > 0")
        for k in range(n):
            if abs(spec.rot[k].norm() - 1) > Real(1e-4):
                raise Error("ContactScene6.add_compound: child " + String(k) + " rotation is not a unit quaternion")
            var h = spec.half[k]
            var kind = spec.kind[k]
            var bad = h[0] <= 0
            if kind == SHAPE_BOX or kind == SHAPE_ELLIPSOID:
                bad = bad or h[1] <= 0 or h[2] <= 0
            elif kind == SHAPE_CAPSULE:
                bad = bad or h[1] < 0
            elif kind == SHAPE_HULL:
                bad = spec.hcount[k] < 12
            if bad:
                raise Error("ContactScene6.add_compound: child " + String(k) + " has no volume")
        var mp = compound_mass(spec, density)
        if not (mp.mass > 0):
            raise Error("ContactScene6.add_compound: children have no volume")
        var qp = mp.frame
        var qpc = qp.conjugate()
        var moved = CompoundSpec()
        for k in range(n):
            var lp = qpc.rotate(spec.pos[k] - mp.com)
            var lq = qpc * spec.rot[k]
            var kind = spec.kind[k]
            if kind == SHAPE_HULL:
                moved.hull(spec.child_verts(k), lp, lq)
            else:
                moved._push(kind, spec.half[k], lp, lq)
        var q0 = b.rotation()
        b.set_pose(Pose6(b.position() + q0.rotate(mp.com), q0 * qp))
        if not is_static:
            b.set_inertia(Inertia3(mp.mass, mp.moments[0], mp.moments[1], mp.moments[2]))
        var id = self._push_body(b^, is_static)
        var ci = self.colliders.add_compound(moved, id.index())
        debug_assert(ci == id.index(), "ContactScene6.add_compound: body/collider index desync")
        return id

    def add_sdf(mut self, var b: Self.B, var grid: SdfGrid) -> BodyId:
        """A static signed distance grid (ROADMAP 17.52) in world
        coordinates, like `add_trimesh` (the body's pose is ignored). Boxes,
        spheres, capsules and hulls meet it through a multi-point manifold
        sampled from their own shape (`contact_gen.try_sdf_pair`)."""
        var id = self._push_body(b^, True)
        var ci = self.colliders.add_sdf(grid^, id.index())
        debug_assert(ci == id.index(), "ContactScene6.add_sdf: body/collider index desync")
        return id

    def add_cylinder(
        mut self, var b: Self.B, r: Real, half_len: Real, is_static: Bool, segments: Int = 16
    ) -> BodyId:
        """A cylinder about local Y (ROADMAP 17.52). Its geometry is a
        `segments`-gon prism (end caps, queries); lying on a box its side
        contact is the exact capsule manifold with the round anchors of
        17.19, so it rolls as a cylinder. `segments` is clamped to [3, 16]:
        `HullShape` keeps at most 16 vertices per face and 30 faces, and a
        32-gon cap truncated to half its rim stood on one side and tipped
        over. Pair with `Inertia3.cylinder`."""
        var n = min(max(segments, 3), 16)
        var v = List[Real](capacity=6 * n)
        for k in range(n):
            var a = Real(6.283185307179586) * Real(k) / Real(n)
            for sgn in range(2):
                v.append(r * cos(a))
                v.append(half_len if sgn == 1 else -half_len)
                v.append(r * sin(a))
        var id = self.add_hull(b^, v^, is_static)
        self.colliders.hulls[self.colliders.hull_id[id.index()]].round_r = r
        return id

    def add_trimesh(
        mut self, var b: Self.B, verts: List[Real], indices: List[Int],
        active: List[UInt8] = List[UInt8](), local: Bool = False,
    ) raises -> BodyId:
        """Static triangle soup. `verts` is flat (x, y, z per vertex) in WORLD
        space, `indices` three per triangle.

        Always static. A mesh has no useful inertia tensor and no closed
        volume, so a dynamic one would be resolved against by contacts that
        cannot conserve anything; refusing it here is cheaper than discovering
        it as drift."""
        # ROADMAP 17.45: `local=True` places one mesh asset at the body's
        # pose (instancing). The collider still stores world vertices -- the
        # mesh is static, so the transform is applied once here.
        var placed = List[Real](capacity=len(verts))
        if local:
            for i in range(len(verts) // 3):
                var w = b.act(Vec3(verts[3 * i], verts[3 * i + 1], verts[3 * i + 2], 0))
                placed.append(w[0])
                placed.append(w[1])
                placed.append(w[2])
        else:
            for i in range(len(verts)):
                placed.append(verts[i])
        var id = self._push_body(b^, True)
        var ci = self.colliders.add_trimesh(placed, indices, id.index(), active)
        debug_assert(
            ci == id.index(),
            "ContactScene6.add_trimesh: body/collider index desync",
        )
        return id

    def add_heightfield(
        mut self, var b: Self.B, heights: List[Real], nx: Int, nz: Int,
        cell: Real, ox: Real = 0, oz: Real = 0,
    ) raises -> BodyId:
        """Static heightfield: the same surface as a mesh, with the triangles
        left implicit and the midphase reduced to arithmetic. Static for the
        same reason as `add_trimesh`."""
        var id = self._push_body(b^, True)
        var ci = self.colliders.add_heightfield(
            heights, nx, nz, cell, ox, oz, id.index()
        )
        debug_assert(
            ci == id.index(),
            "ContactScene6.add_heightfield: body/collider index desync",
        )
        return id

    def deform_heightfield(
        mut self, id: BodyId, cx: Real, cz: Real, radius: Real, delta: Real
    ) raises -> Int:
        """Dig or raise the heightfield `id` around world (cx, cz) --
        ROADMAP 17.30 -- and wake every sleeping body whose box reaches the
        edited disc (a crater under a resting crate must drop it, 17.25)."""
        if not self.bset.is_valid(id):
            raise Error("ContactScene6.deform_heightfield: invalid BodyId")
        var edited = self.colliders.deform_heightfield(id.index(), cx, cz, radius, delta)
        if edited == 0:
            return 0
        for i in range(len(self.bset.bodies)):
            if not self.bset.is_dynamic(i) or not self.bset.sleeping[i]:
                continue
            var p = self.bset.bodies[i].position()
            var hh = self.colliders.half[i]
            var reach = radius + max(hh[0], hh[2])
            var dx = p[0] - cx
            var dz = p[2] - cz
            if dx * dx + dz * dz <= reach * reach:
                wake_island(self.bset, i)
        return edited

    def remove_body(mut self, id: BodyId) raises:
        """ROADMAP 17.0i: full body removal -- the 17.0g-1 deferral
        `physics/body_set.mojo`'s module docstring flagged (`BodySet.remove`/
        `is_valid` existed and were tested, but nothing on `ContactScene6`
        called them). Tombstones the slot (`BodySet.remove`: bumps the
        generation, so a captured `BodyId` reads `is_valid() == False`
        afterwards) and drops every cached warm-start pair referencing it
        (`_quarantine_nonfinite`'s cache-prune has the identical shape) --
        the NEXT `step`'s `_collect_pairs` never re-generates a pair
        touching a removed body (the `is_removed` checks added alongside
        this method), so a stale cache entry would otherwise just sit
        unused; pruning it now is a courtesy, not a correctness requirement.

        Raises if a joint still references `id`: `_joint_sweep`/
        `_warm_start_joints` index `self.bset.bodies` directly with no
        removed-body check of their own (mirroring `add_joint`'s own
        bounds-check -- ARCHITECTURE.md S2, "invalid caller input"), so a
        dangling joint would be a live out-of-bounds-meaning read, not just
        stale data. The caller removes/replaces the joint first.

        `ColliderSet` keeps collider `i`'s shape data in place -- it has no
        free list of its own (unlike `BodySet`), so a reused slot's `add*`
        call OVERWRITES it via the `at` parameter (`ColliderSet.add`'s
        docstring) rather than the two index spaces drifting apart. Until
        that reuse happens, the stale row is simply never read again: every
        candidate-pair loop in `_collect_pairs` now skips `is_removed`
        bodies before touching `self.colliders` at that index."""
        if not self.bset.is_valid(id):
            raise Error("ContactScene6.remove_body: invalid BodyId")
        var i = id.index()
        for c in range(len(self.drives)):
            if self.drives[c].a == i or self.drives[c].b == i:
                raise Error(
                    "ContactScene6.remove_body: body is referenced by a"
                    " drive; remove the drive first"
                )
        for c in range(len(self.joints)):
            if self.joints[c].kind != JOINT_BROKEN and (self.joints[c].a == i or self.joints[c].b == i):
                raise Error(
                    "ContactScene6.remove_body: body is referenced by a"
                    " joint; remove the joint first"
                )
        self.bset.remove(id)
        var kept = List[ContactConstraint]()
        for c in range(len(self.cache)):
            if self.cache[c].a != i and self.cache[c].b != i:
                kept.append(self.cache[c])
        self.cache = kept^

    def _check_body_index(self, i: Int, who: String) raises:
        """audit E12: `i` is a raw `Int` (not a `BodyId`) on every `set_*`
        below -- unlike `set_kinematic`/`set_velocity`/etc, which predate
        this and already take `BodyId` (`bset.is_valid`'s generation check).
        Converting these to `BodyId` too would be a signature change on an
        API with call sites across ~10 test/benchmark files for a check that
        doesn't need generation tracking (an out-of-range `i` is exactly as
        wrong as a stale one here), so this only bounds-checks the slot."""
        if i < 0 or i >= len(self.bset.bodies):
            raise Error("ContactScene6." + who + ": body index out of range")

    def set_filter(mut self, i: Int, category: UInt32, mask: UInt32) raises:
        """Which layer body `i` is on, and which layers it collides with."""
        self._check_body_index(i, "set_filter")
        self.colliders.set_filter(i, category, mask)

    def set_sensor(mut self, i: Int, on: Bool) raises:
        """A sensor overlaps but never pushes: it reports contact events and is
        skipped by every solve pass. Trigger volumes are the point."""
        self._check_body_index(i, "set_sensor")
        self.colliders.set_sensor(i, on)

    def set_restitution(mut self, i: Int, e: Real) raises:
        self._check_body_index(i, "set_restitution")
        if e < 0 or e > 1:
            raise Error("ContactScene6.set_restitution: e must be in [0, 1]")
        self.bset.restitution[i] = e

    def set_restitution_combine(mut self, i: Int, mode: Int):
        """ROADMAP 17.23: which formula a pair touching body `i` uses when
        the two bodies' restitution combine modes disagree (`physics
        .material.combine`'s docstring has the PhysX "higher mode wins"
        rule). Default `COMBINE_MAX` reproduces today's hardcoded
        `max(a, b)`."""
        self.bset.restitution_combine[i] = mode

    def set_friction(mut self, i: Int, mu: Real) raises:
        """ROADMAP 17.23: body `i`'s own friction coefficient, replacing the
        step-wide `cfg.default_friction` fallback for every pair touching
        it (`BodySet.eff_friction`). `mu` must be >= 0 -- the sentinel for
        "never set" is negative (`BodySet.friction`'s docstring), so a
        negative call here would silently un-set it; that is caller error,
        not environment failure (docs/ARCHITECTURE.md S2), hence a
        `debug_assert` rather than a `raise` for `mu` specifically. `i` out
        of range (audit E12) does raise -- unlike a bad `mu`, it is not this
        function's own contract, it is an out-of-bounds write waiting to
        happen the next time `i` is read."""
        self._check_body_index(i, "set_friction")
        debug_assert(mu >= 0, "ContactScene6.set_friction: mu must be >= 0")
        self.bset.friction[i] = mu

    def set_static_friction(mut self, i: Int, mu_s: Real) raises:
        """ROADMAP 17.50: body `i`'s static friction coefficient, used by
        its contact points that are not sliding at prep (tangential speed
        below 1 cm/s); sliding points use the kinetic `set_friction` value.
        Pairs combine it with the same rule as the kinetic one."""
        self._check_body_index(i, "set_static_friction")
        if not (mu_s >= 0):
            raise Error("ContactScene6.set_static_friction: mu_s must be >= 0")
        self.bset.static_friction[i] = mu_s
        self.bset.any_contact_model = True

    def set_rolling_resistance(mut self, i: Int, c: Real) raises:
        """ROADMAP 17.50: rolling resistance of body `i` in metres -- a
        contact caps the opposing torque about the tangent plane at
        `c · N` (N the pair's normal force; the pair uses the larger `c`).
        A ball of radius r rolling on a flat floor then decelerates at
        5·c·g / (7·r)."""
        self._check_body_index(i, "set_rolling_resistance")
        if not (c >= 0):
            raise Error("ContactScene6.set_rolling_resistance: c must be >= 0")
        self.bset.rolling[i] = c
        self.bset.any_contact_model = True

    def set_spinning_resistance(mut self, i: Int, c: Real) raises:
        """ROADMAP 17.50: spin (torsional) resistance of body `i` in
        metres: torque about the contact normal capped at `c · N`."""
        self._check_body_index(i, "set_spinning_resistance")
        if not (c >= 0):
            raise Error("ContactScene6.set_spinning_resistance: c must be >= 0")
        self.bset.spinning[i] = c
        self.bset.any_contact_model = True

    def set_contact_softness(mut self, i: Int, hertz: Real, zeta: Real) raises:
        """ROADMAP 17.50: contact stiffness of body `i` (soft-constraint
        `hertz` > 0 and damping ratio `zeta` >= 0, as `SolverConfig`). A
        pair uses the side with the lower hertz; a body never set uses the
        step's `cfg.hertz` / `cfg.zeta`."""
        self._check_body_index(i, "set_contact_softness")
        if not (hertz > 0) or not (zeta >= 0):
            raise Error("ContactScene6.set_contact_softness: hertz must be > 0 and zeta >= 0")
        self.bset.contact_hertz[i] = hertz
        self.bset.contact_zeta[i] = zeta
        self.bset.any_contact_model = True

    def set_load_stiffness(mut self, on: Bool):
        """ROADMAP 17.19 (opt-in, default off): scale each pair's softness
        frequency by sqrt(heavier mass / lighter mass), for pairs whose bodies
        have `set_contact_softness`. Off: bit-identical to before."""
        self.bset.load_stiffness = on
        if on:
            self.bset.any_contact_model = True

    def set_adhesion(mut self, i: Int, force: Real) raises:
        """ROADMAP 17.50: body `i`'s contacts may pull as well as push, up to
        `force` newtons per pair (spread over its points), while the
        surfaces are within 1 cm. The pair uses the larger value."""
        self._check_body_index(i, "set_adhesion")
        if not (force >= 0):
            raise Error("ContactScene6.set_adhesion: force must be >= 0")
        self.bset.adhesion[i] = force
        self.bset.any_contact_model = True

    def set_mesh_active_angle(mut self, id: BodyId, angle: Real) raises:
        """Ghost-contact guard of a mesh or heightfield body (ROADMAP 17.45 /
        17.19): edges between triangles whose normals differ by at most
        `angle` radians become inactive, so a box sliding over a flat seam
        keeps the face normal instead of hitting the edge. Off by default
        (every edge active): on a flat 0.25 m heightfield a 0.8 m box then
        slides 0.099 m where it should slide 0.408 m (`test_mesh_reduce`)."""
        var i = self._check_id(id, "set_mesh_active_angle")
        self.colliders.set_active_angle(i, angle)

    def set_triangle_materials(mut self, id: BodyId, ids: List[Int]) raises:
        """ROADMAP 17.53: per-triangle surface material ids (0 .. 65535) of a
        mesh or heightfield body, one per triangle in the order the mesh was
        given (heightfield: `HeightField.tri`); empty clears. Query hits
        report them (`hit_material`), vehicle wheels take their grip from
        them (`surface_friction`). The contact solver still uses the body's
        friction (per-triangle contact friction is not wired)."""
        var i = self._check_id(id, "set_triangle_materials")
        self.colliders.set_materials(i, ids)

    def set_material_friction(mut self, material: Int, mu: Real) raises:
        """Friction of surface material `material` (`surface_friction`)."""
        if material < 0 or material > 65535:
            raise Error("ContactScene6.set_material_friction: material id must be in 0 .. 65535")
        if not (mu >= 0):
            raise Error("ContactScene6.set_material_friction: mu must be >= 0")
        while len(self.material_mu) <= material:
            self.material_mu.append(-1)
        self.material_mu[material] = mu

    def set_material_softness(mut self, material: Int, hertz: Real, zeta: Real) raises:
        """ROADMAP 17.50: contact stiffness of surface material `material`
        (soft-constraint hertz > 0, damping ratio zeta >= 0, as
        `SolverConfig`): a contact on a mesh / heightfield triangle of that
        material uses it instead of the bodies' or the step's. With a
        material friction set (`set_material_friction`) the triangle's
        friction also replaces the pair's (a `ContactRule` override still
        wins)."""
        if material < 0 or material > 65535:
            raise Error("ContactScene6.set_material_softness: material id must be in 0 .. 65535")
        if not (hertz > 0) or not (zeta >= 0):
            raise Error("ContactScene6.set_material_softness: hertz must be > 0 and zeta >= 0")
        while len(self.material_hz) <= material:
            self.material_hz.append(-1)
            self.material_zeta.append(0)
        self.material_hz[material] = hertz
        self.material_zeta[material] = zeta

    def _apply_materials(self, mut pairs: List[ContactConstraint]):
        """17.50: a contact on a mesh / heightfield triangle with a material
        takes that material's friction (as an override) and softness."""
        for c in range(len(pairs)):
            ref pr = pairs[c]
            var mesh = -1
            var ka = self.colliders.shape[pr.a]
            var kb = self.colliders.shape[pr.b]
            if kb == SHAPE_TRIMESH or kb == SHAPE_HEIGHTFIELD:
                mesh = pr.b
            elif ka == SHAPE_TRIMESH or ka == SHAPE_HEIGHTFIELD:
                mesh = pr.a
            if mesh < 0:
                continue
            var m = self.colliders.material(mesh, pr.feat & 0xFFFF)
            if m < 0:
                continue
            if m < len(self.material_mu) and self.material_mu[m] >= 0:
                pr.mu_override = self.material_mu[m]
            if m < len(self.material_hz) and self.material_hz[m] > 0:
                pr.soft_hz = self.material_hz[m]
                pr.soft_zeta = self.material_zeta[m]

    def hit_material(self, h: Hit) -> Int:
        """Surface material id of a query hit: the triangle's id on a mesh /
        heightfield with material ids, else -1."""
        if not h.hit:
            return -1
        return self.colliders.material(h.body, h.feat)

    def surface_friction(self, body: Int, material: Int, fallback: Real) -> Real:
        """Friction of a surface: material `material`'s when it is set
        (`set_material_friction`), else body `body`'s own
        (`BodySet.eff_friction`, `fallback` when that is unset too)."""
        if material >= 0 and material < len(self.material_mu) and self.material_mu[material] >= 0:
            return self.material_mu[material]
        if body < 0 or body >= len(self.bset.bodies):
            return fallback
        return self.bset.eff_friction(body, fallback)

    def set_friction_combine(mut self, i: Int, mode: Int):
        """Same pair-priority rule as `set_restitution_combine`, for
        friction. Default `COMBINE_AVERAGE` reproduces today's single
        shared `mu` bit-exactly (`physics.material.combine`'s docstring)."""
        self.bset.friction_combine[i] = mode

    def set_kinematic(mut self, id: BodyId) raises:
        """ROADMAP 17.24: promote an already-added body (static or dynamic)
        to KINEMATIC -- infinite mass for impulses, pose still integrated
        every substep from a velocity the caller sets (`set_velocity`/
        `move_to`), never affected by gravity, never merged into a dynamic
        island, never put to sleep. Deliberately NOT a new `add_kinematic`
        constructor: every existing `add*` call site keeps its
        `is_static: Bool` signature unchanged -- a 7-method/~100-call-site
        signature sweep is exactly the compile-cost-cliff risk 17.0g-2 was
        warned to avoid ("land in small steps")."""
        if not self.bset.is_valid(id):
            raise Error("ContactScene6.set_kinematic: invalid BodyId")
        var i = id.index()
        self.bset.motion[i] = MOTION_KINEMATIC
        self.bset.sleeping[i] = False
        self.bset.sleep_timer[i] = 0
        self.bset.island[i] = -1  # recomputed by the next `_refresh_islands`
        # ROADMAP 17.45: a triangle mesh moves with its body from now on --
        # remember its vertices in the body frame (once)
        if self.colliders.shape[i] == SHAPE_TRIMESH:
            for k in self.kin_mesh:
                if k == i:
                    return
            ref m = self.colliders.meshes[self.colliders.mesh_id[i]]
            var loc = List[Real](capacity=len(m.v))
            for vtx in range(len(m.v) // 3):
                var l = self.bset.bodies[i].to_local(Vec3(m.v[3 * vtx], m.v[3 * vtx + 1], m.v[3 * vtx + 2], 0))
                loc.append(l[0])
                loc.append(l[1])
                loc.append(l[2])
            self.kin_mesh.append(i)
            self.kin_local.append(loc^)
            self.kin_at.append(Pose6(self.bset.bodies[i].position(), self.bset.bodies[i].rotation()))

    def set_dynamic(mut self, id: BodyId) raises:
        """ROADMAP 17.68: hand a kinematic body back to the dynamics (a
        sequence-driven platform released at the end of its track). Mass,
        inertia and the current velocity are kept, so it carries on at the
        velocity it was last driven with. Raises for an invalid id, a body
        that is not kinematic, or a kinematic triangle mesh (a dynamic mesh
        is not supported)."""
        if not self.bset.is_valid(id):
            raise Error("ContactScene6.set_dynamic: invalid BodyId")
        var i = id.index()
        if not self.bset.is_kinematic(i):
            raise Error("ContactScene6.set_dynamic: body is not kinematic")
        if self.colliders.shape[i] == SHAPE_TRIMESH:
            raise Error("ContactScene6.set_dynamic: a triangle mesh cannot become dynamic")
        self.bset.motion[i] = MOTION_DYNAMIC
        self.bset.sleeping[i] = False
        self.bset.sleep_timer[i] = 0
        self.bset.island[i] = -1

    def _refresh_kinematic_meshes(mut self) raises:
        """Re-place each kinematic mesh at its body's current pose (vertices,
        BVH, world AABB; active-edge flags kept). Runs before a step (a pose
        set between steps) and after it (so scene queries between steps see
        the mesh where its body is); a mesh whose body has not moved since it
        was last placed is skipped. O(triangles) per moved mesh: meant for
        platforms and doors, not for a level."""
        for k in range(len(self.kin_mesh)):
            var i = self.kin_mesh[k]
            if not self.bset.is_kinematic(i):
                continue
            var pos = self.bset.bodies[i].position()
            var rot = self.bset.bodies[i].rotation()
            ref at = self.kin_at[k]
            if pos[0] == at.pos[0] and pos[1] == at.pos[1] and pos[2] == at.pos[2] and rot.x == at.rot.x and rot.y == at.rot.y and rot.z == at.rot.z and rot.w == at.rot.w:
                continue
            self.kin_at[k] = Pose6(pos, rot)
            var w = List[Real](capacity=len(self.kin_local[k]))
            for vtx in range(len(self.kin_local[k]) // 3):
                var p = self.bset.bodies[i].act(Vec3(self.kin_local[k][3 * vtx], self.kin_local[k][3 * vtx + 1], self.kin_local[k][3 * vtx + 2], 0))
                w.append(p[0])
                w.append(p[1])
                w.append(p[2])
            self.colliders.move_trimesh(i, w)

    def set_velocity(mut self, id: BodyId, v: Vec3, w: Vec3) raises:
        """Directly set body `id`'s linear/angular velocity (world frame) --
        the primitive a constant-speed kinematic platform drives itself
        with (once is enough: nothing else ever changes it again the way
        gravity/impulses would for a dynamic body, so it keeps moving at
        this velocity every substep until called again)."""
        if not self.bset.is_valid(id):
            raise Error("ContactScene6.set_velocity: invalid BodyId")
        self.bset.bodies[id.index()].set_velocity(v, w)

    def move_to(mut self, id: BodyId, pose: Pose6, dt: Real) raises:
        """Compute the velocity that would carry body `id` from its CURRENT
        pose to `pose` over `dt`, and set it (`set_velocity`) -- an
        elevator or door scripted by target pose rather than by velocity.
        Angular velocity uses the small-angle quaternion-derivative
        approximation (`w = 2*Im(q_delta)/dt`, shorter-path corrected) the
        rest of this file already leans on for joint angular error
        (`_joint_sweep`'s hinge `er = cross(oa, ob)`) -- exact for a single
        substep's rotation, and bounded (never NaN/Inf) for any finite
        `pose`/`dt`, including a huge-displacement jump (extreme test)."""
        if not self.bset.is_valid(id):
            raise Error("ContactScene6.move_to: invalid BodyId")
        debug_assert(dt > 0, "ContactScene6.move_to: dt must be > 0")
        var i = id.index()
        var cur_pos = self.bset.bodies[i].position()
        var cur_rot = self.bset.bodies[i].rotation()
        var v = (pose.pos - cur_pos) / dt
        var qd = pose.rot * cur_rot.conjugate()
        if qd.w < 0:
            qd = Quat(-qd.x, -qd.y, -qd.z, -qd.w)  # shorter angular path
        var w = Vec3(qd.x, qd.y, qd.z, 0) * (2 / dt)
        self.bset.bodies[i].set_velocity(v, w)

    def freeze(mut self, id: BodyId) raises:
        """Take body `id` out of the simulation without the sleep semantics
        (ROADMAP 17.31: physics LOD): it becomes static -- it neither moves
        nor responds, contacts do not wake it, others collide with it where
        it stands -- until `unfreeze`. Its velocity is kept, so unfreezing
        resumes the motion exactly. Freezing a static or frozen body is a
        no-op."""
        if not self.bset.is_valid(id):
            raise Error("ContactScene6.freeze: invalid BodyId")
        var i = id.index()
        if self.bset.frozen_motion[i] >= 0 or self.bset.is_static(i):
            return
        self.bset.frozen_motion[i] = self.bset.motion[i]
        self.bset.motion[i] = MOTION_STATIC

    def unfreeze(mut self, id: BodyId) raises:
        if not self.bset.is_valid(id):
            raise Error("ContactScene6.unfreeze: invalid BodyId")
        var i = id.index()
        if self.bset.frozen_motion[i] < 0:
            return
        self.bset.motion[i] = self.bset.frozen_motion[i]
        self.bset.frozen_motion[i] = -1
        self.bset.sleeping[i] = False
        self.bset.sleep_timer[i] = 0

    def is_frozen(self, id: BodyId) raises -> Bool:
        if not self.bset.is_valid(id):
            raise Error("ContactScene6.is_frozen: invalid BodyId")
        return self.bset.frozen_motion[id.index()] >= 0

    def is_sleeping(self, id: BodyId) raises -> Bool:
        """ROADMAP 17.25: e.g. so a character controller (17.2) knows
        whether the platform it's standing on is still simulated or has
        handed off to an idle pose."""
        if not self.bset.is_valid(id):
            raise Error("ContactScene6.is_sleeping: invalid BodyId")
        return self.bset.sleeping[id.index()]

    def wake(mut self, id: BodyId) raises:
        """Manually wake body `id`'s island (ROADMAP 17.25) -- e.g. a
        distant explosion's damage query decides a sleeping stack should
        react NOW rather than at its next contact impulse. Waking a STATIC
        or KINEMATIC id is a no-op (`_wake_island`'s `is_dynamic` gate); an
        invalid/removed id raises (docs/ARCHITECTURE.md S2: invalid caller
        input at the public API)."""
        if not self.bset.is_valid(id):
            raise Error("ContactScene6.wake: invalid BodyId")
        wake_island(self.bset, id.index())

    def set_can_sleep(mut self, id: BodyId, on: Bool) raises:
        """`on=False` keeps body `id`'s whole island awake forever: its own
        `sleep_timer` never advances (`_update_sleep`'s gate), which starves
        the island-wide `all_still` check with no second gate needed there.
        Turning it back off ALSO wakes the body immediately, so a body
        just marked "never sleep" is never left asleep from before this
        call."""
        if not self.bset.is_valid(id):
            raise Error("ContactScene6.set_can_sleep: invalid BodyId")
        var i = id.index()
        self.bset.can_sleep[i] = on
        if not on:
            wake_island(self.bset, i)

    # ------------------------------------------------ joint limits / motors (17.47)

    def _ext_index(mut self, j: Int, what: String) raises -> Int:
        if j < 0 or j >= len(self.joints):
            raise Error("ContactScene6." + what + ": joint index out of range")
        self._ensure_ext()
        return j

    def reset_joint_ext(mut self, j: Int) raises:
        """Rebuild joint `j`'s ext from the current poses (after changing the
        joint's kind or axes in place): references re-zeroed, limits / motor
        / spring cleared, collide flag kept."""
        var c = self._ext_index(j, "reset_joint_ext")
        var keep = self.jext[c].collide
        self.jext[c] = self._new_ext(self.joints[c])
        self.jext[c].collide = keep
        self._ensure_ext()

    def set_joint_limits(mut self, j: Int, lo: Real, hi: Real) raises:
        """Limit the joint coordinate to [lo, hi]: hinge / cone-twist twist
        angle (rad, 0 where the joint was made), slider travel (m from a's
        anchor along the axis), rope length (m)."""
        var c = self._ext_index(j, "set_joint_limits")
        if not (lo <= hi):
            raise Error("ContactScene6.set_joint_limits: need lo <= hi")
        self.jext[c].lim_on = True
        self.jext[c].lo = lo
        self.jext[c].hi = hi
        self._ensure_ext()

    def clear_joint_limits(mut self, j: Int) raises:
        var c = self._ext_index(j, "clear_joint_limits")
        self.jext[c].lim_on = False
        self.jext[c].acc_lo = 0
        self.jext[c].acc_hi = 0
        self._ensure_ext()

    def set_d6_axis(mut self, j: Int, axis: Int, mode: Int, lo: Real = 0, hi: Real = 0) raises:
        """ROADMAP 17.47: one axis of a D6 joint -- `axis` 0..2 = translation
        along a's x / y / z (m), 3..5 = rotation about them (rad, the
        rotation-vector component); `mode` D6_FREE, D6_LOCKED or
        D6_LIMITED with lo <= hi."""
        var c = self._ext_index(j, "set_d6_axis")
        if self.joints[c].kind != JOINT_D6:
            raise Error("ContactScene6.set_d6_axis: not a D6 joint")
        if axis < 0 or axis > 5:
            raise Error("ContactScene6.set_d6_axis: axis must be 0..5")
        if mode != D6_FREE and mode != D6_LOCKED and mode != D6_LIMITED:
            raise Error("ContactScene6.set_d6_axis: unknown mode")
        if mode == D6_LIMITED and not (lo <= hi):
            raise Error("ContactScene6.set_d6_axis: need lo <= hi")
        ref ex = self.jext[c]
        ex.d6_mode = (ex.d6_mode & ~(3 << (2 * axis))) | (mode << (2 * axis))
        if axis < 3:
            ex.d6_lo_lin[axis] = lo
            ex.d6_hi_lin[axis] = hi
            ex.d6_acc_lin[axis] = 0
        else:
            ex.d6_lo_ang[axis - 3] = lo
            ex.d6_hi_ang[axis - 3] = hi
            ex.d6_acc_ang[axis - 3] = 0
        self._ensure_ext()

    def set_cone_limit(mut self, j: Int, angle: Real) raises:
        """Swing cone of a cone-twist joint: the angle between the two twist
        axes stays <= `angle` (rad; < 0 removes it)."""
        var c = self._ext_index(j, "set_cone_limit")
        if self.joints[c].kind != JOINT_CONE_TWIST:
            raise Error("ContactScene6.set_cone_limit: not a cone-twist joint")
        self.jext[c].cone = angle
        self._ensure_ext()

    def set_joint_motor(
        mut self, j: Int, mode: Int, target: Real, max_force: Real,
        hertz: Real = 5, zeta: Real = 1,
    ) raises:
        """Motor along the joint coordinate. MOTOR_VELOCITY drives its rate to
        `target` (rad/s or m/s); MOTOR_POSITION pulls it toward `target` like
        a spring of `hertz` / `zeta`. Either is capped at `max_force` (N m or
        N). MOTOR_NONE switches it off."""
        var c = self._ext_index(j, "set_joint_motor")
        if mode != MOTOR_NONE and mode != MOTOR_VELOCITY and mode != MOTOR_POSITION:
            raise Error("ContactScene6.set_joint_motor: unknown mode")
        if not (max_force >= 0):
            raise Error("ContactScene6.set_joint_motor: max_force must be >= 0")
        self.jext[c].motor = mode
        self.jext[c].target = target
        self.jext[c].max_force = max_force
        self.jext[c].m_hertz = hertz
        self.jext[c].m_zeta = zeta
        self.jext[c].acc_motor = 0
        self._ensure_ext()

    def set_joint_spring(mut self, j: Int, hertz: Real, zeta: Real, rest: Real) raises:
        """Spring-damper on the joint coordinate toward `rest` (soft
        constraint: natural frequency `hertz`, damping ratio `zeta`;
        hertz <= 0 removes it)."""
        var c = self._ext_index(j, "set_joint_spring")
        self.jext[c].s_hertz = hertz
        self.jext[c].s_zeta = zeta
        self.jext[c].s_rest = rest
        self.jext[c].acc_spring = 0
        self._ensure_ext()

    def set_collide_connected(mut self, j: Int, on: Bool) raises:
        """Whether the two bodies of joint `j` collide with each other."""
        var c = self._ext_index(j, "set_collide_connected")
        self.jext[c].collide = on

    def joint_coordinate(mut self, j: Int) raises -> Real:
        """The joint's current coordinate (see `set_joint_limits`)."""
        var c = self._ext_index(j, "joint_coordinate")
        return joint_coordinate(self.bset, self.joints[c], self.jext[c])

    # ------------------------------------------------ force reporting (17.49)

    def set_ccd_mode(mut self, id: BodyId, mode: Int) raises:
        """ROADMAP 17.46: body `id`'s CCD mode -- CCD_AUTO (default: swept
        when cfg.ccd is on), CCD_OFF (never swept), CCD_BULLET (always swept,
        even with cfg.ccd off, so a scene can pay for CCD on its
        projectiles only)."""
        var i = self._check_id(id, "set_ccd_mode")
        if mode != CCD_AUTO and mode != CCD_OFF and mode != CCD_BULLET:
            raise Error("ContactScene6.set_ccd_mode: unknown mode")
        self.bset.ccd_mode[i] = UInt8(mode)
        var any = False
        for k in range(len(self.bset.ccd_mode)):
            if self.bset.ccd_mode[k] == CCD_BULLET and not self.bset.is_removed(k):
                any = True
        self.bset.any_bullet = any

    def set_contact_reporting(mut self, id: BodyId, on: Bool) raises:
        """Report contact events only for flagged bodies' pairs once any body
        is flagged (with none flagged, every pair is reported, as before)."""
        var i = self._check_id(id, "set_contact_reporting")
        self.bset.report[i] = on
        var any = False
        for k in range(len(self.bset.report)):
            if self.bset.report[k]:
                any = True
        self.bset.any_report = any

    def _hold_loads(self, mut pairs: List[ContactConstraint]):
        """ROADMAP 17.19 (5): snapshot the loads of every pair the solver
        touched this step into its `hold_*` fields. `span > 0` is the solver's
        own "solved this step" mark (`accumulate_step_impulse` only adds to it
        for a pair it solved), and it is read after `update_sleep`, so a pair
        whose bodies fell asleep this step is still snapshotted. Runs after
        `_report_excess`, which sets the excess the snapshot carries."""
        for p in range(len(pairs)):
            ref pr = pairs[p]
            if pr.span <= 0:
                continue
            pr.hold_jn = pr.jn.copy()
            pr.hold_jf = pr.jf
            pr.hold_span = pr.span
            pr.hold_excess = pr.excess
            pr.hold_excess_up = pr.excess_up

    def contacts_of(self, id: BodyId) raises -> List[ContactReport]:
        """This step's contacts of body `id` with their impulses (from the
        pairs the step solved; empty before the first step). A pair whose
        bodies are both inert (asleep or static) was skipped by the solver,
        so its report carries the held loads of its last solved step (17.19
        (5)); its live fields stay zero for the event stream."""
        var i = self._check_id(id, "contacts_of")
        var out = List[ContactReport]()
        for c in range(len(self.cache)):
            var pr = self.cache[c]
            if pr.a != i and pr.b != i:
                continue
            if self.bset.impulse_inert(pr.a) and self.bset.impulse_inert(pr.b):
                pr.jn = pr.hold_jn.copy()
                pr.jf = pr.hold_jf
                pr.span = pr.hold_span
                pr.excess = pr.hold_excess
                pr.excess_up = pr.hold_excess_up
            var jn = Real(0)
            var best = -1
            for q in range(pr.m.count):
                jn += pr.jn[q]
                if best < 0 or pr.jn[q] > pr.jn[best]:
                    best = q
            var on_b = pr.m.normal * jn + pr.jf
            var sgn = Real(1) if pr.b == i else Real(-1)
            var imp = on_b * sgn
            var nrep = pr.m.normal * (-sgn)
            if pr.excess_up >= 0:
                # 17.19 A2: the solve carried the scaled excess; report the load
                imp = imp - pr.excess * ((Real(1) if pr.excess_up == i else Real(-1)) * pr.span)
            jn = _excess_jn(pr, jn)
            var f = imp / pr.span if pr.span > 0 else Vec3(0, 0, 0, 0)
            var p = pr.m.points[best] if best >= 0 else self.bset.bodies[i].position()
            out.append(ContactReport(
                pr.b if pr.a == i else pr.a, pr.feat, p, nrep, jn, imp, f,
            ))
        return out^

    def net_contact_force(self, id: BodyId) raises -> Vec3:
        """Sum of this step's contact forces on body `id` (normal and
        friction): a crate resting on a scale reads m g upward."""
        var reps = self.contacts_of(id)
        var f = Vec3(0, 0, 0, 0)
        for r in range(len(reps)):
            f = f + reps[r].force
        return f

    def joint_reaction(self, j: Int) raises -> Tuple[Vec3, Vec3]:
        """(force, torque) joint `j` applied to its body `b` this step,
        averaged over the step (no break threshold needed); a broken joint
        reads zero."""
        if j < 0 or j >= len(self.joints):
            raise Error("ContactScene6.joint_reaction: joint index out of range")
        if j >= len(self.jspan) or self.jspan[j] <= 0:
            return (Vec3(0, 0, 0, 0), Vec3(0, 0, 0, 0))
        var f = self.jsum_f[j] / self.jspan[j]
        if self.jexcess_up[j] >= 0:
            # 17.19 A2: the solve's excess is load the joint does not carry. Its
            # carrier's reaction is short by the excess; the other side's is over.
            var sgn = Real(1) if self.jexcess_up[j] == self.joints[j].b else Real(-1)
            f = f - self.jexcess[j] * sgn
        return (f, self.jsum_t[j] / self.jspan[j])

    # ------------------------------------------------ per-body parameters (17.48)

    def _check_id(self, id: BodyId, what: String) raises -> Int:
        if not self.bset.is_valid(id):
            raise Error("ContactScene6." + what + ": invalid BodyId")
        return id.index()

    def set_damping(mut self, id: BodyId, linear: Real, angular: Real) raises:
        """Implicit linear / angular damping (1/s): every step multiplies the
        velocity by 1 / (1 + c dt), so a large c drives it to zero without
        ever reversing it."""
        var i = self._check_id(id, "set_damping")
        if not (linear >= 0 and angular >= 0):
            raise Error("ContactScene6.set_damping: coefficients must be >= 0 (and not NaN)")
        self.bset.lin_damping[i] = linear
        self.bset.ang_damping[i] = angular
        self.bset.any_props = True

    def set_gravity_scale(mut self, id: BodyId, scale: Real) raises:
        """Multiplies the gravity the body feels (the step's, or a field's
        override); 0 = floats."""
        var i = self._check_id(id, "set_gravity_scale")
        if not (scale == scale):
            raise Error("ContactScene6.set_gravity_scale: NaN")
        self.bset.gravity_scale[i] = scale
        self.bset.any_props = True

    def set_axis_locks(
        mut self, id: BodyId, lx: Bool, ly: Bool, lz: Bool, ax: Bool, ay: Bool, az: Bool
    ) raises:
        """Lock linear (lx, ly, lz) and angular (ax, ay, az) motion along the
        WORLD axes: those velocity components are zeroed before every pose
        integration (a 2.5D game: lz, ax, ay; a revolving door: lx..lz, ax, az)."""
        var i = self._check_id(id, "set_axis_locks")
        var bits = 0
        if lx:
            bits |= 1
        if ly:
            bits |= 2
        if lz:
            bits |= 4
        if ax:
            bits |= 8
        if ay:
            bits |= 16
        if az:
            bits |= 32
        self.bset.locks[i] = bits
        self.bset.any_props = True

    def set_max_velocity(mut self, id: BodyId, linear: Real, angular: Real) raises:
        """Speed caps (m/s, rad/s; <= 0 = none). A step that ends above a cap
        clamps the speed and counts `diag.counters.VELOCITY_CLAMPED`."""
        var i = self._check_id(id, "set_max_velocity")
        if not (linear == linear and angular == angular):
            raise Error("ContactScene6.set_max_velocity: NaN")
        self.bset.max_lin[i] = linear
        self.bset.max_ang[i] = angular
        self.bset.any_props = True

    def set_sleep_thresholds(mut self, id: BodyId, linear: Real, angular: Real) raises:
        """Per-body sleep speed thresholds replacing `SolverConfig`'s
        (< 0 = use the config's)."""
        var i = self._check_id(id, "set_sleep_thresholds")
        self.bset.sleep_lin[i] = linear
        self.bset.sleep_ang[i] = angular
        self.bset.any_props = True

    def set_mass(mut self, id: BodyId, mass: Real) raises:
        """New mass, inertia scaled by the same ratio (the shape keeps its
        mass distribution). `mass` must be finite and > 0."""
        var i = self._check_id(id, "set_mass")
        if not (mass > 0 and mass < Real(1e30)):
            raise Error("ContactScene6.set_mass: mass must be finite and > 0")
        var old = self.bset.bodies[i].get_inertia()
        var k = mass / old.mass
        self.bset.bodies[i].set_inertia(Inertia3(mass, old.ix * k, old.iy * k, old.iz * k))

    def set_inertia(mut self, id: BodyId, inertia: Inertia3) raises:
        var i = self._check_id(id, "set_inertia")
        self.bset.bodies[i].set_inertia(inertia.validated())

    def set_mass_from_density(mut self, id: BodyId, density: Real) raises:
        """Mass and inertia from the body's collider and a density (kg/m^3):
        box, sphere, capsule and ellipsoid (the `Inertia3` formulas); other
        shapes raise."""
        var i = self._check_id(id, "set_mass_from_density")
        if not (density > 0 and density < Real(1e30)):
            raise Error("ContactScene6.set_mass_from_density: density must be finite and > 0")
        var k = self.colliders.shape[i]
        var h = self.colliders.half[i]
        var inertia: Inertia3
        match k:
            case == SHAPE_BOX:
                inertia = Inertia3.box(density * 8 * h[0] * h[1] * h[2], h[0], h[1], h[2])
            case == SHAPE_SPHERE:
                var r = h[0]
                inertia = Inertia3.sphere(density * Real(4.18879020478639) * r * r * r, r)
            case == SHAPE_CAPSULE:
                var r = h[0]
                var hl = h[1]
                var vol = Real(3.14159265358979) * r * r * (2 * hl) + Real(4.18879020478639) * r * r * r
                inertia = Inertia3.capsule(density * vol, r, hl)
            case == SHAPE_ELLIPSOID:
                inertia = Inertia3.ellipsoid(density * Real(4.18879020478639) * h[0] * h[1] * h[2], h[0], h[1], h[2])
            case _:
                raise Error("ContactScene6.set_mass_from_density: only box, sphere, capsule and ellipsoid colliders")
        self.bset.bodies[i].set_inertia(inertia)

    def _touch(mut self, i: Int):
        """What `wake(id)` does to a body that is pushed: restart its sleep
        timer and, if it is asleep, wake its island. An awake body's island
        is awake (islands sleep together), so the O(N) island scan only runs
        for a sleeping body -- `add_force` on every body every step stays
        O(N), not O(N^2) (measured in `bench_rigid_params`)."""
        if self.bset.sleeping[i]:
            wake_island(self.bset, i)
        else:
            self.bset.sleep_timer[i] = 0

    def add_force(mut self, id: BodyId, f: Vec3, mode: Int = FORCE_MODE_FORCE) raises:
        """Force at the centre of mass. FORCE (N) and ACCELERATION (m/s^2)
        accumulate and act over the next step; IMPULSE (N s) and
        VELOCITY_CHANGE (m/s) act now. Static and kinematic bodies ignore it;
        the body's island wakes (sleep timer restarted, as `wake(id)`)."""
        var i = self._check_id(id, "add_force")
        if not self.bset.is_dynamic(i):
            return
        self._touch(i)
        var m = Real(1) / self.bset.bodies[i].inv_mass()
        match mode:
            case == FORCE_MODE_FORCE:
                self.bset.force[i] = self.bset.force[i] + f
                self.bset.any_props = True
            case == FORCE_MODE_ACCELERATION:
                self.bset.force[i] = self.bset.force[i] + f * m
                self.bset.any_props = True
            case == FORCE_MODE_IMPULSE:
                self.bset.bodies[i].apply_impulse(f, self.bset.bodies[i].position())
            case _:
                self.bset.bodies[i].apply_impulse(f * m, self.bset.bodies[i].position())

    def add_force_at(mut self, id: BodyId, f: Vec3, at: Vec3, mode: Int = FORCE_MODE_FORCE) raises:
        """Force at world point `at`: the force plus its torque about the
        centre of mass (FORCE accumulates; IMPULSE acts now; other modes raise)."""
        var i = self._check_id(id, "add_force_at")
        if not self.bset.is_dynamic(i):
            return
        self._touch(i)
        match mode:
            case == FORCE_MODE_FORCE:
                self.bset.force[i] = self.bset.force[i] + f
                self.bset.torque[i] = self.bset.torque[i] + cross(at - self.bset.bodies[i].position(), f)
                self.bset.any_props = True
            case == FORCE_MODE_IMPULSE:
                self.bset.bodies[i].apply_impulse(f, at)
            case _:
                raise Error("ContactScene6.add_force_at: only FORCE and IMPULSE modes")

    def add_torque(mut self, id: BodyId, t: Vec3) raises:
        """Torque (N m), accumulated for the next step."""
        var i = self._check_id(id, "add_torque")
        if not self.bset.is_dynamic(i):
            return
        self._touch(i)
        self.bset.torque[i] = self.bset.torque[i] + t
        self.bset.any_props = True

    def apply_impulse(mut self, id: BodyId, j: Vec3, at: Vec3, wake: Bool = True) raises:
        """Immediate impulse at world point `at` (what gameplay code used to
        do by reaching into `bset.bodies[i].apply_impulse`). `wake` wakes
        the island and restarts its sleep timer, as `wake(id)` does; a
        controller pushing its own body every substep passes False so the
        body can still fall asleep at rest."""
        var i = self._check_id(id, "apply_impulse")
        if not self.bset.is_dynamic(i):
            return
        if wake:
            self._touch(i)
        self.bset.bodies[i].apply_impulse(j, at)

    def apply_angular_impulse(mut self, id: BodyId, l: Vec3, wake: Bool = True) raises:
        """Immediate angular impulse (N m s, world frame); `wake` as in
        `apply_impulse`."""
        var i = self._check_id(id, "apply_angular_impulse")
        if not self.bset.is_dynamic(i):
            return
        if wake:
            self._touch(i)
        self.bset.bodies[i].apply_angular_impulse(l)

    def velocity(self, id: BodyId) raises -> Vec3:
        return self.bset.bodies[self._check_id(id, "velocity")].linear_velocity()

    def angular_velocity(self, id: BodyId) raises -> Vec3:
        return self.bset.bodies[self._check_id(id, "angular_velocity")].omega_world()

    def pose(self, id: BodyId) raises -> Pose6:
        var i = self._check_id(id, "pose")
        return Pose6(self.bset.bodies[i].position(), self.bset.bodies[i].rotation())

    def _apply_locks(mut self, i: Int):
        var bits = self.bset.locks[i]
        var v = self.bset.bodies[i].linear_velocity()
        var w = self.bset.bodies[i].omega_world()
        for a in range(3):
            if (bits >> a) & 1:
                v[a] = 0
            if (bits >> (a + 3)) & 1:
                w[a] = 0
        self.bset.bodies[i].set_velocity(v, w)

    def _props_pre(mut self, dt: Real):
        """Damping, then accumulated forces become this step's impulses.

        Damping first: the force impulse then reaches the solver whole, like
        gravity (added later, never damped), so a damped body held by a
        constraint settles where the loads balance. Damping after the force
        scaled only the force by 1 / (1 + c dt): a 1 m bar on a hinge under
        2 N m with angular damping 2 settled at 0.4091 rad instead of
        asin(2 / (m g d)) = 0.4204 (`test_joint_parity`)."""
        for i in range(len(self.bset.bodies)):
            if not self.bset.is_dynamic(i) or self.bset.sleeping[i]:
                continue
            var cl = self.bset.lin_damping[i]
            var ca = self.bset.ang_damping[i]
            if cl > 0 or ca > 0:
                self.bset.bodies[i].set_velocity(
                    self.bset.bodies[i].linear_velocity() / (1 + cl * dt),
                    self.bset.bodies[i].omega_world() / (1 + ca * dt),
                )
            var f = self.bset.force[i]
            var t = self.bset.torque[i]
            if f[0] != 0 or f[1] != 0 or f[2] != 0:
                self.bset.bodies[i].apply_impulse(f * dt, self.bset.bodies[i].position())
                self.bset.force[i] = Vec3(0, 0, 0, 0)
            if t[0] != 0 or t[1] != 0 or t[2] != 0:
                self.bset.bodies[i].apply_angular_impulse(t * dt)
                self.bset.torque[i] = Vec3(0, 0, 0, 0)

    def _props_post(mut self):
        """Speed caps (counted) and a final lock projection."""
        for i in range(len(self.bset.bodies)):
            if not self.bset.is_dynamic(i):
                continue
            if self.bset.locks[i] != 0:
                self._apply_locks(i)
            var ml = self.bset.max_lin[i]
            var ma = self.bset.max_ang[i]
            if ml <= 0 and ma <= 0:
                continue
            var v = self.bset.bodies[i].linear_velocity()
            var w = self.bset.bodies[i].omega_world()
            var clamped = False
            if ml > 0:
                var sv = sqrt(dot(v, v))
                if sv > ml:
                    v = v * (ml / sv)
                    clamped = True
            if ma > 0:
                var sw = sqrt(dot(w, w))
                if sw > ma:
                    w = w * (ma / sw)
                    clamped = True
            if clamped:
                self.bset.bodies[i].set_velocity(v, w)
                self.counters.incr(VELOCITY_CLAMPED)

    def teleport(mut self, id: BodyId, pose: Pose6) raises:
        """Instantly move body `id` to `pose` (velocity untouched), wake it
        (ROADMAP 17.25's "post-teleport auto-wake"), and drop any warm-start
        cache entries that reference it -- an impulse accumulator anchored
        to the OLD position must never be re-applied at the new one next
        frame (it would inject a spurious impulse at a contact point that
        no longer describes real overlap)."""
        if not self.bset.is_valid(id):
            raise Error("ContactScene6.teleport: invalid BodyId")
        var i = id.index()
        self.bset.bodies[i].set_pose(pose)
        self.bset.sleeping[i] = False
        self.bset.sleep_timer[i] = 0
        wake_island(self.bset, i)
        var kept = List[ContactConstraint]()
        for c in range(len(self.cache)):
            if self.cache[c].a != i and self.cache[c].b != i:
                kept.append(self.cache[c])
        self.cache = kept^

    def teleport_many(mut self, ids: List[BodyId], poses: List[Pose6]) raises:
        """ROADMAP 17.78: `teleport` for many bodies with one pass over the
        bodies (island wake-up) and one over the warm-start cache, instead
        of one of each per body. The resulting state is the same as calling
        `teleport` for each in order. Validates every id first; raises
        before moving anything."""
        if len(ids) != len(poses):
            raise Error("ContactScene6.teleport_many: ids and poses differ in length")
        for id in ids:
            if not self.bset.is_valid(id):
                raise Error("ContactScene6.teleport_many: invalid BodyId")
        var n = len(self.bset.bodies)
        var moved = List[Bool](length=n, fill=False)
        var wake_lbl = Dict[Int, Bool]()
        for k in range(len(ids)):
            var i = ids[k].index()
            self.bset.bodies[i].set_pose(poses[k].copy())
            self.bset.sleeping[i] = False
            self.bset.sleep_timer[i] = 0
            moved[i] = True
            if self.bset.is_dynamic(i):
                wake_lbl[self.bset.island[i]] = True
        if len(wake_lbl) > 0:
            for j in range(n):
                if self.bset.sleeping[j] and self.bset.island[j] in wake_lbl:
                    self.bset.sleeping[j] = False
                    self.bset.sleep_timer[j] = 0
        var kept = List[ContactConstraint]()
        for c in range(len(self.cache)):
            if not moved[self.cache[c].a] and not moved[self.cache[c].b]:
                kept.append(self.cache[c])
        self.cache = kept^

    def shift_origin(mut self, d: Vec3) raises:
        """Origin rebasing (ROADMAP 17.8): the world origin moves to `d`, so
        every world-space quantity becomes `p - d`. That is every body's
        position (static, kinematic and removed slots too), the world-space
        manifold points of the warm-start and sensor caches, soft-body
        particles and static meshes / heightfields (`ColliderSet
        .shift_static`). Joint anchors, contact offsets `ra` / `rb`, drive
        targets, velocities, impulses and island / sleep state are
        body-relative or translation-invariant and stay as they are, so a
        resting stack keeps its warm start across the shift. The broadphase
        is rebuilt every step and holds nothing to move.

        Exact when every coordinate and `d` are multiples of a common power
        of two that each `p - d` can still represent (e.g. `d` snapped to a
        grid of 2^k m and |p - d| <= |p|); otherwise each coordinate rounds
        once, at the new, finer resolution."""
        if not (isfinite(d[0]) and isfinite(d[1]) and isfinite(d[2])):
            raise Error("ContactScene6.shift_origin: shift must be finite")
        var dd = Vec3(d[0], d[1], d[2], 0)
        for i in range(len(self.bset.bodies)):
            var p = self.bset.bodies[i].position()
            var r = self.bset.bodies[i].rotation()
            self.bset.bodies[i].set_pose(Pose6(p - dd, r))
        for c in range(len(self.cache)):
            for k in range(self.cache[c].m.count):
                self.cache[c].m.points[k] = self.cache[c].m.points[k] - dd
        for c in range(len(self.sensor_pairs)):
            for k in range(self.sensor_pairs[c].m.count):
                self.sensor_pairs[c].m.points[k] = self.sensor_pairs[c].m.points[k] - dd
        for s in range(len(self.softs)):
            self.softs[s].shift(dd)
        self.colliders.shift_static(dd)

    def _pose(self, i: Int) -> Pose3:
        """The seam value: everything `ColliderSet` needs from body `i`'s
        transform, and nothing else -- collision never sees a `Body6`."""
        return self.bset.pose3(i)


    # ------------------------------------------------ world queries (17.13)
    # Thin wrappers over `collision.world_query`: this is the only place that
    # knows how to turn bodies into the `Pose3`s the collision layer takes.

    def query_poses(self) -> List[Pose3]:
        var out = List[Pose3](capacity=len(self.bset.bodies))
        for i in range(len(self.bset.bodies)):
            out.append(self._pose(i))
        return out^

    def ray_cast(self, origin: Vec3, dir: Vec3, max_t: Real, f: QueryFilter) -> Hit:
        return wq_ray_cast(self.colliders, self.query_poses(), origin, dir, max_t, f)

    def sphere_cast(
        self, c: Vec3, r: Real, dir: Vec3, max_t: Real, f: QueryFilter
    ) -> Hit:
        return wq_sphere_cast(self.colliders, self.query_poses(), c, r, dir, max_t, f)

    def capsule_cast(
        self, a: Vec3, b: Vec3, r: Real, dir: Vec3, max_t: Real, f: QueryFilter
    ) -> Hit:
        return wq_capsule_cast(
            self.colliders, self.query_poses(), a, b, r, dir, max_t, f
        )

    def overlap_sphere(self, c: Vec3, r: Real, f: QueryFilter) -> List[Int]:
        return wq_overlap_sphere(self.colliders, self.query_poses(), c, r, f)

    def capsule_penetrations(
        self, a: Vec3, b: Vec3, r: Real, f: QueryFilter
    ) -> List[Penetration]:
        return wq_capsule_penetrations(self.colliders, self.query_poses(), a, b, r, f)

    def closest_point(self, i: Int, p: Vec3) -> Probe:
        return wq_point_distance(self.colliders, i, self._pose(i), p)

    # 17.53 -- multi-hit rays, convex shape queries, persistent prefilter.

    def ray_cast_all(
        self, origin: Vec3, dir: Vec3, max_t: Real, f: QueryFilter, max_hits: Int = 64
    ) -> List[Hit]:
        return wq_ray_cast_all(self.colliders, self.query_poses(), origin, dir, max_t, f, max_hits)

    def ray_cast_any(self, origin: Vec3, dir: Vec3, max_t: Real, f: QueryFilter) -> Bool:
        return wq_ray_cast_any(self.colliders, self.query_poses(), origin, dir, max_t, f)

    def shape_cast(
        self, shape: QueryShape, pose: Pose3, dir: Vec3, max_t: Real, f: QueryFilter
    ) -> Hit:
        return wq_shape_cast(self.colliders, self.query_poses(), shape, pose, dir, max_t, f)

    def overlap_shape(self, shape: QueryShape, pose: Pose3, f: QueryFilter) -> List[Int]:
        return wq_overlap_shape(self.colliders, self.query_poses(), shape, pose, f)

    def shape_penetrations(self, shape: QueryShape, pose: Pose3, f: QueryFilter) -> List[Penetration]:
        return wq_shape_penetrations(self.colliders, self.query_poses(), shape, pose, f)

    def closest_points(self, a: BodyId, b: BodyId, search: Real = 1e30) raises -> ConvexDistance:
        """Separation distance and closest points of two bodies' colliders
        (`collision.world_query.closest_points`)."""
        var i = self._check_id(a, "closest_points")
        var j = self._check_id(b, "closest_points")
        return wq_closest_points(self.colliders, self.query_poses(), i, j, search)

    def query_index(self) -> QueryIndex:
        """This step's poses plus a BVH over the colliders, for many queries
        in one frame (rebuild after bodies move)."""
        return QueryIndex(self.colliders, self.query_poses())

    def ray_cast_batch(
        self,
        origins: List[Vec3],
        dirs: List[Vec3],
        max_t: Real,
        f: QueryFilter,
        dispatch: Dispatch = Dispatch.serial(),
        workers: Int = 0,
    ) -> List[Hit]:
        """Many rays against one index built for the batch; each ray is an
        independent item, so any `dispatch` gives the same list."""
        var idx = self.query_index()
        var out = self.ray_cast_batch_in(idx, origins, dirs, max_t, f, dispatch, workers)
        _ = idx^
        return out^

    def ray_cast_batch_in(
        self,
        idx: QueryIndex,
        origins: List[Vec3],
        dirs: List[Vec3],
        max_t: Real,
        f: QueryFilter,
        dispatch: Dispatch = Dispatch.serial(),
        workers: Int = 0,
    ) -> List[Hit]:
        """`ray_cast_batch` against an index the caller built
        (`query_index`) and reuses for every batch of the frame: the build
        is serial and, at 1024 rays over 4096 colliders, costs as much as
        the rays (`bench_query_ext`)."""
        var out = List[Hit](capacity=len(origins))
        for _ in range(len(origins)):
            out.append(Hit.miss())
        var task = _RayTask(self.colliders, idx, origins, dirs, out, max_t, f)
        dispatch_for(dispatch, task, (len(origins) + _RAY_CHUNK - 1) // _RAY_CHUNK, workers)
        _ = len(origins)
        _ = len(dirs)
        return out^

    def _constraint_edges(self, pairs: List[ContactConstraint]) -> List[Int]:
        """The flat `(a, b)` edge list `islands.refresh_islands` takes:
        this step's contacts first, then the joints -- the order the island
        union-find has always merged them in."""
        var edges = List[Int](capacity=2 * (len(pairs) + len(self.joints) + len(self.drives)))
        for c in range(len(pairs)):
            edges.append(pairs[c].a)
            edges.append(pairs[c].b)
        for c in range(len(self.joints)):
            if self.joints[c].kind == JOINT_BROKEN:
                continue
            edges.append(self.joints[c].a)
            edges.append(self.joints[c].b)
        for c in range(len(self.drives)):
            edges.append(self.drives[c].a)
            edges.append(self.drives[c].b)
        return edges^

    def _narrow_reuse(
        mut self, ci: List[Int], cj: List[Int], n: Int, spec_dt: Real, margin_base: Real,
        mut raws: List[RawContact], mut sraws: List[RawContact],
    ):
        """ROADMAP 17.85: the narrowphase with `SolverConfig.reuse_still_pairs`.
        `try_pair` is a function of the colliders, both poses and linear
        velocities, `spec_dt` and the margin only, so a candidate whose two
        bodies are bit-for-bit where they were at the previous collection
        (same velocities, same `colliders.epoch`, same `spec_dt` / margin)
        gets last time's output copied instead of recomputed: frozen or
        sleeping islands, and every body a tier plan did not step. The output
        is the one the plain loop would build, in candidate order."""
        var poses = List[Pose3](capacity=n)
        var vels = List[Vec3](capacity=n)
        for i in range(n):
            poses.append(self._pose(i))
            vels.append(self.bset.bodies[i].linear_velocity())
        var valid = (
            self._np_epoch == self.colliders.epoch and self._np_spec == spec_dt
            and self._np_margin == margin_base and len(self._np_pose) == n
        )
        var still = List[Bool](capacity=n)
        for i in range(n):
            var st = valid
            if st:
                var p = poses[i].position
                var q = self._np_pose[i].position
                st = p == q and vels[i] == self._np_vel[i]
                if st:
                    for k in range(3):
                        if poses[i].axes[k] != self._np_pose[i].axes[k]:
                            st = False
            still.append(st)
        var nlo = List[Int](capacity=len(ci))
        var ncnt = List[Int](capacity=len(ci))
        var nslo = List[Int](capacity=len(ci))
        var nscnt = List[Int](capacity=len(ci))
        var keys = Dict[Int, Int]()
        var reused = 0
        for c in range(len(ci)):
            var i = ci[c]
            var j = cj[c]
            var a = len(raws)
            var sa = len(sraws)
            var k = -1
            if still[i] and still[j]:
                k = self._np_keys.get(i * n + j, -1)
            if k >= 0:
                for q in range(self._np_lo[k], self._np_lo[k] + self._np_cnt[k]):
                    raws.append(self._np_raws[q].copy())
                for q in range(self._np_slo[k], self._np_slo[k] + self._np_scnt[k]):
                    sraws.append(self._np_sraws[q].copy())
                reused += 1
            else:
                try_pair(self.colliders, i, j, poses[i], poses[j], vels[i], vels[j], spec_dt, raws, sraws, margin_base)
            keys[i * n + j] = c
            nlo.append(a)
            ncnt.append(len(raws) - a)
            nslo.append(sa)
            nscnt.append(len(sraws) - sa)
        self._np_keys = keys^
        self._np_lo = nlo^
        self._np_cnt = ncnt^
        self._np_slo = nslo^
        self._np_scnt = nscnt^
        self._np_raws = raws.copy()
        self._np_sraws = sraws.copy()
        self._np_pose = poses^
        self._np_vel = vels^
        self._np_epoch = self.colliders.epoch
        self._np_spec = spec_dt
        self._np_margin = margin_base
        self.np_reused = reused

    def _collect_pairs(
        mut self, warm: Bool, spec_dt: Real, use_bp: Bool = False, margin_base: Real = SPEC_BASE,
        par: Bool = False, workers: Int = 0, dispatch: Dispatch = Dispatch.parallel(),
        reuse: Bool = False,
    ) -> List[ContactConstraint]:
        """Manifolds at the current poses (ROTATED box-box manifold — tilted
        geometry produces restoring contacts). With `warm`, impulses are
        inherited from last frame's matching pair by (a, b) key (order-
        independent). `spec_dt > 0` = SPECULATIVE detection (first-stage CCD,
        Jolt/Box2D): boxes inflated by a velocity-scaled margin, subtracted
        back from the depths so near-contacts enter with NEGATIVE depth and
        the `d < 0 -> bias = -d/h` branch stops fast movers AT the surface.

        `use_bp` swaps the O(n²) double loop for `self.bp` (any `BroadPhase`
        backend) over fat world-AABBs: `collision.contact_gen.collect_bp_pairs`
        reduces its candidates to the SAME (i, j) lexicographic order the
        brute path visits, so the pair set and the Gauss-Seidel sweep are
        bit-identical regardless of which backend `Self.BP` is
        (`tests/test_solver_bp_seam.mojo`). Candidate geometry (which pair
        touched, on what manifold) comes from `collision.contact_gen.try_pair`
        over `self.colliders`; this method's own job is wrapping that
        geometry with the warm-start match and body-frame anchors that need
        `Body6` (`_make_cpair`).

        ROADMAP 17.54: candidates are enumerated first (span "broadphase"),
        then run through the narrowphase ("narrowphase") and wrapped
        ("contact_prep"). With `par` and at least `NARROW_PAR_MIN`
        candidates the last two fan out through `dispatch`
        (`physics.collide_par`), keeping the candidate order, so the result
        is bit-identical to `par=False`."""
        # reserved from last step's contact count (ROADMAP 17.79): these
        # lists were rebuilt from empty every step, ~9 reallocations each
        var est = len(self.cache) + 8
        var raws = List[RawContact](capacity=est)
        var sraws = List[RawContact]()
        var ci = List[Int](capacity=2 * est)
        var cj = List[Int](capacity=2 * est)
        self.trace.begin("broadphase")
        var n = len(self.bset.bodies)
        # ROADMAP 17.5: two bodies held together by a live weld do not collide
        # with each other (a fracture bond is a rigid seam, not two touching
        # solids); the pair collides normally the step after the weld breaks.
        # Built only when a weld exists, so scenes without one are untouched.
        # ROADMAP 17.47: likewise any joint whose ext says collide = False.
        var weld_keys = Dict[Int, Bool]()
        for c in range(len(self.joints)):
            if self.joints[c].kind == JOINT_BROKEN:
                continue
            if self.joints[c].kind == JOINT_WELD or (c < len(self.jext) and not self.jext[c].collide):
                var wa = min(self.joints[c].a, self.joints[c].b)
                var wb = max(self.joints[c].a, self.joints[c].b)
                weld_keys[wa * n + wb] = True
        var has_weld = len(weld_keys) > 0
        if use_bp:
            # `Self.BP.dim` is a dependent expression that never unifies
            # with the literal `3` `ColliderSet.fat_aabb` returns, even
            # though the `__init__` comptime assert guarantees they are
            # equal (mojo_1.1_migration.md Gotcha #2) -- `rebind` bridges
            # the two syntactically-distinct, semantically-equal types.
            var boxes = List[AABB[Self.BP.dim]](capacity=n)
            var any_removed = len(self.bset.free) > 0
            for i in range(n):
                if any_removed and self.bset.is_removed(i):
                    # never inserted (`removed` below); no box to compute
                    var z = Vec3(0, 0, 0, 0)
                    boxes.append(rebind[AABB[Self.BP.dim]](AABB[3](z, z)))
                    continue
                boxes.append(
                    rebind[AABB[Self.BP.dim]](
                        self.colliders.fat_aabb(
                            i, self._pose(i), self.bset.bodies[i].linear_velocity(), spec_dt, margin_base
                        )
                    )
                )
            var bp_pairs = List[Pair](capacity=2 * est)
            # removed slots stay out of the broadphase (ROADMAP 17.79); only
            # built when a slot has been removed, so other scenes are untouched
            var removed = List[Bool]()
            if len(self.bset.free) > 0:
                removed = List[Bool](length=n, fill=False)
                for i in range(n):
                    removed[i] = self.bset.is_removed(i)
            # `collect_bp_pairs` still wants a plain `List[Bool]` of which
            # bodies are static (it lives in `collision`, which cannot
            # import `physics.body_set`'s `MOTION_*` constants -- physics is
            # a higher layer); build it from `self.bset.motion` once here
            # rather than widen that seam's parameter type for one caller.
            # `collect_bp_pairs` drops a pair when BOTH entries read `True`
            # here -- passing "is dynamic? no" (rather than literally
            # `is_static`) makes it drop kinematic-static AND
            # kinematic-kinematic pairs too (ROADMAP 17.24: neither produces
            # a contact), with no change needed in `collision.contact_gen`
            # itself, which only ever sees this bool, never a motion type.
            var is_static_bool = List[Bool](capacity=n)
            for i in range(n):
                is_static_bool.append(not self.bset.is_dynamic(i))
            # `collect_bp_pairs` is `raises` only because `SpatialHashBroadPhase`
            # (one of the dim-3 backends `Self.BP` can be) wraps
            # `SpatialHashGrid`, whose own methods raise. That is a broken-
            # invariant class of failure for a scene the engine already
            # validated at `add*`/`set_filter` time, not caller input this
            # method should propagate (docs/ARCHITECTURE.md S2, "programmer
            # error... terminate") -- so it is caught and aborted here rather
            # than making `step`/`step_soft` (and every one of their ~100
            # call sites across tests/benchmarks) `raises` for a path that
            # should never actually raise.
            try:
                if par and n >= BP_PAR_MIN:
                    pairs_parallel[Self.BP](self.bp, boxes, is_static_bool, bp_pairs, workers, dispatch, removed)
                else:
                    collect_bp_pairs[Self.BP](self.bp, boxes, is_static_bool, bp_pairs, removed)
            except e:
                abort("BroadPhase raised inside ContactScene6: " + String(e))
            for c in range(len(bp_pairs)):
                var i = bp_pairs[c].a
                var j = bp_pairs[c].b
                # ROADMAP 17.0i: a removed body keeps its stale collider row
                # in place (`ColliderSet` has no free list of its own -- see
                # `remove_body`'s docstring), so it must be excluded here,
                # not just from the `is_dynamic` gate above (a removed body
                # reads `is_dynamic == False`, same as static, so a pair
                # against a still-dynamic neighbor is NOT dropped by
                # `is_static_bool` alone).
                if self.bset.is_removed(i) or self.bset.is_removed(j):
                    continue
                if has_weld and (min(i, j) * n + max(i, j)) in weld_keys:
                    continue
                self.counters.incr(NARROWPHASE_PAIRS)
                ci.append(i)
                cj.append(j)
        else:
            # The same fat AABBs the broadphase path tests, so brute and
            # broadphase now see the same pairs. They are not a strict
            # superset of every speculative manifold: a rotated box inflated
            # along its own axes reaches up to sqrt(3) x the margin past its
            # box, and a hull pair can report a speculative contact 9 cm
            # apart -- such far pairs used to reach the narrowphase only on
            # this path (test_fracture's brick piles counted one island
            # less). Without the cull every pair reached the narrowphase:
            # 64 cylinders on a floor made 2080 hull tests per step (18 ms)
            # for 64 real contacts.
            var fat = List[AABB[3]](capacity=n)
            for i in range(n):
                fat.append(self.colliders.fat_aabb(i, self._pose(i), self.bset.bodies[i].linear_velocity(), spec_dt, margin_base))
            for i in range(n):
                for j in range(i + 1, n):
                    if not fat[i].overlaps(fat[j]):
                        # still an enumerated candidate: NARROWPHASE_PAIRS
                        # counts what the brute loop examines (test_work_counters)
                        if self.bset.is_dynamic(i) or self.bset.is_dynamic(j):
                            if not (self.bset.is_removed(i) or self.bset.is_removed(j)):
                                if not (has_weld and (i * n + j) in weld_keys):
                                    self.counters.incr(NARROWPHASE_PAIRS)
                        continue
                    # ROADMAP 17.0i: a removed body's collider row is stale
                    # (see the broadphase branch's matching comment above).
                    if self.bset.is_removed(i) or self.bset.is_removed(j):
                        continue
                    if has_weld and (i * n + j) in weld_keys:
                        continue
                    # same rule as the broadphase branch above: skip only
                    # when NEITHER side is dynamic (static-static,
                    # static-kinematic, kinematic-kinematic all produce no
                    # contact -- ROADMAP 17.24).
                    if not self.bset.is_dynamic(i) and not self.bset.is_dynamic(j):
                        continue
                    self.counters.incr(NARROWPHASE_PAIRS)
                    ci.append(i)
                    cj.append(j)
        self.trace.end()
        self.trace.begin("narrowphase")
        var fan = par and len(ci) >= NARROW_PAR_MIN
        if fan and not reuse:
            var poses = List[Pose3](capacity=n)
            var vels = List[Vec3](capacity=n)
            for i in range(n):
                poses.append(self._pose(i))
                vels.append(self.bset.bodies[i].linear_velocity())
            var cnt = List[Int](length=len(ci), fill=0)
            var scnt = List[Int](length=len(ci), fill=0)
            narrow_parallel(self.colliders, poses, vels, ci, cj, spec_dt, margin_base, raws, sraws, cnt, scnt, workers, dispatch)
        elif reuse:
            self._narrow_reuse(ci, cj, n, spec_dt, margin_base, raws, sraws)
        else:
            for c in range(len(ci)):
                var i = ci[c]
                var j = cj[c]
                try_pair(
                    self.colliders, i, j, self._pose(i), self._pose(j),
                    self.bset.bodies[i].linear_velocity(),
                    self.bset.bodies[j].linear_velocity(),
                    spec_dt, raws, sraws, margin_base,
                )
        self.trace.end()
        self.trace.begin("contact_prep")
        self.sensor_pairs = List[ContactConstraint]()  # rebuilt with the solved pairs
        for c in range(len(sraws)):
            self.sensor_pairs.append(make_sensor_contact(sraws[c]))
        self.counters.incr(CONTACT_MANIFOLDS, Int64(len(raws)))
        for c in range(len(raws)):
            self.counters.incr(CONTACT_POINTS, Int64(raws[c].m.count))
        var cidx = cache_index(self.cache)
        var pairs: List[ContactConstraint]
        if fan:
            pairs = prep_parallel(self.bset, self.colliders, self.cache, cidx, raws, warm, workers, dispatch, margin_base / SPEC_BASE)
        else:
            pairs = List[ContactConstraint](capacity=len(raws))
            for c in range(len(raws)):
                pairs.append(make_contact(self.bset, self.colliders, self.cache, cidx, raws[c], warm, margin_base / SPEC_BASE))
        if len(self.material_mu) > 0 or len(self.material_hz) > 0:
            self._apply_materials(pairs)
        apply_rules(self.bset, self.rules, pairs)
        self.trace.end()
        return pairs^

    def step(mut self, dt: Real, gravity: Vec3, iters: Int = 8):
        # 1. Gravity on dynamic bodies only (velocity level) -- kinematic
        # bodies (ROADMAP 17.24) are unaffected by gravity, their velocity is
        # entirely caller-set.
        for i in range(len(self.bset.bodies)):
            if self.bset.is_dynamic(i):
                var f = self.bset.gravity_for(i, gravity) / self.bset.bodies[i].inv_mass()  # force = m·g
                self.bset.bodies[i].integrate_force(dt, f, Vec3(0, 0, 0, 0))
        # 2. Contact manifolds at the pre-solve poses.
        var pairs = self._collect_pairs(False, 0)
        # 3. Gauss-Seidel sweeps of accumulated per-point normal impulses.
        for _ in range(iters):
            for c in range(len(pairs)):
                var pr = pairs[c]
                for k in range(pr.m.count):
                    pr.acc[k] = solve_point(
                        self.bset,
                        pr.a,
                        pr.b,
                        pr.m.normal,
                        pr.m.points[k],
                        pr.m.depths[k],
                        dt,
                        pr.acc[k],
                    )
                pairs[c] = pr
        # 4. Advance poses.
        for i in range(len(self.bset.bodies)):
            if not self.bset.is_static(i):
                self.bset.bodies[i].integrate_pose(dt)

    def _reset_joint_sums(mut self):
        var n = len(self.joints)
        self.jsum_f = List[Vec3](capacity=n)
        self.jsum_t = List[Vec3](capacity=n)
        self.jspan = List[Real](capacity=n)
        self.jexcess = List[Vec3](capacity=n)
        self.jexcess_up = List[Int](capacity=n)
        for _ in range(n):
            self.jsum_f.append(Vec3(0, 0, 0, 0))
            self.jsum_t.append(Vec3(0, 0, 0, 0))
            self.jspan.append(0)
            self.jexcess.append(Vec3(0, 0, 0, 0))
            self.jexcess_up.append(-1)

    def _report_substep(
        mut self, mut pairs: List[ContactConstraint], lo: Int, hi: Int, label: Int,
        sub: Int, substeps: Int, h: Real,
    ):
        """ROADMAP 17.49: fold this substep's contact and joint impulses into
        the step totals -- every substep (IMPULSE_SUBSTEP_SUM) or only the
        last one, scaled by `substeps` (IMPULSE_LAST_SUBSTEP). `label` limits
        the joints to one island (-2 = all), as `joint_sweep` does."""
        var scale = Real(1)
        if self.impulse_estimator == IMPULSE_LAST_SUBSTEP:
            if sub != substeps - 1:
                return
            scale = Real(substeps)
        accumulate_step_impulse(self.bset, pairs, lo, hi, scale, h)
        for c in range(len(self.joints)):
            ref jt = self.joints[c]
            if jt.kind == JOINT_BROKEN:
                continue
            if label != -2 and joint_island(self.bset, jt) != label:
                continue
            self.jsum_f[c] = self.jsum_f[c] + jt.acc * scale
            self.jsum_t[c] = self.jsum_t[c] + jt.acc_ang * scale
            if self.any_ext and c < len(self.jext) and self.jext[c].active():
                var e = ext_impulse(self.bset, jt, self.jext[c])
                self.jsum_f[c] = self.jsum_f[c] + e[0] * scale
                self.jsum_t[c] = self.jsum_t[c] + e[1] * scale
            self.jspan[c] += h * scale

    def _solve_island(
        mut self,
        mut pairs: List[ContactConstraint],
        plo: Int,
        phi: Int,
        label: Int,
        gravity: Vec3,
        h: Real,
        substeps: Int,
        iters: Int,
        bias_rate: Real,
        mass_scale: Real,
        impulse_scale: Real,
        mu: Real,
        members: List[Int],
        mlo: Int,
        mhi: Int,
        rest_threshold: Real = 1.0,
        ccd: Bool = False,
        ccd_all: Bool = False,
    ):
        """The full substep loop restricted to one island: its bodies
        (`members[mlo:mhi]`, ascending slot order), its contiguous pair
        range, its joints. Islands share nothing, so running these in
        parallel is bit-identical to running them in sequence. The member
        range replaced a scan of every body per island (O(bodies x islands),
        885 ms / step at 1e4 bodies in `bench_tiers`); per-body updates are
        independent, so visiting only the members changes nothing else."""
        for sub in range(substeps):
            # gravity: DYNAMIC members of this island only. A kinematic body
            # gets its OWN singleton island (`_refresh_islands`'s docstring),
            # so it reaches this loop too, with `is_dynamic == False` --
            # skipped here, same as it would be in the serial `step` path.
            for m in range(mlo, mhi):
                var i = members[m]
                if self.bset.is_dynamic(i) and not self.bset.sleeping[i]:
                    var f = self.bset.gravity_for(i, gravity) / self.bset.bodies[i].inv_mass()
                    self.bset.bodies[i].integrate_force(h, f, Vec3(0, 0, 0, 0))
            warm_start_contacts(self.bset, pairs, plo, phi)
            warm_start_joints(self.bset, self.joints, label)
            if self.any_ext:
                warm_start_ext(self.bset, self.joints, self.jext, label)
            joint_sweep(
                self.bset, self.joints, h, bias_rate, mass_scale, impulse_scale, True, iters, label
            )
            if self.any_ext:
                ext_sweep(self.bset, self.joints, self.jext, h, bias_rate, mass_scale, impulse_scale, True, iters, label)
            soft_sweep(
                self.bset, pairs, plo, phi, h, bias_rate, mass_scale,
                impulse_scale, True, iters, mu, self.max_push,
            )
            # pose: dynamic (if awake) OR kinematic -- `not _inactive` is
            # exactly `moves(i) and not sleeping[i]` here since `_inactive`
            # is `is_static or sleeping` and this loop never sees a static
            # body's label (`_refresh_islands` never assigns one).
            if ccd:
                # 17.46: island-local CCD (members + static candidates)
                ccd_advance_island(self.bset, self.colliders, h, ccd_all, members, mlo, mhi)
            else:
                for m in range(mlo, mhi):
                    var i = members[m]
                    if not self.bset.inactive(i):
                        if self.bset.any_props and self.bset.locks[i] != 0:
                            self._apply_locks(i)
                        self.bset.bodies[i].integrate_pose(h)
            joint_sweep(self.bset, self.joints, h, bias_rate, 1, 0, False, 2, label)
            if self.any_ext:
                ext_sweep(self.bset, self.joints, self.jext, h, bias_rate, 1, 0, False, 2, label)
            soft_sweep(self.bset, pairs, plo, phi, h, bias_rate, 1, 0, False, 2, mu)
            self._report_substep(pairs, plo, phi, label, sub, substeps, h)
        restitution_pass(self.bset, pairs, plo, phi, 4, rest_threshold)
        add_restitution_impulse(self.bset, pairs, plo, phi)

    def _emit_events(mut self, pairs: List[ContactConstraint]):
        """Diff this step's contact set against last step's: began / stay /
        ended (`collision.contact_events.diff_events`).

        The set is derived, not tracked. The solver already knows exactly
        which contacts exist this step — it just built them — and the warm-
        start cache is last step's answer to the same question, so the
        events are a sorted merge of two key lists and nothing has to be
        maintained incrementally or invalidated when a body is removed.

        Sensor overlaps are included: a trigger volume that never receives an
        impulse still has to say when something entered it, and that is the
        whole reason sensors exist."""
        self.events = List[ContactEvent]()
        var cur = List[Int](capacity=len(pairs) + len(self.sensor_pairs))
        var at = Dict[Int, Int]()  # key -> pair index (contacts only)
        var filt = self.bset.any_report
        for c in range(len(pairs)):
            if filt and not (self.bset.report[pairs[c].a] or self.bset.report[pairs[c].b]):
                continue
            var k = pack_key(pairs[c].a, pairs[c].b, pairs[c].feat)
            cur.append(k)
            at[k] = c
        for c in range(len(self.sensor_pairs)):
            ref sp = self.sensor_pairs[c]
            if filt and not (self.bset.report[sp.a] or self.bset.report[sp.b]):
                continue
            cur.append(pack_key(sp.a, sp.b, sp.feat))
        sort(cur)
        diff_events(cur, self._prev_keys, self.events)
        # ROADMAP 17.49 payload. `diff_events` emits in key order, so the
        # previous peaks are looked up by key; the new peaks follow `cur`.
        var prev_peak = Dict[Int, Real]()
        for i in range(len(self._prev_keys)):
            if i < len(self._prev_peak):
                prev_peak[self._prev_keys[i]] = self._prev_peak[i]
        var peak_of = Dict[Int, Real]()
        for e in range(len(self.events)):
            ref ev = self.events[e]
            var k = pack_key(ev.a, ev.b, ev.feat)
            var before = prev_peak.get(k, Real(0))
            if ev.kind == EV_ENDED:
                ev.peak = before
                continue
            var c = at.get(k, -1)
            if c >= 0:
                ref pr = pairs[c]
                var total = Real(0)
                var best = -1
                var approach = Real(0)
                for q in range(pr.m.count):
                    total += pr.jn[q]
                    if best < 0 or pr.jn[q] > pr.jn[best]:
                        best = q
                    approach = max(approach, -pr.vn0[q])
                total = _excess_jn(pr, total)
                ev.impulse = total
                ev.force = total / pr.span if pr.span > 0 else Real(0)
                if best >= 0:
                    ev.point = pr.m.points[best]
                ev.normal = pr.m.normal
                ev.approach = approach
                if best >= 0:
                    # 17.90: sliding speed for friction / scrape sounds; reads state only
                    var rel = self.bset.bodies[ev.b].velocity_at(ev.point) - self.bset.bodies[ev.a].velocity_at(ev.point)
                    ev.tvel = rel - pr.m.normal * dot(rel, pr.m.normal)
            ev.peak = max(before, ev.impulse) if ev.kind == EV_STAY else ev.impulse
            peak_of[k] = ev.peak
        self._prev_peak = List[Real](capacity=len(cur))
        for i in range(len(cur)):
            self._prev_peak.append(peak_of.get(cur[i], Real(0)))
        self._prev_keys = cur^

    def _quarantine_nonfinite(mut self):
        """End-of-step NaN/Inf scan (audit E3/E22-adjacent; the `docs
        /ARCHITECTURE.md` S2 "Numerical failure" row): ONE pass over dynamic
        bodies, run once per `step` call, never per substep/iteration --
        catching a non-finite body an iteration late costs nothing extra
        (it is already quarantined for the REST of this step's substeps and
        every step after), and scanning every substep would multiply the
        cost by `substeps` for no benefit.

        A non-finite body (NaN/Inf position, linear velocity, or angular
        velocity) is quarantined: velocity zeroed, force-slept so it stops
        integrating, and dropped from the warm-start cache so a stale
        accumulated impulse anchored to its last (possibly NaN) contact
        point is never re-applied next step. Its pose is reset to the
        origin/identity rather than "the last finite pose" (docs
        /design/17.0h-error-wiring.md's phrasing allows this: "if kept") --
        keeping a per-body pose history would turn this one pass into two
        (capture, then compare) every step, which is exactly the per-step
        fixed cost `bench_solver_scale`'s NaN-scan-overhead row exists to
        keep small; a reset-to-origin quarantined body is still FINITE and
        inert (force-slept), which is what every other body's broadphase/
        narrowphase queries against it actually need.

        A world must keep stepping (the table's "Propagates?" column for
        this row is "No exception") -- this never raises, only counts
        (`NAN_QUARANTINED`) and logs (WARN, via `self.log`)."""
        for i in range(len(self.bset.bodies)):
            if not self.bset.is_dynamic(i):
                continue
            var pos = self.bset.bodies[i].position()
            var vel = self.bset.bodies[i].linear_velocity()
            var w = self.bset.bodies[i].omega_world()
            if (
                Bool(isfinite(pos).reduce_and())
                and Bool(isfinite(vel).reduce_and())
                and Bool(isfinite(w).reduce_and())
            ):
                continue
            self.bset.bodies[i].set_pose(Pose6(Vec3(0, 0, 0, 0), Quat.identity()))
            self.bset.bodies[i].set_velocity(Vec3(0, 0, 0, 0), Vec3(0, 0, 0, 0))
            self.bset.sleeping[i] = True
            self.bset.sleep_timer[i] = 0
            self.counters.incr(NAN_QUARANTINED)
            log[Level.WARN](
                self.log, i, "solver",
                "body quarantined: non-finite pose/velocity", Float64(i), 0,
            )
            var kept = List[ContactConstraint]()
            for c in range(len(self.cache)):
                if self.cache[c].a != i and self.cache[c].b != i:
                    kept.append(self.cache[c])
            self.cache = kept^

    def _emit_debug_draw(mut self, pairs: List[ContactConstraint]):
        """Debug-draw (ROADMAP 17.0h; only compiled to a real call site when
        `-D LUDENS_DEBUG_DRAW` is defined -- `step`'s caller is a `comptime
        if DEBUG_DRAW_ON`). One `DrawCommand` per contact POINT (an arrow
        from the point along the contact normal), coloured by the pair's
        island -- so `sc.draw.count()` equals the step's total contact-point
        count exactly (the test this backs asserts that equality on a known
        stack), with island membership encoded as colour rather than as
        separate per-island commands that would break that count."""
        comptime scale = Real(0.15)  # arrow length, world units
        for pc in range(len(pairs)):
            ref pr = pairs[pc]
            var island = contact_island(self.bset, pr)
            # a small deterministic palette keyed by island label, wrapping
            # at 6 -- debug-draw is for a human to look at, not a contract.
            var color = island_color(island)
            for k in range(pr.m.count):
                var p0 = pr.m.points[k]
                var p1 = p0 + pr.m.normal * scale
                self.draw.arrow(p0, p1, color)

    def _color_pairs(
        mut self,
        mut pairs: List[ContactConstraint],
        mut clo: List[Int],
        mut chi: List[Int],
    ) -> Bool:
        """Greedy smallest-free-colour over the DYNAMIC-body adjacency (a
        shared static must not chain colours, or one ground plane serialises
        the whole scene); `pairs` reordered into contiguous per-colour ranges
        `[clo[c], chi[c])`. <= 64 colours (bit masks): on overflow `pairs` is
        left in its original order, `COLOR_OVERFLOW` counted, and False
        returned (the caller falls back to the uncoloured sweep)."""
        var n_colors = 0
        var mask = List[Int]()
        for _ in range(len(self.bset.bodies)):
            mask.append(0)
        var pcol = List[Int]()
        var overflow = False
        for pc in range(len(pairs)):
            var used = 0
            # DYNAMIC-body adjacency only (was `not is_static`): a
            # kinematic body, like a static one, is never WRITTEN by the
            # colored solve (`_solve_pair`'s impulse application is now
            # `is_dynamic`-gated too), so it must not force a color
            # conflict between two of its dynamic contacts either --
            # ROADMAP 17.24's "kinematic platform pushing N boxes"
            # benchmark would otherwise serialise through one platform
            # the same way a shared static ground plane is documented
            # NOT to below.
            if self.bset.is_dynamic(pairs[pc].a):
                used |= mask[pairs[pc].a]
            if self.bset.is_dynamic(pairs[pc].b):
                used |= mask[pairs[pc].b]
            var col = 0
            # `col < 64` must gate the loop itself, not just be checked
            # after it: found live (this loop used to be unbounded) --
            # once `used` has all 64 bits set (a body already touched by
            # 64 differently-coloured pairs), `used >> col` for `col >=
            # 64` does NOT read as zero the way a mathematical shift
            # would. Mojo's `>>` on `Int` bottoms out at the hardware
            # shift instruction, which masks the shift amount to the
            # register width (`col mod 64` on this target) -- so
            # `used >> 64` re-reads the SAME bits as `used >> 0`, the
            # condition never goes false, and `col` counts up forever.
            # This was a genuine infinite hang, not just "wrong colours
            # past 64" as first filed -- caught by this commit's own
            # extreme test (65 dynamic pairs sharing one body), which
            # hung indefinitely before this bound was added.
            while col < 64 and (used >> col) & 1 == 1:
                col += 1
            if col >= 64:
                # audit E7: a body touched by 64 differently-coloured
                # pairs -- `1 << col` on an `Int` is no longer a single
                # bit past width 63 (wraps/UB), which would corrupt the
                # mask and let two same-colour pairs share a body (a
                # data race under colored+parallel). Bail out of the
                # WHOLE partition rather than continue with a corrupt
                # one: `colored` false below falls through to the
                # existing serial `_soft_sweep(pairs, 0, len(pairs))`
                # path with `pairs` still in its original (uncoloured)
                # order, so this is "fall back to serial", not a crash.
                overflow = True
                break
            pcol.append(col)
            if col + 1 > n_colors:
                n_colors = col + 1
            if self.bset.is_dynamic(pairs[pc].a):
                mask[pairs[pc].a] |= 1 << col
            if self.bset.is_dynamic(pairs[pc].b):
                mask[pairs[pc].b] |= 1 << col
        if overflow:
            self.counters.incr(COLOR_OVERFLOW)
            return False
        else:
            var pairs3 = List[ContactConstraint]()
            for col in range(n_colors):
                clo.append(len(pairs3))
                for pc in range(len(pairs)):
                    if pcol[pc] == col:
                        pairs3.append(pairs[pc])
                chi.append(len(pairs3))
            pairs = pairs3^
        return True

    def _release_overloaded(mut self):
        self.broken_joints = List[Int]()
        if self.any_break:
            # 17.19 A2: a peak carries the scaled excess; subtract its magnitude
            for c in range(min(len(self.jexcess_up), len(self.peak_force))):
                if self.jexcess_up[c] >= 0:
                    var e = sqrt(dot(self.jexcess[c], self.jexcess[c]))
                    self.peak_force[c] = max(Real(0), self.peak_force[c] - e)
            check_breaks(
                self.joints, self.break_force, self.break_torque,
                self.peak_force, self.peak_torque, self.broken_joints,
            )

    def begin_external_solve(
        mut self,
        dt: Real,
        cfg: SolverConfig,
        mut clo: List[Int],
        mut chi: List[Int],
    ) -> List[ContactConstraint]:
        """The first half of a colored `step` for a solver that runs the
        substep loop elsewhere (`physics.gpu_contact`, ROADMAP 17.17):
        collect this frame's contacts, refresh islands, colour. On a colour
        overflow `clo`/`chi` come back empty and the pairs uncoloured; a
        colour-parallel solver must then refuse the frame."""
        self.colliders.reduce_mesh = cfg.reduce_mesh_contacts
        var pairs = self._collect_pairs(True, dt, cfg.broadphase, cfg.margin_base)
        refresh_islands(self.bset, self._constraint_edges(pairs), len(pairs))
        _ = self._color_pairs(pairs, clo, chi)
        return pairs^

    def end_external_solve(
        mut self, var pairs: List[ContactConstraint], dt: Real, cfg: SolverConfig
    ):
        """The second half: restitution, sleep, NaN quarantine, debug draw,
        events, warm-start cache -- the serial `step`'s tail, unchanged."""
        restitution_pass(self.bset, pairs, 0, len(pairs), 4, cfg.restitution_threshold)
        update_sleep(self.bset, dt, cfg)
        self._quarantine_nonfinite()
        comptime if DEBUG_DRAW_ON:
            self._emit_debug_draw(pairs)
        if self.events_on:
            self._emit_events(pairs)
        self.cache = pairs^

    def step_soft(
        mut self,
        dt: Real,
        gravity: Vec3,
        substeps: Int = 4,
        iters: Int = 4,
        hertz: Real = 30,
        zeta: Real = 10,
        mu: Real = 0.5,
        ccd: Bool = False,
        parallel: Bool = False,
        colored: Bool = False,
        broadphase: Bool = False,
        workers: Int = 0,
        max_mass_ratio: Real = MASS_RATIO_DEFAULT,
    ):
        """Thin forwarder (audit F19): builds a `SolverConfig` from these
        keyword arguments and calls `step`. Kept with its original keyword
        signature so every existing call site (~100 across tests/benchmarks/
        examples) keeps compiling. `max_mass_ratio` (17.19, default
        `MASS_RATIO_DEFAULT`; 0 = off) is forwarded to
        `SolverConfig.max_mass_ratio`."""
        var cfg = SolverConfig()
        cfg.substeps = substeps
        cfg.iters = iters
        cfg.hertz = hertz
        cfg.zeta = zeta
        cfg.default_friction = mu
        cfg.ccd = ccd
        cfg.parallel = parallel
        cfg.colored = colored
        cfg.broadphase = broadphase
        cfg.workers = workers
        cfg.max_mass_ratio = max_mass_ratio
        self.step(dt, gravity, cfg)

    def _own_excess(self, gravity: Vec3) -> List[Real]:
        """ROADMAP 17.19 A2: per body, the upward force its scaled mass adds
        to each of its supports. The solver weighs a scaled body as m_c > m,
        so its contacts carry (m_c - m) * |a| more than its true weight, where
        a is gravity plus the applied force per unit mass (read before the
        integration clears it). Zero for static and unscaled bodies."""
        var n = len(self.bset.bodies)
        var own = List[Real](length=n, fill=0)
        var glen = sqrt(dot(gravity, gravity))
        if glen == 0:
            return own^
        var up = gravity * (Real(-1) / glen)
        for i in range(n):
            if not self.bset.is_dynamic(i) or self.bset.cscale[i] >= 1:
                continue
            var m = Real(1) / self.bset.bodies[i].inv_mass()
            var mc = m / self.bset.cscale[i]
            var a = gravity + self.bset.force[i] * (Real(1) / m)
            own[i] = (mc - m) * (Real(0) - dot(a, up))
        return own^

    def _report_excess(mut self, mut pairs: List[ContactConstraint], own: List[Real], gravity: Vec3):
        """ROADMAP 17.19 A2: moves each scaled body's excess weight from the
        solved impulses into the report (`contacts_of`, `joint_reaction`);
        the solve itself is unchanged, so the default path and the golden are too.

        The support graph has one edge per contact pair and per scaled joint
        (`_scaled_linear`). An edge runs from its carrier to the body that holds
        it: the carrier is the dynamic side the other side pushes upward, decided
        by the sign of that upward impulse (not by height), and the edge weight
        is that upward impulse. A body's excess is its own (`_own_excess`) plus
        what its carriers sent it, and it leaves through its edges in proportion
        to their weights. Kahn's topological order visits every carrier before
        the body it rests on. A ring of bodies each holding the next up has no
        such order: the lowest unvisited dynamic body is then taken with the
        inflow it has so far. That break is arbitrary, not an exact split. A
        static holder takes its share and passes nothing on. Each edge records
        the upward force it carries (`pr.excess` / `jexcess`) and its carrier.
        Torques through joints are not corrected."""
        var n = len(self.bset.bodies)
        var glen = sqrt(dot(gravity, gravity))
        var up = Vec3(0, 0, 0, 0)
        if glen > 0:
            up = gravity * (Real(-1) / glen)
        # edge e: carrier esrc[e] holds edst[e] with weight ew[e]; eref[e] is the
        # pair index (>= 0) or -(joint index + 1)
        var esrc = List[Int]()
        var edst = List[Int]()
        var ew = List[Real]()
        var eref = List[Int]()
        for p in range(len(pairs)):
            ref pr = pairs[p]
            pr.excess = Vec3(0, 0, 0, 0)
            pr.excess_up = -1
            var jsup = Real(0)
            for q in range(pr.m.count):
                jsup += pr.jn[q]
            # the impulse on b is normal * jsup, on a its negative
            var s = dot(pr.m.normal, up) * jsup
            if s < 0 and self.bset.is_dynamic(pr.a):
                esrc.append(pr.a)
                edst.append(pr.b)
                ew.append(-s)
                eref.append(p)
            elif s > 0 and self.bset.is_dynamic(pr.b):
                esrc.append(pr.b)
                edst.append(pr.a)
                ew.append(s)
                eref.append(p)
        for j in range(len(self.joints)):
            ref jt = self.joints[j]
            self.jexcess[j] = Vec3(0, 0, 0, 0)
            self.jexcess_up[j] = -1
            if not _scaled_linear(jt.kind) or jt.kind == JOINT_BROKEN:
                continue
            if j >= len(self.jspan) or self.jspan[j] <= 0:
                continue
            # the joint's force on b; its force on a is the negative
            var sb = dot(self.jsum_f[j] / self.jspan[j], up)
            if sb > 0 and self.bset.is_dynamic(jt.b):
                esrc.append(jt.b)
                edst.append(jt.a)
                ew.append(sb)
                eref.append(-(j + 1))
            elif sb < 0 and self.bset.is_dynamic(jt.a):
                esrc.append(jt.a)
                edst.append(jt.b)
                ew.append(-sb)
                eref.append(-(j + 1))
        var ne = len(ew)
        var head = List[Int](length=n, fill=-1)
        var nxt = List[Int](length=ne, fill=-1)
        var wsum = List[Real](length=n, fill=0)
        var indeg = List[Int](length=n, fill=0)
        for e in range(ne):
            nxt[e] = head[esrc[e]]
            head[esrc[e]] = e
            wsum[esrc[e]] += ew[e]
            if self.bset.is_dynamic(edst[e]):
                indeg[edst[e]] += 1
        var ndyn = 0
        var queue = List[Int]()
        for i in range(n):
            if self.bset.is_dynamic(i):
                ndyn += 1
                if indeg[i] == 0:
                    queue.append(i)
        var done = List[Bool](length=n, fill=False)
        var inflow = List[Real](length=n, fill=0)
        var qh = 0
        var visited = 0
        while visited < ndyn:
            var u = -1
            while qh < len(queue) and u < 0:
                if not done[queue[qh]]:
                    u = queue[qh]
                qh += 1
            if u < 0:
                # a cycle: take the lowest unvisited body with the inflow it has
                for i in range(n):
                    if self.bset.is_dynamic(i) and not done[i]:
                        u = i
                        break
            done[u] = True
            visited += 1
            var t = own[u] + inflow[u]
            var e = head[u]
            while e >= 0:
                var lo = edst[e]
                var c = t * ew[e] / wsum[u]
                if c > 0:
                    if eref[e] >= 0:
                        ref pr = pairs[eref[e]]
                        pr.excess = up * c
                        pr.excess_up = u
                    else:
                        var j = -eref[e] - 1
                        self.jexcess[j] = up * c
                        self.jexcess_up[j] = u
                    if self.bset.is_dynamic(lo):
                        inflow[lo] += c
                if self.bset.is_dynamic(lo):
                    indeg[lo] -= 1
                    if indeg[lo] == 0 and not done[lo]:
                        queue.append(lo)
                e = nxt[e]

    def _contact_mass_scale(mut self, mut pairs: List[ContactConstraint], ratio: Real, impact_speed: Real):
        """ROADMAP 17.19 `max_mass_ratio`: dynamic bodies joined by a
        contact or a (core, unbroken) joint form groups (union-find); each
        body's mass in contact and joint rows is m_c = max(m, heaviest in
        its group / ratio) -- the load a body carries comes from the whole
        stack or chain above it, not only its neighbour. scale = m / m_c.
        Only touching contacts join groups (a speculative one carries no
        load: a bullet passing 0.2 m under a 1000 kg box joined its group
        through one), and a contact closing faster than `impact_speed` (the
        restitution threshold) does not either: scaling is for carried load, and a
        0.2 kg bullet that joined a 1000 kg box's group on impact hit as a
        100 kg one and drove a 1 kg box through the floor (measured,
        `test_solver_stress`).

        Warm-started impulses were sized for last step's scales. A body
        whose scale grew (it left a heavy group: the same bullet bouncing
        off) would take an impulse sized for 100 kg as 0.2 kg -- it reached
        2e4 m/s -- so a pair's cached impulses shrink by s_old / s_new of
        its body whose scale grew most; a scale that shrank keeps them
        (an under-warmed start only converges slower)."""
        var n = len(self.bset.bodies)
        var m = List[Real](length=n, fill=0)
        var parent = List[Int](capacity=n)
        for i in range(n):
            parent.append(i)
            if self.bset.is_dynamic(i):
                m[i] = Real(1) / self.bset.bodies[i].inv_mass()
        for ref pr in pairs:
            if self.bset.is_dynamic(pr.a) and self.bset.is_dynamic(pr.b):
                var impact = False
                var touching = False
                for k in range(pr.m.count):
                    if pr.vn0[k] < -impact_speed:
                        impact = True
                    if pr.m.depths[k] >= 0:
                        touching = True
                if touching and not impact:
                    _uf_union(parent, pr.a, pr.b)
        for ref jt in self.joints:
            if _scaled_linear(jt.kind) and self.bset.is_dynamic(jt.a) and self.bset.is_dynamic(jt.b):
                _uf_union(parent, jt.a, jt.b)
        var gmax = List[Real](length=n, fill=0)
        for i in range(n):
            var r = _uf_find(parent, i)
            gmax[r] = max(gmax[r], m[i])
        var prev = self.bset.cscale^
        self.bset.cscale = List[Real](length=n, fill=1)
        for i in range(n):
            var mc = max(m[i], gmax[_uf_find(parent, i)] / ratio)
            if mc > 0:
                self.bset.cscale[i] = m[i] / mc
        for ref pr in pairs:
            var f = Real(1)
            for side in range(2):
                var i = pr.a if side == 0 else pr.b
                var old = prev[i] if i < len(prev) else Real(1)
                if self.bset.cscale[i] > old:
                    f = min(f, old / self.bset.cscale[i])
            if f < 1:
                for k in range(pr.m.count):
                    pr.acc[k] *= f
                    pr.acc_t1[k] *= f
                    pr.acc_t2[k] *= f
        for ref jt in self.joints:
            if not _scaled_linear(jt.kind):
                continue
            var f = Real(1)
            for side in range(2):
                var i = jt.a if side == 0 else jt.b
                var old = prev[i] if i < len(prev) else Real(1)
                if self.bset.cscale[i] > old:
                    f = min(f, old / self.bset.cscale[i])
            if f < 1:
                jt.acc = jt.acc * f
                jt.acc_ang = jt.acc_ang * f

    def step(mut self, dt: Real, gravity: Vec3, cfg: SolverConfig):
        """`_step_impl` (the sub-stepped soft step, every path) wrapped by the
        ROADMAP 17.48 per-body pass: accumulated forces and damping before,
        speed caps and axis locks after. Only scenes that used a 17.48 setter
        (`bset.any_props`) pay for either pass."""
        if self.bset.any_props:
            self._props_pre(dt)
        if len(self.kin_mesh) > 0:
            try:
                self._refresh_kinematic_meshes()
            except:
                pass  # rebuilding a mesh that was valid at add cannot raise
        self._step_impl(dt, gravity, cfg)
        if self.bset.any_props:
            self._props_post()
        if len(self.kin_mesh) > 0:
            try:
                self._refresh_kinematic_meshes()
            except:
                pass
        # ROADMAP 17.80: spans the trace could not keep go to the shared counters
        var tdrop = self.trace.take_dropped()
        if tdrop > 0:
            self.counters.incr(TRACE_DROPPED, Int64(tdrop))

    def _step_impl(mut self, dt: Real, gravity: Vec3, cfg: SolverConfig):
        """Sub-stepped soft-constraint step (Box2D v3 "Soft Step" scheme).

        Collide once, then per substep integrate velocities, solve with soft
        bias, integrate poses, and RELAX (bias-free sweep) so the bias energy
        never becomes bounce. (Overloaded with the legacy one-shot `step(dt,
        gravity, iters: Int = 8)` above -- the two are disambiguated by the
        3rd argument's type/arity, never both callable with the same args.)

        `cfg.parallel=True` solves ISLANDS on worker threads (scenes without
        soft bodies and without ccd): islands are disjoint by construction,
        so the result is bit-identical to the serial path
        (`test_islands_par`). When `cfg.parallel=True` but soft bodies, ccd,
        or colored solving are also requested, this silently falls back to
        the serial path below (audit F23) -- counted in
        `self.counters[PARALLEL_FALLBACK_SERIAL]` rather than staying
        invisible.

        `cfg.workers` pins the fan-out width (0 = let the runtime use every
        core). Because the partition — islands, or a color's pairs — is what
        makes the writes disjoint, the worker count changes only the
        SCHEDULE, never the result: any `workers` is bit-identical to serial.
        That invariance is what makes a core-scaling sweep (`bench_islands`,
        `bench_colored`) a fair measurement rather than a different
        computation per point.

        `step`/`step_soft` stay non-raising (ROADMAP 17.0h / audit E5): with
        ~100 call sites, making either `raises` would force every caller (and
        every caller of those) to become `raises` too. Instead this
        `debug_assert`s the same invariants `SolverConfig.validated()`
        checks -- zero cost in a release build, terminates loudly under
        `-D ASSERT=all` (every test run) if a config or `dt` slipped through
        with a value that would otherwise divide out to `inf`/`NaN` below."""
        self.max_push = cfg.max_push_speed
        self.impulse_estimator = cfg.impulse_estimator
        self.bset.cone = cfg.friction_cone
        self.bset.block = cfg.contact_solver == CONTACT_BLOCK
        self.colliders.reduce_mesh = cfg.reduce_mesh_contacts
        self._reset_joint_sums()
        debug_assert(cfg.substeps >= 1, "ContactScene6.step: cfg.substeps must be >= 1")
        debug_assert(cfg.iters >= 1, "ContactScene6.step: cfg.iters must be >= 1")
        debug_assert(cfg.hertz > 0, "ContactScene6.step: cfg.hertz must be > 0")
        debug_assert(cfg.zeta >= 0, "ContactScene6.step: cfg.zeta must be >= 0")
        debug_assert(dt > 0, "ContactScene6.step: dt must be > 0")
        var substeps = cfg.substeps
        var iters = cfg.iters
        var hertz = cfg.hertz
        var zeta = cfg.zeta
        var mu = cfg.default_friction
        var ccd = cfg.ccd or self.bset.any_bullet
        var parallel = cfg.parallel
        var colored = cfg.colored
        var broadphase = cfg.broadphase
        var workers = cfg.workers
        var h = dt / Real(substeps)
        var omega = Real(6.283185307179586) * hertz
        var c = h * omega * (2 * zeta + h * omega)
        var bias_rate = omega / (2 * zeta + h * omega)
        var mass_scale = c / (1 + c)
        var impulse_scale = 1 / (1 + c)
        # "collect_pairs" covers both broadphase candidate enumeration and
        # narrowphase manifold generation -- `_collect_pairs` (collision
        # .contact_gen) does both in one pass, so there is no seam to split
        # a separate "narrowphase" span at without restructuring that
        # function; the spec's phase list treats them as one unit here.
        self.trace.begin("collect_pairs")
        var pairs = self._collect_pairs(
            True, dt, broadphase, cfg.margin_base, cfg.parallel_collision, workers, cfg.dispatch,
            cfg.reuse_still_pairs,
        )
        if cfg.max_contacts > 0 and len(pairs) > cfg.max_contacts:
            self.counters.incr(CONTACT_DROPPED, Int64(len(pairs) - cfg.max_contacts))
            while len(pairs) > cfg.max_contacts:
                _ = pairs.pop()
        self.trace.end()
        self.bset.mass_ratio = cfg.max_mass_ratio
        var own = List[Real]()
        if cfg.max_mass_ratio > 0:
            self._contact_mass_scale(pairs, cfg.max_mass_ratio, cfg.restitution_threshold)
            own = self._own_excess(gravity)
        # ROADMAP 17.80: counter tracks (no-op unless traced and enabled)
        self.trace.sample("contact_manifolds", len(pairs))
        self.trace.sample("bodies", len(self.bset.bodies))
        self.trace.begin("islands")
        refresh_islands(self.bset, self._constraint_edges(pairs), len(pairs))
        self.trace.end()
        # graph coloring (colored=True): greedy smallest-free-color over the
        # DYNAMIC-body adjacency (a shared static must not chain colors, or
        # one ground plane serialises the whole scene); pairs reordered into
        # contiguous per-color ranges. <= 64 colors (bit masks).
        var clo = List[Int]()
        var chi = List[Int]()
        if colored:
            colored = self._color_pairs(pairs, clo, chi)
        var tiered = len(self.tier_period) > 0
        if tiered and (colored or len(self.softs) > 0 or ccd or len(self.drives) > 0 or self.any_break):
            self.counters.incr(TIER_FALLBACK)
            tiered = False
        if tiered:
            self.trace.begin("solve")
            var pairs2 = self._step_tiered(pairs, dt, gravity, cfg)
            self.trace.end()
            self.trace.begin("sleep")
            update_sleep(self.bset, dt, cfg)
            self.trace.end()
            self.trace.begin("nan_scan")
            self._quarantine_nonfinite()
            self.trace.end()
            comptime if DEBUG_DRAW_ON:
                self._emit_debug_draw(pairs2)
            if self.events_on:
                self._emit_events(pairs2)
            self._release_overloaded()
            self.cache = pairs2^
            self.step_index += 1
            return
        if parallel and (colored or len(self.softs) > 0 or len(self.drives) > 0 or self.any_break):
            # F23: the island-parallel path assumes no soft bodies, no ccd
            # and no colored solving; falling back is correct but used to be
            # silent -- count it so a caller relying on the parallel path
            # can notice it never actually ran in parallel.
            self.counters.incr(PARALLEL_FALLBACK_SERIAL)
        if parallel and not colored and len(self.softs) == 0 and len(self.drives) == 0 and not self.any_break:
            # partition: pairs reordered so each island is a contiguous range
            var labels = List[Int]()
            var first = List[Int]()
            var pairs2 = List[ContactConstraint]()
            var plo = List[Int]()
            var members = List[Int]()
            var mstart = List[Int]()
            self._island_partition(pairs, labels, first, pairs2, plo, members, mstart)
            var phi = List[Int]()
            for k in range(len(labels)):
                phi.append(plo[k + 1])
            self.trace.begin("solve")
            _solve_islands_parallel(
                self, pairs2, plo, phi, labels, gravity, h,
                substeps, iters, bias_rate, mass_scale, impulse_scale, mu,
                members, mstart, workers, cfg.restitution_threshold, cfg.dispatch, ccd, cfg.ccd,
            )
            self.trace.end()
            self.trace.begin("sleep")
            update_sleep(self.bset, dt, cfg)
            self.trace.end()
            self.trace.begin("nan_scan")
            self._quarantine_nonfinite()
            self.trace.end()
            comptime if DEBUG_DRAW_ON:
                self._emit_debug_draw(pairs2)
            if self.events_on:
                self._emit_events(pairs2)
            self._release_overloaded()
            self.cache = pairs2^
            self.step_index += 1
            return
        # ROADMAP 17.0i: ONE "solve" span for the WHOLE substep loop, not one
        # begin/end pair per phase per substep. Measured overhead was ~20% at
        # N=512 (bench_solver_scale table 4) from ~23 span pairs/step (5
        # phases -- warm_start/solve/integrate-or-ccd/soft_pass/relax-solve
        # -- times the default 4 substeps, plus collect_pairs/sleep/
        # nan_scan); `TraceBuffer.begin`/`end` each pay a `perf_counter_ns`
        # call, a `List` push/pop, and a `String` copy of the span name even
        # though `-D LUDENS_TRACE` compiles the CALL away when off (the cost
        # measured is the traced-build cost) -- coarsening to one span per
        # phase per STEP amortizes that fixed cost over the whole step
        # instead of over each substep, without losing what a caller can
        # still ask `sc.trace.stats()` for (`test_error_wiring.mojo` and
        # `bench_solver_scale`'s table 4 only ever check for "solve",
        # "collect_pairs", "sleep", "nan_scan" by name -- never
        # "warm_start"/"integrate"/"soft_pass", which were never part of
        # either's contract). The five phases below stay in their original
        # per-substep INTERLEAVED order (warm start -> solve -> integrate ->
        # soft pass -> relax, repeated `substeps` times) -- only the tracing
        # granularity changes, not the algorithm.
        self.trace.begin("solve")
        for sub in range(substeps):
            # gravity: dynamic + awake only. `not _inactive(i)` alone would
            # also admit a kinematic body (never static, never sleeping) --
            # ROADMAP 17.24 says gravity must NOT reach it, so this gate is
            # tighter than the pose-integration one just below.
            for i in range(len(self.bset.bodies)):
                if self.bset.is_dynamic(i) and not self.bset.sleeping[i]:
                    var f = self.bset.gravity_for(i, gravity) / self.bset.bodies[i].inv_mass()
                    self.bset.bodies[i].integrate_force(h, f, Vec3(0, 0, 0, 0))
            # Warm start: re-apply accumulated impulses; the soft solve's
            # -impulseScale·acc decay is the matching counter-term.
            warm_start_contacts(self.bset, pairs, 0, len(pairs))
            warm_start_joints(self.bset, self.joints, -2)
            if self.any_ext:
                warm_start_ext(self.bset, self.joints, self.jext, -2)
            if len(self.drives) > 0:
                warm_start_drives(self.bset, self.drives)
            joint_sweep(
                self.bset, self.joints, h, bias_rate, mass_scale, impulse_scale, True, iters, -2
            )
            if self.any_ext:
                ext_sweep(self.bset, self.joints, self.jext, h, bias_rate, mass_scale, impulse_scale, True, iters, -2)
            if len(self.drives) > 0:
                drive_sweep(self.bset, self.drives, h, iters)
            if colored:
                sweep_colored(
                    self.bset, pairs, clo, chi, h, bias_rate, mass_scale,
                    impulse_scale, True, iters, mu, parallel, workers, cfg.dispatch, cfg.max_push_speed,
                )
            else:
                soft_sweep(
                self.bset, pairs, 0, len(pairs), h, bias_rate, mass_scale,
                    impulse_scale, True, iters, mu, cfg.max_push_speed,
                )
            if ccd:
                ccd_advance(self.bset, self.colliders, h, cfg.ccd, cfg.parallel_collision, cfg.workers, cfg.dispatch)
            else:
                for i in range(len(self.bset.bodies)):
                    if not self.bset.inactive(i):
                        if self.bset.any_props and self.bset.locks[i] != 0:
                            self._apply_locks(i)
                        self.bset.bodies[i].integrate_pose(h)
            # soft bodies: XPBD lattice + particle-vs-body coupling, at the
            # substep's POST-integration poses (rigid impulses land next substep)
            softbody_pass(self.softs, self.bset, self.colliders, h, gravity, iters, ccd, self.step_index)
            # relax: remove the bias energy (velocity-only, no bias)
            joint_sweep(self.bset, self.joints, h, bias_rate, 1, 0, False, 2, -2)
            if self.any_ext:
                ext_sweep(self.bset, self.joints, self.jext, h, bias_rate, 1, 0, False, 2, -2)
            if colored:
                sweep_colored(
                    self.bset, pairs, clo, chi, h, bias_rate, 1, 0, False, 2, mu,
                    parallel, workers, cfg.dispatch,
                )
            else:
                soft_sweep(
                self.bset, pairs, 0, len(pairs), h, bias_rate, 1, 0, False, 2, mu
                )
            if self.any_break:
                sample_loads(self.joints, h, self.peak_force, self.peak_torque)
                if self.any_ext:
                    sample_ext_loads(self.bset, self.joints, self.jext, h, self.peak_force, self.peak_torque)
            self._report_substep(pairs, 0, len(pairs), -2, sub, substeps, h)
        self.trace.end()
        restitution_pass(self.bset, pairs, 0, len(pairs), 4, cfg.restitution_threshold)
        add_restitution_impulse(self.bset, pairs, 0, len(pairs))
        self.trace.begin("sleep")
        update_sleep(self.bset, dt, cfg)
        self.trace.end()
        self.trace.begin("nan_scan")
        self._quarantine_nonfinite()
        self.trace.end()
        if cfg.max_mass_ratio > 0:
            self._report_excess(pairs, own, gravity)
        self._hold_loads(pairs)
        comptime if DEBUG_DRAW_ON:
            self._emit_debug_draw(pairs)
        if self.events_on:
            self._emit_events(pairs)
        self._release_overloaded()
        self.cache = pairs^  # impulses persist to the next frame
        self.step_index += 1

    def _island_partition(
        self,
        pairs: List[ContactConstraint],
        mut labels: List[Int],
        mut first: List[Int],
        mut pairs2: List[ContactConstraint],
        mut plo: List[Int],
        mut members: List[Int],
        mut mstart: List[Int],
    ):
        """Islands in first-seen slot order (`labels`, each island's first
        slot in `first`); pairs regrouped per island into contiguous ranges
        `plo[k]..plo[k+1]` keeping their order (stable counting sort); island
        members per island in ascending slot order (`mstart`). O(bodies +
        pairs) -- replaced the O(pairs x islands) filter loop and the
        O(bodies x islands) `island_labels` the island-parallel path used;
        the result (order included) is the same."""
        var n = len(self.bset.bodies)
        var ordinal = List[Int](length=n, fill=-1)
        for i in range(n):
            var l = self.bset.island[i] if i < len(self.bset.island) else -1
            if l >= 0 and ordinal[l] < 0:
                ordinal[l] = len(labels)
                labels.append(l)
                first.append(i)
        var k = len(labels)
        mstart = List[Int](length=k + 1, fill=0)
        for i in range(n):
            var l = self.bset.island[i] if i < len(self.bset.island) else -1
            if l >= 0:
                mstart[ordinal[l] + 1] += 1
        for o in range(k):
            mstart[o + 1] += mstart[o]
        var mfill = mstart.copy()
        members = List[Int](length=mstart[k], fill=-1)
        for i in range(n):
            var l = self.bset.island[i] if i < len(self.bset.island) else -1
            if l >= 0:
                members[mfill[ordinal[l]]] = i
                mfill[ordinal[l]] += 1
        plo = List[Int](length=k + 1, fill=0)
        var pl = List[Int](length=len(pairs), fill=-1)
        for pc in range(len(pairs)):
            var l = contact_island(self.bset, pairs[pc])
            if l >= 0 and ordinal[l] >= 0:
                pl[pc] = ordinal[l]
                plo[ordinal[l] + 1] += 1
        for o in range(k):
            plo[o + 1] += plo[o]
        var fill = plo.copy()
        var order = List[Int](length=plo[k], fill=-1)
        for pc in range(len(pairs)):
            if pl[pc] >= 0:
                order[fill[pl[pc]]] = pc
                fill[pl[pc]] += 1
        pairs2 = List[ContactConstraint](capacity=plo[k])
        for j in range(len(order)):
            pairs2.append(pairs[order[j]])

    def _step_tiered(
        mut self, pairs: List[ContactConstraint], dt: Real, gravity: Vec3, cfg: SolverConfig
    ) -> List[ContactConstraint]:
        """ROADMAP 17.85: solve island by island at each island's tier.

        An island's tier is the finest (lowest) tier of its members, so a
        coarse body touched by a fine one is solved finely (the merge rule).
        Its phase is its first member's slot index: island k of tier t is
        due when `(step_index + first) % period[t] == 0`, which spreads the
        islands of one tier evenly over the period. A due island runs the
        same per-island substep loop as the island-parallel path
        (`_solve_island`) with its tier's iters / substeps over
        `period * dt` (catch-up: no simulated time is lost); an off-phase or
        period-0 island is not touched, its contacts keep their accumulated
        impulses for the next warm start.

        O(bodies + pairs): labels by first sight, pairs partitioned by a
        counting sort (stable, so each island's pair order is the order the
        serial path sees). With every body at tier 0 and tier 0 = the
        step's config, this is exactly the island-parallel path run serially,
        which `test_islands_par` pins bit-identical to the serial step."""
        var labels = List[Int]()
        var first = List[Int]()
        var pairs2 = List[ContactConstraint]()
        var plo = List[Int]()
        var members = List[Int]()
        var mcnt = List[Int]()
        self._island_partition(pairs, labels, first, pairs2, plo, members, mcnt)
        var k = len(labels)
        var itier = List[Int](length=k, fill=0)
        for o in range(k):
            var t = self.body_tier(members[mcnt[o]])
            for m in range(mcnt[o] + 1, mcnt[o + 1]):
                t = min(t, self.body_tier(members[m]))
            itier[o] = t
        self.islands_solved = 0
        self.islands_skipped = 0
        for o in range(k):
            var t = itier[o]
            var period = self.tier_period[t]
            if period == 0 or (self.step_index + first[o]) % period != 0:
                self.islands_skipped += 1
                continue
            self.islands_solved += 1
            var substeps = self.tier_substeps[t]
            var h = dt * Real(period) / Real(substeps)
            var omega = Real(6.283185307179586) * cfg.hertz
            var c = h * omega * (2 * cfg.zeta + h * omega)
            var bias_rate = omega / (2 * cfg.zeta + h * omega)
            var mass_scale = c / (1 + c)
            var impulse_scale = 1 / (1 + c)
            self._solve_island(
                pairs2, plo[o], plo[o + 1], labels[o], gravity, h,
                substeps, self.tier_iters[t], bias_rate, mass_scale, impulse_scale,
                cfg.default_friction, members, mcnt[o], mcnt[o + 1], cfg.restitution_threshold,
            )
        return pairs2^


comptime _RAY_CHUNK = 64


struct _RayTask(Task):
    """A chunk of rays per item, each written to its own slot of `out`
    (17.53)."""

    var cs: Pointer[ColliderSet, ImmUntrackedOrigin]
    var idx: Pointer[QueryIndex, ImmUntrackedOrigin]
    var origins: Pointer[List[Vec3], ImmUntrackedOrigin]
    var dirs: Pointer[List[Vec3], ImmUntrackedOrigin]
    var out: Pointer[List[Hit], MutUntrackedOrigin]
    var max_t: Real
    var f: QueryFilter

    def __init__(
        out self, cs: ColliderSet, idx: QueryIndex, origins: List[Vec3], dirs: List[Vec3],
        mut out: List[Hit], max_t: Real, f: QueryFilter,
    ):
        self.cs = Pointer(to=cs).unsafe_origin_cast[ImmUntrackedOrigin]()
        self.idx = Pointer(to=idx).unsafe_origin_cast[ImmUntrackedOrigin]()
        self.origins = Pointer(to=origins).unsafe_origin_cast[ImmUntrackedOrigin]()
        self.dirs = Pointer(to=dirs).unsafe_origin_cast[ImmUntrackedOrigin]()
        self.out = Pointer(to=out).unsafe_origin_cast[MutUntrackedOrigin]()
        self.max_t = max_t
        self.f = f

    def run(self, c: Int):
        # one item = a chunk of _RAY_CHUNK rays: a single ray is ~2 us of
        # work, less than handing it to a worker costs
        var lo = c * _RAY_CHUNK
        var hi = min(lo + _RAY_CHUNK, len(self.origins[]))
        for i in range(lo, hi):
            self.out[][i] = wq_ray_cast_indexed(
                self.cs[], self.idx[], self.origins[][i], self.dirs[][i], self.max_t, self.f
            )


struct _IslandTask[BB: Body6, PBP: BroadPhase](Task):
    """One island per item: islands write disjoint bodies and pairs."""

    var scene: Pointer[ContactScene6[Self.BB, Self.PBP], MutUntrackedOrigin]
    var pairs2: Pointer[List[ContactConstraint], MutUntrackedOrigin]
    var plo: Pointer[List[Int], MutUntrackedOrigin]
    var phi: Pointer[List[Int], MutUntrackedOrigin]
    var labels: Pointer[List[Int], MutUntrackedOrigin]
    var members: Pointer[List[Int], MutUntrackedOrigin]
    var mstart: Pointer[List[Int], MutUntrackedOrigin]
    var gravity: Vec3
    var h: Real
    var substeps: Int
    var iters: Int
    var bias_rate: Real
    var mass_scale: Real
    var impulse_scale: Real
    var mu: Real
    var rest_threshold: Real
    var ccd: Bool
    var ccd_all: Bool
    var times: Pointer[List[Int], MutUntrackedOrigin]  # [2k] start, [2k + 1] end per island (17.80 (c))
    var timed: Bool

    def __init__(
        out self,
        mut scene: ContactScene6[Self.BB, Self.PBP],
        mut pairs2: List[ContactConstraint],
        mut plo: List[Int],
        mut phi: List[Int],
        mut labels: List[Int],
        mut members: List[Int],
        mut mstart: List[Int],
        gravity: Vec3, h: Real, substeps: Int, iters: Int, bias_rate: Real,
        mass_scale: Real, impulse_scale: Real, mu: Real, rest_threshold: Real,
        mut times: List[Int], timed: Bool,
        ccd: Bool = False, ccd_all: Bool = False,
    ):
        self.scene = Pointer(to=scene).unsafe_origin_cast[MutUntrackedOrigin]()
        self.times = Pointer(to=times).unsafe_origin_cast[MutUntrackedOrigin]()
        self.timed = timed
        self.ccd = ccd
        self.ccd_all = ccd_all
        self.pairs2 = Pointer(to=pairs2).unsafe_origin_cast[MutUntrackedOrigin]()
        self.plo = Pointer(to=plo).unsafe_origin_cast[MutUntrackedOrigin]()
        self.phi = Pointer(to=phi).unsafe_origin_cast[MutUntrackedOrigin]()
        self.labels = Pointer(to=labels).unsafe_origin_cast[MutUntrackedOrigin]()
        self.members = Pointer(to=members).unsafe_origin_cast[MutUntrackedOrigin]()
        self.mstart = Pointer(to=mstart).unsafe_origin_cast[MutUntrackedOrigin]()
        self.gravity = gravity
        self.h = h
        self.substeps = substeps
        self.iters = iters
        self.bias_rate = bias_rate
        self.mass_scale = mass_scale
        self.impulse_scale = impulse_scale
        self.mu = mu
        self.rest_threshold = rest_threshold

    def run(self, k: Int):
        if self.timed:
            self.times[][2 * k] = Int(perf_counter_ns())
        self.scene[]._solve_island(
            self.pairs2[], self.plo[][k], self.phi[][k], self.labels[][k], self.gravity, self.h,
            self.substeps, self.iters, self.bias_rate, self.mass_scale, self.impulse_scale, self.mu,
            self.members[], self.mstart[][k], self.mstart[][k + 1], self.rest_threshold,
            self.ccd, self.ccd_all,
        )
        if self.timed:
            self.times[][2 * k + 1] = Int(perf_counter_ns())


def _solve_islands_parallel[BB: Body6, PBP: BroadPhase](
    mut scene: ContactScene6[BB, PBP],
    mut pairs2: List[ContactConstraint],
    mut plo: List[Int],
    mut phi: List[Int],
    mut labels: List[Int],
    gravity: Vec3,
    h: Real,
    substeps: Int,
    iters: Int,
    bias_rate: Real,
    mass_scale: Real,
    impulse_scale: Real,
    mu: Real,
    mut members: List[Int],
    mut mstart: List[Int],
    workers: Int = 0,
    rest_threshold: Real = 1.0,
    dispatch: Dispatch = Dispatch.parallel(),
    ccd: Bool = False,
    ccd_all: Bool = False,
):
    """Worker fan-out for `step(cfg.parallel=True)`: one `_IslandTask` item
    per island, run by `dispatch` (ROADMAP 17.75: the runtime pool, serial,
    reversed, or a host job system). Islands write disjoint bodies/pairs, so
    the result is bit-identical to serial whatever runs the items
    (`test_islands_par`, `test_dispatch`). `workers <= 0` lets the runtime
    pick the width of the default pool."""
    # ROADMAP 17.80 (c): with tracing on, each island records its own
    # start / end (disjoint slots) and the islands become worker tracks
    var timed = False
    comptime if TRACE_ON:
        timed = scene.trace.enabled
    var times = List[Int](length=2 * len(labels) if timed else 0, fill=0)
    var task = _IslandTask[BB, PBP](
        scene, pairs2, plo, phi, labels, members, mstart, gravity, h, substeps,
        iters, bias_rate, mass_scale, impulse_scale, mu, rest_threshold, times, timed, ccd, ccd_all,
    )
    dispatch_for(dispatch, task, len(labels), workers)
    if timed:
        var t0 = List[Int](capacity=len(labels))
        var t1 = List[Int](capacity=len(labels))
        for k in range(len(labels)):
            t0.append(times[2 * k])
            t1.append(times[2 * k + 1])
        _ = scene.trace.add_lanes("island", t0, t1)
    _ = len(times)  # keep `times` alive past the fan-out (untracked pointer)


def write_state[W: StateWriter](sc: ContactScene6[QuatBody6], mut out: W):
    """Full snapshot of everything dynamical (audit F5/F20): rigid body
    state, the per-collider payload each shape kind needs to reconstruct
    (`ColliderSet`'s side tables), joints, soft bodies, the cross-frame
    warm-start cache, and -- new in this commit -- the contact-event
    stream's own state (`events_on`, `_prev_keys`). Previously omitted, so
    `_emit_events`'s `diff_events` compared this step's contacts against an
    EMPTY `_prev_keys` right after a load and reported a spurious `began`
    event for every contact that was already live before the save (F20).

    A free function, not a `ContactScene6` method: the wire format reads
    QuatBody6-specific raw fields (`q`, `omega`, `inertia`) that the
    representation-agnostic `Body6` trait deliberately does not expose (a
    `ScrewBody6` has no quaternion), so this is scoped to
    `ContactScene6[QuatBody6]` exactly the way `physics/serialize.mojo`'s
    public API already was before this commit. `out: StateWriter` decides
    HOW each field is encoded; this function decides only WHICH fields and
    in what order (`physics/state_io.mojo`'s docstring)."""
    out.wi(len(sc.bset.bodies))
    for i in range(len(sc.bset.bodies)):
        var b = sc.bset.bodies[i]
        out.wv(b.pos)
        out.wf(b.q.x)
        out.wf(b.q.y)
        out.wf(b.q.z)
        out.wf(b.q.w)
        out.wv(b.vel)
        out.wv(b.omega)
        out.wf(b.inertia.mass)
        out.wf(b.inertia.ix)
        out.wf(b.inertia.iy)
        out.wf(b.inertia.iz)
        out.wv(sc.colliders.half[i])
        out.wi(1 if sc.bset.is_static(i) else 0)
        out.wi(sc.colliders.shape[i])
        out.wf(sc.bset.restitution[i])
        out.wi(1 if sc.bset.sleeping[i] else 0)
        out.wf(sc.bset.sleep_timer[i])
        out.wi(Int(sc.colliders.category[i]))
        out.wi(Int(sc.colliders.mask[i]))
        out.wi(1 if sc.colliders.sensor[i] else 0)
        # ROADMAP 17.0g-2 additions (17.23 materials, 17.24 kinematic, 17.25
        # can-sleep): appended here, AFTER the pre-existing `is_static` bit
        # above rather than replacing it, so a pre-17.0g-2 field's ENCODED
        # VALUE for every existing body is untouched -- only the blob grows
        # (the identity gate's explicitly allowed exception). `motion` is
        # the field `read_state` actually reconstructs from now on (the old
        # `is_static` bit alone cannot distinguish DYNAMIC from KINEMATIC);
        # it is kept in the stream for its position's own stability, not
        # read back.
        out.wi(sc.bset.motion[i])
        out.wf(sc.bset.friction[i])
        out.wi(sc.bset.friction_combine[i])
        out.wi(sc.bset.restitution_combine[i])
        out.wi(1 if sc.bset.can_sleep[i] else 0)
        # Shape payload for the kinds that keep their geometry in a side
        # table -- a snapshot that restored a hull body without its
        # vertices would load cleanly and then index an empty table on the
        # next contact, so the geometry travels with the body even though a
        # level mesh can be large: this format is a full state snapshot,
        # not an asset reference.
        match sc.colliders.shape[i]:
            case == SHAPE_HULL:
                ref hl = sc.colliders.hulls[sc.colliders.hull_id[i]]
                out.wi(len(hl.v))
                for k in range(len(hl.v)):
                    out.wf(hl.v[k])
            case == SHAPE_TRIMESH:
                ref ms = sc.colliders.meshes[sc.colliders.mesh_id[i]]
                out.wi(len(ms.v))
                for k in range(len(ms.v)):
                    out.wf(ms.v[k])
                out.wi(len(ms.idx))
                for k in range(len(ms.idx)):
                    out.wi(ms.idx[k])
            case == SHAPE_HEIGHTFIELD:
                ref hf = sc.colliders.fields[sc.colliders.mesh_id[i]]
                out.wi(hf.nx)
                out.wi(hf.nz)
                out.wf(hf.cell)
                out.wf(hf.ox)
                out.wf(hf.oz)
                out.wi(len(hf.h))
                for k in range(len(hf.h)):
                    out.wf(hf.h[k])
            case == SHAPE_SDF:
                ref sg = sc.colliders.sdfs[sc.colliders.mesh_id[i]]
                out.wi(sg.res)
                out.wv(sg.origin)
                out.wf(sg.cell)
                for k in range(len(sg.values)):
                    out.wf(sg.values[k])
            case == SHAPE_COMPOUND:
                # 17.44: every child (kind, size, local pose, hull vertices)
                var cid = sc.colliders.mesh_id[i]
                var f0 = sc.colliders.comp_first[cid]
                var nk = sc.colliders.comp_n[cid]
                out.wi(nk)
                for k in range(nk):
                    var d = sc.colliders.kid_desc[f0 + k]
                    var q = sc.colliders.kid_rot[f0 + k]
                    out.wi(d.kind)
                    out.wv(d.half)
                    out.wv(sc.colliders.kid_pos[f0 + k])
                    out.wf(q.x)
                    out.wf(q.y)
                    out.wf(q.z)
                    out.wf(q.w)
                    if d.kind == SHAPE_HULL:
                        ref kh = sc.colliders.hulls[d.hid]
                        out.wi(len(kh.v))
                        for v in range(len(kh.v)):
                            out.wf(kh.v[v])
    out.wi(len(sc.joints))
    for j in range(len(sc.joints)):
        var jt = sc.joints[j]
        out.wi(jt.kind)
        out.wi(jt.a)
        out.wi(jt.b)
        out.wv(jt.la)
        out.wv(jt.lb)
        out.wf(jt.rest)
        out.wv(jt.axis_a)
        out.wv(jt.axis_b)
        out.wv(jt.acc)
        out.wv(jt.acc_ang)
        out.wf(jt.ratio)
    out.wi(len(sc.softs))
    for k in range(len(sc.softs)):
        out.wf(sc.softs[k].alpha)
        out.wf(sc.softs[k].radius)
        out.wf(sc.softs[k].damp)
        out.wf(sc.softs[k].mu)
        out.wi(sc.softs[k].period)
        out.wi(sc.softs[k].phase)
        out.wi(len(sc.softs[k].pts))
        for p in range(len(sc.softs[k].pts)):
            var pt = sc.softs[k].pts[p]
            out.wv(pt.x)
            out.wv(pt.v)
            out.wf(pt.w)
        out.wi(len(sc.softs[k].edges))
        for e in range(len(sc.softs[k].edges)):
            var ed = sc.softs[k].edges[e]
            out.wi(ed.a)
            out.wi(ed.b)
            out.wf(ed.rest)
            out.wf(ed.lam)
    out.wi(len(sc.cache))
    for c in range(len(sc.cache)):
        var pr = sc.cache[c]
        out.wi(pr.a)
        out.wi(pr.b)
        out.wi(pr.feat)  # triangle index for mesh contacts, 0 otherwise
        out.wi(1 if pr.m.hit else 0)
        out.wv(pr.m.normal)
        out.wi(pr.m.count)
        for p in range(4):
            out.wv(pr.m.points[p])
            out.wf(pr.m.depths[p])
            out.wf(pr.acc[p])
            out.wf(pr.acc_t1[p])
            out.wf(pr.acc_t2[p])
            out.wv(pr.ra[p])
            out.wv(pr.rb[p])
            out.wf(pr.vn0[p])
            out.wf(pr.racc[p])
            out.wf(pr.hold_jn[p])
        # 17.19 (5): the held report load (`ContactConstraint.hold_*`), so a
        # loaded sleeping pair keeps reporting its resting load
        out.wv(pr.hold_jf)
        out.wf(pr.hold_span)
        out.wv(pr.hold_excess)
        out.wi(pr.hold_excess_up)
    # F20: the event stream's own state, so a resumed scene's events
    # continue identically instead of restarting from an empty history.
    out.wi(1 if sc.events_on else 0)
    out.wi(len(sc._prev_keys))
    for k in range(len(sc._prev_keys)):
        out.wi(sc._prev_keys[k])
    # ROADMAP 17.85: the tier phase clock, table and plan, so a resumed scene
    # solves the same islands on the same steps.
    out.wi(sc.step_index)
    out.wi(len(sc.tier_period))
    for t in range(len(sc.tier_period)):
        out.wi(sc.tier_iters[t])
        out.wi(sc.tier_substeps[t])
        out.wi(sc.tier_period[t])
    out.wi(len(sc.tier_of))
    for i in range(len(sc.tier_of)):
        out.wi(sc.tier_of[i])
    # ROADMAP 17.16: island labels. `wake` / `teleport` wake a body's whole
    # island by label; without them a restored scene read every label as
    # unknown and woke every sleeping body instead of one island, so a
    # rollback re-simulation diverged from the original run at the first
    # wake after a load.
    out.wi(len(sc.bset.island))
    for i in range(len(sc.bset.island)):
        out.wi(sc.bset.island[i])
    # ROADMAP 17.48 (format 4): per-body parameters, plus the per-body
    # state earlier items added without a snapshot slot -- 17.29 gravity
    # override (`grav_on`, `grav`), 17.31 frozen motion type -- and 17.45's
    # active-edge flags of each triangle mesh. Each block is preceded by a
    # presence flag and written only when the scene uses it, so a scene that
    # never touched these grows by four tokens (netcode deltas included).
    out.wi(1 if sc.bset.any_grav else 0)
    if sc.bset.any_grav:
        for i in range(len(sc.bset.bodies)):
            out.wi(1 if sc.bset.grav_on[i] else 0)
            out.wv(sc.bset.grav[i])
    var any_frozen = False
    for i in range(len(sc.bset.bodies)):
        if sc.bset.frozen_motion[i] >= 0:
            any_frozen = True
    out.wi(1 if any_frozen else 0)
    if any_frozen:
        for i in range(len(sc.bset.bodies)):
            out.wi(sc.bset.frozen_motion[i])
    out.wi(1 if sc.bset.any_props else 0)
    if sc.bset.any_props:
        for i in range(len(sc.bset.bodies)):
            out.wf(sc.bset.lin_damping[i])
            out.wf(sc.bset.ang_damping[i])
            out.wf(sc.bset.gravity_scale[i])
            out.wi(sc.bset.locks[i])
            out.wf(sc.bset.max_lin[i])
            out.wf(sc.bset.max_ang[i])
            out.wv(sc.bset.force[i])
            out.wv(sc.bset.torque[i])
            out.wf(sc.bset.sleep_lin[i])
            out.wf(sc.bset.sleep_ang[i])
    var flagged = List[Int]()  # mesh bodies whose flags are not all-active
    for i in range(len(sc.bset.bodies)):
        if sc.colliders.shape[i] == SHAPE_TRIMESH:
            ref ms = sc.colliders.meshes[sc.colliders.mesh_id[i]]
            for t in range(len(ms.active)):
                if ms.active[t] != 7:
                    flagged.append(i)
                    break
    out.wi(len(flagged))
    for k in range(len(flagged)):
        ref ms = sc.colliders.meshes[sc.colliders.mesh_id[flagged[k]]]
        out.wi(flagged[k])
        for t in range(len(ms.active)):
            out.wi(Int(ms.active[t]))
    # 17.29 joint break thresholds (load peaks are per-step transients,
    # reset after every break check) and 17.2 angular drives.
    out.wi(1 if sc.any_break else 0)
    if sc.any_break:
        for j in range(len(sc.joints)):
            out.wf(sc.break_force[j])
            out.wf(sc.break_torque[j])
    out.wi(len(sc.drives))
    for d in range(len(sc.drives)):
        var dr = sc.drives[d]
        out.wi(dr.a)
        out.wi(dr.b)
        out.wf(dr.target.x)
        out.wf(dr.target.y)
        out.wf(dr.target.z)
        out.wf(dr.target.w)
        out.wf(dr.hertz)
        out.wf(dr.zeta)
        out.wf(dr.max_torque)
        out.wv(dr.acc)
    # 17.49: contact-report flags and the event stream's per-key peaks
    # (aligned with `_prev_keys`, written above).
    out.wi(1 if sc.bset.any_report else 0)
    if sc.bset.any_report:
        for i in range(len(sc.bset.bodies)):
            out.wi(1 if sc.bset.report[i] else 0)
    out.wi(len(sc._prev_peak))
    for k in range(len(sc._prev_peak)):
        out.wf(sc._prev_peak[k])
    # 17.47: joint exts (count 0 when no joint has one yet).
    out.wi(len(sc.jext))
    for c in range(len(sc.jext)):
        var ex = sc.jext[c]
        out.wi(1 if ex.lim_on else 0)
        out.wf(ex.lo)
        out.wf(ex.hi)
        out.wf(ex.cone)
        out.wi(ex.motor)
        out.wf(ex.target)
        out.wf(ex.max_force)
        out.wf(ex.m_hertz)
        out.wf(ex.m_zeta)
        out.wf(ex.s_hertz)
        out.wf(ex.s_zeta)
        out.wf(ex.s_rest)
        out.wv(ex.ref_a)
        out.wv(ex.ref_b)
        out.wf(ex.ref_rel.x)
        out.wf(ex.ref_rel.y)
        out.wf(ex.ref_rel.z)
        out.wf(ex.ref_rel.w)
        out.wi(1 if ex.collide else 0)
        out.wf(ex.acc_lo)
        out.wf(ex.acc_hi)
        out.wf(ex.acc_motor)
        out.wf(ex.acc_spring)
        out.wf(ex.acc_cone)
        out.wi(ex.d6_mode)
        out.wv(ex.d6_lo_lin)
        out.wv(ex.d6_hi_lin)
        out.wv(ex.d6_lo_ang)
        out.wv(ex.d6_hi_ang)
        out.wv(ex.d6_acc_lin)
        out.wv(ex.d6_acc_ang)
    # 17.50: contact-model fields (static friction, rolling, spinning,
    # softness, adhesion).
    out.wi(1 if sc.bset.any_contact_model else 0)
    if sc.bset.any_contact_model:
        for i in range(len(sc.bset.bodies)):
            out.wf(sc.bset.static_friction[i])
            out.wf(sc.bset.rolling[i])
            out.wf(sc.bset.spinning[i])
            out.wf(sc.bset.contact_hertz[i])
            out.wf(sc.bset.contact_zeta[i])
            out.wf(sc.bset.adhesion[i])
    # format 5: 17.45 kinematic meshes (body-frame vertices and the pose
    # last placed at), heightfield active-edge angles, 17.53 per-triangle
    # materials and the material friction table.
    out.wi(len(sc.kin_mesh))
    for k in range(len(sc.kin_mesh)):
        out.wi(sc.kin_mesh[k])
        out.wi(len(sc.kin_local[k]))
        for v in range(len(sc.kin_local[k])):
            out.wf(sc.kin_local[k][v])
        out.wv(sc.kin_at[k].pos)
        out.wf(sc.kin_at[k].rot.x)
        out.wf(sc.kin_at[k].rot.y)
        out.wf(sc.kin_at[k].rot.z)
        out.wf(sc.kin_at[k].rot.w)
    var surf = List[Int]()
    for i in range(len(sc.bset.bodies)):
        var kk = sc.colliders.shape[i]
        if kk == SHAPE_HEIGHTFIELD:
            ref hf = sc.colliders.fields[sc.colliders.mesh_id[i]]
            if hf.active_cos != 2 or len(hf.material) > 0:
                surf.append(i)
        elif kk == SHAPE_TRIMESH:
            if len(sc.colliders.meshes[sc.colliders.mesh_id[i]].material) > 0:
                surf.append(i)
    out.wi(len(surf))
    for k in range(len(surf)):
        var i = surf[k]
        out.wi(i)
        if sc.colliders.shape[i] == SHAPE_HEIGHTFIELD:
            ref hf = sc.colliders.fields[sc.colliders.mesh_id[i]]
            out.wf(hf.active_cos)
            out.wi(len(hf.material))
            for t in range(len(hf.material)):
                out.wi(Int(hf.material[t]))
        else:
            ref ms = sc.colliders.meshes[sc.colliders.mesh_id[i]]
            out.wf(2)
            out.wi(len(ms.material))
            for t in range(len(ms.material)):
                out.wi(Int(ms.material[t]))
    out.wi(len(sc.material_mu))
    for m in range(len(sc.material_mu)):
        out.wf(sc.material_mu[m])
    out.wi(len(sc.material_hz))
    for m in range(len(sc.material_hz)):
        out.wf(sc.material_hz[m])
        out.wf(sc.material_zeta[m])
    # 17.46 per-body CCD modes (non-default only)
    var nccd = 0
    for i in range(len(sc.bset.bodies)):
        if sc.bset.ccd_mode[i] != 0:
            nccd += 1
    out.wi(nccd)
    for i in range(len(sc.bset.bodies)):
        if sc.bset.ccd_mode[i] != 0:
            out.wi(i)
            out.wi(Int(sc.bset.ccd_mode[i]))


def read_state[R: StateReader](mut sc: ContactScene6[QuatBody6], mut r: R) raises:
    """The `write_state` counterpart -- see its docstring for the field
    order and why this is a free function scoped to `ContactScene6
    [QuatBody6]` rather than a generic method. `sc` must be a freshly
    constructed, empty scene (`ContactScene6[QuatBody6]()`); this only
    appends, through `BodySet.push` (F5's one append site) for the body
    lists and directly for `ColliderSet`'s side tables (unchanged from
    before this commit -- `ColliderSet` has no `push`-style single entry
    point of its own yet, and adding one is out of this commit's scope).

    Every count and every body/joint index read from `r` is validated
    before use: a negative count or an out-of-range index means the input
    is truncated or corrupt (an environment-class failure, not a programmer
    error -- docs/ARCHITECTURE.md S2), so this raises rather than indexing
    out of bounds the way the pre-F20 reader could (F20/E20)."""
    var nb = r.ri()
    if nb < 0:
        raise Error("physics.serialize: corrupt snapshot (negative body count)")
    for _ in range(nb):
        var pos = r.rv()
        var qx = r.rf()
        var qy = r.rf()
        var qz = r.rf()
        var qw = r.rf()
        var vel = r.rv()
        var omega = r.rv()
        var im = r.rf()
        var ix = r.rf()
        var iy = r.rf()
        var iz = r.rf()
        var half = r.rv()
        # Pre-17.0g-2 `is_static` bit: still written (`write_state`), kept
        # here only for the token stream's position -- superseded by the
        # authoritative `motion` field read below, which is what
        # distinguishes KINEMATIC from DYNAMIC (a single bit cannot).
        # Discarded to `_` rather than bound, per the unused-binding lint
        # (mojo_1.1_migration.md Gotcha #5).
        _ = r.ri()
        var kind = r.ri()
        var restitution = r.rf()
        var sleeping = r.ri() == 1
        var sleep_timer = r.rf()
        var category = UInt32(r.ri())
        var mask = UInt32(r.ri())
        var sensor = r.ri() == 1
        # ROADMAP 17.0g-2 additions (`write_state`'s docstring has the exact
        # field order/rationale).
        var motion = r.ri()
        if motion < MOTION_STATIC or motion > MOTION_KINEMATIC:
            raise Error(
                "physics.serialize: corrupt snapshot (invalid motion type)"
            )
        var friction = r.rf()
        var friction_combine = r.ri()
        var restitution_combine = r.ri()
        var can_sleep = r.ri() == 1
        var id = sc.bset.push(
            QuatBody6(
                pos, Quat(qx, qy, qz, qw), vel, omega,
                Inertia3(im, ix, iy, iz),
            ),
            motion,
        )
        var bi = id.index()
        if bi != len(sc.colliders.shape):
            raise Error(
                "physics.serialize: body/collider index desync on load"
            )
        sc.bset.restitution[bi] = restitution
        sc.bset.sleeping[bi] = sleeping
        sc.bset.sleep_timer[bi] = sleep_timer
        sc.bset.friction[bi] = friction
        sc.bset.friction_combine[bi] = friction_combine
        sc.bset.restitution_combine[bi] = restitution_combine
        sc.bset.can_sleep[bi] = can_sleep
        sc.colliders.shape.append(kind)
        sc.colliders.half.append(half)
        sc.colliders.category.append(category)
        sc.colliders.mask.append(mask)
        sc.colliders.sensor.append(sensor)
        sc.colliders.hull_id.append(-1)
        sc.colliders.mesh_id.append(-1)
        sc.colliders.world_aabb.append(
            AABB[3](Vec3(0, 0, 0, 0), Vec3(0, 0, 0, 0))
        )
        match kind:
            case == SHAPE_HULL:
                var nv = r.ri()
                if nv < 0:
                    raise Error("physics.serialize: corrupt snapshot (negative hull vertex count)")
                var hv = List[Real](capacity=nv)
                for _ in range(nv):
                    hv.append(r.rf())
                sc.colliders.hull_id[bi] = len(sc.colliders.hulls)
                sc.colliders.hulls.append(HullShape(hv))
            case == SHAPE_TRIMESH:
                var nv = r.ri()
                if nv < 0:
                    raise Error("physics.serialize: corrupt snapshot (negative mesh vertex count)")
                var mv = List[Real](capacity=nv)
                for _ in range(nv):
                    mv.append(r.rf())
                var ni = r.ri()
                if ni < 0:
                    raise Error("physics.serialize: corrupt snapshot (negative mesh index count)")
                var mi = List[Int](capacity=ni)
                for _ in range(ni):
                    mi.append(r.ri())
                sc.colliders.mesh_id[bi] = len(sc.colliders.meshes)
                var tm = TriMesh(mv, mi)
                sc.colliders.world_aabb[bi] = tm.bounds()
                sc.colliders.meshes.append(tm^)
            case == SHAPE_HEIGHTFIELD:
                var nx = r.ri()
                var nz = r.ri()
                var cell = r.rf()
                var ox = r.rf()
                var oz = r.rf()
                var nh = r.ri()
                if nh < 0:
                    raise Error("physics.serialize: corrupt snapshot (negative heightfield sample count)")
                var hh = List[Real](capacity=nh)
                for _ in range(nh):
                    hh.append(r.rf())
                sc.colliders.mesh_id[bi] = len(sc.colliders.fields)
                var hfld = HeightField(hh, nx, nz, cell, ox, oz)
                sc.colliders.world_aabb[bi] = hfld.bounds()
                sc.colliders.fields.append(hfld^)
            case == SHAPE_SDF:
                var res = r.ri()
                if res < 1 or res > 512:
                    raise Error("physics.serialize: corrupt snapshot (sdf resolution)")
                var org = r.rv()
                var cl = r.rf()
                var grid = SdfGrid(res, org, cl)
                for k in range(res * res * res):
                    grid.values[k] = r.rf()
                var span = cl * Real(res - 1)
                sc.colliders.mesh_id[bi] = len(sc.colliders.sdfs)
                sc.colliders.world_aabb[bi] = AABB[3](org, org + Vec3(span, span, span, 0))
                sc.colliders.sdfs.append(grid^)
            case == SHAPE_COMPOUND:
                var nk = r.ri()
                if nk < 1 or nk > COMPOUND_MAX_CHILDREN:
                    raise Error("physics.serialize: corrupt snapshot (compound child count)")
                var f0 = len(sc.colliders.kid_desc)
                for _ in range(nk):
                    var ck = r.ri()
                    if ck != SHAPE_BOX and ck != SHAPE_SPHERE and ck != SHAPE_CAPSULE and ck != SHAPE_HULL and ck != SHAPE_ELLIPSOID:
                        raise Error("physics.serialize: corrupt snapshot (compound child kind)")
                    var ch = r.rv()
                    var cp = r.rv()
                    var qx = r.rf()
                    var qy = r.rf()
                    var qz = r.rf()
                    var qw = r.rf()
                    var hid = -1
                    if ck == SHAPE_HULL:
                        var nv = r.ri()
                        if nv < 0:
                            raise Error("physics.serialize: corrupt snapshot (negative hull vertex count)")
                        var hv = List[Real](capacity=nv)
                        for _ in range(nv):
                            hv.append(r.rf())
                        hid = len(sc.colliders.hulls)
                        sc.colliders.hulls.append(HullShape(hv))
                    sc.colliders.kid_desc.append(ShapeDesc(ck, ch, hid))
                    sc.colliders.kid_pos.append(cp)
                    sc.colliders.kid_rot.append(Quat(qx, qy, qz, qw))
                sc.colliders.mesh_id[bi] = len(sc.colliders.comp_first)
                sc.colliders.comp_first.append(f0)
                sc.colliders.comp_n.append(nk)
    var nj = r.ri()
    if nj < 0:
        raise Error("physics.serialize: corrupt snapshot (negative joint count)")
    for _ in range(nj):
        var kind = r.ri()
        var a = r.ri()
        var b = r.ri()
        var la = r.rv()
        var lb = r.rv()
        var rest = r.rf()
        var axa = r.rv()
        var axb = r.rv()
        var acc = r.rv()
        var acca = r.rv()
        var ratio = r.rf()
        if a < 0 or a >= len(sc.bset.bodies) or b < 0 or b >= len(sc.bset.bodies):
            raise Error("physics.serialize: corrupt snapshot (joint body index out of range)")
        sc.joints.append(Joint6(kind, a, b, la, lb, rest, axa, axb, acc, acca, ratio))
        # break thresholds are read after the island labels (format 4)
        sc.break_force.append(Real.MAX)
        sc.break_torque.append(Real.MAX)
        sc.peak_force.append(0)
        sc.peak_torque.append(0)
    var ns = r.ri()
    if ns < 0:
        raise Error("physics.serialize: corrupt snapshot (negative soft-body count)")
    for _ in range(ns):
        var sb = SoftBody()
        sb.alpha = r.rf()
        sb.radius = r.rf()
        sb.damp = r.rf()
        sb.mu = r.rf()
        sb.period = r.ri()
        sb.phase = r.ri()
        if sb.period < 1 or sb.phase < 0 or sb.phase >= sb.period:
            raise Error("physics.serialize: corrupt snapshot (soft-body period)")
        var np = r.ri()
        if np < 0:
            raise Error("physics.serialize: corrupt snapshot (negative particle count)")
        for _ in range(np):
            var x = r.rv()
            var v = r.rv()
            var w = r.rf()
            sb.pts.append(SP(x, v, w))
        var ne = r.ri()
        if ne < 0:
            raise Error("physics.serialize: corrupt snapshot (negative edge count)")
        for _ in range(ne):
            var ea = r.ri()
            var eb = r.ri()
            var er = r.rf()
            var el = r.rf()
            sb.edges.append(SEdge(ea, eb, er, el))
        _ = sc.add_soft(sb^)
    var nc = r.ri()
    if nc < 0:
        raise Error("physics.serialize: corrupt snapshot (negative cache-pair count)")
    for _ in range(nc):
        var a = r.ri()
        var b = r.ri()
        var feat = r.ri()
        if a < 0 or a >= len(sc.bset.bodies) or b < 0 or b >= len(sc.bset.bodies):
            raise Error("physics.serialize: corrupt snapshot (cache-pair body index out of range)")
        var m = ContactManifold[3]()
        m.hit = r.ri() == 1
        m.normal = r.rv()
        m.count = r.ri()
        var pr = ContactConstraint(
            a, b, feat, m,
            Array[Real, 4](fill=0), Array[Real, 4](fill=0),
            Array[Real, 4](fill=0),
            Array[Vec3, 4](fill=Vec3(0, 0, 0, 0)),
            Array[Vec3, 4](fill=Vec3(0, 0, 0, 0)),
            Array[Vec3, 4](fill=Vec3(0, 0, 0, 0)),
            Array[Vec3, 4](fill=Vec3(0, 0, 0, 0)),
            Array[Real, 4](fill=0), Array[Real, 4](fill=0),
            Vec3(0, 0, 0, 0), Real(-1),
            Array[Real, 4](fill=0), Vec3(0, 0, 0, 0), Real(0),
            Vec3(0, 0, 0, 0), Vec3(0, 0, 0, 0),
            Vec3(0, 0, 0, 0), Real(0), 0, Real(0), Real(0),
            Vec3(0, 0, 0, 0), -1,
            Array[Real, 4](fill=0), Vec3(0, 0, 0, 0), Real(0),
            Vec3(0, 0, 0, 0), -1,
        )
        for p in range(4):
            pr.m.points[p] = r.rv()
            pr.m.depths[p] = r.rf()
            pr.acc[p] = r.rf()
            pr.acc_t1[p] = r.rf()
            pr.acc_t2[p] = r.rf()
            pr.ra[p] = r.rv()
            pr.rb[p] = r.rv()
            pr.vn0[p] = r.rf()
            pr.racc[p] = r.rf()
            pr.hold_jn[p] = r.rf()
        pr.hold_jf = r.rv()
        pr.hold_span = r.rf()
        pr.hold_excess = r.rv()
        pr.hold_excess_up = r.ri()
        sc.cache.append(pr)
    # F20: restore the event stream's own state.
    sc.events_on = r.ri() == 1
    var nk = r.ri()
    if nk < 0:
        raise Error("physics.serialize: corrupt snapshot (negative event-key count)")
    sc._prev_keys = List[Int](capacity=nk)
    for _ in range(nk):
        sc._prev_keys.append(r.ri())
    # ROADMAP 17.85: tier phase clock, table, plan.
    sc.step_index = r.ri()
    var nt = r.ri()
    if nt < 0:
        raise Error("physics.serialize: corrupt snapshot (negative tier count)")
    sc.tier_iters = List[Int]()
    sc.tier_substeps = List[Int]()
    sc.tier_period = List[Int]()
    for _ in range(nt):
        sc.tier_iters.append(r.ri())
        sc.tier_substeps.append(r.ri())
        sc.tier_period.append(r.ri())
    var ntb = r.ri()
    if ntb < 0:
        raise Error("physics.serialize: corrupt snapshot (negative tier plan length)")
    sc.tier_of = List[Int]()
    for _ in range(ntb):
        var t = r.ri()
        if t < 0 or t >= nt:
            raise Error("physics.serialize: corrupt snapshot (tier out of range)")
        sc.tier_of.append(t)
    var nil = r.ri()
    if nil < 0 or nil > len(sc.bset.bodies):
        raise Error("physics.serialize: corrupt snapshot (island label count)")
    sc.bset.island = List[Int]()
    for _ in range(nil):
        var l = r.ri()
        if l < -1 or l >= len(sc.bset.bodies):
            raise Error("physics.serialize: corrupt snapshot (island label out of range)")
        sc.bset.island.append(l)
    # ROADMAP 17.48 (format 4): see `write_state`.
    sc.bset.any_grav = r.ri() == 1
    if sc.bset.any_grav:
        for i in range(len(sc.bset.bodies)):
            sc.bset.grav_on[i] = r.ri() == 1
            sc.bset.grav[i] = r.rv()
    if r.ri() == 1:
        for i in range(len(sc.bset.bodies)):
            var fm = r.ri()
            if fm < -1 or fm > MOTION_KINEMATIC:
                raise Error("physics.serialize: corrupt snapshot (invalid frozen motion type)")
            sc.bset.frozen_motion[i] = fm
    sc.bset.any_props = r.ri() == 1
    if sc.bset.any_props:
        for i in range(len(sc.bset.bodies)):
            sc.bset.lin_damping[i] = r.rf()
            sc.bset.ang_damping[i] = r.rf()
            sc.bset.gravity_scale[i] = r.rf()
            sc.bset.locks[i] = r.ri()
            sc.bset.max_lin[i] = r.rf()
            sc.bset.max_ang[i] = r.rf()
            sc.bset.force[i] = r.rv()
            sc.bset.torque[i] = r.rv()
            sc.bset.sleep_lin[i] = r.rf()
            sc.bset.sleep_ang[i] = r.rf()
    var nflag = r.ri()
    if nflag < 0 or nflag > len(sc.bset.bodies):
        raise Error("physics.serialize: corrupt snapshot (active-edge mesh count)")
    for _ in range(nflag):
        var bi = r.ri()
        if bi < 0 or bi >= len(sc.bset.bodies) or sc.colliders.shape[bi] != SHAPE_TRIMESH:
            raise Error("physics.serialize: corrupt snapshot (active-edge flags on a non-mesh body)")
        ref ms = sc.colliders.meshes[sc.colliders.mesh_id[bi]]
        for t in range(len(ms.active)):
            ms.active[t] = UInt8(r.ri() & 7)
    sc.any_break = r.ri() == 1
    if sc.any_break:
        for j in range(len(sc.joints)):
            sc.break_force[j] = r.rf()
            sc.break_torque[j] = r.rf()
    var nd = r.ri()
    if nd < 0:
        raise Error("physics.serialize: corrupt snapshot (negative drive count)")
    for _ in range(nd):
        var da = r.ri()
        var db = r.ri()
        var qx = r.rf()
        var qy = r.rf()
        var qz = r.rf()
        var qw = r.rf()
        var hz = r.rf()
        var zt = r.rf()
        var mt = r.rf()
        var acc = r.rv()
        if da < 0 or da >= len(sc.bset.bodies) or db < 0 or db >= len(sc.bset.bodies):
            raise Error("physics.serialize: corrupt snapshot (drive body index out of range)")
        sc.drives.append(AngularDrive(da, db, Quat(qx, qy, qz, qw), hz, zt, mt, acc))
    sc.bset.any_report = r.ri() == 1
    if sc.bset.any_report:
        for i in range(len(sc.bset.bodies)):
            sc.bset.report[i] = r.ri() == 1
    var npk = r.ri()
    if npk < 0 or npk > len(sc._prev_keys):
        raise Error("physics.serialize: corrupt snapshot (event peak count)")
    sc._prev_peak = List[Real](capacity=npk)
    for _ in range(npk):
        sc._prev_peak.append(r.rf())
    var nx = r.ri()
    if nx < 0 or nx > len(sc.joints):
        raise Error("physics.serialize: corrupt snapshot (joint ext count)")
    sc.jext = List[JointExt]()
    for _ in range(nx):
        var lim_on = r.ri() == 1
        var lo = r.rf()
        var hi = r.rf()
        var cone = r.rf()
        var motor = r.ri()
        var target = r.rf()
        var max_force = r.rf()
        var mh = r.rf()
        var mz = r.rf()
        var sh = r.rf()
        var sz = r.rf()
        var sr = r.rf()
        var ra = r.rv()
        var rb = r.rv()
        var qx = r.rf()
        var qy = r.rf()
        var qz = r.rf()
        var qw = r.rf()
        var collide = r.ri() == 1
        var a_lo = r.rf()
        var a_hi = r.rf()
        var a_m = r.rf()
        var a_s = r.rf()
        var a_c = r.rf()
        var d6m = r.ri()
        var d6a = r.rv()
        var d6b = r.rv()
        var d6c = r.rv()
        var d6d = r.rv()
        var d6e = r.rv()
        var d6f = r.rv()
        sc.jext.append(JointExt(
            lim_on, lo, hi, cone, motor, target, max_force, mh, mz, sh, sz, sr,
            ra, rb, Quat(qx, qy, qz, qw), collide, a_lo, a_hi, a_m, a_s, a_c,
            d6m, d6a, d6b, d6c, d6d, d6e, d6f,
        ))
    sc._ensure_ext()
    sc.bset.any_contact_model = r.ri() == 1
    if sc.bset.any_contact_model:
        for i in range(len(sc.bset.bodies)):
            sc.bset.static_friction[i] = r.rf()
            sc.bset.rolling[i] = r.rf()
            sc.bset.spinning[i] = r.rf()
            sc.bset.contact_hertz[i] = r.rf()
            sc.bset.contact_zeta[i] = r.rf()
            sc.bset.adhesion[i] = r.rf()
    var nkm = r.ri()
    if nkm < 0 or nkm > len(sc.bset.bodies):
        raise Error("physics.serialize: corrupt snapshot (kinematic mesh count)")
    sc.kin_mesh = List[Int]()
    sc.kin_local = List[List[Real]]()
    sc.kin_at = List[Pose6]()
    for _ in range(nkm):
        var bi = r.ri()
        if bi < 0 or bi >= len(sc.bset.bodies) or sc.colliders.shape[bi] != SHAPE_TRIMESH:
            raise Error("physics.serialize: corrupt snapshot (kinematic mesh on a non-mesh body)")
        var nl = r.ri()
        if nl != len(sc.colliders.meshes[sc.colliders.mesh_id[bi]].v):
            raise Error("physics.serialize: corrupt snapshot (kinematic mesh vertex count)")
        var loc = List[Real](capacity=nl)
        for _ in range(nl):
            loc.append(r.rf())
        var kp = r.rv()
        var qx = r.rf()
        var qy = r.rf()
        var qz = r.rf()
        var qw = r.rf()
        sc.kin_mesh.append(bi)
        sc.kin_local.append(loc^)
        sc.kin_at.append(Pose6(kp, Quat(qx, qy, qz, qw)))
    var nsf = r.ri()
    if nsf < 0 or nsf > len(sc.bset.bodies):
        raise Error("physics.serialize: corrupt snapshot (surface count)")
    for _ in range(nsf):
        var bi = r.ri()
        if bi < 0 or bi >= len(sc.bset.bodies) or (sc.colliders.shape[bi] != SHAPE_TRIMESH and sc.colliders.shape[bi] != SHAPE_HEIGHTFIELD):
            raise Error("physics.serialize: corrupt snapshot (surface data on a non-mesh body)")
        var acos = r.rf()
        var nm = r.ri()
        if nm < 0 or nm > 1 << 26:
            raise Error("physics.serialize: corrupt snapshot (material count)")
        var ids = List[Int](capacity=nm)
        for _ in range(nm):
            ids.append(r.ri())
        if sc.colliders.shape[bi] == SHAPE_HEIGHTFIELD:
            sc.colliders.fields[sc.colliders.mesh_id[bi]].active_cos = acos
        sc.colliders.set_materials(bi, ids)
    var nmu = r.ri()
    if nmu < 0 or nmu > 65536:
        raise Error("physics.serialize: corrupt snapshot (material table size)")
    sc.material_mu = List[Real](capacity=nmu)
    for _ in range(nmu):
        sc.material_mu.append(r.rf())
    var nhz = r.ri()
    if nhz < 0 or nhz > 65536:
        raise Error("physics.serialize: corrupt snapshot (material softness table size)")
    sc.material_hz = List[Real](capacity=nhz)
    sc.material_zeta = List[Real](capacity=nhz)
    for _ in range(nhz):
        sc.material_hz.append(r.rf())
        sc.material_zeta.append(r.rf())
    var nccd = r.ri()
    if nccd < 0 or nccd > len(sc.bset.bodies):
        raise Error("physics.serialize: corrupt snapshot (ccd mode count)")
    for _ in range(nccd):
        var bi = r.ri()
        var md = r.ri()
        if bi < 0 or bi >= len(sc.bset.bodies) or md < 0 or md > 2:
            raise Error("physics.serialize: corrupt snapshot (ccd mode)")
        sc.bset.ccd_mode[bi] = UInt8(md)
        if md == CCD_BULLET:
            sc.bset.any_bullet = True


def _uf_find(mut parent: List[Int], i: Int) -> Int:
    var r = i
    while parent[r] != r:
        r = parent[r]
    var k = i
    while parent[k] != r:
        var nx = parent[k]
        parent[k] = r
        k = nx
    return r


def _uf_union(mut parent: List[Int], a: Int, b: Int):
    var ra = _uf_find(parent, a)
    var rb = _uf_find(parent, b)
    if ra != rb:
        parent[max(ra, rb)] = min(ra, rb)
