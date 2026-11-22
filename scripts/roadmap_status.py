"""Count ROADMAP statuses from the 編號索引 and list the open entries.

    pixi run roadmap-status            # per-subsystem counts + open entries
    pixi run roadmap-status -- --open  # only the open entries, one per line
    pixi run roadmap-status -- --check # exit 1 when a subsystem row differs from the index
    pixi run roadmap-status -- --set 17.89=✅ --set 17.58=不排   # change statuses, rewrite the summary counts
    python3 scripts/roadmap_status.py --selftest

The index table (`## 編號索引`) is the single source for statuses: one row per
entry, `| 編號 | 條目 | 子系統 | 狀態 |`, with ✅ 🔶 ⬜ ⏸ as the status column.
The subsystem summary table (`## 子系統`) is compared against it; any
difference is printed so the two can be reconciled by hand.
"""

import argparse
import re
import sys
from collections import Counter, defaultdict
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
STATUSES = ("✅", "🔶", "⬜", "⏸", "不排")
ROW = re.compile(r"^\|\s*([^|]+?)\s*\|\s*(.*?)\s*\|\s*(.*?)\s*\|\s*(.*?)\s*\|\s*$")


def _section(lines, title):
    start = next(i for i, ln in enumerate(lines) if ln.startswith(title))
    end = next((i for i in range(start + 1, len(lines)) if lines[i].startswith("## ")), len(lines))
    return lines[start + 1 : end]


def parse(text):
    """Return (index rows, summary rows). Index rows: (id, title, subsystem, status)."""
    lines = text.splitlines()
    index, summary = [], []
    for ln in _section(lines, "## 編號索引"):
        m = ROW.match(ln)
        if m and m.group(1) not in ("編號", "---") and not m.group(1).startswith(":"):
            status = next((s for s in STATUSES if s in m.group(4)), "?")
            if status == "?" and "不排" in m.group(4):
                status = "不排"
            index.append((m.group(1), re.sub(r"\[([^]]*)\]\([^)]*\)", r"\1", m.group(2)), m.group(3), status))
    for ln in _section(lines, "## 子系統"):
        if not ln.startswith("|"):
            continue
        cells = [c.strip() for c in ln.strip().strip("|").split("|")]
        if cells[0] not in ("子系統", "---") and not cells[0].startswith(":") and len(cells) == 6:
            summary.append(cells)
    return index, summary


def mismatches(index, summary):
    """Subsystem rows whose summary counts differ from the index: [(name, index counts, summary counts)]."""
    by_sub = defaultdict(Counter)
    for _, _, sub, status in index:
        by_sub[sub][status] += 1
    bad = []
    for row in summary:
        sub = re.sub(r"\[([^]]*)\]\([^)]*\)", r"\1", row[0])
        got = by_sub.get(sub, Counter())
        mine = [got["✅"], got["🔶"], got["⬜"], got["⏸"] + got["不排"]]
        want = [int(w.replace("**", "").strip()) for w in row[2:]]
        if mine != want:
            bad.append((sub, mine, want))
    return bad


def set_status(text, changes):
    """Apply {id: status} to the entry's row in its subsystem table (`| id | [title](#a) | status | wave | ... |`)
    and in the index (`| id | [title](#a) | subsystem | status |`), then rewrite the summary counts from the
    index. Raises if an id has no index row or no subsystem-table row."""
    for st in changes.values():
        if st not in STATUSES:
            raise ValueError(f"unknown status {st!r}; one of {STATUSES}")
    lines = text.split("\n")
    idx_start = next(i for i, ln in enumerate(lines) if ln.startswith("## 編號索引"))
    seen_idx, seen_sub = set(), set()
    for i, ln in enumerate(lines):
        if not ln.startswith("| "):
            continue
        cells = ln.split("|")
        eid = cells[1].strip()
        if eid not in changes or len(cells) < 6:
            continue
        if i > idx_start and len(cells) == 6:  # index: '', id, title, subsystem, status, ''
            cells[4] = f" {changes[eid]} "
            seen_idx.add(eid)
        elif i < idx_start and any(s in cells[3] for s in STATUSES):  # subsystem table: status in the third cell
            cells[3] = f" {changes[eid]} "
            seen_sub.add(eid)
        lines[i] = "|".join(cells)
    missing = sorted(set(changes) - seen_idx) + sorted(set(changes) - seen_sub)
    if missing:
        raise KeyError(f"no index or subsystem-table row for {missing}")
    text = "\n".join(lines)
    index, _ = parse(text)
    by_sub = defaultdict(Counter)
    for _, _, sub, status in index:
        by_sub[sub][status] += 1
    lines = text.split("\n")
    start = next(i for i, ln in enumerate(lines) if ln.startswith("## 子系統"))
    for i in range(start + 1, len(lines)):
        if lines[i].startswith("## "):
            break
        cells = lines[i].split("|")
        if len(cells) != 8 or cells[1].strip() in ("子系統", "---") or cells[1].strip().startswith(":"):
            continue
        got = by_sub[re.sub(r"\[([^]]*)\]\([^)]*\)", r"\1", cells[1].strip())]
        nums = [got["✅"], got["🔶"], got["⬜"], got["⏸"] + got["不排"]]
        cells[3:7] = [f" {n} " for n in nums]
        lines[i] = "|".join(cells)
    return "\n".join(lines)


