"""Position-Based Fluids (Macklin & Müller 2013) — the engine's first fluid.

PBF is the natural fluid for this codebase because it is the SAME solver shape
as everything else here: predict positions, project a constraint, derive
velocity from the position change. XPBD cloth enforces a distance constraint;
PBF enforces a DENSITY constraint

    C_i(p) = rho_i / rho_0 - 1 = 0,   rho_i = sum_j m * W(p_i - p_j, h)

so the machinery is shared and only the constraint changes. That is what makes
it the cheapest entry into fluids rather than a parallel universe of code.

Three details that are not optional, each of which produces visibly wrong
fluid if omitted:

  CFM relaxation — near the free surface a particle has few neighbours, the
  constraint gradient nearly vanishes, and lambda blows up. Adding `_EPS` to
  the denominator (Constraint Force Mixing) bounds it.

  Tensile instability correction — the same missing neighbours make surface
  particles clump into strings. `s_corr`, an artificial repulsive term based on
  W(dq)/W(r), pushes them apart and is what makes a surface look like a
  surface.

  XSPH viscosity — without it the velocity field is noisy and the fluid looks
  like sand. It averages each particle's velocity toward its neighbourhood.

Neighbours come from a uniform grid rebuilt each step (radius = kernel support,
so a 3x3x3 cell walk covers it). `test_pbf` gates the physical properties —
rest density is reached, the box is never escaped, and a dam break conserves
particle count and settles — rather than eyeballing a picture.
"""

from std.math import sqrt
from geometry.vec import Real, Vec3
from spatial.cell_sort import CellSort

comptime H: Real = 0.1
"""Kernel support radius. Public (not `_H`): `physics/sph.mojo` imports it
deliberately — SPH and PBF are meant to share the same smoothing length so
their kernels stay comparable, not two solvers that happen to agree by
coincidence (audit F18)."""
comptime _EPS: Real = 1e-4  # CFM relaxation, on the scale of sum|grad C|^2
comptime _K_CORR: Real = 0.0001  # tensile instability strength
comptime _N_CORR: Int = 4  # tensile instability exponent
comptime _DQ: Real = 0.03  # s_corr reference distance (fraction of h)
comptime _XSPH: Real = 0.01  # viscosity coefficient
comptime _MAX_CORR: Real = 0.2  # per-iteration displacement cap, in units of h


def poly6(r2: Real) -> Real:
    """W_poly6(r, h) without its normalisation constant folded out."""
    var h2 = H * H
    if r2 >= h2 or r2 < 0:
        return 0
    var t = h2 - r2
    return 315.0 / (64.0 * 3.14159265 * (H ** 9)) * t * t * t


def spiky_grad(r: Real) -> Real:
    """Magnitude of grad W_spiky(r, h); the direction is the separation unit
    vector. Spiky (not poly6) is used for the gradient because poly6's gradient
    vanishes at r -> 0 and particles would collapse onto each other."""
    if r >= H or r <= 1e-9:
        return 0
    var t = H - r
    return -45.0 / (3.14159265 * (H ** 6)) * t * t


