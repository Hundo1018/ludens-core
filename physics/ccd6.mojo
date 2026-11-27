"""Second-stage continuous collision (audit F11, cluster 11): swept-box TOI
pose advance, a free function over a `BodySet` view and the `ColliderSet`
(for shape kinds, filters and sensors), composed by `ContactScene6`.
"""

from std.math import sqrt
from geometry.vec import Real, Vec3, dot, length
from geometry.quat import Quat
from geometry.aabb import AABB
from collision.collider_set import (
    ColliderSet,
    Pose3,
    ShapeDesc,
    SHAPE_BOX,
    SHAPE_SPHERE,
    SHAPE_CAPSULE,
    SHAPE_HULL,
    SHAPE_TRIMESH,
    SHAPE_HEIGHTFIELD,
    SHAPE_SDF,
    SHAPE_COMPOUND,
)
from collision.world_query import desc_distance, kid_distance, shape_distance, QueryShape
from spatial.bvh import BVH
from collision.toi import swept_box_toi
from .rigid6 import Body6
from .body_set import BodySet
from scheduler.dispatch import Dispatch, Task, dispatch_for

comptime CCD_PAR_MIN = 64
"""Fewest fast movers for which `ccd_advance` fans out (ROADMAP 17.54)."""


comptime _CA_TOL: Real = 0.005  # stop conservative advancement this far from contact
comptime _CA_ITERS = 32
comptime _CCD_BACKOFF: Real = 0.01  # clamped fraction is backed off by this much (of the substep)


comptime CCD_AUTO = 0  # swept when the step's cfg.ccd is on (the default)
comptime CCD_OFF = 1  # never clamped (still an obstacle for others)
comptime CCD_BULLET = 2  # always swept, even with cfg.ccd off, every candidate


def _is_box_like(k: Int) -> Bool:
    """Kinds the closed-form swept box TOI handles (sphere / capsule by
    their conservative box, as before 17.46)."""
    return k == SHAPE_BOX or k == SHAPE_SPHERE or k == SHAPE_CAPSULE


def _is_static_mesh(k: Int) -> Bool:
    return k == SHAPE_TRIMESH or k == SHAPE_HEIGHTFIELD


def _pose_at[B: Body6](bset: BodySet[B], i: Int, t: Real, h: Real) -> Pose3:
    """Body `i`'s pose at fraction `t` of the substep: its centre moved by
    v h t, its orientation turned by w h t (constant velocities)."""
    var p = bset.bodies[i].position()
    var q = bset.bodies[i].rotation()
    if not bset.inactive(i):
        p = p + bset.bodies[i].linear_velocity() * (h * t)
        var w = bset.bodies[i].omega_world()
        var wl = length(w)
        if wl * h * t > 1e-12:
            q = Quat.from_axis_angle(w / wl, wl * h * t) * q
    var ax = Array[Vec3, 3](fill=Vec3(0, 0, 0, 0))
    ax[0] = q.rotate(Vec3(1, 0, 0, 0))
    ax[1] = q.rotate(Vec3(0, 1, 0, 0))
    ax[2] = q.rotate(Vec3(0, 0, 1, 0))
    return Pose3(p, ax^)


