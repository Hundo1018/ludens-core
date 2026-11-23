"""Conjugate gradients, plain and preconditioned.

CG is the right global solver for the systems this engine produces: they are
symmetric positive definite (mass plus stiffness, or a Laplacian), large, and
sparse. It needs only `A @ x`, so it works matrix-free, and its convergence is
governed by the condition number rather than by the mesh size directly — which
is exactly why a preconditioner is not an optimisation but a change in what is
solvable.

Everything here reports rather than assumes. `CgResult` carries whether the
solve converged, how many iterations it used and the final relative residual,
because "the solver returned" and "the solver solved it" are different claims
and a physics step that mistakes one for the other produces a plausible-looking
wrong answer. A stalled or diverging solve is detected and reported, not
silently accepted: `test_numerics` drives both cases on purpose.

MIXED PRECISION, and not as a refinement. The operator applies in float32
because that is what the engine's state is, but the Krylov recurrence runs in
float64. Measured on the 1D Poisson system: at n=64 a float32 recurrence
converges to a relative residual of 1.6e-7, and at n=256 it DIVERGES — final
residual 8.4, solution off by 4560. The condition number there is around 2.6e4,
which eats most of float32's seven digits, and what is left is not enough to
keep the search directions conjugate. Widening the recurrence costs two
conversions per iteration and is the difference between a solver that works at
scale and one that quietly does not.

Vectors are flat lists; see `vecops` for why they are not `List[Vec3]`.
"""

from std.math import sqrt
from geometry.vec import Real
from .sparse import LinearOperator
from .vecops import (
    zeros, zeros64, dot64, axpy64, scale_add64, norm64, narrow, widen, norm2,
)


@fieldwise_init
struct CgResult(Copyable, ImplicitlyCopyable, Movable):
    """What a solve actually did.

    `converged` is the only field a caller may treat as permission to use the
    answer. `stalled` separates "ran out of iterations" from "the operator is
    not what CG assumed" — the second means no iteration budget will help."""

    var converged: Bool
    # True only for a genuine BREAKDOWN: a search direction along which the
    # operator is not positive definite. An earlier version also set it from a
    # "residual has not improved for 32 iterations" heuristic, which was wrong
    # in a way worth recording -- CG minimises the A-norm of the ERROR, not the
    # residual norm, so ||r|| is not monotonic and plateaus early on a
    # well-posed problem. That heuristic reported the n=256 Poisson system as
    # stalled at iteration 33 when it was converging normally and needed ~180.
    # Running out of iterations is `converged=False, stalled=False`; those are
    # different situations and the caller can act on the difference.
    var stalled: Bool
    var iters: Int
    var residual: Real  # final ||b - Ax|| / ||b||


def cg[Op: LinearOperator](
    a: Op, b: List[Real], mut x: List[Real],
    tol: Real = 1e-6, max_iters: Int = 0,
) -> CgResult:
    """Solve `A x = b` by conjugate gradients, starting from `x`.

    `max_iters = 0` means `n`, the dimension — in exact arithmetic CG converges
    in at most that many steps, so needing more is a statement about rounding,
    not about the algorithm."""
    return _krylov[Op](a, b, x, tol, max_iters, False)


def pcg[Op: LinearOperator](
    a: Op, b: List[Real], mut x: List[Real],
    tol: Real = 1e-6, max_iters: Int = 0,
) -> CgResult:
    """CG with Jacobi (diagonal) preconditioning.

    Jacobi is the cheapest useful preconditioner and the only one always
    available: it needs the diagonal, which the operator interface already
    exposes. It helps exactly when the diagonal VARIES — a stiffness matrix
    with elements of very different sizes, a mass matrix with a heavy body next
    to a light one. On a uniform Poisson matrix the diagonal is constant, so
    Jacobi is a scalar multiple of the identity and changes nothing at all.
    `bench_numerics` reports both regimes rather than only the flattering one:
    a preconditioner that helped everywhere would be a sign of a measurement
    error, not of a good preconditioner."""
    return _krylov[Op](a, b, x, tol, max_iters, True)


