"""Injectable parallel-for (ROADMAP 17.75): who runs the engine's fan-outs.

The engine's parallel loops (island solves, same-colour contact pairs,
batched differentiable worlds) are written as `Task`s -- a struct whose
`run(i)` handles item `i` -- and handed to `dispatch_for` with a `Dispatch`
value saying who runs them:

| kind | runs `run(0..n)` |
|---|---|
| `DISPATCH_PARALLEL` (default) | `max.algorithm.parallelize` on the runtime's pool |
| `DISPATCH_SERIAL` | the calling thread, in order |
| `DISPATCH_REVERSE` | the calling thread, last to first (a test of order independence) |
| `DISPATCH_WORK_STEALING` | `scheduler.workstealing.ws_parallel_for`: static split, idle workers steal the rest |
| `DISPATCH_HOST` | a host function `host(ctx, n, task, data)` -- e.g. Godot's WorkerThreadPool or a Unity job -- which must call `task(data, i)` once for every i in [0, n) before returning, from any threads, in any order |

Contract for every fan-out site: items write disjoint state, so the result
does not depend on the dispatcher, the order, or the thread count (tested
bit-for-bit, `test_dispatch`). A host dispatcher may also run items inline
on the calling thread; `dispatch_for` does not hold any lock.

The host form crosses a C boundary: the task is passed as a thin C function
(`_task_trampoline[T]`, one per task type) plus a pointer to the task value,
which stays alive on the caller's stack for the duration of the call.
"""

from std.memory import alloc, Layout
from std.sys import num_physical_cores
from max.algorithm import parallelize
from .build_opts import SERIAL_ONLY
from .workstealing import ws_parallel_for

comptime Opaque = type_of(alloc[NoneType](Layout[NoneType](count=1)).unsafe_leak())
# void task(void* data, int64_t i)
comptime TaskFn = def(Opaque, Int64) thin abi("C") -> None
# void host_parallel_for(void* ctx, int64_t n, task_fn task, void* data)
comptime HostParallelFor = def(Optional[Opaque], Int64, TaskFn, Opaque) thin abi("C") -> None

comptime DISPATCH_PARALLEL = 0
comptime DISPATCH_SERIAL = 1
comptime DISPATCH_REVERSE = 2
comptime DISPATCH_HOST = 3
comptime DISPATCH_WORK_STEALING = 4


trait Task:
    def run(self, i: Int): ...


@fieldwise_init
struct Dispatch(Copyable, ImplicitlyCopyable, Movable):
    var kind: Int
    var host: Optional[HostParallelFor]
    var ctx: Optional[Opaque]

    @staticmethod
    def parallel() -> Self:
        return Self(DISPATCH_PARALLEL, None, None)

    @staticmethod
    def serial() -> Self:
        return Self(DISPATCH_SERIAL, None, None)

    @staticmethod
    def reverse() -> Self:
        return Self(DISPATCH_REVERSE, None, None)

    @staticmethod
    def work_stealing() -> Self:
        return Self(DISPATCH_WORK_STEALING, None, None)

    @staticmethod
    def from_host(host: HostParallelFor, ctx: Optional[Opaque]) -> Self:
        return Self(DISPATCH_HOST, host, ctx)


def _task_trampoline[T: Task](data: Opaque, i: Int64) abi("C"):
    data.unsafe_bitcast[T]()[].run(Int(i))


def dispatch_for[T: Task](d: Dispatch, mut task: T, n: Int, workers: Int = 0):
    """Run `task.run(i)` for every i in [0, n) with dispatcher `d`;
    `workers > 0` caps the width of `DISPATCH_PARALLEL`."""
    if n <= 0:
        return
    comptime if SERIAL_ONLY:
        if d.kind == DISPATCH_REVERSE:
            var i = n - 1
            while i >= 0:
                task.run(i)
                i -= 1
        elif d.kind == DISPATCH_HOST and d.host:
            var p = Pointer(to=task)
            d.host.value()(d.ctx, Int64(n), _task_trampoline[T], p.unsafe_bitcast[NoneType]().unsafe_origin_cast[MutUntrackedOrigin]())
        else:
            for i in range(n):
                task.run(i)
        return
    if d.kind == DISPATCH_SERIAL:
        for i in range(n):
            task.run(i)
    elif d.kind == DISPATCH_REVERSE:
        var i = n - 1
        while i >= 0:
            task.run(i)
            i -= 1
    elif d.kind == DISPATCH_HOST and d.host:
        var p = Pointer(to=task)
        d.host.value()(d.ctx, Int64(n), _task_trampoline[T], p.unsafe_bitcast[NoneType]().unsafe_origin_cast[MutUntrackedOrigin]())
    elif d.kind == DISPATCH_WORK_STEALING:
        def steal_work(i: Int) {imm task}:
            task.run(i)

        ws_parallel_for(steal_work, n, workers if workers > 0 else num_physical_cores())
    else:
        def work(i: Int) {imm task}:
            task.run(i)

        if workers > 0:
            parallelize(work, n, workers)
        else:
            parallelize(work, n)

