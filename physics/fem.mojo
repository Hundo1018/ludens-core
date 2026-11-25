"""Co-rotational linear tetrahedral FEM — a continuum next to the mass-spring lattice.

`softbody.mojo` models a deformable as particles joined by distance
constraints. That is cheap and stable but it is not a material: its stiffness
depends on how the lattice happens to be connected, it has no Poisson effect,
and "volume" is only preserved to the extent the spring topology happens to
resist it. FEM instead discretises the CONTINUUM: each tetrahedron carries a
deformation gradient, and stress comes from a constitutive law with real
material parameters (Lame mu and lambda), so stiffness and volume response are
properties of the material rather than of the mesh wiring.

The "co-rotational" part is the whole reason this is usable. Linear elasticity
computes stress from the small-strain tensor, which is only valid for small
DISPLACEMENTS — rotate an undeformed body and linear FEM reports enormous
spurious strain and tears it apart. Co-rotational FEM extracts the rotation R
from the deformation gradient F by polar decomposition and measures strain in
the unrotated frame, so a rigid rotation produces exactly zero force. That
property is asserted directly in `test_fem`, because it is the one that
separates a working implementation from one that merely looks elastic at rest.

Stress (co-rotational linear):  P(F) = 2*mu*(F - R) + lambda * tr(R^T F - I) * R
Nodal forces:                   H = -W * P * Dm^-T,  columns give f0..f2, f3 = -sum

The implicit step's linear solve is a seam (ROADMAP 17.84, `FemBody.solver`):
FEM_SOLVE_CG (matrix-free conjugate gradients, the default), FEM_SOLVE_CHOLESKY
(the operator assembled into a sparse matrix, `numerics.cholesky` with a
reverse Cuthill-McKee ordering: a direct solve), FEM_SOLVE_PCG_IC0 (assembled,
CG preconditioned with incomplete Cholesky). The assembled matrix drops the rows
and columns of pinned nodes (their dv is exactly zero either way), which keeps
it symmetric.
"""

from std.math import sqrt
from geometry.vec import Real, Vec3
from geometry.mat import Mat3
from numerics.sparse import LinearOperator, CsrMatrix
from numerics.cg import cg, CgResult
from numerics.cholesky import SparseCholesky, IncompleteCholesky, pcg_ic0, rcm_order

comptime FEM_SOLVE_CG = 0
comptime FEM_SOLVE_CHOLESKY = 1
comptime FEM_SOLVE_PCG_IC0 = 2
from diag.counters import Counters, CG_NOT_CONVERGED
from geometry.tetmesh import TetMesh


def det3(m: Mat3) -> Real:
    """3x3 determinant. Public (not `_det3`): `physics/mpm.mojo` imports it
    deliberately, both solvers' plasticity/inversion math needing the same
    determinant (audit F18). A dedicated `geometry.mat3.Mat3x3` type with its
    own `.det()` now exists for new code (audit F8); `fem`/`mpm` keep the
    `Mat3`-based representation here rather than migrating in this pass —
    that migration made the physics package's compile time regress
    severely (see 17.0c-d-placement.md step 7 notes) and was reverted."""
    return (
        m.get(0, 0) * (m.get(1, 1) * m.get(2, 2) - m.get(1, 2) * m.get(2, 1))
        - m.get(0, 1) * (m.get(1, 0) * m.get(2, 2) - m.get(1, 2) * m.get(2, 0))
        + m.get(0, 2) * (m.get(1, 0) * m.get(2, 1) - m.get(1, 1) * m.get(2, 0))
    )


def _inv3(m: Mat3) -> Mat3:
    var d = det3(m)
    var inv = 1.0 / d if abs(d) > 1e-20 else Real(0)
    var r = Mat3()
    r.set(0, 0, (m.get(1, 1) * m.get(2, 2) - m.get(1, 2) * m.get(2, 1)) * inv)
    r.set(0, 1, (m.get(0, 2) * m.get(2, 1) - m.get(0, 1) * m.get(2, 2)) * inv)
    r.set(0, 2, (m.get(0, 1) * m.get(1, 2) - m.get(0, 2) * m.get(1, 1)) * inv)
    r.set(1, 0, (m.get(1, 2) * m.get(2, 0) - m.get(1, 0) * m.get(2, 2)) * inv)
    r.set(1, 1, (m.get(0, 0) * m.get(2, 2) - m.get(0, 2) * m.get(2, 0)) * inv)
    r.set(1, 2, (m.get(0, 2) * m.get(1, 0) - m.get(0, 0) * m.get(1, 2)) * inv)
    r.set(2, 0, (m.get(1, 0) * m.get(2, 1) - m.get(1, 1) * m.get(2, 0)) * inv)
    r.set(2, 1, (m.get(0, 1) * m.get(2, 0) - m.get(0, 0) * m.get(2, 1)) * inv)
    r.set(2, 2, (m.get(0, 0) * m.get(1, 1) - m.get(0, 1) * m.get(1, 0)) * inv)
    return r^


