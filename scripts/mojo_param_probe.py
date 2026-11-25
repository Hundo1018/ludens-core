"""Which compile-time parameterization does this Mojo toolchain support? (ludens: the host World[B] and the render
pipeline, design A + C).

usage: pixi run python3 scripts/mojo_param_probe.py <project root> [probe name ...]

Run it inside that project's pixi environment (`pixi run python3 ...`) so `mojo` is the pinned compiler. Each probe is
a file tools/mojo_probes/<name>.mojo whose first two lines say what to expect:

    # expect: <the exact stdout of a run>      (ignored by the compile-only modes)
    # mode: run | shlib | core-shlib | engine-build | must-fail

  run           mojo run
  shlib         mojo build --emit shared-lib (C-ABI exports compile)
  core-shlib    the same with -I <root>/build; root is a ludens-core checkout after `pixi run build`
  must-fail     mojo build must be refused (a type error the design relies on)
  engine-build  compiled with the engine's own scripts/build_core.build_native (its include paths: ludens-core
                sources, wgpu-mojo); root is a ludens-engine checkout; compile only

Prints PASS / FAIL per probe with the first compiler error, or SKIP when the probe's mode does not apply to the root
(core-shlib needs <root>/build, engine-build needs <root>/scripts/build_core.py); exits non-zero if any probe fails.
"""
import subprocess
import sys
import tempfile
from pathlib import Path

HERE = Path(__file__).resolve().parent.parent / "tools/mojo_probes"


def header(path):
    lines = path.read_text().splitlines()
    meta = {}
    for line in lines[:2]:
        k, _, v = line.lstrip("# ").partition(": ")
        meta[k] = v
    return meta.get("expect", ""), meta.get("mode", "run")


def errors(text):
    return [l for l in text.splitlines() if "error" in l]


def run(root, path):
    name = path.stem
    expect, mode = header(path)
    with tempfile.TemporaryDirectory(prefix="mojo_probe_") as d:
        if mode in ("shlib", "core-shlib"):
            if mode == "core-shlib" and not (root / "build").is_dir():
                return name, None, "skipped: core-shlib needs <root>/build (pixi run build)"
            inc = ["-I", str(root / "build")] if mode == "core-shlib" else []
            r = subprocess.run(["mojo", "build", "--emit", "shared-lib", *inc, "-o", str(Path(d) / "lib.so"), str(path)],
                               cwd=root, capture_output=True, text=True, check=False)
            return name, r.returncode == 0, "compiled" if r.returncode == 0 else errors(r.stdout + r.stderr)
        if mode == "engine-build":
            if not (root / "scripts/build_core.py").is_file():
                return name, None, "skipped: engine-build needs a ludens-engine checkout as root"
            sys.path.insert(0, str(root / "scripts"))
            import build_core  # noqa: E402  (the engine's include paths and environment)
            entry = root / "build" / f"probe_{name}.mojo"
            entry.parent.mkdir(exist_ok=True)
            entry.write_text(path.read_text())
            try:
                build_core.build_native(str(entry.relative_to(root)), root / "build" / f"probe_{name}", force=True)
            except SystemExit as e:
                return name, False, errors(str(e)) or [str(e)[:300]]
            finally:
                entry.unlink()
            return name, True, "compiled"
        if mode == "must-fail":
            r = subprocess.run(["mojo", "build", "-o", str(Path(d) / "x"), str(path)], cwd=root, capture_output=True, text=True, check=False)
            if r.returncode != 0:
                return name, True, "rejected: " + (errors(r.stdout + r.stderr) or ["?"])[0].split("error: ")[-1][:110]
            return name, False, "compiled, but it must be rejected"
        r = subprocess.run(["mojo", "run", str(path)], cwd=root, capture_output=True, text=True, check=False)
        out = r.stdout.strip()
        if r.returncode == 0 and out == expect:
            return name, True, out
        return name, False, errors(r.stdout + r.stderr) or [f"printed {out!r}, expected {expect!r}"]


def main():
    root = Path(sys.argv[1]).resolve()
    names = sys.argv[2:] or sorted(p.stem for p in HERE.glob("*.mojo"))
    failed = 0
    for n in names:
        name, ok, detail = run(root, HERE / f"{n}.mojo")
        if ok is None:
            print(f"SKIP {name}: {detail}")
        elif ok:
            print(f"PASS {name}: {detail}")
        else:
            failed += 1
            detail = detail if isinstance(detail, list) else [detail]
            print(f"FAIL {name}: {detail[0]}")
            for line in detail[1:3]:
                print("      ", line)
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
