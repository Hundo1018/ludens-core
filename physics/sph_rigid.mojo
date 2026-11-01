"""SPH <-> rigid body two-way coupling (ROADMAP 17.59), after Akinci et al.
2012 ("Versatile rigid-fluid coupling for incompressible SPH") for the
fluid side and Adami et al. 2012 for the wall pressure.

Each coupled body of a `ContactScene6` carries boundary samples on its
surface, in the body frame, each with Akinci's psi (rho0 over the kernel
sum of the body's own samples), an outward normal and the area it stands
for (box: every face on its own grid of cell centres; sphere: Fibonacci
points). Every step:

  1. pose the samples: x_b = body pose * local, velocity v + w x (x_b - c);
  2. fluid density: own neighbours + static boundary + psi_b W(x_i - x_b);
  3. fluid accelerations as `sph_step_boundary`, plus for each moving
     sample Akinci's pressure push -psi_b p_i / rho_i^2 grad W and a viscous
     drag toward the sample's velocity, _VISC lap W psi_b / rho0 (v_b - v_i);
  4. the body gets the viscous drag back pair by pair, and the pressure as
     a surface integral, F = -sum m_p p_b A_b n_b, with p_b the Adami wall
     pressure (Shepard-weighted fluid pressure plus the hydrostatic
     difference rho_i g . (x_b - x_i)); m_p = fluid density / rho0;
  5. the fluid integrates (walls clamp, as `sph_step_boundary`); a fluid
     particle that ends inside a coupled body goes to its surface and loses
     its inward relative velocity, the momentum taken going to the body;
     then the scene steps with the same dt, so coupled bodies still collide.

Why 4 is not Akinci's pairwise reaction: its pressure term is one-sided
(p_i only), and over a kernel radius the hydrostatic pressure changes, so
every sample also takes a force along the pressure gradient. With a 10 cm
kernel on a 10 cm box that is most of the answer -- measured: each vertical
face pushed up 9.4 N, the box 2.3x its displaced weight; with the surface
integral, 0.98-1.00 (test_sph_rigid). The price: the fluid's pressure push
and the body's pressure force are no longer equal and opposite pair by
pair (viscosity and push-out still are).

With no coupled bodies `sph_rigid_step` moves the fluid exactly as
`sph_step_boundary`.
"""

from std.math import sqrt, pi, floor
from geometry.trig import cos, sin
from geometry.vec import Real, Vec3, cross, length, dot
from .pbf import PbfFluid, poly6, spiky_grad, H
from .sph import BoundaryParticles, visc_lap
from .body_set import BodyId
from .rigid6 import Body6, Pose6
from .solver6 import ContactScene6
from .solver_config import SolverConfig
from .state_io import StateWriter, StateReader

comptime _STIFF: Real = 8.0  # as physics.sph
comptime _VISC: Real = 0.15


