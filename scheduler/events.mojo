"""Gameplay event bus (ROADMAP 17.38): decoupled many-to-many delivery of
typed events (`OnPlayerDied`, contact began/ended, joint broke, ...) with a
DETERMINISTIC delivery order -- the property 17.39 (input replay) and 17.16
(rollback) both need: replaying the same sequence of `send()` calls must
reproduce bit-identical per-reader event streams.

`EventChannel` is the swap seam. `Channel[E]` is the production
implementation: a PULL model (readers keep a cursor and drain on their own
schedule, Bevy `EventReader` style) rather than a PUSH model that fans a copy
out to every subscriber at `send()` time. Pull is the Mojo-natural choice
here -- push delivery to a heterogeneous set of subscribers normally wants
boxed/type-erased callbacks, which this toolchain has no cheap way to do
(`ecs/reactive_backend.mojo`'s push observers get away with it because every
subscriber is filtered by the SAME `ObsEvent` shape; a gameplay event bus
carries arbitrary `E`, one `Channel[E]` per event type, so there is no shared
inbox type to erase into). `PushChannel[E]` is kept anyway, as the seam's
comparison partner (architecture law v2: every seam variant needs a parity
test AND a benchmark row) -- it mirrors `scheduler/message.mojo`'s mailbox
style (fan a copy out to every registered subscriber's own `List` at send
time) and is not meant to be the production choice.

DOUBLE BUFFER / RETENTION: an event sent during `update()`-period N is
visible through period N+1, then dropped -- "events live for two update()
calls" in the roadmap note. Concretely `Channel[E]` keeps `cur` (this
period's sends) and `prev` (last period's, about to age out), plus a global
monotonic `next_seq` used both as delivery order AND as each reader's cursor
position. This is what makes "a reader running before or after the writer in
a frame" (relative to when `update()` is called) still see every event
exactly once: whichever of `cur`/`prev` it lands in, a fresh reader's cursor
selects "everything at or after `cursor`", not a physical buffer index.

DETERMINISM: `next_seq` only ever increments by the order `send()` is
CALLED, single-threaded, with no other source of nondeterminism -- so two
runs that call `send()` in the same order produce identical sequence numbers
and therefore identical `read()` results for every reader (`test_events.mojo`
checks this directly by running the same send script twice).

CAPACITY / UNREAD DROPS (`docs/ARCHITECTURE.md` §2, "capacity / budget
overflow" row): `Channel[E]` counts, in `dropped_unread`, every event that
ages out of `prev` while some reader's cursor was still behind it (the
"reader that never reads" extreme case) -- local field first, matching the
existing `LogRing`/`DrawQueue`/`TraceBuffer` convention of a self-contained
`dropped: Int` (see `diag/log.mojo`'s docstring for why: a container should
stay unit-testable without a live `Counters` bank in scope). `sync_counters`
then folds that local tally into a shared `diag.counters.Counters` bank
(`EVENT_DROPPED_UNREAD`) and resets it, so repeated calls don't double-count
-- the owning world/gameloop calls it once a frame, same as the general
"drop the thing that didn't fit, count it, never silently lose the count"
rule. `PushChannel[E]` has no such counter: nothing is ever dropped on that
side (an unread subscriber inbox just grows), which is exactly why pull is
the chosen production model -- documented, not silently absent.

Wiring the `collision.contact_events.ContactEvent` producer onto a channel
lives OUTSIDE this file: `collision` is layer 3, the same layer as
`scheduler` (docs/ARCHITECTURE.md §1), so `scheduler/events.mojo` cannot
import it without a same-layer edge, which the reach-through/cycle rules
forbid. The small adapter that calls `ch.send(...)` for each
`ContactScene6.events` entry lives in the `gameplay` package (layer 5),
which may import both `scheduler` and `collision`: `gameplay/runtime.mojo`'s
`Runtime` forwards `scene.events` onto its `events` channel every fixed
tick. Before `gameplay` existed, `tests/test_events_contacts.mojo`'s
`publish_contact_events` was the only production-style caller architecture
law v3 requires ("接上專案"); it remains as the test of that adapter shape.
"""

from diag.counters import Counters, EVENT_DROPPED_UNREAD

comptime EventPayload = Copyable & Deinitable
"""The bound every event type must satisfy: cheap to copy (a reader drains
its own copy without disturbing other readers/the buffer) and destructible.
Nothing about gameplay semantics belongs here -- `E` can be any POD-ish event
struct, including `collision.contact_events.ContactEvent` unchanged."""


