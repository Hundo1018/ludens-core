"""Client-side checks for the installed `ludens` wheel (ROADMAP 17.21).

Run by tests/test_python_binding.mojo with the python of a fresh venv the
wheel was pip-installed into, from a temp working directory, with a minimal
environment:

    python client_check.py FORBIDDEN_PREFIX WORKDIR

FORBIDDEN_PREFIX is the repository root: no module or shared library may be
loaded from under it. Prints `key value` lines (compared by the Mojo test
against native runs) and `check <ok|FAIL> <label>` lines; exits non-zero if
any check failed.
"""

import math
import os
import sys
import textwrap

import ludens
from ludens import BEGAN, ENDED, POST, PRE

FORBIDDEN = os.path.realpath(sys.argv[1]) + os.sep
WORK = sys.argv[2]
failures = 0


def check(cond, label):
    global failures
    print("check %s %s" % ("ok" if cond else "FAIL", label))
    if not cond:
        failures += 1


def raises(exc_type, fn):
    try:
        fn()
    except exc_type as e:
        return e
    return None


# ---------------------------------------------------------------- isolation
check(not os.path.realpath(ludens.__file__).startswith(FORBIDDEN), "ludens imported from the venv, not the repo: " + ludens.__file__)
check(os.path.dirname(ludens.library_path) == os.path.dirname(ludens.__file__), "libludens.so loaded from the installed package")
check(ludens.abi_version() == (0, 6), "abi_version == (0, 6)")


# ------------------------------------------------- parity scenario (test_capi)
def build_scene(w):
    w.add_box((0, -0.5, 0), (20, 0.5, 20), mass=0, static=True)
    for i in range(4):
        for k in range(2):
            w.add_box((-3 + 2.0 * i, 0.25 + 0.51 * k, 2), (0.25, 0.25, 0.25), mass=1)
    for i in range(3):
        w.add_sphere((-2 + 2.0 * i, 1 + 0.5 * i, -2), 0.3, mass=0.5)
    return w.add_box((0, 0.4, 0), (0.4, 0.4, 0.4), mass=2)


VX = (3.0, 0.0, -3.0, 0.0)
VZ = (0.0, 3.0, 0.0, -3.0)
counts = {"pre": 0, "post": 0, "began": 0, "ended": 0}

