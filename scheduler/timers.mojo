"""Deterministic tick-based timers: schedule, cancel, advance.

Timers tick on the FIXED simulation step (`scheduler.gameloop.FixedLoop`
drives `advance` once per whole `dt`, exactly like a `Scheduler`), never wall
clock, so a recorded sequence of `schedule`/`cancel`/`advance` calls replays
bit-for-bit -- the property 17.39 replay and 17.16 rollback both need.

`TimerQueue` is the swap seam:

  `TimerHeap`   textbook array-based binary min-heap keyed by
                `(due_tick, schedule sequence)`. O(log N) schedule/cancel,
                O(log N) per fired timer.
  `TimerWheel`  a two-level ring buffer (Netty `HashedWheelTimer` shape): a
                near ring with one slot per tick for the next 256 ticks, and
                a far ring with one slot per 256-tick epoch out to 65536
                ticks, cascaded into the near ring as each epoch starts.
                O(1) schedule (append to one bucket), O(1) + O(bucket size)
                per advanced tick -- no per-timer O(log N) work. This is
                where it wins: N active timers clustered near their due tick,
                which is the common gameplay shape (cooldowns, short delays).
                A timer due farther than the 65536-tick horizon lands in
                whatever far-ring slot its due tick aliases to and gets
                re-filed (still O(1)) every time that slot's cycle comes
                back around, until it is finally near enough to place
                exactly -- the single-level wheel's classic tradeoff, just
                256x rarer here. A third ring would remove it; not built,
                since nothing in this file schedules that far out.
                See `bench_timers.mojo` for the measured crossover N.

Determinism contract: `advance` returns newly-fired timers in
`(due_tick, schedule_sequence)` order -- total and a function only of the
script of calls, not of which `TimerQueue` produced them or of either
structure's internal bucket/heap order. `test_timers` checks this with a
seeded randomized schedule/cancel/advance script run through both backends
in lock-step.

Firing semantics: `schedule(after_ticks, id)` computes
`due_tick = current_tick + after_ticks`, clamped up to at least
`current_tick + 1` (see `_due_after`) -- so `after_ticks = 0` means "due on
the very next `advance` step", not "already due", which would place it in
the past relative to every future tick `advance` will ever produce. A
`repeat_every > 0` timer re-schedules itself for `due_tick + repeat_every`
immediately on firing, so it can fire more than once within a single
`advance(n_ticks)` call.
`cancel` is idempotent and silent on an already-fired or already-cancelled
handle -- the common gameplay race of dismissing something whose timer just
fired should not need to be guarded by the caller.

Capacity is not bounded (`List`/`Dict` growth, no fixed-size buffer) -- unlike
`diag`'s frame-budgeted containers, there is no natural fixed budget for
"how many gameplay timers can be live", so this module does not invent one;
the error-handling policy's "capacity/budget overflow -> diag counter" row
does not apply here for the same reason it does not apply to `ecs`'s sparse
entity index.
"""


@fieldwise_init
struct TimerHandle(Copyable, ImplicitlyCopyable, Movable, Writable):
    """Opaque timer identity -- the schedule sequence number. Sequence
    numbers are assigned once, monotonically, and never reused, so (unlike
    `ecs.entity.Entity`) no generation counter is needed to detect a stale
    handle: a cancelled or fired one-shot timer's `seq` simply never matches
    a live timer again."""

    var seq: Int

    def __eq__(self, other: Self) -> Bool:
        return self.seq == other.seq

    def __ne__(self, other: Self) -> Bool:
        return not (self == other)

    def write_to[W: Writer](self, mut w: W):
        w.write("TimerHandle(", self.seq, ")")


@fieldwise_init
struct TimerFire(Copyable, ImplicitlyCopyable, Movable):
    """One firing event: `handle` identifies the timer, `id` is the caller's
    own opaque tag (an event id, an entity id, whatever the caller needs to
    dispatch on -- this module never interprets it), `due_tick` is the tick
    it fired on."""

    var handle: TimerHandle
    var id: Int
    var due_tick: Int


trait TimerQueue(Movable, Deinitable, Defaultable):
    """The swap seam. Every implementation must produce identical
    `(due_tick, seq)`-ordered `fired` sequences for the same script of
    `schedule`/`cancel`/`advance` calls -- `test_timers`' parity check."""

    def current_tick(self) -> Int: ...
    def schedule(
        mut self, after_ticks: Int, id: Int, repeat_every: Int = 0
    ) raises -> TimerHandle: ...
    def cancel(mut self, handle: TimerHandle): ...
    def advance(mut self, n_ticks: Int, mut fired: List[TimerFire]) raises: ...


def _cmp_fire(a: TimerFire, b: TimerFire) -> Bool:
    """Total order for the determinism contract: `(due_tick, seq)`."""
    if a.due_tick != b.due_tick:
        return a.due_tick < b.due_tick
    return a.handle.seq < b.handle.seq


