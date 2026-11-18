"""Free-surface water on a 3-D MAC grid with a level set (ROADMAP 17.60:
the 3-D counterpart of `physics.mac_levelset.LevelSetWater2`; Enright /
Foster & Fedkiw, Gibou's ghost fluid for the surface pressure).

An n x n x n box of cells with solid walls on all six sides unless
`set_open` turns some into outlets (the same rule as `LevelSetWater2`:
boundary face from its interior neighbour, Dirichlet p = 0 at dx / 2 for
liquid cells next to it). phi at the
cell centres is a signed distance, negative in the liquid. u on the x
faces ((n + 1) x n x n), v on the y faces (n x (n + 1) x n), w on the z
faces (n x n x (n + 1)); the wall faces stay zero. Gravity acts along -y,
as in `physics.flip3.FlipWater3`. One `step(dt)`:

  1. advect phi, u, v and w semi-Lagrangian (RK2, trilinear, clamped to
     the box);
  2. gravity on the v faces next to liquid;
  3. pressure on the liquid cells only: -lap p = -div u / dt with the
     walls as Neumann (no flux) and the surface as Dirichlet p = 0 placed
     where phi crosses zero between a liquid cell and an air neighbour
     (ghost fluid: the neighbour's coefficient becomes 1 / theta,
     theta = phi_l / (phi_l - phi_a) >= 0.01, into the diagonal); solved
     by `numerics.pcg` matrix-free;
  4. faces between liquid and liquid or liquid and air get u -= dt grad p
     (air pressure 0 at the theta point);
  5. velocities are extrapolated into the air in `extrap` rings (each air
     face takes the mean of its known neighbours);
  6. every `reinit_every` steps phi is redistanced by fast sweeping over
     the eight sweep orders (Zhao 2005), keeping the cells next to the
     zero crossing fixed.

The 3-D Godunov update is the sorted-neighbour form: with the three
smallest axis values x0 <= x1 <= x2, the new distance is x0 + dx when that
is at most x1, else the two-axis root when it is at most x2, else the
three-axis root.
"""

from std.math import floor, sqrt
from geometry.vec import Real
from numerics.cg import pcg, CgResult
from .mac_levelset import _LiquidPoisson


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


def _ring(known: List[Bool], mut f: List[Real], n: Int, nx: Int, ny: Int, nz: Int) -> List[Bool]:
    """One extrapolation ring on one face array of n x n x n cells: each
    unknown interior face (index 1..n-1 along its own axis, the axis whose
    length is n + 1) takes the mean of its known neighbours. Faces on the
    walls (index 0 or n on that axis) stay 0 and are known."""
    var nxt = known.copy()
    var axis = 0 if nx == n + 1 else (1 if ny == n + 1 else 2)
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
                for d in range(6):
                    var ii = i + (1 if d == 0 else (-1 if d == 1 else 0))
                    var jj = j + (1 if d == 2 else (-1 if d == 3 else 0))
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


