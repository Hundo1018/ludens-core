"""Torsion along a rope (ROADMAP 17.86, #101).

`RopeTwist` is a chain of twist angles, one per rope particle, joined by torsional springs. A segment of length `dl` with
torsional rigidity GJ has stiffness k = GJ / dl and each node carries the polar inertia `inertia` (kg m^2). Equations:

    I theta_i'' = k (theta_i-1 - 2 theta_i + theta_i+1) - c theta_i'

with the root angle driven (`set_root`) and the tip either free or held (`fix_tip`). Checked in `test_rope_twist`:
a held tip with the root turned by phi settles to a linear profile theta_i = phi (1 - i / (n - 1)) with root torque
GJ phi / L; a free tip settles to theta = phi everywhere with no torque; a step at the root travels at
c = dl sqrt(k / I) nodes per second; with c = 0 the energy deviation is first order in dt (7.8e-3 at dt = 0.01 max_dt, 3.9e-3 at half that), no drift.

The twist is a state beside the rope's positions: the rope's XPBD chain has no frame, so this does not bend the rope by
itself (a writhe / plectoneme model needs the frame-carrying `CosseratRod` or `StrandSet.twist`). It gives a game the
twist angle at each particle and the torque a driven end feels, for ropes that are wound, cranked or tied to a
rotating body.
"""

from std.math import sqrt, isfinite
from geometry.vec import Real


struct RopeTwist(Copyable, Movable):
    var theta: List[Real]
    var omega: List[Real]
    var k: Real  # segment stiffness, N m / rad
    var inertia: Real
    var damping: Real
    var tip_fixed: Bool
    var dl: Real

    def __init__(out self, n: Int, dl: Real, gj: Real, inertia: Real, damping: Real = 0) raises:
        if n < 2 or not (dl > 0) or not (gj > 0) or not (inertia > 0) or not (damping >= 0):
            raise Error("RopeTwist: need n >= 2, dl > 0, GJ > 0, inertia > 0, damping >= 0")
        if not isfinite(gj) or not isfinite(inertia) or not isfinite(damping):
            raise Error("RopeTwist: parameters must be finite")
        self.theta = List[Real](length=n, fill=0)
        self.omega = List[Real](length=n, fill=0)
        self.k = gj / dl
        self.inertia = inertia
        self.damping = damping
        self.tip_fixed = False
        self.dl = dl

    def count(self) -> Int:
        return len(self.theta)

    def set_root(mut self, angle: Real):
        self.theta[0] = angle
        self.omega[0] = 0

    def fix_tip(mut self, fixed: Bool):
        self.tip_fixed = fixed
        if fixed:
            self.theta[len(self.theta) - 1] = 0
            self.omega[len(self.omega) - 1] = 0

    def max_dt(self) -> Real:
        """Stability bound of the explicit update: 2 / omega_max, omega_max^2 = 4 k / I."""
        return sqrt(self.inertia / self.k)

    def step(mut self, dt: Real) raises:
        if not (dt > 0) or dt > self.max_dt():
            raise Error("RopeTwist.step: dt must be in (0, max_dt]")
        var n = len(self.theta)
        var last = n - 1 if not self.tip_fixed else n - 2
        for i in range(1, last + 1):
            var right = self.theta[i + 1] if i + 1 < n else self.theta[i]
            var tq = self.k * (self.theta[i - 1] - 2 * self.theta[i] + right) - self.damping * self.omega[i]
            self.omega[i] += dt * tq / self.inertia
        for i in range(1, last + 1):
            self.theta[i] += dt * self.omega[i]

    def root_torque(self) -> Real:
        """Torque the driver applies at the root to hold its angle."""
        return self.k * (self.theta[0] - self.theta[1])

    def energy(self) -> Real:
        var e = Real(0)
        for i in range(len(self.theta)):
            e += 0.5 * self.inertia * self.omega[i] * self.omega[i]
        for i in range(len(self.theta) - 1):
            var d = self.theta[i] - self.theta[i + 1]
            e += 0.5 * self.k * d * d
        return e
