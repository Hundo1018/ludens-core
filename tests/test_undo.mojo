# tier: integration
"""Undo / redo for body edits (ROADMAP 17.43, ludens-core #83).

- contract: after every undo and every redo of a 10-step edit script the world's scene rows equal the rows recorded
  at that step, and the live handles are the same ones (a removed body comes back with its old BodyId);
- seam: `UndoLog` (per-body records) and `SnapshotUndo` (one snapshot per step) agree at every step;
- a script without an add or remove restores the world to the exact snapshot hash, and after 300 ticks it behaves
  like a world that was never edited (the solver flags the edits raised are lowered again where they gate events);
- transactions: nesting, merging of a drag, abort, redo truncation, the step limit, empty transactions, errors;
- the size of one step (one body's records against a snapshot of the world); the times are measured by a separate
  program, not printed here, because the golden compares this test's whole output.
"""
from std.sys import size_of
from harness.runner import Suite
from embed.scene_io import SceneBody, SceneField, body_record, export_scene, scene_diff, scene_to_fields, write_body_record
from embed.undo import SnapshotUndo, UndoLog
from embed.world import EmbedWorld, unpack_body
from geometry.quat import Quat
from geometry.vec import Real, Vec3
from physics.ccd6 import CCD_BULLET

comptime DT = 1.0 / 60.0


def fresh() raises -> EmbedWorld:
    return EmbedWorld(DT, Vec3(0.0, -9.81, 0.0, 0.0))


def build(mut hs: List[Int64]) raises -> EmbedWorld:
    var w = fresh()
    hs.append(w.add_box(Vec3(0.0, -1.0, 0.0, 0.0), Vec3(20.0, 1.0, 20.0, 0.0), 0.0, True))
    for i in range(3):
        hs.append(w.add_box(Vec3(Real(i) * 1.5 - 1.5, 1.0 + Real(i) * 1.1, 0.0, 0.0), Vec3(0.5, 0.5, 0.5, 0.0), 1.0 + Real(i), False))
    hs.append(w.add_sphere(Vec3(0.2, 6.0, 0.1, 0.0), 0.4, 2.0, False))
    return w^


def rows(w: EmbedWorld) raises -> List[SceneField]:
    return scene_to_fields(export_scene(w))


def same(a: List[SceneField], b: List[SceneField]) -> Bool:
    return len(a) == len(b) and len(scene_diff(a, b)) == 0


def same_handles(a: List[Int64], b: List[Int64]) -> Bool:
    if len(a) != len(b):
        return False
    for i in range(len(a)):
        if a[i] != b[i]:
            return False
    return True


def run_ticks(mut w: EmbedWorld, n: Int) raises:
    for _ in range(n):
        for _ in range(w.ticks_due(DT)):
            w.physics_tick()


# The edit script: what each step changes. `use_add` = False skips the add (step 5) and the remove (step 6).
def touched(k: Int, hs: List[Int64]) -> List[Int64]:
    var t = List[Int64]()
    if k == 0 or k == 3 or k == 6:
        t.append(hs[1])
    elif k == 1 or k == 4 or k == 8:
        t.append(hs[2])
    elif k == 2 or k == 7 or k == 9:
        t.append(hs[3])
    return t^


def do_edit(k: Int, mut w: EmbedWorld, mut hs: List[Int64]) raises:
    if k == 0:
        w.teleport(hs[1], Vec3(0.5, 3.0, 0.2, 0.0), w.state(hs[1]).rot)
    elif k == 1:
        w.set_velocity(hs[2], Vec3(1.0, 0.0, 0.0, 0.0), Vec3(0.0, 2.0, 0.0, 0.0))
    elif k == 2:
        w.set_layer(hs[3], 2, 0xFFFFFFFD)
    elif k == 3:
        w.set_user(hs[1], 77)
    elif k == 4:
        w.scene.set_friction(unpack_body(hs[2]).index(), 0.4)
    elif k == 5:
        hs.append(w.add_sphere(Vec3(-0.5, 8.0, 0.3, 0.0), 0.3, 1.0, False))
    elif k == 6:
        w.remove(hs[1])
    elif k == 7:
        w.scene.set_damping(w.scene.bset.id_of(unpack_body(hs[3]).index()), 0.3, 0.2)
    elif k == 8:
        w.scene.set_contact_reporting(w.scene.bset.id_of(unpack_body(hs[2]).index()), True)
    else:
        w.scene.set_ccd_mode(w.scene.bset.id_of(unpack_body(hs[3]).index()), CCD_BULLET)