def _krylov[Op: LinearOperator](
    a: Op, b: List[Real], mut x: List[Real],
    tol: Real, max_iters: Int, precondition: Bool,
) -> CgResult:
    """CG and PCG share everything but the preconditioner, so they share the
    body: two copies of a Krylov recurrence that must agree on the unpreconditioned
    case would be two chances to make the same subtle sign error differently."""
    var n = a.size()
    var limit = max_iters if max_iters > 0 else n
    var tol64 = Float64(tol)

    var minv = zeros64(n)
    if precondition:
        var diag = zeros(n)
        a.diagonal(diag)
        for i in range(n):
            # A zero diagonal means the row is entirely off-diagonal; the
            # identity is the only safe choice and costs one multiply.
            minv[i] = 1.0 / Float64(diag[i]) if diag[i] != 0 else 1.0
    else:
        for i in range(n):
            minv[i] = 1.0

    var b64 = zeros64(n)
    widen(b, b64)
    var bnorm = norm64(b64)
    if bnorm == 0:
        # A zero right-hand side has the zero solution, and the relative
        # residual would be 0/0. Leaving a non-zero starting guess in place
        # would be wrong, so it is cleared explicitly.
        for i in range(n):
            x[i] = 0
        return CgResult(True, False, 0, 0)

    var x64 = zeros64(n)
    widen(x, x64)
    var ax = zeros(n)
    var scratch = zeros(n)
    a.apply(x, ax)
    var r = zeros64(n)
    for i in range(n):
        r[i] = b64[i] - Float64(ax[i])

    var rel = norm64(r) / bnorm
    if rel <= tol64:
        return CgResult(True, False, 0, Real(rel))

    var z = zeros64(n)
    for i in range(n):
        z[i] = minv[i] * r[i]
    var p = zeros64(n)
    for i in range(n):
        p[i] = z[i]
    var rz_old = dot64(r, z)
    var ap = zeros64(n)

    for k in range(limit):
        narrow(p, scratch)
        a.apply(scratch, ax)
        widen(ax, ap)
        var pap = dot64(p, ap)
        if pap <= 0:
            # p^T A p <= 0 means A is not positive definite along p. Continuing
            # would step the wrong way along that direction and return a
            # confidently wrong answer, so the solve stops and says so.
            narrow(x64, x)
            return CgResult(False, True, k, Real(norm64(r) / bnorm))
        var alpha = rz_old / pap
        axpy64(alpha, p, x64)
        axpy64(-alpha, ap, r)
        rel = norm64(r) / bnorm
        if rel <= tol64:
            narrow(x64, x)
            return CgResult(True, False, k + 1, Real(rel))
        for i in range(n):
            z[i] = minv[i] * r[i]
        var rz_new = dot64(r, z)
        scale_add64(rz_new / rz_old, p, z)  # p = z + beta * p
        rz_old = rz_new

    narrow(x64, x)
    return CgResult(False, False, limit, Real(norm64(r) / bnorm))


def jacobi_solve[Op: LinearOperator](
    a: Op, b: List[Real], mut x: List[Real], iters: Int
) -> Real:
    """The control group: plain Jacobi iteration, the local method this engine
    already uses everywhere.

    Kept beside CG so the comparison the whole package is justified by can
    actually be run — "global solve beats local iteration" is a claim about two
    methods on the same system, and both have to be present to measure it.
    Returns the final relative residual."""
    var n = a.size()
    var diag = zeros(n)
    a.diagonal(diag)
    var ax = zeros(n)
    var bnorm = norm2(b)
    if bnorm == 0:
        return 0
    for _ in range(iters):
        a.apply(x, ax)
        for i in range(n):
            if diag[i] != 0:
                x[i] += (b[i] - ax[i]) / diag[i]
    a.apply(x, ax)
    var r = zeros(n)
    for i in range(n):
        r[i] = b[i] - ax[i]
    return norm2(r) / bnorm
