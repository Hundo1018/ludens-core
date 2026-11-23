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

C. (--aot / --simd-opt) how close an LLVM build of the same .wasm gets, all rows in one table vs native:
   * wasm2c (WABT, `pixi exec -s wabt`) -> C -> clang 23 -O3 -march=x86-64 -ffp-contract=off with wasm2c's runtime and
     tools/wasm/platform_w2c.c as the host (the module's imports are env.host_write / env.host_now_ns), one row per
     wasm2c memory-check / segue configuration (W2C_VARIANTS);
   * Wasmer's LLVM backend (--wasmer, conda-forge wasmer via `pixi exec`) on tools/wasm/platform_wasi.mojo built with
     `--host wasi`: records whether it compiles a memory64 module;
   * --simd-opt: the capi module rebuilt with `opt -mattr=+simd128,...` and C `-msimd128` (ludens_wasm_rt's
     build_wasm passes +simd128 to llc only; PATH wrappers in build/pprobe/simdwrap add it) on node, wasmtime
     (Spectre heap mitigation off) and the wasm2c variants marked `simd`.
   `--reuse` keeps modules already built under build/pprobe, `--skip-b` skips part B and the rebuild timing.
   --profile adds node --cpu-prof (self time) and callgrind (instructions) top-10 functions.

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
import re
import shutil
import statistics
import subprocess
import sys
import time
from concurrent.futures import ThreadPoolExecutor
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
    ("simd off", {"wasm_simd": False, "wasm_relaxed_simd": False}, "the module uses simd128: expected to fail"),
]
NODE_FLAGS = [
    ("default", [], "Liftoff then TurboFan, memory64 guard-page trap handling"),
    ("--no-liftoff", ["--no-liftoff"], "TurboFan only"),
    ("--wasm-enforce-bounds-checks", ["--wasm-enforce-bounds-checks"], "explicit bounds checks, like wasmtime"),
    ("--no-wasm-bounds-checks", ["--no-wasm-bounds-checks"], "no bounds checks at all (unsafe, diagnostic)"),
]


WABT = "wabt==1.0.41"
NO_SPECTRE = {"cranelift_flags": {"enable_heap_access_spectre_mitigation": "false"}}
# wasm2c builds of the capi module (name, extra clang flags, patch the generated C, also on the --simd-opt module, note).
# wasm2c checks every memory64 access explicitly (RANGE_CHECK: add-overflow test + compare with the memory size)
# whatever WASM_RT_MEMCHECK_* says; GUARD_PAGES vs BOUNDS_CHECK only changes how the memory is allocated and how
# stack overflow is caught (guard page + signal handler vs a depth counter on every call).
W2C_VARIANTS = [
    ("default", [], None, True, "WASM_RT_MEMCHECK_GUARD_PAGES (the default on x86-64 Linux): mmap'd memory, "
     "stack overflow by signal handler"),
    ("bounds check", ["-DWASM_RT_MEMCHECK_BOUNDS_CHECK=1"], None, False,
     "malloc'd memory, stack-depth counter on every call"),
    ("segue", ["-DWASM_RT_ALLOW_SEGUE=1", "-DWASM_RT_SEGUE_FREE_SEGMENT=1"], None, True,
     "linear-memory base in %gs (fsgsbase): loads/stores without the base register"),
    ("no range check", [], "no_range_check", True, "RANGE_CHECK patched out: no bounds checks at all (unsafe, diagnostic)"),
    ("x86-64-v2", ["-march=x86-64-v2"], None, False, "SSE4.2 (still no FMA): simde's simd128 lowering gets "
     "SSE4.1 blends / rounds; the native reference stays baseline x86-64"),
]


def sh(cmd: list[str], *, cwd: Path = ROOT, env: dict | None = None) -> str:
    p = subprocess.run(cmd, cwd=cwd, capture_output=True, text=True, env=env, check=False)
    if p.returncode != 0:
        raise RuntimeError(f"{' '.join(cmd[:6])}... failed ({p.returncode}):\n{(p.stdout + p.stderr)[:1500]}\n...\n{(p.stdout + p.stderr)[-1500:]}")
    return p.stdout


def stat(xs: list[float]) -> dict:
    return {"median": statistics.median(xs), "min": min(xs), "n": len(xs)}


