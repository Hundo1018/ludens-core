"""Tire force model for the raycast vehicle (ROADMAP 17.4).

A tire turns a contact-patch slip into a force. The shape is a normalised
Pacejka "magic formula" `y = sin(C atan(Bx - E(Bx - atan(Bx))))`: zero at zero
slip, a single peak, then a fall-off toward a lower sliding level -- the curve
every vehicle SDK (PhysX, Jolt, Chaos) fits, here reduced to three numbers.
`TireCurve` locates the peak numerically at construction and divides it out, so
`norm(1) == 1` and the peak slip is a plain field, not a function of B, C, E.

COMBINED SLIP. Longitudinal slip ratio `kappa = (w R - vx) / max(|vx|, vmin)`
and lateral slip `tan(alpha) = -vy / max(|vx|, vmin)` are each divided by their
own peak slip, and the force is the curve of the vector norm along the vector's
direction: a friction ellipse with the Pacejka falloff. Braking while turning
therefore costs lateral grip and the wheel can never exceed `mu Fz` in any
direction.

LOW SPEED. `max(|vx|, vmin)` keeps the slip finite at a standstill (the SAE
definition divides by zero), and `force_limit` is the implicit clamp: a force
that would reverse the slip velocity inside one step is cut to exactly the
value that cancels it, which removes the jitter an explicit friction model has
when parked on a slope.
"""

from std.math import atan, sqrt
from geometry.trig import sin
from geometry.vec import Real

comptime _EPS: Real = 1e-6


struct TireCurve(Copyable, ImplicitlyCopyable, Movable):
    var b: Real
    var c: Real
    var e: Real
    var peak_x: Real  # argument of the maximum
    var peak_y: Real  # value of the maximum (divided out by `norm`)

    def __init__(out self, b: Real, c: Real, e: Real):
        self.b = b
        self.c = c
        self.e = e
        self.peak_x = 0.1
        self.peak_y = 1
        var best = Real(0)
        var bx = Real(0.1)
        for i in range(1, 800):
            var x = Real(i) * 0.0025
            var y = self.raw(x)
            if y > best:
                best = y
                bx = x
        self.peak_x = bx
        self.peak_y = best if best > _EPS else Real(1)

    def raw(self, x: Real) -> Real:
        var bx = self.b * x
        return sin(self.c * atan(bx - self.e * (bx - atan(bx))))

    def norm(self, s: Real) -> Real:
        """Force fraction at normalised slip `s` (1 = peak), odd in `s`."""
        var a = s if s >= 0 else -s
        var y = self.raw(a * self.peak_x) / self.peak_y
        return y if s >= 0 else -y

    @staticmethod
    def default() -> Self:
        """Dry asphalt: peak at slip ratio 0.125, 69% of peak when locked."""
        return Self(12, 1.6, 0)


@fieldwise_init
struct TireModel(Copyable, ImplicitlyCopyable, Movable):
    var mu: Real  # peak friction coefficient on the reference surface
    var shape: TireCurve
    var long_peak: Real  # slip ratio at peak grip
    var lat_peak: Real  # tan(slip angle) at peak grip
    var lat_scale: Real  # lateral grip relative to longitudinal
    var v_min: Real  # slip denominator floor (m/s)

    @staticmethod
    def default() -> Self:
        return Self(1.0, TireCurve.default(), 0.125, 0.18, 1.0, 0.25)

    def grip(self, kappa: Real, tan_alpha: Real, mu_eff: Real, fz: Real) -> Tuple[Real, Real]:
        """(Fx, Fy) in the contact frame for slip ratio `kappa` and lateral
        slip `tan_alpha` (positive = pushes toward +y), at normal load `fz`
        on a surface giving `mu_eff` (already scaled by tire and surface)."""
        if fz <= 0 or mu_eff <= 0:
            return (Real(0), Real(0))
        var sx = kappa / self.long_peak
        var sy = tan_alpha / self.lat_peak
        var s = sqrt(sx * sx + sy * sy)
        if s < 1e-7:
            return (Real(0), Real(0))
        var f = self.shape.norm(s) * mu_eff * fz
        return (f * sx / s, f * sy / s * self.lat_scale)


def solve_axis(
    tire: TireModel,
    on_x: Bool,
    a: Real,
    b: Real,
    other_s: Real,
    den: Real,
    mu_eff: Real,
    fz: Real,
) -> Real:
    """Implicit tire force along one axis.

    `a` is the slip velocity (m/s) the contact would have at the END of the
    step if the tire exerted no force, positive when the force it provokes is
    positive; `b` (m/s per N) is how much one newton of that force reduces it
    over the step (chassis, plus the wheel's spin inertia on the longitudinal
    axis). The force `F` and the slip after it are tied by `F = Grip(a - b F)`;
    this finds that fixed point on the rising, low-slip branch of the curve
    (bisection on [force that leaves the peak slip, force that cancels the slip
    entirely]), so a stiff contact is solved instead of being stepped over.
    `other_s` is the slip velocity on the other axis (it shares the friction
    ellipse). When the tire cannot supply the force that brings the slip down to
    its peak, the wheel keeps sliding and the root is found in the falling tail.
    """
    var sgn = Real(1) if a >= 0 else Real(-1)
    var aa = a * sgn
    if aa < 1e-9 or fz <= 0 or mu_eff <= 0:
        return 0
    var s_pk = (tire.long_peak if on_x else tire.lat_peak) * den
    var f_at_peak = _axis_force(tire, on_x, s_pk, other_s, den, mu_eff, fz)
    if b <= 1e-12:
        return sgn * _axis_force(tire, on_x, aa, other_s, den, mu_eff, fz)
    var hi = min(aa / b, mu_eff * fz * Real(1.01))  # the curve never exceeds mu Fz
    var lo = aa - s_pk
    lo = lo / b if lo > 0 else Real(0)
    # `lo` leaves the peak slip s_pk. If the tire cannot supply even that, the
    # contact keeps sliding in the falling tail: the root lies below `lo`.
    if lo > f_at_peak:
        hi = lo
        lo = 0
    for _ in range(12):
        var mid = (lo + hi) * 0.5
        var fm = _axis_force(tire, on_x, aa - b * mid, other_s, den, mu_eff, fz)
        if mid > fm:
            hi = mid
        else:
            lo = mid
    return sgn * (lo + hi) * 0.5


@always_inline
def _axis_force(
    tire: TireModel, on_x: Bool, s: Real, other_s: Real, den: Real, mu_eff: Real, fz: Real
) -> Real:
    if on_x:
        return tire.grip(s / den, other_s / den, mu_eff, fz)[0]
    return tire.grip(other_s / den, s / den, mu_eff, fz)[1]
