"""wasmtime-py side of the wasm platform probe (scripts/wasm_probe_platform.py).

Runs inside the ludens-wasm-rt pixi env (wasmtime-py with memory64). One JSON spec in, one JSON
result out:

    python tools/wasm/platform_wasmtime.py '{"mode": "scene", "wasm": "...", "nb": 1000, "ticks": 120,
                                            "reps": 7, "config": {...}}'
    python tools/wasm/platform_wasmtime.py '{"mode": "multi", "engine": "...", "game": "...", ...}'

`config` keys are wasmtime.Config attributes (`cranelift_opt_level`, `wasm_simd`, `memory_reservation`,
...) plus `cranelift_flags` ({name: value} for Config.cranelift_flag_set). Unknown attributes are an error.
"""

from __future__ import annotations

import importlib.metadata
import json
import math
import struct
import sys
import time

from wasmtime import Config, Engine, Func, FuncType, Linker, Module, Store, ValType

I32, I64, F32 = ValType.i32(), ValType.i64(), ValType.f32()


def _f32(x: float) -> float:
    return struct.unpack("f", struct.pack("f", x))[0]


def make_engine(cfg: dict) -> Engine:
    c = Config()
    c.wasm_memory64 = True
    for k, v in cfg.items():
        if k == "cranelift_flags":
            for name, val in v.items():
                c.cranelift_flag_set(name, str(val))
            continue
        if not hasattr(c, k):
            raise SystemExit(f"platform_wasmtime: wasmtime.Config has no attribute {k!r}")
        setattr(c, k, v)
    return Engine(c)


class Host:
    """The env.host_* imports of a ludens-wasm-rt module, counting calls."""

    def __init__(self, store: Store):
        self.store = store
        self.calls = {"host_write": 0, "host_now_ns": 0, "host_sinf": 0, "host_cosf": 0}
        self.out = bytearray()

    def funcs(self) -> dict:
        calls = self.calls

        def write(caller, fd, ptr, n):
            calls["host_write"] += 1

        def now():
            calls["host_now_ns"] += 1
            return time.monotonic_ns() & (2**63 - 1)

        def sinf(x):
            calls["host_sinf"] += 1
            return _f32(math.sin(x))

        def cosf(x):
            calls["host_cosf"] += 1
            return _f32(math.cos(x))

        return {
            "host_write": Func(self.store, FuncType([I32, I64, I64], []), write, access_caller=True),
            "host_now_ns": Func(self.store, FuncType([], [I64]), now),
            "host_sinf": Func(self.store, FuncType([F32], [F32]), sinf),
            "host_cosf": Func(self.store, FuncType([F32], [F32]), cosf),
        }


def instantiate(store: Store, module: Module, host: Host, extra: dict | None = None):
    linker = Linker(store.engine)
    funcs = host.funcs()
    for imp in module.imports:
        if imp.module == "env" and imp.name in funcs:
            linker.define(store, "env", imp.name, funcs[imp.name])
        elif extra is not None and imp.name in extra:
            linker.define(store, "env", imp.name, extra[imp.name])
        else:
            raise SystemExit(f"platform_wasmtime: unexpected import {imp.module}.{imp.name}")
    return linker.instantiate(store, module)


