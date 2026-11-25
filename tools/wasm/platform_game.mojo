"""A tiny "game" wasm64 module for the wasm platform probe (scripts/wasm_probe_platform.py).

It imports no engine package: every engine function is an `env` import resolved at instantiation
against the engine module's exports (tools/wasm/platform_entry.mojo built as wasm64). The two modules
have separate memories, so only scalars cross: the world handle and body handles (opaque i64), floats.

  game_run(ticks)  100 spheres; each tick set one velocity, step, read 100 positions; returns a hash
                   (must equal the engine's in-process `pp_game_run`)
  game_calls(n)    n calls of the trivial import `pp_noop`, each on the loop's dependency chain
  game_spin(n)     the same loop with the call's `x + 1` inlined (subtracted)
"""

from std.ffi import external_call
from std.memory import bitcast

comptime GAME_BODIES = 100
# The probe's one-line edit for the rebuild timing changes this constant (game_spin's seed).
comptime EDIT_STAMP = 0


def _fold(h: UInt64, x: Float32) -> UInt64:
    return (h ^ UInt64(bitcast[DType.uint32, 1](x))) * 0x100000001B3


@export
def game_run(ticks: Int32) abi("C") -> UInt64:
    var w = external_call["pp_world_new", UInt64]()
    _ = external_call["ld_body_add_box", Int64](w, Float32(0), Float32(-0.5), Float32(0), Float32(20), Float32(0.5), Float32(20), Float32(0), Int32(1))
    var ids = List[Int64]()
    for k in range(GAME_BODIES):
        ids.append(
            external_call["ld_body_add_sphere", Int64](
                w, Float32(-5.0 + Float64(k % 10) * 1.1), Float32(1.0 + Float64(k // 10) * 1.1), Float32(0), Float32(0.5), Float32(1), Int32(0)
            )
        )
    var h = UInt64(0xCBF29CE484222325)
    for t in range(Int(ticks)):
        var b = ids[t % GAME_BODIES]
        _ = external_call["ld_body_set_velocity", Int32](
            w, b, Float32(Float64(t % 7) - 3.0), Float32(2), Float32(0), Float32(0), Float32(0), Float32(0)
        )
        _ = external_call["ld_world_step_ticks", Int32](w, Int32(1))
        for k in range(GAME_BODIES):
            for a in range(3):
                h = _fold(h, external_call["pp_body_pos", Float32](w, ids[k], Int32(a)))
    h ^= external_call["pp_world_hash", UInt64](w)
    _ = external_call["pp_world_free", Int32](w)
    return h


@export
def game_calls(n: Int64) abi("C") -> Int64:
    var acc = Int64(1)
    for _ in range(Int(n)):
        acc = external_call["pp_noop", Int64](acc) ^ (acc >> 3)
    return acc


@export
def game_spin(n: Int64) abi("C") -> Int64:
    var acc = Int64(1 + EDIT_STAMP)
    for _ in range(Int(n)):
        acc = (acc + 1) ^ (acc >> 3)
    return acc
