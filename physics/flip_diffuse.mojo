"""Spray, foam and bubbles for the FLIP water (ROADMAP 17.60; after Ihmsen
et al. 2012, "Unified spray, foam and air bubbles for particle-based
fluids"), one way: the water does not feel them.

After each water step, `DiffuseParticles.update(w, dt)`:

  1. per water particle i, from its neighbours j within h = 2 dx
     (W = 1 - r / h): the trapped-air potential
       I_ta = sum_j |v_ij| (1 - v^_ij . x^_ij) W,
     the wave-crest potential I_wc = curvature * [moving outward], with the
     outward normal n_i = normalised sum_j x_ij W, curvature
     sum_j (1 - n_i . n_j) W over surface particles (fewer than
     `surface_count` neighbours) whose velocity points along n_i, and the
     kinetic energy E = v^2 / 2; each potential clamped to [0, 1] between
     its two thresholds;
  2. spawns floor(E~ (k_ta I_ta~ + k_wc I_wc~) dt + xi) diffuse particles
     (xi uniform from the seeded `SplitMix64`: same seed, same particles)
     in a disc of radius dx/2 around x_i with the water particle's
     velocity;
  3. classifies each diffuse particle by the water particles within h:
     fewer than 2 = spray (ballistic: gravity only), more than 6 = bubble
     (buoyancy `k_b` g up, drag `k_d` toward the water velocity), else
     foam (carried at the water velocity, ages by dt, removed after
     `lifetime`); particles leaving the box are removed.

Still water spawns nothing (no relative velocity, no outward motion);
`test_flip_diffuse` measures a dam break.
"""

from std.math import sqrt, floor, pi
from geometry.trig import cos, sin
from geometry.vec import Real
from scheduler.rng import SplitMix64
from .flip import FlipWater2

comptime SPRAY = 0
comptime FOAM = 1
comptime BUBBLE = 2


