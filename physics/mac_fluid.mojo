"""Incompressible grid fluid on a 2-D MAC grid (ROADMAP 17.60), periodic.

Stable Fluids (Stam 1999) on a staggered grid: u on the x faces
(i dx, (j + 1/2) dx), v on the y faces ((i + 1/2) dx, j dx), pressure at the
cell centres. One `step(dt)`:

  1. advect u and v semi-Lagrangian, RK2 backtrace, bilinear (periodic);
  2. viscosity explicitly, u += nu dt lap u (raises when
     nu dt / dx^2 > 1/4, the explicit limit);
  3. the body force (fx, fy) times dt;
  4. project: solve -lap p = -div u / dt with `numerics.pcg` through a
     matrix-free 5-point operator (the periodic Laplacian is singular: the
     right-hand side's mean is removed, which CG then never re-enters),
     u -= dt grad p. `use_multigrid()` swaps Jacobi PCG for
     multigrid-preconditioned CG (`numerics.multigrid`, n a power of two):
     a near-constant iteration count instead of one growing with n
     (`bench_grid_fluid`, `test_mac_multigrid`).

Lives in `physics`, not `fluid`: `fluid` and `numerics` share a layer and
may not import each other (ROADMAP 17.60's layering note). Semi-Lagrangian
advection adds numerical viscosity of order |u| dx / 2: decay-rate tests
keep the velocity small (test_taylor_green).

`MacFluid[D]` is this solver for D = 2 and 3: `MacFluid2 = MacFluid[2]` here and
`MacFluid3 = MacFluid[3]` in physics/mac_fluid3.mojo, which describes the 3-D grid and `Smoke3`.
"""

from std.math import ceil, floor, sqrt
from geometry.vec import Real
from numerics.sparse import LinearOperator
from numerics.cg import pcg, CgResult
from numerics.multigrid import PeriodicPoissonMG, pcg_mg
from numerics.multigrid3 import PeriodicPoissonMG3, pcg_mg3


struct _NegLaplacian[D: Int](LinearOperator, Movable):
    """-lap on an n^D periodic cell grid, scaled by dx^2 = 1: 2D x[c] minus the x, y (and z)
    neighbours, in that order."""

    var n: Int

    def __init__(out self, n: Int):
        self.n = n

    def _nz(self) -> Int:
        comptime if Self.D == 3:
            return self.n
        else:
            return 1

    def size(self) -> Int:
        return self.n * self.n * self._nz()

    def apply(self, x: List[Real], mut out: List[Real]):
        var n = self.n
        var nz = self._nz()
        for k in range(nz):
            var km = (k + nz - 1) % nz
            var kp = (k + 1) % nz
            for j in range(n):
                var jm = (j + n - 1) % n
                var jp = (j + 1) % n
                for i in range(n):
                    var im = (i + n - 1) % n
                    var ip = (i + 1) % n
                    var c = (k * n + j) * n + i
                    var s = (
                        Real(2 * Self.D) * x[c]
                        - x[(k * n + j) * n + im] - x[(k * n + j) * n + ip]
                        - x[(k * n + jm) * n + i] - x[(k * n + jp) * n + i]
                    )
                    comptime if Self.D == 3:
                        s = s - x[(km * n + j) * n + i] - x[(kp * n + j) * n + i]
                    out[c] = s

    def diagonal(self, mut out: List[Real]):
        for c in range(self.size()):
            out[c] = Real(2 * Self.D)


struct _MaskedNegLaplacian(LinearOperator, Movable):
    """-lap on the fluid cells of a periodic n x n grid (17.61 solid mask).

    A face between two fluid cells couples them. A face to a solid cell
    carries no flux (Neumann), so it leaves the stencil. Solid cells are
    identity rows, which keeps the operator nonsingular there. Symmetric
    positive semidefinite; its null space is the constant on each connected
    fluid region."""

    var n: Int
    var solid: List[Bool]

    def __init__(out self, n: Int, var solid: List[Bool]):
        self.n = n
        self.solid = solid^

    def size(self) -> Int:
        return self.n * self.n

    def apply(self, x: List[Real], mut out: List[Real]):
        var n = self.n
        for j in range(n):
            var jm = (j + n - 1) % n
            var jp = (j + 1) % n
            for i in range(n):
                var im = (i + n - 1) % n
                var ip = (i + 1) % n
                var k = j * n + i
                if self.solid[k]:
                    out[k] = x[k]
                    continue
                var acc = Real(0)
                if not self.solid[j * n + im]:
                    acc += x[k] - x[j * n + im]
                if not self.solid[j * n + ip]:
                    acc += x[k] - x[j * n + ip]
                if not self.solid[jm * n + i]:
                    acc += x[k] - x[jm * n + i]
                if not self.solid[jp * n + i]:
                    acc += x[k] - x[jp * n + i]
                out[k] = acc

    def diagonal(self, mut out: List[Real]):
        var n = self.n
        for j in range(n):
            var jm = (j + n - 1) % n
            var jp = (j + 1) % n
            for i in range(n):
                var im = (i + n - 1) % n
                var ip = (i + 1) % n
                var k = j * n + i
                if self.solid[k]:
                    out[k] = 1
                    continue
                var cnt = 0
                if not self.solid[j * n + im]:
                    cnt += 1
                if not self.solid[j * n + ip]:
                    cnt += 1
                if not self.solid[jm * n + i]:
                    cnt += 1
                if not self.solid[jp * n + i]:
                    cnt += 1
                out[k] = Real(cnt)


def warm_start_or_zero[Op: LinearOperator](op: Op, rhs: List[Real], mut x: List[Real]):
    """Zero `x` when it is a worse start than zero, ||b - A x|| > ||b||
    (ROADMAP 17.60). A projection warm-started from the last pressure
    after the flow has become divergence-free faces a right-hand side of
    rounding noise: the old pressure's residual is then many times ||b||,
    CG cannot reach tol ||b|| from it in f32 and breaks down, and the
    pressure it leaves injects velocity (a 2-D MAC field grew from
    |u| 0.05 to 667 in 15 steps). From zero the same solve converges."""
    var ax = List[Real](length=len(x), fill=0)
    op.apply(x, ax)
    var rr = Float64(0)
    var bb = Float64(0)
    for k in range(len(x)):
        var d = Float64(rhs[k]) - Float64(ax[k])
        rr += d * d
        bb += Float64(rhs[k]) * Float64(rhs[k])
    if rr > bb:
        for k in range(len(x)):
            x[k] = 0


