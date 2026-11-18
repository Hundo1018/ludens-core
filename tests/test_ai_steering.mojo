# tier: unit  (override: spatial.cell_sort is the solver's internal neighbour grouping, not a second package under test)
"""Steering, flocking, formations (ROADMAP 17.15).

Ordinary: arrive stops on the target; pursue catches a moving quarry sooner
than seek; evade opens the distance; follow_path tracks an L-shaped path to
its end; wander is deterministic per seed and speed-capped; a 200-boid flock
aligns locally (mean neighbour cosine > 0.95 after 20 s) without collapsing (separation holds); wedge /
line / column slots in the leader frame; followers arrive at their slots.
Extreme: seek at the target (no NaN), empty / single-point path, a flock of
one, two runs bit-identical.
"""

from harness.runner import Suite
from std.math import sqrt
from geometry.vec import Real, Vec3, dot
from scheduler.rng import SplitMix64, Rng
from ai.steering import (
    seek,
    flee,
    arrive,
    pursue,
    evade,
    wander,
    follow_path,
    Flock,
    FlockParams,
    Formation,
    FORMATION_LINE,
    FORMATION_COLUMN,
    FORMATION_WEDGE,
)

comptime DT: Real = 1.0 / 30.0


def _v(x: Real, y: Real, z: Real) -> Vec3:
    return Vec3(x, y, z, 0)


def _len(v: Vec3) -> Real:
    return sqrt(dot(v, v))


def _cap(v: Vec3, m: Real) -> Vec3:
    var l = _len(v)
    return v * (m / l) if l > m else v


def _make_flock(seed: UInt64, n: Int) -> Flock:
    var f = Flock(FlockParams(3.0, 1.5, 1.0, 1.0, 2.0, 4.0, 1.0, 1.0))
    var rng = SplitMix64.seeded(seed)
    for _ in range(n):
        var p = _v(rng.next_f32() * 12, 0, rng.next_f32() * 12)
        var v = _v(rng.next_f32() * 2 - 1, 0, rng.next_f32() * 2 - 1)
        _ = f.add(p, v)
    return f^


