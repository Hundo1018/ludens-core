"""Parallel narrowphase and contact prep (ROADMAP 17.54).

`ContactScene6._collect_pairs` enumerates candidate pairs in the canonical
(i < j) ascending order the Gauss-Seidel solve and the warm start depend on
(`collision.contact_gen.collect_bp_pairs`). Both stages here keep that
order exactly, so the output is bit-identical to the serial loop for any
worker count and any `Dispatch`:

  * narrowphase: the candidate list is cut into fixed chunks; each item runs
    `try_pair` over one chunk into its own buffers, and the buffers are
    concatenated in chunk order afterwards. `try_pair` only reads the
    colliders, poses and velocities.
  * prep: `make_contact` per raw contact, written to its own slot. It reads
    the body set, the colliders and last frame's cache.

Both run through `scheduler.dispatch` (17.75), so a host job system can run
the items. Below `NARROW_PAR_MIN` candidates the caller stays serial (the
fan-out costs more than it saves; `bench_collide_par` measures where).
"""

from std.collections import Dict
from std.os import abort
from scheduler.dispatch import Dispatch, Task, dispatch_for
from geometry.vec import Real, Vec3
from collision.collider_set import ColliderSet, Pose3
from collision.contact_gen import RawContact, try_pair
from collision.broadphase import BroadPhase, BoxProxy, Pair
from geometry.aabb import AABB
from .rigid6 import Body6
from .body_set import BodySet
from .contact6 import ContactConstraint, make_contact, make_sensor_contact

comptime NARROW_PAR_MIN = 256
"""Fewest candidate pairs for which `_collect_pairs` fans out (64 box
pairs cost 0.6 ms more with 4 workers than serially, `bench_collide_par`)."""
comptime _CHUNK_MIN = 16
comptime BP_PAR_MIN = 1024
"""Fewest bodies for which `_collect_pairs` queries broadphase candidates in
parallel (`bench_collide_par`)."""


struct _NarrowTask(Task):
    var col: Pointer[ColliderSet, MutUntrackedOrigin]
    var poses: Pointer[List[Pose3], MutUntrackedOrigin]
    var vels: Pointer[List[Vec3], MutUntrackedOrigin]
    var spins: Pointer[List[Real], MutUntrackedOrigin]
    var ci: Pointer[List[Int], MutUntrackedOrigin]
    var cj: Pointer[List[Int], MutUntrackedOrigin]
    var outs: Pointer[List[List[RawContact]], MutUntrackedOrigin]
    var souts: Pointer[List[List[RawContact]], MutUntrackedOrigin]
    var counts: Pointer[List[Int], MutUntrackedOrigin]
    var scounts: Pointer[List[Int], MutUntrackedOrigin]
    var chunk: Int
    var spec_dt: Real
    var margin_base: Real

    def __init__(
        out self,
        mut col: ColliderSet,
        mut poses: List[Pose3],
        mut vels: List[Vec3],
        mut spins: List[Real],
        mut ci: List[Int],
        mut cj: List[Int],
        mut outs: List[List[RawContact]],
        mut souts: List[List[RawContact]],
        mut counts: List[Int],
        mut scounts: List[Int],
        chunk: Int,
        spec_dt: Real,
        margin_base: Real,
    ):
        self.col = Pointer(to=col).unsafe_origin_cast[MutUntrackedOrigin]()
        self.poses = Pointer(to=poses).unsafe_origin_cast[MutUntrackedOrigin]()
        self.vels = Pointer(to=vels).unsafe_origin_cast[MutUntrackedOrigin]()
        self.spins = Pointer(to=spins).unsafe_origin_cast[MutUntrackedOrigin]()
        self.ci = Pointer(to=ci).unsafe_origin_cast[MutUntrackedOrigin]()
        self.cj = Pointer(to=cj).unsafe_origin_cast[MutUntrackedOrigin]()
        self.outs = Pointer(to=outs).unsafe_origin_cast[MutUntrackedOrigin]()
        self.souts = Pointer(to=souts).unsafe_origin_cast[MutUntrackedOrigin]()
        self.counts = Pointer(to=counts).unsafe_origin_cast[MutUntrackedOrigin]()
        self.scounts = Pointer(to=scounts).unsafe_origin_cast[MutUntrackedOrigin]()
        self.chunk = chunk
        self.spec_dt = spec_dt
        self.margin_base = margin_base

    def run(self, k: Int):
        var lo = k * self.chunk
        var hi = min(lo + self.chunk, len(self.ci[]))
        var o = List[RawContact]()
        var so = List[RawContact]()
        for c in range(lo, hi):
            var i = self.ci[][c]
            var j = self.cj[][c]
            var n0 = len(o)
            var s0 = len(so)
            try_pair(
                self.col[], i, j, self.poses[][i], self.poses[][j],
                self.vels[][i], self.vels[][j], self.spec_dt, o, so, self.margin_base,
                self.spins[][i], self.spins[][j],
            )
            self.counts[][c] = len(o) - n0
            self.scounts[][c] = len(so) - s0
        self.outs[][k] = o^
        self.souts[][k] = so^


