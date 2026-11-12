"""Undo and redo cost (ROADMAP 17.43).

Table 1, bodies of an `EmbedWorld`: one edit step (move k bodies) recorded by `UndoLog` (the records of the bodies
touched) against `SnapshotUndo` (a whole-world snapshot before and after). Scene size x edit size: one body, 10 % of
the bodies, all of them. Commit time, undo time and the bytes the step keeps. Both must return the world to the hash it
had before the edit, or the bench raises.

Table 2, ECS entities (`EntityUndo`), on each of the six storage backends: delete one entity and undo; change one
component and undo; change one component of 100 entities in one transaction and undo. There is one implementation, so
no ratio: the table shows whether the cost depends on the world size and how the backends differ.

Every number is the median of REPS runs of the same step on the same world (the undo puts it back, so a step repeats).
Wall-clock: run on an idle machine."""
from std.sys import size_of
from std.time import perf_counter_ns
from ecs.archetype import ArchetypeBackend
from ecs.bitset_backend import BitsetBackend
from ecs.chunked_backend import ChunkedBackend
from ecs.component import ComponentType
from ecs.entity import Entity
from ecs.entity_undo import EntityUndo
from ecs.naive_backend import NaiveBackend
from ecs.reactive_backend import ReactiveBackend
from ecs.sparse_backend import SparseSetBackend
from ecs.storage import StorageBackend
from ecs.world import World
from embed.scene_io import SceneBody
from embed.undo import SnapshotUndo, UndoLog
from embed.world import EmbedWorld
from geometry.quat import Quat
from geometry.vec import Real, Vec3

comptime REPS = 7
comptime TXN = 100


