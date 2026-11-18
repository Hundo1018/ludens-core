"""Incompressible grid fluid on a 3-D MAC grid, periodic, and buoyant smoke
on it (ROADMAP 17.60: 3-D single-phase MAC).

`MacFluid2` in three dimensions: u on the x faces (i, j + 1/2, k + 1/2) dx,
v on the y faces, w on the z faces, pressure at the cell centres. One
`step(dt)`:

  1. advect u, v, w semi-Lagrangian, RK2 backtrace, trilinear (periodic);
  2. viscosity explicitly, u += nu dt lap u (raises when
     nu dt / dx^2 > 1/6, the explicit limit in 3-D);
  3. the body force (fx, fy, fz) times dt;
  4. project: -lap p = -div u / dt with `numerics.pcg` through a
     matrix-free 7-point operator, right-hand side mean removed in f64 (the
     periodic Laplacian is singular; see `MacFluid2.project`), warm-started
     from the last pressure unless that is a worse start than zero
     (`mac_fluid.warm_start_or_zero`), then u -= dt grad p.

`Smoke3`: a cell-centred temperature advected with the flow (RK2,
trilinear) pushes the v faces by Boussinesq buoyancy,
fy = buoyancy (T - mean T); the mean is removed so the periodic box as a
whole does not accelerate.

Vorticity confinement (17.60, opt-in): `set_confinement(eps)` adds
eps dx (N x omega) to the body force, N = grad|omega| / |grad|omega|, with
omega the curl of the cell-centred velocity (central differences). eps = 0
(the default) skips it, so the off path is the same code as before. The
2-D version is `Smoke2`'s `_forces` in `mac_fluid.mojo`; this one works at the
cell centres instead of the corners.

A field that does not vary along z, with w = 0, steps like `MacFluid2`
(`test_mac_fluid3` compares them; equal to the CG tolerance, not bit for
bit -- the 3-D solve sums over n^3 cells).
"""

from geometry.vec import Real
from .mac_fluid import MacFluid

comptime MacFluid3 = MacFluid[3]
"""The periodic 3-D MAC fluid (n x n x n cells); one struct with `MacFluid2` (physics/mac_fluid.mojo)."""


struct Smoke3(Movable):
    var fluid: MacFluid3
    var temp: List[Real]
    var buoyancy: Real

    def __init__(out self, var fluid: MacFluid3, buoyancy: Real):
        var m = fluid.cells()
        self.fluid = fluid^
        self.temp = List[Real](length=m, fill=0)
        self.buoyancy = buoyancy

    def _buoyancy(mut self, dt: Real):
        var n = self.fluid.n
        var m = self.fluid.cells()
        var mean = Float64(0)
        for c in range(m):
            mean += Float64(self.temp[c])
        var tm = Real(mean / Float64(m))
        for k in range(n):
            for j in range(n):
                for i in range(n):
                    var c = (k * n + j) * n + i
                    var tf = 0.5 * (self.temp[c] + self.temp[self.fluid.idx(i, j - 1, k)])
                    self.fluid.v[c] += dt * self.buoyancy * (tf - tm)

    def _advect_temp(mut self, dt: Real):
        var n = self.fluid.n
        var dx = self.fluid.dx
        var nt = List[Real](length=self.fluid.cells(), fill=0)
        for k in range(n):
            for j in range(n):
                for i in range(n):
                    var b = self.fluid._back((Real(i) + 0.5) * dx, (Real(j) + 0.5) * dx, (Real(k) + 0.5) * dx, dt)
                    nt[(k * n + j) * n + i] = self.fluid.sample(self.temp, b[0], b[1], b[2], 0.5, 0.5, 0.5)
        self.temp = nt^

    def step(mut self, dt: Real) raises:
        self._buoyancy(dt)
        self.fluid.step(dt)
        self._advect_temp(dt)

    def heat_centre_y(self) -> Real:
        """Temperature-weighted mean height of the cells above the mean
        temperature (where the hot blob is), in metres."""
        var n = self.fluid.n
        var m = self.fluid.cells()
        var mean = Float64(0)
        for c in range(m):
            mean += Float64(self.temp[c])
        mean /= Float64(m)
        var sw = Float64(0)
        var sy = Float64(0)
        for k in range(n):
            for j in range(n):
                for i in range(n):
                    var t = Float64(self.temp[(k * n + j) * n + i]) - mean
                    if t > 0:
                        sw += t
                        sy += t * (Float64(j) + 0.5)
        return Real(sy / sw) * self.fluid.dx if sw > 0 else Real(0)
