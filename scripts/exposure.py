"""開放清單 (exposure list, issue #159): which engine modules the host can reach.

    pixi run exposure                    # check scripts/exposure.toml against the import graph (CI, pre-push)
    pixi run exposure -- --report        # per-package counts: exposed / internal / pending
    pixi run exposure -- --init          # write a first scripts/exposure.toml from the import graph
    pixi run exposure -- --selftest

Every engine module outside `embed/` has one entry in `scripts/exposure.toml`:

    [modules]
    "physics.rope"       = { status = "exposed" }
    "procedural.tween"   = { status = "pending", issue = 159 }
    "physics.contact6"   = { status = "internal", reason = "solver internals, used through ContactScene6" }

- `exposed`: an `embed/` module imports it directly (EmbedWorld, the C-ABI, scene_io, ...). Checked.
- `pending`: not reachable from the host yet; `issue` names where the work is tracked.
- `internal`: not meant for the host; `reason` says why (for example "used only through physics.solver6").

The check fails when a module has no entry, an entry names a module that does not exist, an `exposed` module
is not imported by `embed/`, a module `embed/` imports is still `pending` / `internal` (promote it), or a
`pending` entry has no issue / an `internal` entry has no reason. So a new module cannot land without a
decision about the host, and the list cannot drift from the code.

Imports recognised: `from pkg.mod import`, `import pkg.mod`, `from .mod import` inside the package, and
`from pkg import` through the package `__init__.mojo` re-exports.
"""

import argparse
import re
import sys
import tempfile
import tomllib
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
LIST = "scripts/exposure.toml"
HOST_PKG = "embed"
SKIP_PKGS = {"embed", "oop"}  # the host boundary itself; the OOP baseline engine exists only for benchmarks
STATUSES = ("exposed", "pending", "internal")
FROM_ABS = re.compile(r"^\s*from\s+([a-z_][a-z0-9_]*)\.([a-z_][a-z0-9_]*)\s+import\b", re.M)
IMPORT_ABS = re.compile(r"^\s*import\s+([a-z_][a-z0-9_]*)\.([a-z_][a-z0-9_]*)\b", re.M)
FROM_REL = re.compile(r"^\s*from\s+\.([a-z_][a-z0-9_]*)\s+import\b", re.M)
FROM_PKG = re.compile(r"^\s*from\s+([a-z_][a-z0-9_]*)\s+import\b", re.M)


def packages(root: Path) -> list[str]:
    t = tomllib.loads((root / "scripts/arch_layers.toml").read_text(encoding="utf-8"))
    return sorted(t["layers"])


def modules(root: Path) -> dict[str, Path]:
    out = {}
    for p in packages(root):
        for f in sorted((root / p).glob("*.mojo")):
            if f.stem != "__init__":
                out[f"{p}.{f.stem}"] = f
    return out


def imports(root: Path, mod: str, path: Path, mods: dict[str, Path], pkgs: set[str]) -> set[str]:
    text = path.read_text(encoding="utf-8", errors="replace")
    own = mod.split(".")[0]
    out = set()
    for a, b in FROM_ABS.findall(text) + IMPORT_ABS.findall(text):
        if f"{a}.{b}" in mods:
            out.add(f"{a}.{b}")
    for b in FROM_REL.findall(text):
        if f"{own}.{b}" in mods:
            out.add(f"{own}.{b}")
    for a in FROM_PKG.findall(text):
        init = root / a / "__init__.mojo"
        if a in pkgs and init.exists():
            for b in FROM_REL.findall(init.read_text(encoding="utf-8", errors="replace")):
                if f"{a}.{b}" in mods:
                    out.add(f"{a}.{b}")
    return out


def graph(root: Path) -> tuple[dict[str, Path], set[str], set[str]]:
    """(modules, imported directly by embed/, reached transitively from embed/)."""
    mods = modules(root)
    pkgs = set(packages(root))
    g = {m: imports(root, m, f, mods, pkgs) for m, f in mods.items()}
    host = [m for m in mods if m.split(".")[0] == HOST_PKG]
    direct = set()
    for m in host:
        direct |= {d for d in g[m] if d.split(".")[0] != HOST_PKG}
    reach, todo = set(), list(host)
    while todo:
        for d in g[todo.pop()]:
            if d not in reach:
                reach.add(d)
                todo.append(d)
    return mods, direct, reach


def subjects(mods: dict[str, Path]) -> list[str]:
    return [m for m in mods if m.split(".")[0] not in SKIP_PKGS]


def load(root: Path) -> dict[str, dict]:
    p = root / LIST
    if not p.exists():
        return {}
    return tomllib.loads(p.read_text(encoding="utf-8")).get("modules", {})


def problems(root: Path) -> list[str]:
    mods, direct, _ = graph(root)
    entries = load(root)
    out = []
    for m in subjects(mods):
        e = entries.get(m)
        if e is None:
            out.append(f"{m}: 沒有登記。在 {LIST} 加一行：exposed（embed/ 已直接 import）、pending（附 issue）或 internal（附理由）")
            continue
        st = e.get("status")
        if st not in STATUSES:
            out.append(f"{m}: status 必須是 {' / '.join(STATUSES)}，現在是 {st!r}")
        elif st == "exposed" and m not in direct:
            out.append(f"{m}: 登記為 exposed，但 embed/ 沒有直接 import 它")
        elif st != "exposed" and m in direct:
            out.append(f"{m}: embed/ 已直接 import 它，請改為 exposed（現在是 {st}）")
        if st == "pending" and not isinstance(e.get("issue"), int):
            out.append(f"{m}: pending 要附 issue 編號")
        if st == "internal" and not str(e.get("reason", "")).strip():
            out.append(f"{m}: internal 要附理由")
    for m in sorted(set(entries) - set(subjects(mods))):
        out.append(f"{m}: 登記了，但這個模組不存在（刪除或改名後請更新 {LIST}）")
    return out


