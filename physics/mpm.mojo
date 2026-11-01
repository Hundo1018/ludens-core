"""MLS-MPM — the hybrid particle/grid solver, for materials the others cannot do.

FEM discretises a fixed mesh, so it models a solid that keeps its connectivity.
PBF and SPH are purely particle-based, so they model a fluid with no memory of
its rest shape. MPM sits between them: particles carry the material state
(deformation gradient, volume), a BACKGROUND GRID is used once per step to
resolve the coupling, and the grid is thrown away afterwards. Because the mesh
is transient, the material can undergo arbitrary topology change — flow, pile
up, tear, merge — while still remembering elastic strain, which is what makes
this the method for snow, mud and plastic flow.

MLS-MPM (Hu et al. 2018) is used rather than classic MPM because it folds the
affine velocity field (APIC) and the stress term into one quadratic B-spline
scatter, which removes the separate force pass entirely.

Per step:
  P2G  scatter mass, affine momentum and stress onto a 3x3x3 grid stencil
  grid normalise momentum, apply gravity, enforce boundaries
  G2P  gather velocity and the affine matrix C, advect, update F

Plasticity is a determinant clamp on F: elastic strain beyond a yield range is
forgotten rather than stored, which is exactly what makes a material FLOW
instead of springing back. `test_mpm` asserts both regimes — elastic recoil
with the clamp wide, and permanent deformation with it tight — since a solver
that never yields would pass any test written only for the elastic case.

Sand, obstacles and moving rigid obstacles (`MpmRigid`, coupled to a
`ContactScene6` by `physics.mpm_rigid`) run in `step_ext` (`step` ignores
them; see there why).
Sand (ROADMAP 17.58, `set_sand(friction_deg)`; measured, not a validated
material: heaps of a collapsed block have an equal-volume cone angle of
20 / 25 / 29 / 32 degrees for 20 / 30 / 40 / 50 degrees of friction, see
`experiments/exp_sand_repose.mojo`): Drucker-Prager plasticity by
the return mapping of Klar et al. 2016 on the singular values of F (SVD from
the polar decomposition and a symmetric eigen solve), in log-strain space:
a stretched particle forgets all elastic strain (sand has no tension), a
compressed one is projected back onto the friction cone. It replaces the
determinant clamp. Static obstacles (`add_obstacle(sdf, mu)`): a grid node
within `node_margin` (3 dx / 4) of an `Sdf3`, or inside it, loses the velocity
into it, with Coulomb friction on the rest (sticks when the tangential speed
is within mu times the normal one), and a particle closer than `skin`
(dx / 4) to the surface is put back at that distance with the same friction
on the velocity removed. Both are needed so that contact does not depend on
where the surface falls between grid nodes (`test_mpm_contact`). The domain
walls only remove the velocity into them (frictionless), so sand needs an
obstacle as its floor to pile instead of spreading.
"""

from std.math import sqrt, log, exp
from geometry.trig import sin
from geometry.vec import Real, Vec3, dot, length
from geometry.mat import Mat3
from geometry.mat3 import Mat3x3, sym_eigen3
from geometry.sdf3 import Sdf3
from geometry.quat import Quat
from physics.fem import polar_rotation, det3


def _cross3(a: Vec3, b: Vec3) -> Vec3:
    return Vec3(a[1] * b[2] - a[2] * b[1], a[2] * b[0] - a[0] * b[2], a[0] * b[1] - a[1] * b[0], 0)


@fieldwise_init
struct MpmRigid(Copyable, ImplicitlyCopyable, Movable):
    """A moving rigid obstacle for `step_ext` (17.59): `shape` in its own
    frame, posed by `pos` / `rot`, moving with `v` / `w`. Grid nodes inside
    it get its velocity in the normal direction (Coulomb `mu` on the
    tangential slip); what that changes in the nodes' momentum, and what
    the particle push-out takes, is summed into `force` / `torque` (about
    `pos`) for the body: the exchange conserves momentum."""

    var shape: Sdf3
    var pos: Vec3
    var rot: Quat
    var v: Vec3
    var w: Vec3
    var mu: Real
    var force: Vec3
    var torque: Vec3


@fieldwise_init
struct MpmParticle(Copyable, ImplicitlyCopyable, Movable):
    var x: Vec3
    var v: Vec3
    var f: Mat3  # deformation gradient
    var c: Mat3  # affine velocity field (APIC)
    var vol: Real
    var mass: Real
    var shear: Real  # scales the shear modulus in step_ext (1 = full; 17.61 mushy particles: 1 - phi)


