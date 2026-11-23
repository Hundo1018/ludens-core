"""Reproducible-build probe (ROADMAP 17.81).

Builds every package twice from the same commit (`pixi run build`, which
precompiles into build/) and compares the SHA-256 of each build/*.mojoc
between the two runs. Prints one line per package and exits non-zero if
any differs.

    pixi run repro-probe           # two builds, compare
    pixi run repro-probe -- --selftest

The selftest checks the comparison on synthetic hash maps (equal, one
differing, one missing) without building.
"""

import hashlib
import os
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BUILD = os.path.join(ROOT, "build")


def hashes():
    out = {}
    for name in sorted(os.listdir(BUILD)):
        if name.endswith(".mojoc"):
            with open(os.path.join(BUILD, name), "rb") as f:
                out[name] = hashlib.sha256(f.read()).hexdigest()
    return out


def build():
    r = subprocess.run(["bash", "scripts/build_engine.sh"], cwd=ROOT, capture_output=True, text=True, check=False)
    if r.returncode != 0:
        sys.stderr.write(r.stdout + r.stderr)
        raise SystemExit("repro-probe: build failed")


def compare(a, b):
    """Return (same, differing, missing) package lists."""
    same, diff, missing = [], [], []
    for k in sorted(set(a) | set(b)):
        if k not in a or k not in b:
            missing.append(k)
        elif a[k] == b[k]:
            same.append(k)
        else:
            diff.append(k)
    return same, diff, missing


def selftest():
    s, d, m = compare({"a": "1", "b": "2"}, {"a": "1", "b": "2"})
    assert s == ["a", "b"] and not d and not m
    s, d, m = compare({"a": "1", "b": "2"}, {"a": "1", "b": "3"})
    assert s == ["a"] and d == ["b"] and not m
    s, d, m = compare({"a": "1"}, {"a": "1", "c": "9"})
    assert m == ["c"]
    print("repro-probe selftest: 3 / 3")


def main():
    if "--selftest" in sys.argv:
        selftest()
        return
    build()
    first = hashes()
    build()
    second = hashes()
    same, diff, missing = compare(first, second)
    for k in same:
        print("  same     %s  %s" % (k, first[k][:16]))
    for k in diff:
        print("  DIFFERS  %s  %s vs %s" % (k, first[k][:16], second[k][:16]))
    for k in missing:
        print("  MISSING  %s" % k)
    print("repro-probe: %d same, %d differ, %d missing" % (len(same), len(diff), len(missing)))
    if diff or missing:
        raise SystemExit(1)


if __name__ == "__main__":
    main()
