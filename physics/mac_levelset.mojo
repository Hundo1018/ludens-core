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


struct LevelSetWater2(Movable):
    var n: Int
    var dx: Real
    var gravity: Real  # downward acceleration (m/s^2)
    var phi: List[Real]  # [j n + i]
    var u: List[Real]  # [j (n + 1) + i], i = 0..n
    var v: List[Real]  # [j n + i], j = 0..n
    var p: List[Real]  # per cell (0 in air)
    var last: CgResult
    var extrap: Int
    var reinit_every: Int
    var steps: Int
    var open: List[Bool]  # per side: left (x = 0), right, bottom, top; True: outlet

    def __init__(out self, n: Int, dx: Real, gravity: Real = 9.81) raises:
        if n < 4 or not (dx > 0):
            raise Error("LevelSetWater2: n >= 4 and dx > 0")
        self.n = n
        self.dx = dx
        self.gravity = gravity
        self.phi = List[Real](length=n * n, fill=dx * Real(n))
        self.u = List[Real](length=(n + 1) * n, fill=0)
        self.v = List[Real](length=n * (n + 1), fill=0)
        self.p = List[Real](length=n * n, fill=0)
        self.last = CgResult(True, False, 0, 0)
        self.extrap = 4
        self.reinit_every = 5
        self.steps = 0
        self.open = List[Bool](length=4, fill=False)

    def set_open(mut self, left: Bool, right: Bool, bottom: Bool, top: Bool):
        """Turns the walls on the given sides into outlets (see the module
        note). All False, the default, is the closed box."""
        self.open[0] = left
        self.open[1] = right
        self.open[2] = bottom
        self.open[3] = top

    def set_box(mut self, x0: Real, y0: Real, x1: Real, y1: Real):
        """Liquid where (x, y) is inside [x0, x1] x [y0, y1] (metres);
        phi = signed distance to that rectangle."""
        var n = self.n
        for j in range(n):
            for i in range(n):
                var x = (Real(i) + 0.5) * self.dx
                var y = (Real(j) + 0.5) * self.dx
                var dxo = max(x0 - x, x - x1)
                var dyo = max(y0 - y, y - y1)
                var outside = sqrt(max(dxo, 0) * max(dxo, 0) + max(dyo, 0) * max(dyo, 0))
                var inside = min(max(dxo, dyo), 0)
                self.phi[j * n + i] = outside + inside

    def volume(self) -> Real:
        var c = 0
        for f in self.phi:
            if f < 0:
                c += 1
        return Real(c) * self.dx * self.dx

    def front_x(self) -> Real:
        """Rightmost liquid cell centre on the bottom row (m)."""
        var n = self.n
        var best = Real(0)
        for i in range(n):
            if self.phi[i] < 0:
                best = (Real(i) + 0.5) * self.dx
        return best

    # ---------------------------------------------------------------- sampling
    def _sample(self, f: List[Real], nx: Int, ny: Int, x: Real, y: Real, ox: Real, oy: Real) -> Real:
        """Bilinear sample of a field with nx x ny samples at
        ((i + ox) dx, (j + oy) dx), clamped to its extent."""
        var gx = min(max(x / self.dx - ox, 0), Real(nx - 1))
        var gy = min(max(y / self.dx - oy, 0), Real(ny - 1))
        var i0 = min(Int(floor(gx)), nx - 2)
        var j0 = min(Int(floor(gy)), ny - 2)
        var ax = gx - Real(i0)
        var ay = gy - Real(j0)
        var lo = f[j0 * nx + i0] * (1 - ax) + f[j0 * nx + i0 + 1] * ax
        var hi = f[(j0 + 1) * nx + i0] * (1 - ax) + f[(j0 + 1) * nx + i0 + 1] * ax
        return lo * (1 - ay) + hi * ay

    def velocity(self, x: Real, y: Real) -> Tuple[Real, Real]:
        var n = self.n
        return (
            self._sample(self.u, n + 1, n, x, y, 0, 0.5),
            self._sample(self.v, n, n + 1, x, y, 0.5, 0),
        )

    def _back(self, x: Real, y: Real, dt: Real) -> Tuple[Real, Real]:
        var v0 = self.velocity(x, y)
        var vm = self.velocity(x - 0.5 * dt * v0[0], y - 0.5 * dt * v0[1])
        var top = Real(self.n) * self.dx
        return (min(max(x - dt * vm[0], 0), top), min(max(y - dt * vm[1], 0), top))

    # ---------------------------------------------------------------- steps
    def _advect(mut self, dt: Real):
        var n = self.n
        var dx = self.dx
        var nphi = List[Real](length=n * n, fill=0)
        var nu_ = List[Real](length=(n + 1) * n, fill=0)
        var nv_ = List[Real](length=n * (n + 1), fill=0)
        for j in range(n):
            for i in range(n):
                var b = self._back((Real(i) + 0.5) * dx, (Real(j) + 0.5) * dx, dt)
                nphi[j * n + i] = self._sample(self.phi, n, n, b[0], b[1], 0.5, 0.5)
        for j in range(n):
            for i in range(1, n):
                var b = self._back(Real(i) * dx, (Real(j) + 0.5) * dx, dt)
                nu_[j * (n + 1) + i] = self._sample(self.u, n + 1, n, b[0], b[1], 0, 0.5)
        for j in range(1, n):
            for i in range(n):
                var b = self._back((Real(i) + 0.5) * dx, Real(j) * dx, dt)
                nv_[j * n + i] = self._sample(self.v, n, n + 1, b[0], b[1], 0.5, 0)
        # outlet faces start from their interior neighbour (zero gradient)
        if self.open[0] or self.open[1]:
            for j in range(n):
                if self.open[0]:
                    nu_[j * (n + 1)] = nu_[j * (n + 1) + 1]
                if self.open[1]:
                    nu_[j * (n + 1) + n] = nu_[j * (n + 1) + n - 1]
        if self.open[2] or self.open[3]:
            for i in range(n):
                if self.open[2]:
                    nv_[i] = nv_[n + i]
                if self.open[3]:
                    nv_[n * n + i] = nv_[(n - 1) * n + i]
        self.phi = nphi^
        self.u = nu_^
        self.v = nv_^

    def _liquid(self, i: Int, j: Int) -> Bool:
        var n = self.n
        return i >= 0 and i < n and j >= 0 and j < n and self.phi[j * n + i] < 0

    def _gravity(mut self, dt: Real):
        var n = self.n
        for j in range(1, n):
            for i in range(n):
                if self._liquid(i, j) or self._liquid(i, j - 1):
                    self.v[j * n + i] -= self.gravity * dt
        # outlet faces are not interior faces above; give them the same rule
        for i in range(n):
            if self.open[2] and self._liquid(i, 0):
                self.v[i] -= self.gravity * dt
            if self.open[3] and self._liquid(i, n - 1):
                self.v[n * n + i] -= self.gravity * dt

    def _project(mut self, dt: Real) -> CgResult:
        var n = self.n
        var dx = self.dx
        var op = _LiquidPoisson[2](n, self.phi, self.open)
        var m = op.size()
        var rhs = List[Real](length=m, fill=0)
        for k in range(m):
            var c = op.cells[k]
            var i = c % n
            var j = c // n
            var div = (self.u[j * (n + 1) + i + 1] - self.u[j * (n + 1) + i] + self.v[(j + 1) * n + i] - self.v[j * n + i]) / dx
            rhs[k] = -div * dx * dx / dt
        var x = List[Real](length=m, fill=0)
        var r = pcg(op, rhs, x, 1e-6, 4 * m + 16)
        for c in range(n * n):
            self.p[c] = 0
        for k in range(m):
            self.p[op.cells[k]] = x[k]
        # face updates: liquid-liquid and liquid-air (ghost p = 0 at theta)
        for j in range(n):
            for i in range(1, n):
                var a = self._liquid(i - 1, j)
                var b = self._liquid(i, j)
                if not a and not b:
                    continue
                var pa = self.p[j * n + i - 1]
                var pb = self.p[j * n + i]
                var dist = dx
                if a and not b:
                    var th = max(self.phi[j * n + i - 1] / (self.phi[j * n + i - 1] - self.phi[j * n + i]), Real(0.01))
                    pb = 0
                    dist = th * dx
                elif b and not a:
                    var th = max(self.phi[j * n + i] / (self.phi[j * n + i] - self.phi[j * n + i - 1]), Real(0.01))
                    pa = 0
                    dist = th * dx
                self.u[j * (n + 1) + i] -= dt * (pb - pa) / dist
        for j in range(1, n):
            for i in range(n):
                var a = self._liquid(i, j - 1)
                var b = self._liquid(i, j)
                if not a and not b:
                    continue
                var pa = self.p[(j - 1) * n + i]
                var pb = self.p[j * n + i]
                var dist = dx
                if a and not b:
                    var th = max(self.phi[(j - 1) * n + i] / (self.phi[(j - 1) * n + i] - self.phi[j * n + i]), Real(0.01))
                    pb = 0
                    dist = th * dx
                elif b and not a:
                    var th = max(self.phi[j * n + i] / (self.phi[j * n + i] - self.phi[(j - 1) * n + i]), Real(0.01))
                    pa = 0
                    dist = th * dx
                self.v[j * n + i] -= dt * (pb - pa) / dist
        # outlet faces: Dirichlet p = 0 at dx / 2 from the liquid cell
        var half = 0.5 * dx
        for j in range(n):
            if self.open[0] and self._liquid(0, j):
                self.u[j * (n + 1)] -= dt * self.p[j * n] / half
            if self.open[1] and self._liquid(n - 1, j):
                self.u[j * (n + 1) + n] += dt * self.p[j * n + n - 1] / half
        for i in range(n):
            if self.open[2] and self._liquid(i, 0):
                self.v[i] -= dt * self.p[i] / half
            if self.open[3] and self._liquid(i, n - 1):
                self.v[n * n + i] += dt * self.p[(n - 1) * n + i] / half
        return r

    def _extrapolate(mut self):
        var n = self.n
        # known faces: next to a liquid cell (or walls, which stay 0)
        var ku = List[Bool](length=(n + 1) * n, fill=False)
        var kv = List[Bool](length=n * (n + 1), fill=False)
        for j in range(n):
            for i in range(n + 1):
                var wall = (i == 0 and not self.open[0]) or (i == n and not self.open[1])
                ku[j * (n + 1) + i] = wall or self._liquid(i - 1, j) or self._liquid(i, j)
        for j in range(n + 1):
            for i in range(n):
                var wall = (j == 0 and not self.open[2]) or (j == n and not self.open[3])
                kv[j * n + i] = wall or self._liquid(i, j - 1) or self._liquid(i, j)
        for _ in range(self.extrap):
            var nku = ku.copy()
            for j in range(n):
                for i in range(1, n):
                    var f = j * (n + 1) + i
                    if ku[f]:
                        continue
                    var s = Real(0)
                    var c = 0
                    for d in [(-1, 0), (1, 0), (0, -1), (0, 1)]:
                        var ii = i + d[0]
                        var jj = j + d[1]
                        if ii >= 0 and ii <= n and jj >= 0 and jj < n and ku[jj * (n + 1) + ii]:
                            s += self.u[jj * (n + 1) + ii]
                            c += 1
                    if c > 0:
                        self.u[f] = s / Real(c)
                        nku[f] = True
            ku = nku^
            var nkv = kv.copy()
            for j in range(1, n):
                for i in range(n):
                    var f = j * n + i
                    if kv[f]:
                        continue
                    var s = Real(0)
                    var c = 0
                    for d in [(-1, 0), (1, 0), (0, -1), (0, 1)]:
                        var ii = i + d[0]
                        var jj = j + d[1]
                        if ii >= 0 and ii < n and jj >= 0 and jj <= n and kv[jj * n + ii]:
                            s += self.v[jj * n + ii]
                            c += 1
                    if c > 0:
                        self.v[f] = s / Real(c)
                        nkv[f] = True
            kv = nkv^

    def _redistance(mut self):
        """Fast sweeping for |grad phi| = 1, the cells next to a sign
        change kept fixed."""
        var n = self.n
        var dx = self.dx
        var big = Real(1e10)
        var fixed = List[Bool](length=n * n, fill=False)
        var d = List[Real](length=n * n, fill=big)
        for j in range(n):
            for i in range(n):
                var c = j * n + i
                var s = self.phi[c] < 0
                for e in [(-1, 0), (1, 0), (0, -1), (0, 1)]:
                    var ii = i + e[0]
                    var jj = j + e[1]
                    if ii >= 0 and ii < n and jj >= 0 and jj < n and (self.phi[jj * n + ii] < 0) != s:
                        fixed[c] = True
                if fixed[c]:
                    d[c] = abs(self.phi[c])
        for sweep in range(4):
            var i_up = sweep % 2 == 0
            var j_up = sweep < 2
            for jj in range(n):
                var j = jj if j_up else n - 1 - jj
                for ii in range(n):
                    var i = ii if i_up else n - 1 - ii
                    var c = j * n + i
                    if fixed[c]:
                        continue
                    var a = min(d[j * n + i - 1] if i > 0 else big, d[j * n + i + 1] if i < n - 1 else big)
                    var b = min(d[(j - 1) * n + i] if j > 0 else big, d[(j + 1) * n + i] if j < n - 1 else big)
                    var nd: Real
                    if abs(a - b) >= dx:
                        nd = min(a, b) + dx
                    else:
                        nd = (a + b + sqrt(2 * dx * dx - (a - b) * (a - b))) / 2
                    if nd < d[c]:
                        d[c] = nd
        for c in range(n * n):
            if not fixed[c]:
                self.phi[c] = -d[c] if self.phi[c] < 0 else d[c]

    def step(mut self, dt: Real) raises:
        if not (dt > 0):
            raise Error("LevelSetWater2.step: dt must be > 0")
        self._advect(dt)
        self._gravity(dt)
        self.last = self._project(dt)
        self._extrapolate()
        self.steps += 1
        if self.reinit_every > 0 and self.steps % self.reinit_every == 0:
            self._redistance()

    def max_speed(self) -> Real:
        var n = self.n
        var m = Real(0)
        for j in range(n):
            for i in range(1, n):
                if self._liquid(i - 1, j) or self._liquid(i, j):
                    m = max(m, abs(self.u[j * (n + 1) + i]))
        for j in range(1, n):
            for i in range(n):
                if self._liquid(i, j - 1) or self._liquid(i, j):
                    m = max(m, abs(self.v[j * n + i]))
        return m