def _spread_face(mut f: List[Real], n: Int, dx: Real, x: Real, y: Real, ox: Real, oy: Real, amount: Real):
    """Adjoint of `MacFluid2.sample`: adds `amount` to the four samples around
    (x, y), weighted as the sampling weights, so the four weights sum to one."""
    var gx = x / dx - ox
    var gy = y / dx - oy
    var i0 = Int(floor(gx))
    var j0 = Int(floor(gy))
    var ax = gx - Real(i0)
    var ay = gy - Real(j0)
    var a = ((i0 % n) + n) % n
    var b = ((i0 + 1) % n + n) % n
    var c = ((j0 % n) + n) % n
    var d = ((j0 + 1) % n + n) % n
    f[c * n + a] += amount * (1 - ax) * (1 - ay)
    f[c * n + b] += amount * ax * (1 - ay)
    f[d * n + a] += amount * (1 - ax) * ay
    f[d * n + b] += amount * ax * ay



def _spread3(mut f: List[Real], n: Int, dx: Real, x: Real, y: Real, z: Real, ox: Real, oy: Real, oz: Real, amount: Real):
    """Adjoint of `MacFluid3.sample`: adds `amount` to the eight samples around
    (x, y, z), weighted as the sampling weights, so the weights sum to one."""
    var gx = x / dx - ox
    var gy = y / dx - oy
    var gz = z / dx - oz
    var i0 = Int(floor(gx))
    var j0 = Int(floor(gy))
    var k0 = Int(floor(gz))
    var ax = gx - Real(i0)
    var ay = gy - Real(j0)
    var az = gz - Real(k0)
    for dk in range(2):
        var wz = az if dk == 1 else 1 - az
        var c = ((k0 + dk) % n + n) % n
        for dj in range(2):
            var wy = ay if dj == 1 else 1 - ay
            var b = ((j0 + dj) % n + n) % n
            for di in range(2):
                var wx = ax if di == 1 else 1 - ax
                var a = ((i0 + di) % n + n) % n
                f[(c * n + b) * n + a] += amount * wx * wy * wz



