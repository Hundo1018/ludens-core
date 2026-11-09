"""Viscoelastic tetrahedral FEM: one Maxwell branch on the first Piola stress (ROADMAP 17.58, #93).

The stress of an element is split into an equilibrium part and one relaxing part (generalised Maxwell / standard
linear solid, Simo 1987 exponential update):

    P = (1 - g) P0(F) + H,     H' = -H / tau + g dP0/dt

with P0 the elastic stress of the chosen `Material`. Under a constant F the relaxing part decays, so the stress goes
from P0 at the instant of loading to (1 - g) P0 as t grows:  P(t) = P0 ((1 - g) + g exp(-t / tau)). The update

    H_n+1 = exp(-dt / tau) H_n + g exp(-dt / (2 tau)) (P0_n+1 - P0_n)

is exact for a stress that changes linearly inside the step, so a held strain relaxes the same for any dt
(`test_fem_visco`). Material constants are the instant (glassy) ones; g in [0, 1) is the relaxing fraction and
g = 0 gives back `material_forces`. `ViscoState` keeps H and the previous P0 (9 reals each) per element.
"""

from std.math import exp, isfinite
from geometry.vec import Real, Vec3
from geometry.mat import Mat3
from .fem import FemBody
from .fem_material import Material, deformation_gradient


struct ViscoState(Movable):
    var tau: Real
    var g: Real
    var h: List[Real]  # 9 per tet, row-major
    var p0: List[Real]  # previous elastic stress, 9 per tet

    def __init__(out self, body: FemBody, tau: Real, g: Real) raises:
        if not (tau > 0) or not isfinite(tau) or not (g >= 0) or not (g < 1):
            raise Error("ViscoState: need finite tau > 0 and 0 <= g < 1")
        self.tau = tau
        self.g = g
        self.h = List[Real](length=9 * len(body.tets), fill=0)
        self.p0 = List[Real](length=9 * len(body.tets), fill=0)

    def reset_rest[M: Material](mut self, body: FemBody):
        """Take the body's current shape as the stress-free reference for the relaxing part (h = g P0, p0 = P0)."""
        for t in range(len(body.tets)):
            var p = M.pk1(deformation_gradient(body, t), body.mu, body.lam)
            for i in range(3):
                for j in range(3):
                    self.p0[9 * t + 3 * i + j] = p.get(i, j)
                    self.h[9 * t + 3 * i + j] = self.g * p.get(i, j)


def visco_forces[M: Material](
    mut st: ViscoState, body: FemBody, dt: Real, mut fx: List[Real], mut fy: List[Real], mut fz: List[Real]
):
    """Advance the relaxing stress by `dt` and accumulate the nodal forces of the total stress."""
    var a = Real(exp(Float64(-dt / st.tau)))
    var b = st.g * Real(exp(Float64(-dt / (2 * st.tau))))
    for t in range(len(body.tets)):
        var f = deformation_gradient(body, t)
        var p0 = M.pk1(f, body.mu, body.lam)
        var p = Mat3()
        for i in range(3):
            for j in range(3):
                var k = 9 * t + 3 * i + j
                var now = p0.get(i, j)
                st.h[k] = a * st.h[k] + b * (now - st.p0[k])
                st.p0[k] = now
                p.set(i, j, (1 - st.g) * now + st.h[k])
        var tt = body.tets[t]
        var hm = p * tt.dm_inv.transpose()
        var w = tt.vol
        var f1 = Vec3(-w * hm.get(0, 0), -w * hm.get(1, 0), -w * hm.get(2, 0), 0)
        var f2 = Vec3(-w * hm.get(0, 1), -w * hm.get(1, 1), -w * hm.get(2, 1), 0)
        var f3 = Vec3(-w * hm.get(0, 2), -w * hm.get(1, 2), -w * hm.get(2, 2), 0)
        var f0 = (f1 + f2 + f3) * Real(-1)
        fx[tt.a] += f0[0]
        fy[tt.a] += f0[1]
        fz[tt.a] += f0[2]
        fx[tt.b] += f1[0]
        fy[tt.b] += f1[1]
        fz[tt.b] += f1[2]
        fx[tt.c] += f2[0]
        fy[tt.c] += f2[1]
        fz[tt.c] += f2[2]
        fx[tt.d] += f3[0]
        fy[tt.d] += f3[1]
        fz[tt.d] += f3[2]


def step_visco[M: Material](mut st: ViscoState, mut body: FemBody, dt: Real, gravity: Vec3, floor_y: Real = -1e30):
    """Explicit step like `step_material`, with the viscoelastic stress."""
    var n = body.node_count()
    var fx = List[Real](length=n, fill=0)
    var fy = List[Real](length=n, fill=0)
    var fz = List[Real](length=n, fill=0)
    visco_forces[M](st, body, dt, fx, fy, fz)
    body.integrate(fx, fy, fz, dt, gravity, floor_y)
