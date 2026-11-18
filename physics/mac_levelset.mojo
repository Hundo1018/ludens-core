"""Free-surface water on a 2-D MAC grid with a level set (ROADMAP 17.60:
the MAC level-set free surface; Enright / Foster & Fedkiw, Gibou's ghost
fluid for the surface pressure).

An n x n box of cells with solid walls on all four sides. phi at the cell
centres is a signed distance, negative in the liquid. u on the x faces
((n + 1) x n, zero on the left / right walls), v on the y faces
(n x (n + 1), zero on the floor / ceiling). One `step(dt)`:

  1. advect phi, u and v semi-Lagrangian (RK2, bilinear, clamped to the
     box);
  2. gravity on the faces next to liquid;
  3. pressure on the liquid cells only: -lap p = -div u / dt with the
     walls as Neumann (no flux) and the surface as Dirichlet p = 0 placed
     where phi crosses zero between a liquid cell and an air neighbour
     (ghost fluid: the neighbour's coefficient becomes 1 / theta,
     theta = phi_l / (phi_l - phi_a) >= 0.01, into the diagonal); solved
     by `numerics.pcg` matrix-free;
  4. faces between liquid and liquid or liquid and air get u -= dt grad p
     (air pressure 0 at the theta point);
  5. velocities are extrapolated into the air (`extrap` rings, each air
     face takes the mean of its known neighbours) so the next advection
     reads sensible values near the surface;
  6. every `reinit_every` steps phi is redistanced by fast sweeping
     (Zhao 2005), keeping the zero crossing cells' values.

`LevelSetWater[D]` is this solver for D = 2 and 3: `LevelSetWater2 = LevelSetWater[2]` here and
`LevelSetWater3 = LevelSetWater[3]` in physics/mac_levelset3.mojo, which describes the 3-D grid.

A level set loses volume where the surface is under-resolved; `volume()`
(cells with phi < 0, times dx^2) is measured in `test_levelset_water`.

Open walls (`set_open`, ROADMAP 17.60) replace a solid wall on chosen sides
by an outlet: the boundary face takes the zero-gradient value of its interior
neighbour before the projection, the liquid cells next to it get a Dirichlet
p = 0 at dx / 2 (ghost fluid with theta = 1/2), and the face is updated by the
same pressure gradient as an interior face. Nothing forces inflow through an
open wall; the sign of the flux is whatever the pressure gives. Phi is
advected with the same clamped back-trace as before, so liquid that reaches
an open wall leaves through the level set's own motion; the level set does
not conserve volume, and `test_levelset_open` measures how far its volume
loss departs from the boundary flux.
"""

from std.math import floor, sqrt
from geometry.vec import Real
from numerics.sparse import LinearOperator
from numerics.cg import pcg, CgResult


