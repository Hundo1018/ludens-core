"""Seed sweeps over the randomised tests (ROADMAP 17.82).

    pixi run fuzz                                   # default set, seeds 1..200
    pixi run fuzz -- --seeds 1000:2000 tests/test_sap.mojo
    pixi run fuzz -- --selftest

Each listed test reads its seed through `harness.runner.fuzz_seed(default)`,
which returns `LUDENS_SEED` when it is set. This runner builds each test ONCE
(`mojo build`) and runs the binary per seed, so a sweep costs one compile plus
N short runs. A failing seed is printed with the command that reproduces it;
the exit code is 1 when any seed failed.
"""

import argparse
import os
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
DEFAULT_TESTS = [
    "tests/test_sap.mojo",
    "tests/test_lbvh.mojo",
    "tests/test_predicates.mojo",
    "tests/test_laws.mojo",
]


def parse_range(r: str) -> range:
    a, _, b = r.partition(":")
    return range(int(a), int(b) + 1)


def build(test: str, out: Path) -> None:
    cpu = os.environ.get("LUDENS_TARGET_CPU", "x86-64")
    subprocess.run(
        ["mojo", "build", "--target-cpu", cpu, "-D", "ASSERT=all", "-I", "build", "-o", str(out), test],
        cwd=ROOT, check=True, capture_output=True,
    )


def sweep(binary: Path, seeds: range) -> list[tuple[int, str]]:
    fails = []
    for seed in seeds:
        r = subprocess.run([str(binary)], cwd=ROOT, capture_output=True, text=True, encoding="utf-8",
                           env={**os.environ, "LUDENS_SEED": str(seed)})
        if r.returncode != 0:
            tail = [l for l in (r.stdout + r.stderr).splitlines() if "FAIL" in l][:3]
            fails.append((seed, " | ".join(tail)))
    return fails


def run(tests: list[str], seeds: range) -> int:
    bad = 0
    with tempfile.TemporaryDirectory(prefix="fuzz_") as d:
        for t in tests:
            exe = Path(d) / Path(t).stem
            build(t, exe)
            fails = sweep(exe, seeds)
            bad += len(fails)
            print(f"fuzz: {t}: {len(seeds) - len(fails)}/{len(seeds)} seeds pass")
            for seed, why in fails:
                print(f"fuzz:   seed {seed} FAILED: {why}")
                print(f"fuzz:   reproduce: LUDENS_SEED={seed} pixi run mojo run -D ASSERT=all -I build {t}")
    print(f"fuzz: {'PASS' if bad == 0 else 'FAIL'} ({bad} failing seeds)")
    return 1 if bad else 0


def selftest() -> int:
    """A fixture whose check fails exactly when seed % 7 == 3 must be reported
    for seeds 3 and 10 in 1..12 and for nothing in 4..9."""
    fixture = ROOT / "tools/fixtures/fuzz_fixture.mojo"
    with tempfile.TemporaryDirectory(prefix="fuzz_self_") as d:
        exe = Path(d) / "fx"
        build(str(fixture), exe)
        got = [s for s, _ in sweep(exe, range(1, 13))]
        clean = sweep(exe, range(4, 10))
    checks = [
        ("planted failures found exactly (seeds 3, 10)", got == [3, 10], got),
        ("clean range reports nothing", clean == [], clean),
    ]
    for name, ok, detail in checks:
        print(f"  [{'PASS' if ok else 'FAIL'}] fuzz selftest - {name} {detail}")
    n = sum(1 for _, ok, _ in checks if ok)
    print(f"[{'PASS' if n == len(checks) else 'FAIL'}] fuzz selftest - {n} / {len(checks)} checks")
    return 0 if n == len(checks) else 1


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("tests", nargs="*")
    ap.add_argument("--seeds", default="1:200")
    ap.add_argument("--selftest", action="store_true")
    a = ap.parse_args()
    if a.selftest:
        return selftest()
    return run(a.tests or DEFAULT_TESTS, parse_range(a.seeds))


if __name__ == "__main__":
    sys.exit(main())
