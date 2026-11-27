# tier: integration
"""One-step and multi-step light cones (ROADMAP 17.100 / 17.85).

1. Speculative margin with the rotation term: a plank spinning at 20 rad/s
   about its centre (centre still, tip at |w| r = 40 m/s) next to a box whose
   face is 0.1 m from the plank's side. The margin was `base + |v| dt`, so a
   still centre meant a 0.02 m margin and no contact until the plank had
   already swept into the box; with `|v| + |w| r` the pair exists after the
   first step, and the plank's sweep never sinks deep into the box.
2. CausalReach arrival time: a body 40 m from the observer closing at 30 m/s
   reaches the seed radius in (40 - 5) / 30 = 1.17 s. With horizons
   [0.5, 2.0] it takes tier 1 instead of the coarsest tier the contact graph
   gives it; the same body moving away keeps the coarsest tier; and with no
   horizons the plan is the graph-only plan.
"""

from harness.runner import Suite
from geometry.vec import Real, Vec3
from physics.rigid6 import Inertia3, QuatBody6
from physics.solver6 import ContactScene6
from gameplay.tiers import CausalReach

comptime DT: Real = 1.0 / 60.0
comptime ZERO = Vec3(0, 0, 0, 0)


def _spin_scene() -> ContactScene6[QuatBody6]:
    var sc = ContactScene6[QuatBody6]()
    var plank = sc.add(QuatBody6.at_rest(ZERO, Inertia3.box(1, 2, 0.05, 0.2)), Vec3(2, 0.05, 0.2, 0), False).index()
    sc.bset.bodies[plank].omega = Vec3(0, 20, 0, 0)
    _ = sc.add(QuatBody6.at_rest(Vec3(2, 0, -0.6, 0), Inertia3.box(1, 0.3, 0.3, 0.3)), Vec3(0.3, 0.3, 0.3, 0), False)
    return sc^


def main() raises:
    var s = Suite("light_cone")

    # 1. rotation term in the speculative margin
    var sc = _spin_scene()
    sc.step_soft(DT, ZERO)
    var paired = False
    for c in range(len(sc.cache)):
        if (sc.cache[c].a == 0 and sc.cache[c].b == 1) or (sc.cache[c].a == 1 and sc.cache[c].b == 0):
            paired = True
    print("  spinning plank: pair with the box after one step", paired, " pairs", len(sc.cache))
    s.check(paired, "a spinning plank with a still centre gets a speculative pair with the box its tip sweeps toward")
    var worst = Real(0)
    for _ in range(10):
        sc.step_soft(DT, ZERO)
        for c in range(len(sc.cache)):
            for k in range(sc.cache[c].m.count):
                worst = max(worst, sc.cache[c].m.depths[k])
    print("  deepest contact over the next 10 steps", worst)
    s.check(worst < 0.05, "the plank's sweep stays out of the box (deepest contact < 5 cm)")

    # 2. CausalReach arrival time
    var scene = ContactScene6[QuatBody6]()
    _ = scene.add(QuatBody6.at_rest(Vec3(0, -0.5, 0, 0), Inertia3.box(1, 60, 0.5, 60)), Vec3(60, 0.5, 60, 0), True)
    var near = scene.add(QuatBody6.at_rest(Vec3(1, 0.5, 0, 0), Inertia3.box(1, 0.5, 0.5, 0.5)), Vec3(0.5, 0.5, 0.5, 0), False).index()
    var inbound = scene.add(QuatBody6.at_rest(Vec3(40, 5, 0, 0), Inertia3.sphere(1, 0.2)), Vec3(0.2, 0.2, 0.2, 0), False).index()
    var outbound = scene.add(QuatBody6.at_rest(Vec3(0, 5, 40, 0), Inertia3.sphere(1, 0.2)), Vec3(0.2, 0.2, 0.2, 0), False).index()
    scene.bset.bodies[inbound].vel = Vec3(-30, 0, 0, 0)
    scene.bset.bodies[outbound].vel = Vec3(0, 0, 30, 0)
    var obs = List[Vec3]()
    obs.append(Vec3(0, 5, 0, 0))
    var d0: List[Int] = [0, 1]
    var graph = CausalReach(5, d0^)
    var plain = graph.assign(scene, obs, 0)
    var d1: List[Int] = [0, 1]
    var hz: List[Real] = [0.5, 2.0]
    var cone = CausalReach(5, d1^, hz^)
    var plan = cone.assign(scene, obs, 0)
    print("  tiers graph-only: near", plain[near], "inbound", plain[inbound], "outbound", plain[outbound],
          " with horizons: near", plan[near], "inbound", plan[inbound], "outbound", plan[outbound], " arriving", cone.arriving)
    s.check(plain[inbound] == 2 and plan[inbound] == 1, "a body arriving in 1.17 s takes the 2 s horizon's tier (1), not the coarsest (2)")
    s.check(plan[outbound] == plain[outbound], "a body moving away keeps its graph tier")
    s.check(plan[near] == plain[near], "a body the graph already ranks finest is unchanged")
    var d2: List[Int] = [0, 1]
    var empty = CausalReach(5, d2^, List[Real]())
    var same = empty.assign(scene, obs, 0)
    var all_same = len(same) == len(plain)
    for i in range(len(same)):
        if same[i] != plain[i]:
            all_same = False
    s.check(all_same, "no horizons: the graph-only plan, slot for slot")
    var raised = False
    try:
        var d3: List[Int] = [0, 1]
        var bad: List[Real] = [2.0, 1.0]
        _ = CausalReach(5, d3^, bad^)
    except:
        raised = True
    s.check(raised, "descending horizons raise")
    s.finish()
