"""Batched narrowphase on flat arrays (ROADMAP 17.17): the per-thread body
of the GPU narrowphase kernel, also run on the host.

One pair record -> one contact manifold, one pair per GPU thread. The body
`narrow_pair` is `ColliderSet.pair_manifold`'s dispatch for the convex
primitive kinds (box, sphere, capsule) with the same arithmetic in the same
order (inflation and speculative margin added per side, kinds normalised so
a-kind <= b-kind, normal flipped back), calling the same `*_manifold`
functions, so a host run is bit-identical to `pair_manifold` (tested). Hulls
and static meshes stay on the CPU path (their data is variable-length).

Flat layouts (world scalar `Real`: f32, or f64 under build-f64):
- pair record, `PAIR_STRIDE` floats: kind a, kind b, position a, axes a
  (3 rows), half a, position b, axes b, half b, speculative margin `mr`,
  inflation `infl` xyz (the `pair_manifold` arguments);
- manifold, `OUT_STRIDE` floats: hit, normal xyz, count, then 4 x (point
  xyz, depth).
"""

from geometry.vec import Real, Vec3
from collision.collider_set import ColliderSet, Pose3, SHAPE_BOX, SHAPE_SPHERE, SHAPE_CAPSULE
from collision.manifold import (
    Axes3,
    ContactManifold,
    box_box_manifold,
    sphere_box_manifold,
    sphere_sphere_manifold,
    capsule_box_manifold,
    capsule_sphere_manifold,
    capsule_capsule_manifold,
)

comptime FPtr = Pointer[Real, MutAnyOrigin]  # world scalar (f32, or f64 under build-f64)

comptime PAIR_STRIDE = 36
comptime P_KA = 0
comptime P_KB = 1
comptime P_POS_A = 2
comptime P_AX_A = 5
comptime P_HALF_A = 14
comptime P_POS_B = 17
comptime P_AX_B = 20
comptime P_HALF_B = 29
comptime P_MR = 32
comptime P_INFL = 33

comptime OUT_STRIDE = 24
comptime O_HIT = 0
comptime O_NORMAL = 1
comptime O_COUNT = 4
comptime O_POINTS = 5  # 4 x (x, y, z, depth)


@always_inline
def _ld3(p: FPtr, o: Int) -> Vec3:
    return Vec3(p[unsafe_offset=o], p[unsafe_offset=o + 1], p[unsafe_offset=o + 2], 0)


@always_inline
def _st3(p: FPtr, o: Int, v: Vec3):
    p[unsafe_offset=o] = v[0]
    p[unsafe_offset=o + 1] = v[1]
    p[unsafe_offset=o + 2] = v[2]


def _axes(p: FPtr, o: Int) -> Axes3:
    var ax = Axes3(fill=Vec3(0, 0, 0, 0))
    for r in range(3):
        ax[r] = _ld3(p, o + 3 * r)
    return ax^


