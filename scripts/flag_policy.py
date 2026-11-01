"""Floating-point flag policy check (ROADMAP 17.84; policy text in
docs/ARCHITECTURE.md §6).

    pixi run flag-policy                 # check the repository
    pixi run flag-policy -- --selftest   # each rule fires on a planted violation

The simulation's bits depend on the toolchain version, the target CPU (FMA
contraction) and -O0 (`pixi run fp-probe`, 17.76). Goldens and bitwise
parity tests are only meaningful while those stay fixed, so drift in any of
them is a policy change that must be made on purpose. Rules:

  R1  pixi.toml pins `mojo` and `modular` with `==` (no ranges).
  R2  scripts/run_tests.sh pins the x86-64 target CPU, and
      docs/ARCHITECTURE.md §6 names the same target.
  R3  no script, pixi task or CI workflow passes fast-math or an explicit
      -O level to mojo, except scripts/fp_probe.py (the probe that measures
      what those flags change).
"""

import argparse
import re
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
PROBE_EXEMPT = {"scripts/fp_probe.py", "scripts/flag_policy.py"}
PIN = re.compile(r'^\s*(mojo|modular)\s*=\s*"([^"]*)"', re.M)
TARGET = re.compile(r'TARGET_CPU=([A-Za-z0-9_-]+)')
DOC_TARGET = re.compile(r"pinned x86-64 target: `([A-Za-z0-9_-]+)`")
BAD_FLAG = re.compile(r"(fast[-_]math|ffast-math|[\"'\s]-O[0-3]\b)")
MOJO_LINE = re.compile(r"\bmojo\b")


def check(root: Path) -> list[str]:
    problems = []
    pixi = (root / "pixi.toml").read_text(encoding="utf-8")
    pins = dict(PIN.findall(pixi))
    for name in ("mojo", "modular"):
        v = pins.get(name)
        if v is None or not v.startswith("=="):
            problems.append(f"R1 pixi.toml: {name} is not pinned with == (got {v!r})")
    rt = (root / "scripts/run_tests.sh").read_text(encoding="utf-8")
    targets = TARGET.findall(rt)
    doc = (root / "docs/ARCHITECTURE.md").read_text(encoding="utf-8")
    dt = DOC_TARGET.findall(doc)
    if not targets:
        problems.append("R2 scripts/run_tests.sh: no pinned TARGET_CPU")
    elif not dt:
        problems.append("R2 docs/ARCHITECTURE.md: §6 does not name the pinned x86-64 target")
    elif dt[0] != targets[0]:
        problems.append(f"R2 target drift: run_tests.sh pins {targets[0]}, ARCHITECTURE.md §6 says {dt[0]}")
    files = [root / "pixi.toml"]
    files += sorted((root / "scripts").glob("*.sh")) + sorted((root / "scripts").glob("*.py"))
    files += sorted((root / ".github/workflows").glob("*.yml"))
    for f in files:
        rel = f.relative_to(root).as_posix()
        if rel in PROBE_EXEMPT or not f.exists():
            continue
        for n, line in enumerate(f.read_text(encoding="utf-8").splitlines(), 1):
            if line.lstrip().startswith("#"):
                continue
            if MOJO_LINE.search(line) and BAD_FLAG.search(line):
                problems.append(f"R3 {rel}:{n}: fast-math / explicit -O level passed to mojo: {line.strip()}")
    return problems


def selftest() -> int:
    good_pixi = 'mojo = "==1.2.0"\nmodular = "==26.7.0"\n'
    good_rt = 'elif [ "$(uname -m)" = "x86_64" ]; then\n    TARGET_CPU=x86-64\nfi\n'
    good_doc = "## 6. Precision\n\nThe pinned x86-64 target: `x86-64`.\n"
    cases = {
        "clean": (good_pixi, good_rt, good_doc, "", None),
        "range pin": ('mojo = ">=1.2.0"\nmodular = "==26.7.0"\n', good_rt, good_doc, "", "R1"),
        "no target": (good_pixi, "echo\n", good_doc, "", "R2"),
        "doc drift": (good_pixi, good_rt, good_doc.replace("x86-64`", "haswell`"), "", "R2"),
        "fast math": (good_pixi, good_rt, good_doc, "mojo build --fast-math tests/x.mojo\n", "R3"),
        "O0": (good_pixi, good_rt, good_doc, 'cmd = ["mojo", "run", "-O0", f]\n', "R3"),
        "comment ok": (good_pixi, good_rt, good_doc, "# mojo run -O0 is what fp_probe measures\n", None),
    }
    failed = 0
    for name, (pixi, rt, doc, extra, want) in cases.items():
        with tempfile.TemporaryDirectory() as d:
            r = Path(d)
            (r / "scripts").mkdir()
            (r / "docs").mkdir()
            (r / ".github/workflows").mkdir(parents=True)
            (r / "pixi.toml").write_text(pixi)
            (r / "scripts/run_tests.sh").write_text(rt)
            (r / "docs/ARCHITECTURE.md").write_text(doc)
            (r / "scripts/tool.py").write_text(extra)
            got = check(r)
            ok = (not got) if want is None else (len(got) == 1 and got[0].startswith(want))
            print(f"  {'ok ' if ok else 'BAD'} {name}: {got}")
            failed += 0 if ok else 1
    print("flag-policy selftest:", "PASS" if failed == 0 else f"FAIL ({failed})")
    return 1 if failed else 0


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--selftest", action="store_true")
    a = ap.parse_args()
    if a.selftest:
        return selftest()
    problems = check(ROOT)
    for p in problems:
        print("flag-policy:", p)
    print("flag-policy:", "PASS" if not problems else f"FAIL ({len(problems)} problems)")
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main())
