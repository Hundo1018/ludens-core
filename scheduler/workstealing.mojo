"""A work-stealing task pool, as an alternative to static fan-out.

`max.algorithm.parallelize` partitions `[0, n)` into contiguous blocks, one per
worker, decided before any task runs. That is optimal when every task costs the
same and pathological when they do not: a worker that draws the expensive tasks
keeps running while the others sit at the barrier, and the round takes as long
as the unluckiest block.

This pool keeps the same static split as a STARTING point but lets an idle
worker drain someone else's remainder:

  - worker `w` owns the index range `[lo_w, hi_w)` and claims from it with an
    atomic `fetch_add` on its own cursor;
  - when its own range is exhausted it scans the other workers and claims from
    THEIR cursors instead, continuing until every range is drained.

Because a claim is a single `fetch_add` and a task is executed only when the
returned index is still below that range's limit, every index in `[0, n)` is
handed out exactly once no matter how the steals interleave. That is the
correctness argument, and `test_workstealing` gates it directly (every task
runs exactly once, for a range of worker counts and cost distributions).

The cursors are spaced `_PAD` Int64s apart — one per 64-byte cache line. This
is not decoration: `bench_falseshare` measures up to ~11x for packed atomic
counters, and these cursors are hammered by every worker in the pool, so
packing them would hand back more than the stealing wins.

Ordering: tasks are claimed in a nondeterministic order, so a body that is not
order-independent must not use this pool. The solver's parallel regions
(disjoint islands, disjoint same-color pairs) are order-independent by
construction, which is what makes them eligible.
"""

from max.algorithm import parallelize
from .build_opts import SERIAL_ONLY
from std.atomic import Atomic

comptime _PAD = 8  # Int64s per 64-byte cache line (see bench_falseshare)


def ws_parallel_for[
    BodyT: def (Int) -> None
](body: BodyT, n: Int, workers: Int):
    """Run `body(i)` for every `i` in `[0, n)` across `workers` threads, with
    idle workers stealing from ranges that are not drained yet."""
    if n <= 0:
        return
    var w = workers if workers > 0 else 1
    if w > n:
        w = n
    if w <= 1:
        for i in range(n):
            body(i)
        return

    # cursors[k*_PAD] = next unclaimed index of range k; limits[k] = its end
    var cursors = List[Int64]()
    for _ in range(w * _PAD):
        cursors.append(0)
    var limits = List[Int]()
    var base = n // w
    var extra = n % w
    var at = 0
    for k in range(w):
        var take = base + (1 if k < extra else 0)
        cursors[k * _PAD] = Int64(at)
        limits.append(at + take)
        at += take
    var cp = cursors.unsafe_ptr()

    def worker(me: Int) {imm body, imm cp, imm limits, imm w}:
        # 1. drain own range
        while True:
            var i = Int(Atomic.fetch_add(cp.unsafe_offset(me * _PAD), Int64(1)))
            if i >= limits[me]:
                break
            body(i)
        # 2. steal: sweep the others until nothing is left anywhere. The
        #    outer loop repeats because a range can still be non-empty when
        #    first probed and drained by the time the sweep comes back.
        while True:
            var stole = False
            for off in range(1, w):
                var v = (me + off) % w
                while True:
                    var i = Int(Atomic.fetch_add(cp.unsafe_offset(v * _PAD), Int64(1)))
                    if i >= limits[v]:
                        break
                    body(i)
                    stole = True
            if not stole:
                break

    comptime if SERIAL_ONLY:
        for t in range(w):
            worker(t)
    else:
        parallelize(worker, w, w)