def report(index, summary, open_only):
    by_sub = defaultdict(Counter)
    for _, _, sub, status in index:
        by_sub[sub][status] += 1
    if open_only:
        for eid, title, sub, status in index:
            if status != "✅":
                print(f"{status} {eid}\t{title}\t{sub}")
        return
    print("subsystem | ✅ | 🔶 | ⬜ | ⏸+不排 | (index) vs (summary table)")
    for row in summary:
        sub = re.sub(r"\[([^]]*)\]\([^)]*\)", r"\1", row[0])
        got = by_sub.get(sub, Counter())
        mine = [got["✅"], got["🔶"], got["⬜"], got["⏸"] + got["不排"]]
        want = [int(w.replace("**", "").strip()) for w in row[2:]]
        ok = mine == want
        cells = " | ".join(str(n) for n in mine)
        print(f"{sub} | {cells} | {'match' if ok else 'DIFF: summary ' + ' '.join(str(w) for w in want)}")
    total = Counter(st for _, _, _, st in index)
    print("total |", " | ".join(str(total[s]) for s in STATUSES), f"| {len(index)} entries")


def selftest():
    sample = (
        "## 編號索引\n\n| 編號 | 條目 | 子系統 | 狀態 |\n|---|---|---|:-:|\n"
        "| 1.0 | [a](x.md) | S | ✅ |\n| 1.1 | b | S | 🔶 |\n| 1.2 | c | T | ⬜ |\n"
        "\n## 子系統\n\n| 子系統 | 範圍 | ✅ | 🔶 | ⬜ | ⏸ / 不排 |\n|---|---|--:|--:|--:|--:|\n"
        "| [S](#s) | r | 1 | 1 | 0 | 0 |\n| T | r | 0 | 0 | 1 | 0 |\n"
    )
    index, summary = parse(sample)
    assert [r[3] for r in index] == ["✅", "🔶", "⬜"], index
    assert parse(sample.replace("⬜ |", "不排 |"))[0][2][3] == "不排"
    assert index[0][1] == "a", index
    assert len(summary) == 2 and summary[0][2:] == ["1", "1", "0", "0"], summary
    assert mismatches(index, summary) == [], mismatches(index, summary)
    assert [m[0] for m in mismatches(index, parse(sample.replace("| r | 1 | 1 |", "| r | 2 | 0 |"))[1])] == ["S"]
    sub_table = "## S\n\n| 編號 | 條目 | 狀態 | 波 | 摘要 |\n|---|---|:-:|:-:|---|\n| 1.1 | [b](#b) | 🔶 | C | x |\n\n"
    moved = set_status(sub_table + sample, {"1.1": "不排"})
    i2, s2 = parse(moved)
    assert i2[1][3] == "不排" and "| 1.1 | [b](#b) | 不排 | C | x |" in moved, moved
    assert s2[0][2:] == ["1", "0", "0", "1"] and mismatches(i2, s2) == [], s2
    try:
        set_status(sample, {"9.9": "✅"})
        raise AssertionError("missing id accepted")
    except KeyError:
        pass
    print("selftest ok")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--open", action="store_true")
    ap.add_argument("--check", action="store_true", help="exit 1 when a subsystem row differs from the index")
    ap.add_argument("--selftest", action="store_true")
    ap.add_argument("--set", action="append", default=[], metavar="ID=STATUS", help="change an entry's status")
    args = ap.parse_args()
    if args.selftest:
        selftest()
        return 0
    if args.set:
        path = ROOT / "docs" / "ROADMAP.md"
        changes = dict(kv.split("=", 1) for kv in args.set)
        path.write_text(set_status(path.read_text(encoding="utf-8"), changes), encoding="utf-8")
        print(f"roadmap-status: set {len(changes)} statuses")
        return 0
    index, summary = parse((ROOT / "docs" / "ROADMAP.md").read_text(encoding="utf-8"))
    if not index:
        print("no index rows found", file=sys.stderr)
        return 1
    if args.check:
        bad = mismatches(index, summary)
        for sub, mine, want in bad:
            print(f"{sub}: index counts {mine} (✅ 🔶 ⬜ ⏸+不排), subsystem table says {want}", file=sys.stderr)
        if not bad:
            print(f"roadmap-status: {len(summary)} subsystem rows match the index ({len(index)} entries)")
        return 1 if bad else 0
    report(index, summary, args.open)
    return 0


if __name__ == "__main__":
    sys.exit(main())
