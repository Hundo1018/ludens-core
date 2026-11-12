# tier: component
"""Undo and redo of component edits and of transactions (ROADMAP 17.43, #83), identical on all six backends.

  1. change: set a component, undo puts the earlier value back, redo the later one; a component the entity did not
     have is absent again after undo.
  2. remove: the component is gone, undo brings back its value, redo removes it again.
  3. merge: three merged changes of one component are one step, and undo returns to the value before the first.
     A change to another component, or to another entity, does not merge.
  4. A transaction is one step: deleting a child and its parent and changing a bystander undo together and redo
     together; nested begins close only at the outermost commit; an empty transaction leaves no step.
  5. A new edit ends the redo chain and releases what the dropped steps held in the graveyard.
  6. Refusals leave the world as it was: undo with a transaction open, undo of a transaction whose deleted entity's
     id was reused (the change in the same transaction is not undone either), change / remove on a dead entity,
     commit with nothing open.
  7. The depth cap counts transactions and releases the graveyard of the dropped ones.
  8. Change tracking sees undo and redo as writes.
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
    var a = w.spawn1(Pos(1, 1))
    var b = w.spawn2(Pos(2, 2), Tag(5))

    # 1. change
    eu.change(w, a, Pos(10, 11))
    o.append(w.get[Pos](a).x)  # 0: 10
    eu.change(w, a, Tag(9))  # a had no Tag
    o.append(b2i(w.has[Tag](a) and w.get[Tag](a).n == 9))  # 1
    o.append(eu.steps())  # 2: 2
    o.append(b2i(eu.undo(w) and not w.has[Tag](a)))  # 3: absent again
    o.append(b2i(eu.undo(w)))  # 4
    o.append(w.get[Pos](a).x * 100 + w.get[Pos](a).y)  # 5: 101
    o.append(b2i(not eu.undo(w)))  # 6: nothing left
    o.append(b2i(eu.redo(w) and eu.redo(w)))  # 7
    o.append(w.get[Pos](a).x * 100 + w.get[Tag](a).n)  # 8: 1009
    o.append(b2i(not eu.redo(w)))  # 9

    # 2. remove
    eu.remove[Tag](w, b)
    o.append(b2i(not w.has[Tag](b)))  # 10
    eu.remove[Tag](w, b)  # not there: records nothing
    o.append(eu.steps())  # 11: 3
    o.append(b2i(eu.undo(w) and w.get[Tag](b).n == 5))  # 12
    o.append(b2i(eu.redo(w) and not w.has[Tag](b)))  # 13
    _ = eu.undo(w)

    # 3. merge
    var before = eu.steps()
    eu.change(w, b, Pos(20, 20), True)  # the top step is the Tag removal of b: another component, a new step
    eu.change(w, b, Pos(21, 20), True)
    eu.change(w, b, Pos(22, 20), True)
    o.append(eu.steps() - before)  # 14: 1
    eu.change(w, a, Pos(30, 30), True)  # another entity: a new step
    o.append(eu.steps() - before)  # 15: 2
    _ = eu.undo(w)
    o.append(b2i(eu.undo(w)))  # 16
    o.append(w.get[Pos](b).x)  # 17: 2, the value before the first merged change
    o.append(b2i(eu.redo(w)))  # 18
    o.append(w.get[Pos](b).x)  # 19: 22, the last merged value
    return o^


def transactions[B: StorageBackend]() raises -> List[Int]:
    var o = List[Int]()
    var w = World[B]()
    var eu = EntityUndo[B, Pos, Link, Tag]()
    var root = w.spawn2(Pos(1, 1), Tag(7))
    var child = w.spawn2(Pos(2, 2), Link(root))
    var other = w.spawn1(Pos(3, 3))

    # 4. one transaction, three edits
    eu.begin()
    eu.begin()  # nested
    eu.delete(w, child)
    eu.commit()
    o.append(eu.depth)  # 0: 1, still open
    eu.delete(w, root)
    eu.change(w, other, Pos(33, 33))
    o.append(b2i(not eu.undo(w)))  # 1: refused while open
    eu.commit()
    o.append(eu.steps())  # 2: 1
    o.append(w.entity_count())  # 3: 1
    o.append(b2i(eu.undo(w)))  # 4
    o.append(b2i(w.is_alive(root) and w.is_alive(child) and w.get[Pos](other).x == 3))  # 5: all three back
    var lk = w.get[Link](child).parent
    o.append(b2i(lk == root and w.get[Tag](root).n == 7))  # 6
    o.append(b2i(eu.redo(w)))  # 7
    o.append(b2i(not w.is_alive(root) and not w.is_alive(child) and w.get[Pos](other).x == 33))  # 8
    _ = eu.undo(w)
    eu.begin()
    eu.commit()  # empty
    o.append(eu.steps())  # 9: 0 (the undone transaction is in the redo chain, the empty one left nothing)
    o.append(b2i(eu.redo(w)))  # 10: an empty transaction does not end the redo chain
    _ = eu.undo(w)

    # 5. a new edit ends the redo chain and releases its graveyard
    eu.change(w, other, Pos(4, 4))
    o.append(b2i(not eu.redo(w)))  # 11
    o.append(eu.grave.entity_count())  # 12: 2 (before and after of the one change)

    # 6. refusals
    eu.begin()
    eu.change(w, other, Pos(5, 5))
    eu.delete(w, child)
    eu.commit()
    var fresh = w.spawn1(Pos(50, 50))  # takes child's id
    o.append(b2i(fresh.id == child.id))  # 13
    o.append(b2i(not eu.undo(w)))  # 14: the delete cannot be undone
    o.append(b2i(w.get[Pos](other).x == 5 and w.is_alive(fresh) and w.get[Pos](fresh).x == 50))  # 15: nothing moved
    o.append(eu.steps())  # 16: 2, the refused step stays
    var raised = 0
    try:
        eu.change(w, child, Pos(0, 0))
    except:
        raised += 1
    try:
        eu.remove[Pos](w, child)
    except:
        raised += 1
    try:
        eu.commit()
    except:
        raised += 1
    o.append(raised)  # 17: 3
    return o^


def cap_and_tracking[B: StorageBackend]() raises -> List[Int]:
    var o = List[Int]()
    var w = World[B]()
    var eu = EntityUndo[B, Pos, Link, Tag](2)
    var e = w.spawn1(Pos(0, 0))
    # 7. three transactions of two changes each, cap 2
    for k in range(3):
        eu.begin()
        eu.change(w, e, Pos(k + 1, 0))
        eu.change(w, e, Tag(k + 1))
        eu.commit()
    o.append(eu.steps())  # 0: 2
    o.append(len(eu.past))  # 1: 4 records
    o.append(eu.grave.entity_count())  # 2: 8 (before and after of 4 records; the first transaction's 4 were released)
    o.append(b2i(eu.undo(w) and eu.undo(w) and not eu.undo(w)))  # 3
    o.append(w.get[Pos](e).x * 10 + w.get[Tag](e).n)  # 4: 11, the state after the dropped first transaction

    # 8. change tracking
    w.track_changes()
    var t0 = w.advance_tick()
    _ = eu.redo(w)
    o.append(len(w.changed[Pos](t0)))  # 5: 1, redo is a write
    var t1 = w.advance_tick()
    o.append(len(w.changed[Pos](t1)))  # 6: 0, nothing since
    _ = eu.undo(w)
    o.append(len(w.changed[Pos](t1)))  # 7: 1, undo is a write
    return o^


def compare(mut s: Suite, name: String, got: List[Int], want: List[Int]):
    var same = len(got) == len(want)
    var bad = -1
    if same:
        for i in range(len(want)):
            if got[i] != want[i] and bad < 0:
                bad = i
                same = False
    var shown = String(got[bad]) + " instead of " + String(want[bad]) if bad >= 0 else String("-")
    s.check(same, name + " matches the reference; first mismatch at " + String(bad) + " (" + shown + ")")


def main() raises:
    var s = Suite("entity_change_undo")
    var ref1 = scenario[SparseSetBackend[Pos, Link, Tag]]()
    var want1 = List[Int]()
    for v in [10, 1, 2, 1, 1, 101, 1, 1, 1009, 1, 1, 3, 1, 1, 1, 2, 1, 2, 1, 22]:
        want1.append(v)
    compare(s, "change, remove, merge: sparse set (reference vs the expected values)", ref1, want1)
    var ref2 = transactions[SparseSetBackend[Pos, Link, Tag]]()
    var want2 = List[Int]()
    for v in [1, 1, 1, 1, 1, 1, 1, 1, 1, 0, 1, 1, 2, 1, 1, 1, 2, 3]:
        want2.append(v)
    compare(s, "transactions and refusals: sparse set (reference vs the expected values)", ref2, want2)
    var ref3 = cap_and_tracking[SparseSetBackend[Pos, Link, Tag]]()
    var want3 = List[Int]()
    for v in [2, 4, 8, 1, 11, 1, 0, 1]:
        want3.append(v)
    compare(s, "depth cap and change tracking: sparse set (reference vs the expected values)", ref3, want3)
    compare(s, "change, remove, merge: archetype", scenario[ArchetypeBackend[Pos, Link, Tag]](), ref1)
    compare(s, "change, remove, merge: bitset", scenario[BitsetBackend[Pos, Link, Tag]](), ref1)
    compare(s, "change, remove, merge: reactive", scenario[ReactiveBackend[Pos, Link, Tag]](), ref1)
    compare(s, "change, remove, merge: naive", scenario[NaiveBackend[Pos, Link, Tag]](), ref1)
    compare(s, "change, remove, merge: chunked", scenario[ChunkedBackend[Pos, Link, Tag]](), ref1)
    compare(s, "transactions and refusals: archetype", transactions[ArchetypeBackend[Pos, Link, Tag]](), ref2)
    compare(s, "transactions and refusals: bitset", transactions[BitsetBackend[Pos, Link, Tag]](), ref2)
    compare(s, "transactions and refusals: reactive", transactions[ReactiveBackend[Pos, Link, Tag]](), ref2)
    compare(s, "transactions and refusals: naive", transactions[NaiveBackend[Pos, Link, Tag]](), ref2)
    compare(s, "transactions and refusals: chunked", transactions[ChunkedBackend[Pos, Link, Tag]](), ref2)
    compare(s, "depth cap and change tracking: archetype", cap_and_tracking[ArchetypeBackend[Pos, Link, Tag]](), ref3)
    compare(s, "depth cap and change tracking: chunked", cap_and_tracking[ChunkedBackend[Pos, Link, Tag]](), ref3)
    s.finish()
