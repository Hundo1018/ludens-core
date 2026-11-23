#!/usr/bin/env python3
"""Check `.abc` files written by `geometry.abc_file` with Blender's Alembic importer (ROADMAP 17.63).

`tests/test_abc_file.mojo` writes `build/abc/<name>.abc` and `<name>.txt`,
the samples it wrote:

    o NAME KIND        object (KIND: mesh | points | curves)
    t I                frame I (time I / 24 s)
    p X Y Z            a vertex / point, in order, as f32 bit patterns (hex)
    f A B C ...        a face, vertex indices counter-clockwise (meshes)
    c N N ...          vertex count per curve (curves)

For each `.abc`, this resets Blender, imports the file
(`bpy.ops.wm.alembic_import`), and for every object and frame sets the
scene frame and reads the evaluated object: vertex / point positions
(Blender converts Alembic's Y-up to Z-up as (x, -z, y); undone here) must
equal the written f32 values exactly, mesh faces must equal the written
vertex lists in order, curve sizes the written counts.

Needs the `bpy` module (Blender as a Python module, PyPI, Python 3.13):
when it is not importable the script creates `build/bpy-venv` (once) and
runs itself there. Checked with Blender 5.2.2.

Usage: abc_check.py [DIR]   (default build/abc). Exit status 1 on any
mismatch, 2 if `bpy` is not importable.
"""

import os
import struct
import subprocess
import sys
from pathlib import Path

VENV = Path("build/bpy-venv")


def reexec_in_venv() -> int:
    """Run this script again under build/bpy-venv (Python 3.13 from
    `pixi exec`, `bpy` from PyPI), creating it on first use."""
    py = VENV / "bin" / "python"
    if not py.exists():
        print(f"abc_check: creating {VENV} (Python 3.13 + bpy, ~400 MB, once)", flush=True)
        subprocess.run(["pixi", "exec", "--spec", "python=3.13", "--", "python", "-m", "venv", str(VENV)], check=True)
        subprocess.run([str(py), "-m", "pip", "install", "-q", "bpy"], check=True)
    env = dict(os.environ, ABC_CHECK_IN_VENV="1")
    return subprocess.run([str(py), __file__, *sys.argv[1:]], env=env, check=False).returncode


def f32(v: float) -> float:
    return struct.unpack("<f", struct.pack("<f", v))[0]


def parse(txt: Path) -> dict:
    objs: dict = {}
    cur = None
    frame = None
    for line in txt.read_text().splitlines():
        w = line.split()
        if not w:
            continue
        if w[0] == "o":
            cur = {"kind": w[2], "frames": {}}
            objs[w[1]] = cur
        elif w[0] == "t":
            frame = {"p": [], "f": [], "c": []}
            cur["frames"][int(w[1])] = frame
        elif w[0] == "p":
            frame["p"].append(tuple(struct.unpack("<f", struct.pack("<I", int(x, 16)))[0] for x in w[1:4]))
        elif w[0] == "f":
            frame["f"].append([int(x) for x in w[1:]])
        elif w[0] == "c":
            frame["c"] = [int(x) for x in w[1:]]
    return objs


def yup(co) -> tuple:
    """Blender's Z-up coordinate back to the file's Y-up one."""
    return (co[0], co[2], -co[1])


def check_file(abc: Path, bpy) -> list[str]:
    errs: list[str] = []
    want = parse(abc.with_suffix(".txt"))
    bpy.ops.wm.read_factory_settings(use_empty=True)
    scene = bpy.context.scene
    scene.render.fps = 24
    scene.render.fps_base = 1
    bpy.ops.wm.alembic_import(filepath=str(abc), as_background_job=False)
    frames_checked = 0
    for name, obj in want.items():
        ob = bpy.data.objects.get(name)
        if ob is None:
            errs.append(f"{abc.name}: no object {name!r} after import ({[o.name for o in bpy.data.objects]})")
            continue
        for t, fr in sorted(obj["frames"].items()):
            scene.frame_set(t)
            dg = bpy.context.evaluated_depsgraph_get()
            ev = ob.evaluated_get(dg)
            where = f"{abc.name}:{name}@{t}"
            if obj["kind"] == "mesh":
                me = ev.to_mesh()
                got_p = [yup(v.co) for v in me.vertices]
                got_f = [list(p.vertices) for p in me.polygons]
                ev.to_mesh_clear()
                if got_f != fr["f"]:
                    errs.append(f"{where}: faces {got_f[:3]}... vs {fr['f'][:3]}... ({len(got_f)} vs {len(fr['f'])})")
            elif obj["kind"] == "points":
                data = ev.data
                got_p = [yup(a.vector) for a in data.attributes["position"].data]
            else:
                data = ev.data
                got_p = [yup(a.vector) for a in data.attributes["position"].data]
                sizes = [c.points_length for c in data.curves]
                if sizes != fr["c"]:
                    errs.append(f"{where}: curve sizes {sizes} vs {fr['c']}")
            got_p = [tuple(f32(c) for c in p) for p in got_p]
            if len(got_p) != len(fr["p"]):
                errs.append(f"{where}: {len(got_p)} positions vs {len(fr['p'])}")
            else:
                bad = [i for i in range(len(got_p)) if got_p[i] != fr["p"][i]]
                if bad:
                    i = bad[0]
                    errs.append(f"{where}: {len(bad)} positions differ, e.g. #{i} {got_p[i]} vs {fr['p'][i]}")
            frames_checked += 1
    print(f"{abc.name}: {len(want)} objects, {frames_checked} object-frames: {'ok' if not errs else 'MISMATCH'}")
    return errs


def main() -> int:
    d = Path(sys.argv[1] if len(sys.argv) > 1 else "build/abc")
    try:
        import bpy  # type: ignore[import-not-found]
    except ImportError:
        if os.environ.get("ABC_CHECK_IN_VENV"):
            print("abc_check: the bpy module (Blender) is not importable", file=sys.stderr)
            return 2
        return reexec_in_venv()
    print(f"Blender {bpy.app.version_string}")
    files = sorted(d.glob("*.abc"))
    if not files:
        print(f"abc_check: no .abc files in {d} (run tests/test_abc_file.mojo first)", file=sys.stderr)
        return 1
    errs: list[str] = []
    for f in files:
        errs += check_file(f.resolve(), bpy)
    for e in errs:
        print("  " + e)
    print(f"abc_check: {len(files)} files, {'OK' if not errs else f'{len(errs)} mismatches'}")
    return 1 if errs else 0


if __name__ == "__main__":
    sys.exit(main())
