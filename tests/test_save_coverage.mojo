# tier: integration
"""What EmbedWorld.save / load / hash carry (ludens-engine audit follow-up; ROADMAP 17.95).

For each piece of world state a host can change, two identical worlds are built and the state is changed in one:
  hash     does world.hash() differ from the untouched world's?
  restore  after save -> load into a fresh world, do 90 more ticks give the same body states (or, for host data, the
           same value read back) as the original?
State that is not carried is listed in embed.world.save_excludes() with the reason; this test fails both when an
excluded item starts being carried (so the list is shrunk) and when a carried item stops being carried.
"""

from harness.runner import Suite
from geometry.vec import Real, Vec3
from embed.world import EmbedWorld, save_excludes

comptime K_VELOCITY = 0
comptime K_GRAVITY = 1
comptime K_SOLVER = 2
comptime K_UNIT_SCALE = 3
comptime K_FRICTION = 4
comptime K_SOFTNESS = 5
comptime K_LAYER = 6
comptime K_KINEMATIC = 7
comptime K_HOST_MATERIAL = 8
comptime K_USER = 9
comptime K_JOINT = 10
comptime K_COUNT = 11


def _name(k: Int) -> String:
    var names: List[String] = ["velocity", "gravity", "solver", "unit_scale", "material_friction", "material_softness",
                               "layer", "kinematic", "host_material", "user", "joint"]
    return names[k]


def _base() raises -> EmbedWorld:
    var w = EmbedWorld(1.0 / 60.0, Vec3(0, -9.81, 0, 0))
    _ = w.add_box(Vec3(0, -0.5, 0, 0), Vec3(20, 0.5, 20, 0), 0.0, True)
    _ = w.add_box(Vec3(0, 1.0, 0, 0), Vec3(0.5, 0.5, 0.5, 0), 1.0, False)
    _ = w.add_box(Vec3(0.3, 2.2, 0, 0), Vec3(0.5, 0.5, 0.5, 0), 1.0, False)
    _ = w.add_sphere(Vec3(1.0, 3.0, 0, 0), 0.3, 1.0, False)
    return w^


def _apply(k: Int, mut w: EmbedWorld) raises:
    var hs = w.bodies()
    if k == K_VELOCITY:
        w.set_velocity(hs[3], Vec3(2, 0, 0, 0), Vec3(0, 0, 0, 0))
    elif k == K_GRAVITY:
        w.set_gravity(Vec3(0, -3, 0, 0))
    elif k == K_SOLVER:
        w.set_solver(2, 1)
    elif k == K_UNIT_SCALE:
        w.set_unit_scale(100.0)
    elif k == K_FRICTION:
        w.set_material_friction(0, 0.05)
    elif k == K_SOFTNESS:
        w.set_material_softness(0, 5.0, 0.1)
    elif k == K_LAYER:
        w.set_layer(hs[2], 2, 0)  # the upper box collides with nothing: it falls through the lower one and the ground
    elif k == K_KINEMATIC:
        w.set_kinematic(hs[1])
    elif k == K_HOST_MATERIAL:
        w.set_material(hs[2], 7)
    elif k == K_USER:
        w.set_user(hs[2], 4242)
    else:
        _ = w.add_ball_joint(hs[1], hs[2], Vec3(0, 0.5, 0, 0), Vec3(0, -0.5, 0, 0))


def _same_states(a: EmbedWorld, b: EmbedWorld) raises -> Bool:
    var ha = a.bodies()
    var hb = b.bodies()
    if len(ha) != len(hb):
        return False
    for i in range(len(ha)):
        var sa = a.state(ha[i])
        var sb = b.state(hb[i])
        if sa.pos[0] != sb.pos[0] or sa.pos[1] != sb.pos[1] or sa.pos[2] != sb.pos[2] or sa.rot.w != sb.rot.w:
            return False
    return True


def _run(mut w: EmbedWorld, ticks: Int) raises:
    for _ in range(ticks):
        _ = w.ticks_due(0.0)
        w.physics_tick()


def _excluded(name: String) -> Bool:
    for e in save_excludes():
        if e == name:
            return True
    return False


def main() raises:
    var s = Suite("save_coverage")
    for k in range(K_COUNT):
        var a = _base()
        var b = _base()
        _run(a, 5)
        _run(b, 5)
        _apply(k, a)
        var hash_differs = a.hash() != b.hash()
        var c = EmbedWorld(1.0 / 60.0, Vec3(0, -9.81, 0, 0))
        c.load(a.save())
        var restored: Bool
        if k == K_HOST_MATERIAL:
            restored = c.get_material(c.bodies()[2]) == 7
        elif k == K_USER:
            restored = c.get_user(c.bodies()[2]) == 4242
        else:
            _run(a, 90)
            _run(c, 90)
            restored = _same_states(a, c)
        var carried = hash_differs and restored
        print(_name(k), ": hash", "differs" if hash_differs else "same", "| save -> load", "restores" if restored else "loses")
        if _excluded(_name(k)):
            s.check(not carried, _name(k) + " is listed in save_excludes() and is not carried")
        else:
            s.check(carried, _name(k) + " is carried by save / load and seen by hash")
    # a water tank: save marks it, load refuses the blob, hash covers its particles
    var wa = _base()
    _ = wa.add_water(40, 12, 0.025, 0.0, 0.0, 0.25, 0.25, 5)
    var wb = _base()
    _ = wb.add_water(40, 12, 0.025, 0.0, 0.0, 0.25, 0.25, 5)
    _run(wa, 10)
    _run(wb, 10)
    var h_before = wa.hash()
    s.check(h_before == wb.hash(), "two identical worlds with water hash the same")
    _run(wa, 1)
    var stepped = wa.hash() != h_before
    print("water : hash", "differs" if stepped else "same", "after one more tick")
    s.check(stepped, "hash sees the water move")
    var refused = False
    var dry = EmbedWorld(1.0 / 60.0, Vec3(0, -9.81, 0, 0))
    try:
        dry.load(wa.save())
    except e:
        refused = "water tank" in String(e)
    s.check(refused and len(dry.bodies()) == 0, "load refuses a blob saved with a water tank; the world is unchanged")
    s.finish()