def _due_after(tick: Int, after_ticks: Int) -> Int:
    """`due_tick` for a fresh `schedule(after_ticks, ...)` call made while the
    clock reads `tick`. Clamped to `tick + 1` minimum (not `tick`): `advance`
    only ever checks a timer against a clock value it steps FORWARD to, so a
    `due_tick` equal to the CURRENT tick would never be visited again until
    it happened to recur (the wheel's ring addresses buckets by `due_tick`,
    not by a live `<=` scan) -- `after_ticks = 0` means "due on the very next
    tick", which this makes literally true by construction instead of
    relying on each `TimerQueue` to special-case an already-due entry."""
    var due = tick + after_ticks
    if due <= tick:
        due = tick + 1
    return due


# =====================================================================
# TimerHeap -- array-based binary min-heap
# =====================================================================


@fieldwise_init
struct _HeapEntry(Copyable, ImplicitlyCopyable, Movable):
    var due_tick: Int
    var seq: Int
    var id: Int
    var repeat_every: Int


def _heap_less(a: _HeapEntry, b: _HeapEntry) -> Bool:
    if a.due_tick != b.due_tick:
        return a.due_tick < b.due_tick
    return a.seq < b.seq


struct TimerHeap(TimerQueue):
    """Reference implementation. `canceled` is a lazy-deletion set: removing
    an arbitrary element from an array heap without tracking its position
    would be O(N); marking it and skipping on pop is O(1) at cancel time and
    costs nothing extra at pop time (the pop already visits the entry)."""

    var entries: List[_HeapEntry]
    var canceled: Dict[Int, Bool]
    var next_seq: Int
    var tick: Int

    def current_tick(self) -> Int:
        return self.tick

    def _swap(mut self, i: Int, j: Int):
        var tmp = self.entries[i]
        self.entries[i] = self.entries[j]
        self.entries[j] = tmp

    def _sift_up(mut self, i0: Int):
        var i = i0
        while i > 0:
            var p = (i - 1) // 2
            if _heap_less(self.entries[i], self.entries[p]):
                self._swap(i, p)
                i = p
            else:
                break

    def _sift_down(mut self, i0: Int):
        var i = i0
        var n = len(self.entries)
        while True:
            var l = 2 * i + 1
            var r = 2 * i + 2
            var smallest = i
            if l < n and _heap_less(self.entries[l], self.entries[smallest]):
                smallest = l
            if r < n and _heap_less(self.entries[r], self.entries[smallest]):
                smallest = r
            if smallest == i:
                break
            self._swap(i, smallest)
            i = smallest

    def _push(mut self, e: _HeapEntry):
        self.entries.append(e)
        self._sift_up(len(self.entries) - 1)

    def _pop(mut self) -> _HeapEntry:
        var top = self.entries[0]
        var last = len(self.entries) - 1
        self.entries[0] = self.entries[last]
        _ = self.entries.pop()
        if len(self.entries) > 0:
            self._sift_down(0)
        return top

    def schedule(
        mut self, after_ticks: Int, id: Int, repeat_every: Int = 0
    ) raises -> TimerHandle:
        if after_ticks < 0:
            raise Error("TimerHeap.schedule: after_ticks must be >= 0")
        if repeat_every < 0:
            raise Error("TimerHeap.schedule: repeat_every must be >= 0")
        var seq = self.next_seq
        self.next_seq += 1
        self._push(
            _HeapEntry(_due_after(self.tick, after_ticks), seq, id, repeat_every)
        )
        return TimerHandle(seq)

    def cancel(mut self, handle: TimerHandle):
        """Mark the timer; its entry is dropped, and the mark with it, when `advance` reaches it. Cancelling a handle
        that has already fired (a one-shot) or was already dropped leaves a mark that nothing removes: one Dict entry
        per such call."""
        self.canceled[handle.seq] = True

    def advance(mut self, n_ticks: Int, mut fired: List[TimerFire]) raises:
        if n_ticks < 0:
            raise Error("TimerHeap.advance: n_ticks must be >= 0")
        var batch = List[TimerFire]()
        for _ in range(n_ticks):
            self.tick += 1
            while len(self.entries) > 0 and self.entries[0].due_tick <= self.tick:
                var e = self._pop()
                if e.seq in self.canceled:
                    # the entry is gone for good (a repeating one is not pushed again), so its mark can go too
                    _ = self.canceled.pop(e.seq, False)
                    continue
                batch.append(TimerFire(TimerHandle(e.seq), e.id, self.tick))
                if e.repeat_every > 0:
                    self._push(
                        _HeapEntry(
                            e.due_tick + e.repeat_every, e.seq, e.id, e.repeat_every
                        )
                    )
        sort(batch, _cmp_fire)
        for e in batch:
            fired.append(e)