def _dist_at[B: Body6](
    bset: BodySet[B], cs: ColliderSet, i: Int, j: Int, t: Real, h: Real, reach: Real
) -> Tuple[Real, Vec3, Vec3, Vec3]:
    """(distance, unit normal from i toward j, witness on i, witness on j)
    between bodies `i` and `j` at fraction `t`: the nearest child pair, or
    the nearest of `i`'s children to the candidate triangles within `reach`
    when `j` is a static mesh."""
    var pi = _pose_at(bset, i, t, h)
    var best = Real(1e30)
    var nrm = Vec3(0, 1, 0, 0)
    var wa = pi.position
    var wb = pi.position
    if cs.shape[j] == SHAPE_SDF:
        # 17.46: each child's core points (+ radius) sampled in the grid
        # (`world_query.shape_distance`): exact for a sphere / capsule core,
        # the vertex distance for a box or hull -- a convex shape meets a
        # locally flat surface first at a vertex
        var pj = _pose_at(bset, j, t, h)
        for a in range(cs.kid_count(i)):
            var da = cs.kid(i, a)
            var pa = cs.kid_pose(i, a, pi)
            var pts = List[Vec3]()
            var rad = Real(0)
            if da.kind == SHAPE_HULL:
                var poly = cs.hull_world_d(da, pa)
                for v in range(len(poly.points)):
                    pts.append(poly.points[v])
            elif da.kind == SHAPE_SPHERE or da.kind == SHAPE_CAPSULE:
                var core = QueryShape(da.kind, da.half, List[Vec3]()).core(pa)
                pts = core[0].copy()
                rad = core[1]
            else:  # box; an ellipsoid by its box
                pts = QueryShape.box(da.half).core(pa)[0].copy()
            var r = shape_distance(cs, j, pj, pts, rad)[0]
            if r.dist < best:
                best = r.dist
                nrm = r.normal
                wa = r.pa
                wb = r.pb
        return (best, nrm, wa, wb)
    if _is_static_mesh(cs.shape[j]):
        for a in range(cs.kid_count(i)):
            var da = cs.kid(i, a)
            var pa = cs.kid_pose(i, a, pi)
            var tris = List[Int]()
            cs.mesh_candidates(j, cs.kid_box(da, pa, reach), tris)
            for c in range(len(tris)):
                var r = kid_distance(cs, cs.mesh_tri(j, tris[c]), 0, da, pa)
                if r.dist < best:
                    best = r.dist
                    nrm = -r.normal  # kid_distance's normal runs triangle -> child
                    wa = r.pb
                    wb = r.pa
        return (best, nrm, wa, wb)
    var pj = _pose_at(bset, j, t, h)
    for a in range(cs.kid_count(i)):
        var da = cs.kid(i, a)
        var pa = cs.kid_pose(i, a, pi)
        for b in range(cs.kid_count(j)):
            var r = desc_distance(cs, da, pa, cs.kid(j, b), cs.kid_pose(j, b, pj))
            if r.dist < best:
                best = r.dist
                nrm = r.normal
                wa = r.pa
                wb = r.pb
    return (best, nrm, wa, wb)


def ca_fraction[B: Body6](bset: BodySet[B], cs: ColliderSet, i: Int, j: Int, h: Real) -> Real:
    """Time of impact (fraction of the substep, 1 = none) of bodies `i` and
    `j` by conservative advancement (Mirtich 1996) on the exact convex
    distance (ROADMAP 17.46): any convex kinds, compound children, and the
    triangles of a static mesh. Each step advances by distance / (closing
    speed along the separating normal + |w_i| r_i + |w_j| r_j), which never
    passes the first contact for constant velocities. A pair already within
    `_CA_TOL` and not closing (resting, sliding) is not clamped."""
    var vi = bset.bodies[i].linear_velocity()
    var vj = Vec3(0, 0, 0, 0)
    var wj = Real(0)
    var rj = Real(0)
    if not bset.inactive(j):
        vj = bset.bodies[j].linear_velocity()
        wj = length(bset.bodies[j].omega_world())
        rj = length(cs.half[j])
    var hi = cs.half[i]
    if cs.shape[i] == SHAPE_CAPSULE:
        hi[1] += hi[0]
    var ang = (length(bset.bodies[i].omega_world()) * length(hi) + wj * rj) * h
    var rel = (vi - vj) * h
    var reach = length(rel) + ang + _CA_TOL
    var t = Real(0)
    for it in range(_CA_ITERS):
        var dn = _dist_at(bset, cs, i, j, t, h, reach)
        var closing = dot(rel, dn[1]) + ang
        if dn[0] <= _CA_TOL:
            if it == 0:
                # touching at the start: clamp only if the two witness points
                # actually approach along the normal (the |w| r bound is
                # unsigned and would freeze a body turning away)
                var va = bset.bodies[i].velocity_at(dn[2])
                var vb = Vec3(0, 0, 0, 0)
                if not bset.inactive(j):
                    vb = bset.bodies[j].velocity_at(dn[3])
                if dot(va - vb, dn[1]) * h <= _CA_TOL:
                    return 1  # resting, sliding or parting: the contact solver owns it
            return t
        if closing <= 1e-12:
            return 1
        t += (dn[0] - _CA_TOL * 0.5) / closing
        if t >= 1:
            return 1
    return t


