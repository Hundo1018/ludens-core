"""Find documentation text that names code which no longer exists, or calls code "future" that exists now.

    pixi run stale-refs                 # check, exit 1 on a finding
    pixi run stale-refs -- --report     # every finding, grouped by file, no exit code
    pixi run stale-refs -- --selftest

Where it looks: comments and docstrings of every `.mojo` file, and the prose docs in DOCS. Plans are skipped
(docs/ROADMAP.md, docs/design/, docs/audits/, docs/ROADMAP_HISTORY.md, generated files): naming something that
does not exist yet is their job.

Two rules:

  dead name    A backticked token that reads as a code name -- `_private`, `snake_case_name`, `CamelCase`,
               `pkg.mod.Name`, `test_x` / `bench_x` -- must exist. A plain name must appear in code (comments
               and docstrings removed); `pkg.mod.Name` must have `pkg/mod.mojo` and `Name` in it; `test_x` and
               `bench_x` must be files under tests/ or benchmarks/.
  resolved     A sentence that says a named thing is missing ("a future `X`", "until `X` exists", "`X` does
               not exist yet", "no `X` yet", "once `X` lands") while `X` exists.

Why: a docstring said the ECS sparse index was capped at 4096 entities long after the cap was removed, and nobody
measured more than a few thousand entities because of it. A sweep then confirmed 13 more stale texts by reading
code; these two rules catch 9 of them. The other 4 need a person: a count ("5 backends" for 6), "not yet threaded"
about a parameter that is, "the system tier is empty" when tests carry it, and a real name placed in the wrong
module. The first full run reported 93 findings across the repo.

A finding that is correct as written (an external API, notation, an example name) goes in ALLOW with a reason:
`token  # reason` (anywhere) or `path:token  # reason` (one file).
"""

import argparse
import re
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
ALLOW = "scripts/stale_refs_allow.txt"
DOCS = ["README.md", "CLAUDE.md", "CONTRIBUTING.md", "docs/ARCHITECTURE.md", "docs/CATEGORY.md",
        "scripts/benchmark_report.md.in"]
SKIP_DIRS = {".git", ".claude", ".pixi", "build", "build64", ".campaign", "node_modules"}
CODE_EXT = (".mojo", ".py", ".sh", ".toml", ".h", ".rs", ".c", ".mjs", ".js", ".ts", ".yml")

TICK = re.compile(r"`([^`\n]{1,120})`")
WORD = re.compile(r"[A-Za-z_][A-Za-z0-9_]*")
MEMBER = re.compile(r"^([A-Z][A-Za-z0-9]+)\.([a-z_][a-z0-9_]*)$")
QUAL = re.compile(r"^([a-z_][a-z0-9_]*)\.([a-z_][a-z0-9_]*)\.([A-Za-z_][A-Za-z0-9_]*)$")
FILE_NAME = re.compile(r"^(test|bench)_[a-z0-9_]+$")
MISSING = [
    re.compile(r"\bfuture\s+`([^`]+)`", re.I),
    re.compile(r"\buntil\s+`([^`]+)`\s+(?:exists|lands|is added|is written)", re.I),
    re.compile(r"\bonce\s+`([^`]+)`\s+(?:exists|lands|is added)", re.I),
    re.compile(r"`([^`]+)`\s+(?:does not|doesn't)\s+(?:exist|exist yet)\b", re.I),
    re.compile(r"\bno\s+`([^`]+)`\s+yet\b", re.I),
    re.compile(r"`([^`]+)`\s+(?:is|are)\s+not\s+(?:written|implemented|there)\s+yet\b", re.I),
]


def walk(root: Path):
    for p in sorted(root.rglob("*")):
        rel = p.relative_to(root)
        if any(part in SKIP_DIRS for part in rel.parts) or not p.is_file():
            continue
        yield p, rel.as_posix()


