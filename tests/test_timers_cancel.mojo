# tier: unit
"""Cancelling a pending timer must not leave a mark behind (audit finding, 2026-11): `canceled` is a lazy-deletion
set, and the entry it marked used to be skipped and dropped while the mark stayed forever, so a program that schedules
and cancels timers grew the Dict without bound. The fired sequence must not change (test_timers is the parity test)."""

from harness.runner import Suite
from scheduler.timers import TimerHeap, TimerWheel, TimerFire, TimerHandle

comptime N = 2000


def _heap(mut s: Suite) raises:
    var q = TimerHeap()
    var handles = List[TimerHandle]()
    for i in range(N):
        var h = q.schedule(10 + (i % 50), i)
        handles.append(h)
    for i in range(N):
        if i % 4 != 0:
            q.cancel(handles[i])
    s.eqi(len(q.canceled), N - N // 4, "heap: every cancel of a pending timer leaves a mark until its tick")
    var fired = List[TimerFire]()
    q.advance(100, fired)
    s.eqi(len(fired), N // 4, "heap: the uncancelled quarter fires")
    s.eqi(len(q.canceled), 0, "heap: after the cancelled entries were reached no mark is left")
    # a repeating timer cancelled while pending
    var r = q.schedule(5, 999, repeat_every=3)
    q.cancel(r)
    var again = List[TimerFire]()
    q.advance(50, again)
    s.eqi(len(again), 0, "heap: a cancelled repeating timer does not fire")
    s.eqi(len(q.canceled), 0, "heap: ...and leaves no mark")


def _wheel(mut s: Suite) raises:
    var q = TimerWheel()
    var handles = List[TimerHandle]()
    for i in range(N):
        var h = q.schedule(10 + (i % 50), i)
        handles.append(h)
    # far entries (beyond the near ring) take the cascade path
    for i in range(200):
        var h = q.schedule(1000 + i * 7, 10000 + i)
        handles.append(h)
    for i in range(len(handles)):
        if i % 4 != 0:
            q.cancel(handles[i])
    var marked = len(q.canceled)
    s.check(marked > 0, "wheel: cancels are marked")
    var fired = List[TimerFire]()
    q.advance(3000, fired)
    s.eqi(len(fired), len(handles) // 4, "wheel: the uncancelled quarter fires")
    s.eqi(len(q.canceled), 0, "wheel: after the cancelled entries were reached (near and far ring) no mark is left")


def main() raises:
    var s = Suite("timers_cancel")
    _heap(s)
    _wheel(s)
    s.finish()
