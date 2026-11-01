"""venv/bin/python -I run64.py ludens64.wasm [ticks]  -- run the linked wasm64 C-ABI under wasmtime."""
import math, struct, sys, time
from wasmtime import Config, Engine, Store, Module, Linker, FuncType, ValType

import ctypes
_libm = ctypes.CDLL("libm.so.6")
for _n in ("sinf", "cosf"):
    getattr(_libm, _n).restype = ctypes.c_float; getattr(_libm, _n).argtypes = [ctypes.c_float]
cfg = Config()
cfg.wasm_memory64 = True
for attr in ("wasm_tail_call", "wasm_simd", "wasm_bulk_memory"):
    if hasattr(cfg, attr):
        setattr(cfg, attr, True)
engine = Engine(cfg)
store = Store(engine)
module = Module.from_file(engine, sys.argv[1])
print("imports", [(i.module, i.name) for i in module.imports])
linker = Linker(engine)
mem_ref = {}


def host_write(fd, p, n):
    sys.stderr.write(bytes(mem_ref["m"].read(store, p, p + n)).decode(errors="replace"))


f32 = lambda x: struct.unpack("f", struct.pack("f", x))[0]
PT = ValType.i32() if "32" in sys.argv[1] else ValType.i64()
linker.define_func("env", "host_write", FuncType([ValType.i32(), PT, ValType.i64()], []), host_write)
linker.define_func("env", "host_sinf", FuncType([ValType.f32()], [ValType.f32()]), (lambda x: _libm.sinf(x)) if __import__("os").environ.get("GLIBC_TRIG") else (lambda x: f32(math.sin(x))))
linker.define_func("env", "host_cosf", FuncType([ValType.f32()], [ValType.f32()]), (lambda x: _libm.cosf(x)) if __import__("os").environ.get("GLIBC_TRIG") else (lambda x: f32(math.cos(x))))
linker.define_func("env", "host_now_ns", FuncType([], [ValType.i64()]), lambda: time.monotonic_ns())
inst = linker.instantiate(store, module)
ex = inst.exports(store)
mem = ex["memory"]
mem_ref["m"] = mem
E = lambda n: ex[n]
rd = lambda p, n: bytes(mem.read(store, p, p + n))

v = E("ld_abi_version")(store)
print("abi", f"{v >> 16}.{v & 0xffff}")
pp = E("shim_alloc")(store, 16)
rc = E("ld_world_create")(store, 1 / 60, 0.0, -9.81, 0.0, pp)
w = struct.unpack("<Q", rd(pp, 8))[0] if "32" not in sys.argv[1] else struct.unpack("<I", rd(pp, 4))[0]
print("world_create rc", rc, "handle", hex(w))
ground = E("ld_body_add_box")(store, w, 0.0, -0.5, 0.0, 20.0, 0.5, 20.0, 0.0, 1)
ball = E("ld_body_add_sphere")(store, w, 0.0, 5.0, 0.0, 0.5, 1.0, 0)
boxes = [E("ld_body_add_box")(store, w, 2.0, 0.5 + i * 1.0, 0.0, 0.5, 0.5, 0.5, 1.0, 0) for i in range(10)] + [E("ld_body_add_sphere")(store, w, -8.0 + (k % 16) * 1.1, 1.0 + (k // 256) * 1.1, -8.0 + ((k // 16) % 16) * 1.1, 0.5, 1.0, 0) for k in range(int(__import__("os").environ.get("NB", "0")))]
print("bodies", E("ld_world_body_count")(store, w), "ground", ground, "ball", ball)
N = int(sys.argv[2]) if len(sys.argv) > 2 else 240
t0 = time.perf_counter()
rc = E("ld_world_step_ticks")(store, w, N)
dt = time.perf_counter() - t0
print("step_ticks rc", rc, "ticks", N, "ms/tick", f"{dt * 1e3 / N:.4f}")
out = E("shim_alloc")(store, 64)
for name, b in (("ball", ball), ("box9", boxes[9])):
    rc = E("ld_body_get_state")(store, w, b, out)
    raw = rd(out, 52)
    f = struct.unpack("<13f", raw)
    u = struct.unpack("<13I", raw)
    print(name, "rc", rc, "pos", ",".join(f"{x:.6f}" for x in f[:3]), "bits", " ".join(f"{x:x}" for x in u[:7]))
hp = E("shim_alloc")(store, 8)
rc = E("ld_world_hash")(store, w, hp)
print("hash rc", rc, f"{struct.unpack('<Q', rd(hp, 8))[0]:x}")
print("libm calls trig", E("shim_n_trig")(store), "fma", E("shim_n_fma")(store), "minmax", E("shim_n_minmax")(store))
print("live_bytes", E("shim_live_bytes")(store), "peak_bytes", E("shim_peak_bytes")(store),
      "heap_top", E("shim_heap_top")(store), "mem_pages", mem.size(store))
rc = E("ld_world_destroy")(store, w)
print("destroy rc", rc, "live_bytes_after", E("shim_live_bytes")(store))
