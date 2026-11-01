"""geometry.trig must equal musl's sinf / cosf bit for bit (ROADMAP 17.89, #75).

    pixi run trig-parity            # 8 M comparisons against libwasmrt_math.a
    pixi run trig-parity -- --selftest

libwasmrt_math.a comes from ludens-wasm-rt (`LUDENS_WASM_RT`, default ../ludens-wasm-rt): the same musl
`sinf` / `cosf` the wasm module links, as native objects. Arguments past ~2^28 * pi/2 (musl's
multi-precision path) are excluded by the generator on purpose; the port documents that range.
"""

import os
import re
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
RT = Path(os.environ.get("LUDENS_WASM_RT", ROOT.parent / "ludens-wasm-rt"))


def parse(out: str) -> tuple[int, int]:
    m = re.search(r"mismatch (\d+) of (\d+)", out)
    if not m:
        raise SystemExit("trig-parity: no result line in the probe output")
    return int(m.group(1)), int(m.group(2))


def selftest() -> int:
    ok = parse("mismatch 0 of 8000000") == (0, 8000000) and parse("x\nmismatch 3 of 10\n") == (3, 10)
    try:
        parse("nothing")
        ok = False
    except SystemExit:
        pass
    print(f"[{'PASS' if ok else 'FAIL'}] trig-parity selftest")
    return 0 if ok else 1


def main() -> int:
    if "--selftest" in sys.argv:
        return selftest()
    if not (RT / "pixi.toml").is_file():
        print(f"trig-parity: ludens-wasm-rt not found at {RT} (set LUDENS_WASM_RT)", file=sys.stderr)
        return 1
    with tempfile.TemporaryDirectory(prefix="trig_") as d:
        a, exe = Path(d) / "libwasmrt_math.a", Path(d) / "parity"
        r = subprocess.run(["pixi", "run", "--manifest-path", str(RT / "pixi.toml"), "python3", "-m",
                            "ludens_wasm_rt.native_math", "-o", str(a)], capture_output=True, text=True)
        if r.returncode != 0:
            print(r.stdout[-800:], r.stderr[-800:])
            return 1
        r = subprocess.run(["mojo", "build", "--target-cpu", "x86-64", "-I", "build", "-Xlinker", str(a), "-o", str(exe),
                            "tools/wasm/trig_parity.mojo"], cwd=ROOT, capture_output=True, text=True)
        if r.returncode != 0:
            print(r.stderr[-1500:])
            return 1
        out = subprocess.run([str(exe)], capture_output=True, text=True).stdout
    bad, total = parse(out)
    print(f"[{'PASS' if bad == 0 else 'FAIL'}] trig-parity - {bad} mismatches in {total} comparisons")
    return 0 if bad == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