def polar_rotation(f: Mat3) -> Mat3:
    """Rotation factor of `F = R S` by Newton iteration `R <- (R + R^-T)/2`.

    Cheap, quadratically convergent, and the standard choice for co-rotational
    FEM. It is what makes a rigid rotation cost zero force: without it the
    strain measure sees the rotation as stretch."""
    var r = f.copy()
    for _ in range(12):
        var rit = _inv3(r).transpose()
        var nr = Mat3()
        for i in range(3):
            for j in range(3):
                nr.set(i, j, 0.5 * (r.get(i, j) + rit.get(i, j)))
        r = nr^
    return r^


@fieldwise_init
struct Tet(Copyable, ImplicitlyCopyable, Movable):
    var a: Int
    var b: Int
    var c: Int
    var d: Int
    var dm_inv: Mat3  # inverse rest shape matrix
    var vol: Real  # rest volume


struct FemBody(Movable):
    """Node state as SoA plus a tetrahedron list."""

    var x: List[Real]
    var y: List[Real]
    var z: List[Real]
    var vx: List[Real]
    var vy: List[Real]
    var vz: List[Real]
    var inv_m: List[Real]  # 0 = pinned
    var tets: List[Tet]
    var mu: Real
    var lam: Real
    var damping: Real
    var corotational: Bool
    """When False, strain is measured with R = I — plain linear elasticity.
    Kept as a switchable variant rather than deleted because it is the control
    that shows what the polar decomposition BUYS: `bench_fem` prices the
    rotation extraction, and `test_fem` shows that without it a rigid rotation
    of an undeformed body generates enormous spurious force."""
    var solver: Int  # FEM_SOLVE_* (17.84)
    # 17.58 plasticity (Mueller & Gross 2004): a plastic strain per tet (6
    # entries: xx yy zz xy xz yz), subtracted from the co-rotated strain
    # before the stress; empty = off (forces bit for bit as before)
    var plastic: List[Real]
    var yield_strain: Real
    var creep: Real
    var max_plastic: Real
    # 17.57 muscle: fibre direction per tet (3 entries), peak active stress
    # and the current activation in [0, 1]; empty = off
    var fiber: List[Real]
    var sigma_max: Real
    var activation: Real
    var counters: Counters
    """ROADMAP 17.0h / audit E19: `diag` counters, so far only
    `CG_NOT_CONVERGED` (bumped by `step_implicit` when its `cg()` solve
    didn't converge and the velocity delta it produced was discarded rather
    than applied -- see that method)."""

    def __init__(out self, young: Real, poisson: Real, damping: Real = 4.0):
        self.x = List[Real]()
        self.y = List[Real]()
        self.z = List[Real]()
        self.vx = List[Real]()
        self.vy = List[Real]()
        self.vz = List[Real]()
        self.inv_m = List[Real]()
        self.tets = List[Tet]()
        # Lame parameters from the engineering constants a user actually knows
        self.mu = young / (2 * (1 + poisson))
        self.lam = young * poisson / ((1 + poisson) * (1 - 2 * poisson))
        self.damping = damping
        self.corotational = True
        self.solver = FEM_SOLVE_CG
        self.plastic = List[Real]()
        self.yield_strain = 0
        self.creep = 0
        self.max_plastic = 0
        self.fiber = List[Real]()
        self.sigma_max = 0
        self.activation = 0
        self.counters = Counters()

    def node_count(self) -> Int:
        return len(self.x)

    def add_node(mut self, p: Vec3, mass: Real):
        self.x.append(p[0])
        self.y.append(p[1])
        self.z.append(p[2])
        self.vx.append(0)
        self.vy.append(0)
        self.vz.append(0)
        self.inv_m.append(1.0 / mass if mass > 0 else Real(0))

    def pos(self, i: Int) -> Vec3:
        return Vec3(self.x[i], self.y[i], self.z[i], 0)

    def pin(mut self, i: Int):
        self.inv_m[i] = 0

    def add_tet(mut self, a: Int, b: Int, c: Int, d: Int):
        var pa = self.pos(a)
        var e1 = self.pos(b) - pa
        var e2 = self.pos(c) - pa
        var e3 = self.pos(d) - pa
        var dm = Mat3()
        for k in range(3):
            dm.set(k, 0, e1[k])
            dm.set(k, 1, e2[k])
            dm.set(k, 2, e3[k])
        var det = det3(dm)
        # Skip degenerate tets rather than storing an infinite inverse. A
        # negatively oriented one is kept with |det|: F = Ds Dm^-1 does not
        # depend on the vertex order (a permutation of b, c, d permutes the
        # columns of Ds and Dm alike), so its det F is positive at rest and
        # turns <= 0 only when the element really inverts (17.58).
        if abs(det) < 1e-12:
            return
        self.tets.append(Tet(a, b, c, d, _inv3(dm), abs(det) / 6.0))
        if len(self.plastic) > 0:
            for _ in range(6):
                self.plastic.append(0)

    def total_volume(self) -> Real:
        var v = Real(0)
        for ref t in self.tets:
            var pa = self.pos(t.a)
            var e1 = self.pos(t.b) - pa
            var e2 = self.pos(t.c) - pa
            var e3 = self.pos(t.d) - pa
            var ds = Mat3()
            for k in range(3):
                ds.set(k, 0, e1[k])
                ds.set(k, 1, e2[k])
                ds.set(k, 2, e3[k])
            v += abs(det3(ds)) / 6.0
        return v

    def set_plasticity(mut self, yield_strain: Real, creep: Real, max_plastic: Real) raises:
        """Turn on plastic flow (17.58, Mueller & Gross 2004) for
        `step_ext` (not `step` / `step_implicit`): after each step, where a tet's elastic strain (co-rotated strain minus its
        plastic strain, Frobenius norm) exceeds `yield_strain`, the plastic
        strain moves toward it by `creep` times the excess fraction, capped
        at norm `max_plastic`. Raises on yield <= 0, creep outside (0, 1] or
        max_plastic < 0."""
        if not (yield_strain > 0) or not (creep > 0 and creep <= 1) or not (max_plastic >= 0):
            raise Error("FemBody.set_plasticity: yield > 0, creep in (0, 1], max_plastic >= 0")
        self.yield_strain = yield_strain
        self.creep = creep
        self.max_plastic = max_plastic
        self.plastic = List[Real](length=6 * len(self.tets), fill=0)

    def plastic_forces(self, mut fx: List[Real], mut fy: List[Real], mut fz: List[Real]):
        """The plastic strain's share of the elastic forces, added as its own
        pass (the stress is linear in the strain: P - R (2 mu Ep + lambda
        tr(Ep) I)), so `elastic_forces` itself is unchanged when plasticity
        is off -- editing its loop moved `test_thermal`'s last digits."""
        for e in range(len(self.tets)):
            ref t = self.tets[e]
            var pa = self.pos(t.a)
            var e1 = self.pos(t.b) - pa
            var e2 = self.pos(t.c) - pa
            var e3 = self.pos(t.d) - pa
            var ds = Mat3()
            for k in range(3):
                ds.set(k, 0, e1[k])
                ds.set(k, 1, e2[k])
                ds.set(k, 2, e3[k])
            var r = polar_rotation(ds * t.dm_inv) if self.corotational else Mat3.identity()
            var ep = self._plastic_mat(e)
            var tre = ep.get(0, 0) + ep.get(1, 1) + ep.get(2, 2)
            var sp = Mat3()
            for i in range(3):
                for j in range(3):
                    sp.set(i, j, 2 * self.mu * ep.get(i, j) + (self.lam * tre if i == j else Real(0)))
            # forces of -R Sp: H = +W R Sp Dm^-T
            var h = (r * sp) * t.dm_inv.transpose()
            var w = t.vol
            var f1 = Vec3(w * h.get(0, 0), w * h.get(1, 0), w * h.get(2, 0), 0)
            var f2 = Vec3(w * h.get(0, 1), w * h.get(1, 1), w * h.get(2, 1), 0)
            var f3 = Vec3(w * h.get(0, 2), w * h.get(1, 2), w * h.get(2, 2), 0)
            var f0 = (f1 + f2 + f3) * Real(-1)
            fx[t.a] += f0[0]
            fy[t.a] += f0[1]
            fz[t.a] += f0[2]
            fx[t.b] += f1[0]
            fy[t.b] += f1[1]
            fz[t.b] += f1[2]
            fx[t.c] += f2[0]
            fy[t.c] += f2[1]
            fz[t.c] += f2[2]
            fx[t.d] += f3[0]
            fy[t.d] += f3[1]
            fz[t.d] += f3[2]

    def _plastic_mat(self, e: Int) -> Mat3:
        var m = Mat3()
        m.set(0, 0, self.plastic[6 * e])
        m.set(1, 1, self.plastic[6 * e + 1])
        m.set(2, 2, self.plastic[6 * e + 2])
        m.set(0, 1, self.plastic[6 * e + 3])
        m.set(1, 0, self.plastic[6 * e + 3])
        m.set(0, 2, self.plastic[6 * e + 4])
        m.set(2, 0, self.plastic[6 * e + 4])
        m.set(1, 2, self.plastic[6 * e + 5])
        m.set(2, 1, self.plastic[6 * e + 5])
        return m

    def strain(self, e: Int) -> Mat3:
        """Co-rotated strain of tet `e`: sym(R^T F) - I."""
        ref t = self.tets[e]
        var pa = self.pos(t.a)
        var e1 = self.pos(t.b) - pa
        var e2 = self.pos(t.c) - pa
        var e3 = self.pos(t.d) - pa
        var ds = Mat3()
        for k in range(3):
            ds.set(k, 0, e1[k])
            ds.set(k, 1, e2[k])
            ds.set(k, 2, e3[k])
        var f = ds * t.dm_inv
        var r = polar_rotation(f) if self.corotational else Mat3.identity()
        var rtf = r.transpose() * f
        var out = Mat3()
        for i in range(3):
            for j in range(3):
                out.set(i, j, (rtf.get(i, j) + rtf.get(j, i)) * 0.5 - (Real(1) if i == j else Real(0)))
        return out

    def elastic_strain_norm(self, e: Int) -> Real:
        var eps = self.strain(e)
        var acc = Real(0)
        var has = len(self.plastic) > 0
        for i in range(3):
            for j in range(3):
                var v = eps.get(i, j)
                if has:
                    v -= self._plastic_mat(e).get(i, j)
                acc += v * v
        return sqrt(acc)

    def plastic_flow(mut self):
        """One plastic update (called by `step_ext`)."""
        if len(self.plastic) == 0:
            return
        for e in range(len(self.tets)):
            var eps = self.strain(e)
            var ep = self._plastic_mat(e)
            var el = Mat3()
            var n2 = Real(0)
            for i in range(3):
                for j in range(3):
                    var v = eps.get(i, j) - ep.get(i, j)
                    el.set(i, j, v)
                    n2 += v * v
            var n = sqrt(n2)
            if n <= self.yield_strain:
                continue
            var k = self.creep * (1 - self.yield_strain / n)
            var q = List[Real](length=6, fill=0)
            q[0] = ep.get(0, 0) + k * el.get(0, 0)
            q[1] = ep.get(1, 1) + k * el.get(1, 1)
            q[2] = ep.get(2, 2) + k * el.get(2, 2)
            q[3] = ep.get(0, 1) + k * el.get(0, 1)
            q[4] = ep.get(0, 2) + k * el.get(0, 2)
            q[5] = ep.get(1, 2) + k * el.get(1, 2)
            var pn = sqrt(q[0] * q[0] + q[1] * q[1] + q[2] * q[2] + 2 * (q[3] * q[3] + q[4] * q[4] + q[5] * q[5]))
            if pn > self.max_plastic and pn > 0:
                for c in range(6):
                    q[c] *= self.max_plastic / pn
            for c in range(6):
                self.plastic[6 * e + c] = q[c]

    def remove_overstrained(mut self, max_strain: Real) raises -> Int:
        """Element-removal fracture (17.58): delete every tet whose elastic
        strain norm exceeds `max_strain`; returns how many. Node masses are
        kept (a node left without tets flies free). Raises on max_strain
        <= 0."""
        if not (max_strain > 0):
            raise Error("FemBody.remove_overstrained: max_strain must be > 0")
        var keep = List[Tet]()
        var keep_p = List[Real]()
        var gone = 0
        for e in range(len(self.tets)):
            if self.elastic_strain_norm(e) > max_strain:
                gone += 1
                continue
            keep.append(self.tets[e])
            if len(self.plastic) > 0:
                for c in range(6):
                    keep_p.append(self.plastic[6 * e + c])
        if gone > 0:
            self.tets = keep^
            if len(self.plastic) > 0:
                self.plastic = keep_p^
        return gone

    def elastic_forces(self, mut fx: List[Real], mut fy: List[Real], mut fz: List[Real]):
        """Accumulate co-rotational elastic forces into the given arrays."""
        for ref t in self.tets:
            var pa = self.pos(t.a)
            var e1 = self.pos(t.b) - pa
            var e2 = self.pos(t.c) - pa
            var e3 = self.pos(t.d) - pa
            var ds = Mat3()
            for k in range(3):
                ds.set(k, 0, e1[k])
                ds.set(k, 1, e2[k])
                ds.set(k, 2, e3[k])
            var f = ds * t.dm_inv  # deformation gradient
            var r = polar_rotation(f) if self.corotational else Mat3.identity()
            # P = 2 mu (F - R) + lambda tr(R^T F - I) R
            var rtf = r.transpose() * f
            var tr = rtf.get(0, 0) + rtf.get(1, 1) + rtf.get(2, 2) - 3.0
            var p = Mat3()
            for i in range(3):
                for j in range(3):
                    p.set(
                        i, j,
                        2 * self.mu * (f.get(i, j) - r.get(i, j))
                        + self.lam * tr * r.get(i, j),
                    )
            # H = -W P Dm^-T ; its columns are the forces on nodes b, c, d
            var h = p * t.dm_inv.transpose()
            var w = t.vol
            var f1 = Vec3(-w * h.get(0, 0), -w * h.get(1, 0), -w * h.get(2, 0), 0)
            var f2 = Vec3(-w * h.get(0, 1), -w * h.get(1, 1), -w * h.get(2, 1), 0)
            var f3 = Vec3(-w * h.get(0, 2), -w * h.get(1, 2), -w * h.get(2, 2), 0)
            var f0 = (f1 + f2 + f3) * Real(-1)
            fx[t.a] += f0[0]
            fy[t.a] += f0[1]
            fz[t.a] += f0[2]
            fx[t.b] += f1[0]
            fy[t.b] += f1[1]
            fz[t.b] += f1[2]
            fx[t.c] += f2[0]
            fy[t.c] += f2[1]
            fz[t.c] += f2[2]
            fx[t.d] += f3[0]
            fy[t.d] += f3[1]
            fz[t.d] += f3[2]

    def step_implicit(
        mut self, dt: Real, gravity: Vec3, floor_y: Real = -1e30,
        tol: Real = 1e-4, max_iters: Int = 64,
    ) -> CgResult:
        """Backward Euler on the linearised system (Baraff-Witkin).

            (M - dt^2 df/dx) dv = dt (f0 + dt (df/dx) v0)

        solved matrix-free by conjugate gradients. No global stiffness matrix is
        ever assembled — the operator loops over elements, which is the whole
        reason `LinearOperator` asks for `apply` rather than for a matrix.

        The point is the step size. The explicit integrator's stable dt is set
        by the stiffest element, so a stiff material forces small steps no
        matter how coarse the mesh is; the implicit one is unconditionally
        stable and its cost per step is the CG solve. `test_numerics` runs both at
        a dt the explicit path cannot survive.

        Returns the solver's own report, so a caller can tell a converged step
        from one that ran out of iterations."""
        var n = self.node_count()
        var dof = 3 * n
        var fx = List[Real]()
        var fy = List[Real]()
        var fz = List[Real]()
        for _ in range(n):
            fx.append(0)
            fy.append(0)
            fz.append(0)
        self.elastic_forces(fx, fy, fz)
        if len(self.plastic) > 0:
            self.plastic_forces(fx, fy, fz)

        var v0 = List[Real](capacity=dof)
        for i in range(n):
            v0.append(self.vx[i])
            v0.append(self.vy[i])
            v0.append(self.vz[i])
        var op = FemImplicitOp(self, dt)
        var kv = List[Real](capacity=dof)
        for _ in range(dof):
            kv.append(0)
        op.stiffness_apply(v0, kv)

        var b = List[Real](capacity=dof)
        for i in range(n):
            if self.inv_m[i] == 0:
                # pinned: the row is the identity and the right-hand side is
                # zero, so dv is exactly zero and the constraint is exact
                # rather than enforced afterwards
                b.append(0)
                b.append(0)
                b.append(0)
                continue
            var m = Real(1) / self.inv_m[i]
            b.append(dt * (fx[i] + m * gravity[0] + dt * kv[3 * i]))
            b.append(dt * (fy[i] + m * gravity[1] + dt * kv[3 * i + 1]))
            b.append(dt * (fz[i] + m * gravity[2] + dt * kv[3 * i + 2]))

        var dv = List[Real](capacity=dof)
        for _ in range(dof):
            dv.append(0)
        var res: CgResult
        if self.solver == FEM_SOLVE_CG:
            res = cg(op, b, dv, tol, max_iters)
        else:
            var a = op.assemble()
            if self.solver == FEM_SOLVE_CHOLESKY:
                var ch = SparseCholesky()
                try:
                    ch.factor(a, rcm_order(a))
                    ch.solve(b, dv)
                    res = CgResult(True, False, 1, 0)
                except:
                    res = CgResult(False, True, 0, 1)
            else:
                var ic = IncompleteCholesky(a)
                res = pcg_ic0(a, ic, b, dv, tol, max_iters)

        # audit E19: `CgResult.converged` is documented (numerics/cg.mojo)
        # as "the only field a caller may treat as permission to use the
        # [result]" -- this used to apply `dv` unconditionally, so a
        # diverged/stalled solve's garbage delta landed on every node's
        # velocity and position before the caller ever saw `res`. Numerical
        # failure recovers locally (docs/ARCHITECTURE.md S2): skip the
        # update entirely (this step's elastic response is dropped, not
        # corrupted -- the body keeps last step's state and tries again next
        # step) and count it; the world keeps stepping either way, and the
        # caller can still inspect the returned `res` for its own purposes.
        if not res.converged:
            self.counters.incr(CG_NOT_CONVERGED)
            return res
        var damp = Real(1.0) / (1.0 + self.damping * dt)
        for i in range(n):
            if self.inv_m[i] == 0:
                self.vx[i] = 0
                self.vy[i] = 0
                self.vz[i] = 0
                continue
            self.vx[i] = (self.vx[i] + dv[3 * i]) * damp
            self.vy[i] = (self.vy[i] + dv[3 * i + 1]) * damp
            self.vz[i] = (self.vz[i] + dv[3 * i + 2]) * damp
            self.x[i] += self.vx[i] * dt
            self.y[i] += self.vy[i] * dt
            self.z[i] += self.vz[i] * dt
            if self.y[i] < floor_y:
                self.y[i] = floor_y
                if self.vy[i] < 0:
                    self.vy[i] = 0
        return res

    def step_ext(mut self, dt: Real, gravity: Vec3, floor_y: Real = -1e30):
        """`step` with plasticity (17.58) and active muscle fibres (17.57)
        when they are set. A separate method because `step` stays exactly
        as it was: any branch added to its body, even an early return that
        is never taken, changed how the explicit integrator compiled and
        moved `test_thermal`'s last digits (0.011999987 -> 0.0119999945).
        `step` ignores both; with neither set this is `step`."""
        var has_p = len(self.plastic) > 0
        var has_f = len(self.fiber) > 0 and self.activation > 0
        if not has_p and not has_f:
            self.step(dt, gravity, floor_y)
            return
        var n = self.node_count()
        var fx = List[Real](length=n, fill=0)
        var fy = List[Real](length=n, fill=0)
        var fz = List[Real](length=n, fill=0)
        self.elastic_forces(fx, fy, fz)
        if has_p:
            self.plastic_forces(fx, fy, fz)
        if has_f:
            self.active_forces(fx, fy, fz)
        self.integrate(fx, fy, fz, dt, gravity, floor_y)
        if has_p:
            self.plastic_flow()

    def set_fibers(mut self, dirs: List[Vec3], sigma_max: Real) raises:
        """Muscle fibres (17.57, Teran et al. 2005 style active stress): a
        rest-frame direction per tet and the peak active stress (Pa). With
        activation a in [0, 1] (`activation`), `step_ext` adds the first
        Piola stress P = a sigma_max (F d) (x) d: tension along the fibre,
        so the tissue shortens along d and, nearly incompressible, bulges
        across it. Raises on a direction count != tets or sigma_max < 0."""
        if len(dirs) != len(self.tets) or not (sigma_max >= 0):
            raise Error("FemBody.set_fibers: one direction per tet and sigma_max >= 0")
        self.fiber = List[Real](capacity=3 * len(dirs))
        for d in dirs:
            var l = sqrt(d[0] * d[0] + d[1] * d[1] + d[2] * d[2])
            if not (l > 0):
                raise Error("FemBody.set_fibers: zero fibre direction")
            self.fiber.append(d[0] / l)
            self.fiber.append(d[1] / l)
            self.fiber.append(d[2] / l)
        self.sigma_max = sigma_max

    def active_forces(self, mut fx: List[Real], mut fy: List[Real], mut fz: List[Real]):
        """Forces of the active fibre stress (see `set_fibers`)."""
        var a = min(max(self.activation, Real(0)), Real(1))
        for e in range(len(self.tets)):
            ref t = self.tets[e]
            var pa = self.pos(t.a)
            var e1 = self.pos(t.b) - pa
            var e2 = self.pos(t.c) - pa
            var e3 = self.pos(t.d) - pa
            var ds = Mat3()
            for k in range(3):
                ds.set(k, 0, e1[k])
                ds.set(k, 1, e2[k])
                ds.set(k, 2, e3[k])
            var f = ds * t.dm_inv
            var d = Vec3(self.fiber[3 * e], self.fiber[3 * e + 1], self.fiber[3 * e + 2], 0)
            var fd = Vec3(0, 0, 0, 0)
            for i in range(3):
                fd[i] = f.get(i, 0) * d[0] + f.get(i, 1) * d[1] + f.get(i, 2) * d[2]
            var p = Mat3()
            for i in range(3):
                for j in range(3):
                    p.set(i, j, a * self.sigma_max * fd[i] * d[j])
            var h = p * t.dm_inv.transpose()
            var w = t.vol
            var f1 = Vec3(-w * h.get(0, 0), -w * h.get(1, 0), -w * h.get(2, 0), 0)
            var f2 = Vec3(-w * h.get(0, 1), -w * h.get(1, 1), -w * h.get(2, 1), 0)
            var f3 = Vec3(-w * h.get(0, 2), -w * h.get(1, 2), -w * h.get(2, 2), 0)
            var f0 = (f1 + f2 + f3) * Real(-1)
            fx[t.a] += f0[0]
            fy[t.a] += f0[1]
            fz[t.a] += f0[2]
            fx[t.b] += f1[0]
            fy[t.b] += f1[1]
            fz[t.b] += f1[2]
            fx[t.c] += f2[0]
            fy[t.c] += f2[1]
            fz[t.c] += f2[2]
            fx[t.d] += f3[0]
            fy[t.d] += f3[1]
            fz[t.d] += f3[2]

    def step(mut self, dt: Real, gravity: Vec3, floor_y: Real = -1e30):
        var n = self.node_count()
        var fx = List[Real]()
        var fy = List[Real]()
        var fz = List[Real]()
        for _ in range(n):
            fx.append(0)
            fy.append(0)
            fz.append(0)
        self.elastic_forces(fx, fy, fz)
        self.integrate(fx, fy, fz, dt, gravity, floor_y)

    def integrate(
        mut self, fx: List[Real], fy: List[Real], fz: List[Real],
        dt: Real, gravity: Vec3, floor_y: Real,
    ):
        """Symplectic Euler with the given elastic forces (shared by `step`
        and `fem_material.step_material`)."""
        for i in range(self.node_count()):
            if self.inv_m[i] == 0:
                self.vx[i] = 0
                self.vy[i] = 0
                self.vz[i] = 0
                continue
            var im = self.inv_m[i]
            self.vx[i] += (fx[i] * im + gravity[0]) * dt
            self.vy[i] += (fy[i] * im + gravity[1]) * dt
            self.vz[i] += (fz[i] * im + gravity[2]) * dt
            # mass-proportional damping keeps the explicit integrator usable
            var d = 1.0 / (1.0 + self.damping * dt)
            self.vx[i] *= d
            self.vy[i] *= d
            self.vz[i] *= d
            self.x[i] += self.vx[i] * dt
            self.y[i] += self.vy[i] * dt
            self.z[i] += self.vz[i] * dt
            if self.y[i] < floor_y:
                self.y[i] = floor_y
                if self.vy[i] < 0:
                    self.vy[i] = 0