def main() raises:
    var s = Suite("ai_steering")

    # arrive
    var p = _v(0, 0, 0)
    var v = _v(0, 0, 0)
    var tgt = _v(10, 0, 4)
    for _ in range(600):
        v = _cap(v + _cap(arrive(p, v, tgt, 3, 2), 6) * DT, 3)
        p = p + v * DT
    s.check(_len(p - tgt) < 0.05 and _len(v) < 0.05, "arrive: stops on the target")

    # pursue vs seek on a crossing quarry
    var steps_seek = 0
    var steps_pursue = 0
    for mode in range(2):
        var a = _v(0, 0, 0)
        var av = _v(0, 0, 0)
        var q = _v(10, 0, -5)
        var qv = _v(0, 0, 1.2)
        var k = 0
        while k < 2000 and _len(q - a) > 0.5:
            var st = seek(a, av, q, 2) if mode == 0 else pursue(a, av, q, qv, 2)
            av = _cap(av + _cap(st, 8) * DT, 2)
            a = a + av * DT
            q = q + qv * DT
            k += 1
        if mode == 0:
            steps_seek = k
        else:
            steps_pursue = k
    s.check(steps_pursue < steps_seek, "pursue catches sooner than seek (" + String(steps_pursue) + " < " + String(steps_seek) + ")")

    # evade opens distance
    var e = _v(0, 0, 0)
    var ev = _v(0, 0, 0)
    var hunter = _v(-3, 0, 0)
    var d0 = _len(e - hunter)
    for _ in range(90):
        ev = _cap(ev + _cap(evade(e, ev, hunter, _v(1, 0, 0), 2), 8) * DT, 2)
        e = e + ev * DT
        hunter = hunter + _v(1, 0, 0) * DT
    s.check(_len(e - hunter) > d0, "evade: distance grows")

    # follow an L-shaped path
    var path = List[Vec3]()
    path.append(_v(0, 0, 0))
    path.append(_v(10, 0, 0))
    path.append(_v(10, 0, 10))
    var fp = _v(0, 0, 0.5)
    var fv = _v(0, 0, 0)
    var worst = Real(0)
    for _ in range(900):
        fv = _cap(fv + _cap(follow_path(fp, fv, path, 1.0, 2), 8) * DT, 2)
        fp = fp + fv * DT
        var dev = min(abs(fp[2]) if fp[0] < 10 else Real(1e9), abs(fp[0] - 10) if fp[2] > 0 else Real(1e9))
        worst = max(worst, min(dev, Real(5)))
    s.check(_len(fp - _v(10, 0, 10)) < 0.1, "follow_path: ends at the path end")
    s.check(worst < 1.0, "follow_path: stays within 1 m of the path")

    # wander: deterministic, capped
    var traj = List[Vec3]()
    for _ in range(2):
        var wp = _v(0, 0, 0)
        var wv = _v(1, 0, 0)
        var ang = Real(0)
        var rng = UInt64(42)
        var maxsp = Real(0)
        for _ in range(300):
            wv = _cap(wv + _cap(wander(wp, wv, ang, rng, 1.5, 2, 1, 0.3), 4) * DT, 1.5)
            wp = wp + wv * DT
            maxsp = max(maxsp, _len(wv))
        traj.append(wp)
        s.check(maxsp <= 1.5001, "wander: speed capped")
    s.check(_len(traj[0] - traj[1]) == 0, "wander: same seed, same path")

    # extremes
    var z = seek(_v(1, 0, 1), _v(0, 0, 0), _v(1, 0, 1), 2)
    s.check(z[0] == z[0] and _len(z) == 0, "seek at the target: zero, no NaN")
    var empty = List[Vec3]()
    var ze = follow_path(_v(0, 0, 0), _v(1, 0, 0), empty, 1, 2)
    s.check(ze[0] == -1, "empty path: brake")

    # flock
    var f1 = _make_flock(7, 200)
    var f2 = _make_flock(7, 200)
    for _ in range(600):
        f1.step(DT)
        f2.step(DT)
    var same = True
    for i in range(200):
        if _len(f1.pos[i] - f2.pos[i]) != 0:
            same = False
    s.check(same, "flock: two runs bit-identical")
    # local order: mean cosine between each boid's heading and the mean
    # heading of its neighbours (what alignment acts on)
    var lsum = Real(0)
    var lcnt = 0
    for i in range(200):
        var m = Vec3(0)
        for j in range(200):
            if j != i and _len(f1.pos[j] - f1.pos[i]) < 3:
                m += f1.vel[j]
        var li = _len(f1.vel[i])
        var lm = _len(m)
        if li > 0 and lm > 0:
            lsum += dot(f1.vel[i], m) / (li * lm)
            lcnt += 1
    var local = lsum / Real(max(lcnt, 1))
    s.check(local > 0.95, "flock aligns locally: mean neighbour cosine " + String(local))
    s.check(f1.min_distance() > 0.3, "flock keeps separation: min distance " + String(f1.min_distance()))
    var lone = Flock(FlockParams(3.0, 1.5, 1.0, 1.0, 2.0, 4.0, 1.0, 1.0))
    _ = lone.add(_v(0, 0, 0), _v(1, 0, 0))
    lone.step(DT)
    s.check(abs(lone.pos[0][0] - DT) < 1e-6, "flock of one keeps its velocity")

    # formations: leader at origin facing +x
    var w = Formation(FORMATION_WEDGE, 2)
    var s0 = w.slot_world(_v(0, 0, 0), _v(1, 0, 0), 0)
    var s1 = w.slot_world(_v(0, 0, 0), _v(1, 0, 0), 1)
    s.check(s0[0] < 0 and s1[0] < 0, "wedge slots are behind the leader")
    s.check(abs(s0[2] + s1[2]) < 1e-6 and abs(s0[2]) > 1, "wedge slots mirror left / right")
    var col = Formation(FORMATION_COLUMN, 1.5)
    var c2 = col.slot_world(_v(5, 0, 5), _v(0, 0, 1), 2)
    s.check(_len(c2 - _v(5, 0, 0.5)) < 1e-5, "column slot 2 is 4.5 m behind")
    var line = Formation(FORMATION_LINE, 1)
    var l0 = line.slot_world(_v(0, 0, 0), _v(0, 0, 1), 0)
    s.check(abs(l0[2]) < 1e-6 and abs(abs(l0[0]) - 1) < 1e-6, "line slot beside the leader")
    # followers arrive at wedge slots while the leader walks
    var lead = _v(0, 0, 0)
    var fpos = List[Vec3]()
    var fvel = List[Vec3]()
    for i in range(4):
        fpos.append(_v(-Real(i) - 3, 0, Real(i) - 2))
        fvel.append(_v(0, 0, 0))
    for _ in range(600):
        lead = lead + _v(1, 0, 0) * DT
        for i in range(4):
            var slot = w.slot_world(lead, _v(1, 0, 0), i)
            fvel[i] = _cap(fvel[i] + _cap(arrive(fpos[i], fvel[i], slot + _v(1, 0, 0) * 0.5, 2.5, 1), 8) * DT, 2.5)
            fpos[i] = fpos[i] + fvel[i] * DT
    var err = Real(0)
    for i in range(4):
        err = max(err, _len(fpos[i] - w.slot_world(lead, _v(1, 0, 0), i)))
    s.check(err < 0.6, "followers hold their wedge slots (max error " + String(err) + " m)")
    s.finish()
