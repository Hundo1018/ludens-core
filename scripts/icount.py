"""Cachegrind instruction-count probe (ROADMAP 17.83).

Wall-clock gates need a fixed host; instruction counts do not depend on the
machine's load. This script compiles `benchmarks/probes/icount_probe.mojo`
(a fixed 40-box workload), runs it under
`valgrind --tool=cachegrind --cache-sim=no` several times and reports the
instruction count ("I refs") and its spread across runs.

    pixi run icount                 # 3 runs, print counts and spread
    pixi run icount -- --runs 5
    pixi run icount -- --selftest   # parser check + detects an injected +10 %

The selftest builds the probe with -D STEPS=66 (+10 % steps) and requires
its count to exceed the baseline by more than 5 x the measured spread.
"""

import os
import re
import subprocess
import sys
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PROBE = "benchmarks/probes/icount_probe.mojo"


def cpu_flags():
    cpu = os.environ.get("LUDENS_TARGET_CPU", "")
    if not cpu and os.uname().machine == "x86_64":
        cpu = "x86-64"
    return ["--target-cpu", cpu] if cpu else []


def build(out, steps=None):
    cmd = ["mojo", "build"] + cpu_flags() + ["-I", "build"]
    if steps is not None:
        cmd += ["-D", "STEPS=%d" % steps]
    cmd += [PROBE, "-o", out]
    r = subprocess.run(cmd, cwd=ROOT, capture_output=True, text=True)
    if r.returncode != 0:
        sys.stderr.write(r.stdout + r.stderr)
        raise SystemExit("icount: build failed")


def parse_irefs(text):
    m = re.search(r"I\s+refs:\s+([\d,]+)", text)
    if not m:
        raise ValueError("no 'I refs' line in cachegrind output")
    return int(m.group(1).replace(",", ""))


def count(binary):
    with tempfile.TemporaryDirectory() as d:
        r = subprocess.run(
            ["valgrind", "--tool=cachegrind", "--cache-sim=no", "--cachegrind-out-file=" + os.path.join(d, "cg.out"), binary],
            cwd=ROOT, capture_output=True, text=True,
        )
        if r.returncode != 0:
            sys.stderr.write(r.stderr[-2000:])
            raise SystemExit("icount: valgrind run failed")
        return parse_irefs(r.stderr)


def measure(binary, runs):
    return [count(binary) for _ in range(runs)]


def main():
    runs = 3
    if "--runs" in sys.argv:
        runs = int(sys.argv[sys.argv.index("--runs") + 1])
    with tempfile.TemporaryDirectory() as d:
        base = os.path.join(d, "probe")
        build(base)
        c = measure(base, runs)
        spread = max(c) - min(c)
        print("icount: %s instructions over %d runs, spread %d (%.2e relative)" % (c[0], runs, spread, spread / c[0]))
        for v in c:
            print("  %d" % v)
        if "--selftest" in sys.argv:
            assert parse_irefs("==1== I   refs:      1,234,567\n") == 1234567
            slow = os.path.join(d, "probe66")
            build(slow, 66)
            s = count(slow)
            delta = s - max(c)
            print("icount selftest: +10 %% steps -> %d instructions (+%.2f %%), %.0f x the spread" % (s, 100.0 * (s - c[0]) / c[0], delta / max(spread, 1)))
            if delta <= 5 * max(spread, 1):
                raise SystemExit("icount selftest: injected regression not separated from the spread")
            print("icount selftest: PASS")


if __name__ == "__main__":
    main()
