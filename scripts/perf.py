"""Performance governance for the benchmarks (ROADMAP 17.83).

    pixi run perf -- collect [--reps 3] [--only bench_foo] [-o build/perf/run.json]
    pixi run perf -- compare BASELINE.json CURRENT.json
    pixi run perf -- slopes RUN.json            # log-log slope vs scripts/perf_slopes.toml
    pixi run perf -- governance                 # template <-> bench files <-> report
    pixi run perf -- budgets RUN.json          # canonical-scene budgets (scripts/perf_budgets.json)
    pixi run perf -- budgets RUN.json --register 'substring' ...   # (re)register at median x 1.2
    pixi run perf -- bisect-check --bench bench_foo --baseline B.json  # exit code for `git bisect run`
    pixi run perf -- selftest

Data model. `collect` runs each `benchmarks/bench_*.mojo` `--reps` times and
parses every standard `BenchTable` table it prints (`### title` + the
`| variant | N | op | ns/op | ...` header) into rows keyed
`bench :: table :: variant :: N :: op`, each holding the list of ns/op
samples, plus a host fingerprint (CPU model, logical cores, compile target,
toolchain pins, world scalar type). Tables in any other format are counted as
unparsed, not guessed at.

Comparison. Two runs compare only when their fingerprints match; otherwise
`compare` refuses (exit 2) instead of reporting differences between machines.
Per row the noise is the larger relative spread (max - min) / median of the
two sample sets, floored at 3 %. A row regresses when the current median
exceeds the baseline median by more than 3 x noise; a row whose noise is above
50 % is reported as undecidable, never as a pass.

Slopes. For each (bench, table, variant, op) with at least three distinct N
the least-squares slope of log(ns/op) against log(N) is the measured exponent
of the cost of one op at size N (a BenchTable op is one step / frame / query
over the whole N-sized problem); `scripts/perf_slopes.toml` declares the
expected exponent per table and a row fails when the measured one exceeds it
by more than 0.25 (an O(n^2) bookkeeping loop in an O(n) step shows up as ~2
vs 1).
"""

import argparse
import json
import math
import os
import platform
import re
import statistics
import subprocess
import sys
import tempfile
import tomllib
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
TEMPLATE = "scripts/benchmark_report.md.in"
REPORT = "BENCHMARK_REPORT.md"
SLOPES = "scripts/perf_slopes.toml"
NOISE_FLOOR = 0.03
NOISE_K = 3.0
UNDECIDABLE = 0.50
SLOPE_TOL = 0.25
HEADER = re.compile(r"^\|\s*variant\s*\|\s*N\s*\|\s*op\s*\|\s*ns/op\s*\|")


# ------------------------------------------------------------------ parsing


def parse_tables(bench: str, text: str) -> tuple[dict[str, float], int]:
    """{key: ns/op} for every standard table in one bench's stdout, plus the
    number of other markdown tables (headers that are not BenchTable's)."""
    rows: dict[str, float] = {}
    unparsed = 0
    title = ""
    in_std = False
    prev_table_line = False
    for line in text.splitlines():
        if line.startswith("### "):
            title = line[4:].strip()
            in_std = False
            continue
        is_table = line.startswith("|")
        if is_table and not prev_table_line:
            in_std = bool(HEADER.match(line))
            if not in_std:
                unparsed += 1
        prev_table_line = is_table
        if not (is_table and in_std):
            continue
        cells = [c.strip() for c in line.strip().strip("|").split("|")]
        if len(cells) < 4 or cells[0] in ("variant",) or set(cells[0]) <= set("-:"):
            continue
        try:
            n = int(cells[1])
            ns = float(cells[3])
        except ValueError:
            continue
        key = f"{bench} :: {title} :: {cells[0]} :: {n} :: {cells[2]}"
        rows[key] = ns
    return rows, unparsed


# -------------------------------------------------------------- fingerprint


def fingerprint() -> dict[str, str]:
    cpu = platform.processor() or "unknown"
    try:
        for line in Path("/proc/cpuinfo").read_text().splitlines():
            if line.startswith("model name"):
                cpu = line.split(":", 1)[1].strip()
                break
    except OSError:
        pass
    pins = {}
    for line in (ROOT / "pixi.toml").read_text(encoding="utf-8").splitlines():
        m = re.match(r'^(mojo|modular)\s*=\s*"([^"]+)"', line)
        if m:
            pins[m.group(1)] = m.group(2)
    real = "unknown"
    m = re.search(r"comptime Real\b[^=]*=\s*([A-Za-z0-9_\[\]. ]+)", (ROOT / "geometry/vec.mojo").read_text(encoding="utf-8"))
    if m:
        real = m.group(1).strip()
    return {
        "cpu": cpu,
        "logical_cores": str(os.cpu_count()),
        "target_cpu": os.environ.get("LUDENS_TARGET_CPU", "host"),
        "mojo": pins.get("mojo", "?"),
        "modular": pins.get("modular", "?"),
        "real": real,
    }