struct LevelSetWater3(Movable):
    var n: Int
    var dx: Real
    var gravity: Real  # downward (-y) acceleration (m/s^2)
    var phi: List[Real]  # [(k n + j) n + i]
    var u: List[Real]  # [(k n + j) (n + 1) + i], i = 0..n
    var v: List[Real]  # [(k (n + 1) + j) n + i], j = 0..n
    var w: List[Real]  # [(k n + j) n + i], k = 0..n
    var p: List[Real]  # per cell (0 in air)
    var last: CgResult
    var extrap: Int
    var reinit_every: Int
    var sweeps: Int  # fast-sweeping passes per redistancing (8 = every sweep order once)
    var steps: Int
    var open: List[Bool]  # per side: left (x = 0), right, bottom (y = 0), top, back (z = 0), front

    def __init__(out self, n: Int, dx: Real, gravity: Real = 9.81) raises:
        if n < 4 or not (dx > 0):
            raise Error("LevelSetWater3: n >= 4 and dx > 0")
        self.n = n
        self.dx = dx
        self.gravity = gravity
        var nn = n * n * n
        self.phi = List[Real](length=nn, fill=dx * Real(n))
        self.u = List[Real](length=(n + 1) * n * n, fill=0)
        self.v = List[Real](length=n * (n + 1) * n, fill=0)
        self.w = List[Real](length=n * n * (n + 1), fill=0)
        self.p = List[Real](length=nn, fill=0)
        self.last = CgResult(True, False, 0, 0)
        self.extrap = 4
        self.reinit_every = 5
        self.sweeps = 8
        self.steps = 0
        self.open = List[Bool](length=6, fill=False)

    def set_open(mut self, left: Bool, right: Bool, bottom: Bool, top: Bool, back: Bool, front: Bool):
        """Turns the walls on the given sides into outlets (see the 2-D
        `LevelSetWater2.set_open`). All False is the closed box."""
        self.open[0] = left
        self.open[1] = right
        self.open[2] = bottom
        self.open[3] = top
        self.open[4] = back
        self.open[5] = front

    def set_box(mut self, x0: Real, y0: Real, z0: Real, x1: Real, y1: Real, z1: Real):
        """Liquid where (x, y, z) is inside the box (metres); phi = signed
        distance to that box."""
        var n = self.n
        for k in range(n):
            for j in range(n):
                for i in range(n):
                    var x = (Real(i) + 0.5) * self.dx
                    var y = (Real(j) + 0.5) * self.dx
                    var z = (Real(k) + 0.5) * self.dx
                    var dxo = max(x0 - x, x - x1)
                    var dyo = max(y0 - y, y - y1)
                    var dzo = max(z0 - z, z - z1)
                    var outside = sqrt(
                        max(dxo, 0) * max(dxo, 0) + max(dyo, 0) * max(dyo, 0) + max(dzo, 0) * max(dzo, 0)
                    )
                    var inside = min(max(dxo, max(dyo, dzo)), 0)
                    self.phi[(k * n + j) * n + i] = outside + inside

    def volume(self) -> Real:
        var c = 0
        for f in self.phi:
            if f < 0:
                c += 1
        return Real(c) * self.dx * self.dx * self.dx

    def front_x(self) -> Real:
        """Rightmost liquid cell centre on the bottom row (j = 0) of the
        middle z plane (m), 0 if there is none."""
        var n = self.n
        var k = n // 2
        var best = Real(0)
        for i in range(n):
            if self.phi[(k * n + 0) * n + i] < 0:
                best = (Real(i) + 0.5) * self.dx
        return best

    # ---------------------------------------------------------------- sampling
    def _sample(
        self, f: List[Real], nx: Int, ny: Int, nz: Int, x: Real, y: Real, z: Real, ox: Real, oy: Real, oz: Real
    ) -> Real:
        """Trilinear sample of a field with nx x ny x nz samples at
        ((i + ox) dx, (j + oy) dx, (k + oz) dx), clamped to its extent."""
        var gx = min(max(x / self.dx - ox, 0), Real(nx - 1))
        var gy = min(max(y / self.dx - oy, 0), Real(ny - 1))
        var gz = min(max(z / self.dx - oz, 0), Real(nz - 1))
        var i0 = min(Int(floor(gx)), nx - 2)
        var j0 = min(Int(floor(gy)), ny - 2)
        var k0 = min(Int(floor(gz)), nz - 2)
        var ax = gx - Real(i0)
        var ay = gy - Real(j0)
        var az = gz - Real(k0)
        var c00 = f[(k0 * ny + j0) * nx + i0] * (1 - ax) + f[(k0 * ny + j0) * nx + i0 + 1] * ax
        var c10 = f[(k0 * ny + j0 + 1) * nx + i0] * (1 - ax) + f[(k0 * ny + j0 + 1) * nx + i0 + 1] * ax
        var c01 = f[((k0 + 1) * ny + j0) * nx + i0] * (1 - ax) + f[((k0 + 1) * ny + j0) * nx + i0 + 1] * ax
        var c11 = f[((k0 + 1) * ny + j0 + 1) * nx + i0] * (1 - ax) + f[((k0 + 1) * ny + j0 + 1) * nx + i0 + 1] * ax
        var lo = c00 * (1 - ay) + c10 * ay
        var hi = c01 * (1 - ay) + c11 * ay
        return lo * (1 - az) + hi * az

    def velocity(self, x: Real, y: Real, z: Real) -> Tuple[Real, Real, Real]:
        var n = self.n
        return (
            self._sample(self.u, n + 1, n, n, x, y, z, 0, 0.5, 0.5),
            self._sample(self.v, n, n + 1, n, x, y, z, 0.5, 0, 0.5),
            self._sample(self.w, n, n, n + 1, x, y, z, 0.5, 0.5, 0),
        )

    def _back(self, x: Real, y: Real, z: Real, dt: Real) -> Tuple[Real, Real, Real]:
        var v0 = self.velocity(x, y, z)
        var vm = self.velocity(x - 0.5 * dt * v0[0], y - 0.5 * dt * v0[1], z - 0.5 * dt * v0[2])
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
        var nphi = List[Real](length=n * n * n, fill=0)
        var nu_ = List[Real](length=(n + 1) * n * n, fill=0)
        var nv_ = List[Real](length=n * (n + 1) * n, fill=0)
        var nw_ = List[Real](length=n * n * (n + 1), fill=0)
        for k in range(n):
            for j in range(n):
                for i in range(n):
                    var b = self._back((Real(i) + 0.5) * dx, (Real(j) + 0.5) * dx, (Real(k) + 0.5) * dx, dt)
                    nphi[(k * n + j) * n + i] = self._sample(self.phi, n, n, n, b[0], b[1], b[2], 0.5, 0.5, 0.5)
        for k in range(n):
            for j in range(n):
                for i in range(1, n):
                    var b = self._back(Real(i) * dx, (Real(j) + 0.5) * dx, (Real(k) + 0.5) * dx, dt)
                    nu_[(k * n + j) * (n + 1) + i] = self._sample(self.u, n + 1, n, n, b[0], b[1], b[2], 0, 0.5, 0.5)
        for k in range(n):
            for j in range(1, n):
                for i in range(n):
                    var b = self._back((Real(i) + 0.5) * dx, Real(j) * dx, (Real(k) + 0.5) * dx, dt)
                    nv_[(k * (n + 1) + j) * n + i] = self._sample(self.v, n, n + 1, n, b[0], b[1], b[2], 0.5, 0, 0.5)
        for k in range(1, n):
            for j in range(n):
                for i in range(n):
                    var b = self._back((Real(i) + 0.5) * dx, (Real(j) + 0.5) * dx, Real(k) * dx, dt)
                    nw_[(k * n + j) * n + i] = self._sample(self.w, n, n, n + 1, b[0], b[1], b[2], 0.5, 0.5, 0)
        # outlet faces start from their interior neighbour (zero gradient)
        for k in range(n):
            for j in range(n):
                if self.open[0]:
                    nu_[(k * n + j) * (n + 1)] = nu_[(k * n + j) * (n + 1) + 1]
                if self.open[1]:
                    nu_[(k * n + j) * (n + 1) + n] = nu_[(k * n + j) * (n + 1) + n - 1]
        for k in range(n):
            for i in range(n):
                if self.open[2]:
                    nv_[(k * (n + 1)) * n + i] = nv_[(k * (n + 1) + 1) * n + i]
                if self.open[3]:
                    nv_[(k * (n + 1) + n) * n + i] = nv_[(k * (n + 1) + n - 1) * n + i]
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
        return i >= 0 and i < n and j >= 0 and j < n and k >= 0 and k < n and self.phi[(k * n + j) * n + i] < 0

    def _gravity(mut self, dt: Real):
        var n = self.n
        for k in range(n):
            for j in range(1, n):
                for i in range(n):
                    if self._liquid(i, j, k) or self._liquid(i, j - 1, k):
                        self.v[(k * (n + 1) + j) * n + i] -= self.gravity * dt
        # outlet faces on the floor and ceiling (same rule as the interior)
        for k in range(n):
            for i in range(n):
                if self.open[2] and self._liquid(i, 0, k):
                    self.v[(k * (n + 1)) * n + i] -= self.gravity * dt
                if self.open[3] and self._liquid(i, n - 1, k):
                    self.v[(k * (n + 1) + n) * n + i] -= self.gravity * dt

    def _project(mut self, dt: Real) -> CgResult:
        var n = self.n
        var dx = self.dx
        var op = _LiquidPoisson[3](n, self.phi, self.open)
        var m = op.size()
        var rhs = List[Real](length=m, fill=0)
        for q in range(m):
            var c = op.cells[q]
            var i = c % n
            var j = (c // n) % n
            var k = c // (n * n)
            var div = (
                self.u[(k * n + j) * (n + 1) + i + 1] - self.u[(k * n + j) * (n + 1) + i]
                + self.v[(k * (n + 1) + j + 1) * n + i] - self.v[(k * (n + 1) + j) * n + i]
                + self.w[((k + 1) * n + j) * n + i] - self.w[(k * n + j) * n + i]
            ) / dx
            rhs[q] = -div * dx * dx / dt
        var x = List[Real](length=m, fill=0)
        var r = pcg(op, rhs, x, 1e-6, 4 * m + 16)
        for c in range(n * n * n):
            self.p[c] = 0
        for q in range(m):
            self.p[op.cells[q]] = x[q]
        # face updates: liquid-liquid and liquid-air (ghost p = 0 at theta)
        for k in range(n):
            for j in range(n):
                for i in range(1, n):
                    var ca = (k * n + j) * n + i - 1
                    var cb = (k * n + j) * n + i
                    var a = self._liquid(i - 1, j, k)
                    var b = self._liquid(i, j, k)
                    if not a and not b:
                        continue
                    var pa = self.p[ca]
                    var pb = self.p[cb]
                    var dist = dx
                    if a and not b:
                        var th = max(self.phi[ca] / (self.phi[ca] - self.phi[cb]), Real(0.01))
                        pb = 0
                        dist = th * dx
                    elif b and not a:
                        var th = max(self.phi[cb] / (self.phi[cb] - self.phi[ca]), Real(0.01))
                        pa = 0
                        dist = th * dx
                    self.u[(k * n + j) * (n + 1) + i] -= dt * (pb - pa) / dist
        for k in range(n):
            for j in range(1, n):
                for i in range(n):
                    var ca = (k * n + j - 1) * n + i
                    var cb = (k * n + j) * n + i
                    var a = self._liquid(i, j - 1, k)
                    var b = self._liquid(i, j, k)
                    if not a and not b:
                        continue
                    var pa = self.p[ca]
                    var pb = self.p[cb]
                    var dist = dx
                    if a and not b:
                        var th = max(self.phi[ca] / (self.phi[ca] - self.phi[cb]), Real(0.01))
                        pb = 0
                        dist = th * dx
                    elif b and not a:
                        var th = max(self.phi[cb] / (self.phi[cb] - self.phi[ca]), Real(0.01))
                        pa = 0
                        dist = th * dx
                    self.v[(k * (n + 1) + j) * n + i] -= dt * (pb - pa) / dist
        for k in range(1, n):
            for j in range(n):
                for i in range(n):
                    var ca = ((k - 1) * n + j) * n + i
                    var cb = (k * n + j) * n + i
                    var a = self._liquid(i, j, k - 1)
                    var b = self._liquid(i, j, k)
                    if not a and not b:
                        continue
                    var pa = self.p[ca]
                    var pb = self.p[cb]
                    var dist = dx
                    if a and not b:
                        var th = max(self.phi[ca] / (self.phi[ca] - self.phi[cb]), Real(0.01))
                        pb = 0
                        dist = th * dx
                    elif b and not a:
                        var th = max(self.phi[cb] / (self.phi[cb] - self.phi[ca]), Real(0.01))
                        pa = 0
                        dist = th * dx
                    self.w[(k * n + j) * n + i] -= dt * (pb - pa) / dist
        # outlet faces: Dirichlet p = 0 at dx / 2 from the liquid cell
        var half = 0.5 * dx
        for k in range(n):
            for j in range(n):
                if self.open[0] and self._liquid(0, j, k):
                    self.u[(k * n + j) * (n + 1)] -= dt * self.p[(k * n + j) * n] / half
                if self.open[1] and self._liquid(n - 1, j, k):
                    self.u[(k * n + j) * (n + 1) + n] += dt * self.p[(k * n + j) * n + n - 1] / half
        for k in range(n):
            for i in range(n):
                if self.open[2] and self._liquid(i, 0, k):
                    self.v[(k * (n + 1)) * n + i] -= dt * self.p[k * n * n + i] / half
                if self.open[3] and self._liquid(i, n - 1, k):
                    self.v[(k * (n + 1) + n) * n + i] += dt * self.p[(k * n + n - 1) * n + i] / half
        for j in range(n):
            for i in range(n):
                if self.open[4] and self._liquid(i, j, 0):
                    self.w[j * n + i] -= dt * self.p[j * n + i] / half
                if self.open[5] and self._liquid(i, j, n - 1):
                    self.w[n * n * n + j * n + i] += dt * self.p[((n - 1) * n + j) * n + i] / half
        return r

    def _extrapolate(mut self):
        var n = self.n
        # known faces: next to a liquid cell (walls stay 0 and are known)
        var ku = List[Bool](length=(n + 1) * n * n, fill=False)
        var kv = List[Bool](length=n * (n + 1) * n, fill=False)
        var kw = List[Bool](length=n * n * (n + 1), fill=False)
        for k in range(n):
            for j in range(n):
                for i in range(n + 1):
                    var wall = (i == 0 and not self.open[0]) or (i == n and not self.open[1])
                    ku[(k * n + j) * (n + 1) + i] = wall or self._liquid(i - 1, j, k) or self._liquid(i, j, k)
        for k in range(n):
            for j in range(n + 1):
                for i in range(n):
                    var wall = (j == 0 and not self.open[2]) or (j == n and not self.open[3])
                    kv[(k * (n + 1) + j) * n + i] = wall or self._liquid(i, j - 1, k) or self._liquid(i, j, k)
        for k in range(n + 1):
            for j in range(n):
                for i in range(n):
                    var wall = (k == 0 and not self.open[4]) or (k == n and not self.open[5])
                    kw[(k * n + j) * n + i] = wall or self._liquid(i, j, k - 1) or self._liquid(i, j, k)
        for _ in range(self.extrap):
            ku = _ring(ku, self.u, n, n + 1, n, n)
            kv = _ring(kv, self.v, n, n, n + 1, n)
            kw = _ring(kw, self.w, n, n, n, n + 1)

    def _redistance(mut self):
        """Fast sweeping for |grad phi| = 1 over the eight sweep orders; the
        cells next to a sign change are kept fixed."""
        var n = self.n
        var dx = self.dx
        var big = Real(1e10)
        var nn = n * n * n
        var fixed = List[Bool](length=nn, fill=False)
        var d = List[Real](length=nn, fill=big)
        for k in range(n):
            for j in range(n):
                for i in range(n):
                    var c = (k * n + j) * n + i
                    var s = self.phi[c] < 0
                    for e in range(6):
                        var ii = i + (1 if e == 0 else (-1 if e == 1 else 0))
                        var jj = j + (1 if e == 2 else (-1 if e == 3 else 0))
                        var kk = k + (1 if e == 4 else (-1 if e == 5 else 0))
                        if ii >= 0 and ii < n and jj >= 0 and jj < n and kk >= 0 and kk < n:
                            if (self.phi[(kk * n + jj) * n + ii] < 0) != s:
                                fixed[c] = True
                    if fixed[c]:
                        d[c] = abs(self.phi[c])
        for sweep in range(self.sweeps):
            var i_up = (sweep & 1) == 0
            var j_up = (sweep & 2) == 0
            var k_up = (sweep & 4) == 0
            for kk in range(n):
                var k = kk if k_up else n - 1 - kk
                for jj in range(n):
                    var j = jj if j_up else n - 1 - jj
                    for ii in range(n):
                        var i = ii if i_up else n - 1 - ii
                        var c = (k * n + j) * n + i
                        if fixed[c]:
                            continue
                        var a = min(d[(k * n + j) * n + i - 1] if i > 0 else big, d[(k * n + j) * n + i + 1] if i < n - 1 else big)
                        var b = min(d[(k * n + j - 1) * n + i] if j > 0 else big, d[(k * n + j + 1) * n + i] if j < n - 1 else big)
                        var e = min(d[((k - 1) * n + j) * n + i] if k > 0 else big, d[((k + 1) * n + j) * n + i] if k < n - 1 else big)
                        var nd = _godunov(a, b, e, dx)
                        if nd < d[c]:
                            d[c] = nd
        for c in range(nn):
            if not fixed[c]:
                self.phi[c] = -d[c] if self.phi[c] < 0 else d[c]

    def step(mut self, dt: Real) raises:
        if not (dt > 0):
            raise Error("LevelSetWater3.step: dt must be > 0")
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
        for k in range(n):
            for j in range(n):
                for i in range(1, n):
                    if self._liquid(i - 1, j, k) or self._liquid(i, j, k):
                        m = max(m, abs(self.u[(k * n + j) * (n + 1) + i]))
        for k in range(n):
            for j in range(1, n):
                for i in range(n):
                    if self._liquid(i, j - 1, k) or self._liquid(i, j, k):
                        m = max(m, abs(self.v[(k * (n + 1) + j) * n + i]))
        for k in range(1, n):
            for j in range(n):
                for i in range(n):
                    if self._liquid(i, j, k - 1) or self._liquid(i, j, k):
                        m = max(m, abs(self.w[(k * n + j) * n + i]))
        return m
