"""Fire on a grid: fuel that ignites, burns and heats its neighbours (ROADMAP 17.61 fire / combustion, #95).

`FireGrid` is a `HeatGrid` (conduction, `physics.thermal`) plus a fuel amount per cell. Each step conducts heat, then
reacts every cell that is hot enough:

    T >= t_ignite and fuel > 0:   burned = fuel (1 - exp(-k dt));  fuel -= burned;  T += heat_per_fuel * burned

The exponential makes the burn independent of the step size (a step of 2 dt burns what two steps of dt do). The heat
a cell gains is exactly `heat_per_fuel` times the fuel it lost, which `released` (the sum of both over the run) lets a
test check; with no conduction a cell that burns out ends at T0 + heat_per_fuel * fuel0, the adiabatic rise.

A flame travels because a burning cell heats the next one past `t_ignite`; the front speed grows with the square
root of the product of diffusivity and burn rate (`test_combustion` measures it, a 4x faster burn runs about 2x
faster). It is a single-fuel, oxygen-unlimited model: no flame buoyancy, no smoke, no radiation. Those need the gas
solver (`physics.mac_*`) and are not here.

Temperatures are Kelvin and checked as `physics.thermal` does; the step is refused above `HeatGrid.max_dt`.
"""

from std.math import exp, isfinite
from geometry.vec import Real
from .thermal import HeatGrid


struct FireGrid(Movable):
    var heat: HeatGrid
    var fuel: List[Real]
    var t_ignite: Real
    var k: Real  # burn rate, 1/s
    var heat_per_fuel: Real  # K of temperature rise per unit of fuel burned
    var released: Float64  # sum of heat_per_fuel * burned over all steps (K x cells)
    var burned_total: Float64  # sum of fuel burned

    def __init__(
        out self, nx: Int, ny: Int, nz: Int, dx: Real, alpha: Real, t0: Real, t_ignite: Real, k: Real, heat_per_fuel: Real
    ) raises:
        if not (t_ignite > t0) or not (k > 0) or not (heat_per_fuel > 0) or not isfinite(k) or not isfinite(heat_per_fuel):
            raise Error("FireGrid: need t_ignite > t0, k > 0 and heat_per_fuel > 0, all finite")
        self.heat = HeatGrid(nx, ny, nz, dx, alpha, t0)
        self.fuel = List[Real](length=nx * ny * nz, fill=0)
        self.t_ignite = t_ignite
        self.k = k
        self.heat_per_fuel = heat_per_fuel
        self.released = 0
        self.burned_total = 0

    def set_fuel(mut self, i: Int, j: Int, k: Int, amount: Real) raises:
        if not isfinite(amount) or amount < 0:
            raise Error("FireGrid: fuel must be finite and >= 0")
        self.fuel[self.heat.idx(i, j, k)] = amount

    def ignite(mut self, i: Int, j: Int, k: Int, temp: Real) raises:
        """Heat one cell to `temp` (a spark); it burns from the next step if it holds fuel and temp >= t_ignite."""
        if not isfinite(temp) or temp <= 0:
            raise Error("FireGrid: ignition temperature must be finite and > 0")
        self.heat.t[self.heat.idx(i, j, k)] = temp

    def max_dt(self) -> Real:
        return self.heat.max_dt()

    def step(mut self, dt: Real) raises:
        self.heat.step(dt)
        var f = Real(1) - Real(exp(Float64(-self.k * dt)))
        for c in range(len(self.fuel)):
            if self.fuel[c] > 0 and self.heat.t[c] >= self.t_ignite and not self.heat.fixed[c]:
                var burned = self.fuel[c] * f
                self.fuel[c] -= burned
                self.heat.t[c] += self.heat_per_fuel * burned
                self.released += Float64(self.heat_per_fuel * burned)
                self.burned_total += Float64(burned)

    def burning(self) -> Int:
        """Cells that burn on the next step: hot enough and still holding fuel (above a trace)."""
        var n = 0
        for c in range(len(self.fuel)):
            if self.fuel[c] > 1e-6 and self.heat.t[c] >= self.t_ignite:
                n += 1
        return n

    def fuel_left(self) -> Float64:
        var s = Float64(0)
        for v in self.fuel:
            s += Float64(v)
        return s

    def front(self, j: Int = 0, k: Int = 0) -> Int:
        """The largest x index on row (j, k) that is burning now, or -1."""
        var best = -1
        for i in range(self.heat.nx):
            var c = self.heat.idx(i, j, k)
            if self.fuel[c] > 1e-6 and self.heat.t[c] >= self.t_ignite:
                best = i
        return best
