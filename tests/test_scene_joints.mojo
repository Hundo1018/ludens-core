# tier: integration
"""Joints in the scene API (ROADMAP 17.12 slice 4; ludens-core #82, #104).

- a chain of ball, hinge, distance and weld joints: scene path == snapshot path == original at tick 0 and after
  300 ticks (the joints constrain the motion, so a joint lost in the round trip changes the hash);
- rows: no joints, no joint rows; with joints rows -> doc -> rows is the identity;
- limits (one set, one cleared), a motor, a spring and a break threshold (17.97): the same three-way equality at tick
  0 and after 300 ticks, and the same scene without them ends differently; only the groups that are set get rows;
- joints the scene cannot describe are refused by name: a non-default collide flag, a hinge whose bodies moved after
  it was made (its zero-angle reference no longer matches);
- `EmbedWorld.remove_joint`: the slot stays (indices do not shift), the joint leaves the exported scene, the body it
  held can then be removed, while removing a body that still has a joint is refused;
- bad documents (body index out of range, one body twice, unknown kind) are refused and change nothing.
Times are not printed (the golden compares this output)."""
from harness.runner import Suite
from embed.scene_io import SceneDoc, SceneJoint, export_scene, import_scene, scene_diff, scene_from_fields, scene_to_fields
from embed.world import EmbedWorld
from geometry.quat import Quat
from geometry.vec import Real, Vec3
from physics.joint_ext import MOTOR_NONE, MOTOR_VELOCITY
from physics.joints6 import JOINT_BALL

comptime DT = 1.0 / 60.0


def fresh() raises -> EmbedWorld:
    return EmbedWorld(DT, Vec3(0.0, -9.81, 0.0, 0.0))


def build(mut hs: List[Int64]) raises -> EmbedWorld:
    var w = fresh()
    hs.append(w.add_box(Vec3(0.0, 6.0, 0.0, 0.0), Vec3(0.5, 0.5, 0.5, 0.0), 0.0, True))  # anchor, static
    hs.append(w.add_box(Vec3(1.5, 6.0, 0.0, 0.0), Vec3(0.5, 0.25, 0.25, 0.0), 1.0, False))
    hs.append(w.add_box(Vec3(3.0, 6.0, 0.0, 0.0), Vec3(0.5, 0.25, 0.25, 0.0), 1.0, False))
    hs.append(w.add_box(Vec3(4.5, 6.0, 0.0, 0.0), Vec3(0.5, 0.25, 0.25, 0.0), 1.0, False))
    hs.append(w.add_sphere(Vec3(6.0, 6.0, 0.0, 0.0), 0.4, 1.0, False))
    _ = w.add_ball_joint(hs[0], hs[1], Vec3(0.5, 0.0, 0.0, 0.0), Vec3(-0.5, 0.0, 0.0, 0.0))
    _ = w.add_hinge_joint(hs[1], hs[2], Vec3(0.5, 0.0, 0.0, 0.0), Vec3(-0.5, 0.0, 0.0, 0.0), Vec3(0.0, 0.0, 1.0, 0.0))
    _ = w.add_weld_joint(hs[2], hs[3], Vec3(0.5, 0.0, 0.0, 0.0), Vec3(-0.5, 0.0, 0.0, 0.0))
    _ = w.add_distance_joint(hs[3], hs[4], Vec3(0.5, 0.0, 0.0, 0.0), Vec3(-0.4, 0.0, 0.0, 0.0), 0.2)
    return w^


def run_ticks(mut w: EmbedWorld, n: Int) raises:
    for _ in range(n):
        for _ in range(w.ticks_due(DT)):
            w.physics_tick()


def add_ext(mut w: EmbedWorld) raises:
    """Joint 0 (ball): a limit set and then cleared (lo / hi stay); 1 (hinge): limit and velocity motor; 2 (weld): a
    break threshold low enough that it breaks; 3 (distance): a spring."""
    w.scene.set_joint_limits(0, -1.0, 1.0)
    w.scene.clear_joint_limits(0)
    w.scene.set_joint_limits(1, -0.3, 0.3)
    w.scene.set_joint_motor(1, MOTOR_VELOCITY, 2.0, 20.0)
    w.scene.set_joint_break(2, 30.0, 30.0)
    w.scene.set_joint_spring(3, 2.0, 0.3, 0.1)


def import_fails(doc: SceneDoc, needle: String) raises -> Bool:
    var t = fresh()
    try:
        import_scene(t, doc)
    except e:
        return needle in String(e) and len(export_scene(t).bodies) == 0
    return False


def refused(mut w: EmbedWorld, needle: String) raises -> Bool:
    try:
        _ = export_scene(w)
    except e:
        return needle in String(e)
    return False


