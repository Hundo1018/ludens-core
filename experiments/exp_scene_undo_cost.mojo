"""Experiment: what scene read/write and undo cost (ROADMAP 17.12 and 17.43).

Two tables, on a world of N boxes (never stepped):

  1. The scene API against the deterministic snapshot: `export_scene`, the rows (`scene_to_fields`,
     `scene_from_fields`), `import_scene`, a diff of a scene with itself, and `EmbedWorld.save` / `load`.
  2. One edit (move a single body) as an undo step: `UndoLog` (the body's records) against `SnapshotUndo`
     (a snapshot before and after): the time to commit, the time to undo, and the bytes the step keeps.

The tests (`test_scene_io`, `test_undo`) check behavior and print no times, because their output is compared with the
golden; the numbers live here. Run on an idle machine: the times are wall-clock.

Run: pixi run mojo run -I build experiments/exp_scene_undo_cost.mojo"""
from std.sys import size_of
from std.time import perf_counter_ns
from embed.scene_io import SceneBody, export_scene, import_scene, scene_diff, scene_from_fields, scene_to_fields
from embed.undo import SnapshotUndo, UndoLog
from embed.world import EmbedWorld
from geometry.vec import Real, Vec3


def make(n: Int, mut hs: List[Int64]) raises -> EmbedWorld:
    var w = EmbedWorld(1.0 / 60.0, Vec3(0.0, -9.81, 0.0, 0.0))
    for i in range(n):
        hs.append(w.add_box(Vec3(Real(i % 100) * 1.2, Real(i // 10000) * 1.2, Real((i // 100) % 100) * 1.2, 0.0), Vec3(0.5, 0.5, 0.5, 0.0), 1.0, False))
    return w^


def us(t0: Int, t1: Int) -> Float64:
    return Float64(t1 - t0) / 1e3


def main() raises:
    print("Scene API against the snapshot (milliseconds)\n")
    print("| bodies | export | to rows | from rows | import | diff (no change) | save | load | rows |")
    print("|---:|---:|---:|---:|---:|---:|---:|---:|---:|")
    for n in [1000, 10000]:
        var hs = List[Int64]()
        var w = make(n, hs)
        var t0 = perf_counter_ns()
        var doc = export_scene(w)
        var t1 = perf_counter_ns()
        var rows = scene_to_fields(doc)
        var t2 = perf_counter_ns()
        var back = scene_from_fields(rows)
        var t3 = perf_counter_ns()
        var w2 = EmbedWorld(1.0 / 60.0, Vec3(0.0, 0.0, 0.0, 0.0))
        import_scene(w2, back)
        var t4 = perf_counter_ns()
        var d = scene_diff(rows, rows)
        var t5 = perf_counter_ns()
        var blob = w.save()
        var t6 = perf_counter_ns()
        var w3 = EmbedWorld(1.0 / 60.0, Vec3(0.0, -9.81, 0.0, 0.0))
        w3.load(blob)
        var t7 = perf_counter_ns()
        print("|", n, "|", us(t0, t1) / 1e3, "|", us(t1, t2) / 1e3, "|", us(t2, t3) / 1e3, "|", us(t3, t4) / 1e3, "|", us(t4, t5) / 1e3, "|", us(t5, t6) / 1e3, "|", us(t6, t7) / 1e3, "|", len(rows), "|")
        _ = len(d)

    print("\nOne body moved, as an undo step\n")
    print("| bodies | UndoLog commit (us) | UndoLog undo (us) | UndoLog bytes | SnapshotUndo commit (us) | SnapshotUndo undo (us) | SnapshotUndo bytes |")
    print("|---:|---:|---:|---:|---:|---:|---:|")
    for n in [1000, 10000, 100000]:
        var hs = List[Int64]()
        var w = make(n, hs)
        var log = UndoLog()
        var target = hs[n // 2]
        var t0 = perf_counter_ns()
        log.begin("move")
        log.touch(w, target)
        w.teleport(target, Vec3(5.0, 50.0, 5.0, 0.0), w.state(target).rot)
        log.commit(w)
        var t1 = perf_counter_ns()
        _ = log.undo(w)
        var t2 = perf_counter_ns()

        var hs2 = List[Int64]()
        var ws = make(n, hs2)
        var snap = SnapshotUndo()
        var t3 = perf_counter_ns()
        snap.begin(ws)
        ws.teleport(hs2[n // 2], Vec3(5.0, 50.0, 5.0, 0.0), ws.state(hs2[n // 2]).rot)
        snap.commit(ws)
        var t4 = perf_counter_ns()
        var snap_bytes = snap.bytes()
        _ = snap.undo(ws)
        var t5 = perf_counter_ns()
        print("|", n, "|", us(t0, t1), "|", us(t1, t2), "|", 2 * size_of[SceneBody](), "|", us(t3, t4), "|", us(t4, t5), "|", snap_bytes, "|")
