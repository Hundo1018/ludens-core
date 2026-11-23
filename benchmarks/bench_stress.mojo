"""Stress and scale benchmark: the hard cases the per-feature benches leave out.

Physics scenes, each timed per tick (p50 / p99 / max, so a single slow tick shows), 4 substeps x 4 iterations,
broadphase on:
  * tower: 30 unit boxes stacked -- one deep Gauss-Seidel chain (every impulse reaches the floor through 30 contacts);
  * pyramid: 20 rows (210 boxes) -- a wide and deep island;
  * pit: N boxes dropped as a dense column into a walled pit, measured once they have piled up into one island
    (the island-parallel path cannot split it);
  * wake storm: N boxes resting in a layer until every one sleeps, then all woken in the same tick by an upward kick
    (the tick that pays for the whole set waking at once).
Scale, to see whether cost stays proportional to the entity count:
  * ECS movement system (query [Position, Velocity], integrate) over 1e4 / 1e5 / 1e6 entities, sparse-set and
    archetype (SoA views) backends;
  * physics: one layer of N resting boxes, awake (first ticks) and asleep (steady state), N up to 1e5.

    pixi run mojo run -I build benchmarks/bench_stress.mojo [quick]

`quick` uses the smaller sizes only (for a smoke run).
"""

from std.sys import argv
from std.benchmark import keep
from harness.bench import now
from geometry.vec import Vec2, Vec3, Real
from physics.rigid6 import Inertia3, QuatBody6
from physics.solver6 import ContactScene6
from ecs.world import World
from ecs.sparse_backend import SparseSetBackend
from ecs.archetype import ArchetypeBackend
from ecs.component import ComponentType

comptime DT: Real = 1.0 / 60.0
comptime G = Vec3(0, -9.81, 0, 0)


@fieldwise_init
struct Pos2(ComponentType):
    comptime ID: Int = 0
    var p: Vec2


@fieldwise_init
struct Vel2(ComponentType):
    comptime ID: Int = 1
    var v: Vec2


def _v(x: Real, y: Real, z: Real) -> Vec3:
    return Vec3(x, y, z, 0)


def _floor(mut sc: ContactScene6[QuatBody6], half: Real):
    _ = sc.add(QuatBody6.at_rest(_v(0, -0.5, 0), Inertia3.box(1, half, 0.5, half)), _v(half, 0.5, half), True)


def _box(mut sc: ContactScene6[QuatBody6], p: Vec3) -> Int:
    return sc.add(QuatBody6.at_rest(p, Inertia3.box(1, 0.5, 0.5, 0.5)), _v(0.5, 0.5, 0.5), False).index()


def _pct(var xs: List[Int], q: Float64) -> Float64:
    """Nearest-rank percentile in ms."""
    if len(xs) == 0:
        return 0
    sort(xs)
    var k = min(len(xs) - 1, Int(Float64(len(xs)) * q))
    return Float64(xs[k]) / 1e6


def _ticks(mut sc: ContactScene6[QuatBody6], n: Int) -> List[Int]:
    var out = List[Int]()
    for _ in range(n):
        var t0 = now()
        sc.step_soft(DT, G, broadphase=True)
        out.append(now() - t0)
    return out^


def _row(name: String, bodies: Int, xs: List[Int], note: String):
    print("|", name, "|", bodies, "|", len(xs), "|", _pct(xs.copy(), 0.5), "|", _pct(xs.copy(), 0.99), "|",
          _pct(xs.copy(), 1.0), "|", note, "|")


def _awake(sc: ContactScene6[QuatBody6]) -> Int:
    var a = 0
    for i in range(len(sc.bset.bodies)):
        if sc.bset.is_dynamic(i) and not sc.bset.sleeping[i]:
            a += 1
    return a


def tower(h: Int):
    var sc = ContactScene6[QuatBody6]()
    _floor(sc, 20)
    for i in range(h):
        _ = _box(sc, _v(0, 0.5 + Real(i) * 1.0, 0))
    var xs = _ticks(sc, 120)
    var top = sc.bset.bodies[h].position()[1]
    _row("tower " + String(h), h, xs, "top y " + String(top) + " (rest " + String(Real(h) - 0.5) + "), islands " + String(sc.island_count()))


