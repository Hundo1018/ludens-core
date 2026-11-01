"""Easing curves and a generic value tween, screw-interpolated for motors.

Penner's easing set (linear, plus ten families -- quad, cubic, quart, quint,
sine, expo, circ, back, elastic, bounce -- each with in/out/in-out variants,
31 curves total) selected by `kind: Int`, a COMPTIME bracket parameter on
`ease[kind]`: the family/variant lookup happens at compile time (`comptime
if`), so `ease[EASE_QUAD_OUT](t)` compiles straight to the quad-out formula
with no runtime branch at all -- the dispatch really is free, not just
cheap. `ease_dyn(kind, t)` is the data-driven counterpart (kind decided at
runtime, e.g. loaded from an asset) built from the SAME `ease[k]` bodies via
a `comptime for`-generated if-chain; `bench_tween.mojo` measures the two
side by side.

Every "out" and "in-out" variant is DERIVED from its family's "in" formula
by the standard construction (`_ease_in` is the only formula hand-written
per family):

    out(t)    = 1 - in(1 - t)
    in_out(t) = t < 0.5 ? in(2t)/2 : 1 - in(2 - 2t)/2

which makes `e(0) = 0`, `e(1) = 1` and the in/out symmetry
`e_out(t) = 1 - e_in(1 - t)` hold BY CONSTRUCTION for all 30 non-linear
curves, rather than by separately transcribing (and risking a transcription
bug in) each closed form -- `test_tween` still checks both properties, as a
check on the wiring (right family selected, composition applied correctly),
not as a proof of algebra already guaranteed by this file's own structure.
`ease`/`ease_dyn` do not clamp `t` -- they are the raw curve; a `t` outside
`[0, 1]` extrapolates the formula (harmless for the polynomial/trig families,
can produce large excursions for back/elastic). Clamping happens one layer
up, in `Tween`.

`Tween[L, ease_kind]` tweens a value of type `L.Value` from `start` to `end`
over `duration` (a `Real`, same unit as whatever drives `advance` -- seconds
if driven by wall/frame time, ticks if driven by `scheduler.timers`), with
`L: Interpolator` (`LerpReal`, `LerpVec3`, `GeodesicMotor3`, `GeodesicMotor2`) supplying the interpolation itself and `ease_kind`
selecting the easing (again a comptime parameter, so the whole per-frame
`value()` call is fully monomorphized). `T` is deliberately NOT constrained
by a shared "Tweenable" trait: `Real` and `Vec3` are stdlib/alias types this
package does not own, so there is nothing to declare conformance on, and a
trait requirement would buy nothing a plain function parameter does not
already give (`geometry.galie.geodesic3` already has exactly the
`def(Motor3, Motor3, Real) -> Motor3` shape `Tween` wants, unmodified).

Rigid-motion tweens (`Tween[Motor3, ..., ...]` / `Tween[Motor2, ..., ...]`)
pass `geodesic3`/`geodesic2` as `F`: screw interpolation along the motor
manifold, constant angular+linear speed in one uniform motion, which
lerp-position-plus-slerp-rotation cannot produce (the two would-be-separate
paths only agree at the endpoints -- see `docs/CATEGORY.md` §3's SE(3)
representation-functor discussion). Motors are compared BY ACTION on points
(`M` and `-M` are the same rigid motion), never by coefficient, matching
`test_motor_parity`'s convention -- `test_tween`'s motor cases apply both
motors to sample points rather than comparing fields.
"""

from std.math import sqrt, pow
from geometry.trig import sin, cos
from geometry.vec import Real, Vec3
from geometry.motor import Motor2, Motor3
from geometry.galie import geodesic2, geodesic3

comptime PI: Real = 3.14159265358979323846

# ---------------------------------------------------------------- easing ids
comptime EASE_LINEAR = 0
comptime EASE_QUAD_IN = 1
comptime EASE_QUAD_OUT = 2
comptime EASE_QUAD_INOUT = 3
comptime EASE_CUBIC_IN = 4
comptime EASE_CUBIC_OUT = 5
comptime EASE_CUBIC_INOUT = 6
comptime EASE_QUART_IN = 7
comptime EASE_QUART_OUT = 8
comptime EASE_QUART_INOUT = 9
comptime EASE_QUINT_IN = 10
comptime EASE_QUINT_OUT = 11
comptime EASE_QUINT_INOUT = 12
comptime EASE_SINE_IN = 13
comptime EASE_SINE_OUT = 14
comptime EASE_SINE_INOUT = 15
comptime EASE_EXPO_IN = 16
comptime EASE_EXPO_OUT = 17
comptime EASE_EXPO_INOUT = 18
comptime EASE_CIRC_IN = 19
comptime EASE_CIRC_OUT = 20
comptime EASE_CIRC_INOUT = 21
comptime EASE_BACK_IN = 22
comptime EASE_BACK_OUT = 23
comptime EASE_BACK_INOUT = 24
comptime EASE_ELASTIC_IN = 25
comptime EASE_ELASTIC_OUT = 26
comptime EASE_ELASTIC_INOUT = 27
comptime EASE_BOUNCE_IN = 28
comptime EASE_BOUNCE_OUT = 29
comptime EASE_BOUNCE_INOUT = 30
comptime EASE_COUNT = 31
"""1 (linear) + 10 families x 3 (in/out/in-out)."""

