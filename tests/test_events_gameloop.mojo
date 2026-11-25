# tier: integration
"""17.38 wired through the production entry point: `scheduler.events.Channel`
driven by `scheduler.gameloop.FixedLoop`'s real tick count over several
frames -- not a hand-rolled frame counter -- checking the exact guarantee the
roadmap note states: a reader running before or after the writer in a frame
still sees each event exactly once.

Contact-event wiring through a REAL `ContactScene6` stack is a separate file
(`tests/test_events_contacts.mojo`), so THIS file does not import `physics`
alongside `scheduler.gameloop` + `ecs`: doing all three together in one file
is exactly the shape `docs/ARCHITECTURE.md` §3 reserves for the `system`
tier (e.g. `test_system_stack`), not `integration` -- this file stays `integration`
(span = {scheduler, ecs}) on purpose.

WHAT "before or after the writer" MEANS HERE: `r_after` reads once per frame,
right after that frame's `send`+`update` -- it sees each frame's event
immediately, the same frame it was produced. `r_before` reads once per frame,
BEFORE that frame's `send`+`update` runs -- structurally identical to a
reader system that happens to be scheduled ahead of the event-producing
system that tick. It can never see the CURRENT frame's own event (it hasn't
been sent yet when `r_before` reads), so it is always exactly one frame
behind -- but the double-buffer retention means it is never MORE than one
frame behind: nothing is lost, only delayed by one read. The test proves
this by giving `r_before` one extra read after the loop ends and checking
its running total then reaches the full count."""

from harness.runner import Suite
from ecs.world import World
from ecs.storage import StorageBackend
from ecs.sparse_backend import SparseSetBackend
from ecs.component import ComponentType
from scheduler.scheduler import System
from scheduler.sequential import SequentialScheduler
from scheduler.gameloop import FixedLoop
from scheduler.events import Channel


@fieldwise_init
struct Evt(Copyable, Deinitable, Movable):
    var seq: Int


@fieldwise_init
struct Marker(ComponentType):
    comptime ID: Int = 0
    var n: Int


struct NoopSystem(System):
    """The `Scheduler`/`World` machinery here exists only so `FixedLoop` has
    a real `Scheduler` to drive -- it is the actual production entry point
    (`scheduler/gameloop.mojo`), not test scaffolding reimplementing it. The
    event bus itself is independent of ECS; nothing about it needs a
    component to be published or read."""

    @staticmethod
    def apply[B: StorageBackend](mut w: World[B]):
        pass


comptime Bk = SparseSetBackend[Marker]
comptime Sched = SequentialScheduler[SparseSetBackend[Marker], NoopSystem]


def _fresh_world() -> World[Bk]:
    var w = World[Bk]()
    var e = w.spawn()
    w.set(e, Marker(0))
    return w^


def main() raises:
    var s = Suite("events_gameloop")
    comptime dt: Float64 = 1.0 / 60.0
    comptime N_FRAMES = 90

    var w = _fresh_world()
    var sc = Sched()
    var loop = FixedLoop.new(dt, 8)
    var ch = Channel[Evt]()

    var r_every = ch.register_reader()  # drains every frame: must never miss
    var r_after = ch.register_reader()  # reads AFTER this frame's writer
    var r_before = ch.register_reader()  # reads BEFORE this frame's writer

    var next_seq = 0
    var total_ticks = 0
    var got_every = 0
    var got_after = 0
    var got_before = 0

    for _ in range(N_FRAMES):
        # r_before runs BEFORE the writer this frame: can only see events
        # from strictly earlier frames (retained via the double buffer).
        var ob = List[Evt]()
        ch.read(r_before, ob)
        got_before += len(ob)

        # FixedLoop is the real driver: frame_dt == dt exactly, so this
        # always produces 1 fixed tick, matching test_gameloop.mojo's own
        # "accumulation across many calls of exactly DT -> one step each".
        var n = loop.advance(sc, w, dt)
        s.eqi(n, 1, "frame_dt == dt -> exactly 1 fixed tick this frame")
        for _ in range(n):
            ch.send(Evt(next_seq))
            next_seq += 1
            total_ticks += 1
        ch.update()

        # r_every and r_after both run AFTER the writer this frame: both
        # see this frame's event immediately.
        var oe = List[Evt]()
        ch.read(r_every, oe)
        got_every += len(oe)
        var oa = List[Evt]()
        ch.read(r_after, oa)
        got_after += len(oa)

    s.eqi(total_ticks, N_FRAMES, String(N_FRAMES) + " real frames of exactly dt -> that many fixed ticks")
    s.eqi(got_every, total_ticks, "reader draining every frame right after the writer misses nothing")
    s.eqi(got_after, total_ticks, "a reader running AFTER the writer catches every event the same frame")
    s.eqi(
        got_before, total_ticks - 1,
        "a reader running BEFORE the writer is exactly one frame behind (never caught up to the last send yet)",
    )

    # One more read, after the loop: r_before finally catches the LAST
    # frame's event too -- confirming nothing was actually dropped, only
    # delayed by exactly one read.
    var ob_final = List[Evt]()
    ch.read(r_before, ob_final)
    got_before += len(ob_final)
    s.eqi(
        got_before, total_ticks,
        "given one more read, the 'before the writer' reader eventually sees every event: zero actually dropped",
    )

    s.finish()
