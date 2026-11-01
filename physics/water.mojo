"""Water surfaces and floating bodies on them (ROADMAP 17.60).

`fields.WaterVolume` is a flat AABB of water. A boat on a sea needs the
surface height where each of its hull points is, at the current time. The
`WaterSurface` trait is that query, chosen at compile time:

  * `FlatWater`: a constant level.
  * `GerstnerWater`: a sum of Gerstner (trochoidal) waves with deep-water
    dispersion w^2 = g k. Closed form in t: any time can be queried
    directly, with no stepping (rollback and replay friendly). Gerstner
    points move horizontally (steepness Q), so the height above a fixed
    (x, z) needs the inverse map; `height` does 4 fixed-point iterations.
    With all amplitudes 0 it returns the level bit for bit; with Q = 0 a
    single wave is exactly A cos(k . x - w t + phase).
  * `ShallowWaterGrid`: an interactive ripple field, the linear shallow-water
    (wave) equation eta_tt = g H lap(eta) on a grid, explicit leapfrog with
    damping; `disturb` pushes the surface, `step` advances it. Its `height`
    ignores t (it is the current state).
  * `FftOcean`: a periodic patch summed from a wave spectrum (Tessendorf
    2001; Phillips spectrum from a seed, or modes set one by one); one
    inverse FFT per `update(t)`, exact mode sums between updates.

`float_body` applies buoyancy by sampling the body's box at n^3 points: each
point below the local surface pushes up with rho g dV at that point (so the
torque follows), plus a drag on the velocity relative to the water.
"""

from std.math import sqrt, pi, exp, log, floor
from geometry.trig import sin, cos
from numerics.fft import fft2
from scheduler.rng import SplitMix64
from geometry.vec import Real, Vec3
from .body_set import BodyId
from .rigid6 import Body6
from .solver6 import ContactScene6
from .fields import WaterVolume, sphere_submerged, _PI, _cell_half_height, _cell_below
from collision.collider_set import SHAPE_BOX, SHAPE_SPHERE


trait WaterSurface:
    def height(self, x: Real, z: Real, t: Real) -> Real: ...

    def velocity(self, x: Real, z: Real, t: Real) -> Vec3: ...


@fieldwise_init
struct FlatWater(WaterSurface, Copyable, Movable):
    var level: Real

    def height(self, x: Real, z: Real, t: Real) -> Real:
        return self.level

    def velocity(self, x: Real, z: Real, t: Real) -> Vec3:
        return Vec3(0, 0, 0, 0)


@fieldwise_init
struct GerstnerWave(Copyable, ImplicitlyCopyable, Movable):
    var dir_x: Real  # unit horizontal direction
    var dir_z: Real
    var amplitude: Real
    var wavelength: Real
    var steepness: Real  # Q in [0, 1]; 0 = plain sine
    var phase: Real


struct GerstnerWater(WaterSurface, Copyable, Movable):
    var level: Real
    var gravity: Real
    var waves: List[GerstnerWave]

    def __init__(out self, level: Real, gravity: Real = 9.8):
        self.level = level
        self.gravity = gravity
        self.waves = List[GerstnerWave]()

    def add(mut self, dir_x: Real, dir_z: Real, amplitude: Real, wavelength: Real, steepness: Real = 0, phase: Real = 0):
        var l = sqrt(dir_x * dir_x + dir_z * dir_z)
        self.waves.append(GerstnerWave(dir_x / l, dir_z / l, amplitude, wavelength, steepness, phase))

    def omega(self, w: Int) -> Real:
        var k = 2 * Real(pi) / self.waves[w].wavelength
        return sqrt(self.gravity * k)

    def _displace(self, x0: Real, z0: Real, t: Real) -> Vec3:
        """Where the surface point with rest position (x0, z0) is at t."""
        var x = x0
        var z = z0
        var y = self.level
        for w in range(len(self.waves)):
            ref wv = self.waves[w]
            var k = 2 * Real(pi) / wv.wavelength
            var th = k * (wv.dir_x * x0 + wv.dir_z * z0) - self.omega(w) * t + wv.phase
            var c = cos(th)
            y += wv.amplitude * c
            # horizontal displacement -Q A d sin(th): points crowd at crests
            x -= wv.steepness * wv.amplitude * wv.dir_x * sin(th)
            z -= wv.steepness * wv.amplitude * wv.dir_z * sin(th)
        return Vec3(x, y, z, 0)

    def height(self, x: Real, z: Real, t: Real) -> Real:
        # invert the horizontal map: find the rest position whose displaced
        # point lands on (x, z)
        var x0 = x
        var z0 = z
        for _ in range(4):
            var p = self._displace(x0, z0, t)
            x0 -= p[0] - x
            z0 -= p[2] - z
        return self._displace(x0, z0, t)[1]

    def velocity(self, x: Real, z: Real, t: Real) -> Vec3:
        """Surface particle velocity (d/dt of the displacement) at (x, z)."""
        var h = Real(1e-3)
        var a = self._displace(x, z, t - h)
        var b = self._displace(x, z, t + h)
        return (b - a) * (1 / (2 * h))


