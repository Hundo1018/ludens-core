"""Fluid and rigid bodies in one position-based solve (ROADMAP 17.59:
PBF two-way, Macklin et al. 2014 "Unified particle physics").

Rigid bodies are clusters of particles at the fluid's spacing. Per step:
predict every particle under gravity; then, per iteration, every fluid
particle's density constraint C_i = rho_i / rho0 - 1 (neighbours fluid
and solid alike, the PBF kernels of `physics.pbf`) gives a lambda_i, and
each particle k near i moves by w_k lambda_i grad_k C_i with w_k its
inverse mass relative to a fluid particle's (a body of density rho_b
has w = rho_fluid / rho_b: light bodies are pushed more, heavy ones
less -- the momentum the fluid gives is what the body takes); then every
cluster is shape-matched back to a rigid pose (centroid plus the polar
rotation of sum (p - c) q_rest^T, `fem.polar_rotation`); then the box
clamps everything. Velocities are the position change over dt.

The earlier attempt recorded under 17.59 pushed the fluid against fixed
body samples and handed the reaction back as an explicit force; a
density-300 box was thrown out of the tank. Here the body moves inside
the same projection, so its displacement is limited the same way the
fluid's is (`test_pbf_unified`: a light box rises and floats, a heavy one
sinks, nothing is thrown out). `add_walls` lines the floor and side walls
with static particles (inverse mass 0): without them the fluid packed
against the walls (0.4 m of water settled at 0.30 m). The draft still
sits about one particle layer deep (density 0.3 / 0.6 -> 0.59 / 0.84 of
the box height; slope 0.82 against the ideal 1).
"""

from std.math import sqrt
from geometry.vec import Real, Vec3
from geometry.mat import Mat3
from spatial.cell_sort import CellSort
from .pbf import H
from .fem import polar_rotation

comptime _MAX_CORR: Real = 0.2


def _poly6(r2: Real, h: Real) -> Real:
    var h2 = h * h
    if r2 >= h2 or r2 < 0:
        return 0
    var t = h2 - r2
    return 315.0 / (64.0 * 3.14159265 * (h ** 9)) * t * t * t


def _spiky_grad(r: Real, h: Real) -> Real:
    if r >= h or r <= 1e-9:
        return 0
    var t = h - r
    return -45.0 / (3.14159265 * (h ** 6)) * t * t


