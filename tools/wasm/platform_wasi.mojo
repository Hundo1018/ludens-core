"""A self-timing scene driver for runtimes driven from their CLI (scripts/wasm_probe_platform.py --aot: Wasmer).

Built with `build_wasm --host wasi`: the clock and stdout go through WASI preview 1, so a CLI runtime that provides
WASI but no custom `env` imports can run it. `pw_bench(nb, ticks, reps)` builds the platform_entry.mojo scene
(ground, ball, ten stacked boxes, nb spheres) `reps` times and prints `scene <bodies> <ticks> <ms/tick> <hash>` per
repeat, like the native build's main.
"""

from std.memory import alloc, Layout
from std.builtin.rebind import rebind
from std.time import perf_counter_ns
from embed.capi import (
    Handle,
    HandlePtr,
    U64Ptr,
    ld_world_create,
    ld_world_destroy,
    ld_world_hash,
    ld_world_step_ticks,
    ld_body_add_box,
    ld_body_add_sphere,
)


def _scene(nb: Int) -> Optional[Handle]:
    var slot = alloc[Handle](Layout[Handle](count=1)).unsafe_leak()
    _ = ld_world_create(1.0 / 60.0, 0, -9.81, 0, rebind[HandlePtr](slot))
    var w: Optional[Handle] = slot[]
    slot.unsafe_free()
    _ = ld_body_add_box(w, 0, -0.5, 0, 20, 0.5, 20, 0, 1)
    _ = ld_body_add_sphere(w, 0, 5, 0, 0.5, 1, 0)
    for i in range(10):
        _ = ld_body_add_box(w, 2, Float32(0.5 + Float64(i) * 1.0), 0, 0.5, 0.5, 0.5, 1, 0)
    for k in range(nb):
        _ = ld_body_add_sphere(
            w,
            Float32(-8.0 + Float64(k % 16) * 1.1),
            Float32(1.0 + Float64(k // 256) * 1.1),
            Float32(-8.0 + Float64((k // 16) % 16) * 1.1),
            0.5,
            1,
            0,
        )
    return w


@export
def pw_bench(nb: Int32, ticks: Int32, reps: Int32) abi("C") -> Int32:
    for _ in range(Int(reps)):
        var w = _scene(Int(nb))
        var t0 = perf_counter_ns()
        _ = ld_world_step_ticks(w, ticks)
        var dt = perf_counter_ns() - t0
        var out = alloc[UInt64](Layout[UInt64](count=1)).unsafe_leak()
        out[] = 0
        _ = ld_world_hash(w, rebind[U64Ptr](out))
        print("scene", 12 + Int(nb), Int(ticks), Float64(dt) / 1e6 / Float64(ticks), hex(out[]))
        out.unsafe_free()
        _ = ld_world_destroy(w)
    return 0


def main():
    pass
