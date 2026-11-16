# tier: integration
"""Save and load of a world with a fractured object (ROADMAP 17.93; ludens-engine#75).

  ordinary     a 40-piece wall hit by a 2000 kg crate at 30 m/s: saved at tick 30 (mid-break), loaded into a fresh world,
               both stepped 120 more ticks: every body's state and the live weld count are bit for bit the same, the
               fracture events after the load are the same, and the two worlds' save bytes are equal.
  round trip   save -> load -> save gives the same bytes.
  replace      loading a blob without a fractured object into a world that has one clears it; loading one with a
               fractured object into a world that has one replaces it.
  extreme      a truncated fracture trailer raises and leaves the world as it was.
"""

from harness.runner import Suite
from geometry.vec import Real, Vec3
from embed.world import EmbedWorld


def _world() raises -> EmbedWorld:
    var w = EmbedWorld(1.0 / 60.0, Vec3(0, -9.81, 0, 0))
    _ = w.add_box(Vec3(0, -0.5, 0, 0), Vec3(50, 0.5, 50, 0), 0.0, True)
    return w^


def _same(a: List[UInt8], b: List[UInt8]) -> Bool:
    if len(a) != len(b):
        return False
    for i in range(len(a)):
        if a[i] != b[i]:
            return False
    return True


def main() raises:
    var s = Suite("fracture_save")
    var a = _world()
    _ = a.add_fracture_box(Vec3(0, 2, 0, 0), Vec3(4, 2, 0.3, 0), 40, 7, 50.0, 2000.0)
    var crate = a.add_box(Vec3(0, 2.2, 4, 0), Vec3(0.6, 0.6, 0.6, 0), 2000.0, False)
    a.set_velocity(crate, Vec3(0, 0, -30, 0), Vec3(0, 0, 0, 0))
    var events_before = 0
    for _ in range(30):
        _ = a.ticks_due(0.0)
        a.physics_tick()
        events_before += len(a.frame_fracture)
    var blob = a.save()
    var live_at_save = a.fracture.live_bonds()
    print("saved at tick 30:", len(blob), "bytes,", events_before, "fracture events so far,", live_at_save, "welds live")
    s.check(events_before > 0 and live_at_save > 0, "the save is mid-break: some welds broke, some are live")

    var b = EmbedWorld(1.0 / 60.0, Vec3(0, -9.81, 0, 0))
    b.load(blob)
    s.check(b.fracture_on and b.fracture.fragments() == 40 and b.fracture.live_bonds() == live_at_save,
            "loaded: 40 fragments, the same live welds (" + String(b.fracture.live_bonds()) + ")")
    s.check(_same(b.save(), blob), "save -> load -> save gives the same bytes")

    var ea = 0
    var eb = 0
    for _ in range(120):
        _ = a.ticks_due(0.0)
        a.physics_tick()
        ea += len(a.frame_fracture)
        _ = b.ticks_due(0.0)
        b.physics_tick()
        eb += len(b.frame_fracture)
    var same_states = True
    for h in a.bodies():
        var sa = a.state(h)
        var sb = b.state(h)
        same_states = same_states and sa.pos[0] == sb.pos[0] and sa.pos[1] == sb.pos[1] and sa.pos[2] == sb.pos[2]
        same_states = same_states and sa.rot.x == sb.rot.x and sa.rot.w == sb.rot.w
    print("after 120 more ticks: events", ea, "/", eb, "live welds", a.fracture.live_bonds(), "/", b.fracture.live_bonds())
    s.check(same_states, "after 120 more ticks every body's state is bit for bit the same as the uninterrupted run")
    s.check(ea == eb and a.fracture.live_bonds() == b.fracture.live_bonds() and ea > 0,
            "the same fracture events after the load (" + String(ea) + ") and live welds")
    s.check(_same(a.save(), b.save()), "the two worlds save to the same bytes")

    var plain = _world()
    var plain_blob = plain.save()
    var c = _world()
    _ = c.add_fracture_box(Vec3(0, 2, 0, 0), Vec3(4, 2, 0.3, 0), 10, 3, 50.0, 2000.0)
    c.load(plain_blob)
    s.check(not c.fracture_on, "a blob without a fractured object clears the world's")
    c.load(blob)
    s.check(c.fracture_on and c.fracture.fragments() == 40, "a blob with one replaces it")
    var cut = List[UInt8]()
    for i in range(len(blob) - 9):
        cut.append(blob[i])
    var d = _world()
    var raised = False
    try:
        d.load(cut)
    except:
        raised = True
    s.check(raised and not d.fracture_on and len(d.bodies()) == 1, "a truncated fracture trailer raises; the world is unchanged")
    s.finish()
