# tier: integration
"""Python bindings, tested as a client would use them (ROADMAP 17.21).

1. `python/build_wheel.py` builds the wheel (library + bundled Mojo runtime,
   RUNPATH rewritten to `$ORIGIN`).
2. A fresh venv (system python3 when present) installs it with
   `pip install --no-index`: no repo path, no `-I build`.
3. `python/tests/client_check.py` runs with that venv's python, from a temp
   directory, with `env -i PATH=/usr/bin:/bin`. It checks its own isolation
   (no module or mapped library from under the repo root) plus bindings,
   errors, CVars and hot reload, and prints the scenario's results.
4. Here: every client check passed, and the Python-driven world hashes equal
   to the same scenario run natively on `EmbedWorld` (the scenario of
   test_capi, so Python == C == Mojo). Also: the ctypes prototype table
   names exactly the functions of `embed/ludens.h`.
"""

from std.python import Python, PythonObject
from harness.runner import Suite
from geometry.vec import Real, Vec3
from nav.heightfield import NavBakeConfig
from embed.world import EmbedWorld, EVENT_BEGAN, EVENT_ENDED
from embed.navigation import EmbedNav


def _v(x: Real, y: Real, z: Real) -> Vec3:
    return Vec3(x, y, z, 0)


def native_abi8() raises -> UInt64:
    """The 0.8 scene of client_check.py and tests/capi/host.c (same as test_capi's native_abi8)."""
    var w = EmbedWorld(1.0 / 60.0, _v(0, -9.8, 0))
    _ = w.add_box(_v(0, -0.5, 0), _v(20, 0.5, 20), 0, True)
    w.set_material_friction(0, 0.25)
    w.set_material_softness(0, 30, 0.5)
    _ = w.add_capsule(_v(0, 2, 0), 0.25, 0.5, 1, False)
    var kin = w.add_box(_v(3, 0.5, 0), _v(0.5, 0.5, 0.5), 1, False)
    w.set_kinematic(kin)
    w.set_velocity(kin, _v(-1, 0, 0), _v(0, 0, 0))
    var ja = w.add_box(_v(-2, 3, 0), _v(0.25, 0.25, 0.25), 0, True)
    var jb = w.add_box(_v(-2, 2, 0), _v(0.25, 0.25, 0.25), 1, False)
    var jc = w.add_box(_v(-2, 1, 0), _v(0.25, 0.25, 0.25), 1, False)
    var jd = w.add_box(_v(-1, 1, 0), _v(0.25, 0.25, 0.25), 1, False)
    var je = w.add_box(_v(-1, 2, 0), _v(0.25, 0.25, 0.25), 1, False)
    _ = w.add_ball_joint(ja, jb, _v(0, -0.5, 0), _v(0, 0.5, 0))
    _ = w.add_distance_joint(jb, jc, _v(0, -0.25, 0), _v(0, 0.25, 0), 0.5)
    _ = w.add_hinge_joint(jc, jd, _v(0.5, 0, 0), _v(-0.5, 0, 0), _v(0, 0, 1))
    var weld = w.add_weld_joint(jd, je, _v(0, 0.5, 0), _v(0, -0.5, 0))
    for _ in range(120):
        w.physics_tick()
    w.remove_joint(weld)
    for _ in range(60):
        w.physics_tick()
    return w.hash()


