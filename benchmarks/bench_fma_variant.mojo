"""FMA off vs on (ROADMAP 17.89 / #75): the reference build targets `x86-64` (no FMA) so the
native result equals wasm64 bit for bit; `skylake` (AVX2 + FMA) is the speed variant.

The reference scene of `tools/wasm/ref_entry.mojo` (12 bodies x 240 ticks, then 1012 bodies x
120 ticks, 360 ticks in all) is built for each CPU with the wasm gate's defines and run 7 times;
the row is the fastest run per tick (process start included, about 1 ms of 600). The label
carries the world hash: the two CPUs differ in it by design.

Run: pixi run mojo run -I build benchmarks/bench_fma_variant.mojo
"""

from std.python import Python, PythonObject
from harness.bench import BenchTable

comptime TICKS = 360
comptime RUNS = 7


def _sh(sp: PythonObject, cmd: PythonObject) raises -> String:
    var r = sp.run(cmd, capture_output=True, text=True)
    if Int(py=r.returncode) != 0:
        raise Error("command failed: " + String(cmd) + "\n" + String(r.stdout) + String(r.stderr))
    return String(r.stdout)


def main() raises:
    var t = BenchTable("FMA off vs on: the 12 + 1012 body reference scene, native (17.89 / #75)")
    var sp = Python.import_module("subprocess")
    var time = Python.import_module("time")
    var tmp = String(Python.import_module("tempfile").mkdtemp(prefix="ludens_bench_fma_"))
    var cpus = List[String]()
    cpus.append("x86-64")
    cpus.append("skylake")
    for cpu in cpus:
        var exe = tmp + "/ref_" + cpu
        _ = _sh(
            sp,
            Python.list(
                "mojo", "build", "--target-cpu", cpu, "-D", "LUDENS_SERIAL=True", "-D", "ASSERT=none",
                "-I", "build", "-o", exe, "tools/wasm/ref_entry.mojo",
            ),
        )
        var best = Int.MAX
        var out = String()
        for _ in range(RUNS):
            var t0 = Int(py=time.perf_counter_ns())
            out = _sh(sp, Python.list(exe))
            var dt = Int(py=time.perf_counter_ns()) - t0
            if dt < best:
                best = dt
        var h = String()
        for line in out.split("\n"):
            if line.startswith("hash1012"):
                h = String(line.split(" ")[1])
        var label = cpu + (" (reference, no FMA" if cpu == "x86-64" else " (speed variant, AVX2 + FMA") + "; 1012-body hash " + h + ")"
        t.add(label, 1012, "tick", best, TICKS)
    _ = Python.import_module("shutil").rmtree(tmp)
    t.print_report()
