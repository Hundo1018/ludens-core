"""Contact constraints and their sequential-impulse solve (audit F11, cluster
1 + 8): the constraint record, its prep from raw collision geometry, warm
starting, the soft (Box2D v3 / Solver2D) normal + Coulomb friction solve, the
graph-coloured and colour-parallel sweeps, and the restitution pass.

Every function here is a free function over a `BodySet` view plus a slice of
`ContactConstraint`s -- nothing reads a `ContactScene6`. That is the shape the
Wave B items need: a GPU contact solver (17.17) and a batched world layout
(17.18) swap the body storage, and a differentiable solve (17.20) swaps the
scalar ring, without rewriting a 2 800-line scene. `ContactScene6` in
`physics/solver6.mojo` now only composes these calls; the arithmetic, and
therefore every result, is unchanged (the golden test output is the identity
gate for the move).
"""

from std.math import sqrt
from scheduler.dispatch import Dispatch, Task, dispatch_for
from geometry.vec import Real, Vec3, dot, tangent_basis
from collision.manifold import ContactManifold
from collision.contact_gen import RawContact
from collision.contact_events import pack_key
from collision.collider_set import ColliderSet, SHAPE_SPHERE, SHAPE_CAPSULE, SHAPE_ELLIPSOID, SHAPE_COMPOUND, SHAPE_TRIMESH, SHAPE_HEIGHTFIELD, SHAPE_SDF
from .rigid6 import Body6
from .body_set import BodySet
from .material import combine

comptime _BETA: Real = 0.2  # Baumgarte position-correction gain
comptime _SLOP: Real = 0.005  # allowed penetration
# ROADMAP 17.50: a contact point whose tangential speed at prep is below
# this grips with the static coefficient (m/s). Prep runs before the frame's
# gravity is integrated, so a resting point reads ~0 here.
comptime _STICK_V: Real = 0.01
# Adhesion (17.50) holds a point whose separation is within this gap (m).
comptime _ADH_GAP: Real = 0.01
comptime _BLOCK_EPS: Real = 1e-4  # 17.50 block solver diagonal regularisation (relative)

# Per-step contact features as a compile-time bit set (ROADMAP 17.98): the
# sweeps read `BodySet` once per call and run a kernel specialised for the set
# bits, so `solve_contact`'s per-pair, per-iteration body has no test for a
# feature that is off. Each bit only removes code that the run-time flag
# skipped anyway, so every flag combination is bit-identical to before.
comptime CF_MODEL = 1  # `bset.any_contact_model`: static friction, rolling, per-body softness, adhesion
comptime CF_ELLIPTIC = 2  # `bset.cone == 1`: elliptic friction cone
comptime CF_BLOCK = 4  # `bset.block`: block normal solve of multi-point manifolds


def contact_features[B: Body6](bset: BodySet[B]) -> Int:
    """The `CF_*` bits of the run-time flags in `bset`."""
    var f = 0
    if bset.any_contact_model:
        f |= CF_MODEL
    if bset.cone == 1:
        f |= CF_ELLIPTIC
    if bset.block:
        f |= CF_BLOCK
    return f


@fieldwise_init
struct ContactConstraint(Copyable, ImplicitlyCopyable, Movable):
    var a: Int
    var b: Int
    # Sub-key within the pair. Zero for shape-vs-shape, which produces one
    # manifold; for static mesh contact it is the triangle index, because one
    # crate resting on a level touches several triangles at once and each is a
    # separate manifold. Without it every one of them would inherit the first
    # cached entry's impulses and warm-starting would fight itself.
    var feat: Int
    var m: ContactManifold[3]
    var acc: Array[Real, 4]  # per-point accumulated normal impulse
    var acc_t1: Array[Real, 4]  # accumulated friction impulses
    var acc_t2: Array[Real, 4]
    # Body-frame contact anchors (Box2D scheme): both coincide with the
    # manifold point at prep; per-substep world separation is re-derived from
    # the CURRENT poses, so tilting a body deepens its near edge and the bias
    # produces a restoring torque (frozen depths cannot — towers slowly tip).
    var ra: Array[Vec3, 4]
    var rb: Array[Vec3, 4]
    # ROADMAP 17.19: round shapes (sphere, capsule). For them `ra` / `rb` is
    # the closest point on the shape's CORE (sphere centre, capsule segment)
    # in the body frame, and `oa` / `ob` the world-frame offset from that core
    # point to the contact point, which does NOT turn with the body. A rolling
    # ball's contact stays under its centre; with a body-frame anchor the
    # point rotated forward each substep, friction acted ahead of the true
    # contact and braked the roll, and the anchor's lift sank the ball. Zero
    # for every other shape, where the anchor is the body-frame point as before.
    var oa: Array[Vec3, 4]
    var ob: Array[Vec3, 4]
    # Restitution (Box2D v3 scheme): the approach speed captured at prep time
    # drives a dedicated post-substep pass toward v_target = -e·vn0. Neither
    # field is warm-start-inherited — both are per-frame.
    var vn0: Array[Real, 4]
    var racc: Array[Real, 4]
    # Contact modification (ROADMAP 17.26), set per frame by a
    # `ContactRule` and never inherited from the cache: the tangential
    # velocity of b's surface relative to a's that friction should match (a
    # conveyor belt), and a friction coefficient replacing the combined one
    # (< 0 = none).
    var vsurf: Vec3
    var mu_override: Real
    # ROADMAP 17.49 report: this step's normal impulse per point (restitution
    # included), the summed friction impulse vector, and the time they cover.
    # Built by `accumulate_step_impulse` / `add_restitution_impulse`, never
    # inherited from the cache.
    var jn: Array[Real, 4]
    var jf: Vec3
    var span: Real
    # ROADMAP 17.52: semi-axes of side a / b when it is an ellipsoid (zero
    # otherwise). Its anchor is then re-taken every substep as its support
    # point along the normal under the current orientation: on a rocking
    # ellipsoid the contact slides over the surface, and the sphere's fixed
    # world offset pumped energy in (+2.6 % in 4 s at 60 Hz).
    var ea: Vec3
    var eb: Vec3
    # ROADMAP 17.50, read only when `bset.any_contact_model`: the pair's
    # accumulated rolling (tangential) and spin (normal) angular impulses,
    # warm-started each substep like the friction accumulators but never
    # inherited across frames, and a bit per point set at prep when its
    # tangential speed is below `_STICK_V` (static friction applies then).
    var roll_acc: Vec3
    var spin_acc: Real
    var stick: Int
    # ROADMAP 17.50: contact softness from the touched mesh triangle's
    # material (`ContactScene6.set_material_softness`); hertz 0 = none.
    var soft_hz: Real
    var soft_zeta: Real
    # ROADMAP 17.19 (A2): the upward force this pair's report carries from a
    # scaled body's excess weight (`ContactScene6._report_excess`), set per
    # step when `max_mass_ratio` is on. `excess_up` is the body it supports
    # (-1 = none). Read by `contacts_of` only; the solver never reads it.
    var excess: Vec3
    var excess_up: Int
    # ROADMAP 17.19 (5): the held report load. `jn` / `jf` / `span` / `excess`
    # above are this step's live values, zero for a pair the solver skipped
    # because both sides are inert -- and the event stream must keep seeing
    # zero there. `hold_*` is the snapshot of the last step this pair was
    # solved (`ContactScene6._hold_loads`), carried by the warm-start match,
    # and read only by `contacts_of` while the pair is inert. Serialized with
    # the cache (snapshot format 6), so a loaded sleeping pair keeps reporting.
    var hold_jn: Array[Real, 4]
    var hold_jf: Vec3
    var hold_span: Real
    var hold_excess: Vec3
    var hold_excess_up: Int

    def __init__(out self, *, copy: Self):
        """Explicit copy: `Array` is not `ImplicitlyCopyable` in
        Mojo 1.0, so a struct holding one gets no synthesised copy."""
        self.a = copy.a
        self.b = copy.b
        self.feat = copy.feat
        self.m = copy.m.copy()
        self.acc = copy.acc.copy()
        self.acc_t1 = copy.acc_t1.copy()
        self.acc_t2 = copy.acc_t2.copy()
        self.ra = copy.ra.copy()
        self.rb = copy.rb.copy()
        self.oa = copy.oa.copy()
        self.ob = copy.ob.copy()
        self.vn0 = copy.vn0.copy()
        self.racc = copy.racc.copy()
        self.vsurf = copy.vsurf
        self.mu_override = copy.mu_override
        self.jn = copy.jn.copy()
        self.jf = copy.jf
        self.span = copy.span
        self.ea = copy.ea
        self.eb = copy.eb
        self.roll_acc = copy.roll_acc
        self.spin_acc = copy.spin_acc
        self.stick = copy.stick
        self.soft_hz = copy.soft_hz
        self.soft_zeta = copy.soft_zeta
        self.excess = copy.excess
        self.excess_up = copy.excess_up
        self.hold_jn = copy.hold_jn.copy()
        self.hold_jf = copy.hold_jf
        self.hold_span = copy.hold_span
        self.hold_excess = copy.hold_excess
        self.hold_excess_up = copy.hold_excess_up