def log_edit(k: Int, mut w: EmbedWorld, mut log: UndoLog, mut hs: List[Int64]) raises:
    log.begin("step " + String(k))
    for h in touched(k, hs):
        log.touch(w, h)
    do_edit(k, w, hs)
    if k == 5:
        log.created(w, hs[len(hs) - 1])
    log.commit(w)


def snap_edit(k: Int, mut w: EmbedWorld, mut log: SnapshotUndo, mut hs: List[Int64]) raises:
    log.begin(w)
    do_edit(k, w, hs)
    log.commit(w)


def main() raises:
    var s = Suite("undo")

    # ---- 1. contract and seam over the 10-step script (with an add and a remove)
    var ha = List[Int64]()
    var hb = List[Int64]()
    var hr = List[Int64]()
    var wa = build(ha)
    var wb = build(hb)
    var wref = build(hr)
    var ulog = UndoLog()
    var slog = SnapshotUndo()
    var rows_at = List[List[SceneField]]()
    var handles_at = List[List[Int64]]()
    rows_at.append(rows(wa))
    handles_at.append(wa.bodies())
    for k in range(10):
        log_edit(k, wa, ulog, ha)
        snap_edit(k, wb, slog, hb)
        rows_at.append(rows(wa))
        handles_at.append(wa.bodies())
        if not same(rows(wa), rows(wb)):
            s.check(False, "forward: the two worlds disagree after step " + String(k))
    s.eqi(ulog.steps(), 10, "10 steps are on the log")
    var contract = 0
    var seam = 0
    var ident = 0
    for j in range(10, 0, -1):
        s.check(ulog.undo(wa) and slog.undo(wb), "undo step " + String(j))
        if not same(rows(wa), rows_at[j - 1]):
            contract += 1
        if not same(rows(wb), rows_at[j - 1]) or not same(rows(wa), rows(wb)):
            seam += 1
        if not same_handles(wa.bodies(), handles_at[j - 1]) or not same_handles(wb.bodies(), handles_at[j - 1]):
            ident += 1
    s.eqi(contract, 0, "UndoLog: every undo reaches the recorded rows")
    s.eqi(seam, 0, "seam: SnapshotUndo reaches the same rows at every undo")
    s.eqi(ident, 0, "...with the same live handles (the removed body comes back with its old BodyId)")
    s.check(not ulog.undo(wa) and not slog.undo(wb), "nothing left to undo")
    var redo_bad = 0
    for j in range(1, 11):
        s.check(ulog.redo(wa) and slog.redo(wb), "redo step " + String(j))
        if not same(rows(wa), rows_at[j]) or not same(rows(wb), rows_at[j]):
            redo_bad += 1
        if not same_handles(wa.bodies(), handles_at[j]):
            redo_bad += 1
    s.eqi(redo_bad, 0, "every redo reaches the recorded rows and handles, in both implementations")

    # ---- 2. without add / remove the world returns to the exact snapshot, and behaves like an unedited one
    var hp = List[Int64]()
    var hq = List[Int64]()
    var wp = build(hp)
    var wq = build(hq)
    var hash0 = wp.hash()
    var plog = UndoLog()
    for k in [0, 1, 2, 3, 4, 7, 8, 9]:
        log_edit(k, wp, plog, hp)
    s.check(wp.hash() != hash0, "the edits changed the world")
    while plog.undo(wp):
        pass
    s.check(wp.hash() == hash0, "all edits undone: the snapshot hash is the original one")
    run_ticks(wp, 300)
    run_ticks(wq, 300)
    s.check(same(rows(wp), rows(wq)), "after 300 ticks it behaves like a world that was never edited (damping, reporting, CCD undone)")
    s.check(wp.hash() == wq.hash(), "...down to the snapshot hash")

    # ---- 3. identity: a slot reused by another body is given back in order
    var hi = List[Int64]()
    var wi = build(hi)
    var ilog = UndoLog()
    var victim = hi[2]
    ilog.begin("remove")
    ilog.touch(wi, victim)
    wi.remove(victim)
    ilog.commit(wi)
    ilog.begin("add")
    var newcomer = wi.add_box(Vec3(3.0, 1.0, 0.0, 0.0), Vec3(0.4, 0.4, 0.4, 0.0), 1.0, False)
    ilog.created(wi, newcomer)
    ilog.commit(wi)
    s.check(unpack_body(newcomer).index() == unpack_body(victim).index() and newcomer != victim, "the new body took the freed slot with a newer generation")
    s.check(ilog.undo(wi) and not wi.is_alive(newcomer), "undo the add: the newcomer is gone")
    s.check(ilog.undo(wi) and wi.is_alive(victim), "undo the remove: the old handle is alive again")
    s.check(not wi.is_alive(newcomer), "...and the newcomer's handle stays dead")
    wi.remove(victim)  # the restored body goes away again
    var later = wi.add_box(Vec3(4.0, 1.0, 0.0, 0.0), Vec3(0.4, 0.4, 0.4, 0.0), 1.0, False)
    s.check(later != victim and later != newcomer, "after the rewind, a later body gets a generation nobody held")
    s.check(not wi.is_alive(newcomer) and not wi.is_alive(victim), "...so stale handles from before the rewind never alias it")

    # ---- 4. merge a drag, abort, nesting, truncation, limit, empty transactions
    var hm = List[Int64]()
    var wm = build(hm)
    var mlog = UndoLog()
    var start = rows(wm)
    for i in range(5):
        mlog.begin("drag", 7)
        mlog.touch(wm, hm[1])
        wm.teleport(hm[1], Vec3(Real(i) * 0.5, 2.0, 0.0, 0.0), wm.state(hm[1]).rot)
        mlog.commit(wm)
    s.eqi(mlog.steps(), 1, "five drag transactions with one merge key are one undo step")
    var end_rows = rows(wm)
    s.check(mlog.undo(wm) and same(rows(wm), start), "one undo returns to where the drag started")
    s.check(mlog.redo(wm) and same(rows(wm), end_rows), "one redo returns to where it ended")
    var back = UndoLog()
    var hn = List[Int64]()
    var wn = build(hn)
    var orig = body_record(wn, hn[1])
    back.begin("drag", 9)
    back.touch(wn, hn[1])
    wn.teleport(hn[1], Vec3(1.0, 4.0, 0.0, 0.0), orig.rot)
    back.commit(wn)
    s.eqi(back.steps(), 1, "a drag away from the start is a step")
    back.begin("drag", 9)
    back.touch(wn, hn[1])
    wn.teleport(hn[1], orig.pos, orig.rot)
    back.commit(wn)
    s.eqi(back.steps(), 0, "dragged back to where it started, the merged step has no net change and disappears")

    var ha2 = List[Int64]()
    var wab = build(ha2)
    var alog = UndoLog()
    var before_abort = rows(wab)
    alog.begin("oops")
    alog.touch(wab, ha2[1])
    alog.touch(wab, ha2[2])
    wab.teleport(ha2[1], Vec3(9.0, 9.0, 9.0, 0.0), wab.state(ha2[1]).rot)
    wab.set_velocity(ha2[2], Vec3(5.0, 0.0, 0.0, 0.0), Vec3(0.0, 0.0, 0.0, 0.0))
    alog.abort(wab)
    s.check(same(rows(wab), before_abort) and alog.steps() == 0, "abort puts every touched body back and leaves no step")

    var hnest = List[Int64]()
    var wnest = build(hnest)
    var nlog = UndoLog()
    nlog.begin("outer")
    nlog.touch(wnest, hnest[1])
    nlog.begin("inner")
    nlog.touch(wnest, hnest[2])
    wnest.teleport(hnest[1], Vec3(2.0, 2.0, 0.0, 0.0), wnest.state(hnest[1]).rot)
    wnest.teleport(hnest[2], Vec3(-2.0, 2.0, 0.0, 0.0), wnest.state(hnest[2]).rot)
    nlog.commit(wnest)
    s.eqi(nlog.steps(), 0, "an inner commit does not close the transaction")
    nlog.commit(wnest)
    s.eqi(nlog.steps(), 1, "the outer commit makes one step of both bodies")

    var htr = List[Int64]()
    var wtr = build(htr)
    var tlog = UndoLog()
    for k in range(3):
        log_edit(k, wtr, tlog, htr)
    _ = tlog.undo(wtr)
    s.check(tlog.can_redo(), "after an undo there is something to redo")
    log_edit(3, wtr, tlog, htr)
    s.check(not tlog.can_redo(), "a new commit ends the redo chain")

    var hl = List[Int64]()
    var wl = build(hl)
    var llog = UndoLog(3)
    for k in range(5):
        log_edit(k, wl, llog, hl)
    s.eqi(llog.steps(), 3, "past the limit the oldest steps are dropped")

    var he = List[Int64]()
    var we = build(he)
    var elog = UndoLog()
    elog.begin("nothing")
    elog.commit(we)
    elog.begin("touch only")
    elog.touch(we, he[1])
    elog.commit(we)
    s.eqi(elog.steps(), 0, "a transaction that changed nothing leaves no step")

    # ---- 5. errors
    var raised = 0
    try:
        elog.touch(we, he[1])
    except:
        raised += 1
    try:
        elog.commit(we)
    except:
        raised += 1
    elog.begin("open")
    try:
        _ = elog.undo(we)
    except:
        raised += 1
    try:
        elog.touch(we, 123456789)
    except:
        raised += 1
    elog.commit(we)
    var rec = body_record(we, he[1])
    var other_shape = rec.copy()
    other_shape.size = Vec3(2.0, 2.0, 2.0, 0.0)
    try:
        write_body_record(we, he[1], other_shape)
    except:
        raised += 1
    s.eqi(raised, 5, "touch / commit without a transaction, undo while open, a dead handle and a changed shape all raise")

    # ---- 6. size of a step: one body's records against a snapshot of the whole world
    var rec_bytes = 2 * size_of[SceneBody]()
    for n in [1000, 100000]:
        var wsnap = fresh()
        for i in range(n):
            _ = wsnap.add_box(Vec3(Real(i % 100) * 1.2, Real(i // 10000) * 1.2, Real((i // 100) % 100) * 1.2, 0.0), Vec3(0.5, 0.5, 0.5, 0.0), 1.0, False)
        var first = wsnap.bodies()[n // 2]
        var snap_log = SnapshotUndo()
        snap_log.begin(wsnap)
        wsnap.teleport(first, Vec3(5.0, 50.0, 5.0, 0.0), wsnap.state(first).rot)
        snap_log.commit(wsnap)
        s.check(snap_log.bytes() > 100 * rec_bytes, "a snapshot step at " + String(n) + " bodies is over 100x one body's records")
        if n == 100000:
            s.check(snap_log.bytes() > 10000 * rec_bytes, "...and at 100000 bodies over 10000x")

    s.finish()