def ccd_advance[B: Body6](
    mut bset: BodySet[B], colliders: ColliderSet, h: Real, all_bodies: Bool = True,
    par: Bool = False, workers: Int = 0, dispatch: Dispatch = Dispatch.parallel(),
):
    """Swept/TOI pose advance (second-stage CCD, Jolt LinearCast
    direction): a body whose relative travel this substep could jump the
    thinnest feature of a pair advances only to the time of impact, minus a
    hair of back-off -- the speculative solver then removes the approach
    velocity with the pair already AT the surface, so the midplane can
    never be crossed. Slow bodies take the plain pose step, bit-identical
    to the non-CCD path (zero-regression guarantee). Clamp fractions are
    decided against the substep-start snapshot before any pose moves, so
    mutually-approaching fast pairs resolve symmetrically.

    Two TOI solvers (ROADMAP 17.46):
    - box / sphere / capsule pairs keep the closed-form swept box
      (`swept_box_toi`; sphere and capsule by their conservative box);
    - any pair with a hull, ellipsoid, compound or static mesh uses
      conservative advancement on the exact convex distance (`ca_fraction`,
      angular motion bounded by |w| r).
    An SDF collider (static) is met through the grid distance of the mover's
    core points (17.46, `_dist_at`). Candidates come from a BVH over every
    body's swept box (its box at the start and at the end of the substep,
    grown by its rotation radius) instead of the all-pairs loop.
    `should_collide` / sensors are consulted, so a filtered or sensor pair
    is never clamped (17.0f / F4c).

    Per-body modes (17.46, `BodySet.ccd_mode`): CCD_OFF bodies are never
    clamped; CCD_BULLET bodies are swept even when `all_bodies` is False
    (the step's cfg.ccd off) and against every candidate, without the
    "cannot jump the thinnest feature" shortcut.

    `par` (ROADMAP 17.54, `SolverConfig.parallel_collision`): with at least
    `CCD_PAR_MIN` fast movers their clamp fractions are computed through
    `dispatch`, bit-identical to the serial loop."""
    var n = len(bset.bodies)
    var all = List[Int](capacity=n)
    for i in range(n):
        all.append(i)
    _ccd_core(bset, colliders, h, all_bodies, all, all, par, workers, dispatch)


def ccd_advance_island[B: Body6](
    mut bset: BodySet[B], colliders: ColliderSet, h: Real, all_bodies: Bool,
    members: List[Int], mlo: Int, mhi: Int,
):
    """`ccd_advance` for one island of the island-parallel step (17.46):
    only the island's members move, and their candidates are the island's
    members plus the static bodies -- static poses never change during the
    step, so islands running in parallel read nothing another island
    writes. A pair from two islands has no contact this step (a speculative
    contact would have joined the islands), so it is not swept. For a body
    against static geometry the result is the serial `ccd_advance`'s."""
    var movers = List[Int](capacity=mhi - mlo)
    for m in range(mlo, mhi):
        movers.append(members[m])
    var pool = movers.copy()
    for j in range(len(bset.bodies)):
        if bset.is_static(j) and not bset.is_removed(j):
            pool.append(j)
    sort(pool)
    _ccd_core(bset, colliders, h, all_bodies, movers, pool)