struct Native:
    """The parity scenario of client_check.py (same as the C host of test_capi)."""

    var w: EmbedWorld
    var player: Int64
    var began: Int
    var ended: Int

    def __init__(out self) raises:
        self.w = EmbedWorld(1.0 / 60.0, _v(0, -9.8, 0))
        _ = self.w.add_box(_v(0, -0.5, 0), _v(20, 0.5, 20), 0, True)
        for i in range(4):
            for k in range(2):
                _ = self.w.add_box(_v(-3 + 2 * Real(i), 0.25 + 0.51 * Real(k), 2), _v(0.25, 0.25, 0.25), 1, False)
        for i in range(3):
            _ = self.w.add_sphere(_v(-2 + 2 * Real(i), 1 + 0.5 * Real(i), -2), 0.3, 0.5, False)
        self.player = self.w.add_box(_v(0, 0.4, 0), _v(0.4, 0.4, 0.4), 2, False)
        self.began = 0
        self.ended = 0

    def tick(mut self) raises:
        var vx: Real = 0
        var vz: Real = 0
        var k = (self.w.tick // 60) % 4
        match k:
            case 0:
                vx = 3
            case 1:
                vz = 3
            case 2:
                vx = -3
            case _:
                vz = -3
        var st = self.w.state(self.player)
        self.w.set_velocity(self.player, _v(vx, st.vel[1], vz), _v(0, 0, 0))
        self.w.physics_tick()
        for e in self.w.tick_events:
            if Int(e.kind) == EVENT_BEGAN:
                self.began += 1
            elif Int(e.kind) == EVENT_ENDED:
                self.ended += 1


def _run(sp: PythonObject, cmd: PythonObject, cwd: String, env: PythonObject) raises -> PythonObject:
    return sp.run(cmd, capture_output=True, text=True, cwd=cwd, env=env)


def main() raises:
    var s = Suite("python_binding")
    var sp = Python.import_module("subprocess")
    var os = Python.import_module("os")
    var shutil = Python.import_module("shutil")
    var bi = Python.import_module("builtins")
    var repo = String(os.getcwd())
    var tmp = String(Python.import_module("tempfile").mkdtemp(prefix="ludens_pyclient_"))
    var work = tmp + "/work"
    _ = os.makedirs(work)

    # 1. wheel (Linux only: on another OS the builder must say so, ROADMAP 17.76)
    var r = sp.run(Python.list("python3", "python/build_wheel.py", "--out", tmp + "/dist"), capture_output=True, text=True)
    var plat = String(Python.import_module("sys").platform)
    if not plat.startswith("linux"):
        s.check(
            Int(py=r.returncode) != 0 and "Linux only" in String(r.stderr),
            "build_wheel.py refuses on " + plat + " with a message",
        )
        _ = shutil.rmtree(tmp)
        s.finish()
        return
    s.check(Int(py=r.returncode) == 0, "build_wheel.py succeeds")
    if Int(py=r.returncode) != 0:
        print(String(r.stderr))
        s.finish()
        return
    var whl = String(r.stdout).strip()
    var size = Int(py=os.path.getsize(whl))
    s.check(size > 0 and size < 16 * 1024 * 1024, "wheel size " + String(size // 1024) + " kB (< 16 MB)")

    # 2. clean venv + client install
    var py = String("/usr/bin/python3") if Bool(py=os.path.exists("/usr/bin/python3")) else String("python3")
    var clean = Python.dict()
    clean["PATH"] = "/usr/bin:/bin"
    clean["HOME"] = work
    r = _run(sp, Python.list(py, "-m", "venv", tmp + "/venv"), work, clean)
    s.check(Int(py=r.returncode) == 0, "fresh venv created with " + py)
    r = _run(sp, Python.list(tmp + "/venv/bin/python", "-m", "pip", "install", "--no-index", "-q", whl), work, clean)
    s.check(Int(py=r.returncode) == 0, "pip install --no-index of the wheel " + String(r.stderr).strip())

    # 3. client checks
    _ = shutil.copyfile("python/tests/client_check.py", work + "/client_check.py")
    r = _run(sp, Python.list(tmp + "/venv/bin/python", "client_check.py", repo, work), work, clean)
    var out = String(r.stdout)
    var ok = 0
    var failed = 0
    var kv = Python.dict()
    for line in out.split("\n"):
        var l = String(line)
        if l.startswith("check ok "):
            ok += 1
        elif l.startswith("check FAIL "):
            failed += 1
            print("  client:", l)
        else:
            var parts = l.split(" ")
            if len(parts) >= 2:
                var vals = Python.list()
                for p in parts[1:]:
                    _ = vals.append(String(p))
                kv[String(parts[0])] = vals
    if Int(py=r.returncode) != 0 and failed == 0:
        print(String(r.stderr))
    s.eqi(failed, 0, "client checks: " + String(ok) + " passed in the installed environment")
    s.check(ok >= 43, "client ran the full check list (" + String(ok) + ")")
    s.eqi(Int(py=r.returncode), 0, "client_check.py exit status")

    # 4. parity with the native run
    var nat = Native()
    for _ in range(120):
        var n = nat.w.ticks_due(1.0 / 60.0)
        for _ in range(n):
            nat.tick()
    for _ in range(120):
        nat.tick()
    s.check(String(kv.get("hash", Python.list("?"))[0]) == String(nat.w.hash()), "Python-driven world hash == native Mojo run (" + String(nat.w.hash()) + ")")
    s.check(String(kv.get("began", Python.list("?", "?", "?"))[0]) == String(nat.began), "Python subscriber BEGAN count == native")
    s.check(String(kv.get("began", Python.list("?", "?", "?"))[2]) == String(nat.ended), "Python subscriber ENDED count == native")
    s.check(String(kv.get("abi8_hash", Python.list("?"))[0]) == String(native_abi8()),
            "0.8: the Python abi8 scene (capsule, kinematic, materials, four joints) hashes like the native run")
    var st = nat.w.state(nat.player)
    s.almost(Float64(String(kv["player"][0])), Float64(st.pos[0]), "player x", tol=2e-6)

    var raw = List[Real]()
    for x in [-5, 0, -5, 5, 0, -5, 5, 0, 5, -5, 0, 5]:
        raw.append(Real(x))
    for x in [-0.2, 0.0, -5.0, 0.2, 0.0, -5.0, 0.2, 0.0, 3.0, -0.2, 0.0, 3.0, -0.2, 2.0, -5.0, 0.2, 2.0, -5.0, 0.2, 2.0, 3.0, -0.2, 2.0, 3.0]:
        raw.append(Real(x))
    var vs = List[Vec3]()
    for i in range(12):
        vs.append(_v(raw[3 * i], raw[3 * i + 1], raw[3 * i + 2]))
    var ts = List[Int]()
    for t in [0, 2, 1, 0, 3, 2, 8, 10, 9, 8, 11, 10, 4, 5, 9, 4, 9, 8, 6, 7, 11, 6, 11, 10, 5, 6, 10, 5, 10, 9, 7, 4, 8, 7, 8, 11]:
        ts.append(t)
    var nav = EmbedNav(vs, ts, NavBakeConfig.default())
    var path = nav.find_path(_v(-3, 0, -3), _v(3, 0, -3))
    s.eqi(Int(String(kv["nav_points"][0])), len(path.points), "Python nav path point count == native")
    s.almost(Float64(String(kv["nav_points"][2])), Float64(path.length()), "Python nav path length == native", tol=2e-3)

    # 5. prototype table == header
    var re = Python.import_module("re")
    var pathlib = Python.import_module("pathlib")
    var header = pathlib.Path("embed/ludens.h").read_text()
    var declared = bi.set(re.findall("\\b(ld_[a-z_0-9]+)\\(", header))
    var bound = bi.set(re.findall("\"(ld_[a-z_0-9]+)\": \\(", pathlib.Path("python/ludens/_capi.py").read_text()))
    s.check(Bool(py=declared == bound), "ctypes PROTOTYPES name exactly the header's functions " + String(bi.sorted(declared ^ bound)))
    _ = shutil.rmtree(tmp)
    s.finish()
