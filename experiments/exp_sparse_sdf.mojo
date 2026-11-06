"""Experiment: what a sparse SDF grid saves and what a query costs (ROADMAP 17.52 follow-up).

A sphere of radius 0.3 of the box width, band = 4 cells. Per lattice size: bricks stored, bytes of the sparse arrays
against the dense grid, and the time of 1e6 `distance` queries at random points near the surface, dense and sparse.
Wall clock; run on an idle machine.

Run: pixi run mojo run -I build experiments/exp_sparse_sdf.mojo"""
from std.time import perf_counter_ns
from geometry.sdf3 import Sdf3
from geometry.sdf_grid import SdfGrid
from geometry.sparse_sdf import SparseSdfGrid
from geometry.vec import Real, Vec3
from scheduler.rng import SplitMix64


def main() raises:
    print("| res | dense MiB | sparse MiB | bricks stored | build dense ms | build from_field ms | dense ns / query | sparse ns / query |")
    print("|---:|---:|---:|---:|---:|---:|---:|---:|")
    for res in [64, 128, 192]:
        var cell = Real(1.0) / Real(res - 1)
        var origin = Vec3(-0.5, -0.5, -0.5, 0)
        var f = Sdf3.sphere(Vec3(0, 0, 0, 0), 0.3)
        var t0 = perf_counter_ns()
        var dense = SdfGrid.from_field(f, res, origin, cell)
        var t1 = perf_counter_ns()
        var sparse = SparseSdfGrid.from_field(f, res, origin, cell, 4 * cell)
        var t2 = perf_counter_ns()
        var rng = SplitMix64.seeded(7)
        var pts = List[Vec3]()
        for _ in range(1000000):
            var a = Real(rng.next_f32()) * 6.2831853
            var u = Real(rng.next_f32()) * 2 - 1
            var rr = Real(0.3) + (Real(rng.next_f32()) - 0.5) * 8 * cell
            var s = (1 - u * u) ** 0.5
            pts.append(Vec3(rr * s * Real(0.5 * (a - a + 1)) * 1, rr * u, rr * s, 0))
        var acc = Real(0)
        var t3 = perf_counter_ns()
        for i in range(len(pts)):
            acc += dense.distance(pts[i])
        var t4 = perf_counter_ns()
        for i in range(len(pts)):
            acc += sparse.distance(pts[i])
        var t5 = perf_counter_ns()
        print("|", res, "|", Float64(res * res * res * 4) / 1048576.0, "|", Float64(sparse.bytes()) / 1048576.0, "|", sparse.stored_bricks(), "of", sparse.nb * sparse.nb * sparse.nb, "|", Float64(t1 - t0) / 1e6, "|", Float64(t2 - t1) / 1e6, "|", Float64(t4 - t3) / 1e6, "|", Float64(t5 - t4) / 1e6, "|")
        _ = acc