# ------------------------------------------------------------------ collect


def run_bench(path: Path, target_cpu: str | None) -> str:
    cmd = ["mojo", "run"]
    if target_cpu:
        cmd += ["--target-cpu", target_cpu]
    cmd += ["-I", "build", str(path)]
    for _ in range(2):  # same teardown-crash safety net as run_benchmarks.sh
        r = subprocess.run(cmd, cwd=ROOT, capture_output=True, text=True, encoding="utf-8", check=False)
        if r.returncode == 0:
            return r.stdout
    raise SystemExit(f"perf: {path} kept failing:\n{r.stderr[-2000:]}")


def collect(reps: int, only: list[str], out: Path) -> int:
    fp = fingerprint()
    target = os.environ.get("LUDENS_TARGET_CPU")
    benches = sorted((ROOT / "benchmarks").glob("bench_*.mojo"))
    if only:
        benches = [b for b in benches if b.stem in only]
    samples: dict[str, list[float]] = {}
    unparsed = {}
    for b in benches:
        for _ in range(reps):
            rows, un = parse_tables(b.stem, run_bench(b, target))
            unparsed[b.stem] = un
            for k, v in rows.items():
                samples.setdefault(k, []).append(v)
        print(f"perf: {b.stem}: {sum(1 for k in samples if k.startswith(b.stem + ' ::'))} rows, {unparsed[b.stem]} non-standard tables")
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(json.dumps({"fingerprint": fp, "reps": reps, "rows": samples, "unparsed": unparsed}, indent=1, sort_keys=True), encoding="utf-8")
    print(f"perf: wrote {out} ({len(samples)} rows from {len(benches)} benches)")
    return 0


# ------------------------------------------------------------------ compare


def spread(xs: list[float]) -> float:
    med = statistics.median(xs)
    return (max(xs) - min(xs)) / med if med > 0 else 0.0


def compare_runs(base: dict, cur: dict) -> tuple[int, list[str]]:
    """(exit code, lines). 0 pass, 1 regression or undecidable, 2 refused."""
    if base["fingerprint"] != cur["fingerprint"]:
        diff = {k: (base["fingerprint"].get(k), cur["fingerprint"].get(k)) for k in set(base["fingerprint"]) | set(cur["fingerprint"]) if base["fingerprint"].get(k) != cur["fingerprint"].get(k)}
        return 2, [f"REFUSED: host fingerprints differ {diff}"]
    lines = []
    worst = 0
    for key in sorted(set(base["rows"]) & set(cur["rows"])):
        b, c = base["rows"][key], cur["rows"][key]
        noise = max(spread(b), spread(c), NOISE_FLOOR)
        mb, mc = statistics.median(b), statistics.median(c)
        ratio = mc / mb if mb > 0 else 1.0
        if noise > UNDECIDABLE:
            lines.append(f"UNDECIDABLE {key}: noise {noise:.0%}")
            worst = max(worst, 1)
        elif ratio > 1 + NOISE_K * noise:
            lines.append(f"REGRESSION {key}: {mb:.2f} -> {mc:.2f} ns/op (x{ratio:.3f}, noise {noise:.1%})")
            worst = max(worst, 1)
    for key in sorted(set(cur["rows"]) - set(base["rows"])):
        lines.append(f"NEW (no baseline) {key}")
        worst = max(worst, 1)
    for key in sorted(set(base["rows"]) - set(cur["rows"])):
        lines.append(f"MISSING {key}")
        worst = max(worst, 1)
    return worst, lines


# ------------------------------------------------------------------- slopes


def fit_slope(points: list[tuple[int, float]]) -> float:
    xs = [math.log(n) for n, _ in points]
    ys = [math.log(ns) for n, ns in points]
    mx, my = statistics.fmean(xs), statistics.fmean(ys)
    den = sum((x - mx) ** 2 for x in xs)
    return sum((x - mx) * (y - my) for x, y in zip(xs, ys, strict=True)) / den if den > 0 else 0.0