struct FemImplicitOp(LinearOperator, Movable, Deinitable):
    """`A = M - dt^2 df/dx`, applied without ever forming it.

    The per-element rotations are SNAPSHOT at construction rather than
    recomputed inside `apply`. That is not a cache — it is the warped-stiffness
    assumption written into the data layout. Holding R fixed for the duration of
    the solve is what makes the operator symmetric, and recomputing it per CG
    iteration would silently change the operator between iterations, which is
    the one thing a Krylov method cannot tolerate. It is also cheaper: the polar
    decomposition runs once per step instead of once per iteration."""

    var n: Int
    var dt: Real
    var mu: Real
    var lam: Real
    var tet_idx: List[Int]  # 4 per element
    var rot: List[Real]  # 9 per element, row-major
    var dm_inv: List[Real]  # 9 per element, row-major
    var vol: List[Real]
    var mass: List[Real]  # per node; 0 marks a pinned node

    def __init__(out self, body: FemBody, dt: Real):
        self.n = body.node_count()
        self.dt = dt
        self.mu = body.mu
        self.lam = body.lam
        var nt = len(body.tets)
        self.tet_idx = List[Int](capacity=4 * nt)
        self.rot = List[Real](capacity=9 * nt)
        self.dm_inv = List[Real](capacity=9 * nt)
        self.vol = List[Real](capacity=nt)
        for ref t in body.tets:
            self.tet_idx.append(t.a)
            self.tet_idx.append(t.b)
            self.tet_idx.append(t.c)
            self.tet_idx.append(t.d)
            var pa = body.pos(t.a)
            var e1 = body.pos(t.b) - pa
            var e2 = body.pos(t.c) - pa
            var e3 = body.pos(t.d) - pa
            var ds = Mat3()
            for k in range(3):
                ds.set(k, 0, e1[k])
                ds.set(k, 1, e2[k])
                ds.set(k, 2, e3[k])
            var f = ds * t.dm_inv
            var r = polar_rotation(f) if body.corotational else Mat3.identity()
            for i in range(3):
                for j in range(3):
                    self.rot.append(r.get(i, j))
                    self.dm_inv.append(t.dm_inv.get(i, j))
            self.vol.append(t.vol)
        self.mass = List[Real](capacity=self.n)
        for i in range(self.n):
            self.mass.append(
                Real(0) if body.inv_m[i] == 0 else Real(1) / body.inv_m[i]
            )

    def _mat(self, src: List[Real], e: Int) -> Mat3:
        var m = Mat3()
        for i in range(3):
            for j in range(3):
                m.set(i, j, src[9 * e + 3 * i + j])
        return m

    def size(self) -> Int:
        return 3 * self.n

    def stiffness_apply(self, du: List[Real], mut out: List[Real]):
        """`out = (df/dx) du` — the differential of the co-rotational elastic
        force at the snapshot rotations. Mirrors `FemBody.elastic_forces` term
        for term with F replaced by its differential and the constant terms
        dropped."""
        for i in range(len(out)):
            out[i] = 0
        for e in range(len(self.vol)):
            var a = self.tet_idx[4 * e]
            var b = self.tet_idx[4 * e + 1]
            var c = self.tet_idx[4 * e + 2]
            var d = self.tet_idx[4 * e + 3]
            var d1 = Vec3(du[3 * b] - du[3 * a], du[3 * b + 1] - du[3 * a + 1], du[3 * b + 2] - du[3 * a + 2], 0)
            var d2 = Vec3(du[3 * c] - du[3 * a], du[3 * c + 1] - du[3 * a + 1], du[3 * c + 2] - du[3 * a + 2], 0)
            var d3 = Vec3(du[3 * d] - du[3 * a], du[3 * d + 1] - du[3 * a + 1], du[3 * d + 2] - du[3 * a + 2], 0)
            var f = self._elem_forces(e, d1, d2, d3)
            comptime for k in range(3):
                out[3 * a + k] += f[0][k]
                out[3 * b + k] += f[1][k]
                out[3 * c + k] += f[2][k]
                out[3 * d + k] += f[3][k]

    def _elem_forces(self, e: Int, d1: Vec3, d2: Vec3, d3: Vec3) -> Tuple[Vec3, Vec3, Vec3, Vec3]:
        """Force differentials on element e's four nodes for edge
        differentials d1 = du_b - du_a, d2 = du_c - du_a, d3 = du_d - du_a."""
        var r = self._mat(self.rot, e)
        var dmi = self._mat(self.dm_inv, e)
        var dds = Mat3()
        for k in range(3):
            dds.set(k, 0, d1[k])
            dds.set(k, 1, d2[k])
            dds.set(k, 2, d3[k])
        var dfm = r.transpose() * (dds * dmi)
        var tr = dfm.get(0, 0) + dfm.get(1, 1) + dfm.get(2, 2)
        var dp = Mat3()
        for i in range(3):
            for j in range(3):
                var lamterm = self.lam * tr if i == j else Real(0)
                dp.set(i, j, 2 * self.mu * dfm.get(i, j) + lamterm)
        var h = (r * dp) * dmi.transpose()
        var w = self.vol[e]
        var f1 = Vec3(-w * h.get(0, 0), -w * h.get(1, 0), -w * h.get(2, 0), 0)
        var f2 = Vec3(-w * h.get(0, 1), -w * h.get(1, 1), -w * h.get(2, 1), 0)
        var f3 = Vec3(-w * h.get(0, 2), -w * h.get(1, 2), -w * h.get(2, 2), 0)
        var f0 = (f1 + f2 + f3) * Real(-1)
        return (f0, f1, f2, f3)

    def assemble(self) -> CsrMatrix:
        """`A = M - dt^2 df/dx` as a sparse matrix (17.84), element by element
        from the same force differential `stiffness_apply` uses. Rows and
        columns of pinned nodes are dropped (identity rows), so A is
        symmetric; its solution equals `apply`'s on every free node."""
        var rows = List[Int]()
        var cols = List[Int]()
        var vals = List[Real]()
        var dt2 = self.dt * self.dt
        for i in range(self.n):
            comptime for k in range(3):
                rows.append(3 * i + k)
                cols.append(3 * i + k)
                vals.append(Real(1) if self.mass[i] == 0 else self.mass[i])
        var zero = Vec3(0, 0, 0, 0)
        for e in range(len(self.vol)):
            var nodes = List[Int]()
            for q in range(4):
                nodes.append(self.tet_idx[4 * e + q])
            for q in range(4):
                if self.mass[nodes[q]] == 0:
                    continue
                for k in range(3):
                    # column: unit displacement of node q along axis k
                    var u = Vec3(0, 0, 0, 0)
                    u[k] = 1
                    var d1 = u * Real(-1) if q == 0 else (u if q == 1 else zero)
                    var d2 = u * Real(-1) if q == 0 else (u if q == 2 else zero)
                    var d3 = u * Real(-1) if q == 0 else (u if q == 3 else zero)
                    var f = self._elem_forces(e, d1, d2, d3)
                    var fl: List[Vec3] = [f[0], f[1], f[2], f[3]]
                    for rnode in range(4):
                        var ri = nodes[rnode]
                        if self.mass[ri] == 0:
                            continue
                        comptime for kk in range(3):
                            var fv = fl[rnode][kk]
                            if fv != 0:
                                rows.append(3 * ri + kk)
                                cols.append(3 * nodes[q] + k)
                                vals.append(-dt2 * fv)
        return CsrMatrix.from_triplets(3 * self.n, rows, cols, vals)

    def apply(self, x: List[Real], mut out: List[Real]):
        self.stiffness_apply(x, out)
        var dt2 = self.dt * self.dt
        for i in range(self.n):
            if self.mass[i] == 0:
                # A pinned node's row is the identity, so its dv comes out
                # exactly zero. Leaving mass * dv there would let the solver
                # push a node that is supposed to be nailed down.
                comptime for k in range(3):
                    out[3 * i + k] = x[3 * i + k]
                continue
            comptime for k in range(3):
                out[3 * i + k] = self.mass[i] * x[3 * i + k] - dt2 * out[3 * i + k]

    def diagonal(self, mut out: List[Real]):
        """Mass only. The stiffness diagonal would need a per-element pass of
        its own; mass alone already captures the part that varies most — a
        pinned node against a free one, which is the ratio Jacobi exists for."""
        for i in range(self.n):
            var d = Real(1) if self.mass[i] == 0 else self.mass[i]
            comptime for k in range(3):
                out[3 * i + k] = d


