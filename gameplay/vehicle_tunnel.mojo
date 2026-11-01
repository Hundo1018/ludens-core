"""A coarse virtual wind tunnel for a car shape: LBM Cd -> vehicle drag (ROADMAP 17.4).

The differentiator of this vehicle model is not the wheel code (every engine
has one) but that the body's drag coefficient can come from the engine's own
fluid solver. This builds a voxel car in a `fluid.lbm.Lbm` tunnel, runs it to a
quasi-steady state, averages the momentum-exchange force on the solid (ROADMAP
14.4) and reports `Cd = Fx / (1/2 rho u^2 A)`. `Aero.from_cd` turns the number
into the vehicle's aerodynamic drag.

HONEST LIMITS. The lattice Reynolds number is ~25-50 (a real car is ~1e6), the
car is a staircase voxelisation, there is no ground plane or moving floor and
the blockage ratio is a few percent -- so the ABSOLUTE Cd is a lattice number,
not a road car's. What carries over is the ordering of shapes (a sloped nose
measures lower than a flat one, `test_vehicle_aero`) and the plumbing: any
future higher-resolution or GPU tunnel (`fluid/lbm_gpu`) yields a Cd that
drops into the same `Aero`. `scaled_cd` lets a caller calibrate a lattice
result against a known reference shape.
"""

from geometry.trig import sin, cos
from geometry.vec import Real
from fluid.lbm import Lbm, BC_TUNNEL, CELL_SOLID


@fieldwise_init
struct CarShape(Copyable, ImplicitlyCopyable, Movable):
    """A voxel car: a body block of `length x height x width` cells with a
    cabin on top, and a nose cut away at `nose_slope` cells of height per
    cell of length (0 = flat-fronted brick)."""

    var length: Int
    var height: Int
    var width: Int
    var cabin_length: Int
    var cabin_height: Int
    var nose_slope: Real  # hood rise per cell, 0 = square front
    var tail_slope: Real  # the same toward the rear (boat tail), 0 = square back

    @staticmethod
    def boxy() -> Self:
        return Self(20, 5, 9, 8, 3, 0.0, 0.0)

    @staticmethod
    def streamlined() -> Self:
        return Self(20, 5, 9, 8, 3, 0.5, 0.5)


@fieldwise_init
struct TunnelResult(Copyable, ImplicitlyCopyable, Movable):
    var cd: Real  # lattice drag coefficient
    var area: Int  # frontal area, cells
    var fx: Real  # mean streamwise force, lattice units
    var steps: Int


def _solid(s: CarShape, x: Int, y: Int, z: Int, x0: Int, y0: Int, z0: Int) -> Bool:
    var lx = x - x0
    var ly = y - y0
    var lz = z - z0
    if lz < 0 or lz >= s.width or lx < 0 or lx >= s.length or ly < 0:
        return False
    if ly < s.height:
        # body block; the hood rises from the nose by `nose_slope` per cell
        var hood = Real(s.height)
        if s.nose_slope > 0:
            hood = min(hood, 1 + Real(lx) * s.nose_slope)
        if s.tail_slope > 0:
            hood = min(hood, 1 + Real(s.length - 1 - lx) * s.tail_slope)
        return Real(ly) < hood
    # cabin: narrower, sits over the middle of the body
    var cx0 = (s.length - s.cabin_length) // 2 + 1
    if ly < s.height + s.cabin_height and lx >= cx0 and lx < cx0 + s.cabin_length:
        var inset = 1
        return lz >= inset and lz < s.width - inset
    return False


def car_cd(
    shape: CarShape,
    nx: Int = 48,
    ny: Int = 24,
    nz: Int = 24,
    u: Real = 0.05,
    nu: Real = 0.02,
    steps: Int = 800,
    avg: Int = 200,
) -> TunnelResult:
    """Run the tunnel and return the time-averaged drag coefficient."""
    var t = Lbm(nx, ny, nz, nu, BC_TUNNEL)
    t.init_uniform(1.0, u, 0, 0)
    t.inlet_u = u
    var x0 = nx // 4
    var y0 = (ny - (shape.height + shape.cabin_height)) // 2
    var z0 = (nz - shape.width) // 2
    for z in range(nz):
        for y in range(ny):
            for x in range(nx):
                if _solid(shape, x, y, z, x0, y0, z0):
                    t.flag[t.idx(x, y, z)] = CELL_SOLID
    # frontal area: (y, z) columns with any solid cell
    var area = 0
    for z in range(nz):
        for y in range(ny):
            var any = False
            for x in range(nx):
                if t.flag[t.idx(x, y, z)] == CELL_SOLID:
                    any = True
                    break
            if any:
                area += 1
    var acc = Real(0)
    var m = 0
    for k in range(steps):
        t.step()
        if k >= steps - avg:
            acc += t.fx
            m += 1
    var fx = acc / Real(m)
    return TunnelResult(fx / (Real(0.5) * u * u * Real(area)), area, fx, steps)


def scaled_cd(measured: Real, reference_measured: Real, reference_real: Real) -> Real:
    """Calibrate a lattice Cd against a reference shape whose real Cd is known:
    `real = measured * (reference_real / reference_measured)`."""
    if reference_measured <= 0:
        return measured
    return measured * (reference_real / reference_measured)


@fieldwise_init
struct PolarPoint(Copyable, ImplicitlyCopyable, Movable):
    var alpha: Real  # angle of attack, radians
    var cl: Real  # lift coefficient on chord x span, lattice
    var cd: Real  # drag coefficient on chord x span, lattice


def plate_polar(
    alpha: Real,
    chord: Int = 16,
    nx: Int = 112,
    ny: Int = 96,
    nz: Int = 4,
    u: Real = 0.05,
    nu: Real = 0.02,
    steps: Int = 2400,
    avg: Int = 300,
) -> PolarPoint:
    """Lift and drag of a 2-cell-thick flat plate at angle of attack `alpha`
    in an `Lbm` tunnel, spanning the periodic z axis (an infinite wing), as
    force over 1/2 u^2 chord span. The lattice Reynolds number is
    u chord / nu = 40, so the numbers are a viscous-flow polar, not a
    high-Re airfoil's (a plate there gives CL ~ 2 pi alpha)."""
    var t = Lbm(nx, ny, nz, nu, BC_TUNNEL)
    t.init_uniform(1.0, u, 0, 0)
    t.inlet_u = u
    var xc = Real(nx // 4 + chord // 2)
    var yc = Real(ny // 2)
    var ca = cos(alpha)
    var sa = sin(alpha)
    for z in range(nz):
        for y in range(ny):
            for x in range(nx):
                var dx = Real(x) - xc
                var dy = Real(y) - yc
                # chord runs leading edge -> trailing edge along (cos a, -sin a)
                var s = dx * ca - dy * sa
                var n = dx * sa + dy * ca
                if abs(s) <= Real(chord) * 0.5 and abs(n) <= 1.0:
                    t.flag[t.idx(x, y, z)] = CELL_SOLID
    var fx = Real(0)
    var fy = Real(0)
    var m = 0
    for k in range(steps):
        t.step()
        if k >= steps - avg:
            fx += t.fx
            fy += t.fy
            m += 1
    var q = Real(0.5) * u * u * Real(chord * nz)
    return PolarPoint(alpha, fy / Real(m) / q, fx / Real(m) / q)