with ludens.World(1.0 / 60.0, (0, -9.8, 0)) as w:
    player = build_scene(w)

    @w.system(PRE)
    def drive(world, dt, tick):
        k = (tick // 60) % 4
        vy = player.state().vel[1]
        player.set_velocity((VX[k], vy, VZ[k]))
        counts["pre"] += 1

    @w.system(POST)
    def post(world, dt, tick):
        counts["post"] += 1

    def on_contact(world, ev):
        counts["began" if ev.kind == BEGAN else "ended"] += 1

    w.subscribe_contacts(on_contact, kinds=(BEGAN, ENDED))
    buffered = 0
    for _ in range(120):
        w.step(1.0 / 60.0)
        buffered += sum(1 for e in w.events() if e.kind == BEGAN)
    w.step_ticks(120)
    buffered += sum(1 for e in w.events() if e.kind == BEGAN)
    print("tick", w.tick)
    print("hash", w.hash())
    print("began", counts["began"], "ended", counts["ended"])
    st = player.state()
    print("player %.6f %.6f %.6f" % st.pos)
    check(counts["pre"] == 240 and counts["post"] == 240, "PRE / POST Python systems ran once per tick")
    check(buffered == counts["began"], "events() BEGAN count == subscriber count")

    hit = w.raycast((0, 5, -2), (0, -1, 0), 20)
    check(hit is not None and hit.body.alive and abs(hit.t - 4.4) < 0.1, "raycast hits the middle sphere (t=%.4f)" % (hit.t if hit else -1))
    check(w.raycast((0, 5, 0), (0, 1, 0), 20) is None, "raycast into empty space -> None")
    bodies, poses = w.bodies()
    check(len(bodies) == 13 and bodies[-1] == player and poses[-1][:3] == st.pos, "bodies() handles and poses line up")
    import ctypes

    buf = (ctypes.c_float * (7 * 13))()
    check(w.poses_into(buf) == 13 and tuple(buf[7 * 12 : 7 * 12 + 3]) == st.pos, "poses_into fills a caller buffer")
    # ABI 0.2: bulk pose write, counters
    moved = [(float(i), 5.0, 0.0, 0.0, 0.0, 0.0, 1.0) for i in range(len(bodies))]
    check(w.set_poses(bodies, moved) == len(bodies), "set_poses writes every pose in one call")
    _, back = w.bodies()
    check(all(abs(back[i][0] - float(i)) < 1e-6 and abs(back[i][1] - 5.0) < 1e-6 for i in range(len(back))), "set_poses round-trips through get_bodies")
    cn = w.counters()
    check(isinstance(cn, dict) and "nan_quarantined" in cn and all(v >= 0 for v in cn.values()), "counters() names every counter")

    # ABI 0.3: physics capture
    w.capture_begin(30)
    w.step_ticks(45)
    w.capture_end()
    cap = w.capture_bytes()
    w.step_ticks(5)
    import struct

    magic, version, key_every, frames = struct.unpack("<4q", cap[:32])
    check(magic == 0x5041434C and version == 2 and key_every == 30 and frames == 45, "capture_bytes: 45 frames recorded, recording stops at capture_end")
    check(isinstance(raises(ludens.ArgumentError, lambda: w.capture_begin(0)), ludens.ArgumentError), "capture_begin(0) -> ArgumentError")

    # save / load replay
    blob = w.save()
    w.step_ticks(60)
    ha = w.hash()
    w.load(blob)
    w.step_ticks(60)
    check(w.hash() == ha, "save, run 60, load, run 60: same hash")
    check(isinstance(raises(ludens.FormatError, lambda: w.load(b"garbage")), ludens.FormatError), "load(garbage) -> FormatError")

    # errors
    victim = w.add_sphere((5, 3, 5), 0.2)
    victim.remove()
    check(isinstance(raises(ludens.StaleBodyError, victim.remove), ludens.StaleBodyError), "remove twice -> StaleBodyError")
    check(not victim.alive, "removed body reads dead")
    e = raises(ludens.ArgumentError, lambda: w.add_box((math.nan, 0, 0), (1, 1, 1)))
    check(e is not None and "finite" in str(e), "NaN position -> ArgumentError with the engine's message")
    check(raises(ludens.ArgumentError, lambda: w.add_box((0, 0), (1, 1, 1))) is not None, "2-element position -> ArgumentError")

    class Boom(RuntimeError):
        pass

    def bad(world, dt, tick):
        raise Boom("from a system")

    sid = w.add_system(bad)
    t0 = w.tick
    err = raises(Boom, lambda: w.step_ticks(5))
    check(err is not None and isinstance(err.__cause__, ludens.CallbackError), "Python exception in a system re-raised from step (cause CallbackError)")
    check(w.tick == t0, "failing PRE system stops the step before physics")
    w.remove_system(sid)
    check(w.step_ticks(2) == 2, "world steps again after the failing system is removed")

    def destroy_inside(world, dt, tick):
        world.close()

    sid = w.add_system(destroy_inside)
    err = raises(ludens.StateError, lambda: w.step_ticks(1))
    check(err is not None, "close() from inside a system -> StateError (world stays valid)")
    w.remove_system(sid)

check(isinstance(raises(ludens.HandleError, lambda: w.tick), ludens.HandleError), "use after close -> HandleError")
check(raises(ludens.ArgumentError, lambda: ludens.World(dt=0)) is not None, "World(dt=0) -> ArgumentError")


# ---------------------------------------------------------------- navigation
verts = [(-5, 0, -5), (5, 0, -5), (5, 0, 5), (-5, 0, 5),
         (-0.2, 0, -5), (0.2, 0, -5), (0.2, 0, 3), (-0.2, 0, 3),
         (-0.2, 2, -5), (0.2, 2, -5), (0.2, 2, 3), (-0.2, 2, 3)]
tris = [(0, 2, 1), (0, 3, 2), (8, 10, 9), (8, 11, 10), (4, 5, 9), (4, 9, 8), (6, 7, 11), (6, 11, 10),
        (5, 6, 10), (5, 10, 9), (7, 4, 8), (7, 8, 11)]
with ludens.NavMesh(verts, tris) as nav:
    path = nav.find_path((-3, 0, -3), (3, 0, -3), max_points=2)
    length = sum(math.dist(path[i - 1], path[i]) for i in range(1, len(path)))
    print("nav_points %d len %.3f" % (len(path), length))
    check(nav.poly_count > 0, "navmesh has polygons")
check(raises(ludens.ArgumentError, lambda: ludens.NavMesh(verts, [(0, 1, 99)])) is not None, "triangle index out of range -> ArgumentError")


# ------------------------------------------------------------------- cvars
reg = ludens.CVarRegistry()
seen = []
reg.define("game.speed", 1.5, min=0.0, max=10.0, help="player speed scale", on_change=lambda cv, o, n: seen.append((o, n)))
reg.define("game.god", False)
reg.define("game.lives", 3, min=0)
check(reg.exec("game.speed 2.5") == "2.5" and seen == [(1.5, 2.5)], "console `name value` sets and notifies")
check(reg.exec("game.god on") == "1" and reg["game.god"] is True, "bool cvar parses `on`")
check(raises(ludens.ArgumentError, lambda: reg.set("game.speed", 11)) is not None and reg["game.speed"] == 2.5, "out-of-range set rejected, value kept")
check(raises(ludens.ArgumentError, lambda: reg.set("game.lives", "2.5")) is not None, "int cvar rejects 2.5")
check(raises(ludens.ArgumentError, lambda: reg.exec("nope 1")) is not None, "unknown cvar rejected")
bad_cfg = "game.lives 5\ngame.speed fast\n"
check(raises(ludens.ArgumentError, lambda: reg.load(bad_cfg)) is not None and reg["game.lives"] == 3, "config with a bad line applies nothing")
dumped = reg.dump()
reg2 = ludens.CVarRegistry()
reg2.define("game.speed", 1.5, min=0.0, max=10.0)
reg2.define("game.god", False)
reg2.define("game.lives", 3, min=0)
reg2.load(dumped)
values = lambda text: [l.split("#")[0].strip() for l in text.splitlines()]
check(values(reg2.dump()) == values(dumped) and reg2["game.speed"] == 2.5, "dump -> load round-trips")


def tuned_run(change):
    with ludens.World() as tw:
        reg = ludens.bind_world(tw)
        build_scene(tw)
        tw.step_ticks(60)
        if change == "cvar":
            reg.exec("physics.iterations 1")
            reg.exec("physics.gravity_y -3.0")
        elif change == "direct":
            tw.set_solver(1, 4)
            tw.set_gravity((0, -3.0, 0))
        tw.step_ticks(60)
        return tw.hash()


plain = tuned_run(None)
via_cvar = tuned_run("cvar")
direct = tuned_run("direct")
with ludens.World() as tw:
    build_scene(tw)
    tw.step_ticks(120)
    unbound = tw.hash()
check(via_cvar == direct, "live cvar change at tick 60 == direct set_solver / set_gravity at tick 60")
check(via_cvar != plain, "the cvar change had an effect")
check(plain == unbound, "binding cvars with defaults does not change the simulation")


# --------------------------------------------------------------- hot reload
src_v1 = textwrap.dedent("""
    def system(world, dt, tick, state):
        state["calls"] = state.get("calls", 0) + 1
        p = world.body(state["player"])
        p.set_velocity((2.0, p.state().vel[1], 0.0))
""")
src_v2 = textwrap.dedent("""
    def system(world, dt, tick, state):
        state["calls"] = state.get("calls", 0) + 1
        p = world.body(state["player"])
        p.set_velocity((0.0, p.state().vel[1], -2.0))
""")
src_broken = "def system(world, dt, tick, state)\n    pass\n"
src_v3 = src_v2 + textwrap.dedent("""
    def migrate(state):
        state["migrated"] = True
""")
mod = os.path.join(WORK, "hot_sys.py")
open(mod, "w").write(src_v1)
with ludens.World() as hw:
    hp = build_scene(hw)
    hs = ludens.HotSystem(hw, mod)
    hs.state["player"] = hp.handle
    hw.step_ticks(60)
    open(mod, "w").write(src_v2)
    hw.step_ticks(60)
    hot_hash = hw.hash()
    check(hs.reloads == 1 and hs.failures == 0, "edit picked up: 1 reload")
    check(hs.state["calls"] == 120, "state dict survives the reload (120 calls)")
    open(mod, "w").write(src_broken)
    hw.step_ticks(10)
    check(hs.failures == 1 and "SyntaxError" in (hs.last_error or "") and hs.state["calls"] == 130, "syntax error keeps the old function running")
    open(mod, "w").write(src_v3)
    hw.step_ticks(1)
    check(hs.reloads == 2 and hs.state.get("migrated") is True and hs.last_error is None, "fixed edit reloads and runs migrate(state)")

with ludens.World() as rw:
    rp = build_scene(rw)

    def switched(world, dt, tick):
        vx, vz = (2.0, 0.0) if tick < 60 else (0.0, -2.0)
        rp.set_velocity((vx, rp.state().vel[1], vz))

    rw.add_system(switched)
    rw.step_ticks(120)
    check(rw.hash() == hot_hash, "hot reload at tick 60 == switching functions at tick 60 (same hash)")


# ---------------------------------------------------------------- host mapping (0.4)
import threading

with ludens.World() as mw:
    near = mw.add_box((2, 0, 0), (0.5, 0.5, 0.5), mass=0, static=True)
    far = mw.add_box((4, 0, 0), (0.5, 0.5, 0.5), mass=0, static=True)
    near.set_layer(1, 0xFFFFFFFF)
    far.set_layer(2, 0xFFFFFFFF)
    h_all = mw.raycast((0, 0, 0), (1, 0, 0))
    h_2 = mw.raycast((0, 0, 0), (1, 0, 0), mask=2)
    h_none = mw.raycast((0, 0, 0), (1, 0, 0), mask=4)
    check(h_all.body == near and h_2.body == far and h_none is None, "raycast mask selects layers: all -> near, 2 -> far, 4 -> none")
    near.user = 1001
    far.user = 1002
    check(mw.find_user(1002) == far and near.user == 1001 and mw.find_user(7) is None, "user values attach to bodies and map back")
    blob = mw.save()
    with ludens.World() as lw:
        lw.load(blob)
        check(lw.find_user(1001) is not None and lw.find_user(1001).user == 1001, "user values survive save / load")
    far.remove()
    check(mw.find_user(1002) is None, "a removed body's user value is gone")
    mw.bind_thread()
    seen = []
    t = threading.Thread(target=lambda: seen.append(raises(ludens.ThreadError, lambda: mw.tick)))
    t.start()
    t.join()
    check(seen[0] is not None and mw.tick == 0, "a bound world refuses other threads (ThreadError), works on its own")
    mw.bind_thread(False)
    seen2 = []
    t2 = threading.Thread(target=lambda: seen2.append(mw.tick))
    t2.start()
    t2.join()
    check(seen2 == [0], "after unbinding another thread may use it")

with ludens.World() as ua, ludens.World() as ub:
    pa = build_scene(ua)
    pb = build_scene(ub)
    for i, b in enumerate(ub.bodies()[0]):
        b.user = 5000 + i
    ua.step_ticks(60)
    ub.step_ticks(60)
    check(pa.state() == pb.state(), "user values do not change the simulation")


# ---------------------------------------------------------------- units (ABI 0.5)
def scaled_scene(w, k):
    w.add_box((0, -0.5 * k, 0), (20 * k, 0.5 * k, 20 * k), mass=0, static=True)
    out = []
    for i in range(4):
        for j in range(2):
            out.append(w.add_box(((-3 + 2.0 * i) * k, (0.25 + 0.51 * j) * k, 2 * k), (0.25 * k, 0.25 * k, 0.25 * k), mass=1))
    return out


K = 128.0
with ludens.World(1.0 / 60.0, (0, -9.8, 0)) as m1, ludens.World(1.0 / 60.0, (0, -9.8 * K, 0)) as mk, ludens.World(1.0 / 60.0, (0, -9.8 * K, 0)) as mn:
    b1 = scaled_scene(m1, 1.0)
    bk = scaled_scene(mk, K)
    bn = scaled_scene(mn, K)
    mk.set_unit_scale(K)
    for wv in (m1, mk, mn):
        wv.step_ticks(120)
    same = all(tuple(x * K for x in a.state().pos) == tuple(b.state().pos) for a, b in zip(b1, bk))
    drift = max(abs(a.state().pos[1] * K - b.state().pos[1]) / K for a, b in zip(b1, bn))
    check(same, "a world in units of 1/128 m with set_unit_scale(128) is the metre world x 128, bit for bit")
    check(drift > 0, "without set_unit_scale the same world differs (by %.2g m)" % drift)
    check(raises(ludens.LudensError, lambda: mk.set_unit_scale(0)) is not None, "set_unit_scale(0) is rejected")


# ---------------------------------------------------------------- ABI 0.6 (17.90)
with ludens.World(dt=1 / 60, gravity=(0, -9.81, 0)) as fw:
    ground = fw.add_box((0, -1, 0), (20, 1, 20), mass=0, static=True)
    frags = fw.add_fracture_box((0, 3, 0), (0.5, 0.5, 0.5), pieces=10, seed=2, stress=2.0e3)
    check(len(frags) >= 4, "add_fracture_box returns fragment handles (%d)" % len(frags))
    broken = 0
    for _ in range(90):
        fw.step_ticks(1)
        broken += len(fw.fracture_events())
    check(broken > 0, "a falling fractured box reports broken welds (%d)" % broken)
    frame = fw.export_frame()
    check(frame[:4] == b"LDF1" and len(frame) == 24 + 72 * (len(frags) + 1), "export_frame has the LDF1 header and one record per body")
with ludens.World(dt=1 / 60, gravity=(0, -9.81, 0)) as mw:
    mw.add_box((0, -1, 0), (20, 1, 20), mass=0, static=True)
    ball = mw.add_sphere((0, 0.6, 0), 0.5, mass=1.0)
    ball.material = 9
    check(ball.material == 9, "Body.material round-trips")
    seen = []
    for _ in range(60):
        mw.step_ticks(1)
        seen += mw.events_ex()
    check(any(e.material_a == 9 or e.material_b == 9 for e in seen), "events_ex carries the body's material id")
    check(any(e.normal_impulse > 0 for e in seen), "events_ex carries a normal impulse")

# ---------------------------------------------------------------- isolation again
maps = open("/proc/self/maps").read().splitlines()
leaked = sorted({l.split()[-1] for l in maps if l.split()[-1].startswith(FORBIDDEN)})
check(not leaked, "no shared library mapped from the repository: %s" % leaked[:3])
mods = sorted(n for n, m in sys.modules.items() if getattr(m, "__file__", None) and os.path.realpath(m.__file__).startswith(FORBIDDEN))
check(not mods, "no module imported from the repository: %s" % mods[:3])

print("failures", failures)
sys.exit(1 if failures else 0)
