"""Git and Claude Code hooks for ludens-engine (ROADMAP 17.87).

One entry point for every hook, so the rules live in one tested file:

    scripts/hooks.py commit-msg FILE   # Conventional Commits subject (git commit-msg)
    scripts/hooks.py pre-commit        # checks matched to the staged files (git pre-commit)
    scripts/hooks.py pre-push          # the fast CI checks (git pre-push)
    scripts/hooks.py claude-pre        # Claude Code PreToolUse (JSON on stdin)
    scripts/hooks.py claude-post       # Claude Code PostToolUse (JSON on stdin)
    scripts/hooks.py --selftest

Install the git hooks with `pixi run install-hooks` (core.hooksPath=.githooks).
The Claude Code hooks are wired in .claude/settings.json. Only the standard
library is used, so any python3 can run the Claude hooks; the git hooks run
under `pixi run python3` so the checks see the project toolchain.

A hook never edits history and never runs the full test gate (hours; that is
`pixi run gate` and CI). Bypass for a human: `git commit --no-verify`.
"""

import json
import re
import subprocess
import sys
import tomllib
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
PY = sys.executable

CONVENTIONAL = re.compile(r"^(feat|fix|docs|test|refactor|perf|chore|ci|build|style|revert)(\([a-z0-9_.,/ -]+\))?!?: \S")
EXEMPT_SUBJECT = re.compile(r"^(Merge |Revert \"|fixup! |squash! |amend! )")

# Files that a tool writes; editing them by hand is overwritten or flagged stale.
GENERATED = {
    "BENCHMARK_REPORT.md": "pixi run benchmark",
    "CHANGELOG.md": "pixi run changelog",
    "docs/STRUCTURE.md": "pixi run structure",
    "bindings/rust/ludens_sys.rs": "pixi run bindings",
    "bindings/csharp/Ludens.cs": "pixi run bindings",
}
GENERATED_PREFIX = {"tests/golden/": "pixi run gate -- --update-golden (after confirming the new output)"}

TIER_HEADER = re.compile(r"^# tier: (unit|component|integration|system|stress)\b")
DOC_FILES = ("README.md", "CLAUDE.md", "CONTRIBUTING.md")


# --------------------------------------------------------------------------- helpers


def run(label, argv, quiet_ok=True):
    """Run one check; print its output only when it fails. Returns True on success."""
    p = subprocess.run(argv, cwd=ROOT, capture_output=True, text=True)
    if p.returncode != 0:
        print(f"[hooks] FAIL {label}", file=sys.stderr)
        sys.stderr.write((p.stdout or "") + (p.stderr or ""))
        return False
    print(f"[hooks] ok   {label}")
    return True


def git_lines(*args):
    p = subprocess.run(["git", *args], cwd=ROOT, capture_output=True, text=True, check=True)
    return [ln for ln in p.stdout.splitlines() if ln]


def engine_dirs():
    data = tomllib.loads((ROOT / "scripts" / "arch_layers.toml").read_text(encoding="utf-8"))
    return set(data["layers"]) | set(data.get("infrastructure", {}).get("packages", []))


def script(name, *args):
    return [PY, str(ROOT / "scripts" / name), *args]


def arch(*args):
    return ["bash", str(ROOT / "scripts" / "arch.sh"), *args]


# --------------------------------------------------------------------------- commit-msg


def subject_problem(msg):
    """None when the first non-comment line is a Conventional Commit (or exempt)."""
    lines = [ln for ln in msg.splitlines() if not ln.startswith("#")]
    subject = next((ln for ln in lines if ln.strip()), "")
    if not subject:
        return "empty commit message"
    if EXEMPT_SUBJECT.match(subject) or CONVENTIONAL.match(subject):
        return None
    return (
        f"not a Conventional Commit: {subject!r}\n"
        "  expected  type(scope): subject (17.xx)   e.g.  feat(physics): ropes and cables (17.41)\n"
        "  types     feat fix docs test refactor perf chore ci build style revert\n"
        "  scope     a package name, lowercase (optional)"
    )


