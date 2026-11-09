"""Engine, gearbox and differentials for the raycast vehicle (ROADMAP 17.4).

Pure arithmetic with no scene access, so it is unit-tested on its own
(`test_vehicle_drive`). The chain, per step:

    throttle -> torque curve at engine rpm -> gear ratio * final drive
             -> centre split between axles -> axle differential -> wheel torque

ENGINE RPM follows the driven wheels through the gearbox (a locked clutch)
except at launch: below `launch_rpm` the clutch is taken to slip and the
engine runs at `launch_rpm` under throttle, so a standing start has torque
instead of stalling at idle. Above `redline_rpm` fuel is cut. Off the throttle
the engine drags with `engine_brake` Nm at redline, scaling linearly with rpm.

DIFFERENTIALS split an axle's torque between its two wheels:
* open    equal torque. A wheel on ice gets as much as one on tarmac, which is
          the model of a real open differential's torque equality; the
          approximation is that the tarmac wheel is NOT also limited to the
          ice wheel's tiny torque (see TODO in ROADMAP 17.4).
* limited-slip  moves torque from the faster wheel to the slower one by
          `preload + lock * |dw|` (Nm), capped at `max_bias`.
* locked  both wheels get the torque a spool would give a stuck pair: the
          bias is unbounded (up to the whole axle torque).
"""

from std.math import sqrt
from geometry.vec import Real

comptime DIFF_OPEN = 0
comptime DIFF_LSD = 1
comptime DIFF_LOCKED = 2

comptime RAD_S_TO_RPM: Real = 9.549297  # 60 / (2 pi)


struct TorqueCurve(Copyable, Movable):
    """Piecewise-linear engine torque (Nm) over rpm; clamped at both ends."""

    var rpm: List[Real]
    var torque: List[Real]

    def __init__(out self):
        self.rpm = List[Real]()
        self.torque = List[Real]()

    def __init__(out self, *, copy: Self):
        self.rpm = copy.rpm.copy()
        self.torque = copy.torque.copy()

    def add(mut self, rpm: Real, torque: Real):
        self.rpm.append(rpm)
        self.torque.append(torque)

    @staticmethod
    def constant(torque: Real) -> Self:
        var c = Self()
        c.add(0, torque)
        c.add(20000, torque)
        return c^

    @staticmethod
    def sedan() -> Self:
        """A 1.8-2.0 L petrol engine: 300 Nm plateau from 3500 to 5000 rpm."""
        var c = Self()
        c.add(0, 120)
        c.add(1000, 180)
        c.add(2000, 250)
        c.add(3500, 300)
        c.add(5000, 300)
        c.add(6000, 260)
        c.add(7000, 150)
        return c^

    @staticmethod
    def diesel_truck() -> Self:
        """A 7-10 L turbo diesel: 1800 Nm from 1200 to 1600 rpm, falling off above 2000 rpm (governed near 2500)."""
        var c = Self()
        c.add(0, 900)
        c.add(600, 1100)
        c.add(1000, 1600)
        c.add(1200, 1800)
        c.add(1600, 1800)
        c.add(2000, 1500)
        c.add(2400, 900)
        c.add(2600, 200)
        return c^

    def at(self, r: Real) -> Real:
        var n = len(self.rpm)
        if n == 0:
            return 0
        if r <= self.rpm[0]:
            return self.torque[0]
        for i in range(1, n):
            if r <= self.rpm[i]:
                var t = (r - self.rpm[i - 1]) / (self.rpm[i] - self.rpm[i - 1])
                return self.torque[i - 1] + (self.torque[i] - self.torque[i - 1]) * t
        return self.torque[n - 1]


