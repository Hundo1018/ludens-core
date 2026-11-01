"""Cachegrind cost of the rules-vs-OOP tick loop (ROADMAP 17.70 (b)).

Builds `benchmarks/probes/rules_oop_probe.mojo` for each variant and population,
once with TICKS=0 (setup only) and once with TICKS=400, and runs each binary
under `valgrind --tool=cachegrind --cache-sim=yes`. The difference of the two
runs is the tick loop. Reports instructions (Ir), D1 read misses (D1mr) and
last-level data read misses (DLmr) per actor-tick.

    pixi run rules-icount                                # N = 1000, 10000
    pixi run rules-icount -- --n 1000,2000,5000,10000,20000
    pixi run rules-icount -- --n 1000,10000 --ll 1048576  # LL forced to 1 MiB
    pixi run rules-icount -- --wall --n 1000,2000,5000,10000,20000

Needs `pixi run build` first (the probe imports the precompiled packages).
"""

import argparse
import os
import re
import subprocess
import sys
import tempfile
import time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PROBE = "benchmarks/probes/rules_oop_probe.mojo"
TICKS = 400
VARIANTS = {0: "rules (value struct)", 1: "oop (object)", 2: "ecs (archetype backend)"}
FIELDS = {"Ir": r"I\s+refs:\s+([\d,]+)", "D1mr": r"D1\s+misses:\s+([\d,]+)", "DLmr": r"LLd\s+misses:\s+([\d,]+)"}


def cpu_flags():
    cpu = os.environ.get("LUDENS_TARGET_CPU", "")
    if not cpu and os.uname().machine == "x86_64":
        cpu = "x86-64"
    return ["--target-cpu", cpu] if cpu else []


def build(out, variant, n, ticks):
    cmd = ["mojo", "build"] + cpu_flags() + ["-I", "build",
           "-D", "VARIANT=%d" % variant, "-D", "N=%d" % n, "-D", "TICKS=%d" % ticks,
           PROBE, "-o", out]
    r = subprocess.run(cmd, cwd=ROOT, capture_output=True, text=True)
    if r.returncode != 0:
        sys.stderr.write(r.stdout + r.stderr)
        raise SystemExit("rules_icount: build failed")


def parse(text):
    out = {}
    for key, pat in FIELDS.items():
        m = re.search(pat, text)
        if not m:
            raise ValueError("rules_icount: no %s line in cachegrind output" % key)
        out[key] = int(m.group(1).replace(",", ""))
    return out


def cachegrind(binary, ll_bytes=None):
    cmd = ["valgrind", "--tool=cachegrind", "--cache-sim=yes"]
    if ll_bytes:
        cmd.append("--LL=%d,16,64" % ll_bytes)
    with tempfile.TemporaryDirectory() as d:
        r = subprocess.run(
            cmd + ["--cachegrind-out-file=" + os.path.join(d, "cg.out"), binary],
            cwd=ROOT, capture_output=True, text=True,
        )
        if r.returncode != 0:
            sys.stderr.write(r.stderr[-2000:])
            raise SystemExit("rules_icount: valgrind run failed")
        return parse(r.stderr)


def tick_loop_cost(variant, n, workdir, ll_bytes=None):
    setup_bin = os.path.join(workdir, "v%d_n%d_t0" % (variant, n))
    loop_bin = os.path.join(workdir, "v%d_n%d_t%d" % (variant, n, TICKS))
    build(setup_bin, variant, n, 0)
    build(loop_bin, variant, n, TICKS)
    a = cachegrind(setup_bin, ll_bytes)
    b = cachegrind(loop_bin, ll_bytes)
    per = n * TICKS
    return {k: (b[k] - a[k]) / per for k in FIELDS}


def wall_seconds(binary, runs):
    best = None
    for _ in range(runs):
        t0 = time.perf_counter()
        r = subprocess.run([binary], cwd=ROOT, capture_output=True)
        dt = time.perf_counter() - t0
        if r.returncode != 0:
            raise SystemExit("rules_icount: probe run failed")
        best = dt if best is None else min(best, dt)
    return best


def wall_cost(variant, n, workdir, runs):
    setup_bin = os.path.join(workdir, "w%d_n%d_t0" % (variant, n))
    loop_bin = os.path.join(workdir, "w%d_n%d_t%d" % (variant, n, TICKS))
    build(setup_bin, variant, n, 0)
    build(loop_bin, variant, n, TICKS)
    return (wall_seconds(loop_bin, runs) - wall_seconds(setup_bin, runs)) * 1e9 / (n * TICKS)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--n", default="1000,10000", help="comma-separated populations")
    ap.add_argument("--wall", action="store_true", help="wall-clock ns per actor-tick (min of --runs) instead of cachegrind")
    ap.add_argument("--runs", type=int, default=5)
    ap.add_argument("--ll", type=int, default=None, help="force the last-level cache to this many bytes (16-way, 64 B lines)")
    args = ap.parse_args()
    if args.ll:
        print("last-level cache forced to %d bytes" % args.ll)
    ns = [int(x) for x in args.n.split(",")]
    if args.wall:
        print("| variant | N | ns per actor-tick (wall, min of %d) |" % args.runs)
        print("|---|---:|---:|")
        with tempfile.TemporaryDirectory() as d:
            for n in ns:
                for v in VARIANTS:
                    print("| %s | %d | %.2f |" % (VARIANTS[v], n, wall_cost(v, n, d, args.runs)))
        return
    print("cost per actor-tick, tick loop only (difference of TICKS=%d and TICKS=0 runs)" % TICKS)
    print("| variant | N | Ir | D1mr | DLmr |")
    print("|---|---:|---:|---:|---:|")
    with tempfile.TemporaryDirectory() as d:
        for n in ns:
            for v in VARIANTS:
                c = tick_loop_cost(v, n, d, args.ll)
                print("| %s | %d | %.1f | %.3f | %.3f |" % (VARIANTS[v], n, c["Ir"], c["D1mr"], c["DLmr"]))


if __name__ == "__main__":
    main()