def cmd_commit_msg(path):
    problem = subject_problem(Path(path).read_text(encoding="utf-8"))
    if problem:
        print(f"[hooks] commit-msg: {problem}", file=sys.stderr)
        return 1
    return 0


# --------------------------------------------------------------------------- pre-commit


DECL_LINE = re.compile(r"^[+-]\s*(def|struct|trait|alias|comptime)\b")


def declaration_changed(diff, dirs):
    """True when a diff (`git diff --cached -U0`) adds or removes a declaration line in an engine .mojo file.

    Regenerating docs/STRUCTURE.md reruns `mojo doc` (about 85 s on this repo),
    so a commit that only changes function bodies, comments or tests skips it;
    the pre-push `--check` catches a multi-line signature edit this misses.
    """
    current = old = None
    for ln in diff.splitlines():
        if ln.startswith("--- "):
            old = ln[6:] if ln.startswith("--- a/") else None
        elif ln.startswith("+++ "):
            current = ln[6:] if ln.startswith("+++ b/") else old  # a deleted file removes its declarations
        elif current and current.endswith(".mojo") and current.split("/")[0] in dirs and DECL_LINE.match(ln):
            return True
    return False


def precommit_plan(staged, added, dirs, decl_changed=False):
    """Return (checks, regen_structure) for the staged paths.

    checks: list of (label, argv). Pure function of its arguments, so the
    selection rules are testable without a git repository.
    """
    checks = []
    touches_mojo = any(f.endswith(".mojo") or f == "scripts/arch_layers.toml" or f == "scripts/build_engine.sh" for f in staged)
    # docs/STRUCTURE.md is no longer written by commits: CI regenerates it on main,
    # so PR branches never edit it and merges do not conflict on it (see ci.yml).
    regen = False
    docs = [f for f in staged if f.endswith(".md") or f in DOC_FILES]
    if touches_mojo:
        checks.append(("arch check (layers, cycles, reach-through)", arch("check")))
        checks.append(("test tier headers", arch("tiers", "--check")))
    if docs or "scripts/arch_layers.toml" in staged:
        checks.append(("doc references", script("doclint.py")))
        checks.append(("layer tables match arch_layers.toml", script("layers_sync.py")))
    if "docs/ROADMAP.md" in staged:
        checks.append(("ROADMAP subsystem table matches the index", script("roadmap_status.py", "--check")))
    if any(f in ("pixi.toml", "pixi.lock") or f.startswith("scripts/") and f.endswith((".sh", ".toml")) for f in staged):
        checks.append(("floating-point flag policy", script("flag_policy.py")))
    if any(f.endswith(".mojo") for f in added) or "scripts/orphans_allow.txt" in staged:
        checks.append(("unwired modules", script("orphans.py")))
    return checks, regen


STRUCTURE_DOC = "docs/STRUCTURE.md"


def structure_edit_problem(staged_blob, main_blob):
    """Message when a commit would give docs/STRUCTURE.md content main does not have.

    The file flows one way: CI regenerates it on main, branches only pull it.
    staged_blob is None when the commit does not touch the file; main_blob is
    None when origin/main is not fetched (nothing to compare against).
    """
    if staged_blob is None or main_blob is None or staged_blob == main_blob:
        return None
    return (f"{STRUCTURE_DOC} differs from origin/main. CI owns this file; take main's version:\n"
            f"    git checkout origin/main -- {STRUCTURE_DOC}")


def _blob(rev_path):
    p = subprocess.run(["git", "rev-parse", "-q", "--verify", rev_path], cwd=ROOT, capture_output=True, text=True)
    return p.stdout.strip() or None


