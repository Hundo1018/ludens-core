# tier: integration
"""GPU contact solver vs the CPU coloured step (ROADMAP 17.17).

`GpuContactSolver.step` runs the substep loop of `ContactScene6.step(cfg
.colored=True)` on the device, loading each body into a real `QuatBody6`.
Parity is by action (positions, velocities) within float32 noise: the
schedule is the same, only multiply-add contraction may differ.

The bar is measured, not assumed: box-box contact clipping is a discrete
branch, so the CPU solver itself turns a 1e-7 nudge of one box into ~3e-3
within 20 frames of a stack settling. Each scenario runs CPU, CPU with every
dynamic body nudged by 1e-6, and GPU; the GPU must stay within twice the CPU's own
divergence, and end in the same rest state by action.

  ordinary     a 5-box stack.
  integration  two separate stacks (two islands) with per-body friction and
               a rolling sphere, events on.
  extreme      10:1 mass ratio stack; a 400-box field; one body and no
               contacts; joints are refused; no accelerator -> skipped.
"""

from std.sys import has_accelerator
from max.gpu.host import DeviceContext
from harness.runner import Suite
from geometry.vec import Real, Vec3
from physics.rigid6 import QuatBody6, Inertia3
from physics.solver6 import ContactScene6
from physics.joints6 import Joint6
from physics.solver_config import SolverConfig
from physics.gpu_contact import GpuContactSolver

comptime DT: Real = 1.0 / 60.0


def _cfg() -> SolverConfig:
    var c = SolverConfig()
    c.colored = True
    c.max_mass_ratio = 0  # the device path does not implement the mass ratio limit (17.19)
    return c


def _ground(mut sc: ContactScene6[QuatBody6], half: Real):
    _ = sc.add(
        QuatBody6.at_rest(Vec3(0, -0.5, 0, 0), Inertia3.box(1, half, 0.5, half)),
        Vec3(half, 0.5, half, 0), True,
    )


def _stack(mut sc: ContactScene6[QuatBody6], x: Real, n: Int, mass_top: Real):
    for i in range(n):
        var m = mass_top if i == n - 1 else Real(1)
        _ = sc.add(
            QuatBody6.at_rest(Vec3(x, 0.25 + Real(i) * 0.52, 0, 0), Inertia3.box(m, 0.25, 0.25, 0.25)),
            Vec3(0.25, 0.25, 0.25, 0), False,
        )


def _two_islands(mut sc: ContactScene6[QuatBody6]) raises:
    _ground(sc, 10)
    _stack(sc, -3, 3, 1)
    _stack(sc, 3, 4, 1)
    var b = QuatBody6.at_rest(Vec3(0, 0.6, 0, 0), Inertia3.sphere(1, 0.4))
    b.vel = Vec3(2, 0, 0, 0)
    _ = sc.add_sphere(b^, 0.4, False)
    sc.set_friction(1, 0.9)
    sc.set_friction(5, 0.1)
    sc.events_on = True


def _max_diff(a: ContactScene6[QuatBody6], b: ContactScene6[QuatBody6]) -> Real:
    var d = Real(0)
    for i in range(len(a.bset.bodies)):
        var p = a.bset.bodies[i].position() - b.bset.bodies[i].position()
        var v = a.bset.bodies[i].linear_velocity() - b.bset.bodies[i].linear_velocity()
        for k in range(3):
            d = max(d, abs(p[k]))
            d = max(d, abs(v[k]) * DT)
    return d


def _build(kind: Int) raises -> ContactScene6[QuatBody6]:
    var sc = ContactScene6[QuatBody6]()
    match kind:
        case 0:  # 5-box stack
            _ground(sc, 5)
            _stack(sc, 0, 5, 1)
        case 1:  # two islands + materials + a rolling sphere, events on
            _two_islands(sc)
        case 2:  # 10:1 mass ratio stack
            _ground(sc, 5)
            _stack(sc, 0, 3, 10)
        case _:  # 400-box field
            _ground(sc, 40)
            for i in range(20):
                for j in range(20):
                    var p = Vec3(Real(i) * 1.2 - 12, 0.3 + Real((i + j) % 3) * 0.05, Real(j) * 1.2 - 12, 0)
                    _ = sc.add(QuatBody6.at_rest(p, Inertia3.box(1, 0.25, 0.25, 0.25)), Vec3(0.25, 0.25, 0.25, 0), False)
    return sc^