# family ids used by `_ease_in`, independent of the public `EASE_*` numbering
comptime _FAM_QUAD = 0
comptime _FAM_CUBIC = 1
comptime _FAM_QUART = 2
comptime _FAM_QUINT = 3
comptime _FAM_SINE = 4
comptime _FAM_EXPO = 5
comptime _FAM_CIRC = 6
comptime _FAM_BACK = 7
comptime _FAM_ELASTIC = 8
comptime _FAM_BOUNCE = 9


def _bounce_out_raw(x0: Real) -> Real:
    """`easeOutBounce`, Penner's primitive for the bounce family (every other
    family instead defines "in" as the primitive -- bounce is the one
    exception in the canonical set, so `_ease_in[_FAM_BOUNCE]` is written in
    terms of THIS, flipped, rather than the other way around)."""
    comptime n1: Real = 7.5625
    comptime d1: Real = 2.75
    var x = x0
    if x < 1.0 / d1:
        return n1 * x * x
    elif x < 2.0 / d1:
        x -= 1.5 / d1
        return n1 * x * x + 0.75
    elif x < 2.5 / d1:
        x -= 2.25 / d1
        return n1 * x * x + 0.9375
    else:
        x -= 2.625 / d1
        return n1 * x * x + 0.984375


def _ease_in[fam: Int](t: Real) -> Real:
    """The one hand-written formula per family; `ease[kind]` derives out/
    in-out from this. Domain `[0, 1]` (guaranteed by how `ease[kind]`
    composes calls to this function -- see module docstring)."""
    comptime match fam:
        case == _FAM_QUAD:
            return t * t
        case == _FAM_CUBIC:
            return t * t * t
        case == _FAM_QUART:
            var t2 = t * t
            return t2 * t2
        case == _FAM_QUINT:
            var t2 = t * t
            return t2 * t2 * t
        case == _FAM_SINE:
            return 1 - cos(t * PI * 0.5)
        case == _FAM_EXPO:
            if t <= 0:
                return 0
            return pow(Real(2), 10 * t - 10)
        case == _FAM_CIRC:
            return 1 - sqrt(1 - t * t)
        case == _FAM_BACK:
            comptime c1: Real = 1.70158
            comptime c3: Real = c1 + 1
            return c3 * t * t * t - c1 * t * t
        case == _FAM_ELASTIC:
            if t <= 0:
                return 0
            elif t >= 1:
                return 1
            comptime c4: Real = 2 * PI / 3
            return -pow(Real(2), 10 * t - 10) * sin((t * 10 - 10.75) * c4)
        case _:  # _FAM_BOUNCE
            return 1 - _bounce_out_raw(1 - t)


def ease[kind: Int](t: Real) -> Real:
    """Comptime-dispatched easing: `kind` is a bracket parameter, so this
    monomorphizes to exactly one family/variant's formula with no runtime
    branch. See module docstring for the out/in-out derivation."""
    comptime if kind == EASE_LINEAR:
        return t
    else:
        comptime fam = (kind - 1) // 3
        comptime variant = (kind - 1) % 3  # 0 = in, 1 = out, 2 = in-out
        comptime match variant:
            case 0:
                return _ease_in[fam](t)
            case 1:
                return 1 - _ease_in[fam](1 - t)
            case _:
                if t < 0.5:
                    return _ease_in[fam](2 * t) * 0.5
                else:
                    return 1 - _ease_in[fam](2 - 2 * t) * 0.5


def ease_dyn(kind: Int, t: Real) -> Real:
    """Runtime-dispatched easing for a `kind` not known until runtime (e.g.
    loaded from data). Built by unrolling `comptime for` into a chain of
    plain `if`s, each calling the same `ease[k]` the comptime path uses --
    the SAME formulas, the difference `bench_tween` measures is purely the
    cost of the outer runtime branch. An out-of-range `kind` falls through
    to identity (documented, not an error: this is a rendering/animation
    value, not a public API boundary an invalid-input `raise` would guard --
    see `docs/ARCHITECTURE.md` §2, "invalid input" is for a public entry
    point, and a bad `kind` here is a content/data bug, not caller misuse of
    this function's own contract)."""
    comptime for k in range(EASE_COUNT):
        if kind == k:
            return ease[k](t)
    return t


