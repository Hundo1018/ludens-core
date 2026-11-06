# tier: integration
"""The surface material table in the scene API (ROADMAP 17.12 slice 3, 17.50; ludens-engine #82).

- a world with a material table: scene path == snapshot path at tick 0 and after 300 ticks;
- the table is part of the snapshot hash (a world without it hashes differently), so the comparison above sees it;
- rows: a scene without a table has no `materials` rows; with one, rows -> doc -> rows is the identity; a changed
  friction shows up as one changed row in a diff, and applying it gives the target;
- bad tables (repeated id, id out of range, an entry that sets nothing, negative friction) are refused and change nothing.
Times are not printed (the golden compares this output)."""
from harness.runner import Suite
from embed.scene_io import SceneDoc, SceneMaterial, export_scene, import_scene, scene_apply, scene_diff, scene_from_fields, scene_to_fields
from embed.world import EmbedWorld
from geometry.vec import Real, Vec3

comptime DT = 1.0 / 60.0


def fresh() raises -> EmbedWorld:
    return EmbedWorld(DT, Vec3(0.0, -9.81, 0.0, 0.0))


def build(with_table: Bool) raises -> EmbedWorld:
    var w = fresh()
    _ = w.add_box(Vec3(0.0, -1.0, 0.0, 0.0), Vec3(20.0, 1.0, 20.0, 0.0), 0.0, True)
    for i in range(3):
        _ = w.add_box(Vec3(Real(i) * 1.1 - 1.1, 1.0 + Real(i) * 1.05, 0.0, 0.0), Vec3(0.5, 0.5, 0.5, 0.0), 1.0, False)
    if with_table:
        w.set_material_friction(3, 0.7)
        w.set_material_softness(9, 30.0, 0.5)
        w.set_material_friction(12, 0.2)
        w.set_material_softness(12, 45.0, 0.25)
    return w^


def run_ticks(mut w: EmbedWorld, n: Int) raises:
    for _ in range(n):
        for _ in range(w.ticks_due(DT)):
            w.physics_tick()


def refused(doc: SceneDoc, needle: String) raises -> Bool:
    var w = fresh()
    try:
        import_scene(w, doc)
    except e:
        return needle in String(e) and len(export_scene(w).bodies) == 0 and len(export_scene(w).materials) == 0
    return False


def main() raises:
    var s = Suite("scene_materials")
    var original = build(True)
    var doc = export_scene(original)
    s.eqi(len(doc.materials), 3, "export: three table entries (3, 9, 12)")
    s.check(doc.materials[0].id == 3 and doc.materials[0].mu == 0.7 and doc.materials[0].hertz < 0, "entry 3: friction only")
    s.check(doc.materials[1].id == 9 and doc.materials[1].mu < 0 and doc.materials[1].hertz == 30.0 and doc.materials[1].zeta == 0.5, "entry 9: softness only")
    s.check(doc.materials[2].id == 12 and doc.materials[2].mu == 0.2 and doc.materials[2].hertz == 45.0, "entry 12: both")

    var rebuilt = fresh()
    import_scene(rebuilt, doc)
    s.check(rebuilt.hash() == original.hash(), "scene path == original at tick 0")
    var snap = fresh()
    snap.load(original.save())
    s.check(snap.hash() == rebuilt.hash(), "seam: scene path == snapshot path at tick 0")
    s.check(build(False).hash() != original.hash(), "the table is part of the snapshot hash")
    run_ticks(original, 300)
    run_ticks(rebuilt, 300)
    run_ticks(snap, 300)
    s.check(rebuilt.hash() == original.hash() and snap.hash() == rebuilt.hash(), "after 300 ticks all three are bit-identical")

    # rows
    var none_rows = scene_to_fields(export_scene(build(False)))
    var any_table_row = False
    for i in range(len(none_rows)):
        if none_rows[i].path.startswith("material"):
            any_table_row = True
    s.check(not any_table_row and len(none_rows) == 8 + 4 * 44, "no table: no material rows, row count unchanged")
    var rows = scene_to_fields(doc)
    s.eqi(len(rows), 8 + 4 * 44 + 1 + 3 * 4, "with a table: 1 count row + 4 rows per entry")
    var back = scene_from_fields(rows)
    s.check(len(scene_diff(scene_to_fields(back), rows)) == 0, "rows -> doc -> rows is the identity")
    var edited = export_scene(build(True))
    edited.materials[0].mu = 0.9
    var erows = scene_to_fields(edited)
    var changes = scene_diff(rows, erows)
    s.check(len(changes) == 1 and changes[0].path == "material.0.friction", "a changed friction is one changed row (" + (changes[0].path if len(changes) > 0 else String("none")) + ")")
    s.check(len(scene_diff(scene_apply(rows, changes), erows)) == 0, "applying the change gives the target rows")

    # bad tables
    var bad = export_scene(build(True))
    bad.materials[1].id = 3
    s.check(refused(bad, "appears twice"), "a repeated id is refused")
    bad = export_scene(build(True))
    bad.materials[0].id = 70000
    s.check(refused(bad, "0 .. 65535"), "an id out of range is refused")
    bad = export_scene(build(True))
    bad.materials[0].mu = -1.0
    s.check(refused(bad, "neither friction nor softness"), "an entry that sets nothing is refused")
    bad = export_scene(build(True))
    bad.materials[1].zeta = -1.0
    s.check(refused(bad, "softness"), "negative damping is refused")
    s.finish()
