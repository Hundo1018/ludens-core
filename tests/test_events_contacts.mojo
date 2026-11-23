# tier: integration
"""The adapter from `collision.contact_events.ContactEvent` (produced by a
REAL `physics.solver6.ContactScene6` stack -- ordinary rigid-body contact,
not a hand-built event list) onto `scheduler.events.Channel`, with a reader
that receives began/ended (roadmap 17.38's own wiring requirement).

LAYER NOTE (why the adapter lives here, not in `scheduler/events.mojo`):
`scheduler` and `collision` are BOTH layer 3 (`docs/ARCHITECTURE.md` §1), so
`scheduler/events.mojo` cannot import `collision.contact_events` -- that
would be a same-layer edge, which the reach-through/cycle rules forbid.
`publish_contact_events` below is the "small adapter" the design note asks
for. Before the `gameplay` package (layer 5) existed, this test was the
production-style caller architecture law v3 requires ("接上專案" -- reached
by at least one real caller, not left as an island the way
`geometry/quickhull.mojo` was before `947a37f`). The production adapter now
lives in `gameplay/runtime.mojo` (`Runtime` forwards `scene.events` onto
its `events` channel each fixed tick); this test still checks the same
adapter shape against a real `ContactScene6`."""

from harness.runner import Suite
from geometry.vec import Real, Vec3
from physics.rigid6 import Inertia3, QuatBody6
from physics.solver6 import ContactScene6
from collision.contact_events import ContactEvent, EV_BEGAN, EV_ENDED
from scheduler.events import Channel

comptime DT: Real = 1.0 / 60.0
comptime G = Vec3(0, -9.8, 0, 0)


def _floor(mut sc: ContactScene6[QuatBody6]) -> Int:
    return sc.add(
        QuatBody6.at_rest(Vec3(0, -1, 0, 0), Inertia3.box(1, 30, 1, 30)),
        Vec3(30, 1, 30, 0), True,
    ).index()


def _crate(x: Real, y: Real) -> QuatBody6:
    return QuatBody6.at_rest(Vec3(x, y, 0, 0), Inertia3.box(2, 0.25, 0.25, 0.25))


def publish_contact_events(mut ch: Channel[ContactEvent], events: List[ContactEvent]):
    """THE ADAPTER: forward one step's contact events onto a channel, in the
    solver's own order -- already deterministic
    (`collision.contact_events.diff_events`'s sorted merge), so the channel's
    own sequence numbers just extend that same total order across frames."""
    for i in range(len(events)):
        ch.send(events[i].copy())


def main() raises:
    var s = Suite("events_contacts")

    var sc = ContactScene6[QuatBody6]()
    sc.events_on = True
    _ = _floor(sc)
    var b = sc.add(_crate(0, 0.3), Vec3(0.25, 0.25, 0.25, 0), False).index()

    var ch = Channel[ContactEvent]()
    var r = ch.register_reader()

    var began_total = 0
    var stay_total = 0
    var ended_total = 0
    for _ in range(40):
        sc.step_soft(DT, G)
        publish_contact_events(ch, sc.events)
        ch.update()
        var out = List[ContactEvent]()
        ch.read(r, out)
        for i in range(len(out)):
            if out[i].kind == EV_BEGAN:
                began_total += 1
            elif out[i].kind == EV_ENDED:
                ended_total += 1
            else:
                stay_total += 1

    s.check(
        began_total >= 1,
        "reader receives at least one BEGAN from a real ContactScene6 stack",
    )
    s.check(stay_total >= 1, "reader receives STAY once the crate has settled")
    s.eqi(ended_total, 0, "nothing ended yet -- the crate is still resting on the floor")

    # Teleport the crate away: the contact must END, and the reader (which
    # kept draining every step) must see it -- not miss it to the double
    # buffer's 2-update retention window, since it reads every step.
    sc.bset.bodies[b].pos = Vec3(0, 40, 0, 0)
    sc.bset.sleeping[b] = False
    sc.step_soft(DT, G)
    publish_contact_events(ch, sc.events)
    ch.update()
    var out2 = List[ContactEvent]()
    ch.read(r, out2)
    for i in range(len(out2)):
        if out2[i].kind == EV_ENDED:
            ended_total += 1
    s.check(ended_total >= 1, "reader receives ENDED after the contact is broken by a teleport")

    s.finish()