def cmd_pre_commit():
    staged = git_lines("diff", "--cached", "--name-only", "--diff-filter=ACMR")
    added = git_lines("diff", "--cached", "--name-only", "--diff-filter=A")
    if not staged:
        return 0
    if STRUCTURE_DOC in staged:
        main_blob = _blob(f"origin/main:{STRUCTURE_DOC}")
        if main_blob is None:
            print(f"[hooks] warn origin/main not fetched: cannot check {STRUCTURE_DOC} (git fetch origin main)")
        problem = structure_edit_problem(_blob(f":{STRUCTURE_DOC}"), main_blob)
        if problem:
            print(f"[hooks] FAIL {problem}")
            return 1
    dirs = engine_dirs()
    diff = subprocess.run(["git", "diff", "--cached", "-U0", "--", "*.mojo"], cwd=ROOT, capture_output=True, text=True).stdout
    checks, _ = precommit_plan(staged, added, dirs, declaration_changed(diff, dirs))
    ok = True
    for label, argv in checks:
        ok = run(label, argv) and ok
    return 0 if ok else 1


# --------------------------------------------------------------------------- pre-push

CHANGELOG_BEHIND_WARN = 150


def changelog_behind():
    """Commits between HEAD and the newest commit CHANGELOG.md lists, or None.

    The file groups by type, so the newest listed commit is the first one in
    `git log` order whose 7-character hash appears in it.
    """
    path = ROOT / "CHANGELOG.md"
    if not path.exists():
        return None
    listed = set(re.findall(r"\(([0-9a-f]{7})\)\s*$", path.read_text(encoding="utf-8"), re.M))
    p = subprocess.run(["git", "log", "--format=%H"], cwd=ROOT, capture_output=True, text=True)
    for behind, full in enumerate(p.stdout.split()):
        if full[:7] in listed:
            return behind
    return None


def cmd_pre_push():
    checks = [
        ("gate tool selftest", ["bash", str(ROOT / "scripts" / "agent_gate.sh"), "--selftest"]),
        ("arch check", arch("check")),
        ("test tier headers", arch("tiers", "--check")),
        ("doc references", script("doclint.py")),
        ("layer tables match arch_layers.toml", script("layers_sync.py")),
        ("ROADMAP subsystem table matches the index", script("roadmap_status.py", "--check")),
        ("unwired modules", script("orphans.py")),
        ("floating-point flag policy", script("flag_policy.py")),
        ("benchmark template / files / report", script("perf.py", "governance")),
        ("benchmark report not older than any bench", script("bench_fresh.py")),
    ]
    ok = True
    for label, argv in checks:
        ok = run(label, argv) and ok
    behind = changelog_behind()
    if behind is not None and behind > CHANGELOG_BEHIND_WARN:
        print(f"[hooks] warn CHANGELOG.md is {behind} commits behind HEAD (pixi run changelog; not blocking)")
    return 0 if ok else 1


# --------------------------------------------------------------------------- Claude Code hooks


def rel_path(p):
    try:
        return str(Path(p).resolve().relative_to(ROOT))
    except ValueError:
        return None


def pre_edit_problem(rel):
    if rel in GENERATED:
        return f"{rel} is generated; regenerate it with `{GENERATED[rel]}` instead of editing it."
    for prefix, how in GENERATED_PREFIX.items():
        if rel.startswith(prefix):
            return f"{rel} is a recorded golden; update it with `{how}`."
    return None


def command_text(cmd):
    """The command with heredoc bodies and quoted strings removed, so a rule only sees what is executed.

    A guardrail, not a security boundary: `bash -c "..."` hides its payload.
    """
    out, skip_until = [], None
    for ln in cmd.splitlines():
        if skip_until is not None:
            if ln.strip() == skip_until:
                skip_until = None
            continue
        m = re.search(r"<<-?\s*['\"]?(\w+)['\"]?", ln)
        if m:
            skip_until = m.group(1)
        out.append(ln)
    return re.sub(r"'[^']*'|\"[^\"]*\"", "''", "\n".join(out))