@always_inline
def _cs[B: Body6](bset: BodySet[B], i: Int) -> Real:
    """Contact mass scale of body i (`SolverConfig.max_mass_ratio`, 17.19):
    its inverse mass and inertia in contact rows are multiplied by this
    (<= 1). 1 when the option is off; x * 1 is exact, so an unscaled step
    is bit-identical to one without the option."""
    return bset.cscale[i] if bset.mass_ratio > 0 else Real(1)


def contact_island[B: Body6](bset: BodySet[B], pr: ContactConstraint) -> Int:
    """The island a contact belongs to: its dynamic side's label."""
    return bset.island[pr.a] if bset.is_dynamic(pr.a) else bset.island[pr.b]


def island_color(label: Int) -> SIMD[DType.float32, 4]:
    """Debug-draw colour of an island label: a 6-colour palette keyed by
    label mod 6 (white for -1). Shared by the scene's debug draw and
    `physics.capture.draw_frame`."""
    var lbl = label % 6 if label >= 0 else 5
    match lbl:
        case 0:
            return SIMD[DType.float32, 4](1, 0, 0, 1)
        case 1:
            return SIMD[DType.float32, 4](0, 1, 0, 1)
        case 2:
            return SIMD[DType.float32, 4](0, 0, 1, 1)
        case 3:
            return SIMD[DType.float32, 4](1, 1, 0, 1)
        case 4:
            return SIMD[DType.float32, 4](0, 1, 1, 1)
        case _:
            return SIMD[DType.float32, 4](1, 1, 1, 1)


def make_sensor_contact(rc: RawContact) -> ContactConstraint:
    """Wrap a sensor overlap: all-zero accumulators/anchors, matching the
    original inline construction exactly -- a sensor never receives an
    impulse, so it never needs an anchor or an approach-speed prep."""
    return ContactConstraint(
        rc.a, rc.b, rc.feat, rc.m,
        Array[Real, 4](fill=0),
        Array[Real, 4](fill=0),
        Array[Real, 4](fill=0),
        Array[Vec3, 4](fill=Vec3(0, 0, 0, 0)),
        Array[Vec3, 4](fill=Vec3(0, 0, 0, 0)),
        Array[Vec3, 4](fill=Vec3(0, 0, 0, 0)),
        Array[Vec3, 4](fill=Vec3(0, 0, 0, 0)),
        Array[Real, 4](fill=0),
        Array[Real, 4](fill=0),
        Vec3(0, 0, 0, 0),
        Real(-1),
        Array[Real, 4](fill=0),
        Vec3(0, 0, 0, 0),
        Real(0),
        Vec3(0, 0, 0, 0),
        Vec3(0, 0, 0, 0),
        Vec3(0, 0, 0, 0),
        Real(0),
        0,
        Real(0),
        Real(0),
        Vec3(0, 0, 0, 0),
        -1,
        Array[Real, 4](fill=0),
        Vec3(0, 0, 0, 0),
        Real(0),
        Vec3(0, 0, 0, 0),
        -1,
    )


def cache_index(cache: List[ContactConstraint]) -> Dict[Int, Int]:
    """First cache position of each (a, b, feat) key -- built once per frame
    so the warm-start match is a lookup instead of a scan per new contact
    (audit F22: that scan made collection O(pairs x cache))."""
    var idx = Dict[Int, Int]()
    for c in range(len(cache)):
        var k = pack_key(cache[c].a, cache[c].b, cache[c].feat)
        if k not in idx:
            idx[k] = c
    return idx^


def round_core[B: Body6](
    bset: BodySet[B], colliders: ColliderSet, i: Int, p: Vec3, n: Vec3 = Vec3(0, 0, 0, 0),
    child: Int = -1,
) -> Optional[Vec3]:
    """Body-frame core point of a round collider nearest to world point
    `p` -- the sphere's centre, or the clamped point on a capsule's local-y
    segment -- or None for any other shape (ROADMAP 17.19). A cylinder
    (17.52) counts as round when the contact normal `n` is across its axis
    (a side contact), not on its flat end caps. For a compound (17.44)
    `child` names the child that touched: a sphere child's centre or the
    clamped point on a capsule child's axis, in the body frame."""
    var k = colliders.shape[i]
    if k == SHAPE_COMPOUND:
        if child < 0 or child >= colliders.kid_count(i):
            return None
        var d = colliders.kid(i, child)
        var r = colliders.comp_first[colliders.mesh_id[i]] + child
        var lp = colliders.kid_pos[r]
        if d.kind == SHAPE_SPHERE:
            return lp
        if d.kind == SHAPE_CAPSULE:
            var ax = colliders.kid_rot[r].rotate(Vec3(0, 1, 0, 0))
            var y = dot(bset.bodies[i].to_local(p) - lp, ax)
            return lp + ax * min(max(y, -d.half[1]), d.half[1])
        return None
    var rr = colliders.round_radius(i)
    if rr > 0:
        var o = bset.bodies[i].act(Vec3(0, 0, 0, 0))
        var axis = bset.bodies[i].act(Vec3(0, 1, 0, 0)) - o
        if abs(dot(n, axis)) >= 0.5:
            return None
        var hl = colliders.half[i][1]
        var y = bset.bodies[i].to_local(p)[1]
        return Vec3(0, min(max(y, -hl), hl), 0, 0)
    if k == SHAPE_SPHERE or k == SHAPE_ELLIPSOID:
        return Vec3(0, 0, 0, 0)
    if k == SHAPE_CAPSULE:
        var hl = colliders.half[i][1]
        var y = bset.bodies[i].to_local(p)[1]
        return Vec3(0, min(max(y, -hl), hl), 0, 0)
    return None


def round_reach[B: Body6](
    bset: BodySet[B], colliders: ColliderSet, i: Int, n: Vec3, child: Int = -1
) -> Real:
    """How far round collider `i`'s surface lies from its core point along
    unit world direction `n`: the radius, or for an ellipsoid (17.52) its
    support function |diag(radii) R^T n|."""
    if colliders.shape[i] == SHAPE_COMPOUND and child >= 0:
        return colliders.kid(i, child).half[0]  # sphere / capsule child radius
    if colliders.shape[i] == SHAPE_ELLIPSOID:
        var o = bset.bodies[i].act(Vec3(0, 0, 0, 0))
        var ln = bset.bodies[i].to_local(o + n)
        var h = colliders.half[i]
        return sqrt((h[0] * ln[0]) ** 2 + (h[1] * ln[1]) ** 2 + (h[2] * ln[2]) ** 2)
    var rr = colliders.round_radius(i)
    return rr if rr > 0 else colliders.half[i][0]


def anchor_world[B: Body6](
    bset: BodySet[B], i: Int, r: Vec3, o: Vec3,
    e: Vec3 = Vec3(0, 0, 0, 0), toward: Vec3 = Vec3(0, 0, 0, 0),
) -> Vec3:
    """World position of a contact anchor: body-frame point `r` under the
    current pose, plus the world-frame round-shape offset `o` (zero for
    non-round shapes, so this is `act(r)` exactly). An ellipsoid side (its
    semi-axes `e` nonzero) anchors at its current support point along unit
    `toward` instead (17.52)."""
    if e[0] > 0:
        var c = bset.bodies[i].act(Vec3(0, 0, 0, 0))
        var ln = bset.bodies[i].to_local(c + toward)
        var q = Vec3(e[0] * e[0] * ln[0], e[1] * e[1] * ln[1], e[2] * e[2] * ln[2], 0)
        var l = sqrt((e[0] * ln[0]) ** 2 + (e[1] * ln[1]) ** 2 + (e[2] * ln[2]) ** 2)
        if l > Real(1e-12):
            return bset.bodies[i].act(q / l)
    return bset.bodies[i].act(r) + o


