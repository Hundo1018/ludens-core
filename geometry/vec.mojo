"""Dimension-generic vector math built on SIMD.

`WorldType` is the world's scalar dtype; `Vec2` is `SIMD[WorldType, 2]` and `Vec3`
is `SIMD[WorldType, 4]` with lane 3 always zero (16.3: SIMD widths are powers of
two). Reductions use SIMD `reduce_add` over every lane, which is correct because
the pad lane is zero (see `Vec3` and `dot` below).

Width-generic helpers infer the width with `[w: SIMDLength, //]` (SIMD's width
parameter is `SIMDLength`, not `Int`, so plain `Int` would not infer from a value).
"""

from std.math import sqrt

comptime WorldType = DType.float32
comptime Real = Scalar[WorldType]
comptime Vec2 = SIMD[WorldType, 2]
# FOUR lanes, not three. Mojo requires SIMD widths to be powers of two, so a
# 3-vector is stored padded and LANE 3 IS ALWAYS ZERO.
#
# That invariant is load-bearing, not decorative: `dot` reduces over every lane
# of whatever width it is given, so a non-zero pad lane would silently corrupt
# every dot product, length and normalisation in the engine. It is maintained by
# construction -- `Vec3(x, y, z, 0)` at every call site, and splats are only
# ever `Vec3(0)` -- and `test_vec` asserts it survives the arithmetic that
# matters. Addition, subtraction and scalar multiply preserve zero; the one
# operation that would not is dividing two vectors element-wise, which this
# engine never does (division is always by a scalar length).
#
# Padding is also why the old `List[Vec3]` corruption class is gone: it was
# caused by a width the toolchain never fully supported.
comptime Vec3 = SIMD[WorldType, 4]


comptime PadW[d: Int] = 4 if d == 3 else d
"""Lane count used to store a `d`-dimensional vector.

SIMD widths must be powers of two, so a 3-vector occupies 4 lanes. Every
dimension-generic container sizes its storage with `PadW[dim]` rather than with
`dim` directly; loops still run over `dim`, so the pad lane is never addressed.

It has to be a CONDITIONAL alias, not arithmetic and not a function. A `def`
called in type position is never folded, and an arithmetic expression stays
symbolic -- `SIMDLength(((Int(4) // Int(2)) * Int(2)))` will not unify with
`SIMDLength(4)`, so a padded container could not be passed to anything typed
with a literal width. The conditional form folds to a literal and unifies."""


def vlanes(d: Int) -> Int:
    """Runtime form of `PadW`, for code that needs the count as a value."""
    return 4 if d == 3 else d


