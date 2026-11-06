# tier: component
"""Undo and redo of entity deletion (ROADMAP 17.43, #83), identical on all six backends.

A root with a child whose `Link` component holds the root's handle, plus a bystander:
  1. Delete child then root; undo twice brings root then child back under the same ids and generations with the same
     components, and the child's Link still names a live root. Redo twice removes them again. A new delete ends the
     redo chain.
  2. If a spawn took the freed id after the delete, undo returns False, the newcomer is untouched and the step stays.
  3. Delete of a dead entity raises; undo and redo on empty stacks return False.
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
from ecs.entity_undo import EntityUndo


@fieldwise_init
struct Pos(ComponentType):
    comptime ID: Int = 0
    var x: Int
    var y: Int


@fieldwise_init
struct Link(ComponentType):
    comptime ID: Int = 1
    var parent: Entity


@fieldwise_init
struct Tag(ComponentType):
    comptime ID: Int = 2
    var n: Int


def b2i(v: Bool) -> Int:
    return 1 if v else 0


def scenario[B: StorageBackend]() raises -> List[Int]:
    var o = List[Int]()
    var w = World[B]()
    var eu = EntityUndo[B, Pos, Link, Tag]()
    var root = w.spawn2(Pos(1, 1), Tag(7))
    var child = w.spawn2(Pos(2, 2), Link(root))
    var other = w.spawn1(Pos(3, 3))
    eu.delete(w, child)
    eu.delete(w, root)
    o.append(b2i(not w.is_alive(root) and not w.is_alive(child) and w.is_alive(other)))  # 0
    o.append(w.entity_count())  # 1: 1
    o.append(b2i(eu.undo(w)))  # 2: root back
    o.append(b2i(w.is_alive(root) and w.get[Pos](root).x == 1 and w.get[Tag](root).n == 7))  # 3
    o.append(b2i(not w.has[Link](root)))  # 4: a component it never had stays absent
    o.append(b2i(eu.undo(w)))  # 5: child back
    o.append(b2i(w.is_alive(child) and w.get[Pos](child).y == 2))  # 6
    var lk = w.get[Link](child).parent
    o.append(b2i(lk == root and w.is_alive(lk)))  # 7: the link names the live root
    o.append(w.entity_count())  # 8: 3
    o.append(b2i(not eu.undo(w)))  # 9: nothing left
    o.append(b2i(eu.redo(w) and eu.redo(w)))  # 10
    o.append(b2i(not w.is_alive(root) and not w.is_alive(child)))  # 11
    o.append(b2i(not eu.redo(w)))  # 12
    _ = eu.undo(w)
    o.append(b2i(w.is_alive(root) and not w.is_alive(child)))  # 13: undo after redo brings the root back first
    # a new delete ends the redo chain
    eu.delete(w, other)
    o.append(b2i(not eu.redo(w)))  # 14
    # id reuse
    var fresh = w.spawn1(Pos(50, 50))
    o.append(b2i(fresh.id == other.id))  # 15: the freed id was taken (all backends recycle)
    o.append(b2i(not eu.undo(w)))  # 16: refused
    o.append(b2i(w.is_alive(fresh) and w.get[Pos](fresh).x == 50))  # 17
    o.append(len(eu.past))  # 18: the refused step stays
    var raised = 0
    try:
        eu.delete(w, other)
    except:
        raised = 1
    o.append(raised)  # 19
    return o^


def compare(mut s: Suite, name: String, got: List[Int], want: List[Int]):
    var same = len(got) == len(want)
    var bad = -1
    if same:
        for i in range(len(want)):
            if got[i] != want[i] and bad < 0:
                bad = i
                same = False
    s.check(same, name + " matches the reference; first mismatch at " + String(bad))


def main() raises:
    var s = Suite("entity_undo")
    var reference = scenario[SparseSetBackend[Pos, Link, Tag]]()
    var want = List[Int]()
    for v in [1, 1, 1, 1, 1, 1, 1, 1, 3, 1, 1, 1, 1, 1, 1, 1, 1, 1, 2, 1]:
        want.append(v)
    compare(s, "sparse set (reference vs the expected values)", reference, want)
    compare(s, "archetype", scenario[ArchetypeBackend[Pos, Link, Tag]](), reference)
    compare(s, "bitset", scenario[BitsetBackend[Pos, Link, Tag]](), reference)
    compare(s, "reactive", scenario[ReactiveBackend[Pos, Link, Tag]](), reference)
    compare(s, "naive", scenario[NaiveBackend[Pos, Link, Tag]](), reference)
    compare(s, "chunked", scenario[ChunkedBackend[Pos, Link, Tag]](), reference)
    s.finish()
