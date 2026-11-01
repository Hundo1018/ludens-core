# tier: integration
"""C-ABI embedding boundary (ROADMAP 12.1).

Builds `embed/capi.mojo` into a shared library, compiles the C host
`tests/capi/host.c` against `embed/ludens.h`, runs it, and checks:

- parity: the C host's world (systems as C callbacks, contacts through a
  C subscriber) hashes equal to the same scenario run natively on
  `EmbedWorld` with the logic written in Mojo;
- the documented status code of every error path;
- the v0.x freeze: every line of `embed/abi_v0.txt` is still in the header,
  and the library exports exactly the functions the header declares;
- ABI 0.4 (17.78): two worlds stepped at once on two C threads hash like
  one alone, a world bound to a thread refuses others (LD_ERR_THREAD),
  layers filter a masked raycast, user values map bodies back;
- generated bindings (17.78): `bindings/rust/ludens_sys.rs` is what
  `scripts/gen_bindings.py` makes from the header today, and a Rust host
  (`tests/capi/host.rs`) built on it hashes equal to the C host.

Needs `gcc`, `nm` and `rustc` on PATH (the test fails, not skips, without
them: the boundary is the deliverable).
"""

from std.python import Python, PythonObject
from harness.runner import Suite
from geometry.vec import Real, Vec3
from nav.heightfield import NavBakeConfig
from embed.world import (
    EmbedWorld,
    ABI_MAJOR,
    ABI_MINOR,
    LD_ERR_HANDLE,
    LD_ERR_ARG,
    LD_ERR_STALE,
    LD_ERR_BUFFER,
    LD_ERR_FORMAT,
    LD_ERR_CALLBACK,
    LD_ERR_STATE,
    LD_ERR_THREAD,
    EVENT_BEGAN,
    EVENT_ENDED,
)
from embed.navigation import EmbedNav


def _v(x: Real, y: Real, z: Real) -> Vec3:
    return Vec3(x, y, z, 0)


struct Native:
    """The C host's scenario, written against EmbedWorld directly."""

    var w: EmbedWorld
    var player: Int64
    var began: Int
    var ended: Int
    var events: Int

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
        self.events = 0

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
        self.events += len(self.w.tick_events)


def _sh(sp: PythonObject, cmd: PythonObject) raises -> String:
    var r = sp.run(cmd, capture_output=True, text=True)
    if Int(py=r.returncode) != 0:
        raise Error("command failed: " + String(cmd) + "\n" + String(r.stdout) + String(r.stderr))
    return String(r.stdout)


