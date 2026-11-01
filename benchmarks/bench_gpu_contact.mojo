"""CPU vs GPU contact solve on the same coloured schedule (ROADMAP 17.17).

A field of N boxes resting on the ground (N contacts with the ground plus
whatever neighbours touch), stepped with `ContactScene6.step(cfg.colored)`
serially, with colours fanned over CPU cores (`cfg.parallel`), and with the
substep loop on the GPU (`GpuContactSolver`). Timings are per frame over 30
frames after a 10-frame warm-up; the GPU rows split the frame into upload,
compute and download, because the whole body and contact state crosses the
bus twice per frame in this design and the Wave-1 lesson was that transfer
cost is situational, not a constant.

All paths use the broadphase (`cfg.broadphase`); without it the O(N^2)
candidate loop dominates every row and hides the solve.

Bodies are kept awake (`set_can_sleep(False)`): a sleeping island skips its
solve entirely on every path, and that difference would swamp the one
being measured.
"""

from std.benchmark import keep
from std.time import perf_counter_ns
from std.sys import has_accelerator
from max.gpu.host import DeviceContext
from harness.bench import BenchTable
from geometry.vec import Real, Vec3
from physics.rigid6 import QuatBody6, Inertia3
from physics.solver6 import ContactScene6
from physics.solver_config import SolverConfig
from physics.gpu_contact import GpuContactSolver

comptime DT: Real = 1.0 / 60.0
comptime WARM = 10
comptime FRAMES = 30


def _field(side: Int) raises -> ContactScene6[QuatBody6]:
    var sc = ContactScene6[QuatBody6]()
    var half = Real(side) * 0.7 + 2
    _ = sc.add(
        QuatBody6.at_rest(Vec3(0, -0.5, 0, 0), Inertia3.box(1, half, 0.5, half)),
        Vec3(half, 0.5, half, 0), True,
    )
    for i in range(side):
        for j in range(side):
            var p = Vec3(Real(i) * 0.6 - half + 1, 0.26, Real(j) * 0.6 - half + 1, 0)
            var id = sc.add(QuatBody6.at_rest(p, Inertia3.box(1, 0.25, 0.25, 0.25)), Vec3(0.25, 0.25, 0.25, 0), False)
            sc.set_can_sleep(id, False)
    return sc^


def _cpu(mut t: BenchTable, side: Int, parallel: Bool) raises:
    var sc = _field(side)
    var cfg = SolverConfig()
    cfg.colored = True
    cfg.max_mass_ratio = 0  # the device path does not implement the mass ratio limit (17.19)
    cfg.broadphase = True
    cfg.parallel = parallel
    var g = Vec3(0, -9.8, 0, 0)
    for _ in range(WARM):
        sc.step(DT, g, cfg)
    var t0 = Int(perf_counter_ns())
    for _ in range(FRAMES):
        sc.step(DT, g, cfg)
    var d = Int(perf_counter_ns()) - t0
    keep(sc.bset.bodies[1].position()[1])
    t.add("CPU coloured" + (" x cores" if parallel else ", serial"), side * side, "frame", d, FRAMES)


def _gpu(mut t: BenchTable, mut ctx: DeviceContext, side: Int) raises:
    var sc = _field(side)
    var cfg = SolverConfig()
    cfg.colored = True
    cfg.max_mass_ratio = 0  # the device path does not implement the mass ratio limit (17.19)
    cfg.broadphase = True
    var g = Vec3(0, -9.8, 0, 0)
    var solver = GpuContactSolver(ctx)
    for _ in range(WARM):
        solver.step(ctx, sc, DT, g, cfg)
    solver.upload_ns = 0
    solver.compute_ns = 0
    solver.download_ns = 0
    var t0 = Int(perf_counter_ns())
    for _ in range(FRAMES):
        solver.step(ctx, sc, DT, g, cfg)
    var d = Int(perf_counter_ns()) - t0
    keep(sc.bset.bodies[1].position()[1])
    var n = side * side
    t.add("GPU, whole frame", n, "frame", d, FRAMES)
    t.add("GPU: upload", n, "frame", solver.upload_ns, FRAMES)
    t.add("GPU: compute (substep loop)", n, "frame", solver.compute_ns, FRAMES)
    t.add("GPU: download", n, "frame", solver.download_ns, FRAMES)
    t.add(
        "GPU path: CPU collection + bookkeeping", n, "frame",
        d - solver.upload_ns - solver.compute_ns - solver.download_ns, FRAMES,
    )


def main() raises:
    var t = BenchTable("Contact solve per frame: CPU coloured vs GPU (N boxes on the ground, awake)")
    comptime if not has_accelerator():
        print("no accelerator: GPU rows skipped")
        for side in [8, 32]:
            _cpu(t, side, False)
            _cpu(t, side, True)
    else:
        var ctx = DeviceContext()
        for side in [8, 16, 32, 64]:
            _cpu(t, side, False)
            _cpu(t, side, True)
            _gpu(t, ctx, side)
    t.print_report()