def strip_mojo(text: str) -> tuple[str, list[tuple[int, str]]]:
    """(code without comments/docstrings, [(line, prose)] of the comments and docstrings)."""
    code, prose = [], []
    in_doc = False
    for i, line in enumerate(text.splitlines(), 1):
        if in_doc:
            if '"""' in line:
                before, _, after = line.partition('"""')
                prose.append((i, before))
                in_doc = False
                line = after
            else:
                prose.append((i, line))
                continue
        while '"""' in line:
            before, _, rest = line.partition('"""')
            if '"""' in rest:
                doc, _, line = rest.partition('"""')
                prose.append((i, doc))
                code.append(before)
            else:
                prose.append((i, rest))
                code.append(before)
                in_doc = True
                line = ""
                break
        # a `#` outside a string literal starts a comment
        no_str = re.sub(r'"(?:\\.|[^"\\])*"|\'(?:\\.|[^\'\\])*\'', lambda m: " " * len(m.group(0)), line)
        k = no_str.find("#")
        if k >= 0:
            prose.append((i, line[k + 1:]))
            line = line[:k]
        code.append(line)
    return "\n".join(code), prose


def strip_py(text: str) -> str:
    text = re.sub(r'"""[\s\S]*?"""', "", text)
    return re.sub(r"#.*", "", text)


def index(root: Path):
    """Names that appear in code, defined names per module, and test/bench file stems."""
    words, per_module, files = set(), {}, set()
    prose = {}
    for p, rel in walk(root):
        if rel.startswith(("tests/", "benchmarks/")) and p.suffix == ".mojo":
            files.add(p.stem)
        if p.suffix not in CODE_EXT:
            continue
        text = p.read_text(encoding="utf-8", errors="ignore")
        if p.suffix == ".mojo":
            code, pr = strip_mojo(text)
            prose[rel] = pr
            per_module[rel] = set(WORD.findall(code))
        elif p.suffix == ".py":
            code = strip_py(text)
        else:
            code = text
        words.update(WORD.findall(code))
    return words, per_module, files, prose


def is_code_name(tok: str) -> bool:
    if tok.startswith("_") and len(tok) > 2:
        return True
    if "_" in tok.strip("_") and tok.lower() == tok and len(tok) >= 6:
        return True
    return bool(re.fullmatch(r"[A-Z][a-z0-9]+(?:[A-Z][a-z0-9]*)+", tok))


def exists(tok: str, words, per_module, files) -> bool | None:
    """True / False when `tok` is a checkable code name, None when it is not one."""
    tok = tok.strip().rstrip("()").removesuffix("[]")
    m = QUAL.match(tok)
    if m:  # `pkg.mod.Name` for a package of this repo; `max.gpu.host` or `self.a.b` are not checked
        if not any(k.startswith(m.group(1) + "/") for k in per_module):
            return None
        mod = f"{m.group(1)}/{m.group(2)}.mojo"
        return mod in per_module and m.group(3) in per_module[mod]
    m = MEMBER.match(tok)
    if m:  # `Type.member`: both names must appear in code
        return m.group(1) in words and m.group(2) in words
    if "." in tok:
        return None
    if FILE_NAME.match(tok):
        return tok in files or tok in words
    if not WORD.fullmatch(tok):
        return None
    if not is_code_name(tok):
        return None
    return tok in words


def load_allow(root: Path) -> dict[str, str]:
    f = root / ALLOW
    out = {}
    if not f.exists():
        return out
    for line in f.read_text(encoding="utf-8").splitlines():
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        key, _, reason = line.partition("#")
        out[key.strip()] = reason.strip()
    return out


