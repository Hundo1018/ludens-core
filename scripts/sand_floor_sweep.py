#!/usr/bin/env python3
"""Run experiments/exp_sand_repose.mojo (heap table only) with the floor top at
several heights relative to the grid, to check that contact does not depend on
where the floor surface falls between grid nodes (ROADMAP 17.58).

  pixi run python scripts/sand_floor_sweep.py [--floors 0.19 0.2125 0.2375]
                                              [--phis 20 30] [--steps 3000]

Needs `pixi run build` first. Prints one markdown row per (floor, friction).
"""
import argparse
import re
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SRC = ROOT / "experiments" / "exp_sand_repose.mojo"


def variant(floor: float, phis: list[float], steps: int, mu: float) -> str:
    s = SRC.read_text()
    s = re.sub(r"comptime FLOOR: Real = [0-9.]+", f"comptime FLOOR: Real = {floor}", s)
    s = re.sub(r"for phi in \[Real\(20\).*?\]:", "for phi in [" + ", ".join(f"Real({p:g})" for p in phis) + "]:", s, count=1)
    s = s.replace("for _ in range(3000):", f"for _ in range({steps}):")
    s = re.sub(r"(Vec3\(1\.0, FLOOR, 1\.0, 0\)\), )1\.0\)", lambda m: m.group(1) + f"{mu})", s, count=1)
    cut = s.index('    print()\n    print("| friction angle | cone slope')
    return s[:cut]


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--floors", type=float, nargs="+", default=[0.19, 0.2125, 0.2375])
    ap.add_argument("--phis", type=float, nargs="+", default=[20, 30])
    ap.add_argument("--steps", type=int, default=3000)
    ap.add_argument("--mu", type=float, default=1.0, help="floor friction coefficient")
    a = ap.parse_args()
    print("| floor top (m) | floor mu | friction angle | equal-volume cone angle | peak (m) | outer radius (m) |")
    print("|---:|---:|---:|---:|---:|---:|")
    with tempfile.TemporaryDirectory() as d:
        for fl in a.floors:
            f = Path(d) / "exp.mojo"
            f.write_text(variant(fl, a.phis, a.steps, a.mu))
            r = subprocess.run(["mojo", "run", "-I", str(ROOT / "build"), str(f)], capture_output=True, text=True, cwd=d, check=False)
            if r.returncode != 0:
                print(r.stdout + r.stderr, file=sys.stderr)
                return r.returncode
            for line in r.stdout.splitlines():
                c = [x.strip() for x in line.strip("|").split("|")]
                if len(c) >= 4 and re.fullmatch(r"[0-9.]+", c[0]):
                    print(f"| {fl} | {a.mu} | {c[0]} | {c[1]} | {c[2]} | {c[3]} |")
    return 0


if __name__ == "__main__":
    sys.exit(main())
