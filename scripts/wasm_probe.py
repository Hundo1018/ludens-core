"""Which leaf kernels could ship as wasm today? (ROADMAP 17.76)

    pixi run wasm-probe            # every tools/wasm/kernel_*.mojo
    pixi run wasm-probe -- --selftest

Modular's LLVM has no wasm backend; the known route is `mojo build --emit
llvm` and an external llc (PoC 2026-07-24). That route works only for code
that needs nothing from the Mojo runtime. For each `@export` function in a
kernel file this emits the LLVM IR, walks the call graph from that function,
and lists every reachable symbol that is only DECLARED (an import a wasm
module would need), ignoring `llvm.*` intrinsics. Zero imports = a candidate
leaf kernel. (The emitted module's `main` pulls in runtime start-up symbols;
they are not reachable from the kernel and are not counted.)

It also checks the core/shell split (ROADMAP 17.76): the import closure of
each kernel, followed through engine source under `<pkg>/<mod>.mojo`, must not
reach a shell package (`embed`, `harness`, `oop`, `benchmarks`, `examples`,
`experiments`). A wasm core may not depend on the C-ABI shell or on the test
harness; a violation names the module and the shell import it adds.
"""

import argparse
import os
import re
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
# Mojo mangles names into quoted LLVM identifiers (`@"pkg::mod::f[...](...)"`), so a
# symbol is either a quoted run or a bare word. References count whether or not a call
# follows: a function address passed as an argument (dispatch trampolines) is reachable too.
SYM = r'@(?:"([^"]+)"|([\w.$]+))'
DEFINE = re.compile(r"^define [^@]*" + SYM + r"\(")
DECLARE = re.compile(r"^declare [^@]*" + SYM + r"\(")
CALLEE = re.compile(SYM)


def _name(m: "re.Match[str]") -> str:
    return m.group(1) or m.group(2)


def parse(ir: str) -> tuple[dict[str, set[str]], set[str]]:
    """(function -> symbols referenced in its body, declared symbols)."""
    bodies: dict[str, set[str]] = {}
    declared: set[str] = set()
    cur = None
    for line in ir.splitlines():
        m = DEFINE.match(line)
        if m:
            cur = _name(m)
            bodies[cur] = set()
            continue
        m = DECLARE.match(line)
        if m:
            declared.add(_name(m))
            continue
        if cur is not None:
            if line.startswith("}"):
                cur = None
                continue
            for m in CALLEE.finditer(line):
                bodies[cur].add(_name(m))
    return bodies, declared


def imports(ir: str, root: str) -> list[str]:
    bodies, declared = parse(ir)
    seen, todo, out = set(), [root], set()
    while todo:
        f = todo.pop()
        if f in seen:
            continue
        seen.add(f)
        for c in bodies.get(f, ()):
            if c in bodies:
                todo.append(c)
            elif c in declared and not c.startswith("llvm."):
                out.add(c)
    return sorted(out)


def exported(src: str) -> list[str]:
    names, nxt = [], False
    for line in src.splitlines():
        if line.strip() == "@export":
            nxt = True
            continue
        if nxt:
            m = re.match(r"\s*def\s+(\w+)", line)
            if m:
                names.append(m.group(1))
            nxt = False
    return names


SHELL = frozenset({"embed", "harness", "oop", "benchmarks", "examples", "experiments"})
IMPORT = re.compile(r"^\s*(?:from\s+([\w.]+)\s+import|import\s+([\w.]+))", re.M)


def shell_reach(src_root: Path, kernel: Path) -> list[str]:
    """Violations: 'module -> shell.import' for each shell import in the closure of kernel."""
    seen, todo, out = set(), [kernel], []
    while todo:
        f = todo.pop()
        if f in seen or not f.exists():
            continue
        seen.add(f)
        for m in IMPORT.finditer(f.read_text(encoding="utf-8")):
            mod = (m.group(1) or m.group(2)).split(".")
            if mod[0] in SHELL:
                out.append(f"{f.relative_to(src_root)} -> {'.'.join(mod)}")
            elif mod[0] != "std" and len(mod) > 1:
                todo.append(src_root / mod[0] / ("/".join(mod[1:]) + ".mojo"))
    return sorted(out)


def run(files: list[Path]) -> int:
    worst = 0
    for f in files:
        with tempfile.TemporaryDirectory(prefix="wasm_") as d:
            ll = Path(d) / "k.ll"
            r = subprocess.run(["mojo", "build", "--emit", "llvm", "-I", "build", "-o", str(ll), str(f)],
                               cwd=ROOT, capture_output=True, text=True, encoding="utf-8")
            if r.returncode != 0:
                print(f"wasm-probe: {f}: emit failed\n{r.stderr[-1500:]}")
                worst = 1
                continue
            ir = ll.read_text(encoding="utf-8")
        for name in exported(f.read_text(encoding="utf-8")):
            imp = imports(ir, name)
            status = "LEAF (0 imports)" if not imp else f"{len(imp)} imports: {', '.join(imp)}"
            print(f"wasm-probe: {f.relative_to(ROOT)}::{name}: {status}")
            if name not in parse(ir)[0]:
                print(f"wasm-probe:   (exported function not found in IR)")
                worst = 1
        bad = shell_reach(ROOT, f)
        print(f"wasm-probe: {f.relative_to(ROOT)} core/shell split: "
              f"{'OK' if not bad else 'VIOLATION ' + '; '.join(bad)}")
        if bad:
            worst = 1
    return worst


