"""A static bounding-volume hierarchy over `AABB[dim]`, dimension-generic.

Built by recursively median-splitting leaves along the widest centroid axis.
Supports region queries (all proxies whose box overlaps a query box) and
self-pair queries (all overlapping proxy pairs) — the basis of the BVH
broadphase. Nodes live in a flat `List`; children are referenced by index.
"""

from geometry.vec import WorldType, Real, lane_min, lane_max, PadW
from geometry.aabb import AABB
from geometry.ray import Ray, RayHit, ray_aabb

comptime SAH_BINS = 12  # binned-SAH candidate split planes per axis


@fieldwise_init
struct _Leaf[dim: Int](Copyable, ImplicitlyCopyable, Movable):
    var box: AABB[Self.dim]
    var proxy: Int


@fieldwise_init
struct _Node[dim: Int](Copyable, ImplicitlyCopyable, Movable):
    var box: AABB[Self.dim]
    var left: Int  # child node index, or -1 for a leaf
    var right: Int  # child node index, or -1 for a leaf
    var proxy: Int  # proxy id for a leaf, else -1

    def is_leaf(self) -> Bool:
        return self.left < 0


struct BVH[dim: Int](Copyable, Defaultable, Movable):
    var nodes: List[_Node[Self.dim]]
    var root: Int

    def __init__(out self):
        self.nodes = List[_Node[Self.dim]]()
        self.root = -1

    def clear(mut self):
        self.nodes.clear()
        self.root = -1

    def build(
        mut self,
        var leaves: List[_Leaf[Self.dim]],
        sah: Bool = False,
        lbvh: Bool = False,
    ):
        """Three build heuristics over the same leaves, all answering queries
        identically (`test_bvh` / `test_sah` / `test_lbvh` parity).

        - default: median-split along the widest centroid axis.
        - `sah`: binned Surface-Area-Heuristic — least SA(L)·|L| + SA(R)·|R|
          over SAH_BINS candidates. Tighter tree, cheaper traversal.
        - `lbvh`: LINEAR BVH — sort leaves by Morton code, then split at the
          highest differing bit. The split decisions are then implied by the
          sort rather than searched for, which is what makes this the standard
          construction to run in parallel (and on a GPU): the only global step
          is a radix sort. Tree quality is the worst of the three, because a
          Z-order curve is a proxy for spatial proximity, not a measurement of
          it.

        `lbvh` wins over `sah` when a tree is thrown away every frame; `sah`
        wins when it is queried many times per build. `bench_sah` measures
        exactly that queries-per-build ratio."""
        self.clear()
        if len(leaves) == 0:
            return
        if lbvh:
            self.root = self._build_lbvh(leaves)
        else:
            self.root = self._build(leaves, 0, len(leaves), sah)

    def _bounds(self, leaves: List[_Leaf[Self.dim]], lo: Int, hi: Int) -> AABB[Self.dim]:
        var b = leaves[lo].box
        for i in range(lo + 1, hi):
            b = b.merge(leaves[i].box)
        return b

    def _widest_axis(self, leaves: List[_Leaf[Self.dim]], lo: Int, hi: Int) -> Int:
        var cmin = leaves[lo].box.center()
        var cmax = cmin
        for i in range(lo + 1, hi):
            var c = leaves[i].box.center()
            comptime for k in range(Self.dim):
                if c[k] < cmin[k]:
                    cmin[k] = c[k]
                if c[k] > cmax[k]:
                    cmax[k] = c[k]
        var axis = 0
        var best = cmax[0] - cmin[0]
        comptime for k in range(1, Self.dim):
            var ext = cmax[k] - cmin[k]
            if ext > best:
                best = ext
                axis = k
        return axis

    def _sort_range(mut self, mut leaves: List[_Leaf[Self.dim]], lo: Int, hi: Int, axis: Int):
        """Stable sort of [lo, hi) by centroid along `axis`. Was an insertion
        sort -- O(n^2) per node, 15.8 ms of a 4097-box rebuild (ROADMAP
        17.54). This bottom-up merge sort takes the left run on ties, the
        same stable order the insertion sort produced, so trees (and every
        query's output order) are unchanged."""
        var n = hi - lo
        if n < 2:
            return
        if n <= 16:
            for i in range(lo + 1, hi):
                var key = leaves[i]
                var kc = key.box.center()[axis]
                var j = i - 1
                while j >= lo and leaves[j].box.center()[axis] > kc:
                    leaves[j + 1] = leaves[j]
                    j -= 1
                leaves[j + 1] = key
            return
        var keys = List[Real](capacity=n)
        var idx = List[Int](capacity=n)
        for i in range(lo, hi):
            keys.append(leaves[i].box.center()[axis])
            idx.append(i - lo)
        var tmp = List[Int](length=n, fill=0)
        var width = 1
        while width < n:
            var start = 0
            while start < n:
                var mid = min(start + width, n)
                var end = min(start + 2 * width, n)
                var a = start
                var b = mid
                var o = start
                while a < mid and b < end:
                    if keys[idx[a]] > keys[idx[b]]:
                        tmp[o] = idx[b]
                        b += 1
                    else:
                        tmp[o] = idx[a]
                        a += 1
                    o += 1
                while a < mid:
                    tmp[o] = idx[a]
                    a += 1
                    o += 1
                while b < end:
                    tmp[o] = idx[b]
                    b += 1
                    o += 1
                start = end
            var sw = idx^
            idx = tmp^
            tmp = sw^
            width *= 2
        var src = List[_Leaf[Self.dim]](capacity=n)
        for i in range(lo, hi):
            src.append(leaves[i])
        for k in range(n):
            leaves[lo + k] = src[idx[k]]

    def _sah_split(
        self, mut leaves: List[_Leaf[Self.dim]], lo: Int, hi: Int
    ) -> Int:
        """Binned SAH: pick the axis + plane minimising SA(L)·|L| + SA(R)·|R|,
        partition [lo, hi) in place, return the split index (or -1 when every
        centroid coincides / one side is empty -> caller falls back to median)."""
        var cmin = leaves[lo].box.center()
        var cmax = cmin
        for i in range(lo + 1, hi):
            var c = leaves[i].box.center()
            cmin = lane_min(cmin, c)
            cmax = lane_max(cmax, c)

        var best_cost = Real(1e30)
        var best_axis = -1
        var best_split = Real(0)
        comptime BIG = SIMD[WorldType, PadW[Self.dim]](1e30)
        comptime SMALL = SIMD[WorldType, PadW[Self.dim]](-1e30)
        for a in range(Self.dim):
            var extent = cmax[a] - cmin[a]
            if extent <= 0:
                continue
            var bcount = Array[Int, SAH_BINS](fill=0)
            var bmin = Array[SIMD[WorldType, PadW[Self.dim]], SAH_BINS](fill=BIG)
            var bmax = Array[SIMD[WorldType, PadW[Self.dim]], SAH_BINS](
                fill=SMALL
            )
            for i in range(lo, hi):
                var c = leaves[i].box.center()[a]
                var k = Int(Real(SAH_BINS) * (c - cmin[a]) / extent)
                if k < 0:
                    k = 0
                if k >= SAH_BINS:
                    k = SAH_BINS - 1
                bcount[k] += 1
                bmin[k] = lane_min(bmin[k], leaves[i].box.min)
                bmax[k] = lane_max(bmax[k], leaves[i].box.max)
            # left prefix (bins [0..k])
            var lcount = Array[Int, SAH_BINS](fill=0)
            var lmin = Array[SIMD[WorldType, PadW[Self.dim]], SAH_BINS](fill=BIG)
            var lmax = Array[SIMD[WorldType, PadW[Self.dim]], SAH_BINS](
                fill=SMALL
            )
            var acc_c = 0
            var acc_min = BIG
            var acc_max = SMALL
            for k in range(SAH_BINS):
                acc_c += bcount[k]
                acc_min = lane_min(acc_min, bmin[k])
                acc_max = lane_max(acc_max, bmax[k])
                lcount[k] = acc_c
                lmin[k] = acc_min
                lmax[k] = acc_max
            # right suffix; split between bin k-1 and k
            var r_c = 0
            var r_min = BIG
            var r_max = SMALL
            for k in range(SAH_BINS - 1, 0, -1):
                r_c += bcount[k]
                r_min = lane_min(r_min, bmin[k])
                r_max = lane_max(r_max, bmax[k])
                var lc = lcount[k - 1]
                if lc == 0 or r_c == 0:
                    continue
                var sa_l = AABB[Self.dim](lmin[k - 1], lmax[k - 1]).surface_area()
                var sa_r = AABB[Self.dim](r_min, r_max).surface_area()
                var cost = sa_l * Real(lc) + sa_r * Real(r_c)
                if cost < best_cost:
                    best_cost = cost
                    best_axis = a
                    best_split = cmin[a] + extent * Real(k) / Real(SAH_BINS)

        if best_axis < 0:
            return -1
        # partition in place: centroid on the chosen axis left of the plane
        var mid = lo
        for i in range(lo, hi):
            if leaves[i].box.center()[best_axis] < best_split:
                var tmp = leaves[i]
                leaves[i] = leaves[mid]
                leaves[mid] = tmp
                mid += 1
        if mid == lo or mid == hi:
            return -1
        return mid

    def _build(
        mut self, mut leaves: List[_Leaf[Self.dim]], lo: Int, hi: Int, sah: Bool
    ) -> Int:
        # bottom-up bounds, as in `_radix_node`: rescanning the range at every
        # node costs O(n log n) merges for a value the children already have
        if hi - lo == 1:
            self.nodes.append(
                _Node[Self.dim](leaves[lo].box, -1, -1, leaves[lo].proxy)
            )
            return len(self.nodes) - 1

        var mid = -1
        if sah:
            mid = self._sah_split(leaves, lo, hi)
        if mid < 0:  # median (default, or SAH degenerate fallback)
            var axis = self._widest_axis(leaves, lo, hi)
            self._sort_range(leaves, lo, hi, axis)
            mid = (lo + hi) // 2
        var left = self._build(leaves, lo, mid, sah)
        var right = self._build(leaves, mid, hi, sah)
        var box = self.nodes[left].box.merge(self.nodes[right].box)
        self.nodes.append(_Node[Self.dim](box, left, right, -1))
        return len(self.nodes) - 1

    # ------------------------------------------------------------ LBVH
    @staticmethod
    def _spread(v: UInt32, bits: Int) -> UInt32:
        """Insert `dim-1` zero bits after each of the low `bits` bits, so that
        OR-ing the per-axis results interleaves them into a Morton code."""
        var out = UInt32(0)
        for i in range(bits):
            out |= ((v >> UInt32(i)) & UInt32(1)) << UInt32(i * Self.dim)
        return out

    def _morton(self, leaf: _Leaf[Self.dim], cmin: SIMD[WorldType, PadW[Self.dim]],
                inv: SIMD[WorldType, PadW[Self.dim]]) -> UInt32:
        """Quantise the centroid to a uniform grid and interleave the axes.
        30 bits total, so 10 bits per axis in 3D and 15 in 2D."""
        comptime BITS = 30 // Self.dim
        comptime SCALE = Real((1 << BITS) - 1)
        var c = (leaf.box.min + leaf.box.max) * 0.5
        var code = UInt32(0)
        for a in range(Self.dim):
            var t = (c[a] - cmin[a]) * inv[a]
            if t < 0:
                t = 0
            if t > 1:
                t = 1
            var q = UInt32(Int(t * SCALE))
            code |= Self._spread(q, BITS) << UInt32(a)
        return code

    def _build_lbvh(mut self, mut leaves: List[_Leaf[Self.dim]]) -> Int:
        var n = len(leaves)
        # scene centroid bounds -> quantisation grid
        var cmin = (leaves[0].box.min + leaves[0].box.max) * 0.5
        var cmax = cmin
        for i in range(1, n):
            var c = (leaves[i].box.min + leaves[i].box.max) * 0.5
            cmin = lane_min(cmin, c)
            cmax = lane_max(cmax, c)
        var inv = SIMD[WorldType, PadW[Self.dim]](0)
        for a in range(Self.dim):
            var e = cmax[a] - cmin[a]
            inv[a] = (1.0 / e) if e > 1e-20 else Real(0)

        var codes = List[UInt32]()
        for i in range(n):
            codes.append(self._morton(leaves[i], cmin, inv))

        # LSD radix sort, 8 bits per pass: the one global step of an LBVH
        # build, and the step that parallelises.
        var tmp_leaves = leaves.copy()
        var tmp_codes = codes.copy()
        for shift in range(0, 32, 8):
            var count = Array[Int, 257](fill=0)
            for i in range(n):
                count[Int((codes[i] >> UInt32(shift)) & UInt32(255)) + 1] += 1
            for b in range(1, 257):
                count[b] += count[b - 1]
            for i in range(n):
                var b = Int((codes[i] >> UInt32(shift)) & UInt32(255))
                var d = count[b]
                count[b] = d + 1
                tmp_codes[d] = codes[i]
                tmp_leaves[d] = leaves[i]
            for i in range(n):
                codes[i] = tmp_codes[i]
                leaves[i] = tmp_leaves[i]

        return self._radix_node(leaves, codes, 0, n, 29)

    def _radix_node(
        mut self, mut leaves: List[_Leaf[Self.dim]], codes: List[UInt32],
        lo: Int, hi: Int, bit: Int,
    ) -> Int:
        # A node's box is the union of its children's, so it is computed AFTER
        # the recursion rather than by rescanning [lo, hi) here. Rescanning made
        # the emit O(n log n) AABB merges and — measured — the emit was ~100% of
        # the whole LBVH build, with the Morton sort effectively free. Bottom-up
        # bounds make it O(n).
        if hi - lo == 1:
            var box = leaves[lo].box
            self.nodes.append(_Node[Self.dim](box, -1, -1, leaves[lo].proxy))
            return len(self.nodes) - 1
        # Descend to the highest bit that actually differs across the range;
        # equal codes (duplicate cells) fall through to a median split so the
        # recursion always makes progress.
        var b = bit
        while b >= 0:
            var m = UInt32(1) << UInt32(b)
            if (codes[lo] & m) != (codes[hi - 1] & m):
                break
            b -= 1
        var mid: Int
        if b < 0:
            mid = (lo + hi) // 2
        else:
            # codes are sorted, so the 0->1 transition is a binary search
            var m = UInt32(1) << UInt32(b)
            var l = lo
            var r = hi - 1
            while l < r:
                var c = (l + r) // 2
                if (codes[c] & m) == 0:
                    l = c + 1
                else:
                    r = c
            mid = l
            if mid <= lo or mid >= hi:
                mid = (lo + hi) // 2
        var left = self._radix_node(leaves, codes, lo, mid, b - 1 if b > 0 else 0)
        var right = self._radix_node(leaves, codes, mid, hi, b - 1 if b > 0 else 0)
        var box = self.nodes[left].box.merge(self.nodes[right].box)
        self.nodes.append(_Node[Self.dim](box, left, right, -1))
        return len(self.nodes) - 1

    def build_lbvh_presorted(
        mut self, boxes: List[AABB[Self.dim]], proxies: List[Int]
    ):
        """Emit the hierarchy from leaves that are ALREADY in Z-order.

        Exists so a device-side sort is not thrown away: passing its output to
        `build(lbvh=True)` would re-run the whole Morton+radix sort on the host,
        which is idempotent (same order out) and therefore silently correct but
        doubles the work — a benchmark written that way charges the GPU path for
        a CPU sort it never needed."""
        self.clear()
        var n = len(boxes)
        if n == 0:
            return
        var leaves = List[_Leaf[Self.dim]]()
        for i in range(n):
            leaves.append(_Leaf[Self.dim](boxes[i], proxies[i]))
        # codes are still needed for the split decisions, but not the sort
        comptime BITS = 30 // Self.dim
        comptime SCALE = Real((1 << BITS) - 1)
        var cmin = (leaves[0].box.min + leaves[0].box.max) * 0.5
        var cmax = cmin
        for i in range(1, n):
            var c = (leaves[i].box.min + leaves[i].box.max) * 0.5
            cmin = lane_min(cmin, c)
            cmax = lane_max(cmax, c)
        var inv = SIMD[WorldType, PadW[Self.dim]](0)
        for a in range(Self.dim):
            var e = cmax[a] - cmin[a]
            inv[a] = (1.0 / e) if e > 1e-20 else Real(0)
        var codes = List[UInt32]()
        for i in range(n):
            codes.append(self._morton(leaves[i], cmin, inv))
        self.root = self._radix_node(leaves, codes, 0, n, 29)

    def build_boxes(
        mut self, boxes: List[AABB[Self.dim]], proxies: List[Int],
        sah: Bool = False,
        lbvh: Bool = False,
    ):
        """Build from parallel (box, proxy) lists — keeps `_Leaf` private to this module."""
        var leaves = List[_Leaf[Self.dim]]()
        for i in range(len(boxes)):
            leaves.append(_Leaf[Self.dim](boxes[i], proxies[i]))
        self.build(leaves^, sah, lbvh)

    def raycast(self, ray: Ray[Self.dim]) -> RayHit[Self.dim]:
        """Nearest proxy the ray hits, found by descending only nodes the ray enters."""
        var best = RayHit[Self.dim].miss()
        var best_t = ray.max_t
        if self.root >= 0:
            self._raycast(self.root, ray, best, best_t)
        return best

    def _raycast(
        self,
        node: Int,
        ray: Ray[Self.dim],
        mut best: RayHit[Self.dim],
        mut best_t: Real,
    ):
        var n = self.nodes[node]
        var bh = ray_aabb(ray, n.box)
        if not bh.hit or bh.t > best_t:
            return
        if n.is_leaf():
            if bh.t <= best_t:
                best_t = bh.t
                best = RayHit[Self.dim](True, bh.t, n.proxy, bh.normal)
            return
        self._raycast(n.left, ray, best, best_t)
        self._raycast(n.right, ray, best, best_t)

    def ray_leaves(self, ray: Ray[Self.dim], mut out: List[Int]):
        """Every leaf whose box the ray segment [0, max_t] enters, descending
        only nodes it enters (ROADMAP 17.53: a long diagonal ray over a mesh
        visits the boxes along it, not every box inside its bounding box)."""
        if self.root >= 0:
            self._ray_leaves(self.root, ray, out)

    def _ray_leaves(self, node: Int, ray: Ray[Self.dim], mut out: List[Int]):
        var n = self.nodes[node]
        if not ray_aabb(ray, n.box).hit:
            return
        if n.is_leaf():
            out.append(n.proxy)
            return
        self._ray_leaves(n.left, ray, out)
        self._ray_leaves(n.right, ray, out)

    def query_region(self, box: AABB[Self.dim], mut out: List[Int]):
        if self.root < 0:
            return
        self._query(self.root, box, out)

    def _query(self, node: Int, box: AABB[Self.dim], mut out: List[Int]):
        var n = self.nodes[node]
        if not n.box.overlaps(box):
            return
        if n.is_leaf():
            out.append(n.proxy)
            return
        self._query(n.left, box, out)
        self._query(n.right, box, out)

    def cost(self) -> Real:
        """Σ node AABB surface area — the tree-tightness metric the SAH build
        minimises (leaf areas are identical across builds, so a lower total
        means tighter internal nodes and cheaper traversal)."""
        var s = Real(0)
        for i in range(len(self.nodes)):
            s += self.nodes[i].box.surface_area()
        return s

    def _depth_sum(self, node: Int, d: Int) -> Int:
        var n = self.nodes[node]
        if n.is_leaf():
            return d
        return self._depth_sum(n.left, d + 1) + self._depth_sum(n.right, d + 1)

    def avg_leaf_depth(self) -> Real:
        """Mean root-to-leaf depth (lower/flatter = fewer nodes per query)."""
        if self.root < 0:
            return 0
        var nleaf = 0
        for i in range(len(self.nodes)):
            if self.nodes[i].is_leaf():
                nleaf += 1
        if nleaf == 0:
            return 0
        return Real(self._depth_sum(self.root, 0)) / Real(nleaf)