trait EventChannel(Movable, Deinitable, Defaultable):
    """The pull/push seam. `Payload` is an associated type (traits in this
    toolchain cannot themselves take bracket parameters -- confirmed by
    probe: `trait EventChannel[E: EventPayload]` is a parse error, "trait
    declarations do not support parameters" -- so the event type rides on
    the CONFORMING STRUCT's own bracket parameter instead, mirroring how
    `BroadPhase.dim` is an associated `comptime Int` rather than a trait
    parameter). Bound to `EventPayload`, not `Copyable` alone, so every
    conformer can hold its buffered events in a plain `List`."""

    comptime Payload: EventPayload

    def send(mut self, var e: Self.Payload):
        """Publish one event. Delivery order is CALL order -- the sequence
        number (pull) / fan-out order (push) IS the order every reader sees
        it in, which is what makes replay deterministic."""
        ...

    def register_reader(mut self) -> Int:
        """A fresh reader handle.

        Sees only events sent AFTER this call -- true on both sides of the
        seam: pull starts the cursor at "now" (`next_seq`), push starts with
        an empty, newly-appended inbox that earlier `send()` fan-outs never
        touched. (Extreme case: "reader registered mid-frame".)"""
        ...

    def read(mut self, reader: Int, mut out: List[Self.Payload]) raises:
        """Append this reader's undelivered events, in send order, to `out`,
        then advance its position so they are not redelivered. Raises on an
        unknown handle (`docs/ARCHITECTURE.md` §2: invalid caller input at a
        public API is the caller's problem, not a `debug_assert`)."""
        ...

    def update(mut self):
        """Advance one frame boundary. Pull: recycles the double buffer
        (anything not read within two `update()` calls is gone, counted).
        Push: a no-op -- delivery already happened at `send()` time, there is
        no buffer to age out."""
        ...


@fieldwise_init
struct _Seq[E: EventPayload](Movable, Deinitable):
    """One buffered event plus the global sequence number it was sent with
    -- the sole source of delivery order and of cursor comparisons."""

    var seq: Int64
    var value: Self.E


struct Channel[E: EventPayload](EventChannel):
    """Pull channel: shared double buffer (`cur`/`prev`) + one cursor per
    registered reader. `send` is O(1); `read` is O(events since the reader's
    cursor) -- the cost the roadmap note calls "pull costs cursor checks",
    against push's "costs copies ∝ readers"."""

    comptime Payload: EventPayload = Self.E

    var cur: List[_Seq[Self.E]]
    var prev: List[_Seq[Self.E]]
    var next_seq: Int64
    var cursors: List[Int64]
    var dropped_unread: Int64
    """Local tally, `LogRing`-style (see module docstring). Folded into a
    shared `diag.counters.Counters` bank by `sync_counters`."""

    def send(mut self, var e: Self.E):
        self.cur.append(_Seq[Self.E](self.next_seq, e^))
        self.next_seq += 1

    def register_reader(mut self) -> Int:
        self.cursors.append(self.next_seq)
        return len(self.cursors) - 1

    def read(mut self, reader: Int, mut out: List[Self.E]) raises:
        if reader < 0 or reader >= len(self.cursors):
            raise Error("Channel.read: unknown reader handle " + String(reader))
        var cursor = self.cursors[reader]
        # `prev` then `cur`: both are already internally in send order, and
        # every seq in `prev` is smaller than every seq in `cur` (buffers
        # rotate at `update()`), so concatenating them is already sorted --
        # no separate sort step needed for determinism.
        for i in range(len(self.prev)):
            if self.prev[i].seq >= cursor:
                out.append(self.prev[i].value.copy())
        for i in range(len(self.cur)):
            if self.cur[i].seq >= cursor:
                out.append(self.cur[i].value.copy())
        self.cursors[reader] = self.next_seq

    def update(mut self):
        # `prev` has already lived through one full period (it was `cur`
        # last time `update()` ran) -- this is its second and last chance to
        # be read. Anything a reader's cursor hasn't reached yet is about to
        # be gone for good, so it is counted here, once, before the purge.
        for i in range(len(self.prev)):
            for r in range(len(self.cursors)):
                if self.cursors[r] <= self.prev[i].seq:
                    self.dropped_unread += 1
        self.prev = self.cur^
        self.cur = List[_Seq[Self.E]]()

    def sync_counters(mut self, mut counters: Counters):
        """Fold `dropped_unread` into a shared `diag` bank and reset the
        local tally so a periodic call (once per frame, from whoever owns
        both the channel and the counters) never double-counts."""
        counters.incr(EVENT_DROPPED_UNREAD, self.dropped_unread)
        self.dropped_unread = 0


struct PushChannel[E: EventPayload](EventChannel):
    """Push channel: `send` fans a COPY out to every already-registered
    subscriber's own inbox immediately (`scheduler/message.mojo` mailbox
    style), so `read` is just draining that inbox. Cost moves from `read`
    (pull) to `send` (push, O(readers) copies per event) -- the comparison
    partner `benchmarks/bench_events.mojo` sweeps against `Channel[E]`.
    Deliberately has no drop counter: an inbox nobody drains just grows,
    which is exactly the operational reason `Channel[E]` (pull) is the
    production channel and this is not."""

    comptime Payload: EventPayload = Self.E

    var inboxes: List[List[Self.E]]

    def send(mut self, var e: Self.E):
        if len(self.inboxes) == 0:
            return
        for i in range(len(self.inboxes) - 1):
            self.inboxes[i].append(e.copy())
        self.inboxes[len(self.inboxes) - 1].append(e^)

    def register_reader(mut self) -> Int:
        self.inboxes.append(List[Self.E]())
        return len(self.inboxes) - 1

    def read(mut self, reader: Int, mut out: List[Self.E]) raises:
        if reader < 0 or reader >= len(self.inboxes):
            raise Error("PushChannel.read: unknown reader handle " + String(reader))
        for i in range(len(self.inboxes[reader])):
            out.append(self.inboxes[reader][i].copy())
        self.inboxes[reader].clear()

    def update(mut self):
        pass  # delivery already happened at send() time; nothing ages out
