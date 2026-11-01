"""One entry for both targets (17.89 W5): the C-ABI plus the reference scene.

  pixi run wasm                       # wasm64 module; main is not called
  python3 -m ludens_wasm_rt.build_wasm --target native --lib . tools/wasm/ref_entry.mojo -I build -o ref

Native, `main` prints the two reference hashes the wasm gate compares against:
12 bodies x 240 ticks and 1012 bodies x 120 ticks (the scene of `world_hash.mjs`).
"""

from geometry.vec import Vec3
from embed.world import EmbedWorld
from embed.capi import ld_abi_version


def _scene(extra: Int, ticks: Int) raises -> UInt64:
    var w = EmbedWorld(1.0 / 60.0, Vec3(0, -9.81, 0, 0))
    _ = w.add_box(Vec3(0, -0.5, 0, 0), Vec3(20, 0.5, 20, 0), 0, True)
    _ = w.add_sphere(Vec3(0, 5, 0, 0), 0.5, 1, False)
    for i in range(10):
        _ = w.add_box(Vec3(Float32(2), Float32(0.5 + Float64(i)), 0, 0), Vec3(0.5, 0.5, 0.5, 0), 1, False)
    for k in range(extra):
        _ = w.add_sphere(
            Vec3(
                Float32(-8.0 + Float64(k % 16) * 1.1),
                Float32(1.0 + Float64(k // 256) * 1.1),
                Float32(-8.0 + Float64((k // 16) % 16) * 1.1),
                0,
            ),
            0.5,
            1,
            False,
        )
    for _ in range(ticks):
        w.physics_tick()
    return w.hash()


def main() raises:
    print("abi", ld_abi_version())
    print("hash12 ", hex(_scene(0, 240)))
    print("hash1012", hex(_scene(1000, 120)))
