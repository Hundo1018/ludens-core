# tier: integration
"""Viscoelastic FEM, one Maxwell branch (ROADMAP 17.58, #93).

  1. Held strain: a beam stretched 5 % along x and held. The total nodal force norm follows (1 - g) + g exp(-(t - dt/2) / tau)
     times the elastic force (the strain jump falls in the middle of the first step), checked at t = tau/2, tau, 3 tau, 10 tau (g = 0.6, tau = 0.5 s) to 1e-4 relative.
  2. Step size: dt = 1e-3 and dt = 1e-2 give the same force at t = tau to 1e-5 relative.
  3. g = 0 gives `material_forces` bit for bit.
  4. Damping: a free-ending cantilever released from a bent shape; the late tip amplitude (summed over 9 tip nodes, start 0.18: elastic 0.172, g = 0.5 0.119) is below 0.8x
     the elastic one, so the relaxing branch dissipates.
"""

from std.math import sqrt, exp
from harness.runner import Suite
from geometry.vec import Real, Vec3
from physics.fem import FemBody, make_beam
from physics.fem_material import StableNeoHookean, material_forces
from physics.fem_visco import ViscoState, visco_forces, step_visco


def beam() -> FemBody:
    var b = FemBody(1.0e6, 0.3, 0.0)
    make_beam(b, 6, 2, 2, 0.1, 1.0)
    return b^


def norm(fx: List[Real], fy: List[Real], fz: List[Real]) -> Real:
    var s = Real(0)
    for i in range(len(fx)):
        s += fx[i] * fx[i] + fy[i] * fy[i] + fz[i] * fz[i]
    return sqrt(s)


def stretch(mut b: FemBody, s: Real):
    for i in range(b.node_count()):
        b.x[i] *= s


def force_at(g: Real, tau: Real, dt: Real, t_end: Real) raises -> Real:
    var b = beam()
    var st = ViscoState(b, tau, g)
    st.reset_rest[StableNeoHookean](b)
    stretch(b, 1.05)
    var n = b.node_count()
    var t = Real(0)
    var last = Real(0)
    while t < t_end - dt * 0.5:
        var fx = List[Real](length=n, fill=0)
        var fy = List[Real](length=n, fill=0)
        var fz = List[Real](length=n, fill=0)
        visco_forces[StableNeoHookean](st, b, dt, fx, fy, fz)
        last = norm(fx, fy, fz)
        t += dt
    return last


def main() raises:
    var s = Suite("fem_visco")
    var b0 = beam()
    stretch(b0, 1.05)
    var n = b0.node_count()
    var ex = List[Real](length=n, fill=0)
    var ey = List[Real](length=n, fill=0)
    var ez = List[Real](length=n, fill=0)
    material_forces[StableNeoHookean](b0, ex, ey, ez)
    var fe = norm(ex, ey, ez)
    var g = Real(0.6)
    var tau = Real(0.5)
    var times = List[Real]()
    times.append(0.25)
    times.append(0.5)
    times.append(1.5)
    times.append(5.0)
    for k in range(len(times)):
        var got = force_at(g, tau, 0.001, times[k]) / fe
        var want = (1 - g) + g * Real(exp(Float64(-(times[k] - 0.0005) / tau)))
        var rel = abs(got - want) / want
        s.check(rel < 1e-4, "t = " + String(times[k]) + " s: force / elastic " + String(got) + ", analytic " + String(want))
    var a = force_at(g, tau, 0.001, 0.5)
    var c = force_at(g, tau, 0.01, 0.5)
    # the strain jump falls in the middle of the first step, so the effective time is t - dt / 2
    var wa = fe * ((1 - g) + g * Real(exp(Float64(-(0.5 - 0.0005) / tau))))
    var wc = fe * ((1 - g) + g * Real(exp(Float64(-(0.5 - 0.005) / tau))))
    s.check(abs(a - wa) / wa < 1e-4 and abs(c - wc) / wc < 1e-4, "dt 1e-3 and 1e-2 each match the analytic value at t - dt/2: " + String(a) + " (" + String(wa) + "), " + String(c) + " (" + String(wc) + ")")

    var b1 = beam()
    var st0 = ViscoState(b1, tau, 0.0)
    st0.reset_rest[StableNeoHookean](b1)
    stretch(b1, 1.05)
    var gx = List[Real](length=n, fill=0)
    var gy = List[Real](length=n, fill=0)
    var gz = List[Real](length=n, fill=0)
    visco_forces[StableNeoHookean](st0, b1, 0.01, gx, gy, gz)
    var same = True
    for i in range(n):
        if gx[i] != ex[i] or gy[i] != ey[i] or gz[i] != ez[i]:
            same = False
    s.check(same, "g = 0 equals material_forces bit for bit")

    # damping of a vibrating cantilever
    var amp0 = Real(0)
    var amp1 = Real(0)
    for pass_ in range(2):
        var gg = Real(0) if pass_ == 0 else Real(0.5)
        var b = beam()
        for i in range(b.node_count()):
            if b.x[i] < 1e-6:
                b.pin(i)
        var st = ViscoState(b, 0.02, gg)
        st.reset_rest[StableNeoHookean](b)
        var rest_tip = Real(0)
        for i in range(b.node_count()):
            if b.x[i] > 0.55:
                rest_tip += b.y[i]
        for i in range(b.node_count()):
            b.y[i] -= 0.02 * (b.x[i] / 0.6) ** 2
        var peak_late = Real(0)
        for step in range(6000):
            step_visco[StableNeoHookean](st, b, 0.0001, Vec3(0, 0, 0, 0))
            if step >= 4000:
                var tip = Real(0)
                for i in range(b.node_count()):
                    if b.x[i] > 0.55:
                        tip += b.y[i]
                peak_late = max(peak_late, abs(tip - rest_tip))
        if pass_ == 0:
            amp0 = peak_late
        else:
            amp1 = peak_late
    s.check(amp1 < 0.8 * amp0 and amp0 > 0, "late tip amplitude: elastic " + String(amp0) + ", g = 0.5 " + String(amp1))
    s.finish()
