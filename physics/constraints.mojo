"""One solver for every constraint the engine has: equality, joint limits,
dry friction, and contact with friction.

The engine solved these in separate passes — limits in `resolve_limits`,
contacts in `resolve_contacts` — and separate passes fight. A limit pass that
runs after a contact pass undoes some of the contact impulse, the contact pass
next step undoes some of the limit impulse, and the visible result is a foot
that buzzes against a joint stop. Putting every row in ONE system means each
impulse is computed knowing what the others are doing.

The rows differ only in how their impulse is projected:

    equality       unbounded          a bilateral constraint pushes both ways
    joint limit    f >= 0             a stop pushes, it does not pull
    friction loss  |f| <= f_max       a box: dry friction with a fixed cap
    contact normal f >= 0             same as a limit, different Jacobian
    contact firct. |f| <= mu * f_n    a cone whose size follows the normal

so the solver is one projected Gauss-Seidel loop with a per-row projection,
not four algorithms sharing a file.

The last row is where the interesting choice lives, and it is exposed as a
seam. A PYRAMIDAL cone bounds each tangent component separately, which is
cheap and is what most solvers do; its cost is that the admissible set is a
square, so friction along a diagonal of the tangent basis can reach sqrt(2)
times the limit. An ELLIPTIC cone bounds the tangent vector's magnitude,
which is what Coulomb friction actually says. The difference is not subtle
and it is not a tolerance: it makes sliding friction depend on the direction
of travel relative to an arbitrary basis. `bench_constraints` measures that
anisotropy directly.
"""

from std.math import sqrt, isfinite
from geometry.vec import Real, Vec3, length
from numerics.bicgstab import bicgstab
from numerics.dense import solve_dense
from numerics.sparse import LinearOperator
from physics.chain import Chain

comptime CON_EQUALITY = 0
comptime CON_LIMIT = 1
comptime CON_FRICTION_LOSS = 2
comptime CON_CONTACT = 3
comptime CON_TANGENT = 4

comptime CONE_PYRAMIDAL = 0
comptime CONE_ELLIPTIC = 1

# ROADMAP 17.51: how `resolve_loops` solves its rows
comptime SOLVE_PGS = 0
comptime SOLVE_DIRECT = 1  # `solve_active_set`
comptime SOLVE_CG = 2  # `solve_cg`


@fieldwise_init
struct ConRow(Copyable, ImplicitlyCopyable, Movable):
    """One scalar constraint. Its Jacobian row is not stored here: row `r`
    of the owning `ConstraintSet` lives at `jac[r * n + i]` (row-major,
    `i` over the `n` generalised coordinates)."""

    var kind: Int
    var bias: Real  # target residual velocity (Baumgarte / restitution)
    var cap: Real  # friction-loss bound; ignored otherwise
    var normal_row: Int  # for CON_TANGENT: which normal scales the cone
    var mu: Real
    var partner: Int  # for CON_TANGENT: the other tangent of the same contact