struct SphRigidCoupler(Movable):
    var bodies: List[BodyId]
    var kind: List[Int]  # 0 box, 1 sphere
    var dims: List[Vec3]  # box half extents, or (radius, 0, 0)
    var start: List[Int]  # first sample of each body
    var local: List[Vec3]  # samples in the body frame
    var normal: List[Vec3]  # outward normal per sample, body frame
    var area: List[Real]  # surface area each sample stands for (m^2)
    var psi: List[Real]
    var world: List[Vec3]  # scratch: posed samples
    var vel: List[Vec3]  # scratch: sample velocities
    var particle_mass: Real  # kg per fluid particle
    var force: List[Vec3]  # last step's fluid force per body (N)
    var torque: List[Vec3]
    var stiffness: Real  # equation of state, as physics.sph (8 there)

    def __init__(out self, fluid_density: Real, rho0: Real) raises:
        """`fluid_density` in kg/m^3, `rho0` the fluid's rest number density
        (`PbfFluid.rho0`)."""
        if not (fluid_density > 0) or not (rho0 > 0):
            raise Error("SphRigidCoupler: fluid density and rho0 must be > 0")
        self.bodies = List[BodyId]()
        self.kind = List[Int]()
        self.dims = List[Vec3]()
        self.start = List[Int]()
        self.local = List[Vec3]()
        self.normal = List[Vec3]()
        self.area = List[Real]()
        self.psi = List[Real]()
        self.world = List[Vec3]()
        self.vel = List[Vec3]()
        self.particle_mass = fluid_density / rho0
        self.force = List[Vec3]()
        self.torque = List[Vec3]()
        self.stiffness = _STIFF

    def samples(self) -> Int:
        return len(self.local)

    def _add(mut self, id: BodyId, var pts: List[Vec3], var nrm: List[Vec3], var area: List[Real], rho0: Real):
        self.bodies.append(id)
        self.start.append(len(self.local))
        for k in range(len(pts)):
            var delta = Real(0)
            for j in range(len(pts)):
                var d = pts[k] - pts[j]
                delta += poly6(d[0] * d[0] + d[1] * d[1] + d[2] * d[2])
            self.local.append(pts[k])
            self.normal.append(nrm[k])
            self.area.append(area[k])
            self.psi.append(rho0 / delta if delta > 0 else Real(0))
            self.world.append(Vec3(0, 0, 0, 0))
            self.vel.append(Vec3(0, 0, 0, 0))
        self.force.append(Vec3(0, 0, 0, 0))
        self.torque.append(Vec3(0, 0, 0, 0))

    def add_box(mut self, id: BodyId, half: Vec3, spacing: Real, rho0: Real) raises -> Int:
        """Sample the surface of a box of half extents `half` (body frame):
        each face on a grid of cell centres about `spacing` apart."""
        if not (spacing > 0) or not (half[0] > 0 and half[1] > 0 and half[2] > 0):
            raise Error("SphRigidCoupler.add_box: spacing and half extents must be > 0")
        var pts = List[Vec3]()
        var nrm = List[Vec3]()
        var area = List[Real]()
        # each face on its own grid of cell centres: one normal per sample
        for a in range(3):
            var u = (a + 1) % 3
            var w = (a + 2) % 3
            var nu = max(Int(2 * half[u] / spacing + 0.5), 1)
            var nw = max(Int(2 * half[w] / spacing + 0.5), 1)
            var da = (2 * half[u] / Real(nu)) * (2 * half[w] / Real(nw))
            for side in range(2):
                var sgn = Real(1) if side == 0 else Real(-1)
                for i in range(nu):
                    for j in range(nw):
                        var p = Vec3(0, 0, 0, 0)
                        p[a] = sgn * half[a]
                        p[u] = -half[u] + 2 * half[u] * (Real(i) + 0.5) / Real(nu)
                        p[w] = -half[w] + 2 * half[w] * (Real(j) + 0.5) / Real(nw)
                        var nv = Vec3(0, 0, 0, 0)
                        nv[a] = sgn
                        pts.append(p)
                        nrm.append(nv)
                        area.append(da)
        self._add(id, pts^, nrm^, area^, rho0)
        self.kind.append(0)
        self.dims.append(half)
        return len(self.bodies) - 1

    def add_sphere(mut self, id: BodyId, radius: Real, spacing: Real, rho0: Real) raises -> Int:
        """Sample a sphere surface (Fibonacci points, about `spacing` apart)."""
        if not (spacing > 0) or not (radius > 0):
            raise Error("SphRigidCoupler.add_sphere: spacing and radius must be > 0")
        var n = max(Int(4 * pi * radius * radius / (spacing * spacing) + 0.5), 4)
        var pts = List[Vec3]()
        var nrm = List[Vec3]()
        var area = List[Real]()
        var golden = Real(pi * (3 - sqrt(5.0)))
        for k in range(n):
            var y = 1 - 2 * (Real(k) + 0.5) / Real(n)
            var rr = sqrt(max(1 - y * y, Real(0)))
            var th = golden * Real(k)
            var u = Vec3(cos(th) * rr, y, sin(th) * rr, 0)
            pts.append(u * radius)
            nrm.append(u)
            area.append(Real(4 * pi) * radius * radius / Real(n))
        self._add(id, pts^, nrm^, area^, rho0)
        self.kind.append(1)
        self.dims.append(Vec3(radius, 0, 0, 0))
        return len(self.bodies) - 1

    def push_out(self, b: Int, p: Vec3) -> Tuple[Bool, Vec3, Vec3]:
        """(inside, surface point, outward normal) for a body-frame point:
        the nearest face of a box, radially for a sphere."""
        if self.kind[b] == 1:
            var r = self.dims[b][0]
            var l = length(p)
            if l >= r:
                return (False, p, Vec3(0, 0, 0, 0))
            var nv = p * (1 / l) if l > 1e-12 else Vec3(0, 1, 0, 0)
            return (True, nv * r, nv)
        var h = self.dims[b]
        if abs(p[0]) >= h[0] or abs(p[1]) >= h[1] or abs(p[2]) >= h[2]:
            return (False, p, Vec3(0, 0, 0, 0))
        var best = 0
        var gap = h[0] - abs(p[0])
        for a in range(1, 3):
            if h[a] - abs(p[a]) < gap:
                gap = h[a] - abs(p[a])
                best = a
        var q = p
        var nv = Vec3(0, 0, 0, 0)
        var sgn = Real(1) if p[best] >= 0 else Real(-1)
        q[best] = sgn * h[best]
        nv[best] = sgn
        return (True, q, nv)