# ---------------------------------------------------------------- interpolants
def lerp_real(a: Real, b: Real, t: Real) -> Real:
    return a + (b - a) * t


def lerp_vec3(a: Vec3, b: Vec3, t: Real) -> Vec3:
    return a + (b - a) * t


trait Interpolator(Copyable, Movable, Deinitable):
    """What `Tween` interpolates with: `lerp(a, b, t)` for `t` in `[0, 1]` over
    `Value`. It is a trait implemented by empty structs rather than a
    function-typed parameter because Mojo 1.2.0 fails to compile a struct
    that stores one (`Tween[T, type_of(f), K]` -> "'kgen.call' op callee
    argument #4 expected type ... but operation argument has type ...");
    an empty struct field compiles and is as free."""

    comptime Value: Copyable & Deinitable

    def lerp(self, a: Self.Value, b: Self.Value, t: Real) -> Self.Value:
        ...


@fieldwise_init
struct LerpReal(Interpolator):
    comptime Value = Real

    def lerp(self, a: Real, b: Real, t: Real) -> Real:
        return lerp_real(a, b, t)


@fieldwise_init
struct LerpVec3(Interpolator):
    comptime Value = Vec3

    def lerp(self, a: Vec3, b: Vec3, t: Real) -> Vec3:
        return lerp_vec3(a, b, t)


@fieldwise_init
struct GeodesicMotor3(Interpolator):
    """Screw interpolation of `Motor3` (`geometry.galie.geodesic3`)."""

    comptime Value = Motor3

    def lerp(self, a: Motor3, b: Motor3, t: Real) -> Motor3:
        return geodesic3(a, b, t)


@fieldwise_init
struct GeodesicMotor2(Interpolator):
    """Screw interpolation of `Motor2` (`geometry.galie.geodesic2`)."""

    comptime Value = Motor2

    def lerp(self, a: Motor2, b: Motor2, t: Real) -> Motor2:
        return geodesic2(a, b, t)


# ---------------------------------------------------------------- Tween
struct Tween[L: Interpolator, ease_kind: Int](Movable, Deinitable):
    """`start` -> `end` over `duration`, eased by `ease_kind`, interpolated by
    `L`. Stateful (`advance`/`done`/`reset`) for the common "drive it every
    frame" use; `value_at(t)` is the stateless counterpart for scrubbing or
    one-shot evaluation. `duration <= 0` is a valid, deliberately-supported
    degenerate case ("zero-duration tween"): `u()` reports 1 immediately, so
    the tween is `done()` before its first `advance` and evaluates to `end`
    -- not a divide-by-zero, not an error, because a designer setting a
    tween's duration to 0 (or an animation curve collapsing to a snap) is a
    normal authoring choice, not invalid input."""

    var start: Self.L.Value
    var end: Self.L.Value
    var duration: Real
    var elapsed: Real
    var f: Self.L

    def __init__(
        out self, var start: Self.L.Value, var end: Self.L.Value, duration: Real, var f: Self.L
    ):
        self.start = start^
        self.end = end^
        self.duration = duration
        self.elapsed = 0
        self.f = f^

    def reset(mut self):
        self.elapsed = 0

    def advance(mut self, dt: Real) -> Bool:
        """Step elapsed time forward by `dt`; returns `done()` after the step."""
        self.elapsed += dt
        return self.done()

    def done(self) -> Bool:
        return self.elapsed >= self.duration

    def u(self) -> Real:
        """Normalized, CLAMPED progress in `[0, 1]`. `duration <= 0` reports
        1 (see struct docstring); otherwise `elapsed / duration` clamped --
        the "t outside [0,1]" extreme case (`elapsed` can overshoot past a
        cap, or a caller can rewind `elapsed` negative) never reaches `ease`
        with an out-of-range input from THIS path."""
        if self.duration <= 0:
            return 1
        var raw = self.elapsed / self.duration
        if raw < 0:
            return 0
        if raw > 1:
            return 1
        return raw

    def value(self) -> Self.L.Value:
        return self.f.lerp(self.start, self.end, ease[Self.ease_kind](self.u()))

    def value_at(self, t: Real) -> Self.L.Value:
        """Stateless evaluation at an explicit, CLAMPED `t` -- ignores
        `elapsed`. `t` outside `[0, 1]` is the other half of the documented
        extreme case: clamped here too, same as `u()`."""
        var tc = t
        if tc < 0:
            tc = 0
        if tc > 1:
            tc = 1
        return self.f.lerp(self.start, self.end, ease[Self.ease_kind](tc))