def narrow_pair(inp: FPtr, res: FPtr, k: Int):
    """Manifold of pair record `k` into output slot `k`."""
    var r = k * PAIR_STRIDE
    var ka0 = Int(inp[unsafe_offset=r + P_KA])
    var kb0 = Int(inp[unsafe_offset=r + P_KB])
    var oa = P_POS_A
    var ob = P_POS_B
    var flip = False
    if ka0 > kb0:
        oa = P_POS_B
        ob = P_POS_A
        flip = True
    var ka = min(ka0, kb0)
    var kb = max(ka0, kb0)
    # record offsets: position at o, axes at o + 3, half at o + 12
    var pa = _ld3(inp, r + oa)
    var pb = _ld3(inp, r + ob)
    var axa = _axes(inp, r + oa + 3)
    var axb = _axes(inp, r + ob + 3)
    var ha = _ld3(inp, r + oa + 12)
    var hb = _ld3(inp, r + ob + 12)
    var mr = inp[unsafe_offset=r + P_MR]
    var infl = _ld3(inp, r + P_INFL)
    var m = ContactManifold[3]()
    if ka == SHAPE_BOX and kb == SHAPE_BOX:
        m = box_box_manifold(pa, axa, ha + infl, pb, axb, hb + infl)
    elif ka == SHAPE_BOX and kb == SHAPE_SPHERE:
        m = sphere_box_manifold(pb, hb[0] + mr, pa, axa, ha + infl)
        m.normal = -m.normal
    elif ka == SHAPE_BOX and kb == SHAPE_CAPSULE:
        m = capsule_box_manifold(pb, axb[1], hb[1], hb[0] + mr, pa, axa, ha + infl)
        m.normal = -m.normal
    elif ka == SHAPE_SPHERE and kb == SHAPE_SPHERE:
        m = sphere_sphere_manifold(pa, ha[0] + mr, pb, hb[0] + mr)
    elif ka == SHAPE_SPHERE and kb == SHAPE_CAPSULE:
        m = capsule_sphere_manifold(pb, axb[1], hb[1], hb[0] + mr, pa, ha[0] + mr)
        m.normal = -m.normal
    elif ka == SHAPE_CAPSULE and kb == SHAPE_CAPSULE:
        m = capsule_capsule_manifold(pa, axa[1], ha[1], ha[0] + mr, pb, axb[1], hb[1], hb[0] + mr)
    if flip and m.hit:
        m.normal = -m.normal
    var o = k * OUT_STRIDE
    res[unsafe_offset=o + O_HIT] = 1 if m.hit else 0
    _st3(res, o + O_NORMAL, m.normal)
    res[unsafe_offset=o + O_COUNT] = Real(m.count)
    for c in range(ContactManifold[3].MAX):
        var po = o + O_POINTS + 4 * c
        if c < m.count:
            _st3(res, po, m.points[c])
            res[unsafe_offset=po + 3] = m.depths[c]
        else:
            _st3(res, po, Vec3(0, 0, 0, 0))
            res[unsafe_offset=po + 3] = 0


def is_batchable(kind: Int) -> Bool:
    return kind == SHAPE_BOX or kind == SHAPE_SPHERE or kind == SHAPE_CAPSULE


struct NarrowBatch(Movable):
    """Pair records in the flat layout the GPU kernel reads; `run_host` runs
    the kernel body per pair on the CPU."""

    var inp: List[Real]
    var out: List[Real]
    var count: Int

    def __init__(out self, capacity: Int = 0):
        self.inp = List[Real](capacity=capacity * PAIR_STRIDE)
        self.out = List[Real]()
        self.count = 0

    def clear(mut self):
        self.inp.clear()
        self.count = 0

    def add_pair(mut self, cs: ColliderSet, i: Int, j: Int, pose_i: Pose3, pose_j: Pose3, mr: Real, infl: Vec3) raises:
        """Record pair (i, j) with `pair_manifold`'s arguments. Raises for a
        hull or static-mesh collider (those stay on the CPU path)."""
        if not is_batchable(cs.shape[i]) or not is_batchable(cs.shape[j]):
            raise Error("NarrowBatch.add_pair: only box, sphere and capsule colliders batch")
        self.inp.append(Real(cs.shape[i]))
        self.inp.append(Real(cs.shape[j]))
        self._side(pose_i, cs.half[i])
        self._side(pose_j, cs.half[j])
        self.inp.append(mr)
        for c in range(3):
            self.inp.append(infl[c])
        self.count += 1

    def _side(mut self, pose: Pose3, half: Vec3):
        for c in range(3):
            self.inp.append(pose.position[c])
        for r in range(3):
            for c in range(3):
                self.inp.append(pose.axes[r][c])
        for c in range(3):
            self.inp.append(half[c])

    def run_host(mut self):
        self.out = List[Real](length=self.count * OUT_STRIDE, fill=0)
        var ip = self.inp.unsafe_ptr().unsafe_origin_cast[MutAnyOrigin]()
        var op = self.out.unsafe_ptr().unsafe_origin_cast[MutAnyOrigin]()
        for k in range(self.count):
            narrow_pair(ip, op, k)

    def manifold(self, k: Int) -> ContactManifold[3]:
        """Pair k's result (after `run_host` or a device run filled `out`)."""
        var o = k * OUT_STRIDE
        var m = ContactManifold[3]()
        m.hit = self.out[o + O_HIT] != 0
        for c in range(3):
            m.normal[c] = self.out[o + O_NORMAL + c]
        m.count = Int(self.out[o + O_COUNT])
        for c in range(m.count):
            var po = o + O_POINTS + 4 * c
            for d in range(3):
                m.points[c][d] = self.out[po + d]
            m.depths[c] = self.out[po + 3]
        return m
