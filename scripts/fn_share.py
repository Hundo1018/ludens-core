"""Function-level instruction shares of a Mojo probe under callgrind (ROADMAP 17.98: upper bounds before a change).

Builds the probe for x86-64 (`-I build`, so run `pixi run build` first), runs it under
`valgrind --tool=callgrind`, and prints, for each function whose demangled name contains one of the given
substrings, its inclusive and self instruction counts and their shares of the program total.

    pixi run python scripts/fn_share.py benchmarks/probes/joint_probe.mojo joint_sweep ext_sweep joint_axis
    pixi run python scripts/fn_share.py PROBE NAME ... --self-only

Self cost is what a change confined to that function's own body (not its callees) can save at most.
"""
import os
import re
import subprocess
import sys
import tempfile

ROW = re.compile(r"\s*([\d,]+)\s+\(\s*([\d.]+)%\)\s+(.*)")
TOTAL = re.compile(r"\s*([\d,]+)\s+(\(\s*[\d.]+%\))?\s*PROGRAM TOTALS")


def annotate(out, inclusive):
    args = ["callgrind_annotate", "--threshold=100", out]
    if inclusive:
        args.insert(1, "--inclusive=yes")
    return subprocess.run(args, check=True, capture_output=True, text=True).stdout


def rows(text, names):
    total, found = None, {}
    for line in text.splitlines():
        m = TOTAL.match(line)
        if m:
            total = int(m.group(1).replace(",", ""))
            continue
        m = ROW.match(line)
        if m:
            fn = m.group(3)
            for n in names:
                if n in fn:
                    found[fn] = found.get(fn, 0) + int(m.group(1).replace(",", ""))
    return total, found


def profile(probe, names):
    with tempfile.TemporaryDirectory() as d:
        exe = os.path.join(d, "probe")
        subprocess.run(["mojo", "build", "--target-cpu", "x86-64", "-I", "build", probe, "-o", exe], check=True)
        out = os.path.join(d, "cg.out")
        subprocess.run(["valgrind", "--tool=callgrind", "--callgrind-out-file=" + out, exe], check=True, capture_output=True)
        total, incl = rows(annotate(out, True), names)
        _, own = rows(annotate(out, False), names)
    return total, incl, own


def main():
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    if len(args) < 1:
        raise SystemExit(__doc__)
    probe, names = args[0], args[1:] or ["NOSUCHFUNCTION"]
    total, incl, own = profile(probe, names)
    print("total instructions:", total)
    print("%14s %8s %14s %8s  function" % ("inclusive", "%", "self", "%"))
    for fn in sorted(set(incl) | set(own), key=lambda f: -incl.get(f, 0)):
        i, s = incl.get(fn, 0), own.get(fn, 0)
        print("%14d %7.3f%% %14d %7.3f%%  %s" % (i, 100.0 * i / total, s, 100.0 * s / total, fn[:120]))


if __name__ == "__main__":
    main()