def report(root: Path) -> str:
    mods, direct, reach = graph(root)
    entries = load(root)
    rows = {}
    for m in subjects(mods):
        p = m.split(".")[0]
        st = entries.get(m, {}).get("status", "未登記")
        rows.setdefault(p, {}).setdefault(st, 0)
        rows[p][st] += 1
    cols = ["exposed", "internal", "pending", "未登記"]
    lines = ["| 套件 | " + " | ".join(cols) + " |", "|---|" + "---:|" * len(cols)]
    tot = {c: 0 for c in cols}
    for p in sorted(rows):
        lines.append(f"| {p} | " + " | ".join(str(rows[p].get(c, 0)) for c in cols) + " |")
        for c in cols:
            tot[c] += rows[p].get(c, 0)
    lines.append("| 合計 | " + " | ".join(str(tot[c]) for c in cols) + " |")
    return "\n".join(lines)


def init(root: Path, issue: int) -> str:
    """A first list from the import graph: direct -> exposed; reached only through exposed modules -> internal
    (marked for review); not reached -> pending on `issue`."""
    mods, direct, reach = graph(root)
    lines = [
        "# 開放清單 (issue #159): one entry per engine module outside embed/ and oop/.",
        "# exposed = embed/ imports it directly (checked); pending = not reachable from the host yet (issue);",
        "# internal = not meant for the host (reason). `pixi run exposure` checks this file against the imports.",
        "",
        "[modules]",
    ]
    for m in subjects(mods):
        if m in direct:
            lines.append(f'"{m}" = {{ status = "exposed" }}')
        elif m in reach:
            lines.append(f'"{m}" = {{ status = "internal", reason = "只經由已開放的模組使用（自動分類，待確認）" }}')
        else:
            lines.append(f'"{m}" = {{ status = "pending", issue = {issue} }}')
    return "\n".join(lines) + "\n"


def selftest() -> int:
    with tempfile.TemporaryDirectory() as d:
        r = Path(d)
        (r / "scripts").mkdir()
        (r / "scripts/arch_layers.toml").write_text('[layers]\ngeom = 1\nphys = 2\nembed = 3\n')
        for p in ("geom", "phys", "embed"):
            (r / p).mkdir()
        (r / "geom/vec.mojo").write_text("def f(): pass\n")
        (r / "phys/body.mojo").write_text("from geom.vec import f\n")
        (r / "phys/rope.mojo").write_text("from .body import x\n")
        (r / "phys/tween.mojo").write_text("def g(): pass\n")
        (r / "embed/world.mojo").write_text("from phys.rope import y\n")
        _, direct, reach = graph(r)
        assert direct == {"phys.rope"}, direct
        assert reach == {"phys.rope", "phys.body", "geom.vec"}, reach
        assert len(problems(r)) == 4, problems(r)  # nothing registered yet
        (r / LIST).write_text(init(r, 7))
        assert problems(r) == [], problems(r)
        text = (r / LIST).read_text()
        assert '"phys.tween" = { status = "pending", issue = 7 }' in text, text
        # a new module without an entry fails
        (r / "phys/cloth.mojo").write_text("def h(): pass\n")
        assert any("phys.cloth: 沒有登記" in p for p in problems(r)), problems(r)
        (r / "phys/cloth.mojo").unlink()
        # embed starts importing a pending module: must be promoted
        (r / "embed/world.mojo").write_text("from phys.rope import y\nfrom phys.tween import g\n")
        assert any("phys.tween: embed/ 已直接 import" in p for p in problems(r)), problems(r)
        (r / "embed/world.mojo").write_text("from phys.rope import y\n")
        # exposed but not imported fails; a deleted module's entry fails
        (r / LIST).write_text(text.replace('"phys.tween" = { status = "pending", issue = 7 }', '"phys.tween" = { status = "exposed" }'))
        assert any("phys.tween: 登記為 exposed" in p for p in problems(r)), problems(r)
        (r / LIST).write_text(text + '"phys.gone" = { status = "internal", reason = "x" }\n')
        assert any("phys.gone: 登記了，但這個模組不存在" in p for p in problems(r)), problems(r)
        (r / LIST).write_text(text.replace("issue = 7", 'reason = "x"'))
        assert any("pending 要附 issue" in p for p in problems(r)), problems(r)
    print("exposure selftest: ok")
    return 0


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--report", action="store_true")
    ap.add_argument("--init", action="store_true", help=f"write {LIST} from the import graph (refuses to overwrite)")
    ap.add_argument("--issue", type=int, default=159)
    ap.add_argument("--selftest", action="store_true")
    a = ap.parse_args()
    if a.selftest:
        return selftest()
    if a.init:
        p = ROOT / LIST
        if p.exists():
            print(f"{LIST} exists; edit it instead", file=sys.stderr)
            return 1
        p.write_text(init(ROOT, a.issue), encoding="utf-8")
        print(f"wrote {LIST}")
        print(report(ROOT))
        return 0
    if a.report:
        print(report(ROOT))
        return 0
    bad = problems(ROOT)
    for b in bad:
        print("exposure:", b, file=sys.stderr)
    if bad:
        print(f"exposure: FAIL ({len(bad)} problems; scripts/exposure.toml, issue #159)", file=sys.stderr)
        return 1
    print(f"exposure: OK ({len(load(ROOT))} modules registered)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