struct ConstraintSet(Movable, Deinitable):
    """Rows over a system described only by its mass matrix and velocity.

    Deliberately not tied to `Chain`. A constraint solver that knows what a
    joint is cannot be tested against a system with an analytic answer, and
    the friction-cone question in particular needs one: a free body has
    `H = m I`, so the exact stopping distance is a closed form and the
    anisotropy measurement has something to be anisotropic against."""

    var n: Int  # generalised coordinates
    var jac: List[Real]  # rows * n, row-major
    var rows: List[ConRow]
    var force: List[Real]  # accumulated impulse per row
    var cone: Int

    def __init__(out self, n: Int):
        self.n = n
        self.jac = List[Real]()
        self.rows = List[ConRow]()
        self.force = List[Real]()
        self.cone = CONE_ELLIPTIC

    def count(self) -> Int:
        return len(self.rows)

    def add(mut self, jac: List[Real], row: ConRow) raises -> Int:
        if len(jac) != self.n:
            raise Error("constraint Jacobian must have one entry per coordinate")
        for i in range(self.n):
            self.jac.append(jac[i])
        self.rows.append(row)
        self.force.append(0)
        return len(self.rows) - 1

    def add_equality(mut self, jac: List[Real], bias: Real) raises -> Int:
        return self.add(jac, ConRow(CON_EQUALITY, bias, 0, -1, 0, -1))

    def add_limit(mut self, jac: List[Real], bias: Real) raises -> Int:
        return self.add(jac, ConRow(CON_LIMIT, bias, 0, -1, 0, -1))

    def add_friction_loss(mut self, jac: List[Real], cap: Real) raises -> Int:
        return self.add(jac, ConRow(CON_FRICTION_LOSS, 0, cap, -1, 0, -1))

    def add_contact(mut self, jac: List[Real], bias: Real) raises -> Int:
        return self.add(jac, ConRow(CON_CONTACT, bias, 0, -1, 0, -1))

    def add_tangents(
        mut self, jt1: List[Real], jt2: List[Real], normal_row: Int, mu: Real
    ) raises -> Int:
        """The two tangent rows of a contact, added together because the
        elliptic projection needs both at once — a cone is a statement about
        the pair, and adding them one at a time would make it impossible to
        express."""
        var a = self.add(jt1, ConRow(CON_TANGENT, 0, 0, normal_row, mu, -1))
        var b = self.add(jt2, ConRow(CON_TANGENT, 0, 0, normal_row, mu, a))
        self.rows[a] = ConRow(CON_TANGENT, 0, 0, normal_row, mu, b)
        return a

    def residual(self, qd: List[Real]) -> Real:
        """Largest row violation at `qd`: |J qd - bias| for equalities,
        how far J qd falls short of `bias` for limits and contact normals
        (17.51; tangent / friction rows are not counted)."""
        var worst = Real(0)
        for r in range(len(self.rows)):
            var k = self.rows[r].kind
            var e = self._row_dot(r, qd) - self.rows[r].bias
            if k == CON_EQUALITY:
                worst = max(worst, abs(e))
            elif k == CON_LIMIT or k == CON_CONTACT:
                worst = max(worst, -e)
        return worst

    def _minv_jt(self, hmat: List[Real]) -> List[Real]:
        var m = len(self.rows)
        var out = List[Real](length=m * self.n, fill=0)
        for r in range(m):
            var rhs = List[Real](capacity=self.n)
            for i in range(self.n):
                rhs.append(self.jac[r * self.n + i])
            var col = solve_dense(hmat.copy(), rhs^, self.n)
            for i in range(self.n):
                out[r * self.n + i] = col[i]
        return out^

    def solve_active_set(mut self, var hmat: List[Real], mut qd: List[Real], max_iter: Int = 20) raises -> Int:
        """Exact solve (17.51, the Newton-type alternative to PGS): with the
        set of active rows fixed the impulses solve the dense system
        J_a H^-1 J_a^T f = bias_a - J_a qd exactly; a limit / contact row is
        then dropped if its impulse pulls and added if it is violated, until
        nothing changes. Equality, limit and contact rows only (friction
        cones stay with `solve`). Returns the number of active-set rounds."""
        var m = len(self.rows)
        if m == 0:
            return 0
        for r in range(m):
            var k = self.rows[r].kind
            if k != CON_EQUALITY and k != CON_LIMIT and k != CON_CONTACT:
                raise Error("ConstraintSet.solve_active_set: equality, limit and contact rows only")
        var mj = self._minv_jt(hmat)
        var qd0 = qd.copy()
        # a row no coordinate can move (J H^-1 J^T = 0: the z row of a loop
        # closed in a planar chain) is left out -- it would make the system
        # singular and no impulse can change it anyway
        var diag = List[Real](length=m, fill=0)
        var dmax = Real(0)
        for r in range(m):
            for i in range(self.n):
                diag[r] += self.jac[r * self.n + i] * mj[r * self.n + i]
            dmax = max(dmax, diag[r])
        var movable = List[Bool](length=m, fill=True)
        for r in range(m):
            movable[r] = diag[r] > dmax * Real(1e-9)
        var active = List[Bool](length=m, fill=False)
        for r in range(m):
            active[r] = movable[r] and (self.rows[r].kind == CON_EQUALITY or self._row_dot(r, qd0) < self.rows[r].bias)
        var rounds = 0
        for _ in range(max_iter):
            rounds += 1
            var idx = List[Int]()
            for r in range(m):
                if active[r]:
                    idx.append(r)
            var na = len(idx)
            var f = List[Real](length=m, fill=0)
            if na > 0:
                var a = List[Real](length=na * na, fill=0)
                var b = List[Real](length=na, fill=0)
                for p in range(na):
                    var rp = idx[p]
                    b[p] = self.rows[rp].bias - self._row_dot(rp, qd0)
                    for q in range(na):
                        var rq = idx[q]
                        var acc = Real(0)
                        for i in range(self.n):
                            acc += self.jac[rp * self.n + i] * mj[rq * self.n + i]
                        a[p * na + q] = acc
                var sol = solve_dense(a.copy(), b.copy(), na)
                var finite = True
                for p in range(na):
                    if not isfinite(sol[p]):
                        finite = False
                if not finite:
                    # redundant rows (a loop closed twice) make the system
                    # singular: retry with a relative diagonal shift (1e-5
                    # softening; an absolute 1e-9 still gave NaN in f32).
                    # Only then -- on a regular system the shift raised the
                    # residual from 5.5e-6 to 6.2e-4 (`test_loops`).
                    for p in range(na):
                        a[p * na + p] += max(a[p * na + p] * Real(1e-5), Real(1e-12))
                    sol = solve_dense(a^, b^, na)
                for p in range(na):
                    f[idx[p]] = sol[p]
            for i in range(self.n):
                var v = qd0[i]
                for r in range(m):
                    if f[r] != 0:
                        v += mj[r * self.n + i] * f[r]
                qd[i] = v
            # one change per round: the most negative pulling row out, else
            # the most violated inactive row in
            var worst_r = -1
            var worst_v = Real(-1e-9)
            for r in range(m):
                if active[r] and self.rows[r].kind != CON_EQUALITY and f[r] < worst_v:
                    worst_v = f[r]
                    worst_r = r
            if worst_r >= 0:
                active[worst_r] = False
                continue
            var add_r = -1
            var add_v = Real(1e-7)
            for r in range(m):
                if not active[r] and movable[r]:
                    var short = self.rows[r].bias - self._row_dot(r, qd)
                    if short > add_v:
                        add_v = short
                        add_r = r
            if add_r < 0:
                for r in range(m):
                    self.force[r] = f[r]
                return rounds
            active[add_r] = True
        return rounds

    def solve_cg(mut self, var hmat: List[Real], mut qd: List[Real], iters: Int = 50, tol: Real = 1e-10) raises -> Int:
        """Conjugate gradient on J H^-1 J^T f = bias - J qd (17.51), equality
        rows only (the operator is symmetric positive semi-definite there).
        Matrix-free: one J (H^-1 J^T p) product per iteration. Returns the
        iterations taken."""
        var m = len(self.rows)
        if m == 0:
            return 0
        for r in range(m):
            if self.rows[r].kind != CON_EQUALITY:
                raise Error("ConstraintSet.solve_cg: equality rows only")
        var mj = self._minv_jt(hmat)
        var f = List[Real](length=m, fill=0)
        var res = List[Real](length=m, fill=0)
        for r in range(m):
            res[r] = self.rows[r].bias - self._row_dot(r, qd)
        var p = res.copy()
        var rr = Real(0)
        for r in range(m):
            rr += res[r] * res[r]
        var it = 0
        var ap = List[Real](length=m, fill=0)
        var tmp = List[Real](length=self.n, fill=0)
        while it < iters and rr > tol * tol:
            it += 1
            for i in range(self.n):
                var v = Real(0)
                for r in range(m):
                    v += mj[r * self.n + i] * p[r]
                tmp[i] = v
            var pap = Real(0)
            for r in range(m):
                ap[r] = self._row_dot(r, tmp)
                pap += p[r] * ap[r]
            if pap <= 1e-30:
                break
            var alpha = rr / pap
            var rr2 = Real(0)
            for r in range(m):
                f[r] += alpha * p[r]
                res[r] -= alpha * ap[r]
                rr2 += res[r] * res[r]
            var beta = rr2 / rr
            rr = rr2
            for r in range(m):
                p[r] = res[r] + beta * p[r]
        for i in range(self.n):
            var v = qd[i]
            for r in range(m):
                v += mj[r * self.n + i] * f[r]
            qd[i] = v
        for r in range(m):
            self.force[r] = f[r]
        return it

    def solve_cone_newton(
        mut self, var hmat: List[Real], mut qd: List[Real], max_iter: Int = 40, krylov: Bool = False
    ) raises -> Int:
        """Active-set Newton that keeps the friction cone (13.5).

        `solve_active_set` leaves the tangent rows out. This one keeps them.
        Each tangent group is STICK (its rows are equalities with target 0) or
        SLIDE (its impulse sits on the cone boundary, f_t = -mu f_n s, where s
        is the unit sliding direction, fixed within a round). Between rounds s
        is recomputed from the velocity, which is the Newton step on the cone.
        Substituting the boundary into the normal column makes the system
        non-symmetric, so it is solved by dense LU (`solve_dense`), not
        Cholesky. With `krylov` the same system goes to BiCGStab instead
        (13.5 CG column; `krylov` is an inner-solver flag, not a trait seam).

        One change per round, in this order: drop a normal that pulls, stick a
        sliding group whose velocity has reversed, slide a stuck group that
        left the cone, add a violated inactive normal. Returns the rounds used;
        a return equal to `max_iter` means the set did not settle.

        Friction-loss rows are not handled here (they raise). Cone type stays
        the runtime flag `self.cone`; it is not a trait seam."""
        var m = len(self.rows)
        if m == 0:
            return 0
        for r in range(m):
            var k = self.rows[r].kind
            if k != CON_EQUALITY and k != CON_LIMIT and k != CON_CONTACT and k != CON_TANGENT:
                raise Error("ConstraintSet.solve_cone_newton: friction-loss rows are not handled")
        var pyramidal = self.cone == CONE_PYRAMIDAL
        var mj = self._minv_jt(hmat)
        var qd0 = qd.copy()
        # gram[r * m + s] = J_r H^-1 J_s^T
        var gram = List[Real](length=m * m, fill=0)
        for r in range(m):
            for s in range(m):
                var acc = Real(0)
                for i in range(self.n):
                    acc += self.jac[r * self.n + i] * mj[s * self.n + i]
                gram[r * m + s] = acc
        # state 0: off; 1: active, impulse unknown; 2: sliding tangent
        var state = List[Int](length=m, fill=0)
        # sliding direction s_r: a sliding tangent has f_r = -mu f_n s_r
        var sdir = List[Real](length=m, fill=0)
        for r in range(m):
            var k = self.rows[r].kind
            if k == CON_EQUALITY:
                state[r] = 1
            elif (k == CON_LIMIT or k == CON_CONTACT) and self._row_dot(r, qd0) < self.rows[r].bias:
                state[r] = 1
        for r in range(m):
            if self.rows[r].kind == CON_TANGENT and state[self.rows[r].normal_row] == 1:
                state[r] = 1

        var f = List[Real](length=m, fill=0)
        var rounds = 0
        for _ in range(max_iter):
            rounds += 1
            var idx = List[Int](length=m, fill=-1)
            var u = List[Int]()
            for r in range(m):
                if state[r] == 1:
                    idx[r] = len(u)
                    u.append(r)
            var nu = len(u)
            for r in range(m):
                f[r] = 0
            if nu > 0:
                # rows of the unknown set: velocity J_p (qd0 + sum_s H^-1 J_s^T f_s) = bias_p.
                # a sliding tangent contributes -mu s f_n through its normal's unknown
                var a = List[Real](length=nu * nu, fill=0)
                var b = List[Real](length=nu, fill=0)
                for p in range(nu):
                    var rp = u[p]
                    b[p] = self.rows[rp].bias - self._row_dot(rp, qd0)
                    for s in range(m):
                        var g = gram[rp * m + s]
                        if state[s] == 1:
                            a[p * nu + idx[s]] += g
                        elif state[s] == 2:
                            var nrow = self.rows[s].normal_row
                            if state[nrow] == 1:
                                a[p * nu + idx[nrow]] += g * (-self.rows[s].mu * sdir[s])
                var sol: List[Real]
                if krylov:
                    var xk = List[Real](length=nu, fill=0)
                    var info = bicgstab(_DenseOp(a^, nu), b, xk, tol=1e-6)
                    if not info.converged:
                        raise Error("ConstraintSet.solve_cone_newton: BiCGStab did not converge")
                    sol = xk^
                else:
                    sol = solve_dense(a^, b^, nu)
                for p in range(nu):
                    f[u[p]] = sol[p]
            for s in range(m):
                if state[s] == 2:
                    var nrow = self.rows[s].normal_row
                    if state[nrow] == 1:
                        f[s] = -self.rows[s].mu * sdir[s] * f[nrow]
                    else:
                        f[s] = 0
            for i in range(self.n):
                var v = qd0[i]
                for r in range(m):
                    if f[r] != 0:
                        v += mj[r * self.n + i] * f[r]
                qd[i] = v

            # 1. a normal (or limit) that pulls is dropped, with its tangents
            var worst_r = -1
            var worst_v = Real(-1e-9)
            for r in range(m):
                var k = self.rows[r].kind
                if state[r] == 1 and (k == CON_LIMIT or k == CON_CONTACT) and f[r] < worst_v:
                    worst_v = f[r]
                    worst_r = r
            if worst_r >= 0:
                state[worst_r] = 0
                for t in range(m):
                    if self.rows[t].kind == CON_TANGENT and self.rows[t].normal_row == worst_r:
                        state[t] = 0
                continue

            # 2. a sliding group whose velocity has reversed against its direction sticks
            var stick_r = -1
            for r in range(m):
                if self.rows[r].kind != CON_TANGENT or state[r] != 2:
                    continue
                if pyramidal:
                    if self._row_dot(r, qd) * sdir[r] < 0:
                        stick_r = r
                        break
                elif self.rows[r].partner > r:
                    var p = self.rows[r].partner
                    if self._row_dot(r, qd) * sdir[r] + self._row_dot(p, qd) * sdir[p] < 0:
                        stick_r = r
                        break
            if stick_r >= 0:
                state[stick_r] = 1
                if not pyramidal:
                    state[self.rows[stick_r].partner] = 1
                continue

            # 3. a stuck group whose impulse leaves its cone starts to slide
            var slide_r = -1
            var slide_v = Real(1e-9)
            for r in range(m):
                if self.rows[r].kind != CON_TANGENT or state[r] != 1:
                    continue
                var cap = self.rows[r].mu * f[self.rows[r].normal_row]
                if pyramidal:
                    var ex = abs(f[r]) - cap
                    if ex > slide_v:
                        slide_v = ex
                        slide_r = r
                elif self.rows[r].partner > r:
                    var p = self.rows[r].partner
                    var ex = sqrt(f[r] * f[r] + f[p] * f[p]) - cap
                    if ex > slide_v:
                        slide_v = ex
                        slide_r = r
            if slide_r >= 0:
                if pyramidal:
                    state[slide_r] = 2
                    sdir[slide_r] = -1 if f[slide_r] > 0 else 1
                else:
                    var p = self.rows[slide_r].partner
                    var norm = sqrt(f[slide_r] * f[slide_r] + f[p] * f[p])
                    state[slide_r] = 2
                    state[p] = 2
                    sdir[slide_r] = -f[slide_r] / norm
                    sdir[p] = -f[p] / norm
                continue

            # 4. a violated inactive normal joins the active set, with its stuck tangents
            var add_r = -1
            var add_v = Real(1e-7)
            for r in range(m):
                var k = self.rows[r].kind
                if state[r] == 0 and (k == CON_LIMIT or k == CON_CONTACT):
                    var short = self.rows[r].bias - self._row_dot(r, qd)
                    if short > add_v:
                        add_v = short
                        add_r = r
            if add_r < 0:
                for r in range(m):
                    self.force[r] = f[r]
                return rounds
            state[add_r] = 1
            for t in range(m):
                if self.rows[t].kind == CON_TANGENT and self.rows[t].normal_row == add_r:
                    state[t] = 1
        for r in range(m):
            self.force[r] = f[r]
        return rounds

    def _row_dot(self, r: Int, v: List[Real]) -> Real:
        var s = Real(0)
        for i in range(self.n):
            s += self.jac[r * self.n + i] * v[i]
        return s

    def solve(
        mut self, var hmat: List[Real], mut qd: List[Real], iters: Int = 20
    ):
        """Projected Gauss-Seidel over every row, in place on `qd`.

        `H⁻¹Jᵀ` is formed ONCE for all rows rather than per row per iteration.
        That is the difference between a solver whose cost grows with
        iteration count and one whose iterations are cheap: the expensive part
        is the factorisation, and it does not change while the impulses do."""
        var m = len(self.rows)
        if m == 0:
            return
        # minv_jt[r] = H⁻¹ Jᵀ_r, one dense solve per row
        var minv_jt = List[Real]()
        for _ in range(m * self.n):
            minv_jt.append(0)
        for r in range(m):
            var rhs = List[Real]()
            for i in range(self.n):
                rhs.append(self.jac[r * self.n + i])
            var col = solve_dense(hmat.copy(), rhs^, self.n)
            for i in range(self.n):
                minv_jt[r * self.n + i] = col[i]
        # diagonal of A = J H⁻¹ Jᵀ
        var adiag = List[Real]()
        for r in range(m):
            var s = Real(0)
            for i in range(self.n):
                s += self.jac[r * self.n + i] * minv_jt[r * self.n + i]
            adiag.append(s if s > 1e-12 else Real(1e-12))

        for r in range(m):
            self.force[r] = 0

        for _ in range(iters):
            for r in range(m):
                var kind = self.rows[r].kind
                if kind == CON_TANGENT and self.cone == CONE_ELLIPTIC:
                    # elliptic rows are solved as a pair, by the lower index
                    if self.rows[r].partner < r:
                        continue
                    self._solve_pair(r, minv_jt, adiag, qd)
                    continue
                var resid = self._row_dot(r, qd) - self.rows[r].bias
                var df = -resid / adiag[r]
                var want = self.force[r] + df
                var clamped = self._project(r, want)
                var applied = clamped - self.force[r]
                self.force[r] = clamped
                for i in range(self.n):
                    qd[i] = qd[i] + minv_jt[r * self.n + i] * applied

    def _project(self, r: Int, f: Real) -> Real:
        var row = self.rows[r]
        if row.kind == CON_EQUALITY:
            return f
        if row.kind == CON_LIMIT or row.kind == CON_CONTACT:
            return f if f > 0 else Real(0)
        if row.kind == CON_FRICTION_LOSS:
            return row.cap if f > row.cap else (-row.cap if f < -row.cap else f)
        # pyramidal tangent: each component bounded independently, which is
        # exactly the approximation that makes the admissible set a square
        var lim = row.mu * self.force[row.normal_row]
        if lim < 0:
            lim = 0
        return lim if f > lim else (-lim if f < -lim else f)

    def _solve_pair(
        mut self,
        r: Int,
        minv_jt: List[Real],
        adiag: List[Real],
        mut qd: List[Real],
    ):
        """Both tangents of one contact, projected onto the friction DISC.

        Solving them separately and then scaling is not the same thing: the
        radial projection has to see the pair as a vector, or the result is
        the square again with extra steps."""
        var b = self.rows[r].partner
        var r1 = self._row_dot(r, qd)
        var r2 = self._row_dot(b, qd)
        var f1 = self.force[r] - r1 / adiag[r]
        var f2 = self.force[b] - r2 / adiag[b]
        var lim = self.rows[r].mu * self.force[self.rows[r].normal_row]
        if lim < 0:
            lim = 0
        var mag = sqrt(f1 * f1 + f2 * f2)
        if mag > lim and mag > 1e-12:
            var k = lim / mag
            f1 = f1 * k
            f2 = f2 * k
        var d1 = f1 - self.force[r]
        var d2 = f2 - self.force[b]
        self.force[r] = f1
        self.force[b] = f2
        for i in range(self.n):
            qd[i] = (
                qd[i]
                + minv_jt[r * self.n + i] * d1
                + minv_jt[b * self.n + i] * d2
            )