def slopes(run: dict, declared: dict[str, float]) -> tuple[int, list[str]]:
    groups: dict[str, list[tuple[int, float]]] = {}
    for key, xs in run["rows"].items():
        bench, table, variant, n, op = key.split(" :: ")
        # benches often repeat the size in the variant label ("brute N=128");
        # drop it so the sizes of one variant form one series
        variant = " ".join(re.sub(r"\bN\s*=\s*\d+", "", variant).split())
        groups.setdefault(f"{bench} :: {table} :: {variant} :: {op}", []).append((int(n), statistics.median(xs)))
    lines, rc = [], 0
    for g, pts in sorted(groups.items()):
        if len({n for n, _ in pts}) < 3:
            continue
        # the most specific declaration wins: a key naming the variant
        # ("bench :: table :: variant") over one naming only the table
        hits = [k for k in declared if k in g]
        want = declared[max(hits, key=len)] if hits else None
        s = fit_slope(sorted(pts))
        if want is None:
            lines.append(f"undeclared  {g}: measured {s:.2f}")
        elif s > want + SLOPE_TOL:
            lines.append(f"SLOPE FAIL  {g}: measured {s:.2f}, declared {want}")
            rc = 1
        else:
            lines.append(f"ok          {g}: measured {s:.2f}, declared {want}")
    return rc, lines


def load_slopes() -> dict[str, float]:
    f = ROOT / SLOPES
    if not f.exists():
        return {}
    return {k: float(v) for k, v in tomllib.loads(f.read_text(encoding="utf-8")).get("slopes", {}).items()}


# ------------------------------------------------------------------ budgets

BUDGETS = "scripts/perf_budgets.json"


def check_budgets(run: dict, book: dict) -> tuple[int, list[str]]:
    """Each budget row: the run's median must stay under `budget_ns` x (1 +
    the run's own noise for that row). Budgets belong to one host; another
    host is refused (exit 2)."""
    if book.get("fingerprint") != run["fingerprint"]:
        return 2, [f"REFUSED: budgets were registered on {book.get('fingerprint')}, this run is {run['fingerprint']}"]
    lines, rc = [], 0
    for key, budget in sorted(book["budgets"].items()):
        xs = run["rows"].get(key)
        if xs is None:
            lines.append(f"MISSING {key}")
            rc = 1
            continue
        med = statistics.median(xs)
        allow = budget * (1 + spread(xs))
        if med > allow:
            lines.append(f"OVER BUDGET {key}: {med:.0f} ns > {budget:.0f} ns (+{spread(xs):.0%} noise band)")
            rc = 1
        else:
            lines.append(f"ok {key}: {med:.0f} / {budget:.0f} ns")
    return rc, lines


def register_budgets(run: dict, patterns: list[str]) -> dict:
    rows = {k: round(statistics.median(v) * 1.2) for k, v in run["rows"].items() if any(p in k for p in patterns)}
    return {"fingerprint": run["fingerprint"], "rule": "median x 1.2 at registration", "budgets": rows}


# --------------------------------------------------------------- governance


def governance(root: Path) -> list[str]:
    """Template @bench lines vs bench files vs report sections."""
    problems = []
    tmpl = (root / TEMPLATE).read_text(encoding="utf-8").splitlines()
    cited = [l[len("@bench "):].strip() for l in tmpl if l.startswith("@bench ")]
    files = sorted(str(p.relative_to(root)) for p in (root / "benchmarks").glob("bench_*.mojo"))
    for f in sorted(set(files) - set(cited)):
        problems.append(f"bench not in the report template: {f}")
    for f in sorted(set(cited) - set(files)):
        problems.append(f"template cites a missing bench: {f}")
    dup = sorted({c for c in cited if cited.count(c) > 1})
    for f in dup:
        problems.append(f"template cites a bench twice: {f}")
    rep = root / REPORT
    if rep.exists():
        text = rep.read_text(encoding="utf-8")
        for l in tmpl:
            if l.startswith("## ") and l not in text:
                problems.append(f"report is missing template section '{l[3:]}' (regenerate with `pixi run benchmark`)")
    else:
        problems.append(f"{REPORT} does not exist")
    return problems


# ------------------------------------------------------------------ selftest