struct DiffuseParticles(Movable):
    var x: List[Real]
    var y: List[Real]
    var u: List[Real]
    var v: List[Real]
    var age: List[Real]
    var kind: List[Int]
    var rng: SplitMix64
    var k_ta: Real
    var k_wc: Real
    var ta_min: Real
    var ta_max: Real
    var wc_min: Real
    var wc_max: Real
    var e_min: Real
    var e_max: Real
    var surface_count: Int
    var lifetime: Real
    var k_b: Real
    var k_d: Real
    var spawned: Int  # total spawned so far
    var max_particles: Int

    def __init__(out self, seed: UInt64, max_particles: Int = 100000):
        self.x = List[Real]()
        self.y = List[Real]()
        self.u = List[Real]()
        self.v = List[Real]()
        self.age = List[Real]()
        self.kind = List[Int]()
        self.rng = SplitMix64.seeded(seed)
        self.k_ta = 40
        self.k_wc = 40
        self.ta_min = 0.5
        self.ta_max = 5
        self.wc_min = 0.5
        self.wc_max = 2
        self.e_min = 0.5
        self.e_max = 5
        self.surface_count = 12
        self.lifetime = 2
        self.k_b = 0.8
        self.k_d = 0.5
        self.spawned = 0
        self.max_particles = max_particles

    def count(self) -> Int:
        return len(self.x)

    def count_kind(self, k: Int) -> Int:
        var c = 0
        for q in self.kind:
            if q == k:
                c += 1
        return c

    @staticmethod
    def _clamp01(i: Real, lo: Real, hi: Real) -> Real:
        return (min(i, hi) - min(i, lo)) / (hi - lo)

    def update(mut self, w: FlipWater2, dt: Real):
        var n = w.count()
        var h = 2 * w.dx
        var h2 = h * h
        # water particles binned on cells of h
        var gx = Int(Real(w.nx) * w.dx / h) + 1
        var gy = Int(Real(w.ny) * w.dx / h) + 1
        var cnt = List[Int](length=gx * gy + 1, fill=0)
        var cid = List[Int](length=n, fill=0)
        for k in range(n):
            var a = min(max(Int(w.px[k] / h), 0), gx - 1)
            var b = min(max(Int(w.py[k] / h), 0), gy - 1)
            cid[k] = b * gx + a
            cnt[cid[k] + 1] += 1
        for c in range(gx * gy):
            cnt[c + 1] += cnt[c]
        var fill = cnt.copy()
        var order = List[Int](length=n, fill=0)
        for k in range(n):
            order[fill[cid[k]]] = k
            fill[cid[k]] += 1
        # normals and neighbour counts
        var nxs = List[Real](length=n, fill=0)
        var nys = List[Real](length=n, fill=0)
        var nbs = List[Int](length=n, fill=0)
        for i in range(n):
            var a0 = cid[i] % gx
            var b0 = cid[i] // gx
            var sx = Real(0)
            var sy = Real(0)
            var c = 0
            for b in range(max(b0 - 1, 0), min(b0 + 2, gy)):
                for a in range(max(a0 - 1, 0), min(a0 + 2, gx)):
                    var q0 = b * gx + a
                    for q in range(cnt[q0], cnt[q0 + 1]):
                        var j = order[q]
                        if j == i:
                            continue
                        var dx = w.px[i] - w.px[j]
                        var dy = w.py[i] - w.py[j]
                        var r2 = dx * dx + dy * dy
                        if r2 < h2:
                            var wt = 1 - sqrt(r2) / h
                            sx += dx * wt
                            sy += dy * wt
                            c += 1
            var l = sqrt(sx * sx + sy * sy)
            nxs[i] = sx / l if l > 0 else Real(0)
            nys[i] = sy / l if l > 0 else Real(0)
            nbs[i] = c
        # potentials and spawning
        for i in range(n):
            var a0 = cid[i] % gx
            var b0 = cid[i] // gx
            var ta = Real(0)
            var curv = Real(0)
            for b in range(max(b0 - 1, 0), min(b0 + 2, gy)):
                for a in range(max(a0 - 1, 0), min(a0 + 2, gx)):
                    var q0 = b * gx + a
                    for q in range(cnt[q0], cnt[q0 + 1]):
                        var j = order[q]
                        if j == i:
                            continue
                        var dx = w.px[i] - w.px[j]
                        var dy = w.py[i] - w.py[j]
                        var r2 = dx * dx + dy * dy
                        if r2 >= h2 or r2 <= 0:
                            continue
                        var r = sqrt(r2)
                        var wt = 1 - r / h
                        var du = w.pu[i] - w.pu[j]
                        var dv = w.pv[i] - w.pv[j]
                        var vl = sqrt(du * du + dv * dv)
                        if vl > 0:
                            ta += vl * (1 - (du * dx + dv * dy) / (vl * r)) * wt
                        curv += (1 - (nxs[i] * nxs[j] + nys[i] * nys[j])) * wt
            var sp = sqrt(w.pu[i] * w.pu[i] + w.pv[i] * w.pv[i])
            var wc = Real(0)
            if nbs[i] < self.surface_count and sp > 0 and (w.pu[i] * nxs[i] + w.pv[i] * nys[i]) / sp > 0.6:
                wc = curv
            var ek = 0.5 * sp * sp
            var rate = DiffuseParticles._clamp01(ek, self.e_min, self.e_max) * (
                self.k_ta * DiffuseParticles._clamp01(ta, self.ta_min, self.ta_max)
                + self.k_wc * DiffuseParticles._clamp01(wc, self.wc_min, self.wc_max)
            ) * dt
            if rate <= 0:
                continue
            var nd = Int(floor(rate + Real(self.rng.next_f32())))
            for _ in range(nd):
                if len(self.x) >= self.max_particles:
                    break
                var ang = 2 * Real(pi) * Real(self.rng.next_f32())
                var rad = 0.5 * w.dx * sqrt(Real(self.rng.next_f32()))
                self.x.append(w.px[i] + rad * cos(ang))
                self.y.append(w.py[i] + rad * sin(ang))
                self.u.append(w.pu[i])
                self.v.append(w.pv[i])
                self.age.append(0)
                self.kind.append(SPRAY)
                self.spawned += 1
        # classify and move
        var keep = List[Bool](length=len(self.x), fill=True)
        var top_x = Real(w.nx) * w.dx
        var top_y = Real(w.ny) * w.dx
        for d in range(len(self.x)):
            var a0 = min(max(Int(self.x[d] / h), 0), gx - 1)
            var b0 = min(max(Int(self.y[d] / h), 0), gy - 1)
            var c = 0
            for b in range(max(b0 - 1, 0), min(b0 + 2, gy)):
                for a in range(max(a0 - 1, 0), min(a0 + 2, gx)):
                    var q0 = b * gx + a
                    for q in range(cnt[q0], cnt[q0 + 1]):
                        var j = order[q]
                        var dx = self.x[d] - w.px[j]
                        var dy = self.y[d] - w.py[j]
                        if dx * dx + dy * dy < h2:
                            c += 1
            if c < 2:
                self.kind[d] = SPRAY
                self.v[d] -= w.gravity * dt
            elif c > 6:
                self.kind[d] = BUBBLE
                var fv = w.velocity(self.x[d], self.y[d])
                self.u[d] += self.k_d * (fv[0] - self.u[d])
                self.v[d] += self.k_b * w.gravity * dt + self.k_d * (fv[1] - self.v[d])
            else:
                self.kind[d] = FOAM
                var fv = w.velocity(self.x[d], self.y[d])
                self.u[d] = fv[0]
                self.v[d] = fv[1]
                self.age[d] += dt
                if self.age[d] > self.lifetime:
                    keep[d] = False
            self.x[d] += self.u[d] * dt
            self.y[d] += self.v[d] * dt
            if self.x[d] < 0 or self.x[d] > top_x or self.y[d] < 0 or self.y[d] > top_y:
                keep[d] = False
        var m = 0
        for d in range(len(self.x)):
            if keep[d]:
                self.x[m] = self.x[d]
                self.y[m] = self.y[d]
                self.u[m] = self.u[d]
                self.v[m] = self.v[d]
                self.age[m] = self.age[d]
                self.kind[m] = self.kind[d]
                m += 1
        self.x.resize(m, 0)
        self.y.resize(m, 0)
        self.u.resize(m, 0)
        self.v.resize(m, 0)
        self.age.resize(m, 0)
        self.kind.resize(m, 0)