def make_contact[B: Body6](
    bset: BodySet[B],
    colliders: ColliderSet,
    cache: List[ContactConstraint],
    cidx: Dict[Int, Int],
    rc: RawContact,
    warm: Bool,
    match_scale: Real = 1,
) -> ContactConstraint:
    """Wrap raw contact geometry (`collision.contact_gen.RawContact`)
    into a solved `ContactConstraint`: body-frame anchors and approach-speed prep
    (need `Body6.to_local`/`velocity_at`), then a warm-start match
    against last frame's cache (need `cache`) -- the two things
    `contact_gen` cannot do without seeing physics.

    For a mesh contact `rc.b` is always static, so `vb0` below is always
    the zero it starts as -- the same value the old mesh-specific path
    got from `dot(-va0, normal)`, just via the shared formula."""
    var pr = ContactConstraint(
        rc.a, rc.b, rc.feat, rc.m,
        Array[Real, 4](fill=0),
        Array[Real, 4](fill=0),
        Array[Real, 4](fill=0),
        Array[Vec3, 4](fill=Vec3(0, 0, 0, 0)),
        Array[Vec3, 4](fill=Vec3(0, 0, 0, 0)),
        Array[Vec3, 4](fill=Vec3(0, 0, 0, 0)),
        Array[Vec3, 4](fill=Vec3(0, 0, 0, 0)),
        Array[Real, 4](fill=0),
        Array[Real, 4](fill=0),
        Vec3(0, 0, 0, 0),
        Real(-1),
        Array[Real, 4](fill=0),
        Vec3(0, 0, 0, 0),
        Real(0),
        Vec3(0, 0, 0, 0),
        Vec3(0, 0, 0, 0),
        Vec3(0, 0, 0, 0),
        Real(0),
        0,
        Real(0),
        Real(0),
        Vec3(0, 0, 0, 0),
        -1,
        Array[Real, 4](fill=0),
        Vec3(0, 0, 0, 0),
        Real(0),
        Vec3(0, 0, 0, 0),
        -1,
    )
    if colliders.shape[rc.a] == SHAPE_ELLIPSOID:
        pr.ea = colliders.half[rc.a]
    if colliders.shape[rc.b] == SHAPE_ELLIPSOID:
        pr.eb = colliders.half[rc.b]
    # 17.44: which child of a compound made this contact (the feat encodings
    # of `contact_gen.try_compound_pair` and `try_mesh_pair`)
    var kid_a = -1
    var kid_b = -1
    var sa = colliders.shape[rc.a]
    var sb0 = colliders.shape[rc.b]
    if sa == SHAPE_COMPOUND or sb0 == SHAPE_COMPOUND:
        if sb0 == SHAPE_TRIMESH or sb0 == SHAPE_HEIGHTFIELD:
            kid_a = rc.feat >> 16
        elif sa != SHAPE_SDF and sb0 != SHAPE_SDF and rc.feat >= 1:
            kid_a = (rc.feat - 1) // 1024
            kid_b = (rc.feat - 1) % 1024
    for k in range(rc.m.count):
        var p = rc.m.points[k]
        var ca = round_core(bset, colliders, rc.a, p, rc.m.normal, kid_a)
        var cb = round_core(bset, colliders, rc.b, p, rc.m.normal, kid_b)
        # A round side's lever arm must reach its real surface: the
        # narrowphase puts e.g. a sphere-on-box point on the margin-inflated
        # face, half a speculative margin inside the ball, and friction
        # there makes a ball roll at omega * (r - margin/2) == v. Slide the
        # point along the normal (both anchors together, so separation is
        # unchanged) to the round surface, or midway between two of them.
        if ca or cb:
            var n = rc.m.normal
            var target = Real(0)
            if case .Some(wa) = ca:
                target = dot(bset.bodies[rc.a].act(wa), n) + round_reach(bset, colliders, rc.a, n, kid_a)
            if case .Some(wb) = cb:
                var sb = dot(bset.bodies[rc.b].act(wb), n) - round_reach(bset, colliders, rc.b, n, kid_b)
                target = (target + sb) * 0.5 if ca else sb
            p = p + n * (target - dot(p, n))
        if case .Some(wa) = ca:
            pr.ra[k] = wa
            pr.oa[k] = p - bset.bodies[rc.a].act(wa)
        else:
            pr.ra[k] = bset.bodies[rc.a].to_local(p)
        if case .Some(wb) = cb:
            pr.rb[k] = wb
            pr.ob[k] = p - bset.bodies[rc.b].act(wb)
        else:
            pr.rb[k] = bset.bodies[rc.b].to_local(p)
        var va0 = Vec3(0, 0, 0, 0)
        var vb0 = Vec3(0, 0, 0, 0)
        if not bset.is_static(rc.a):
            va0 = bset.bodies[rc.a].velocity_at(p)
        if not bset.is_static(rc.b):
            vb0 = bset.bodies[rc.b].velocity_at(p)
        pr.vn0[k] = dot(vb0 - va0, rc.m.normal)
        if bset.any_contact_model:
            var vt0 = (vb0 - va0) - rc.m.normal * pr.vn0[k]
            if dot(vt0, vt0) < _STICK_V * _STICK_V:
                pr.stick |= 1 << k
    if warm:
        # Start at the first entry with this key (`cache_index`); the scan
        # from there keeps the old first-match rule exactly, count included.
        var start = cidx.get(pack_key(rc.a, rc.b, rc.feat), len(cache))
        for c in range(start, len(cache)):
            var old = cache[c]
            if (
                old.a == rc.a
                and old.b == rc.b
                and old.feat == rc.feat
                and old.m.count == rc.m.count
            ):
                # Match each point to the nearest unused cached point, not
                # by index: `box_box_manifold` returns the same four corners
                # of a resting box in a different order from step to step,
                # and index matching handed every corner another corner's
                # friction -- a 3-box stack built up that torsion until it
                # kicked (1.24 N sideways on the top box, ARM runner).
                # Distance in body `a`'s frame (a sliding box's corners stay
                # put there), and only within 5 cm (times `match_scale`). A point with no cached
                # point that close keeps the old rule -- the cached point of
                # the same index, if not taken: points that moved further
                # (a box sliding over small triangles, a bullet in the step
                # after its impact) have no reliable partner either way, and
                # forcing the nearest one kicked the sliding box up at the
                # seams (|vy| 0.023) while starting cold raised the bullet's
                # rebound from 2.4 to 3.5 m/s.
                var used = Array[Bool, 4](fill=False)
                var src = Array[Int, 4](fill=-1)
                for k in range(rc.m.count):
                    var best = -1
                    # (5 cm)^2, scaled with the world's length unit
                    # (`match_scale` = margin_base / SPEC_BASE, so
                    # `UnitScale` scales it; ROADMAP 17.75)
                    var bd = Real(2.5e-3) * match_scale * match_scale
                    for q in range(old.m.count):
                        if used[q]:
                            continue
                        var dv = old.ra[q] - pr.ra[k]
                        var d2 = dot(dv, dv)
                        if d2 <= bd:
                            bd = d2
                            best = q
                    if best >= 0:
                        used[best] = True
                        src[k] = best
                for k in range(rc.m.count):
                    if src[k] < 0 and not used[k]:
                        used[k] = True
                        src[k] = k
                for k in range(rc.m.count):
                    if src[k] >= 0:
                        pr.acc[k] = old.acc[src[k]]
                        pr.acc_t1[k] = old.acc_t1[src[k]]
                        pr.acc_t2[k] = old.acc_t2[src[k]]
                # 17.19 (5): the held loads ride along with the warm start
                pr.hold_jn = old.hold_jn.copy()
                pr.hold_jf = old.hold_jf
                pr.hold_span = old.hold_span
                pr.hold_excess = old.hold_excess
                pr.hold_excess_up = old.hold_excess_up
                break
    return pr^


def accumulate_step_impulse[B: Body6](
    bset: BodySet[B], mut pairs: List[ContactConstraint], lo: Int, hi: Int, scale: Real, h: Real
):
    """After a substep's relax sweep: each point's `acc` is exactly the
    normal impulse that substep applied (the warm start applied the old
    `acc`, the sweeps applied the increments), likewise `acc_t1 / acc_t2`
    for friction. Add them (times `scale`) to the step totals. A pair the
    solver skipped (both sides impulse-inert: static or asleep) applied
    nothing -- its `acc` is only kept for the next warm start -- so it adds
    nothing."""
    for c in range(lo, hi):
        ref pr = pairs[c]
        if bset.impulse_inert(pr.a) and bset.impulse_inert(pr.b):
            continue
        var tb = tangent_basis(pr.m.normal)
        for k in range(pr.m.count):
            pr.jn[k] += pr.acc[k] * scale
            pr.jf = pr.jf + (tb[0] * pr.acc_t1[k] + tb[1] * pr.acc_t2[k]) * scale
        pr.span += h * scale