def selftest() -> int:
    fails = 0

    def ok(name: str, cond: bool, detail=""):
        nonlocal fails
        fails += 0 if cond else 1
        print(f"  [{'PASS' if cond else 'FAIL'}] perf selftest - {name} {detail}")

    out = """### Table A
| variant | N | op | ns/op | Mops/s | total ms |
|---|---:|---|---:|---:|---:|
| fast | 10 | step | 5.00 | 200.00 | 0.05 |
| fast | 100 | step | 5.10 | 196.08 | 0.51 |

| custom | x |
|---|---|
| a | 1 |
"""
    rows, un = parse_tables("bench_x", out)
    ok("parse standard table", rows == {"bench_x :: Table A :: fast :: 10 :: step": 5.0, "bench_x :: Table A :: fast :: 100 :: step": 5.1}, str(rows))
    ok("count non-standard table", un == 1, str(un))

    fp = {"cpu": "X", "logical_cores": "4", "target_cpu": "x86-64-v3", "mojo": "1", "modular": "1", "real": "Float32"}
    k = "b :: t :: v :: 10 :: op"
    base = {"fingerprint": fp, "rows": {k: [100.0, 101.0, 100.5]}}
    rc, _ = compare_runs(base, {"fingerprint": fp, "rows": {k: [100.2, 100.9, 100.4]}})
    ok("no change passes", rc == 0)
    rc, lines = compare_runs(base, {"fingerprint": fp, "rows": {k: [120.0, 121.0, 120.4]}})
    ok("injected +20% is caught", rc == 1 and "REGRESSION" in lines[0], str(lines))
    # Detection levels at this row's 3 % noise floor (measured 2026-10-27): +10 % and +25 % are
    # caught; +5 % is not. The +5 % check pins that boundary so a threshold change shows up here.
    for pct, caught in ((10, True), (25, True), (5, False)):
        f = 1 + pct / 100
        rc, lines = compare_runs(base, {"fingerprint": fp, "rows": {k: [100.0 * f, 101.0 * f, 100.5 * f]}})
        hit = rc == 1 and any("REGRESSION" in l for l in lines)
        ok(f"injected +{pct}% at 3% noise is {'caught' if caught else 'not caught (measured boundary)'}", hit == caught, str(lines))
    rc, lines = compare_runs(base, {"fingerprint": fp, "rows": {k: [104.0, 105.0, 104.5]}})
    ok("+4% inside 3x noise floor is not reported", rc == 0, str(lines))
    noisy = {"fingerprint": fp, "rows": {k: [80.0, 140.0, 100.0]}}
    rc, lines = compare_runs(noisy, noisy)
    ok("60% noise is undecidable, not a pass", rc == 1 and "UNDECIDABLE" in lines[0], str(lines))
    rc, lines = compare_runs(base, {"fingerprint": {**fp, "cpu": "Y"}, "rows": base["rows"]})
    ok("different host is refused", rc == 2, str(lines))
    rc, lines = compare_runs(base, {"fingerprint": fp, "rows": {k: [100.0], "b :: t :: v :: 20 :: op": [1.0]}})
    ok("new row without baseline must be registered", rc == 1 and any("NEW" in l for l in lines), str(lines))

    lin = {"rows": {f"b :: lin :: v N={n} :: {n} :: op": [5.0 * n] for n in (64, 256, 1024, 4096)}}
    quad = {"rows": {f"b :: quad :: v :: {n} :: op": [0.01 * n * n] for n in (64, 256, 1024, 4096)}}
    rc, lines = slopes(lin, {"b :: lin": 1.0})
    ok("O(n) table at slope 1 passes", rc == 0 and "1.00" in lines[0], str(lines))
    rc, lines = slopes(quad, {"b :: quad": 1.0})
    ok("O(n^2) in an O(n) table is caught", rc == 1 and "2.00" in lines[0], str(lines))
    rc, lines = slopes(quad, {"b :: quad": 1.0, "b :: quad :: v": 2.0})
    ok("a variant-level declaration overrides the table's", rc == 0, str(lines))

    d = Path(tempfile.mkdtemp(prefix="perfgov_"))
    (d / "benchmarks").mkdir()
    (d / "scripts").mkdir()
    (d / "benchmarks/bench_a.mojo").write_text("")
    (d / "benchmarks/bench_b.mojo").write_text("")
    (d / TEMPLATE).write_text("## A\n@bench benchmarks/bench_a.mojo\n## B\n@bench benchmarks/bench_b.mojo\n")
    (d / REPORT).write_text("## A\n...\n## B\n...\n")
    ok("governance: consistent tree", governance(d) == [], str(governance(d)))
    (d / "benchmarks/bench_c.mojo").write_text("")
    (d / REPORT).write_text("## A\n")
    g = governance(d)
    ok("governance: unregistered bench and stale report caught", len(g) == 2, str(g))

    run = {"fingerprint": fp, "rows": {"s :: scene :: tower :: 100 :: step": [1000.0, 1010.0, 1005.0]}}
    book = register_budgets(run, ["tower"])
    ok("registered budget is median x 1.2", book["budgets"]["s :: scene :: tower :: 100 :: step"] == 1206, str(book["budgets"]))
    rc, _ = check_budgets(run, book)
    ok("same numbers stay in budget", rc == 0)
    doubled = {"fingerprint": fp, "rows": {"s :: scene :: tower :: 100 :: step": [2000.0, 2010.0, 2005.0]}}
    rc, lines = check_budgets(doubled, book)
    ok("doubling the scene's cost is over budget", rc == 1 and "OVER BUDGET" in lines[0], str(lines))
    rc, _ = check_budgets({**run, "fingerprint": {**fp, "cpu": "Y"}}, book)
    ok("budgets of another host are refused", rc == 2)

    total = 20
    print(f"[{'PASS' if fails == 0 else 'FAIL'}] perf selftest - {total - fails} / {total} checks")
    return 1 if fails else 0