def _candidates(f: PbfFluid, pts: List[Vec3], mut start: List[Int], mut out: List[Int]):
    """Per particle i, the points in the 27 grid cells (size H) around its
    predicted position, ascending: out[start[i]:start[i + 1]]."""
    var ns = len(pts)
    var n = f.count()
    if ns == 0:
        for i in range(n + 1):
            start[i] = 0
        return
    var lo = pts[0]
    var hi = pts[0]
    for s in range(ns):
        for a in range(3):
            lo[a] = min(lo[a], pts[s][a])
            hi[a] = max(hi[a], pts[s][a])
    var nx = Int((hi[0] - lo[0]) / H) + 1
    var ny = Int((hi[1] - lo[1]) / H) + 1
    var nz = Int((hi[2] - lo[2]) / H) + 1
    var cells = nx * ny * nz
    var count = List[Int](length=cells + 1, fill=0)
    var cid = List[Int](length=ns, fill=0)
    for s in range(ns):
        var cx = min(Int((pts[s][0] - lo[0]) / H), nx - 1)
        var cy = min(Int((pts[s][1] - lo[1]) / H), ny - 1)
        var cz = min(Int((pts[s][2] - lo[2]) / H), nz - 1)
        cid[s] = (cz * ny + cy) * nx + cx
        count[cid[s] + 1] += 1
    for c in range(cells):
        count[c + 1] += count[c]
    var fill = count.copy()
    var sorted = List[Int](length=ns, fill=0)
    for s in range(ns):  # ascending within each cell
        sorted[fill[cid[s]]] = s
        fill[cid[s]] += 1
    out.clear()
    var tmp = List[Int]()
    for i in range(n):
        start[i] = len(out)
        var gx = Int(floor((f.px[i] - lo[0]) / H))
        var gy = Int(floor((f.py[i] - lo[1]) / H))
        var gz = Int(floor((f.pz[i] - lo[2]) / H))
        tmp.clear()
        for cz in range(max(gz - 1, 0), min(gz + 2, nz)):
            for cy in range(max(gy - 1, 0), min(gy + 2, ny)):
                for cx in range(max(gx - 1, 0), min(gx + 2, nx)):
                    var c = (cz * ny + cy) * nx + cx
                    for k in range(count[c], count[c + 1]):
                        tmp.append(sorted[k])
        sort(tmp)
        for k in range(len(tmp)):
            out.append(tmp[k])
    start[n] = len(out)


