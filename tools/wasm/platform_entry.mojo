"""The engine side of the wasm platform probe (scripts/wasm_probe_platform.py).

One entry for both targets, built through ludens-wasm-rt with the wasm64 defines (`wasm.toml`):

  * native (`--target native`): `main` times the world_hash scenes (12 bodies x 240 ticks,
    1012 x 120) through the C-ABI and prints `scene <bodies> <ticks> <ms/tick> <hash>` per repeat,
    then the in-process game loop (`game <ticks> <ms/tick> <hash>`).
  * wasm64: the C-ABI functions the game module imports (`ld_*`) plus a few scalar helpers
    (`pp_*`): two wasm modules have separate memories, so everything that crosses between them is
    a scalar (world handle, body handle, one float), never a pointer.

`pp_game_run` is the game loop of tools/wasm/platform_game.mojo compiled into the engine module;
both must return the same hash.
"""

from std.memory import alloc, Layout, stack_allocation
from std.builtin.rebind import rebind
from std.time import perf_counter_ns
from std.memory import bitcast
from embed.capi import (
    Handle,
    HandlePtr,
    F32Ptr,
    U64Ptr,
    ld_world_create,
    ld_world_destroy,
    ld_world_hash,
    ld_world_step_ticks,
    ld_body_add_box,
    ld_body_add_sphere,
    ld_body_set_velocity,
    ld_body_get_state,
)

comptime GAME_BODIES = 100


@export
def pp_world_new() abi("C") -> Optional[Handle]:
    """A world with gravity, nothing in it; the handle as a scalar."""
    var slot = alloc[Handle](Layout[Handle](count=1)).unsafe_leak()
    if ld_world_create(1.0 / 60.0, 0, -9.81, 0, rebind[HandlePtr](slot)) != 0:
        return None
    var w: Optional[Handle] = slot[]
    slot.unsafe_free()
    return w


@export
def pp_world_hash(w: Optional[Handle]) abi("C") -> UInt64:
    var out = alloc[UInt64](Layout[UInt64](count=1)).unsafe_leak()
    out[] = 0
    _ = ld_world_hash(w, rebind[U64Ptr](out))
    var h = out[]
    out.unsafe_free()
    return h


@export
def pp_world_free(w: Optional[Handle]) abi("C") -> Int32:
    return ld_world_destroy(w)


@export
def pp_body_pos(w: Optional[Handle], b: Int64, axis: Int32) abi("C") -> Float32:
    """One coordinate of a body's position (axis 0..2): the scalar read a second module can use."""
    var buf = stack_allocation[13, Float32]()
    _ = ld_body_get_state(w, b, rebind[F32Ptr](buf))
    return buf[Int(axis)]


@no_inline
@export
def pp_noop(x: Int64) abi("C") -> Int64:
    """The trivial getter of the per-call cost loop."""
    return x + 1


def _scene(nb: Int) -> Optional[Handle]:
    """The world_hash.mjs / ref_entry scene: ground, ball, ten stacked boxes, nb extra spheres."""
    var w = pp_world_new()
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


# ---------------------------------------------------------------- the game loop, in-process
# Keep in step with tools/wasm/platform_game.mojo (the probe compares the two hashes).


def _fold(h: UInt64, x: Float32) -> UInt64:
    return (h ^ UInt64(bitcast[DType.uint32, 1](x))) * 0x100000001B3


@export
def pp_game_run(ticks: Int32) abi("C") -> UInt64:
    var w = pp_world_new()
    _ = ld_body_add_box(w, 0, -0.5, 0, 20, 0.5, 20, 0, 1)
    var ids = List[Int64]()
    for k in range(GAME_BODIES):
        ids.append(
            ld_body_add_sphere(w, Float32(-5.0 + Float64(k % 10) * 1.1), Float32(1.0 + Float64(k // 10) * 1.1), 0, 0.5, 1, 0)
        )
    var h = UInt64(0xCBF29CE484222325)
    for t in range(Int(ticks)):
        var b = ids[t % GAME_BODIES]
        _ = ld_body_set_velocity(w, b, Float32(Float64(t % 7) - 3.0), 2, 0, 0, 0, 0)
        _ = ld_world_step_ticks(w, 1)
        for k in range(GAME_BODIES):
            for a in range(3):
                h = _fold(h, pp_body_pos(w, ids[k], Int32(a)))
    h ^= pp_world_hash(w)
    _ = ld_world_destroy(w)
    return h


@export
def pp_calls_inproc(n: Int64) abi("C") -> Int64:
    """The cross-module call loop of platform_game.mojo, but calling pp_noop inside this module."""
    var acc = Int64(1)
    for _ in range(Int(n)):
        acc = pp_noop(acc) ^ (acc >> 3)
    return acc


def main() raises:
    var reps = 7
    for sc in range(2):
        var nb = 0 if sc == 0 else 1000
        var ticks = 240 if sc == 0 else 120
        for _ in range(reps):
            var w = _scene(nb)
            var t0 = perf_counter_ns()
            _ = ld_world_step_ticks(w, Int32(ticks))
            var dt = perf_counter_ns() - t0
            print("scene", 12 + nb, ticks, Float64(dt) / 1e6 / Float64(ticks), hex(pp_world_hash(w)))
            _ = ld_world_destroy(w)
    for _ in range(reps):
        var t0 = perf_counter_ns()
        var h = pp_game_run(240)
        var dt = perf_counter_ns() - t0
        print("game", 240, Float64(dt) / 1e6 / 240.0, hex(h))
