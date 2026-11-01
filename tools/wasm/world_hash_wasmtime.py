"""The world_hash.mjs scene on wasmtime (memory64) through ludens-wasm-rt's wasmtime host (17.89 / #75).

    pixi run --manifest-path ../ludens-wasm-rt/pixi.toml python tools/wasm/world_hash_wasmtime.py build/ludens64.wasm [ticks=240] [NB=0]
"""
import os
import struct
import sys
from pathlib import Path

rt_root = Path(os.environ.get("LUDENS_WASM_RT", Path(__file__).resolve().parents[3] / "ludens-wasm-rt"))
sys.path.insert(0, str(rt_root / "tests"))
from wasmtime_host import Rt  # noqa: E402

rt = Rt(Path(sys.argv[1]))
ticks = int(sys.argv[2]) if len(sys.argv) > 2 else 240
nb = int(sys.argv[3]) if len(sys.argv) > 3 else 0
pp = rt.alloc(16, 8)
rc = rt.call("ld_world_create", 1.0 / 60.0, 0.0, -9.81, 0.0, pp)
assert rc == 0, rc
w = struct.unpack("<Q", rt.read(pp, 8))[0]
rt.call("ld_body_add_box", w, 0.0, -0.5, 0.0, 20.0, 0.5, 20.0, 0.0, 1)
rt.call("ld_body_add_sphere", w, 0.0, 5.0, 0.0, 0.5, 1.0, 0)
for i in range(10):
    rt.call("ld_body_add_box", w, 2.0, 0.5 + i * 1.0, 0.0, 0.5, 0.5, 0.5, 1.0, 0)
for k in range(nb):
    rt.call("ld_body_add_sphere", w, -8 + (k % 16) * 1.1, 1 + (k // 256) * 1.1, -8 + ((k // 16) % 16) * 1.1, 0.5, 1.0, 0)
rc = rt.call("ld_world_step_ticks", w, ticks)
hp = rt.alloc(8, 8)
rt.call("ld_world_hash", w, hp)
print(f"bodies {12 + nb} ticks {ticks} rc {rc}")
print("hash", format(struct.unpack("<Q", rt.read(hp, 8))[0], "016x"))
rt.call("ld_world_destroy", w)
