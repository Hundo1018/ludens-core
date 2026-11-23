"""wasm as the first platform: what running the wasm64 module costs instead of native Mojo, and what a
second ("game") wasm module linked to the engine module costs.

    pixi run wasm-platform-probe                 # everything; markdown on stdout, build/wasm_platform_probe.json
    pixi run wasm-platform-probe -- --reps 7     # measured repeats per number (default 5, after one warm-up)
    pixi run wasm-platform-probe -- --quick      # skip the wasmtime / node knob sweep and the engine rebuild timing

A. The world_hash scenes (12 bodies x 240 ticks, 1012 x 120) on the native reference build
   (tools/wasm/platform_entry.mojo, `--target native`: x86-64, no FMA, the wasm64 defines), node and wasmtime-py
   (tools/wasm/platform_node.mjs / platform_wasmtime.py on the capi wasm64 module, the one `pixi run wasm` makes).
   Then wasmtime's Config knobs and node's V8 flags, compile / deserialize / instantiate cost.
B. tools/wasm/platform_game.mojo as its own wasm64 module importing engine functions (`ld_*` plus the scalar `pp_*`
   helpers of platform_entry.mojo) from the engine module: rebuild time, size, cross-module call cost
   (wasm-to-wasm vs JS / Python forwarder), and the game loop as two modules vs compiled into the engine.

Every runtime runs pinned to one core (taskset). Each number is the median of --reps runs after one warm-up run (the
min is reported next to it); build times are the median of --reps builds. Every run that steps a world must give the
native hash; the script exits 1 when one does not (the V8 / wasmtime knob rows included, except a config that fails to
compile, which is recorded with its error). Needs ../ludens-wasm-rt (LUDENS_WASM_RT) and `pixi run build`.
"""

from __future__ import annotations

import argparse
import json
import os
import platform
import shutil
import statistics
import subprocess
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
OUT = ROOT / "build" / "pprobe"
RT = Path(os.environ.get("LUDENS_WASM_RT", ROOT.parent / "ludens-wasm-rt")).resolve()
RTRUN = ["pixi", "run", "--manifest-path", str(RT / "pixi.toml")]
MOJO = f"pixi run --manifest-path '{ROOT / 'pixi.toml'}' mojo"
SCENES = [(0, 240), (1000, 120)]  # (extra spheres, ticks): 12 x 240 and 1012 x 120
GAME_TICKS = 240

# wasmtime.Config settings tried on the 1012-body scene (name, config, why).
WASMTIME_CONFIGS = [
    ("default", {}, "wasmtime-py defaults (Cranelift speed, SIMD on, signals-based traps)"),
    ("opt none", {"cranelift_opt_level": "none"}, "no Cranelift optimisation"),
    ("opt speed_and_size", {"cranelift_opt_level": "speed_and_size"}, ""),
    ("no spectre heap", {"cranelift_flags": {"enable_heap_access_spectre_mitigation": "false"}},
     "drop the cmov after each explicit bounds check"),
    ("static memory", {"memory_reservation": 8 << 30, "memory_may_move": False, "memory_reservation_for_growth": 0,
                       "memory_guard_size": 2 << 30}, "fixed 8 GiB reservation + 2 GiB guard"),
    ("static + no spectre", {"memory_reservation": 8 << 30, "memory_may_move": False,
                             "memory_reservation_for_growth": 0, "memory_guard_size": 2 << 30,
                             "cranelift_flags": {"enable_heap_access_spectre_mitigation": "false"}}, ""),
    ("no signals traps", {"signals_based_traps": False}, "every trap check explicit"),
    ("nan canonicalization", {"cranelift_nan_canonicalization": True}, "determinism knob"),
    ("simd off", {"wasm_simd": False}, "the module uses simd128: expected to fail"),
]
NODE_FLAGS = [
    ("default", [], "Liftoff then TurboFan, memory64 guard-page trap handling"),
    ("--no-liftoff", ["--no-liftoff"], "TurboFan only"),
    ("--wasm-enforce-bounds-checks", ["--wasm-enforce-bounds-checks"], "explicit bounds checks, like wasmtime"),
    ("--no-wasm-bounds-checks", ["--no-wasm-bounds-checks"], "no bounds checks at all (unsafe, diagnostic)"),
]


def sh(cmd: list[str], *, cwd: Path = ROOT, env: dict | None = None) -> str:
    p = subprocess.run(cmd, cwd=cwd, capture_output=True, text=True, env=env, check=False)
    if p.returncode != 0:
        raise RuntimeError(f"{' '.join(cmd[:6])}... failed ({p.returncode}):\n{(p.stdout + p.stderr)[-3000:]}")
    return p.stdout