struct MacFluid[D: Int](Movable):
    """The periodic MAC fluid on an n^D grid, D = 2 or 3 (`MacFluid2` here, `MacFluid3` in
    physics/mac_fluid3.mojo). Every array is indexed (k n + j) n + i with one z layer in 2-D, so the 2-D
    indices are the 3-D ones at k = 0. Each sum is written in the order both solvers used (the x terms,
    then y, then z), so a 2-D sum is the 3-D one without its z terms. Per dimension remain: bilinear
    against trilinear sampling and spreading, `momentum`'s dx^D product, the explicit viscosity limit,
    the multigrid type, the solid mask and momentum fix (2-D) and vorticity confinement (3-D)."""

    comptime MG = PeriodicPoissonMG if Self.D == 2 else PeriodicPoissonMG3
    comptime Vec = Tuple[Real, Real] if Self.D == 2 else Tuple[Real, Real, Real]

    var n: Int  # cells per side
    var dx: Real
    var nu: Real  # kinematic viscosity
    var fx: Real  # body force (acceleration)
    var fy: Real
    var fz: Real  # 3-D only (0 in 2-D)
    var epsilon: Real  # vorticity confinement strength, 0 = off (3-D only)
    var u: List[Real]  # [(k n + j) n + i] at (i, j + 1/2, k + 1/2) dx
    var v: List[Real]  # at (i + 1/2, j, k + 1/2) dx
    var w: List[Real]  # at (i + 1/2, j + 1/2, k) dx; empty in 2-D
    var p: List[Real]  # last pressure (warm start), cell centres
    var last: CgResult
    var mg: Optional[Self.MG]  # set by use_multigrid
    var fix_momentum: Bool  # set by use_momentum_fix (2-D)
    var momentum_booked: Real  # sum of |momentum corrections| applied (x and y)
    var flux_advect: Bool  # set by use_flux_advection
    var flux_substeps: Int  # sub-steps taken by `_advect_flux`, summed
    var solid: List[Bool]  # set by set_solid (2-D); empty means no solid cell

    def __init__(out self, n: Int, dx: Real, nu: Real) raises:
        comptime assert Self.D == 2 or Self.D == 3, "MacFluid: D is 2 or 3"
        if n < 4 or not (dx > 0) or not (nu >= 0):
            raise Error("MacFluid" + String(Self.D) + ": n >= 4, dx > 0, nu >= 0")
        self.n = n
        self.dx = dx
        self.nu = nu
        self.fx = 0
        self.fy = 0
        self.fz = 0
        self.epsilon = 0
        var m = n * n * (n if Self.D == 3 else 1)
        self.u = List[Real](length=m, fill=0)
        self.v = List[Real](length=m, fill=0)
        self.w = List[Real](length=m if Self.D == 3 else 0, fill=0)
        self.p = List[Real](length=m, fill=0)
        self.last = CgResult(True, False, 0, 0)
        self.mg = None
        self.fix_momentum = False
        self.momentum_booked = 0
        self.flux_advect = False
        self.flux_substeps = 0
        self.solid = List[Bool]()

    def _nz(self) -> Int:
        """Cells along z: n in 3-D, 1 in 2-D."""
        comptime if Self.D == 3:
            return self.n
        else:
            return 1

    def cells(self) -> Int:
        return self.n * self.n * self._nz()

    def set_solid(mut self, var mask: List[Bool]) raises:
        """Mark cells solid (opt-in; the default empty mask leaves the solver
        unchanged). Faces that touch a solid cell carry no normal flux: they
        are zeroed before each projection and the pressure solve treats them
        as walls. Every fluid cell needs a fluid neighbour, so the operator has
        no empty row. Not available with multigrid. 2-D only."""
        comptime assert Self.D == 2, "set_solid is 2-D only"
        var n = self.n
        if len(mask) != n * n:
            raise Error("MacFluid2.set_solid: mask length must be n * n")
        if self.mg:
            raise Error("MacFluid2.set_solid: the solid mask is not supported with multigrid")
        var fluid = 0
        for j in range(n):
            var jm = (j + n - 1) % n
            var jp = (j + 1) % n
            for i in range(n):
                var im = (i + n - 1) % n
                var ip = (i + 1) % n
                if mask[j * n + i]:
                    continue
                fluid += 1
                var nb = 0
                if not mask[j * n + im]:
                    nb += 1
                if not mask[j * n + ip]:
                    nb += 1
                if not mask[jm * n + i]:
                    nb += 1
                if not mask[jp * n + i]:
                    nb += 1
                if nb == 0:
                    raise Error("MacFluid2.set_solid: a fluid cell has no fluid neighbour")
        if fluid == 0:
            raise Error("MacFluid2.set_solid: the mask leaves no fluid cell")
        self.solid = mask^

    def use_momentum_fix(mut self):
        """Restore the total momentum after each advection (opt-in; off by
        default so the semi-Lagrangian default path is unchanged). The applied
        corrections are summed in `momentum_booked`. 2-D only."""
        comptime assert Self.D == 2, "use_momentum_fix is 2-D only"
        self.fix_momentum = True

    def use_flux_advection(mut self):
        """Advect the faces in flux form, `_advect_flux`, instead of
        semi-Lagrangian (opt-in; off by default). Total momentum is conserved
        by construction, so `momentum_booked` stays zero on this path."""
        self.flux_advect = True

    def set_confinement(mut self, eps: Real) raises:
        comptime assert Self.D == 3, "set_confinement is 3-D only (2-D confinement is Smoke2's epsilon)"
        if not (eps >= 0):
            raise Error("MacFluid3.set_confinement: eps must be >= 0")
        self.epsilon = eps

    def momentum(self) -> Self.Vec:
        """Total (sum u dx^D, sum v dx^D[, sum w dx^D]), accumulated in f64."""
        var sx = Float64(0)
        var sy = Float64(0)
        var sz = Float64(0)
        for c in range(self.cells()):
            sx += Float64(self.u[c])
            sy += Float64(self.v[c])
            comptime if Self.D == 3:
                sz += Float64(self.w[c])
        comptime if Self.D == 2:
            var a = Real(sx * Float64(self.dx) * Float64(self.dx))
            var b = Real(sy * Float64(self.dx) * Float64(self.dx))
            return rebind[Self.Vec]((a, b))
        else:
            var s = Float64(self.dx) * Float64(self.dx) * Float64(self.dx)
            return rebind[Self.Vec]((Real(sx * s), Real(sy * s), Real(sz * s)))

    def use_multigrid(mut self) raises:
        """Project with MGPCG from now on; raises unless n is a power of two.
        Not available once a solid mask is set."""
        comptime if Self.D == 2:
            if len(self.solid) > 0:
                raise Error("MacFluid2.use_multigrid: not supported with a solid mask")
            self.mg = rebind_var[Optional[Self.MG]](Optional(PeriodicPoissonMG(self.n)))
        else:
            self.mg = rebind_var[Optional[Self.MG]](Optional(PeriodicPoissonMG3(self.n)))

    def _w(self, i: Int) -> Int:
        return ((i % self.n) + self.n) % self.n

    def idx(self, i: Int, j: Int, k: Int) -> Int:
        """The cell (i, j, k) wrapped into the periodic box (k ignored in 2-D)."""
        var n = self.n
        comptime if Self.D == 2:
            return (((j % n) + n) % n) * n + (((i % n) + n) % n)
        else:
            return ((((k % n) + n) % n) * n + (((j % n) + n) % n)) * n + (((i % n) + n) % n)

    def sample(self, f: List[Real], x: Real, y: Real, z: Real, ox: Real, oy: Real, oz: Real) -> Real:
        """Bilinear (2-D, z and oz unused) or trilinear sample of a staggered field whose (i, j, k)
        value sits at ((i + ox) dx, (j + oy) dx, (k + oz) dx)."""
        var gx = x / self.dx - ox
        var gy = y / self.dx - oy
        var i0 = Int(floor(gx))
        var j0 = Int(floor(gy))
        var ax = gx - Real(i0)
        var ay = gy - Real(j0)
        comptime if Self.D == 2:
            var n = self.n
            var a = self._w(i0)
            var b = self._w(i0 + 1)
            var c = self._w(j0)
            var d = self._w(j0 + 1)
            var lo = f[c * n + a] * (1 - ax) + f[c * n + b] * ax
            var hi = f[d * n + a] * (1 - ax) + f[d * n + b] * ax
            return lo * (1 - ay) + hi * ay
        else:
            var gz = z / self.dx - oz
            var k0 = Int(floor(gz))
            var az = gz - Real(k0)
            var c00 = f[self.idx(i0, j0, k0)] * (1 - ax) + f[self.idx(i0 + 1, j0, k0)] * ax
            var c10 = f[self.idx(i0, j0 + 1, k0)] * (1 - ax) + f[self.idx(i0 + 1, j0 + 1, k0)] * ax
            var c01 = f[self.idx(i0, j0, k0 + 1)] * (1 - ax) + f[self.idx(i0 + 1, j0, k0 + 1)] * ax
            var c11 = f[self.idx(i0, j0 + 1, k0 + 1)] * (1 - ax) + f[self.idx(i0 + 1, j0 + 1, k0 + 1)] * ax
            var lo = c00 * (1 - ay) + c10 * ay
            var hi = c01 * (1 - ay) + c11 * ay
            return lo * (1 - az) + hi * az

    def velocity(self, x: Real, y: Real) -> Tuple[Real, Real]:
        comptime assert Self.D == 2, "velocity(x, y) is the 2-D form"
        return (self.sample(self.u, x, y, 0, 0, 0.5, 0), self.sample(self.v, x, y, 0, 0.5, 0, 0))

    def velocity(self, x: Real, y: Real, z: Real) -> Tuple[Real, Real, Real]:
        comptime assert Self.D == 3, "velocity(x, y, z) is the 3-D form"
        return (
            self.sample(self.u, x, y, z, 0, 0.5, 0.5),
            self.sample(self.v, x, y, z, 0.5, 0, 0.5),
            self.sample(self.w, x, y, z, 0.5, 0.5, 0),
        )

    def _vel(self, x: Real, y: Real, z: Real) -> Tuple[Real, Real, Real]:
        """velocity in either dimension, z = 0 in 2-D."""
        comptime if Self.D == 2:
            var v = self.velocity(x, y)
            return (v[0], v[1], Real(0))
        else:
            return self.velocity(x, y, z)

    def _back(self, x: Real, y: Real, z: Real, dt: Real) -> Tuple[Real, Real, Real]:
        """RK2 (midpoint) backtrace of the point (x, y, z) over dt (z unused in 2-D)."""
        var v0 = self._vel(x, y, z)
        var vm = self._vel(x - 0.5 * dt * v0[0], y - 0.5 * dt * v0[1], z - 0.5 * dt * v0[2])
        return (x - dt * vm[0], y - dt * vm[1], z - dt * vm[2])

    def add_impulse(mut self, x: Real, y: Real, ix: Real, iy: Real):
        """Adds the momentum impulse (ix, iy) per unit density at the point (x, y).
        The impulse is spread onto the staggered faces with the velocity-sampling
        weights, so the total momentum sum(u) dx^2 rises by exactly ix (and
        sum(v) dx^2 by iy); density is 1, as in the rest of this struct."""
        comptime assert Self.D == 2, "add_impulse(x, y, ix, iy) is the 2-D form"
        var inv = 1 / (self.dx * self.dx)
        _spread_face(self.u, self.n, self.dx, x, y, 0, 0.5, ix * inv)
        _spread_face(self.v, self.n, self.dx, x, y, 0.5, 0, iy * inv)

    def add_impulse(mut self, x: Real, y: Real, z: Real, ix: Real, iy: Real, iz: Real):
        """Adds the momentum impulse (ix, iy, iz) per unit density at (x, y, z).
        Spread onto the 8 nearest samples of each staggered component with the
        velocity-sampling (trilinear) weights, so sum(u) dx^3 rises by exactly
        ix, and likewise for v and w. Density is 1, as in `MacFluid2`."""
        comptime assert Self.D == 3, "add_impulse with six arguments is the 3-D form"
        var inv = 1 / (self.dx * self.dx * self.dx)
        _spread3(self.u, self.n, self.dx, x, y, z, 0, 0.5, 0.5, ix * inv)
        _spread3(self.v, self.n, self.dx, x, y, z, 0.5, 0, 0.5, iy * inv)
        _spread3(self.w, self.n, self.dx, x, y, z, 0.5, 0.5, 0, iz * inv)

    def divergence(self) -> List[Real]:
        """Per cell, (du/dx + dv/dy [+ dw/dz])."""
        var n = self.n
        var nz = self._nz()
        var out = List[Real](length=self.cells(), fill=0)
        for k in range(nz):
            var kp = (k + 1) % nz
            for j in range(n):
                var jp = (j + 1) % n
                for i in range(n):
                    var ip = (i + 1) % n
                    var c = (k * n + j) * n + i
                    var s = self.u[(k * n + j) * n + ip] - self.u[c] + self.v[(k * n + jp) * n + i] - self.v[c]
                    comptime if Self.D == 3:
                        s = s + self.w[(kp * n + j) * n + i] - self.w[c]
                    out[c] = s / self.dx
        return out^

    def _advect(mut self, dt: Real):
        var n = self.n
        var dx = self.dx
        var m = self.cells()
        var nu_ = List[Real](length=m, fill=0)
        var nv_ = List[Real](length=m, fill=0)
        var nw_ = List[Real](length=len(self.w), fill=0)
        for k in range(self._nz()):
            for j in range(n):
                for i in range(n):
                    var c = (k * n + j) * n + i
                    var b = self._back(Real(i) * dx, (Real(j) + 0.5) * dx, (Real(k) + 0.5) * dx, dt)
                    nu_[c] = self.sample(self.u, b[0], b[1], b[2], 0, 0.5, 0.5)
                    b = self._back((Real(i) + 0.5) * dx, Real(j) * dx, (Real(k) + 0.5) * dx, dt)
                    nv_[c] = self.sample(self.v, b[0], b[1], b[2], 0.5, 0, 0.5)
                    comptime if Self.D == 3:
                        b = self._back((Real(i) + 0.5) * dx, (Real(j) + 0.5) * dx, Real(k) * dx, dt)
                        nw_[c] = self.sample(self.w, b[0], b[1], b[2], 0.5, 0.5, 0)
        self.u = nu_^
        self.v = nv_^
        self.w = nw_^

    def _lap(self, f: List[Real], c: Int, xm: Int, xp: Int, ym: Int, yp: Int, zm: Int, zp: Int) -> Real:
        """The periodic Laplacian sum at cell c (neighbour cell indices given; the z pair unused in
        2-D): x, y, z neighbours in that order, minus 2D f[c]."""
        var s = f[xm] + f[xp] + f[ym] + f[yp]
        comptime if Self.D == 3:
            s = s + f[zm] + f[zp]
        return s - Real(2 * Self.D) * f[c]

    def _diffuse(mut self, dt: Real):
        var n = self.n
        var nz = self._nz()
        var a = self.nu * dt / (self.dx * self.dx)
        var nu_ = self.u.copy()
        var nv_ = self.v.copy()
        var nw_ = self.w.copy()
        for k in range(nz):
            var km = (k + nz - 1) % nz
            var kp = (k + 1) % nz
            for j in range(n):
                var jm = (j + n - 1) % n
                var jp = (j + 1) % n
                for i in range(n):
                    var im = (i + n - 1) % n
                    var ip = (i + 1) % n
                    var c = (k * n + j) * n + i
                    var xm = (k * n + j) * n + im
                    var xp = (k * n + j) * n + ip
                    var ym = (k * n + jm) * n + i
                    var yp = (k * n + jp) * n + i
                    var zm = (km * n + j) * n + i
                    var zp = (kp * n + j) * n + i
                    nu_[c] += a * self._lap(self.u, c, xm, xp, ym, yp, zm, zp)
                    nv_[c] += a * self._lap(self.v, c, xm, xp, ym, yp, zm, zp)
                    comptime if Self.D == 3:
                        nw_[c] += a * self._lap(self.w, c, xm, xp, ym, yp, zm, zp)
        self.u = nu_^
        self.v = nv_^
        self.w = nw_^

    def _zero_solid_faces(mut self):
        """Hold the normal velocity on every face that touches a solid cell at
        zero (the u face on a cell's left and right, the v face below and
        above it). 2-D only (the mask is)."""
        var n = self.n
        for j in range(n):
            var jp = (j + 1) % n
            for i in range(n):
                var k = j * n + i
                if not self.solid[k]:
                    continue
                var ip = (i + 1) % n
                self.u[k] = 0
                self.u[j * n + ip] = 0
                self.v[k] = 0
                self.v[jp * n + i] = 0

    def project(mut self, dt: Real, tol: Real = 1e-6) -> CgResult:
        var n = self.n
        var nz = self._nz()
        var m = self.cells()
        var masked = len(self.solid) > 0
        if masked:
            self._zero_solid_faces()
        var div = self.divergence()
        # -lap p = -div / dt, in dx^2 = 1 units: rhs = -div dx^2 / dt
        var rhs = List[Real](length=m, fill=0)
        # The periodic Laplacian is singular: remove the mean in f64. An f32
        # sum over the cells left a mean of ~n^D eps |rhs| that CG cannot
        # reduce, so it never met tol, ran 4 n^D iterations, and the constant
        # it piled into p cost f32 its pressure differences (a heated row
        # under Smoke2 blew up to 1e11 m/s in 0.3 s; 17.61). With solid cells
        # the mean runs over the fluid cells only, and solid rows stay zero.
        var fluid = 0
        for c in range(m):
            if not masked or not self.solid[c]:
                fluid += 1
        var mean = Float64(0)
        for c in range(m):
            if masked and self.solid[c]:
                continue
            rhs[c] = -div[c] * self.dx * self.dx / dt
            mean += Float64(rhs[c])
        mean /= Float64(fluid)
        for c in range(m):
            if masked and self.solid[c]:
                continue
            rhs[c] = Real(Float64(rhs[c]) - mean)
        var r: CgResult
        var op = _NegLaplacian[Self.D](n)
        comptime if Self.D == 2:
            if masked:
                var mop = _MaskedNegLaplacian(n, self.solid.copy())
                warm_start_or_zero(mop, rhs, self.p)
                r = pcg(mop, rhs, self.p, tol, 4 * m)
            else:
                warm_start_or_zero(op, rhs, self.p)
                if case .Some(ref mg) = self.mg:
                    r = pcg_mg(op, rebind[PeriodicPoissonMG](mg), rhs, self.p, tol, 4 * m)
                else:
                    r = pcg(op, rhs, self.p, tol, 4 * m)
        else:
            warm_start_or_zero(op, rhs, self.p)
            if case .Some(ref mg) = self.mg:
                r = pcg_mg3(op, rebind[PeriodicPoissonMG3](mg), rhs, self.p, tol, 4 * m)
            else:
                r = pcg(op, rhs, self.p, tol, 4 * m)
        for k in range(nz):
            var km = (k + nz - 1) % nz
            for j in range(n):
                var jm = (j + n - 1) % n
                for i in range(n):
                    var im = (i + n - 1) % n
                    var c = (k * n + j) * n + i
                    var cl = (k * n + j) * n + im
                    var cd = (k * n + jm) * n + i
                    # A face that touches a solid cell keeps its zero normal velocity.
                    if not masked or not (self.solid[c] or self.solid[cl]):
                        self.u[c] -= dt * (self.p[c] - self.p[cl]) / self.dx
                    if not masked or not (self.solid[c] or self.solid[cd]):
                        self.v[c] -= dt * (self.p[c] - self.p[cd]) / self.dx
                    comptime if Self.D == 3:
                        self.w[c] -= dt * (self.p[c] - self.p[(km * n + j) * n + i]) / self.dx
        self.last = r
        return r

    def _advect_flux(mut self, dt: Real):
        """Flux-form (finite-volume) advection, first-order upwind (17.61).

        Each face is advected through its own control volume: the u face at
        (i, j + 1/2) owns [i - 1/2, i + 1/2] x [j, j + 1] (x [k, k + 1] in 3-D);
        the v and w faces are the same with their roles permuted. The advecting
        speed on each side is the average of the two staggered components there,
        and the advected value is taken upwind. The flux through a shared side is
        computed once from the same arrays by both neighbours, so the periodic
        sum over the grid telescopes: total momentum is conserved to rounding
        with no correction term. The scheme is first order and therefore
        diffusive: the upwind value is the cell value, not an interpolated
        one, which dissipates small-scale swirl that semi-Lagrangian keeps.
        Explicit and unsplit, so stability needs D |u|max h <= 1 (h = sub-step
        dt / dx). The step is sub-cycled: the count is ceil(D |u|max dt / dx),
        and each sub-step is itself a conservative flux update, so the total is
        still conserved. Without sub-cycling the 17.61 k = 5 run goes to NaN
        within 3 steps (face speeds reach 1000 m/s against dx / dt = 3.75)."""
        var umax = Real(0)
        for c in range(self.cells()):
            comptime if Self.D == 2:
                umax = max(umax, max(abs(self.u[c]), abs(self.v[c])))
            else:
                umax = max(umax, max(abs(self.u[c]), max(abs(self.v[c]), abs(self.w[c]))))
        var need = Real(Self.D) * umax * dt / self.dx
        var sub = 1
        if need > 1:
            sub = Int(ceil(need))
        var h = dt / Real(sub) / self.dx
        self.flux_substeps += sub
        for _ in range(sub):
            self._flux_once(h)

    def _flux_once(mut self, h: Real):
        """One conservative flux update with step h = sub-step / dx. The z sides (3-D) are added
        after the x and y sides, as in each solver's original sum."""
        var n = self.n
        var nz = self._nz()
        var m = self.cells()
        var u0 = self.u.copy()
        var v0 = self.v.copy()
        var w0 = self.w.copy()
        var nu_ = List[Real](length=m, fill=0)
        var nv_ = List[Real](length=m, fill=0)
        var nw_ = List[Real](length=len(self.w), fill=0)
        for k in range(nz):
            var km = (k + nz - 1) % nz
            var kp = (k + 1) % nz
            for j in range(n):
                var jm = (j + n - 1) % n
                var jp = (j + 1) % n
                for i in range(n):
                    var im = (i + n - 1) % n
                    var ip = (i + 1) % n
                    var c = (k * n + j) * n + i
                    var c_xm = (k * n + j) * n + im
                    var c_xp = (k * n + j) * n + ip
                    var c_ym = (k * n + jm) * n + i
                    var c_yp = (k * n + jp) * n + i
                    # u face: east / west sides at x = i +- 1/2, speed from u
                    var ue = 0.5 * (u0[c] + u0[c_xp])
                    var fe = ue * (u0[c] if ue > 0 else u0[c_xp])
                    var uw = 0.5 * (u0[c_xm] + u0[c])
                    var fw = uw * (u0[c_xm] if uw > 0 else u0[c])
                    # north / south sides at y = j + 1, j, speed from v at x = i +- 1/2
                    var vn = 0.5 * (v0[(k * n + jp) * n + im] + v0[c_yp])
                    var fnorth = vn * (u0[c] if vn > 0 else u0[c_yp])
                    var vs = 0.5 * (v0[c_xm] + v0[c])
                    var fs = vs * (u0[c_ym] if vs > 0 else u0[c])
                    var acc = (fe - fw) + (fnorth - fs)
                    comptime if Self.D == 3:
                        var c_zm = (km * n + j) * n + i
                        var c_zp = (kp * n + j) * n + i
                        var wt = 0.5 * (w0[(kp * n + j) * n + im] + w0[c_zp])
                        var ft = wt * (u0[c] if wt > 0 else u0[c_zp])
                        var wb = 0.5 * (w0[c_xm] + w0[c])
                        var fb = wb * (u0[c_zm] if wb > 0 else u0[c])
                        acc = acc + (ft - fb)
                    nu_[c] = u0[c] - h * acc
                    # v face: east / west sides at x = i + 1, i, speed from u at y = j +- 1/2
                    ue = 0.5 * (u0[(k * n + jm) * n + ip] + u0[c_xp])
                    fe = ue * (v0[c] if ue > 0 else v0[c_xp])
                    uw = 0.5 * (u0[c_ym] + u0[c])
                    fw = uw * (v0[c_xm] if uw > 0 else v0[c])
                    # north / south sides at y = j + 1/2, j - 1/2, speed from v
                    var vnv = 0.5 * (v0[c] + v0[c_yp])
                    fnorth = vnv * (v0[c] if vnv > 0 else v0[c_yp])
                    var vsv = 0.5 * (v0[c_ym] + v0[c])
                    fs = vsv * (v0[c_ym] if vsv > 0 else v0[c])
                    acc = (fe - fw) + (fnorth - fs)
                    comptime if Self.D == 3:
                        var c_zm = (km * n + j) * n + i
                        var c_zp = (kp * n + j) * n + i
                        var wt = 0.5 * (w0[(kp * n + jm) * n + i] + w0[c_zp])
                        var ft = wt * (v0[c] if wt > 0 else v0[c_zp])
                        var wb = 0.5 * (w0[c_ym] + w0[c])
                        var fb = wb * (v0[c_zm] if wb > 0 else v0[c])
                        acc = acc + (ft - fb)
                    nv_[c] = v0[c] - h * acc
                    comptime if Self.D == 3:
                        # w face: x sides speed from u; y sides from v; z sides from w
                        var c_zm = (km * n + j) * n + i
                        var c_zp = (kp * n + j) * n + i
                        ue = 0.5 * (u0[(km * n + j) * n + ip] + u0[c_xp])
                        fe = ue * (w0[c] if ue > 0 else w0[c_xp])
                        uw = 0.5 * (u0[c_zm] + u0[c])
                        fw = uw * (w0[c_xm] if uw > 0 else w0[c])
                        vn = 0.5 * (v0[(km * n + jp) * n + i] + v0[c_yp])
                        fnorth = vn * (w0[c] if vn > 0 else w0[c_yp])
                        vs = 0.5 * (v0[c_zm] + v0[c])
                        fs = vs * (w0[c_ym] if vs > 0 else w0[c])
                        var wtw = 0.5 * (w0[c] + w0[c_zp])
                        var ft = wtw * (w0[c] if wtw > 0 else w0[c_zp])
                        var wbw = 0.5 * (w0[c_zm] + w0[c])
                        var fb = wbw * (w0[c_zm] if wbw > 0 else w0[c])
                        nw_[c] = w0[c] - h * ((fe - fw) + (fnorth - fs) + (ft - fb))
        self.u = nu_^
        self.v = nv_^
        self.w = nw_^

    # ------------------------------------------------------- 3-D confinement
    def _centre_velocity(self) -> Tuple[List[Real], List[Real], List[Real]]:
        """Face velocities averaged to the cell centres (3-D)."""
        var m = self.cells()
        var uc = List[Real](length=m, fill=0)
        var vc = List[Real](length=m, fill=0)
        var wc = List[Real](length=m, fill=0)
        for k in range(self.n):
            for j in range(self.n):
                for i in range(self.n):
                    var c = self.idx(i, j, k)
                    uc[c] = 0.5 * (self.u[c] + self.u[self.idx(i + 1, j, k)])
                    vc[c] = 0.5 * (self.v[c] + self.v[self.idx(i, j + 1, k)])
                    wc[c] = 0.5 * (self.w[c] + self.w[self.idx(i, j, k + 1)])
        return (uc^, vc^, wc^)

    def vorticity(self) -> Tuple[List[Real], List[Real], List[Real]]:
        """Curl of the cell-centred velocity (central differences, periodic). 3-D only; the 2-D
        corner vorticity is `Smoke2.vorticity`."""
        comptime assert Self.D == 3, "MacFluid.vorticity is 3-D only"
        var vel = self._centre_velocity()
        ref uc = vel[0]
        ref vc = vel[1]
        ref wc = vel[2]
        var m = self.cells()
        var ox = List[Real](length=m, fill=0)
        var oy = List[Real](length=m, fill=0)
        var oz = List[Real](length=m, fill=0)
        var h = 2 * self.dx
        for k in range(self.n):
            for j in range(self.n):
                for i in range(self.n):
                    var c = self.idx(i, j, k)
                    ox[c] = (wc[self.idx(i, j + 1, k)] - wc[self.idx(i, j - 1, k)]) / h - (vc[self.idx(i, j, k + 1)] - vc[self.idx(i, j, k - 1)]) / h
                    oy[c] = (uc[self.idx(i, j, k + 1)] - uc[self.idx(i, j, k - 1)]) / h - (wc[self.idx(i + 1, j, k)] - wc[self.idx(i - 1, j, k)]) / h
                    oz[c] = (vc[self.idx(i + 1, j, k)] - vc[self.idx(i - 1, j, k)]) / h - (uc[self.idx(i, j + 1, k)] - uc[self.idx(i, j - 1, k)]) / h
        return (ox^, oy^, oz^)

    def enstrophy(self) -> Real:
        """Sum of |omega|^2 over the cells, times dx^3. 3-D only."""
        comptime assert Self.D == 3, "MacFluid.enstrophy is 3-D only"
        var om = self.vorticity()
        ref ox = om[0]
        ref oy = om[1]
        ref oz = om[2]
        var e = Real(0)
        for c in range(self.cells()):
            e += ox[c] * ox[c] + oy[c] * oy[c] + oz[c] * oz[c]
        return e * self.dx * self.dx * self.dx

    def _confine(mut self, dt: Real):
        """Adds dt eps dx (N x omega) to the faces; the force is taken from the
        velocity at the start of the call, all components before any face moves. 3-D."""
        var n = self.n
        var m = self.cells()
        var dx = self.dx
        var om = self.vorticity()
        ref ox = om[0]
        ref oy = om[1]
        ref oz = om[2]
        var mag = List[Real](length=m, fill=0)
        for c in range(m):
            mag[c] = sqrt(ox[c] * ox[c] + oy[c] * oy[c] + oz[c] * oz[c])
        var fx = List[Real](length=m, fill=0)
        var fy = List[Real](length=m, fill=0)
        var fz = List[Real](length=m, fill=0)
        var h = 2 * dx
        var scale = self.epsilon * dx
        for k in range(n):
            for j in range(n):
                for i in range(n):
                    var c = self.idx(i, j, k)
                    var gx = (mag[self.idx(i + 1, j, k)] - mag[self.idx(i - 1, j, k)]) / h
                    var gy = (mag[self.idx(i, j + 1, k)] - mag[self.idx(i, j - 1, k)]) / h
                    var gz = (mag[self.idx(i, j, k + 1)] - mag[self.idx(i, j, k - 1)]) / h
                    var gl = sqrt(gx * gx + gy * gy + gz * gz) + 1e-12
                    var nx = gx / gl
                    var ny = gy / gl
                    var nz = gz / gl
                    var wx = ox[c]
                    var wy = oy[c]
                    var wz = oz[c]
                    fx[c] = scale * (ny * wz - nz * wy)
                    fy[c] = scale * (nz * wx - nx * wz)
                    fz[c] = scale * (nx * wy - ny * wx)
        for k in range(n):
            for j in range(n):
                for i in range(n):
                    var c = self.idx(i, j, k)
                    # each face sits between the two cells on either side of it
                    self.u[c] += dt * 0.5 * (fx[self.idx(i - 1, j, k)] + fx[c])
                    self.v[c] += dt * 0.5 * (fy[self.idx(i, j - 1, k)] + fy[c])
                    self.w[c] += dt * 0.5 * (fz[self.idx(i, j, k - 1)] + fz[c])

    def step(mut self, dt: Real) raises:
        if not (dt > 0):
            raise Error("MacFluid" + String(Self.D) + ".step: dt must be > 0")
        comptime if Self.D == 2:
            if self.nu * dt / (self.dx * self.dx) > 0.25:
                raise Error("MacFluid2.step: nu dt / dx^2 > 1/4 (explicit viscosity limit)")
        else:
            if self.nu * dt / (self.dx * self.dx) > Real(1.0 / 6.0):
                raise Error("MacFluid3.step: nu dt / dx^2 > 1/6 (explicit viscosity limit)")
        comptime if Self.D == 2:
            var m0 = rebind[Tuple[Real, Real]](self.momentum()) if self.fix_momentum else (Real(0), Real(0))
            if self.flux_advect:
                self._advect_flux(dt)
            else:
                self._advect(dt)
            if self.fix_momentum:
                # Semi-Lagrangian advection changes sum(u) and sum(v) by the
                # interpolation residual, though the periodic box has no external
                # momentum source. Shift every face by the same amount so the total
                # matches m0. A constant has zero divergence on the periodic grid,
                # so the projection is unaffected. This restores the total only:
                # the local distribution keeps the advection error.
                var m1 = rebind[Tuple[Real, Real]](self.momentum())
                var cells = Real(self.n * self.n) * self.dx * self.dx
                var du = (m0[0] - m1[0]) / cells
                var dv = (m0[1] - m1[1]) / cells
                for k in range(self.n * self.n):
                    self.u[k] += du
                    self.v[k] += dv
                self.momentum_booked += abs(m0[0] - m1[0]) + abs(m0[1] - m1[1])
        else:
            if self.flux_advect:
                self._advect_flux(dt)
            else:
                self._advect(dt)
        if self.nu > 0:
            self._diffuse(dt)
        if self.fx != 0 or self.fy != 0 or self.fz != 0:
            for c in range(self.cells()):
                self.u[c] += self.fx * dt
                self.v[c] += self.fy * dt
                comptime if Self.D == 3:
                    self.w[c] += self.fz * dt
        comptime if Self.D == 3:
            if self.epsilon > 0:
                self._confine(dt)
        _ = self.project(dt)

    def kinetic_energy(self) -> Real:
        """Sum of |u|^2 / 2 over the faces, times dx^D."""
        var e = Real(0)
        for c in range(self.cells()):
            comptime if Self.D == 2:
                e += 0.5 * (self.u[c] * self.u[c] + self.v[c] * self.v[c])
            else:
                e += 0.5 * (self.u[c] * self.u[c] + self.v[c] * self.v[c] + self.w[c] * self.w[c])
        comptime if Self.D == 2:
            return e * self.dx * self.dx
        else:
            return e * self.dx * self.dx * self.dx