# ------------------------------------------------------------ loop closures (17.51)


@fieldwise_init
struct LoopClosure(Copyable, ImplicitlyCopyable, Movable):
    """Closes a kinematic loop: point `la` of link `a` stays on point `lb`
    of link `b` (both in link frames), or on the world point `lb` when
    `b < 0` (a four-bar's ground pivot). Three equality rows, Jacobian
    assembled from `Chain.point_jacobian` -- no hand-written rows."""

    var a: Int
    var la: Vec3
    var b: Int
    var lb: Vec3


struct _DenseOp(LinearOperator, Movable):
    """Row-major dense square matrix as a `LinearOperator`, for the Krylov
    inner solve of `solve_cone_newton` (the reduced system is built dense)."""

    var a: List[Real]
    var n: Int

    def __init__(out self, var a: List[Real], n: Int):
        self.a = a^
        self.n = n

    def size(self) -> Int:
        return self.n

    def apply(self, x: List[Real], mut out: List[Real]):
        for i in range(self.n):
            var acc = Real(0)
            for j in range(self.n):
                acc += self.a[i * self.n + j] * x[j]
            out[i] = acc

    def diagonal(self, mut out: List[Real]):
        for i in range(self.n):
            out[i] = self.a[i * self.n + i]


def _loop_gap(ch: Chain, lp: LoopClosure) -> Vec3:
    var pa = ch.point_world(lp.a, lp.la)
    var pb = ch.point_world(lp.b, lp.lb) if lp.b >= 0 else lp.lb
    return pa - pb