def narrow_parallel(
    mut colliders: ColliderSet,
    mut poses: List[Pose3],
    mut vels: List[Vec3],
    mut ci: List[Int],
    mut cj: List[Int],
    spec_dt: Real,
    margin_base: Real,
    mut raws: List[RawContact],
    mut sraws: List[RawContact],
    mut counts: List[Int],
    mut scounts: List[Int],
    workers: Int,
    dispatch: Dispatch,
    mut spins: List[Real],
):
    """`try_pair` over candidates (ci[c], cj[c]) in chunks, appended to
    `raws` / `sraws` in candidate order (bit-identical to the serial loop).
    `counts[c]` / `scounts[c]` (pre-sized to the candidate count) receive
    how many contacts candidate c produced. `colliders`, `poses`, `vels` and
    `spins` (the |w| r part of each vel's length, 17.100) are only read."""
    var n = len(ci)
    if n == 0:
        return
    var chunk = max(_CHUNK_MIN, n // 256)
    var nchunk = (n + chunk - 1) // chunk
    var outs = List[List[RawContact]](capacity=nchunk)
    var souts = List[List[RawContact]](capacity=nchunk)
    for _ in range(nchunk):
        outs.append(List[RawContact]())
        souts.append(List[RawContact]())
    var task = _NarrowTask(colliders, poses, vels, spins, ci, cj, outs, souts, counts, scounts, chunk, spec_dt, margin_base)
    dispatch_for(dispatch, task, nchunk, workers)
    for k in range(nchunk):
        for c in range(len(outs[k])):
            raws.append(outs[k][c].copy())
        for c in range(len(souts[k])):
            sraws.append(souts[k][c].copy())


struct _PrepTask[B: Body6](Task):
    var bset: Pointer[BodySet[Self.B], MutUntrackedOrigin]
    var col: Pointer[ColliderSet, MutUntrackedOrigin]
    var cache: Pointer[List[ContactConstraint], MutUntrackedOrigin]
    var cidx: Pointer[Dict[Int, Int], MutUntrackedOrigin]
    var raws: Pointer[List[RawContact], MutUntrackedOrigin]
    var out: Pointer[List[ContactConstraint], MutUntrackedOrigin]
    var warm: Bool
    var match_scale: Real

    def __init__(
        out self,
        mut bset: BodySet[Self.B],
        mut col: ColliderSet,
        mut cache: List[ContactConstraint],
        mut cidx: Dict[Int, Int],
        mut raws: List[RawContact],
        mut out: List[ContactConstraint],
        warm: Bool,
        match_scale: Real,
    ):
        self.bset = Pointer(to=bset).unsafe_origin_cast[MutUntrackedOrigin]()
        self.col = Pointer(to=col).unsafe_origin_cast[MutUntrackedOrigin]()
        self.cache = Pointer(to=cache).unsafe_origin_cast[MutUntrackedOrigin]()
        self.cidx = Pointer(to=cidx).unsafe_origin_cast[MutUntrackedOrigin]()
        self.raws = Pointer(to=raws).unsafe_origin_cast[MutUntrackedOrigin]()
        self.out = Pointer(to=out).unsafe_origin_cast[MutUntrackedOrigin]()
        self.warm = warm
        self.match_scale = match_scale

    def run(self, c: Int):
        self.out[][c] = make_contact(self.bset[], self.col[], self.cache[], self.cidx[], self.raws[][c], self.warm, self.match_scale)


def prep_parallel[B: Body6](
    mut bset: BodySet[B],
    mut colliders: ColliderSet,
    mut cache: List[ContactConstraint],
    mut cidx: Dict[Int, Int],
    mut raws: List[RawContact],
    warm: Bool,
    workers: Int,
    dispatch: Dispatch,
    match_scale: Real = 1,
) -> List[ContactConstraint]:
    """`make_contact` for every raw contact, each into its own slot (the
    same list the serial loop builds). Nothing passed in is written."""
    var out = List[ContactConstraint](capacity=len(raws))
    for c in range(len(raws)):
        out.append(make_sensor_contact(raws[c]))
    var task = _PrepTask[B](bset, colliders, cache, cidx, raws, out, warm, match_scale)
    dispatch_for(dispatch, task, len(raws), workers)
    return out^



struct _BpTask[BP: BroadPhase](Task):
    var bp: Pointer[Self.BP, MutUntrackedOrigin]
    var boxes: Pointer[List[AABB[Self.BP.dim]], MutUntrackedOrigin]
    var statics: Pointer[List[Bool], MutUntrackedOrigin]
    var outs: Pointer[List[List[Pair]], MutUntrackedOrigin]
    var skip: Pointer[List[Bool], MutUntrackedOrigin]
    var chunk: Int

    def __init__(
        out self,
        mut bp: Self.BP,
        mut boxes: List[AABB[Self.BP.dim]],
        mut statics: List[Bool],
        mut outs: List[List[Pair]],
        mut skip: List[Bool],
        chunk: Int,
    ):
        self.skip = Pointer(to=skip).unsafe_origin_cast[MutUntrackedOrigin]()
        self.bp = Pointer(to=bp).unsafe_origin_cast[MutUntrackedOrigin]()
        self.boxes = Pointer(to=boxes).unsafe_origin_cast[MutUntrackedOrigin]()
        self.statics = Pointer(to=statics).unsafe_origin_cast[MutUntrackedOrigin]()
        self.outs = Pointer(to=outs).unsafe_origin_cast[MutUntrackedOrigin]()
        self.chunk = chunk

    def run(self, k: Int):
        var lo = k * self.chunk
        var hi = min(lo + self.chunk, len(self.boxes[]))
        var o = List[Pair]()
        var cands = List[Int]()
        for i in range(lo, hi):
            if i < len(self.skip[]) and self.skip[][i]:
                continue
            cands.clear()
            try:
                self.bp[].query_region(self.boxes[][i], cands)
            except e:
                abort("BroadPhase.query_region raised inside pairs_parallel: " + String(e))
            sort(cands)
            var last = -1
            for c in cands:
                if c <= i or c == last:
                    continue
                last = c
                if self.statics[][i] and self.statics[][c]:
                    continue
                o.append(Pair(i, c))
        self.outs[][k] = o^


def pairs_parallel[BP: BroadPhase](
    mut bp: BP,
    mut boxes: List[AABB[BP.dim]],
    mut statics: List[Bool],
    mut out: List[Pair],
    workers: Int,
    dispatch: Dispatch,
    mut skip: List[Bool],
) raises:
    """ROADMAP 17.54: `collect_bp_pairs` with the candidate query fanned out.
    `bp` is rebuilt from `boxes` (proxy = index), then each item's box is
    queried in chunks; item i keeps the others j > i (deduplicated, sorted),
    static-static pairs dropped. Chunks hold ascending i, so concatenating
    them in chunk order is already the canonical (a, b) ascending order --
    the same list `collect_bp_pairs` builds, for every backend whose
    `query_region` reports the same overlaps as its `pairs`
    (`test_collide_par` checks all six)."""
    var n = len(boxes)
    var items = List[BoxProxy[BP.dim]](capacity=n)
    for i in range(n):
        if i < len(skip) and skip[i]:
            continue  # removed slot (`collect_bp_pairs`' `skip`)
        items.append(BoxProxy[BP.dim](i, boxes[i]))
    bp.rebuild(items)
    if n == 0:
        return
    var chunk = max(_CHUNK_MIN, n // 256)
    var nchunk = (n + chunk - 1) // chunk
    var outs = List[List[Pair]](capacity=nchunk)
    for _ in range(nchunk):
        outs.append(List[Pair]())
    var task = _BpTask[BP](bp, boxes, statics, outs, skip, chunk)
    dispatch_for(dispatch, task, nchunk, workers)
    for k in range(nchunk):
        for c in range(len(outs[k])):
            out.append(outs[k][c])