# =====================================================================
# TimerWheel -- two-level hierarchical ring buffer
# =====================================================================

comptime _L0_BITS: Int = 8
comptime _L0_SIZE: Int = 1 << _L0_BITS  # 256 -- near ring, one slot/tick
comptime _L0_MASK: Int = _L0_SIZE - 1
comptime _L1_BITS: Int = 8
comptime _L1_SIZE: Int = 1 << _L1_BITS  # 256 -- far ring, one slot/256 ticks
comptime _L1_MASK: Int = _L1_SIZE - 1


@fieldwise_init
struct _WheelEntry(Copyable, ImplicitlyCopyable, Movable):
    var due_tick: Int
    var seq: Int
    var id: Int
    var repeat_every: Int


struct TimerWheel(TimerQueue):
    """Two-level ring. `_insert` files an entry into the near ring if it is
    due within the next `_L0_SIZE` ticks, otherwise into the far ring's
    epoch bucket; `_cascade` empties one far-ring bucket into the near ring
    exactly when that epoch starts. Module docstring has the horizon and the
    aliasing tradeoff beyond it."""

    var l0: List[List[_WheelEntry]]
    var l1: List[List[_WheelEntry]]
    var canceled: Dict[Int, Bool]
    var next_seq: Int
    var tick: Int

    def __init__(out self):
        self.l0 = List[List[_WheelEntry]](capacity=_L0_SIZE)
        for _ in range(_L0_SIZE):
            self.l0.append(List[_WheelEntry]())
        self.l1 = List[List[_WheelEntry]](capacity=_L1_SIZE)
        for _ in range(_L1_SIZE):
            self.l1.append(List[_WheelEntry]())
        self.canceled = Dict[Int, Bool]()
        self.next_seq = 0
        self.tick = 0

    def current_tick(self) -> Int:
        return self.tick

    def _insert(mut self, e: _WheelEntry):
        var delta = e.due_tick - self.tick
        if delta < _L0_SIZE:
            self.l0[e.due_tick & _L0_MASK].append(e)
        else:
            var epoch = e.due_tick >> _L0_BITS
            self.l1[epoch & _L1_MASK].append(e)

    def schedule(
        mut self, after_ticks: Int, id: Int, repeat_every: Int = 0
    ) raises -> TimerHandle:
        if after_ticks < 0:
            raise Error("TimerWheel.schedule: after_ticks must be >= 0")
        if repeat_every < 0:
            raise Error("TimerWheel.schedule: repeat_every must be >= 0")
        var seq = self.next_seq
        self.next_seq += 1
        self._insert(
            _WheelEntry(_due_after(self.tick, after_ticks), seq, id, repeat_every)
        )
        return TimerHandle(seq)

    def cancel(mut self, handle: TimerHandle):
        """Mark the timer; its entry is dropped, and the mark with it, when `advance` reaches it. Cancelling a handle
        that has already fired (a one-shot) or was already dropped leaves a mark that nothing removes: one Dict entry
        per such call."""
        self.canceled[handle.seq] = True

    def _cascade(mut self, t: Int):
        """Empty the far-ring bucket for the epoch that starts at tick `t`
        into the near ring. Entries whose true due tick is much farther out
        than this epoch (aliased into this bucket, see module docstring)
        simply route back into the far ring via `_insert`."""
        var idx1 = (t >> _L0_BITS) & _L1_MASK
        var bucket = self.l1[idx1].copy()
        self.l1[idx1] = List[_WheelEntry]()
        for i in range(len(bucket)):
            var e = bucket[i]
            if e.seq in self.canceled:
                _ = self.canceled.pop(e.seq, False)  # dropped for good: the mark can go
                continue
            self._insert(e)

    def advance(mut self, n_ticks: Int, mut fired: List[TimerFire]) raises:
        if n_ticks < 0:
            raise Error("TimerWheel.advance: n_ticks must be >= 0")
        var batch = List[TimerFire]()
        for _ in range(n_ticks):
            self.tick += 1
            if self.tick & _L0_MASK == 0:
                self._cascade(self.tick)
            var idx0 = self.tick & _L0_MASK
            var bucket = self.l0[idx0].copy()
            self.l0[idx0] = List[_WheelEntry]()
            for i in range(len(bucket)):
                var e = bucket[i]
                if e.seq in self.canceled:
                    _ = self.canceled.pop(e.seq, False)  # dropped for good: the mark can go
                    continue
                if e.due_tick == self.tick:
                    batch.append(TimerFire(TimerHandle(e.seq), e.id, self.tick))
                    if e.repeat_every > 0:
                        self._insert(
                            _WheelEntry(
                                e.due_tick + e.repeat_every,
                                e.seq,
                                e.id,
                                e.repeat_every,
                            )
                        )
                else:
                    self._insert(e)
        sort(batch, _cmp_fire)
        for e in batch:
            fired.append(e)