def pre_bash_problem(cmd):
    text = command_text(cmd)
    boundary = r"(?:^|[;&|(]|\bsudo\s)\s*"
    if re.search(boundary + r"git\b[^;&|\n]*\bcommit\b[^;&|\n]*--no-verify", text, re.M):
        return "git commit --no-verify skips the repository hooks; fix what the hook reports instead."
    if re.search(boundary + r"git\b[^;&|\n]*\bpush\b[^;&|\n]*--no-verify", text, re.M):
        return "git push --no-verify skips the pre-push checks; fix what they report instead."
    if re.search(boundary + r"git\b[^;&|\n]*\badd\b[^;&|\n]*(?:\s-f\b|--force)", text, re.M) and re.search(
        r"(^|[\s/])(build|build64|\.pixi|\.campaign)(/|\s|$)", text
    ):
        return "build/, build64/, .pixi/ and .campaign/ are never committed (CLAUDE.md)."
    return None


def post_edit_problems(rel, text):
    out = []
    if re.fullmatch(r"tests/test_[^/]+\.mojo", rel):
        first = text.splitlines()[0] if text else ""
        if not TIER_HEADER.match(first):
            out.append(f"{rel}: line 1 must be `# tier: <unit|component|integration|system|stress>`; the test runner fails without it.")
    return out


def read_hook_input():
    try:
        return json.load(sys.stdin)
    except (json.JSONDecodeError, ValueError):
        return {}


def cmd_claude_pre():
    data = read_hook_input()
    tool, inp = data.get("tool_name", ""), data.get("tool_input", {}) or {}
    problem = None
    if tool in ("Edit", "Write", "MultiEdit", "NotebookEdit"):
        rel = rel_path(inp.get("file_path") or inp.get("notebook_path") or "")
        problem = pre_edit_problem(rel) if rel else None
    elif tool == "Bash":
        problem = pre_bash_problem(inp.get("command", ""))
    if problem:
        print(problem, file=sys.stderr)
        return 2
    return 0


def cmd_claude_post():
    data = read_hook_input()
    inp = data.get("tool_input", {}) or {}
    path = inp.get("file_path") or ""
    rel = rel_path(path) if path else None
    if not rel or not rel.endswith(".mojo"):
        return 0
    problems = []
    full = ROOT / rel
    if full.exists():
        problems += post_edit_problems(rel, full.read_text(encoding="utf-8", errors="replace"))
    if rel.split("/")[0] in engine_dirs():
        p = subprocess.run(arch("check"), cwd=ROOT, capture_output=True, text=True)
        if p.returncode != 0:
            problems.append("arch check failed after this edit:\n" + (p.stdout + p.stderr).strip())
    if problems:
        print("\n".join(problems), file=sys.stderr)
        return 2
    return 0


# --------------------------------------------------------------------------- selftest