struct PbfFluid(Movable):
    """SoA particle state. Split arrays keep every hot loop off width-3 SIMD,
    the same discipline `gpu_cloth` follows."""

    var x: List[Real]
    var y: List[Real]
    var z: List[Real]
    var vx: List[Real]
    var vy: List[Real]
    var vz: List[Real]
    var px: List[Real]  # predicted / working positions
    var py: List[Real]
    var pz: List[Real]
    var lam: List[Real]
    # container bounds
    var lo: Vec3
    var hi: Vec3
    # uniform grid
    var grid: CellSort  # particles by cell (spatial.cell_sort)
    var nx: Int
    var ny: Int
    var nz: Int
    var rho0: Real

    def __init__(out self, lo: Vec3, hi: Vec3):
        self.x = List[Real]()
        self.y = List[Real]()
        self.z = List[Real]()
        self.vx = List[Real]()
        self.vy = List[Real]()
        self.vz = List[Real]()
        self.px = List[Real]()
        self.py = List[Real]()
        self.pz = List[Real]()
        self.lam = List[Real]()
        self.lo = lo
        self.hi = hi
        self.grid = CellSort()
        self.nx = Int((hi[0] - lo[0]) / H) + 1
        self.ny = Int((hi[1] - lo[1]) / H) + 1
        self.nz = Int((hi[2] - lo[2]) / H) + 1
        self.rho0 = 1.0

    def calibrate(mut self, spacing: Real):
        """Rest density for a lattice at `spacing`, computed rather than
        guessed. Getting this wrong is not a tuning inconvenience: if rho0
        exceeds the density the sampling can actually reach, EVERY particle
        reads as under-dense, the correction pushes outward everywhere, and the
        fluid explodes against the container instead of settling. Deriving it
        from the same spacing the particles are seeded at makes C ~ 0 at rest
        by construction."""
        var reach = Int(H / spacing) + 1
        var rho = poly6(0)
        for i in range(-reach, reach + 1):
            for j in range(-reach, reach + 1):
                for k in range(-reach, reach + 1):
                    if i == 0 and j == 0 and k == 0:
                        continue
                    var dx = Real(i) * spacing
                    var dy = Real(j) * spacing
                    var dz = Real(k) * spacing
                    rho += poly6(dx * dx + dy * dy + dz * dz)
        self.rho0 = rho

    def count(self) -> Int:
        return len(self.x)

    def add(mut self, p: Vec3):
        self.x.append(p[0])
        self.y.append(p[1])
        self.z.append(p[2])
        self.vx.append(0)
        self.vy.append(0)
        self.vz.append(0)
        self.px.append(p[0])
        self.py.append(p[1])
        self.pz.append(p[2])
        self.lam.append(0)

    def _cell_of(self, cx: Int, cy: Int, cz: Int) -> Int:
        return (cz * self.ny + cy) * self.nx + cx

    def _clampi(self, v: Int, hi: Int) -> Int:
        return 0 if v < 0 else (hi - 1 if v >= hi else v)

    def _rebuild_grid(mut self):
        """Counting sort into a uniform grid over the PREDICTED positions."""
        var ncell = self.nx * self.ny * self.nz
        var n = self.count()
        var cid = List[Int]()
        for i in range(n):
            var cx = self._clampi(Int((self.px[i] - self.lo[0]) / H), self.nx)
            var cy = self._clampi(Int((self.py[i] - self.lo[1]) / H), self.ny)
            var cz = self._clampi(Int((self.pz[i] - self.lo[2]) / H), self.nz)
            var c = self._cell_of(cx, cy, cz)
            cid.append(c)
        self.grid.build(cid, ncell)

    def _neighbors(self, i: Int, mut out: List[Int]):
        out.clear()
        var cx = self._clampi(Int((self.px[i] - self.lo[0]) / H), self.nx)
        var cy = self._clampi(Int((self.py[i] - self.lo[1]) / H), self.ny)
        var cz = self._clampi(Int((self.pz[i] - self.lo[2]) / H), self.nz)
        for dz in range(-1, 2):
            var z2 = cz + dz
            if z2 < 0 or z2 >= self.nz:
                continue
            for dy in range(-1, 2):
                var y2 = cy + dy
                if y2 < 0 or y2 >= self.ny:
                    continue
                for dx in range(-1, 2):
                    var x2 = cx + dx
                    if x2 < 0 or x2 >= self.nx:
                        continue
                    var c = self._cell_of(x2, y2, z2)
                    for k in range(self.grid.start[c], self.grid.start[c + 1]):
                        var j = self.grid.items[k]
                        if j == i:
                            continue
                        var ddx = self.px[i] - self.px[j]
                        var ddy = self.py[i] - self.py[j]
                        var ddz = self.pz[i] - self.pz[j]
                        if ddx * ddx + ddy * ddy + ddz * ddz < H * H:
                            out.append(j)

    def _clamp_to_box(mut self, i: Int):
        var eps = Real(1e-4)
        if self.px[i] < self.lo[0] + eps:
            self.px[i] = self.lo[0] + eps
        if self.px[i] > self.hi[0] - eps:
            self.px[i] = self.hi[0] - eps
        if self.py[i] < self.lo[1] + eps:
            self.py[i] = self.lo[1] + eps
        if self.py[i] > self.hi[1] - eps:
            self.py[i] = self.hi[1] - eps
        if self.pz[i] < self.lo[2] + eps:
            self.pz[i] = self.lo[2] + eps
        if self.pz[i] > self.hi[2] - eps:
            self.pz[i] = self.hi[2] - eps

    def density(self, i: Int, nbr: List[Int]) -> Real:
        var rho = poly6(0)
        for ref j in nbr:
            var dx = self.px[i] - self.px[j]
            var dy = self.py[i] - self.py[j]
            var dz = self.pz[i] - self.pz[j]
            rho += poly6(dx * dx + dy * dy + dz * dz)
        return rho

    def step(mut self, dt: Real, gravity: Vec3, iters: Int):
        var n = self.count()
        # 1. predict
        for i in range(n):
            self.vx[i] += gravity[0] * dt
            self.vy[i] += gravity[1] * dt
            self.vz[i] += gravity[2] * dt
            self.px[i] = self.x[i] + self.vx[i] * dt
            self.py[i] = self.y[i] + self.vy[i] * dt
            self.pz[i] = self.z[i] + self.vz[i] * dt
            self._clamp_to_box(i)

        var nbr = List[Int]()
        var corr_x = List[Real]()
        var corr_y = List[Real]()
        var corr_z = List[Real]()
        for _ in range(n):
            corr_x.append(0)
            corr_y.append(0)
            corr_z.append(0)

        var wdq = poly6(_DQ * _DQ)

        # Neighbours are found ONCE per step from the predicted positions and
        # reused across every solver iteration — the standard PBF arrangement.
        # Rebuilding inside the loop is not more correct: corrections are a
        # fraction of the kernel radius, so the neighbour SET is stable across
        # iterations, and rebuilding it made the per-step cost scale with the
        # iteration count for no accuracy gain (measured: same settled density,
        # ~4x the time at it=4).
        self._rebuild_grid()
        for _ in range(iters):
            # 2. lambda per particle
            for i in range(n):
                self._neighbors(i, nbr)
                var rho = self.density(i, nbr)
                var c = rho / self.rho0 - 1.0
                # sum of squared constraint gradients
                var sum_grad2 = Real(0)
                var gix = Real(0)
                var giy = Real(0)
                var giz = Real(0)
                for ref j in nbr:
                    var dx = self.px[i] - self.px[j]
                    var dy = self.py[i] - self.py[j]
                    var dz = self.pz[i] - self.pz[j]
                    var r = sqrt(dx * dx + dy * dy + dz * dz)
                    if r <= 1e-9:
                        continue
                    var w = spiky_grad(r) / (self.rho0 * r)
                    var gx = w * dx
                    var gy = w * dy
                    var gz = w * dz
                    sum_grad2 += gx * gx + gy * gy + gz * gz
                    gix -= gx
                    giy -= gy
                    giz -= gz
                sum_grad2 += gix * gix + giy * giy + giz * giz
                self.lam[i] = -c / (sum_grad2 + _EPS)

            # 3. position correction
            for i in range(n):
                corr_x[i] = 0
                corr_y[i] = 0
                corr_z[i] = 0
            for i in range(n):
                self._neighbors(i, nbr)
                var ax = Real(0)
                var ay = Real(0)
                var az = Real(0)
                for ref j in nbr:
                    var dx = self.px[i] - self.px[j]
                    var dy = self.py[i] - self.py[j]
                    var dz = self.pz[i] - self.pz[j]
                    var r2 = dx * dx + dy * dy + dz * dz
                    var r = sqrt(r2)
                    if r <= 1e-9:
                        continue
                    # tensile instability: artificial pressure keeps surface
                    # particles from clumping into strings
                    var ratio = poly6(r2) / wdq if wdq > 1e-20 else Real(0)
                    var scorr = -_K_CORR * (ratio ** _N_CORR)
                    var w = spiky_grad(r) / (self.rho0 * r)
                    var f = (self.lam[i] + self.lam[j] + scorr) * w
                    ax += f * dx
                    ay += f * dy
                    az += f * dz
                corr_x[i] = ax
                corr_y[i] = ay
                corr_z[i] = az
            for i in range(n):
                # Clamp the per-iteration displacement. Without this the
                # projection can overshoot far enough to push particles past
                # each other, and the solver then oscillates instead of
                # converging: measured behaviour was erratic in the ITERATION
                # COUNT (2 and 4 converged, 3 and 6 collapsed), which is the
                # signature of divergence rather than of under-resolution.
                # A particle has no business moving a large fraction of the
                # kernel radius in one projection step.
                var dx = corr_x[i]
                var dy = corr_y[i]
                var dz = corr_z[i]
                var m2 = dx * dx + dy * dy + dz * dz
                var lim = _MAX_CORR * H
                if m2 > lim * lim:
                    var sc = lim / sqrt(m2)
                    dx *= sc
                    dy *= sc
                    dz *= sc
                self.px[i] += dx
                self.py[i] += dy
                self.pz[i] += dz
                self._clamp_to_box(i)

        # 4. velocity from position change, then XSPH viscosity
        for i in range(n):
            self.vx[i] = (self.px[i] - self.x[i]) / dt
            self.vy[i] = (self.py[i] - self.y[i]) / dt
            self.vz[i] = (self.pz[i] - self.z[i]) / dt
        self._rebuild_grid()
        var dvx = List[Real]()
        var dvy = List[Real]()
        var dvz = List[Real]()
        for i in range(n):
            self._neighbors(i, nbr)
            var ax = Real(0)
            var ay = Real(0)
            var az = Real(0)
            for ref j in nbr:
                var dx = self.px[i] - self.px[j]
                var dy = self.py[i] - self.py[j]
                var dz = self.pz[i] - self.pz[j]
                var w = poly6(dx * dx + dy * dy + dz * dz)
                ax += (self.vx[j] - self.vx[i]) * w
                ay += (self.vy[j] - self.vy[i]) * w
                az += (self.vz[j] - self.vz[i]) * w
            # XSPH must be normalised by density: poly6 is unnormalised and
            # of order 1e3 here, so summing it raw over ~30 neighbours injects
            # velocity thousands of times larger than the field it is meant to
            # smooth — the solver then gains energy every step instead of
            # dissipating it.
            var inv = 1.0 / self.rho0
            dvx.append(_XSPH * ax * inv)
            dvy.append(_XSPH * ay * inv)
            dvz.append(_XSPH * az * inv)
        for i in range(n):
            self.vx[i] += dvx[i]
            self.vy[i] += dvy[i]
            self.vz[i] += dvz[i]
            self.x[i] = self.px[i]
            self.y[i] = self.py[i]
            self.z[i] = self.pz[i]
