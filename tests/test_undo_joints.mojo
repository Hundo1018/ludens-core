# tier: integration
"""Undo and redo with joints (ROADMAP 17.43 / 17.12; ludens-engine #104, second half).

- deleting a body that has joints (the joints removed first, then the body, in one transaction) and undoing it brings
  back the same body handle, the same joints in the same slots, and the scene rows equal the rows before; after 120
  ticks the restored world's bodies are where an unedited world's bodies are;
- redo deletes again, a second undo brings it back;
- a joint added in a transaction is removed by undo and comes back with redo, in the same slot;
- abort of a transaction that removed joints puts them back;
- removing a body before its joints is refused by the engine and the transaction can be aborted;
- a joint edit that changes nothing leaves no step.
Times are not printed (the golden compares this output)."""
from harness.runner import Suite
from embed.scene_io import export_scene, scene_diff, scene_to_fields
from embed.undo import UndoLog
from embed.world import EmbedWorld
from geometry.vec import Real, Vec3

comptime DT = 1.0 / 60.0


def fresh() raises -> EmbedWorld:
    return EmbedWorld(DT, Vec3(0.0, -9.81, 0.0, 0.0))


def build(mut hs: List[Int64]) raises -> EmbedWorld:
    var w = fresh()
    hs.append(w.add_box(Vec3(0.0, 6.0, 0.0, 0.0), Vec3(0.5, 0.5, 0.5, 0.0), 0.0, True))
    for i in range(1, 4):
        hs.append(w.add_box(Vec3(Real(i) * 1.5, 6.0, 0.0, 0.0), Vec3(0.5, 0.25, 0.25, 0.0), 1.0, False))
    for i in range(3):
        _ = w.add_ball_joint(hs[i], hs[i + 1], Vec3(0.5, 0.0, 0.0, 0.0), Vec3(-0.5, 0.0, 0.0, 0.0))
    return w^


def run_ticks(mut w: EmbedWorld, n: Int) raises:
    for _ in range(n):
        for _ in range(w.ticks_due(DT)):
            w.physics_tick()


def live_joints(w: EmbedWorld) raises -> Int:
    return len(export_scene(w).joints)


def same_positions(a: EmbedWorld, b: EmbedWorld, ha: List[Int64], hb: List[Int64]) raises -> Bool:
    for i in range(len(ha)):
        var pa = a.state(ha[i]).pos
        var pb = b.state(hb[i]).pos
        if pa[0] != pb[0] or pa[1] != pb[1] or pa[2] != pb[2]:
            return False
    return True


def main() raises:
    var s = Suite("undo_joints")
    var hs = List[Int64]()
    var w = build(hs)
    var rows0 = scene_to_fields(export_scene(w))
    var log = UndoLog()

    # delete the middle body (hs[2]) with its two joints (slots 1 and 2)
    log.begin("delete body")
    log.touch_joint(w, 1)
    log.touch_joint(w, 2)
    w.remove_joint(1)
    w.remove_joint(2)
    log.touch(w, hs[2])
    w.remove(hs[2])
    log.commit(w)
    s.check(not w.is_alive(hs[2]) and live_joints(w) == 1, "after the edit: the body is gone and one joint is left")
    s.check(log.undo(w), "undo reports a step")
    s.check(w.is_alive(hs[2]), "the same handle is alive again")
    s.eqi(live_joints(w), 3, "all three joints are live again")
    s.check(len(scene_diff(rows0, scene_to_fields(export_scene(w)))) == 0, "the scene rows equal the rows before the edit")
    var h2 = List[Int64]()
    var plain = build(h2)
    run_ticks(w, 120)
    run_ticks(plain, 120)
    s.check(same_positions(w, plain, hs, h2), "after 120 ticks the bodies are where an unedited world's are (bit for bit)")

    # redo deletes again, undo restores again (fresh world: positions are at rest)
    var hs3 = List[Int64]()
    var w3 = build(hs3)
    var rows3 = scene_to_fields(export_scene(w3))
    var log3 = UndoLog()
    log3.begin("delete body")
    log3.touch_joint(w3, 1)
    log3.touch_joint(w3, 2)
    w3.remove_joint(1)
    w3.remove_joint(2)
    log3.touch(w3, hs3[2])
    w3.remove(hs3[2])
    log3.commit(w3)
    s.check(log3.undo(w3) and log3.redo(w3), "undo then redo")
    s.check(not w3.is_alive(hs3[2]) and live_joints(w3) == 1, "redo deletes the body and its joints again")
    s.check(log3.undo(w3) and len(scene_diff(rows3, scene_to_fields(export_scene(w3)))) == 0, "a second undo restores the rows again")

    # a joint added in a transaction
    var hs4 = List[Int64]()
    var w4 = fresh()
    hs4.append(w4.add_box(Vec3(0.0, 6.0, 0.0, 0.0), Vec3(0.5, 0.5, 0.5, 0.0), 0.0, True))
    hs4.append(w4.add_box(Vec3(1.5, 6.0, 0.0, 0.0), Vec3(0.5, 0.25, 0.25, 0.0), 1.0, False))
    var log4 = UndoLog()
    log4.begin("add joint")
    var slot = w4.add_ball_joint(hs4[0], hs4[1], Vec3(0.5, 0.0, 0.0, 0.0), Vec3(-0.5, 0.0, 0.0, 0.0))
    log4.created_joint(w4, slot)
    log4.commit(w4)
    s.eqi(live_joints(w4), 1, "a joint was added")
    s.check(log4.undo(w4) and live_joints(w4) == 0, "undo removes it")
    s.eqi(w4.joint_count(), 1, "...and its slot stays")
    s.check(log4.redo(w4) and live_joints(w4) == 1, "redo brings it back")

    # abort restores removed joints
    var hs5 = List[Int64]()
    var w5 = build(hs5)
    var log5 = UndoLog()
    log5.begin("remove joints")
    log5.touch_joint(w5, 0)
    w5.remove_joint(0)
    s.eqi(live_joints(w5), 2, "one joint removed inside the transaction")
    log5.abort(w5)
    s.eqi(live_joints(w5), 3, "abort puts it back")

    # removing the body first is refused; the transaction can be aborted
    var hs6 = List[Int64]()
    var w6 = build(hs6)
    var log6 = UndoLog()
    log6.begin("wrong order")
    log6.touch(w6, hs6[2])
    var raised = False
    try:
        w6.remove(hs6[2])
    except:
        raised = True
    s.check(raised, "removing a body that still has joints is refused")
    log6.abort(w6)
    s.check(w6.is_alive(hs6[2]) and live_joints(w6) == 3, "abort leaves everything as it was")

    # an edit that changes nothing leaves no step
    var hs7 = List[Int64]()
    var w7 = build(hs7)
    var log7 = UndoLog()
    log7.begin("noop")
    log7.touch_joint(w7, 0)
    log7.commit(w7)
    s.check(not log7.can_undo(), "touching a joint without changing it leaves no step")
    s.finish()