struct ShallowWaterGrid(WaterSurface, Movable):
    var nx: Int
    var nz: Int
    var cell: Real
    var origin_x: Real
    var origin_z: Real
    var level: Real
    var depth: Real  # mean depth H
    var gravity: Real
    var damping: Real  # 1/s
    var eta: List[Real]  # surface elevation above `level`
    var prev: List[Real]

    def __init__(out self, nx: Int, nz: Int, cell: Real, origin_x: Real, origin_z: Real, level: Real, depth: Real, gravity: Real = 9.8, damping: Real = 0.0) raises:
        if nx < 3 or nz < 3 or cell <= 0 or depth <= 0:
            raise Error("ShallowWaterGrid: need >= 3 x 3 cells, cell > 0, depth > 0")
        self.nx = nx
        self.nz = nz
        self.cell = cell
        self.origin_x = origin_x
        self.origin_z = origin_z
        self.level = level
        self.depth = depth
        self.gravity = gravity
        self.damping = damping
        self.eta = List[Real](length=nx * nz, fill=0)
        self.prev = List[Real](length=nx * nz, fill=0)

    def wave_speed(self) -> Real:
        return sqrt(self.gravity * self.depth)

    def max_dt(self) -> Real:
        """CFL limit of the 5-point leapfrog: c dt / dx <= 1 / sqrt(2)."""
        return self.cell / (self.wave_speed() * sqrt(Real(2)))

    def disturb(mut self, x: Real, z: Real, radius: Real, amount: Real):
        """Raise (or lower) the surface by `amount` with a cosine bump."""
        for j in range(self.nz):
            for i in range(self.nx):
                var dx = self.origin_x + Real(i) * self.cell - x
                var dz = self.origin_z + Real(j) * self.cell - z
                var d = sqrt(dx * dx + dz * dz)
                if d < radius:
                    var b = amount * 0.5 * (1 + cos(Real(pi) * d / radius))
                    self.eta[j * self.nx + i] += b
                    self.prev[j * self.nx + i] += b

    def step(mut self, dt: Real) raises:
        if dt > self.max_dt():
            raise Error("ShallowWaterGrid.step: dt above the CFL limit " + String(self.max_dt()))
        var c2 = self.gravity * self.depth * dt * dt / (self.cell * self.cell)
        var d = self.damping * dt
        var nxt = List[Real](length=self.nx * self.nz, fill=0)
        for j in range(self.nz):
            for i in range(self.nx):
                var k = j * self.nx + i
                # reflecting walls: mirror the missing neighbour
                var l = self.eta[k - 1] if i > 0 else self.eta[k + 1]
                var r = self.eta[k + 1] if i < self.nx - 1 else self.eta[k - 1]
                var u = self.eta[k - self.nx] if j > 0 else self.eta[k + self.nx]
                var w = self.eta[k + self.nx] if j < self.nz - 1 else self.eta[k - self.nx]
                var lap = l + r + u + w - 4 * self.eta[k]
                nxt[k] = ((2 - d) * self.eta[k] - (1 - d) * self.prev[k] + c2 * lap)
        self.prev = self.eta^
        self.eta = nxt^

    def _sample(self, f: List[Real], x: Real, z: Real) -> Real:
        var fx = (x - self.origin_x) / self.cell
        var fz = (z - self.origin_z) / self.cell
        var i0 = min(max(Int(fx), 0), self.nx - 2)
        var j0 = min(max(Int(fz), 0), self.nz - 2)
        var tx = min(max(fx - Real(i0), Real(0)), Real(1))
        var tz = min(max(fz - Real(j0), Real(0)), Real(1))
        var a = f[j0 * self.nx + i0] * (1 - tx) + f[j0 * self.nx + i0 + 1] * tx
        var b = f[(j0 + 1) * self.nx + i0] * (1 - tx) + f[(j0 + 1) * self.nx + i0 + 1] * tx
        return a * (1 - tz) + b * tz

    def height(self, x: Real, z: Real, t: Real) -> Real:
        return self.level + self._sample(self.eta, x, z)

    def velocity(self, x: Real, z: Real, t: Real) -> Vec3:
        return Vec3(0, 0, 0, 0)  # vertical rate only would need dt; not tracked

    def energy(self) -> Real:
        """Potential energy proxy sum(eta^2) (decays with damping)."""
        var e = Real(0)
        for v in self.eta:
            e += v * v
        return e


def float_body[W: WaterSurface, B: Body6](
    mut sc: ContactScene6[B], id: BodyId, half: Vec3, water: W, t: Real,
    density: Real, gravity: Vec3, drag: Real = 1.0, samples: Int = 4,
) raises -> Real:
    """Buoyancy and drag on a box-shaped body (half extents `half`) from
    `water` at time t, accumulated as forces for the next step. Returns the
    submerged volume."""
    var pose = sc.pose(id)
    var v = sc.velocity(id)
    var om = sc.angular_velocity(id)
    var n = samples
    var dv = 8 * half[0] * half[1] * half[2] / Real(n * n * n)
    var sub = Real(0)
    for i in range(n):
        for j in range(n):
            for k in range(n):
                var lp = Vec3(
                    (Real(2 * i + 1) / Real(n) - 1) * half[0],
                    (Real(2 * j + 1) / Real(n) - 1) * half[1],
                    (Real(2 * k + 1) / Real(n) - 1) * half[2],
                    0,
                )
                var wp = pose.pos + pose.rot.rotate(lp)
                if wp[1] >= water.height(wp[0], wp[2], t):
                    continue
                sub += dv
                var fb = gravity * (-density * dv)
                var pv = v + _cross(om, wp - pose.pos)
                var rel = water.velocity(wp[0], wp[2], t) - pv
                sc.add_force_at(id, fb + rel * (drag * density * dv), wp)
    return sub


