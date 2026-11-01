"""Run-to-run stability and per-file test time (ROADMAP 17.82).

    pixi run stability                         # every tests/test_*.mojo, twice
    pixi run stability -- tests/test_sap.mojo tests/test_rope.mojo
    pixi run stability -- --selftest

The golden gate catches "differs from the recorded run"; it cannot catch a
test whose output changes from run to run on the same commit when the golden
happens to hold one of its values. This builds each test once, runs the binary
twice, normalises both outputs with the golden tool (`scripts/golden.sh
normalize`, which drops timing lines) and reports every file whose two runs
differ. It also prints the slowest files with their run time, since the gate
keeps only one overall timeout.
"""

import argparse
import os
import subprocess
import sys
import tempfile
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent


def build(test: str, out: Path) -> bool:
    cpu = os.environ.get("LUDENS_TARGET_CPU", "x86-64")
    r = subprocess.run(
        ["mojo", "build", "--target-cpu", cpu, "-D", "ASSERT=all", "-I", "build", "-o", str(out), test],
        cwd=ROOT, capture_output=True,
    )
    return r.returncode == 0


def normalized(test: str, text: str, d: Path) -> str:
    log = d / "one.log"
    log.write_text(f"--- {test} ---\n{text}", encoding="utf-8")
    r = subprocess.run(["bash", "scripts/golden.sh", "normalize", str(log)], cwd=ROOT, capture_output=True, text=True, encoding="utf-8")
    return r.stdout


def check(tests: list[str]) -> tuple[list[str], list[tuple[float, str]], list[str]]:
    """(unstable files, (seconds, file) per file, files that did not build)."""
    unstable, times, broken = [], [], []
    with tempfile.TemporaryDirectory(prefix="stab_") as dd:
        d = Path(dd)
        for t in tests:
            exe = d / Path(t).stem
            if not build(t, exe):
                broken.append(t)
                continue
            outs = []
            for _ in range(2):
                t0 = time.monotonic()
                r = subprocess.run([str(exe)], cwd=ROOT, capture_output=True, text=True, encoding="utf-8")
                times.append((time.monotonic() - t0, t)) if not outs else None
                outs.append(normalized(t, r.stdout, d))
            if outs[0] != outs[1]:
                unstable.append(t)
    return unstable, times, broken


def report(unstable, times, broken, top: int = 15) -> int:
    for t in broken:
        print(f"stability: did not build: {t}")
    for t in unstable:
        print(f"stability: UNSTABLE (two runs differ): {t}")
    print(f"stability: slowest {min(top, len(times))} of {len(times)} files (run time, build excluded):")
    for sec, t in sorted(times, reverse=True)[:top]:
        print(f"  {sec:7.2f} s  {t}")
    print(f"stability: {'PASS' if not unstable and not broken else 'FAIL'} ({len(unstable)} unstable, {len(broken)} not built)")
    return 1 if unstable or broken else 0


def selftest() -> int:
    fx = ["tools/fixtures/stable_fixture.mojo", "tools/fixtures/unstable_fixture.mojo"]
    unstable, times, broken = check(fx)
    checks = [
        ("unstable fixture is flagged", unstable == ["tools/fixtures/unstable_fixture.mojo"], unstable),
        ("stable fixture with a timing line is not flagged", "tools/fixtures/stable_fixture.mojo" not in unstable, unstable),
        ("both fixtures timed", len(times) == 2 and not broken, (times, broken)),
    ]
    for name, ok, detail in checks:
        print(f"  [{'PASS' if ok else 'FAIL'}] stability selftest - {name} {detail}")
    n = sum(1 for _, ok, _ in checks if ok)
    print(f"[{'PASS' if n == len(checks) else 'FAIL'}] stability selftest - {n} / {len(checks)} checks")
    return 0 if n == len(checks) else 1


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("tests", nargs="*")
    ap.add_argument("--selftest", action="store_true")
    a = ap.parse_args()
    if a.selftest:
        return selftest()
    tests = a.tests or sorted(str(p.relative_to(ROOT)) for p in (ROOT / "tests").glob("test_*.mojo"))
    return report(*check(tests))


if __name__ == "__main__":
    sys.exit(main())
