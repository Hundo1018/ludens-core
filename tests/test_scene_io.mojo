# tier: integration
"""Scene read/write (ROADMAP 17.12, ludens-core #82; the file format is ludens-engine #9).

- seam: a world rebuilt from its exported scene is bit-identical to the one rebuilt from its deterministic
  snapshot (`EmbedWorld.save` / `load`): same hash at tick 0 and after 300 ticks;
- the scene as text rows (`scene_to_fields`) loses nothing: values that are not exact in decimal survive;
- `scene_diff` / `scene_apply`: the rows of a prefab override, exactly the changed ones, applied back to the base;
- the per-body physics properties (friction, damping, caps, contact model, sleep, CCD, axis locks) set through the
  scene's own setters survive export -> import, including the flags the solver gates on (checked by stepping);
- what slice 1 cannot represent is refused with a message, never dropped;
- a bad document changes nothing; the sizes it was measured at.
"""
from harness.runner import Suite
from embed.world import EmbedWorld
from embed.scene_io import (
    BODY_BOX,
    BODY_SPHERE,
    BodyProps,
    CHANGE_ADDED,
    CHANGE_CHANGED,
    SceneBody,
    SceneDoc,
    SceneField,
    export_scene,
    import_scene,
    scene_apply,
    scene_diff,
    scene_from_fields,
    scene_to_fields,
)
from geometry.quat import Quat
from geometry.vec import Real, Vec3
from physics.ccd6 import CCD_BULLET
from physics.material import COMBINE_AVERAGE, COMBINE_MAX

comptime DT = 1.0 / 60.0


def fresh() raises -> EmbedWorld:
    return EmbedWorld(DT, Vec3(0.0, -9.81, 0.0, 0.0))