def _cross(a: Vec3, b: Vec3) -> Vec3:
    return Vec3(a[1] * b[2] - a[2] * b[1], a[2] * b[0] - a[0] * b[2], a[0] * b[1] - a[1] * b[0], 0)


struct FftOcean(WaterSurface, Movable):
    """A periodic ocean patch from a wave spectrum (Tessendorf 2001), 17.60.

    Each wavevector k = 2 pi (m_x, m_z) / size of an n x n grid (m in
    [-n/2, n/2)) carries a complex amplitude h0(k); the surface is
        eta(x, t) = level + Re sum_k h0(k) exp(i (k . x - w(k) t)),
    w^2 = g |k| (deep water). One mode with h0 = A exp(i phase) is exactly
    a Gerstner wave with Q = 0 (`test_fft_ocean`). `phillips(seed, ...)`
    fills h0 from the Phillips spectrum with seeded Gaussian draws
    (`scheduler.rng.SplitMix64`): the same seed gives the same sea, bit for
    bit, at any t without stepping.

    `update(t)` evaluates the whole n x n grid at t with one inverse 2-D
    FFT (`numerics.fft`); `height(x, z, t)` interpolates that grid
    (bilinear, periodic) when t is the updated time, and otherwise sums
    the modes directly (exact, O(n^2) per query). `velocity` is the
    vertical surface velocity d eta / dt, summed directly. `choppy` = lambda
    > 0 shifts surface points horizontally (Tessendorf's choppy waves; one
    mode = Gerstner with Q = lambda); `height` then inverts the map with
    4 fixed-point iterations, as `GerstnerWater` does: at the updated t over
    the displacement grids `update` also builds (two more inverse FFTs,
    bilinear like the height grid), otherwise over exact sums.
    `normal` is the non-choppy surface's normal, from analytic slopes."""

    var n: Int
    var size: Real  # patch edge (m); the surface repeats with this period
    var level: Real
    var gravity: Real
    var h0_re: List[Real]  # [mz * n + mx], FFT index order
    var h0_im: List[Real]
    var grid: List[Real]  # eta - level at the grid points, at t_grid
    var t_grid: Real
    var has_grid: Bool
    var choppy: Real  # lambda: horizontal displacement -lambda k^ Im(...)
    var disp_x: List[Real]  # choppy displacement grids at t_grid (empty unless choppy)
    var disp_z: List[Real]

    def __init__(out self, n: Int, size: Real, level: Real, gravity: Real = 9.8) raises:
        if n < 2 or (n & (n - 1)) != 0 or not (size > 0):
            raise Error("FftOcean: n must be a power of two >= 2 and size > 0")
        self.n = n
        self.size = size
        self.level = level
        self.gravity = gravity
        self.h0_re = List[Real](length=n * n, fill=0)
        self.h0_im = List[Real](length=n * n, fill=0)
        self.grid = List[Real](length=n * n, fill=0)
        self.t_grid = 0
        self.has_grid = False
        self.choppy = 0
        self.disp_x = List[Real]()
        self.disp_z = List[Real]()

    def _m(self, i: Int) -> Int:
        return i if i < self.n // 2 else i - self.n

    def _k(self, ix: Int, iz: Int) -> Tuple[Real, Real]:
        var s = 2 * Real(pi) / self.size
        return (Real(self._m(ix)) * s, Real(self._m(iz)) * s)

    def omega(self, ix: Int, iz: Int) -> Real:
        var k = self._k(ix, iz)
        return sqrt(self.gravity * sqrt(k[0] * k[0] + k[1] * k[1]))

    def set_mode(mut self, mx: Int, mz: Int, amplitude: Real, phase: Real) raises:
        """One wave: wavevector 2 pi (mx, mz) / size, A cos(k . x - w t + phase)."""
        var h = self.n // 2
        if mx < -h or mx >= h or mz < -h or mz >= h:
            raise Error("FftOcean.set_mode: mode index outside [-n/2, n/2)")
        var ix = mx if mx >= 0 else mx + self.n
        var iz = mz if mz >= 0 else mz + self.n
        self.h0_re[iz * self.n + ix] = amplitude * cos(phase)
        self.h0_im[iz * self.n + ix] = amplitude * sin(phase)
        self.has_grid = False

    def phillips(mut self, seed: UInt64, amplitude: Real, wind_x: Real, wind_z: Real):
        """Phillips spectrum P(k) = amplitude exp(-1 / (k L)^2) / k^4 |k^ . w^|^2,
        L = |wind|^2 / g, h0 = (xi_r + i xi_i) sqrt(P / 2) with standard normal
        xi from `seed` (Box-Muller over SplitMix64); k = 0 stays 0."""
        var rng = SplitMix64.seeded(seed)
        var wl = sqrt(wind_x * wind_x + wind_z * wind_z)
        var wx = wind_x / wl if wl > 0 else Real(1)
        var wz = wind_z / wl if wl > 0 else Real(0)
        var big_l = wl * wl / self.gravity
        for iz in range(self.n):
            for ix in range(self.n):
                var g1 = _gauss(rng)
                var g2 = _gauss(rng)
                var k = self._k(ix, iz)
                var kl = sqrt(k[0] * k[0] + k[1] * k[1])
                var idx = iz * self.n + ix
                if kl <= 0 or big_l <= 0:
                    self.h0_re[idx] = 0
                    self.h0_im[idx] = 0
                    continue
                var kw = (k[0] * wx + k[1] * wz) / kl
                var p = amplitude * exp(-1 / (kl * big_l * kl * big_l)) / (kl * kl * kl * kl) * kw * kw
                var s = sqrt(p / 2)
                self.h0_re[idx] = g1 * s
                self.h0_im[idx] = g2 * s
        self.has_grid = False

    def update(mut self, t: Real) raises:
        """The grid at time t: h(k, t) = h0 exp(-i w t), one inverse FFT."""
        var n = self.n
        var re = List[Real](length=n * n, fill=0)
        var im = List[Real](length=n * n, fill=0)
        for iz in range(n):
            for ix in range(n):
                var idx = iz * n + ix
                var a = -self.omega(ix, iz) * t
                var c = cos(a)
                var s = sin(a)
                re[idx] = self.h0_re[idx] * c - self.h0_im[idx] * s
                im[idx] = self.h0_re[idx] * s + self.h0_im[idx] * c
        var cre = re.copy()
        var cim = im.copy()
        fft2(re, im, n, True)
        var scale = Real(n * n)  # the inverse divides by n^2; the sum does not
        for i in range(n * n):
            self.grid[i] = re[i] * scale
        self.t_grid = t
        self.has_grid = True
        if self.choppy != 0:
            self._update_displacement(cre, cim)

    def _update_displacement(mut self, cre: List[Real], cim: List[Real]) raises:
        """Choppy displacement grids from the time-shifted spectrum c:
        -lambda k^ Im(c e^{i k.x}) = Re(i lambda k^ c e^{i k.x}), so each
        component's spectrum is i lambda k^ c."""
        var n = self.n
        var xr = List[Real](length=n * n, fill=0)
        var xi = List[Real](length=n * n, fill=0)
        var zr = List[Real](length=n * n, fill=0)
        var zi = List[Real](length=n * n, fill=0)
        for iz in range(n):
            for ix in range(n):
                var idx = iz * n + ix
                var k = self._k(ix, iz)
                var kl = sqrt(k[0] * k[0] + k[1] * k[1])
                if kl <= 0:
                    continue
                var ax = self.choppy * k[0] / kl
                var az = self.choppy * k[1] / kl
                xr[idx] = -ax * cim[idx]
                xi[idx] = ax * cre[idx]
                zr[idx] = -az * cim[idx]
                zi[idx] = az * cre[idx]
        fft2(xr, xi, n, True)
        fft2(zr, zi, n, True)
        var scale = Real(n * n)
        self.disp_x = List[Real](length=n * n, fill=0)
        self.disp_z = List[Real](length=n * n, fill=0)
        for i in range(n * n):
            self.disp_x[i] = xr[i] * scale
            self.disp_z[i] = zr[i] * scale

    def _bilinear(self, g: List[Real], x: Real, z: Real) -> Real:
        """A periodic grid of this patch, bilinear at (x, z)."""
        var cell = self.size / Real(self.n)
        var fx = x / cell
        var fz = z / cell
        var x0 = Int(floor(fx))
        var z0 = Int(floor(fz))
        var ax = fx - Real(x0)
        var az = fz - Real(z0)
        var n = self.n
        var i0 = ((x0 % n) + n) % n
        var j0 = ((z0 % n) + n) % n
        var i1 = (i0 + 1) % n
        var j1 = (j0 + 1) % n
        var a = g[j0 * n + i0] * (1 - ax) + g[j0 * n + i1] * ax
        var b = g[j1 * n + i0] * (1 - ax) + g[j1 * n + i1] * ax
        return a * (1 - az) + b * az

    def direct(self, x: Real, z: Real, t: Real) -> Real:
        """Height above the level, summing every mode (exact, O(n^2))."""
        var acc = Real(0)
        for iz in range(self.n):
            for ix in range(self.n):
                var idx = iz * self.n + ix
                if self.h0_re[idx] == 0 and self.h0_im[idx] == 0:
                    continue
                var k = self._k(ix, iz)
                var a = k[0] * x + k[1] * z - self.omega(ix, iz) * t
                acc += self.h0_re[idx] * cos(a) - self.h0_im[idx] * sin(a)
        return acc

    def displaced(self, x0: Real, z0: Real, t: Real) -> Vec3:
        """Where the surface point with rest position (x0, z0) is at t:
        height plus the choppy horizontal shift
        -lambda sum k^ Im(h0 exp(i (k . x0 - w t))) (Tessendorf's D; for one
        mode exactly Gerstner's -Q A d sin(theta) with Q = lambda)."""
        var y = Real(0)
        var dx = Real(0)
        var dz = Real(0)
        for iz in range(self.n):
            for ix in range(self.n):
                var idx = iz * self.n + ix
                if self.h0_re[idx] == 0 and self.h0_im[idx] == 0:
                    continue
                var k = self._k(ix, iz)
                var a = k[0] * x0 + k[1] * z0 - self.omega(ix, iz) * t
                var c = cos(a)
                var s = sin(a)
                y += self.h0_re[idx] * c - self.h0_im[idx] * s
                var kl = sqrt(k[0] * k[0] + k[1] * k[1])
                var im = self.h0_re[idx] * s + self.h0_im[idx] * c
                dx -= self.choppy * k[0] / kl * im
                dz -= self.choppy * k[1] / kl * im
        return Vec3(x0 + dx, self.level + y, z0 + dz, 0)

    def normal(self, x: Real, z: Real, t: Real) -> Vec3:
        """Unit surface normal of the non-choppy surface at (x, z):
        (-d eta/dx, 1, -d eta/dz), slopes summed analytically."""
        var gx = Real(0)
        var gz = Real(0)
        for iz in range(self.n):
            for ix in range(self.n):
                var idx = iz * self.n + ix
                if self.h0_re[idx] == 0 and self.h0_im[idx] == 0:
                    continue
                var k = self._k(ix, iz)
                var a = k[0] * x + k[1] * z - self.omega(ix, iz) * t
                # d/dx Re(h0 e^{i a}) = -k_x Im(h0 e^{i a})
                var im = self.h0_re[idx] * sin(a) + self.h0_im[idx] * cos(a)
                gx -= k[0] * im
                gz -= k[1] * im
        var l = sqrt(gx * gx + 1 + gz * gz)
        return Vec3(-gx / l, 1 / l, -gz / l, 0)

    def height(self, x: Real, z: Real, t: Real) -> Real:
        if self.choppy != 0:
            # the inverse horizontal map, as GerstnerWater.height
            var x0 = x
            var z0 = z
            if self.has_grid and t == self.t_grid and len(self.disp_x) == self.n * self.n:
                for _ in range(4):
                    x0 -= x0 + self._bilinear(self.disp_x, x0, z0) - x
                    z0 -= z0 + self._bilinear(self.disp_z, x0, z0) - z
                return self.level + self._bilinear(self.grid, x0, z0)
            for _ in range(4):
                var p = self.displaced(x0, z0, t)
                x0 -= p[0] - x
                z0 -= p[2] - z
            return self.displaced(x0, z0, t)[1]
        if not self.has_grid or t != self.t_grid:
            return self.level + self.direct(x, z, t)
        var cell = self.size / Real(self.n)
        var fx = x / cell
        var fz = z / cell
        var x0 = Int(floor(fx))
        var z0 = Int(floor(fz))
        var ax = fx - Real(x0)
        var az = fz - Real(z0)
        var n = self.n
        var i0 = ((x0 % n) + n) % n
        var j0 = ((z0 % n) + n) % n
        var i1 = (i0 + 1) % n
        var j1 = (j0 + 1) % n
        var a = self.grid[j0 * n + i0] * (1 - ax) + self.grid[j0 * n + i1] * ax
        var b = self.grid[j1 * n + i0] * (1 - ax) + self.grid[j1 * n + i1] * ax
        return self.level + a * (1 - az) + b * az

    def velocity(self, x: Real, z: Real, t: Real) -> Vec3:
        var acc = Real(0)
        for iz in range(self.n):
            for ix in range(self.n):
                var idx = iz * self.n + ix
                if self.h0_re[idx] == 0 and self.h0_im[idx] == 0:
                    continue
                var k = self._k(ix, iz)
                var w = self.omega(ix, iz)
                var a = k[0] * x + k[1] * z - w * t
                # d/dt Re(h0 e^{i a}) with da/dt = -w
                acc += w * (self.h0_re[idx] * sin(a) + self.h0_im[idx] * cos(a))
        return Vec3(0, acc, 0, 0)


