"""Fixed MAC fluid workload for an instruction count (ROADMAP 17.98 item 7; `scripts/fn_share.py`): 2-D 32^2
and 3-D 12^3, 8 steps each, from a swirl; once semi-Lagrangian (2-D with viscosity, 3-D with confinement) and
once in flux form."""
from std.benchmark import keep
from std.math import sin, cos
from geometry.vec import Real
from physics.mac_fluid import MacFluid2
from physics.mac_fluid3 import MacFluid3


def swirl2(mut f: MacFluid2):
    var n = f.n
    for j in range(n):
        for i in range(n):
            f.u[j * n + i] = Real(0.3) * sin(Real(6.283185) * Real(j) / Real(n))
            f.v[j * n + i] = Real(0.3) * cos(Real(6.283185) * Real(i) / Real(n))


def swirl3(mut f: MacFluid3):
    var n = f.n
    for k in range(n):
        for j in range(n):
            for i in range(n):
                var c = (k * n + j) * n + i
                f.u[c] = Real(0.3) * sin(Real(6.283185) * Real(j) / Real(n))
                f.v[c] = Real(0.3) * cos(Real(6.283185) * Real(k) / Real(n))
                f.w[c] = Real(0.3) * sin(Real(6.283185) * Real(i) / Real(n))


def main() raises:
    var acc = Real(0)
    for flux in range(2):
        var f = MacFluid2(32, Real(1.0 / 32.0), Real(1e-3))
        if flux == 1:
            f.use_flux_advection()
        swirl2(f)
        for _ in range(8):
            f.step(Real(1.0 / 60.0))
        acc += f.u[17]
        var g = MacFluid3(12, Real(1.0 / 12.0), Real(1e-3))
        if flux == 1:
            g.use_flux_advection()
        else:
            g.set_confinement(0.5)
        swirl3(g)
        for _ in range(8):
            g.step(Real(1.0 / 60.0))
        acc += g.w[100]
    keep(acc)
    print(acc)