def add_restitution_impulse[B: Body6](
    bset: BodySet[B], mut pairs: List[ContactConstraint], lo: Int, hi: Int
):
    """Fold the restitution pass's normal impulses into the step totals."""
    for c in range(lo, hi):
        ref pr = pairs[c]
        if bset.impulse_inert(pr.a) and bset.impulse_inert(pr.b):
            continue
        for k in range(pr.m.count):
            pr.jn[k] += pr.racc[k]


def warm_start_contacts[B: Body6](
    mut bset: BodySet[B], pairs: List[ContactConstraint], lo: Int, hi: Int
):
    """Apply the accumulated impulses at each anchor (Box2D v3 scheme: the
    soft solve's `-impulseScale·acc` term is what balances this out)."""
    for c in range(lo, hi):
        ref pr = pairs[c]
        if bset.impulse_inert(pr.a) and bset.impulse_inert(pr.b):
            continue
        var n = pr.m.normal
        var tb = tangent_basis(n)
        for k in range(pr.m.count):
            var j = (
                n * pr.acc[k]
                + tb[0] * pr.acc_t1[k]
                + tb[1] * pr.acc_t2[k]
            )
            if bset.is_dynamic(pr.a):
                bset.bodies[pr.a].apply_impulse(
                    -j * _cs(bset, pr.a), anchor_world(bset, pr.a, pr.ra[k], pr.oa[k], pr.ea, n)
                )
            if bset.is_dynamic(pr.b):
                bset.bodies[pr.b].apply_impulse(
                    j * _cs(bset, pr.b), anchor_world(bset, pr.b, pr.rb[k], pr.ob[k], pr.eb, -n)
                )
        if bset.any_contact_model:
            var l = pr.roll_acc + n * pr.spin_acc
            if bset.is_dynamic(pr.a):
                bset.bodies[pr.a].apply_angular_impulse(-l)
            if bset.is_dynamic(pr.b):
                bset.bodies[pr.b].apply_angular_impulse(l)


def warm_start_prepared[B: Body6](
    mut bset: BodySet[B], pairs: List[ContactConstraint], cache: SweepCache, lo: Int, hi: Int
):
    """`warm_start_contacts` reading the anchors and the tangent basis from a
    `SweepCache` prepared at the current poses (ROADMAP 17.99): the same
    values `anchor_world` / `tangent_basis` give there, so bit-identical."""
    for c in range(lo, hi):
        ref pr = pairs[c]
        if bset.impulse_inert(pr.a) and bset.impulse_inert(pr.b):
            continue
        var n = pr.m.normal
        var co = c - cache.base
        var tb0 = cache.t1[co]
        var tb1 = cache.t2[co]
        for k in range(pr.m.count):
            var j = (
                n * pr.acc[k]
                + tb0 * pr.acc_t1[k]
                + tb1 * pr.acc_t2[k]
            )
            if bset.is_dynamic(pr.a):
                bset.bodies[pr.a].apply_impulse(-j * _cs(bset, pr.a), cache.pwa[4 * co + k])
            if bset.is_dynamic(pr.b):
                bset.bodies[pr.b].apply_impulse(j * _cs(bset, pr.b), cache.pwb[4 * co + k])
        if bset.any_contact_model:
            var l = pr.roll_acc + n * pr.spin_acc
            if bset.is_dynamic(pr.a):
                bset.bodies[pr.a].apply_angular_impulse(-l)
            if bset.is_dynamic(pr.b):
                bset.bodies[pr.b].apply_angular_impulse(l)


def solve_point[B: Body6](
    mut bset: BodySet[B],
    ia: Int,
    ib: Int,
    n: Vec3,
    p: Vec3,
    depth: Real,
    dt: Real,
    acc: Real,
) -> Real:
    """One accumulated-impulse Gauss-Seidel update; returns the new
    accumulated normal impulse (clamped >= 0, so later sweeps can remove
    an earlier over-push — without this the solve order injects a net
    torque and resting boxes slowly rotate)."""
    # `moves` (velocity read: dynamic OR kinematic) vs `is_dynamic` (mass
    # term + impulse: dynamic only) -- ROADMAP 17.24's whole solver-side
    # split, see `BodySet.moves`'s docstring. A zero-velocity kinematic
    # body takes the exact same `moves=True, is_dynamic=False` branches a
    # static body takes `moves=False`, both landing on `va=0, ka=0` --
    # the bit-identity the KEY PARITY TEST requires.
    var va = Vec3(0, 0, 0, 0)
    var ka = Real(0)
    if bset.moves(ia):
        va = bset.bodies[ia].velocity_at(p)
    if bset.is_dynamic(ia):
        ka = bset.bodies[ia].inv_mass() + bset.bodies[ia].angular_factor(
            p - bset.bodies[ia].position(), n
        )
    var vb = Vec3(0, 0, 0, 0)
    var kb = Real(0)
    if bset.moves(ib):
        vb = bset.bodies[ib].velocity_at(p)
    if bset.is_dynamic(ib):
        kb = bset.bodies[ib].inv_mass() + bset.bodies[ib].angular_factor(
            p - bset.bodies[ib].position(), n
        )
    ka *= _cs(bset, ia)
    kb *= _cs(bset, ib)
    var denom = ka + kb
    if denom <= 0:
        return acc
    var vn = dot(vb - va, n)  # >0 means separating (n points a -> b)
    var bias = _BETA / dt * max(depth - _SLOP, 0)
    var new_acc = max(acc + (bias - vn) / denom, 0)
    var dl = new_acc - acc
    if dl == 0:
        return acc
    var j = n * dl
    if bset.is_dynamic(ia):
        bset.bodies[ia].apply_impulse(-j * _cs(bset, ia), p)
    if bset.is_dynamic(ib):
        bset.bodies[ib].apply_impulse(j * _cs(bset, ib), p)
    return new_acc


struct SweepCache(Movable):
    """ROADMAP 17.99: what the velocity sweeps of one `soft_sweep` /
    `sweep_colored` call do not change, computed once per call by
    `prepare_sweep`: per point the world anchors and the normal and tangent
    denominators (inverse masses plus `angular_factor`, scaled by `_cs`), per
    pair the tangent basis. A sweep changes velocities only; poses move
    between sweep calls (`integrate_pose`), so every call prepares afresh.
    The values come from the same functions on the same inputs as the
    per-iteration code they replace, so the solve is bit-identical."""

    var base: Int  # pair index of slot 0
    var pwa: List[Vec3]  # 4 per pair
    var pwb: List[Vec3]
    var dn: List[Real]
    var dt1: List[Real]
    var dt2: List[Real]
    var t1: List[Vec3]  # 1 per pair
    var t2: List[Vec3]

    def __init__(out self, lo: Int, hi: Int):
        var n = max(hi - lo, 0)
        self.base = lo
        self.pwa = List[Vec3](length=4 * n, fill=Vec3(0, 0, 0, 0))
        self.pwb = List[Vec3](length=4 * n, fill=Vec3(0, 0, 0, 0))
        self.dn = List[Real](length=4 * n, fill=0)
        self.dt1 = List[Real](length=4 * n, fill=0)
        self.dt2 = List[Real](length=4 * n, fill=0)
        self.t1 = List[Vec3](length=n, fill=Vec3(0, 0, 0, 0))
        self.t2 = List[Vec3](length=n, fill=Vec3(0, 0, 0, 0))


@always_inline
def _denom[B: Body6](
    bset: BodySet[B], pr: ContactConstraint, pwa: Vec3, pwb: Vec3, axis: Vec3
) -> Real:
    """`ka + kb` along `axis`, written exactly as `solve_contact` wrote it."""
    var ka = Real(0)
    if bset.is_dynamic(pr.a):
        ka = bset.bodies[pr.a].inv_mass() + bset.bodies[
            pr.a
        ].angular_factor(pwa - bset.bodies[pr.a].position(), axis)
    var kb = Real(0)
    if bset.is_dynamic(pr.b):
        kb = bset.bodies[pr.b].inv_mass() + bset.bodies[
            pr.b
        ].angular_factor(pwb - bset.bodies[pr.b].position(), axis)
    ka *= _cs(bset, pr.a)
    kb *= _cs(bset, pr.b)
    return ka + kb