comptime MacFluid2 = MacFluid[2]
"""The periodic 2-D MAC fluid (n x n cells)."""


struct Smoke2(Movable):
    """Buoyant smoke on a `MacFluid2` (Fedkiw, Stam & Jensen 2001), 17.60.

    A temperature field `temp` at the cell centres is advected with the
    flow (semi-Lagrangian, RK2); it pushes up by Boussinesq buoyancy,
    fy = buoyancy (T - mean T) -- the mean is removed so a periodic box as
    a whole does not accelerate -- and vorticity confinement adds
    epsilon dx (N x omega) with N = grad|omega| / |grad|omega||, putting
    back the small swirls semi-Lagrangian advection smears out.
    `step(dt)` = buoyancy and confinement forces, then the fluid's step,
    then the temperature's advection. epsilon = 0 skips the confinement
    pass entirely."""

    var fluid: MacFluid2
    var temp: List[Real]
    var buoyancy: Real
    var epsilon: Real

    def __init__(out self, var fluid: MacFluid2, buoyancy: Real, epsilon: Real) raises:
        if not (epsilon >= 0):
            raise Error("Smoke2: epsilon must be >= 0")
        var n = fluid.n
        self.fluid = fluid^
        self.temp = List[Real](length=n * n, fill=0)
        self.buoyancy = buoyancy
        self.epsilon = epsilon

    def vorticity(self) -> List[Real]:
        """Vorticity dv/dx - du/dy at the cell corners (i dx, j dx)."""
        ref f = self.fluid
        var n = f.n
        var out = List[Real](length=n * n, fill=0)
        for j in range(n):
            var jm = (j + n - 1) % n
            for i in range(n):
                var im = (i + n - 1) % n
                out[j * n + i] = (f.v[j * n + i] - f.v[j * n + im] - f.u[j * n + i] + f.u[jm * n + i]) / f.dx
        return out^

    def kinetic_energy(self) -> Real:
        var e = Real(0)
        for k in range(len(self.fluid.u)):
            e += 0.5 * (self.fluid.u[k] * self.fluid.u[k] + self.fluid.v[k] * self.fluid.v[k])
        return e * self.fluid.dx * self.fluid.dx

    def _forces(mut self, dt: Real):
        var n = self.fluid.n
        var dx = self.fluid.dx
        var mean = Real(0)
        for k in range(n * n):
            mean += self.temp[k]
        mean /= Real(n * n)
        # buoyancy on the v faces: temperature averaged from the two cells
        for j in range(n):
            var jm = (j + n - 1) % n
            for i in range(n):
                var tf = 0.5 * (self.temp[j * n + i] + self.temp[jm * n + i])
                self.fluid.v[j * n + i] += dt * self.buoyancy * (tf - mean)
        if self.epsilon <= 0:
            return
        var w = self.vorticity()  # corners
        var mag = List[Real](length=n * n, fill=0)
        for k in range(n * n):
            mag[k] = abs(w[k])
        # force at the corners, then averaged onto the faces
        var cfx = List[Real](length=n * n, fill=0)
        var cfy = List[Real](length=n * n, fill=0)
        for j in range(n):
            var jm = (j + n - 1) % n
            var jp = (j + 1) % n
            for i in range(n):
                var im = (i + n - 1) % n
                var ip = (i + 1) % n
                var gx = (mag[j * n + ip] - mag[j * n + im]) / (2 * dx)
                var gy = (mag[jp * n + i] - mag[jm * n + i]) / (2 * dx)
                var gl = sqrt(gx * gx + gy * gy) + 1e-12
                var nx = gx / gl
                var ny = gy / gl
                # (N x omega z) in 2-D: (ny omega, -nx omega)
                cfx[j * n + i] = self.epsilon * dx * ny * w[j * n + i]
                cfy[j * n + i] = -self.epsilon * dx * nx * w[j * n + i]
        for j in range(n):
            var jp = (j + 1) % n
            for i in range(n):
                var ip = (i + 1) % n
                # u face (i, j + 1/2) between corners (i, j) and (i, j + 1)
                self.fluid.u[j * n + i] += dt * 0.5 * (cfx[j * n + i] + cfx[jp * n + i])
                # v face (i + 1/2, j) between corners (i, j) and (i + 1, j)
                self.fluid.v[j * n + i] += dt * 0.5 * (cfy[j * n + i] + cfy[j * n + ip])

    def _advect_temp(mut self, dt: Real):
        var n = self.fluid.n
        var dx = self.fluid.dx
        var nt = List[Real](length=n * n, fill=0)
        for j in range(n):
            for i in range(n):
                var x = (Real(i) + 0.5) * dx
                var y = (Real(j) + 0.5) * dx
                var v0 = self.fluid.velocity(x, y)
                var vm = self.fluid.velocity(x - 0.5 * dt * v0[0], y - 0.5 * dt * v0[1])
                nt[j * n + i] = self.fluid.sample(self.temp, x - dt * vm[0], y - dt * vm[1], 0, 0.5, 0.5, 0)
        self.temp = nt^

    def step(mut self, dt: Real) raises:
        self._forces(dt)
        self.fluid.step(dt)
        self._advect_temp(dt)