def selftest():
    good = [
        "feat(physics): ropes and cables (17.41)",
        "fix(collision): narrowphase tolerance",
        "docs: progress notes for 17.42",
        "test: golden for tiers",
        "feat!: breaking change",
        "Merge pull request #68 from x/y",
        "fixup! feat(ai): a",
        "# comment first\nci(gate): run structure check",
    ]
    bad = ["physics: old style", "Feat(physics): caps", "feat(physics) missing colon", "feat(Physics): caps scope", "", "# only a comment", "feat(physics):no space"]
    for m in good:
        assert subject_problem(m) is None, ("should pass", m)
    for m in bad:
        assert subject_problem(m) is not None, ("should fail", m)

    dirs = {"physics", "collision", "harness"}
    checks, regen = precommit_plan(["physics/solver6.mojo"], [], dirs)
    assert [c[0] for c in checks] == ["arch check (layers, cycles, reach-through)", "test tier headers"] and not regen
    assert not precommit_plan(["physics/solver6.mojo"], [], dirs, decl_changed=True)[1], "commits never regenerate the doc"
    assert not precommit_plan(["scripts/arch_layers.toml"], [], dirs)[1]
    body_only = "+++ b/physics/solver6.mojo\n@@ -1 +1 @@\n-    x = 1\n+    x = 2\n"
    new_def = "+++ b/physics/solver6.mojo\n@@ -1,0 +2 @@\n+def zz() -> Int:\n"
    assert not declaration_changed(body_only, dirs) and declaration_changed(new_def, dirs)
    assert not declaration_changed(new_def.replace("physics/", "tests/"), dirs), "tests are not in the structure doc"
    assert declaration_changed("+++ b/harness/x.mojo\n-struct A:\n", dirs)
    assert declaration_changed("--- a/physics/gone.mojo\n+++ /dev/null\n-def gone():\n", dirs), "deleting a module changes the doc"
    checks, regen = precommit_plan(["tests/test_vec.mojo"], [], dirs)
    assert checks and not regen, "a test edit runs arch checks but does not regenerate the structure doc"
    checks, regen = precommit_plan(["docs/ROADMAP.md"], [], dirs)
    assert {c[0] for c in checks} == {"doc references", "layer tables match arch_layers.toml", "ROADMAP subsystem table matches the index"} and not regen
    checks, regen = precommit_plan(["README.md"], [], dirs)
    assert {c[0] for c in checks} == {"doc references", "layer tables match arch_layers.toml"}
    checks, _ = precommit_plan(["pixi.toml"], [], dirs)
    assert [c[0] for c in checks] == ["floating-point flag policy"]
    checks, _ = precommit_plan(["physics/new.mojo"], ["physics/new.mojo"], dirs)
    assert "unwired modules" in [c[0] for c in checks]
    checks, regen = precommit_plan(["python/ludens/_capi.py"], [], dirs)
    assert checks == [] and not regen

    assert structure_edit_problem(None, "a") is None, "a commit that does not touch the doc passes"
    assert structure_edit_problem("a", "a") is None, "main's version (pulled or merged) passes"
    assert structure_edit_problem("b", "a"), "any other content is refused"
    assert structure_edit_problem("b", None) is None, "no origin/main to compare: not blocked"
    assert pre_edit_problem("BENCHMARK_REPORT.md") and pre_edit_problem("CHANGELOG.md")
    assert pre_edit_problem("docs/STRUCTURE.md") and pre_edit_problem("tests/golden/test_stdout.txt")
    assert pre_edit_problem("physics/solver6.mojo") is None and pre_edit_problem("docs/ROADMAP.md") is None
    assert pre_bash_problem("git commit --no-verify -m x")
    assert pre_bash_problem("git push origin main --no-verify")
    assert pre_bash_problem("git add -f build/libludens.so")
    assert pre_bash_problem("git add --force .pixi")
    assert pre_bash_problem("git add physics/solver6.mojo") is None
    assert pre_bash_problem("git commit -m 'fix: x'") is None
    assert pre_bash_problem("cd x && git commit -a --no-verify") and pre_bash_problem("git -C . commit --no-verify")
    assert pre_bash_problem("git commit -m 'mentions --no-verify in prose'") is None
    assert pre_bash_problem("python3 - <<'E'\ntext = 'git commit --no-verify'\nE\n") is None
    assert pre_bash_problem("cat > f <<EOF\ngit commit --no-verify\nEOF\n") is None
    assert pre_bash_problem("python3 -c \"print('git add -f build/x')\"") is None
    assert pre_bash_problem("pixi run gate -- --update-golden") is None

    assert post_edit_problems("tests/test_x.mojo", "# tier: unit\nfrom a import b\n") == []
    assert post_edit_problems("tests/test_x.mojo", "from a import b\n")
    assert post_edit_problems("tests/test_x.mojo", "# tier: bogus\n")
    assert post_edit_problems("tests/test_x.mojo", "# tier: unit  (override: why)\n") == []
    assert post_edit_problems("physics/solver6.mojo", "from a import b\n") == []
    print("selftest ok")
    return 0


def main(argv):
    if not argv:
        print(__doc__, file=sys.stderr)
        return 2
    cmd = argv[0]
    if cmd == "--selftest":
        return selftest()
    if cmd == "commit-msg" and len(argv) == 2:
        return cmd_commit_msg(argv[1])
    if cmd == "pre-commit":
        return cmd_pre_commit()
    if cmd == "pre-push":
        return cmd_pre_push()
    if cmd == "claude-pre":
        return cmd_claude_pre()
    if cmd == "claude-post":
        return cmd_claude_post()
    print(__doc__, file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