struct DriveConfig(Copyable, Movable):
    var torque: TorqueCurve
    var idle_rpm: Real
    var launch_rpm: Real
    var redline_rpm: Real
    var gears: List[Real]  # forward ratios, gear 1 first
    var reverse_ratio: Real
    var final_drive: Real
    var efficiency: Real
    var engine_brake: Real  # Nm at redline with the throttle closed
    var up_rpm: Real  # automatic upshift above this
    var down_rpm: Real  # automatic downshift below this
    var shift_time: Real  # torque is cut this long during a shift
    var front_bias: Real  # share of torque to the front axle when both are driven
    var diff_kind: Int
    var diff_preload: Real
    var diff_lock: Real  # Nm per rad/s of wheel speed difference
    var diff_max: Real  # cap on the torque moved by a limited-slip
    var axle_diff_kind: Int  # between two driven axles (DIFF_OPEN = the fixed split of `front_bias` / equal)
    var axle_diff_preload: Real  # Nm moved to the slower axle at equal speed
    var axle_diff_lock: Real  # Nm per rad/s of axle speed difference
    var axle_diff_max: Real

    def __init__(out self):
        self.torque = TorqueCurve.sedan()
        self.idle_rpm = 900
        self.launch_rpm = 2500
        self.redline_rpm = 6500
        self.gears = [Real(3.6), Real(2.1), Real(1.45), Real(1.05), Real(0.8)]
        self.reverse_ratio = 3.4
        self.final_drive = 3.6
        self.efficiency = 0.9
        self.engine_brake = 60
        self.up_rpm = 6000
        self.down_rpm = 2800
        self.shift_time = 0.25
        self.front_bias = 0.4
        self.diff_kind = DIFF_OPEN
        self.diff_preload = 50
        self.diff_lock = 60
        self.diff_max = 1500
        self.axle_diff_kind = DIFF_OPEN
        self.axle_diff_preload = 200
        self.axle_diff_lock = 400
        self.axle_diff_max = 6000

    def __init__(out self, *, copy: Self):
        self.torque = copy.torque.copy()
        self.idle_rpm = copy.idle_rpm
        self.launch_rpm = copy.launch_rpm
        self.redline_rpm = copy.redline_rpm
        self.gears = copy.gears.copy()
        self.reverse_ratio = copy.reverse_ratio
        self.final_drive = copy.final_drive
        self.efficiency = copy.efficiency
        self.engine_brake = copy.engine_brake
        self.up_rpm = copy.up_rpm
        self.down_rpm = copy.down_rpm
        self.shift_time = copy.shift_time
        self.front_bias = copy.front_bias
        self.diff_kind = copy.diff_kind
        self.diff_preload = copy.diff_preload
        self.diff_lock = copy.diff_lock
        self.diff_max = copy.diff_max
        self.axle_diff_kind = copy.axle_diff_kind
        self.axle_diff_preload = copy.axle_diff_preload
        self.axle_diff_lock = copy.axle_diff_lock
        self.axle_diff_max = copy.axle_diff_max

    def gear_ratio(self, gear: Int) -> Real:
        """Overall engine-to-wheel ratio of `gear` (1..n forward, -1 reverse,
        0 neutral = 0)."""
        if gear == 0:
            return 0
        if gear < 0:
            return self.reverse_ratio * self.final_drive
        var g = gear if gear <= len(self.gears) else len(self.gears)
        return self.gears[g - 1] * self.final_drive

    def engine_rpm(self, wheel_rpm: Real, throttle: Real) -> Real:
        """Engine speed given the driven wheels' speed (already multiplied up
        through the gearbox): the clutch slips to `launch_rpm` under throttle."""
        var r = wheel_rpm
        if throttle > 0.05 and r < self.launch_rpm:
            r = self.launch_rpm
        if r < self.idle_rpm:
            r = self.idle_rpm
        return r

    def engine_torque(self, rpm: Real, wheel_rpm: Real, throttle: Real) -> Real:
        """Crank torque (Nm): the curve under throttle, fuel cut above redline,
        negative engine braking when the throttle is closed."""
        if wheel_rpm > self.redline_rpm and throttle > 0:
            return 0
        if throttle > 0.02:
            return self.torque.at(rpm) * throttle
        return -self.engine_brake * (wheel_rpm / self.redline_rpm)


def split_axle(
    kind: Int,
    torque: Real,
    w_left: Real,
    w_right: Real,
    preload: Real,
    lock: Real,
    max_bias: Real,
) -> Tuple[Real, Real]:
    """Wheel torques (left, right) of one axle for total axle `torque` and
    wheel speeds `w_*` (rad/s, forward positive)."""
    var half = torque * 0.5
    if kind == DIFF_OPEN:
        return (half, half)
    var dw = w_left - w_right  # > 0: the left wheel is faster
    var mag = dw if dw >= 0 else -dw
    var bias = preload + lock * mag
    if kind == DIFF_LOCKED:
        bias = 1.0e9
    if bias > max_bias and kind != DIFF_LOCKED:
        bias = max_bias
    # The torque moved to the slower wheel can never exceed what the faster
    # one has to give, or the faster wheel would be braked by the diff.
    var cap = half if half >= 0 else -half
    if bias > cap * 2:
        bias = cap * 2
    var shift = bias * 0.5
    if torque < 0:
        shift = -shift
    # Faster wheel gives `shift`, slower wheel receives it. A near-equal speed
    # pair with zero preload moves nothing.
    if dw > 0:
        return (half - shift, half + shift)
    if dw < 0:
        return (half + shift, half - shift)
    return (half, half)
