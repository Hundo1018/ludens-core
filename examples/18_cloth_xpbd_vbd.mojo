"""Example 18 — the same cloth, two solvers, two devices.

A 32×32 cloth pinned along one edge falls for 120 steps under two
interchangeable solvers: XPBD (per-constraint position projection) and VBD
(vertex block descent: a small Newton step per vertex, swept in graph colours).
Each runs on the CPU reference and, when an accelerator is present, on the
GPU through ONE shared device context (creating several contexts in one
process hangs, so `gpu_cloth_run_ctx` / `gpu_vbd_run_ctx` are the entry points to use for more than
one rollout). The example prints how far the free corner fell, the worst
edge stretch for each solver, and the CPU/GPU agreement.

Run:

    pixi run mojo run -I build examples/18_cloth_xpbd_vbd.mojo
"""

from std.sys import has_accelerator
from max.gpu.host import DeviceContext
from physics.gpu_cloth import ClothState, cpu_cloth_run, gpu_cloth_run_ctx
from physics.vbd_cloth import cpu_vbd_run, gpu_vbd_run_ctx

comptime W = 32
comptime H = 32
comptime STEPS = 120
comptime ITERS = 10
comptime REST: Float32 = 0.05


def _corner_y(c: ClothState) -> Float32:
    return c.y[W * H - 1]


def _max_stretch(c: ClothState) -> Float32:
    var worst = Float32(0)
    for j in range(H):
        for i in range(W - 1):
            var a = j * W + i
            var dx = c.x[a + 1] - c.x[a]
            var dy = c.y[a + 1] - c.y[a]
            var dz = c.z[a + 1] - c.z[a]
            var l = (dx * dx + dy * dy + dz * dz) ** 0.5
            worst = max(worst, l / REST - 1)
    return worst


def _max_diff(a: ClothState, b: ClothState) -> Float32:
    var d = Float32(0)
    for k in range(len(a.x)):
        d = max(d, abs(a.x[k] - b.x[k]))
        d = max(d, abs(a.y[k] - b.y[k]))
        d = max(d, abs(a.z[k] - b.z[k]))
    return d


def main() raises:
    var xp = cpu_cloth_run[W, H](STEPS, ITERS, 1.0 / 60.0, REST)
    var vb = cpu_vbd_run[W, H](STEPS, ITERS, 1.0 / 60.0, REST)
    print("CPU XPBD: free corner y", _corner_y(xp), "  worst edge stretch", _max_stretch(xp))
    print("CPU VBD : free corner y", _corner_y(vb), "  worst edge stretch", _max_stretch(vb))
    comptime if has_accelerator():
        var ctx = DeviceContext()
        var gx = gpu_cloth_run_ctx[W, H](ctx, STEPS, ITERS, 1.0 / 60.0, REST)
        var gv = gpu_vbd_run_ctx[W, H](ctx, STEPS, ITERS, 1.0 / 60.0, REST)
        print("GPU XPBD vs CPU XPBD, max |diff|:", _max_diff(gx, xp))
        print("GPU VBD  vs CPU VBD,  max |diff|:", _max_diff(gv, vb))
        print("GPU matches CPU for both solvers:",
              "YES" if _max_diff(gx, xp) < 1e-3 and _max_diff(gv, vb) < 1e-3 else "NO")
    else:
        print("no accelerator: GPU rollouts skipped")
    print("both solvers keep the cloth from over-stretching (< 10%):",
          "YES" if _max_stretch(xp) < 0.1 and _max_stretch(vb) < 0.1 else "NO")
