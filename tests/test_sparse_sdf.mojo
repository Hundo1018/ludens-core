# tier: component
"""Sparse signed distance grid (ROADMAP 17.52 follow-up).

- near the surface (true distance within band - 2 cells) the sparse grid and the dense grid give the same distance
  and gradient, bit for bit, at thousands of random points;
- far away the sign is right (unstored bricks read sign * band);
- memory: a sphere on a 64^3 lattice stores a small fraction of the bricks; the ratio is checked, not just printed;
- `from_field` (never builds the dense lattice) and `from_dense` store the same bricks and values;
- `to_dense` agrees with the dense grid on every stored node and clamps the rest;
- sphere tracing a ray through the sparse grid finds the same hit as through the dense one;
- edges: res 1, a res that is not a multiple of 8, a band so small nothing is stored, a band so large everything is.
"""
from std.math import sqrt
from harness.runner import Suite
from geometry.distance_field import sphere_trace
from geometry.sdf3 import Sdf3
from geometry.sdf_grid import SdfGrid
from geometry.sparse_sdf import SparseSdfGrid
from geometry.vec import Real, Vec3
from scheduler.rng import SplitMix64


def rnd(mut r: SplitMix64, lo: Real, hi: Real) -> Real:
    return lo + (hi - lo) * Real(r.next_f32())