struct UnifiedPbf(Movable):
    var x: List[Vec3]  # positions (start of step)
    var p: List[Vec3]  # working positions
    var v: List[Vec3]
    var w: List[Real]  # inverse mass relative to a fluid particle
    var body: List[Int]  # -1 = fluid, -2 = wall particle, else rigid body index
    var rest: List[Vec3]  # per particle: rest offset from its body centroid (solids)
    var body_first: List[Int]
    var body_count: List[Int]
    var lo: Vec3
    var hi: Vec3
    var rho0: Real
    var h: Real  # kernel radius (default `pbf.H`; 2-3 particle spacings)
    var eps: Real  # constraint-force mixing, 1e-6 / h^2 (1e-4 at h = 0.1)
    var lam: List[Real]

    def __init__(out self, lo: Vec3, hi: Vec3, h: Real = H):
        self.x = List[Vec3]()
        self.p = List[Vec3]()
        self.v = List[Vec3]()
        self.w = List[Real]()
        self.body = List[Int]()
        self.rest = List[Vec3]()
        self.body_first = List[Int]()
        self.body_count = List[Int]()
        self.lo = lo
        self.hi = hi
        self.rho0 = 1
        self.h = h
        self.eps = Real(1e-6) / (h * h)
        self.lam = List[Real]()

    def calibrate(mut self, spacing: Real):
        """Rest density of a particle in a full lattice at `spacing`."""
        var reach = Int(self.h / spacing) + 1
        var rho = Real(0)
        for i in range(-reach, reach + 1):
            for j in range(-reach, reach + 1):
                for k in range(-reach, reach + 1):
                    var dx = Real(i) * spacing
                    var dy = Real(j) * spacing
                    var dz = Real(k) * spacing
                    rho += _poly6(dx * dx + dy * dy + dz * dz, self.h)
        self.rho0 = rho

    def count(self) -> Int:
        return len(self.x)

    def add_fluid(mut self, pos: Vec3):
        self.x.append(pos)
        self.p.append(pos)
        self.v.append(Vec3(0, 0, 0, 0))
        self.w.append(1)
        self.body.append(-1)
        self.rest.append(Vec3(0, 0, 0, 0))
        self.lam.append(0)

    def add_body(mut self, points: List[Vec3], density_ratio: Real) raises -> Int:
        """A rigid body made of `points` (fluid spacing); `density_ratio`
        = body density / fluid density."""
        if len(points) < 1 or not (density_ratio > 0):
            raise Error("UnifiedPbf.add_body: >= 1 point and a positive density ratio")
        var b = len(self.body_first)
        var c = Vec3(0, 0, 0, 0)
        for q in points:
            c = c + q
        c = c / Real(len(points))
        self.body_first.append(len(self.x))
        self.body_count.append(len(points))
        for q in points:
            self.x.append(q)
            self.p.append(q)
            self.v.append(Vec3(0, 0, 0, 0))
            self.w.append(1 / density_ratio)
            self.body.append(b)
            self.rest.append(q - c)
            self.lam.append(0)
        return b

    def add_walls(mut self, spacing: Real, layers: Int = 2, height: Real = -1):
        """Static boundary particles (inverse mass 0) in `layers` rows just
        outside the floor and the four side walls, up to `height` (default
        the box top): the fluid next to a wall then has the neighbours a
        full lattice would give it and stops packing against it."""
        var top = self.hi[1] if height < 0 else height
        var nx = Int((self.hi[0] - self.lo[0]) / spacing + 0.5)
        var nz = Int((self.hi[2] - self.lo[2]) / spacing + 0.5)
        var ny = Int((top - self.lo[1]) / spacing + 0.5)
        for l in range(layers):
            var o = (Real(l) + 0.5) * spacing
            # floor (extended under the side-wall rows)
            for k in range(-layers, nz + layers):
                for i in range(-layers, nx + layers):
                    self._add_static(Vec3(self.lo[0] + (Real(i) + 0.5) * spacing, self.lo[1] - o, self.lo[2] + (Real(k) + 0.5) * spacing, 0))
            for j in range(ny):
                var y = self.lo[1] + (Real(j) + 0.5) * spacing
                for k in range(-layers, nz + layers):
                    var z = self.lo[2] + (Real(k) + 0.5) * spacing
                    self._add_static(Vec3(self.lo[0] - o, y, z, 0))
                    self._add_static(Vec3(self.hi[0] + o, y, z, 0))
                for i in range(nx):
                    var x = self.lo[0] + (Real(i) + 0.5) * spacing
                    self._add_static(Vec3(x, y, self.lo[2] - o, 0))
                    self._add_static(Vec3(x, y, self.hi[2] + o, 0))

    def _add_static(mut self, q: Vec3):
        self.x.append(q)
        self.p.append(q)
        self.v.append(Vec3(0, 0, 0, 0))
        self.w.append(0)
        self.body.append(-2)
        self.rest.append(Vec3(0, 0, 0, 0))
        self.lam.append(0)

    def fluid_count(self) -> Int:
        var c = 0
        for b in self.body:
            if b == -1:
                c += 1
        return c

    def body_centroid(self, b: Int) -> Vec3:
        var c = Vec3(0, 0, 0, 0)
        for k in range(self.body_first[b], self.body_first[b] + self.body_count[b]):
            c = c + self.x[k]
        return c / Real(self.body_count[b])

    def body_velocity(self, b: Int) -> Vec3:
        var c = Vec3(0, 0, 0, 0)
        for k in range(self.body_first[b], self.body_first[b] + self.body_count[b]):
            c = c + self.v[k]
        return c / Real(self.body_count[b])

    def _clamp(mut self, k: Int):
        var q = self.p[k]
        self.p[k] = Vec3(
            min(max(q[0], self.lo[0]), self.hi[0]),
            min(max(q[1], self.lo[1]), self.hi[1]),
            min(max(q[2], self.lo[2]), self.hi[2]),
            0,
        )

    def _shape_match(mut self, b: Int):
        var f = self.body_first[b]
        var m = self.body_count[b]
        var c = Vec3(0, 0, 0, 0)
        for k in range(f, f + m):
            c = c + self.p[k]
        c = c / Real(m)
        if m < 3:
            for k in range(f, f + m):
                self.p[k] = c + self.rest[k]
            return
        var a = Mat3()
        for k in range(f, f + m):
            var d = self.p[k] - c
            var r = self.rest[k]
            for i in range(3):
                for j in range(3):
                    a.set(i, j, a.get(i, j) + d[i] * r[j])
        var rot = polar_rotation(a)
        for k in range(f, f + m):
            var r = self.rest[k]
            self.p[k] = c + Vec3(
                rot.get(0, 0) * r[0] + rot.get(0, 1) * r[1] + rot.get(0, 2) * r[2],
                rot.get(1, 0) * r[0] + rot.get(1, 1) * r[1] + rot.get(1, 2) * r[2],
                rot.get(2, 0) * r[0] + rot.get(2, 1) * r[1] + rot.get(2, 2) * r[2],
                0,
            )

    def _neighbours(self) -> List[List[Int]]:
        """Neighbours within h of every particle (cell hashing on h)."""
        var n = len(self.p)
        var gx = Int((self.hi[0] - self.lo[0]) / self.h) + 1
        var gy = Int((self.hi[1] - self.lo[1]) / self.h) + 1
        var gz = Int((self.hi[2] - self.lo[2]) / self.h) + 1
        var cell = List[Int](length=n, fill=0)
        for k in range(n):
            var q = self.p[k] - self.lo
            var a = min(max(Int(q[0] / self.h), 0), gx - 1)
            var b = min(max(Int(q[1] / self.h), 0), gy - 1)
            var c = min(max(Int(q[2] / self.h), 0), gz - 1)
            cell[k] = (c * gy + b) * gx + a
        var grid = CellSort()
        grid.build(cell, gx * gy * gz)
        var out = List[List[Int]]()
        var h2 = self.h * self.h
        for k in range(n):
            var nb = List[Int]()
            var ck = cell[k]
            var a0 = ck % gx
            var b0 = (ck // gx) % gy
            var c0 = ck // (gx * gy)
            for c in range(max(c0 - 1, 0), min(c0 + 2, gz)):
                for b in range(max(b0 - 1, 0), min(b0 + 2, gy)):
                    for a in range(max(a0 - 1, 0), min(a0 + 2, gx)):
                        var cc = (c * gy + b) * gx + a
                        for t in range(grid.start[cc], grid.start[cc + 1]):
                            var j = grid.items[t]
                            if j == k:
                                continue
                            var d = self.p[k] - self.p[j]
                            if d[0] * d[0] + d[1] * d[1] + d[2] * d[2] < h2:
                                nb.append(j)
            out.append(nb^)
        return out^

    def step(mut self, dt: Real, gravity: Vec3, iters: Int):
        var n = len(self.x)
        for k in range(n):
            if self.body[k] == -2:
                continue  # wall particle
            self.v[k] = self.v[k] + gravity * dt
            self.p[k] = self.x[k] + self.v[k] * dt
            self._clamp(k)
        for b in range(len(self.body_first)):
            self._shape_match(b)
        var nbs = self._neighbours()
        var corr = List[Vec3](length=n, fill=Vec3(0, 0, 0, 0))
        for _ in range(iters):
            # lambda per fluid particle, gradients weighted by inverse mass
            for i in range(n):
                if self.body[i] != -1:
                    self.lam[i] = 0
                    continue
                var rho = _poly6(0, self.h)
                var gi = Vec3(0, 0, 0, 0)
                var s2 = Real(0)
                for j in nbs[i]:
                    var d = self.p[i] - self.p[j]
                    var r = sqrt(d[0] * d[0] + d[1] * d[1] + d[2] * d[2])
                    rho += _poly6(r * r, self.h)
                    if r <= 1e-9:
                        continue
                    var g = d * (_spiky_grad(r, self.h) / (self.rho0 * r))
                    s2 += self.w[j] * (g[0] * g[0] + g[1] * g[1] + g[2] * g[2])
                    gi = gi - g
                s2 += self.w[i] * (gi[0] * gi[0] + gi[1] * gi[1] + gi[2] * gi[2])
                var c = rho / self.rho0 - 1
                self.lam[i] = -max(c, 0) / (s2 + self.eps)
            for k in range(n):
                corr[k] = Vec3(0, 0, 0, 0)
            for i in range(n):
                if self.body[i] != -1:
                    continue
                for j in nbs[i]:
                    var d = self.p[i] - self.p[j]
                    var r = sqrt(d[0] * d[0] + d[1] * d[1] + d[2] * d[2])
                    if r <= 1e-9:
                        continue
                    var g = d * (_spiky_grad(r, self.h) / (self.rho0 * r))
                    if self.body[j] == -1:
                        # fluid pair: PBF's symmetric (lambda_i + lambda_j) form
                        corr[i] = corr[i] + g * ((self.lam[i] + self.lam[j]) * self.w[i])
                    else:
                        # fluid i - solid j: i's constraint moves both
                        corr[i] = corr[i] + g * (self.lam[i] * self.w[i])
                        corr[j] = corr[j] - g * (self.lam[i] * self.w[j])
            for k in range(n):
                if self.body[k] == -2:
                    continue
                var c = corr[k]
                var l = sqrt(c[0] * c[0] + c[1] * c[1] + c[2] * c[2])
                if l > _MAX_CORR * self.h:
                    c = c * (_MAX_CORR * self.h / l)
                self.p[k] = self.p[k] + c
                self._clamp(k)
            for b in range(len(self.body_first)):
                self._shape_match(b)
        for k in range(n):
            if self.body[k] == -2:
                continue
            self.v[k] = (self.p[k] - self.x[k]) / dt
            self.x[k] = self.p[k]