def _lat_idx(i: Int, j: Int, k: Int, ny: Int, nz: Int) -> Int:
    """Lattice node index. Module level: a nested def cannot infer the capture
    convention of an outer `var` on this nightly."""
    return (i * (ny + 1) + j) * (nz + 1) + k


def make_beam(
    mut b: FemBody, nx: Int, ny: Int, nz: Int, h: Real, mass_per_node: Real
):
    """A box lattice split into 5 tetrahedra per cell, the standard
    decomposition that tiles without leaving gaps."""
    for i in range(nx + 1):
        for j in range(ny + 1):
            for k in range(nz + 1):
                b.add_node(
                    Vec3(Real(i) * h, Real(j) * h, Real(k) * h, 0), mass_per_node
                )
    for i in range(nx):
        for j in range(ny):
            for k in range(nz):
                var v000 = _lat_idx(i, j, k, ny, nz)
                var v100 = _lat_idx(i + 1, j, k, ny, nz)
                var v010 = _lat_idx(i, j + 1, k, ny, nz)
                var v001 = _lat_idx(i, j, k + 1, ny, nz)
                var v110 = _lat_idx(i + 1, j + 1, k, ny, nz)
                var v101 = _lat_idx(i + 1, j, k + 1, ny, nz)
                var v011 = _lat_idx(i, j + 1, k + 1, ny, nz)
                var v111 = _lat_idx(i + 1, j + 1, k + 1, ny, nz)
                # alternate the split so neighbouring cells share faces
                if (i + j + k) % 2 == 0:
                    b.add_tet(v000, v100, v010, v001)
                    b.add_tet(v100, v110, v010, v111)
                    b.add_tet(v100, v010, v001, v111)
                    b.add_tet(v010, v011, v001, v111)
                    b.add_tet(v100, v001, v101, v111)
                else:
                    b.add_tet(v100, v000, v110, v101)
                    b.add_tet(v000, v010, v110, v011)
                    b.add_tet(v000, v001, v101, v011)
                    b.add_tet(v110, v101, v011, v111)
                    b.add_tet(v000, v110, v101, v011)


def fem_from_tetmesh(mut b: FemBody, m: TetMesh, density: Real) raises:
    """Add a `geometry.tetmesh.TetMesh` to `b`: one node per mesh point with
    its lumped mass (a quarter of each adjacent tet's density x volume), one
    element per tet. Node indices are the mesh's, offset by the nodes `b`
    already had. Raises on density <= 0."""
    if not (density > 0):
        raise Error("fem_from_tetmesh: density must be > 0")
    var base = b.node_count()
    var mass = List[Real](length=len(m.pts), fill=0)
    for t in range(m.tet_count()):
        var q = abs(m.tet_volume(t)) * density / 4
        for k in range(4):
            mass[m.tets[4 * t + k]] += q
    for i in range(len(m.pts)):
        b.add_node(m.pts[i], max(mass[i], Real(1e-12)))
    for t in range(m.tet_count()):
        b.add_tet(base + m.tets[4 * t], base + m.tets[4 * t + 1], base + m.tets[4 * t + 2], base + m.tets[4 * t + 3])