def prepare_sweep[B: Body6](
    bset: BodySet[B], pairs: List[ContactConstraint], lo: Int, hi: Int
) -> SweepCache:
    """A new `SweepCache` of pairs `lo ..< hi` at the current poses."""
    var sc = SweepCache(lo, hi)
    prepare_into(sc, bset, pairs, lo, hi)
    return sc^


def prepare_into[B: Body6](
    mut sc: SweepCache, bset: BodySet[B], pairs: List[ContactConstraint], lo: Int, hi: Int
):
    """Fill `sc` for pairs `lo ..< hi` at the current poses, reusing its
    storage (a step keeps one `SweepCache` and refills it after every pose
    change instead of allocating per sweep). Entries of an inert pair are
    left as they were: `solve_contact` and `warm_start_prepared` return
    before reading them."""
    var n = max(hi - lo, 0)
    sc.base = lo
    if len(sc.t1) < n:
        sc.pwa.resize(4 * n, Vec3(0, 0, 0, 0))
        sc.pwb.resize(4 * n, Vec3(0, 0, 0, 0))
        sc.dn.resize(4 * n, 0)
        sc.dt1.resize(4 * n, 0)
        sc.dt2.resize(4 * n, 0)
        sc.t1.resize(n, Vec3(0, 0, 0, 0))
        sc.t2.resize(n, Vec3(0, 0, 0, 0))
    for c in range(lo, hi):
        ref pr = pairs[c]
        if bset.impulse_inert(pr.a) and bset.impulse_inert(pr.b):
            continue
        var n = pr.m.normal
        var tb = tangent_basis(n)
        var o = c - lo
        sc.t1[o] = tb[0]
        sc.t2[o] = tb[1]
        for k in range(pr.m.count):
            var pwa = anchor_world(bset, pr.a, pr.ra[k], pr.oa[k], pr.ea, n)
            var pwb = anchor_world(bset, pr.b, pr.rb[k], pr.ob[k], pr.eb, -n)
            var i = 4 * o + k
            sc.pwa[i] = pwa
            sc.pwb[i] = pwb
            sc.dn[i] = _denom(bset, pr, pwa, pwb, n)
            sc.dt1[i] = _denom(bset, pr, pwa, pwb, tb[0])
            sc.dt2[i] = _denom(bset, pr, pwa, pwb, tb[1])


def soft_sweep[B: Body6](
    mut bset: BodySet[B],
    mut pairs: List[ContactConstraint],
    lo: Int,
    hi: Int,
    h: Real,
    bias_rate: Real,
    mass_scale: Real,
    impulse_scale: Real,
    use_bias: Bool,
    iters: Int,
    mu: Real,
    max_push: Real = 4,
):
    """Gauss-Seidel sweeps with Solver2D soft coefficients. `max_push` caps
    the soft push-out speed (m/s, `SolverConfig.max_push_speed`). Separation is
    re-derived per point from the CURRENT poses via body-frame anchors, so
    rotation shows up as differential depth (restoring torque)."""
    var cache = prepare_sweep(bset, pairs, lo, hi)
    soft_sweep_prepared(
        bset, pairs, cache, lo, hi, h, bias_rate, mass_scale, impulse_scale, use_bias, iters, mu, max_push
    )


def soft_sweep_prepared[B: Body6](
    mut bset: BodySet[B],
    mut pairs: List[ContactConstraint],
    cache: SweepCache,
    lo: Int,
    hi: Int,
    h: Real,
    bias_rate: Real,
    mass_scale: Real,
    impulse_scale: Real,
    use_bias: Bool,
    iters: Int,
    mu: Real,
    max_push: Real = 4,
):
    """`soft_sweep` with a `SweepCache` the caller prepared at the current
    poses (ROADMAP 17.99), covering at least `lo ..< hi`."""
    var f = contact_features(bset)
    comptime for F in range(8):
        if f == F:
            for _ in range(iters):
                for c in range(lo, hi):
                    solve_contact[F=F](bset,
                        pairs, cache, c, h, bias_rate, mass_scale, impulse_scale,
                        use_bias, mu, max_push,
                    )


def sweep_colored[B: Body6](
    mut bset: BodySet[B],
    mut pairs: List[ContactConstraint],
    clo: List[Int],
    chi: List[Int],
    h: Real,
    bias_rate: Real,
    mass_scale: Real,
    impulse_scale: Real,
    use_bias: Bool,
    iters: Int,
    mu: Real,
    par: Bool,
    workers: Int = 0,
    dispatch: Dispatch = Dispatch.parallel(),
    max_push: Real = 4,
):
    """Graph-colored sweeps: pairs in one color share no DYNAMIC body
    (statics are excluded from adjacency and never written), so a color
    solves in parallel — Jacobi within the color, Gauss-Seidel across
    colors. The schedule is fixed and same-color writes are disjoint, so
    par=True is bit-identical to par=False (and to any `workers` count)."""
    var f = contact_features(bset)
    var cache = prepare_sweep(bset, pairs, 0, len(pairs))
    comptime for F in range(8):
        if f == F:
            for _ in range(iters):
                for col in range(len(clo)):
                    if par and chi[col] - clo[col] >= 8:
                        solve_color_parallel[F=F](
                            bset, pairs, cache, clo[col], chi[col], h, bias_rate,
                            mass_scale, impulse_scale, use_bias, mu, workers, dispatch, max_push,
                        )
                    else:
                        for c in range(clo[col], chi[col]):
                            solve_contact[F=F](bset,
                                pairs, cache, c, h, bias_rate, mass_scale,
                                impulse_scale, use_bias, mu, max_push,
                            )


