"""Fast static checks in one command: `pixi run lint` (4.2 s measured; no build).

    pixi run lint                # every check, one line each; exit 1 if any fails
    pixi run lint -- --only ruff,shellcheck
    pixi run lint -- --list

Each check prints its own findings under its line. The checks:

  code-rules   CLAUDE.md coding rules a script can check (scripts/code_rules.py)
  stale-refs   comments and docs that name code which does not exist (scripts/stale_refs.py)
  ruff         scripts/ and python/: the bug-finding rules in ruff.toml
  shellcheck   scripts/*.sh and .githooks/*
  selftests    the selftests of code_rules and stale_refs

pre-commit runs the checks that match the staged files (scripts/hooks.py); pre-push and CI run all of them.
"""

import argparse
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
PY = sys.executable


def shell_files() -> list[str]:
    files = sorted(str(p.relative_to(ROOT)) for p in (ROOT / "scripts").glob("*.sh"))
    files += sorted(str(p.relative_to(ROOT)) for p in (ROOT / ".githooks").iterdir() if p.is_file())
    return files


CHECKS = {
    "code-rules": lambda: [PY, "scripts/code_rules.py"],
    "stale-refs": lambda: [PY, "scripts/stale_refs.py"],
    "ruff": lambda: ["ruff", "check", "--quiet", "--output-format", "concise", "scripts", "python"],
    "shellcheck": lambda: ["shellcheck", "-f", "gcc", *shell_files()],
    "selftests": lambda: None,
}


def run(argv: list[str]) -> tuple[bool, str]:
    try:
        p = subprocess.run(argv, cwd=ROOT, capture_output=True, text=True, check=False)
    except FileNotFoundError:
        return False, f"{argv[0]} not found (run through pixi: `pixi run lint`)"
    return p.returncode == 0, (p.stdout + p.stderr).strip()


def run_check(name: str) -> tuple[bool, str]:
    if name == "selftests":
        outs, ok = [], True
        for s in ("scripts/code_rules.py", "scripts/stale_refs.py"):
            good, out = run([PY, s, "--selftest"])
            ok = ok and good
            if not good:
                outs.append(out)
        return ok, "\n".join(outs)
    return run(CHECKS[name]())


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--only", help="comma-separated subset of: " + ", ".join(CHECKS))
    ap.add_argument("--list", action="store_true")
    a = ap.parse_args()
    if a.list:
        print("\n".join(CHECKS))
        return 0
    names = a.only.split(",") if a.only else list(CHECKS)
    unknown = [n for n in names if n not in CHECKS]
    if unknown:
        print("lint: unknown check(s): " + ", ".join(unknown))
        return 2
    failed = []
    for n in names:
        ok, out = run_check(n)
        print(f"[lint] {'ok  ' if ok else 'FAIL'} {n}")
        if not ok:
            failed.append(n)
            for line in out.splitlines():
                print("    " + line)
    if failed:
        print("lint: failed: " + ", ".join(failed))
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