def fix_w2c_decls(c: Path) -> int:
    """wabt 1.0.41 wasm2c --enable-tail-call emits the first local of some wasm_tailcall_* functions as
    `  u64   u32 var_i0;` ... `var_l2 = 0;` (type and name split around the stack-variable declarations); put the type
    back in front of the name. Returns how many were fixed."""
    lines = c.read_text().split("\n")
    n = 0
    for i, line in enumerate(lines):
        m = re.match(r"^  ([uf]\d+|v128)   (\S.*)$", line)
        if not m:
            continue
        lines[i] = "  " + m.group(2)
        j = i + 1
        while not re.match(r"^var_l\d+ = ", lines[j]):
            if lines[j].startswith("}"):
                raise RuntimeError(f"fix_w2c_decls: no split local after line {i + 1} of {c}")
            j += 1
        lines[j] = f"{m.group(1)} {lines[j]}"
        n += 1
    c.write_text("\n".join(lines))
    return n


def patch_range_check(c: Path) -> None:
    """Drop wasm2c's memory64 bounds check (diagnostic only: an out-of-bounds access is then undefined behaviour)."""
    text = c.read_text()
    pat = re.compile(r"#define RANGE_CHECK\(mem, offset, len\)\s*\\\n(?:.*\\\n)*?\s*\} while \(0\);")
    text, k = pat.subn("#define RANGE_CHECK(mem, offset, len) do {} while (0);", text)
    if k != 1:
        raise RuntimeError(f"patch_range_check: RANGE_CHECK definition matched {k} times (wasm2c output changed?)")
    c.write_text(text)


def unescape_w2c(name: str) -> str:
    """wasm2c / names-section symbols spell punctuation as 0xNN."""
    return re.sub(r"0x([0-9A-F]{2})", lambda m: chr(int(m.group(1), 16)), name)


def clean_intermediates(d: Path) -> None:
    """Emitted IR is tens of MB per engine build; keep only the module."""
    for pat in ("*.ll", "*.opt.bc", "*.mojo.o"):
        for f in d.glob(pat):
            f.unlink()


REUSE = False  # --reuse: keep a module that is already there


