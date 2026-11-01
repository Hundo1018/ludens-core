"""Engine packages take sin / cos from geometry.trig, not std.math (ROADMAP 17.89, #75).

    pixi run trig-check [-- --selftest]

libm's sin / cos differ between glibc, musl and a browser, so one call to `std.math.sin` in the engine
breaks bit-identity between a native build and the wasm module. `geometry/trig.mojo` is the one
place allowed to import them (for non-f32 types).
"""

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
PACKAGES = "diag geometry numerics spatial procedural fluid ecs scheduler collision nav physics ai gameplay embed".split()
ALLOWED = {"geometry/trig.mojo"}
IMPORT = re.compile(r"^\s*from\s+std\.math\s+import\s+(.+)$", re.M)
QUALIFIED = re.compile(r"\bstd\.math\.(sin|cos)\b")


def violations(text: str) -> list[str]:
    bad = []
    for m in IMPORT.finditer(text):
        names = {n.strip().split(" as ")[0] for n in m.group(1).split(",")}
        bad += sorted(names & {"sin", "cos", "sincos"})
    bad += [m.group(1) for m in QUALIFIED.finditer(text)]
    return bad


def selftest() -> int:
    cases = [
        ("from std.math import sqrt, cos\n", ["cos"]),
        ("    from std.math import sin as s\n", ["sin"]),
        ("from std.math import sqrt, floor\nfrom geometry.trig import sin, cos\n", []),
        ("x = std.math.sin(1.0)\n", ["sin"]),
    ]
    ok = all(violations(t) == want for t, want in cases)
    print(f"[{'PASS' if ok else 'FAIL'}] trig-check selftest - {len(cases)} cases")
    return 0 if ok else 1


def main() -> int:
    if "--selftest" in sys.argv:
        return selftest()
    bad = []
    for pk in PACKAGES:
        for f in sorted((ROOT / pk).rglob("*.mojo")):
            rel = f.relative_to(ROOT).as_posix()
            if rel in ALLOWED:
                continue
            v = violations(f.read_text(encoding="utf-8"))
            if v:
                bad.append(f"{rel}: std.math {', '.join(v)}")
    if bad:
        print("trig-check: engine code must use geometry.trig:\n  " + "\n  ".join(bad))
        return 1
    print("trig-check: OK (no std.math sin / cos in engine packages)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