def _loop_rows(ch: Chain, loops: List[LoopClosure], bias_scale: Real) raises -> ConstraintSet:
    var n = len(ch.links)
    var cs = ConstraintSet(n)
    for lp in loops:
        var gap = _loop_gap(ch, lp)
        for k in range(3):
            var e = Vec3(0, 0, 0, 0)
            e[k] = 1
            var ja = ch.point_jacobian(lp.a, lp.la, e)
            if lp.b >= 0:
                var jb = ch.point_jacobian(lp.b, lp.lb, e)
                for i in range(n):
                    ja[i] -= jb[i]
            _ = cs.add_equality(ja, -gap[k] * bias_scale)
    return cs^


def _solve_rows(mut cs: ConstraintSet, var h: List[Real], mut qd: List[Real], mode: Int, iters: Int) raises:
    match mode:
        case == SOLVE_DIRECT:
            _ = cs.solve_active_set(h^, qd)
        case == SOLVE_CG:
            _ = cs.solve_cg(h^, qd, iters)
        case _:
            cs.solve(h^, qd, iters)


def resolve_loops(
    mut ch: Chain, loops: List[LoopClosure], dt: Real,
    mode: Int = SOLVE_DIRECT, iters: Int = 20, pos_iters: Int = 2,
) raises -> Real:
    """After `Chain.step`: remove the loop-breaking part of q-dot (velocity
    rows, target 0), then pull q back onto the loop with pseudo-velocity
    passes (target -gap / dt, integrated into q and discarded), like
    `Chain.resolve_contacts`. Returns the largest remaining gap (m)."""
    var n = len(ch.links)
    if len(loops) == 0:
        return 0
    var cv = _loop_rows(ch, loops, 0)
    _solve_rows(cv, ch.mass_matrix(), ch.qd, mode, iters)
    for _ in range(pos_iters):
        var cp = _loop_rows(ch, loops, 1 / dt)
        var pseudo = List[Real](length=n, fill=0)
        _solve_rows(cp, ch.mass_matrix(), pseudo, mode, iters)
        for k in range(n):
            ch.q[k] += pseudo[k] * dt
        if len(ch.balls) > 0:
            ch.fold_balls()
    var worst = Real(0)
    for lp in loops:
        var g = length(_loop_gap(ch, lp))
        if not (g <= worst):  # NaN propagates (max() would drop it)
            worst = g
    return worst