def scene(spec: dict) -> dict:
    engine = make_engine(spec.get("config", {}))
    data = open(spec["wasm"], "rb").read()
    t0 = time.perf_counter()
    module = Module(engine, data)
    compile_s = time.perf_counter() - t0
    blob = module.serialize()
    t0 = time.perf_counter()
    module = Module.deserialize(engine, blob)
    deserialize_s = time.perf_counter() - t0
    store = Store(engine)
    host = Host(store)
    t0 = time.perf_counter()
    inst = instantiate(store, module, host)
    inst_s = time.perf_counter() - t0
    ex = inst.exports(store)
    mem = ex["memory"]
    nb, ticks = spec["nb"], spec["ticks"]
    times, hashes = [], set()
    for _ in range(spec["reps"]):
        pp = ex["mw_alloc"](store, 16, 8)
        rc = ex["ld_world_create"](store, 1 / 60, 0.0, -9.81, 0.0, pp)
        assert rc == 0, rc
        w = struct.unpack("<Q", mem.read(store, pp, pp + 8))[0]
        ex["ld_body_add_box"](store, w, 0.0, -0.5, 0.0, 20.0, 0.5, 20.0, 0.0, 1)
        ex["ld_body_add_sphere"](store, w, 0.0, 5.0, 0.0, 0.5, 1.0, 0)
        for i in range(10):
            ex["ld_body_add_box"](store, w, 2.0, 0.5 + i * 1.0, 0.0, 0.5, 0.5, 0.5, 1.0, 0)
        for k in range(nb):
            ex["ld_body_add_sphere"](store, w, -8 + (k % 16) * 1.1, 1 + (k // 256) * 1.1, -8 + ((k // 16) % 16) * 1.1,
                                     0.5, 1.0, 0)
        before = dict(host.calls)
        t0 = time.perf_counter()
        rc = ex["ld_world_step_ticks"](store, w, ticks)
        times.append((time.perf_counter() - t0) * 1e3 / ticks)
        step_calls = {k: host.calls[k] - before[k] for k in host.calls}
        assert rc == ticks, rc
        hp = ex["mw_alloc"](store, 8, 8)
        ex["ld_world_hash"](store, w, hp)
        hashes.add(struct.unpack("<Q", mem.read(store, hp, hp + 8))[0])
        ex["ld_world_destroy"](store, w)
        ex["mw_free"](store, pp)
        ex["mw_free"](store, hp)
    return {"compile_s": compile_s, "deserialize_s": deserialize_s, "serialized_bytes": len(blob), "instantiate_s": inst_s, "ms_per_tick": times,
            "hash": [format(h, "016x") for h in sorted(hashes)], "host_calls_in_step": step_calls}


def multi(spec: dict) -> dict:
    """Engine + game module in one store. link = direct (the engine's exported Func is the game's import:
    wasm-to-wasm) or pycallback (a Python function, re-entering through its Caller, that calls the export).
    Also times game_calls with pp_noop as a pure Python function (pyhost: what a Python host import costs)."""
    engine = make_engine(spec.get("config", {}))
    store = Store(engine)
    t0 = time.perf_counter()
    emod = Module(engine, open(spec["engine"], "rb").read())
    t1 = time.perf_counter()
    gmod = Module(engine, open(spec["game"], "rb").read())
    t2 = time.perf_counter()
    einst = instantiate(store, emod, Host(store))
    eex = einst.exports(store)

    def link(mode: str):
        extra = {}
        for imp in gmod.imports:
            if imp.module != "env" or imp.name.startswith("host_"):
                continue
            f = eex[imp.name]
            if mode == "direct" or (mode == "pyhost" and imp.name != "pp_noop"):
                extra[imp.name] = f
            elif mode == "pyhost":
                extra[imp.name] = Func(store, f.type(store), lambda x: x + 1)
            else:
                extra[imp.name] = Func(store, f.type(store), lambda caller, *a, _f=f: _f(caller, *a), access_caller=True)
        t = time.perf_counter()
        inst = instantiate(store, gmod, Host(store), extra)
        return inst.exports(store), time.perf_counter() - t, sorted(extra)

    gex, inst_s, names = link(spec["link"])
    out = {"engine_compile_s": t1 - t0, "game_compile_s": t2 - t1, "game_instantiate_s": inst_s, "imports": names}
    ticks, reps = spec["ticks"], spec["reps"]

    def timed(fn, *a):
        t = time.perf_counter()
        r = fn(store, *a)
        return time.perf_counter() - t, r

    def loop_pair(ex, n):
        calls, spins = [], []
        for _ in range(reps + 1):
            calls.append(timed(ex["game_calls"], n)[0])
            spins.append(timed(ex["game_spin"], n)[0])
        return calls[1:], spins[1:]

    runs = [timed(gex["game_run"], ticks) for _ in range(reps + 1)]
    out["game_ms_per_tick"] = [r[0] * 1e3 / ticks for r in runs]
    out["game_hash"] = sorted({format(r[1] & 0xFFFFFFFFFFFFFFFF, "016x") for r in runs})
    n = spec["calls"] if spec["link"] == "direct" else spec["calls_slow"]
    out["n"] = n
    out["calls_s"], out["spin_s"] = loop_pair(gex, n)
    if spec.get("inproc"):
        out["inproc_calls_s"] = [timed(eex["pp_calls_inproc"], spec["calls"])[0] for _ in range(reps + 1)][1:]
        out["inproc_n"] = spec["calls"]
        runs = [timed(eex["pp_game_run"], ticks) for _ in range(reps + 1)]
        out["inproc_ms_per_tick"] = [r[0] * 1e3 / ticks for r in runs]
        out["inproc_hash"] = sorted({format(r[1] & 0xFFFFFFFFFFFFFFFF, "016x") for r in runs})
        pex, _, _ = link("pyhost")
        out["pyhost_n"] = spec["calls_slow"]
        out["pyhost_calls_s"], out["pyhost_spin_s"] = loop_pair(pex, spec["calls_slow"])
    return out


def main() -> None:
    spec = json.loads(sys.argv[1])
    res = {"scene": scene, "multi": multi}[spec["mode"]](spec)
    res["wasmtime_py"] = importlib.metadata.version("wasmtime")
    print(json.dumps(res))


if __name__ == "__main__":
    main()
