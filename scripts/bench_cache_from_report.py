"""Rebuild build/bench_out/ (the per-bench cache `run_benchmarks.sh` reads with ONLY=) from the committed report.

    pixi run bench-cache                # write build/bench_out/<bench>.md for every @bench in the template
    pixi run bench-cache -- --check     # only verify that template + recovered outputs reproduce the report

`ONLY="bench_x.mojo" pixi run benchmark` reruns only the listed benches and takes the others from the cache of an
earlier full run. A fresh checkout has no cache, so without this the first ONLY= run reruns every bench (hours).
BENCHMARK_REPORT.md is the template with each `@bench` line replaced by that program's stdout and `@host` by a
two-line host block, so the outputs can be read back out: walk the template, match its literal lines against the
report, and take what sits between them as the bench's output.

The recovered outputs are checked before anything is written: template + outputs must reproduce the report byte for
byte. Blank lines next to an `@bench` line are ambiguous (template or output); either attribution renders the same
report, which is what the check enforces.
"""

import argparse
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
TEMPLATE = "scripts/benchmark_report.md.in"
REPORT = "BENCHMARK_REPORT.md"
CACHE = "build/bench_out"
HOST_LINES = 2


def _bench(line: str) -> str:
    return Path(line.split(maxsplit=1)[1].strip()).name


def recover(template: list[str], report: list[str]) -> tuple[list[tuple[list[str], list[str]]], list[str]]:
    """([(bench names, output lines)], host block lines). A group holds one bench, or several `@bench` lines that
    the template separates only by blank lines (their outputs cannot be told apart; they get no cache entry and
    are rerun). Raises ValueError where the report does not follow the template."""
    groups: list[tuple[list[str], list[str]]] = []
    host: list[str] = []
    r = 0
    t = 0
    while t < len(template):
        line = template[t]
        if line == "@host":
            host = report[r:r + HOST_LINES]
            r += HOST_LINES
            t += 1
            continue
        if line.startswith("@bench "):
            names = [_bench(line)]
            k = t + 1
            while True:  # the run of directives separated only by blank lines
                j = k
                while j < len(template) and template[j] == "":
                    j += 1
                if j < len(template) and template[j].startswith("@bench "):
                    names.append(_bench(template[j]))
                    k = j + 1
                    continue
                break
            blanks = j - k
            if j == len(template):
                end = len(report) - blanks
            else:
                anchor = template[j]
                if anchor == "@host":
                    raise ValueError(f"template line {j + 1}: @host right after @bench")
                end = r
                while end < len(report) and report[end] != anchor:
                    end += 1
                if end == len(report):
                    raise ValueError(f"template line {j + 1} not found in the report after {names[-1]}")
                end -= blanks
            groups.append((names, report[r:end]))
            r = end
            t = k
            continue
        if r >= len(report) or report[r] != line:
            got = report[r] if r < len(report) else "<end of report>"
            raise ValueError(f"template line {t + 1} {line!r} does not match report line {r + 1} {got!r}")
        r += 1
        t += 1
    if r != len(report):
        raise ValueError(f"report has {len(report) - r} lines after the end of the template")
    return groups, host


def render(template: list[str], groups: list[tuple[list[str], list[str]]], host: list[str]) -> list[str]:
    """The report from the template with each group's output in place of its directives (blank lines between the
    directives of one group belong to the output)."""
    res = []
    g = iter(groups)
    t = 0
    while t < len(template):
        line = template[t]
        if line == "@host":
            res += host
        elif line.startswith("@bench "):
            names, lines = next(g)
            res += lines
            seen = 1
            while seen < len(names):  # skip the rest of the group in the template
                t += 1
                if template[t].startswith("@bench "):
                    seen += 1
        else:
            res.append(line)
        t += 1
    return res


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--check", action="store_true", help="verify only, write nothing")
    a = ap.parse_args()
    template = (ROOT / TEMPLATE).read_text(encoding="utf-8").splitlines()
    report = (ROOT / REPORT).read_text(encoding="utf-8").splitlines()
    try:
        groups, host = recover(template, report)
    except ValueError as e:
        print(f"bench-cache: {e}")
        print("the report is out of step with the template; run the full `pixi run benchmark` once instead")
        return 1
    if render(template, groups, host) != report:
        print("bench-cache: template + recovered outputs do not reproduce the report")
        return 1
    single = [(n[0], lines) for n, lines in groups if len(n) == 1]
    joint = [name for n, _ in groups if len(n) > 1 for name in n]
    if a.check:
        print(f"bench-cache: {len(single)} bench outputs recovered, {len(joint)} adjacent ones not separable; "
              f"they reproduce {REPORT}")
        return 0
    cache = ROOT / CACHE
    cache.mkdir(parents=True, exist_ok=True)
    for name, lines in single:
        (cache / f"{name}.md").write_text("".join(l + "\n" for l in lines), encoding="utf-8")
        print(f"  {name}")
    print(f"bench-cache: wrote {len(single)} files to {CACHE}/ (from {REPORT})")
    if joint:
        print(f"not cached (adjacent @bench lines, outputs not separable; ONLY= reruns them): {' '.join(joint)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