def pyramid(rows: Int):
    var sc = ContactScene6[QuatBody6]()
    _floor(sc, 40)
    var n = 0
    for r in range(rows):
        for c in range(rows - r):
            _ = _box(sc, _v(Real(c) * 1.02 - Real(rows - r) * 0.51, 0.5 + Real(r) * 1.0, 0))
            n += 1
    var xs = _ticks(sc, 120)
    _row("pyramid " + String(rows) + " rows", n, xs, "islands " + String(sc.island_count()) + ", awake " + String(_awake(sc)))


def pit(n: Int, settle: Int, measure: Int):
    """A dense column of boxes in a pit of side ~sqrt(n)/2: they fall, pile and touch, forming one island."""
    var sc = ContactScene6[QuatBody6]()
    _floor(sc, 200)
    var side = 1
    while side * side * 4 < n:
        side += 1
    var w = Real(side) * 1.1 * 0.5 + 0.5
    for s in range(4):  # walls
        var x = (w + 0.5) if s == 0 else (-(w + 0.5) if s == 1 else Real(0))
        var z = (w + 0.5) if s == 2 else (-(w + 0.5) if s == 3 else Real(0))
        var hx = Real(0.5) if s < 2 else w + 1
        var hz = Real(0.5) if s >= 2 else w + 1
        _ = sc.add(QuatBody6.at_rest(_v(x, 20, z), Inertia3.box(1, hx, 20, hz)), _v(hx, 20, hz), True)
    for i in range(n):  # brick pattern: odd layers shifted half a box, so each box rests on up to four below
        var layer = i // (side * side)
        var k = i % (side * side)
        var off = Real(0.5) if layer % 2 == 1 else Real(0)
        var x = Real(k % side) * 1.02 - w + 1 + off
        var z = Real(k // side) * 1.02 - w + 1 + off
        if off > 0 and (k % side == side - 1 or k // side == side - 1):
            x -= 0.5  # the shifted row would hit the wall; drop it back
            z -= 0.5
        _ = _box(sc, _v(x, 0.6 + Real(layer) * 1.05, z))
    _ = _ticks(sc, settle)
    var xs = _ticks(sc, measure)
    _row("pit " + String(n), n, xs, "after " + String(settle) + " ticks: islands " + String(sc.island_count()) + ", pairs " + String(len(sc.cache)) + ", awake " + String(_awake(sc)))


def wake_storm(n: Int) raises:
    var sc = ContactScene6[QuatBody6]()
    var side = 1
    while side * side < n:
        side += 1
    _floor(sc, Real(side) * 0.6 + 5)
    var ids = List[Int]()
    for i in range(n):
        ids.append(_box(sc, _v(Real(i % side) * 1.2 - Real(side) * 0.6, 0.5, Real(i // side) * 1.2 - Real(side) * 0.6)))
    var ticks = 0
    while _awake(sc) > 0 and ticks < 600:
        sc.step_soft(DT, G, broadphase=True)
        ticks += 1
    var asleep = _ticks(sc, 30)
    _row("wake storm " + String(n) + ": all asleep", n, asleep, "asleep after " + String(ticks) + " ticks")
    # every body kicked up in the same tick
    for k in range(len(ids)):
        sc.bset.bodies[ids[k]].vel = _v(0, 3, 0)
        sc.bset.sleeping[ids[k]] = False
        sc.bset.sleep_timer[ids[k]] = 0
    var t0 = now()
    sc.step_soft(DT, G, broadphase=True)
    var first = now() - t0
    var after = _ticks(sc, 30)
    var one = List[Int]()
    one.append(first)
    _row("wake storm " + String(n) + ": the waking tick", n, one, "awake " + String(_awake(sc)))
    _row("wake storm " + String(n) + ": next 30 ticks", n, after, "")


def layer(n: Int, awake_ticks: Int) raises:
    var sc = ContactScene6[QuatBody6]()
    var side = 1
    while side * side < n:
        side += 1
    _floor(sc, Real(side) * 0.6 + 5)
    for i in range(n):
        _ = _box(sc, _v(Real(i % side) * 1.2 - Real(side) * 0.6, 0.5, Real(i // side) * 1.2 - Real(side) * 0.6))
    var t0 = now()
    var xs = _ticks(sc, awake_ticks)
    _row("layer " + String(n) + ": awake", n, xs, "per body " + String(_pct(xs.copy(), 0.5) * 1e6 / Float64(n)) + " ns")
    var ticks = awake_ticks
    while _awake(sc) > 0 and ticks < 600:
        sc.step_soft(DT, G, broadphase=True)
        ticks += 1
    var ys = _ticks(sc, 10)
    _row("layer " + String(n) + ": asleep", n, ys, "asleep after " + String(ticks) + " ticks, per body " + String(_pct(ys.copy(), 0.5) * 1e6 / Float64(n)) + " ns")
    keep(now() - t0)


def ecs_sparse(n: Int, frames: Int):
    var w = World[SparseSetBackend[Pos2, Vel2]]()
    var t0 = now()
    for i in range(n):
        _ = w.spawn2(Pos2(Vec2(Real(i), 0)), Vel2(Vec2(1, 1)))
    var spawn = now() - t0
    var xs = List[Int]()
    for _ in range(frames):
        var t = now()
        var movers = w.query2[Pos2, Vel2]()
        for i in range(len(movers)):
            var e = movers[i]
            w.set(e, Pos2(w.get[Pos2](e).p + w.get[Vel2](e).v))
        xs.append(now() - t)
    print("| ecs sparse-set |", n, "|", frames, "|", _pct(xs.copy(), 0.5), "|", _pct(xs.copy(), 0.99), "|", _pct(xs.copy(), 1.0),
          "| spawn", Float64(spawn) / Float64(n), "ns / entity, update", _pct(xs.copy(), 0.5) * 1e6 / Float64(n), "ns / entity |")


def ecs_archetype(n: Int, frames: Int):
    var w = World[ArchetypeBackend[Pos2, Vel2]]()
    var t0 = now()
    for i in range(n):
        _ = w.spawn2(Pos2(Vec2(Real(i), 0)), Vel2(Vec2(1, 1)))
    var spawn = now() - t0
    var xs = List[Int]()
    for _ in range(frames):
        var t = now()
        var views = w.backend.query2_views[Pos2, Vel2]()
        for vi in range(len(views)):
            var view = views[vi]
            for i in range(view.len()):
                view.set_a(i, Pos2(view.get_a(i).p + view.get_b(i).v))
        xs.append(now() - t)
    print("| ecs archetype (SoA views) |", n, "|", frames, "|", _pct(xs.copy(), 0.5), "|", _pct(xs.copy(), 0.99), "|", _pct(xs.copy(), 1.0),
          "| spawn", Float64(spawn) / Float64(n), "ns / entity, update", _pct(xs.copy(), 0.5) * 1e6 / Float64(n), "ns / entity |")


def main() raises:
    var quick = len(argv()) > 1 and argv()[1] == "quick"
    print("### Physics stress (ms per tick; 4 substeps x 4 iterations, broadphase on)\n")
    print("| scene | dynamic bodies | ticks | p50 | p99 | max | notes |")
    print("|---|---:|---:|---:|---:|---:|---|")
    tower(30)
    pyramid(20)
    pit(1000 if quick else 10000, 60 if quick else 120, 20)
    wake_storm(500 if quick else 5000)
    print("\n### Scale (ms per tick / frame)\n")
    print("| case | entities | ticks | p50 | p99 | max | notes |")
    print("|---|---:|---:|---:|---:|---:|---|")
    var ecs_sizes: List[Int] = [10000, 100000] if quick else [10000, 100000, 1000000]
    for n in ecs_sizes:
        ecs_sparse(n, 20)
        ecs_archetype(n, 20)
    var phys_sizes: List[Int] = [10000] if quick else [10000, 30000, 100000]
    for n in phys_sizes:
        layer(n, 10)