def solve_contact[B: Body6, F: Int](
    mut bset: BodySet[B],
    mut pairs: List[ContactConstraint],
    cache: SweepCache,
    c: Int,
    h: Real,
    bias_rate: Real,
    mass_scale: Real,
    impulse_scale: Real,
    use_bias: Bool,
    mu: Real,
    max_push: Real = 4,
):
    """One pair's normal + friction solve (the body of `_soft_sweep`,
    extracted so the colored sweep can schedule it per pair). `F` is
    `contact_features(bset)`, fixed by the caller (the `CF_*` bits)."""
    comptime MODEL = (F & CF_MODEL) != 0
    comptime ELL = (F & CF_ELLIPTIC) != 0
    comptime BLOCK = (F & CF_BLOCK) != 0
    ref pr = pairs[c]
    if bset.impulse_inert(pr.a) and bset.impulse_inert(pr.b):
        return
    var n = pr.m.normal
    # ROADMAP 17.23: the pair's combined friction, computed ONCE per pair
    # (not per point/substep) since it depends only on (a, b), not on the
    # contact geometry -- "cheap per contact" per the spec. `mu` here is
    # `cfg.default_friction`, substituted for either body's coefficient
    # when it never called `set_friction` (`eff_friction`'s docstring);
    # with both bodies unset and the default `COMBINE_AVERAGE` mode,
    # `combine(mu, mu, AVERAGE, AVERAGE) == mu` bit-exactly, so an
    # all-default scene is unchanged from before this existed.
    var pair_mu = combine(
        bset.eff_friction(pr.a, mu),
        bset.eff_friction(pr.b, mu),
        bset.friction_combine[pr.a],
        bset.friction_combine[pr.b],
    )
    var pair_ms = pair_mu
    comptime if MODEL:
        pair_ms = combine(
            bset.eff_static(pr.a, mu),
            bset.eff_static(pr.b, mu),
            bset.friction_combine[pr.a],
            bset.friction_combine[pr.b],
        )
    if pr.mu_override >= 0:
        pair_mu = pr.mu_override
        pair_ms = pr.mu_override
    # ROADMAP 17.50 per-body contact softness: the softer side's (lower
    # hertz) hertz / zeta replace the step's for this pair; the same
    # formulas as `ContactScene6.step`, so equal values are bit-identical.
    var p_bias = bias_rate
    var p_ms = mass_scale
    var p_isc = impulse_scale
    var adh = Real(0)
    comptime if MODEL:
        var ha = bset.contact_hertz[pr.a]
        var hb = bset.contact_hertz[pr.b]
        if ha > 0 or hb > 0:
            var use_a = ha > 0 and (hb <= 0 or ha <= hb)
            var hz = ha if use_a else hb
            var zt = bset.contact_zeta[pr.a] if use_a else bset.contact_zeta[pr.b]
            var om_scale = Real(1)
            if bset.load_stiffness:
                var ia = bset.bodies[pr.a].inv_mass()
                var ib = bset.bodies[pr.b].inv_mass()
                if ia > 0 and ib > 0:
                    om_scale = sqrt(max(ia, ib) / min(ia, ib))  # heavier / lighter mass
            var om = Real(6.283185307179586) * hz * om_scale
            var cc = h * om * (2 * zt + h * om)
            p_bias = om / (2 * zt + h * om)
            p_ms = cc / (1 + cc)
            p_isc = 1 / (1 + cc)
        adh = max(bset.adhesion[pr.a], bset.adhesion[pr.b]) * h / Real(max(pr.m.count, 1))
    if pr.soft_hz > 0:
        # 17.50: the touched triangle's material softness wins over the
        # bodies' (same formulas as `ContactScene6.step`)
        var om = Real(6.283185307179586) * pr.soft_hz
        var cc = h * om * (2 * pr.soft_zeta + h * om)
        p_bias = om / (2 * pr.soft_zeta + h * om)
        p_ms = cc / (1 + cc)
        p_isc = 1 / (1 + cc)
    var conveyor = pr.vsurf[0] != 0 or pr.vsurf[1] != 0 or pr.vsurf[2] != 0
    # ROADMAP 17.50 block solver: all of a manifold's normal impulses at
    # once (a small LCP), then friction per point; one point, adhesion or
    # a singular block stays on the per-point Gauss-Seidel.
    var blk = False
    comptime if BLOCK:
        blk = pr.m.count > 1 and adh == 0
    if blk:
        blk = _block_normal(bset, pr, n, h, p_bias, p_ms, use_bias, max_push)
    # ROADMAP 17.99: anchors, denominators and the tangent basis come from
    # `cache` (`prepare_sweep`, computed once per sweep call from the same
    # poses with the same functions, so the values are bit-identical).
    var co = c - cache.base
    var tb0 = cache.t1[co]
    var tb1 = cache.t2[co]
    for k in range(pr.m.count):
        var ci = 4 * co + k
        var pwa = cache.pwa[ci]
        var pwb = cache.pwb[ci]
        if not blk:
            # anchors coincided at prep with depth d0; separation since
            # then is the anchor drift along the normal
            var d = pr.m.depths[k] - dot(pwb - pwa, n)
            var va = Vec3(0, 0, 0, 0)
            if bset.moves(pr.a):
                va = bset.bodies[pr.a].velocity_at(pwa)
            var vb = Vec3(0, 0, 0, 0)
            if bset.moves(pr.b):
                vb = bset.bodies[pr.b].velocity_at(pwb)
            var denom = cache.dn[ci]
            if denom <= 0:
                continue
            var vn = dot(vb - va, n)
            # Box2D sign convention: separation s = -d (negative when
            # penetrating), bias <= 0 pulls vn upward past zero.
            var bias = Real(0)
            var ms = Real(1)
            var isc = Real(0)
            if d < 0:
                bias = -d / h  # speculative: match approach speed
            elif use_bias:
                bias = max(-p_bias * d, -max_push)
                ms = p_ms
                isc = p_isc
            var raw = -ms * (vn + bias) / denom - isc * pr.acc[k]
            var lo = Real(0)
            if adh > 0 and d > -_ADH_GAP:
                lo = -adh
            var new_acc = max(pr.acc[k] + raw, lo)
            var dl = new_acc - pr.acc[k]
            pr.acc[k] = new_acc
            if dl != 0:
                var j = n * dl
                if bset.is_dynamic(pr.a):
                    bset.bodies[pr.a].apply_impulse(-j * _cs(bset, pr.a), pwa)
                if bset.is_dynamic(pr.b):
                    bset.bodies[pr.b].apply_impulse(j * _cs(bset, pr.b), pwb)
        # Coulomb friction: tangent impulses clamped to pair_mu * lambda_n.
        # an adhesive point's normal impulse may be negative; it gives no grip
        var lam = pr.acc[k] if pr.acc[k] > 0 else Real(0)
        var cap = pair_mu * lam
        comptime if MODEL:
            if (pr.stick >> k) & 1 == 1:
                cap = pair_ms * lam
        # ROADMAP 17.50 elliptic cone: solve both axes unclamped, then
        # project the pair onto the disk |(t1, t2)| <= cap. Below the cap
        # it takes the pyramid's exact steps; cap 0 stays on the pyramid.
        var disk = False
        comptime if ELL:
            disk = cap > 0
        for ti in range(2):
            var t = tb0 if ti == 0 else tb1
            var vat = Vec3(0, 0, 0, 0)
            if bset.moves(pr.a):
                vat = bset.bodies[pr.a].velocity_at(pwa)
            var vbt = Vec3(0, 0, 0, 0)
            if bset.moves(pr.b):
                vbt = bset.bodies[pr.b].velocity_at(pwb)
            var dent = cache.dt1[ci] if ti == 0 else cache.dt2[ci]
            if dent <= 0:
                continue
            var vt = dot(vbt - vat, t)
            if conveyor:
                vt += dot(pr.vsurf, t)
            var acc_t = pr.acc_t1[k] if ti == 0 else pr.acc_t2[k]
            var new_t = acc_t - vt / dent
            if disk:
                pass
            elif new_t > cap:
                new_t = cap
            elif new_t < -cap:
                new_t = -cap
            var dtl = new_t - acc_t
            if ti == 0:
                pr.acc_t1[k] = new_t
            else:
                pr.acc_t2[k] = new_t
            if dtl != 0:
                var jt = t * dtl
                if bset.is_dynamic(pr.a):
                    bset.bodies[pr.a].apply_impulse(-jt * _cs(bset, pr.a), pwa)
                if bset.is_dynamic(pr.b):
                    bset.bodies[pr.b].apply_impulse(jt * _cs(bset, pr.b), pwb)
        if disk:
            var t1 = pr.acc_t1[k]
            var t2 = pr.acc_t2[k]
            var m2 = t1 * t1 + t2 * t2
            if m2 > cap * cap:
                var sc = cap / sqrt(m2)
                pr.acc_t1[k] = t1 * sc
                pr.acc_t2[k] = t2 * sc
                var jt = tb0 * (t1 * sc - t1) + tb1 * (t2 * sc - t2)
                if bset.is_dynamic(pr.a):
                    bset.bodies[pr.a].apply_impulse(-jt * _cs(bset, pr.a), pwa)
                if bset.is_dynamic(pr.b):
                    bset.bodies[pr.b].apply_impulse(jt * _cs(bset, pr.b), pwb)
    comptime if MODEL:
        _solve_rolling(bset, pr, n)


