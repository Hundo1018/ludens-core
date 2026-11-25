"""Does the C-ABI library compute the same world as a native Mojo program on a CPU with FMA? (ROADMAP 17.96)

usage: pixi run python3 scripts/fma_parity_probe.py [--cpu skylake] [--ticks 120]      (after `pixi run build`)

For each shape (box, capsule, hull) one world is built twice: by a C program through build/…/libludens.so (the sizes
arrive as run-time arguments) and by a Mojo program through EmbedWorld (the sizes are literals the compiler can fold).
Both are compiled for --cpu. Each prints the world hash at tick 0 and after --ticks; the script compares them and
exits non-zero on a difference.

Why this exists: an expression such as `hy * hy + hz * hz` is fused into one FMA (one rounding) or not (two) per
inlined copy. A mass-property function inlined into both programs then differs by 1 ulp between them, the hash
differs at tick 0, and the worlds drift apart (seen in test_capi on linux-aarch64 with Inertia3.capsule). The x86-64
test target has no FMA, so the test suite cannot see it there; this probe compiles for an FMA CPU on purpose.
Sizes are chosen not to be exactly representable (0.3, 0.7, 0.45) so that a fused and an unfused sum differ.
"""
import argparse
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent

# name -> (C statement creating the body `b` in world `w`, Mojo statement creating `b` in `w`)
SHAPES = {
    "box": ("ld_body b = ld_body_add_box(w, 0.0f, 3.0f, 0.0f, 0.3f, 0.7f, 0.45f, 1.3f, 0);",
            "var b = w.add_box(_v(0, 3, 0), _v(0.3, 0.7, 0.45), 1.3, False)"),
    "capsule": ("ld_body b = ld_body_add_capsule(w, 0.0f, 3.0f, 0.0f, 0.3f, 0.7f, 1.3f, 0);",
                "var b = w.add_capsule(_v(0, 3, 0), 0.3, 0.7, 1.3, False)"),
    "hull": ("float hv[12] = {0.0f, 0.0f, 0.0f, 0.7f, 0.0f, 0.0f, 0.0f, 0.3f, 0.0f, 0.0f, 0.0f, 0.45f};\n"
             "    ld_body b = ld_body_add_hull(w, 0.0f, 3.0f, 0.0f, hv, 4, 1.3f, 0);",
             "var hv = List[Vec3]()\n"
             "    for p in [_v(0, 0, 0), _v(0.7, 0, 0), _v(0, 0.3, 0), _v(0, 0, 0.45)]:\n"
             "        hv.append(p)\n"
             "    var b = w.add_hull(_v(0, 3, 0), hv, 1.3, False)"),
}

C_FN = """
static void run_%(name)s(int ticks) {
    ld_world* w = NULL;
    ld_world_create(1.0 / 60.0, 0.0f, -9.8f, 0.0f, &w);
    ld_body_add_box(w, 0.0f, -0.5f, 0.0f, 20.0f, 0.5f, 20.0f, 0.0f, 1);
    %(c)s
    ld_body_set_velocity(w, b, 0.3f, 0.0f, 0.0f, 0.7f, 1.1f, -0.4f);
    uint64_t h0 = 0, h1 = 0;
    ld_world_hash(w, &h0);
    ld_world_step_ticks(w, ticks);
    ld_world_hash(w, &h1);
    printf("%(name)s %%llu %%llu\\n", (unsigned long long)h0, (unsigned long long)h1);
    ld_world_destroy(w);
}
"""

MOJO_FN = """
def run_%(name)s(ticks: Int) raises:
    var w = EmbedWorld(1.0 / 60.0, _v(0, -9.8, 0))
    _ = w.add_box(_v(0, -0.5, 0), _v(20, 0.5, 20), 0, True)
    %(mojo)s
    w.set_velocity(b, _v(0.3, 0, 0), _v(0.7, 1.1, -0.4))
    var h0 = w.hash()
    for _ in range(ticks):
        w.physics_tick()
    print("%(name)s", h0, w.hash())
"""


def sources(ticks):
    c = '#include <stdio.h>\n#include "ludens.h"\n'
    m = ("from embed.world import EmbedWorld\nfrom geometry.vec import Real, Vec3\n\n\n"
         "def _v(x: Real, y: Real, z: Real) -> Vec3:\n    return Vec3(x, y, z, 0)\n")
    for name, (cs, ms) in SHAPES.items():
        c += C_FN % {"name": name, "c": cs}
        m += MOJO_FN % {"name": name, "mojo": ms}
    c += "int main(void) {\n" + "".join(f"    run_{n}({ticks});\n" for n in SHAPES) + "    return 0;\n}\n"
    m += "\n\ndef main() raises:\n" + "".join(f"    run_{n}({ticks})\n" for n in SHAPES)
    return c, m


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--cpu", default="skylake", help="target CPU for both sides (default skylake: has FMA)")
    ap.add_argument("--ticks", type=int, default=120)
    args = ap.parse_args()
    c_src, m_src = sources(args.ticks)
    with tempfile.TemporaryDirectory(prefix="fma_parity_") as d:
        d = Path(d)
        (d / "probe.c").write_text(c_src)
        (d / "probe.mojo").write_text(m_src)
        subprocess.run(["mojo", "build", "--emit", "shared-lib", "--target-cpu", args.cpu, "-I", "build", "-o",
                        str(d / "libludens.so"), "embed/capi.mojo"], cwd=ROOT, check=True)
        subprocess.run(["gcc", "-std=c99", "-I" + str(ROOT / "embed"), str(d / "probe.c"), "-L" + str(d), "-lludens",
                        "-lm", "-Wl,-rpath," + str(d), "-o", str(d / "probe_c")], check=True)
        c_out = subprocess.run([str(d / "probe_c")], capture_output=True, text=True, check=True).stdout.split("\n")
        m_out = subprocess.run(["mojo", "run", "--target-cpu", args.cpu, "-I", "build", str(d / "probe.mojo")], cwd=ROOT,
                               capture_output=True, text=True, check=True).stdout.split("\n")
    bad = 0
    print(f"cpu {args.cpu}, {args.ticks} ticks: world hash from the C-ABI library vs native Mojo")
    for cl, ml in zip(c_out, m_out, strict=True):
        if not cl:
            continue
        name, c0, c1 = cl.split()
        _, m0, m1 = ml.split()
        t0 = "same" if c0 == m0 else "DIFFERS"
        t1 = "same" if c1 == m1 else "DIFFERS"
        bad += (c0 != m0) + (c1 != m1)
        print(f"  {name:8} tick 0 {t0:8} after {args.ticks} {t1}")
    print("fma parity:", "PASS" if not bad else "FAIL")
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