# 17.89 W1: what the whole C-ABI may import in the wasm build. Engine-owned: allocator, write,
# clock. Std-owned (cannot be removed from engine code): the abort report (`dup fdopen fclose
# fflush`) and Error's stack-trace probe. ludens-wasm-rt's runtime defines them, so the linked
# wasm module imports only `host_write` and `host_now_ns` (measured 2026-11-02, build/ludens64.wasm).
CAPI_ALLOWED = frozenset({"KGEN_CompilerRT_AlignedAlloc", "KGEN_CompilerRT_AlignedFree", "write",
                          "clock_gettime"})
CAPI_STD_STUBS = frozenset({"dup", "fdopen", "fclose", "fflush", "KGEN_CompilerRT_GetStackTrace"})


def capi_unexpected(ir: str) -> list[str]:
    """Imports reachable from any `ld_*` export outside CAPI_ALLOWED | CAPI_STD_STUBS."""
    bodies, _ = parse(ir)
    got: set[str] = set()
    for r in (n for n in bodies if n.startswith("ld_")):
        got |= set(imports(ir, r))
    return sorted(got - CAPI_ALLOWED - CAPI_STD_STUBS)


def capi() -> int:
    """Emit embed/capi.mojo as the wasm build does and report unexpected imports."""
    with tempfile.TemporaryDirectory(prefix="wasm_capi_") as d:
        ll = Path(d) / "capi.ll"
        r = subprocess.run(["mojo", "build", "--emit", "llvm", "-D", "LUDENS_SERIAL=True", "-D", "ASSERT=none",
                            "-I", "build", "-o", str(ll), "embed/capi.mojo"],
                           cwd=ROOT, capture_output=True, text=True, encoding="utf-8")
        if r.returncode != 0:
            print(f"wasm-probe --capi: emit failed\n{r.stderr[-1500:]}")
            return 1
        bad = capi_unexpected(ll.read_text(encoding="utf-8"))
    print(f"wasm-probe --capi: {'OK' if not bad else 'UNEXPECTED IMPORTS ' + ', '.join(bad)}")
    return 1 if bad else 0


def selftest() -> int:
    ir = """declare void @ext_io(i32)
declare float @llvm.fma.f32(float, float, float)
define float @k(float %a) {
  %1 = call float @helper(float %a)
  ret float %1
}
define float @helper(float %a) {
  %1 = call float @llvm.fma.f32(float %a, float %a, float %a)
  ret float %1
}
define float @"pkg::k3[T](x)"(float %a) {
  %1 = call float @"pkg::inner[T](x)"(float %a)
  ret float %1
}
define float @"pkg::inner[T](x)"(float %a) {
  %1 = call i64 @"ext_quoted"(float %a)
  store ptr @"pkg::fnptr", ptr %p
  ret float %a
}
declare i64 @"ext_quoted"(float)
define void @"pkg::fnptr"() {
  call void @ext_via_ptr()
  ret void
}
declare void @ext_via_ptr()
define i32 @main() {
  call void @ext_io(i32 1)
  ret i32 0
}
define float @k2(float %a) {
  call void @ext_io(i32 2)
  ret float %a
}
"""
    checks = [
        ("transitive callee, intrinsic ignored -> leaf", imports(ir, "k") == [], imports(ir, "k")),
        ("main's runtime import not charged to the kernel", "ext_io" not in imports(ir, "k"), imports(ir, "k")),
        ("direct external call counted", imports(ir, "k2") == ["ext_io"], imports(ir, "k2")),
        ("quoted mangled names + address-taken callee followed",
         imports(ir, "pkg::k3[T](x)") == ["ext_quoted", "ext_via_ptr"], imports(ir, "pkg::k3[T](x)")),
        ("capi gate flags an unlisted import, accepts stubs",
         capi_unexpected('define i32 @ld_a() {\n call void @pthread_self()\n call void @dup()\n ret i32 0\n}\n'
                         'declare void @pthread_self()\ndeclare void @dup()\n') == ["pthread_self"], None),
        ("@export names found", exported("@export\ndef a(x: Int) abi(\"C\") -> Int:\n    return x\n") == ["a"], None),
    ]
    with tempfile.TemporaryDirectory(prefix="wasm_split_") as d:
        r = Path(d)
        (r / "core").mkdir()
        (r / "embed").mkdir()
        (r / "core/a.mojo").write_text("from core.b import f\n")
        (r / "core/b.mojo").write_text("from std.math import sqrt\nfrom embed.capi import x\n")
        (r / "core/c.mojo").write_text("from std.math import sqrt\n")
        (r / "embed/capi.mojo").write_text("")
        (r / "k_bad.mojo").write_text("from core.a import f\n")
        (r / "k_ok.mojo").write_text("from core.c import g\n")
        bad = shell_reach(r, r / "k_bad.mojo")
        checks.append(("shell import reached through two engine modules is reported",
                       bad == ["core/b.mojo -> embed.capi"], bad))
        ok_case = shell_reach(r, r / "k_ok.mojo")
        checks.append(("a core kernel with no shell import reports no violation", ok_case == [], ok_case))
    for name, ok, detail in checks:
        print(f"  [{'PASS' if ok else 'FAIL'}] wasm-probe selftest - {name} {detail if detail is not None else ''}")
    n = sum(1 for _, ok, _ in checks if ok)
    print(f"[{'PASS' if n == len(checks) else 'FAIL'}] wasm-probe selftest - {n} / {len(checks)} checks")
    return 0 if n == len(checks) else 1


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("files", nargs="*")
    ap.add_argument("--selftest", action="store_true")
    ap.add_argument("--capi", action="store_true", help="gate the C-ABI's import set (17.89 W1)")
    a = ap.parse_args()
    if a.selftest:
        return selftest()
    if a.capi:
        return capi()
    files = [ROOT / f for f in a.files] or sorted((ROOT / "tools/wasm").glob("kernel_*.mojo"))
    return run(files)


if __name__ == "__main__":
    sys.exit(main())