def build(entry: Path, out: Path, *, libs: list[str], exports: list[str], target: str = "wasm64",
          include_build: bool = True, path_prefix: Path | None = None, extra: list[str] = ()) -> float:
    if REUSE and out.is_file():
        return 0.0
    # path_prefix goes in front of PATH inside the pixi env (whose bin/ pixi itself puts first)
    pre = ["bash", "-c", 'PATH="$0:$PATH" exec "$@"', str(path_prefix)] if path_prefix else []
    cmd = [*RTRUN, *pre, "python3", "-m", "ludens_wasm_rt.build_wasm", "--target", target, *extra]
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
        if self.args.skip_b:
            self.res["first_builds_s"] = {
                "capi_s": build(ROOT / "embed/capi.mojo", OUT / "capi/ludens64.wasm", libs=["."], exports=["ld_*"]),
                "native_s": build(ROOT / "tools/wasm/platform_entry.mojo", OUT / "native/engine_native", libs=["."],
                                  exports=[], target="native")}
            self.res["sizes"] = {"capi_engine": (OUT / "capi/ludens64.wasm").stat().st_size}
            return
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
                    lines = str(e).strip().splitlines()
                    key = [x for x in lines if re.search(r"panicked|Error|error|failed", x) and "RUST_BACKTRACE" not in x]
                    row["error"] = " / ".join(x.strip() for x in (key or lines[-1:])[:3])[:300].replace("|", "/")
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

    # ------------------------------------------------------------------ C
    def native_run(self) -> dict:
        """The native reference build once more (C measures it before and after the wasm rows)."""
        rows = [x.split() for x in sh([*self.pin, str(OUT / "native/engine_native")]).splitlines()
                if x.startswith("scene 1012 ")]
        return {**stat([float(f[3]) for f in rows[1:]]), "hash": sorted({f[4].removeprefix("0x").rjust(16, "0") for f in rows}),
                "load": os.getloadavg()[0]}

    def wabt(self) -> Path:
        if not hasattr(self, "_wabt"):
            self._wabt = Path(sh(["pixi", "exec", "-s", WABT, "-s", "simde", "sh", "-c", "echo $CONDA_PREFIX"]).strip())
            self._clang = sh([*RTRUN, "which", "clang"]).strip()
            self.res["host"]["wasm2c"] = sh([str(self._wabt / "bin/wasm2c"), "--version"]).strip()
            self.res["host"]["clang_aot"] = sh([self._clang, "--version"]).splitlines()[0]
        return self._wabt

    def simd_ops(self, wasm: Path) -> dict:
        dis = sh([str(self.wabt() / "bin/wasm-objdump"), "-d", str(wasm)])
        ops = re.findall(r"\|\s+((?:[if](?:8x16|16x8|32x4|64x2)|v128)\.\S+)", dis)
        return {"simd_ops": len(ops), "f32x4": sum(o.startswith("f32x4") for o in ops),
                "f32x4.mul": ops.count("f32x4.mul"), "f32x4.add": ops.count("f32x4.add")}

    def simd_wrappers(self) -> Path:
        """opt / clang wrappers that add simd128 where build_wasm leaves it out (llc already gets +simd128)."""
        d = OUT / "simdwrap"
        d.mkdir(parents=True, exist_ok=True)
        envbin = Path(sh([*RTRUN, "which", "opt"]).strip()).parent
        (d / "opt").write_text(f'#!/bin/sh\nexec "{envbin}/opt" -mattr=+tail-call,+simd128,+bulk-memory,'
                               f'+nontrapping-fptoint,+sign-ext,+mutable-globals "$@"\n')
        (d / "clang").write_text(f'#!/bin/sh\ncase " $* " in *--target=wasm64*) exec "{envbin}/clang" -msimd128 "$@";; esac\n'
                                 f'exec "{envbin}/clang" "$@"\n')
        for f in ("opt", "clang"):
            (d / f).chmod(0o755)
        return d

    def w2c_build(self, wasm: Path, d: Path, flags: list[str], patch: str | None) -> dict:
        exe = d / "w2c_scene"
        if REUSE and exe.is_file():
            return {"bin": exe, "compile_s": None, "fixed_decls": None}
        d.mkdir(parents=True, exist_ok=True)
        wabt = self.wabt()
        c = d / "module.c"
        sh([str(wabt / "bin/wasm2c"), "--enable-memory64", "--enable-tail-call", "-n", "ludens", str(wasm), "-o", str(c)])
        fixed = fix_w2c_decls(c)
        if patch == "no_range_check":
            patch_range_check(c)
        base = [self._clang, "-O3", "-march=x86-64", "-ffp-contract=off", f"-I{d}", f"-I{wabt / 'include'}", "-w", *flags]
        t0 = time.perf_counter()
        sh([*base, "-c", str(c), "-o", str(d / "module.o")])
        compile_s = time.perf_counter() - t0
        rt = wabt / "share/wabt/wasm2c"
        objs = [d / "module.o"]
        for src in (rt / "wasm-rt-impl.c", rt / "wasm-rt-mem-impl.c", ROOT / "tools/wasm/platform_w2c.c"):
            objs.append(d / (src.stem + ".o"))
            sh([*base, "-c", str(src), "-o", str(objs[-1])])
        sh([self._clang, *map(str, objs), "-lm", "-lpthread", "-o", str(exe)])
        for f in [c, *objs]:
            f.unlink()
        return {"bin": exe, "compile_s": compile_s, "fixed_decls": fixed}

    def w2c_try(self, wasm: Path, d: Path, flags: list[str], patch: str | None) -> dict:
        try:
            return self.w2c_build(wasm, d, flags, patch)
        except RuntimeError as e:
            lines = [x for x in str(e).splitlines() if "error" in x] or str(e).splitlines()[-1:]
            return {"error": " / ".join(x.strip() for x in lines[:3])[:300].replace("|", "/")}

    def w2c_run(self, exe: Path, nb: int, ticks: int) -> dict:
        return json.loads(sh([*self.pin, str(exe), str(nb), str(ticks), str(self.reps + 1)]).strip().splitlines()[-1])

    def wasmer(self) -> dict:
        """Wasmer (conda-forge, LLVM / Cranelift backends) on the WASI scene driver; records the error if any."""
        wasm = OUT / "wasi/bench.wasm"
        build(ROOT / "tools/wasm/platform_wasi.mojo", wasm, libs=["."], exports=["pw_*"], extra=["--host", "wasi"])
        out = {"version": sh(["pixi", "exec", "-s", "wasmer", "wasmer", "--version"]).strip(), "backends": {}}
        for be in ("llvm", "cranelift"):
            p = subprocess.run(["pixi", "exec", "-s", "wasmer", *self.pin, "wasmer", "run", f"--{be}", "--enable-memory64",
                                "--enable-tail-call", "--enable-simd", "--enable-bulk-memory", "--invoke", "pw_bench",
                                str(wasm), "1000", "120", str(self.reps + 1)], capture_output=True, text=True, check=False)
            text = (p.stdout + p.stderr).strip()
            rows = [x.split() for x in p.stdout.splitlines() if x.startswith("scene ")]
            out["backends"][be] = ({**stat([float(f[3]) for f in rows[1:]]),
                                    "hash": sorted({f[4].removeprefix("0x").rjust(16, "0") for f in rows})}
                                   if p.returncode == 0 and rows else {"error": " / ".join(text.splitlines()[-2:])[:300]})
        return out

    def part_c(self) -> None:
        c: dict = {"rows": []}
        mods = {"baseline": OUT / "capi/ludens64.wasm"}
        if self.args.simd_opt:
            mods["simd128 opt"] = OUT / "capi_simd/ludens64.wasm"
            c["simd_build_s"] = build(ROOT / "embed/capi.mojo", mods["simd128 opt"], libs=["."], exports=["ld_*"],
                                      path_prefix=self.simd_wrappers())
            c["simd_ops"] = {k: self.simd_ops(p) for k, p in mods.items()}
        jobs, builds = [], []
        if self.args.aot:
            self.wabt()
            for name, flags, patch, on_simd, why in W2C_VARIANTS:
                for mk in mods:
                    if mk == "baseline" or on_simd:
                        jobs.append((name, mk, flags, patch, why))
            with ThreadPoolExecutor(max(1, min(3, (os.cpu_count() or 2) - 1))) as pool:
                builds = list(pool.map(lambda j: self.w2c_try(
                    mods[j[1]], OUT / "w2c" / f"{j[1].split()[0]}-{j[0].replace(' ', '_')}", j[2], j[3]), jobs))
        want = {sc: self.native[f"{12 + sc[0]}x{sc[1]}"]["hash"] for sc in SCENES}

        def measure(runtime: str, setting: str, mk: str, fn, note: str = "", compile_s=None) -> None:
            row = {"runtime": runtime, "setting": setting, "module": mk, "note": note, "load": os.getloadavg()[0],
                   "compile_s": compile_s}
            try:
                big = fn(SCENES[1])
                small = fn(SCENES[0])
                row.update(stat(big["ms_per_tick"][1:]), hash=big["hash"], hash12=small["hash"])
                self.expect(f"{runtime} [{setting}, {mk}] 1012x120", big["hash"], want[SCENES[1]])
                self.expect(f"{runtime} [{setting}, {mk}] 12x240", small["hash"], want[SCENES[0]])
            except RuntimeError as e:
                row["error"] = " / ".join(str(e).strip().splitlines()[-3:])[:300].replace("|", "/")
            c["rows"].append(row)

        c["native_start"] = self.native_run()
        for mk, wasm in mods.items():
            def spec(sc, cfg=None, _w=wasm):
                return {"mode": "scene", "wasm": str(_w), "nb": sc[0], "ticks": sc[1], "reps": self.reps + 1,
                        **({"config": cfg} if cfg else {})}
            measure("node", "default", mk, lambda sc: self.node(spec(sc)))
            measure("wasmtime-py", "default", mk, lambda sc: self.wasmtime(spec(sc)))
            measure("wasmtime-py", "no Spectre heap mitigation", mk, lambda sc: self.wasmtime(spec(sc, NO_SPECTRE)))
            for (name, mk2, _f, _p, why), b in zip(jobs, builds, strict=True):
                if mk2 == mk and "error" in b:
                    c["rows"].append({"runtime": "wasm2c + clang -O3", "setting": name, "module": mk, "note": why,
                                      "error": b["error"]})
                elif mk2 == mk:
                    measure("wasm2c + clang -O3", name, mk, lambda sc, _b=b: self.w2c_run(_b["bin"], *sc), why,
                            b["compile_s"])
        c["native_end"] = self.native_run()
        if self.args.wasmer:
            c["wasmer"] = self.wasmer()
        self.res["C"] = c
        if self.args.profile:
            self.profile()

    def profile(self) -> None:
        """Top-10 functions: node --cpu-prof self time on the baseline module, callgrind instructions on the fastest
        wasm2c binary (no `perf` on this host)."""
        prof: dict = {}
        d = OUT / "cpuprof"
        shutil.rmtree(d, ignore_errors=True)
        d.mkdir(parents=True)
        nb, ticks = SCENES[1]
        self.node({"mode": "scene", "wasm": str(OUT / "capi/ludens64.wasm"), "nb": nb, "ticks": ticks, "reps": 3},
                  ["--cpu-prof", f"--cpu-prof-dir={d}"])
        p = json.loads(next(d.glob("*.cpuprofile")).read_text())
        hits: dict = {}
        for n in p["nodes"]:
            name = n["callFrame"]["functionName"] or "(anonymous)"
            hits[name] = hits.get(name, 0) + n.get("hitCount", 0)
        total = sum(hits.values())
        prof["node"] = [(unescape_w2c(k)[:110], v / total * 100) for k, v in sorted(hits.items(), key=lambda kv: -kv[1])[:10]]
        shutil.rmtree(d, ignore_errors=True)
        rows = [r for r in self.res["C"]["rows"] if r["runtime"].startswith("wasm2c") and "median" in r
                and r["setting"] != "no range check"]
        if rows and shutil.which("valgrind"):
            best = min(rows, key=lambda r: r["median"])
            exe = OUT / "w2c" / f"{best['module'].split()[0]}-{best['setting'].replace(' ', '_')}" / "w2c_scene"
            cg = OUT / "callgrind.out"
            sh(["valgrind", "--tool=callgrind", f"--callgrind-out-file={cg}", str(exe), str(nb), str(ticks), "1"])
            ann = sh(["callgrind_annotate", "--threshold=100", str(cg)])
            cg.unlink()
            tot = None
            top = []
            for line in ann.splitlines():
                m = re.match(r"^\s*([\d,]+) \(\s*([\d.]+)%\)\s+(\S.*)$", line)
                if not m:
                    continue
                if tot is None and "PROGRAM TOTALS" in line:
                    tot = m.group(1)
                    continue
                if ":" in m.group(3) and len(top) < 10:
                    fn = m.group(3).split(":", 1)[1].split(" [")[0].removeprefix("w2c_ludens_")
                    top.append((unescape_w2c(fn)[:110], float(m.group(2))))
            prof["callgrind"] = {"binary": f"{best['setting']} ({best['module']})", "top": top}
        self.res["profile"] = prof

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
        if "C" in r:
            L += self.report_c()
        if "B" in r:
            L += self.report_b()
        if r["failures"]:
            L += ["## FAILURES", ""] + [f"- {x}" for x in r["failures"]]
        return "\n".join(L)

    def report_c(self) -> list[str]:
        r, c = self.res, self.res["C"]
        ns, ne = c["native_start"], c["native_end"]
        ref = (ns["median"] + ne["median"]) / 2
        L = ["## C. LLVM ahead-of-time and simd128 opt vs native (1012 x 120, ms/tick)", "",
             f"Native reference (platform_entry.mojo `--target native`: x86-64, no FMA) measured before and after the "
             f"rows: {ns['median']:.3f} ({ns['min']:.3f}) / {ne['median']:.3f} ({ne['min']:.3f}), load "
             f"{ns['load']:.2f} / {ne['load']:.2f}; ratios use their mean {ref:.3f}. "
             f"wasm2c: {r['host'].get('wasm2c', '-')}, C compiler: {r['host'].get('clang_aot', '-')}. "
             "Hash equal = the 1012 x 120 and 12 x 240 hashes both equal native.", "",
             "| runtime | setting | module | ms/tick | ratio | hash equal | load | C compile | note |",
             "|---|---|---|---:|---:|---|---:|---:|---|",
             f"| native | reference build | | {ref:.3f} | 1.00x | yes | | | |"]
        want = (self.native["1012x120"]["hash"], self.native["12x240"]["hash"])
        for x in c["rows"]:
            if "error" in x:
                L.append(f"| {x['runtime']} | {x['setting']} | {x['module']} | fails | | | | | {x['error']} |")
                continue
            ok = "yes" if (x["hash"], x["hash12"]) == ([want[0]], [want[1]]) else f"NO {x['hash']} {x['hash12']}"
            cs = f"{x['compile_s']:.0f} s" if x.get("compile_s") else ""
            L.append(f"| {x['runtime']} | {x['setting']} | {x['module']} | {x['median']:.3f} ({x['min']:.3f}) | "
                     f"{x['median'] / ref:.2f}x | {ok} | {x['load']:.2f} | {cs} | {x['note']} |")
        L.append("")
        if "simd_ops" in c:
            L += ["simd128 opt variant: the capi module rebuilt with opt `-mattr=+simd128,...` and C `-msimd128` "
                  f"(build {c['simd_build_s']:.0f} s). SIMD instructions in the module (wasm-objdump -d): " + "; ".join(
                      f"{k}: {v['simd_ops']:,} ({v['f32x4']:,} f32x4, of which mul {v['f32x4.mul']:,} / add {v['f32x4.add']:,})"
                      for k, v in c["simd_ops"].items()) + ".", ""]
        if "wasmer" in c:
            w = c["wasmer"]
            L += [f"Wasmer ({w['version']}, conda-forge) on tools/wasm/platform_wasi.mojo (`--host wasi`): " + "; ".join(
                f"{be}: " + (v["error"] if "error" in v else f"{v['median']:.3f} ms/tick, hash {v['hash']}")
                for be, v in w["backends"].items()) + ".", ""]
        prof = r.get("profile")
        if prof:
            L += ["### Profiles (1012 x 120)", "", "node --cpu-prof, baseline module, self time:", "",
                  "| % | function |", "|---:|---|"] + [f"| {pc:.1f} | `{fn}` |" for fn, pc in prof["node"]] + [""]
            if "callgrind" in prof:
                cg = prof["callgrind"]
                L += [f"callgrind (self instructions), wasm2c {cg['binary']}:", "",
                      "| % Ir | function |", "|---:|---|"] + [f"| {pc:.1f} | `{fn}` |" for fn, pc in cg["top"]] + [""]
        return L

    def report_b(self) -> list[str]:
        r = self.res
        L: list[str] = []
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
        return L


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--reps", type=int, default=5, help="measured repeats per number (after one warm-up)")
    ap.add_argument("--quick", action="store_true", help="skip the knob sweep and the engine rebuild timing")
    ap.add_argument("--package-build", action="store_true", help="also time `scripts/build_engine.sh` once")
    ap.add_argument("--aot", action="store_true", help="C: wasm2c + clang -O3 builds of the capi module (W2C_VARIANTS)")
    ap.add_argument("--simd-opt", action="store_true", help="C: also a capi module built with simd128 for opt and C")
    ap.add_argument("--wasmer", action="store_true", help="C: try Wasmer's LLVM / Cranelift backends (pixi exec wasmer)")
    ap.add_argument("--profile", action="store_true", help="C: node --cpu-prof and callgrind top-10 functions")
    ap.add_argument("--skip-b", action="store_true", help="skip part B (game module) and the rebuild timing")
    ap.add_argument("--reuse", action="store_true", help="keep modules / binaries already under build/pprobe")
    args = ap.parse_args()
    global REUSE
    REUSE = args.reuse
    if not (RT / "pixi.toml").is_file():
        sys.exit(f"wasm_probe_platform: ludens-wasm-rt not found at {RT} (set LUDENS_WASM_RT)")
    if shutil.disk_usage(ROOT).free < 400 << 20:
        sys.exit("wasm_probe_platform: less than 400 MB free; the builds emit ~30 MB of IR each (deleted after use)")
    p = Probe(args)
    p.host()
    p.builds()
    p.part_a()
    if args.aot or args.simd_opt or args.wasmer:
        p.part_c()
    if not args.skip_b:
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
