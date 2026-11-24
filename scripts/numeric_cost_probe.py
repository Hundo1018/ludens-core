"""Numeric policy cost probe (ROADMAP 17.105).

How much speed do the optimizations that give up cross-target bit identity buy,
and how much error do they add? This compiles `benchmarks/probes/numeric_cost.mojo`
once per CPU target / feature set and runs each build. For every workload it
reports the time against the reference build. For the pile it also reports
whether the result is bit-identical to the reference and, if not, the largest
position drift.

    pixi run numeric-cost                 # table on this host (needs `pixi run build`)
    pixi run numeric-cost -- --runs 3     # repeat each build N times, keep the minimum
    pixi run numeric-cost -- --selftest   # parser / table check on synthetic data

Reference: `--target-cpu x86-64`. This is SSE2 with no FMA, the build that
`scripts/flag_policy.py` pins and that all goldens come from. The other builds
change one factor at a time: FMA alone, AVX2 without FMA, AVX2 + FMA, and the
host CPU. Times are wall clock on a shared machine, so differences under about
5 % are noise; run with `--runs 3` for a decision.
"""

import os
import subprocess
import sys
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PROBE = "benchmarks/probes/numeric_cost.mojo"

VARIANTS = [
    ("x86-64 (reference: SSE2, no FMA)", ["--target-cpu", "x86-64"]),
    ("x86-64 + FMA only", ["--target-cpu", "x86-64", "--target-features", "+fma"]),
    ("haswell without FMA (AVX2)", ["--target-cpu", "haswell", "--target-features", "-fma"]),
    ("haswell (AVX2 + FMA)", ["--target-cpu", "haswell"]),
    ("native host CPU", []),
]
WORKLOADS = ["pile", "motor", "norm_exact", "norm_rsqrt"]


def parse(text):
    """{'time': {name: ns}, 'hash': {name: int}, 'pos': [floats], 'err': {name: float}}"""
    out = {"time": {}, "hash": {}, "pos": [], "err": {}}
    for line in text.strip().split("\n"):
        f = line.split()
        if not f:
            continue
        if f[0] == "TIME":
            out["time"][f[1]] = int(f[2])
        elif f[0] == "HASH":
            out["hash"][f[1]] = int(f[2])
        elif f[0] == "POS":
            out["pos"] = [float(x) for x in f[1:]]
        elif f[0] == "ERR":
            out["err"][f[1]] = float(f[2])
    return out


def merge_min(a, b):
    """Keep the faster time per workload; results must agree (same build)."""
    if a is None:
        return b
    for k, v in b["time"].items():
        a["time"][k] = min(a["time"].get(k, v), v)
    return a


def build_and_run(flags, d, runs):
    exe = os.path.join(d, "nc")
    b = subprocess.run(["mojo", "build"] + flags + ["-I", "build", PROBE, "-o", exe], cwd=ROOT, capture_output=True, text=True, check=False)
    if b.returncode != 0:
        return None, (b.stderr.strip().split("\n") or ["build failed"])[-1]
    res = None
    for _ in range(runs):
        r = subprocess.run([exe], cwd=ROOT, capture_output=True, text=True, check=False)
        if r.returncode != 0:
            return None, "run failed (the host cannot run this target?): " + r.stderr.strip()[-120:]
        res = merge_min(res, parse(r.stdout))
    return res, ""


def drift(res, ref):
    if res["hash"].get("pile") == ref["hash"].get("pile"):
        return 0.0
    return max(abs(a - b) for a, b in zip(res["pos"], ref["pos"], strict=True))


def row(name, res, ref):
    cells = [name]
    for w in WORKLOADS:
        t = res["time"][w] / 1e6
        cells.append("%.1f ms (%.2fx)" % (t, ref["time"][w] / res["time"][w]))
    same = res["hash"]["pile"] == ref["hash"]["pile"]
    cells.append("identical" if same else "differs, max %.2e m" % drift(res, ref))
    cells.append("identical" if res["hash"]["motor"] == ref["hash"]["motor"] else "differs")
    return "| " + " | ".join(cells) + " |"


def main():
    if "--selftest" in sys.argv:
        text = "TIME pile 200\nHASH pile 7\nPOS 1.0 2.0\nTIME motor 50\nHASH motor 3\nTIME norm_exact 10\nTIME norm_rsqrt 20\nERR norm_rsqrt 3e-7\n"
        p = parse(text)
        assert p["time"]["pile"] == 200 and p["hash"]["motor"] == 3 and p["pos"] == [1.0, 2.0] and p["err"]["norm_rsqrt"] == 3e-7
        q = parse(text.replace("TIME pile 200", "TIME pile 100").replace("HASH pile 7", "HASH pile 8").replace("POS 1.0 2.0", "POS 1.0 2.5"))
        assert merge_min(parse(text), q)["time"]["pile"] == 100
        assert drift(q, p) == 0.5 and drift(p, p) == 0.0
        r = row("x", q, p)
        assert "(2.00x)" in r and "differs, max 5.00e-01 m" in r and r.count("identical") == 1, r
        print("numeric-cost selftest: 4 / 4")
        return
    runs = int(sys.argv[sys.argv.index("--runs") + 1]) if "--runs" in sys.argv else 1
    ref = None
    print("| build | pile 400 boxes x 120 steps | motor 2e6 | normalize 4e6 (1/sqrt) | normalize 4e6 (rsqrtps + Newton) | pile bits | motor bits |")
    print("|---|---|---|---|---|---|---|")
    err = None
    with tempfile.TemporaryDirectory() as d:
        for name, flags in VARIANTS:
            res, why = build_and_run(flags, d, runs)
            if res is None:
                print("| %s | skipped: %s |||||" % (name, why[:80]))
                continue
            if ref is None:
                ref = res
                err = res["err"].get("norm_rsqrt")
            print(row(name, res, ref))
    if err is not None:
        print()
        print("rsqrtps + one Newton step: largest relative error against 1/sqrt %.2e (f32 epsilon 1.19e-07)" % err)


if __name__ == "__main__":
    main()