def main() raises:
    var s = Suite("scene_joints")
    var hs = List[Int64]()
    var original = build(hs)
    var doc = export_scene(original)
    s.eqi(len(doc.joints), 4, "export: four joints")
    s.check(doc.joints[0].a == 0 and doc.joints[0].b == 1 and doc.joints[1].a == 1 and doc.joints[1].b == 2, "joints name bodies by position in the scene")

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
    var no_joint = fresh()
    var doc2 = export_scene(build(hs))
    doc2.joints = List[SceneJoint]()
    import_scene(no_joint, doc2)
    run_ticks(no_joint, 300)
    s.check(no_joint.hash() != rebuilt.hash(), "control: the same bodies without the joints end differently")

    # rows
    var hs1 = List[Int64]()
    var rows = scene_to_fields(export_scene(build(hs1)))
    var jrows = 0
    for i in range(len(rows)):
        if rows[i].path.startswith("joint"):
            jrows += 1
    s.eqi(jrows, 1 + 4 * 16, "joint rows: a count row and 16 rows per joint")
    var back = scene_from_fields(rows)
    s.check(len(scene_diff(scene_to_fields(back), rows)) == 0, "rows -> doc -> rows is the identity")
    var plain = fresh()
    _ = plain.add_box(Vec3(0.0, 1.0, 0.0, 0.0), Vec3(0.5, 0.5, 0.5, 0.0), 1.0, False)
    var any_j = False
    for f in scene_to_fields(export_scene(plain)):
        if f.path.startswith("joint"):
            any_j = True
    s.check(not any_j, "a scene without joints has no joint rows")

    # limits, motor, spring, break (17.97)
    var he = List[Int64]()
    var ext = build(he)
    add_ext(ext)
    var edoc = export_scene(ext)
    s.check(edoc.joints[0].has_limit() and not edoc.joints[0].lim_on and edoc.joints[1].lim_on and edoc.joints[1].motor == MOTOR_VELOCITY
            and edoc.joints[2].has_break() and edoc.joints[3].has_spring() and edoc.joints[3].motor == MOTOR_NONE,
            "export: the cleared limit, hinge limit and motor, weld break threshold and distance spring are in the document")
    var erows = scene_to_fields(edoc)
    var grp = 0
    for i in range(len(erows)):
        if erows[i].path.startswith("joint") and (".limit." in erows[i].path or ".motor." in erows[i].path or ".spring." in erows[i].path or ".break." in erows[i].path):
            grp += 1
    s.eqi(grp, 3 + 3 + 5 + 2 + 3, "rows only for the groups that are set (2 limits, 1 motor, 1 break, 1 spring)")
    s.check(len(scene_diff(scene_to_fields(scene_from_fields(erows)), erows)) == 0, "with extensions: rows -> doc -> rows is the identity")
    var erebuilt = fresh()
    import_scene(erebuilt, scene_from_fields(erows))
    var esnap = fresh()
    esnap.load(ext.save())
    s.check(erebuilt.hash() == ext.hash(), "with extensions: scene path == original at tick 0")
    s.check(esnap.hash() == erebuilt.hash(), "with extensions: scene path == snapshot path at tick 0")
    run_ticks(ext, 300)
    run_ticks(erebuilt, 300)
    run_ticks(esnap, 300)
    s.check(erebuilt.hash() == ext.hash(), "with extensions, after 300 ticks: scene path == original")
    s.check(esnap.hash() == erebuilt.hash(), "with extensions, after 300 ticks: snapshot path == scene path")
    s.check(erebuilt.hash() != rebuilt.hash(), "control: the same scene without the extensions ends differently")

    # what the scene cannot describe
    var h2 = List[Int64]()
    var w2 = build(h2)
    w2.scene.set_collide_connected(1, False)
    w2.scene.set_collide_connected(1, True)
    s.check(not refused(w2, "collide"), "a collide flag set back to the default is accepted")
    w2.scene.set_collide_connected(2, True)  # a weld is made with collide off
    s.check(refused(w2, "collide flag"), "a non-default collide flag is refused by name")
    var h4 = List[Int64]()
    var w4 = build(h4)
    w4.teleport(h4[2], Vec3(3.0, 6.0, 0.0, 0.0), Quat(0.0, 0.0, 0.3826834, 0.9238795))
    s.check(refused(w4, "differs from where it was made"), "a hinge whose body was turned after creation is refused")

    # remove_joint
    var h5 = List[Int64]()
    var w5 = build(h5)
    s.eqi(w5.joint_count(), 4, "four joint slots")
    var raised = False
    try:
        w5.remove(h5[4])
    except:
        raised = True
    s.check(raised, "removing a body that still has a joint is refused")
    w5.remove_joint(3)
    s.eqi(w5.joint_count(), 4, "removing a joint keeps its slot")
    s.eqi(len(export_scene(w5).joints), 3, "the removed joint is not in the exported scene")
    w5.remove(h5[4])
    s.check(not w5.is_alive(h5[4]), "the body the removed joint held can now be removed")
    raised = False
    try:
        w5.remove_joint(3)
    except:
        raised = True
    s.check(raised, "removing a joint twice is an error")
    run_ticks(w5, 60)
    s.eqi(len(w5.bodies()), 4, "the world keeps stepping after the removal (four bodies left)")

    # bad documents change nothing
    var good = export_scene(build(h5))
    var bad = export_scene(build(h5))
    bad.joints[0].b = 99
    var tgt = fresh()
    raised = False
    try:
        import_scene(tgt, bad)
    except e:
        raised = "out of range" in String(e)
    s.check(raised and len(export_scene(tgt).bodies) == 0, "a joint naming a missing body is refused, the world untouched")
    bad = export_scene(build(h5))
    bad.joints[0].b = bad.joints[0].a
    raised = False
    try:
        import_scene(tgt, bad)
    except e:
        raised = "must differ" in String(e)
    s.check(raised, "a joint from a body to itself is refused")
    bad = good.copy()
    bad.joints[0].kind = 42
    raised = False
    try:
        import_scene(tgt, bad)
    except e:
        raised = "unknown kind" in String(e)
    s.check(raised, "an unknown joint kind is refused")
    bad = good.copy()
    bad.joints[1].lim_on = True
    bad.joints[1].lo = 0.5
    bad.joints[1].hi = -0.5
    s.check(import_fails(bad, "lo <= hi"), "a limit with lo > hi is refused, the world untouched")
    bad = good.copy()
    bad.joints[1].motor = 7
    s.check(import_fails(bad, "unknown motor mode"), "an unknown motor mode is refused")
    bad = good.copy()
    bad.joints[2].break_force = 0.0
    s.check(import_fails(bad, "break thresholds"), "a break threshold of 0 is refused")
    s.finish()