def findings(root: Path) -> list[tuple[str, int, str, str]]:
    """(path, line, token, rule) for every finding, before the allow list."""
    words, per_module, files, prose = index(root)
    texts = dict(prose)
    for d in DOCS:
        f = root / d
        if f.exists():
            texts[d] = list(enumerate(f.read_text(encoding="utf-8").splitlines(), 1))
    out = []
    for rel, lines in sorted(texts.items()):
        prev = ""
        for i, line in lines:
            for m in TICK.finditer(line):
                inner = m.group(1).strip()
                if exists(inner, words, per_module, files) is False:
                    out.append((rel, i, inner, "dead name"))
            joined = prev + " " + line  # a sentence wrapped across two lines
            start = len(prev) + 1
            prev = line
            for pat in MISSING:
                for m in pat.finditer(joined):
                    tok = m.group(1)
                    if m.end() <= start:
                        continue  # wholly on the previous line: reported there
                    if exists(tok, words, per_module, files) or (root / tok).exists():
                        out.append((rel, i, tok, "resolved"))
    return out


def check(root: Path) -> list[str]:
    allow = load_allow(root)
    used, problems = set(), []
    for rel, i, tok, rule in findings(root):
        for key in (f"{rel}:{tok}", tok):
            if key in allow:
                used.add(key)
                break
        else:
            what = "names code that does not exist" if rule == "dead name" else "calls existing code missing or future"
            problems.append(f"{rel}:{i}: `{tok}` {what}")
    for key, reason in allow.items():
        if not reason:
            problems.append(f"{ALLOW}: `{key}` has no reason")
        elif key not in used:
            problems.append(f"{ALLOW}: `{key}` is not needed any more (nothing matches it)")
    return problems


def selftest() -> int:
    cases = 0
    with tempfile.TemporaryDirectory() as t:
        r = Path(t)
        (r / "pkg").mkdir()
        (r / "tests").mkdir()
        (r / "tests/test_real.mojo").write_text("def main():\n    pass\n")
        (r / "pkg/mod.mojo").write_text(
            '"""Uses `live_name` and `pkg.mod.Thing`; see `test_real`."""\n'
            "def live_name():\n    pass\n\nstruct Thing:\n    pass\n"
            "# `_gone_helper` was renamed\n"
            "# a\n# future `live_name` will do it\n"
            "# a future `Thing.live_name`; `Thing.gone_method` too\n"
            "# `pkg.mod.Missing` and `test_absent`\n"
            '# `x + y` and `max` are not code names, nor `max.gpu.host` or `self.a.b`\n'
            'var s = "# `_in_string` is not a comment"\n'
        )
        got = {(rel, tok, rule) for rel, _, tok, rule in findings(r)}
        want = {
            ("pkg/mod.mojo", "_gone_helper", "dead name"),
            ("pkg/mod.mojo", "live_name", "resolved"),
            ("pkg/mod.mojo", "Thing.live_name", "resolved"),
            ("pkg/mod.mojo", "Thing.gone_method", "dead name"),
            ("pkg/mod.mojo", "pkg.mod.Missing", "dead name"),
            ("pkg/mod.mojo", "test_absent", "dead name"),
        }
        cases += 1
        if got != want:
            print(f"selftest FAIL findings: got {sorted(got)} want {sorted(want)}")
            return 1
        (r / "scripts").mkdir()
        (r / ALLOW).write_text("_gone_helper  # kept as history\npkg/mod.mojo:test_absent\nunused_entry  # stale\n")
        p = check(r)
        cases += 1
        expect = {"no reason", "not needed any more"}
        if len(p) != 6 or not all(any(e in x for x in p) for e in expect):
            print("selftest FAIL allow list:", p)
            return 1
    print(f"stale_refs selftest: {cases} cases ok")
    return 0


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--report", action="store_true")
    ap.add_argument("--selftest", action="store_true")
    a = ap.parse_args()
    if a.selftest:
        return selftest()
    problems = check(ROOT)
    if a.report:
        for p in problems:
            print(p)
        print(f"{len(problems)} findings")
        return 0
    if problems:
        print("stale references (fix the text, or allow it with a reason in " + ALLOW + "):")
        for p in problems:
            print("  " + p)
        return 1
    print("stale_refs: ok")
    return 0


if __name__ == "__main__":
    sys.exit(main())