def _block_normal[B: Body6](
    mut bset: BodySet[B], mut pr: ContactConstraint, n: Vec3, h: Real,
    p_bias: Real, p_ms: Real, use_bias: Bool, max_push: Real,
) -> Bool:
    """ROADMAP 17.50 block solver: the normal impulses of a manifold's
    points solved together. A_ij = n·(velocity change at point i per unit
    impulse at point j); the rigid problem x >= 0, w = A x + b >= 0,
    x·w = 0 (b = vn + bias - A·acc) is solved by enumerating active sets
    (largest first), and each point keeps ms_k·x_k -- the per-point soft
    update, which is ms·(acc - (vn + bias) / A_kk), with the full block in
    place of A_kk. False (nothing applied) when the block is singular or no
    active set fits; the caller then runs the per-point sweep."""
    var cnt = pr.m.count
    var pa = List[Vec3](capacity=cnt)
    var pb = List[Vec3](capacity=cnt)
    var ra = List[Vec3](capacity=cnt)
    var rb = List[Vec3](capacity=cnt)
    var b = List[Real](length=cnt, fill=0)
    var ms = List[Real](length=cnt, fill=1)
    var dyn_a = bset.is_dynamic(pr.a)
    var dyn_b = bset.is_dynamic(pr.b)
    # 17.19 mass scale, the same `_cs` the per-point sweep applies to each side:
    # it multiplies the block's effective mass and the impulse it applies
    var wa = _cs(bset, pr.a)
    var wb = _cs(bset, pr.b)
    var pos_a = bset.bodies[pr.a].position()
    var pos_b = bset.bodies[pr.b].position()
    for k in range(cnt):
        var pwa = anchor_world(bset, pr.a, pr.ra[k], pr.oa[k], pr.ea, n)
        var pwb = anchor_world(bset, pr.b, pr.rb[k], pr.ob[k], pr.eb, -n)
        pa.append(pwa)
        pb.append(pwb)
        ra.append(pwa - pos_a)
        rb.append(pwb - pos_b)
        var d = pr.m.depths[k] - dot(pwb - pwa, n)
        var va = Vec3(0, 0, 0, 0)
        var vb = Vec3(0, 0, 0, 0)
        if bset.moves(pr.a):
            va = bset.bodies[pr.a].velocity_at(pwa)
        if bset.moves(pr.b):
            vb = bset.bodies[pr.b].velocity_at(pwb)
        var bias = Real(0)
        if d < 0:
            bias = -d / h
        elif use_bias:
            bias = max(-p_bias * d, -max_push)
            ms[k] = p_ms
        b[k] = dot(vb - va, n) + bias
    # A by polarisation: (ri x n)·I^-1 (rj x n) = (f(ri + rj) - f(ri) - f(rj)) / 2
    var A = List[Real](length=cnt * cnt, fill=0)
    var im = (wa * bset.bodies[pr.a].inv_mass() if dyn_a else Real(0)) + (wb * bset.bodies[pr.b].inv_mass() if dyn_b else Real(0))
    var fa = List[Real](length=cnt, fill=0)
    var fb = List[Real](length=cnt, fill=0)
    for i in range(cnt):
        if dyn_a:
            fa[i] = wa * bset.bodies[pr.a].angular_factor(ra[i], n)
        if dyn_b:
            fb[i] = wb * bset.bodies[pr.b].angular_factor(rb[i], n)
    for i in range(cnt):
        for j in range(i, cnt):
            var v = im
            if i == j:
                v += fa[i] + fb[i]
            else:
                if dyn_a:
                    v += (wa * bset.bodies[pr.a].angular_factor(ra[i] + ra[j], n) - fa[i] - fa[j]) / 2
                if dyn_b:
                    v += (wb * bset.bodies[pr.b].angular_factor(rb[i] + rb[j], n) - fb[i] - fb[j]) / 2
            A[i * cnt + j] = v
            A[j * cnt + i] = v
    # b uses the unregularised A; then eps·I: four coplanar points give a
    # rank-3 A (three velocity DOFs), and the regularised solve picks the
    # least-norm split of the load (equal impulses under a uniform load)
    var tr = Real(0)
    for i in range(cnt):
        if not (A[i * cnt + i] > 1e-12):
            return False
        for j in range(cnt):
            b[i] -= A[i * cnt + j] * pr.acc[j]
        tr += A[i * cnt + i]
    for i in range(cnt):
        A[i * cnt + i] += _BLOCK_EPS * tr / Real(cnt)
    # active sets, largest first (full set = mask 2^cnt - 1)
    var full = (1 << cnt) - 1
    var x = List[Real](length=cnt, fill=0)
    var found = False
    for size in range(cnt, -1, -1):
        for mask in range(full, -1, -1):
            if _popcount(mask) != size:
                continue
            if _block_try(A, b, cnt, mask, x):
                found = True
                break
        if found:
            break
    if not found:
        return False
    for k in range(cnt):
        var na = ms[k] * x[k]
        var dl = na - pr.acc[k]
        pr.acc[k] = na
        if dl != 0:
            var j = n * dl
            if dyn_a:
                bset.bodies[pr.a].apply_impulse(-j * wa, pa[k])
            if dyn_b:
                bset.bodies[pr.b].apply_impulse(j * wb, pb[k])
    return True


def _popcount(m: Int) -> Int:
    var c = 0
    var v = m
    while v > 0:
        c += v & 1
        v >>= 1
    return c


def _block_try(A: List[Real], b: List[Real], cnt: Int, mask: Int, mut x: List[Real]) -> Bool:
    """Solve A_SS x_S = -b_S for the active set `mask` (Gaussian elimination
    with partial pivoting); True when x_S >= 0 and every inactive point's
    w = (A x + b) >= 0."""
    var idx = List[Int]()
    for k in range(cnt):
        if (mask >> k) & 1 == 1:
            idx.append(k)
    var m = len(idx)
    var M = List[Real](length=m * (m + 1), fill=0)
    for r in range(m):
        for c in range(m):
            M[r * (m + 1) + c] = A[idx[r] * cnt + idx[c]]
        M[r * (m + 1) + m] = -b[idx[r]]
    for col in range(m):
        var piv = col
        for r in range(col + 1, m):
            if abs(M[r * (m + 1) + col]) > abs(M[piv * (m + 1) + col]):
                piv = r
        if abs(M[piv * (m + 1) + col]) < 1e-14:
            return False
        if piv != col:
            for c in range(m + 1):
                var t = M[col * (m + 1) + c]
                M[col * (m + 1) + c] = M[piv * (m + 1) + c]
                M[piv * (m + 1) + c] = t
        for r in range(col + 1, m):
            var f = M[r * (m + 1) + col] / M[col * (m + 1) + col]
            for c in range(col, m + 1):
                M[r * (m + 1) + c] -= f * M[col * (m + 1) + c]
    var xs = List[Real](length=m, fill=0)
    for r in range(m - 1, -1, -1):
        var s = M[r * (m + 1) + m]
        for c in range(r + 1, m):
            s -= M[r * (m + 1) + c] * xs[c]
        xs[r] = s / M[r * (m + 1) + r]
        if xs[r] < 0:
            return False
    for k in range(cnt):
        x[k] = 0
    for r in range(m):
        x[idx[r]] = xs[r]
    for k in range(cnt):
        if (mask >> k) & 1 == 0:
            var w = b[k]
            for r in range(m):
                w += A[k * cnt + idx[r]] * xs[r]
            if w < -1e-9 * (1 + abs(b[k])):
                return False
    return True


def _solve_rolling[B: Body6](mut bset: BodySet[B], mut pr: ContactConstraint, n: Vec3):
    """ROADMAP 17.50 rolling and spin resistance: angular impulses on the
    pair's relative angular velocity, its normal part capped at
    `spinning · Σλn` and its tangential part (a disk) at `rolling · Σλn`
    (both coefficients in metres, the larger of the two bodies')."""
    var cr = max(bset.rolling[pr.a], bset.rolling[pr.b])
    var cs = max(bset.spinning[pr.a], bset.spinning[pr.b])
    if cr <= 0 and cs <= 0:
        return
    var lam = Real(0)
    for k in range(pr.m.count):
        lam += max(pr.acc[k], 0)
    if cs > 0:
        var kk = Real(0)
        if bset.is_dynamic(pr.a):
            kk += bset.bodies[pr.a].angular_only_factor(n)
        if bset.is_dynamic(pr.b):
            kk += bset.bodies[pr.b].angular_only_factor(n)
        if kk > 0:
            var w = dot(_omega(bset, pr.b) - _omega(bset, pr.a), n)
            var cap = cs * lam
            var na = min(max(pr.spin_acc - w / kk, -cap), cap)
            var dl = na - pr.spin_acc
            pr.spin_acc = na
            if dl != 0:
                if bset.is_dynamic(pr.a):
                    bset.bodies[pr.a].apply_angular_impulse(n * -dl)
                if bset.is_dynamic(pr.b):
                    bset.bodies[pr.b].apply_angular_impulse(n * dl)
    if cr > 0:
        var tb = tangent_basis(n)
        var wr = _omega(bset, pr.b) - _omega(bset, pr.a)
        var nr = Vec3(0, 0, 0, 0)
        for ti in range(2):
            var t = tb[0] if ti == 0 else tb[1]
            var kk = Real(0)
            if bset.is_dynamic(pr.a):
                kk += bset.bodies[pr.a].angular_only_factor(t)
            if bset.is_dynamic(pr.b):
                kk += bset.bodies[pr.b].angular_only_factor(t)
            var cur = dot(pr.roll_acc, t)
            if kk > 0:
                cur -= dot(wr, t) / kk
            nr = nr + t * cur
        var cap = cr * lam
        var m2 = dot(nr, nr)
        if m2 > cap * cap:
            nr = nr * (cap / sqrt(m2)) if m2 > 0 else nr
        var dl = nr - pr.roll_acc
        pr.roll_acc = nr
        if bset.is_dynamic(pr.a):
            bset.bodies[pr.a].apply_angular_impulse(-dl)
        if bset.is_dynamic(pr.b):
            bset.bodies[pr.b].apply_angular_impulse(dl)