def _gauss(mut rng: SplitMix64) -> Real:
    """Standard normal by Box-Muller (one of the pair)."""
    var u1 = max(Real(rng.next_f32()), Real(1e-7))
    var u2 = Real(rng.next_f32())
    return sqrt(-2 * log(u1)) * cos(2 * Real(pi) * u2)


def _box_submerged_on[W: WaterSurface, B: Body6](body: B, half: Vec3, water: W, t: Real, samples: Int) -> Tuple[Real, Vec3]:
    """`fields.box_submerged_sampled` with the surface read at each cell."""
    var n = samples
    var cell_v = 8 * half[0] * half[1] * half[2] / Real(n * n * n)
    var e = _cell_half_height(body, half, n)
    var v = Real(0)
    var acc = Vec3(0, 0, 0, 0)
    for i in range(n):
        for j in range(n):
            for k in range(n):
                var lp = Vec3(
                    (Real(2 * i + 1) / Real(n) - 1) * half[0],
                    (Real(2 * j + 1) / Real(n) - 1) * half[1],
                    (Real(2 * k + 1) / Real(n) - 1) * half[2],
                    0,
                )
                var wp = body.act(lp)
                var part = _cell_below(wp, e, water.height(wp[0], wp[2], t), cell_v)
                if part[0] > 0:
                    v += part[0]
                    acc = acc + part[1] * part[0]
    if v <= 0:
        return (Real(0), body.position())
    return (v, acc * (1 / v))