struct _LiquidPoisson[D: Int](LinearOperator, Movable):
    """-lap p over the liquid cells (index map `cell` -> unknown) with
    Neumann walls and ghost-fluid Dirichlet air neighbours; dx^2 = 1. D is 2
    (LevelSetWater2) or 3 (LevelSetWater3): cells are [(k n + j) n + i] with k
    = 0 in 2D, and the sides are visited in the order +x, -x, +y, -y (+z, -z),
    so the diagonal sums the same terms in the same order in both."""

    comptime SIDES = 2 * Self.D
    var n: Int
    var unk: List[Int]  # per cell: unknown index or -1
    var cells: List[Int]  # per unknown: cell
    var diag: List[Real]
    var nb: List[Int]  # per unknown: SIDES neighbour unknowns (-1: none / not liquid)

    def __init__(out self, n: Int, phi: List[Real], open: List[Bool]):
        self.n = n
        var nn = n
        comptime for _ in range(Self.D - 1):
            nn *= n
        self.unk = List[Int](length=nn, fill=-1)
        self.cells = List[Int]()
        for c in range(nn):
            if phi[c] < 0:
                self.unk[c] = len(self.cells)
                self.cells.append(c)
        var m = len(self.cells)
        self.diag = List[Real](length=m, fill=0)
        self.nb = List[Int](length=Self.SIDES * m, fill=-1)
        for k in range(m):
            var c = self.cells[k]
            var i = c % n
            var j = (c // n) % n
            var kz = c // (n * n)
            var d = Real(0)
            for s in range(Self.SIDES):
                var ii = i + (1 if s == 0 else (-1 if s == 1 else 0))
                var jj = j + (1 if s == 2 else (-1 if s == 3 else 0))
                var kk = kz + (1 if s == 4 else (-1 if s == 5 else 0))
                if ii < 0 or ii >= n or jj < 0 or jj >= n or kk < 0 or kk >= n:
                    # solid wall: no flux. Open wall: Dirichlet p = 0 at
                    # dx / 2, so 1 / theta = 2. Side index: 0 left, 1 right,
                    # 2 bottom, 3 top, 4 back, 5 front; s ^ 1 maps the step.
                    if open[s ^ 1]:
                        d += 2
                    continue
                var o = (kk * n + jj) * n + ii
                if phi[o] < 0:
                    d += 1
                    self.nb[Self.SIDES * k + s] = self.unk[o]
                else:
                    var th = max(phi[c] / (phi[c] - phi[o]), Real(0.01))
                    d += 1 / th
            self.diag[k] = d

    def size(self) -> Int:
        return len(self.cells)

    def apply(self, x: List[Real], mut out: List[Real]):
        for k in range(len(self.cells)):
            var a = self.diag[k] * x[k]
            for s in range(Self.SIDES):
                var o = self.nb[Self.SIDES * k + s]
                if o >= 0:
                    a -= x[o]
            out[k] = a

    def diagonal(self, mut out: List[Real]):
        for k in range(len(self.cells)):
            out[k] = self.diag[k]


def _ring[D: Int](known: List[Bool], mut f: List[Real], n: Int, nx: Int, ny: Int, nz: Int) -> List[Bool]:
    """One extrapolation ring on one face array of an n^D grid (nz = 1 in 2-D): each unknown interior face (index
    1..n-1 along its own axis, the axis whose length is n + 1) takes the mean of its known neighbours. Faces on the
    walls (index 0 or n on that axis) stay as they are. The neighbours are summed in each solver's original order
    (2-D: -x, +x, -y, +y; 3-D: +x, -x, +y, -y, +z, -z), which the last bits of the mean depend on."""
    var nxt = known.copy()
    var axis = 0 if nx == n + 1 else (1 if ny == n + 1 else 2)
    comptime FIRST = -1 if D == 2 else 1
    for k in range(nz):
        for j in range(ny):
            for i in range(nx):
                var c = (k * ny + j) * nx + i
                if known[c]:
                    continue
                var pos = i if axis == 0 else (j if axis == 1 else k)
                if pos < 1 or pos >= n:
                    continue
                var s = Real(0)
                var cnt = 0
                for d in range(2 * D):
                    var ii = i + (FIRST if d == 0 else (-FIRST if d == 1 else 0))
                    var jj = j + (FIRST if d == 2 else (-FIRST if d == 3 else 0))
                    var kk = k + (1 if d == 4 else (-1 if d == 5 else 0))
                    if ii < 0 or ii >= nx or jj < 0 or jj >= ny or kk < 0 or kk >= nz:
                        continue
                    var o = (kk * ny + jj) * nx + ii
                    if known[o]:
                        s += f[o]
                        cnt += 1
                if cnt > 0:
                    f[c] = s / Real(cnt)
                    nxt[c] = True
    return nxt^


def _face_update(mut f: List[Real], face: Int, phi: List[Real], p: List[Real], ca: Int, cb: Int, dx: Real, dt: Real):
    """The pressure update of the face between cells ca and cb (cb the higher index on the face's axis):
    f[face] -= dt (pb - pa) / dist. Liquid-liquid uses dist = dx; liquid-air puts the ghost p = 0 on the surface, at
    theta dx from the liquid cell's centre (theta >= 0.01); air-air faces are left alone."""
    var a = phi[ca] < 0
    var b = phi[cb] < 0
    if not a and not b:
        return
    var pa = p[ca]
    var pb = p[cb]
    var dist = dx
    if a and not b:
        var th = max(phi[ca] / (phi[ca] - phi[cb]), Real(0.01))
        pb = 0
        dist = th * dx
    elif b and not a:
        var th = max(phi[cb] / (phi[cb] - phi[ca]), Real(0.01))
        pa = 0
        dist = th * dx
    f[face] -= dt * (pb - pa) / dist


def _godunov(a: Real, b: Real, c: Real, dx: Real) -> Real:
    """Fast-sweeping update in three axes: the d >= 0 with
    sum_axes max(d - a_axis, 0)^2 = dx^2 (a, b, c = big where a neighbour is missing)."""
    # sorted by min / max, not by a + b + c - x0 - x2: with the big sentinel
    # that difference cancels to zero in single precision
    var x0 = min(a, min(b, c))
    var x2 = max(a, max(b, c))
    var x1 = max(min(a, b), min(max(a, b), c))
    var d = x0 + dx
    if d <= x1:
        return d
    d = (x0 + x1 + sqrt(2 * dx * dx - (x0 - x1) * (x0 - x1))) / 2
    if d <= x2:
        return d
    var s1 = x0 + x1 + x2
    var s2 = x0 * x0 + x1 * x1 + x2 * x2
    return (s1 + sqrt(s1 * s1 - 3 * (s2 - dx * dx))) / 3


struct LevelSetWater[D: Int](Movable):
    """The level-set water on an n^D MAC grid, D = 2 or 3 (`LevelSetWater2`, `LevelSetWater3` in
    physics/mac_levelset3.mojo). Every array is indexed (k ny + j) nx + i with nz = 1 in 2-D, so the 2-D
    indices are the 3-D ones at k = 0. Where the two solvers' arithmetic differs it stays per dimension:
    bilinear against trilinear sampling (the 2-D value is the 3-D one's first plane), and the redistancing
    update (2-D tests |a - b| >= dx, 3-D `_godunov`), whose comparisons are not the same in floating point."""

    var n: Int
    var dx: Real
    var gravity: Real  # downward (-y) acceleration (m/s^2)
    var phi: List[Real]  # [(k n + j) n + i]
    var u: List[Real]  # [(k n + j) (n + 1) + i], i = 0..n
    var v: List[Real]  # [(k (n + 1) + j) n + i], j = 0..n
    var w: List[Real]  # [(k n + j) n + i], k = 0..n; empty in 2-D
    var p: List[Real]  # per cell (0 in air)
    var last: CgResult
    var extrap: Int
    var reinit_every: Int
    var sweeps: Int  # fast-sweeping passes per redistancing (2^D = every sweep order once)
    var steps: Int
    var open: List[Bool]  # per side: left (x = 0), right, bottom (y = 0), top, back (z = 0), front; True: outlet

    def __init__(out self, n: Int, dx: Real, gravity: Real = 9.81) raises:
        comptime assert Self.D == 2 or Self.D == 3, "LevelSetWater: D is 2 or 3"
        if n < 4 or not (dx > 0):
            raise Error("LevelSetWater" + String(Self.D) + ": n >= 4 and dx > 0")
        self.n = n
        self.dx = dx
        self.gravity = gravity
        var nz = n if Self.D == 3 else 1
        self.phi = List[Real](length=n * n * nz, fill=dx * Real(n))
        self.u = List[Real](length=(n + 1) * n * nz, fill=0)
        self.v = List[Real](length=n * (n + 1) * nz, fill=0)
        self.w = List[Real](length=n * n * (n + 1) if Self.D == 3 else 0, fill=0)
        self.p = List[Real](length=n * n * nz, fill=0)
        self.last = CgResult(True, False, 0, 0)
        self.extrap = 4
        self.reinit_every = 5
        self.sweeps = 1 << Self.D
        self.steps = 0
        self.open = List[Bool](length=2 * Self.D, fill=False)

    def _nz(self) -> Int:
        """Cells along z: n in 3-D, 1 in 2-D."""
        comptime if Self.D == 3:
            return self.n
        else:
            return 1

    def set_open(mut self, left: Bool, right: Bool, bottom: Bool, top: Bool):
        """Turns the walls on the given sides into outlets (see the module
        note). All False, the default, is the closed box."""
        comptime assert Self.D == 2, "set_open(left, right, bottom, top) is the 2-D form"
        self.open[0] = left
        self.open[1] = right
        self.open[2] = bottom
        self.open[3] = top

    def set_open(mut self, left: Bool, right: Bool, bottom: Bool, top: Bool, back: Bool, front: Bool):
        """Turns the walls on the given sides into outlets (the 2-D rule on
        six sides). All False is the closed box."""
        comptime assert Self.D == 3, "set_open with six sides is the 3-D form"
        self.open[0] = left
        self.open[1] = right
        self.open[2] = bottom
        self.open[3] = top
        self.open[4] = back
        self.open[5] = front

    def set_box(mut self, x0: Real, y0: Real, x1: Real, y1: Real):
        """Liquid where (x, y) is inside [x0, x1] x [y0, y1] (metres);
        phi = signed distance to that rectangle."""
        comptime assert Self.D == 2, "set_box(x0, y0, x1, y1) is the 2-D form"
        self._set_box(x0, y0, 0, x1, y1, 0)

    def set_box(mut self, x0: Real, y0: Real, z0: Real, x1: Real, y1: Real, z1: Real):
        """Liquid where (x, y, z) is inside the box (metres); phi = signed
        distance to that box."""
        comptime assert Self.D == 3, "set_box with six bounds is the 3-D form"
        self._set_box(x0, y0, z0, x1, y1, z1)

    def _set_box(mut self, x0: Real, y0: Real, z0: Real, x1: Real, y1: Real, z1: Real):
        var n = self.n
        for k in range(self._nz()):
            for j in range(n):
                for i in range(n):
                    var x = (Real(i) + 0.5) * self.dx
                    var y = (Real(j) + 0.5) * self.dx
                    var dxo = max(x0 - x, x - x1)
                    var dyo = max(y0 - y, y - y1)
                    var outside: Real
                    var inside: Real
                    comptime if Self.D == 2:
                        outside = sqrt(max(dxo, 0) * max(dxo, 0) + max(dyo, 0) * max(dyo, 0))
                        inside = min(max(dxo, dyo), 0)
                    else:
                        var z = (Real(k) + 0.5) * self.dx
                        var dzo = max(z0 - z, z - z1)
                        outside = sqrt(
                            max(dxo, 0) * max(dxo, 0) + max(dyo, 0) * max(dyo, 0) + max(dzo, 0) * max(dzo, 0)
                        )
                        inside = min(max(dxo, max(dyo, dzo)), 0)
                    self.phi[(k * n + j) * n + i] = outside + inside

    def volume(self) -> Real:
        """Cells with phi < 0 times dx^D."""
        var c = 0
        for f in self.phi:
            if f < 0:
                c += 1
        var vol = Real(c) * self.dx * self.dx
        comptime if Self.D == 3:
            vol = vol * self.dx
        return vol

    def front_x(self) -> Real:
        """Rightmost liquid cell centre on the bottom row (j = 0), in 3-D of
        the middle z plane (m), 0 if there is none."""
        var n = self.n
        var k = n // 2 if Self.D == 3 else 0
        var best = Real(0)
        for i in range(n):
            if self.phi[(k * n + 0) * n + i] < 0:
                best = (Real(i) + 0.5) * self.dx
        return best

    # ---------------------------------------------------------------- sampling
    def _sample(
        self, f: List[Real], nx: Int, ny: Int, nz: Int, x: Real, y: Real, z: Real, ox: Real, oy: Real, oz: Real
    ) -> Real:
        """Bilinear (2-D) or trilinear (3-D) sample of a field with nx x ny (x nz) samples at
        ((i + ox) dx, (j + oy) dx, (k + oz) dx), clamped to its extent. The 2-D value is the 3-D
        one's first plane, computed the same way."""
        var gx = min(max(x / self.dx - ox, 0), Real(nx - 1))
        var gy = min(max(y / self.dx - oy, 0), Real(ny - 1))
        var i0 = min(Int(floor(gx)), nx - 2)
        var j0 = min(Int(floor(gy)), ny - 2)
        var ax = gx - Real(i0)
        var ay = gy - Real(j0)
        comptime if Self.D == 3:
            var gz = min(max(z / self.dx - oz, 0), Real(nz - 1))
            var k0 = min(Int(floor(gz)), nz - 2)
            var az = gz - Real(k0)
            var c00 = f[(k0 * ny + j0) * nx + i0] * (1 - ax) + f[(k0 * ny + j0) * nx + i0 + 1] * ax
            var c10 = f[(k0 * ny + j0 + 1) * nx + i0] * (1 - ax) + f[(k0 * ny + j0 + 1) * nx + i0 + 1] * ax
            var c01 = f[((k0 + 1) * ny + j0) * nx + i0] * (1 - ax) + f[((k0 + 1) * ny + j0) * nx + i0 + 1] * ax
            var c11 = f[((k0 + 1) * ny + j0 + 1) * nx + i0] * (1 - ax) + f[((k0 + 1) * ny + j0 + 1) * nx + i0 + 1] * ax
            var lo = c00 * (1 - ay) + c10 * ay
            var hi = c01 * (1 - ay) + c11 * ay
            return lo * (1 - az) + hi * az
        else:
            var lo = f[j0 * nx + i0] * (1 - ax) + f[j0 * nx + i0 + 1] * ax
            var hi = f[(j0 + 1) * nx + i0] * (1 - ax) + f[(j0 + 1) * nx + i0 + 1] * ax
            return lo * (1 - ay) + hi * ay

    def velocity(self, x: Real, y: Real) -> Tuple[Real, Real]:
        comptime assert Self.D == 2, "velocity(x, y) is the 2-D form"
        var n = self.n
        return (
            self._sample(self.u, n + 1, n, 1, x, y, 0, 0, 0.5, 0),
            self._sample(self.v, n, n + 1, 1, x, y, 0, 0.5, 0, 0),
        )

    def velocity(self, x: Real, y: Real, z: Real) -> Tuple[Real, Real, Real]:
        comptime assert Self.D == 3, "velocity(x, y, z) is the 3-D form"
        var n = self.n
        return (
            self._sample(self.u, n + 1, n, n, x, y, z, 0, 0.5, 0.5),
            self._sample(self.v, n, n + 1, n, x, y, z, 0.5, 0, 0.5),
            self._sample(self.w, n, n, n + 1, x, y, z, 0.5, 0.5, 0),
        )

    def _vel(self, x: Real, y: Real, z: Real) -> Tuple[Real, Real, Real]:
        """velocity in either dimension, z = 0 in 2-D."""
        comptime if Self.D == 2:
            var v = self.velocity(x, y)
            return (v[0], v[1], Real(0))
        else:
            return self.velocity(x, y, z)

    def _back(self, x: Real, y: Real, z: Real, dt: Real) -> Tuple[Real, Real, Real]:
        """RK2 back-trace from (x, y, z), clamped to the box (z unused in 2-D)."""
        var v0 = self._vel(x, y, z)
        var vm = self._vel(x - 0.5 * dt * v0[0], y - 0.5 * dt * v0[1], z - 0.5 * dt * v0[2])
        var top = Real(self.n) * self.dx
        return (
            min(max(x - dt * vm[0], 0), top),
            min(max(y - dt * vm[1], 0), top),
            min(max(z - dt * vm[2], 0), top),
        )

    # ---------------------------------------------------------------- steps
    def _advect(mut self, dt: Real):
        var n = self.n
        var dx = self.dx
        var nz = self._nz()
        var nphi = List[Real](length=n * n * nz, fill=0)
        var nu_ = List[Real](length=(n + 1) * n * nz, fill=0)
        var nv_ = List[Real](length=n * (n + 1) * nz, fill=0)
        var nw_ = List[Real](length=len(self.w), fill=0)
        for k in range(nz):
            var zc = (Real(k) + 0.5) * dx
            for j in range(n):
                for i in range(n):
                    var b = self._back((Real(i) + 0.5) * dx, (Real(j) + 0.5) * dx, zc, dt)
                    nphi[(k * n + j) * n + i] = self._sample(self.phi, n, n, nz, b[0], b[1], b[2], 0.5, 0.5, 0.5)
        for k in range(nz):
            var zc = (Real(k) + 0.5) * dx
            for j in range(n):
                for i in range(1, n):
                    var b = self._back(Real(i) * dx, (Real(j) + 0.5) * dx, zc, dt)
                    nu_[(k * n + j) * (n + 1) + i] = self._sample(self.u, n + 1, n, nz, b[0], b[1], b[2], 0, 0.5, 0.5)
        for k in range(nz):
            var zc = (Real(k) + 0.5) * dx
            for j in range(1, n):
                for i in range(n):
                    var b = self._back((Real(i) + 0.5) * dx, Real(j) * dx, zc, dt)
                    nv_[(k * (n + 1) + j) * n + i] = self._sample(self.v, n, n + 1, nz, b[0], b[1], b[2], 0.5, 0, 0.5)
        comptime if Self.D == 3:
            for k in range(1, n):
                for j in range(n):
                    for i in range(n):
                        var b = self._back((Real(i) + 0.5) * dx, (Real(j) + 0.5) * dx, Real(k) * dx, dt)
                        nw_[(k * n + j) * n + i] = self._sample(self.w, n, n, n + 1, b[0], b[1], b[2], 0.5, 0.5, 0)
        # outlet faces start from their interior neighbour (zero gradient)
        for k in range(nz):
            for j in range(n):
                if self.open[0]:
                    nu_[(k * n + j) * (n + 1)] = nu_[(k * n + j) * (n + 1) + 1]
                if self.open[1]:
                    nu_[(k * n + j) * (n + 1) + n] = nu_[(k * n + j) * (n + 1) + n - 1]
        for k in range(nz):
            for i in range(n):
                if self.open[2]:
                    nv_[(k * (n + 1)) * n + i] = nv_[(k * (n + 1) + 1) * n + i]
                if self.open[3]:
                    nv_[(k * (n + 1) + n) * n + i] = nv_[(k * (n + 1) + n - 1) * n + i]
        comptime if Self.D == 3:
            for j in range(n):
                for i in range(n):
                    if self.open[4]:
                        nw_[j * n + i] = nw_[n * n + j * n + i]
                    if self.open[5]:
                        nw_[n * n * n + j * n + i] = nw_[(n - 1) * n * n + j * n + i]
        self.phi = nphi^
        self.u = nu_^
        self.v = nv_^
        self.w = nw_^

    def _liquid(self, i: Int, j: Int, k: Int) -> Bool:
        var n = self.n
        return (
            i >= 0 and i < n and j >= 0 and j < n and k >= 0 and k < self._nz()
            and self.phi[(k * n + j) * n + i] < 0
        )

    def _gravity(mut self, dt: Real):
        var n = self.n
        var nz = self._nz()
        for k in range(nz):
            for j in range(1, n):
                for i in range(n):
                    if self._liquid(i, j, k) or self._liquid(i, j - 1, k):
                        self.v[(k * (n + 1) + j) * n + i] -= self.gravity * dt
        # outlet faces on the floor and ceiling are not interior faces above; give them the same rule
        for k in range(nz):
            for i in range(n):
                if self.open[2] and self._liquid(i, 0, k):
                    self.v[(k * (n + 1)) * n + i] -= self.gravity * dt
                if self.open[3] and self._liquid(i, n - 1, k):
                    self.v[(k * (n + 1) + n) * n + i] -= self.gravity * dt

    def _project(mut self, dt: Real) -> CgResult:
        var n = self.n
        var dx = self.dx
        var nz = self._nz()
        var op = _LiquidPoisson[Self.D](n, self.phi, self.open)
        var m = op.size()
        var rhs = List[Real](length=m, fill=0)
        for q in range(m):
            var c = op.cells[q]
            var i = c % n
            var j = (c // n) % n
            var k = c // (n * n)
            # left to right in the original order: du - ... + dv - ... (+ dw - ... in 3-D)
            var s = (
                self.u[(k * n + j) * (n + 1) + i + 1] - self.u[(k * n + j) * (n + 1) + i]
                + self.v[(k * (n + 1) + j + 1) * n + i] - self.v[(k * (n + 1) + j) * n + i]
            )
            comptime if Self.D == 3:
                s = s + self.w[((k + 1) * n + j) * n + i] - self.w[(k * n + j) * n + i]
            var div = s / dx
            rhs[q] = -div * dx * dx / dt
        var x = List[Real](length=m, fill=0)
        var r = pcg(op, rhs, x, 1e-6, 4 * m + 16)
        for c in range(n * n * nz):
            self.p[c] = 0
        for q in range(m):
            self.p[op.cells[q]] = x[q]
        # face updates: liquid-liquid and liquid-air (ghost p = 0 at theta)
        for k in range(nz):
            for j in range(n):
                for i in range(1, n):
                    var cb = (k * n + j) * n + i
                    _face_update(self.u, (k * n + j) * (n + 1) + i, self.phi, self.p, cb - 1, cb, dx, dt)
        for k in range(nz):
            for j in range(1, n):
                for i in range(n):
                    var cb = (k * n + j) * n + i
                    _face_update(self.v, (k * (n + 1) + j) * n + i, self.phi, self.p, cb - n, cb, dx, dt)
        comptime if Self.D == 3:
            for k in range(1, n):
                for j in range(n):
                    for i in range(n):
                        var cb = (k * n + j) * n + i
                        _face_update(self.w, cb, self.phi, self.p, cb - n * n, cb, dx, dt)
        # outlet faces: Dirichlet p = 0 at dx / 2 from the liquid cell
        var half = 0.5 * dx
        for k in range(nz):
            for j in range(n):
                if self.open[0] and self._liquid(0, j, k):
                    self.u[(k * n + j) * (n + 1)] -= dt * self.p[(k * n + j) * n] / half
                if self.open[1] and self._liquid(n - 1, j, k):
                    self.u[(k * n + j) * (n + 1) + n] += dt * self.p[(k * n + j) * n + n - 1] / half
        for k in range(nz):
            for i in range(n):
                if self.open[2] and self._liquid(i, 0, k):
                    self.v[(k * (n + 1)) * n + i] -= dt * self.p[k * n * n + i] / half
                if self.open[3] and self._liquid(i, n - 1, k):
                    self.v[(k * (n + 1) + n) * n + i] += dt * self.p[(k * n + n - 1) * n + i] / half
        comptime if Self.D == 3:
            for j in range(n):
                for i in range(n):
                    if self.open[4] and self._liquid(i, j, 0):
                        self.w[j * n + i] -= dt * self.p[j * n + i] / half
                    if self.open[5] and self._liquid(i, j, n - 1):
                        self.w[n * n * n + j * n + i] += dt * self.p[((n - 1) * n + j) * n + i] / half
        return r

    def _extrapolate(mut self):
        var n = self.n
        var nz = self._nz()
        # known faces: next to a liquid cell (walls stay 0 and are known)
        var ku = List[Bool](length=(n + 1) * n * nz, fill=False)
        var kv = List[Bool](length=n * (n + 1) * nz, fill=False)
        var kw = List[Bool](length=len(self.w), fill=False)
        for k in range(nz):
            for j in range(n):
                for i in range(n + 1):
                    var wall = (i == 0 and not self.open[0]) or (i == n and not self.open[1])
                    ku[(k * n + j) * (n + 1) + i] = wall or self._liquid(i - 1, j, k) or self._liquid(i, j, k)
        for k in range(nz):
            for j in range(n + 1):
                for i in range(n):
                    var wall = (j == 0 and not self.open[2]) or (j == n and not self.open[3])
                    kv[(k * (n + 1) + j) * n + i] = wall or self._liquid(i, j - 1, k) or self._liquid(i, j, k)
        comptime if Self.D == 3:
            for k in range(n + 1):
                for j in range(n):
                    for i in range(n):
                        var wall = (k == 0 and not self.open[4]) or (k == n and not self.open[5])
                        kw[(k * n + j) * n + i] = wall or self._liquid(i, j, k - 1) or self._liquid(i, j, k)
        for _ in range(self.extrap):
            ku = _ring[Self.D](ku, self.u, n, n + 1, n, nz)
            kv = _ring[Self.D](kv, self.v, n, n, n + 1, nz)
            comptime if Self.D == 3:
                kw = _ring[3](kw, self.w, n, n, n, n + 1)

    def _redistance(mut self):
        """Fast sweeping for |grad phi| = 1 over the `sweeps` sweep orders; the
        cells next to a sign change are kept fixed."""
        var n = self.n
        var dx = self.dx
        var nz = self._nz()
        var big = Real(1e10)
        var nn = n * n * nz
        var fixed = List[Bool](length=nn, fill=False)
        var d = List[Real](length=nn, fill=big)
        for k in range(nz):
            for j in range(n):
                for i in range(n):
                    var c = (k * n + j) * n + i
                    var s = self.phi[c] < 0
                    for e in range(2 * Self.D):
                        var ii = i + (1 if e == 0 else (-1 if e == 1 else 0))
                        var jj = j + (1 if e == 2 else (-1 if e == 3 else 0))
                        var kk = k + (1 if e == 4 else (-1 if e == 5 else 0))
                        if ii >= 0 and ii < n and jj >= 0 and jj < n and kk >= 0 and kk < nz:
                            if (self.phi[(kk * n + jj) * n + ii] < 0) != s:
                                fixed[c] = True
                    if fixed[c]:
                        d[c] = abs(self.phi[c])
        for sweep in range(self.sweeps):
            var i_up = (sweep & 1) == 0
            var j_up = (sweep & 2) == 0
            var k_up = (sweep & 4) == 0
            for kk in range(nz):
                var k = kk if k_up else nz - 1 - kk
                for jj in range(n):
                    var j = jj if j_up else n - 1 - jj
                    for ii in range(n):
                        var i = ii if i_up else n - 1 - ii
                        var c = (k * n + j) * n + i
                        if fixed[c]:
                            continue
                        var a = min(d[c - 1] if i > 0 else big, d[c + 1] if i < n - 1 else big)
                        var b = min(d[c - n] if j > 0 else big, d[c + n] if j < n - 1 else big)
                        var nd: Real
                        comptime if Self.D == 2:
                            if abs(a - b) >= dx:
                                nd = min(a, b) + dx
                            else:
                                nd = (a + b + sqrt(2 * dx * dx - (a - b) * (a - b))) / 2
                        else:
                            var e = min(d[c - n * n] if k > 0 else big, d[c + n * n] if k < n - 1 else big)
                            nd = _godunov(a, b, e, dx)
                        if nd < d[c]:
                            d[c] = nd
        for c in range(nn):
            if not fixed[c]:
                self.phi[c] = -d[c] if self.phi[c] < 0 else d[c]

    def step(mut self, dt: Real) raises:
        if not (dt > 0):
            raise Error("LevelSetWater" + String(Self.D) + ".step: dt must be > 0")
        self._advect(dt)
        self._gravity(dt)
        self.last = self._project(dt)
        self._extrapolate()
        self.steps += 1
        if self.reinit_every > 0 and self.steps % self.reinit_every == 0:
            self._redistance()

    def max_speed(self) -> Real:
        """Largest |face velocity| over the faces next to liquid."""
        var n = self.n
        var nz = self._nz()
        var m = Real(0)
        for k in range(nz):
            for j in range(n):
                for i in range(1, n):
                    if self._liquid(i - 1, j, k) or self._liquid(i, j, k):
                        m = max(m, abs(self.u[(k * n + j) * (n + 1) + i]))
        for k in range(nz):
            for j in range(1, n):
                for i in range(n):
                    if self._liquid(i, j - 1, k) or self._liquid(i, j, k):
                        m = max(m, abs(self.v[(k * (n + 1) + j) * n + i]))
        comptime if Self.D == 3:
            for k in range(1, n):
                for j in range(n):
                    for i in range(n):
                        if self._liquid(i, j, k - 1) or self._liquid(i, j, k):
                            m = max(m, abs(self.w[(k * n + j) * n + i]))
        return m


comptime LevelSetWater2 = LevelSetWater[2]
"""The 2-D level-set water (n x n cells)."""