def _speed(sc: ContactScene6[QuatBody6]) -> Real:
    var m = Real(0)
    for i in range(len(sc.bset.bodies)):
        var v = sc.bset.bodies[i].linear_velocity()
        m = max(m, abs(v[0]) + abs(v[1]) + abs(v[2]))
    return m


def _scenario(
    mut s: Suite, mut ctx: DeviceContext, mut solver: GpuContactSolver,
    kind: Int, frames: Int, name: String,
) raises:
    """GPU vs CPU, judged against the CPU's own divergence from a 1e-6
    nudge of every dynamic body (box-box clipping is a discrete branch: the solver is
    chaotic at that scale, so bit-level parity is not the right bar)."""
    var cfg = _cfg()
    var g = Vec3(0, -9.8, 0, 0)
    var cpu = _build(kind)
    var nudged = _build(kind)
    var gpu = _build(kind)
    for i in range(len(nudged.bset.bodies)):
        if nudged.bset.is_dynamic(i):
            nudged.bset.bodies[i].pos = nudged.bset.bodies[i].pos + Vec3(1e-6, 0, 0, 0)
    var floor = Real(0)
    var worst = Real(0)
    for _ in range(frames):
        cpu.step(DT, g, cfg)
        nudged.step(DT, g, cfg)
        solver.step(ctx, gpu, DT, g, cfg)
        floor = max(floor, _max_diff(cpu, nudged))
        worst = max(worst, _max_diff(cpu, gpu))
    print("  [device] " + name + ": gpu-cpu", worst, " cpu self-divergence (1e-6 nudge)", floor, " speeds", _speed(cpu), _speed(nudged), _speed(gpu))
    s.check(worst <= max(2 * floor, Real(1e-4)), name + ": GPU within the CPU's own sensitivity")
    s.check(_max_diff(cpu, gpu) < 2e-2, name + ": same rest state by action")
    # settled on both: residual jitter below 5 cm/s (whether a stack has
    # dropped into sleep on this exact frame is itself chaotic -- the nudged
    # CPU run differs from the plain one there too)
    s.check(_speed(cpu) < 0.05 and _speed(gpu) < 0.05, name + ": both settled")
    s.check(len(cpu.cache) == len(gpu.cache), name + ": same contact set size at the end")
    s.check(cpu.island_count() == gpu.island_count(), name + ": same island count")


def main() raises:
    var s = Suite("gpu_contact")
    comptime if not has_accelerator():
        s.skip_device("no accelerator on this host")
        s.finish()
    else:
        s.begin_device()
        var ctx = DeviceContext()  # the single owner (F17)
        var solver = GpuContactSolver(ctx)
        var cfg = _cfg()
        var g = Vec3(0, -9.8, 0, 0)

        _scenario(s, ctx, solver, 0, 180, "5-box stack")
        _scenario(s, ctx, solver, 1, 180, "two islands + materials + sphere")
        _scenario(s, ctx, solver, 2, 180, "10:1 mass ratio stack")
        _scenario(s, ctx, solver, 3, 60, "400-box field")

        # ---- extremes -----------------------------------------------------------
        var lone = ContactScene6[QuatBody6]()
        var lc = ContactScene6[QuatBody6]()
        _ = lone.add(QuatBody6.at_rest(Vec3(0, 5, 0, 0), Inertia3.box(1, 0.5, 0.5, 0.5)), Vec3(0.5, 0.5, 0.5, 0), False)
        _ = lc.add(QuatBody6.at_rest(Vec3(0, 5, 0, 0), Inertia3.box(1, 0.5, 0.5, 0.5)), Vec3(0.5, 0.5, 0.5, 0), False)
        for _ in range(30):
            solver.step(ctx, lone, DT, g, cfg)
            lc.step(DT, g, cfg)
        s.check(_max_diff(lone, lc) < 1e-5, "single body, no contacts: device free fall == CPU")

        var jc = ContactScene6[QuatBody6]()
        _ground(jc, 5)
        _stack(jc, 0, 2, 1)
        _ = jc.add_joint(Joint6.ball(1, 2, Vec3(0, 0.25, 0, 0), Vec3(0, -0.25, 0, 0)))
        var refused = False
        try:
            solver.step(ctx, jc, DT, g, cfg)
        except:
            refused = True
        s.check(refused, "joints are refused, not silently ignored")

        s.finish()
