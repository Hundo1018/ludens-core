# tier: integration
"""Capsules and kinematic bodies in the scene API (ROADMAP 17.12 slice 2, 17.43; ludens-engine #82, #83).

- a world with a capsule and a kinematic box that carries a velocity: scene path == snapshot path at tick 0 and after
  300 ticks (the kinematic box keeps moving, the capsule falls and rests);
- rows: a scene without a kinematic body has no `kinematic` row (same row count as before); with one the row is there
  and the text round trip is the identity; capsule size rows hold radius and half length;
- bad records: a static kinematic body, a capsule with zero half length, are refused and change nothing;
- undo: removing a kinematic body and a capsule and undoing brings back the same handles and the same rows; a body
  turned kinematic inside a transaction is turned back by undo (a different motion type, so the body is re-added).
Times are not printed (the golden compares this output)."""
from harness.runner import Suite
from embed.scene_io import BODY_CAPSULE, SceneDoc, export_scene, import_scene, scene_diff, scene_from_fields, scene_to_fields
from embed.undo import UndoLog
from embed.world import EmbedWorld, unpack_body
from geometry.vec import Real, Vec3

comptime DT = 1.0 / 60.0


def fresh() raises -> EmbedWorld:
    return EmbedWorld(DT, Vec3(0.0, -9.81, 0.0, 0.0))


def build(mut hs: List[Int64]) raises -> EmbedWorld:
    var w = fresh()
    hs.append(w.add_box(Vec3(0.0, -1.0, 0.0, 0.0), Vec3(20.0, 1.0, 20.0, 0.0), 0.0, True))
    hs.append(w.add_capsule(Vec3(0.0, 3.0, 0.0, 0.0), 0.4, 0.6, 2.0, False))
    var k = w.add_box(Vec3(-4.0, 0.5, 0.0, 0.0), Vec3(1.0, 0.5, 1.0, 0.0), 5.0, False)
    w.set_kinematic(k)
    w.set_velocity(k, Vec3(1.0, 0.0, 0.0, 0.0), Vec3(0.0, 0.0, 0.0, 0.0))
    hs.append(k)
    hs.append(w.add_box(Vec3(-3.5, 3.0, 0.0, 0.0), Vec3(0.5, 0.5, 0.5, 0.0), 1.0, False))
    return w^


def run_ticks(mut w: EmbedWorld, n: Int) raises:
    for _ in range(n):
        for _ in range(w.ticks_due(DT)):
            w.physics_tick()


def main() raises:
    var s = Suite("scene_kinematic")
    var hs = List[Int64]()
    var original = build(hs)
    var doc = export_scene(original)
    s.eqi(len(doc.bodies), 4, "export: 4 bodies (floor, capsule, kinematic box, box)")
    s.check(doc.bodies[1].kind == BODY_CAPSULE and doc.bodies[1].size[0] == 0.4 and doc.bodies[1].size[1] == 0.6, "capsule record: radius 0.4, half length 0.6")
    s.check(doc.bodies[2].kinematic and not doc.bodies[0].kinematic and not doc.bodies[3].kinematic, "only the kinematic box is flagged")

    var rebuilt = fresh()
    import_scene(rebuilt, doc)
    s.check(rebuilt.hash() == original.hash(), "scene path == original at tick 0")
    var snap = fresh()
    snap.load(original.save())
    s.check(snap.hash() == rebuilt.hash(), "seam: scene path == snapshot path at tick 0")
    run_ticks(original, 300)
    run_ticks(rebuilt, 300)
    run_ticks(snap, 300)
    s.check(rebuilt.hash() == original.hash(), "after 300 ticks: scene path == original")
    s.check(snap.hash() == rebuilt.hash(), "after 300 ticks: snapshot path == scene path")
    s.check(original.state(hs[2]).pos[0] > -4.0 + 4.9, "the kinematic box moved by its velocity (x > 0.9 after 5 s)")

    # rows
    var rows = scene_to_fields(doc)
    var kin_rows = 0
    for i in range(len(rows)):
        if rows[i].path.endswith(".kinematic"):
            kin_rows += 1
    s.eqi(kin_rows, 1, "one kinematic row, for the one kinematic body")
    s.eqi(len(rows), 8 + 4 * 44 + 1, "row count: 8 + 44 per body + 1 kinematic row")
    var back = scene_from_fields(rows)
    s.check(len(scene_diff(scene_to_fields(back), rows)) == 0, "rows -> doc -> rows is the identity")

    # bad records change nothing
    var both = export_scene(original)
    both.bodies[2].is_static = True
    var w2 = fresh()
    var raised = False
    try:
        import_scene(w2, both)
    except e:
        raised = "both static and kinematic" in String(e)
    s.check(raised and len(export_scene(w2).bodies) == 0, "static + kinematic is refused and the world is untouched")
    var flat = export_scene(original)
    flat.bodies[1].size = Vec3(0.4, 0.0, 0.0, 0.0)
    raised = False
    try:
        import_scene(w2, flat)
    except e:
        raised = "capsule" in String(e)
    s.check(raised, "a capsule with zero half length is refused")

    # undo: remove the capsule and the kinematic box in one transaction, then undo
    var hs3 = List[Int64]()
    var w3 = build(hs3)
    var before = scene_to_fields(export_scene(w3))
    var log = UndoLog()
    log.begin("delete")
    log.touch(w3, hs3[1])
    log.touch(w3, hs3[2])
    w3.remove(hs3[1])
    w3.remove(hs3[2])
    log.commit(w3)
    s.eqi(len(export_scene(w3).bodies), 2, "two bodies removed")
    s.check(log.undo(w3), "undo reports a step")
    var after = scene_to_fields(export_scene(w3))
    s.check(len(scene_diff(before, after)) == 0, "undo restores the rows, capsule and kinematic flag included")
    s.check(w3.is_alive(hs3[1]) and w3.is_alive(hs3[2]), "the same handles are alive again")

    # undo of turning a body kinematic
    var hs4 = List[Int64]()
    var w4 = build(hs4)
    var b4 = scene_to_fields(export_scene(w4))
    log = UndoLog()
    log.begin("make kinematic")
    log.touch(w4, hs4[3])
    w4.set_kinematic(hs4[3])
    log.commit(w4)
    s.check(export_scene(w4).bodies[3].kinematic, "the body is kinematic after the edit")
    s.check(log.undo(w4), "undo")
    s.check(not export_scene(w4).bodies[3].kinematic and len(scene_diff(b4, scene_to_fields(export_scene(w4)))) == 0, "undo makes it dynamic again (rows equal)")
    s.check(log.redo(w4) and export_scene(w4).bodies[3].kinematic, "redo makes it kinematic")
    s.finish()