def stat(xs: list[float]) -> dict:
    return {"median": statistics.median(xs), "min": min(xs), "n": len(xs)}


def clean_intermediates(d: Path) -> None:
    """Emitted IR is tens of MB per engine build; keep only the module."""
    for pat in ("*.ll", "*.opt.bc", "*.mojo.o"):
        for f in d.glob(pat):
            f.unlink()


def build(entry: Path, out: Path, *, libs: list[str], exports: list[str], target: str = "wasm64",
          include_build: bool = True) -> float:
    cmd = [*RTRUN, "python3", "-m", "ludens_wasm_rt.build_wasm", "--target", target]
    for lib in libs:
        cmd += ["--lib", lib]
    cmd += [str(entry)] + (["-I", "build"] if include_build else []) + ["-o", str(out), "--mojo", MOJO]
    for e in exports:
        cmd += ["--export", e]
    t0 = time.perf_counter()
    sh(cmd)
    dt = time.perf_counter() - t0
    clean_intermediates(out.parent)
    return dt


class Probe:
    def __init__(self, args):
        self.args = args
        self.reps = args.reps
        cpus = sorted(os.sched_getaffinity(0))
        self.core = cpus[-1]
        self.pin = ["taskset", "-c", str(self.core)] if shutil.which("taskset") else []
        self.env = dict(os.environ, LUDENS_WASM_RT=str(RT), LUDENS_WASM_RT_HOST=str(RT / "ludens_wasm_rt" / "host.mjs"))
        self.res: dict = {"failures": [], "errors": []}
        self.gamelib = OUT / "gamelib"

    # ------------------------------------------------------------------ helpers
    def node(self, spec: dict, flags: list[str] = ()) -> dict:
        cmd = [*RTRUN, *self.pin, "node", *flags, str(ROOT / "tools/wasm/platform_node.mjs"), json.dumps(spec)]
        return json.loads(sh(cmd, env=self.env).strip().splitlines()[-1])

    def wasmtime(self, spec: dict) -> dict:
        cmd = [*RTRUN, *self.pin, "python", str(ROOT / "tools/wasm/platform_wasmtime.py"), json.dumps(spec)]
        return json.loads(sh(cmd, env=self.env).strip().splitlines()[-1])

    def expect(self, what: str, got, want: str) -> None:
        got = list(got)
        if got != [want]:
            self.res["failures"].append(f"{what}: hash {got} != native {want}")

    # ------------------------------------------------------------------ host + versions
    def host(self) -> None:
        cpu = "unknown"
        for line in Path("/proc/cpuinfo").read_text().splitlines():
            if line.startswith("model name"):
                cpu = line.split(":", 1)[1].strip()
                break
        pin = (ROOT / "tools/wasm/wasm_rt.rev").read_text().strip()
        head = subprocess.run(["git", "-C", str(RT), "rev-parse", "HEAD"], capture_output=True, text=True, check=False).stdout.strip()
        mojo = sh(["mojo", "--version"]).strip()
        node = sh([*RTRUN, "node", "--version"]).strip()
        self.res["host"] = {
            "nproc": os.cpu_count(), "cpu": cpu, "kernel": platform.release(), "pinned_core": self.core if self.pin else None,
            "loadavg_start": os.getloadavg(), "mojo": mojo, "node": node,
            "ludens_wasm_rt_head": head, "ludens_wasm_rt_pin": pin,
            "wasmtime_cli": shutil.which("wasmtime") or "not installed",
        }

    # ------------------------------------------------------------------ builds
    def builds(self) -> None:
        OUT.mkdir(parents=True, exist_ok=True)
        self.gamelib.mkdir(exist_ok=True)
        (self.gamelib / "wasm.toml").write_text(
            "# generated by scripts/wasm_probe_platform.py: the game module's engine imports\n"
            '[lib]\nname = "platform_game"\nhost_imports = ["ld_*", "pp_*"]\n')
        src = OUT / "src"
        src.mkdir(exist_ok=True)
        (src / "empty_game.mojo").write_text(
            '@export\ndef game_nop() abi("C") -> Int32:\n    return 0\n\n\ndef main():\n    pass\n')
        b = {}
        b["capi_s"] = build(ROOT / "embed/capi.mojo", OUT / "capi/ludens64.wasm", libs=["."], exports=["ld_*"])
        b["native_s"] = build(ROOT / "tools/wasm/platform_entry.mojo", OUT / "native/engine_native", libs=["."], exports=[],
                              target="native")
        b["engine_s"] = build(ROOT / "tools/wasm/platform_entry.mojo", OUT / "engine/engine.wasm", libs=["."],
                              exports=["ld_*", "pp_*"])
        b["game_s"] = build(ROOT / "tools/wasm/platform_game.mojo", OUT / "game/game.wasm", libs=[str(self.gamelib)],
                            exports=["game_*"], include_build=False)
        b["empty_s"] = build(src / "empty_game.mojo", OUT / "empty/empty.wasm", libs=[str(self.gamelib)],
                             exports=["game_*"], include_build=False)
        self.res["first_builds_s"] = b
        sizes = {k: (OUT / p).stat().st_size for k, p in [
            ("capi_engine", "capi/ludens64.wasm"), ("probe_engine", "engine/engine.wasm"), ("game", "game/game.wasm"),
            ("empty_game", "empty/empty.wasm")]}
        self.res["sizes"] = sizes
        self.res["exports"] = {k: self.export_count(OUT / p) for k, p in [
            ("capi_engine", "capi/ludens64.wasm"), ("probe_engine", "engine/engine.wasm"), ("game", "game/game.wasm")]}

    def export_count(self, wasm: Path) -> int:
        code = ("import sys; from ludens_wasm_rt import wasmbin; d = wasmbin.parse(open(sys.argv[1], 'rb').read()); "
                "print(len(d['exports']))")
        return int(sh([*RTRUN, "python", "-c", code, str(wasm)]).strip())

    def rebuild_times(self) -> None:
        """B.1: one-line edit + rebuild. cold = fresh output dir (the C runtime objects are compiled again),
        warm = same dir (obj/ cache kept). The game edit changes EDIT_STAMP; the engine edit appends a constant to
        a copy of the entry (an edit inside an engine package would also need `pixi run build`)."""
        src = OUT / "src"
        game_src = (ROOT / "tools/wasm/platform_game.mojo").read_text()
        eng_src = (ROOT / "tools/wasm/platform_entry.mojo").read_text()
        out: dict = {}
        jobs = [("game", game_src, "game_edit.mojo", [str(self.gamelib)], ["game_*"], False)]
        if not self.args.quick:
            jobs.append(("engine", eng_src, "engine_edit.mojo", ["."], ["ld_*", "pp_*"], True))
        for name, text, fname, libs, exports, inc in jobs:
            cold, warm = [], []
            for k in range(self.reps):
                d = OUT / f"rebuild_{name}"
                shutil.rmtree(d, ignore_errors=True)
                if name == "game":
                    edited = text.replace("comptime EDIT_STAMP = 0", f"comptime EDIT_STAMP = {k + 1}")
                else:
                    edited = text + f"\ncomptime EDIT_STAMP = {k + 1}\n"
                (src / fname).write_text(edited)
                cold.append(build(src / fname, d / f"{name}.wasm", libs=libs, exports=exports, include_build=inc))
                (src / fname).write_text(edited.replace(f"EDIT_STAMP = {k + 1}", f"EDIT_STAMP = {k + 100}"))
                warm.append(build(src / fname, d / f"{name}.wasm", libs=libs, exports=exports, include_build=inc))
            out[name] = {"cold": stat(cold), "warm": stat(warm)}
            shutil.rmtree(OUT / f"rebuild_{name}", ignore_errors=True)
        if self.args.package_build:
            t0 = time.perf_counter()
            sh(["bash", "scripts/build_engine.sh"])
            out["engine_packages_s"] = time.perf_counter() - t0
        self.res["rebuild_s"] = out

    # ------------------------------------------------------------------ A
    def part_a(self) -> None:
        native_out = sh([*self.pin, str(OUT / "native/engine_native")])
        nat: dict = {}
        for line in native_out.splitlines():
            f = line.split()
            key = f"{f[1]}x{f[2]}" if f[0] == "scene" else f"game{f[1]}"
            ms, h = (float(f[3]), f[4]) if f[0] == "scene" else (float(f[2]), f[3])
            nat.setdefault(key, {"ms": [], "hash": set()})
            nat[key]["ms"].append(ms)
            nat[key]["hash"].add(h.removeprefix("0x").rjust(16, "0"))
        self.native = {}
        for k, v in nat.items():
            assert len(v["hash"]) == 1, (k, v["hash"])
            self.native[k] = {"hash": v["hash"].pop(), "first": v["ms"][0], **stat(v["ms"][1:])}
        a: dict = {"native": self.native, "node": {}, "wasmtime": {}}
        capi = str(OUT / "capi/ludens64.wasm")
        for nb, ticks in SCENES:
            key = f"{12 + nb}x{ticks}"
            want = self.native[key]["hash"]
            spec = {"mode": "scene", "wasm": capi, "nb": nb, "ticks": ticks, "reps": self.reps + 1}
            r = self.node(spec)
            self.expect(f"node {key}", r["hash"], want)
            a["node"][key] = {"first": r["ms_per_tick"][0], **stat(r["ms_per_tick"][1:]),
                              "compile_ms": r["compile_ms"], "instantiate_ms": r["instantiate_ms"]}
            a["node_version"], a["v8"] = r["node"], r["v8"]
            r = self.wasmtime(spec)
            self.expect(f"wasmtime {key}", r["hash"], want)
            a["wasmtime"][key] = {"first": r["ms_per_tick"][0], **stat(r["ms_per_tick"][1:]),
                                  "compile_s": r["compile_s"], "deserialize_s": r["deserialize_s"],
                                  "instantiate_s": r["instantiate_s"], "host_calls_in_step": r["host_calls_in_step"]}
            a["wasmtime_py"] = r["wasmtime_py"]
        if not self.args.quick:
            nb, ticks = SCENES[1]
            want = self.native["1012x120"]["hash"]
            spec = {"mode": "scene", "wasm": capi, "nb": nb, "ticks": ticks, "reps": self.reps + 1}
            a["wasmtime_configs"], a["node_flags"] = [], []
            for name, cfg, why in WASMTIME_CONFIGS:
                row = {"name": name, "config": cfg, "why": why}
                try:
                    r = self.wasmtime({**spec, "config": cfg})
                    self.expect(f"wasmtime [{name}] 1012x120", r["hash"], want)
                    row.update(stat(r["ms_per_tick"][1:]), compile_s=r["compile_s"])
                except RuntimeError as e:
                    row["error"] = str(e).strip().splitlines()[-1][:300]
                a["wasmtime_configs"].append(row)
            for name, flags, why in NODE_FLAGS:
                r = self.node(spec, flags)
                self.expect(f"node [{name}] 1012x120", r["hash"], want)
                a["node_flags"].append({"name": name, "why": why, "first": r["ms_per_tick"][0],
                                        **stat(r["ms_per_tick"][1:])})
        self.res["A"] = a

    # ------------------------------------------------------------------ B
    def part_b(self) -> None:
        want = self.native[f"game{GAME_TICKS}"]["hash"]
        base = {"mode": "multi", "engine": str(OUT / "engine/engine.wasm"), "game": str(OUT / "game/game.wasm"),
                "ticks": GAME_TICKS, "reps": self.reps, "calls": 10_000_000, "calls_slow": 20_000}
        b: dict = {"node": {}, "wasmtime": {}}
        for runtime, links in (("node", ("direct", "js")), ("wasmtime", ("direct", "pycallback"))):
            for link in links:
                inproc = link == "direct"
                r = (self.node if runtime == "node" else self.wasmtime)({**base, "link": link, "inproc": inproc})
                self.expect(f"{runtime} two modules ({link})", r["game_hash"], want)
                row = {"game_first": r["game_ms_per_tick"][0], "game": stat(r["game_ms_per_tick"][1:]),
                       "n": r["n"], "ns_per_call": self.per_call(r["calls_s"], r["spin_s"], r["n"]),
                       "imports": r["imports"]}
                if inproc:
                    self.expect(f"{runtime} one module", r["inproc_hash"], want)
                    row["inproc"] = stat(r["inproc_ms_per_tick"][1:])
                    row["inproc_ns_per_call"] = self.per_call(r["inproc_calls_s"], r["spin_s"], r["inproc_n"])
                    if "pyhost_calls_s" in r:
                        row["pyhost_ns_per_call"] = self.per_call(r["pyhost_calls_s"], r["pyhost_spin_s"], r["pyhost_n"])
                b[runtime][link] = row
        self.res["B"] = b

    @staticmethod
    def per_call(calls: list[float], spins: list[float], n: int) -> dict:
        c, s = statistics.median(calls), statistics.median(spins)
        return {"ns": (c - s) / n * 1e9, "loop_ns": c / n * 1e9, "spin_ns": s / n * 1e9}

    # ------------------------------------------------------------------ report
    def report(self) -> str:
        r, a = self.res, self.res["A"]
        h = r["host"]
        L = [f"# wasm platform probe ({time.strftime('%Y-%m-%d')})", "",
             f"Host: {h['cpu']}, nproc {h['nproc']}, pinned to core {h['pinned_core']} (taskset), "
             f"load at start {h['loadavg_start'][0]:.2f}. {h['mojo']}; node {a['node_version']} (V8 {a['v8']}); "
             f"wasmtime-py {a['wasmtime_py']}; wasmtime CLI: {h['wasmtime_cli']}. ludens-wasm-rt {h['ludens_wasm_rt_head'][:7]}"
             f" (CI pin {h['ludens_wasm_rt_pin'][:7]}).",
             f"Each number: median of {self.reps} runs after one warm-up (min in parentheses).", "",
             "## A. wasm instead of native (ms/tick)", "",
             "| scene | native x86-64 | node | wasmtime-py | node / native | wasmtime / native | hash |", "|---|---:|---:|---:|---:|---:|---|"]
        for nb, ticks in SCENES:
            k = f"{12 + nb}x{ticks}"
            n, no, wt = a["native"][k], a["node"][k], a["wasmtime"][k]
            L.append(f"| {12 + nb} bodies x {ticks} | {n['median']:.3f} ({n['min']:.3f}) | {no['median']:.3f} ({no['min']:.3f}) | "
                     f"{wt['median']:.3f} ({wt['min']:.3f}) | {no['median'] / n['median']:.2f}x | {wt['median'] / n['median']:.2f}x | `{n['hash']}` |")
        L += ["", "First (warm-up) run, ms/tick: " + "; ".join(
            f"{k}: native {a['native'][k]['first']:.3f}, node {a['node'][k]['first']:.3f}, wasmtime {a['wasmtime'][k]['first']:.3f}"
            for k in a["native"] if "x" in k) + ".", "",
            "Start-up cost (capi module, %d bytes):" % r["sizes"]["capi_engine"], "",
            "| runtime | compile | other |", "|---|---:|---|"]
        w = a["wasmtime"]["1012x120"]
        no = a["node"]["1012x120"]
        L += [f"| wasmtime-py (Cranelift, pinned to one core) | {w['compile_s'] * 1e3:.0f} ms | deserialize of the "
              f"serialized module {w['deserialize_s'] * 1e3:.1f} ms, instantiate {w['instantiate_s'] * 1e3:.2f} ms |",
              f"| node (V8, lazy Liftoff) | {no['compile_ms']:.1f} ms | compile + instantiate through host.mjs "
              f"{no['instantiate_ms']:.1f} ms; TurboFan tier-up happens during the first runs |",
              "", f"Host imports called during ld_world_step_ticks (wasmtime): {w['host_calls_in_step']}.", ""]
        if "wasmtime_configs" in a:
            L += ["### wasmtime Config knobs (1012 x 120, ms/tick)", "", "| config | ms/tick | compile | note |",
                  "|---|---:|---:|---|"]
            for c in a["wasmtime_configs"]:
                if "error" in c:
                    L.append(f"| {c['name']} | fails | | {c['error']} |")
                else:
                    L.append(f"| {c['name']} | {c['median']:.3f} ({c['min']:.3f}) | {c['compile_s'] * 1e3:.0f} ms | {c['why']} |")
            L += ["", "### node V8 flags (1012 x 120, ms/tick)", "", "| flags | ms/tick | first run | note |", "|---|---:|---:|---|"]
            for c in a["node_flags"]:
                L.append(f"| {c['name']} | {c['median']:.3f} ({c['min']:.3f}) | {c['first']:.3f} | {c['why']} |")
            L.append("")
        s = r["sizes"]
        L += ["## B. engine module + game module", "",
              "### Sizes", "", "| module | bytes | exports |", "|---|---:|---:|",
              f"| engine: capi (`pixi run wasm`) | {s['capi_engine']:,} | {r['exports']['capi_engine']} |",
              f"| engine: probe entry (the ld_* the game imports + pp_* scalar helpers) | {s['probe_engine']:,} | {r['exports']['probe_engine']} |",
              f"| game (tools/wasm/platform_game.mojo) | {s['game']:,} | {r['exports']['game']} |",
              f"| empty game (one trivial export: runtime + stdlib floor) | {s['empty_game']:,} | |", "",
              f"Floor share of the game module: {s['empty_game'] / s['game'] * 100:.0f} %.", ""]
        rb = r.get("rebuild_s", {})
        if rb:
            L += ["### Rebuild after a one-line edit (s, wall clock)", "", "| module | cold | warm |", "|---|---:|---:|"]
            for k in ("game", "engine"):
                if k in rb:
                    L.append(f"| {k} | {rb[k]['cold']['median']:.1f} ({rb[k]['cold']['min']:.1f}) | {rb[k]['warm']['median']:.1f} ({rb[k]['warm']['min']:.1f}) |")
            if "engine_packages_s" in rb:
                L.append(f"| engine packages (`pixi run build`, needed for an edit inside a package) | {rb['engine_packages_s']:.0f} | |")
            L.append("")
        b = r["B"]
        L += ["### Cross-module call (trivial i64 getter, ns/call, loop minus the call-free loop)", "",
              "| runtime | link | ns/call | loop ns/iter | N |", "|---|---|---:|---:|---:|"]
        for rt_name, links in (("node", ("direct", "js")), ("wasmtime", ("direct", "pycallback"))):
            for link in links:
                x = b[rt_name][link]
                label = {"direct": "engine export as the game's import (wasm-to-wasm)", "js": "JS forwarder",
                         "pycallback": "Python forwarder (re-enters the engine)"}[link]
                L.append(f"| {rt_name} | {label} | {x['ns_per_call']['ns']:.1f} | {x['ns_per_call']['loop_ns']:.1f} | {x['n']:,} |")
            d = b[rt_name]["direct"]
            L.append(f"| {rt_name} | same-module call (engine's pp_calls_inproc) | {d['inproc_ns_per_call']['ns']:.1f} | "
                     f"{d['inproc_ns_per_call']['loop_ns']:.1f} | {10_000_000:,} |")
            if "pyhost_ns_per_call" in d:
                p = d["pyhost_ns_per_call"]
                L.append(f"| {rt_name} | pure Python host function | {p['ns']:.1f} | {p['loop_ns']:.1f} | 20,000 |")
        L += ["", f"### Game loop, {GAME_TICKS} ticks: 100 spheres, 1 set_velocity + 1 step + 300 position reads per tick (ms/tick)",
              "", "| runtime | one module (game in engine) | two modules, direct link | two modules, forwarder |", "|---|---:|---:|---:|"]
        ng = self.native[f"game{GAME_TICKS}"]
        L.append(f"| native | {ng['median']:.3f} ({ng['min']:.3f}) | | |")
        for rt_name, fwd in (("node", "js"), ("wasmtime", "pycallback")):
            d, f = b[rt_name]["direct"], b[rt_name][fwd]
            L.append(f"| {rt_name} | {d['inproc']['median']:.3f} ({d['inproc']['min']:.3f}) | {d['game']['median']:.3f} "
                     f"({d['game']['min']:.3f}) | {f['game']['median']:.3f} ({f['game']['min']:.3f}) |")
        L += ["", f"Game hash (all rows, native included): `{ng['hash']}`.", ""]
        if r["failures"]:
            L += ["## FAILURES", ""] + [f"- {x}" for x in r["failures"]]
        return "\n".join(L)


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--reps", type=int, default=5, help="measured repeats per number (after one warm-up)")
    ap.add_argument("--quick", action="store_true", help="skip the knob sweep and the engine rebuild timing")
    ap.add_argument("--package-build", action="store_true", help="also time `scripts/build_engine.sh` once")
    args = ap.parse_args()
    if not (RT / "pixi.toml").is_file():
        sys.exit(f"wasm_probe_platform: ludens-wasm-rt not found at {RT} (set LUDENS_WASM_RT)")
    if shutil.disk_usage(ROOT).free < 400 << 20:
        sys.exit("wasm_probe_platform: less than 400 MB free; the builds emit ~30 MB of IR each (deleted after use)")
    p = Probe(args)
    p.host()
    p.builds()
    p.part_a()
    p.part_b()
    p.rebuild_times()
    p.res["host"]["loadavg_end"] = os.getloadavg()
    md = p.report()
    print(md)
    p.res["markdown"] = md
    out = ROOT / "build" / "wasm_platform_probe.json"
    out.write_text(json.dumps(p.res, indent=1, default=list))
    print(f"\nwrote {out.relative_to(ROOT)}")
    if p.res["failures"]:
        print("WASM PLATFORM PROBE FAIL: hash mismatch", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