# --------------------------------------------------------------------- main


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    c = sub.add_parser("collect")
    c.add_argument("--reps", type=int, default=3)
    c.add_argument("--only", nargs="*", default=[])
    c.add_argument("-o", "--out", default="build/perf/run.json")
    cp = sub.add_parser("compare")
    cp.add_argument("baseline")
    cp.add_argument("current")
    sl = sub.add_parser("slopes")
    sl.add_argument("run")
    sub.add_parser("governance")
    bu = sub.add_parser("budgets")
    bu.add_argument("run")
    bu.add_argument("--register", nargs="*")
    bc = sub.add_parser("bisect-check")
    bc.add_argument("--bench", required=True)
    bc.add_argument("--baseline", required=True)
    bc.add_argument("--reps", type=int, default=3)
    sub.add_parser("selftest")
    sub.add_parser("fingerprint")
    a = ap.parse_args()

    if a.cmd == "selftest":
        return selftest()
    if a.cmd == "fingerprint":
        print(json.dumps(fingerprint(), indent=1))
        return 0
    if a.cmd == "collect":
        return collect(a.reps, a.only, ROOT / a.out)
    if a.cmd == "compare":
        rc, lines = compare_runs(json.loads(Path(a.baseline).read_text()), json.loads(Path(a.current).read_text()))
        for l in lines:
            print("perf:", l)
        print(f"perf: compare {'PASS' if rc == 0 else 'REFUSED' if rc == 2 else 'FAIL'}")
        return rc
    if a.cmd == "slopes":
        rc, lines = slopes(json.loads(Path(a.run).read_text()), load_slopes())
        for l in lines:
            print("perf:", l)
        print(f"perf: slopes {'PASS' if rc == 0 else 'FAIL'}")
        return rc
    if a.cmd == "budgets":
        run = json.loads(Path(a.run).read_text())
        if a.register:
            book = register_budgets(run, a.register)
            (ROOT / BUDGETS).write_text(json.dumps(book, indent=1, sort_keys=True, ensure_ascii=False) + "\n", encoding="utf-8")
            print(f"perf: registered {len(book['budgets'])} budgets in {BUDGETS}")
            return 0
        rc, lines = check_budgets(run, json.loads((ROOT / BUDGETS).read_text(encoding="utf-8")))
        for l in lines:
            print("perf:", l)
        print(f"perf: budgets {'PASS' if rc == 0 else 'REFUSED' if rc == 2 else 'FAIL'}")
        return rc
    if a.cmd == "governance":
        problems = governance(ROOT)
        for p in problems:
            print("perf:", p)
        print(f"perf: governance {'PASS' if not problems else 'FAIL'} ({len(problems)} problems)")
        return 1 if problems else 0
    if a.cmd == "bisect-check":
        # exit 0 = good, 1 = bad, 125 = skip (build failed): `git bisect run` codes
        if subprocess.run(["bash", "scripts/build_engine.sh"], cwd=ROOT, capture_output=True, check=False).returncode != 0:
            return 125
        tmp = ROOT / "build/perf/bisect.json"
        collect(a.reps, [a.bench], tmp)
        base = json.loads(Path(a.baseline).read_text())
        cur = json.loads(tmp.read_text())
        base["rows"] = {k: v for k, v in base["rows"].items() if k.startswith(a.bench + " ::")}
        rc, lines = compare_runs(base, cur)
        for l in lines:
            print("perf:", l)
        return 125 if rc == 2 else (1 if any(l.startswith("REGRESSION") for l in lines) else 0)
    return 2


if __name__ == "__main__":
    sys.exit(main())
