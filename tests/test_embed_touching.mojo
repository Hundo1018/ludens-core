# tier: integration
"""EmbedWorld.touching (ROADMAP 17.12, #113): the pair query event sheets read.

  1. A box dropped on the ground: touching(box, ground) is False in the air (first True at the analytic fall time), True from the tick of impact on, in both
     argument orders; touching(box, other) stays False; the world hash is the same with and without the queries.
  2. A box thrown upward off the ground: False again once it has left (ENDED is not touching).
  3. a == b, a removed body and a made-up handle give False without raising.
  4. The pair list agrees with the events the tick reported: touching_count equals the number of non-ENDED events.
"""

from harness.runner import Suite
from geometry.vec import Real, Vec3
from embed.world import EmbedWorld


def build() raises -> Tuple[EmbedWorld, Int64, Int64, Int64]:
    var w = EmbedWorld(1.0 / 60.0, Vec3(0.0, -9.81, 0.0, 0.0))
    var ground = w.add_box(Vec3(0.0, -0.5, 0.0, 0.0), Vec3(20.0, 0.5, 20.0, 0.0), 0.0, True)
    var box = w.add_box(Vec3(0.0, 1.0, 0.0, 0.0), Vec3(0.5, 0.5, 0.5, 0.0), 1.0, False)
    var far = w.add_box(Vec3(10.0, 5.0, 0.0, 0.0), Vec3(0.5, 0.5, 0.5, 0.0), 1.0, False)
    return (w^, ground, box, far)


def main() raises:
    var s = Suite("embed_touching")
    var t = build()
    ref w = t[0]
    var ground = t[1]
    var box = t[2]
    var far = t[3]
    var first = -1
    var always = True
    var count_ok = True
    for n in range(240):
        for _ in range(w.ticks_due(1.0 / 60.0)):
            w.physics_tick()
        var touch = w.touching(box, ground)
        if first < 0 and touch:
            first = n
        if first >= 0 and n > first + 60 and not touch:
            always = False
        if touch != w.touching(ground, box) or w.touching(box, far):
            always = False
        var non_ended = 0
        for e in w.tick_events:
            if e.kind != 2:
                non_ended += 1
        if non_ended != w.touching_count():
            count_ok = False
    s.check(first + 1 >= 18 and first + 1 <= 21, "contact reported on tick " + String(first + 1) + "; free fall of 0.5 m takes sqrt(2 * 0.5 / 9.81) = 0.319 s = 19.2 ticks")
    s.check(always, "True from then on while resting, symmetric, never with the far box")
    s.check(count_ok, "touching_count equals the non-ENDED events of the tick")

    var t2 = build()
    var t3 = build()
    for _ in range(120):
        for _ in range(t2[0].ticks_due(1.0 / 60.0)):
            t2[0].physics_tick()
            _ = t2[0].touching(t2[2], t2[1])
        for _ in range(t3[0].ticks_due(1.0 / 60.0)):
            t3[0].physics_tick()
    s.check(t2[0].hash() == t3[0].hash(), "querying does not change the world hash")

    # leaving: throw the box up
    var t4 = build()
    ref w4 = t4[0]
    for _ in range(90):
        for _ in range(w4.ticks_due(1.0 / 60.0)):
            w4.physics_tick()
    var resting = w4.touching(t4[2], t4[1])
    var st = w4.state(t4[2])
    w4.set_velocity(t4[2], Vec3(0.0, 6.0, 0.0, 0.0), st.omega)
    var left = False
    for _ in range(10):
        for _ in range(w4.ticks_due(1.0 / 60.0)):
            w4.physics_tick()
        var ended_now = False
        for e in w4.tick_events:
            if e.kind == 2:
                ended_now = True
        if ended_now and not w4.touching(t4[2], t4[1]):
            left = True  # the tick that reported ENDED reads False
    s.check(resting and left, "resting then thrown up: the tick that reports ENDED reads touching = False")

    var t5 = build()
    ref w5 = t5[0]
    w5.remove(t5[3])
    s.check(not w5.touching(t5[2], t5[2]) and not w5.touching(t5[3], t5[1]) and not w5.touching(Int64(987654321), t5[1]), "a == b, a removed body and a made-up handle give False")
    s.finish()