def main() raises:
    var s = Suite("capi")
    var sp = Python.import_module("subprocess")
    var tempfile = Python.import_module("tempfile")
    var bi = Python.import_module("builtins")
    var tmp = String(tempfile.mkdtemp(prefix="ludens_capi_"))
    var lib = tmp + "/libludens.so"
    var host = tmp + "/host"

    _ = _sh(sp, Python.list("mojo", "build", "--emit", "shared-lib", "-I", "build", "-o", lib, "embed/capi.mojo"))
    _ = _sh(
        sp,
        Python.list(
            "gcc", "-std=c99", "-Wall", "-Wextra", "-Werror", "-pthread", "-Iembed", "tests/capi/host.c",
            "-L" + tmp, "-lludens", "-lm", "-Wl,-rpath," + tmp, "-o", host,
        ),
    )
    var out = _sh(sp, Python.list(host))
    var gen = _sh(sp, Python.list("python3", "scripts/gen_bindings.py", "--check"))
    var host_rs = tmp + "/host_rs"
    _ = _sh(
        sp,
        Python.list(
            "rustc", "--edition", "2021", "-O", "tests/capi/host.rs", "-L", tmp, "-l", "ludens",
            "-C", "link-arg=-Wl,-rpath," + tmp, "-o", host_rs,
        ),
    )
    out = out + _sh(sp, Python.list(host_rs))
    var kv = Python.dict()
    for line in out.split("\n"):
        var parts = line.split(" ")
        if len(parts) >= 2:
            kv[String(parts[0])] = Python.list()
            for p in parts[1:]:
                _ = kv[String(parts[0])].append(String(p))

    def get(kv: PythonObject, key: String, i: Int) raises -> String:
        return String(kv[key][i])

    # --- version
    s.eqi(Int(get(kv, "abi", 0)), (ABI_MAJOR << 16) | ABI_MINOR, "ld_abi_version == ABI_MAJOR << 16 | ABI_MINOR")

    # --- parity: C callbacks vs native Mojo logic
    var nat = Native()
    for _ in range(120):
        var n = nat.w.ticks_due(1.0 / 60.0)
        for _ in range(n):
            nat.tick()
    for _ in range(120):
        nat.tick()
    s.eqi(Int(get(kv, "tick", 0)), nat.w.tick, "C host and native both at tick 240")
    var c_hash = String(bi.str(bi.int(get(kv, "hash", 0), 16)))
    var native_hash = String(nat.w.hash())
    s.check(c_hash == native_hash, "world hash: C host (systems + subscriber as C callbacks) == native Mojo run")
    s.eqi(Int(get(kv, "pre", 0)), 240, "PRE system called once per tick")
    s.eqi(Int(get(kv, "pre", 2)), 240, "POST system called once per tick")
    s.eqi(Int(get(kv, "began", 0)), nat.began, "subscriber saw the native run's BEGAN count")
    s.eqi(Int(get(kv, "began", 2)), nat.ended, "subscriber saw the native run's ENDED count")
    s.eqi(Int(get(kv, "began", 4)), nat.began, "buffered events (ld_world_get_events) carry the same BEGAN count")
    s.eqi(Int(get(kv, "began", 6)), nat.events, "buffered event total == native event total")
    s.eqi(Int(get(kv, "evex", 0)), nat.events, "ld_world_get_events_ex returns the same number of events")
    s.eqi(Int(get(kv, "evex", 1)), 0, "ld_contact_event_ex repeats tick / a / b / kind / feature of ld_contact_event")
    s.check(Int(get(kv, "evex", 2)) > 0, "some events carry a normal impulse (" + get(kv, "evex", 2) + ")")
    s.check(Int(get(kv, "evex", 3)) > 0, "ld_body_set_material shows up as material_a / material_b (" + get(kv, "evex", 3) + ")")
    s.eqi(Int(get(kv, "evex", 4)), nat.events, "LD_EVENT_FLAG_PERSISTENT is set exactly on STAY events")
    s.check(Int(get(kv, "evex", 5)) > 0, "some contacts report a tangential velocity (" + get(kv, "evex", 5) + ")")
    s.eqi(Int(get(kv, "evex", 6)), 104, "sizeof(ld_contact_event_ex) == 104")
    s.check(Int(get(kv, "fracture", 0)) >= 4, "ld_world_add_fracture_box made fragments (" + get(kv, "fracture", 0) + ")")
    s.eqi(Int(get(kv, "fracture", 1)), Int(get(kv, "fracture", 0)), "ld_world_get_fragments returns every fragment")
    s.eqi(Int(get(kv, "fracture", 2)), 1, "the first fragment handle is fragment 0")
    s.check(Int(get(kv, "fracture", 3)) > 0, "a falling fractured box breaks welds and reports events (" + get(kv, "fracture", 3) + ")")
    s.eqi(Int(get(kv, "fracture", 4)), 1, "fracture events name live fragment bodies")
    s.eqi(Int(get(kv, "fracture", 5)), LD_ERR_STATE, "a world with a fractured object refuses to save")
    s.eqi(Int(get(kv, "fracture_second", 0)), LD_ERR_ARG, "a second fractured object is refused")
    s.eqi(Int(get(kv, "frame", 0)), Int(get(kv, "frame", 2)), "ld_world_frame_size == 24 + 72 per body")
    s.eqi(Int(get(kv, "frame", 1)), Int(get(kv, "frame", 0)), "ld_world_export_frame writes exactly frame_size bytes")
    s.eqi(Int(get(kv, "frame", 3)), 0x3146444C, "frame magic is LDF1")
    s.eqi(Int(get(kv, "frame", 4)), 1, "frame header body count == ld_world_body_count")
    s.eqi(Int(get(kv, "frame", 5)), 1, "frame records repeat ld_world_get_bodies handles and poses bit for bit")
    s.eqi(Int(get(kv, "frame", 6)), 1, "a short frame buffer is refused with LD_ERR_BUFFER")
    s.check(nat.began > 0, "scenario has contacts beginning (" + String(nat.began) + ")")
    var st = nat.w.state(nat.player)
    s.almost(Float64(get(kv, "player", 0)), Float64(st.pos[0]), "player x (C printout, 6 decimals)", tol=2e-6)
    s.almost(Float64(get(kv, "player", 2)), Float64(st.pos[2]), "player z", tol=2e-6)
    s.eqi(Int(get(kv, "bodies", 0)), 13, "13 live bodies")

    # --- queries
    var ray = nat.w.raycast(_v(0, 5, -2), _v(0, -1, 0), 20)
    s.eqi(Int(get(kv, "ray", 0)), 1, "raycast down onto the middle sphere hits")
    s.check(Int(get(kv, "ray", 2)) == Int(ray.body), "C raycast hit body == native")
    s.almost(Float64(get(kv, "ray", 4)), Float64(ray.t), "C raycast t == native", tol=1e-4)
    s.eqi(Int(get(kv, "ray_miss", 0)), 0, "raycast up into empty space misses (0)")
    s.eqi(Int(get(kv, "get_bodies", 0)), 13, "get_bodies returns the live count")
    s.eqi(Int(get(kv, "get_bodies", 2)), LD_ERR_BUFFER, "get_bodies with capacity count-1 -> LD_ERR_BUFFER")
    s.eqi(Int(get(kv, "last_pose_is_player", 0)), 1, "get_bodies handles and poses line up")

    # --- save / load
    s.check(get(kv, "save", 0) == get(kv, "save", 2), "save writes ld_world_save_size bytes")
    s.eqi(Int(get(kv, "save", 4)), LD_ERR_BUFFER, "save into a short buffer -> LD_ERR_BUFFER")
    s.eqi(Int(get(kv, "load", 0)), 0, "load of own blob -> LD_OK")
    s.eqi(Int(get(kv, "replay_equal", 0)), 1, "save, run 60, load, run 60: same hash")
    s.eqi(Int(get(kv, "load_garbage", 0)), LD_ERR_FORMAT, "corrupted magic -> LD_ERR_FORMAT")
    s.eqi(Int(get(kv, "load_short", 0)), LD_ERR_FORMAT, "truncated blob -> LD_ERR_FORMAT")

    # --- error paths
    s.eqi(Int(get(kv, "null_world", 0)), LD_ERR_HANDLE, "NULL world -> LD_ERR_HANDLE")
    s.eqi(Int(get(kv, "remove", 0)), 0, "remove body -> LD_OK")
    s.eqi(Int(get(kv, "remove", 2)), LD_ERR_STALE, "remove twice -> LD_ERR_STALE")
    s.eqi(Int(get(kv, "slot_reused", 0)), 1, "next body reuses the slot")
    s.eqi(Int(get(kv, "slot_reused", 2)), 0, "old handle to the reused slot reads dead (generation)")
    s.eqi(Int(get(kv, "slot_reused", 4)), 1, "new handle alive")
    s.eqi(Int(get(kv, "stale_velocity", 0)), LD_ERR_STALE, "set_velocity on stale handle -> LD_ERR_STALE")
    s.eqi(Int(get(kv, "nan_box", 0)), LD_ERR_ARG, "NaN position -> LD_ERR_ARG")
    s.eqi(Int(get(kv, "msg_len_ok", 0)), 1, "last_error copies a NUL-terminated message and returns its length")
    s.eqi(Int(get(kv, "zero_mass", 0)), LD_ERR_ARG, "dynamic body with mass 0 -> LD_ERR_ARG")
    s.eqi(Int(get(kv, "bad_phase", 0)), LD_ERR_ARG, "unknown system phase -> LD_ERR_ARG")
    s.eqi(Int(get(kv, "null_out", 0)), LD_ERR_ARG, "NULL output pointer -> LD_ERR_ARG")
    # ABI 0.3 (17.80): capture of 25 ticks, recording stops at capture_end
    s.eqi(Int(get(kv, "capture_bad", 0)), LD_ERR_ARG, "capture_begin(0) -> LD_ERR_ARG")
    s.eqi(Int(get(kv, "capture_read_all", 0)), 1, "capture_read copies capture_size bytes")
    s.eqi(Int(get(kv, "capture_frames", 0)), 25, "25 ticks captured, none after capture_end")
    s.eqi(Int(get(kv, "capture_small", 0)), LD_ERR_BUFFER, "capture_read into 8 bytes -> LD_ERR_BUFFER")
    s.eqi(Int(get(kv, "bad_dt", 0)), 1, "create with dt 0 -> LD_ERR_ARG")
    s.eqi(Int(get(kv, "callback_fail", 0)), LD_ERR_CALLBACK, "system returning non-zero -> LD_ERR_CALLBACK")
    s.eqi(Int(get(kv, "callback_fail", 2)), 2, "step stops before the failing tick's physics (2 ticks done)")
    s.eqi(Int(get(kv, "destroy_inside", 0)), LD_ERR_STATE, "destroy from inside a callback -> LD_ERR_STATE")
    s.eqi(Int(get(kv, "destroy", 0)), 0, "destroy -> LD_OK")

    # --- generated Rust bindings (17.78)
    print("  " + gen.strip() + ";  rust host hash", get(kv, "rs_hash", 0), " c host hash", get(kv, "hash", 0))
    s.check("up to date" in gen, "bindings/rust/ludens_sys.rs matches the header")
    s.check(get(kv, "rs_hash", 0) == get(kv, "hash", 0) and get(kv, "rs_pre", 0) == get(kv, "pre", 0) and get(kv, "rs_destroy", 0) == "0", "the Rust host on the generated bindings hashes equal to the C host")

    # --- ABI 0.4 (17.78): threads, layers, user values
    s.eqi(Int(get(kv, "two_worlds_parallel", 0)), 1, "two worlds stepped at once on two threads hash like one stepped alone")
    s.eqi(Int(get(kv, "thread_refused", 0)), LD_ERR_THREAD, "a bound world called from another thread -> LD_ERR_THREAD")
    s.check(Int(get(kv, "thread_refused", 2)) >= 0 and Int(get(kv, "thread_refused", 4)) >= 0, "the owning thread works; after unbinding any thread does")
    s.eqi(Int(get(kv, "thread_refused", 6)), LD_ERR_ARG, "bind_thread flag other than 0 / 1 -> LD_ERR_ARG")
    s.check(get(kv, "mask_ray", 0) == "1" and get(kv, "mask_ray", 1) == "1" and get(kv, "mask_ray", 3) == "0", "raycast mask: all -> near layer 1 box, mask 2 -> far box, mask 4 -> miss")
    s.check(get(kv, "user", 0) == "1" and get(kv, "user", 2) == "1" and Int(get(kv, "user", 4)) == LD_ERR_STALE, "user value set, read back, found; an unknown value -> LD_ERR_STALE")

    # --- navigation parity
    var vs = List[Vec3]()
    var raw = List[Real]()
    for x in [-5, 0, -5, 5, 0, -5, 5, 0, 5, -5, 0, 5]:
        raw.append(Real(x))
    for x in [-0.2, 0.0, -5.0, 0.2, 0.0, -5.0, 0.2, 0.0, 3.0, -0.2, 0.0, 3.0]:
        raw.append(Real(x))
    for x in [-0.2, 2.0, -5.0, 0.2, 2.0, -5.0, 0.2, 2.0, 3.0, -0.2, 2.0, 3.0]:
        raw.append(Real(x))
    for i in range(12):
        vs.append(_v(raw[3 * i], raw[3 * i + 1], raw[3 * i + 2]))
    var ts = List[Int]()
    for t in [0, 2, 1, 0, 3, 2, 8, 10, 9, 8, 11, 10, 4, 5, 9, 4, 9, 8, 6, 7, 11, 6, 11, 10, 5, 6, 10, 5, 10, 9, 7, 4, 8, 7, 8, 11]:
        ts.append(t)
    var nav = EmbedNav(vs, ts, NavBakeConfig.default())
    var path = nav.find_path(_v(-3, 0, -3), _v(3, 0, -3))
    s.eqi(Int(get(kv, "nav_bake", 0)), 0, "nav bake -> LD_OK")
    s.eqi(Int(get(kv, "nav_points", 0)), len(path.points), "C path point count == native")
    s.almost(Float64(get(kv, "nav_points", 2)), Float64(path.length()), "C path length == native", tol=2e-3)
    s.check(path.length() > 12.6, "path goes around the wall (straight line is 6 m, wall end detour >= 12.6 m)")
    s.eqi(Int(get(kv, "nav_small", 0)), LD_ERR_BUFFER, "path into a 1-point buffer -> LD_ERR_BUFFER")
    s.eqi(Int(get(kv, "nav_bad_index", 0)), LD_ERR_ARG, "triangle index out of range -> LD_ERR_ARG")
    s.eqi(Int(get(kv, "nav_destroy", 0)), 0, "nav destroy -> LD_OK")

    # --- v0.x freeze
    var header = String(Python.import_module("pathlib").Path("embed/ludens.h").read_text())
    var frozen = String(Python.import_module("pathlib").Path("embed/abi_v0.txt").read_text())
    var missing = 0
    var frozen_lines = 0
    for line in frozen.split("\n"):
        var l = String(line).strip()
        if l.byte_length() == 0 or l.startswith("#"):
            continue
        frozen_lines += 1
        if not header.__contains__(String(l)):
            missing += 1
            print("  frozen line missing from ludens.h:", l)
    s.check(frozen_lines >= 35, "abi_v0.txt lists the frozen declarations (" + String(frozen_lines) + ")")
    s.eqi(missing, 0, "every frozen declaration still in ludens.h verbatim")
    var re = Python.import_module("re")
    var declared = bi.set(re.findall("\\b(ld_[a-z_0-9]+)\\(", header))
    # ELF: the dynamic symbol table; Mach-O (macOS) has none by that name --
    # `nm -g -U` lists defined globals there, with a leading underscore
    var darwin = String(Python.import_module("sys").platform) == "darwin"
    var syms = _sh(sp, Python.list("nm", "-g", "-U", lib) if darwin else Python.list("nm", "-D", "--defined-only", lib))
    var exported = bi.set()
    for line in syms.split("\n"):
        var parts = String(line).split(" ")
        if len(parts) == 3 and String(parts[1]) == "T":
            var raw = String(parts[2])
            var name = String(raw[byte=1:]) if darwin and raw.startswith("_") else raw
            _ = exported.add(name)
    var extra = bi.sorted(exported - declared)
    var undeclared = bi.sorted(declared - exported)
    s.eqi(Int(py=len(extra)), 0, "library exports nothing beyond the header " + String(extra))
    s.eqi(Int(py=len(undeclared)), 0, "every header function is exported " + String(undeclared))
    _ = Python.import_module("shutil").rmtree(tmp)
    s.finish()