def morton_order[D: Int](boxes: List[AABB[D]]) -> List[Int]:
    """CPU Morton code + LSD radix sort, returning the Z-order permutation.

    The same computation `BVH.build(lbvh=True)` does internally, exposed so the
    SORT can be compared against a device implementation directly. Without
    this the only available comparison is GPU-sort against CPU-FULL-BUILD,
    which conflates the sort with the hierarchy emit that both share — and the
    emit turns out to dominate, so that conflation hides the answer rather than
    approximating it."""
    var n = len(boxes)
    var order = List[Int]()
    if n == 0:
        return order^
    comptime BITS = 30 // D
    comptime SCALE = Real((1 << BITS) - 1)

    var cmin = (boxes[0].min + boxes[0].max) * 0.5
    var cmax = cmin
    for i in range(1, n):
        var c = (boxes[i].min + boxes[i].max) * 0.5
        cmin = lane_min(cmin, c)
        cmax = lane_max(cmax, c)
    var inv = SIMD[WorldType, PadW[D]](0)
    for a in range(D):
        var e = cmax[a] - cmin[a]
        inv[a] = (1.0 / e) if e > 1e-20 else Real(0)

    var codes = List[UInt32]()
    for i in range(n):
        var c = (boxes[i].min + boxes[i].max) * 0.5
        var code = UInt32(0)
        for a in range(D):
            var t = (c[a] - cmin[a]) * inv[a]
            if t < 0:
                t = 0
            if t > 1:
                t = 1
            var q = UInt32(Int(t * SCALE))
            var spread = UInt32(0)
            for b in range(BITS):
                spread |= ((q >> UInt32(b)) & UInt32(1)) << UInt32(b * D)
            code |= spread << UInt32(a)
        codes.append(code)
        order.append(i)

    var tmp_codes = codes.copy()
    var tmp_order = order.copy()
    for shift in range(0, 32, 8):
        var count = Array[Int, 257](fill=0)
        for i in range(n):
            count[Int((codes[i] >> UInt32(shift)) & UInt32(255)) + 1] += 1
        for b in range(1, 257):
            count[b] += count[b - 1]
        for i in range(n):
            var b = Int((codes[i] >> UInt32(shift)) & UInt32(255))
            var d = count[b]
            count[b] = d + 1
            tmp_codes[d] = codes[i]
            tmp_order[d] = order[i]
        for i in range(n):
            codes[i] = tmp_codes[i]
            order[i] = tmp_order[i]
    return order^