def _ccd_core[B: Body6](
    mut bset: BodySet[B], colliders: ColliderSet, h: Real, all_bodies: Bool,
    movers: List[Int], pool: List[Int],
    par: Bool = False, workers: Int = 0, dispatch: Dispatch = Dispatch.parallel(),
):
    """The body of `ccd_advance`: clamp fractions for `movers` against the
    candidates in `pool` (ascending), then advance the movers' poses."""
    var n = len(bset.bodies)
    var frac = List[Real](length=n, fill=1)
    var fast = List[Bool](length=n, fill=False)
    var any_fast = False
    for i in movers:
        var f = False
        var mode = Int(bset.ccd_mode[i])
        var wanted = mode == CCD_BULLET or (all_bodies and mode != CCD_OFF)
        if wanted and not bset.inactive(i) and colliders.shape[i] != SHAPE_SDF and not _is_static_mesh(colliders.shape[i]):
            var vi = bset.bodies[i].linear_velocity()
            var spin = length(bset.bodies[i].omega_world()) * length(colliders.half[i]) * h
            f = dot(vi, vi) * h * h >= 1e-12 or spin * spin >= 1e-12
        fast[i] = f
        any_fast = any_fast or f
    if any_fast:
        var boxes = List[AABB[3]](capacity=len(pool))
        var ids = List[Int](capacity=len(pool))
        var box_of = List[Int](length=n, fill=-1)
        for j in pool:
            var b0 = colliders.fat_aabb(j, bset.pose3(j), Vec3(0, 0, 0, 0), 0)
            if not bset.inactive(j) and not _is_static_mesh(colliders.shape[j]) and colliders.shape[j] != SHAPE_SDF:
                var hj = colliders.half[j]
                var rr = length(hj) + length(Vec3(0, hj[0], 0, 0))
                var grow = length(bset.bodies[j].omega_world()) * rr * h
                var d = bset.bodies[j].linear_velocity() * h
                var lo = Vec3(min(b0.min[0], b0.min[0] + d[0]), min(b0.min[1], b0.min[1] + d[1]), min(b0.min[2], b0.min[2] + d[2]), 0)
                var hi = Vec3(max(b0.max[0], b0.max[0] + d[0]), max(b0.max[1], b0.max[1] + d[1]), max(b0.max[2], b0.max[2] + d[2]), 0)
                b0 = AABB[3](lo - Vec3(grow, grow, grow, 0), hi + Vec3(grow, grow, grow, 0))
            box_of[j] = len(boxes)
            boxes.append(b0)
            ids.append(j)
        var bvh = BVH[3]()
        bvh.build_boxes(boxes, ids)
        var fl = List[Int]()
        for i in movers:
            if fast[i]:
                fl.append(i)
        if par and len(fl) >= CCD_PAR_MIN:
            var task = _FracTask[B](bset, colliders, bvh, boxes, box_of, fl, frac, h)
            dispatch_for(dispatch, task, len(fl), workers)
        else:
            for i in fl:
                frac[i] = _mover_frac(bset, colliders, h, bvh, boxes, box_of, i)
        # the task reads these through untracked pointers: keep them alive
        # past `dispatch_for` (their last tracked use is before it)
        _ = fl^
        _ = boxes^
        _ = box_of^
        _ = bvh^
    for i in movers:
        if bset.inactive(i):
            continue
        var f = frac[i]
        if f < 1:
            f = max(f - _CCD_BACKOFF, 0)
        bset.bodies[i].integrate_pose(h * f)