def sph_rigid_step[B: Body6](
    mut f: PbfFluid,
    bnd: BoundaryParticles,
    mut cp: SphRigidCoupler,
    mut scene: ContactScene6[B],
    dt: Real,
    gravity: Vec3,
    cfg: SolverConfig,
) raises:
    """One coupled step (module note)."""
    # 1. pose the samples
    var com = List[Vec3]()
    var poses = List[Pose6]()
    var bv = List[Vec3]()
    var bw = List[Vec3]()
    var ns = len(cp.local)
    var nworld = List[Vec3](length=ns, fill=Vec3(0, 0, 0, 0))
    var wsum = List[Real](length=ns, fill=0)
    var psum = List[Real](length=ns, fill=0)
    for b in range(len(cp.bodies)):
        var pose = scene.pose(cp.bodies[b])
        com.append(pose.pos)
        poses.append(pose)
        var v = scene.velocity(cp.bodies[b])
        var w = scene.angular_velocity(cp.bodies[b])
        bv.append(v)
        bw.append(w)
        var end = cp.start[b + 1] if b + 1 < len(cp.bodies) else len(cp.local)
        for s in range(cp.start[b], end):
            var x = pose.pos + pose.rot.rotate(cp.local[s])
            cp.world[s] = x
            cp.vel[s] = v + cross(w, x - pose.pos)
            nworld[s] = pose.rot.rotate(cp.normal[s])
        cp.force[b] = Vec3(0, 0, 0, 0)
        cp.torque[b] = Vec3(0, 0, 0, 0)
    var owner = List[Int](length=len(cp.local), fill=0)
    for b in range(len(cp.bodies)):
        var end = cp.start[b + 1] if b + 1 < len(cp.bodies) else len(cp.local)
        for s in range(cp.start[b], end):
            owner[s] = b

    var n = f.count()
    f._rebuild_grid()
    var h2 = H * H
    # samples near each particle: a hash grid of the posed samples (cell H),
    # each particle's 27 cells gathered and sorted ascending, so the sums
    # below visit the same samples in the same order as a loop over all
    # samples that skips those beyond H -- bit for bit the same, without the
    # O(particles x samples) scan
    var cand_start = List[Int](length=n + 1, fill=0)
    var cand = List[Int]()
    _candidates(f, cp.world, cand_start, cand)
    # the same for the static boundary particles (poly6 is 0 beyond H and
    # the force loop skips r >= H, so the skipped terms added exactly 0)
    var bpts = List[Vec3](capacity=len(bnd.x))
    for b in range(len(bnd.x)):
        bpts.append(Vec3(bnd.x[b], bnd.y[b], bnd.z[b], 0))
    var bc_start = List[Int](length=n + 1, fill=0)
    var bc = List[Int]()
    _candidates(f, bpts, bc_start, bc)

    # 2. density and pressure
    var rho = List[Real]()
    var pres = List[Real]()
    var nbr = List[Int]()
    for i in range(n):
        f._neighbors(i, nbr)
        var d = f.density(i, nbr)
        for qb in range(bc_start[i], bc_start[i + 1]):
            var b = bc[qb]
            var bx = f.px[i] - bnd.x[b]
            var by = f.py[i] - bnd.y[b]
            var bz = f.pz[i] - bnd.z[b]
            d += bnd.psi[b] * poly6(bx * bx + by * by + bz * bz)
        for q in range(cand_start[i], cand_start[i + 1]):
            var s = cand[q]
            var e = Vec3(f.px[i], f.py[i], f.pz[i], 0) - cp.world[s]
            var r2 = e[0] * e[0] + e[1] * e[1] + e[2] * e[2]
            if r2 < h2:
                d += cp.psi[s] * poly6(r2)
        rho.append(d)
        var p = cp.stiffness * (d - f.rho0)
        pres.append(p if p > 0 else Real(0))

    # 3. accelerations; 4. reactions on the bodies
    var ax = List[Real]()
    var ay = List[Real]()
    var az = List[Real]()
    for i in range(n):
        f._neighbors(i, nbr)
        var fx = Real(0)
        var fy = Real(0)
        var fz = Real(0)
        var ri = rho[i] if rho[i] > 1e-9 else Real(1)
        for ref j in nbr:
            var dx = f.px[i] - f.px[j]
            var dy = f.py[i] - f.py[j]
            var dz = f.pz[i] - f.pz[j]
            var r = sqrt(dx * dx + dy * dy + dz * dz)
            if r <= 1e-9:
                continue
            var rj = rho[j] if rho[j] > 1e-9 else Real(1)
            var coeff = (pres[i] / (ri * ri) + pres[j] / (rj * rj))
            var g = spiky_grad(r) / r
            fx -= coeff * g * dx
            fy -= coeff * g * dy
            fz -= coeff * g * dz
            var lap = _VISC * visc_lap(r) / rj
            fx += lap * (f.vx[j] - f.vx[i])
            fy += lap * (f.vy[j] - f.vy[i])
            fz += lap * (f.vz[j] - f.vz[i])
        for qb in range(bc_start[i], bc_start[i + 1]):
            var b = bc[qb]
            var bx = f.px[i] - bnd.x[b]
            var by = f.py[i] - bnd.y[b]
            var bz = f.pz[i] - bnd.z[b]
            var r = sqrt(bx * bx + by * by + bz * bz)
            if r <= 1e-9 or r >= H:
                continue
            var coeff = bnd.psi[b] * pres[i] / (ri * ri)
            var g = spiky_grad(r) / r
            fx -= coeff * g * bx
            fy -= coeff * g * by
            fz -= coeff * g * bz
        var vi = Vec3(f.vx[i], f.vy[i], f.vz[i], 0)
        for q in range(cand_start[i], cand_start[i + 1]):
            var s = cand[q]
            var e = Vec3(f.px[i], f.py[i], f.pz[i], 0) - cp.world[s]
            var r = length(e)
            if r <= 1e-9 or r >= H:
                continue
            var coeff = cp.psi[s] * pres[i] / (ri * ri)
            var a_visc = (cp.vel[s] - vi) * (_VISC * visc_lap(r) * cp.psi[s] / f.rho0)
            var a = e * (-coeff * spiky_grad(r) / r) + a_visc
            fx += a[0]
            fy += a[1]
            fz += a[2]
            # the viscous drag goes back pairwise; the pressure is
            # integrated over the surface below
            var fb = a_visc * (-cp.particle_mass)
            var o = owner[s]
            cp.force[o] = cp.force[o] + fb
            cp.torque[o] = cp.torque[o] + cross(cp.world[s] - com[o], fb)
            # Adami et al. 2012 wall pressure: Shepard-weighted fluid
            # pressure plus the hydrostatic difference rho g (x_b - x_i)
            var wk = poly6(r * r)
            wsum[s] += wk
            psum[s] += (pres[i] + rho[i] * (-(e[0] * gravity[0] + e[1] * gravity[1] + e[2] * gravity[2]))) * wk
        ax.append(fx + gravity[0])
        ay.append(fy + gravity[1])
        az.append(fz + gravity[2])

    # 5. integrate the fluid as sph_step_boundary, then the scene
    for i in range(n):
        f.vx[i] += ax[i] * dt
        f.vy[i] += ay[i] * dt
        f.vz[i] += az[i] * dt
        f.px[i] = f.x[i] + f.vx[i] * dt
        f.py[i] = f.y[i] + f.vy[i] * dt
        f.pz[i] = f.z[i] + f.vz[i] * dt
        f._clamp_to_box(i)
        if f.px[i] != f.x[i] + f.vx[i] * dt:
            f.vx[i] = 0
        if f.py[i] != f.y[i] + f.vy[i] * dt:
            f.vy[i] = 0
        if f.pz[i] != f.z[i] + f.vz[i] * dt:
            f.vz[i] = 0
        # out of the coupled bodies: onto the surface, inward relative
        # velocity removed; the momentum taken goes to the body
        for b in range(len(cp.bodies)):
            var xw = Vec3(f.px[i], f.py[i], f.pz[i], 0)
            var lp = poses[b].rot.conjugate().rotate(xw - com[b])
            var po = cp.push_out(b, lp)
            if not po[0]:
                continue
            var xs = com[b] + poses[b].rot.rotate(po[1])
            var nw = poses[b].rot.rotate(po[2])
            f.px[i] = xs[0]
            f.py[i] = xs[1]
            f.pz[i] = xs[2]
            var vi = Vec3(f.vx[i], f.vy[i], f.vz[i], 0)
            var vn = dot(vi - bv[b] - cross(bw[b], xs - com[b]), nw)
            if vn < 0:
                f.vx[i] -= vn * nw[0]
                f.vy[i] -= vn * nw[1]
                f.vz[i] -= vn * nw[2]
                var fb = nw * (cp.particle_mass * vn / dt)
                cp.force[b] = cp.force[b] + fb
                cp.torque[b] = cp.torque[b] + cross(xs - com[b], fb)
        f.x[i] = f.px[i]
        f.y[i] = f.py[i]
        f.z[i] = f.pz[i]
    for s in range(ns):
        if wsum[s] <= 0:
            continue
        var pb = max(psum[s] / wsum[s], Real(0))
        var fp = nworld[s] * (-cp.particle_mass * pb * cp.area[s])
        var o = owner[s]
        cp.force[o] = cp.force[o] + fp
        cp.torque[o] = cp.torque[o] + cross(cp.world[s] - com[o], fp)
    for b in range(len(cp.bodies)):
        scene.add_force(cp.bodies[b], cp.force[b])
        scene.add_torque(cp.bodies[b], cp.torque[b])
    scene.step(dt, gravity, cfg)


