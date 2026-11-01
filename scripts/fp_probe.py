"""Floating-point factor probe (ROADMAP 17.76).

Which compiler / target factors change simulation bits? Compiles
`benchmarks/probes/fp_probe.mojo` (three scenes, 300 steps) under each
variant, runs it, and compares each scene's state hash and largest
coordinate drift against the reference (x86-64, default optimisation).

Variants: CPU targets (x86-64 baseline without FMA, x86-64-v3 / haswell,
x86-64, skylake, skylake-avx512, the host CPU) and optimisation levels -O0 .. -O3.
A target the host cannot run is skipped.

    pixi run fp-probe
    pixi run fp-probe -- --check            # fail if a variant drifts past TOLERANCE
    pixi run fp-probe -- --dump out.json    # this host's native build, for another platform
    pixi run fp-probe -- --compare in.json  # a dump from another platform vs this host
    pixi run fp-probe -- --selftest         # parser / tolerance check on synthetic data

Cross-target tolerance table (`TOLERANCE`, largest coordinate drift after
300 steps, m): from the measured drift of the variants that change bits on
x86-64 (2026-10-13: no FMA 6.65e-3 / 1.07e-6 / 3.05e-7, -O0 7.20e-3 /
9.55e-7 / 1.43e-6 for pile / roll / tower) with about 3x (pile) and 10x
(single bodies) headroom. The pile is chaotic (40 boxes settling: a
different contraction reorders who lands first), so its bound is mm-scale;
a single rolling ball and a tower are not, so theirs stay at 1e-5. Another
architecture (aarch64 always contracts to FMA, but where is up to the
compiler) is held to the same table through `--dump` / `--compare`.
"""

import json
import os
import subprocess
import sys
import tempfile

TOLERANCE = {"pile": 2e-2, "roll": 1e-5, "tower": 1e-5}

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PROBE = "benchmarks/probes/fp_probe.mojo"

VARIANTS = [
    ("x86-64 -O (reference: no FMA, SSE2)", ["--target-cpu", "x86-64"]),
    ("x86-64 -O0", ["--target-cpu", "x86-64", "-O0"]),
    ("x86-64 -O1", ["--target-cpu", "x86-64", "-O1"]),
    ("x86-64 -O2", ["--target-cpu", "x86-64", "-O2"]),
    ("skylake (AVX2 + FMA: the speed variant)", ["--target-cpu", "skylake"]),
    ("haswell (AVX2 + FMA)", ["--target-cpu", "haswell"]),
    ("skylake-avx512", ["--target-cpu", "skylake-avx512"]),
    ("native host CPU", []),
]


def parse(text):
    """{scene: (hash, [floats])}"""
    out = {}
    lines = text.strip().split("\n")
    for i, l in enumerate(lines):
        if l.startswith("HASH "):
            _, name, h = l.split()
            vals = [float(x) for x in lines[i + 1].split()[1:]]
            out[name] = (int(h), vals)
    return out


def run(flags, d):
    exe = os.path.join(d, "fp")
    b = subprocess.run(["mojo", "build"] + flags + ["-I", "build", PROBE, "-o", exe], cwd=ROOT, capture_output=True, text=True)
    if b.returncode != 0:
        return None, b.stderr.strip().split("\n")[-1]
    r = subprocess.run([exe], cwd=ROOT, capture_output=True, text=True)
    if r.returncode != 0:
        return None, "run failed: " + r.stderr.strip()[-200:]
    return parse(r.stdout), ""


def drift(res, ref, scene):
    h, vals = res[scene]
    rh, rvals = ref[scene]
    if h == rh:
        return 0.0
    return max(abs(a - b) for a, b in zip(vals, rvals))


def over(res, ref):
    """Scenes whose drift exceeds TOLERANCE."""
    return [s for s in TOLERANCE if drift(res, ref, s) > TOLERANCE[s]]


def main():
    if "--selftest" in sys.argv:
        p = parse("HASH a 42\na 1.0 2.5\nHASH b 7\nb 3.0\n")
        assert p["a"] == (42, [1.0, 2.5]) and p["b"] == (7, [3.0])
        ref = {"pile": (1, [0.0]), "roll": (2, [0.0]), "tower": (3, [0.0])}
        ok = {"pile": (9, [0.01]), "roll": (2, [0.0]), "tower": (8, [5e-6])}
        bad = {"pile": (1, [0.0]), "roll": (9, [2e-5]), "tower": (3, [0.0])}
        assert over(ok, ref) == [] and over(bad, ref) == ["roll"]
        print("fp-probe selftest: 3 / 3")
        return
    if "--dump" in sys.argv or "--compare" in sys.argv:
        with tempfile.TemporaryDirectory() as d:
            res, err = run([], d)
            if res is None:
                sys.exit("fp-probe: native build failed: " + err)
        if "--dump" in sys.argv:
            path = sys.argv[sys.argv.index("--dump") + 1]
            with open(path, "w") as f:
                json.dump({k: [v[0], v[1]] for k, v in res.items()}, f)
            print("fp-probe: wrote", path)
            return
        path = sys.argv[sys.argv.index("--compare") + 1]
        with open(path) as f:
            other = {k: (v[0], v[1]) for k, v in json.load(f).items()}
        print("| scene | drift vs dump | tolerance |")
        print("|---|---|---|")
        for scene in TOLERANCE:
            print("| %s | %.2e | %.0e |" % (scene, drift(res, other, scene), TOLERANCE[scene]))
        bad = over(res, other)
        if bad:
            sys.exit("fp-probe: over tolerance: " + ", ".join(bad))
        return
    check = "--check" in sys.argv
    failed = []
    with tempfile.TemporaryDirectory() as d:
        ref = None
        family_same = True  # every x86-64 (no FMA) variant is bit-identical to the reference
        fma_differs = False
        print("| variant | pile | roll | tower |")
        print("|---|---|---|---|")
        for name, flags in VARIANTS:
            res, err = run(flags, d)
            if res is None:
                print("| %s | skipped: %s | | |" % (name, err[:60]))
                continue
            if ref is None:
                ref = res
            for sc in over(res, ref):
                failed.append(name + " " + sc)
            cells = []
            for scene in ("pile", "roll", "tower"):
                h, vals = res[scene]
                rh, rvals = ref[scene]
                if h == rh:
                    cells.append("identical")
                else:
                    if flags[:2] == ["--target-cpu", "x86-64"]:
                        family_same = False
                    else:
                        fma_differs = True
                    dr = max(abs(a - b) for a, b in zip(vals, rvals))
                    cells.append("differs, max drift %.2e" % dr)
            print("| %s | %s |" % (name, " | ".join(cells)))
        print()
        if family_same:
            print("verdict: FMA is not a bit factor of the reference build -- every x86-64 variant (-O0 .. -O2) "
                  "is bit-identical to it; FMA changes bits only in the speed variants%s." % (" (listed above)" if fma_differs else ""))
        else:
            print("verdict: an x86-64 variant differs from the reference -- the reference build is NOT optimisation-independent")
            failed.append("x86-64 family")
        if check and failed:
            sys.exit("fp-probe: over tolerance: " + "; ".join(failed))


if __name__ == "__main__":
    main()