def median(mut xs: List[Int]) -> Float64:
    """Median of nanosecond samples, in microseconds."""
    for i in range(1, len(xs)):
        var v = xs[i]
        var j = i
        while j > 0 and xs[j - 1] > v:
            xs[j] = xs[j - 1]
            j -= 1
        xs[j] = v
    return Float64(xs[len(xs) // 2]) / 1e3


def make(n: Int, mut hs: List[Int64]) raises -> EmbedWorld:
    var w = EmbedWorld(1.0 / 60.0, Vec3(0.0, -9.81, 0.0, 0.0))
    for i in range(n):
        hs.append(w.add_box(Vec3(Real(i % 100) * 1.2, Real(i // 10000) * 1.2, Real((i // 100) % 100) * 1.2, 0.0), Vec3(0.5, 0.5, 0.5, 0.0), 1.0, False))
    return w^


def body_row(n: Int, k: Int, label: String) raises:
    var stride = n // k
    # UndoLog
    var hs = List[Int64]()
    var w = make(n, hs)
    var h0 = w.hash()
    # the edit: k bodies, evenly spread, moved with one `teleport_many` (the same handles are valid in both worlds)
    var moved = List[Int64]()
    var to_pos = List[Vec3]()
    var to_rot = List[Quat]()
    for j in range(k):
        moved.append(hs[j * stride])
        to_pos.append(Vec3(5.0, 50.0 + Real(j), 5.0, 0.0))
        to_rot.append(Quat(0.0, 0.0, 0.0, 1.0))
    var log = UndoLog()
    var lc = List[Int]()
    var lu = List[Int]()
    for _ in range(REPS):
        var t0 = perf_counter_ns()
        log.begin("move")
        for j in range(k):
            log.touch(w, moved[j])
        w.teleport_many(moved, to_pos, to_rot)
        log.commit(w)
        var t1 = perf_counter_ns()
        if not log.undo(w):
            raise Error("bench_undo: UndoLog.undo refused")
        var t2 = perf_counter_ns()
        lc.append(Int(t1 - t0))
        lu.append(Int(t2 - t1))
    if w.hash() != h0:
        raise Error("bench_undo: UndoLog did not restore the world")
    # SnapshotUndo
    var hs2 = List[Int64]()
    var ws = make(n, hs2)
    var snap = SnapshotUndo()
    var sc = List[Int]()
    var su = List[Int]()
    var snap_bytes = 0
    for _ in range(REPS):
        var t0 = perf_counter_ns()
        snap.begin(ws)
        ws.teleport_many(moved, to_pos, to_rot)
        snap.commit(ws)
        var t1 = perf_counter_ns()
        snap_bytes = snap.bytes()
        if not snap.undo(ws):
            raise Error("bench_undo: SnapshotUndo.undo refused")
        var t2 = perf_counter_ns()
        sc.append(Int(t1 - t0))
        su.append(Int(t2 - t1))
    if ws.hash() != h0:
        raise Error("bench_undo: SnapshotUndo did not restore the world")
    var a = median(lc)
    var b = median(lu)
    var c = median(sc)
    var d = median(su)
    var log_bytes = k * 2 * size_of[SceneBody]()
    print("|", n, "|", label, "|", a, "|", b, "|", log_bytes, "|", c, "|", d, "|", snap_bytes / REPS, "|", (c + d) / (a + b), "|")


@fieldwise_init
struct Pos(ComponentType):
    comptime ID: Int = 0
    var x: Int
    var y: Int


@fieldwise_init
struct Vel(ComponentType):
    comptime ID: Int = 1
    var x: Int
    var y: Int


@fieldwise_init
struct Tag(ComponentType):
    comptime ID: Int = 2
    var n: Int


def entity_row[B: StorageBackend](name: String, n: Int) raises:
    var w = World[B]()
    var es = List[Entity]()
    for i in range(n):
        es.append(w.spawn2(Pos(i, i), Vel(1, 2)))
    var eu = EntityUndo[B, Pos, Vel, Tag]()
    var mid = es[n // 2]
    var del_do = List[Int]()
    var del_undo = List[Int]()
    var ch_do = List[Int]()
    var ch_undo = List[Int]()
    var tx_do = List[Int]()
    var tx_undo = List[Int]()
    var stride = n // TXN
    for r in range(REPS):
        var t0 = perf_counter_ns()
        eu.delete(w, mid)
        var t1 = perf_counter_ns()
        if not eu.undo(w):
            raise Error("bench_undo: undo of a delete refused")
        var t2 = perf_counter_ns()
        eu.change(w, mid, Pos(-1 - r, 7))
        var t3 = perf_counter_ns()
        if not eu.undo(w):
            raise Error("bench_undo: undo of a change refused")
        var t4 = perf_counter_ns()
        eu.begin()
        for j in range(TXN):
            eu.change(w, es[j * stride], Pos(-j, r))
        eu.commit()
        var t5 = perf_counter_ns()
        if not eu.undo(w):
            raise Error("bench_undo: undo of a transaction refused")
        var t6 = perf_counter_ns()
        del_do.append(Int(t1 - t0))
        del_undo.append(Int(t2 - t1))
        ch_do.append(Int(t3 - t2))
        ch_undo.append(Int(t4 - t3))
        tx_do.append(Int(t5 - t4))
        tx_undo.append(Int(t6 - t5))
    var ok = w.is_alive(mid) and w.get[Pos](mid).x == n // 2 and w.get[Vel](mid).y == 2 and w.entity_count() == n
    for j in range(TXN):
        ok = ok and w.get[Pos](es[j * stride]).x == j * stride
    if not ok:
        raise Error("bench_undo: EntityUndo did not restore the world on " + name)
    print("|", name, "|", n, "|", median(del_do), "|", median(del_undo), "|", median(ch_do), "|", median(ch_undo), "|", median(tx_do), "|", median(tx_undo), "|")


def entity_rows[B: StorageBackend](name: String) raises:
    for n in [1000, 10000, 100000]:
        entity_row[B](name, n)


def main() raises:
    print("### Undo: one edit step on an `EmbedWorld`, records against snapshots (microseconds, median of", REPS, ")\n")
    print("| bodies | bodies moved | UndoLog commit | UndoLog undo | UndoLog bytes | SnapshotUndo commit | SnapshotUndo undo | SnapshotUndo bytes | snapshot / records (commit + undo) |")
    print("|---:|:--|---:|---:|---:|---:|---:|---:|---:|")
    for n in [1000, 10000, 100000]:
        body_row(n, 1, "1")
        body_row(n, n // 10, "10 %")
        body_row(n, n, "all")

    print("\n### Undo: ECS entities, `EntityUndo` on each storage backend (microseconds, median of", REPS, ")\n")
    print("| backend | entities | delete 1 | undo | change 1 component | undo | 100 changes in one transaction | undo |")
    print("|:--|---:|---:|---:|---:|---:|---:|---:|")
    entity_rows[SparseSetBackend[Pos, Vel, Tag]]("sparse set")
    entity_rows[ArchetypeBackend[Pos, Vel, Tag]]("archetype")
    entity_rows[ChunkedBackend[Pos, Vel, Tag]]("chunked")
    entity_rows[BitsetBackend[Pos, Vel, Tag]]("bitset")
    entity_rows[ReactiveBackend[Pos, Vel, Tag]]("reactive")
    entity_rows[NaiveBackend[Pos, Vel, Tag]]("naive")
