"""ROADMAP 17.25: sleep API wake storm.

`wake(id)` scans every body in the scene once to find the ones sharing
`id`'s island label (`physics.islands.wake_island`) -- O(bodies), not
O(island size), by construction: it walks the same flat `BodySet` index
space `refresh_islands` already scans every step, just once instead of
per-step. This bench builds a single N-body island (island size == scene
size, the worst case for that scan) and times waking ONE already-settled
body in it repeatedly, at increasing N.
"""

from std.time import perf_counter_ns
from harness.bench import BenchTable
from geometry.vec import Real, Vec3
from physics.rigid6 import Inertia3, QuatBody6
from physics.solver6 import ContactScene6

comptime DT: Real = 1.0 / 60.0
comptime G = Vec3(0, -9.8, 0, 0)
comptime REPS = 3000


def _one_island(n: Int) raises -> ContactScene6[QuatBody6]:
    """N boxes shoulder-to-shoulder on a wide floor: touching neighbours
    union into ONE dynamic island (`refresh_islands`'s contact-graph
    union-find), then settle to sleep so the wake actually has sleeping
    state to flip."""
    var sc = ContactScene6[QuatBody6]()
    var half_w = Real(n) * 0.3 + 2
    _ = sc.add(
        QuatBody6.at_rest(Vec3(0, -0.5, 0, 0), Inertia3.box(1, half_w, 0.5, 2)),
        Vec3(half_w, 0.5, 2, 0),
        True,
    )
    var bi = Inertia3.box(1, 0.24, 0.24, 0.24)
    for i in range(n):
        var x = Real(i) * 0.48 - Real(n) * 0.24
        _ = sc.add(
            QuatBody6.at_rest(Vec3(x, 0.24, 0, 0), bi), Vec3(0.24, 0.24, 0.24, 0), False,
        )
    for _ in range(200):
        sc.step_soft(DT, G)
    return sc^


def _wake_storm(mut sc: ContactScene6[QuatBody6], mid: Int, reps: Int) raises -> Int:
    var id = sc.bset.id_of(mid)
    var t0 = Int(perf_counter_ns())
    for _ in range(reps):
        sc.wake(id)
    return Int(perf_counter_ns()) - t0


def main() raises:
    var t = BenchTable("Sleep API: wake(1 body) cost vs island/scene size")
    var ns = [16, 64, 256, 1024]
    for i in range(len(ns)):
        var n = ns[i]
        var sc = _one_island(n)
        var mid = n // 2 + 1  # a body in the middle of the island (slot 0 is the floor)
        t.add("wake 1 of N", n, "wake", _wake_storm(sc, mid, REPS), REPS)
    t.print_report()