def _omega[B: Body6](bset: BodySet[B], i: Int) -> Vec3:
    if bset.moves(i):
        return bset.bodies[i].omega_world()
    return Vec3(0, 0, 0, 0)


def restitution_pass[B: Body6](
    mut bset: BodySet[B],
    mut pairs: List[ContactConstraint],
    lo: Int,
    hi: Int,
    iters: Int,
    threshold: Real = 1.0,  # m/s approach speed to trigger (SolverConfig
    # .restitution_threshold; default matches the old comptime REST_THRESH)
):
    """Box2D v3 restitution: after the substeps have resolved penetration,
    push each point that arrived faster than the threshold back toward
    `vn = -e·vn0` (its own clamped accumulator, so sweeps can correct)."""
    for _ in range(iters):
        for c in range(lo, hi):
            ref pr = pairs[c]
            # ROADMAP 17.23: combined via each body's own
            # `restitution_combine` (default `COMBINE_MAX` for every
            # body -- `combine`'s docstring), so an all-default scene's
            # `max(a, b)` is bit-identical to before this existed.
            var e = combine(
                bset.restitution[pr.a], bset.restitution[pr.b],
                bset.restitution_combine[pr.a],
                bset.restitution_combine[pr.b],
            )
            if e <= 0:
                continue
            var n = pr.m.normal
            for k in range(pr.m.count):
                if pr.vn0[k] >= -threshold:
                    continue
                var pwa = anchor_world(bset, pr.a, pr.ra[k], pr.oa[k], pr.ea, n)
                var pwb = anchor_world(bset, pr.b, pr.rb[k], pr.ob[k], pr.eb, -n)
                var va = Vec3(0, 0, 0, 0)
                var ka = Real(0)
                if bset.moves(pr.a):
                    va = bset.bodies[pr.a].velocity_at(pwa)
                if bset.is_dynamic(pr.a):
                    ka = bset.bodies[pr.a].inv_mass() + bset.bodies[
                        pr.a
                    ].angular_factor(pwa - bset.bodies[pr.a].position(), n)
                var vb = Vec3(0, 0, 0, 0)
                var kb = Real(0)
                if bset.moves(pr.b):
                    vb = bset.bodies[pr.b].velocity_at(pwb)
                if bset.is_dynamic(pr.b):
                    kb = bset.bodies[pr.b].inv_mass() + bset.bodies[
                        pr.b
                    ].angular_factor(pwb - bset.bodies[pr.b].position(), n)
                ka *= _cs(bset, pr.a)
                kb *= _cs(bset, pr.b)
                var denom = ka + kb
                if denom <= 0:
                    continue
                var vn = dot(vb - va, n)
                var target = -e * pr.vn0[k]
                var new_acc = max(pr.racc[k] + (target - vn) / denom, 0)
                var dl = new_acc - pr.racc[k]
                pr.racc[k] = new_acc
                if dl != 0:
                    var j = n * dl
                    if bset.is_dynamic(pr.a):
                        bset.bodies[pr.a].apply_impulse(-j * _cs(bset, pr.a), pwa)
                    if bset.is_dynamic(pr.b):
                        bset.bodies[pr.b].apply_impulse(j * _cs(bset, pr.b), pwb)


struct _ColorTask[B: Body6, F: Int](Task):
    """One same-colour pair per item: no two share a dynamic body."""

    var bset: Pointer[BodySet[Self.B], MutUntrackedOrigin]
    var pairs2: Pointer[List[ContactConstraint], MutUntrackedOrigin]
    var cache: Pointer[SweepCache, MutUntrackedOrigin]
    var lo: Int
    var h: Real
    var bias_rate: Real
    var mass_scale: Real
    var impulse_scale: Real
    var use_bias: Bool
    var mu: Real
    var max_push: Real

    def __init__(
        out self, mut bset: BodySet[Self.B], mut pairs2: List[ContactConstraint], mut cache: SweepCache, lo: Int,
        h: Real, bias_rate: Real, mass_scale: Real, impulse_scale: Real, use_bias: Bool, mu: Real,
        max_push: Real,
    ):
        self.bset = Pointer(to=bset).unsafe_origin_cast[MutUntrackedOrigin]()
        self.pairs2 = Pointer(to=pairs2).unsafe_origin_cast[MutUntrackedOrigin]()
        self.cache = Pointer(to=cache).unsafe_origin_cast[MutUntrackedOrigin]()
        self.lo = lo
        self.h = h
        self.bias_rate = bias_rate
        self.mass_scale = mass_scale
        self.impulse_scale = impulse_scale
        self.use_bias = use_bias
        self.mu = mu
        self.max_push = max_push

    def run(self, k: Int):
        solve_contact[F=Self.F](
            self.bset[], self.pairs2[], self.cache[], self.lo + k, self.h, self.bias_rate, self.mass_scale,
            self.impulse_scale, self.use_bias, self.mu, self.max_push,
        )


def solve_color_parallel[B: Body6, F: Int](
    mut bset: BodySet[B],
    mut pairs2: List[ContactConstraint],
    mut cache: SweepCache,
    lo: Int,
    hi: Int,
    h: Real,
    bias_rate: Real,
    mass_scale: Real,
    impulse_scale: Real,
    use_bias: Bool,
    mu: Real,
    workers: Int = 0,
    dispatch: Dispatch = Dispatch.parallel(),
    max_push: Real = 4,
):
    """Solve one color's pairs as `_ColorTask` items run by `dispatch`
    (ROADMAP 17.75). Same-color pairs share no dynamic body, so the writes
    are disjoint and the result is bit-identical to solving the color
    serially, whoever runs the items."""
    var task = _ColorTask[B, F](bset, pairs2, cache, lo, h, bias_rate, mass_scale, impulse_scale, use_bias, mu, max_push)
    dispatch_for(dispatch, task, hi - lo, workers)


# ------------------------------------------------------ contact modification

comptime RULE_ONE_WAY = 0  # body passes through from the far side of `dir`
comptime RULE_CONVEYOR = 1  # body's surface moves at `dir` (m/s)
comptime RULE_FRICTION = 2  # contacts of body use friction `value`


@fieldwise_init
struct ContactRule(Copyable, ImplicitlyCopyable, Movable):
    """A per-contact rule on one body, applied to that frame's contacts
    after collection (ROADMAP 17.26). ONE_WAY: a contact with `body` counts
    only when its normal toward the other body is within 60 degrees of
    `dir`, the other body is not moving along `dir` faster than 0.1 m/s,
    and it has not sunk deeper than `value` into the platform -- so a body
    passes up through it and lands on it from above. CONVEYOR: friction
    drags toward `body`'s surface moving at `dir`. FRICTION: contacts of
    `body` use coefficient `value` instead of the combined one."""

    var kind: Int
    var body: Int
    var dir: Vec3
    var value: Real


def apply_rules[B: Body6](
    bset: BodySet[B], rules: List[ContactRule], mut pairs: List[ContactConstraint]
):
    """Drop or modify this frame's contacts according to `rules`. With no
    rules nothing is touched (the parity with the unmodified solver)."""
    if len(rules) == 0:
        return
    var kept = List[ContactConstraint](capacity=len(pairs))
    for c in range(len(pairs)):
        ref pr = pairs[c]
        var keep = True
        for r in range(len(rules)):
            ref ru = rules[r]
            var on_a = pr.a == ru.body
            var on_b = pr.b == ru.body
            if not on_a and not on_b:
                continue
            match ru.kind:
                case == RULE_ONE_WAY:
                    # normal from the platform toward the other body
                    var n = pr.m.normal if on_a else -pr.m.normal
                    var other = pr.b if on_a else pr.a
                    var up_v = Real(0)
                    if bset.moves(other):
                        up_v = dot(bset.bodies[other].linear_velocity(), ru.dir)
                    var deepest = Real(0)
                    for k in range(pr.m.count):
                        deepest = max(deepest, pr.m.depths[k])
                    if dot(n, ru.dir) < 0.5 or up_v > 0.1 or deepest > ru.value:
                        keep = False
                case == RULE_CONVEYOR:
                    # relative surface velocity of b w.r.t. a, tangential part
                    var u = ru.dir if on_b else -ru.dir
                    var nn = pr.m.normal
                    pr.vsurf = pr.vsurf + (u - nn * dot(u, nn))
                case == RULE_FRICTION:
                    pr.mu_override = ru.value
        if keep:
            kept.append(pr)
    pairs = kept^
