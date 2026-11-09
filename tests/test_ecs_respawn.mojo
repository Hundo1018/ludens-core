# tier: component
"""Respawn of a despawned entity under the same id and generation (ROADMAP 17.43, #83: undo of an entity delete),
identical on all six storage backends.

  1. despawn then respawn brings the exact handle back (same id, same generation), the entity count returns, the
     components are gone (a respawn restores identity, not data), new components can be set and queries see the entity
     once.
  2. Refusals, each leaving the world unchanged: a live entity, an id that a later spawn reused (the newcomer stays
     alive and keeps its data), a made-up id, a wrong generation, a negative id.
  3. Despawn -> respawn -> despawn -> respawn cycles twice: the generation each time is what the handle says.
"""

from harness.runner import Suite
from ecs.world import World
from ecs.storage import StorageBackend
from ecs.sparse_backend import SparseSetBackend
from ecs.archetype import ArchetypeBackend
from ecs.bitset_backend import BitsetBackend
from ecs.reactive_backend import ReactiveBackend
from ecs.naive_backend import NaiveBackend
from ecs.chunked_backend import ChunkedBackend
from ecs.component import ComponentType
from ecs.entity import Entity


@fieldwise_init
struct Position(ComponentType):
    comptime ID: Int = 0
    var x: Int
    var y: Int


@fieldwise_init
struct Velocity(ComponentType):
    comptime ID: Int = 1
    var dx: Int
    var dy: Int


@fieldwise_init
struct Frozen(ComponentType):
    comptime ID: Int = 2
    var flag: Int


def b2i(v: Bool) -> Int:
    return 1 if v else 0


def scenario[B: StorageBackend]() -> List[Int]:
    var o = List[Int]()
    var w = World[B]()
    var a = w.spawn2(Position(1, 1), Velocity(1, 1))
    var b = w.spawn2(Position(2, 2), Velocity(2, 2))
    var c = w.spawn2(Position(3, 3), Velocity(3, 3))
    w.despawn(b)
    o.append(b2i(not w.is_alive(b)))  # 0: dead after despawn
    o.append(w.entity_count())  # 1: 2
    o.append(b2i(w.respawn(b)))  # 2: respawn works
    o.append(b2i(w.is_alive(b)))  # 3: alive with the same handle
    o.append(w.entity_count())  # 4: 3
    o.append(b2i(not w.has[Position](b) and not w.has[Velocity](b)))  # 5: components are gone
    w.set(b, Position(20, 20))
    o.append(w.get[Position](b).x)  # 6: 20
    o.append(len(w.query1[Position]()))  # 7: 3 entities have a Position
    var seen_b = 0
    for e in w.query1[Position]():
        if e == b:
            seen_b += 1
    o.append(seen_b)  # 8: b once
    o.append(w.get[Position](a).x * 100 + w.get[Position](c).x)  # 9: 103 (others untouched)

    # refusals
    o.append(b2i(not w.respawn(b)))  # 10: b is alive
    w.despawn(a)
    var d = w.spawn()  # takes the freed id of a
    w.set(d, Position(40, 40))
    o.append(b2i(not w.respawn(a)))  # 11: the id was reused
    o.append(b2i(w.is_alive(d) and w.get[Position](d).x == 40 and not w.is_alive(a)))  # 12: newcomer intact
    o.append(b2i(not w.respawn(Entity(99, 0))))  # 13: made up
    o.append(b2i(not w.respawn(Entity(-1, 0))))  # 14: negative
    w.despawn(c)
    o.append(b2i(not w.respawn(Entity(c.id, c.gen + 5))))  # 15: wrong generation
    o.append(b2i(not w.is_alive(c)))  # 16: still dead
    o.append(w.entity_count())  # 17: b, d = 2

    # cycles
    var cur = c
    var ok = 1
    for _ in range(2):
        if not w.respawn(cur):
            ok = 0
        if not (w.is_alive(cur) and cur.gen == c.gen):
            ok = 0
        w.despawn(cur)
        if w.is_alive(cur):
            ok = 0
    o.append(ok)  # 18
    o.append(b2i(w.respawn(c) and w.is_alive(c) and w.entity_count() == 3))  # 19
    return o^


def compare(mut s: Suite, name: String, got: List[Int], want: List[Int]):
    var same = len(got) == len(want)
    if same:
        for i in range(len(want)):
            if got[i] != want[i]:
                same = False
    s.check(same, name + " matches the reference (" + String(len(got)) + " observations)")


def main() raises:
    var s = Suite("ecs_respawn")
    var sparse = scenario[SparseSetBackend[Position, Velocity, Frozen]]()
    var want = List[Int]()
    for v in [1, 2, 1, 1, 3, 1, 20, 3, 1, 103, 1, 1, 1, 1, 1, 1, 1, 2, 1, 1]:
        want.append(v)
    var exact = len(sparse) == len(want)
    var first_bad = -1
    if exact:
        for i in range(len(want)):
            if sparse[i] != want[i] and first_bad < 0:
                first_bad = i
                exact = False
    s.check(exact, "the reference (sparse set) gives the expected observations; first mismatch at " + String(first_bad))
    compare(s, "archetype", scenario[ArchetypeBackend[Position, Velocity, Frozen]](), sparse)
    compare(s, "bitset", scenario[BitsetBackend[Position, Velocity, Frozen]](), sparse)
    compare(s, "reactive", scenario[ReactiveBackend[Position, Velocity, Frozen]](), sparse)
    compare(s, "naive", scenario[NaiveBackend[Position, Velocity, Frozen]](), sparse)
    compare(s, "chunked", scenario[ChunkedBackend[Position, Velocity, Frozen]](), sparse)
    s.finish()