struct MpmSolver(Movable):
    var p: List[MpmParticle]
    var lo: Vec3
    var dx: Real
    var n: Int  # grid resolution per axis
    var mu: Real
    var lam: Real
    # plastic yield range on det(F); (1,1) = purely elastic
    var j_min: Real
    var j_max: Real
    var dp_alpha: Real  # Drucker-Prager cone (0 = off)
    var obstacles: List[Sdf3]
    var obstacle_mu: List[Real]
    var skin: Real  # particles keep this far from an obstacle surface (dx / 4)
    var node_margin: Real  # grid nodes this close to a surface (or inside) are projected (dx * 3 / 4)
    var rigids: List[MpmRigid]  # moving rigid obstacles (step_ext)
    # grid scratch (SoA, rebuilt each step)
    var gm: List[Real]
    var gvx: List[Real]
    var gvy: List[Real]
    var gvz: List[Real]
    # opt-in sand accounting (off by default): energy the return map removes,
    # sum over particles of vol * (psi(F before) - psi(F after)), psi the
    # corotated energy of elastic_energy
    var measure_loss: Bool
    var sand_loss: Real
    # Tampubolon volume correction (opt-in, default off): per-particle vc
    var volume_correction: Bool
    var sand_vc: List[Real]

    def __init__(out self, lo: Vec3, dx: Real, n: Int, young: Real, poisson: Real):
        self.p = List[MpmParticle]()
        self.lo = lo
        self.dx = dx
        self.n = n
        self.mu = young / (2 * (1 + poisson))
        self.lam = young * poisson / ((1 + poisson) * (1 - 2 * poisson))
        self.j_min = 1.0
        self.j_max = 1.0
        self.dp_alpha = 0
        self.obstacles = List[Sdf3]()
        self.obstacle_mu = List[Real]()
        self.skin = dx * 0.25
        self.node_margin = dx * 0.75
        self.rigids = List[MpmRigid]()
        self.gm = List[Real]()
        self.gvx = List[Real]()
        self.gvy = List[Real]()
        self.gvz = List[Real]()
        self.measure_loss = False
        self.sand_loss = 0
        self.volume_correction = False
        self.sand_vc = List[Real]()
        var cells = n * n * n
        for _ in range(cells):
            self.gm.append(0)
            self.gvx.append(0)
            self.gvy.append(0)
            self.gvz.append(0)

    def count(self) -> Int:
        return len(self.p)

    def add(mut self, pos: Vec3, mass: Real, vol: Real):
        self.p.append(
            MpmParticle(pos, Vec3(0, 0, 0, 0), Mat3.identity(), Mat3(), vol, mass, 1)
        )
        self.sand_vc.append(0)

    def set_plastic(mut self, j_min: Real, j_max: Real):
        self.j_min = j_min
        self.j_max = j_max

    def set_sand(mut self, friction_deg: Real) raises:
        """Drucker-Prager sand with friction angle `friction_deg` (module
        note); raises outside (0, 90)."""
        if not (friction_deg > 0 and friction_deg < 90):
            raise Error("MpmSolver.set_sand: friction angle must be in (0, 90) degrees")
        var sp = sin(friction_deg * 0.017453292519943295)
        self.dp_alpha = Real(0.816496580927726) * 2 * sp / (3 - sp)
        self.j_min = 1.0  # the return mapping replaces the determinant clamp
        self.j_max = 1.0

    def add_obstacle(mut self, sdf: Sdf3, mu: Real) raises:
        if not (mu >= 0):
            raise Error("MpmSolver.add_obstacle: mu must be >= 0")
        self.obstacles.append(sdf)
        self.obstacle_mu.append(mu)

    def elastic_energy(self, f: Mat3) -> Real:
        """Fixed-corotated elastic energy of F, the one whose stress step_ext
        scatters: mu * sum((sigma_i - 1)^2) + lam / 2 * (J - 1)^2, sigma_i the
        singular values of F and J = det F."""
        var c = f.transpose() * f
        var cs = Mat3x3()
        for a in range(3):
            for b in range(3):
                cs.set(a, b, c.get(a, b))
        var ev = sym_eigen3(cs)
        var e0 = Real(0)
        for k in range(3):
            var d = sqrt(max(ev[0][k], Real(0))) - 1
            e0 += d * d
        var j = det3(f) - 1
        return self.mu * e0 + 0.5 * self.lam * j * j

    def _sand(self, f: Mat3, vc: Real) -> Tuple[Mat3, Real]:
        """Drucker-Prager return mapping of F (Klar et al. 2016). With
        `volume_correction`, the volume term vc (Tampubolon et al. 2017, eq. 26
        and 27) joins the trial strain, so a particle that expanded and was
        projected to the tip can compress again. Returns F and the new vc."""
        var r = polar_rotation(f)
        var sm = r.transpose() * f
        var s3 = Mat3x3()
        for a in range(3):
            for b in range(3):
                s3.set(a, b, (sm.get(a, b) + sm.get(b, a)) * 0.5)
        var ev = sym_eigen3(s3)
        var sig = ev[0]
        var eps = Vec3(log(max(sig[0], Real(1e-6))), log(max(sig[1], Real(1e-6))), log(max(sig[2], Real(1e-6))), 0)
        var shift = vc / 3 if self.volume_correction else Real(0)
        eps = eps + Vec3(shift, shift, shift, 0)
        var tr = eps[0] + eps[1] + eps[2]
        var newsig: Vec3
        if tr >= 0:
            newsig = Vec3(1, 1, 1, 0)  # no tension: forget the strain
        else:
            var dev = eps - Vec3(tr / 3, tr / 3, tr / 3, 0)
            var dn = length(dev)
            var dgamma = dn + (3 * self.lam + 2 * self.mu) / (2 * self.mu) * tr * self.dp_alpha
            if dgamma <= 0 or dn < 1e-12:
                return (f, vc)
            var h = eps - dev * (dgamma / dn)
            newsig = Vec3(exp(h[0]), exp(h[1]), exp(h[2]), 0)
        # eq. 26: vc gains the log-volume the projection removed from the trial
        var new_vc = Real(0)
        if self.volume_correction:
            var logj_out = log(newsig[0]) + log(newsig[1]) + log(newsig[2])
            new_vc = vc + logj_out - tr
        # F = U diag(sigma) V^T with U = R V
        var v = ev[1]
        var out = Mat3()
        for a in range(3):
            for b in range(3):
                var acc = Real(0)
                for k in range(3):
                    acc += v.get(a, k) * newsig[k] * v.get(b, k)
                out.set(a, b, acc)
        return (r * out, new_vc)

    def _obstacle(mut self, i: Int, j: Int, k: Int, idx: Int):
        """Separate a grid node's velocity from every obstacle it is inside or
        on the surface of (distance <= 0: with the surface on a node plane,
        the nodes carrying a resting body's weight sit at distance 0, and
        skipping them left the floor friction at 0.49 m of sliding instead of
        0.34)."""
        var x = self.lo + Vec3(Real(i), Real(j), Real(k), 0) * self.dx
        for o in range(len(self.obstacles)):
            if self.obstacles[o].distance(x) > self.node_margin:
                continue
            var g = self.obstacles[o].gradient(x)
            var gl = length(g)
            if not (gl > 0):
                continue
            var n = g / gl
            var v = Vec3(self.gvx[idx], self.gvy[idx], self.gvz[idx], 0)
            var vn = dot(v, n)
            if vn >= 0:
                continue
            var vt = v - n * vn
            var tl = length(vt)
            var mu = self.obstacle_mu[o]
            if tl <= -mu * vn:
                v = Vec3(0, 0, 0, 0)
            else:
                v = vt * (1 + mu * vn / tl)
            self.gvx[idx] = v[0]
            self.gvy[idx] = v[1]
            self.gvz[idx] = v[2]

    def _rigid_node(mut self, i: Int, j: Int, k: Int, idx: Int, dt: Real):
        """Separate a grid node's velocity from every moving rigid it is
        inside, relative to the body's velocity there; the node's momentum
        change goes to the body (`MpmRigid`)."""
        var x = self.lo + Vec3(Real(i), Real(j), Real(k), 0) * self.dx
        for o in range(len(self.rigids)):
            ref r = self.rigids[o]
            var lp = r.rot.conjugate().rotate(x - r.pos)
            if r.shape.distance(lp) >= 0:
                continue
            var g = r.shape.gradient(lp)
            var gl = length(g)
            if not (gl > 0):
                continue
            var n = r.rot.rotate(g / gl)
            var vb = r.v + _cross3(r.w, x - r.pos)
            var v0 = Vec3(self.gvx[idx], self.gvy[idx], self.gvz[idx], 0)
            var vr = v0 - vb
            var vn = dot(vr, n)
            if vn >= 0:
                continue
            var vt = vr - n * vn
            var tl = length(vt)
            if tl <= -r.mu * vn:
                vr = Vec3(0, 0, 0, 0)
            else:
                vr = vt * (1 + r.mu * vn / tl)
            var v1 = vb + vr
            var fb = (v0 - v1) * (self.gm[idx] / dt)
            r.force = r.force + fb
            r.torque = r.torque + _cross3(x - r.pos, fb)
            self.gvx[idx] = v1[0]
            self.gvy[idx] = v1[1]
            self.gvz[idx] = v1[2]

    def _rigid_push_out(mut self, pi: Int, dt: Real):
        """A particle inside a moving rigid goes to its surface and loses
        its inward velocity relative to the body; the momentum goes to the
        body."""
        for o in range(len(self.rigids)):
            ref r = self.rigids[o]
            var x = self.p[pi].x
            var lp = r.rot.conjugate().rotate(x - r.pos)
            var d = r.shape.distance(lp)
            if d >= 0:
                continue
            var g = r.shape.gradient(lp)
            var gl = length(g)
            if not (gl > 0):
                continue
            var n = r.rot.rotate(g / gl)
            var xs = x - n * d
            self.p[pi].x = xs
            var vb = r.v + _cross3(r.w, xs - r.pos)
            var vn = dot(self.p[pi].v - vb, n)
            if vn < 0:
                var dv = n * (-vn)
                self.p[pi].v = self.p[pi].v + dv
                var fb = dv * (-self.p[pi].mass / dt)
                r.force = r.force + fb
                r.torque = r.torque + _cross3(xs - r.pos, fb)

    def _push_out(mut self, pi: Int):
        """Keep a particle `skin` outside every obstacle: move it back to that
        distance and drop its inward velocity, with Coulomb friction on the
        removed normal velocity. The grid projection alone is not enough: it
        only sees nodes inside the obstacle, so a floor whose surface falls
        between two node planes left the particles' own nodes free and the
        floor frictionless (measured: sand on a floor 1 cm below a node plane
        spread to a 2 degree film; 80 of 288 sand particles also ended more
        than half a cell inside a box)."""
        for o in range(len(self.obstacles)):
            var x = self.p[pi].x
            var d = self.obstacles[o].distance(x)
            if d >= self.skin:
                continue
            var g = self.obstacles[o].gradient(x)
            var gl = length(g)
            if not (gl > 0):
                continue
            var n = g / gl
            self.p[pi].x = x - n * (d - self.skin)
            var vn = dot(self.p[pi].v, n)
            if vn < 0:
                var vt = self.p[pi].v - n * vn
                var tl = length(vt)
                var mu = self.obstacle_mu[o]
                if tl <= -mu * vn:
                    self.p[pi].v = Vec3(0, 0, 0, 0)
                else:
                    self.p[pi].v = vt * (1 + mu * vn / tl)

    def _gi(self, i: Int, j: Int, k: Int) -> Int:
        return (k * self.n + j) * self.n + i

    def total_mass(self) -> Real:
        var m = Real(0)
        for ref q in self.p:
            m += q.mass
        return m

    def total_momentum(self) -> Vec3:
        var s = Vec3(0, 0, 0, 0)
        for ref q in self.p:
            s = s + q.v * q.mass
        return s

    def step(mut self, dt: Real, gravity: Vec3):
        # Obstacle friction is applied only by `step_ext` (`_push_out`); this path
        # would let obstacles pass friction-free (17.58, tests/test_mpm_domain.mojo).
        debug_assert(len(self.obstacles) == 0, "MpmSolver.step ignores obstacles; use step_ext")
        var cells = self.n * self.n * self.n
        for c in range(cells):
            self.gm[c] = 0
            self.gvx[c] = 0
            self.gvy[c] = 0
            self.gvz[c] = 0

        var inv_dx = 1.0 / self.dx

        # ---- P2G ----
        for pi in range(len(self.p)):
            var q = self.p[pi]
            var gx = (q.x[0] - self.lo[0]) * inv_dx
            var gy = (q.x[1] - self.lo[1]) * inv_dx
            var gz = (q.x[2] - self.lo[2]) * inv_dx
            var bx = Int(gx - 0.5)
            var by = Int(gy - 0.5)
            var bz = Int(gz - 0.5)
            if bx < 0 or by < 0 or bz < 0:
                continue
            if bx + 2 >= self.n or by + 2 >= self.n or bz + 2 >= self.n:
                continue
            var fx = gx - Real(bx)
            var fy = gy - Real(by)
            var fz = gz - Real(bz)
            # quadratic B-spline weights over the 3-cell stencil
            var wx = Array[Real, 3](fill=0)
            var wy = Array[Real, 3](fill=0)
            var wz = Array[Real, 3](fill=0)
            wx[0] = 0.5 * (1.5 - fx) * (1.5 - fx)
            wx[1] = 0.75 - (fx - 1.0) * (fx - 1.0)
            wx[2] = 0.5 * (fx - 0.5) * (fx - 0.5)
            wy[0] = 0.5 * (1.5 - fy) * (1.5 - fy)
            wy[1] = 0.75 - (fy - 1.0) * (fy - 1.0)
            wy[2] = 0.5 * (fy - 0.5) * (fy - 0.5)
            wz[0] = 0.5 * (1.5 - fz) * (1.5 - fz)
            wz[1] = 0.75 - (fz - 1.0) * (fz - 1.0)
            wz[2] = 0.5 * (fz - 0.5) * (fz - 0.5)

            # fixed-corotated stress: P = 2 mu (F - R) + lambda (J - 1) J F^-T,
            # folded into the MLS affine term
            var r = polar_rotation(q.f)
            var jdet = det3(q.f)
            var stress = Mat3()
            for a in range(3):
                for b in range(3):
                    stress.set(a, b, 2 * self.mu * (q.f.get(a, b) - r.get(a, b)))
            # volumetric part: P_vol F^T = lambda (J-1) J F^-T F^T = lambda (J-1) J I,
            # so it joins the Kirchhoff stress P F^T after the product, not P
            # before it (before it, F^T would rotate the pressure)
            var volterm = self.lam * (jdet - 1.0) * jdet
            var ft = q.f.transpose()
            var pft = stress * ft  # P F^T, the Cauchy-like term MLS scatters
            for a in range(3):
                pft.set(a, a, pft.get(a, a) + volterm)
            var scale = -dt * q.vol * 4.0 * inv_dx * inv_dx
            var affine = Mat3()
            for a in range(3):
                for b in range(3):
                    affine.set(
                        a, b, scale * pft.get(a, b) + q.mass * q.c.get(a, b)
                    )

            for i in range(3):
                for j in range(3):
                    for k in range(3):
                        var w = wx[i] * wy[j] * wz[k]
                        # offset from the particle to grid node (b+i):
                        # (i - fx) * dx, with fx in [0.5, 1.5] from the
                        # base = int(g - 0.5) convention. An extra +1 here
                        # shifts every stencil weight onto the wrong node and
                        # the solver explodes in free fall.
                        var dpx = (Real(i) - fx) * self.dx
                        var dpy = (Real(j) - fy) * self.dx
                        var dpz = (Real(k) - fz) * self.dx
                        var idx = self._gi(bx + i, by + j, bz + k)
                        self.gm[idx] += w * q.mass
                        self.gvx[idx] += w * (
                            q.mass * q.v[0]
                            + affine.get(0, 0) * dpx
                            + affine.get(0, 1) * dpy
                            + affine.get(0, 2) * dpz
                        )
                        self.gvy[idx] += w * (
                            q.mass * q.v[1]
                            + affine.get(1, 0) * dpx
                            + affine.get(1, 1) * dpy
                            + affine.get(1, 2) * dpz
                        )
                        self.gvz[idx] += w * (
                            q.mass * q.v[2]
                            + affine.get(2, 0) * dpx
                            + affine.get(2, 1) * dpy
                            + affine.get(2, 2) * dpz
                        )

        # ---- grid: momentum -> velocity, gravity, boundaries ----
        for k in range(self.n):
            for j in range(self.n):
                for i in range(self.n):
                    var idx = self._gi(i, j, k)
                    var m = self.gm[idx]
                    if m <= 1e-12:
                        self.gvx[idx] = 0
                        self.gvy[idx] = 0
                        self.gvz[idx] = 0
                        continue
                    var inv = 1.0 / m
                    self.gvx[idx] *= inv
                    self.gvy[idx] *= inv
                    self.gvz[idx] *= inv
                    self.gvx[idx] += gravity[0] * dt
                    self.gvy[idx] += gravity[1] * dt
                    self.gvz[idx] += gravity[2] * dt
                    # sticky walls in a 3-cell boundary band
                    if i < 3 and self.gvx[idx] < 0:
                        self.gvx[idx] = 0
                    if i > self.n - 4 and self.gvx[idx] > 0:
                        self.gvx[idx] = 0
                    if j < 3 and self.gvy[idx] < 0:
                        self.gvy[idx] = 0
                    if j > self.n - 4 and self.gvy[idx] > 0:
                        self.gvy[idx] = 0
                    if k < 3 and self.gvz[idx] < 0:
                        self.gvz[idx] = 0
                    if k > self.n - 4 and self.gvz[idx] > 0:
                        self.gvz[idx] = 0

        # ---- G2P ----
        for pi in range(len(self.p)):
            var q = self.p[pi]
            var gx = (q.x[0] - self.lo[0]) * inv_dx
            var gy = (q.x[1] - self.lo[1]) * inv_dx
            var gz = (q.x[2] - self.lo[2]) * inv_dx
            var bx = Int(gx - 0.5)
            var by = Int(gy - 0.5)
            var bz = Int(gz - 0.5)
            if bx < 0 or by < 0 or bz < 0:
                continue
            if bx + 2 >= self.n or by + 2 >= self.n or bz + 2 >= self.n:
                continue
            var fx = gx - Real(bx)
            var fy = gy - Real(by)
            var fz = gz - Real(bz)
            var wx = Array[Real, 3](fill=0)
            var wy = Array[Real, 3](fill=0)
            var wz = Array[Real, 3](fill=0)
            wx[0] = 0.5 * (1.5 - fx) * (1.5 - fx)
            wx[1] = 0.75 - (fx - 1.0) * (fx - 1.0)
            wx[2] = 0.5 * (fx - 0.5) * (fx - 0.5)
            wy[0] = 0.5 * (1.5 - fy) * (1.5 - fy)
            wy[1] = 0.75 - (fy - 1.0) * (fy - 1.0)
            wy[2] = 0.5 * (fy - 0.5) * (fy - 0.5)
            wz[0] = 0.5 * (1.5 - fz) * (1.5 - fz)
            wz[1] = 0.75 - (fz - 1.0) * (fz - 1.0)
            wz[2] = 0.5 * (fz - 0.5) * (fz - 0.5)

            var nv = Vec3(0, 0, 0, 0)
            var nc = Mat3()
            for i in range(3):
                for j in range(3):
                    for k in range(3):
                        var w = wx[i] * wy[j] * wz[k]
                        var idx = self._gi(bx + i, by + j, bz + k)
                        var gvel = Vec3(
                            self.gvx[idx], self.gvy[idx], self.gvz[idx]
                        , 0)
                        # offset from the particle to grid node (b+i):
                        # (i - fx) * dx, with fx in [0.5, 1.5] from the
                        # base = int(g - 0.5) convention. An extra +1 here
                        # shifts every stencil weight onto the wrong node and
                        # the solver explodes in free fall.
                        var dpx = (Real(i) - fx) * self.dx
                        var dpy = (Real(j) - fy) * self.dx
                        var dpz = (Real(k) - fz) * self.dx
                        nv = nv + gvel * w
                        # APIC affine matrix: outer product of velocity and
                        # offset, scaled by 4/dx^2 for the quadratic kernel
                        var s = w * 4.0 * inv_dx * inv_dx
                        nc.set(0, 0, nc.get(0, 0) + s * gvel[0] * dpx)
                        nc.set(0, 1, nc.get(0, 1) + s * gvel[0] * dpy)
                        nc.set(0, 2, nc.get(0, 2) + s * gvel[0] * dpz)
                        nc.set(1, 0, nc.get(1, 0) + s * gvel[1] * dpx)
                        nc.set(1, 1, nc.get(1, 1) + s * gvel[1] * dpy)
                        nc.set(1, 2, nc.get(1, 2) + s * gvel[1] * dpz)
                        nc.set(2, 0, nc.get(2, 0) + s * gvel[2] * dpx)
                        nc.set(2, 1, nc.get(2, 1) + s * gvel[2] * dpy)
                        nc.set(2, 2, nc.get(2, 2) + s * gvel[2] * dpz)

            q.v = nv
            q.c = nc
            q.x = q.x + nv * dt
            # F <- (I + dt C) F
            var upd = Mat3.identity()
            for a in range(3):
                for b in range(3):
                    upd.set(a, b, upd.get(a, b) + dt * nc.get(a, b))
            q.f = upd * q.f
            # PLASTICITY: forget elastic strain outside the yield range. This
            # single clamp is what turns an elastic solid into a material that
            # flows and keeps its new shape.
            if self.j_max > self.j_min:
                var jd = det3(q.f)
                if jd > self.j_max or jd < self.j_min:
                    var target = self.j_max if jd > self.j_max else self.j_min
                    if abs(jd) > 1e-9:
                        # cube root through Float64: Real ** Float64
                        # is not a supported type combination on this nightly
                        var sc = Real(Float64(target / jd) ** (1.0 / 3.0))
                        for a in range(3):
                            for b in range(3):
                                q.f.set(a, b, q.f.get(a, b) * sc)
            self.p[pi] = q

    def step_ext(mut self, dt: Real, gravity: Vec3):
        """`step` plus static obstacles (grid) and Drucker-Prager sand (after
        G2P). A copy of `step` rather than a branch inside it: every way of
        adding the extension to `step` itself that was tried -- run-time
        branches in the body, the body moved into a comptime-parameterised
        helper -- changed how it compiled and moved `test_mpm`'s digits
        (spread 0.20055819 -> 0.20055932). `MpmContinuum` and callers with
        sand or obstacles use this one."""
        var cells = self.n * self.n * self.n
        for c in range(cells):
            self.gm[c] = 0
            self.gvx[c] = 0
            self.gvy[c] = 0
            self.gvz[c] = 0

        var inv_dx = 1.0 / self.dx

        # ---- P2G ----
        for pi in range(len(self.p)):
            var q = self.p[pi]
            var gx = (q.x[0] - self.lo[0]) * inv_dx
            var gy = (q.x[1] - self.lo[1]) * inv_dx
            var gz = (q.x[2] - self.lo[2]) * inv_dx
            var bx = Int(gx - 0.5)
            var by = Int(gy - 0.5)
            var bz = Int(gz - 0.5)
            if bx < 0 or by < 0 or bz < 0:
                continue
            if bx + 2 >= self.n or by + 2 >= self.n or bz + 2 >= self.n:
                continue
            var fx = gx - Real(bx)
            var fy = gy - Real(by)
            var fz = gz - Real(bz)
            # quadratic B-spline weights over the 3-cell stencil
            var wx = Array[Real, 3](fill=0)
            var wy = Array[Real, 3](fill=0)
            var wz = Array[Real, 3](fill=0)
            wx[0] = 0.5 * (1.5 - fx) * (1.5 - fx)
            wx[1] = 0.75 - (fx - 1.0) * (fx - 1.0)
            wx[2] = 0.5 * (fx - 0.5) * (fx - 0.5)
            wy[0] = 0.5 * (1.5 - fy) * (1.5 - fy)
            wy[1] = 0.75 - (fy - 1.0) * (fy - 1.0)
            wy[2] = 0.5 * (fy - 0.5) * (fy - 0.5)
            wz[0] = 0.5 * (1.5 - fz) * (1.5 - fz)
            wz[1] = 0.75 - (fz - 1.0) * (fz - 1.0)
            wz[2] = 0.5 * (fz - 0.5) * (fz - 0.5)

            # fixed-corotated stress: P = 2 mu (F - R) + lambda (J - 1) J F^-T,
            # folded into the MLS affine term
            var r = polar_rotation(q.f)
            var jdet = det3(q.f)
            var stress = Mat3()
            for a in range(3):
                for b in range(3):
                    stress.set(a, b, 2 * self.mu * q.shear * (q.f.get(a, b) - r.get(a, b)))
            # the shear factor scales the deviatoric part only: the isotropic
            # part of F - R, (tr(F - R) / 3) I, is compression resistance and
            # stays (a liquid particle keeps it, 17.61)
            var iso = 2 * self.mu * (1 - q.shear) * (q.f.get(0, 0) - r.get(0, 0) + q.f.get(1, 1) - r.get(1, 1) + q.f.get(2, 2) - r.get(2, 2)) / 3
            for a in range(3):
                stress.set(a, a, stress.get(a, a) + iso)
            # volumetric part: P_vol F^T = lambda (J-1) J F^-T F^T = lambda (J-1) J I,
            # so it joins the Kirchhoff stress P F^T after the product, not P
            # before it (before it, F^T would rotate the pressure)
            var volterm = self.lam * (jdet - 1.0) * jdet
            var ft = q.f.transpose()
            var pft = stress * ft  # P F^T, the Cauchy-like term MLS scatters
            for a in range(3):
                pft.set(a, a, pft.get(a, a) + volterm)
            var scale = -dt * q.vol * 4.0 * inv_dx * inv_dx
            var affine = Mat3()
            for a in range(3):
                for b in range(3):
                    affine.set(
                        a, b, scale * pft.get(a, b) + q.mass * q.c.get(a, b)
                    )

            for i in range(3):
                for j in range(3):
                    for k in range(3):
                        var w = wx[i] * wy[j] * wz[k]
                        # offset from the particle to grid node (b+i):
                        # (i - fx) * dx, with fx in [0.5, 1.5] from the
                        # base = int(g - 0.5) convention. An extra +1 here
                        # shifts every stencil weight onto the wrong node and
                        # the solver explodes in free fall.
                        var dpx = (Real(i) - fx) * self.dx
                        var dpy = (Real(j) - fy) * self.dx
                        var dpz = (Real(k) - fz) * self.dx
                        var idx = self._gi(bx + i, by + j, bz + k)
                        self.gm[idx] += w * q.mass
                        self.gvx[idx] += w * (
                            q.mass * q.v[0]
                            + affine.get(0, 0) * dpx
                            + affine.get(0, 1) * dpy
                            + affine.get(0, 2) * dpz
                        )
                        self.gvy[idx] += w * (
                            q.mass * q.v[1]
                            + affine.get(1, 0) * dpx
                            + affine.get(1, 1) * dpy
                            + affine.get(1, 2) * dpz
                        )
                        self.gvz[idx] += w * (
                            q.mass * q.v[2]
                            + affine.get(2, 0) * dpx
                            + affine.get(2, 1) * dpy
                            + affine.get(2, 2) * dpz
                        )

        # ---- grid: momentum -> velocity, gravity, boundaries ----
        for k in range(self.n):
            for j in range(self.n):
                for i in range(self.n):
                    var idx = self._gi(i, j, k)
                    var m = self.gm[idx]
                    if m <= 1e-12:
                        self.gvx[idx] = 0
                        self.gvy[idx] = 0
                        self.gvz[idx] = 0
                        continue
                    var inv = 1.0 / m
                    self.gvx[idx] *= inv
                    self.gvy[idx] *= inv
                    self.gvz[idx] *= inv
                    self.gvx[idx] += gravity[0] * dt
                    self.gvy[idx] += gravity[1] * dt
                    self.gvz[idx] += gravity[2] * dt
                    self._obstacle(i, j, k, idx)
                    if len(self.rigids) > 0:
                        self._rigid_node(i, j, k, idx, dt)
                    # sticky walls in a 3-cell boundary band
                    if i < 3 and self.gvx[idx] < 0:
                        self.gvx[idx] = 0
                    if i > self.n - 4 and self.gvx[idx] > 0:
                        self.gvx[idx] = 0
                    if j < 3 and self.gvy[idx] < 0:
                        self.gvy[idx] = 0
                    if j > self.n - 4 and self.gvy[idx] > 0:
                        self.gvy[idx] = 0
                    if k < 3 and self.gvz[idx] < 0:
                        self.gvz[idx] = 0
                    if k > self.n - 4 and self.gvz[idx] > 0:
                        self.gvz[idx] = 0

        # ---- G2P ----
        for pi in range(len(self.p)):
            var q = self.p[pi]
            var gx = (q.x[0] - self.lo[0]) * inv_dx
            var gy = (q.x[1] - self.lo[1]) * inv_dx
            var gz = (q.x[2] - self.lo[2]) * inv_dx
            var bx = Int(gx - 0.5)
            var by = Int(gy - 0.5)
            var bz = Int(gz - 0.5)
            if bx < 0 or by < 0 or bz < 0:
                continue
            if bx + 2 >= self.n or by + 2 >= self.n or bz + 2 >= self.n:
                continue
            var fx = gx - Real(bx)
            var fy = gy - Real(by)
            var fz = gz - Real(bz)
            var wx = Array[Real, 3](fill=0)
            var wy = Array[Real, 3](fill=0)
            var wz = Array[Real, 3](fill=0)
            wx[0] = 0.5 * (1.5 - fx) * (1.5 - fx)
            wx[1] = 0.75 - (fx - 1.0) * (fx - 1.0)
            wx[2] = 0.5 * (fx - 0.5) * (fx - 0.5)
            wy[0] = 0.5 * (1.5 - fy) * (1.5 - fy)
            wy[1] = 0.75 - (fy - 1.0) * (fy - 1.0)
            wy[2] = 0.5 * (fy - 0.5) * (fy - 0.5)
            wz[0] = 0.5 * (1.5 - fz) * (1.5 - fz)
            wz[1] = 0.75 - (fz - 1.0) * (fz - 1.0)
            wz[2] = 0.5 * (fz - 0.5) * (fz - 0.5)

            var nv = Vec3(0, 0, 0, 0)
            var nc = Mat3()
            for i in range(3):
                for j in range(3):
                    for k in range(3):
                        var w = wx[i] * wy[j] * wz[k]
                        var idx = self._gi(bx + i, by + j, bz + k)
                        var gvel = Vec3(
                            self.gvx[idx], self.gvy[idx], self.gvz[idx]
                        , 0)
                        # offset from the particle to grid node (b+i):
                        # (i - fx) * dx, with fx in [0.5, 1.5] from the
                        # base = int(g - 0.5) convention. An extra +1 here
                        # shifts every stencil weight onto the wrong node and
                        # the solver explodes in free fall.
                        var dpx = (Real(i) - fx) * self.dx
                        var dpy = (Real(j) - fy) * self.dx
                        var dpz = (Real(k) - fz) * self.dx
                        nv = nv + gvel * w
                        # APIC affine matrix: outer product of velocity and
                        # offset, scaled by 4/dx^2 for the quadratic kernel
                        var s = w * 4.0 * inv_dx * inv_dx
                        nc.set(0, 0, nc.get(0, 0) + s * gvel[0] * dpx)
                        nc.set(0, 1, nc.get(0, 1) + s * gvel[0] * dpy)
                        nc.set(0, 2, nc.get(0, 2) + s * gvel[0] * dpz)
                        nc.set(1, 0, nc.get(1, 0) + s * gvel[1] * dpx)
                        nc.set(1, 1, nc.get(1, 1) + s * gvel[1] * dpy)
                        nc.set(1, 2, nc.get(1, 2) + s * gvel[1] * dpz)
                        nc.set(2, 0, nc.get(2, 0) + s * gvel[2] * dpx)
                        nc.set(2, 1, nc.get(2, 1) + s * gvel[2] * dpy)
                        nc.set(2, 2, nc.get(2, 2) + s * gvel[2] * dpz)

            q.v = nv
            q.c = nc
            q.x = q.x + nv * dt
            # F <- (I + dt C) F
            var upd = Mat3.identity()
            for a in range(3):
                for b in range(3):
                    upd.set(a, b, upd.get(a, b) + dt * nc.get(a, b))
            q.f = upd * q.f
            # PLASTICITY: forget elastic strain outside the yield range. This
            # single clamp is what turns an elastic solid into a material that
            # flows and keeps its new shape.
            if self.j_max > self.j_min:
                var jd = det3(q.f)
                if jd > self.j_max or jd < self.j_min:
                    var target = self.j_max if jd > self.j_max else self.j_min
                    if abs(jd) > 1e-9:
                        # cube root through Float64: Real ** Float64
                        # is not a supported type combination on this nightly
                        var sc = Real(Float64(target / jd) ** (1.0 / 3.0))
                        for a in range(3):
                            for b in range(3):
                                q.f.set(a, b, q.f.get(a, b) * sc)
            self.p[pi] = q
        if self.dp_alpha > 0:
            while len(self.sand_vc) < len(self.p):
                self.sand_vc.append(0)
            for pi in range(len(self.p)):
                var before = Real(0)
                if self.measure_loss:
                    before = self.elastic_energy(self.p[pi].f)
                var res = self._sand(self.p[pi].f, self.sand_vc[pi])
                if self.measure_loss:
                    self.sand_loss += self.p[pi].vol * (before - self.elastic_energy(res[0]))
                self.p[pi].f = res[0]
                self.sand_vc[pi] = res[1]
        if len(self.obstacles) > 0:
            for pi in range(len(self.p)):
                self._push_out(pi)
        if len(self.rigids) > 0:
            for pi in range(len(self.p)):
                self._rigid_push_out(pi, dt)