def apply_buoyancy_surface[W: WaterSurface, B: Body6](
    mut sc: ContactScene6[B],
    waters: List[WaterVolume],
    water: W,
    t: Real,
    gravity: Vec3,
    dt: Real,
    samples: Int = 8,
) raises:
    """`fields.apply_buoyancy` with the level from a `WaterSurface` instead
    of each volume's flat top (17.60): the volumes keep their footprint,
    density and drag; a box's cells each compare with the surface where
    they are, a sphere uses the surface above its centre. With `FlatWater`
    at the volume's top it is `apply_buoyancy`, bit for bit (test_water_seam)."""
    for i in range(len(sc.bset.bodies)):
        if not sc.bset.is_dynamic(i):
            continue
        var kind = sc.colliders.shape[i]
        if kind != SHAPE_BOX and kind != SHAPE_SPHERE:
            continue
        var p = sc.bset.bodies[i].position()
        var half = sc.colliders.half[i]
        for w in range(len(waters)):
            ref wv = waters[w]
            if p[0] < wv.lo[0] or p[0] > wv.hi[0] or p[2] < wv.lo[2] or p[2] > wv.hi[2]:
                continue
            var sub: Tuple[Real, Vec3]
            var total: Real
            if kind == SHAPE_SPHERE:
                sub = sphere_submerged(p, half[0], water.height(p[0], p[2], t))
                total = 4 * _PI * half[0] * half[0] * half[0] / 3
            else:
                sub = _box_submerged_on(sc.bset.bodies[i], half, water, t, samples)
                total = 8 * half[0] * half[1] * half[2]
            if sub[0] <= 0:
                continue
            if sc.bset.sleeping[i]:
                sc.wake(sc.bset.id_of(i))
            var frac = sub[0] / total
            var fb = gravity * (-wv.density * sub[0])
            sc.bset.bodies[i].apply_impulse(fb * dt, sub[1])
            var v = sc.bset.bodies[i].linear_velocity()
            var om = sc.bset.bodies[i].omega_world()
            sc.bset.bodies[i].set_velocity(
                v * (1 / (1 + wv.lin_drag * frac * dt)),
                om * (1 / (1 + wv.ang_drag * frac * dt)),
            )