def dot[w: SIMDLength, //](a: SIMD[WorldType, w], b: SIMD[WorldType, w]) -> Real:
    """Lane-wise multiply then horizontal sum.

    This was a hand-written `comptime for` reduction because `reduce_add` was
    broken at width 3. Every vector width is a power of two now, so the
    hardware reduction is both correct and cheaper -- and the hand-written form
    had become actively harmful: `w` is INFERRED, so in dimension-generic code
    it arrives as the unfolded `PadW[D]`, and `comptime for i in range(Int(w))`
    over a symbolic bound exhausts the comptime interpreter's heap instead of
    unrolling. That is what `HEAP_BUFFER_BYTES exceeded` was, and why raising
    the limit did not help.

    Summing every lane is correct for a padded 3-vector because lane 3 is
    always zero -- see the `Vec3` alias for why that invariant holds."""
    return (a * b).reduce_add()


def length_sq[w: SIMDLength, //](a: SIMD[WorldType, w]) -> Real:
    return dot(a, a)


def length[w: SIMDLength, //](a: SIMD[WorldType, w]) -> Real:
    return sqrt(length_sq(a))


def distance_sq[w: SIMDLength, //](a: SIMD[WorldType, w], b: SIMD[WorldType, w]) -> Real:
    return length_sq(a - b)


def normalize[w: SIMDLength, //](a: SIMD[WorldType, w]) -> SIMD[WorldType, w]:
    var n = length(a)
    if n == 0:
        return a
    return a / n


def normalize_or[w: SIMDLength, //](
    a: SIMD[WorldType, w], fallback: SIMD[WorldType, w]
) -> SIMD[WorldType, w]:
    """`normalize(a)`, or `fallback` when `a` is (numerically) the zero
    vector (audit E16: `normalize`'s silent zero return lets a degenerate
    direction reach downstream code as a valid-looking unit vector -- an
    sdf gradient at a coincident centre, a clip edge between duplicate
    vertices, an rng sample that happened to land on the origin). Callers
    that need geometry to keep working must pick a `fallback` that is
    itself a unit vector (or use zero deliberately as a sentinel) -- this
    function does not normalize `fallback` for them."""
    var n = length(a)
    if n < Real(1e-12):
        return fallback
    return a / n


def lane_min[w: SIMDLength, //](
    a: SIMD[WorldType, w], b: SIMD[WorldType, w]
) -> SIMD[WorldType, w]:
    # Element-wise, for the same reason `dot` no longer hand-rolls its loop.
    return min(a, b)


def lane_max[w: SIMDLength, //](
    a: SIMD[WorldType, w], b: SIMD[WorldType, w]
) -> SIMD[WorldType, w]:
    return max(a, b)


def splat[d: Int](v: Real) -> SIMD[WorldType, PadW[d]]:
    """A vector with every lane set to `v` (width passed explicitly)."""
    var r = SIMD[WorldType, PadW[d]](0)
    comptime for i in range(d):
        r[i] = v
    return r


@always_inline
def cross[dim: Int](
    a: SIMD[WorldType, PadW[dim]], b: SIMD[WorldType, PadW[dim]]
) -> SIMD[WorldType, PadW[dim]]:
    """3-D cross product, dimension-generic over the padded lane width.

    `dim` cannot always be inferred from a plain `SIMD[WorldType, PadW[dim]]`
    argument (a width-4 value is ambiguous between `dim=3`, padded, and
    `dim=4`), so a dim-generic call site passes it explicitly: `cross[3](a, b)`.
    The non-generic `cross(a: Vec3, b: Vec3)` overload below covers the common
    fixed-width-3 case with no bracket parameter."""
    var r = SIMD[WorldType, PadW[dim]](0)
    r[0] = a[1] * b[2] - a[2] * b[1]
    r[1] = a[2] * b[0] - a[0] * b[2]
    r[2] = a[0] * b[1] - a[1] * b[0]
    return r


@always_inline
def cross(a: Vec3, b: Vec3) -> Vec3:
    """3-D cross product. The single shared implementation: this formula and
    operand order used to be copied privately in 11 modules (audit F8).
    Built in one constructor rather than through `cross[3]`'s lane writes:
    that is the form the copies used, and the hot solver paths measured
    faster with it."""
    return Vec3(
        a[1] * b[2] - a[2] * b[1],
        a[2] * b[0] - a[0] * b[2],
        a[0] * b[1] - a[1] * b[0],
        0,
    )


@always_inline
def tangent_basis(n: Vec3) -> Tuple[Vec3, Vec3]:
    """Two unit tangents perpendicular to `n` (and each other).

    One fixed convention (seed axis, threshold, cross operand order) shared by
    every caller that needs A specific orthonormal frame around a normal —
    moved here verbatim from `physics/solver6.mojo`'s `_tangent_basis` (F8).
    `collision/hull.mojo`'s `_basis` wants only *some* orthonormal pair, uses a
    different threshold and operand order, and stays a separate, named
    variant for that reason (see its docstring)."""
    var seed = Vec3(0, 1, 0, 0) if abs(n[0]) > 0.9 else Vec3(1, 0, 0, 0)
    var t1 = cross(seed, n)
    t1 = t1 / sqrt(max(dot(t1, t1), Real(1e-12)))
    return (t1, cross(n, t1))
