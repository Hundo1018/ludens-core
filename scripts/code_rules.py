"""CLAUDE.md coding rules that a script can check, so nobody has to remember them on every change.

    pixi run code-rules                 # exit 1 on a violation
    pixi run code-rules -- --selftest

Rules (each one is a CLAUDE.md sentence; the check reads the code with comments and docstrings removed, except
the TODO rule, which reads only comments and docstrings):

  bare-case     `case NAME:` binds a new variable called NAME and matches every value; a named constant is
                compared with `case == NAME:`. Any `case` followed by an upper-case name is reported.
  engine-print  engine packages do not print (`print(` in a package listed in scripts/arch_layers.toml [layers]).
  todo-id       a TODO / FIXME / XXX names the issue (`#123`) or ROADMAP entry (`17.5`) that tracks it, so it can
                be found and closed.

Not checked: "`raises` must really raise". A text scan of engine functions found 69 declared `raises` with no
`raise` and no call to a repo function declared `raises`; the ones read were trait implementations whose trait
requires `raises`, `Dict` subscripts and GPU calls, which raise. Telling those apart needs types.
"""

import argparse
import re
import sys
import tempfile
import tomllib
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from stale_refs import strip_mojo  # noqa: E402  -- the one comment/docstring splitter, shared

ROOT = Path(__file__).resolve().parent.parent
SKIP = {".git", ".claude", ".pixi", "build", "build64", ".campaign"}
BARE_CASE = re.compile(r"^\s*case\s+([A-Z][A-Za-z0-9_]*)\b(?!\s*\()")
PRINT = re.compile(r"(?<![\w.])print\s*\(")
TODO = re.compile(r"\b(TODO|FIXME|XXX)\b")
STRING = re.compile(r'"(?:\\.|[^"\\])*"|\'(?:\\.|[^\'\\])*\'')
TRACKED = re.compile(r"#\d+|\b\d{1,2}\.\d{1,3}[a-z]?\b")


def engine_packages(root: Path) -> set[str]:
    """The packages of [layers] (`name = layer`)."""
    return set(tomllib.loads((root / "scripts/arch_layers.toml").read_text(encoding="utf-8"))["layers"])


def mojo_files(root: Path):
    for p in sorted(root.rglob("*.mojo")):
        rel = p.relative_to(root)
        if not any(part in SKIP for part in rel.parts):
            yield p, rel.as_posix()


def check(root: Path) -> list[str]:
    engine = engine_packages(root)
    out = []
    for p, rel in mojo_files(root):
        code, prose = strip_mojo(p.read_text(encoding="utf-8", errors="ignore"))
        in_engine = rel.split("/", 1)[0] in engine
        for i, line in enumerate(code.split("\n"), 1):
            line = STRING.sub('""', line)
            m = BARE_CASE.match(line)
            if m:
                out.append(f"{rel}:{i}: bare-case `case {m.group(1)}:` binds a new name; write `case == {m.group(1)}:`")
            if in_engine and PRINT.search(line):
                out.append(f"{rel}:{i}: engine-print engine packages do not print (CLAUDE.md); return the value or use diag.log")
        for i, text in prose:
            if TODO.search(text) and not TRACKED.search(text):
                out.append(f"{rel}:{i}: todo-id a TODO names its issue (#123) or ROADMAP entry (17.5)")
    return out


def selftest() -> int:
    with tempfile.TemporaryDirectory() as t:
        r = Path(t)
        (r / "scripts").mkdir()
        (r / "scripts/arch_layers.toml").write_text("[layers]\ndiag = 0\nphysics = 1\n")
        (r / "physics").mkdir()
        (r / "tests").mkdir()
        (r / "physics/a.mojo").write_text(
            '"""TODO: no id here.\nTODO (17.5): tracked.\nFIXME #12 tracked."""\n'
            "def f(x: Int):\n"
            "    match x:\n"
            "        case == KIND_A:\n"
            "            pass\n"
            "        case KIND_B:\n"
            "            pass\n"
            "        case Point(a, b):\n"
            "            pass\n"
            "        case _:\n"
            "            pass\n"
            '    print("x")  # TODO without an id\n'
            '    var s = "print(not code)"\n'
        )
        (r / "tests/test_a.mojo").write_text('def main():\n    print("tests may print")\n')
        got = sorted(x.split(" ", 2)[1] + "@" + x.split(":")[1] for x in check(r))
        want = sorted(["todo-id@1", "bare-case@8", "engine-print@14", "todo-id@14"])  # line numbers are the file's
        if got != want:
            print(f"code_rules selftest FAIL: got {got} want {want}")
            return 1
    print("code_rules selftest: 1 case ok")
    return 0


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--selftest", action="store_true")
    a = ap.parse_args()
    if a.selftest:
        return selftest()
    problems = check(ROOT)
    for p in problems:
        print("  " + p)
    if problems:
        print(f"code_rules: {len(problems)} violation(s)")
        return 1
    print("code_rules: ok")
    return 0


if __name__ == "__main__":
    sys.exit(main())