def _mover_frac[B: Body6](
    bset: BodySet[B], colliders: ColliderSet, h: Real, bvh: BVH[3],
    boxes: List[AABB[3]], box_of: List[Int], i: Int,
) -> Real:
    """Clamp fraction of fast mover `i` against its swept-box candidates
    (reads only; the serial loop and `_FracTask` both call it)."""
    var best = Real(1)
    var ki = colliders.shape[i]
    var bullet = bset.ccd_mode[i] == CCD_BULLET
    var vi = bset.bodies[i].linear_velocity()
    var cand = List[Int]()
    bvh.query_region(boxes[box_of[i]], cand)
    for c in range(len(cand)):
        var j = cand[c]
        if j == i:
            continue
        if not colliders.should_collide(i, j):
            continue
        if colliders.is_sensor(i) or colliders.is_sensor(j):
            continue
        if not bset.is_dynamic(i) and not bset.is_dynamic(j):
            # ROADMAP 17.24: static-kinematic and kinematic-kinematic
            # pairs produce no DISCRETE contact either (`_collect_pairs`)
            # -- CCD must agree.
            continue
        var kj = colliders.shape[j]
        var vj = Vec3(0, 0, 0, 0)
        if not bset.inactive(j):
            vj = bset.bodies[j].linear_velocity()
        var rel = (vi - vj) * h
        var ha = colliders.half[i]
        var hb = colliders.half[j]
        var thin = min(ha[0], min(ha[1], ha[2]))
        if not _is_static_mesh(kj):
            thin = min(thin, min(hb[0], min(hb[1], hb[2])))
        if _is_box_like(ki) and _is_box_like(kj):
            if not bullet and dot(rel, rel) <= (thin * 0.5) * (thin * 0.5):
                continue  # cannot jump the pair's thinnest feature
            var r = swept_box_toi(
                bset.bodies[j].position(),
                bset.axes(j),
                hb,
                bset.bodies[i].position(),
                bset.axes(i),
                ha,
                rel,
            )
            if r.hit and r.t <= _CCD_BACKOFF:
                # The clamp would leave this body no motion at all (the
                # back-off eats the whole fraction), rotation included. The
                # swept box ignores rotation, so when the pair turns farther
                # this substep than it travels linearly, the discrete
                # contact (which sees the rotation) may be separating it:
                # freezing it would repeat every step and the body would
                # hang there (ROADMAP 17.19, `test_solver_stress` `_mixed`,
                # `test_ccd6` spinning bullet).
                var turn = length(bset.bodies[i].omega_world()) * length(ha) * h
                if not bset.inactive(j):
                    turn += length(bset.bodies[j].omega_world()) * length(hb) * h
                if turn * turn > dot(rel, rel):
                    continue
            if r.hit and r.t < best:
                best = r.t
        else:
            # linear travel or the tip's turn this substep
            var spin = length(bset.bodies[i].omega_world()) * length(ha) * h
            if not bullet and dot(rel, rel) + spin * spin <= (thin * 0.5) * (thin * 0.5):
                continue
            var f = ca_fraction(bset, colliders, i, j, h)
            if f < best:
                best = f
    return best


struct _FracTask[B: Body6](Task):
    """ROADMAP 17.54: one fast mover's clamp fraction per item; each item
    writes only its own `frac` slot, so any schedule gives the serial
    result bit for bit."""

    var bset: Pointer[BodySet[Self.B], MutUntrackedOrigin]
    var col: Pointer[ColliderSet, ImmUntrackedOrigin]
    var bvh: Pointer[BVH[3], ImmUntrackedOrigin]
    var boxes: Pointer[List[AABB[3]], ImmUntrackedOrigin]
    var box_of: Pointer[List[Int], ImmUntrackedOrigin]
    var fl: Pointer[List[Int], ImmUntrackedOrigin]
    var frac: Pointer[List[Real], MutUntrackedOrigin]
    var h: Real

    def __init__(
        out self, mut bset: BodySet[Self.B], col: ColliderSet, bvh: BVH[3], boxes: List[AABB[3]],
        box_of: List[Int], fl: List[Int], mut frac: List[Real], h: Real,
    ):
        self.bset = Pointer(to=bset).unsafe_origin_cast[MutUntrackedOrigin]()
        self.col = Pointer(to=col).unsafe_origin_cast[ImmUntrackedOrigin]()
        self.bvh = Pointer(to=bvh).unsafe_origin_cast[ImmUntrackedOrigin]()
        self.boxes = Pointer(to=boxes).unsafe_origin_cast[ImmUntrackedOrigin]()
        self.box_of = Pointer(to=box_of).unsafe_origin_cast[ImmUntrackedOrigin]()
        self.fl = Pointer(to=fl).unsafe_origin_cast[ImmUntrackedOrigin]()
        self.frac = Pointer(to=frac).unsafe_origin_cast[MutUntrackedOrigin]()
        self.h = h

    def run(self, k: Int):
        var i = self.fl[][k]
        self.frac[][i] = _mover_frac(self.bset[], self.col[], self.h, self.bvh[], self.boxes[], self.box_of[], i)