def sph_rigid_write[W: StateWriter](f: PbfFluid, cp: SphRigidCoupler, mut w: W):
    """Dynamical state of an SPH <-> rigid run (17.59): the fluid particles
    (positions, velocities) and the coupler's last body forces; the scene
    goes through `solver6.write_state`. Samples, psi and the fluid's grid
    are construction: restore into a fluid and coupler built the same way."""
    w.wi(f.count())
    for i in range(f.count()):
        w.wf(f.x[i])
        w.wf(f.y[i])
        w.wf(f.z[i])
        w.wf(f.vx[i])
        w.wf(f.vy[i])
        w.wf(f.vz[i])
    w.wi(len(cp.bodies))
    for b in range(len(cp.bodies)):
        w.wv(cp.force[b])
        w.wv(cp.torque[b])


def sph_rigid_read[R: StateReader](mut f: PbfFluid, mut cp: SphRigidCoupler, mut r: R) raises:
    """Inverse of `sph_rigid_write`. The predicted positions are set to the
    positions, as a finished step leaves them (`sph_rigid_step` reads them
    for the density); raises when the particle or body count differs."""
    if r.ri() != f.count():
        raise Error("sph_rigid_read: particle count differs from this fluid")
    for i in range(f.count()):
        f.x[i] = r.rf()
        f.y[i] = r.rf()
        f.z[i] = r.rf()
        f.vx[i] = r.rf()
        f.vy[i] = r.rf()
        f.vz[i] = r.rf()
        f.px[i] = f.x[i]
        f.py[i] = f.y[i]
        f.pz[i] = f.z[i]
    if r.ri() != len(cp.bodies):
        raise Error("sph_rigid_read: coupled body count differs from this coupler")
    for b in range(len(cp.bodies)):
        cp.force[b] = r.rv()
        cp.torque[b] = r.rv()