def main() raises:
    var s = Suite("sparse_sdf")
    var cell = Real(0.1)
    var res = 64
    var origin = Vec3(-3.2, -3.2, -3.2, 0)
    var field = Sdf3.sphere(Vec3(0.3, -0.2, 0.1, 0), 0.9)
    var dense = SdfGrid.from_field(field, res, origin, cell)
    var band = Real(0.45)
    var sparse = SparseSdfGrid.from_dense(dense, band)
    var direct = SparseSdfGrid.from_field(field, res, origin, cell, band)

    var total = sparse.nb * sparse.nb * sparse.nb
    s.check(sparse.stored_bricks() > 0 and sparse.stored_bricks() * 3 < total, "a sphere stores under a third of the bricks (" + String(sparse.stored_bricks()) + " of " + String(total) + ")")
    s.check(sparse.bytes() * 3 < res * res * res * 4, "...and its arrays take under a third of the dense grid's bytes (" + String(sparse.bytes()) + " of " + String(res * res * res * 4) + ")")
    s.check(direct.stored_bricks() >= sparse.stored_bricks(), "from_field keeps at least the bricks from_dense keeps (its skip test is conservative): " + String(direct.stored_bricks()) + " vs " + String(sparse.stored_bricks()))
    var same = True
    for k in range(res):
        for j in range(res):
            for i in range(res):
                var d0 = dense.at(i, j, k)
                var m0 = d0 if d0 >= 0 else -d0
                if m0 <= band and (direct.at(i, j, k) != d0 or sparse.at(i, j, k) != d0):
                    same = False
    s.check(same, "every node within the band holds the dense value in both sparse grids")

    var r = SplitMix64.seeded(12345)
    var near_n = 0
    var mismatch = 0
    var gmismatch = 0
    var far_n = 0
    var far_bad = 0
    for _ in range(9000):
        var p = Vec3(rnd(r, -1.7, 2.3), rnd(r, -2.2, 1.8), rnd(r, -1.9, 2.1), 0)
        var dd = dense.distance(p)
        var da = dd if dd >= 0 else -dd
        if da <= band - 2 * cell:
            near_n += 1
            if sparse.distance(p) != dd or direct.distance(p) != dd:
                mismatch += 1
            var gd = dense.gradient(p)
            var gs = sparse.gradient(p)
            if gd[0] != gs[0] or gd[1] != gs[1] or gd[2] != gs[2]:
                gmismatch += 1
        elif da > band + 2 * cell:
            far_n += 1
            var vs = sparse.distance(p)
            if (vs < 0) != (dd < 0):
                far_bad += 1
    s.check(near_n > 500, "enough random points fall in the exact zone (" + String(near_n) + ")")
    s.eqi(mismatch, 0, "distance equals the dense grid's, bit for bit, in the exact zone")
    s.eqi(gmismatch, 0, "gradient equals the dense grid's, bit for bit, in the exact zone")
    s.check(far_n > 500 and far_bad == 0, "far away: right sign (" + String(far_n) + " points)")

    # to_dense
    var back = sparse.to_dense()
    var bad_nodes = 0
    var clamped_bad = 0
    for k in range(res):
        for j in range(res):
            for i in range(res):
                var d0 = dense.at(i, j, k)
                var d1 = back.at(i, j, k)
                var mag = d0 if d0 >= 0 else -d0
                if mag <= band - 2 * cell and d0 != d1:
                    bad_nodes += 1
                var b = ((k // 8) * sparse.nb + (j // 8)) * sparse.nb + (i // 8)
                if sparse.slot[b] < 0 and (d1 != band and d1 != -band):
                    clamped_bad += 1
    s.eqi(bad_nodes, 0, "to_dense: every node within band - 2 cells is exact")
    s.eqi(clamped_bad, 0, "to_dense: every node of an unstored brick is sign * band")

    # sphere tracing finds the same hit
    var o = Vec3(-3.0, 0.1, 0.0, 0)
    var dir = Vec3(1, 0, 0, 0)
    var th = sphere_trace(dense, o, dir, 6.0, 0.01)
    var ts = sphere_trace(sparse, o, dir, 6.0, 0.01)
    s.check(th.hit and ts.hit, "both traces hit the sphere")
    s.check(ts.t > th.t - 0.3 and ts.t < th.t + 0.3, "the sparse trace's hit is within 0.3 of the dense one (clamped far field: " + String(ts.t) + " vs " + String(th.t) + ")")
    var tp = sphere_trace(sparse, Vec3(0.3, 4.0, 0.0, 0), Vec3(0, 1, 0, 0), 5.0, 0.01)
    s.check(not tp.hit, "a ray that misses the sphere misses in the sparse grid too")

    # edges
    var one = SparseSdfGrid.from_field(field, 1, origin, cell, band)
    s.check(one.distance(Vec3(0, 0, 0, 0)) == one.distance(Vec3(9, 9, 9, 0)) and one.gradient(Vec3(0, 0, 0, 0))[0] == 0, "res 1: a constant field, zero gradient")
    var odd = SdfGrid.from_field(field, 21, origin, Real(0.3))
    var sodd = SparseSdfGrid.from_dense(odd, Real(0.9))
    var odd_bad = 0
    for k in range(21):
        for j in range(21):
            for i in range(21):
                var d0 = odd.at(i, j, k)
                var m = d0 if d0 >= 0 else -d0
                if m <= 0.9 - 0.6 and sodd.at(i, j, k) != d0:
                    odd_bad += 1
    s.eqi(odd_bad, 0, "res 21 (not a multiple of 8): near nodes exact")
    # the one-node ring: with a band of 0.6 cell, a cell whose only band node sits in the next brick still reads exactly
    var small = SdfGrid.from_field(field, 33, Vec3(-1.5, -1.5, -1.5, 0), Real(0.1))
    var tiny = SparseSdfGrid.from_dense(small, Real(0.06))
    var cells_checked = 0
    var cell_bad = 0
    for k in range(32):
        for j in range(32):
            for i in range(32):
                var has_band = False
                for n in range(8):
                    var v = small.at(i + (n & 1), j + ((n >> 1) & 1), k + ((n >> 2) & 1))
                    if v <= 0.06 and v >= -0.06:
                        has_band = True
                if has_band:
                    cells_checked += 1
                    var pc = small.node(i, j, k) + Vec3(0.05, 0.05, 0.05, 0)
                    if tiny.distance(pc) != small.distance(pc):
                        cell_bad += 1
    s.check(cells_checked > 20, "the ring test looks at cells that touch the band (" + String(cells_checked) + ")")
    s.eqi(cell_bad, 0, "a cell with a band node in the next brick reads exactly (the one-node ring)")
    var none = SparseSdfGrid.from_dense(dense, Real(0.0001))
    s.check(none.stored_bricks() < sparse.stored_bricks(), "a tiny band stores fewer bricks")
    var all = SparseSdfGrid.from_dense(dense, Real(1000))
    var all_same = True
    for k in range(res):
        for j in range(res):
            for i in range(res):
                if all.at(i, j, k) != dense.at(i, j, k):
                    all_same = False
    s.check(all_same and all.stored_bricks() == total, "a huge band stores everything and equals the dense grid at every node")
    s.finish()