struct ShallowWaterFV(WaterSurface, Movable):
    """Nonlinear shallow water (Saint-Venant) on a flat bed, finite volume
    (17.60): cell depths h and discharges (hu, hv), first-order Rusanov
    (local Lax-Friedrichs) fluxes, reflective walls. Unlike
    `ShallowWaterGrid` (linear waves on a mean depth) it carries the flow
    velocity, moving bores and drying cells (h = 0 stays 0; velocities
    are taken as 0 below `dry`). A bed (`set_bed`) and Manning friction
    run in `_step_bed` (well balanced by hydrostatic reconstruction).
    `step(dt)` raises past the CFL limit
    dt (|u| + sqrt(g h)) / cell <= 1/2; `max_dt` is that bound. Mass is
    conserved to rounding (the fluxes cancel between cells; walls pass
    none). `height` is bed + h at the cell under (x, z); `velocity` the
    depth-averaged (u, 0, v) there."""

    var nx: Int
    var nz: Int
    var cell: Real
    var origin_x: Real
    var origin_z: Real
    var bed: Real
    var gravity: Real
    var dry: Real
    var h: List[Real]
    var hu: List[Real]
    var hv: List[Real]
    var zb: List[Real]  # per-cell bed height above `bed` (all 0: a flat bed)
    var manning: Real  # Manning n (s / m^(1/3)); 0 = no bed friction
    var well_balanced: Bool  # hydrostatic reconstruction (False: naive slope source)
    var has_bed: Bool

    def __init__(out self, nx: Int, nz: Int, cell: Real, origin_x: Real, origin_z: Real, bed: Real, gravity: Real = 9.8) raises:
        if nx < 1 or nz < 1 or not (cell > 0):
            raise Error("ShallowWaterFV: need >= 1 x 1 cells and cell > 0")
        self.nx = nx
        self.nz = nz
        self.cell = cell
        self.origin_x = origin_x
        self.origin_z = origin_z
        self.bed = bed
        self.gravity = gravity
        self.dry = 1e-6
        self.h = List[Real](length=nx * nz, fill=0)
        self.hu = List[Real](length=nx * nz, fill=0)
        self.hv = List[Real](length=nx * nz, fill=0)
        self.zb = List[Real](length=nx * nz, fill=0)
        self.manning = 0
        self.well_balanced = True
        self.has_bed = False

    def set_bed(mut self, i: Int, j: Int, z: Real):
        """Bed height of cell (i, j) above `bed`; switches `step` to the
        bed-aware update."""
        self.zb[j * self.nx + i] = z
        self.has_bed = True

    def _vel(self, k: Int) -> Tuple[Real, Real]:
        var h = self.h[k]
        if h <= self.dry:
            return (Real(0), Real(0))
        return (self.hu[k] / h, self.hv[k] / h)

    def max_dt(self) -> Real:
        var smax = Real(0)
        for k in range(self.nx * self.nz):
            var v = self._vel(k)
            var c = sqrt(self.gravity * max(self.h[k], Real(0)))
            smax = max(smax, max(abs(v[0]), abs(v[1])) + c)
        return 0.5 * self.cell / smax if smax > 0 else Real(1e30)

    def total_volume(self) -> Real:
        var s = Real(0)
        for k in range(self.nx * self.nz):
            s += self.h[k]
        return s * self.cell * self.cell

    def _flux(self, hl: Real, ql: Real, pl: Real, hr: Real, qr: Real, pr: Real) -> Tuple[Real, Real, Real]:
        """Rusanov flux normal to a face: q is the normal discharge, p the
        tangential one (h, q, p) per side."""
        var g = self.gravity
        var ul = ql / hl if hl > self.dry else Real(0)
        var ur = qr / hr if hr > self.dry else Real(0)
        var cl = sqrt(g * max(hl, Real(0)))
        var cr = sqrt(g * max(hr, Real(0)))
        var a = max(abs(ul) + cl, abs(ur) + cr)
        var f0 = 0.5 * (ql + qr) - 0.5 * a * (hr - hl)
        var f1 = 0.5 * (ql * ul + 0.5 * g * hl * hl + qr * ur + 0.5 * g * hr * hr) - 0.5 * a * (qr - ql)
        var f2 = 0.5 * (pl * ul + pr * ur) - 0.5 * a * (pr - pl)
        return (f0, f1, f2)

    def step(mut self, dt: Real) raises:
        if not (dt > 0) or dt > self.max_dt() * 1.000001:
            raise Error("ShallowWaterFV.step: dt must be in (0, max_dt()]")
        if self.has_bed or self.manning > 0:
            self._step_bed(dt)
            return
        var nx = self.nx
        var nz = self.nz
        var dh = List[Real](length=nx * nz, fill=0)
        var du = List[Real](length=nx * nz, fill=0)
        var dv = List[Real](length=nx * nz, fill=0)
        var r = dt / self.cell
        # x faces between (i, j) and (i + 1, j); walls mirror the normal discharge
        for j in range(nz):
            for i in range(-1, nx):
                var l = j * nx + i
                var rr = j * nx + i + 1
                var hl: Real
                var ql: Real
                var pl: Real
                var hr: Real
                var qr: Real
                var pr: Real
                if i < 0:
                    hr = self.h[rr]
                    qr = self.hu[rr]
                    pr = self.hv[rr]
                    hl = hr
                    ql = -qr
                    pl = pr
                elif i == nx - 1:
                    hl = self.h[l]
                    ql = self.hu[l]
                    pl = self.hv[l]
                    hr = hl
                    qr = -ql
                    pr = pl
                else:
                    hl = self.h[l]
                    ql = self.hu[l]
                    pl = self.hv[l]
                    hr = self.h[rr]
                    qr = self.hu[rr]
                    pr = self.hv[rr]
                var fl = self._flux(hl, ql, pl, hr, qr, pr)
                if i >= 0:
                    dh[l] -= r * fl[0]
                    du[l] -= r * fl[1]
                    dv[l] -= r * fl[2]
                if i < nx - 1:
                    dh[rr] += r * fl[0]
                    du[rr] += r * fl[1]
                    dv[rr] += r * fl[2]
        # z faces: normal discharge is hv, tangential hu
        for j in range(-1, nz):
            for i in range(nx):
                var l = j * nx + i
                var rr = (j + 1) * nx + i
                var hl: Real
                var ql: Real
                var pl: Real
                var hr: Real
                var qr: Real
                var pr: Real
                if j < 0:
                    hr = self.h[rr]
                    qr = self.hv[rr]
                    pr = self.hu[rr]
                    hl = hr
                    ql = -qr
                    pl = pr
                elif j == nz - 1:
                    hl = self.h[l]
                    ql = self.hv[l]
                    pl = self.hu[l]
                    hr = hl
                    qr = -ql
                    pr = pl
                else:
                    hl = self.h[l]
                    ql = self.hv[l]
                    pl = self.hu[l]
                    hr = self.h[rr]
                    qr = self.hv[rr]
                    pr = self.hu[rr]
                var fl = self._flux(hl, ql, pl, hr, qr, pr)
                if j >= 0:
                    dh[l] -= r * fl[0]
                    dv[l] -= r * fl[1]
                    du[l] -= r * fl[2]
                if j < nz - 1:
                    dh[rr] += r * fl[0]
                    dv[rr] += r * fl[1]
                    du[rr] += r * fl[2]
        for k in range(nx * nz):
            self.h[k] += dh[k]
            self.hu[k] += du[k]
            self.hv[k] += dv[k]
            if self.h[k] <= self.dry:
                self.hu[k] = 0
                self.hv[k] = 0
                if self.h[k] < 0:
                    self.h[k] = 0

    def _side(self, k: Int, normal_x: Bool, wall: Bool, mirror: Bool) -> Tuple[Real, Real, Real, Real]:
        """(h, normal discharge, tangential discharge, bed) of cell k, or of
        its mirror image across a wall."""
        var q = self.hu[k] if normal_x else self.hv[k]
        var p = self.hv[k] if normal_x else self.hu[k]
        if wall and mirror:
            q = -q
        return (self.h[k], q, p, self.zb[k])

    def _step_bed(mut self, dt: Real):
        """`step` over a bed (`zb`) and / or with Manning friction. Well
        balanced (Audusse et al. 2004): at each face the depths are
        reconstructed against the higher bed, h* = max(0, h + z - max(zl, zr)),
        the flux is taken from h*, and each side gets back g/2 (h^2 - h*^2)
        on its normal momentum -- so a lake at rest (h + z constant, no flow)
        stays at rest exactly. `well_balanced = False` uses the naive
        pointwise source -g h dz/dx instead (for comparison). Friction:
        q /= 1 + dt g n^2 |u| / h^(4/3), implicit."""
        var nx = self.nx
        var nz = self.nz
        var g = self.gravity
        var dh = List[Real](length=nx * nz, fill=0)
        var du = List[Real](length=nx * nz, fill=0)
        var dv = List[Real](length=nx * nz, fill=0)
        var r = dt / self.cell
        for axis in range(2):
            var ax = axis == 0
            var outer = nz if ax else nx
            var inner = nx if ax else nz
            for o in range(outer):
                for a in range(-1, inner):
                    var l = (o * nx + a) if ax else (a * nx + o)
                    var rr = (o * nx + a + 1) if ax else ((a + 1) * nx + o)
                    var L: Tuple[Real, Real, Real, Real]
                    var R: Tuple[Real, Real, Real, Real]
                    if a < 0:
                        R = self._side(rr, ax, False, False)
                        L = self._side(rr, ax, True, True)
                    elif a == inner - 1:
                        L = self._side(l, ax, False, False)
                        R = self._side(l, ax, True, True)
                    else:
                        L = self._side(l, ax, False, False)
                        R = self._side(rr, ax, False, False)
                    var hl = L[0]
                    var hr = R[0]
                    var fl: Tuple[Real, Real, Real]
                    var corr_l = Real(0)
                    var corr_r = Real(0)
                    if self.well_balanced:
                        var zf = max(L[3], R[3])
                        var hls = max(Real(0), hl + L[3] - zf)
                        var hrs = max(Real(0), hr + R[3] - zf)
                        var ul = L[1] / hl if hl > self.dry else Real(0)
                        var ur = R[1] / hr if hr > self.dry else Real(0)
                        var vl = L[2] / hl if hl > self.dry else Real(0)
                        var vr = R[2] / hr if hr > self.dry else Real(0)
                        fl = self._flux(hls, hls * ul, hls * vl, hrs, hrs * ur, hrs * vr)
                        corr_l = 0.5 * g * (hl * hl - hls * hls)
                        corr_r = 0.5 * g * (hr * hr - hrs * hrs)
                    else:
                        fl = self._flux(hl, L[1], L[2], hr, R[1], R[2])
                    var dn_l = -r * (fl[1] + corr_l)
                    var dn_r = r * (fl[1] + corr_r)
                    if a >= 0:
                        dh[l] -= r * fl[0]
                        if ax:
                            du[l] += dn_l
                            dv[l] -= r * fl[2]
                        else:
                            dv[l] += dn_l
                            du[l] -= r * fl[2]
                    if a < inner - 1:
                        dh[rr] += r * fl[0]
                        if ax:
                            du[rr] += dn_r
                            dv[rr] += r * fl[2]
                        else:
                            dv[rr] += dn_r
                            du[rr] += r * fl[2]
        if not self.well_balanced:
            # naive source -g h dz/dx, central differences (walls: one-sided 0)
            for j in range(nz):
                for i in range(nx):
                    var k = j * nx + i
                    var zxm = self.zb[k - 1] if i > 0 else self.zb[k]
                    var zxp = self.zb[k + 1] if i < nx - 1 else self.zb[k]
                    var zzm = self.zb[k - nx] if j > 0 else self.zb[k]
                    var zzp = self.zb[k + nx] if j < nz - 1 else self.zb[k]
                    du[k] -= dt * g * self.h[k] * (zxp - zxm) / (2 * self.cell)
                    dv[k] -= dt * g * self.h[k] * (zzp - zzm) / (2 * self.cell)
        for k in range(nx * nz):
            self.h[k] += dh[k]
            self.hu[k] += du[k]
            self.hv[k] += dv[k]
            if self.h[k] <= self.dry:
                self.hu[k] = 0
                self.hv[k] = 0
                if self.h[k] < 0:
                    self.h[k] = 0
            elif self.manning > 0:
                var v = self._vel(k)
                var sp = sqrt(v[0] * v[0] + v[1] * v[1])
                var hk = self.h[k]
                var d = 1 + dt * g * self.manning * self.manning * sp / (hk * Real(Float64(hk) ** (1.0 / 3.0)))
                self.hu[k] /= d
                self.hv[k] /= d

    def _cell_at(self, x: Real, z: Real) -> Int:
        var i = min(max(Int(floor((x - self.origin_x) / self.cell)), 0), self.nx - 1)
        var j = min(max(Int(floor((z - self.origin_z) / self.cell)), 0), self.nz - 1)
        return j * self.nx + i

    def height(self, x: Real, z: Real, t: Real) -> Real:
        var k = self._cell_at(x, z)
        return self.bed + self.zb[k] + self.h[k]

    def velocity(self, x: Real, z: Real, t: Real) -> Vec3:
        var v = self._vel(self._cell_at(x, z))
        return Vec3(v[0], 0, v[1], 0)
