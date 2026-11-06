#!/usr/bin/env python3
"""17.91: hand a world between two separately built programs (the second has extra code) and compare hashes.

Run: pixi run python scripts/xfer_probe.py"""
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
OUT = ROOT / "build/xfer"
BEFORE, AFTER = 60, 120


def mojo(*args: str) -> str:
    proc = subprocess.run(["mojo", *args], cwd=ROOT, capture_output=True, text=True)
    if proc.returncode:
        sys.exit(proc.stdout + proc.stderr)
    return proc.stdout


def main() -> int:
    OUT.mkdir(parents=True, exist_ok=True)
    src = "experiments/xfer_probe.mojo"
    mojo("build", "--target-cpu", "x86-64", "-I", "build", src, "-o", str(OUT / "a"))
    mojo("build", "--target-cpu", "x86-64", "-I", "build", "-D", "XFER_EXTRA=True", src, "-o", str(OUT / "b"))
    blob = str(OUT / "world.blob")
    ref = subprocess.run([str(OUT / "a"), "save", blob, str(BEFORE), str(AFTER)], capture_output=True, text=True, check=True).stdout
    got = subprocess.run([str(OUT / "b"), "load", blob, str(AFTER)], capture_output=True, text=True, check=True).stdout
    h_ref = ref.split()[-1]
    h_got = got.split()[-1]
    sz = (OUT / "world.blob").stat().st_size
    print(f"blob {sz} bytes; uninterrupted {h_ref}; after swap into build B (extra code) {h_got}")
    print("transfer across builds:", "PASS" if h_ref == h_got else "FAIL")
    return 0 if h_ref == h_got else 1


if __name__ == "__main__":
    sys.exit(main())