def build(mut hs: List[Int64]) raises -> EmbedWorld:
    """A floor, six boxes of different sizes, two spheres: velocities, a tilted pose, layers, materials, user data."""
    var w = fresh()
    w.set_solver(6, 2)
    hs.append(w.add_box(Vec3(0.0, -1.0, 0.0, 0.0), Vec3(20.0, 1.0, 20.0, 0.0), 0.0, True))
    for i in range(6):
        var half = Vec3(0.3 + 0.1 * Real(i), 0.4, 0.5 - 0.05 * Real(i), 0.0)
        hs.append(w.add_box(Vec3(Real(i % 3) * 1.3 - 1.3, 1.0 + Real(i) * 1.1, Real(i // 3) * 1.2, 0.0), half, 1.0 + Real(i), False))
    hs.append(w.add_sphere(Vec3(0.2, 9.0, 0.1, 0.0), 0.4, 2.0, False))
    hs.append(w.add_sphere(Vec3(-0.6, 11.0, 0.3, 0.0), 0.25, 0.5, False))
    w.teleport(hs[2], Vec3(0.1, 2.5, 0.0, 0.0), Quat.from_axis_angle(Vec3(0.0, 1.0, 1.0, 0.0), 0.7))
    w.set_velocity(hs[3], Vec3(1.5, 0.0, -0.5, 0.0), Vec3(0.0, 2.0, 0.0, 0.0))
    w.set_velocity(hs[7], Vec3(-0.3, 0.0, 0.2, 0.0), Vec3(0.1, 0.0, 0.4, 0.0))
    w.set_layer(hs[4], 2, 0xFFFFFFFD)
    w.set_material(hs[5], 7)
    w.set_user(hs[6], 0xFFFFFFFFFFFFFFF0)  # above 2^63: user data is a full 64-bit value
    return w^


def run_ticks(mut w: EmbedWorld, n: Int) raises:
    for _ in range(n):
        for _ in range(w.ticks_due(DT)):
            w.physics_tick()


def same_rows(a: List[SceneField], b: List[SceneField]) -> Bool:
    return len(a) == len(b) and len(scene_diff(a, b)) == 0


def raises_with(mut w: EmbedWorld, doc: SceneDoc, needle: String) -> Bool:
    try:
        import_scene(w, doc)
    except e:
        return needle in String(e)
    return False


def main() raises:
    var s = Suite("scene_io")

    # ---- 1. export -> import, and the snapshot path, at tick 0 and after 300 ticks
    var hs = List[Int64]()
    var original = build(hs)
    var doc = export_scene(original)
    s.eqi(len(doc.bodies), 9, "export: 9 bodies (floor, 6 boxes, 2 spheres)")
    var rebuilt = fresh()
    import_scene(rebuilt, doc)
    s.check(rebuilt.hash() == original.hash(), "import(export(world)) hashes equal to the world, tick 0")
    var from_snapshot = fresh()
    from_snapshot.set_solver(6, 2)
    from_snapshot.load(original.save())
    s.check(from_snapshot.hash() == rebuilt.hash(), "seam: scene path == snapshot path at tick 0")
    var hb = rebuilt.bodies()
    s.check(rebuilt.get_material(hb[5]) == 7 and rebuilt.get_user(hb[6]) == 0xFFFFFFFFFFFFFFF0, "material and a 64-bit user value survive")
    run_ticks(original, 300)
    run_ticks(rebuilt, 300)
    run_ticks(from_snapshot, 300)
    s.check(rebuilt.hash() == original.hash(), "after 300 ticks: scene-built world == the original")
    s.check(rebuilt.hash() == from_snapshot.hash(), "after 300 ticks: scene path == snapshot path")

    # ---- 2. text rows lose nothing
    var rows = scene_to_fields(doc)
    s.eqi(len(rows), 8 + 9 * 44, "row count: 8 settings rows + 44 rows per body")
    var round = scene_from_fields(rows)
    s.check(same_rows(scene_to_fields(round), rows), "fields -> doc -> fields is the identity")
    var w2 = fresh()
    import_scene(w2, round)
    var hs0 = List[Int64]()
    var w0 = build(hs0)
    s.check(w2.hash() == w0.hash(), "a world built from the text rows hashes equal to the original build")

    var awk = SceneDoc()
    awk.gravity = Vec3(0.0, Real(-9.81), 0.0, 0.0)
    awk.iters = 4
    awk.substeps = 3
    awk.bodies.append(
        SceneBody(
            BODY_BOX, Vec3(Real(1.0 / 3.0), Real(2.0 / 7.0), 0.1, 0.0), 1.1, False,
            Vec3(Real(1.0 / 3.0), Real(10.0 / 3.0), Real(-0.1), 0.0),
            Quat(Real(0.1), Real(0.2), Real(0.3), Real(0.9273618495495704)),
            Vec3(Real(0.1), 0.0, Real(-1.0 / 7.0), 0.0), Vec3(0.0, Real(1.0 / 9.0), 0.0, 0.0),
            3, 0xFFFFFFFE, 0, 0, BodyProps.defaults(), False,
        )
    )
    var awk_world = fresh()
    import_scene(awk_world, awk)
    var again = scene_from_fields(scene_to_fields(export_scene(awk_world)))
    var awk_world2 = fresh()
    import_scene(awk_world2, again)
    s.check(awk_world.hash() == awk_world2.hash(), "1/3, 2/7, 1/9 and a non-trivial rotation survive world -> rows -> world")

    # ---- 3. diff and apply: the rows of an override
    var base = scene_to_fields(doc)
    var edited = scene_from_fields(base)
    edited.bodies[2].pos = Vec3(edited.bodies[2].pos[0] + 1.0, edited.bodies[2].pos[1], edited.bodies[2].pos[2], 0.0)
    edited.gravity = Vec3(0.0, -3.0, 0.0, 0.0)
    edited.bodies.append(SceneBody(BODY_SPHERE, Vec3(0.5, 0.0, 0.0, 0.0), 1.0, False, Vec3(0.0, 20.0, 0.0, 0.0), Quat.identity(),
                                   Vec3(0.0, 0.0, 0.0, 0.0), Vec3(0.0, 0.0, 0.0, 0.0), 1, 0xFFFFFFFF, 0, 0, BodyProps.defaults(), False))
    var target = scene_to_fields(edited)
    var changes = scene_diff(base, target)
    var changed = 0
    var added = 0
    var only_expected = True
    for i in range(len(changes)):
        if changes[i].kind == CHANGE_CHANGED:
            changed += 1
            var p = changes[i].path
            if p != "gravity.y" and p != "body.2.pos.x" and p != "bodies.count":
                only_expected = False
        elif changes[i].kind == CHANGE_ADDED:
            added += 1
    s.eqi(changed, 3, "diff: 3 changed rows (gravity.y, body.2.pos.x, bodies.count)")
    s.eqi(added, 44, "diff: 44 added rows for the one new body")
    s.check(only_expected, "diff: no other row differs")
    s.check(same_rows(scene_apply(base, changes), target), "apply(base, diff(base, target)) == target")
    s.eqi(len(scene_diff(base, base)), 0, "diff of a scene with itself is empty")
    var wrong_base = scene_to_fields(doc)
    for i in range(len(wrong_base)):
        if wrong_base[i].path == "gravity.y":
            wrong_base[i].text = "99"  # a base the change (gravity.y -9.81 -> -3) was not made against
    var landed = True
    try:
        _ = scene_apply(wrong_base, changes)
    except e:
        landed = False
    s.check(not landed, "an override whose `before` does not match the base raises")

    # ---- 4. what slice 1 cannot represent is refused, by name
    var hc = List[Int64]()
    var custom = build(hc)
    custom.scene.bset.bodies[1].inertia.ix = custom.scene.bset.bodies[1].inertia.ix * 2
    var msg = String()
    try:
        _ = export_scene(custom)
    except e:
        msg = String(e)
    s.check("custom inertia" in msg, "a custom inertia tensor is refused")
    var wet = fresh()
    _ = wet.add_water(8, 8, Real(0.25), Real(0.3), Real(0.3), Real(1.5), Real(1.0), 1)
    msg = String()
    try:
        _ = export_scene(wet)
    except e:
        msg = String(e)
    s.check("water" in msg, "a water tank is refused")

    # ---- 5. removed slots are skipped
    var hr = List[Int64]()
    var gappy = build(hr)
    gappy.remove(hr[4])
    var gdoc = export_scene(gappy)
    s.eqi(len(gdoc.bodies), 8, "a removed body is not exported")
    var gw = fresh()
    import_scene(gw, gdoc)
    s.eqi(len(gw.bodies()), 8, "and the imported world has 8 bodies")

    # ---- 6. a bad document changes nothing
    var occupied = fresh()
    _ = occupied.add_box(Vec3(0.0, 0.0, 0.0, 0.0), Vec3(1.0, 1.0, 1.0, 0.0), 1.0, False)
    var before = occupied.hash()
    s.check(raises_with(occupied, doc, "empty"), "import into a world that has bodies raises")
    s.check(occupied.hash() == before, "...and leaves it unchanged")

    var bad_version = export_scene(rebuilt)
    bad_version.version = 2
    var e1 = fresh()
    s.check(raises_with(e1, bad_version, "version"), "an unknown version raises")
    var bad_size = scene_from_fields(scene_to_fields(doc))
    bad_size.bodies[3].size = Vec3(0.5, -0.5, 0.5, 0.0)
    var e2 = fresh()
    s.check(raises_with(e2, bad_size, "body 3"), "a negative half extent raises and names the body")
    s.eqi(len(e2.bodies()), 0, "...with no body added before the failure")
    var bad_mass = scene_from_fields(scene_to_fields(doc))
    bad_mass.bodies[8].mass = 0.0
    var e3 = fresh()
    s.check(raises_with(e3, bad_mass, "mass"), "a dynamic body without mass raises")
    var bad_rot = scene_from_fields(scene_to_fields(doc))
    bad_rot.bodies[2].rot = Quat(0.0, 0.0, 0.0, 3.0)
    var e4 = fresh()
    s.check(raises_with(e4, bad_rot, "unit quaternion"), "a non-unit rotation raises")

    var no_mass = scene_to_fields(doc)
    var kept = List[SceneField]()
    for i in range(len(no_mass)):
        if no_mass[i].path != "body.1.mass":
            kept.append(SceneField(no_mass[i].path, no_mass[i].text))
    var missing = String()
    try:
        _ = scene_from_fields(kept)
    except e:
        missing = String(e)
    s.check("body.1.mass" in missing, "a missing row raises with its path")
    var flagged = scene_to_fields(doc)
    for i in range(len(flagged)):
        if flagged[i].path == "body.0.static":
            flagged[i].text = "yes"
    var bad_flag = String()
    try:
        _ = scene_from_fields(flagged)
    except e:
        bad_flag = String(e)
    s.check("body.0.static" in bad_flag, "a malformed row raises with its path")


    # ---- 8. per-body properties, set through the scene's own setters
    var hp = List[Int64]()
    var pw = build(hp)
    pw.scene.set_friction(1, 0.3)
    pw.scene.set_static_friction(1, 0.5)
    pw.scene.set_restitution(2, 0.6)
    pw.scene.set_restitution_combine(2, COMBINE_AVERAGE)
    pw.scene.set_friction_combine(2, COMBINE_MAX)
    pw.scene.set_damping(pw.scene.bset.id_of(3), 0.4, 0.2)
    pw.scene.set_gravity_scale(pw.scene.bset.id_of(4), 0.5)
    pw.scene.set_max_velocity(pw.scene.bset.id_of(5), 4.0, 3.0)
    pw.scene.set_rolling_resistance(6, 0.02)
    pw.scene.set_spinning_resistance(6, 0.01)
    pw.scene.set_contact_softness(7, 40.0, 0.6)
    pw.scene.set_adhesion(8, 1.5)
    pw.scene.set_can_sleep(pw.scene.bset.id_of(1), False)
    pw.scene.set_ccd_mode(pw.scene.bset.id_of(7), CCD_BULLET)
    pw.scene.set_contact_reporting(pw.scene.bset.id_of(2), True)
    pw.scene.set_sleep_thresholds(pw.scene.bset.id_of(8), 0.05, 0.04)
    pw.scene.set_axis_locks(pw.scene.bset.id_of(3), False, False, True, True, True, False)
    var pdoc = export_scene(pw)
    s.check(pdoc.bodies[1].props.friction == 0.3 and pdoc.bodies[2].props.restitution == 0.6, "export reads friction and restitution")
    s.check(pdoc.bodies[7].props.ccd_mode == CCD_BULLET and pdoc.bodies[3].props.locks == (4 | 8 | 16), "export reads the CCD mode and the lock mask")
    var pcopy = fresh()
    import_scene(pcopy, scene_from_fields(scene_to_fields(pdoc)))
    s.check(pcopy.hash() == pw.hash(), "properties: world -> rows -> world hashes equal at tick 0")
    run_ticks(pw, 300)
    run_ticks(pcopy, 300)
    s.check(pcopy.hash() == pw.hash(), "properties: equal after 300 ticks (the any_* flags the solver gates on were raised)")
    var plain_h = List[Int64]()
    var plain = build(plain_h)
    run_ticks(plain, 300)
    s.check(plain.hash() != pw.hash(), "control: the properties change the simulation")

    var one = scene_to_fields(doc)
    var two = scene_to_fields(doc)
    for i in range(len(two)):
        if two[i].path == "body.3.friction":
            two[i].text = "0.25"
    var pd = scene_diff(one, two)
    s.check(len(pd) == 1 and pd[0].path == "body.3.friction" and pd[0].kind == CHANGE_CHANGED, "diff: one property change is one row")

    var no_pending = build(hp)
    no_pending.scene.bset.force[3] = Vec3(1.0, 0.0, 0.0, 0.0)
    msg = String()
    try:
        _ = export_scene(no_pending)
    except e:
        msg = String(e)
    s.check("pending" in msg, "a force pending for the next step is refused")
    var zoned = build(hp)
    zoned.scene.bset.grav_on[2] = True
    msg = String()
    try:
        _ = export_scene(zoned)
    except e:
        msg = String(e)
    s.check("own gravity" in msg, "a per-body gravity is refused")
    var frozen = build(hp)
    frozen.scene.freeze(frozen.scene.bset.id_of(2))
    msg = String()
    try:
        _ = export_scene(frozen)
    except e:
        msg = String(e)
    s.check("frozen" in msg, "a frozen body is refused")

    var bad_p = scene_from_fields(scene_to_fields(doc))
    bad_p.bodies[2].props.restitution = 1.5
    var e5 = fresh()
    s.check(raises_with(e5, bad_p, "restitution"), "restitution above 1 raises")
    var bad_l = scene_from_fields(scene_to_fields(doc))
    bad_l.bodies[2].props.locks = 64
    var e6 = fresh()
    s.check(raises_with(e6, bad_l, "locks"), "a lock mask above 6 bits raises")
    var bad_d = scene_from_fields(scene_to_fields(doc))
    bad_d.bodies[2].props.lin_damping = -1.0
    var e7 = fresh()
    s.check(raises_with(e7, bad_d, "damping"), "negative damping raises")
    s.eqi(len(e7.bodies()), 0, "...before any body is added")

    # ---- 7. size: 1000 bodies
    var big = fresh()
    for i in range(1000):
        _ = big.add_box(Vec3(Real(i % 10) * 1.5, Real(i // 100) * 1.2, Real((i // 10) % 10) * 1.5, 0.0), Vec3(0.5, 0.5, 0.5, 0.0), 1.0, False)
    var big_doc = export_scene(big)
    var big_back = fresh()
    import_scene(big_back, scene_from_fields(scene_to_fields(big_doc)))
    s.check(big_back.hash() == big.hash(), "1000 bodies: world -> rows -> world is bit-identical")
    s.eqi(len(scene_to_fields(big_doc)), 8 + 1000 * 44, "1000 bodies: 44 rows each")

    s.finish()
